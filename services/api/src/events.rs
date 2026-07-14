// SPDX-License-Identifier: AGPL-3.0-or-later

//! Detection-event API endpoints.
//!
//! # Endpoints
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `GET`  | `/events` | Bearer | List detection events for cameras in a time window |
//! | `GET`  | `/events/{id}/snapshot` | Bearer or `?token=` | Proxy the event's snapshot JPEG |
//!
//! # Viewer scoping
//!
//! The `/events` handler enforces viewer camera scope: any camera the caller
//! cannot access is silently dropped from the result (returns zero rows, not
//! 403) — consistent with `/timeline`.
//!
//! # Empty / unconfigured
//!
//! When the detection feature is not running (no Frigate connected) the events
//! table is empty.  Both endpoints return gracefully:
//! - `GET /events` returns `{"events":[],"total":0,"has_more":false}`.
//! - `GET /events/{id}/snapshot` returns 404 (event does not exist).

use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crumb_common::db;

use crate::{auth_mw::AuthUser, error::ApiError, state::AppState};

/// Mount the authenticated JSON routes for detection events.
///
/// Mounted in `json_routes` (rate-limited, gzip-compressed, 30 s timeout).
/// Returns `GET /events`.
pub fn json_routes() -> Router<AppState> {
    Router::new().route("/events", get(get_events))
}

/// Mount the unauthenticated media routes for detection events.
///
/// Mounted in `media_routes` (no gzip, no timeout, no rate-limit — matches
/// the segment URL design: event IDs are opaque UUIDs).
/// Returns `GET /events/{id}/snapshot`.
pub fn media_routes() -> Router<AppState> {
    Router::new().route("/events/:id/snapshot", get(get_event_snapshot))
}

// ── /events query params & response ──────────────────────────────────────────

/// Query parameters for `GET /events`.
#[derive(Debug, Deserialize)]
pub struct EventsQuery {
    /// Comma-separated camera UUIDs (viewer-scoped).
    pub camera_ids: String,
    /// Window start (ISO 8601, inclusive).
    pub start: DateTime<Utc>,
    /// Window end (ISO 8601, exclusive).
    pub end: DateTime<Utc>,
    /// Optional comma-separated label filter (e.g. `person,car`).
    pub labels: Option<String>,
    /// Max events to return.  Default 500, max 2 000.
    pub limit: Option<i64>,
    /// Events to skip before returning `limit`.  Default 0.
    pub offset: Option<i64>,
}

/// A single detection event in the `/events` response.
///
/// This struct is the **locked CONTRACT** — every field name and type is
/// used by desktop, web, and Android clients verbatim.
#[derive(Debug, Serialize)]
pub struct DetectionEventDto {
    pub id: Uuid,
    pub camera_id: Uuid,
    /// Detection start time (ISO 8601).
    pub ts: DateTime<Utc>,
    /// Tracking end time, `null` while in progress.
    pub end_ts: Option<DateTime<Utc>>,
    /// Object class label, e.g. `"person"`, `"car"`.
    pub label: String,
    /// Client icon/colour selector derived server-side from `label`.
    ///
    /// Per-label: equals the normalised `label` slug (e.g. `"person"`, `"car"`,
    /// `"truck"`, `"bus"`, `"bicycle"`, `"cat"`, `"dog"`, `"license_plate"`,
    /// `"face"`, `"package"`).  Unknown labels yield their own slug; clients map
    /// each key to a designed glyph and fall back to a generic marker.
    pub icon_key: String,
    /// Provider sub-label (e.g. plate number), `null` when absent.
    pub sub_label: Option<String>,
    /// Detection confidence at persistence time (`0.0..=1.0`).
    pub score: f32,
    /// Highest confidence over the object's lifetime.
    pub top_score: f32,
    /// Zone names at detection time.
    pub zones: Vec<String>,
    /// Crumb API path for the snapshot JPEG, `null` when unavailable.
    ///
    /// Clients fetch `GET /events/{id}/snapshot` — they never need to talk
    /// to the detection provider directly.
    pub snapshot_url: Option<String>,
    /// Provider identifier, e.g. `"frigate"`.
    pub source_id: Option<String>,
}

/// `GET /events` response.
///
/// Empty window, unconfigured detection, or scoped-out cameras all return
/// `{"events":[],"total":0,"has_more":false}` — never an error.
#[derive(Debug, Serialize)]
pub struct EventsResponse {
    pub events: Vec<DetectionEventDto>,
    pub total: i64,
    pub has_more: bool,
}

// ── handlers ──────────────────────────────────────────────────────────────────

/// `GET /events?camera_ids=<csv>&start=<iso>&end=<iso>[&labels=<csv>][&limit=N][&offset=N]`
///
/// Returns detection events for the requested cameras within `[start, end)`.
/// Viewer camera scope is enforced; out-of-scope cameras return zero rows.
///
/// # Errors
///
/// * `400` — malformed UUIDs, `start >= end`, or invalid params.
/// * `401` / `403` — auth failure.
async fn get_events(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<EventsQuery>,
) -> Result<Json<EventsResponse>, ApiError> {
    // ── 1. parse & scope camera_ids ───────────────────────────────────────────
    let requested_ids = parse_uuid_csv(&q.camera_ids)?;
    let camera_ids = user.filter_camera_ids(&requested_ids);

    // Viewer has no overlap or all cameras out of scope → empty result.
    if camera_ids.is_empty() {
        return Ok(Json(EventsResponse {
            events: vec![],
            total: 0,
            has_more: false,
        }));
    }

    // ── 2. validate time range ────────────────────────────────────────────────
    if q.start >= q.end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }

    // ── 3. parse optional filters ─────────────────────────────────────────────
    const DEFAULT_LIMIT: i64 = 500;
    const MAX_LIMIT: i64 = 2_000;

    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let offset = q.offset.unwrap_or(0).max(0);

    let labels: Option<Vec<String>> = q.labels.as_deref().map(|s| {
        s.split(',')
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_owned)
            .collect()
    });

    // ── 4. query DB ───────────────────────────────────────────────────────────
    let query = db::DetectionEventQuery {
        camera_ids,
        start: q.start,
        end: q.end,
        labels,
        limit,
        offset,
    };

    let (rows, total) = db::list_detection_events(state.pool(), &query)
        .await
        .map_err(ApiError::Internal)?;

    let has_more = offset.saturating_add(rows.len() as i64) < total;

    // ── 5. map to DTOs ────────────────────────────────────────────────────────
    let events: Vec<DetectionEventDto> = rows
        .into_iter()
        .map(|row| DetectionEventDto {
            id: row.id,
            camera_id: row.camera_id,
            ts: row.ts,
            end_ts: row.end_ts,
            label: row.label,
            icon_key: row.icon_key,
            sub_label: row.sub_label,
            score: row.score,
            top_score: row.top_score.unwrap_or(row.score),
            zones: row.zones.unwrap_or_default(),
            snapshot_url: row.snapshot_url,
            source_id: row.source_id,
        })
        .collect();

    Ok(Json(EventsResponse {
        events,
        total,
        has_more,
    }))
}

/// `GET /events/{id}/snapshot`
///
/// Proxy the detection snapshot JPEG from the provider's URL stored in the
/// `events` table.  Authenticated via [`AuthUser`] (Bearer token or `?token=`
/// query-param fallback so `<img>` elements can authenticate without a custom
/// header). Camera scope is enforced: the event's `camera_id` is looked up and
/// `user.assert_camera_access` is called when a camera is present.
///
/// The Frigate API base is resolved in priority order:
/// 1. `server_settings.frigate_api_base` (DB, updated via admin UI).
/// 2. `frigate_config.api_base` (the Frigate-integration settings row, also
///    updated via admin UI).
/// 3. `FRIGATE_API_BASE` env (legacy fallback; no hardcoded IPs).
///
/// The `source_camera_name` column (BYO-Frigate camera mapping) is now
/// editable in the admin camera editor — no code change needed here; the DB
/// column is writable and `db::load_camera_name_map` already uses it.
///
/// Returns:
/// - `200 image/jpeg` — JPEG bytes proxied from the provider.
/// - `401` / `403` — auth / scope failure.
/// - `404` — event does not exist or has no snapshot.
/// - `502` — provider responded with an error.
async fn get_event_snapshot(
    user: AuthUser,
    State(state): State<AppState>,
    Path(event_id): Path<Uuid>,
) -> Result<Response, ApiError> {
    // Enforce camera scope when the event's camera is known.
    if let Some(camera_id) = db::get_event_camera_id(state.pool(), event_id)
        .await
        .map_err(ApiError::Internal)?
    {
        user.assert_camera_access(camera_id)?;
    }

    // Look up the stored snapshot URL.
    let provider_url = db::get_event_snapshot_url(state.pool(), event_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("event {event_id} has no snapshot")))?;

    // Resolve against the Frigate HTTP API base when the stored path is relative.
    //
    // #11: event snapshots are served by Frigate's own HTTP API (:5000), NOT the
    // go2rtc REST API (:1984).  Priority order:
    //   1. server_settings.frigate_http_api_base  — the new split field (migration 0014)
    //   2. server_settings.frigate_api_base        — legacy unified field (back-compat)
    //   3. frigate_config.api_base                 — Frigate integration settings row
    //   4. FRIGATE_API_BASE env                    — final legacy fallback
    // No hardcoded IPs; all paths lead through admin-editable DB values or env.
    let full_url = if provider_url.starts_with("http://") || provider_url.starts_with("https://") {
        provider_url
    } else {
        // Try server_settings first (the unified streaming-settings table).
        // Prefer the new `frigate_http_api_base` field; fall back to legacy
        // `frigate_api_base` when the new field is empty (pre-0014 row).
        let base_from_settings = crumb_common::db::get_server_settings(state.pool())
            .await
            .ok()
            .flatten()
            .and_then(|s| {
                // New field (migration 0014) takes priority — it points specifically
                // at Frigate's HTTP API (:5000).  If empty, fall back to the legacy
                // unified field which also pointed at Frigate HTTP in old installs.
                let http_api = s.frigate_http_api_base;
                if http_api.trim().is_empty() {
                    let legacy = s.frigate_api_base;
                    if legacy.trim().is_empty() {
                        None
                    } else {
                        Some(legacy)
                    }
                } else {
                    Some(http_api)
                }
            });

        // Then try the Frigate integration settings row.
        let base_from_frigate = if base_from_settings.is_none() {
            db::get_frigate_settings(state.pool())
                .await
                .ok()
                .flatten()
                .map(|f| f.api_base)
                .filter(|v| !v.trim().is_empty())
        } else {
            None
        };

        // Final fallback: FRIGATE_API_BASE env (legacy; empty by default in new installs).
        let base = base_from_settings
            .or(base_from_frigate)
            .unwrap_or_else(|| state.config().frigate_api_base.clone());
        let base = base.trim_end_matches('/');
        format!("{base}{provider_url}")
    };

    // Fetch from provider.
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("reqwest build: {e}")))?;

    // Upstream (Frigate) failures are gateway errors, not our bug: map them to
    // 502 (not 500) so a flapping/misconfigured provider doesn't read as an api
    // fault or trip 5xx-based alerting. `ApiError::BadGateway` logs the detail at
    // warn! and returns a generic message (no URL disclosure).
    let upstream = http_client
        .get(&full_url)
        .send()
        .await
        .map_err(|e| ApiError::BadGateway(format!("snapshot fetch: {e}")))?;

    if !upstream.status().is_success() {
        return Err(ApiError::BadGateway(format!(
            "snapshot provider returned HTTP {}",
            upstream.status()
        )));
    }

    // Cap the proxied body so a hostile/broken upstream can't OOM the api.
    let bytes = crate::channel_notify::read_body_capped(
        upstream,
        crate::channel_notify::MAX_SNAPSHOT_BYTES,
    )
    .await
    .map_err(|e| ApiError::BadGateway(format!("snapshot body: {e}")))?;

    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, "image/jpeg")],
        Body::from(bytes),
    )
        .into_response())
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn parse_uuid_csv(csv: &str) -> Result<Vec<Uuid>, ApiError> {
    csv.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| {
            s.parse::<Uuid>().map_err(|_| {
                ApiError::BadRequest(format!("'{s}' is not a valid UUID in camera_ids"))
            })
        })
        .collect()
}
