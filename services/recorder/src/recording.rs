// SPDX-License-Identifier: AGPL-3.0-or-later

//! Recording task — ffmpeg segment writer and segment index writer.
//!
//! # Responsibility
//!
//! Owns one `ffmpeg -c copy -f segment` child process per camera.  For each
//! completed segment:
//!
//! * Derives precise `start_ts` / `end_ts` from the strftime-encoded filename
//!   (correctness item 3).
//! * Inserts one [`segments`](crumb_common::types::Segment) row.
//! * In **continuous** mode: indexes every segment; stamps `has_motion` from
//!   overlapping [`MotionSignal`]s (correctness item 15).
//! * In **motion** mode: maintains a ring buffer of un-indexed segments; on a
//!   motion start flushes the pre-buffer then indexes live; continues
//!   `motion_post_seconds` after stop.
//!
//! # ffmpeg invocation rules (correctness items 1–4)
//!
//! 1. Pass `-segment_format_options movflags=+frag_keyframe+empty_moov+default_base_moof`
//!    so fMP4 flags reach the inner mp4 muxer (not the segment muxer).
//! 2. Use `-c copy -segment_atclocktime 1 -reset_timestamps 1` for keyframe
//!    alignment and clock-aligned timestamps.
//! 3. Derive timestamps from strftime filenames, not from wall-clock at log
//!    observation.
//! 4. Use a segment-list pipe (`-segment_list pipe:1`) for boundary detection,
//!    **not** stderr log scraping.
//!
//! # Pipe safety (correctness item 5)
//!
//! The ffmpeg child's stderr is drained in a separate task to prevent the
//! ~64 KB pipe buffer from filling and blocking the child.
//!
//! # Shutdown (correctness item 6)
//!
//! On [`CancellationToken`](tokio_util::sync::CancellationToken) cancellation,
//! the ffmpeg child is killed immediately via `child.kill()`.  We do **not**
//! wait for it to produce more output.
//!
//! # Cold-start fast retry (recorder-restart footage gap)
//!
//! On a recorder restart, the embedded go2rtc comes up with NO streams (they
//! are runtime-managed by the api's reconcile loop, not `go2rtc.yaml` — see
//! `services/api/src/go2rtc.rs`), so every camera's first ffmpeg attempt this
//! process's life fails immediately (go2rtc has nothing to serve yet). The
//! outer `run()` loop classifies that specific failure (`classify_failure`)
//! and retries at `COLD_START_RETRY_DELAY` (2s) instead of paying the full
//! exponential backoff up to `BACKOFF_MAX` (30s) — bounded by
//! `COLD_START_MAX_FAST_RETRIES` so a stream that keeps failing fast forever
//! (not just during a cold start) still falls back to the normal backoff.
//! Steady-state reconnect behavior (a stream that already proved it can
//! connect, then drops) is completely unchanged.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use crumb_common::{
    config::Config,
    db::{self, InsertSegmentParams},
    types::{Camera, RecordingMode, SegmentStage, SegmentStream},
    MotionSignal,
};
use deadpool_postgres::Pool;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};

use crate::{MotionHealthRx, MotionRx};

// ─── backoff constants ────────────────────────────────────────────────────────

/// Initial back-off before restarting a failed ffmpeg process.
const BACKOFF_INIT: Duration = Duration::from_secs(1);
/// Maximum back-off cap.
const BACKOFF_MAX: Duration = Duration::from_secs(30);
/// Multiplier applied to the current backoff on each successive failure.
const BACKOFF_FACTOR: u32 = 2;

/// Fast retry delay used only for the "go2rtc not ready yet" cold-start class
/// (see [`FailureClass::ColdStartNotReady`]). Short enough that a recorder
/// restart's ~45 s window until the api's go2rtc reconcile re-PUTs streams
/// (see `services/api/src/go2rtc.rs`) costs a handful of quick retries instead
/// of paying the full `BACKOFF_MAX` (30 s) tail — the measured prod gap was
/// ~70 s of lost footage per camera per recorder restart, dominated by this
/// worker sitting in a 30 s backoff sleep *after* go2rtc already had the
/// stream available.
const COLD_START_RETRY_DELAY: Duration = Duration::from_secs(2);

/// Cap on consecutive cold-start-classified fast retries before falling back
/// to the normal exponential backoff, even if every failure still classifies
/// as [`FailureClass::ColdStartNotReady`].
///
/// GUARDRAIL: this is what keeps a genuinely, permanently unreachable stream
/// (bad URL, camera never coming back, go2rtc itself down for good) from being
/// hammered at `COLD_START_RETRY_DELAY` forever — see `classify_failure`'s
/// doc comment for the full reasoning. 15 retries * 2 s = 30 s of fast
/// retries, matching one `BACKOFF_MAX` interval, before the outer loop's
/// exponential backoff takes over exactly as it did before this change.
const COLD_START_MAX_FAST_RETRIES: u32 = 15;

// ─── failure classification (cold-start fast retry) ──────────────────────────

/// How a `run_ffmpeg_loop` failure should be retried.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FailureClass {
    /// "go2rtc isn't serving this stream yet" — ffmpeg's process for this run
    /// never produced even one segment before exiting. Safe to retry fast
    /// (bounded by `COLD_START_MAX_FAST_RETRIES`).
    ColdStartNotReady,
    /// Anything else: a stream that was working and then failed, a config/DB
    /// error resolving storage, an ffmpeg spawn failure, a stalled/hung
    /// stream, etc. Always the normal exponential backoff.
    SteadyState,
}

/// Classify a `run_ffmpeg_loop` failure to decide fast-retry eligibility.
///
/// `saw_segment` is the run's `saw_segment` out-param: `true` iff ffmpeg
/// reported at least one segment-list line before this run ended (i.e. it
/// successfully opened the RTSP source at least once). `eof_no_data` is
/// `true` only for the specific "ffmpeg stdout closed (process exited)"
/// error path taken when ffmpeg exits (normally or on error) *before* the
/// segment-receipt watchdog would have fired — i.e. a fast exit, not a long
/// stall.
///
/// Returns [`FailureClass::ColdStartNotReady`] ONLY when both are true:
/// ffmpeg exited fast (`eof_no_data`) AND never produced a single segment
/// this run (`!saw_segment`). That combination is precisely what a
/// freshly-restarted recorder sees while the api's go2rtc reconcile loop
/// hasn't re-PUT the stream yet: ffmpeg connects to go2rtc, gets an
/// immediate "stream not found"-class response, and exits within
/// milliseconds — long before `SEGMENT_RECEIPT_TIMEOUT_SECS` (90s) would
/// even have a chance to fire.
///
/// # Why this can't turn into hammering a dead camera (the guardrail)
///
/// * A camera that has EVER produced a segment in this process's life
///   (`saw_segment == true`) never classifies as cold-start again, even if
///   it fails a moment later — a stream that already proved it can connect
///   is not the "go2rtc hasn't caught up yet" case, it's a real disconnect,
///   and gets the normal backoff.
/// * A stall (watchdog timeout) is never cold-start, regardless of
///   `saw_segment` — it already paid the full 90s wait, so there is no
///   startup-latency problem left to compensate for.
/// * Even a stream that fails fast on EVERY attempt (e.g. a permanently bad
///   RTSP URL) only gets `COLD_START_MAX_FAST_RETRIES` (30s total) of fast
///   retries before the outer loop in `run()` falls back to the normal
///   exponential backoff up to `BACKOFF_MAX` — see `run()`.
fn classify_failure(saw_segment: bool, eof_no_data: bool) -> FailureClass {
    if !saw_segment && eof_no_data {
        FailureClass::ColdStartNotReady
    } else {
        FailureClass::SteadyState
    }
}

// ─── segment-receipt watchdog ─────────────────────────────────────────────────

/// Maximum time to wait for ffmpeg to write any segment to the stdout list pipe
/// before declaring the recording stream dead and forcing a reconnect.
///
/// This watchdog fires when:
/// * go2rtc resets a stream's internal producer (e.g. a Frigate restart
///   flips the shared stream): ffmpeg's TCP connection may stay half-open with
///   no EOF or error, so it stops producing segments silently.
/// * A freshly started (or live-reconfig-restarted) worker whose ffmpeg child
///   connects to go2rtc but never opens the source (live-reconfig half-init):
///   ffmpeg hangs before writing the first segment line, so the `seg_lines`
///   reader never yields and the anchored watchdog arm fires.
///
/// The watchdog is a dedicated `select!` arm anchored to the last segment
/// receipt (`last_segment_at`), NOT a per-iteration `timeout` wrapper — the
/// latter was silently reset by the motion-cache telemetry tick every 45 s and
/// so never fired (issue #71); see the `run_ffmpeg_loop` select loop.
///
/// A healthy camera on a 4–10 s segment produces a new stdout line every 4–10 s.
/// Any gap this long (90 s = ~9–22 missed segments) is unambiguously a dead
/// stream.  The value is deliberately generous so a legitimate ffmpeg startup
/// (which may take several seconds to open the RTSP stream and align to the
/// first keyframe) is never spuriously evicted.
///
/// Back-off in the outer `run()` loop prevents restart storms on a persistently
/// unreachable stream.
///
/// This is the DEFAULT only. The effective per-camera timeout is
/// `max(configured, 2 × GOP_seconds)`, where `configured` comes from the
/// `SEGMENT_RECEIPT_TIMEOUT_SECS` env override (clamped to
/// `[MIN_SEGMENT_RECEIPT_TIMEOUT_SECS, MAX_SEGMENT_RECEIPT_TIMEOUT_SECS]`) and
/// `GOP_seconds` is probed from the stream — see
/// [`configured_segment_receipt_timeout_secs`] and
/// [`probe_keyframe_interval_secs`]. The GOP-derived floor is what keeps a
/// smart-codec / long-GOP camera (Hikvision/Dahua "H.264+/H.265+", adaptive or
/// long keyframe intervals, or very low fps) from being falsely reconnected
/// forever: with `-c copy -f segment` a segment only closes on a keyframe, so
/// the segment cadence equals the camera's I-frame interval, NOT
/// `segment_seconds`.
const SEGMENT_RECEIPT_TIMEOUT_SECS: u64 = 90;

/// Lower clamp for the `SEGMENT_RECEIPT_TIMEOUT_SECS` env override. Even an
/// operator who wants a fast heal cannot set it so low that a couple of missed
/// segments on a healthy stream cause a false eviction; the per-camera
/// `2 × GOP` floor further protects cameras with a long keyframe interval.
const MIN_SEGMENT_RECEIPT_TIMEOUT_SECS: u64 = 20;

/// Upper clamp for the `SEGMENT_RECEIPT_TIMEOUT_SECS` env override. A camera
/// that is genuinely dead must still heal within a bounded time (an hour is the
/// most extreme "record on a very long GOP" case we tolerate before forcing a
/// reconnect).
const MAX_SEGMENT_RECEIPT_TIMEOUT_SECS: u64 = 3600;

/// Consecutive stall→reconnect cycles that produced ZERO segments before we
/// raise the camera-tagged `stream_no_segments` system event. Each cycle is at
/// least one full watchdog timeout long, so three cycles is several minutes of
/// "connects but records nothing" — long enough to be unambiguous, short enough
/// to surface the misconfiguration before much footage is lost. The event's
/// rule cooldown (900 s) throttles any re-emit.
const NO_SEGMENT_STALL_ALERT_THRESHOLD: u32 = 3;

/// Seconds of stream the keyframe (GOP) probe reads before giving up. A window
/// this wide reliably captures two keyframes for the common 1–8 s keyframe
/// intervals; a genuinely long-GOP camera whose interval exceeds the window
/// yields <2 keyframes → `None` → the configured default is kept, and the
/// `stream_no_segments` event (plus the env override) is the operator's remedy.
/// Runs in the background at worker start so it never delays the start of
/// recording (see the probe spawn in `run_ffmpeg_loop`).
const GOP_PROBE_WINDOW_SECS: u64 = 12;

/// Read the operator's `SEGMENT_RECEIPT_TIMEOUT_SECS` env override, clamped to a
/// sane range, defaulting to [`SEGMENT_RECEIPT_TIMEOUT_SECS`] when unset or
/// unparseable. Read once per worker (in [`run`]); an out-of-range value is
/// clamped rather than rejected so a fat-fingered env never wedges the recorder.
fn configured_segment_receipt_timeout_secs() -> u64 {
    clamp_segment_receipt_timeout_secs(
        std::env::var("SEGMENT_RECEIPT_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok()),
    )
}

/// Pure clamp/default logic behind [`configured_segment_receipt_timeout_secs`],
/// split out so it is unit-testable without touching the process environment:
/// `None` (unset/unparseable) → default; otherwise clamped to the sane range.
fn clamp_segment_receipt_timeout_secs(raw: Option<u64>) -> u64 {
    match raw {
        Some(s) => s.clamp(
            MIN_SEGMENT_RECEIPT_TIMEOUT_SECS,
            MAX_SEGMENT_RECEIPT_TIMEOUT_SECS,
        ),
        None => SEGMENT_RECEIPT_TIMEOUT_SECS,
    }
}

/// Best-effort probe of the stream's keyframe (GOP) interval, in seconds.
///
/// With `-c copy -f segment` a segment only closes on a keyframe, so the stall
/// watchdog must be at least twice the keyframe interval or a long-GOP camera is
/// reconnected forever without ever recording. We ffprobe the video packets over
/// a bounded [`GOP_PROBE_WINDOW_SECS`] window and take the LARGEST gap between
/// consecutive keyframe packets (so adaptive-GOP jitter can only make the floor
/// more generous, never less).
///
/// Returns `None` on ANY failure — `ffprobe` missing, the stream unreachable, no
/// video track, or fewer than two keyframes observed in the window (a GOP longer
/// than the window) — in which case the caller keeps the configured default.
/// Bounded timeout so a slow/unready source never stalls anything (this runs in
/// a detached background task).
async fn probe_keyframe_interval_secs(url: &str) -> Option<f64> {
    let fut = tokio::process::Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-rtsp_transport",
            "tcp",
            "-select_streams",
            "v:0",
            "-show_entries",
            "packet=pts_time,flags",
            "-of",
            "csv=print_section=0",
            // Read only the first GOP_PROBE_WINDOW_SECS of stream, then stop.
            "-read_intervals",
            &format!("%+{GOP_PROBE_WINDOW_SECS}"),
            "-i",
            url,
        ])
        // Reap the probe child if the timeout below drops this future, so a
        // hung ffprobe never lingers (correctness item 6 spirit).
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(Duration::from_secs(GOP_PROBE_WINDOW_SECS + 5), fut)
        .await
        .ok()? // timed out
        .ok()?; // failed to spawn (e.g. ffprobe absent)
    if !out.status.success() {
        return None;
    }
    // Lines are "<pts_time>,<flags>"; keyframe packets carry a leading 'K' in
    // the flags field (e.g. "1.400000,K__"). Collect keyframe timestamps.
    let mut kf_times: Vec<f64> = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let mut cols = line.split(',');
        let pts = cols.next().and_then(|s| s.trim().parse::<f64>().ok());
        let flags = cols.next().unwrap_or("");
        if let Some(t) = pts {
            if flags.trim_start().starts_with('K') {
                kf_times.push(t);
            }
        }
    }
    if kf_times.len() < 2 {
        // Fewer than two keyframes in the window → cannot measure the interval.
        return None;
    }
    // Largest inter-keyframe gap (handles adaptive GOP): the watchdog floor must
    // clear the WORST case seen, not the average.
    let mut max_gap = 0.0f64;
    for pair in kf_times.windows(2) {
        let gap = pair[1] - pair[0];
        if gap > max_gap {
            max_gap = gap;
        }
    }
    (max_gap > 0.0).then_some(max_gap)
}

/// How often each recording worker reports motion-cache telemetry (global
/// filesystem free/total + this camera's ring occupancy) to the DB — see
/// `report_motion_cache_status`. Telemetry only, entirely off the recording
/// hot path; a slow/modest cadence (well above the segment interval) is
/// plenty for an operator-facing RAM gauge that updates every admin-console
/// page load.
const MOTION_CACHE_STATUS_INTERVAL_SECS: u64 = 45;

// ─── public entry point ───────────────────────────────────────────────────────

/// Run the recording task for `camera` until `cancel` is triggered.
///
/// `motion_rx` receives [`MotionSignal`]s from the companion motion task.
/// The function is `async` and should be spawned via `tokio::spawn`.
///
/// # Error handling
///
/// The function logs errors and applies exponential back-off before restarting
/// the ffmpeg child.  It never panics and never calls `unwrap()` / `expect()`
/// in the hot path.
///
/// # Arguments
///
/// * `camera`     — fully-resolved camera config with joined policy.
/// * `pool`       — database connection pool (deadpool-postgres).
/// * `config`     — global recorder config (segment length, storage paths, etc.).
/// * `motion_rx`  — receives [`MotionSignal`]s from `motion.rs`.
/// * `health_rx`  — receives the motion detector's health signal from `motion.rs`
///   (fail-open safety rail — see [`MotionHealthRx`]).
/// * `cancel`     — shared cancellation token; set when the worker is stopped.
pub async fn run(
    camera: Camera,
    pool: Pool,
    config: Config,
    mut motion_rx: MotionRx,
    health_rx: MotionHealthRx,
    cancel: CancellationToken,
) {
    info!(
        camera_id   = %camera.id,
        camera_name = %camera.name,
        mode        = %camera.policy.mode.as_str(),
        "recording task started"
    );

    let mut backoff = BACKOFF_INIT;

    // #73 (reconnect mid-motion-event): the motion state machine must SURVIVE
    // ffmpeg reconnects. These three used to be locals of `run_ffmpeg_loop`,
    // rebuilt on every reconnect — so an ffmpeg error/stall mid-event reset the
    // buffer to Idle and the union to "no open sources", the event's queued
    // STOP then hit the fresh union as an unmatched edge (ignored), and every
    // segment of the event's remainder went into the Idle ring and was
    // eventually DISCARDED (the detector task keeps running across the
    // reconnect and does not re-emit a START for an already-open event).
    // Owning them here — one instance per worker lifetime, passed `&mut` into
    // each `run_ffmpeg_loop` run — keeps the Recording/PostBuffer state, the
    // union's open-source set, and the accumulated `pending_signals` (for
    // `has_motion` stamping) intact across the reconnect, so an ongoing motion
    // event keeps persisting. A worker RESPAWN (config change / process
    // restart) still starts fresh, exactly as before, and starts fail-open
    // (the health watch is seeded `false`) until the detector proves itself.
    let mut motion_buf = MotionBuffer::new(
        camera.policy.motion_pre_seconds as i64,
        camera.policy.motion_post_seconds as i64,
    );
    let mut motion_union = MotionUnion::default();
    let mut pending_signals: Vec<MotionSignal> = Vec::new();

    // Cold-start fast-retry counter (see `classify_failure` / `COLD_START_MAX_FAST_RETRIES`).
    // Counts CONSECUTIVE cold-start-classified failures; reset to 0 the instant
    // a failure classifies as anything else, or a segment is ever indexed, so
    // it never lingers across an unrelated later failure.
    let mut cold_start_retries: u32 = 0;

    // P0-3: per-camera segment-receipt stall-watchdog timeout, worker-lifetime.
    //
    // Seeded with the operator-configured default and only ever RAISED (never
    // lowered) to `2 × GOP_seconds` once the background keyframe probe reports
    // back — a smart-codec / long-GOP camera would otherwise stall the watchdog
    // and be reconnected forever without recording. It is an `Arc<AtomicU64>`
    // (not a plain field) because the probe runs in a DETACHED background task
    // so it never delays the start of recording; the select loop reads the
    // current value each iteration. Because the value can only increase, a
    // late-arriving probe result can only make the watchdog MORE lenient, never
    // cause a spurious eviction.
    let configured_watchdog_secs = configured_segment_receipt_timeout_secs();
    let watchdog_secs = Arc::new(AtomicU64::new(configured_watchdog_secs));
    // The GOP probe is spawned at most once per worker (on the first
    // `run_ffmpeg_loop` that reaches the point where the RTSP URL is known);
    // this flag guards against re-probing on every reconnect.
    let mut gop_probe_spawned = false;

    // P0-3: count CONSECUTIVE stall→reconnect cycles that produced ZERO
    // segments. When it reaches `NO_SEGMENT_STALL_ALERT_THRESHOLD` we raise the
    // camera-tagged `stream_no_segments` event ONCE (further re-emits are
    // throttled by the alert rule's cooldown). Reset the instant the stream
    // produces any segment (see `stream_healthy` below).
    let mut consecutive_no_seg_stalls: u32 = 0;

    loop {
        // Check for shutdown before attempting to start ffmpeg.
        if cancel.is_cancelled() {
            break;
        }

        // R6: `indexed_ok` is set by `run_ffmpeg_loop` (out-param) the first
        // time this run successfully indexes a segment — i.e. the stream is
        // confirmed healthy again. Without this, a camera that once hit
        // BACKOFF_MAX paid up to 30s of lost footage on every future blip
        // forever, since `backoff` was only ever initialized once before the
        // loop and multiplied toward the cap, never reset back down.
        let mut indexed_ok = false;
        // See `run_ffmpeg_loop`'s doc comment: `saw_segment` + `eof_no_data`
        // together identify the "go2rtc not ready yet" cold-start failure class.
        let mut saw_segment = false;
        let mut eof_no_data = false;
        // P0-3: set by `run_ffmpeg_loop` when THIS run ended via the
        // segment-receipt stall watchdog (as opposed to a clean EOF / setup
        // error). Combined with `!saw_segment` it identifies a "connected but
        // recorded nothing" cycle for the `stream_no_segments` counter.
        let mut watchdog_stalled = false;
        let outcome = run_ffmpeg_loop(
            &camera,
            &pool,
            &config,
            &mut motion_rx,
            &health_rx,
            &cancel,
            &mut motion_buf,
            &mut motion_union,
            &mut pending_signals,
            &mut indexed_ok,
            &mut saw_segment,
            &mut eof_no_data,
            &mut watchdog_stalled,
            configured_watchdog_secs,
            &watchdog_secs,
            &mut gop_probe_spawned,
        )
        .await;

        // "Stream healthy again" is determined by `saw_segment` (ffmpeg produced
        // at least one segment-list line this run), NOT `indexed_ok` (a segment
        // was KEPT). A Motion-mode camera on a healthy stream with no motion
        // rings/discards every segment and never indexes one, so keying the
        // reset on `indexed_ok` left its backoff ratcheting toward BACKOFF_MAX
        // (30s) across idle-night blips forever — and a real event starting
        // during one of those 30s windows lost its opening seconds with an empty
        // pre-roll ring. A stream that demonstrably produced and processed
        // segments is healthy regardless of the keep/discard verdict.
        let stream_healthy = saw_segment;
        if stream_healthy && backoff != BACKOFF_INIT {
            debug!(
                camera_id   = %camera.id,
                camera_name = %camera.name,
                "stream healthy again (segments produced); resetting reconnect backoff"
            );
            backoff = BACKOFF_INIT;
        }
        if stream_healthy {
            // A confirmed-healthy stream is by definition not in the cold-start
            // window anymore; a later failure starts the fast-retry count fresh.
            cold_start_retries = 0;
            // P0-3: a produced segment clears the "records nothing" streak.
            consecutive_no_seg_stalls = 0;
        }

        // P0-3: a stall→reconnect cycle that produced ZERO segments is the
        // long-GOP / smart-codec silent-failure signature (ffmpeg connects, no
        // EOF, no error, but never closes a segment before the watchdog fires).
        // Count consecutive such cycles and, on crossing the threshold, raise a
        // camera-tagged `stream_no_segments` event ONCE so the operator sees it
        // instead of a camera that silently records nothing forever. We fire at
        // EXACTLY the threshold (not `>=`) so one sustained outage yields one
        // event; the alert-rule cooldown throttles anything further, and the
        // counter only re-arms after `stream_healthy` resets it above.
        if watchdog_stalled && !saw_segment {
            consecutive_no_seg_stalls = consecutive_no_seg_stalls.saturating_add(1);
            if consecutive_no_seg_stalls == NO_SEGMENT_STALL_ALERT_THRESHOLD {
                let effective = watchdog_secs.load(Ordering::Relaxed);
                let reason = format!(
                    "camera produced no segments across {NO_SEGMENT_STALL_ALERT_THRESHOLD} \
                     consecutive {effective}s stall/reconnect cycles — check the camera's \
                     keyframe (I-frame) interval or disable its smart codec \
                     (H.264+/H.265+), or raise SEGMENT_RECEIPT_TIMEOUT_SECS"
                );
                error!(
                    camera_id   = %camera.id,
                    camera_name = %camera.name,
                    effective_watchdog_secs = effective,
                    "camera records nothing: no segments across {} stall cycles",
                    NO_SEGMENT_STALL_ALERT_THRESHOLD
                );
                if let Err(e) = crumb_common::db::insert_system_event(
                    &pool,
                    "stream_no_segments",
                    Some(camera.id),
                    Some(&reason),
                )
                .await
                {
                    warn!(
                        camera_id = %camera.id,
                        error = %e,
                        "failed to record stream_no_segments system event"
                    );
                }
            }
        }

        match outcome {
            Ok(()) => {
                // run_ffmpeg_loop returned Ok only when cancel was fired.
                break;
            }
            Err(e) => {
                if cancel.is_cancelled() {
                    // A shutdown happened while we were setting up; don't log
                    // it as an error.
                    break;
                }

                let class = classify_failure(saw_segment, eof_no_data);
                let use_fast_retry = class == FailureClass::ColdStartNotReady
                    && cold_start_retries < COLD_START_MAX_FAST_RETRIES;

                if use_fast_retry {
                    cold_start_retries += 1;
                    debug!(
                        camera_id      = %camera.id,
                        camera_name    = %camera.name,
                        error          = %e,
                        retry_secs     = COLD_START_RETRY_DELAY.as_secs(),
                        attempt        = cold_start_retries,
                        max_attempts   = COLD_START_MAX_FAST_RETRIES,
                        "recording ffmpeg loop exited before any segment (cold start); fast retry"
                    );
                    // Fast retry: deliberately does NOT touch `backoff` — the
                    // normal exponential backoff is untouched and resumes from
                    // wherever it was if/when this stream stops classifying as
                    // cold-start (guardrail: see classify_failure).
                    tokio::select! {
                        () = tokio::time::sleep(COLD_START_RETRY_DELAY) => {}
                        () = cancel.cancelled() => { break; }
                    }
                } else {
                    // Falling out of the cold-start fast path (either this
                    // failure didn't classify as cold-start, or we exhausted
                    // COLD_START_MAX_FAST_RETRIES) — reset the counter so a
                    // LATER genuine cold-start window (e.g. a subsequent
                    // recorder restart) gets the full fast-retry budget again.
                    cold_start_retries = 0;
                    error!(
                        camera_id   = %camera.id,
                        camera_name = %camera.name,
                        error       = %e,
                        backoff_secs = backoff.as_secs(),
                        "recording ffmpeg loop exited with error; will retry"
                    );
                    // Wait for the backoff period, but respect cancellation.
                    tokio::select! {
                        () = tokio::time::sleep(backoff) => {}
                        () = cancel.cancelled() => { break; }
                    }
                    backoff = (backoff * BACKOFF_FACTOR).min(BACKOFF_MAX);
                }
            }
        }
    }

    info!(
        camera_id   = %camera.id,
        camera_name = %camera.name,
        "recording task stopped"
    );
}

/// Inner loop: resolve storage, spawn ffmpeg, read the segment list pipe.
///
/// Returns `Ok(())` on a clean shutdown (cancel fired).
/// Returns `Err(…)` on any unexpected failure so the outer loop can back-off.
///
/// `indexed_ok` (R6) is an out-param set to `true` the first time a segment is
/// successfully indexed during this run — via `&mut bool` rather than folded
/// into the return value, so early setup failures (storage resolution, ffmpeg
/// spawn — all still using plain `?`) don't need to thread it through, and so
/// the caller sees it even on a run that ultimately returns `Err` (e.g.
/// indexed several segments, THEN stalled).
///
/// `saw_segment` (cold-start fast-retry) is an out-param set to `true` the
/// moment ffmpeg reports its FIRST segment-list line on stdout — i.e. ffmpeg
/// successfully opened the RTSP source at least once this run, regardless of
/// whether that segment ever got indexed. This is a strictly earlier signal
/// than `indexed_ok` and is what `classify_failure` uses to tell "ffmpeg never
/// even connected this run" (candidate for the fast cold-start retry) apart
/// from "connected fine, then the stream died later" (must use the normal
/// backoff — seeing streams before is evidence the source is real and can
/// legitimately go away again, which is exactly the case the guardrail in
/// `classify_failure` must not fast-retry).
///
/// `eof_no_data` (cold-start fast-retry) is an out-param set to `true` only
/// when this run ends via the immediate-EOF path ("ffmpeg stdout closed
/// (process exited)") — i.e. ffmpeg's process exited on its own, as opposed
/// to the segment-receipt watchdog forcing a reconnect after a stall, or a
/// setup/IO error. A dedicated out-param (rather than matching on the error
/// string) keeps `classify_failure` decoupled from this function's exact
/// error message wording.
///
/// `motion_buf` / `motion_union` / `pending_signals` are the worker-lifetime
/// motion state, owned by [`run`] and passed `&mut` so they SURVIVE ffmpeg
/// reconnects (#73) — an ongoing motion event's Recording state, the union's
/// open-source set, and the accumulated signals all carry across an
/// error/stall restart of the ffmpeg child instead of being silently reset
/// (which used to discard the remainder of the event).
/// The audio ffmpeg args for the `-c copy` (video) segmenter, given the camera's
/// `record_audio` policy.
///
/// - `record_audio == false` → `-an` (drop the audio output stream).
/// - otherwise → **re-encode to a gap-filled, sample-continuous 48 kHz AAC**
///   (`-af aresample=async=1:first_pts=0 -c:a aac -ar 48000`).
///
/// Why ALWAYS re-encode (docs/DECISIONS.md 2026-07-13, superseding the
/// 2026-07-12 "copy when the rate is client-safe" split): a bit-exact `-c:a copy`
/// preserves the camera's audio *timeline* verbatim, and cheap camera audio
/// clocks drift ~1 % — the container timestamps promise more time than the AAC
/// frames deliver (measured ~32 ms phantom gap per 4 s segment). ExoPlayer's
/// `DefaultAudioSink` requires sample-continuous audio: once the accumulated
/// drift crosses ~200 ms it throws `UnexpectedDiscontinuityException`, and
/// because the audio renderer is the player's master clock the position lurches,
/// segments "end" early, and playback wedges (silent audio, stalled video). The
/// premise that "≤ 48 kHz ⇒ client-safe to copy" is empirically false — 48 kHz
/// copies were silent on Android. `aresample=async=1` resamples onto a strictly
/// continuous lattice (fills genuine gaps with silence, preserving A/V
/// alignment), so the recorded track has ZERO discontinuities on every client
/// (verified: 61/62 discontinuous frames on the copy path → 0/192 after; a plain
/// re-encode WITHOUT `aresample` still left 75, because it inherits the input's
/// jittery frame PTS). `first_pts=0` anchors the audio start.
///
/// No `-copyinkf:a` here: that flag existed only for the `-c copy` path (RTP-AAC
/// is never key-flagged, so a bare copy declared a zero-packet track —
/// RECORDER-CORRECTNESS #23). Re-encoding decodes from PCM, so there is no
/// keyframe gate. These args come AFTER `-c copy`, overriding ONLY the audio;
/// video stays a bit-exact copy.
fn audio_segmenter_args(record_audio: bool) -> &'static [&'static str] {
    if !record_audio {
        &["-an"]
    } else {
        &[
            "-af",
            "aresample=async=1:first_pts=0",
            "-c:a",
            "aac",
            "-ar",
            "48000",
        ]
    }
}

/// Best-effort probe of the first audio stream's sample rate (Hz) at `url`, for
/// the admin console's per-camera audio status. Returns `None` on ANY failure —
/// no audio
/// stream, `ffprobe` missing, a timeout, or go2rtc not serving yet — so the
/// caller safely falls back to transcode. Bounded timeout so a slow/unready
/// source never stalls the start of recording (the recorder records from the
/// go2rtc restream, so this is a local consumer, not a camera connection).
async fn probe_audio_sample_rate(url: &str) -> Option<u32> {
    let fut = tokio::process::Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-rtsp_transport",
            "tcp",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=sample_rate",
            "-of",
            "default=nokey=1:noprint_wrappers=1",
            "-i",
            url,
        ])
        .output();
    let out = tokio::time::timeout(std::time::Duration::from_secs(4), fut)
        .await
        .ok()? // timed out
        .ok()?; // failed to spawn (e.g. ffprobe absent)
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .and_then(|s| s.trim().parse::<u32>().ok())
}

#[allow(clippy::too_many_arguments)]
async fn run_ffmpeg_loop(
    camera: &Camera,
    pool: &Pool,
    config: &Config,
    motion_rx: &mut MotionRx,
    health_rx: &MotionHealthRx,
    cancel: &CancellationToken,
    motion_buf: &mut MotionBuffer,
    motion_union: &mut MotionUnion,
    pending_signals: &mut Vec<MotionSignal>,
    indexed_ok: &mut bool,
    saw_segment: &mut bool,
    eof_no_data: &mut bool,
    // P0-3: set to `true` when this run ends via the segment-receipt stall
    // watchdog arm (not a clean EOF or a setup/IO error), so the caller can
    // count zero-segment stall cycles for the `stream_no_segments` event.
    watchdog_stalled: &mut bool,
    // P0-3: the operator-configured watchdog default (already env-read+clamped
    // by `run`), used as the probe's baseline and the immediate select-loop
    // deadline until the background GOP probe (if any) raises `watchdog_secs`.
    configured_watchdog_secs: u64,
    // P0-3: worker-lifetime effective watchdog timeout (seconds). Read each loop
    // iteration; raised by the background keyframe probe to `max(configured,
    // 2 × GOP)`. Never lowered, so it can only make the watchdog more lenient.
    watchdog_secs: &Arc<AtomicU64>,
    // P0-3: guards the one-shot GOP probe spawn across reconnects.
    gop_probe_spawned: &mut bool,
) -> Result<()> {
    // ── 1. Resolve live storage ────────────────────────────────────────────────

    // A segment's physical location is owned by its storage_id. Resolve this
    // worker's live disk by the policy's live_storage_id when set (authoritative);
    // only when it is NULL fall back to the configured default storage NAME (A1c).
    let live_storage = if let Some(sid) = camera.policy.live_storage_id {
        db::get_storage(pool, sid)
            .await
            .context("get_storage by policy id")?
            .with_context(|| format!("live_storage_id {} from policy not found in storages", sid))?
    } else {
        // NULL-policy fallback: prefer resolving the configured default storage ROW
        // (and thereafter use its id) rather than carrying the name around. Defend
        // against an ambiguous config where the name maps to >1 row — though
        // `storages.name` is UNIQUE so this should be impossible, a loud warning
        // beats silently picking one if that invariant is ever weakened.
        let candidates = db::find_storages_by_name(pool, &config.live_storage_name)
            .await
            .context("find_storages_by_name (live default)")?;
        // Panic-free by construction (audit 2026-07-05): consume the vec via its
        // iterator instead of `.len()`-match + `.next().expect()`, so there is no
        // unreachable-panic path in this footage-start path even if the length
        // invariant is ever weakened.
        let count = candidates.len();
        let mut it = candidates.into_iter();
        match it.next() {
            None => {
                anyhow::bail!(
                    "live storage '{}' not found; run the seed first",
                    config.live_storage_name
                );
            }
            Some(first) => {
                if count > 1 {
                    warn!(
                        name = %config.live_storage_name,
                        count,
                        "AMBIGUOUS default live storage: NAME maps to >1 storage row; using the first. \
                         Set the policy's live_storage_id explicitly to disambiguate."
                    );
                }
                first
            }
        }
    };

    // ── 2. Build output path and ensure directory exists ───────────────────────

    // Segment path (prototype): {live.path}/{camera_id}/{start_ts}.mp4 — FLAT.
    // ffmpeg's segment muxer does NOT create directories (and -strftime_mkdir is
    // not honoured by it), so nested %Y/%m/%d/ dirs would make every segment-open
    // fail. We keep the layout flat under the camera dir and encode the full UTC
    // timestamp in the filename. The DB segment index is the source of truth for
    // layout; nested date dirs are a future scale optimisation that needs
    // day-rollover directory management.
    let camera_dir = PathBuf::from(&live_storage.path).join(camera.id.to_string());

    if let Err(e) = tokio::fs::create_dir_all(&camera_dir).await {
        // P0-1: the default-install footgun — a root-owned host media dir makes
        // this fail EACCES on the recorder's non-root uid (1001), and today it
        // just errors per-reconnect so the operator sees a silent "no footage"
        // with no obvious cause. Raise a distinct, LOUD system event on
        // PermissionDenied specifically (the actionable misconfiguration) so the
        // operator gets "recorder can't write to storage — footage is NOT being
        // saved". Other errors (a transiently-unmounted disk, etc.) fall through
        // to the normal error path unchanged. The event's rule cooldown throttles
        // the per-reconnect re-emit, matching the `motion_cache_unavailable`
        // precedent below.
        if e.kind() == std::io::ErrorKind::PermissionDenied {
            let reason = format!(
                "cannot create media directory {camera_dir:?}: {e} — footage is NOT being \
                 saved; check the host media dir ownership/permissions (the recorder runs as \
                 non-root uid 1001)"
            );
            error!(
                camera_id = %camera.id,
                dir = ?camera_dir,
                error = %e,
                "storage unwritable: cannot create camera media directory (footage NOT saved)"
            );
            if let Err(ev) = crumb_common::db::insert_system_event(
                pool,
                "storage_unwritable",
                Some(camera.id),
                Some(&reason),
            )
            .await
            {
                warn!(
                    camera_id = %camera.id,
                    error = %ev,
                    "failed to record storage_unwritable system event"
                );
            }
        }
        return Err(anyhow::Error::from(e).context(format!("create_dir_all {camera_dir:?}")));
    }

    // ── 2b. Motion-mode RAM cache dir (persist-on-motion) ──────────────────────
    //
    // For Motion-mode cameras (and shadow mode OFF), ffmpeg writes segments into
    // MOTION_CACHE_DIR/{camera_id}/ instead of the storage root. `MotionBuffer`
    // then decides per segment whether to copy it into storage (persist) or
    // delete it from the cache (discard) — see `finish_completed_segment` below.
    //
    // Continuous-mode cameras and shadow-mode cameras are UNCHANGED: they always
    // write straight to `camera_dir` (the storage root), exactly as before this
    // feature existed. `use_motion_cache` gates every cache-specific branch
    // below; when it is `false` this function is byte-for-byte the pre-feature
    // code path.
    let use_motion_cache =
        camera.policy.mode == RecordingMode::Motion && !config.motion_recording_shadow;

    let write_dir = if use_motion_cache {
        match resolve_motion_cache_dir(pool, config, camera.id).await {
            Ok(dir) => match tokio::fs::create_dir_all(&dir).await {
                Ok(()) => {
                    // R1: clear any leftover files from a previous in-process
                    // restart — a crash mid-recording can leave cache files with
                    // no corresponding MotionBuffer state (the buffer is
                    // reconstructed fresh on every worker spawn), so stale files
                    // would sit in the cache forever, never persisted or
                    // discarded through the normal path, and — worse — could be
                    // mistaken for a NEW segment if ffmpeg ever reused a
                    // strftime-clashing filename. Best-effort: a failure to
                    // clean is logged and does not block recording (the stale
                    // files just linger; they are never indexed since they are
                    // not in a storage root, so reconcile never sees them).
                    //
                    // #73: the motion buffer now SURVIVES ffmpeg reconnects
                    // (see `run`), so on a reconnect the carried ring's
                    // segments still reference live files in this cache dir —
                    // the sweep must skip exactly those (deleting them would
                    // make every later persist of a ring segment fail, losing
                    // the pre-roll). A fresh worker spawn has an empty ring,
                    // so the keep-set is empty and the sweep behaves exactly
                    // as before.
                    let mut keep = std::collections::HashSet::new();
                    for seg in &motion_buf.pending {
                        keep.insert(PathBuf::from(&seg.path));
                    }
                    if let Err(e) = clear_dir_contents(&dir, &keep).await {
                        warn!(
                            camera_id = %camera.id,
                            dir = ?dir,
                            error = %e,
                            "failed to clear leftover motion-cache files at worker start (non-fatal)"
                        );
                    }
                    Some(dir)
                }
                Err(e) => {
                    error!(
                        camera_id = %camera.id,
                        dir = ?dir,
                        error = %e,
                        "failed to create motion cache dir; falling back to direct-to-storage \
                         recording (every segment will be indexed, same as continuous mode)"
                    );
                    let reason = format!("cache dir create failed: {e}");
                    if let Err(e) = crumb_common::db::insert_system_event(
                        pool,
                        "motion_cache_unavailable",
                        Some(camera.id),
                        Some(&reason),
                    )
                    .await
                    {
                        warn!(
                            camera_id = %camera.id,
                            error = %e,
                            "failed to record motion_cache_unavailable system event"
                        );
                    }
                    None
                }
            },
            Err(e) => {
                error!(
                    camera_id = %camera.id,
                    error = %e,
                    "motion cache dir rejected; falling back to direct-to-storage recording"
                );
                let reason = format!("cache dir rejected: {e}");
                if let Err(e) = crumb_common::db::insert_system_event(
                    pool,
                    "motion_cache_unavailable",
                    Some(camera.id),
                    Some(&reason),
                )
                .await
                {
                    warn!(
                        camera_id = %camera.id,
                        error = %e,
                        "failed to record motion_cache_unavailable system event"
                    );
                }
                None
            }
        }
    } else {
        None
    };
    // Effective write directory: the cache dir when Motion-mode caching is
    // active and healthy, else the storage root (continuous mode, shadow mode,
    // or any cache-dir failure — the documented fall-open-to-today's-behaviour
    // path from the spec).
    let effective_write_dir: &Path = write_dir.as_deref().unwrap_or(&camera_dir);
    // Did we actually end up caching? (write_dir resolved AND use_motion_cache
    // was requested — mirrors `write_dir.is_some()` but names the concept used
    // throughout the rest of this function.)
    let caching_active = write_dir.is_some();

    // ── 2c. #73 flip-guard: settle carried ring entries this run cannot manage
    //
    // The motion ring now survives reconnects (see `run`). Within one worker a
    // ring entry's file lives in exactly one of two places: this camera's
    // cache dir (buffered by a caching-active run) or the storage camera dir
    // (a fallback/direct-to-storage run drives the buffer for shadow
    // bookkeeping only). If the cache-dir resolution FLIPPED across the
    // reconnect, entries of the other flavor must be settled NOW, footage-safe:
    //
    // * fallback→caching: a storage-dir entry was already persisted AND
    //   indexed by the fallback run (fallback indexes every segment), so it
    //   simply leaves the ring with no file operation. Leaving it in would be
    //   DESTRUCTIVE: a later pre-roll flush would run the cache persist's
    //   copy-then-delete on a storage path — a self-copy that truncates, then
    //   deletes, an already-indexed segment file.
    // * caching→fallback: a cache-dir entry is unmanageable this run (the
    //   fallback path never executes cache file ops), which would leak the
    //   buffered pre-roll — persist it to storage right away instead (same
    //   footage-safe mechanics as a cache-pressure spill; at worst this
    //   writes a few segments of idle pre-roll).
    //
    // On a same-mode reconnect every entry lives under `effective_write_dir`
    // and the ring is carried through completely untouched.
    if !motion_buf.pending.is_empty() {
        let mut carried = VecDeque::new();
        for seg in motion_buf.drain_ring() {
            if ring_entry_lives_under(&seg, effective_write_dir) {
                carried.push_back(seg);
            } else if !caching_active {
                // Cache-dir entry while this run is fallback → persist now.
                persist_cached_segment(
                    &seg,
                    camera,
                    &live_storage.id,
                    &live_storage.path,
                    &camera_dir,
                    pool,
                    pending_signals,
                )
                .await;
            }
            // else: a storage-dir entry in a caching run — already indexed by
            // the fallback run that buffered it; it safely leaves the ring.
        }
        motion_buf.pending = carried;
    }

    // strftime pattern for segment filenames (UTC), flat under the EFFECTIVE
    // write dir (cache dir when caching_active, else camera_dir as before).
    let segment_pattern = effective_write_dir
        .join("%Y%m%dT%H%M%SZ.mp4")
        .to_string_lossy()
        .into_owned();

    // ── 3. Determine recording URL ─────────────────────────────────────────────
    //
    // §6.3 / O3: `main_url` now holds a RELATIVE stream name (e.g. "driveway")
    // for cameras added or migrated via 0012. Legacy rows keep full absolute URLs
    // (they contain "://") and are passed through unchanged by `resolve_stream_url`.
    //
    // Base resolution: read server_settings from DB (the operator-filled table);
    // fall back to the `go2rtc_rtsp_base` env value for BOTH crumb and frigate
    // on a single-host prototype where the operator hasn't filled Server Settings.
    // This is the documented single-host fallback (see §6.3 decision note).
    let (crumb_rtsp_base, frigate_rtsp_base) = resolve_rtsp_bases(pool, config).await;
    // P0-GO2RTC (lighter lockdown): go2rtc's RTSP listener now requires auth for
    // non-loopback callers, which the recorder's connection is (it crosses the
    // Docker bridge network by service name / LAN address). Only inject into the
    // CRUMB base — frigate_rtsp_base is a separate BYO instance with its own
    // (possibly absent) credentials Crumb doesn't own.
    let crumb_rtsp_base = crumb_common::db::inject_rtsp_credentials(
        &crumb_rtsp_base,
        &config.go2rtc_user,
        &config.go2rtc_pass,
    );

    // Determine the stream name: sub-stream when the policy says so, else main.
    let stream_name = match camera.policy.record_stream {
        crumb_common::types::RecordStream::Sub => camera
            .sub_url
            .clone()
            .filter(|u| !u.is_empty())
            .unwrap_or_else(|| format!("{}_sub", camera.go2rtc_name)),
        crumb_common::types::RecordStream::Main => camera.main_url.clone(),
    };

    let rtsp_url = crumb_common::db::resolve_stream_url(
        &camera.served_by,
        &stream_name,
        &crumb_rtsp_base,
        &frigate_rtsp_base,
    );
    // #18: redact embedded credentials (user:pass@host) before logging at INFO
    // so camera passwords never appear in plaintext logs.
    let redacted_url = redact_rtsp_credentials(&rtsp_url);
    info!(
        camera_id = %camera.id,
        url = %redacted_url,
        "recording from RTSP source"
    );

    // ── 3b. P0-3: keyframe (GOP) probe → per-camera stall-watchdog floor ────────
    //
    // With `-c copy -f segment` a segment only closes on a keyframe, so the
    // segment cadence equals the camera's I-frame interval, NOT `segment_seconds`.
    // A smart-codec / long-GOP camera (Hikvision/Dahua "H.264+/H.265+", adaptive
    // or long keyframe intervals, or very low fps) can therefore go longer than
    // the watchdog between segments, be killed+reconnected forever, and record
    // NOTHING. We probe the keyframe interval and raise the watchdog to at least
    // `2 × GOP`.
    //
    // The probe runs in a DETACHED background task (spawned at most once per
    // worker) so it never delays the start of recording: ffmpeg starts
    // immediately using the configured default, and the watchdog only becomes
    // MORE lenient once the probe reports back. Reading the shared `watchdog_secs`
    // atomic each select iteration picks up the raised value with no further
    // plumbing. A probe failure (no video, GOP longer than the probe window,
    // ffprobe absent) leaves the configured default in place — the
    // `stream_no_segments` event is the operator-facing backstop for that tail.
    if !*gop_probe_spawned {
        *gop_probe_spawned = true;
        let probe_url = rtsp_url.clone();
        let watchdog_secs = Arc::clone(watchdog_secs);
        let configured = configured_watchdog_secs;
        let camera_id = camera.id;
        tokio::spawn(async move {
            let Some(gop) = probe_keyframe_interval_secs(&probe_url).await else {
                debug!(
                    camera_id = %camera_id,
                    "keyframe (GOP) probe did not yield an interval; keeping configured watchdog"
                );
                return;
            };
            // 2 × GOP, rounded up; the watchdog floor must clear the worst-case
            // keyframe gap with headroom.
            let floor = (gop * 2.0).ceil().max(0.0) as u64;
            let effective = configured.max(floor).min(MAX_SEGMENT_RECEIPT_TIMEOUT_SECS);
            // Publish only if it actually raises the timeout (never lower it).
            let prev = watchdog_secs.fetch_max(effective, Ordering::Relaxed);
            info!(
                camera_id = %camera_id,
                gop_secs = gop,
                configured_secs = configured,
                effective_secs = effective.max(prev),
                "segment-receipt watchdog floored to 2 × keyframe interval"
            );
        });
    }

    // ── 4. Build ffmpeg argv ───────────────────────────────────────────────────
    //
    // Correctness items 1–4:
    // #1 — -segment_format_options movflags=... (reaches inner mp4 muxer).
    // #2 — -c copy, -segment_atclocktime 1, -reset_timestamps 1.
    // #3 — strftime filenames as the timestamp source.
    // #4 — -segment_list pipe:1 (stdout) for boundary detection; no stderr parsing.

    let segment_secs_str = config.segment_seconds.to_string();

    // ffmpeg writes completed segment paths to stdout (one per line).
    // We read stdout for segment boundaries.
    //
    // Correctness item 5: stderr is drained in a separate task.
    //
    // Build the Command as an owned value so we can conditionally append `-an`
    // based on the camera policy before calling `.spawn()`.
    let mut ffmpeg_cmd = Command::new("ffmpeg");
    ffmpeg_cmd
        // TZ PIN (index-correctness): ffmpeg's `-strftime 1` expands the
        // segment filename pattern via LOCALTIME, but our pattern ends in a
        // literal `Z` and `parse_segment_timestamp` parses it as UTC. If the
        // container runs with TZ set (docker-compose sets
        // `TZ=${TZ:-America/Los_Angeles}` on the recorder since the go2rtc
        // embed carried the restreamer's env over), every filename — and
        // therefore every segment row's start_ts/end_ts — lands shifted by
        // the UTC offset (-7/-8h for LA): `max(start_ts)` freezes at the last
        // correctly-stamped row, motion-overlap stamping misses, and
        // retention ages footage hours early. Pinning TZ=UTC for the ffmpeg
        // CHILD ONLY keeps the filename==UTC contract regardless of what TZ
        // the operator sets on the container (which go2rtc/log timestamps
        // legitimately use).
        .env("TZ", "UTC")
        // Global options
        .args(["-hide_banner", "-loglevel", "warning"])
        // RTSP input options
        .args(["-rtsp_transport", "tcp"])
        .args(["-i", &rtsp_url])
        // Encoding: bit-exact video copy. Audio is handled below (copied when the
        // source rate is already client-safe, else transcoded to 48 kHz) — see
        // audio_segmenter_args; those args override ONLY the audio.
        .args(["-c", "copy"])
        // Force the HEVC sample entry to `hvc1` (not ffmpeg's default `hev1`).
        // Apple's AVFoundation (iOS/macOS AVPlayer) will NOT decode HEVC in MP4
        // tagged `hev1` — it requires `hvc1` — so without this the iOS client
        // shows a black/empty video on every H.265 camera's recorded playback.
        // ExoPlayer (Android) accepts both, which masked this. `-tag:v hvc1` is a
        // pure container-level retag (no transcode); harmless for H.264 streams.
        .args(["-tag:v", "hvc1"]);

    // Audio handling (see [`audio_segmenter_args`]).  These come AFTER `-c copy`
    // so they override ONLY the audio (video stays a bit-exact copy). Audio is
    // ALWAYS re-encoded to a gap-filled, sample-continuous 48 kHz AAC now (a bare
    // `-c copy` burns the camera's drifting audio clock into the file and Android
    // playback goes silent — see the fn doc). We still probe the SOURCE rate,
    // purely so the admin console can show it; the probe is a local consumer of
    // the go2rtc restream, not an extra camera connection.
    let audio_sample_rate = if camera.policy.record_audio {
        let sample_rate = probe_audio_sample_rate(&rtsp_url).await;
        info!(
            camera_id = %camera.id,
            audio_sample_rate = ?sample_rate,
            "audio: re-encoding to gap-filled 48 kHz AAC (sample-continuous for all clients)"
        );
        sample_rate
    } else {
        None
    };
    // Publish the per-camera audio status for the admin console. `transcoding` is
    // now simply "are we recording audio" (we always re-encode). Best-effort — a
    // DB hiccup must never stop recording.
    if let Err(e) = crumb_common::db::upsert_camera_audio_status(
        pool,
        camera.id,
        audio_sample_rate.and_then(|r| i32::try_from(r).ok()),
        camera.policy.record_audio,
    )
    .await
    {
        warn!(camera_id = %camera.id, error = %e, "upsert_camera_audio_status failed (audio badge may be stale)");
    }
    ffmpeg_cmd.args(audio_segmenter_args(camera.policy.record_audio));

    ffmpeg_cmd
        // Segmenter muxer
        .args(["-f", "segment"])
        .args(["-segment_time", &segment_secs_str])
        .args(["-segment_atclocktime", "1"]) // correctness #2: clock-aligned
        .args(["-reset_timestamps", "1"]) // correctness #2: independent timestamps
        .args(["-segment_format", "mp4"])
        // Correctness #1: fMP4 flags must go to the inner mp4 muxer via -segment_format_options
        .args([
            "-segment_format_options",
            "movflags=+frag_keyframe+empty_moov+default_base_moof",
        ])
        .args(["-strftime", "1"]) // correctness #3: use strftime in filename
        // Correctness #4: stdout segment list for reliable boundary detection
        .args(["-segment_list", "pipe:1"])
        .args(["-segment_list_flags", "live"])
        .arg(&segment_pattern)
        // Pipe configuration: stdout = segment list, stderr = drain separately
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .stdin(std::process::Stdio::null())
        // Correctness item 6: reap the child if this future is dropped, so a
        // dropped recorder never leaks an ffmpeg process.
        .kill_on_drop(true);

    let mut child = ffmpeg_cmd
        .spawn()
        .context("spawn ffmpeg recording process")?;

    let ffmpeg_stdout = child.stdout.take().context("take ffmpeg stdout")?;
    let ffmpeg_stderr = child.stderr.take().context("take ffmpeg stderr")?;

    // ── 5. Drain stderr in a background task (correctness item 5) ─────────────
    //
    // A ~64 KB stderr pipe buffer that fills up blocks ffmpeg from writing video
    // data, which in turn blocks our stdout reader → deadlock.  We drain stderr
    // unconditionally and log at debug level.
    let camera_id_for_stderr = camera.id;
    let stderr_drain = tokio::spawn(async move {
        // Drain BYTES, not UTF-8 lines. ffmpeg warning lines can contain
        // non-UTF-8 bytes (camera-supplied stream metadata); `read_line`
        // returns InvalidData on those and the old `break` closed the pipe
        // under the LIVE recording child — the ~64 KB stderr buffer then fills,
        // ffmpeg blocks writing video, and the stdout segment reader blocks →
        // deadlock (correctness item 5). The task's contract is "keep the pipe
        // empty until EOF", not "log every line", so we read raw bytes, lossy-
        // decode only for the debug log, and CONTINUE (bounded) on an IO error
        // instead of breaking. (#76 fixed the go2rtc and motion drains the same
        // way; this recording-child drain was missed in the first pass.)
        const MAX_CONSECUTIVE_ERRORS: u32 = 100;
        let mut reader = BufReader::new(ffmpeg_stderr);
        let mut buf: Vec<u8> = Vec::with_capacity(256);
        let mut consecutive_errors: u32 = 0;
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf).await {
                Ok(0) => break, // EOF — child's stderr closed
                Ok(_) => {
                    consecutive_errors = 0;
                    let text = String::from_utf8_lossy(&buf);
                    let trimmed = text.trim_end();
                    if !trimmed.is_empty() {
                        debug!(
                            camera_id = %camera_id_for_stderr,
                            ffmpeg_stderr = %trimmed,
                            "ffmpeg (recording)"
                        );
                    }
                }
                Err(e) => {
                    // A pathologically erroring fd is bounded so teardown
                    // (`stderr_drain.await`) can never hang.
                    consecutive_errors += 1;
                    if consecutive_errors >= MAX_CONSECUTIVE_ERRORS {
                        debug!(
                            camera_id = %camera_id_for_stderr,
                            error = %e,
                            "ffmpeg recording stderr drain giving up after repeated errors"
                        );
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            }
        }
    });

    // ── 6. Read the segment list from stdout ───────────────────────────────────
    //
    // ffmpeg writes one line per completed segment to stdout (pipe:1):
    //   <path-to-segment>\n
    //
    // We process segments as a sliding window: when segment N+1 is reported,
    // segment N is complete.  At shutdown we handle the final segment specially.

    // A PERSISTENT, cancellation-safe line reader. `tokio::io::Lines` keeps its
    // partial-line state inside the iterator, so when a competing `select!` arm
    // (the telemetry tick, or the stall watchdog) wins and drops the in-flight
    // `next_line()` future, no half-read segment-list line is lost — unlike the
    // old per-call `read_line` into a fresh `String`, which was NOT
    // cancellation-safe and could drop a partial line every time the tick fired.
    let mut seg_lines = BufReader::new(ffmpeg_stdout).lines();

    // The motion buffer / union / pending-signal state for motion-mode cameras
    // is owned by `run` (worker lifetime) and passed in `&mut` so it survives
    // reconnects (#73) — see the parameter docs above. `finish_completed_segment`
    // reads `camera.policy.mode` directly, so no local copy is kept here.

    // Motion-cache telemetry tick (read-only reporter — see
    // `report_motion_cache_status`). Only meaningful for Motion-mode cameras,
    // but cheap enough to tick unconditionally rather than threading an extra
    // "am I motion mode" branch through the select loop; the reporter itself
    // no-ops for Continuous-mode cameras. `MissedTickBehavior::Delay` (the
    // default) is fine here — a missed tick under load just delays the next
    // report by one interval, never piles up catch-up ticks.
    let mut cache_status_interval =
        tokio::time::interval(Duration::from_secs(MOTION_CACHE_STATUS_INTERVAL_SECS));
    cache_status_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    // Accumulated motion signals drained from the channel during each segment:
    // `pending_signals`, carried across reconnects by `run` (#73).

    // Sliding window: the previous segment whose end_ts we derive from the
    // current segment's start_ts.
    let mut prev_segment: Option<PendingSegment> = None;

    // Stall-watchdog anchor: the instant of the last received segment-list line
    // (seeded at loop entry so a cold start that never produces a first segment
    // still trips the watchdog within the timeout). Bumped ONLY when a real line
    // arrives — never by the telemetry tick — so the watchdog deadline below is
    // stable across tick-only iterations. This is the fix for the gap-#1
    // silent-reset regression (see the watchdog `select!` arm).
    let mut last_segment_at = tokio::time::Instant::now();

    // A single closure-like helper (defined as a local async fn below rather
    // than a real closure, since it needs many `&`/`&mut` borrows of locals
    // that are also touched elsewhere in this loop) consolidates the
    // finish-one-completed-segment pipeline shared by all THREE call sites in
    // this function (the normal boundary, the cancel-triggered final segment,
    // and the post-loop reconnect/error in-flight recovery). See
    // `finish_completed_segment` below.

    let result: Result<()> = async {
        // NOTE: `indexed_ok` is the `&mut bool` out-param (R6), reborrowed by
        // this block since it is `async { }` not `async move { }` — mutations
        // here are visible after `.await` below and to the caller.
        loop {
            // We select between four events:
            // a) ffmpeg reports a new segment (stdout line via `seg_lines`)
            // b) the SEGMENT_RECEIPT_TIMEOUT_SECS stall watchdog (its own arm,
            //    anchored to `last_segment_at` — not a per-read timeout, which
            //    the telemetry tick used to silently reset, issue #71)
            // c) the cancellation token fires (shutdown)
            // d) the motion-cache telemetry tick
            //
            // tokio::select! polls all branches simultaneously.
            tokio::select! {
                // Priority: cancellation (biased = true gives it first crack).
                biased;

                () = cancel.cancelled() => {
                    // Correctness item 6: kill child immediately on shutdown.
                    kill_child(&mut child).await;
                    // Handle the final pending segment using file mtime.
                    if let Some(prev) = prev_segment.take() {
                        // R5: clamp the mtime-derived end_ts to a plausible
                        // segment duration — see `clamp_recovered_end_ts`.
                        let end_ts = match file_mtime_utc(&prev.path).await {
                            Ok(mtime) => {
                                clamp_recovered_end_ts(prev.start_ts, mtime, config.segment_seconds)
                            }
                            Err(_) => {
                                prev.start_ts
                                    + chrono::Duration::seconds(i64::from(config.segment_seconds))
                            }
                        };
                        // prev.size_bytes is the in-flight placeholder (0) — it's only
                        // filled at the NEXT boundary, which never comes for the FINAL
                        // segment on shutdown. Fetch the real size now (same file_size()
                        // the normal boundary uses) so the last segment isn't indexed
                        // with size_bytes=0 (data-integrity fix).
                        //
                        // Spec item 6 (shutdown / ffmpeg-exit recovery): whether this
                        // final in-flight segment should PERSIST or be left buffered
                        // depends on MotionBuffer's state at this instant —
                        // `finish_completed_segment` (via `decide_persist_for_segment` →
                        // `motion_buf.push_segment`) already encodes exactly that: Idle
                        // buffers it into the ring (simply abandoned in the cache on
                        // process exit — correct, since Idle means "not part of any
                        // motion event"; a fresh worker's R1 sweep cleans it up on next
                        // start), Recording/PostBuffer persists it. No special-casing
                        // needed here.
                        let size_bytes = file_size(&prev.path).await.unwrap_or(prev.size_bytes);
                        let completed = PendingSegment {
                            path:       prev.path.clone(),
                            start_ts:   prev.start_ts,
                            end_ts,
                            size_bytes,
                        };
                        if finish_completed_segment(
                            &completed,
                            camera,
                            config,
                            pool,
                            motion_rx,
                            health_rx,
                            pending_signals,
                            motion_buf,
                            motion_union,
                            &live_storage.id,
                            &live_storage.path,
                            &camera_dir,
                            caching_active,
                            write_dir.as_deref(),
                        )
                        .await
                        {
                            *indexed_ok = true;
                        }
                    }
                    return Ok(());
                }

                // Drain motion_rx while waiting for the next stdout line.
                // We use try_recv in a non-blocking fashion via a zero-timeout
                // select arm instead — see motion draining below the select.

                // Next segment-list line (cancellation-safe; see `seg_lines`).
                // The stall watchdog is now a SEPARATE arm below, so this read
                // is a plain await with no per-iteration timeout wrapper.
                read_result = seg_lines.next_line() => {
                    match read_result {
                        Ok(None) => {
                            // EOF on stdout: ffmpeg exited (either error or normal),
                            // WITHOUT the segment-receipt watchdog having to force
                            // it — a fast exit. `saw_segment` distinguishes "never
                            // produced a single segment this run" (classify_failure's
                            // cold-start signal) from "produced some, then died"
                            // (normal backoff) — see classify_failure's doc comment.
                            *eof_no_data = true;
                            return Err(anyhow::anyhow!("ffmpeg stdout closed (process exited)"));
                        }
                        Ok(Some(raw_line)) => {
                            // A segment-list line arrived → the stream is alive.
                            // Bump the watchdog anchor so its deadline moves
                            // forward off THIS receipt (the only place it does).
                            last_segment_at = tokio::time::Instant::now();
                            // First (or any) segment-list line received: ffmpeg
                            // did open the RTSP source this run. Set unconditionally
                            // (not just on the first line) — cheap, and correctness
                            // only needs "at least once", never "exactly once".
                            *saw_segment = true;

                            let new_path = raw_line.trim().to_owned();
                            if new_path.is_empty() {
                                continue;
                            }

                            // Derive start_ts from the new segment's filename.
                            // Materialise to an owned String so the borrow does
                            // not reference a temporary Path / OsStr value.
                            let filename_owned: String = Path::new(&new_path)
                                .file_name()
                                .and_then(|n| n.to_str())
                                .map(str::to_owned)
                                .unwrap_or_else(|| new_path.clone());
                            let new_start_ts = match parse_segment_timestamp(&filename_owned) {
                                Ok(ts) => ts,
                                Err(e) => {
                                    warn!(
                                        camera_id = %camera.id,
                                        filename  = %filename_owned,
                                        error     = %e,
                                        "cannot parse segment timestamp; skipping"
                                    );
                                    continue;
                                }
                            };

                            // Now that we have start_ts for the *new* segment, the
                            // previous segment's end_ts is known.
                            if let Some(prev) = prev_segment.take() {
                                // Fetch file size (the prev file is now complete).
                                let size_bytes = file_size(&prev.path).await.unwrap_or(0);
                                let completed = PendingSegment {
                                    path:       prev.path.clone(),
                                    start_ts:   prev.start_ts,
                                    end_ts:     new_start_ts,
                                    size_bytes,
                                };

                                // `finish_completed_segment` drains motion_rx itself
                                // (feeding MotionBuffer exactly once per new signal —
                                // see its doc comment) and executes the full
                                // persist/discard pipeline.
                                if finish_completed_segment(
                                    &completed,
                                    camera,
                                    config,
                                    pool,
                                    motion_rx,
                                    health_rx,
                                    pending_signals,
                                    motion_buf,
                                    motion_union,
                                    &live_storage.id,
                                    &live_storage.path,
                                    &camera_dir,
                                    caching_active,
                                    write_dir.as_deref(),
                                )
                                .await
                                {
                                    *indexed_ok = true;
                                }
                            }

                            // Record the new segment as "in flight". Reconstruct
                            // the ABSOLUTE path from the EFFECTIVE WRITE dir + the
                            // basename: ffmpeg's -segment_list reports only the
                            // basename, so using it raw broke file_size (size_bytes=0)
                            // and stored a path missing the camera subdir, so playback
                            // / archive / reconcile (which resolve {storage}/{path})
                            // could not find the file. When the motion cache is active
                            // this is the CACHE path (not the storage path) — the
                            // persist pipeline computes the storage destination
                            // separately (`persist_cached_segment`); a discard just
                            // deletes this cache path directly.
                            prev_segment = Some(PendingSegment {
                                path:       effective_write_dir
                                    .join(&filename_owned)
                                    .to_string_lossy()
                                    .into_owned(),
                                start_ts:   new_start_ts,
                                end_ts:     new_start_ts, // placeholder; filled on next iteration
                                size_bytes: 0,            // placeholder
                            });
                        }
                        Err(e) => {
                            return Err(
                                anyhow::Error::from(e).context("reading ffmpeg segment list")
                            );
                        }
                    }
                }

                // Segment-receipt stall watchdog. Fires when no new segment-list
                // line has arrived within the effective per-camera timeout of the
                // last one, forcing the loop to error out → reconnect. The
                // deadline is anchored to `last_segment_at` (bumped ONLY by a
                // real line in the read arm above), NOT rebuilt from "now" each
                // iteration, so the telemetry tick below — which returns from
                // the `select!` every MOTION_CACHE_STATUS_INTERVAL_SECS (45s <
                // the timeout) — can no longer push the deadline out and starve
                // the watchdog forever. That silent-reset was the gap-#1
                // regression: a half-open RTSP stream (no EOF, no error, no
                // segments) left the camera recording NOTHING indefinitely with
                // no reconnect.
                //
                // P0-3: the timeout is the worker-lifetime `watchdog_secs` atomic
                // (`max(configured, 2 × GOP)`), read fresh each iteration so a
                // late background-probe raise takes effect; it only ever
                // increases, so re-reading can only push the deadline LATER,
                // never cause a spurious early eviction. On fire we set
                // `*watchdog_stalled` so the caller can count zero-segment stall
                // cycles for the `stream_no_segments` event.
                () = tokio::time::sleep_until(
                    last_segment_at
                        + Duration::from_secs(watchdog_secs.load(Ordering::Relaxed))
                ) => {
                    *watchdog_stalled = true;
                    let timeout_secs = watchdog_secs.load(Ordering::Relaxed);
                    return Err(anyhow::anyhow!(
                        "recording stream stalled: no segment for {}s; forcing reconnect",
                        timeout_secs
                    ));
                }

                // Motion-cache telemetry tick (read-only; see
                // `report_motion_cache_status`). Placed last so cancellation
                // and segment-boundary handling always take priority under
                // `biased` selection.
                _ = cache_status_interval.tick() => {
                    report_motion_cache_status(
                        pool,
                        camera,
                        config,
                        &*motion_buf,
                        caching_active,
                        write_dir.as_deref(),
                    )
                    .await;
                }
            }
        }
    }
    .await;

    // Correctness item 6: on ALL exit paths (cancel, stdout EOF, stdout error)
    // kill the child unconditionally — killing an already-dead process is a
    // harmless no-op. This guarantees ffmpeg's stderr closes so the drain task
    // reaches EOF instead of blocking forever (the orphaned-ffmpeg deadlock).
    kill_child(&mut child).await;

    // Now the stderr drain task can finish (its pipe is closed).
    let _ = stderr_drain.await;

    // In-flight segment recovery on a RECONNECT/ERROR exit (not cancel).
    //
    // A segment's row is only inserted at the NEXT boundary line (the sliding
    // window derives its end_ts/size from the following segment's start). When
    // ffmpeg dies (EOF, stall watchdog, read error) that next line never comes,
    // so the last in-flight segment used to be dropped here un-indexed — one
    // orphan file per reconnect, on EVERY camera, accumulating until a restart's
    // reconcile adopted it. Index it now using the file's real mtime+size (the
    // same recovery the cancel branch does for the final segment), so a reconnect
    // no longer desyncs the index from disk.
    //
    // On the cancel path `prev_segment` was already taken+indexed inside the loop,
    // so this is a no-op there (no double insert; insert_segment is an UPSERT
    // anyway). `index_segment` fsyncs the file before inserting.
    if let Some(prev) = prev_segment.take() {
        // R5: clamp the mtime-derived end_ts to a plausible segment duration —
        // see `clamp_recovered_end_ts`.
        let end_ts = match file_mtime_utc(&prev.path).await {
            Ok(mtime) => clamp_recovered_end_ts(prev.start_ts, mtime, config.segment_seconds),
            Err(_) => prev.start_ts + chrono::Duration::seconds(i64::from(config.segment_seconds)),
        };
        let size_bytes = file_size(&prev.path).await.unwrap_or(prev.size_bytes);
        let completed = PendingSegment {
            path: prev.path.clone(),
            start_ts: prev.start_ts,
            end_ts,
            size_bytes,
        };
        // Spec item 6: same reasoning as the cancel-branch comment above —
        // MotionBuffer's state at this instant (Idle vs Recording/PostBuffer)
        // correctly decides whether this reconnect-orphaned in-flight segment
        // should persist or simply be left buffered in the cache. Since the
        // buffer now survives the reconnect (#73), an Idle-buffered segment
        // stays a live ring entry into the next run (the R1 sweep skips
        // ring-referenced files) and gets its keep/discard verdict through the
        // normal path there.
        if finish_completed_segment(
            &completed,
            camera,
            config,
            pool,
            motion_rx,
            health_rx,
            pending_signals,
            motion_buf,
            motion_union,
            &live_storage.id,
            &live_storage.path,
            &camera_dir,
            caching_active,
            write_dir.as_deref(),
        )
        .await
        {
            *indexed_ok = true;
        }
    }

    result
}

/// Consolidated "a segment just completed" pipeline, shared by all THREE call
/// sites in [`run_ffmpeg_loop`] (the normal segment-boundary path, the
/// cancel-triggered final segment, and the post-loop reconnect/error in-flight
/// recovery).
///
/// Order of operations:
/// 1. Drain + persist any new motion signals (`drain_and_persist_motion`),
///    feeding them into `motion_buf` when this is a Motion-mode camera with the
///    RAM cache active — this is the ONLY point signals are applied to the
///    buffer (edge-triggered on channel receive), so the same signal is never
///    double-applied across boundaries even though `signals`/`pending_signals`
///    is a cumulative snapshot re-read every call.
/// 2. Decide persist/discard for `completed` itself
///    (`decide_persist_for_segment` — handles Continuous, shadow mode, and the
///    fail-open detector-health override).
/// 3. Cache-pressure spill check (Motion mode + cache active only): force any
///    ring segments to persist if the cache filesystem is low on free space.
/// 4. Execute the merged decision (copy/fsync/index/delete or delete-only).
/// 5. In shadow mode, ALSO record what the buffer decided (without letting
///    that decision affect file operations — shadow mode already persisted
///    everything as a normal direct-to-storage segment in step 2/4).
///
/// Returns `true` iff any segment was newly indexed (for R6's `indexed_ok`).
#[allow(clippy::too_many_arguments)]
async fn finish_completed_segment(
    completed: &PendingSegment,
    camera: &Camera,
    config: &Config,
    pool: &Pool,
    motion_rx: &mut MotionRx,
    health_rx: &MotionHealthRx,
    pending_signals: &mut Vec<MotionSignal>,
    motion_buf: &mut MotionBuffer,
    motion_union: &mut MotionUnion,
    live_storage_id: &uuid::Uuid,
    live_storage_path: &str,
    camera_dir: &Path,
    caching_active: bool,
    write_dir: Option<&Path>,
) -> bool {
    let recording_mode = camera.policy.mode;
    let shadow_active = recording_mode == RecordingMode::Motion && config.motion_recording_shadow;
    // Read health ONCE up front so the signal-drain step (which may apply
    // signals to `motion_buf`) and the segment-push step agree on the same
    // reading for this call — a health flip mid-call must not let one step see
    // healthy and the other see unhealthy.
    let detector_healthy = *health_rx.borrow();
    // Fail-open (spec item 4): while the CACHE is active and the detector is
    // unhealthy, `motion_buf`'s STATE must not be driven — neither by signals
    // nor by the segment push — so it resumes where it left off once health
    // returns. Signals arriving during an unhealthy window come from the same
    // untrusted detector, so trusting them to drive Idle→Recording transitions
    // would be exactly the failure mode this rail exists to prevent. Two
    // footage-safety carve-outs to that freeze (both persist-only, and
    // neither drives a state transition during the window):
    // * #77 — segments already sitting in the ring at the transition are
    //   drained to PERSIST (see `decide_persist_for_segment`); they were
    //   awaiting a verdict the detector can no longer render, and "unknown"
    //   must resolve to "keep", never to a later age-out discard.
    // * #74 — drained signals are still FOLDED through `motion_union` (see
    //   `drain_and_persist_motion`) so its open-source accounting stays
    //   exact; the resulting synthetic edge is stashed and replayed to the
    //   buffer when it thaws, instead of being applied to the frozen buffer.
    // Health is irrelevant when the cache is NOT active (shadow/fallback):
    // there is no real persist-on-motion behaviour to fail-open FROM in that
    // case, so the buffer keeps running (for the shadow verdict) regardless
    // of detector health.
    let unhealthy_while_caching = caching_active && !detector_healthy;
    let drive_buffer = recording_mode == RecordingMode::Motion && !unhealthy_while_caching;

    // Step 1: drain signals. `drain_and_persist_motion` feeds the buffer and
    // returns its decisions into whichever accumulator we hand it. When the
    // cache is genuinely active AND healthy (real persist-on-motion), the
    // buffer's decision from signals IS the real decision — accumulate into
    // `actual`. When shadow/fallback (cache inactive, buffer still driven for
    // validation only), accumulate into `shadow` instead so it never touches
    // file operations. When unhealthy-while-caching, `drive_buffer` is false
    // so the buffer isn't fed — but the drain still folds every edge through
    // `motion_union` and stashes the newest synthetic edge for replay when
    // the buffer thaws (#74; see `drain_and_persist_motion`).
    let mut actual = MotionDecision::empty();
    let mut shadow = MotionDecision::empty();
    if caching_active && detector_healthy {
        drain_and_persist_motion(
            motion_rx,
            pending_signals,
            drive_buffer.then_some(&mut *motion_buf),
            motion_union,
            &mut actual,
        )
        .await;
    } else {
        drain_and_persist_motion(
            motion_rx,
            pending_signals,
            drive_buffer.then_some(&mut *motion_buf),
            motion_union,
            &mut shadow,
        )
        .await;
    }

    // Step 2: the segment-push decision.
    let seg_decision = decide_persist_for_segment(
        recording_mode,
        caching_active,
        detector_healthy,
        motion_buf,
        completed,
    );
    actual.persist.extend(seg_decision.actual.persist);
    actual.discard.extend(seg_decision.actual.discard);
    if let Some(sd) = seg_decision.shadow {
        shadow.persist.extend(sd.persist);
        shadow.discard.extend(sd.discard);
    }

    // Step 3: cache-pressure spill (Motion mode + cache active + detector
    // healthy only). Nothing to spill for continuous/shadow/fallback (which
    // never accumulate a ring), and nothing to spill while unhealthy-and-
    // caching either — that path already persists every segment directly and
    // its transition drain (#77, in `decide_persist_for_segment`) has already
    // emptied the ring into the persist set, so there is nothing left in the
    // ring to relieve pressure with.
    if caching_active && detector_healthy && recording_mode == RecordingMode::Motion {
        if let Some(cache_dir) = write_dir {
            let spilled =
                spill_oldest_if_under_pressure(cache_dir, motion_buf, completed.size_bytes);
            actual.persist.extend(spilled);
        }
    }

    // Step 4: execute the REAL decision only — `shadow` never touches a file.
    let signal_snapshot = pending_signals.clone();
    let any_indexed = execute_motion_decision(
        &actual,
        camera,
        live_storage_id,
        live_storage_path,
        camera_dir,
        pool,
        &signal_snapshot,
        caching_active,
    )
    .await;

    // Step 5: shadow-mode verdict recording — stamps `motion_shadow_keep`
    // against the rows `actual` just indexed (shadow mode always persists
    // everything, so every segment IS in `segments` by `(camera_id, path)` at
    // this point), using the buffer's real verdict recorded in `shadow`.
    if shadow_active {
        record_shadow_verdicts(&shadow, pool, camera.id, live_storage_path).await;
    }

    // Clear signals that have been fully applied (mirrors the pre-feature
    // behaviour — bounded by the segment's end_ts boundary).
    prune_pending_signals(pending_signals, completed.end_ts);

    any_indexed
}

// ─── motion RAM-cache telemetry (migration 0039) ─────────────────────────────

/// Best-effort report of this camera's motion RAM-cache truth, mirroring
/// `motion.rs`'s `report_decode_status`: recorder-side truth published to the
/// DB on a modest cadence (`MOTION_CACHE_STATUS_INTERVAL_SECS`), read back by
/// the API's `/config/motion-cache-status` endpoint for the admin console.
/// Entirely off the recording hot path — this is called from the same
/// `tokio::select!` loop that owns `motion_buf`, never from inside the
/// persist/discard pipeline, and a failed write here can never affect what
/// gets recorded.
///
/// Reports two things:
/// * The GLOBAL motion-cache filesystem free/total (via
///   `motion_cache_free_and_total`, the same statvfs call the spill check
///   already makes) plus whether shadow mode is on. `caching_active` here
///   describes THIS camera's cache dir — the DB upsert is a per-tick
///   overwrite of the singleton row, so in a multi-camera recorder the last
///   camera to tick "wins" the caching_active bit; that's fine because it is
///   only ever false when every Motion camera has fallen back (a real global
///   fact, not a per-camera one an operator needs disambiguated).
/// * This camera's ring occupancy (segment count + summed bytes) — only when
///   the camera is actually in Motion mode. A Continuous-mode camera reports
///   nothing here (mirrors `camera_decode_status`'s "absence means not
///   applicable"); a Motion-mode camera with an inactive cache (shadow mode
///   or a fallen-back cache dir) still reports a row, with 0/0, so the UI can
///   tell "0 buffered" apart from "never reported".
async fn report_motion_cache_status(
    pool: &Pool,
    camera: &Camera,
    config: &Config,
    motion_buf: &MotionBuffer,
    caching_active: bool,
    write_dir: Option<&Path>,
) {
    // Global filesystem truth: prefer the active cache dir (statvfs needs a
    // path that exists); fall back to the configured cache ROOT so a camera
    // that fell back to direct-to-storage still reports a meaningful
    // free/total for the shared tmpfs mount.
    let stat_path: &Path = write_dir.unwrap_or_else(|| Path::new(&config.motion_cache_dir));
    if let Some((free, total)) = motion_cache_free_and_total(stat_path) {
        if let Err(e) = db::upsert_motion_cache_status(
            pool,
            free,
            total,
            caching_active,
            config.motion_recording_shadow,
        )
        .await
        {
            debug!(
                error = %e,
                "motion-cache global status upsert failed (telemetry only)"
            );
        }
    }

    // Per-camera ring occupancy: only meaningful for Motion-mode cameras.
    if camera.policy.mode == RecordingMode::Motion {
        let (ring_segments, ring_bytes) = motion_buf.ring_stats();
        #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
        let ring_segments = ring_segments as i32;
        if let Err(e) =
            db::upsert_camera_motion_cache_status(pool, camera.id, ring_segments, ring_bytes).await
        {
            debug!(
                camera_id = %camera.id,
                error = %e,
                "motion-cache per-camera status upsert failed (telemetry only)"
            );
        }
    }
}

// ─── base URL resolution ──────────────────────────────────────────────────────

/// Resolve the RTSP base URLs for Crumb's restreamer and for an external
/// Frigate go2rtc instance.
///
/// Resolution order (§6.3):
/// 1. `server_settings` table (operator-filled via the admin UI / API).
/// 2. Per-source env fallback when the DB row is empty:
///    - crumb base  → `config.crumb_go2rtc_rtsp_base` then `config.go2rtc_rtsp_base` (#20)
///    - frigate base → `config.go2rtc_rtsp_base`
///
/// The crumb-specific env var (`CRUMB_GO2RTC_RTSP_BASE`) lets a fresh install
/// wire the crumb restreamer without touching the admin UI, acting as a
/// defense-in-depth fallback for finding #1 (empty server_settings on fresh
/// install). It is tried FIRST; `GO2RTC_RTSP_BASE` is the final backstop so a
/// single-host prototype that sets only the generic var still works.
///
/// Returns `(crumb_rtsp_base, frigate_rtsp_base)`.
async fn resolve_rtsp_bases(pool: &Pool, config: &Config) -> (String, String) {
    // Env-level crumb fallback: prefer the crumb-specific var, then the
    // generic go2rtc base (#20 — previously the crumb base always fell back to
    // `go2rtc_rtsp_base`, which is the Frigate-side base on most deployments,
    // so crumb cameras resolved to the wrong host on a split install).
    let env_crumb_base = if !config.crumb_go2rtc_rtsp_base.trim().is_empty() {
        config.crumb_go2rtc_rtsp_base.clone()
    } else {
        config.go2rtc_rtsp_base.clone()
    };

    match db::get_server_settings(pool).await {
        Ok(Some(s)) => {
            let crumb = if s.crumb_rtsp_base.trim().is_empty() {
                env_crumb_base
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
        Ok(None) | Err(_) => {
            // server_settings table absent or unreachable — fall back to env.
            (env_crumb_base, config.go2rtc_rtsp_base.clone())
        }
    }
}

/// Redact embedded credentials from an RTSP URL for safe logging.
///
/// Masks the `user:pass@` authority component with `***:***@` so camera
/// passwords never appear in plaintext log output. Non-RTSP URLs and URLs
/// without embedded credentials are returned unchanged. Uses a simple byte
/// scan rather than a URL parser to avoid panicking on malformed URLs.
///
/// # Examples
///
/// ```ignore
/// assert_eq!(
///     redact_rtsp_credentials("rtsp://admin:secret@10.0.0.1/stream"),
///     "rtsp://***:***@10.0.0.1/stream"
/// );
/// assert_eq!(
///     redact_rtsp_credentials("rtsp://10.0.0.1/noauth"),
///     "rtsp://10.0.0.1/noauth"
/// );
/// ```
pub(crate) fn redact_rtsp_credentials(url: &str) -> String {
    // Only URLs with a scheme authority separator can carry embedded creds.
    let scheme_end = match url.find("://") {
        Some(i) => i + 3, // byte index of the first char after "://"
        None => return url.to_owned(),
    };

    let authority_and_rest = &url[scheme_end..];

    // Locate the `@` that terminates the userinfo component.  The `@` must
    // precede the first `/` in the authority (if any) to be an authority
    // delimiter rather than a literal `@` inside a path segment.
    let at_pos = authority_and_rest
        .find('@')
        .filter(|&at| authority_and_rest.find('/').is_none_or(|slash| at < slash));

    match at_pos {
        None => url.to_owned(),
        Some(at) => {
            // authority_and_rest[..at] is "user:pass" (or just "user").
            // Reconstruct as "<scheme>://***:***@<rest>" without a second find.
            let scheme_prefix = &url[..scheme_end]; // e.g. "rtsp://"
            let after_at = &authority_and_rest[at + 1..]; // "host/path"
            format!("{scheme_prefix}***:***@{after_at}")
        }
    }
}

/// Drain all currently-available items from `motion_rx` into `out`.
///
/// This is non-blocking: it empties the channel without yielding or sleeping.
fn drain_motion_channel(rx: &mut MotionRx, out: &mut Vec<MotionSignal>) {
    while let Ok(sig) = rx.try_recv() {
        out.push(sig);
    }
}

/// Drain motion signals AND persist each newly-arrived one to the shared `events`
/// table (`source_id = 'motion'`), making motion a first-class event for the
/// notification engine (and a future motion timeline). Done here, in the consumer,
/// so the motion task stays a pure detector. Best-effort: a DB hiccup is logged and
/// never blocks recording. A single event's START then STOP upsert the same row.
///
/// When `motion_buf` is `Some` (Motion-mode cameras), each NEWLY-drained signal
/// is also fed into [`MotionBuffer::apply_signal`] exactly once — this is the
/// ONLY call site that applies signals to the buffer, so a signal can never be
/// double-applied across boundaries (the `signals` snapshot `index_segment`
/// uses for `has_motion` stamping is a separate, replay-safe read of the
/// accumulated list; the buffer's state transitions are edge-triggered on the
/// channel receive, not on the boundary loop). The resulting [`MotionDecision`]s
/// are appended into `decision`.
///
/// **Surfacing note (additive sources):** this function no longer writes any
/// `events` row. Under the additive model each source writes its OWN labeled row
/// (pixel → `'motion'`, HA → `'ha'`/device-class, Frigate → its detections), so
/// `recording.rs` — which sees only a source-blind unioned signal — cannot and
/// must not label events. See `docs/DECISIONS.md` (additive multi-source motion).
///
/// The raw drained signals still accumulate into `out` (`pending_signals`) for
/// the `has_motion`/bbox stamping, which unions across signals itself. The
/// **buffer** feed is routed through [`MotionUnion`] so a second source's STOP
/// can't end recording while another source is still open.
async fn drain_and_persist_motion(
    rx: &mut MotionRx,
    out: &mut Vec<MotionSignal>,
    motion_buf: Option<&mut MotionBuffer>,
    motion_union: &mut MotionUnion,
    decision: &mut MotionDecision,
) {
    let before = out.len();
    drain_motion_channel(rx, out);
    match motion_buf {
        Some(buf) => {
            // #74: FIRST replay the newest union edge that was produced while
            // the buffer was frozen (the fail-open unhealthy window stashes it
            // below instead of dropping it), so the buffer's Recording/Idle
            // regime resyncs to the union's before any of this call's fresh
            // edges — or the segment push that follows in
            // `finish_completed_segment` — are applied. Replaying an edge the
            // buffer effectively already agrees with is a no-op (a START on
            // Recording is a re-trigger; a STOP on Idle is stale-ignored), so
            // this can only make the buffer persist MORE, never less.
            if let Some(replay) = motion_union.take_pending_replay() {
                // apply_replayed_edge (not apply_signal): a replayed STOP onto an
                // Idle buffer means a full event ran inside the frozen window and
                // we owe its post-roll → PostBuffer, not stale-ignore (#74).
                let d = buf.apply_replayed_edge(&replay);
                decision.persist.extend(d.persist);
                decision.discard.extend(d.discard);
            }
            for sig in &out[before..] {
                // Union the per-source edges before the buffer: only a rising edge on
                // the FIRST open and a falling edge on the LAST close reach apply_signal.
                if let Some(union_sig) = motion_union.fold(sig) {
                    let d = buf.apply_signal(&union_sig);
                    decision.persist.extend(d.persist);
                    decision.discard.extend(d.discard);
                } else if sig.stopped_at.is_some()
                    && motion_union.open.is_empty()
                    && matches!(buf.state, MotionBufferState::Idle)
                {
                    // Unmatched STOP while the union AND the buffer are idle: its
                    // matching START was lost to channel overflow, so fail-open
                    // (the #81 loss debt) held health false and persisted the
                    // event body directly, the union never opened, and fold()
                    // returned None. The debt clears at exactly this accepted STOP
                    // (main.rs #5), so without this the post-roll would drop —
                    // treat it as a synthetic PostBuffer trigger (persist-more).
                    // This is the recording.rs half of the #5 coordination.
                    let d = buf.apply_replayed_edge(sig);
                    decision.persist.extend(d.persist);
                    decision.discard.extend(d.discard);
                }
            }
        }
        None => {
            // #74 (fail-open desync): the buffer is frozen (unhealthy-while-
            // caching) or absent (Continuous mode), but the UNION must still
            // see every drained edge — this drain consumes the signals from
            // the channel, so an open/close that is not folded here is lost to
            // the union forever, leaving its open-source set out of sync with
            // the detector (a later STOP arrives unmatched, or a stale open
            // key pins the union open across every subsequent event). Fold
            // each edge to keep the accounting exact, and STASH the newest
            // synthetic edge so the buffer can resync to the union's regime
            // when it thaws (see the `Some` arm above). The frozen buffer
            // itself is deliberately NOT driven — segments during the window
            // already persist directly via fail-open.
            for sig in &out[before..] {
                if let Some(union_sig) = motion_union.fold(sig) {
                    motion_union.stash_replay(union_sig);
                } else if sig.stopped_at.is_some() && motion_union.open.is_empty() {
                    // Unmatched STOP (its START was lost to channel overflow, so
                    // the union never opened) drained while the buffer is frozen.
                    // Stash it so the thaw replay turns it into a PostBuffer
                    // trigger (apply_replayed_edge keeps the post-roll) — the
                    // frozen-window twin of the healthy-arm #5 coordination
                    // above. Newest-edge-wins: a later real START supersedes it.
                    motion_union.stash_replay(sig.clone());
                }
            }
        }
    }
}

/// Hard cap on how long an *open* motion START (a signal with `stopped_at = None`)
/// may keep marking new segments before it is force-expired. A legitimate motion
/// event is bounded by `motion.rs` emitting a STOP; this only fires if that STOP
/// never arrives (e.g. the motion task wedged), so it is set generously — no real
/// single motion event runs this long, but a stuck-open START otherwise marks
/// EVERY future segment as motion forever.
const MAX_OPEN_SIGNAL_SECS: i64 = 1800; // 30 minutes

/// Prune `pending_signals` after indexing the segment ending at `boundary`.
///
/// Two rules:
/// * A **closed** signal (`stopped_at = Some`) is dropped once it can no longer
///   overlap a future segment (`stopped_at <= boundary`).
/// * An **open** START (`stopped_at = None`) is dropped when its matching STOP has
///   arrived — `motion.rs` emits the STOP as a *separate* signal with the same
///   `started_at`, so a closed signal for that `started_at` **supersedes** the open
///   START. Without this, a single motion event's open START lingers forever and
///   stamps `has_motion = true` (with a frozen `peak_score`) on every subsequent
///   segment — the "stuck motion" bug. An open START with no STOP yet is genuine
///   ongoing motion and is retained, unless it exceeds [`MAX_OPEN_SIGNAL_SECS`]
///   (a safety net for a motion task that never emits STOP).
fn prune_pending_signals(signals: &mut Vec<MotionSignal>, boundary: DateTime<Utc>) {
    let superseded: std::collections::HashSet<DateTime<Utc>> = signals
        .iter()
        .filter(|s| s.stopped_at.is_some())
        .map(|s| s.started_at)
        .collect();
    signals.retain(|s| match s.stopped_at {
        Some(stopped) => stopped > boundary,
        None => {
            !superseded.contains(&s.started_at)
                && (boundary - s.started_at) < chrono::Duration::seconds(MAX_OPEN_SIGNAL_SECS)
        }
    });
}

/// Kill the ffmpeg child process immediately.
///
/// Correctness item 6: on CancellationToken cancellation we kill the child
/// without waiting for it to emit output.  A `-c copy` stream on a quiet camera
/// can remain silent for long stretches; relying on log cadence for shutdown
/// detection causes hangs.
async fn kill_child(child: &mut tokio::process::Child) {
    if let Err(e) = child.kill().await {
        // ESRCH (No such process) is fine — the process already exited.
        debug!(error = %e, "ffmpeg kill (may already be dead)");
    }
}

/// Retrieve the file size in bytes; returns 0 on any IO error.
async fn file_size(path: &str) -> Result<i64> {
    let meta = tokio::fs::metadata(path)
        .await
        .with_context(|| format!("metadata({path})"))?;
    Ok(meta.len() as i64)
}

/// fsync a just-completed segment file AND its parent directory before the row
/// is inserted (audit GAP 1 / P1 #4 — the durability inversion).
///
/// ffmpeg `close(2)`s the file but does NOT flush it; `insert_segment` then
/// commits fsync-durably while the mp4 bytes (and possibly the directory entry)
/// sit in page cache for up to ext4's ~5s commit. A power cut in that window
/// leaves a committed row pointing at a truncated/absent file, and reconcile
/// only catches *entirely* missing files — never truncation. fsyncing the file
/// (data + size) and its parent dir (the dirent, so the file can't vanish)
/// BEFORE the insert guarantees the row is never more durable than its bytes.
///
/// Runs the blocking `sync_all` calls on `spawn_blocking` so the capture/select
/// hot path is never blocked. Errors are returned to the caller, which logs and
/// SKIPS the insert for that segment (better an un-indexed orphan reconcile can
/// re-index than a row promising bytes that aren't durable). The file is already
/// closed by ffmpeg, so opening it read-only here is safe and cheap.
async fn fsync_segment_and_dir(path: &str) -> Result<()> {
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || -> Result<()> {
        use std::fs::File;
        // fsync the file's data + metadata (length).
        let f = File::open(&path).with_context(|| format!("open for fsync: {path}"))?;
        f.sync_all()
            .with_context(|| format!("sync_all segment: {path}"))?;
        // fsync the parent directory so the directory entry itself is durable —
        // otherwise a power cut can lose the file even though its data flushed.
        if let Some(parent) = std::path::Path::new(&path).parent() {
            // Opening a directory read-only and fsyncing it is the POSIX-blessed
            // way to flush a dirent. On platforms where opening a dir as a File
            // is not permitted this errors; we surface it (Linux container target
            // supports it).
            let dir = File::open(parent)
                .with_context(|| format!("open parent dir for fsync: {}", parent.display()))?;
            dir.sync_all()
                .with_context(|| format!("sync_all parent dir: {}", parent.display()))?;
        }
        Ok(())
    })
    .await
    .context("fsync_segment_and_dir: join")?
}

/// Retrieve the file mtime as a UTC DateTime.
///
/// Used for the final segment at shutdown, where no subsequent segment
/// filename provides an end_ts (correctness item 3).
async fn file_mtime_utc(path: &str) -> Result<DateTime<Utc>> {
    let meta = tokio::fs::metadata(path)
        .await
        .with_context(|| format!("metadata({path}) for mtime"))?;
    let mtime = meta
        .modified()
        .context("file modified time not supported on this platform")?;
    let duration_since_epoch = mtime
        .duration_since(std::time::UNIX_EPOCH)
        .context("mtime before UNIX epoch")?;
    let secs = duration_since_epoch.as_secs() as i64;
    let nanos = duration_since_epoch.subsec_nanos();
    DateTime::from_timestamp(secs, nanos).context("mtime out of range for DateTime<Utc>")
}

/// Clamp a raw file-mtime-derived `end_ts` to a plausible segment duration
/// (R5).
///
/// Both in-flight recovery paths (cancel-shutdown and ffmpeg-error-exit) used
/// to trust the file's raw mtime for `end_ts` with no plausibility check. A
/// `SEGMENT_RECEIPT_TIMEOUT_SECS` (90s) watchdog stall can leave the file's
/// mtime up to ~90s after `start_ts` even though the actual video content is
/// only a few seconds long (ffmpeg wrote the last frame, then the stream
/// stalled and the process wasn't reaped for up to 90s) — indexing that raw
/// mtime claims a ~90s duration for a ~4s file (prod has 328 such rows).
///
/// Mirrors the exact clamp `reconcile`'s orphan adopter applies
/// (`try_index_orphan`): if the mtime is not after `start_ts`, or is more than
/// `2 * segment_seconds` after it, the mtime is implausible and we fall back
/// to `start_ts + segment_seconds` instead.
fn clamp_recovered_end_ts(
    start_ts: DateTime<Utc>,
    mtime: DateTime<Utc>,
    segment_seconds: u32,
) -> DateTime<Utc> {
    let segment_len = chrono::Duration::seconds(i64::from(segment_seconds));
    let max_plausible = chrono::Duration::seconds(i64::from(segment_seconds) * 2);
    if mtime <= start_ts || (mtime - start_ts) > max_plausible {
        start_ts + segment_len
    } else {
        mtime
    }
}

/// Result of [`decide_persist_for_segment`]: the REAL decision that drives
/// file operations, plus — only when shadow mode is active — the decision
/// `MotionBuffer` would have made if it were live, for validation stamping.
#[derive(Default)]
struct SegmentDecision {
    /// The decision that actually governs file operations this call.
    actual: MotionDecision,
    /// `Some` only in shadow mode: what the buffer decided, independent of
    /// `actual` (which always persists in shadow mode). `None` for Continuous
    /// mode and for the live cache path (where `actual` already IS the buffer's
    /// decision, so a separate shadow readout would be redundant).
    shadow: Option<MotionDecision>,
}

/// Determine the persist/discard decision for a just-completed segment, given
/// the recording mode, the fail-open detector-health signal, and whether the
/// motion RAM cache is actually active for this camera right now.
///
/// * **Continuous mode**: always persist; `motion_buf` is never touched (a
///   Continuous-mode camera's ring would be meaningless — there is no cache to
///   discard from).
/// * **Motion mode, cache active, detector healthy**: the REAL decision comes
///   from `motion_buf.push_segment` — this is the actual persist-on-motion
///   behaviour.
/// * **Motion mode, cache active, detector UNHEALTHY**: fail-open (spec item
///   4) — persist every segment, exactly like Continuous, AND (#77) drain any
///   segments still sitting in the ring awaiting a verdict into the persist
///   set too (same footage-safe mechanics as the cache-pressure spill):
///   "detector state unknown" must resolve to "keep everything", and that
///   includes the buffered pre-roll — before this, those ring segments sat
///   frozen through the unhealthy window and then aged out as DISCARDS once
///   health returned, without ever getting a real verdict. At worst this
///   persists ~`motion_pre_seconds` of idle footage per unhealthy episode.
///   The buffer's STATE is still never touched, so it resumes exactly where
///   it left off (with an empty ring, as after a spill) once health returns.
/// * **Motion mode, cache NOT active** (shadow mode, or a cache-dir failure):
///   file operations always persist (byte-for-byte continuous-mode behaviour
///   — there is no cache file to discard). `motion_buf.push_segment` is STILL
///   called so shadow mode can record what the buffer would have decided;
///   that verdict comes back as `.shadow`, entirely separate from `.actual`.
fn decide_persist_for_segment(
    mode: RecordingMode,
    caching_active: bool,
    detector_healthy: bool,
    motion_buf: &mut MotionBuffer,
    completed: &PendingSegment,
) -> SegmentDecision {
    match mode {
        RecordingMode::Continuous => SegmentDecision {
            actual: MotionDecision::persist_one(completed.clone()),
            shadow: None,
        },
        RecordingMode::Motion => {
            if !caching_active {
                // Shadow mode or a cache-dir failure: file ops always persist;
                // the buffer still runs (driven for real, including its ring
                // state) so its verdict can be recorded for validation.
                let shadow = motion_buf.push_segment(completed.clone());
                return SegmentDecision {
                    actual: MotionDecision::persist_one(completed.clone()),
                    shadow: Some(shadow),
                };
            }
            if !detector_healthy {
                // Fail-open (spec item 4): persist every segment, exactly like
                // Continuous. #77: ALSO drain the ring — segments buffered
                // before the healthy→unhealthy transition were awaiting a
                // keep/discard verdict the detector can no longer render, so
                // they persist too (oldest first, then `completed`), exactly
                // like a cache-pressure spill. Idempotent across the unhealthy
                // window: the first call empties the ring, later calls drain
                // nothing. The buffer's STATE is deliberately untouched.
                let mut persist = motion_buf.drain_ring();
                persist.push(completed.clone());
                return SegmentDecision {
                    actual: MotionDecision {
                        persist,
                        discard: Vec::new(),
                    },
                    shadow: None,
                };
            }
            SegmentDecision {
                actual: motion_buf.push_segment(completed.clone()),
                shadow: None,
            }
        }
    }
}

/// Insert one row into the `segments` table for a completed segment.
///
/// Computes `has_motion` by checking all accumulated signals against the
/// segment's time window.  Logs (but does not propagate) DB errors so that
/// one bad segment never kills the entire recording loop.
///
/// Returns `true` iff a row was actually inserted (used by R6 to detect the
/// first successfully-indexed segment of a run and reset the reconnect
/// backoff — a sub-floor skip or a failed fsync/insert does NOT count as a
/// healthy segment).
async fn index_segment(
    seg: &PendingSegment,
    camera: &Camera,
    storage_id: &uuid::Uuid,
    storage_root: &str,
    pool: &Pool,
    signals: &[MotionSignal],
) -> bool {
    // SUB-FLOOR REJECT on the LIVE path (R3a): a header-only skeleton (ffmpeg
    // writes a ~28-byte `ftyp`+empty `moov` before any frame lands) is not a
    // valid segment. Previously this path indexed whatever `file_size()`
    // returned, so a segment caught mid-write (e.g. right before a reconnect)
    // was inserted as a real row. Skip the insert and leave the file as an
    // orphan on disk — reconcile's orphan pass applies the SAME floor
    // (`reconcile::SUB_FLOOR_BYTES`) and will quarantine it instead of
    // adopting it, so nothing is lost by not indexing here.
    if (seg.size_bytes as u64) < crate::reconcile::SUB_FLOOR_BYTES {
        debug!(
            camera_id  = %camera.id,
            path       = %seg.path,
            size_bytes = seg.size_bytes,
            "segment below sub-floor byte count; skipping index (left for reconcile)"
        );
        return false;
    }

    // Compute has_motion: true if ANY overlapping signal exists.
    let has_motion = signals
        .iter()
        .any(|s| overlaps_motion(seg.start_ts, seg.end_ts, s));

    // Motion magnitude for the timeline intensity histogram: the peak changed-
    // pixel fraction (0..1) of any signal overlapping this segment (0 if none).
    // The motion bbox is taken from that SAME top-scoring overlapping signal so
    // the stored region matches the segment's peak-motion frame (used by the clip
    // player's motion-highlight auto-zoom).
    let (motion_score, motion_bbox) = signals
        .iter()
        .filter(|s| overlaps_motion(seg.start_ts, seg.end_ts, s))
        .fold((0.0_f32, None), |(best, bbox), s| {
            if s.peak_score >= best {
                (s.peak_score, s.bbox.or(bbox))
            } else {
                (best, bbox)
            }
        });

    // Compute the relative path within the storage root for the index row.
    // The path column stores a path relative to the storage root so the index
    // is independent of mount points.
    let relative_path = compute_relative_path(&seg.path, storage_root);

    let duration_ms = (seg.end_ts - seg.start_ts).num_milliseconds();
    // Clamp to i32 range; a 2-6 s segment will always be well within range.
    let duration_ms_i32 = duration_ms.clamp(0, i64::from(i32::MAX)) as i32;

    // Determine the segment stream type from the camera policy.
    let stream = match camera.policy.record_stream {
        crumb_common::types::RecordStream::Main => SegmentStream::Main,
        crumb_common::types::RecordStream::Sub => SegmentStream::Sub,
    };

    // Durability (audit GAP 1 / P1 #4): make the BYTES durable before the ROW.
    // fsync the just-completed file + its parent dir off the hot path; on
    // failure, log and SKIP the insert so we never commit a row more durable
    // than the file it points at (an un-indexed file is reclaimable by reconcile;
    // a row pointing at lost bytes is not).
    if let Err(e) = fsync_segment_and_dir(&seg.path).await {
        error!(
            camera_id = %camera.id,
            path      = %seg.path,
            error     = %e,
            "failed to fsync segment before indexing; skipping insert (will be reconciled)"
        );
        return false;
    }

    let params = InsertSegmentParams {
        camera_id: camera.id,
        storage_id: *storage_id,
        stage: SegmentStage::Live,
        path: relative_path,
        stream,
        start_ts: seg.start_ts,
        end_ts: seg.end_ts,
        duration_ms: duration_ms_i32,
        has_motion,
        motion_score,
        size_bytes: seg.size_bytes,
        motion_bbox,
    };

    match db::insert_segment(pool, &params).await {
        Ok(id) => {
            debug!(
                camera_id  = %camera.id,
                segment_id = %id,
                start_ts   = %seg.start_ts,
                end_ts     = %seg.end_ts,
                has_motion = has_motion,
                "segment indexed"
            );
            true
        }
        Err(e) => {
            error!(
                camera_id = %camera.id,
                path      = %seg.path,
                error     = %e,
                "failed to index segment; continuing"
            );
            false
        }
    }
}

// ─── motion cache dir resolution + guard ──────────────────────────────────────

/// Resolve `MOTION_CACHE_DIR/{camera_id}` for this camera, refusing (with an
/// error) if it resolves to a path under ANY configured storage root.
///
/// Reconcile's orphan/dangling scan walks every row in `storages` — if the
/// cache dir were nested under a storage root, reconcile would see half-written
/// or about-to-be-discarded cache files and either quarantine them (harmless
/// but noisy) or, worse, adopt one moments before this task deletes it as a
/// discard (a benign race, but one that is trivially avoided by keeping the
/// cache dir OUTSIDE every storage root entirely). The guard reads
/// `storages` fresh (not just the two env-seeded paths) so an operator-added
/// extra storage row is covered too.
///
/// # Errors
///
/// Returns an error if `storages` cannot be listed, or if the cache dir is
/// nested under (or equal to) any storage root's path.
async fn resolve_motion_cache_dir(
    pool: &Pool,
    config: &Config,
    camera_id: uuid::Uuid,
) -> Result<PathBuf> {
    let cache_root = PathBuf::from(&config.motion_cache_dir);

    let storages = db::list_storages(pool)
        .await
        .context("list_storages (motion cache dir guard)")?;
    let storage_roots: Vec<(String, PathBuf)> = storages
        .iter()
        .map(|s| (s.name.clone(), PathBuf::from(&s.path)))
        .collect();
    if let Some((name, root)) = cache_dir_conflicts_with_storage(&cache_root, &storage_roots) {
        anyhow::bail!(
            "MOTION_CACHE_DIR ({}) resolves under storage '{}' ({}); refusing — the cache dir \
             must never be visible to reconcile's storage-root scan",
            cache_root.display(),
            name,
            root.display(),
        );
    }

    Ok(cache_root.join(camera_id.to_string()))
}

/// Pure check for the #73 flip-guard: does this carried ring entry's file live
/// DIRECTLY under `dir` (this run's effective write dir)? The cache and
/// storage layouts are both flat under the per-camera dir, so a simple parent
/// comparison is exact — an entry whose parent is not `dir` was produced by a
/// run in the OTHER caching mode and must be settled before the ring is used
/// (see the flip-guard in `run_ffmpeg_loop`).
fn ring_entry_lives_under(seg: &PendingSegment, dir: &Path) -> bool {
    Path::new(&seg.path).parent() == Some(dir)
}

/// Pure guard check: does `cache_root` equal or nest under any storage root in
/// `storage_roots`? Returns the first conflicting `(name, path)` found, or
/// `None` if the cache dir is safely outside every storage root. Extracted
/// from [`resolve_motion_cache_dir`] so the path-comparison logic is
/// unit-testable without a database.
fn cache_dir_conflicts_with_storage(
    cache_root: &Path,
    storage_roots: &[(String, PathBuf)],
) -> Option<(String, PathBuf)> {
    storage_roots
        .iter()
        .find(|(_, root)| cache_root == root || cache_root.starts_with(root))
        .cloned()
}

/// Delete every regular file directly inside `dir` (non-recursive — the cache
/// layout is flat, matching the storage layout), EXCEPT paths listed in
/// `keep`. Used at ffmpeg-(re)start to clear stale files from a previous
/// in-process restart (R1). `keep` carries the reconnect-surviving motion
/// ring's file paths (#73): those cache files are still awaiting a
/// keep/discard verdict from the carried `MotionBuffer`, so deleting them here
/// would silently lose the buffered pre-roll (every later persist of a ring
/// segment would fail). A fresh worker spawn passes an empty `keep`, making
/// this exactly the original R1 sweep. Best-effort per file: one failed delete
/// is logged and does not stop the sweep.
///
/// # Errors
///
/// Returns an error only if the directory itself cannot be read (e.g. it does
/// not exist yet, which the caller has already created, or a permissions
/// problem) — individual file-delete failures are swallowed with a warning.
async fn clear_dir_contents(dir: &Path, keep: &std::collections::HashSet<PathBuf>) -> Result<()> {
    let mut entries = tokio::fs::read_dir(dir)
        .await
        .with_context(|| format!("read_dir {:?}", dir))?;
    while let Some(entry) = entries
        .next_entry()
        .await
        .with_context(|| format!("read_dir next_entry {:?}", dir))?
    {
        let path = entry.path();
        if keep.contains(&path) {
            continue;
        }
        if let Ok(meta) = entry.metadata().await {
            if meta.is_file() {
                if let Err(e) = tokio::fs::remove_file(&path).await {
                    warn!(path = ?path, error = %e, "failed to remove leftover motion-cache file");
                }
            }
        }
    }
    Ok(())
}

// ─── persist / discard execution (RAM pre-buffer + persist-on-motion) ────────

/// Copy a cached segment into storage, fsync it (+ parent dir), then index it —
/// mirrors the correctness ordering `index_segment` already uses for a
/// direct-to-storage write, with one extra step at the front (the cross-device
/// copy, since the cache dir is expected to be tmpfs).
///
/// Ordering (crash-safe): copy cache→storage, fsync the copied file AND its
/// parent dir (belt-and-suspenders — `index_segment` also fsyncs before
/// insert; a redundant fsync on an already-durable file is cheap), THEN
/// `index_segment` (which inserts the DB row), THEN delete the cache file.
///
/// A crash between the copy and the index leaves an orphan file in storage
/// with no row — this is IDENTICAL to the existing direct-to-storage orphan
/// window (correctness item 9 / reconcile's orphan-adopt pass), and reconcile
/// adopts it exactly the same way: it is real motion footage that was
/// successfully persisted, just not yet indexed.
///
/// A crash between the index and the cache-file delete leaves a stale file
/// sitting harmlessly in the cache (never re-persisted — the cache is never
/// scanned by reconcile, and a tmpfs cache clears on reboot anyway; the R1
/// leftover-file sweep at worker start also cleans it on the next restart).
///
/// Returns `true` iff the segment was successfully indexed (used for R6's
/// `indexed_ok`), regardless of whether the cache-file delete afterward
/// succeeded (a delete failure is warn-and-continue — never treated as
/// indexing failure).
#[allow(clippy::too_many_arguments)]
async fn persist_cached_segment(
    seg: &PendingSegment,
    camera: &Camera,
    storage_id: &uuid::Uuid,
    storage_root: &str,
    camera_dir: &Path,
    pool: &Pool,
    signals: &[MotionSignal],
) -> bool {
    let cache_path = Path::new(&seg.path);
    let filename = match cache_path.file_name() {
        Some(f) => f,
        None => {
            error!(camera_id = %camera.id, path = %seg.path, "persist_cached_segment: no filename component; skipping");
            return false;
        }
    };
    let storage_path = camera_dir.join(filename);
    let storage_path_str = storage_path.to_string_lossy().into_owned();

    // Cross-device copy (the cache dir is expected to be tmpfs, a different
    // filesystem from the storage root, so a rename(2) would fail with EXDEV —
    // `tokio::fs::copy` handles this correctly via read+write).
    if let Err(e) = tokio::fs::copy(&seg.path, &storage_path).await {
        error!(
            camera_id = %camera.id,
            src = %seg.path,
            dst = %storage_path_str,
            error = %e,
            "failed to copy cached segment into storage; leaving in cache (footage may be lost \
             if the cache is tmpfs and the process restarts)"
        );
        // R2 (audit 2026-07-05): a copy failure here is footage-THREATENING —
        // storage full (ENOSPC) or read-only (EROFS) while the motion RAM buffer
        // must spill. It was previously logged only ("silent"); surface it as an
        // urgent `storage_persist_failed` system alert (migration 0043). Throttled
        // to once/minute per process because one spill fails many buffered
        // segments at once (the alert-rule cooldown throttles the operator-facing
        // notification further).
        {
            use std::sync::atomic::{AtomicI64, Ordering};
            static LAST_ALERT_TS: AtomicI64 = AtomicI64::new(0);
            let now = chrono::Utc::now().timestamp();
            let last = LAST_ALERT_TS.load(Ordering::Relaxed);
            if now - last >= 60
                && LAST_ALERT_TS
                    .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
                    .is_ok()
            {
                let reason = format!("copy cache->storage failed: {e}");
                if let Err(ev) = crumb_common::db::insert_system_event(
                    pool,
                    "storage_persist_failed",
                    Some(camera.id),
                    Some(&reason),
                )
                .await
                {
                    warn!(
                        camera_id = %camera.id,
                        error = %ev,
                        "failed to record storage_persist_failed system event"
                    );
                }
            }
        }
        return false;
    }

    // Belt-and-suspenders fsync here (index_segment fsyncs again before its own
    // insert) — cheap on an already-synced small file, and keeps this function
    // correct in isolation if ever called from a path that doesn't re-fsync.
    if let Err(e) = fsync_segment_and_dir(&storage_path_str).await {
        warn!(
            camera_id = %camera.id,
            path = %storage_path_str,
            error = %e,
            "fsync after cache->storage copy failed (index_segment will fsync again and \
             skip the insert if it still fails)"
        );
    }

    let storage_seg = PendingSegment {
        path: storage_path_str.clone(),
        start_ts: seg.start_ts,
        end_ts: seg.end_ts,
        size_bytes: seg.size_bytes,
    };

    let indexed = index_segment(
        &storage_seg,
        camera,
        storage_id,
        storage_root,
        pool,
        signals,
    )
    .await;

    // Delete the cache file regardless of index outcome — a failed index
    // leaves an un-indexed file in STORAGE (reconcile's job), not in the
    // cache; the cache copy has served its purpose either way.
    if let Err(e) = tokio::fs::remove_file(&seg.path).await {
        warn!(
            camera_id = %camera.id,
            path = %seg.path,
            error = %e,
            "failed to delete cache file after persisting (non-fatal; tmpfs clears on restart)"
        );
    }

    indexed
}

/// Delete a discarded segment from the motion cache without ever touching
/// storage. Best-effort: a failed delete is logged and swallowed (a stale
/// cache file on a real filesystem would linger until the next worker
/// restart's R1 sweep; on tmpfs it clears on reboot regardless).
async fn discard_cached_segment(seg: &PendingSegment, camera_id: uuid::Uuid) {
    if let Err(e) = tokio::fs::remove_file(&seg.path).await {
        // NotFound is expected/harmless if something else already removed it
        // (e.g. a race with the R1 startup sweep) — still just a debug/warn,
        // never escalated, since a discard's whole point is "this file no
        // longer needs to exist".
        warn!(
            camera_id = %camera_id,
            path = %seg.path,
            error = %e,
            "failed to delete discarded motion-cache segment (non-fatal)"
        );
    }
}

/// Execute a [`MotionDecision`].
///
/// When `caching_active` is `true`, `.persist` segments are still physically
/// IN THE CACHE (`persist_cached_segment`: copy → fsync → index → delete
/// cache) and `.discard` segments are deleted from the cache without ever
/// touching storage.
///
/// When `caching_active` is `false` (Continuous mode, shadow mode, or a
/// cache-dir fallback), EVERY segment reaching this function is ALREADY in
/// storage (ffmpeg wrote it there directly — see `effective_write_dir` in
/// `run_ffmpeg_loop`), so `.persist` segments are indexed IN PLACE with no
/// copy and no delete. **This branch must never call `persist_cached_segment`
/// on a non-cached path** — that function's copy-then-delete-source sequence
/// would copy the storage file onto itself and then DELETE THE ONLY COPY of
/// freshly-recorded footage. `.discard` is always empty when `!caching_active`
/// (nothing in this mode is ever discarded — see `decide_persist_for_segment`),
/// so the discard loop is a documented no-op guard, not dead code.
///
/// Returns `true` iff ANY persisted segment was successfully indexed (for R6's
/// `indexed_ok`).
///
/// `signals` is the accumulated snapshot used for `has_motion`/`motion_score`
/// stamping — identical semantics to the pre-feature direct call to
/// `index_segment`.
#[allow(clippy::too_many_arguments)]
async fn execute_motion_decision(
    decision: &MotionDecision,
    camera: &Camera,
    storage_id: &uuid::Uuid,
    storage_root: &str,
    camera_dir: &Path,
    pool: &Pool,
    signals: &[MotionSignal],
    caching_active: bool,
) -> bool {
    let mut any_indexed = false;
    if caching_active {
        for seg in &decision.persist {
            if persist_cached_segment(
                seg,
                camera,
                storage_id,
                storage_root,
                camera_dir,
                pool,
                signals,
            )
            .await
            {
                any_indexed = true;
            }
        }
        for seg in &decision.discard {
            discard_cached_segment(seg, camera.id).await;
        }
    } else {
        // Direct-to-storage: `seg.path` IS the storage path already (no cache
        // involved). Index in place — byte-for-byte the pre-feature behaviour.
        debug_assert!(
            decision.discard.is_empty(),
            "a non-caching decision must never contain discards (nothing to discard without a cache)"
        );
        for seg in &decision.persist {
            if index_segment(seg, camera, storage_id, storage_root, pool, signals).await {
                any_indexed = true;
            }
        }
    }
    any_indexed
}

// ─── shadow mode (MOTION_RECORDING_SHADOW=1) ──────────────────────────────────

/// Stamp the shadow-mode verdict for every segment in `decision` (both
/// `.persist` and `.discard`) onto `segments.motion_shadow_keep` (migration
/// 0037), matching by `(camera_id, path)`.
///
/// Called ONLY when shadow mode is on. In shadow mode every segment is ALSO
/// indexed directly (the normal continuous-style path — see
/// `decide_persist_for_segment`'s `!caching_active` branch), so by the time
/// this runs the row already exists — but `segments.path` is stored RELATIVE
/// to the storage root (`compute_relative_path`, exactly like `index_segment`
/// computes it), while `seg.path` here is still the absolute on-disk path
/// (shadow mode never uses the cache dir, so this is the storage root itself).
/// `storage_root` converts before matching so the UPDATE actually finds the row.
/// Best-effort: a failed UPDATE is logged and does not affect recording.
async fn record_shadow_verdicts(
    decision: &MotionDecision,
    pool: &Pool,
    camera_id: uuid::Uuid,
    storage_root: &str,
) {
    for seg in &decision.persist {
        let rel = compute_relative_path(&seg.path, storage_root);
        if let Err(e) = db::set_segment_motion_shadow_keep(pool, camera_id, &rel, true).await {
            warn!(camera_id = %camera_id, path = %rel, error = %e, "failed to stamp shadow verdict (persist)");
        }
    }
    for seg in &decision.discard {
        let rel = compute_relative_path(&seg.path, storage_root);
        if let Err(e) = db::set_segment_motion_shadow_keep(pool, camera_id, &rel, false).await {
            warn!(camera_id = %camera_id, path = %rel, error = %e, "failed to stamp shadow verdict (discard)");
        }
    }
}

// ─── cache-pressure spill ──────────────────────────────────────────────────────

/// Pure decision: given free bytes, the filesystem's total size, and a recent
/// segment's size, should the caller SPILL (persist the oldest ring segments
/// instead of waiting for the normal trigger) to relieve cache pressure?
///
/// Spec: spill when free space is below `max(2 × recent_segment_size, 20% of
/// the filesystem)`. Extracted as a pure function (no syscalls) so the
/// boundary is unit-testable without a real tmpfs.
fn should_spill_cache(free_bytes: i64, total_bytes: i64, recent_segment_bytes: i64) -> bool {
    if total_bytes <= 0 {
        // Can't reason about a zero/negative-sized filesystem reading — don't
        // spill on bad data (mirrors `fs_free_and_total`'s "skip this tick"
        // philosophy elsewhere in the recorder).
        return false;
    }
    let twice_segment = recent_segment_bytes.saturating_mul(2);
    #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
    let twenty_pct = (total_bytes as f64 * 0.20) as i64;
    let floor = twice_segment.max(twenty_pct);
    free_bytes < floor
}

/// Free + total bytes on the filesystem containing `path`, via `statvfs(2)`.
/// Mirrors `archive::fs_free_and_total` (kept as a separate copy here since
/// that helper is private to `archive.rs`); returns `None` on any failure
/// (path missing, syscall error, non-Unix) so the caller skips the spill check
/// for this tick rather than acting on a bad reading.
fn motion_cache_free_and_total(path: &Path) -> Option<(i64, i64)> {
    #[cfg(unix)]
    {
        use std::ffi::CString;
        let c_path = CString::new(path.to_string_lossy().as_bytes()).ok()?;
        // SAFETY: `buf` is value-initialised to zero before the call; `c_path`
        // is a valid NUL-terminated C string for the lifetime of the call.
        let mut buf = unsafe { std::mem::zeroed::<libc::statvfs>() };
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &raw mut buf) };
        if rc != 0 {
            return None;
        }
        #[allow(clippy::cast_lossless)]
        let free = (buf.f_bfree as u64).saturating_mul(buf.f_bsize as u64);
        #[allow(clippy::cast_lossless)]
        let total = (buf.f_blocks as u64).saturating_mul(buf.f_bsize as u64);
        Some((i64::try_from(free).ok()?, i64::try_from(total).ok()?))
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// At each segment push, check whether the motion cache filesystem is under
/// pressure and — if so — force-persist the OLDEST pending ring segments
/// (normal persist path, not a discard) instead of letting them age out or
/// wait for a real motion trigger. Footage must never be silently dropped
/// because the cache filled (spec item 5).
///
/// Returns the forced persists (empty if not under pressure, or if free space
/// could not be read this tick). Drains from the FRONT of the ring (oldest
/// first) so the freed bytes correspond to the segments most likely to be
/// evicted as discards soon anyway.
///
/// `recent_segment_bytes` should be the just-completed segment's size — a
/// reasonable proxy for "how big is one more segment going to be" without
/// tracking a rolling average.
fn spill_oldest_if_under_pressure(
    cache_dir: &Path,
    motion_buf: &mut MotionBuffer,
    recent_segment_bytes: i64,
) -> Vec<PendingSegment> {
    let Some((free, total)) = motion_cache_free_and_total(cache_dir) else {
        return Vec::new(); // can't read free space this tick — skip, don't spill blind.
    };
    if !should_spill_cache(free, total, recent_segment_bytes) {
        return Vec::new();
    }
    // Only meaningful in Idle (the ring buffer holds anything at all); in
    // Recording/PostBuffer every segment is already being persisted as it
    // arrives, so there is nothing sitting in the ring to spill.
    if !matches!(motion_buf.state, MotionBufferState::Idle) {
        return Vec::new();
    }
    if motion_buf.pending.is_empty() {
        return Vec::new();
    }
    warn!(
        cache_dir = ?cache_dir,
        free_bytes = free,
        total_bytes = total,
        ring_len = motion_buf.pending.len(),
        "motion cache under pressure; spilling oldest ring segments to storage instead of discarding"
    );
    // Drain the whole ring: this is a rare, already-warn-logged event, and the
    // ring is bounded (pre_seconds + slack of segments) so draining all of it
    // is a small, fixed amount of I/O — simpler and more effective at
    // relieving pressure than draining just one segment per tick.
    motion_buf.pending.drain(..).collect()
}

/// Compute the path of `full_path` relative to `storage_root`.
///
/// If `full_path` does not start with `storage_root`, returns `full_path`
/// unchanged (this should not happen in normal operation but is safe).
fn compute_relative_path(full_path: &str, storage_root: &str) -> String {
    let full = Path::new(full_path);
    let root = Path::new(storage_root);
    full.strip_prefix(root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| full_path.to_owned())
}

// ─── public helpers ───────────────────────────────────────────────────────────

/// Derive `start_ts` from a strftime-encoded segment filename.
///
/// Expected format: `%Y%m%dT%H%M%SZ.mp4`, e.g. `20260101T030000Z.mp4`.
/// The stem (without extension) is parsed as a UTC [`chrono::DateTime`].
///
/// # Errors
///
/// Returns an error if the filename stem does not match the expected format.
///
/// # Examples
///
/// ```ignore
/// // Doctests for binary crates must use `ignore` — call the function
/// // directly in unit tests instead.
/// let ts = parse_segment_timestamp("20260101T030000Z.mp4").unwrap();
/// assert_eq!(ts.to_rfc3339(), "2026-01-01T03:00:00+00:00");
/// ```
pub fn parse_segment_timestamp(filename: &str) -> Result<DateTime<Utc>> {
    // Strip the directory component if present (caller may pass a full path).
    let base = Path::new(filename)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(filename);

    // Strip the `.mp4` extension to get the stem.
    let stem = base
        .strip_suffix(".mp4")
        .ok_or_else(|| anyhow::anyhow!("segment filename '{base}' does not end in .mp4"))?;

    // Parse as `%Y%m%dT%H%M%SZ` in UTC.
    //
    // Using chrono::NaiveDateTime::parse_from_str because the format is
    // wallclock-only (UTC implied by the 'Z' suffix we strip).
    let naive =
        chrono::NaiveDateTime::parse_from_str(stem, "%Y%m%dT%H%M%SZ").with_context(|| {
            format!("segment filename stem '{stem}' does not match format '%Y%m%dT%H%M%SZ'")
        })?;

    Ok(naive.and_utc())
}

/// Determine whether a segment's time window overlaps with a [`MotionSignal`].
///
/// Returns `true` when:
/// - The motion event's `started_at` falls within `[seg_start, seg_end)`, **or**
/// - The motion event was completed (`stopped_at` is `Some`) and its window
///   `[started_at, stopped_at)` overlaps `[seg_start, seg_end)`, **or**
/// - The motion event is still in progress (`stopped_at` is `None`) and its
///   `started_at` is before `seg_end`.
pub fn overlaps_motion(
    seg_start: DateTime<Utc>,
    seg_end: DateTime<Utc>,
    signal: &MotionSignal,
) -> bool {
    let motion_start = signal.started_at;

    match signal.stopped_at {
        None => {
            // Motion is still in progress.  It overlaps if it started before
            // the segment ended.
            motion_start < seg_end
        }
        Some(motion_stop) => {
            // Motion event spans [motion_start, motion_stop).
            // Segment spans [seg_start, seg_end).
            // They overlap iff one starts before the other ends.
            motion_start < seg_end && motion_stop > seg_start
        }
    }
}

// ─── MotionBuffer ─────────────────────────────────────────────────────────────

/// State machine for motion-mode ring buffer.
///
/// Tracks un-indexed segments (the rolling pre-buffer) and decides when to
/// start/stop indexing based on incoming [`MotionSignal`]s.
///
/// # Transitions
///
/// ```text
/// Idle ──── apply_signal(started_at=T, stopped_at=None)
///               → Recording { motion_started=T }
///               → flush pre-buffer segments whose end_ts > T - pre_seconds
///
/// Recording ── apply_signal(stopped_at=Some(T))
///               → PostBuffer { motion_stopped=T }
///
/// PostBuffer ── push_segment with start_ts > motion_stopped + post_seconds
///               → Idle
///               (the segment is buffered, not indexed)
///
/// Any state ── apply_signal(started_at) while in PostBuffer or Recording
///               → stays in Recording (extends the window)
/// ```
///
/// # Persist vs discard (RAM pre-buffer + persist-on-motion)
///
/// [`push_segment`](Self::push_segment) and [`apply_signal`](Self::apply_signal)
/// return a [`MotionDecision`] — the segments to PERSIST (copy cache → storage,
/// fsync, index) and the segments to DISCARD (delete from the cache, never
/// touch storage). A segment ages out of the Idle ring buffer (older than
/// `pre_seconds + RING_SLACK_SECS`) or is superseded (the Idle→Recording
/// transition evicts everything older than the pre-cutoff) as a discard;
/// everything actually flushed/indexed is a persist.
pub struct MotionBuffer {
    /// Number of seconds of footage to retain before a motion event.
    pre_seconds: i64,
    /// Number of seconds of footage to continue recording after motion stops.
    post_seconds: i64,
    /// Circular buffer of segments waiting for a motion trigger.
    pending: VecDeque<PendingSegment>,
    /// Current state.
    state: MotionBufferState,
}

/// Extra slack (seconds) the Idle ring buffer retains BEYOND `pre_seconds`,
/// added to absorb detection latency: the motion task's own dwell
/// (`MOTION_START_SECS`/`MOTION_START_FRAMES` in `motion.rs`) plus the segment
/// boundary the signal arrives on can each cost up to roughly one segment of
/// delay between "motion actually started" and the `MotionSignal` reaching
/// this buffer. Segments are 2–6 s (default 4 s), so 8 s ≈ two full segments of
/// slack — generous enough that a legitimate pre-roll flush is never short a
/// segment at its start, at the cost of a couple of extra small buffers held
/// in the cache momentarily longer before eviction.
const RING_SLACK_SECS: i64 = 8;

/// A segment that has been written to disk (or the motion cache) but not yet
/// indexed.
#[derive(Debug, Clone)]
pub struct PendingSegment {
    pub path: String,
    pub start_ts: DateTime<Utc>,
    pub end_ts: DateTime<Utc>,
    pub size_bytes: i64,
}

/// The result of feeding one segment or signal into [`MotionBuffer`]: which
/// segments to PERSIST (copy cache → storage, fsync, index) and which to
/// DISCARD (delete from the cache — never touch storage).
#[derive(Debug, Default)]
pub struct MotionDecision {
    /// Segments that should be copied into storage and indexed.
    pub persist: Vec<PendingSegment>,
    /// Segments that should be deleted from the cache without ever being
    /// written to storage.
    pub discard: Vec<PendingSegment>,
}

impl MotionDecision {
    fn persist_one(seg: PendingSegment) -> Self {
        Self {
            persist: vec![seg],
            discard: Vec::new(),
        }
    }

    fn empty() -> Self {
        Self::default()
    }
}

/// Tracks where the motion buffer state machine is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MotionBufferState {
    /// No motion; buffering segments in the ring buffer.
    Idle,
    /// Motion in progress; indexing all segments.
    Recording {
        /// Wall-clock when the current motion event started.
        motion_started: DateTime<Utc>,
    },
    /// Motion stopped; continuing to index for `post_seconds` more.
    PostBuffer {
        /// Wall-clock when motion stopped (post-buffer countdown start).
        motion_stopped: DateTime<Utc>,
    },
}

impl MotionBuffer {
    /// Create a new motion buffer.
    ///
    /// # Arguments
    ///
    /// * `pre_seconds`  — `recording_policies.motion_pre_seconds`.
    /// * `post_seconds` — `recording_policies.motion_post_seconds`.
    pub fn new(pre_seconds: i64, post_seconds: i64) -> Self {
        Self {
            pre_seconds,
            post_seconds,
            pending: VecDeque::new(),
            state: MotionBufferState::Idle,
        }
    }

    /// Push a newly-written segment into the buffer.
    ///
    /// Returns a [`MotionDecision`]:
    /// - In `Idle` state: the segment is held in the ring buffer (nothing
    ///   persisted this call); any segments aged out of the ring by this push
    ///   are returned as discards.
    /// - In `Recording` state: the segment is persisted immediately.
    /// - In `PostBuffer` state: if the segment is within the post-buffer window,
    ///   it is persisted.  Once the post-buffer window expires the state
    ///   transitions back to `Idle` and the segment starts a fresh ring buffer
    ///   (not persisted, not discarded — it is now the ring's newest entry).
    pub fn push_segment(&mut self, seg: PendingSegment) -> MotionDecision {
        let now = seg.start_ts;

        match self.state.clone() {
            MotionBufferState::Idle => {
                // Evict pre-buffer segments older than the rolling window —
                // these are genuine discards (never persisted, never will be).
                let discard = self.evict_old(now);
                // Buffer the segment.
                self.pending.push_back(seg);
                MotionDecision {
                    persist: Vec::new(),
                    discard,
                }
            }

            MotionBufferState::Recording { .. } => {
                // We are actively recording — persist immediately.
                MotionDecision::persist_one(seg)
            }

            MotionBufferState::PostBuffer { motion_stopped } => {
                let post_deadline = motion_stopped + chrono::Duration::seconds(self.post_seconds);

                if seg.start_ts <= post_deadline {
                    // Still within the post-buffer window — persist.
                    MotionDecision::persist_one(seg)
                } else {
                    // Post-buffer expired.  Transition back to Idle and start
                    // buffering this segment (not persisted this call).
                    self.state = MotionBufferState::Idle;
                    let discard = self.evict_old(now);
                    self.pending.push_back(seg);
                    MotionDecision {
                        persist: Vec::new(),
                        discard,
                    }
                }
            }
        }
    }

    /// Apply a [`MotionSignal`] from the motion task.
    ///
    /// Returns a [`MotionDecision`]: segments from the pre-buffer that should
    /// now be flushed and PERSISTED (the pre-buffer segments that overlap the
    /// pre-window before `started_at`) and segments older than that window,
    /// which are DISCARDED (deleted from the cache, never written to storage).
    ///
    /// # Semantics
    ///
    /// * A signal with `stopped_at = None` means motion just started.
    ///   Transition to `Recording` and flush pre-buffer segments.
    /// * A signal with `stopped_at = Some(t)` means motion finished.
    ///   If in `Recording`, transition to `PostBuffer`.
    ///   If already `Idle`, ignore (stale signal).
    pub fn apply_signal(&mut self, signal: &MotionSignal) -> MotionDecision {
        match signal.stopped_at {
            None => {
                // Motion started.
                let motion_started = signal.started_at;

                // If already recording, this is a re-trigger; stay in Recording
                // and extend without flushing again (the ring is already empty
                // in this state — nothing to flush or discard).
                if let MotionBufferState::Recording { .. } = &self.state {
                    return MotionDecision::empty();
                }

                // Also if in PostBuffer a new motion starts — transition back
                // to Recording.
                self.state = MotionBufferState::Recording { motion_started };

                // Flush pre-buffer: segments whose time window overlaps
                // [motion_started - pre_seconds, motion_started].
                let pre_cutoff = motion_started - chrono::Duration::seconds(self.pre_seconds);

                let mut persist: Vec<PendingSegment> = Vec::new();
                let mut discard: Vec<PendingSegment> = Vec::new();
                // Drain all pending segments that start at or after the pre-cutoff.
                // Segments older than the cutoff are discarded (they're too old to
                // be relevant to this motion event).
                while let Some(front) = self.pending.front() {
                    // Flush any segment whose window OVERLAPS the pre-buffer
                    // window [pre_cutoff, motion_started] — i.e. it ENDS after
                    // pre_cutoff. Keying on start_ts would discard a segment that
                    // straddles the cutoff and clip the start of the event, which
                    // the spec forbids ("never clip the pre-buffer").
                    if front.end_ts > pre_cutoff {
                        if let Some(s) = self.pending.pop_front() {
                            persist.push(s);
                        }
                    } else {
                        // Entirely older than the pre-window — discard.
                        if let Some(s) = self.pending.pop_front() {
                            discard.push(s);
                        }
                    }
                }

                MotionDecision { persist, discard }
            }

            Some(stopped_at) => {
                // Motion stopped.
                match &self.state {
                    MotionBufferState::Recording { .. } | MotionBufferState::PostBuffer { .. } => {
                        // Transition to PostBuffer with the new stopped_at.
                        // If stopped_at is newer than what we already have in
                        // PostBuffer, use it (re-use the most recent stop time).
                        self.state = MotionBufferState::PostBuffer {
                            motion_stopped: stopped_at,
                        };
                        MotionDecision::empty()
                    }
                    MotionBufferState::Idle => {
                        // Stale stopped signal while idle — ignore.
                        MotionDecision::empty()
                    }
                }
            }
        }
    }

    /// Apply a union edge REPLAYED after a fail-open freeze thaws (#74). Differs
    /// from [`apply_signal`](Self::apply_signal) in exactly one cell: a STOP
    /// replayed while the buffer is Idle. A *fresh* STOP while Idle is a spurious
    /// stop with no matching START and is correctly ignored — but a *replayed*
    /// STOP while Idle means a full motion event opened AND closed inside the
    /// unhealthy window (fail-open already persisted its body directly) and we
    /// are now in its post-roll, so the buffer must enter `PostBuffer` to keep
    /// segments within `motion_post_seconds` after the stop (MOTION-RECORDING.md
    /// §4's post-roll keep verdict; invariant #19). The ring is empty at thaw
    /// (#77 drains it on the transition), so this can only persist MORE, never
    /// discard. Every other case (a START replay, or a STOP replay while already
    /// Recording/PostBuffer) is identical to `apply_signal`.
    pub fn apply_replayed_edge(&mut self, signal: &MotionSignal) -> MotionDecision {
        if let Some(stopped_at) = signal.stopped_at {
            if matches!(self.state, MotionBufferState::Idle) {
                self.state = MotionBufferState::PostBuffer {
                    motion_stopped: stopped_at,
                };
                return MotionDecision::empty();
            }
        }
        self.apply_signal(signal)
    }

    /// Evict pre-buffer segments older than `pre_seconds + RING_SLACK_SECS` to
    /// bound memory, returning the evicted segments as discards (RAM
    /// pre-buffer mode: an aged-out cache segment is deleted, never written to
    /// storage).
    fn evict_old(&mut self, now: DateTime<Utc>) -> Vec<PendingSegment> {
        let cutoff = now - chrono::Duration::seconds(self.pre_seconds + RING_SLACK_SECS);
        // VecDeque has no `extract_if` in stable; drain from the front while the
        // oldest entry is past the cutoff (the deque is push_back-only, so it is
        // always ordered oldest-first).
        let mut evicted = Vec::new();
        while let Some(front) = self.pending.front() {
            if front.start_ts < cutoff {
                if let Some(s) = self.pending.pop_front() {
                    evicted.push(s);
                }
            } else {
                break;
            }
        }
        evicted
    }

    /// Read-only snapshot of the ring buffer's current occupancy: `(segment
    /// count, summed size_bytes)`. Used only by the motion-cache telemetry
    /// reporter (see `report_motion_cache_status` below) — never mutates
    /// state and never touches a file, so it is safe to call from anywhere
    /// that holds a `&MotionBuffer`.
    pub fn ring_stats(&self) -> (usize, i64) {
        let bytes = self.pending.iter().map(|s| s.size_bytes).sum();
        (self.pending.len(), bytes)
    }

    /// Drain the ENTIRE ring (oldest first), leaving the buffer's state
    /// untouched. The caller persists every returned segment — this is the
    /// footage-safe "flush everything awaiting a verdict" primitive shared by
    /// the healthy→unhealthy fail-open transition (#77): the ring's segments
    /// have not been through a keep/discard decision, so the only safe exits
    /// for them are a real verdict or a persist, never silent deletion.
    pub fn drain_ring(&mut self) -> Vec<PendingSegment> {
        self.pending.drain(..).collect()
    }
}

/// Unions the START/STOP edges from N **additive** motion sources into the single
/// coherent event stream [`MotionBuffer::apply_signal`] expects.
///
/// Why this exists: `apply_signal` tracks ONE event (Idle/Recording/PostBuffer).
/// With two sources feeding independent START/STOP pairs, one source's STOP would
/// flip the buffer to PostBuffer while the other source is still open; after the
/// post-roll it goes Idle → **recording stops while motion is still happening = a
/// footage gap.** This state machine collapses the per-source edges so the buffer
/// only ever sees a rising edge when the FIRST source opens and a falling edge
/// when the LAST source closes. `apply_signal` itself is unchanged (golden rule 2:
/// don't bet footage on modifying the buffer — feed it a clean stream instead).
///
/// It feeds the **buffer only**. Raw per-source signals still flow to
/// `pending_signals` for `has_motion`/bbox stamping, which already unions across
/// signals (it scans for ANY overlap), so per-source motion bbox is preserved.
///
/// Keyed by `started_at`: a source's START and its matching STOP share it, and
/// distinct sources have distinct wall-clock start times. A `started_at` collision
/// across sources is astronomically unlikely and would merely merge two events
/// (still footage-safe). For a single-source camera this is a pass-through — the
/// synthetic edges are identical to the raw ones, so behavior is unchanged.
#[derive(Debug, Default)]
pub struct MotionUnion {
    /// Currently-open event keys (each source's in-flight `started_at`).
    open: std::collections::BTreeSet<DateTime<Utc>>,
    /// `started_at` of the union event while it is open (the first opener's) —
    /// used as the synthetic START/STOP `started_at` so pre-buffer flush covers
    /// from the earliest motion.
    union_started_at: Option<DateTime<Utc>>,
    /// #74 (fail-open desync): the most recent synthetic union edge produced
    /// while the [`MotionBuffer`] was frozen (the unhealthy-while-caching
    /// window), held until the buffer thaws and can be resynced. Only the
    /// NEWEST edge matters: [`fold`](Self::fold) emits strictly alternating
    /// START/STOP edges (it fires only on the 0→1 and 1→0 open-count
    /// transitions), and the buffer only needs to converge to the union's
    /// current regime — a final START means "an event is open, resume
    /// Recording" (any intermediate events' footage was already persisted
    /// directly by fail-open), a final STOP means "closed, run the post-roll
    /// down from its `stopped_at`". Replay can therefore only add persisted
    /// footage relative to dropping the edges, never remove any.
    pending_replay: Option<MotionSignal>,
}

impl MotionUnion {
    /// Fold one raw source signal in. Returns the synthetic signal to feed the
    /// buffer when the union state *changes* (0→1 open = START, 1→0 = STOP), or
    /// `None` for a re-trigger / an unmatched STOP / an interleaved edge that
    /// leaves the union state unchanged.
    pub fn fold(&mut self, sig: &MotionSignal) -> Option<MotionSignal> {
        // NOTE (#7, deliberately NOT a time-based expiry): a blind expiry of
        // open keys older than MAX_OPEN_SIGNAL_SECS is NOT footage-safe on a
        // MULTI-source camera. Genuinely-long open events are real — an HA
        // occupancy/contact sensor held "on" for hours (ha_motion.rs: "real,
        // not a dropped end"), or a pixel event through a sustained storm. If
        // such a long event's key were expired, a SECOND source's short event
        // closing would empty the union, drive the buffer Recording→PostBuffer→
        // Idle, and DISCARD segments while a healthy source is still asserting
        // motion (golden rule 2 / invariant #19 — never bet footage on a buffer
        // change; "unknown" resolves to keep). The wedge a blind expiry targets
        // (a lost STOP pinning Recording) is already covered the footage-safe
        // way: a STOP lost to channel overflow trips the #81 loss debt →
        // fail-open (over-record); a panicked source is respawned by the
        // motion-source supervision and its health goes false for the gap. What
        // remains is only over-record (disk waste, bounded by retention), never
        // loss — the correct direction. Do NOT reintroduce a time-based expiry
        // here; a proper fix keys `open` by source identity and expires a key
        // only when the SAME source re-opens (definitive lost-STOP evidence).
        match sig.stopped_at {
            None => {
                // START: union rises only on the first open.
                let was_empty = self.open.is_empty();
                self.open.insert(sig.started_at);
                if was_empty {
                    self.union_started_at = Some(sig.started_at);
                    Some(MotionSignal {
                        camera_id: sig.camera_id,
                        started_at: sig.started_at,
                        stopped_at: None,
                        peak_score: sig.peak_score,
                        bbox: None,
                    })
                } else {
                    None
                }
            }
            Some(stopped_at) => {
                // STOP: union falls only when the LAST open event closes.
                let removed = self.open.remove(&sig.started_at);
                if removed && self.open.is_empty() {
                    let started_at = self.union_started_at.take().unwrap_or(sig.started_at);
                    Some(MotionSignal {
                        camera_id: sig.camera_id,
                        started_at,
                        stopped_at: Some(stopped_at),
                        peak_score: sig.peak_score,
                        bbox: None,
                    })
                } else {
                    None
                }
            }
        }
    }

    /// Stash a synthetic edge produced by [`fold`](Self::fold) while the
    /// buffer was frozen (fail-open unhealthy window), overwriting any older
    /// stashed edge — only the newest one matters (see
    /// [`pending_replay`](Self::pending_replay)'s doc for why that is
    /// footage-safe).
    pub fn stash_replay(&mut self, edge: MotionSignal) {
        self.pending_replay = Some(edge);
    }

    /// Take (and clear) the stashed frozen-window edge, if any — applied to
    /// the buffer by `drain_and_persist_motion` the first time the buffer is
    /// driven again after a frozen window.
    pub fn take_pending_replay(&mut self) -> Option<MotionSignal> {
        self.pending_replay.take()
    }
}

// ─── unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    // Helper to build a UTC DateTime quickly.
    fn utc(y: i32, mo: u32, d: u32, h: u32, m: u32, s: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, mo, d, h, m, s).unwrap()
    }

    // ── audio segmenter args (declared-track-must-carry-packets invariant) ──────

    #[test]
    fn audio_args_always_reencode_to_gapfilled_48k_aac() {
        // Audio is ALWAYS re-encoded now: a bit-exact copy preserves the camera's
        // drifting audio timeline and Android playback goes silent
        // (UnexpectedDiscontinuityException). aresample=async=1 makes it
        // sample-continuous; -c:a aac -ar 48000 normalizes the codec/rate.
        let args = audio_segmenter_args(true);
        assert!(
            args.windows(2).any(|w| w == ["-c:a", "aac"]),
            "must encode AAC; got {args:?}"
        );
        assert!(
            args.windows(2).any(|w| w == ["-ar", "48000"]),
            "must normalize to 48 kHz; got {args:?}"
        );
        assert!(
            args.windows(2)
                .any(|w| w == ["-af", "aresample=async=1:first_pts=0"]),
            "must gap-fill onto a continuous lattice (aresample=async); got {args:?}"
        );
        assert!(
            !args.contains(&"copy") && !args.contains(&"-copyinkf:a"),
            "the re-encode path must not copy (no keyframe gate); got {args:?}"
        );
    }

    #[test]
    fn audio_args_disable_audio_when_not_recording_audio() {
        // record_audio=false ⇒ -an, no audio output at all.
        let args = audio_segmenter_args(false);
        assert!(
            args.contains(&"-an"),
            "record_audio=false must pass -an; got {args:?}"
        );
        assert!(
            !args.contains(&"aac") && !args.contains(&"copy"),
            "record_audio=false has no audio; got {args:?}"
        );
    }

    // ── classify_failure (cold-start fast retry) ────────────────────────────────

    #[test]
    fn classify_cold_start_when_no_segment_and_fast_eof() {
        // The exact prod signature: recorder just restarted, go2rtc has no
        // streams yet, ffmpeg connects and immediately exits with no segment
        // ever written.
        assert_eq!(
            classify_failure(false, true),
            FailureClass::ColdStartNotReady
        );
    }

    #[test]
    fn classify_steady_state_when_segment_was_seen_even_with_fast_eof() {
        // GUARDRAIL: a stream that has already produced at least one segment
        // this run must NEVER classify as cold-start again, even if it then
        // fails fast — this is a real disconnect of a working stream, not a
        // "go2rtc isn't ready yet" symptom, and must get the normal backoff
        // so a flapping-but-technically-alive camera can't be fast-retried
        // forever.
        assert_eq!(classify_failure(true, true), FailureClass::SteadyState);
    }

    #[test]
    fn classify_steady_state_on_watchdog_stall_even_with_no_segment() {
        // GUARDRAIL: the segment-receipt watchdog (90s stall) is never
        // cold-start, regardless of whether a segment was ever seen — it
        // already paid the full 90s wait, so there is no startup latency left
        // to compensate for, and a camera that is genuinely unreachable after
        // never connecting must not be fast-retried indefinitely.
        assert_eq!(classify_failure(false, false), FailureClass::SteadyState);
    }

    #[test]
    fn classify_steady_state_when_segment_seen_and_clean_eof_absent() {
        assert_eq!(classify_failure(true, false), FailureClass::SteadyState);
    }

    // ── parse_segment_timestamp ────────────────────────────────────────────────

    #[test]
    fn parse_timestamp_valid() {
        let ts = parse_segment_timestamp("20260101T030000Z.mp4").unwrap();
        assert_eq!(ts, utc(2026, 1, 1, 3, 0, 0));
    }

    #[test]
    fn parse_timestamp_full_path() {
        let ts = parse_segment_timestamp("/data/live/cam/2026/01/01/20260101T235959Z.mp4").unwrap();
        assert_eq!(ts, utc(2026, 1, 1, 23, 59, 59));
    }

    #[test]
    fn parse_timestamp_bad_extension() {
        assert!(parse_segment_timestamp("20260101T030000Z.mkv").is_err());
    }

    #[test]
    fn parse_timestamp_bad_format() {
        assert!(parse_segment_timestamp("not-a-date.mp4").is_err());
    }

    // ── clamp_recovered_end_ts (R5: in-flight recovery mtime clamp) ─────────────

    #[test]
    fn clamp_keeps_plausible_mtime() {
        // A 4s segment (segment_seconds=4) whose mtime lands 3s after start —
        // well within the 2x-segment-seconds plausibility window — is trusted
        // verbatim.
        let start = utc(2026, 1, 1, 0, 0, 0);
        let mtime = start + chrono::Duration::seconds(3);
        assert_eq!(clamp_recovered_end_ts(start, mtime, 4), mtime);
    }

    #[test]
    fn clamp_rejects_watchdog_stall_duration() {
        // Regression: a SEGMENT_RECEIPT_TIMEOUT_SECS (90s) watchdog stall can
        // leave a ~4s segment's file mtime ~90s after start_ts even though the
        // actual content is only a few seconds — the exact prod bug (328 rows).
        // With segment_seconds=4, the plausibility window is 2*4=8s, so a 90s
        // gap must clamp down to start+4s, not report a ~90s duration.
        let start = utc(2026, 1, 1, 0, 0, 0);
        let mtime = start + chrono::Duration::seconds(90);
        let clamped = clamp_recovered_end_ts(start, mtime, 4);
        assert_eq!(clamped, start + chrono::Duration::seconds(4));
    }

    #[test]
    fn clamp_rejects_mtime_at_or_before_start() {
        // A copied/reset mtime that is not strictly after start_ts is
        // implausible (a real segment always has positive duration) and must
        // fall back to start + segment_seconds.
        let start = utc(2026, 1, 1, 0, 0, 0);
        assert_eq!(
            clamp_recovered_end_ts(start, start, 4),
            start + chrono::Duration::seconds(4)
        );
        assert_eq!(
            clamp_recovered_end_ts(start, start - chrono::Duration::seconds(1), 4),
            start + chrono::Duration::seconds(4)
        );
    }

    #[test]
    fn clamp_boundary_exactly_twice_segment_len_is_kept() {
        // The boundary condition is `> max_plausible`, so a gap of EXACTLY
        // 2*segment_seconds is still accepted (not clamped).
        let start = utc(2026, 1, 1, 0, 0, 0);
        let mtime = start + chrono::Duration::seconds(8); // exactly 2*4
        assert_eq!(clamp_recovered_end_ts(start, mtime, 4), mtime);
    }

    // ── R3a: LIVE-path sub-floor reject shares reconcile's constant ────────────

    #[test]
    fn live_path_sub_floor_matches_reconcile_orphan_floor() {
        // R3 requires the LIVE insert path (index_segment) and the reconcile
        // orphan/dangling passes to reject the EXACT same "near-empty segment"
        // byte floor — a single source of truth, not two constants that can
        // drift apart. index_segment reads `crate::reconcile::SUB_FLOOR_BYTES`
        // directly (see its sub-floor-reject check), so this test pins the
        // value itself: if reconcile's floor ever changes, this test forces a
        // conscious update rather than a silent behavioral split.
        assert_eq!(crate::reconcile::SUB_FLOOR_BYTES, 512);
    }

    // ── overlaps_motion ────────────────────────────────────────────────────────

    fn make_signal(start: DateTime<Utc>, stop: Option<DateTime<Utc>>) -> MotionSignal {
        MotionSignal {
            camera_id: uuid::Uuid::nil(),
            started_at: start,
            stopped_at: stop,
            peak_score: 0.5,
            bbox: None,
        }
    }

    #[test]
    fn motion_overlaps_started_inside_segment() {
        // Segment [0:00, 0:04); motion started at 0:02 (still in progress).
        let seg_s = utc(2026, 1, 1, 0, 0, 0);
        let seg_e = utc(2026, 1, 1, 0, 0, 4);
        let sig = make_signal(utc(2026, 1, 1, 0, 0, 2), None);
        assert!(overlaps_motion(seg_s, seg_e, &sig));
    }

    // ── MotionUnion (additive multi-source edge union) ──────────────────────────

    fn t(s: u32) -> DateTime<Utc> {
        utc(2026, 1, 1, 0, 0, s)
    }

    #[test]
    fn union_single_source_is_passthrough() {
        // One source: the synthetic edges must equal the raw edges (behavior
        // unchanged for existing single-source cameras).
        let mut u = MotionUnion::default();
        let start = u
            .fold(&make_signal(t(0), None))
            .expect("START passes through");
        assert_eq!(start.started_at, t(0));
        assert!(start.stopped_at.is_none());
        let stop = u
            .fold(&make_signal(t(0), Some(t(5))))
            .expect("STOP passes through");
        assert_eq!(stop.stopped_at, Some(t(5)));
    }

    #[test]
    fn union_two_sources_no_gap_when_one_stops_while_other_open() {
        // THE crux: pixel opens, HA opens, PIXEL STOPS while HA still open. The
        // buffer must NOT see a STOP (which would start the post-roll and end
        // recording early). Only when the LAST source closes does STOP fire.
        let mut u = MotionUnion::default();
        // pixel START @0 → union rises → synthetic START.
        assert!(u.fold(&make_signal(t(0), None)).is_some());
        // ha START @2 (different started_at) → union already open → nothing.
        assert!(u.fold(&make_signal(t(2), None)).is_none());
        // pixel STOP @5 → ha still open → NO synthetic STOP (no gap!).
        assert!(u.fold(&make_signal(t(0), Some(t(5)))).is_none());
        // ha STOP @9 → last source closes → synthetic STOP, from the union start.
        let stop = u.fold(&make_signal(t(2), Some(t(9)))).expect("union STOP");
        assert_eq!(stop.started_at, t(0)); // earliest opener fixes the pre-buffer
        assert_eq!(stop.stopped_at, Some(t(9)));
    }

    #[test]
    fn union_retrigger_within_open_emits_no_duplicate_start() {
        let mut u = MotionUnion::default();
        assert!(u.fold(&make_signal(t(0), None)).is_some()); // first START
        assert!(u.fold(&make_signal(t(3), None)).is_none()); // second source, no dup START
        assert!(u.fold(&make_signal(t(0), Some(t(4)))).is_none()); // one closes, still open
        assert!(u.fold(&make_signal(t(3), Some(t(6)))).is_some()); // last closes → STOP
    }

    #[test]
    fn union_unmatched_stop_is_ignored() {
        let mut u = MotionUnion::default();
        // STOP with no prior START (stale / buffer started mid-event): no edge.
        assert!(u.fold(&make_signal(t(0), Some(t(1)))).is_none());
        // A real event still works afterwards.
        assert!(u.fold(&make_signal(t(2), None)).is_some());
        assert!(u.fold(&make_signal(t(2), Some(t(5)))).is_some());
    }

    #[test]
    fn union_reopen_after_close_is_a_fresh_event() {
        let mut u = MotionUnion::default();
        assert!(u.fold(&make_signal(t(0), None)).is_some());
        // First event opens then closes.
        assert!(u.fold(&make_signal(t(0), Some(t(2)))).is_some());
        // A later source opens: a brand-new union event (fresh START).
        let re = u.fold(&make_signal(t(10), None)).expect("fresh START");
        assert_eq!(re.started_at, t(10));
    }

    // ── #74: fail-open window must not desync MotionUnion / MotionBuffer ───────

    /// Build a bounded motion channel like main.rs's, for driving
    /// `drain_and_persist_motion` directly in tests.
    fn motion_channel() -> (tokio::sync::mpsc::Sender<MotionSignal>, MotionRx) {
        tokio::sync::mpsc::channel(16)
    }

    #[tokio::test]
    async fn source_opened_while_unhealthy_resyncs_buffer_and_closes_cleanly() {
        // #74 (H3): a source OPENS during an unhealthy (fail-open) window —
        // the drain consumes the signal from the channel, so pre-fix the union
        // never saw the open: when health returned, the buffer sat Idle while
        // motion was ongoing (segments ringed → aged out → DISCARDED), and the
        // eventual STOP hit the union unmatched. Post-fix: the union folds the
        // edge even while the buffer is frozen, stashes it, and replays it on
        // thaw, so the buffer resumes Recording and the STOP matches.
        let (tx, mut rx) = motion_channel();
        let mut buf = MotionBuffer::new(5, 10);
        let mut union = MotionUnion::default();
        let mut out: Vec<MotionSignal> = Vec::new();

        // Pre-freeze: one idle ring segment (pre-roll for the coming event).
        buf.push_segment(pending(0, 4));

        // UNHEALTHY window: source opens at t=6. Buffer frozen (None).
        tx.try_send(motion_start(6)).expect("send START");
        let mut d1 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, None, &mut union, &mut d1).await;
        assert!(
            d1.persist.is_empty() && d1.discard.is_empty(),
            "the frozen window itself must not produce buffer decisions"
        );
        assert!(
            matches!(buf.state, MotionBufferState::Idle),
            "the frozen buffer must not be driven while unhealthy"
        );
        assert!(!union.open.is_empty(), "the union must see the open edge");

        // HEALTHY again: first drive replays the stashed START → the buffer
        // resyncs to Recording and flushes the pre-roll ring as PERSISTS.
        let mut d2 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, Some(&mut buf), &mut union, &mut d2).await;
        assert!(
            matches!(buf.state, MotionBufferState::Recording { .. }),
            "the buffer must resync to the union's open regime on thaw"
        );
        assert_eq!(
            d2.persist.len(),
            1,
            "the pre-roll ring segment must be flushed as a PERSIST: {d2:?}"
        );
        assert!(d2.discard.is_empty(), "no spurious discard on resync");

        // Segments during the resynced ongoing event persist (this is exactly
        // the footage the pre-fix desync silently discarded).
        let d3 = buf.push_segment(pending(8, 12));
        assert_eq!(d3.persist.len(), 1, "event-tail segments must persist");

        // The source CLOSES while healthy: the STOP must match the open key
        // folded during the unhealthy window — no stuck-open union.
        tx.try_send(motion_stop(6, 12)).expect("send STOP");
        let mut d4 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, Some(&mut buf), &mut union, &mut d4).await;
        assert!(
            union.open.is_empty(),
            "the union must not be left stuck open after the close"
        );
        assert!(
            matches!(buf.state, MotionBufferState::PostBuffer { .. }),
            "the STOP must reach the buffer and start the post-roll"
        );
        assert!(d4.discard.is_empty());
    }

    #[tokio::test]
    async fn stop_drained_while_unhealthy_replays_on_thaw_without_wedging() {
        // #74 inverse direction: the event opened while HEALTHY, then its STOP
        // was drained during the unhealthy window. Pre-fix the union kept the
        // event's key open forever (the STOP was consumed unfolded), so every
        // subsequent event's STOP left the union non-empty → no synthetic STOP
        // ever again → the buffer wedged in Recording across every future
        // fail-open episode. Post-fix: the union sees the close, and the thaw
        // replays it as a post-roll rundown (persist-more, never less).
        let (tx, mut rx) = motion_channel();
        let mut buf = MotionBuffer::new(5, 10);
        let mut union = MotionUnion::default();
        let mut out: Vec<MotionSignal> = Vec::new();

        // Healthy: the event opens normally.
        tx.try_send(motion_start(0)).expect("send START");
        let mut d0 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, Some(&mut buf), &mut union, &mut d0).await;
        assert!(matches!(buf.state, MotionBufferState::Recording { .. }));

        // Unhealthy: the STOP is drained with the buffer frozen.
        tx.try_send(motion_stop(0, 8)).expect("send STOP");
        let mut d1 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, None, &mut union, &mut d1).await;
        assert!(
            union.open.is_empty(),
            "the union's accounting must see the close even while frozen"
        );
        assert!(
            matches!(buf.state, MotionBufferState::Recording { .. }),
            "the frozen buffer itself must not be driven"
        );

        // Healthy again: the replayed STOP runs the post-roll down instead of
        // leaving the buffer Recording forever with a desynced union.
        let mut d2 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, Some(&mut buf), &mut union, &mut d2).await;
        assert!(
            matches!(buf.state, MotionBufferState::PostBuffer { .. }),
            "the stashed STOP must be replayed on thaw"
        );

        // A brand-new event afterwards opens AND closes cleanly (no stale keys).
        tx.try_send(motion_start(30)).expect("send START 2");
        let mut d3 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, Some(&mut buf), &mut union, &mut d3).await;
        assert!(matches!(buf.state, MotionBufferState::Recording { .. }));
        tx.try_send(motion_stop(30, 35)).expect("send STOP 2");
        let mut d4 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, Some(&mut buf), &mut union, &mut d4).await;
        assert!(union.open.is_empty(), "no stuck-open key after the fix");
        assert!(matches!(buf.state, MotionBufferState::PostBuffer { .. }));
    }

    #[tokio::test]
    async fn full_event_inside_unhealthy_window_replays_stop_into_post_buffer() {
        // #74 boundary: an event opens AND closes entirely inside the frozen
        // window (its body was persisted directly by fail-open). Only the newest
        // edge (the STOP) is stashed. On thaw, replaying that STOP onto the Idle
        // buffer must enter PostBuffer — NOT stale-ignore it — so the event's
        // post-roll (segments within motion_post_seconds after the stop) is kept
        // (MOTION-RECORDING.md §4). The union ends consistent (empty).
        let (tx, mut rx) = motion_channel();
        let mut buf = MotionBuffer::new(5, 10);
        let mut union = MotionUnion::default();
        let mut out: Vec<MotionSignal> = Vec::new();

        tx.try_send(motion_start(2)).expect("send START");
        tx.try_send(motion_stop(2, 6)).expect("send STOP");
        let mut d1 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, None, &mut union, &mut d1).await;
        assert!(union.open.is_empty());

        let mut d2 = MotionDecision::empty();
        drain_and_persist_motion(&mut rx, &mut out, Some(&mut buf), &mut union, &mut d2).await;
        assert!(
            matches!(buf.state, MotionBufferState::PostBuffer { .. }),
            "a replayed STOP after a full in-window event must enter PostBuffer to keep the post-roll"
        );
        // The ring was empty at thaw (fail-open persisted the body directly), so
        // entering PostBuffer produces no immediate persist/discard here — the
        // post-roll is kept by subsequent push_segment calls within the window.
        assert!(d2.persist.is_empty() && d2.discard.is_empty());
    }

    #[test]
    fn motion_union_keeps_long_event_open_across_a_second_sources_event() {
        // #7 regression guard: a genuinely-long open event on one source must
        // NOT be closed by a second source's short event — recording continues
        // as long as ANY source asserts motion. (This is why the blind
        // time-based expiry was reverted: it discarded footage here.)
        let mut union = MotionUnion::default();
        let t0 = utc(2026, 1, 1, 0, 0, 0);
        // Source A opens a long event (e.g. an HA occupancy sensor held on).
        assert!(
            union.fold(&make_signal(t0, None)).is_some(),
            "A opens the union"
        );
        // Much later (> MAX_OPEN_SIGNAL_SECS) source B has a short event while A
        // is still open. B's START is a re-trigger (union already open → None);
        // B's STOP must NOT fall the union, because A is still open.
        let late = t0 + chrono::Duration::seconds(MAX_OPEN_SIGNAL_SECS + 60);
        assert!(
            union.fold(&make_signal(late, None)).is_none(),
            "B is a re-trigger"
        );
        assert!(
            union
                .fold(&make_signal(
                    late,
                    Some(late + chrono::Duration::seconds(4))
                ))
                .is_none(),
            "B's STOP must NOT close the union while A is still open (no footage loss)"
        );
        assert_eq!(union.open.len(), 1, "A's long event stays open");
        // Only A's own STOP closes the union.
        assert!(
            union
                .fold(&make_signal(t0, Some(late + chrono::Duration::seconds(30))))
                .is_some(),
            "A's real STOP finally closes the union"
        );
        assert!(union.open.is_empty());
    }

    // ── prune_pending_signals (the "stuck motion" regression) ───────────────────

    #[test]
    fn prune_drops_open_start_once_its_stop_arrives() {
        // A motion event: START at 0:00 (open), then STOP at 0:08 — emitted by
        // motion.rs as two separate signals with the same started_at.
        let started = utc(2026, 1, 1, 0, 0, 0);
        let mut signals = vec![
            make_signal(started, None),                           // open START
            make_signal(started, Some(utc(2026, 1, 1, 0, 0, 8))), // matching STOP
        ];
        // Index a much later segment (boundary well past the stop).
        prune_pending_signals(&mut signals, utc(2026, 1, 1, 0, 1, 0));
        // The superseded open START AND the now-old closed signal are both gone,
        // so later segments are NOT marked as motion. (This is the bug fix: the
        // open START used to linger forever and stamp every future segment.)
        assert!(
            signals.is_empty(),
            "open START must be cleared once its STOP arrives: {signals:?}"
        );
    }

    #[test]
    fn prune_retains_genuinely_ongoing_open_start() {
        // An open START with NO stop yet = motion still in progress → keep it so
        // the ongoing event keeps marking segments.
        let started = utc(2026, 1, 1, 0, 0, 0);
        let mut signals = vec![make_signal(started, None)];
        prune_pending_signals(&mut signals, utc(2026, 1, 1, 0, 0, 20));
        assert_eq!(signals.len(), 1, "ongoing motion must stay marked");
    }

    #[test]
    fn prune_force_expires_a_wedged_open_start() {
        // Safety net: an open START with no STOP for > MAX_OPEN_SIGNAL_SECS (the
        // motion task wedged) is force-expired so it can't mark segments forever.
        let started = utc(2026, 1, 1, 0, 0, 0);
        let mut signals = vec![make_signal(started, None)];
        let boundary = started + chrono::Duration::seconds(MAX_OPEN_SIGNAL_SECS + 1);
        prune_pending_signals(&mut signals, boundary);
        assert!(
            signals.is_empty(),
            "a wedged open START must be force-expired"
        );
    }

    #[test]
    fn motion_overlaps_started_before_segment_ended_after() {
        // Segment [0:04, 0:08); motion [0:02, 0:06) — overlaps.
        let seg_s = utc(2026, 1, 1, 0, 0, 4);
        let seg_e = utc(2026, 1, 1, 0, 0, 8);
        let sig = make_signal(utc(2026, 1, 1, 0, 0, 2), Some(utc(2026, 1, 1, 0, 0, 6)));
        assert!(overlaps_motion(seg_s, seg_e, &sig));
    }

    #[test]
    fn motion_no_overlap_stopped_before_segment() {
        // Segment [0:08, 0:12); motion [0:02, 0:06) — no overlap.
        let seg_s = utc(2026, 1, 1, 0, 0, 8);
        let seg_e = utc(2026, 1, 1, 0, 0, 12);
        let sig = make_signal(utc(2026, 1, 1, 0, 0, 2), Some(utc(2026, 1, 1, 0, 0, 6)));
        assert!(!overlaps_motion(seg_s, seg_e, &sig));
    }

    #[test]
    fn motion_no_overlap_started_after_segment() {
        // Segment [0:00, 0:04); motion started at 0:05 — no overlap.
        let seg_s = utc(2026, 1, 1, 0, 0, 0);
        let seg_e = utc(2026, 1, 1, 0, 0, 4);
        let sig = make_signal(utc(2026, 1, 1, 0, 0, 5), None);
        assert!(!overlaps_motion(seg_s, seg_e, &sig));
    }

    #[test]
    fn motion_in_progress_started_before_segment() {
        // Segment [0:04, 0:08); motion started at 0:01, still in progress — overlaps.
        let seg_s = utc(2026, 1, 1, 0, 0, 4);
        let seg_e = utc(2026, 1, 1, 0, 0, 8);
        let sig = make_signal(utc(2026, 1, 1, 0, 0, 1), None);
        assert!(overlaps_motion(seg_s, seg_e, &sig));
    }

    // ── MotionBuffer ───────────────────────────────────────────────────────────

    fn pending(start_s: u32, end_s: u32) -> PendingSegment {
        PendingSegment {
            path: format!("seg_{start_s}_{end_s}.mp4"),
            start_ts: utc(2026, 1, 1, 0, 0, start_s),
            end_ts: utc(2026, 1, 1, 0, 0, end_s),
            size_bytes: 1024,
        }
    }

    fn motion_start(s: u32) -> MotionSignal {
        make_signal(utc(2026, 1, 1, 0, 0, s), None)
    }

    fn motion_stop(start_s: u32, stop_s: u32) -> MotionSignal {
        make_signal(
            utc(2026, 1, 1, 0, 0, start_s),
            Some(utc(2026, 1, 1, 0, 0, stop_s)),
        )
    }

    #[test]
    fn idle_state_buffers_segments() {
        let mut buf = MotionBuffer::new(5, 10);
        // Push segments while Idle — they should be buffered, not persisted or
        // discarded (the ring is nowhere near its pre_seconds+slack cutoff yet).
        let d1 = buf.push_segment(pending(0, 4));
        assert!(d1.persist.is_empty() && d1.discard.is_empty());
        let d2 = buf.push_segment(pending(4, 8));
        assert!(d2.persist.is_empty() && d2.discard.is_empty());
        assert_eq!(buf.pending.len(), 2);
    }

    #[test]
    fn motion_start_flushes_prebuffer() {
        let mut buf = MotionBuffer::new(5, 10);
        // Buffer two segments before motion.
        buf.push_segment(pending(0, 4));
        buf.push_segment(pending(4, 8));
        // Motion starts at t=10; pre_seconds=5 → pre-cutoff at t=5.
        // Segment [0,4) is too old; segment [4,8) is within window → flush [4,8).
        let decision = buf.apply_signal(&motion_start(10));
        assert_eq!(decision.persist.len(), 1);
        assert_eq!(decision.persist[0].start_ts, utc(2026, 1, 1, 0, 0, 4));
        // The too-old segment [0,4) is a genuine DISCARD (never touches storage).
        assert_eq!(decision.discard.len(), 1);
        assert_eq!(decision.discard[0].start_ts, utc(2026, 1, 1, 0, 0, 0));
        assert!(matches!(buf.state, MotionBufferState::Recording { .. }));
    }

    #[test]
    fn recording_state_indexes_all_segments() {
        let mut buf = MotionBuffer::new(5, 10);
        // Trigger motion.
        buf.apply_signal(&motion_start(10));
        // Push two segments during recording — both should be persisted.
        let r1 = buf.push_segment(pending(10, 14));
        assert_eq!(r1.persist.len(), 1);
        assert!(r1.discard.is_empty());
        let r2 = buf.push_segment(pending(14, 18));
        assert_eq!(r2.persist.len(), 1);
        assert!(r2.discard.is_empty());
    }

    #[test]
    fn post_buffer_indexes_then_returns_to_idle() {
        let mut buf = MotionBuffer::new(5, 10);
        buf.apply_signal(&motion_start(0));
        buf.apply_signal(&motion_stop(0, 10)); // motion stopped at t=10
                                               // post_seconds=10 → post-deadline at t=20.
                                               // Segment at t=15 is within window — persisted.
        let r1 = buf.push_segment(pending(15, 19));
        assert_eq!(r1.persist.len(), 1);
        // Segment at t=25 is outside post-buffer — Idle, buffered (not
        // persisted, not discarded — it becomes the new ring's first entry).
        let r2 = buf.push_segment(pending(25, 29));
        assert!(r2.persist.is_empty() && r2.discard.is_empty());
        assert!(matches!(buf.state, MotionBufferState::Idle));
    }

    #[test]
    fn post_buffer_boundary_segment_starting_after_deadline_is_buffered_not_persisted() {
        // Explicit boundary-condition regression (spec: "segment starting after
        // motion_stopped+post_seconds is buffered, not persisted"). motion_stopped=10,
        // post_seconds=10 → deadline=20. A segment starting exactly at t=21 (start
        // STRICTLY after the deadline) must NOT be persisted.
        let mut buf = MotionBuffer::new(5, 10);
        buf.apply_signal(&motion_start(0));
        buf.apply_signal(&motion_stop(0, 10));
        let r = buf.push_segment(pending(21, 25));
        assert!(
            r.persist.is_empty(),
            "a segment starting after the post-buffer deadline must not be persisted"
        );
        assert!(matches!(buf.state, MotionBufferState::Idle));
    }

    #[test]
    fn post_buffer_boundary_segment_at_deadline_is_still_persisted() {
        // Companion boundary case: start_ts == deadline exactly is still WITHIN
        // the window (`<=`), so it persists.
        let mut buf = MotionBuffer::new(5, 10);
        buf.apply_signal(&motion_start(0));
        buf.apply_signal(&motion_stop(0, 10)); // deadline = 20
        let r = buf.push_segment(pending(20, 24));
        assert_eq!(
            r.persist.len(),
            1,
            "a segment starting exactly at the deadline is still persisted"
        );
    }

    #[test]
    fn retrigger_during_post_buffer_extends_without_reflushing_prebuffer() {
        // Spec: "re-trigger during PostBuffer extends without re-flushing."
        let mut buf = MotionBuffer::new(5, 10);
        buf.apply_signal(&motion_start(0));
        buf.push_segment(pending(0, 4));
        buf.apply_signal(&motion_stop(0, 4)); // → PostBuffer{motion_stopped: 4}
                                              // A NEW motion start arrives while in PostBuffer (a re-trigger).
        let decision = buf.apply_signal(&motion_start(6));
        // Re-trigger must NOT re-flush the pre-buffer (the ring is empty at this
        // point anyway — everything up to t=4 was already persisted during the
        // first Recording state), and must transition back to Recording.
        assert!(
            decision.persist.is_empty() && decision.discard.is_empty(),
            "a re-trigger from PostBuffer must not re-flush/discard anything: {decision:?}"
        );
        assert!(matches!(buf.state, MotionBufferState::Recording { .. }));
        // Subsequent segments persist immediately (extended recording, not a
        // fresh pre-buffer wait).
        let r = buf.push_segment(pending(6, 10));
        assert_eq!(r.persist.len(), 1);
    }

    #[test]
    fn stale_stop_signal_while_idle_is_ignored() {
        let mut buf = MotionBuffer::new(5, 10);
        let decision = buf.apply_signal(&motion_stop(0, 5));
        assert!(decision.persist.is_empty() && decision.discard.is_empty());
        assert!(matches!(buf.state, MotionBufferState::Idle));
    }

    #[test]
    fn ring_ages_out_old_segments_as_discards() {
        // Spec: "age-out discards". pre_seconds=5 → the ring retains
        // pre_seconds + RING_SLACK_SECS (8) = 13s of segments. Pushing a
        // segment far enough in the future must age out (discard) the earliest
        // buffered segment rather than silently dropping it uncounted.
        let mut buf = MotionBuffer::new(5, 10);
        // Seed the ring with one segment at t=[0,4).
        let d0 = buf.push_segment(pending(0, 4));
        assert!(d0.persist.is_empty() && d0.discard.is_empty());
        assert_eq!(buf.pending.len(), 1);

        // Push a segment starting well past the retention window (cutoff =
        // start_ts - 13s; a segment at t=20 makes the cutoff t=7, which is
        // past the first segment's start_ts=0, so it must be evicted now).
        let d1 = buf.push_segment(pending(20, 24));
        assert_eq!(
            d1.discard.len(),
            1,
            "the aged-out segment must come back as a discard: {d1:?}"
        );
        assert_eq!(d1.discard[0].start_ts, utc(2026, 1, 1, 0, 0, 0));
        assert!(
            d1.persist.is_empty(),
            "Idle state must never persist directly"
        );
        // The ring now holds only the newly-pushed segment.
        assert_eq!(buf.pending.len(), 1);
    }

    // ── decide_persist_for_segment ──────────────────────────────────────────────

    #[test]
    fn continuous_mode_always_persists_and_ignores_buffer() {
        let mut buf = MotionBuffer::new(5, 10);
        let seg = pending(0, 4);
        let decision = decide_persist_for_segment(
            RecordingMode::Continuous,
            /* caching_active */ false,
            /* detector_healthy */ true,
            &mut buf,
            &seg,
        );
        assert_eq!(decision.actual.persist.len(), 1);
        assert_eq!(decision.actual.persist[0].start_ts, seg.start_ts);
        assert!(decision.actual.discard.is_empty());
        assert!(
            decision.shadow.is_none(),
            "continuous mode never produces a shadow verdict"
        );
        // The buffer must be completely untouched in Continuous mode.
        assert!(matches!(buf.state, MotionBufferState::Idle));
        assert!(buf.pending.is_empty());
    }

    #[test]
    fn motion_mode_caching_active_healthy_delegates_to_buffer() {
        // With the cache active and the detector healthy, the REAL decision is
        // exactly what MotionBuffer would decide (Idle → buffered, not persisted).
        let mut buf = MotionBuffer::new(5, 10);
        let seg = pending(0, 4);
        let decision = decide_persist_for_segment(
            RecordingMode::Motion,
            /* caching_active */ true,
            /* detector_healthy */ true,
            &mut buf,
            &seg,
        );
        assert!(
            decision.actual.persist.is_empty(),
            "Idle-state buffer must not persist a fresh segment immediately"
        );
        assert!(
            decision.shadow.is_none(),
            "shadow is only populated when the cache is NOT active"
        );
        assert_eq!(
            buf.pending.len(),
            1,
            "the segment must land in the buffer's ring"
        );
    }

    #[test]
    fn motion_mode_unhealthy_detector_fails_open_and_freezes_buffer() {
        // Fail-open (spec item 4): an unhealthy detector must persist the
        // segment directly, exactly like Continuous, and must NOT drive the
        // buffer's STATE (the ring — empty here — is drained-to-persist on
        // the transition; see the #77 companion test below).
        let mut buf = MotionBuffer::new(5, 10);
        let seg = pending(0, 4);
        let decision = decide_persist_for_segment(
            RecordingMode::Motion,
            /* caching_active */ true,
            /* detector_healthy */ false,
            &mut buf,
            &seg,
        );
        assert_eq!(
            decision.actual.persist.len(),
            1,
            "fail-open must persist every segment while the detector is unhealthy"
        );
        assert!(decision.actual.discard.is_empty());
        assert!(decision.shadow.is_none());
        assert!(
            buf.pending.is_empty() && matches!(buf.state, MotionBufferState::Idle),
            "the buffer's state must be untouched (and the empty ring stay empty) while unhealthy"
        );
    }

    #[test]
    fn unhealthy_transition_drains_pending_ring_to_persist_not_discard() {
        // #77 (fail-open transition): segments sitting in the Idle ring when
        // the detector goes healthy→unhealthy were awaiting a keep/discard
        // verdict the detector can no longer render. They must be PERSISTED
        // (same footage-safe mechanics as the cache-pressure spill), never
        // left frozen to age out as discards once health returns.
        let mut buf = MotionBuffer::new(5, 10);
        buf.push_segment(pending(0, 4));
        buf.push_segment(pending(4, 8));
        assert_eq!(buf.pending.len(), 2, "ring holds two segments");

        // First segment completed while unhealthy: ring + completed all persist.
        let seg = pending(8, 12);
        let decision = decide_persist_for_segment(
            RecordingMode::Motion,
            /* caching_active */ true,
            /* detector_healthy */ false,
            &mut buf,
            &seg,
        );
        assert_eq!(
            decision.actual.persist.len(),
            3,
            "ring segments + the completed segment must ALL persist: {:?}",
            decision.actual.persist
        );
        // Oldest-first, completed last (matches the spill's drain order).
        let persisted = &decision.actual.persist;
        assert_eq!(persisted[0].start_ts, utc(2026, 1, 1, 0, 0, 0));
        assert_eq!(persisted[1].start_ts, utc(2026, 1, 1, 0, 0, 4));
        assert_eq!(persisted[2].start_ts, utc(2026, 1, 1, 0, 0, 8));
        assert!(
            decision.actual.discard.is_empty(),
            "the fail-open transition must never discard anything"
        );
        assert!(buf.pending.is_empty(), "the ring must be drained");
        assert!(
            matches!(buf.state, MotionBufferState::Idle),
            "the buffer's STATE must still be untouched (resumes where it left off)"
        );

        // Idempotent across the unhealthy window: the next unhealthy segment
        // persists only itself (the ring is already empty).
        let d2 = decide_persist_for_segment(
            RecordingMode::Motion,
            true,
            false,
            &mut buf,
            &pending(12, 16),
        );
        assert_eq!(d2.actual.persist.len(), 1);
        assert!(d2.actual.discard.is_empty());
    }

    #[test]
    fn unhealthy_during_recording_keeps_state_for_resume() {
        // #77 companion: if the buffer was mid-event (Recording) when health
        // was lost, the ring is empty (Recording persists as it goes) and the
        // Recording state must survive the frozen window so the event resumes
        // persisting on thaw.
        let mut buf = MotionBuffer::new(5, 10);
        buf.apply_signal(&motion_start(0));
        let d = decide_persist_for_segment(
            RecordingMode::Motion,
            true,
            /* detector_healthy */ false,
            &mut buf,
            &pending(4, 8),
        );
        assert_eq!(d.actual.persist.len(), 1);
        assert!(
            matches!(buf.state, MotionBufferState::Recording { .. }),
            "Recording state must be preserved through the unhealthy window"
        );
    }

    #[test]
    fn motion_mode_cache_inactive_persists_and_records_shadow_verdict() {
        // Shadow mode / cache-dir fallback: file operations always persist, but
        // the buffer is still driven for real and its verdict comes back
        // separately as `.shadow` — here it's Idle, so the buffer BUFFERS the
        // segment (shadow decision has nothing yet) while `.actual` persists it.
        let mut buf = MotionBuffer::new(5, 10);
        let seg = pending(0, 4);
        let decision = decide_persist_for_segment(
            RecordingMode::Motion,
            /* caching_active */ false,
            /* detector_healthy */ true,
            &mut buf,
            &seg,
        );
        assert_eq!(
            decision.actual.persist.len(),
            1,
            "cache-inactive mode must always persist (there is no cache file to discard)"
        );
        let shadow = decision
            .shadow
            .expect("cache-inactive mode must report a shadow verdict");
        assert!(shadow.persist.is_empty() && shadow.discard.is_empty());
        assert_eq!(
            buf.pending.len(),
            1,
            "the buffer must still be driven for real in shadow mode"
        );
    }

    #[test]
    fn motion_mode_cache_inactive_shadow_verdict_reflects_real_buffer_decision() {
        // Drive the buffer into Recording first, then confirm the shadow
        // verdict reports "would persist" even though `.actual` persists
        // unconditionally in this mode anyway (proving `.shadow` is a genuinely
        // independent readout, not just a copy of `.actual`).
        let mut buf = MotionBuffer::new(5, 10);
        buf.apply_signal(&motion_start(0));
        let seg = pending(0, 4);
        let decision = decide_persist_for_segment(
            RecordingMode::Motion,
            /* caching_active */ false,
            /* detector_healthy */ true,
            &mut buf,
            &seg,
        );
        assert_eq!(decision.actual.persist.len(), 1);
        let shadow = decision.shadow.expect("shadow verdict expected");
        assert_eq!(
            shadow.persist.len(),
            1,
            "buffer is in Recording state, so the shadow verdict must say PERSIST"
        );
    }

    #[test]
    fn compute_relative_path_strips_root() {
        let rel = compute_relative_path(
            "/data/live/cam/2026/01/01/20260101T030000Z.mp4",
            "/data/live",
        );
        assert_eq!(rel, "cam/2026/01/01/20260101T030000Z.mp4");
    }

    #[test]
    fn compute_relative_path_no_match_returns_full() {
        let rel = compute_relative_path("/other/path/file.mp4", "/data/live");
        assert_eq!(rel, "/other/path/file.mp4");
    }

    // ── MotionBuffer::ring_stats (motion-cache telemetry accessor) ─────────────

    #[test]
    fn ring_stats_empty_buffer_is_zero() {
        let buf = MotionBuffer::new(5, 10);
        assert_eq!(buf.ring_stats(), (0, 0));
    }

    #[test]
    fn ring_stats_reflects_pending_segments_while_idle() {
        let mut buf = MotionBuffer::new(30, 10);
        buf.push_segment(pending(0, 4));
        buf.push_segment(pending(4, 8));
        // `pending()` hardcodes size_bytes: 1024 per segment.
        assert_eq!(buf.ring_stats(), (2, 2048));
    }

    #[test]
    fn ring_stats_empties_after_motion_flushes_the_prebuffer() {
        let mut buf = MotionBuffer::new(30, 10);
        buf.push_segment(pending(0, 4));
        buf.push_segment(pending(4, 8));
        assert_eq!(buf.ring_stats().0, 2);
        // Motion at t=8 flushes/discards everything currently pending; the ring
        // has nothing left buffered while Recording (every new segment persists
        // immediately rather than entering the ring — see push_segment).
        buf.apply_signal(&motion_start(8));
        assert_eq!(
            buf.ring_stats(),
            (0, 0),
            "ring must be empty once the pre-buffer is flushed into Recording"
        );
    }

    // ── cache_dir_conflicts_with_storage (MOTION_CACHE_DIR storage-root guard) ──

    #[test]
    fn cache_dir_outside_every_storage_root_is_fine() {
        let roots = vec![
            ("NVMe-Live".to_owned(), PathBuf::from("/data/live")),
            ("Bulk-Archive".to_owned(), PathBuf::from("/data/archive")),
        ];
        assert!(cache_dir_conflicts_with_storage(Path::new("/cache/motion"), &roots).is_none());
    }

    #[test]
    fn cache_dir_equal_to_storage_root_conflicts() {
        let roots = vec![("NVMe-Live".to_owned(), PathBuf::from("/data/live"))];
        let conflict = cache_dir_conflicts_with_storage(Path::new("/data/live"), &roots);
        assert_eq!(conflict.map(|(n, _)| n), Some("NVMe-Live".to_owned()));
    }

    #[test]
    fn cache_dir_nested_under_storage_root_conflicts() {
        let roots = vec![("Bulk-Archive".to_owned(), PathBuf::from("/data/archive"))];
        let conflict =
            cache_dir_conflicts_with_storage(Path::new("/data/archive/motion-cache"), &roots);
        assert_eq!(conflict.map(|(n, _)| n), Some("Bulk-Archive".to_owned()));
    }

    #[test]
    fn cache_dir_sibling_of_storage_root_does_not_conflict() {
        // A path that merely SHARES A PREFIX string (not a real path component
        // nesting) must not false-positive. `/data/live2` is not "under"
        // `/data/live` even though the string starts with it.
        let roots = vec![("NVMe-Live".to_owned(), PathBuf::from("/data/live"))];
        assert!(cache_dir_conflicts_with_storage(Path::new("/data/live2"), &roots).is_none());
    }

    // ── should_spill_cache (cache-pressure spill decision) ─────────────────────

    #[test]
    fn spill_triggers_below_twenty_percent_floor() {
        // total=100GB, 20% floor = 20GB. A tiny recent segment (1MB) means the
        // 2x-segment floor (2MB) is irrelevant — the 20% floor dominates.
        let total = 100 * 1024 * 1024 * 1024i64;
        let recent_seg = 1024 * 1024i64; // 1 MB
        let floor_20pct = (total as f64 * 0.20) as i64;
        assert!(
            should_spill_cache(floor_20pct - 1, total, recent_seg),
            "just below the 20% floor must trigger a spill"
        );
        assert!(
            !should_spill_cache(floor_20pct + 1, total, recent_seg),
            "just above the 20% floor must NOT trigger a spill"
        );
    }

    #[test]
    fn spill_triggers_below_twice_recent_segment_floor() {
        // A small filesystem where 20% is tiny, but a big recent segment makes
        // 2x-that the dominant floor.
        let total = 10 * 1024 * 1024i64; // 10 MB total (small/test fs)
        let recent_seg = 4 * 1024 * 1024i64; // 4 MB segment
        let twice_seg = recent_seg * 2; // 8 MB — bigger than 20% of 10MB (2MB)
        assert!(
            should_spill_cache(twice_seg - 1, total, recent_seg),
            "just below the 2x-segment floor must trigger a spill"
        );
        assert!(
            !should_spill_cache(twice_seg + 1, total, recent_seg),
            "just above the 2x-segment floor must NOT trigger a spill"
        );
    }

    #[test]
    fn spill_never_triggers_on_nonpositive_total() {
        // A bad/unreadable filesystem size must never spuriously spill.
        assert!(!should_spill_cache(0, 0, 1_000_000));
        assert!(!should_spill_cache(-1, -1, 1_000_000));
    }

    #[test]
    fn spill_does_not_trigger_with_ample_free_space() {
        let total = 100 * 1024 * 1024 * 1024i64;
        let recent_seg = 4 * 1024 * 1024i64;
        // 50% free — nowhere near either floor.
        assert!(!should_spill_cache(total / 2, total, recent_seg));
    }

    #[test]
    fn motion_cache_free_and_total_reads_a_real_temp_dir() {
        // Mirrors archive.rs's below_free_floor_on_real_temp_dir_is_readable —
        // we only assert the syscall succeeds (Some) on Unix; the actual
        // free/total numbers depend on the host and aren't asserted.
        let dir = tempfile::tempdir().expect("tempdir");
        let result = motion_cache_free_and_total(dir.path());
        #[cfg(unix)]
        assert!(result.is_some(), "statvfs should read a real temp dir");
        #[cfg(not(unix))]
        let _ = result; // None on non-Unix is acceptable
    }

    #[test]
    fn motion_cache_free_and_total_missing_path_is_none() {
        let result =
            motion_cache_free_and_total(Path::new("/this/path/does/not/exist/crumb-test-xyz"));
        assert!(result.is_none());
    }

    #[test]
    fn spill_oldest_drains_the_whole_ring_when_idle_and_under_pressure() {
        // Integration of should_spill_cache + the ring-drain logic, using a real
        // temp dir (guaranteed to have SOME free space) with an absurdly high
        // "recent segment size" so should_spill_cache's 2x-segment floor always
        // exceeds real free space, forcing a deterministic spill regardless of
        // the host's actual disk usage.
        let dir = tempfile::tempdir().expect("tempdir");
        let mut buf = MotionBuffer::new(5, 10);
        buf.push_segment(pending(0, 4));
        buf.push_segment(pending(4, 8));
        assert_eq!(buf.pending.len(), 2);

        let huge_recent_segment = i64::MAX / 4; // forces should_spill_cache true on any real fs
        let spilled = spill_oldest_if_under_pressure(dir.path(), &mut buf, huge_recent_segment);

        #[cfg(unix)]
        {
            assert_eq!(
                spilled.len(),
                2,
                "the whole ring must be spilled under pressure"
            );
            assert!(
                buf.pending.is_empty(),
                "the ring must be drained after a spill"
            );
        }
        #[cfg(not(unix))]
        {
            // motion_cache_free_and_total returns None on non-Unix, so no spill
            // occurs and the ring is untouched — both are acceptable here.
            let _ = spilled;
        }
    }

    #[test]
    fn spill_oldest_does_nothing_when_ring_is_empty() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut buf = MotionBuffer::new(5, 10);
        let spilled = spill_oldest_if_under_pressure(dir.path(), &mut buf, i64::MAX / 4);
        assert!(spilled.is_empty());
    }

    #[test]
    fn spill_oldest_does_nothing_outside_idle_state() {
        // Recording/PostBuffer already persist every segment as it arrives, so
        // there is nothing sitting in the ring to spill even under pressure.
        let dir = tempfile::tempdir().expect("tempdir");
        let mut buf = MotionBuffer::new(5, 10);
        buf.apply_signal(&motion_start(0));
        assert!(matches!(buf.state, MotionBufferState::Recording { .. }));
        let spilled = spill_oldest_if_under_pressure(dir.path(), &mut buf, i64::MAX / 4);
        assert!(spilled.is_empty());
    }

    // ── #73: motion state survives an ffmpeg reconnect ─────────────────────────
    //
    // The reconnect path itself (`run`'s outer loop re-invoking
    // `run_ffmpeg_loop` with the CARRIED `MotionBuffer`/`MotionUnion`/
    // `pending_signals`) is not unit-reachable: it needs a live DB pool for
    // storage resolution and a spawnable ffmpeg child before it ever touches
    // the motion state. What IS unit-testable is each property the fix is
    // composed of: (a) the carried state machine keeps an open event alive
    // across an arbitrary gap in segment arrivals (nothing auto-expires it),
    // (b) the carried union still matches the event's STOP after the gap
    // (a FRESH union — the pre-fix behaviour — provably does not), and
    // (c) the R1 cache sweep at the top of the next run spares exactly the
    // carried ring's files (deleting them would fail every later persist of
    // the pre-roll).

    #[test]
    fn carried_buffer_keeps_ongoing_event_persisting_across_reconnect_gap() {
        let mut buf = MotionBuffer::new(5, 10);
        buf.apply_signal(&motion_start(0));
        assert_eq!(buf.push_segment(pending(0, 4)).persist.len(), 1);
        // ... ffmpeg dies here; the worker backs off and reconnects; the
        // buffer is CARRIED as-is (that is the fix) ...
        let d = buf.push_segment(pending(40, 44));
        assert_eq!(
            d.persist.len(),
            1,
            "the event tail after a reconnect gap must keep persisting"
        );
        assert!(d.discard.is_empty());
    }

    #[test]
    fn carried_union_matches_event_stop_after_reconnect_where_fresh_union_cannot() {
        // The carried union closes the event properly...
        let mut carried = MotionUnion::default();
        assert!(carried.fold(&motion_start(0)).is_some());
        // ... reconnect gap ...
        assert!(
            carried.fold(&motion_stop(0, 42)).is_some(),
            "the carried union must emit the synthetic STOP for the ongoing event"
        );
        // ...while a FRESH union (the pre-fix reconnect behaviour) drops the
        // STOP as unmatched — pinning exactly why the state must be carried.
        let mut fresh = MotionUnion::default();
        assert!(
            fresh.fold(&motion_stop(0, 42)).is_none(),
            "a fresh union cannot close an event it never saw open"
        );
    }

    #[test]
    fn ring_entry_dir_check_separates_cache_and_storage_flavors() {
        // #73 flip-guard: the parent-dir check must tell a cache-dir ring
        // entry apart from a storage-dir one exactly, in both directions —
        // this is what prevents a storage-path entry from ever being run
        // through the cache persist's copy-then-delete (which would truncate
        // and then delete an already-indexed segment file).
        let cache_dir = Path::new("/cache/motion/cam-1");
        let storage_dir = Path::new("/data/live/cam-1");
        let cache_seg = PendingSegment {
            path: "/cache/motion/cam-1/20260101T000000Z.mp4".to_owned(),
            start_ts: utc(2026, 1, 1, 0, 0, 0),
            end_ts: utc(2026, 1, 1, 0, 0, 4),
            size_bytes: 1024,
        };
        let storage_seg = PendingSegment {
            path: "/data/live/cam-1/20260101T000000Z.mp4".to_owned(),
            start_ts: utc(2026, 1, 1, 0, 0, 0),
            end_ts: utc(2026, 1, 1, 0, 0, 4),
            size_bytes: 1024,
        };
        assert!(ring_entry_lives_under(&cache_seg, cache_dir));
        assert!(!ring_entry_lives_under(&cache_seg, storage_dir));
        assert!(ring_entry_lives_under(&storage_seg, storage_dir));
        assert!(!ring_entry_lives_under(&storage_seg, cache_dir));
    }

    #[tokio::test]
    async fn r1_sweep_preserves_carried_ring_files_and_removes_stale_ones() {
        let dir = tempfile::tempdir().expect("tempdir");
        let kept_path = dir.path().join("20260101T000000Z.mp4");
        let stale_path = dir.path().join("20260101T000004Z.mp4");
        tokio::fs::write(&kept_path, b"ring-referenced")
            .await
            .expect("write kept");
        tokio::fs::write(&stale_path, b"stale-leftover")
            .await
            .expect("write stale");

        let keep: std::collections::HashSet<PathBuf> = [kept_path.clone()].into_iter().collect();
        clear_dir_contents(dir.path(), &keep).await.expect("sweep");

        assert!(
            tokio::fs::metadata(&kept_path).await.is_ok(),
            "a ring-referenced cache file must survive the R1 sweep"
        );
        assert!(
            tokio::fs::metadata(&stale_path).await.is_err(),
            "a stale leftover file must still be swept"
        );
    }

    #[tokio::test]
    async fn r1_sweep_with_empty_keep_set_clears_everything() {
        // A fresh worker spawn has an empty ring → the sweep must behave
        // exactly like the original R1 (clear everything).
        let dir = tempfile::tempdir().expect("tempdir");
        let a = dir.path().join("20260101T000000Z.mp4");
        let b = dir.path().join("20260101T000004Z.mp4");
        tokio::fs::write(&a, b"x").await.expect("write a");
        tokio::fs::write(&b, b"y").await.expect("write b");

        let keep = std::collections::HashSet::new();
        clear_dir_contents(dir.path(), &keep).await.expect("sweep");

        assert!(tokio::fs::metadata(&a).await.is_err());
        assert!(tokio::fs::metadata(&b).await.is_err());
    }

    // ── segment-receipt watchdog ───────────────────────────────────────────────

    /// The watchdog timeout must be strictly larger than a typical multi-segment
    /// gap so no healthy stream gets evicted.  We require at least 3× the largest
    /// common segment length (30 s) to absorb keyframe-alignment delays.
    #[test]
    fn segment_receipt_timeout_is_generous_multiple_of_segment() {
        // Config default is typically 6 s; the generous value is 90 s = 15×.
        // This test encodes the design intent as a regression guard.
        const {
            assert!(
                SEGMENT_RECEIPT_TIMEOUT_SECS >= 30,
                "watchdog must be >= 30 s (several missed segments) to avoid false evictions"
            )
        }
    }

    /// The watchdog timeout must be finite enough to heal within a few minutes
    /// so a stalled camera does not silently drop recordings for hours (the
    /// pre-fix behaviour: 2+ hours of silent dead recording on Fri Door/Backdoor,
    /// 2026-06-17).
    #[test]
    fn segment_receipt_timeout_heals_within_minutes() {
        const {
            assert!(
                SEGMENT_RECEIPT_TIMEOUT_SECS <= 300,
                "watchdog must trigger within 5 minutes; stalls must not linger for hours"
            )
        }
    }

    /// P0-3: the env-override clamp defaults when unset/unparseable and clamps
    /// out-of-range values into the sane band rather than rejecting them (a
    /// fat-fingered env must never wedge the recorder or defeat the watchdog).
    #[test]
    fn segment_receipt_timeout_clamp_defaults_and_bounds() {
        // Unset / unparseable → the generous default.
        assert_eq!(
            clamp_segment_receipt_timeout_secs(None),
            SEGMENT_RECEIPT_TIMEOUT_SECS
        );
        // In-range passes through.
        assert_eq!(clamp_segment_receipt_timeout_secs(Some(45)), 45);
        // Too small → floored; too large → capped.
        assert_eq!(
            clamp_segment_receipt_timeout_secs(Some(1)),
            MIN_SEGMENT_RECEIPT_TIMEOUT_SECS
        );
        assert_eq!(
            clamp_segment_receipt_timeout_secs(Some(u64::MAX)),
            MAX_SEGMENT_RECEIPT_TIMEOUT_SECS
        );
    }

    /// P0-3: the clamp band and default must stay coherent (MIN ≤ default ≤ MAX)
    /// so the env override can never invert the bounds.
    #[test]
    fn segment_receipt_timeout_bounds_are_coherent() {
        const {
            assert!(MIN_SEGMENT_RECEIPT_TIMEOUT_SECS <= SEGMENT_RECEIPT_TIMEOUT_SECS);
            assert!(SEGMENT_RECEIPT_TIMEOUT_SECS <= MAX_SEGMENT_RECEIPT_TIMEOUT_SECS);
        }
    }

    /// P0-3: the effective watchdog only ever RISES to `2 × GOP` and is never
    /// lowered below the configured baseline — the invariant that makes reading
    /// the shared atomic each select iteration safe (a late probe result can
    /// only push the deadline later, never cause a spurious eviction). Mirrors
    /// the flooring arithmetic in the background probe task.
    #[test]
    fn watchdog_floor_only_raises_never_lowers() {
        let configured = 90u64;
        // Short GOP: 2×GOP below configured → no change.
        let gop = 2.0f64;
        let floor = (gop * 2.0).ceil() as u64;
        assert_eq!(configured.max(floor), configured);
        // Long GOP: 2×GOP above configured → raised to the floor.
        let gop = 60.0f64;
        let floor = (gop * 2.0).ceil() as u64;
        assert_eq!(configured.max(floor), 120);
        // The floor is capped at MAX.
        let gop = 100_000.0f64;
        let floor = (gop * 2.0).ceil() as u64;
        assert_eq!(
            configured.max(floor).min(MAX_SEGMENT_RECEIPT_TIMEOUT_SECS),
            MAX_SEGMENT_RECEIPT_TIMEOUT_SECS
        );
    }

    /// Regression for the gap-#1 silent-reset (issue #71): the segment-receipt
    /// watchdog must fire on a stalled stream EVEN THOUGH the motion-cache
    /// telemetry tick keeps returning from the `select!`. The pre-fix loop
    /// rebuilt `timeout(90s, read)` every iteration, so the 45 s tick reset the
    /// deadline before it could elapse and the watchdog never fired → silent
    /// dead recording on a half-open stream (2026-06-17 incident). This
    /// reproduces `run_ffmpeg_loop`'s arm structure — a never-ready read, a tick
    /// shorter than the watchdog, and the deadline anchored to a FIXED
    /// `last_segment_at` (never bumped, mimicking "no segments arriving") — and
    /// asserts the watchdog still resolves after ticks have fired. On paused
    /// time this is deterministic and instant. The pre-fix structure (a fresh
    /// `timeout` rebuilt each iteration) would loop forever here.
    #[tokio::test]
    async fn watchdog_fires_despite_faster_telemetry_tick() {
        // Scaled down from the real 45 s tick < 90 s watchdog so the test runs
        // in ~120 ms of real time (no `test-util`/paused-clock dependency). The
        // STRUCTURE is the point: the watchdog deadline is anchored to a fixed
        // `last_segment_at` (never bumped here — a stream producing no further
        // segments) while the tick keeps returning from the `select!`. Pre-fix,
        // a per-iteration `timeout(read)` was rebuilt every loop and reset by
        // each tick so it never fired; this loop must still resolve to stalled.
        let timeout = Duration::from_millis(120);
        let tick_period = Duration::from_millis(40);
        assert!(
            tick_period < timeout,
            "tick must be shorter than the watchdog"
        );

        // Anchor fixed at entry and NEVER bumped: a stream that produces no
        // further segment-list lines.
        let last_segment_at = tokio::time::Instant::now();
        let mut tick = tokio::time::interval(tick_period);
        tick.tick().await; // consume the immediate first tick
        let mut ticks = 0u32;

        let stalled = loop {
            tokio::select! {
                biased;
                // Never-ready read stand-in (a silently stalled ffmpeg).
                _ = std::future::pending::<()>() => unreachable!("read never ready"),
                // Watchdog anchored to last_segment_at, NOT rebuilt from now().
                () = tokio::time::sleep_until(last_segment_at + timeout) => break true,
                _ = tick.tick() => { ticks += 1; }
            }
        };

        assert!(stalled, "watchdog must fire on a stalled stream");
        assert!(
            ticks >= 1,
            "telemetry ticks fired before the watchdog but must not reset it"
        );
    }

    // ── redact_rtsp_credentials (#18) ─────────────────────────────────────────

    #[test]
    fn redact_strips_user_pass() {
        assert_eq!(
            redact_rtsp_credentials("rtsp://admin:s3cr3t@10.0.0.1/stream1"),
            "rtsp://***:***@10.0.0.1/stream1"
        );
    }

    #[test]
    fn redact_strips_user_only_no_colon() {
        // Some cameras omit the colon when there is no password.
        assert_eq!(
            redact_rtsp_credentials("rtsp://admin@10.0.0.1/stream"),
            "rtsp://***:***@10.0.0.1/stream"
        );
    }

    #[test]
    fn redact_leaves_url_without_creds_unchanged() {
        let url = "rtsp://10.0.0.1:8554/driveway";
        assert_eq!(redact_rtsp_credentials(url), url);
    }

    #[test]
    fn redact_leaves_non_rtsp_url_unchanged() {
        let url = "http://10.0.0.1:8080/api";
        assert_eq!(redact_rtsp_credentials(url), url);
    }

    #[test]
    fn redact_leaves_relative_name_unchanged() {
        // Relative stream names (no scheme) must not be altered.
        let url = "driveway";
        assert_eq!(redact_rtsp_credentials(url), url);
    }

    #[test]
    fn redact_preserves_path_at_sign() {
        // An `@` in the path component (after the first `/`) must NOT be
        // treated as a credential delimiter.
        let url = "rtsp://10.0.0.1/stream@1";
        assert_eq!(redact_rtsp_credentials(url), url);
    }
}
