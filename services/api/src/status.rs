// SPDX-License-Identifier: AGPL-3.0-or-later

//! System status route.
//!
//! # Endpoints
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `GET`  | `/status` | Bearer (any user) | Per-camera recording health (all users); storages admin-only |
//!
//! # Implementation details
//!
//! ## Storage free space
//!
//! For each storage row, we call `db::storage_used_bytes` (cached for 30 s,
//! since it is a full `SUM` over the storage's segments) to get the
//! segment-index tracked usage.  Free disk space is queried via the POSIX
//! `statvfs` syscall through `libc` — this works on read-only mounts and
//! requires no extra crate beyond `libc` which is already present as a
//! transitive dependency.
//!
//! ## Camera recording health
//!
//! For each camera, `db::camera_last_segment` returns the most recent segment.
//! A camera is considered "recording" when `last_segment.end_ts` is within
//! `HEALTH_STALENESS_SECS` of the current time.  We use a conservative 12 s
//! (2 × the 6 s maximum `SEGMENT_SECONDS` value).
//!
//! ## Recorder heartbeat
//!
//! The recorder does not yet write a heartbeat to Postgres.  Returns `None`
//! until the recorder team adds a `heartbeats` table in a future migration.

use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

use axum::{extract::State, routing::get, Json, Router};
use tokio::task::JoinSet;
use tracing::warn;
use uuid::Uuid;

use crumb_common::{
    db,
    types::{RecordingMode, UserRole},
};

use crate::{
    auth_mw::AuthUser,
    dto::{CameraStatusEntry, StorageStatusEntry, SystemStatusResponse},
    error::ApiError,
    state::AppState,
};

/// How recently a segment's `end_ts` must be for the camera to be considered
/// "recording".  2 × the maximum `SEGMENT_SECONDS` (6 s) = 12 s, with a
/// small buffer to tolerate network jitter.
const HEALTH_STALENESS_SECS: i64 = 15;

/// How recently a segment with motion must have ended for the camera to be
/// considered to have motion "right now".  ~2 × the max segment length so the
/// live indicator clears within a segment or two after motion stops.
const MOTION_FRESHNESS_SECS: i64 = 12;

/// How long a storage's `used_bytes` figure is reused. The figure is a
/// `SUM(size_bytes)` over every segment row of the storage, far too heavy to
/// recompute on every 2 to 3 s admin `/status` poll; the consumers (dashboard,
/// recording alerts, admin console) display it and tolerate a short lag.
const USED_BYTES_TTL: Duration = Duration::from_secs(30);

/// Per-key value cache with a fixed time-to-live.
struct TtlCache<K, V> {
    ttl: Duration,
    entries: HashMap<K, (Instant, V)>,
}

impl<K: std::hash::Hash + Eq, V: Copy> TtlCache<K, V> {
    fn new(ttl: Duration) -> Self {
        Self {
            ttl,
            entries: HashMap::new(),
        }
    }

    /// The cached value for `key`, if present and not older than the TTL at `now`.
    fn get(&self, key: &K, now: Instant) -> Option<V> {
        self.entries
            .get(key)
            .filter(|(at, _)| now.saturating_duration_since(*at) < self.ttl)
            .map(|(_, v)| *v)
    }

    fn put(&mut self, key: K, value: V, now: Instant) {
        self.entries.insert(key, (now, value));
    }
}

static USED_BYTES_CACHE: OnceLock<Mutex<TtlCache<Uuid, i64>>> = OnceLock::new();

fn used_bytes_cache() -> &'static Mutex<TtlCache<Uuid, i64>> {
    USED_BYTES_CACHE.get_or_init(|| Mutex::new(TtlCache::new(USED_BYTES_TTL)))
}

/// `db::storage_used_bytes` behind a short TTL cache. A failed query returns 0
/// (as before) and is not cached.
async fn cached_storage_used_bytes(pool: &deadpool_postgres::Pool, storage_id: Uuid) -> i64 {
    if let Some(v) = used_bytes_cache()
        .lock()
        .ok()
        .and_then(|c| c.get(&storage_id, Instant::now()))
    {
        return v;
    }
    match db::storage_used_bytes(pool, storage_id).await {
        Ok(v) => {
            if let Ok(mut c) = used_bytes_cache().lock() {
                c.put(storage_id, v, Instant::now());
            }
            v
        }
        Err(e) => {
            warn!(
                storage_id = %storage_id,
                error = %e,
                "failed to query storage_used_bytes"
            );
            0
        }
    }
}

/// Mount status routes onto the root router.
pub fn routes() -> Router<AppState> {
    Router::new().route("/status", get(system_status))
}

/// `GET /status` — system health snapshot (admin only).
///
/// Returns per-storage disk metrics and per-camera recording health derived
/// from the live segment index.
async fn system_status(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<SystemStatusResponse>, ApiError> {
    let pool = state.pool();
    let now = chrono::Utc::now();
    let is_admin = matches!(user.role, UserRole::Admin);

    // ── 1. storages (admin-only — don't leak disk paths/sizes to viewers) ──────
    let storages = if is_admin {
        db::list_storages(pool).await?
    } else {
        Vec::new()
    };
    let mut storage_entries: Vec<StorageStatusEntry> = Vec::with_capacity(storages.len());

    for storage in &storages {
        let used_bytes = cached_storage_used_bytes(pool, storage.id).await;

        let (fs_total_bytes, free_bytes) = match statvfs_bytes(&storage.path) {
            Some((total, free)) => (Some(total), Some(free)),
            None => (None, None),
        };

        storage_entries.push(StorageStatusEntry {
            id: storage.id,
            name: storage.name.clone(),
            path: storage.path.clone(),
            total_bytes: storage.total_bytes,
            fs_total_bytes,
            free_bytes,
            used_bytes,
            icon: crumb_common::icons::storage_icon_kind(&storage.name, storage.icon.as_deref())
                .to_owned(),
        });
    }

    // ── 2. cameras ────────────────────────────────────────────────────────────
    // Viewers only see the cameras scoped to them; admins see all.
    let cameras: Vec<_> = db::list_cameras_all(pool)
        .await?
        .into_iter()
        .filter(|c| user.can_access_camera(c.id))
        .collect();
    // Query each camera's last segment CONCURRENTLY (was a sequential loop — N
    // round-trips serialized into a multi-second /status hang at scale). Spawn one
    // task per camera; results carry their index so the response order is stable.
    let mut set: JoinSet<(usize, CameraStatusEntry)> = JoinSet::new();
    for (i, camera) in cameras.iter().enumerate() {
        let pool = pool.clone();
        let id = camera.id;
        let name = camera.name.clone();
        let enabled = camera.enabled;
        let mode = camera.policy.mode;
        set.spawn(async move {
            let last_seg = db::camera_last_segment(&pool, id)
                .await
                .unwrap_or_else(|e| {
                    warn!(camera_id = %id, error = %e, "failed to query camera_last_segment");
                    None
                });
            let last_segment_end = last_seg.as_ref().map(|s| s.end_ts);
            let (recording, recent_motion) = match mode {
                // Continuous cameras record whenever they're online, so a fresh
                // last segment means "recording now".
                RecordingMode::Continuous => match &last_seg {
                    Some(seg) => {
                        let age = (now - seg.end_ts).num_seconds();
                        (
                            age <= HEALTH_STALENESS_SECS,
                            seg.has_motion && age <= MOTION_FRESHNESS_SECS,
                        )
                    }
                    None => (false, false),
                },
                // Motion cameras index every segment continuously, so the latest
                // segment is always fresh and can't distinguish recording from
                // idle. Gate the REC indicator on recent MOTION instead.
                RecordingMode::Motion => {
                    let last_motion = db::camera_last_motion_segment(&pool, id)
                        .await
                        .unwrap_or_else(|e| {
                            warn!(camera_id = %id, error = %e, "failed to query camera_last_motion_segment");
                            None
                        });
                    let recording = last_motion
                        .as_ref()
                        .is_some_and(|s| (now - s.end_ts).num_seconds() <= MOTION_FRESHNESS_SECS);
                    (recording, recording)
                }
            };
            (
                i,
                CameraStatusEntry {
                    id,
                    name,
                    enabled,
                    recording,
                    recent_motion,
                    last_segment_end,
                },
            )
        });
    }
    let mut indexed: Vec<(usize, CameraStatusEntry)> = Vec::with_capacity(cameras.len());
    while let Some(res) = set.join_next().await {
        if let Ok(pair) = res {
            indexed.push(pair);
        }
    }
    indexed.sort_by_key(|(i, _)| *i);
    let camera_entries: Vec<CameraStatusEntry> = indexed.into_iter().map(|(_, e)| e).collect();

    // ── 3. recorder heartbeat ─────────────────────────────────────────────────
    // Read the singleton liveness row the recorder upserts every ~10 s.  A
    // failed read is non-fatal: report `None` (UI shows "heartbeat —") rather
    // than failing the whole status call.
    let hb = db::read_recorder_heartbeat(pool).await.unwrap_or_else(|e| {
        warn!(error = %e, "failed to read recorder heartbeat");
        None
    });
    let (recorder_heartbeat, recorder_pid, recorder_active_cameras) = match hb {
        Some(h) => (Some(h.updated_at), h.pid, Some(h.active_cameras)),
        None => (None, None, None),
    };

    // ── 4. config fingerprint ─────────────────────────────────────────────────
    // Lets clients detect a server-side config change (stream URL, mode, retention,
    // enable/disable, …) and silently re-fetch + reconnect. Non-fatal: an empty
    // string on error just means "no change signal this tick".
    let config_version = db::config_version(pool).await.unwrap_or_else(|e| {
        warn!(error = %e, "failed to compute config_version");
        String::new()
    });

    // Platform-wide bookmarks-UI toggle (clients hide the bookmark button when
    // false). Non-fatal: default to enabled on a read error.
    let bookmarks_enabled = db::get_bookmarks_enabled(pool).await.unwrap_or(true);

    Ok(Json(SystemStatusResponse {
        storages: storage_entries,
        cameras: camera_entries,
        recorder_heartbeat,
        recorder_pid,
        recorder_active_cameras,
        config_version,
        bookmarks_enabled,
    }))
}

// ─── disk size via statvfs ─────────────────────────────────────────────────────

/// Query `(total_bytes, free_bytes)` on the filesystem containing `path` using
/// the POSIX `statvfs` syscall.
///
/// Returns `None` when the path does not exist or the syscall fails (e.g. the
/// storage is unmounted).  `statvfs` works on read-only bind mounts.
fn statvfs_bytes(path: &str) -> Option<(i64, i64)> {
    // SAFETY: we pass a valid C string built from `path`.  `statvfs` is a
    // well-defined POSIX syscall; the only invariant is that `buf` is a valid
    // pointer to a zeroed `libc::statvfs` struct, which we guarantee by
    // value-initialising it with `std::mem::zeroed()`.
    #[cfg(unix)]
    {
        use std::ffi::CString;

        let c_path = CString::new(path.as_bytes()).ok()?;
        // SAFETY: `buf` is initialised before use; pointer is valid for the
        // lifetime of the call; no aliasing issues.
        let mut buf = unsafe { std::mem::zeroed::<libc::statvfs>() };
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &raw mut buf) };
        if rc != 0 {
            return None;
        }
        // Blocks are `f_bsize` bytes each. `f_blocks` = total data blocks,
        // `f_bavail` = blocks available to a NON-root writer (we use this, not
        // `f_bfree`, which includes the ext4 root reserve the non-root services
        // can't use → over-reported free space; issue #72). All unsigned;
        // products fit i64 for any realistic disk size.
        // cast_lossless: c_ulong = u64 on x86_64 Linux — alias, not identical type.
        #[allow(clippy::cast_lossless)]
        let bsize = buf.f_bsize as u64;
        #[allow(clippy::cast_lossless)]
        let total = (buf.f_blocks as u64).saturating_mul(bsize);
        #[allow(clippy::cast_lossless)]
        let free = (buf.f_bavail as u64).saturating_mul(bsize);
        Some((i64::try_from(total).ok()?, i64::try_from(free).ok()?))
    }

    #[cfg(not(unix))]
    {
        // Non-Unix build (e.g. cross-compilation checks on Windows CI).
        let _ = path;
        None
    }
}

#[cfg(test)]
mod used_bytes_cache_tests {
    use super::*;

    #[test]
    fn value_is_reused_within_ttl_and_expires_after() {
        let t0 = Instant::now();
        let mut c: TtlCache<u8, i64> = TtlCache::new(Duration::from_secs(30));
        assert_eq!(c.get(&1, t0), None);
        c.put(1, 42, t0);
        assert_eq!(c.get(&1, t0 + Duration::from_secs(29)), Some(42));
        assert_eq!(c.get(&1, t0 + Duration::from_secs(30)), None);
        assert_eq!(c.get(&2, t0), None);
        c.put(1, 43, t0 + Duration::from_secs(31));
        assert_eq!(c.get(&1, t0 + Duration::from_secs(32)), Some(43));
    }
}
