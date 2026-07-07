// SPDX-License-Identifier: AGPL-3.0-or-later

//! Playback routes — segment resolution, file serving, and live-stream brokering.
//!
//! # Endpoints
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `GET`  | `/play/{camera_id}` | Bearer | Resolve segment covering `ts`, return metadata |
//! | `GET`  | `/play/aligned` | Bearer | Aligned segment set for N cameras at `ts` |
//! | `GET`  | `/segments/{segment_id}` | Bearer | Serve segment file with HTTP range support |
//! | `GET`  | `/cameras/{camera_id}/streams` | Bearer | Return go2rtc live stream URLs |
//! | `GET`  | `/live/{camera_id}/stream.mp4` | Bearer / `?token=` | Authenticated live MSE proxy |
//!
//! # Security invariant — path traversal guard
//!
//! Every file-serve request resolves the segment's storage root (live or archive)
//! and verifies that the canonicalised absolute path starts with the canonicalised
//! storage root **before** any I/O on the file.  Any path that escapes the root
//! is rejected with 400 and a `tracing::warn!` entry.  The check uses
//! [`std::path::Path::starts_with`] on canonicalised paths so symlinks cannot
//! be exploited to leave the root.
//!
//! # HTTP range requests
//!
//! Segment files are served using [`tower_http::services::ServeFile`].
//! `ServeFile` handles `Range:` header parsing, `206 Partial Content` generation,
//! `Content-Range:` and `Accept-Ranges:` headers automatically.
//! We set `Content-Type: video/mp4` explicitly.
//!
//! # Live streaming
//!
//! `GET /cameras/{id}/streams` returns the go2rtc WebRTC and RTSP stream URLs
//! derived from the camera's `go2rtc_name` and the configured `go2rtc_rtsp_base`
//! / `go2rtc_api_base`; desktop (RTSP) and Android (RTSP) connect to go2rtc
//! directly.
//!
//! For browser clients, `GET /live/{id}/stream.mp4` proxies go2rtc's
//! fragmented-MP4 (MSE) output **through the API** for cameras served by
//! Crumb's own restreamer (so web-live for those cameras does not depend on,
//! or expose, Frigate's go2rtc). Frigate-fed cameras are still streamed by the
//! web client directly from go2rtc.

use std::path::{Path, PathBuf};

use axum::{
    body::Body,
    extract::{Path as AxumPath, Query, Request, State},
    response::Response,
    routing::{get, post},
    Json, Router,
};
use tower::ServiceExt as _;
use tower_http::services::ServeFile;
use uuid::Uuid;

use crumb_common::db;

use crate::{
    auth_mw::AuthUser,
    dto::{
        AlignedPlaybackQuery, LiveStreamQuery, LiveStreamsResponse, PlaybackQuery, ResolvedSegment,
    },
    error::ApiError,
    go2rtc::resolve_bases,
    state::AppState,
};

/// Mount playback routes.
///
/// Caller (`main.rs`) merges this at the router root.
///
/// # Route ordering note
///
/// `/play/aligned` is registered **before** `/play/{camera_id}` so that axum
/// matches the literal segment "aligned" before treating it as a UUID.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/play/aligned", get(play_aligned))
        .route("/play/:camera_id", get(play))
        .route("/segments/:segment_id", get(serve_segment))
        .route("/cameras/:camera_id/streams", get(live_streams))
        .route("/cameras/:camera_id/motion-grid", get(motion_grid))
        .route("/live/:camera_id/stream.mp4", get(live_stream_mp4))
        .route("/live/:camera_id/webrtc", post(live_webrtc))
}

// ─── /live/{camera_id}/stream.mp4 ─────────────────────────────────────────────

/// Shared HTTP client for the live MSE proxy.
///
/// Built once and reused (a `reqwest::Client` owns a connection pool + DNS
/// resolver; per-request construction is the documented anti-pattern). Timeout
/// shape is specific to an open-ended fMP4 stream:
/// * `connect_timeout` — bounds the TCP/TLS handshake (a fully-dead host fails fast).
/// * `read_timeout` — bounds time-to-first-byte AND any mid-stream read stall, so a
///   half-dead/wedged go2rtc that accepts the connection but never produces bytes is
///   reaped rather than pinning a task forever. It does NOT cap a healthy stream that
///   keeps delivering fragments.
/// * `.timeout()` is deliberately NOT set — it would kill the live stream after N seconds.
fn live_proxy_client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(5))
            .read_timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("build live-proxy reqwest client")
    })
}

/// `GET /live/{camera_id}/stream.mp4?stream=main|sub`
///
/// Authenticated live MSE proxy. Streams go2rtc's fragmented-MP4 output
/// (`/api/stream.mp4`) through the API so browser clients never connect to
/// go2rtc directly. The upstream go2rtc is chosen per-camera via `served_by`:
///
/// * `served_by = "crumb"` → proxy from `crumb_api` (Crumb's own restreamer,
///   reached over the internal compose network — go2rtc stays unexposed).
/// * `served_by = "frigate"` (or any external) → `frigate_api`.
///
/// Both bases are resolved from DB `server_settings` with env fallback so
/// docker-internal service names work with zero operator config on a fresh
/// install. This decouples web live-view from Frigate's go2rtc for restreamed
/// cameras without exposing a second unauthenticated service: every byte rides
/// the already-exposed, JWT-protected API. The browser's MSE `fetch()` cannot
/// set the `Authorization` header, so it authenticates via `?token=` (handled
/// by [`AuthUser`]). The route lives in `media_routes`, so the 30 s JSON timeout
/// does **not** apply to this open-ended stream.
///
/// # Errors
///
/// * `403` — caller cannot access this camera.
/// * `404` — camera not found, `stream=sub` requested for a camera with no sub
///   stream, or the upstream go2rtc has no such src registered.
/// * `502` — the upstream go2rtc was unreachable or returned a non-2xx (other
///   than 404). Logged at `warn!` so a flapping go2rtc doesn't trip 5xx alerts.
async fn live_stream_mp4(
    user: AuthUser,
    State(state): State<AppState>,
    AxumPath(camera_id): AxumPath<Uuid>,
    Query(q): Query<LiveStreamQuery>,
) -> Result<Response, ApiError> {
    user.require_playback()?;
    user.assert_camera_access(camera_id)?;

    let cam = db::get_camera(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {camera_id} not found")))?;

    // Resolve the stream selector → go2rtc src name. Reject sub when absent so
    // we don't open a 404-looping consumer.
    let want_sub = matches!(q.stream.as_deref(), Some("sub"));
    if want_sub && cam.sub_url.as_deref().is_none_or(str::is_empty) {
        return Err(ApiError::NotFound(format!(
            "camera {camera_id} has no sub stream"
        )));
    }
    let src = if want_sub {
        format!("{}_sub", cam.go2rtc_name)
    } else {
        cam.go2rtc_name.clone()
    };

    // Pick the upstream go2rtc API base from `served_by`. Bases are resolved
    // from DB server_settings with env fallback (see go2rtc::resolve_bases).
    //
    // #11: Frigate-served cameras use `frigate_go2rtc_api` (the go2rtc REST
    // base at :1984), NOT the Frigate HTTP API base (:5000).  Crumb-served
    // cameras use `crumb_api` (Crumb's own go2rtc restreamer).
    let b = resolve_bases(&state).await;
    let api_base = if cam.served_by == "frigate" {
        b.frigate_go2rtc_api.trim_end_matches('/').to_owned()
    } else {
        b.crumb_api.trim_end_matches('/').to_owned()
    };
    let upstream = format!("{api_base}/api/stream.mp4?src={src}");

    // P0-GO2RTC (lighter lockdown): go2rtc's REST API auth (`local_auth: true`)
    // applies to this call too — it crosses the Docker bridge network by
    // service name, which go2rtc does not treat as "localhost". Only send
    // Crumb's own GO2RTC_USER/PASS to Crumb's OWN go2rtc — a Frigate-served
    // camera's external go2rtc is a separate BYO instance with its own
    // (possibly absent) credentials Crumb doesn't own.
    let mut req = live_proxy_client().get(&upstream);
    if cam.served_by != "frigate" {
        req = req.basic_auth(
            &state.config().go2rtc_user,
            Some(&state.config().go2rtc_pass),
        );
    }
    let upstream_resp = req
        .send()
        .await
        .map_err(|e| ApiError::BadGateway(format!("go2rtc connect ({upstream}): {e}")))?;

    let status = upstream_resp.status();
    if !status.is_success() {
        // A genuinely-missing src (camera not registered in go2rtc yet, or a
        // `_sub` name mismatch) is a 404, not a server fault.
        return Err(if status == reqwest::StatusCode::NOT_FOUND {
            ApiError::NotFound(format!("go2rtc has no stream '{src}'"))
        } else {
            ApiError::BadGateway(format!("go2rtc returned {status} for {upstream}"))
        });
    }

    let content_type = upstream_resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("video/mp4")
        .to_owned();

    // Pipe go2rtc's fMP4 fragments straight through; backpressure is handled by
    // the stream so a slow client can't balloon memory.
    let body = Body::from_stream(upstream_resp.bytes_stream());

    Response::builder()
        .header(axum::http::header::CONTENT_TYPE, content_type)
        .header(axum::http::header::CACHE_CONTROL, "no-store")
        .body(body)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build response: {e}")))
}

// ─── /live/{camera_id}/webrtc ─────────────────────────────────────────────────

/// `POST /live/{camera_id}/webrtc?stream=main|sub`
///
/// Authenticated WebRTC **signaling** proxy. The client POSTs its SDP offer
/// (`Content-Type: application/sdp`); the API — after an [`AuthUser`] +
/// [`AuthUser::assert_camera_access`] check — forwards it to go2rtc's internal
/// `/api/webrtc?src=<stream>` SDP exchange and returns go2rtc's SDP answer. This
/// lets go2rtc's REST API (`:1984`) stay bound to loopback (unexposed) while
/// clients still negotiate WebRTC through the JWT/RBAC-protected API.
///
/// The browser's `fetch()` / native SDP POST cannot set the `Authorization`
/// header for a `<video>`-style element, so like the other media routes this
/// authenticates via `?token=` too (handled by [`AuthUser`]). The route lives in
/// `playback::routes()` which is merged into `media_routes`, so the 30 s JSON
/// timeout does not apply.
///
/// NOTE: only the SDP **signaling** rides through the API. The negotiated WebRTC
/// **media** (ICE) still flows to go2rtc's media port (`:8556`, advertised via
/// `WEBRTC_CANDIDATE`), which remains LAN-exposed — it carries only the video of
/// an already-authorized session and offers no stream-management surface. A
/// future phase can gate/relay that too (short-lived per-camera token or TURN).
///
/// # Errors
///
/// * `403` — caller cannot access this camera.
/// * `404` — camera not found, or `stream=sub` requested for a camera with no
///   sub stream.
/// * `502` — the upstream go2rtc was unreachable or returned an error status.
async fn live_webrtc(
    user: AuthUser,
    State(state): State<AppState>,
    AxumPath(camera_id): AxumPath<Uuid>,
    Query(q): Query<LiveStreamQuery>,
    offer: axum::body::Bytes,
) -> Result<Response, ApiError> {
    user.assert_camera_access(camera_id)?;

    let cam = db::get_camera(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {camera_id} not found")))?;

    // Resolve the stream selector → go2rtc src name. Reject sub when absent.
    let want_sub = matches!(q.stream.as_deref(), Some("sub"));
    if want_sub && cam.sub_url.as_deref().is_none_or(str::is_empty) {
        return Err(ApiError::NotFound(format!(
            "camera {camera_id} has no sub stream"
        )));
    }
    let src = if want_sub {
        format!("{}_sub", cam.go2rtc_name)
    } else {
        cam.go2rtc_name.clone()
    };

    // Pick the upstream go2rtc API base from `served_by` (resolved from DB
    // server_settings with env fallback → internal `http://recorder:1984`,
    // the recorder container hosting the embedded go2rtc).
    let b = resolve_bases(&state).await;
    let api_base = if cam.served_by == "frigate" {
        b.frigate_go2rtc_api.trim_end_matches('/').to_owned()
    } else {
        b.crumb_api.trim_end_matches('/').to_owned()
    };
    let upstream = format!("{api_base}/api/webrtc?src={src}");

    // Forward the SDP offer. go2rtc replies 200/201 + the SDP answer (the WHEP
    // exchange). A 15 s cap bounds a wedged go2rtc — the SDP round-trip is fast.
    // P0-GO2RTC (lighter lockdown): send Basic auth to Crumb's OWN go2rtc only
    // (its REST API auth applies to this internal, cross-bridge-network call);
    // a Frigate-served camera's external go2rtc is a separate BYO instance.
    let mut req = live_proxy_client()
        .post(&upstream)
        .header(reqwest::header::CONTENT_TYPE, "application/sdp")
        .header(reqwest::header::ACCEPT, "application/sdp")
        .timeout(std::time::Duration::from_secs(15));
    if cam.served_by != "frigate" {
        req = req.basic_auth(
            &state.config().go2rtc_user,
            Some(&state.config().go2rtc_pass),
        );
    }
    let upstream_resp =
        req.body(offer).send().await.map_err(|e| {
            ApiError::BadGateway(format!("go2rtc webrtc connect ({upstream}): {e}"))
        })?;

    let status = upstream_resp.status();
    if !status.is_success() {
        return Err(if status == reqwest::StatusCode::NOT_FOUND {
            ApiError::NotFound(format!("go2rtc has no stream '{src}'"))
        } else {
            ApiError::BadGateway(format!("go2rtc webrtc returned {status} for {upstream}"))
        });
    }

    let content_type = upstream_resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/sdp")
        .to_owned();

    let answer = upstream_resp
        .bytes()
        .await
        .map_err(|e| ApiError::BadGateway(format!("go2rtc webrtc answer read: {e}")))?;

    Response::builder()
        .header(axum::http::header::CONTENT_TYPE, content_type)
        .header(axum::http::header::CACHE_CONTROL, "no-store")
        .body(Body::from(answer))
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build response: {e}")))
}

// ─── /cameras/{camera_id}/motion-grid ───────────────────────────────────────────

/// `GET /cameras/{camera_id}/motion-grid` — latest live per-cell motion grid for
/// the camera (for the desktop motion tuner). Returns `null` if the recorder has
/// not published one yet (e.g. no sub-stream / motion disabled).
async fn motion_grid(
    user: AuthUser,
    State(state): State<AppState>,
    AxumPath(camera_id): AxumPath<Uuid>,
) -> Result<Json<Option<crumb_common::types::MotionGrid>>, ApiError> {
    user.require_playback()?;
    user.assert_camera_access(camera_id)?;
    let grid = db::read_motion_grid(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(grid))
}

// ─── /play/{camera_id} ────────────────────────────────────────────────────────

/// `GET /play/{camera_id}?ts=<iso8601>&stream=<main|sub>`
///
/// Resolves the segment whose `[start_ts, end_ts)` window contains `ts` for
/// the given camera and stream.  Returns a [`ResolvedSegment`] JSON body
/// containing a `/segments/{id}` URL that the client uses to fetch bytes (with
/// HTTP range support via [`serve_segment`]).
///
/// # Errors
///
/// * `400` — `stream` is not `"main"` or `"sub"`.
/// * `403` — caller cannot access this camera.
/// * `404` — no segment covers `ts` for this camera / stream combination.
async fn play(
    user: AuthUser,
    State(state): State<AppState>,
    AxumPath(camera_id): AxumPath<Uuid>,
    Query(q): Query<PlaybackQuery>,
) -> Result<Json<ResolvedSegment>, ApiError> {
    // ── capability + scope ────────────────────────────────────────────────────
    user.require_playback()?;
    user.assert_camera_access(camera_id)?;

    // ── 2. validate stream param ──────────────────────────────────────────────
    validate_stream(&q.stream)?;

    // ── 3. resolve segment from the index ─────────────────────────────────────
    let seg = db::resolve_segment(state.pool(), camera_id, q.ts, &q.stream)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| {
            ApiError::NotFound(format!(
                "no {} segment for camera {} at {}",
                q.stream, camera_id, q.ts
            ))
        })?;

    Ok(Json(segment_to_resolved(&seg)))
}

// ─── /play/aligned ────────────────────────────────────────────────────────────

/// `GET /play/aligned?camera_ids=<csv>&ts=<iso8601>&stream=<main|sub>`
///
/// Resolves one segment per camera at the same `ts`, enabling multi-camera
/// synced playback.  Camera UUIDs that the caller cannot access are silently
/// dropped (viewer scope).  Cameras for which no segment covers `ts` are
/// omitted from the response — this is not an error.
///
/// # Errors
///
/// * `400` — `camera_ids` is empty / contains a malformed UUID, or `stream` is
///   not `"main"` or `"sub"`.
async fn play_aligned(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<AlignedPlaybackQuery>,
) -> Result<Json<Vec<ResolvedSegment>>, ApiError> {
    // ── capability gate ───────────────────────────────────────────────────────
    user.require_playback()?;

    // ── 1. parse + scope filter ───────────────────────────────────────────────
    let requested = parse_uuid_csv(&q.camera_ids)?;
    if requested.is_empty() {
        return Err(ApiError::BadRequest(
            "camera_ids must contain at least one UUID".to_owned(),
        ));
    }
    let camera_ids = user.filter_camera_ids(&requested);

    // ── 2. validate stream ────────────────────────────────────────────────────
    validate_stream(&q.stream)?;

    // ── 3. resolve all cameras concurrently (pool-checkout bounded) ────────────
    // A shared semaphore caps how many of these per-camera resolves can hold a
    // DB connection at once, so a burst of multi-camera aligned-playback requests
    // cannot spawn unbounded tasks that starve the pool (audit Risk #1).
    let pool = state.pool().clone();
    let ts = q.ts;
    let stream = q.stream.clone();
    let sem = state.play_semaphore();

    let mut handles = Vec::with_capacity(camera_ids.len());
    for cam_id in camera_ids {
        let pool = pool.clone();
        let stream = stream.clone();
        let sem = sem.clone();
        handles.push(tokio::spawn(async move {
            // Hold a permit only while the DB checkout/query is in flight.
            // `acquire` only errors if the semaphore is closed (never, here);
            // on the impossible error we proceed unbounded rather than fail.
            let _permit = sem.acquire().await.ok();
            db::resolve_segment(&pool, cam_id, ts, &stream).await
        }));
    }

    let mut resolved: Vec<ResolvedSegment> = Vec::with_capacity(handles.len());
    for handle in handles {
        match handle.await {
            Ok(Ok(Some(seg))) => resolved.push(segment_to_resolved(&seg)),
            Ok(Ok(None)) => { /* camera has no segment at ts — omit silently */ }
            Ok(Err(e)) => return Err(ApiError::Internal(e)),
            Err(join_err) => {
                return Err(ApiError::Internal(anyhow::anyhow!(
                    "task join error in play_aligned: {join_err}"
                )));
            }
        }
    }

    Ok(Json(resolved))
}

// ─── /segments/{segment_id} ───────────────────────────────────────────────────

/// `GET /segments/{segment_id}` — serve the fMP4 file with HTTP range support.
///
/// 1. Loads the segment row from the DB by UUID.
/// 2. Verifies the caller can access the owning camera.
/// 3. Constructs the absolute path from the storage root:
///    `absolute = storage_root(seg.stage) / seg.path`
/// 4. Runs the **path-traversal guard** — rejects with 400 if the canonicalised
///    path escapes the storage root.
/// 5. Forwards the full HTTP request (including any `Range:` header) to
///    [`ServeFile`], which handles range parsing and 206 responses.
///
/// # Wire details
///
/// * `Content-Type: video/mp4` (set via `ServeFile::new_with_mime`)
/// * `Accept-Ranges: bytes` (added by `ServeFile` automatically)
/// * `206 Partial Content` + `Content-Range:` on valid Range requests
///
/// # Errors
///
/// * `400` — path traversal detected (also emits `WARN` log).
/// * `403` — caller cannot access the camera that owns this segment.
/// * `404` — segment row not found in DB, or the file is missing on disk.
/// * `500` — storage root cannot be canonicalised (misconfigured mount).
async fn serve_segment(
    user: AuthUser,
    State(state): State<AppState>,
    AxumPath(segment_id): AxumPath<Uuid>,
    req: Request,
) -> Result<Response, ApiError> {
    // ── capability gate ───────────────────────────────────────────────────────
    user.require_playback()?;

    // ── 1. load the segment row ───────────────────────────────────────────────
    let seg = db::get_segment(state.pool(), segment_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("segment {segment_id} not found")))?;

    // ── 2. camera access guard ────────────────────────────────────────────────
    user.assert_camera_access(seg.camera_id)?;

    // ── 3. resolve storage root ───────────────────────────────────────────────
    // A segment's physical location is defined SOLELY by its storage_id (→
    // storages.path). Resolve the file from that row (authoritative); a repointed
    // live_storage puts footage on a disk that no longer matches its `stage`, so a
    // stage→mount guess would serve the WRONG disk (or 404). If the storage row is
    // missing (should never happen — NOT NULL + ON DELETE RESTRICT FK), FAIL LOUDLY
    // rather than guessing a mount — guessing is the original migration bug.
    let storage = db::get_storage(state.pool(), seg.storage_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!(
                "segment {segment_id} storage row missing (storage_id={}); refusing to guess a mount",
                seg.storage_id
            ))
        })?;
    let storage_root = PathBuf::from(storage.path);

    // ── 4. build and guard the absolute file path ─────────────────────────────
    // `seg.path` is a relative path within the storage root.
    // Must not allow ".." escape sequences.
    let absolute = storage_root.join(&seg.path);
    let safe_path = guard_path_traversal(&storage_root, &absolute, segment_id)?;

    // ── 5. serve via ServeFile (handles Range / Accept-Ranges / 206) ──────────
    // ServeFile guesses Content-Type from the file extension (.mp4 -> video/mp4)
    // via mime_guess, so no explicit mime constant is needed. ServeFile is a tower
    // Service<Request>, so we call `.oneshot(req)` with the original axum request
    // (which carries the Range header if the client sent one).
    let svc = ServeFile::new(&safe_path);

    // Call the service and map the response body to axum's Body type.
    // ServeFile::oneshot is infallible (error type = Infallible).
    let sf_response = svc
        .oneshot(req)
        .await
        // Infallible — the ? can never trigger but satisfies the type system.
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("ServeFile error: {e}")))?;

    // Map the opaque ServeFileBody into axum's Body so the response implements
    // IntoResponse.  axum::body::Body::new accepts any http_body::Body.
    let (parts, body) = sf_response.into_parts();
    let axum_body = Body::new(body);
    Ok(Response::from_parts(parts, axum_body))
}

// ─── /cameras/{camera_id}/streams ─────────────────────────────────────────────

/// `GET /cameras/{camera_id}/streams`
///
/// Returns the live stream URLs for a camera:
///
/// * **RTSP** (`rtsp_main_url` / `rtsp_sub_url`): resolved via
///   `crumb_common::db::resolve_stream_url`. go2rtc's RTSP listener now
///   requires auth (P0-GO2RTC lighter lockdown — see `go2rtc/go2rtc.yaml`), so
///   for Crumb-owned cameras (`served_by != "frigate"`) the API embeds
///   `GO2RTC_USER`/`GO2RTC_PASS` into the authority
///   (`rtsp://user:pass@host:18554/<name>`) via
///   `crumb_common::db::inject_rtsp_credentials`. Desktop (`libmpv`) and Android
///   (`ExoPlayer`) both accept userinfo-in-URL RTSP credentials natively, so this
///   requires **zero client changes**. Frigate-served cameras are untouched
///   (a separate BYO go2rtc with its own, possibly absent, credentials).
/// * **WebRTC**: `POST /live/{camera_id}/webrtc?stream=main|sub` — the API's
///   own authenticated SDP-exchange proxy (API-relative). go2rtc's REST API
///   has no LAN host-publish, so clients no longer hit it directly; the API
///   brokers the offer/answer after an `assert_camera_access` check.
///
/// # Errors
///
/// * `403` — caller cannot access this camera.
/// * `404` — camera not found in the DB.
async fn live_streams(
    user: AuthUser,
    State(state): State<AppState>,
    AxumPath(camera_id): AxumPath<Uuid>,
) -> Result<Json<LiveStreamsResponse>, ApiError> {
    // ── 1. scope check ────────────────────────────────────────────────────────
    user.assert_camera_access(camera_id)?;

    // ── 2. load camera ────────────────────────────────────────────────────────
    let cam = db::get_camera(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {camera_id} not found")))?;

    // ── 3. resolve bases (DB server_settings with env fallback) ───────────────
    //
    // RTSP bases (crumb_rtsp / frigate_rtsp) are resolved here for the native
    // RTSP URLs below. The go2rtc REST base is NOT needed anymore: WebRTC
    // signaling goes through the API's own `/live/{id}/webrtc` proxy rather than
    // a client-reachable go2rtc URL (go2rtc's REST API has no LAN host-publish).
    let b = resolve_bases(&state).await;
    // P0-GO2RTC (lighter lockdown): embed Crumb's go2rtc RTSP credentials into
    // the CRUMB base only — never into frigate_rtsp (a separate BYO instance).
    let crumb_rtsp_authed = crumb_common::db::inject_rtsp_credentials(
        &b.crumb_rtsp,
        &state.config().go2rtc_user,
        &state.config().go2rtc_pass,
    );

    // ── 4. build stream URLs ──────────────────────────────────────────────────
    // RTSP URLs are resolved via the canonical helper so legacy rows (absolute
    // URLs in main_url / sub_url) pass through unchanged and new rows (relative
    // names) are expanded correctly using the appropriate RTSP base.
    //
    // IMPORTANT (#3 fix): resolve RTSP from cam.main_url / cam.sub_url rather
    // than go2rtc_name.  Legacy cameras store absolute URLs in main_url — if we
    // used go2rtc_name (a relative stream name like "driveway") we would produce
    // "rtsp://go2rtc:8554/driveway" instead of passing the absolute URL through,
    // breaking desktop/Android live view for all legacy-URL cameras.
    //
    // NOTE: a legacy served_by='crumb' row whose main_url/sub_url is already a
    // full absolute URL (pre-migration-0012 format, no embedded creds) passes
    // through resolve_stream_url unchanged — it will NOT get credentials
    // injected (inject_rtsp_credentials only touches the *base*, and the
    // absolute-URL branch never consults the base at all). Such a legacy row
    // will fail RTSP auth once go2rtc's auth is enabled; re-saving the camera
    // in the admin UI (which rewrites main_url to a relative name) resolves it.
    let rtsp_main_url = crumb_common::db::resolve_stream_url(
        &cam.served_by,
        &cam.main_url,
        &crumb_rtsp_authed,
        &b.frigate_rtsp,
    );

    // Only expose a sub RTSP URL if the camera actually has a sub stream
    // configured.  Resolve from cam.sub_url (which may be absolute or relative)
    // rather than synthesising a `_sub` name — synthesised names can differ from
    // the actual go2rtc stream name for legacy cameras.
    let rtsp_sub_url = cam
        .sub_url
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(|sub_stream| {
            crumb_common::db::resolve_stream_url(
                &cam.served_by,
                sub_stream,
                &crumb_rtsp_authed,
                &b.frigate_rtsp,
            )
        });

    // WebRTC signaling now goes through the AUTHENTICATED API proxy
    // (`POST /live/{camera_id}/webrtc?stream=main|sub`), NOT directly at
    // go2rtc's REST API — go2rtc's :1984 has no LAN host-publish (see
    // docker-compose.yml P0-GO2RTC lockdown). The API brokers the SDP exchange
    // after an AuthUser + assert_camera_access check; only the negotiated media
    // (ICE :8556) still reaches go2rtc directly. Clients POST their SDP offer to
    // these (API-relative) URLs.
    let webrtc_main_url = Some(format!("/live/{camera_id}/webrtc?stream=main"));
    let webrtc_sub_url = if cam.sub_url.as_deref().is_some_and(|s| !s.is_empty()) {
        Some(format!("/live/{camera_id}/webrtc?stream=sub"))
    } else {
        None
    };

    Ok(Json(LiveStreamsResponse {
        camera_id,
        webrtc_main_url,
        webrtc_sub_url,
        rtsp_main_url,
        rtsp_sub_url,
    }))
}

// ─── private helpers ──────────────────────────────────────────────────────────

/// Convert a [`crumb_common::Segment`] to the [`ResolvedSegment`] DTO.
///
/// The `url` field is the `/segments/{id}` URL the client uses to retrieve the
/// file bytes (with HTTP range support via [`serve_segment`]).
fn segment_to_resolved(seg: &crumb_common::Segment) -> ResolvedSegment {
    ResolvedSegment {
        camera_id: seg.camera_id,
        segment_id: seg.id,
        url: format!("/segments/{}", seg.id),
        start: seg.start_ts,
        end: seg.end_ts,
        duration_ms: seg.duration_ms,
        has_motion: seg.has_motion,
    }
}

/// Assert that `stream` is `"main"` or `"sub"`, returning 400 otherwise.
fn validate_stream(stream: &str) -> Result<(), ApiError> {
    match stream {
        "main" | "sub" => Ok(()),
        other => Err(ApiError::BadRequest(format!(
            "stream must be 'main' or 'sub', got '{other}'"
        ))),
    }
}

/// Parse a comma-separated string of UUID values.
///
/// Returns `Err(ApiError::BadRequest)` if any non-empty token is not a valid
/// UUID.  Leading/trailing whitespace around each token is trimmed before
/// parsing.
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

/// Verify that `absolute` is contained within `storage_root` after
/// canonicalisation (symlinks resolved, `..` collapsed).
///
/// Returns the canonicalised path on success.
///
/// # Errors
///
/// * `ApiError::Internal` — if the storage root path cannot be canonicalised
///   (mount point missing — infrastructure bug).
/// * `ApiError::NotFound` — if the file does not exist on disk.
/// * `ApiError::BadRequest` (400) — if the resolved path escapes the root; also
///   emits a `tracing::warn!` so the attempt is visible in the operator logs.
fn guard_path_traversal(
    storage_root: &Path,
    absolute: &Path,
    segment_id: Uuid,
) -> Result<PathBuf, ApiError> {
    // Canonicalise the storage root.  Required for the starts_with check to be
    // meaningful (the root must not itself contain symlinks that bypass the check).
    let canonical_root = storage_root.canonicalize().map_err(|e| {
        ApiError::Internal(anyhow::anyhow!(
            "cannot canonicalise storage root '{}': {e}",
            storage_root.display()
        ))
    })?;

    // Canonicalise the target path.  This resolves symlinks and collapses `..`.
    // If the file does not exist, `canonicalize` returns `NotFound`.
    let canonical_target = absolute.canonicalize().map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            ApiError::NotFound(format!(
                "segment {segment_id} file not found (expected at '{}')",
                absolute.display()
            ))
        } else {
            ApiError::Internal(anyhow::anyhow!(
                "cannot canonicalise segment path '{}': {e}",
                absolute.display()
            ))
        }
    })?;

    // The traversal check: reject if the file is not under the storage root.
    if !canonical_target.starts_with(&canonical_root) {
        tracing::warn!(
            %segment_id,
            raw_path            = %absolute.display(),
            canonical_target    = %canonical_target.display(),
            canonical_root      = %canonical_root.display(),
            "PATH TRAVERSAL ATTEMPT: segment path escapes storage root — request rejected"
        );
        return Err(ApiError::BadRequest(
            "segment path is outside the storage root".to_owned(),
        ));
    }

    Ok(canonical_target)
}

// ─── unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use crumb_common::{Segment, SegmentStage, SegmentStream};

    fn make_seg() -> Segment {
        let now = Utc::now();
        Segment {
            id: Uuid::new_v4(),
            camera_id: Uuid::new_v4(),
            storage_id: Uuid::new_v4(),
            stage: SegmentStage::Live,
            path: "cam/seg.mp4".to_owned(),
            stream: SegmentStream::Main,
            start_ts: now,
            end_ts: now,
            duration_ms: 4_000,
            has_motion: false,
            size_bytes: 1024,
            motion_bbox: None,
        }
    }

    // ── validate_stream ───────────────────────────────────────────────────────

    #[test]
    fn test_validate_stream_valid() {
        assert!(validate_stream("main").is_ok());
        assert!(validate_stream("sub").is_ok());
    }

    #[test]
    fn test_validate_stream_invalid() {
        assert!(validate_stream("hd").is_err());
        assert!(validate_stream("").is_err());
        // Case-sensitive: the DB constraint is lowercase only.
        assert!(validate_stream("Main").is_err());
        assert!(validate_stream("SUB").is_err());
    }

    // ── parse_uuid_csv ────────────────────────────────────────────────────────

    #[test]
    fn test_parse_uuid_csv_single() {
        let id = Uuid::new_v4();
        let ids = parse_uuid_csv(&id.to_string()).unwrap();
        assert_eq!(ids, vec![id]);
    }

    #[test]
    fn test_parse_uuid_csv_multiple() {
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        let csv = format!("{id1},{id2}");
        let ids = parse_uuid_csv(&csv).unwrap();
        assert_eq!(ids, vec![id1, id2]);
    }

    #[test]
    fn test_parse_uuid_csv_whitespace_trimmed() {
        let id = Uuid::new_v4();
        let csv = format!("  {id}  ");
        let ids = parse_uuid_csv(&csv).unwrap();
        assert_eq!(ids, vec![id]);
    }

    #[test]
    fn test_parse_uuid_csv_empty_tokens_ignored() {
        let id = Uuid::new_v4();
        let csv = format!(",{id},");
        let ids = parse_uuid_csv(&csv).unwrap();
        assert_eq!(ids, vec![id]);
    }

    #[test]
    fn test_parse_uuid_csv_invalid() {
        let result = parse_uuid_csv("not-a-uuid");
        assert!(matches!(result, Err(ApiError::BadRequest(_))));
    }

    // ── segment_to_resolved ───────────────────────────────────────────────────

    #[test]
    fn test_segment_to_resolved_url_format() {
        let seg = make_seg();
        let resolved = segment_to_resolved(&seg);
        assert_eq!(resolved.url, format!("/segments/{}", seg.id));
        assert_eq!(resolved.camera_id, seg.camera_id);
        assert_eq!(resolved.segment_id, seg.id);
        assert_eq!(resolved.duration_ms, seg.duration_ms);
        assert_eq!(resolved.has_motion, seg.has_motion);
    }

    // ── guard_path_traversal ──────────────────────────────────────────────────

    /// On Linux containers (the deployment target) /tmp always exists.
    #[test]
    #[cfg(unix)]
    fn test_guard_valid_path_inside_root() {
        let root = Path::new("/tmp");
        // /tmp is inside /tmp.
        let inside = PathBuf::from("/tmp");
        let seg_id = Uuid::new_v4();
        let result = guard_path_traversal(root, &inside, seg_id);
        assert!(result.is_ok(), "path inside root must pass the guard");
    }

    #[test]
    #[cfg(unix)]
    fn test_guard_traversal_via_dotdot() {
        // /tmp/../etc canonicalises to /etc, which is outside /tmp.
        // This only works if /etc exists — which it always does on Linux.
        let root = Path::new("/tmp");
        let escape = PathBuf::from("/tmp/../etc");
        if escape.canonicalize().is_ok() {
            let seg_id = Uuid::new_v4();
            let result = guard_path_traversal(root, &escape, seg_id);
            assert!(
                matches!(result, Err(ApiError::BadRequest(_))),
                "traversal via .. must be rejected with 400"
            );
        }
    }

    #[test]
    #[cfg(unix)]
    fn test_guard_missing_file_returns_not_found() {
        let root = Path::new("/tmp");
        let missing = PathBuf::from("/tmp/this_file_should_not_exist_crumb_test_xyz");
        let seg_id = Uuid::new_v4();
        let result = guard_path_traversal(root, &missing, seg_id);
        assert!(
            matches!(result, Err(ApiError::NotFound(_))),
            "missing file must map to 404, got: {result:?}"
        );
    }
}
