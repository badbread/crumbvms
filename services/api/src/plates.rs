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
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crumb_common::{
    db,
    types::{LprSettings, PlateRead, PlateWatchlistEntry},
};

use crate::{
    auth_mw::{AdminUser, AuthUser},
    error::ApiError,
    state::AppState,
};

/// Mount the authenticated JSON routes: `GET /plates` (view_plates-gated), the
/// admin `GET`/`PUT /config/lpr` enable toggle, and the plate-watchlist CRUD
/// (reads gated on `view_plates`, writes admin-only).
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
        .route("/lpr/ab-confirm", post(post_ab_confirm))
        .route("/config/lpr", get(get_lpr_config).put(put_lpr_config))
        .route("/config/lpr/rotate-token", post(rotate_lpr_token))
        .route(
            "/lpr/watchlist",
            get(get_watchlist).post(post_watchlist_entry),
        )
        .route(
            "/lpr/watchlist/:id",
            axum::routing::delete(delete_watchlist),
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
    user: AuthUser,
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
    let stats = lpr_ab::compute_stats(&reads, &passes, &truths);
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
        total_passes: stats.total_passes,
        both_seen: stats.both_seen,
        agreement_rate: stats.agreement_rate,
        frigate: stats.frigate.into(),
        crumb_alpr: stats.crumb_alpr.into(),
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
