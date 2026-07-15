//! Home Assistant integration — Phase 1: connection config + per-camera entity
//! links + an entity picker. REST-only (HA's `/api`), no WebSocket yet; the
//! inbound event path (Phase 2) will consume a transport-agnostic source so WS
//! can drop in later. See `docs/DECISIONS.md` (2026-07-10) and issue #52.
//!
//! Security: the token is write-only (never returned; the admin DTO exposes only
//! `has_token`) and travels in the `Authorization: Bearer` header, never a URL.
//! The entity picker proxies HA `/api/states` so the client never sees the token.
//! Config + links edits are admin-only; reading a camera's links needs only
//! access to that camera.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::{
    extract::{Path, Query, State},
    routing::{get, post, put},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::{
    auth_mw::{AdminUser, AuthUser},
    error::ApiError,
    state::{AppState, HaStatesCache},
};
use crumb_common::db;
use crumb_common::types::HaSettings;

/// TTL for the on-demand `GET /ha/states` cache. Clients poll on the live-status
/// 3s tick, so Crumb→HA is at most one `/api/states` request per this window
/// while at least one wall with placements is open (0 otherwise).
const HA_STATES_TTL: Duration = Duration::from_secs(2);
/// How long a last-known snapshot may keep being served (marked `stale`) after
/// HA starts failing, before `GET /ha/states` gives up with a 502.
const HA_STATES_STALE_MAX: Duration = Duration::from_secs(30);

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/config/ha", get(get_config).put(put_config))
        .route("/config/ha/test", post(test_config))
        .route("/ha/entities", get(get_entities))
        .route("/ha/states", get(get_states))
        .route("/cameras/:id/ha/links", get(get_links).put(put_links))
        .route(
            "/cameras/:id/ha/links/:link_id/placement",
            put(put_placement),
        )
}

// ─── HTTP: shared client + picker filter ──────────────────────────────────────

/// Build the shared `crumb_common::ha` client from stored settings, mapping the
/// "not configured" case to a 400.
fn ha_client(s: &HaSettings) -> Result<crumb_common::ha::HaClient, ApiError> {
    crumb_common::ha::HaClient::from_settings(s).ok_or_else(|| {
        ApiError::BadRequest(
            "Home Assistant is not configured (set a base URL and token first)".to_owned(),
        )
    })
}

/// Pure filter/sort of an HA `/api/states` array to the given domains. Split out
/// so it can be unit-tested without a network round-trip.
fn entities_from_states(states: &[serde_json::Value], domains: &[&str]) -> Vec<HaEntity> {
    let mut out: Vec<HaEntity> = states
        .iter()
        .filter_map(|s| {
            let eid = s.get("entity_id")?.as_str()?;
            let domain = eid.split_once('.').map_or("", |(d, _)| d);
            if !domains.contains(&domain) {
                return None;
            }
            let attrs = s.get("attributes");
            let friendly_name = attrs
                .and_then(|a| a.get("friendly_name"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or(eid)
                .to_owned();
            let device_class = attrs
                .and_then(|a| a.get("device_class"))
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned);
            Some(HaEntity {
                entity_id: eid.to_owned(),
                friendly_name,
                device_class,
            })
        })
        .collect();
    out.sort_by_key(|e| e.friendly_name.to_lowercase());
    out
}

async fn effective_settings(state: &AppState) -> Result<HaSettings, ApiError> {
    db::get_ha_settings(state.pool())
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::Internal(anyhow::anyhow!("ha_config singleton row missing")))
}

// ─── DTOs ────────────────────────────────────────────────────────────────────

/// What the admin console sees for the connection. Never includes the token.
#[derive(Serialize)]
struct HaConfigDto {
    enabled: bool,
    base_url: String,
    has_token: bool,
}

impl From<HaSettings> for HaConfigDto {
    fn from(s: HaSettings) -> Self {
        Self {
            enabled: s.enabled,
            base_url: s.base_url,
            has_token: s.token.as_deref().is_some_and(|t| !t.trim().is_empty()),
        }
    }
}

/// Admin config edit. `token: None` leaves the stored token unchanged (write-only);
/// `Some("")` clears it; `Some(x)` sets it.
#[derive(Deserialize)]
struct HaConfigUpdate {
    enabled: bool,
    base_url: String,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Serialize)]
struct HaEntity {
    entity_id: String,
    friendly_name: String,
    /// HA `device_class` (`motion`, `door`, ...), if the entity reports one.
    /// The client filters/groups on this; the server does not gatekeep it.
    device_class: Option<String>,
}

#[derive(Deserialize)]
struct EntitiesQuery {
    /// `binary_sensor`, `light`, `switch`, `scene`, or `controls`
    /// (light+switch+scene). Omitted ⇒ all of the above.
    domain: Option<String>,
}

#[derive(Serialize)]
struct HaLinkDto {
    id: Uuid,
    entity_id: String,
    role: String,
    device_class: Option<String>,
    label: Option<String>,
    sort_order: i32,
    /// On-video overlay placement (issue #170): normalized x/y as a fraction of
    /// the displayed video frame, or `null` when the link is not placed. Set
    /// together with `overlay_y`.
    overlay_x: Option<f64>,
    overlay_y: Option<f64>,
    /// Badge scale multiplier (1.0 = default) when placed, else `null`.
    overlay_size: Option<f32>,
    /// Per-badge display overrides (migration 0059): '#RRGGBB' color and a
    /// curated icon slug, `null` = the state/class-derived default.
    overlay_color: Option<String>,
    overlay_icon: Option<String>,
    /// Pin the live state text / relative age next to the badge on the wall.
    overlay_show_state: bool,
    overlay_show_age: bool,
}

impl From<crumb_common::types::CameraHaLink> for HaLinkDto {
    fn from(l: crumb_common::types::CameraHaLink) -> Self {
        Self {
            id: l.id,
            entity_id: l.entity_id,
            role: l.role,
            device_class: l.device_class,
            label: l.label,
            sort_order: l.sort_order,
            overlay_x: l.overlay_x,
            overlay_y: l.overlay_y,
            overlay_size: l.overlay_size,
            overlay_color: l.overlay_color,
            overlay_icon: l.overlay_icon,
            overlay_show_state: l.overlay_show_state,
            overlay_show_age: l.overlay_show_age,
        }
    }
}

/// Body of `PUT /cameras/:id/ha/links/:link_id/placement`. A literal `null`
/// clears the placement (display overrides reset with it); an object pins the
/// badge at `(x, y)` on the video frame with an optional size multiplier and
/// optional per-badge display overrides (migration 0059).
///
/// `label` edits the LINK-level caption (shared with the admin console's link
/// list) and follows the `PUT /config/ha` token convention: omitted ⇒
/// unchanged, `""` ⇒ cleared, non-empty ⇒ set.
#[derive(Deserialize)]
struct PlacementInput {
    x: f64,
    y: f64,
    #[serde(default = "default_overlay_size")]
    size: f32,
    /// '#RRGGBB' badge color override; `null`/omitted = state-derived default.
    #[serde(default)]
    color: Option<String>,
    /// Curated icon slug override; `null`/omitted = class-derived default.
    #[serde(default)]
    icon: Option<String>,
    #[serde(default)]
    show_state: bool,
    #[serde(default)]
    show_age: bool,
    #[serde(default)]
    label: Option<String>,
}

fn default_overlay_size() -> f32 {
    1.0
}

/// Validate a '#RRGGBB' badge color override (mirrors the migration-0059 CHECK
/// so a bad value 400s with a clear message instead of a 500 from Postgres).
fn valid_overlay_color(c: &str) -> bool {
    match c.strip_prefix('#') {
        Some(hex) => hex.len() == 6 && hex.chars().all(|ch| ch.is_ascii_hexdigit()),
        None => false,
    }
}

/// Validate a curated icon-slug override: short, lowercase `[a-z0-9_]` — the
/// clients own the slug → glyph mapping, the server only sanity-checks shape.
fn valid_overlay_icon(i: &str) -> bool {
    !i.is_empty()
        && i.len() <= 64
        && i.chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
}

/// One entity's current state in the `GET /ha/states` feed.
#[derive(Serialize)]
struct HaEntityState {
    entity_id: String,
    state: String,
    /// HA `last_changed` (RFC3339), passed through verbatim for "N ago" display.
    last_changed: Option<String>,
}

/// `GET /ha/states` response: the caller-visible entity states plus cache age so
/// the client can show a "stale" treatment without guessing.
#[derive(Serialize)]
struct HaStatesResponse {
    /// Age of the served snapshot in milliseconds.
    fetched_at_ms_ago: u64,
    /// True when HA is currently unreachable and this is a last-known snapshot;
    /// clients grey the badges and never read a stale value as authoritative.
    stale: bool,
    states: Vec<HaEntityState>,
}

#[derive(Deserialize)]
struct HaLinkInput {
    entity_id: String,
    role: String,
    #[serde(default)]
    device_class: Option<String>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    sort_order: i32,
}

#[derive(Deserialize)]
struct HaLinksUpdate {
    links: Vec<HaLinkInput>,
}

// ─── handlers ────────────────────────────────────────────────────────────────

/// `GET /config/ha` — admin. Connection config (no token).
async fn get_config(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<HaConfigDto>, ApiError> {
    Ok(Json(effective_settings(&state).await?.into()))
}

/// `PUT /config/ha` — admin. Update connection config; bumps the version.
async fn put_config(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<HaConfigUpdate>,
) -> Result<Json<HaConfigDto>, ApiError> {
    let s = db::update_ha_settings(
        state.pool(),
        body.enabled,
        body.base_url.trim(),
        body.token.is_some(),
        body.token.as_deref(),
    )
    .await
    .map_err(ApiError::Internal)?;
    Ok(Json(s.into()))
}

/// `POST /config/ha/test` — admin. Authenticated reachability check.
async fn test_config(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let s = effective_settings(&state).await?;
    ha_client(&s)?
        .test_connection()
        .await
        .map_err(|e| ApiError::BadRequest(e.to_string()))?;
    Ok(Json(json!({ "ok": true })))
}

/// `GET /ha/entities?domain=...` — admin. The entity picker's data source;
/// proxies HA `/api/states` so the token never reaches the client.
async fn get_entities(
    _admin: AdminUser,
    State(state): State<AppState>,
    Query(q): Query<EntitiesQuery>,
) -> Result<Json<Vec<HaEntity>>, ApiError> {
    let s = effective_settings(&state).await?;
    let domains: Vec<&str> = match q.domain.as_deref() {
        Some("controls") => vec!["light", "switch", "scene"],
        Some(d) => vec![d],
        None => vec!["binary_sensor", "light", "switch", "scene"],
    };
    let states = ha_client(&s)?
        .get_states()
        .await
        .map_err(|e| ApiError::BadRequest(e.to_string()))?;
    Ok(Json(entities_from_states(&states, &domains)))
}

/// `GET /cameras/:id/ha/links` — any user with access to the camera.
async fn get_links(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
) -> Result<Json<Vec<HaLinkDto>>, ApiError> {
    user.assert_camera_access(camera_id)?;
    let links = db::list_camera_ha_links(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(links.into_iter().map(HaLinkDto::from).collect()))
}

/// `PUT /cameras/:id/ha/links` — admin. Replace the camera's full link set.
async fn put_links(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
    Json(body): Json<HaLinksUpdate>,
) -> Result<Json<Vec<HaLinkDto>>, ApiError> {
    for l in &body.links {
        if !matches!(l.role.as_str(), "motion" | "sensor" | "actuator") {
            return Err(ApiError::BadRequest(format!(
                "invalid link role '{}' (expected 'motion', 'sensor', or 'actuator')",
                l.role
            )));
        }
        if l.entity_id.trim().is_empty() {
            return Err(ApiError::BadRequest(
                "link entity_id must not be empty".to_owned(),
            ));
        }
    }
    let tuples: Vec<db::HaLinkInsert> = body
        .links
        .into_iter()
        .map(|l| (l.entity_id, l.role, l.device_class, l.label, l.sort_order))
        .collect();
    let links = db::replace_camera_ha_links(state.pool(), camera_id, &tuples)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(links.into_iter().map(HaLinkDto::from).collect()))
}

/// `PUT /cameras/:id/ha/links/:link_id/placement` — admin. Pin (or, with a
/// `null` body, clear) a linked entity's on-video badge, including its
/// per-badge display overrides (color/icon/pinned captions, migration 0059).
/// Coordinates are clamped to the video frame `[0,1]`; size to a sane range;
/// color/icon are format-validated. Returns the updated link, 404 if no such
/// link exists on that camera.
async fn put_placement(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path((camera_id, link_id)): Path<(Uuid, Uuid)>,
    Json(body): Json<Option<PlacementInput>>,
) -> Result<Json<HaLinkDto>, ApiError> {
    let mut label_update: Option<Option<&str>> = None;
    let placement = match &body {
        None => None,
        Some(p) => {
            if !p.x.is_finite() || !p.y.is_finite() || !p.size.is_finite() {
                return Err(ApiError::BadRequest(
                    "placement x/y/size must be finite numbers".to_owned(),
                ));
            }
            if let Some(c) = &p.color {
                if !valid_overlay_color(c) {
                    return Err(ApiError::BadRequest(
                        "placement color must be a '#RRGGBB' hex string".to_owned(),
                    ));
                }
            }
            if let Some(i) = &p.icon {
                if !valid_overlay_icon(i) {
                    return Err(ApiError::BadRequest(
                        "placement icon must be a short lowercase [a-z0-9_] slug".to_owned(),
                    ));
                }
            }
            // Label edit rides the placement PUT: omitted = unchanged,
            // "" = cleared, non-empty = set (trimmed).
            label_update = p.label.as_deref().map(|l| {
                let t = l.trim();
                if t.is_empty() {
                    None
                } else {
                    Some(t)
                }
            });
            Some(db::HaOverlayPlacement {
                x: p.x.clamp(0.0, 1.0),
                y: p.y.clamp(0.0, 1.0),
                size: p.size.clamp(0.1, 8.0),
                color: p.color.clone(),
                icon: p.icon.clone(),
                show_state: p.show_state,
                show_age: p.show_age,
            })
        }
    };
    let link = db::update_ha_link_placement(
        state.pool(),
        camera_id,
        link_id,
        placement.as_ref(),
        label_update,
    )
    .await
    .map_err(ApiError::Internal)?
    .ok_or_else(|| ApiError::NotFound("no HA link with that id on this camera".to_owned()))?;
    Ok(Json(link.into()))
}

/// `GET /ha/states` — any authenticated user. Current state of every HA entity
/// linked to a camera the caller can access, from the demand-driven cache. A
/// viewer sees only entities linked to cameras in their grant. Never fabricates
/// state: HA unreachable ⇒ last-known snapshot marked `stale`, or a 502 once the
/// snapshot ages past [`HA_STATES_STALE_MAX`].
async fn get_states(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<HaStatesResponse>, ApiError> {
    let s = effective_settings(&state).await?;
    if !s.enabled {
        return Err(ApiError::BadRequest(
            "Home Assistant is not enabled".to_owned(),
        ));
    }
    let client = ha_client(&s)?;

    // Refresh-or-serve under the single-flight lock: concurrent callers on a
    // stale cache collapse to one HA request.
    let (states, age, is_stale) = {
        let mut guard = state.ha_states_cache().lock().await;
        let fresh = guard
            .as_ref()
            .is_some_and(|c| c.fetched_at.elapsed() < HA_STATES_TTL);
        if fresh {
            let c = guard.as_ref().expect("fresh implies a present cache");
            (Arc::clone(&c.states), c.fetched_at.elapsed(), false)
        } else {
            match client.get_states().await {
                Ok(v) => {
                    let states = Arc::new(v);
                    *guard = Some(HaStatesCache {
                        fetched_at: Instant::now(),
                        states: Arc::clone(&states),
                    });
                    (states, Duration::ZERO, false)
                }
                // HA is down: serve last-known while it's recent (clients grey
                // it); give up once it ages out rather than lie about state.
                Err(e) => match guard.as_ref() {
                    Some(c) if c.fetched_at.elapsed() < HA_STATES_STALE_MAX => {
                        (Arc::clone(&c.states), c.fetched_at.elapsed(), true)
                    }
                    _ => {
                        return Err(ApiError::BadGateway(format!(
                            "Home Assistant unreachable: {e}"
                        )))
                    }
                },
            }
        }
    };

    // RBAC: project the snapshot down to entities linked to caller-visible
    // cameras (admins see all). A viewer never learns about entities linked only
    // to cameras outside their grant.
    let cam_filter = if user.is_admin() {
        None
    } else {
        Some(user.camera_ids.clone())
    };
    let linked = db::list_ha_linked_entities(state.pool(), cam_filter.as_deref())
        .await
        .map_err(ApiError::Internal)?;
    let wanted: std::collections::HashSet<&str> = linked.iter().map(String::as_str).collect();

    Ok(Json(HaStatesResponse {
        fetched_at_ms_ago: u64::try_from(age.as_millis()).unwrap_or(u64::MAX),
        stale: is_stale,
        states: project_states(&states, &wanted),
    }))
}

/// Project a raw HA `/api/states` array down to the `wanted` entity ids, keeping
/// each entity's `state` and `last_changed`. Pure (no HA/DB), so the RBAC
/// filtering it backs is unit-testable. Entities not in `wanted` are dropped —
/// the caller passes only the entity ids linked to cameras it may access.
fn project_states(
    states: &[serde_json::Value],
    wanted: &std::collections::HashSet<&str>,
) -> Vec<HaEntityState> {
    states
        .iter()
        .filter_map(|v| {
            let eid = v.get("entity_id")?.as_str()?;
            if !wanted.contains(eid) {
                return None;
            }
            Some(HaEntityState {
                entity_id: eid.to_owned(),
                state: v
                    .get("state")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
                last_changed: v
                    .get("last_changed")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entities_filter_by_domain_with_name_fallback() {
        let states = json!([
            {"entity_id": "binary_sensor.front_door", "attributes": {"friendly_name": "Front Door", "device_class": "door"}},
            {"entity_id": "light.kitchen", "attributes": {"friendly_name": "Kitchen"}},
            {"entity_id": "sensor.temperature", "attributes": {"friendly_name": "Temp"}},
            {"entity_id": "binary_sensor.no_name"}
        ]);
        let arr = states.as_array().unwrap();

        let sensors = entities_from_states(arr, &["binary_sensor"]);
        let ids: Vec<&str> = sensors.iter().map(|e| e.entity_id.as_str()).collect();
        assert_eq!(sensors.len(), 2);
        assert!(ids.contains(&"binary_sensor.front_door"));
        assert!(ids.contains(&"binary_sensor.no_name"));
        assert!(!ids.contains(&"light.kitchen"));
        // device_class is surfaced when present, None otherwise.
        let door = sensors
            .iter()
            .find(|e| e.entity_id == "binary_sensor.front_door")
            .unwrap();
        assert_eq!(door.device_class.as_deref(), Some("door"));
        // Missing friendly_name falls back to the entity id; missing class is None.
        let no_name = sensors
            .iter()
            .find(|e| e.entity_id == "binary_sensor.no_name")
            .unwrap();
        assert_eq!(no_name.friendly_name, "binary_sensor.no_name");
        assert_eq!(no_name.device_class, None);

        // 'controls' domain set picks light/switch/scene, not binary_sensor.
        let controls = entities_from_states(arr, &["light", "switch", "scene"]);
        assert_eq!(controls.len(), 1);
        assert_eq!(controls[0].entity_id, "light.kitchen");
    }

    #[test]
    fn project_states_keeps_only_wanted_with_state_and_last_changed() {
        let states = json!([
            {"entity_id": "binary_sensor.front_door", "state": "off",
             "last_changed": "2026-07-14T18:22:04Z"},
            {"entity_id": "light.kitchen", "state": "on"},
            {"entity_id": "binary_sensor.garage", "state": "open",
             "last_changed": "2026-07-14T10:00:00Z"}
        ]);
        let arr = states.as_array().unwrap();

        // Caller can see only the front door + kitchen light; garage is linked
        // to a camera outside their grant and must not leak.
        let wanted: std::collections::HashSet<&str> = ["binary_sensor.front_door", "light.kitchen"]
            .into_iter()
            .collect();
        let out = project_states(arr, &wanted);
        let ids: Vec<&str> = out.iter().map(|e| e.entity_id.as_str()).collect();
        assert_eq!(out.len(), 2);
        assert!(ids.contains(&"binary_sensor.front_door"));
        assert!(ids.contains(&"light.kitchen"));
        assert!(!ids.contains(&"binary_sensor.garage"));

        let door = out
            .iter()
            .find(|e| e.entity_id == "binary_sensor.front_door")
            .unwrap();
        assert_eq!(door.state, "off");
        assert_eq!(door.last_changed.as_deref(), Some("2026-07-14T18:22:04Z"));
        // last_changed is optional and absent here.
        let light = out.iter().find(|e| e.entity_id == "light.kitchen").unwrap();
        assert_eq!(light.state, "on");
        assert_eq!(light.last_changed, None);

        // Empty wanted set ⇒ nothing projected (a viewer with no linked cameras).
        assert!(project_states(arr, &std::collections::HashSet::new()).is_empty());
    }

    #[test]
    fn placement_input_clamps_and_defaults_size() {
        // Out-of-range coordinates clamp into the video frame; missing size
        // defaults to 1.0. (Mirrors the clamp the handler applies.)
        let p: PlacementInput = serde_json::from_value(json!({"x": 1.4, "y": -0.2})).unwrap();
        assert!((p.x.clamp(0.0, 1.0) - 1.0).abs() < f64::EPSILON);
        assert!((p.y.clamp(0.0, 1.0) - 0.0).abs() < f64::EPSILON);
        assert!((p.size - 1.0).abs() < f32::EPSILON);
        // Display overrides default to "unset"/off (migration 0059).
        assert_eq!(p.color, None);
        assert_eq!(p.icon, None);
        assert!(!p.show_state);
        assert!(!p.show_age);
        assert_eq!(p.label, None);

        // A null body deserializes to None (clears the placement).
        let cleared: Option<PlacementInput> = serde_json::from_value(json!(null)).unwrap();
        assert!(cleared.is_none());
    }

    #[test]
    fn placement_input_accepts_badge_style_overrides() {
        let p: PlacementInput = serde_json::from_value(json!({
            "x": 0.4, "y": 0.6, "size": 1.5,
            "color": "#FFB143", "icon": "doorbell",
            "show_state": true, "show_age": true,
            "label": "Front door"
        }))
        .unwrap();
        assert_eq!(p.color.as_deref(), Some("#FFB143"));
        assert_eq!(p.icon.as_deref(), Some("doorbell"));
        assert!(p.show_state);
        assert!(p.show_age);
        assert_eq!(p.label.as_deref(), Some("Front door"));
    }

    #[test]
    fn overlay_color_and_icon_validation() {
        // Color: exactly '#' + 6 hex digits (mirrors the migration-0059 CHECK).
        assert!(valid_overlay_color("#000000"));
        assert!(valid_overlay_color("#FFb143"));
        assert!(!valid_overlay_color("FFB143")); // missing '#'
        assert!(!valid_overlay_color("#FFB14")); // too short
        assert!(!valid_overlay_color("#FFB1433")); // too long
        assert!(!valid_overlay_color("#GGB143")); // not hex
        assert!(!valid_overlay_color("")); // empty

        // Icon: 1..=64 chars of lowercase [a-z0-9_].
        assert!(valid_overlay_icon("sensor_door"));
        assert!(valid_overlay_icon("doorbell"));
        assert!(!valid_overlay_icon("")); // empty
        assert!(!valid_overlay_icon("Sensor_Door")); // uppercase
        assert!(!valid_overlay_icon("door bell")); // space
        assert!(!valid_overlay_icon(&"x".repeat(65))); // too long
    }
}
