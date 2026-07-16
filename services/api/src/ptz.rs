// SPDX-License-Identifier: AGPL-3.0-or-later

//! PTZ (pan/tilt/zoom) control endpoint.
//!
//! # Endpoint
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `POST` | `/cameras/:id/ptz` | Bearer | Send a PTZ command to an ONVIF camera |
//!
//! # Request body
//!
//! ```json
//! { "action": "move",
//!   "pan": 0.5, "tilt": -0.25, "zoom": 0.0 }
//! ```
//!
//! ```json
//! { "action": "stop" }
//! ```
//!
//! ```json
//! { "action": "preset", "preset": "1" }
//! ```
//!
//! ```json
//! { "action": "presets" }
//! ```
//!
//! # Responses
//!
//! * `200 {}` for `move`, `stop`, `preset`.
//! * `200 {"presets":[{"token":"1","name":"Entrance"},...]}` for `action=presets`.
//! * `404` if the camera has no ONVIF PTZ configuration (`camera is not PTZ`).
//! * `400` for invalid action / missing required fields.
//! * `502` (mapped to [`ApiError::Internal`]) for ONVIF communication errors.
//!
//! # ONVIF config source
//!
//! ONVIF credentials are resolved per-request in priority order:
//!
//! 1. **DB columns** — `cameras.onvif_host`, `onvif_port`, `onvif_user`,
//!    `onvif_password` (set via the admin camera editor or `redetect`).
//! 2. **Env fallback** — the legacy `ONVIF_CONFIG` / `ONVIF_CONFIG_B64` JSON
//!    map keyed by `go2rtc_name`, parsed at startup into
//!    [`ApiConfig::onvif_cameras`]. This path is retained for backwards
//!    compatibility with existing deployments; DB columns take precedence.
//!
//! Example env value:
//!
//! ```json
//! {"lpr":{"host":"198.51.100.6","port":80,"user":"admin","password":"secret"}}
//! ```
//!
//! # ONVIF implementation notes
//!
//! The handler performs one ONVIF round-trip sequence per request:
//!
//! 1. Build a device-management client at `http://{host}:{port}/onvif/device_service`.
//! 2. Call `GetServices` to discover the media and PTZ `XAddr` endpoints.
//! 3. Build media + PTZ clients from the discovered `XAddrs`.
//! 4. Call `GetProfiles` on the media client; use the first profile's token.
//! 5. Execute the requested PTZ action.
//!
//! This is stateless (no persistent connection) which is safe for the low
//! request rate of a PTZ joystick.  If latency becomes a concern, a connection
//! pool keyed by `go2rtc_name` can be added later.

use axum::{
    extract::{Path, State},
    routing::post,
    Json, Router,
};
use onvif::soap::client::{AuthType, ClientBuilder, Credentials};
use serde::{Deserialize, Serialize};
use tracing::{debug, instrument, warn};
use url::Url;
use uuid::Uuid;

use crumb_common::db;

use crate::{auth_mw::AuthUser, error::ApiError, state::AppState};

// ─── public config type (also used in config.rs) ─────────────────────────────

/// ONVIF connection parameters for one PTZ-capable camera.
///
/// Populated at startup from the `ONVIF_CONFIG` environment variable.
#[derive(Debug, Clone, Deserialize)]
pub struct OnvifCameraConfig {
    /// Camera host — IP or hostname (no scheme, no port).
    pub host: String,
    /// ONVIF HTTP port (typically `80`).
    pub port: u16,
    /// ONVIF username.
    pub user: String,
    /// ONVIF password (plain text — stored in memory only, never logged).
    pub password: String,
}

// ─── DTOs ────────────────────────────────────────────────────────────────────

/// `POST /cameras/:id/ptz` request body.
#[derive(Debug, Deserialize)]
pub struct PtzRequest {
    /// The PTZ action to perform.
    pub action: PtzAction,
    /// Pan velocity in `[-1.0, 1.0]`.  Only used for `action = "move"`.
    #[serde(default)]
    pub pan: f32,
    /// Tilt velocity in `[-1.0, 1.0]`.  Only used for `action = "move"`.
    #[serde(default)]
    pub tilt: f32,
    /// Zoom velocity in `[-1.0, 1.0]`.  Only used for `action = "move"`.
    #[serde(default)]
    pub zoom: f32,
    /// Preset token string.  Required for `action = "preset"`.
    #[serde(default)]
    pub preset: Option<String>,
}

/// Discriminant for the PTZ action.
#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PtzAction {
    /// Start continuous movement (velocities in `pan`, `tilt`, `zoom`).
    Move,
    /// Stop all ongoing movement.
    Stop,
    /// Go to a named preset (`preset` field contains the token).
    Preset,
    /// Go to the camera's configured home position.
    Home,
    /// List all presets for this camera.
    Presets,
}

/// A single PTZ preset returned by `action = "presets"`.
#[derive(Debug, Serialize)]
pub struct PtzPresetDto {
    /// ONVIF preset token (camera-assigned identifier).
    pub token: String,
    /// Human-readable preset name (may be empty if the camera did not set one).
    pub name: String,
}

/// Response body for `POST /cameras/:id/ptz`.
///
/// `{}` for `move`, `stop`, `preset`; `{"presets":[...]}` for `presets`.
#[derive(Debug, Serialize)]
pub struct PtzResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub presets: Option<Vec<PtzPresetDto>>,
}

// ─── route registration ───────────────────────────────────────────────────────

/// Mount PTZ routes onto the root router.
///
/// Caller (`main.rs`) merges this at the router root via `.merge(ptz::routes())`.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/cameras/:id/ptz", post(ptz_command))
        .route("/cameras/:id/imaging", post(imaging_command))
}

// ─── handler ─────────────────────────────────────────────────────────────────

/// `POST /cameras/:id/ptz` — execute a PTZ command on an ONVIF camera.
///
/// # ONVIF credential resolution
///
/// DB columns (`onvif_host`, `onvif_port`, `onvif_user`, `onvif_password`) take
/// priority over the legacy `ONVIF_CONFIG` / `ONVIF_CONFIG_B64` env vars. The
/// env map is retained as a one-time fallback for existing deployments that
/// populated it before the DB columns were added. DB wins; env is a fallback.
///
/// # Errors
///
/// * `400` — unsupported `action` or missing required fields.
/// * `401` / `403` — standard auth failures.
/// * `404` — camera does not exist in the DB, or has no ONVIF PTZ config in DB
///   or env.
/// * `500` — ONVIF communication error or unexpected internal failure.
#[instrument(skip_all, fields(camera_id = %camera_id))]
async fn ptz_command(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
    Json(body): Json<PtzRequest>,
) -> Result<Json<PtzResponse>, ApiError> {
    // ── 1. enforce capability + camera access ─────────────────────────────────
    user.require_ptz()?;
    user.assert_camera_access(camera_id)?;

    // ── 2. load camera from DB ────────────────────────────────────────────────
    let camera = db::get_camera(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {camera_id} not found")))?;

    // ── 2b. defense in depth: honor the per-camera PTZ-controls toggle ────────
    // The clients already hide PTZ when `camera.ptz` is false, but a stale client
    // (or a hand-crafted request) must not be able to drive a camera whose PTZ
    // the operator turned off. Reject before touching the network (migration 0061).
    ensure_ptz_enabled(&camera)?;

    // ── 3. resolve ONVIF config (DB columns → env fallback) ───────────────────
    let onvif_cfg = resolve_onvif_config(&state, &camera)?;

    // ── 4. validate action-specific fields before hitting the network ─────────
    if body.action == PtzAction::Preset && body.preset.as_deref().is_none_or(str::is_empty) {
        return Err(ApiError::BadRequest(
            "action 'preset' requires a non-empty 'preset' token field".to_owned(),
        ));
    }

    // ── 5. build ONVIF clients via service discovery ──────────────────────────
    let (media_client, ptz_client) = build_onvif_clients(&onvif_cfg).await.map_err(|e| {
        warn!(
            camera_id = %camera_id,
            go2rtc_name = %camera.go2rtc_name,
            error = %e,
            "ONVIF service discovery failed"
        );
        ApiError::Internal(anyhow::anyhow!("ONVIF service discovery failed: {e}"))
    })?;

    // ── 6. get the first media profile token ──────────────────────────────────
    let profile_token = get_first_profile_token(&media_client).await.map_err(|e| {
        warn!(
            camera_id = %camera_id,
            error = %e,
            "ONVIF GetProfiles failed"
        );
        ApiError::Internal(anyhow::anyhow!("ONVIF GetProfiles failed: {e}"))
    })?;

    debug!(
        camera_id = %camera_id,
        profile_token = %profile_token.0,
        action = ?body.action,
        "executing PTZ action"
    );

    // ── 7. execute the requested PTZ action ───────────────────────────────────
    match body.action {
        PtzAction::Move => {
            execute_move(&ptz_client, profile_token, body.pan, body.tilt, body.zoom)
                .await
                .map_err(|e| {
                    warn!(camera_id = %camera_id, error = %e, "ONVIF ContinuousMove failed");
                    ApiError::Internal(anyhow::anyhow!("ONVIF ContinuousMove failed: {e}"))
                })?;
            Ok(Json(PtzResponse { presets: None }))
        }

        PtzAction::Stop => {
            execute_stop(&ptz_client, profile_token)
                .await
                .map_err(|e| {
                    warn!(camera_id = %camera_id, error = %e, "ONVIF Stop failed");
                    ApiError::Internal(anyhow::anyhow!("ONVIF Stop failed: {e}"))
                })?;
            Ok(Json(PtzResponse { presets: None }))
        }

        PtzAction::Preset => {
            // Validated above — `preset` is Some and non-empty here.
            let preset_token = body.preset.unwrap();
            execute_goto_preset(&ptz_client, profile_token, &preset_token)
                .await
                .map_err(|e| {
                    warn!(
                        camera_id = %camera_id,
                        preset_token = %preset_token,
                        error = %e,
                        "ONVIF GotoPreset failed"
                    );
                    ApiError::Internal(anyhow::anyhow!("ONVIF GotoPreset failed: {e}"))
                })?;
            Ok(Json(PtzResponse { presets: None }))
        }

        PtzAction::Home => {
            execute_home(&ptz_client, profile_token)
                .await
                .map_err(|e| {
                    warn!(camera_id = %camera_id, error = %e, "ONVIF GotoHomePosition failed");
                    ApiError::Internal(anyhow::anyhow!("ONVIF GotoHomePosition failed: {e}"))
                })?;
            Ok(Json(PtzResponse { presets: None }))
        }

        PtzAction::Presets => {
            let presets = list_presets(&ptz_client, profile_token)
                .await
                .map_err(|e| {
                    warn!(camera_id = %camera_id, error = %e, "ONVIF GetPresets failed");
                    ApiError::Internal(anyhow::anyhow!("ONVIF GetPresets failed: {e}"))
                })?;
            Ok(Json(PtzResponse {
                presets: Some(presets),
            }))
        }
    }
}

// ─── imaging (focus / iris) ─────────────────────────────────────────────────────

/// Focus / iris actions for `POST /cameras/:id/imaging` (ONVIF Imaging service).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImagingAction {
    /// Continuous focus toward NEAR; held until `focus_stop`.
    FocusNear,
    /// Continuous focus toward FAR/infinity; held until `focus_stop`.
    FocusFar,
    /// Stop an in-progress focus move.
    FocusStop,
    /// Switch the lens to continuous auto-focus.
    AutoFocus,
    /// Open the iris one step (forces manual exposure).
    IrisOpen,
    /// Close the iris one step (forces manual exposure).
    IrisClose,
    /// Return the iris to automatic exposure.
    IrisAuto,
}

/// Request body for `POST /cameras/:id/imaging`.
#[derive(Debug, Deserialize)]
pub struct ImagingRequest {
    pub action: ImagingAction,
    /// Focus speed 0.0–1.0 (focus moves only). Defaults to [`FOCUS_SPEED`].
    #[serde(default)]
    pub speed: Option<f32>,
}

/// Empty success body (mirrors `PtzResponse`'s `{}` shape).
#[derive(Debug, Serialize)]
pub struct ImagingResponse {}

/// Default continuous-focus speed when the client doesn't specify one.
const FOCUS_SPEED: f64 = 0.7;
/// Iris nudge per step. ONVIF iris is dB attenuation (0 = open, higher = closed).
const IRIS_STEP_DB: f64 = 1.0;

/// `POST /cameras/:id/imaging` — drive focus / iris on an ONVIF camera via the
/// Imaging service. Same gate as PTZ (`require_ptz` + camera access).
#[instrument(skip_all, fields(camera_id = %camera_id))]
async fn imaging_command(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
    Json(body): Json<ImagingRequest>,
) -> Result<Json<ImagingResponse>, ApiError> {
    user.require_ptz()?;
    user.assert_camera_access(camera_id)?;

    let camera = db::get_camera(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {camera_id} not found")))?;

    // Defense in depth: honor the per-camera PTZ-controls toggle (migration 0061),
    // same as the PTZ move/preset path — focus/iris is a PTZ control too.
    ensure_ptz_enabled(&camera)?;

    let onvif_cfg = resolve_onvif_config(&state, &camera)?;

    let (imaging_client, vst) = build_onvif_imaging(&onvif_cfg).await.map_err(|e| {
        warn!(camera_id = %camera_id, error = %e, "ONVIF imaging discovery failed");
        ApiError::Internal(anyhow::anyhow!("ONVIF imaging discovery failed: {e}"))
    })?;

    let focus_speed = body
        .speed
        .map_or(FOCUS_SPEED, |s| f64::from(s).clamp(0.0, 1.0));

    let result = match body.action {
        ImagingAction::FocusNear => imaging_focus(&imaging_client, vst, -focus_speed).await,
        ImagingAction::FocusFar => imaging_focus(&imaging_client, vst, focus_speed).await,
        ImagingAction::FocusStop => imaging_focus_stop(&imaging_client, vst).await,
        ImagingAction::AutoFocus => imaging_set_autofocus(&imaging_client, vst).await,
        ImagingAction::IrisOpen => {
            imaging_set_iris(&imaging_client, vst, Some(-IRIS_STEP_DB)).await
        }
        ImagingAction::IrisClose => {
            imaging_set_iris(&imaging_client, vst, Some(IRIS_STEP_DB)).await
        }
        ImagingAction::IrisAuto => imaging_set_iris(&imaging_client, vst, None).await,
    };
    result.map_err(|e| {
        warn!(camera_id = %camera_id, action = ?body.action, error = %e, "ONVIF imaging command failed");
        ApiError::Internal(anyhow::anyhow!("ONVIF imaging command failed: {e}"))
    })?;
    Ok(Json(ImagingResponse {}))
}

// ─── ONVIF helpers ────────────────────────────────────────────────────────────

/// Reject a PTZ/imaging command when the operator has turned this camera's
/// PTZ controls off (migration 0061). Returns `403 Forbidden` with a clear
/// message. This is the server-side backstop behind the client-facing `ptz`
/// capability (`ViewerCameraDto.ptz`), so a stale client cannot drive a camera
/// whose PTZ is disabled.
fn ensure_ptz_enabled(camera: &crumb_common::types::Camera) -> Result<(), ApiError> {
    if camera.ptz_control_enabled {
        Ok(())
    } else {
        Err(ApiError::Forbidden(format!(
            "PTZ controls are disabled for camera '{}'",
            camera.name
        )))
    }
}

/// Resolve a camera's ONVIF connection config: DB columns are authoritative, with
/// the legacy `ONVIF_CONFIG` env map as a fallback for pre-DB-column installs.
pub(crate) fn resolve_onvif_config(
    state: &AppState,
    camera: &crumb_common::types::Camera,
) -> Result<OnvifCameraConfig, ApiError> {
    let host = camera
        .onvif_host
        .as_deref()
        .filter(|h| !h.is_empty())
        .map(str::to_owned)
        .or_else(|| {
            state
                .config()
                .onvif_cameras
                .get(&camera.go2rtc_name)
                .map(|c| c.host.clone())
        })
        .ok_or_else(|| {
            ApiError::NotFound(format!(
                "camera '{}' has no ONVIF host configured (set in admin camera editor or ONVIF_CONFIG env)",
                camera.name
            ))
        })?;
    let port = camera
        .onvif_port
        .and_then(|p| u16::try_from(p).ok())
        .or_else(|| {
            state
                .config()
                .onvif_cameras
                .get(&camera.go2rtc_name)
                .map(|c| c.port)
        })
        .unwrap_or(80);
    let user = camera.onvif_user.clone().unwrap_or_else(|| {
        state
            .config()
            .onvif_cameras
            .get(&camera.go2rtc_name)
            .map(|c| c.user.clone())
            .unwrap_or_default()
    });
    let password = camera.onvif_password.clone().unwrap_or_else(|| {
        state
            .config()
            .onvif_cameras
            .get(&camera.go2rtc_name)
            .map(|c| c.password.clone())
            .unwrap_or_default()
    });
    Ok(OnvifCameraConfig {
        host,
        port,
        user,
        password,
    })
}

/// Fetch ONVIF device identity (manufacturer / model / firmware) using the same
/// per-camera config resolution as PTZ. Best-effort: each field degrades to
/// `None` when the camera doesn't report it. Used by `POST /cameras/:id/identify`.
pub(crate) async fn onvif_device_info(
    cfg: &OnvifCameraConfig,
) -> anyhow::Result<(Option<String>, Option<String>, Option<String>)> {
    let device_url: Url =
        format!("http://{}:{}/onvif/device_service", cfg.host, cfg.port).parse()?;
    let creds = Credentials {
        username: cfg.user.clone(),
        password: cfg.password.clone(),
    };
    let device_client = ClientBuilder::new(&device_url)
        .credentials(Some(creds))
        .auth_type(AuthType::Any)
        .build();
    let info =
        schema::devicemgmt::get_device_information(&device_client, &Default::default()).await?;
    let ne = |s: &str| {
        let t = s.trim();
        (!t.is_empty()).then(|| t.to_owned())
    };
    Ok((
        ne(&info.manufacturer),
        ne(&info.model),
        ne(&info.firmware_version),
    ))
}

/// Build an ONVIF imaging client + resolve the video-source token (required by all
/// imaging operations). Discovers the imaging + media `XAddrs` via `GetServices`,
/// falling back to well-known paths.
async fn build_onvif_imaging(
    cfg: &OnvifCameraConfig,
) -> anyhow::Result<(onvif::soap::client::Client, schema::onvif::ReferenceToken)> {
    let device_url: Url =
        format!("http://{}:{}/onvif/device_service", cfg.host, cfg.port).parse()?;
    let creds = Credentials {
        username: cfg.user.clone(),
        password: cfg.password.clone(),
    };
    let device_client = ClientBuilder::new(&device_url)
        .credentials(Some(creds.clone()))
        .auth_type(AuthType::Any)
        .build();

    let fallback_imaging: Url = format!("http://{}:{}/onvif/imaging", cfg.host, cfg.port)
        .parse()
        .unwrap_or_else(|_| device_url.clone());
    let fallback_media: Url = format!("http://{}:{}/onvif/media_service", cfg.host, cfg.port)
        .parse()
        .unwrap_or_else(|_| device_url.clone());

    let (imaging_url, media_url) =
        match schema::devicemgmt::get_services(&device_client, &Default::default()).await {
            Ok(r) => {
                let mut img = None::<Url>;
                let mut med = None::<Url>;
                for s in &r.service {
                    let Ok(u) = Url::parse(&s.x_addr) else {
                        continue;
                    };
                    match s.namespace.as_str() {
                        "http://www.onvif.org/ver20/imaging/wsdl" => img = Some(u),
                        "http://www.onvif.org/ver10/media/wsdl"
                        | "http://www.onvif.org/ver20/media/wsdl"
                            if med.is_none() =>
                        {
                            med = Some(u);
                        }
                        _ => {}
                    }
                }
                (
                    img.unwrap_or(fallback_imaging),
                    med.unwrap_or(fallback_media),
                )
            }
            Err(e) => {
                warn!(error = %e, "ONVIF GetServices failed; using fallback imaging/media URLs");
                (fallback_imaging, fallback_media)
            }
        };

    let media_client = ClientBuilder::new(&media_url)
        .credentials(Some(creds.clone()))
        .auth_type(AuthType::Any)
        .build();
    let imaging_client = ClientBuilder::new(&imaging_url)
        .credentials(Some(creds))
        .auth_type(AuthType::Any)
        .build();

    let profiles = schema::media::get_profiles(&media_client, &Default::default())
        .await
        .map_err(|e| anyhow::anyhow!("GetProfiles SOAP error: {e}"))?;
    let vst = profiles
        .profiles
        .into_iter()
        .find_map(|p| p.video_source_configuration.map(|v| v.source_token))
        .ok_or_else(|| anyhow::anyhow!("camera reported no video source configuration"))?;
    Ok((imaging_client, vst))
}

/// Continuous focus move; `speed < 0` focuses near, `> 0` focuses far. Held until
/// [`imaging_focus_stop`].
async fn imaging_focus(
    client: &onvif::soap::client::Client,
    video_source_token: schema::onvif::ReferenceToken,
    speed: f64,
) -> anyhow::Result<()> {
    schema::imaging::_move(
        client,
        &schema::imaging::Move {
            video_source_token,
            focus: vec![schema::onvif::FocusMove {
                continuous: Some(schema::onvif::ContinuousFocus { speed }),
                absolute: None,
                relative: None,
            }],
        },
    )
    .await
    .map_err(|e| anyhow::anyhow!("imaging Move SOAP error: {e}"))?;
    Ok(())
}

/// Stop any in-progress focus movement.
async fn imaging_focus_stop(
    client: &onvif::soap::client::Client,
    video_source_token: schema::onvif::ReferenceToken,
) -> anyhow::Result<()> {
    schema::imaging::stop(client, &schema::imaging::Stop { video_source_token })
        .await
        .map_err(|e| anyhow::anyhow!("imaging Stop SOAP error: {e}"))?;
    Ok(())
}

/// Switch the lens to continuous auto-focus (read-modify-write the focus config).
async fn imaging_set_autofocus(
    client: &onvif::soap::client::Client,
    video_source_token: schema::onvif::ReferenceToken,
) -> anyhow::Result<()> {
    // ReferenceToken isn't Clone; duplicate via its inner string for the set call.
    let token2 = schema::onvif::ReferenceToken(video_source_token.0.clone());
    let mut settings = schema::imaging::get_imaging_settings(
        client,
        &schema::imaging::GetImagingSettings { video_source_token },
    )
    .await
    .map_err(|e| anyhow::anyhow!("GetImagingSettings SOAP error: {e}"))?
    .imaging_settings;
    match settings.focus.as_mut() {
        Some(f) => f.auto_focus_mode = schema::onvif::AutoFocusMode::Auto,
        None => {
            settings.focus = Some(schema::onvif::FocusConfiguration20 {
                auto_focus_mode: schema::onvif::AutoFocusMode::Auto,
                default_speed: None,
                near_limit: None,
                far_limit: None,
                extension: None,
                af_mode: None,
            });
        }
    }
    schema::imaging::set_imaging_settings(
        client,
        &schema::imaging::SetImagingSettings {
            video_source_token: token2,
            imaging_settings: settings,
            force_persistence: false,
        },
    )
    .await
    .map_err(|e| anyhow::anyhow!("SetImagingSettings SOAP error: {e}"))?;
    Ok(())
}

/// Adjust the iris. `delta_db = Some(±step)` nudges manual iris (ONVIF iris is dB
/// attenuation: 0 = open, higher = closed); `None` returns to auto exposure.
async fn imaging_set_iris(
    client: &onvif::soap::client::Client,
    video_source_token: schema::onvif::ReferenceToken,
    delta_db: Option<f64>,
) -> anyhow::Result<()> {
    // ReferenceToken isn't Clone; duplicate via its inner string for the set call.
    let token2 = schema::onvif::ReferenceToken(video_source_token.0.clone());
    let mut settings = schema::imaging::get_imaging_settings(
        client,
        &schema::imaging::GetImagingSettings { video_source_token },
    )
    .await
    .map_err(|e| anyhow::anyhow!("GetImagingSettings SOAP error: {e}"))?
    .imaging_settings;
    let exposure = settings.exposure.as_mut().ok_or_else(|| {
        anyhow::anyhow!("camera did not report exposure settings; iris is not controllable")
    })?;
    match delta_db {
        None => exposure.mode = schema::onvif::ExposureMode::Auto,
        Some(delta) => {
            exposure.mode = schema::onvif::ExposureMode::Manual;
            exposure.iris = Some(exposure.iris.unwrap_or(0.0) + delta);
        }
    }
    schema::imaging::set_imaging_settings(
        client,
        &schema::imaging::SetImagingSettings {
            video_source_token: token2,
            imaging_settings: settings,
            force_persistence: false,
        },
    )
    .await
    .map_err(|e| anyhow::anyhow!("SetImagingSettings SOAP error: {e}"))?;
    Ok(())
}

/// Build an ONVIF device-management client at the well-known device-service URL,
/// run `GetServices` to discover the media and PTZ `XAddrs`, then return clients
/// for both.
///
/// Falls back to constructing the media and PTZ client URLs from the device
/// service base if `GetServices` does not advertise those namespaces (defensive
/// against cameras that implement ONVIF incompletely).
async fn build_onvif_clients(
    cfg: &OnvifCameraConfig,
) -> anyhow::Result<(onvif::soap::client::Client, onvif::soap::client::Client)> {
    let device_url: Url =
        format!("http://{}:{}/onvif/device_service", cfg.host, cfg.port).parse()?;

    let creds = Credentials {
        username: cfg.user.clone(),
        password: cfg.password.clone(),
    };

    let device_client = ClientBuilder::new(&device_url)
        .credentials(Some(creds.clone()))
        .auth_type(AuthType::Any)
        .build();

    // Discover service URLs via GetServices.  If the camera returns an error or
    // omits the media/PTZ namespaces, fall back to well-known relative paths.
    let (media_url, ptz_url) =
        discover_service_urls(&device_client, &device_url, &cfg.host, cfg.port).await;

    let media_client = ClientBuilder::new(&media_url)
        .credentials(Some(creds.clone()))
        .auth_type(AuthType::Any)
        .build();

    let ptz_client = ClientBuilder::new(&ptz_url)
        .credentials(Some(creds))
        .auth_type(AuthType::Any)
        .build();

    Ok((media_client, ptz_client))
}

/// Run `GetServices` and return the `(media_url, ptz_url)` pair.
///
/// If discovery fails or either service is absent, returns fallback URLs built
/// from the device base:
///  - media: `http://{host}:{port}/onvif/media_service`
///  - PTZ:   `http://{host}:{port}/onvif/PTZ`
async fn discover_service_urls(
    device_client: &onvif::soap::client::Client,
    device_url: &Url,
    host: &str,
    port: u16,
) -> (Url, Url) {
    let fallback_media: Url = format!("http://{host}:{port}/onvif/media_service")
        .parse()
        .unwrap_or_else(|_| device_url.clone());
    let fallback_ptz: Url = format!("http://{host}:{port}/onvif/PTZ")
        .parse()
        .unwrap_or_else(|_| device_url.clone());

    let services = match schema::devicemgmt::get_services(device_client, &Default::default()).await
    {
        Ok(r) => r,
        Err(e) => {
            warn!(error = %e, "ONVIF GetServices failed; using fallback URLs");
            return (fallback_media, fallback_ptz);
        }
    };

    let mut media_url = None::<Url>;
    let mut ptz_url = None::<Url>;

    for service in &services.service {
        let parsed = match Url::parse(&service.x_addr) {
            Ok(u) => u,
            Err(e) => {
                warn!(xaddr = %service.x_addr, error = %e, "could not parse service XAddr");
                continue;
            }
        };
        match service.namespace.as_str() {
            "http://www.onvif.org/ver10/media/wsdl" | "http://www.onvif.org/ver20/media/wsdl" => {
                // Prefer the already-set value so a v10 media entry isn't
                // overwritten by a duplicate v20 one and vice-versa; first
                // match wins.
                if media_url.is_none() {
                    media_url = Some(parsed);
                }
            }
            "http://www.onvif.org/ver20/ptz/wsdl" => {
                ptz_url = Some(parsed);
            }
            _ => {}
        }
    }

    (
        media_url.unwrap_or(fallback_media),
        ptz_url.unwrap_or(fallback_ptz),
    )
}

/// Retrieve the first media profile and return its [`schema::onvif::ReferenceToken`].
///
/// Returns an error if the camera reports zero profiles.
async fn get_first_profile_token(
    media_client: &onvif::soap::client::Client,
) -> anyhow::Result<schema::onvif::ReferenceToken> {
    let profiles = schema::media::get_profiles(media_client, &Default::default())
        .await
        .map_err(|e| anyhow::anyhow!("GetProfiles SOAP error: {e}"))?;

    let first = profiles
        .profiles
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("camera reported zero media profiles"))?;

    Ok(schema::onvif::ReferenceToken(first.token.0.clone()))
}

/// Send `ContinuousMove` with the given pan/tilt/zoom velocities.
///
/// Velocities must be in `[-1.0, 1.0]`.  Values outside this range are silently
/// clamped by the camera firmware; we do not clamp them here so the caller gets
/// accurate semantics if it sends 0.0.
async fn execute_move(
    ptz_client: &onvif::soap::client::Client,
    profile_token: schema::onvif::ReferenceToken,
    pan: f32,
    tilt: f32,
    zoom: f32,
) -> anyhow::Result<()> {
    schema::ptz::continuous_move(
        ptz_client,
        &schema::ptz::ContinuousMove {
            profile_token,
            velocity: schema::onvif::Ptzspeed {
                pan_tilt: Some(schema::onvif::Vector2D {
                    x: f64::from(pan),
                    y: f64::from(tilt),
                    space: None,
                }),
                zoom: Some(schema::onvif::Vector1D {
                    x: f64::from(zoom),
                    space: None,
                }),
            },
            timeout: None,
        },
    )
    .await
    .map_err(|e| anyhow::anyhow!("ContinuousMove SOAP error: {e}"))?;
    Ok(())
}

/// Send `Stop` to halt pan/tilt and zoom.
async fn execute_stop(
    ptz_client: &onvif::soap::client::Client,
    profile_token: schema::onvif::ReferenceToken,
) -> anyhow::Result<()> {
    schema::ptz::stop(
        ptz_client,
        &schema::ptz::Stop {
            profile_token,
            pan_tilt: Some(true),
            zoom: Some(true),
        },
    )
    .await
    .map_err(|e| anyhow::anyhow!("Stop SOAP error: {e}"))?;
    Ok(())
}

/// Send `GotoPreset` to move the camera to a saved preset position.
async fn execute_goto_preset(
    ptz_client: &onvif::soap::client::Client,
    profile_token: schema::onvif::ReferenceToken,
    preset_token: &str,
) -> anyhow::Result<()> {
    schema::ptz::goto_preset(
        ptz_client,
        &schema::ptz::GotoPreset {
            profile_token,
            preset_token: schema::onvif::ReferenceToken(preset_token.to_owned()),
            speed: None,
        },
    )
    .await
    .map_err(|e| anyhow::anyhow!("GotoPreset SOAP error: {e}"))?;
    Ok(())
}

/// Send `GotoHomePosition` to move the camera to its configured home position.
async fn execute_home(
    ptz_client: &onvif::soap::client::Client,
    profile_token: schema::onvif::ReferenceToken,
) -> anyhow::Result<()> {
    schema::ptz::goto_home_position(
        ptz_client,
        &schema::ptz::GotoHomePosition {
            profile_token,
            speed: None,
        },
    )
    .await
    .map_err(|e| anyhow::anyhow!("GotoHomePosition SOAP error: {e}"))?;
    Ok(())
}

/// Retrieve all PTZ presets for the given profile.
async fn list_presets(
    ptz_client: &onvif::soap::client::Client,
    profile_token: schema::onvif::ReferenceToken,
) -> anyhow::Result<Vec<PtzPresetDto>> {
    let resp = schema::ptz::get_presets(ptz_client, &schema::ptz::GetPresets { profile_token })
        .await
        .map_err(|e| anyhow::anyhow!("GetPresets SOAP error: {e}"))?;

    let presets = resp
        .preset
        .into_iter()
        .filter_map(|p| {
            // Presets without a token are malformed — skip them.
            let token = p.token?.0;
            let name = p.name.map(|n| n.0).unwrap_or_default();
            Some(PtzPresetDto { token, name })
        })
        .collect();

    Ok(presets)
}
