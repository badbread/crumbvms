// SPDX-License-Identifier: AGPL-3.0-or-later

//! Archive scheduler and archive move logic.
//!
//! # Responsibility
//!
//! [`run_scheduler`] is a long-running tokio task that:
//!
//! 1. Every tick (60 s by default; overridable via `ARCHIVE_TICK_SECONDS`),
//!    runs **live retention** for cameras where `archive_enabled = false`
//!    (correctness item 7 — archive-enabled cameras are excluded here;
//!    the archiver owns their deletion).
//! 2. For each camera with `archive_enabled = true`, evaluates whether its
//!    `archive_schedule` cron is due (catch-up semantics: an occurrence that
//!    fell inside a slow/straddled tick window still fires).  When due, runs
//!    [`archive_camera`] then [`archive_retention_sweep`].  The cron-archive
//!    work of one tick shares a wall-time budget (issue #80); leftover backlog
//!    is continued on the NEXT tick without waiting for the next cron fire.
//! 3. Stops cleanly when the [`CancellationToken`] is cancelled.
//!
//! # Archive move ordering (correctness item 8)
//!
//! The move sequence is strictly:
//!
//! ```text
//! 1. tokio::fs::copy(src, dst)               — destination file written
//! 2. verify(dst)                              — dst size == segment.size_bytes
//! 3. db::update_segment_archive(…)           — update storage_id, stage, path
//! 4. tokio::fs::remove_file(src)             — source deleted
//! ```
//!
//! A crash at any step leaves the system recoverable: either the source copy
//! is still indexed (a crash before step 3 leaves an unindexed dst copy that
//! the next archive run simply overwrites), or the archive copy is indexed (a
//! crash before step 4 leaves a stray source copy on the live disk — see the
//! step-4 note in [`move_segment_to_archive`]) — never a missing file with a
//! stale row pointing at it.
//!
//! # Retention delete ordering (correctness item 10)
//!
//! ```text
//! 1. tokio::fs::remove_file(path)            — file gone from disk
//! 2. db::delete_segment_row(id)              — row removed only on fs success
//! ```
//!
//! # PHASE-2 grooming seam
//!
//! A `// PHASE-2 GROOMING SEAM` comment marks the point between the copy step
//! and the verify/update/delete steps in [`archive_camera`].  In Phase 2 a
//! grooming pass (re-encode to lower fps) can be inserted there; the copy
//! destination is the groomed output, and the rest of the pipeline is unchanged.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use chrono::{DateTime, Duration, Utc};
use crumb_common::{
    config::Config,
    db,
    types::{Camera, RecordingPolicy},
    Segment, SegmentStage, Storage, StorageMigration,
};
use deadpool_postgres::Pool;
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

// ─── free-space floor (audit P1 #7 / GAP 5) ──────────────────────────────────

/// Minimum free fraction of the live storage filesystem below which eviction
/// fires regardless of the byte budget. The byte-cap and the physical disk are
/// independent failure domains; if the disk fills before the cap triggers (or
/// the cap is mis-set — prod was ~333GB over its interpreted budget), ffmpeg
/// hits ENOSPC and backoff-loops recording NOTHING. This floor is the safety
/// valve wired to the PHYSICAL disk. Overridable via `MIN_FREE_FRACTION`.
const DEFAULT_MIN_FREE_FRACTION: f64 = 0.05; // 5%

/// Absolute free-bytes floor (bytes) — eviction fires if free drops below this
/// even when the fractional floor is satisfied (a huge disk's 5% may still be a
/// lot, but we also never want to dip under a hard 50GB headroom). Overridable
/// via `MIN_FREE_BYTES`.
const DEFAULT_MIN_FREE_BYTES: i64 = 50 * 1024 * 1024 * 1024; // 50 GiB

/// How many segments the size-eviction sweep pulls per tick (the oldest prefix).
/// The sweep consumes only the oldest segments needed to get back under cap /
/// above the free floor; if still over after this many, the next tick re-queries.
/// Bounds the per-tick query + I/O (audit P1 #9: stop pulling 162k rows + a disk
/// sort every 60s) and smooths the live→archive drain.
const EVICTION_BATCH_LIMIT: i64 = 2_000;

/// How many segments the absolute max-retention sweep deletes per tick (the
/// oldest prefix past the age cap). Bounds the initial delete storm when an
/// operator first sets (or shortens) `max_retention_days` below the age of
/// existing footage — the cap converges over a few ticks instead of deleting a
/// huge backlog in one pass. Same rationale as [`EVICTION_BATCH_LIMIT`].
const MAX_RETENTION_BATCH_LIMIT: i64 = 2_000;

/// Upper bound on rows ONE archive run's eligibility query pulls (the oldest
/// prefix). The #80 backlog continuation re-runs [`archive_camera`] every tick
/// until the catch-up drains — but an UNBOUNDED listing re-fetched the entire
/// eligible set (a 300k-row / ~70MB `Vec` on a large catch-up) once per 60s
/// tick even though the wall-time budget only processes ~1-2k of them. Sized
/// to a generous multiple of one tick's realistic throughput (same rationale
/// as [`EVICTION_BATCH_LIMIT`]); a listing that FILLS the limit is treated as
/// pending backlog even when fully processed, so the next tick re-queries and
/// the continuation semantics are unchanged.
const ARCHIVE_LIST_LIMIT: i64 = 5_000;

/// Process-wide guard ensuring archive operations NEVER run concurrently.
///
/// Today they already can't: the scheduler runs ONE tick at a time and processes
/// the cron-archive loop + the size-eviction sweep sequentially, and the recorder
/// holds a single-writer `pg_advisory_lock` so a second process can't exist. This
/// is belt-and-suspenders — an in-process serialization point that keeps the
/// "no two archive jobs overlap" invariant true even if the per-camera archive
/// loop is ever parallelized or a manual "archive now" trigger is added. It's an
/// in-process `Mutex` (not a pg lock) because cross-process is already covered by
/// the single-writer lock. Held only at the top-level archive entry points
/// (`archive_camera` — per bounded batch, see issue #80 —
/// `policy_size_eviction_sweep`, `max_retention_sweep`, and the migration
/// drain's bulk flip) — never nested — so it cannot deadlock.
static ARCHIVE_GUARD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// How many segments one guarded archive batch moves before [`ARCHIVE_GUARD`]
/// is released and re-acquired (issue #80). Releasing between batches lets any
/// concurrent guard-taker (e.g. a "Change storage" drain's bulk flip) interleave
/// instead of waiting behind an entire catch-up backlog. Small enough that a
/// batch of large segments on a spinning archive disk stays in the seconds
/// range; the wall-time budget below bounds the run regardless.
const ARCHIVE_MOVE_BATCH: usize = 64;

/// Default wall-time budget (seconds) shared by ALL cron-archive work in ONE
/// scheduler tick (issue #80). A single archive run used to process the whole
/// backlog while holding [`ARCHIVE_GUARD`] and the scheduler tick — on a large
/// catch-up (first enable of archiving, or days of downtime) that starved live
/// retention and the free-space floor for hours. The budget bounds how long a
/// tick spends moving segments; whatever remains is logged as deferred and the
/// per-camera tracker's `backlog_pending` flag makes the NEXT tick continue it
/// without waiting for the next cron fire. Overridable via
/// `ARCHIVE_TICK_BUDGET_SECONDS`.
const DEFAULT_ARCHIVE_TICK_BUDGET_SECS: u64 = 30;

/// Read `ARCHIVE_TICK_BUDGET_SECONDS` from the env, falling back to
/// [`DEFAULT_ARCHIVE_TICK_BUDGET_SECS`]. Parsed per tick (cheap, ~once/60s).
fn archive_tick_budget() -> std::time::Duration {
    let secs = std::env::var("ARCHIVE_TICK_BUDGET_SECONDS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|s| *s > 0)
        .unwrap_or(DEFAULT_ARCHIVE_TICK_BUDGET_SECS);
    std::time::Duration::from_secs(secs)
}

/// Read `MIN_FREE_FRACTION` / `MIN_FREE_BYTES` from the env, falling back to the
/// defaults. Parsed per call (cheap; the sweep runs ~once/60s).
fn min_free_thresholds() -> (f64, i64) {
    let frac = std::env::var("MIN_FREE_FRACTION")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|f| (0.0..1.0).contains(f))
        .unwrap_or(DEFAULT_MIN_FREE_FRACTION);
    let bytes = std::env::var("MIN_FREE_BYTES")
        .ok()
        .and_then(|v| v.parse::<i64>().ok())
        .filter(|b| *b >= 0)
        .unwrap_or(DEFAULT_MIN_FREE_BYTES);
    (frac, bytes)
}

/// Free + total bytes on the filesystem containing `path`, via `statvfs(2)`.
///
/// Returns `None` when the path does not exist or the syscall fails (e.g. the
/// storage is unmounted) — the caller then SKIPS the free-space floor for this
/// tick rather than acting on a bad reading. Mirrors the API's `statvfs` helper;
/// works on read-only bind mounts. `None` on non-Unix (CI cross-checks).
fn fs_free_and_total(path: &str) -> Option<(i64, i64)> {
    #[cfg(unix)]
    {
        use std::ffi::CString;
        let c_path = CString::new(path.as_bytes()).ok()?;
        // SAFETY: `buf` is value-initialised to zero before the call; `c_path`
        // is a valid NUL-terminated C string for the lifetime of the call.
        let mut buf = unsafe { std::mem::zeroed::<libc::statvfs>() };
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &raw mut buf) };
        if rc != 0 {
            return None;
        }
        // Use f_bavail (blocks available to a NON-privileged writer), NOT
        // f_bfree (total free blocks, which includes the ext4 root reserve — 5%
        // by default). The recorder runs as a non-root uid, so on a normally
        // provisioned ext4 volume f_bfree never reaches 0 and the ENOSPC safety
        // valve could never fire, letting the disk fill until writes failed
        // (issue #72). f_frsize is the POSIX fundamental block size that
        // f_bavail/f_blocks are counted in (f_bsize is the "preferred" I/O size,
        // not the count unit).
        #[allow(clippy::cast_lossless)]
        let free = (buf.f_bavail as u64).saturating_mul(buf.f_frsize as u64);
        #[allow(clippy::cast_lossless)]
        let total = (buf.f_blocks as u64).saturating_mul(buf.f_frsize as u64);
        Some((i64::try_from(free).ok()?, i64::try_from(total).ok()?))
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// Whether the live filesystem at `path` is below the configured free-space
/// floor (and by how much). Returns `None` if free space can't be read (skip the
/// floor this tick). `Some((true, deficit_bytes))` means evict until at least
/// `deficit_bytes` have been freed; `Some((false, 0))` means above the floor.
///
/// The floor is the MORE conservative (higher) of:
///   * the FRACTIONAL floor (`total × MIN_FREE_FRACTION`), and
///   * the ABSOLUTE floor (`MIN_FREE_BYTES`) — **but only when it is a sane
///     HEADROOM on this disk, i.e. < half the disk size**. On a disk smaller than
///     ~2× the absolute floor the absolute floor is meaningless (it would equal or
///     exceed the whole disk and perma-trigger eviction), so we fall back to the
///     fractional floor alone. This keeps the default 50GB headroom meaningful on
///     real multi-TB live tiers while never wedging a small/test filesystem.
#[cfg(test)] // production always goes through the per-policy variant; the tests
             // exercise the env-default floor path through this thin wrapper
fn below_free_floor(path: &str) -> Option<(bool, i64)> {
    below_free_floor_for_policy(path, None, None)
}

/// Like [`below_free_floor`] but lets a per-policy override replace the env/default
/// fractional and/or absolute floor inputs before the (unchanged, unit-tested)
/// [`free_floor_decision`] runs. `None` overrides fall back to the global env
/// floor, so passing `(None, None)` is byte-identical to [`below_free_floor`].
///
/// The fractional override is validated to `0.0..1.0` and the absolute override to
/// `>= 0`; an out-of-range value is ignored (falls back to the env value) so a bad
/// stored value can never wedge eviction. The `< total/2` small-disk guard inside
/// `free_floor_decision` still applies to a per-policy absolute floor, so an
/// oversized headroom on a tiny disk safely degrades to the fractional floor.
fn below_free_floor_for_policy(
    path: &str,
    frac_override: Option<f32>,
    abs_override: Option<i64>,
) -> Option<(bool, i64)> {
    let (free, total) = fs_free_and_total(path)?;
    let (env_frac, env_abs) = min_free_thresholds();
    let frac = frac_override
        .map(f64::from)
        .filter(|f| (0.0..1.0).contains(f))
        .unwrap_or(env_frac);
    let abs = abs_override.filter(|b| *b >= 0).unwrap_or(env_abs);
    Some(free_floor_decision(free, total, frac, abs))
}

/// Pure floor decision (no syscalls, no env) so the boundary logic is unit-
/// testable without touching the real filesystem or process-global env.
///
/// Returns `(below_floor, deficit_bytes)`: `deficit_bytes` is how much must be
/// freed to climb back above the floor (0 when above it).
#[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
fn free_floor_decision(free: i64, total: i64, frac: f64, abs: i64) -> (bool, i64) {
    let frac_floor = (total as f64 * frac) as i64;
    // Only honour the absolute floor when it is a genuine HEADROOM (< half the
    // disk); otherwise it would dominate and perma-fire on small disks.
    let abs_floor = if abs < total / 2 { abs } else { 0 };
    let floor = frac_floor.max(abs_floor);
    if free < floor {
        (true, floor - free)
    } else {
        (false, 0)
    }
}

/// Pure deficit-credit decision for a successful ARCHIVE MOVE during a
/// free-space-floor deficit (#278): the move may be credited against the
/// deficit ONLY when the source bytes lived on the floor (deficit)
/// filesystem — a move whose source sits on another disk (repointed
/// storage; or one sharing the archive fs while the floor fs is elsewhere)
/// frees nothing on the deficit disk, and crediting it would clear the
/// deficit on paper while the real disk keeps filling toward the ffmpeg
/// ENOSPC halt the floor exists to prevent.
fn credit_move_against_deficit(deficit: i64, seg_bytes: i64, src_on_floor_fs: bool) -> i64 {
    if deficit <= 0 || !src_on_floor_fs {
        return deficit.max(0);
    }
    (deficit - seg_bytes).max(0)
}

// ─── scheduler entry point ────────────────────────────────────────────────────

/// Run the archive scheduler loop until `cancel` is triggered.
///
/// This is the top-level entry point spawned by `main.rs`.  It never panics;
/// errors from individual operations are logged and the loop continues.
///
/// # Arguments
///
/// * `pool`   — database connection pool (deadpool-postgres).
/// * `config` — global recorder configuration.
/// * `cancel` — global shutdown token; loop exits when this is cancelled.
pub async fn run_scheduler(pool: Pool, config: Config, cancel: CancellationToken) {
    info!("archive scheduler started");

    // Allow the tick interval to be tuned without a rebuild.
    let tick_secs: u64 = std::env::var("ARCHIVE_TICK_SECONDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60);

    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(tick_secs));
    // Burst catch-up is undesirable here: if the process was suspended or a
    // tick was slow, skip the backlog and fire only at the next wall-clock
    // boundary.
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    // Per-camera cron state — allocated lazily on first contact.
    let mut cron_trackers: std::collections::HashMap<Uuid, CronTracker> =
        std::collections::HashMap::new();

    loop {
        tokio::select! {
            biased;

            // Honour cancellation before processing the next tick so shutdown
            // is instant when the tick and cancel arrive in the same poll.
            () = cancel.cancelled() => {
                info!("archive scheduler shutting down");
                break;
            }

            _ = interval.tick() => {
                tick(&pool, &config, &mut cron_trackers).await;
            }
        }
    }

    info!("archive scheduler stopped");
}

/// One scheduler tick: live retention sweep + per-camera archive jobs.
async fn tick(
    pool: &Pool,
    config: &Config,
    cron_trackers: &mut std::collections::HashMap<Uuid, CronTracker>,
) {
    // ── 1. Live retention for non-archive cameras (correctness item 7) ────────
    if let Err(e) = live_retention_sweep(pool, config).await {
        error!(error = %e, "live retention sweep failed");
    }

    // ── 2. Per-camera archive jobs ────────────────────────────────────────────
    let cameras = match db::list_enabled_cameras(pool).await {
        Ok(c) => c,
        Err(e) => {
            error!(error = %e, "failed to list cameras for archive tick; skipping");
            return;
        }
    };

    let now = Utc::now();

    // One shared wall-time budget for ALL of this tick's cron-archive moves
    // (issue #80): however many cameras fire at once, the tick spends at most
    // this long moving segments before yielding back to retention / the
    // free-space floor; the remainder is deferred and continued next tick.
    let archive_deadline = std::time::Instant::now() + archive_tick_budget();

    for camera in &cameras {
        // The cron-driven time-based archive move applies only to archive-enabled
        // cameras with a schedule.
        if camera.policy.archive_enabled {
            run_cron_archive(pool, config, camera, now, cron_trackers, archive_deadline).await;
        } else {
            // Archive OFF: there is no move to do, but residual stage=archive footage
            // may exist (archive was turned off after footage had been archived).
            // Drain it so it can't orphan — live_retention_sweep skips non-live
            // stages, so nothing else would ever delete it. Cheap no-op when the
            // camera has no archive segments (the candidate query returns empty).
            if let Err(e) = archive_retention_sweep(pool, config, camera).await {
                error!(
                    camera_id = %camera.id,
                    error     = %e,
                    "residual archive-stage drain failed (archive disabled)"
                );
            }
        }
    }

    // ── size-cap eviction (runs once per DISTINCT effective policy) ───────────
    //
    // Caps are now a shared budget across every camera on a policy rather than a
    // per-camera limit. We deduplicate by policy id so that a policy shared by N
    // cameras runs the sweep exactly once, not N times.
    //
    // live_max_bytes applies even when archive is off; archive_max_bytes is gated
    // on archive_enabled inside the sweep. Runs AFTER the cron loop so the bulk
    // time-move happens first and caps then trim any residual.
    {
        // Collect the first RecordingPolicy seen for each distinct policy id.
        // Camera.policy is already the resolved effective policy; clone it once
        // per unique id.
        let mut seen: std::collections::HashSet<Uuid> = std::collections::HashSet::new();
        let mut distinct_policies: Vec<RecordingPolicy> = Vec::new();
        for camera in &cameras {
            if seen.insert(camera.policy.id) {
                distinct_policies.push(camera.policy.clone());
            }
        }

        for policy in &distinct_policies {
            if let Err(e) = policy_size_eviction_sweep(pool, config, policy).await {
                error!(
                    policy_id = %policy.id,
                    error     = %e,
                    "size eviction sweep failed for policy"
                );
            }
            // Absolute max-retention ceiling (opt-in; OFF unless max_retention_days
            // is set). Runs AFTER size eviction so the archive move for this tick
            // has already happened — a segment that was just moved live→archive and
            // is also past the age cap is then deleted here in the same tick. A
            // no-op for the common case where no policy sets the cap.
            if let Err(e) = max_retention_sweep(pool, config, policy).await {
                error!(
                    policy_id = %policy.id,
                    error     = %e,
                    "max-retention sweep failed for policy"
                );
            }
        }
    }

    // Prune CronTracker entries for cameras that are no longer enabled so the
    // map does not grow unbounded.
    let enabled_ids: std::collections::HashSet<Uuid> = cameras.iter().map(|c| c.id).collect();
    cron_trackers.retain(|id, _| enabled_ids.contains(id));
}

/// Run the cron-driven time-based archive move + archive-retention sweep for one
/// archive-enabled camera, if its `archive_schedule` cron is due this tick — or
/// if a budget-bounded previous run left deferred backlog to continue (#80).
async fn run_cron_archive(
    pool: &Pool,
    config: &Config,
    camera: &Camera,
    now: DateTime<Utc>,
    cron_trackers: &mut std::collections::HashMap<Uuid, CronTracker>,
    deadline: std::time::Instant,
) {
    // Resolve the cron expression — cameras with no schedule are skipped.
    let schedule = match camera.policy.archive_schedule.as_deref() {
        Some(s) if !s.is_empty() => s,
        _ => {
            debug!(
                camera_id = %camera.id,
                "archive enabled but no schedule set; skipping"
            );
            return;
        }
    };

    // Initialise or RESYNC the tracker (#82: a runtime edit of
    // `archive_schedule` must take effect without a recorder restart).
    //
    // If the cron expression is invalid we log the error and skip this camera
    // rather than keeping a poisoned/stale tracker. The error is logged again
    // on the next tick, which is acceptable (once per minute) and keeps the
    // operator informed without crashing.
    let tracker = match ensure_cron_tracker(cron_trackers, camera.id, schedule) {
        Ok(t) => t,
        Err(e) => {
            error!(
                camera_id = %camera.id,
                schedule  = %schedule,
                error     = %e,
                "invalid archive_schedule cron expression; \
                 camera will not be archived until schedule is fixed"
            );
            return;
        }
    };

    let due = tracker.is_due(now, config.archive_cron_tz);
    // Continue a budget-deferred backlog on the next tick even without a cron
    // fire (#80) — otherwise a deferred catch-up would wait for the next
    // scheduled occurrence (typically a whole day).
    if !due && !tracker.backlog_pending {
        return;
    }

    info!(
        camera_id   = %camera.id,
        camera_name = %camera.name,
        cron_fired  = due,
        "archive job due (cron fired or continuing deferred backlog); running"
    );

    match archive_camera(pool, config, camera, deadline).await {
        Ok(outcome) => {
            // Deferred segments OR a truncated listing (#80 follow-up: a
            // fully-processed but LIMIT-filled batch may hide more eligible
            // rows) both mean "continue next tick without a cron fire".
            tracker.backlog_pending = outcome.backlog_pending();
        }
        Err(e) => {
            // Setup failures (missing storage / bad policy) won't self-heal
            // within a tick; clear the pending flag so the error is reported
            // once per cron fire rather than spammed once per tick.
            tracker.backlog_pending = false;
            error!(
                camera_id = %camera.id,
                error     = %e,
                "archive job failed"
            );
        }
    }

    if let Err(e) = archive_retention_sweep(pool, config, camera).await {
        error!(
            camera_id = %camera.id,
            error     = %e,
            "archive retention sweep failed"
        );
    }
}

/// Ensure the cached [`CronTracker`] for `camera_id` was parsed from `schedule`,
/// (re)parsing when the entry is missing or stale (#82: editing a camera's
/// `archive_schedule` previously never took effect until a restart, because the
/// tracker was lazily built once and never compared against the current value).
///
/// On a re-parse the evaluation window (`last_checked`) and the deferred-backlog
/// flag are preserved, so an edit can neither retro-fire past occurrences nor
/// skip one that lands right after the edit, and an in-progress catch-up (#80)
/// keeps going. An invalid new expression removes the stale entry (the operator
/// replaced the schedule — keeping the OLD cron firing would be wrong) and
/// returns the parse error for the caller to log.
fn ensure_cron_tracker<'a>(
    trackers: &'a mut std::collections::HashMap<Uuid, CronTracker>,
    camera_id: Uuid,
    schedule: &str,
) -> Result<&'a mut CronTracker> {
    let needs_parse = trackers
        .get(&camera_id)
        .is_none_or(|t| t.schedule != schedule);
    if needs_parse {
        let fresh = match CronTracker::new(schedule) {
            Ok(mut fresh) => {
                if let Some(old) = trackers.get(&camera_id) {
                    info!(
                        camera_id    = %camera_id,
                        old_schedule = %old.schedule,
                        new_schedule = %schedule,
                        "archive_schedule changed; cron tracker re-parsed (no restart needed)"
                    );
                    fresh.last_checked = old.last_checked;
                    fresh.backlog_pending = old.backlog_pending;
                }
                fresh
            }
            Err(e) => {
                trackers.remove(&camera_id);
                return Err(e);
            }
        };
        trackers.insert(camera_id, fresh);
    }
    trackers
        .get_mut(&camera_id)
        .ok_or_else(|| anyhow::anyhow!("cron tracker missing after ensure (unreachable)"))
}

// ─── archive job ──────────────────────────────────────────────────────────────

/// Run the archive job for a single camera, bounded by `deadline`.
///
/// For each live segment older than `live_retention_hours` on an
/// archive-enabled camera, moves the file from live storage to archive storage
/// using the safe copy→verify→update→delete sequence (correctness item 8).
///
/// **Bounded work (issue #80):** [`ARCHIVE_GUARD`] is held per BATCH of
/// [`ARCHIVE_MOVE_BATCH`] moves — not for the whole run — and the run stops at
/// `deadline`, returning how many eligible segments were left unprocessed. A
/// large catch-up backlog (first enable of archiving, days of downtime) no
/// longer pins the scheduler tick and the guard for hours, starving live
/// retention and the free-space floor; the scheduler re-runs the job every
/// tick (via the tracker's `backlog_pending` flag) until the backlog drains.
/// Releasing the guard between batches is safe: each move is independently
/// crash-ordered (copy→verify→index→delete, item 8), and a segment mutated by
/// a concurrent guard-holder between batches simply fails its own move
/// (missing source → logged, skipped) — same as any other per-segment failure.
///
/// Errors are logged per-segment and the loop continues.  Partial runs are
/// safe: the segment index always reflects the actual file location.
///
/// # Arguments
///
/// * `pool`     — database pool.
/// * `config`   — global recorder config.
/// * `camera`   — camera whose archive job is due.
/// * `deadline` — wall-clock cutoff for this run (shared across the tick).
///
/// # Returns
///
/// An [`ArchiveRunOutcome`]: how many LISTED segments were deferred past the
/// deadline, and whether the listing itself was truncated at
/// [`ARCHIVE_LIST_LIMIT`] (more eligible rows may exist that were never
/// listed). Either condition means the backlog is pending.
///
/// # Errors
///
/// Returns an error only for setup failures (missing storage, bad policy).
/// Per-segment errors are logged and not propagated.
pub async fn archive_camera(
    pool: &Pool,
    config: &Config,
    camera: &Camera,
    deadline: std::time::Instant,
) -> Result<ArchiveRunOutcome> {
    archive_camera_bounded(pool, config, camera, deadline, ARCHIVE_LIST_LIMIT).await
}

/// Outcome of one bounded [`archive_camera`] run (issue #80 + its follow-up).
#[derive(Debug, Clone, Copy)]
pub struct ArchiveRunOutcome {
    /// Eligible segments that were LISTED this run but deferred past the
    /// wall-time deadline (0 = every listed segment was processed).
    pub deferred: usize,
    /// The eligibility listing FILLED [`ARCHIVE_LIST_LIMIT`] — more eligible
    /// rows may exist behind the truncation that were never listed at all, so
    /// even a fully-processed run must re-query on the next tick.
    pub listing_truncated: bool,
}

impl ArchiveRunOutcome {
    /// More work may remain: the scheduler continues on the NEXT tick without
    /// waiting for the next cron fire (#80 continuation).
    pub fn backlog_pending(self) -> bool {
        self.deferred > 0 || self.listing_truncated
    }
}

/// [`archive_camera`] with an explicit listing bound, so tests can exercise
/// the truncated-listing continuation without inserting `ARCHIVE_LIST_LIMIT`
/// rows.
async fn archive_camera_bounded(
    pool: &Pool,
    _config: &Config,
    camera: &Camera,
    deadline: std::time::Instant,
    list_limit: i64,
) -> Result<ArchiveRunOutcome> {
    info!(
        camera_id   = %camera.id,
        camera_name = %camera.name,
        "archive job starting"
    );

    // ── resolve the ARCHIVE destination storage ───────────────────────────────
    // The SOURCE storage is resolved per-segment below (from each segment's own
    // `storage_id`), not from the policy's live_storage — see move_segment_to_archive.

    let archive_storage_id = camera.policy.archive_storage_id.with_context(|| {
        format!(
            "camera '{}' has no archive_storage_id in its policy",
            camera.name
        )
    })?;

    let archive_storage = db::get_storage(pool, archive_storage_id)
        .await
        .context("fetching archive storage")?
        .with_context(|| format!("archive storage {archive_storage_id} not found"))?;

    // ── select segments eligible for archiving ────────────────────────────────

    let cutoff = Utc::now() - Duration::hours(i64::from(camera.policy.live_retention_hours));

    let segments = list_live_segments_for_archive_limited(pool, camera.id, cutoff, list_limit)
        .await
        .context("listing live segments for archive")?;
    // A listing that fills the limit may hide more eligible rows behind the
    // truncation; the caller must treat this run as pending backlog even when
    // every listed segment is processed within budget.
    let listing_truncated = usize::try_from(list_limit)
        .map(|l| segments.len() >= l)
        .unwrap_or(false);

    if segments.is_empty() {
        debug!(
            camera_id = %camera.id,
            "no segments eligible for archiving"
        );
        return Ok(ArchiveRunOutcome {
            deferred: 0,
            listing_truncated: false,
        });
    }

    info!(
        camera_id = %camera.id,
        count     = segments.len(),
        cutoff    = %cutoff,
        "archiving segments"
    );

    let archive_root = Path::new(&archive_storage.path);

    let mut archived = 0u64;
    let mut failed = 0u64;
    // Cache storage rows so resolving each segment's source is not an N+1 query.
    let mut storage_cache: std::collections::HashMap<Uuid, Storage> =
        std::collections::HashMap::new();

    // Index of the first UNPROCESSED segment; everything past it at the end of
    // the run is the deferred backlog.
    let mut next = 0usize;
    while next < segments.len() && std::time::Instant::now() < deadline {
        // Serialize ONE bounded batch against any other archive operation
        // (see ARCHIVE_GUARD) — per batch, not per run (issue #80). The guard
        // drops at the end of this iteration, letting concurrent guard-takers
        // interleave between batches.
        let _archive_guard = ARCHIVE_GUARD.lock().await;
        let batch_end = (next + ARCHIVE_MOVE_BATCH).min(segments.len());
        while next < batch_end {
            // The deadline is also honoured WITHIN a batch so a run of large
            // files on a slow disk can't blow far past the budget.
            if std::time::Instant::now() >= deadline {
                break;
            }
            let seg = &segments[next];
            next += 1;
            if archive_one_segment(
                pool,
                camera,
                seg,
                archive_root,
                archive_storage.id,
                &mut storage_cache,
            )
            .await
            {
                archived += 1;
            } else {
                failed += 1;
            }
        }
    }

    let deferred = segments.len() - next;
    if deferred > 0 {
        info!(
            camera_id = %camera.id,
            deferred  = deferred,
            "archive tick budget exhausted; deferring remaining segments to the next tick"
        );
    }
    if listing_truncated {
        info!(
            camera_id = %camera.id,
            list_limit = list_limit,
            "eligible-segment listing truncated at the per-run limit; \
             remaining backlog will be re-queried next tick"
        );
    }

    info!(
        camera_id = %camera.id,
        archived  = archived,
        failed    = failed,
        deferred  = deferred,
        listing_truncated = listing_truncated,
        "archive job complete"
    );

    Ok(ArchiveRunOutcome {
        deferred,
        listing_truncated,
    })
}

/// Bounded variant of `db::list_live_segments_for_archive` (issue #80
/// follow-up): the same oldest-first eligibility SELECT with a `LIMIT`, so the
/// per-tick backlog continuation re-fetches at most [`ARCHIVE_LIST_LIMIT`]
/// rows instead of the entire eligible set (300k rows / ~70MB per 60s tick on
/// a large catch-up). Lives here rather than in `common/db.rs` because the
/// recorder's archive job is its only consumer and this audit fix is scoped to
/// this file; the projection mirrors the db.rs segment reads (no
/// `motion_score` / `motion_bbox_*` columns — neither is needed to move a
/// file, exactly as the unbounded query it replaces).
async fn list_live_segments_for_archive_limited(
    pool: &Pool,
    camera_id: Uuid,
    older_than: DateTime<Utc>,
    limit: i64,
) -> Result<Vec<Segment>> {
    let client = db::get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = $1
              AND stage = 'live'
              AND start_ts < $2
            ORDER BY start_ts
            LIMIT $3
            ",
            &[&camera_id, &older_than, &limit],
        )
        .await
        .context("list_live_segments_for_archive_limited")?;
    rows.iter()
        .map(|row| {
            let stage_str: String = row.get("stage");
            let stage = SegmentStage::from_str(&stage_str)
                .with_context(|| format!("unknown segment stage '{stage_str}'"))?;
            let stream_str: String = row.get("stream");
            let stream = crumb_common::types::SegmentStream::from_str(&stream_str)
                .with_context(|| format!("unknown segment stream '{stream_str}'"))?;
            Ok(Segment {
                id: row.get("id"),
                camera_id: row.get("camera_id"),
                storage_id: row.get("storage_id"),
                stage,
                path: row.get("path"),
                stream,
                start_ts: row.get("start_ts"),
                end_ts: row.get("end_ts"),
                duration_ms: row.get("duration_ms"),
                has_motion: row.get("has_motion"),
                size_bytes: row.get("size_bytes"),
                motion_bbox: None,
            })
        })
        .collect()
}

/// Archive ONE segment for [`archive_camera`]: resolve its OWN source storage
/// (per-segment — a policy's live storage can be repointed and older footage
/// still lives on the previous disk), run the crash-ordered move, and log the
/// outcome. Returns `true` on success, `false` on a (logged) per-segment
/// failure; the caller only tallies.
async fn archive_one_segment(
    pool: &Pool,
    camera: &Camera,
    seg: &Segment,
    archive_root: &Path,
    archive_storage_id: Uuid,
    storage_cache: &mut std::collections::HashMap<Uuid, Storage>,
) -> bool {
    let src_storage = match resolve_storage(pool, storage_cache, seg.storage_id).await {
        Ok(s) => s,
        Err(e) => {
            error!(
                camera_id  = %camera.id,
                segment_id = %seg.id,
                storage_id = %seg.storage_id,
                error      = %e,
                "failed to resolve segment storage for archive; skipping"
            );
            return false;
        }
    };
    let src_root = Path::new(&src_storage.path);
    match move_segment_to_archive(pool, seg, src_root, archive_root, archive_storage_id).await {
        Ok(()) => {
            debug!(
                camera_id  = %camera.id,
                segment_id = %seg.id,
                src        = %seg.path,
                "segment archived"
            );
            true
        }
        Err(e) => {
            error!(
                camera_id  = %camera.id,
                segment_id = %seg.id,
                error      = %e,
                "failed to archive segment; skipping"
            );
            false
        }
    }
}

/// Move a single segment from live storage to archive storage.
///
/// The exact sequence (correctness item 8):
/// 1. `tokio::fs::copy(src, dst)` — bytes land in archive
/// 2. Verify: `dst` metadata size equals `seg.size_bytes`
/// 3. `db::update_segment_archive(…)` — index now points at archive
/// 4. `tokio::fs::remove_file(src)` — live copy deleted
///
/// A `// PHASE-2 GROOMING SEAM` comment sits between steps 1 and 2.  A
/// future grooming pass (re-encode at lower fps) would be inserted there;
/// the copy destination is the groomed output and the rest of the pipeline
/// is unchanged.
async fn move_segment_to_archive(
    pool: &Pool,
    seg: &Segment,
    // The root of the SEGMENT'S OWN storage (resolved by the caller from
    // `seg.storage_id`), NOT the policy's current live storage. A policy's live
    // storage can be repointed, and footage recorded before the change still lives
    // on the old disk, so the source must be resolved per-segment or the move
    // looks for the file in the wrong place and (mis)treats it as missing.
    src_root: &Path,
    archive_root: &Path,
    archive_storage_id: Uuid,
) -> Result<()> {
    let src_abs = src_root.join(&seg.path);

    // Build the archive destination path using the same directory convention
    // as the recorder: <storage_root>/<camera_id>/<YYYY>/<MM>/<DD>/<filename>
    let dst_rel = archive_relative_path(&seg.camera_id, &seg.start_ts, &seg.path)?;
    let dst_abs = archive_root.join(&dst_rel);

    // ── SAME-FILE GUARD (issue #70) — never copy a segment onto itself ────────
    // If src_abs and dst_abs are the SAME file, the streaming copy below opens
    // the destination for WRITE (truncating the real segment to zero bytes) and
    // Step 4 then deletes it: permanent, silent footage loss. This is reachable
    // in normal configs — the seed defaults the `archive` storage to the SAME
    // path as the live storage (two storage rows, one directory), and the
    // startup reconciler adopts a file already sitting on the archive disk under
    // a stage=Live row. In both cases the bytes are ALREADY at their archive
    // location (dst_abs == archive_root/dst_rel is exactly where the row should
    // point), so the correct action is to flip the index row to stage=archive in
    // place: no copy, no delete. dev+ino identity (not textual path equality)
    // catches symlinks and two storage rows resolving to one directory.
    if same_file(&src_abs, &dst_abs).await {
        let dst_rel_str = dst_rel
            .to_str()
            .with_context(|| format!("non-UTF-8 archive path: {}", dst_rel.display()))?;
        // The file is already present; make it (and its dir entry) durable, then
        // record the archive stage/storage/path. update_segment_archive is an
        // idempotent no-op if the row already reflects this.
        fsync_file_and_parent_dir(&dst_abs)
            .await
            .with_context(|| format!("fsync in-place archive {}", dst_abs.display()))?;
        db::update_segment_archive(pool, seg.id, archive_storage_id, dst_rel_str)
            .await
            .context("update_segment_archive (in-place, src==dst)")?;
        return Ok(());
    }

    // Ensure the destination directory exists.
    if let Some(dst_dir) = dst_abs.parent() {
        tokio::fs::create_dir_all(dst_dir)
            .await
            .with_context(|| format!("create_dir_all {}", dst_dir.display()))?;
    }

    // ── Step 1: copy bytes to archive, HASHING the source as we read ──────────
    // (audit P1 #8 / P2 #7) A byte-LENGTH-only verify can't catch a same-length
    // bit-flip during the cross-device copy (the archive HDD reports write-back
    // cache). We CRC32 the source stream while copying, then re-hash the written
    // destination and compare before deleting the source — so corruption is
    // caught while the good source still exists.
    let (bytes_copied, src_crc) = match copy_with_crc32(&src_abs, &dst_abs).await {
        Ok(r) => r,
        Err(e) => {
            // A failed/interrupted copy can leave a PARTIAL destination behind
            // (issue #84). Remove it best-effort before propagating — exactly
            // as the size/crc verify branches below do — so a half-written
            // file is never left to be mistaken for a valid archive copy. The
            // same-file guard above already ruled out src == dst, so this can
            // never touch the source.
            let _ = tokio::fs::remove_file(&dst_abs).await;
            return Err(e.context(format!(
                "copy {} -> {}",
                src_abs.display(),
                dst_abs.display()
            )));
        }
    };

    // ── PHASE-2 GROOMING SEAM ─────────────────────────────────────────────────
    // In Phase 2, insert a grooming step here:
    //   1. Re-encode `dst_abs` to a lower frame-rate.
    //   2. Replace `dst_abs` with the groomed output.
    //   3. Update `bytes_copied` / verification size accordingly.
    // The copy→verify→update→delete sequence below remains unchanged.
    // ── END PHASE-2 GROOMING SEAM ─────────────────────────────────────────────

    // ── Step 2a: verify destination SIZE ──────────────────────────────────────
    let dst_meta = tokio::fs::metadata(&dst_abs)
        .await
        .with_context(|| format!("metadata {}", dst_abs.display()))?;
    let dst_size = dst_meta.len();

    // The bytes_copied count from the streaming copy is the authoritative byte
    // count; the metadata len is a cross-check.
    if dst_size != bytes_copied || dst_size != seg.size_bytes as u64 {
        // Remove the incomplete destination so it is not misidentified as a
        // valid archive file during reconciliation.
        let _ = tokio::fs::remove_file(&dst_abs).await;
        anyhow::bail!(
            "archive verify failed for segment {}: \
             expected {} bytes, copied {} bytes, dst has {} bytes",
            seg.id,
            seg.size_bytes,
            bytes_copied,
            dst_size,
        );
    }

    // ── Step 2b: verify destination CHECKSUM ──────────────────────────────────
    // Re-hash what actually landed on the archive disk and compare to the source
    // hash. Catches same-length corruption the size check misses. If it differs
    // we DELETE the bad destination and abort WITHOUT touching the source — the
    // only good copy is preserved for the next attempt.
    let dst_crc = crc32_of_file(&dst_abs)
        .await
        .with_context(|| format!("crc32 dst {}", dst_abs.display()))?;
    if dst_crc != src_crc {
        let _ = tokio::fs::remove_file(&dst_abs).await;
        anyhow::bail!(
            "archive checksum mismatch for segment {}: src crc32 {:#010x} != dst crc32 {:#010x}; \
             destination discarded, source kept",
            seg.id,
            src_crc,
            dst_crc,
        );
    }

    // ── Step 2c: fsync the destination FILE + its parent DIR ──────────────────
    // (audit GAP 2 / P1 #2 — the only-copy-loss bug). tokio::fs::copy does NOT
    // flush; without this, update_segment_archive flips the row to stage=archive
    // (durable instantly) and remove_file unlinks the only other copy, while the
    // archive bytes are still page-cache-only. A power cut there = a row claiming
    // an archived segment backed by truncated/empty bytes, source gone.
    // fsyncing the dst file + dir BEFORE the row flip and source delete makes the
    // move crash-atomic in the SAFE direction (never delete the only durable copy).
    fsync_file_and_parent_dir(&dst_abs)
        .await
        .with_context(|| format!("fsync archive dst {}", dst_abs.display()))?;

    // ── Step 3: update the index row ──────────────────────────────────────────
    let dst_rel_str = dst_rel
        .to_str()
        .with_context(|| format!("non-UTF-8 archive path: {}", dst_rel.display()))?;

    db::update_segment_archive(pool, seg.id, archive_storage_id, dst_rel_str)
        .await
        .context("update_segment_archive")?;

    // ── Step 4: delete the source ─────────────────────────────────────────────
    //
    // This runs AFTER the dst is fsync-durable AND the index update so a crash
    // here leaves the archive copy indexed (safe) rather than the live copy with
    // a stale row.  NOTE: the reconciler does NOT clean up the leftover source
    // file after such a crash — its orphan pass sees a row already indexed at
    // this (camera_id, stream, start_ts) key and conservatively leaves the file
    // in place (reconcile.rs `OrphanOutcome::AlreadyIndexed`), and no sweep
    // deletes files that have no row. The cost of this crash window is bounded
    // and safe-direction: one segment's worth of duplicate bytes on the source
    // disk, reclaimable only by an operator (or a future
    // duplicate-of-indexed-key cleanup pass) — never footage loss.
    tokio::fs::remove_file(&src_abs)
        .await
        .with_context(|| format!("remove source {}", src_abs.display()))?;

    Ok(())
}

/// A segment whose bytes are durably on the migration target (file fsynced),
/// awaiting the guarded batch DB flip + source delete.
struct CopiedSeg {
    id: Uuid,
    src_abs: PathBuf,
    dst_abs: PathBuf,
    size_bytes: i64,
}

/// Result of the (unguarded, parallelizable) copy phase for one segment.
enum MigrationOutcome {
    /// Bytes durable on target; ready for the guarded flip.
    Copied(CopiedSeg),
    /// Source file already gone (dangling row) — the reconciler owns those.
    Skipped,
    /// A real I/O / verify failure; any partial destination was removed.
    Failed,
}

/// Copy ONE segment src→dst with a streaming CRC32 + size verification and an
/// fsync of the destination **file**, keeping the same relative path under the new
/// root. This is the parallelizable, un-guarded half of the "Change storage"
/// drain: it does NOT touch the DB and does NOT delete the source — the caller
/// performs the guarded batch flip + source delete.
///
/// Differences from the archive-move primitive, by design:
/// * **No destination re-read.** The archive path re-reads the whole written file
///   to re-hash it; that doubled migration I/O (read every copied byte back off
///   the target) for a guarantee the streaming CRC + size check already give on a
///   local filesystem. The streaming hash sees every source byte as it's written.
/// * **Parent dir not fsynced here.** The caller fsyncs each batch's (few) distinct
///   destination directories ONCE, instead of once per file.
///
/// The caller MUST have already created the destination directory.
async fn copy_segment_for_migration(
    seg: &Segment,
    src_root: &Path,
    dst_root: &Path,
) -> MigrationOutcome {
    let src_abs = src_root.join(&seg.path);
    let dst_abs = dst_root.join(&seg.path); // SAME relative path, new root

    if !tokio::fs::try_exists(&src_abs).await.unwrap_or(false) {
        // Dangling row (file already gone) — the reconciler owns dangling rows.
        warn!(segment = %seg.id, src = %src_abs.display(),
              "migration: source missing (dangling row); skipping");
        return MigrationOutcome::Skipped;
    }

    // copy + streaming hash of the source (one pass)
    let bytes_copied = match copy_with_crc32(&src_abs, &dst_abs).await {
        Ok((n, _src_crc)) => n,
        Err(e) => {
            warn!(segment = %seg.id, error = %e,
                  "migration: copy {} -> {} failed", src_abs.display(), dst_abs.display());
            let _ = tokio::fs::remove_file(&dst_abs).await;
            return MigrationOutcome::Failed;
        }
    };

    // size verify (a truncated/short write is the failure the streaming copy can't
    // catch on its own); discard the partial dst on mismatch, keep the source.
    let dst_size = match tokio::fs::metadata(&dst_abs).await {
        Ok(m) => m.len(),
        Err(e) => {
            warn!(segment = %seg.id, error = %e, "migration: stat dst {} failed", dst_abs.display());
            let _ = tokio::fs::remove_file(&dst_abs).await;
            return MigrationOutcome::Failed;
        }
    };
    if dst_size != bytes_copied || dst_size != seg.size_bytes as u64 {
        warn!(segment = %seg.id, expected = seg.size_bytes, copied = bytes_copied, dst = dst_size,
              "migration: size verify failed; discarding dst");
        let _ = tokio::fs::remove_file(&dst_abs).await;
        return MigrationOutcome::Failed;
    }

    // fsync the destination FILE so its bytes are durable before the DB flip; the
    // parent dir's dirent is fsynced once per batch by the caller.
    if let Err(e) = fsync_file_only(&dst_abs).await {
        warn!(segment = %seg.id, error = %e, "migration: fsync dst {} failed; discarding", dst_abs.display());
        let _ = tokio::fs::remove_file(&dst_abs).await;
        return MigrationOutcome::Failed;
    }

    MigrationOutcome::Copied(CopiedSeg {
        id: seg.id,
        src_abs,
        dst_abs,
        size_bytes: seg.size_bytes,
    })
}

/// How many segments the drain pulls per batch. Larger batches amortize the per-
/// batch DB SELECT + the single bulk flip + the per-batch directory fsyncs over
/// more files. The expensive per-file I/O no longer holds [`ARCHIVE_GUARD`] (only
/// the brief bulk flip does), so this can be generous.
const MIGRATION_BATCH: i64 = 256;

/// How many segment copies run concurrently within a batch. The copies overlap
/// NVMe reads, target writes, and CRC compute. 4 is a good fit for a single
/// spinning-disk destination (more just thrashes the head) while keeping
/// NVMe→NVMe and NVMe→HDD moves saturated.
const MIGRATION_COPY_CONCURRENCY: usize = 4;

/// Execute a "Change storage" drain: move every segment of the migration's policy
/// still on `from_storage_id` to `to_storage_id`, keeping stage + path.
///
/// Per batch, the expensive work — copy + verify + fsync of each file — runs
/// **concurrently and WITHOUT [`ARCHIVE_GUARD`]** (it neither mutates the DB nor
/// deletes anything, so it can't race archiving/eviction). Only the cheap,
/// crash-critical step holds the guard: a SINGLE multi-row flip of every freshly-
/// copied segment's `storage_id` (one round-trip, one WAL flush, vs one per file).
/// Sources are deleted only after that flip commits. Crash-safety ordering is
/// preserved (durable dst → DB flip → delete source); a crash leaves at worst a
/// duplicate dst (no row) or a source orphan (row already on target) — both
/// harmless, and the conservative reconciler won't re-adopt a key that has a row.
///
/// Oldest-first + the guarded flip keep it idempotent and crash-resumable (moved
/// rows drop out of the next SELECT because their `storage_id` changed).
///
/// # Errors
///
/// Returns an error if a storage row is missing, or a whole batch makes zero
/// forward progress AND had real I/O errors (a genuine stall — e.g. the target
/// filled up), so the caller marks the job `failed` with the reason. A batch whose
/// only non-moves are dangling rows (missing source files) ends the drain cleanly
/// — all movable footage is on the target; the reconciler owns the dangling rows.
pub async fn run_storage_migration(pool: &Pool, mig: &StorageMigration) -> Result<()> {
    let from = db::get_storage(pool, mig.from_storage_id)
        .await?
        .context("migration source storage no longer exists")?;
    let to = db::get_storage(pool, mig.to_storage_id)
        .await?
        .context("migration target storage no longer exists")?;
    let from_root = Arc::new(PathBuf::from(&from.path));
    let to_root = Arc::new(PathBuf::from(&to.path));

    loop {
        // #9/#10: Re-read the migration row's status at the top of EACH batch so
        // that a `cancelled` status (set by the API cancel handler while the drain
        // is running) is honoured promptly rather than after the entire drain
        // completes. Without this check the API's cancel is a silent no-op: the
        // drain never re-reads and overwrites the status with `done` at the end.
        //
        // Uses `get_storage_migration` (already in db — no new symbols needed).
        // A missing row (deleted under us) is treated the same as `cancelled`.
        match db::get_storage_migration(pool, mig.id).await {
            Ok(Some(current)) if current.status == "running" => {
                // Status is still 'running' — safe to process this batch.
            }
            Ok(Some(current)) => {
                info!(
                    migration = %mig.id,
                    status    = %current.status,
                    "Change-storage drain: status changed externally; aborting drain"
                );
                // Return Ok so the caller does NOT overwrite with `failed`;
                // the cancelling party has already set the terminal status.
                return Ok(());
            }
            Ok(None) => {
                warn!(migration = %mig.id,
                      "Change-storage drain: migration row no longer exists; aborting");
                return Ok(());
            }
            Err(e) => {
                // A transient DB error reading the status should not abort a
                // healthy drain — log and continue so one blip doesn't kill
                // a long-running migration. If the connection is genuinely dead
                // the batch SELECT below will also fail and surface the error.
                warn!(migration = %mig.id, error = %e,
                      "Change-storage drain: failed to re-read status; continuing");
            }
        }

        let batch = db::list_policy_segments_on_storage(
            pool,
            mig.policy_id,
            mig.from_storage_id,
            MIGRATION_BATCH,
        )
        .await
        .context("list segments to drain")?;
        if batch.is_empty() {
            break; // fully drained
        }

        // Pre-create the batch's DISTINCT destination directories once (deduped) so
        // the concurrent copies don't each mkdir, and so we can fsync the (few)
        // dirs once at the end rather than once per file.
        let mut dirs: HashSet<PathBuf> = HashSet::new();
        for seg in &batch {
            if let Some(d) = to_root.join(&seg.path).parent() {
                dirs.insert(d.to_path_buf());
            }
        }
        for d in &dirs {
            tokio::fs::create_dir_all(d)
                .await
                .with_context(|| format!("create_dir_all {}", d.display()))?;
        }

        // ── Copy phase (NO guard): up to N segments copied + file-fsynced at once.
        let mut tasks: JoinSet<MigrationOutcome> = JoinSet::new();
        let mut iter = batch.iter();
        let mut copied: Vec<CopiedSeg> = Vec::new();
        let (mut skipped, mut failed) = (0usize, 0usize);
        loop {
            while tasks.len() < MIGRATION_COPY_CONCURRENCY {
                let Some(seg) = iter.next() else { break };
                let seg = seg.clone();
                let src_root = Arc::clone(&from_root);
                let dst_root = Arc::clone(&to_root);
                tasks.spawn(async move {
                    copy_segment_for_migration(&seg, src_root.as_path(), dst_root.as_path()).await
                });
            }
            let Some(joined) = tasks.join_next().await else {
                break;
            };
            match joined {
                Ok(MigrationOutcome::Copied(c)) => copied.push(c),
                Ok(MigrationOutcome::Skipped) => skipped += 1,
                Ok(MigrationOutcome::Failed) => failed += 1,
                Err(e) => {
                    failed += 1;
                    warn!(error = %e, "migration: copy task join failed");
                }
            }
        }

        // fsync the batch's (few) destination directories once, so the new dirents
        // are durable before we flip the DB and delete the sources.
        for d in &dirs {
            if let Err(e) = fsync_dir(d).await {
                warn!(dir = %d.display(), error = %e, "migration: dir fsync failed (continuing)");
            }
        }

        // ── Flip phase (GUARD held only here, briefly): ONE multi-row UPDATE flips
        //    every copied segment still on the source. RETURNING tells us exactly
        //    which rows changed — a row a concurrent eviction/move already changed
        //    simply isn't returned, and its freshly-copied dst becomes an orphan.
        let copied_ids: Vec<Uuid> = copied.iter().map(|c| c.id).collect();
        let flipped: HashSet<Uuid> = {
            let _archive_guard = ARCHIVE_GUARD.lock().await;
            db::bulk_update_segment_storage(
                pool,
                &copied_ids,
                mig.to_storage_id,
                mig.from_storage_id,
            )
            .await
            .context("bulk flip segment storage_id")?
            .into_iter()
            .collect()
        };

        // ── Cleanup: delete the source for every flipped segment (durable dst + DB
        //    flip already done). A copied-but-not-flipped row lost the race to a
        //    concurrent mover/eviction → its dst copy is a duplicate; remove it.
        let (mut moved, mut bytes) = (0i64, 0i64);
        for c in &copied {
            if flipped.contains(&c.id) {
                match tokio::fs::remove_file(&c.src_abs).await {
                    Ok(()) => {}
                    // After the flip, a missing source is harmless — the row already
                    // points at the durable target copy.
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => warn!(segment = %c.id, error = %e,
                        "migration: source delete failed after flip (orphan left for reconciler)"),
                }
                moved += 1;
                bytes += c.size_bytes;
            } else {
                let _ = tokio::fs::remove_file(&c.dst_abs).await;
            }
        }

        if moved > 0 {
            db::add_migration_progress(pool, mig.id, moved, bytes)
                .await
                .context("update migration progress")?;
        }

        // A batch that moved NOTHING means no forward progress is possible —
        // re-listing returns the same rows forever, so stop rather than spin.
        if moved == 0 {
            if failed == 0 && skipped > 0 {
                // The only non-moves were dangling rows (missing source files). All
                // movable footage is on the target; the reconciler owns the rest.
                warn!(migration = %mig.id, dangling = skipped,
                      "migration: drain complete; {skipped} dangling row(s) left for the reconciler");
                break;
            }
            anyhow::bail!(
                "migration stalled: 0 of {} segment(s) moved this batch \
                 ({failed} errored, {skipped} dangling/missing source) — target full or unreadable?",
                batch.len()
            );
        }
    }
    Ok(())
}

/// Stream-copy `src` → `dst`, returning `(bytes_written, crc32_of_source)`.
///
/// Reads the source in chunks, feeds each chunk to a CRC32 hasher, and writes it
/// to the destination — one pass, no extra read of the source. Used by the
/// archive move so the source hash is computed for free during the copy and can
/// be compared to a re-hash of the destination before the source is deleted.
/// True when `a` and `b` are the SAME file on disk (identical device + inode),
/// resolving symlinks, `..`, and two storage rows that point at one directory.
/// A missing side (the normal cross-storage move, where the destination does
/// not exist yet) returns false. Used to refuse a copy that would truncate the
/// only copy of a segment (issue #70).
async fn same_file(a: &Path, b: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        match (tokio::fs::metadata(a).await, tokio::fs::metadata(b).await) {
            (Ok(ma), Ok(mb)) => ma.dev() == mb.dev() && ma.ino() == mb.ino(),
            _ => false,
        }
    }
    #[cfg(not(unix))]
    {
        // No dev/ino; fall back to canonical-path equality (CI cross-check only).
        match (
            tokio::fs::canonicalize(a).await,
            tokio::fs::canonicalize(b).await,
        ) {
            (Ok(ca), Ok(cb)) => ca == cb,
            _ => false,
        }
    }
}

/// True when `a` and `b` live on the SAME filesystem (identical `st_dev`), so a
/// live→archive "move" between them cannot free a single byte of physical disk
/// space. This is the default compose layout: `/data/archive` on the same
/// filesystem as the live `/data` tree, expressed as two storage rows.
///
/// Used by the free-space-floor rescue in [`policy_size_eviction_sweep`]: when
/// the floor is in deficit, freeing space must actually reduce used bytes, and
/// a same-filesystem archive move does not.
///
/// Conservative on failure: if either side cannot be stat'd (unmounted
/// storage, archive root not yet created) this returns `false`, keeping the
/// normal footage-preserving archive-move behaviour — the floor deficit then
/// persists into the next tick, by which time the move will have created the
/// archive root and the detection works. Also `false` on non-Unix (no
/// `st_dev`; CI cross-checks only).
async fn same_filesystem(a: &Path, b: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        match (tokio::fs::metadata(a).await, tokio::fs::metadata(b).await) {
            (Ok(ma), Ok(mb)) => ma.dev() == mb.dev(),
            _ => false,
        }
    }
    #[cfg(not(unix))]
    {
        let _ = (a, b);
        false
    }
}

async fn copy_with_crc32(src: &Path, dst: &Path) -> Result<(u64, u32)> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    // Defense in depth for issue #70: `File::create(dst)` truncates, so if a
    // caller ever reaches here with src == dst it would zero the source before a
    // single byte is read. `move_segment_to_archive` already guards this, but a
    // copy that destroys its own source must never be one refactor away.
    if same_file(src, dst).await {
        anyhow::bail!(
            "refusing to copy a segment onto itself: {} == {} (issue #70)",
            src.display(),
            dst.display(),
        );
    }

    let mut reader = tokio::fs::File::open(src)
        .await
        .with_context(|| format!("open src {}", src.display()))?;
    let mut writer = tokio::fs::File::create(dst)
        .await
        .with_context(|| format!("create dst {}", dst.display()))?;

    let mut hasher = crc32fast::Hasher::new();
    let mut buf = vec![0u8; 256 * 1024];
    let mut total: u64 = 0;
    loop {
        let n = reader
            .read(&mut buf)
            .await
            .with_context(|| format!("read src {}", src.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        writer
            .write_all(&buf[..n])
            .await
            .with_context(|| format!("write dst {}", dst.display()))?;
        total += n as u64;
    }
    writer
        .flush()
        .await
        .with_context(|| format!("flush dst {}", dst.display()))?;
    Ok((total, hasher.finalize()))
}

/// Compute the CRC32 of a file's full contents (used to re-hash the archive
/// destination after copy).
async fn crc32_of_file(path: &Path) -> Result<u32> {
    use tokio::io::AsyncReadExt;
    let mut reader = tokio::fs::File::open(path)
        .await
        .with_context(|| format!("open for crc32 {}", path.display()))?;
    let mut hasher = crc32fast::Hasher::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = reader
            .read(&mut buf)
            .await
            .with_context(|| format!("read for crc32 {}", path.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize())
}

/// fsync a file's data + metadata AND its parent directory's dirent.
///
/// The POSIX-correct durability primitive for the archive move (audit GAP 2):
/// `sync_all` flushes the file's bytes + length; fsyncing the parent dir flushes
/// the directory entry so the file can't vanish on a power cut. Runs the blocking
/// syscalls on `spawn_blocking` so the scheduler is never blocked.
async fn fsync_file_and_parent_dir(path: &Path) -> Result<()> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || -> Result<()> {
        use std::fs::File;
        let f = File::open(&path).with_context(|| format!("open for fsync {}", path.display()))?;
        f.sync_all()
            .with_context(|| format!("sync_all {}", path.display()))?;
        if let Some(parent) = path.parent() {
            let dir = File::open(parent)
                .with_context(|| format!("open parent dir for fsync {}", parent.display()))?;
            dir.sync_all()
                .with_context(|| format!("sync_all parent dir {}", parent.display()))?;
        }
        Ok(())
    })
    .await
    .context("fsync_file_and_parent_dir: join")?
}

/// fsync a single file's data + metadata (its parent dir is fsynced separately).
///
/// The split form used by the "Change storage" drain: each copied file is fsynced
/// here (needed per file), but the (few) destination directories of a batch are
/// fsynced ONCE via [`fsync_dir`] instead of once per file — a large win on a
/// spinning destination where every fsync costs a rotation.
async fn fsync_file_only(path: &Path) -> Result<()> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || -> Result<()> {
        let f = std::fs::File::open(&path)
            .with_context(|| format!("open for fsync {}", path.display()))?;
        f.sync_all()
            .with_context(|| format!("sync_all {}", path.display()))?;
        Ok(())
    })
    .await
    .context("fsync_file_only: join")?
}

/// fsync a directory so newly-created dirents in it survive a crash. Amortized
/// across a migration batch (called once per distinct destination directory).
async fn fsync_dir(dir: &Path) -> Result<()> {
    let dir = dir.to_path_buf();
    tokio::task::spawn_blocking(move || -> Result<()> {
        let d = std::fs::File::open(&dir)
            .with_context(|| format!("open dir for fsync {}", dir.display()))?;
        d.sync_all()
            .with_context(|| format!("sync_all dir {}", dir.display()))?;
        Ok(())
    })
    .await
    .context("fsync_dir: join")?
}

/// Derive the archive-relative path for a segment.
///
/// Format: `<camera_id>/<YYYY>/<MM>/<DD>/<original_filename>`
///
/// We preserve the original filename so the segment's timestamp can still be
/// parsed from it by the reconciler and other tools.
fn archive_relative_path(
    camera_id: &Uuid,
    start_ts: &DateTime<Utc>,
    original_path: &str,
) -> Result<PathBuf> {
    // Extract just the filename from the (possibly multi-component) live path.
    let filename = Path::new(original_path)
        .file_name()
        .with_context(|| format!("segment path '{original_path}' has no filename component"))?;

    let rel = PathBuf::from(camera_id.to_string())
        .join(format!("{}", start_ts.format("%Y")))
        .join(format!("{}", start_ts.format("%m")))
        .join(format!("{}", start_ts.format("%d")))
        .join(filename);

    Ok(rel)
}

// ─── live retention sweep ─────────────────────────────────────────────────────

/// Delete live-stage segments older than retention for non-archive cameras.
///
/// **Correctness item 7** is enforced both at the SQL level (the
/// [`db::list_live_segments_older_than`] query joins on `archive_enabled =
/// false`) *and* here as a defence-in-depth guard.  The archiver owns deletion
/// of archive-enabled cameras' segments.
///
/// **Correctness item 10**: file is removed first; the index row is deleted
/// only on filesystem success.
///
/// # Per-camera retention
///
/// Each camera has its own `live_retention_hours` policy field.  Since the
/// `list_live_segments_older_than` DB accessor accepts a single cutoff
/// timestamp (not a per-camera cutoff), we use the following strategy:
///
/// 1. Load all enabled cameras; build a map `camera_id → live_retention_hours`
///    for non-archive cameras.
/// 2. Pass a generous cutoff to the DB (the minimum retention among all
///    non-archive cameras) — this returns only segments that *could* be
///    eligible.
/// 3. For each returned segment, cross-check against the camera's own
///    `live_retention_hours` before deleting.
///
/// This ensures we never delete footage that is still within a camera's own
/// retention window.
///
/// # Errors
///
/// Returns an error if the initial database queries fail.  Per-segment errors
/// are logged and the sweep continues.
pub async fn live_retention_sweep(pool: &Pool, _config: &Config) -> Result<()> {
    let now = Utc::now();

    // Load all enabled cameras to build the per-camera retention map.
    let cameras = db::list_enabled_cameras(pool)
        .await
        .context("list_enabled_cameras for retention sweep")?;

    // Build map: camera_id -> live_retention_hours for non-archive cameras.
    // Also determine the minimum retention across non-archive cameras so we
    // can use it as the DB query cutoff (see doc comment above).
    let mut retention_map: std::collections::HashMap<Uuid, i32> = std::collections::HashMap::new();
    let mut min_retention_hours: i32 = i32::MAX;

    for cam in &cameras {
        if !cam.policy.archive_enabled {
            let h = cam.policy.live_retention_hours;
            retention_map.insert(cam.id, h);
            if h < min_retention_hours {
                min_retention_hours = h;
            }
        }
    }

    if retention_map.is_empty() {
        // All cameras are archive-enabled; nothing to sweep here.
        return Ok(());
    }

    // The DB cutoff is the oldest possible eligible segment: now minus the
    // shortest live retention among non-archive cameras.  Segments older than
    // this could be eligible for at least one camera; the per-segment check
    // below filters out segments that are still within their own camera's
    // window.
    let db_cutoff = now - Duration::hours(i64::from(min_retention_hours));

    // Fetch segments eligible for deletion.  The db accessor already filters
    // out archive-enabled cameras (correctness item 7).
    //
    // Batch-limited (oldest-first) to [`MAX_RETENTION_BATCH_LIMIT`]: without a
    // cap, shortening a camera's retention or a long recorder downtime would
    // materialise MILLIONS of `Segment` rows into one `Vec` and OOM a small box
    // (Pi/NUC). The query orders oldest-first, so a capped batch always makes
    // forward progress and the sweep converges over its ~60s ticks — the same
    // convergence-over-ticks pattern the reconcile, size-eviction, and
    // max-retention sweeps already use.
    let segments =
        db::list_live_segments_older_than(pool, db_cutoff, Some(MAX_RETENTION_BATCH_LIMIT))
            .await
            .context("list_live_segments_older_than")?;

    if segments.is_empty() {
        return Ok(());
    }

    debug!(count = segments.len(), "live retention sweep: candidates");

    // We need live storage paths to resolve absolute file paths.  Each segment
    // carries storage_id; we resolve and cache storage rows to avoid N+1 queries.
    let mut storage_cache: std::collections::HashMap<Uuid, Storage> =
        std::collections::HashMap::new();

    for seg in &segments {
        // Defence-in-depth: double-check stage is 'live' (correctness item 7).
        if seg.stage != SegmentStage::Live {
            warn!(
                segment_id = %seg.id,
                stage      = ?seg.stage,
                "live_retention_sweep: segment is not live-stage; skipping"
            );
            continue;
        }

        // Per-camera retention cross-check: even though we queried with the
        // minimum retention cutoff, a segment might belong to a camera with
        // a longer retention window and therefore not yet be eligible.
        if let Some(&cam_retention_hours) = retention_map.get(&seg.camera_id) {
            let cam_cutoff = now - Duration::hours(i64::from(cam_retention_hours));
            if seg.start_ts >= cam_cutoff {
                // Segment is still within this camera's retention window.
                continue;
            }
        } else {
            // The segment belongs to a camera not in our retention map.
            // This means the camera is archive-enabled or disabled — skip it.
            // (Correctness item 7 defence-in-depth.)
            warn!(
                segment_id = %seg.id,
                camera_id  = %seg.camera_id,
                "live_retention_sweep: camera not in retention map (archive-enabled or disabled); skipping"
            );
            continue;
        }

        // Resolve storage row (cached).
        let storage = match resolve_storage(pool, &mut storage_cache, seg.storage_id).await {
            Ok(s) => s,
            Err(e) => {
                error!(
                    segment_id = %seg.id,
                    storage_id = %seg.storage_id,
                    error      = %e,
                    "live_retention_sweep: could not resolve storage; skipping segment"
                );
                continue;
            }
        };

        let abs_path = Path::new(&storage.path).join(&seg.path);

        // ── Step 1: delete the file ───────────────────────────────────────────
        match tokio::fs::remove_file(&abs_path).await {
            Ok(()) => {
                debug!(
                    segment_id = %seg.id,
                    path       = %abs_path.display(),
                    "live retention: file deleted"
                );
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                // File already gone (e.g. manual cleanup or prior crash).
                // Proceed to delete the row so the index is consistent.
                warn!(
                    segment_id = %seg.id,
                    path       = %abs_path.display(),
                    "live retention: file not found; cleaning up dangling row"
                );
            }
            Err(e) => {
                error!(
                    segment_id = %seg.id,
                    path       = %abs_path.display(),
                    error      = %e,
                    "live retention: failed to delete file; skipping row deletion"
                );
                // Do NOT delete the row — the file might still be there.
                // (correctness item 10)
                continue;
            }
        }

        // ── Step 2: delete the index row ─────────────────────────────────────
        if let Err(e) = db::delete_segment_row(pool, seg.id).await {
            error!(
                segment_id = %seg.id,
                error      = %e,
                "live retention: failed to delete segment row"
            );
        }
    }

    Ok(())
}

// ─── archive retention sweep ──────────────────────────────────────────────────

/// Effective retention window (hours) for a camera's `stage=archive` segments,
/// or `None` for "keep indefinitely / nothing to drain".
///
/// - Archive **enabled**: the archive tier governs — `archive_retention_hours`
///   (`None`/`<= 0` ⇒ keep indefinitely on the archive tier; original behaviour).
/// - Archive **disabled** but residual archive-stage footage may exist (archive
///   was turned off *after* footage had already been archived): drain it so it
///   cannot orphan. `live_retention_sweep` skips non-live stages and the size
///   sweep's archive branch is gated on `archive_enabled`, so without this drain
///   that footage is swept by nothing and lives forever. Drain under
///   `archive_retention_hours` when one was set (a graceful wind-down under the
///   rule it was stored under — no surprise mass-deletion), else bound it by
///   `live_retention_hours` so `stage=archive` is never retained forever with no
///   owning tier. `None` only when BOTH are non-positive.
fn archive_drain_retention_hours(policy: &RecordingPolicy) -> Option<i32> {
    let archive = policy.archive_retention_hours.filter(|h| *h > 0);
    if policy.archive_enabled {
        archive
    } else {
        archive.or_else(|| Some(policy.live_retention_hours).filter(|h| *h > 0))
    }
}

/// P0-HEALTH-NOTIFY: emit a `premature_rollover` system event when a
/// size-cap/free-space eviction deletes a segment BEFORE it reached its
/// configured time-based retention window — i.e. actual footage loss, not a
/// routine time-based expiry. This is deliberately a pure "would-be-retained"
/// check against the SAME `retention_hours` the time-based sweeps use, so it
/// fires only when the size/floor pressure is the reason footage is gone
/// sooner than the admin configured, not merely "old enough anyway".
///
/// Best-effort: a failure to write the system event is logged and swallowed
/// — it must never abort or slow down the eviction sweep itself (footage
/// deletion always takes priority over alerting about it).
async fn emit_premature_rollover_if_early(
    pool: &Pool,
    seg: &Segment,
    retention_hours: i32,
    reason: &str,
) {
    if retention_hours <= 0 {
        return; // "indefinite" retention — any eviction is inherently premature,
                // but a policy that explicitly asked for unbounded retention
                // and also set a byte cap has already accepted size-driven
                // trimming as normal; don't alert on it.
    }
    let would_expire_at = seg.start_ts + Duration::hours(i64::from(retention_hours));
    if would_expire_at <= Utc::now() {
        return; // Segment had already reached its normal retention age anyway.
    }
    let detail = format!(
        "{reason}: segment {} (camera {}) evicted early — would not have expired \
         under its {retention_hours}h retention until {would_expire_at}",
        seg.id, seg.camera_id
    );
    if let Err(e) = db::insert_system_event(
        pool,
        "premature_rollover",
        Some(seg.camera_id),
        Some(&detail),
    )
    .await
    {
        warn!(error = %e, segment_id = %seg.id, "failed to record premature_rollover system event");
    }
}

/// Delete archive-stage segments older than their effective retention
/// ([`archive_drain_retention_hours`]).
///
/// Runs for archive-ENABLED cameras (the archive tier's own retention) AND, as
/// the fix for the disable-archive orphan bug, for archive-DISABLED cameras that
/// still have residual `stage=archive` footage — draining it under the archive
/// retention (or the live retention as a bound) so it cannot orphan.
///
/// **Correctness item 10** applies here identically to live retention: the
/// file is removed before the index row. The candidate query
/// ([`db::list_archive_segments_older_than`]) skips segments overlapping an active
/// protected bookmark, so pinned clips survive.
///
/// # Errors
///
/// Returns an error if the database query fails.  Per-segment errors are
/// logged and the sweep continues.
pub async fn archive_retention_sweep(pool: &Pool, _config: &Config, camera: &Camera) -> Result<()> {
    let retention_hours = match archive_drain_retention_hours(&camera.policy) {
        Some(h) => h,
        None => {
            debug!(
                camera_id = %camera.id,
                archive_enabled = camera.policy.archive_enabled,
                "no effective archive-stage retention (indefinite); nothing to sweep"
            );
            return Ok(());
        }
    };

    let cutoff = Utc::now() - Duration::hours(i64::from(retention_hours));

    let segments = db::list_archive_segments_older_than(pool, camera.id, cutoff)
        .await
        .context("list_archive_segments_older_than")?;

    if segments.is_empty() {
        return Ok(());
    }

    info!(
        camera_id = %camera.id,
        count     = segments.len(),
        cutoff    = %cutoff,
        "archive retention: sweeping expired segments"
    );

    let mut storage_cache: std::collections::HashMap<Uuid, Storage> =
        std::collections::HashMap::new();

    for seg in &segments {
        // Defence-in-depth: only process archive-stage rows here.
        if seg.stage != SegmentStage::Archive {
            warn!(
                segment_id = %seg.id,
                stage      = ?seg.stage,
                "archive_retention_sweep: unexpected stage; skipping"
            );
            continue;
        }

        let storage = match resolve_storage(pool, &mut storage_cache, seg.storage_id).await {
            Ok(s) => s,
            Err(e) => {
                error!(
                    segment_id = %seg.id,
                    storage_id = %seg.storage_id,
                    error      = %e,
                    "archive retention: could not resolve storage; skipping segment"
                );
                continue;
            }
        };

        let abs_path = Path::new(&storage.path).join(&seg.path);

        // ── Step 1: delete the file ───────────────────────────────────────────
        match tokio::fs::remove_file(&abs_path).await {
            Ok(()) => {
                debug!(
                    segment_id = %seg.id,
                    path       = %abs_path.display(),
                    "archive retention: file deleted"
                );
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                warn!(
                    segment_id = %seg.id,
                    path       = %abs_path.display(),
                    "archive retention: file not found; cleaning dangling row"
                );
            }
            Err(e) => {
                error!(
                    segment_id = %seg.id,
                    path       = %abs_path.display(),
                    error      = %e,
                    "archive retention: failed to delete file; skipping row deletion"
                );
                continue; // correctness item 10
            }
        }

        // ── Step 2: delete the index row ─────────────────────────────────────
        if let Err(e) = db::delete_segment_row(pool, seg.id).await {
            error!(
                segment_id = %seg.id,
                error      = %e,
                "archive retention: failed to delete segment row"
            );
        }
    }

    Ok(())
}

// ─── size-cap eviction sweep ───────────────────────────────────────────────────

/// Enforce the per-POLICY SIZE caps (`live_max_bytes` / `archive_max_bytes`) —
/// the size half of commercial-VMS-style "retention time OR max size, whichever hits
/// first". Runs once per distinct effective policy per tick (~60 s), independent
/// of the archive cron: caps are enforced continuously, the cron only drives the
/// time-based bulk move.
///
/// The cap is a **shared budget** across every camera on the policy: all of a
/// policy's cameras' live footage is summed and the oldest segments — regardless
/// of which camera produced them — are evicted first until the total is back
/// under the cap.
///
/// # Disposal order (matters)
///
/// LIVE eviction runs BEFORE ARCHIVE eviction within the same sweep, because
/// moving live→archive ADDS to the archive total and may itself push the archive
/// over its cap — the archive pass then trims that residual in the same tick.
///
/// # SAFETY INVARIANT
///
/// **Never delete a LIVE segment that has not been archived while
/// `archive_enabled` is true.** The live branch DELETES only in the `else`
/// (archive-disabled) arm; when archiving is on, the only disposal is
/// [`move_segment_to_archive`] (which deletes the source ONLY after the archive
/// copy is verified + indexed). If `archive_enabled` but the archive storage is
/// missing/unresolved, this logs an error and SKIPS live eviction entirely —
/// leaving footage in place rather than deleting un-archived footage.
///
/// **One deliberate, narrow exception — the ENOSPC rescue.** When the
/// free-space FLOOR is in DEFICIT *and* the archive destination is on the SAME
/// filesystem as the segment's own storage ([`same_filesystem`]; the default
/// compose layout puts `/data/archive` beside live `/data`), an archive move
/// frees ZERO bytes: pre-fix the sweep "moved" the oldest live footage in
/// place every tick, the deficit read as satisfied, and the disk filled to
/// 100% until ffmpeg hit ENOSPC and recording halted on EVERY camera — losing
/// all future footage. In exactly that state the deficit-driven portion of
/// the sweep DELETES the oldest segments instead (file-then-row, item 10, via
/// the shared helper; protected bookmarks are still excluded by the candidate
/// query; each disposal is still done under [`ARCHIVE_GUARD`], now re-acquired
/// per [`ARCHIVE_MOVE_BATCH`] sub-batch rather than pinned for the whole run —
/// issue #144 item 4), and emits
/// `premature_rollover` so the loss is loud. Cap-only pressure (no floor
/// deficit) still MOVES as before — the exception applies only while real
/// bytes must be freed and a move cannot free them.
///
/// `used` is computed once via `SUM` at entry, then decremented by
/// `seg.size_bytes` after each disposal so the loop stops exactly at the cap
/// without re-SUMming every iteration.
pub async fn policy_size_eviction_sweep(
    pool: &Pool,
    config: &Config,
    policy: &RecordingPolicy,
) -> Result<()> {
    // Serialize against any other archive job (see ARCHIVE_GUARD) — the eviction
    // sweep MOVES live→archive, so it must never overlap a cron archive_camera.
    //
    // Item 4 (issue #144): held per SUB-BATCH of [`ARCHIVE_MOVE_BATCH`] disposals,
    // NOT for the whole (up to [`EVICTION_BATCH_LIMIT`]-segment) run. The disposal
    // loops below drop and re-acquire the guard with a `yield_now` every batch so
    // a large eviction can no longer pin the guard — and the scheduler tick — for
    // the entire sweep, which starved the cron archiver and the free-space floor.
    // Releasing between disposals is safe exactly as it is for `archive_camera`
    // (issue #80): each move/delete is independently guarded and crash-safe; a
    // concurrent guard-holder that disposes of a candidate during our yield just
    // makes our later disposal a source-gone no-op (dangling-row cleanup), and a
    // slightly stale `used`/`deficit` self-corrects on the next tick.
    // Underscore-prefixed: held purely for its RAII lock effect (never read), and
    // re-bound below to cycle the lock — the prefix keeps the unused-binding lint
    // quiet while `Drop` still releases the guard on every re-bind and at return.
    let mut _archive_guard = Some(ARCHIVE_GUARD.lock().await);
    let mut since_guard_yield: usize = 0;
    let policy_label: &str = policy.name.as_deref().unwrap_or("<unnamed>");

    // ── LIVE over-cap OR below physical free-space floor ───────────────────────
    //
    // The byte cap and the physical disk are INDEPENDENT failure domains (audit
    // P1 #7). Eviction fires if EITHER the policy's live total exceeds its byte
    // cap OR the live filesystem has dropped below the free-space floor — the
    // latter prevents the ENOSPC-records-nothing catastrophe even when the cap is
    // unset or mis-set. When below the floor we evict until the deficit is freed
    // AND (if a cap exists) under cap.
    {
        let cap_opt = policy.live_max_bytes.filter(|c| *c > 0);
        let mut used = db::policy_stage_bytes(pool, policy.id, SegmentStage::Live).await?;
        // Archive OFF → the live cap is the ONLY budget, so it must also account for
        // any residual stage=archive footage (archive turned off after footage was
        // archived). Otherwise that footage is uncapped and un-evictable, and a full
        // disk would evict recent LIVE footage while the orphan persists. No-op for
        // policies that never archived (archive bytes = 0).
        if !policy.archive_enabled {
            used += db::policy_stage_bytes(pool, policy.id, SegmentStage::Archive).await?;
        }

        // Resolve the live storage path to read free space (independent of whether
        // archiving is on). Resolve EXACTLY the way recording.rs does: the policy's
        // own `live_storage_id` if set, else the globally-configured default live
        // storage. (Previously a NULL `live_storage_id` — the common default-policy
        // case — left the floor unevaluated, so the free-space floor AND any
        // per-policy headroom silently never fired. Resolving the default closes
        // that gap so headroom works on every policy.) A missing/unresolvable
        // storage means we just can't read free space this tick — fall back to the
        // byte cap.
        let live_storage_for_floor: Option<Storage> = match policy.live_storage_id {
            Some(sid) => db::get_storage(pool, sid).await.ok().flatten(),
            None => db::get_storage_by_name(pool, &config.live_storage_name)
                .await
                .ok()
                .flatten(),
        };
        // `deficit` is how many bytes we must free to get back above the floor;
        // 0 when above the floor or free space can't be read. The per-policy
        // headroom overrides (NULL ⇒ env defaults) feed the SAME pure
        // `free_floor_decision`, so NULL-everywhere is byte-identical to before.
        let mut deficit: i64 = live_storage_for_floor
            .as_ref()
            .and_then(|s| {
                below_free_floor_for_policy(
                    &s.path,
                    policy.live_min_free_pct,
                    policy.live_min_free_bytes,
                )
            })
            .map(|(below, d)| if below { d } else { 0 })
            .unwrap_or(0);

        let over_cap = cap_opt.map(|cap| used > cap).unwrap_or(false);
        let below_floor = deficit > 0;

        // SPILL / low-water hysteresis. `spill` (NULL/0 ⇒ 0) is how far PAST the
        // trigger a fired eviction overshoots so it batches instead of nibbling one
        // segment per tick at the boundary. It NEVER changes the trigger: we pad
        // the deficit ONLY when already below the floor (so spill can't cause an
        // earlier free-floor trigger), and the live STOP target is `cap - spill`
        // (so spill can't cause an earlier cap trigger — `over_cap` was decided
        // against the true cap above). spill==0 ⇒ deficit unpadded, target==cap ⇒
        // identical to today.
        let spill = policy
            .live_spill_low_water_bytes
            .filter(|b| *b > 0)
            .unwrap_or(0);
        if below_floor {
            deficit = deficit.saturating_add(spill);
        }
        // Stop target = cap - spill. DEFENSIVE: the API rejects spill >= cap, but a
        // hand-edited DB could not — so if spill ever meets/exceeds the cap, degrade
        // to NO overshoot (drain to exactly the cap) rather than a 0 target that
        // would evict ALL live footage.
        let live_target = cap_opt.map(|cap| if spill < cap { cap - spill } else { cap });

        // Closure-free stop predicate: keep evicting while over cap OR below floor.
        let needs_eviction = over_cap || below_floor;

        if needs_eviction {
            // Resolve archive storage UP-FRONT when archiving is on. If it is
            // missing/unresolved we must NOT fall through to deleting
            // un-archived live footage — skip live eviction entirely.
            let archive_target: Option<(Storage, Storage)> = if policy.archive_enabled {
                match resolve_archive_dirs_for_policy(pool, policy).await {
                    Ok(pair) => Some(pair),
                    Err(e) => {
                        error!(
                            policy_id   = %policy.id,
                            policy_name = %policy_label,
                            error       = %e,
                            "size eviction: archive enabled but archive/live storage \
                             unresolved; SKIPPING live eviction (will not delete \
                             un-archived footage)"
                        );
                        // Skip the LIVE branch; fall through to the ARCHIVE branch
                        // below (archive_max_bytes still applies).
                        None
                    }
                }
            } else {
                None
            };

            // When archiving is on but storage couldn't be resolved, do not
            // touch live footage at all.
            let proceed_live = !policy.archive_enabled || archive_target.is_some();

            if proceed_live {
                // Pull only the OLDEST batch (audit P1 #9): the sweep consumes the
                // oldest prefix; if still over cap / below floor next tick re-queries.
                // Archive ON: evict only live-stage (the oldest live is MOVED to
                // archive). Archive OFF: evict the oldest footage regardless of stage
                // so residual stage=archive segments are reclaimed alongside live
                // (one shared budget), oldest-first. Both queries skip protected
                // bookmarks. For a policy that never archived, the any-stage query
                // returns the same rows as the live-only one (no archive segments).
                let live = if policy.archive_enabled {
                    db::list_policy_segments_oldest_first(
                        pool,
                        policy.id,
                        SegmentStage::Live,
                        Some(EVICTION_BATCH_LIMIT),
                    )
                    .await?
                } else {
                    db::list_policy_segments_oldest_first_any_stage(
                        pool,
                        policy.id,
                        Some(EVICTION_BATCH_LIMIT),
                    )
                    .await?
                };
                info!(
                    policy_id   = %policy.id,
                    policy_name = %policy_label,
                    used_bytes  = used,
                    cap_bytes   = ?cap_opt,
                    free_deficit_bytes = deficit,
                    candidates  = live.len(),
                    archiving   = policy.archive_enabled,
                    "size eviction: live footage over cap or below free-space floor; evicting oldest-first"
                );
                let mut storage_cache: std::collections::HashMap<Uuid, Storage> =
                    std::collections::HashMap::new();
                // Memoized per-source-storage answers for the ENOSPC-rescue
                // exception (see the SAFETY INVARIANT above), keyed by the
                // segment's own storage id (the archive root and the floor root
                // are both fixed for the whole sweep):
                //   same_fs_cache       — does the segment share the ARCHIVE fs
                //                          (so a move would free nothing)?
                //   same_fs_floor_cache — does the segment share the FLOOR fs
                //                          (the disk actually in deficit)?
                // The delete rescue requires BOTH: deleting a segment that is
                // NOT on the deficit disk frees zero bytes there yet destroys it
                // permanently (a repointed-storage config), so those fall
                // through to the normal footage-preserving MOVE instead.
                let mut same_fs_cache: std::collections::HashMap<Uuid, bool> =
                    std::collections::HashMap::new();
                let mut same_fs_floor_cache: std::collections::HashMap<Uuid, bool> =
                    std::collections::HashMap::new();
                let floor_root: Option<&Path> = live_storage_for_floor
                    .as_ref()
                    .map(|s| Path::new(s.path.as_str()));
                for seg in &live {
                    // Item 4: release + re-acquire ARCHIVE_GUARD every
                    // ARCHIVE_MOVE_BATCH disposals so the guard/scheduler tick is
                    // not pinned for the whole (up to EVICTION_BATCH_LIMIT) run.
                    if since_guard_yield >= ARCHIVE_MOVE_BATCH {
                        since_guard_yield = 0;
                        _archive_guard = None; // release the guard
                        tokio::task::yield_now().await;
                        _archive_guard = Some(ARCHIVE_GUARD.lock().await);
                    }
                    since_guard_yield += 1;
                    // Stop once BOTH conditions are satisfied: under the live TARGET
                    // (cap - spill, if a cap exists) AND the free-space deficit
                    // (already padded by spill when below floor) is cleared. With
                    // spill==0 the target is the cap and the deficit is unpadded, so
                    // this is the original stop condition.
                    let still_over_cap = live_target.map(|t| used > t).unwrap_or(false);
                    let still_below_floor = deficit > 0;
                    if !still_over_cap && !still_below_floor {
                        break;
                    }
                    if let Some((_live_storage, archive_storage)) = &archive_target {
                        // MOVE oldest live → archive. Resolve the source from the
                        // SEGMENT'S OWN storage (per-segment), NOT the policy's live
                        // storage — footage can live on a different disk than the
                        // policy currently points at (e.g. after a live_storage change),
                        // and resolving per-policy here would look in the wrong place
                        // and dangling-delete real footage's index rows.
                        let src_storage = match resolve_storage(
                            pool,
                            &mut storage_cache,
                            seg.storage_id,
                        )
                        .await
                        {
                            Ok(s) => s,
                            Err(e) => {
                                error!(
                                    policy_id  = %policy.id,
                                    segment_id = %seg.id,
                                    error      = %e,
                                    "size eviction: cannot resolve segment storage; stopping tick"
                                );
                                break;
                            }
                        };
                        let src_root = Path::new(&src_storage.path);
                        let archive_root = Path::new(&archive_storage.path);

                        // ── ENOSPC RESCUE (SAFETY INVARIANT exception above) ──
                        // While the free-space floor is in DEFICIT, the disposal
                        // must reduce USED bytes on the physical disk. An archive
                        // move onto the SAME filesystem frees nothing (default
                        // compose layout: /data/archive on the live disk) — the
                        // pre-fix sweep "moved" oldest live footage in place every
                        // tick until the disk hit 100% and ffmpeg ENOSPC-halted
                        // recording on every camera. Delete oldest-first instead,
                        // exactly like the archive-off arm (file-then-row, item
                        // 10; protected bookmarks already excluded by the query).
                        let move_frees_nothing = if still_below_floor {
                            // (a) segment shares the ARCHIVE fs → a move frees
                            //     nothing on it.
                            let shares_archive = match same_fs_cache.get(&src_storage.id).copied() {
                                Some(v) => v,
                                None => {
                                    let v = same_filesystem(src_root, archive_root).await;
                                    same_fs_cache.insert(src_storage.id, v);
                                    v
                                }
                            };
                            // (b) AND the segment lives on the FLOOR fs (the disk
                            //     actually in deficit) — otherwise deleting it
                            //     frees zero bytes on the deficit disk while
                            //     destroying footage permanently. Only checked
                            //     when (a) already holds and the floor storage is
                            //     known (it is, whenever still_below_floor).
                            let shares_floor = match (shares_archive, floor_root) {
                                (true, Some(fr)) => {
                                    match same_fs_floor_cache.get(&src_storage.id).copied() {
                                        Some(v) => v,
                                        None => {
                                            let v = same_filesystem(src_root, fr).await;
                                            same_fs_floor_cache.insert(src_storage.id, v);
                                            v
                                        }
                                    }
                                }
                                _ => false,
                            };
                            shares_archive && shares_floor
                        } else {
                            false
                        };
                        if move_frees_nothing {
                            match delete_segment_file_then_row(pool, seg, &mut storage_cache).await
                            {
                                Ok(()) => {
                                    used -= seg.size_bytes;
                                    deficit = (deficit - seg.size_bytes).max(0);
                                    warn!(
                                        policy_id  = %policy.id,
                                        segment_id = %seg.id,
                                        "free-space floor: archive shares the live \
                                         filesystem, so a move would free nothing; \
                                         deleted oldest live segment to free real bytes"
                                    );
                                    emit_premature_rollover_if_early(
                                        pool,
                                        seg,
                                        policy.live_retention_hours,
                                        "free-space floor eviction (archive on same filesystem)",
                                    )
                                    .await;
                                }
                                Err(e) => {
                                    error!(
                                        policy_id  = %policy.id,
                                        segment_id = %seg.id,
                                        error      = %e,
                                        "free-space floor: failed to delete over-floor \
                                         live segment"
                                    );
                                }
                            }
                            continue;
                        }

                        match move_segment_to_archive(
                            pool,
                            seg,
                            src_root,
                            archive_root,
                            archive_storage.id,
                        )
                        .await
                        {
                            Ok(()) => {
                                used -= seg.size_bytes;
                                // Deficit accounting (#278): a move helps the floor
                                // ONLY when the source bytes lived on the floor
                                // (deficit) filesystem. The old comment claimed a
                                // floor-deficit move "only reaches here when the
                                // archive is a DIFFERENT filesystem" — untrue for a
                                // repointed storage: the policy's oldest footage can
                                // sit on another disk entirely (or share the archive
                                // fs while the floor fs is elsewhere), in which case
                                // the move frees ZERO bytes on the deficit disk.
                                // Crediting it anyway "cleared" the deficit on paper
                                // each tick while the real disk kept filling toward
                                // the ffmpeg ENOSPC halt the floor exists to prevent.
                                if deficit > 0 {
                                    let src_on_floor_fs = match floor_root {
                                        Some(fr) => {
                                            match same_fs_floor_cache.get(&src_storage.id).copied()
                                            {
                                                Some(v) => v,
                                                None => {
                                                    let v = same_filesystem(src_root, fr).await;
                                                    same_fs_floor_cache.insert(src_storage.id, v);
                                                    v
                                                }
                                            }
                                        }
                                        // No floor storage resolved → nothing to
                                        // credit against (deficit only arises with
                                        // a known floor fs).
                                        None => false,
                                    };
                                    deficit = credit_move_against_deficit(
                                        deficit,
                                        seg.size_bytes,
                                        src_on_floor_fs,
                                    );
                                }
                                debug!(
                                    policy_id  = %policy.id,
                                    segment_id = %seg.id,
                                    "size eviction: live segment moved to archive"
                                );
                            }
                            Err(e) => {
                                // Distinguish a DANGLING ROW (the source file is
                                // already gone) from a SYSTEMIC failure (e.g. archive
                                // disk full). A missing source is per-segment, not
                                // systemic: clean the stale index row and keep going,
                                // so a single dangling row at the oldest position can't
                                // wedge the entire sweep (which would let live grow
                                // unbounded past the cap). A real IO failure WILL hit
                                // every remaining segment too, so we stop the tick.
                                let src_abs = src_root.join(&seg.path);
                                let src_gone =
                                    !tokio::fs::try_exists(&src_abs).await.unwrap_or(true);
                                if src_gone {
                                    warn!(
                                        policy_id  = %policy.id,
                                        segment_id = %seg.id,
                                        path       = %src_abs.display(),
                                        "size eviction: live source file missing; \
                                         deleting dangling row and continuing"
                                    );
                                    if let Err(de) = db::delete_segment_row(pool, seg.id).await {
                                        error!(
                                            policy_id  = %policy.id,
                                            segment_id = %seg.id,
                                            error      = %de,
                                            "size eviction: failed to delete dangling \
                                             row; stopping tick"
                                        );
                                        break;
                                    }
                                    used -= seg.size_bytes;
                                    continue;
                                }
                                error!(
                                    policy_id  = %policy.id,
                                    segment_id = %seg.id,
                                    error      = %e,
                                    "size eviction: failed to archive over-cap live \
                                     segment; leaving in place"
                                );
                                // Source still present → a real IO failure (e.g. archive
                                // disk full) will hit every remaining segment too — stop
                                // this tick and retry next tick rather than spam-failing
                                // the whole over-cap set.
                                break;
                            }
                        }
                    } else {
                        // Archive disabled → safe to DELETE oldest live (file
                        // then row, correctness item 10; NotFound-tolerant).
                        match delete_segment_file_then_row(pool, seg, &mut storage_cache).await {
                            Ok(()) => {
                                used -= seg.size_bytes;
                                deficit = (deficit - seg.size_bytes).max(0);
                                debug!(
                                    policy_id  = %policy.id,
                                    segment_id = %seg.id,
                                    "size eviction: live segment deleted (archive off)"
                                );
                                emit_premature_rollover_if_early(
                                    pool,
                                    seg,
                                    policy.live_retention_hours,
                                    "live cap/free-space eviction (archive off)",
                                )
                                .await;
                            }
                            Err(e) => {
                                error!(
                                    policy_id  = %policy.id,
                                    segment_id = %seg.id,
                                    error      = %e,
                                    "size eviction: failed to delete over-cap live segment"
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    // ── ARCHIVE over-cap ───────────────────────────────────────────────────────
    if let Some(cap) = policy.archive_max_bytes {
        if cap > 0 && policy.archive_enabled {
            let mut used = db::policy_stage_bytes(pool, policy.id, SegmentStage::Archive).await?;
            // Shared spill knob (same column the live branch uses): the TRIGGER is
            // still `used > cap`, but once fired we drain to `cap - spill` so archive
            // eviction also batches. spill==0 ⇒ target==cap ⇒ today's behaviour.
            let arch_spill = policy
                .live_spill_low_water_bytes
                .filter(|b| *b > 0)
                .unwrap_or(0);
            // DEFENSIVE (as in the live branch): degrade to no-overshoot if a bad
            // stored spill ever meets/exceeds the archive cap, so it can't zero the
            // target and delete ALL archived footage.
            let arch_target = if arch_spill < cap {
                cap - arch_spill
            } else {
                cap
            };
            if used > cap {
                let arch = db::list_policy_segments_oldest_first(
                    pool,
                    policy.id,
                    SegmentStage::Archive,
                    Some(EVICTION_BATCH_LIMIT),
                )
                .await?;
                info!(
                    policy_id   = %policy.id,
                    policy_name = %policy_label,
                    used_bytes  = used,
                    cap_bytes   = cap,
                    candidates  = arch.len(),
                    "size eviction: archive footage over policy cap; deleting oldest-first"
                );
                let mut storage_cache: std::collections::HashMap<Uuid, Storage> =
                    std::collections::HashMap::new();
                for seg in &arch {
                    // Item 4: same per-batch guard release as the live loop above.
                    if since_guard_yield >= ARCHIVE_MOVE_BATCH {
                        since_guard_yield = 0;
                        _archive_guard = None; // release the guard
                        tokio::task::yield_now().await;
                        _archive_guard = Some(ARCHIVE_GUARD.lock().await);
                    }
                    since_guard_yield += 1;
                    if used <= arch_target {
                        break;
                    }
                    match delete_segment_file_then_row(pool, seg, &mut storage_cache).await {
                        Ok(()) => {
                            used -= seg.size_bytes;
                            debug!(
                                policy_id  = %policy.id,
                                segment_id = %seg.id,
                                "size eviction: archive segment deleted"
                            );
                            if let Some(archive_hours) = archive_drain_retention_hours(policy) {
                                emit_premature_rollover_if_early(
                                    pool,
                                    seg,
                                    archive_hours,
                                    "archive cap eviction",
                                )
                                .await;
                            }
                        }
                        Err(e) => {
                            error!(
                                policy_id  = %policy.id,
                                segment_id = %seg.id,
                                error      = %e,
                                "size eviction: failed to delete over-cap archive segment"
                            );
                        }
                    }
                }
            }
        }
    }

    Ok(())
}

// ─── absolute max-retention sweep (data-minimization ceiling) ─────────────────

/// Enforce a policy's **absolute maximum-retention** cap
/// (`recording_policies.max_retention_days`): delete any footage under the policy
/// older than the cap, across BOTH the live and archive stages.
///
/// This is the "keep no longer than N days" upper bound requested by the EU/UK
/// legal review for data-minimization (GDPR Art. 5(1)(e) / UK DPA). It is
/// **opt-in and OFF by default** (`max_retention_days IS NULL`), so an existing
/// install is untouched and it can never surprise-delete footage until an
/// operator deliberately sets it. When set it is an ADDITIONAL constraint layered
/// over the per-tier retention windows and the size caps — it only ever removes
/// footage SOONER, never keeps it longer.
///
/// # Why this deliberately differs from the per-tier sweeps
///
/// [`live_retention_sweep`] intentionally skips `archive_enabled` cameras
/// (correctness item 7: the archiver owns their deletion) and only touches
/// `stage = 'live'`. The max-retention cap is a HARD CEILING with the opposite
/// requirement: footage older than the cap must be gone whether or not it was
/// archived and regardless of stage, or the operator's stated retention limit is
/// violated. So this sweep queries BOTH stages and does not exclude archiving
/// cameras. That is not a data-loss bug — deleting footage past an
/// operator-configured legal ceiling is the whole point; keeping it would be the
/// defect.
///
/// # Safety
///
/// - Serializes on [`ARCHIVE_GUARD`] so it can never delete a segment while a
///   cron/size-eviction archive MOVE (`copy → verify → index → delete source`,
///   correctness item 8) is mid-flight on the same footage.
/// - Deletes **file then index row** (correctness item 10) via the shared,
///   `NotFound`-tolerant [`delete_segment_file_then_row`], so a crash never
///   leaves a row pointing at a missing file and a pre-deleted file just cleans
///   its dangling row.
/// - Skips segments overlapping an active **protected bookmark** (enforced in the
///   SQL): an explicit human "protect from auto-delete" pin wins over the
///   automatic cap. Documented in `docs/RESPONSIBLE-USE.md`.
/// - Batch-limited ([`MAX_RETENTION_BATCH_LIMIT`]); if more remain the next tick
///   re-queries, so first enabling a short cap converges over a few ticks instead
///   of one huge delete.
///
/// Per-segment failures are logged and the sweep continues to the next segment
/// (unlike the size sweep, a max-retention pass is a routine time-based expiry,
/// not an urgent free-space rescue, so one stuck file must not wedge the rest).
///
/// # Errors
///
/// Returns an error only if the initial candidate query fails.
pub async fn max_retention_sweep(
    pool: &Pool,
    _config: &Config,
    policy: &RecordingPolicy,
) -> Result<()> {
    // OFF unless the operator set a positive day count. `<= 0` is treated as
    // "no cap" defensively (the API rejects it, but a hand-edited DB could not).
    let days = match policy.max_retention_days {
        Some(d) if d > 0 => d,
        _ => return Ok(()),
    };

    // Serialize against any concurrent archive move (see ARCHIVE_GUARD) so we
    // never delete a segment that a move is copying/verifying right now.
    let _archive_guard = ARCHIVE_GUARD.lock().await;

    let policy_label: &str = policy.name.as_deref().unwrap_or("<unnamed>");
    let cutoff = Utc::now() - Duration::days(i64::from(days));

    let segments = db::list_policy_segments_older_than_any_stage(
        pool,
        policy.id,
        cutoff,
        Some(MAX_RETENTION_BATCH_LIMIT),
    )
    .await
    .context("list_policy_segments_older_than_any_stage")?;

    if segments.is_empty() {
        return Ok(());
    }

    info!(
        policy_id   = %policy.id,
        policy_name = %policy_label,
        max_days    = days,
        cutoff      = %cutoff,
        candidates  = segments.len(),
        "max-retention: deleting footage past the absolute retention cap (oldest-first)"
    );

    let mut storage_cache: std::collections::HashMap<Uuid, Storage> =
        std::collections::HashMap::new();

    for seg in &segments {
        if let Err(e) = delete_segment_file_then_row(pool, seg, &mut storage_cache).await {
            // A real IO failure (not a tolerated NotFound) — log and move on so a
            // single stuck file can't block the rest of the cap. Retried next tick.
            error!(
                policy_id  = %policy.id,
                segment_id = %seg.id,
                error      = %e,
                "max-retention: failed to delete segment; leaving in place (retry next tick)"
            );
        }
    }

    Ok(())
}

/// Resolve (`live_storage`, `archive_storage`) rows from a policy directly.
///
/// Both `live_storage_id` and `archive_storage_id` must be set on the policy
/// and the corresponding `storages` rows must exist.  Returns an error
/// otherwise; the caller must then SKIP live eviction rather than deleting
/// un-archived footage (see SAFETY INVARIANT on
/// [`policy_size_eviction_sweep`]).
async fn resolve_archive_dirs_for_policy(
    pool: &Pool,
    policy: &RecordingPolicy,
) -> Result<(Storage, Storage)> {
    let policy_label: &str = policy.name.as_deref().unwrap_or("<unnamed>");

    let live_storage_id = policy.live_storage_id.with_context(|| {
        format!(
            "policy '{policy_label}' ({}) has no live_storage_id",
            policy.id
        )
    })?;
    let archive_storage_id = policy.archive_storage_id.with_context(|| {
        format!(
            "policy '{policy_label}' ({}) has no archive_storage_id",
            policy.id
        )
    })?;

    let live_storage = db::get_storage(pool, live_storage_id)
        .await
        .context("fetching live storage")?
        .with_context(|| format!("live storage {live_storage_id} not found"))?;
    let archive_storage = db::get_storage(pool, archive_storage_id)
        .await
        .context("fetching archive storage")?
        .with_context(|| format!("archive storage {archive_storage_id} not found"))?;

    Ok((live_storage, archive_storage))
}

/// Delete a segment's file then its index row (correctness item 10: file first,
/// row only on filesystem success; `NotFound` is tolerated so a dangling row is
/// still cleaned up). Shared by the size-eviction delete branches.
async fn delete_segment_file_then_row(
    pool: &Pool,
    seg: &Segment,
    storage_cache: &mut std::collections::HashMap<Uuid, Storage>,
) -> Result<()> {
    let storage = resolve_storage(pool, storage_cache, seg.storage_id).await?;
    let abs_path = Path::new(&storage.path).join(&seg.path);

    match tokio::fs::remove_file(&abs_path).await {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            warn!(
                segment_id = %seg.id,
                path       = %abs_path.display(),
                "size eviction: file not found; cleaning dangling row"
            );
        }
        Err(e) => {
            // Do NOT delete the row — the file might still be there (item 10).
            return Err(
                anyhow::Error::new(e).context(format!("remove_file {}", abs_path.display()))
            );
        }
    }

    db::delete_segment_row(pool, seg.id)
        .await
        .context("delete_segment_row")?;
    Ok(())
}

// ─── shared helpers ───────────────────────────────────────────────────────────

/// Resolve a storage row by ID, using an in-memory cache to avoid repeated
/// round-trips for the same storage within a single sweep.
async fn resolve_storage(
    pool: &Pool,
    cache: &mut std::collections::HashMap<Uuid, Storage>,
    storage_id: Uuid,
) -> Result<Storage> {
    if let Some(s) = cache.get(&storage_id) {
        return Ok(s.clone());
    }
    let s = db::get_storage(pool, storage_id)
        .await
        .context("get_storage")?
        .with_context(|| format!("storage {storage_id} not found"))?;
    cache.insert(storage_id, s.clone());
    Ok(s)
}

// ─── cron tracker ────────────────────────────────────────────────────────────

/// State tracker for per-camera cron schedule.
///
/// Wraps [`croner::Cron`] and remembers the end of the last evaluated window so
/// each cron occurrence fires exactly once, no matter how the scheduler ticks
/// land around it.
///
/// # Design
///
/// `is_due` uses CATCH-UP semantics (#84): it fires when the cron has an
/// occurrence in the half-open window `(last_checked, now]`. The old
/// implementation asked "does the pattern match the CURRENT minute?", which
/// silently skipped a run whenever two ticks straddled the matching minute (a
/// slow tick, a suspended VM, an archive run that overran the tick interval).
/// Duplicate calls within the same minute still fire at most once, because the
/// window advances to `now` on every evaluation.
pub struct CronTracker {
    cron: croner::Cron,
    /// The raw expression `cron` was parsed from, so a runtime edit of
    /// `archive_schedule` can be detected and re-parsed without a restart
    /// (#82 — see [`ensure_cron_tracker`]).
    schedule: String,
    /// End of the last evaluated window (UTC). `None` until the first
    /// `is_due` call establishes it.
    last_checked: Option<DateTime<Utc>>,
    /// A budget-bounded [`archive_camera`] run deferred part of this camera's
    /// backlog (issue #80); the scheduler continues it on the next tick
    /// without waiting for the next cron fire.
    backlog_pending: bool,
}

impl CronTracker {
    /// Parse an archive schedule expression and create a tracker.
    ///
    /// Supports both 5-field (`MIN HOUR DOM MON DOW`) and optional
    /// 6-field (`SEC MIN HOUR DOM MON DOW`) cron expressions, handled by
    /// croner's `with_seconds_optional` parser.
    ///
    /// # Errors
    ///
    /// Returns an error if the cron expression is syntactically invalid.
    ///
    /// # Examples
    ///
    /// ```ignore
    /// let tracker = CronTracker::new("0 3 * * *").unwrap();
    /// ```
    pub fn new(schedule: &str) -> Result<Self> {
        let cron = croner::Cron::new(schedule)
            .with_seconds_optional()
            .parse()
            .map_err(|e| anyhow::anyhow!("invalid cron expression '{schedule}': {e}"))?;
        Ok(Self {
            cron,
            schedule: schedule.to_owned(),
            last_checked: None,
            backlog_pending: false,
        })
    }

    /// Returns `true` if the cron has an occurrence in `(last_checked, now]`
    /// that has not fired yet — CATCH-UP semantics (#84), so a slow tick that
    /// straddles the matching minute cannot skip a scheduled run.
    ///
    /// # Algorithm
    ///
    /// 1. `window_start` = `last_checked`, or (first call) the start of the
    ///    current minute minus one second — preserving the original behaviour
    ///    of firing iff the process was up during the matching minute, and
    ///    never retro-firing occurrences from before startup.
    /// 2. Ask croner for the first occurrence STRICTLY AFTER `window_start`,
    ///    in LOCAL wall-clock time (DST-correct via chrono-tz) so e.g.
    ///    "0 2 * * *" fires at 02:00 local, not 02:00 UTC.
    /// 3. Fire iff that occurrence is `<= now`; advance `last_checked = now`
    ///    either way so each occurrence fires exactly once.
    pub fn is_due(&mut self, now: DateTime<Utc>, tz: chrono_tz::Tz) -> bool {
        use chrono::Timelike;

        // `last_checked` stays in UTC (a monotonic instant) — only the cron
        // occurrence lookup uses local wall-clock time.
        let window_start = self.last_checked.unwrap_or_else(|| {
            let now_minute = now
                .with_second(0)
                .and_then(|t| t.with_nanosecond(0))
                .unwrap_or(now);
            now_minute - Duration::seconds(1)
        });

        // Guard against a backwards clock step: never evaluate an
        // empty/negative window, and never move the window backwards.
        if now <= window_start {
            return false;
        }

        let after_local = window_start.with_timezone(&tz);
        match self.cron.find_next_occurrence(&after_local, false) {
            Ok(next) => {
                // Advance the window only on a successful evaluation, so a
                // transient croner error can't swallow an occurrence.
                self.last_checked = Some(now);
                next.with_timezone(&Utc) <= now
            }
            Err(e) => {
                error!(error = %e, "CronTracker::is_due: find_next_occurrence error");
                false
            }
        }
    }
}

// ─── unit tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── archive-stage drain retention (disable-archive orphan fix) ───────────

    /// Minimal RecordingPolicy for pure-logic tests (no DB).
    fn mk_drain_policy() -> crumb_common::types::RecordingPolicy {
        use crumb_common::types::{
            MotionSensitivity, RecordStream, RecordingMode, RecordingPolicy,
        };
        RecordingPolicy {
            id: uuid::Uuid::nil(),
            name: None,
            is_default: false,
            origin: "operator".to_owned(),
            mode: RecordingMode::Continuous,
            live_storage_id: None,
            live_retention_hours: 72,
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

    #[test]
    fn archive_drain_retention_semantics() {
        let mut p = mk_drain_policy();

        // Archive ENABLED: governed by archive_retention_hours; None ⇒ indefinite.
        p.archive_enabled = true;
        p.archive_retention_hours = Some(240);
        p.live_retention_hours = 72;
        assert_eq!(archive_drain_retention_hours(&p), Some(240));
        p.archive_retention_hours = None;
        assert_eq!(
            archive_drain_retention_hours(&p),
            None,
            "enabled + no archive retention ⇒ keep indefinitely on the archive tier"
        );
        p.archive_retention_hours = Some(0);
        assert_eq!(archive_drain_retention_hours(&p), None, "<=0 ⇒ indefinite");

        // Archive DISABLED: drain under archive retention when set (graceful)…
        p.archive_enabled = false;
        p.archive_retention_hours = Some(240);
        p.live_retention_hours = 72;
        assert_eq!(
            archive_drain_retention_hours(&p),
            Some(240),
            "disabled + archive retention set ⇒ wind down under that retention"
        );
        // …else bound by the live retention so it can't orphan forever…
        p.archive_retention_hours = None;
        p.live_retention_hours = 336;
        assert_eq!(
            archive_drain_retention_hours(&p),
            Some(336),
            "disabled + no archive retention ⇒ fall back to live retention"
        );
        // …and only None when BOTH are non-positive.
        p.live_retention_hours = 0;
        assert_eq!(archive_drain_retention_hours(&p), None);
    }

    // ── free-space floor (audit P1 #7) ───────────────────────────────────────

    #[test]
    fn free_floor_pure_decision_boundaries() {
        // 1 TB disk, 5% fractional floor, 50 GB absolute floor.
        let tb: i64 = 1024 * 1024 * 1024 * 1024;
        let gb: i64 = 1024 * 1024 * 1024;
        let frac = 0.05;
        let abs = 50 * gb;

        // On a 1 TB disk the absolute 50 GB floor IS a sane headroom (< half),
        // and it exceeds the 5% (~51 GB) … actually 5% of 1 TB ≈ 51.2 GB > 50 GB,
        // so the fractional floor dominates here. Free of 60 GB is above both.
        let (below, _) = free_floor_decision(60 * gb, tb, frac, abs);
        assert!(!below, "60 GB free on 1 TB is above the floor");
        // Free of 10 GB is below the floor → evict; deficit > 0.
        let (below, deficit) = free_floor_decision(10 * gb, tb, frac, abs);
        assert!(below, "10 GB free on 1 TB is below the floor");
        assert!(deficit > 0);

        // SMALL DISK GUARD: on a 2 GB disk the 50 GB absolute floor is NOT a
        // headroom (>= half the disk), so it must be IGNORED — only the 5%
        // fractional floor (~100 MB) applies. Free of 1 GB is comfortably above
        // it, so we must NOT perma-fire. (This was the bug that over-evicted the
        // test tmpfs.)
        let two_gb = 2 * gb;
        let (below, _) = free_floor_decision(gb, two_gb, 0.05, 50 * gb);
        assert!(
            !below,
            "absolute floor must not dominate a small disk (perma-eviction guard)"
        );
        // But a genuinely low small disk (free below 5%) still fires.
        let (below, _) = free_floor_decision(10 * 1024 * 1024, two_gb, 0.05, 50 * gb);
        assert!(
            below,
            "small disk truly below 5% must still trigger eviction"
        );
    }

    /// #278: an archive move may be credited against the floor deficit ONLY
    /// when its source bytes lived on the floor (deficit) filesystem. A move
    /// from any other disk frees nothing on the deficit disk and must leave
    /// the deficit untouched — the pre-fix unconditional credit "cleared" the
    /// deficit on paper each tick while the real disk filled toward ENOSPC.
    #[test]
    fn deficit_credited_only_for_floor_fs_moves() {
        // On the floor fs → credited, clamped at zero.
        assert_eq!(credit_move_against_deficit(1000, 400, true), 600);
        assert_eq!(credit_move_against_deficit(300, 400, true), 0);
        // NOT on the floor fs → deficit untouched (the fix).
        assert_eq!(credit_move_against_deficit(1000, 400, false), 1000);
        // No deficit → nothing to credit either way; negatives clamp.
        assert_eq!(credit_move_against_deficit(0, 400, true), 0);
        assert_eq!(credit_move_against_deficit(-5, 400, false), 0);
    }

    #[test]
    fn below_free_floor_on_real_temp_dir_is_readable() {
        // The temp dir's filesystem exists, so statvfs must return a reading
        // (Some) on Unix. We only assert it parses — the actual below/above
        // result depends on the host's free space, which we don't control.
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().to_str().expect("utf8");
        let result = below_free_floor(path);
        #[cfg(unix)]
        assert!(result.is_some(), "statvfs should read a real temp dir");
        #[cfg(not(unix))]
        let _ = result; // None on non-Unix is acceptable
    }

    #[test]
    fn below_free_floor_missing_path_is_none() {
        // A path that does not exist → statvfs fails → None (skip the floor).
        let result = below_free_floor("/this/path/does/not/exist/crumb-test-xyz");
        assert!(result.is_none());
    }

    // ── archive copy checksum (audit P2 #7) ──────────────────────────────────

    #[tokio::test]
    async fn copy_with_crc32_matches_independent_rehash() {
        let dir = tempfile::tempdir().expect("tempdir");
        let src = dir.path().join("src.bin");
        let dst = dir.path().join("dst.bin");
        let data: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
        tokio::fs::write(&src, &data).await.expect("write src");

        let (n, src_crc) = copy_with_crc32(&src, &dst).await.expect("copy");
        assert_eq!(n, data.len() as u64);

        // Re-hash the destination independently; must equal the source hash.
        let dst_crc = crc32_of_file(&dst).await.expect("rehash dst");
        assert_eq!(src_crc, dst_crc, "a clean copy must round-trip the crc32");

        // A tampered destination must NOT match (this is what the move's verify
        // catches — same-length corruption the byte-count check misses).
        let mut corrupted = tokio::fs::read(&dst).await.expect("read dst");
        corrupted[100] ^= 0xFF; // flip one byte, same length
        tokio::fs::write(&dst, &corrupted)
            .await
            .expect("rewrite dst");
        let tampered_crc = crc32_of_file(&dst).await.expect("rehash tampered");
        assert_ne!(
            src_crc, tampered_crc,
            "a same-length bit-flip must change the crc32"
        );
    }

    /// Regression for issue #70: a copy whose source and destination are the
    /// SAME file must refuse rather than truncate the file to zero. Reproduces
    /// the seed-default (archive path == live path) trigger with one on-disk
    /// file addressed by two paths; the file's bytes must survive intact.
    #[tokio::test]
    async fn copy_with_crc32_refuses_same_file_and_preserves_bytes() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("seg.bin");
        let data: Vec<u8> = (0..4096u32).map(|i| (i % 253) as u8).collect();
        tokio::fs::write(&path, &data).await.expect("write");

        // Same physical file via a symlink alias → dev+ino identical.
        let alias = dir.path().join("alias.bin");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&path, &alias).expect("symlink");
        #[cfg(not(unix))]
        tokio::fs::copy(&path, &alias)
            .await
            .map(|_| ())
            .unwrap_or(());

        let res = copy_with_crc32(&path, &alias).await;
        assert!(
            res.is_err(),
            "copying a file onto itself must error, not truncate"
        );

        // The original bytes must be completely intact (never opened for write).
        let after = tokio::fs::read(&path).await.expect("read back");
        assert_eq!(
            after, data,
            "the segment must survive a same-file copy attempt"
        );
    }

    // ── CronTracker ──────────────────────────────────────────────────────────

    #[test]
    fn cron_tracker_fires_on_matching_minute() {
        let mut tracker = CronTracker::new("0 3 * * *").expect("valid cron");
        // Build a DateTime that matches "0 3 * * *": 03:00 UTC on any day.
        let fire_time = chrono::DateTime::parse_from_rfc3339("2026-01-15T03:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert!(
            tracker.is_due(fire_time, chrono_tz::Tz::UTC),
            "should fire at 03:00 UTC"
        );
    }

    #[test]
    fn cron_tracker_does_not_fire_twice_in_same_minute() {
        let mut tracker = CronTracker::new("0 3 * * *").expect("valid cron");
        let fire_time = chrono::DateTime::parse_from_rfc3339("2026-01-15T03:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let fire_time_30s = chrono::DateTime::parse_from_rfc3339("2026-01-15T03:00:30Z")
            .unwrap()
            .with_timezone(&Utc);

        assert!(
            tracker.is_due(fire_time, chrono_tz::Tz::UTC),
            "first call should fire"
        );
        assert!(
            !tracker.is_due(fire_time_30s, chrono_tz::Tz::UTC),
            "second call in same minute must not fire"
        );
    }

    #[test]
    fn cron_tracker_does_not_fire_on_non_matching_minute() {
        let mut tracker = CronTracker::new("0 3 * * *").expect("valid cron");
        let non_fire = chrono::DateTime::parse_from_rfc3339("2026-01-15T04:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert!(
            !tracker.is_due(non_fire, chrono_tz::Tz::UTC),
            "should not fire at 04:00"
        );
    }

    #[test]
    fn cron_tracker_fires_again_next_day() {
        let mut tracker = CronTracker::new("0 3 * * *").expect("valid cron");
        let day1 = chrono::DateTime::parse_from_rfc3339("2026-01-15T03:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let day2 = chrono::DateTime::parse_from_rfc3339("2026-01-16T03:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        assert!(
            tracker.is_due(day1, chrono_tz::Tz::UTC),
            "day 1 should fire"
        );
        assert!(
            tracker.is_due(day2, chrono_tz::Tz::UTC),
            "day 2 should fire again"
        );
    }

    #[test]
    fn cron_tracker_rejects_invalid_expression() {
        let result = CronTracker::new("not a cron expression");
        assert!(result.is_err(), "invalid expression should error");
    }

    /// #84 (catch-up): a slow tick that STRADDLES the matching minute — one
    /// tick lands just before it, the next lands just after — must still fire
    /// the schedule exactly once. The old exact-minute matching skipped the
    /// run for a whole day in this case.
    #[test]
    fn cron_tracker_catches_up_when_tick_straddles_the_minute() {
        let mut tracker = CronTracker::new("0 3 * * *").expect("valid cron");
        let before = chrono::DateTime::parse_from_rfc3339("2026-01-15T02:59:30Z")
            .unwrap()
            .with_timezone(&Utc);
        // The next tick arrives LATE — the 03:00 minute itself was never sampled.
        let after = chrono::DateTime::parse_from_rfc3339("2026-01-15T03:01:10Z")
            .unwrap()
            .with_timezone(&Utc);
        let later = chrono::DateTime::parse_from_rfc3339("2026-01-15T03:02:10Z")
            .unwrap()
            .with_timezone(&Utc);

        assert!(
            !tracker.is_due(before, chrono_tz::Tz::UTC),
            "not due before the boundary"
        );
        assert!(
            tracker.is_due(after, chrono_tz::Tz::UTC),
            "an occurrence inside the straddled window must fire (catch-up)"
        );
        assert!(
            !tracker.is_due(later, chrono_tz::Tz::UTC),
            "the caught-up occurrence fires exactly once"
        );
    }

    /// #82: editing `archive_schedule` must take effect WITHOUT a recorder
    /// restart — the cached tracker is re-parsed when the stored expression
    /// differs, the old schedule stops firing, and an invalid replacement
    /// removes the entry (reported once per tick until fixed).
    #[test]
    fn cron_tracker_resyncs_on_schedule_edit_without_restart() {
        let mut trackers: std::collections::HashMap<Uuid, CronTracker> =
            std::collections::HashMap::new();
        let cam = Uuid::new_v4();
        let at = |s: &str| {
            chrono::DateTime::parse_from_rfc3339(s)
                .unwrap()
                .with_timezone(&Utc)
        };

        // Initial schedule: 03:00 daily. Establish the window before the edit.
        let tracker = ensure_cron_tracker(&mut trackers, cam, "0 3 * * *").expect("parse");
        assert!(!tracker.is_due(at("2026-01-15T01:59:00Z"), chrono_tz::Tz::UTC));

        // Operator edits the schedule to 02:00 daily: the tracker must be
        // re-parsed (schedule string updated) and the NEW schedule fires at
        // 02:00 — pre-fix the stale cached cron kept firing 03:00 forever.
        let tracker = ensure_cron_tracker(&mut trackers, cam, "0 2 * * *").expect("re-parse");
        assert_eq!(
            tracker.schedule, "0 2 * * *",
            "tracker stores the new expression"
        );
        assert!(
            tracker.is_due(at("2026-01-15T02:00:10Z"), chrono_tz::Tz::UTC),
            "edited schedule must fire without a restart"
        );
        // …and the OLD schedule no longer fires.
        assert!(
            !tracker.is_due(at("2026-01-15T03:00:00Z"), chrono_tz::Tz::UTC),
            "the replaced schedule must not fire any more"
        );

        // An unchanged schedule is NOT re-parsed (window preserved: the same
        // occurrence does not fire twice across ensure calls).
        let tracker = ensure_cron_tracker(&mut trackers, cam, "0 2 * * *").expect("noop");
        assert!(!tracker.is_due(at("2026-01-15T03:01:00Z"), chrono_tz::Tz::UTC));

        // An INVALID edit errors and removes the stale entry.
        assert!(ensure_cron_tracker(&mut trackers, cam, "not a cron").is_err());
        assert!(
            !trackers.contains_key(&cam),
            "invalid replacement must drop the stale tracker (old cron must not keep firing)"
        );
    }

    #[test]
    fn cron_tracker_every_minute() {
        let mut tracker = CronTracker::new("* * * * *").expect("valid cron");
        let t1 = chrono::DateTime::parse_from_rfc3339("2026-01-15T10:01:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let t2 = chrono::DateTime::parse_from_rfc3339("2026-01-15T10:02:00Z")
            .unwrap()
            .with_timezone(&Utc);

        assert!(
            tracker.is_due(t1, chrono_tz::Tz::UTC),
            "minute 1 should fire"
        );
        assert!(
            tracker.is_due(t2, chrono_tz::Tz::UTC),
            "minute 2 should also fire"
        );
    }

    // ── archive_relative_path ────────────────────────────────────────────────

    #[test]
    fn archive_relative_path_structure() {
        let camera_id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        let ts = chrono::DateTime::parse_from_rfc3339("2026-06-14T03:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        let rel = archive_relative_path(
            &camera_id,
            &ts,
            "550e8400-e29b-41d4-a716-446655440000/2026/06/14/20260614T030000Z.mp4",
        )
        .unwrap();

        let s = rel.to_str().unwrap().replace('\\', "/");
        assert!(
            s.starts_with("550e8400-e29b-41d4-a716-446655440000/2026/06/14/"),
            "path should start with camera_id/year/month/day: {s}"
        );
        assert!(
            s.ends_with("20260614T030000Z.mp4"),
            "filename should be preserved: {s}"
        );
    }

    #[test]
    fn archive_relative_path_bare_filename() {
        let camera_id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        let ts = chrono::DateTime::parse_from_rfc3339("2026-06-14T03:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        // Live path might just be a bare filename too.
        let rel = archive_relative_path(&camera_id, &ts, "20260614T030000Z.mp4").unwrap();
        let s = rel.to_str().unwrap().replace('\\', "/");
        assert!(s.ends_with("20260614T030000Z.mp4"), "{s}");
    }

    // ── policy_size_eviction_sweep — DB + filesystem integration ─────────────
    //
    // These exercise the real eviction path (DB + on-disk files), not just the
    // CronTracker unit. They are **opt-in**: each returns early (passing) unless
    // `CRUMB_TEST_DATABASE_URL` points at a reachable, *throwaway* Postgres (e.g.
    // build-host's `docker run --rm postgres`). Each test allocates its OWN uniquely
    // named schema (search_path) and drops it on the way out, so two tests — or a
    // re-run — never collide and nothing leaks into an existing DB.
    //
    //   CRUMB_TEST_DATABASE_URL='postgresql://crumb:secret@127.0.0.1:5544/crumb' \
    //     cargo test -p crumb-recorder size_eviction
    mod size_eviction_integration {
        use super::*;
        use crumb_common::config::Config;
        use crumb_common::db::InsertSegmentParams;
        use crumb_common::types::SegmentStream;
        use deadpool_postgres::Pool;

        /// Read the opt-in throwaway-DB URL, or `None` to skip the test.
        ///
        /// Prefers the recorder-specific `CRUMB_TEST_DATABASE_URL` but falls back
        /// to the workspace-wide `TEST_DATABASE_URL` that CI already sets. Without
        /// that fallback these footage-critical integration tests silently skipped
        /// in CI — the gate was green *because* they weren't running (audit
        /// 2026-07-05). The `assert!` makes a skip under CI fail LOUD so a future
        /// env-var rename can never resurrect the silent-skip.
        fn test_db_url() -> Option<String> {
            let url = std::env::var("CRUMB_TEST_DATABASE_URL")
                .or_else(|_| std::env::var("TEST_DATABASE_URL"))
                .ok()
                .filter(|s| !s.trim().is_empty());
            let in_ci = std::env::var("CI")
                .map(|v| {
                    let v = v.trim();
                    !v.is_empty() && v != "0" && !v.eq_ignore_ascii_case("false")
                })
                .unwrap_or(false);
            assert!(
                url.is_some() || !in_ci,
                "CI is set but neither CRUMB_TEST_DATABASE_URL nor TEST_DATABASE_URL points at a \
                 Postgres: the recorder DB-integration suite would skip silently. Set one to a \
                 throwaway Postgres (see this module's header)."
            );
            url
        }

        /// A fixture owning the per-test schema, pool, temp storage dirs, and the
        /// ids of the rows it created. `Drop` best-effort-drops the schema so a
        /// throwaway DB stays clean across re-runs.
        struct Fixture {
            pool: Pool,
            schema: String,
            base_url: String,
            _live_dir: tempfile::TempDir,
            _archive_dir: tempfile::TempDir,
            live_storage_id: Uuid,
            archive_storage_id: Uuid,
            camera_id: Uuid,
        }

        impl Drop for Fixture {
            fn drop(&mut self) {
                // Drop the schema on a fresh blocking connection (the pool's
                // search_path points *into* the schema we're deleting, so use a
                // plain client without that search_path).
                let url = self.base_url.clone();
                let schema = self.schema.clone();
                // Best-effort: ignore errors (the throwaway DB is discarded anyway).
                let _ = std::thread::spawn(move || {
                    let rt = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .expect("rt");
                    rt.block_on(async move {
                        if let Ok((client, conn)) =
                            tokio_postgres::connect(&url, tokio_postgres::NoTls).await
                        {
                            tokio::spawn(conn);
                            let _ = client
                                .batch_execute(&format!("DROP SCHEMA IF EXISTS {schema} CASCADE;"))
                                .await;
                        }
                    });
                })
                .join();
            }
        }

        /// Stand up an isolated schema with the four tables the sweep touches,
        /// plus one storage pair / policy / camera. The caps (`live_max_bytes` /
        /// `archive_max_bytes`, either `None`) and `archive_enabled` are exactly
        /// what each test needs to drive a specific eviction branch.
        async fn setup(
            base_url: &str,
            live_max_bytes: Option<i64>,
            archive_max_bytes: Option<i64>,
            archive_enabled: bool,
        ) -> Fixture {
            // Unique schema so concurrent / repeated runs never collide.
            let schema = format!("crumb_test_{}", Uuid::new_v4().simple());

            // 1. Create the schema on a plain connection.
            {
                let (client, conn) = tokio_postgres::connect(base_url, tokio_postgres::NoTls)
                    .await
                    .expect("connect to CRUMB_TEST_DATABASE_URL");
                tokio::spawn(conn);
                client
                    .batch_execute(&format!("CREATE SCHEMA {schema};"))
                    .await
                    .expect("create schema");
            }

            // 2. Build a pool whose connections default into our schema. libpq
            //    `options=-c search_path=<schema>` (URL-encoded) does this.
            let sep = if base_url.contains('?') { '&' } else { '?' };
            let pool_url = format!("{base_url}{sep}options=-c%20search_path%3D{schema}");
            let pool = crumb_common::db::build_pool(&pool_url, 4).expect("build_pool");

            // 3. Minimal schema: exactly the columns the sweep + accessors read.
            //    (We create the tables directly rather than replaying the 7
            //    migration files so the test can't drift with migration ordering.)
            //
            //    camera_groups / camera_group_members are included so that
            //    `list_policy_segments_oldest_first` and `policy_stage_bytes`
            //    (which join those tables) work even in this single-camera
            //    fixture. The `name` column on recording_policies is likewise
            //    present so policy_from_row / camera_from_row can be used
            //    unmodified.
            {
                let client = pool.get().await.expect("conn");
                client
                    .batch_execute(
                        r"
                        CREATE TABLE storages (
                            id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            name        text NOT NULL UNIQUE,
                            path        text NOT NULL,
                            total_bytes bigint,
                            icon        text,
                            created_at  timestamptz NOT NULL DEFAULT now()
                        );
                        CREATE TABLE recording_policies (
                            id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            name                    text,
                            is_default              boolean NOT NULL DEFAULT false,
                            origin                  text NOT NULL DEFAULT 'operator',
                            mode                    text NOT NULL DEFAULT 'continuous',
                            live_storage_id         uuid REFERENCES storages(id),
                            live_retention_hours    integer NOT NULL DEFAULT 48,
                            archive_enabled         boolean NOT NULL DEFAULT false,
                            archive_storage_id      uuid REFERENCES storages(id),
                            archive_schedule        text DEFAULT '0 3 * * *',
                            archive_retention_hours integer,
                            live_max_bytes          bigint,
                            archive_max_bytes       bigint,
                            live_min_free_pct          real,
                            live_min_free_bytes        bigint,
                            live_spill_low_water_bytes bigint,
                            max_retention_days      integer,
                            motion_pre_seconds      integer NOT NULL DEFAULT 5,
                            motion_post_seconds     integer NOT NULL DEFAULT 10,
                            motion_sensitivity      text NOT NULL DEFAULT 'dynamic',
                            motion_threshold        real,
                            motion_keyframes_only   boolean NOT NULL DEFAULT false,
                            record_stream           text NOT NULL DEFAULT 'main',
                            record_audio            boolean NOT NULL DEFAULT true
                        );
                        CREATE TABLE camera_groups (
                            id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            name      text NOT NULL,
                            policy_id uuid REFERENCES recording_policies(id)
                        );
                        CREATE TABLE camera_group_members (
                            camera_id uuid NOT NULL,
                            group_id  uuid NOT NULL,
                            PRIMARY KEY (camera_id, group_id)
                        );
                        CREATE TABLE cameras (
                            id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            name           text NOT NULL,
                            enabled        boolean NOT NULL DEFAULT true,
                            go2rtc_name    text NOT NULL UNIQUE,
                            main_url       text NOT NULL,
                            sub_url        text,
                            source_url     text,
                            source_sub_url text,
                            policy_id      uuid REFERENCES recording_policies(id),
                            motion_mask    jsonb,
                            onvif_motion   boolean NOT NULL DEFAULT false,
                            motion_source    text NOT NULL DEFAULT 'pixel',
                            motion_algorithm text NOT NULL DEFAULT 'census',
                            camera_type    text,
                            icon           text,
                            motion_grid_cols smallint,
                            motion_grid_rows smallint,
                            served_by      text NOT NULL DEFAULT 'crumb',
                            source_camera_name text,
                            onvif_host     text,
                            onvif_port     integer,
                            onvif_user     text,
                            onvif_password text,
                            created_at     timestamptz NOT NULL DEFAULT now()
                        );
                        CREATE TABLE segments (
                            id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            camera_id    uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
                            storage_id   uuid NOT NULL REFERENCES storages(id),
                            stage        text NOT NULL DEFAULT 'live',
                            path         text NOT NULL,
                            stream       text NOT NULL,
                            start_ts     timestamptz NOT NULL,
                            end_ts       timestamptz NOT NULL,
                            duration_ms  integer NOT NULL,
                            has_motion   boolean NOT NULL DEFAULT false,
                            motion_score real NOT NULL DEFAULT 0,
                            size_bytes   bigint NOT NULL,
                            -- Mirror migration 0026: insert_segment writes
                            -- these, so the fixture must carry them.
                            motion_bbox_x real,
                            motion_bbox_y real,
                            motion_bbox_w real,
                            motion_bbox_h real
                        );
                        -- Mirror migration 0009: insert_segment now UPSERTs on
                        -- ON CONFLICT (camera_id, stream, start_ts), which needs
                        -- this unique index to exist in the test schema too.
                        CREATE UNIQUE INDEX segments_uniq_cam_stream_start
                            ON segments (camera_id, stream, start_ts);
                        CREATE TABLE bookmarks (
                            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            camera_id uuid NOT NULL,
                            ts timestamptz NOT NULL,
                            description text,
                            created_by uuid,
                            protect_until timestamptz,
                            protect_start_ts timestamptz,
                            protect_end_ts timestamptz,
                            created_at timestamptz NOT NULL DEFAULT now()
                        );
                        -- Mirror migration 0019: the per-policy queries under test
                        -- (policy_stage_bytes / list_policy_segments_oldest_first /
                        -- list_policy_segments_on_storage / …) now resolve the
                        -- effective policy through this view, so the test schema must
                        -- define it too. Same own→group→default COALESCE as prod.
                        CREATE VIEW v_camera_effective_policy AS
                        SELECT
                            c.id AS c_id, c.name AS c_name, c.enabled AS c_enabled,
                            c.go2rtc_name AS c_go2rtc_name, c.main_url AS c_main_url,
                            c.sub_url AS c_sub_url, c.source_url AS c_source_url,
                            c.source_sub_url AS c_source_sub_url, c.policy_id AS c_policy_id,
                            m.group_id AS c_group_id, c.motion_mask AS c_motion_mask,
                            c.onvif_motion AS c_onvif_motion, c.motion_source AS c_motion_source,
                            c.motion_algorithm AS c_motion_algorithm, c.camera_type AS c_camera_type,
                            c.icon AS c_icon, c.motion_grid_cols AS c_motion_grid_cols,
                            c.motion_grid_rows AS c_motion_grid_rows, c.created_at AS c_created_at,
                            c.served_by AS c_served_by, c.source_camera_name AS c_source_camera_name,
                            c.onvif_host AS c_onvif_host, c.onvif_port AS c_onvif_port,
                            c.onvif_user AS c_onvif_user, c.onvif_password AS c_onvif_password,
                            p.id AS p_id, p.name AS p_name, p.is_default AS p_is_default,
                            p.mode AS p_mode, p.live_storage_id AS p_live_storage_id,
                            p.live_retention_hours AS p_live_retention_hours,
                            p.archive_enabled AS p_archive_enabled,
                            p.archive_storage_id AS p_archive_storage_id,
                            p.archive_schedule AS p_archive_schedule,
                            p.archive_retention_hours AS p_archive_retention_hours,
                            p.live_max_bytes AS p_live_max_bytes,
                            p.archive_max_bytes AS p_archive_max_bytes,
                            p.live_min_free_pct AS p_live_min_free_pct,
                            p.live_min_free_bytes AS p_live_min_free_bytes,
                            p.live_spill_low_water_bytes AS p_live_spill_low_water_bytes,
                            p.motion_pre_seconds AS p_motion_pre_seconds,
                            p.motion_post_seconds AS p_motion_post_seconds,
                            p.motion_sensitivity AS p_motion_sensitivity,
                            p.motion_threshold AS p_motion_threshold,
                            p.motion_keyframes_only AS p_motion_keyframes_only,
                            p.record_stream AS p_record_stream, p.record_audio AS p_record_audio,
                            p.max_retention_days AS p_max_retention_days
                        FROM cameras c
                        LEFT JOIN camera_group_members m ON m.camera_id = c.id
                        LEFT JOIN camera_groups g ON g.id = m.group_id
                        JOIN recording_policies p ON p.id = COALESCE(
                            c.policy_id, g.policy_id,
                            (SELECT id FROM recording_policies WHERE is_default LIMIT 1)
                        );
                        ",
                    )
                    .await
                    .expect("create tables");
            }

            // 4. Temp storage dirs + storage rows.
            let live_dir = tempfile::Builder::new()
                .prefix("crumb-live")
                .tempdir()
                .expect("live tmp");
            let archive_dir = tempfile::Builder::new()
                .prefix("crumb-archive")
                .tempdir()
                .expect("archive tmp");
            let live_storage = db::upsert_storage(
                &pool,
                "test-live",
                live_dir.path().to_str().expect("utf8 live path"),
            )
            .await
            .expect("upsert live storage");
            let archive_storage = db::upsert_storage(
                &pool,
                "test-archive",
                archive_dir.path().to_str().expect("utf8 archive path"),
            )
            .await
            .expect("upsert archive storage");

            // 5. Policy (caps/archive set by the caller) + camera.
            let camera_id;
            {
                let client = pool.get().await.expect("conn");
                let policy_row = client
                    .query_one(
                        "INSERT INTO recording_policies
                            (name, is_default, live_storage_id, archive_storage_id,
                             live_max_bytes, archive_max_bytes, archive_enabled)
                         VALUES ('Default', true, $1, $2, $3, $4, $5)
                         RETURNING id",
                        &[
                            &live_storage.id,
                            &archive_storage.id,
                            &live_max_bytes,
                            &archive_max_bytes,
                            &archive_enabled,
                        ],
                    )
                    .await
                    .expect("insert policy");
                let policy_id: Uuid = policy_row.get(0);

                let cam_row = client
                    .query_one(
                        "INSERT INTO cameras (name, go2rtc_name, main_url, policy_id)
                         VALUES ('Test Cam', $1, 'rtsp://x/main', $2)
                         RETURNING id",
                        &[&format!("cam_{}", Uuid::new_v4().simple()), &policy_id],
                    )
                    .await
                    .expect("insert camera");
                camera_id = cam_row.get(0);
            }

            Fixture {
                pool,
                schema,
                base_url: base_url.to_owned(),
                _live_dir: live_dir,
                _archive_dir: archive_dir,
                live_storage_id: live_storage.id,
                archive_storage_id: archive_storage.id,
                camera_id,
            }
        }

        /// Write a real file under `storage_path/rel` of `size` bytes and insert a
        /// matching segment row. Returns the inserted segment id + its rel path.
        #[allow(clippy::too_many_arguments)]
        async fn add_segment(
            fx: &Fixture,
            storage_id: Uuid,
            storage_path: &std::path::Path,
            stage: SegmentStage,
            rel: &str,
            start: DateTime<Utc>,
            size: i64,
        ) {
            let abs = storage_path.join(rel);
            if let Some(parent) = abs.parent() {
                tokio::fs::create_dir_all(parent).await.expect("mkdir seg");
            }
            tokio::fs::write(&abs, vec![0u8; size as usize])
                .await
                .expect("write seg file");

            db::insert_segment(
                &fx.pool,
                &InsertSegmentParams {
                    camera_id: fx.camera_id,
                    storage_id,
                    stage,
                    path: rel.to_owned(),
                    stream: SegmentStream::Main,
                    start_ts: start,
                    end_ts: start + Duration::seconds(4),
                    duration_ms: 4000,
                    has_motion: false,
                    motion_score: 0.0,
                    size_bytes: size,
                    motion_bbox: None,
                },
            )
            .await
            .expect("insert segment");
        }

        async fn load_camera(fx: &Fixture) -> Camera {
            db::get_camera(&fx.pool, fx.camera_id)
                .await
                .expect("get_camera")
                .expect("camera exists")
        }

        async fn default_policy_id(fx: &Fixture) -> Uuid {
            let client = fx.pool.get().await.expect("conn");
            client
                .query_one(
                    "SELECT id FROM recording_policies WHERE is_default LIMIT 1",
                    &[],
                )
                .await
                .expect("default policy")
                .get(0)
        }

        /// The "Change storage" drain must relocate footage SAFELY: the file lands
        /// on the new disk at the SAME relative path, the source is deleted, the row
        /// flips `storage_id` (keeping stage + path), and progress is recorded — and
        /// a second run is a clean no-op (idempotent). This is the data-loss-risk
        /// path, so it asserts conservation on both disks + the DB.
        #[tokio::test]
        async fn change_storage_drain_relocates_footage() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, None, None, false).await;
            db::ensure_storage_migrations_table(&fx.pool)
                .await
                .expect("ensure migrations table");

            // Two live segments on the LIVE disk under the camera's date tree.
            let start = Utc::now() - Duration::hours(2);
            let rel1 = format!("{}/2026/06/21/a.mp4", fx.camera_id);
            let rel2 = format!("{}/2026/06/21/b.mp4", fx.camera_id);
            add_segment(
                &fx,
                fx.live_storage_id,
                fx._live_dir.path(),
                SegmentStage::Live,
                &rel1,
                start,
                4096,
            )
            .await;
            add_segment(
                &fx,
                fx.live_storage_id,
                fx._live_dir.path(),
                SegmentStage::Live,
                &rel2,
                start + Duration::seconds(10),
                8192,
            )
            .await;

            let policy_id = default_policy_id(&fx).await;
            let mig = db::create_storage_migration(
                &fx.pool,
                policy_id,
                fx.live_storage_id,
                fx.archive_storage_id,
                2,
            )
            .await
            .expect("create migration");

            // The worker claims a 'pending' migration (-> 'running') before draining;
            // run_storage_migration now re-reads status per batch and aborts unless it
            // is still 'running' (the #9/#10 cancel control plane). Mirror that claim so
            // the drain proceeds in this direct-call test.
            db::set_migration_status(&fx.pool, mig.id, "running", None)
                .await
                .expect("set running");

            // Drain.
            run_storage_migration(&fx.pool, &mig)
                .await
                .expect("drain ok");

            // Files: gone from LIVE, present on ARCHIVE at the SAME relative path.
            for rel in [&rel1, &rel2] {
                assert!(
                    !fx._live_dir.path().join(rel).exists(),
                    "source must be deleted after move: {rel}"
                );
                assert!(
                    fx._archive_dir.path().join(rel).exists(),
                    "destination must exist at the same rel path: {rel}"
                );
            }

            // DB: both rows now on the target storage, stage + path unchanged.
            let segs = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(segs.len(), 2);
            for s in &segs {
                assert_eq!(s.storage_id, fx.archive_storage_id, "row flipped to target");
                assert_eq!(
                    s.stage,
                    SegmentStage::Live,
                    "stage preserved (not archived)"
                );
                assert!(s.path == rel1 || s.path == rel2, "relative path preserved");
            }

            // Progress recorded.
            let after = db::get_storage_migration(&fx.pool, mig.id)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(after.moved_segments, 2);
            assert_eq!(after.moved_bytes, 4096 + 8192);

            // Idempotent: re-running drains nothing (all already on target) → Ok.
            run_storage_migration(&fx.pool, &mig)
                .await
                .expect("second drain is a clean no-op");
        }

        /// Insert two segments with the SAME (camera_id, stream, start_ts): the
        /// ON CONFLICT UPSERT must COLLAPSE them into ONE row, keeping the LARGER
        /// size_bytes / later end_ts (audit P0 #3 / P1 #5 — kills the dup-row
        /// class at the DB layer). Pre-fix this forked a second row; the prod 815
        /// dup groups + double-counted budget were exactly this.
        #[tokio::test]
        async fn insert_segment_on_conflict_collapses() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, None, None, false).await;

            let start = Utc::now() - Duration::hours(1);
            let mk = |size: i64, motion: bool| db::InsertSegmentParams {
                camera_id: fx.camera_id,
                storage_id: fx.live_storage_id,
                stage: SegmentStage::Live,
                path: "dup.mp4".to_owned(),
                stream: SegmentStream::Main,
                start_ts: start,
                end_ts: start + Duration::seconds(4),
                duration_ms: 4000,
                has_motion: motion,
                motion_score: if motion { 0.5 } else { 0.0 },
                size_bytes: size,
                motion_bbox: None,
            };

            // First insert: a 28-byte skeleton with no motion.
            let id1 = db::insert_segment(&fx.pool, &mk(28, false))
                .await
                .expect("insert 1");
            // Second insert at the SAME key: the real, larger segment WITH motion.
            let id2 = db::insert_segment(&fx.pool, &mk(1_000_000, true))
                .await
                .expect("insert 2 (upsert)");

            // Same row id returned (it UPDATEd, did not fork).
            assert_eq!(id1, id2, "second insert must UPSERT the same row, not fork");

            // Exactly ONE row for the camera, with the GREATEST size + motion OR-ed.
            let all = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(all.len(), 1, "duplicate key must collapse to one row");
            assert_eq!(all[0].size_bytes, 1_000_000, "GREATEST(size) kept");
            assert!(
                all[0].has_motion,
                "motion must not be erased by the reindex"
            );

            // A LATER insert with a SMALLER size must NOT shrink the row.
            db::insert_segment(&fx.pool, &mk(500, false))
                .await
                .expect("insert 3 (smaller)");
            let after = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(after.len(), 1);
            assert_eq!(
                after[0].size_bytes, 1_000_000,
                "GREATEST must keep the larger size; a skeleton can't shrink a real row"
            );
            assert!(after[0].has_motion, "motion OR is monotone — stays true");
        }

        /// The archive move must ABORT IN THE SAFE DIRECTION when verification
        /// fails: the bad destination is removed, the SOURCE is KEPT, and the row
        /// stays live (audit GAP 2 / P1 #2 — never destroy the only copy). Here we
        /// trip the size-verify by lying about size_bytes; the checksum-verify path
        /// (P2 #7) aborts identically (it `bail`s before the source delete too).
        #[tokio::test]
        async fn archive_move_verify_failure_keeps_source() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, None, None, true).await;

            let live_path = fx._live_dir.path().to_path_buf();
            let archive_path = fx._archive_dir.path().to_path_buf();
            let start = Utc::now() - Duration::hours(5);

            // Write a 100-byte file but record size_bytes = 999 (a deliberate lie
            // so the dst-size verify fails — the same bail the checksum mismatch
            // takes, before any source delete).
            let rel = "verify.mp4";
            let abs = live_path.join(rel);
            tokio::fs::write(&abs, vec![7u8; 100]).await.expect("write");
            let seg_id = db::insert_segment(
                &fx.pool,
                &db::InsertSegmentParams {
                    camera_id: fx.camera_id,
                    storage_id: fx.live_storage_id,
                    stage: SegmentStage::Live,
                    path: rel.to_owned(),
                    stream: SegmentStream::Main,
                    start_ts: start,
                    end_ts: start + Duration::seconds(4),
                    duration_ms: 4000,
                    has_motion: false,
                    motion_score: 0.0,
                    size_bytes: 999, // LIE → verify fails
                    motion_bbox: None,
                },
            )
            .await
            .expect("insert");

            let seg = db::get_segment(&fx.pool, seg_id)
                .await
                .unwrap()
                .expect("seg");

            let err = move_segment_to_archive(
                &fx.pool,
                &seg,
                &live_path,
                &archive_path,
                fx.archive_storage_id,
            )
            .await;
            assert!(err.is_err(), "verify mismatch must abort the move");

            // SAFE-DIRECTION INVARIANTS:
            //  * the source file is still present (the only good copy preserved),
            assert!(
                live_path.join(rel).exists(),
                "source must NOT be deleted when verify fails"
            );
            //  * the row is unchanged (still live, still pointing at the source),
            let after = db::get_segment(&fx.pool, seg_id)
                .await
                .unwrap()
                .expect("seg still exists");
            assert_eq!(after.stage, SegmentStage::Live, "row must stay live");
            assert_eq!(after.storage_id, fx.live_storage_id);
            //  * no stray archive file was left behind.
            assert!(
                !archive_path.join(rel).exists(),
                "incomplete archive dst must be cleaned up"
            );
        }

        /// Issue #84: a FAILED copy must not leave a partial destination file
        /// behind. Simulates the retry-after-interruption shape: a stale
        /// partial dst already sits at the exact archive destination and the
        /// source file is missing, so `copy_with_crc32` errors at open — the
        /// copy error path must best-effort remove the destination before
        /// returning (mirroring the size/crc verify branches).
        #[tokio::test]
        async fn archive_move_copy_failure_removes_partial_dst() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, None, None, true).await;

            let live_path = fx._live_dir.path().to_path_buf();
            let archive_path = fx._archive_dir.path().to_path_buf();
            let start = Utc::now() - Duration::hours(5);

            // A row whose SOURCE file does not exist → the streaming copy
            // fails at `open src` before writing a byte.
            let rel = "gone.mp4";
            let seg_id = db::insert_segment(
                &fx.pool,
                &db::InsertSegmentParams {
                    camera_id: fx.camera_id,
                    storage_id: fx.live_storage_id,
                    stage: SegmentStage::Live,
                    path: rel.to_owned(),
                    stream: SegmentStream::Main,
                    start_ts: start,
                    end_ts: start + Duration::seconds(4),
                    duration_ms: 4000,
                    has_motion: false,
                    motion_score: 0.0,
                    size_bytes: 100,
                    motion_bbox: None,
                },
            )
            .await
            .expect("insert");
            let seg = db::get_segment(&fx.pool, seg_id)
                .await
                .unwrap()
                .expect("seg");

            // Pre-create a stale PARTIAL destination at the exact path the
            // move computes (leftover of a previously interrupted attempt).
            let dst_rel =
                archive_relative_path(&seg.camera_id, &seg.start_ts, &seg.path).expect("dst rel");
            let dst_abs = archive_path.join(&dst_rel);
            tokio::fs::create_dir_all(dst_abs.parent().expect("parent"))
                .await
                .expect("mkdir dst");
            tokio::fs::write(&dst_abs, vec![9u8; 37])
                .await
                .expect("write stale partial dst");

            let res = move_segment_to_archive(
                &fx.pool,
                &seg,
                &live_path,
                &archive_path,
                fx.archive_storage_id,
            )
            .await;
            assert!(res.is_err(), "copying a missing source must error");
            assert!(
                !dst_abs.exists(),
                "the copy error path must remove the partial destination (issue #84)"
            );
            // The row is untouched — still live, still pointing at the source.
            let after = db::get_segment(&fx.pool, seg_id)
                .await
                .unwrap()
                .expect("row survives a failed copy");
            assert_eq!(after.stage, SegmentStage::Live);
            assert_eq!(after.storage_id, fx.live_storage_id);
        }

        /// Issue #80: an archive run is wall-time bounded. With an already-
        /// expired deadline NOTHING is processed — the whole backlog is
        /// reported deferred and no footage is touched — and a later run with
        /// budget headroom drains the SAME backlog to completion, proving
        /// deferral loses nothing.
        #[tokio::test]
        async fn archive_camera_budget_defers_backlog_without_data_loss() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, None, None, true).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            // Well past the fixture's default live_retention_hours (48) so all
            // three segments are archive-eligible.
            let t0 = Utc::now() - Duration::hours(100);
            for i in 0..3 {
                add_segment(
                    &fx,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    &format!("bud{i}.mp4"),
                    t0 + Duration::minutes(i),
                    100,
                )
                .await;
            }
            let camera = load_camera(&fx).await;

            // (1) Deadline already expired → everything deferred, untouched.
            let outcome = archive_camera(&fx.pool, &config, &camera, std::time::Instant::now())
                .await
                .expect("bounded run ok");
            assert_eq!(
                outcome.deferred, 3,
                "an exhausted budget defers the whole backlog"
            );
            assert!(
                outcome.backlog_pending(),
                "a deferred backlog must flag the continuation"
            );
            let all = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(all.len(), 3);
            assert!(
                all.iter().all(|s| s.stage == SegmentStage::Live),
                "a deferred backlog must not be touched: {all:?}"
            );
            for i in 0..3 {
                assert!(
                    live_path.join(format!("bud{i}.mp4")).exists(),
                    "source bud{i} must be untouched by deferral"
                );
            }

            // (2) A later run with headroom drains the same backlog fully.
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3600);
            let outcome = archive_camera(&fx.pool, &config, &camera, deadline)
                .await
                .expect("full run ok");
            assert_eq!(
                outcome.deferred, 0,
                "with budget headroom the backlog fully drains"
            );
            assert!(
                !outcome.backlog_pending(),
                "a drained, non-truncated run must clear the continuation"
            );
            let all = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(all.len(), 3, "no rows lost across deferral + drain");
            assert!(
                all.iter().all(|s| s.stage == SegmentStage::Archive),
                "all segments archived after the follow-up run: {all:?}"
            );
            for i in 0..3 {
                assert!(
                    !live_path.join(format!("bud{i}.mp4")).exists(),
                    "source bud{i} removed after the verified move"
                );
            }
        }

        /// Issue #80 follow-up: the eligibility LISTING itself is bounded. A
        /// run whose listing FILLED the limit must report the backlog as
        /// pending even when every listed segment was processed within budget
        /// (a fully-processed but truncated batch may hide more eligible rows
        /// behind the LIMIT), so the next tick re-queries; successive bounded
        /// runs drain the whole backlog with nothing lost.
        #[tokio::test]
        async fn archive_camera_truncated_listing_flags_backlog_and_drains() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, None, None, true).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            // Well past the fixture's default live_retention_hours (48) so all
            // three segments are archive-eligible.
            let t0 = Utc::now() - Duration::hours(100);
            for i in 0..3 {
                add_segment(
                    &fx,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    &format!("lim{i}.mp4"),
                    t0 + Duration::minutes(i),
                    100,
                )
                .await;
            }
            let camera = load_camera(&fx).await;
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3600);

            // Run 1 with list_limit=2: lists exactly 2 (== limit), processes
            // BOTH within budget → deferred == 0, but the truncated listing
            // must still flag pending backlog (pre-fix semantics would have
            // cleared backlog_pending here and stranded lim2 until the next
            // cron fire).
            let outcome = archive_camera_bounded(&fx.pool, &config, &camera, deadline, 2)
                .await
                .expect("run 1 ok");
            assert_eq!(outcome.deferred, 0, "both listed segments processed");
            assert!(
                outcome.listing_truncated,
                "a listing that fills the limit must be flagged truncated"
            );
            assert!(
                outcome.backlog_pending(),
                "a truncated listing IS pending backlog even when fully processed"
            );
            let archived_now =
                db::camera_stage_bytes(&fx.pool, fx.camera_id, SegmentStage::Archive)
                    .await
                    .unwrap();
            assert_eq!(archived_now, 200, "the two oldest were archived in run 1");

            // Run 2: only lim2 remains eligible → lists 1 (< limit), drains it,
            // and the continuation stops.
            let outcome = archive_camera_bounded(&fx.pool, &config, &camera, deadline, 2)
                .await
                .expect("run 2 ok");
            assert_eq!(outcome.deferred, 0);
            assert!(
                !outcome.listing_truncated,
                "a short listing means the backlog is fully drained"
            );
            assert!(
                !outcome.backlog_pending(),
                "the continuation must stop once the backlog drains"
            );

            // Nothing lost across the bounded runs: all three rows archived.
            let all = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(all.len(), 3, "no rows lost across bounded runs");
            assert!(
                all.iter().all(|s| s.stage == SegmentStage::Archive),
                "all segments archived after the continuation drains: {all:?}"
            );
        }

        /// LIVE over-cap with archiving ON ⇒ oldest live segments MOVE to archive
        /// (files relocated, rows flip to stage=archive); nothing is deleted.
        #[tokio::test]
        async fn live_over_cap_archives_oldest_not_deletes() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            // live cap = 250 bytes; archive on, no archive cap.
            let fx = setup(&url, Some(250), None, true).await;
            std::env::set_var("DATABASE_URL", "unused://"); // Config::from_env needs it
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            let t0 = Utc::now() - Duration::hours(10);
            // 4 × 100B live = 400B, over the 250B cap → expect 2 oldest moved.
            for i in 0..4 {
                add_segment(
                    &fx,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    &format!("seg{i}.mp4"),
                    t0 + Duration::minutes(i),
                    100,
                )
                .await;
            }

            let camera = load_camera(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &camera.policy)
                .await
                .expect("sweep ok");

            // Nothing deleted: all 4 rows still present.
            let all = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(all.len(), 4, "no rows should be deleted when archiving");

            // Live now under cap (≤ 250).
            let live_used = db::camera_stage_bytes(&fx.pool, fx.camera_id, SegmentStage::Live)
                .await
                .unwrap();
            assert!(
                live_used <= 250,
                "live should be under cap, got {live_used}"
            );

            // The two OLDEST (seg0, seg1) are now archive-stage, with files in the
            // archive dir and gone from live.
            let archived: Vec<_> = all
                .iter()
                .filter(|s| s.stage == SegmentStage::Archive)
                .collect();
            assert_eq!(archived.len(), 2, "two oldest should be archived");
            for seg in &archived {
                assert_eq!(seg.storage_id, fx.archive_storage_id);
                let abs = fx._archive_dir.path().join(&seg.path);
                assert!(
                    abs.exists(),
                    "archived file must exist at {}",
                    abs.display()
                );
            }
            // seg0/seg1 source files removed from live.
            assert!(!fx._live_dir.path().join("seg0.mp4").exists());
            assert!(!fx._live_dir.path().join("seg1.mp4").exists());
        }

        /// LIVE over-cap with archiving ON, but the OLDEST segment's source file
        /// is MISSING (a dangling row, e.g. a cutover artifact). The sweep must
        /// NOT wedge on it: it deletes the dangling row and CONTINUES archiving
        /// the next-oldest real segments until under cap. Regression test for the
        /// break-on-any-failure bug that let live grow unbounded past the cap.
        #[tokio::test]
        async fn live_over_cap_skips_dangling_row_and_continues() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            // live cap = 250 bytes; archive on, no archive cap.
            let fx = setup(&url, Some(250), None, true).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            let t0 = Utc::now() - Duration::hours(10);
            // 4 × 100B live = 400B, over the 250B cap.
            for i in 0..4 {
                add_segment(
                    &fx,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    &format!("seg{i}.mp4"),
                    t0 + Duration::minutes(i),
                    100,
                )
                .await;
            }

            // Make the OLDEST segment (seg0) a DANGLING ROW: remove its file but
            // keep its row. Pre-fix, the sweep would break here and never get
            // under cap (the oldest candidate can never be moved).
            tokio::fs::remove_file(live_path.join("seg0.mp4"))
                .await
                .expect("rm seg0 file");

            let camera = load_camera(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &camera.policy)
                .await
                .expect("sweep ok");

            let all = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();

            // The dangling row was cleaned (deleted, not moved).
            assert!(
                !all.iter().any(|s| s.path.ends_with("seg0.mp4")),
                "dangling seg0 row should be deleted"
            );

            // Live is back under cap — proving the sweep CONTINUED past the
            // dangling row instead of wedging on it.
            let live_used = db::camera_stage_bytes(&fx.pool, fx.camera_id, SegmentStage::Live)
                .await
                .unwrap();
            assert!(
                live_used <= 250,
                "live should be under cap after skipping dangling row, got {live_used}"
            );

            // The next-oldest REAL segment (seg1) was moved to archive instead.
            assert!(
                all.iter()
                    .any(|s| s.stage == SegmentStage::Archive && s.path.ends_with("seg1.mp4")),
                "next-oldest real segment should have been archived"
            );
        }

        /// ARCHIVE over-cap ⇒ oldest archive segments DELETED (file + row).
        #[tokio::test]
        async fn archive_over_cap_deletes_oldest() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, None, Some(250), true).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let archive_path = fx._archive_dir.path().to_path_buf();
            let t0 = Utc::now() - Duration::hours(50);
            // 4 × 100B archive = 400B, over 250B cap → expect 2 oldest deleted.
            for i in 0..4 {
                add_segment(
                    &fx,
                    fx.archive_storage_id,
                    &archive_path,
                    SegmentStage::Archive,
                    &format!("arc{i}.mp4"),
                    t0 + Duration::minutes(i),
                    100,
                )
                .await;
            }

            let camera = load_camera(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &camera.policy)
                .await
                .expect("sweep ok");

            let all = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(all.len(), 2, "two oldest archive rows should be deleted");
            // Oldest two files gone from disk.
            assert!(!fx._archive_dir.path().join("arc0.mp4").exists());
            assert!(!fx._archive_dir.path().join("arc1.mp4").exists());
            // Newest two remain.
            assert!(fx._archive_dir.path().join("arc2.mp4").exists());
            assert!(fx._archive_dir.path().join("arc3.mp4").exists());

            let used = db::camera_stage_bytes(&fx.pool, fx.camera_id, SegmentStage::Archive)
                .await
                .unwrap();
            assert!(used <= 250, "archive should be under cap, got {used}");
        }

        /// LIVE over-cap with archiving OFF ⇒ oldest live segments DELETED.
        #[tokio::test]
        async fn live_over_cap_archive_off_deletes_oldest() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, Some(250), None, false).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            let t0 = Utc::now() - Duration::hours(10);
            for i in 0..4 {
                add_segment(
                    &fx,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    &format!("d{i}.mp4"),
                    t0 + Duration::minutes(i),
                    100,
                )
                .await;
            }

            let camera = load_camera(&fx).await;
            // Drive via the new per-policy path so this test exercises
            // policy_size_eviction_sweep even on the single-camera case.
            policy_size_eviction_sweep(&fx.pool, &config, &camera.policy)
                .await
                .expect("sweep ok");

            let all = db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
                .await
                .unwrap();
            assert_eq!(all.len(), 2, "two oldest live rows should be deleted");
            assert!(!fx._live_dir.path().join("d0.mp4").exists());
            assert!(!fx._live_dir.path().join("d1.mp4").exists());
            assert!(fx._live_dir.path().join("d2.mp4").exists());
        }

        /// A PROTECTED bookmark keeps its clip's segment from being evicted even
        /// when the policy is over its size cap: the sweep skips the protected
        /// (oldest) segment and evicts younger ones to get under cap instead.
        #[tokio::test]
        async fn protected_bookmark_survives_size_eviction() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup(&url, Some(250), None, false).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            let t0 = Utc::now() - Duration::hours(10);
            for i in 0..4 {
                add_segment(
                    &fx,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    &format!("d{i}.mp4"),
                    t0 + Duration::minutes(i),
                    100,
                )
                .await;
            }

            // Protect the OLDEST segment (d0 @ t0) for 1 day.
            db::create_bookmark(
                &fx.pool,
                fx.camera_id,
                t0,
                Some("evidence"),
                None,
                Some(Utc::now() + Duration::days(1)),
                // Tight window around d0 only — segments are 1 min apart, so keep
                // this well under 60s so it doesn't also cover d1.
                Some(t0 - Duration::seconds(5)),
                Some(t0 + Duration::seconds(5)),
            )
            .await
            .expect("create protected bookmark");

            let camera = load_camera(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &camera.policy)
                .await
                .expect("sweep ok");

            // 4×100 = 400 over a 250 cap. d0 is protected → skipped; the sweep evicts
            // d1 then d2 (→ 200, under cap). d0 + d3 survive.
            assert!(
                fx._live_dir.path().join("d0.mp4").exists(),
                "protected oldest segment must survive eviction"
            );
            assert!(
                !fx._live_dir.path().join("d1.mp4").exists(),
                "d1 should be evicted"
            );
            assert!(
                !fx._live_dir.path().join("d2.mp4").exists(),
                "d2 should be evicted"
            );
            assert!(
                fx._live_dir.path().join("d3.mp4").exists(),
                "d3 should be kept"
            );
        }

        // ── per-policy shared-budget tests ────────────────────────────────────
        //
        // The fixture below is a superset of `setup()`: it creates the
        // `camera_groups` / `camera_group_members` tables (needed by
        // `list_policy_segments_oldest_first`) and the `name` column on
        // `recording_policies`, then inserts TWO cameras on the same policy so
        // we can verify that the cap is enforced as a SHARED TOTAL.

        /// Schema + data needed to test per-policy eviction with multiple cameras.
        struct PolicyFixture {
            pool: Pool,
            schema: String,
            base_url: String,
            _live_dir: tempfile::TempDir,
            _archive_dir: tempfile::TempDir,
            live_storage_id: Uuid,
            archive_storage_id: Uuid,
            /// Two cameras sharing the same policy.
            camera_a_id: Uuid,
            camera_b_id: Uuid,
            policy_id: Uuid,
        }

        impl Drop for PolicyFixture {
            fn drop(&mut self) {
                let url = self.base_url.clone();
                let schema = self.schema.clone();
                let _ = std::thread::spawn(move || {
                    let rt = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .expect("rt");
                    rt.block_on(async move {
                        if let Ok((client, conn)) =
                            tokio_postgres::connect(&url, tokio_postgres::NoTls).await
                        {
                            tokio::spawn(conn);
                            let _ = client
                                .batch_execute(&format!("DROP SCHEMA IF EXISTS {schema} CASCADE;"))
                                .await;
                        }
                    });
                })
                .join();
            }
        }

        async fn setup_policy(
            base_url: &str,
            live_max_bytes: Option<i64>,
            archive_max_bytes: Option<i64>,
            archive_enabled: bool,
        ) -> PolicyFixture {
            let schema = format!("crumb_policy_test_{}", Uuid::new_v4().simple());

            {
                let (client, conn) = tokio_postgres::connect(base_url, tokio_postgres::NoTls)
                    .await
                    .expect("connect");
                tokio::spawn(conn);
                client
                    .batch_execute(&format!("CREATE SCHEMA {schema};"))
                    .await
                    .expect("create schema");
            }

            let sep = if base_url.contains('?') { '&' } else { '?' };
            let pool_url = format!("{base_url}{sep}options=-c%20search_path%3D{schema}");
            let pool = crumb_common::db::build_pool(&pool_url, 4).expect("build_pool");

            {
                let client = pool.get().await.expect("conn");
                client
                    .batch_execute(
                        r"
                        CREATE TABLE storages (
                            id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            name        text NOT NULL UNIQUE,
                            path        text NOT NULL,
                            total_bytes bigint,
                            icon        text,
                            created_at  timestamptz NOT NULL DEFAULT now()
                        );
                        CREATE TABLE recording_policies (
                            id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            name                    text,
                            is_default              boolean NOT NULL DEFAULT false,
                            origin                  text NOT NULL DEFAULT 'operator',
                            mode                    text NOT NULL DEFAULT 'continuous',
                            live_storage_id         uuid REFERENCES storages(id),
                            live_retention_hours    integer NOT NULL DEFAULT 48,
                            archive_enabled         boolean NOT NULL DEFAULT false,
                            archive_storage_id      uuid REFERENCES storages(id),
                            archive_schedule        text DEFAULT '0 3 * * *',
                            archive_retention_hours integer,
                            live_max_bytes          bigint,
                            archive_max_bytes       bigint,
                            live_min_free_pct          real,
                            live_min_free_bytes        bigint,
                            live_spill_low_water_bytes bigint,
                            max_retention_days      integer,
                            motion_pre_seconds      integer NOT NULL DEFAULT 5,
                            motion_post_seconds     integer NOT NULL DEFAULT 10,
                            motion_sensitivity      text NOT NULL DEFAULT 'dynamic',
                            motion_threshold        real,
                            motion_keyframes_only   boolean NOT NULL DEFAULT false,
                            record_stream           text NOT NULL DEFAULT 'main',
                            record_audio            boolean NOT NULL DEFAULT true
                        );
                        CREATE TABLE camera_groups (
                            id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            name      text NOT NULL,
                            policy_id uuid REFERENCES recording_policies(id)
                        );
                        CREATE TABLE camera_group_members (
                            camera_id uuid NOT NULL,
                            group_id  uuid NOT NULL,
                            PRIMARY KEY (camera_id, group_id)
                        );
                        CREATE TABLE cameras (
                            id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            name           text NOT NULL,
                            enabled        boolean NOT NULL DEFAULT true,
                            go2rtc_name    text NOT NULL UNIQUE,
                            main_url       text NOT NULL,
                            sub_url        text,
                            source_url     text,
                            source_sub_url text,
                            policy_id      uuid REFERENCES recording_policies(id),
                            motion_mask    jsonb,
                            onvif_motion   boolean NOT NULL DEFAULT false,
                            motion_source    text NOT NULL DEFAULT 'pixel',
                            motion_algorithm text NOT NULL DEFAULT 'census',
                            camera_type    text,
                            icon           text,
                            motion_grid_cols smallint,
                            motion_grid_rows smallint,
                            served_by      text NOT NULL DEFAULT 'crumb',
                            source_camera_name text,
                            onvif_host     text,
                            onvif_port     integer,
                            onvif_user     text,
                            onvif_password text,
                            created_at     timestamptz NOT NULL DEFAULT now()
                        );
                        CREATE TABLE segments (
                            id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            camera_id    uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
                            storage_id   uuid NOT NULL REFERENCES storages(id),
                            stage        text NOT NULL DEFAULT 'live',
                            path         text NOT NULL,
                            stream       text NOT NULL,
                            start_ts     timestamptz NOT NULL,
                            end_ts       timestamptz NOT NULL,
                            duration_ms  integer NOT NULL,
                            has_motion   boolean NOT NULL DEFAULT false,
                            motion_score real NOT NULL DEFAULT 0,
                            size_bytes   bigint NOT NULL,
                            -- Mirror migration 0026: insert_segment writes
                            -- these, so the fixture must carry them.
                            motion_bbox_x real,
                            motion_bbox_y real,
                            motion_bbox_w real,
                            motion_bbox_h real
                        );
                        -- Mirror migration 0009: insert_segment now UPSERTs on
                        -- ON CONFLICT (camera_id, stream, start_ts), which needs
                        -- this unique index to exist in the test schema too.
                        CREATE UNIQUE INDEX segments_uniq_cam_stream_start
                            ON segments (camera_id, stream, start_ts);
                        CREATE TABLE bookmarks (
                            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                            camera_id uuid NOT NULL,
                            ts timestamptz NOT NULL,
                            description text,
                            created_by uuid,
                            protect_until timestamptz,
                            protect_start_ts timestamptz,
                            protect_end_ts timestamptz,
                            created_at timestamptz NOT NULL DEFAULT now()
                        );
                        -- Mirror migration 0019: the per-policy queries under test
                        -- (policy_stage_bytes / list_policy_segments_oldest_first /
                        -- list_policy_segments_on_storage / …) now resolve the
                        -- effective policy through this view, so the test schema must
                        -- define it too. Same own→group→default COALESCE as prod.
                        CREATE VIEW v_camera_effective_policy AS
                        SELECT
                            c.id AS c_id, c.name AS c_name, c.enabled AS c_enabled,
                            c.go2rtc_name AS c_go2rtc_name, c.main_url AS c_main_url,
                            c.sub_url AS c_sub_url, c.source_url AS c_source_url,
                            c.source_sub_url AS c_source_sub_url, c.policy_id AS c_policy_id,
                            m.group_id AS c_group_id, c.motion_mask AS c_motion_mask,
                            c.onvif_motion AS c_onvif_motion, c.motion_source AS c_motion_source,
                            c.motion_algorithm AS c_motion_algorithm, c.camera_type AS c_camera_type,
                            c.icon AS c_icon, c.motion_grid_cols AS c_motion_grid_cols,
                            c.motion_grid_rows AS c_motion_grid_rows, c.created_at AS c_created_at,
                            c.served_by AS c_served_by, c.source_camera_name AS c_source_camera_name,
                            c.onvif_host AS c_onvif_host, c.onvif_port AS c_onvif_port,
                            c.onvif_user AS c_onvif_user, c.onvif_password AS c_onvif_password,
                            p.id AS p_id, p.name AS p_name, p.is_default AS p_is_default,
                            p.mode AS p_mode, p.live_storage_id AS p_live_storage_id,
                            p.live_retention_hours AS p_live_retention_hours,
                            p.archive_enabled AS p_archive_enabled,
                            p.archive_storage_id AS p_archive_storage_id,
                            p.archive_schedule AS p_archive_schedule,
                            p.archive_retention_hours AS p_archive_retention_hours,
                            p.live_max_bytes AS p_live_max_bytes,
                            p.archive_max_bytes AS p_archive_max_bytes,
                            p.live_min_free_pct AS p_live_min_free_pct,
                            p.live_min_free_bytes AS p_live_min_free_bytes,
                            p.live_spill_low_water_bytes AS p_live_spill_low_water_bytes,
                            p.motion_pre_seconds AS p_motion_pre_seconds,
                            p.motion_post_seconds AS p_motion_post_seconds,
                            p.motion_sensitivity AS p_motion_sensitivity,
                            p.motion_threshold AS p_motion_threshold,
                            p.motion_keyframes_only AS p_motion_keyframes_only,
                            p.record_stream AS p_record_stream, p.record_audio AS p_record_audio,
                            p.max_retention_days AS p_max_retention_days
                        FROM cameras c
                        LEFT JOIN camera_group_members m ON m.camera_id = c.id
                        LEFT JOIN camera_groups g ON g.id = m.group_id
                        JOIN recording_policies p ON p.id = COALESCE(
                            c.policy_id, g.policy_id,
                            (SELECT id FROM recording_policies WHERE is_default LIMIT 1)
                        );
                        ",
                    )
                    .await
                    .expect("create tables");
            }

            let live_dir = tempfile::Builder::new()
                .prefix("crumb-live-p")
                .tempdir()
                .expect("live tmp");
            let archive_dir = tempfile::Builder::new()
                .prefix("crumb-archive-p")
                .tempdir()
                .expect("archive tmp");

            let live_storage = db::upsert_storage(
                &pool,
                "test-live-p",
                live_dir.path().to_str().expect("utf8"),
            )
            .await
            .expect("upsert live storage");
            let archive_storage = db::upsert_storage(
                &pool,
                "test-archive-p",
                archive_dir.path().to_str().expect("utf8"),
            )
            .await
            .expect("upsert archive storage");

            let (policy_id, camera_a_id, camera_b_id) = {
                let client = pool.get().await.expect("conn");
                let policy_row = client
                    .query_one(
                        "INSERT INTO recording_policies
                            (name, is_default, live_storage_id, archive_storage_id,
                             live_max_bytes, archive_max_bytes, archive_enabled)
                         VALUES ('TestPolicy', true, $1, $2, $3, $4, $5)
                         RETURNING id",
                        &[
                            &live_storage.id,
                            &archive_storage.id,
                            &live_max_bytes,
                            &archive_max_bytes,
                            &archive_enabled,
                        ],
                    )
                    .await
                    .expect("insert policy");
                let policy_id: Uuid = policy_row.get(0);

                let row_a = client
                    .query_one(
                        "INSERT INTO cameras (name, go2rtc_name, main_url, policy_id)
                         VALUES ('Cam A', $1, 'rtsp://a/main', $2)
                         RETURNING id",
                        &[&format!("cam_a_{}", Uuid::new_v4().simple()), &policy_id],
                    )
                    .await
                    .expect("insert camera a");
                let row_b = client
                    .query_one(
                        "INSERT INTO cameras (name, go2rtc_name, main_url, policy_id)
                         VALUES ('Cam B', $1, 'rtsp://b/main', $2)
                         RETURNING id",
                        &[&format!("cam_b_{}", Uuid::new_v4().simple()), &policy_id],
                    )
                    .await
                    .expect("insert camera b");

                (policy_id, row_a.get::<_, Uuid>(0), row_b.get::<_, Uuid>(0))
            };

            PolicyFixture {
                pool,
                schema,
                base_url: base_url.to_owned(),
                _live_dir: live_dir,
                _archive_dir: archive_dir,
                live_storage_id: live_storage.id,
                archive_storage_id: archive_storage.id,
                camera_a_id,
                camera_b_id,
                policy_id,
            }
        }

        /// Add a segment for an arbitrary camera id (not pinned to Fixture.camera_id).
        #[allow(clippy::too_many_arguments)]
        async fn add_segment_for(
            pool: &Pool,
            camera_id: Uuid,
            storage_id: Uuid,
            storage_path: &std::path::Path,
            stage: SegmentStage,
            rel: &str,
            start: DateTime<Utc>,
            size: i64,
        ) {
            let abs = storage_path.join(rel);
            if let Some(parent) = abs.parent() {
                tokio::fs::create_dir_all(parent).await.expect("mkdir");
            }
            tokio::fs::write(&abs, vec![0u8; size as usize])
                .await
                .expect("write file");

            db::insert_segment(
                pool,
                &InsertSegmentParams {
                    camera_id,
                    storage_id,
                    stage,
                    path: rel.to_owned(),
                    stream: SegmentStream::Main,
                    start_ts: start,
                    end_ts: start + Duration::seconds(4),
                    duration_ms: 4000,
                    has_motion: false,
                    motion_score: 0.0,
                    size_bytes: size,
                    motion_bbox: None,
                },
            )
            .await
            .expect("insert segment");
        }

        async fn load_policy(fx: &PolicyFixture) -> RecordingPolicy {
            db::get_policy(&fx.pool, fx.policy_id)
                .await
                .expect("get_policy")
                .expect("policy exists")
        }

        /// Two cameras share one policy with a live cap of 350 B.  Each camera
        /// contributes 200 B of live footage (2 × 100 B segments).  The TOTAL is
        /// 400 B > 350 B cap, so the policy sweep should evict the single globally
        /// oldest segment (100 B), leaving 300 B ≤ 350 B.
        #[tokio::test]
        async fn policy_live_cap_is_shared_across_cameras() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            // 350B cap, archive off.
            let fx = setup_policy(&url, Some(350), None, false).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            let t0 = Utc::now() - Duration::hours(10);

            // Camera A: segments at t0 and t0+1m.
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "a0.mp4",
                t0,
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "a1.mp4",
                t0 + Duration::minutes(1),
                100,
            )
            .await;

            // Camera B: segments at t0+2m and t0+3m.
            add_segment_for(
                &fx.pool,
                fx.camera_b_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "b0.mp4",
                t0 + Duration::minutes(2),
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_b_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "b1.mp4",
                t0 + Duration::minutes(3),
                100,
            )
            .await;

            // Total = 400 B; cap = 350 B → need to evict 1 × 100 B (a0, oldest).
            let policy = load_policy(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep ok");

            // 3 rows remain.
            let used = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Live)
                .await
                .unwrap();
            assert!(
                used <= 350,
                "policy live total should be under cap, got {used}"
            );
            assert_eq!(used, 300, "exactly 3 × 100B should remain");

            // Oldest file (a0) deleted from disk.
            assert!(
                !live_path.join("a0.mp4").exists(),
                "oldest segment must be deleted"
            );
            // Remaining files still on disk.
            assert!(live_path.join("a1.mp4").exists());
            assert!(live_path.join("b0.mp4").exists());
            assert!(live_path.join("b1.mp4").exists());
        }

        /// SPILL / low-water hysteresis. Cap = 350 B, spill = 150 B (archive off).
        /// (1) 600 B over the cap → eviction fires (trigger = cap) and OVERSHOOTS
        ///     down to the low-water target `cap - spill = 200 B`, not just to the
        ///     cap — so it evicts 4 × 100 B in one batched drain, leaving 200 B.
        /// (2) Then 300 B (between the target and the cap) → eviction does NOT fire
        ///     (the trigger is still the true cap, 350 B), so it stays at 300 B.
        ///     Together these prove spill batches without lowering the trigger.
        #[tokio::test]
        async fn policy_spill_overshoots_cap_then_stays_quiet() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, Some(350), None, false).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            // Set the spill buffer on the policy (setup_policy doesn't take it).
            {
                let client = fx.pool.get().await.expect("conn");
                client
                    .execute(
                        "UPDATE recording_policies SET live_spill_low_water_bytes = $2 WHERE id = $1",
                        &[&fx.policy_id, &150_i64],
                    )
                    .await
                    .expect("set spill");
            }

            let live_path = fx._live_dir.path().to_path_buf();
            let t0 = Utc::now() - Duration::hours(10);

            // 6 × 100 B = 600 B on one camera.
            for i in 0..6 {
                add_segment_for(
                    &fx.pool,
                    fx.camera_a_id,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    &format!("s{i}.mp4"),
                    t0 + Duration::minutes(i),
                    100,
                )
                .await;
            }

            // (1) Over cap → overshoot to cap - spill = 200 B.
            let policy = load_policy(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep 1");
            let used = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Live)
                .await
                .unwrap();
            assert_eq!(
                used, 200,
                "spill must overshoot the cap down to cap-spill (200B), got {used}"
            );

            // (2) Add 100 B → 300 B, which is BELOW the cap (350) though above the
            // target (200). Eviction must NOT fire (hysteresis): trigger is the cap.
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "s_new.mp4",
                t0 + Duration::minutes(10),
                100,
            )
            .await;
            policy_size_eviction_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep 2");
            let used2 = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Live)
                .await
                .unwrap();
            assert_eq!(
                used2, 300,
                "between target and cap, eviction must stay quiet (trigger is the cap), got {used2}"
            );
        }

        /// ENOSPC rescue (free-space floor × shared filesystem): when the floor
        /// is in DEFICIT and the archive destination is on the SAME filesystem
        /// as the live storage (the default compose layout — both fixture
        /// tempdirs share one fs, same `st_dev`), the sweep must DELETE the
        /// oldest live segments — actually freeing bytes — instead of
        /// archive-moving them in place. Pre-fix, the move freed 0 bytes, the
        /// deficit read as satisfied, and the loop repeated every tick until
        /// the disk hit 100% and ffmpeg ENOSPC-halted recording on every
        /// camera. Protected bookmarks still survive, nothing lands on
        /// stage=archive, and rows go file-then-row.
        #[tokio::test]
        async fn floor_deficit_on_shared_fs_deletes_oldest_instead_of_moving() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            // Archive ON, NO byte caps — only the free-space floor drives this
            // sweep, so the delete can only be the floor-deficit path.
            let fx = setup_policy(&url, None, None, true).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            // Force the floor into deficit DETERMINISTICALLY: read the live
            // tempdir filesystem's real free/total and set the per-policy
            // fractional floor strictly between the current free fraction and
            // 1.0 — guaranteed below-floor regardless of how full the host
            // disk is. (`None` ⇒ statvfs unavailable, e.g. non-Unix — skip,
            // mirroring the floor itself.)
            let live_path = fx._live_dir.path().to_path_buf();
            let Some((free, total)) = fs_free_and_total(live_path.to_str().expect("utf8")) else {
                eprintln!("skipping: statvfs unavailable on this platform");
                return;
            };
            #[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
            let frac = (((free as f64 / total as f64) + 1.0) / 2.0) as f32;
            if !(0.0..1.0).contains(&frac) {
                eprintln!("skipping: cannot construct a firing floor (free={free}, total={total})");
                return;
            }
            {
                let client = fx.pool.get().await.expect("conn");
                client
                    .execute(
                        "UPDATE recording_policies SET live_min_free_pct = $2 WHERE id = $1",
                        &[&fx.policy_id, &frac],
                    )
                    .await
                    .expect("set per-policy floor");
            }

            // Three old live segments; the OLDEST is pinned by a protected
            // bookmark (a human pin outranks the automatic rescue).
            let t0 = Utc::now() - Duration::hours(10);
            for (rel, offset) in [("pinned.mp4", 0i64), ("old1.mp4", 1), ("old2.mp4", 2)] {
                add_segment_for(
                    &fx.pool,
                    fx.camera_a_id,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    rel,
                    t0 + Duration::minutes(offset),
                    100,
                )
                .await;
            }
            {
                let client = fx.pool.get().await.expect("conn");
                client
                    .execute(
                        "INSERT INTO bookmarks \
                             (camera_id, ts, protect_until, protect_start_ts, protect_end_ts) \
                         VALUES ($1, $2, now() + interval '1 day', $3, $4)",
                        &[
                            &fx.camera_a_id,
                            &t0,
                            &(t0 - Duration::seconds(5)),
                            &(t0 + Duration::seconds(5)),
                        ],
                    )
                    .await
                    .expect("insert protected bookmark");
            }

            let policy = load_policy(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep ok");

            // The deficit (GB-scale) dwarfs the 300B of footage, so every
            // UNPROTECTED candidate must be DELETED — real bytes freed — never
            // archive-moved in place.
            assert!(
                !live_path.join("old1.mp4").exists(),
                "old1 must be deleted (bytes actually freed), not moved in place"
            );
            assert!(
                !live_path.join("old2.mp4").exists(),
                "old2 must be deleted (bytes actually freed), not moved in place"
            );
            assert!(
                live_path.join("pinned.mp4").exists(),
                "the protected segment must survive the ENOSPC rescue"
            );

            // Rows follow the files (file-then-row): only the protected row
            // remains, still live — nothing was flipped to stage=archive.
            let rows = db::list_all_segments_for_camera(&fx.pool, fx.camera_a_id)
                .await
                .unwrap();
            assert_eq!(rows.len(), 1, "only the protected row remains: {rows:?}");
            assert!(rows[0].path.ends_with("pinned.mp4"));
            assert_eq!(
                rows[0].stage,
                SegmentStage::Live,
                "the protected segment must not be archive-moved either"
            );
            let archive_bytes =
                db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                    .await
                    .unwrap();
            assert_eq!(
                archive_bytes, 0,
                "a shared-fs floor deficit must never archive-move (0 bytes freed)"
            );
            // And the archive directory really received nothing.
            let mut entries = tokio::fs::read_dir(fx._archive_dir.path())
                .await
                .expect("read archive dir");
            assert!(
                entries.next_entry().await.expect("read entry").is_none(),
                "no files may land on the archive dir during a shared-fs floor rescue"
            );
        }

        // ── absolute max-retention cap tests ──────────────────────────────────

        /// Set `max_retention_days` on the fixture's policy (setup_policy doesn't
        /// take it). `None` clears it (= OFF).
        async fn set_max_retention_days(fx: &PolicyFixture, days: Option<i32>) {
            let client = fx.pool.get().await.expect("conn");
            client
                .execute(
                    "UPDATE recording_policies SET max_retention_days = $2 WHERE id = $1",
                    &[&fx.policy_id, &days],
                )
                .await
                .expect("set max_retention_days");
        }

        /// OFF by default: with `max_retention_days` unset, even ancient footage on
        /// both stages must survive — the cap can never surprise-delete.
        #[tokio::test]
        async fn max_retention_off_by_default_keeps_everything() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, true).await; // archive ON
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            let archive_path = fx._archive_dir.path().to_path_buf();
            // Distinct start_ts so the two segments don't collide on the
            // (camera_id, stream, start_ts) unique index (which would UPSERT one
            // over the other). Both ~10 years old.
            let ancient_live = Utc::now() - Duration::days(3650);
            let ancient_arch = Utc::now() - Duration::days(3640);

            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "ancient_live.mp4",
                ancient_live,
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &archive_path,
                SegmentStage::Archive,
                "ancient_arch.mp4",
                ancient_arch,
                100,
            )
            .await;

            let policy = load_policy(&fx).await;
            assert!(
                policy.max_retention_days.is_none(),
                "cap must default to OFF (NULL)"
            );
            max_retention_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep");

            assert!(
                live_path.join("ancient_live.mp4").exists(),
                "with no cap set, old live footage must survive"
            );
            assert!(
                archive_path.join("ancient_arch.mp4").exists(),
                "with no cap set, old archived footage must survive"
            );
        }

        /// The cap is an absolute ceiling: footage older than it is deleted on
        /// BOTH stages and even for an archive-enabled camera (whose live footage
        /// `live_retention_sweep` would otherwise skip). Footage within the cap
        /// survives.
        #[tokio::test]
        async fn max_retention_deletes_across_both_stages_and_archive_cameras() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, true).await; // archive ON
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");
            set_max_retention_days(&fx, Some(7)).await;

            let live_path = fx._live_dir.path().to_path_buf();
            let archive_path = fx._archive_dir.path().to_path_buf();
            // Distinct start_ts so the two camera_a segments are distinct rows
            // (same camera+stream+start_ts would collide on the unique index and
            // UPSERT one over the other). Both are ~10-12 days old (past the cap).
            let old_live_ts = Utc::now() - Duration::days(10);
            let old_arch_ts = Utc::now() - Duration::days(12);
            let recent = Utc::now() - Duration::days(1);

            // camera_a: an OLD live segment (archive enabled → the per-tier live
            // sweep skips it) + an OLD archive segment. Both are past the cap.
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "old_live.mp4",
                old_live_ts,
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &archive_path,
                SegmentStage::Archive,
                "old_arch.mp4",
                old_arch_ts,
                100,
            )
            .await;
            // camera_b: a RECENT live segment — within the cap, must survive.
            add_segment_for(
                &fx.pool,
                fx.camera_b_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "recent_live.mp4",
                recent,
                100,
            )
            .await;

            let policy = load_policy(&fx).await;
            max_retention_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep");

            assert!(
                !live_path.join("old_live.mp4").exists(),
                "old live footage past the cap must be deleted even for an archive-enabled camera"
            );
            assert!(
                !archive_path.join("old_arch.mp4").exists(),
                "old archived footage past the cap must be deleted"
            );
            assert!(
                live_path.join("recent_live.mp4").exists(),
                "footage within the cap must survive"
            );
            // Index rows: only the recent live segment remains anywhere.
            let live_bytes = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Live)
                .await
                .unwrap();
            assert_eq!(
                live_bytes, 100,
                "only the recent live segment's row remains"
            );
            let arch_bytes = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                .await
                .unwrap();
            assert_eq!(arch_bytes, 0, "the old archive segment's row must be gone");
        }

        /// A protected bookmark exempts overlapping footage from the cap — an
        /// explicit human pin wins over the automatic ceiling. An unpinned sibling
        /// of the same age is still deleted.
        #[tokio::test]
        async fn max_retention_respects_protected_bookmarks() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");
            set_max_retention_days(&fx, Some(7)).await;

            let live_path = fx._live_dir.path().to_path_buf();
            let old = Utc::now() - Duration::days(10);
            let old_far = old + Duration::hours(1); // well outside the protect window

            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "pinned.mp4",
                old,
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.live_storage_id,
                &live_path,
                SegmentStage::Live,
                "unpinned.mp4",
                old_far,
                100,
            )
            .await;

            // Protect a window tightly around `pinned` (start..start+4s), active
            // into the future. `unpinned` (an hour later) is outside it.
            {
                let client = fx.pool.get().await.expect("conn");
                let protect_start = old - Duration::minutes(1);
                let protect_end = old + Duration::minutes(5);
                let protect_until = Utc::now() + Duration::days(1);
                client
                    .execute(
                        "INSERT INTO bookmarks
                             (camera_id, ts, protect_until, protect_start_ts, protect_end_ts)
                         VALUES ($1, $2, $3, $4, $5)",
                        &[
                            &fx.camera_a_id,
                            &old,
                            &protect_until,
                            &protect_start,
                            &protect_end,
                        ],
                    )
                    .await
                    .expect("insert protect bookmark");
            }

            let policy = load_policy(&fx).await;
            max_retention_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep");

            assert!(
                live_path.join("pinned.mp4").exists(),
                "protected footage must survive the cap"
            );
            assert!(
                !live_path.join("unpinned.mp4").exists(),
                "unprotected footage past the cap must be deleted"
            );
        }

        /// Two cameras share one policy with a live cap of 150 B and archive ON.
        /// Total live = 4 × 100 B = 400 B.  Sweep should MOVE (not delete) the
        /// two globally oldest live segments into archive, leaving 200 B ≤ cap ×
        /// … wait, 200 > 150: it moves until used ≤ cap, so it evicts 3 segments
        /// (moving them to archive) → 100 B live ≤ 150 B.
        #[tokio::test]
        async fn policy_live_over_cap_archive_on_moves_not_deletes() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            // live cap 150B, no archive cap, archive enabled.
            let fx = setup_policy(&url, Some(150), None, true).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            let live_path = fx._live_dir.path().to_path_buf();
            let t0 = Utc::now() - Duration::hours(10);

            // 2 segments per camera, oldest across cameras interleaved:
            // a0 (t0), b0 (t0+1m), a1 (t0+2m), b1 (t0+3m)
            for (camera_id, rel, offset) in [
                (fx.camera_a_id, "pa0.mp4", 0i64),
                (fx.camera_b_id, "pb0.mp4", 1),
                (fx.camera_a_id, "pa1.mp4", 2),
                (fx.camera_b_id, "pb1.mp4", 3),
            ] {
                add_segment_for(
                    &fx.pool,
                    camera_id,
                    fx.live_storage_id,
                    &live_path,
                    SegmentStage::Live,
                    rel,
                    t0 + Duration::minutes(offset),
                    100,
                )
                .await;
            }

            // Total = 400B live; cap = 150B → move 3 oldest (pa0, pb0, pa1).
            let policy = load_policy(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep ok");

            // No rows deleted — all 4 segments still exist (moved to archive).
            let live_used = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Live)
                .await
                .unwrap();
            assert!(live_used <= 150, "live under cap, got {live_used}");

            let archive_used =
                db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                    .await
                    .unwrap();
            assert_eq!(archive_used, 300, "three segments moved to archive");

            // Moved files are gone from live dir.
            assert!(!live_path.join("pa0.mp4").exists(), "pa0 moved");
            assert!(!live_path.join("pb0.mp4").exists(), "pb0 moved");
            assert!(!live_path.join("pa1.mp4").exists(), "pa1 moved");
            // Newest still in live.
            assert!(live_path.join("pb1.mp4").exists(), "pb1 still live");

            // Moved files exist somewhere under the archive dir.
            let moved_segs = db::list_policy_segments_oldest_first(
                &fx.pool,
                fx.policy_id,
                SegmentStage::Archive,
                None,
            )
            .await
            .unwrap();
            assert_eq!(moved_segs.len(), 3);
            for seg in &moved_segs {
                assert_eq!(
                    seg.storage_id, fx.archive_storage_id,
                    "segment {} must point at archive storage",
                    seg.id
                );
                let abs = fx._archive_dir.path().join(&seg.path);
                assert!(abs.exists(), "archived file must exist: {}", abs.display());
            }
        }

        /// REGRESSION (the live_storage-repoint bug): a LIVE segment whose file is on
        /// a DIFFERENT storage than the policy's current live_storage must be ARCHIVED
        /// from its OWN storage — not dangling-deleted because the move looked for the
        /// file under the policy's live path. Models footage left on the old disk after
        /// a policy's live_storage was repointed.
        #[tokio::test]
        async fn eviction_moves_segment_from_its_own_storage_not_policy_live() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            // live cap 50B, archive enabled. Policy live_storage = live; archive = archive.
            let fx = setup_policy(&url, Some(50), None, true).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");

            // A LIVE-stage segment whose file physically lives on the ARCHIVE disk —
            // i.e. its storage_id is NOT the policy's live_storage_id. (Stand-in for
            // "footage on the disk the policy no longer points at as live".) 100B > the
            // 50B cap, so eviction fires.
            let t0 = Utc::now() - Duration::hours(10);
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,  // storage_id != policy.live_storage_id
                fx._archive_dir.path(), // file physically on the archive disk
                SegmentStage::Live,
                "stray.mp4",
                t0,
                100,
            )
            .await;

            let policy = load_policy(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &policy)
                .await
                .expect("sweep ok");

            // The segment must SURVIVE — moved to archive, NOT dangling-deleted.
            // (Pre-fix: the move resolved the source at the policy's live path, didn't
            // find the file there, and deleted the row as dangling → rows.len()==0.)
            let rows = db::list_all_segments_for_camera(&fx.pool, fx.camera_a_id)
                .await
                .unwrap();
            assert_eq!(
                rows.len(),
                1,
                "segment must be preserved (moved), not deleted: {rows:?}"
            );
            let live_used = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Live)
                .await
                .unwrap();
            let archive_used =
                db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                    .await
                    .unwrap();
            assert_eq!(live_used, 0, "no longer live");
            assert_eq!(archive_used, 100, "moved to archive");
            assert!(
                !fx._archive_dir.path().join("stray.mp4").exists(),
                "flat source removed after move"
            );
            let abs = fx._archive_dir.path().join(&rows[0].path);
            assert!(abs.exists(), "archived file exists at {}", abs.display());
        }

        // ── disable-archive orphan fix (residual stage=archive coverage) ─────

        /// Set the policy's retention windows (hours). `None` archive ⇒ indefinite.
        async fn set_retention(fx: &PolicyFixture, archive_hours: Option<i32>, live_hours: i32) {
            let client = fx.pool.get().await.expect("conn");
            client
                .execute(
                    "UPDATE recording_policies SET archive_retention_hours = $1, \
                     live_retention_hours = $2 WHERE id = $3",
                    &[&archive_hours, &live_hours, &fx.policy_id],
                )
                .await
                .expect("set retention");
        }

        /// Camera A with its resolved effective policy.
        async fn cam_a(fx: &PolicyFixture) -> Camera {
            db::list_enabled_cameras(&fx.pool)
                .await
                .expect("list cameras")
                .into_iter()
                .find(|c| c.id == fx.camera_a_id)
                .expect("camera a")
        }

        /// Archive OFF + residual archive footage: the drain deletes archive-stage
        /// segments older than the ARCHIVE retention (graceful wind-down) and keeps
        /// newer ones. Pre-fix, this footage was swept by nothing and orphaned.
        #[tokio::test]
        async fn disabled_archive_drains_old_residual_under_archive_retention() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await; // archive OFF
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");
            set_retention(&fx, Some(240), 72).await; // archive 10d, live 3d

            let ap = fx._archive_dir.path().to_path_buf();
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "old.mp4",
                Utc::now() - Duration::hours(300),
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "fresh.mp4",
                Utc::now() - Duration::hours(100),
                100,
            )
            .await;

            let cam = cam_a(&fx).await;
            assert!(!cam.policy.archive_enabled);
            archive_retention_sweep(&fx.pool, &config, &cam)
                .await
                .expect("drain");

            let arch = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                .await
                .unwrap();
            assert_eq!(arch, 100, ">10d archive segment drained; <10d one kept");
            assert!(!ap.join("old.mp4").exists(), "old archive file deleted");
            assert!(ap.join("fresh.mp4").exists(), "fresh archive file kept");
        }

        /// Archive OFF + NO archive retention: the drain falls back to the LIVE
        /// retention so residual archive footage can't be retained forever.
        #[tokio::test]
        async fn disabled_archive_drains_under_live_retention_when_archive_indefinite() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");
            set_retention(&fx, None, 72).await; // archive indefinite, live 3d

            let ap = fx._archive_dir.path().to_path_buf();
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "old.mp4",
                Utc::now() - Duration::hours(100),
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "fresh.mp4",
                Utc::now() - Duration::hours(24),
                100,
            )
            .await;

            let cam = cam_a(&fx).await;
            archive_retention_sweep(&fx.pool, &config, &cam)
                .await
                .expect("drain");

            let arch = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                .await
                .unwrap();
            assert_eq!(
                arch, 100,
                ">live-retention archive segment drained under live retention"
            );
        }

        /// Archive OFF: residual archive footage shares the LIVE size cap and is
        /// size-evictable oldest-first, so a full disk reclaims the orphan instead
        /// of squeezing recent live footage.
        #[tokio::test]
        async fn disabled_archive_residual_is_size_evictable() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, Some(150), None, false).await; // live cap 150B
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");
            // Long retention so the AGE drain doesn't act; zero the free-space floor
            // so ONLY the cap drives eviction (deterministic).
            {
                let client = fx.pool.get().await.unwrap();
                client
                    .execute(
                        "UPDATE recording_policies SET archive_retention_hours = NULL, \
                     live_retention_hours = 1000000, live_min_free_pct = 0, \
                     live_min_free_bytes = 0 WHERE id = $1",
                        &[&fx.policy_id],
                    )
                    .await
                    .unwrap();
            }

            let ap = fx._archive_dir.path().to_path_buf();
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "old.mp4",
                Utc::now() - Duration::hours(50),
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "new.mp4",
                Utc::now() - Duration::hours(10),
                100,
            )
            .await;

            let policy = load_policy(&fx).await;
            policy_size_eviction_sweep(&fx.pool, &config, &policy)
                .await
                .expect("evict");

            let arch = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                .await
                .unwrap();
            assert_eq!(
                arch, 100,
                "oldest archive segment evicted to satisfy the live cap"
            );
            assert!(!ap.join("old.mp4").exists(), "oldest archive file evicted");
            assert!(ap.join("new.mp4").exists(), "newer archive file kept");
        }

        /// Regression: with archive ENABLED, archive-retention behaviour is
        /// unchanged — old archive segments age out under archive_retention_hours.
        #[tokio::test]
        async fn enabled_archive_retention_unchanged() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, true).await; // archive ON
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");
            set_retention(&fx, Some(240), 72).await;

            let ap = fx._archive_dir.path().to_path_buf();
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "old.mp4",
                Utc::now() - Duration::hours(300),
                100,
            )
            .await;
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "fresh.mp4",
                Utc::now() - Duration::hours(100),
                100,
            )
            .await;

            let cam = cam_a(&fx).await;
            assert!(cam.policy.archive_enabled);
            archive_retention_sweep(&fx.pool, &config, &cam)
                .await
                .expect("sweep");

            let arch = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                .await
                .unwrap();
            assert_eq!(arch, 100, "enabled-archive retention unchanged");
        }

        /// A protected bookmark covering a residual archive segment keeps the drain
        /// from deleting it when archive is disabled.
        #[tokio::test]
        async fn disabled_archive_drain_respects_protected_bookmarks() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await;
            std::env::set_var("DATABASE_URL", "unused://");
            let config = Config::from_env().expect("config");
            set_retention(&fx, Some(240), 72).await;

            let ap = fx._archive_dir.path().to_path_buf();
            let seg_start = Utc::now() - Duration::hours(300); // older than archive retention
            add_segment_for(
                &fx.pool,
                fx.camera_a_id,
                fx.archive_storage_id,
                &ap,
                SegmentStage::Archive,
                "protected.mp4",
                seg_start,
                100,
            )
            .await;

            {
                let client = fx.pool.get().await.unwrap();
                client.execute(
                    "INSERT INTO bookmarks (camera_id, ts, protect_until, protect_start_ts, protect_end_ts) \
                     VALUES ($1, $2, now() + interval '7 days', $3, $4)",
                    &[&fx.camera_a_id, &seg_start,
                      &(seg_start - Duration::minutes(1)), &(seg_start + Duration::minutes(5))],
                ).await.unwrap();
            }

            let cam = cam_a(&fx).await;
            archive_retention_sweep(&fx.pool, &config, &cam)
                .await
                .expect("drain");

            let arch = db::policy_stage_bytes(&fx.pool, fx.policy_id, SegmentStage::Archive)
                .await
                .unwrap();
            assert_eq!(arch, 100, "protected archive segment survives the drain");
            assert!(ap.join("protected.mp4").exists(), "protected file kept");
        }

        /// Insert a camera with an optional direct policy; returns its id.
        async fn insert_cam(pool: &Pool, policy: Option<Uuid>) -> Uuid {
            pool.get()
                .await
                .unwrap()
                .query_one(
                    "INSERT INTO cameras (name, go2rtc_name, main_url, policy_id) \
                     VALUES ('c', $1, 'rtsp://x/main', $2) RETURNING id",
                    &[&format!("cam_{}", Uuid::new_v4().simple()), &policy],
                )
                .await
                .unwrap()
                .get(0)
        }
        async fn join_group(pool: &Pool, cam: Uuid, grp: Uuid) {
            pool.get()
                .await
                .unwrap()
                .execute(
                    "INSERT INTO camera_group_members (camera_id, group_id) VALUES ($1, $2)",
                    &[&cam, &grp],
                )
                .await
                .unwrap();
        }

        /// Phase-1 equivalence LOCK: v_camera_effective_policy.p_id must equal the
        /// canonical COALESCE(own -> group -> default) for EVERY resolution path,
        /// and yield exactly one row per camera. Existing tests only exercise
        /// direct-policy cameras; this also covers group-inherit, default-fallback,
        /// and the NULL-group-policy fallthrough — the surfaces the view centralizes.
        #[tokio::test]
        async fn view_effective_policy_equals_canonical_coalesce() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await;
            let default_id = fx.policy_id; // setup_policy's TestPolicy has is_default = true

            // A second NAMED non-default policy + two groups (one with it, one NULL).
            let (p2, grp, grp_null): (Uuid, Uuid, Uuid) = {
                let client = fx.pool.get().await.unwrap();
                let p2 = client
                    .query_one(
                        "INSERT INTO recording_policies (name, is_default) VALUES ('P2', false) RETURNING id",
                        &[],
                    )
                    .await
                    .unwrap()
                    .get(0);
                let grp = client
                    .query_one(
                        "INSERT INTO camera_groups (name, policy_id) VALUES ('G', $1) RETURNING id",
                        &[&p2],
                    )
                    .await
                    .unwrap()
                    .get(0);
                let grp_null = client
                    .query_one(
                        "INSERT INTO camera_groups (name, policy_id) VALUES ('Gnull', NULL) RETURNING id",
                        &[],
                    )
                    .await
                    .unwrap()
                    .get(0);
                (p2, grp, grp_null)
            };

            let cam_own = insert_cam(&fx.pool, Some(p2)).await; // own -> P2
            let cam_grp = insert_cam(&fx.pool, None).await; // group -> P2
            join_group(&fx.pool, cam_grp, grp).await;
            let cam_def = insert_cam(&fx.pool, None).await; // none -> default
            let cam_gnull = insert_cam(&fx.pool, None).await; // NULL-policy group -> default
            join_group(&fx.pool, cam_gnull, grp_null).await;

            for (cam, expected, label) in [
                (cam_own, p2, "own direct policy"),
                (cam_grp, p2, "group policy"),
                (cam_def, default_id, "default fallback (no group)"),
                (
                    cam_gnull,
                    default_id,
                    "default fallback (group policy NULL)",
                ),
            ] {
                let client = fx.pool.get().await.unwrap();
                let view_rows = client
                    .query(
                        "SELECT p_id FROM v_camera_effective_policy WHERE c_id = $1",
                        &[&cam],
                    )
                    .await
                    .unwrap();
                assert_eq!(
                    view_rows.len(),
                    1,
                    "{label}: exactly one view row per camera"
                );
                let view_pid: Uuid = view_rows[0].get("p_id");
                let coalesce_pid: Uuid = client
                    .query_one(
                        "SELECT COALESCE(c.policy_id, g.policy_id, \
                             (SELECT id FROM recording_policies WHERE is_default LIMIT 1)) AS pid \
                         FROM cameras c \
                         LEFT JOIN camera_group_members m ON m.camera_id = c.id \
                         LEFT JOIN camera_groups g ON g.id = m.group_id \
                         WHERE c.id = $1",
                        &[&cam],
                    )
                    .await
                    .unwrap()
                    .get("pid");
                assert_eq!(
                    view_pid, coalesce_pid,
                    "{label}: view p_id must equal canonical COALESCE"
                );
                assert_eq!(view_pid, expected, "{label}: resolved to the wrong policy");
            }
        }

        /// Read a camera's direct policy_id (NULL → None).
        async fn cam_policy_id(pool: &Pool, cam: Uuid) -> Option<Uuid> {
            pool.get()
                .await
                .unwrap()
                .query_one("SELECT policy_id FROM cameras WHERE id = $1", &[&cam])
                .await
                .unwrap()
                .get::<_, Option<Uuid>>(0)
        }

        /// Resolve a camera's EFFECTIVE policy via the view (own → group → default).
        async fn effective_pid(pool: &Pool, cam: Uuid) -> Uuid {
            pool.get()
                .await
                .unwrap()
                .query_one(
                    "SELECT p_id FROM v_camera_effective_policy WHERE c_id = $1",
                    &[&cam],
                )
                .await
                .unwrap()
                .get("p_id")
        }

        /// Insert a NAMED non-default policy + a group assigned to it; returns ids.
        async fn named_policy_and_group(pool: &Pool, pname: &str, gname: &str) -> (Uuid, Uuid) {
            let client = pool.get().await.unwrap();
            let p: Uuid = client
                .query_one(
                    "INSERT INTO recording_policies (name, is_default) VALUES ($1, false) RETURNING id",
                    &[&pname],
                )
                .await
                .unwrap()
                .get(0);
            let g: Uuid = client
                .query_one(
                    "INSERT INTO camera_groups (name, policy_id) VALUES ($1, $2) RETURNING id",
                    &[&gname, &p],
                )
                .await
                .unwrap()
                .get(0);
            (p, g)
        }

        /// Phase 2 (write-through): set_group_members ADDING a camera PINS its
        /// policy_id directly to the group's policy (no inheritance), and the view
        /// resolves it to that same policy.
        #[tokio::test]
        async fn set_group_members_pins_added_camera_to_group_policy() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await;
            let (p2, grp) = named_policy_and_group(&fx.pool, "P2", "G").await;

            // A camera that initially holds a DIRECT policy distinct from the group's.
            let cam = insert_cam(&fx.pool, Some(fx.policy_id)).await;
            assert_eq!(
                cam_policy_id(&fx.pool, cam).await,
                Some(fx.policy_id),
                "precondition: camera has its own direct policy"
            );

            // Add it to the group (the wire path the admin UI / config-routes use).
            db::set_group_members(&fx.pool, grp, &[cam]).await.unwrap();

            assert_eq!(
                cam_policy_id(&fx.pool, cam).await,
                Some(p2),
                "joining a group PINS the member's policy_id to the group's policy"
            );
            assert_eq!(
                effective_pid(&fx.pool, cam).await,
                p2,
                "a grouped camera resolves to its group's profile"
            );
        }

        /// Phase 2 (write-through): set_group_members must only re-pin the cameras
        /// it ADDS — a pre-existing member dropped from the new set, and an
        /// unrelated ungrouped camera, keep whatever policy they hold.
        #[tokio::test]
        async fn set_group_members_leaves_nonmembers_override_intact() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await;
            let (p2, grp) = named_policy_and_group(&fx.pool, "P2", "G").await;

            // An ungrouped camera with a direct override, never passed to the group.
            let outsider = insert_cam(&fx.pool, Some(fx.policy_id)).await;
            // A camera we DO add to the group (its override should clear).
            let joiner = insert_cam(&fx.pool, Some(p2)).await;

            db::set_group_members(&fx.pool, grp, &[joiner])
                .await
                .unwrap();

            // The outsider — not in camera_ids — keeps its direct policy and resolves
            // to it (own → … → default puts its own policy first).
            assert_eq!(
                cam_policy_id(&fx.pool, outsider).await,
                Some(fx.policy_id),
                "an ungrouped, never-added camera keeps its direct policy_id"
            );
            assert_eq!(
                effective_pid(&fx.pool, outsider).await,
                fx.policy_id,
                "ungrouped camera still resolves to its own direct policy"
            );
            // The joiner was re-pinned to the group's policy.
            assert_eq!(
                cam_policy_id(&fx.pool, joiner).await,
                Some(p2),
                "the added camera is pinned to the group's policy"
            );

            // Now DROP the joiner from the group (members = []) — it becomes ungrouped
            // and is NOT re-pinned (the UPDATE only touches camera_ids, never a removed
            // member). Give it a different direct policy first to prove dropped members
            // are left alone by the write-through.
            db::set_camera_policy_id(&fx.pool, joiner, fx.policy_id)
                .await
                .unwrap();
            db::set_group_members(&fx.pool, grp, &[]).await.unwrap();
            assert_eq!(
                cam_policy_id(&fx.pool, joiner).await,
                Some(fx.policy_id),
                "a member DROPPED from the group keeps the policy it was given (clear only touches added ids)"
            );
            assert!(
                !db::is_camera_grouped(&fx.pool, joiner).await.unwrap(),
                "dropped camera is no longer grouped"
            );
        }

        /// Phase 3 (c): the migration-0020-style clear — UPDATE cameras SET
        /// policy_id = NULL for every member of any group — clears grouped cameras
        /// but leaves UNGROUPED cameras' overrides intact. Mirrors the migration's
        /// exact predicate so the test guards the data migration's behavior.
        #[tokio::test]
        async fn migration_clear_only_affects_grouped_cameras() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await;
            let (p2, grp) = named_policy_and_group(&fx.pool, "P2", "G").await;

            // A grouped camera that (wrongly, pre-migration) still holds a direct
            // override — inserted directly + joined via the raw helper so the clear
            // in set_group_members does NOT run (we want to simulate the stale state
            // the migration repairs).
            let grouped_stale = insert_cam(&fx.pool, Some(fx.policy_id)).await;
            join_group(&fx.pool, grouped_stale, grp).await;
            // An ungrouped camera with its own legitimate override.
            let ungrouped = insert_cam(&fx.pool, Some(fx.policy_id)).await;

            // Run the migration's exact statement.
            fx.pool
                .get()
                .await
                .unwrap()
                .execute(
                    "UPDATE cameras SET policy_id = NULL \
                     WHERE policy_id IS NOT NULL \
                       AND id IN (SELECT camera_id FROM camera_group_members)",
                    &[],
                )
                .await
                .unwrap();

            // Grouped camera's override cleared → now resolves to the group profile.
            assert_eq!(
                cam_policy_id(&fx.pool, grouped_stale).await,
                None,
                "migration clears a grouped camera's stale override"
            );
            assert_eq!(
                effective_pid(&fx.pool, grouped_stale).await,
                p2,
                "cleared grouped camera resolves to its group's profile"
            );
            // Ungrouped camera's override survives.
            assert_eq!(
                cam_policy_id(&fx.pool, ungrouped).await,
                Some(fx.policy_id),
                "migration leaves an ungrouped camera's override intact"
            );
            assert_eq!(
                effective_pid(&fx.pool, ungrouped).await,
                fx.policy_id,
                "ungrouped camera still resolves to its own policy"
            );

            // Idempotent: re-running is a no-op.
            let n = fx
                .pool
                .get()
                .await
                .unwrap()
                .execute(
                    "UPDATE cameras SET policy_id = NULL \
                     WHERE policy_id IS NOT NULL \
                       AND id IN (SELECT camera_id FROM camera_group_members)",
                    &[],
                )
                .await
                .unwrap();
            assert_eq!(n, 0, "re-running the migration affects zero rows");
        }

        /// Phase-3 BACKSTOP (migration 0021 triggers): the DB structurally prevents
        /// a grouped camera from holding a direct policy override, even if the app
        /// checks were bypassed or raced.
        #[tokio::test]
        async fn grouped_camera_override_trigger_enforced() {
            let Some(url) = test_db_url() else {
                eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
                return;
            };
            let fx = setup_policy(&url, None, None, false).await;
            // Install the real 0021 triggers on the fixture schema (single source).
            fx.pool
                .get()
                .await
                .unwrap()
                .batch_execute(include_str!(
                    "../../../db/migrations/0021_grouped_camera_no_override_trigger.sql"
                ))
                .await
                .expect("install 0021 triggers");

            let (p2, grp) = named_policy_and_group(&fx.pool, "P2", "G").await;

            // (1) Adding a camera that HOLDS an override into a group auto-clears it
            //     (the camera_group_members BEFORE INSERT trigger).
            let cam_join = insert_cam(&fx.pool, Some(p2)).await;
            join_group(&fx.pool, cam_join, grp).await;
            assert_eq!(
                cam_policy_id(&fx.pool, cam_join).await,
                None,
                "joining a group must auto-clear the direct override (membership trigger)"
            );

            // (2) Pinning a policy on an ALREADY-grouped camera is REJECTED
            //     (the cameras BEFORE UPDATE trigger).
            let cam_grouped = insert_cam(&fx.pool, None).await;
            join_group(&fx.pool, cam_grouped, grp).await;
            let pin = fx
                .pool
                .get()
                .await
                .unwrap()
                .execute(
                    "UPDATE cameras SET policy_id = $1 WHERE id = $2",
                    &[&p2, &cam_grouped],
                )
                .await;
            assert!(
                pin.is_err(),
                "pinning a policy on a grouped camera must be rejected by the trigger"
            );

            // (3) Clearing to NULL on a grouped camera is still allowed (inherit).
            let clear = fx
                .pool
                .get()
                .await
                .unwrap()
                .execute(
                    "UPDATE cameras SET policy_id = NULL WHERE id = $1",
                    &[&cam_grouped],
                )
                .await;
            assert!(
                clear.is_ok(),
                "clearing to NULL on a grouped camera must be allowed"
            );
        }
    }
}
