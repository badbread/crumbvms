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
    routing::get,
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
        .route("/config/lpr", get(get_lpr_config).put(put_lpr_config))
        .route(
            "/lpr/watchlist",
            get(get_watchlist).post(post_watchlist_entry),
        )
        .route(
            "/lpr/watchlist/:id",
            axum::routing::delete(delete_watchlist),
        )
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
