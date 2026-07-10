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

use std::time::Duration;

use axum::{
    extract::{Path, Query, State},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::{
    auth_mw::{AdminUser, AuthUser},
    error::ApiError,
    state::AppState,
};
use crumb_common::db;
use crumb_common::types::HaSettings;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/config/ha", get(get_config).put(put_config))
        .route("/config/ha/test", post(test_config))
        .route("/ha/entities", get(get_entities))
        .route("/cameras/:id/ha/links", get(get_links).put(put_links))
}

// ─── REST client ─────────────────────────────────────────────────────────────

struct HaClient {
    http: reqwest::Client,
    base_url: String,
    token: String,
}

impl HaClient {
    /// Build a client from the effective settings, or a 400 if HA isn't
    /// configured (no base URL / token).
    fn from_settings(s: &HaSettings) -> Result<Self, ApiError> {
        let token = s.token.clone().unwrap_or_default();
        if s.base_url.trim().is_empty() || token.trim().is_empty() {
            return Err(ApiError::BadRequest(
                "Home Assistant is not configured (set a base URL and token first)".to_owned(),
            ));
        }
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("http client build: {e}")))?;
        Ok(Self {
            http,
            base_url: s.base_url.trim_end_matches('/').to_owned(),
            token,
        })
    }

    async fn get(&self, path: &str) -> Result<reqwest::Response, ApiError> {
        // The token is a header, never in the URL, so a reqwest error string
        // (URL + kind) can't leak it.
        self.http
            .get(format!("{}{path}", self.base_url))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Home Assistant request failed: {e}")))
    }

    /// `GET /api/` — a cheap authenticated reachability check.
    async fn test_connection(&self) -> Result<(), ApiError> {
        let resp = self.get("/api/").await?;
        let code = resp.status();
        if code.is_success() {
            Ok(())
        } else {
            Err(ApiError::BadRequest(format!(
                "Home Assistant returned HTTP {}{}",
                code.as_u16(),
                if code.as_u16() == 401 {
                    " (token rejected)"
                } else {
                    ""
                }
            )))
        }
    }

    /// `GET /api/states`, filtered to the given entity-id domains, returning
    /// `(entity_id, friendly_name)` sorted by name.
    async fn list_entities(&self, domains: &[&str]) -> Result<Vec<HaEntity>, ApiError> {
        let resp = self.get("/api/states").await?;
        if !resp.status().is_success() {
            return Err(ApiError::BadRequest(format!(
                "Home Assistant returned HTTP {}",
                resp.status().as_u16()
            )));
        }
        let states: Vec<serde_json::Value> = resp
            .json()
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("Home Assistant states parse: {e}")))?;
        Ok(entities_from_states(&states, domains))
    }
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
        }
    }
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
    HaClient::from_settings(&s)?.test_connection().await?;
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
    let client = HaClient::from_settings(&s)?;
    let domains: Vec<&str> = match q.domain.as_deref() {
        Some("controls") => vec!["light", "switch", "scene"],
        Some(d) => vec![d],
        None => vec!["binary_sensor", "light", "switch", "scene"],
    };
    Ok(Json(client.list_entities(&domains).await?))
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
    let tuples: Vec<(String, String, Option<String>, Option<String>, i32)> = body
        .links
        .into_iter()
        .map(|l| (l.entity_id, l.role, l.device_class, l.label, l.sort_order))
        .collect();
    let links = db::replace_camera_ha_links(state.pool(), camera_id, &tuples)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(links.into_iter().map(HaLinkDto::from).collect()))
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
}
