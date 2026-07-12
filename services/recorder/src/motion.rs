// SPDX-License-Identifier: AGPL-3.0-or-later

//! Motion detection task — native frame-diff on raw grayscale bytes.
//!
//! # Responsibility
//!
//! Spawns an ffmpeg child that decodes the camera's sub-stream to raw
//! grayscale frames (pipe → stdout), then for each frame:
//!
//! 1. Absolute-difference vs the previous frame on `&[u8]` byte slices
//!    (correctness item 16 — **no OpenCV**).
//! 2. Apply `motion_mask` polygon exclusions (zero diff inside masked zones).
//! 3. Threshold + count changed pixels → score ∈ `[0.0, 1.0]`.
//! 4. Dynamic sensitivity (default): auto-calibrate threshold from a rolling
//!    window of recent frame statistics (correctness item 15).
//! 5. Emit [`MotionSignal`] start/stop events on the `motion_tx` channel.
//!
//! # Hardware acceleration (correctness items 11–12)
//!
//! * When `MOTION_HWACCEL=cuda`: ffmpeg is invoked with `-hwaccel cuda`.
//! * Before opening the NVDEC session, the task tries to acquire one permit
//!   from the global [`NVDEC_SEMAPHORE_ARC`].  When the permit limit is
//!   exhausted the task falls back to CPU decode for that camera.
//! * Recording itself is `-c copy` (zero decode) — GPU pressure comes only
//!   from motion sub-stream decode.
//!
//! # Pipe safety (correctness item 5)
//!
//! The ffmpeg child's stderr is drained in a separate spawned task to prevent
//! the ~64 KB OS pipe buffer from filling and blocking ffmpeg → blocking our
//! frame reader.  We never rely on stderr cadence for shutdown detection.
//!
//! # Shutdown (correctness item 6)
//!
//! On [`CancellationToken`](tokio_util::sync::CancellationToken) cancellation,
//! the ffmpeg child is killed immediately via `child.kill().await`.  We do NOT
//! wait for it to emit more output.

use std::sync::Arc;

use anyhow::{Context, Result};
use chrono::{DateTime, Datelike, Timelike, Utc};
use crumb_common::{
    config::{Config, HwAccel},
    db::MotionBaselineState,
    types::{Camera, MotionSensitivity},
    MotionSignal,
};
use deadpool_postgres::Pool;
use tokio::io::AsyncBufReadExt;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};

use crate::source_health::{FailOpenGate, SourceHealth, SourceKind, DEFAULT_SOURCE_DOWN_GRACE};
use crate::{MotionHealthTx, MotionTx};

// ─── tuning constants ─────────────────────────────────────────────────────────

/// Width to which the sub-stream is downscaled for motion analysis (pixels).
///
/// Height is derived at runtime by probing the stream with `ffprobe`.
const MOTION_FRAME_WIDTH: u32 = 320;

/// Fallback frame height when `ffprobe` fails.
///
/// 180 px = 16:9 at 320 px wide — the most common sub-stream aspect ratio.
const MOTION_FRAME_HEIGHT_FALLBACK: u32 = 180;

/// Cap on the post-decode ANALYSIS rate (frames per second).
///
/// ffmpeg must decode every frame the camera sends — RTSP does not support
/// requesting fewer.  An `fps=` filter placed *before* the scale step drops
/// frames AFTER decode but BEFORE the analysis pipeline (census → morphology
/// → blob → threshold → grid), so we avoid running that CPU-heavy path on
/// every decoded frame.  A typical 8–15 fps sub-stream becomes 5 fps of
/// analysis work across all cameras.
///
/// CPU path filter order: `fps={N},scale=320:H,format=gray`
///   — `fps` drops first so scaling is skipped for dropped frames.
///
/// CUDA path filter order: `scale_cuda=W:H,hwdownload,format=nv12,fps={N},format=gray`
///   — scale happens on GPU, then download, then CPU-side fps drop before gray.
const MOTION_ANALYSIS_FPS: u32 = 5;

/// Minimum wall-clock seconds of consecutive above-floor frames before the
/// state machine transitions Idle → Active.
///
/// Preserves today's feel (3 frames at ~8 fps ≈ 0.375 s).  Derived frame
/// count: `round(MOTION_START_SECS * MOTION_ANALYSIS_FPS)` = 2 frames.
/// Using seconds keeps the dwell fps-independent so a change to
/// `MOTION_ANALYSIS_FPS` does not silently alter detection latency.
const MOTION_START_SECS: f32 = 0.4;

/// Minimum wall-clock seconds of consecutive below-threshold frames before
/// the state machine transitions Active → Idle.
///
/// Preserves today's feel (15 frames at ~8 fps ≈ 1.875 s).  Derived frame
/// count: `round(MOTION_STOP_SECS * MOTION_ANALYSIS_FPS)` = 9 frames.
const MOTION_STOP_SECS: f32 = 1.8;

/// Frame-count dwell for Idle→Active, derived from [`MOTION_START_SECS`] and
/// [`MOTION_ANALYSIS_FPS`].  Internal use only; public interface is the
/// seconds-based const above.
const MOTION_START_FRAMES: usize =
    ((MOTION_START_SECS * MOTION_ANALYSIS_FPS as f32) + 0.5) as usize;

/// Frame-count hysteresis for Active→Idle, derived from [`MOTION_STOP_SECS`]
/// and [`MOTION_ANALYSIS_FPS`].  Internal use only; public interface is the
/// seconds-based const above.
const MOTION_STOP_HYSTERESIS: usize =
    ((MOTION_STOP_SECS * MOTION_ANALYSIS_FPS as f32) + 0.5) as usize;

/// After this many seconds with no detected motion, the adaptive-rate logic
/// halves the analysis rate to ~2.5 fps (every other decoded frame is skipped
/// without running the detector).  The instant any processed frame detects
/// motion the full rate resumes immediately, so the worst-case detection
/// latency while quiet is one skipped frame ≈ 1/`MOTION_ANALYSIS_FPS` s.
const QUIET_SECS: u64 = 30;

// ─── motion-detection-design.md constants (blob/background redesign) ───────────
//
// The detector no longer thresholds a *prev-frame diff* and counts the global
// changed-pixel fraction. It now:
//   1. maintains a per-pixel EMA BACKGROUND model (`bg`),
//   2. thresholds |curr − bg| into a binary foreground mask,
//   3. erodes (denoise) then dilates ×2 (bridge a body into one blob),
//   4. runs connected-component labeling, and
//   5. decides on the LARGEST connected blob's area, not a global pixel count.
// See docs/MOTION-DETECTION-DESIGN.md for the full rationale.

/// Minimum compact-blob area, as a fraction of the frame, for ANY motion to be
/// declared (the floor in both Manual and Dynamic modes). 0.30 % ≈ 175 px on a
/// 320×180 frame — catches a person at ~10–13 m on a wide view while rejecting a
/// swaying-branch fragment (≤150 px) and denoised speckle (≤3 px). It is the
/// convergent default across ZoneMinder / Frigate / `motion` normalised to our
/// frame size. Used as an absolute pixel count internally
/// (`round(BLOB_FRACTION * total_pixels)`) so it scales across aspect ratios.
const BLOB_FRACTION: f32 = 0.0030;

/// Background-model EMA rate while IDLE (no active event). ~12 s time-constant at
/// an ~8 fps sub-stream — absorbs slow lighting drift so it never trips motion.
const BG_ALPHA_IDLE: f32 = 0.01;

/// Background-model EMA rate while an event is ACTIVE. ~60 s — the background is
/// near-frozen so a subject who pauses is NOT absorbed mid-event (recording keeps
/// running while they stand still), but a genuinely parked object re-absorbs over
/// ~a minute and the event then ends.
const BG_ALPHA_ACTIVE: f32 = 0.002;

/// Background-model EMA rate applied for ONE frame after a whole-frame
/// illumination change (IR cut, headlight sweep, lights-on) so `bg` re-converges
/// fast instead of reading the new lighting as motion for ~12 s.
const BG_ALPHA_LIGHTNING: f32 = 0.15;

/// Whole-frame-change ("lightning") gate: if more than this fraction of the frame
/// is foreground after thresholding, treat it as a global illumination change —
/// emit NO motion and bump `bg` to the fast rate for that frame.
const LIGHTNING_FRACTION: f32 = 0.50;

/// Dilation iterations after erosion — bridges the gaps inside a moving person
/// (dark clothing, limbs, background showing through) so the body becomes ONE
/// connected blob big enough to pass [`BLOB_FRACTION`], instead of many fragments.
const DILATE_ITERS: usize = 2;

/// Frames at startup during which `bg` converges and NO motion is emitted (while
/// still updating `bg` at the idle rate). Prevents the first ~100 frames — when
/// `bg` is still seeded from a single frame — reading as full-frame motion.
const WARMUP_FRAMES: u64 = 60;

/// Live motion-tuner display grid resolution (columns × rows) published per
/// camera. Fine (80×45 = 4×4-px cells on the 320×180 analysis frame) so the tuner
/// paints the actual changing pixels (a foreground mask), not coarse boxes — the
/// "show pixels, not 16×9 cells" requirement (docs/MOTION-TUNER-VIZ-REQ.md). The
/// exclusion-zone AUTHORING grid stays coarse and is a separate client-side grid.
const MOTION_GRID_COLS: usize = 80;
const MOTION_GRID_ROWS: usize = 45;
/// Throttle the grid upsert to ~2 Hz so it never burdens the motion loop or DB.
const MOTION_GRID_WRITE_MS: u128 = 500;

/// Fixed per-pixel byte-diff threshold used in the DARK-region census fallback
/// (and the unit tests).  Separate from the score-level threshold held by
/// [`AdaptiveThreshold`].
const PIXEL_DIFF_THRESHOLD_DYNAMIC: u8 = 25;

// ─── adaptive-threshold tuning constants ──────────────────────────────────────
//
// All knobs are named consts so they can be re-tuned against the maintainer's real clips
// without touching algorithm code.

/// Number of geometric histogram buckets spanning `[BLOB_FRACTION, MAX_THRESHOLD]`.
/// Bucket 0 is the "quiet" bin (score < `BLOB_FRACTION`).
const AT_NB: usize = 64;

/// Exponential-decay half-life in minutes.  Scores older than ~2 h are nearly
/// forgotten, so the learner tracks weather / lighting without thrashing.
const AT_HORIZON_MIN: f32 = 120.0;

/// Percentile of the CDF to use as the live floor.  0.97 → the floor sits just
/// above 97% of recent activity, so isolated nuisance frames can't trigger.
const AT_PERCENTILE: f32 = 0.97;

/// EMA smoothing factor for the per-hour diurnal profile.  ≈0.05 → slow
/// learning over many days, stable against transient illumination shifts.
const AT_DIURNAL_ALPHA: f32 = 0.05;

/// Wall-clock seconds between `recompute` calls.  15 s gives sub-minute
/// adaptation at negligible CPU cost (one 64-bucket scan per camera).
const AT_RECOMPUTE_SECS: u64 = 15;

/// Wall-clock seconds between baseline UPSERT calls.  Every 5 min per camera
/// (~11 cameras total → ~132 tiny writes/hour) is trivially low DB load.
const AT_PERSIST_SECS: u64 = 300;

// ── Census-transform foreground (illumination-invariant) ──────────────────────
// The foreground primitive compares the 3×3 CENSUS SIGNATURE (local intensity
// ORDERING) of curr vs bg, not raw brightness — so lighting changes (sun/shade
// boundaries, clouds, auto-exposure) that uniformly darken/brighten a region
// produce NO motion, while real objects (which change the local texture/silhouette)
// do. This replaces the old raw `|curr − bg| > 25` test that false-triggered on
// any lighting change. See docs/MOTION-DETECTION-DESIGN.md.

/// Minimum number of 3×3 neighbour-ordering bits (of 8) that must flip between
/// curr and bg for a pixel to count as foreground. Lower = more sensitive.
///
/// Raised 2→3 (2026-06-17): LED light sources (spotlights, eave strips) PWM-flicker
/// and beat with the camera frame rate, jittering the local ordering of lit
/// surfaces enough to flip 2 bits frame-to-frame. Requiring 3 of 8 demands more
/// genuine texture/silhouette change — a real person still trips many bits, but
/// flicker on a flat lit wall/door no longer clears the bar.
const CENSUS_HAMMING_THRESH: u8 = 3;
/// A foreground pixel must ALSO have moved more than this many luma levels — a
/// noise-floor band that kills ordering-bit flips from sensor grain in flat
/// regions. Well below [`PIXEL_DIFF_THRESHOLD_DYNAMIC`] so it never gates a real
/// object; and because a uniformly-lit region has Hamming ≈ 0, this band can only
/// REMOVE false positives, never create the shadow-edge one.
///
/// Raised 8→18 (2026-06-17): the dominant night false-motion source is LED flicker
/// reflecting off lit surfaces (white doors, curtained windows under eave LEDs),
/// whose per-frame luma swing is a small pulse (~8–15). An 18-level floor lets that
/// pulse fall through while a real moving object (which changes luma by far more)
/// stays above it.
const CENSUS_ABS_GUARD: f32 = 18.0;
/// Below this background luma the census bits are noise-dominated (deep shadow /
/// high-gain IR night image); fall back to plain `|curr − bg|` for that pixel.
const CENSUS_DARK_FLOOR: f32 = 30.0;
/// A neighbour must be darker than the centre by MORE than this many luma levels
/// (after BOTH are quantised to integers) to set its ordering bit. This dead-band
/// makes the census signature ignore sub-luma ordering "ties": on a smooth
/// gradient (sky/wall/road) adjacent pixels differ by a fraction of a luma, and
/// without the band the integer-rounded `curr` and the integer-truncated `bg`
/// disagree on those near-ties under a uniform light change — re-creating the
/// shadow false-positive. Both sides are compared as `i16` (same quantisation) so
/// their orderings match; the band absorbs the residual ±1 rounding/truncation.
const CENSUS_TIE_BAND: i16 = 2;

/// Base back-off on ffmpeg restart (seconds).
const BACKOFF_BASE_SECS: u64 = 1;
/// Maximum back-off cap (seconds).
const BACKOFF_MAX_SECS: u64 = 30;
/// How long an *enabled-but-not-yet-configured* source idles before re-reading
/// its settings (so enabling the integration is picked up without a restart,
/// without hot-spinning the DB).
const SOURCE_RECHECK_SECS: u64 = 5;

/// Maximum time to wait for `ffprobe` to return stream geometry before giving
/// up and either using the fallback height or forcing a reconnect.
///
/// When the upstream camera is temporarily unreachable (or go2rtc has not yet
/// established the producer connection), ffprobe blocks indefinitely — it can
/// connect the TCP socket to go2rtc but go2rtc can't deliver an SDP until the
/// camera comes back.  Without this cap the motion loop never reaches the frame
/// loop, so the per-frame stall and frame-receipt watchdogs never fire and the
/// sub-stream stays silently dead.
///
/// On failure the caller falls back to `MOTION_FRAME_HEIGHT_FALLBACK` (16:9
/// at 320 px wide), which is correct for the vast majority of cameras.  The
/// miss cost is that a camera with a non-16:9 sub-stream will have a slightly
/// wrong blob-area fraction until the next reconnect probes again — acceptable
/// because the motion detector still works, just with a minor scale error.
const FFPROBE_TIMEOUT_SECS: u64 = 20;

/// Per-frame stall watchdog: maximum time to wait for the next pipe-level read
/// to complete before declaring the sub-stream dead and forcing a reconnect.
///
/// A sub-stream can stall WITHOUT closing its TCP socket (camera firmware
/// glitch, network half-open, upstream go2rtc hiccup): ffmpeg blocks on the
/// input read, emits no more frames, and never returns EOF or an error — so the
/// frame loop would await forever and the outer back-off/reconnect would never
/// fire. (Observed in prod 2026-06-17: Front Door + Backdoor motion went silently
/// dead at 11:33 for ~2 h while recording continued.) A healthy sub-stream
/// delivers several frames/sec, so any gap this long is a genuine stall.
const FRAME_STALL_TIMEOUT_SECS: u64 = 12;

/// Frame-receipt watchdog: maximum wall-clock time between successfully decoded
/// frames before declaring the sub-stream dead and forcing a full reconnect.
/// Tracked by `Instant::now()` on each complete frame decode, so it fires even
/// if the stall watchdog has a blind spot (e.g. ffmpeg emits partial pipe data
/// that keeps resetting the `read_exact_frame` inner loop without ever producing
/// a complete frame).
///
/// Also serves as the **init deadline** for a freshly started or live-reconfig-
/// restarted worker: a new worker that never decodes its first frame within this
/// window (gap #2 — live-reconfig half-init where ffmpeg opens the RTSP session
/// but go2rtc's producer is not yet available) will reconnect rather than
/// hanging forever.  Set slightly above the per-frame stall so the two watchdogs
/// do not race; in the common case the stall fires first at 12 s and
/// immediately returns Err, resetting the outer back-off loop, so this fires
/// only when stall has a blind spot.
const FRAME_RECEIPT_TIMEOUT_SECS: u64 = 15;

// ─── global NVDEC semaphore ───────────────────────────────────────────────────

/// Global `Arc<Semaphore>` capping concurrent NVDEC decode sessions.
///
/// `Arc` is required so each motion task can hold an
/// [`OwnedSemaphorePermit`](tokio::sync::OwnedSemaphorePermit) that is not
/// lifetime-tied to the static — the permit lives as long as the spawned task.
///
/// Correctness item 11: prevents VRAM exhaustion that would starve other GPU
/// workloads sharing the host.
static NVDEC_SEMAPHORE_ARC: std::sync::OnceLock<Arc<Semaphore>> = std::sync::OnceLock::new();

/// Initialise the global NVDEC semaphore.
///
/// Must be called exactly once from `main()`, before any camera workers are
/// spawned.  Subsequent calls are silently ignored (`OnceLock` semantics).
///
/// # Arguments
///
/// * `max_sessions` — maximum concurrent NVDEC sessions
///   (`MAX_GPU_DECODE_SESSIONS` env var; default 4).
pub fn init_nvdec_semaphore(max_sessions: usize) {
    NVDEC_SEMAPHORE_ARC.get_or_init(|| Arc::new(Semaphore::new(max_sessions)));
}

/// Try to acquire one NVDEC permit (non-blocking).
///
/// Returns `Some(permit)` when a slot is free; `None` when exhausted.
/// The caller must fall back to CPU decode when `None` is returned.
/// The permit is released automatically when dropped.
fn try_acquire_nvdec() -> Option<tokio::sync::OwnedSemaphorePermit> {
    NVDEC_SEMAPHORE_ARC
        .get()
        .and_then(|arc| arc.clone().try_acquire_owned().ok())
}

// ─── pluggable motion detector (the seam) ──────────────────────────────────────
//
// The per-frame loop (`run_pixel_diff_loop`) is almost entirely
// algorithm-AGNOSTIC: exclusion masking, morphology, connected-components,
// largest-blob scoring, manual/dynamic thresholding, the event state machine,
// and the tuner grid all operate on a foreground mask and work identically no
// matter how that mask was produced. Only TWO steps are specific to a given
// algorithm: (1) turning a frame into a foreground mask, and (2) owning +
// updating the background model. Those two live behind [`MotionDetector`].
//
// Contract (deliberately split read-from-model from update-model so the shared
// lightning/active decision can parametrise the model update, exactly as the
// monolithic loop did):
//   * `seed_if_needed` — seed the model from the first frame; returns true on
//     that seed frame so the caller skips the rest (mirrors the old bg-seed
//     `continue`).
//   * `foreground` — produce the mask from `frame` vs the model (READ-ONLY).
//   * `commit` — fold `frame` into the model, choosing the update rate from the
//     shared [`FrameContext`] (lightning / event-active).
// The mask byte is a 0..=255 confidence (binary detectors write 0/255); the
// shared pipeline treats any non-zero pixel as foreground, so a 0/255 mask is
// byte-identical to the legacy behaviour. Richer detectors (optical flow,
// future ML) can emit graded confidence for ensemble fusion.

/// Which motion algorithm a `MotionDetector` implements (logging / tuner display
/// / per-camera selection). The wire/DB spelling is the lower-case `as_str`
/// form; `from_str` is tolerant (unknown ⇒ `Census`, the safe default).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MotionAlgorithm {
    /// Illumination-invariant 3×3 census transform over an EMA background.
    #[default]
    Census,
    /// Classic adjacent-frame absolute difference (the pre-census behaviour):
    /// maximally sensitive, sees every change including a subject the instant it
    /// stops, at the cost of tripping on lighting change.
    FrameDiff,
    /// Stauffer–Grimson / Zivkovic-style per-pixel Gaussian-mixture background.
    /// Multi-modal: a pixel that legitimately alternates between two appearances
    /// (sky vs. a swaying branch, a flickering sign) learns BOTH as background, so
    /// it stops false-triggering where a single-mode model can't.
    Mog2,
    /// Block-matching optical flow: foreground where image content actually
    /// *translates* between frames. Coherent motion (a walking person, a car)
    /// trips it; incoherent change (global flicker, sensor shimmer, an IR cut that
    /// brightens-in-place) does not, because it has no consistent displacement.
    OpticalFlow,
    /// Fusion of Census (primary, illumination-invariant) with MOG2 (fills the
    /// flat/low-texture regions where census is structurally blind), plus a
    /// lightning veto: if MOG2 lights the whole frame but census doesn't, it's a
    /// global illumination change and MOG2's verdict is suppressed. The most
    /// robust option; ~2–3× the CPU of a single detector.
    Ensemble,
}

impl MotionAlgorithm {
    /// Canonical lower-case identifier (DB column / API / tuner).
    pub fn as_str(self) -> &'static str {
        match self {
            MotionAlgorithm::Census => "census",
            MotionAlgorithm::FrameDiff => "framediff",
            MotionAlgorithm::Mog2 => "mog2",
            MotionAlgorithm::OpticalFlow => "opticalflow",
            MotionAlgorithm::Ensemble => "ensemble",
        }
    }

    /// Parse the canonical identifier. Unknown / empty ⇒ `Census` (the safe,
    /// byte-identical-to-legacy default) so a bad config row can never crash a
    /// recorder worker or silently disable motion.
    pub fn from_str_lenient(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "framediff" | "frame_diff" | "diff" => MotionAlgorithm::FrameDiff,
            "mog2" | "gmm" | "mog" => MotionAlgorithm::Mog2,
            "opticalflow" | "optical_flow" | "flow" => MotionAlgorithm::OpticalFlow,
            "ensemble" | "fusion" | "hybrid" => MotionAlgorithm::Ensemble,
            _ => MotionAlgorithm::Census,
        }
    }
}

/// Where a camera's motion comes from. `LocalCv` runs the frame pipeline with a
/// [`MotionDetector`]; `Frigate` (a later stage) consumes Frigate MQTT object
/// events and bypasses the frame pipeline entirely.
pub enum MotionSource {
    LocalCv(Box<dyn MotionDetector>),
    // Frigate(..) — added in the Frigate-as-source stage.
}

/// Shared per-frame state the detector needs when folding a frame into its model.
/// Computed by the shared pipeline (it owns the lightning gate + the event state
/// machine); the detector decides how to *react* to it.
#[derive(Debug, Clone, Copy)]
pub struct FrameContext {
    /// The shared pipeline classified this frame as a whole-frame illumination
    /// change (foreground fraction > `LIGHTNING_FRACTION`).
    pub lightning: bool,
    /// A motion event is currently active (state machine is in `Active`).
    pub event_active: bool,
}

/// A motion algorithm: frame in, foreground mask out, owning its own background
/// model. One instance per camera; stateful. Everything else (morphology,
/// scoring, thresholding, hysteresis, tuner grid) is the shared pipeline.
pub trait MotionDetector: Send {
    /// Seed the model from the first frame. Returns `true` on the seed frame so
    /// the caller skips the rest of that frame (no comparison is possible yet).
    fn seed_if_needed(&mut self, frame: &[u8]) -> bool;

    /// Produce the foreground mask for `frame` vs the current model into `mask`
    /// (a `w*h` buffer; 0..=255 confidence, 0/255 for binary detectors). MUST be
    /// read-only on the model — the model is updated separately by `commit`.
    ///
    /// `active` is a precomputed per-pixel activity map (`1` = compute, `0` =
    /// masked/skip).  For every pixel where `active[i] == 0` the detector MUST
    /// write `mask[i] = 0` and MUST skip any foreground computation and background
    /// model update for that pixel (skipping the model update here is the whole
    /// point — only the `commit` impl handles the per-pixel model write, and only
    /// for active pixels).  For active pixels (`active[i] != 0`) the detector
    /// computes exactly as before, including reads of neighbouring pixels that may
    /// themselves be masked (e.g. the 3×3 census neighbourhood).
    fn foreground(&self, frame: &[u8], w: usize, h: usize, active: &[u8], mask: &mut [u8]);

    /// Fold `frame` into the background model, choosing the update rate from
    /// `ctx`.  For pixels where `active[i] == 0` the background model MUST NOT
    /// be updated — the pixel is masked out and its model state is frozen.
    fn commit(&mut self, frame: &[u8], ctx: FrameContext, active: &[u8]);

    /// Drop all model state (called when the sub-stream reconnects so a stale
    /// background can't read as motion on resume).
    fn reset(&mut self);

    /// Which algorithm this is (diagnostics / tuner).
    fn algorithm_id(&self) -> MotionAlgorithm;
}

/// The default, illumination-invariant detector: a per-pixel EMA background plus
/// the 3×3 census-transform foreground. Wraps the existing [`census_mask_vs_bg`]
/// and [`update_background`] verbatim — behaviour is identical to the pre-seam
/// monolithic loop (guarded by `census_detector_matches_legacy`).
pub struct CensusDetector {
    /// Per-pixel EMA background model (f32), length `w*h`.
    bg: Vec<f32>,
    /// True once `bg` has been seeded from the first frame.
    bg_init: bool,
}

impl CensusDetector {
    pub fn new(frame_size: usize) -> Self {
        Self {
            bg: vec![0f32; frame_size],
            bg_init: false,
        }
    }
}

impl MotionDetector for CensusDetector {
    fn seed_if_needed(&mut self, frame: &[u8]) -> bool {
        if self.bg_init {
            return false;
        }
        for (b, &c) in self.bg.iter_mut().zip(frame.iter()) {
            *b = f32::from(c);
        }
        self.bg_init = true;
        true
    }

    fn foreground(&self, frame: &[u8], w: usize, h: usize, active: &[u8], mask: &mut [u8]) {
        census_mask_vs_bg(frame, &self.bg, w, h, active, mask);
    }

    fn commit(&mut self, frame: &[u8], ctx: FrameContext, active: &[u8]) {
        // Identical rate selection to the legacy loop: fast on a lightning frame
        // so bg re-converges; near-frozen during an active event so a paused
        // subject isn't absorbed; slow otherwise to track gradual drift.
        let alpha = if ctx.lightning {
            BG_ALPHA_LIGHTNING
        } else if ctx.event_active {
            BG_ALPHA_ACTIVE
        } else {
            BG_ALPHA_IDLE
        };
        update_background_active(&mut self.bg, frame, alpha, active);
    }

    fn reset(&mut self) {
        self.bg_init = false;
        for b in self.bg.iter_mut() {
            *b = 0.0;
        }
    }

    fn algorithm_id(&self) -> MotionAlgorithm {
        MotionAlgorithm::Census
    }
}

// ── FrameDiff detector ────────────────────────────────────────────────────────

/// Per-pixel threshold (luma levels) for the FrameDiff / OpticalFlow detectors —
/// the "did this pixel change at all" floor. Same value the references use
/// (Frigate 30, ZoneMinder 25); shared with the dark-region census fallback.
const FRAMEDIFF_THRESHOLD: i16 = PIXEL_DIFF_THRESHOLD_DYNAMIC as i16;

/// Classic adjacent-frame absolute difference. The "model" is simply the previous
/// frame, so [`commit`](MotionDetector::commit) always copies the current frame
/// in (alpha/state are irrelevant — this is the alpha=1.0 extreme the EMA models
/// were designed to replace, kept as a deliberately-sensitive option).
pub struct FrameDiffDetector {
    prev: Vec<u8>,
    prev_init: bool,
}

impl FrameDiffDetector {
    pub fn new(frame_size: usize) -> Self {
        Self {
            prev: vec![0u8; frame_size],
            prev_init: false,
        }
    }
}

impl MotionDetector for FrameDiffDetector {
    fn seed_if_needed(&mut self, frame: &[u8]) -> bool {
        if self.prev_init {
            return false;
        }
        self.prev.copy_from_slice(frame);
        self.prev_init = true;
        true
    }

    fn foreground(&self, frame: &[u8], _w: usize, _h: usize, active: &[u8], mask: &mut [u8]) {
        for (((m, &a), &c), &p) in mask
            .iter_mut()
            .zip(active.iter())
            .zip(frame.iter())
            .zip(self.prev.iter())
        {
            if a == 0 {
                *m = 0;
                continue;
            }
            let d = (i16::from(c) - i16::from(p)).abs();
            *m = if d > FRAMEDIFF_THRESHOLD { 255 } else { 0 };
        }
    }

    fn commit(&mut self, frame: &[u8], _ctx: FrameContext, active: &[u8]) {
        // The model is the previous frame. Advance only the ACTIVE pixels to
        // `curr`; masked pixels keep their previous value so a newly-unmasked
        // region converges from a stale prev (acceptable — the worker respawns
        // on mask changes anyway).
        for (p, (&a, &c)) in self.prev.iter_mut().zip(active.iter().zip(frame.iter())) {
            if a != 0 {
                *p = c;
            }
        }
    }

    fn reset(&mut self) {
        self.prev_init = false;
        self.prev.iter_mut().for_each(|p| *p = 0);
    }

    fn algorithm_id(&self) -> MotionAlgorithm {
        MotionAlgorithm::FrameDiff
    }
}

// ── MOG2 (Gaussian-mixture) detector ──────────────────────────────────────────

/// Number of Gaussian components per pixel. 3 is the sweet spot for outdoor
/// scenes (sky / branch / occasional third mode) at this frame size; OpenCV
/// defaults to 5 but the extra two rarely earn their ~0.7 MB/cam here.
const MOG2_K: usize = 3;
/// Background learning rate (idle). One match ≈ this fraction of the way toward
/// "this is background"; ~0.01 ⇒ a new static object joins the background over
/// ~100 frames. Scaled like the census model via [`FrameContext`].
const MOG2_ALPHA_IDLE: f32 = 0.01;
const MOG2_ALPHA_ACTIVE: f32 = 0.002;
const MOG2_ALPHA_LIGHTNING: f32 = 0.15;
/// Initial variance for a freshly-spawned component (std ≈ 15 luma) — wide enough
/// that the next few frames almost certainly match and tighten it.
const MOG2_VAR_INIT: f32 = 225.0;
/// Variance floor (std = 4) so a perfectly still pixel's variance can't collapse
/// to zero and make trivial sensor noise read as foreground.
const MOG2_VAR_MIN: f32 = 16.0;
/// Variance ceiling (std ≈ 32) so a chronically noisy pixel can't widen until it
/// matches everything and goes blind.
const MOG2_VAR_MAX: f32 = 1024.0;
/// Squared-Mahalanobis match gate: `(x-μ)² < VAR_THRESHOLD · σ²`. 16 ⇒ ±4σ,
/// OpenCV's default `varThreshold`.
const MOG2_VAR_THRESHOLD: f32 = 16.0;
/// Cumulative weight that the highest-weight components must reach to be treated
/// as "the background". A mode carrying < (1−this) of the time is foreground.
const MOG2_BACKGROUND_RATIO: f32 = 0.90;
/// Weight a brand-new (just-spawned) component starts with.
const MOG2_INIT_WEIGHT: f32 = 0.05;

/// Per-pixel Gaussian-mixture background subtraction (Stauffer–Grimson with
/// Zivkovic-style component replacement), grayscale, pure Rust. Each pixel keeps
/// [`MOG2_K`] weighted Gaussians; a pixel is background if it falls within
/// `±√MOG2_VAR_THRESHOLD·σ` of any of the highest-weight components that together
/// carry [`MOG2_BACKGROUND_RATIO`] of the weight — so genuinely bimodal pixels
/// (sky↔branch) are learnt as background instead of false-triggering.
///
/// Layout: three flat `f32` arrays indexed `[px * MOG2_K + k]` (means, vars,
/// weights), allocated once. Read/commit are split per the trait contract:
/// `foreground` classifies against the pre-update mixture, `commit` folds the
/// frame in — identical model state in both, so the split is exact.
pub struct Mog2Detector {
    means: Vec<f32>,
    vars: Vec<f32>,
    weights: Vec<f32>,
    init: bool,
}

impl Mog2Detector {
    pub fn new(frame_size: usize) -> Self {
        Self {
            means: vec![0.0; frame_size * MOG2_K],
            vars: vec![MOG2_VAR_INIT; frame_size * MOG2_K],
            weights: vec![0.0; frame_size * MOG2_K],
            init: false,
        }
    }

    /// Is `x` within the background portion of pixel `px`'s mixture? Orders the
    /// `MOG2_K` components by weight, walks them high→low accumulating weight, and
    /// returns true if `x` matches one before the cumulative weight passes
    /// `MOG2_BACKGROUND_RATIO`.
    fn is_background(&self, px: usize, x: f32) -> bool {
        let base = px * MOG2_K;
        // Sort indices by weight desc (K is tiny — insertion sort, no alloc).
        let mut order = [0usize; MOG2_K];
        for (i, slot) in order.iter_mut().enumerate() {
            *slot = i;
        }
        for i in 1..MOG2_K {
            let mut j = i;
            while j > 0 && self.weights[base + order[j - 1]] < self.weights[base + order[j]] {
                order.swap(j - 1, j);
                j -= 1;
            }
        }
        let mut cum = 0.0f32;
        for &k in &order {
            let w = self.weights[base + k];
            if w <= 0.0 {
                break;
            }
            let d = x - self.means[base + k];
            if d * d < MOG2_VAR_THRESHOLD * self.vars[base + k] {
                return true; // matches a background-set component
            }
            cum += w;
            if cum > MOG2_BACKGROUND_RATIO {
                break; // remaining components are the foreground tail
            }
        }
        false
    }
}

impl MotionDetector for Mog2Detector {
    fn seed_if_needed(&mut self, frame: &[u8]) -> bool {
        if self.init {
            return false;
        }
        for (px, &v) in frame.iter().enumerate() {
            let base = px * MOG2_K;
            self.means[base] = f32::from(v);
            self.vars[base] = MOG2_VAR_INIT;
            self.weights[base] = 1.0;
            for k in 1..MOG2_K {
                self.means[base + k] = 0.0;
                self.vars[base + k] = MOG2_VAR_INIT;
                self.weights[base + k] = 0.0;
            }
        }
        self.init = true;
        true
    }

    fn foreground(&self, frame: &[u8], _w: usize, _h: usize, active: &[u8], mask: &mut [u8]) {
        for (px, ((&a, &v), m)) in active
            .iter()
            .zip(frame.iter())
            .zip(mask.iter_mut())
            .enumerate()
        {
            if a == 0 {
                *m = 0;
                continue;
            }
            *m = if self.is_background(px, f32::from(v)) {
                0
            } else {
                255
            };
        }
    }

    fn commit(&mut self, frame: &[u8], ctx: FrameContext, active: &[u8]) {
        let alpha = if ctx.lightning {
            MOG2_ALPHA_LIGHTNING
        } else if ctx.event_active {
            MOG2_ALPHA_ACTIVE
        } else {
            MOG2_ALPHA_IDLE
        };
        for (px, (&a, &v)) in active.iter().zip(frame.iter()).enumerate() {
            if a == 0 {
                continue; // masked pixel — do not update the mixture model
            }
            let x = f32::from(v);
            let base = px * MOG2_K;

            // Find the best matching component (closest mean within the gate).
            let mut best: Option<usize> = None;
            let mut best_d2 = f32::INFINITY;
            for k in 0..MOG2_K {
                if self.weights[base + k] <= 0.0 {
                    continue;
                }
                let d = x - self.means[base + k];
                let d2 = d * d;
                if d2 < MOG2_VAR_THRESHOLD * self.vars[base + k] && d2 < best_d2 {
                    best_d2 = d2;
                    best = Some(k);
                }
            }

            match best {
                Some(k) => {
                    // Pull weights toward the indicator (matched=1, others=0).
                    for j in 0..MOG2_K {
                        let ind = f32::from(j == k);
                        self.weights[base + j] += alpha * (ind - self.weights[base + j]);
                    }
                    // Update the matched component's mean & variance.
                    let w = self.weights[base + k].max(1e-6);
                    let rho = alpha / w;
                    let d = x - self.means[base + k];
                    self.means[base + k] += rho * d;
                    let new_var = self.vars[base + k] + rho * (d * d - self.vars[base + k]);
                    self.vars[base + k] = new_var.clamp(MOG2_VAR_MIN, MOG2_VAR_MAX);
                }
                None => {
                    // No match: replace the weakest component with a new mode.
                    let mut weakest = 0usize;
                    for k in 1..MOG2_K {
                        if self.weights[base + k] < self.weights[base + weakest] {
                            weakest = k;
                        }
                    }
                    // Decay the survivors (the new component is the only "match").
                    for j in 0..MOG2_K {
                        self.weights[base + j] *= 1.0 - alpha;
                    }
                    self.means[base + weakest] = x;
                    self.vars[base + weakest] = MOG2_VAR_INIT;
                    self.weights[base + weakest] = MOG2_INIT_WEIGHT;
                }
            }

            // Renormalise weights to sum 1 (cheap; keeps the ratio math honest).
            let sum: f32 = (0..MOG2_K).map(|k| self.weights[base + k]).sum();
            if sum > 1e-6 {
                let inv = 1.0 / sum;
                for k in 0..MOG2_K {
                    self.weights[base + k] *= inv;
                }
            }
        }
    }

    fn reset(&mut self) {
        self.init = false;
        self.means.iter_mut().for_each(|v| *v = 0.0);
        self.vars.iter_mut().for_each(|v| *v = MOG2_VAR_INIT);
        self.weights.iter_mut().for_each(|v| *v = 0.0);
    }

    fn algorithm_id(&self) -> MotionAlgorithm {
        MotionAlgorithm::Mog2
    }
}

// ── Optical-flow (block-matching) detector ────────────────────────────────────

/// Side of a square block for block-matching, in pixels. 16 at 320×180 ⇒ a
/// 20×11 grid — coarse enough to be cheap, fine enough to localise a person.
const FLOW_BLOCK: usize = 16;
/// Half-width of the search window (±N px each axis) when matching a block into
/// the previous frame. ±4 covers fast motion at a 5–15 fps sub-stream.
const FLOW_SEARCH: i32 = 4;
/// A block is "moving" only if its best match sits at least this many pixels from
/// zero displacement — kills the sub-pixel jitter of a static block.
const FLOW_MIN_DISP2: i32 = 4; // (≥2 px in some direction)
/// …AND the zero-displacement SAD must exceed the best-match SAD by at least this
/// much *per pixel*, i.e. the block genuinely matches better when shifted than
/// when still. Rejects flat/again-flat regions where every shift is equally good
/// (aperture problem) and global flicker (every shift equally bad).
const FLOW_MIN_SAD_GAIN: i32 = 6;

/// Block-matching optical flow → foreground mask. For each [`FLOW_BLOCK`]² block,
/// search ±[`FLOW_SEARCH`] px in the previous frame for the lowest SAD; if the
/// best displacement is non-trivial AND clearly beats staying put, the whole
/// block is marked foreground. Responds to *coherent translation* and ignores
/// in-place change (flicker, IR cut, sensor shimmer) that the brightness-based
/// detectors can trip on. Model = previous frame (advanced every `commit`).
pub struct OpticalFlowDetector {
    prev: Vec<u8>,
    prev_init: bool,
}

impl OpticalFlowDetector {
    pub fn new(frame_size: usize) -> Self {
        Self {
            prev: vec![0u8; frame_size],
            prev_init: false,
        }
    }

    /// SAD of the block at (bx0,by0) in `frame` vs the same block shifted by
    /// (dx,dy) in `prev`. Out-of-bounds shifts return `i32::MAX` (never chosen).
    #[allow(clippy::too_many_arguments)]
    fn block_sad(
        &self,
        frame: &[u8],
        w: usize,
        h: usize,
        bx0: usize,
        by0: usize,
        bw: usize,
        bh: usize,
        dx: i32,
        dy: i32,
    ) -> i32 {
        // Bounds: the shifted block must stay fully inside `prev`.
        let sx = bx0 as i32 + dx;
        let sy = by0 as i32 + dy;
        if sx < 0 || sy < 0 || (sx as usize + bw) > w || (sy as usize + bh) > h {
            return i32::MAX;
        }
        let mut sad = 0i32;
        for row in 0..bh {
            let f_off = (by0 + row) * w + bx0;
            let p_off = (sy as usize + row) * w + sx as usize;
            for col in 0..bw {
                sad += (i32::from(frame[f_off + col]) - i32::from(self.prev[p_off + col])).abs();
            }
        }
        sad
    }
}

impl MotionDetector for OpticalFlowDetector {
    fn seed_if_needed(&mut self, frame: &[u8]) -> bool {
        if self.prev_init {
            return false;
        }
        self.prev.copy_from_slice(frame);
        self.prev_init = true;
        true
    }

    fn foreground(&self, frame: &[u8], w: usize, h: usize, active: &[u8], mask: &mut [u8]) {
        mask.iter_mut().for_each(|m| *m = 0);
        let mut by0 = 0;
        while by0 < h {
            let bh = FLOW_BLOCK.min(h - by0);
            let mut bx0 = 0;
            while bx0 < w {
                let bw = FLOW_BLOCK.min(w - bx0);

                // If every pixel in this block is masked, skip the (expensive)
                // block search entirely — the output pixels are already 0 from
                // the iter_mut().for_each above.
                let all_masked = (0..bh).all(|row| {
                    let off = (by0 + row) * w + bx0;
                    (0..bw).all(|col| active[off + col] == 0)
                });
                if all_masked {
                    bx0 += FLOW_BLOCK;
                    continue;
                }

                let still = self.block_sad(frame, w, h, bx0, by0, bw, bh, 0, 0);
                let mut best = still;
                let mut best_dx = 0i32;
                let mut best_dy = 0i32;
                for dy in -FLOW_SEARCH..=FLOW_SEARCH {
                    for dx in -FLOW_SEARCH..=FLOW_SEARCH {
                        if dx == 0 && dy == 0 {
                            continue;
                        }
                        let sad = self.block_sad(frame, w, h, bx0, by0, bw, bh, dx, dy);
                        if sad < best {
                            best = sad;
                            best_dx = dx;
                            best_dy = dy;
                        }
                    }
                }
                let disp2 = best_dx * best_dx + best_dy * best_dy;
                let px = (bw * bh) as i32;
                let gain = still.saturating_sub(best); // ≥0 (still ≥ best)
                if disp2 >= FLOW_MIN_DISP2 && gain >= FLOW_MIN_SAD_GAIN * px {
                    for row in 0..bh {
                        let off = (by0 + row) * w + bx0;
                        for col in 0..bw {
                            // Honour individual pixel masking within a mixed block.
                            if active[off + col] != 0 {
                                mask[off + col] = 255;
                            }
                        }
                    }
                }
                bx0 += FLOW_BLOCK;
            }
            by0 += FLOW_BLOCK;
        }
    }

    fn commit(&mut self, frame: &[u8], _ctx: FrameContext, active: &[u8]) {
        // Only advance the previous-frame model for active pixels so the block
        // search for masked regions remains on stale data (frozen, not updated).
        for (p, (&a, &c)) in self.prev.iter_mut().zip(active.iter().zip(frame.iter())) {
            if a != 0 {
                *p = c;
            }
        }
    }

    fn reset(&mut self) {
        self.prev_init = false;
        self.prev.iter_mut().for_each(|p| *p = 0);
    }

    fn algorithm_id(&self) -> MotionAlgorithm {
        MotionAlgorithm::OpticalFlow
    }
}

// ── Ensemble (soft-mask fusion) detector ──────────────────────────────────────

/// Below this max-abs difference to a pixel's 4-neighbours, the local region is
/// "low texture" — census has no ordering to compare and is blind there, so the
/// ensemble defers to the brightness-based secondary model in such pixels.
const ENSEMBLE_FLAT_THRESHOLD: i16 = 12;

/// Census (primary) fused with MOG2 (secondary). The fusion rule:
/// * a pixel is foreground if **census** flags it (textured regions — census is
///   illumination-invariant and trusted there); PLUS
/// * MOG2 fills in **low-texture pixels** where census is structurally blind; BUT
/// * a **lightning veto** suppresses MOG2 entirely on a frame where MOG2 lights
///   up globally (> [`LIGHTNING_FRACTION`]) while census does not — that is a
///   whole-frame illumination change, and trusting census preserves the
///   shadow/IR-cut immunity that is the whole point of the census primary.
///
/// Scratch masks live behind `RefCell` so the trait's read-only `foreground` can
/// reuse allocate-once buffers (the detector is owned by a single task — `Send`,
/// never shared `&self` across threads). ~2–3× a single detector's CPU.
pub struct EnsembleDetector {
    census: CensusDetector,
    mog2: Mog2Detector,
    census_mask: std::cell::RefCell<Vec<u8>>,
    mog2_mask: std::cell::RefCell<Vec<u8>>,
}

impl EnsembleDetector {
    pub fn new(frame_size: usize) -> Self {
        Self {
            census: CensusDetector::new(frame_size),
            mog2: Mog2Detector::new(frame_size),
            census_mask: std::cell::RefCell::new(vec![0u8; frame_size]),
            mog2_mask: std::cell::RefCell::new(vec![0u8; frame_size]),
        }
    }
}

/// Is pixel `idx` in a low-texture neighbourhood (max |Δ| to its 4-neighbours
/// below [`ENSEMBLE_FLAT_THRESHOLD`])? Border pixels count as textured (false) so
/// the ensemble never invents foreground at the frame edge.
fn is_flat(frame: &[u8], w: usize, h: usize, idx: usize) -> bool {
    let x = idx % w;
    let y = idx / w;
    if x == 0 || y == 0 || x + 1 >= w || y + 1 >= h {
        return false;
    }
    let c = i16::from(frame[idx]);
    let mut max_d = 0i16;
    for nidx in [idx - 1, idx + 1, idx - w, idx + w] {
        let d = (i16::from(frame[nidx]) - c).abs();
        if d > max_d {
            max_d = d;
        }
    }
    max_d < ENSEMBLE_FLAT_THRESHOLD
}

impl MotionDetector for EnsembleDetector {
    fn seed_if_needed(&mut self, frame: &[u8]) -> bool {
        // Seed BOTH (no short-circuit) so neither sub-model is left unseeded.
        let a = self.census.seed_if_needed(frame);
        let b = self.mog2.seed_if_needed(frame);
        a || b
    }

    fn foreground(&self, frame: &[u8], w: usize, h: usize, active: &[u8], mask: &mut [u8]) {
        let mut c = self.census_mask.borrow_mut();
        let mut m = self.mog2_mask.borrow_mut();
        self.census.foreground(frame, w, h, active, &mut c[..]);
        self.mog2.foreground(frame, w, h, active, &mut m[..]);

        let total = (w * h).max(1) as f32;
        let c_on = c.iter().filter(|&&v| v != 0).count() as f32;
        let m_on = m.iter().filter(|&&v| v != 0).count() as f32;
        // Whole-frame illumination change: MOG2 (brightness) lights up, census
        // (ordering) does not → veto MOG2 for this frame.
        let veto_mog2 = (m_on / total) > LIGHTNING_FRACTION && (c_on / total) <= LIGHTNING_FRACTION;

        for (idx, out) in mask.iter_mut().enumerate() {
            if active[idx] == 0 {
                *out = 0;
                continue;
            }
            let census_fg = c[idx] != 0;
            let mog_fg = !veto_mog2 && m[idx] != 0 && is_flat(frame, w, h, idx);
            *out = if census_fg || mog_fg { 255 } else { 0 };
        }
    }

    fn commit(&mut self, frame: &[u8], ctx: FrameContext, active: &[u8]) {
        self.census.commit(frame, ctx, active);
        self.mog2.commit(frame, ctx, active);
    }

    fn reset(&mut self) {
        self.census.reset();
        self.mog2.reset();
    }

    fn algorithm_id(&self) -> MotionAlgorithm {
        MotionAlgorithm::Ensemble
    }
}

/// Construct a detector for an explicit algorithm. Stage 4 wires the per-camera
/// `motion_algorithm` column to this; until then [`build_detector`] always passes
/// `Census` (the byte-identical default).
fn detector_for_algorithm(algo: MotionAlgorithm, frame_size: usize) -> Box<dyn MotionDetector> {
    match algo {
        MotionAlgorithm::Census => Box::new(CensusDetector::new(frame_size)),
        MotionAlgorithm::FrameDiff => Box::new(FrameDiffDetector::new(frame_size)),
        MotionAlgorithm::Mog2 => Box::new(Mog2Detector::new(frame_size)),
        MotionAlgorithm::OpticalFlow => Box::new(OpticalFlowDetector::new(frame_size)),
        MotionAlgorithm::Ensemble => Box::new(EnsembleDetector::new(frame_size)),
    }
}

/// Construct the per-camera detector from the camera's `motion_algorithm` column
/// (lenient parse — an unknown value falls back to Census, so a bad config row
/// can never disable motion).
fn build_detector(camera: &Camera, frame_size: usize) -> Box<dyn MotionDetector> {
    let algo = MotionAlgorithm::from_str_lenient(&camera.motion_algorithm);
    detector_for_algorithm(algo, frame_size)
}

// ─── decode-backend truth telemetry (migration 0035) ─────────────────────────

/// Best-effort upsert of this camera's decode-backend truth row
/// (`camera_decode_status`), surfaced by `GET /config/decode-status` so the
/// admin console can show what the recorder is ACTUALLY using vs what the
/// operator requested. Telemetry only — a failed write is logged at DEBUG and
/// never affects the motion loop.
async fn report_decode_status(
    pool: &Pool,
    camera_id: uuid::Uuid,
    requested: &str,
    active: &str,
    fallback_reason: Option<&str>,
) {
    if let Err(e) = crumb_common::db::upsert_camera_decode_status(
        pool,
        camera_id,
        requested,
        active,
        fallback_reason,
    )
    .await
    {
        debug!(
            camera_id = %camera_id,
            error = %e,
            "decode-status upsert failed (telemetry only)"
        );
    }
}

/// Hysteresis gate for the `motion_detector_unhealthy` alert (NOT for the
/// `health_tx` watch signal itself — that always flips immediately so
/// fail-open recording reacts instantly; see [`report_health`]).
///
/// Flaky cameras (e.g. Reolink units that self-reboot) commonly bounce the
/// frame-stall/frame-receipt watchdogs for well under a minute and self-heal
/// via the normal reconnect back-off, before ever losing footage (fail-open
/// keeps recording throughout). Alerting on every such blip pages the
/// operator all day for nothing actionable. This gate defers the alert: on
/// the unhealthy transition it spawns a one-shot timer that waits
/// `alert_after_secs`, then emits the `system_events` row only if the camera
/// is STILL unhealthy at that point — i.e. the outage outlasted the grace
/// period and is therefore worth paging about.
///
/// `generation` is bumped on every transition (either direction). A spawned
/// timer captures the generation at spawn time and compares it after the
/// sleep: if the generation has moved on (the detector recovered — and,
/// symmetrically, went unhealthy again in a later episode), the timer is
/// stale and must NOT emit — this is what makes the emit exactly-once per
/// sustained episode instead of once per elapsed timer, and what makes the
/// RECOVERED transition clear the pending alert instead of leaving a
/// dangling timer that pages later on an unrelated episode.
pub(crate) struct UnhealthyAlertGate {
    generation: std::sync::atomic::AtomicU64,
}

impl UnhealthyAlertGate {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            generation: std::sync::atomic::AtomicU64::new(0),
        })
    }
}

/// Report the motion detector's health to the companion recording task
/// (fail-open safety rail).
///
/// `health_tx` is a `watch` channel — `send` only errors when every receiver
/// has been dropped (the recording task is tearing down), which is not itself
/// an error worth logging. Logs the transition exactly once in each direction
/// (comparing against the previously-published value, not on every call).
///
/// The watch-channel send (and thus fail-open) happens FIRST and
/// unconditionally on a transition, regardless of the alert gate below —
/// recording correctness must never wait on hysteresis. Only the
/// `motion_detector_unhealthy` `system_events` row (migration re-uses the
/// existing `system_alert_rules` engine — see `db::insert_system_event`) is
/// gated: instead of writing it synchronously on the UNHEALTHY transition, we
/// bump `gate`'s generation and spawn a one-shot timer
/// ([`spawn_unhealthy_alert_timer`]) that emits the event only if the
/// detector is STILL unhealthy after `alert_after_secs` — see
/// [`UnhealthyAlertGate`]. The RECOVERED transition bumps the generation with
/// no timer of its own, which both clears any pending alert for the episode
/// that just ended and mirrors the existing "alert-worthy direction is
/// 'just went bad', not 'recovered'" design (a flapping detector still can't
/// spam two events per flap — recovery never alerts at all).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn report_health(
    health_tx: &MotionHealthTx,
    pool: &Pool,
    camera_id: uuid::Uuid,
    healthy: bool,
    reason: &str,
    gate: &Arc<UnhealthyAlertGate>,
    alert_after_secs: u64,
) {
    let was_healthy = *health_tx.borrow();
    if was_healthy == healthy {
        return; // no transition — don't re-notify the watch channel or spam logs/events.
    }
    // Fail-open FIRST: flip the signal immediately, unconditionally, before any
    // hysteresis bookkeeping. The recording task's `health_rx.borrow()` must
    // see this the instant a transition happens, exactly as before this change.
    if health_tx.send(healthy).is_err() {
        // Recording task's receiver dropped (worker tearing down) — nothing to
        // report to.
        return;
    }
    // Every transition (either direction) invalidates any in-flight alert
    // timer from a previous episode.
    let my_generation = gate
        .generation
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        + 1;
    if healthy {
        info!(camera_id = %camera_id, "motion detector health: RECOVERED ({reason})");
        // No timer to spawn on recovery — bumping the generation above is
        // sufficient to retire any pending unhealthy-episode timer.
    } else {
        warn!(camera_id = %camera_id, "motion detector health: UNHEALTHY ({reason}); \
              will alert in {alert_after_secs}s if still unhealthy");
        if alert_after_secs == 0 {
            // Hysteresis disabled — preserve the original immediate-alert
            // behaviour exactly.
            emit_unhealthy_alert(pool, camera_id, reason).await;
        } else {
            spawn_unhealthy_alert_timer(
                Arc::clone(gate),
                my_generation,
                health_tx.clone(),
                pool.clone(),
                camera_id,
                reason.to_owned(),
                alert_after_secs,
            );
        }
    }
}

/// Write the `motion_detector_unhealthy` `system_events` row. Split out of
/// [`report_health`] so both the `alert_after_secs == 0` (hysteresis
/// disabled) path and the deferred timer path share the exact same insert.
async fn emit_unhealthy_alert(pool: &Pool, camera_id: uuid::Uuid, reason: &str) {
    if let Err(e) = crumb_common::db::insert_system_event(
        pool,
        "motion_detector_unhealthy",
        Some(camera_id),
        Some(reason),
    )
    .await
    {
        warn!(camera_id = %camera_id, error = %e, "failed to record motion_detector_unhealthy system event");
    }
}

/// Spawn the one-shot hysteresis timer for a single unhealthy episode.
///
/// Sleeps `alert_after_secs`, then re-checks — in order — that (a) the gate's
/// generation hasn't moved on (a RECOVERED, or a later UNHEALTHY episode, has
/// superseded this one) and (b) the watch channel's current value is still
/// `false`. Both must hold for the alert to fire, which is what guarantees
/// exactly-once-per-sustained-episode: a blip that recovers before the sleep
/// elapses calls `report_health(..., true, ...)`, which bumps the generation
/// (`superseded` becomes true) and this timer becomes a no-op.
///
/// Worker teardown (`run()`'s final `report_health(..., false, "motion task
/// exiting", ...)`) cannot fabricate a spurious extra alert: in the common
/// case the task is already unhealthy when it tears down, so that call is a
/// same-value no-op in `report_health` (no transition ⇒ no generation bump,
/// no new timer spawned) and any already-running timer for the real episode
/// simply resolves against a health value that is still (correctly) `false`
/// — the camera genuinely was unhealthy for the full duration, teardown
/// included. In the rarer case teardown itself IS the healthy→unhealthy
/// transition, it spawns a fresh timer exactly like any other transition —
/// but that spawned task is dropped along with the whole process the instant
/// it exits, so it can never survive to fire after shutdown. If the process
/// exits before the sleep completes for any reason, the spawned task is
/// dropped with it — no alert is written, which is correct (nothing to page
/// about after shutdown).
#[allow(clippy::too_many_arguments)]
fn spawn_unhealthy_alert_timer(
    gate: Arc<UnhealthyAlertGate>,
    my_generation: u64,
    health_tx: MotionHealthTx,
    pool: Pool,
    camera_id: uuid::Uuid,
    reason: String,
    alert_after_secs: u64,
) {
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(alert_after_secs)).await;

        // The generation check IS the "already alerted / superseded" guard
        // for this scheme: if a RECOVERED (or a newer UNHEALTHY episode)
        // happened while we slept, `current_generation` has moved past
        // `my_generation` and this episode must be treated as already
        // resolved — feed that into the same pure decision fn the unit tests
        // exercise directly, rather than duplicating the boolean logic here.
        let current_generation = gate.generation.load(std::sync::atomic::Ordering::SeqCst);
        let superseded = current_generation != my_generation;
        let still_unhealthy = !*health_tx.borrow();
        // We just slept exactly `alert_after_secs`, so "elapsed" is trivially
        // `alert_after_secs` here — the real-world elapsed-time check already
        // happened via the sleep; `should_emit_unhealthy_alert` still gives
        // the single source of truth for the boundary/already-alerted logic
        // so the production path and the unit tests agree on the same rule.
        let should_emit = still_unhealthy
            && should_emit_unhealthy_alert(alert_after_secs, alert_after_secs, superseded);
        if !should_emit {
            return; // recovered (or a newer episode started) before the threshold — no alert.
        }
        warn!(
            camera_id = %camera_id,
            secs = alert_after_secs,
            "motion detector still unhealthy past alert threshold ({reason}); emitting alert"
        );
        emit_unhealthy_alert(&pool, camera_id, &reason).await;
    });
}

/// Pure decision used by [`spawn_unhealthy_alert_timer`] (factored out for
/// unit testing without spinning up a real timer task): given how long the
/// detector has been continuously unhealthy, the configured threshold, and
/// whether this episode has already alerted, should an alert be emitted now?
///
/// `already_alerted` exists for callers that track alert-emitted state
/// directly (rather than the generation-counter scheme `report_health` uses)
/// — included so the decision is testable independent of the async plumbing.
#[must_use]
fn should_emit_unhealthy_alert(
    unhealthy_elapsed_secs: u64,
    threshold_secs: u64,
    already_alerted: bool,
) -> bool {
    !already_alerted && unhealthy_elapsed_secs >= threshold_secs
}

/// Pure gate for the pixel detector's healthy report: a real keep/discard
/// verdict is only possible once the warm-up window has elapsed (section g's
/// `warming_up = !pixel_verdict_capable(..)` forces `motion_detected = false`
/// through frame `WARMUP_FRAMES`), so health must not flip `true` before then.
/// Reporting healthy on the first post-seed frame (the old behaviour) ended
/// fail-open while the detector was still verdict-blind — a Motion-mode camera
/// gating footage on a detector that cannot yet say KEEP, after every
/// (re)connect (correctness item 19: "detector state unknown" must resolve to
/// keep-everything, never keep-nothing).
#[must_use]
fn pixel_verdict_capable(frames_seen: u64) -> bool {
    frames_seen > WARMUP_FRAMES
}

// ─── public entry point ───────────────────────────────────────────────────────

/// Run the motion detection task for `camera` until `cancel` is triggered.
///
/// Sends [`MotionSignal`]s on `motion_tx`.  The function never panics and
/// applies exponential back-off before restarting the ffmpeg decode child on
/// any failure.
///
/// # Arguments
///
/// * `camera`    — fully-resolved camera config (with joined policy).
/// * `_pool`     — database pool (reserved for future ONVIF / Frigate-MQTT
///   sources; unused by the pixel-diff path).
/// * `config`    — global recorder config.
/// * `motion_tx` — channel sender to the companion recording task.
/// * `health_tx` — watch-channel sender reporting detector health to the
///   companion recording task (fail-open safety rail — see [`MotionHealthTx`]).
/// * `cancel`    — shared cancellation token for this camera worker.
pub async fn run(
    camera: Camera,
    pool: Pool,
    config: Config,
    motion_tx: MotionTx,
    health_tx: MotionHealthTx,
    cancel: CancellationToken,
) {
    info!(
        camera_id   = %camera.id,
        camera_name = %camera.name,
        hwaccel     = ?config.motion_hwaccel,
        "motion task started"
    );

    // Additive motion-source set (migration 0049): run one supervised loop per
    // ENABLED source and record on the UNION of their triggers (unioned in
    // recording.rs's MotionUnion). Per-source health is collapsed into the single
    // camera fail-open signal the recording task reads by `aggregate_health`.
    let alert_after_secs = config.motion_unhealthy_alert_secs;
    let camera_id = camera.id;

    let mut enabled: Vec<SourceKind> = Vec::new();
    if camera.motion_pixel_enabled {
        enabled.push(SourceKind::Pixel);
    }
    if camera.motion_frigate_enabled {
        enabled.push(SourceKind::Frigate);
    }
    if camera.motion_ha_enabled {
        enabled.push(SourceKind::Ha);
    }
    info!(
        camera_id = %camera_id,
        sources = ?enabled.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
        "motion sources (additive)"
    );

    // No source enabled on a Motion-mode camera means no detector at all: the
    // recording task must fail OPEN (record everything) for the task's whole
    // lifetime. Publish unhealthy once and idle until cancelled.
    if enabled.is_empty() {
        warn!(
            camera_id = %camera_id,
            "no motion source enabled; recording is fail-open (records everything) \
             until a source is enabled"
        );
        let gate = UnhealthyAlertGate::new();
        report_health(
            &health_tx,
            &pool,
            camera_id,
            false,
            "no motion source enabled",
            &gate,
            alert_after_secs,
        )
        .await;
        cancel.cancelled().await;
        info!(camera_id = %camera_id, "motion task exiting");
        return;
    }

    // One supervised loop per enabled source. Each publishes to its OWN per-source
    // health watch (so a per-source alert fires by name) and feeds the shared
    // motion channel; the aggregator collapses the watches into camera health.
    //
    // We keep a CLONE of every per-source health sender here (`src_txs`). A
    // panicked source task drops ITS sender clone without ever running its
    // "motion source exiting" unhealthy report — without our retained clone the
    // aggregator's watch would close on the source's last-known value (often
    // healthy) and a Motion-mode camera would stay motion-gated on a dead
    // detector, silently missing footage (correctness item 19). The retained
    // clone (a) keeps the watch channel open, (b) lets the supervision loop
    // below force the dead source unhealthy the instant its task ends, and
    // (c) lets the respawned task publish onto the SAME watch the aggregator
    // already reads.
    let mut supervisors: tokio::task::JoinSet<SourceKind> = tokio::task::JoinSet::new();
    let mut pixel_rx: Option<tokio::sync::watch::Receiver<bool>> = None;
    let mut frigate_rx: Option<tokio::sync::watch::Receiver<bool>> = None;
    let mut ha_rx: Option<tokio::sync::watch::Receiver<bool>> = None;
    let mut src_txs: std::collections::HashMap<SourceKind, MotionHealthTx> =
        std::collections::HashMap::new();
    let mut task_kinds: std::collections::HashMap<tokio::task::Id, SourceKind> =
        std::collections::HashMap::new();

    // Spawn (or respawn) ONE source task; the returned SourceKind lets the
    // supervision loop identify a cleanly-returned task, and `task_kinds` maps
    // a panicked task's id back to its source.
    let spawn_source = |supervisors: &mut tokio::task::JoinSet<SourceKind>,
                        task_kinds: &mut std::collections::HashMap<tokio::task::Id, SourceKind>,
                        kind: SourceKind,
                        src_tx: MotionHealthTx| {
        let camera = camera.clone();
        let pool = pool.clone();
        let config = config.clone();
        let motion_tx = motion_tx.clone();
        let cancel = cancel.clone();
        let handle = supervisors.spawn(async move {
            run_one_source(
                kind,
                camera,
                pool,
                config,
                motion_tx,
                src_tx,
                cancel,
                alert_after_secs,
            )
            .await;
            kind
        });
        task_kinds.insert(handle.id(), kind);
    };

    for kind in enabled.iter().copied() {
        // Start unhealthy: a source is not trusted until its loop proves healthy.
        let (src_tx, src_rx) = tokio::sync::watch::channel(false);
        match kind {
            SourceKind::Pixel => pixel_rx = Some(src_rx),
            SourceKind::Frigate => frigate_rx = Some(src_rx),
            SourceKind::Ha => ha_rx = Some(src_rx),
        }
        src_txs.insert(kind, src_tx.clone());
        spawn_source(&mut supervisors, &mut task_kinds, kind, src_tx);
    }

    // Health aggregator: collapses the per-source watches into the single camera
    // fail-open bool via the FailOpenGate rule.
    let aggregator = {
        let health_tx = health_tx.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move {
            aggregate_health(
                enabled, pixel_rx, frigate_rx, ha_rx, health_tx, camera_id, cancel,
            )
            .await;
        })
    };

    // Supervise the source tasks until cancellation (the motion-task twin of
    // main.rs's `respawn_dead_services`, audit #75). `run_one_source` loops
    // until the token fires, so a task that ends OUTSIDE shutdown died
    // unexpectedly — in practice a panic (panics unwind and kill just that
    // task's future). Without this, a panicked source never runs its exit
    // report, and a Motion-mode camera would sit motion-gated on a dead
    // detector forever (correctness item 19). On a dead source we (1) force
    // its health watch to unhealthy IMMEDIATELY — the aggregator drives the
    // camera to fail-open (record everything) while the source is down — and
    // (2) respawn it after a short delay onto the same watch.
    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            joined = supervisors.join_next_with_id() => {
                let Some(joined) = joined else {
                    // No source task left to supervise (unreachable while every
                    // dead source is respawned below); just await shutdown.
                    cancel.cancelled().await;
                    break;
                };
                if cancel.is_cancelled() {
                    break;
                }
                let kind = match joined {
                    Ok((id, kind)) => {
                        task_kinds.remove(&id);
                        warn!(
                            camera_id = %camera_id,
                            source = kind.as_str(),
                            "motion source task ended unexpectedly; failing open and respawning"
                        );
                        Some(kind)
                    }
                    Err(e) => {
                        let kind = task_kinds.remove(&e.id());
                        error!(
                            camera_id = %camera_id,
                            source = kind.map_or("unknown", SourceKind::as_str),
                            error = %e,
                            "motion source task PANICKED; failing open and respawning"
                        );
                        kind
                    }
                };
                let Some(kind) = kind else { continue };
                // Force the dead source unhealthy NOW (its panic skipped the
                // "motion source exiting" report): the aggregator must never
                // keep trusting the last-known health of a dead detector.
                if let Some(src_tx) = src_txs.get(&kind) {
                    let _ = src_tx.send(false);
                }
                // Brief pause so a source that panics on entry cannot hot-spin;
                // the source reads unhealthy (fail-open) for the whole gap.
                tokio::select! {
                    () = cancel.cancelled() => break,
                    () = tokio::time::sleep(tokio::time::Duration::from_secs(BACKOFF_BASE_SECS)) => {}
                }
                if let Some(src_tx) = src_txs.get(&kind) {
                    spawn_source(&mut supervisors, &mut task_kinds, kind, src_tx.clone());
                }
            }
        }
    }

    // Shutdown: the source loops observe the same token and exit, then the
    // aggregator (also watching the token) publishes a final unhealthy.
    while supervisors.join_next().await.is_some() {}
    let _ = aggregator.await;

    info!(camera_id = %camera_id, "motion task exiting");
}

/// Supervise ONE motion source for a camera: run its loop, apply back-off on
/// error, hot-reload on a clean (config-version) exit, and publish this source's
/// health to `health_tx` — a PER-SOURCE watch the aggregator reads, so a stuck
/// source's alert fires by name. Feeds the shared `motion_tx`. This is the old
/// single-source supervisor loop, now one instance per enabled source.
#[allow(clippy::too_many_arguments)]
async fn run_one_source(
    kind: SourceKind,
    camera: Camera,
    pool: Pool,
    config: Config,
    motion_tx: MotionTx,
    health_tx: MotionHealthTx,
    cancel: CancellationToken,
    alert_after_secs: u64,
) {
    // One hysteresis gate for this source's lifetime — every report_health call
    // below shares it so a transition retires a stale alert timer.
    let alert_gate = UnhealthyAlertGate::new();
    let mut backoff_secs = BACKOFF_BASE_SECS;

    loop {
        if cancel.is_cancelled() {
            break;
        }

        let loop_result: Result<()> = match kind {
            SourceKind::Pixel => {
                run_pixel_diff_loop(
                    &camera,
                    &pool,
                    &config,
                    &motion_tx,
                    &health_tx,
                    &cancel,
                    &alert_gate,
                    alert_after_secs,
                )
                .await
            }
            SourceKind::Frigate => {
                // Re-read Frigate settings each iteration so a live admin edit is
                // honored on the next (re)connect.
                let frigate = crumb_common::db::get_frigate_settings(&pool)
                    .await
                    .ok()
                    .flatten();
                let frigate_ver = frigate.as_ref().map_or(0, |s| s.version);
                let frigate_cfg = frigate
                    .as_ref()
                    .and_then(crate::frigate_motion::FrigateMotionConfig::from_settings);
                if let Some(ref cfg) = frigate_cfg {
                    report_decode_status(
                        &pool,
                        camera.id,
                        config.motion_hwaccel.as_str(),
                        "none",
                        Some("motion source is Frigate (no local decode)"),
                    )
                    .await;
                    // Start PESSIMISTIC: not healthy until the broker GRANTS the
                    // events subscription (SubAck) — run_frigate_motion_loop flips
                    // it healthy then. Reporting healthy here (before connecting)
                    // would make a source that can't reach the broker flap healthy
                    // on every retry and reset the fail-open grace so it never
                    // fires (issue #61, the ha_motion twin); reporting on ConnAck
                    // would trust a connection whose subscription the broker may
                    // still deny (issue #78).
                    report_health(
                        &health_tx,
                        &pool,
                        camera.id,
                        false,
                        "frigate connecting",
                        &alert_gate,
                        alert_after_secs,
                    )
                    .await;
                    let r = crate::frigate_motion::run_frigate_motion_loop(
                        &camera,
                        cfg,
                        &motion_tx,
                        &cancel,
                        &pool,
                        frigate_ver,
                        &health_tx,
                        &alert_gate,
                        alert_after_secs,
                    )
                    .await;
                    report_health(
                        &health_tx,
                        &pool,
                        camera.id,
                        false,
                        "frigate MQTT loop exited",
                        &alert_gate,
                        alert_after_secs,
                    )
                    .await;
                    r
                } else {
                    // Enabled but not configured: this source contributes nothing
                    // (unhealthy → fail-open weight). Idle, then re-check so
                    // configuring Frigate later is picked up without a restart.
                    report_health(
                        &health_tx,
                        &pool,
                        camera.id,
                        false,
                        "frigate source enabled but not configured",
                        &alert_gate,
                        alert_after_secs,
                    )
                    .await;
                    idle_before_recheck(&cancel).await;
                    Ok(())
                }
            }
            SourceKind::Ha => {
                // Re-read HA settings + this camera's motion links each iteration
                // so an admin edit hot-reloads on the next (re)connect.
                let ha_settings = crumb_common::db::get_ha_settings(&pool)
                    .await
                    .ok()
                    .flatten();
                let ha_ver = ha_settings.as_ref().map_or(0, |s| s.version);
                let ha_client = ha_settings
                    .as_ref()
                    .and_then(crumb_common::ha::HaClient::from_settings);
                let ha_links = crumb_common::db::get_camera_ha_links(&pool, camera.id, "motion")
                    .await
                    .unwrap_or_default();
                if let (Some(client), false) = (ha_client, ha_links.is_empty()) {
                    report_decode_status(
                        &pool,
                        camera.id,
                        config.motion_hwaccel.as_str(),
                        "none",
                        Some("motion source is Home Assistant (no local decode)"),
                    )
                    .await;
                    // Start PESSIMISTIC: the source is not healthy until a poll
                    // actually succeeds. run_ha_motion_loop flips it healthy on the
                    // first successful poll. Reporting healthy here (before polling)
                    // would make a failing source flap healthy on every retry and
                    // reset the fail-open grace so it never fires.
                    report_health(
                        &health_tx,
                        &pool,
                        camera.id,
                        false,
                        "ha connecting",
                        &alert_gate,
                        alert_after_secs,
                    )
                    .await;
                    let links: Vec<(String, Option<String>)> = ha_links
                        .iter()
                        .map(|l| (l.entity_id.clone(), l.device_class.clone()))
                        .collect();
                    let r = crate::ha_motion::run_ha_motion_loop(
                        &camera,
                        client,
                        links,
                        &motion_tx,
                        &cancel,
                        &pool,
                        ha_ver,
                        &health_tx,
                        &alert_gate,
                        alert_after_secs,
                    )
                    .await;
                    report_health(
                        &health_tx,
                        &pool,
                        camera.id,
                        false,
                        "ha motion loop exited",
                        &alert_gate,
                        alert_after_secs,
                    )
                    .await;
                    r
                } else {
                    report_health(
                        &health_tx,
                        &pool,
                        camera.id,
                        false,
                        "ha source enabled but HA disabled or no motion links",
                        &alert_gate,
                        alert_after_secs,
                    )
                    .await;
                    idle_before_recheck(&cancel).await;
                    Ok(())
                }
            }
        };

        match loop_result {
            Ok(()) => {
                if cancel.is_cancelled() {
                    break;
                }
                // Clean exit: a config-version reload (reconnect promptly) or a
                // not-configured re-check (already idled above). Reset back-off.
                backoff_secs = BACKOFF_BASE_SECS;
                continue;
            }
            Err(e) => {
                if cancel.is_cancelled() {
                    break;
                }
                error!(
                    camera_id = %camera.id,
                    source = kind.as_str(),
                    error = %e,
                    backoff_s = backoff_secs,
                    "motion source error; restarting after back-off"
                );
                tokio::select! {
                    _ = tokio::time::sleep(tokio::time::Duration::from_secs(backoff_secs)) => {}
                    () = cancel.cancelled() => break,
                }
                backoff_secs = (backoff_secs * 2).min(BACKOFF_MAX_SECS);
            }
        }
    }

    // The source loop is gone; the recording task must not trust a stale health.
    report_health(
        &health_tx,
        &pool,
        camera.id,
        false,
        "motion source exiting",
        &alert_gate,
        alert_after_secs,
    )
    .await;
    info!(camera_id = %camera.id, source = kind.as_str(), "motion source task exiting");
}

/// Idle a not-yet-configured source before it re-reads settings, so it neither
/// hot-spins the DB nor waits so long that configuring the integration feels
/// unresponsive.
async fn idle_before_recheck(cancel: &CancellationToken) {
    tokio::select! {
        _ = tokio::time::sleep(tokio::time::Duration::from_secs(SOURCE_RECHECK_SECS)) => {}
        () = cancel.cancelled() => {}
    }
}

/// Collapse the per-source health watches into the single camera fail-open bool
/// the recording task reads, applying the [`FailOpenGate`] rule. Re-evaluates on
/// any per-source change AND every second (so the down-past-grace clause fires on
/// time even with no new event). Publishes a final unhealthy on teardown.
async fn aggregate_health(
    enabled: Vec<SourceKind>,
    mut pixel_rx: Option<tokio::sync::watch::Receiver<bool>>,
    mut frigate_rx: Option<tokio::sync::watch::Receiver<bool>>,
    mut ha_rx: Option<tokio::sync::watch::Receiver<bool>>,
    health_tx: MotionHealthTx,
    camera_id: uuid::Uuid,
    cancel: CancellationToken,
) {
    let start = Utc::now();
    let mut gate = FailOpenGate::new(&enabled, start, DEFAULT_SOURCE_DOWN_GRACE);
    // Per-source "went down at" — sticky until the source recovers, so the grace
    // is measured from the FIRST down tick, not reset on every evaluation.
    let mut down_since: std::collections::HashMap<SourceKind, DateTime<Utc>> =
        enabled.iter().map(|&k| (k, start)).collect();
    let mut last_healthy: std::collections::HashMap<SourceKind, bool> =
        enabled.iter().map(|&k| (k, false)).collect();
    let mut last_sent: Option<bool> = None;

    let mut ticker = tokio::time::interval(tokio::time::Duration::from_secs(1));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        let now = Utc::now();
        for (kind, rx) in [
            (SourceKind::Pixel, &pixel_rx),
            (SourceKind::Frigate, &frigate_rx),
            (SourceKind::Ha, &ha_rx),
        ] {
            if !enabled.contains(&kind) {
                continue;
            }
            // An enabled source whose slot is `None` had its sender DROPPED
            // (the source task panicked/ended and `changed_opt` cleared the
            // slot). Its last-known health — often healthy — must never be
            // trusted: read it as down so the gate fails open (record
            // everything, correctness item 19) instead of leaving a
            // Motion-mode camera gated on a dead detector. Belt-and-braces:
            // `run` retains a sender clone and respawns dead sources, so this
            // path only fires if the motion task itself is dying.
            let cur = match rx {
                Some(rx) => *rx.borrow(),
                None => false,
            };
            let was = last_healthy.insert(kind, cur).unwrap_or(false);
            if !cur && was {
                down_since.insert(kind, now); // just transitioned down
            }
            if cur {
                gate.set(kind, SourceHealth::Healthy);
            } else {
                let since = *down_since.get(&kind).unwrap_or(&now);
                gate.set(kind, SourceHealth::Down { since });
            }
        }
        let camera_healthy = gate.healthy(now);
        if last_sent != Some(camera_healthy) {
            if camera_healthy {
                info!(camera_id = %camera_id, "motion health: RECOVERED (a source is healthy)");
            } else {
                warn!(
                    camera_id = %camera_id,
                    "motion health: FAIL-OPEN (no source healthy, or one down past grace)"
                );
            }
            let _ = health_tx.send(camera_healthy);
            last_sent = Some(camera_healthy);
        }

        tokio::select! {
            () = cancel.cancelled() => break,
            _ = ticker.tick() => {}
            _ = changed_opt(&mut pixel_rx) => {}
            _ = changed_opt(&mut frigate_rx) => {}
            _ = changed_opt(&mut ha_rx) => {}
        }
    }

    // Teardown: the recording task must not trust a stale healthy reading.
    let _ = health_tx.send(false);
    info!(camera_id = %camera_id, "motion health aggregator exiting");
}

/// Await the next change on an optional per-source health watch. A `None` slot
/// never resolves (that source isn't enabled); if the sender is dropped the slot
/// is cleared so it stops being polled — and the aggregator's scan reads a
/// cleared ENABLED slot as down (never its stale last value), so a dead source
/// task drives the gate to fail-open rather than freezing its last-known
/// health (correctness item 19).
async fn changed_opt(rx: &mut Option<tokio::sync::watch::Receiver<bool>>) {
    match rx {
        Some(r) => {
            if r.changed().await.is_err() {
                *rx = None;
            }
        }
        None => std::future::pending().await,
    }
}

// ─── one ffmpeg child lifetime ────────────────────────────────────────────────

/// Inner loop: probe stream, spawn ffmpeg, read frames, emit signals.
///
/// Returns:
/// * `Ok(())` — cancelled normally via the token.
/// * `Err(_)` — stream lost, pipe failure, or any recoverable error.
///   The outer [`run`] function applies back-off and calls this again.
#[allow(clippy::too_many_arguments)]
async fn run_pixel_diff_loop(
    camera: &Camera,
    pool: &Pool,
    config: &Config,
    motion_tx: &MotionTx,
    health_tx: &MotionHealthTx,
    cancel: &CancellationToken,
    alert_gate: &Arc<UnhealthyAlertGate>,
    alert_after_secs: u64,
) -> Result<()> {
    // Fail-open: every (re)entry into this function is a fresh connection
    // attempt — mark unhealthy up front so a camera stuck cycling through
    // reconnects (ffprobe timeout, stall watchdog, etc. below) is never left
    // reporting a stale "healthy" from a previous successful run. Flipped back
    // to healthy only once a real frame has been analysed (section 8 below).
    report_health(
        health_tx,
        pool,
        camera.id,
        false,
        "(re)connecting",
        alert_gate,
        alert_after_secs,
    )
    .await;

    // ── 1. Resolve sub-stream URL ─────────────────────────────────────────────
    // Cameras with no sub-stream (sub_url NULL) get no motion analysis. Do NOT
    // synthesise a <name>_sub URL that 404s and back-off-loops forever — idle
    // until the worker is cancelled.
    //
    // §6.3 / O3: `sub_url` now holds a RELATIVE stream name (e.g. "driveway_sub")
    // for cameras migrated via 0012. Legacy absolute URLs (contain "://") are
    // passed through unchanged by `resolve_stream_url`. We read server_settings
    // once here for the base, falling back to `config.go2rtc_rtsp_base`.
    let raw_sub = match camera.sub_rtsp_url_opt() {
        Some(u) => u,
        None => {
            info!(
                camera_id = %camera.id,
                "motion: camera has no sub-stream; skipping motion analysis"
            );
            // Truth telemetry: nothing is decoded for this camera at all.
            report_decode_status(
                pool,
                camera.id,
                config.motion_hwaccel.as_str(),
                "none",
                Some("camera has no sub-stream; motion analysis disabled"),
            )
            .await;
            // Fail-open: no sub-stream means motion detection is permanently
            // disabled for this camera, so a Motion-mode policy must persist
            // every segment rather than silently record nothing extra.
            report_health(
                health_tx,
                pool,
                camera.id,
                false,
                "camera has no sub-stream",
                alert_gate,
                alert_after_secs,
            )
            .await;
            cancel.cancelled().await;
            return Ok(());
        }
    };
    let (crumb_rtsp_base, frigate_rtsp_base) = resolve_rtsp_bases_motion(pool, config).await;
    // P0-GO2RTC (lighter lockdown): go2rtc's RTSP listener now requires auth for
    // non-loopback callers (the motion worker's connection crosses the Docker
    // bridge network). Only inject into the CRUMB base — frigate_rtsp_base is a
    // separate BYO instance with its own (possibly absent) credentials.
    let crumb_rtsp_base = crumb_common::db::inject_rtsp_credentials(
        &crumb_rtsp_base,
        &config.go2rtc_user,
        &config.go2rtc_pass,
    );
    let sub_url = crumb_common::db::resolve_stream_url(
        &camera.served_by,
        &raw_sub,
        &crumb_rtsp_base,
        &frigate_rtsp_base,
    );
    info!(
        camera_id = %camera.id,
        // #18-equivalent: redact embedded go2rtc creds before logging at INFO
        // (P0-GO2RTC newly embeds GO2RTC_USER/PASS here; must not leak them).
        url = %crate::recording::redact_rtsp_credentials(&sub_url),
        "motion: opening sub-stream"
    );

    // ── 2. Probe frame geometry ───────────────────────────────────────────────
    //
    // Raw video has no header; we must know WIDTH×HEIGHT before reading frames.
    // We run ffprobe on the sub-stream to get the native resolution and compute
    // the scaled height.  If ffprobe fails we fall back to the 16:9 default.
    //
    // The probe is wrapped in a timeout (FFPROBE_TIMEOUT_SECS) so that a
    // temporarily-offline camera (or a go2rtc stream whose producer hasn't
    // connected yet) doesn't block the motion loop indefinitely.  On timeout we
    // fall back to the 16:9 default and let the frame-loop watchdogs handle
    // further reconnects — returning Err here causes run() to back-off-retry
    // which re-enters this probe and tries again.
    // Timeout wraps the inner function (which already respects `cancel`
    // internally).  The timeout fires when the camera is unreachable or
    // go2rtc's producer hasn't connected yet; in that case we return Err
    // so run() applies back-off and retries.  On a clean cancel the inner
    // function returns Ok(()) before the timeout, which propagates here.
    let height = match tokio::time::timeout(
        std::time::Duration::from_secs(FFPROBE_TIMEOUT_SECS),
        probe_frame_height(&sub_url, cancel),
    )
    .await
    {
        Ok(Ok(h)) => {
            debug!(camera_id = %camera.id, height = h, "ffprobe detected height");
            h
        }
        Ok(Err(e)) => {
            if cancel.is_cancelled() {
                return Ok(());
            }
            warn!(
                camera_id = %camera.id,
                error     = %e,
                fallback  = MOTION_FRAME_HEIGHT_FALLBACK,
                "ffprobe failed; using fallback height"
            );
            MOTION_FRAME_HEIGHT_FALLBACK
        }
        Err(_elapsed) => {
            if cancel.is_cancelled() {
                return Ok(());
            }
            // Probe timed out: the upstream camera is unreachable or go2rtc's
            // producer hasn't connected yet.  Return Err so run() backs off and
            // retries — the per-frame watchdogs can only fire once we are inside
            // the frame loop, so the probe itself needs its own deadline.
            return Err(anyhow::anyhow!(
                "motion ffprobe timed out after {}s; \
                 sub-stream may be offline — forcing reconnect",
                FFPROBE_TIMEOUT_SECS
            ));
        }
    };

    // ── 3. NVDEC semaphore / hardware acceleration ────────────────────────────
    //
    // Correctness item 11: acquire one permit before opening an NVDEC session.
    // Fall back to CPU decode if the semaphore is exhausted.
    //
    // HwAccel::Auto (§6.2 / O3): probe whether NVDEC is actually usable in this
    // container via `nvdec_available()` (OnceLock-cached). On a GPU-absent host
    // the probe returns false and we fall through to CPU, so a plain
    // `docker compose up` (no GPU overlay) never tries cuda and fails.
    let want_cuda = match config.motion_hwaccel {
        HwAccel::Cpu | HwAccel::Vaapi => false,
        HwAccel::Cuda => true,
        HwAccel::Auto => crumb_common::config::nvdec_available(),
    };
    // VAAPI (Intel/AMD iGPU) decode is an explicit opt-in. It shares neither the
    // NVDEC semaphore nor the cuda filter path: the iGPU decodes the sub-stream and
    // ffmpeg downloads frames to system memory, so the analysis-side video filter
    // is identical to the CPU path (only the pre-input -hwaccel flags differ).
    //
    // Safety for the admin toggle: VAAPI is now selectable from the admin UI, but
    // the DRI render node must be mapped into the container (the vaapi compose
    // overlay). If an operator picks VAAPI without that mapping, degrade to CPU
    // decode instead of looping on an ffmpeg device-creation error forever.
    let use_vaapi = matches!(config.motion_hwaccel, HwAccel::Vaapi) && {
        let present = std::path::Path::new(&config.motion_vaapi_device).exists();
        if !present {
            warn!(
                camera_id = %camera.id,
                device = %config.motion_vaapi_device,
                "VAAPI selected but the render node is not present in the container; \
                 falling back to CPU decode (map it via the vaapi compose overlay)"
            );
        }
        present
    };
    let (use_cuda, _permit): (bool, Option<tokio::sync::OwnedSemaphorePermit>) = if want_cuda {
        match try_acquire_nvdec() {
            Some(permit) => {
                debug!(camera_id = %camera.id, "acquired NVDEC permit");
                (true, Some(permit))
            }
            None => {
                warn!(
                    camera_id = %camera.id,
                    "NVDEC semaphore exhausted; falling back to CPU decode"
                );
                (false, None)
            }
        }
    } else {
        (false, None)
    };

    // ── 3b. Report decode-backend truth (telemetry; migration 0035) ───────────
    //
    // `active` is derived from the SAME booleans that build the ffmpeg args
    // below, so it can never disagree with what the child is launched with.
    // Runs on every (re)connect — the upsert is one cheap indexed write and
    // reconnects are back-off-limited.
    //
    // Honesty note: this reports launch-time truth (requested backend + device
    // presence + semaphore outcome), not ffmpeg's runtime init result. The one
    // known launch-vs-runtime gap — explicit `cuda` on a build/host without
    // usable NVDEC — is called out explicitly below.
    let active = if use_cuda {
        "cuda"
    } else if use_vaapi {
        "vaapi"
    } else {
        "cpu"
    };
    let fallback_reason: Option<String> = if want_cuda && !use_cuda {
        Some("NVDEC session limit reached (MAX_GPU_DECODE_SESSIONS); decoding on CPU".to_owned())
    } else {
        match config.motion_hwaccel {
            HwAccel::Vaapi if !use_vaapi => Some(format!(
                "{} not present in the recorder container; decoding on CPU \
                 (map it via the vaapi compose overlay, e.g. docker-compose.vaapi.example.yml)",
                config.motion_vaapi_device
            )),
            HwAccel::Cuda if use_cuda && !crumb_common::config::nvdec_available() => Some(
                "cuda requested and launched, but ffmpeg reports no cuda hwaccel in this \
                 container — decode will likely fail and retry (map the GPU via the gpu \
                 compose overlay, e.g. docker-compose.gpu.example.yml)"
                    .to_owned(),
            ),
            HwAccel::Auto if !want_cuda => {
                Some("auto: NVDEC not detected in this container; using CPU decode".to_owned())
            }
            _ => None,
        }
    };
    report_decode_status(
        pool,
        camera.id,
        config.motion_hwaccel.as_str(),
        active,
        fallback_reason.as_deref(),
    )
    .await;

    // ── 4. Build ffmpeg argument list ─────────────────────────────────────────
    //
    // Correctness item 16: we output raw 8-bit grayscale frames to stdout and
    // diff them natively — no OpenCV.
    //
    // Correctness item 5: stderr is piped so a separate task can drain it.
    //
    // CUDA decode path:
    //   -hwaccel cuda -hwaccel_output_format cuda
    //   -vf scale_cuda=320:HEIGHT,hwdownload,format=gray
    //
    // CPU decode path:
    //   -vf scale=320:HEIGHT,format=gray
    //
    // We pass the explicit height (derived from ffprobe above) instead of `-2`
    // so we know the exact frame_size before reading any bytes.
    let keyframes_only = camera.policy.motion_keyframes_only;

    let mut args: Vec<String> = vec![
        "-hide_banner".to_owned(),
        "-loglevel".to_owned(),
        "warning".to_owned(),
    ];

    // Hardware decode flags — must appear before -i.
    if use_cuda {
        args.push("-hwaccel".to_owned());
        args.push("cuda".to_owned());
        args.push("-hwaccel_output_format".to_owned());
        args.push("cuda".to_owned());
    } else if use_vaapi {
        // Decode on the iGPU's fixed-function block. We deliberately do NOT set
        // `-hwaccel_output_format vaapi`: letting ffmpeg auto-download decoded
        // frames to system memory means the downstream filter (fps/scale/gray)
        // runs on the CPU exactly as in the software path — the proven, low-risk
        // chain — while the expensive decode still happens on the iGPU.
        args.push("-hwaccel".to_owned());
        args.push("vaapi".to_owned());
        args.push("-hwaccel_device".to_owned());
        args.push(config.motion_vaapi_device.clone());
    }

    // Low-latency input — never let the demux/decoder accumulate a backlog.
    // A continuously-running motion decoder on a bursty/jittery sub-stream can
    // otherwise drift seconds behind real time, which delays detection and
    // pushes the timeline motion marks late (observed on the LPR PTZ's
    // direct-RTSP sub, ~2-4 s). Drop stale frames instead of queuing them —
    // motion detection wants freshness, not every frame. Applies to EVERY
    // camera's motion task, so any camera added later gets it automatically.
    args.push("-fflags".to_owned());
    args.push("nobuffer".to_owned());
    args.push("-flags".to_owned());
    args.push("low_delay".to_owned());

    // Input.
    args.push("-rtsp_transport".to_owned());
    args.push("tcp".to_owned());
    args.push("-i".to_owned());
    args.push(sub_url);

    // Keyframe-only decode (reduces CPU; lower temporal resolution).
    if keyframes_only {
        args.push("-skip_frame".to_owned());
        args.push("noref".to_owned());
    }

    // Video filter: cap analysis rate + downscale to analysis resolution +
    // convert to 8-bit gray.
    //
    // The `fps=` filter DROPS frames (not dups) so analysis work is reduced
    // without altering the output frame size or pixel format.
    //
    // CPU & VAAPI paths: fps first (drops before scale → cheapest), then scale,
    // gray. VAAPI decodes on the iGPU and ffmpeg auto-downloads the frames, so the
    // filter chain is software in both cases (only the -hwaccel flags differ).
    //
    // CUDA path: scale on GPU, download to host (nv12 intermediate REQUIRED —
    // going straight to format=gray fails with -22 Invalid argument, which
    // silently killed all NVDEC motion), then fps drop on CPU, then gray.
    // Explicit height avoids any ambiguity about what `-2` would produce.
    let vf = if use_cuda {
        format!(
            "scale_cuda={}:{},hwdownload,format=nv12,fps={},format=gray",
            MOTION_FRAME_WIDTH, height, MOTION_ANALYSIS_FPS
        )
    } else {
        format!(
            "fps={},scale={}:{},format=gray",
            MOTION_ANALYSIS_FPS, MOTION_FRAME_WIDTH, height
        )
    };
    args.push("-vf".to_owned());
    args.push(vf);

    // Raw video output to stdout.
    args.push("-f".to_owned());
    args.push("rawvideo".to_owned());
    args.push("-pix_fmt".to_owned());
    args.push("gray".to_owned());
    args.push("pipe:1".to_owned());

    // ── 5. Spawn the ffmpeg child ─────────────────────────────────────────────
    let mut child = Command::new("ffmpeg")
        .args(&args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        // kill_on_drop is a secondary safety net; we kill explicitly on cancel.
        .kill_on_drop(true)
        .spawn()
        .context("failed to spawn ffmpeg for motion decode")?;

    let mut stdout = child
        .stdout
        .take()
        .context("ffmpeg motion child has no stdout")?;

    let stderr = child
        .stderr
        .take()
        .context("ffmpeg motion child has no stderr")?;

    // ── 6. Drain stderr in a separate task (correctness item 5) ──────────────
    //
    // ffmpeg's stderr OS pipe buffer is ~64 KB.  If it fills, ffmpeg blocks on
    // stderr writes → our frame reader on stdout stalls → deadlock (and the
    // NVDEC session + VRAM leak indefinitely).  We drain stderr line-by-line in
    // a background task, logging at DEBUG level.
    let camera_id_log = camera.id;
    let stderr_handle = tokio::spawn(async move {
        drain_motion_stderr(stderr, camera_id_log).await;
    });

    // ── 7. Initialise per-loop state ──────────────────────────────────────────
    let w = MOTION_FRAME_WIDTH as usize;
    let h = height as usize;
    let frame_size = w * h;
    let total_pixels = frame_size as f32;

    // Load the persisted baseline so the learner starts already-trained.
    // On error (first run / missing row) fall back to a cold-start learner.
    let mut dyn_sens = match crumb_common::db::load_motion_baseline(pool, camera.id).await {
        Ok(Some(state)) => {
            info!(camera_id = %camera.id, "motion: loaded persisted baseline (warm start)");
            AdaptiveThreshold::from_baseline(&state)
        }
        Ok(None) => {
            info!(camera_id = %camera.id, "motion: no baseline found; cold start");
            AdaptiveThreshold::new()
        }
        Err(e) => {
            warn!(camera_id = %camera.id, error = %e, "motion: baseline load error; cold start");
            AdaptiveThreshold::new()
        }
    };

    // Frame-receipt watchdog: wall-clock timestamp of the last successfully
    // decoded frame.  Initialised to `now` so new workers get a full
    // FRAME_RECEIPT_TIMEOUT_SECS grace window before the first frame must arrive
    // (covers gap #2 — live-reconfig half-init where ffmpeg stalls without
    // producing any output; also serves as the init deadline so a never-
    // connecting worker self-heals instead of hanging forever).
    let mut last_frame_decoded = std::time::Instant::now();

    // Per-camera motion detector — owns the background model and the foreground
    // primitive (Census by default). Everything below this is the shared,
    // algorithm-agnostic pipeline.
    let mut detector = build_detector(camera, frame_size);
    let mut frames_seen: u64 = 0;

    let mut curr_frame = vec![0u8; frame_size];

    // ── Active-pixel map (precomputed once) ──────────────────────────────────
    // `active_mask[i] = 1` means "compute this pixel"; `0` means "masked/skip".
    // Built from `camera.motion_mask` using the same `apply_mask` logic that
    // was previously applied per-frame.  The motion worker is respawned on any
    // mask change (via the camera-change signal), so this only needs to be built
    // once per worker lifetime.
    //
    // Convergence note: pixels that are unmasked after being masked start with
    // a stale background model and re-converge over a few frames (like a fresh
    // region).  This is acceptable because the worker respawns on mask change
    // anyway, resetting all model state.
    let active_mask: Vec<u8> = {
        let mut am = vec![1u8; frame_size];
        if let Some(ref mask_val) = camera.motion_mask {
            // apply_mask zeroes excluded pixels — invert the semantics so
            // `active_mask[i] = 0` means masked/skip.
            apply_mask(&mut am, MOTION_FRAME_WIDTH, height, mask_val);
        }
        am
    };

    // Reused per-frame scratch buffers (allocated once; see design §6).
    // `raw_mask` is no longer needed: the detector now writes masked pixels as 0
    // directly, so a single `mask` buffer holds the post-exclusion result.
    let mut mask = vec![0u8; frame_size]; // foreground mask (post-exclusion)
    let mut eroded = vec![0u8; frame_size];
    let mut dilated = vec![0u8; frame_size];
    let mut dilate_tmp = vec![0u8; frame_size];
    let mut labels = vec![0u32; frame_size];
    let mut parent: Vec<u32> = Vec::with_capacity(1024);
    let mut areas: Vec<u32> = Vec::with_capacity(1024);

    let mut motion_state = MotionState::Idle;
    let mut peak_score: f32 = 0.0;
    // Normalized [x,y,w,h] bbox of the largest motion blob at the event's
    // peak-score frame so far. Captured at START and refreshed whenever a stronger
    // frame is seen; emitted on STOP so recording.rs can stamp the segment.
    let mut event_bbox: Option<[f32; 4]> = None;
    let mut motion_started_at: Option<DateTime<Utc>> = None;
    let mut below_threshold_count: usize = 0;
    // Consecutive above-floor frames while Idle — gates the Idle→Active dwell.
    let mut above_floor_count: usize = 0;
    // Throttle for publishing the live motion-tuner grid. The DB write runs in a
    // detached task (never on the frame-decode path); this flag skips a tick when
    // a prior write is still in flight.
    let mut last_grid_write = std::time::Instant::now();
    let grid_write_inflight = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));

    // ── Adaptive-rate state ────────────────────────────────────────────────────
    // When the scene has been quiet for QUIET_SECS, we skip analysis on every
    // other decoded frame (~2.5 fps), reducing detector CPU by ~50 % during
    // idle cameras.  Full-rate analysis (every frame, ~5 fps) resumes the
    // instant motion is detected or we are still within the QUIET_SECS window.
    //
    // `analysis_frame_count` counts frames that reached analysis (after the
    // fps-filter drop by ffmpeg); `last_motion_instant` is the Instant of the
    // most recent frame where `motion_detected` was true.
    let mut analysis_frame_count: u64 = 0;
    let mut last_motion_instant: Option<std::time::Instant> = None;

    // ── 8. Frame loop ─────────────────────────────────────────────────────────
    // Tracks whether the loop ended because the stream closed (EOF) rather than a
    // genuine cancellation — the two share the same clean-up path but differ in
    // the return value (EOF must force a reconnect, cancellation must not).
    let mut stream_ended = false;
    loop {
        // Check cancellation before every frame read (correctness item 6).
        if cancel.is_cancelled() {
            break;
        }

        // Frame-receipt watchdog (independent of the per-frame stall below).
        // Fires when too much wall-clock time passes since the last DECODED frame,
        // covering the case where partial pipe bytes reset the stall-read timeout
        // without ever completing a frame.  Also fires as an init deadline for a
        // fresh or live-reconfig-restarted worker that stalls before decoding
        // frame #1 (gap #2).  The stall watchdog below fires first in the common
        // case (12 s < 15 s); this is a backstop for the edge case.
        if last_frame_decoded.elapsed().as_secs() >= FRAME_RECEIPT_TIMEOUT_SECS {
            report_health(
                health_tx,
                pool,
                camera.id,
                false,
                "frame-receipt watchdog fired",
                alert_gate,
                alert_after_secs,
            )
            .await;
            return Err(anyhow::anyhow!(
                "motion sub-stream receipt timeout: no decoded frame for {}s; forcing reconnect",
                FRAME_RECEIPT_TIMEOUT_SECS
            ));
        }

        // Read one full frame — or break if the token fires. The read is wrapped
        // in a stall watchdog: if no frame arrives within FRAME_STALL_TIMEOUT_SECS
        // the sub-stream has silently stalled (socket open, no data, no EOF), so
        // we return Err to drop out of this loop and let the outer run() apply
        // back-off and RECONNECT — which a silent stall never triggers on its own.
        let frame_ready = tokio::select! {
            r = tokio::time::timeout(
                std::time::Duration::from_secs(FRAME_STALL_TIMEOUT_SECS),
                read_exact_frame(&mut stdout, &mut curr_frame),
            ) => {
                match r {
                    Ok(inner) => inner.context("reading motion frame from ffmpeg stdout")?,
                    Err(_elapsed) => {
                        report_health(
                            health_tx,
                            pool,
                            camera.id,
                            false,
                            "frame-stall watchdog fired",
                            alert_gate,
                            alert_after_secs,
                        )
                        .await;
                        return Err(anyhow::anyhow!(
                            "motion sub-stream stalled: no frame for {}s; forcing reconnect",
                            FRAME_STALL_TIMEOUT_SECS
                        ));
                    }
                }
            }
            () = cancel.cancelled() => {
                break;
            }
        };

        if !frame_ready {
            info!(camera_id = %camera.id, "motion: stream EOF");
            stream_ended = true;
            break;
        }

        // A complete frame arrived: reset the receipt watchdog.
        last_frame_decoded = std::time::Instant::now();

        frames_seen += 1;

        // ── a. Seed / hold the background model ────────────────────────────────
        // Seed `bg` from the FIRST decoded frame (not zeros — zeros would read the
        // opening frame as full-frame motion). We diff against the PRE-update `bg`
        // and update it at the end of the frame (section j).
        if detector.seed_if_needed(&curr_frame) {
            continue; // seed frame — nothing to compare yet
        }

        // Fail-open recovery: report healthy only once the warm-up window has
        // elapsed — the first frame where a keep/discard verdict is actually
        // possible. Analysing frames is not enough: through `WARMUP_FRAMES`
        // section g forces `motion_detected = false`, so a healthy report on
        // the first post-seed frame (the old behaviour) opened a "healthy but
        // verdict-blind" window after every (re)connect in which Motion mode
        // gated footage on a detector that could not yet say KEEP (correctness
        // item 19). Cheap to call every frame; `report_health` no-ops after
        // the first transition since the value no longer changes.
        if pixel_verdict_capable(frames_seen) {
            report_health(
                health_tx,
                pool,
                camera.id,
                true,
                "analysing frames (warm-up complete)",
                alert_gate,
                alert_after_secs,
            )
            .await;
        }

        // ── a2. Adaptive-rate skip (Part B) ────────────────────────────────────
        // When the scene has been quiet for QUIET_SECS, we skip analysis on every
        // other analysis-eligible frame to reduce detector CPU to ~2.5 fps.  The
        // instant any processed frame detects motion the full rate resumes.
        //
        // `analysis_frame_count` counts frames that actually reach this point
        // (post-seed, post-ffmpeg-fps-filter).  Skipped frames are just discarded
        // — no foreground, no model update, no learner observation.
        analysis_frame_count += 1;
        if !should_process_frame(analysis_frame_count, last_motion_instant) {
            continue;
        }

        // ── b. Foreground mask — ILLUMINATION-INVARIANT census transform ──────
        // Compares the local intensity ORDERING (3×3 census) of curr vs the
        // background, not raw brightness — so a lighting change (sun/shade
        // boundary, cloud, auto-exposure) that uniformly darkens/brightens a
        // region produces NO motion, while a real object that changes the local
        // texture/silhouette does. (Was raw `|curr − bg| > 25`, which fired on
        // any lighting change — the sun/shade false-trigger.)
        //
        // `active_mask` is precomputed once at worker start (see above).
        // Masked pixels are skipped inside the detector (no foreground compute,
        // no background-model update for that pixel) and are written as 0.
        // The tuner heatmap therefore shows 0 under excluded regions — matching
        // Frigate's behaviour; the client-side red mask overlay is unchanged.
        detector.foreground(&curr_frame, w, h, &active_mask, &mut mask);

        // ── d. Lightning gate (whole-frame illumination change) ───────────────
        // If most of the frame is foreground, it's an IR cut / headlight sweep /
        // lights-on, not an object — emit no motion and let `bg` re-converge fast.
        let on_pixels = mask.iter().filter(|&&v| v != 0).count();
        let lightning = (on_pixels as f32 / total_pixels) > LIGHTNING_FRACTION;

        // ── e. Morphology: erode (denoise) → dilate ×N (bridge into one blob) ──
        erode_mask(&mask, &mut eroded, w, h);
        dilate_mask(&eroded, &mut dilated, w, h);
        for _ in 1..DILATE_ITERS {
            std::mem::swap(&mut dilated, &mut dilate_tmp);
            dilate_mask(&dilate_tmp, &mut dilated, w, h);
        }

        // ── f. Connected components → largest blob → score ────────────────────
        // The score is the LARGEST single connected region's area as a fraction of
        // the frame — a compact-object measure, NOT a global changed-pixel count
        // (which can't tell scattered noise from one person). This same number
        // drives the trigger, the timeline `motion_score`, and the tuner meter.
        let largest_blob =
            connected_components(&dilated, w, h, &mut labels, &mut parent, &mut areas);
        let score = largest_blob as f32 / total_pixels;

        // ── g. Decision: largest-blob fraction vs the effective floor ─────────
        // Kept in lockstep with the healthy report above: verdict-capable and
        // "no longer warming up" are the same predicate by construction.
        let warming_up = !pixel_verdict_capable(frames_seen);

        // Adaptive threshold: drive recompute on a ~15 s wall-clock schedule.
        // `now` here is the Utc timestamp used by the state machine below — the
        // same value is forwarded to recompute for the diurnal hour-of-day update.
        let frame_now = Utc::now();
        if matches!(camera.policy.motion_sensitivity, MotionSensitivity::Dynamic)
            && dyn_sens.recompute_due()
        {
            dyn_sens.recompute(frame_now);
        }

        let effective_floor: f32 = match camera.policy.motion_sensitivity {
            MotionSensitivity::Dynamic => dyn_sens.floor(),
            MotionSensitivity::Manual => manual_floor(camera.policy.motion_threshold),
        };
        let motion_detected = !warming_up && !lightning && score >= effective_floor;

        // Update the adaptive-rate "last motion" timer so the half-rate quiet
        // mode is suppressed whenever motion is present.
        if motion_detected {
            last_motion_instant = Some(std::time::Instant::now());
        }

        // Feed EVERY frame to the learner (not just background frames).
        // This is the key fix: the learner must SEE recurring nuisance frames
        // so the 97th-percentile floor can rise above them.  A sustained real
        // event is ≤~3% of a 2 h horizon and cannot move the 97th percentile
        // up into the real-event band.
        if matches!(camera.policy.motion_sensitivity, MotionSensitivity::Dynamic) && !warming_up {
            dyn_sens.observe(score);
        }

        // Periodic baseline persist (best-effort: log + continue on error).
        if matches!(camera.policy.motion_sensitivity, MotionSensitivity::Dynamic)
            && dyn_sens.persist_due()
        {
            dyn_sens.mark_persisted();
            let state = dyn_sens.to_baseline();
            let p = pool.clone();
            let cam_id = camera.id;
            tokio::spawn(async move {
                if let Err(e) = crumb_common::db::upsert_motion_baseline(&p, cam_id, &state).await {
                    warn!(camera_id = %cam_id, error = %e, "motion: baseline persist failed (non-fatal)");
                }
            });
        }

        // ── h. Publish the live tuner grid + coherent meter (throttled ~2 Hz) ──
        // The display grid is the detector's FINE foreground (post-exclusion,
        // post-morphology) downsampled to MOTION_GRID_COLS×ROWS as 0..100 %
        // coverage — so the tuner paints the actual changing pixels (green), with
        // excluded zones already removed (the client draws those red), instead of
        // coarse boxes. `score` + `effective_floor` are published alongside so the
        // tuner meter, the threshold marker, the recording trigger, and the
        // timeline are all the SAME quantity. Detached upsert; a prior in-flight
        // write skips this tick (never block the stdout pipe — correctness item 5).
        if last_grid_write.elapsed().as_millis() >= MOTION_GRID_WRITE_MS
            && !grid_write_inflight.load(std::sync::atomic::Ordering::Relaxed)
        {
            last_grid_write = std::time::Instant::now();
            let grid = compute_fg_grid(&dilated, w, h, MOTION_GRID_COLS, MOTION_GRID_ROWS);
            let cells = serde_json::Value::Array(
                grid.iter().map(|&v| serde_json::Value::from(v)).collect(),
            );
            grid_write_inflight.store(true, std::sync::atomic::Ordering::Relaxed);
            let p = pool.clone();
            let cam_id = camera.id;
            let flag = std::sync::Arc::clone(&grid_write_inflight);
            let pub_score = score;
            let pub_thr = effective_floor;
            tokio::spawn(async move {
                if let Err(e) = crumb_common::db::write_motion_grid(
                    &p,
                    cam_id,
                    MOTION_GRID_COLS as i16,
                    MOTION_GRID_ROWS as i16,
                    &cells,
                    pub_score,
                    pub_thr,
                )
                .await
                {
                    debug!(camera_id = %cam_id, error = %e, "write_motion_grid failed");
                }
                flag.store(false, std::sync::atomic::Ordering::Relaxed);
            });
        }

        // ── i. Motion state machine ───────────────────────────────────────────
        let now = frame_now;

        match motion_state {
            MotionState::Idle => {
                // Require MOTION_START_FRAMES consecutive above-floor frames before
                // starting an event — suppresses single-frame spikes.
                if motion_detected {
                    above_floor_count += 1;
                } else {
                    above_floor_count = 0;
                }

                if motion_detected && above_floor_count >= MOTION_START_FRAMES {
                    motion_state = MotionState::Active;
                    motion_started_at = Some(now);
                    peak_score = score;
                    below_threshold_count = 0;
                    above_floor_count = 0;

                    // Capture WHERE the motion is at the start frame (the labels
                    // from this frame's connected_components are still current).
                    event_bbox = normalized_largest_bbox(&labels, &mut parent, &areas, w, h);

                    // Emit START signal (stopped_at = None means in progress) +
                    // this source's own labeled 'motion' events row.
                    emit_pixel_signal(
                        motion_tx,
                        pool,
                        MotionSignal {
                            camera_id: camera.id,
                            started_at: now,
                            stopped_at: None,
                            peak_score: score,
                            bbox: event_bbox,
                        },
                    )
                    .await;

                    debug!(
                        camera_id = %camera.id,
                        score,
                        threshold = effective_floor,
                        largest_blob,
                        "motion STARTED"
                    );
                }
            }

            MotionState::Active => {
                if score > peak_score {
                    peak_score = score;
                    // New strongest frame → re-capture the motion region so the
                    // stored bbox tracks the most prominent moment of the event.
                    if let Some(b) = normalized_largest_bbox(&labels, &mut parent, &areas, w, h) {
                        event_bbox = Some(b);
                    }
                }

                if motion_detected {
                    below_threshold_count = 0;
                } else {
                    below_threshold_count += 1;

                    if below_threshold_count >= MOTION_STOP_HYSTERESIS {
                        let started_at = motion_started_at.unwrap_or(now);

                        // Emit STOP signal + update this source's 'motion' row.
                        emit_pixel_signal(
                            motion_tx,
                            pool,
                            MotionSignal {
                                camera_id: camera.id,
                                started_at,
                                stopped_at: Some(now),
                                peak_score,
                                bbox: event_bbox,
                            },
                        )
                        .await;

                        debug!(
                            camera_id  = %camera.id,
                            peak_score,
                            "motion STOPPED"
                        );

                        // Reset state.
                        motion_state = MotionState::Idle;
                        peak_score = 0.0;
                        motion_started_at = None;
                        below_threshold_count = 0;
                    }
                }
            }
        }

        // ── j. Update the background model (EMA) ──────────────────────────────
        // Rate by state: fast on a lightning frame so `bg` re-converges to the new
        // lighting; near-frozen during an active event so a paused subject is not
        // absorbed into the background (recording keeps running while they stand
        // still); slow otherwise to track gradual lighting drift.
        // Masked pixels (active_mask[i] == 0) are skipped inside commit — their
        // model state is frozen and will re-converge when first unmasked.
        detector.commit(
            &curr_frame,
            FrameContext {
                lightning,
                event_active: matches!(motion_state, MotionState::Active),
            },
            &active_mask,
        );
    }

    // ── 9. Shutdown clean-up (correctness items 5 & 6) ───────────────────────
    //
    // Kill the child immediately; do NOT wait for more output.
    if let Err(e) = child.kill().await {
        // kill() returns Err when the process already exited — that is fine.
        debug!(
            camera_id = %camera.id,
            error     = %e,
            "motion ffmpeg kill (process may have already exited)"
        );
    }

    // If motion was in-progress when we cancelled, emit a synthetic STOP so
    // recording.rs can close out the event and write the correct end timestamp.
    if motion_state == MotionState::Active {
        if let Some(started_at) = motion_started_at {
            emit_pixel_signal(
                motion_tx,
                pool,
                MotionSignal {
                    camera_id: camera.id,
                    started_at,
                    stopped_at: Some(Utc::now()),
                    peak_score,
                    bbox: event_bbox,
                },
            )
            .await;
        }
    }

    // Wait for the stderr drain task (exits when stderr pipe closes).
    let _ = stderr_handle.await;

    // Reap the child process.
    let _ = child.wait().await;

    // If the loop ended because the sub-stream CLOSED (ffmpeg EOF) rather than a
    // real cancellation, return Err so the outer run() applies back-off and
    // RECONNECTS. An RTSP drop or transient ffmpeg exit closes stdout → EOF; the
    // old code returned Ok(()) here, which run() treated as "cancelled cleanly"
    // and exited the task permanently — motion stayed dead for that camera until
    // the recorder restarted (prod 2026-06-17: Front Door + Backdoor).
    if stream_ended && !cancel.is_cancelled() {
        return Err(anyhow::anyhow!(
            "motion sub-stream ended (ffmpeg EOF); forcing reconnect"
        ));
    }

    Ok(())
}

// ─── geometry probe ───────────────────────────────────────────────────────────

/// Probe the sub-stream with `ffprobe` to compute the exact scaled height.
///
/// Raw video has no header, so we must know `WIDTH × HEIGHT` before spawning
/// the decode child.  We run a fast `ffprobe` on the sub-stream to get the
/// native resolution, then calculate the height that `scale=320:HEIGHT` will
/// use.
///
/// # Returns
///
/// `Ok(height)` — the exact pixel height that ffmpeg will produce.
///
/// # Errors
///
/// Returns `Err` if `ffprobe` is not on `PATH`, the stream is unreachable,
/// the output cannot be parsed, or the cancellation token fires.
async fn probe_frame_height(sub_url: &str, cancel: &CancellationToken) -> Result<u32> {
    // ffprobe -v error -select_streams v:0
    //         -show_entries stream=width,height
    //         -of default=noprint_wrappers=1:nokey=1
    //         -rtsp_transport tcp
    //         -read_intervals "%+#1"   ← read just enough to get stream info
    //         -i <sub_url>
    //
    // Outputs two lines:  native_width\n  native_height\n
    let mut probe_child = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            "-rtsp_transport",
            "tcp",
            "-read_intervals",
            "%+#1",
            "-i",
            sub_url,
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context("failed to spawn ffprobe for sub-stream geometry")?;

    let mut probe_stdout = probe_child.stdout.take().context("ffprobe has no stdout")?;

    // Read all output, cancellably.
    let raw = tokio::select! {
        r = read_all_bytes(&mut probe_stdout) => r?,
        () = cancel.cancelled() => {
            let _ = probe_child.kill().await;
            return Err(anyhow::anyhow!("cancelled during ffprobe geometry probe"));
        }
    };
    let _ = probe_child.wait().await;

    let text = String::from_utf8_lossy(&raw);
    let mut non_empty_lines = text.lines().filter(|l| !l.trim().is_empty());

    let native_w: u32 = non_empty_lines
        .next()
        .and_then(|l| l.trim().parse().ok())
        .context("ffprobe did not output a parseable native width")?;

    let native_h: u32 = non_empty_lines
        .next()
        .and_then(|l| l.trim().parse().ok())
        .context("ffprobe did not output a parseable native height")?;

    anyhow::ensure!(
        native_w > 0 && native_h > 0,
        "ffprobe returned zero dimensions ({}×{}); stream may have no video",
        native_w,
        native_h
    );

    // Calculate the scaled height: proportional to native aspect ratio, rounded
    // to the nearest even integer (ffmpeg's `-2` rounding rule).
    let scaled_raw = (MOTION_FRAME_WIDTH as f64 * native_h as f64 / native_w as f64).round() as u32;
    let scaled_h = if scaled_raw.is_multiple_of(2) {
        scaled_raw
    } else {
        scaled_raw + 1
    };

    Ok(scaled_h.clamp(2, 4096))
}

/// Read all available bytes from `reader` into a `Vec<u8>`.
async fn read_all_bytes(reader: &mut (impl AsyncReadExt + Unpin)) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = reader.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        out.extend_from_slice(&chunk[..n]);
    }
    Ok(out)
}

/// Read exactly one frame (`buf.len()` bytes) from `reader`.
///
/// Returns:
/// * `Ok(true)`  — buffer filled: frame is complete.
/// * `Ok(false)` — EOF before or during the frame (stream ended).
/// * `Err(_)`    — I/O error.
async fn read_exact_frame(
    reader: &mut (impl AsyncReadExt + Unpin),
    buf: &mut [u8],
) -> Result<bool> {
    let mut total = 0usize;
    while total < buf.len() {
        let n = reader.read(&mut buf[total..]).await?;
        if n == 0 {
            return Ok(false);
        }
        total += n;
    }
    Ok(true)
}

/// Consecutive read errors after which [`drain_motion_stderr`] gives up. An
/// `Err` from a pipe read is transient by nature (EOF is delivered as `Ok(0)`,
/// not `Err`), so this bound only exists to keep a pathological fd from
/// spinning the drain task forever — which would also hang the worker's
/// teardown `stderr_handle.await`.
const STDERR_DRAIN_MAX_CONSECUTIVE_ERRORS: u32 = 100;

/// Drain the motion ffmpeg child's stderr to DEBUG logs until EOF, returning
/// the number of lines drained (exercised by tests).
///
/// Drains BYTES (`read_until`), NOT UTF-8 lines: ffmpeg's stderr is not
/// guaranteed to be valid UTF-8 (stream metadata, dumped packet bytes), and
/// the previous `read_line` failed the whole read on the first invalid byte,
/// ending the drain early — the pipe closed while ffmpeg kept writing, ffmpeg
/// blocked on the full ~64 KB pipe buffer, and the stdout frame reader stalled:
/// the exact deadlock this task exists to prevent (correctness item 5). Lines
/// are rendered lossily for logging; a read error is logged and skipped (with
/// a short pause, bounded by [`STDERR_DRAIN_MAX_CONSECUTIVE_ERRORS`]) rather
/// than ending the drain, because only EOF (`Ok(0)` — the child exited) means
/// there is nothing left to drain.
async fn drain_motion_stderr(
    stderr: impl tokio::io::AsyncRead + Unpin,
    camera_id: uuid::Uuid,
) -> u64 {
    let mut reader = tokio::io::BufReader::new(stderr);
    let mut line: Vec<u8> = Vec::new();
    let mut drained: u64 = 0;
    let mut consecutive_errors: u32 = 0;
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line).await {
            Ok(0) => break, // EOF — ffmpeg has exited.
            Ok(_) => {
                consecutive_errors = 0;
                drained += 1;
                let text = String::from_utf8_lossy(&line);
                let trimmed = text.trim_end();
                if !trimmed.is_empty() {
                    debug!(
                        camera_id     = %camera_id,
                        ffmpeg_stderr = trimmed,
                        "motion ffmpeg"
                    );
                }
            }
            Err(e) => {
                // Do NOT break while the child may still be alive — an
                // abandoned stderr pipe recreates the fill-and-deadlock this
                // task prevents. Pause briefly so a persistently erroring fd
                // cannot busy-spin, and give up only past the error bound.
                consecutive_errors += 1;
                debug!(
                    camera_id = %camera_id,
                    error     = %e,
                    consecutive_errors,
                    "motion ffmpeg stderr drain error (continuing)"
                );
                if consecutive_errors >= STDERR_DRAIN_MAX_CONSECUTIVE_ERRORS {
                    warn!(
                        camera_id = %camera_id,
                        "motion ffmpeg stderr drain giving up after repeated errors"
                    );
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        }
    }
    drained
}

// ─── motion state ─────────────────────────────────────────────────────────────

/// Internal state of the per-frame motion detector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MotionState {
    Idle,
    Active,
}

// ─── signal helper ────────────────────────────────────────────────────────────

/// Try to send a [`MotionSignal`] on `tx`; log a warning if the channel is full.
///
/// The channel is bounded at [`MOTION_CHANNEL_CAPACITY`](crate::MOTION_CHANNEL_CAPACITY)
/// (256).  Using `try_send` prevents the frame-diff loop from blocking, which
/// would stall the stdout pipe and eventually deadlock ffmpeg (correctness
/// item 5).
#[inline]
fn send_signal(tx: &MotionTx, signal: MotionSignal, camera_id: uuid::Uuid) {
    if let Err(e) = tx.try_send(signal) {
        warn!(
            camera_id = %camera_id,
            error     = %e,
            "motion channel full; signal dropped"
        );
    }
}

/// Emit a pixel [`MotionSignal`] AND persist its `'motion'` `events` row.
///
/// Under additive motion sources `recording.rs` no longer writes event rows —
/// each source owns its own surfacing (pixel → `'motion'`, HA → `'ha'`/
/// device-class, Frigate → its detection rows). The signal is sent FIRST (it
/// drives footage via the buffer); the labeled row is best-effort — a DB error
/// is logged and ignored, exactly as the generic write was before, so a failed
/// surfacing row can never cost a segment.
async fn emit_pixel_signal(tx: &MotionTx, pool: &Pool, signal: MotionSignal) {
    let camera_id = signal.camera_id;
    send_signal(tx, signal.clone(), camera_id);
    if let Err(e) = crumb_common::db::upsert_motion_event(pool, &signal).await {
        warn!(camera_id = %camera_id, error = %e, "failed to persist pixel motion event");
    }
}

// ─── public frame-diff primitives ────────────────────────────────────────────

/// Compute the per-pixel absolute difference between two grayscale frames.
///
/// Both slices must have identical length (`width × height` bytes).
/// The result is written into `dst` in-place.
///
/// Operates entirely on `&[u8]` byte slices — **no OpenCV** (correctness
/// item 16).
///
/// In release builds `u8::abs_diff` is branchless and typically compiles to
/// a single `PSUBB`-family SIMD instruction when auto-vectorised.
///
/// # Examples
///
/// ```ignore
/// let prev = vec![100u8; 4];
/// let curr = vec![150u8; 4];
/// let mut dst = vec![0u8; 4];
/// frame_absdiff(&prev, &curr, &mut dst);
/// assert_eq!(dst, vec![50, 50, 50, 50]);
/// ```
pub fn frame_absdiff(prev: &[u8], curr: &[u8], dst: &mut [u8]) {
    let n = prev.len().min(curr.len()).min(dst.len());
    for i in 0..n {
        dst[i] = prev[i].abs_diff(curr[i]);
    }
}

/// Count pixels in `diff` that strictly exceed `threshold`.
///
/// # Examples
///
/// ```ignore
/// let diff = vec![0u8, 50, 100, 200];
/// assert_eq!(count_above_threshold(&diff, 75), 2);
/// ```
pub fn count_above_threshold(diff: &[u8], threshold: u8) -> usize {
    diff.iter().filter(|&&p| p > threshold).count()
}

/// Minimum number of the 8 neighbours that must ALSO be "changed" for a changed
/// pixel to survive the denoise. This is a RELAXED erosion: full erosion (all 8)
/// is too destructive on our small 320-px-wide motion frame — a person crossing a
/// wide view is only a ~6–12 px-wide blob, and full erosion shaves it away. A
/// majority-style threshold (≥4 of 8) deletes scattered speckle (isolated noise
/// has ~0 changed neighbours, a 2×2 noise cluster has only 3) while keeping ~80 %
/// of a real subject's blob (edges have ≥5 changed neighbours).
const MIN_NEIGHBOURS_ON: u32 = 4;

/// Count "changed" pixels after a relaxed 3×3 denoise of the binary
/// `diff > threshold` mask: a pixel counts only if it changed AND at least
/// [`MIN_NEIGHBOURS_ON`] of its 8 neighbours also changed.
///
/// # Why
///
/// The raw changed-pixel fraction cannot tell a real moving subject from noise:
/// sensor grain, AGC flicker, compression artefacts and timestamp-edge shimmer
/// scatter SINGLE changed pixels all over the frame, which on a wide 4K view can
/// sum to 2–3 % — forcing a high area floor that then also rejects a *person*
/// (who, on the 320-px motion frame, is well under 1 %). This denoise deletes the
/// isolated speckle (no changed neighbours → dropped) while preserving the solid
/// blob of a person/vehicle, so the area floor can drop low enough to catch real
/// subjects without the noise swamping it.
///
/// Border pixels (no full 3×3 neighbourhood) are never counted; on tiny frames it
/// falls back to the un-denoised count.
pub fn count_eroded_above_threshold(diff: &[u8], width: u32, height: u32, threshold: u8) -> usize {
    let w = width as usize;
    let h = height as usize;
    if w < 3 || h < 3 || diff.len() < w * h {
        return count_above_threshold(diff, threshold);
    }
    let on = |i: usize| u32::from(diff[i] > threshold);
    let mut count = 0usize;
    for y in 1..(h - 1) {
        let row = y * w;
        let up = row - w;
        let down = row + w;
        for x in 1..(w - 1) {
            if diff[row + x] <= threshold {
                continue;
            }
            let neighbours = on(row + x - 1)
                + on(row + x + 1)
                + on(up + x)
                + on(up + x - 1)
                + on(up + x + 1)
                + on(down + x)
                + on(down + x - 1)
                + on(down + x + 1);
            if neighbours >= MIN_NEIGHBOURS_ON {
                count += 1;
            }
        }
    }
    count
}

/// Minimum Manual-mode floor (fraction of frame): 0.05 % of frame area.
const MANUAL_FLOOR_MIN: f32 = 0.0005;
/// Maximum Manual-mode floor (fraction of frame): 5 % of frame area.
const MANUAL_FLOOR_MAX: f32 = 0.05;

/// Manual-mode motion floor (fraction of frame area).
///
/// `motion_threshold` is stored as a FRACTION (0..1) — the SAME unit as the
/// largest-blob `score`, so the comparison `score >= floor` is a direct
/// like-for-like, no conversion. `None` ⇒ the blob-area default ([`BLOB_FRACTION`]
/// = 0.30 %). Clamped to `[MANUAL_FLOOR_MIN, MANUAL_FLOOR_MAX]` (0.05 %–5 %) as a
/// defensive guard against an out-of-range stored value.
fn manual_floor(motion_threshold: Option<f32>) -> f32 {
    motion_threshold
        .unwrap_or(BLOB_FRACTION)
        .clamp(MANUAL_FLOOR_MIN, MANUAL_FLOOR_MAX)
}

/// EMA-update the background model in place: `bg = bg·(1−α) + curr·α`.
fn update_background(bg: &mut [f32], curr: &[u8], alpha: f32) {
    let keep = 1.0 - alpha;
    for (b, &c) in bg.iter_mut().zip(curr.iter()) {
        *b = *b * keep + c as f32 * alpha;
    }
}

/// EMA-update the background model for ACTIVE pixels only.
///
/// Pixels where `active[i] == 0` are skipped — their background value is
/// frozen so a newly-unmasked pixel re-converges from its last known state
/// rather than from stale-during-masked zero.
fn update_background_active(bg: &mut [f32], curr: &[u8], alpha: f32, active: &[u8]) {
    let keep = 1.0 - alpha;
    for ((b, &c), &a) in bg.iter_mut().zip(curr.iter()).zip(active.iter()) {
        if a != 0 {
            *b = *b * keep + c as f32 * alpha;
        }
    }
}

/// Threshold `|curr − bg|` into a binary foreground mask (0 or 255). Every output
/// byte is assigned, so the caller may reuse `mask` across frames. Retained for
/// the census dark-region fallback's semantics and the unit tests.
fn threshold_mask_vs_bg(curr: &[u8], bg: &[f32], thr: f32, mask: &mut [u8]) {
    for ((m, &c), &b) in mask.iter_mut().zip(curr.iter()).zip(bg.iter()) {
        *m = if (c as f32 - b).abs() > thr { 255 } else { 0 };
    }
}

/// 3×3 neighbour offsets used by the census transform (any consistent order works
/// — only whether each neighbour's "darker than centre" sign FLIPS between curr
/// and bg matters, and the count of flips is the Hamming distance).
const CENSUS_NEIGHBOURS: [(isize, isize); 8] = [
    (-1, -1),
    (0, -1),
    (1, -1),
    (1, 0),
    (1, 1),
    (0, 1),
    (-1, 1),
    (-1, 0),
];

/// ILLUMINATION-INVARIANT foreground mask via the 3×3 census transform — the
/// replacement for raw-luma `threshold_mask_vs_bg` in the live detector.
///
/// For each interior pixel we count how many of its 8 neighbours change their
/// "darker than the centre?" relationship between the current frame and the
/// background model (`bg`). That sign pattern (the census signature) depends only
/// on the local ORDERING of intensities, which is invariant under any monotone
/// brightness/contrast change: a shadow (or cloud, or auto-exposure step) scales a
/// whole region's luma roughly uniformly, leaving every ordering — and thus every
/// census bit — unchanged, so the flat interior of a shadow yields ZERO foreground.
/// A real object replaces the local texture and adds a silhouette edge, flipping
/// bits → foreground.
///
/// A pixel is foreground iff Hamming ≥ [`CENSUS_HAMMING_THRESH`] AND it also moved
/// more than [`CENSUS_ABS_GUARD`] luma (a noise-floor band; a uniformly-lit region
/// has Hamming ≈ 0 regardless of luma delta, so this band can only remove false
/// positives, never create the shadow one). Where `bg` is below
/// [`CENSUS_DARK_FLOOR`] the bits are noise-dominated, so we fall back to plain
/// `|curr − bg|` for that pixel. The 1-pixel border is forced to 0 (no full 3×3
/// window), matching erosion's border handling.
fn census_mask_vs_bg(curr: &[u8], bg: &[f32], w: usize, h: usize, active: &[u8], mask: &mut [u8]) {
    for m in mask.iter_mut() {
        *m = 0; // border (and everything) starts off
    }
    if w < 3 || h < 3 {
        return;
    }
    let dark_fallback_thr = PIXEL_DIFF_THRESHOLD_DYNAMIC as f32;
    for y in 1..(h - 1) {
        for x in 1..(w - 1) {
            let i = y * w + x;

            // Skip masked pixels — output is already 0 from the init loop above.
            if active[i] == 0 {
                continue;
            }

            let cf = curr[i] as f32;
            let bf = bg[i];

            // Deep shadow / high-gain IR: census bits are noise — use raw diff.
            if bf < CENSUS_DARK_FLOOR {
                mask[i] = if (cf - bf).abs() > dark_fallback_thr {
                    255
                } else {
                    0
                };
                continue;
            }

            // Quantise BOTH sides to i16 and compare with a signed TIE-BAND. `curr`
            // is a u8 frame (= round(bg+Δ) under a uniform light change); `bg` is
            // fractional f32. Comparing them on the SAME integer scale (not f32 vs
            // u8) is what keeps their orderings matched; the band then absorbs the
            // residual ±1 rounding so near-ties on a smooth gradient can't
            // spuriously flip bits and re-create the lighting false-positive.
            let cc = curr[i] as i16;
            let cb = bf as i16;
            let mut flips: u8 = 0;
            for &(dx, dy) in CENSUS_NEIGHBOURS.iter() {
                let j = ((y as isize + dy) as usize) * w + ((x as isize + dx) as usize);
                let curr_darker = (cc - curr[j] as i16) > CENSUS_TIE_BAND;
                let bg_darker = (cb - bg[j] as i16) > CENSUS_TIE_BAND;
                if curr_darker != bg_darker {
                    flips += 1;
                }
            }

            let abs_ok = (cf - bf).abs() > CENSUS_ABS_GUARD;
            mask[i] = if flips >= CENSUS_HAMMING_THRESH && abs_ok {
                255
            } else {
                0
            };
        }
    }
}

/// 3×3 erosion of a binary mask: an on-pixel survives only if at least
/// [`MIN_NEIGHBOURS_ON`] of its 8 neighbours are also on. Deletes isolated/2×2
/// speckle (sensor grain, AGC flicker, compression edges) before labeling. Border
/// pixels (no full 3×3 neighbourhood) are eroded to 0. Every output byte is
/// assigned, so `dst` may be reused across frames.
fn erode_mask(src: &[u8], dst: &mut [u8], w: usize, h: usize) {
    for v in dst.iter_mut() {
        *v = 0;
    }
    if w < 3 || h < 3 {
        return;
    }
    for y in 1..(h - 1) {
        let row = y * w;
        let up = row - w;
        let down = row + w;
        for x in 1..(w - 1) {
            let i = row + x;
            if src[i] == 0 {
                continue;
            }
            let on = |j: usize| u32::from(src[j] != 0);
            let neighbours = on(i - 1)
                + on(i + 1)
                + on(up + x - 1)
                + on(up + x)
                + on(up + x + 1)
                + on(down + x - 1)
                + on(down + x)
                + on(down + x + 1);
            if neighbours >= MIN_NEIGHBOURS_ON {
                dst[i] = 255;
            }
        }
    }
}

/// 3×3 dilation of a binary mask: a pixel turns on if it or any of its 8
/// neighbours is on. Run a couple of times this bridges the gaps inside a moving
/// body so it labels as ONE blob. Every output byte is assigned (reusable `dst`).
fn dilate_mask(src: &[u8], dst: &mut [u8], w: usize, h: usize) {
    for y in 0..h {
        let row = y * w;
        for x in 0..w {
            let i = row + x;
            let mut on = src[i] != 0;
            if !on {
                let y0 = y.saturating_sub(1);
                let y1 = (y + 1).min(h - 1);
                let x0 = x.saturating_sub(1);
                let x1 = (x + 1).min(w - 1);
                'scan: for ny in y0..=y1 {
                    let nrow = ny * w;
                    for nx in x0..=x1 {
                        if src[nrow + nx] != 0 {
                            on = true;
                            break 'scan;
                        }
                    }
                }
            }
            dst[i] = if on { 255 } else { 0 };
        }
    }
}

/// Disjoint-set find with path halving.
#[inline]
fn cc_find(parent: &mut [u32], mut x: u32) -> u32 {
    while parent[x as usize] != x {
        let gp = parent[parent[x as usize] as usize];
        parent[x as usize] = gp;
        x = gp;
    }
    x
}

/// Disjoint-set union (attach the larger root index under the smaller).
#[inline]
fn cc_union(parent: &mut [u32], a: u32, b: u32) {
    let ra = cc_find(parent, a);
    let rb = cc_find(parent, b);
    if ra != rb {
        let (lo, hi) = if ra < rb { (ra, rb) } else { (rb, ra) };
        parent[hi as usize] = lo;
    }
}

/// Two-pass connected-component labeling (union-find, 4-connectivity) over a
/// binary mask. Returns the **largest connected blob's pixel area**. Scratch
/// buffers (`labels`, `parent`, `areas`) are caller-owned and reused across
/// frames; `labels` must be `w·h` long.
///
/// 4-connectivity (left + up neighbours) is sufficient after dilation has already
/// bridged a body into one region, and is cheaper than 8-connectivity.
fn connected_components(
    mask: &[u8],
    w: usize,
    h: usize,
    labels: &mut [u32],
    parent: &mut Vec<u32>,
    areas: &mut Vec<u32>,
) -> u32 {
    parent.clear();
    parent.push(0); // index 0 = background crumb; first real label is 1
    let mut next: u32 = 1;

    // Pass 1: provisional labels + unions.
    for y in 0..h {
        let row = y * w;
        for x in 0..w {
            let i = row + x;
            if mask[i] == 0 {
                labels[i] = 0;
                continue;
            }
            let left = if x > 0 { labels[i - 1] } else { 0 };
            let up = if y > 0 { labels[i - w] } else { 0 };
            labels[i] = match (left, up) {
                (0, 0) => {
                    let l = next;
                    parent.push(l);
                    next += 1;
                    l
                }
                (l, 0) => l,
                (0, u) => u,
                (l, u) => {
                    if l != u {
                        cc_union(parent, l, u);
                    }
                    l
                }
            };
        }
    }

    // Pass 2: resolve roots, accumulate area, track the maximum.
    areas.clear();
    areas.resize(parent.len(), 0);
    let mut largest = 0u32;
    for &lbl in labels.iter().take(w * h) {
        if lbl == 0 {
            continue;
        }
        let root = cc_find(parent, lbl) as usize;
        areas[root] += 1;
        if areas[root] > largest {
            largest = areas[root];
        }
    }
    largest
}

/// Bounding box (in analysis-frame pixel coords) of the LARGEST connected
/// component, reusing the `labels`/`parent`/`areas` produced by the most recent
/// [`connected_components`] call over the SAME `dilated` mask. Returns
/// `(x, y, w, h)`, or `None` if there is no foreground.
///
/// This is a second pass over `labels` and runs ONLY when a new peak-motion frame
/// is seen during an active event (rare), so it never touches the steady-state
/// detector hot path and cannot affect the golden-test output.
fn largest_blob_bbox(
    labels: &[u32],
    parent: &mut [u32],
    areas: &[u32],
    w: usize,
    h: usize,
) -> Option<(usize, usize, usize, usize)> {
    // The largest blob's root is the `areas` index holding the maximum count
    // (only roots accumulate area in pass 2 of connected_components).
    let mut best_root = 0u32;
    let mut best_area = 0u32;
    for (root, &a) in areas.iter().enumerate() {
        if a > best_area {
            best_area = a;
            best_root = root as u32;
        }
    }
    if best_area == 0 {
        return None;
    }

    let (mut min_x, mut min_y, mut max_x, mut max_y) = (w, h, 0usize, 0usize);
    let mut found = false;
    for y in 0..h {
        let base = y * w;
        for x in 0..w {
            let lbl = labels[base + x];
            if lbl == 0 {
                continue;
            }
            if cc_find(parent, lbl) == best_root {
                found = true;
                if x < min_x {
                    min_x = x;
                }
                if x > max_x {
                    max_x = x;
                }
                if y < min_y {
                    min_y = y;
                }
                if y > max_y {
                    max_y = y;
                }
            }
        }
    }
    if !found {
        return None;
    }
    Some((min_x, min_y, max_x - min_x + 1, max_y - min_y + 1))
}

/// [`largest_blob_bbox`] normalized to 0..1 fractions of the frame (`[x,y,w,h]`),
/// resolution-independent so the same value works for any clip-render size.
/// `None` when there is no foreground or the frame has zero extent.
fn normalized_largest_bbox(
    labels: &[u32],
    parent: &mut [u32],
    areas: &[u32],
    w: usize,
    h: usize,
) -> Option<[f32; 4]> {
    if w == 0 || h == 0 {
        return None;
    }
    let (bx, by, bw, bh) = largest_blob_bbox(labels, parent, areas, w, h)?;
    let (fw, fh) = (w as f32, h as f32);
    Some([
        bx as f32 / fw,
        by as f32 / fh,
        bw as f32 / fw,
        bh as f32 / fh,
    ])
}

/// Downsample a binary foreground `mask` to a `cols × rows` row-major grid of
/// 0..100 % coverage (the % of each cell's pixels that are foreground), for the
/// live motion tuner display. Anti-aliases the foreground edges so a fine grid
/// reads as "the pixels that are changing" rather than hard boxes.
fn compute_fg_grid(mask: &[u8], w: usize, h: usize, cols: usize, rows: usize) -> Vec<u8> {
    let mut grid = vec![0u8; cols * rows];
    if w == 0 || h == 0 {
        return grid;
    }
    for gy in 0..rows {
        let y0 = gy * h / rows;
        let y1 = (((gy + 1) * h / rows).max(y0 + 1)).min(h);
        for gx in 0..cols {
            let x0 = gx * w / cols;
            let x1 = (((gx + 1) * w / cols).max(x0 + 1)).min(w);
            let mut on = 0usize;
            let mut total = 0usize;
            for y in y0..y1 {
                let base = y * w;
                for x in x0..x1 {
                    total += 1;
                    if mask[base + x] != 0 {
                        on += 1;
                    }
                }
            }
            grid[gy * cols + gx] = (on * 100).checked_div(total).unwrap_or(0) as u8;
        }
    }
    grid
}

/// Apply a motion mask to a diff frame — zero out pixels inside EXCLUDED zones.
///
/// `mask` is the deserialized `cameras.motion_mask` JSONB column: a JSON array
/// of exclusion regions to IGNORE during motion analysis. Two element shapes are
/// accepted (sniffed per element):
///
/// * **Normalized rectangle** (preferred, what the clients now author):
///   `[x, y, w, h]` — each value 0..1 as a fraction of the frame. Resolution-
///   independent, so the same mask works regardless of the sub-stream size.
/// * **Legacy polygon**: `[[x, y], [x, y], …]` in scaled-frame PIXEL coords
///   (≥3 points). Detected when the first element is itself an array.
///
/// Pixels inside any excluded region are zeroed and do not contribute to the
/// motion score.
///
/// * `diff`   — mutable diff buffer (`width × height` bytes, row-major).
/// * `width`  — frame width in pixels (of the scaled sub-stream).
/// * `height` — frame height in pixels.
/// * `mask`   — parsed from `camera.motion_mask`.
pub fn apply_mask(diff: &mut [u8], width: u32, height: u32, mask: &serde_json::Value) {
    let regions = match mask.as_array() {
        Some(arr) if !arr.is_empty() => arr,
        _ => return,
    };

    for region in regions {
        let elems = match region.as_array() {
            Some(e) if !e.is_empty() => e,
            _ => continue,
        };
        // Shape sniff: first element an array → legacy polygon; else normalized rect.
        if elems[0].is_array() {
            apply_polygon(diff, width, height, elems);
        } else {
            apply_norm_rect(diff, width, height, elems);
        }
    }
}

/// Zero a normalized `[x, y, w, h]` rectangle (each 0..1) in the diff buffer.
fn apply_norm_rect(diff: &mut [u8], width: u32, height: u32, rect: &[serde_json::Value]) {
    if rect.len() < 4 {
        return;
    }
    let get = |i: usize| {
        rect.get(i)
            .and_then(serde_json::Value::as_f64)
            .unwrap_or(0.0) as f32
    };
    let (x, y, w, h) = (get(0), get(1), get(2), get(3));
    if w <= 0.0 || h <= 0.0 {
        return;
    }
    let col_start = ((x * width as f32).floor().max(0.0) as u32).min(width);
    let col_end = (((x + w) * width as f32).ceil().max(0.0) as u32).min(width);
    let row_start = ((y * height as f32).floor().max(0.0) as u32).min(height);
    let row_end = (((y + h) * height as f32).ceil().max(0.0) as u32).min(height);
    for row in row_start..row_end {
        let base = (row * width) as usize;
        for col in col_start..col_end {
            let idx = base + col as usize;
            if idx < diff.len() {
                diff[idx] = 0;
            }
        }
    }
}

/// Legacy pixel-polygon mask (even-odd ray cast). Retained for backward compat.
fn apply_polygon(diff: &mut [u8], width: u32, height: u32, points_json: &[serde_json::Value]) {
    let pts: Vec<(f32, f32)> = points_json
        .iter()
        .filter_map(|p| {
            let arr = p.as_array()?;
            let x = arr.first()?.as_f64()? as f32;
            let y = arr.get(1)?.as_f64()? as f32;
            Some((x, y))
        })
        .collect();

    if pts.len() < 3 {
        return;
    }

    // Bounding box for fast per-row skip.
    let min_x = pts.iter().map(|p| p.0).fold(f32::INFINITY, f32::min);
    let max_x = pts.iter().map(|p| p.0).fold(f32::NEG_INFINITY, f32::max);
    let min_y = pts.iter().map(|p| p.1).fold(f32::INFINITY, f32::min);
    let max_y = pts.iter().map(|p| p.1).fold(f32::NEG_INFINITY, f32::max);

    let row_start = (min_y.floor().max(0.0) as u32).min(height);
    let row_end = (max_y.ceil().max(0.0) as u32).min(height);
    let col_start = (min_x.floor().max(0.0) as u32).min(width);
    let col_end = (max_x.ceil().max(0.0) as u32).min(width);

    let n = pts.len();

    for row in row_start..row_end {
        let py = row as f32 + 0.5;

        for col in col_start..col_end {
            let px = col as f32 + 0.5;

            let mut inside = false;
            let mut j = n - 1;
            for i in 0..n {
                let (xi, yi) = pts[i];
                let (xj, yj) = pts[j];
                if (yi > py) != (yj > py) {
                    let x_cross = (xj - xi) * (py - yi) / (yj - yi) + xi;
                    if px < x_cross {
                        inside = !inside;
                    }
                }
                j = i;
            }

            if inside {
                let idx = (row * width + col) as usize;
                if idx < diff.len() {
                    diff[idx] = 0;
                }
            }
        }
    }
}

// ─── adaptive (history-learning) motion threshold ────────────────────────────

/// Minimum score threshold — clamp floor so the learner can never go below the
/// hard blob-area floor during a genuinely quiet scene.
const MIN_THRESHOLD: f32 = BLOB_FRACTION;

/// Maximum score threshold — hard ceiling for pathologically noisy cameras.
const MAX_THRESHOLD: f32 = 0.5;

/// Pre-computed per-recompute decay factor: `2^(-RECOMPUTE_INTERVAL_MIN /
/// HORIZON_MIN)`.  Applied once per `recompute` call to all bucket weights and
/// `total`, equivalent to an exponential window with the given half-life.
///
/// Computed at runtime on first construction (no `f32::powf` in const).
fn decay_factor(elapsed_min: f32) -> f32 {
    // 2^(-elapsed / half_life)  ≡  exp(-ln2 * elapsed / half_life)
    (-core::f32::consts::LN_2 * elapsed_min / AT_HORIZON_MIN).exp()
}

/// Map a score value to a histogram bucket index.
///
/// Bucket 0 is the "quiet" bin (score < `BLOB_FRACTION`).
/// Buckets 1–`AT_NB-1` are geometric over `[BLOB_FRACTION, MAX_THRESHOLD]`.
///
/// Returns a value in `0..AT_NB`.
fn score_to_bucket(score: f32) -> usize {
    if score < BLOB_FRACTION {
        return 0;
    }
    // Geometric mapping: log ratio into [0, NB-1] span (buckets 1..AT_NB-1
    // plus bucket 0 for quiet), giving finer resolution in the nuisance band.
    let lo = BLOB_FRACTION.ln();
    let hi = MAX_THRESHOLD.ln();
    let t = (score.clamp(BLOB_FRACTION, MAX_THRESHOLD).ln() - lo) / (hi - lo);
    // Map to [1, AT_NB-1] — bucket 0 is reserved for quiet.
    1 + ((t * (AT_NB - 1) as f32) as usize).min(AT_NB - 2)
}

/// Return the score at the lower edge of bucket `b`.
fn bucket_lower_edge(b: usize) -> f32 {
    if b == 0 {
        return 0.0;
    }
    let lo = BLOB_FRACTION.ln();
    let hi = MAX_THRESHOLD.ln();
    // Inverse of score_to_bucket: t = (b - 1) / (AT_NB - 1)
    let t = (b - 1) as f32 / (AT_NB - 1) as f32;
    (lo + t * (hi - lo)).exp()
}

/// Per-camera adaptive motion-threshold learner.
///
/// Replaces the old `DynamicSensitivity` (`mean + 3σ` over a 300-frame deque).
///
/// ## Algorithm
///
/// * **`hist[AT_NB]`** — a decaying histogram of per-frame largest-blob scores.
///   Bucket 0 is the quiet bin (score < `BLOB_FRACTION`); buckets 1–63 are
///   geometric over `[BLOB_FRACTION, MAX_THRESHOLD]`.  Weights decay
///   exponentially with half-life [`AT_HORIZON_MIN`] (~120 min) so the
///   learner tracks weather and lighting without thrashing on old data.
///
/// * **`diurnal[24]`** — per-hour-of-day EMA of the computed floor.  Learns
///   that "02:00 headlights normally need floor X" over days.  Updated each
///   `recompute` with step size [`AT_DIURNAL_ALPHA`].
///
/// * **`floor`** — the current effective floor, clamped to
///   `[MIN_THRESHOLD, MAX_THRESHOLD]`.
///
/// ## Per-frame cost
///
/// `observe` is O(1) — one array index + two f32 adds.  `recompute` (called
/// every [`AT_RECOMPUTE_SECS`]) does a single 64-element scan.
pub struct AdaptiveThreshold {
    /// Decaying histogram bucket weights (f32).  Index 0 = quiet frames.
    hist: [f32; AT_NB],
    /// Sum of all bucket weights (kept in sync to avoid a full scan each decay).
    total: f32,
    /// Per-hour-of-day EMA floor (UTC hour, 0–23).
    diurnal: [f32; 24],
    /// Current effective floor (returned by [`Self::floor`]).
    floor: f32,
    /// Wall time of the last `recompute` call (used to schedule the next one
    /// and to compute the decay exponent).
    last_recompute: std::time::Instant,
    /// Timestamp of the last persistence UPSERT (used to schedule the next one).
    last_persist: std::time::Instant,
}

impl AdaptiveThreshold {
    /// Create a fresh learner (cold start).
    ///
    /// `floor` starts at [`MIN_THRESHOLD`]; it will climb after a few minutes
    /// of observing the scene's nuisance band.
    pub fn new() -> Self {
        let now = std::time::Instant::now();
        Self {
            hist: [0.0_f32; AT_NB],
            total: 0.0,
            diurnal: [MIN_THRESHOLD; 24],
            floor: MIN_THRESHOLD,
            last_recompute: now,
            last_persist: now,
        }
    }

    /// Create a learner seeded from a previously-persisted baseline.
    ///
    /// Uses the stored histogram and diurnal profile so the first `recompute`
    /// produces a meaningful floor instead of the cold-start minimum.
    pub fn from_baseline(state: &MotionBaselineState) -> Self {
        let now = std::time::Instant::now();
        let mut hist = [0.0_f32; AT_NB];
        let len = state.hist.len().min(AT_NB);
        for (i, &v) in state.hist[..len].iter().enumerate() {
            hist[i] = v as f32;
        }
        let mut diurnal = [MIN_THRESHOLD; 24];
        let dlen = state.diurnal.len().min(24);
        for (i, &v) in state.diurnal[..dlen].iter().enumerate() {
            diurnal[i] = (v as f32).clamp(MIN_THRESHOLD, MAX_THRESHOLD);
        }
        Self {
            hist,
            total: state.total as f32,
            diurnal,
            floor: MIN_THRESHOLD,
            last_recompute: now,
            last_persist: now,
        }
    }

    /// Snapshot the current learner state for persistence.
    pub fn to_baseline(&self) -> MotionBaselineState {
        MotionBaselineState {
            hist: self.hist.iter().map(|&v| f64::from(v)).collect(),
            diurnal: self.diurnal.iter().map(|&v| f64::from(v)).collect(),
            total: f64::from(self.total),
        }
    }

    /// Record one frame's score.  O(1) — one array lookup and two f32 adds.
    ///
    /// Feed **every** frame (including motion-active frames).  The 97th-percentile
    /// floor is robust to the ≤3% of frames that are real events.
    pub fn observe(&mut self, score: f32) {
        let b = score_to_bucket(score);
        self.hist[b] += 1.0;
        self.total += 1.0;
    }

    /// Recompute the effective floor.
    ///
    /// Should be called approximately every [`AT_RECOMPUTE_SECS`] seconds.
    /// Uses `now` for the diurnal update's hour-of-day.
    ///
    /// Steps:
    /// 1. Decay all bucket weights (exponential window, half-life
    ///    [`AT_HORIZON_MIN`]).
    /// 2. Walk the CDF to find the [`AT_PERCENTILE`]th-percentile score.
    /// 3. Update `diurnal[hour]` with a slow EMA step.
    /// 4. Set `floor = clamp(max(live, diurnal[hour]), MIN, MAX)`.
    pub fn recompute(&mut self, now: DateTime<Utc>) {
        let elapsed = self.last_recompute.elapsed();
        self.last_recompute = std::time::Instant::now();

        // 1. Decay.
        let elapsed_min = elapsed.as_secs_f32() / 60.0;
        let decay = decay_factor(elapsed_min);
        for w in &mut self.hist {
            *w *= decay;
        }
        self.total *= decay;

        // 2. Percentile scan.
        let live = if self.total < 1e-6 {
            // No data yet — stay at the minimum floor.
            MIN_THRESHOLD
        } else {
            let target = self.total * AT_PERCENTILE;
            let mut cumulative = 0.0_f32;
            let mut live_floor = MIN_THRESHOLD;
            for (b, &w) in self.hist.iter().enumerate() {
                cumulative += w;
                if cumulative >= target {
                    live_floor = bucket_lower_edge(b);
                    break;
                }
            }
            live_floor
        };

        // 3. Diurnal EMA update.
        let hour = now.hour() as usize; // 0..=23 UTC
        self.diurnal[hour] =
            AT_DIURNAL_ALPHA * live + (1.0 - AT_DIURNAL_ALPHA) * self.diurnal[hour];

        // 4. Effective floor = max of live and the historical hourly baseline.
        let effective = live.max(self.diurnal[hour]);
        self.floor = effective.clamp(MIN_THRESHOLD, MAX_THRESHOLD);
    }

    /// Return the current effective floor.
    ///
    /// This is the value compared against the per-frame score to decide motion.
    pub fn floor(&self) -> f32 {
        self.floor
    }

    /// Returns `true` when [`AT_RECOMPUTE_SECS`] have elapsed since the last
    /// `recompute` call — used by the frame loop to drive `recompute`.
    pub fn recompute_due(&self) -> bool {
        self.last_recompute.elapsed().as_secs() >= AT_RECOMPUTE_SECS
    }

    /// Returns `true` when [`AT_PERSIST_SECS`] have elapsed since the last
    /// baseline UPSERT — used by the frame loop to schedule persistence.
    pub fn persist_due(&self) -> bool {
        self.last_persist.elapsed().as_secs() >= AT_PERSIST_SECS
    }

    /// Reset the persist timer after a successful UPSERT.
    pub fn mark_persisted(&mut self) {
        self.last_persist = std::time::Instant::now();
    }
}

// ─── adaptive-rate helper ─────────────────────────────────────────────────────

/// Decide whether to run the analysis pipeline on this frame.
///
/// When the camera has had no detected motion for at least [`QUIET_SECS`],
/// only every other frame is processed (roughly halving detector CPU to ~2.5
/// fps on top of the [`MOTION_ANALYSIS_FPS`] cap applied by ffmpeg).  While
/// motion is active — or was active within the last [`QUIET_SECS`] — every
/// frame is processed so detection is not delayed.
///
/// # Arguments
///
/// * `analysis_frame_count` — number of frames that have reached the analysis
///   stage since the worker started (post-seed, post-ffmpeg-fps-filter).
/// * `last_motion_instant`  — `Instant` of the most recent frame on which
///   `motion_detected` was `true`, or `None` if no motion has been seen yet.
///
/// # Returns
///
/// `true`  → run the detector on this frame.
/// `false` → skip (caller must `continue` the frame loop).
pub(crate) fn should_process_frame(
    analysis_frame_count: u64,
    last_motion_instant: Option<std::time::Instant>,
) -> bool {
    let in_quiet_window = match last_motion_instant {
        None => true, // no motion ever seen — start in quiet mode
        Some(t) => t.elapsed().as_secs() >= QUIET_SECS,
    };
    if !in_quiet_window {
        return true; // recent motion → full rate
    }
    // Quiet: process every other frame (even-indexed → skip, odd → run).
    !analysis_frame_count.is_multiple_of(2)
}

// ─── watchdog helper ──────────────────────────────────────────────────────────

/// Pure predicate: returns `true` when the motion frame-receipt watchdog
/// deadline has been exceeded.
///
/// Mirrors the condition in the frame loop so boundary behavior is testable
/// without spawning ffmpeg or touching real timers.
pub(crate) fn frame_receipt_deadline_exceeded(elapsed_secs: u64) -> bool {
    elapsed_secs >= FRAME_RECEIPT_TIMEOUT_SECS
}

// ─── base URL resolution ──────────────────────────────────────────────────────

/// Resolve the RTSP base URLs for the motion sub-stream (§6.3 / O3).
///
/// Reads `server_settings` from the DB; falls back to `config.go2rtc_rtsp_base`
/// for both crumb and frigate when the table is absent or a field is empty.
/// This mirrors the same logic in `recording.rs::resolve_rtsp_bases`.
async fn resolve_rtsp_bases_motion(pool: &Pool, config: &Config) -> (String, String) {
    match crumb_common::db::get_server_settings(pool).await {
        Ok(Some(s)) => {
            let crumb = if s.crumb_rtsp_base.trim().is_empty() {
                config.go2rtc_rtsp_base.clone()
            } else {
                s.crumb_rtsp_base
            };
            let frigate = if s.frigate_rtsp_base.trim().is_empty() {
                config.go2rtc_rtsp_base.clone()
            } else {
                s.frigate_rtsp_base
            };
            (crumb, frigate)
        }
        Ok(None) | Err(_) => (
            config.go2rtc_rtsp_base.clone(),
            config.go2rtc_rtsp_base.clone(),
        ),
    }
}

// ─── unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── unhealthy-alert hysteresis (should_emit_unhealthy_alert) ─────────────────

    #[test]
    fn unhealthy_alert_blip_under_threshold_does_not_emit() {
        // 45s of unhealthy against a 180s threshold — a self-healing Reolink
        // blip must NOT alert.
        assert!(!should_emit_unhealthy_alert(45, 180, false));
    }

    #[test]
    fn unhealthy_alert_sustained_past_threshold_emits() {
        assert!(should_emit_unhealthy_alert(180, 180, false));
        assert!(should_emit_unhealthy_alert(300, 180, false));
    }

    #[test]
    fn unhealthy_alert_exactly_at_threshold_emits() {
        // Boundary: >= threshold, not strictly greater.
        assert!(should_emit_unhealthy_alert(180, 180, false));
        assert!(!should_emit_unhealthy_alert(179, 180, false));
    }

    #[test]
    fn unhealthy_alert_already_alerted_never_emits_again() {
        // Exactly-once guard: even well past the threshold, an episode that
        // already alerted must not alert a second time.
        assert!(!should_emit_unhealthy_alert(999, 180, true));
    }

    #[test]
    fn unhealthy_alert_zero_threshold_emits_immediately() {
        // MOTION_UNHEALTHY_ALERT_SECS=0 must restore the pre-hysteresis
        // immediate-alert behaviour.
        assert!(should_emit_unhealthy_alert(0, 0, false));
    }

    #[test]
    fn alert_gate_generation_bumps_on_each_transition() {
        // Simulates the transition bookkeeping `report_health` performs,
        // without the DB/watch-channel plumbing: each direction of transition
        // must invalidate a previously-spawned timer's captured generation.
        let gate = UnhealthyAlertGate::new();
        let g0 = gate
            .generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1; // unhealthy transition #1
        assert_eq!(
            gate.generation.load(std::sync::atomic::Ordering::SeqCst),
            g0
        );

        // Recovery before the timer fires bumps the generation again, so a
        // timer captured at g0 is now stale.
        let g1 = gate
            .generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1; // healthy transition
        assert_ne!(g0, g1);
        assert_eq!(
            gate.generation.load(std::sync::atomic::Ordering::SeqCst),
            g1
        );

        // A NEW unhealthy episode gets its own generation, distinct from both
        // prior ones — a stale timer from episode #1 must never fire for
        // episode #2's alert.
        let g2 = gate
            .generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1;
        assert_ne!(g1, g2);
        assert_ne!(g0, g2);
    }

    // ── pixel healthy report deferred past warm-up (pixel_verdict_capable) ──────

    #[test]
    fn pixel_health_waits_out_warmup() {
        // Warm-up frames are verdict-blind (section g forces
        // `motion_detected = false`), so reporting healthy there would end
        // fail-open on a detector that cannot yet say KEEP (correctness
        // item 19) — a "healthy but blind" window after every (re)connect.
        assert!(!pixel_verdict_capable(1)); // first post-seed frame
        assert!(!pixel_verdict_capable(WARMUP_FRAMES)); // last warm-up frame
                                                        // The first frame past warm-up can produce a real keep/discard
                                                        // verdict — healthy may be reported from here on.
        assert!(pixel_verdict_capable(WARMUP_FRAMES + 1));
    }

    // ── stderr drain (byte-based, UTF-8 tolerant) ────────────────────────────────

    #[tokio::test]
    async fn stderr_drain_survives_invalid_utf8() {
        // ffmpeg stderr with invalid UTF-8 mid-stream. The old `read_line`
        // drain errored on line 2 and STOPPED draining — the pipe closed while
        // ffmpeg kept writing, ffmpeg blocked on the full pipe buffer, and the
        // stdout frame reader stalled (correctness item 5). The byte drain
        // must reach EOF having seen all three lines.
        let stderr: &[u8] = b"frame=1 fps=5\n\xff\xfe bad bytes\nframe=2 fps=5\n";
        assert_eq!(drain_motion_stderr(stderr, uuid::Uuid::nil()).await, 3);
    }

    #[tokio::test]
    async fn stderr_drain_counts_final_unterminated_line() {
        // A child that dies mid-line leaves a final chunk without '\n' — it is
        // still drained (read_until returns Ok(n>0) for it) before the Ok(0) EOF.
        let stderr: &[u8] = b"line one\ntruncated";
        assert_eq!(drain_motion_stderr(stderr, uuid::Uuid::nil()).await, 2);
    }

    // ── frame_absdiff ─────────────────────────────────────────────────────────

    #[test]
    fn absdiff_basic_values() {
        let prev = vec![100u8, 200, 50, 0];
        let curr = vec![150u8, 100, 50, 255];
        let mut dst = vec![0u8; 4];
        frame_absdiff(&prev, &curr, &mut dst);
        assert_eq!(dst, vec![50, 100, 0, 255]);
    }

    #[test]
    fn absdiff_identical_frames_is_zero() {
        let frame = vec![42u8; 64];
        let mut dst = vec![0u8; 64];
        frame_absdiff(&frame, &frame, &mut dst);
        assert!(dst.iter().all(|&b| b == 0));
    }

    // ── census transform (illumination invariance) ────────────────────────────

    fn textured_bg(w: usize, h: usize) -> Vec<f32> {
        // Non-flat pattern, all well above CENSUS_DARK_FLOOR so census (not the
        // dark fallback) is exercised.
        let mut bg = vec![0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                bg[y * w + x] = (60 + ((x + y) % 5) * 10) as f32; // 60..100
            }
        }
        bg
    }

    #[test]
    fn census_ignores_uniform_brightness_shift() {
        // Brighten the WHOLE frame by a large uniform amount (a shadow lifting /
        // cloud clearing / auto-exposure step). Local intensity ORDERING is
        // unchanged, so census must report ZERO foreground — THE shadow-immunity
        // property — despite a 40-luma delta at every pixel.
        let (w, h) = (10usize, 10usize);
        let bg = textured_bg(w, h);
        let curr: Vec<u8> = bg.iter().map(|&b| (b + 40.0) as u8).collect();
        let all_active = vec![1u8; w * h];
        let mut mask = vec![0u8; w * h];
        census_mask_vs_bg(&curr, &bg, w, h, &all_active, &mut mask);
        assert!(
            mask.iter().all(|&m| m == 0),
            "a uniform brightness shift (shadow/cloud) must produce NO census foreground",
        );
    }

    #[test]
    fn census_flags_local_ordering_change() {
        // Same background; in curr, drop in a bright block (a real object changes
        // the local texture/ordering, not just brightness). Census must flag it.
        let (w, h) = (10usize, 10usize);
        let bg = textured_bg(w, h);
        let mut curr: Vec<u8> = bg.iter().map(|&b| b as u8).collect();
        for y in 4..7 {
            for x in 4..7 {
                curr[y * w + x] = 255;
            }
        }
        let all_active = vec![1u8; w * h];
        let mut mask = vec![0u8; w * h];
        census_mask_vs_bg(&curr, &bg, w, h, &all_active, &mut mask);
        assert!(
            mask.contains(&255),
            "a real local-ordering change (object) must produce foreground",
        );
    }

    #[test]
    fn census_ignores_uniform_shift_on_smooth_gradient() {
        // THE real-world case: a FRACTIONAL smooth gradient (sky/wall/road) full of
        // near-equal neighbour pairs, brightened uniformly (sun/shade transition).
        // The tie-band must keep foreground negligible — an integer test can't
        // exercise this (no near-ties), which is how the quantization bug hid.
        let (w, h) = (40usize, 30usize);
        let mut bg = vec![0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                bg[y * w + x] = 80.0
                    + 30.0 * (x as f32 / w as f32)
                    + 10.0 * (y as f32 / h as f32)
                    + ((x * 7 + y * 13) % 5) as f32 * 0.2; // fractional near-ties
            }
        }
        let curr: Vec<u8> = bg.iter().map(|&b| (b + 40.0).round() as u8).collect();
        let all_active = vec![1u8; w * h];
        let mut mask = vec![0u8; w * h];
        census_mask_vs_bg(&curr, &bg, w, h, &all_active, &mut mask);
        let fg = mask.iter().filter(|&&m| m != 0).count();
        assert!(
            fg * 100 < w * h * 5,
            "uniform shift on a smooth gradient must stay <5% foreground, got {fg}/{}",
            w * h,
        );
    }

    // ── erosion (noise rejection) ─────────────────────────────────────────────

    #[test]
    fn erosion_deletes_scattered_noise() {
        // 8×8 frame with isolated "changed" speckle pixels (no neighbours) — the
        // signature of sensor/AGC noise. Raw count sees them; eroded count = 0.
        let w = 8u32;
        let h = 8u32;
        let mut diff = vec![0u8; (w * h) as usize];
        for &i in &[0usize, 10, 23, 45, 60] {
            diff[i] = 200; // lone changed pixels
        }
        assert!(
            count_above_threshold(&diff, 25) >= 5,
            "raw count sees the noise"
        );
        assert_eq!(
            count_eroded_above_threshold(&diff, w, h, 25),
            0,
            "isolated noise pixels must not survive erosion",
        );
    }

    #[test]
    fn erosion_keeps_solid_blob() {
        // A solid 4×4 changed block (a "subject") in an 8×8 frame. With the relaxed
        // ≥4-of-8 rule, only the 4 corners (3 changed neighbours each) drop; the
        // other 12 pixels (≥5 neighbours) survive — i.e. a real blob is preserved.
        let w = 8u32;
        let h = 8u32;
        let mut diff = vec![0u8; (w * h) as usize];
        for y in 2..6u32 {
            for x in 2..6u32 {
                diff[(y * w + x) as usize] = 200;
            }
        }
        let kept = count_eroded_above_threshold(&diff, w, h, 25);
        assert_eq!(
            kept, 12,
            "a 4×4 subject keeps 12 of 16 px (only corners drop)"
        );
    }

    #[test]
    fn absdiff_max_diff_no_overflow() {
        let prev = vec![0u8];
        let curr = vec![255u8];
        let mut dst = vec![0u8; 1];
        frame_absdiff(&prev, &curr, &mut dst);
        assert_eq!(dst[0], 255);
    }

    // ── count_above_threshold ─────────────────────────────────────────────────

    #[test]
    fn count_threshold_strict_greater_than() {
        // 100 and 200 are strictly > 75.
        let diff = vec![0u8, 50, 75, 100, 200];
        assert_eq!(count_above_threshold(&diff, 75), 2);
    }

    #[test]
    fn count_threshold_zero_nothing_strictly_above_zero() {
        let diff = vec![0u8; 5];
        assert_eq!(count_above_threshold(&diff, 0), 0);
    }

    #[test]
    fn count_threshold_equal_not_counted() {
        let diff = vec![10u8; 5];
        assert_eq!(count_above_threshold(&diff, 10), 0);
        assert_eq!(count_above_threshold(&diff, 9), 5);
    }

    // ── apply_mask ────────────────────────────────────────────────────────────

    #[test]
    fn mask_null_is_noop() {
        let mut diff = vec![200u8; 320 * 180];
        apply_mask(&mut diff, 320, 180, &serde_json::Value::Null);
        assert!(diff.iter().all(|&b| b == 200));
    }

    #[test]
    fn mask_empty_array_is_noop() {
        let mut diff = vec![200u8; 320 * 180];
        apply_mask(&mut diff, 320, 180, &json!([]));
        assert!(diff.iter().all(|&b| b == 200));
    }

    #[test]
    fn mask_full_frame_polygon_zeroes_all() {
        let w = 10u32;
        let h = 10u32;
        let mut diff = vec![200u8; (w * h) as usize];
        // Axis-aligned rectangle slightly larger than the frame.
        let mask = json!([[[-1.0, -1.0], [11.0, -1.0], [11.0, 11.0], [-1.0, 11.0]]]);
        apply_mask(&mut diff, w, h, &mask);
        assert!(diff.iter().all(|&b| b == 0), "all pixels should be zeroed");
    }

    #[test]
    fn mask_corner_triangle_zeroes_correct_pixels() {
        let w = 10u32;
        let h = 10u32;
        let mut diff = vec![200u8; (w * h) as usize];
        // Right-triangle: (0,0)→(4,0)→(0,4).
        let mask = json!([[[0.0, 0.0], [4.0, 0.0], [0.0, 4.0]]]);
        apply_mask(&mut diff, w, h, &mask);
        // Pixel (0,0) centre = (0.5, 0.5) → inside triangle → zeroed.
        assert_eq!(diff[0], 0);
        // Pixel (9,9) centre = (9.5, 9.5) → outside → unchanged.
        assert_eq!(diff[9 * 10 + 9], 200);
    }

    #[test]
    fn mask_degenerate_polygon_skipped() {
        let mut diff = vec![200u8; 10 * 10];
        // Only 2 points — not a polygon.
        let mask = json!([[[0.0, 0.0], [5.0, 5.0]]]);
        apply_mask(&mut diff, 10, 10, &mask);
        assert!(diff.iter().all(|&b| b == 200));
    }

    // ── AdaptiveThreshold (was DynamicSensitivity) ───────────────────────────
    //
    // Legacy test names retained for git-blame continuity.  The tests are
    // updated to use the new API and verify equivalent invariants.

    #[test]
    fn dynamic_sens_initial_threshold_is_min() {
        let ds = AdaptiveThreshold::new();
        assert_eq!(ds.floor(), MIN_THRESHOLD);
    }

    #[test]
    fn dynamic_sens_single_sample_no_change() {
        let mut ds = AdaptiveThreshold::new();
        ds.observe(0.05);
        // recompute not called yet → floor unchanged.
        assert_eq!(ds.floor(), MIN_THRESHOLD);
    }

    #[test]
    fn dynamic_sens_constant_background_converges_low() {
        // A quiet scene (all scores well below BLOB_FRACTION) must not
        // invent noise — floor stays at MIN_THRESHOLD.
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        for _ in 0..500 {
            ds.observe(0.0);
        }
        ds.recompute(t);
        assert!(ds.floor() >= MIN_THRESHOLD);
        assert!(ds.floor() <= 0.005, "quiet scene floor must stay near MIN");
    }

    #[test]
    fn dynamic_sens_clamped_to_max() {
        // Even if every frame scores MAX, the floor never exceeds MAX_THRESHOLD.
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        for _ in 0..1000 {
            ds.observe(MAX_THRESHOLD);
        }
        ds.recompute(t);
        assert!(ds.floor() <= MAX_THRESHOLD);
    }

    #[test]
    fn dynamic_sens_zero_background_clamped_to_min() {
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        for _ in 0..100 {
            ds.observe(0.0);
        }
        ds.recompute(t);
        assert_eq!(ds.floor(), MIN_THRESHOLD);
    }

    #[test]
    fn dynamic_sens_window_eviction_no_panic() {
        // Stress test: many observations, no panic, floor in bounds.
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        for i in 0..1000_usize {
            ds.observe((i as f32) * 0.0001);
        }
        ds.recompute(t);
        assert!(ds.floor() >= MIN_THRESHOLD);
        assert!(ds.floor() <= MAX_THRESHOLD);
    }

    // ── AdaptiveThreshold: 6 behavioral tests (spec §Tests) ──────────────────

    /// 1. Quiet scene: floor stays at BLOB_FRACTION (don't invent noise).
    #[test]
    fn adaptive_quiet_scene_stays_at_floor() {
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        // 10 000 frames of near-zero activity (sub-pixel noise at 0.001).
        for _ in 0..10_000 {
            ds.observe(0.001);
        }
        ds.recompute(t);
        // Quiet scene: 97th pct is bucket 0 (quiet) → floor = MIN_THRESHOLD.
        assert!(
            ds.floor() <= BLOB_FRACTION * 1.5,
            "quiet scene floor should stay near BLOB_FRACTION, got {}",
            ds.floor()
        );
    }

    /// 2. Tree-noisy scene: floor rises above the nuisance band.
    #[test]
    fn adaptive_noisy_scene_floor_rises_above_nuisance() {
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        // Simulate a tree camera: most frames 0.5–1.5 % (just above BLOB_FRACTION).
        // Feed 10 000 nuisance frames at 0.008 (well above BLOB_FRACTION = 0.003).
        for _ in 0..10_000 {
            ds.observe(0.008);
        }
        ds.recompute(t);
        // Floor must exceed the nuisance score so the tree stops triggering.
        assert!(
            ds.floor() >= 0.005,
            "noisy scene floor should rise above nuisance, got {}",
            ds.floor()
        );
    }

    /// 3. Real event passes after training on nuisance.
    #[test]
    fn adaptive_real_event_still_passes_after_training() {
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        // Train on a nuisance band at 0.008.
        for _ in 0..10_000 {
            ds.observe(0.008);
        }
        ds.recompute(t);
        let floor = ds.floor();
        // A 5% blob (a person) must clearly exceed the trained floor.
        assert!(
            0.05 > floor,
            "real event score 0.05 must exceed trained floor {floor}"
        );
    }

    /// 4. Sustained high-score burst doesn't blind the camera.
    ///
    /// A person standing for 5 min ≈ 4 500 frames; the horizon is ~120 min
    /// (tens of thousands of frames).  The burst is ≤~3% of weight and
    /// cannot move the 97th percentile above the burst level.
    #[test]
    fn adaptive_sustained_burst_does_not_blind() {
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        // 50 000 "normal" quiet frames (97th pct lands in quiet bucket).
        for _ in 0..50_000 {
            ds.observe(0.001);
        }
        // 1 500 "event" frames at 0.10 (~3% of total, like a standing person).
        for _ in 0..1_500 {
            ds.observe(0.10);
        }
        ds.recompute(t);
        // Floor must remain well below the event score (0.10).
        assert!(
            ds.floor() < 0.05,
            "sustained burst should not push floor above 0.05, got {}",
            ds.floor()
        );
    }

    /// 5. Diurnal: training only at hour=2 raises diurnal[2] but not diurnal[14].
    #[test]
    fn adaptive_diurnal_trains_per_hour() {
        let mut ds = AdaptiveThreshold::new();
        use chrono::{TimeZone, Utc};
        // Build a UTC timestamp at 02:30.
        let t2 = Utc.with_ymd_and_hms(2026, 1, 1, 2, 30, 0).unwrap();
        // Feed many nuisance frames and recompute at hour 2 many times.
        for _ in 0..20 {
            for _ in 0..1_000 {
                ds.observe(0.008);
            }
            ds.recompute(t2);
        }
        let diurnal_2 = ds.diurnal[2];
        let diurnal_14 = ds.diurnal[14];
        // Hour 2 should have risen from MIN_THRESHOLD; hour 14 should remain at it.
        assert!(
            diurnal_2 > MIN_THRESHOLD + 0.001,
            "diurnal[2] should have risen above MIN, got {diurnal_2}"
        );
        assert!(
            (diurnal_14 - MIN_THRESHOLD).abs() < 0.001,
            "diurnal[14] should remain near MIN, got {diurnal_14}"
        );
    }

    /// 6. Persistence round-trip: serialize → deserialize yields the same floor.
    #[test]
    fn adaptive_persistence_round_trip() {
        let mut ds = AdaptiveThreshold::new();
        let t = chrono::Utc::now();
        // Train to produce a non-trivial floor.
        for _ in 0..10_000 {
            ds.observe(0.008);
        }
        ds.recompute(t);
        let floor_before = ds.floor();

        // Serialize → deserialize.
        let state = ds.to_baseline();
        let mut ds2 = AdaptiveThreshold::from_baseline(&state);
        // After recompute on the restored learner the floor should be the same.
        // (The histogram is reproduced exactly; only the decay for elapsed ≈ 0 s
        // applies, which is ~1.0, so the result is identical.)
        ds2.recompute(t);
        let floor_after = ds2.floor();

        assert!(
            (floor_before - floor_after).abs() < 1e-4,
            "round-trip floor mismatch: before={floor_before} after={floor_after}"
        );
    }

    // ── new engine: background / mask / morphology / blobs ─────────────────────

    #[test]
    fn threshold_mask_marks_only_changed_pixels() {
        let curr = vec![100u8, 100, 200, 100];
        let bg = vec![100f32, 100.0, 100.0, 130.0];
        let mut mask = vec![0u8; 4];
        threshold_mask_vs_bg(&curr, &bg, 25.0, &mut mask);
        // px2: |200-100|=100 > 25 → on; px3: |100-130|=30 > 25 → on; rest off.
        assert_eq!(mask, vec![0, 0, 255, 255]);
    }

    #[test]
    fn update_background_converges_toward_current() {
        let mut bg = vec![0f32; 1];
        let curr = vec![100u8; 1];
        for _ in 0..200 {
            update_background(&mut bg, &curr, 0.05);
        }
        assert!((bg[0] - 100.0).abs() < 1.0, "bg should converge to curr");
    }

    #[test]
    fn connected_components_largest_blob() {
        // 10×10: one solid 4×4 blob (16 px) + two lone speckle pixels.
        let w = 10usize;
        let h = 10usize;
        let mut mask = vec![0u8; w * h];
        for y in 1..5 {
            for x in 1..5 {
                mask[y * w + x] = 255;
            }
        }
        mask[9 * w + 9] = 255; // speckle
        mask[0] = 255; // speckle
        let mut labels = vec![0u32; w * h];
        let mut parent = Vec::new();
        let mut areas = Vec::new();
        let largest = connected_components(&mask, w, h, &mut labels, &mut parent, &mut areas);
        assert_eq!(largest, 16, "the 4×4 blob is the largest connected region");
    }

    #[test]
    fn connected_components_empty_is_zero() {
        let (w, h) = (8usize, 8usize);
        let mask = vec![0u8; w * h];
        let mut labels = vec![0u32; w * h];
        let mut parent = Vec::new();
        let mut areas = Vec::new();
        assert_eq!(
            connected_components(&mask, w, h, &mut labels, &mut parent, &mut areas),
            0
        );
    }

    #[test]
    fn connected_components_merges_l_shape() {
        // An L shape must label as ONE blob via union of left+up labels (9 px).
        let (w, h) = (5usize, 5usize);
        let mut mask = vec![0u8; w * h];
        for cell in mask.iter_mut().take(5) {
            *cell = 255; // top row (5)
        }
        for y in 1..5 {
            mask[y * w] = 255; // left column (4)
        }
        let mut labels = vec![0u32; w * h];
        let mut parent = Vec::new();
        let mut areas = Vec::new();
        assert_eq!(
            connected_components(&mask, w, h, &mut labels, &mut parent, &mut areas),
            9
        );
    }

    #[test]
    fn dilate_grows_and_erode_keeps_blob() {
        let (w, h) = (10usize, 10usize);
        let mut mask = vec![0u8; w * h];
        for y in 3..7 {
            for x in 3..7 {
                mask[y * w + x] = 255; // 4×4 = 16 px
            }
        }
        let mut dil = vec![0u8; w * h];
        dilate_mask(&mask, &mut dil, w, h);
        assert!(
            dil.iter().filter(|&&v| v != 0).count() > 16,
            "dilation should grow the blob"
        );
        let mut ero = vec![0u8; w * h];
        erode_mask(&dil, &mut ero, w, h);
        assert!(
            ero.iter().filter(|&&v| v != 0).count() >= 12,
            "a solid blob survives erosion"
        );
    }

    #[test]
    fn manual_floor_is_a_fraction() {
        assert!((manual_floor(Some(0.0030)) - 0.0030).abs() < 1e-6); // 0.30 % passes through
        assert!((manual_floor(None) - BLOB_FRACTION).abs() < 1e-6); // default = blob floor
        assert!((manual_floor(Some(0.0)) - 0.0005).abs() < 1e-6); // clamp low (0.05 %)
        assert!((manual_floor(Some(1.0)) - 0.05).abs() < 1e-6); // clamp high (5 %)
    }

    // ── NVDEC semaphore ───────────────────────────────────────────────────────

    #[test]
    fn nvdec_acquire_before_init_returns_none() {
        // NVDEC_SEMAPHORE_ARC may or may not be initialised in a test binary.
        // We only verify that try_acquire_nvdec() does not panic.
        let _permit = try_acquire_nvdec();
    }

    // ── frame-receipt watchdog ────────────────────────────────────────────────

    /// The receipt timeout must be > the per-frame stall timeout (12 s) so the
    /// two watchdogs do not race: the stall fires first in the common case and
    /// immediately returns Err; the receipt watchdog is a backstop for edge cases
    /// where partial pipe reads keep resetting the inner stall counter.
    #[test]
    fn frame_receipt_timeout_exceeds_stall_timeout() {
        const {
            assert!(
                FRAME_RECEIPT_TIMEOUT_SECS > FRAME_STALL_TIMEOUT_SECS,
                "receipt timeout must be > stall timeout to avoid a race"
            )
        }
    }

    /// The receipt timeout must be short enough to heal within a minute so a
    /// live-reconfig-restarted worker that never connects self-heals quickly.
    #[test]
    fn frame_receipt_timeout_heals_promptly() {
        const {
            assert!(
                FRAME_RECEIPT_TIMEOUT_SECS <= 60,
                "receipt timeout must be <= 60 s; a never-connecting worker must not stall for minutes"
            )
        }
    }

    #[test]
    fn frame_receipt_deadline_not_exceeded_before_timeout() {
        assert!(!frame_receipt_deadline_exceeded(
            FRAME_RECEIPT_TIMEOUT_SECS - 1
        ));
    }

    #[test]
    fn frame_receipt_deadline_exceeded_at_boundary() {
        assert!(frame_receipt_deadline_exceeded(FRAME_RECEIPT_TIMEOUT_SECS));
    }

    #[test]
    fn frame_receipt_deadline_exceeded_well_past_timeout() {
        assert!(frame_receipt_deadline_exceeded(
            FRAME_RECEIPT_TIMEOUT_SECS + 120
        ));
    }

    // ── Analysis-rate constants: frame counts derived from seconds ────────────

    /// The start-dwell in frames must be `round(MOTION_START_SECS * MOTION_ANALYSIS_FPS)`.
    #[test]
    fn motion_start_frames_derived_from_secs() {
        let expected = ((MOTION_START_SECS * MOTION_ANALYSIS_FPS as f32) + 0.5) as usize;
        assert_eq!(
            MOTION_START_FRAMES, expected,
            "MOTION_START_FRAMES must equal round(MOTION_START_SECS * MOTION_ANALYSIS_FPS)"
        );
    }

    /// The stop-hysteresis in frames must be `round(MOTION_STOP_SECS * MOTION_ANALYSIS_FPS)`.
    #[test]
    fn motion_stop_hysteresis_derived_from_secs() {
        let expected = ((MOTION_STOP_SECS * MOTION_ANALYSIS_FPS as f32) + 0.5) as usize;
        assert_eq!(
            MOTION_STOP_HYSTERESIS, expected,
            "MOTION_STOP_HYSTERESIS must equal round(MOTION_STOP_SECS * MOTION_ANALYSIS_FPS)"
        );
    }

    /// The derived frame counts must be non-zero — a zero dwell is a logic error.
    #[test]
    fn motion_frame_counts_nonzero() {
        const {
            assert!(MOTION_START_FRAMES > 0, "MOTION_START_FRAMES must be > 0");
            assert!(
                MOTION_STOP_HYSTERESIS > 0,
                "MOTION_STOP_HYSTERESIS must be > 0"
            );
        }
    }

    /// Start-dwell wall time must stay below 1 s (fast detection) and
    /// [`MOTION_ANALYSIS_FPS`] must be non-zero (would divide by zero in the
    /// derived-frame-count expressions).
    #[test]
    fn motion_start_secs_below_one_second() {
        const {
            assert!(
                MOTION_ANALYSIS_FPS > 0,
                "MOTION_ANALYSIS_FPS must be non-zero"
            );
            // f32 comparisons are allowed in const blocks on stable Rust.
            assert!(
                MOTION_START_SECS < 1.0,
                "MOTION_START_SECS must be < 1 s for fast detection"
            );
        }
    }

    // ── should_process_frame (adaptive-rate logic) ────────────────────────────

    /// When no motion has ever been seen, the function is in quiet mode and
    /// processes every other frame (odd indices → true, even → false).
    #[test]
    fn adaptive_rate_quiet_never_seen_motion() {
        // Frame 0 (even) is skipped, frame 1 (odd) runs, frame 2 skipped, etc.
        assert!(
            !should_process_frame(0, None),
            "frame 0 (even) must be skipped during quiet"
        );
        assert!(
            should_process_frame(1, None),
            "frame 1 (odd) must be processed during quiet"
        );
        assert!(
            !should_process_frame(2, None),
            "frame 2 (even) must be skipped during quiet"
        );
        assert!(
            should_process_frame(3, None),
            "frame 3 (odd) must be processed during quiet"
        );
    }

    /// When motion was detected very recently (< QUIET_SECS ago), every frame
    /// is processed regardless of the frame count parity.
    #[test]
    fn adaptive_rate_full_rate_during_recent_motion() {
        let just_now = std::time::Instant::now();
        // Even-indexed frames must still be processed because motion is recent.
        for fc in 0..10u64 {
            assert!(
                should_process_frame(fc, Some(just_now)),
                "frame {fc} must be processed during recent-motion window"
            );
        }
    }

    /// When motion was detected > QUIET_SECS ago, half-rate kicks in again.
    #[test]
    fn adaptive_rate_half_rate_after_quiet_window() {
        // Simulate a timestamp long in the past.
        // We can't actually sleep QUIET_SECS in a unit test, so we use an
        // Instant from just-past the QUIET_SECS boundary by creating one via
        // checked_sub.
        let long_ago = std::time::Instant::now()
            .checked_sub(std::time::Duration::from_secs(QUIET_SECS + 1))
            .expect("Instant::checked_sub must not underflow on a QUIET_SECS + 1 offset");
        // Even-indexed frames must be skipped; odd ones processed.
        assert!(
            !should_process_frame(0, Some(long_ago)),
            "frame 0 (even) must be skipped after quiet window"
        );
        assert!(
            should_process_frame(1, Some(long_ago)),
            "frame 1 (odd) must be processed after quiet window"
        );
        assert!(
            !should_process_frame(4, Some(long_ago)),
            "frame 4 (even) must be skipped after quiet window"
        );
        assert!(
            should_process_frame(5, Some(long_ago)),
            "frame 5 (odd) must be processed after quiet window"
        );
    }

    /// Within the QUIET_SECS window (motion was recent enough), all frames
    /// are processed — the half-rate suppressor must not fire.
    #[test]
    fn adaptive_rate_full_rate_within_quiet_boundary() {
        let recent = std::time::Instant::now()
            .checked_sub(std::time::Duration::from_secs(QUIET_SECS - 1))
            .expect("QUIET_SECS must be >= 1");
        for fc in 0..6u64 {
            assert!(
                should_process_frame(fc, Some(recent)),
                "frame {fc} must be processed when inside QUIET_SECS window"
            );
        }
    }

    // ── Stage-0 seam: CensusDetector ≡ the legacy inline path ─────────────────
    //
    // The pluggable-motion refactor moved the bg seed, the census foreground, and
    // the EMA background update out of `run_pixel_diff_loop` and behind the
    // `MotionDetector` trait (impl `CensusDetector`). The seam MUST be
    // behaviour-preserving: same mask, same background, every frame. This golden
    // record/replay test drives a deterministic sequence (seed → textured drift →
    // a moving bright block "object" → a whole-frame lightning step) through BOTH
    // the trait detector and the original inline calls, asserting the foreground
    // mask is byte-identical on every frame and the f32 background model is
    // bit-for-bit identical after every commit. Any future CensusDetector edit
    // that diverges from `census_mask_vs_bg` + `update_background` fails here.

    /// Deterministic (frame, ctx) sequence covering the four interesting regimes:
    /// the seed frame, idle drift, an active event (moving block), and a lightning
    /// step. No RNG — fully reproducible.
    fn golden_frame_sequence(w: usize, h: usize, n: usize) -> Vec<(Vec<u8>, FrameContext)> {
        let mut frames = Vec::with_capacity(n);
        for f in 0..n {
            let mut frame = vec![0u8; w * h];
            for y in 0..h {
                for x in 0..w {
                    // Textured base (so census is exercised, not the dark fallback)
                    // with a slow temporal drift to flex the EMA update.
                    let base = 60 + ((x + y) % 5) * 8 + (f % 7) * 2;
                    frame[y * w + x] = base.min(255) as u8;
                }
            }
            // A moving bright block ("object") on frames 10..40 ⇒ event_active.
            let event_active = (10..40).contains(&f);
            if event_active {
                let span = w.saturating_sub(4).max(1);
                let ox = (f - 10) % span;
                for y in 4..8.min(h) {
                    for x in ox..(ox + 4).min(w) {
                        frame[y * w + x] = 240;
                    }
                }
            }
            // A whole-frame illumination step on frames 45..48 ⇒ lightning.
            let lightning = (45..48).contains(&f);
            if lightning {
                for px in frame.iter_mut() {
                    *px = px.saturating_add(60);
                }
            }
            frames.push((
                frame,
                FrameContext {
                    lightning,
                    event_active,
                },
            ));
        }
        frames
    }

    #[test]
    fn census_detector_matches_legacy() {
        let (w, h) = (32usize, 24usize);
        let frame_size = w * h;
        let seq = golden_frame_sequence(w, h, 60);

        // All-ones active mask: every pixel is active → the new code path must
        // produce byte-identical output to the legacy inline path.
        let all_active = vec![1u8; frame_size];

        // New path: the trait-based detector (concrete type so the test, a child
        // module, can read its private `bg` for bit-exact comparison).
        let mut detector = CensusDetector::new(frame_size);

        // Legacy path: the inline bg seed + census + EMA update, verbatim from the
        // pre-seam `run_pixel_diff_loop`.
        let mut bg = vec![0f32; frame_size];
        let mut bg_init = false;

        let mut new_mask = vec![0u8; frame_size];
        let mut old_mask = vec![0u8; frame_size];
        let mut compared = 0usize;
        let mut any_fg = false;

        for (frame, ctx) in &seq {
            let new_seeded = detector.seed_if_needed(frame);
            let old_seeded = if bg_init {
                false
            } else {
                for (b, &c) in bg.iter_mut().zip(frame.iter()) {
                    *b = c as f32;
                }
                bg_init = true;
                true
            };
            assert_eq!(new_seeded, old_seeded, "seed decision must match");
            if old_seeded {
                continue; // both paths skip the seed frame
            }

            // foreground with all-ones active must equal the legacy census call.
            detector.foreground(frame, w, h, &all_active, &mut new_mask);
            census_mask_vs_bg(frame, &bg, w, h, &all_active, &mut old_mask);
            assert_eq!(
                new_mask, old_mask,
                "foreground mask must be byte-identical (frame {compared})",
            );
            any_fg |= new_mask.iter().any(|&m| m != 0);
            compared += 1;

            // Update both models with the SAME alpha branch and assert bit-exact.
            detector.commit(frame, *ctx, &all_active);
            let alpha = if ctx.lightning {
                BG_ALPHA_LIGHTNING
            } else if ctx.event_active {
                BG_ALPHA_ACTIVE
            } else {
                BG_ALPHA_IDLE
            };
            update_background(&mut bg, frame, alpha);
            for (i, (a, b)) in detector.bg.iter().zip(bg.iter()).enumerate() {
                assert_eq!(
                    a.to_bits(),
                    b.to_bits(),
                    "background diverged at bg[{i}] after commit (frame {compared}): {a} vs {b}",
                );
            }
        }

        assert!(compared > 10, "golden sequence compared too few frames");
        assert!(
            any_fg,
            "sanity: the moving-block frames must produce foreground"
        );
    }

    // ── active-mask correctness tests ─────────────────────────────────────────

    /// Partial `active` mask: masked pixels are 0 in the output; active-pixel
    /// output equals the all-active result restricted to those pixels.
    #[test]
    fn active_mask_partial_zeroes_masked_pixels_no_cross_contamination() {
        let (w, h) = (16usize, 16usize);
        let frame_size = w * h;

        // Build a non-trivial scene: textured, with a bright block that census
        // would normally flag as foreground.
        let mut bg_arr = vec![0f32; frame_size];
        for (i, b) in bg_arr.iter_mut().enumerate() {
            *b = (60 + ((i % w + i / w) % 5) * 8) as f32;
        }
        let mut curr = vec![0u8; frame_size];
        for (i, c) in curr.iter_mut().enumerate() {
            *c = bg_arr[i] as u8;
        }
        // Inject a moving object in the top-left quadrant.
        for y in 2..6 {
            for x in 2..6 {
                curr[y * w + x] = 240;
            }
        }

        // Mask: first half of the frame (rows 0..h/2) is masked; rest is active.
        let mut partial_active = vec![1u8; frame_size];
        for a in partial_active.iter_mut().take(frame_size / 2) {
            *a = 0;
        }
        let all_active = vec![1u8; frame_size];

        let det = CensusDetector {
            bg: bg_arr.clone(),
            bg_init: true,
        };

        let mut mask_partial = vec![0u8; frame_size];
        let mut mask_all = vec![0u8; frame_size];
        det.foreground(&curr, w, h, &partial_active, &mut mask_partial);
        det.foreground(&curr, w, h, &all_active, &mut mask_all);

        // 1. All masked pixels must be 0 in the partial output.
        for (i, &v) in mask_partial.iter().enumerate().take(frame_size / 2) {
            assert_eq!(v, 0, "masked pixel {i} must be 0 in partial output");
        }
        // 2. Active pixels must agree with the all-active run (no cross-contamination).
        for (i, (&vp, &va)) in mask_partial
            .iter()
            .zip(mask_all.iter())
            .enumerate()
            .skip(frame_size / 2)
        {
            assert_eq!(vp, va, "active pixel {i} must match the all-active result");
        }
    }

    /// Background model is NOT updated for masked pixels.
    ///
    /// Strategy: build a CensusDetector seeded to bg_init value A.  Run many
    /// commits with `active[i] = 0` (masked).  The `bg` values for those pixels
    /// must remain unchanged (still A).  Then unmask and run a commit — the
    /// model now updates (proves the skip was the active-flag, not a bug).
    #[test]
    fn active_mask_commit_skips_bg_model_for_masked_pixels() {
        let (w, h) = (8usize, 8usize);
        let frame_size = w * h;

        // Seed the background to all-100.
        let mut det = CensusDetector::new(frame_size);
        let seed = vec![100u8; frame_size];
        assert!(det.seed_if_needed(&seed));

        // A new frame with all pixels at 200 — a large drift that would rapidly
        // move the EMA away from 100 if the model were updated.
        let new_frame = vec![200u8; frame_size];

        // Mask every pixel (active = 0 everywhere).
        let all_masked = vec![0u8; frame_size];
        let ctx = FrameContext {
            lightning: false,
            event_active: false,
        };

        // Run 500 commits with all pixels masked → model must not move.
        for _ in 0..500 {
            det.commit(&new_frame, ctx, &all_masked);
        }

        // All bg values must still be exactly 100.0 (the seed value).
        for (i, &b) in det.bg.iter().enumerate() {
            assert!(
                (b - 100.0).abs() < 1e-5,
                "bg[{i}] should be unchanged at 100.0, got {b}"
            );
        }

        // Now unmask and run one commit — model must start moving toward 200.
        let all_active = vec![1u8; frame_size];
        det.commit(&new_frame, ctx, &all_active);
        for (i, &b) in det.bg.iter().enumerate() {
            assert!(
                b > 100.0,
                "bg[{i}] should have moved toward 200 after unmasking, got {b}"
            );
        }
    }

    #[test]
    fn census_detector_reset_reseeds() {
        // After reset() the next frame must re-seed (so a stale background from
        // before a sub-stream reconnect can't read as motion on resume).
        let mut detector = CensusDetector::new(16);
        let frame = vec![100u8; 16];
        assert!(detector.seed_if_needed(&frame), "first frame seeds");
        assert!(!detector.seed_if_needed(&frame), "already seeded");
        detector.reset();
        assert!(detector.seed_if_needed(&frame), "reset forces a re-seed");
    }

    #[test]
    fn census_detector_default_algorithm() {
        assert_eq!(
            CensusDetector::new(4).algorithm_id(),
            MotionAlgorithm::Census,
        );
    }

    // ── Stage-1 detectors: FrameDiff / MOG2 / OpticalFlow ─────────────────────

    /// Count foreground pixels after seeding `det` on `seed`, then for each frame
    /// running foreground→commit; returns the LAST frame's foreground count.
    fn run_detector(det: &mut dyn MotionDetector, w: usize, h: usize, frames: &[Vec<u8>]) -> usize {
        let all_active = vec![1u8; w * h];
        let mut mask = vec![0u8; w * h];
        let mut last = 0usize;
        for (i, f) in frames.iter().enumerate() {
            if i == 0 {
                assert!(det.seed_if_needed(f), "first frame must seed");
                continue;
            }
            // (already-seeded detectors return false here)
            assert!(!det.seed_if_needed(f));
            det.foreground(f, w, h, &all_active, &mut mask);
            last = mask.iter().filter(|&&m| m != 0).count();
            det.commit(
                f,
                FrameContext {
                    lightning: false,
                    event_active: false,
                },
                &all_active,
            );
        }
        last
    }

    #[test]
    fn framediff_static_then_moving() {
        let (w, h) = (16usize, 16usize);
        let flat = vec![100u8; w * h];
        // Identical frames ⇒ no foreground.
        let mut det = FrameDiffDetector::new(w * h);
        assert_eq!(
            run_detector(&mut det, w, h, &[flat.clone(), flat.clone(), flat.clone()]),
            0,
            "identical frames must produce no frame-diff foreground",
        );
        // A bright block appearing ⇒ that block is foreground.
        let mut moved = flat.clone();
        for y in 4..8 {
            for x in 4..8 {
                moved[y * w + x] = 255;
            }
        }
        let mut det = FrameDiffDetector::new(w * h);
        let fg = run_detector(&mut det, w, h, &[flat.clone(), moved]);
        assert_eq!(fg, 16, "the 4×4 changed block must be the foreground");
        assert_eq!(det.algorithm_id(), MotionAlgorithm::FrameDiff);
    }

    #[test]
    fn mog2_learns_bimodal_background() {
        // THE MOG2 property: a pixel that legitimately alternates between two
        // values (sky ↔ swaying branch) must be learnt as background — both modes
        // — so it stops reading as foreground, where a single-mode model can't.
        let (w, h) = (8usize, 8usize);
        let a = vec![60u8; w * h];
        let b = vec![160u8; w * h];
        let all_active = vec![1u8; w * h];
        let mut det = Mog2Detector::new(w * h);
        det.seed_if_needed(&a);
        let mut mask = vec![0u8; w * h];
        // Train on a long A/B alternation so BOTH modes gain weight.
        for i in 0..400 {
            let f = if i % 2 == 0 { &a } else { &b };
            det.commit(
                f,
                FrameContext {
                    lightning: false,
                    event_active: false,
                },
                &all_active,
            );
        }
        // After training, neither A nor B should read as foreground.
        det.foreground(&a, w, h, &all_active, &mut mask);
        let fg_a = mask.iter().filter(|&&m| m != 0).count();
        det.foreground(&b, w, h, &all_active, &mut mask);
        let fg_b = mask.iter().filter(|&&m| m != 0).count();
        assert!(
            fg_a == 0 && fg_b == 0,
            "both modes of a bimodal pixel must be background (A={fg_a}, B={fg_b})",
        );
        // A genuinely new value (an object) must still be foreground.
        let c = vec![10u8; w * h];
        det.foreground(&c, w, h, &all_active, &mut mask);
        let fg_c = mask.iter().filter(|&&m| m != 0).count();
        assert_eq!(fg_c, w * h, "an unseen value must read as foreground");
    }

    #[test]
    fn mog2_static_scene_quiet() {
        // A static textured scene must converge to ~zero foreground.
        let (w, h) = (16usize, 16usize);
        let mut frame = vec![0u8; w * h];
        for y in 0..h {
            for x in 0..w {
                frame[y * w + x] = (40 + ((x * 3 + y * 5) % 60)) as u8;
            }
        }
        let all_active = vec![1u8; w * h];
        let mut det = Mog2Detector::new(w * h);
        det.seed_if_needed(&frame);
        let mut mask = vec![0u8; w * h];
        for _ in 0..50 {
            det.commit(
                &frame,
                FrameContext {
                    lightning: false,
                    event_active: false,
                },
                &all_active,
            );
        }
        det.foreground(&frame, w, h, &all_active, &mut mask);
        assert_eq!(
            mask.iter().filter(|&&m| m != 0).count(),
            0,
            "a static scene must be fully background under MOG2",
        );
        assert_eq!(det.algorithm_id(), MotionAlgorithm::Mog2);
    }

    #[test]
    fn opticalflow_translation_vs_flicker() {
        // A textured patch that TRANSLATES must trip optical flow; the SAME patch
        // brightened in place (flicker / IR cut) must NOT.
        let (w, h) = (48usize, 32usize);
        let bg = 50u8;
        // base: a textured 16×16 patch near the left so it has room to move right.
        let make = |shift: usize, bright: i16| -> Vec<u8> {
            let mut f = vec![bg; w * h];
            for y in 8..24 {
                for x in 8..24 {
                    // Texture with NO period ≤ the ±4 search window (mod-17 on a
                    // skewed index), so block-matching has a single clear minimum
                    // and can't alias a 4 px shift onto zero displacement.
                    let v = 100 + ((x * 5 + y * 9) % 17) as i16 * 9 + bright;
                    let dst_x = x + shift;
                    if dst_x < w {
                        f[y * w + dst_x] = v.clamp(0, 255) as u8;
                    }
                }
            }
            f
        };
        let f0 = make(0, 0);
        let f_moved = make(4, 0); // patch shifted +4 px right
        let f_bright = make(0, 40); // same position, +40 luma in place

        let all_active = vec![1u8; w * h];
        let mut det = OpticalFlowDetector::new(w * h);
        det.seed_if_needed(&f0);
        let mut mask = vec![0u8; w * h];
        det.foreground(&f_moved, w, h, &all_active, &mut mask);
        let fg_move = mask.iter().filter(|&&m| m != 0).count();
        assert!(fg_move > 0, "a translating patch must trip optical flow");

        // Re-seed for an independent flicker test.
        let mut det = OpticalFlowDetector::new(w * h);
        det.seed_if_needed(&f0);
        det.foreground(&f_bright, w, h, &all_active, &mut mask);
        let fg_flicker = mask.iter().filter(|&&m| m != 0).count();
        assert!(
            fg_flicker < fg_move,
            "in-place flicker must trip optical flow far less than real translation (flicker={fg_flicker}, move={fg_move})",
        );
        assert_eq!(det.algorithm_id(), MotionAlgorithm::OpticalFlow);
    }

    #[test]
    fn motion_algorithm_str_roundtrip() {
        for a in [
            MotionAlgorithm::Census,
            MotionAlgorithm::FrameDiff,
            MotionAlgorithm::Mog2,
            MotionAlgorithm::OpticalFlow,
            MotionAlgorithm::Ensemble,
        ] {
            assert_eq!(MotionAlgorithm::from_str_lenient(a.as_str()), a);
        }
        // Unknown / empty ⇒ the safe default.
        assert_eq!(
            MotionAlgorithm::from_str_lenient("nonsense"),
            MotionAlgorithm::Census
        );
        assert_eq!(
            MotionAlgorithm::from_str_lenient(""),
            MotionAlgorithm::Census
        );
        assert_eq!(MotionAlgorithm::default(), MotionAlgorithm::Census);
    }

    #[test]
    fn detector_for_algorithm_matches_id() {
        for a in [
            MotionAlgorithm::Census,
            MotionAlgorithm::FrameDiff,
            MotionAlgorithm::Mog2,
            MotionAlgorithm::OpticalFlow,
            MotionAlgorithm::Ensemble,
        ] {
            assert_eq!(detector_for_algorithm(a, 64).algorithm_id(), a);
        }
    }

    // ── Stage-3: Ensemble fusion ──────────────────────────────────────────────

    #[test]
    fn ensemble_fills_flat_region_where_census_is_blind() {
        // A flat scene: census has no local ordering to compare, so it's blind to
        // a flat patch appearing on a flat background. MOG2 (brightness) catches
        // it, and the ensemble's flat-region rule surfaces it — so the ensemble
        // sees an object census alone would miss.
        let (w, h) = (24usize, 24usize);
        let flat = vec![80u8; w * h];
        let all_active = vec![1u8; w * h];
        let mut ens = EnsembleDetector::new(w * h);
        let mut cen = CensusDetector::new(w * h);
        ens.seed_if_needed(&flat);
        cen.seed_if_needed(&flat);
        for _ in 0..20 {
            ens.commit(
                &flat,
                FrameContext {
                    lightning: false,
                    event_active: false,
                },
                &all_active,
            );
            cen.commit(
                &flat,
                FrameContext {
                    lightning: false,
                    event_active: false,
                },
                &all_active,
            );
        }
        // A flat bright patch (still flat internally) appears.
        let mut obj = flat.clone();
        for y in 8..16 {
            for x in 8..16 {
                obj[y * w + x] = 160;
            }
        }
        let mut em = vec![0u8; w * h];
        let mut cm = vec![0u8; w * h];
        ens.foreground(&obj, w, h, &all_active, &mut em);
        cen.foreground(&obj, w, h, &all_active, &mut cm);
        let ens_fg = em.iter().filter(|&&v| v != 0).count();
        let cen_fg = cm.iter().filter(|&&v| v != 0).count();
        assert!(
            ens_fg > cen_fg,
            "ensemble must surface a flat patch census misses (ens={ens_fg}, census={cen_fg})",
        );
        assert!(
            ens_fg >= 36,
            "the 8×8 flat-patch interior should be flagged, got {ens_fg}"
        );
    }

    #[test]
    fn ensemble_vetoes_global_illumination_change() {
        // A textured static scene, brightened uniformly: MOG2 lights up the whole
        // frame, census stays dark (ordering preserved). The ensemble's lightning
        // veto must suppress MOG2 → near-zero foreground, preserving census's
        // illumination immunity (the whole reason census is primary).
        let (w, h) = (24usize, 24usize);
        let mut scene = vec![0u8; w * h];
        for y in 0..h {
            for x in 0..w {
                scene[y * w + x] = (50 + ((x * 7 + y * 11) % 90)) as u8; // textured 50..139
            }
        }
        let all_active = vec![1u8; w * h];
        let mut ens = EnsembleDetector::new(w * h);
        ens.seed_if_needed(&scene);
        for _ in 0..30 {
            ens.commit(
                &scene,
                FrameContext {
                    lightning: false,
                    event_active: false,
                },
                &all_active,
            );
        }
        let brighter: Vec<u8> = scene.iter().map(|&v| v.saturating_add(40)).collect();
        let mut em = vec![0u8; w * h];
        ens.foreground(&brighter, w, h, &all_active, &mut em);
        let fg = em.iter().filter(|&&v| v != 0).count();
        assert!(
            fg * 100 < w * h * 10,
            "a global brightness change must stay <10% foreground under the ensemble veto, got {fg}/{}",
            w * h,
        );
    }

    #[test]
    fn ensemble_default_algorithm() {
        assert_eq!(
            EnsembleDetector::new(16).algorithm_id(),
            MotionAlgorithm::Ensemble
        );
    }

    // ── Real-footage replay bench (opt-in) ────────────────────────────────────
    //
    // Tuning bench for the detectors against REAL clips. Skipped unless
    // `CRUMB_REPLAY_DIR` points at a folder of `.mp4`/`.mkv` files. Decodes each
    // clip through the SAME ffmpeg → gray-320 pipeline the recorder uses, runs
    // every algorithm through the SAME morphology/blob/threshold scoring, and
    // prints a per-clip × per-detector report (triggered? peak score, frames over
    // floor). The filename is the ground truth: a name containing "quiet",
    // "empty", "notrigger", or "none" is expected NOT to trigger; anything else is
    // expected TO trigger. Run with:
    //
    //   CRUMB_REPLAY_DIR=/path/to/clips cargo test -p crumb-recorder \
    //       replay_motion_clips -- --ignored --nocapture
    //
    // It's #[ignore] so the normal suite never depends on ffmpeg or sample files.

    /// Probe (width, height) of a video file via ffprobe.
    fn replay_probe_dims(path: &std::path::Path) -> Option<(u32, u32)> {
        let out = std::process::Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=width,height",
                "-of",
                "csv=s=x:p=0",
            ])
            .arg(path)
            .output()
            .ok()?;
        let s = String::from_utf8_lossy(&out.stdout);
        let (w, h) = s.trim().split_once('x')?;
        Some((w.trim().parse().ok()?, h.trim().parse().ok()?))
    }

    /// Decode `path` to a flat sequence of `w*h` gray frames (same scale + format
    /// the recorder's motion sub-stream decode uses).
    fn replay_decode_gray(path: &std::path::Path, w: usize, h: usize) -> Vec<Vec<u8>> {
        let out = std::process::Command::new("ffmpeg")
            .args(["-v", "error", "-i"])
            .arg(path)
            .args([
                "-an",
                "-vf",
                &format!("scale={w}:{h},format=gray"),
                "-f",
                "rawvideo",
                "-pix_fmt",
                "gray",
                "pipe:1",
            ])
            .output()
            .expect("run ffmpeg");
        let frame = w * h;
        out.stdout.chunks_exact(frame).map(<[u8]>::to_vec).collect()
    }

    /// Run one detector over a decoded clip and return (triggered, peak_score,
    /// frames_over_floor). Mirrors run_pixel_diff_loop sections a–g (sans the
    /// exclusion mask and dynamic auto-calibration; manual blob floor).
    fn replay_score(
        algo: MotionAlgorithm,
        frames: &[Vec<u8>],
        w: usize,
        h: usize,
    ) -> (bool, f32, usize) {
        let n = w * h;
        let total = n as f32;
        let floor = BLOB_FRACTION;
        let mut det = detector_for_algorithm(algo, n);
        // Replay bench has no exclusion mask → all pixels active.
        let all_active = vec![1u8; n];
        let (mut mask, mut eroded, mut dilated, mut dtmp) =
            (vec![0u8; n], vec![0u8; n], vec![0u8; n], vec![0u8; n]);
        let mut labels = vec![0u32; n];
        let (mut parent, mut areas): (Vec<u32>, Vec<u32>) = (Vec::new(), Vec::new());

        let mut peak = 0f32;
        let mut over = 0usize;
        let mut run = 0usize;
        let mut triggered = false;
        let mut seen = 0u64;

        for f in frames {
            if det.seed_if_needed(f) {
                continue;
            }
            seen += 1;
            det.foreground(f, w, h, &all_active, &mut mask);
            let on = mask.iter().filter(|&&v| v != 0).count();
            let lightning = (on as f32 / total) > LIGHTNING_FRACTION;
            erode_mask(&mask, &mut eroded, w, h);
            dilate_mask(&eroded, &mut dilated, w, h);
            for _ in 1..DILATE_ITERS {
                std::mem::swap(&mut dilated, &mut dtmp);
                dilate_mask(&dtmp, &mut dilated, w, h);
            }
            let largest =
                connected_components(&dilated, w, h, &mut labels, &mut parent, &mut areas);
            let score = largest as f32 / total;
            peak = peak.max(score);
            let warming = seen <= WARMUP_FRAMES;
            let hit = !warming && !lightning && score >= floor;
            if hit {
                over += 1;
                run += 1;
                if run >= MOTION_START_FRAMES {
                    triggered = true;
                }
            } else {
                run = 0;
            }
            // `event_active` drives the detector's slow-update rate during motion,
            // exactly as the live loop's MotionState::Active does.
            det.commit(
                f,
                FrameContext {
                    lightning,
                    event_active: hit,
                },
                &all_active,
            );
        }
        (triggered, peak, over)
    }

    #[test]
    #[ignore = "opt-in: set CRUMB_REPLAY_DIR to a folder of sample clips"]
    fn replay_motion_clips() {
        let Ok(dir) = std::env::var("CRUMB_REPLAY_DIR") else {
            eprintln!("CRUMB_REPLAY_DIR unset — skipping replay bench");
            return;
        };
        let mut clips: Vec<std::path::PathBuf> = std::fs::read_dir(&dir)
            .expect("read CRUMB_REPLAY_DIR")
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                matches!(
                    p.extension().and_then(|e| e.to_str()),
                    Some("mp4" | "mkv" | "mov" | "ts" | "avi")
                )
            })
            .collect();
        clips.sort();
        assert!(!clips.is_empty(), "no video clips found in {dir}");

        let algos = [
            MotionAlgorithm::Census,
            MotionAlgorithm::FrameDiff,
            MotionAlgorithm::Mog2,
            MotionAlgorithm::OpticalFlow,
            MotionAlgorithm::Ensemble,
        ];

        println!(
            "\n=== Motion detector replay bench ({} clips) ===",
            clips.len()
        );
        println!(
            "floor = {:.4} (BLOB_FRACTION); ✓ = matched filename expectation\n",
            BLOB_FRACTION
        );

        for clip in &clips {
            let name = clip.file_name().unwrap().to_string_lossy().to_string();
            let lower = name.to_ascii_lowercase();
            let expect_quiet = ["quiet", "empty", "notrigger", "none", "notrig"]
                .iter()
                .any(|k| lower.contains(k));
            let Some((iw, ih)) = replay_probe_dims(clip) else {
                println!("{name}: ffprobe failed — skipped");
                continue;
            };
            let w = MOTION_FRAME_WIDTH as usize;
            // Even height preserving aspect (matches the recorder's scale=320:H).
            let h =
                (((MOTION_FRAME_WIDTH as f64 * ih as f64 / iw as f64).round() as usize) / 2) * 2;
            let frames = replay_decode_gray(clip, w, h);
            println!(
                "▶ {name}  ({iw}x{ih} → {w}x{h}, {} frames, expect {})",
                frames.len(),
                if expect_quiet { "QUIET" } else { "MOTION" }
            );
            if frames.len() < 5 {
                println!("   (too few frames — skipped)\n");
                continue;
            }
            for algo in algos {
                let (trig, peak, over) = replay_score(algo, &frames, w, h);
                let ok = if expect_quiet { !trig } else { trig };
                println!(
                    "   {:>11}: {:<9} peak={:6.3}%  over={:>4}  {}",
                    algo.as_str(),
                    if trig { "TRIGGER" } else { "quiet" },
                    peak * 100.0,
                    over,
                    if ok { "✓" } else { "✗ MISMATCH" },
                );
            }
            println!();
        }
    }

    // ── health aggregator: dropped source sender ⇒ fail-open ────────────────────

    /// Await the camera health watch reaching `want`, with a hard timeout so a
    /// broken aggregator fails the test instead of hanging it.
    async fn wait_for_camera_health(rx: &mut tokio::sync::watch::Receiver<bool>, want: bool) {
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            rx.wait_for(|&v| v == want),
        )
        .await
        .expect("timed out waiting for the aggregated camera health value")
        .expect("camera health watch sender dropped");
    }

    /// A source task that panics drops its health sender without ever running
    /// its "motion source exiting" unhealthy report. The aggregator must NOT
    /// keep the source's last-known (healthy) reading — the gate has to fail
    /// open (record everything, correctness item 19), never leave a
    /// Motion-mode camera gated on a dead detector.
    #[tokio::test]
    async fn dropped_source_sender_drives_fail_open() {
        let (src_tx, src_rx) = tokio::sync::watch::channel(false);
        let (cam_tx, mut cam_rx) = tokio::sync::watch::channel(false);
        let cancel = CancellationToken::new();
        let aggregator = tokio::spawn(aggregate_health(
            vec![SourceKind::Pixel],
            Some(src_rx),
            None,
            None,
            cam_tx,
            uuid::Uuid::nil(),
            cancel.clone(),
        ));

        // The source proves healthy → the camera is healthy (motion-gated).
        src_tx.send(true).expect("aggregator holds the receiver");
        wait_for_camera_health(&mut cam_rx, true).await;

        // The source task "panics": its sender is dropped mid-healthy. The
        // camera must flip to fail-open, not freeze on the stale healthy.
        drop(src_tx);
        wait_for_camera_health(&mut cam_rx, false).await;

        cancel.cancel();
        let _ = aggregator.await;
    }
}
