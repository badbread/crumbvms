//! Home Assistant integration — connection config + per-camera entity links + an
//! entity picker (Phase 1), the live state feed, and the outbound control path
//! (Phase 2, issue #187). REST-only (HA's `/api`), no WebSocket yet; the inbound
//! event path consumes a transport-agnostic source so WS can drop in later. See
//! `docs/DECISIONS.md` (2026-07-10, 2026-08-01) and issues #52 / #187.
//!
//! Security: the token is write-only (never returned; the admin DTO exposes only
//! `has_token`) and travels in the `Authorization: Bearer` header, never a URL.
//! The entity picker proxies HA `/api/states` so the client never sees the token.
//! Config + links edits are admin-only; reading a camera's links needs only
//! access to that camera.
//!
//! `POST /cameras/:id/ha/action` is the most privileged surface in the product:
//! it moves physical hardware (locks, garage doors, sirens). Its whole design is
//! "the client picks from a set the server already decided": the client sends a
//! `link_id` the operator authored plus an action *word*, and the server derives
//! the HA domain from the stored entity, checks the word against a static
//! per-domain allowlist, and constructs the service call itself. There is no
//! raw-service passthrough, and no domain / service / `entity_id` is ever accepted
//! from a client.

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
        .route("/cameras/:id/ha/action", post(post_action))
}

// ─── outbound control: the action allowlist ───────────────────────────────────

/// The EXHAUSTIVE set of HA services Crumb will ever call, keyed by the linked
/// entity's own domain. A client sends an action *word*; the server looks it up
/// here for the domain it derived from the stored `entity_id` and calls the
/// matching HA service. Anything not in this table is rejected with a 400.
///
/// Deliberately narrow: only actions an operator would plausibly want from a
/// camera view, and only ones whose effect is obvious from the button. Adding a
/// domain here widens what any `actuators` role can do, so it is a security
/// decision, not a convenience one (see `docs/DECISIONS.md`, 2026-08-01).
///
/// The action word and the HA service name are 1:1 within a domain, so the
/// lookup returns a `&'static str` service that the URL is built from — the
/// client's own string never reaches the HA request.
const HA_ACTION_ALLOWLIST: &[(&str, &[&str])] = &[
    ("light", &["turn_on", "turn_off", "toggle"]),
    ("switch", &["turn_on", "turn_off", "toggle"]),
    ("fan", &["turn_on", "turn_off", "toggle"]),
    ("siren", &["turn_on", "turn_off", "toggle"]),
    ("cover", &["open_cover", "close_cover", "stop_cover"]),
    ("lock", &["lock", "unlock"]),
    ("button", &["press"]),
    ("input_button", &["press"]),
    ("scene", &["turn_on"]),
    ("script", &["turn_on"]),
];

/// HA domain of an entity id: the text before the first `.` (`cover.garage` ⇒
/// `cover`). Always derived SERVER-SIDE from the stored link, never taken from
/// the client. An entity id with no `.` yields `""`, which matches no allowlist
/// row and is therefore rejected.
fn domain_of(entity_id: &str) -> &str {
    entity_id.split_once('.').map_or("", |(d, _)| d)
}

/// Resolve `(domain, action)` to the `&'static str` HA service to call, or
/// `None` when the pair is not allowlisted (unknown domain, unknown action, or
/// an action that belongs to a different domain). Pure, so the allowlist is
/// exhaustively unit-testable without HA or a DB.
fn allowed_service(domain: &str, action: &str) -> Option<&'static str> {
    let (_, actions) = HA_ACTION_ALLOWLIST.iter().find(|(d, _)| *d == domain)?;
    actions.iter().copied().find(|s| *s == action)
}

/// Every entity domain Crumb can actuate, derived straight from
/// [`HA_ACTION_ALLOWLIST`] so the "controls" entity-picker set can never drift
/// from the domains the action endpoint will actually accept. Order follows the
/// allowlist.
fn control_domains() -> Vec<&'static str> {
    HA_ACTION_ALLOWLIST.iter().map(|(d, _)| *d).collect()
}

/// Validate a link's authored `role` against its entity's HA domain at write
/// time (issue #434). A role that cannot possibly work on its entity's domain is
/// a silent misconfiguration: an `actuator` on a `sensor` never fires, a `motion`
/// link on a non-`binary_sensor` never produces recording edges. Rejecting at the
/// PUT turns that into an immediate, explained 400 instead of a dead link.
///
/// Rules:
/// - `actuator`: the entity's domain MUST be controllable, i.e. present in
///   [`control_domains`] (derived from `HA_ACTION_ALLOWLIST`, never hand-copied,
///   so this can never drift from what `POST .../ha/action` will accept).
/// - `motion`: the entity MUST be a `binary_sensor` (only on/off domains yield
///   the edges motion recording keys on).
/// - `sensor` (status-only display): permissive, any domain is allowed.
///
/// Returns the 400 message on rejection. Pure, so every role-vs-domain pairing is
/// unit-testable without HA or a DB.
fn validate_link_role(entity_id: &str, role: &str) -> Result<(), String> {
    let domain = domain_of(entity_id);
    match role {
        "actuator" => {
            if control_domains().contains(&domain) {
                Ok(())
            } else {
                Err(format!(
                    "an 'actuator' link needs a controllable entity, but '{entity_id}' is a \
                     '{domain}' entity Crumb cannot control (controllable domains: {})",
                    control_domains().join(", ")
                ))
            }
        }
        "motion" => {
            if domain == "binary_sensor" {
                Ok(())
            } else {
                Err(format!(
                    "a 'motion' link needs a 'binary_sensor' entity, but '{entity_id}' is a \
                     '{domain}' entity (only binary sensors produce motion edges)"
                ))
            }
        }
        // 'sensor' is status-only display; permissive on any domain.
        _ => Ok(()),
    }
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
    /// A single HA domain (e.g. `binary_sensor`, `sensor`, `light`, `cover`), or
    /// one of the role aliases: `controls` (every actuatable domain from
    /// `HA_ACTION_ALLOWLIST`: light, switch, fan, siren, cover, lock, button,
    /// `input_button`, scene, script) or `sensors` (numeric `sensor`). Omitted ⇒
    /// the union of all of the above (motion binary sensors + numeric sensors +
    /// every controllable domain).
    domain: Option<String>,
}

#[derive(Serialize)]
struct HaLinkDto {
    id: Uuid,
    /// The same value as `id`, under the name the control endpoint's request
    /// body uses (`POST /cameras/:id/ha/action` takes `link_id`). Additive and
    /// redundant on purpose: clients rendering controls from this payload send
    /// the field back verbatim, and having the two names agree removes the one
    /// place a client could plausibly send the wrong id.
    link_id: Uuid,
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
    /// Badge opacity (0.05..1.0, migration 0060); `null` = fully opaque.
    overlay_opacity: Option<f32>,
    /// Badge shape (migration 0062): `"dot"` or `"pill"`; `null` = default dot.
    overlay_shape: Option<String>,
    /// Solid background '#RRGGBB' (migration 0062); `null` = default dark.
    overlay_bg_color: Option<String>,
    /// White outline + drop shadow (migration 0062; default false).
    overlay_outline: bool,
}

impl From<crumb_common::types::CameraHaLink> for HaLinkDto {
    fn from(l: crumb_common::types::CameraHaLink) -> Self {
        Self {
            id: l.id,
            link_id: l.id,
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
            overlay_opacity: l.overlay_opacity,
            overlay_shape: l.overlay_shape,
            overlay_bg_color: l.overlay_bg_color,
            overlay_outline: l.overlay_outline,
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
    /// Badge opacity (migration 0060); omitted = fully opaque.
    #[serde(default = "default_overlay_opacity")]
    opacity: f32,
    /// Badge shape (migration 0062): `"dot"`/`"pill"`; omitted = default dot.
    #[serde(default)]
    shape: Option<String>,
    /// Solid background '#RRGGBB' (migration 0062); omitted = default dark.
    #[serde(default)]
    bg_color: Option<String>,
    /// White outline + drop shadow (migration 0062); omitted = false.
    #[serde(default)]
    outline: bool,
    #[serde(default)]
    label: Option<String>,
}

fn default_overlay_size() -> f32 {
    1.0
}

fn default_overlay_opacity() -> f32 {
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

/// Validate a badge shape token (migration 0062): the tiny closed vocabulary
/// `dot` / `pill` (mirrors the migration CHECK so a bad value 400s clearly).
fn valid_overlay_shape(s: &str) -> bool {
    matches!(s, "dot" | "pill")
}

/// Validate a curated icon-slug override's SHAPE: short, lowercase `[a-z0-9_]`.
/// Shape and membership are two separate gates: a slug must pass this AND be a
/// member of [`CANONICAL_ICON_SLUGS`] (see [`canonical_icon`]) to be accepted.
/// Keeping shape distinct gives the two rejections distinct, actionable messages.
fn valid_overlay_icon(i: &str) -> bool {
    !i.is_empty()
        && i.len() <= 64
        && i.chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
}

/// The ONE canonical closed vocabulary of on-video badge icon slugs (issue #438,
/// epic #445). This list is the single source of truth: `overlay_icon` is
/// validated against it here, and ALL THREE clients map every slug below to a
/// native glyph:
/// - desktop `ha_overlay/ha_icons.dart` (`kHaBadgeIconChoices`)
/// - iOS `Features/HomeAssistant/HomeAssistant.swift` (`HA.iconSlugToSymbol`)
/// - Android `feature/live/HaVisual.kt` (`badgeIconSlugs`)
///
/// So an icon an operator picks renders the same glyph everywhere instead of
/// silently degrading to a generic fallback on a client that never knew the slug.
/// The future console icon picker (#439) draws from this same list.
///
/// Grouped for maintenance; order is not significant (validation is set
/// membership). To add a slug: add it here AND give it a real glyph in every
/// client map named above. The unit tests below assert the list is deduped and
/// that every slug passes the shape check.
pub const CANONICAL_ICON_SLUGS: &[&str] = &[
    // contact & openings
    "door",
    "window",
    "gate",
    "garage",
    "cover",
    "blinds",
    "curtains",
    "shade",
    "lock",
    "key",
    // motion & presence
    "motion",
    "occupancy",
    "person",
    "pet",
    "vibration",
    // lighting
    "lightbulb",
    "floodlight",
    "outdoor_light",
    // power & switches
    "switch",
    "power",
    "plug",
    "outlet",
    "energy",
    "meter",
    "battery",
    "solar",
    "ev",
    // climate & environment
    "fan",
    "ac",
    "heatpump",
    "hvac",
    "thermostat",
    "temperature",
    "humidity",
    "sun",
    // safety & alarm (incl. smoke/gas/CO problem sensors)
    "smoke",
    "gas",
    "co",
    "fire",
    "leak",
    "water",
    "valve",
    "siren",
    "security",
    "armed",
    "warning",
    "doorbell",
    "bell",
    // camera & media
    "camera",
    "tv",
    "speaker",
    // network
    "wifi",
    "router",
    // vehicles & delivery
    "vehicle",
    "package",
    "mail",
    // appliances & outdoor
    "vacuum",
    "lawn",
    "fridge",
    "laundry",
    "pool",
    "hottub",
    // time
    "clock",
    // automation
    "scene",
    "script",
    "button",
    // generic fallback (every client also renders unknown slugs as this)
    "sensor",
];

/// Whether an icon slug is a member of the closed [`CANONICAL_ICON_SLUGS`]
/// vocabulary. Membership is the contract the clients implement: a slug that
/// passes here is guaranteed a real glyph on every client.
fn canonical_icon(slug: &str) -> bool {
    CANONICAL_ICON_SLUGS.contains(&slug)
}

/// One entity's current state in the `GET /ha/states` feed.
#[derive(Serialize)]
struct HaEntityState {
    entity_id: String,
    state: String,
    /// HA `last_changed` (RFC3339), passed through verbatim for "N ago" display.
    last_changed: Option<String>,
    /// HA `attributes.unit_of_measurement`, passed through verbatim so clients
    /// can render a numeric sensor as `<state> <unit>` (e.g. "72 degF"). `None`
    /// when the entity reports no unit (issue #449). No server-side formatting:
    /// the raw `state` string is left as-is; clients own display.
    unit: Option<String>,
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

/// Body of `POST /cameras/:id/ha/action`.
///
/// Note what is NOT here: no domain, no service, no entity id. The link id
/// addresses an operator-authored row on this camera, and `action` is a word
/// looked up in [`HA_ACTION_ALLOWLIST`] for the domain the SERVER derives from
/// that row's entity. Everything the HA request is built from comes from the
/// server side of that lookup.
#[derive(Deserialize)]
struct HaActionRequest {
    link_id: Uuid,
    action: String,
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
        // Actuator role: every domain the action endpoint can drive (light,
        // switch, fan, siren, cover, lock, button, input_button, scene, script),
        // derived from the allowlist so the two can never diverge.
        Some("controls") => control_domains(),
        // Numeric-sensor role (temperature/humidity/... display links).
        Some("sensors") => vec!["sensor"],
        Some(d) => vec![d],
        // Omitted ⇒ the union of every pickable role: motion binary sensors,
        // numeric sensors, and every controllable domain.
        None => {
            let mut all = vec!["binary_sensor", "sensor"];
            all.extend(control_domains());
            all
        }
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
        // Role must be compatible with the entity's HA domain, else the link is
        // a silent dead end (actuator that never fires, motion that never
        // triggers). Issue #434.
        validate_link_role(l.entity_id.trim(), &l.role).map_err(ApiError::BadRequest)?;
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
            if !p.x.is_finite() || !p.y.is_finite() || !p.size.is_finite() || !p.opacity.is_finite()
            {
                return Err(ApiError::BadRequest(
                    "placement x/y/size/opacity must be finite numbers".to_owned(),
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
                // Membership in the closed vocabulary is what guarantees every
                // client can render the slug (issue #438). A shape-valid but
                // off-list slug would render fine on the client that authored it
                // and fall back to a generic glyph on the others, which is the
                // exact divergence this endpoint now refuses.
                if !canonical_icon(i) {
                    return Err(ApiError::BadRequest(format!(
                        "placement icon '{i}' is not a known badge icon (see the closed icon \
                         vocabulary; the console icon picker only offers valid slugs)"
                    )));
                }
            }
            if let Some(s) = &p.shape {
                if !valid_overlay_shape(s) {
                    return Err(ApiError::BadRequest(
                        "placement shape must be 'dot' or 'pill'".to_owned(),
                    ));
                }
            }
            if let Some(c) = &p.bg_color {
                if !valid_overlay_color(c) {
                    return Err(ApiError::BadRequest(
                        "placement bg_color must be a '#RRGGBB' hex string".to_owned(),
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
                opacity: Some(p.opacity.clamp(0.05, 1.0)),
                shape: p.shape.clone(),
                bg_color: p.bg_color.clone(),
                outline: p.outline,
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

// ─── outbound control: the actuator endpoint ─────────────────────────────────

/// `system_events.event_key` for the actuation audit trail. There is no
/// `system_alert_rules` row for it, so the notification engine consumes and
/// skips it (see `notifications.rs`): the row is an AUDIT record, not an alert.
const HA_ACTUATION_EVENT_KEY: &str = "ha_actuation";

/// Sanitize a client-supplied string for inclusion in an audit detail: keep it
/// short and printable so a hostile `action` cannot smuggle newlines or control
/// characters into the log / audit row.
fn sanitize_for_audit(s: &str) -> String {
    s.chars()
        .take(64)
        .map(|c| if c.is_ascii_graphic() { c } else { '?' })
        .collect()
}

/// Record one actuation attempt: a durable `system_events` row plus a tracing
/// line. Called for every attempt that got as far as a resolved actuator link,
/// including allowlist rejections and failed HA calls.
///
/// Never fails the request: the tracing line is emitted unconditionally, so a
/// DB hiccup degrades the audit to log-only rather than either losing the record
/// silently or telling an operator their garage door did not move when it did.
async fn audit_actuation(
    state: &AppState,
    user: &AuthUser,
    camera_id: Uuid,
    link: &crumb_common::types::CameraHaLink,
    action: &str,
    outcome: &str,
) {
    let username = db::get_user_by_id(state.pool(), user.user_id)
        .await
        .ok()
        .flatten()
        .map_or_else(|| "unknown".to_owned(), |u| u.username);
    let action = sanitize_for_audit(action);
    tracing::info!(
        target: "crumb::audit",
        user_id = %user.user_id,
        username = %username,
        camera_id = %camera_id,
        link_id = %link.id,
        entity_id = %link.entity_id,
        action = %action,
        outcome = %outcome,
        "HA actuation"
    );
    let detail = format!(
        "user={username} ({}) camera={camera_id} link={} entity={} \
         action={action} outcome={outcome}",
        user.user_id, link.id, link.entity_id
    );
    if let Err(e) = db::insert_system_event(
        state.pool(),
        HA_ACTUATION_EVENT_KEY,
        Some(camera_id),
        Some(&detail),
    )
    .await
    {
        tracing::warn!(error = %e, "ha actuation audit row insert failed (log-only audit for this attempt)");
    }
}

/// `POST /cameras/:id/ha/action` — operate a device linked to this camera.
///
/// Bearer JWT only. A scoped media `?token=` principal authenticates for media
/// but never carries the `actuators` capability (hardcoded `false` in
/// `auth_mw::media_capabilities_from_claims`), so it is refused at the first
/// check below.
///
/// Verification order, each step returning before HA is contacted:
/// 1. `actuators` capability (admin implies) — else 403.
/// 2. access to camera `:id` — else 403, matching every other per-camera route
///    (`AuthUser::assert_camera_access`).
/// 3. `link_id` exists on THIS camera and has `role = 'actuator'` — else 404.
/// 4. the action is allowlisted for the domain of the link's stored entity —
///    else 400.
///
/// Returns `{"ok": true}` on an HA 2xx. No state is returned: clients converge
/// on the existing 3s `GET /ha/states` poll, so there is one source of truth for
/// entity state and no chance of this response disagreeing with it.
///
/// # Errors
///
/// * `400` — action not allowlisted for the entity's domain, or HA not
///   configured/enabled.
/// * `403` — missing `actuators`, or the camera is outside the caller's grant.
/// * `404` — no actuator link with that id on this camera.
/// * `502` — Home Assistant unreachable or returned an error.
async fn post_action(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
    Json(body): Json<HaActionRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    // 1. capability — the deny-by-default gate on moving physical hardware.
    user.require_actuators()?;
    // 2. camera scope.
    user.assert_camera_access(camera_id)?;
    // 3. the link must exist ON THIS CAMERA and be an actuator. A link id from
    //    another camera, or a motion/sensor link, is indistinguishable from a
    //    nonexistent one to the caller.
    let link = db::get_camera_ha_link(state.pool(), camera_id, body.link_id)
        .await
        .map_err(ApiError::Internal)?
        .filter(|l| l.role == "actuator")
        .ok_or_else(|| {
            ApiError::NotFound("no actuator HA link with that id on this camera".to_owned())
        })?;

    // 4. allowlist, on the domain derived from the STORED entity id.
    let domain = domain_of(&link.entity_id);
    let action = body.action.trim();
    let Some(service) = allowed_service(domain, action) else {
        audit_actuation(
            &state,
            &user,
            camera_id,
            &link,
            action,
            "rejected: action not allowed for this domain",
        )
        .await;
        let allowed = HA_ACTION_ALLOWLIST
            .iter()
            .find(|(d, _)| *d == domain)
            .map(|(_, a)| a.join(", "));
        return Err(ApiError::BadRequest(match allowed {
            Some(list) => {
                format!("that action is not allowed for a '{domain}' entity (allowed: {list})")
            }
            None => format!("Crumb does not control '{domain}' entities"),
        }));
    };

    let settings = effective_settings(&state).await?;
    if !settings.enabled {
        return Err(ApiError::BadRequest(
            "Home Assistant is not enabled".to_owned(),
        ));
    }
    let client = ha_client(&settings)?;

    // `domain` is the stored entity's own prefix and `service` is a &'static str
    // straight out of the allowlist, so nothing client-controlled reaches the
    // HA URL; the entity id travels in the request body.
    match client.call_service(domain, service, &link.entity_id).await {
        Ok(()) => {
            audit_actuation(&state, &user, camera_id, &link, action, "ok").await;
            Ok(Json(json!({ "ok": true })))
        }
        Err(e) => {
            audit_actuation(&state, &user, camera_id, &link, action, "ha call failed").await;
            // BadGateway logs the detail and returns a generic message to the
            // client (see error.rs); the detail carries only a status code.
            Err(ApiError::BadGateway(format!(
                "Home Assistant service call failed: {e}"
            )))
        }
    }
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
                unit: v
                    .get("attributes")
                    .and_then(|a| a.get("unit_of_measurement"))
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

        // Numeric-sensor picker set surfaces `sensor.*` only.
        let sensors = entities_from_states(arr, &["sensor"]);
        assert_eq!(sensors.len(), 1);
        assert_eq!(sensors[0].entity_id, "sensor.temperature");
    }

    #[test]
    fn control_domains_match_the_action_allowlist() {
        // The picker's "controls" set is derived from HA_ACTION_ALLOWLIST, so
        // every domain the action endpoint can drive is reachable through the
        // picker, and nothing else leaks in. This guards against the two lists
        // silently diverging.
        let picker = control_domains();
        let allow: Vec<&str> = HA_ACTION_ALLOWLIST.iter().map(|(d, _)| *d).collect();
        assert_eq!(picker, allow);
        for d in [
            "light",
            "switch",
            "fan",
            "siren",
            "cover",
            "lock",
            "button",
            "input_button",
            "scene",
            "script",
        ] {
            assert!(picker.contains(&d), "control picker missing {d}");
        }
        // Motion + numeric-sensor domains are NOT controls (separate roles).
        assert!(!picker.contains(&"binary_sensor"));
        assert!(!picker.contains(&"sensor"));
    }

    #[test]
    fn control_domains_filter_covers_lock_and_cover() {
        // A cover and a lock must both be pickable via the widened controls set
        // (the flagship confirm-gated garage/lock control had buttons but no
        // pick path before issue #433).
        let states = json!([
            {"entity_id": "cover.garage", "attributes": {"friendly_name": "Garage Door"}},
            {"entity_id": "lock.front", "attributes": {"friendly_name": "Front Lock"}},
            {"entity_id": "fan.attic", "attributes": {"friendly_name": "Attic Fan"}},
            {"entity_id": "binary_sensor.motion", "attributes": {"friendly_name": "Motion"}}
        ]);
        let arr = states.as_array().unwrap();
        let controls = entities_from_states(arr, &control_domains());
        let ids: Vec<&str> = controls.iter().map(|e| e.entity_id.as_str()).collect();
        assert!(ids.contains(&"cover.garage"));
        assert!(ids.contains(&"lock.front"));
        assert!(ids.contains(&"fan.attic"));
        // binary_sensor is a motion entity, not a control.
        assert!(!ids.contains(&"binary_sensor.motion"));
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
        assert!((p.opacity - 1.0).abs() < f32::EPSILON); // migration 0060 default
        assert_eq!(p.shape, None); // shape/background/outline default off (0062)
        assert_eq!(p.bg_color, None);
        assert!(!p.outline);
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
            "show_state": true, "show_age": true, "opacity": 0.5,
            "shape": "pill", "bg_color": "#101014", "outline": true,
            "label": "Front door"
        }))
        .unwrap();
        assert_eq!(p.color.as_deref(), Some("#FFB143"));
        assert_eq!(p.icon.as_deref(), Some("doorbell"));
        assert!(p.show_state);
        assert!(p.show_age);
        assert!((p.opacity - 0.5).abs() < f32::EPSILON);
        assert_eq!(p.shape.as_deref(), Some("pill"));
        assert_eq!(p.bg_color.as_deref(), Some("#101014"));
        assert!(p.outline);
        assert_eq!(p.label.as_deref(), Some("Front door"));
    }

    #[test]
    fn overlay_shape_validation() {
        assert!(valid_overlay_shape("dot"));
        assert!(valid_overlay_shape("pill"));
        assert!(!valid_overlay_shape("square")); // not in the vocabulary
        assert!(!valid_overlay_shape("Dot")); // case-sensitive
        assert!(!valid_overlay_shape("")); // empty
    }

    #[test]
    fn domain_is_derived_from_the_entity_id_prefix() {
        assert_eq!(domain_of("cover.garage_door"), "cover");
        assert_eq!(domain_of("lock.front_door"), "lock");
        // Only the FIRST dot splits, so a dotted object id keeps its domain.
        assert_eq!(domain_of("light.hall.left"), "light");
        // No dot ⇒ no domain ⇒ matches no allowlist row.
        assert_eq!(domain_of("garage"), "");
        assert_eq!(domain_of(""), "");
        assert!(allowed_service(domain_of("garage"), "turn_on").is_none());
    }

    #[test]
    fn allowlist_accepts_every_documented_domain_action_pair() {
        // The EXHAUSTIVE positive list. If this test needs editing, the set of
        // things any `actuators` role can do to physical hardware changed.
        let allowed: &[(&str, &[&str])] = &[
            ("light", &["turn_on", "turn_off", "toggle"]),
            ("switch", &["turn_on", "turn_off", "toggle"]),
            ("fan", &["turn_on", "turn_off", "toggle"]),
            ("siren", &["turn_on", "turn_off", "toggle"]),
            ("cover", &["open_cover", "close_cover", "stop_cover"]),
            ("lock", &["lock", "unlock"]),
            ("button", &["press"]),
            ("input_button", &["press"]),
            ("scene", &["turn_on"]),
            ("script", &["turn_on"]),
        ];
        for (domain, actions) in allowed {
            for action in *actions {
                assert_eq!(
                    allowed_service(domain, action),
                    Some(*action),
                    "{domain}.{action} must be allowed and map 1:1 to its service"
                );
            }
        }
        // ...and the allowlist contains nothing beyond that set.
        let expected: usize = allowed.iter().map(|(_, a)| a.len()).sum();
        let actual: usize = HA_ACTION_ALLOWLIST.iter().map(|(_, a)| a.len()).sum();
        assert_eq!(actual, expected, "allowlist grew or shrank unexpectedly");
    }

    #[test]
    fn allowlist_rejects_wrong_domain_unknown_and_garbage_actions() {
        // Right action word, wrong domain.
        assert_eq!(allowed_service("lock", "turn_on"), None);
        assert_eq!(allowed_service("light", "unlock"), None);
        assert_eq!(allowed_service("cover", "toggle"), None);
        assert_eq!(allowed_service("scene", "turn_off"), None);
        assert_eq!(allowed_service("button", "turn_on"), None);
        assert_eq!(allowed_service("script", "toggle"), None);
        assert_eq!(allowed_service("lock", "open_cover"), None);

        // Unknown domains, including HA domains Crumb deliberately won't drive.
        assert_eq!(allowed_service("climate", "set_temperature"), None);
        assert_eq!(allowed_service("alarm_control_panel", "alarm_disarm"), None);
        assert_eq!(allowed_service("homeassistant", "turn_on"), None);
        assert_eq!(allowed_service("shell_command", "turn_on"), None);
        assert_eq!(allowed_service("", "turn_on"), None);

        // Unknown / garbage actions.
        assert_eq!(allowed_service("light", "explode"), None);
        assert_eq!(allowed_service("light", ""), None);
        assert_eq!(allowed_service("light", "TURN_ON"), None); // case-sensitive
        assert_eq!(allowed_service("light", "turn_on "), None); // handler trims
        assert_eq!(allowed_service("light", "turn_on;reboot"), None);
        assert_eq!(
            allowed_service("light", "../../homeassistant/restart"),
            None
        );
        assert_eq!(allowed_service("light", "turn_on/../restart"), None);
        assert_eq!(allowed_service("light/../x", "turn_on"), None);
    }

    #[test]
    fn audit_detail_is_sanitized() {
        assert_eq!(sanitize_for_audit("turn_on"), "turn_on");
        // Newlines / control chars can't break out into a forged log line.
        assert_eq!(sanitize_for_audit("turn_on\nFAKE"), "turn_on?FAKE");
        assert_eq!(sanitize_for_audit("a\tb"), "a?b");
        // Bounded length.
        assert_eq!(sanitize_for_audit(&"x".repeat(300)).len(), 64);
    }

    #[test]
    fn action_request_requires_link_id_and_action_only() {
        let ok: HaActionRequest = serde_json::from_value(json!({
            "link_id": "11111111-1111-1111-1111-111111111111",
            "action": "open_cover"
        }))
        .unwrap();
        assert_eq!(ok.action, "open_cover");
        // A body trying to name a service/entity/domain is not a different
        // request — the extra keys are simply ignored, never honoured.
        let sneaky: HaActionRequest = serde_json::from_value(json!({
            "link_id": "11111111-1111-1111-1111-111111111111",
            "action": "turn_on",
            "domain": "homeassistant",
            "service": "restart",
            "entity_id": "lock.front_door"
        }))
        .unwrap();
        assert_eq!(sneaky.action, "turn_on");
        // Missing fields are a deserialize failure (400), not a default.
        let no_link = serde_json::from_value::<HaActionRequest>(json!({"action": "turn_on"}));
        assert!(no_link.is_err());
        let no_action = serde_json::from_value::<HaActionRequest>(
            json!({"link_id": "11111111-1111-1111-1111-111111111111"}),
        );
        assert!(no_action.is_err());
    }

    #[test]
    fn link_role_validation_matches_role_to_domain() {
        // actuator: every controllable domain is accepted...
        for d in control_domains() {
            assert!(
                validate_link_role(&format!("{d}.thing"), "actuator").is_ok(),
                "actuator on controllable '{d}' should be accepted"
            );
        }
        // ...and non-controllable domains are rejected.
        assert!(validate_link_role("sensor.temperature", "actuator").is_err());
        assert!(validate_link_role("binary_sensor.motion", "actuator").is_err());
        assert!(validate_link_role("climate.thermostat", "actuator").is_err());
        assert!(validate_link_role("garage", "actuator").is_err()); // no domain

        // motion: only binary_sensor is accepted.
        assert!(validate_link_role("binary_sensor.motion", "motion").is_ok());
        assert!(validate_link_role("sensor.temperature", "motion").is_err());
        assert!(validate_link_role("light.kitchen", "motion").is_err());
        assert!(validate_link_role("cover.garage", "motion").is_err());

        // sensor (display): permissive on any domain, including numeric sensors,
        // binary sensors, and even controllable domains.
        assert!(validate_link_role("sensor.temperature", "sensor").is_ok());
        assert!(validate_link_role("binary_sensor.motion", "sensor").is_ok());
        assert!(validate_link_role("light.kitchen", "sensor").is_ok());

        // The rejection message names the offending entity so an operator can
        // see what to fix (and carries no em-dash per house style).
        let msg = validate_link_role("sensor.temperature", "actuator").unwrap_err();
        assert!(msg.contains("sensor.temperature"));
        assert!(!msg.contains('\u{2014}'));
    }

    #[test]
    fn state_unit_is_parsed_from_attributes_when_present() {
        let states = json!([
            {"entity_id": "sensor.temperature", "state": "72",
             "attributes": {"unit_of_measurement": "\u{00b0}F"}},
            {"entity_id": "sensor.no_unit", "state": "42",
             "attributes": {"friendly_name": "Plain"}},
            {"entity_id": "binary_sensor.door", "state": "on"}
        ]);
        let arr = states.as_array().unwrap();
        let wanted: std::collections::HashSet<&str> =
            ["sensor.temperature", "sensor.no_unit", "binary_sensor.door"]
                .into_iter()
                .collect();
        let out = project_states(arr, &wanted);

        let temp = out
            .iter()
            .find(|e| e.entity_id == "sensor.temperature")
            .unwrap();
        assert_eq!(temp.state, "72"); // no server-side formatting
        assert_eq!(temp.unit.as_deref(), Some("\u{00b0}F"));

        // Unit is None when the attribute is missing, or attributes absent.
        let no_unit = out
            .iter()
            .find(|e| e.entity_id == "sensor.no_unit")
            .unwrap();
        assert_eq!(no_unit.unit, None);
        let door = out
            .iter()
            .find(|e| e.entity_id == "binary_sensor.door")
            .unwrap();
        assert_eq!(door.unit, None);
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

    #[test]
    fn canonical_icon_vocabulary_is_well_formed() {
        // The list is deduped: a stray duplicate would silently misrepresent the
        // contract (and a future picker would show it twice).
        let set: std::collections::HashSet<&&str> = CANONICAL_ICON_SLUGS.iter().collect();
        assert_eq!(
            set.len(),
            CANONICAL_ICON_SLUGS.len(),
            "CANONICAL_ICON_SLUGS contains a duplicate slug"
        );
        // Every canonical slug is itself shape-valid, so the two gates in the
        // handler can never contradict each other (a canonical slug that failed
        // the shape check would be permanently unusable).
        for slug in CANONICAL_ICON_SLUGS {
            assert!(
                valid_overlay_icon(slug),
                "canonical slug '{slug}' fails the shape check"
            );
            assert!(canonical_icon(slug), "canonical slug '{slug}' not a member");
        }
        // The generic fallback every client also renders must be in the set.
        assert!(canonical_icon("sensor"));
    }

    #[test]
    fn canonical_icon_covers_every_desktop_picker_slug() {
        // The desktop badge editor was the most complete slug set before #438;
        // every slug it could already store MUST remain accepted, or a prior
        // placement's icon would start 400ing on the next edit. This is the
        // regression guard for that stored-data compatibility.
        for slug in [
            "door",
            "window",
            "garage",
            "gate",
            "motion",
            "person",
            "lightbulb",
            "power",
            "plug",
            "lock",
            "doorbell",
            "bell",
            "water",
            "fire",
            "thermostat",
            "fan",
            "camera",
            "pet",
            "scene",
            "sensor",
            "floodlight",
            "outdoor_light",
            "siren",
            "security",
            "armed",
            "blinds",
            "curtains",
            "shade",
            "ac",
            "heatpump",
            "hvac",
            "humidity",
            "smoke",
            "co",
            "leak",
            "valve",
            "battery",
            "energy",
            "meter",
            "switch",
            "vibration",
            "occupancy",
            "sun",
            "vehicle",
            "package",
            "mail",
            "speaker",
            "tv",
            "vacuum",
            "lawn",
            "solar",
            "ev",
            "fridge",
            "laundry",
            "wifi",
            "router",
            "clock",
            "key",
            "warning",
            "pool",
            "hottub",
        ] {
            assert!(
                canonical_icon(slug),
                "desktop slug '{slug}' dropped from vocabulary"
            );
        }
    }

    #[test]
    fn canonical_icon_rejects_off_list_slugs() {
        // Shape-valid but NOT in the vocabulary: exactly the case the handler now
        // rejects (it would otherwise render as a generic glyph on clients that
        // did not author it).
        assert!(valid_overlay_icon("banana_phone")); // passes shape...
        assert!(!canonical_icon("banana_phone")); // ...but is off-list.
        assert!(!canonical_icon("sensor_door")); // legacy shape-only example, not a slug.
        assert!(!canonical_icon("")); // empty is neither shape-valid nor a member.
        assert!(!canonical_icon("lightbulb2")); // near-miss of a real slug.
    }
}
