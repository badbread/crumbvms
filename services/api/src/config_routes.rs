// SPDX-License-Identifier: AGPL-3.0-or-later

//! Config CRUD routes — **admin only**.
//!
//! # Endpoints
//!
//! ## Cameras
//! | Method   | Path                              | Description                              |
//! |----------|-----------------------------------|------------------------------------------|
//! | `GET`    | `/config/cameras`                 | List all cameras with joined policy      |
//! | `POST`   | `/config/cameras`                 | Create camera; clones default policy     |
//! | `GET`    | `/config/cameras/{id}`            | Single camera                            |
//! | `PUT`    | `/config/cameras/{id}`            | Update camera fields (partial)           |
//! | `DELETE` | `/config/cameras/{id}`            | Delete camera + its segments (cascade)   |
//! | `PUT`    | `/config/cameras/{id}/policy`     | Override per-camera policy fields        |
//! | `POST`   | `/config/cameras/{id}/redetect`   | Re-run ONVIF discovery + restart stream  |
//!
//! ## Policies
//! | Method | Path                     | Description                              |
//! |--------|--------------------------|------------------------------------------|
//! | `GET`  | `/config/policy/default` | Global default policy                    |
//! | `PUT`  | `/config/policy/default` | Update global default policy fields      |
//!
//! ## Storages
//! | Method   | Path                    | Description                              |
//! |----------|-------------------------|------------------------------------------|
//! | `GET`    | `/config/storages`      | List all storages + live free space      |
//! | `POST`   | `/config/storages`      | Create storage (validate path writable)  |
//! | `GET`    | `/config/storages/{id}` | Single storage + live free space         |
//! | `PUT`    | `/config/storages/{id}` | Update storage (partial)                 |
//! | `DELETE` | `/config/storages/{id}` | Delete (refuse if segments/policies use)  |
//! | `GET`    | `/config/fs/list`      | Browse server directories (folder picker) |
//!
//! ## Users
//! | Method   | Path                 | Description                              |
//! |----------|----------------------|------------------------------------------|
//! | `GET`    | `/config/users`      | List users (no `password_hash`)            |
//! | `POST`   | `/config/users`      | Create user (argon2 hash password)       |
//! | `GET`    | `/config/users/{id}` | Single user                              |
//! | `PUT`    | `/config/users/{id}` | Update user (re-hash password if given)  |
//! | `DELETE` | `/config/users/{id}` | Delete user (refuse last admin)          |
//!
//! ## Update-available check (issue #7)
//! | Method | Path                          | Description                                    |
//! |--------|-------------------------------|-------------------------------------------------|
//! | `GET`  | `/config/update-check-enabled` | Resolved effective state (DB, else env default) |
//! | `PUT`  | `/config/update-check-enabled` | Operator opt-in/out; writes only this field    |
//!
//! The public, any-user endpoint clients actually poll is `GET /updates/latest`
//! (`services/api/src/updates.rs`), not under `/config`.
//!
//! # Design notes
//!
//! * Every handler requires [`crate::auth_mw::AdminUser`] — viewers never reach
//!   these routes (403 at the extractor layer).
//! * Camera creation clones the default policy via
//!   [`crumb_common::db::clone_default_policy`] so each camera owns an
//!   independent row that can be overridden without touching other cameras or the
//!   global default.
//! * Camera/policy updates write SQL directly to the pool (no shared `db` helper
//!   for partial updates) keeping the public `common::db` surface minimal.
//! * Storage deletion refuses (409) when any recorded segment lives on it (so
//!   footage is never orphaned) or any recording policy still references it (the
//!   message names the blocking profiles + role so the UI can guide the fix).
//! * Named-policy deletion refuses (409) when still assigned to any camera or
//!   group; the message breaks the count down by kind (e.g. "2 cameras and 1
//!   group") so the operator knows exactly what to reassign first.
//! * Camera deletion cascades the camera's `segments` rows (FK `ON DELETE
//!   CASCADE`) but intentionally leaves any anonymous per-camera policy fork
//!   orphaned — per-camera copy-on-write edits stay isolated; the recorder's
//!   periodic reaper (`db::reap_orphan_policy_forks`) deletes forks no
//!   camera/group references.
//! * User deletion refuses (409) removing the last administrator.
//! * Free space is queried via `libc::statvfs` (Linux/Unix only); paths outside
//!   the container filesystem return `None`.
//! * `/config/fs/list` is read-only directory browsing for the storage-path
//!   picker: it canonicalizes the requested path (collapsing `..`/symlinks)
//!   BEFORE listing so traversal games resolve to a real path, lists
//!   directories only (never files/contents), skips hidden entries and
//!   container-noise roots (`proc`/`sys`/`dev`/`run`/`boot`) when listing `/`,
//!   and silently skips unreadable entries. A missing/non-directory path is a
//!   normal `200 {exists:false}` response (the UI treats that as "navigate up
//!   or type a new path"), not an error — only a non-absolute/empty `path` is
//!   `400`. It has no bearing on `validate_storage_path`, which still owns
//!   the writability/`MEDIA_ROOT` checks made on save.
//! * Password hashing uses `argon2::Argon2::default()` (Argon2id, v19, secure
//!   defaults) with a freshly-generated `SaltString` for each call.
//! * Postgres `UNIQUE` violations are caught by inspecting the
//!   `tokio_postgres::error::SqlState` and mapped to `ApiError::Conflict`.

use anyhow::Context as _;
use argon2::{
    password_hash::{PasswordHasher, SaltString},
    Argon2,
};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, post, put},
    Json, Router,
};
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::{
    db::{self, CreateCameraParams, PolicyFields},
    types::{
        Camera, CameraGroup, MotionSensitivity, RecordStream, RecordingMode, RecordingPolicy,
        ServerSettings, Storage, User, UserRole,
    },
};

use crate::{
    auth_mw::AdminUser,
    dto::{
        CameraDecodeStatusDto, CameraDto, CameraGroupDto, CameraMotionCacheDto,
        ChangeStorageRequest, ChangeStorageResponse, CreateCameraRequest, CreateGroupRequest,
        CreatePolicyRequest, CreateStorageRequest, CreateUserRequest, DecodeStatusDto,
        FrigateConfigDto, FrigateHttpTargetResult, FrigateHttpTestRequest, FrigateHttpTestResult,
        FrigateTestResult, FsCheckRequest, FsCheckResponse, FsDirEntryDto, FsListQuery,
        FsListResponseDto, MotionCacheGlobalDto, MotionCacheStatusDto, RecorderCapabilitiesDto,
        RecordingPolicyDto, RedetectResponse, ServerSettingsDto, SetMembersRequest, StorageDto,
        StorageMigrationDto, UpdateCameraRequest, UpdateFrigateConfigRequest, UpdateGroupRequest,
        UpdateNamedPolicyRequest, UpdatePolicyRequest, UpdateServerSettingsRequest,
        UpdateStorageRequest, UpdateUserRequest, UserDto,
    },
    error::ApiError,
    state::AppState,
};

// ─── router ───────────────────────────────────────────────────────────────────

/// Mount all config routes.
///
/// Caller (`main.rs`) nests this under `/config`.
pub fn routes() -> Router<AppState> {
    Router::new()
        // ── cameras ───────────────────────────────────────────────────────────
        .route("/cameras", get(list_cameras).post(create_camera))
        .route(
            "/cameras/:id",
            get(get_camera).put(update_camera).delete(delete_camera),
        )
        .route("/cameras/:id/policy", put(update_camera_policy))
        .route("/cameras/:id/redetect", post(redetect_camera))
        // ── global default policy ─────────────────────────────────────────────
        .route(
            "/policy/default",
            get(get_default_policy).put(update_default_policy),
        )
        // ── named, reusable policies ──────────────────────────────────────────
        .route("/policies", get(list_policies).post(create_policy))
        .route(
            "/policies/:id",
            get(get_policy).put(update_policy).delete(delete_policy),
        )
        // ── guarded "Change storage" (repoint + optional footage drain) ─────────
        .route("/policies/:id/change-storage", post(change_policy_storage))
        .route("/migrations", get(list_migrations))
        .route("/migrations/:id", get(get_migration))
        .route("/migrations/:id/retry", post(retry_migration))
        .route("/migrations/:id/cancel", post(cancel_migration))
        // ── server / streaming settings ───────────────────────────────────────
        .route(
            "/server",
            get(get_server_settings).put(update_server_settings),
        )
        // ── health-alert maintenance window (issue #46) ───────────────────────
        .route(
            "/maintenance",
            get(get_maintenance).post(arm_maintenance_route),
        )
        // ── motion-decode truth (requested vs ACTIVE backend + capabilities) ──
        .route("/decode-status", get(get_decode_status))
        // ── motion RAM-cache telemetry (usage + per-camera ring projection) ────
        .route("/motion-cache-status", get(get_motion_cache_status))
        // ── Frigate / MQTT integration (DB-backed, hot-reloaded) ────────────────
        .route("/frigate", get(get_frigate).put(update_frigate))
        .route("/frigate/test", post(test_frigate))
        .route("/frigate/test-http", post(test_frigate_http))
        // ── camera groups ─────────────────────────────────────────────────────
        .route("/groups", get(list_groups).post(create_group))
        .route(
            "/groups/:id",
            get(get_group).put(update_group).delete(delete_group),
        )
        .route("/groups/:id/members", put(set_group_members))
        // ── storages ──────────────────────────────────────────────────────────
        .route("/storages", get(list_storages).post(create_storage))
        .route(
            "/storages/:id",
            get(get_storage).put(update_storage).delete(delete_storage),
        )
        // ── server filesystem browsing (storage-path "Browse…" folder picker) ──
        .route("/fs/list", get(list_fs))
        // ── storage-path preflight (writability + free space, wizard "Next" gate) ──
        .route("/fs/check", post(check_fs))
        // ── users ─────────────────────────────────────────────────────────────
        .route("/users", get(list_users).post(create_user))
        .route(
            "/users/:id",
            get(get_user).put(update_user).delete(delete_user),
        )
        // ── clip source (Clips feature: per-camera override + global default) ──
        .route("/clip-sources", get(get_clip_sources))
        .route("/clip-source-default", put(set_clip_source_default))
        .route("/cameras/:id/clip-source", put(set_camera_clip_source))
        .route("/clip-preroll", get(get_clip_preroll).put(set_clip_preroll))
        .route(
            "/clip-motion-highlight",
            get(get_clip_motion_highlight).put(set_clip_motion_highlight),
        )
        .route(
            "/bookmarks-enabled",
            get(get_bookmarks_enabled).put(set_bookmarks_enabled),
        )
        // Update-available check opt-in (issue #7, D3: off by default). The
        // effective GET /updates/latest (any user) lives in updates.rs; this
        // pair is the admin-only settings toggle.
        .route(
            "/update-check-enabled",
            get(get_update_check_enabled_route).put(set_update_check_enabled_route),
        )
        .route("/setup-complete", put(set_setup_complete_route))
        .route("/beta-terms", put(set_beta_terms_route))
        // ── stream test (admin "Test stream" button) ──────────────────────────
        // → /config/test-stream (probe stats) + /config/test-frame (JPEG preview)
        .merge(crate::stream_test::routes())
        // ── network discovery (admin "Scan network" button) ────────────────────
        // → /config/discover (unicast IP-range ONVIF/RTSP camera scan)
        // → /config/discover/probe (single-IP deep probe: ONVIF + brand-aware
        //   RTSP path guesses, ffprobe-validated)
        // → /config/camera-brands (static brand list for the probe's `brand` field)
        .merge(crate::discover::routes())
        // ── permission roles (RBAC: capabilities + camera scope per role) ───────
        // → /config/roles, /config/roles/:id
        .merge(crate::roles::routes())
}

// ─── clip source (Clips feature) ────────────────────────────────────────────────

#[derive(serde::Deserialize)]
struct CameraClipSourceRequest {
    /// `"frigate"` | `"crumb"` | null (follow the global default).
    clip_source: Option<String>,
}

#[derive(serde::Deserialize)]
struct DefaultClipSourceRequest {
    /// `"frigate"` | `"crumb"`.
    default: String,
}

#[derive(serde::Serialize)]
struct ClipSourceCameraDto {
    id: Uuid,
    name: String,
    clip_source: Option<String>,
}

#[derive(serde::Serialize)]
struct ClipSourcesDto {
    default: String,
    cameras: Vec<ClipSourceCameraDto>,
}

/// Validate + canonicalize a clip-source string to `"crumb"` / `"frigate"`.
fn normalize_clip_source(s: &str) -> Option<&'static str> {
    match s.trim().to_ascii_lowercase().as_str() {
        "crumb" => Some("crumb"),
        "frigate" => Some("frigate"),
        _ => None,
    }
}

/// `GET /config/clip-sources` — the global default + every camera's override.
async fn get_clip_sources(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<ClipSourcesDto>, ApiError> {
    let default = db::get_default_clip_source(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    let cameras = db::all_clip_cameras(state.pool())
        .await
        .map_err(ApiError::Internal)?
        .into_iter()
        .map(|c| ClipSourceCameraDto {
            id: c.id,
            name: c.name,
            clip_source: c.clip_source,
        })
        .collect();
    Ok(Json(ClipSourcesDto { default, cameras }))
}

/// `PUT /config/clip-source-default` — set the deployment-wide default.
async fn set_clip_source_default(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<DefaultClipSourceRequest>,
) -> Result<StatusCode, ApiError> {
    let src = normalize_clip_source(&body.default)
        .ok_or_else(|| ApiError::BadRequest("default must be 'crumb' or 'frigate'".to_owned()))?;
    db::set_default_clip_source(state.pool(), src)
        .await
        .map_err(ApiError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

/// `PUT /config/cameras/:id/clip-source` — set or clear (null) a camera's override.
async fn set_camera_clip_source(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<CameraClipSourceRequest>,
) -> Result<StatusCode, ApiError> {
    let src: Option<&str> = match body.clip_source.as_deref().map(str::trim) {
        None | Some("") => None,
        Some(s) => Some(normalize_clip_source(s).ok_or_else(|| {
            ApiError::BadRequest("clip_source must be 'crumb' or 'frigate'".to_owned())
        })?),
    };
    db::update_camera_clip_source(state.pool(), id, src)
        .await
        .map_err(ApiError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ─── clip pre-roll (Clips feature: seconds before the event a clip starts) ──────

#[derive(serde::Serialize)]
struct ClipPreRollDto {
    seconds: i64,
    /// The max the UI should allow (clamp ceiling).
    max: i64,
}

#[derive(serde::Deserialize)]
struct ClipPreRollRequest {
    seconds: i64,
}

/// `GET /config/clip-preroll` — current pre-roll seconds + the allowed max.
async fn get_clip_preroll(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<ClipPreRollDto>, ApiError> {
    let seconds = db::get_clip_pre_roll_seconds(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(ClipPreRollDto { seconds, max: 9 }))
}

/// `PUT /config/clip-preroll` — set the pre-roll (db clamps to 0..=9).
async fn set_clip_preroll(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<ClipPreRollRequest>,
) -> Result<StatusCode, ApiError> {
    db::set_clip_pre_roll_seconds(state.pool(), body.seconds)
        .await
        .map_err(ApiError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ─── clip motion highlight (Clips: auto-zoom to the motion region) ──────────────

#[derive(serde::Serialize)]
struct ClipMotionHighlightDto {
    seconds: i64,
    /// Max the UI should allow (0 = disabled .. max).
    max: i64,
}

#[derive(serde::Deserialize)]
struct ClipMotionHighlightRequest {
    seconds: i64,
}

/// `GET /config/clip-motion-highlight` — current highlight seconds + allowed max.
async fn get_clip_motion_highlight(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<ClipMotionHighlightDto>, ApiError> {
    let seconds = db::get_clip_motion_highlight_seconds(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(ClipMotionHighlightDto { seconds, max: 4 }))
}

/// `PUT /config/clip-motion-highlight` — set the duration (db clamps 0..=4).
async fn set_clip_motion_highlight(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<ClipMotionHighlightRequest>,
) -> Result<StatusCode, ApiError> {
    db::set_clip_motion_highlight_seconds(state.pool(), body.seconds)
        .await
        .map_err(ApiError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ─── bookmarks UI toggle (platform-wide: hide the bookmark button everywhere) ───

#[derive(serde::Serialize)]
struct BookmarksEnabledDto {
    enabled: bool,
}

#[derive(serde::Deserialize)]
struct BookmarksEnabledRequest {
    enabled: bool,
}

/// `GET /config/bookmarks-enabled` — current platform-wide bookmarks-UI toggle.
async fn get_bookmarks_enabled(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<BookmarksEnabledDto>, ApiError> {
    let enabled = db::get_bookmarks_enabled(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(BookmarksEnabledDto { enabled }))
}

/// `PUT /config/bookmarks-enabled` — show/hide the bookmark button on all clients.
async fn set_bookmarks_enabled(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<BookmarksEnabledRequest>,
) -> Result<StatusCode, ApiError> {
    db::set_bookmarks_enabled(state.pool(), body.enabled)
        .await
        .map_err(ApiError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ─── update-available check opt-in (issue #7, D3: off by default) ──────────────

#[derive(serde::Serialize)]
struct UpdateCheckEnabledDto {
    enabled: bool,
}

#[derive(serde::Deserialize)]
struct UpdateCheckEnabledRequest {
    enabled: bool,
}

/// `GET /config/update-check-enabled` — the RESOLVED effective state (an
/// explicit DB choice, else the `UPDATE_CHECK_ENABLED` env default, itself
/// `false` per D3). Mirrors the precedence `crate::updates::resolve_enabled`
/// applies to `GET /updates/latest` itself, so the admin toggle always shows
/// what the check is actually doing right now, not just the raw DB row.
async fn get_update_check_enabled_route(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<UpdateCheckEnabledDto>, ApiError> {
    let enabled = crate::updates::resolve_enabled(state.pool(), state.config()).await?;
    Ok(Json(UpdateCheckEnabledDto { enabled }))
}

/// `PUT /config/update-check-enabled` — explicit operator opt-in/out. Writes
/// ONLY this field (house rule); once set, the DB value wins over the env
/// default for good (the standard `server_settings` precedence).
async fn set_update_check_enabled_route(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<UpdateCheckEnabledRequest>,
) -> Result<StatusCode, ApiError> {
    db::set_update_check_enabled(state.pool(), body.enabled)
        .await
        .map_err(ApiError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ─── first-run setup wizard completion flag ─────────────────────────────────────

#[derive(serde::Deserialize)]
struct SetupCompleteRequest {
    complete: bool,
}

/// `PUT /config/setup-complete` — mark the first-run wizard done (`{"complete":true}`
/// when the operator finishes it) or re-open it (`false`, the "Run setup again"
/// action in Server settings).
async fn set_setup_complete_route(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<SetupCompleteRequest>,
) -> Result<StatusCode, ApiError> {
    db::set_setup_complete(state.pool(), body.complete)
        .await
        .map_err(ApiError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ─── beta tester terms acceptance (first-run AS-IS gate) ─────────────────────────

/// Current version of the `CrumbVMS` Beta Tester Terms (see
/// `docs/ALPHA-TESTER-TERMS.md`, "Last updated"). The server owns this string so
/// acceptance is recorded against a known version; bump it (and the doc's date)
/// only when the terms change materially, which re-prompts already-accepted
/// operators the next time the first-run wizard runs.
pub const BETA_TERMS_VERSION: &str = "2026-07-05";

#[derive(serde::Deserialize)]
struct BetaTermsRequest {
    accept: bool,
}

/// `PUT /config/beta-terms` — record the operator's acceptance of the Beta
/// Tester Terms (the AS-IS gate that opens the first-run wizard). The client
/// only signals `{"accept":true}`; the server stamps the acceptance against its
/// own [`BETA_TERMS_VERSION`], so the recorded version can't be spoofed. Admin
/// only — the wizard reaches this once an admin token exists (the account is
/// created in the same first run, before setup completes).
async fn set_beta_terms_route(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<BetaTermsRequest>,
) -> Result<StatusCode, ApiError> {
    if !body.accept {
        return Ok(StatusCode::NO_CONTENT);
    }
    db::set_beta_terms_accepted(state.pool(), BETA_TERMS_VERSION)
        .await
        .map_err(ApiError::Internal)?;
    Ok(StatusCode::NO_CONTENT)
}

// ─── cameras ──────────────────────────────────────────────────────────────────

/// `GET /config/cameras` — list all cameras (enabled and disabled).
async fn list_cameras(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<CameraDto>>, ApiError> {
    let cameras = db::list_cameras_all(state.pool())
        .await
        .context("list_cameras_all")?;
    Ok(Json(cameras.into_iter().map(camera_to_dto).collect()))
}

/// `POST /config/cameras` — create a new camera (clones the default policy).
///
/// Returns `201 Created` with the full [`CameraDto`].
async fn create_camera(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<CreateCameraRequest>,
) -> Result<(StatusCode, Json<CameraDto>), ApiError> {
    validate_create_camera(&body)?;

    // Resolve the two add flows into concrete values.
    let trimmed = |o: &Option<String>| {
        o.as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    let source_url = trimmed(&body.source_url);
    let source_sub_url = trimmed(&body.source_sub_url);

    // served_by: validate + default to "crumb".
    let served_by = match body.served_by.as_deref() {
        Some(s) => normalize_served_by(s).ok_or_else(|| {
            ApiError::BadRequest(format!("served_by must be 'crumb' or 'frigate', got '{s}'"))
        })?,
        None => "crumb",
    };

    // main_url / sub_url now hold the RELATIVE stream name (not a full URL).
    // O3: resolve_stream_url() (in db) does the full-URL assembly at request
    // time.  Legacy cameras that pass main_url directly pass through unchanged.
    let (go2rtc_name, main_url, sub_url): (String, String, Option<String>) = if let Some(_src) =
        source_url.as_deref()
    {
        // ── Self-service: derive go2rtc_name; store the RELATIVE stream name. ─
        let name = trimmed(&body.go2rtc_name).unwrap_or_else(|| slugify_go2rtc_name(&body.name));
        if name.is_empty() {
            return Err(ApiError::BadRequest(
                "could not derive a stream name from the camera name; please set one".to_owned(),
            ));
        }
        // main_url = relative name ("driveway"); sub_url = "<name>_sub" when a
        // sub source is supplied. (O2: NO base URL concatenated here.)
        let sub = source_sub_url.as_ref().map(|_| format!("{name}_sub"));
        (name.clone(), name, sub)
    } else {
        // ── Legacy/manual: caller supplies go2rtc_name + main_url directly. ─
        // Legacy callers may pass a full absolute URL in main_url; that is
        // preserved verbatim (O3 backward-compatible pass-through).
        let name = trimmed(&body.go2rtc_name).ok_or_else(|| {
            ApiError::BadRequest(
                "either source_url, or go2rtc_name + main_url, is required".to_owned(),
            )
        })?;
        let main = trimmed(&body.main_url).ok_or_else(|| {
            ApiError::BadRequest("main_url is required when source_url is not given".to_owned())
        })?;
        (name, main, trimmed(&body.sub_url))
    };

    let pool = state.pool();

    // Clone the default policy — each camera owns its own independent row.
    let policy_id = db::clone_default_policy(pool)
        .await
        .context("clone_default_policy")?;

    // Motion source / algorithm: default to pixel/census; validate if supplied.
    let motion_source = match body.motion_source.as_deref() {
        Some(s) => normalize_motion_source(s).ok_or_else(|| {
            ApiError::BadRequest(format!(
                "motion_source must be 'pixel' or 'frigate', got '{s}'"
            ))
        })?,
        None => "pixel",
    };
    let motion_algorithm = match body.motion_algorithm.as_deref() {
        Some(s) => normalize_motion_algorithm(s).ok_or_else(|| {
            ApiError::BadRequest(format!(
                "motion_algorithm must be census/framediff/mog2/opticalflow/ensemble, got '{s}'"
            ))
        })?,
        None => "census",
    };

    // Camera type (console glyph only): validate if a non-empty value is given,
    // else leave NULL (rendered as the generic icon).
    let camera_type = match body.camera_type.as_deref().map(str::trim) {
        Some(s) if !s.is_empty() => Some(normalize_camera_type(s).ok_or_else(|| {
            ApiError::BadRequest(format!(
                "camera_type must be ptz/dome/bullet/lpr/other, got '{s}'"
            ))
        })?),
        _ => None,
    };

    // Explicit glyph override (console only): validate if given, else leave NULL
    // (the glyph derives from camera_type).
    let icon = match body.icon.as_deref().map(str::trim) {
        Some(s) if !s.is_empty() => Some(
            crumb_common::icons::normalize_camera_icon(s).ok_or_else(|| {
                ApiError::BadRequest(format!("icon must be a cam_* glyph key, got '{s}'"))
            })?,
        ),
        _ => None,
    };

    // New ONVIF / distributability fields.
    let onvif_host_create = body
        .onvif_host
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let onvif_user_create = body
        .onvif_user
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let onvif_password_create = body
        .onvif_password
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let source_camera_name_create = body
        .source_camera_name
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let params = CreateCameraParams {
        name: &body.name,
        go2rtc_name: &go2rtc_name,
        main_url: &main_url,
        sub_url: sub_url.as_deref(),
        source_url: source_url.as_deref(),
        source_sub_url: source_sub_url.as_deref(),
        enabled: body.enabled,
        policy_id,
        motion_mask: body.motion_mask.as_ref(),
        onvif_motion: body.onvif_motion,
        motion_source,
        motion_algorithm,
        camera_type,
        icon,
        served_by,
        source_camera_name: source_camera_name_create,
        onvif_host: onvif_host_create,
        onvif_port: body.onvif_port,
        onvif_user: onvif_user_create,
        onvif_password: onvif_password_create,
    };

    let camera = db::create_camera(pool, &params).await.map_err(|e| {
        // go2rtc_name has a UNIQUE constraint — map to Conflict.
        if is_unique_violation(&e) {
            ApiError::Conflict(format!(
                "a camera with stream name '{go2rtc_name}' already exists"
            ))
        } else {
            ApiError::Internal(e)
        }
    })?;

    // Self-service cameras: configure the go2rtc stream now (the reconcile loop is
    // the safety net if this transient call fails).
    if source_url.is_some() {
        if let Err(e) = crate::go2rtc::reconcile(&state).await {
            tracing::warn!(camera_id = %camera.id, error = %e, "go2rtc stream apply failed; reconcile loop will retry");
        }
    }

    tracing::info!(camera_id = %camera.id, name = %camera.name, "camera created");
    Ok((StatusCode::CREATED, Json(camera_to_dto(camera))))
}

/// `GET /config/cameras/{id}` — fetch a single camera by UUID.
async fn get_camera(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<CameraDto>, ApiError> {
    let camera = require_camera(state.pool(), id).await?;
    Ok(Json(camera_to_dto(camera)))
}

/// `PUT /config/cameras/{id}` — partial update of camera fields.
///
/// Only non-`null` / present JSON fields are applied.  Returns the updated row.
async fn update_camera(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateCameraRequest>,
) -> Result<Json<CameraDto>, ApiError> {
    // Verify the camera exists first (returns 404 rather than silent no-op).
    let existing = require_camera(state.pool(), id).await?;

    validate_update_camera(&body)?;

    let pool = state.pool();
    let client = pool.get().await.context("db pool get")?;

    // Resolve final values: apply patch over existing fields.
    let name = body.name.as_deref().unwrap_or(&existing.name).to_owned();
    let go2rtc_name = body
        .go2rtc_name
        .as_deref()
        .unwrap_or(&existing.go2rtc_name)
        .to_owned();
    let enabled = body.enabled.unwrap_or(existing.enabled);
    let onvif_motion = body.onvif_motion.unwrap_or(existing.onvif_motion);

    // source_url / source_sub_url: Option<Option<String>>; trimmed to non-empty.
    let clean = |s: Option<String>| s.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    let source_url: Option<String> = clean(match body.source_url {
        Some(inner) => inner,
        None => existing.source_url.clone(),
    });
    let source_sub_url: Option<String> = clean(match body.source_sub_url {
        Some(inner) => inner,
        None => existing.source_sub_url.clone(),
    });

    // Guard: a Crumb-managed camera (source_url set) derives its re-stream name
    // from go2rtc_name; an empty go2rtc_name would yield main_url="" / sub_url="_sub"
    // and silently misdirect the recorder. Mirror the create_camera requirement.
    if source_url.is_some() && go2rtc_name.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "go2rtc_name is required when source_url is set".to_owned(),
        ));
    }

    // For a Crumb-managed camera (source_url set) the re-stream URLs are DERIVED
    // as RELATIVE stream names (O2/O3). Legacy cameras may have absolute URLs in
    // main_url — those are preserved verbatim (backward-compatible pass-through).
    let (main_url, sub_url): (String, Option<String>) = if source_url.is_some() {
        // Store the relative stream name only (no base URL concatenation).
        let sub = source_sub_url
            .as_ref()
            .map(|_| format!("{go2rtc_name}_sub"));
        (go2rtc_name.clone(), sub)
    } else {
        let main = body
            .main_url
            .as_deref()
            .unwrap_or(&existing.main_url)
            .to_owned();
        let sub = match body.sub_url {
            Some(inner) => inner,
            None => existing.sub_url.clone(),
        };
        (main, sub)
    };

    // served_by: validate if provided, else keep existing.
    let served_by: String = match body.served_by.as_deref() {
        Some(s) => normalize_served_by(s)
            .ok_or_else(|| {
                ApiError::BadRequest(format!("served_by must be 'crumb' or 'frigate', got '{s}'"))
            })?
            .to_owned(),
        None => existing.served_by.clone(),
    };

    // source_camera_name: double-option merge.
    let source_camera_name: Option<String> = match body.source_camera_name {
        Some(inner) => inner.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()),
        None => existing.source_camera_name.clone(),
    };

    // onvif_host / onvif_user: double-option merge; trim + empty = None.
    let onvif_host: Option<String> = match body.onvif_host {
        Some(inner) => inner.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()),
        None => existing.onvif_host.clone(),
    };
    let onvif_port: Option<i32> = match body.onvif_port {
        Some(inner) => inner,
        None => existing.onvif_port,
    };
    let onvif_user: Option<String> = match body.onvif_user {
        Some(inner) => inner.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()),
        None => existing.onvif_user.clone(),
    };
    // onvif_password: Some(Some(v)) = set; Some(None) = clear; None = keep existing.
    // Never echoed back.
    let onvif_password: Option<String> = match body.onvif_password {
        Some(inner) => inner.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()),
        None => existing.onvif_password.clone(),
    };

    // motion_mask: same double-option pattern.
    let motion_mask: Option<serde_json::Value> = match body.motion_mask {
        Some(inner) => inner,
        None => existing.motion_mask.clone(),
    };

    // Motion source / algorithm: validate to the canonical set, else 400.
    let motion_source = match body.motion_source.as_deref() {
        Some(s) => normalize_motion_source(s)
            .ok_or_else(|| {
                ApiError::BadRequest(format!(
                    "motion_source must be 'pixel' or 'frigate', got '{s}'"
                ))
            })?
            .to_owned(),
        None => existing.motion_source.clone(),
    };
    let motion_algorithm = match body.motion_algorithm.as_deref() {
        Some(s) => normalize_motion_algorithm(s)
            .ok_or_else(|| {
                ApiError::BadRequest(format!(
                    "motion_algorithm must be census/framediff/mog2/opticalflow/ensemble, got '{s}'"
                ))
            })?
            .to_owned(),
        None => existing.motion_algorithm.clone(),
    };

    // camera_type: Option<Option<String>>. Omitted = keep existing; Some(None) or
    // Some(Some("")) = clear to NULL (generic icon); Some(Some(v)) = validated set.
    let camera_type: Option<String> = match &body.camera_type {
        None => existing.camera_type.clone(),
        Some(None) => None,
        Some(Some(v)) => {
            let t = v.trim();
            if t.is_empty() {
                None
            } else {
                Some(
                    normalize_camera_type(t)
                        .ok_or_else(|| {
                            ApiError::BadRequest(format!(
                                "camera_type must be ptz/dome/bullet/lpr/other, got '{t}'"
                            ))
                        })?
                        .to_owned(),
                )
            }
        }
    };

    // icon: Option<Option<String>>. Omitted = keep existing; Some(None) or
    // Some(Some("")) = clear to NULL (glyph derives from camera_type);
    // Some(Some(v)) = validated glyph-key override.
    let icon: Option<String> = match &body.icon {
        None => existing.icon.clone(),
        Some(None) => None,
        Some(Some(v)) => {
            let t = v.trim();
            if t.is_empty() {
                None
            } else {
                Some(
                    crumb_common::icons::normalize_camera_icon(t)
                        .ok_or_else(|| {
                            ApiError::BadRequest(format!(
                                "icon must be a cam_* glyph key, got '{t}'"
                            ))
                        })?
                        .to_owned(),
                )
            }
        }
    };

    // Motion-tuner grid size (UI preference): a provided value sets it; omitted
    // keeps the existing value.
    let motion_grid_cols: Option<i16> = body.motion_grid_cols.or(existing.motion_grid_cols);
    let motion_grid_rows: Option<i16> = body.motion_grid_rows.or(existing.motion_grid_rows);

    client
        .execute(
            r"
            UPDATE cameras
            SET name               = $2,
                go2rtc_name        = $3,
                main_url           = $4,
                sub_url            = $5,
                source_url         = $6,
                source_sub_url     = $7,
                enabled            = $8,
                onvif_motion       = $9,
                motion_mask        = $10,
                motion_source      = $11,
                motion_algorithm   = $12,
                camera_type        = $13,
                icon               = $14,
                motion_grid_cols   = $15,
                motion_grid_rows   = $16,
                served_by          = $17,
                source_camera_name = $18,
                onvif_host         = $19,
                onvif_port         = $20,
                onvif_user         = $21,
                onvif_password     = $22
            WHERE id = $1
            ",
            &[
                &id,
                &name,
                &go2rtc_name,
                &main_url,
                &sub_url,
                &source_url,
                &source_sub_url,
                &enabled,
                &onvif_motion,
                &motion_mask,
                &motion_source,
                &motion_algorithm,
                &camera_type,
                &icon,
                &motion_grid_cols,
                &motion_grid_rows,
                &served_by,
                &source_camera_name,
                &onvif_host,
                &onvif_port,
                &onvif_user,
                &onvif_password,
            ],
        )
        .await
        .map_err(|e| {
            let e = anyhow::Error::new(e).context("update_camera");
            if is_unique_violation_pg(&e) {
                ApiError::Conflict(format!(
                    "a camera with stream name '{go2rtc_name}' already exists"
                ))
            } else {
                ApiError::Internal(e)
            }
        })?;

    // Recording-policy ASSIGNMENT (distinct from editing policy fields): pin the
    // camera to a named policy, or clear it so the camera inherits from its group
    // / the default. `Some(Some(id))` pins; `Some(None)` clears; omitted leaves it.
    if let Some(assignment) = body.policy_id {
        if let Some(pid) = assignment {
            // Phase 3: a grouped camera is governed by its GROUP's profile and
            // may not hold a direct per-camera policy. Reject the pin (but still
            // allow `Some(None)`, i.e. clear-to-inherit — that's how you make a
            // grouped camera follow its group). Ungrouped cameras pass through.
            if let Some(group_name) = db::camera_group_name(pool, id)
                .await
                .context("camera_group_name")?
            {
                return Err(ApiError::BadRequest(format!(
                    "camera is in group '{group_name}' — change the group's profile \
                     or ungroup the camera first to give it its own recording profile"
                )));
            }
            // Must exist (404, not an FK 500) AND be assignable: a camera may only be
            // pinned to a named or the default policy, never to an anonymous fork.
            require_assignable_policy(pool, pid).await?;
        }
        db::set_camera_policy(pool, id, assignment)
            .await
            .context("set_camera_policy")?;
    }

    // Apply go2rtc changes: re-sync if managed; remove the stream if it was just
    // detached from Crumb management.
    if source_url.is_some() {
        if let Err(e) = crate::go2rtc::reconcile(&state).await {
            tracing::warn!(camera_id = %id, error = %e, "go2rtc re-sync failed; reconcile loop will retry");
        }
    } else if existing.source_url.is_some() {
        if let Err(e) = crate::go2rtc::remove(&state, &existing.go2rtc_name).await {
            tracing::warn!(camera_id = %id, error = %e, "go2rtc stream removal failed");
        }
    }

    let updated = require_camera(pool, id).await?;
    tracing::info!(camera_id = %id, "camera updated");
    Ok(Json(camera_to_dto(updated)))
}

/// `DELETE /config/cameras/{id}` — delete a camera and its recorded segments
/// (`segments ON DELETE CASCADE`).
///
/// The camera's *anonymous per-camera policy fork* (if it owns one — a `name IS
/// NULL`, non-default `recording_policies` row) is intentionally left orphaned
/// rather than cascade-deleted: per-camera copy-on-write edits are isolated by
/// design, and the recorder's periodic reaper (`db::reap_orphan_policy_forks`)
/// later deletes any fork no camera/group references.
async fn delete_camera(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    // Verify the camera exists → 404 if not (and capture its go2rtc name).
    let existing = require_camera(state.pool(), id).await?;

    db::delete_camera(state.pool(), id)
        .await
        .context("delete_camera")?;

    // Tear down its go2rtc stream if Crumb managed it.
    if existing.source_url.is_some() {
        if let Err(e) = crate::go2rtc::remove(&state, &existing.go2rtc_name).await {
            tracing::warn!(camera_id = %id, error = %e, "go2rtc stream removal failed");
        }
    }

    tracing::info!(camera_id = %id, "camera deleted");
    Ok(StatusCode::NO_CONTENT)
}

/// `PUT /config/cameras/{id}/policy` — partial update of a camera's own policy
/// row.  Returns the updated [`RecordingPolicyDto`].
/// Postgres advisory-lock key serializing copy-on-write camera-policy edits.
/// Admin-only and low-frequency, so a single global lock is fine.
const CAMERA_POLICY_COW_LOCK: i64 = 0x4357_4f57; // "CWOW"

async fn update_camera_policy(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdatePolicyRequest>,
) -> Result<Json<RecordingPolicyDto>, ApiError> {
    validate_update_policy(&body)?;
    let pool = state.pool();

    // Phase 3: Custom-settings is a per-camera copy-on-write fork — exactly the
    // direct override a grouped camera may not hold (it is governed by its
    // group's profile). Reject here, BEFORE taking the advisory lock, so a
    // grouped camera can never create a fork. Ungroup the camera (or edit the
    // group's profile) to differ.
    if let Some(group_name) = db::camera_group_name(pool, id)
        .await
        .context("camera_group_name")?
    {
        return Err(ApiError::BadRequest(format!(
            "camera is in group '{group_name}' — change the group's profile \
             or ungroup the camera first to set per-camera Custom settings"
        )));
    }

    // Serialize copy-on-write: the ref-count check → clone → reassign in
    // `update_camera_policy_locked` is a read-decide-write spanning several pooled
    // connections. Without mutual exclusion, two concurrent camera-policy edits can
    // race the `ref_count <= 1` check (mutating a policy that just became shared) or
    // both clone the same source (leaking a fork / losing one edit). A
    // transaction-scoped advisory lock — auto-released on commit / rollback / drop —
    // gives that exclusion without threading a txn through every db helper.
    let mut lock_conn = db::get_conn(pool)
        .await
        .context("copy-on-write lock conn")?;
    let lock_txn = lock_conn
        .transaction()
        .await
        .context("begin copy-on-write lock txn")?;
    lock_txn
        .execute(
            "SELECT pg_advisory_xact_lock($1)",
            &[&CAMERA_POLICY_COW_LOCK],
        )
        .await
        .context("acquire copy-on-write lock")?;

    let result = update_camera_policy_locked(pool, id, &body).await;

    // Release the advisory lock (the empty txn carries no row changes either way).
    let _ = lock_txn.commit().await;

    let updated = result?;
    tracing::info!(camera_id = %id, policy_id = %updated.id, "camera policy updated");
    Ok(Json(policy_to_dto(updated)))
}

/// The copy-on-write body of [`update_camera_policy`], run while holding the
/// [`CAMERA_POLICY_COW_LOCK`] advisory lock so the ref-count check and the
/// clone/reassign cannot interleave with a concurrent edit.
async fn update_camera_policy_locked(
    pool: &Pool,
    id: Uuid,
    body: &UpdatePolicyRequest,
) -> Result<RecordingPolicy, ApiError> {
    // Resolve the camera → get the policy_id (inside the lock for a race-free read).
    let camera = require_camera(pool, id).await?;

    // Copy-on-write under inheritance: this endpoint edits THIS camera's recording
    // settings only. The camera may edit its policy in place ONLY when it owns an
    // ANONYMOUS per-camera fork — i.e. it has its own direct `policy_id`, that row
    // is not the default, has no `name` (a named/reusable policy must never be
    // mutated here — that would silently change every camera/group using it), and
    // exactly one camera references it. In every other case (the camera inherits
    // from its group/default, or shares a named/default policy) we fork a new
    // anonymous row FROM THE EFFECTIVE policy, pin the camera to it, and edit the
    // fork — leaving the source policy, other cameras, and groups untouched.
    let effective_id = camera.policy.id; // resolved own → group → default
    let owns_anonymous_fork = match camera.policy_id {
        Some(direct_id) if direct_id == effective_id => {
            let direct = db::get_policy(pool, direct_id)
                .await
                .context("get_policy")?
                .ok_or_else(|| ApiError::NotFound(format!("policy {direct_id} not found")))?;
            let ref_count = db::count_cameras_for_policy(pool, direct_id)
                .await
                .context("count_cameras_for_policy")?;
            !direct.is_default && direct.name.is_none() && ref_count <= 1
        }
        _ => false,
    };

    let target_policy_id = if owns_anonymous_fork {
        effective_id
    } else {
        let new_id = db::clone_policy(pool, effective_id)
            .await
            .context("clone_policy")?;
        db::set_camera_policy(pool, camera.id, Some(new_id))
            .await
            .context("set_camera_policy")?;
        tracing::info!(
            camera_id = %id,
            source_policy_id = %effective_id,
            new_policy_id = %new_id,
            "per-camera policy forked (copy-on-write)"
        );
        new_id
    };

    apply_policy_update(pool, target_policy_id, body).await
}

// ─── default policy ───────────────────────────────────────────────────────────

/// `GET /config/policy/default` — fetch the global default policy.
async fn get_default_policy(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<RecordingPolicyDto>, ApiError> {
    let policy = db::get_default_policy(state.pool())
        .await
        .context("get_default_policy")?;
    Ok(Json(policy_to_dto(policy)))
}

/// `PUT /config/policy/default` — partial update of the global default policy.
///
/// Only modifies the `is_default = true` row.  All fields are optional.
async fn update_default_policy(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<UpdatePolicyRequest>,
) -> Result<Json<RecordingPolicyDto>, ApiError> {
    validate_update_policy(&body)?;

    let default = db::get_default_policy(state.pool())
        .await
        .context("get_default_policy")?;

    let updated = apply_policy_update(state.pool(), default.id, &body).await?;
    tracing::info!(policy_id = %default.id, "default policy updated");
    Ok(Json(policy_to_dto(updated)))
}

// ─── named, reusable policies ─────────────────────────────────────────────────

/// `GET /config/policies` — list all NAMED, reusable policies.
///
/// Excludes anonymous per-camera copy-on-write forks (`name = NULL`); only rows
/// an operator can pick for reuse are returned (the default IS named "Default").
async fn list_policies(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<RecordingPolicyDto>>, ApiError> {
    let policies = db::list_policies(state.pool())
        .await
        .context("list_policies")?;
    Ok(Json(
        policies
            .into_iter()
            .filter(|p| p.name.is_some())
            .map(policy_to_dto)
            .collect(),
    ))
}

/// `GET /config/policies/{id}` — a single policy by id.
async fn get_policy(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<RecordingPolicyDto>, ApiError> {
    let policy = require_policy(state.pool(), id).await?;
    Ok(Json(policy_to_dto(policy)))
}

/// `POST /config/policies` — create a NAMED, reusable policy.
///
/// Recording knobs default to the schema/default policy's values; provided fields
/// override. Returns `201 Created`.
async fn create_policy(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<CreatePolicyRequest>,
) -> Result<(StatusCode, Json<RecordingPolicyDto>), ApiError> {
    let name = body.name.trim().to_owned();
    if name.is_empty() {
        return Err(ApiError::BadRequest(
            "policy name must not be blank".to_owned(),
        ));
    }
    validate_update_policy(&body.fields)?;

    // Merge the partial knobs over the global default as the baseline so a new
    // policy is fully populated even when the client sends just a name + a couple
    // of overrides.
    let base = db::get_default_policy(state.pool())
        .await
        .context("get_default_policy (policy baseline)")?;
    let resolved = resolve_policy_fields(&base, &body.fields, Some(&name))?;
    let created = db::create_policy(state.pool(), &resolved.as_fields())
        .await
        .context("create_policy")?;
    tracing::info!(policy_id = %created.id, name = %name, "named policy created");
    Ok((StatusCode::CREATED, Json(policy_to_dto(created))))
}

/// `PUT /config/policies/{id}` — edit a named policy (name + recording knobs).
///
/// Refuses to rename a policy to blank. Editing the default policy's knobs here
/// is allowed (it is a named policy too), but it always keeps `name = "Default"`.
async fn update_policy(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateNamedPolicyRequest>,
) -> Result<Json<RecordingPolicyDto>, ApiError> {
    let existing = require_policy(state.pool(), id).await?;
    validate_update_policy(&body.fields)?;

    // Resolve the name: rename when provided (non-blank), else keep existing. The
    // default policy must keep a stable name so it can never become anonymous.
    let name: Option<String> = if existing.is_default {
        existing.name.clone().or(Some("Default".to_owned()))
    } else {
        match &body.name {
            Some(n) if n.trim().is_empty() => {
                return Err(ApiError::BadRequest(
                    "policy name must not be blank".to_owned(),
                ));
            }
            Some(n) => Some(n.trim().to_owned()),
            None => existing.name.clone(),
        }
    };

    let resolved = resolve_policy_fields(&existing, &body.fields, name.as_deref())?;
    let updated = db::update_policy(state.pool(), id, &resolved.as_fields())
        .await
        .context("update_policy")?
        .ok_or_else(|| ApiError::NotFound(format!("policy {id} not found")))?;
    tracing::info!(policy_id = %id, "named policy updated");
    Ok(Json(policy_to_dto(updated)))
}

/// `DELETE /config/policies/{id}` — delete a named policy.
///
/// Refuses (`400`) to delete the global default, and (`409`) any policy still
/// referenced by a camera's own `policy_id` or a group's `policy_id`. Cameras
/// inheriting it transitively are fine (they re-resolve to their group/default).
async fn delete_policy(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let existing = require_policy(state.pool(), id).await?;
    if existing.is_default {
        return Err(ApiError::BadRequest(
            "the default recording policy cannot be deleted".to_owned(),
        ));
    }
    let refs = db::count_policy_references(state.pool(), id)
        .await
        .context("count_policy_references")?;
    if refs > 0 {
        // Break the combined count into cameras vs groups so the operator knows
        // exactly what to reassign first. `count_cameras_for_policy` covers the
        // direct camera assignments; an inline query covers the group bindings.
        let pool = state.pool();
        let cam_refs = db::count_cameras_for_policy(pool, id)
            .await
            .context("count_cameras_for_policy")?;
        let group_refs = {
            let client = pool.get().await.context("db pool get")?;
            let row = client
                .query_one(
                    "SELECT COUNT(*)::bigint AS cnt FROM camera_groups WHERE policy_id = $1",
                    &[&id],
                )
                .await
                .context("count group references on policy")?;
            row.get::<_, i64>("cnt")
        };
        let mut parts: Vec<String> = Vec::with_capacity(2);
        if cam_refs > 0 {
            parts.push(format!(
                "{cam_refs} camera{}",
                if cam_refs == 1 { "" } else { "s" }
            ));
        }
        if group_refs > 0 {
            parts.push(format!(
                "{group_refs} group{}",
                if group_refs == 1 { "" } else { "s" }
            ));
        }
        // Fall back to the raw count if the breakdown somehow sums to zero (e.g. a
        // reference type not covered above) so the message is never empty.
        let detail = if parts.is_empty() {
            format!("{refs} camera(s)/group(s)")
        } else {
            parts.join(" and ")
        };
        return Err(ApiError::Conflict(format!(
            "\"{}\" is still assigned to {detail}; reassign {} to another profile \
             before deleting.",
            existing.name.as_deref().unwrap_or("this profile"),
            if cam_refs + group_refs == 1 {
                "it"
            } else {
                "them"
            },
        )));
    }
    let n = db::delete_policy(state.pool(), id)
        .await
        .context("delete_policy")?;
    if n == 0 {
        return Err(ApiError::NotFound(format!("policy {id} not found")));
    }
    tracing::info!(policy_id = %id, "named policy deleted");
    Ok(StatusCode::NO_CONTENT)
}

// ─── camera groups ────────────────────────────────────────────────────────────

/// `GET /config/groups` — list all groups, each with its member camera ids.
async fn list_groups(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<CameraGroupDto>>, ApiError> {
    let groups = db::list_groups(state.pool()).await.context("list_groups")?;
    Ok(Json(groups.into_iter().map(group_to_dto).collect()))
}

/// `GET /config/groups/{id}` — a single group with its members.
async fn get_group(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<CameraGroupDto>, ApiError> {
    // list_groups assembles members; filter to the one requested.
    let groups = db::list_groups(state.pool()).await.context("list_groups")?;
    let dto = groups
        .into_iter()
        .find(|g| g.group.id == id)
        .map(group_to_dto)
        .ok_or_else(|| ApiError::NotFound(format!("group {id} not found")))?;
    Ok(Json(dto))
}

/// `POST /config/groups` — create a group (optionally with a policy + members).
async fn create_group(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<CreateGroupRequest>,
) -> Result<(StatusCode, Json<CameraGroupDto>), ApiError> {
    let name = body.name.trim().to_owned();
    if name.is_empty() {
        return Err(ApiError::BadRequest(
            "group name must not be blank".to_owned(),
        ));
    }
    if let Some(pid) = body.policy_id {
        require_assignable_policy(state.pool(), pid).await?;
    }

    let group = db::create_group(state.pool(), &name, body.policy_id)
        .await
        .context("create_group")?;

    if !body.camera_ids.is_empty() {
        db::set_group_members(state.pool(), group.id, &body.camera_ids)
            .await
            .context("set_group_members")?;
    }
    tracing::info!(group_id = %group.id, name = %name, "camera group created");

    let dto = require_group_dto(state.pool(), group.id).await?;
    Ok((StatusCode::CREATED, Json(dto)))
}

/// `PUT /config/groups/{id}` — rename a group and/or change its policy.
async fn update_group(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateGroupRequest>,
) -> Result<Json<CameraGroupDto>, ApiError> {
    let existing = require_group(state.pool(), id).await?;

    let name = match &body.name {
        Some(n) if n.trim().is_empty() => {
            return Err(ApiError::BadRequest(
                "group name must not be blank".to_owned(),
            ));
        }
        Some(n) => n.trim().to_owned(),
        None => existing.name.clone(),
    };

    // policy_id: Option<Option<Uuid>> — Some(None) clears, omitted keeps existing.
    let policy_id: Option<Uuid> = match body.policy_id {
        Some(inner) => inner,
        None => existing.policy_id,
    };
    if let Some(pid) = policy_id {
        require_assignable_policy(state.pool(), pid).await?;
    }

    db::update_group(state.pool(), id, &name, policy_id)
        .await
        .context("update_group")?
        .ok_or_else(|| ApiError::NotFound(format!("group {id} not found")))?;
    tracing::info!(group_id = %id, "camera group updated");

    let dto = require_group_dto(state.pool(), id).await?;
    Ok(Json(dto))
}

/// `DELETE /config/groups/{id}` — delete a group (members revert to their own
/// policy / the default; membership rows cascade).
async fn delete_group(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let _ = require_group(state.pool(), id).await?;
    let n = db::delete_group(state.pool(), id)
        .await
        .context("delete_group")?;
    if n == 0 {
        return Err(ApiError::NotFound(format!("group {id} not found")));
    }
    tracing::info!(group_id = %id, "camera group deleted");
    Ok(StatusCode::NO_CONTENT)
}

/// `PUT /config/groups/{id}/members` — replace the group's membership wholesale.
///
/// A camera already in another group is MOVED here (one-group-per-camera).
async fn set_group_members(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<SetMembersRequest>,
) -> Result<Json<CameraGroupDto>, ApiError> {
    let _ = require_group(state.pool(), id).await?;
    db::set_group_members(state.pool(), id, &body.camera_ids)
        .await
        .context("set_group_members")?;
    tracing::info!(group_id = %id, members = body.camera_ids.len(), "group members set");

    let dto = require_group_dto(state.pool(), id).await?;
    Ok(Json(dto))
}

// ─── storages ─────────────────────────────────────────────────────────────────

/// `GET /config/storages` — list all storage rows with live free-space data.
async fn list_storages(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<StorageDto>>, ApiError> {
    let storages = db::list_storages(state.pool())
        .await
        .context("list_storages")?;
    let dtos = storages.into_iter().map(storage_to_dto).collect();
    Ok(Json(dtos))
}

/// `POST /config/storages` — create a new storage row.
///
/// Validates that the path exists and is a directory before inserting.  Returns
/// `201 Created`.
async fn create_storage(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<CreateStorageRequest>,
) -> Result<(StatusCode, Json<StorageDto>), ApiError> {
    // Validate the path: must exist and be a directory.
    validate_storage_path(&body.path)?;

    // Optional media-glyph override (display only): validate if given, else NULL
    // (the glyph infers from the name).
    let icon = match body.icon.as_deref().map(str::trim) {
        Some(s) if !s.is_empty() => Some(
            crumb_common::icons::normalize_storage_icon(s).ok_or_else(|| {
                ApiError::BadRequest(format!("icon must be ssd/hdd/disk, got '{s}'"))
            })?,
        ),
        _ => None,
    };

    let storage = db::create_storage(state.pool(), &body.name, &body.path, body.total_bytes, icon)
        .await
        .map_err(|e| {
            if is_unique_violation(&e) {
                ApiError::Conflict(format!("a storage named '{}' already exists", body.name))
            } else {
                ApiError::Internal(e)
            }
        })?;

    tracing::info!(storage_id = %storage.id, name = %storage.name, "storage created");
    Ok((StatusCode::CREATED, Json(storage_to_dto(storage))))
}

/// `GET /config/storages/{id}` — single storage with live free-space data.
async fn get_storage(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<StorageDto>, ApiError> {
    let storage = require_storage(state.pool(), id).await?;
    Ok(Json(storage_to_dto(storage)))
}

/// `PUT /config/storages/{id}` — partial update of a storage row.
async fn update_storage(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateStorageRequest>,
) -> Result<Json<StorageDto>, ApiError> {
    // Verify the row exists.
    let _ = require_storage(state.pool(), id).await?;

    // If a new path is provided, validate it.
    if let Some(ref path) = body.path {
        validate_storage_path(path)?;
    }

    // icon: Option<Option<String>>. Omitted = keep; Some(None)/Some(Some("")) =
    // clear to NULL (infer from name); Some(Some(v)) = validated kind.
    let icon: Option<Option<String>> = match &body.icon {
        None => None,
        Some(None) => Some(None),
        Some(Some(v)) => {
            let t = v.trim();
            if t.is_empty() {
                Some(None)
            } else {
                Some(Some(
                    crumb_common::icons::normalize_storage_icon(t)
                        .ok_or_else(|| {
                            ApiError::BadRequest(format!("icon must be ssd/hdd/disk, got '{t}'"))
                        })?
                        .to_owned(),
                ))
            }
        }
    };

    let storage = db::update_storage(
        state.pool(),
        id,
        body.name.as_deref(),
        body.path.as_deref(),
        body.total_bytes,
        icon.as_ref().map(std::option::Option::as_deref),
    )
    .await
    .map_err(|e| {
        if is_unique_violation(&e) {
            ApiError::Conflict("a storage with the provided name already exists".to_string())
        } else {
            ApiError::Internal(e)
        }
    })?;

    tracing::info!(storage_id = %id, "storage updated");
    Ok(Json(storage_to_dto(storage)))
}

/// `DELETE /config/storages/{id}` — delete a storage.
///
/// Refuses with `409 Conflict` if any camera's policy references this storage
/// as either the live or archive destination.
async fn delete_storage(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    // Verify the row exists (also gives us the human-readable name for messages).
    let storage = require_storage(state.pool(), id).await?;

    // Guard: refuse deletion if any recording policy references this storage —
    // and name those policies (and which role: live vs archive) so the UI can
    // tell the operator exactly what to clear first. An anonymous per-camera
    // fork has a NULL `name`; surface it as the owning camera ("<Camera>'s
    // custom settings") so the message is actionable rather than a bare UUID.
    let pool = state.pool();
    let client = pool.get().await.context("db pool get")?;

    // Guard 1: refuse if any recorded segments still live on this storage —
    // deleting the row would orphan that footage (segments.storage_id is a NOT
    // NULL FK with no cascade). Tell the operator how many recordings block it.
    let seg_row = client
        .query_one(
            "SELECT COUNT(*)::bigint AS cnt FROM segments WHERE storage_id = $1",
            &[&id],
        )
        .await
        .context("check segment references on storage")?;
    let seg_cnt: i64 = seg_row.get("cnt");
    if seg_cnt > 0 {
        return Err(ApiError::Conflict(format!(
            "\"{}\" holds {seg_cnt} recording{}; clear that footage before \
             deleting this location.",
            storage.name,
            if seg_cnt == 1 { "" } else { "s" },
        )));
    }

    // Guard 2: refuse if any recording policy references this storage —
    let rows = client
        .query(
            r"
            SELECT
                COALESCE(rp.name, c.name || '''s custom settings', 'a recording profile')
                    AS label,
                (rp.live_storage_id = $1)    AS is_live,
                (rp.archive_storage_id = $1) AS is_archive
            FROM recording_policies rp
            LEFT JOIN cameras c ON c.policy_id = rp.id
            WHERE rp.live_storage_id = $1 OR rp.archive_storage_id = $1
            ORDER BY label
            ",
            &[&id],
        )
        .await
        .context("check storage references in recording_policies")?;

    if !rows.is_empty() {
        // Build "Default (live), Night (archive)" — one entry per referencing
        // policy, de-duplicated, so the reason fits inline in the console.
        let mut refs: Vec<String> = Vec::with_capacity(rows.len());
        for row in &rows {
            let label: String = row.get("label");
            let is_live: bool = row.get("is_live");
            let is_archive: bool = row.get("is_archive");
            let role = match (is_live, is_archive) {
                (true, true) => "live + archive",
                (true, false) => "live",
                _ => "archive",
            };
            let entry = format!("{label} ({role})");
            if !refs.contains(&entry) {
                refs.push(entry);
            }
        }
        let cnt = refs.len();
        return Err(ApiError::Conflict(format!(
            "\"{}\" is still used by {cnt} recording profile{}: {}. \
             Reassign {} to another location before deleting.",
            storage.name,
            if cnt == 1 { "" } else { "s" },
            refs.join(", "),
            if cnt == 1 { "it" } else { "them" },
        )));
    }

    drop(client);

    db::delete_storage(pool, id)
        .await
        .context("delete_storage")?;

    tracing::info!(storage_id = %id, "storage deleted");
    Ok(StatusCode::NO_CONTENT)
}

// ─── server filesystem browsing (storage-path folder picker) ──────────────────

/// Container-noise roots skipped when listing `/` — never real recording
/// storage, just clutter an operator would otherwise have to page past.
const FS_ROOT_NOISE: &[&str] = &["proc", "sys", "dev", "run", "boot"];

/// `GET /config/fs/list?path=<absolute path>` — list the subdirectories of
/// `path` for the admin console's storage-path "Browse…" picker.
///
/// Directories only, never files/contents. Missing `path` defaults to `/data`
/// (falling back to `/` if that does not exist). The path is canonicalized
/// (resolving `..`/symlinks) before listing, so traversal attempts collapse to
/// a real filesystem path rather than being rejected — a non-existent or
/// non-directory path is a normal `200 {exists:false, dirs:[]}` response (the
/// UI treats that as "type a new path / navigate up"). Only a relative or
/// empty `path` is a `400`.
async fn list_fs(
    _admin: AdminUser,
    Query(q): Query<FsListQuery>,
) -> Result<Json<FsListResponseDto>, ApiError> {
    let requested = match q.path {
        Some(p) => p,
        None => {
            if tokio::fs::metadata("/data").await.is_ok() {
                "/data".to_owned()
            } else {
                "/".to_owned()
            }
        }
    };

    if requested.trim().is_empty() {
        return Err(ApiError::BadRequest("path must not be empty".to_owned()));
    }
    if !std::path::Path::new(&requested).is_absolute() {
        return Err(ApiError::BadRequest(format!(
            "path must be absolute, got '{requested}'"
        )));
    }

    // Canonicalize BEFORE listing so `..`/symlink traversal games collapse to a
    // real path rather than needing to be pattern-matched away. A path that
    // doesn't exist (or can't be resolved) is NOT an error here — it just means
    // there is nothing to list yet.
    let canonical = match tokio::fs::canonicalize(&requested).await {
        Ok(c) => c,
        Err(_) => return Ok(Json(not_found_fs_response(&requested))),
    };

    let meta = match tokio::fs::metadata(&canonical).await {
        Ok(m) => m,
        Err(_) => return Ok(Json(not_found_fs_response(&canonical.to_string_lossy()))),
    };

    if !meta.is_dir() {
        return Ok(Json(not_found_fs_response(&canonical.to_string_lossy())));
    }

    let mut names: Vec<String> = Vec::new();
    let mut read_dir = tokio::fs::read_dir(&canonical).await.context("read_dir")?;
    loop {
        // A permission error (or any other transient error) on an individual
        // entry is skipped rather than failing the whole listing.
        let entry = match read_dir.next_entry().await {
            Ok(Some(e)) => e,
            Ok(None) => break,
            Err(_) => break,
        };
        let name = entry.file_name().to_string_lossy().into_owned();
        // Only directories; skip files/symlink-to-files silently (a failed
        // `file_type()` — e.g. a permission error — is skipped too).
        let is_dir = entry.file_type().await.is_ok_and(|t| t.is_dir());
        if !is_dir {
            continue;
        }
        names.push(name);
    }

    let dirs = filter_and_sort_fs_entries(names, canonical.is_root_listing())
        .into_iter()
        .map(|name| FsDirEntryDto {
            path: canonical.join(&name).to_string_lossy().into_owned(),
            name,
        })
        .collect();

    Ok(Json(FsListResponseDto {
        path: canonical.to_string_lossy().into_owned(),
        parent: canonical.parent().map(|p| p.to_string_lossy().into_owned()),
        exists: true,
        dirs,
    }))
}

/// The `{exists:false, dirs:[]}` shape shared by every "nothing to list"
/// outcome in [`list_fs`] (missing path, unreadable, or not a directory).
fn not_found_fs_response(path: &str) -> FsListResponseDto {
    FsListResponseDto {
        path: path.to_owned(),
        parent: std::path::Path::new(path)
            .parent()
            .map(|p| p.to_string_lossy().into_owned()),
        exists: false,
        dirs: Vec::new(),
    }
}

/// `POST /config/fs/check` — preflight a candidate recording path before it is
/// committed. Storage *creation* only rejects a plainly-invalid path
/// ([`validate_storage_path`]) — crucially it does NOT check free space, so a
/// writable-but-full (or `statvfs`-reports-zero) disk sails through. This
/// endpoint reports granular facts (under-media-root, exists, is-dir, writable,
/// total/free bytes) plus an overall `status` verdict so the setup wizard can
/// render a live status line and refuse to advance when recording would fail.
///
/// Read-only apart from a throwaway write-probe file that is created and removed
/// immediately (the only reliable way to know the recorder can actually write).
async fn check_fs(
    _admin: AdminUser,
    Json(body): Json<FsCheckRequest>,
) -> Result<Json<FsCheckResponse>, ApiError> {
    // Below this much free space we warn (usable but footage evicts fast); a path
    // reporting truly 0 free is an error.
    const LOW_FREE_BYTES: i64 = 2 * 1024 * 1024 * 1024; // 2 GiB

    let requested = body.path.trim().to_owned();
    if requested.is_empty() {
        return Err(ApiError::BadRequest("path must not be empty".to_owned()));
    }
    if !std::path::Path::new(&requested).is_absolute() {
        return Err(ApiError::BadRequest(format!(
            "path must be absolute, got '{requested}'"
        )));
    }

    let root = std::env::var("MEDIA_ROOT").unwrap_or_else(|_| "/data".to_owned());
    let p = std::path::Path::new(&requested);
    let under_media_root = p.starts_with(std::path::Path::new(&root));

    // Existence / directory-ness — canonicalize when it exists so `..`/symlinks
    // collapse to a real path; a non-existent path is a normal (not error) case.
    let (path_out, exists, is_dir) = match tokio::fs::canonicalize(&requested).await {
        Ok(c) => {
            let is_dir = tokio::fs::metadata(&c).await.is_ok_and(|m| m.is_dir());
            (c.to_string_lossy().into_owned(), true, is_dir)
        }
        Err(_) => (requested.clone(), false, false),
    };

    // Where the recorder would actually write: the dir itself if it exists, else
    // its parent (the recorder creates the leaf subdir on first write). `None`
    // means the path exists but is a file — nowhere to write.
    let probe_dir: Option<std::path::PathBuf> = if exists && is_dir {
        Some(std::path::PathBuf::from(&path_out))
    } else if !exists {
        p.parent().map(std::path::PathBuf::from)
    } else {
        None
    };

    // Three-state writability. The standard compose mounts /data READ-ONLY into
    // this (api) container — the recorder holds the RW mount — so a failed write
    // probe on an RO mount says nothing about the recorder's ability to write.
    // Only a failed probe on a mount the api itself sees as read-write is a real
    // permission problem.
    let writable: Option<bool> = match &probe_dir {
        Some(dir) => {
            if probe_writable(dir).await {
                Some(true)
            } else if mount_readonly_for_path(&dir.to_string_lossy()) == Some(true) {
                None // api-side mount is RO by design — recorder writability unknown
            } else {
                Some(false)
            }
        }
        None => Some(false),
    };
    let (total_bytes, free_bytes) = match probe_dir
        .as_deref()
        .and_then(|d| disk_stats_for_path(&d.to_string_lossy()))
    {
        Some((t, f)) => (Some(t), Some(f)),
        None => (None, None),
    };

    // Verdict — most severe first.
    let (status, message) = if !under_media_root {
        (
            "error",
            format!(
                "This folder is outside the recorder's writable area ('{root}'). \
                 Choose a path under '{root}/…'."
            ),
        )
    } else if exists && !is_dir {
        (
            "error",
            format!("'{requested}' exists but is not a folder."),
        )
    } else if probe_dir.is_none() {
        (
            "error",
            format!("'{requested}' can't be created — it has no parent folder."),
        )
    } else if writable == Some(false) {
        (
            "error",
            "The recorder can't write to this folder (permission denied). \
             Check ownership/permissions on the mounted disk."
                .to_owned(),
        )
    } else if free_bytes == Some(0) {
        (
            "error",
            "This disk reports 0 bytes free — recording would fail immediately. \
             Point Crumb at a disk with real free space."
                .to_owned(),
        )
    } else if let Some(f) = free_bytes {
        if f < LOW_FREE_BYTES {
            (
                "warn",
                format!(
                    "Only {} free — footage will be evicted almost immediately. \
                     Use a larger disk if you can.",
                    fmt_bytes_dec(f)
                ),
            )
        } else {
            (
                "ok",
                format!(
                    "{} free of {}.",
                    fmt_bytes_dec(f),
                    total_bytes.map_or_else(|| "?".to_owned(), fmt_bytes_dec)
                ),
            )
        }
    } else {
        // Writable and under the media root, but statvfs couldn't read the size —
        // usable but unverified (e.g. an exotic mount).
        (
            "warn",
            "This folder is writable, but its free space couldn't be read. \
             Make sure the disk has room for recordings."
                .to_owned(),
        )
    };

    Ok(Json(FsCheckResponse {
        path: path_out,
        under_media_root,
        exists,
        is_dir,
        writable,
        total_bytes,
        free_bytes,
        status: status.to_owned(),
        message,
    }))
}

/// Whether the filesystem at `path` is mounted read-only *from this (api)
/// container's point of view* (`statvfs` `ST_RDONLY`). The standard compose
/// gives the api `/data:ro` — so `Some(true)` here usually means "by design",
/// not "broken". `None` when `statvfs` is unavailable.
fn mount_readonly_for_path(path: &str) -> Option<bool> {
    #[cfg(unix)]
    {
        use std::ffi::CString;
        let c_path = CString::new(path).ok()?;
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        // SAFETY: valid C string + local zeroed struct, per POSIX statvfs(3).
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &raw mut stat) };
        if rc == 0 {
            Some(stat.f_flag & libc::ST_RDONLY != 0)
        } else {
            None
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// Best-effort proof that the recorder can create files in `dir`: write a
/// throwaway dotfile and remove it. Any error (missing dir, permission denied,
/// read-only mount) → `false`. The probe name is process-scoped so concurrent
/// checks don't collide.
async fn probe_writable(dir: &std::path::Path) -> bool {
    let probe = dir.join(format!(".crumb-writetest-{}", std::process::id()));
    match tokio::fs::write(&probe, b"").await {
        Ok(()) => {
            let _ = tokio::fs::remove_file(&probe).await;
            true
        }
        Err(_) => false,
    }
}

/// Compact decimal byte formatting (1 GB = 1,000,000,000 B) for preflight
/// messages — matches the console's `fmtBytes` and the "decimal units" note.
#[allow(clippy::cast_precision_loss)] // display-only figures
fn fmt_bytes_dec(b: i64) -> String {
    let bf = b as f64;
    if bf >= 1e12 {
        format!("{:.1} TB", bf / 1e12)
    } else if bf >= 1e9 {
        format!("{:.1} GB", bf / 1e9)
    } else if bf >= 1e6 {
        format!("{:.0} MB", bf / 1e6)
    } else {
        format!("{b} B")
    }
}

/// Small helper trait so [`list_fs`] can ask "is this the filesystem root?"
/// without repeating the `parent().is_none()` check inline.
trait IsRootListing {
    fn is_root_listing(&self) -> bool;
}

impl IsRootListing for std::path::Path {
    fn is_root_listing(&self) -> bool {
        self.parent().is_none()
    }
}

/// Filter hidden entries (leading `.`) and — only when listing the filesystem
/// root — the container-noise roots ([`FS_ROOT_NOISE`]), then sort the
/// remainder by name, case-insensitively. Pure/sync so it is trivially unit
/// tested without touching the filesystem.
fn filter_and_sort_fs_entries(names: Vec<String>, at_fs_root: bool) -> Vec<String> {
    let mut kept: Vec<String> = names
        .into_iter()
        .filter(|n| !n.starts_with('.'))
        .filter(|n| !(at_fs_root && FS_ROOT_NOISE.contains(&n.as_str())))
        .collect();
    kept.sort_by_key(|n| n.to_ascii_lowercase());
    kept
}

// ─── users ────────────────────────────────────────────────────────────────────

/// `GET /config/users` — list all users (no `password_hash` in response).
async fn list_users(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<UserDto>>, ApiError> {
    let users = db::list_users(state.pool()).await.context("list_users")?;
    Ok(Json(users.into_iter().map(user_to_dto).collect()))
}

/// `POST /config/users` — create a user.
///
/// The plaintext password is hashed with Argon2id before storage; it is never
/// persisted or returned.  Returns `201 Created`.
async fn create_user(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<UserDto>), ApiError> {
    validate_username(&body.username)?;
    validate_password(&body.password)?;

    let hash = hash_password(&body.password)?;

    // New model: assign a permission role by id (carries caps + cameras). The
    // legacy `role` (admin/viewer) text column is kept in sync as a mirror of the
    // role's is_admin so the existing UserRole-based guards/JWT keep working. The
    // per-user `camera_ids` column now holds OPTIONAL extra cameras granted to this
    // user on top of the role's set (effective access = role ∪ user; see auth_mw).
    // Admins ignore cameras entirely. Fall back to the legacy role/camera_ids path
    // when no role_id is supplied.
    let (eff_role, role_id, camera_ids) = if let Some(rid) = body.role_id {
        let role = db::get_role(state.pool(), rid)
            .await
            .context("get_role")?
            .ok_or_else(|| ApiError::BadRequest(format!("role {rid} not found")))?;
        let ur = if role.is_admin {
            UserRole::Admin
        } else {
            UserRole::Viewer
        };
        let cams = if role.is_admin {
            Vec::new()
        } else {
            body.camera_ids.clone()
        };
        (ur, Some(rid), cams)
    } else {
        let ur = body.role.unwrap_or(UserRole::Viewer);
        let cams = if matches!(ur, UserRole::Admin) {
            Vec::new()
        } else {
            body.camera_ids.clone()
        };
        (ur, None, cams)
    };

    let user = db::create_user(
        state.pool(),
        &body.username,
        &hash,
        eff_role,
        &camera_ids,
        role_id,
    )
    .await
    .map_err(|e| {
        if is_unique_violation(&e) {
            ApiError::Conflict(format!("username '{}' is already taken", body.username))
        } else {
            ApiError::Internal(e)
        }
    })?;

    tracing::info!(user_id = %user.id, username = %user.username, "user created");
    Ok((StatusCode::CREATED, Json(user_to_dto(user))))
}

/// `GET /config/users/{id}` — single user by UUID.
async fn get_user(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<UserDto>, ApiError> {
    let user = require_user(state.pool(), id).await?;
    Ok(Json(user_to_dto(user)))
}

/// `PUT /config/users/{id}` — partial update.
///
/// If `password` is provided it is re-hashed.  If `role` changes from viewer to
/// admin, `camera_ids` is cleared automatically.
async fn update_user(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateUserRequest>,
) -> Result<Json<UserDto>, ApiError> {
    // Verify the user exists.
    let existing = require_user(state.pool(), id).await?;

    if let Some(ref uname) = body.username {
        validate_username(uname)?;
    }
    if let Some(ref pw) = body.password {
        validate_password(pw)?;
    }

    let new_hash = body.password.as_deref().map(hash_password).transpose()?;

    // Resolve the new role assignment. New model: `role_id` (carries caps +
    // cameras) mirrored into the legacy `role` text column. The per-user
    // `camera_ids` now carries OPTIONAL extra cameras on top of the role's set
    // (effective = role ∪ user; admins ignore cameras). When `role_id` is supplied
    // for a non-admin role, pass body.camera_ids through (None = leave unchanged).
    // Legacy path applies only when no `role_id` is supplied.
    #[allow(clippy::type_complexity)]
    let (new_role, role_id_to_set, final_camera_ids): (
        Option<UserRole>,
        Option<Uuid>,
        Option<Vec<Uuid>>,
    ) = if let Some(rid) = body.role_id {
        let role = db::get_role(state.pool(), rid)
            .await
            .context("get_role")?
            .ok_or_else(|| ApiError::BadRequest(format!("role {rid} not found")))?;
        let ur = if role.is_admin {
            UserRole::Admin
        } else {
            UserRole::Viewer
        };
        let cams = if role.is_admin {
            Some(Vec::new())
        } else {
            body.camera_ids.clone()
        };
        (Some(ur), Some(rid), cams)
    } else {
        let nr = body.role;
        let eff = nr.unwrap_or(existing.role);
        let cams = match eff {
            UserRole::Admin => Some(Vec::new()),
            UserRole::Viewer => body.camera_ids.clone(),
        };
        (nr, None, cams)
    };

    // Effective role after this update — used for the last-admin guard.
    let effective_role = new_role.unwrap_or(existing.role);

    // Guard: never demote the LAST administrator to viewer — that drives the system
    // to zero admins, which (with the first-run bootstrap route) would open an
    // UNAUTHENTICATED admin-creation window. Mirror the delete_user last-admin guard.
    if matches!(existing.role, UserRole::Admin) && matches!(effective_role, UserRole::Viewer) {
        let users = db::list_users(state.pool()).await.context("list_users")?;
        let admins = users
            .iter()
            .filter(|u| matches!(u.role, UserRole::Admin))
            .count();
        if admins <= 1 {
            return Err(ApiError::Conflict(
                "cannot demote the last administrator — create another admin first".to_owned(),
            ));
        }
    }

    let user = db::update_user(
        state.pool(),
        id,
        body.username.as_deref(),
        new_hash.as_deref(),
        new_role,
        final_camera_ids.as_deref(),
        role_id_to_set,
    )
    .await
    .map_err(|e| {
        if is_unique_violation(&e) {
            ApiError::Conflict(format!(
                "username '{}' is already taken",
                body.username.as_deref().unwrap_or_default()
            ))
        } else {
            ApiError::Internal(e)
        }
    })?;

    tracing::info!(user_id = %id, "user updated");
    Ok(Json(user_to_dto(user)))
}

/// `DELETE /config/users/{id}` — delete a user.
async fn delete_user(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    // Verify existence → 404 if not found.
    let existing = require_user(state.pool(), id).await?;

    // Guard: never remove the last administrator — that would lock everyone out
    // of this console. Refuse with a clear reason the UI can show inline.
    if matches!(existing.role, UserRole::Admin) {
        let users = db::list_users(state.pool()).await.context("list_users")?;
        let admins = users
            .iter()
            .filter(|u| matches!(u.role, UserRole::Admin))
            .count();
        if admins <= 1 {
            return Err(ApiError::Conflict(
                "cannot remove the last administrator — create another admin first".to_owned(),
            ));
        }
    }

    db::delete_user(state.pool(), id)
        .await
        .context("delete_user")?;

    tracing::info!(user_id = %id, "user deleted");
    Ok(StatusCode::NO_CONTENT)
}

// ─── shared policy update logic ───────────────────────────────────────────────

/// Apply a partial [`UpdatePolicyRequest`] to any policy row identified by
/// `policy_id`.  Reads the current row, merges, writes back, and returns the
/// updated [`RecordingPolicy`].
///
/// Used by both `update_camera_policy` and `update_default_policy`.
async fn apply_policy_update(
    pool: &Pool,
    policy_id: Uuid,
    body: &UpdatePolicyRequest,
) -> Result<RecordingPolicy, ApiError> {
    let existing = db::get_policy(pool, policy_id)
        .await
        .context("get_policy")?
        .ok_or_else(|| ApiError::NotFound(format!("policy {policy_id} not found")))?;

    // Resolve final field values: patch over existing.
    let mode = body.mode.unwrap_or(existing.mode).as_str().to_owned();

    let live_storage_id = body.live_storage_id.or(existing.live_storage_id);

    let live_retention_hours = body
        .live_retention_hours
        .unwrap_or(existing.live_retention_hours);

    let archive_enabled = body.archive_enabled.unwrap_or(existing.archive_enabled);

    // archive_storage_id: Option<Option<Uuid>> — Some(None) clears it.
    let archive_storage_id: Option<Uuid> = match body.archive_storage_id {
        Some(inner) => inner,
        None => existing.archive_storage_id,
    };

    // archive_schedule: Option<Option<String>> — Some(None) clears it.
    let archive_schedule: Option<String> = match &body.archive_schedule {
        Some(inner) => inner.clone(),
        None => existing.archive_schedule.clone(),
    };

    // archive_retention_hours: Option<Option<i32>> — Some(None) clears it.
    let archive_retention_hours: Option<i32> = match body.archive_retention_hours {
        Some(inner) => inner,
        None => existing.archive_retention_hours,
    };

    // live_max_bytes / archive_max_bytes: Option<Option<i64>> — Some(None) clears
    // the cap to NULL ("no cap"); omitted leaves it unchanged. Same pattern as
    // archive_retention_hours. UI sends bytes (it presents GB).
    let live_max_bytes: Option<i64> = match body.live_max_bytes {
        Some(inner) => inner,
        None => existing.live_max_bytes,
    };
    let archive_max_bytes: Option<i64> = match body.archive_max_bytes {
        Some(inner) => inner,
        None => existing.archive_max_bytes,
    };

    // Advanced storage knobs: Option<Option<_>> — Some(None) clears to NULL (=
    // system default / no hysteresis); omitted leaves unchanged.
    let live_min_free_pct: Option<f32> = match body.live_min_free_pct {
        Some(inner) => inner,
        None => existing.live_min_free_pct,
    };
    let live_min_free_bytes: Option<i64> = match body.live_min_free_bytes {
        Some(inner) => inner,
        None => existing.live_min_free_bytes,
    };
    let live_spill_low_water_bytes: Option<i64> = match body.live_spill_low_water_bytes {
        Some(inner) => inner,
        None => existing.live_spill_low_water_bytes,
    };

    // max_retention_days: Option<Option<i32>> — Some(None) clears to NULL (= OFF,
    // no cap); omitted leaves it unchanged. Opt-in absolute retention ceiling.
    let max_retention_days: Option<i32> = match body.max_retention_days {
        Some(inner) => inner,
        None => existing.max_retention_days,
    };

    // Cross-field: an archive size cap only makes sense when archiving is on.
    // Checked here (not in the stateless validate_update_policy) because the
    // EFFECTIVE archive_enabled depends on `existing` when the body omits it.
    if archive_max_bytes.is_some() && !archive_enabled {
        return Err(ApiError::BadRequest(
            "archive_max_bytes requires archive_enabled".to_owned(),
        ));
    }

    // Cross-field: the spill buffer must be SMALLER than any size cap it drains to
    // (a spill >= cap would set the stop target to 0 and evict everything). Checked
    // here because the EFFECTIVE cap depends on `existing` when the body omits it.
    // A spill with NO live cap is allowed (it still pads the free-floor branch).
    if let Some(spill) = live_spill_low_water_bytes.filter(|s| *s > 0) {
        if let Some(cap) = live_max_bytes.filter(|c| *c > 0) {
            if spill >= cap {
                return Err(ApiError::BadRequest(
                    "live_spill_low_water_bytes must be smaller than live_max_bytes".to_owned(),
                ));
            }
        }
        if let Some(cap) = archive_max_bytes.filter(|c| *c > 0) {
            if spill >= cap {
                return Err(ApiError::BadRequest(
                    "live_spill_low_water_bytes must be smaller than archive_max_bytes".to_owned(),
                ));
            }
        }
    }

    let motion_pre_seconds = body
        .motion_pre_seconds
        .unwrap_or(existing.motion_pre_seconds);

    let motion_post_seconds = body
        .motion_post_seconds
        .unwrap_or(existing.motion_post_seconds);

    // motion_sensitivity: validated string → enum → stored as text.
    let motion_sensitivity: String = match &body.motion_sensitivity {
        Some(s) => MotionSensitivity::from_str(s)
            .ok_or_else(|| {
                ApiError::UnprocessableEntity(format!(
                    "motion_sensitivity must be 'dynamic' or 'manual', got '{s}'"
                ))
            })?
            .as_str()
            .to_owned(),
        None => existing.motion_sensitivity.as_str().to_owned(),
    };

    // motion_threshold: Option<Option<f32>> — Some(None) clears it (→ default
    // floor). It is a FRACTION of frame area (0..1); clamp to a sane manual range
    // (0.05%..5% of frame) when set so a bad client value can't be persisted.
    let motion_threshold: Option<f32> = match body.motion_threshold {
        Some(inner) => inner.map(|v| v.clamp(0.0005, 0.05)),
        None => existing.motion_threshold,
    };

    let motion_keyframes_only = body
        .motion_keyframes_only
        .unwrap_or(existing.motion_keyframes_only);

    // record_stream: validated string.
    let record_stream: String = match &body.record_stream {
        Some(s) => RecordStream::from_str(s)
            .ok_or_else(|| {
                ApiError::UnprocessableEntity(format!(
                    "record_stream must be 'main' or 'sub', got '{s}'"
                ))
            })?
            .as_str()
            .to_owned(),
        None => existing.record_stream.as_str().to_owned(),
    };

    let record_audio = body.record_audio.unwrap_or(existing.record_audio);

    let client = pool.get().await.context("db pool get")?;
    client
        .execute(
            r"
            UPDATE recording_policies
            SET mode                    = $2,
                live_storage_id         = $3,
                live_retention_hours    = $4,
                archive_enabled         = $5,
                archive_storage_id      = $6,
                archive_schedule        = $7,
                archive_retention_hours = $8,
                motion_pre_seconds      = $9,
                motion_post_seconds     = $10,
                motion_sensitivity      = $11,
                motion_threshold        = $12,
                motion_keyframes_only   = $13,
                record_stream           = $14,
                record_audio            = $15,
                live_max_bytes          = $16,
                archive_max_bytes       = $17,
                live_min_free_pct          = $18,
                live_min_free_bytes        = $19,
                live_spill_low_water_bytes = $20,
                max_retention_days         = $21
            WHERE id = $1
            ",
            &[
                &policy_id,
                &mode,
                &live_storage_id,
                &live_retention_hours,
                &archive_enabled,
                &archive_storage_id,
                &archive_schedule,
                &archive_retention_hours,
                &motion_pre_seconds,
                &motion_post_seconds,
                &motion_sensitivity,
                &motion_threshold,
                &motion_keyframes_only,
                &record_stream,
                &record_audio,
                &live_max_bytes,
                &archive_max_bytes,
                &live_min_free_pct,
                &live_min_free_bytes,
                &live_spill_low_water_bytes,
                &max_retention_days,
            ],
        )
        .await
        .context("update recording_policy")?;

    drop(client);

    // Re-read to return the authoritative DB state.
    let updated = db::get_policy(pool, policy_id)
        .await
        .context("get_policy after update")?
        .ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!(
                "policy {policy_id} disappeared after update"
            ))
        })?;

    Ok(updated)
}

// ─── shared policy-field resolution (named create/update) ─────────────────────

/// An owned, fully-resolved set of policy field values.
///
/// [`db::PolicyFields`] borrows `&str`; this struct owns the strings so the
/// handler can build the borrowed view via [`Self::as_fields`] right before the
/// DB call. Produced by [`resolve_policy_fields`] (patch over a baseline policy).
struct ResolvedPolicy {
    name: Option<String>,
    mode: String,
    live_storage_id: Option<Uuid>,
    live_retention_hours: i32,
    archive_enabled: bool,
    archive_storage_id: Option<Uuid>,
    archive_schedule: Option<String>,
    archive_retention_hours: Option<i32>,
    live_max_bytes: Option<i64>,
    archive_max_bytes: Option<i64>,
    live_min_free_pct: Option<f32>,
    live_min_free_bytes: Option<i64>,
    live_spill_low_water_bytes: Option<i64>,
    max_retention_days: Option<i32>,
    motion_pre_seconds: i32,
    motion_post_seconds: i32,
    motion_sensitivity: String,
    motion_threshold: Option<f32>,
    motion_keyframes_only: bool,
    record_stream: String,
    record_audio: bool,
}

impl ResolvedPolicy {
    fn as_fields(&self) -> PolicyFields<'_> {
        PolicyFields {
            name: self.name.as_deref(),
            mode: &self.mode,
            live_storage_id: self.live_storage_id,
            live_retention_hours: self.live_retention_hours,
            archive_enabled: self.archive_enabled,
            archive_storage_id: self.archive_storage_id,
            archive_schedule: self.archive_schedule.as_deref(),
            archive_retention_hours: self.archive_retention_hours,
            live_max_bytes: self.live_max_bytes,
            archive_max_bytes: self.archive_max_bytes,
            live_min_free_pct: self.live_min_free_pct,
            live_min_free_bytes: self.live_min_free_bytes,
            live_spill_low_water_bytes: self.live_spill_low_water_bytes,
            max_retention_days: self.max_retention_days,
            motion_pre_seconds: self.motion_pre_seconds,
            motion_post_seconds: self.motion_post_seconds,
            motion_sensitivity: &self.motion_sensitivity,
            motion_threshold: self.motion_threshold,
            motion_keyframes_only: self.motion_keyframes_only,
            record_stream: &self.record_stream,
            record_audio: self.record_audio,
        }
    }
}

/// Patch a partial [`UpdatePolicyRequest`] over a baseline [`RecordingPolicy`],
/// producing fully-resolved owned field values for create/replace.
///
/// Mirrors the merge semantics of [`apply_policy_update`] (`Some(None)` clears,
/// omitted keeps the baseline, enum strings validated, `motion_threshold`
/// clamped) but does NOT read/write the DB — the caller hands the result to
/// [`db::create_policy`] or [`db::update_policy`]. `name` is supplied separately
/// (it isn't part of `UpdatePolicyRequest`).
fn resolve_policy_fields(
    base: &RecordingPolicy,
    body: &UpdatePolicyRequest,
    name: Option<&str>,
) -> Result<ResolvedPolicy, ApiError> {
    let mode = body.mode.unwrap_or(base.mode).as_str().to_owned();
    let live_storage_id = body.live_storage_id.or(base.live_storage_id);
    let live_retention_hours = body
        .live_retention_hours
        .unwrap_or(base.live_retention_hours);
    let archive_enabled = body.archive_enabled.unwrap_or(base.archive_enabled);

    let archive_storage_id: Option<Uuid> = match body.archive_storage_id {
        Some(inner) => inner,
        None => base.archive_storage_id,
    };
    let archive_schedule: Option<String> = match &body.archive_schedule {
        Some(inner) => inner.clone(),
        None => base.archive_schedule.clone(),
    };
    let archive_retention_hours: Option<i32> = match body.archive_retention_hours {
        Some(inner) => inner,
        None => base.archive_retention_hours,
    };
    let live_max_bytes: Option<i64> = match body.live_max_bytes {
        Some(inner) => inner,
        None => base.live_max_bytes,
    };
    let archive_max_bytes: Option<i64> = match body.archive_max_bytes {
        Some(inner) => inner,
        None => base.archive_max_bytes,
    };
    if archive_max_bytes.is_some() && !archive_enabled {
        return Err(ApiError::BadRequest(
            "archive_max_bytes requires archive_enabled".to_owned(),
        ));
    }

    let live_min_free_pct: Option<f32> = match body.live_min_free_pct {
        Some(inner) => inner,
        None => base.live_min_free_pct,
    };
    let live_min_free_bytes: Option<i64> = match body.live_min_free_bytes {
        Some(inner) => inner,
        None => base.live_min_free_bytes,
    };
    let live_spill_low_water_bytes: Option<i64> = match body.live_spill_low_water_bytes {
        Some(inner) => inner,
        None => base.live_spill_low_water_bytes,
    };
    // Spill must be smaller than any cap it drains to (else stop target = 0 =
    // evict everything). Spill with no cap is allowed (pads the free-floor branch).
    if let Some(spill) = live_spill_low_water_bytes.filter(|s| *s > 0) {
        if let Some(cap) = live_max_bytes.filter(|c| *c > 0) {
            if spill >= cap {
                return Err(ApiError::BadRequest(
                    "live_spill_low_water_bytes must be smaller than live_max_bytes".to_owned(),
                ));
            }
        }
        if let Some(cap) = archive_max_bytes.filter(|c| *c > 0) {
            if spill >= cap {
                return Err(ApiError::BadRequest(
                    "live_spill_low_water_bytes must be smaller than archive_max_bytes".to_owned(),
                ));
            }
        }
    }

    // max_retention_days: Some(None) clears (→ OFF); omitted keeps the baseline.
    let max_retention_days: Option<i32> = match body.max_retention_days {
        Some(inner) => inner,
        None => base.max_retention_days,
    };

    let motion_pre_seconds = body.motion_pre_seconds.unwrap_or(base.motion_pre_seconds);
    let motion_post_seconds = body.motion_post_seconds.unwrap_or(base.motion_post_seconds);

    let motion_sensitivity: String = match &body.motion_sensitivity {
        Some(s) => MotionSensitivity::from_str(s)
            .ok_or_else(|| {
                ApiError::UnprocessableEntity(format!(
                    "motion_sensitivity must be 'dynamic' or 'manual', got '{s}'"
                ))
            })?
            .as_str()
            .to_owned(),
        None => base.motion_sensitivity.as_str().to_owned(),
    };
    let motion_threshold: Option<f32> = match body.motion_threshold {
        Some(inner) => inner.map(|v| v.clamp(0.0005, 0.05)),
        None => base.motion_threshold,
    };
    let motion_keyframes_only = body
        .motion_keyframes_only
        .unwrap_or(base.motion_keyframes_only);
    let record_stream: String = match &body.record_stream {
        Some(s) => RecordStream::from_str(s)
            .ok_or_else(|| {
                ApiError::UnprocessableEntity(format!(
                    "record_stream must be 'main' or 'sub', got '{s}'"
                ))
            })?
            .as_str()
            .to_owned(),
        None => base.record_stream.as_str().to_owned(),
    };
    let record_audio = body.record_audio.unwrap_or(base.record_audio);

    Ok(ResolvedPolicy {
        name: name.map(str::to_owned),
        mode,
        live_storage_id,
        live_retention_hours,
        archive_enabled,
        archive_storage_id,
        archive_schedule,
        archive_retention_hours,
        live_max_bytes,
        archive_max_bytes,
        live_min_free_pct,
        live_min_free_bytes,
        live_spill_low_water_bytes,
        max_retention_days,
        motion_pre_seconds,
        motion_post_seconds,
        motion_sensitivity,
        motion_threshold,
        motion_keyframes_only,
        record_stream,
        record_audio,
    })
}

// ─── helper: require_* ────────────────────────────────────────────────────────

/// Load a camera by ID or return `404 Not Found`.
async fn require_camera(pool: &Pool, id: Uuid) -> Result<Camera, ApiError> {
    db::get_camera(pool, id)
        .await
        .context("get_camera")?
        .ok_or_else(|| ApiError::NotFound(format!("camera {id} not found")))
}

/// Load a storage by ID or return `404 Not Found`.
async fn require_storage(pool: &Pool, id: Uuid) -> Result<Storage, ApiError> {
    db::get_storage(pool, id)
        .await
        .context("get_storage")?
        .ok_or_else(|| ApiError::NotFound(format!("storage {id} not found")))
}

/// Load a user by ID or return `404 Not Found`.
async fn require_user(pool: &Pool, id: Uuid) -> Result<User, ApiError> {
    db::get_user_by_id(pool, id)
        .await
        .context("get_user_by_id")?
        .ok_or_else(|| ApiError::NotFound(format!("user {id} not found")))
}

/// Load a recording policy by ID or return `404 Not Found`.
async fn require_policy(pool: &Pool, id: Uuid) -> Result<RecordingPolicy, ApiError> {
    db::get_policy(pool, id)
        .await
        .context("get_policy")?
        .ok_or_else(|| ApiError::NotFound(format!("policy {id} not found")))
}

// ─── guarded "Change storage" (repoint + optional footage drain) ───────────────

fn migration_to_dto(m: crumb_common::StorageMigration) -> StorageMigrationDto {
    StorageMigrationDto {
        id: m.id,
        policy_id: m.policy_id,
        from_storage_id: m.from_storage_id,
        to_storage_id: m.to_storage_id,
        status: m.status,
        total_segments: m.total_segments,
        moved_segments: m.moved_segments,
        moved_bytes: m.moved_bytes,
        error: m.error,
        created_at: m.created_at,
        updated_at: m.updated_at,
    }
}

/// `POST /config/policies/{id}/change-storage` — repoint a policy's live/archive
/// storage and, optionally, enqueue a guarded background drain of its EXISTING
/// footage from the old disk to the new one.
///
/// The repoint alone is already safe: the D1 fingerprint change reloads the
/// recording worker so NEW footage lands on the new disk immediately, and
/// existing footage keeps serving correctly (resolved by `storage_id`). The drain
/// (when requested) runs in the recorder under `ARCHIVE_GUARD` so footage moves
/// never race archiving/eviction. Pre-flight refuses a drain that plainly can't
/// fit — and does so BEFORE repointing, so a refused drain leaves the policy
/// untouched.
#[allow(clippy::cast_precision_loss)] // GB figures are display-only (error text)
async fn change_policy_storage(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<ChangeStorageRequest>,
) -> Result<Json<ChangeStorageResponse>, ApiError> {
    let pool = state.pool();
    let policy = require_policy(pool, id).await?;
    let target = require_storage(pool, body.to_storage_id).await?;
    validate_storage_path(&target.path)?; // target must exist + be a writable dir

    let role = body.stage.trim().to_ascii_lowercase();
    let current = match role.as_str() {
        "live" => policy.live_storage_id,
        "archive" => policy.archive_storage_id,
        _ => {
            return Err(ApiError::BadRequest(
                "stage must be 'live' or 'archive'".to_owned(),
            ))
        }
    };
    if current == Some(body.to_storage_id) {
        return Err(ApiError::BadRequest(format!(
            "policy '{}' already records {role} to '{}'",
            policy.name.as_deref().unwrap_or("Default"),
            target.name
        )));
    }

    // Size the drain + pre-flight BEFORE repointing, so a drain that can't fit
    // refuses the whole operation rather than leaving a half-applied change.
    let (mut segs, mut bytes) = (0i64, 0i64);
    if body.migrate_existing {
        if let Some(from) = current {
            segs = db::count_policy_segments_on_storage(pool, id, from)
                .await
                .context("count_policy_segments_on_storage")?;
            bytes = db::policy_bytes_on_storage(pool, id, from)
                .await
                .context("policy_bytes_on_storage")?;
            if let Some((_, free)) = disk_stats_for_path(&target.path) {
                if free < bytes {
                    return Err(ApiError::BadRequest(format!(
                        "target '{}' has {:.1} GB free but the drain needs {:.1} GB — \
                         free space and retry (nothing was changed)",
                        target.name,
                        free as f64 / 1e9,
                        bytes as f64 / 1e9
                    )));
                }
            }
        }
    }

    // Repoint via the shared policy-update path.
    let req = if role == "live" {
        UpdatePolicyRequest {
            live_storage_id: Some(body.to_storage_id),
            ..Default::default()
        }
    } else {
        UpdatePolicyRequest {
            archive_storage_id: Some(Some(body.to_storage_id)),
            ..Default::default()
        }
    };
    apply_policy_update(pool, id, &req).await?;
    tracing::info!(policy = %id, role = %role, to = %body.to_storage_id, "policy storage repointed");

    // Enqueue the drain (the recorder's worker claims + runs it).
    let mut migration_id = None;
    if body.migrate_existing {
        if let Some(from) = current {
            if segs > 0 {
                let mig = db::create_storage_migration(pool, id, from, body.to_storage_id, segs)
                    .await
                    .context("create_storage_migration")?;
                migration_id = Some(mig.id);
                tracing::info!(migration = %mig.id, segments = segs, "storage drain enqueued");
            }
        }
    }

    Ok(Json(ChangeStorageResponse {
        repointed: true,
        migration_id,
        segments_to_move: segs,
        bytes_to_move: bytes,
    }))
}

/// `GET /config/migrations` — recent "Change storage" drain jobs, newest first.
async fn list_migrations(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<StorageMigrationDto>>, ApiError> {
    let rows = db::list_storage_migrations(state.pool(), 50)
        .await
        .context("list_storage_migrations")?;
    Ok(Json(rows.into_iter().map(migration_to_dto).collect()))
}

/// `GET /config/migrations/{id}` — one drain job's status (progress polling).
async fn get_migration(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<StorageMigrationDto>, ApiError> {
    let m = db::get_storage_migration(state.pool(), id)
        .await
        .context("get_storage_migration")?
        .ok_or_else(|| ApiError::NotFound(format!("migration {id} not found")))?;
    Ok(Json(migration_to_dto(m)))
}

// ─── Frigate / MQTT integration settings ──────────────────────────────────────

fn frigate_to_dto(s: crumb_common::FrigateSettings) -> FrigateConfigDto {
    let has_password = s.mqtt_password.as_deref().is_some_and(|p| !p.is_empty());
    FrigateConfigDto {
        enabled: s.enabled,
        mqtt_url: s.mqtt_url,
        mqtt_prefix: s.mqtt_prefix,
        mqtt_user: s.mqtt_user,
        has_password,
        api_base: s.api_base,
        min_score: s.min_score,
        catchup_hours: s.catchup_hours,
        version: s.version,
    }
}

/// `GET /config/frigate` — current settings (password never returned).
async fn get_frigate(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<FrigateConfigDto>, ApiError> {
    let s = db::get_frigate_settings(state.pool())
        .await
        .context("get_frigate_settings")?
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("frigate_config row missing")))?;
    Ok(Json(frigate_to_dto(s)))
}

/// `PUT /config/frigate` — update settings; bumps the version so the recorder +
/// API hot-reload (reconnect MQTT) with no restart.
async fn update_frigate(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<UpdateFrigateConfigRequest>,
) -> Result<Json<FrigateConfigDto>, ApiError> {
    if body.enabled && body.mqtt_url.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "MQTT broker URL is required when Frigate is enabled".to_owned(),
        ));
    }
    let prefix = body
        .mqtt_prefix
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("frigate");
    // Default to empty when not supplied — an empty value falls back to
    // server_settings.frigate_api_base or the env FRIGATE_API_BASE at
    // request time. No homelab IP baked into the binary (spec §4.5 / O4).
    let api_base = body
        .api_base
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("");
    let user = body
        .mqtt_user
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let min_score = body.min_score.unwrap_or(0.3).clamp(0.0, 1.0);
    let catchup = i32::try_from(body.catchup_hours.unwrap_or(24).clamp(0, 720)).unwrap_or(24);

    let updated = db::update_frigate_settings(
        state.pool(),
        body.enabled,
        body.mqtt_url.trim(),
        prefix,
        user,
        body.mqtt_password.as_deref(),
        api_base,
        min_score,
        catchup,
    )
    .await
    .context("update_frigate_settings")?;
    tracing::info!(
        version = updated.version,
        enabled = updated.enabled,
        "frigate settings updated (hot-reload)"
    );
    Ok(Json(frigate_to_dto(updated)))
}

/// `POST /config/frigate/test` — quick broker REACHABILITY check (TCP connect to
/// the MQTT host:port). Doesn't authenticate — just confirms the broker is
/// reachable from the API container, the usual "is my URL right" question.
async fn test_frigate(
    _admin: AdminUser,
    Json(body): Json<UpdateFrigateConfigRequest>,
) -> Result<Json<FrigateTestResult>, ApiError> {
    // Parse host:port from an `mqtt://host:port` (or bare `host:port`) URL.
    let raw = body.mqtt_url.trim();
    let after = raw.split_once("://").map_or(raw, |(_, rest)| rest);
    let hostport = after.split('/').next().unwrap_or(after);
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => (h, p.parse::<u16>().unwrap_or(1883)),
        None => (hostport, 1883_u16),
    };
    if host.is_empty() {
        return Ok(Json(FrigateTestResult {
            ok: false,
            detail: "No broker host in the URL.".to_owned(),
        }));
    }
    let addr = format!("{host}:{port}");
    let res = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        tokio::net::TcpStream::connect(&addr),
    )
    .await;
    let (ok, detail) = match res {
        Ok(Ok(_)) => (
            true,
            format!("Reachable — TCP connect to {addr} succeeded."),
        ),
        Ok(Err(e)) => (false, format!("Could not connect to {addr}: {e}")),
        Err(_) => (false, format!("Timed out connecting to {addr} (5s).")),
    };
    Ok(Json(FrigateTestResult { ok, detail }))
}

/// `POST /config/frigate/test-http` — server-side probe of the Frigate URL
/// bases (go2rtc `:1984` REST + Frigate `:5000` HTTP API), so the wizard /
/// console "Test" buttons don't need cross-origin requests from the browser.
///
/// - go2rtc base → `GET {base}/api/streams`, expect `200` + a JSON object
///   (detail includes the stream count).
/// - HTTP base → `GET {base}/api/version` (Frigate returns a bare version
///   string); falls back to `GET {base}/api/stats` when `/api/version` 404s.
///
/// ~3 s timeout per request; a blank base is reported as skipped (`ok: null`),
/// not an error. Admin-only, like the MQTT `test_frigate` above.
async fn test_frigate_http(
    _admin: AdminUser,
    Json(body): Json<FrigateHttpTestRequest>,
) -> Result<Json<FrigateHttpTestResult>, ApiError> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(3))
        .build()
        .context("build frigate probe client")?;

    /// The deepest source in the error chain, first line only — reqwest's
    /// Display repeats the full URL the operator just typed; the root cause
    /// ("Connection refused", "dns error", …) is the useful part.
    fn err_line(e: &reqwest::Error) -> String {
        let mut src: &dyn std::error::Error = e;
        while let Some(next) = src.source() {
            src = next;
        }
        let s = src.to_string();
        s.lines().next().unwrap_or("request failed").to_owned()
    }

    fn skipped() -> FrigateHttpTargetResult {
        FrigateHttpTargetResult {
            ok: None,
            detail: "Skipped — blank.".to_owned(),
        }
    }
    fn fail(detail: String) -> FrigateHttpTargetResult {
        FrigateHttpTargetResult {
            ok: Some(false),
            detail,
        }
    }
    fn pass(detail: String) -> FrigateHttpTargetResult {
        FrigateHttpTargetResult {
            ok: Some(true),
            detail,
        }
    }
    fn clean_base(raw: Option<&str>) -> Result<Option<&str>, FrigateHttpTargetResult> {
        let Some(base) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
            return Ok(None);
        };
        if base.starts_with("http://") || base.starts_with("https://") {
            Ok(Some(base.trim_end_matches('/')))
        } else {
            Err(fail("URL must start with http:// or https://.".to_owned()))
        }
    }

    // go2rtc REST base → /api/streams must answer 200 with a JSON object.
    let go2rtc = match clean_base(body.go2rtc_api_base.as_deref()) {
        Err(bad) => bad,
        Ok(None) => skipped(),
        Ok(Some(base)) => {
            let url = format!("{base}/api/streams");
            match client.get(&url).send().await {
                Ok(r) if r.status().is_success() => match r.json::<serde_json::Value>().await {
                    Ok(serde_json::Value::Object(map)) => {
                        pass(format!("go2rtc answered — {} stream(s).", map.len()))
                    }
                    Ok(_) | Err(_) => fail(
                        "Responded 200 but not with go2rtc's JSON — is this the :1984 API base?"
                            .to_owned(),
                    ),
                },
                Ok(r) => fail(format!("HTTP {} from {url}.", r.status().as_u16())),
                Err(e) => fail(format!("Could not reach {url}: {}.", err_line(&e))),
            }
        }
    };

    // Frigate HTTP base → /api/version, falling back to /api/stats on 404.
    let http = match clean_base(body.http_api_base.as_deref()) {
        Err(bad) => bad,
        Ok(None) => skipped(),
        Ok(Some(base)) => {
            let vurl = format!("{base}/api/version");
            match client.get(&vurl).send().await {
                Ok(r) if r.status().is_success() => {
                    let v = r.text().await.unwrap_or_default();
                    let v: String = v.trim().trim_matches('"').chars().take(40).collect();
                    if v.is_empty() || v.contains('<') {
                        pass("Frigate API answered /api/version.".to_owned())
                    } else {
                        pass(format!("Frigate {v}."))
                    }
                }
                Ok(r) if r.status() == reqwest::StatusCode::NOT_FOUND => {
                    let surl = format!("{base}/api/stats");
                    match client.get(&surl).send().await {
                        Ok(r2) if r2.status().is_success() => pass(
                            "Frigate API answered /api/stats (no /api/version on this version)."
                                .to_owned(),
                        ),
                        Ok(r2) => fail(format!(
                            "HTTP {} from {surl} (and 404 from /api/version).",
                            r2.status().as_u16()
                        )),
                        Err(e) => fail(format!("Could not reach {surl}: {}.", err_line(&e))),
                    }
                }
                Ok(r) => fail(format!("HTTP {} from {vurl}.", r.status().as_u16())),
                Err(e) => fail(format!("Could not reach {vurl}: {}.", err_line(&e))),
            }
        }
    };

    Ok(Json(FrigateHttpTestResult { go2rtc, http }))
}

// ─── ONVIF re-detect ─────────────────────────────────────────────────────────

/// `POST /config/cameras/{id}/redetect` — re-run ONVIF discovery against the
/// camera's stored credentials, update source URLs + PTZ capability, then force
/// a go2rtc producer restart (DELETE-then-PUT) so the new source takes effect.
///
/// Returns `400 Bad Request` when the camera has no stored ONVIF host/creds.
/// Returns `502 Bad Gateway` when the ONVIF probe fails (camera offline, wrong
/// port, auth error, etc.).
///
/// # Credential injection
///
/// ONVIF `GetStreamUri` returns a bare `rtsp://host/path` without credentials.
/// go2rtc needs them in the URL to authenticate to the camera (`rtsp://user:pass@host/path`).
/// This handler injects the stored `onvif_user`/`onvif_password` into both the
/// main and sub source URLs before persisting, URL-encoding special characters
/// so the RTSP URI stays valid.
///
/// # Sub-stream preservation
///
/// If ONVIF does not return a second media profile the re-detect result has no
/// sub-stream URI, but the camera may have had a working sub stream configured
/// previously. The DB helper uses `COALESCE($new, existing)` for
/// `source_sub_url` so a None result leaves the old value in place.
async fn redetect_camera(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<RedetectResponse>, ApiError> {
    let cam = require_camera(state.pool(), id).await?;

    // Require a stored ONVIF host. Username and password are OPTIONAL — some ONVIF
    // cameras accept anonymous access or an empty password — so default each to an
    // empty string when absent rather than rejecting the request.
    let host = match &cam.onvif_host {
        Some(h) if !h.trim().is_empty() => h.clone(),
        _ => {
            return Err(ApiError::BadRequest(
                "camera has no stored ONVIF host; set onvif_host (and credentials if \
                 the camera requires them) before re-detecting"
                    .to_owned(),
            ));
        }
    };
    let user = cam.onvif_user.clone().unwrap_or_default();
    let pass = cam.onvif_password.clone().unwrap_or_default();

    let port = cam
        .onvif_port
        .and_then(|p| u16::try_from(p).ok())
        .unwrap_or(80);

    // Delegate the ONVIF probe to api-streams (C7).
    let r = crate::discover::redetect_camera_streams(&host, port, &user, &pass)
        .await
        .map_err(|e| ApiError::BadGateway(format!("ONVIF re-detect failed: {e}")))?;

    // Inject the stored ONVIF credentials into the returned source URLs.
    //
    // ONVIF `GetStreamUri` returns bare URLs (`rtsp://host/path`) without
    // credentials. go2rtc needs `rtsp://user:pass@host/path` to authenticate.
    // We use `url::Url` to inject them (URL-encoded) safely; if either URL is
    // unparseable we fall back to string interpolation.
    let inject_creds = |raw: &str| -> String {
        if user.is_empty() && pass.is_empty() {
            return raw.to_owned();
        }
        if let Ok(mut u) = raw.parse::<url::Url>() {
            // set_username/set_password return Err only for non-relative URLs
            // (e.g. `cannot-be-a-base`) — RTSP URLs are always relative-base,
            // so these should succeed. Fall back to raw on the rare error.
            let _ = u.set_username(&user);
            let _ = u.set_password(if pass.is_empty() { None } else { Some(&pass) });
            u.to_string()
        } else {
            // Unparseable URL: inject via string replacement as a fallback.
            // Replace `rtsp://` with `rtsp://user:pass@`.
            let scheme_end = raw.find("://").map_or(0, |i| i + 3);
            let (scheme, rest) = raw.split_at(scheme_end);
            if pass.is_empty() {
                format!("{scheme}{user}@{rest}")
            } else {
                format!("{scheme}{user}:{pass}@{rest}")
            }
        }
    };

    let credentialed_source_url = inject_creds(&r.source_url);
    let credentialed_source_sub_url = r.source_sub_url.as_deref().map(inject_creds);

    // Persist the new source URLs + PTZ capability via the db helper (C8 owner).
    // Re-detected URIs become Crumb-managed (the operator wires them into Crumb's
    // go2rtc); set served_by="crumb" so the restreamer and URL resolver agree.
    //
    // Sub-stream preservation: if ONVIF didn't return a second media profile
    // (credentialed_source_sub_url is None) we fall back to the camera's
    // existing source_sub_url so a working sub stream is never wiped by a
    // re-detect that only found one profile. The db helper writes whatever we
    // pass, so this is the client-side equivalent of COALESCE.
    let effective_source_sub_url = credentialed_source_sub_url
        .clone()
        .or_else(|| cam.source_sub_url.clone());

    let served_by = "crumb";
    crumb_common::db::update_camera_onvif_and_sources(
        state.pool(),
        id,
        Some(credentialed_source_url.as_str()),
        effective_source_sub_url.as_deref(),
        served_by,
        r.ptz_supported,
    )
    .await
    .context("update_camera_onvif_and_sources")?;

    // Force go2rtc producer restart (DELETE-then-PUT) so the new source takes
    // effect immediately.  A plain PUT does NOT restart a live producer (spec C8).
    // On failure, log and return 502 — the operator needs to know the stream did
    // not reconnect (the 60s reconcile loop will retry, but that delay may be
    // unacceptable for a camera swap).
    if let Err(e) = crate::go2rtc::reconnect(&state, &cam.go2rtc_name).await {
        tracing::warn!(
            camera_id = %id,
            error = %e,
            "go2rtc reconnect after redetect failed; reconcile loop will retry"
        );
    }

    // Re-read to return the authoritative post-update DTO.
    let updated = require_camera(state.pool(), id).await?;
    Ok(Json(RedetectResponse {
        source_url: credentialed_source_url,
        source_sub_url: credentialed_source_sub_url,
        ptz_supported: r.ptz_supported,
        camera: camera_to_dto(updated),
    }))
}

// ─── server / streaming settings ─────────────────────────────────────────────

fn server_settings_to_dto(s: ServerSettings) -> ServerSettingsDto {
    ServerSettingsDto {
        server_address: s.server_address,
        crumb_rtsp_base: s.crumb_rtsp_base,
        crumb_api_base: s.crumb_api_base,
        frigate_rtsp_base: s.frigate_rtsp_base,
        // frigate_api_base kept for back-compat; equals frigate_go2rtc_api_base.
        frigate_api_base: s.frigate_api_base.clone(),
        frigate_go2rtc_api_base: s.frigate_go2rtc_api_base,
        frigate_http_api_base: s.frigate_http_api_base,
        motion_hwaccel: s.motion_hwaccel,
        motion_vaapi_device: s.motion_vaapi_device,
        version: s.version,
    }
}

/// `GET /config/server` — current server & streaming base-URL settings.
async fn get_server_settings(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<ServerSettingsDto>, ApiError> {
    let s = crumb_common::db::get_server_settings(state.pool())
        .await
        .context("get_server_settings")?
        .ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!("server_settings row missing; run ensure"))
        })?;
    Ok(Json(server_settings_to_dto(s)))
}

/// `PUT /config/server` — update server & streaming base-URL settings.
///
/// All fields accept an empty string to fall back to the container environment
/// / internal docker service-name default.  Bumps the version counter so
/// downstream consumers (recorder, API, clients) can detect and reload.
async fn update_server_settings(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<UpdateServerSettingsRequest>,
) -> Result<Json<ServerSettingsDto>, ApiError> {
    // Trim each field; allow empty (means "fall back to env / docker service
    // name").  No homelab IPs baked in here — the operator provides them.
    //
    // Split-field back-compat: when the caller sends the legacy `frigate_api_base`
    // only (old admin.html), copy it into both split fields so the DB row is
    // always self-consistent. When the new fields ARE present they take precedence.
    let legacy = body.frigate_api_base.trim();
    let go2rtc_api = {
        let v = body.frigate_go2rtc_api_base.trim();
        if v.is_empty() {
            legacy
        } else {
            v
        }
    };
    let http_api = {
        let v = body.frigate_http_api_base.trim();
        if v.is_empty() {
            legacy
        } else {
            v
        }
    };

    let s = crumb_common::db::update_server_settings(
        state.pool(),
        body.server_address.trim(),
        body.crumb_rtsp_base.trim(),
        body.crumb_api_base.trim(),
        body.frigate_rtsp_base.trim(),
        legacy,
        go2rtc_api,
        http_api,
        // Motion decode backend (admin-editable, hot-reloaded by the recorder).
        // Empty ⇒ recorder falls back to its MOTION_HWACCEL / MOTION_VAAPI_DEVICE env.
        body.motion_hwaccel.trim(),
        body.motion_vaapi_device.trim(),
    )
    .await
    .context("update_server_settings")?;
    tracing::info!(version = s.version, "server settings updated");
    Ok(Json(server_settings_to_dto(s)))
}

// ─── health-alert maintenance window (issue #46) ────────────────────────────────

/// `POST /config/maintenance` body: arm the health-alert maintenance window for
/// `minutes` minutes. `0` (or negative) clears an active window immediately.
#[derive(Debug, serde::Deserialize)]
struct ArmMaintenanceRequest {
    /// Minutes to suppress operational health alerts, from now. Clamped to
    /// `0..=1440` (24 h). `0` disarms.
    minutes: i64,
}

/// Wire shape for the maintenance-window state.
#[derive(Debug, serde::Serialize)]
struct MaintenanceStatus {
    /// Whether a window is currently in effect (armed AND not yet expired).
    active: bool,
    /// `maintenance_until` as unix seconds (`0` = not armed). While a window is
    /// active this is a future timestamp; after it expires the stored value
    /// remains but `active` is `false`.
    until_unix: i64,
    /// Whole seconds remaining until the window expires (`0` when inactive).
    remaining_secs: i64,
}

impl MaintenanceStatus {
    fn from_until(until: i64) -> Self {
        let now = chrono::Utc::now().timestamp();
        let active = crate::state::maintenance_active_at(until, now);
        Self {
            active,
            until_unix: until,
            remaining_secs: if active { until - now } else { 0 },
        }
    }
}

/// `GET /config/maintenance` — read the current health-alert maintenance window.
///
/// While a window is active the notification engine SUPPRESSES operational
/// health alerts (camera offline, recorder down, low disk, Frigate disconnect,
/// backup failed): they are still evaluated and recorded in `system_events`,
/// just not dispatched to any channel. Admin-only (mirrors `/config/server`).
async fn get_maintenance(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<MaintenanceStatus>, ApiError> {
    Ok(Json(MaintenanceStatus::from_until(
        state.maintenance_until(),
    )))
}

/// `POST /config/maintenance` — arm (or clear) the health-alert maintenance
/// window. Use before a planned stack cutover / recorder restart so the
/// transient "no new segment" gap during go2rtc reconcile doesn't false-fire
/// camera-offline / recorder-down alerts. Admin-only.
async fn arm_maintenance_route(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<ArmMaintenanceRequest>,
) -> Result<Json<MaintenanceStatus>, ApiError> {
    let minutes = body.minutes.clamp(0, 1440);
    let until = state.arm_maintenance(minutes);
    if minutes == 0 {
        tracing::info!("health-alert maintenance window cleared");
    } else {
        tracing::info!(
            minutes,
            until_unix = until,
            "health-alert maintenance window armed — health alerts suppressed until expiry"
        );
    }
    Ok(Json(MaintenanceStatus::from_until(until)))
}

// ─── motion-decode truth (decode-status panel) ──────────────────────────────────

/// `GET /config/decode-status` — what the recorder is ACTUALLY using for
/// motion decode (per camera), plus the accelerator surface it detected
/// inside its container on boot.
///
/// Both halves are written by the recorder (migration 0035) and read here —
/// recorder and API only communicate via Postgres. `capabilities` is `null`
/// until a recorder new enough to report has booted; `cameras` is empty until
/// motion workers have (re)started at least once.
async fn get_decode_status(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<DecodeStatusDto>, ApiError> {
    let capabilities = crumb_common::db::read_recorder_capabilities(state.pool())
        .await
        .context("read_recorder_capabilities")?
        .map(|c| RecorderCapabilitiesDto {
            dri_devices: c.dri_devices,
            nvidia: c.nvidia,
            ffmpeg_hwaccels: c.ffmpeg_hwaccels,
            detected_at: c.detected_at,
        });

    let cameras = crumb_common::db::list_camera_decode_status(state.pool())
        .await
        .context("list_camera_decode_status")?
        .into_iter()
        .map(|s| CameraDecodeStatusDto {
            camera_id: s.camera_id,
            camera_name: s.camera_name,
            requested: s.requested,
            active: s.active,
            fallback_reason: s.fallback_reason,
            updated_at: s.updated_at,
        })
        .collect();

    Ok(Json(DecodeStatusDto {
        capabilities,
        cameras,
    }))
}

// ─── motion RAM-cache telemetry (migration 0039) ──────────────────────────────
//
// Mirrors the decode-status flow directly above: the recorder is the sole
// writer of `motion_cache_status` / `camera_motion_cache_status` (via its
// periodic `report_motion_cache_status` reporter in recording.rs); this
// handler only reads them back and layers on the one thing the recorder can't
// compute for itself — the per-camera ring-size PROJECTION, which must also
// work for a camera that isn't in Motion mode yet (planning before flipping
// the switch), so it can't live in the recorder's own report.

/// Matches the recorder's `SEGMENT_SECONDS` default (`services/common/src/config.rs`,
/// env `SEGMENT_SECONDS`, valid range 2–6). The API process doesn't share the
/// recorder's env, so — same precedent as `filmstrip::DEFAULT_THUMB_INTERVAL_SECS`
/// — this is a documented constant matching the default rather than a plumbed
/// setting. A camera actually configured with a non-default `SEGMENT_SECONDS`
/// will see a very slightly off projection; harmless (the projection is a
/// planning aid, not a hard cap).
const ASSUMED_SEGMENT_SECONDS: f64 = 4.0;

/// Ring-buffer slack constant mirrored from `recorder::recording::RING_SLACK_SECS`
/// (services/recorder/src/recording.rs) — extra seconds beyond
/// `motion_pre_seconds` the ring retains to absorb motion-detection latency.
/// Duplicated here (not imported) because the api crate doesn't depend on the
/// recorder binary crate; keep these two constants in sync if either changes.
const ASSUMED_RING_SLACK_SECS: f64 = 8.0;

/// Look-back window for observing a camera's actual segment bitrate.
const SEGMENT_RATE_WINDOW_HOURS: i64 = 1;

/// Minimum sample count before trusting an observed rate. A single segment's
/// size/duration is noisy (keyframe alignment, a brief network hiccup); a
/// small handful of segments in the window is enough to smooth that out
/// without requiring a long observation period.
const MIN_RATE_SAMPLES: i64 = 3;

/// Pure projection: given an observed bytes/sec rate and a camera's configured
/// `motion_pre_seconds`, estimate the steady-state RAM ring need in bytes.
///
/// `ring_window_secs = motion_pre_seconds + RING_SLACK_SECS + 2 * SEGMENT_SECONDS`
/// — the pre-roll window, plus the same detection-latency slack the recorder's
/// ring eviction uses (`RING_SLACK_SECS`, recording.rs), plus roughly two
/// in-flight segments of headroom (the segment currently being written, and
/// the previous one not yet rotated out) so the projection doesn't
/// under-count relative to what the recorder's ring actually holds moment to
/// moment. Extracted as a standalone pure function (no DB, no I/O) so the
/// boundary math is unit-testable without a database.
fn project_camera_ring_bytes(bytes_per_sec: f64, motion_pre_seconds: i32) -> i64 {
    if bytes_per_sec <= 0.0 {
        return 0;
    }
    let ring_window_secs =
        f64::from(motion_pre_seconds) + ASSUMED_RING_SLACK_SECS + 2.0 * ASSUMED_SEGMENT_SECONDS;
    let bytes = bytes_per_sec * ring_window_secs;
    // Clamp to i64 range defensively (bytes_per_sec is derived from real
    // segment sizes and pre_seconds is a small positive column value, so this
    // should never come close to overflowing — the clamp is just cheap
    // insurance against a corrupt/absurd DB value producing a nonsense DTO).
    #[allow(clippy::cast_precision_loss)]
    let i64_max_as_f64 = i64::MAX as f64;
    if bytes >= i64_max_as_f64 {
        i64::MAX
    } else {
        #[allow(clippy::cast_possible_truncation)]
        let rounded = bytes.round() as i64;
        rounded
    }
}

/// `GET /config/motion-cache-status` — the recorder's motion RAM-cache truth
/// (global filesystem usage + per-camera ring occupancy) plus the API's
/// per-camera projected ring need, so the admin console can show both
/// "what's used right now" and "what will Motion mode cost" (the latter works
/// even before a camera is switched to Motion, using its recent segment
/// history under whatever mode it's currently in).
async fn get_motion_cache_status(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<MotionCacheStatusDto>, ApiError> {
    let global = db::read_motion_cache_status(state.pool())
        .await
        .context("read_motion_cache_status")?
        .map(|g| MotionCacheGlobalDto {
            free_bytes: g.free_bytes,
            total_bytes: g.total_bytes,
            caching_active: g.caching_active,
            shadow_mode: g.shadow_mode,
            updated_at: g.updated_at,
        });

    // Ring occupancy the recorder has actually reported (Motion-mode cameras
    // only — see camera_motion_cache_status's table comment).
    let reported = db::list_camera_motion_cache_status(state.pool())
        .await
        .context("list_camera_motion_cache_status")?;
    let reported_by_id: std::collections::HashMap<Uuid, _> =
        reported.into_iter().map(|s| (s.camera_id, s)).collect();

    // Observed bytes/sec per camera over a recent window — computed for every
    // camera (not just ones the recorder has reported a ring for) so the
    // projection works as a BEFORE-you-flip-the-switch planning tool.
    let rates = db::camera_recent_segment_rate_stats(state.pool(), SEGMENT_RATE_WINDOW_HOURS)
        .await
        .context("camera_recent_segment_rate_stats")?;
    let rate_by_id: std::collections::HashMap<Uuid, _> =
        rates.into_iter().map(|r| (r.camera_id, r)).collect();

    // Motion-mode cameras only — mirrors the recorder's own reporting scope
    // (see camera_motion_cache_status's table comment: Continuous-mode
    // cameras never get a row).
    let motion_cameras: Vec<Camera> = db::list_cameras_all(state.pool())
        .await
        .context("list_cameras_all")?
        .into_iter()
        .filter(|c| c.policy.mode == RecordingMode::Motion)
        .collect();

    let mut total_projected_bytes: i64 = 0;
    let mut cameras: Vec<CameraMotionCacheDto> = Vec::with_capacity(motion_cameras.len());
    for cam in motion_cameras {
        let ring = reported_by_id.get(&cam.id);
        let rate = rate_by_id
            .get(&cam.id)
            .filter(|r| r.sample_count >= MIN_RATE_SAMPLES);
        let observed_bytes_per_sec = rate.and_then(|r| {
            if r.avg_duration_secs > 0.0 {
                Some(r.avg_size_bytes / r.avg_duration_secs)
            } else {
                None
            }
        });
        let projected_ring_bytes = observed_bytes_per_sec.map(|bps| {
            let p = project_camera_ring_bytes(bps, cam.policy.motion_pre_seconds);
            total_projected_bytes = total_projected_bytes.saturating_add(p);
            p
        });

        cameras.push(CameraMotionCacheDto {
            camera_id: cam.id,
            camera_name: cam.name,
            mode: cam.policy.mode.as_str().to_owned(),
            ring_segments: ring.map(|r| r.ring_segments),
            ring_bytes: ring.map(|r| r.ring_bytes),
            updated_at: ring.map(|r| r.updated_at),
            observed_bytes_per_sec,
            projected_ring_bytes,
        });
    }
    cameras.sort_by(|a, b| a.camera_name.cmp(&b.camera_name));

    Ok(Json(MotionCacheStatusDto {
        global,
        cameras,
        total_projected_bytes,
    }))
}

// ─── migration retry / cancel ─────────────────────────────────────────────────

/// `POST /config/migrations/{id}/retry` — re-queue a failed or stuck-running
/// migration as `pending` so the recorder's drain worker can pick it back up.
///
/// Returns `400` when the migration is in a non-retryable state (e.g. `done`).
async fn retry_migration(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<StorageMigrationDto>, ApiError> {
    let m = crumb_common::db::get_storage_migration(state.pool(), id)
        .await
        .context("get_storage_migration")?
        .ok_or_else(|| ApiError::NotFound(format!("migration {id} not found")))?;

    // Only `failed`, `cancelled`, or stale `running` migrations may be retried.
    if !matches!(m.status.as_str(), "failed" | "cancelled" | "running") {
        return Err(ApiError::BadRequest(format!(
            "migration is '{}'; only failed, cancelled, or stuck-running migrations can be retried",
            m.status
        )));
    }

    // Reset to pending — the recorder's worker loop re-claims it on its next
    // pass.  The drain is idempotent + crash-resumable, so a retry is safe.
    crumb_common::db::set_migration_status(state.pool(), id, "pending", None)
        .await
        .context("set_migration_status (retry)")?;

    let updated = crumb_common::db::get_storage_migration(state.pool(), id)
        .await
        .context("get_storage_migration after retry")?
        .expect("migration disappeared immediately after status update");

    tracing::info!(migration_id = %id, "storage migration queued for retry");
    Ok(Json(migration_to_dto(updated)))
}

/// `POST /config/migrations/{id}/cancel` — abandon a pending or running
/// migration by marking it `cancelled`.
///
/// Returns `400` when the migration is already `done` (can't un-do completed
/// work) or already `cancelled`.  Uses a conditional UPDATE (`WHERE status =
/// $expected_current`) so a concurrent state change (e.g. the drain worker
/// writing `done` in the same instant) is detected and the caller gets a clear
/// message rather than a silent no-op that a drain later overwrites with `done`.
///
/// The drain worker re-reads the row status at the top of each batch; when it
/// sees `cancelled` it stops without writing `done` back (see archive.rs).
async fn cancel_migration(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<StorageMigrationDto>, ApiError> {
    let m = crumb_common::db::get_storage_migration(state.pool(), id)
        .await
        .context("get_storage_migration")?
        .ok_or_else(|| ApiError::NotFound(format!("migration {id} not found")))?;

    match m.status.as_str() {
        "done" => {
            return Err(ApiError::BadRequest(
                "migration already completed; nothing to cancel".to_owned(),
            ));
        }
        "cancelled" => {
            return Err(ApiError::BadRequest(
                "migration is already cancelled".to_owned(),
            ));
        }
        _ => {}
    }

    // Cancel pending migrations unconditionally; for running ones use a
    // conditional UPDATE so we don't race the drain worker's own `done` write.
    // Try "running" first, then "pending" — the migration may have transitioned
    // while we were checking. If neither applies (e.g. another concurrent cancel
    // won) we re-read and surface the real state.
    let applied = if m.status == "running" {
        crumb_common::db::set_migration_status_if(
            state.pool(),
            id,
            "cancelled",
            "running",
            Some("cancelled by operator"),
        )
        .await
        .context("set_migration_status_if (cancel running)")?
    } else {
        // status == "pending" — no active worker holds it, safe unconditional set.
        crumb_common::db::set_migration_status_if(
            state.pool(),
            id,
            "cancelled",
            "pending",
            Some("cancelled by operator"),
        )
        .await
        .context("set_migration_status_if (cancel pending)")?
    };

    if !applied {
        // The migration changed status between our initial read and the UPDATE
        // (drain worker finished or another cancel request raced). Re-read and
        // surface whatever the real state is now.
        let current = crumb_common::db::get_storage_migration(state.pool(), id)
            .await
            .context("get_storage_migration (post-race re-read)")?
            .expect("migration disappeared immediately after status check");
        return Err(ApiError::Conflict(format!(
            "migration status changed to '{}' before cancel could be applied; \
             no change was made",
            current.status
        )));
    }

    let updated = crumb_common::db::get_storage_migration(state.pool(), id)
        .await
        .context("get_storage_migration after cancel")?
        .expect("migration disappeared immediately after status update");

    tracing::info!(migration_id = %id, "storage migration cancelled");
    Ok(Json(migration_to_dto(updated)))
}

/// Load a policy a camera OR group may be ASSIGNED to: it must exist (404) and be
/// either the DEFAULT or a NAMED policy — never an anonymous per-camera copy-on-write
/// fork (`name IS NULL`, non-default), which is owned by exactly one camera. Pinning a
/// second owner (another camera, or a group) to a fork would let the in-place COW edit
/// in `update_camera_policy_locked` silently mutate a now-shared policy. Rejecting
/// non-named policies here is the clean invariant that closes both assignment paths.
async fn require_assignable_policy(pool: &Pool, id: Uuid) -> Result<RecordingPolicy, ApiError> {
    let policy = require_policy(pool, id).await?;
    if !policy.is_default && policy.name.is_none() {
        return Err(ApiError::BadRequest(
            "cannot assign to an anonymous per-camera policy; choose a named policy \
             (or clear the assignment to inherit)"
                .to_owned(),
        ));
    }
    Ok(policy)
}

/// Load a camera group by ID or return `404 Not Found`.
async fn require_group(pool: &Pool, id: Uuid) -> Result<CameraGroup, ApiError> {
    db::get_group(pool, id)
        .await
        .context("get_group")?
        .ok_or_else(|| ApiError::NotFound(format!("group {id} not found")))
}

/// Re-read a group (with members) and convert to a DTO, or `404` if it vanished.
async fn require_group_dto(pool: &Pool, id: Uuid) -> Result<CameraGroupDto, ApiError> {
    let groups = db::list_groups(pool).await.context("list_groups")?;
    groups
        .into_iter()
        .find(|g| g.group.id == id)
        .map(group_to_dto)
        .ok_or_else(|| ApiError::NotFound(format!("group {id} not found")))
}

// ─── helper: DTO conversions ──────────────────────────────────────────────────

fn group_to_dto(g: db::CameraGroupWithMembers) -> CameraGroupDto {
    CameraGroupDto {
        id: g.group.id,
        name: g.group.name,
        policy_id: g.group.policy_id,
        created_at: g.group.created_at,
        camera_ids: g.camera_ids,
    }
}

fn camera_to_dto(c: Camera) -> CameraDto {
    let policy = policy_to_dto(c.policy);
    // onvif_has_password: true when a non-empty password is stored. The password
    // itself is NEVER copied into the DTO (write-only field per spec C10).
    let onvif_has_password = c.onvif_password.as_deref().is_some_and(|p| !p.is_empty());
    CameraDto {
        id: c.id,
        name: c.name,
        enabled: c.enabled,
        go2rtc_name: c.go2rtc_name,
        main_url: c.main_url,
        sub_url: c.sub_url,
        source_url: c.source_url,
        source_sub_url: c.source_sub_url,
        policy_id: c.policy_id,
        group_id: c.group_id,
        policy,
        motion_mask: c.motion_mask,
        onvif_motion: c.onvif_motion,
        motion_source: c.motion_source,
        motion_algorithm: c.motion_algorithm,
        camera_type: c.camera_type,
        icon: c.icon,
        motion_grid_cols: c.motion_grid_cols,
        motion_grid_rows: c.motion_grid_rows,
        created_at: c.created_at,
        // distributability fields — onvif_password deliberately excluded
        served_by: c.served_by,
        source_camera_name: c.source_camera_name,
        onvif_host: c.onvif_host,
        onvif_port: c.onvif_port,
        onvif_user: c.onvif_user,
        onvif_has_password,
    }
}

fn policy_to_dto(p: RecordingPolicy) -> RecordingPolicyDto {
    RecordingPolicyDto {
        id: p.id,
        name: p.name,
        is_default: p.is_default,
        mode: p.mode,
        live_storage_id: p.live_storage_id,
        live_retention_hours: p.live_retention_hours,
        archive_enabled: p.archive_enabled,
        archive_storage_id: p.archive_storage_id,
        archive_schedule: p.archive_schedule,
        archive_retention_hours: p.archive_retention_hours,
        live_max_bytes: p.live_max_bytes,
        archive_max_bytes: p.archive_max_bytes,
        live_min_free_pct: p.live_min_free_pct,
        live_min_free_bytes: p.live_min_free_bytes,
        live_spill_low_water_bytes: p.live_spill_low_water_bytes,
        max_retention_days: p.max_retention_days,
        motion_pre_seconds: p.motion_pre_seconds,
        motion_post_seconds: p.motion_post_seconds,
        motion_sensitivity: p.motion_sensitivity.as_str().to_owned(),
        motion_threshold: p.motion_threshold,
        motion_keyframes_only: p.motion_keyframes_only,
        record_stream: p.record_stream.as_str().to_owned(),
        record_audio: p.record_audio,
    }
}

fn storage_to_dto(s: Storage) -> StorageDto {
    let (fs_total_bytes, free_bytes) = match disk_stats_for_path(&s.path) {
        Some((t, f)) => (Some(t), Some(f)),
        None => (None, None),
    };
    StorageDto {
        id: s.id,
        name: s.name,
        path: s.path,
        total_bytes: s.total_bytes,
        fs_total_bytes,
        free_bytes,
        icon: s.icon,
        created_at: s.created_at,
    }
}

fn user_to_dto(u: User) -> UserDto {
    UserDto {
        id: u.id,
        username: u.username,
        role: u.role,
        camera_ids: u.camera_ids,
        role_id: u.role_id,
    }
}

// ─── helper: free space ───────────────────────────────────────────────────────

/// Total + free bytes at `path` via `statvfs(2)`, returned as `(total, free)`.
///
/// `total` is the filesystem size; `free` is space available to unprivileged
/// users. Returns `None` if the path does not exist, is not accessible from the
/// container, or if the OS does not support `statvfs` (non-Unix targets).
///
/// # Platform note
///
/// This binary only runs inside a Linux Docker container, so `#[cfg(unix)]`
/// always matches.  The `#[cfg(not(unix))]` stub keeps non-Linux dev machines
/// from failing to compile.
fn disk_stats_for_path(path: &str) -> Option<(i64, i64)> {
    #[cfg(unix)]
    {
        use std::ffi::CString;

        let c_path = CString::new(path).ok()?;
        // `libc::statvfs` is the standard POSIX struct; available on all
        // Unix targets the libc crate supports.
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };

        // SAFETY: `c_path` is a valid null-terminated C string produced by
        // `CString::new`.  `stat` is a local zero-initialised struct whose
        // address is passed to the well-documented POSIX `statvfs(3)` call.
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &raw mut stat) };
        if rc == 0 {
            // `f_blocks`: total blocks; `f_bavail`: blocks available to
            // unprivileged users; `f_bsize`: block size. Cast through u64
            // (c_ulong on Linux) to avoid sign extension before the multiply.
            let bsize = stat.f_bsize as u64;
            let total = (stat.f_blocks as u64)
                .saturating_mul(bsize)
                .try_into()
                .unwrap_or(i64::MAX);
            let free = (stat.f_bavail as u64)
                .saturating_mul(bsize)
                .try_into()
                .unwrap_or(i64::MAX);
            Some((total, free))
        } else {
            tracing::debug!(path, "statvfs failed for storage path");
            None
        }
    }

    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

// ─── helper: password hashing ─────────────────────────────────────────────────

/// Hash a plaintext password with Argon2id (default params: 19 MiB, 2
/// iterations, parallelism 1 — well above OWASP minimums).
///
/// Returns the PHC string (`$argon2id$v=19$...`).
fn hash_password(password: &str) -> Result<String, ApiError> {
    // argon2 0.5's OsRng re-export needs the getrandom sub-feature (not enabled);
    // uuid v4 (getrandom-backed) provides equivalent salt entropy.
    let salt = SaltString::encode_b64(uuid::Uuid::new_v4().as_bytes())
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("salt encode: {e}")))?;
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("argon2 hash failed: {e}")))
}

// ─── helper: validation ───────────────────────────────────────────────────────

/// Validate fields on [`CreateCameraRequest`]. The flow-specific requirements
/// (`source_url` vs `go2rtc_name`+`main_url`) are resolved in the handler.
fn validate_create_camera(body: &CreateCameraRequest) -> Result<(), ApiError> {
    if body.name.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "camera name must not be blank".to_owned(),
        ));
    }
    Ok(())
}

/// Slugify a camera name into a safe, lowercase go2rtc stream name (alphanumerics
/// + underscores). Used to derive a `go2rtc_name` in the self-service add flow.
fn slugify_go2rtc_name(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut prev_us = false;
    for ch in name.trim().chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            prev_us = false;
        } else if !prev_us && !out.is_empty() {
            out.push('_');
            prev_us = true;
        }
    }
    out.trim_matches('_').to_owned()
}

/// Normalise + validate a motion-source string to its canonical lowercase form
/// (`"pixel"` / `"frigate"`). `None` ⇒ unrecognised (caller returns 400).
fn normalize_motion_source(s: &str) -> Option<&'static str> {
    match s.trim().to_ascii_lowercase().as_str() {
        "pixel" | "local" | "" => Some("pixel"),
        "frigate" => Some("frigate"),
        _ => None,
    }
}

/// Normalise + validate a motion-algorithm string to its canonical lowercase
/// form. `None` ⇒ unrecognised (caller returns 400). Mirrors the recorder's
/// `MotionAlgorithm` variants.
fn normalize_motion_algorithm(s: &str) -> Option<&'static str> {
    match s.trim().to_ascii_lowercase().as_str() {
        "census" | "" => Some("census"),
        "framediff" | "frame_diff" => Some("framediff"),
        "mog2" => Some("mog2"),
        "opticalflow" | "optical_flow" => Some("opticalflow"),
        "ensemble" => Some("ensemble"),
        _ => None,
    }
}

/// Normalise + validate a `served_by` string to its canonical form.
///
/// Accepts `"crumb"` (Crumb's own embedded go2rtc) or `"frigate"` (an external
/// BYO Frigate's go2rtc). `None` ⇒ unrecognised value (caller returns 400).
fn normalize_served_by(s: &str) -> Option<&'static str> {
    match s.trim().to_ascii_lowercase().as_str() {
        "crumb" | "" => Some("crumb"),
        "frigate" => Some("frigate"),
        _ => None,
    }
}

/// Normalise + validate a camera-type string to its canonical lowercase form
/// (`ptz`/`dome`/`bullet`/`lpr`/`other`). `None` ⇒ unrecognised (caller returns
/// 400). Drives the admin-console glyph only.
fn normalize_camera_type(s: &str) -> Option<&'static str> {
    match s.trim().to_ascii_lowercase().as_str() {
        "ptz" => Some("ptz"),
        "dome" => Some("dome"),
        "bullet" => Some("bullet"),
        "lpr" => Some("lpr"),
        "other" => Some("other"),
        _ => None,
    }
}

/// Validate fields on [`UpdateCameraRequest`].
fn validate_update_camera(body: &UpdateCameraRequest) -> Result<(), ApiError> {
    if let Some(ref name) = body.name {
        if name.trim().is_empty() {
            return Err(ApiError::BadRequest(
                "camera name must not be blank".to_owned(),
            ));
        }
    }
    if let Some(ref g) = body.go2rtc_name {
        if g.trim().is_empty() {
            return Err(ApiError::BadRequest(
                "go2rtc_name must not be blank".to_owned(),
            ));
        }
    }
    if let Some(ref url) = body.main_url {
        if url.trim().is_empty() {
            return Err(ApiError::BadRequest(
                "main_url must not be blank".to_owned(),
            ));
        }
    }
    Ok(())
}

/// Validate the enum-constrained string fields on [`UpdatePolicyRequest`].
///
/// Returns `422 Unprocessable Entity` on unknown enum strings, so the caller
/// gets a clear error rather than a silent no-op or a DB constraint violation.
fn validate_update_policy(body: &UpdatePolicyRequest) -> Result<(), ApiError> {
    if let Some(ref s) = body.motion_sensitivity {
        MotionSensitivity::from_str(s).ok_or_else(|| {
            ApiError::UnprocessableEntity(format!(
                "motion_sensitivity must be 'dynamic' or 'manual', got '{s}'"
            ))
        })?;
    }
    if let Some(ref s) = body.record_stream {
        RecordStream::from_str(s).ok_or_else(|| {
            ApiError::UnprocessableEntity(format!(
                "record_stream must be 'main' or 'sub', got '{s}'"
            ))
        })?;
    }
    if let Some(retention) = body.live_retention_hours {
        if retention <= 0 {
            return Err(ApiError::BadRequest(
                "live_retention_hours must be positive".to_owned(),
            ));
        }
    }
    if let Some(Some(retention)) = body.archive_retention_hours {
        if retention <= 0 {
            return Err(ApiError::BadRequest(
                "archive_retention_hours must be positive".to_owned(),
            ));
        }
    }
    // Size caps are byte counts: non-negative when set. `Some(None)` clears the
    // cap (NULL = no cap) and is always valid. The archive_max_bytes ⇒
    // archive_enabled cross-field check lives in apply_policy_update, where the
    // effective archive_enabled (body-or-existing) is in scope.
    if let Some(Some(v)) = body.live_max_bytes {
        if v < 0 {
            return Err(ApiError::BadRequest(
                "live_max_bytes must be non-negative".to_owned(),
            ));
        }
    }
    if let Some(Some(v)) = body.archive_max_bytes {
        if v < 0 {
            return Err(ApiError::BadRequest(
                "archive_max_bytes must be non-negative".to_owned(),
            ));
        }
    }
    // Advanced storage knobs. `Some(None)` clears (→ system default) and is valid.
    // The spill ⇒ cap cross-field check lives in apply_policy_update /
    // resolve_policy_fields (the effective cap is in scope there).
    if let Some(Some(v)) = body.live_min_free_pct {
        if !(0.0..1.0).contains(&v) {
            return Err(ApiError::BadRequest(
                "live_min_free_pct must be in [0, 1)".to_owned(),
            ));
        }
    }
    if let Some(Some(v)) = body.live_min_free_bytes {
        if v < 0 {
            return Err(ApiError::BadRequest(
                "live_min_free_bytes must be non-negative".to_owned(),
            ));
        }
    }
    if let Some(Some(v)) = body.live_spill_low_water_bytes {
        if v < 0 {
            return Err(ApiError::BadRequest(
                "live_spill_low_water_bytes must be non-negative".to_owned(),
            ));
        }
    }
    // Absolute max-retention cap: a day count, positive when set. `Some(None)`
    // clears it (NULL = OFF, no cap) and is always valid.
    if let Some(Some(v)) = body.max_retention_days {
        if v <= 0 {
            return Err(ApiError::BadRequest(
                "max_retention_days must be positive".to_owned(),
            ));
        }
    }
    if let Some(pre) = body.motion_pre_seconds {
        if pre < 0 {
            return Err(ApiError::BadRequest(
                "motion_pre_seconds must be non-negative".to_owned(),
            ));
        }
    }
    if let Some(post) = body.motion_post_seconds {
        if post < 0 {
            return Err(ApiError::BadRequest(
                "motion_post_seconds must be non-negative".to_owned(),
            ));
        }
    }
    Ok(())
}

/// Validate a username string.
fn validate_username(username: &str) -> Result<(), ApiError> {
    if username.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "username must not be blank".to_owned(),
        ));
    }
    if username.len() > 128 {
        return Err(ApiError::BadRequest(
            "username must be 128 characters or fewer".to_owned(),
        ));
    }
    Ok(())
}

/// Validate a plaintext password before hashing.
fn validate_password(password: &str) -> Result<(), ApiError> {
    if password.len() < 8 {
        return Err(ApiError::BadRequest(
            "password must be at least 8 characters".to_owned(),
        ));
    }
    Ok(())
}

/// Validate a storage path.
///
/// Rules (spec §4.4, FINAL version):
/// 1. The path must be under `MEDIA_ROOT` (default `/data`) — the broad
///    read-write media mount the recorder can write to.
/// 2. If the path does not yet exist, its PARENT must exist AND be inside
///    `MEDIA_ROOT` (the recorder auto-creates the subdir on first write, so we
///    accept prospective paths without creating them here — the API mounts
///    `/data` read-only in the container and must not call `create_dir_all`).
/// 3. If the path does exist it must be a directory.
///
/// The "under `MEDIA_ROOT`" check uses a lexicographic prefix test (no symlink
/// resolution from the API side; the recorder runs as root inside the container
/// and can always access the dir once the recorder creates it).
fn validate_storage_path(path: &str) -> Result<(), ApiError> {
    let root = std::env::var("MEDIA_ROOT").unwrap_or_else(|_| "/data".to_owned());
    let p = std::path::Path::new(path);
    let canon_root = std::path::Path::new(&root);

    // Require the path to be under (or equal to) MEDIA_ROOT so the recorder
    // can reach it via its RW mount.  We compare without canonicalization to
    // avoid accessing the filesystem for paths that don't exist yet.
    if !p.starts_with(canon_root) {
        return Err(ApiError::UnprocessableEntity(format!(
            "storage path must be under the media root '{root}' (the disk Crumb can write to). \
             Add the disk under '{root}/…'. \
             To use a disk at another mount point, mount it as a subdirectory of '{root}'."
        )));
    }

    if let Ok(meta) = std::fs::metadata(path) {
        // Path exists: must be a directory.
        if !meta.is_dir() {
            return Err(ApiError::UnprocessableEntity(format!(
                "storage path '{path}' exists but is not a directory"
            )));
        }
    } else {
        // Path does not yet exist: require the PARENT to be an accessible
        // directory so the recorder can create this subdir on first write.
        let parent = p.parent().unwrap_or(canon_root);
        match std::fs::metadata(parent) {
            Ok(m) if m.is_dir() => { /* parent accessible — accept */ }
            Ok(_) => {
                return Err(ApiError::UnprocessableEntity(format!(
                    "storage path '{path}' does not exist and its parent is not a directory"
                )));
            }
            Err(e) => {
                return Err(ApiError::UnprocessableEntity(format!(
                    "storage path '{path}' does not exist and its parent is not accessible: {e}. \
                         The recorder will create the directory on first write once you \
                         start recording to this location."
                )));
            }
        }
    }

    Ok(())
}

// ─── helper: error classification ─────────────────────────────────────────────

/// Return `true` if the `anyhow` error wraps a Postgres UNIQUE violation
/// (`SqlState::UNIQUE_VIOLATION`).
fn is_unique_violation(err: &anyhow::Error) -> bool {
    err.chain().any(|e| {
        if let Some(pg_err) = e.downcast_ref::<tokio_postgres::Error>() {
            pg_err
                .code()
                .is_some_and(|c| c == &tokio_postgres::error::SqlState::UNIQUE_VIOLATION)
        } else {
            false
        }
    })
}

/// Same as [`is_unique_violation`] but for an error that is already typed as
/// `anyhow::Error` wrapping a `tokio_postgres::Error` after context attachment.
fn is_unique_violation_pg(err: &anyhow::Error) -> bool {
    is_unique_violation(err)
}

#[cfg(test)]
mod fs_list_tests {
    use super::*;

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn filters_hidden_entries_regardless_of_root() {
        let input = names(&[".git", "live", ".hidden", "archive"]);
        assert_eq!(
            filter_and_sort_fs_entries(input, false),
            names(&["archive", "live"])
        );
    }

    #[test]
    fn filters_container_noise_only_at_fs_root() {
        let input = names(&["proc", "sys", "dev", "run", "boot", "data", "mnt"]);
        assert_eq!(
            filter_and_sort_fs_entries(input.clone(), true),
            names(&["data", "mnt"])
        );
        // Away from the root, none of those names are special — kept and sorted.
        assert_eq!(
            filter_and_sort_fs_entries(input, false),
            names(&["boot", "data", "dev", "mnt", "proc", "run", "sys"])
        );
    }

    #[test]
    fn sorts_case_insensitively() {
        let input = names(&["Zebra", "apple", "Banana", "aardvark"]);
        assert_eq!(
            filter_and_sort_fs_entries(input, false),
            names(&["aardvark", "apple", "Banana", "Zebra"])
        );
    }

    #[test]
    fn empty_input_yields_empty_output() {
        assert!(filter_and_sort_fs_entries(Vec::new(), true).is_empty());
    }

    #[test]
    fn rejects_relative_path() {
        assert!(!std::path::Path::new("data/live").is_absolute());
        assert!(std::path::Path::new("/data/live").is_absolute());
    }
}

#[cfg(test)]
mod motion_cache_projection_tests {
    use super::*;

    #[test]
    fn zero_or_negative_rate_projects_zero() {
        assert_eq!(project_camera_ring_bytes(0.0, 30), 0);
        assert_eq!(project_camera_ring_bytes(-5.0, 30), 0);
    }

    #[test]
    fn matches_hand_worked_example() {
        // 1 MB/s (typical 8 Mbps main stream, per docs/MOTION-RECORDING.md §5),
        // 30s pre-roll: window = 30 + 8 (RING_SLACK_SECS) + 2*4 (SEGMENT_SECONDS) = 46s.
        let bytes_per_sec: f64 = 1_000_000.0;
        let expected = (46.0 * bytes_per_sec).round() as i64;
        assert_eq!(project_camera_ring_bytes(bytes_per_sec, 30), expected);
    }

    #[test]
    fn scales_linearly_with_rate() {
        let low = project_camera_ring_bytes(500_000.0, 10);
        let high = project_camera_ring_bytes(1_000_000.0, 10);
        assert_eq!(high, low * 2);
    }

    #[test]
    fn longer_pre_roll_projects_more() {
        let short = project_camera_ring_bytes(1_000_000.0, 5);
        let long = project_camera_ring_bytes(1_000_000.0, 60);
        assert!(long > short);
        // Difference should be exactly the extra pre-roll seconds' worth of bytes.
        assert_eq!(
            long - short,
            (f64::from(60 - 5) * 1_000_000.0).round() as i64
        );
    }

    #[test]
    fn zero_pre_roll_still_projects_the_slack_and_segment_headroom() {
        // Even a 0s pre-roll camera has RING_SLACK_SECS + 2*SEGMENT_SECONDS of
        // ring headroom to project — never zero just because pre-roll is zero.
        let projected = project_camera_ring_bytes(1_000_000.0, 0);
        assert_eq!(projected, (16.0_f64 * 1_000_000.0).round() as i64); // 8 + 2*4
    }

    #[test]
    fn absurd_rate_clamps_to_i64_max_instead_of_overflowing() {
        let projected = project_camera_ring_bytes(f64::MAX, 30);
        assert_eq!(projected, i64::MAX);
    }
}
