// SPDX-License-Identifier: AGPL-3.0-or-later

//! Crumb NVR — recorder process entry point.
//!
//! # Responsibility
//!
//! `main` owns the [`RecorderSupervisor`] which:
//!
//! 1. Initialises the database pool and runs startup reconciliation.
//! 2. Seeds the two named storage rows (idempotent — correctness item 13).
//! 3. Spawns the [`ArchiveScheduler`](archive::ArchiveScheduler) task.
//! 4. Runs the camera sync loop every `CONFIG_POLL_SECONDS`, diffing enabled
//!    DB cameras vs running [`CameraWorker`]s.
//! 5. On SIGTERM / Ctrl-C: cancels all workers and waits for clean shutdown.
//!
//! # Architecture (locked)
//!
//! ```text
//! main
//!  └── RecorderSupervisor (tokio task set)
//!       ├── ArchiveScheduler task (archive.rs)
//!       ├── CameraWorker A
//!       │    ├── recording task  (recording.rs)  <──mpsc── motion task
//!       │    └── motion task     (motion.rs)
//!       └── CameraWorker B …
//! ```
//!
//! Each [`CameraWorker`] owns:
//!
//! * A [`CancellationToken`](tokio_util::sync::CancellationToken) shared
//!   between its two child tasks.
//! * A `tokio::sync::mpsc` sender/receiver pair: `motion.rs` sends
//!   [`MotionSignal`](crumb_common::MotionSignal)s; `recording.rs` receives
//!   them to stamp `has_motion` and drive motion-mode recording.
//!
//! # Change detection (correctness item 14)
//!
//! Before reloading a camera worker the supervisor compares a lightweight
//! hash of the camera config.  Workers are only restarted when the config
//! actually changed, preventing needless ring-buffer destruction.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};
use crumb_common::{
    config::{Config, HwAccel},
    db, logging,
    types::Camera,
};
use deadpool_postgres::Pool;
use tokio::signal;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};
use uuid::Uuid;

/// How often the recorder writes its liveness heartbeat row.
///
/// Chosen well below the API/UI "stale" threshold (15 s warn / 60 s dead) so a
/// healthy recorder always reports a sub-15 s heartbeat age even with one
/// missed tick.
const HEARTBEAT_INTERVAL_SECONDS: u64 = 10;

mod archive;
mod decode_probe;
mod frigate_motion;
mod go2rtc_embed;
mod ha_motion;
mod motion;
mod reconcile;
mod recording;
mod resource_stats;
mod source_health;

// ─── channel types (exported for implementers) ────────────────────────────────

/// Capacity of the per-camera motion-signal channel.
///
/// A small buffer is sufficient: recording.rs drains it on every segment
/// boundary.  Overflow means the camera is flooding events — that's a
/// configuration issue, not a buffering one.
const MOTION_CHANNEL_CAPACITY: usize = 256;

/// Sender half of the per-camera motion signal channel.
///
/// Produced by `CameraWorker::spawn`; owned by the motion task (one clone per
/// enabled source loop).
///
/// Wraps the raw mpsc sender so a full channel can never *silently* corrupt
/// the keep/discard verdict (audit #81). The send must stay non-blocking (a
/// blocking send would stall the frame-diff loop and deadlock ffmpeg —
/// correctness item 5), so on overflow the signal really is lost — but a lost
/// START edge would let a Motion-mode camera discard footage during real
/// motion. The wrapper therefore books the loss per HANDLE in shared state
/// that [`forward_motion_health`] folds into the recording task's fail-open
/// signal: a lost verdict degrades to record-everything (correctness item 19),
/// never to silence. The debt clears on this handle's next ACCEPTED signal
/// **after which the source is genuinely idle** — a completed event
/// (`stopped_at` set) — so recovery is automatic once the channel drains.
/// Clearing on just *any* next accepted signal would be too early: when the
/// LOST edge was a START, the very next accepted signal is that same event's
/// STOP, and ending fail-open at the stop instant would leave the
/// boundary-spanning tail segment and the `motion_post_seconds` post-roll
/// exposed (the recording task's union never saw the event). Coordination
/// boundary (#2/#5): recording.rs treats an unmatched STOP received while
/// healthy as a synthetic post-buffer trigger, which is what makes clearing
/// at the accepted STOP footage-safe.
pub struct MotionTx {
    tx: tokio::sync::mpsc::Sender<crumb_common::MotionSignal>,
    camera_id: Uuid,
    /// This handle's un-resynced-loss flag. Per handle (not shared): each
    /// source loop holds its own clone, and only a signal from the SAME source
    /// re-syncs that source's verdict stream.
    lost: AtomicBool,
    /// Camera-wide loss bookkeeping, shared by every clone.
    shared: Arc<MotionLossShared>,
}

/// Camera-wide bookkeeping for lost motion signals, shared by every clone of
/// one camera's [`MotionTx`] and read by [`forward_motion_health`].
#[derive(Default)]
struct MotionLossShared {
    /// Number of sender handles whose most recent `try_send` failed and which
    /// have not delivered a signal since — each such source's verdict stream
    /// is missing an edge until its next accepted signal re-syncs it.
    lost_handles: AtomicUsize,
    /// Wakes the health forwarder whenever `lost_handles` moves. `notify_one`
    /// stores a permit, so a wake between the forwarder's recompute and its
    /// re-arm is never missed.
    changed: tokio::sync::Notify,
}

impl MotionTx {
    fn new(tx: tokio::sync::mpsc::Sender<crumb_common::MotionSignal>, camera_id: Uuid) -> Self {
        Self {
            tx,
            camera_id,
            lost: AtomicBool::new(false),
            shared: Arc::new(MotionLossShared::default()),
        }
    }

    /// The shared loss state, handed to this camera's [`forward_motion_health`].
    fn loss_state(&self) -> Arc<MotionLossShared> {
        Arc::clone(&self.shared)
    }

    /// Non-blocking send of a motion signal to the recording task.
    ///
    /// On failure (channel full — or closed, i.e. the recording task is gone,
    /// which is an even less trustworthy state) the signal is lost: mark this
    /// handle's debt so the camera fails OPEN until the same handle delivers a
    /// fresh accepted signal AFTER WHICH it is genuinely idle (a completed
    /// event, `stopped_at` set). An accepted START edge does NOT clear the
    /// debt: if the lost edge was itself a START, the union missed the whole
    /// event, and ending fail-open before the event has fully closed (and its
    /// unmatched STOP has reached the recording task, which converts it into a
    /// synthetic post-buffer trigger — the recording.rs half of this fix)
    /// could ring-discard the boundary tail + post-roll. The error is still
    /// returned so callers keep their existing per-drop warning logs.
    pub fn try_send(
        &self,
        signal: crumb_common::MotionSignal,
    ) -> Result<(), tokio::sync::mpsc::error::TrySendError<crumb_common::MotionSignal>> {
        // Whether, after this signal, the source has no open event. Captured
        // before the send moves the signal into the channel.
        let source_idle = signal.stopped_at.is_some();
        match self.tx.try_send(signal) {
            Ok(()) => {
                if source_idle && self.lost.swap(false, Ordering::SeqCst) {
                    // The channel accepted a completed event from this handle:
                    // the source is idle and the recording task's view of it
                    // re-syncs at this edge (an unmatched STOP is a synthetic
                    // post-buffer trigger on the recording side), so the debt
                    // (and with it fail-open) can end.
                    self.shared.lost_handles.fetch_sub(1, Ordering::SeqCst);
                    self.shared.changed.notify_one();
                }
                Ok(())
            }
            Err(e) => {
                if !self.lost.swap(true, Ordering::SeqCst) {
                    // Once per loss episode, not per dropped signal — the
                    // caller already warns on every drop.
                    error!(
                        camera_id = %self.camera_id,
                        "motion signal LOST (channel full/closed); failing open \
                         (recording everything) until this source re-syncs"
                    );
                    self.shared.lost_handles.fetch_add(1, Ordering::SeqCst);
                    self.shared.changed.notify_one();
                }
                Err(e)
            }
        }
    }
}

impl Clone for MotionTx {
    fn clone(&self) -> Self {
        Self {
            tx: self.tx.clone(),
            camera_id: self.camera_id,
            // Loss is per handle: a fresh clone has lost nothing yet.
            lost: AtomicBool::new(false),
            shared: Arc::clone(&self.shared),
        }
    }
}

impl Drop for MotionTx {
    fn drop(&mut self) {
        // A handle dropped mid-debt can never re-sync, so return its debt —
        // otherwise the camera would fail open forever on a vanished handle.
        // A dying source has its own fail-open path (the per-source health
        // watch in motion.rs), which is the correct one from here on.
        if self.lost.load(Ordering::SeqCst) {
            self.shared.lost_handles.fetch_sub(1, Ordering::SeqCst);
            self.shared.changed.notify_one();
        }
    }
}

/// Fold the motion task's health watch AND the motion-channel loss state into
/// the single fail-open bool the recording task reads (audit #81).
///
/// `recording_tx` has exactly ONE writer — this task — so a detector-health
/// flip and a loss flip can never interleave into a stale healthy reading.
/// The recording task fails open (`healthy == false`) whenever the detector
/// itself is unhealthy (motion.rs's aggregator, forwarded from `detector_rx`)
/// OR any sender handle has an un-resynced lost signal. Mirrors the
/// aggregator's teardown rule: publish a final unhealthy so the recording task
/// never trusts a stale healthy reading.
async fn forward_motion_health(
    mut detector_rx: MotionHealthRx,
    recording_tx: MotionHealthTx,
    loss: Arc<MotionLossShared>,
    camera_id: Uuid,
    cancel: CancellationToken,
) {
    loop {
        let lossy = loss.lost_handles.load(Ordering::SeqCst) > 0;
        let healthy = *detector_rx.borrow() && !lossy;
        if *recording_tx.borrow() != healthy {
            if !healthy && lossy {
                // Detector-driven transitions are already logged by motion.rs
                // (RECOVERED / FAIL-OPEN); only the loss-driven one is ours.
                warn!(
                    camera_id = %camera_id,
                    "motion health: FAIL-OPEN (motion signal lost on a full channel; \
                     recording everything until the source re-syncs)"
                );
            }
            // Only errors when the recording task dropped its receiver
            // (worker teardown) — nothing left to protect.
            let _ = recording_tx.send(healthy);
        }
        tokio::select! {
            () = cancel.cancelled() => break,
            res = detector_rx.changed() => {
                if res.is_err() {
                    break; // motion task gone — teardown
                }
            }
            () = loss.changed.notified() => {}
        }
    }
    // Teardown: the recording task must not trust a stale healthy reading
    // (same rule as motion.rs's aggregator).
    let _ = recording_tx.send(false);
}

/// Receiver half of the per-camera motion signal channel.
///
/// Owned by the recording task.
pub type MotionRx = tokio::sync::mpsc::Receiver<crumb_common::MotionSignal>;

/// Sender half of the per-camera motion-detector health signal.
///
/// Owned by the motion task. `true` = the detector is healthy (frames are
/// being analysed normally); `false` = unhealthy (watchdog fired, the motion
/// task died, motion detection is disabled while the policy mode is Motion, or
/// no frame has been analysed yet since task start). The recording task fails
/// OPEN on `false` — a Motion-mode camera persists every segment (as if
/// Continuous) whenever health is not confirmed, so a broken detector can
/// never silently drop footage the operator thinks is being kept.
pub type MotionHealthTx = tokio::sync::watch::Sender<bool>;

/// Receiver half of the per-camera motion-detector health signal.
///
/// Owned by the recording task.
pub type MotionHealthRx = tokio::sync::watch::Receiver<bool>;

// ─── camera config hash (change detection) ────────────────────────────────────

/// A cheap fingerprint of a [`Camera`]'s configuration for change detection.
///
/// We compare this value before and after each poll cycle.  If the fingerprint
/// is unchanged we skip the worker reload (correctness item 14).
#[derive(Debug, PartialEq, Eq, Clone)]
struct CameraFingerprint {
    /// The EFFECTIVE recording policy id (own → group's → default), as resolved by
    /// the DB join. Using the effective id (not the camera's direct `policy_id`,
    /// which is now nullable for inherited cameras) means reassigning a camera to
    /// a different group/policy — or editing a GROUP's policy — flips this and
    /// triggers a worker reload on the next poll.
    policy_id: Uuid,
    main_url: String,
    sub_url: Option<String>,
    enabled: bool,
    onvif_motion: bool,
    // Motion sources: the ADDITIVE set (migration 0049) + pixel algorithm.
    // Toggling which sources are enabled — or the pixel detector — must respawn
    // the worker so `motion::run` starts/stops the right per-source loops. The
    // deprecated `motion_source` is kept (harmless, never changes) alongside.
    motion_source: String,
    motion_pixel_enabled: bool,
    motion_frigate_enabled: bool,
    motion_ha_enabled: bool,
    motion_algorithm: String,
    // Effective motion-decode backend (server_settings.motion_hwaccel + vaapi
    // device, admin-editable; empty ⇒ env default). Folded into the per-camera
    // fingerprint so a GLOBAL decode-mode change rolls a worker respawn one
    // camera at a time on the next poll (no simultaneous fleet-wide recording gap).
    motion_hwaccel: String,
    motion_vaapi_device: String,
    // Stringify motion_mask for equality; jsonb is order-agnostic so we
    // normalise via serde_json's canonical display.
    motion_mask_json: String,
    // The policy FIELDS that change worker behavior — so editing a camera's
    // policy in place (same policy_id, e.g. mode/sensitivity/stream/audio)
    // triggers a worker reload on the next poll. Retention/archive are excluded
    // (handled by the sweep/scheduler, no worker reload needed).
    policy_fp: String,
}

impl CameraFingerprint {
    fn from_camera(c: &Camera, motion_hwaccel: &str, motion_vaapi_device: &str) -> Self {
        let motion_mask_json = c
            .motion_mask
            .as_ref()
            .map(|v| v.to_string())
            .unwrap_or_default();
        let p = &c.policy;
        let policy_fp = format!(
            // NOTE: live_storage_id / archive_storage_id are part of this
            // fingerprint deliberately (D1). A running recording worker resolves
            // its output disk ONCE at spawn from the policy's storage id (see
            // recording.rs `run_ffmpeg_loop`). If an operator repoints a policy's
            // live_storage_id to a different disk, the worker must respawn so it
            // re-resolves and starts writing to the NEW disk — otherwise it keeps
            // writing to the OLD disk, silently orphaning footage at the source.
            "{:?}|{:?}|{}|{:?}|{:?}|{}|{}|{}|{:?}|{:?}",
            p.mode,
            p.record_stream,
            p.record_audio,
            p.motion_sensitivity,
            p.motion_threshold,
            p.motion_pre_seconds,
            p.motion_post_seconds,
            p.motion_keyframes_only,
            p.live_storage_id,
            p.archive_storage_id,
        );
        Self {
            // EFFECTIVE policy id (resolved own → group → default), so a change of
            // group/policy assignment registers as a config change.
            policy_id: c.policy.id,
            main_url: c.main_url.clone(),
            sub_url: c.sub_url.clone(),
            enabled: c.enabled,
            onvif_motion: c.onvif_motion,
            motion_source: c.motion_source.clone(),
            motion_pixel_enabled: c.motion_pixel_enabled,
            motion_frigate_enabled: c.motion_frigate_enabled,
            motion_ha_enabled: c.motion_ha_enabled,
            motion_algorithm: c.motion_algorithm.clone(),
            motion_hwaccel: motion_hwaccel.to_owned(),
            motion_vaapi_device: motion_vaapi_device.to_owned(),
            motion_mask_json,
            policy_fp,
        }
    }
}

// ─── CameraWorker ─────────────────────────────────────────────────────────────

/// A running pair of tasks (recording + motion) for one camera.
///
/// The supervisor inserts one [`CameraWorker`] per enabled camera into
/// [`RecorderSupervisor::workers`].
pub struct CameraWorker {
    pub camera_id: Uuid,
    /// Shared shutdown signal for the recording and motion tasks.
    pub cancel: CancellationToken,
    /// Join handles — awaited on worker shutdown.
    recording_handle: tokio::task::JoinHandle<()>,
    motion_handle: tokio::task::JoinHandle<()>,
    /// Fingerprint at spawn time — used for cheap change detection.
    fingerprint: CameraFingerprint,
}

impl CameraWorker {
    /// Spawn the recording and motion tasks for `camera`.
    ///
    /// The two tasks share `cancel`; calling `cancel.cancel()` causes both to
    /// wind down promptly.
    pub fn spawn(camera: Camera, pool: Pool, config: Config) -> Self {
        let cancel = CancellationToken::new();
        // `config` here is the EFFECTIVE config the supervisor built for this spawn
        // (decode backend already resolved from server_settings → env). The
        // fingerprint must use the SAME values so the next poll's comparison matches.
        let fingerprint = CameraFingerprint::from_camera(
            &camera,
            config.motion_hwaccel.as_str(),
            &config.motion_vaapi_device,
        );

        let (raw_motion_tx, motion_rx) = tokio::sync::mpsc::channel(MOTION_CHANNEL_CAPACITY);
        let motion_tx = MotionTx::new(raw_motion_tx, camera.id);

        // Health channel: starts `false` (unhealthy / unconfirmed) until the
        // motion task's first successful frame analysis flips it `true`. This
        // means a freshly-spawned Motion-mode worker fails OPEN (persists every
        // segment) until the detector proves itself healthy, rather than
        // trusting an unproven detector from the first segment.
        let (health_tx, health_rx): (MotionHealthTx, MotionHealthRx) =
            tokio::sync::watch::channel(false);

        // Interposed fail-open rail (audit #81): the recording task reads a
        // SECOND watch that folds the detector health above together with the
        // motion channel's loss state, written only by `forward_motion_health`.
        // Same initial `false` — the worker starts fail-open either way.
        let (rec_health_tx, rec_health_rx): (MotionHealthTx, MotionHealthRx) =
            tokio::sync::watch::channel(false);
        tokio::spawn(forward_motion_health(
            health_rx,
            rec_health_tx,
            motion_tx.loss_state(),
            camera.id,
            cancel.clone(),
        ));

        // Clone the cancellation token for each child task.
        let rec_cancel = cancel.clone();
        let mot_cancel = cancel.clone();

        let rec_camera = camera.clone();
        let rec_pool = pool.clone();
        let rec_config = config.clone();
        let recording_handle = tokio::spawn(async move {
            recording::run(
                rec_camera,
                rec_pool,
                rec_config,
                motion_rx,
                rec_health_rx,
                rec_cancel,
            )
            .await;
        });

        let mot_camera = camera.clone();
        let mot_pool = pool.clone();
        let motion_handle = tokio::spawn(async move {
            motion::run(
                mot_camera, mot_pool, config, motion_tx, health_tx, mot_cancel,
            )
            .await;
        });

        CameraWorker {
            camera_id: camera.id,
            cancel,
            recording_handle,
            motion_handle,
            fingerprint,
        }
    }

    /// True while both child tasks are still running.
    ///
    /// `recording::run` / `motion::run` loop internally and only return on
    /// cancellation, so a finished handle during normal operation means the task
    /// ended unexpectedly — in practice a panic (panics unwind and fail just that
    /// task's future; the process survives because `panic = "abort"` is
    /// forbidden). The supervisor uses this to resurrect a dead worker on the
    /// next poll instead of leaving that camera dark until the whole process
    /// restarts (audit 2026-07-05).
    pub fn is_alive(&self) -> bool {
        !self.recording_handle.is_finished() && !self.motion_handle.is_finished()
    }

    /// Signal cancellation and wait for both tasks to finish.
    pub async fn stop(self) {
        self.cancel.cancel();
        // Correctness item 6: bound shutdown in time. Capture abort handles
        // first, then join with a timeout; if a task is wedged (e.g. a stuck
        // ffmpeg kill or a stalled DB write) abort it so shutdown can never hang.
        let rec_abort = self.recording_handle.abort_handle();
        let mot_abort = self.motion_handle.abort_handle();
        let camera_id = self.camera_id;
        let joined = tokio::time::timeout(std::time::Duration::from_secs(8), async move {
            let _ = tokio::join!(self.recording_handle, self.motion_handle);
        })
        .await;
        if joined.is_err() {
            warn!(camera_id = %camera_id, "worker shutdown timed out; aborting tasks");
            rec_abort.abort();
            mot_abort.abort();
        }
        info!(camera_id = %camera_id, "camera worker stopped");
    }
}

// ─── RecorderSupervisor ───────────────────────────────────────────────────────

/// Owns all running [`CameraWorker`]s and the archive scheduler task.
struct RecorderSupervisor {
    pool: Pool,
    config: Config,
    /// camera_id → worker
    workers: HashMap<Uuid, CameraWorker>,
    /// Global shutdown signal — propagated to all workers and the scheduler.
    shutdown: CancellationToken,
    archive_handle: Option<tokio::task::JoinHandle<()>>,
    heartbeat_handle: Option<tokio::task::JoinHandle<()>>,
    resource_handle: Option<tokio::task::JoinHandle<()>>,
    /// The "Change storage" drain worker (claims + runs storage_migrations).
    migration_handle: Option<tokio::task::JoinHandle<()>>,
    /// Periodic reaper of orphaned anonymous per-camera COW policy forks.
    reaper_handle: Option<tokio::task::JoinHandle<()>>,
    /// Live count of running camera workers, published for the heartbeat task.
    /// Updated at the end of every `sync_cameras` cycle.
    active_cameras: Arc<AtomicU32>,
}

impl RecorderSupervisor {
    fn new(pool: Pool, config: Config, shutdown: CancellationToken) -> Self {
        Self {
            pool,
            config,
            workers: HashMap::new(),
            shutdown,
            archive_handle: None,
            heartbeat_handle: None,
            resource_handle: None,
            migration_handle: None,
            reaper_handle: None,
            active_cameras: Arc::new(AtomicU32::new(0)),
        }
    }

    /// Run startup reconciliation, then enter the camera sync loop.
    ///
    /// This method drives the supervisor until `shutdown` is cancelled.
    async fn run(&mut self) -> Result<()> {
        // 1. Startup reconciliation.
        //
        // Phase 1 (inline, fast): loads the segment index from the DB into
        // memory.  Completes in milliseconds — camera workers are spawned as
        // soon as this returns.
        //
        // Phase 2 (background): walks storage, removes dangling rows, and
        // indexes orphan files.  Runs concurrently with camera workers so a
        // large archive never delays recording.
        //
        // SKIP_RECONCILE=1 skips Phase 2 only.  Phase 1 always runs (the
        // in-memory segment index is needed for correctness).
        let skip_reconcile = std::env::var("SKIP_RECONCILE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);

        // Phase 1 is now just a connectivity check (the boot load is paginated in
        // Phase 2 — audit P2 #12). A failure means the DB is unreachable; log and
        // continue (the recorder still starts; reconcile retries are a future
        // boot's concern).
        if let Err(e) = reconcile::load_segment_index(&self.pool).await {
            error!(error = %e, "reconcile phase 1 (connectivity) failed; continuing");
        }

        if skip_reconcile {
            warn!("SKIP_RECONCILE set — skipping reconcile phase 2 (background orphan pass)");
        } else {
            // Spawn Phase 2; it runs concurrently with camera workers. It
            // keyset-paginates the segments table itself, so no large index is
            // passed in. The returned handle is intentionally not stored — the
            // task is self-contained and stops cleanly when `shutdown` cancels.
            let _phase2_handle = reconcile::spawn_background(
                self.pool.clone(),
                self.config.clone(),
                self.shutdown.clone(),
            );
            info!("reconcile phase 2 spawned in background; camera workers starting now");
        }

        // 2. Seed the storage rows (idempotent).
        self.seed_storages().await?;

        // 2b. Ensure the motion_grid table exists (for the live motion tuner).
        if let Err(e) = db::ensure_motion_grid_table(&self.pool).await {
            error!(error = %e, "ensure_motion_grid_table failed; motion tuner grid disabled");
        }

        // 2c. Ensure segments.motion_score exists (timeline intensity histogram).
        if let Err(e) = db::ensure_segments_motion_score_column(&self.pool).await {
            error!(error = %e, "ensure_segments_motion_score_column failed; timeline intensity disabled");
        }

        // 2d. Ensure motion_threshold is a fraction (0..1), not legacy basis points,
        //     so it shares ONE unit with motion_score / the effective floor.
        if let Err(e) = db::ensure_motion_threshold_fraction(&self.pool).await {
            error!(error = %e, "ensure_motion_threshold_fraction failed; manual thresholds may be mis-scaled");
        }

        // 2e. Ensure the per-camera resource-stats table exists (CPU / mem / GPU
        //     sampler target). Non-fatal — without it the sampler's upserts fail
        //     and /stats/cameras reports zeros, but recording is unaffected.
        if let Err(e) = db::ensure_camera_resource_stats(&self.pool).await {
            error!(error = %e, "ensure_camera_resource_stats failed; per-camera CPU/mem/GPU stats disabled");
        }

        // 2f. Ensure the per-camera size-cap columns exist (live_max_bytes /
        //     archive_max_bytes) so the commercial-VMS-style "time OR size, whichever
        //     hits first" eviction works. Non-fatal — without them the size
        //     sweeps read NULL (no cap) and only time-based retention applies.
        if let Err(e) = db::ensure_policy_size_cap_columns(&self.pool).await {
            error!(error = %e, "ensure_policy_size_cap_columns failed; size caps disabled");
        }

        // 2f-bis. Ensure the per-policy ADVANCED storage columns exist
        //     (live_min_free_pct / live_min_free_bytes / live_spill_low_water_bytes)
        //     so configurable free-space headroom + the batched spill buffer work.
        //     Non-fatal — without them the sweeps read NULL = use the global env
        //     floor with no hysteresis (today's behaviour).
        if let Err(e) = db::ensure_policy_advanced_storage_columns(&self.pool).await {
            error!(error = %e, "ensure_policy_advanced_storage_columns failed; per-policy headroom/spill disabled");
        }

        // 2g. Ensure the per-camera motion-source / motion-algorithm columns
        //     exist (pluggable-motion Stage 4). Non-fatal — without them every
        //     camera reads the defaults ('pixel' / 'census'), i.e. current
        //     behaviour.
        if let Err(e) = db::ensure_motion_source_columns(&self.pool).await {
            error!(error = %e, "ensure_motion_source_columns failed; per-camera motion source/algorithm disabled");
        }

        // 2g. Ensure the per-camera `camera_type` column exists (admin-console
        //     glyph only; nullable, NULL ⇒ 'other'). Non-fatal — the recorder
        //     never reads it, but it shares CAMERA_SELECT_SQL which now selects
        //     the column, so whichever process boots first must add it.
        if let Err(e) = db::ensure_camera_type_column(&self.pool).await {
            error!(error = %e, "ensure_camera_type_column failed; per-camera type icon disabled");
        }

        // 2g·5. Ensure the per-camera ownership + ONVIF columns exist (migration
        //       0012 backstop). run_migrations (fatal, in main) already applies
        //       them, so this is belt-and-suspenders + parity with the API path.
        if let Err(e) = db::ensure_camera_ownership_columns(&self.pool).await {
            error!(error = %e, "ensure_camera_ownership_columns failed; served_by/onvif/source_camera_name columns may be absent");
        }

        // 2g². Ensure the per-camera + per-storage `icon` OVERRIDE columns exist
        //      (admin-console glyph only; nullable). The recorder never reads them,
        //      but CAMERA_SELECT_SQL + every storage SELECT now reference them, so
        //      whichever process boots first MUST add them or those queries fail.
        if let Err(e) = db::ensure_cameras_icon_column(&self.pool).await {
            error!(error = %e, "ensure_cameras_icon_column failed; camera icon override disabled");
        }
        if let Err(e) = db::ensure_storages_icon_column(&self.pool).await {
            error!(error = %e, "ensure_storages_icon_column failed; storage icon override disabled");
        }
        if let Err(e) = db::ensure_cameras_motion_grid_columns(&self.pool).await {
            error!(error = %e, "ensure_cameras_motion_grid_columns failed; per-camera tuner grid-size disabled");
        }
        // 2h. Ensure the storage_migrations job table (the guarded "Change storage"
        //     drain). Non-fatal — without it the drain worker just finds nothing.
        if let Err(e) = db::ensure_storage_migrations_table(&self.pool).await {
            error!(error = %e, "ensure_storage_migrations_table failed; Change-storage drain disabled");
        }
        // 2h'. Composite index that keeps the Change-storage drain's per-batch SELECT
        //      a range scan rather than a full table scan. Non-fatal — without it the
        //      drain still works, just slowly on a large segments table.
        if let Err(e) = db::ensure_segments_storage_index(&self.pool).await {
            error!(error = %e, "ensure_segments_storage_index failed; Change-storage drain SELECT may full-scan");
        }
        // 2i. Ensure the Frigate/MQTT settings row (seeded from env on first
        //     create). Non-fatal — Frigate motion sources fall back to pixel.
        if let Err(e) = db::ensure_frigate_config_table(&self.pool).await {
            error!(error = %e, "ensure_frigate_config_table failed; Frigate config hot-reload disabled");
        }

        // 2g'. Enforce the DB-level storage invariant: segments.storage_id must be
        //      ON DELETE RESTRICT so a referenced storage can't be deleted out from
        //      under footage (A2). Idempotent — swaps the FK only if not already
        //      RESTRICT. Non-fatal: without it the admin delete_storage guard still
        //      protects, but the DB backstop is absent until this succeeds.
        if let Err(e) = db::ensure_segments_storage_fk_restrict(&self.pool).await {
            error!(error = %e, "ensure_segments_storage_fk_restrict failed; segments.storage_id FK backstop not enforced this run");
        }

        // 2g. Introduce named, reusable recording policies + camera groups (with
        //     inheritance). Additive/idempotent: existing cameras keep their own
        //     policy_id so the COALESCE join is unchanged until a group is made.
        //     Non-fatal — without it, named policies / groups are unavailable but
        //     per-camera recording is unaffected.
        if let Err(e) = db::ensure_named_policies_and_groups(&self.pool).await {
            error!(error = %e, "ensure_named_policies_and_groups failed; named policies + camera groups disabled");
        }

        // 2j. Probe + publish the container's accelerator capabilities
        //     (/dev/dri/renderD*, /dev/nvidia*, ffmpeg -hwaccels) for the admin
        //     decode-status panel. Telemetry only, best-effort, once per boot.
        decode_probe::publish(&self.pool).await;

        // 3. Spawn the long-lived service tasks (archive scheduler, heartbeat,
        //    resource sampler, migration worker, policy reaper). Each spawn is a
        //    method so the poll-loop watchdog (`respawn_dead_services`, audit
        //    #75) can respawn one that panicked, exactly like camera workers.
        self.spawn_archive_scheduler();
        self.spawn_heartbeat();
        self.spawn_resource_sampler();
        self.spawn_migration_worker();
        self.spawn_policy_reaper();

        // 4. Initial camera sync.
        self.sync_cameras().await;

        // 5. Config-poll loop.
        let poll_interval = tokio::time::Duration::from_secs(self.config.config_poll_seconds);
        let mut interval = tokio::time::interval(poll_interval);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    self.respawn_dead_services();
                    self.sync_cameras().await;
                }
                () = self.shutdown.cancelled() => {
                    info!("shutdown signal received; stopping all workers");
                    break;
                }
            }
        }

        // 6. Stop all workers.
        self.stop_all_workers().await;

        // 7. Stop the archive scheduler (bounded — correctness item 6).
        if let Some(h) = self.archive_handle.take() {
            let abort = h.abort_handle();
            if tokio::time::timeout(std::time::Duration::from_secs(8), h)
                .await
                .is_err()
            {
                warn!("archive scheduler shutdown timed out; aborting");
                abort.abort();
            }
        }

        // 8. Stop the heartbeat task (bounded).
        if let Some(h) = self.heartbeat_handle.take() {
            let abort = h.abort_handle();
            if tokio::time::timeout(std::time::Duration::from_secs(4), h)
                .await
                .is_err()
            {
                warn!("heartbeat task shutdown timed out; aborting");
                abort.abort();
            }
        }

        // 9. Stop the resource sampler task (bounded).
        if let Some(h) = self.resource_handle.take() {
            let abort = h.abort_handle();
            if tokio::time::timeout(std::time::Duration::from_secs(4), h)
                .await
                .is_err()
            {
                warn!("resource sampler shutdown timed out; aborting");
                abort.abort();
            }
        }

        // 10. Stop the "Change storage" migration worker (#9/#10).
        //
        // Without a bounded join here the migration worker is simply DROPPED when
        // the supervisor exits. Dropping a `JoinHandle` does NOT cancel the task
        // (the tokio runtime keeps it alive until the runtime shuts down). On a
        // `SIGTERM + docker restart` the runtime tears down promptly, which aborts
        // the worker mid-batch — and the next boot's `reset_stale_migrations` then
        // resets the row to `pending`, silently re-running the drain as if the
        // cancel never happened. By explicitly joining here (with a timeout) we let
        // the in-progress batch finish cleanly; the drain checks the `cancelled`
        // status at the next batch boundary and exits on its own.
        //
        // The shutdown `CancellationToken` was already cancelled above (step 5 via
        // `break`), so the migration worker's idle-poll `select!` fires promptly.
        // The bounded join allows a generous window for a final in-flight batch to
        // complete (copy + fsync + flip is I/O-bound; 60 s is enough for a
        // MIGRATION_BATCH=256 batch at ~10 files/s on a spinning destination).
        if let Some(h) = self.migration_handle.take() {
            let abort = h.abort_handle();
            if tokio::time::timeout(std::time::Duration::from_secs(60), h)
                .await
                .is_err()
            {
                warn!(
                    "migration worker shutdown timed out after 60s; \
                     aborting (in-progress batch will be reset to 'pending' on next boot)"
                );
                abort.abort();
            } else {
                info!("migration worker stopped cleanly");
            }
        }

        Ok(())
    }

    /// Spawn the archive scheduler task.
    fn spawn_archive_scheduler(&mut self) {
        let sched_pool = self.pool.clone();
        let sched_config = self.config.clone();
        let sched_cancel = self.shutdown.clone();
        self.archive_handle = Some(tokio::spawn(async move {
            archive::run_scheduler(sched_pool, sched_config, sched_cancel).await;
        }));
    }

    /// Spawn the liveness heartbeat task.
    fn spawn_heartbeat(&mut self) {
        let hb_pool = self.pool.clone();
        let hb_cancel = self.shutdown.clone();
        let hb_active = Arc::clone(&self.active_cameras);
        self.heartbeat_handle = Some(tokio::spawn(async move {
            run_heartbeat(hb_pool, hb_active, hb_cancel).await;
        }));
    }

    /// Spawn the per-camera resource sampler (CPU / mem / GPU). Reads /proc
    /// + nvidia-smi out-of-band; never touches the recording/motion path.
    fn spawn_resource_sampler(&mut self) {
        self.resource_handle = Some(resource_stats::spawn(
            self.pool.clone(),
            self.shutdown.clone(),
        ));
    }

    /// Spawn the "Change storage" drain worker — claims pending
    /// storage_migrations and relocates footage under ARCHIVE_GUARD so it
    /// never races archiving/eviction. Idle-polls; cheap when no migration.
    fn spawn_migration_worker(&mut self) {
        let mig_pool = self.pool.clone();
        let mig_cancel = self.shutdown.clone();
        self.migration_handle = Some(tokio::spawn(async move {
            run_migration_worker(mig_pool, mig_cancel).await;
        }));
    }

    /// Spawn the policy-fork reaper — periodically deletes orphaned anonymous
    /// per-camera COW policy rows no camera/group references (the "separate
    /// vacuum" the config-routes COW design refers to). Cheap; hourly.
    fn spawn_policy_reaper(&mut self) {
        let reap_pool = self.pool.clone();
        let reap_cancel = self.shutdown.clone();
        self.reaper_handle = Some(tokio::spawn(async move {
            run_policy_reaper(reap_pool, reap_cancel).await;
        }));
    }

    /// Watchdog for the long-lived service tasks (audit #75). Each of them
    /// loops until `shutdown` fires, so a finished handle outside shutdown
    /// means the task died unexpectedly — in practice a panic (panics unwind
    /// and fail just that task's future; the process survives because
    /// `panic = "abort"` is forbidden). Without this check a panicked archive
    /// scheduler silently stops retention/eviction until the whole recorder
    /// restarts. Mirrors the camera-worker resurrection in `sync_cameras`
    /// (audit 2026-07-05); called from the same poll loop.
    fn respawn_dead_services(&mut self) {
        if self.shutdown.is_cancelled() {
            // Shutting down — finished service tasks are expected, and the
            // shutdown path below joins them; never respawn into a teardown.
            return;
        }
        if service_task_died(&self.archive_handle) {
            error!("archive scheduler task ended unexpectedly (likely a panic); respawning");
            self.spawn_archive_scheduler();
        }
        if service_task_died(&self.heartbeat_handle) {
            error!("heartbeat task ended unexpectedly (likely a panic); respawning");
            self.spawn_heartbeat();
        }
        if service_task_died(&self.resource_handle) {
            error!("resource sampler task ended unexpectedly (likely a panic); respawning");
            self.spawn_resource_sampler();
        }
        if service_task_died(&self.migration_handle) {
            error!("migration worker task ended unexpectedly (likely a panic); respawning");
            // The dead incarnation's claimed migration (if any) is left with
            // status='running'; the respawned worker's idle poll re-runs the
            // boot path's guaranteed-stale reset (see `run_migration_worker`)
            // so the drain resumes instead of freezing at N%.
            self.spawn_migration_worker();
        }
        if service_task_died(&self.reaper_handle) {
            error!("policy reaper task ended unexpectedly (likely a panic); respawning");
            self.spawn_policy_reaper();
        }
    }

    /// Diff enabled DB cameras vs running workers; start new ones, stop
    /// removed ones, restart changed ones.
    ///
    /// Change detection uses [`CameraFingerprint`] — no churn if nothing
    /// changed (correctness item 14).
    async fn sync_cameras(&mut self) {
        let cameras = match db::list_enabled_cameras(&self.pool).await {
            Ok(c) => c,
            Err(e) => {
                error!(error = %e, "failed to list enabled cameras; skipping sync");
                return;
            }
        };

        // Resolve the effective motion-decode backend (admin-editable via
        // server_settings; empty ⇒ env default). Read every poll so an admin change
        // hot-reloads: folding it into each fingerprint makes a changed value flip
        // every camera's fingerprint, rolling a one-at-a-time worker respawn below.
        let (eff_hwaccel, eff_vaapi_device) = self.effective_hwaccel().await;

        // Build a set of enabled camera IDs for removal detection.
        let enabled_ids: std::collections::HashSet<Uuid> = cameras.iter().map(|c| c.id).collect();

        // Stop workers for cameras no longer enabled.
        let to_remove: Vec<Uuid> = self
            .workers
            .keys()
            .filter(|id| !enabled_ids.contains(*id))
            .copied()
            .collect();

        for id in to_remove {
            if let Some(worker) = self.workers.remove(&id) {
                info!(camera_id = %id, "stopping worker for removed/disabled camera");
                worker.stop().await;
                // Drop the decode-status telemetry row so the admin panel never
                // shows a stale backend for a camera that isn't decoding at all.
                // Best-effort; camera DELETEs also cascade it via the FK.
                if let Err(e) = db::delete_camera_decode_status(&self.pool, id).await {
                    warn!(camera_id = %id, error = %e, "failed to delete decode-status row");
                }
                // Same for the motion-cache ring telemetry (migration 0039) —
                // a stopped/disabled camera has no worker left to report a
                // live ring occupancy, so drop the stale row.
                if let Err(e) = db::delete_camera_motion_cache_status(&self.pool, id).await {
                    warn!(camera_id = %id, error = %e, "failed to delete motion-cache status row");
                }
            }
        }

        // Start or reload workers for each enabled camera.
        for camera in cameras {
            let new_fp =
                CameraFingerprint::from_camera(&camera, eff_hwaccel.as_str(), &eff_vaapi_device);
            let camera_id = camera.id;

            if let Some(existing) = self.workers.get(&camera_id) {
                if existing.fingerprint == new_fp && existing.is_alive() {
                    // No change and both tasks healthy — leave the worker running.
                    continue;
                }
                if existing.fingerprint == new_fp {
                    // Fingerprint unchanged but a task ended unexpectedly (a panic
                    // fails one task's future without killing the process).
                    // Resurrect it so the camera doesn't stay dark until the whole
                    // recorder restarts. (audit 2026-07-05)
                    warn!(
                        camera_id = %camera_id,
                        "camera worker task ended unexpectedly (likely a panic); restarting"
                    );
                } else {
                    // Config changed — stop the old worker, fall through to start.
                    info!(camera_id = %camera_id, "config changed; restarting worker");
                }
                if let Some(worker) = self.workers.remove(&camera_id) {
                    worker.stop().await;
                }
            }

            info!(
                camera_id  = %camera_id,
                camera_name = %camera.name,
                hwaccel = %eff_hwaccel.as_str(),
                "starting camera worker"
            );
            // Effective per-spawn config: override the decode backend with the
            // resolved (server_settings → env) value so every camera follows the
            // admin-selected mode. Other config is the shared process config.
            let mut cfg = self.config.clone();
            cfg.motion_hwaccel = eff_hwaccel;
            cfg.motion_vaapi_device = eff_vaapi_device.clone();
            let worker = CameraWorker::spawn(camera, self.pool.clone(), cfg);
            self.workers.insert(camera_id, worker);
        }

        // Publish the live worker count for the heartbeat task.
        self.active_cameras
            .store(self.workers.len() as u32, Ordering::Relaxed);
    }

    /// Resolve the effective motion-decode backend for this poll.
    ///
    /// Priority: the admin-editable `server_settings.motion_hwaccel` (+ vaapi
    /// device) when set, else the env-configured default ([`Config::motion_hwaccel`]
    /// / [`Config::motion_vaapi_device`]). An empty or unreadable DB value means
    /// "inherit the env default" — never a hard failure, so a transient DB hiccup
    /// can't strand the motion workers.
    async fn effective_hwaccel(&self) -> (HwAccel, String) {
        match db::get_server_settings(&self.pool).await {
            Ok(Some(s)) => {
                let mode = HwAccel::from_setting(&s.motion_hwaccel, self.config.motion_hwaccel);
                let device = if s.motion_vaapi_device.trim().is_empty() {
                    self.config.motion_vaapi_device.clone()
                } else {
                    s.motion_vaapi_device.clone()
                };
                (mode, device)
            }
            Ok(None) => (
                self.config.motion_hwaccel,
                self.config.motion_vaapi_device.clone(),
            ),
            Err(e) => {
                warn!(error = %e, "could not read server_settings for hwaccel; using env default");
                (
                    self.config.motion_hwaccel,
                    self.config.motion_vaapi_device.clone(),
                )
            }
        }
    }

    /// Cancel and join all running workers, concurrently.
    ///
    /// Each `CameraWorker::stop` is individually bounded (8 s join + abort),
    /// so stopping concurrently bounds the WHOLE fleet's shutdown at ~one
    /// worker's budget instead of N × 8 s of sequential joins — the total
    /// shutdown must fit inside compose's `stop_grace_period` or Docker
    /// SIGKILLs the recorder mid-teardown (audit #84).
    async fn stop_all_workers(&mut self) {
        let mut stops = tokio::task::JoinSet::new();
        for (_, worker) in self.workers.drain() {
            stops.spawn(worker.stop());
        }
        while stops.join_next().await.is_some() {}
    }

    /// Ensure the two named storage rows exist (idempotent via `ON CONFLICT`).
    ///
    /// This is a startup convenience so the service can self-bootstrap without
    /// requiring a separate `seed` run for storage rows.  Camera rows still
    /// require the `seed` binary.
    async fn seed_storages(&self) -> Result<()> {
        db::upsert_storage(
            &self.pool,
            &self.config.live_storage_name,
            &self.config.live_storage_path,
        )
        .await
        .context("upserting live storage")?;

        db::upsert_storage(
            &self.pool,
            &self.config.archive_storage_name,
            &self.config.archive_storage_path,
        )
        .await
        .context("upserting archive storage")?;

        info!(
            live    = %self.config.live_storage_name,
            archive = %self.config.archive_storage_name,
            "storage rows seeded"
        );
        Ok(())
    }
}

/// True when a stored long-lived service handle has ended and must be
/// respawned (see [`RecorderSupervisor::respawn_dead_services`]). `None`
/// (never spawned / already taken for shutdown) is NOT "died" — there is
/// nothing to resurrect.
fn service_task_died(handle: &Option<tokio::task::JoinHandle<()>>) -> bool {
    handle.as_ref().is_some_and(|h| h.is_finished())
}

// ─── heartbeat task ───────────────────────────────────────────────────────────

/// Periodically write the recorder liveness heartbeat row until `cancel` fires.
///
/// A failed write is logged and retried on the next tick — a transient DB blip
/// must not kill the loop (which would make a healthy recorder look dead).
/// `active_cameras` is read from the shared counter the supervisor refreshes on
/// every sync cycle.  The first `interval.tick()` resolves immediately, so a
/// heartbeat is written the moment the recorder finishes start-up.
async fn run_heartbeat(pool: Pool, active_cameras: Arc<AtomicU32>, cancel: CancellationToken) {
    // pid fits in i32 on every platform we target (Linux pids ≤ 2^22).
    #[allow(clippy::cast_possible_wrap)]
    let pid = std::process::id() as i32;
    let mut interval =
        tokio::time::interval(tokio::time::Duration::from_secs(HEARTBEAT_INTERVAL_SECONDS));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = interval.tick() => {
                #[allow(clippy::cast_possible_wrap)]
                let active = active_cameras.load(Ordering::Relaxed) as i32;
                if let Err(e) = db::write_recorder_heartbeat(&pool, pid, active).await {
                    warn!(error = %e, "failed to write recorder heartbeat; will retry");
                }
            }
            () = cancel.cancelled() => {
                info!("heartbeat task shutting down");
                break;
            }
        }
    }
}

// ─── "Change storage" drain worker ────────────────────────────────────────────

/// How often the drain worker polls for a pending migration when idle.
const MIGRATION_POLL_SECONDS: u64 = 10;

/// How often the policy-fork reaper sweeps for orphaned anonymous per-camera COW
/// policy rows (hourly — orphans are rare and non-urgent; the sweep is one cheap
/// guarded DELETE).
const POLICY_REAP_SECONDS: u64 = 3600;

/// Claim and run pending `storage_migrations` until `cancel` fires.
///
/// One migration at a time (serialised by the claim). Each run drains under
/// `ARCHIVE_GUARD` (per batch) so footage moves never race archiving/eviction.
/// A failed run is recorded as `failed` with the error; the loop continues so a
/// later migration isn't blocked. Cheap when idle (a single indexed query per
/// poll, plus the stale-`running` self-heal below — one no-op UPDATE against a
/// tiny table).
///
/// Self-heals a migration orphaned by a PANICKED predecessor: the #75 watchdog
/// respawns this worker, and the idle poll re-runs the boot path's
/// guaranteed-stale reset (`reset_stale_migrations`) so the drain the dead
/// incarnation had claimed resumes instead of freezing at `running` forever.
async fn run_migration_worker(pool: Pool, cancel: CancellationToken) {
    loop {
        // Claim before sleeping so a freshly-enqueued migration starts promptly on
        // the next poll.
        match db::claim_pending_migration(&pool).await {
            Ok(Some(mig)) => {
                info!(
                    migration = %mig.id,
                    from = %mig.from_storage_id, to = %mig.to_storage_id,
                    total = mig.total_segments,
                    "Change-storage drain: starting"
                );
                match archive::run_storage_migration(&pool, &mig).await {
                    Ok(()) => {
                        // Only mark 'done' if the row is STILL 'running'. A concurrent
                        // operator cancel sets status='cancelled' and the drain returns
                        // Ok(()) early — we must NOT overwrite that with 'done'.
                        match db::set_migration_status_if(&pool, mig.id, "done", "running", None)
                            .await
                        {
                            Ok(true) => info!(migration = %mig.id, "Change-storage drain: done"),
                            Ok(false) => {
                                info!(migration = %mig.id, "Change-storage drain: ended but status was no longer 'running' (cancelled?) — leaving as-is")
                            }
                            Err(e) => {
                                warn!(migration = %mig.id, error = %e, "failed to mark migration done")
                            }
                        }
                    }
                    Err(e) => {
                        let msg = e.to_string();
                        error!(migration = %mig.id, error = %msg, "Change-storage drain: failed");
                        let _ = db::set_migration_status(&pool, mig.id, "failed", Some(&msg)).await;
                    }
                }
                // Loop straight back to pick up any other pending migration.
            }
            Ok(None) => {
                // Nothing 'pending' — but a row stuck in 'running' can still
                // exist: the #75 watchdog respawns this worker after a panic,
                // and the migration the dead incarnation had claimed stays
                // 'running' forever (this loop only claims 'pending'), freezing
                // the operator's storage repoint at N%. This worker is the ONLY
                // claimer (we hold the recorder singleton advisory lock, R7)
                // and it is idle right now, so any 'running' row here is
                // guaranteed stale. Reuse the boot path's reset verbatim — its
                // 2-minute freshness guard only bounds how quickly a
                // freshly-orphaned row is recovered (a later idle poll gets it).
                match db::reset_stale_migrations(&pool).await {
                    Ok(0) => {}
                    Ok(n) => {
                        info!(
                            reset = n,
                            "migration worker: reset stale 'running' migration rows to \
                             'pending' (previous worker incarnation died mid-drain); resuming"
                        );
                        // Claim the reset row promptly instead of idling —
                        // unless shutdown fired meanwhile (never start a fresh
                        // drain into a teardown).
                        if cancel.is_cancelled() {
                            info!("migration worker shutting down");
                            break;
                        }
                        continue;
                    }
                    Err(e) => {
                        warn!(error = %e, "migration worker: reset_stale_migrations failed; will retry next poll");
                    }
                }
                tokio::select! {
                    () = tokio::time::sleep(tokio::time::Duration::from_secs(MIGRATION_POLL_SECONDS)) => {}
                    () = cancel.cancelled() => { info!("migration worker shutting down"); break; }
                }
            }
            Err(e) => {
                warn!(error = %e, "claim_pending_migration failed; backing off");
                tokio::select! {
                    () = tokio::time::sleep(tokio::time::Duration::from_secs(30)) => {}
                    () = cancel.cancelled() => { info!("migration worker shutting down"); break; }
                }
            }
        }
        if cancel.is_cancelled() {
            break;
        }
    }
}

/// Periodically reap orphaned anonymous per-camera COW policy forks — the
/// "separate vacuum" the config-routes COW design refers to. The first
/// `interval.tick()` resolves immediately, so a sweep runs at startup, then every
/// [`POLICY_REAP_SECONDS`]. Each sweep is one guarded, idempotent DELETE; errors
/// are logged and retried on the next tick — never fatal.
async fn run_policy_reaper(pool: Pool, cancel: CancellationToken) {
    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(POLICY_REAP_SECONDS));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = interval.tick() => {
                match db::reap_orphan_policy_forks(&pool).await {
                    Ok(0) => {}
                    Ok(n) => info!(reaped = n, "policy reaper: removed orphaned per-camera policy forks"),
                    Err(e) => warn!(error = %e, "policy reaper: sweep failed; will retry next tick"),
                }
            }
            () = cancel.cancelled() => { info!("policy reaper shutting down"); break; }
        }
    }
}

// ─── entry point ──────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    logging::init();

    let config = Config::from_env().context("reading configuration")?;
    info!("Crumb recorder starting");

    // Global shutdown token — created before anything spawns so early children
    // (the embedded go2rtc below) share the same cancellation signal.
    let shutdown = CancellationToken::new();

    // Embedded go2rtc restreamer (spawned EARLY, before any DB wait — it has no
    // DB dependency, so live restreaming comes up even while Postgres is still
    // starting). Missing binary/config or GO2RTC_EMBEDDED=false ⇒ one loud
    // warning and the recorder proceeds; recording is never hostage to the
    // restreamer. See go2rtc_embed.rs.
    let go2rtc_handle = go2rtc_embed::spawn(shutdown.clone());

    // Initialise the global NVDEC semaphore before any camera workers start.
    // Must be called exactly once (OnceLock — subsequent calls are no-ops).
    motion::init_nvdec_semaphore(config.max_gpu_decode_sessions);

    let pool = db::build_pool(&config.database_url, config.db_pool_size)
        .context("building database pool")?;

    // Verify the DB is reachable before proceeding.
    {
        let client = pool.get().await.context("initial DB connection check")?;
        client
            .execute("SELECT 1", &[])
            .await
            .context("initial DB ping")?;
        info!("database connection verified");
    }

    // ── Schema bootstrap (O1 / §6.1) ─────────────────────────────────────────
    //
    // run_migrations is the canonical schema owner: it embeds all *.sql files
    // and applies any that have not yet been recorded in schema_migrations.
    // For the recorder this is FATAL — we cannot safely record against a schema
    // we cannot verify.
    db::run_migrations(&pool).await.context("run_migrations")?;
    info!("schema migrations verified / applied");

    // Idempotent self-heal backstops (run after migrations so the tables exist).
    if let Err(e) = db::ensure_segments_indexes(&pool).await {
        error!(error = %e, "ensure_segments_indexes failed; unique/covering indexes may be absent");
    }
    if let Err(e) = db::ensure_server_settings_table(&pool).await {
        error!(error = %e, "ensure_server_settings_table failed; server_settings singleton may be absent");
    }

    // SINGLE-WRITER GUARD (audit P2 #14): take a session-scoped pg_advisory_lock
    // on a dedicated connection. Two recorders against the same DB + storage tree
    // race the move/delete ordering and corrupt the index, so a second instance
    // must refuse to start. The lock auto-releases when this process dies (the DB
    // drops the session), so a crashed recorder never wedges its successor. The
    // guard is bound for the whole of `main` — dropping it releases the lock.
    let _singleton_lock = match db::acquire_recorder_singleton_lock(&config.database_url).await {
        Ok(Some(guard)) => {
            info!("acquired recorder single-writer advisory lock");
            guard
        }
        Ok(None) => {
            error!(
                "another recorder already holds the single-writer advisory lock; \
                 refusing to start (two recorders would corrupt the segment index). \
                 Stop the other instance (or wait for a stale session to drop) and retry."
            );
            anyhow::bail!("recorder single-writer lock is held by another instance");
        }
        Err(e) => {
            // A connection failure here is fatal — we cannot guarantee single-writer.
            error!(error = %e, "failed to acquire recorder single-writer lock");
            return Err(e.context("acquiring recorder single-writer lock"));
        }
    };

    // Reset any storage-migration rows stuck in 'running' (process died
    // mid-drain). R7: this MUST run AFTER the singleton lock is held, not
    // before — a second recorder booting concurrently with a first (which is
    // legitimately mid-migration-drain) would otherwise reset that first
    // recorder's genuinely-`running` row to `pending` before losing the
    // singleton-lock race, corrupting the migration's in-progress state. Once
    // we hold the singleton lock we know we are the only recorder process, so
    // any `running` row we see here is guaranteed stale (left behind by a
    // process that died, not a live sibling).
    match db::reset_stale_migrations(&pool).await {
        Ok(0) => {}
        Ok(n) => info!(
            reset = n,
            "reset stale storage-migration rows from 'running' to 'pending'"
        ),
        Err(e) => {
            warn!(error = %e, "reset_stale_migrations failed; stuck migrations may need manual reset")
        }
    }

    // Intercept SIGTERM and Ctrl-C, then cancel the global token.
    {
        let shutdown_signal = shutdown.clone();
        tokio::spawn(async move {
            let ctrl_c = async {
                if let Err(e) = signal::ctrl_c().await {
                    error!(error = %e, "failed to listen for Ctrl-C; disabling that shutdown path");
                    std::future::pending::<()>().await;
                }
            };

            #[cfg(unix)]
            let sigterm = async {
                match signal::unix::signal(signal::unix::SignalKind::terminate()) {
                    Ok(mut s) => {
                        s.recv().await;
                    }
                    Err(e) => {
                        error!(error = %e, "failed to install SIGTERM handler; disabling that shutdown path");
                        std::future::pending::<()>().await;
                    }
                }
            };

            // On non-Unix (e.g. Windows CI) there is no SIGTERM; only honour
            // Ctrl-C.
            #[cfg(not(unix))]
            let sigterm = std::future::pending::<()>();

            tokio::select! {
                () = ctrl_c  => { warn!("received Ctrl-C"); }
                () = sigterm => { warn!("received SIGTERM"); }
            }

            shutdown_signal.cancel();
        });
    }

    let mut supervisor = RecorderSupervisor::new(pool, config, shutdown);
    supervisor.run().await?;

    // Stop the embedded go2rtc supervisor (it SIGTERMs the child, SIGKILL after
    // a bound). The shutdown token is already cancelled when run() returns, so
    // this join is prompt; the timeout is a belt-and-suspenders bound. On any
    // earlier error path `kill_on_drop` reaps the child at runtime teardown.
    if let Some(h) = go2rtc_handle {
        if tokio::time::timeout(std::time::Duration::from_secs(8), h)
            .await
            .is_err()
        {
            warn!("embedded go2rtc supervisor shutdown timed out");
        }
    }

    info!("Crumb recorder shut down cleanly");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{forward_motion_health, service_task_died, CameraFingerprint, MotionTx};
    use chrono::Utc;
    use crumb_common::types::{
        Camera, MotionSensitivity, RecordStream, RecordingMode, RecordingPolicy,
    };
    use std::sync::atomic::Ordering;
    use tokio_util::sync::CancellationToken;
    use uuid::Uuid;

    /// Build a minimal default policy for fingerprint tests.
    fn mk_policy() -> RecordingPolicy {
        RecordingPolicy {
            id: Uuid::nil(),
            name: Some("Default".to_owned()),
            is_default: true,
            origin: "operator".to_owned(),
            mode: RecordingMode::Continuous,
            live_storage_id: None,
            live_retention_hours: 48,
            archive_enabled: false,
            archive_storage_id: None,
            archive_schedule: None,
            archive_retention_hours: None,
            live_max_bytes: None,
            archive_max_bytes: None,
            live_min_free_pct: None,
            live_min_free_bytes: None,
            live_spill_low_water_bytes: None,
            max_retention_days: None,
            motion_pre_seconds: 5,
            motion_post_seconds: 10,
            motion_sensitivity: MotionSensitivity::Dynamic,
            motion_threshold: None,
            motion_keyframes_only: false,
            record_stream: RecordStream::Main,
            record_audio: true,
        }
    }

    /// Build a minimal camera with the given policy for fingerprint tests.
    fn mk_camera(policy: RecordingPolicy) -> Camera {
        Camera {
            id: Uuid::nil(),
            name: "Cam".to_owned(),
            enabled: true,
            go2rtc_name: "cam".to_owned(),
            main_url: "cam".to_owned(),
            sub_url: None,
            source_url: None,
            source_sub_url: None,
            served_by: "crumb".to_owned(),
            source_camera_name: None,
            onvif_host: None,
            onvif_port: None,
            onvif_user: None,
            onvif_password: None,
            ptz_control_enabled: true,
            policy_id: Some(policy.id),
            group_id: None,
            policy,
            motion_mask: None,
            onvif_motion: false,
            motion_source: "pixel".to_owned(),
            motion_pixel_enabled: true,
            motion_frigate_enabled: false,
            motion_ha_enabled: false,
            motion_algorithm: "census".to_owned(),
            camera_type: None,
            icon: None,
            motion_grid_cols: None,
            motion_grid_rows: None,
            created_at: Utc::now(),
        }
    }

    /// D1 regression: repointing a policy's `live_storage_id` to a different disk
    /// MUST change the fingerprint so the supervisor respawns the worker (which
    /// re-resolves its output disk). Without this, the running worker keeps writing
    /// to the OLD disk and silently orphans footage at the source.
    #[test]
    fn fingerprint_differs_when_live_storage_id_changes() {
        let cam_a = mk_camera(mk_policy());

        let mut policy_b = mk_policy();
        policy_b.live_storage_id = Some(Uuid::from_u128(0x1234));
        let cam_b = mk_camera(policy_b);

        let fp_a = CameraFingerprint::from_camera(&cam_a, "auto", "");
        let fp_b = CameraFingerprint::from_camera(&cam_b, "auto", "");

        assert_ne!(
            fp_a, fp_b,
            "fingerprint must differ when live_storage_id changes (else no worker respawn → footage orphaned on the old disk)"
        );
    }

    /// A change to the global motion-decode backend (server_settings.motion_hwaccel,
    /// folded into the fingerprint) MUST flip it so the supervisor respawns the
    /// worker with the new ffmpeg decode flags. Same for the vaapi device.
    #[test]
    fn fingerprint_differs_when_hwaccel_changes() {
        let cam = mk_camera(mk_policy());
        assert_ne!(
            CameraFingerprint::from_camera(&cam, "cpu", ""),
            CameraFingerprint::from_camera(&cam, "vaapi", ""),
            "fingerprint must differ when the decode backend changes (else no respawn)"
        );
        assert_ne!(
            CameraFingerprint::from_camera(&cam, "vaapi", "/dev/dri/renderD128"),
            CameraFingerprint::from_camera(&cam, "vaapi", "/dev/dri/renderD129"),
            "fingerprint must differ when the vaapi device changes"
        );
        assert_eq!(
            CameraFingerprint::from_camera(&cam, "cpu", ""),
            CameraFingerprint::from_camera(&cam, "cpu", ""),
            "fingerprint must be stable when the decode backend is unchanged"
        );
    }

    /// Toggling which ADDITIVE motion sources are enabled MUST flip the
    /// fingerprint. The admin edits these booleans (not the deprecated
    /// `motion_source`), so without this the supervisor never respawns the worker
    /// and enabling/disabling a source silently does nothing until a restart.
    #[test]
    fn fingerprint_differs_when_motion_source_toggled() {
        let cam_pixel = mk_camera(mk_policy());
        let mut cam_ha = mk_camera(mk_policy());
        cam_ha.motion_ha_enabled = true; // pixel + HA
        assert_ne!(
            CameraFingerprint::from_camera(&cam_pixel, "auto", ""),
            CameraFingerprint::from_camera(&cam_ha, "auto", ""),
            "fingerprint must differ when the HA source is toggled (else no respawn)"
        );
        let mut cam_frigate = mk_camera(mk_policy());
        cam_frigate.motion_frigate_enabled = true;
        assert_ne!(
            CameraFingerprint::from_camera(&cam_pixel, "auto", ""),
            CameraFingerprint::from_camera(&cam_frigate, "auto", ""),
            "fingerprint must differ when the Frigate source is toggled"
        );
    }

    /// Companion: repointing `archive_storage_id` must also flip the fingerprint
    /// so the worker re-resolves its archive destination.
    #[test]
    fn fingerprint_differs_when_archive_storage_id_changes() {
        let cam_a = mk_camera(mk_policy());

        let mut policy_b = mk_policy();
        policy_b.archive_storage_id = Some(Uuid::from_u128(0xabcd));
        let cam_b = mk_camera(policy_b);

        assert_ne!(
            CameraFingerprint::from_camera(&cam_a, "auto", ""),
            CameraFingerprint::from_camera(&cam_b, "auto", ""),
            "fingerprint must differ when archive_storage_id changes"
        );
    }

    /// Negative control: an unrelated, non-fingerprinted change (created_at) must
    /// NOT flip the fingerprint — otherwise every poll would churn workers.
    #[test]
    fn fingerprint_stable_when_storage_unchanged() {
        let cam_a = mk_camera(mk_policy());
        let mut cam_b = mk_camera(mk_policy());
        cam_b.created_at = cam_a.created_at + chrono::Duration::seconds(1);

        assert_eq!(
            CameraFingerprint::from_camera(&cam_a, "auto", ""),
            CameraFingerprint::from_camera(&cam_b, "auto", ""),
            "fingerprint must be stable when no fingerprinted field changes"
        );
    }

    // ── service-task watchdog (audit #75) ─────────────────────────────────────

    /// The watchdog's liveness predicate: a panicked service task must read as
    /// died (so `respawn_dead_services` resurrects it); a live task and a
    /// never-spawned/taken-for-shutdown slot must not.
    #[tokio::test]
    async fn service_watchdog_detects_dead_task() {
        // A task that panics: its JoinHandle finishes with a JoinError.
        let mut dead = tokio::spawn(async { panic!("service task panicked (test)") });
        let joined = (&mut dead).await;
        assert!(joined.is_err(), "panicked task must join with an error");
        assert!(
            service_task_died(&Some(dead)),
            "a panicked service task must be detected as died"
        );

        // A live task must NOT read as died.
        let alive = Some(tokio::spawn(std::future::pending::<()>()));
        assert!(
            !service_task_died(&alive),
            "a running service task must not be respawned"
        );
        if let Some(h) = alive {
            h.abort();
        }

        // Never spawned / already taken for shutdown: nothing to resurrect.
        assert!(!service_task_died(&None));
    }

    // ── motion-signal loss → fail-open (audit #81) ────────────────────────────

    /// Minimal START-edge signal (event still open) for the loss-tracking tests.
    fn mk_signal() -> crumb_common::MotionSignal {
        crumb_common::MotionSignal {
            camera_id: Uuid::nil(),
            started_at: Utc::now(),
            stopped_at: None,
            peak_score: 0.5,
            bbox: None,
        }
    }

    /// Minimal STOP-edge signal (completed event — the source is idle after it).
    fn mk_stop_signal() -> crumb_common::MotionSignal {
        crumb_common::MotionSignal {
            camera_id: Uuid::nil(),
            started_at: Utc::now(),
            stopped_at: Some(Utc::now()),
            peak_score: 0.5,
            bbox: None,
        }
    }

    /// A signal dropped on a full channel must mark the loss (the camera owes
    /// a fail-open). The debt must NOT clear on the next accepted signal if
    /// that signal leaves an event open (a START edge — the lost edge may have
    /// been the START of an event the union never saw, audit #81); it clears
    /// only on an accepted signal after which the source is genuinely idle
    /// (a completed event, `stopped_at` set).
    #[tokio::test]
    async fn motion_tx_overflow_marks_loss_until_resync() {
        let (raw, mut rx) = tokio::sync::mpsc::channel(1);
        let tx = MotionTx::new(raw, Uuid::nil());
        let loss = tx.loss_state();

        assert!(tx.try_send(mk_signal()).is_ok());
        assert_eq!(loss.lost_handles.load(Ordering::SeqCst), 0);

        // Channel full → the signal is lost → the handle owes a re-sync.
        assert!(tx.try_send(mk_signal()).is_err());
        assert_eq!(loss.lost_handles.load(Ordering::SeqCst), 1);
        // Repeated drops in the same episode must not double-count.
        assert!(tx.try_send(mk_signal()).is_err());
        assert_eq!(loss.lost_handles.load(Ordering::SeqCst), 1);

        // Drain, then an accepted START edge: the source now has an OPEN
        // event, so the debt (and fail-open) must be HELD, not cleared —
        // clearing here could end fail-open at the lost event's own STOP and
        // expose the boundary tail + post-roll.
        assert!(rx.recv().await.is_some());
        assert!(tx.try_send(mk_signal()).is_ok());
        assert_eq!(loss.lost_handles.load(Ordering::SeqCst), 1);

        // Drain, then an accepted COMPLETED event (stop edge): the source is
        // genuinely idle — debt cleared, fail-open may end.
        assert!(rx.recv().await.is_some());
        assert!(tx.try_send(mk_stop_signal()).is_ok());
        assert_eq!(loss.lost_handles.load(Ordering::SeqCst), 0);
    }

    /// Loss is tracked per handle — another source's accepted signal must NOT
    /// clear a debt it didn't incur — and a handle dropped mid-debt returns it
    /// (a dead source's fail-open is motion.rs's per-source health watch).
    #[tokio::test]
    async fn motion_tx_loss_is_per_handle_and_returned_on_drop() {
        let (raw, mut rx) = tokio::sync::mpsc::channel(1);
        let a = MotionTx::new(raw, Uuid::nil());
        let b = a.clone();
        let loss = a.loss_state();

        assert!(a.try_send(mk_signal()).is_ok()); // fill the only slot
        assert!(b.try_send(mk_signal()).is_err()); // b loses a signal
        assert_eq!(loss.lost_handles.load(Ordering::SeqCst), 1);

        // a's accepted send (after a drain) must not clear b's debt — not even
        // a stop edge, which WOULD clear a's own debt if a had one.
        assert!(rx.recv().await.is_some());
        assert!(a.try_send(mk_stop_signal()).is_ok());
        assert_eq!(loss.lost_handles.load(Ordering::SeqCst), 1);

        // Dropping the indebted handle hands the debt back.
        drop(b);
        assert_eq!(loss.lost_handles.load(Ordering::SeqCst), 0);
    }

    /// Await the forwarded health watch reaching `want`, with a hard timeout so
    /// a broken forwarder fails the test instead of hanging it.
    async fn wait_for_health(rx: &mut super::MotionHealthRx, want: bool) {
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            rx.wait_for(|&v| v == want),
        )
        .await
        .expect("timed out waiting for the forwarded health value")
        .expect("health watch sender dropped");
    }

    /// End-to-end: the recording-side health watch must go false while a lost
    /// signal is un-resynced, and recover once the same handle delivers a fresh
    /// edge — even though the detector stayed healthy throughout.
    #[tokio::test]
    async fn health_forwarder_folds_signal_loss_into_fail_open() {
        let (detector_tx, detector_rx) = tokio::sync::watch::channel(false);
        let (recording_tx, mut recording_rx) = tokio::sync::watch::channel(false);
        let (raw, mut rx) = tokio::sync::mpsc::channel(1);
        let tx = MotionTx::new(raw, Uuid::nil());
        let cancel = CancellationToken::new();
        tokio::spawn(forward_motion_health(
            detector_rx,
            recording_tx,
            tx.loss_state(),
            Uuid::nil(),
            cancel.clone(),
        ));

        // Detector healthy, nothing lost → forwarded healthy.
        detector_tx.send(true).unwrap();
        wait_for_health(&mut recording_rx, true).await;

        // Overflow: fill the one slot, then lose a signal → fail-open.
        assert!(tx.try_send(mk_signal()).is_ok());
        assert!(tx.try_send(mk_signal()).is_err());
        wait_for_health(&mut recording_rx, false).await;

        // Drain + an accepted COMPLETED event (source idle after it) →
        // re-synced → healthy again. (An accepted START edge would hold the
        // debt — see motion_tx_overflow_marks_loss_until_resync.)
        assert!(rx.recv().await.is_some());
        assert!(tx.try_send(mk_stop_signal()).is_ok());
        wait_for_health(&mut recording_rx, true).await;

        cancel.cancel();
    }
}
