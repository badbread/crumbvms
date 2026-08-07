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
/// Each row is a [`HaActionSpec`]: the action *word* a client may send, the
/// `&'static` HA service Crumb calls for it, and whether it carries a numeric
/// value. The action word is NO LONGER 1:1 with the service (a value word like
/// `set_brightness` rides `turn_on`); the `service` and every value `param` are
/// always `&'static str`s from this table, never the client's string, so the
/// URL and the service-data keys are built entirely server-side.
///
/// Value words this slice adds (#442, Slice 1): `light.set_brightness` (rides
/// `turn_on`, `brightness_pct`), `cover.set_position` (`set_cover_position`,
/// `position`), `fan.set_speed` (`set_percentage`, `percentage`). All three are
/// percent-kind (0..100). Climate `set_temperature` is Slice 2 and deliberately
/// NOT here (see `docs/DECISIONS.md`, 2026-08-01).
const HA_ACTION_ALLOWLIST: &[(&str, &[HaActionSpec])] = &[
    (
        "light",
        &[
            spec("turn_on"),
            spec("turn_off"),
            spec("toggle"),
            pct("set_brightness", "turn_on", "brightness_pct"),
        ],
    ),
    (
        "switch",
        &[spec("turn_on"), spec("turn_off"), spec("toggle")],
    ),
    (
        "fan",
        &[
            spec("turn_on"),
            spec("turn_off"),
            spec("toggle"),
            pct("set_speed", "set_percentage", "percentage"),
        ],
    ),
    (
        "siren",
        &[spec("turn_on"), spec("turn_off"), spec("toggle")],
    ),
    (
        "cover",
        &[
            spec("open_cover"),
            spec("close_cover"),
            spec("stop_cover"),
            pct("set_position", "set_cover_position", "position"),
        ],
    ),
    ("lock", &[spec("lock"), spec("unlock")]),
    ("button", &[spec("press")]),
    ("input_button", &[spec("press")]),
    ("scene", &[spec("turn_on")]),
    ("script", &[spec("turn_on")]),
];

/// The kind of numeric value an action carries. Kept as an enum (not a bare
/// range) so a non-percent kind slots in without reshaping the spec or the
/// validation: Slice 2's climate `set_temperature` will add a `Temperature`
/// variant here and one match arm in [`validate_value`] / the state descriptor,
/// nothing else.
enum ValueKind {
    /// An integer percent, hardcoded `0..=100`. `param` is the HA service-data
    /// key the rounded value is sent under (`brightness_pct`, `position`, ...).
    Percent { param: &'static str },
}

/// One allowlisted action for a domain: the action *word* a client sends, the
/// `&'static` HA service Crumb calls for it, and its value arity (`None` =
/// discrete on/off/press; `Some(kind)` = requires a numeric value of that kind).
struct HaActionSpec {
    /// The action word a client sends, looked up per the entity's own domain.
    action: &'static str,
    /// The HA service Crumb calls for it. `&'static`, never client input.
    service: &'static str,
    /// `None` for a discrete action; `Some(kind)` for a value action.
    value: Option<ValueKind>,
}

/// Build a discrete spec whose action word IS its HA service name (the common
/// case: on/off/toggle/press).
const fn spec(action: &'static str) -> HaActionSpec {
    HaActionSpec {
        action,
        service: action,
        value: None,
    }
}

/// Build a percent-kind value spec: `action` word, the `service` it rides, and
/// the service-data `param` the rounded 0..100 value is sent under.
const fn pct(action: &'static str, service: &'static str, param: &'static str) -> HaActionSpec {
    HaActionSpec {
        action,
        service,
        value: Some(ValueKind::Percent { param }),
    }
}

/// HA domain of an entity id: the text before the first `.` (`cover.garage` ⇒
/// `cover`). Always derived SERVER-SIDE from the stored link, never taken from
/// the client. An entity id with no `.` yields `""`, which matches no allowlist
/// row and is therefore rejected.
fn domain_of(entity_id: &str) -> &str {
    entity_id.split_once('.').map_or("", |(d, _)| d)
}

/// Resolve `(domain, action)` to its [`HaActionSpec`], or `None` when the pair
/// is not allowlisted (unknown domain, unknown action, or an action that belongs
/// to a different domain). Pure, so the allowlist is exhaustively unit-testable
/// without HA or a DB.
fn allowed_spec(domain: &str, action: &str) -> Option<&'static HaActionSpec> {
    HA_ACTION_ALLOWLIST
        .iter()
        .find(|(d, _)| *d == domain)
        .and_then(|(_, specs)| specs.iter().find(|s| s.action == action))
}

/// Validate a request's numeric `value` against an action's [`HaActionSpec`],
/// returning the HA service-data extras to send (`&'static` key + JSON value) on
/// success, or a 400 message on failure. Enforced in `post_action` AFTER the
/// allowlist + `allowed_actions` checks and BEFORE HA is contacted, and pure so
/// every arity/range/rounding edge is unit-testable without HA or a DB.
///
/// Rules (strict on purpose, to catch buggy clients):
/// - discrete action (`spec.value == None`) with a value present ⇒ rejected;
/// - value action with no value ⇒ rejected;
/// - percent kind: `value` must be finite and in `0..=100` (the range is
///   hardcoded, so a cold attribute cache can never block a control), then it is
///   rounded to the nearest integer and sent as a JSON integer under the spec's
///   `param`.
fn validate_value(
    spec: &HaActionSpec,
    value: Option<f64>,
) -> Result<Vec<(&'static str, serde_json::Value)>, String> {
    match (&spec.value, value) {
        (None, None) => Ok(Vec::new()),
        (None, Some(_)) => Err(format!("action '{}' does not take a value", spec.action)),
        (Some(_), None) => Err(format!("action '{}' requires a numeric value", spec.action)),
        (Some(ValueKind::Percent { param }), Some(v)) => {
            if !v.is_finite() || !(0.0..=100.0).contains(&v) {
                return Err(format!(
                    "value for '{}' must be a number between 0 and 100",
                    spec.action
                ));
            }
            // Round to nearest integer and send as a JSON integer.
            let pct = v.round() as i64;
            Ok(vec![(*param, serde_json::json!(pct))])
        }
    }
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

/// Validate a link's authored `allowed_actions` (migration 0075, issue #440) at
/// write time: every entry MUST be a valid action for the entity's own HA
/// domain, i.e. present in [`HA_ACTION_ALLOWLIST`] for that domain. An entry
/// that could never fire (wrong domain, garbage word) is a silent
/// misconfiguration, so it is rejected at the PUT with a clear 400 rather than
/// stored as a dead restriction. An EMPTY list is accepted: it is the explicit
/// "no action permitted" state (control fully disabled on the link).
///
/// Returns the 400 message on rejection. Pure, so it is unit-testable without a
/// DB.
fn validate_allowed_actions(entity_id: &str, allowed: &[String]) -> Result<(), String> {
    let domain = domain_of(entity_id);
    for action in allowed {
        if allowed_spec(domain, action).is_none() {
            return Err(format!(
                "allowed_actions entry '{action}' is not a valid action for a '{domain}' entity \
                 ('{entity_id}'); it must be one of that domain's actions"
            ));
        }
    }
    Ok(())
}

/// Whether `action` is permitted by a link's `allowed_actions` restriction
/// (migration 0075, issue #440). `None` ⇒ unrestricted: every action the domain
/// allowlist already permits is allowed (today's behavior). `Some(list)` ⇒ the
/// action must ALSO appear in `list`. This is the server-side enforcement
/// `post_action` applies AFTER the domain allowlist check, so a viewer cannot
/// fire a disallowed action even by crafting the request. Pure, so it is
/// exhaustively unit-testable without a DB.
fn action_permitted_by_link(allowed_actions: Option<&[String]>, action: &str) -> bool {
    match allowed_actions {
        None => true,
        Some(list) => list.iter().any(|a| a.as_str() == action),
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
    /// BASE solid background '#RRGGBB' (migration 0062); `null` = default dark.
    /// This is the background for the OFF state and for an indeterminate or
    /// stale reading (unknown/unavailable/no reading yet).
    overlay_bg_color: Option<String>,
    /// Background override applied ONLY while the entity reads on (migration
    /// 0076); `null` ⇒ inherit `overlay_bg_color`. Additive: an older client
    /// that does not know the field keeps using the base for both states,
    /// exactly as today. Resolution every client implements:
    /// `on ⇒ overlay_bg_color_on ?? overlay_bg_color ?? #17171B`, any other
    /// state ⇒ `overlay_bg_color ?? #17171B`.
    overlay_bg_color_on: Option<String>,
    /// White outline + drop shadow (migration 0062; default false).
    overlay_outline: bool,
    /// Per-link control config (migration 0075, issue #440). `require_confirm`
    /// tells every client to prompt a confirmation before firing ANY action on
    /// this link (on top of the hardcoded cover/lock safety confirm). Additive
    /// and always present; an older client that does not know the field ignores
    /// it and behaves exactly as today (default false).
    require_confirm: bool,
    /// Per-link control config (migration 0075, issue #440). When non-null, the
    /// client presents ONLY these actions (intersected with the domain's action
    /// set) AND the server refuses anything outside it (see `post_action`).
    /// `null` ⇒ every domain action is offered/allowed (today's behavior). Older
    /// clients ignore it and offer the full domain set as before.
    allowed_actions: Option<Vec<String>>,
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
            overlay_bg_color_on: l.overlay_bg_color_on,
            overlay_outline: l.overlay_outline,
            require_confirm: l.require_confirm,
            allowed_actions: l.allowed_actions,
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
    /// BASE solid background '#RRGGBB' (migration 0062); omitted/`null` =
    /// default dark. Used for the off state and for indeterminate/stale.
    #[serde(default)]
    bg_color: Option<String>,
    /// Background override for the ON state (migration 0076); omitted/`null` =
    /// inherit `bg_color`. Field-level `null` inside the placement object is
    /// the reset ("go back to inheriting"), matching the other overrides; a
    /// body-level `null` still clears the whole placement.
    #[serde(default)]
    bg_color_on: Option<String>,
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
    "home",
    "pet",
    "vibration",
    // lighting
    "lightbulb",
    "floodlight",
    "outdoor_light",
    "landscape_light",
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
    // weather
    "cloud",
    "rain",
    "wind",
    "storm",
    "moon",
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
    "media_player",
    "remote",
    "game",
    "mic",
    "music",
    // network & computing
    "wifi",
    "router",
    "printer",
    "server",
    "computer",
    "storage",
    "phone",
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
    "grill",
    "smoker",
    "coffee",
    "plant",
    // time
    "clock",
    "calendar",
    "timer",
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

/// A value-control capability descriptor on a `GET /ha/states` entry (#442,
/// Slice 1). Present only when the entity currently exposes a settable value
/// (a dimmable light, a positionable cover, a speed-controllable fan); absent
/// otherwise, which is how a client decides whether to draw a slider at all. An
/// old client simply ignores the unknown field.
///
/// Deliberately KIND-AGNOSTIC (`min`/`max`/`step`/`unit`, numbers as JSON
/// values) so Slice 2's temperature control reuses this shape unchanged: it only
/// sets `kind` to something other than `"percent"` and a non-null `unit`.
#[derive(Serialize)]
struct ControlDescriptor {
    /// The value action word a client sends to set this (`set_brightness`, ...).
    action: &'static str,
    /// The value kind. `"percent"` in this slice; a future kind reuses the rest.
    kind: &'static str,
    /// Current value, then the slider bounds/step, in the descriptor's own units
    /// (integers for percent). JSON numbers so a client can render without a
    /// second call and without guessing the type.
    value: serde_json::Value,
    min: serde_json::Value,
    max: serde_json::Value,
    step: serde_json::Value,
    /// Unit label for non-percent kinds; `null` for percent.
    unit: Option<String>,
}

/// Build a percent-kind [`ControlDescriptor`] (0..100, given current value and
/// step; `unit` is null for percent).
fn percent_descriptor(action: &'static str, value: i64, step: i64) -> ControlDescriptor {
    ControlDescriptor {
        action,
        kind: "percent",
        value: serde_json::json!(value),
        min: serde_json::json!(0),
        max: serde_json::json!(100),
        step: serde_json::json!(step),
        unit: None,
    }
}

/// Project a value-control descriptor from an entity's HA `attributes`, using
/// ONLY fields already in the cached raw snapshot (no extra HA round-trip). Kept
/// in lockstep with the value rows of [`HA_ACTION_ALLOWLIST`]: the descriptor's
/// `action` is exactly the value word the client sends back to `post_action`.
///
/// - light: present iff `attributes.brightness` (0..255) exists; value =
///   `round(brightness * 100 / 255)`.
/// - cover: iff `attributes.current_position` (0..100) exists; value = it.
/// - fan: iff `attributes.percentage` (0..100) exists; step =
///   `ceil(attributes.percentage_step)` min 1, else 1.
///
/// Returns `None` for any other domain, or when the keying attribute is absent
/// (a non-dimmable light, a cover that does not report position): the client
/// then shows the entity with no slider.
fn control_descriptor(
    domain: &str,
    attrs: Option<&serde_json::Value>,
) -> Option<ControlDescriptor> {
    let attr = |k: &str| {
        attrs
            .and_then(|a| a.get(k))
            .and_then(serde_json::Value::as_f64)
    };
    match domain {
        "light" => {
            let brightness = attr("brightness")?;
            let pct = (brightness * 100.0 / 255.0).round() as i64;
            Some(percent_descriptor("set_brightness", pct, 1))
        }
        "cover" => {
            let pos = attr("current_position")?;
            Some(percent_descriptor("set_position", pos.round() as i64, 1))
        }
        "fan" => {
            let pct = attr("percentage")?;
            let step = attr("percentage_step").map_or(1, |s| (s.ceil() as i64).max(1));
            Some(percent_descriptor("set_speed", pct.round() as i64, step))
        }
        _ => None,
    }
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
    /// Value-control capability (#442, Slice 1), projected from the entity's
    /// current HA attributes. `None` ⇒ no settable value ⇒ the client shows no
    /// slider. `#[serde(skip)]` when absent to keep the payload small and old
    /// clients unaffected.
    #[serde(skip_serializing_if = "Option::is_none")]
    control: Option<ControlDescriptor>,
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
    /// Per-link control config (migration 0075, issue #440). Omitted ⇒ false
    /// (today's behavior). A client-side confirm gate; not server-enforced.
    #[serde(default)]
    require_confirm: bool,
    /// Per-link control config (migration 0075, issue #440). Omitted / `null` ⇒
    /// every domain action is allowed (today's behavior). When present, each
    /// entry is validated against the entity domain's allowlist at write time
    /// and `post_action` refuses anything outside it.
    #[serde(default)]
    allowed_actions: Option<Vec<String>>,
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
///
/// `value` is the ONE numeric a value action carries (a dimmer level, a cover
/// position). It is optional so discrete actions omit it; serde `f64` rejects
/// strings/objects and JSON has no NaN/Infinity, so a non-number never parses.
/// The arity/range check lives in [`validate_value`], keyed off the action's
/// spec, so a value on a discrete action (or a missing value on a value action)
/// is a clean 400.
#[derive(Deserialize)]
struct HaActionRequest {
    link_id: Uuid,
    action: String,
    #[serde(default)]
    value: Option<f64>,
}

// ─── handlers ────────────────────────────────────────────────────────────────

/// `GET /config/ha` — admin. Connection config (no token).
async fn get_config(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<HaConfigDto>, ApiError> {
    Ok(Json(effective_settings(&state).await?.into()))
}

/// Is `base` an `http(s)://` URL? A base URL pasted without a scheme
/// (`host:8123`, the single most common paste error) is not a URL at all and
/// fails deep inside reqwest with an unhelpful message — reject it at save
/// time instead, the way the Frigate HTTP test already does.
fn has_http_scheme(base: &str) -> bool {
    ["http://", "https://"].iter().any(|p| {
        base.get(..p.len())
            .is_some_and(|s| s.eq_ignore_ascii_case(p))
    })
}

/// `PUT /config/ha` — admin. Update connection config; bumps the version.
async fn put_config(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<HaConfigUpdate>,
) -> Result<Json<HaConfigDto>, ApiError> {
    let base = body.base_url.trim();
    if !base.is_empty() && !has_http_scheme(base) {
        return Err(ApiError::BadRequest(format!(
            "The Home Assistant address must start with http:// or https:// \
             (for example http://homeassistant.local:8123). Got '{base}'."
        )));
    }
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

/// Build the DB insert tuples from validated link inputs, trimming `entity_id`
/// so surrounding whitespace never persists. Validation above (emptiness,
/// `validate_link_role`, `validate_allowed_actions`) runs on the *trimmed* id,
/// so storing the raw padded value would leave a permanently un-actuatable dead
/// link — the HA action path matches on the exact stored id. Pure, so the trim
/// behavior is unit-testable without a DB.
fn link_inserts(links: Vec<HaLinkInput>) -> Vec<db::HaLinkInsert> {
    links
        .into_iter()
        .map(|l| {
            (
                l.entity_id.trim().to_owned(),
                l.role,
                l.device_class,
                l.label,
                l.sort_order,
                l.require_confirm,
                l.allowed_actions,
            )
        })
        .collect()
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
        // allowed_actions entries must be real actions for the entity's domain,
        // else the restriction is nonsense the operator can never satisfy
        // (migration 0075, issue #440).
        if let Some(allowed) = &l.allowed_actions {
            validate_allowed_actions(l.entity_id.trim(), allowed).map_err(ApiError::BadRequest)?;
        }
    }
    let tuples = link_inserts(body.links);
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
            if let Some(c) = &p.bg_color_on {
                if !valid_overlay_color(c) {
                    return Err(ApiError::BadRequest(
                        "placement bg_color_on must be a '#RRGGBB' hex string".to_owned(),
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
                bg_color_on: p.bg_color_on.clone(),
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
    value: Option<f64>,
    outcome: &str,
) {
    let username = db::get_user_by_id(state.pool(), user.user_id)
        .await
        .ok()
        .flatten()
        .map_or_else(|| "unknown".to_owned(), |u| u.username);
    let action = sanitize_for_audit(action);
    // Formatted from the PARSED f64, never the raw client string. Empty for a
    // discrete action so its audit line/detail read exactly as before.
    let value_str = value.map(|v| format!(" value={v}")).unwrap_or_default();
    tracing::info!(
        target: "crumb::audit",
        user_id = %user.user_id,
        username = %username,
        camera_id = %camera_id,
        link_id = %link.id,
        entity_id = %link.entity_id,
        action = %action,
        value = ?value,
        outcome = %outcome,
        "HA actuation"
    );
    let detail = format!(
        "user={username} ({}) camera={camera_id} link={} entity={} \
         action={action}{value_str} outcome={outcome}",
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
/// 5. the action is permitted by the link's own `allowed_actions` restriction
///    (migration 0075, issue #440) — else 403. `null` ⇒ unrestricted.
/// 6. the request's numeric `value` matches the action's arity/range
///    (`validate_value`, #442 Slice 1) — else 400, before HA is contacted.
///
/// Returns `{"ok": true}` on an HA 2xx. No state is returned: clients converge
/// on the existing 3s `GET /ha/states` poll, so there is one source of truth for
/// entity state and no chance of this response disagreeing with it.
///
/// # Errors
///
/// * `400` — action not allowlisted for the entity's domain, or HA not
///   configured/enabled.
/// * `403` — missing `actuators`, the camera is outside the caller's grant, or
///   the action is not in the link's `allowed_actions`.
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
    let Some(spec) = allowed_spec(domain, action) else {
        audit_actuation(
            &state,
            &user,
            camera_id,
            &link,
            action,
            body.value,
            "rejected: action not allowed for this domain",
        )
        .await;
        let allowed = HA_ACTION_ALLOWLIST
            .iter()
            .find(|(d, _)| *d == domain)
            .map(|(_, a)| a.iter().map(|s| s.action).collect::<Vec<_>>().join(", "));
        return Err(ApiError::BadRequest(match allowed {
            Some(list) => {
                format!("that action is not allowed for a '{domain}' entity (allowed: {list})")
            }
            None => format!("Crumb does not control '{domain}' entities"),
        }));
    };

    // 5. per-link allowed_actions restriction (migration 0075, issue #440). The
    //    domain allowlist above says the action is possible for this KIND of
    //    entity; this narrows it to what the operator authored for THIS link. A
    //    non-null list that omits the action is a real server-side denial (403),
    //    not a client hint: a viewer cannot fire it by crafting the request.
    if !action_permitted_by_link(link.allowed_actions.as_deref(), action) {
        audit_actuation(
            &state,
            &user,
            camera_id,
            &link,
            action,
            body.value,
            "rejected: action not in link's allowed_actions",
        )
        .await;
        let allowed = link
            .allowed_actions
            .as_deref()
            .map(|l| l.join(", "))
            .unwrap_or_default();
        return Err(ApiError::Forbidden(format!(
            "that action is not permitted on this link (allowed on this link: {allowed})"
        )));
    }

    // 6. value arity + range, driven by the action's spec. A discrete action
    //    with a value, a value action with none, or an out-of-range value is a
    //    400 audited as a rejection BEFORE HA is contacted. `extra` is the
    //    (&'static key, JSON value) service data to send (empty for discrete).
    let extra = match validate_value(spec, body.value) {
        Ok(extra) => extra,
        Err(msg) => {
            audit_actuation(
                &state,
                &user,
                camera_id,
                &link,
                action,
                body.value,
                "rejected: value failed validation",
            )
            .await;
            return Err(ApiError::BadRequest(msg));
        }
    };

    let settings = effective_settings(&state).await?;
    if !settings.enabled {
        return Err(ApiError::BadRequest(
            "Home Assistant is not enabled".to_owned(),
        ));
    }
    let client = ha_client(&settings)?;

    // `domain` is the stored entity's own prefix, `spec.service` is a &'static
    // str, and every `extra` KEY is a &'static param from the spec, so nothing
    // client-controlled reaches the HA URL or the service-data keys; the entity
    // id and the validated numeric value travel in the request body.
    match client
        .call_service_with(domain, spec.service, &link.entity_id, &extra)
        .await
    {
        Ok(()) => {
            audit_actuation(&state, &user, camera_id, &link, action, body.value, "ok").await;
            Ok(Json(json!({ "ok": true })))
        }
        Err(e) => {
            audit_actuation(
                &state,
                &user,
                camera_id,
                &link,
                action,
                body.value,
                "ha call failed",
            )
            .await;
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
            let attrs = v.get("attributes");
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
                unit: attrs
                    .and_then(|a| a.get("unit_of_measurement"))
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned),
                control: control_descriptor(domain_of(eid), attrs),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_url_scheme_is_required_on_save() {
        assert!(has_http_scheme("http://ha.example:8123"));
        assert!(has_http_scheme("HTTPS://ha.example"));
        assert!(!has_http_scheme("ha.example:8123"));
        assert!(!has_http_scheme("ws://ha.example:8123"));
        assert!(!has_http_scheme(""));
    }

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
        assert_eq!(p.bg_color_on, None); // per-state background inherits (0076)
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
            "shape": "pill", "bg_color": "#101014", "bg_color_on": "#B3261E",
            "outline": true,
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
        assert_eq!(p.bg_color_on.as_deref(), Some("#B3261E"));
        assert!(p.outline);
        assert_eq!(p.label.as_deref(), Some("Front door"));
    }

    #[test]
    fn placement_input_per_state_background_accepts_valid_hex_and_resets_on_null() {
        // Mirrors the 0062 bg_color coverage for the 0076 ON-state override.
        // A valid '#RRGGBB' is carried through verbatim...
        let set: PlacementInput = serde_json::from_value(json!({
            "x": 0.2, "y": 0.3, "bg_color": "#17171B", "bg_color_on": "#b3261e"
        }))
        .unwrap();
        assert_eq!(set.bg_color.as_deref(), Some("#17171B"));
        assert_eq!(set.bg_color_on.as_deref(), Some("#b3261e"));
        assert!(valid_overlay_color(set.bg_color_on.as_deref().unwrap()));

        // ...an explicit field-level null is the RESET: it reads as None, so the
        // badge goes back to inheriting the base background on the on state.
        // (A body-level null clears the whole placement, which is a different
        // thing entirely and is covered by the defaults test above.)
        let reset: PlacementInput = serde_json::from_value(json!({
            "x": 0.2, "y": 0.3, "bg_color": "#17171B", "bg_color_on": null
        }))
        .unwrap();
        assert_eq!(reset.bg_color.as_deref(), Some("#17171B"));
        assert_eq!(reset.bg_color_on, None);

        // Setting only the ON color while the base inherits the client default
        // is legal: resolution is bg_color_on ?? bg_color ?? default.
        let on_only: PlacementInput =
            serde_json::from_value(json!({"x": 0.0, "y": 0.0, "bg_color_on": "#0F9D58"})).unwrap();
        assert_eq!(on_only.bg_color, None);
        assert_eq!(on_only.bg_color_on.as_deref(), Some("#0F9D58"));

        // Garbage is rejected by the same gate the handler 400s on. These are
        // the exact strings the bg_color validation test rejects.
        for bad in ["B3261E", "#B3261", "#B3261EE", "#GGB143", "", "red"] {
            assert!(
                !valid_overlay_color(bad),
                "bg_color_on '{bad}' must be rejected"
            );
        }
    }

    #[test]
    fn link_inserts_trims_entity_id_before_storage() {
        // A padded entity_id validates on its trimmed form; storage must keep the
        // trimmed value or the link becomes a permanently un-actuatable dead entry
        // (the HA action path matches on the exact stored id).
        let update: HaLinksUpdate = serde_json::from_value(json!({
            "links": [
                {"entity_id": "  binary_sensor.front_door 	", "role": "sensor"},
                {"entity_id": "light.kitchen", "role": "actuator",
                 "device_class": "outlet", "label": "Kitchen", "sort_order": 3,
                 "require_confirm": true, "allowed_actions": ["turn_on"]}
            ]
        }))
        .unwrap();
        let tuples = link_inserts(update.links);
        assert_eq!(tuples.len(), 2);
        // Leading/trailing whitespace is stripped from the stored id.
        assert_eq!(tuples[0].0, "binary_sensor.front_door");
        assert_eq!(tuples[0].1, "sensor");
        // An already-clean id and the other fields pass through unchanged.
        assert_eq!(tuples[1].0, "light.kitchen");
        assert_eq!(tuples[1].1, "actuator");
        assert_eq!(tuples[1].2.as_deref(), Some("outlet"));
        assert_eq!(tuples[1].3.as_deref(), Some("Kitchen"));
        assert_eq!(tuples[1].4, 3);
        assert!(tuples[1].5);
        assert_eq!(tuples[1].6, Some(vec!["turn_on".to_owned()]));
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
        assert!(allowed_spec(domain_of("garage"), "turn_on").is_none());
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
                let spec = allowed_spec(domain, action)
                    .unwrap_or_else(|| panic!("{domain}.{action} must be allowlisted"));
                assert_eq!(
                    spec.service, *action,
                    "{domain}.{action} must map 1:1 to its service (discrete action)"
                );
                assert!(
                    spec.value.is_none(),
                    "{domain}.{action} is a discrete action, not a value action"
                );
            }
        }

        // The value actions (#442, Slice 1): action word != service, percent kind.
        let value_words: &[(&str, &str, &str, &str)] = &[
            ("light", "set_brightness", "turn_on", "brightness_pct"),
            ("cover", "set_position", "set_cover_position", "position"),
            ("fan", "set_speed", "set_percentage", "percentage"),
        ];
        for (domain, action, service, param) in value_words {
            let spec = allowed_spec(domain, action)
                .unwrap_or_else(|| panic!("{domain}.{action} must be allowlisted"));
            assert_eq!(spec.service, *service, "{domain}.{action} rides {service}");
            match &spec.value {
                Some(ValueKind::Percent { param: p }) => assert_eq!(p, param),
                None => panic!("{domain}.{action} must be a value action"),
            }
        }

        // ...and the allowlist contains nothing beyond the discrete + value sets.
        let expected: usize =
            allowed.iter().map(|(_, a)| a.len()).sum::<usize>() + value_words.len();
        let actual: usize = HA_ACTION_ALLOWLIST.iter().map(|(_, a)| a.len()).sum();
        assert_eq!(actual, expected, "allowlist grew or shrank unexpectedly");
    }

    #[test]
    fn allowlist_rejects_wrong_domain_unknown_and_garbage_actions() {
        // Right action word, wrong domain.
        assert!(allowed_spec("lock", "turn_on").is_none());
        assert!(allowed_spec("light", "unlock").is_none());
        assert!(allowed_spec("cover", "toggle").is_none());
        assert!(allowed_spec("scene", "turn_off").is_none());
        assert!(allowed_spec("button", "turn_on").is_none());
        assert!(allowed_spec("script", "toggle").is_none());
        assert!(allowed_spec("lock", "open_cover").is_none());

        // Unknown domains, including HA domains Crumb deliberately won't drive.
        assert!(allowed_spec("climate", "set_temperature").is_none());
        assert!(allowed_spec("alarm_control_panel", "alarm_disarm").is_none());
        assert!(allowed_spec("homeassistant", "turn_on").is_none());
        assert!(allowed_spec("shell_command", "turn_on").is_none());
        assert!(allowed_spec("", "turn_on").is_none());

        // Unknown / garbage actions.
        assert!(allowed_spec("light", "explode").is_none());
        assert!(allowed_spec("light", "").is_none());
        assert!(allowed_spec("light", "TURN_ON").is_none()); // case-sensitive
        assert!(allowed_spec("light", "turn_on ").is_none()); // handler trims
        assert!(allowed_spec("light", "turn_on;reboot").is_none());
        assert!(allowed_spec("light", "../../homeassistant/restart").is_none());
        assert!(allowed_spec("light", "turn_on/../restart").is_none());
        assert!(allowed_spec("light/../x", "turn_on").is_none());
    }

    // ─── value actions (#442, Slice 1) ──────────────────────────────────────

    #[test]
    fn value_action_spec_lookup() {
        // The three value words resolve to their ride-along service + percent kind.
        for (domain, action, service, param) in [
            ("light", "set_brightness", "turn_on", "brightness_pct"),
            ("cover", "set_position", "set_cover_position", "position"),
            ("fan", "set_speed", "set_percentage", "percentage"),
        ] {
            let spec = allowed_spec(domain, action).expect("value word allowlisted");
            assert_eq!(spec.service, service);
            match &spec.value {
                Some(ValueKind::Percent { param: p }) => assert_eq!(*p, param),
                None => panic!("{domain}.{action} must be a value action"),
            }
        }
        // Climate is Slice 2: still not allowlisted in this slice.
        assert!(allowed_spec("climate", "set_temperature").is_none());
        // A value word on the wrong domain does not resolve.
        assert!(allowed_spec("switch", "set_brightness").is_none());
        assert!(allowed_spec("light", "set_position").is_none());
    }

    #[test]
    fn validate_value_enforces_arity_range_and_rounding() {
        let discrete = allowed_spec("light", "turn_on").unwrap();
        let percent = allowed_spec("light", "set_brightness").unwrap();

        // Discrete action: no value ⇒ ok with empty extras; a value ⇒ 400.
        assert_eq!(validate_value(discrete, None).unwrap(), vec![]);
        assert!(validate_value(discrete, Some(50.0)).is_err());

        // Value action: absent value ⇒ 400.
        assert!(validate_value(percent, None).is_err());

        // Out of range (either side) and non-finite ⇒ 400.
        assert!(validate_value(percent, Some(-1.0)).is_err());
        assert!(validate_value(percent, Some(100.1)).is_err());
        assert!(validate_value(percent, Some(f64::NAN)).is_err());
        assert!(validate_value(percent, Some(f64::INFINITY)).is_err());

        // Boundaries 0 and 100 are ok and map to their integer param values.
        assert_eq!(
            validate_value(percent, Some(0.0)).unwrap(),
            vec![("brightness_pct", serde_json::json!(0))]
        );
        assert_eq!(
            validate_value(percent, Some(100.0)).unwrap(),
            vec![("brightness_pct", serde_json::json!(100))]
        );
        // Rounds to the nearest integer and sends a JSON integer.
        let extra = validate_value(percent, Some(61.6)).unwrap();
        assert_eq!(extra, vec![("brightness_pct", serde_json::json!(62))]);
        assert!(extra[0].1.is_i64() || extra[0].1.is_u64());

        // The param name follows the entity's domain, not the action word.
        assert_eq!(
            validate_value(allowed_spec("cover", "set_position").unwrap(), Some(40.4)).unwrap(),
            vec![("position", serde_json::json!(40))]
        );
        assert_eq!(
            validate_value(allowed_spec("fan", "set_speed").unwrap(), Some(66.7)).unwrap(),
            vec![("percentage", serde_json::json!(67))]
        );
    }

    #[test]
    fn action_request_parses_optional_value() {
        // Omitted ⇒ None (discrete actions), present ⇒ carried through.
        let no_value: HaActionRequest = serde_json::from_value(json!({
            "link_id": "11111111-1111-1111-1111-111111111111", "action": "toggle"
        }))
        .unwrap();
        assert_eq!(no_value.value, None);
        let with_value: HaActionRequest = serde_json::from_value(json!({
            "link_id": "11111111-1111-1111-1111-111111111111",
            "action": "set_brightness", "value": 62
        }))
        .unwrap();
        assert_eq!(with_value.value, Some(62.0));
        // A non-number value is a parse failure (400), never silently coerced.
        assert!(serde_json::from_value::<HaActionRequest>(json!({
            "link_id": "11111111-1111-1111-1111-111111111111",
            "action": "set_brightness", "value": "62"
        }))
        .is_err());
    }

    #[test]
    fn control_descriptor_projection_per_domain() {
        // Dimmable light: brightness 191/255 ⇒ round(74.9) = 75, percent kind.
        let d = control_descriptor("light", Some(&json!({"brightness": 191}))).expect("dimmable");
        assert_eq!(d.action, "set_brightness");
        assert_eq!(d.kind, "percent");
        assert_eq!(d.value, json!(75));
        assert_eq!(d.min, json!(0));
        assert_eq!(d.max, json!(100));
        assert_eq!(d.step, json!(1));
        assert!(d.unit.is_none());

        // Non-dimmable light (no brightness attr, or no attrs) ⇒ no descriptor.
        assert!(control_descriptor("light", Some(&json!({"friendly_name": "Porch"}))).is_none());
        assert!(control_descriptor("light", None).is_none());

        // Cover reports current_position verbatim.
        let c =
            control_descriptor("cover", Some(&json!({"current_position": 40}))).expect("position");
        assert_eq!(c.action, "set_position");
        assert_eq!(c.value, json!(40));
        assert!(control_descriptor("cover", Some(&json!({"state": "open"}))).is_none());

        // Fan: percentage + step from ceil(percentage_step), min 1.
        let f = control_descriptor(
            "fan",
            Some(&json!({"percentage": 66, "percentage_step": 33.3333})),
        )
        .expect("fan");
        assert_eq!(f.action, "set_speed");
        assert_eq!(f.value, json!(66));
        assert_eq!(f.step, json!(34)); // ceil(33.3333)
                                       // Missing percentage_step ⇒ step defaults to 1.
        let f2 = control_descriptor("fan", Some(&json!({"percentage": 50}))).expect("fan");
        assert_eq!(f2.step, json!(1));
        assert!(control_descriptor("fan", Some(&json!({"state": "on"}))).is_none());

        // A non-controllable domain never gets a descriptor.
        assert!(control_descriptor("switch", Some(&json!({"brightness": 100}))).is_none());
        assert!(control_descriptor("sensor", Some(&json!({"state": "72"}))).is_none());
    }

    #[test]
    fn project_states_includes_control_only_for_settable_entities() {
        let states = json!([
            {"entity_id": "light.dimmable", "state": "on", "attributes": {"brightness": 255}},
            {"entity_id": "light.plain", "state": "on", "attributes": {}},
            {"entity_id": "switch.plug", "state": "on", "attributes": {}}
        ]);
        let arr = states.as_array().unwrap();
        let wanted: std::collections::HashSet<&str> =
            ["light.dimmable", "light.plain", "switch.plug"]
                .into_iter()
                .collect();
        let out = project_states(arr, &wanted);
        let v = serde_json::to_value(&out).unwrap();

        // The dimmable light carries a control descriptor (100% at brightness 255).
        let dimmable = v
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["entity_id"] == "light.dimmable")
            .unwrap();
        assert_eq!(dimmable["control"]["action"], "set_brightness");
        assert_eq!(dimmable["control"]["value"], 100);
        // A non-dimmable light and a switch omit the field entirely (skip-if-none),
        // so an old client sees exactly today's payload.
        let plain = v
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["entity_id"] == "light.plain")
            .unwrap();
        assert!(plain.get("control").is_none());
        let plug = v
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["entity_id"] == "switch.plug")
            .unwrap();
        assert!(plug.get("control").is_none());
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

    // ─── per-link control config (migration 0075, issue #440) ────────────────

    #[test]
    fn allowed_actions_enforcement_null_allows_all_and_list_restricts() {
        // Null ⇒ unrestricted: every action the domain allowlist already permits
        // still passes (today's behavior).
        assert!(action_permitted_by_link(None, "turn_on"));
        assert!(action_permitted_by_link(None, "turn_off"));
        assert!(action_permitted_by_link(None, "toggle"));

        // A link restricted to turn_on: turn_on passes, turn_off / toggle do not,
        // even though they are perfectly valid LIGHT actions (this is the whole
        // point — the restriction is tighter than the domain allowlist).
        let only_on = [String::from("turn_on")];
        assert!(action_permitted_by_link(Some(&only_on), "turn_on"));
        assert!(!action_permitted_by_link(Some(&only_on), "turn_off"));
        assert!(!action_permitted_by_link(Some(&only_on), "toggle"));

        // An empty list ⇒ nothing is permitted (control fully disabled).
        let none: [String; 0] = [];
        assert!(!action_permitted_by_link(Some(&none), "turn_on"));
    }

    #[test]
    fn allowed_actions_write_validation_matches_the_domain_allowlist() {
        // A subset of the entity domain's own actions is accepted.
        assert!(validate_allowed_actions(
            "light.kitchen",
            &["turn_on".to_owned(), "toggle".to_owned()]
        )
        .is_ok());
        assert!(validate_allowed_actions("cover.garage", &["open_cover".to_owned()]).is_ok());
        // An empty list is a valid "no actions permitted" configuration.
        assert!(validate_allowed_actions("light.kitchen", &[]).is_ok());

        // An action from a DIFFERENT domain, or garbage, is rejected at write.
        assert!(validate_allowed_actions("light.kitchen", &["open_cover".to_owned()]).is_err());
        assert!(validate_allowed_actions("lock.front", &["turn_on".to_owned()]).is_err());
        assert!(validate_allowed_actions("sensor.temp", &["turn_on".to_owned()]).is_err());
        // The rejection names the offending action and carries no em-dash.
        let msg = validate_allowed_actions("light.kitchen", &["explode".to_owned()]).unwrap_err();
        assert!(msg.contains("explode"));
        assert!(!msg.contains('\u{2014}'));
    }

    #[test]
    fn link_input_parses_control_config_with_today_default() {
        // Omitted ⇒ require_confirm=false, allowed_actions=None (today's behavior),
        // so an existing admin-console/desktop payload that predates #440 keeps
        // writing links exactly as before.
        let bare: HaLinkInput = serde_json::from_value(json!({
            "entity_id": "light.kitchen", "role": "actuator"
        }))
        .unwrap();
        assert!(!bare.require_confirm);
        assert_eq!(bare.allowed_actions, None);

        // Present ⇒ carried through verbatim.
        let full: HaLinkInput = serde_json::from_value(json!({
            "entity_id": "cover.garage", "role": "actuator",
            "require_confirm": true,
            "allowed_actions": ["open_cover", "close_cover"]
        }))
        .unwrap();
        assert!(full.require_confirm);
        assert_eq!(
            full.allowed_actions,
            Some(vec!["open_cover".to_owned(), "close_cover".to_owned()])
        );
    }

    #[test]
    fn link_dto_exposes_control_config_for_clients() {
        use crumb_common::types::CameraHaLink;
        let link = CameraHaLink {
            id: Uuid::nil(),
            camera_id: Uuid::nil(),
            entity_id: "cover.garage".to_owned(),
            role: "actuator".to_owned(),
            device_class: None,
            label: None,
            sort_order: 0,
            overlay_x: None,
            overlay_y: None,
            overlay_size: None,
            overlay_color: None,
            overlay_icon: None,
            overlay_show_state: false,
            overlay_show_age: false,
            overlay_opacity: None,
            overlay_shape: None,
            overlay_bg_color: None,
            overlay_bg_color_on: None,
            overlay_outline: false,
            require_confirm: true,
            allowed_actions: Some(vec!["open_cover".to_owned()]),
        };
        let dto = HaLinkDto::from(link);
        let v = serde_json::to_value(dto).unwrap();
        assert_eq!(v["require_confirm"], true);
        assert_eq!(v["allowed_actions"][0], "open_cover");

        // A link with the migration defaults round-trips to the "unchanged"
        // shape: require_confirm=false, allowed_actions=null.
        let default = CameraHaLink {
            id: Uuid::nil(),
            camera_id: Uuid::nil(),
            entity_id: "light.kitchen".to_owned(),
            role: "actuator".to_owned(),
            device_class: None,
            label: None,
            sort_order: 0,
            overlay_x: None,
            overlay_y: None,
            overlay_size: None,
            overlay_color: None,
            overlay_icon: None,
            overlay_show_state: false,
            overlay_show_age: false,
            overlay_opacity: None,
            overlay_shape: None,
            overlay_bg_color: None,
            overlay_bg_color_on: None,
            overlay_outline: false,
            require_confirm: false,
            allowed_actions: None,
        };
        let v = serde_json::to_value(HaLinkDto::from(default)).unwrap();
        assert_eq!(v["require_confirm"], false);
        assert!(v["allowed_actions"].is_null());
    }

    #[test]
    fn link_dto_carries_per_state_background_to_clients() {
        use crumb_common::types::CameraHaLink;
        let base = CameraHaLink {
            id: Uuid::nil(),
            camera_id: Uuid::nil(),
            entity_id: "binary_sensor.front_door".to_owned(),
            role: "sensor".to_owned(),
            device_class: Some("door".to_owned()),
            label: None,
            sort_order: 0,
            overlay_x: Some(0.25),
            overlay_y: Some(0.75),
            overlay_size: Some(1.0),
            overlay_color: None,
            overlay_icon: None,
            overlay_show_state: false,
            overlay_show_age: false,
            overlay_opacity: None,
            overlay_shape: Some("pill".to_owned()),
            overlay_bg_color: Some("#17171B".to_owned()),
            overlay_bg_color_on: Some("#B3261E".to_owned()),
            overlay_outline: false,
            require_confirm: false,
            allowed_actions: None,
        };
        let v = serde_json::to_value(HaLinkDto::from(base.clone())).unwrap();
        // Both backgrounds ride the wire; the client picks by edge_on.
        assert_eq!(v["overlay_bg_color"], "#17171B");
        assert_eq!(v["overlay_bg_color_on"], "#B3261E");

        // A badge that predates 0076 serializes the new field as null, which is
        // exactly "inherit the base for the on state" — i.e. today's rendering.
        let inherited = CameraHaLink {
            overlay_bg_color_on: None,
            ..base
        };
        let v = serde_json::to_value(HaLinkDto::from(inherited)).unwrap();
        assert_eq!(v["overlay_bg_color"], "#17171B");
        assert!(v["overlay_bg_color_on"].is_null());
    }
}
