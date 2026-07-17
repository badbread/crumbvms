// SPDX-License-Identifier: AGPL-3.0-or-later

//! Per-camera storage / usage statistics route.
//!
//! # Endpoints
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `GET`  | `/stats/cameras` | Bearer (admin only) | Per-camera storage + ingest stats |
//!
//! # Access control
//!
//! Admin only — the response exposes total disk consumption per camera and a
//! live ingest rate, which is operator-level capacity-planning data (the same
//! class of information the admin-only storages block in `/status` carries).
//! Non-admins receive `403 Forbidden`.
//!
//! # Implementation details
//!
//! All numbers are derived from the `segments` index via
//! [`db::camera_storage_stats`] (a single grouped SQL query). Cameras with no
//! recorded segments are included with zeroed byte/count fields and `null`
//! timestamps, so the desktop Statistics view can list every camera.
//!
//! Two derived fields are computed server-side from the raw DB columns:
//!
//! * `gb_per_hour` — `recent_bytes / 1e9` divided by the trailing-24h span in
//!   hours, giving the camera's *current* ingest rate (reflects today's
//!   settings, not the lifetime average). `0.0` when there is no recent
//!   footage.
//! * `retention_hours` — `newest_ts - oldest_ts` in hours, i.e. how much
//!   wall-clock history is currently on disk. `0.0` when the camera has no
//!   segments.

use std::collections::HashMap;

use axum::{extract::State, routing::get, Json, Router};

use chrono::{DateTime, Utc};
use serde::Serialize;
use uuid::Uuid;

use crumb_common::{db, types::UserRole};

use crate::{auth_mw::AdminUser, auth_mw::AuthUser, error::ApiError, state::AppState};

/// Cheap stats routes — mounted in `json_routes` (rate-limited, gzip, 30 s
/// timeout), alongside `/status`. Both are single grouped DB queries.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/stats/cameras", get(cameras_stats))
        .route("/stats/policies", get(policy_stats))
        .route("/stats/storage", get(storage_advisor))
}

/// Heavy stats routes — mounted with `media_routes` (NO 30 s timeout). The
/// on-demand `/stats/policies/verify` walks the media mounts file-by-file, which
/// can legitimately exceed 30 s on a large/slow archive; under the json timeout
/// it would 408 while the non-cancellable `spawn_blocking` walk kept running.
pub fn heavy_routes() -> Router<AppState> {
    Router::new().route("/stats/policies/verify", get(policy_verify))
}

/// Per-camera storage + ingest statistics in the `/stats/cameras` response.
#[derive(Debug, Serialize)]
pub struct CameraStatDto {
    pub camera_id: Uuid,
    pub name: String,
    /// Lifetime bytes consumed by this camera's recorded segments.
    pub total_bytes: i64,
    /// Lifetime count of recorded segments.
    pub segment_count: i64,
    /// Oldest segment `start_ts`, `null` when the camera has no segments.
    pub oldest_ts: Option<DateTime<Utc>>,
    /// Newest segment `end_ts`, `null` when the camera has no segments.
    pub newest_ts: Option<DateTime<Utc>>,
    /// Current ingest rate in gigabytes per hour, derived from the trailing-24h
    /// window. `0.0` when there is no footage in that window.
    pub gb_per_hour: f64,
    /// Hours of footage currently on disk (`newest_ts - oldest_ts`). `0.0` when
    /// the camera has no segments.
    pub retention_hours: f64,
    /// Latest sampled CPU usage of this camera's ffmpeg children, as a percentage
    /// of one core (so a camera can exceed 100% across both its ffmpeg processes).
    /// `0.0` when the recorder hasn't sampled the camera or the sample is stale
    /// (`> 60 s` old).
    pub cpu_pct: f64,
    /// Latest sampled resident memory (MB) of this camera's ffmpeg children.
    /// `0.0` when never sampled or stale.
    pub mem_mb: f64,
    /// Latest sampled GPU utilisation (%) attributed to this camera's motion
    /// decode. `null` when GPU telemetry is unavailable (e.g. no `nvidia-smi` in
    /// the recorder container), the camera has never been sampled, or the sample
    /// is stale.
    pub gpu_pct: Option<f64>,
}

/// `GET /stats/cameras` response.
#[derive(Debug, Serialize)]
pub struct CameraStatsResponse {
    pub cameras: Vec<CameraStatDto>,
    /// Server time the snapshot was computed (ISO 8601).
    pub generated_at: DateTime<Utc>,
}

/// `GET /stats/cameras` — per-camera storage + ingest statistics (admin only).
///
/// Returns lifetime storage consumption, segment counts, recording span, and a
/// live ingest rate for every camera, computed from the segment index.
///
/// # Errors
///
/// * `401` — missing / invalid bearer token.
/// * `403` — authenticated but not an admin.
/// * `500` — database error.
async fn cameras_stats(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<CameraStatsResponse>, ApiError> {
    // Admin-only: this is operator capacity-planning data (disk per camera,
    // ingest rate). Mirrors the admin-only storages block in /status, but here
    // we 403 rather than silently empty since the whole payload is admin-scoped.
    if !matches!(user.role, UserRole::Admin) {
        return Err(ApiError::Forbidden(
            "camera statistics are available to administrators only".to_owned(),
        ));
    }

    let rows = db::camera_storage_stats(state.pool()).await?;

    let now = Utc::now();
    let cameras: Vec<CameraStatDto> = rows
        .into_iter()
        .map(|s| {
            let gb_per_hour = gb_per_hour(s.recent_bytes, s.recent_span_secs);
            let retention_hours = retention_hours(s.oldest_ts, s.newest_ts);
            // Resource usage is only meaningful while it's fresh: a stale (or
            // missing) sample means the recorder isn't currently sampling this
            // camera, so report 0/None rather than a frozen reading.
            let fresh = is_fresh(s.resource_updated_at, now);
            let (cpu_pct, mem_mb, gpu_pct) = if fresh {
                (s.cpu_pct, s.mem_mb, s.gpu_pct)
            } else {
                (0.0, 0.0, None)
            };
            CameraStatDto {
                camera_id: s.camera_id,
                name: s.name,
                total_bytes: s.total_bytes,
                segment_count: s.segment_count,
                oldest_ts: s.oldest_ts,
                newest_ts: s.newest_ts,
                gb_per_hour,
                retention_hours,
                cpu_pct,
                mem_mb,
                gpu_pct,
            }
        })
        .collect();

    Ok(Json(CameraStatsResponse {
        cameras,
        generated_at: Utc::now(),
    }))
}

// ─── per-policy usage (Recorder Health "Policy usage") ────────────────────────

/// Per-effective-policy storage usage + forecast in the `/stats/policies` response.
/// "live" is the rolling primary store the size cap binds on; "archive" is the
/// optional long-term copy. Bytes come from the SAME effective-policy rollup the
/// eviction sweep measures, so the numbers are what eviction actually enforces.
#[derive(Debug, Serialize)]
pub struct PolicyStatDto {
    pub policy_id: Uuid,
    /// Policy name, or `null` for an anonymous per-camera fork.
    pub name: Option<String>,
    /// Display label: the name, else `Custom — <owning camera>`.
    pub label: String,
    pub is_default: bool,
    /// `continuous` | `motion`.
    pub mode: String,
    pub camera_count: i64,
    pub camera_names: Vec<String>,
    pub live_used_bytes: i64,
    /// Live size budget (shared across the policy's cameras); `null` = no cap.
    pub live_max_bytes: Option<i64>,
    pub archive_used_bytes: i64,
    pub archive_max_bytes: Option<i64>,
    /// Current LIVE ingest rate (GB/h) summed over the policy's cameras (trailing 24h).
    pub gb_per_hour: f64,
    /// Hours of LIVE footage currently on disk for this policy (`newest-oldest`).
    pub live_retention_hours_now: f64,
    /// The policy's CONFIGURED time-retention (hours) — the time limit eviction also enforces.
    pub live_retention_hours_cap: i32,
    /// At the current rate, hours until LIVE usage reaches `live_max_bytes`
    /// (`null` when no cap or rate is ~0). Clamped at 0 when already over.
    pub live_time_to_full_hours: Option<f64>,
    /// At the current rate, the hours of footage the size cap holds (cap/rate) —
    /// i.e. the size-bound steady-state retention (`null` when no cap or rate ~0).
    pub size_bound_retention_hours: Option<f64>,
    /// Which limit binds first: `size`, `time`, or `none` (not enough recent footage).
    pub binding_limit: String,
}

/// `GET /stats/policies` response.
#[derive(Debug, Serialize)]
pub struct PolicyStatsResponse {
    pub policies: Vec<PolicyStatDto>,
    pub generated_at: DateTime<Utc>,
}

/// `GET /stats/policies` — per-recording-policy storage usage + forecast (admin only).
///
/// Keyed on EFFECTIVE policy (own → group → default) so it covers the anonymous
/// per-camera forks `/config/policies` hides, and so the bytes match the size-cap
/// eviction sweep exactly. Sidesteps the duplicated `storages` rows (#67) by
/// reporting per policy, not per disk.
///
/// # Errors
/// * `401` — missing/invalid token. * `403` — not an admin. * `500` — DB error.
async fn policy_stats(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<PolicyStatsResponse>, ApiError> {
    if !matches!(user.role, UserRole::Admin) {
        return Err(ApiError::Forbidden(
            "policy statistics are available to administrators only".to_owned(),
        ));
    }
    let pool = state.pool();
    let policies = db::list_policies(pool).await?; // includes name=NULL forks — do NOT filter
    let rollup: HashMap<Uuid, db::PolicyUsageRollup> = db::policy_usage_rollup(pool)
        .await?
        .into_iter()
        .map(|r| (r.policy_id, r))
        .collect();

    // camera_id grouping per effective policy → count + names.
    let mut cams_by_policy: HashMap<Uuid, Vec<String>> = HashMap::new();
    for (policy_id, _camera_id, name) in db::cameras_by_effective_policy(pool).await? {
        cams_by_policy.entry(policy_id).or_default().push(name);
    }

    let mut out: Vec<PolicyStatDto> = Vec::new();
    for p in &policies {
        let names = cams_by_policy.get(&p.id).cloned().unwrap_or_default();
        let usage = rollup.get(&p.id);
        let (live_used, archive_used, recent_bytes, recent_span, live_oldest, live_newest) =
            match usage {
                Some(u) => (
                    u.live_used,
                    u.archive_used,
                    u.recent_live_bytes,
                    u.recent_live_span_secs,
                    u.live_oldest_ts,
                    u.live_newest_ts,
                ),
                None => (0, 0, 0, 0.0, None, None),
            };
        // Skip policies that are neither assigned nor holding footage (noise).
        if names.is_empty() && live_used == 0 && archive_used == 0 {
            continue;
        }

        // Phase 3: every policy is named (0068 made recording_policies.name NOT
        // NULL, and no anonymous per-camera forks are minted anymore), so the old
        // "Custom — <camera>" fallback is dead. Keep a neutral guard that cannot
        // appear in practice.
        let label = p.name.clone().unwrap_or_else(|| "Policy".to_owned());
        let gb_h = gb_per_hour(recent_bytes, recent_span);
        let forecast = policy_forecast(live_used, p.live_max_bytes, p.live_retention_hours, gb_h);

        out.push(PolicyStatDto {
            policy_id: p.id,
            name: p.name.clone(),
            label,
            is_default: p.is_default,
            mode: p.mode.as_str().to_owned(),
            camera_count: names.len() as i64,
            camera_names: names,
            live_used_bytes: live_used,
            live_max_bytes: p.live_max_bytes,
            archive_used_bytes: archive_used,
            archive_max_bytes: p.archive_max_bytes,
            gb_per_hour: gb_h,
            live_retention_hours_now: retention_hours(live_oldest, live_newest),
            live_retention_hours_cap: p.live_retention_hours,
            live_time_to_full_hours: forecast.time_to_full_hours,
            size_bound_retention_hours: forecast.size_bound_retention_hours,
            binding_limit: forecast.binding.to_owned(),
        });
    }
    // Default first, then named alphabetically, then forks — already the
    // list_policies order; preserve it.

    Ok(Json(PolicyStatsResponse {
        policies: out,
        generated_at: Utc::now(),
    }))
}

/// Forecast outcome for one policy's LIVE store.
struct Forecast {
    time_to_full_hours: Option<f64>,
    size_bound_retention_hours: Option<f64>,
    binding: &'static str,
}

/// Compute which limit binds (size cap vs time retention) and the size forecast.
///
/// Honest about the binding limit: when the configured time-retention would evict
/// footage before the size cap is reached, `binding = "time"` and we do NOT show a
/// scary countdown (eviction holds the store flat at the time-bound steady state).
#[allow(clippy::cast_precision_loss)]
fn policy_forecast(
    live_used: i64,
    live_max_bytes: Option<i64>,
    live_retention_hours_cap: i32,
    gb_per_hour: f64,
) -> Forecast {
    let rate_bph = gb_per_hour * 1e9; // bytes/hour
    let time_bound_h = f64::from(live_retention_hours_cap);

    // No usable ingest rate → can't project from size at all.
    if rate_bph <= 0.0 {
        return Forecast {
            time_to_full_hours: None,
            size_bound_retention_hours: None,
            binding: "none",
        };
    }
    let Some(cap) = live_max_bytes.filter(|&c| c > 0) else {
        // Rate known but no size cap → only time retention binds.
        return Forecast {
            time_to_full_hours: None,
            size_bound_retention_hours: None,
            binding: "time",
        };
    };
    let cap_f = cap as f64;
    let remaining = (cap_f - live_used as f64).max(0.0);
    let time_to_full = remaining / rate_bph;
    let size_bound_retention = cap_f / rate_bph;
    // Whichever comes first holds the store: if the size cap's steady-state
    // retention is shorter than the configured time retention, size binds.
    let binding = if time_bound_h > 0.0 && size_bound_retention >= time_bound_h {
        "time"
    } else {
        "size"
    };
    Forecast {
        time_to_full_hours: Some(time_to_full),
        size_bound_retention_hours: Some(size_bound_retention),
        binding,
    }
}

// ─── per-policy on-disk verification (Tier B, on-demand) ──────────────────────

/// One policy's DB-tracked vs actual-on-disk byte comparison.
#[derive(Debug, Serialize)]
pub struct PolicyVerifyDto {
    pub policy_id: Uuid,
    pub label: String,
    /// `SUM(size_bytes)` from the segment index (live + archive).
    pub db_bytes: i64,
    /// Sum of actual file sizes under the policy's cameras on disk.
    pub disk_bytes: i64,
    pub delta_bytes: i64,
    /// `delta_bytes` as a percent of `db_bytes` (0 when `db_bytes` is 0).
    pub delta_pct: f64,
}

/// `GET /stats/policies/verify` response.
#[derive(Debug, Serialize)]
pub struct PolicyVerifyResponse {
    pub policies: Vec<PolicyVerifyDto>,
    pub generated_at: DateTime<Utc>,
}

/// `GET /stats/policies/verify` — reconcile DB-tracked bytes against the actual
/// files on disk, per effective policy (admin only).
///
/// On-demand only (a filesystem walk over the read-only media mounts) — never on
/// the cheap refresh path. Walks `{storage.path}/{camera_id}/*` summing real file
/// sizes and rolls them up by the camera's effective policy, then compares to the
/// segment-index sum. A healthy fleet reads ~0 delta (the startup reconciler
/// repairs `size_bytes`); a large delta flags drift or out-of-band file changes.
///
/// # Errors
/// * `401`/`403` as above. * `500` — DB error or filesystem walk failure.
async fn policy_verify(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<PolicyVerifyResponse>, ApiError> {
    if !matches!(user.role, UserRole::Admin) {
        return Err(ApiError::Forbidden(
            "policy verification is available to administrators only".to_owned(),
        ));
    }
    let pool = state.pool();
    let cam_rows = db::cameras_by_effective_policy(pool).await?;
    let storages = db::list_storages(pool).await?;
    let rollup = db::policy_usage_rollup(pool).await?;
    let policies = db::list_policies(pool).await?;

    // Camera→policy map for attribution. (Phase 3 dropped the per-camera "Custom
    // — <name>" label fallback, so the name-collecting map is no longer needed.)
    let mut cam_to_policy: HashMap<Uuid, Uuid> = HashMap::new();
    for (policy_id, camera_id, _name) in &cam_rows {
        cam_to_policy.insert(*camera_id, *policy_id);
    }
    let label_for = |pid: &Uuid| -> String {
        let named = policies
            .iter()
            .find(|p| &p.id == pid)
            .and_then(|p| p.name.clone());
        // Phase 3: policies are always named now; neutral guard that can't appear.
        named.unwrap_or_else(|| "Policy".to_owned())
    };

    // DB bytes per policy (live + archive).
    let mut db_by_policy: HashMap<Uuid, i64> = HashMap::new();
    for r in &rollup {
        db_by_policy.insert(r.policy_id, r.live_used + r.archive_used);
    }

    // Walk the disk off the async runtime (blocking fs syscalls over the mounts).
    let storage_paths: Vec<String> = storages.iter().map(|s| s.path.clone()).collect();
    let cam_map = cam_to_policy.clone();
    let disk_by_policy =
        tokio::task::spawn_blocking(move || walk_disk_by_policy(&storage_paths, &cam_map))
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("disk-walk task join: {e}")))?;

    // Union of all policy ids seen in either source.
    let mut ids: Vec<Uuid> = db_by_policy
        .keys()
        .chain(disk_by_policy.keys())
        .copied()
        .collect();
    ids.sort();
    ids.dedup();

    let mut out: Vec<PolicyVerifyDto> = ids
        .into_iter()
        .map(|pid| {
            let db_bytes = *db_by_policy.get(&pid).unwrap_or(&0);
            let disk_bytes = *disk_by_policy.get(&pid).unwrap_or(&0);
            let delta_bytes = disk_bytes - db_bytes;
            #[allow(clippy::cast_precision_loss)]
            let delta_pct = if db_bytes > 0 {
                delta_bytes as f64 / db_bytes as f64 * 100.0
            } else if disk_bytes > 0 {
                100.0
            } else {
                0.0
            };
            PolicyVerifyDto {
                policy_id: pid,
                label: label_for(&pid),
                db_bytes,
                disk_bytes,
                delta_bytes,
                delta_pct,
            }
        })
        .collect();
    out.sort_by(|a, b| a.label.cmp(&b.label));

    Ok(Json(PolicyVerifyResponse {
        policies: out,
        generated_at: Utc::now(),
    }))
}

/// Sum actual file sizes under `{storage}/{camera_id}/*` and roll up by the
/// camera's effective policy. Layout is flat: each storage root holds one dir per
/// camera UUID, each holding that camera's segment files (recording.rs §2). Skips
/// unreadable dirs / unmapped camera ids rather than failing the whole walk.
fn walk_disk_by_policy(
    storage_paths: &[String],
    cam_to_policy: &HashMap<Uuid, Uuid>,
) -> HashMap<Uuid, i64> {
    let mut out: HashMap<Uuid, i64> = HashMap::new();
    // Walk each PHYSICAL path once. Storage rows can share a path (the duplicate-
    // storage-row situation, #67); canonicalising + de-duping prevents counting
    // the same files twice, which would otherwise inflate disk_bytes and make
    // verify falsely report DB/disk drift on exactly that prod layout.
    let mut visited: std::collections::HashSet<std::path::PathBuf> =
        std::collections::HashSet::new();
    for sp in storage_paths {
        let canon = std::fs::canonicalize(sp).unwrap_or_else(|_| std::path::PathBuf::from(sp));
        if !visited.insert(canon.clone()) {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&canon) else {
            continue;
        };
        for entry in entries.flatten() {
            if !entry.file_type().is_ok_and(|t| t.is_dir()) {
                continue;
            }
            let Some(cid) = entry
                .file_name()
                .to_str()
                .and_then(|s| Uuid::parse_str(s).ok())
            else {
                continue;
            };
            let Some(&pid) = cam_to_policy.get(&cid) else {
                continue; // dir for a deleted camera — not attributable
            };
            let mut sum: i64 = 0;
            if let Ok(files) = std::fs::read_dir(entry.path()) {
                for f in files.flatten() {
                    if let Ok(md) = f.metadata() {
                        if md.is_file() {
                            sum += i64::try_from(md.len()).unwrap_or(i64::MAX);
                        }
                    }
                }
            }
            *out.entry(pid).or_insert(0) += sum;
        }
    }
    out
}

// ─── storage advisor ────────────────────────────────────────────────────────────

/// One camera's contribution to a storage device's daily ingest in the
/// `/stats/storage` response.
#[derive(Debug, Serialize)]
pub struct TopContributorDto {
    /// Camera display name.
    pub camera: String,
    /// Estimated bytes/day written by this camera on this storage (trailing 7d).
    pub bytes_per_day: f64,
    /// Stream recorded — `"main"` or `"sub"`.
    pub stream: String,
    /// Recording mode of the camera's effective policy — `"continuous"` or
    /// `"motion"`.
    pub mode: String,
}

/// One camera's on-disk footprint on a storage device, for the per-camera
/// storage-breakdown table ("what's eating my disk and why").
#[derive(Debug, Serialize)]
pub struct CameraFootprintDto {
    /// Camera display name.
    pub camera: String,
    /// Total bytes this camera occupies on this storage right now (all stages,
    /// all time) — the actual footprint on disk.
    pub bytes: i64,
    /// Recent fill rate in bytes/day (trailing 7 days). `0` when idle.
    pub bytes_per_day: f64,
    /// Dominant stream on this storage — `"main"` or `"sub"`.
    pub stream: String,
    /// Recording mode of the camera's effective policy — `"continuous"` or
    /// `"motion"`.
    pub mode: String,
    /// Observed footage age span in days (`max(end_ts) − min(start_ts)`). `null`
    /// when unknown (no completed segments yet).
    pub days_retained: Option<f64>,
    /// Effective policy id — matches a `usage_by_policy[].policy_id` so the UI
    /// colour-keys this row to the stacked bar above.
    pub policy_id: Uuid,
    /// Properly-resolved policy label (named policy, `"Default"`, or
    /// `"<camera> · custom"` for a per-camera override).
    pub policy_name: String,
}

/// One recording-profile's share of a storage device's used space, for the
/// stacked-by-profile utilization bar.
#[derive(Debug, Serialize)]
pub struct StoragePolicyUsageDto {
    pub policy_id: Uuid,
    /// Human-readable profile name (e.g. `"Default"`, `"Motion"`).
    pub policy_name: String,
    /// DB-tracked bytes this profile's cameras occupy on this storage.
    pub bytes: i64,
}

/// Per-storage device entry in the `/stats/storage` response.
#[derive(Debug, Serialize)]
pub struct StorageAdvisorDto {
    pub id: Uuid,
    pub name: String,
    pub path: String,
    /// Filesystem total bytes (from `statvfs`).
    pub total_bytes: i64,
    /// Filesystem free bytes (from `statvfs`).
    pub free_bytes: i64,
    /// `total_bytes - free_bytes`.
    pub used_bytes: i64,
    /// Average ingest rate in bytes/day over the last 24 hours.
    pub fill_rate_bytes_per_day_24h: f64,
    /// Average ingest rate in bytes/day over the last 7 days.
    pub fill_rate_bytes_per_day_7d: f64,
    /// `capacity / fill_rate_7d` — how many days of footage the storage can
    /// sustainably hold at the current rate. `capacity` is the configured
    /// `total_bytes` cap if set, otherwise the filesystem total.  `null` when
    /// the 7d fill rate is near zero.
    pub effective_retention_days: Option<f64>,
    /// Days until the storage is full at the current fill rate. `null` when the
    /// storage is at steady-state (eviction is keeping pace) or when the fill
    /// rate is near zero.
    pub days_until_full: Option<f64>,
    /// `true` when the storage appears to be at steady-state: it has a policy
    /// with a retention/size cap configured AND the used fraction is close to
    /// the cap (i.e. eviction is running, not unbounded growth).
    pub at_steady_state: bool,
    /// Retention configured on the effective policy(ies) pointing at this
    /// storage, in days.  `null` if no policy points here or no retention is
    /// set.
    pub configured_retention_days: Option<f64>,
    /// Sustainable retention at the current fill rate — equal to
    /// `effective_retention_days`.  Exposed separately so the UI can suggest
    /// adjusting the configured value to match.
    pub suggested_retention_days: Option<f64>,
    /// Top ~5 cameras by bytes/day on this storage over the last 7 days.
    pub top_contributors: Vec<TopContributorDto>,
    /// Per-recording-profile share of this storage's used space (largest first).
    /// The remainder up to `used_bytes` is footage Crumb didn't write ("other").
    pub usage_by_policy: Vec<StoragePolicyUsageDto>,
    /// One row per camera with footage on this storage, sorted by footprint
    /// (bytes on disk) descending — the "what's eating my disk and why" table.
    pub camera_footprints: Vec<CameraFootprintDto>,
    /// Actionable suggestion strings (0–3).
    pub suggestions: Vec<String>,
}

/// `GET /stats/storage` response.
#[derive(Debug, Serialize)]
pub struct StorageAdvisorResponse {
    pub storages: Vec<StorageAdvisorDto>,
    pub generated_at: DateTime<Utc>,
}

/// Minimum fill rate below which we treat ingest as "zero" and suppress
/// projections.  Equivalent to ~1 MiB/day — below this the camera is probably
/// offline or just seeded with test data.
const MIN_FILL_RATE_BYTES_PER_DAY: f64 = 1.0e6;

/// Fraction of capacity at which we consider a storage to be at "steady-state"
/// (eviction is keeping pace rather than the device filling up).  90 % is
/// conservative — the eviction high-water mark is typically 95–97 % on a
/// healthy fleet.
const STEADY_STATE_FILL_FRACTION: f64 = 0.90;

/// `GET /stats/storage` — per-storage fill rate, retention forecast, and
/// top-contributor breakdown (admin only).
///
/// Computes from actual recorded data:
///
/// * Filesystem total / free via `statvfs(2)` (same helper as `/status`).
/// * 24h and 7d fill rates from the `segments` index (two efficient aggregate
///   queries grouped by `storage_id`; no N+1).
/// * Effective and configured retention, steady-state detection, days-to-full.
/// * Per-camera on-disk footprint breakdown (bytes, %, fill rate, age span,
///   properly-labelled policy) and actionable suggestions. The top-5 by
///   bytes/day still feed the suggestion heuristics.
///
/// # Errors
///
/// * `401` — missing / invalid token.
/// * `403` — not an admin.
/// * `500` — database error.
async fn storage_advisor(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<StorageAdvisorResponse>, ApiError> {
    let pool = state.pool();

    // Fetch all data sources concurrently; they are independent reads.
    let (
        storages,
        fill_24h,
        fill_7d,
        contributors,
        policies,
        cam_policy_rows,
        policy_usage,
        cam_footprints,
    ) = tokio::try_join!(
        db::list_storages(pool),
        db::storage_fill_rate_stats(pool, 24),
        db::storage_fill_rate_stats(pool, 168), // 7d = 168 h
        db::storage_top_contributors(pool),
        db::list_policies(pool),
        db::cameras_by_effective_policy(pool),
        db::storage_usage_by_policy(pool),
        db::storage_camera_footprints(pool),
    )
    .map_err(ApiError::Internal)?;

    // Index fill-rate rows by storage_id for O(1) lookup.
    let fill_24h_map: HashMap<Uuid, &db::StorageFillRateStat> =
        fill_24h.iter().map(|r| (r.storage_id, r)).collect();
    let fill_7d_map: HashMap<Uuid, &db::StorageFillRateStat> =
        fill_7d.iter().map(|r| (r.storage_id, r)).collect();

    // Build storage_id → [contributor] mapping.
    let mut contrib_map: HashMap<Uuid, Vec<TopContributorDto>> = HashMap::new();
    for c in contributors {
        contrib_map
            .entry(c.storage_id)
            .or_default()
            .push(TopContributorDto {
                camera: c.camera_name,
                bytes_per_day: c.bytes_per_day,
                stream: c.stream,
                mode: c.mode,
            });
    }

    // First camera that resolves to each policy, for labelling per-camera custom
    // (unnamed, non-default) overrides. Such a policy is referenced by exactly one
    // camera, and cam_policy_rows is already ordered by camera name.
    let mut cam_name_for_policy: HashMap<Uuid, String> = HashMap::new();
    for (pid, _cid, cname) in &cam_policy_rows {
        cam_name_for_policy
            .entry(*pid)
            .or_insert_with(|| cname.clone());
    }

    // Build storage_id → [per-profile usage slice] for the stacked utilization bar.
    // Label resolution: a NAMED policy uses its name; the single real default (name
    // NULL but is_default) is "Default"; an anonymous per-camera fork (name NULL,
    // not default) is a per-camera override → label it by its owning camera
    // ("<camera> · custom"), never the misleading "Default". An orphaned/unknown
    // policy id falls back to a generic label so a slice is never silently dropped.
    let policy_name_for = |pid: &Uuid| -> String {
        match policies.iter().find(|p| &p.id == pid) {
            Some(p) => {
                if let Some(name) = p.name.clone() {
                    name
                } else if p.is_default {
                    "Default".to_owned()
                } else {
                    cam_name_for_policy
                        .get(pid)
                        .map_or_else(|| "Custom".to_owned(), |c| format!("{c} · custom"))
                }
            }
            None => "Custom".to_owned(),
        }
    };
    let mut usage_map: HashMap<Uuid, Vec<StoragePolicyUsageDto>> = HashMap::new();
    for u in &policy_usage {
        usage_map
            .entry(u.storage_id)
            .or_default()
            .push(StoragePolicyUsageDto {
                policy_id: u.policy_id,
                policy_name: policy_name_for(&u.policy_id),
                bytes: u.bytes,
            });
    }
    // Largest profile first so the stacked bar reads big→small left→right.
    for v in usage_map.values_mut() {
        v.sort_by_key(|u| std::cmp::Reverse(u.bytes));
    }

    // Build storage_id → [per-camera footprint row]. The query already orders by
    // bytes desc within each storage, so the default sort is footprint-first. Each
    // row's policy label reuses the Problem-1-fixed policy_name_for so the table
    // and the stacked bar above read as one picture.
    let mut footprint_map: HashMap<Uuid, Vec<CameraFootprintDto>> = HashMap::new();
    for f in &cam_footprints {
        footprint_map
            .entry(f.storage_id)
            .or_default()
            .push(CameraFootprintDto {
                camera: f.camera_name.clone(),
                bytes: f.bytes,
                bytes_per_day: f.bytes_per_day,
                stream: f.stream.clone(),
                mode: f.mode.clone(),
                days_retained: f.span_days,
                policy_id: f.policy_id,
                policy_name: policy_name_for(&f.policy_id),
            });
    }

    // Build storage_id → configured_retention_days.
    // A storage may be the live_storage_id for several policies; we take the
    // shortest configured retention (the binding limit) so the number is
    // conservative and honest.
    //
    // We need: policy.live_storage_id → retention.  But some cameras inherit the
    // default policy (policy_id = NULL on the camera row); we need to resolve the
    // EFFECTIVE policy for each camera to know which storage it's writing to.
    // The effective resolution is done in cam_policy_rows (from
    // cameras_by_effective_policy) + policies list.
    let policy_map: HashMap<Uuid, &crumb_common::types::RecordingPolicy> =
        policies.iter().map(|p| (p.id, p)).collect();

    // storage_id → shortest live_retention_hours across all policies pointing there.
    let mut retention_by_storage: HashMap<Uuid, i32> = HashMap::new();
    // storage_id → whether ANY policy has a size cap on that storage.
    let mut has_size_cap: HashMap<Uuid, bool> = HashMap::new();

    // Use cam_policy_rows to discover which policies are actually effective
    // (some rows in list_policies may be orphaned forks with no cameras).
    let effective_policy_ids: std::collections::HashSet<Uuid> =
        cam_policy_rows.iter().map(|(pid, _, _)| *pid).collect();

    for pid in &effective_policy_ids {
        let Some(p) = policy_map.get(pid) else {
            continue;
        };
        if let Some(storage_id) = p.live_storage_id {
            let ret = retention_by_storage.entry(storage_id).or_insert(i32::MAX);
            *ret = (*ret).min(p.live_retention_hours);
            if p.live_max_bytes.is_some_and(|b| b > 0) {
                *has_size_cap.entry(storage_id).or_insert(false) = true;
            }
        }
    }

    let mut out = Vec::with_capacity(storages.len());
    for storage in &storages {
        let sid = storage.id;

        // ── filesystem metrics ────────────────────────────────────────────────
        let (total_bytes, free_bytes) = storage_statvfs(&storage.path).unwrap_or((0, 0));
        let used_bytes = total_bytes.saturating_sub(free_bytes);

        // ── fill rates ────────────────────────────────────────────────────────
        #[allow(clippy::cast_precision_loss)]
        let rate_24h: f64 = fill_24h_map.get(&sid).map_or(0.0, |r| {
            if r.window_secs > 0.0 {
                r.window_bytes as f64 / (r.window_secs / 86_400.0)
            } else {
                0.0
            }
        });
        #[allow(clippy::cast_precision_loss)]
        let rate_7d: f64 = fill_7d_map.get(&sid).map_or(0.0, |r| {
            if r.window_secs > 0.0 {
                r.window_bytes as f64 / (r.window_secs / 86_400.0)
            } else {
                0.0
            }
        });

        // ── capacity: configured cap OR filesystem total ───────────────────────
        // storage.total_bytes is the admin-configured cap (optional); the
        // filesystem size is the hard physical limit.  Use whichever is smaller
        // (and non-zero) so projections are conservative.
        #[allow(clippy::cast_precision_loss)]
        let capacity: f64 = match storage.total_bytes {
            Some(cap) if cap > 0 => (cap as f64).min(total_bytes as f64),
            _ => total_bytes as f64,
        };

        // ── retention projections ─────────────────────────────────────────────
        let effective_retention_days = if rate_7d >= MIN_FILL_RATE_BYTES_PER_DAY && capacity > 0.0 {
            Some(capacity / rate_7d)
        } else {
            None
        };

        // Steady-state: the storage has a policy cap configured AND is already
        // near full (eviction should be running). Under steady-state the device
        // doesn't actually "fill up" — the count-down would be misleading.
        let cap_configured = has_size_cap.get(&sid).copied().unwrap_or(false)
            || storage.total_bytes.is_some_and(|b| b > 0);
        #[allow(clippy::cast_precision_loss)]
        let fill_fraction = if total_bytes > 0 {
            used_bytes as f64 / total_bytes as f64
        } else {
            0.0
        };
        let at_steady_state = cap_configured && fill_fraction >= STEADY_STATE_FILL_FRACTION;

        let days_until_full = if at_steady_state || rate_7d < MIN_FILL_RATE_BYTES_PER_DAY {
            // Either eviction is keeping pace, or we have no usable rate.
            None
        } else {
            #[allow(clippy::cast_precision_loss)]
            let remaining = (free_bytes as f64).max(0.0);
            Some((remaining / rate_7d).max(0.0))
        };

        // ── configured retention ──────────────────────────────────────────────
        let configured_retention_days = retention_by_storage.get(&sid).and_then(|&h| {
            if h == i32::MAX || h <= 0 {
                None
            } else {
                Some(f64::from(h) / 24.0)
            }
        });

        // ── suggestions ───────────────────────────────────────────────────────
        let contributors = contrib_map.remove(&sid).unwrap_or_default();
        let mut suggestions: Vec<String> = Vec::new();

        // 1. Dominant continuous-main camera eating most of the fill.
        if let Some(top) = contributors.first() {
            let total_rate = rate_7d.max(1.0);
            let top_fraction = top.bytes_per_day / total_rate;
            if top.mode == "continuous" && top.stream == "main" && top_fraction >= 0.40 {
                // Only suggest a motion-mode estimate when we actually have a real
                // retention figure — skip when capacity/rate is unknown (e.g. statvfs
                // failed → effective_retention_days is None), to avoid a "~0d" nonsense.
                if let Some(motion_est_days) = effective_retention_days
                    .filter(|d| *d > 0.0)
                    .map(|d| d / 0.10)
                {
                    let cam = &top.camera;
                    let pct = top_fraction * 100.0;
                    suggestions.push(format!(
                        "{cam} (continuous main) accounts for {pct:.0}% of fill — \
                         motion mode could extend retention to ~{motion_est_days:.0}d"
                    ));
                }
            }
        }

        // 2. Configured retention exceeds what the storage can sustainably hold.
        if let (Some(cfg_d), Some(eff_d)) = (configured_retention_days, effective_retention_days) {
            if cfg_d > eff_d * 1.10 {
                suggestions.push(format!(
                    "Configured retention ({cfg_d:.0}d) exceeds capacity at current fill rate \
                     ({eff_d:.0}d available) — lower retention or add storage"
                ));
            }
        }

        // 3. No retention policy + low days-to-full.
        if configured_retention_days.is_none() && !at_steady_state {
            if let Some(dtf) = days_until_full {
                if dtf < 14.0 {
                    suggestions.push(format!(
                        "No retention policy set — storage will be full in ~{dtf:.0}d at current rate; \
                         set a retention policy to enable automatic eviction"
                    ));
                }
            }
        }

        out.push(StorageAdvisorDto {
            id: sid,
            name: storage.name.clone(),
            path: storage.path.clone(),
            total_bytes,
            free_bytes,
            used_bytes,
            fill_rate_bytes_per_day_24h: rate_24h,
            fill_rate_bytes_per_day_7d: rate_7d,
            effective_retention_days,
            days_until_full,
            at_steady_state,
            configured_retention_days,
            suggested_retention_days: effective_retention_days,
            top_contributors: contributors,
            usage_by_policy: usage_map.remove(&sid).unwrap_or_default(),
            camera_footprints: footprint_map.remove(&sid).unwrap_or_default(),
            suggestions,
        });
    }

    Ok(Json(StorageAdvisorResponse {
        storages: out,
        generated_at: Utc::now(),
    }))
}

/// Query `(total_bytes, free_bytes)` for the filesystem containing `path` via
/// `statvfs(2)`.  Returns `None` when the path is inaccessible or on non-Unix
/// build targets (dev compilation on Windows).
///
/// Mirrors the identical helper in `status.rs` and `config_routes.rs`; kept
/// local so neither module needs to expose a private function.
fn storage_statvfs(path: &str) -> Option<(i64, i64)> {
    #[cfg(unix)]
    {
        use std::ffi::CString;
        let c_path = CString::new(path.as_bytes()).ok()?;
        // SAFETY: `c_path` is a valid NUL-terminated string; `buf` is a
        // zero-initialised local whose address we pass to the well-documented
        // POSIX `statvfs(3)` syscall.
        let mut buf = unsafe { std::mem::zeroed::<libc::statvfs>() };
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &raw mut buf) };
        if rc != 0 {
            return None;
        }
        #[allow(clippy::cast_lossless)]
        let bsize = buf.f_bsize as u64;
        #[allow(clippy::cast_lossless)]
        let total = (buf.f_blocks as u64).saturating_mul(bsize);
        // f_bavail (available to a non-root writer), not f_bfree (includes the
        // ext4 root reserve) — otherwise free space is over-reported (issue #72).
        #[allow(clippy::cast_lossless)]
        let free = (buf.f_bavail as u64).saturating_mul(bsize);
        Some((
            i64::try_from(total).unwrap_or(i64::MAX),
            i64::try_from(free).unwrap_or(i64::MAX),
        ))
    }

    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

// ─── derived metrics ────────────────────────────────────────────────────────────

/// Maximum age (seconds) a resource sample may have before it's treated as stale.
///
/// The recorder samples every ~10 s, so 60 s tolerates several missed ticks while
/// still meaning "the recorder isn't currently running this camera" once exceeded.
const RESOURCE_STALE_SECONDS: i64 = 60;

/// Whether a resource sample written at `updated_at` is fresh enough to report.
///
/// `None` (no sample row yet) is never fresh. A future timestamp (clock skew) is
/// treated as fresh.
fn is_fresh(updated_at: Option<DateTime<Utc>>, now: DateTime<Utc>) -> bool {
    match updated_at {
        Some(ts) => (now - ts).num_seconds() <= RESOURCE_STALE_SECONDS,
        None => false,
    }
}

/// Smallest span (in hours) we'll divide an ingest rate by, to avoid dividing by
/// (near-)zero when only a few seconds of recent footage exist.
const MIN_SPAN_HOURS: f64 = 1.0 / 3600.0;

/// Live ingest rate in gigabytes per hour from a trailing-window byte total and
/// its span in seconds. Returns `0.0` when there is no recent footage.
#[allow(clippy::cast_precision_loss)]
fn gb_per_hour(recent_bytes: i64, recent_span_secs: f64) -> f64 {
    if recent_bytes <= 0 || recent_span_secs <= 0.0 {
        return 0.0;
    }
    let gb = recent_bytes as f64 / 1e9;
    let span_hours = (recent_span_secs / 3600.0).max(MIN_SPAN_HOURS);
    gb / span_hours
}

/// Hours of footage on disk from the oldest start and newest end timestamps.
/// Returns `0.0` when either bound is missing (no segments).
#[allow(clippy::cast_precision_loss)]
fn retention_hours(oldest: Option<DateTime<Utc>>, newest: Option<DateTime<Utc>>) -> f64 {
    match (oldest, newest) {
        (Some(o), Some(n)) if n > o => {
            // num_milliseconds avoids the sub-second truncation of num_hours.
            (n - o).num_milliseconds() as f64 / 3_600_000.0
        }
        _ => 0.0,
    }
}
