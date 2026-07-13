// SPDX-License-Identifier: AGPL-3.0-or-later

//! License-plate reads API (`GET /plates`).
//!
//! Capability-gated on `view_plates` — Crumb's first capability-gated *read*
//! endpoint, because a searchable plate database is the most privacy-sensitive
//! surface. Camera-scoped exactly like `/events`: out-of-scope cameras are
//! dropped from the result, not 403'd. An empty window, LPR disabled, or a
//! scoped-out caller all return an empty page — never an error.

use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crumb_common::{
    db,
    types::{LprSettings, PlateRead},
};

use crate::{
    auth_mw::{AdminUser, AuthUser},
    error::ApiError,
    state::AppState,
};

/// Mount the authenticated JSON routes: `GET /plates` (view_plates-gated) and
/// the admin `GET`/`PUT /config/lpr` enable toggle.
///
/// Mounted in `json_routes` (rate-limited, gzip, 30 s timeout).
pub fn json_routes() -> Router<AppState> {
    Router::new()
        .route("/plates", get(get_plates))
        .route("/config/lpr", get(get_lpr_config).put(put_lpr_config))
}

// ── admin: LPR enable/retention config (`/config/lpr`) ──────────────────────

/// `GET`/`PUT /config/lpr` response. Never exposes the ingest token itself —
/// only whether one is set.
#[derive(Debug, Serialize)]
pub struct LprConfigDto {
    pub enabled: bool,
    pub retention_days: i32,
    pub has_ingest_token: bool,
    pub version: i64,
}

impl From<LprSettings> for LprConfigDto {
    fn from(s: LprSettings) -> Self {
        Self {
            enabled: s.enabled,
            retention_days: s.retention_days,
            has_ingest_token: s.ingest_token.as_deref().is_some_and(|t| !t.is_empty()),
            version: s.version,
        }
    }
}

/// `PUT /config/lpr` body.
#[derive(Debug, Deserialize)]
pub struct LprConfigUpdate {
    pub enabled: bool,
    #[serde(default = "default_retention_days")]
    pub retention_days: i32,
}

fn default_retention_days() -> i32 {
    90
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
    let retention = body.retention_days.clamp(1, 3650);
    let s = db::update_lpr_settings(state.pool(), body.enabled, retention, false, None)
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
