// SPDX-License-Identifier: AGPL-3.0-or-later

//! Per-camera utility endpoints.
//!
//! # Endpoints
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `GET`  | `/cameras/:id/frame.jpg` | Bearer or `?token=` | Live JPEG still proxied from the camera's go2rtc instance |
//!
//! # Auth
//!
//! [`AuthUser`] accepts both `Authorization: Bearer <jwt>` and `?token=<jwt>`.
//! The `?token=` fallback is required so Android's `Coil` image loader (and
//! any `<img>` element) can authenticate without setting a custom header.
//!
//! # go2rtc routing
//!
//! Cameras with `served_by = "crumb"` are owned by Crumb's own go2rtc
//! restreamer; the frame is fetched from the Crumb API base (`crumb_api` from
//! [`crate::go2rtc::resolve_bases`]). Cameras with `served_by = "frigate"` (or
//! any external go2rtc) use the Frigate API base. This mirrors the predicate used
//! by the live MSE proxy in [`crate::playback`] and the live-streams handler.

use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use uuid::Uuid;

use anyhow::Context as _;
use crumb_common::db;

use crate::{
    auth_mw::AuthUser, dto::ViewerCameraDto, error::ApiError, go2rtc::resolve_bases,
    state::AppState,
};

// ─── route registry ───────────────────────────────────────────────────────────

/// Mount per-camera utility routes.
///
/// These are media endpoints (single JPEG still, short-lived, uncacheable) and
/// belong in `media_routes` — no gzip, no 30 s JSON timeout.
pub fn routes() -> Router<AppState> {
    Router::new().route("/cameras/:id/frame.jpg", get(get_camera_frame))
}

/// Mount the viewer-facing camera-list route.
///
/// `GET /cameras` is a JSON route: rate-limited, gzip-compressed, 30 s timeout.
/// Wired in `json_routes` in `main.rs`.
pub fn json_routes() -> Router<AppState> {
    Router::new().route("/cameras", get(list_visible_cameras))
}

// ─── GET /cameras ────────────────────────────────────────────────────────────

/// `GET /cameras`
///
/// Returns the viewer-safe camera list. Admins receive every camera; viewers
/// receive only the cameras their assigned role grants access to (enforced via
/// [`AuthUser::can_access_camera`]).
///
/// Response is an array of [`ViewerCameraDto`] — credentials and internal
/// plumbing fields are never included. An empty array (not 403) is returned
/// when a viewer has no assigned cameras.
///
/// # Errors
///
/// * `401` / `403` — auth failure (invalid token or no token).
/// * `500` — database error loading the camera list.
async fn list_visible_cameras(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<ViewerCameraDto>>, ApiError> {
    let all = db::list_cameras_all(state.pool())
        .await
        .context("list_cameras_all")?;

    let dtos: Vec<ViewerCameraDto> = all
        .into_iter()
        .filter(|c| user.can_access_camera(c.id))
        .map(|c| ViewerCameraDto {
            id: c.id,
            name: c.name,
            enabled: c.enabled,
            has_sub: c.sub_url.is_some(),
            ptz: c.onvif_host.is_some(),
            camera_type: c.camera_type,
            icon: c.icon,
            served_by: c.served_by,
            created_at: c.created_at,
        })
        .collect();

    Ok(Json(dtos))
}

// ─── GET /cameras/:id/frame.jpg ───────────────────────────────────────────────

/// `GET /cameras/:id/frame.jpg`
///
/// Returns a single live JPEG still for the camera, proxied from whichever
/// go2rtc instance owns it.  The upstream URL is
/// `{go2rtc_api_base}/api/frame.jpeg?src={go2rtc_name}`.
///
/// # go2rtc routing
///
/// Cameras with `served_by = "crumb"` are fetched from Crumb's own go2rtc
/// (`crumb_api` resolved from DB `server_settings` with env fallback).
/// Cameras with `served_by = "frigate"` are fetched from the Frigate/external
/// go2rtc (`frigate_api`). The `go2rtc_name` is used as-is for the `src`
/// parameter (it is the relative stream name in both go2rtc instances).
///
/// # Auth
///
/// Fail-closed [`AuthUser`]: accepts `Authorization: Bearer <jwt>` or a scoped
/// media token via `?token=` (so a plain `<img>` can load it without a header).
/// A full login JWT via `?token=` is REJECTED (audit 2026-07-05 #2) — every
/// caller (native clients and the web console) mints a scoped media token
/// (`GET /media-token`) for per-camera media, so a login credential never lands
/// in a snapshot URL.
///
/// # Errors
///
/// * `401` / `403` — auth / scope failure.
/// * `404` — camera UUID not found in the database.
/// * `502` — go2rtc was unreachable, returned a non-2xx status, or the frame
///   body could not be read.  Detail is logged at `warn!`, not `error!`, so a
///   momentarily unavailable stream doesn't trip 5xx alerting.
async fn get_camera_frame(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
) -> Result<Response, ApiError> {
    // ── 1. scope check ────────────────────────────────────────────────────────
    user.assert_camera_access(camera_id)?;

    // ── 2. load camera row ────────────────────────────────────────────────────
    let cam = db::get_camera(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {camera_id} not found")))?;

    // ── 3. pick the correct go2rtc API base ───────────────────────────────────
    //
    // Use `served_by` instead of an RTSP-base prefix comparison. Cameras owned
    // by Crumb's restreamer use the Crumb API base; everything else (Frigate or
    // any externally managed go2rtc) uses the Frigate/external API base.
    // Both bases fall back to env config when the DB `server_settings` row has
    // empty values (fresh install / no admin config yet).
    // #11: The frame.jpeg endpoint hits the go2rtc REST API (:1984), NOT the
    // Frigate HTTP API (:5000).  Use `frigate_go2rtc_api` for frigate-served
    // cameras and `crumb_api` for Crumb-managed cameras.
    let b = resolve_bases(&state).await;
    let api_base = if cam.served_by == "frigate" {
        b.frigate_go2rtc_api.trim_end_matches('/').to_owned()
    } else {
        b.crumb_api.trim_end_matches('/').to_owned()
    };

    // ── 4. build upstream URL and fetch ───────────────────────────────────────
    //
    // go2rtc's frame endpoint: GET /api/frame.jpeg?src=<stream_name>
    // `go2rtc_name` is an ASCII identifier with no characters that need
    // percent-encoding, so a plain format string is safe here.
    let upstream_url = format!("{api_base}/api/frame.jpeg?src={}", cam.go2rtc_name);

    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .map_err(|e| {
            ApiError::Internal(anyhow::anyhow!("frame proxy: build reqwest client: {e}"))
        })?;

    // P0-GO2RTC (lighter lockdown): Crumb's own go2rtc REST API now requires
    // Basic auth (`local_auth: true` — this call crosses the Docker bridge
    // network, which go2rtc does not treat as "localhost"). Only send Crumb's
    // GO2RTC_USER/PASS to Crumb's OWN go2rtc; a Frigate-served camera's
    // external go2rtc is a separate BYO instance with its own credentials.
    let go2rtc_auth = (cam.served_by != "frigate").then(|| {
        (
            state.config().go2rtc_user.clone(),
            state.config().go2rtc_pass.clone(),
        )
    });

    // go2rtc starts a producer LAZILY: the first frame.jpeg for a cold stream
    // returns 500 while the source connects, then succeeds once a keyframe lands.
    // Retry a few times with a short delay so a cold camera loads on first touch
    // instead of leaning on the client to retry (and to keep the error logs quiet).
    const MAX_ATTEMPTS: u32 = 4;
    const RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(900);
    let mut frame = None;
    let mut last_status: Option<reqwest::StatusCode> = None;
    let mut last_err: Option<String> = None;
    for attempt in 1..=MAX_ATTEMPTS {
        let mut req = http_client.get(&upstream_url);
        if let Some((ref user, ref pass)) = go2rtc_auth {
            req = req.basic_auth(user, Some(pass));
        }
        match req.send().await {
            Ok(resp) if resp.status().is_success() => match resp.bytes().await {
                Ok(b) => {
                    frame = Some(b);
                    break;
                }
                Err(e) => last_err = Some(format!("body: {e}")),
            },
            Ok(resp) => last_status = Some(resp.status()),
            // `{:#}` on an anyhow-wrapped reqwest error prints the full source
            // chain ("error sending request ...: connection refused"), which a
            // bare reqwest Display hides — that cause is exactly what an
            // operator needs when go2rtc is down or the API base is wrong.
            Err(e) => last_err = Some(format!("connect: {:#}", anyhow::Error::new(e))),
        }
        if attempt < MAX_ATTEMPTS {
            tokio::time::sleep(RETRY_DELAY).await;
        }
    }
    let bytes = frame.ok_or_else(|| {
        ApiError::BadGateway(format!(
            "go2rtc frame ({upstream_url}) unavailable after {MAX_ATTEMPTS} tries (last status {last_status:?}{})",
            last_err.map(|e| format!(", {e}")).unwrap_or_default(),
        ))
    })?;

    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "image/jpeg"),
            // Live frame — never cache; each request should fetch a fresh still.
            (header::CACHE_CONTROL, "no-store"),
        ],
        Body::from(bytes),
    )
        .into_response())
}
