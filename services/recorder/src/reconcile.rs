// SPDX-License-Identifier: AGPL-3.0-or-later

//! Startup reconciliation — index vs filesystem consistency pass.
//!
//! # Responsibility
//!
//! Run once at startup.  Split into two phases so camera recording starts
//! immediately:
//!
//! * **Phase 1** — fast, inline, mandatory: loads the segment index from the
//!   database into memory and returns.  Completes in milliseconds even with
//!   tens of thousands of segments.
//!
//! * **Phase 2** — slow, background, optional: walks live and archive storage,
//!   deletes dangling rows (rows whose file no longer exists), and indexes
//!   orphan files (files with no matching row).  Runs in a `tokio::spawn`'d
//!   task concurrently with all camera workers.
//!
//! ## What the background pass does
//!
//! 1. **Dangling rows** — rows in the `segments` table whose file no longer
//!    exists.  Delete the row (the file is gone; the row is the lie).
//!
//! 2. **Orphan files** — files on live or archive storage that have no
//!    matching row in `segments`.  This happens when:
//!    * The recorder was killed mid-segment (the file was written but the row
//!      was never inserted).
//!    * An archive move was interrupted after the copy but before the
//!      `update_segment_archive` call.
//!
//!    Strategy: attempt to index the orphan (derive timestamps from the
//!    filename); if the filename is unparseable, quarantine the file by moving
//!    it to a `_quarantine/` subdirectory and logging a warning.
//!
//! 3. **Correctness item 9 specific note**: both live AND archive storages are
//!    scanned.  An interrupted archive move leaves a verified copy in archive
//!    with no row — only scanning the archive storage reclaims it.
//!
//! # Design
//!
//! The reconciler is intentionally conservative: it never deletes a file that
//! has a valid index row, and never inserts a row for a file it cannot reliably
//! parse.  Ambiguous cases go to `_quarantine/` for operator review.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::{DateTime, Duration, Utc};
use crumb_common::{
    config::Config,
    db,
    types::{RecordStream, SegmentStage, SegmentStream},
};
use deadpool_postgres::Pool;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

// ─── rate-limit constant ──────────────────────────────────────────────────────

/// Maximum orphan DB inserts per second during the background pass.
///
/// Keeps the connection pool available for camera workers.  At 40 inserts/sec a
/// backlog of 1 000 orphan files is drained in ~25 s. Now that reconcile runs on
/// a timer (see [`run_periodic`]) the steady-state backlog is tiny, so this rate
/// only governs the one-time catch-up of a large pre-existing backlog (e.g. the
/// non-motion files a motion-mode period left un-indexed). Override with
/// `RECONCILE_ORPHAN_RATE_HZ`.
const ORPHAN_INSERT_RATE_HZ: u64 = 40;

/// Read the orphan-insert rate (Hz) from the environment, clamped to a sane
/// range, falling back to [`ORPHAN_INSERT_RATE_HZ`].
fn orphan_insert_rate_hz() -> u64 {
    std::env::var("RECONCILE_ORPHAN_RATE_HZ")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|&v| (1..=1000).contains(&v))
        .unwrap_or(ORPHAN_INSERT_RATE_HZ)
}

/// Log a progress line every N orphans indexed.
const ORPHAN_PROGRESS_INTERVAL: u64 = 10;

// ─── in-flight / sub-floor integrity gates ────────────────────────────────────

/// Minimum byte length for an orphan file to be indexable. Files smaller than
/// this are header-only skeletons (ffmpeg writes a 28-byte `ftyp`+empty `moov`
/// before any frame). Indexing them produced the prod 215 sub-floor rows; the
/// orphan pass now REJECTS them (audit GAP 4 / P1 #8). Matches the 512-byte floor
/// the repair migration (0008) purges by.
///
/// `pub(crate)` so the LIVE insert path (`recording::index_segment`, R3) can
/// reuse the exact same floor instead of drifting a second copy of the
/// constant.
pub(crate) const SUB_FLOOR_BYTES: u64 = 512;

/// **Phase 1** — confirm the DB is reachable before camera workers start.
///
/// Reconcile no longer loads the entire `segments` table into a `Vec` held for
/// Phase 2's lifetime (audit P2 #12 — that risked an OOM boot-loop at the 1M-row
/// target under the recorder's 4GiB cap). Phase 2 now KEYSET-PAGINATES the table
/// itself, so Phase 1 only needs to verify connectivity (the same fatal-at-startup
/// signal `main.rs` already branches on). One cheap `SELECT 1`.
///
/// # Errors
///
/// Returns an error only if the database is unreachable, which is fatal at
/// startup.
pub async fn load_segment_index(pool: &Pool) -> Result<()> {
    info!("reconcile phase 1: verifying database connectivity");
    let client = db::get_conn(pool)
        .await
        .context("reconcile phase 1: get connection")?;
    client
        .execute("SELECT 1", &[])
        .await
        .context("reconcile phase 1: connectivity check")?;
    info!("reconcile phase 1 complete: database reachable");
    Ok(())
}

// ─── Phase 2: background worker ───────────────────────────────────────────────

/// **Phase 2** — spawn the background reconciliation task and return
/// immediately.
///
/// The returned `JoinHandle` resolves when the background pass completes or is
/// cancelled.  Callers may drop the handle — the task is self-contained and
/// will not panic or hold the pool hostage if dropped.
///
/// # Arguments
///
/// * `pool`    — cloned database pool.  The task holds its own clone.
/// * `config`  — cloned recorder config.
/// * `shutdown` — global shutdown token; Phase 2 stops cleanly when cancelled.
pub fn spawn_background(
    pool: Pool,
    config: Config,
    shutdown: CancellationToken,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        run_periodic(pool, config, shutdown).await;
    })
}

/// Minimum allowed reconcile interval, regardless of configuration.
///
/// A pass walks both storage roots and stats every indexed file, so running it
/// more than once a minute would needlessly load the filesystem with no benefit.
const MIN_RECONCILE_INTERVAL_SECS: u64 = 60;

/// Run [`run_background`] once immediately, then re-run it every
/// `config.reconcile_interval_seconds` until `shutdown` fires.
///
/// Reconcile was originally a single startup pass, so any orphan file a recording
/// reconnect or a motion-mode gap left on disk stayed un-indexed — invisible to
/// the per-policy stats AND to size-cap eviction — until the next recorder
/// restart (and the restart's pass adopts at a rate limit, so a large backlog
/// took ~hours and was often interrupted by the next restart). Re-running on a
/// timer keeps the segment index converged with the filesystem within one
/// interval, so the usage numbers and eviction always act on real bytes.
///
/// Each pass is idempotent: orphan adoption only inserts missing rows (UPSERT),
/// size repair only corrects drifted `size_bytes`, and the dangling pass only
/// deletes rows whose file is truly gone. The first pass runs immediately so a
/// fresh boot catches up its backlog without waiting a full interval.
async fn run_periodic(pool: Pool, config: Config, shutdown: CancellationToken) {
    // Maintenance pause switch: when set, run NO reconcile passes at all (startup
    // catch-up included). Reconcile rewrites a row's on-disk location to match
    // what it last walked, which races any deliberate out-of-band file movement
    // (storage migration / tiering / disk swap); those operations set this so the
    // reconciler can't fight them. Recording/motion/eviction continue regardless.
    if config.reconcile_paused {
        warn!("reconcile is PAUSED (RECONCILE_PAUSED=true); skipping all reconcile passes until restart");
        return;
    }

    let interval_secs = config
        .reconcile_interval_seconds
        .max(MIN_RECONCILE_INTERVAL_SECS);
    let interval = tokio::time::Duration::from_secs(interval_secs);

    loop {
        run_background(pool.clone(), config.clone(), shutdown.clone()).await;

        if shutdown.is_cancelled() {
            break;
        }

        // Sleep until the next pass, but wake immediately on shutdown.
        tokio::select! {
            () = tokio::time::sleep(interval) => {}
            () = shutdown.cancelled() => break,
        }
    }

    info!("reconcile periodic loop stopped");
}

/// Run ONE background reconciliation pass (dangling-row prune + size repair +
/// orphan adoption).
///
/// Invoked once per interval by [`run_periodic`] (and directly by the reconcile
/// integration tests). Each pass is self-contained and idempotent, so repeated
/// invocations converge the segment index toward the on-disk reality without
/// duplicating work.
///
/// KEYSET-PAGINATED (audit P2 #12): the dangling-row pass streams the `segments`
/// table one [`db::RECONCILE_PAGE_SIZE`] page at a time, processing and dropping
/// each page, so peak RSS is `O(page)` not `O(total rows)`. The orphan pass's
/// `indexed_paths` set (storage_id + path only) is built in the same paginated
/// scan — much smaller than the full `Vec<Segment>` the old code held.
async fn run_background(pool: Pool, config: Config, shutdown: CancellationToken) {
    info!("reconcile phase 2: starting background pass (dangling rows + orphan indexing)");

    // ── segment lengths: 1× for end_ts fallbacks + future-mtime slop, 2× to
    //    bound in-flight skips + duration plausibility ─────────────────────────
    let segment_len = Duration::seconds(i64::from(config.segment_seconds));
    let twice_segment = Duration::seconds(i64::from(config.segment_seconds) * 2);

    // ── dangling-row pass (paginated) ─────────────────────────────────────────
    //
    // For every row in `segments`, confirm the file still exists on disk. If the
    // file is missing the row is the lie — delete it. If the file is PRESENT but
    // SHORTER than the row claims, repair size_bytes (audit GAP 3 / P1 #8 — so
    // reconcile can SEE truncation instead of trusting a stale larger size).
    //
    // We also accumulate the indexed-path set for the orphan pass as we go, so we
    // never hold the whole table in memory at once.

    let mut storage_cache: HashMap<Uuid, String> = HashMap::new();
    let mut dangling_count = 0u64;
    let mut size_repaired_count = 0u64;
    let mut indexed_paths: HashSet<(String, String)> = HashSet::new();

    let mut cursor = Uuid::nil();
    'pages: loop {
        if shutdown.is_cancelled() {
            warn!("reconcile phase 2: shutdown requested; aborting dangling-row pass early");
            return;
        }

        let page = match db::list_segments_after(&pool, cursor, db::RECONCILE_PAGE_SIZE).await {
            Ok(p) => p,
            Err(e) => {
                error!(error = %e, "reconcile phase 2: failed to load segment page; aborting dangling pass");
                return;
            }
        };
        if page.is_empty() {
            break;
        }
        // Advance the keyset cursor to the last id in this page.
        if let Some(last) = page.last() {
            cursor = last.id;
        }

        for seg in &page {
            if shutdown.is_cancelled() {
                warn!("reconcile phase 2: shutdown requested; aborting dangling-row pass early");
                return;
            }

            // Resolve storage path (cached).
            let storage_path = match storage_cache.get(&seg.storage_id) {
                Some(p) => p.clone(),
                None => match db::get_storage(&pool, seg.storage_id).await {
                    Ok(Some(s)) => {
                        storage_cache.insert(seg.storage_id, s.path.clone());
                        s.path
                    }
                    Ok(None) => {
                        warn!(
                            segment_id   = %seg.id,
                            storage_id   = %seg.storage_id,
                            "segment row references unknown storage_id — deleting dangling row"
                        );
                        if let Err(e) = db::delete_segment_row(&pool, seg.id).await {
                            error!(segment_id = %seg.id, error = %e, "failed to delete dangling row");
                        } else {
                            dangling_count += 1;
                        }
                        continue;
                    }
                    Err(e) => {
                        error!(
                            segment_id = %seg.id,
                            storage_id = %seg.storage_id,
                            error = %e,
                            "failed to resolve storage for segment; skipping"
                        );
                        continue;
                    }
                },
            };

            // Record this row's (storage ROOT PATH, rel path) for the orphan pass.
            // Key by the storage PATH, NOT its id: prod has DUPLICATE storage rows
            // for the same /data/live and /data/archive paths (e.g. "2TB NVMe" vs
            // "NVMe-Live"); segments may reference either, and reconcile looks the
            // storage up by config NAME — keying by id made every file on the
            // other duplicate row look like an orphan (510k false orphans).
            indexed_paths.insert((storage_path.replace('\\', "/"), seg.path.replace('\\', "/")));

            let abs_path = PathBuf::from(&storage_path).join(&seg.path);

            match tokio::fs::metadata(&abs_path).await {
                Ok(meta) => {
                    // IN-FLIGHT GATE (same guard the orphan pass uses below): if the
                    // file was modified within 2×segment_seconds it may be one a
                    // camera worker is ACTIVELY (re)writing — e.g. a rapid restart
                    // reopened the same strftime filename and it is momentarily back
                    // at the 28-byte ftyp skeleton. Mutating its row this pass would
                    // race the writer: the sub-floor branch would delete the file +
                    // row out from under live ffmpeg (data loss), and the size-repair
                    // branch would clamp the row to a transient partial length. Skip
                    // it; a later pass (once it has settled) reconciles it correctly.
                    // The recorder's own boundary insert keeps the row accurate
                    // meanwhile. This matters now that reconcile runs periodically,
                    // not just at a quiescent startup.
                    //
                    // #84 follow-up: this gate must use the SAME future-mtime-aware
                    // helper as the orphan pass ([`mtime_in_flight`]). The raw
                    // `now - mtime < twice_segment` check it previously used is
                    // trivially true for ANY future mtime (the difference is
                    // negative), so after a backwards clock step the file was
                    // "in flight" on every pass FOREVER — a torn 28-byte skeleton
                    // row+file was never reconciled. An mtime more than one segment
                    // length in the future is implausible, not "recent": treat it
                    // as settled and reconcile it normally.
                    if let Ok(mtime) = meta.modified() {
                        let mtime_utc: DateTime<Utc> = mtime.into();
                        if mtime_in_flight(Utc::now(), mtime_utc, segment_len, twice_segment) {
                            debug!(
                                segment_id = %seg.id,
                                path = %abs_path.display(),
                                "segment file modified too recently (in-flight); skipping dangling check this pass"
                            );
                            continue;
                        }
                    }

                    // File exists — but does its on-disk length match the row?
                    // A present-but-short file means a torn/truncated write the
                    // existence-only check used to miss forever (audit GAP 3).
                    let on_disk = meta.len() as i64;

                    // SUB-FLOOR CHECK (R3b): this must run REGARDLESS of whether
                    // `on_disk` drifted from `seg.size_bytes`. Previously it only
                    // fired inside the `on_disk != seg.size_bytes` branch, so a
                    // file that is PERSISTENTLY sub-floor (e.g. a 28-byte
                    // ftyp-only skeleton whose row was ALSO indexed at 28 bytes —
                    // the on-disk length matching the claimed length exactly) was
                    // never caught: `on_disk == seg.size_bytes` skipped straight
                    // to the "confirmed" branch below and the unusable row lived
                    // forever. A sub-floor file is unusable no matter what the
                    // row claims, so check it first and unconditionally.
                    if on_disk < SUB_FLOOR_BYTES as i64 {
                        // Truncated/skeleton below the playable floor — treat as
                        // a dangling row: the bytes are unusable. Delete file
                        // then row (file-then-row; NotFound-tolerant).
                        warn!(
                            segment_id = %seg.id,
                            path       = %abs_path.display(),
                            on_disk, claimed = seg.size_bytes,
                            "segment file below sub-floor byte count — removing unusable file + row"
                        );
                        match tokio::fs::remove_file(&abs_path).await {
                            Ok(()) | Err(_) => {}
                        }
                        if let Err(de) = db::delete_segment_row(&pool, seg.id).await {
                            error!(segment_id = %seg.id, error = %de, "failed to delete sub-floor row");
                        } else {
                            dangling_count += 1;
                        }
                    } else if on_disk != seg.size_bytes {
                        // Repair the row's size to the real on-disk length so
                        // eviction math + range reads are correct.
                        warn!(
                            segment_id = %seg.id,
                            path       = %abs_path.display(),
                            on_disk, claimed = seg.size_bytes,
                            "segment size drift — repairing size_bytes to on-disk length"
                        );
                        if let Err(e) = db::update_segment_size_bytes(&pool, seg.id, on_disk).await
                        {
                            error!(segment_id = %seg.id, error = %e, "failed to repair segment size");
                        } else {
                            size_repaired_count += 1;
                        }
                    } else {
                        debug!(segment_id = %seg.id, path = %abs_path.display(), "segment file confirmed");
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    // RE-VERIFY BEFORE DELETE (defect 2 / correctness item 10
                    // hardening): `seg` and `abs_path` were captured from the
                    // page snapshot taken at the START of this pass, which can
                    // be tens of seconds stale on a large table. In that
                    // window the row may have been:
                    //   * relocated by the live→archive migration (its
                    //     storage_id/path changed to the new location — the
                    //     file we just stat'd under the OLD path is
                    //     legitimately gone), or
                    //   * quarantined-then-reindexed, or otherwise updated.
                    // Re-fetch the row by id and re-resolve its CURRENT
                    // storage_id + path; only delete if the file is STILL
                    // missing at its current location. This is the second
                    // half of the footage-loss fix: defect 1 (quarantine on
                    // conflict) is what orphaned rows in the first place, but
                    // this re-verify independently defends against any
                    // stale-snapshot dangling delete, including the archive
                    // migration race.
                    match db::get_segment(&pool, seg.id).await {
                        Ok(None) => {
                            // Row is already gone (deleted by someone else
                            // concurrently) — nothing to do.
                            debug!(
                                segment_id = %seg.id,
                                "segment row vanished before re-verify; nothing to delete"
                            );
                        }
                        Ok(Some(current)) => {
                            let current_storage_path = match storage_cache.get(&current.storage_id)
                            {
                                Some(p) => Some(p.clone()),
                                None => match db::get_storage(&pool, current.storage_id).await {
                                    Ok(Some(s)) => {
                                        storage_cache.insert(current.storage_id, s.path.clone());
                                        Some(s.path)
                                    }
                                    Ok(None) => None,
                                    Err(e) => {
                                        error!(
                                            segment_id = %seg.id,
                                            error = %e,
                                            "failed to resolve current storage for re-verify; skipping delete this pass"
                                        );
                                        None
                                    }
                                },
                            };

                            let Some(current_storage_path) = current_storage_path else {
                                continue;
                            };

                            let current_abs_path =
                                PathBuf::from(&current_storage_path).join(&current.path);

                            match tokio::fs::metadata(&current_abs_path).await {
                                Ok(_) => {
                                    // File exists at its CURRENT location — the
                                    // row moved (or was fixed up) since the
                                    // page snapshot. Not dangling; skip.
                                    debug!(
                                        segment_id = %seg.id,
                                        old_path = %abs_path.display(),
                                        current_path = %current_abs_path.display(),
                                        "segment file re-verify: file exists at current location; row is NOT dangling — skipping delete"
                                    );
                                }
                                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                                    warn!(
                                        segment_id = %seg.id,
                                        path       = %current_abs_path.display(),
                                        "segment file missing — deleting dangling row (correctness item 10, re-verified)"
                                    );
                                    if let Err(de) = db::delete_segment_row(&pool, seg.id).await {
                                        error!(segment_id = %seg.id, error = %de, "failed to delete dangling segment row");
                                    } else {
                                        dangling_count += 1;
                                    }
                                }
                                Err(e) => {
                                    error!(
                                        segment_id = %seg.id,
                                        path       = %current_abs_path.display(),
                                        error      = %e,
                                        "filesystem error re-verifying segment file before delete; skipping"
                                    );
                                }
                            }
                        }
                        Err(e) => {
                            error!(
                                segment_id = %seg.id,
                                error = %e,
                                "failed to re-fetch segment row for dangling re-verify; skipping delete this pass"
                            );
                        }
                    }
                }
                Err(e) => {
                    error!(
                        segment_id = %seg.id,
                        path       = %abs_path.display(),
                        error      = %e,
                        "filesystem error checking segment file; skipping"
                    );
                }
            }
        }

        // A short page is the last page.
        if page.len() < db::RECONCILE_PAGE_SIZE as usize {
            break 'pages;
        }
    }

    info!(
        deleted = dangling_count,
        size_repaired = size_repaired_count,
        "reconcile phase 2: dangling row pass complete"
    );

    // ── orphan-file pass ─────────────────────────────────────────────────────
    //
    // Walk EVERY storage root (A1b), not just the two config-NAME defaults. A
    // segment's physical location is owned by its storage_id, and footage can live
    // on any per-policy disk; scanning only the default live/archive disks left
    // footage on a non-default disk un-adopted and un-dangling-checked. We resolve
    // every `storages` row and walk all of them.
    //
    // For each .mp4 file found, check whether a segment row references it. If not,
    // try to index it (conservatively — see `try_index_orphan`); if we cannot
    // parse the filename, quarantine it.
    //
    // `indexed_paths` was accumulated during the paginated dangling pass above.

    let all_storages = match db::list_storages(&pool)
        .await
        .context("listing storages for reconciliation")
    {
        Ok(v) => v,
        Err(e) => {
            error!(error = %e, "reconcile phase 2: cannot list storages; aborting orphan pass");
            return;
        }
    };

    // `stage` is a RETENTION label, not a location selector — but a newly-adopted
    // truly-orphan row still needs one. An orphan found on an ARCHIVE destination
    // disk must be adopted as stage=archive: labelling it Live mis-scoped its
    // retention (archive tiers often keep footage far longer than live) and
    // pointed the next cron archive run at a "live" segment already sitting at
    // its archive destination (the issue-#70 family — archive.rs now also guards
    // that self-copy, but the label should simply be right at adoption).
    //
    // Archive destinations are the configured ARCHIVE-default disk PLUS every
    // policy's `archive_storage_id` (previously only the config-name default was
    // labelled Archive, so orphans on a per-policy archive disk were adopted as
    // Live). A storage that is ALSO a live destination (some policy's
    // `live_storage_id`, or the configured live default — e.g. a shared
    // live==archive directory expressed as one row) stays labelled Live, the
    // conservative recording stage, exactly as before.
    let mut archive_storage_ids: HashSet<Uuid> = HashSet::new();
    let mut live_storage_ids: HashSet<Uuid> = HashSet::new();
    match db::get_storage_by_name(&pool, &config.archive_storage_name).await {
        Ok(opt) => {
            if let Some(s) = opt {
                archive_storage_ids.insert(s.id);
            }
        }
        Err(e) => {
            // Non-fatal: without it we just label fewer disks Archive (safe).
            warn!(error = %e, "reconcile phase 2: cannot resolve archive-default storage");
        }
    }
    match db::get_storage_by_name(&pool, &config.live_storage_name).await {
        Ok(opt) => {
            if let Some(s) = opt {
                live_storage_ids.insert(s.id);
            }
        }
        Err(e) => {
            warn!(error = %e, "reconcile phase 2: cannot resolve live-default storage");
        }
    }
    match db::list_policies(&pool).await {
        Ok(policies) => {
            for p in &policies {
                if let Some(id) = p.archive_storage_id {
                    archive_storage_ids.insert(id);
                }
                if let Some(id) = p.live_storage_id {
                    live_storage_ids.insert(id);
                }
            }
        }
        Err(e) => {
            // Non-fatal: fall back to the storage-name defaults resolved above.
            warn!(error = %e, "reconcile phase 2: cannot list policies for archive-stage labelling; using storage-name defaults only");
        }
    }

    let storages_to_scan: Vec<(Uuid, PathBuf, SegmentStage)> = all_storages
        .into_iter()
        .map(|s| {
            let is_archive_dest =
                archive_storage_ids.contains(&s.id) && !live_storage_ids.contains(&s.id);
            let stage = if is_archive_dest {
                SegmentStage::Archive
            } else {
                SegmentStage::Live
            };
            (s.id, PathBuf::from(&s.path), stage)
        })
        .collect();

    // Collect ALL orphan paths first (filesystem walk), then rate-limit the
    // DB inserts.  This keeps the walk phase self-contained and makes the
    // progress log meaningful (we know the total before starting inserts).
    struct OrphanEntry {
        abs_path: PathBuf,
        storage_id: Uuid,
        storage_root: PathBuf,
        rel_path: String,
        stage: SegmentStage,
    }

    let mut orphan_entries: Vec<OrphanEntry> = Vec::new();
    let mut orphan_quarantined = 0u64;

    for (storage_id, storage_root, stage) in &storages_to_scan {
        if shutdown.is_cancelled() {
            warn!("reconcile phase 2: shutdown requested; aborting storage walk");
            return;
        }

        if tokio::fs::metadata(storage_root).await.is_err() {
            debug!(root = %storage_root.display(), "storage root does not exist or is inaccessible; skipping walk");
            continue;
        }

        let mp4_files = match walk_storage(storage_root).await {
            Ok(files) => files,
            Err(e) => {
                error!(root = %storage_root.display(), error = %e, "failed to walk storage; skipping");
                continue;
            }
        };

        info!(
            storage_root = %storage_root.display(),
            stage = %stage.as_str(),
            file_count = mp4_files.len(),
            "reconcile phase 2: walking storage for orphan detection"
        );

        for abs_path in mp4_files {
            let rel_path = match abs_path.strip_prefix(storage_root) {
                Ok(rel) => rel.to_string_lossy().replace('\\', "/"),
                Err(_) => {
                    warn!(path = %abs_path.display(), "could not strip storage prefix; skipping");
                    continue;
                }
            };

            if indexed_paths.contains(&(
                storage_root.to_string_lossy().replace('\\', "/"),
                rel_path.clone(),
            )) {
                debug!(path = %rel_path, "file already indexed; skipping");
                continue;
            }

            // IN-FLIGHT GATE (audit GAP 5 / P0 #3): the orphan walk races live
            // camera workers on every boot. A file whose mtime is within
            // 2×segment_seconds of NOW is almost certainly one ffmpeg is STILL
            // writing — indexing it produced the prod 28-byte ftyp-only rows.
            // Skip it; the recorder's own boundary insert (or a later reconcile)
            // will index it once it is complete. A FUTURE mtime beyond one
            // segment length of clock slop is implausible, not "recent" — see
            // [`mtime_in_flight`] — and must not gate the file forever.
            match tokio::fs::metadata(&abs_path).await {
                Ok(meta) => {
                    if let Ok(mtime) = meta.modified() {
                        let mtime_utc: DateTime<Utc> = mtime.into();
                        if mtime_in_flight(Utc::now(), mtime_utc, segment_len, twice_segment) {
                            debug!(
                                path = %rel_path,
                                "orphan file modified too recently (in-flight); skipping this boot"
                            );
                            continue;
                        }
                    }
                }
                Err(e) => {
                    debug!(path = %rel_path, error = %e, "cannot stat orphan candidate; skipping");
                    continue;
                }
            }

            info!(
                path  = %rel_path,
                stage = %stage.as_str(),
                "reconcile phase 2: found orphan file"
            );

            orphan_entries.push(OrphanEntry {
                abs_path,
                storage_id: *storage_id,
                storage_root: storage_root.clone(),
                rel_path,
                stage: *stage,
            });
        }
    }

    // ── rate-limited DB insert loop ──────────────────────────────────────────

    let total_orphans = orphan_entries.len() as u64;
    info!(
        total = total_orphans,
        "reconcile phase 2: beginning rate-limited orphan indexing"
    );

    // One tick per insert at ORPHAN_INSERT_RATE_HZ; start immediately so the
    // first insert does not wait a full interval.
    let insert_period = tokio::time::Duration::from_millis(1_000 / orphan_insert_rate_hz());
    let mut rate_interval = tokio::time::interval(insert_period);
    rate_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let mut orphan_indexed = 0u64;

    for entry in orphan_entries {
        // Honour shutdown.
        if shutdown.is_cancelled() {
            warn!(
                indexed = orphan_indexed,
                remaining = total_orphans.saturating_sub(orphan_indexed),
                "reconcile phase 2: shutdown requested; stopping orphan indexing"
            );
            return;
        }

        // Wait for the rate-limit token (first tick resolves immediately).
        rate_interval.tick().await;

        match try_index_orphan(
            &pool,
            &entry.abs_path,
            &entry.storage_root,
            entry.storage_id,
            &entry.rel_path,
            &entry.stage,
            segment_len,
            twice_segment,
        )
        .await
        {
            Ok(OrphanOutcome::Indexed) => {
                orphan_indexed += 1;
                // Progress log every ORPHAN_PROGRESS_INTERVAL indexed.
                if orphan_indexed.is_multiple_of(ORPHAN_PROGRESS_INTERVAL) {
                    info!(
                        indexed = orphan_indexed,
                        remaining = total_orphans.saturating_sub(orphan_indexed),
                        "reconcile phase 2: orphan indexing progress"
                    );
                }
            }
            Ok(OrphanOutcome::AlreadyIndexed) => {
                // A row already exists at this key — this is real,
                // already-indexed footage (often the recorder's own
                // freshly-written segment), NOT junk. Do NOT quarantine it
                // (this is the fix for the footage-loss bug: quarantining
                // here orphaned the valid row, and the next pass deleted the
                // row as "dangling" once the file was gone).
                debug!(
                    path = %entry.abs_path.display(),
                    "reconcile phase 2: orphan key already indexed; leaving file in place"
                );
            }
            Ok(OrphanOutcome::NotIndexable) => {
                // Genuinely unindexable junk — quarantine.
                warn!(
                    path = %entry.abs_path.display(),
                    "reconcile phase 2: orphan file not indexable; quarantining"
                );
                if let Err(e) = quarantine_file(&entry.abs_path, &entry.storage_root).await {
                    error!(
                        path  = %entry.abs_path.display(),
                        error = %e,
                        "failed to quarantine orphan file"
                    );
                } else {
                    orphan_quarantined += 1;
                }
            }
            Err(e) => {
                error!(
                    path  = %entry.abs_path.display(),
                    error = %e,
                    "error while trying to index orphan file; skipping"
                );
            }
        }
    }

    info!(
        dangling_deleted = dangling_count,
        orphan_indexed = orphan_indexed,
        orphan_quarantined = orphan_quarantined,
        total_orphans_found = total_orphans,
        "reconcile phase 2 complete"
    );

    // ── quarantine retention prune ───────────────────────────────────────────
    //
    // The reconcile passes above MOVE unindexable junk into `_quarantine/` but
    // nothing ever cleans it, so it grows unbounded (prod reached 110 GB / 36k
    // files in a month before a manual purge). Auto-purge quarantine files older
    // than the operator-configured retention. This is the ONLY code that ever
    // deletes from `_quarantine/`; the orphan walk deliberately skips that dir
    // (see `walk_storage`), so nothing here races the adoption logic.
    //
    // `0` DISABLES the prune (keep-forever opt-out); a read error skips the prune
    // this pass rather than guessing a retention. See `prune_quarantine` for the
    // deletion guards that keep this bounded to aged quarantine files only.
    let retention_days = match db::get_quarantine_retention_days(&pool).await {
        Ok(d) => d,
        Err(e) => {
            warn!(error = %e, "reconcile phase 2: cannot read quarantine retention; skipping prune this pass");
            0
        }
    };
    if retention_days > 0 {
        // Prod can carry DUPLICATE storage rows for the same on-disk path (see
        // the orphan pass's note); pruning the same `_quarantine/` twice is
        // harmless but noisy, so dedupe roots first.
        let mut seen_roots: HashSet<PathBuf> = HashSet::new();
        let mut pruned_files = 0u64;
        let mut pruned_bytes = 0u64;
        for (_id, storage_root, _stage) in &storages_to_scan {
            if shutdown.is_cancelled() {
                warn!("reconcile phase 2: shutdown requested; stopping quarantine prune");
                break;
            }
            if !seen_roots.insert(storage_root.clone()) {
                continue;
            }
            let (files, bytes) = prune_quarantine(storage_root, retention_days).await;
            pruned_files += files;
            pruned_bytes += bytes;
        }
        info!(
            files = pruned_files,
            bytes = pruned_bytes,
            retention_days,
            "reconcile phase 2: quarantine retention prune complete"
        );
    }
}

// ─── legacy entry point (kept for any external callers) ───────────────────────

/// Run the full reconciliation pass synchronously (inline).
///
/// **Deprecated for production use** — prefer [`load_segment_index`] +
/// [`spawn_background`] so camera workers start immediately.  This function
/// is retained to avoid breaking any callers outside `main.rs`.
///
/// # Errors
///
/// Returns an error if the database is unreachable.
#[allow(dead_code)]
pub async fn run(pool: &Pool, config: &Config) -> Result<()> {
    info!("starting startup reconciliation (legacy inline path)");
    load_segment_index(pool).await?;
    let shutdown = CancellationToken::new(); // never cancelled — runs to completion
    run_background(pool.clone(), config.clone(), shutdown).await;
    info!("startup reconciliation complete");
    Ok(())
}

// ─── orphan indexing ──────────────────────────────────────────────────────────

/// Outcome of [`try_index_orphan`].
///
/// Replaces a plain `bool` (defect 1 in the footage-loss bug): the old code
/// conflated "genuinely unindexable junk" with "a row already exists for this
/// key" into a single `Ok(false)`, and the caller quarantined BOTH — which
/// meant the reconciler quarantined its own freshly-written, already-indexed
/// footage on every conflict. The three outcomes let the caller tell them
/// apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OrphanOutcome {
    /// A brand-new row was inserted for a truly orphaned file.
    Indexed,
    /// A row already exists at this `(camera_id, stream, start_ts)` key — the
    /// file is real, already-indexed footage. Leave it exactly where it is.
    AlreadyIndexed,
    /// The file is genuinely unindexable (unparseable name, unknown camera,
    /// below the sub-floor, etc). Safe to quarantine.
    NotIndexable,
}

/// In-flight gate shared by the ORPHAN pass and the DANGLING-ROW pass: `true`
/// when `mtime` says the file may still be actively written, so adoption (or a
/// row mutation / sub-floor delete) must wait for a later pass.
///
/// A file modified within `twice_segment` of `now` is almost certainly one
/// ffmpeg is still writing (indexing those produced the prod 28-byte ftyp-only
/// rows). But an mtime more than one segment length in the FUTURE is not
/// "recent" — it is implausible (a clock step, a copied/restored file) — and
/// the pre-fix arithmetic (`now - mtime < twice_segment`, which is trivially
/// true when the difference is negative) kept such files "in flight" FOREVER:
/// never adopted, never counted toward any budget, silently eating disk
/// (issue #84). Treat them as settled and adoptable; [`try_index_orphan`]
/// already ignores an implausible mtime and derives timestamps from the
/// filename. Up to one segment length of future skew is still tolerated as
/// ordinary clock slop (a segment being written right now legitimately carries
/// an mtime a moment ahead of a slightly-behind reader clock).
fn mtime_in_flight(
    now: DateTime<Utc>,
    mtime: DateTime<Utc>,
    segment_len: Duration,
    twice_segment: Duration,
) -> bool {
    if mtime > now + segment_len {
        return false; // implausible future mtime — settled, adoptable
    }
    now - mtime < twice_segment
}

/// Attempt to index an orphan file.
///
/// Returns [`OrphanOutcome::Indexed`] if a new row was inserted,
/// [`OrphanOutcome::AlreadyIndexed`] if a row already exists at this key (the
/// file must NOT be quarantined), [`OrphanOutcome::NotIndexable`] if the file
/// is genuine junk (caller should quarantine), or `Err` on a database /
/// filesystem error.
///
/// `segment_len` is the nominal segment length (the `end_ts` fallback);
/// `max_segment_len` (2×) is the mtime plausibility window only.
///
/// The path structure is expected to be:
/// `{storage_root}/{camera_id}/{YYYY}/{MM}/{DD}/{timestamp}.mp4`
#[allow(clippy::too_many_arguments)]
async fn try_index_orphan(
    pool: &Pool,
    abs_path: &Path,
    storage_root: &Path,
    storage_id: Uuid,
    rel_path: &str,
    stage: &SegmentStage,
    segment_len: Duration,
    max_segment_len: Duration,
) -> Result<OrphanOutcome> {
    // Parse the segment start timestamp from the filename.
    let filename = abs_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();

    let start_ts = match crate::recording::parse_segment_timestamp(&filename) {
        Ok(ts) => ts,
        Err(_) => {
            debug!(filename = %filename, "cannot parse timestamp from filename");
            return Ok(OrphanOutcome::NotIndexable);
        }
    };

    // Extract camera_id from the path: storage_root/camera_id/YYYY/MM/DD/file.
    // The first component after the storage root is the camera_id.
    let rel = match abs_path.strip_prefix(storage_root) {
        Ok(r) => r,
        Err(_) => return Ok(OrphanOutcome::NotIndexable),
    };

    let mut components = rel.components();
    let camera_id_str = match components.next() {
        Some(c) => c.as_os_str().to_string_lossy().into_owned(),
        None => {
            debug!(path = %rel_path, "orphan file not in expected directory structure");
            return Ok(OrphanOutcome::NotIndexable);
        }
    };

    let camera_id: Uuid = match camera_id_str.parse() {
        Ok(id) => id,
        Err(_) => {
            debug!(dir = %camera_id_str, "first directory component is not a UUID; not indexable");
            return Ok(OrphanOutcome::NotIndexable);
        }
    };

    // Verify the camera exists in the DB (and keep it: its effective policy
    // tells us which stream this camera records — issue #84 below).
    let camera = match db::get_camera(pool, camera_id).await {
        Ok(None) => {
            warn!(
                camera_id = %camera_id,
                path = %rel_path,
                "orphan file references unknown camera_id; not indexable"
            );
            return Ok(OrphanOutcome::NotIndexable);
        }
        Err(e) => {
            return Err(e.context("looking up camera for orphan indexing"));
        }
        Ok(Some(cam)) => cam,
    };

    // Get file size.
    let metadata = tokio::fs::metadata(abs_path)
        .await
        .with_context(|| format!("stat orphan file {}", abs_path.display()))?;
    let size_bytes = metadata.len() as i64;

    // SUB-FLOOR REJECT (audit GAP 4 / P1 #8): a header-only/zero-byte file is not
    // a valid segment — indexing it produced the prod 28-byte rows that serve a
    // black pane on scrub. Quarantine (return NotIndexable) instead of indexing.
    if metadata.len() < SUB_FLOOR_BYTES {
        debug!(
            path = %rel_path,
            size = metadata.len(),
            "orphan file below {SUB_FLOOR_BYTES}-byte floor (header-only/empty); not indexable"
        );
        return Ok(OrphanOutcome::NotIndexable);
    }

    // For end_ts: use the file's modification time as a best-effort estimate,
    // CLAMPED so a reset/copied mtime can't manufacture a multi-hour duration
    // (audit GAP / P1 #6 — prod had 806 rows up to 49h). Falls back to
    // start_ts + ONE nominal segment length when mtime is unavailable or
    // implausible — NOT the 2× plausibility window, which would manufacture a
    // double-length segment (issue #84); 2× is only how far an mtime may
    // legitimately land past start_ts (a real segment can run somewhat long).
    let fallback_end = start_ts + segment_len;
    let end_ts = match metadata.modified() {
        Ok(mtime) => {
            let mtime_utc: DateTime<Utc> = mtime.into();
            // mtime must be AFTER start and within one (×2) segment length of it;
            // anything else is a copied/recovered mtime, not the true segment end.
            if mtime_utc <= start_ts || (mtime_utc - start_ts) > max_segment_len {
                fallback_end
            } else {
                mtime_utc
            }
        }
        Err(_) => fallback_end,
    };

    let duration_ms = (end_ts - start_ts).num_milliseconds().max(0) as i32;

    // Adopt with the STREAM the camera's effective policy actually records
    // (issue #84): hardcoding Main mislabelled sub-stream cameras' footage and
    // weakened the (camera_id, stream, start_ts) AlreadyIndexed guard — a
    // sub-stream camera's real row never collided with a Main-labelled adopt.
    // The RecordStream→SegmentStream mapping is total, so Main remains the
    // value only for cameras that record main (the previous default).
    let stream = match camera.policy.record_stream {
        RecordStream::Main => SegmentStream::Main,
        RecordStream::Sub => SegmentStream::Sub,
    };

    let params = db::InsertSegmentParams {
        camera_id,
        storage_id,
        stage: *stage,
        path: rel_path.to_owned(),
        stream,
        start_ts,
        end_ts,
        duration_ms,
        has_motion: false,
        motion_score: 0.0, // orphan-file reindex has no motion signals to score
        size_bytes,
        motion_bbox: None, // orphan-file reindex has no motion region
    };

    // CONSERVATIVE adoption (C1): a segment's physical location is defined ONLY
    // by its storage_id + path. Reconcile walks the filesystem and must NEVER
    // relocate a healthy row: if a row already exists at (camera_id, stream,
    // start_ts) we leave it exactly as-is (it may legitimately point at a
    // different disk than the file we just walked — a stray duplicate). Only
    // TRULY-orphan keys (no existing row) are adopted. `insert_segment_if_absent`
    // is `ON CONFLICT … DO NOTHING`, so this is strictly additive — the recorder's
    // own live-finalize path keeps `insert_segment`'s adopting behaviour.
    match db::insert_segment_if_absent(pool, &params)
        .await
        .with_context(|| format!("indexing orphan file {rel_path}"))?
    {
        Some(_) => {
            info!(
                path     = %rel_path,
                start_ts = %start_ts,
                end_ts   = %end_ts,
                camera_id = %camera_id,
                "indexed orphan file"
            );
            Ok(OrphanOutcome::Indexed)
        }
        None => {
            // A row already exists at this key (`insert_segment_if_absent`'s
            // ON CONFLICT ... DO NOTHING reported a conflict). This is REAL,
            // already-indexed footage — often the recorder's own freshly
            // written segment — not junk. Defect 1: the old code returned
            // Ok(false) here, indistinguishable from genuine junk, and the
            // caller quarantined the file — orphaning its own valid row and
            // causing the next pass to delete it as "dangling". Leave the
            // file exactly where it is.
            debug!(
                path      = %rel_path,
                start_ts  = %start_ts,
                camera_id = %camera_id,
                "orphan key already has a segment row; leaving file unchanged (conservative skip, NOT quarantined)"
            );
            Ok(OrphanOutcome::AlreadyIndexed)
        }
    }
}

// ─── quarantine_file ─────────────────────────────────────────────────────────

/// Move a file to the quarantine directory within its storage root.
///
/// The quarantine directory is `<storage_root>/_quarantine/<camera_id>/`,
/// mirroring the camera subdirectory the file came from (hygiene fix, defect
/// 4). The original layout flattened everything into a single
/// `_quarantine/<name>` directory, which COLLIDES across cameras: segment
/// filenames are timestamp-derived, so two cameras can legitimately produce
/// the same-second filename and the second quarantine would silently
/// overwrite/rename-suffix the first, making operator review unreliable.
/// Files are moved rather than deleted so the operator can inspect them.
///
/// # Arguments
///
/// * `file_path`    — absolute path of the file to quarantine.
/// * `storage_root` — storage root that contains the file.
///
/// # Errors
///
/// Returns an error if the move fails (e.g. cross-device).  In that case the
/// caller should log and continue rather than aborting the reconciliation pass.
pub async fn quarantine_file(file_path: &Path, storage_root: &Path) -> Result<()> {
    // Preserve the camera subdirectory: the on-disk layout is
    // `{storage_root}/{camera_id}/{YYYY}/{MM}/{DD}/{file}`, so the first path
    // component under storage_root is the camera_id. Fall back to the flat
    // `_quarantine/` root if the path doesn't fit that shape (defensive —
    // still better than erroring the whole quarantine operation).
    let camera_subdir = file_path
        .strip_prefix(storage_root)
        .ok()
        .and_then(|rel| rel.components().next())
        .map(|c| c.as_os_str().to_owned());

    let quarantine_dir = match &camera_subdir {
        Some(cam) => storage_root.join("_quarantine").join(cam),
        None => storage_root.join("_quarantine"),
    };
    tokio::fs::create_dir_all(&quarantine_dir)
        .await
        .with_context(|| format!("creating quarantine dir {}", quarantine_dir.display()))?;

    let filename = file_path.file_name().ok_or_else(|| {
        anyhow::anyhow!(
            "quarantine_file: path has no filename: {}",
            file_path.display()
        )
    })?;

    // Avoid collisions: prefix with a timestamp if the filename already exists.
    let dst_candidate = quarantine_dir.join(filename);
    let dst = if tokio::fs::try_exists(&dst_candidate).await.unwrap_or(false) {
        let ts = Utc::now().format("%Y%m%dT%H%M%S%.3fZ");
        let stem = Path::new(filename)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let ext = Path::new(filename)
            .extension()
            .map(|e| e.to_string_lossy().into_owned())
            .unwrap_or_default();
        quarantine_dir.join(format!("{stem}_{ts}.{ext}"))
    } else {
        dst_candidate
    };

    // Prefer rename (atomic, same filesystem) — fall back to copy+delete for
    // cross-device moves.
    match tokio::fs::rename(file_path, &dst).await {
        Ok(()) => {
            info!(
                src = %file_path.display(),
                dst = %dst.display(),
                "quarantined file via rename"
            );
            stamp_quarantine_entry_time(&dst);
            Ok(())
        }
        Err(e) if e.raw_os_error() == Some(libc_cross_device_error()) => {
            // Cross-device: copy then delete.
            tokio::fs::copy(file_path, &dst)
                .await
                .with_context(|| format!("copy {} → {}", file_path.display(), dst.display()))?;
            tokio::fs::remove_file(file_path).await.with_context(|| {
                format!(
                    "delete source after cross-device quarantine copy: {}",
                    file_path.display()
                )
            })?;
            info!(
                src = %file_path.display(),
                dst = %dst.display(),
                "quarantined file via copy+delete (cross-device)"
            );
            stamp_quarantine_entry_time(&dst);
            Ok(())
        }
        Err(e) => Err(anyhow::anyhow!(
            "failed to quarantine {} → {}: {e}",
            file_path.display(),
            dst.display()
        )),
    }
}

/// Stamp a just-quarantined file's mtime to NOW — the quarantine-ENTRY time.
///
/// The prune's age gate reads mtime, and a same-filesystem `rename` preserves
/// the original RECORDING-time mtime — which silently turned the
/// "review-then-purge grace window" into `retention − (age at quarantine)`,
/// clamped at zero (issue #277): a file already older than the window at entry
/// was deleted by the very next prune, possibly in the SAME reconcile pass
/// (e.g. a deleted camera's entire history, orphaned → quarantined → purged
/// within ~15 minutes, no review window at all). Touching mtime on arrival
/// gives every quarantined file the FULL window from the moment an operator
/// could first see it in `_quarantine/`.
///
/// Best-effort: on a filesystem where this fails, the old mtime remains and
/// that file falls back to recording-age pruning — logged loudly so the
/// degradation is visible, and never a reason to fail the quarantine itself
/// (parking the file safely still comes first).
fn stamp_quarantine_entry_time(path: &Path) {
    let touch = || -> std::io::Result<()> {
        let f = std::fs::File::options().append(true).open(path)?;
        f.set_times(std::fs::FileTimes::new().set_modified(std::time::SystemTime::now()))
    };
    if let Err(e) = touch() {
        warn!(
            path = %path.display(),
            error = %e,
            "quarantine: could not stamp entry-time mtime; prune will age this file by its RECORDING time"
        );
    }
}

/// True when `filename` carries the backward-clock `-rN` disambiguator
/// (`recording.rs::disambiguated_name`, issue #144 item 2): stem ends in
/// `-r<digits>`. Those files are the losers of a wall-clock collision — real
/// footage ratified as "never deleted" (DECISIONS 2026-07-14) — and the
/// quarantine prune exempts them (issue #277). Pure + unit-tested.
fn is_collision_disambiguated(filename: &str) -> bool {
    let stem = filename.rsplit_once('.').map_or(filename, |(s, _)| s);
    match stem.rsplit_once("-r") {
        Some((_, digits)) => !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()),
        None => false,
    }
}

/// Return the platform errno value for EXDEV (cross-device link / rename).
///
/// On Linux this is 18; on macOS also 18.  We use a raw_os_error comparison
/// rather than the `std::io::ErrorKind::CrossesDevices` variant which is only
/// stable on nightly as of 2026.
#[inline]
fn libc_cross_device_error() -> i32 {
    // EXDEV = 18 on all POSIX platforms we target.
    18
}

// ─── prune_quarantine ────────────────────────────────────────────────────────

/// Purge aged files from `<storage_root>/_quarantine/`.
///
/// This is a DELETION path in the footage-sacred recorder (golden rule 2 /
/// `docs/RECORDER-CORRECTNESS.md`), so it is guarded so it is *impossible* for it
/// to remove anything but aged quarantine files:
///
/// * **Scope** — it only ever descends the single directory
///   `<storage_root>/_quarantine/`. That root is canonicalized ONCE up front, and
///   every file it is about to delete is independently canonicalized and verified
///   to still resolve *under* that canonical root. A `..` component or a symlink
///   that would escape the quarantine subtree is refused, never followed out. The
///   walk itself never traverses a symlinked directory, so it cannot wander into
///   a camera recording dir or anywhere else.
/// * **Kind + age** — it deletes only REGULAR files (never directories, never
///   symlinks, never fifos/sockets) whose mtime is strictly older than
///   `retention_days`. Directories-in-use, camera-id recording dirs, and tracked
///   segments (which never live under `_quarantine/`) are all left untouched.
/// * **Opt-out** — `retention_days <= 0` disables the prune entirely (keep
///   quarantined files forever). The caller only invokes it for `> 0`, but the
///   guard is repeated here so the function is safe on its own.
/// * **Resilience** — a read/stat/delete error on one entry is logged and the
///   walk continues; one bad file never aborts the sweep.
///
/// Returns `(files_deleted, bytes_deleted)`.
async fn prune_quarantine(storage_root: &Path, retention_days: i64) -> (u64, u64) {
    // OPT-OUT: 0 (or negative, defensively) = keep forever.
    if retention_days <= 0 {
        return (0, 0);
    }

    let quarantine_root = storage_root.join("_quarantine");

    // Canonicalize the quarantine root ONCE. If it doesn't exist (nothing was
    // ever quarantined on this disk) there is simply nothing to prune. Every file
    // we delete below is verified to canonicalize to a path *under* this root, so
    // resolving it here (following any symlink the operator may have made the
    // quarantine dir itself) is the anchor the boundary check compares against.
    let canon_root = match tokio::fs::canonicalize(&quarantine_root).await {
        Ok(p) => p,
        Err(_) => return (0, 0),
    };

    let cutoff = Utc::now() - Duration::days(retention_days);

    let mut files_deleted = 0u64;
    let mut bytes_deleted = 0u64;

    // Explicit stack walk rooted at the canonical quarantine dir. We only ever
    // push child directories discovered *under* canon_root (and never through a
    // symlink), so the traversal can never leave the quarantine subtree.
    let mut stack: Vec<PathBuf> = vec![canon_root.clone()];
    while let Some(dir) = stack.pop() {
        let mut entries = match tokio::fs::read_dir(&dir).await {
            Ok(rd) => rd,
            Err(e) => {
                warn!(dir = %dir.display(), error = %e, "prune_quarantine: cannot read dir; skipping");
                continue;
            }
        };

        loop {
            let entry = match entries.next_entry().await {
                Ok(Some(e)) => e,
                Ok(None) => break,
                Err(e) => {
                    warn!(dir = %dir.display(), error = %e, "prune_quarantine: error reading entry; skipping rest of dir");
                    break;
                }
            };

            let path = entry.path();

            // lstat (symlink_metadata): never traverse or delete THROUGH a
            // symlink. A symlink sitting inside _quarantine/ is left as-is —
            // following it could touch footage outside the quarantine subtree.
            let meta = match tokio::fs::symlink_metadata(&path).await {
                Ok(m) => m,
                Err(e) => {
                    warn!(path = %path.display(), error = %e, "prune_quarantine: cannot lstat entry; skipping");
                    continue;
                }
            };
            let ft = meta.file_type();

            if ft.is_symlink() {
                debug!(path = %path.display(), "prune_quarantine: symlink; leaving untouched");
                continue;
            }
            if ft.is_dir() {
                stack.push(path);
                continue;
            }
            if !ft.is_file() {
                // fifo/socket/device — not a quarantined segment; leave it.
                continue;
            }

            // COLLISION-LOSER EXEMPTION (issue #277): `-rN` disambiguated
            // files are the losers of a backward wall-clock collision — real
            // footage the 2026-07-14 decision promises is "never deleted".
            // Their stems deliberately don't parse, so the orphan pass parks
            // them here; quarantine is their TERMINAL home, and deleting them
            // stays a manual operator action.
            if entry
                .file_name()
                .to_str()
                .is_some_and(is_collision_disambiguated)
            {
                debug!(path = %path.display(),
                    "prune_quarantine: -rN collision-loser footage; never auto-deleted");
                continue;
            }

            // AGE GATE: only files strictly older than the retention cutoff. A
            // missing/unreadable mtime fails SAFE toward keeping the file.
            // NOTE the epoch: `quarantine_file` stamps mtime to the
            // quarantine-ENTRY time on arrival, so this window counts from
            // when the file became reviewable — not from when it was recorded.
            let mtime = match meta.modified() {
                Ok(m) => m,
                Err(e) => {
                    debug!(path = %path.display(), error = %e, "prune_quarantine: no mtime; keeping");
                    continue;
                }
            };
            let mtime_utc: DateTime<Utc> = mtime.into();
            if mtime_utc >= cutoff {
                continue; // within the grace window — keep for review
            }

            // BOUNDARY RE-VERIFY (defense in depth): canonicalize the real file
            // and confirm it STILL resolves under canon_root before deleting.
            // read_dir never yields `.`/`..`, and we never followed a symlinked
            // dir, so this holds by construction — but re-checking makes it
            // impossible for any path trick or mid-walk rename to delete outside
            // the quarantine subtree.
            let canon_file = match tokio::fs::canonicalize(&path).await {
                Ok(p) => p,
                Err(e) => {
                    warn!(path = %path.display(), error = %e, "prune_quarantine: cannot canonicalize; skipping");
                    continue;
                }
            };
            if !canon_file.starts_with(&canon_root) {
                warn!(
                    path = %canon_file.display(),
                    root = %canon_root.display(),
                    "prune_quarantine: resolved path escapes quarantine root; refusing to delete"
                );
                continue;
            }

            let size = meta.len();
            match tokio::fs::remove_file(&path).await {
                Ok(()) => {
                    files_deleted += 1;
                    bytes_deleted += size;
                    debug!(path = %path.display(), size, "prune_quarantine: deleted aged quarantine file");
                }
                Err(e) => {
                    // One bad file must not abort the pass (log + continue).
                    warn!(path = %path.display(), error = %e, "prune_quarantine: failed to delete aged quarantine file; continuing");
                }
            }
        }
    }

    if files_deleted > 0 {
        info!(
            storage_root = %storage_root.display(),
            files = files_deleted,
            bytes = bytes_deleted,
            retention_days,
            "prune_quarantine: purged aged quarantine files"
        );
    }

    (files_deleted, bytes_deleted)
}

// ─── walk_storage ────────────────────────────────────────────────────────────

/// Walk a storage root directory and return all `.mp4` file paths.
///
/// Does not recurse into `_quarantine/` to avoid re-quarantining already
/// quarantined files.
///
/// Implemented with an explicit stack (no external walkdir dependency) using
/// `tokio::fs::read_dir` for async-safe directory traversal.
///
/// # Errors
///
/// Returns an error if the root directory cannot be read.
pub async fn walk_storage(root: &Path) -> Result<Vec<PathBuf>> {
    let mut results: Vec<PathBuf> = Vec::new();
    // Stack of directories to visit.
    let mut stack: Vec<PathBuf> = vec![root.to_path_buf()];

    while let Some(dir) = stack.pop() {
        let mut entries = match tokio::fs::read_dir(&dir).await {
            Ok(rd) => rd,
            Err(e) => {
                warn!(dir = %dir.display(), error = %e, "cannot read directory during storage walk; skipping");
                continue;
            }
        };

        loop {
            let entry = match entries.next_entry().await {
                Ok(Some(e)) => e,
                Ok(None) => break,
                Err(e) => {
                    warn!(dir = %dir.display(), error = %e, "error reading directory entry; skipping");
                    break;
                }
            };

            let path = entry.path();

            let file_type = match entry.file_type().await {
                Ok(ft) => ft,
                Err(e) => {
                    warn!(path = %path.display(), error = %e, "cannot stat entry; skipping");
                    continue;
                }
            };

            if file_type.is_dir() {
                // Skip the quarantine directory.
                if path
                    .file_name()
                    .map(|n| n == "_quarantine")
                    .unwrap_or(false)
                {
                    debug!(path = %path.display(), "skipping _quarantine directory");
                    continue;
                }
                stack.push(path);
            } else if file_type.is_file()
                && path
                    .extension()
                    .map(|e| e.eq_ignore_ascii_case("mp4"))
                    .unwrap_or(false)
            {
                results.push(path);
            }
            // Symlinks are intentionally ignored.
        }
    }

    Ok(results)
}

// ─── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crumb_common::config::Config;

    /// Pure-logic test of the mtime-derived-duration clamp the orphan reindexer
    /// applies (audit P1 #6). Mirrors `try_index_orphan`'s clamp arithmetic so the
    /// boundary is verifiable without a DB/filesystem: the fallback is ONE
    /// nominal segment length; `max_segment_len` (2×) is only the plausibility
    /// window an observed mtime may land in (issue #84).
    fn clamp_end_ts(
        start_ts: DateTime<Utc>,
        mtime: DateTime<Utc>,
        segment_len: Duration,
        max_segment_len: Duration,
    ) -> DateTime<Utc> {
        let fallback = start_ts + segment_len;
        if mtime <= start_ts || (mtime - start_ts) > max_segment_len {
            fallback
        } else {
            mtime
        }
    }

    #[test]
    fn orphan_clamps_absurd_mtime_duration() {
        let start = Utc::now() - Duration::hours(50);
        let seg_len = Duration::seconds(4); // nominal segment
        let window = Duration::seconds(8); // 2× plausibility window

        // A 49h mtime (copied/recovered file) must clamp to the fallback.
        let bad_mtime = start + Duration::hours(49);
        assert_eq!(
            clamp_end_ts(start, bad_mtime, seg_len, window),
            start + seg_len
        );
        // mtime before start → also fallback.
        assert_eq!(
            clamp_end_ts(start, start - Duration::seconds(1), seg_len, window),
            start + seg_len
        );
        // A plausible mtime (within the 2× window) is kept verbatim — even one
        // somewhat past the nominal length (a real segment can run long).
        let good = start + Duration::seconds(6);
        assert_eq!(clamp_end_ts(start, good, seg_len, window), good);
    }

    /// Issue #84: the end_ts FALLBACK is one NOMINAL segment, not the 2×
    /// plausibility window — the old code manufactured a double-length
    /// duration for every adopted orphan whose mtime was implausible.
    #[test]
    fn orphan_end_ts_fallback_is_one_segment_not_double() {
        let start = Utc::now() - Duration::hours(50);
        let seg_len = Duration::seconds(4);
        let window = Duration::seconds(8);
        let implausible = start + Duration::hours(49);
        let end = clamp_end_ts(start, implausible, seg_len, window);
        assert_eq!(
            end,
            start + seg_len,
            "fallback must be start + segment_seconds"
        );
        assert_ne!(
            end,
            start + window,
            "fallback must NOT be the 2× window (the manufactured 2×-duration bug)"
        );
    }

    /// Issue #84: the orphan in-flight gate must not skip FUTURE-mtime files
    /// forever. Pre-fix, `now - mtime` was negative for any future mtime and
    /// therefore always `< twice_segment`, so the file was gated on EVERY
    /// pass — never adopted, never counted, silently eating disk.
    #[test]
    fn inflight_gate_treats_far_future_mtime_as_adoptable() {
        let now = Utc::now();
        let seg = Duration::seconds(4);
        let twice = Duration::seconds(8);

        // Just written → genuinely in flight.
        assert!(mtime_in_flight(now, now, seg, twice));
        // Written 1s ago → still in flight.
        assert!(mtime_in_flight(now, now - Duration::seconds(1), seg, twice));
        // Settled (older than the 2× window) → adoptable.
        assert!(!mtime_in_flight(
            now,
            now - Duration::seconds(9),
            seg,
            twice
        ));
        // Slight future skew (within one segment of clock slop) → still gated.
        assert!(mtime_in_flight(now, now + Duration::seconds(3), seg, twice));
        // FAR-future mtime (beyond one segment ahead): implausible, must be
        // treated as settled/adoptable instead of gated forever.
        assert!(!mtime_in_flight(now, now + Duration::hours(5), seg, twice));
        assert!(!mtime_in_flight(
            now,
            now + Duration::seconds(5),
            seg,
            twice
        ));
    }

    /// Quarantine-retention prune (DB-free): a `_quarantine/` tree with a mix of
    /// aged and fresh files plus a sibling NON-quarantine recording dir. Asserts
    /// the prune removes ONLY the aged quarantine files, leaves the fresh
    /// quarantine files and the entire sibling dir untouched, and that
    /// `retention_days = 0` deletes nothing (the opt-out).
    #[tokio::test]
    async fn prune_quarantine_deletes_only_aged_quarantine_files() {
        const DAY: u64 = 86_400;
        let root = tempfile::Builder::new()
            .prefix("crumb-qprune")
            .tempdir()
            .expect("tempdir");
        let root_path = root.path();

        // _quarantine/<cam>/ with one aged (30d) and one fresh file.
        let cam = Uuid::new_v4().to_string();
        let q_cam = root_path.join("_quarantine").join(&cam);
        tokio::fs::create_dir_all(&q_cam)
            .await
            .expect("mkdir q cam");

        let aged = q_cam.join("20260101T000000Z.mp4");
        tokio::fs::write(&aged, vec![0u8; 4096])
            .await
            .expect("write aged");
        backdate(&aged, 30 * DAY).await;

        let fresh = q_cam.join("20260716T000000Z.mp4");
        tokio::fs::write(&fresh, vec![0u8; 2048])
            .await
            .expect("write fresh");
        // fresh keeps its ~now mtime.

        // A SIBLING non-quarantine recording dir with an aged "segment" — must
        // NEVER be touched, even though it is older than the retention.
        let rec_cam = root_path.join(&cam).join("2026").join("01").join("01");
        tokio::fs::create_dir_all(&rec_cam)
            .await
            .expect("mkdir rec cam");
        let tracked = rec_cam.join("20260101T000000Z.mp4");
        tokio::fs::write(&tracked, vec![0u8; 800_000])
            .await
            .expect("write tracked");
        backdate(&tracked, 30 * DAY).await;

        // Retention 14d: aged quarantine file is 30d old → pruned; fresh kept.
        let (files, bytes) = prune_quarantine(root_path, 14).await;
        assert_eq!(files, 1, "exactly one aged quarantine file must be pruned");
        assert_eq!(bytes, 4096, "reported bytes must be the aged file's size");
        assert!(!aged.exists(), "aged quarantine file must be deleted");
        assert!(
            fresh.exists(),
            "fresh quarantine file must survive the grace window"
        );
        assert!(
            tracked.exists(),
            "a sibling non-quarantine recording file must NEVER be touched"
        );
        assert!(
            rec_cam.exists(),
            "the sibling recording dir must be untouched"
        );

        // Opt-out: retention 0 must delete nothing, even the aged fresh-tree.
        let root2 = tempfile::Builder::new()
            .prefix("crumb-qprune-optout")
            .tempdir()
            .expect("tempdir2");
        let q2 = root2.path().join("_quarantine").join(&cam);
        tokio::fs::create_dir_all(&q2).await.expect("mkdir q2");
        let aged2 = q2.join("20260101T000000Z.mp4");
        tokio::fs::write(&aged2, vec![0u8; 4096])
            .await
            .expect("write aged2");
        backdate(&aged2, 30 * DAY).await;

        let (files0, bytes0) = prune_quarantine(root2.path(), 0).await;
        assert_eq!(files0, 0, "retention 0 (opt-out) must delete nothing");
        assert_eq!(bytes0, 0, "retention 0 must report zero bytes");
        assert!(
            aged2.exists(),
            "retention 0 must keep even a 30-day-old file"
        );
    }

    /// Issue #277 part (a): the prune's grace window must count from
    /// quarantine ENTRY, not from recording time. A file 30 days old at the
    /// moment it is quarantined must still get the FULL review window —
    /// pre-fix, `rename` preserved the recording mtime and the very next
    /// prune (same reconcile pass) deleted it, so e.g. deleting a camera
    /// silently destroyed its whole history with zero review window.
    #[tokio::test]
    async fn quarantine_entry_restarts_the_prune_clock() {
        const DAY: u64 = 86_400;
        let root = tempfile::Builder::new()
            .prefix("crumb-qclock")
            .tempdir()
            .expect("tempdir");
        let root_path = root.path();

        // An "orphaned segment" already 30 days old at quarantine time.
        let cam = Uuid::new_v4().to_string();
        let rec_dir = root_path.join(&cam).join("2026").join("06");
        tokio::fs::create_dir_all(&rec_dir).await.expect("mkdir");
        let old_file = rec_dir.join("20260620T000000Z.mp4");
        tokio::fs::write(&old_file, vec![0u8; 4096])
            .await
            .expect("write");
        backdate(&old_file, 30 * DAY).await;

        quarantine_file(&old_file, root_path)
            .await
            .expect("quarantine");
        // Layout: `_quarantine/<camera_id>/<filename>` (camera dir preserved,
        // date tree flattened — see quarantine_file's doc).
        let quarantined = root_path
            .join("_quarantine")
            .join(&cam)
            .join("20260620T000000Z.mp4");
        assert!(quarantined.exists(), "file parked under _quarantine");

        // Entry stamp: mtime is ~now, not the 30-day-old recording time.
        let mtime: DateTime<Utc> = tokio::fs::metadata(&quarantined)
            .await
            .expect("meta")
            .modified()
            .expect("mtime")
            .into();
        assert!(
            Utc::now() - mtime < Duration::minutes(5),
            "quarantine entry must stamp mtime to NOW (got {mtime})"
        );

        // The very next prune (14d window) must KEEP it — the full review
        // window starts at entry.
        let (files, _) = prune_quarantine(root_path, 14).await;
        assert_eq!(files, 0, "freshly quarantined file must survive the prune");
        assert!(quarantined.exists());
    }

    /// Issue #277 part (b): `-rN` collision-loser files are ratified "never
    /// deleted" (DECISIONS 2026-07-14) — the prune must exempt them at ANY
    /// age, while a plain aged neighbor is still pruned.
    #[tokio::test]
    async fn prune_quarantine_exempts_collision_losers() {
        const DAY: u64 = 86_400;
        let root = tempfile::Builder::new()
            .prefix("crumb-qrn")
            .tempdir()
            .expect("tempdir");
        let q = root.path().join("_quarantine").join("cam");
        tokio::fs::create_dir_all(&q).await.expect("mkdir");

        let loser = q.join("20260101T000000Z-r1.mp4");
        tokio::fs::write(&loser, vec![0u8; 1024]).await.expect("w");
        backdate(&loser, 90 * DAY).await;

        let plain = q.join("20260101T000000Z.mp4");
        tokio::fs::write(&plain, vec![0u8; 2048]).await.expect("w");
        backdate(&plain, 90 * DAY).await;

        let (files, bytes) = prune_quarantine(root.path(), 14).await;
        assert_eq!(files, 1, "only the plain aged file is pruned");
        assert_eq!(bytes, 2048);
        assert!(
            loser.exists(),
            "-rN collision-loser footage must NEVER be auto-deleted"
        );
        assert!(!plain.exists());
    }

    /// The `-rN` detector: exact suffix shape only (stem ends `-r<digits>`).
    #[test]
    fn collision_disambiguated_detector() {
        assert!(is_collision_disambiguated("20260101T000000Z-r1.mp4"));
        assert!(is_collision_disambiguated("20260101T000000Z-r64.mp4"));
        assert!(is_collision_disambiguated("seg-r7")); // no extension
        assert!(!is_collision_disambiguated("20260101T000000Z.mp4"));
        assert!(!is_collision_disambiguated("clip-r.mp4")); // no digits
        assert!(!is_collision_disambiguated("clip-r1x.mp4")); // trailing junk
        assert!(!is_collision_disambiguated("rear-video.mp4"));
    }

    /// Prefers `CRUMB_TEST_DATABASE_URL`, falling back to the workspace-wide
    /// `TEST_DATABASE_URL` that CI already sets. Without that fallback these
    /// footage-critical reconcile tests silently skipped in CI (audit
    /// 2026-07-05). The `assert!` makes a skip under CI fail LOUD.
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
             throwaway Postgres."
        );
        url
    }

    /// Minimal reconcile fixture: a schema with the tables the orphan/dangling
    /// passes touch, one camera, plus a live + archive storage NAMED to match the
    /// recorder config defaults so `run_background` discovers them.
    struct RFixture {
        pool: deadpool_postgres::Pool,
        schema: String,
        base_url: String,
        _live_dir: tempfile::TempDir,
        _archive_dir: tempfile::TempDir,
        live_path: PathBuf,
        camera_id: Uuid,
    }

    impl Drop for RFixture {
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

    async fn setup_reconcile(base_url: &str) -> RFixture {
        let schema = format!("crumb_recon_test_{}", Uuid::new_v4().simple());
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
                        camera_type      text,
                        icon             text,
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
                        -- Mirror migration 0026: insert_segment writes these,
                        -- so the fixture must carry them or EVERY DB-backed
                        -- reconcile test dies on the first insert.
                        motion_bbox_x real,
                        motion_bbox_y real,
                        motion_bbox_w real,
                        motion_bbox_h real
                    );
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
                    -- Mirror migration 0019: get_camera (and the per-policy queries)
                    -- now resolve the effective policy through this view, so the test
                    -- schema must define it too. Same own→group→default COALESCE.
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
            .prefix("crumb-recon-live")
            .tempdir()
            .expect("live tmp");
        let archive_dir = tempfile::Builder::new()
            .prefix("crumb-recon-arch")
            .tempdir()
            .expect("archive tmp");

        // Storage rows NAMED to match Config defaults so run_background finds them.
        let live_storage = crumb_common::db::upsert_storage(
            &pool,
            "NVMe-Live",
            live_dir.path().to_str().expect("utf8"),
        )
        .await
        .expect("live storage");
        crumb_common::db::upsert_storage(
            &pool,
            "Bulk-Archive",
            archive_dir.path().to_str().expect("utf8"),
        )
        .await
        .expect("archive storage");

        let camera_id = {
            let client = pool.get().await.expect("conn");
            let policy = client
                .query_one(
                    "INSERT INTO recording_policies (name, is_default, live_storage_id)
                     VALUES ('Default', true, $1) RETURNING id",
                    &[&live_storage.id],
                )
                .await
                .expect("policy");
            let policy_id: Uuid = policy.get(0);
            let cam = client
                .query_one(
                    "INSERT INTO cameras (name, go2rtc_name, main_url, policy_id)
                     VALUES ('Recon Cam', $1, 'rtsp://x/main', $2) RETURNING id",
                    &[&format!("rc_{}", Uuid::new_v4().simple()), &policy_id],
                )
                .await
                .expect("camera");
            cam.get::<_, Uuid>(0)
        };

        RFixture {
            pool,
            schema,
            base_url: base_url.to_owned(),
            live_path: live_dir.path().to_path_buf(),
            _live_dir: live_dir,
            _archive_dir: archive_dir,
            camera_id,
        }
    }

    fn recon_config() -> Config {
        std::env::set_var("DATABASE_URL", "unused://");
        Config::from_env().expect("config")
    }

    /// End-to-end: a recent-mtime (in-flight) file is SKIPPED and a sub-floor
    /// (28-byte) file is REJECTED — neither produces a segment row (audit P0 #3 /
    /// GAP 4). A genuine, complete, old-enough file IS indexed (control).
    #[tokio::test]
    async fn orphan_skips_inflight_and_rejects_subfloor() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;
        let config = recon_config(); // segment_seconds = 4 → 2× = 8s in-flight window

        let cam_dir = fx.live_path.join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&cam_dir)
            .await
            .expect("mkdir cam");

        // (1) IN-FLIGHT: filename timestamp is old, but the file was JUST written
        //     (mtime = now), so it's within the 8s in-flight window → must skip.
        let inflight = cam_dir.join("20260101T000000Z.mp4");
        tokio::fs::write(&inflight, vec![0u8; 4096])
            .await
            .expect("write inflight");
        // (mtime is "now" because we just wrote it.)

        // (2) SUB-FLOOR: a complete-but-tiny 28-byte file, old mtime → must reject
        //     (quarantined, not indexed).
        let subfloor = cam_dir.join("20260101T000010Z.mp4");
        tokio::fs::write(&subfloor, vec![0u8; 28])
            .await
            .expect("write subfloor");
        backdate(&subfloor, 3600).await;

        // (3) CONTROL: a valid 4KB file with an OLD mtime → must be indexed.
        let good = cam_dir.join("20260101T000020Z.mp4");
        tokio::fs::write(&good, vec![0u8; 4096])
            .await
            .expect("write good");
        backdate(&good, 3600).await;

        run_background(fx.pool.clone(), config, CancellationToken::new()).await;

        let rows = crumb_common::db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
            .await
            .unwrap();
        // Only the control file is indexed; in-flight skipped, sub-floor rejected.
        assert_eq!(
            rows.len(),
            1,
            "exactly the one valid file should be indexed: {rows:?}"
        );
        assert!(rows[0].path.ends_with("20260101T000020Z.mp4"));
        assert!(rows[0].size_bytes >= 512, "indexed row is above the floor");

        // The in-flight file is left in place (not indexed, not quarantined).
        assert!(
            inflight.exists(),
            "in-flight file must remain for a later boot"
        );
        // The sub-floor file is quarantined (moved out of the camera dir).
        assert!(
            !subfloor.exists(),
            "sub-floor file should be quarantined (moved away)"
        );
    }

    /// Regression guard for the dangling-pass in-flight gate: a sub-floor file
    /// whose row pre-exists (the rapid-restart-rewrite race, where a camera worker
    /// reopened the same strftime filename and it's momentarily back at the
    /// 28-byte ftyp skeleton) must NOT have its file+row deleted while it's being
    /// actively written. A stale (old-mtime) sub-floor row+file IS removed.
    #[tokio::test]
    async fn dangling_pass_skips_inflight_subfloor_keeps_footage() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;
        let config = recon_config(); // segment_seconds = 4 → 2× = 8s in-flight window

        let cam_dir = fx.live_path.join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&cam_dir)
            .await
            .expect("mkdir cam");

        let live = crumb_common::db::get_storage_by_name(&fx.pool, "NVMe-Live")
            .await
            .expect("get live storage")
            .expect("live storage exists");

        let mk_row = |name: &str, start: &str, end: &str| crumb_common::db::InsertSegmentParams {
            camera_id: fx.camera_id,
            storage_id: live.id,
            stage: SegmentStage::Live,
            path: format!("{}/{name}", fx.camera_id),
            stream: SegmentStream::Main,
            start_ts: start.parse().expect("start ts"),
            end_ts: end.parse().expect("end ts"),
            duration_ms: 4000,
            has_motion: false,
            motion_score: 0.0,
            size_bytes: 800_000, // row claims a full segment...
            motion_bbox: None,
        };

        // (1) IN-FLIGHT sub-floor: 28 bytes on disk (mtime = now), row claims 800KB.
        //     The dangling pass MUST skip it — ffmpeg is mid-rewrite.
        let inflight = cam_dir.join("20260101T000000Z.mp4");
        tokio::fs::write(&inflight, vec![0u8; 28])
            .await
            .expect("write inflight");
        crumb_common::db::insert_segment(
            &fx.pool,
            &mk_row(
                "20260101T000000Z.mp4",
                "2026-01-01T00:00:00Z",
                "2026-01-01T00:00:04Z",
            ),
        )
        .await
        .expect("insert inflight row");

        // (2) STALE sub-floor: 28 bytes on disk, OLD mtime, row claims 800KB →
        //     genuinely truncated/dead, so the dangling pass removes file + row.
        let stale = cam_dir.join("20260101T000010Z.mp4");
        tokio::fs::write(&stale, vec![0u8; 28])
            .await
            .expect("write stale");
        backdate(&stale, 3600).await;
        crumb_common::db::insert_segment(
            &fx.pool,
            &mk_row(
                "20260101T000010Z.mp4",
                "2026-01-01T00:00:10Z",
                "2026-01-01T00:00:14Z",
            ),
        )
        .await
        .expect("insert stale row");

        run_background(fx.pool.clone(), config, CancellationToken::new()).await;

        let rows = crumb_common::db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
            .await
            .unwrap();
        let has = |suffix: &str| rows.iter().any(|r| r.path.ends_with(suffix));

        // In-flight sub-floor row+file survive (gate protected the live writer).
        assert!(
            inflight.exists(),
            "in-flight sub-floor file must NOT be deleted"
        );
        assert!(
            has("20260101T000000Z.mp4"),
            "in-flight sub-floor row must survive: {rows:?}"
        );
        // Stale sub-floor row+file removed.
        assert!(!stale.exists(), "stale sub-floor file should be deleted");
        assert!(
            !has("20260101T000010Z.mp4"),
            "stale sub-floor row should be deleted: {rows:?}"
        );
    }

    /// #84 follow-up: the DANGLING-ROW pass's in-flight gate must be
    /// future-mtime-aware, exactly like the orphan pass. Pre-fix it used the
    /// raw `now - mtime < twice_segment` arithmetic, which is trivially true
    /// for ANY future mtime (negative difference) — so after a backwards clock
    /// step a torn 28-byte skeleton whose row claimed a full segment was
    /// "in flight" on EVERY pass, forever: never size-repaired, never removed.
    /// With [`mtime_in_flight`] a far-future mtime is implausible → settled →
    /// the sub-floor branch reconciles it (file + row deleted).
    #[tokio::test]
    async fn dangling_pass_reconciles_future_mtime_file_instead_of_gating_forever() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;
        let config = recon_config(); // segment_seconds = 4 → slop allowance = 4s

        let cam_dir = fx.live_path.join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&cam_dir)
            .await
            .expect("mkdir cam");

        let live = crumb_common::db::get_storage_by_name(&fx.pool, "NVMe-Live")
            .await
            .expect("get live storage")
            .expect("live storage exists");

        // A 28-byte torn skeleton whose row claims a full 800KB segment, with
        // an mtime 5 HOURS in the future — far beyond the one-segment clock
        // slop mtime_in_flight tolerates.
        let torn = cam_dir.join("20260101T000000Z.mp4");
        tokio::fs::write(&torn, vec![0u8; 28])
            .await
            .expect("write torn skeleton");
        futuredate(&torn, 5 * 3600).await;
        crumb_common::db::insert_segment(
            &fx.pool,
            &crumb_common::db::InsertSegmentParams {
                camera_id: fx.camera_id,
                storage_id: live.id,
                stage: SegmentStage::Live,
                path: format!("{}/20260101T000000Z.mp4", fx.camera_id),
                stream: SegmentStream::Main,
                start_ts: "2026-01-01T00:00:00Z".parse().expect("start ts"),
                end_ts: "2026-01-01T00:00:04Z".parse().expect("end ts"),
                duration_ms: 4000,
                has_motion: false,
                motion_score: 0.0,
                size_bytes: 800_000, // the row's claim; on disk it is 28 bytes
                motion_bbox: None,
            },
        )
        .await
        .expect("insert torn row");

        run_background(fx.pool.clone(), config, CancellationToken::new()).await;

        // Post-fix: the future mtime does NOT gate the file; the sub-floor
        // branch removes the unusable file + its row in one pass. Pre-fix both
        // survived every pass indefinitely.
        assert!(
            !torn.exists(),
            "a far-future-mtime torn file must be reconciled (deleted), not gated forever"
        );
        let rows = crumb_common::db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
            .await
            .unwrap();
        assert!(
            rows.is_empty(),
            "the torn row must be deleted, not kept alive by the in-flight gate: {rows:?}"
        );
    }

    /// R3b regression: a PERSISTENTLY sub-floor file — one whose row was ALSO
    /// indexed at the sub-floor size (`on_disk == seg.size_bytes`, both 28
    /// bytes) — must still be deleted. Before the fix, the sub-floor check
    /// only ran inside the `on_disk != seg.size_bytes` (drift) branch, so this
    /// exact-match case fell through to the "segment file confirmed" branch
    /// and the unusable row+file lived forever. This is DISTINCT from
    /// `dangling_pass_skips_inflight_subfloor_keeps_footage`'s "stale" case
    /// above, which has on_disk (28) != claimed (800_000) and so already
    /// exercised the pre-fix code path.
    #[tokio::test]
    async fn dangling_pass_removes_persistent_subfloor_with_no_size_drift() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;
        let config = recon_config();

        let cam_dir = fx.live_path.join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&cam_dir)
            .await
            .expect("mkdir cam");

        let live = crumb_common::db::get_storage_by_name(&fx.pool, "NVMe-Live")
            .await
            .expect("get live storage")
            .expect("live storage exists");

        // File is 28 bytes on disk AND the row claims 28 bytes too — no drift
        // between `on_disk` and `seg.size_bytes`, but 28 < SUB_FLOOR_BYTES
        // (512), so this must be treated as unusable regardless.
        let persistent = cam_dir.join("20260101T000020Z.mp4");
        tokio::fs::write(&persistent, vec![0u8; 28])
            .await
            .expect("write persistent sub-floor file");
        backdate(&persistent, 3600).await; // old enough to clear the in-flight gate

        crumb_common::db::insert_segment(
            &fx.pool,
            &crumb_common::db::InsertSegmentParams {
                camera_id: fx.camera_id,
                storage_id: live.id,
                stage: SegmentStage::Live,
                path: format!("{}/20260101T000020Z.mp4", fx.camera_id),
                stream: SegmentStream::Main,
                start_ts: "2026-01-01T00:00:20Z".parse().expect("start ts"),
                end_ts: "2026-01-01T00:00:24Z".parse().expect("end ts"),
                duration_ms: 4000,
                has_motion: false,
                motion_score: 0.0,
                size_bytes: 28, // matches on-disk exactly — no drift
                motion_bbox: None,
            },
        )
        .await
        .expect("insert persistent sub-floor row");

        run_background(fx.pool.clone(), config, CancellationToken::new()).await;

        let rows = crumb_common::db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
            .await
            .unwrap();
        assert!(
            !persistent.exists(),
            "persistent sub-floor file (no size drift) must still be deleted"
        );
        assert!(
            !rows
                .iter()
                .any(|r| r.path.ends_with("20260101T000020Z.mp4")),
            "persistent sub-floor row (no size drift) must still be deleted: {rows:?}"
        );
    }

    /// C1 regression: reconcile's orphan adoption must NEVER relocate a healthy
    /// row. We pre-insert a row at key K pointing at disk A, then run the
    /// orphan-adopt path (`try_index_orphan`) for a duplicate file at the SAME key
    /// living on disk B. The row must STILL point at disk A (storage_id unchanged):
    /// a segment's physical location is owned by its storage_id, and a stray dup on
    /// another disk may not flip it (the storage ping-pong this fix kills).
    #[tokio::test]
    async fn reconcile_orphan_adopt_does_not_relocate_existing_row() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;

        // Disk A: the existing storage the healthy row points at.
        let disk_a = crumb_common::db::get_storage_by_name(&fx.pool, "NVMe-Live")
            .await
            .expect("get disk A")
            .expect("disk A exists");

        // Disk B: a SECOND storage row + on-disk root holding a stray duplicate.
        let disk_b_dir = tempfile::Builder::new()
            .prefix("crumb-recon-diskB")
            .tempdir()
            .expect("disk B tmp");
        let disk_b = crumb_common::db::upsert_storage(
            &fx.pool,
            "DiskB-Stray",
            disk_b_dir.path().to_str().expect("utf8"),
        )
        .await
        .expect("disk B storage");

        // Filename that parses to a fixed start_ts; key = (camera_id, main, start).
        let filename = "20260101T000000Z.mp4";
        let start_ts: DateTime<Utc> = "2026-01-01T00:00:00Z".parse().expect("start ts");

        // 1. Pre-insert the HEALTHY row at key K → disk A.
        crumb_common::db::insert_segment(
            &fx.pool,
            &crumb_common::db::InsertSegmentParams {
                camera_id: fx.camera_id,
                storage_id: disk_a.id,
                stage: SegmentStage::Live,
                path: format!("{}/{filename}", fx.camera_id),
                stream: SegmentStream::Main,
                start_ts,
                end_ts: "2026-01-01T00:00:04Z".parse().expect("end ts"),
                duration_ms: 4000,
                has_motion: false,
                motion_score: 0.0,
                size_bytes: 800_000,
                motion_bbox: None,
            },
        )
        .await
        .expect("insert healthy row on disk A");

        // 2. Write a stray duplicate file at the SAME key on disk B.
        let b_cam_dir = disk_b_dir.path().join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&b_cam_dir)
            .await
            .expect("mkdir disk B cam");
        let b_file = b_cam_dir.join(filename);
        tokio::fs::write(&b_file, vec![0u8; 8192])
            .await
            .expect("write stray dup");

        // 3. Run the orphan-adopt path for the disk-B file. It must return
        //    AlreadyIndexed (conservative skip — row already exists, NOT
        //    junk) and NOT relocate anything.
        let rel_path = format!("{}/{filename}", fx.camera_id);
        let outcome = try_index_orphan(
            &fx.pool,
            &b_file,
            disk_b_dir.path(),
            disk_b.id,
            &rel_path,
            &SegmentStage::Live,
            Duration::seconds(15),
            Duration::seconds(30),
        )
        .await
        .expect("try_index_orphan must not error");
        assert_eq!(
            outcome,
            OrphanOutcome::AlreadyIndexed,
            "orphan adopt at an existing key must be a conservative no-op (AlreadyIndexed, not NotIndexable)"
        );

        // 4. The row STILL points at disk A — no relocation occurred.
        let rows = crumb_common::db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
            .await
            .expect("list segments");
        assert_eq!(rows.len(), 1, "no duplicate row created: {rows:?}");
        assert_eq!(
            rows[0].storage_id, disk_a.id,
            "healthy row must STILL point at disk A (reconcile must not relocate it)"
        );
    }

    /// FOOTAGE-LOSS REGRESSION (defect 1): the full `run_background` reconcile
    /// pass must NEVER quarantine a valid, already-indexed segment file.
    ///
    /// Pre-fix, `try_index_orphan` returned `Ok(false)` both for genuine junk
    /// AND for "a row already exists at this key" (the `ON CONFLICT ... DO
    /// NOTHING` case). The caller treated every `Ok(false)` as junk and moved
    /// the file into `_quarantine/` — so the reconciler quarantined its OWN
    /// freshly-written, already-indexed footage. The next pass then saw the
    /// row's file "missing" at its original path and deleted the row
    /// (correctness item 10), producing the recording gap.
    ///
    /// This test seeds a segment row AND its on-disk file (already indexed,
    /// old enough to clear the in-flight gate), runs one full
    /// `run_background` pass — which walks the storage as an "orphan"
    /// candidate exactly like prod's periodic reconcile does — and asserts
    /// the file is STILL PRESENT AT ITS ORIGINAL PATH afterward. Pre-fix this
    /// assertion fails (the file is moved into `_quarantine/`); post-fix it
    /// passes.
    #[tokio::test]
    async fn reconcile_does_not_quarantine_already_indexed_footage() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;
        let config = recon_config(); // segment_seconds = 4 → 2× = 8s in-flight window

        let cam_dir = fx.live_path.join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&cam_dir)
            .await
            .expect("mkdir cam");

        let live = crumb_common::db::get_storage_by_name(&fx.pool, "NVMe-Live")
            .await
            .expect("get live storage")
            .expect("live storage exists");

        // A valid, complete segment file — old enough to clear the in-flight
        // gate — WITH a matching row already indexed at the same key. This
        // mirrors real steady-state: the recorder's own boundary-finalize
        // insert already indexed this segment before reconcile ever sees it.
        let filename = "20260101T000000Z.mp4";
        let abs_path = cam_dir.join(filename);
        tokio::fs::write(&abs_path, vec![0u8; 800_000])
            .await
            .expect("write segment file");
        backdate(&abs_path, 3600).await;

        crumb_common::db::insert_segment(
            &fx.pool,
            &crumb_common::db::InsertSegmentParams {
                camera_id: fx.camera_id,
                storage_id: live.id,
                stage: SegmentStage::Live,
                path: format!("{}/{filename}", fx.camera_id),
                stream: SegmentStream::Main,
                start_ts: "2026-01-01T00:00:00Z".parse().expect("start ts"),
                end_ts: "2026-01-01T00:00:04Z".parse().expect("end ts"),
                duration_ms: 4000,
                has_motion: false,
                motion_score: 0.0,
                size_bytes: 800_000,
                motion_bbox: None,
            },
        )
        .await
        .expect("insert pre-existing row");

        // Run the FULL background pass — dangling check + orphan walk — just
        // like the periodic reconcile does in prod.
        run_background(fx.pool.clone(), config, CancellationToken::new()).await;

        // THE ASSERTION THAT FAILS PRE-FIX: the file must still exist at its
        // ORIGINAL path — not moved into _quarantine/.
        assert!(
            abs_path.exists(),
            "already-indexed footage must NOT be quarantined by reconcile"
        );

        // And the row must still be present (not deleted as dangling either).
        let rows = crumb_common::db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
            .await
            .expect("list segments");
        assert_eq!(
            rows.len(),
            1,
            "the pre-existing row must survive the pass untouched: {rows:?}"
        );
        assert!(rows[0].path.ends_with(filename));

        // Quarantine directory must not contain the file either (defensive:
        // even if it were duplicated somewhere, the original must remain).
        let quarantine_root = fx.live_path.join("_quarantine");
        if quarantine_root.exists() {
            let mut found_in_quarantine = false;
            let mut stack = vec![quarantine_root];
            while let Some(dir) = stack.pop() {
                let mut rd = tokio::fs::read_dir(&dir)
                    .await
                    .expect("read quarantine dir");
                while let Some(entry) = rd.next_entry().await.expect("next entry") {
                    let p = entry.path();
                    if entry.file_type().await.expect("file type").is_dir() {
                        stack.push(p);
                    } else if p.file_name().map(|n| n == filename).unwrap_or(false) {
                        found_in_quarantine = true;
                    }
                }
            }
            assert!(
                !found_in_quarantine,
                "already-indexed footage must not appear anywhere under _quarantine/"
            );
        }
    }

    /// DANGLING RE-VERIFY REGRESSION (defect 2): a row whose file is present
    /// at its CURRENT `(storage_id, path)` must NOT be deleted, even if the
    /// dangling-row pass's page snapshot was taken before the row's location
    /// changed (e.g. an archive-move race, or the file being fixed up by a
    /// concurrent orphan-adopt).
    ///
    /// We can't easily race the actual paginated scan from a unit test, so
    /// this test verifies the re-verify logic's observable contract directly:
    /// seed a row + file that are consistent (file present at the row's
    /// current path) and confirm `run_background` does NOT delete the row.
    /// This is the same steady-state the quarantine regression test checks
    /// from the file side; here we assert from the row side that dangling
    /// deletion never fires for a segment whose file demonstrably still
    /// exists at its current location.
    #[tokio::test]
    async fn dangling_reverify_keeps_row_when_file_present_at_current_path() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;
        let config = recon_config();

        let cam_dir = fx.live_path.join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&cam_dir)
            .await
            .expect("mkdir cam");

        let live = crumb_common::db::get_storage_by_name(&fx.pool, "NVMe-Live")
            .await
            .expect("get live storage")
            .expect("live storage exists");

        let filename = "20260101T000030Z.mp4";
        let abs_path = cam_dir.join(filename);
        tokio::fs::write(&abs_path, vec![0u8; 800_000])
            .await
            .expect("write segment file");
        backdate(&abs_path, 3600).await;

        let seg_id = crumb_common::db::insert_segment(
            &fx.pool,
            &crumb_common::db::InsertSegmentParams {
                camera_id: fx.camera_id,
                storage_id: live.id,
                stage: SegmentStage::Live,
                path: format!("{}/{filename}", fx.camera_id),
                stream: SegmentStream::Main,
                start_ts: "2026-01-01T00:00:30Z".parse().expect("start ts"),
                end_ts: "2026-01-01T00:00:34Z".parse().expect("end ts"),
                duration_ms: 4000,
                has_motion: false,
                motion_score: 0.0,
                size_bytes: 800_000,
                motion_bbox: None,
            },
        )
        .await
        .expect("insert row");

        run_background(fx.pool.clone(), config, CancellationToken::new()).await;

        // Row must survive: its file is present at its current path, so the
        // dangling pass's re-verify must find it and skip deletion.
        let row = crumb_common::db::get_segment(&fx.pool, seg_id)
            .await
            .expect("get_segment")
            .expect("row must still exist — dangling re-verify must not delete a row whose file is present");
        assert!(row.path.ends_with(filename));
        assert!(abs_path.exists(), "file itself must be untouched");
    }

    /// Issue #84: orphan adoption must index with the STREAM the camera's
    /// effective policy actually records — hardcoding Main mislabelled
    /// sub-stream cameras' footage and weakened the (camera_id, stream,
    /// start_ts) AlreadyIndexed guard.
    #[tokio::test]
    async fn orphan_adoption_uses_policy_record_stream() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;

        // Flip the camera's effective policy to record the SUB stream.
        {
            let client = fx.pool.get().await.expect("conn");
            client
                .execute("UPDATE recording_policies SET record_stream = 'sub'", &[])
                .await
                .expect("set record_stream = sub");
        }

        let live = crumb_common::db::get_storage_by_name(&fx.pool, "NVMe-Live")
            .await
            .expect("get live storage")
            .expect("live storage exists");

        let cam_dir = fx.live_path.join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&cam_dir)
            .await
            .expect("mkdir cam");
        let filename = "20260101T000100Z.mp4";
        let abs_path = cam_dir.join(filename);
        tokio::fs::write(&abs_path, vec![0u8; 4096])
            .await
            .expect("write orphan");
        backdate(&abs_path, 3600).await;

        let rel_path = format!("{}/{filename}", fx.camera_id);
        let outcome = try_index_orphan(
            &fx.pool,
            &abs_path,
            &fx.live_path,
            live.id,
            &rel_path,
            &SegmentStage::Live,
            Duration::seconds(15),
            Duration::seconds(30),
        )
        .await
        .expect("try_index_orphan must not error");
        assert_eq!(outcome, OrphanOutcome::Indexed, "truly-orphan key adopted");

        let rows = crumb_common::db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
            .await
            .expect("list segments");
        assert_eq!(rows.len(), 1, "one adopted row: {rows:?}");
        assert_eq!(
            rows[0].stream,
            SegmentStream::Sub,
            "adopted orphan must carry the policy's record_stream (sub), not a hardcoded Main"
        );
    }

    /// Issue #70 family: an orphan found on an ARCHIVE destination disk (a
    /// policy's `archive_storage_id`, not just the config-name default) must be
    /// adopted as stage=archive — pre-fix it was labelled Live, which
    /// mis-scoped its retention and pointed the next cron archive run at a
    /// "live" segment already sitting at its archive destination. A control
    /// orphan on the live disk stays stage=live.
    #[tokio::test]
    async fn orphan_on_policy_archive_storage_adopts_as_archive_stage() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: CRUMB_TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_reconcile(&url).await;
        let config = recon_config();

        // A per-policy archive disk that is NOT the config-name default
        // ("Bulk-Archive") — the case the old labelling missed.
        let policy_arch_dir = tempfile::Builder::new()
            .prefix("crumb-recon-policy-arch")
            .tempdir()
            .expect("policy archive tmp");
        let policy_arch = crumb_common::db::upsert_storage(
            &fx.pool,
            "Policy-Archive",
            policy_arch_dir.path().to_str().expect("utf8"),
        )
        .await
        .expect("policy archive storage");
        {
            let client = fx.pool.get().await.expect("conn");
            client
                .execute(
                    "UPDATE recording_policies SET archive_storage_id = $1",
                    &[&policy_arch.id],
                )
                .await
                .expect("point policy at the archive storage");
        }

        // Orphan on the POLICY ARCHIVE disk → must adopt as stage=archive.
        let arch_cam_dir = policy_arch_dir.path().join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&arch_cam_dir)
            .await
            .expect("mkdir arch cam");
        let arch_file = arch_cam_dir.join("20260101T000200Z.mp4");
        tokio::fs::write(&arch_file, vec![0u8; 4096])
            .await
            .expect("write archive orphan");
        backdate(&arch_file, 3600).await;

        // Control orphan on the LIVE disk → must adopt as stage=live.
        let live_cam_dir = fx.live_path.join(fx.camera_id.to_string());
        tokio::fs::create_dir_all(&live_cam_dir)
            .await
            .expect("mkdir live cam");
        let live_file = live_cam_dir.join("20260101T000210Z.mp4");
        tokio::fs::write(&live_file, vec![0u8; 4096])
            .await
            .expect("write live orphan");
        backdate(&live_file, 3600).await;

        run_background(fx.pool.clone(), config, CancellationToken::new()).await;

        let rows = crumb_common::db::list_all_segments_for_camera(&fx.pool, fx.camera_id)
            .await
            .expect("list segments");
        let by_suffix = |suffix: &str| {
            rows.iter()
                .find(|r| r.path.ends_with(suffix))
                .unwrap_or_else(|| panic!("adopted row for {suffix} missing: {rows:?}"))
        };

        let arch_row = by_suffix("20260101T000200Z.mp4");
        assert_eq!(
            arch_row.stage,
            SegmentStage::Archive,
            "orphan on a policy archive disk must be adopted as stage=archive"
        );
        assert_eq!(arch_row.storage_id, policy_arch.id);

        let live_row = by_suffix("20260101T000210Z.mp4");
        assert_eq!(
            live_row.stage,
            SegmentStage::Live,
            "orphan on the live disk must stay stage=live"
        );
    }

    /// Set a file's mtime `secs_ago` seconds into the past so it falls OUTSIDE
    /// the in-flight window. Uses `filetime`-free approach via std on Unix.
    async fn backdate(path: &Path, secs_ago: u64) {
        set_mtime(
            path,
            std::time::SystemTime::now() - std::time::Duration::from_secs(secs_ago),
        )
        .await;
    }

    /// Set a file's mtime `secs_ahead` seconds into the FUTURE — models a
    /// backwards clock step / restored file whose mtime is ahead of the
    /// recorder's clock (issue #84).
    async fn futuredate(path: &Path, secs_ahead: u64) {
        set_mtime(
            path,
            std::time::SystemTime::now() + std::time::Duration::from_secs(secs_ahead),
        )
        .await;
    }

    /// Shared mtime setter for [`backdate`] / [`futuredate`].
    async fn set_mtime(path: &Path, when: std::time::SystemTime) {
        let path = path.to_path_buf();
        let ft = when;
        tokio::task::spawn_blocking(move || {
            // SAFETY: portable mtime set via std isn't available; use utimes via libc.
            #[cfg(unix)]
            {
                use std::os::unix::ffi::OsStrExt;
                let secs = ft
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);
                let times = [
                    libc::timeval {
                        tv_sec: secs as libc::time_t,
                        tv_usec: 0,
                    },
                    libc::timeval {
                        tv_sec: secs as libc::time_t,
                        tv_usec: 0,
                    },
                ];
                let cpath = std::ffi::CString::new(path.as_os_str().as_bytes()).expect("cstring");
                // SAFETY: valid C string + a 2-element timeval array, per utimes(2).
                unsafe {
                    libc::utimes(cpath.as_ptr(), times.as_ptr());
                }
            }
            #[cfg(not(unix))]
            {
                let _ = (path, ft);
            }
        })
        .await
        .expect("set_mtime join");
    }
}
