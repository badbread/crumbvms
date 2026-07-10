// SPDX-License-Identifier: AGPL-3.0-or-later

//! Database access layer — deadpool-postgres pool and all typed accessors.
//!
//! ## Design invariants
//!
//! * **All queries are parameterised** — no string interpolation of user data.
//! * **No sqlx** — the Docker build must work without a live DB at compile
//!   time.  We use `tokio-postgres` runtime queries only.
//! * **chrono/uuid/serde_json** — the `tokio-postgres` features
//!   `with-chrono-0_4`, `with-uuid-1`, `with-serde_json-1` are enabled so
//!   `row.get::<_, DateTime<Utc>>(…)` etc. work without intermediate parsing.
//!
//! ## Correctness notes (from `docs/RECORDER-CORRECTNESS.md`)
//!
//! * Item 7  — live-retention deletes SKIP archive-enabled cameras.
//! * Item 8  — archive move is copy→verify→`update_segment_archive`→delete.
//! * Item 9  — startup reconciliation uses [`list_all_segment_paths`] over both
//!   storages.
//! * Item 10 — retention deletes file *then* row; [`delete_segment_row`] is
//!   called only after the filesystem delete succeeds.
//! * Item 13 — [`upsert_storage`] is idempotent on `name` (`ON CONFLICT`).

use anyhow::{Context, Result};
use chrono::{DateTime, TimeZone, Utc};
use deadpool_postgres::{Config as DeadpoolConfig, Hook, HookError, Pool, Runtime};
use serde::Serialize;
use tokio_postgres::NoTls;
use uuid::Uuid;

use crate::types::{
    Bookmark, Camera, CameraDecodeStatus, CameraGroup, CameraHaLink, CameraMotionCacheStatus,
    Capabilities, FrigateSettings, HaSettings, MotionCacheStatus, MotionGrid, MotionSensitivity,
    MotionSignal, RecordStream, RecorderCapabilities, RecorderHeartbeat, RecordingMode,
    RecordingPolicy, Role, Segment, SegmentStage, SegmentStream, ServerSettings, Session, Storage,
    StorageMigration, User, UserRole, View,
};

// ─── pool creation ───────────────────────────────────────────────────────────

/// Default `statement_timeout` applied to every pooled connection (30s). See
/// [`build_pool`] for rationale; overridable via `DB_STATEMENT_TIMEOUT_MS`.
const DEFAULT_STATEMENT_TIMEOUT_MS: u64 = 30_000;

/// Default `lock_timeout` applied to every pooled connection (10s). See
/// [`build_pool`] for rationale; overridable via `DB_LOCK_TIMEOUT_MS`.
const DEFAULT_LOCK_TIMEOUT_MS: u64 = 10_000;

/// Read a millisecond duration from `key`, falling back to `default` if unset
/// or unparsable. Used only for the two pool-session timeouts below — kept
/// local (rather than routed through `crumb_common::config::Config`) because
/// `build_pool` is called with a bare `database_url` + `pool_size` from
/// several binaries (recorder `main`, `api` `main`, the `seed` bin, ad-hoc
/// pools in `archive.rs`/`reconcile.rs`) and changing its signature would
/// ripple into files outside this module.
fn timeout_ms_env(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(default)
}

/// Build and return a `deadpool-postgres` connection pool.
///
/// The `database_url` must be a valid `libpq`-style connection string, e.g.:
/// `postgresql://user:pass@host:5432/dbname`.
///
/// # Errors
///
/// Returns an error if the URL cannot be parsed or the pool cannot be created.
pub fn build_pool(database_url: &str, pool_size: usize) -> Result<Pool> {
    let mut cfg = DeadpoolConfig::new();
    cfg.url = Some(database_url.to_owned());
    // Bound how long pool.get() / connection-create can block. Without these,
    // a saturated pool makes pool.get() wait FOREVER, which can stall callers on
    // hot paths (e.g. the motion loop's stdout reader). Fail fast and let the
    // caller log/retry instead of hanging.
    let mut pool_cfg = deadpool_postgres::PoolConfig::new(pool_size);
    pool_cfg.timeouts = deadpool_postgres::Timeouts {
        // Fail FAST when the pool is saturated (2s) so a hot-path caller logs/retries
        // instead of compounding a multi-second stall; connect/recycle keep 5s.
        wait: Some(std::time::Duration::from_secs(2)),
        create: Some(std::time::Duration::from_secs(5)),
        recycle: Some(std::time::Duration::from_secs(5)),
    };
    cfg.pool = Some(pool_cfg);

    // Bound how long a statement will WAIT on a lock before erroring, and how
    // long any single statement may RUN, on every pooled connection. Without
    // these, a stuck query or a lock-contended UPDATE (a per-camera policy COW
    // edit racing the reconciler/eviction, or a segment bulk-update) can hold a
    // connection indefinitely and starve the whole 32-conn pool.
    //
    // * `lock_timeout` only aborts statements BLOCKED waiting on a lock; it
    //   never affects an uncontended query.
    // * `statement_timeout` bounds total execution time of any statement,
    //   contended or not — the backstop for a runaway query.
    //
    // Both are set via a post-create hook (one `SET` per physical connection)
    // rather than libpq `options`, so they do NOT clobber any `options`
    // already in the URL (the test harness puts `search_path` there for
    // per-schema isolation).
    //
    // Migrations exemption: `run_migrations_locked` uses this SAME pool to run
    // DDL, including `CREATE INDEX CONCURRENTLY` builds that can legitimately
    // take far longer than 30s on a large table. That function explicitly
    // raises/clears `statement_timeout` around its own DDL (see the "migration
    // timeout exemption" comments there) rather than us weakening the default
    // here — every other caller keeps the safety net.
    let statement_timeout_ms =
        timeout_ms_env("DB_STATEMENT_TIMEOUT_MS", DEFAULT_STATEMENT_TIMEOUT_MS);
    let lock_timeout_ms = timeout_ms_env("DB_LOCK_TIMEOUT_MS", DEFAULT_LOCK_TIMEOUT_MS);
    cfg.builder(NoTls)
        .context("failed to create deadpool-postgres pool builder")?
        .runtime(Runtime::Tokio1)
        .post_create(Hook::async_fn(move |client, _| {
            Box::pin(async move {
                client
                    .batch_execute(&format!(
                        "SET statement_timeout = '{statement_timeout_ms}ms'; \
                         SET lock_timeout = '{lock_timeout_ms}ms'"
                    ))
                    .await
                    .map_err(HookError::Backend)?;
                Ok(())
            })
        }))
        .build()
        .context("failed to build deadpool-postgres pool")
}

/// Pool-checkout latency above which we emit a saturation WARN (audit Risk #1:
/// operators were blind to pool starvation).
const SLOW_POOL_GET_MS: u128 = 100;

/// Acquire a pooled connection, instrumented.
///
/// Wraps `pool.get()` and logs a WARN (with the current pool status: size /
/// available / waiting) whenever the checkout blocks longer than
/// [`SLOW_POOL_GET_MS`]. A slow checkout is the canonical early symptom of pool
/// saturation under load; surfacing it turns a silent multi-second stall into a
/// visible operator signal. Every accessor in this module acquires its
/// connection through here.
pub async fn get_conn(pool: &Pool) -> Result<deadpool_postgres::Client> {
    let start = std::time::Instant::now();
    let res = pool.get().await;
    let elapsed_ms = start.elapsed().as_millis();
    if elapsed_ms >= SLOW_POOL_GET_MS {
        tracing::warn!(
            elapsed_ms = u64::try_from(elapsed_ms).unwrap_or(u64::MAX),
            pool_status = ?pool.status(),
            "slow DB pool checkout (>={}ms) — pool may be saturated",
            SLOW_POOL_GET_MS
        );
    }
    res.context("db pool get")
}

// ─── single-writer advisory lock ─────────────────────────────────────────────

/// A 64-bit key for `pg_advisory_lock`, distinct from any other advisory lock
/// the app takes (the COW policy path uses its own keys). Arbitrary but fixed —
/// "CRUMBREC" rendered as a constant. Both recorders must agree on it for the
/// mutual-exclusion to work.
const RECORDER_SINGLETON_LOCK_KEY: i64 = 0x4352_554D_4252_4543; // 'CRUMBREC'

/// A held session-scoped recorder-singleton lock.
///
/// Owns the dedicated `tokio_postgres` connection on which
/// `pg_try_advisory_lock` was taken. The session-level advisory lock is held for
/// **exactly as long as this guard (and its connection) lives** — dropping it
/// closes the connection, which releases the lock. Keep it alive for the whole
/// recorder process lifetime (store it in `main`); do NOT take it from the
/// deadpool (pooled connections get recycled, which would silently drop the
/// lock).
pub struct RecorderSingletonLock {
    // The connection task handle; aborting/dropping it ends the session and
    // releases the lock. Held only to keep the connection alive.
    _conn_task: tokio::task::JoinHandle<()>,
    // The client kept alive so the session (and thus the lock) persists.
    _client: tokio_postgres::Client,
}

/// Acquire the recorder single-writer advisory lock on a DEDICATED connection.
///
/// Returns `Ok(Some(guard))` if this process won the lock (it is the sole
/// recorder), `Ok(None)` if another recorder already holds it (the caller should
/// log a clear error and exit — two recorders racing the same DB + storage tree
/// corrupt the index, per audit P2 #14), or `Err` only on a connection failure.
///
/// Uses `pg_try_advisory_lock` (non-blocking) so a second recorder fails fast
/// rather than hanging. The lock auto-releases if this process dies (the DB drops
/// the session), so a crashed recorder never wedges its successor.
///
/// # Errors
///
/// Returns an error if the dedicated connection cannot be established.
pub async fn acquire_recorder_singleton_lock(
    database_url: &str,
) -> Result<Option<RecorderSingletonLock>> {
    let (client, connection) = tokio_postgres::connect(database_url, NoTls)
        .await
        .context("recorder singleton lock: dedicated connect")?;

    // Drive the connection on its own task. If it ever ends (DB restart, network
    // drop), the session — and the advisory lock — is gone; we log so the
    // operator knows the singleton guarantee lapsed until the recorder restarts.
    let conn_task = tokio::spawn(async move {
        if let Err(e) = connection.await {
            tracing::error!(error = %e, "recorder singleton lock connection ended; lock released");
        }
    });

    let row = client
        .query_one(
            "SELECT pg_try_advisory_lock($1)",
            &[&RECORDER_SINGLETON_LOCK_KEY],
        )
        .await
        .context("recorder singleton lock: pg_try_advisory_lock")?;
    let got: bool = row.get(0);

    if got {
        Ok(Some(RecorderSingletonLock {
            _conn_task: conn_task,
            _client: client,
        }))
    } else {
        // Release our resources; another holder owns the lock.
        conn_task.abort();
        Ok(None)
    }
}

// ─── storages ────────────────────────────────────────────────────────────────

/// Upsert a storage row by name (idempotent).
///
/// Correctness item 13: using `ON CONFLICT (name) DO UPDATE` means repeated
/// calls from the `seed` binary / entrypoint never insert duplicate rows.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn upsert_storage(pool: &Pool, name: &str, path: &str) -> Result<Storage> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO storages (name, path)
            VALUES ($1, $2)
            ON CONFLICT (name) DO UPDATE
                SET path = EXCLUDED.path
            RETURNING id, name, path, total_bytes, icon, created_at
            ",
            &[&name, &path],
        )
        .await
        .context("upsert_storage")?;

    Ok(storage_from_row(&row))
}

/// Fetch a storage row by its UUID.
///
/// Returns `None` if the row does not exist.
pub async fn get_storage(pool: &Pool, id: Uuid) -> Result<Option<Storage>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT id, name, path, total_bytes, icon, created_at FROM storages WHERE id = $1",
            &[&id],
        )
        .await
        .context("get_storage")?;
    Ok(opt.map(|r| storage_from_row(&r)))
}

/// Fetch a storage row by its human name.
pub async fn get_storage_by_name(pool: &Pool, name: &str) -> Result<Option<Storage>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT id, name, path, total_bytes, icon, created_at FROM storages WHERE name = $1",
            &[&name],
        )
        .await
        .context("get_storage_by_name")?;
    Ok(opt.map(|r| storage_from_row(&r)))
}

/// Fetch ALL storage rows that share a human name.
///
/// `storages.name` carries a `UNIQUE` constraint, so this normally returns 0 or 1
/// row. It exists so the NULL-policy fallback (recording.rs A1c) can DETECT the
/// pathological "name maps to >1 row" case and warn loudly rather than silently
/// picking one, should that invariant ever be weakened.
pub async fn find_storages_by_name(pool: &Pool, name: &str) -> Result<Vec<Storage>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT id, name, path, total_bytes, icon, created_at FROM storages WHERE name = $1 ORDER BY created_at",
            &[&name],
        )
        .await
        .context("find_storages_by_name")?;
    Ok(rows.iter().map(storage_from_row).collect())
}

/// Resolve a segment's absolute on-disk path from its OWN `storage_id`
/// (authoritative), rather than guessing the mount from `stage`.
///
/// The API historically chose the file root by `stage` (live→live mount,
/// archive→archive mount), which silently breaks the moment a policy's
/// `live_storage` is repointed to a different disk: footage then lives on a disk
/// that no longer matches its stage, and the stage→mount guess 404s. Resolving by
/// `storage_id` mirrors the recorder (which always has) and is correct under any
/// per-policy storage layout. Returns `None` only when the segment's `storage_id`
/// has no `storages` row (should not happen — NOT NULL + FK); callers may then
/// fall back to a stage→mount guess.
pub async fn segment_abs_path(pool: &Pool, seg: &Segment) -> Result<Option<std::path::PathBuf>> {
    Ok(get_storage(pool, seg.storage_id)
        .await?
        .map(|s| std::path::Path::new(&s.path).join(&seg.path)))
}

/// All storages as an `id → path` map, for batch file resolution without an N+1
/// `get_storage` per segment. See [`segment_abs_path`] for why resolution must be
/// by `storage_id`.
pub async fn storage_path_map(pool: &Pool) -> Result<std::collections::HashMap<Uuid, String>> {
    Ok(list_storages(pool)
        .await?
        .into_iter()
        .map(|s| (s.id, s.path))
        .collect())
}

fn storage_from_row(row: &tokio_postgres::Row) -> Storage {
    Storage {
        id: row.get("id"),
        name: row.get("name"),
        path: row.get("path"),
        total_bytes: row.get("total_bytes"),
        icon: row.get("icon"),
        created_at: row.get("created_at"),
    }
}

// ─── cameras ─────────────────────────────────────────────────────────────────

/// Return all enabled cameras, each with its fully-joined policy.
///
/// Used by the supervisor's config-poll loop to diff against running workers.
pub async fn list_enabled_cameras(pool: &Pool) -> Result<Vec<Camera>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            &format!("{CAMERA_SELECT_SQL} WHERE v.c_enabled = $1"),
            &[&true],
        )
        .await
        .context("list_enabled_cameras")?;
    rows.iter().map(camera_from_row).collect()
}

/// Load a single camera by UUID (with joined policy).
pub async fn get_camera(pool: &Pool, id: Uuid) -> Result<Option<Camera>> {
    let client = get_conn(pool).await?;
    // Resolve by id WITHOUT the enabled filter so reconcile can find disabled
    // cameras' rows (correctness item 9 — otherwise their footage is quarantined).
    let rows = client
        .query(&format!("{CAMERA_SELECT_SQL} WHERE v.c_id = $1"), &[&id])
        .await
        .context("get_camera")?;
    rows.first().map(camera_from_row).transpose()
}

/// The base SELECT that fetches a camera row joined with its EFFECTIVE policy.
///
/// Backed by the `v_camera_effective_policy` view (migration 0019), which
/// encapsulates the canonical own→group→default effective-policy resolution and
/// exposes every camera column as `c_*` (plus the camera's group id as
/// `c_group_id`) and every effective recording-policy column as `p_*` — the SAME
/// aliases [`camera_from_row`] reads, so the view is a drop-in for the old inline
/// COALESCE join. The view is aliased `v` here so each caller can append its own
/// predicate against the view's aliased columns.
///
/// No WHERE clause — each caller appends its own predicate. `get_camera` must
/// NOT filter on `enabled` (so reconcile can resolve disabled cameras —
/// correctness item 9); `list_enabled_cameras` appends `WHERE v.c_enabled = $1`.
///
/// Includes the six columns added by migration 0012 (`served_by`,
/// `source_camera_name`, `onvif_host`, `onvif_port`, `onvif_user`,
/// `onvif_password`) — all surfaced by the view. They are nullable / defaulted so
/// this works against a DB that has not yet had 0012 applied (the ensure-shims +
/// migration 0018 add them before this query runs at startup).
const CAMERA_SELECT_SQL: &str = r"
    SELECT * FROM v_camera_effective_policy v
";

fn camera_from_row(row: &tokio_postgres::Row) -> Result<Camera> {
    let mode_str: String = row.get("p_mode");
    let mode = RecordingMode::from_str(&mode_str)
        .with_context(|| format!("unknown recording mode '{mode_str}'"))?;

    let sens_str: String = row.get("p_motion_sensitivity");
    let motion_sensitivity = MotionSensitivity::from_str(&sens_str)
        .with_context(|| format!("unknown motion sensitivity '{sens_str}'"))?;

    let stream_str: String = row.get("p_record_stream");
    let record_stream = RecordStream::from_str(&stream_str)
        .with_context(|| format!("unknown record stream '{stream_str}'"))?;

    let policy = RecordingPolicy {
        id: row.get("p_id"),
        name: row.get("p_name"),
        is_default: row.get("p_is_default"),
        mode,
        live_storage_id: row.get("p_live_storage_id"),
        live_retention_hours: row.get("p_live_retention_hours"),
        archive_enabled: row.get("p_archive_enabled"),
        archive_storage_id: row.get("p_archive_storage_id"),
        archive_schedule: row.get("p_archive_schedule"),
        archive_retention_hours: row.get("p_archive_retention_hours"),
        live_max_bytes: row.get("p_live_max_bytes"),
        archive_max_bytes: row.get("p_archive_max_bytes"),
        live_min_free_pct: row.get("p_live_min_free_pct"),
        live_min_free_bytes: row.get("p_live_min_free_bytes"),
        live_spill_low_water_bytes: row.get("p_live_spill_low_water_bytes"),
        max_retention_days: row.get("p_max_retention_days"),
        motion_pre_seconds: row.get("p_motion_pre_seconds"),
        motion_post_seconds: row.get("p_motion_post_seconds"),
        motion_sensitivity,
        motion_threshold: row.get("p_motion_threshold"),
        motion_keyframes_only: row.get("p_motion_keyframes_only"),
        record_stream,
        record_audio: row.get("p_record_audio"),
    };

    Ok(Camera {
        id: row.get("c_id"),
        name: row.get("c_name"),
        enabled: row.get("c_enabled"),
        go2rtc_name: row.get("c_go2rtc_name"),
        main_url: row.get("c_main_url"),
        sub_url: row.get("c_sub_url"),
        source_url: row.get("c_source_url"),
        source_sub_url: row.get("c_source_sub_url"),
        policy_id: row.get("c_policy_id"),
        group_id: row.get("c_group_id"),
        policy,
        motion_mask: row.get("c_motion_mask"),
        onvif_motion: row.get("c_onvif_motion"),
        motion_source: row.get("c_motion_source"),
        motion_algorithm: row.get("c_motion_algorithm"),
        camera_type: row.get("c_camera_type"),
        icon: row.get("c_icon"),
        motion_grid_cols: row.get("c_motion_grid_cols"),
        motion_grid_rows: row.get("c_motion_grid_rows"),
        created_at: row.get("c_created_at"),
        // columns added by migration 0012 — present after ensure_camera_ownership_columns()
        served_by: row
            .try_get::<_, String>("c_served_by")
            .unwrap_or_else(|_| "crumb".to_owned()),
        source_camera_name: row.try_get("c_source_camera_name").unwrap_or(None),
        onvif_host: row.try_get("c_onvif_host").unwrap_or(None),
        onvif_port: row.try_get("c_onvif_port").unwrap_or(None),
        onvif_user: row.try_get("c_onvif_user").unwrap_or(None),
        onvif_password: row.try_get("c_onvif_password").unwrap_or(None),
    })
}

// ─── segments — insert / update ──────────────────────────────────────────────

/// Upper bound on a single segment's wall-clock duration, used as the sargable
/// lower-bound offset in time-window queries (`start_ts >= start - MAX_SEGMENT_LEN`).
///
/// The recorder caps `SEGMENT_SECONDS` at 6s; we use 2× that (12s) so even a
/// boundary-straddling segment (or a slightly long final segment recovered at
/// shutdown) is always captured. Over-estimating only widens the index range
/// scan slightly; under-estimating would drop a real overlapping segment, so we
/// err generous.
pub const MAX_SEGMENT_LEN: chrono::Duration = chrono::Duration::seconds(12);

/// Default page size for the keyset-paginated reconcile boot load
/// ([`list_segments_after`]). Each page is one round-trip; 10k rows is a few MB
/// of `Segment` structs, well under the recorder's 4GiB cap, while keeping the
/// number of round-trips low even at the 1M-row target.
pub const RECONCILE_PAGE_SIZE: i64 = 10_000;

/// Parameters for inserting a new segment row.
///
/// All fields correspond 1:1 to `segments` columns.
#[derive(Debug)]
pub struct InsertSegmentParams {
    pub camera_id: Uuid,
    pub storage_id: Uuid,
    pub stage: SegmentStage,
    pub path: String,
    pub stream: SegmentStream,
    pub start_ts: DateTime<Utc>,
    pub end_ts: DateTime<Utc>,
    pub duration_ms: i32,
    pub has_motion: bool,
    /// Peak motion magnitude over the segment (changed-pixel fraction 0..1).
    /// Drives the timeline motion-intensity histogram. 0.0 when no motion.
    pub motion_score: f32,
    pub size_bytes: i64,
    /// Normalized `[x, y, w, h]` (0..1) bounding box of the motion at the segment's
    /// peak-motion frame, for the clip motion-highlight auto-zoom. `None` when the
    /// segment has no motion or the source didn't capture a region.
    pub motion_bbox: Option<[f32; 4]>,
}

/// Insert a new segment row and return its UUID (UPSERT on re-index/overwrite).
///
/// `ON CONFLICT (camera_id, stream, start_ts) DO UPDATE` so a re-index of the
/// same boundary (the reconcile/recorder race, a same-second reopen, or an
/// orphan reindex of a file the live insert already wrote) **UPSERTs into the
/// existing row instead of forking a duplicate** — the root cause of the prod
/// 815 dup groups and the 28-byte skeleton rows. The merge is monotone-safe:
///
///   * `size_bytes` / `end_ts` take the **GREATEST** so a fuller/longer later
///     write wins and a smaller skeleton can never shrink a real row.
///   * `has_motion` is OR-ed so motion is never erased by a no-motion reindex.
///   * `path` / `storage_id` / `stage` / `duration_ms` / `motion_score` adopt
///     the NEW values (the latest writer knows the current file location/stream
///     stage and recomputed duration).
///
/// Requires the `segments_uniq_cam_stream_start` unique index (migration 0009).
/// On a DB that has not yet had 0009 applied, the conflict target does not exist
/// and Postgres errors — apply the migrations first (the recorder will surface
/// the error per-segment and continue, exactly like any insert failure).
///
/// # Errors
///
/// Returns an error if the query fails (e.g. foreign-key violation, disk full,
/// or the unique index is absent).
pub async fn insert_segment(pool: &Pool, p: &InsertSegmentParams) -> Result<Uuid> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO segments
                (camera_id, storage_id, stage, path, stream,
                 start_ts, end_ts, duration_ms, has_motion, motion_score, size_bytes,
                 motion_bbox_x, motion_bbox_y, motion_bbox_w, motion_bbox_h)
            VALUES
                ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
            ON CONFLICT (camera_id, stream, start_ts) DO UPDATE SET
                size_bytes  = GREATEST(segments.size_bytes, EXCLUDED.size_bytes),
                end_ts      = GREATEST(segments.end_ts, EXCLUDED.end_ts),
                path        = EXCLUDED.path,
                storage_id  = EXCLUDED.storage_id,
                stage       = EXCLUDED.stage,
                duration_ms = EXCLUDED.duration_ms,
                motion_score = GREATEST(segments.motion_score, EXCLUDED.motion_score),
                has_motion  = EXCLUDED.has_motion OR segments.has_motion,
                -- Adopt the incoming bbox only when this write's motion is at least
                -- as strong as what's stored, so the bbox tracks the winning peak
                -- and a weaker (or bbox-less) re-index never clobbers it.
                motion_bbox_x = CASE WHEN EXCLUDED.motion_score >= segments.motion_score
                                     THEN EXCLUDED.motion_bbox_x ELSE segments.motion_bbox_x END,
                motion_bbox_y = CASE WHEN EXCLUDED.motion_score >= segments.motion_score
                                     THEN EXCLUDED.motion_bbox_y ELSE segments.motion_bbox_y END,
                motion_bbox_w = CASE WHEN EXCLUDED.motion_score >= segments.motion_score
                                     THEN EXCLUDED.motion_bbox_w ELSE segments.motion_bbox_w END,
                motion_bbox_h = CASE WHEN EXCLUDED.motion_score >= segments.motion_score
                                     THEN EXCLUDED.motion_bbox_h ELSE segments.motion_bbox_h END
            RETURNING id
            ",
            &[
                &p.camera_id,
                &p.storage_id,
                &p.stage.as_str(),
                &p.path,
                &p.stream.as_str(),
                &p.start_ts,
                &p.end_ts,
                &p.duration_ms,
                &p.has_motion,
                &p.motion_score,
                &p.size_bytes,
                &p.motion_bbox.map(|b| b[0]),
                &p.motion_bbox.map(|b| b[1]),
                &p.motion_bbox.map(|b| b[2]),
                &p.motion_bbox.map(|b| b[3]),
            ],
        )
        .await
        .context("insert_segment")?;
    Ok(row.get(0))
}

/// Stamp the shadow-mode verdict (`segments.motion_shadow_keep`, migration 0037)
/// for the segment matching `(camera_id, path)`.
///
/// Used ONLY when `MOTION_RECORDING_SHADOW=1`: Motion-mode cameras record and
/// index every segment exactly as Continuous mode (no file-operation changes),
/// but the recorder ALSO evaluates what `MotionBuffer` would have decided and
/// records that verdict here for prod validation before flipping shadow mode
/// off. `true` = the buffer would have persisted this segment; `false` = it
/// would have discarded it. Matches by `(camera_id, path)` rather than the
/// segment id because the shadow decision is made from the same
/// `PendingSegment` the live indexer just inserted, before the caller has (or
/// needs) the returned row id.
///
/// A no-op (silently matches zero rows) if the segment was not indexed (e.g.
/// sub-floor reject) — the caller does not treat that as an error.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn set_segment_motion_shadow_keep(
    pool: &Pool,
    camera_id: Uuid,
    path: &str,
    keep: bool,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            UPDATE segments
            SET motion_shadow_keep = $3
            WHERE camera_id = $1 AND path = $2
            ",
            &[&camera_id, &path, &keep],
        )
        .await
        .context("set_segment_motion_shadow_keep")?;
    Ok(())
}

/// CONSERVATIVE insert for the reconcile orphan-adoption path (C1).
///
/// Unlike [`insert_segment`] — which UPSERTs and so will *relocate* an existing
/// row's `storage_id`/`path` to the incoming values — this NEVER modifies a row
/// that already exists at `(camera_id, stream, start_ts)`. It inserts ONLY when
/// the key is absent (a TRUE orphan).
///
/// Why this split exists: a segment's physical location is defined SOLELY by its
/// `storage_id` (→ `storages.path`) + `path`. The recorder's live-finalize path
/// legitimately knows the current location and may adopt (it keeps
/// [`insert_segment`]). Reconcile, however, walks the filesystem and must not let
/// a stray duplicate file on disk B flip a healthy row that points at disk A —
/// that was the storage ping-pong. `ON CONFLICT … DO NOTHING` makes the orphan
/// walk strictly additive.
///
/// Returns:
///   * `Some(id)` — a brand-new row was inserted (the key was a true orphan).
///   * `None`     — a row already existed at the key; nothing was modified.
///
/// Requires the `segments_uniq_cam_stream_start` unique index (migration 0009),
/// same as [`insert_segment`].
///
/// # Errors
///
/// Returns an error if the query fails (e.g. foreign-key violation, disk full,
/// or the unique index is absent).
pub async fn insert_segment_if_absent(
    pool: &Pool,
    p: &InsertSegmentParams,
) -> Result<Option<Uuid>> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            r"
            INSERT INTO segments
                (camera_id, storage_id, stage, path, stream,
                 start_ts, end_ts, duration_ms, has_motion, motion_score, size_bytes,
                 motion_bbox_x, motion_bbox_y, motion_bbox_w, motion_bbox_h)
            VALUES
                ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
            ON CONFLICT (camera_id, stream, start_ts) DO NOTHING
            RETURNING id
            ",
            &[
                &p.camera_id,
                &p.storage_id,
                &p.stage.as_str(),
                &p.path,
                &p.stream.as_str(),
                &p.start_ts,
                &p.end_ts,
                &p.duration_ms,
                &p.has_motion,
                &p.motion_score,
                &p.size_bytes,
                &p.motion_bbox.map(|b| b[0]),
                &p.motion_bbox.map(|b| b[1]),
                &p.motion_bbox.map(|b| b[2]),
                &p.motion_bbox.map(|b| b[3]),
            ],
        )
        .await
        .context("insert_segment_if_absent")?;
    Ok(row.map(|r| r.get(0)))
}

/// Stamp `has_motion = true` on a segment.
///
/// Called by `recording.rs` when a `MotionSignal` overlaps a segment's time
/// window.
pub async fn mark_segment_has_motion(pool: &Pool, segment_id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE segments SET has_motion = true WHERE id = $1",
            &[&segment_id],
        )
        .await
        .context("mark_segment_has_motion")?;
    Ok(())
}

/// Update a segment row after a successful archive move.
///
/// Called as the **last** step of the copy→verify→update→delete sequence
/// (correctness item 8).
///
/// The caller is responsible for performing the copy, verifying the
/// destination, then calling this function, then deleting the source file.
pub async fn update_segment_archive(
    pool: &Pool,
    segment_id: Uuid,
    new_storage_id: Uuid,
    new_path: &str,
) -> Result<()> {
    let client = get_conn(pool).await?;
    let updated = client
        .execute(
            r"
            UPDATE segments
            SET storage_id = $1,
                stage      = 'archive',
                path       = $2
            WHERE id = $3
            ",
            &[&new_storage_id, &new_path, &segment_id],
        )
        .await
        .context("update_segment_archive")?;
    anyhow::ensure!(
        updated == 1,
        "update_segment_archive: segment {segment_id} not found"
    );
    Ok(())
}

/// Repoint a segment to a different storage WITHOUT changing its stage or path
/// (the same relative path is reused under the new storage root). Used by the
/// guarded "Change storage" drain ([`crate`] migration worker): the caller has
/// already copied→verified→fsynced the file at the SAME relative path on the new
/// disk, calls this to flip the authoritative `storage_id`, then deletes the
/// source. Mirrors the safe ordering of [`update_segment_archive`].
///
/// `expected_from` guards against a concurrent relocation: the UPDATE only
/// applies when the row is still on the storage we copied FROM, so two movers
/// (or a re-run) can't double-flip or fight. Returns whether the row was updated.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn update_segment_storage(
    pool: &Pool,
    segment_id: Uuid,
    new_storage_id: Uuid,
    expected_from: Uuid,
) -> Result<bool> {
    let client = get_conn(pool).await?;
    let updated = client
        .execute(
            r"
            UPDATE segments
            SET storage_id = $1
            WHERE id = $2 AND storage_id = $3
            ",
            &[&new_storage_id, &segment_id, &expected_from],
        )
        .await
        .context("update_segment_storage")?;
    Ok(updated == 1)
}

/// Bulk variant of [`update_segment_storage`]: flip MANY segments to
/// `new_storage_id` in ONE round-trip + ONE WAL flush, instead of one autocommit
/// UPDATE (and one fsync) per file. Guarded identically — only rows still on
/// `expected_from` flip — and `RETURNING id` reports exactly which rows changed,
/// so the caller knows which source files are now safe to delete. Rows a
/// concurrent mover / eviction already changed simply don't come back.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn bulk_update_segment_storage(
    pool: &Pool,
    segment_ids: &[Uuid],
    new_storage_id: Uuid,
    expected_from: Uuid,
) -> Result<Vec<Uuid>> {
    if segment_ids.is_empty() {
        return Ok(Vec::new());
    }
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            UPDATE segments
            SET storage_id = $1
            WHERE id = ANY($2) AND storage_id = $3
            RETURNING id
            ",
            &[&new_storage_id, &segment_ids, &expected_from],
        )
        .await
        .context("bulk_update_segment_storage")?;
    Ok(rows.iter().map(|r| r.get::<_, Uuid>(0)).collect())
}

/// Count segments belonging to `policy_id` (own → group → default) that currently
/// live on `from_storage_id`. Used to size a "Change storage" drain up front.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn count_policy_segments_on_storage(
    pool: &Pool,
    policy_id: Uuid,
    from_storage_id: Uuid,
) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            SELECT COUNT(*)::bigint
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            WHERE s.storage_id = $2
              AND v.p_id = $1
            ",
            &[&policy_id, &from_storage_id],
        )
        .await
        .context("count_policy_segments_on_storage")?;
    Ok(row.get(0))
}

/// Total bytes of segments belonging to `policy_id` currently on `from_storage_id`
/// — the size a "Change storage" drain must fit on the target. Used for pre-flight.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn policy_bytes_on_storage(
    pool: &Pool,
    policy_id: Uuid,
    from_storage_id: Uuid,
) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            SELECT COALESCE(SUM(s.size_bytes), 0)::bigint
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            WHERE s.storage_id = $2
              AND v.p_id = $1
            ",
            &[&policy_id, &from_storage_id],
        )
        .await
        .context("policy_bytes_on_storage")?;
    Ok(row.get(0))
}

/// List segments belonging to `policy_id` (own → group → default) that live on
/// `from_storage_id`, oldest first, capped at `limit`. The drain batches through
/// these. Oldest-first means a crash mid-drain leaves the NEWEST footage (most
/// likely to be viewed) until last, and re-running resumes cleanly (moved rows
/// drop out of the result because their `storage_id` changed).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_policy_segments_on_storage(
    pool: &Pool,
    policy_id: Uuid,
    from_storage_id: Uuid,
    limit: i64,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT s.id, s.camera_id, s.storage_id, s.stage, s.path,
                   s.stream, s.start_ts, s.end_ts, s.duration_ms,
                   s.has_motion, s.size_bytes
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            WHERE s.storage_id = $2
              AND v.p_id = $1
            ORDER BY s.start_ts ASC
            LIMIT $3
            ",
            &[&policy_id, &from_storage_id, &limit],
        )
        .await
        .context("list_policy_segments_on_storage")?;
    rows.iter().map(segment_from_row).collect()
}

// ─── storage migrations ("Change storage" drain jobs) ─────────────────────────

fn storage_migration_from_row(row: &tokio_postgres::Row) -> StorageMigration {
    StorageMigration {
        id: row.get("id"),
        policy_id: row.get("policy_id"),
        from_storage_id: row.get("from_storage_id"),
        to_storage_id: row.get("to_storage_id"),
        status: row.get("status"),
        total_segments: row.get("total_segments"),
        moved_segments: row.get("moved_segments"),
        moved_bytes: row.get("moved_bytes"),
        error: row.get("error"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

/// Ensure the `storage_migrations` job table exists (idempotent). One row per
/// "Change storage" drain. The recorder's migration worker claims `pending` rows,
/// flips them to `running`, drains, then marks `done`/`failed`.
///
/// # Errors
///
/// Returns an error if the DDL fails.
pub async fn ensure_storage_migrations_table(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    // CREATE TABLE includes 'cancelled' in the CHECK from the start so fresh
    // installs get the full constraint.  Existing tables have their constraint
    // upgraded by migration 0014 (which drops the old constraint and adds the
    // wider one).  The CREATE TABLE here is only reached on a truly fresh DB;
    // the IF NOT EXISTS makes it a no-op on an existing table.
    client
        .batch_execute(
            r"
            CREATE TABLE IF NOT EXISTS storage_migrations (
                id              uuid PRIMARY KEY,
                policy_id       uuid NOT NULL,
                from_storage_id uuid NOT NULL REFERENCES storages(id) ON DELETE RESTRICT,
                to_storage_id   uuid NOT NULL REFERENCES storages(id) ON DELETE RESTRICT,
                status          text NOT NULL DEFAULT 'pending'
                                  CHECK (status IN ('pending','running','done','failed','cancelled')),
                total_segments  bigint NOT NULL DEFAULT 0,
                moved_segments  bigint NOT NULL DEFAULT 0,
                moved_bytes     bigint NOT NULL DEFAULT 0,
                error           text,
                created_at      timestamptz NOT NULL DEFAULT now(),
                updated_at      timestamptz NOT NULL DEFAULT now()
            );
            CREATE INDEX IF NOT EXISTS storage_migrations_status_idx
                ON storage_migrations (status, created_at);
            ",
        )
        .await
        .context("ensure_storage_migrations_table")?;
    Ok(())
}

/// Ensure the composite index that keeps the "Change storage" drain's batch SELECT
/// cheap. The drain repeatedly runs `WHERE storage_id = $ ... ORDER BY start_ts
/// LIMIT n`; with no index leading on `storage_id` Postgres falls back to a full
/// scan of the (potentially many-hundred-thousand-row) segments table for EVERY
/// batch — O(rows × batches). `(storage_id, start_ts)` turns each batch into a
/// tight range scan that also satisfies the ORDER BY without a sort.
///
/// Idempotent (`IF NOT EXISTS`); a no-op once the index exists. Built
/// non-concurrently — acceptable because it runs at startup before the recording
/// loops spin up, so the brief share-lock doesn't contend with live inserts.
///
/// # Errors
///
/// Returns an error if the statement fails.
pub async fn ensure_segments_storage_index(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            CREATE INDEX IF NOT EXISTS segments_storage_start
                ON segments (storage_id, start_ts);
            ",
        )
        .await
        .context("ensure_segments_storage_index")?;
    Ok(())
}

/// Create a `pending` migration. `total_segments` is a snapshot count for the UI.
///
/// # Errors
///
/// Returns an error if the insert fails.
pub async fn create_storage_migration(
    pool: &Pool,
    policy_id: Uuid,
    from_storage_id: Uuid,
    to_storage_id: Uuid,
    total_segments: i64,
) -> Result<StorageMigration> {
    let client = get_conn(pool).await?;
    let id = Uuid::new_v4();
    let row = client
        .query_one(
            r"
            INSERT INTO storage_migrations
                (id, policy_id, from_storage_id, to_storage_id, status, total_segments)
            VALUES ($1, $2, $3, $4, 'pending', $5)
            RETURNING id, policy_id, from_storage_id, to_storage_id, status,
                      total_segments, moved_segments, moved_bytes, error,
                      created_at, updated_at
            ",
            &[
                &id,
                &policy_id,
                &from_storage_id,
                &to_storage_id,
                &total_segments,
            ],
        )
        .await
        .context("create_storage_migration")?;
    Ok(storage_migration_from_row(&row))
}

/// Fetch one migration by id.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn get_storage_migration(pool: &Pool, id: Uuid) -> Result<Option<StorageMigration>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"SELECT id, policy_id, from_storage_id, to_storage_id, status,
                     total_segments, moved_segments, moved_bytes, error,
                     created_at, updated_at
              FROM storage_migrations WHERE id = $1",
            &[&id],
        )
        .await
        .context("get_storage_migration")?;
    Ok(opt.as_ref().map(storage_migration_from_row))
}

/// List recent migrations, newest first.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_storage_migrations(pool: &Pool, limit: i64) -> Result<Vec<StorageMigration>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"SELECT id, policy_id, from_storage_id, to_storage_id, status,
                     total_segments, moved_segments, moved_bytes, error,
                     created_at, updated_at
              FROM storage_migrations ORDER BY created_at DESC LIMIT $1",
            &[&limit],
        )
        .await
        .context("list_storage_migrations")?;
    Ok(rows.iter().map(storage_migration_from_row).collect())
}

/// Atomically claim the oldest `pending` migration, flipping it to `running`.
/// `FOR UPDATE SKIP LOCKED` makes this safe if ever called concurrently. Returns
/// `None` when nothing is pending.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn claim_pending_migration(pool: &Pool) -> Result<Option<StorageMigration>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"
            UPDATE storage_migrations SET status = 'running', updated_at = now()
            WHERE id = (
                SELECT id FROM storage_migrations
                WHERE status = 'pending'
                ORDER BY created_at ASC
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            RETURNING id, policy_id, from_storage_id, to_storage_id, status,
                      total_segments, moved_segments, moved_bytes, error,
                      created_at, updated_at
            ",
            &[],
        )
        .await
        .context("claim_pending_migration")?;
    Ok(opt.as_ref().map(storage_migration_from_row))
}

/// Add to a migration's progress counters (called per drained batch).
///
/// # Errors
///
/// Returns an error if the update fails.
pub async fn add_migration_progress(
    pool: &Pool,
    id: Uuid,
    segments_delta: i64,
    bytes_delta: i64,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"UPDATE storage_migrations
              SET moved_segments = moved_segments + $2,
                  moved_bytes    = moved_bytes + $3,
                  updated_at     = now()
              WHERE id = $1",
            &[&id, &segments_delta, &bytes_delta],
        )
        .await
        .context("add_migration_progress")?;
    Ok(())
}

/// Mark a migration `done` or `failed` (with optional error detail).
///
/// # Errors
///
/// Returns an error if the update fails.
pub async fn set_migration_status(
    pool: &Pool,
    id: Uuid,
    status: &str,
    error: Option<&str>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"UPDATE storage_migrations SET status = $2, error = $3, updated_at = now() WHERE id = $1",
            &[&id, &status, &error],
        )
        .await
        .context("set_migration_status")?;
    Ok(())
}

/// Conditionally update a migration's status — only applies when the row is still
/// in `expected_current` status.
///
/// Returns `true` if the row was updated (the CAS succeeded), `false` if the row
/// was already in a different status (e.g. a concurrent cancel already applied).
///
/// Used by:
/// - The drain loop in `archive.rs` to flip `running` → `done`/`failed` only if
///   the row wasn't cancelled mid-drain.
/// - The cancel API route to flip `running`/`pending` → `cancelled` atomically.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn set_migration_status_if(
    pool: &Pool,
    id: Uuid,
    new_status: &str,
    expected_current: &str,
    error: Option<&str>,
) -> Result<bool> {
    let client = get_conn(pool).await?;
    let n = client
        .execute(
            r"
            UPDATE storage_migrations
            SET status     = $2,
                error      = $4,
                updated_at = now()
            WHERE id     = $1
              AND status = $3
            ",
            &[&id, &new_status, &expected_current, &error],
        )
        .await
        .context("set_migration_status_if")?;
    Ok(n == 1)
}

// ─── frigate / mqtt integration settings (singleton, hot-reloaded) ─────────────

fn frigate_settings_from_row(row: &tokio_postgres::Row) -> FrigateSettings {
    FrigateSettings {
        enabled: row.get("enabled"),
        mqtt_url: row.get("mqtt_url"),
        mqtt_prefix: row.get("mqtt_prefix"),
        mqtt_user: row.get("mqtt_user"),
        mqtt_password: row.get("mqtt_password"),
        api_base: row.get("api_base"),
        min_score: row.get("min_score"),
        catchup_hours: i64::from(row.get::<_, i32>("catchup_hours")),
        version: row.get("version"),
    }
}

/// Read the legacy `FRIGATE_*` env vars used to SEED the singleton row on first
/// creation (so an existing env-configured deployment carries over to the DB).
fn frigate_env_seed() -> (
    bool,
    String,
    String,
    Option<String>,
    Option<String>,
    String,
    f32,
    i32,
) {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let mqtt_url = env("FRIGATE_MQTT_URL").unwrap_or_default();
    let password = env("FRIGATE_MQTT_PASSWORD").or_else(|| {
        use base64::Engine as _;
        env("FRIGATE_MQTT_PASSWORD_B64").and_then(|b| {
            base64::engine::general_purpose::STANDARD
                .decode(b.trim())
                .ok()
                .and_then(|bytes| String::from_utf8(bytes).ok())
        })
    });
    (
        !mqtt_url.is_empty(),
        mqtt_url,
        env("FRIGATE_MQTT_PREFIX").unwrap_or_else(|| "frigate".to_owned()),
        env("FRIGATE_MQTT_USER"),
        password,
        env("FRIGATE_API_BASE").unwrap_or_default(),
        env("FRIGATE_MIN_SCORE")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0.3_f32),
        env("FRIGATE_CATCHUP_HOURS")
            .and_then(|v| v.parse().ok())
            .unwrap_or(24_i32),
    )
}

/// Ensure the singleton `frigate_config` row exists (idempotent). On first
/// creation it is SEEDED from the legacy `FRIGATE_*` env vars so an existing
/// deployment's broker config carries over; subsequently the DB row is
/// authoritative. Called at both API and recorder startup.
///
/// # Errors
///
/// Returns an error if the DDL/insert fails.
pub async fn ensure_frigate_config_table(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            CREATE TABLE IF NOT EXISTS frigate_config (
                id            smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
                enabled       boolean NOT NULL DEFAULT false,
                mqtt_url      text NOT NULL DEFAULT '',
                mqtt_prefix   text NOT NULL DEFAULT 'frigate',
                mqtt_user     text,
                mqtt_password text,
                api_base      text NOT NULL DEFAULT '',
                min_score     real NOT NULL DEFAULT 0.3,
                catchup_hours integer NOT NULL DEFAULT 24,
                version       bigint NOT NULL DEFAULT 1,
                updated_at    timestamptz NOT NULL DEFAULT now()
            );
            ",
        )
        .await
        .context("ensure_frigate_config_table: create")?;
    let (enabled, url, prefix, user, pass, api_base, min_score, catchup) = frigate_env_seed();
    client
        .execute(
            r"
            INSERT INTO frigate_config
                (id, enabled, mqtt_url, mqtt_prefix, mqtt_user, mqtt_password,
                 api_base, min_score, catchup_hours, version)
            VALUES (1, $1, $2, $3, $4, $5, $6, $7, $8, 1)
            ON CONFLICT (id) DO NOTHING
            ",
            &[
                &enabled, &url, &prefix, &user, &pass, &api_base, &min_score, &catchup,
            ],
        )
        .await
        .context("ensure_frigate_config_table: seed")?;
    Ok(())
}

/// Fetch the singleton Frigate settings (`None` only if the row is somehow absent).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn get_frigate_settings(pool: &Pool) -> Result<Option<FrigateSettings>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"SELECT enabled, mqtt_url, mqtt_prefix, mqtt_user, mqtt_password,
                     api_base, min_score, catchup_hours, version
              FROM frigate_config WHERE id = 1",
            &[],
        )
        .await
        .context("get_frigate_settings")?;
    Ok(opt.as_ref().map(frigate_settings_from_row))
}

/// Cheap version poll — what the recorder + API compare to decide whether to
/// reconnect. Returns 0 if the row is missing.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn frigate_config_version(pool: &Pool) -> Result<i64> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt("SELECT version FROM frigate_config WHERE id = 1", &[])
        .await
        .context("frigate_config_version")?;
    Ok(opt.map_or(0, |r| r.get("version")))
}

/// Update the singleton Frigate settings and BUMP `version` (so both processes
/// hot-reload). `mqtt_password = None` LEAVES the stored password unchanged
/// (write-only field); pass `Some("")` to clear it. Returns the new settings.
///
/// # Errors
///
/// Returns an error if the update fails.
#[allow(clippy::too_many_arguments)]
pub async fn update_frigate_settings(
    pool: &Pool,
    enabled: bool,
    mqtt_url: &str,
    mqtt_prefix: &str,
    mqtt_user: Option<&str>,
    mqtt_password: Option<&str>,
    api_base: &str,
    min_score: f32,
    catchup_hours: i32,
) -> Result<FrigateSettings> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            UPDATE frigate_config SET
                enabled       = $1,
                mqtt_url      = $2,
                mqtt_prefix   = $3,
                mqtt_user     = $4,
                mqtt_password = CASE WHEN $5::boolean THEN $6 ELSE mqtt_password END,
                api_base      = $7,
                min_score     = $8,
                catchup_hours = $9,
                version       = version + 1,
                updated_at    = now()
            WHERE id = 1
            RETURNING enabled, mqtt_url, mqtt_prefix, mqtt_user, mqtt_password,
                      api_base, min_score, catchup_hours, version
            ",
            &[
                &enabled,
                &mqtt_url,
                &mqtt_prefix,
                &mqtt_user,
                &mqtt_password.is_some(),
                &mqtt_password,
                &api_base,
                &min_score,
                &catchup_hours,
            ],
        )
        .await
        .context("update_frigate_settings")?;
    Ok(frigate_settings_from_row(&row))
}

// ─── Home Assistant: config singleton + per-camera entity links (0048) ────────

fn ha_settings_from_row(row: &tokio_postgres::Row) -> HaSettings {
    HaSettings {
        enabled: row.get("enabled"),
        base_url: row.get("base_url"),
        token: row.get("token"),
        version: row.get("version"),
    }
}

/// Read-time env fallback for the HA connection: `HA_BASE_URL` and
/// `HA_TOKEN` / `HA_TOKEN_FILE`. Applied only when the DB fields are empty (DB
/// wins), mirroring the config-precedence convention.
fn ha_env() -> (String, Option<String>) {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let base_url = env("HA_BASE_URL").unwrap_or_default();
    let token = env("HA_TOKEN").or_else(|| {
        env("HA_TOKEN_FILE").and_then(|p| {
            std::fs::read_to_string(p)
                .ok()
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
        })
    });
    (base_url, token)
}

/// Fetch the singleton HA settings with env fallback applied to empty fields
/// (DB wins). `None` only if the singleton row is somehow absent.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn get_ha_settings(pool: &Pool) -> Result<Option<HaSettings>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT enabled, base_url, token, version FROM ha_config WHERE id = 1",
            &[],
        )
        .await
        .context("get_ha_settings")?;
    Ok(opt.as_ref().map(|row| {
        let mut s = ha_settings_from_row(row);
        let (env_url, env_token) = ha_env();
        if s.base_url.trim().is_empty() {
            s.base_url = env_url;
        }
        if s.token.as_deref().is_none_or(|t| t.trim().is_empty()) {
            s.token = env_token;
        }
        s
    }))
}

/// Cheap version poll for hot-reload. Returns 0 if the row is missing.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn ha_config_version(pool: &Pool) -> Result<i64> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt("SELECT version FROM ha_config WHERE id = 1", &[])
        .await
        .context("ha_config_version")?;
    Ok(opt.map_or(0, |r| r.get("version")))
}

/// Update the singleton HA settings and BUMP `version`. `set_token = false`
/// LEAVES the stored token unchanged (write-only field); `set_token = true` with
/// `token = Some("")` clears it. The returned settings have env fallback applied.
///
/// # Errors
///
/// Returns an error if the update fails or the row is missing afterward.
pub async fn update_ha_settings(
    pool: &Pool,
    enabled: bool,
    base_url: &str,
    set_token: bool,
    token: Option<&str>,
) -> Result<HaSettings> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            UPDATE ha_config SET
                enabled    = $1,
                base_url   = $2,
                token      = CASE WHEN $3::boolean THEN $4 ELSE token END,
                version    = version + 1,
                updated_at = now()
            WHERE id = 1
            ",
            &[&enabled, &base_url, &set_token, &token],
        )
        .await
        .context("update_ha_settings")?;
    get_ha_settings(pool)
        .await?
        .ok_or_else(|| anyhow::anyhow!("ha_config row missing after update"))
}

fn ha_link_from_row(row: &tokio_postgres::Row) -> CameraHaLink {
    CameraHaLink {
        id: row.get("id"),
        camera_id: row.get("camera_id"),
        entity_id: row.get("entity_id"),
        role: row.get("role"),
        device_class: row.get("device_class"),
        label: row.get("label"),
        sort_order: row.get("sort_order"),
    }
}

/// All HA entity links for a camera, ordered for display.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_camera_ha_links(pool: &Pool, camera_id: Uuid) -> Result<Vec<CameraHaLink>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT id, camera_id, entity_id, role, device_class, label, sort_order
             FROM camera_ha_links WHERE camera_id = $1
             ORDER BY sort_order, entity_id",
            &[&camera_id],
        )
        .await
        .context("list_camera_ha_links")?;
    Ok(rows.iter().map(ha_link_from_row).collect())
}

/// Replace the full set of a camera's HA links (delete-then-insert in one
/// transaction) and bump `ha_config.version` so consumers hot-reload. Each input
/// link is `(entity_id, role, device_class, label, sort_order)`; `id` is
/// server-assigned.
///
/// # Errors
///
/// Returns an error if the transaction fails.
pub async fn replace_camera_ha_links(
    pool: &Pool,
    camera_id: Uuid,
    links: &[(String, String, Option<String>, Option<String>, i32)],
) -> Result<Vec<CameraHaLink>> {
    let mut client = get_conn(pool).await?;
    let tx = client
        .transaction()
        .await
        .context("replace_camera_ha_links: begin")?;
    tx.execute(
        "DELETE FROM camera_ha_links WHERE camera_id = $1",
        &[&camera_id],
    )
    .await
    .context("replace_camera_ha_links: delete")?;
    for (entity_id, role, device_class, label, sort_order) in links {
        tx.execute(
            "INSERT INTO camera_ha_links (camera_id, entity_id, role, device_class, label, sort_order)
             VALUES ($1, $2, $3, $4, $5, $6)",
            &[&camera_id, entity_id, role, device_class, label, sort_order],
        )
        .await
        .context("replace_camera_ha_links: insert")?;
    }
    tx.execute(
        "UPDATE ha_config SET version = version + 1 WHERE id = 1",
        &[],
    )
    .await
    .context("replace_camera_ha_links: bump version")?;
    tx.commit()
        .await
        .context("replace_camera_ha_links: commit")?;
    list_camera_ha_links(pool, camera_id).await
}

/// Repair a segment row's `size_bytes` to the actual on-disk byte length.
///
/// Called by the reconcile dangling pass (audit GAP 3 / P1 #8) when it finds a
/// present-but-truncated file whose on-disk length disagrees with the row's
/// stored `size_bytes` — otherwise the stale larger value lives forever, the
/// eviction math is wrong, and a short read serves truncated footage. Repairing
/// (rather than deleting) keeps the playable bytes indexed while correcting the
/// accounting.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn update_segment_size_bytes(
    pool: &Pool,
    segment_id: Uuid,
    size_bytes: i64,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE segments SET size_bytes = $2 WHERE id = $1",
            &[&segment_id, &size_bytes],
        )
        .await
        .context("update_segment_size_bytes")?;
    Ok(())
}

/// Delete a segment row from the index.
///
/// Must be called **after** the file has been successfully deleted from disk
/// (correctness item 10).  If the filesystem delete fails, do not call this.
pub async fn delete_segment_row(pool: &Pool, segment_id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute("DELETE FROM segments WHERE id = $1", &[&segment_id])
        .await
        .context("delete_segment_row")?;
    Ok(())
}

// ─── segments — queries ──────────────────────────────────────────────────────

/// Return live segments older than `older_than` for cameras that do **not**
/// have archive enabled.
///
/// Correctness item 7: archive-enabled cameras are excluded here so the
/// retention ticker never races with the archive job.
pub async fn list_live_segments_older_than(
    pool: &Pool,
    older_than: DateTime<Utc>,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT s.id, s.camera_id, s.storage_id, s.stage, s.path,
                   s.stream, s.start_ts, s.end_ts, s.duration_ms,
                   s.has_motion, s.size_bytes
            FROM segments s
            -- Resolve the EFFECTIVE policy (own → group → global default) via the
            -- canonical v_camera_effective_policy view (the same COALESCE join
            -- CAMERA_SELECT_SQL uses). A plain `JOIN … ON p.id = c.policy_id` would
            -- INNER-drop every camera that INHERITS (policy_id NULL), so the
            -- retention sweep would never delete that camera's expired live footage
            -- and its disk would fill unbounded. The view's one-row-per-camera
            -- invariant (one_group_per_camera unique index) means this join cannot
            -- duplicate segment rows.
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            WHERE s.stage = 'live'
              AND s.start_ts < $1
              AND v.p_archive_enabled = false
              AND NOT EXISTS (
                  SELECT 1 FROM bookmarks bk
                  WHERE bk.camera_id = s.camera_id
                    AND bk.protect_until > now()
                    AND bk.protect_start_ts <= s.end_ts
                    AND bk.protect_end_ts   >= s.start_ts
              )
            ORDER BY s.start_ts
            ",
            &[&older_than],
        )
        .await
        .context("list_live_segments_older_than")?;
    rows.iter().map(segment_from_row).collect()
}

/// Return live segments older than `older_than` for a specific camera that
/// *has* archive enabled.
///
/// Used by the archive job to select which segments to move.
pub async fn list_live_segments_for_archive(
    pool: &Pool,
    camera_id: Uuid,
    older_than: DateTime<Utc>,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
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
            ",
            &[&camera_id, &older_than],
        )
        .await
        .context("list_live_segments_for_archive")?;
    rows.iter().map(segment_from_row).collect()
}

/// Return archive segments older than `older_than` for a specific camera.
///
/// Used by the archive-retention sweep.
pub async fn list_archive_segments_older_than(
    pool: &Pool,
    camera_id: Uuid,
    older_than: DateTime<Utc>,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = $1
              AND stage = 'archive'
              AND start_ts < $2
              AND NOT EXISTS (
                  SELECT 1 FROM bookmarks bk
                  WHERE bk.camera_id = segments.camera_id
                    AND bk.protect_until > now()
                    AND bk.protect_start_ts <= segments.end_ts
                    AND bk.protect_end_ts   >= segments.start_ts
              )
            ORDER BY start_ts
            ",
            &[&camera_id, &older_than],
        )
        .await
        .context("list_archive_segments_older_than")?;
    rows.iter().map(segment_from_row).collect()
}

/// Total bytes of segments for one camera in a given stage (`live`|`archive`).
///
/// Mirrors [`storage_used_bytes`] but scoped to one camera + one stage. Used by
/// the recorder's size-eviction sweep to decide whether the camera's LIVE or
/// ARCHIVE footage is over its per-camera byte cap. The
/// `segments_camera_stage_start` index covers the `(camera_id, stage)` filter.
pub async fn camera_stage_bytes(pool: &Pool, camera_id: Uuid, stage: SegmentStage) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            "SELECT COALESCE(SUM(size_bytes), 0)::bigint AS used
               FROM segments WHERE camera_id = $1 AND stage = $2",
            &[&camera_id, &stage.as_str()],
        )
        .await
        .context("camera_stage_bytes")?;
    Ok(row.get("used"))
}

/// Return ALL of a camera's LIVE-stage segments, oldest-first (no time cutoff).
///
/// Used by the size-eviction sweep, which walks oldest→newest moving/deleting
/// segments until the camera's live total is back under its `live_max_bytes`
/// cap. Same SELECT shape as [`list_live_segments_for_archive`] minus the time
/// predicate.
pub async fn list_live_segments_oldest_first(pool: &Pool, camera_id: Uuid) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = $1
              AND stage = 'live'
              AND NOT EXISTS (
                  SELECT 1 FROM bookmarks bk
                  WHERE bk.camera_id = segments.camera_id
                    AND bk.protect_until > now()
                    AND bk.protect_start_ts <= segments.end_ts
                    AND bk.protect_end_ts   >= segments.start_ts
              )
            ORDER BY start_ts
            ",
            &[&camera_id],
        )
        .await
        .context("list_live_segments_oldest_first")?;
    rows.iter().map(segment_from_row).collect()
}

/// Return ALL of a camera's ARCHIVE-stage segments, oldest-first (no time
/// cutoff). Used by the size-eviction sweep to delete the oldest archived
/// segments until the archive total is back under `archive_max_bytes`.
pub async fn list_archive_segments_oldest_first(
    pool: &Pool,
    camera_id: Uuid,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = $1
              AND stage = 'archive'
              AND NOT EXISTS (
                  SELECT 1 FROM bookmarks bk
                  WHERE bk.camera_id = segments.camera_id
                    AND bk.protect_until > now()
                    AND bk.protect_start_ts <= segments.end_ts
                    AND bk.protect_end_ts   >= segments.start_ts
              )
            ORDER BY start_ts
            ",
            &[&camera_id],
        )
        .await
        .context("list_archive_segments_oldest_first")?;
    rows.iter().map(segment_from_row).collect()
}

// ─── segments — per-policy queries (size-cap eviction) ───────────────────────

/// Total bytes of segments belonging to cameras on a given effective policy, in
/// a given stage.
///
/// "Effective policy" is resolved the same way as [`CAMERA_SELECT_SQL`], via the
/// canonical `v_camera_effective_policy` view (own → group → default;
/// `COALESCE(c.policy_id, g.policy_id, (SELECT id FROM recording_policies
/// WHERE is_default LIMIT 1))`).  This is the companion of
/// [`camera_stage_bytes`] but scoped to an entire named policy so that
/// `live_max_bytes` / `archive_max_bytes` are treated as a shared budget across
/// every camera on that policy rather than a per-camera cap.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn policy_stage_bytes(pool: &Pool, policy_id: Uuid, stage: SegmentStage) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            SELECT COALESCE(SUM(s.size_bytes), 0)::bigint AS used
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            WHERE s.stage = $1
              AND v.p_id = $2
            ",
            &[&stage.as_str(), &policy_id],
        )
        .await
        .context("policy_stage_bytes")?;
    Ok(row.get("used"))
}

/// Return segments (for a given stage) belonging to cameras on a given effective
/// policy, ordered oldest-first by `start_ts`, optionally capped to the oldest
/// `limit` rows.
///
/// Used by the size-eviction sweep to walk the policy's oldest footage first
/// when the policy's total exceeds its byte cap.  The effective-policy
/// resolution is identical to [`CAMERA_SELECT_SQL`] and [`policy_stage_bytes`].
///
/// `limit`: pass `Some(n)` so the sweep only pulls the OLDEST `n`-row prefix it
/// can plausibly need this tick (the caller re-queries next tick if still over
/// cap). The audit observed this query returning 162k rows + an external-merge
/// disk sort every 60s; the `segments_stage_start` covering index (migration
/// 0009) plus this LIMIT turns it into a bounded ordered index scan. Pass `None`
/// only where the full set is genuinely required.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn list_policy_segments_oldest_first(
    pool: &Pool,
    policy_id: Uuid,
    stage: SegmentStage,
    limit: Option<i64>,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    // `$3::bigint IS NULL OR LIMIT $3` lets one prepared statement serve both
    // the capped and uncapped cases without string-building the SQL.
    let rows = client
        .query(
            r"
            SELECT s.id, s.camera_id, s.storage_id, s.stage, s.path,
                   s.stream, s.start_ts, s.end_ts, s.duration_ms,
                   s.has_motion, s.size_bytes
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            WHERE s.stage = $1
              AND v.p_id = $2
              AND NOT EXISTS (
                  SELECT 1 FROM bookmarks bk
                  WHERE bk.camera_id = s.camera_id
                    AND bk.protect_until > now()
                    AND bk.protect_start_ts <= s.end_ts
                    AND bk.protect_end_ts   >= s.start_ts
              )
            ORDER BY s.start_ts ASC
            LIMIT $3::bigint
            ",
            &[&stage.as_str(), &policy_id, &limit],
        )
        .await
        .context("list_policy_segments_oldest_first")?;
    rows.iter().map(segment_from_row).collect()
}

/// Like [`list_policy_segments_oldest_first`] but across BOTH stages
/// (`live` + `archive`), oldest-first.
///
/// Used by the size-eviction sweep for **archive-disabled** policies: when a
/// policy's archive tier is off, residual `stage=archive` footage shares the live
/// budget, so eviction must be able to reclaim the oldest footage regardless of
/// stage. Skips segments overlapping an active protected bookmark — the same
/// guard as the single-stage variant.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_policy_segments_oldest_first_any_stage(
    pool: &Pool,
    policy_id: Uuid,
    limit: Option<i64>,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT s.id, s.camera_id, s.storage_id, s.stage, s.path,
                   s.stream, s.start_ts, s.end_ts, s.duration_ms,
                   s.has_motion, s.size_bytes
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            WHERE s.stage IN ('live', 'archive')
              AND v.p_id = $1
              AND NOT EXISTS (
                  SELECT 1 FROM bookmarks bk
                  WHERE bk.camera_id = s.camera_id
                    AND bk.protect_until > now()
                    AND bk.protect_start_ts <= s.end_ts
                    AND bk.protect_end_ts   >= s.start_ts
              )
            ORDER BY s.start_ts ASC
            LIMIT $2::bigint
            ",
            &[&policy_id, &limit],
        )
        .await
        .context("list_policy_segments_oldest_first_any_stage")?;
    rows.iter().map(segment_from_row).collect()
}

/// Return segments (BOTH `live` + `archive` stages) for every camera whose
/// EFFECTIVE policy is `policy_id` that started before `older_than`, oldest-first.
///
/// Backs the recorder's **absolute maximum-retention** sweep
/// (`recording_policies.max_retention_days`): unlike the per-tier
/// live/archive retention sweeps — which are scoped to a single stage and, for
/// live, to `archive_enabled = false` cameras — the max-retention cap is a hard
/// ceiling that applies to ALL footage under the policy regardless of stage or
/// archiving. It therefore queries both stages and does NOT filter on
/// `archive_enabled`.
///
/// Skips segments overlapping an active protected bookmark — the SAME guard as
/// the other per-policy queries, so a human "protect from auto-delete" pin wins
/// over the automatic cap. `limit` bounds the per-tick batch (the sweep re-queries
/// next tick if more remain), mirroring [`list_policy_segments_oldest_first`].
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_policy_segments_older_than_any_stage(
    pool: &Pool,
    policy_id: Uuid,
    older_than: DateTime<Utc>,
    limit: Option<i64>,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT s.id, s.camera_id, s.storage_id, s.stage, s.path,
                   s.stream, s.start_ts, s.end_ts, s.duration_ms,
                   s.has_motion, s.size_bytes
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            WHERE s.stage IN ('live', 'archive')
              AND v.p_id = $1
              AND s.start_ts < $2
              AND NOT EXISTS (
                  SELECT 1 FROM bookmarks bk
                  WHERE bk.camera_id = s.camera_id
                    AND bk.protect_until > now()
                    AND bk.protect_start_ts <= s.end_ts
                    AND bk.protect_end_ts   >= s.start_ts
              )
            ORDER BY s.start_ts ASC
            LIMIT $3::bigint
            ",
            &[&policy_id, &older_than, &limit],
        )
        .await
        .context("list_policy_segments_older_than_any_stage")?;
    rows.iter().map(segment_from_row).collect()
}

/// Return all segment rows for a camera (both stages), used by the startup
/// reconciler to detect dangling rows (correctness item 9).
pub async fn list_all_segments_for_camera(pool: &Pool, camera_id: Uuid) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = $1
            ORDER BY start_ts
            ",
            &[&camera_id],
        )
        .await
        .context("list_all_segments_for_camera")?;
    rows.iter().map(segment_from_row).collect()
}

/// Return ALL segment rows across all cameras and stages.
///
/// Used during startup reconciliation to diff index vs filesystem
/// (correctness item 9).
///
/// **Prefer [`list_segments_after`] for the recorder boot load** — this loads
/// the whole table into one `Vec` and at the 1M-row target risks OOM-boot-loop
/// under the recorder's 4GiB cap (audit P2 #12). Retained for callers that
/// genuinely need the full set in memory (e.g. tooling) at small row counts.
pub async fn list_all_segments(pool: &Pool) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            ORDER BY id
            ",
            &[],
        )
        .await
        .context("list_all_segments")?;
    rows.iter().map(segment_from_row).collect()
}

/// Keyset-paginated segment scan for the reconcile boot load (audit P2 #12).
///
/// Returns up to `limit` rows whose `id` is strictly greater than `after`,
/// ordered by `id` (the PRIMARY KEY — a stable, indexed keyset cursor). Pass
/// `after = Uuid::nil()` for the first page, then the last returned row's `id`
/// for each subsequent page; stop when fewer than `limit` rows come back.
///
/// This replaces a single unbounded `ORDER BY start_ts` full-table load with a
/// bounded-RSS stream: the caller processes and DROPS each page before fetching
/// the next, so peak memory is `O(limit)` not `O(total rows)`. The global
/// `ORDER BY start_ts` the old load paid for was pointless — reconcile does a
/// set-membership diff, not an ordered walk — so keying on `id` is both cheaper
/// (PK index) and correct for pagination.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn list_segments_after(pool: &Pool, after: Uuid, limit: i64) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE id > $1
            ORDER BY id
            LIMIT $2
            ",
            &[&after, &limit],
        )
        .await
        .context("list_segments_after")?;
    rows.iter().map(segment_from_row).collect()
}

fn segment_from_row(row: &tokio_postgres::Row) -> Result<Segment> {
    let stage_str: String = row.get("stage");
    let stage = SegmentStage::from_str(&stage_str)
        .with_context(|| format!("unknown segment stage '{stage_str}'"))?;

    let stream_str: String = row.get("stream");
    let stream = SegmentStream::from_str(&stream_str)
        .with_context(|| format!("unknown segment stream '{stream_str}'"))?;

    // Motion bbox is only present in SELECTs that explicitly project the
    // motion_bbox_* columns (e.g. list_segments_for_range). For every other
    // segment read the columns are absent from the row, so try_get errors and we
    // leave the bbox None — keeping all existing SELECTs working unchanged.
    let motion_bbox = {
        let x = row
            .try_get::<_, Option<f32>>("motion_bbox_x")
            .ok()
            .flatten();
        let y = row
            .try_get::<_, Option<f32>>("motion_bbox_y")
            .ok()
            .flatten();
        let w = row
            .try_get::<_, Option<f32>>("motion_bbox_w")
            .ok()
            .flatten();
        let h = row
            .try_get::<_, Option<f32>>("motion_bbox_h")
            .ok()
            .flatten();
        match (x, y, w, h) {
            (Some(x), Some(y), Some(w), Some(h)) => Some([x, y, w, h]),
            _ => None,
        }
    };

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
        motion_bbox,
    })
}

// ─── cameras — additional API queries ────────────────────────────────────────

/// Return all cameras (enabled and disabled), each with its fully-joined policy.
///
/// Used by the config CRUD routes which must list every camera, not just active ones.
pub async fn list_cameras_all(pool: &Pool) -> Result<Vec<Camera>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(CAMERA_SELECT_SQL, &[])
        .await
        .context("list_cameras_all")?;
    rows.iter().map(camera_from_row).collect()
}

/// A cheap fingerprint (md5 hex) of all camera + recording-policy config a CLIENT
/// cares about: camera identity/streams + the effective recording policy.
///
/// Returned by `GET /status` as `config_version`. Clients poll `/status` already;
/// when this value changes they silently re-fetch the camera list and reconnect, so
/// a server-side edit (stream URL, mode, retention, enable/disable, drive, …)
/// propagates without a manual refresh. Computed entirely in SQL — no schema change,
/// no per-mutation bookkeeping; the cost is one md5 over the camera rows. An empty
/// fleet hashes to `""`.
pub async fn config_version(pool: &Pool) -> Result<String> {
    let client = get_conn(pool).await?;
    // Resolve each camera's EFFECTIVE policy (own → group's → default) the same
    // way [`CAMERA_SELECT_SQL`] does, and fold the camera→group assignment +
    // resolved policy id into the hash. This makes assigning a policy to a group —
    // or moving a camera between groups — change the hash, so connected clients
    // auto-refresh. Kept to ONE query (LEFT JOINs + a COALESCE), no schema change.
    let row = client
        .query_one(
            r"
            SELECT COALESCE(md5(string_agg(
                v.c_id::text || '~' || v.c_name || '~' || v.c_enabled::text || '~' ||
                COALESCE(v.c_main_url,'') || '~' || COALESCE(v.c_sub_url,'') || '~' || v.c_go2rtc_name || '~' ||
                COALESCE(v.c_group_id::text,'') || '~' || v.p_id::text || '~' ||
                v.p_mode || '~' || v.p_record_stream || '~' || v.p_live_retention_hours::text || '~' ||
                v.p_archive_enabled::text || '~' || COALESCE(v.p_archive_retention_hours::text,'') || '~' ||
                COALESCE(v.p_live_storage_id::text,'') || '~' || COALESCE(v.p_archive_storage_id::text,'') || '~' ||
                v.p_motion_sensitivity || '~' || COALESCE(v.p_motion_threshold::text,'')
            , '|' ORDER BY v.c_id)), '') AS version
            FROM v_camera_effective_policy v
            ",
            &[],
        )
        .await
        .context("config_version")?;
    Ok(row.get("version"))
}

/// Return the single default recording policy row (`is_default = true`).
///
/// There is exactly one such row (enforced by a partial unique index in the
/// migration).  Returns an error if none is found (schema inconsistency).
pub async fn get_default_policy(pool: &Pool) -> Result<RecordingPolicy> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            SELECT id, name, is_default, mode,
                   live_storage_id, live_retention_hours,
                   archive_enabled, archive_storage_id, archive_schedule,
                   archive_retention_hours,
                   live_max_bytes, archive_max_bytes,
                   live_min_free_pct, live_min_free_bytes, live_spill_low_water_bytes,
                   max_retention_days,
                   motion_pre_seconds, motion_post_seconds,
                   motion_sensitivity, motion_threshold,
                   motion_keyframes_only, record_stream,
                   record_audio
            FROM recording_policies
            WHERE is_default = true
            ",
            &[],
        )
        .await
        .context("get_default_policy: no default policy row found")?;
    policy_from_row(&row)
}

/// Return a recording policy by its UUID.
///
/// Returns `None` if no such row exists.
pub async fn get_policy(pool: &Pool, id: Uuid) -> Result<Option<RecordingPolicy>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"
            SELECT id, name, is_default, mode,
                   live_storage_id, live_retention_hours,
                   archive_enabled, archive_storage_id, archive_schedule,
                   archive_retention_hours,
                   live_max_bytes, archive_max_bytes,
                   live_min_free_pct, live_min_free_bytes, live_spill_low_water_bytes,
                   max_retention_days,
                   motion_pre_seconds, motion_post_seconds,
                   motion_sensitivity, motion_threshold,
                   motion_keyframes_only, record_stream,
                   record_audio
            FROM recording_policies
            WHERE id = $1
            ",
            &[&id],
        )
        .await
        .context("get_policy")?;
    opt.map(|r| policy_from_row(&r)).transpose()
}

fn policy_from_row(row: &tokio_postgres::Row) -> Result<RecordingPolicy> {
    let mode_str: String = row.get("mode");
    let mode = RecordingMode::from_str(&mode_str)
        .with_context(|| format!("unknown recording mode '{mode_str}'"))?;

    let sens_str: String = row.get("motion_sensitivity");
    let motion_sensitivity = MotionSensitivity::from_str(&sens_str)
        .with_context(|| format!("unknown motion sensitivity '{sens_str}'"))?;

    let stream_str: String = row.get("record_stream");
    let record_stream = RecordStream::from_str(&stream_str)
        .with_context(|| format!("unknown record stream '{stream_str}'"))?;

    Ok(RecordingPolicy {
        id: row.get("id"),
        name: row.get("name"),
        is_default: row.get("is_default"),
        mode,
        live_storage_id: row.get("live_storage_id"),
        live_retention_hours: row.get("live_retention_hours"),
        archive_enabled: row.get("archive_enabled"),
        archive_storage_id: row.get("archive_storage_id"),
        archive_schedule: row.get("archive_schedule"),
        archive_retention_hours: row.get("archive_retention_hours"),
        live_max_bytes: row.get("live_max_bytes"),
        archive_max_bytes: row.get("archive_max_bytes"),
        live_min_free_pct: row.get("live_min_free_pct"),
        live_min_free_bytes: row.get("live_min_free_bytes"),
        live_spill_low_water_bytes: row.get("live_spill_low_water_bytes"),
        max_retention_days: row.get("max_retention_days"),
        motion_pre_seconds: row.get("motion_pre_seconds"),
        motion_post_seconds: row.get("motion_post_seconds"),
        motion_sensitivity,
        motion_threshold: row.get("motion_threshold"),
        motion_keyframes_only: row.get("motion_keyframes_only"),
        record_stream,
        record_audio: row.get("record_audio"),
    })
}

/// List all storages.
pub async fn list_storages(pool: &Pool) -> Result<Vec<Storage>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT id, name, path, total_bytes, icon, created_at FROM storages ORDER BY name",
            &[],
        )
        .await
        .context("list_storages")?;
    Ok(rows.iter().map(storage_from_row).collect())
}

/// Create a new storage row.
///
/// Returns the created [`Storage`].  Errors on `name` uniqueness violation.
pub async fn create_storage(
    pool: &Pool,
    name: &str,
    path: &str,
    total_bytes: Option<i64>,
    icon: Option<&str>,
) -> Result<Storage> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO storages (name, path, total_bytes, icon)
            VALUES ($1, $2, $3, $4)
            RETURNING id, name, path, total_bytes, icon, created_at
            ",
            &[&name, &path, &total_bytes, &icon],
        )
        .await
        .context("create_storage")?;
    Ok(storage_from_row(&row))
}

/// Update a storage row (partial update — only non-`None` fields are written).
pub async fn update_storage(
    pool: &Pool,
    id: Uuid,
    name: Option<&str>,
    path: Option<&str>,
    total_bytes: Option<Option<i64>>,
    icon: Option<Option<&str>>,
) -> Result<Storage> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            UPDATE storages
            SET name        = COALESCE($2, name),
                path        = COALESCE($3, path),
                total_bytes = CASE WHEN $4 THEN $5 ELSE total_bytes END,
                icon        = CASE WHEN $6 THEN $7 ELSE icon END
            WHERE id = $1
            RETURNING id, name, path, total_bytes, icon, created_at
            ",
            &[
                &id,
                &name,
                &path,
                &total_bytes.is_some(),
                &total_bytes.unwrap_or(None),
                &icon.is_some(),
                &icon.unwrap_or(None),
            ],
        )
        .await
        .context("update_storage")?;
    Ok(storage_from_row(&row))
}

/// Delete a storage row by UUID.
///
/// Returns an error if the storage is referenced by cameras (FK constraint).
pub async fn delete_storage(pool: &Pool, id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute("DELETE FROM storages WHERE id = $1", &[&id])
        .await
        .context("delete_storage")?;
    Ok(())
}

/// Return total bytes used by segments currently on a specific storage.
pub async fn storage_used_bytes(pool: &Pool, storage_id: Uuid) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            "SELECT COALESCE(SUM(size_bytes), 0)::bigint AS used FROM segments WHERE storage_id = $1",
            &[&storage_id],
        )
        .await
        .context("storage_used_bytes")?;
    Ok(row.get("used"))
}

/// Per-camera storage + ingest statistics, computed from the `segments` index.
///
/// Returned by [`camera_storage_stats`]. One row per camera (including cameras
/// with zero recorded segments, in which case the byte/count fields are 0 and
/// the timestamp fields are `None`).
///
/// `recent_bytes` / `recent_span_secs` cover only the trailing 24-hour window so
/// callers can derive a live ingest rate (e.g. GB/hour) that reflects current
/// settings rather than the camera's whole history.
#[derive(Debug, Clone)]
pub struct CameraStorageStat {
    pub camera_id: Uuid,
    pub name: String,
    /// `SUM(size_bytes)` over all of the camera's segments.
    pub total_bytes: i64,
    /// `COUNT(*)` of the camera's segments.
    pub segment_count: i64,
    /// `MIN(start_ts)` over all segments, `None` when the camera has none.
    pub oldest_ts: Option<DateTime<Utc>>,
    /// `MAX(end_ts)` over all segments, `None` when the camera has none.
    pub newest_ts: Option<DateTime<Utc>>,
    /// `SUM(size_bytes)` over segments started within the last 24 hours.
    pub recent_bytes: i64,
    /// `MAX(end_ts) - MIN(start_ts)` (seconds) over that same 24-hour window;
    /// `0.0` when no segments fall in the window.
    pub recent_span_secs: f64,
    /// Latest sampled CPU usage (% of one core) of this camera's ffmpeg children,
    /// from `camera_resource_stats`. `0.0` when the recorder has never sampled the
    /// camera (LEFT JOIN miss). May be stale — `resource_updated_at` lets callers
    /// age it out.
    pub cpu_pct: f64,
    /// Latest sampled resident memory (MB) of this camera's ffmpeg children.
    /// `0.0` when never sampled.
    pub mem_mb: f64,
    /// Latest sampled GPU utilisation (%) attributed to this camera's motion
    /// decode, or `None` when GPU telemetry is unavailable (e.g. no `nvidia-smi`
    /// in the container) or the camera has never been sampled.
    pub gpu_pct: Option<f64>,
    /// When the resource sample was last written, or `None` when the camera has no
    /// `camera_resource_stats` row yet. Callers treat a stale (`> 60 s`) timestamp
    /// as "no live usage".
    pub resource_updated_at: Option<DateTime<Utc>>,
}

/// Per-camera storage + ingest statistics over the `segments` index.
///
/// One row per camera (`LEFT JOIN` so cameras with no segments are included
/// with zeroed sums and null timestamps), ordered by camera name.
///
/// A single grouped subquery aggregates `segments` by `camera_id`:
/// lifetime totals (`SUM(size_bytes)`, `COUNT(*)`, `MIN(start_ts)`,
/// `MAX(end_ts)`) plus a trailing-24h window (`recent_bytes` and the span
/// between the window's first `start_ts` and last `end_ts`). All sums/counts are
/// cast to `::bigint` so they read back as `i64`.
pub async fn camera_storage_stats(pool: &Pool) -> Result<Vec<CameraStorageStat>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT
                c.id   AS camera_id,
                c.name AS name,
                COALESCE(s.total_bytes, 0)::bigint    AS total_bytes,
                COALESCE(s.segment_count, 0)::bigint  AS segment_count,
                s.oldest_ts                           AS oldest_ts,
                s.newest_ts                           AS newest_ts,
                COALESCE(s.recent_bytes, 0)::bigint   AS recent_bytes,
                COALESCE(
                    EXTRACT(EPOCH FROM (s.recent_newest_ts - s.recent_oldest_ts)),
                    0
                )::double precision                   AS recent_span_secs,
                COALESCE(r.cpu_pct, 0)::double precision AS cpu_pct,
                COALESCE(r.mem_mb, 0)::double precision  AS mem_mb,
                r.gpu_pct                              AS gpu_pct,
                r.updated_at                           AS resource_updated_at
            FROM cameras c
            LEFT JOIN (
                SELECT
                    camera_id,
                    SUM(size_bytes)  AS total_bytes,
                    COUNT(*)         AS segment_count,
                    MIN(start_ts)    AS oldest_ts,
                    MAX(end_ts)      AS newest_ts,
                    SUM(size_bytes) FILTER (
                        WHERE start_ts >= now() - interval '24 hours'
                    )                AS recent_bytes,
                    MIN(start_ts) FILTER (
                        WHERE start_ts >= now() - interval '24 hours'
                    )                AS recent_oldest_ts,
                    MAX(end_ts) FILTER (
                        WHERE start_ts >= now() - interval '24 hours'
                    )                AS recent_newest_ts
                FROM segments
                GROUP BY camera_id
            ) s ON s.camera_id = c.id
            LEFT JOIN camera_resource_stats r ON r.camera_id = c.id
            ORDER BY c.name
            ",
            &[],
        )
        .await
        .context("camera_storage_stats")?;

    let stats = rows
        .iter()
        .map(|row| CameraStorageStat {
            camera_id: row.get("camera_id"),
            name: row.get("name"),
            total_bytes: row.get("total_bytes"),
            segment_count: row.get("segment_count"),
            oldest_ts: row.get("oldest_ts"),
            newest_ts: row.get("newest_ts"),
            recent_bytes: row.get("recent_bytes"),
            recent_span_secs: row.get("recent_span_secs"),
            cpu_pct: row.get("cpu_pct"),
            mem_mb: row.get("mem_mb"),
            gpu_pct: row.get("gpu_pct"),
            resource_updated_at: row.get("resource_updated_at"),
        })
        .collect();
    Ok(stats)
}

// ─── per-policy usage rollup (Recorder Health "Policy usage") ─────────────────

/// One row of per-effective-policy storage usage, computed over the `segments`
/// index joined to the canonical `v_camera_effective_policy` view — the SAME
/// `COALESCE(c.policy_id, g.policy_id, default)` effective-policy resolution that
/// [`policy_stage_bytes`] and the size-cap eviction sweep
/// use — so the displayed "used" matches what eviction actually enforces,
/// byte-for-byte. Live and archive are split because the budgets
/// (`live_max_bytes` / `archive_max_bytes`) are separate.
#[derive(Debug, Clone)]
pub struct PolicyUsageRollup {
    /// Effective policy id (a camera's own → its group's → the default).
    pub policy_id: Uuid,
    /// `SUM(size_bytes)` of LIVE-stage segments on this policy.
    pub live_used: i64,
    /// `SUM(size_bytes)` of ARCHIVE-stage segments on this policy.
    pub archive_used: i64,
    /// LIVE bytes recorded in the trailing 24h (for the ingest-rate forecast).
    pub recent_live_bytes: i64,
    /// Span (seconds) of that trailing-24h LIVE window; `0.0` when none.
    pub recent_live_span_secs: f64,
    /// Oldest LIVE `start_ts` on this policy (`None` when no live footage).
    pub live_oldest_ts: Option<DateTime<Utc>>,
    /// Newest LIVE `end_ts` on this policy (`None` when no live footage).
    pub live_newest_ts: Option<DateTime<Utc>>,
}

/// Roll up storage usage per EFFECTIVE recording policy in one grouped query.
///
/// Keyed on the effective-policy expression (own → group → default), so it
/// includes the anonymous per-camera COW forks that `list_policies` keeps but
/// `/config/policies` hides — exactly the buckets eviction enforces. Returns one
/// row per policy that currently has any segments; policies with none are absent
/// (the caller left-joins `list_policies` to show them at 0).
///
/// Note: this rolls up over ALL cameras, whereas the size-cap eviction sweep only
/// sweeps policies with ≥1 *enabled* camera. The byte SUMs are identical; the only
/// edge case is a policy whose cameras are all disabled but still holds footage —
/// it displays a size cap eviction is not actively enforcing (its zero recent
/// ingest makes the forecast bind on "none", so the shown bytes stay accurate).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn policy_usage_rollup(pool: &Pool) -> Result<Vec<PolicyUsageRollup>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT
                v.p_id AS policy_id,
                COALESCE(SUM(s.size_bytes) FILTER (WHERE s.stage = 'live'),    0)::bigint AS live_used,
                COALESCE(SUM(s.size_bytes) FILTER (WHERE s.stage = 'archive'), 0)::bigint AS archive_used,
                COALESCE(SUM(s.size_bytes) FILTER (
                    WHERE s.stage = 'live' AND s.start_ts >= now() - interval '24 hours'
                ), 0)::bigint AS recent_live_bytes,
                COALESCE(EXTRACT(EPOCH FROM (
                    MAX(s.end_ts)   FILTER (WHERE s.stage = 'live' AND s.start_ts >= now() - interval '24 hours')
                  - MIN(s.start_ts) FILTER (WHERE s.stage = 'live' AND s.start_ts >= now() - interval '24 hours')
                )), 0)::double precision AS recent_live_span_secs,
                MIN(s.start_ts) FILTER (WHERE s.stage = 'live') AS live_oldest_ts,
                MAX(s.end_ts)   FILTER (WHERE s.stage = 'live') AS live_newest_ts
            -- v_camera_effective_policy resolves the SAME own→group→default policy
            -- the inline COALESCE did; its p_id is the grouping key. Because the
            -- COALESCE always resolves to the guaranteed single default (or an
            -- existing own/group policy via FK), the view's inner recording_policies
            -- join drops no segments — byte SUMs are identical to the old form.
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            GROUP BY v.p_id
            ",
            &[],
        )
        .await
        .context("policy_usage_rollup")?;
    Ok(rows
        .iter()
        .map(|row| PolicyUsageRollup {
            policy_id: row.get("policy_id"),
            live_used: row.get("live_used"),
            archive_used: row.get("archive_used"),
            recent_live_bytes: row.get("recent_live_bytes"),
            recent_live_span_secs: row.get("recent_live_span_secs"),
            live_oldest_ts: row.get("live_oldest_ts"),
            live_newest_ts: row.get("live_newest_ts"),
        })
        .collect())
}

// ─── per-storage fill-rate + top-contributor queries (storage advisor) ──────────

/// Per-storage fill rate over a trailing time window.
///
/// Used by `GET /stats/storage` to compute 24h and 7d ingest rates per storage
/// device. A single aggregate query grouped by `storage_id` avoids the N+1 that
/// would arise from calling [`storage_used_bytes`] once per storage + window.
///
/// Returns one row per storage that received at least one segment in the window;
/// storages with no recent data are simply absent (the caller treats them as zero).
#[derive(Debug, Clone)]
pub struct StorageFillRateStat {
    /// The storage device the segments live on.
    pub storage_id: Uuid,
    /// `SUM(size_bytes)` of segments whose `start_ts` falls in the window.
    pub window_bytes: i64,
    /// Wall-clock width of the window in seconds (always the constant passed in,
    /// returned so callers don't have to track the conversion themselves).
    pub window_secs: f64,
}

/// Fill-rate aggregate over a single trailing window (24h or 7d) grouped by storage.
///
/// `window_hours` is the look-back horizon in hours.  Returns one row per storage
/// that recorded any segments in that window.  The `segments(storage_id, start_ts)`
/// index (created by [`ensure_segments_storage_index`]) makes the range scan cheap
/// even on large tables.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn storage_fill_rate_stats(
    pool: &Pool,
    window_hours: i64,
) -> Result<Vec<StorageFillRateStat>> {
    let client = get_conn(pool).await?;
    // Use a parameterised interval so one prepared statement covers both the 24h
    // and 7d call.  The `storage_id` GROUP BY uses the index prefix directly.
    let rows = client
        .query(
            r"
            SELECT
                storage_id,
                COALESCE(SUM(size_bytes), 0)::bigint AS window_bytes,
                EXTRACT(EPOCH FROM ($1::bigint * interval '1 hour'))::double precision AS window_secs
            FROM segments
            WHERE start_ts >= now() - ($1::bigint * interval '1 hour')
            GROUP BY storage_id
            ",
            &[&window_hours],
        )
        .await
        .context("storage_fill_rate_stats")?;
    Ok(rows
        .iter()
        .map(|row| StorageFillRateStat {
            storage_id: row.get("storage_id"),
            window_bytes: row.get("window_bytes"),
            window_secs: row.get("window_secs"),
        })
        .collect())
}

// ─── per-camera recent segment rate (motion-cache ring projection) ───────────

/// One Motion-mode camera's observed segment rate over a recent trailing
/// window — the raw ingredients for the API's motion-cache ring projection
/// (`GET /config/motion-cache-status`). Averaging over a real window (rather
/// than reading the policy's nominal `SEGMENT_SECONDS` config) captures the
/// camera's ACTUAL bitrate, which is what the RAM ring really has to hold.
#[derive(Debug, Clone)]
pub struct CameraSegmentRateStat {
    pub camera_id: Uuid,
    /// `AVG(size_bytes)` over the window's live segments.
    pub avg_size_bytes: f64,
    /// `AVG(duration_ms) / 1000.0` over the window's live segments.
    pub avg_duration_secs: f64,
    /// Number of segments the averages were computed over — callers should
    /// treat a very small sample as unreliable (see the projection function).
    pub sample_count: i64,
}

/// Average segment size + duration for every camera with at least one `live`
/// segment in the last `window_hours` — used to derive observed bytes/sec per
/// camera for the motion-cache ring projection. Cameras with no recent live
/// segments are simply absent (the caller treats them as "no estimate yet").
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn camera_recent_segment_rate_stats(
    pool: &Pool,
    window_hours: i64,
) -> Result<Vec<CameraSegmentRateStat>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT
                camera_id,
                AVG(size_bytes)::double precision       AS avg_size_bytes,
                AVG(duration_ms)::double precision / 1000.0 AS avg_duration_secs,
                COUNT(*)::bigint                         AS sample_count
            FROM segments
            WHERE stage = 'live'
              AND start_ts >= now() - ($1::bigint * interval '1 hour')
            GROUP BY camera_id
            ",
            &[&window_hours],
        )
        .await
        .context("camera_recent_segment_rate_stats")?;
    Ok(rows
        .iter()
        .map(|row| CameraSegmentRateStat {
            camera_id: row.get("camera_id"),
            avg_size_bytes: row.get("avg_size_bytes"),
            avg_duration_secs: row.get("avg_duration_secs"),
            sample_count: row.get("sample_count"),
        })
        .collect())
}

/// One camera's contribution to a storage device's fill rate over the last 7 days.
///
/// Returned by [`storage_top_contributors`]; up to 5 per storage, sorted by
/// descending `bytes_per_day`.
#[derive(Debug, Clone)]
pub struct StorageContributor {
    pub storage_id: Uuid,
    pub camera_name: String,
    /// `SUM(size_bytes) / 7.0` over segments on this storage in the last 7 days,
    /// in bytes/day.  Rounded at the application layer if needed.
    pub bytes_per_day: f64,
    /// Dominant stream for this camera on this storage (`main` / `sub`).
    /// Derived from the stream that accounts for the most bytes.
    pub stream: String,
    /// Recording mode of the camera's effective policy (`continuous` / `motion`).
    pub mode: String,
}

/// One (storage, effective-policy) usage slice — total DB-tracked bytes that the
/// cameras of a given effective recording policy currently occupy on a given
/// storage device.  Drives the stacked-by-profile utilization bar in the storage
/// advisor (each profile = one coloured segment of the drive's used space).
#[derive(Debug, Clone)]
pub struct StoragePolicyUsage {
    pub storage_id: Uuid,
    pub policy_id: Uuid,
    /// Sum of `size_bytes` (all stages, all time) for this policy's cameras on
    /// this storage — i.e. the bytes Crumb is currently tracking on disk.
    pub bytes: i64,
}

/// Per-storage, per-effective-policy on-disk byte totals.
///
/// Mirrors the own→group→default resolution of [`policy_usage_rollup`] but keeps
/// the `storage_id` group key so the storage advisor can break a single drive's
/// used space into one segment per recording profile (the remainder up to the
/// filesystem's used bytes is "other / untracked" — footage Crumb didn't write).
/// One aggregate query, O(1) round-trips.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn storage_usage_by_policy(pool: &Pool) -> Result<Vec<StoragePolicyUsage>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT
                s.storage_id          AS storage_id,
                v.p_id                AS policy_id,
                SUM(s.size_bytes)::bigint AS bytes
            FROM segments s
            JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
            GROUP BY s.storage_id, v.p_id
            ",
            &[],
        )
        .await
        .context("storage_usage_by_policy")?;
    Ok(rows
        .iter()
        .map(|row| StoragePolicyUsage {
            storage_id: row.get("storage_id"),
            policy_id: row.get("policy_id"),
            bytes: row.get("bytes"),
        })
        .collect())
}

/// Top-5 cameras by bytes/day per storage device over the last 7 days.
///
/// Uses a single query (one `JOIN` + `GROUP BY storage_id, camera_id, stream`
/// with a `ROW_NUMBER()` window) so the number of round-trips is O(1) regardless
/// of how many storages or cameras exist.  The `segments(storage_id, start_ts)`
/// index covers the filter; the additional `camera_id` group-key hit uses the
/// `segments_camera_stage_start` covering index if available.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn storage_top_contributors(pool: &Pool) -> Result<Vec<StorageContributor>> {
    let client = get_conn(pool).await?;
    // Rank camera-stream pairs per storage by bytes/day, then keep only rank ≤ 5.
    // The effective-policy COALESCE mirrors CAMERA_SELECT_SQL so the mode reflects
    // what the recorder is actually using, not just the policy row c.policy_id
    // directly references (which may be NULL for group/default-inheriting cameras).
    let rows = client
        .query(
            r"
            WITH ranked AS (
                SELECT
                    s.storage_id,
                    v.c_name                            AS camera_name,
                    s.stream,
                    COALESCE(v.p_mode, 'continuous')    AS mode,
                    SUM(s.size_bytes)::double precision / 7.0 AS bytes_per_day,
                    ROW_NUMBER() OVER (
                        PARTITION BY s.storage_id
                        ORDER BY SUM(s.size_bytes) DESC
                    ) AS rn
                -- Effective recording mode via v_camera_effective_policy (same
                -- own→group→default COALESCE as CAMERA_SELECT_SQL). The guaranteed
                -- single default means the view resolves a policy for every camera,
                -- so the COALESCE(...,'continuous') fallback is defensive only — no
                -- camera is dropped vs the old LEFT JOIN form.
                FROM segments s
                JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
                WHERE s.start_ts >= now() - interval '7 days'
                GROUP BY s.storage_id, v.c_name, s.stream, v.p_mode
            )
            SELECT storage_id, camera_name, stream, mode, bytes_per_day
            FROM ranked
            WHERE rn <= 5
            ORDER BY storage_id, bytes_per_day DESC
            ",
            &[],
        )
        .await
        .context("storage_top_contributors")?;
    Ok(rows
        .iter()
        .map(|row| StorageContributor {
            storage_id: row.get("storage_id"),
            camera_name: row.get("camera_name"),
            stream: row.get("stream"),
            mode: row.get("mode"),
            bytes_per_day: row.get("bytes_per_day"),
        })
        .collect())
}

/// Map every camera to its EFFECTIVE policy id (own → group → default), with the
/// camera's display name. Same COALESCE resolution as [`policy_usage_rollup`] but
/// without the segment join — used to attach camera_count / camera_names to each
/// policy bucket (and to label anonymous single-owner forks). Returns
/// `(policy_id, camera_id, camera_name)`, ordered by camera name.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn cameras_by_effective_policy(pool: &Pool) -> Result<Vec<(Uuid, Uuid, String)>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT
                v.p_id   AS policy_id,
                v.c_id   AS camera_id,
                v.c_name AS name
            FROM v_camera_effective_policy v
            ORDER BY v.c_name
            ",
            &[],
        )
        .await
        .context("cameras_by_effective_policy")?;
    Ok(rows
        .iter()
        .map(|row| {
            (
                row.get::<_, Uuid>("policy_id"),
                row.get::<_, Uuid>("camera_id"),
                row.get::<_, String>("name"),
            )
        })
        .collect())
}

// ─── cameras — CRUD for config routes ────────────────────────────────────────

/// Parameters for creating a new camera row.
///
/// The caller is responsible for inserting a cloned policy row first, then
/// passing its UUID here.
#[derive(Debug)]
pub struct CreateCameraParams<'a> {
    pub name: &'a str,
    pub go2rtc_name: &'a str,
    pub main_url: &'a str,
    pub sub_url: Option<&'a str>,
    /// Raw camera RTSP source (the go2rtc producer) for Crumb-managed cameras.
    pub source_url: Option<&'a str>,
    pub source_sub_url: Option<&'a str>,
    pub enabled: bool,
    pub policy_id: Uuid,
    pub motion_mask: Option<&'a serde_json::Value>,
    pub onvif_motion: bool,
    /// Canonical motion source (`"pixel"` / `"frigate"`).
    pub motion_source: &'a str,
    /// Canonical motion algorithm (census / framediff / mog2 / opticalflow / ensemble).
    pub motion_algorithm: &'a str,
    /// Camera form-factor for the console glyph (`ptz`/`dome`/`bullet`/`lpr`/`other`),
    /// or `None` to leave it unset (rendered as the generic icon).
    pub camera_type: Option<&'a str>,
    /// Optional explicit glyph-key override (`cam_*`); `None` derives from `camera_type`.
    pub icon: Option<&'a str>,
    // ── fields added by migration 0012 ────────────────────────────────────────
    /// Which restreamer owns this camera: `"crumb"` (default) or `"frigate"`.
    pub served_by: &'a str,
    /// External detection-provider camera name for event mapping (nullable).
    pub source_camera_name: Option<&'a str>,
    /// ONVIF host for PTZ commands (nullable).
    pub onvif_host: Option<&'a str>,
    /// ONVIF port (nullable; default 80 at the application layer).
    pub onvif_port: Option<i32>,
    /// ONVIF authentication username (nullable).
    pub onvif_user: Option<&'a str>,
    /// ONVIF authentication password (nullable; never returned by the API).
    pub onvif_password: Option<&'a str>,
}

/// Insert a new camera row and return the full `Camera` (with joined policy).
pub async fn create_camera(pool: &Pool, p: &CreateCameraParams<'_>) -> Result<Camera> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO cameras
                (name, enabled, go2rtc_name, main_url, sub_url,
                 source_url, source_sub_url,
                 policy_id, motion_mask, onvif_motion,
                 motion_source, motion_algorithm, camera_type, icon,
                 served_by, source_camera_name,
                 onvif_host, onvif_port, onvif_user, onvif_password)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
                    $15, $16, $17, $18, $19, $20)
            RETURNING id
            ",
            &[
                &p.name,
                &p.enabled,
                &p.go2rtc_name,
                &p.main_url,
                &p.sub_url,
                &p.source_url,
                &p.source_sub_url,
                &p.policy_id,
                &p.motion_mask,
                &p.onvif_motion,
                &p.motion_source,
                &p.motion_algorithm,
                &p.camera_type,
                &p.icon,
                &p.served_by,
                &p.source_camera_name,
                &p.onvif_host,
                &p.onvif_port,
                &p.onvif_user,
                &p.onvif_password,
            ],
        )
        .await
        .context("create_camera")?;
    let id: Uuid = row.get(0);
    get_camera(pool, id)
        .await?
        .context("create_camera: row missing after insert")
}

/// A Crumb-managed camera's go2rtc stream definition: the go2rtc stream name and
/// its raw RTSP producer source(s). Returned only for cameras with a `source_url`
/// (i.e. ones whose go2rtc config the API owns).
#[derive(Debug, Clone)]
pub struct CameraStream {
    pub go2rtc_name: String,
    pub source_url: String,
    pub source_sub_url: Option<String>,
}

/// List the go2rtc stream definitions for all Crumb-managed cameras (those with a
/// `source_url`). Used by the API to render `go2rtc.yaml` + sync go2rtc.
pub async fn list_camera_streams(pool: &Pool) -> Result<Vec<CameraStream>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT go2rtc_name, source_url, source_sub_url
             FROM cameras
             WHERE source_url IS NOT NULL AND source_url <> ''
             ORDER BY go2rtc_name",
            &[],
        )
        .await
        .context("list_camera_streams")?;
    Ok(rows
        .iter()
        .map(|r| CameraStream {
            go2rtc_name: r.get("go2rtc_name"),
            source_url: r.get("source_url"),
            source_sub_url: r.get("source_sub_url"),
        })
        .collect())
}

/// Idempotently add the raw-source columns the self-service camera flow needs.
/// `source_url`/`source_sub_url` hold the actual camera RTSP (the go2rtc producer
/// source); `main_url`/`sub_url` stay the recorder-facing go2rtc re-stream URLs.
/// Safe to run on every startup.
pub async fn ensure_camera_source_columns(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            "ALTER TABLE cameras ADD COLUMN IF NOT EXISTS source_url text;
             ALTER TABLE cameras ADD COLUMN IF NOT EXISTS source_sub_url text;",
        )
        .await
        .context("ensure_camera_source_columns")?;
    Ok(())
}

/// Delete a camera row (cascades to its policy row and segments via FK CASCADE).
pub async fn delete_camera(pool: &Pool, id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute("DELETE FROM cameras WHERE id = $1", &[&id])
        .await
        .context("delete_camera")?;
    Ok(())
}

/// Clone the default recording policy into a new row and return its UUID.
///
/// Used by `create_camera` to give each camera its own policy row.
pub async fn clone_default_policy(pool: &Pool) -> Result<Uuid> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO recording_policies (
                is_default, mode,
                live_storage_id, live_retention_hours,
                archive_enabled, archive_storage_id, archive_schedule,
                archive_retention_hours,
                live_max_bytes, archive_max_bytes,
                live_min_free_pct, live_min_free_bytes, live_spill_low_water_bytes,
                max_retention_days,
                motion_pre_seconds, motion_post_seconds,
                motion_sensitivity, motion_threshold,
                motion_keyframes_only, record_stream,
                record_audio
            )
            SELECT
                false, mode,
                live_storage_id, live_retention_hours,
                archive_enabled, archive_storage_id, archive_schedule,
                archive_retention_hours,
                live_max_bytes, archive_max_bytes,
                live_min_free_pct, live_min_free_bytes, live_spill_low_water_bytes,
                max_retention_days,
                motion_pre_seconds, motion_post_seconds,
                motion_sensitivity, motion_threshold,
                motion_keyframes_only, record_stream,
                record_audio
            FROM recording_policies
            WHERE is_default = true
            RETURNING id
            ",
            &[],
        )
        .await
        .context("clone_default_policy")?;
    Ok(row.get(0))
}

/// Clone an ARBITRARY recording policy (by id) into a new `is_default = false`
/// row and return its UUID.
///
/// Used for copy-on-write when a camera that currently shares a policy (e.g. the
/// default) gets a per-camera edit: we fork the policy so other cameras are
/// untouched.  Copies the full current column set (incl. `record_audio` and the
/// `live_max_bytes`/`archive_max_bytes` size caps). The fork deliberately leaves
/// `name` NULL (= an anonymous per-camera "custom" policy, not a reusable named
/// one) — a past bug forgot to copy newly-added columns, so verify this SELECT
/// lists EVERY policy column except `id`/`name` whenever the schema grows.
pub async fn clone_policy(pool: &Pool, src_id: Uuid) -> Result<Uuid> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO recording_policies (
                is_default, mode,
                live_storage_id, live_retention_hours,
                archive_enabled, archive_storage_id, archive_schedule,
                archive_retention_hours,
                live_max_bytes, archive_max_bytes,
                live_min_free_pct, live_min_free_bytes, live_spill_low_water_bytes,
                max_retention_days,
                motion_pre_seconds, motion_post_seconds,
                motion_sensitivity, motion_threshold,
                motion_keyframes_only, record_stream,
                record_audio
            )
            SELECT
                false, mode,
                live_storage_id, live_retention_hours,
                archive_enabled, archive_storage_id, archive_schedule,
                archive_retention_hours,
                live_max_bytes, archive_max_bytes,
                live_min_free_pct, live_min_free_bytes, live_spill_low_water_bytes,
                max_retention_days,
                motion_pre_seconds, motion_post_seconds,
                motion_sensitivity, motion_threshold,
                motion_keyframes_only, record_stream,
                record_audio
            FROM recording_policies
            WHERE id = $1
            RETURNING id
            ",
            &[&src_id],
        )
        .await
        .context("clone_policy")?;
    Ok(row.get(0))
}

/// Reap orphaned anonymous per-camera copy-on-write policy forks.
///
/// A COW fork ([`clone_policy`]) is an `is_default = false`, `name IS NULL` row
/// owned by exactly one camera. When that camera is deleted (its `segments`
/// cascade but the fork is intentionally left behind) or repointed at another
/// policy, the fork becomes unreferenced. This deletes every such row that NO
/// camera and NO group still references — named policies and the default are never
/// touched (both fail the `name IS NULL` / `is_default = false` guard). Idempotent;
/// returns the number of forks reaped. This is the "separate vacuum" the
/// config-routes COW design refers to (run periodically by the recorder).
pub async fn reap_orphan_policy_forks(pool: &Pool) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = client
        .execute(
            r"
            DELETE FROM recording_policies p
            WHERE p.is_default = false
              AND p.name IS NULL
              AND NOT EXISTS (SELECT 1 FROM cameras c       WHERE c.policy_id = p.id)
              AND NOT EXISTS (SELECT 1 FROM camera_groups g WHERE g.policy_id = p.id)
            ",
            &[],
        )
        .await
        .context("reap_orphan_policy_forks")?;
    Ok(n)
}

/// Count how many cameras currently reference `policy_id`.
///
/// Used to decide whether a camera exclusively owns its policy (count == 1) or
/// shares it (count > 1, or it's the default) before a per-camera edit.
pub async fn count_cameras_for_policy(pool: &Pool, policy_id: Uuid) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            "SELECT COUNT(*)::bigint AS cnt FROM cameras WHERE policy_id = $1",
            &[&policy_id],
        )
        .await
        .context("count_cameras_for_policy")?;
    Ok(row.get("cnt"))
}

/// Repoint a camera at a different recording policy row.
pub async fn set_camera_policy_id(pool: &Pool, camera_id: Uuid, policy_id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE cameras SET policy_id = $2 WHERE id = $1",
            &[&camera_id, &policy_id],
        )
        .await
        .context("set_camera_policy_id")?;
    Ok(())
}

/// True if the camera currently belongs to a group (has a membership row).
///
/// Phase 3: a grouped camera is authoritatively governed by its group's profile
/// and may not hold a direct per-camera policy or copy-on-write fork. The
/// `one_group_per_camera` unique index means at most one membership row exists,
/// so `EXISTS` is exact.
pub async fn is_camera_grouped(pool: &Pool, camera_id: Uuid) -> Result<bool> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            "SELECT EXISTS (SELECT 1 FROM camera_group_members WHERE camera_id = $1)",
            &[&camera_id],
        )
        .await
        .context("is_camera_grouped")?;
    Ok(row.get(0))
}

/// Return the name of the group a camera belongs to, or `None` if ungrouped.
///
/// Phase 3: used to build a clear rejection message ("camera is in group NAME …")
/// when a direct/custom policy assignment is attempted on a grouped camera.
pub async fn camera_group_name(pool: &Pool, camera_id: Uuid) -> Result<Option<String>> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT g.name FROM camera_group_members m \
             JOIN camera_groups g ON g.id = m.group_id \
             WHERE m.camera_id = $1",
            &[&camera_id],
        )
        .await
        .context("camera_group_name")?;
    Ok(row.map(|r| r.get(0)))
}

/// Set (or clear) a camera's OWN direct recording policy.
///
/// `Some(id)` pins the camera to a named policy; `None` clears `policy_id` so the
/// camera INHERITS (its group's policy, else the global default). The effective
/// policy is resolved by the `COALESCE` join in [`CAMERA_SELECT_SQL`].
pub async fn set_camera_policy(
    pool: &Pool,
    camera_id: Uuid,
    policy_id: Option<Uuid>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE cameras SET policy_id = $2 WHERE id = $1",
            &[&camera_id, &policy_id],
        )
        .await
        .context("set_camera_policy")?;
    Ok(())
}

// ─── named recording policies (CRUD) ──────────────────────────────────────────

/// All policy columns except `id` — the canonical column list for SELECTs and
/// the basis for clones/inserts. Keep in sync with [`policy_from_row`].
const POLICY_COLUMNS: &str = r"
    id, name, is_default, mode,
    live_storage_id, live_retention_hours,
    archive_enabled, archive_storage_id, archive_schedule,
    archive_retention_hours,
    live_max_bytes, archive_max_bytes,
    live_min_free_pct, live_min_free_bytes, live_spill_low_water_bytes,
    max_retention_days,
    motion_pre_seconds, motion_post_seconds,
    motion_sensitivity, motion_threshold,
    motion_keyframes_only, record_stream,
    record_audio
";

/// List every recording policy (named and anonymous), default first then by name.
///
/// Returns ALL rows including anonymous per-camera copy-on-write forks
/// (`name = NULL`). The API typically filters to named ones for the "pick a
/// policy" UI; the recorder/admin may want the full set.
pub async fn list_policies(pool: &Pool) -> Result<Vec<RecordingPolicy>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            &format!(
                "SELECT {POLICY_COLUMNS} FROM recording_policies \
                 ORDER BY is_default DESC, name NULLS LAST, id"
            ),
            &[],
        )
        .await
        .context("list_policies")?;
    rows.iter().map(policy_from_row).collect()
}

/// Field values for creating or fully replacing a named policy row.
///
/// All recording knobs are explicit (no partial-merge) — the API resolves
/// patch-over-existing before calling. `is_default` is intentionally absent:
/// callers never create a second default (the partial unique index forbids it).
#[derive(Debug)]
pub struct PolicyFields<'a> {
    pub name: Option<&'a str>,
    pub mode: &'a str,
    pub live_storage_id: Option<Uuid>,
    pub live_retention_hours: i32,
    pub archive_enabled: bool,
    pub archive_storage_id: Option<Uuid>,
    pub archive_schedule: Option<&'a str>,
    pub archive_retention_hours: Option<i32>,
    pub live_max_bytes: Option<i64>,
    pub archive_max_bytes: Option<i64>,
    pub live_min_free_pct: Option<f32>,
    pub live_min_free_bytes: Option<i64>,
    pub live_spill_low_water_bytes: Option<i64>,
    pub max_retention_days: Option<i32>,
    pub motion_pre_seconds: i32,
    pub motion_post_seconds: i32,
    pub motion_sensitivity: &'a str,
    pub motion_threshold: Option<f32>,
    pub motion_keyframes_only: bool,
    pub record_stream: &'a str,
    pub record_audio: bool,
}

/// Create a new **named** (non-default) recording policy and return it.
pub async fn create_policy(pool: &Pool, f: &PolicyFields<'_>) -> Result<RecordingPolicy> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            &format!(
                r"
                INSERT INTO recording_policies (
                    name, is_default, mode,
                    live_storage_id, live_retention_hours,
                    archive_enabled, archive_storage_id, archive_schedule,
                    archive_retention_hours,
                    live_max_bytes, archive_max_bytes,
                    live_min_free_pct, live_min_free_bytes, live_spill_low_water_bytes,
                    motion_pre_seconds, motion_post_seconds,
                    motion_sensitivity, motion_threshold,
                    motion_keyframes_only, record_stream,
                    record_audio,
                    -- Appended (not grouped with the other storage knobs) so the
                    -- positional placeholders below need no renumbering.
                    max_retention_days
                )
                VALUES ($1, false, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                        $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21)
                RETURNING {POLICY_COLUMNS}
                "
            ),
            &[
                &f.name,
                &f.mode,
                &f.live_storage_id,
                &f.live_retention_hours,
                &f.archive_enabled,
                &f.archive_storage_id,
                &f.archive_schedule,
                &f.archive_retention_hours,
                &f.live_max_bytes,
                &f.archive_max_bytes,
                &f.live_min_free_pct,
                &f.live_min_free_bytes,
                &f.live_spill_low_water_bytes,
                &f.motion_pre_seconds,
                &f.motion_post_seconds,
                &f.motion_sensitivity,
                &f.motion_threshold,
                &f.motion_keyframes_only,
                &f.record_stream,
                &f.record_audio,
                &f.max_retention_days,
            ],
        )
        .await
        .context("create_policy")?;
    policy_from_row(&row)
}

/// Fully update a recording policy row's fields (does NOT touch `is_default`),
/// returning the updated row. Returns `None` if no such policy exists.
pub async fn update_policy(
    pool: &Pool,
    id: Uuid,
    f: &PolicyFields<'_>,
) -> Result<Option<RecordingPolicy>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            &format!(
                r"
                UPDATE recording_policies SET
                    name                       = $2,
                    mode                       = $3,
                    live_storage_id            = $4,
                    live_retention_hours       = $5,
                    archive_enabled            = $6,
                    archive_storage_id         = $7,
                    archive_schedule           = $8,
                    archive_retention_hours    = $9,
                    live_max_bytes             = $10,
                    archive_max_bytes          = $11,
                    live_min_free_pct          = $12,
                    live_min_free_bytes        = $13,
                    live_spill_low_water_bytes = $14,
                    motion_pre_seconds         = $15,
                    motion_post_seconds        = $16,
                    motion_sensitivity         = $17,
                    motion_threshold           = $18,
                    motion_keyframes_only      = $19,
                    record_stream              = $20,
                    record_audio               = $21,
                    max_retention_days         = $22
                WHERE id = $1
                RETURNING {POLICY_COLUMNS}
                "
            ),
            &[
                &id,
                &f.name,
                &f.mode,
                &f.live_storage_id,
                &f.live_retention_hours,
                &f.archive_enabled,
                &f.archive_storage_id,
                &f.archive_schedule,
                &f.archive_retention_hours,
                &f.live_max_bytes,
                &f.archive_max_bytes,
                &f.live_min_free_pct,
                &f.live_min_free_bytes,
                &f.live_spill_low_water_bytes,
                &f.motion_pre_seconds,
                &f.motion_post_seconds,
                &f.motion_sensitivity,
                &f.motion_threshold,
                &f.motion_keyframes_only,
                &f.record_stream,
                &f.record_audio,
                &f.max_retention_days,
            ],
        )
        .await
        .context("update_policy")?;
    opt.map(|r| policy_from_row(&r)).transpose()
}

/// How many cameras + groups directly reference a policy (excludes inheritance).
///
/// Used to refuse deleting a policy that is still in use. Counts cameras whose
/// own `policy_id` is this policy and groups whose `policy_id` is this policy.
pub async fn count_policy_references(pool: &Pool, policy_id: Uuid) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            SELECT
                (SELECT COUNT(*) FROM cameras       WHERE policy_id = $1)
              + (SELECT COUNT(*) FROM camera_groups WHERE policy_id = $1)
              AS cnt
            ",
            &[&policy_id],
        )
        .await
        .context("count_policy_references")?;
    Ok(row.get("cnt"))
}

/// Delete a recording policy by id.
///
/// Returns the number of rows deleted (0 if not found). The caller MUST guard
/// against deleting the default policy or one still referenced by a camera/group
/// (use [`get_policy`] + [`count_policy_references`]); FK `ON DELETE` is `NO
/// ACTION` here, so a referenced delete would error anyway, but the API maps the
/// guarded cases to 400/409 with a clear message.
pub async fn delete_policy(pool: &Pool, id: Uuid) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = client
        .execute(
            "DELETE FROM recording_policies WHERE id = $1 AND is_default = false",
            &[&id],
        )
        .await
        .context("delete_policy")?;
    Ok(n)
}

// ─── camera groups (CRUD) ─────────────────────────────────────────────────────

/// A camera group plus the ids of its member cameras.
#[derive(Debug, Clone, Serialize)]
pub struct CameraGroupWithMembers {
    pub group: CameraGroup,
    pub camera_ids: Vec<Uuid>,
}

fn camera_group_from_row(row: &tokio_postgres::Row) -> CameraGroup {
    CameraGroup {
        id: row.get("id"),
        name: row.get("name"),
        policy_id: row.get("policy_id"),
        created_at: row.get("created_at"),
    }
}

/// List all camera groups, each with its member camera ids.
///
/// One query for the groups, one for all memberships — assembled in memory so the
/// result is a clean group→members structure (avoids row fan-out from a join).
pub async fn list_groups(pool: &Pool) -> Result<Vec<CameraGroupWithMembers>> {
    let client = get_conn(pool).await?;
    let group_rows = client
        .query(
            "SELECT id, name, policy_id, created_at FROM camera_groups ORDER BY name, id",
            &[],
        )
        .await
        .context("list_groups: groups")?;
    let member_rows = client
        .query("SELECT group_id, camera_id FROM camera_group_members", &[])
        .await
        .context("list_groups: members")?;

    let mut by_group: std::collections::HashMap<Uuid, Vec<Uuid>> = std::collections::HashMap::new();
    for r in &member_rows {
        by_group
            .entry(r.get("group_id"))
            .or_default()
            .push(r.get("camera_id"));
    }

    Ok(group_rows
        .iter()
        .map(|r| {
            let group = camera_group_from_row(r);
            let camera_ids = by_group.remove(&group.id).unwrap_or_default();
            CameraGroupWithMembers { group, camera_ids }
        })
        .collect())
}

/// Fetch a single camera group by id (without members). `None` if absent.
pub async fn get_group(pool: &Pool, id: Uuid) -> Result<Option<CameraGroup>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT id, name, policy_id, created_at FROM camera_groups WHERE id = $1",
            &[&id],
        )
        .await
        .context("get_group")?;
    Ok(opt.as_ref().map(camera_group_from_row))
}

/// Create a camera group (no members yet) and return it.
pub async fn create_group(pool: &Pool, name: &str, policy_id: Option<Uuid>) -> Result<CameraGroup> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO camera_groups (name, policy_id)
            VALUES ($1, $2)
            RETURNING id, name, policy_id, created_at
            ",
            &[&name, &policy_id],
        )
        .await
        .context("create_group")?;
    Ok(camera_group_from_row(&row))
}

/// Update a camera group's name and/or policy. `policy_id = None` clears the
/// group's policy (members then inherit the global default). Returns the updated
/// group, or `None` if no such group.
pub async fn update_group(
    pool: &Pool,
    id: Uuid,
    name: &str,
    policy_id: Option<Uuid>,
) -> Result<Option<CameraGroup>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"
            UPDATE camera_groups SET name = $2, policy_id = $3 WHERE id = $1
            RETURNING id, name, policy_id, created_at
            ",
            &[&id, &name, &policy_id],
        )
        .await
        .context("update_group")?;
    Ok(opt.as_ref().map(camera_group_from_row))
}

/// Delete a camera group. Membership rows cascade (cameras revert to their own
/// policy, else the default). Returns rows deleted (0 if not found).
pub async fn delete_group(pool: &Pool, id: Uuid) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = client
        .execute("DELETE FROM camera_groups WHERE id = $1", &[&id])
        .await
        .context("delete_group")?;
    Ok(n)
}

/// Replace a group's membership with exactly `camera_ids`.
///
/// Honors the one-group-per-camera invariant: a camera already in ANOTHER group
/// is MOVED here (its prior membership is deleted first). Runs in a single
/// transaction so a partial failure leaves membership unchanged:
/// 1. delete all current members of THIS group,
/// 2. delete any membership of the incoming cameras in OTHER groups (the move),
/// 3. insert the new memberships,
/// 4. clear the DIRECT per-camera `policy_id` on every added camera.
///
/// Step 4 enforces the Phase-3 authoritative-grouping invariant: a grouped
/// camera is governed by its GROUP's recording profile, so it may not also hold
/// a direct per-camera policy/fork. The effective-policy COALESCE puts
/// `cameras.policy_id` FIRST (it would shadow the group), so leaving it set
/// would silently ignore the group profile. Clearing it makes the group win.
/// Only the cameras being ADDED here are touched; a camera DROPPED from this
/// group (a former member not in `camera_ids`) becomes ungrouped and keeps its
/// `policy_id` — an ungrouped camera is allowed a direct override. A cleared
/// camera's now-unreferenced anonymous fork (if any) is left for the periodic
/// [`reap_orphan_policy_forks`] reaper.
pub async fn set_group_members(pool: &Pool, group_id: Uuid, camera_ids: &[Uuid]) -> Result<()> {
    let mut client = get_conn(pool).await?;
    let tx = client
        .transaction()
        .await
        .context("set_group_members: begin")?;

    // 1. Clear this group's current membership.
    tx.execute(
        "DELETE FROM camera_group_members WHERE group_id = $1",
        &[&group_id],
    )
    .await
    .context("set_group_members: clear group")?;

    // 2. Move any incoming camera out of whatever OTHER group it was in (the
    //    one_group_per_camera unique index would otherwise reject the insert).
    if !camera_ids.is_empty() {
        tx.execute(
            "DELETE FROM camera_group_members WHERE camera_id = ANY($1)",
            &[&camera_ids],
        )
        .await
        .context("set_group_members: detach from other groups")?;

        // 3. Insert the new membership (UNNEST → one row per camera).
        tx.execute(
            r"
            INSERT INTO camera_group_members (group_id, camera_id)
            SELECT $1, cam_id FROM UNNEST($2::uuid[]) AS cam_id
            ",
            &[&group_id, &camera_ids],
        )
        .await
        .context("set_group_members: insert")?;

        // 4. Phase 3: a grouped camera is AUTHORITATIVELY governed by its
        //    group's profile and may not also hold a direct per-camera
        //    override. Clear the direct policy_id on exactly the cameras being
        //    added so the group wins (the effective-policy COALESCE puts
        //    camera.policy_id first). Same transaction as the membership change.
        tx.execute(
            "UPDATE cameras SET policy_id = NULL WHERE id = ANY($1)",
            &[&camera_ids],
        )
        .await
        .context("set_group_members: clear direct policy on added members")?;
    }

    tx.commit().await.context("set_group_members: commit")?;
    Ok(())
}

// ─── segments — API queries ───────────────────────────────────────────────────

/// Return segments for one or more cameras within `[start, end)`.
///
/// Used by the timeline endpoint and export job.  Results are ordered by
/// `(camera_id, start_ts)` for efficient server-side span merging.
pub async fn timeline_spans(
    pool: &Pool,
    camera_ids: &[Uuid],
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Result<Vec<Segment>> {
    if camera_ids.is_empty() {
        return Ok(vec![]);
    }

    let client = get_conn(pool).await?;

    // Lower bound on the indexed `start_ts` column (audit P2 #11): the overlap
    // predicate is `start_ts < end AND end_ts > start`. `end_ts > start` alone
    // is non-sargable, so without this the all-cameras timeline seq-scans ALL
    // footage to find a small window. A segment overlapping `[start, end)` must
    // start no earlier than `start - max_segment_len` (its end can't reach past
    // its own ≤ max_segment_len duration), so `start_ts >= start - MAX_SEGMENT`
    // is a sound, sargable lower bound that lets Postgres range-scan
    // `segments_start_ts` (migration 0009) instead of scanning the whole table.
    let lower_bound = start - MAX_SEGMENT_LEN;

    // Build a parameterised `ANY($1)` clause.  tokio-postgres supports
    // `&[Uuid]` directly as a PostgreSQL UUID array.
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = ANY($1)
              AND start_ts >= $4
              AND start_ts < $3
              AND end_ts   > $2
            ORDER BY camera_id, start_ts
            ",
            &[&camera_ids, &start, &end, &lower_bound],
        )
        .await
        .context("timeline_spans")?;
    rows.iter().map(segment_from_row).collect()
}

/// Resolve the segment(s) covering a specific timestamp for one camera and stream.
///
/// Returns up to one segment (the one whose `[start_ts, end_ts)` window contains
/// `ts`).  Returns an empty vec if no segment covers `ts`.
///
/// `stream` must be `"main"` or `"sub"`.
pub async fn resolve_segment(
    pool: &Pool,
    camera_id: Uuid,
    ts: DateTime<Utc>,
    stream: &str,
) -> Result<Option<Segment>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = $1
              AND stream    = $2
              AND start_ts <= $3
              AND end_ts    > $3
            ORDER BY start_ts DESC
            LIMIT 1
            ",
            &[&camera_id, &stream, &ts],
        )
        .await
        .context("resolve_segment")?;
    opt.map(|r| segment_from_row(&r)).transpose()
}

/// Return a single segment row by UUID.
///
/// Returns `None` if the row does not exist.
pub async fn get_segment(pool: &Pool, id: Uuid) -> Result<Option<Segment>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE id = $1
            ",
            &[&id],
        )
        .await
        .context("get_segment")?;
    opt.map(|r| segment_from_row(&r)).transpose()
}

/// Return all segments for a camera and stream in `[start, end)`, ordered by
/// `start_ts`.  Used by the export job to build the concat list.
pub async fn list_segments_for_range(
    pool: &Pool,
    camera_id: Uuid,
    stream: &str,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Result<Vec<Segment>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes,
                   motion_bbox_x, motion_bbox_y, motion_bbox_w, motion_bbox_h
            FROM segments
            WHERE camera_id = $1
              AND stream    = $2
              AND start_ts < $4
              AND end_ts   > $3
            ORDER BY start_ts
            ",
            &[&camera_id, &stream, &start, &end],
        )
        .await
        .context("list_segments_for_range")?;
    rows.iter().map(segment_from_row).collect()
}

/// Return the most-recent segment for a camera (any stream), for health checks.
///
/// Returns `None` if the camera has no recorded segments yet.
///
/// #12 fix: order by `start_ts DESC` (not `end_ts`).  `end_ts` has no supporting
/// index so this query fell back to a full per-camera sort on every `/status`
/// poll.  `start_ts` is covered by the `segments_camera_start_ts` composite index
/// added by migration 0014 (and the `ensure_segments_camera_start_index` ensure-shim
/// below), turning the query into a fast index DESC scan.
pub async fn camera_last_segment(pool: &Pool, camera_id: Uuid) -> Result<Option<Segment>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = $1
            ORDER BY start_ts DESC
            LIMIT 1
            ",
            &[&camera_id],
        )
        .await
        .context("camera_last_segment")?;
    opt.map(|r| segment_from_row(&r)).transpose()
}

/// The most recent segment that captured motion (`has_motion = true`) within the
/// last two minutes for a camera. Used by `/status` to decide whether a
/// *motion-mode* camera is recording right now: such cameras index every segment
/// continuously (so [`camera_last_segment`] is always fresh), but the REC
/// indicator should only light while motion is being captured.
///
/// The 2-minute floor bounds the scan: without it, a camera quiet for hours would
/// scan back through thousands of non-motion rows to find the last motion one.
/// The "recording now" freshness window the caller applies (~15 s) is well within
/// it, so the bound never affects the result — only the cost. Returns `None` when
/// no motion was captured in that window.
pub async fn camera_last_motion_segment(pool: &Pool, camera_id: Uuid) -> Result<Option<Segment>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            r"
            SELECT id, camera_id, storage_id, stage, path,
                   stream, start_ts, end_ts, duration_ms,
                   has_motion, size_bytes
            FROM segments
            WHERE camera_id = $1 AND has_motion = true
              AND start_ts > now() - interval '2 minutes'
            ORDER BY start_ts DESC
            LIMIT 1
            ",
            &[&camera_id],
        )
        .await
        .context("camera_last_motion_segment")?;
    opt.map(|r| segment_from_row(&r)).transpose()
}

/// Ensure the `(camera_id, start_ts DESC)` index used by `camera_last_segment`
/// exists (idempotent).
///
/// Called at API and recorder startup alongside the other ensure-shims so the
/// index self-heals on a DB that predates migration 0014.
///
/// # Errors
///
/// Returns an error if the DDL fails.
pub async fn ensure_segments_camera_start_index(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            CREATE INDEX IF NOT EXISTS segments_camera_start_ts
                ON segments (camera_id, start_ts DESC);
            ",
        )
        .await
        .context("ensure_segments_camera_start_index")?;
    Ok(())
}

/// Build ascending grid-aligned slot timestamps across `[start, end)`.
///
/// Slots are floored to `interval_secs` on the wall-clock epoch (NOT anchored
/// to `start`), so the same interval requested across different query windows
/// lands on identical timestamps. That stability is what lets pre-generated
/// and on-demand frames share cache keys instead of each scrub minting a new
/// filename. The first slot is `start` floored to the grid; the last is the
/// largest grid multiple strictly less than `end`.
///
/// Shared by [`list_thumbnail_times`] (coverage-filtered below) and
/// `filmstrip::list_filmstrip`'s synthetic fallback (unfiltered — used only
/// when a requested range has zero recorded coverage at all), so the two
/// never drift apart into two different grids.
pub fn thumbnail_grid_slots(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    interval_secs: i64,
) -> Vec<DateTime<Utc>> {
    if interval_secs <= 0 {
        return vec![];
    }
    let step_ms = interval_secs * 1_000;
    // div_euclid floors correctly even for a pre-epoch input.
    let start_ms = start.timestamp_millis().div_euclid(step_ms) * step_ms;
    let end_ms = end.timestamp_millis();
    if end_ms <= start_ms {
        return vec![];
    }
    // start_ms < end_ms and step_ms > 0 here; the quotient fits usize on all
    // targets we care about (Linux x86_64 with 48-bit virtual address space).
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let count = ((end_ms - start_ms) / step_ms) as usize + 1;

    (0..count)
        .filter_map(|i| {
            #[allow(clippy::cast_possible_wrap)]
            let ts_ms = start_ms + (i as i64) * step_ms;
            // Keep slots strictly before `end`.
            let ts = Utc.timestamp_millis_opt(ts_ms).single()?;
            if ts < end {
                Some(ts)
            } else {
                None
            }
        })
        .collect()
}

/// Return pre-generation / scrub-preview grid slot timestamps for a camera in
/// `[start, end)`, filtered to slots that fall within actual recorded `main`-
/// stream `segments` coverage.
///
/// The grid itself is [`thumbnail_grid_slots`] at `interval_secs` — unchanged
/// cadence from the Phase 1 synthetic fallback. What's new is the filter: a
/// slot is only returned when some `main`-stream segment's `[start_ts, end_ts)`
/// span covers it, the same half-open convention [`resolve_segment`] uses (a
/// slot exactly at a segment's `start_ts` is covered; one exactly at its
/// `end_ts` is not, unless the next contiguous segment starts exactly there).
/// This is what keeps recording-gap slots out of both the client-facing
/// `/filmstrip` list and the background pre-generation worker, so neither ever
/// requests a frame ffmpeg has no footage to extract (issue #9).
///
/// Callers relying on `interval_secs` for cache-key stability (the on-demand
/// `serve_frame` grid-snap) must pass the same value used elsewhere for this
/// camera — [`filmstrip::DEFAULT_THUMB_INTERVAL_SECS`] in production.
///
/// Implemented by fetching the (already indexed, `camera_id, start_ts`)
/// segments overlapping the window once via [`list_segments_for_range`], then
/// sweeping the grid against them in a single linear pass — segments are
/// non-overlapping and returned ordered by `start_ts`, so a monotonically
/// advancing cursor is sufficient (no per-slot query).
///
/// # Errors
///
/// Returns an error if the underlying segments query fails.
pub async fn list_thumbnail_times(
    pool: &Pool,
    camera_id: Uuid,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    interval_secs: i64,
) -> Result<Vec<DateTime<Utc>>> {
    let grid = thumbnail_grid_slots(start, end, interval_secs);
    if grid.is_empty() {
        return Ok(vec![]);
    }

    let segments = list_segments_for_range(pool, camera_id, "main", start, end).await?;

    let mut covered = Vec::with_capacity(grid.len());
    let mut idx = 0usize;
    for ts in grid {
        // Advance past segments that end at-or-before this slot — such a
        // segment (and anything earlier) can never cover this or any later
        // slot, since both the grid and the segments are ascending.
        while idx < segments.len() && segments[idx].end_ts <= ts {
            idx += 1;
        }
        if idx < segments.len() && segments[idx].start_ts <= ts {
            covered.push(ts);
        }
    }
    Ok(covered)
}

// ─── users — CRUD ────────────────────────────────────────────────────────────

/// Return all user rows.
pub async fn list_users(pool: &Pool) -> Result<Vec<User>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT id, username, password_hash, role, camera_ids, role_id FROM users ORDER BY username",
            &[],
        )
        .await
        .context("list_users")?;
    rows.iter().map(user_from_row).collect()
}

/// Fetch a user row by username.
///
/// Returns `None` if the username does not exist.  Used by the login handler
/// to retrieve the hash for verification.
pub async fn get_user_by_username(pool: &Pool, username: &str) -> Result<Option<User>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT id, username, password_hash, role, camera_ids, role_id FROM users WHERE username = $1",
            &[&username],
        )
        .await
        .context("get_user_by_username")?;
    opt.map(|r| user_from_row(&r)).transpose()
}

/// Fetch a user row by UUID.
pub async fn get_user_by_id(pool: &Pool, id: Uuid) -> Result<Option<User>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT id, username, password_hash, role, camera_ids, role_id FROM users WHERE id = $1",
            &[&id],
        )
        .await
        .context("get_user_by_id")?;
    opt.map(|r| user_from_row(&r)).transpose()
}

/// Insert a new user row and return the created [`User`].
///
/// `password_hash` must already be an Argon2 PHC string — this function does
/// **not** perform hashing.  That is the caller's responsibility.
///
/// # Errors
///
/// Returns an error (with `tokio_postgres::error::SqlState::UNIQUE_VIOLATION`)
/// if the `username` is already taken.  Callers should map this to
/// `ApiError::Conflict`.
pub async fn create_user(
    pool: &Pool,
    username: &str,
    password_hash: &str,
    role: UserRole,
    camera_ids: &[Uuid],
    role_id: Option<Uuid>,
) -> Result<User> {
    let client = get_conn(pool).await?;
    let camera_ids_json =
        serde_json::to_value(camera_ids).context("create_user: serialise camera_ids")?;
    let row = client
        .query_one(
            r"
            INSERT INTO users (username, password_hash, role, camera_ids, role_id)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING id, username, password_hash, role, camera_ids, role_id
            ",
            &[
                &username,
                &password_hash,
                &role.as_str(),
                &camera_ids_json,
                &role_id,
            ],
        )
        .await
        .context("create_user")?;
    user_from_row(&row)
}

/// Update an existing user row.
///
/// Only non-`None` fields are written.  Pass `None` to leave a field unchanged.
pub async fn update_user(
    pool: &Pool,
    id: Uuid,
    username: Option<&str>,
    password_hash: Option<&str>,
    role: Option<UserRole>,
    camera_ids: Option<&[Uuid]>,
    role_id: Option<Uuid>,
) -> Result<User> {
    let client = get_conn(pool).await?;
    let camera_ids_json = camera_ids
        .map(serde_json::to_value)
        .transpose()
        .context("update_user: serialise camera_ids")?;
    let row = client
        .query_one(
            r"
            UPDATE users
            SET username      = COALESCE($2::text,  username),
                password_hash = COALESCE($3::text,  password_hash),
                role          = COALESCE($4::text,  role),
                camera_ids    = COALESCE($5::jsonb, camera_ids),
                role_id       = COALESCE($6::uuid,  role_id)
            WHERE id = $1
            RETURNING id, username, password_hash, role, camera_ids, role_id
            ",
            &[
                &id,
                &username,
                &password_hash,
                &role.map(|r| r.as_str().to_owned()),
                &camera_ids_json,
                &role_id,
            ],
        )
        .await
        .context("update_user")?;
    user_from_row(&row)
}

/// Delete a user by UUID.
pub async fn delete_user(pool: &Pool, id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute("DELETE FROM users WHERE id = $1", &[&id])
        .await
        .context("delete_user")?;
    Ok(())
}

fn user_from_row(row: &tokio_postgres::Row) -> Result<User> {
    let role_str: String = row.get("role");
    let role =
        UserRole::from_str(&role_str).with_context(|| format!("unknown user role '{role_str}'"))?;

    // `camera_ids` is stored as `jsonb` — extract as `serde_json::Value` then
    // deserialise to `Vec<Uuid>` (as documented in types.rs).
    let camera_ids_json: serde_json::Value = row.get("camera_ids");
    let camera_ids: Vec<Uuid> =
        serde_json::from_value(camera_ids_json).context("user_from_row: deserialise camera_ids")?;

    Ok(User {
        id: row.get("id"),
        username: row.get("username"),
        password_hash: row.get("password_hash"),
        role,
        camera_ids,
        role_id: row.get("role_id"),
    })
}

// ─── roles (RBAC) — CRUD ───────────────────────────────────────────────────────

fn role_from_row(row: &tokio_postgres::Row) -> Result<Role> {
    let caps_json: serde_json::Value = row.get("capabilities");
    let capabilities: Capabilities =
        serde_json::from_value(caps_json).context("role_from_row: deserialise capabilities")?;
    let cam_json: serde_json::Value = row.get("camera_ids");
    let camera_ids: Vec<Uuid> =
        serde_json::from_value(cam_json).context("role_from_row: deserialise camera_ids")?;
    Ok(Role {
        id: row.get("id"),
        name: row.get("name"),
        is_admin: row.get("is_admin"),
        capabilities,
        camera_ids,
        created_at: row.get("created_at"),
    })
}

const ROLE_SELECT: &str =
    "SELECT id, name, is_admin, capabilities, camera_ids, created_at FROM roles";

/// All roles, ordered admin-first then by name.
pub async fn list_roles(pool: &Pool) -> Result<Vec<Role>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(&format!("{ROLE_SELECT} ORDER BY is_admin DESC, name"), &[])
        .await
        .context("list_roles")?;
    rows.iter().map(role_from_row).collect()
}

/// Fetch one role by id.
pub async fn get_role(pool: &Pool, id: Uuid) -> Result<Option<Role>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(&format!("{ROLE_SELECT} WHERE id = $1"), &[&id])
        .await
        .context("get_role")?;
    opt.map(|r| role_from_row(&r)).transpose()
}

/// The built-in admin role id (oldest `is_admin` role), if any.
pub async fn get_admin_role_id(pool: &Pool) -> Result<Option<Uuid>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT id FROM roles WHERE is_admin = true ORDER BY created_at LIMIT 1",
            &[],
        )
        .await
        .context("get_admin_role_id")?;
    Ok(opt.map(|r| r.get("id")))
}

/// Create a non-admin role. (The admin role is seeded by migration, not created here.)
pub async fn create_role(
    pool: &Pool,
    name: &str,
    capabilities: &Capabilities,
    camera_ids: &[Uuid],
) -> Result<Role> {
    let client = get_conn(pool).await?;
    let caps_json = serde_json::to_value(capabilities).context("create_role: serialise caps")?;
    let cam_json = serde_json::to_value(camera_ids).context("create_role: serialise cameras")?;
    let row = client
        .query_one(
            r"
            INSERT INTO roles (name, is_admin, capabilities, camera_ids)
            VALUES ($1, false, $2, $3)
            RETURNING id, name, is_admin, capabilities, camera_ids, created_at
            ",
            &[&name, &caps_json, &cam_json],
        )
        .await
        .context("create_role")?;
    role_from_row(&row)
}

/// Update a role's name / capabilities / cameras. `None` fields are left unchanged.
/// The `is_admin` flag is immutable (never edited here).
pub async fn update_role(
    pool: &Pool,
    id: Uuid,
    name: Option<&str>,
    capabilities: Option<&Capabilities>,
    camera_ids: Option<&[Uuid]>,
) -> Result<Option<Role>> {
    let client = get_conn(pool).await?;
    let caps_json = capabilities
        .map(serde_json::to_value)
        .transpose()
        .context("update_role: serialise caps")?;
    let cam_json = camera_ids
        .map(serde_json::to_value)
        .transpose()
        .context("update_role: serialise cameras")?;
    let opt = client
        .query_opt(
            r"
            UPDATE roles
            SET name         = COALESCE($2::text,  name),
                capabilities = COALESCE($3::jsonb, capabilities),
                camera_ids   = COALESCE($4::jsonb, camera_ids)
            WHERE id = $1 AND is_admin = false
            RETURNING id, name, is_admin, capabilities, camera_ids, created_at
            ",
            &[&id, &name, &caps_json, &cam_json],
        )
        .await
        .context("update_role")?;
    opt.map(|r| role_from_row(&r)).transpose()
}

/// Delete a non-admin role. Returns rows affected (0 if not found or is_admin).
pub async fn delete_role(pool: &Pool, id: Uuid) -> Result<u64> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "DELETE FROM roles WHERE id = $1 AND is_admin = false",
            &[&id],
        )
        .await
        .context("delete_role")
}

/// Number of users currently assigned to a role (guards deletion / last-admin).
pub async fn count_users_with_role(pool: &Pool, role_id: Uuid) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            "SELECT COUNT(*)::bigint FROM users WHERE role_id = $1",
            &[&role_id],
        )
        .await
        .context("count_users_with_role")?;
    Ok(row.get(0))
}

// ─── sessions (revocable auth) — CRUD ──────────────────────────────────────────

const SESSION_SELECT: &str = "SELECT jti, user_id, label, ip, long_lived, created_at, \
     last_seen_at, expires_at, revoked_at FROM sessions";

fn session_from_row(row: &tokio_postgres::Row) -> Session {
    Session {
        jti: row.get("jti"),
        user_id: row.get("user_id"),
        label: row.get("label"),
        ip: row.get("ip"),
        long_lived: row.get("long_lived"),
        created_at: row.get("created_at"),
        last_seen_at: row.get("last_seen_at"),
        expires_at: row.get("expires_at"),
        revoked_at: row.get("revoked_at"),
    }
}

/// Insert a session row at token-issue time.
///
/// Called by `auth.rs` when a login (or refresh) mints a token bearing `jti`.
/// The row is what makes that token revocable: the `AuthUser` extractor checks
/// (via the in-memory revocation cache) that the `jti` is present and not
/// revoked before honouring the token.
pub async fn create_session(
    pool: &Pool,
    jti: Uuid,
    user_id: Uuid,
    label: Option<&str>,
    ip: Option<&str>,
    long_lived: bool,
    expires_at: DateTime<Utc>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO sessions (jti, user_id, label, ip, long_lived, expires_at)
            VALUES ($1, $2, $3, $4, $5, $6)
            ",
            &[&jti, &user_id, &label, &ip, &long_lived, &expires_at],
        )
        .await
        .context("create_session")?;
    Ok(())
}

/// List a user's sessions, newest first. Used by the "your sessions" UI.
pub async fn list_sessions_for_user(pool: &Pool, user_id: Uuid) -> Result<Vec<Session>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            &format!("{SESSION_SELECT} WHERE user_id = $1 ORDER BY created_at DESC"),
            &[&user_id],
        )
        .await
        .context("list_sessions_for_user")?;
    Ok(rows.iter().map(session_from_row).collect())
}

/// Fetch one session by `jti`.
pub async fn get_session(pool: &Pool, jti: Uuid) -> Result<Option<Session>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(&format!("{SESSION_SELECT} WHERE jti = $1"), &[&jti])
        .await
        .context("get_session")?;
    Ok(opt.as_ref().map(session_from_row))
}

/// Every currently-revoked `jti` (used to (re)build the in-memory revocation
/// cache). Only rows whose token has not yet expired matter — an expired token
/// is already rejected by the JWT `exp` check — so this scopes to
/// `expires_at > now()` to keep the set small on a long-lived DB.
pub async fn list_revoked_jtis(pool: &Pool) -> Result<Vec<Uuid>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT jti FROM sessions WHERE revoked_at IS NOT NULL AND expires_at > now()",
            &[],
        )
        .await
        .context("list_revoked_jtis")?;
    Ok(rows.iter().map(|r| r.get("jti")).collect())
}

/// Revoke a single session by `jti`, but only if it belongs to `user_id`
/// (self-service revoke) — pass `None` for `user_id` to allow an admin to
/// revoke any session. Returns the number of rows affected (0 ⇒ not found / not
/// owned). Idempotent: re-revoking an already-revoked row is a no-op match.
pub async fn revoke_session(pool: &Pool, jti: Uuid, user_id: Option<Uuid>) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = match user_id {
        Some(uid) => client
            .execute(
                "UPDATE sessions SET revoked_at = now() \
                 WHERE jti = $1 AND user_id = $2 AND revoked_at IS NULL",
                &[&jti, &uid],
            )
            .await
            .context("revoke_session (scoped)")?,
        None => client
            .execute(
                "UPDATE sessions SET revoked_at = now() \
                 WHERE jti = $1 AND revoked_at IS NULL",
                &[&jti],
            )
            .await
            .context("revoke_session (admin)")?,
    };
    Ok(n)
}

/// Revoke ALL of a user's active sessions ("sign out all devices"). Returns the
/// number revoked.
pub async fn revoke_all_sessions_for_user(pool: &Pool, user_id: Uuid) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = client
        .execute(
            "UPDATE sessions SET revoked_at = now() \
             WHERE user_id = $1 AND revoked_at IS NULL",
            &[&user_id],
        )
        .await
        .context("revoke_all_sessions_for_user")?;
    Ok(n)
}

/// Best-effort update of a session's `last_seen_at` (for the activity column in
/// the "your sessions" UI). Off the hot auth path — callers throttle this.
pub async fn touch_session(pool: &Pool, jti: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE sessions SET last_seen_at = now() WHERE jti = $1",
            &[&jti],
        )
        .await
        .context("touch_session")?;
    Ok(())
}

/// Delete session rows whose token has already expired (housekeeping). Safe to
/// run periodically; expired tokens are rejected by the `exp` check regardless.
/// Returns the number of rows pruned.
pub async fn prune_expired_sessions(pool: &Pool) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = client
        .execute("DELETE FROM sessions WHERE expires_at <= now()", &[])
        .await
        .context("prune_expired_sessions")?;
    Ok(n)
}

// ─── schema helpers ──────────────────────────────────────────────────────────

// ─── views — CRUD ────────────────────────────────────────────────────────────

/// List views visible to a given user.
///
/// * Admins receive every view ordered by `created_at`.
/// * Non-admins receive views where `owner_id = user_id` (their own), or
///   `owner_id IS NULL` (legacy global rows), or an explicit share exists in
///   `view_shares`.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn list_views_for_user(pool: &Pool, user_id: Uuid, is_admin: bool) -> Result<Vec<View>> {
    let client = get_conn(pool).await?;
    let rows = if is_admin {
        client
            .query(
                "SELECT id, name, layout, slots, owner_id, icon, created_at \
                 FROM views \
                 ORDER BY created_at",
                &[],
            )
            .await
            .context("list_views_for_user (admin)")?
    } else {
        client
            .query(
                r"
                SELECT id, name, layout, slots, owner_id, icon, created_at
                FROM views
                WHERE owner_id = $1
                   OR owner_id IS NULL
                   OR EXISTS (
                       SELECT 1 FROM view_shares s
                       WHERE s.view_id = views.id AND s.user_id = $1
                   )
                ORDER BY created_at
                ",
                &[&user_id],
            )
            .await
            .context("list_views_for_user")?
    };
    Ok(rows.iter().map(view_from_row).collect())
}

/// Insert a new view row and return it.
///
/// `slots` is stored verbatim as `jsonb`; the `with-serde_json-1`
/// `tokio-postgres` feature enables passing `&serde_json::Value` directly as a
/// `jsonb` parameter.
///
/// `owner_id` should be `Some(user_id)` for user-owned views, or `None` to
/// create a legacy global view (not normally used by the API after Phase 3).
///
/// `icon` is the caller's chosen quick-switch glyph, or `None` to leave it
/// unset (clients fall back to their own default).
///
/// # Errors
///
/// Returns an error if the database query fails (e.g. a constraint violation).
pub async fn create_view(
    pool: &Pool,
    name: &str,
    layout: &str,
    slots: &serde_json::Value,
    owner_id: Option<Uuid>,
    icon: Option<&str>,
) -> Result<View> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO views (name, layout, slots, owner_id, icon)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING id, name, layout, slots, owner_id, icon, created_at
            ",
            &[&name, &layout, &slots, &owner_id, &icon],
        )
        .await
        .context("create_view")?;
    Ok(view_from_row(&row))
}

/// Update the `icon` of an existing view in place.
///
/// Passing `icon = None` clears it back to unset (so clients fall back to
/// their own default) rather than leaving the previous value — callers that
/// want to *preserve* the current icon should omit the call entirely (there
/// is no partial-field PATCH here; this function always writes exactly what
/// it is given, matching how [`set_view_shares`] fully replaces its set).
///
/// Returns the number of rows updated (0 or 1); the caller maps 0 to a `404`.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn update_view_icon(pool: &Pool, id: Uuid, icon: Option<&str>) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = client
        .execute("UPDATE views SET icon = $2 WHERE id = $1", &[&id, &icon])
        .await
        .context("update_view_icon")?;
    Ok(n)
}

/// Delete a view by UUID.
///
/// Returns the number of rows deleted (0 or 1).  The caller maps 0 to a
/// `404 Not Found` response.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn delete_view(pool: &Pool, id: Uuid) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = client
        .execute("DELETE FROM views WHERE id = $1", &[&id])
        .await
        .context("delete_view")?;
    Ok(n)
}

/// Return the `owner_id` of the given view.
///
/// * `Ok(None)` — no view with that UUID exists.
/// * `Ok(Some(None))` — view exists but has no owner (legacy global row).
/// * `Ok(Some(Some(uuid)))` — view exists and is owned by `uuid`.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn get_view_owner(pool: &Pool, id: Uuid) -> Result<Option<Option<Uuid>>> {
    let client = get_conn(pool).await?;
    let opt_row = client
        .query_opt("SELECT owner_id FROM views WHERE id = $1", &[&id])
        .await
        .context("get_view_owner")?;
    Ok(opt_row.map(|row| row.get("owner_id")))
}

/// Return the list of user UUIDs that have been explicitly granted access to
/// `view_id` via `view_shares`.
///
/// Returns an empty `Vec` when the view has no shares (or does not exist).
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn list_view_shares(pool: &Pool, view_id: Uuid) -> Result<Vec<Uuid>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT user_id FROM view_shares WHERE view_id = $1 ORDER BY created_at",
            &[&view_id],
        )
        .await
        .context("list_view_shares")?;
    Ok(rows.iter().map(|r| r.get("user_id")).collect())
}

/// Replace the full share list for `view_id` with `user_ids` in a single
/// transaction.
///
/// Duplicate entries in `user_ids` are silently deduplicated before the
/// INSERT so the composite PK is never violated.  The old share set is
/// deleted first, then the new one inserted.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn set_view_shares(pool: &Pool, view_id: Uuid, user_ids: &[Uuid]) -> Result<()> {
    // Deduplicate preserving order so the INSERT is deterministic.
    let mut seen = std::collections::HashSet::new();
    let unique: Vec<Uuid> = user_ids
        .iter()
        .copied()
        .filter(|id| seen.insert(*id))
        .collect();

    let mut client = get_conn(pool).await?;
    let tx = client
        .transaction()
        .await
        .context("set_view_shares: begin")?;

    tx.execute("DELETE FROM view_shares WHERE view_id = $1", &[&view_id])
        .await
        .context("set_view_shares: delete")?;

    for uid in &unique {
        tx.execute(
            "INSERT INTO view_shares (view_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
            &[&view_id, uid],
        )
        .await
        .context("set_view_shares: insert")?;
    }

    tx.commit().await.context("set_view_shares: commit")?;
    Ok(())
}

fn view_from_row(row: &tokio_postgres::Row) -> View {
    View {
        id: row.get("id"),
        name: row.get("name"),
        layout: row.get("layout"),
        slots: row.get("slots"),
        owner_id: row.get("owner_id"),
        icon: row.get("icon"),
        created_at: row.get("created_at"),
    }
}

// ─── bookmarks — CRUD ──────────────────────────────────────────────────────────

/// Idempotently create the `bookmarks` table.
///
/// Runtime mirror of migration `0010_bookmarks.sql` (migrations only run on a
/// fresh data dir), so an already-running DB gains the table when the API
/// (re)starts. `protect_until` is reserved for future protected retention.
///
/// # Errors
/// Returns an error if the DDL fails.
pub async fn ensure_bookmarks_table(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            CREATE TABLE IF NOT EXISTS bookmarks (
                id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                camera_id     uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
                ts            timestamptz NOT NULL,
                description   text,
                created_by    uuid,
                protect_until timestamptz,
                created_at    timestamptz NOT NULL DEFAULT now()
            );
            -- Reconcile an OLDER bookmarks table (an early schema used `note` and
            -- lacked these columns) so CREATE-IF-NOT-EXISTS being a no-op on an
            -- existing table doesn't leave us missing fields.
            ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS description     text;
            ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS created_by      uuid;
            ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS protect_until   timestamptz;
            -- Protected-clip footage window [protect_start_ts, protect_end_ts]: while
            -- protect_until > now() the recorder skips deleting/evicting any segment
            -- overlapping this window (see the NOT-EXISTS guard on the eviction queries).
            ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS protect_start_ts timestamptz;
            ALTER TABLE bookmarks ADD COLUMN IF NOT EXISTS protect_end_ts   timestamptz;
            DO $$
            BEGIN
                IF EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_name = 'bookmarks' AND column_name = 'note') THEN
                    UPDATE bookmarks SET description = note
                        WHERE description IS NULL AND note IS NOT NULL;
                    ALTER TABLE bookmarks DROP COLUMN note;
                END IF;
            END $$;
            CREATE INDEX IF NOT EXISTS bookmarks_camera_ts ON bookmarks (camera_id, ts);
            CREATE INDEX IF NOT EXISTS bookmarks_created ON bookmarks (created_at);
            ",
        )
        .await
        .context("ensure_bookmarks_table")?;
    Ok(())
}

/// Columns selected for a [`Bookmark`], with the joined camera name.
const BOOKMARK_SELECT: &str = r"
    SELECT b.id, b.camera_id, c.name AS camera_name, b.ts, b.description,
           b.protect_until, b.protect_start_ts, b.protect_end_ts, b.created_at
    FROM bookmarks b
    LEFT JOIN cameras c ON c.id = b.camera_id
";

/// List every bookmark, newest moment first (for the cross-camera list view).
///
/// # Errors
/// Returns an error if the query fails.
pub async fn list_bookmarks(pool: &Pool) -> Result<Vec<Bookmark>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(&format!("{BOOKMARK_SELECT} ORDER BY b.ts DESC"), &[])
        .await
        .context("list_bookmarks")?;
    Ok(rows.iter().map(bookmark_from_row).collect())
}

/// List one camera's bookmarks, oldest first (for timeline markers).
///
/// # Errors
/// Returns an error if the query fails.
pub async fn list_bookmarks_for_camera(pool: &Pool, camera_id: Uuid) -> Result<Vec<Bookmark>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            &format!("{BOOKMARK_SELECT} WHERE b.camera_id = $1 ORDER BY b.ts ASC"),
            &[&camera_id],
        )
        .await
        .context("list_bookmarks_for_camera")?;
    Ok(rows.iter().map(bookmark_from_row).collect())
}

/// Insert a bookmark and return it (with the joined camera name).
///
/// # Errors
/// Returns an error if the query fails (e.g. an unknown `camera_id` FK violation).
#[allow(clippy::too_many_arguments)]
pub async fn create_bookmark(
    pool: &Pool,
    camera_id: Uuid,
    ts: DateTime<Utc>,
    description: Option<&str>,
    created_by: Option<Uuid>,
    protect_until: Option<DateTime<Utc>>,
    protect_start: Option<DateTime<Utc>>,
    protect_end: Option<DateTime<Utc>>,
) -> Result<Bookmark> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            WITH ins AS (
                INSERT INTO bookmarks
                    (camera_id, ts, description, created_by,
                     protect_until, protect_start_ts, protect_end_ts)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                RETURNING id, camera_id, ts, description, protect_until,
                          protect_start_ts, protect_end_ts, created_at
            )
            SELECT ins.id, ins.camera_id, c.name AS camera_name, ins.ts, ins.description,
                   ins.protect_until, ins.protect_start_ts, ins.protect_end_ts, ins.created_at
            FROM ins LEFT JOIN cameras c ON c.id = ins.camera_id
            ",
            &[
                &camera_id,
                &ts,
                &description,
                &created_by,
                &protect_until,
                &protect_start,
                &protect_end,
            ],
        )
        .await
        .context("create_bookmark")?;
    Ok(bookmark_from_row(&row))
}

/// Update a bookmark's description (NULL clears it). Returns the updated row, or
/// `None` if no bookmark has that id.
///
/// # Errors
/// Returns an error if the query fails.
pub async fn update_bookmark_description(
    pool: &Pool,
    id: Uuid,
    description: Option<&str>,
) -> Result<Option<Bookmark>> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            r"
            WITH upd AS (
                UPDATE bookmarks SET description = $2 WHERE id = $1
                RETURNING id, camera_id, ts, description, protect_until,
                          protect_start_ts, protect_end_ts, created_at
            )
            SELECT upd.id, upd.camera_id, c.name AS camera_name, upd.ts, upd.description,
                   upd.protect_until, upd.protect_start_ts, upd.protect_end_ts, upd.created_at
            FROM upd LEFT JOIN cameras c ON c.id = upd.camera_id
            ",
            &[&id, &description],
        )
        .await
        .context("update_bookmark_description")?;
    Ok(row.as_ref().map(bookmark_from_row))
}

/// Delete a bookmark by id. Returns the number of rows deleted (0 or 1).
///
/// # Errors
/// Returns an error if the query fails.
pub async fn delete_bookmark(pool: &Pool, id: Uuid) -> Result<u64> {
    let client = get_conn(pool).await?;
    let n = client
        .execute("DELETE FROM bookmarks WHERE id = $1", &[&id])
        .await
        .context("delete_bookmark")?;
    Ok(n)
}

/// Fetch the `(camera_id, created_by)` pair for a bookmark by its id.
///
/// Returns `None` when no bookmark has that id (caller should treat as 404).
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn get_bookmark_owner(pool: &Pool, id: Uuid) -> Result<Option<(Uuid, Option<Uuid>)>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT camera_id, created_by FROM bookmarks WHERE id = $1",
            &[&id],
        )
        .await
        .context("get_bookmark_owner")?;
    Ok(opt.map(|row| {
        let camera_id: Uuid = row.get("camera_id");
        let created_by: Option<Uuid> = row.get("created_by");
        (camera_id, created_by)
    }))
}

/// List bookmarks owned by a specific user (for `BookmarkScope::Own` in the
/// list-all view, no camera filter). Ordered newest first.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_bookmarks_by_user(pool: &Pool, created_by: Uuid) -> Result<Vec<Bookmark>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            &format!("{BOOKMARK_SELECT} WHERE b.created_by = $1 ORDER BY b.ts DESC"),
            &[&created_by],
        )
        .await
        .context("list_bookmarks_by_user")?;
    Ok(rows.iter().map(bookmark_from_row).collect())
}

/// Fetch the `camera_id` for a detection event.
///
/// Returns `None` when the event does not exist.  Used by the snapshot handler
/// to enforce per-camera access control.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn get_event_camera_id(pool: &Pool, event_id: Uuid) -> Result<Option<Uuid>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt("SELECT camera_id FROM events WHERE id = $1", &[&event_id])
        .await
        .context("get_event_camera_id")?;
    Ok(opt.map(|row| row.get("camera_id")))
}

fn bookmark_from_row(row: &tokio_postgres::Row) -> Bookmark {
    Bookmark {
        id: row.get("id"),
        camera_id: row.get("camera_id"),
        camera_name: row.try_get("camera_name").unwrap_or(None),
        ts: row.get("ts"),
        description: row.get("description"),
        protect_until: row.get("protect_until"),
        protect_start_ts: row.try_get("protect_start_ts").unwrap_or(None),
        protect_end_ts: row.try_get("protect_end_ts").unwrap_or(None),
        created_at: row.get("created_at"),
    }
}

// ─── recorder heartbeat ────────────────────────────────────────────────────────

/// Upsert the recorder liveness heartbeat (singleton row, id = 1).
///
/// Called by the recorder on a fixed interval.  Sets `updated_at = now()` (DB
/// clock — avoids client/server clock skew) plus diagnostic `pid` and the
/// current `active_cameras` count.  The `ON CONFLICT` keeps it a single row
/// even if migration 0004's seed row is missing.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn write_recorder_heartbeat(pool: &Pool, pid: i32, active_cameras: i32) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO recorder_heartbeat (id, updated_at, pid, active_cameras)
            VALUES (1, now(), $1, $2)
            ON CONFLICT (id) DO UPDATE
                SET updated_at = now(),
                    pid = EXCLUDED.pid,
                    active_cameras = EXCLUDED.active_cameras
            ",
            &[&pid, &active_cameras],
        )
        .await
        .context("write_recorder_heartbeat")?;
    Ok(())
}

/// Read the recorder liveness heartbeat (singleton row, id = 1).
///
/// Returns `None` if the row does not exist (e.g. migration 0004 not yet
/// applied or the recorder has never written one).  The caller compares
/// `updated_at` against `now()` to decide whether the recorder is live.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn read_recorder_heartbeat(pool: &Pool) -> Result<Option<RecorderHeartbeat>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT updated_at, pid, active_cameras FROM recorder_heartbeat WHERE id = 1",
            &[],
        )
        .await
        .context("read_recorder_heartbeat")?;
    Ok(opt.map(|row| RecorderHeartbeat {
        updated_at: row.get("updated_at"),
        pid: row.get("pid"),
        active_cameras: row.get("active_cameras"),
    }))
}

// ─── Frigate connectivity heartbeat (frigate_disconnected alert) ────────────────

/// Upsert the Frigate MQTT connectivity heartbeat (singleton row, id = 1).
///
/// The API's Frigate provider calls this on each MQTT ConnAck and periodically
/// while connected (keepalive/events). The `frigate_disconnected` watchdog reads
/// [`read_frigate_heartbeat`] and fires when this goes stale. Migration 0034
/// creates the table WITHOUT a seed row, so the first successful connection is
/// what makes the row appear — distinguishing "never connected" from "was
/// connected, now stale". Best-effort: callers log a WARN and continue on error.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn write_frigate_heartbeat(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO frigate_heartbeat (id, updated_at)
            VALUES (1, now())
            ON CONFLICT (id) DO UPDATE SET updated_at = now()
            ",
            &[],
        )
        .await
        .context("write_frigate_heartbeat")?;
    Ok(())
}

/// Read the Frigate connectivity heartbeat timestamp (singleton row, id = 1).
///
/// Returns `None` when no row exists — Frigate has never connected (or isn't
/// configured), in which case the watchdog must NOT fire `frigate_disconnected`.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn read_frigate_heartbeat(pool: &Pool) -> Result<Option<chrono::DateTime<chrono::Utc>>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt("SELECT updated_at FROM frigate_heartbeat WHERE id = 1", &[])
        .await
        .context("read_frigate_heartbeat")?;
    Ok(opt.map(|row| row.get("updated_at")))
}

// ─── motion-decode truth telemetry (migration 0035) ──────────────────────────

/// Upsert the recorder's accelerator-capability report (singleton row, id = 1).
///
/// Called once per recorder boot after the container's devices have been
/// probed. `detected_at` uses the DB clock (`now()`) so the UI's staleness
/// comparison is skew-free. Best-effort at the call site: a failed write only
/// degrades the admin decode-status panel, never recording.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn write_recorder_capabilities(
    pool: &Pool,
    dri_devices: &[String],
    nvidia: bool,
    ffmpeg_hwaccels: &[String],
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO recorder_capabilities (id, dri_devices, nvidia, ffmpeg_hwaccels, detected_at)
            VALUES (1, $1, $2, $3, now())
            ON CONFLICT (id) DO UPDATE
                SET dri_devices     = EXCLUDED.dri_devices,
                    nvidia          = EXCLUDED.nvidia,
                    ffmpeg_hwaccels = EXCLUDED.ffmpeg_hwaccels,
                    detected_at     = now()
            ",
            &[&dri_devices, &nvidia, &ffmpeg_hwaccels],
        )
        .await
        .context("write_recorder_capabilities")?;
    Ok(())
}

/// Read the recorder's accelerator-capability report (singleton row, id = 1).
///
/// Returns `None` when the recorder has never reported (older recorder image
/// or not booted yet) — the API surfaces that as `capabilities: null`, which
/// the UI must render as "no report yet", not as "no devices".
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn read_recorder_capabilities(pool: &Pool) -> Result<Option<RecorderCapabilities>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT dri_devices, nvidia, ffmpeg_hwaccels, detected_at
             FROM recorder_capabilities WHERE id = 1",
            &[],
        )
        .await
        .context("read_recorder_capabilities")?;
    Ok(opt.map(|row| RecorderCapabilities {
        dri_devices: row.get("dri_devices"),
        nvidia: row.get("nvidia"),
        ffmpeg_hwaccels: row.get("ffmpeg_hwaccels"),
        detected_at: row.get("detected_at"),
    }))
}

/// Upsert one camera's decode-backend truth row.
///
/// Called by the motion task each time it (re)starts its ffmpeg decode child
/// (and when it parks with no local decode — Frigate-sourced motion or no
/// sub-stream). Best-effort at the call site: telemetry only, never blocks or
/// fails the motion loop.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn upsert_camera_decode_status(
    pool: &Pool,
    camera_id: Uuid,
    requested: &str,
    active: &str,
    fallback_reason: Option<&str>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO camera_decode_status (camera_id, requested, active, fallback_reason, updated_at)
            VALUES ($1, $2, $3, $4, now())
            ON CONFLICT (camera_id) DO UPDATE
                SET requested       = EXCLUDED.requested,
                    active          = EXCLUDED.active,
                    fallback_reason = EXCLUDED.fallback_reason,
                    updated_at      = now()
            ",
            &[&camera_id, &requested, &active, &fallback_reason],
        )
        .await
        .context("upsert_camera_decode_status")?;
    Ok(())
}

/// Delete one camera's decode-status row.
///
/// Called by the supervisor when it stops the worker of a disabled/removed
/// camera, so the admin decode-status panel never shows a stale entry for a
/// camera that isn't being decoded at all. (Camera deletion also cascades via
/// the FK — this covers the disable case.)
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn delete_camera_decode_status(pool: &Pool, camera_id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "DELETE FROM camera_decode_status WHERE camera_id = $1",
            &[&camera_id],
        )
        .await
        .context("delete_camera_decode_status")?;
    Ok(())
}

/// List every camera's decode-backend truth row (joined with `cameras` for the
/// display name), ordered by camera name for a stable UI.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn list_camera_decode_status(pool: &Pool) -> Result<Vec<CameraDecodeStatus>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT s.camera_id, c.name AS camera_name,
                   s.requested, s.active, s.fallback_reason, s.updated_at
            FROM camera_decode_status s
            JOIN cameras c ON c.id = s.camera_id
            ORDER BY c.name, s.camera_id
            ",
            &[],
        )
        .await
        .context("list_camera_decode_status")?;
    Ok(rows
        .into_iter()
        .map(|row| CameraDecodeStatus {
            camera_id: row.get("camera_id"),
            camera_name: row.get("camera_name"),
            requested: row.get("requested"),
            active: row.get("active"),
            fallback_reason: row.get("fallback_reason"),
            updated_at: row.get("updated_at"),
        })
        .collect())
}

// ─── motion RAM-cache telemetry (migration 0039) ──────────────────────────────

/// Upsert the global motion-cache filesystem report (singleton row, id = 1).
///
/// Called by the recorder's periodic motion-cache reporter (mirrors
/// `write_recorder_capabilities`'s upsert-on-tick pattern). Best-effort at the
/// call site: telemetry only, never blocks or fails recording.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn upsert_motion_cache_status(
    pool: &Pool,
    free_bytes: i64,
    total_bytes: i64,
    caching_active: bool,
    shadow_mode: bool,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO motion_cache_status (id, free_bytes, total_bytes, caching_active, shadow_mode, updated_at)
            VALUES (1, $1, $2, $3, $4, now())
            ON CONFLICT (id) DO UPDATE
                SET free_bytes     = EXCLUDED.free_bytes,
                    total_bytes    = EXCLUDED.total_bytes,
                    caching_active = EXCLUDED.caching_active,
                    shadow_mode    = EXCLUDED.shadow_mode,
                    updated_at     = now()
            ",
            &[&free_bytes, &total_bytes, &caching_active, &shadow_mode],
        )
        .await
        .context("upsert_motion_cache_status")?;
    Ok(())
}

/// Read the global motion-cache filesystem report (singleton row, id = 1).
///
/// Returns `None` when the recorder has never reported this tick (older
/// recorder image, not booted yet, or no Motion-mode camera has ever
/// resolved a cache dir) — the API surfaces that as `null`, which the UI
/// renders as "no cache telemetry yet", not as zero usage.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn read_motion_cache_status(pool: &Pool) -> Result<Option<MotionCacheStatus>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT free_bytes, total_bytes, caching_active, shadow_mode, updated_at
             FROM motion_cache_status WHERE id = 1",
            &[],
        )
        .await
        .context("read_motion_cache_status")?;
    Ok(opt.map(|row| MotionCacheStatus {
        free_bytes: row.get("free_bytes"),
        total_bytes: row.get("total_bytes"),
        caching_active: row.get("caching_active"),
        shadow_mode: row.get("shadow_mode"),
        updated_at: row.get("updated_at"),
    }))
}

/// Upsert one Motion-mode camera's RAM ring-buffer occupancy.
///
/// Called by the recorder's periodic motion-cache reporter, once per
/// Motion-mode camera. When the cache is inactive/fallen-back for that
/// camera, callers still upsert a row with `ring_segments = 0, ring_bytes = 0`
/// (the camera IS Motion-mode; it just has nothing buffered right now) rather
/// than omitting the row, so the UI can distinguish "0 buffered" from "never
/// reported".
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn upsert_camera_motion_cache_status(
    pool: &Pool,
    camera_id: Uuid,
    ring_segments: i32,
    ring_bytes: i64,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO camera_motion_cache_status (camera_id, ring_segments, ring_bytes, updated_at)
            VALUES ($1, $2, $3, now())
            ON CONFLICT (camera_id) DO UPDATE
                SET ring_segments = EXCLUDED.ring_segments,
                    ring_bytes    = EXCLUDED.ring_bytes,
                    updated_at    = now()
            ",
            &[&camera_id, &ring_segments, &ring_bytes],
        )
        .await
        .context("upsert_camera_motion_cache_status")?;
    Ok(())
}

/// Delete one camera's motion-cache-status row.
///
/// Called by the supervisor when it stops the worker of a disabled/removed
/// camera, or when a camera's mode flips away from Motion, so the panel never
/// shows a stale ring occupancy for a camera no longer buffering in RAM.
/// (Camera deletion also cascades via the FK — this covers the disable/mode-
/// flip case.)
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn delete_camera_motion_cache_status(pool: &Pool, camera_id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "DELETE FROM camera_motion_cache_status WHERE camera_id = $1",
            &[&camera_id],
        )
        .await
        .context("delete_camera_motion_cache_status")?;
    Ok(())
}

/// List every Motion-mode camera's RAM ring-buffer occupancy (joined with
/// `cameras` for the display name), ordered by camera name for a stable UI.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn list_camera_motion_cache_status(pool: &Pool) -> Result<Vec<CameraMotionCacheStatus>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT s.camera_id, c.name AS camera_name,
                   s.ring_segments, s.ring_bytes, s.updated_at
            FROM camera_motion_cache_status s
            JOIN cameras c ON c.id = s.camera_id
            ORDER BY c.name, s.camera_id
            ",
            &[],
        )
        .await
        .context("list_camera_motion_cache_status")?;
    Ok(rows
        .into_iter()
        .map(|row| CameraMotionCacheStatus {
            camera_id: row.get("camera_id"),
            camera_name: row.get("camera_name"),
            ring_segments: row.get("ring_segments"),
            ring_bytes: row.get("ring_bytes"),
            updated_at: row.get("updated_at"),
        })
        .collect())
}

/// Just the `updated_at` of one camera's `camera_motion_cache_status` row —
/// the liveness heartbeat `check_camera_offline` uses for Motion-mode cameras
/// (crumb-api's `alerts.rs`). The recorder upserts this row on a ~45 s tick
/// (`MOTION_CACHE_STATUS_INTERVAL_SECS`) for every Motion-mode camera
/// regardless of whether it is actively caching segments right now — an idle
/// Motion camera (no motion, nothing being buffered) still gets a fresh row
/// every tick, which is exactly what makes this a reliable "the recorder's
/// worker for this camera is alive" signal even during long quiet stretches
/// (unlike [`camera_last_segment`], which goes stale by design when a Motion
/// camera is simply not seeing motion).
///
/// Returns `None` if the row is absent (recorder never reported for this
/// camera — e.g. it only just flipped to Motion mode, or predates 0039).
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn camera_motion_cache_status_updated_at(
    pool: &Pool,
    camera_id: Uuid,
) -> Result<Option<DateTime<Utc>>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT updated_at FROM camera_motion_cache_status WHERE camera_id = $1",
            &[&camera_id],
        )
        .await
        .context("camera_motion_cache_status_updated_at")?;
    Ok(opt.map(|row| row.get("updated_at")))
}

// ─── motion grid (motion tuner) ─────────────────────────────────────────────────

/// Ensure the `segments.motion_score` column exists (idempotent — the recorder
/// calls this at startup so the timeline motion-intensity histogram works without
/// a manual prod migration). Old rows get NULL → treated as 0 intensity.
pub async fn ensure_segments_motion_score_column(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute("ALTER TABLE segments ADD COLUMN IF NOT EXISTS motion_score real")
        .await
        .context("ensure_segments_motion_score_column")?;
    Ok(())
}

/// Ensure `recording_policies.motion_threshold` is a `real` FRACTION of frame
/// area (0..1) — the SAME unit as `motion_score` / `motion_grid.threshold` — and
/// NOT the legacy `integer` basis-points encoding (`30` = 0.30%).
///
/// Idempotent and SELF-GUARDING: the conversion `bp/10000` runs ONLY while the
/// column is still `integer`, so a re-run (or a fresh DB already on `real`) is a
/// no-op and never double-divides an already-fractional value. Old bp values
/// convert exactly: `30 → 0.0030`, `25 → 0.0025`, `13 → 0.0013`; NULL stays NULL.
pub async fn ensure_motion_threshold_fraction(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            DO $$
            BEGIN
              IF (SELECT data_type FROM information_schema.columns
                  WHERE table_name = 'recording_policies'
                    AND column_name = 'motion_threshold') = 'integer' THEN
                ALTER TABLE recording_policies
                  ALTER COLUMN motion_threshold TYPE real
                  USING (motion_threshold::real / 10000.0);
              END IF;
            END $$;
            ",
        )
        .await
        .context("ensure_motion_threshold_fraction")?;
    Ok(())
}

/// Ensure the per-camera SIZE-CAP columns exist on `recording_policies`
/// (idempotent — the recorder calls this at startup so the commercial-VMS-style
/// "retention time OR max size, whichever hits first" tiering works without a
/// manual prod migration). Both are nullable with no default, so `NULL` reads
/// back as "no size cap".
///
/// * `live_max_bytes`    — max BYTES of LIVE-stage footage to retain per camera.
/// * `archive_max_bytes` — max BYTES of ARCHIVE-stage footage to retain.
///
/// The recorder (not the API) bootstraps schema, so the recorder must be
/// deployed for these columns to appear before the API reads/writes them.
pub async fn ensure_policy_size_cap_columns(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS live_max_bytes    bigint;
            ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS archive_max_bytes bigint;
            ",
        )
        .await
        .context("ensure_policy_size_cap_columns")?;
    Ok(())
}

/// Ensure the per-policy ADVANCED storage-management columns exist on
/// `recording_policies` (idempotent; recorder bootstraps schema, the API also
/// calls it so a fresh DB is tolerated). All three are nullable with NO default,
/// so `NULL` reads back as "use the system default" and deploying with zero
/// operator action changes nothing about eviction (strictly opt-in per policy).
///
/// * `live_min_free_pct`          — fractional free-space floor override (0..1).
/// * `live_min_free_bytes`        — absolute free-space floor override (BYTES).
/// * `live_spill_low_water_bytes` — low-water spill buffer (BYTES) for batched,
///   hysteretic eviction (the live disk gets breathing room instead of nibbling
///   one segment at the cap boundary every tick).
pub async fn ensure_policy_advanced_storage_columns(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS live_min_free_pct          real;
            ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS live_min_free_bytes        bigint;
            ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS live_spill_low_water_bytes bigint;
            ",
        )
        .await
        .context("ensure_policy_advanced_storage_columns")?;
    Ok(())
}

/// Idempotently introduce **named, reusable** recording policies + **camera
/// groups** (with policy inheritance). Mirrors the runtime `ensure_*` pattern —
/// the recorder bootstraps schema, so the recorder runs this at startup (the API
/// also runs it so it tolerates a fresh DB).
///
/// The migration is strictly additive / non-destructive:
/// * `recording_policies.name` — adds a nullable label; backfills only the
///   single default row to `"Default"`. Every other (cloned per-camera) policy
///   keeps `name = NULL` ("custom").
/// * `cameras.policy_id` becomes nullable so a camera can INHERIT (NULL ⇒ its
///   group's policy, else the global default). Every existing camera already has
///   a non-NULL `policy_id`, so the `COALESCE` join keeps its exact current
///   policy — zero behaviour change.
/// * `camera_groups` / `camera_group_members` are created empty; with no groups,
///   inheritance is inert until an operator creates one.
/// * `one_group_per_camera` enforces a camera belongs to AT MOST ONE group.
///
/// Safe to re-run on every startup (`IF NOT EXISTS` / `IF EXISTS` / idempotent
/// `ALTER`s, and a backfill guarded by `name IS NULL`).
/// Advisory-lock key serializing the concurrent api+recorder startup calls to
/// [`ensure_named_policies_and_groups`]. Both processes boot at once on a fresh
/// install and run the SAME idempotent DDL; without serialization, concurrent
/// `ALTER TABLE` / `CREATE TABLE IF NOT EXISTS` on the same tables races and one
/// side fails with "tuple concurrently updated". Arbitrary fixed constant.
const ENSURE_POLICIES_LOCK_KEY: i64 = 917_342_001;

pub async fn ensure_named_policies_and_groups(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;

    // Serialize with the other startup caller (api ↔ recorder) via a session
    // advisory lock so the idempotent DDL never runs concurrently. Released
    // explicitly below — and automatically if the connection is dropped.
    client
        .execute("SELECT pg_advisory_lock($1)", &[&ENSURE_POLICIES_LOCK_KEY])
        .await
        .context("acquire ensure-policies advisory lock")?;

    // Run the work in an inner block, CAPTURING the result, so the advisory lock
    // is ALWAYS released before returning (no `?` early-return between the
    // lock and the unlock below).
    let result = async {
        client
            .batch_execute(
                r"
                -- 1. Named policies: add the label column + backfill the default.
                ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS name text;
                UPDATE recording_policies SET name = 'Default' WHERE is_default AND name IS NULL;

                -- 2. Allow a camera to inherit (NULL policy_id). Idempotent: DROP NOT
                --    NULL is a no-op if already nullable.
                ALTER TABLE cameras ALTER COLUMN policy_id DROP NOT NULL;

                -- 3. Camera groups + their (optional) shared policy.
                CREATE TABLE IF NOT EXISTS camera_groups (
                    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                    name       text NOT NULL,
                    policy_id  uuid REFERENCES recording_policies(id),
                    created_at timestamptz NOT NULL DEFAULT now()
                );

                -- 4. Group membership (cascades on group OR camera delete).
                CREATE TABLE IF NOT EXISTS camera_group_members (
                    group_id  uuid NOT NULL REFERENCES camera_groups(id)  ON DELETE CASCADE,
                    camera_id uuid NOT NULL REFERENCES cameras(id)        ON DELETE CASCADE,
                    PRIMARY KEY (group_id, camera_id)
                );

                -- 5. A camera belongs to AT MOST ONE recording group.
                CREATE UNIQUE INDEX IF NOT EXISTS one_group_per_camera
                    ON camera_group_members (camera_id);
                ",
            )
            .await
            .context("ensure_named_policies_and_groups")?;

        // Defense-in-depth: every INHERITING camera resolves its policy through the
        // COALESCE fallback `(SELECT id FROM recording_policies WHERE is_default)`.
        // `one_default_policy` (partial unique index) guarantees ≤ 1 such row; this
        // guards the dangerous states — >1 (ambiguous) or 0-defaults-while-cameras-exist,
        // which would make the policy JOIN in CAMERA_SELECT_SQL / the retention sweep
        // silently DROP every inheriting camera (recorder stops recording it, no error).
        // We deliberately stay quiet on a fresh/un-seeded DB (0 defaults, 0 cameras) so
        // first boot before `seed` runs doesn't cry wolf. Both callers log this
        // non-fatally, so a genuinely broken DB surfaces loudly without locking the
        // operator out of the API.
        let default_count: i64 = client
            .query_one(
                "SELECT COUNT(*)::bigint FROM recording_policies WHERE is_default",
                &[],
            )
            .await
            .context("count default recording policies")?
            .get(0);
        if default_count != 1 {
            let camera_count: i64 = client
                .query_one("SELECT COUNT(*)::bigint FROM cameras", &[])
                .await
                .context("count cameras")?
                .get(0);
            if default_count > 1 || camera_count > 0 {
                anyhow::bail!(
                    "expected exactly one default recording policy (is_default = true), found \
                     {default_count} with {camera_count} camera(s) — inheriting cameras would \
                     silently stop recording; run `seed` to (re)create the default policy"
                );
            }
        }
        Ok::<(), anyhow::Error>(())
    }
    .await;

    // Release the advisory lock (best-effort) regardless of the outcome above.
    let _ = client
        .execute(
            "SELECT pg_advisory_unlock($1)",
            &[&ENSURE_POLICIES_LOCK_KEY],
        )
        .await;

    result
}

/// The leading edge (start) of the next/previous MOTION EVENT for `camera_id`
/// relative to `from`, searched across ALL recorded history (not a client window)
/// — this is what lets the prev/next-motion buttons reach events off the current
/// timeline zoom.
///
/// A motion event is a run of segments whose `motion_score` is at/above the
/// timeline ribbon floor (`0.004`, matching the desktop's `TL_MOTION_ABS`); its
/// START is a motion segment NOT preceded within 8 s by another motion segment.
/// `next = true` → the first event start strictly after `from`. `next = false` →
/// the event start strictly before the one the playhead is currently in, so "prev"
/// reaches the EARLIER event instead of restarting the current one. Returns `None`
/// when there is no such event. `ORDER BY … LIMIT 1` lets Postgres walk the
/// `(camera_id, start_ts)` index and stop at the first match.
pub async fn motion_event_edge(
    pool: &Pool,
    camera_id: Uuid,
    from: DateTime<Utc>,
    next: bool,
) -> Result<Option<DateTime<Utc>>> {
    let client = get_conn(pool).await?;
    let sql = if next {
        r"
        SELECT s.start_ts FROM segments s
        WHERE s.camera_id = $1 AND s.motion_score >= 0.004 AND s.start_ts > $2
          AND NOT EXISTS (
            SELECT 1 FROM segments p
            WHERE p.camera_id = s.camera_id AND p.motion_score >= 0.004
              AND p.start_ts < s.start_ts AND p.end_ts >= s.start_ts - INTERVAL '8 seconds')
        ORDER BY s.start_ts ASC
        LIMIT 1
        "
    } else {
        r"
        SELECT s.start_ts FROM segments s
        WHERE s.camera_id = $1 AND s.motion_score >= 0.004
          AND s.start_ts < (
            SELECT c.start_ts FROM segments c
            WHERE c.camera_id = $1 AND c.motion_score >= 0.004 AND c.start_ts <= $2
              AND NOT EXISTS (
                SELECT 1 FROM segments p
                WHERE p.camera_id = c.camera_id AND p.motion_score >= 0.004
                  AND p.start_ts < c.start_ts AND p.end_ts >= c.start_ts - INTERVAL '8 seconds')
            ORDER BY c.start_ts DESC LIMIT 1)
          AND NOT EXISTS (
            SELECT 1 FROM segments p
            WHERE p.camera_id = s.camera_id AND p.motion_score >= 0.004
              AND p.start_ts < s.start_ts AND p.end_ts >= s.start_ts - INTERVAL '8 seconds')
        ORDER BY s.start_ts DESC
        LIMIT 1
        "
    };
    let row = client
        .query_opt(sql, &[&camera_id, &from])
        .await
        .context("motion_event_edge")?;
    Ok(row.map(|r| r.get::<_, DateTime<Utc>>(0)))
}

/// Bucketed motion-intensity series for one camera over `[start, end)`.
///
/// Returns `n` buckets, each the MAX `motion_score` (0..1) of any segment
/// overlapping that bucket's time slice — the data behind the timeline's
/// per-camera activity histogram. Buckets with no footage are 0.0.
pub async fn motion_intensity_buckets(
    pool: &Pool,
    camera_id: Uuid,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    n: usize,
) -> Result<Vec<f32>> {
    let n = n.clamp(1, 4096);
    let mut buckets = vec![0.0_f32; n];
    if end <= start {
        return Ok(buckets);
    }
    let span_ms = (end - start).num_milliseconds().max(1) as f64;

    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT start_ts, end_ts, COALESCE(motion_score, 0.0) AS motion_score
            FROM segments
            WHERE camera_id = $1
              AND start_ts < $3
              AND end_ts   > $2
            ",
            &[&camera_id, &start, &end],
        )
        .await
        .context("motion_intensity_buckets")?;

    for row in &rows {
        let s: DateTime<Utc> = row.get("start_ts");
        let e: DateTime<Utc> = row.get("end_ts");
        let score: f32 = row.get("motion_score");
        // Map the segment's overlap with [start,end) onto bucket indices.
        let s_off = ((s - start).num_milliseconds() as f64).max(0.0);
        let e_off = ((e - start).num_milliseconds() as f64).min(span_ms);
        if e_off <= s_off {
            continue;
        }
        let b0 = ((s_off / span_ms) * n as f64).floor() as usize;
        let b1 = (((e_off / span_ms) * n as f64).ceil() as usize).min(n);
        for bucket in &mut buckets[b0..b1] {
            if score > *bucket {
                *bucket = score;
            }
        }
    }
    Ok(buckets)
}

/// Ensure the `motion_grid` table exists (idempotent — the recorder calls this
/// at startup so the tuner works without a manual migration).
pub async fn ensure_motion_grid_table(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            CREATE TABLE IF NOT EXISTS motion_grid (
                camera_id  uuid PRIMARY KEY REFERENCES cameras(id) ON DELETE CASCADE,
                updated_at timestamptz NOT NULL DEFAULT now(),
                cols       smallint NOT NULL,
                rows       smallint NOT NULL,
                cells      jsonb NOT NULL DEFAULT '[]'::jsonb,
                score      real NOT NULL DEFAULT 0,
                threshold  real NOT NULL DEFAULT 0
            );
            -- Live largest-blob score + effective threshold (0..1 fraction of the
            -- frame) so the tuner meter, threshold marker, recording trigger, and
            -- timeline are all the SAME quantity. Added idempotently for tables
            -- created before the motion-detection redesign.
            ALTER TABLE motion_grid ADD COLUMN IF NOT EXISTS score     real NOT NULL DEFAULT 0;
            ALTER TABLE motion_grid ADD COLUMN IF NOT EXISTS threshold real NOT NULL DEFAULT 0;
            ",
        )
        .await
        .context("ensure_motion_grid_table")?;
    Ok(())
}

/// Upsert the latest motion grid for a camera (called by the recorder, throttled).
///
/// `score` is the current frame's largest-blob-area fraction (0..1) and
/// `threshold` is the effective floor it is compared against — the same quantity
/// in both, so the tuner can render a coherent meter + threshold marker.
pub async fn write_motion_grid(
    pool: &Pool,
    camera_id: Uuid,
    cols: i16,
    rows: i16,
    cells: &serde_json::Value,
    score: f32,
    threshold: f32,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO motion_grid (camera_id, updated_at, cols, rows, cells, score, threshold)
            VALUES ($1, now(), $2, $3, $4, $5, $6)
            ON CONFLICT (camera_id) DO UPDATE
                SET updated_at = now(), cols = EXCLUDED.cols,
                    rows = EXCLUDED.rows, cells = EXCLUDED.cells,
                    score = EXCLUDED.score, threshold = EXCLUDED.threshold
            ",
            &[&camera_id, &cols, &rows, cells, &score, &threshold],
        )
        .await
        .context("write_motion_grid")?;
    Ok(())
}

/// Read the latest motion grid for a camera (served by the API to the tuner).
pub async fn read_motion_grid(pool: &Pool, camera_id: Uuid) -> Result<Option<MotionGrid>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT cols, rows, cells, score, threshold, updated_at \
             FROM motion_grid WHERE camera_id = $1",
            &[&camera_id],
        )
        .await
        .context("read_motion_grid")?;
    Ok(opt.map(|row| MotionGrid {
        cols: row.get("cols"),
        rows: row.get("rows"),
        cells: row.get("cells"),
        score: row.get("score"),
        threshold: row.get("threshold"),
        updated_at: row.get("updated_at"),
    }))
}

// ─── adaptive motion-threshold baseline ──────────────────────────────────────

/// Serialisable state of the per-camera adaptive motion-threshold learner.
///
/// Stored in `motion_baseline` as JSONB columns so the learner survives process
/// restarts with a warm histogram and diurnal profile.
///
/// * `hist`    — 64 f64 bucket weights (geometric over `[BLOB_FRACTION, MAX_THRESHOLD]`).
/// * `diurnal` — 24 f64 per-hour EMA values.
/// * `total`   — sum of all bucket weights.
#[derive(Debug, Clone)]
pub struct MotionBaselineState {
    pub hist: Vec<f64>,
    pub diurnal: Vec<f64>,
    pub total: f64,
}

/// Load the persisted adaptive-threshold baseline for `camera_id`.
///
/// Returns `Ok(None)` when no row exists yet (first run).
///
/// # Errors
///
/// Returns an error if the query fails or the stored JSONB cannot be parsed.
pub async fn load_motion_baseline(
    pool: &Pool,
    camera_id: Uuid,
) -> Result<Option<MotionBaselineState>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT hist, diurnal, total \
             FROM motion_baseline WHERE camera_id = $1",
            &[&camera_id],
        )
        .await
        .context("load_motion_baseline")?;

    let Some(row) = opt else {
        return Ok(None);
    };

    let hist_val: serde_json::Value = row.get("hist");
    let diurnal_val: serde_json::Value = row.get("diurnal");
    let total: f64 = row.get("total");

    let hist = hist_val
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("motion_baseline.hist is not a JSON array"))?
        .iter()
        .map(|v| v.as_f64().unwrap_or(0.0))
        .collect();

    let diurnal = diurnal_val
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("motion_baseline.diurnal is not a JSON array"))?
        .iter()
        .map(|v| v.as_f64().unwrap_or(0.003))
        .collect();

    Ok(Some(MotionBaselineState {
        hist,
        diurnal,
        total,
    }))
}

/// Upsert the adaptive-threshold baseline for `camera_id`.
///
/// Called from the motion loop every [`AT_PERSIST_SECS`] seconds (best-effort;
/// recording never blocks on this write).
///
/// # Errors
///
/// Returns an error if the upsert fails.
pub async fn upsert_motion_baseline(
    pool: &Pool,
    camera_id: Uuid,
    state: &MotionBaselineState,
) -> Result<()> {
    let client = get_conn(pool).await?;

    let hist_json = serde_json::Value::Array(
        state
            .hist
            .iter()
            .map(|&v| serde_json::Value::from(v))
            .collect(),
    );
    let diurnal_json = serde_json::Value::Array(
        state
            .diurnal
            .iter()
            .map(|&v| serde_json::Value::from(v))
            .collect(),
    );

    client
        .execute(
            r"
            INSERT INTO motion_baseline (camera_id, hist, diurnal, total, updated_at)
            VALUES ($1, $2, $3, $4, now())
            ON CONFLICT (camera_id) DO UPDATE
                SET hist       = EXCLUDED.hist,
                    diurnal    = EXCLUDED.diurnal,
                    total      = EXCLUDED.total,
                    updated_at = now()
            ",
            &[&camera_id, &hist_json, &diurnal_json, &state.total],
        )
        .await
        .context("upsert_motion_baseline")?;
    Ok(())
}

// ─── camera resource stats (per-camera CPU / mem / GPU sampler) ──────────────────

/// Ensure the `camera_resource_stats` table exists (idempotent — the recorder
/// calls this at startup, and the API also calls it defensively so
/// `GET /stats/cameras` degrades to zeros instead of 500 if the API ever starts
/// against a DB the recorder hasn't touched yet).
///
/// One row per camera holding the recorder's latest non-invasive sample of the
/// camera's ffmpeg children: CPU% (of one core), resident memory (MB), and a
/// best-effort GPU% (`NULL` when GPU telemetry is unavailable). `updated_at` lets
/// readers age out a stale sample.
pub async fn ensure_camera_resource_stats(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            CREATE TABLE IF NOT EXISTS camera_resource_stats (
                camera_id  uuid PRIMARY KEY REFERENCES cameras(id) ON DELETE CASCADE,
                cpu_pct    double precision NOT NULL DEFAULT 0,
                mem_mb     double precision NOT NULL DEFAULT 0,
                gpu_pct    double precision,
                updated_at timestamptz NOT NULL DEFAULT now()
            );
            ",
        )
        .await
        .context("ensure_camera_resource_stats")?;
    Ok(())
}

/// Upsert the latest resource sample for one camera (called by the recorder's
/// resource sampler, ~every 10 s).
///
/// `cpu_pct` is the sum of the camera's ffmpeg children's CPU usage (% of one
/// core), `mem_mb` their summed resident memory, and `gpu_pct` the best-effort GPU
/// utilisation attributed to the camera's decode (`None` when GPU telemetry is
/// unavailable). `updated_at` is set to `now()` on every write so readers can age
/// out stale samples.
pub async fn upsert_camera_resource_stats(
    pool: &Pool,
    camera_id: Uuid,
    cpu_pct: f64,
    mem_mb: f64,
    gpu_pct: Option<f64>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO camera_resource_stats (camera_id, cpu_pct, mem_mb, gpu_pct, updated_at)
            VALUES ($1, $2, $3, $4, now())
            ON CONFLICT (camera_id) DO UPDATE
                SET cpu_pct = EXCLUDED.cpu_pct,
                    mem_mb  = EXCLUDED.mem_mb,
                    gpu_pct = EXCLUDED.gpu_pct,
                    updated_at = now()
            ",
            &[&camera_id, &cpu_pct, &mem_mb, &gpu_pct],
        )
        .await
        .context("upsert_camera_resource_stats")?;
    Ok(())
}

// ─── schema helpers ──────────────────────────────────────────────────────────

// ─── detection events schema ──────────────────────────────────────────────────

/// Ensure the detection-event schema columns exist on the `cameras` and
/// `events` tables (idempotent — uses `ADD COLUMN IF NOT EXISTS`).
///
/// Called at API startup so the system self-heals on a DB that was initialised
/// before migration 0007 was applied, mirroring the pattern used by
/// [`ensure_motion_grid_table`] and [`ensure_segments_motion_score_column`].
///
/// The columns match those in `db/migrations/0007_detection_events.sql` exactly.
/// The deduplication index and query indexes are also created idempotently.
///
/// # Errors
///
/// Returns an error if any DDL statement fails (e.g. permission denied, or the
/// `events` table itself does not yet exist).
pub async fn ensure_detection_columns(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE cameras
                ADD COLUMN IF NOT EXISTS source_camera_name TEXT;

            ALTER TABLE events
                ADD COLUMN IF NOT EXISTS source_id            TEXT,
                ADD COLUMN IF NOT EXISTS provider_event_id    TEXT,
                ADD COLUMN IF NOT EXISTS sub_label            TEXT,
                ADD COLUMN IF NOT EXISTS top_score            REAL,
                ADD COLUMN IF NOT EXISTS end_ts               TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS bbox_x1              REAL,
                ADD COLUMN IF NOT EXISTS bbox_y1              REAL,
                ADD COLUMN IF NOT EXISTS bbox_x2              REAL,
                ADD COLUMN IF NOT EXISTS bbox_y2              REAL,
                ADD COLUMN IF NOT EXISTS zones                TEXT[],
                ADD COLUMN IF NOT EXISTS snapshot_url         TEXT,
                ADD COLUMN IF NOT EXISTS raw                  JSONB,
                ADD COLUMN IF NOT EXISTS lifecycle            TEXT
                    CHECK (lifecycle IS NULL OR lifecycle IN ('start','update','end'));

            CREATE UNIQUE INDEX IF NOT EXISTS events_provider_dedup
                ON events (source_id, provider_event_id)
                WHERE source_id IS NOT NULL;

            CREATE INDEX IF NOT EXISTS events_camera_ts
                ON events (camera_id, ts);

            CREATE INDEX IF NOT EXISTS events_camera_label_ts
                ON events (camera_id, label, ts);
            ",
        )
        .await
        .context("ensure_detection_columns")?;
    Ok(())
}

/// Ensure the per-camera motion-source / motion-algorithm columns exist
/// (idempotent — `ADD COLUMN IF NOT EXISTS`). Defaults preserve current
/// behaviour exactly: `motion_source = 'pixel'` (the local analysis pipeline)
/// and `motion_algorithm = 'census'` (the byte-identical default detector). Part
/// of the pluggable-motion design (Stage 4). Called at both recorder and API
/// startup so whichever boots first applies it.
///
/// # Errors
///
/// Returns an error if the DDL fails (e.g. permission denied or `cameras` absent).
pub async fn ensure_motion_source_columns(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE cameras
                ADD COLUMN IF NOT EXISTS motion_source    TEXT NOT NULL DEFAULT 'pixel',
                ADD COLUMN IF NOT EXISTS motion_algorithm TEXT NOT NULL DEFAULT 'census';
            ",
        )
        .await
        .context("ensure_motion_source_columns")?;
    Ok(())
}

/// Ensure the per-camera `camera_type` column exists (idempotent —
/// `ADD COLUMN IF NOT EXISTS`). NULLABLE with no default: a NULL `camera_type`
/// is treated as `'other'` by the UI, so existing rows keep today's generic
/// glyph until an operator picks a type. Drives the per-camera tree/header icon
/// in the admin console; the recorder ignores it. Accepted values are
/// `'ptz' | 'dome' | 'bullet' | 'lpr' | 'other'` (validated/normalised by the
/// API; a CHECK constraint guards direct DB writes). Called at both API and
/// recorder startup so whichever boots first applies it.
///
/// # Errors
///
/// Returns an error if the DDL fails (e.g. permission denied or `cameras` absent).
pub async fn ensure_camera_type_column(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE cameras
                ADD COLUMN IF NOT EXISTS camera_type TEXT
                    CHECK (camera_type IS NULL
                           OR camera_type IN ('ptz','dome','bullet','lpr','other'));
            ",
        )
        .await
        .context("ensure_camera_type_column")?;
    Ok(())
}

/// Ensure the per-camera `icon` override column exists (idempotent —
/// `ADD COLUMN IF NOT EXISTS`). NULLABLE with no default: a NULL `icon` means
/// "derive the glyph from `camera_type`", so existing rows keep today's behaviour.
/// Stores a glyph key (`'cam_ptz' | 'cam_dome' | 'cam_bullet' | 'cam_lpr' |
/// 'cam_other'`), validated/normalised by the API; a CHECK constraint guards
/// direct DB writes. Console/clients render `icon ?? glyph_for(camera_type)`.
/// Shares `CAMERA_SELECT_SQL` (which now selects the column) with the recorder, so
/// whichever process boots first must add it.
///
/// # Errors
///
/// Returns an error if the DDL fails (e.g. permission denied or `cameras` absent).
pub async fn ensure_cameras_icon_column(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE cameras
                ADD COLUMN IF NOT EXISTS icon TEXT
                    CHECK (icon IS NULL
                           OR icon IN ('cam_ptz','cam_dome','cam_bullet','cam_lpr','cam_other'));
            ",
        )
        .await
        .context("ensure_cameras_icon_column")?;
    Ok(())
}

/// Ensure the per-storage `icon` override column exists (idempotent —
/// `ADD COLUMN IF NOT EXISTS`). NULLABLE with no default: a NULL `icon` means
/// "infer the media glyph from the name" (NVMe→SSD, Spinner→HDD, …), so existing
/// rows keep today's behaviour. Stores a kind (`'ssd' | 'hdd' | 'disk'`),
/// validated/normalised by the API; a CHECK constraint guards direct DB writes.
/// Every storage SELECT now reads the column, so whichever of the API/recorder
/// boots first must add it.
///
/// # Errors
///
/// Returns an error if the DDL fails (e.g. permission denied or `storages` absent).
pub async fn ensure_storages_icon_column(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE storages
                ADD COLUMN IF NOT EXISTS icon TEXT
                    CHECK (icon IS NULL OR icon IN ('ssd','hdd','disk'));
            ",
        )
        .await
        .context("ensure_storages_icon_column")?;
    Ok(())
}

/// Ensure the per-camera motion-tuner grid-size columns exist (idempotent —
/// `ADD COLUMN IF NOT EXISTS`). NULLABLE with no default: NULL ⇒ the client's
/// default authoring grid (16×9). These persist the operator's chosen
/// exclusion-zone *authoring* resolution in the motion tuner so it reopens at the
/// grid they last picked, per camera; the recorder ignores them (its analysis
/// grid is fixed at 80×45). CHECK keeps values in a sane 1..=256 range. Both
/// camera SELECTs read these, so whichever of the API/recorder boots first must
/// add them.
///
/// # Errors
///
/// Returns an error if the DDL fails (e.g. permission denied or `cameras` absent).
pub async fn ensure_cameras_motion_grid_columns(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE cameras
                ADD COLUMN IF NOT EXISTS motion_grid_cols SMALLINT
                    CHECK (motion_grid_cols IS NULL
                           OR (motion_grid_cols >= 1 AND motion_grid_cols <= 256));
            ALTER TABLE cameras
                ADD COLUMN IF NOT EXISTS motion_grid_rows SMALLINT
                    CHECK (motion_grid_rows IS NULL
                           OR (motion_grid_rows >= 1 AND motion_grid_rows <= 256));
            ",
        )
        .await
        .context("ensure_cameras_motion_grid_columns")?;
    Ok(())
}

/// Ensure the `segments.storage_id` foreign key is `ON DELETE RESTRICT` (A2).
///
/// A segment's physical location is defined SOLELY by its `storage_id` (→
/// `storages.path`). The DB-level backstop for that invariant is that a storage
/// row referenced by footage CANNOT be deleted out from under it. The admin
/// `delete_storage` handler already refuses when segments reference a storage;
/// this enforces the same rule at the database so a direct/erroneous delete also
/// fails loudly instead of orphaning footage (or, with a CASCADE, silently
/// deleting the index rows).
///
/// Idempotent: looks up the EXISTING FK on `segments.storage_id` (whatever its
/// auto-generated name), inspects its delete-rule, and only drops + recreates it
/// as `ON DELETE RESTRICT` when it is not already RESTRICT. A no-op on a DB that
/// already has the right rule. Called at both API and recorder startup so
/// whichever boots first applies it.
///
/// # Errors
///
/// Returns an error if the catalog query or DDL fails (e.g. permission denied or
/// `segments` absent).
pub async fn ensure_segments_storage_fk_restrict(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;

    // Find the FK constraint on segments.storage_id and its delete-rule. We match
    // by the referencing table+column rather than a hard-coded name so this works
    // regardless of how the constraint was originally named.
    let row = client
        .query_opt(
            r"
            SELECT con.conname,
                   con.confdeltype
            FROM pg_constraint con
            JOIN pg_class      rel ON rel.oid = con.conrelid
            JOIN pg_namespace  nsp ON nsp.oid = rel.relnamespace
            JOIN pg_attribute  att ON att.attrelid = con.conrelid
                                  AND att.attnum = con.conkey[1]
            WHERE con.contype = 'f'
              AND rel.relname = 'segments'
              AND att.attname = 'storage_id'
              AND nsp.nspname = current_schema()
            ",
            &[],
        )
        .await
        .context("ensure_segments_storage_fk_restrict: locate FK")?;

    let Some(row) = row else {
        // No FK present at all (unexpected for a real schema). Add it as RESTRICT.
        client
            .batch_execute(
                r"
                ALTER TABLE segments
                    ADD CONSTRAINT segments_storage_id_fkey
                    FOREIGN KEY (storage_id) REFERENCES storages(id) ON DELETE RESTRICT;
                ",
            )
            .await
            .context("ensure_segments_storage_fk_restrict: add missing FK")?;
        return Ok(());
    };

    let conname: String = row.get(0);
    // pg_constraint.confdeltype: 'a' = NO ACTION, 'r' = RESTRICT, 'c' = CASCADE,
    // 'n' = SET NULL, 'd' = SET DEFAULT. We want 'r'.
    let confdeltype: i8 = row.get(1);
    if confdeltype == b'r' as i8 {
        // Already ON DELETE RESTRICT — nothing to do.
        return Ok(());
    }

    // Drop the existing FK and recreate it as ON DELETE RESTRICT. The constraint
    // name is quoted via format!; conname comes from the catalog (trusted), not
    // user input.
    let ddl = format!(
        r#"
        ALTER TABLE segments DROP CONSTRAINT "{conname}";
        ALTER TABLE segments
            ADD CONSTRAINT segments_storage_id_fkey
            FOREIGN KEY (storage_id) REFERENCES storages(id) ON DELETE RESTRICT;
        "#
    );
    client
        .batch_execute(&ddl)
        .await
        .context("ensure_segments_storage_fk_restrict: swap FK to ON DELETE RESTRICT")?;
    Ok(())
}

// ─── clips feature ────────────────────────────────────────────────────────────

/// A camera's name + its per-camera clip-source override (Clips feature).
/// `clip_source` is `None` when the camera follows the global default.
#[derive(Debug, Clone)]
pub struct ClipCamera {
    pub id: Uuid,
    pub name: String,
    pub clip_source: Option<String>,
}

/// Fetch `(id, name, clip_source)` for the given cameras (Clips feature).
///
/// Empty input → empty result. Cameras not found are simply absent.
pub async fn list_clip_cameras(pool: &Pool, camera_ids: &[Uuid]) -> Result<Vec<ClipCamera>> {
    if camera_ids.is_empty() {
        return Ok(vec![]);
    }
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT id, name, clip_source FROM cameras WHERE id = ANY($1)",
            &[&camera_ids],
        )
        .await
        .context("list_clip_cameras")?;
    Ok(rows
        .iter()
        .map(|r| ClipCamera {
            id: r.get("id"),
            name: r.get("name"),
            clip_source: r.get("clip_source"),
        })
        .collect())
}

/// The deployment-wide default clip source (`"crumb"` | `"frigate"`).
///
/// Returns `"crumb"` when unset, blank, or no settings row exists — so the Clips
/// feature works with zero Frigate dependency by default.
pub async fn get_default_clip_source(pool: &Pool) -> Result<String> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT default_clip_source FROM server_settings LIMIT 1",
            &[],
        )
        .await
        .context("get_default_clip_source")?;
    Ok(row
        .and_then(|r| r.try_get::<_, String>("default_clip_source").ok())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "crumb".to_owned()))
}

/// Set a camera's per-camera clip-source override (`Some("frigate")`/`Some("crumb")`,
/// or `None` to follow the global default).
pub async fn update_camera_clip_source(
    pool: &Pool,
    camera_id: Uuid,
    source: Option<&str>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE cameras SET clip_source = $2 WHERE id = $1",
            &[&camera_id, &source],
        )
        .await
        .context("update_camera_clip_source")?;
    Ok(())
}

/// Read a camera's stored ONVIF device identity `(make, model, firmware)`; any
/// field may be `None` (camera never identified, or added by raw RTSP URL with
/// no ONVIF). See migration 0047 and `services/api/src/camera_compat.rs`.
pub async fn get_camera_device_info(
    pool: &Pool,
    camera_id: Uuid,
) -> Result<(Option<String>, Option<String>, Option<String>)> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT make, model, firmware FROM cameras WHERE id = $1",
            &[&camera_id],
        )
        .await
        .context("get_camera_device_info")?;
    Ok(match row {
        Some(r) => (r.get(0), r.get(1), r.get(2)),
        None => (None, None, None),
    })
}

/// Persist a camera's ONVIF device identity. A `None` field leaves the existing
/// column unchanged (`COALESCE`), so a partial ONVIF probe never wipes a
/// previously-known value.
pub async fn set_camera_device_info(
    pool: &Pool,
    camera_id: Uuid,
    make: Option<&str>,
    model: Option<&str>,
    firmware: Option<&str>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE cameras SET make = COALESCE($2, make), model = COALESCE($3, model), \
             firmware = COALESCE($4, firmware) WHERE id = $1",
            &[&camera_id, &make, &model, &firmware],
        )
        .await
        .context("set_camera_device_info")?;
    Ok(())
}

/// Server-configurable clip pre-roll in seconds (footage before the event a clip
/// starts at). Clamped to 0..=9; defaults to 2 when unset/out of range.
pub async fn get_clip_pre_roll_seconds(pool: &Pool) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT clip_pre_roll_seconds FROM server_settings LIMIT 1",
            &[],
        )
        .await
        .context("get_clip_pre_roll_seconds")?;
    let secs = row
        .and_then(|r| r.try_get::<_, i32>("clip_pre_roll_seconds").ok())
        .map_or(2_i64, i64::from);
    Ok(secs.clamp(0, 9))
}

/// Set the clip pre-roll (seconds). Clamped to 0..=9 before storing.
pub async fn set_clip_pre_roll_seconds(pool: &Pool, seconds: i64) -> Result<()> {
    let client = get_conn(pool).await?;
    let clamped = i32::try_from(seconds.clamp(0, 9)).unwrap_or(2);
    client
        .execute(
            "UPDATE server_settings SET clip_pre_roll_seconds = $1",
            &[&clamped],
        )
        .await
        .context("set_clip_pre_roll_seconds")?;
    Ok(())
}

/// Whether the first-run setup wizard has been completed. `false` (the column
/// default) on a fresh install makes the wizard show; migration 0027 backfills
/// `true` for installs that already had an admin user. Missing row ⇒ `false`.
pub async fn get_setup_complete(pool: &Pool) -> Result<bool> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt("SELECT setup_complete FROM server_settings LIMIT 1", &[])
        .await
        .context("get_setup_complete")?;
    Ok(row
        .and_then(|r| r.try_get::<_, bool>("setup_complete").ok())
        .unwrap_or(false))
}

/// Mark the first-run setup wizard complete (or re-open it with `false` so an
/// admin can re-run it from Server settings).
pub async fn set_setup_complete(pool: &Pool, complete: bool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE server_settings SET setup_complete = $1",
            &[&complete],
        )
        .await
        .context("set_setup_complete")?;
    Ok(())
}

/// Beta-terms acceptance status: `(accepted, version)`. `accepted` is false when
/// the operator has never accepted the tester terms; `version` is the terms
/// version they last accepted (empty string when never). Reads booleans/strings
/// only (no chrono dependency) — callers compare `version` to the current
/// `BETA_TERMS_VERSION` (owned by the api crate) to decide whether a
/// re-acknowledgement is due.
pub async fn get_beta_terms_status(pool: &Pool) -> Result<(bool, String)> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT (beta_terms_accepted_at IS NOT NULL) AS accepted, \
             beta_terms_version FROM server_settings LIMIT 1",
            &[],
        )
        .await
        .context("get_beta_terms_status")?;
    Ok(match row {
        Some(r) => (
            r.try_get::<_, bool>("accepted").unwrap_or(false),
            r.try_get::<_, String>("beta_terms_version")
                .unwrap_or_default(),
        ),
        None => (false, String::new()),
    })
}

/// Record acceptance of the beta tester terms at `version`. Idempotent: the
/// original acceptance timestamp is preserved when re-recording the same
/// version, so calling this from more than one wizard step is safe; a *different*
/// version re-stamps `now()` so a materially-changed terms document is
/// re-acknowledged with a fresh timestamp.
pub async fn set_beta_terms_accepted(pool: &Pool, version: &str) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE server_settings \
             SET beta_terms_version = $1, \
                 beta_terms_accepted_at = CASE \
                     WHEN beta_terms_accepted_at IS NULL \
                       OR beta_terms_version IS DISTINCT FROM $1 \
                     THEN now() ELSE beta_terms_accepted_at END",
            &[&version],
        )
        .await
        .context("set_beta_terms_accepted")?;
    Ok(())
}

/// Server-configurable motion-highlight duration in seconds (clip player
/// auto-zooms to the motion region for this long; 0 = disabled). Clamped 0..=4,
/// default 2.
pub async fn get_clip_motion_highlight_seconds(pool: &Pool) -> Result<i64> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT clip_motion_highlight_seconds FROM server_settings LIMIT 1",
            &[],
        )
        .await
        .context("get_clip_motion_highlight_seconds")?;
    let secs = row
        .and_then(|r| r.try_get::<_, i32>("clip_motion_highlight_seconds").ok())
        .map_or(2_i64, i64::from);
    Ok(secs.clamp(0, 4))
}

/// Set the motion-highlight duration (seconds). Clamped to 0..=4 before storing.
pub async fn set_clip_motion_highlight_seconds(pool: &Pool, seconds: i64) -> Result<()> {
    let client = get_conn(pool).await?;
    let clamped = i32::try_from(seconds.clamp(0, 4)).unwrap_or(2);
    client
        .execute(
            "UPDATE server_settings SET clip_motion_highlight_seconds = $1",
            &[&clamped],
        )
        .await
        .context("set_clip_motion_highlight_seconds")?;
    Ok(())
}

/// Platform-wide bookmarks-UI toggle. When false, clients hide the bookmark
/// button(s). Defaults to true (also when the row/column is somehow absent).
pub async fn get_bookmarks_enabled(pool: &Pool) -> Result<bool> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt("SELECT bookmarks_enabled FROM server_settings LIMIT 1", &[])
        .await
        .context("get_bookmarks_enabled")?;
    Ok(row
        .and_then(|r| r.try_get::<_, bool>("bookmarks_enabled").ok())
        .unwrap_or(true))
}

/// Set the platform-wide bookmarks-UI toggle.
pub async fn set_bookmarks_enabled(pool: &Pool, enabled: bool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE server_settings SET bookmarks_enabled = $1",
            &[&enabled],
        )
        .await
        .context("set_bookmarks_enabled")?;
    Ok(())
}

/// Operator opt-in toggle for the update-available check (issue #7,
/// migration 0045). `None` means the operator has never touched this setting
/// — the caller (`services/api/src/updates.rs::resolve_enabled`) falls back to
/// the `UPDATE_CHECK_ENABLED` env default (off by default, D3). Unlike
/// [`get_bookmarks_enabled`], this is deliberately nullable rather than
/// defaulting in Rust: NULL must be distinguishable from an explicit `false`.
pub async fn get_update_check_enabled(pool: &Pool) -> Result<Option<bool>> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT update_check_enabled FROM server_settings LIMIT 1",
            &[],
        )
        .await
        .context("get_update_check_enabled")?;
    Ok(row
        .and_then(|r| r.try_get::<_, Option<bool>>("update_check_enabled").ok())
        .flatten())
}

/// Set the operator's explicit update-check opt-in/out (issue #7).
pub async fn set_update_check_enabled(pool: &Pool, enabled: bool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE server_settings SET update_check_enabled = $1",
            &[&enabled],
        )
        .await
        .context("set_update_check_enabled")?;
    Ok(())
}

// ─── scrub-preview runtime tunables (issue #10, migration 0046) ────────────────
//
// Admin-console overrides for the thumbnail pre-generation worker + cache
// sweeper. Each field is `None` when the operator has never touched it in the
// console — the caller (`services/api/src/scrub_settings.rs::resolve`) falls
// back to the corresponding `THUMB_*` env default, same nullable-column
// precedence as `update_check_enabled` above. `THUMB_PREGEN_WIDTH` is
// deliberately NOT here (ratified D1): it stays env-only, see migration
// 0046's comment and `docs/DECISIONS.md`.

/// Raw `server_settings` overrides for the five scrub-preview knobs. `None` in
/// any field means "never set in the console" — the resolver falls back to
/// the matching `ApiConfig` env default.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ScrubPregenOverrides {
    pub pregen_enabled: Option<bool>,
    pub pregen_lookback_hours: Option<i64>,
    pub pregen_scan_secs: Option<i64>,
    pub cache_max_bytes: Option<i64>,
    pub cache_ttl_seconds: Option<i64>,
}

/// Fetch all five scrub-preview overrides in one `server_settings` row read.
pub async fn get_scrub_pregen_settings(pool: &Pool) -> Result<ScrubPregenOverrides> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT thumb_pregen_enabled, thumb_pregen_lookback_hours, \
             thumb_pregen_scan_secs, thumb_cache_max_bytes, thumb_cache_ttl_seconds \
             FROM server_settings LIMIT 1",
            &[],
        )
        .await
        .context("get_scrub_pregen_settings")?;
    Ok(match row {
        Some(r) => ScrubPregenOverrides {
            pregen_enabled: r
                .try_get::<_, Option<bool>>("thumb_pregen_enabled")
                .ok()
                .flatten(),
            pregen_lookback_hours: r
                .try_get::<_, Option<i32>>("thumb_pregen_lookback_hours")
                .ok()
                .flatten()
                .map(i64::from),
            pregen_scan_secs: r
                .try_get::<_, Option<i32>>("thumb_pregen_scan_secs")
                .ok()
                .flatten()
                .map(i64::from),
            cache_max_bytes: r
                .try_get::<_, Option<i64>>("thumb_cache_max_bytes")
                .ok()
                .flatten(),
            cache_ttl_seconds: r
                .try_get::<_, Option<i64>>("thumb_cache_ttl_seconds")
                .ok()
                .flatten(),
        },
        None => ScrubPregenOverrides::default(),
    })
}

/// Set the pre-generation worker's enabled override.
pub async fn set_thumb_pregen_enabled(pool: &Pool, enabled: bool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE server_settings SET thumb_pregen_enabled = $1",
            &[&enabled],
        )
        .await
        .context("set_thumb_pregen_enabled")?;
    Ok(())
}

/// Set the pre-generation backfill lookback (hours). Clamped to 0..=168 (a
/// week) before storing — larger backfills belong in the env var, where the
/// operator has read the cost note in `config.rs`.
pub async fn set_thumb_pregen_lookback_hours(pool: &Pool, hours: i64) -> Result<()> {
    let client = get_conn(pool).await?;
    let clamped = i32::try_from(hours.clamp(0, 168)).unwrap_or(2);
    client
        .execute(
            "UPDATE server_settings SET thumb_pregen_lookback_hours = $1",
            &[&clamped],
        )
        .await
        .context("set_thumb_pregen_lookback_hours")?;
    Ok(())
}

/// Set the pre-generation worker's scan interval (seconds). Clamped to
/// 5..=3600, matching the existing env floor.
pub async fn set_thumb_pregen_scan_secs(pool: &Pool, secs: i64) -> Result<()> {
    let client = get_conn(pool).await?;
    let clamped = i32::try_from(secs.clamp(5, 3600)).unwrap_or(60);
    client
        .execute(
            "UPDATE server_settings SET thumb_pregen_scan_secs = $1",
            &[&clamped],
        )
        .await
        .context("set_thumb_pregen_scan_secs")?;
    Ok(())
}

/// Set the thumbnail cache byte budget. Floored at 100 MiB (D5) — a
/// near-zero budget would make the sweeper delete every thumbnail every
/// minute, silently defeating the feature.
pub async fn set_thumb_cache_max_bytes(pool: &Pool, bytes: i64) -> Result<()> {
    let client = get_conn(pool).await?;
    let clamped = bytes.max(104_857_600);
    client
        .execute(
            "UPDATE server_settings SET thumb_cache_max_bytes = $1",
            &[&clamped],
        )
        .await
        .context("set_thumb_cache_max_bytes")?;
    Ok(())
}

/// Set the thumbnail cache max age (seconds). Clamped to 1 hour..=1 year.
pub async fn set_thumb_cache_ttl_seconds(pool: &Pool, secs: i64) -> Result<()> {
    let client = get_conn(pool).await?;
    let clamped = secs.clamp(3600, 31_536_000);
    client
        .execute(
            "UPDATE server_settings SET thumb_cache_ttl_seconds = $1",
            &[&clamped],
        )
        .await
        .context("set_thumb_cache_ttl_seconds")?;
    Ok(())
}

/// Set the deployment-wide default clip source (`"crumb"` | `"frigate"`).
pub async fn set_default_clip_source(pool: &Pool, source: &str) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE server_settings SET default_clip_source = $1",
            &[&source],
        )
        .await
        .context("set_default_clip_source")?;
    Ok(())
}

/// Every camera's `(id, name, clip_source)` for the Clips source picker.
pub async fn all_clip_cameras(pool: &Pool) -> Result<Vec<ClipCamera>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT id, name, clip_source FROM cameras ORDER BY name",
            &[],
        )
        .await
        .context("all_clip_cameras")?;
    Ok(rows
        .iter()
        .map(|r| ClipCamera {
            id: r.get("id"),
            name: r.get("name"),
            clip_source: r.get("clip_source"),
        })
        .collect())
}

/// Mark a clip as viewed by a user (idempotent). Backs the Clips feed's
/// "watched" dimming. `clip_id` is the opaque Clips handle.
pub async fn mark_clip_viewed(pool: &Pool, user_id: Uuid, clip_id: &str) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "INSERT INTO clip_views (user_id, clip_id) VALUES ($1, $2)
             ON CONFLICT (user_id, clip_id) DO NOTHING",
            &[&user_id, &clip_id],
        )
        .await
        .context("mark_clip_viewed")?;
    Ok(())
}

/// The subset of `clip_ids` this user has already viewed. Used to stamp the
/// `viewed` flag on a `/clips` response in one round-trip.
pub async fn viewed_clip_ids(
    pool: &Pool,
    user_id: Uuid,
    clip_ids: &[String],
) -> Result<std::collections::HashSet<String>> {
    if clip_ids.is_empty() {
        return Ok(std::collections::HashSet::new());
    }
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT clip_id FROM clip_views WHERE user_id = $1 AND clip_id = ANY($2)",
            &[&user_id, &clip_ids],
        )
        .await
        .context("viewed_clip_ids")?;
    Ok(rows.iter().map(|r| r.get::<_, String>("clip_id")).collect())
}

/// `(provider_event_id, source_id)` for a detection event — for the Frigate clip
/// media proxy. Either field may be `None`.
pub async fn get_event_provider(
    pool: &Pool,
    event_id: Uuid,
) -> Result<Option<(Option<String>, Option<String>)>> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT provider_event_id, source_id FROM events WHERE id = $1",
            &[&event_id],
        )
        .await
        .context("get_event_provider")?;
    Ok(row.map(|r| (r.get("provider_event_id"), r.get("source_id"))))
}

/// The Frigate HTTP API base for proxying event media (clips/snapshots), resolved
/// from the admin-editable DB settings: `server_settings.frigate_http_api_base`,
/// then the legacy `frigate_api_base`, then the Frigate-integration `api_base`.
/// Returns `None` when nothing is configured — callers fall back to the
/// `FRIGATE_API_BASE` env.
pub async fn frigate_http_base(pool: &Pool) -> Result<Option<String>> {
    if let Some(s) = get_server_settings(pool).await? {
        let http = s.frigate_http_api_base.trim().to_owned();
        if !http.is_empty() {
            return Ok(Some(http));
        }
        let legacy = s.frigate_api_base.trim().to_owned();
        if !legacy.is_empty() {
            return Ok(Some(legacy));
        }
    }
    if let Some(f) = get_frigate_settings(pool).await? {
        let base = f.api_base.trim().to_owned();
        if !base.is_empty() {
            return Ok(Some(base));
        }
    }
    Ok(None)
}

/// Resolve a detection event's `(camera_id, start, end)` for clip generation.
/// `end` falls back to `start` when the event is still in progress.
pub async fn get_clip_event_window(
    pool: &Pool,
    event_id: Uuid,
) -> Result<Option<(Uuid, DateTime<Utc>, DateTime<Utc>)>> {
    let client = get_conn(pool).await?;
    let row = client
        .query_opt(
            "SELECT camera_id, ts, end_ts FROM events WHERE id = $1",
            &[&event_id],
        )
        .await
        .context("get_clip_event_window")?;
    Ok(row.map(|r| {
        let cam: Uuid = r.get("camera_id");
        let start: DateTime<Utc> = r.get("ts");
        let end: Option<DateTime<Utc>> = r.get("end_ts");
        (cam, start, end.unwrap_or(start))
    }))
}

// ─── detection events — query ─────────────────────────────────────────────────

/// Parameters for [`list_detection_events`].
#[derive(Debug)]
pub struct DetectionEventQuery {
    pub camera_ids: Vec<Uuid>,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// Optional label filter (e.g. `["person", "car"]`).  `None` = all labels.
    pub labels: Option<Vec<String>>,
    /// Max rows to return.  Clamped to 2 000 by the caller.
    pub limit: i64,
    /// Rows to skip before returning `limit`.
    pub offset: i64,
}

/// A single detection-event row as returned by the DB layer.
///
/// All fields map 1-to-1 to columns in the `events` table.
/// `icon_key` is computed server-side from `label` by [`crate::detection::icon_key_for_label`].
#[derive(Debug)]
pub struct DetectionEventRow {
    pub id: Uuid,
    pub camera_id: Uuid,
    pub ts: DateTime<Utc>,
    pub end_ts: Option<DateTime<Utc>>,
    pub label: String,
    /// Server-derived from `label` — clients use this for glyph/colour selection.
    ///
    /// Per-label: equals the normalised `label` slug (e.g. `car`, `truck`),
    /// not a collapsed group key.  Owned because the `Other`-label key is the
    /// label text itself.
    pub icon_key: String,
    pub sub_label: Option<String>,
    pub score: f32,
    pub top_score: Option<f32>,
    pub zones: Option<Vec<String>>,
    /// Crumb API path (`/events/{id}/snapshot`) when the event has a snapshot,
    /// `None` otherwise.
    pub snapshot_url: Option<String>,
    pub source_id: Option<String>,
}

/// Return detection events for the given cameras in `[start, end)` with
/// optional label filtering and pagination.
///
/// Returns `(rows, total_count)` where `total_count` is the **unfiltered**
/// total (before pagination), used for `has_more` computation by the caller.
///
/// Empty camera list → returns `(vec![], 0)` immediately (no DB round-trip).
///
/// Implementation note: two separate code paths (with/without label filter)
/// are used to avoid `Box<dyn ToSql + Sync>` across await points, which would
/// make the returned future `!Send` and break axum's Handler trait bound.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn list_detection_events(
    pool: &Pool,
    q: &DetectionEventQuery,
) -> Result<(Vec<DetectionEventRow>, i64)> {
    if q.camera_ids.is_empty() {
        return Ok((vec![], 0));
    }

    let client = get_conn(pool).await?;

    let (total, event_rows) = if let Some(ref labels) = q.labels {
        // ── path A: with label filter ─────────────────────────────────────
        let count_row = client
            .query_one(
                r"SELECT COUNT(*)::bigint AS cnt
                  FROM events
                  WHERE camera_id = ANY($1)
                    AND ts >= $2 AND ts < $3
                    AND label = ANY($4::text[])",
                &[&q.camera_ids, &q.start, &q.end, labels],
            )
            .await
            .context("list_detection_events: count (with labels)")?;
        let total: i64 = count_row.get("cnt");

        let rows = client
            .query(
                r"SELECT id, camera_id, ts, end_ts, label, sub_label,
                         COALESCE(score, 0.0) AS score,
                         top_score, zones, snapshot_url, source_id
                  FROM events
                  WHERE camera_id = ANY($1)
                    AND ts >= $2 AND ts < $3
                    AND label = ANY($4::text[])
                  ORDER BY ts DESC
                  LIMIT $5 OFFSET $6",
                &[&q.camera_ids, &q.start, &q.end, labels, &q.limit, &q.offset],
            )
            .await
            .context("list_detection_events: rows (with labels)")?;

        (total, rows)
    } else {
        // ── path B: no label filter ───────────────────────────────────────
        let count_row = client
            .query_one(
                r"SELECT COUNT(*)::bigint AS cnt
                  FROM events
                  WHERE camera_id = ANY($1)
                    AND ts >= $2 AND ts < $3",
                &[&q.camera_ids, &q.start, &q.end],
            )
            .await
            .context("list_detection_events: count (all labels)")?;
        let total: i64 = count_row.get("cnt");

        let rows = client
            .query(
                r"SELECT id, camera_id, ts, end_ts, label, sub_label,
                         COALESCE(score, 0.0) AS score,
                         top_score, zones, snapshot_url, source_id
                  FROM events
                  WHERE camera_id = ANY($1)
                    AND ts >= $2 AND ts < $3
                  ORDER BY ts DESC
                  LIMIT $4 OFFSET $5",
                &[&q.camera_ids, &q.start, &q.end, &q.limit, &q.offset],
            )
            .await
            .context("list_detection_events: rows (all labels)")?;

        (total, rows)
    };

    let rows = event_rows
        .iter()
        .map(|row| {
            let label: String = row.get("label");
            let icon_key = crate::detection::icon_key_for_label(&label);
            let id: Uuid = row.get("id");
            // snapshot_url stored in DB is the Frigate-relative path; rewrite
            // to the Crumb proxy path so clients never talk to Frigate directly.
            let has_snapshot: bool = row.get::<_, Option<String>>("snapshot_url").is_some();
            let crumb_snapshot_url = if has_snapshot {
                Some(format!("/events/{id}/snapshot"))
            } else {
                None
            };
            DetectionEventRow {
                id,
                camera_id: row.get("camera_id"),
                ts: row.get("ts"),
                end_ts: row.get("end_ts"),
                label,
                icon_key,
                sub_label: row.get("sub_label"),
                score: row.get("score"),
                top_score: row.get("top_score"),
                zones: row.get("zones"),
                snapshot_url: crumb_snapshot_url,
                source_id: row.get("source_id"),
            }
        })
        .collect();

    Ok((rows, total))
}

/// Return the `snapshot_url` (Frigate URL) stored in the `events` row.
///
/// Used by the snapshot-proxy handler to fetch the JPEG from Frigate.
/// Returns `None` when the event has no snapshot or does not exist.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn get_event_snapshot_url(pool: &Pool, event_id: Uuid) -> Result<Option<String>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT snapshot_url FROM events WHERE id = $1",
            &[&event_id],
        )
        .await
        .context("get_event_snapshot_url")?;
    Ok(opt.and_then(|row| row.get("snapshot_url")))
}

/// Load the `(source_camera_name → camera_id)` mapping used by detection providers.
///
/// Returns a `HashMap<String, Uuid>` where the key is the provider's camera
/// name (e.g. Frigate's `after.camera` value) and the value is the Crumb
/// camera UUID.  Only cameras with a non-null `source_camera_name` are included.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn load_camera_name_map(pool: &Pool) -> Result<std::collections::HashMap<String, Uuid>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            "SELECT id, source_camera_name FROM cameras \
             WHERE source_camera_name IS NOT NULL",
            &[],
        )
        .await
        .context("load_camera_name_map")?;
    let map = rows
        .into_iter()
        .map(|row| {
            let id: Uuid = row.get("id");
            let name: String = row.get("source_camera_name");
            (name, id)
        })
        .collect();
    Ok(map)
}

/// Upsert a detection event row.
///
/// `INSERT … ON CONFLICT (source_id, provider_event_id) DO UPDATE` so replay
/// and backfill are idempotent. The dedup index is partial (`WHERE source_id
/// IS NOT NULL`) so only provider-sourced events participate in dedup.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn upsert_detection_event(pool: &Pool, p: &UpsertDetectionEventParams) -> Result<Uuid> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO events (
                camera_id, ts, label, score,
                source_id, provider_event_id, sub_label,
                top_score, end_ts, zones,
                snapshot_url, raw, lifecycle
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
            ON CONFLICT (source_id, provider_event_id)
            WHERE source_id IS NOT NULL
            DO UPDATE SET
                end_ts       = COALESCE(EXCLUDED.end_ts, events.end_ts),
                top_score    = GREATEST(EXCLUDED.top_score, events.top_score),
                score        = EXCLUDED.score,
                lifecycle    = EXCLUDED.lifecycle,
                snapshot_url = COALESCE(EXCLUDED.snapshot_url, events.snapshot_url),
                raw          = EXCLUDED.raw,
                sub_label    = COALESCE(EXCLUDED.sub_label, events.sub_label),
                zones        = EXCLUDED.zones
            RETURNING id
            ",
            &[
                &p.camera_id,
                &p.start_ts,
                &p.label,
                &p.score,
                &p.source_id,
                &p.provider_event_id,
                &p.sub_label,
                &p.top_score,
                &p.end_ts,
                &p.zones,
                &p.snapshot_url,
                &p.raw,
                &p.lifecycle,
            ],
        )
        .await
        .context("upsert_detection_event")?;
    Ok(row.get(0))
}

/// Persist (or update) a motion event in the shared `events` table, so motion is a
/// first-class event alongside Frigate detections — the single unified stream the
/// notification engine consumes (and a foundation for a future motion timeline).
///
/// Idempotent via the `(source_id, provider_event_id)` dedup key: the START signal
/// (`stopped_at = None`) inserts the row (`lifecycle = 'start'`, `end_ts` NULL), and
/// the later STOP signal with the same `started_at` updates it (`lifecycle = 'end'`,
/// `end_ts` set, peak score). `source_id = 'motion'`, `label = 'motion'`.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn upsert_motion_event(pool: &Pool, sig: &MotionSignal) -> Result<Uuid> {
    let provider_event_id = format!(
        "motion:{}:{}",
        sig.camera_id,
        sig.started_at.timestamp_millis()
    );
    let lifecycle = if sig.stopped_at.is_some() {
        "end"
    } else {
        "start"
    };
    let params = UpsertDetectionEventParams {
        camera_id: sig.camera_id,
        start_ts: sig.started_at,
        label: "motion".to_owned(),
        score: sig.peak_score,
        source_id: "motion".to_owned(),
        provider_event_id,
        sub_label: None,
        top_score: sig.peak_score,
        end_ts: sig.stopped_at,
        zones: Vec::new(),
        snapshot_url: None,
        raw: serde_json::json!({ "source": "motion", "peak_score": sig.peak_score }),
        lifecycle: lifecycle.to_owned(),
    };
    upsert_detection_event(pool, &params).await
}

/// Parameters for [`upsert_detection_event`].
#[derive(Debug)]
pub struct UpsertDetectionEventParams {
    pub camera_id: Uuid,
    pub start_ts: DateTime<Utc>,
    pub label: String,
    pub score: f32,
    pub source_id: String,
    pub provider_event_id: String,
    pub sub_label: Option<String>,
    pub top_score: f32,
    pub end_ts: Option<DateTime<Utc>>,
    pub zones: Vec<String>,
    pub snapshot_url: Option<String>,
    pub raw: serde_json::Value,
    pub lifecycle: String,
}

/// Ensure the `UNIQUE(name)` constraint exists on `storages`.
///
/// Postgres applies the constraint from the migration, but this guard is run
/// at startup so the seed binary fails loudly if pointed at a stale schema
/// rather than silently inserting duplicates.
pub async fn assert_storages_unique_name(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            SELECT COUNT(*) AS cnt
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            WHERE t.relname = 'storages'
              AND c.contype IN ('u', 'p')
              AND pg_get_constraintdef(c.oid) LIKE '%name%'
            ",
            &[],
        )
        .await
        .context("assert_storages_unique_name")?;
    let cnt: i64 = row.get("cnt");
    anyhow::ensure!(
        cnt > 0,
        "storages table is missing a UNIQUE constraint on (name); \
         apply db/migrations/0001_initial_schema.sql first"
    );
    Ok(())
}

// ─── camera ownership columns — ensure-shim (migration 0012 backstop) ────────

/// Ensure the six camera columns added by migration 0012 exist (idempotent).
///
/// `served_by` (NOT NULL DEFAULT 'crumb'), `source_camera_name`, `onvif_host`,
/// `onvif_port`, `onvif_user`, `onvif_password`.  Called at both API and recorder
/// startup so whichever boots first applies them, mirroring the pattern used by
/// `ensure_camera_source_columns` and `ensure_camera_type_column`.
///
/// # Errors
///
/// Returns an error if the DDL fails (e.g. permission denied or `cameras` absent).
pub async fn ensure_camera_ownership_columns(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            ALTER TABLE cameras
                ADD COLUMN IF NOT EXISTS served_by text NOT NULL DEFAULT 'crumb'
                    CHECK (served_by IN ('crumb', 'frigate'));
            ALTER TABLE cameras ADD COLUMN IF NOT EXISTS source_camera_name text;
            ALTER TABLE cameras ADD COLUMN IF NOT EXISTS onvif_host     text;
            ALTER TABLE cameras ADD COLUMN IF NOT EXISTS onvif_port     integer;
            ALTER TABLE cameras ADD COLUMN IF NOT EXISTS onvif_user     text;
            ALTER TABLE cameras ADD COLUMN IF NOT EXISTS onvif_password text;
            ",
        )
        .await
        .context("ensure_camera_ownership_columns")?;
    Ok(())
}

// ─── stream URL resolution ────────────────────────────────────────────────────

/// Build the absolute RTSP URL for a camera stream.
///
/// This is the single source of truth for turning a camera's `main_url`/`sub_url`
/// (which may be a relative go2rtc stream name OR a legacy full absolute URL) and
/// its `served_by` ownership into an absolute RTSP URL.
///
/// # Behaviour
///
/// * **Legacy rows** (pre-migration-0012) store a full absolute URL in
///   `main_url`/`sub_url` (e.g. `"rtsp://192.0.2.10:18554/driveway"`).  These
///   are returned **verbatim** — no base is prepended.  Detection is the presence
///   of `"://"` in `stream_name`.
/// * **New rows** store only the relative name (`"driveway"` / `"driveway_sub"`).
///   The resolved base — picked by `served_by` — is prepended:
///   `"crumb"` → `crumb_rtsp_base`; any other value (including `"frigate"`) →
///   `frigate_rtsp_base`.
///
/// # Arguments
///
/// * `served_by`        — `"crumb"` or `"frigate"` (from `cameras.served_by`).
/// * `stream_name`      — the value of `cameras.main_url` or `cameras.sub_url`.
/// * `crumb_rtsp_base`  — resolved RTSP base for Crumb's restreamer.
/// * `frigate_rtsp_base`— resolved RTSP base for an external Frigate go2rtc.
///
/// # Examples
///
/// ```
/// use crumb_common::db::resolve_stream_url;
///
/// // Legacy absolute URL: passed through unchanged.
/// assert_eq!(
///     resolve_stream_url("crumb", "rtsp://10.0.0.1:18554/cam1", "rtsp://crumb:18554", "rtsp://frigate:8554"),
///     "rtsp://10.0.0.1:18554/cam1"
/// );
///
/// // New relative name, Crumb-managed:
/// assert_eq!(
///     resolve_stream_url("crumb", "driveway", "rtsp://crumb:18554", "rtsp://frigate:8554"),
///     "rtsp://crumb:18554/driveway"
/// );
///
/// // New relative name, Frigate-managed:
/// assert_eq!(
///     resolve_stream_url("frigate", "driveway_sub", "rtsp://crumb:18554", "rtsp://frigate:8554"),
///     "rtsp://frigate:8554/driveway_sub"
/// );
/// ```
pub fn resolve_stream_url(
    served_by: &str,
    stream_name: &str,
    crumb_rtsp_base: &str,
    frigate_rtsp_base: &str,
) -> String {
    // Legacy rows stored a FULL absolute URL in main_url/sub_url — pass those
    // through unchanged so no data migration is needed.
    if stream_name.contains("://") {
        return stream_name.to_string();
    }
    let base = if served_by == "frigate" {
        frigate_rtsp_base
    } else {
        crumb_rtsp_base // "crumb" and any unknown value default to Crumb's restreamer
    };
    format!("{}/{}", base.trim_end_matches('/'), stream_name)
}

/// Inject Basic/RTSP-auth credentials (`user:pass@`) into an `rtsp://host:port`
/// base URL's authority component, for P0-GO2RTC's lighter lockdown: Crumb's own
/// go2rtc RTSP listener now requires auth, so both the recorder (opening ffmpeg
/// RTSP connections) and the API (building client-facing `rtsp://` URLs for
/// `GET /cameras/{id}/streams`) need to embed `GO2RTC_USER`/`GO2RTC_PASS` into
/// the **base** before calling [`resolve_stream_url`] — that function only
/// concatenates `base/name`, so any credentials must already be in `base`.
///
/// No-ops (returns `base` unchanged) when `user` is empty, so an unconfigured
/// deployment degrades to the pre-auth URL shape rather than producing a
/// malformed `rtsp://:@host` authority.
///
/// Only apply this to `crumb_rtsp_base` — NEVER to `frigate_rtsp_base`, which
/// points at a separate, BYO Frigate go2rtc instance with its own (possibly
/// absent) credentials that Crumb does not own or know.
///
/// # Examples
///
/// ```
/// use crumb_common::db::inject_rtsp_credentials;
///
/// assert_eq!(
///     inject_rtsp_credentials("rtsp://recorder:8554", "admin", "secret"),
///     "rtsp://admin:secret@recorder:8554"
/// );
/// // No-op when unconfigured.
/// assert_eq!(
///     inject_rtsp_credentials("rtsp://recorder:8554", "", "secret"),
///     "rtsp://recorder:8554"
/// );
/// // Idempotent: a base that already has an authority is left alone (avoids
/// // double-embedding if ever called twice on the same value).
/// assert_eq!(
///     inject_rtsp_credentials("rtsp://admin:secret@recorder:8554", "admin", "secret"),
///     "rtsp://admin:secret@recorder:8554"
/// );
/// ```
pub fn inject_rtsp_credentials(base: &str, user: &str, pass: &str) -> String {
    if user.is_empty() {
        return base.to_owned();
    }
    let Some(rest) = base.strip_prefix("rtsp://") else {
        // Not an rtsp:// base (shouldn't happen for crumb_rtsp_base) — pass through.
        return base.to_owned();
    };
    if rest.contains('@') {
        // Already has an authority (idempotency guard) — leave unchanged.
        return base.to_owned();
    }
    format!("rtsp://{user}:{pass}@{rest}")
}

// ─── server_settings singleton ────────────────────────────────────────────────

/// Seeds for the `server_settings` singleton row, read from environment variables.
///
/// The tuple fields are: `(server_address, crumb_rtsp, crumb_api, frigate_rtsp,
/// frigate_api_legacy, frigate_go2rtc_api, frigate_http_api)`.
///
/// * `frigate_api_legacy` — the old single-field seed (kept for the legacy
///   `frigate_api_base` column), sourced from `FRIGATE_API_BASE` first, then
///   `GO2RTC_API_BASE`.  This produced the conflation bug (#11); retained for
///   back-compat with the column.
/// * `frigate_go2rtc_api` — the go2rtc REST side of an external Frigate
///   (MSE/WebRTC/frame-proxy, port :1984), seeded from `GO2RTC_API_BASE`.
/// * `frigate_http_api` — the Frigate HTTP detection API (events/snapshots,
///   port :5000), seeded from `FRIGATE_API_BASE`.
fn server_settings_env_seed() -> (String, String, String, String, String, String, String) {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let crumb_rtsp = env("CRUMB_GO2RTC_RTSP_BASE").unwrap_or_default();
    let crumb_api = env("CRUMB_GO2RTC_API_BASE").unwrap_or_default();
    let frigate_rtsp = env("GO2RTC_RTSP_BASE").unwrap_or_default();
    // Legacy: the old single field conflated go2rtc-REST and Frigate-HTTP.
    let frigate_api_legacy = env("FRIGATE_API_BASE")
        .or_else(|| env("GO2RTC_API_BASE"))
        .unwrap_or_default();
    // New split fields (migration 0014).
    let frigate_go2rtc_api = env("GO2RTC_API_BASE").unwrap_or_default();
    let frigate_http_api = env("FRIGATE_API_BASE").unwrap_or_default();
    let server_address = env("SERVER_ADDRESS").unwrap_or_default();
    (
        server_address,
        crumb_rtsp,
        crumb_api,
        frigate_rtsp,
        frigate_api_legacy,
        frigate_go2rtc_api,
        frigate_http_api,
    )
}

fn server_settings_from_row(row: &tokio_postgres::Row) -> ServerSettings {
    // The two new columns were added by migration 0014; use try_get with a fallback
    // so this deserialiser works against a DB that is mid-migration (e.g. migration
    // runner hasn't applied 0014 yet on this startup's first boot pass).
    let frigate_api_base: String = row.get("frigate_api_base");
    let frigate_go2rtc_api_base: String = row
        .try_get("frigate_go2rtc_api_base")
        .unwrap_or_else(|_| frigate_api_base.clone());
    let frigate_http_api_base: String = row
        .try_get("frigate_http_api_base")
        .unwrap_or_else(|_| frigate_api_base.clone());
    // motion_hwaccel / motion_vaapi_device are added by ensure_server_settings_table;
    // try_get with a fallback keeps this safe against a mid-migration boot.
    let motion_hwaccel: String = row.try_get("motion_hwaccel").unwrap_or_default();
    let motion_vaapi_device: String = row.try_get("motion_vaapi_device").unwrap_or_default();
    ServerSettings {
        server_address: row.get("server_address"),
        crumb_rtsp_base: row.get("crumb_rtsp_base"),
        crumb_api_base: row.get("crumb_api_base"),
        frigate_rtsp_base: row.get("frigate_rtsp_base"),
        frigate_api_base,
        frigate_go2rtc_api_base,
        frigate_http_api_base,
        motion_hwaccel,
        motion_vaapi_device,
        version: row.get("version"),
    }
}

/// Ensure the `server_settings` singleton table exists and seed it from env
/// (idempotent — mirrors `ensure_frigate_config_table`).
///
/// On first creation the row is seeded from the legacy `CRUMB_GO2RTC_RTSP_BASE`,
/// `CRUMB_GO2RTC_API_BASE`, `GO2RTC_RTSP_BASE`, `GO2RTC_API_BASE`,
/// `FRIGATE_API_BASE` env vars so an existing env-configured deployment carries
/// over.
///
/// **#1 fix**: Migration 0012 inserts `(id) VALUES (1)` with all base fields at
/// their empty-string defaults BEFORE `ensure_server_settings_table` is called.
/// The old `ON CONFLICT DO NOTHING` then left all fields empty — meaning a fresh
/// `docker compose up` with `CRUMB_GO2RTC_RTSP_BASE` set produced an empty
/// `crumb_rtsp_base`, resolving every camera stream URL to a malformed
/// `/stream-name`.
///
/// Fix: use `ON CONFLICT DO UPDATE SET ... = CASE WHEN existing IS '' THEN env
/// ELSE existing END` (COALESCE-on-empty pattern) so the env values are applied
/// even when the row already exists with empty fields.  A row where an operator
/// has explicitly set a value (non-empty) is NEVER overwritten.
///
/// **No `192.0.2.10` literals.** Any homelab IP from legacy env vars is preserved
/// through env seeding but never hardcoded here.
///
/// # Errors
///
/// Returns an error if the DDL or UPSERT fails.
pub async fn ensure_server_settings_table(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    // Create table and the two new split-columns from 0014 if absent.  This is a
    // best-effort shim: migrations may not have run yet on this boot, so we add
    // the columns silently here to avoid a deserialisation panic on `server_settings_from_row`.
    client
        .batch_execute(
            r"
            CREATE TABLE IF NOT EXISTS server_settings (
                id                smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
                server_address    text NOT NULL DEFAULT '',
                crumb_rtsp_base   text NOT NULL DEFAULT '',
                crumb_api_base    text NOT NULL DEFAULT '',
                frigate_rtsp_base text NOT NULL DEFAULT '',
                frigate_api_base  text NOT NULL DEFAULT '',
                version           bigint NOT NULL DEFAULT 1,
                updated_at        timestamptz NOT NULL DEFAULT now()
            );
            ALTER TABLE server_settings
                ADD COLUMN IF NOT EXISTS frigate_go2rtc_api_base text NOT NULL DEFAULT '';
            ALTER TABLE server_settings
                ADD COLUMN IF NOT EXISTS frigate_http_api_base text NOT NULL DEFAULT '';
            ALTER TABLE server_settings
                ADD COLUMN IF NOT EXISTS motion_hwaccel text NOT NULL DEFAULT '';
            ALTER TABLE server_settings
                ADD COLUMN IF NOT EXISTS motion_vaapi_device text NOT NULL DEFAULT '';
            ",
        )
        .await
        .context("ensure_server_settings_table: create")?;

    let (
        server_address,
        crumb_rtsp,
        crumb_api,
        frigate_rtsp,
        frigate_api,
        frigate_go2rtc_api,
        frigate_http_api,
    ) = server_settings_env_seed();

    // UPSERT with COALESCE-on-empty: INSERT the row if absent; if it already
    // exists (e.g. inserted by migration 0012 with all-empty fields), update
    // every field that is currently empty with the env value.  Fields the
    // operator has already populated (non-empty) are left untouched.
    client
        .execute(
            r"
            INSERT INTO server_settings
                (id, server_address, crumb_rtsp_base, crumb_api_base,
                 frigate_rtsp_base, frigate_api_base,
                 frigate_go2rtc_api_base, frigate_http_api_base, version)
            VALUES (1, $1, $2, $3, $4, $5, $6, $7, 1)
            ON CONFLICT (id) DO UPDATE SET
                server_address         = CASE WHEN server_settings.server_address         = '' THEN EXCLUDED.server_address         ELSE server_settings.server_address         END,
                crumb_rtsp_base        = CASE WHEN server_settings.crumb_rtsp_base        = '' THEN EXCLUDED.crumb_rtsp_base        ELSE server_settings.crumb_rtsp_base        END,
                crumb_api_base         = CASE WHEN server_settings.crumb_api_base         = '' THEN EXCLUDED.crumb_api_base         ELSE server_settings.crumb_api_base         END,
                frigate_rtsp_base      = CASE WHEN server_settings.frigate_rtsp_base      = '' THEN EXCLUDED.frigate_rtsp_base      ELSE server_settings.frigate_rtsp_base      END,
                frigate_api_base       = CASE WHEN server_settings.frigate_api_base       = '' THEN EXCLUDED.frigate_api_base       ELSE server_settings.frigate_api_base       END,
                frigate_go2rtc_api_base = CASE WHEN server_settings.frigate_go2rtc_api_base = '' THEN EXCLUDED.frigate_go2rtc_api_base ELSE server_settings.frigate_go2rtc_api_base END,
                frigate_http_api_base  = CASE WHEN server_settings.frigate_http_api_base  = '' THEN EXCLUDED.frigate_http_api_base  ELSE server_settings.frigate_http_api_base  END
            ",
            &[
                &server_address,
                &crumb_rtsp,
                &crumb_api,
                &frigate_rtsp,
                &frigate_api,
                &frigate_go2rtc_api,
                &frigate_http_api,
            ],
        )
        .await
        .context("ensure_server_settings_table: seed")?;
    Ok(())
}

/// Fetch the singleton server settings row (`None` only if the row is somehow absent).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn get_server_settings(pool: &Pool) -> Result<Option<ServerSettings>> {
    let client = get_conn(pool).await?;
    // Select both the legacy frigate_api_base and the two new split columns added
    // by migration 0014.  server_settings_from_row uses try_get with a fallback so
    // this is safe on a DB that hasn't had 0014 applied yet.
    let opt = client
        .query_opt(
            r"SELECT server_address, crumb_rtsp_base, crumb_api_base,
                     frigate_rtsp_base, frigate_api_base,
                     frigate_go2rtc_api_base, frigate_http_api_base,
                     motion_hwaccel, motion_vaapi_device, version
              FROM server_settings WHERE id = 1",
            &[],
        )
        .await
        .context("get_server_settings")?;
    Ok(opt.as_ref().map(server_settings_from_row))
}

/// Cheap version poll for `server_settings`.
///
/// Returns `0` if the row is missing (table not yet created / pre-migration).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn server_settings_version(pool: &Pool) -> Result<i64> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt("SELECT version FROM server_settings WHERE id = 1", &[])
        .await
        .context("server_settings_version")?;
    Ok(opt.map_or(0, |r| r.get("version")))
}

/// Update the singleton server settings and BUMP `version` (so any future
/// hot-reload pollers pick up the change).  Returns the updated settings.
///
/// All settable fields are replaced; pass the current values for fields the
/// caller does not want to change.  Empty strings are valid (mean "fall back to
/// env").
///
/// The two new fields added by migration 0014 (`frigate_go2rtc_api_base` and
/// `frigate_http_api_base`) are also updated.  The API-routes caller must include
/// them in `UpdateServerSettingsRequest`; see the contract in the audit.
///
/// # Errors
///
/// Returns an error if the update fails (e.g. the row does not exist — call
/// `ensure_server_settings_table` first at startup).
#[allow(clippy::too_many_arguments)]
pub async fn update_server_settings(
    pool: &Pool,
    server_address: &str,
    crumb_rtsp_base: &str,
    crumb_api_base: &str,
    frigate_rtsp_base: &str,
    frigate_api_base: &str,
    frigate_go2rtc_api_base: &str,
    frigate_http_api_base: &str,
    motion_hwaccel: &str,
    motion_vaapi_device: &str,
) -> Result<ServerSettings> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            UPDATE server_settings SET
                server_address          = $1,
                crumb_rtsp_base         = $2,
                crumb_api_base          = $3,
                frigate_rtsp_base       = $4,
                frigate_api_base        = $5,
                frigate_go2rtc_api_base = $6,
                frigate_http_api_base   = $7,
                motion_hwaccel          = $8,
                motion_vaapi_device     = $9,
                version                 = version + 1,
                updated_at              = now()
            WHERE id = 1
            RETURNING server_address, crumb_rtsp_base, crumb_api_base,
                      frigate_rtsp_base, frigate_api_base,
                      frigate_go2rtc_api_base, frigate_http_api_base,
                      motion_hwaccel, motion_vaapi_device, version
            ",
            &[
                &server_address,
                &crumb_rtsp_base,
                &crumb_api_base,
                &frigate_rtsp_base,
                &frigate_api_base,
                &frigate_go2rtc_api_base,
                &frigate_http_api_base,
                &motion_hwaccel,
                &motion_vaapi_device,
            ],
        )
        .await
        .context("update_server_settings")?;
    Ok(server_settings_from_row(&row))
}

// ─── segments index self-heal (C3) ───────────────────────────────────────────

/// Idempotently create the three canonical segment indexes at startup.
///
/// This subsumes / is complementary to [`ensure_segments_storage_index`]:
///
/// | Index name                       | Purpose |
/// |---|---|
/// | `segments_uniq_cam_stream_start` | UNIQUE — prevents duplicate rows. |
/// | `segments_stage_start`           | Eviction covering index. |
/// | `segments_start_ts`              | Cross-camera timeline index. |
///
/// All three use `CREATE INDEX IF NOT EXISTS` (non-concurrent) so this can
/// run safely inside or outside a transaction and is a catalog-check no-op once
/// the indexes exist.  Called at BOTH API and recorder startup alongside the
/// existing `ensure_segments_storage_index`.
///
/// # Errors
///
/// Returns an error if any DDL statement fails.
pub async fn ensure_segments_indexes(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            CREATE UNIQUE INDEX IF NOT EXISTS segments_uniq_cam_stream_start
                ON segments (camera_id, stream, start_ts);
            CREATE INDEX IF NOT EXISTS segments_stage_start
                ON segments (stage, start_ts);
            CREATE INDEX IF NOT EXISTS segments_start_ts
                ON segments (start_ts);
            ",
        )
        .await
        .context("ensure_segments_indexes")?;
    Ok(())
}

// ─── notification_settings singleton ────────────────────────────────────────

/// Fetch the global notification-engine enabled flag.
///
/// Returns `true` when notifications are enabled (the default), or `false`
/// when an operator has flipped the master switch off.  If the row is somehow
/// absent (fresh DB before migration 0017) the function returns `true` (safe
/// default — no alerts silenced unexpectedly).
///
/// # Errors
///
/// Returns an error if the query itself fails (e.g. the table does not exist
/// yet — the caller should treat this the same as the default `true`).
pub async fn get_notifications_enabled(pool: &Pool) -> Result<bool> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT enabled FROM notification_settings WHERE id = 1",
            &[],
        )
        .await
        .context("get_notifications_enabled")?;
    Ok(opt.is_none_or(|r| r.get::<_, bool>("enabled")))
}

/// Set the global notification-engine enabled flag.
///
/// A `false` value instructs the engine to consume events (advancing the
/// cursor) but skip all dispatch — so re-enabling does NOT backlog old alerts.
///
/// # Errors
///
/// Returns an error if the update fails (e.g. the row or table does not exist
/// — run migration 0017 or call this after startup finishes).
pub async fn set_notifications_enabled(pool: &Pool, enabled: bool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE notification_settings SET enabled = $1, updated_at = now() WHERE id = 1",
            &[&enabled],
        )
        .await
        .context("set_notifications_enabled")?;
    Ok(())
}

/// Fetch the global quiet-hours window used ONLY by the system/health alerts
/// pipeline (P0-HEALTH-NOTIFY). `(None, None)` when unset (the default — no
/// quiet hours) or the row is absent (pre-migration-0032 DB).
///
/// # Errors
///
/// Returns an error if the query itself fails.
pub async fn get_system_alert_quiet_hours(pool: &Pool) -> Result<(Option<i32>, Option<i32>)> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT quiet_start_hour, quiet_end_hour FROM notification_settings WHERE id = 1",
            &[],
        )
        .await
        .context("get_system_alert_quiet_hours")?;
    Ok(opt.map_or((None, None), |r| {
        (r.get("quiet_start_hour"), r.get("quiet_end_hour"))
    }))
}

/// Set the global quiet-hours window for the system/health alerts pipeline.
/// `None` for either bound clears quiet hours (both must be `Some` for the
/// window to apply — enforced by the caller / admin UI, not here).
///
/// # Errors
///
/// Returns an error if the update fails.
pub async fn set_system_alert_quiet_hours(
    pool: &Pool,
    start_hour: Option<i32>,
    end_hour: Option<i32>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            "UPDATE notification_settings SET quiet_start_hour = $1, quiet_end_hour = $2, updated_at = now() WHERE id = 1",
            &[&start_hour, &end_hour],
        )
        .await
        .context("set_system_alert_quiet_hours")?;
    Ok(())
}

// ─── schema migration runner (C4) ────────────────────────────────────────────

/// Apply embedded `db/migrations/*.sql` files in filename order, idempotently,
/// tracked in `schema_migrations`.
///
/// # Behaviour
///
/// 1. Creates `schema_migrations(filename text primary key, applied_at
///    timestamptz default now())` if absent.
/// 2. **Baseline detection:** if `schema_migrations` is EMPTY AND `segments`
///    already exists (an existing / upgraded DB), marks filenames `0001…`–`0011…`
///    as applied WITHOUT executing them.  This protects a live production DB
///    from re-running the base migrations.
/// 3. For each embedded migration whose filename is NOT yet in
///    `schema_migrations`, runs it inside a transaction and records it on commit.
///
/// This makes fresh installs, external-Postgres setups, and prod-DB upgrades
/// all converge to the same schema with a single call at startup.
///
/// # Errors
///
/// Returns an error on the FIRST migration that fails, leaving the DB in the
/// partially-migrated state (the failed file is not recorded, so it will be
/// retried on the next startup after the underlying issue is fixed).
///
/// # Concurrency (R2)
///
/// The api and recorder processes both call this at boot, and Compose starts
/// them together — so on every upgrade (and every fresh install) two
/// processes can run the SAME idempotent `ALTER TABLE` / `CREATE TABLE IF NOT
/// EXISTS` DDL concurrently against an unapplied migration, which Postgres can
/// reject with "tuple concurrently updated". Serialize with a session
/// advisory lock (same pattern as [`ensure_named_policies_and_groups`]): the
/// loser blocks until the winner finishes, then re-runs the (now-idempotent,
/// already-applied) migrations harmlessly.
pub async fn run_migrations(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;

    // Serialize with the other startup caller (api ↔ recorder) via a session
    // advisory lock so the idempotent DDL never runs concurrently. Released
    // explicitly below — and automatically if the connection is dropped.
    client
        .execute("SELECT pg_advisory_lock($1)", &[&RUN_MIGRATIONS_LOCK_KEY])
        .await
        .context("acquire run-migrations advisory lock")?;

    // Run the work in an inner block, CAPTURING the result, so the advisory
    // lock is ALWAYS released before returning (no `?` early-return between
    // the lock and the unlock below).
    let result = run_migrations_locked(pool).await;

    // Release the advisory lock (best-effort) regardless of the outcome above.
    let _ = client
        .execute("SELECT pg_advisory_unlock($1)", &[&RUN_MIGRATIONS_LOCK_KEY])
        .await;

    result
}

/// Advisory-lock key serializing the concurrent api+recorder startup calls to
/// [`run_migrations`]. Distinct from [`ENSURE_POLICIES_LOCK_KEY`] — each
/// serialized startup path owns its own key so they never contend with each
/// other, only with their own concurrent caller. Arbitrary fixed constant.
const RUN_MIGRATIONS_LOCK_KEY: i64 = 917_342_002;

/// Find and DROP every INVALID index in the current schema, logging a loud
/// WARN naming each one.
///
/// An index is left `INVALID` when its `CREATE INDEX CONCURRENTLY` build is
/// interrupted (process killed, OOM, container restart mid-build) — Postgres
/// leaves the catalog entry behind rather than rolling it back (that's the
/// whole point of CONCURRENTLY: it can't run inside a transaction, so there is
/// no transaction to roll back). The danger: a subsequent
/// `CREATE INDEX ... IF NOT EXISTS` (concurrent or not) sees the name already
/// present and treats it as done, so the broken index is **never rebuilt** —
/// silently, forever. For the UNIQUE index on `segments`
/// (`segments_uniq_cam_stream_start`) that means the duplicate-row guarantee
/// the whole reliability audit depends on is quietly gone; for the others it
/// just means the planner ignores the index and queries fall back to a slow
/// path.
///
/// Dropping and recreating is unconditionally safe here: [`run_migrations`]
/// (the sole caller, via [`run_migrations_locked`]) holds
/// [`RUN_MIGRATIONS_LOCK_KEY`] for the whole call, so no other process can be
/// concurrently building the same index name, and the migrations that follow
/// this check all use `CREATE INDEX IF NOT EXISTS` / `CREATE INDEX
/// CONCURRENTLY IF NOT EXISTS`, which will simply rebuild whatever was just
/// dropped.
///
/// Scoped to `current_schema()` only (never touches another tenant's schema
/// in a shared-cluster / multi-schema test setup).
///
/// # Errors
///
/// Returns an error if the catalog query or a `DROP INDEX` fails.
async fn reap_invalid_indexes(client: &deadpool_postgres::Client) -> Result<()> {
    // pg_index.indisvalid is false for exactly this case (interrupted
    // CONCURRENTLY build); pg_class gives us the human-readable index name and
    // its owning table for a useful log line.
    let rows = client
        .query(
            r"
            SELECT ci.relname AS index_name, ct.relname AS table_name
            FROM pg_index pi
            JOIN pg_class ci ON ci.oid = pi.indexrelid
            JOIN pg_class ct ON ct.oid = pi.indrelid
            JOIN pg_namespace ns ON ns.oid = ci.relnamespace
            WHERE NOT pi.indisvalid
              AND ns.nspname = current_schema()
            ",
            &[],
        )
        .await
        .context("reap_invalid_indexes: query pg_index for INVALID indexes")?;

    for row in rows {
        let index_name: String = row.get("index_name");
        let table_name: String = row.get("table_name");
        tracing::warn!(
            index_name,
            table_name,
            "run_migrations: found INVALID index (left by an interrupted \
             CREATE INDEX CONCURRENTLY) — dropping so the migration runner \
             rebuilds it; the index provided NO guarantees while invalid"
        );
        // Index names are catalog-sourced identifiers (not user input), but
        // quote them defensively since `format!` can't bind a DDL identifier
        // as a parameter.
        client
            .batch_execute(&format!(
                r#"DROP INDEX IF EXISTS "{index_name}""#,
                index_name = index_name.replace('"', "\"\"")
            ))
            .await
            .with_context(|| format!("reap_invalid_indexes: drop invalid index {index_name}"))?;
    }

    Ok(())
}

/// The actual migration-application body, run while [`run_migrations`] holds
/// the advisory lock. Split out so the lock/unlock wrapping above has no `?`
/// early-return between acquire and release.
async fn run_migrations_locked(pool: &Pool) -> Result<()> {
    // The ordered list of (filename, SQL body) pairs.  0001–0011 must be
    // included so an EXTERNAL Postgres (not initdb-seeded) self-provisions.
    // On an existing prod DB they are baseline-skipped (see step 2 above).
    static MIGRATIONS: &[(&str, &str)] = &[
        (
            "0001_initial_schema.sql",
            include_str!("../../../db/migrations/0001_initial_schema.sql"),
        ),
        (
            "0002_views.sql",
            include_str!("../../../db/migrations/0002_views.sql"),
        ),
        (
            "0003_record_audio.sql",
            include_str!("../../../db/migrations/0003_record_audio.sql"),
        ),
        (
            "0004_recorder_heartbeat.sql",
            include_str!("../../../db/migrations/0004_recorder_heartbeat.sql"),
        ),
        (
            "0005_motion_grid.sql",
            include_str!("../../../db/migrations/0005_motion_grid.sql"),
        ),
        (
            "0006_motion_grid_score.sql",
            include_str!("../../../db/migrations/0006_motion_grid_score.sql"),
        ),
        (
            "0007_detection_events.sql",
            include_str!("../../../db/migrations/0007_detection_events.sql"),
        ),
        (
            "0008_segments_repair.sql",
            include_str!("../../../db/migrations/0008_segments_repair.sql"),
        ),
        (
            "0009_segments_indexes.sql",
            include_str!("../../../db/migrations/0009_segments_indexes.sql"),
        ),
        (
            "0010_bookmarks.sql",
            include_str!("../../../db/migrations/0010_bookmarks.sql"),
        ),
        (
            "0011_segments_storage_idx.sql",
            include_str!("../../../db/migrations/0011_segments_storage_idx.sql"),
        ),
        (
            "0012_server_settings_and_camera_ownership.sql",
            include_str!("../../../db/migrations/0012_server_settings_and_camera_ownership.sql"),
        ),
        (
            "0013_segments_indexes.sql",
            include_str!("../../../db/migrations/0013_segments_indexes.sql"),
        ),
        (
            "0014_frigate_api_split.sql",
            include_str!("../../../db/migrations/0014_frigate_api_split.sql"),
        ),
        (
            "0015_notifications.sql",
            include_str!("../../../db/migrations/0015_notifications.sql"),
        ),
        (
            "0016_motion_baseline.sql",
            include_str!("../../../db/migrations/0016_motion_baseline.sql"),
        ),
        (
            "0017_notification_settings.sql",
            include_str!("../../../db/migrations/0017_notification_settings.sql"),
        ),
        (
            "0018_consolidate_runtime_ensure_ddl.sql",
            include_str!("../../../db/migrations/0018_consolidate_runtime_ensure_ddl.sql"),
        ),
        (
            "0019_camera_effective_policy_view.sql",
            include_str!("../../../db/migrations/0019_camera_effective_policy_view.sql"),
        ),
        (
            "0020_grouped_cameras_clear_override.sql",
            include_str!("../../../db/migrations/0020_grouped_cameras_clear_override.sql"),
        ),
        (
            "0021_grouped_camera_no_override_trigger.sql",
            include_str!("../../../db/migrations/0021_grouped_camera_no_override_trigger.sql"),
        ),
        (
            "0022_clip_source.sql",
            include_str!("../../../db/migrations/0022_clip_source.sql"),
        ),
        (
            "0023_clip_views.sql",
            include_str!("../../../db/migrations/0023_clip_views.sql"),
        ),
        (
            "0024_clip_pre_roll.sql",
            include_str!("../../../db/migrations/0024_clip_pre_roll.sql"),
        ),
        (
            "0025_clip_motion_highlight.sql",
            include_str!("../../../db/migrations/0025_clip_motion_highlight.sql"),
        ),
        (
            "0026_segment_motion_bbox.sql",
            include_str!("../../../db/migrations/0026_segment_motion_bbox.sql"),
        ),
        (
            "0027_setup_complete.sql",
            include_str!("../../../db/migrations/0027_setup_complete.sql"),
        ),
        (
            "0028_roles.sql",
            include_str!("../../../db/migrations/0028_roles.sql"),
        ),
        (
            "0029_bookmarks_enabled.sql",
            include_str!("../../../db/migrations/0029_bookmarks_enabled.sql"),
        ),
        (
            "0030_view_owner.sql",
            include_str!("../../../db/migrations/0030_view_owner.sql"),
        ),
        (
            "0031_view_shares.sql",
            include_str!("../../../db/migrations/0031_view_shares.sql"),
        ),
        (
            "0032_system_alerts.sql",
            include_str!("../../../db/migrations/0032_system_alerts.sql"),
        ),
        (
            "0033_sessions.sql",
            include_str!("../../../db/migrations/0033_sessions.sql"),
        ),
        (
            "0034_frigate_heartbeat.sql",
            include_str!("../../../db/migrations/0034_frigate_heartbeat.sql"),
        ),
        (
            "0035_decode_status.sql",
            include_str!("../../../db/migrations/0035_decode_status.sql"),
        ),
        (
            "0036_embedded_go2rtc_api_base.sql",
            include_str!("../../../db/migrations/0036_embedded_go2rtc_api_base.sql"),
        ),
        (
            "0037_segment_motion_shadow.sql",
            include_str!("../../../db/migrations/0037_segment_motion_shadow.sql"),
        ),
        (
            "0038_motion_detector_unhealthy_alert.sql",
            include_str!("../../../db/migrations/0038_motion_detector_unhealthy_alert.sql"),
        ),
        (
            "0039_motion_cache_status.sql",
            include_str!("../../../db/migrations/0039_motion_cache_status.sql"),
        ),
        (
            "0040_motion_cache_unavailable_alert.sql",
            include_str!("../../../db/migrations/0040_motion_cache_unavailable_alert.sql"),
        ),
        (
            "0041_view_icon.sql",
            include_str!("../../../db/migrations/0041_view_icon.sql"),
        ),
        (
            "0042_policy_max_retention_days.sql",
            include_str!("../../../db/migrations/0042_policy_max_retention_days.sql"),
        ),
        (
            "0043_storage_persist_failed_alert.sql",
            include_str!("../../../db/migrations/0043_storage_persist_failed_alert.sql"),
        ),
        (
            "0044_beta_terms_acceptance.sql",
            include_str!("../../../db/migrations/0044_beta_terms_acceptance.sql"),
        ),
        (
            "0045_update_check.sql",
            include_str!("../../../db/migrations/0045_update_check.sql"),
        ),
        (
            "0046_scrub_pregen_settings.sql",
            include_str!("../../../db/migrations/0046_scrub_pregen_settings.sql"),
        ),
        (
            "0047_camera_device_info.sql",
            include_str!("../../../db/migrations/0047_camera_device_info.sql"),
        ),
        (
            "0048_ha_integration.sql",
            include_str!("../../../db/migrations/0048_ha_integration.sql"),
        ),
    ];

    // Baseline filenames: 0001–0011 are marked applied on an existing DB to
    // avoid re-running them.
    const BASELINE_FILENAMES: &[&str] = &[
        "0001_initial_schema.sql",
        "0002_views.sql",
        "0003_record_audio.sql",
        "0004_recorder_heartbeat.sql",
        "0005_motion_grid.sql",
        "0006_motion_grid_score.sql",
        "0007_detection_events.sql",
        "0008_segments_repair.sql",
        "0009_segments_indexes.sql",
        "0010_bookmarks.sql",
        "0011_segments_storage_idx.sql",
    ];

    let mut client = get_conn(pool).await?;

    // 1. Create the tracking table.
    client
        .batch_execute(
            r"
            CREATE TABLE IF NOT EXISTS schema_migrations (
                filename   text PRIMARY KEY,
                applied_at timestamptz NOT NULL DEFAULT now()
            );
            ",
        )
        .await
        .context("run_migrations: create schema_migrations")?;

    // 2. Check for the baseline condition: empty tracking table + segments exists.
    //
    // #16 crash-window fix: we must be sure the DB is a genuine existing production
    // DB before baselining, not a partially-applied fresh install.  A fresh install
    // that crashed AFTER 0001 (which creates `segments`) but BEFORE 0002 (which
    // creates `views`) would pass the old `segments_exists` check but would then
    // have 0002–0011 incorrectly baselines as applied — skipping their DDL forever.
    //
    // Added guard: `views` must ALSO exist.  `views` is created by 0002 (the very
    // next migration after 0001).  Together `segments + views + schema_migrations
    // empty` unambiguously means "this is an upgraded prod DB that predates the
    // migration runner", because a fresh install that made it to 0002 would have
    // successfully recorded 0001 in schema_migrations (both run in the same loop
    // iteration) and applied_count would be ≥ 1.
    let applied_count: i64 = client
        .query_one("SELECT COUNT(*)::bigint FROM schema_migrations", &[])
        .await
        .context("run_migrations: count schema_migrations")?
        .get(0);

    /// Return true iff `table_name` exists in `current_schema()`.
    async fn table_exists(client: &deadpool_postgres::Client, table_name: &str) -> Result<bool> {
        client
            .query_one(
                r"
                SELECT EXISTS (
                    SELECT 1 FROM information_schema.tables
                    WHERE table_schema = current_schema()
                      AND table_name = $1
                )
                ",
                &[&table_name],
            )
            .await
            .map(|r| r.get(0))
            .context("run_migrations: table_exists")
    }

    let segments_exists = table_exists(&client, "segments").await?;
    // `views` is created by 0002 — see #16 safety rationale above.
    let views_exists = table_exists(&client, "views").await?;

    if applied_count == 0 && segments_exists && views_exists {
        // Existing / upgraded DB: mark 0001–0011 as applied without running them.
        tracing::info!(
            "run_migrations: existing DB detected (schema_migrations empty, segments+views exist); \
             baselining 0001–0011 as applied"
        );
        let tx = client
            .transaction()
            .await
            .context("run_migrations: begin baseline txn")?;
        for name in BASELINE_FILENAMES {
            tx.execute(
                "INSERT INTO schema_migrations (filename) VALUES ($1) ON CONFLICT DO NOTHING",
                &[name],
            )
            .await
            .with_context(|| format!("run_migrations: baseline insert {name}"))?;
        }
        tx.commit()
            .await
            .context("run_migrations: commit baseline")?;
        // Re-acquire client after transaction.
        client = get_conn(pool).await?;
    }

    // 2.5. Heal any INVALID index left by a previously-interrupted
    // `CREATE INDEX CONCURRENTLY` (process killed / OOM'd / crashed mid-build).
    // A `CREATE INDEX CONCURRENTLY IF NOT EXISTS` run afterwards sees the name
    // already present in `pg_class` and treats it as done — the index is
    // silently NEVER rebuilt, so queries either misbehave (a stale/partial
    // index is never used by the planner, which is safe but slow) or, for the
    // UNIQUE index, future inserts lose the duplicate-prevention guarantee
    // entirely. Drop-and-let-the-migration-below-recreate-it is safe here
    // because we hold [`RUN_MIGRATIONS_LOCK_KEY`] for the whole call, so no
    // other process can be mid-build on the same name.
    reap_invalid_indexes(&client).await?;

    // 3. Apply each migration not yet in schema_migrations.
    for (filename, sql) in MIGRATIONS {
        let already_applied: bool = client
            .query_one(
                "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = $1)",
                &[filename],
            )
            .await
            .with_context(|| format!("run_migrations: check {filename}"))?
            .get(0);

        if already_applied {
            continue;
        }

        tracing::info!(filename, "run_migrations: applying");

        // CREATE INDEX CONCURRENTLY cannot run inside a transaction block, and a
        // multi-statement simple query is ITSELF an implicit transaction — so a
        // CONCURRENTLY file (0009, 0011) must be applied one statement at a time,
        // each as its own standalone simple query. Detect by the actual DDL line
        // (the keyword can also appear in comments, which we must ignore — that
        // false-trigger would otherwise route plain files like 0013 here).
        //
        // Everything else is applied as a single batch_execute: a multi-statement
        // string runs as ONE implicit transaction (atomic, auto-rolled-back on
        // error), and a file that brings its own BEGIN/COMMIT (0001, 0008) is
        // honored as-is — we add NO wrapping transaction of our own, so there is
        // never a nested-transaction (savepoint) hazard. The schema_migrations
        // INSERT is recorded after a successful apply; if the process dies between
        // apply and record, every migration is idempotent (IF NOT EXISTS /
        // ON CONFLICT) so it simply re-applies harmlessly on the next startup.
        //
        // NOTE (#2): strip line comments BEFORE checking for CONCURRENTLY and
        // BEFORE splitting on ';'.  Splitting first and then sending a raw chunk
        // that happens to start with a SQL comment (`-- foo; CONCURRENTLY`) sends
        // the comment fragment as a statement to Postgres, which errors on an
        // external Postgres (unlike the embedded one which is more lenient).  Strip
        // each line's comment suffix, join, then split on ';'.
        let stripped_sql: String = sql
            .lines()
            .map(|l| {
                // Remove everything from `--` to end-of-line (the standard SQL
                // single-line comment syntax).  This is safe because our
                // migrations do not contain `--` inside string literals.
                if let Some(pos) = l.find("--") {
                    &l[..pos]
                } else {
                    l
                }
            })
            .collect::<Vec<_>>()
            .join("\n");

        let has_concurrently = stripped_sql.to_ascii_uppercase().contains("CONCURRENTLY");

        // Migration timeout exemption: [`build_pool`] sets a pool-wide
        // `statement_timeout` (default 30s) on every connection so a stuck
        // query elsewhere can't wedge the pool forever. A big `CREATE INDEX
        // CONCURRENTLY` (or any other legitimately-long DDL) on an
        // already-populated table can easily exceed that, so migrations must
        // opt out of it locally rather than have us weaken the pool default.
        if has_concurrently {
            // CONCURRENTLY statements each run as their OWN standalone simple
            // query/session (see the comment above) — `SET LOCAL` would not
            // survive past the single statement it's batched with, so this
            // needs the session-level `SET` here, unset again once the
            // migration's statements are done.
            client
                .batch_execute("SET statement_timeout = 0")
                .await
                .context("run_migrations: disable statement_timeout for CONCURRENTLY")?;
            for stmt in stripped_sql.split(';') {
                // Skip chunks that are only whitespace.
                if stmt.trim().is_empty() {
                    continue;
                }
                client.batch_execute(stmt).await.with_context(|| {
                    format!("run_migrations: apply (concurrently stmt) {filename}")
                })?;
            }
            // Restore the pool default for the rest of this connection's life
            // (it is about to be re-acquired fresh below anyway, but this
            // keeps the invariant explicit rather than relying on that).
            client
                .batch_execute("RESET statement_timeout")
                .await
                .context("run_migrations: restore statement_timeout after CONCURRENTLY")?;
        } else {
            // Plain DDL runs as ONE implicit transaction (see the comment
            // above), so `SET LOCAL` scopes the timeout override to just this
            // migration's statements without leaking onto later queries on the
            // same connection. Per Postgres semantics, `SET LOCAL` only takes
            // effect once inside a transaction block: for a file that brings
            // its own explicit `BEGIN;` (0001, 0008), insert the `SET LOCAL`
            // immediately AFTER that `BEGIN;` so it is unambiguously scoped to
            // the explicit block (rather than relying on the implicit
            // whole-string transaction, which a leading `SET LOCAL` before an
            // explicit `BEGIN` would otherwise fold into). A file with no
            // explicit `BEGIN` is wrapped only by the implicit transaction, so
            // prepending is correct and sufficient there.
            let trimmed = stripped_sql.trim_start();
            let sql_with_timeout_exempt = if let Some(rest) = trimmed
                .strip_prefix("BEGIN;")
                .or_else(|| trimmed.strip_prefix("BEGIN"))
            {
                format!("BEGIN;\nSET LOCAL statement_timeout = 0;\n{rest}")
            } else {
                format!("SET LOCAL statement_timeout = 0;\n{sql}")
            };
            client
                .batch_execute(&sql_with_timeout_exempt)
                .await
                .with_context(|| format!("run_migrations: apply {filename}"))?;
        }

        client
            .execute(
                "INSERT INTO schema_migrations (filename) VALUES ($1) ON CONFLICT DO NOTHING",
                &[filename],
            )
            .await
            .with_context(|| format!("run_migrations: record {filename}"))?;

        tracing::info!(filename, "run_migrations: applied");

        // Re-acquire client after each migration so pool recycling is healthy.
        client = get_conn(pool).await?;
    }

    Ok(())
}

// ─── stale-migration reset (C5) ──────────────────────────────────────────────

/// Reset `storage_migrations` rows stuck in `'running'` (process died mid-drain)
/// back to `'pending'`.
///
/// Call once at recorder startup, BEFORE the migration worker loop is spawned.
/// Returns the number of rows reset.  A stuck `running` row blocks the worker
/// from picking up the next `pending` migration; resetting it lets the drain
/// resume from where it was interrupted (the drain is idempotent).
///
/// #9/#10 fix: two additional guards vs the old unconditional reset:
///
/// 1. **`status = 'running'` (not `'cancelled'`)** — the WHERE clause already
///    restricts to `running` rows.  A row the operator cancelled via the cancel API
///    has `status = 'cancelled'` and is naturally excluded; it is never resurrected.
///
/// 2. **`updated_at < now() - interval '2 minutes'`** — a row that was flipped to
///    `running` by the migration worker within the last 2 minutes is still live; do
///    not reset it (the worker may still be in the middle of its first batch after a
///    very recent restart).  The 2-minute guard matches the contract documented in
///    the cross-module audit notes.
///
/// # Errors
///
/// Returns an error if the UPDATE fails.
pub async fn reset_stale_migrations(pool: &Pool) -> Result<u64> {
    let client = get_conn(pool).await?;
    // Only reset rows that are genuinely stale: status is 'running' (cancelled rows
    // have status = 'cancelled' and are not touched here — they are already excluded
    // by the status predicate) AND the row hasn't been touched in the last 2 minutes
    // (a freshly-claimed row from a live worker must not be interrupted).
    let n = client
        .execute(
            r"
            UPDATE storage_migrations
            SET status = 'pending', updated_at = now()
            WHERE status = 'running'
              AND updated_at < now() - interval '2 minutes'
            ",
            &[],
        )
        .await
        .context("reset_stale_migrations")?;
    Ok(n)
}

// ─── ONVIF + source URL update helper (for re-detect flow) ───────────────────

/// Update a camera's ONVIF-discovered source URLs and PTZ capability.
///
/// Called by the `POST /config/cameras/{id}/redetect` handler (in api-routes)
/// after `discover::redetect_camera_streams` returns new URLs.  Keeps the raw
/// SQL in db.rs rather than duplicating it in config_routes.rs.
///
/// `ptz_supported = true` sets `camera_type = 'ptz'`; `false` leaves it
/// unchanged (the operator can tick it manually — Risk R7).
///
/// `source_url` and `source_sub_url` are the RAW camera RTSP URIs returned by
/// the ONVIF `GetStreamUri` call.
///
/// **#6 db fix**: `source_sub_url = $3` used to unconditionally overwrite the
/// sub-stream URL with whatever ONVIF returned — including `None` when the ONVIF
/// probe found no sub-stream.  This silently wiped a working sub-stream whenever
/// the camera responded to ONVIF without advertising one, causing motion analysis
/// and wall tiles (which use the sub) to break.  Now uses
/// `COALESCE($3, source_sub_url)` — a non-NULL incoming value wins (the ONVIF
/// result is authoritative when present); `None` / missing ONVIF sub leaves the
/// existing column value in place.
///
/// `served_by` is set to `"crumb"` after a re-detect because the new sources
/// become Crumb-managed streams.
///
/// # Errors
///
/// Returns an error if the UPDATE fails (e.g. the camera does not exist).
pub async fn update_camera_onvif_and_sources(
    pool: &Pool,
    id: Uuid,
    source_url: Option<&str>,
    source_sub_url: Option<&str>,
    served_by: &str,
    ptz_supported: bool,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            UPDATE cameras SET
                source_url     = COALESCE($2, source_url),
                source_sub_url = COALESCE($3, source_sub_url),
                served_by      = $4,
                camera_type    = CASE
                                    WHEN $5 THEN 'ptz'
                                    ELSE camera_type
                                 END
            WHERE id = $1
            ",
            &[
                &id,
                &source_url,
                &source_sub_url,
                &served_by,
                &ptz_supported,
            ],
        )
        .await
        .context("update_camera_onvif_and_sources")?;
    Ok(())
}

// ─── notifications ────────────────────────────────────────────────────────────

/// A registered push device row (`push_devices`).
///
/// One row per app install per user.  Re-registration updates the row via
/// `INSERT … ON CONFLICT (user_id, install_id) DO UPDATE`.
#[derive(Debug, Clone, Serialize)]
pub struct PushDevice {
    pub id: Uuid,
    pub user_id: Uuid,
    /// Stable per-install identity generated by the app.
    pub install_id: String,
    /// `'android'` | `'ios'` | `'web'`
    pub platform: String,
    /// `'websocket'` | `'unifiedpush'` | `'fcm'`
    pub transport: String,
    /// Absent for WebSocket devices.
    pub push_token: Option<String>,
    pub device_name: Option<String>,
    /// `'home'` | `'away'`
    pub presence: String,
    pub presence_source: Option<String>,
    pub presence_updated_at: Option<DateTime<Utc>>,
    pub last_seen: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

fn push_device_from_row(row: &tokio_postgres::Row) -> PushDevice {
    PushDevice {
        id: row.get("id"),
        user_id: row.get("user_id"),
        install_id: row.get("install_id"),
        platform: row.get("platform"),
        transport: row.get("transport"),
        push_token: row.get("push_token"),
        device_name: row.get("device_name"),
        presence: row.get("presence"),
        presence_source: row.get("presence_source"),
        presence_updated_at: row.get("presence_updated_at"),
        last_seen: row.get("last_seen"),
        created_at: row.get("created_at"),
    }
}

/// Register (or re-register) a push device.
///
/// On conflict with the `(user_id, install_id)` unique index the row is updated
/// in place: platform, transport, push token, name and last-seen are refreshed.
/// Presence is NOT overwritten on re-register — it retains the last-known value.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn register_push_device(
    pool: &Pool,
    user_id: Uuid,
    install_id: &str,
    platform: &str,
    transport: &str,
    push_token: Option<&str>,
    device_name: Option<&str>,
) -> Result<PushDevice> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO push_devices
                (user_id, install_id, platform, transport, push_token, device_name, last_seen)
            VALUES ($1, $2, $3, $4, $5, $6, now())
            ON CONFLICT (user_id, install_id) DO UPDATE SET
                platform    = EXCLUDED.platform,
                transport   = EXCLUDED.transport,
                push_token  = EXCLUDED.push_token,
                device_name = EXCLUDED.device_name,
                last_seen   = now()
            RETURNING id, user_id, install_id, platform, transport, push_token,
                      device_name, presence, presence_source, presence_updated_at,
                      last_seen, created_at
            ",
            &[
                &user_id,
                &install_id,
                &platform,
                &transport,
                &push_token,
                &device_name,
            ],
        )
        .await
        .context("register_push_device")?;
    Ok(push_device_from_row(&row))
}

/// List all push devices owned by `user_id`.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_push_devices(pool: &Pool, user_id: Uuid) -> Result<Vec<PushDevice>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, user_id, install_id, platform, transport, push_token,
                   device_name, presence, presence_source, presence_updated_at,
                   last_seen, created_at
            FROM push_devices
            WHERE user_id = $1
            ORDER BY created_at
            ",
            &[&user_id],
        )
        .await
        .context("list_push_devices")?;
    Ok(rows.iter().map(push_device_from_row).collect())
}

/// Delete a push device by `id`, scoped to `user_id` (prevents cross-user deletion).
///
/// Returns `true` if a row was deleted.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn delete_push_device(pool: &Pool, id: Uuid, user_id: Uuid) -> Result<bool> {
    let client = get_conn(pool).await?;
    let n = client
        .execute(
            "DELETE FROM push_devices WHERE id = $1 AND user_id = $2",
            &[&id, &user_id],
        )
        .await
        .context("delete_push_device")?;
    Ok(n == 1)
}

/// Update the presence state of a single device (identified by `user_id` + `install_id`).
///
/// `presence` must be `'home'` or `'away'`.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn set_device_presence(
    pool: &Pool,
    user_id: Uuid,
    install_id: &str,
    presence: &str,
    source: &str,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            UPDATE push_devices
            SET presence            = $3,
                presence_source     = $4,
                presence_updated_at = now()
            WHERE user_id = $1 AND install_id = $2
            ",
            &[&user_id, &install_id, &presence, &source],
        )
        .await
        .context("set_device_presence")?;
    Ok(())
}

/// Update the presence state of ALL devices owned by `user_id` (webhook/bulk form).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn set_user_presence(
    pool: &Pool,
    user_id: Uuid,
    presence: &str,
    source: &str,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            UPDATE push_devices
            SET presence            = $2,
                presence_source     = $3,
                presence_updated_at = now()
            WHERE user_id = $1
            ",
            &[&user_id, &presence, &source],
        )
        .await
        .context("set_user_presence")?;
    Ok(())
}

/// A notification rule row (`notification_rules`).
#[derive(Debug, Clone, Serialize)]
pub struct NotificationRule {
    pub id: Uuid,
    pub user_id: Uuid,
    /// `None` for the user's default rule; `Some(uuid)` for a per-camera override.
    pub camera_id: Option<Uuid>,
    /// `'off'` | `'away_only'` | `'always'`
    pub presence_mode: String,
    pub notify_motion: bool,
    pub notify_detection: bool,
    /// Absent means "any label".
    pub object_labels: Option<Vec<String>>,
    pub min_score: Option<f32>,
    pub min_duration_secs: Option<i32>,
    pub quiet_start_hour: Option<i32>,
    pub quiet_end_hour: Option<i32>,
    pub cooldown_secs: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

fn notification_rule_from_row(row: &tokio_postgres::Row) -> NotificationRule {
    NotificationRule {
        id: row.get("id"),
        user_id: row.get("user_id"),
        camera_id: row.get("camera_id"),
        presence_mode: row.get("presence_mode"),
        notify_motion: row.get("notify_motion"),
        notify_detection: row.get("notify_detection"),
        object_labels: row.get("object_labels"),
        min_score: row.get("min_score"),
        min_duration_secs: row.get("min_duration_secs"),
        quiet_start_hour: row.get("quiet_start_hour"),
        quiet_end_hour: row.get("quiet_end_hour"),
        cooldown_secs: row.get("cooldown_secs"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

/// Parameters for upserting a notification rule.
#[derive(Debug)]
pub struct UpsertNotificationRuleParams {
    pub user_id: Uuid,
    /// `None` → the user's default rule; `Some(uuid)` → per-camera override.
    pub camera_id: Option<Uuid>,
    pub presence_mode: String,
    pub notify_motion: bool,
    pub notify_detection: bool,
    pub object_labels: Option<Vec<String>>,
    pub min_score: Option<f32>,
    pub min_duration_secs: Option<i32>,
    pub quiet_start_hour: Option<i32>,
    pub quiet_end_hour: Option<i32>,
    pub cooldown_secs: i32,
}

/// Upsert a notification rule.
///
/// Cannot use `ON CONFLICT` against partial unique indexes (which differ by
/// whether `camera_id IS NULL`), so we use a manual update-then-insert approach:
/// first `UPDATE … WHERE user_id=$1 AND camera_id IS NOT DISTINCT FROM $2
/// RETURNING id`; if zero rows, `INSERT … RETURNING *`.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn upsert_notification_rule(
    pool: &Pool,
    p: &UpsertNotificationRuleParams,
) -> Result<NotificationRule> {
    let client = get_conn(pool).await?;

    // Try UPDATE first.
    let opt = client
        .query_opt(
            r"
            UPDATE notification_rules SET
                presence_mode    = $3,
                notify_motion    = $4,
                notify_detection = $5,
                object_labels    = $6,
                min_score        = $7,
                min_duration_secs = $8,
                quiet_start_hour = $9,
                quiet_end_hour   = $10,
                cooldown_secs    = $11,
                updated_at       = now()
            WHERE user_id   = $1
              AND camera_id IS NOT DISTINCT FROM $2
            RETURNING id, user_id, camera_id, presence_mode, notify_motion,
                      notify_detection, object_labels, min_score, min_duration_secs,
                      quiet_start_hour, quiet_end_hour, cooldown_secs,
                      created_at, updated_at
            ",
            &[
                &p.user_id,
                &p.camera_id,
                &p.presence_mode,
                &p.notify_motion,
                &p.notify_detection,
                &p.object_labels,
                &p.min_score,
                &p.min_duration_secs,
                &p.quiet_start_hour,
                &p.quiet_end_hour,
                &p.cooldown_secs,
            ],
        )
        .await
        .context("upsert_notification_rule: update")?;

    if let Some(row) = opt {
        return Ok(notification_rule_from_row(&row));
    }

    // Row did not exist; insert.
    let row = client
        .query_one(
            r"
            INSERT INTO notification_rules
                (user_id, camera_id, presence_mode, notify_motion, notify_detection,
                 object_labels, min_score, min_duration_secs, quiet_start_hour,
                 quiet_end_hour, cooldown_secs)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            RETURNING id, user_id, camera_id, presence_mode, notify_motion,
                      notify_detection, object_labels, min_score, min_duration_secs,
                      quiet_start_hour, quiet_end_hour, cooldown_secs,
                      created_at, updated_at
            ",
            &[
                &p.user_id,
                &p.camera_id,
                &p.presence_mode,
                &p.notify_motion,
                &p.notify_detection,
                &p.object_labels,
                &p.min_score,
                &p.min_duration_secs,
                &p.quiet_start_hour,
                &p.quiet_end_hour,
                &p.cooldown_secs,
            ],
        )
        .await
        .context("upsert_notification_rule: insert")?;
    Ok(notification_rule_from_row(&row))
}

/// List all notification rules for `user_id` (default first, then per-camera).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_notification_rules(pool: &Pool, user_id: Uuid) -> Result<Vec<NotificationRule>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, user_id, camera_id, presence_mode, notify_motion,
                   notify_detection, object_labels, min_score, min_duration_secs,
                   quiet_start_hour, quiet_end_hour, cooldown_secs,
                   created_at, updated_at
            FROM notification_rules
            WHERE user_id = $1
            ORDER BY camera_id NULLS FIRST, created_at
            ",
            &[&user_id],
        )
        .await
        .context("list_notification_rules")?;
    Ok(rows.iter().map(notification_rule_from_row).collect())
}

/// Add (or replace) a snooze for a device.
///
/// Old snoozes for the same `(device_id, camera_id)` are deleted first so
/// each device has at most one active snooze per camera scope.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn add_snooze(
    pool: &Pool,
    device_id: Uuid,
    camera_id: Option<Uuid>,
    until: DateTime<Utc>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    // Remove any existing snooze for this scope first.
    client
        .execute(
            r"
            DELETE FROM notification_snoozes
            WHERE device_id = $1
              AND camera_id IS NOT DISTINCT FROM $2
            ",
            &[&device_id, &camera_id],
        )
        .await
        .context("add_snooze: delete existing")?;
    client
        .execute(
            r"
            INSERT INTO notification_snoozes (device_id, camera_id, until)
            VALUES ($1, $2, $3)
            ",
            &[&device_id, &camera_id, &until],
        )
        .await
        .context("add_snooze: insert")?;
    Ok(())
}

/// Remove an active snooze for a device and camera scope.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn clear_snooze(pool: &Pool, device_id: Uuid, camera_id: Option<Uuid>) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            DELETE FROM notification_snoozes
            WHERE device_id = $1
              AND camera_id IS NOT DISTINCT FROM $2
            ",
            &[&device_id, &camera_id],
        )
        .await
        .context("clear_snooze")?;
    Ok(())
}

/// Return all active snoozes for a device as `(camera_id, until)` pairs.
///
/// A `None` camera_id means "all cameras".  `now` is passed in so the engine
/// can use a consistent timestamp within one tick.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn active_snoozes_for_device(
    pool: &Pool,
    device_id: Uuid,
    now: DateTime<Utc>,
) -> Result<Vec<(Option<Uuid>, DateTime<Utc>)>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT camera_id, until
            FROM notification_snoozes
            WHERE device_id = $1 AND until > $2
            ",
            &[&device_id, &now],
        )
        .await
        .context("active_snoozes_for_device")?;
    Ok(rows
        .iter()
        .map(|r| (r.get("camera_id"), r.get("until")))
        .collect())
}

/// Insert a row into `notification_log`.
///
/// On PASS the engine calls this with `status='suppressed'` and a human-readable
/// `reason` explaining the decision (e.g. `"pass: would deliver (transport
/// pending)"`).  On failure the engine only logs at `tracing::debug!` level and
/// does NOT write to the log table (to avoid polluting it with every dropped
/// event).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn insert_notification_log(
    pool: &Pool,
    event_id: Option<Uuid>,
    camera_id: Option<Uuid>,
    device_id: Option<Uuid>,
    kind: &str,
    status: &str,
    reason: Option<&str>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO notification_log
                (event_id, camera_id, device_id, kind, status, reason)
            VALUES ($1, $2, $3, $4, $5, $6)
            ",
            &[&event_id, &camera_id, &device_id, &kind, &status, &reason],
        )
        .await
        .context("insert_notification_log")?;
    Ok(())
}

/// A notification log row.
#[derive(Debug, Clone, Serialize)]
pub struct NotificationLog {
    pub id: Uuid,
    pub event_id: Option<Uuid>,
    pub camera_id: Option<Uuid>,
    pub device_id: Option<Uuid>,
    pub kind: String,
    pub status: String,
    pub reason: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// List recent notification log rows.
///
/// When `user_id` is `Some` and `is_admin` is false, restrict to rows for
/// devices owned by that user.  When `is_admin` is true, return all rows.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_notification_log(
    pool: &Pool,
    user_id: Option<Uuid>,
    is_admin: bool,
    limit: i64,
) -> Result<Vec<NotificationLog>> {
    let client = get_conn(pool).await?;
    let rows = match (is_admin, user_id) {
        (true, _) | (_, None) => client
            .query(
                r"
                SELECT id, event_id, camera_id, device_id, kind, status, reason, created_at
                FROM notification_log
                ORDER BY created_at DESC
                LIMIT $1
                ",
                &[&limit],
            )
            .await
            .context("list_notification_log (admin)")?,
        (false, Some(uid)) => {
            // Viewer: only rows for their own devices.
            client
                .query(
                    r"
                    SELECT nl.id, nl.event_id, nl.camera_id, nl.device_id, nl.kind,
                           nl.status, nl.reason, nl.created_at
                    FROM notification_log nl
                    WHERE nl.device_id IN (
                        SELECT id FROM push_devices WHERE user_id = $2
                    )
                    ORDER BY nl.created_at DESC
                    LIMIT $1
                    ",
                    &[&limit, &uid],
                )
                .await
                .context("list_notification_log (viewer)")?
        }
    };
    Ok(rows
        .iter()
        .map(|r| NotificationLog {
            id: r.get("id"),
            event_id: r.get("event_id"),
            camera_id: r.get("camera_id"),
            device_id: r.get("device_id"),
            kind: r.get("kind"),
            status: r.get("status"),
            reason: r.get("reason"),
            created_at: r.get("created_at"),
        })
        .collect())
}

/// A minimal event row consumed by the notification engine.
#[derive(Debug, Clone)]
pub struct EngineEvent {
    pub id: Uuid,
    pub camera_id: Uuid,
    pub ts: DateTime<Utc>,
    pub end_ts: Option<DateTime<Utc>>,
    pub label: String,
    pub score: f32,
    pub source_id: String,
    pub zones: Option<Vec<String>>,
    pub lifecycle: String,
}

/// Return events inserted after `after`, oldest first, capped at `limit`.
///
/// The engine calls this on each tick to drain new events from the unified
/// `events` table.  Only `start` lifecycle rows are returned (so each event is
/// processed exactly once at the START boundary; updates/END rows are skipped).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn events_since(
    pool: &Pool,
    after: DateTime<Utc>,
    limit: i64,
) -> Result<Vec<EngineEvent>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, camera_id, ts, end_ts, label,
                   COALESCE(score, 0.0) AS score,
                   COALESCE(source_id, '') AS source_id,
                   zones,
                   COALESCE(lifecycle, 'start') AS lifecycle
            FROM events
            WHERE ts > $1
            ORDER BY ts ASC
            LIMIT $2
            ",
            &[&after, &limit],
        )
        .await
        .context("events_since")?;
    Ok(rows
        .iter()
        .map(|r| EngineEvent {
            id: r.get("id"),
            camera_id: r.get("camera_id"),
            ts: r.get("ts"),
            end_ts: r.get("end_ts"),
            label: r.get("label"),
            score: r.get("score"),
            source_id: r.get("source_id"),
            zones: r.get("zones"),
            lifecycle: r.get("lifecycle"),
        })
        .collect())
}

/// Load all push devices with their owning user's role and camera_ids.
///
/// The engine uses this per-tick to enumerate (device, owner) pairs for
/// fan-out without a per-device DB round-trip.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_devices_with_owner(
    pool: &Pool,
) -> Result<Vec<(PushDevice, crate::types::UserRole, Vec<Uuid>)>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT
                d.id, d.user_id, d.install_id, d.platform, d.transport, d.push_token,
                d.device_name, d.presence, d.presence_source, d.presence_updated_at,
                d.last_seen, d.created_at,
                u.role       AS u_role,
                u.camera_ids AS u_camera_ids
            FROM push_devices d
            JOIN users u ON u.id = d.user_id
            ORDER BY d.user_id, d.created_at
            ",
            &[],
        )
        .await
        .context("list_devices_with_owner")?;

    rows.iter()
        .map(|row| {
            let device = push_device_from_row(row);
            let role_str: String = row.get("u_role");
            let role = crate::types::UserRole::from_str(&role_str)
                .with_context(|| format!("list_devices_with_owner: unknown role '{role_str}'"))?;
            let camera_ids_json: serde_json::Value = row.get("u_camera_ids");
            let camera_ids: Vec<Uuid> = serde_json::from_value(camera_ids_json)
                .context("list_devices_with_owner: deserialise camera_ids")?;
            Ok((device, role, camera_ids))
        })
        .collect()
}

// ─── notification channels ────────────────────────────────────────────────────

/// A third-party outbound notification channel (`notification_channels`).
///
/// One row per integration (Discord, Slack, Pushover, Telegram, ntfy, or a
/// generic webhook).  `user_id = None` means admin-managed global channel.
///
/// Filter behaviour (notify_motion, notify_detection, object_labels, min_score,
/// quiet hours, cooldown, presence) is governed entirely by the **owner's**
/// `notification_rules` (resolved per-camera → user default → system default).
/// The filter columns still exist in the DB but are no longer read by the engine
/// or exposed through the REST API — they are left in place so the schema diff is
/// additive and a future rollback is safe.
#[derive(Debug, Clone, Serialize)]
pub struct NotificationChannel {
    pub id: Uuid,
    /// `None` for global (admin-managed) channels.
    pub user_id: Option<Uuid>,
    /// `'discord'` | `'slack'` | `'pushover'` | `'telegram'` | `'ntfy'` | `'webhook'`
    pub kind: String,
    pub name: String,
    pub enabled: bool,
    /// Per-kind connection config (jsonb). Callers must mask secret fields before
    /// returning to untrusted clients; use [`mask_channel_config`] for that.
    pub config: serde_json::Value,
    /// `None`/empty = all cameras the owner can access.
    pub camera_ids: Option<Vec<Uuid>>,
    pub include_snapshot: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

fn notification_channel_from_row(row: &tokio_postgres::Row) -> NotificationChannel {
    NotificationChannel {
        id: row.get("id"),
        user_id: row.get("user_id"),
        kind: row.get("kind"),
        name: row.get("name"),
        enabled: row.get("enabled"),
        config: row.get("config"),
        camera_ids: row.get("camera_ids"),
        include_snapshot: row.get("include_snapshot"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}

/// Shared SELECT list for `notification_channels`.
///
/// The filter columns (`notify_motion`, `notify_detection`, `object_labels`,
/// `min_score`, `quiet_start_hour`, `quiet_end_hour`, `cooldown_secs`) are
/// intentionally omitted — behaviour is now governed by the owner's
/// `notification_rules`.  The DB columns remain for schema backwards compatibility.
const CHANNEL_COLS: &str = r"
    id, user_id, kind, name, enabled, config,
    camera_ids, include_snapshot, created_at, updated_at
";

/// Parameters for creating a notification channel.
///
/// Mirrors the table columns that the caller supplies; `id` and timestamps are
/// generated by the DB.  The filter columns (`notify_motion`, `notify_detection`,
/// etc.) are not included — behaviour is governed by the owner's
/// `notification_rules`.
#[derive(Debug)]
pub struct CreateChannelParams {
    pub user_id: Option<Uuid>,
    pub kind: String,
    pub name: String,
    pub enabled: bool,
    pub config: serde_json::Value,
    pub camera_ids: Option<Vec<Uuid>>,
    pub include_snapshot: bool,
}

/// Create a new notification channel row.
///
/// # Errors
///
/// Returns an error if the insert fails (e.g. unsupported `kind` value).
pub async fn create_notification_channel(
    pool: &Pool,
    p: &CreateChannelParams,
) -> Result<NotificationChannel> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            &format!(
                r"
                INSERT INTO notification_channels
                    (user_id, kind, name, enabled, config, camera_ids, include_snapshot)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                RETURNING {CHANNEL_COLS}
                "
            ),
            &[
                &p.user_id,
                &p.kind,
                &p.name,
                &p.enabled,
                &p.config,
                &p.camera_ids,
                &p.include_snapshot,
            ],
        )
        .await
        .context("create_notification_channel")?;
    Ok(notification_channel_from_row(&row))
}

/// List notification channels visible to `user_id`.
///
/// Returns the caller's own channels plus global channels (`user_id IS NULL`).
/// When `include_globals` is true (Admin callers should pass true so they also
/// see global channels), global channels are included.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_notification_channels(
    pool: &Pool,
    user_id: Uuid,
    include_globals: bool,
) -> Result<Vec<NotificationChannel>> {
    let client = get_conn(pool).await?;
    let rows = if include_globals {
        client
            .query(
                &format!(
                    r"
                    SELECT {CHANNEL_COLS}
                    FROM notification_channels
                    WHERE user_id = $1 OR user_id IS NULL
                    ORDER BY created_at
                    "
                ),
                &[&user_id],
            )
            .await
            .context("list_notification_channels (with globals)")?
    } else {
        client
            .query(
                &format!(
                    r"
                    SELECT {CHANNEL_COLS}
                    FROM notification_channels
                    WHERE user_id = $1
                    ORDER BY created_at
                    "
                ),
                &[&user_id],
            )
            .await
            .context("list_notification_channels (own)")?
    };
    Ok(rows.iter().map(notification_channel_from_row).collect())
}

/// Fetch a single notification channel by id.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn get_notification_channel(
    pool: &Pool,
    id: Uuid,
) -> Result<Option<NotificationChannel>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            &format!("SELECT {CHANNEL_COLS} FROM notification_channels WHERE id = $1"),
            &[&id],
        )
        .await
        .context("get_notification_channel")?;
    Ok(opt.as_ref().map(notification_channel_from_row))
}

/// Parameters for updating a notification channel.
///
/// `config = None` means "keep the stored config unchanged" (so a PATCH that
/// doesn't supply credentials doesn't wipe them).  Filter fields are omitted —
/// behaviour is governed by the owner's `notification_rules`.
#[derive(Debug)]
pub struct UpdateChannelParams {
    pub id: Uuid,
    pub name: String,
    pub enabled: bool,
    /// `None` → leave `config` column unchanged; `Some(v)` → replace it.
    pub config: Option<serde_json::Value>,
    pub camera_ids: Option<Vec<Uuid>>,
    pub include_snapshot: bool,
}

/// Update a notification channel.
///
/// When `params.config` is `None` the stored `config` column is left unchanged
/// (a PATCH that omits the secret fields won't wipe them).
///
/// Returns `None` when no row with `id` exists.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn update_notification_channel(
    pool: &Pool,
    params: &UpdateChannelParams,
) -> Result<Option<NotificationChannel>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            &format!(
                r"
                UPDATE notification_channels SET
                    name             = $2,
                    enabled          = $3,
                    config           = CASE WHEN $4 THEN $5 ELSE config END,
                    camera_ids       = $6,
                    include_snapshot = $7,
                    updated_at       = now()
                WHERE id = $1
                RETURNING {CHANNEL_COLS}
                "
            ),
            &[
                &params.id,
                &params.name,
                &params.enabled,
                &params.config.is_some(),
                &params.config,
                &params.camera_ids,
                &params.include_snapshot,
            ],
        )
        .await
        .context("update_notification_channel")?;
    Ok(opt.as_ref().map(notification_channel_from_row))
}

/// Delete a notification channel by id.
///
/// Returns `true` when a row was deleted.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn delete_notification_channel(pool: &Pool, id: Uuid) -> Result<bool> {
    let client = get_conn(pool).await?;
    let n = client
        .execute("DELETE FROM notification_channels WHERE id = $1", &[&id])
        .await
        .context("delete_notification_channel")?;
    Ok(n == 1)
}

/// Compute the effective presence for a user: `'home'` when ANY of the user's
/// registered devices has `presence = 'home'`; `'away'` otherwise (no devices,
/// all devices away, or unknown).
///
/// Used by the notification engine when evaluating a channel's
/// `presence_mode` rule against the channel owner.  The fail-safe default
/// (`'away'`) means alerts are NOT silenced when device state is absent —
/// the owner keeps receiving notifications rather than missing them.
///
/// # Errors
///
/// Returns an error if the database query fails.
pub async fn owner_presence(pool: &Pool, user_id: Uuid) -> Result<&'static str> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"SELECT bool_or(presence = 'home') AS any_home
              FROM push_devices WHERE user_id = $1",
            &[&user_id],
        )
        .await
        .context("owner_presence")?;
    // `bool_or` returns NULL when there are no rows, which maps to `false` via
    // `Option<bool>::unwrap_or(false)`.
    let any_home: Option<bool> = row.get("any_home");
    Ok(if any_home.unwrap_or(false) {
        "home"
    } else {
        "away"
    })
}

/// Load all **enabled** channels for engine fan-out.
///
/// Called once per engine tick.  Returns channels with `enabled = true`,
/// ordered by `created_at` so the evaluation order is deterministic.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_enabled_channels(pool: &Pool) -> Result<Vec<NotificationChannel>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            &format!(
                r"
                SELECT {CHANNEL_COLS}
                FROM notification_channels
                WHERE enabled = true
                ORDER BY created_at
                "
            ),
            &[],
        )
        .await
        .context("list_enabled_channels")?;
    Ok(rows.iter().map(notification_channel_from_row).collect())
}

/// Insert a `notification_log` row that references a third-party channel.
///
/// Mirrors [`insert_notification_log`] but accepts `channel_id` instead of
/// `device_id`.  Both may be present but in practice a channel-delivery log row
/// has `device_id = NULL` and a device-delivery log row has `channel_id = NULL`.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn insert_channel_notification_log(
    pool: &Pool,
    event_id: Option<Uuid>,
    camera_id: Option<Uuid>,
    channel_id: Option<Uuid>,
    kind: &str,
    status: &str,
    reason: Option<&str>,
) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute(
            r"
            INSERT INTO notification_log
                (event_id, camera_id, channel_id, kind, status, reason)
            VALUES ($1, $2, $3, $4, $5, $6)
            ",
            &[&event_id, &camera_id, &channel_id, &kind, &status, &reason],
        )
        .await
        .context("insert_channel_notification_log")?;
    Ok(())
}

/// Fetch a camera's `go2rtc_name` and `served_by` for snapshot fetching.
///
/// Returns `None` when no enabled camera with `id` exists.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn get_camera_go2rtc_info(pool: &Pool, id: Uuid) -> Result<Option<(String, String)>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            "SELECT go2rtc_name, COALESCE(served_by, 'crumb') AS served_by FROM cameras WHERE id = $1",
            &[&id],
        )
        .await
        .context("get_camera_go2rtc_info")?;
    Ok(opt.map(|r| (r.get("go2rtc_name"), r.get("served_by"))))
}

// ─── system / health alerts (P0-HEALTH-NOTIFY) ────────────────────────────────
//
// A second, parallel signal path alongside `events`/`notification_rules`: it
// alerts on the things that LOSE footage (recorder/camera down, footage
// evicted before its configured retention, low disk, over-cap policies,
// backup failures, Frigate/MQTT disconnects) rather than camera motion/
// detections. Fed by [`insert_system_event`] (called from watchdogs in
// `services/api/src/notifications.rs` and from the recorder's eviction path),
// consumed by the SAME notification engine, dispatched over the SAME channels.

/// One configurable system/health event type. Seeded by migration 0032; the
/// admin Notifications panel edits these rows via `/system-alerts/rules`.
#[derive(Debug, Clone, Serialize)]
pub struct SystemAlertRule {
    pub event_key: String,
    pub enabled: bool,
    /// Seconds — meaning is event-specific (see migration 0032 doc comment).
    pub threshold_secs: Option<i32>,
    /// Fraction 0..1 — currently only `low_disk` uses this.
    pub threshold_fraction: Option<f32>,
    /// When true, this event ignores the default notification quiet-hours
    /// window (footage-loss-critical events default to `true`).
    pub bypass_quiet_hours: bool,
    pub cooldown_secs: i32,
    pub updated_at: DateTime<Utc>,
}

fn system_alert_rule_from_row(row: &tokio_postgres::Row) -> SystemAlertRule {
    SystemAlertRule {
        event_key: row.get("event_key"),
        enabled: row.get("enabled"),
        threshold_secs: row.get("threshold_secs"),
        threshold_fraction: row.get("threshold_fraction"),
        bypass_quiet_hours: row.get("bypass_quiet_hours"),
        cooldown_secs: row.get("cooldown_secs"),
        updated_at: row.get("updated_at"),
    }
}

const SYSTEM_ALERT_RULE_COLS: &str =
    "event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs, updated_at";

/// List all configured system-alert rules (one row per known `event_key`).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn list_system_alert_rules(pool: &Pool) -> Result<Vec<SystemAlertRule>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            &format!("SELECT {SYSTEM_ALERT_RULE_COLS} FROM system_alert_rules ORDER BY event_key"),
            &[],
        )
        .await
        .context("list_system_alert_rules")?;
    Ok(rows.iter().map(system_alert_rule_from_row).collect())
}

/// Fetch a single system-alert rule by key. Returns `None` if the key is
/// unknown (e.g. an older binary talking to a newer DB, or vice versa).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn get_system_alert_rule(
    pool: &Pool,
    event_key: &str,
) -> Result<Option<SystemAlertRule>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            &format!(
                "SELECT {SYSTEM_ALERT_RULE_COLS} FROM system_alert_rules WHERE event_key = $1"
            ),
            &[&event_key],
        )
        .await
        .context("get_system_alert_rule")?;
    Ok(opt.map(|r| system_alert_rule_from_row(&r)))
}

/// Parameters for [`update_system_alert_rule`]. All fields optional: `None`
/// keeps the stored value unchanged (so a partial PATCH from the admin UI
/// can't accidentally clear a threshold).
#[derive(Debug, Default)]
pub struct UpdateSystemAlertRuleParams {
    pub enabled: Option<bool>,
    pub threshold_secs: Option<Option<i32>>,
    pub threshold_fraction: Option<Option<f32>>,
    pub bypass_quiet_hours: Option<bool>,
    pub cooldown_secs: Option<i32>,
}

/// Update one system-alert rule by `event_key`. Returns `None` if the key
/// does not exist (the caller should treat this as 404 — rules are seeded by
/// migration, never created ad hoc via the API).
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn update_system_alert_rule(
    pool: &Pool,
    event_key: &str,
    p: &UpdateSystemAlertRuleParams,
) -> Result<Option<SystemAlertRule>> {
    let client = get_conn(pool).await?;
    let opt = client
        .query_opt(
            &format!(
                r"
                UPDATE system_alert_rules SET
                    enabled            = COALESCE($2, enabled),
                    threshold_secs     = CASE WHEN $3 THEN $4 ELSE threshold_secs END,
                    threshold_fraction = CASE WHEN $5 THEN $6 ELSE threshold_fraction END,
                    bypass_quiet_hours = COALESCE($7, bypass_quiet_hours),
                    cooldown_secs      = COALESCE($8, cooldown_secs),
                    updated_at         = now()
                WHERE event_key = $1
                RETURNING {SYSTEM_ALERT_RULE_COLS}
                "
            ),
            &[
                &event_key,
                &p.enabled,
                &p.threshold_secs.is_some(),
                &p.threshold_secs.flatten(),
                &p.threshold_fraction.is_some(),
                &p.threshold_fraction.flatten(),
                &p.bypass_quiet_hours,
                &p.cooldown_secs,
            ],
        )
        .await
        .context("update_system_alert_rule")?;
    Ok(opt.map(|r| system_alert_rule_from_row(&r)))
}

/// A single occurrence row from `system_events` — the append-only log the
/// notification engine polls, mirroring [`EngineEvent`] closely enough to
/// reuse the same "poll since last_ts" pattern.
#[derive(Debug, Clone)]
pub struct SystemEvent {
    pub id: Uuid,
    pub event_key: String,
    pub camera_id: Option<Uuid>,
    pub ts: DateTime<Utc>,
    pub detail: Option<String>,
}

/// Record one system/health event occurrence. Called by the watchdogs in
/// `notifications.rs` (recorder heartbeat, camera-offline, low-disk,
/// policy-over-cap, Frigate/MQTT disconnect) and by the recorder's eviction
/// path (`premature_rollover`, via an HTTP callback — see `alerts.rs`).
///
/// This is a pure insert with no dedup: callers are responsible for only
/// calling it on a state transition (e.g. "just went offline") or accept that
/// the engine's own cooldown will collapse repeats into one notification.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn insert_system_event(
    pool: &Pool,
    event_key: &str,
    camera_id: Option<Uuid>,
    detail: Option<&str>,
) -> Result<Uuid> {
    let client = get_conn(pool).await?;
    let row = client
        .query_one(
            r"
            INSERT INTO system_events (event_key, camera_id, detail)
            VALUES ($1, $2, $3)
            RETURNING id
            ",
            &[&event_key, &camera_id, &detail],
        )
        .await
        .context("insert_system_event")?;
    Ok(row.get("id"))
}

/// Return system events with `ts > after`, oldest first, capped at `limit`.
///
/// Mirrors [`events_since`] — the engine's system-event poller uses this to
/// drain new rows on each tick.
///
/// # Errors
///
/// Returns an error if the query fails.
pub async fn system_events_since(
    pool: &Pool,
    after: DateTime<Utc>,
    limit: i64,
) -> Result<Vec<SystemEvent>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, event_key, camera_id, ts, detail
            FROM system_events
            WHERE ts > $1
            ORDER BY ts ASC
            LIMIT $2
            ",
            &[&after, &limit],
        )
        .await
        .context("system_events_since")?;
    Ok(rows
        .iter()
        .map(|r| SystemEvent {
            id: r.get("id"),
            event_key: r.get("event_key"),
            camera_id: r.get("camera_id"),
            ts: r.get("ts"),
            detail: r.get("detail"),
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// R2: `run_migrations`'s advisory lock key must be distinct from
    /// `ensure_named_policies_and_groups`'s — each serialized startup path
    /// owns its own key so a booting api+recorder pair only ever contends
    /// with its OWN concurrent caller on that path, never cross-blocks the
    /// other path. A copy-paste key collision here would silently serialize
    /// two unrelated startup sequences against each other.
    #[test]
    fn advisory_lock_keys_are_distinct() {
        assert_ne!(ENSURE_POLICIES_LOCK_KEY, RUN_MIGRATIONS_LOCK_KEY);
        assert_ne!(ENSURE_POLICIES_LOCK_KEY, RECORDER_SINGLETON_LOCK_KEY);
        assert_ne!(RUN_MIGRATIONS_LOCK_KEY, RECORDER_SINGLETON_LOCK_KEY);
    }

    // ── reap_invalid_indexes — throwaway-DB integration test ─────────────────
    //
    // Opt-in: skips (passes) unless `TEST_DATABASE_URL` points at a reachable
    // Postgres, matching the convention documented at the top of
    // `services/api/tests/support/mod.rs`. Runs entirely inside a uniquely
    // named schema (dropped on the way out via the `Drop` impl below) so it
    // never collides with other tests or leaves anything behind on a shared
    // throwaway DB.
    //
    // We can't easily *interrupt* a real `CREATE INDEX CONCURRENTLY` build to
    // reproduce an INVALID index deterministically in a unit test, but the
    // resulting catalog state is well documented and simple to reproduce
    // directly: flip `pg_index.indisvalid` to `false` for an ordinary index.
    // That is exactly the on-disk state a killed CONCURRENTLY build leaves
    // behind, and it is what [`reap_invalid_indexes`] queries for — so this
    // exercises the real detection + drop logic against a real server.

    /// Read the opt-in throwaway-DB URL, or `None` to skip the test.
    fn test_db_url() -> Option<String> {
        std::env::var("TEST_DATABASE_URL")
            .ok()
            .filter(|s| !s.trim().is_empty())
    }

    /// Owns a uniquely-named schema on the test server; dropped (with
    /// `CASCADE`) when the fixture goes out of scope so repeated runs never
    /// accumulate leftover schemas.
    struct SchemaFixture {
        pool: Pool,
        schema: String,
        base_url: String,
    }

    impl Drop for SchemaFixture {
        fn drop(&mut self) {
            let base_url = self.base_url.clone();
            let schema = self.schema.clone();
            // Best-effort cleanup on a fresh dedicated connection — `Drop` is
            // sync, so spawn the async cleanup rather than block the drop.
            tokio::spawn(async move {
                if let Ok((client, conn)) = tokio_postgres::connect(&base_url, NoTls).await {
                    tokio::spawn(conn);
                    let _ = client
                        .batch_execute(&format!("DROP SCHEMA IF EXISTS {schema} CASCADE"))
                        .await;
                }
            });
        }
    }

    async fn setup_schema(base_url: &str) -> SchemaFixture {
        let schema = format!("crumb_test_{}", Uuid::new_v4().simple());

        // Create the schema on a plain connection.
        {
            let (client, conn) = tokio_postgres::connect(base_url, NoTls)
                .await
                .expect("connect to TEST_DATABASE_URL");
            tokio::spawn(conn);
            client
                .batch_execute(&format!("CREATE SCHEMA {schema}"))
                .await
                .expect("create test schema");
        }

        // Point a pool at that schema via `options=-c search_path=...` (same
        // technique used by the recorder's throwaway-DB tests), URL-encoded.
        let sep = if base_url.contains('?') { '&' } else { '?' };
        let schema_url = format!("{base_url}{sep}options=-c%20search_path%3D{schema}");
        // `run_migrations` holds an advisory-lock connection AND a work
        // connection (via `run_migrations_locked`) concurrently, so a max_size
        // of 2 deadlocks itself waiting for a slot. Give the fixture headroom.
        let pool = build_pool(&schema_url, 8).expect("build_pool (test schema)");

        SchemaFixture {
            pool,
            schema,
            base_url: base_url.to_owned(),
        }
    }

    /// An index left `INVALID` (the on-disk state a killed `CREATE INDEX
    /// CONCURRENTLY` leaves behind) must be detected AND dropped by
    /// [`reap_invalid_indexes`], so a later `CREATE INDEX IF NOT EXISTS` with
    /// the same name actually rebuilds it instead of silently no-op'ing
    /// against the broken catalog entry.
    #[tokio::test]
    async fn reap_invalid_indexes_drops_invalid_index() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: TEST_DATABASE_URL not set");
            return;
        };
        let fx = setup_schema(&url).await;
        let client = get_conn(&fx.pool).await.expect("get_conn");

        client
            .batch_execute(
                r"
                CREATE TABLE widgets (id int PRIMARY KEY, name text);
                CREATE INDEX widgets_name_idx ON widgets (name);
                ",
            )
            .await
            .expect("create table + index");

        // Simulate the catalog state a killed CREATE INDEX CONCURRENTLY
        // leaves behind: the index exists but is marked NOT VALID.
        client
            .batch_execute(
                r"
                UPDATE pg_index SET indisvalid = false
                WHERE indexrelid = 'widgets_name_idx'::regclass;
                ",
            )
            .await
            .expect("mark index invalid");

        let still_present_before: bool = client
            .query_one(
                "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'widgets_name_idx')",
                &[],
            )
            .await
            .expect("check index exists before reap")
            .get(0);
        assert!(still_present_before, "fixture setup: index should exist");

        reap_invalid_indexes(&client)
            .await
            .expect("reap_invalid_indexes");

        let still_present_after: bool = client
            .query_one(
                "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'widgets_name_idx')",
                &[],
            )
            .await
            .expect("check index exists after reap")
            .get(0);
        assert!(
            !still_present_after,
            "reap_invalid_indexes must DROP an INVALID index so a later \
             CREATE INDEX IF NOT EXISTS rebuilds it"
        );

        // A VALID index must be left completely alone.
        client
            .batch_execute("CREATE INDEX widgets_id_extra_idx ON widgets (id)")
            .await
            .expect("create a second, valid index");
        reap_invalid_indexes(&client)
            .await
            .expect("reap_invalid_indexes (second pass, nothing invalid left)");
        let valid_index_survives: bool = client
            .query_one(
                "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'widgets_id_extra_idx')",
                &[],
            )
            .await
            .expect("check valid index still exists")
            .get(0);
        assert!(
            valid_index_survives,
            "reap_invalid_indexes must never touch a VALID index"
        );
    }

    // ── thumbnail_grid_slots — pure grid math, no DB needed ───────────────────

    /// The grid must floor to the interval on the wall-clock epoch (not anchor
    /// to `start`) and must exclude a slot landing exactly on `end` (half-open
    /// range), matching `filmstrip::generate_synthetic_timestamps`'s original
    /// contract now that both share this implementation.
    #[test]
    fn thumbnail_grid_slots_floors_and_excludes_end() {
        let base = Utc
            .timestamp_millis_opt(1_700_000_000_000)
            .single()
            .unwrap();
        // start is 2s past a 5s-grid boundary; the first slot must still be
        // the grid boundary at-or-before start, i.e. `base`, not `start`.
        let start = base + chrono::Duration::seconds(2);
        let end = base + chrono::Duration::seconds(15); // exactly a grid multiple
        let slots = thumbnail_grid_slots(start, end, 5);
        let expected: Vec<_> = [0, 5, 10]
            .iter()
            .map(|s| base + chrono::Duration::seconds(*s))
            .collect();
        assert_eq!(
            slots, expected,
            "grid floors to the epoch-aligned interval and excludes a slot at exactly `end`"
        );
    }

    #[test]
    fn thumbnail_grid_slots_empty_when_end_not_after_start() {
        let t = Utc
            .timestamp_millis_opt(1_700_000_000_000)
            .single()
            .unwrap();
        assert!(thumbnail_grid_slots(t, t, 5).is_empty());
        assert!(thumbnail_grid_slots(t + chrono::Duration::seconds(5), t, 5).is_empty());
    }

    // ── list_thumbnail_times — coverage-aware grid, throwaway-DB integration test ──
    //
    // Opt-in: skips (passes) unless `TEST_DATABASE_URL` points at a reachable
    // Postgres, same convention as `reap_invalid_indexes_drops_invalid_index`
    // above.
    //
    // Isolation model — deliberately NOT the `setup_schema` search_path trick the
    // reap test uses: this test needs the REAL schema (segments's FKs to
    // cameras/storages, cameras' FK to recording_policies), which means running
    // the full `run_migrations`, and `run_migrations` does not survive the
    // per-connection `search_path` isolation (it re-acquires pooled connections
    // and runs `CREATE INDEX CONCURRENTLY` statements as their own sessions,
    // where the schema-scoping does not hold; migration 0014 then fails looking
    // up `storage_migrations`). Instead we mirror the PROVEN model in
    // `services/api/tests/support/mod.rs`: migrate the shared database in its
    // real `public` schema (idempotent + advisory-locked, so concurrent test
    // binaries serialize safely), then isolate this test's DATA by a freshly
    // generated `camera_id`. `list_thumbnail_times` filters solely by
    // `camera_id`, so a unique camera is complete isolation from any other
    // rows in the shared throwaway DB — no private schema, no teardown needed.

    /// Build a size-8 pool at the raw (public-schema) URL and run migrations.
    /// The pool needs headroom because `run_migrations` holds an advisory-lock
    /// connection AND a work connection concurrently (a max_size of 2 would
    /// deadlock itself).
    async fn migrated_public_pool(url: &str) -> Pool {
        let pool = build_pool(url, 8).expect("build_pool (public)");
        run_migrations(&pool)
            .await
            .expect("run_migrations (public schema)");
        pool
    }

    /// Insert a non-default `recording_policies` row and return its id. Using a
    /// non-default policy sidesteps the `one_default_policy` partial-unique
    /// constraint entirely (this test never needs the global default), and the
    /// explicit column set mirrors `services/api/tests/support/mod.rs`'s seed so
    /// it stays valid as the schema grows.
    async fn insert_nondefault_policy(pool: &Pool) -> Uuid {
        let client = get_conn(pool).await.expect("get_conn (insert_policy)");
        let row = client
            .query_one(
                r"
                INSERT INTO recording_policies (
                    is_default, mode, live_storage_id, live_retention_hours,
                    archive_enabled, archive_storage_id, archive_schedule, archive_retention_hours,
                    motion_pre_seconds, motion_post_seconds, motion_sensitivity,
                    motion_keyframes_only, record_stream
                )
                VALUES (
                    false, 'continuous', NULL, 48,
                    false, NULL, NULL, NULL,
                    5, 10, 'dynamic',
                    false, 'main'
                )
                RETURNING id
                ",
                &[],
            )
            .await
            .expect("insert non-default recording_policies row");
        row.get(0)
    }

    /// Seed a camera with a UNIQUE name/go2rtc_name on the given policy and
    /// return its id — the unique id is this test's isolation boundary.
    async fn seed_camera_for_test(pool: &Pool, policy_id: Uuid) -> Uuid {
        let suffix = Uuid::new_v4().simple().to_string();
        let params = CreateCameraParams {
            name: &format!("cam_{suffix}"),
            go2rtc_name: &format!("go2rtc_{suffix}"),
            main_url: "rtsp://127.0.0.1:18554/does-not-matter",
            sub_url: None,
            source_url: None,
            source_sub_url: None,
            enabled: true,
            policy_id,
            motion_mask: None,
            onvif_motion: false,
            motion_source: "pixel",
            motion_algorithm: "census",
            camera_type: None,
            icon: None,
            served_by: "crumb",
            source_camera_name: None,
            onvif_host: None,
            onvif_port: None,
            onvif_user: None,
            onvif_password: None,
        };
        create_camera(pool, &params)
            .await
            .expect("create_camera")
            .id
    }

    /// Insert a `main`-stream segment row directly (no real file — this test
    /// only exercises the coverage query, never opens the path).
    async fn insert_test_segment(
        pool: &Pool,
        camera_id: Uuid,
        storage_id: Uuid,
        start_ts: DateTime<Utc>,
        end_ts: DateTime<Utc>,
    ) {
        let client = get_conn(pool)
            .await
            .expect("get_conn (insert_test_segment)");
        let duration_ms = (end_ts - start_ts).num_milliseconds();
        #[allow(clippy::cast_possible_truncation)]
        let duration_ms = duration_ms as i32;
        client
            .execute(
                r"
                INSERT INTO segments
                    (camera_id, storage_id, stage, path, stream, start_ts, end_ts, duration_ms, has_motion, size_bytes)
                VALUES ($1, $2, 'live', 'seg.mp4', 'main', $3, $4, $5, false, 64)
                ",
                &[&camera_id, &storage_id, &start_ts, &end_ts, &duration_ms],
            )
            .await
            .expect("insert test segment");
    }

    /// A recording gap in the middle of the requested window must never
    /// surface a slot, and the two segment BOUNDARIES must resolve per the
    /// half-open `[start_ts, end_ts)` convention `resolve_segment` already
    /// uses: a slot exactly at a segment's `end_ts` is NOT covered (that
    /// instant belongs to whatever comes next, if anything), and a slot
    /// exactly at the following segment's `start_ts` IS covered.
    ///
    /// Layout (grid = 5s, `base` an arbitrary 5s-grid-aligned instant):
    /// ```text
    /// offset(s):  0    5    10   15   20   25   30
    /// segment:    [--- seg1 ---)     [--- seg2 ---)
    /// grid slot:  ✓    ✓    ✗    ✗    ✓    ✓
    /// ```
    /// Slot 10 sits exactly on seg1's `end_ts` (excluded); slot 20 sits
    /// exactly on seg2's `start_ts` (included); slots 10 and 15 are the pure
    /// mid-gap case (excluded).
    #[tokio::test]
    async fn list_thumbnail_times_excludes_gap_slots() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: TEST_DATABASE_URL not set");
            return;
        };
        let pool = migrated_public_pool(&url).await;

        let policy_id = insert_nondefault_policy(&pool).await;
        let camera_id = seed_camera_for_test(&pool, policy_id).await;
        // Unique storage name — the shared public DB persists rows across runs
        // and `storages.name` is UNIQUE.
        let storage_name = format!("test-storage-{}", Uuid::new_v4().simple());
        let storage_id = create_storage(&pool, &storage_name, "/does/not/matter", None, None)
            .await
            .expect("create_storage")
            .id;

        let base = Utc
            .timestamp_millis_opt(1_700_000_000_000)
            .single()
            .unwrap();
        let sec = |n: i64| base + chrono::Duration::seconds(n);

        // seg1 covers [0, 10); a real recording gap sits in [10, 20); seg2
        // covers [20, 30).
        insert_test_segment(&pool, camera_id, storage_id, sec(0), sec(10)).await;
        insert_test_segment(&pool, camera_id, storage_id, sec(20), sec(30)).await;

        let times = list_thumbnail_times(&pool, camera_id, sec(0), sec(30), 5)
            .await
            .expect("list_thumbnail_times");

        let expected = vec![sec(0), sec(5), sec(20), sec(25)];
        assert_eq!(
            times, expected,
            "gap slots (10, 15) must be excluded; the segment-end boundary (10) \
             must be excluded and the next segment's start boundary (20) included"
        );
    }

    // ── scrub-preview settings (issue #10) — get/set roundtrip + clamps ──────
    //
    // `server_settings` is a process-wide singleton row (see the `clip_preroll`/
    // `update_check_enabled` setters above, and `auth_rbac.rs`'s admin-gate walk
    // in the api integration suite, which also touches this row from a
    // different test binary). This test therefore asserts only what IT writes
    // comes back correctly — never the row's state before/after — so it can't
    // flake against unrelated concurrent writers to the same shared row.

    #[tokio::test]
    async fn scrub_pregen_settings_roundtrip_and_clamps() {
        let Some(url) = test_db_url() else {
            eprintln!("skipping: TEST_DATABASE_URL not set");
            return;
        };
        let pool = migrated_public_pool(&url).await;

        // ── enabled: plain bool roundtrip ──
        set_thumb_pregen_enabled(&pool, true)
            .await
            .expect("set enabled=true");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set enabled=true");
        assert_eq!(s.pregen_enabled, Some(true));
        set_thumb_pregen_enabled(&pool, false)
            .await
            .expect("set enabled=false");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set enabled=false");
        assert_eq!(s.pregen_enabled, Some(false));

        // ── lookback hours: in-range roundtrip + clamp on both ends ──
        set_thumb_pregen_lookback_hours(&pool, 10)
            .await
            .expect("set lookback=10");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set lookback=10");
        assert_eq!(s.pregen_lookback_hours, Some(10));
        set_thumb_pregen_lookback_hours(&pool, -5)
            .await
            .expect("set lookback=-5 (below floor)");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set lookback=-5");
        assert_eq!(
            s.pregen_lookback_hours,
            Some(0),
            "must clamp to the 0 floor"
        );
        set_thumb_pregen_lookback_hours(&pool, 9999)
            .await
            .expect("set lookback=9999 (above ceiling)");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set lookback=9999");
        assert_eq!(
            s.pregen_lookback_hours,
            Some(168),
            "must clamp to the 168h (1 week) ceiling"
        );

        // ── scan secs: in-range roundtrip + clamp on both ends ──
        set_thumb_pregen_scan_secs(&pool, 120)
            .await
            .expect("set scan=120");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set scan=120");
        assert_eq!(s.pregen_scan_secs, Some(120));
        set_thumb_pregen_scan_secs(&pool, 1)
            .await
            .expect("set scan=1 (below floor)");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set scan=1");
        assert_eq!(s.pregen_scan_secs, Some(5), "must clamp to the 5s floor");
        set_thumb_pregen_scan_secs(&pool, 999_999)
            .await
            .expect("set scan=999999 (above ceiling)");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set scan=999999");
        assert_eq!(
            s.pregen_scan_secs,
            Some(3600),
            "must clamp to the 3600s ceiling"
        );

        // ── cache max bytes: in-range roundtrip + floor clamp (no ceiling, D5) ──
        set_thumb_cache_max_bytes(&pool, 10_000_000_000)
            .await
            .expect("set cache_max_bytes=10GB");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set cache_max_bytes=10GB");
        assert_eq!(s.cache_max_bytes, Some(10_000_000_000));
        set_thumb_cache_max_bytes(&pool, 0)
            .await
            .expect("set cache_max_bytes=0 (below floor)");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set cache_max_bytes=0");
        assert_eq!(
            s.cache_max_bytes,
            Some(104_857_600),
            "must clamp to the 100 MiB floor (D5)"
        );

        // ── cache ttl seconds: in-range roundtrip + clamp on both ends ──
        set_thumb_cache_ttl_seconds(&pool, 86_400)
            .await
            .expect("set ttl=1 day");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set ttl=1 day");
        assert_eq!(s.cache_ttl_seconds, Some(86_400));
        set_thumb_cache_ttl_seconds(&pool, 60)
            .await
            .expect("set ttl=60s (below floor)");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set ttl=60s");
        assert_eq!(
            s.cache_ttl_seconds,
            Some(3600),
            "must clamp to the 1h floor"
        );
        set_thumb_cache_ttl_seconds(&pool, 999_999_999)
            .await
            .expect("set ttl=999999999 (above ceiling)");
        let s = get_scrub_pregen_settings(&pool)
            .await
            .expect("get after set ttl=999999999");
        assert_eq!(
            s.cache_ttl_seconds,
            Some(31_536_000),
            "must clamp to the 1-year ceiling"
        );
    }
}
