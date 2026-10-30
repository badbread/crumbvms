// SPDX-License-Identifier: AGPL-3.0-or-later

//! License-plate reads API (`GET /plates`).
//!
//! Capability-gated on `view_plates` — Crumb's first capability-gated *read*
//! endpoint, because a searchable plate database is the most privacy-sensitive
//! surface. Camera-scoped exactly like `/events`: out-of-scope cameras are
//! dropped from the result, not 403'd. An empty window or a scoped-out caller
//! returns an empty page — never an error. Note: reads captured before LPR was
//! toggled off remain queryable (there is no `enabled` gate on the read path);
//! disabling capture only stops NEW reads, and retention pruning ages out the
//! stored ones.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crumb_common::{
    db,
    types::{LprSettings, PlateRead, PlateWatchlistEntry},
};

use crate::{
    auth_mw::{AdminUser, AuthUser, MediaOrFullUser},
    error::ApiError,
    state::AppState,
};

/// Mount the authenticated JSON routes: `GET /plates` (view_plates-gated), the
/// admin `GET`/`PUT /config/lpr` enable toggle, the plate-watchlist CRUD (reads
/// gated on `view_plates`, writes admin-only), the plate-name CRUD
/// (`PUT`/`DELETE /lpr/plate-labels`, admin-only, issue #363), and the plate
/// corrections (`/lpr/plate-aliases`, reads `view_plates`, writes admin-only,
/// issue #673).
///
/// Mounted in `json_routes` (rate-limited, gzip, 30 s timeout).
pub fn json_routes() -> Router<AppState> {
    Router::new()
        .route("/plates", get(get_plates))
        .route("/plates/:id/crop", get(get_plate_crop))
        // External-engine ingest (crumb-alpr worker). Authenticated by the
        // `lpr_config` ingest token, NOT a user JWT — so no AuthUser extractor.
        .route("/lpr/reads", post(post_lpr_read))
        // The crumb-alpr worker polls its effective per-camera config (zones,
        // min-conf, engine). Ingest-token-auth like /lpr/reads, not a user JWT.
        .route("/lpr/worker-config", get(get_worker_config))
        // Dual-engine A/B benchmark: derived-pass report (view_plates-gated)
        // and operator ground-truth confirmation (admin-only, like the
        // watchlist writes).
        .route("/lpr/ab-report", get(get_ab_report))
        // Plate desk (LPR page redesign): today's header totals and per-plate
        // history for the plates on screen. view_plates-gated, camera-scoped.
        .route("/lpr/overview", get(get_lpr_overview))
        .route("/lpr/plates/stats", post(post_plate_stats))
        .route("/lpr/ab-confirm", post(post_ab_confirm))
        .route("/config/lpr", get(get_lpr_config).put(put_lpr_config))
        .route("/config/lpr/rotate-token", post(rotate_lpr_token))
        // Storage-footprint hint for the retention field (admin-only, like the
        // /config/lpr card it decorates).
        .route("/lpr/storage", get(get_lpr_storage))
        .route(
            "/lpr/watchlist",
            get(get_watchlist).post(post_watchlist_entry),
        )
        .route(
            "/lpr/watchlist/:id",
            axum::routing::delete(delete_watchlist),
        )
        // Human-readable plate names (issue #363). Writes are admin-only, like
        // the watchlist writes; the resolved name rides `GET /plates` and the
        // watchlist read for every client via the `display_name` DTO field.
        .route("/lpr/plate-labels", axum::routing::put(put_plate_label))
        .route(
            "/lpr/plate-labels/:plate",
            axum::routing::delete(delete_plate_label),
        )
        // Plate corrections (issue #673): "this misread is really that
        // plate". Reads are view_plates-gated and camera-scoped; writes are
        // admin-only, like plate names and the watchlist.
        .route(
            "/lpr/plate-aliases",
            get(get_plate_aliases).post(post_plate_alias),
        )
        .route(
            "/lpr/plate-aliases/:alias",
            axum::routing::delete(delete_plate_alias),
        )
        .route(
            "/lpr/plate-alias-suggestions",
            get(get_plate_alias_suggestions),
        )
}

// ── external-engine ingest (`POST /lpr/reads`) ──────────────────────────────

/// `POST /lpr/reads` body — one voted plate read from an external OCR engine
/// (the `crumb-alpr` fast-alpr worker). Authenticated by the `lpr_config` ingest
/// token, never a user JWT.
#[derive(Debug, Deserialize)]
pub struct LprReadIngest {
    pub camera_id: Uuid,
    /// Recognized plate string (raw engine output; normalized server-side).
    pub plate: String,
    /// OCR confidence `0..1`, if the engine reports one.
    pub confidence: Option<f32>,
    /// State/region label if the engine reports one (preserved in `raw`).
    pub region: Option<String>,
    /// Plate box as `[x, y, w, h]` fractions (`0..1`) of the frame.
    pub bbox: Option<[f32; 4]>,
    /// Plate crop as a base64-encoded JPEG (stored in `plate_reads.crop`).
    pub crop_jpeg_b64: Option<String>,
    /// Stable per-vehicle-pass id for dedup — one stored read per pass.
    pub provider_event_id: String,
    /// Read time (engine clock). Defaults to now when omitted.
    pub ts: Option<DateTime<Utc>>,
}

/// Constant-time byte comparison for the shared ingest token, so a wrong token
/// cannot be recovered via response timing. The length short-circuit is
/// acceptable for a high-entropy random token (it leaks only length, not bytes).
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Verify the LPR ingest token against `lpr_config`, constant-time. Shared by the
/// ingest and worker-config handlers. The token is read from the `X-Ingest-Token`
/// header or an `Authorization: Bearer` header. Returns `403` when LPR is disabled
/// or no token is configured, and `401` on a token mismatch.
async fn verify_ingest_token(
    state: &AppState,
    headers: &axum::http::HeaderMap,
) -> Result<(), ApiError> {
    let cfg = db::get_lpr_settings(state.pool())
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("lpr_config row missing")))?;
    if !cfg.enabled {
        return Err(ApiError::Forbidden("LPR capture is disabled".to_owned()));
    }
    let expected = cfg
        .ingest_token
        .as_deref()
        .filter(|t| !t.is_empty())
        .ok_or_else(|| ApiError::Forbidden("LPR ingest token not configured".to_owned()))?;
    let presented = headers
        .get("x-ingest-token")
        .and_then(|v| v.to_str().ok())
        .or_else(|| {
            headers
                .get(axum::http::header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.strip_prefix("Bearer "))
        })
        .unwrap_or("");
    if !ct_eq(presented.as_bytes(), expected.as_bytes()) {
        return Err(ApiError::Unauthorized(
            "invalid LPR ingest token".to_owned(),
        ));
    }
    Ok(())
}

/// `POST /lpr/reads` — external-engine plate ingest. Auth is the
/// `lpr_config.ingest_token` (header `X-Ingest-Token`, or `Authorization: Bearer`),
/// NOT a user JWT. Requires LPR capture enabled and a configured token. Builds a
/// `crumb-alpr` `NormalizedEvent` and sends it into the SAME detection channel
/// Frigate uses, so dedup / ignore-list / watchlist / alerts / the timeline event
/// mirror are all reused verbatim (see `detection_ingester`).
///
/// # Errors
///
/// * `400` — empty plate or malformed `crop_jpeg_b64`.
/// * `401` — missing/incorrect ingest token.
/// * `403` — LPR capture disabled, or no ingest token configured.
/// * `500` — the ingester is not running (API built without the `detection` feature).
async fn post_lpr_read(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(body): Json<LprReadIngest>,
) -> Result<StatusCode, ApiError> {
    verify_ingest_token(&state, &headers).await?;

    // Per-camera enforcement: the camera must exist, have LPR enabled, and use an
    // engine that accepts crumb-alpr reads. The global token check is not enough —
    // a per-camera OFF is the operator's privacy control and must actually stop
    // capture (not just decorate the UI). Unknown camera -> 404 (also catches a
    // worker configured with a mistyped LPR_CAMERA_ID, which would otherwise 202
    // forever while the FK-violating read is silently dropped by the ingester).
    let cam = db::get_camera_lpr_config(state.pool(), body.camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {} not found", body.camera_id)))?;
    if !cam.enabled {
        return Err(ApiError::Forbidden(
            "LPR is disabled for this camera".to_owned(),
        ));
    }
    if cam.engine != "crumb-alpr" && cam.engine != "both" {
        return Err(ApiError::Forbidden(format!(
            "this camera's LPR engine is '{}', which does not accept crumb-alpr reads",
            cam.engine
        )));
    }

    if db::normalize_plate(&body.plate).is_empty() {
        return Err(ApiError::BadRequest(
            "plate must contain at least one alphanumeric character".to_owned(),
        ));
    }

    // Decode the crop up front so a malformed blob is a 400, not a silent drop.
    // Cap the decoded size so a flood of large crops can't amplify into the
    // bounded ingester channel and pin API memory.
    const MAX_CROP_BYTES: usize = 512 * 1024;
    let crop = match body.crop_jpeg_b64.as_deref() {
        Some(b64) if !b64.is_empty() => {
            use base64::Engine as _;
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(b64)
                .map_err(|_| {
                    ApiError::BadRequest("crop_jpeg_b64 is not valid base64".to_owned())
                })?;
            if bytes.len() > MAX_CROP_BYTES {
                return Err(ApiError::BadRequest(format!(
                    "crop_jpeg_b64 decodes to {} bytes, over the {MAX_CROP_BYTES}-byte cap",
                    bytes.len()
                )));
            }
            Some(bytes)
        }
        _ => None,
    };

    // Clamp the client-supplied timestamp: a far-future ts would defeat retention
    // pruning (a permanent plate record — retention is the core privacy control);
    // a far-past ts pollutes/loses history. Outside a small window around now,
    // fall back to now. (The worker always sends ts=null anyway.)
    let now = Utc::now();
    let ts = match body.ts {
        Some(t) if (t - now).num_seconds().abs() <= 3600 => t,
        _ => now,
    };
    // Clamp confidence + bbox to valid ranges so out-of-range values never reach
    // the store or clients.
    let confidence = body.confidence.map(|c| c.clamp(0.0, 1.0));
    let score = confidence.unwrap_or(1.0);
    let bbox = body.bbox.map(|b| b.map(|v| v.clamp(0.0, 1.0)));
    let raw = serde_json::json!({
        "source": "crumb-alpr",
        "plate": body.plate,
        "region": body.region,
        "confidence": confidence,
    });

    let event = crumb_common::detection::NormalizedEvent {
        source_id: "crumb-alpr".to_owned(),
        camera_id: body.camera_id,
        provider_event_id: body.provider_event_id,
        lifecycle: crumb_common::detection::EventLifecycle::End,
        label: crumb_common::detection::DetectionLabel::LicensePlate,
        // Mirror Frigate: the recognized plate rides `sub_label` too, so the
        // shared detection timeline shows it. Plate capture keys off
        // `recognized_plate` (below), which `plate_string()` prefers.
        sub_label: Some(body.plate.clone()),
        score,
        top_score: score,
        start_ts: ts,
        end_ts: Some(ts),
        bounding_box: None,
        zones: vec![],
        snapshot_url: None,
        recognized_plate: Some(body.plate.clone()),
        plate_confidence: confidence,
        plate_box: bbox,
        plate_crop: crop,
        raw,
    };

    let tx = state.event_tx().ok_or_else(|| {
        ApiError::Internal(anyhow::anyhow!(
            "detection ingester not running (API built without the `detection` feature)"
        ))
    })?;
    tx.send(event)
        .await
        .map_err(|_| ApiError::Internal(anyhow::anyhow!("detection ingester channel closed")))?;
    Ok(StatusCode::ACCEPTED)
}

/// `GET /plates/:id/crop` — serve a stored plate crop JPEG (external-engine reads
/// only; Frigate reads carry `snapshot_url` instead). `view_plates`-gated and
/// camera-scoped: an out-of-scope or unknown read 404s (never revealing
/// existence), and a read with no stored crop 404s.
///
/// # Errors
///
/// * `401` / `403` — auth failure / missing `view_plates`.
/// * `404` — no such read (or out of scope), or the read has no crop.
async fn get_plate_crop(
    // Media-read: the cropped plate JPEG is fetched with a scoped `?token=`
    // (A/B benchmark + Plates report). Accepts a scoped media token or a full
    // session; view_plates capability + camera scope are enforced below.
    MediaOrFullUser(user): MediaOrFullUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<axum::response::Response, ApiError> {
    user.require_view_plates()?;
    let (camera_id, crop) = db::get_plate_read_crop(state.pool(), id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("plate read {id} not found")))?;
    if user.filter_camera_ids(&[camera_id]).is_empty() {
        return Err(ApiError::NotFound(format!("plate read {id} not found")));
    }
    let bytes = crop.ok_or_else(|| ApiError::NotFound(format!("plate read {id} has no crop")))?;
    Ok(([(axum::http::header::CONTENT_TYPE, "image/jpeg")], bytes).into_response())
}

/// `POST /config/lpr/rotate-token` — admin. Generate a new random ingest token,
/// store it, and return it ONCE (it is never retrievable via `GET /config/lpr`).
/// Rotating invalidates any previously issued token.
async fn rotate_lpr_token(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let current = db::get_lpr_settings(state.pool())
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("lpr_config row missing")))?;
    // 64 hex chars (~244 bits) from two v4 UUIDs — no extra dependency.
    let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    db::update_lpr_settings(
        state.pool(),
        current.enabled,
        current.retention_days,
        current.watchlist_fuzz,
        true,
        Some(&token),
    )
    .await
    .map_err(ApiError::Internal)?;
    Ok(Json(serde_json::json!({ "ingest_token": token })))
}

/// `GET /lpr/worker-config?camera_id=<uuid>` query.
#[derive(Debug, Deserialize)]
pub struct WorkerConfigQuery {
    pub camera_id: Uuid,
}

/// `GET /lpr/worker-config?camera_id=<uuid>` — the crumb-alpr worker polls its
/// effective per-camera config (enable, engine, min-confidence, detection zones)
/// so admin edits apply without a worker restart. Auth is the LPR ingest token
/// (same as `POST /lpr/reads`), NOT a user JWT.
///
/// # Errors
///
/// * `401` / `403` — token failure / LPR disabled.
/// * `404` — no such camera.
async fn get_worker_config(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Query(q): Query<WorkerConfigQuery>,
) -> Result<Json<crumb_common::types::CameraLprConfig>, ApiError> {
    verify_ingest_token(&state, &headers).await?;
    let cfg = db::get_camera_lpr_config(state.pool(), q.camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {} not found", q.camera_id)))?;
    Ok(Json(cfg))
}

// ── plate watchlist (`/lpr/watchlist`) ───────────────────────────────────────

/// `POST /lpr/watchlist` body. `plate` is normalized server-side; `notify`
/// defaults true; `kind` is `"watch"` (alert) or `"ignore"` (drop the read).
#[derive(Debug, Deserialize)]
pub struct WatchlistUpsert {
    pub plate: String,
    pub label: Option<String>,
    pub note: Option<String>,
    pub color: Option<String>,
    #[serde(default = "default_notify")]
    pub notify: bool,
    #[serde(default = "default_kind")]
    pub kind: String,
}

fn default_notify() -> bool {
    true
}

fn default_kind() -> String {
    "watch".to_owned()
}

/// `GET /lpr/watchlist` — list every watchlist entry. `view_plates`-gated: an
/// operator who can see plates can see which are flagged.
async fn get_watchlist(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<PlateWatchlistEntry>>, ApiError> {
    user.require_view_plates()?;
    let entries = db::list_watchlist(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(entries))
}

/// `POST /lpr/watchlist` — add or edit a watchlist entry (admin-only; keyed on
/// the normalized plate, so re-adding the same plate edits it). Returns the
/// resulting entry.
async fn post_watchlist_entry(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<WatchlistUpsert>,
) -> Result<Json<PlateWatchlistEntry>, ApiError> {
    let plate = db::normalize_plate(&body.plate);
    if plate.is_empty() {
        return Err(ApiError::BadRequest(
            "plate must contain at least one alphanumeric character".to_owned(),
        ));
    }
    let kind = match body.kind.as_str() {
        "watch" | "ignore" => body.kind,
        _ => {
            return Err(ApiError::BadRequest(
                "kind must be 'watch' or 'ignore'".to_owned(),
            ))
        }
    };
    let entry = db::upsert_watchlist_entry(
        state.pool(),
        &db::UpsertWatchlistParams {
            plate,
            label: body.label.filter(|s| !s.is_empty()),
            note: body.note.filter(|s| !s.is_empty()),
            color: body.color.filter(|s| !s.is_empty()),
            notify: body.notify,
            kind,
        },
    )
    .await
    .map_err(ApiError::Internal)?;
    Ok(Json(entry))
}

/// `DELETE /lpr/watchlist/:id` — remove a watchlist entry (admin-only). 404 if
/// no such entry.
async fn delete_watchlist(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let removed = db::delete_watchlist_entry(state.pool(), id)
        .await
        .map_err(ApiError::Internal)?;
    if removed {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound(format!(
            "watchlist entry {id} not found"
        )))
    }
}

// ── plate names (`/lpr/plate-labels`) ────────────────────────────────────────

/// `PUT /lpr/plate-labels` body. `plate` is normalized server-side; `label` is
/// the human-readable name to show wherever the plate appears.
#[derive(Debug, Deserialize)]
pub struct PlateLabelUpsert {
    pub plate: String,
    pub label: String,
}

/// `PUT /lpr/plate-labels` — set or edit a plate's human-readable name (issue
/// #363). Admin-only, matching the watchlist writes: naming a plate is an
/// operator-curation action. Keyed on the normalized plate, so re-setting the
/// same plate edits it. The name then wins over any watchlist label wherever a
/// plate read is shown (see the `display_name` resolution in `list_plate_reads`
/// and the watchlist read).
///
/// # Errors
///
/// * `400` — the plate normalizes to empty, or the label is blank.
/// * `401` / `403` — auth failure / not an admin.
async fn put_plate_label(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<PlateLabelUpsert>,
) -> Result<StatusCode, ApiError> {
    let wrote = db::upsert_plate_label(state.pool(), &body.plate, &body.label)
        .await
        .map_err(ApiError::Internal)?;
    if wrote {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::BadRequest(
            "plate must contain at least one alphanumeric character and label must not be blank"
                .to_owned(),
        ))
    }
}

/// `DELETE /lpr/plate-labels/:plate` — clear a plate's human-readable name
/// (admin-only). The `plate` path segment is normalized before lookup, so it
/// matches how the name was stored. 404 when the plate has no name. After
/// clearing, reads fall back to any watchlist label, else the raw plate.
///
/// # Errors
///
/// * `400` — the plate normalizes to empty.
/// * `401` / `403` — auth failure / not an admin.
/// * `404` — the plate has no name set.
async fn delete_plate_label(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(plate): Path<String>,
) -> Result<StatusCode, ApiError> {
    if db::normalize_plate(&plate).is_empty() {
        return Err(ApiError::BadRequest(
            "plate must contain at least one alphanumeric character".to_owned(),
        ));
    }
    let removed = db::delete_plate_label(state.pool(), &plate)
        .await
        .map_err(ApiError::Internal)?;
    if removed {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound(format!("plate {plate} has no name set")))
    }
}

// ── plate corrections (`/lpr/plate-aliases`, issue #673) ─────────────────────

/// One plate correction as served to clients.
#[derive(Debug, Serialize)]
pub struct PlateAliasDto {
    /// The misread plate string (normalized).
    pub alias_plate: String,
    /// The plate its reads count as.
    pub canonical_plate: String,
    /// Username of the admin who made the correction, when still known.
    pub created_by: Option<String>,
    pub created_at: DateTime<Utc>,
    /// Reads stored under the misread string on cameras the caller may see:
    /// how many reads this correction moves.
    pub reads: i64,
}

/// `GET /lpr/plate-aliases` query.
#[derive(Debug, Deserialize)]
pub struct PlateAliasQuery {
    /// Only the misreads of this plate (normalized server-side).
    pub canonical: Option<String>,
}

async fn alias_dtos(
    state: &AppState,
    user: &AuthUser,
    aliases: Vec<db::PlateAlias>,
) -> Result<Vec<PlateAliasDto>, ApiError> {
    let scope = aggregate_scope(user, None);
    let plates: Vec<String> = aliases.iter().map(|a| a.alias_plate.clone()).collect();
    let counts = db::plate_raw_read_counts(state.pool(), &plates, scope.as_deref())
        .await
        .map_err(ApiError::Internal)?;
    Ok(aliases
        .into_iter()
        .map(|a| PlateAliasDto {
            reads: counts.get(&a.alias_plate).copied().unwrap_or(0),
            alias_plate: a.alias_plate,
            canonical_plate: a.canonical_plate,
            // Admin usernames are only for admins.
            created_by: if user.is_admin() {
                a.created_by_username
            } else {
                None
            },
            created_at: a.created_at,
        })
        .collect())
}

/// The plates among `plates` that have at least one read on a camera in
/// `scope` (`None` = every camera, so all of them).
async fn plates_visible_in_scope(
    state: &AppState,
    plates: &[String],
    scope: Option<&[Uuid]>,
) -> Result<std::collections::HashSet<String>, ApiError> {
    if scope.is_none() {
        return Ok(plates.iter().cloned().collect());
    }
    Ok(db::plate_raw_read_counts(state.pool(), plates, scope)
        .await
        .map_err(ApiError::Internal)?
        .into_keys()
        .collect())
}

/// `GET /lpr/plate-aliases[?canonical=<plate>]` — the plate corrections, or
/// only the known misreads of one plate (the plate profile's list).
/// `view_plates`-gated. For non-admins the list is camera-scoped: a correction
/// is returned only when its misread or its canonical plate has a read on a
/// camera the caller may see, the read counts only count such cameras, and
/// `created_by` (an admin username) is omitted.
///
/// # Errors
///
/// * `401` / `403` — auth failure / missing `view_plates`.
async fn get_plate_aliases(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<PlateAliasQuery>,
) -> Result<Json<Vec<PlateAliasDto>>, ApiError> {
    user.require_view_plates()?;
    let canonical = q
        .canonical
        .as_deref()
        .map(db::normalize_plate)
        .filter(|p| !p.is_empty());
    let mut aliases = db::list_plate_aliases(state.pool(), canonical.as_deref())
        .await
        .map_err(ApiError::Internal)?;
    if !user.is_admin() {
        // A correction is OCR output from specific cameras: show it only when
        // the misread or the plate it counts as was read on a camera the
        // caller may see.
        let scope = aggregate_scope(&user, None);
        let both: Vec<String> = aliases
            .iter()
            .flat_map(|a| [a.alias_plate.clone(), a.canonical_plate.clone()])
            .collect();
        let visible = plates_visible_in_scope(&state, &both, scope.as_deref()).await?;
        aliases
            .retain(|a| visible.contains(&a.alias_plate) || visible.contains(&a.canonical_plate));
    }
    Ok(Json(alias_dtos(&state, &user, aliases).await?))
}

/// `POST /lpr/plate-aliases` body: reads of `alias` count as `canonical`.
/// Both are normalized server-side.
#[derive(Debug, Deserialize)]
pub struct PlateAliasCreate {
    pub alias: String,
    pub canonical: String,
}

/// `POST /lpr/plate-aliases` response: the stored correction plus any older
/// corrections that were re-pointed to keep one level.
#[derive(Debug, Serialize)]
pub struct PlateAliasCreated {
    pub alias: PlateAliasDto,
    /// Aliases that pointed at the new alias and now point at its canonical
    /// plate.
    pub moved: Vec<String>,
}

/// `POST /lpr/plate-aliases {alias, canonical}` — record that a plate string
/// is a misread of another plate (issue #673). Admin-only, matching the plate
/// names and watchlist writes: a correction changes what every operator sees.
///
/// Raw reads are never rewritten; the correction is applied when reads are
/// queried and is undone with `DELETE`. Chains are flattened: naming a plate
/// that is itself a misread stores its canonical plate instead, and
/// correcting `B -> A` when `A -> B` exists swaps the two.
///
/// # Errors
///
/// * `400` — a plate normalizes to empty, or both are the same plate.
/// * `401` / `403` — auth failure / not an admin.
async fn post_plate_alias(
    admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<PlateAliasCreate>,
) -> Result<(StatusCode, Json<PlateAliasCreated>), ApiError> {
    let written = db::create_plate_alias(
        state.pool(),
        &body.alias,
        &body.canonical,
        Some(admin.0.user_id),
    )
    .await
    .map_err(ApiError::Internal)?;
    match written {
        db::PlateAliasWrite::Saved { alias, moved } => {
            let mut dtos = alias_dtos(&state, &admin.0, vec![alias]).await?;
            let alias = dtos.pop().ok_or_else(|| {
                ApiError::Internal(anyhow::anyhow!("plate alias vanished after write"))
            })?;
            Ok((
                StatusCode::CREATED,
                Json(PlateAliasCreated { alias, moved }),
            ))
        }
        db::PlateAliasWrite::Invalid => Err(ApiError::BadRequest(
            "alias and canonical must each contain at least one alphanumeric character \
             and must be different plates"
                .to_owned(),
        )),
    }
}

/// `DELETE /lpr/plate-aliases/:alias` — undo a correction: reads of the
/// misread string count as themselves again (admin-only). 404 when the plate
/// has no correction.
///
/// # Errors
///
/// * `400` — the plate normalizes to empty.
/// * `401` / `403` — auth failure / not an admin.
/// * `404` — no correction for this plate.
async fn delete_plate_alias(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(alias): Path<String>,
) -> Result<StatusCode, ApiError> {
    if db::normalize_plate(&alias).is_empty() {
        return Err(ApiError::BadRequest(
            "plate must contain at least one alphanumeric character".to_owned(),
        ));
    }
    let removed = db::delete_plate_alias(state.pool(), &alias)
        .await
        .map_err(ApiError::Internal)?;
    if removed {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound(format!(
            "plate {alias} has no correction"
        )))
    }
}

/// `GET /lpr/plate-alias-suggestions` query.
#[derive(Debug, Deserialize)]
pub struct PlateSuggestQuery {
    /// The plate being corrected (normalized server-side).
    pub plate: String,
}

/// One likely correction target.
#[derive(Debug, Serialize)]
pub struct PlateSuggestionDto {
    pub plate: String,
    pub reads: i64,
    pub distance: usize,
    pub display_name: Option<String>,
}

/// `GET /lpr/plate-alias-suggestions` response.
#[derive(Debug, Serialize)]
pub struct PlateSuggestResponse {
    /// The normalized input plate.
    pub plate: String,
    /// What the input currently counts as (itself, unless already corrected).
    pub canonical_plate: String,
    /// Visible reads a correction of `plate` would move: its own reads plus
    /// those of any misreads that currently point at it.
    pub reads: i64,
    /// Misreads that currently point at `plate` and would move with it.
    pub aliases: Vec<String>,
    /// Likely real plates, closest first.
    pub suggestions: Vec<PlateSuggestionDto>,
}

/// Most suggestions returned.
const MAX_PLATE_SUGGESTIONS: usize = 8;

/// `GET /lpr/plate-alias-suggestions?plate=<plate>` — feeds the "Correct
/// plate" dialog: the existing plates `plate` is probably a misread of (within
/// two character edits, with OCR-confusable characters such as `O`/`0` free,
/// the same distance as watchlist matching), and how many reads a correction
/// would move. `view_plates`-gated and camera-scoped: only plates and reads on
/// cameras the caller may see are considered.
///
/// # Errors
///
/// * `400` — the plate normalizes to empty.
/// * `401` / `403` — auth failure / missing `view_plates`.
async fn get_plate_alias_suggestions(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<PlateSuggestQuery>,
) -> Result<Json<PlateSuggestResponse>, ApiError> {
    user.require_view_plates()?;
    let plate = db::normalize_plate(&q.plate);
    if plate.is_empty() {
        return Err(ApiError::BadRequest(
            "plate must contain at least one alphanumeric character".to_owned(),
        ));
    }
    let scope = aggregate_scope(&user, None);
    let pool = state.pool();
    let mut canonical_plate = db::resolve_plate_alias(pool, &plate)
        .await
        .map_err(ApiError::Internal)?;
    let mut aliases: Vec<String> = db::plate_aliases_of(pool, std::slice::from_ref(&plate))
        .await
        .map_err(ApiError::Internal)?
        .into_iter()
        .map(|(a, _)| a)
        .collect();
    if !user.is_admin() {
        // Same visibility rule as `GET /lpr/plate-aliases`: a correction row
        // shows only when one of its two plates was read on a visible camera.
        let mut probe = aliases.clone();
        probe.push(plate.clone());
        probe.push(canonical_plate.clone());
        let visible = plates_visible_in_scope(&state, &probe, scope.as_deref()).await?;
        // If the input itself is visible, every correction touching it is.
        if !visible.contains(&plate) {
            aliases.retain(|a| visible.contains(a));
            if !visible.contains(&canonical_plate) {
                canonical_plate.clone_from(&plate);
            }
        }
    }
    let mut group = aliases.clone();
    group.push(plate.clone());
    let reads = db::plate_raw_read_counts(pool, &group, scope.as_deref())
        .await
        .map_err(ApiError::Internal)?
        .values()
        .sum();
    let suggestions =
        db::suggest_plate_corrections(pool, &plate, scope.as_deref(), MAX_PLATE_SUGGESTIONS)
            .await
            .map_err(ApiError::Internal)?
            .into_iter()
            .map(|s| PlateSuggestionDto {
                plate: s.plate,
                reads: s.reads,
                distance: s.distance,
                display_name: s.display_name,
            })
            .collect();
    Ok(Json(PlateSuggestResponse {
        plate,
        canonical_plate,
        reads,
        aliases,
        suggestions,
    }))
}

// ── plate desk: today's overview + per-plate history (`/lpr/overview`,
// `/lpr/plates/stats`) ───────────────────────────────────────────────────────

/// Max plates one `POST /lpr/plates/stats` call may ask about. Clients batch
/// the plates currently on screen, which is well under this.
pub const MAX_STATS_PLATES: usize = 200;

/// Resolve the camera scope for an aggregate read. An explicit `requested`
/// list is intersected with the caller's grants (out-of-scope cameras are
/// dropped, never 403'd, exactly like `/plates`). No list means "every camera
/// I can see": `None` (no filter) for an admin, the granted cameras otherwise.
fn aggregate_scope(user: &AuthUser, requested: Option<Vec<Uuid>>) -> Option<Vec<Uuid>> {
    match requested {
        Some(ids) if !ids.is_empty() => Some(user.filter_camera_ids(&ids)),
        _ if user.is_admin() => None,
        _ => Some(user.camera_ids.clone()),
    }
}

/// UTC instant of local midnight starting `day` in `tz`. A zone whose DST
/// jump skips midnight starts that day at the first valid local instant
/// (01:00); an ambiguous midnight takes the earlier instant.
fn local_day_start(tz: chrono_tz::Tz, day: NaiveDate) -> DateTime<Utc> {
    use chrono::{LocalResult, TimeZone};
    let midnight = day.and_time(NaiveTime::MIN);
    match tz.from_local_datetime(&midnight) {
        LocalResult::Single(t) | LocalResult::Ambiguous(t, _) => t.with_timezone(&Utc),
        LocalResult::None => tz
            .from_local_datetime(&(midnight + chrono::Duration::hours(1)))
            .earliest()
            .map_or_else(|| midnight.and_utc(), |t| t.with_timezone(&Utc)),
    }
}

/// The UTC bounds of local `day`, plus the start of the 30-day window ending
/// with it (local day `day - 29`). `None` only at the edges of the calendar.
fn day_bounds(
    tz: chrono_tz::Tz,
    day: NaiveDate,
) -> Option<(DateTime<Utc>, DateTime<Utc>, DateTime<Utc>)> {
    let next = day.checked_add_days(chrono::Days::new(1))?;
    #[allow(clippy::cast_possible_truncation)]
    let first = day.checked_sub_days(chrono::Days::new(db::LPR_STATS_DAYS as u64 - 1))?;
    Some((
        local_day_start(tz, day),
        local_day_start(tz, next),
        local_day_start(tz, first),
    ))
}

/// `GET /lpr/overview` query.
#[derive(Debug, Deserialize)]
pub struct LprOverviewQuery {
    /// Local calendar day (`YYYY-MM-DD`, the server's time zone). Default:
    /// today on the server.
    pub day: Option<NaiveDate>,
    /// Optional comma-separated camera UUIDs to narrow to (caller-scoped).
    /// Omitted = every camera the caller can see.
    pub camera_ids: Option<String>,
}

/// The regulars / returning / first-time split of the day's unique plates.
/// The three always sum to `unique_today`.
#[derive(Debug, Serialize)]
pub struct LprSplitDto {
    /// Seen before the day, at least `regular_min_reads_30d` reads in the 30
    /// days ending with it.
    pub regulars: i64,
    /// Seen before the day, but not (yet) a regular.
    pub returning: i64,
    /// First seen on the day (same number as `new_today`).
    pub first_time: i64,
}

/// `GET /lpr/overview` response.
#[derive(Debug, Serialize)]
pub struct LprOverviewDto {
    /// The local day summarized.
    pub day: NaiveDate,
    /// IANA name of the server time zone the day is computed in.
    pub tz: String,
    pub reads_today: i64,
    pub unique_today: i64,
    pub new_today: i64,
    /// Reads on the day of plates on the watchlist (watch entries, exact
    /// plate match; ignore entries never count).
    pub watchlist_hits_today: i64,
    pub split: LprSplitDto,
    /// The "regular" threshold the split used, so clients label plates with
    /// the same rule.
    pub regular_min_reads_30d: i64,
}

/// `GET /lpr/overview?day=<YYYY-MM-DD>&camera_ids=<csv>` — the plate desk
/// header: the day's reads, unique plates, new plates, watchlist hits and the
/// regulars / returning / first-time split. "Day" is the server's local day.
///
/// `view_plates`-gated and camera-scoped like `/plates`: only reads from
/// cameras the caller may see are counted, including the history that decides
/// whether a plate is new or a regular.
///
/// # Errors
///
/// * `400` — malformed camera ids or an out-of-range day.
/// * `401` / `403` — auth failure / missing `view_plates`.
async fn get_lpr_overview(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<LprOverviewQuery>,
) -> Result<Json<LprOverviewDto>, ApiError> {
    user.require_view_plates()?;
    let tz = state.config().server_tz;
    let requested = q.camera_ids.as_deref().map(parse_uuid_csv).transpose()?;
    let scope = aggregate_scope(&user, requested);
    let day = q
        .day
        .unwrap_or_else(|| Utc::now().with_timezone(&tz).date_naive());
    let (start, end, window) =
        day_bounds(tz, day).ok_or_else(|| ApiError::BadRequest("day out of range".to_owned()))?;
    let c = db::lpr_overview(state.pool(), scope.as_deref(), start, end, window)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(LprOverviewDto {
        day,
        tz: tz.name().to_owned(),
        reads_today: c.reads,
        unique_today: c.unique,
        new_today: c.new_plates,
        watchlist_hits_today: c.watchlist_hits,
        split: LprSplitDto {
            regulars: c.regulars,
            returning: c.returning,
            first_time: c.new_plates,
        },
        regular_min_reads_30d: db::LPR_REGULAR_MIN_READS_30D,
    }))
}

/// `POST /lpr/plates/stats` body.
#[derive(Debug, Deserialize)]
pub struct PlateStatsBody {
    /// Plates to describe (normalized server-side, de-duplicated; at most
    /// [`MAX_STATS_PLATES`] entries).
    pub plates: Vec<String>,
    /// Optional camera narrowing (caller-scoped). Omitted = every camera the
    /// caller can see.
    pub camera_ids: Option<Vec<Uuid>>,
}

/// Reads of one plate on one camera.
#[derive(Debug, Serialize)]
pub struct PlateCameraCountDto {
    pub camera_id: Uuid,
    pub n: i64,
}

/// One plate's history in `POST /lpr/plates/stats`.
#[derive(Debug, Serialize)]
pub struct PlateStatsDto {
    pub plate: String,
    pub total: i64,
    /// Reads in the last 7 local days, today included.
    pub seen_7d: i64,
    /// Reads in the last 30 local days, today included (`sum(days30)`).
    pub seen_30d: i64,
    pub first_seen: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
    /// Latest read before today (local), when there is one.
    pub prev_seen: Option<DateTime<Utc>>,
    /// Reads per camera, most first.
    pub cameras: Vec<PlateCameraCountDto>,
    /// 24 counts, reads per local hour of day over the whole history.
    pub hours: Vec<i64>,
    /// 30 counts, reads per local day, oldest first; the last one is today.
    pub days30: Vec<i64>,
}

/// `POST /lpr/plates/stats` response.
#[derive(Debug, Serialize)]
pub struct PlateStatsResponse {
    /// IANA name of the zone `hours` / `days30` are bucketed in.
    pub tz: String,
    /// The local day `days30` ends with.
    pub today: NaiveDate,
    pub regular_min_reads_30d: i64,
    /// One entry per requested plate that has visible reads (plates with none
    /// are omitted), ordered by plate. Plate corrections are resolved: a
    /// requested misread is answered under its canonical plate, and a
    /// canonical plate's numbers include its misreads (issue #673).
    pub plates: Vec<PlateStatsDto>,
}

/// `POST /lpr/plates/stats {plates: [...]}` — history for the plates on
/// screen: totals, 7/30-day counts, first / last / previous sighting, camera
/// breakdown, hour-of-day and 30-day activity, bucketed in the server's time
/// zone. Feeds the history cells, sparklines and the plate profile.
///
/// `view_plates`-gated and camera-scoped: reads from cameras the caller may
/// not see are never counted. Bounded by the requested plates through the
/// (plate, ts) index, never a table scan.
///
/// # Errors
///
/// * `400` — more than [`MAX_STATS_PLATES`] distinct plates.
/// * `401` / `403` — auth failure / missing `view_plates`.
async fn post_plate_stats(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<PlateStatsBody>,
) -> Result<Json<PlateStatsResponse>, ApiError> {
    user.require_view_plates()?;
    let tz = state.config().server_tz;
    let today = Utc::now().with_timezone(&tz).date_naive();

    if body.plates.len() > MAX_STATS_PLATES {
        return Err(ApiError::BadRequest(format!(
            "at most {MAX_STATS_PLATES} plates per request"
        )));
    }
    let mut plates: Vec<String> = body
        .plates
        .iter()
        .map(|p| db::normalize_plate(p))
        .filter(|p| !p.is_empty())
        .collect();
    plates.sort_unstable();
    plates.dedup();

    let scope = aggregate_scope(&user, body.camera_ids);
    let (today_start, _, window) = day_bounds(tz, today)
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("server day out of range")))?;
    let history = db::lpr_plate_stats(
        state.pool(),
        &plates,
        scope.as_deref(),
        tz.name(),
        window,
        today_start,
    )
    .await
    .map_err(ApiError::Internal)?;

    let plates = history
        .into_iter()
        .map(|s| {
            let seen_30d = s.days.iter().sum();
            let seen_7d = s.days[db::LPR_STATS_DAYS - 7..].iter().sum();
            PlateStatsDto {
                plate: s.plate,
                total: s.total,
                seen_7d,
                seen_30d,
                first_seen: s.first_seen,
                last_seen: s.last_seen,
                prev_seen: s.prev_seen,
                cameras: s
                    .cameras
                    .into_iter()
                    .map(|(camera_id, n)| PlateCameraCountDto { camera_id, n })
                    .collect(),
                hours: s.hours.to_vec(),
                days30: s.days.to_vec(),
            }
        })
        .collect();
    Ok(Json(PlateStatsResponse {
        tz: tz.name().to_owned(),
        today,
        regular_min_reads_30d: db::LPR_REGULAR_MIN_READS_30D,
        plates,
    }))
}

// ── dual-engine A/B benchmark (`/lpr/ab-report`, `/lpr/ab-confirm`) ─────────

/// `GET /lpr/ab-report` query. All optional; see [`get_ab_report`].
#[derive(Debug, Deserialize)]
pub struct AbReportQuery {
    /// Restrict to one camera (must be a `both`-engine camera in the caller's
    /// scope; anything else yields the empty report, mirroring `/plates`).
    pub camera_id: Option<Uuid>,
    /// Pass-pairing window in seconds (reads of one physical vehicle pass).
    /// Default 8, clamped 2..=120.
    pub window: Option<i64>,
    /// Pairing fuzziness (length-scaled Levenshtein, same model as the
    /// watchlist). Default 0.25, clamped 0.0..=0.5.
    pub fuzz: Option<f32>,
    /// Report range start (ISO 8601, inclusive). Default: `end - 24h`.
    pub start: Option<DateTime<Utc>>,
    /// Report range end (ISO 8601, exclusive). Default: now.
    pub end: Option<DateTime<Utc>>,
    /// Max passes returned. Default 100, max 500.
    pub limit: Option<i64>,
    /// Passes to skip (stats always cover the whole range, only the pass list
    /// pages).
    pub offset: Option<i64>,
}

/// A `both`-engine camera included in the report.
#[derive(Debug, Serialize)]
pub struct AbCameraDto {
    pub id: Uuid,
    pub name: String,
}

/// One engine's aggregate block in the report.
#[derive(Debug, Serialize)]
pub struct AbEngineStatsDto {
    pub total_reads: usize,
    pub passes_seen: usize,
    pub avg_confidence: Option<f32>,
    pub hit_rate: Option<f32>,
    pub confirmed: usize,
    pub correct: usize,
    pub accuracy: Option<f32>,
}

impl From<crumb_common::lpr_ab::EngineAggregate> for AbEngineStatsDto {
    fn from(a: crumb_common::lpr_ab::EngineAggregate) -> Self {
        Self {
            total_reads: a.total_reads,
            passes_seen: a.passes_seen,
            avg_confidence: a.avg_confidence,
            hit_rate: a.hit_rate,
            confirmed: a.confirmed,
            correct: a.correct,
            accuracy: a.accuracy,
        }
    }
}

/// One engine's best read within a paired pass.
#[derive(Debug, Serialize)]
pub struct AbReadDto {
    pub read_id: Uuid,
    pub plate: String,
    pub confidence: Option<f32>,
    /// Sibling detection event — the client fetches the pass image via the
    /// existing `GET /events/:id/snapshot` (or `GET /plates/:id/crop`).
    pub event_id: Option<Uuid>,
    /// Plate box `[x, y, w, h]` (0..1 fractions of the snapshot frame), when
    /// one was captured. Lets a client crop the pass image to the plate from
    /// the report alone — without a per-row `GET /plates` round-trip to look
    /// up a box the server already had.
    pub bbox: Option<[f32; 4]>,
    pub ts: DateTime<Utc>,
    /// Raw reads collapsed into this engine's entry (dup-refinement count).
    pub read_count: usize,
}

fn ab_read_dto(b: &crumb_common::lpr_ab::EngineBest) -> AbReadDto {
    AbReadDto {
        read_id: b.read_id,
        plate: b.plate.clone(),
        confidence: b.confidence,
        event_id: b.event_id,
        bbox: b.bbox,
        ts: b.ts,
        read_count: b.read_count,
    }
}

/// One paired pass row. `(camera_id, bucket_ts)` is the stable pass key the
/// confirm endpoint takes back.
#[derive(Debug, Serialize)]
pub struct AbPassDto {
    pub camera_id: Uuid,
    pub bucket_ts: DateTime<Utc>,
    pub frigate: Option<AbReadDto>,
    pub crumb_alpr: Option<AbReadDto>,
    /// Both engines read it and agreed (`null` when either missed).
    pub agree: Option<bool>,
    /// Operator-confirmed truth, when recorded.
    pub true_plate: Option<String>,
    pub frigate_correct: Option<bool>,
    pub crumb_alpr_correct: Option<bool>,
}

/// `GET /lpr/ab-report` response.
#[derive(Debug, Serialize)]
pub struct AbReportResponse {
    pub window_secs: i64,
    pub fuzz: f32,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// The `both`-engine cameras (caller-scoped) this report covers. Empty ⇒
    /// the benchmark is not applicable (clients hide the Benchmark UI).
    pub cameras: Vec<AbCameraDto>,
    pub total_passes: usize,
    pub both_seen: usize,
    pub agreement_rate: Option<f32>,
    pub frigate: AbEngineStatsDto,
    pub crumb_alpr: AbEngineStatsDto,
    /// One page of passes, newest first.
    pub passes: Vec<AbPassDto>,
    pub pass_total: usize,
    pub has_more: bool,
    /// True when the range held more reads than the report ceiling (stats
    /// cover only the newest slice — narrow the range).
    pub truncated: bool,
}

/// Report read ceiling: the newest reads fed to the pairing pass. A `both`
/// LPR camera produces a handful of reads per vehicle, so 10 000 covers weeks
/// of realistic traffic; beyond it the response flags `truncated`.
const AB_MAX_READS: i64 = 10_000;

/// `GET /lpr/ab-report` — head-to-head comparison of the two LPR engines on
/// `lpr_engine = 'both'` cameras: reads in the range are clustered into
/// physical vehicle passes (see `crumb_common::lpr_ab`), each pass carrying at
/// most one best read per engine, plus per-engine aggregates (hit rate,
/// agreement, confidence, and accuracy against operator-confirmed truths).
///
/// `view_plates`-gated and camera-scoped like `/plates`: out-of-scope or
/// non-`both` cameras are silently dropped; no eligible cameras yields the
/// empty report (`cameras: []`), never an error.
///
/// # Errors
///
/// * `400` — `start >= end`.
/// * `401` / `403` — auth failure / missing `view_plates`.
async fn get_ab_report(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<AbReportQuery>,
) -> Result<Json<AbReportResponse>, ApiError> {
    use crumb_common::lpr_ab;

    user.require_view_plates()?;

    let window_secs = q.window.unwrap_or(8).clamp(2, 120);
    let fuzz = q.fuzz.unwrap_or(0.25).clamp(0.0, 0.5);
    let end = q.end.unwrap_or_else(Utc::now);
    let start = q.start.unwrap_or(end - chrono::Duration::hours(24));
    if start >= end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let limit = q.limit.unwrap_or(100).clamp(1, 500) as usize;
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let offset = q.offset.unwrap_or(0).max(0) as usize;

    // Eligible cameras: lpr_engine = 'both', intersected with the caller's
    // camera scope, optionally narrowed to one requested camera.
    let all = db::list_lpr_ab_cameras(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    let all_ids: Vec<Uuid> = all.iter().map(|(id, _)| *id).collect();
    let scoped = user.filter_camera_ids(&all_ids);
    let mut cameras: Vec<AbCameraDto> = all
        .into_iter()
        .filter(|(id, _)| scoped.contains(id))
        .map(|(id, name)| AbCameraDto { id, name })
        .collect();
    if let Some(cid) = q.camera_id {
        cameras.retain(|c| c.id == cid);
    }
    if cameras.is_empty() {
        return Ok(Json(AbReportResponse {
            window_secs,
            fuzz,
            start,
            end,
            cameras,
            total_passes: 0,
            both_seen: 0,
            agreement_rate: None,
            frigate: AbEngineStatsDto::from(lpr_ab::EngineAggregate::default()),
            crumb_alpr: AbEngineStatsDto::from(lpr_ab::EngineAggregate::default()),
            passes: vec![],
            pass_total: 0,
            has_more: false,
            truncated: false,
        }));
    }
    let ids: Vec<Uuid> = cameras.iter().map(|c| c.id).collect();

    let (reads, read_total) = db::list_plate_reads(
        state.pool(),
        &db::PlateReadQuery {
            camera_ids: ids.clone(),
            start: Some(start),
            end: Some(end),
            plate: None,
            match_mode: db::PlateMatch::Contains,
            limit: AB_MAX_READS,
            offset: 0,
            // Score the engines on what they read, never on an operator's
            // later correction (which would inflate their accuracy).
            resolve_aliases: false,
        },
    )
    .await
    .map_err(ApiError::Internal)?;
    let truncated = read_total > AB_MAX_READS;

    // Truth rows for the range. `bucket_ts` is a read ts floored to whole
    // seconds, so widen the lower bound by a second to catch a pass whose
    // earliest read sits in the range's first partial second.
    let truths_rows = db::list_lpr_pass_truth(
        state.pool(),
        &ids,
        start - chrono::Duration::seconds(1),
        end,
    )
    .await
    .map_err(ApiError::Internal)?;
    let truths: std::collections::HashMap<(Uuid, DateTime<Utc>), String> = truths_rows
        .into_iter()
        .map(|t| ((t.camera_id, t.bucket_ts), t.true_plate))
        .collect();

    let passes = lpr_ab::pair_passes(&reads, window_secs, fuzz);
    let agg = lpr_ab::compute_stats(&reads, &passes, &truths);
    let pass_total = passes.len();

    let page: Vec<AbPassDto> = passes
        .iter()
        .skip(offset)
        .take(limit)
        .map(|p| {
            let truth = lpr_ab::truth_for(p, &truths);
            AbPassDto {
                camera_id: p.camera_id,
                bucket_ts: p.bucket_ts,
                frigate: p.frigate.as_ref().map(ab_read_dto),
                crumb_alpr: p.crumb_alpr.as_ref().map(ab_read_dto),
                agree: p.agree(),
                true_plate: truth.cloned(),
                frigate_correct: lpr_ab::engine_correct(p.frigate.as_ref(), truth),
                crumb_alpr_correct: lpr_ab::engine_correct(p.crumb_alpr.as_ref(), truth),
            }
        })
        .collect();
    let has_more = offset.saturating_add(page.len()) < pass_total;

    Ok(Json(AbReportResponse {
        window_secs,
        fuzz,
        start,
        end,
        cameras,
        total_passes: agg.total_passes,
        both_seen: agg.both_seen,
        agreement_rate: agg.agreement_rate,
        frigate: agg.frigate.into(),
        crumb_alpr: agg.crumb_alpr.into(),
        passes: page,
        pass_total,
        has_more,
        truncated,
    }))
}

/// `POST /lpr/ab-confirm` body: the pass key echoed from an `ab-report` row
/// plus the operator-verified plate (normalized server-side).
#[derive(Debug, Deserialize)]
pub struct AbConfirmBody {
    pub camera_id: Uuid,
    pub bucket_ts: DateTime<Utc>,
    pub true_plate: String,
}

/// `POST /lpr/ab-confirm` — record the operator-confirmed true plate for one
/// derived pass (upsert on the `(camera_id, bucket_ts)` pass key, so
/// re-confirming corrects a typo). Admin-only, matching the watchlist writes:
/// ground truth drives the published accuracy numbers.
///
/// # Errors
///
/// * `400` — `true_plate` normalizes to empty.
/// * `401` / `403` — auth failure / not an admin.
/// * `404` — unknown camera.
async fn post_ab_confirm(
    admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<AbConfirmBody>,
) -> Result<Json<crumb_common::types::LprPassTruth>, ApiError> {
    let plate = db::normalize_plate(&body.true_plate);
    if plate.is_empty() {
        return Err(ApiError::BadRequest(
            "true_plate must contain at least one alphanumeric character".to_owned(),
        ));
    }
    // Unknown camera -> 404 (otherwise the FK insert would surface as a 500).
    db::get_camera_lpr_config(state.pool(), body.camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {} not found", body.camera_id)))?;
    let truth = db::upsert_lpr_pass_truth(
        state.pool(),
        body.camera_id,
        crumb_common::lpr_ab::bucket_key(body.bucket_ts),
        &plate,
        admin.0.user_id,
    )
    .await
    .map_err(ApiError::Internal)?;
    Ok(Json(truth))
}

// ── admin: LPR enable/retention config (`/config/lpr`) ──────────────────────

/// `GET`/`PUT /config/lpr` response. Never exposes the ingest token itself —
/// only whether one is set.
#[derive(Debug, Serialize)]
pub struct LprConfigDto {
    pub enabled: bool,
    pub retention_days: i32,
    /// Watchlist/ignore match fuzziness (0 = exact, up to 0.5).
    pub watchlist_fuzz: f32,
    pub has_ingest_token: bool,
    pub version: i64,
}

impl From<LprSettings> for LprConfigDto {
    fn from(s: LprSettings) -> Self {
        Self {
            enabled: s.enabled,
            retention_days: s.retention_days,
            watchlist_fuzz: s.watchlist_fuzz,
            has_ingest_token: s.ingest_token.as_deref().is_some_and(|t| !t.is_empty()),
            version: s.version,
        }
    }
}

/// `PUT /config/lpr` body. Every field is optional: an omitted field is left at
/// its currently-stored value (a partial update must never reset the fields the
/// caller didn't mention).
#[derive(Debug, Deserialize)]
pub struct LprConfigUpdate {
    pub enabled: Option<bool>,
    pub retention_days: Option<i32>,
    pub watchlist_fuzz: Option<f32>,
}

/// `GET /config/lpr` — admin. The enable flag + retention window.
async fn get_lpr_config(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<LprConfigDto>, ApiError> {
    let s = db::get_lpr_settings(state.pool())
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("lpr_config row missing")))?;
    Ok(Json(s.into()))
}

/// `PUT /config/lpr` — admin. Toggle capture + set retention; bumps the version.
async fn put_lpr_config(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<LprConfigUpdate>,
) -> Result<Json<LprConfigDto>, ApiError> {
    // Load current settings and overlay only the fields the caller supplied, so
    // a partial body (e.g. `{"enabled": false}`) leaves retention/fuzz intact.
    let current = db::get_lpr_settings(state.pool())
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("lpr_config row missing")))?;

    let enabled = body.enabled.unwrap_or(current.enabled);
    let retention = body
        .retention_days
        .unwrap_or(current.retention_days)
        .clamp(1, 3650);
    let fuzz = body
        .watchlist_fuzz
        .unwrap_or(current.watchlist_fuzz)
        .clamp(0.0, 0.5);

    let s = db::update_lpr_settings(state.pool(), enabled, retention, fuzz, false, None)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(s.into()))
}

/// `GET /lpr/storage` response — the storage footprint of stored plate reads,
/// rendered by the admin console as a hint under the retention-days field
/// ("12,431 reads · ~1.8 GB of images · oldest 61 days").
#[derive(Debug, Serialize)]
pub struct LprStorageDto {
    /// Total stored plate reads.
    pub reads: i64,
    /// Total bytes of stored crop JPEGs (external-engine reads; Frigate reads
    /// carry a snapshot URL instead and contribute 0 here).
    pub crop_bytes: i64,
    /// Timestamp of the oldest stored read (`null` when there are none).
    pub oldest_ts: Option<DateTime<Utc>>,
}

/// `GET /lpr/storage` — admin. Aggregate `plate_reads` storage usage, so the
/// retention setting shows what it is actually pruning. Admin-only like the
/// `/config/lpr` card it decorates (it aggregates across ALL cameras, so it is
/// not camera-scoped like `/plates`).
async fn get_lpr_storage(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<LprStorageDto>, ApiError> {
    let (reads, crop_bytes, oldest_ts) = db::lpr_storage_stats(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(LprStorageDto {
        reads,
        crop_bytes,
        oldest_ts,
    }))
}

/// Query parameters for `GET /plates`.
#[derive(Debug, Deserialize)]
pub struct PlatesQuery {
    /// Comma-separated camera UUIDs (viewer-scoped).
    pub camera_ids: String,
    /// Optional window start (ISO 8601, inclusive).
    pub start: Option<DateTime<Utc>>,
    /// Optional window end (ISO 8601, exclusive).
    pub end: Option<DateTime<Utc>>,
    /// Optional plate search string (normalized server-side before matching).
    pub q: Option<String>,
    /// Match mode: `exact` | `prefix` | `contains` | `fuzzy`. Defaults to
    /// `contains` when `q` is present.
    #[serde(rename = "match")]
    pub match_mode: Option<String>,
    /// Max reads to return. Default 200, max 1 000.
    pub limit: Option<i64>,
    /// Reads to skip before returning `limit`. Default 0.
    pub offset: Option<i64>,
}

/// `GET /plates` response.
#[derive(Debug, Serialize)]
pub struct PlatesResponse {
    pub plates: Vec<PlateRead>,
    pub total: i64,
    pub has_more: bool,
}

/// `GET /plates?camera_ids=<csv>[&start=&end=&q=&match=&limit=&offset=]`
///
/// Lists plate reads for the requested cameras (viewer-scoped), newest first —
/// or by fuzzy closeness when `q` + `match=fuzzy`.
///
/// # Errors
///
/// * `400` — malformed UUIDs or `start >= end`.
/// * `401` / `403` — auth failure / missing `view_plates` capability.
async fn get_plates(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<PlatesQuery>,
) -> Result<Json<PlatesResponse>, ApiError> {
    user.require_view_plates()?;

    let requested = parse_uuid_csv(&q.camera_ids)?;
    let camera_ids = user.filter_camera_ids(&requested);
    if camera_ids.is_empty() {
        return Ok(Json(PlatesResponse {
            plates: vec![],
            total: 0,
            has_more: false,
        }));
    }

    if let (Some(s), Some(e)) = (q.start, q.end) {
        if s >= e {
            return Err(ApiError::BadRequest(
                "start must be strictly before end".to_owned(),
            ));
        }
    }

    const DEFAULT_LIMIT: i64 = 200;
    const MAX_LIMIT: i64 = 1_000;
    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let offset = q.offset.unwrap_or(0).max(0);

    // Normalize the search term the same way stored plates are normalized, so
    // exact/prefix/contains behave; drop it if it normalizes to empty.
    let plate =
        q.q.as_deref()
            .map(db::normalize_plate)
            .filter(|s| !s.is_empty());
    let match_mode = match q.match_mode.as_deref() {
        Some("exact") => db::PlateMatch::Exact,
        Some("prefix") => db::PlateMatch::Prefix,
        Some("fuzzy") => db::PlateMatch::Fuzzy,
        _ => db::PlateMatch::Contains,
    };

    let query = db::PlateReadQuery {
        camera_ids,
        start: q.start,
        end: q.end,
        plate,
        match_mode,
        limit,
        offset,
        // Corrected reads count as their canonical plate (issue #673).
        resolve_aliases: true,
    };

    let (plates, total) = db::list_plate_reads(state.pool(), &query)
        .await
        .map_err(ApiError::Internal)?;

    let has_more = offset.saturating_add(plates.len() as i64) < total;

    Ok(Json(PlatesResponse {
        plates,
        total,
        has_more,
    }))
}

/// Parse a comma-separated list of camera UUIDs, rejecting malformed entries.
fn parse_uuid_csv(csv: &str) -> Result<Vec<Uuid>, ApiError> {
    csv.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| {
            Uuid::parse_str(s).map_err(|_| ApiError::BadRequest(format!("invalid camera id: {s}")))
        })
        .collect()
}
