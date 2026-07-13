// SPDX-License-Identifier: AGPL-3.0-or-later

//! Data-Transfer Objects (request bodies and response shapes) for the
//! Crumb NVR API.
//!
//! All types derive [`serde::Serialize`] / [`serde::Deserialize`] and use
//! `snake_case` field names matching the JSON wire format.
//!
//! # Design rules
//!
//! * `password_hash` and other credentials are **never** included in response
//!   DTOs — only the handler that creates/updates a user ever touches the hash.
//! * UUIDs are serialised as lowercase hyphenated strings (`uuid` crate default).
//! * Timestamps use RFC 3339 / ISO 8601 strings (`chrono` serde feature).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crumb_common::types::{Capabilities, RecordingMode, UserRole};

// ─── auth ─────────────────────────────────────────────────────────────────────

/// `POST /auth/login` request body.
#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
    /// When true, mint a long-lived ("keep me signed in") token instead of the
    /// config's default expiry. Used by the mobile app's save-login toggle so the
    /// session survives well beyond the default 1-day window. Defaults to false so
    /// existing clients (which omit the field) keep the normal expiry.
    #[serde(default)]
    pub remember: bool,
}

/// `POST /auth/login` response.
#[derive(Debug, Serialize)]
pub struct LoginResponse {
    /// Bearer token — put in `Authorization: Bearer <token>` on subsequent requests.
    pub token: String,
    /// UTC timestamp at which the token expires.
    pub expires_at: DateTime<Utc>,
}

/// JWT claims — the payload embedded in every token.
///
/// Named fields match IANA registered claim names where applicable.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Claims {
    /// Subject — the user's UUID.
    pub sub: String,
    /// Expiry — Unix timestamp (seconds since epoch).
    pub exp: u64,
    /// Issued-at — Unix timestamp.
    pub iat: u64,
    /// Role — `"admin"` or `"viewer"`. Legacy mirror of the assigned role's
    /// `is_admin`; the `AdminUser` gate still reads this.
    pub role: String,
    /// LEGACY camera scope baked into the token. Superseded by the role's cameras,
    /// which the auth extractor resolves from `role_id`. Kept for back-compat with
    /// tokens issued before RBAC and as a fallback when a role can't be resolved.
    pub camera_ids: Vec<String>,
    /// Assigned permission-role id (the source of truth for capabilities + camera
    /// scope). `None` on legacy tokens issued before RBAC. `#[serde(default)]` so
    /// those older tokens still deserialize.
    #[serde(default)]
    pub role_id: Option<String>,
    /// Session id (JWT ID) — a UUID that ties this token to a revocable `sessions`
    /// row (migration 0033). The `AuthUser` extractor rejects the token if this
    /// `jti` is revoked. `None` on legacy tokens minted before P0-SESSIONS:
    /// `#[serde(default)]` keeps those deserializing, and the extractor treats a
    /// `jti`-less token as "legacy, not revocable" (unchanged behaviour) unless
    /// the owner opts into rejecting legacy tokens.
    #[serde(default)]
    pub jti: Option<String>,
}

/// Claims for a **scoped, short-lived media token** (P0-SESSIONS).
///
/// Minted by `GET /media-token?camera=<id>` for an authenticated caller and
/// used ONLY as `?token=` on the media endpoints (segment/live/clip/filmstrip/
/// snapshot/export-download). Unlike the full [`Claims`] bearer JWT, it carries
/// no role/capability payload and is scoped to a single camera for ~15 min (see
/// `MEDIA_TOKEN_EXPIRY_SECONDS` = 900 in auth.rs — long enough to outlast a
/// clip's continuous playback), so if it leaks into a proxy/access log the blast
/// radius is one camera for fifteen minutes rather than the user's entire
/// (possibly 10-year) session.
///
/// Signed with the SAME `JWT_SECRET` (no new secret) but disambiguated from a
/// normal access token by the `typ: "media"` claim, which the media auth path
/// requires and the JSON-API bearer path rejects.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct MediaClaims {
    /// Subject — the user's UUID (for audit/log correlation).
    pub sub: String,
    /// Token type discriminator — always `"media"`. Guards against a media token
    /// being replayed as a full bearer token (and vice-versa).
    pub typ: String,
    /// The single camera UUID this token authorises. Media handlers assert the
    /// requested resource belongs to this camera.
    pub cam: String,
    /// Expiry — Unix timestamp (seconds). Short (~15 min; see auth.rs).
    pub exp: u64,
    /// Issued-at — Unix timestamp.
    pub iat: u64,
}

// ─── users ────────────────────────────────────────────────────────────────────

/// Response shape for a single user (no `password_hash`).
#[derive(Debug, Serialize)]
pub struct UserDto {
    pub id: Uuid,
    pub username: String,
    pub role: UserRole,
    /// UUIDs of cameras this viewer is allowed to access.  Empty for admins.
    /// LEGACY: superseded by the assigned role's cameras (`role_id`).
    pub camera_ids: Vec<Uuid>,
    /// Assigned permission role (source of truth for capabilities + cameras).
    pub role_id: Option<Uuid>,
}

/// `POST /config/users` request body.
#[derive(Debug, Deserialize)]
pub struct CreateUserRequest {
    pub username: String,
    /// Plain-text password — hashed in the handler with argon2; never stored.
    pub password: String,
    /// New model: assign a permission role by id (carries capabilities + cameras).
    /// When set, it supersedes the legacy `role`/`camera_ids` fields.
    #[serde(default)]
    pub role_id: Option<Uuid>,
    /// LEGACY binary role — used only when `role_id` is absent (older clients).
    #[serde(default)]
    pub role: Option<UserRole>,
    /// LEGACY per-user camera list — used only when `role_id` is absent.
    #[serde(default)]
    pub camera_ids: Vec<Uuid>,
}

/// `GET /auth/me` response — the caller's profile plus their EFFECTIVE permissions
/// (resolved from the assigned role) so clients can gate UI. The server enforces
/// regardless; this is for hiding/disabling controls the user can't use.
#[derive(Debug, Serialize)]
pub struct MeResponse {
    pub id: Uuid,
    pub username: String,
    /// Effective role (admin/viewer) — kept for back-compat with clients reading `role`.
    pub role: UserRole,
    pub is_admin: bool,
    /// Effective capabilities from the assigned role (admin ⇒ all true).
    pub capabilities: Capabilities,
    /// Effective accessible camera ids (from the role; empty for admins = all).
    pub camera_ids: Vec<Uuid>,
    pub role_id: Option<Uuid>,
}

// ─── sessions (revocable auth) ─────────────────────────────────────────────────

/// One row in the `GET /auth/sessions` list (a user's active + recent sessions).
///
/// `is_current` marks the session the request itself is authenticated with, so
/// the UI can label "this device" and warn before revoking it.
#[derive(Debug, Serialize)]
pub struct SessionDto {
    pub jti: Uuid,
    pub label: Option<String>,
    pub ip: Option<String>,
    pub long_lived: bool,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
    /// True iff this is the session the current request is using.
    pub is_current: bool,
}

/// `GET /media-token` response — a scoped, short-lived media token (see
/// [`MediaClaims`]) usable ONLY as `?token=` on media endpoints for `camera_id`.
#[derive(Debug, Serialize)]
pub struct MediaTokenResponse {
    pub token: String,
    pub camera_id: Uuid,
    pub expires_at: DateTime<Utc>,
}

/// `PUT /config/users/{id}` request body.  All fields optional — only provided
/// fields are updated.
#[derive(Debug, Deserialize)]
pub struct UpdateUserRequest {
    pub username: Option<String>,
    /// If provided, the password is re-hashed.
    pub password: Option<String>,
    /// Reassign the user's permission role (new model).
    pub role_id: Option<Uuid>,
    /// LEGACY fields — applied only when `role_id` is absent.
    pub role: Option<UserRole>,
    pub camera_ids: Option<Vec<Uuid>>,
}

// ─── cameras ──────────────────────────────────────────────────────────────────

/// Viewer-safe camera summary.
///
/// Returned by `GET /cameras` (the viewer-facing camera list). Contains ONLY
/// the fields a viewer needs to enumerate cameras and build live-view URLs.
/// Deliberately omits all secrets and internal plumbing: `main_url`,
/// `source_url`, `onvif_host`/`onvif_user`, `go2rtc_name`, and policy/motion
/// internals are never present in this DTO.
#[derive(Debug, Serialize)]
pub struct ViewerCameraDto {
    pub id: Uuid,
    pub name: String,
    pub enabled: bool,
    /// `true` when a sub-stream is configured (`sub_url` is `Some`).
    pub has_sub: bool,
    /// `true` when ONVIF PTZ is configured (`onvif_host` is `Some`).
    pub ptz: bool,
    /// Physical form-factor glyph hint (`"ptz"`, `"dome"`, `"bullet"`, `"lpr"`,
    /// `"other"`). `null` for legacy rows that pre-date the type column.
    pub camera_type: Option<String>,
    /// Optional explicit glyph-key override. `null` means derive from
    /// `camera_type`. Matches the same field in [`CameraDto`].
    pub icon: Option<String>,
    /// Restreamer that owns this camera's go2rtc stream (`"crumb"` or `"frigate"`).
    /// Clients need this to pick the correct RTSP/WebRTC base URL.
    pub served_by: String,
    pub created_at: DateTime<Utc>,
}

/// Response shape for a camera (with embedded policy summary).
#[derive(Debug, Serialize)]
pub struct CameraDto {
    pub id: Uuid,
    pub name: String,
    pub enabled: bool,
    pub go2rtc_name: String,
    pub main_url: String,
    pub sub_url: Option<String>,
    /// Raw camera RTSP source — set for Crumb-managed cameras (the API owns their
    /// go2rtc stream). `None` for legacy/externally-configured streams.
    pub source_url: Option<String>,
    pub source_sub_url: Option<String>,
    /// The camera's OWN direct recording policy id, or `null` when it inherits
    /// (from its group, else the global default). The UI uses this together with
    /// `group_id` to render "Inherit from group X" vs an explicit named policy.
    pub policy_id: Option<Uuid>,
    /// The recording group this camera belongs to, or `null`. Lets the UI show
    /// where an inherited policy comes from.
    pub group_id: Option<Uuid>,
    /// The RESOLVED effective policy (own → group's → default) — what actually
    /// governs recording. Inheritance is already applied here.
    pub policy: RecordingPolicyDto,
    pub motion_mask: Option<serde_json::Value>,
    pub onvif_motion: bool,
    /// DEPRECATED (migration 0049): superseded by the `motion_*_enabled` set
    /// below. Still emitted for older clients; new clients use the booleans.
    pub motion_source: String,
    /// Additive motion sources: a camera records on the UNION of every enabled
    /// source. Each is toggled independently.
    pub motion_pixel_enabled: bool,
    pub motion_frigate_enabled: bool,
    pub motion_ha_enabled: bool,
    /// Pixel detector when the pixel source is enabled: census / framediff / mog2 /
    /// opticalflow / ensemble.
    pub motion_algorithm: String,
    /// Physical camera form-factor for the console glyph: `"ptz"`, `"dome"`,
    /// `"bullet"`, `"lpr"`, or `"other"`. `null` (legacy rows) renders the
    /// generic icon.
    pub camera_type: Option<String>,
    /// OPTIONAL explicit glyph-key override (`"cam_ptz"`/`"cam_dome"`/…). `null`
    /// means "derive from `camera_type`". The console renders `icon ?? type-glyph`.
    pub icon: Option<String>,
    /// Motion-tuner exclusion-grid authoring resolution the operator last picked
    /// (UI preference; `null` ⇒ client default 16×9). The recorder ignores these.
    pub motion_grid_cols: Option<i16>,
    pub motion_grid_rows: Option<i16>,
    pub created_at: DateTime<Utc>,
    // ── distributability fields (C10) ─────────────────────────────────────────
    /// Which restreamer owns this camera's go2rtc stream: `"crumb"` (Crumb's own
    /// embedded go2rtc, default) or `"frigate"` (an external Frigate's go2rtc).
    /// Drives URL base selection in playback/live/frame handlers.
    pub served_by: String,
    /// Frigate event mapping: the Frigate camera name used to match detection
    /// events to this camera. Set when `motion_source == "frigate"`. `null` for
    /// pixel-only cameras.
    pub source_camera_name: Option<String>,
    /// ONVIF host address for PTZ and stream re-detection. `null` if ONVIF is not
    /// configured for this camera.
    pub onvif_host: Option<String>,
    /// ONVIF service port (default 80). `null` when no ONVIF host is set.
    pub onvif_port: Option<i32>,
    /// ONVIF username. `null` when no ONVIF credentials are stored.
    pub onvif_user: Option<String>,
    /// `true` when an ONVIF password is stored for this camera. The password
    /// itself is NEVER returned — this flag lets the UI show "•••• (change)" vs
    /// an empty field.
    pub onvif_has_password: bool,
}

/// `POST /config/cameras` request body.
///
/// Two ways to add a camera:
/// * **Self-service (preferred):** supply `name` + `source_url` (the raw camera
///   RTSP). The API derives `go2rtc_name` + the re-stream `main_url`/`sub_url`
///   and configures go2rtc itself.
/// * **Legacy/manual:** supply `go2rtc_name` + `main_url` directly (the operator
///   pre-configured the stream). `source_url` stays null.
#[derive(Debug, Deserialize)]
pub struct CreateCameraRequest {
    pub name: String,
    /// Raw camera RTSP URL — triggers the self-service flow when present.
    pub source_url: Option<String>,
    pub source_sub_url: Option<String>,
    /// Legacy: explicit go2rtc stream name (required if `source_url` is absent).
    pub go2rtc_name: Option<String>,
    /// Legacy: explicit re-stream URL (required if `source_url` is absent).
    pub main_url: Option<String>,
    pub sub_url: Option<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub motion_mask: Option<serde_json::Value>,
    #[serde(default)]
    pub onvif_motion: bool,
    /// Motion source — `"pixel"` (default) or `"frigate"`.
    pub motion_source: Option<String>,
    /// Pixel detector — census (default) / framediff / mog2 / opticalflow / ensemble.
    pub motion_algorithm: Option<String>,
    /// Camera form-factor for the console glyph — ptz / dome / bullet / lpr /
    /// other. Omitted/`null` leaves it unset (rendered as the generic icon).
    pub camera_type: Option<String>,
    /// Optional explicit glyph-key override (`cam_*`, or a bare type word).
    /// Omitted/`null` derives the glyph from `camera_type`.
    pub icon: Option<String>,
    // ── distributability fields (C10) ─────────────────────────────────────────
    /// Restreamer ownership: `"crumb"` (default) or `"frigate"`.
    /// Omitted/`null` defaults to `"crumb"`.
    pub served_by: Option<String>,
    /// Frigate detection event camera name mapping. Set when wiring a BYO-Frigate
    /// camera so detection events can be matched back to this camera.
    pub source_camera_name: Option<String>,
    /// ONVIF host address (e.g. `"192.168.1.50"`). Required for PTZ + re-detect.
    pub onvif_host: Option<String>,
    /// ONVIF service port. Omitted/`null` defaults to `80`.
    pub onvif_port: Option<i32>,
    /// ONVIF username.
    pub onvif_user: Option<String>,
    /// ONVIF password — **write-only**. Never returned in responses.
    pub onvif_password: Option<String>,
}

/// `PUT /config/cameras/{id}` request body.
#[derive(Debug, Deserialize)]
pub struct UpdateCameraRequest {
    pub name: Option<String>,
    pub go2rtc_name: Option<String>,
    pub main_url: Option<String>,
    /// Change the re-stream sub URL: `Some(Some(v))` sets it, `Some(None)` clears
    /// it (removes the sub stream), omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub sub_url: Option<Option<String>>,
    /// Raw source RTSP — when changed, the API re-derives the re-stream URLs and
    /// re-syncs go2rtc. `Some(None)` detaches the camera from Crumb-managed go2rtc.
    #[serde(default, deserialize_with = "double_option")]
    pub source_url: Option<Option<String>>,
    /// Raw sub-stream RTSP source. `Some(None)` clears it; omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub source_sub_url: Option<Option<String>>,
    pub enabled: Option<bool>,
    /// Motion exclusion mask. `Some(None)` clears it; omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub motion_mask: Option<Option<serde_json::Value>>,
    pub onvif_motion: Option<bool>,
    /// DEPRECATED (migration 0049): superseded by the `motion_*_enabled` set.
    /// Omitted = unchanged.
    pub motion_source: Option<String>,
    /// Change the additive motion sources (migration 0049). Each `Some(v)` toggles
    /// that source; omitted = unchanged. A camera records on the UNION of the
    /// enabled sources; zero enabled records everything (fail-open).
    pub motion_pixel_enabled: Option<bool>,
    pub motion_frigate_enabled: Option<bool>,
    pub motion_ha_enabled: Option<bool>,
    /// Change the pixel detector; omitted = unchanged.
    pub motion_algorithm: Option<String>,
    /// Change the camera form-factor glyph: `Some(Some("dome"))` sets it,
    /// `Some(None)` clears it back to the generic icon, omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub camera_type: Option<Option<String>>,
    /// Change the explicit glyph-key override: `Some(Some("cam_dome"))` pins it,
    /// `Some(None)` clears it back to deriving from `camera_type`, omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub icon: Option<Option<String>>,
    /// Persist the motion-tuner authoring grid size (UI preference). Omitted =
    /// unchanged; a value sets it. Sent together by the tuner when the user picks
    /// a grid.
    pub motion_grid_cols: Option<i16>,
    pub motion_grid_rows: Option<i16>,
    /// Recording-policy ASSIGNMENT: pin the camera to a named policy
    /// (`Some(Some(id))`), clear it so the camera INHERITS from its group/default
    /// (`Some(None)`), or leave the current assignment unchanged (omitted/`None`).
    /// Distinct from `PUT /cameras/{id}/policy`, which edits the policy's *fields*
    /// via per-camera copy-on-write.
    #[serde(default, deserialize_with = "double_option")]
    pub policy_id: Option<Option<Uuid>>,
    // ── distributability fields (C10) ─────────────────────────────────────────
    /// Change the restreamer ownership: `"crumb"` or `"frigate"`. Omitted = unchanged.
    pub served_by: Option<String>,
    /// Frigate detection event camera name mapping.
    /// `Some(None)` clears it; `Some(Some(v))` sets it; omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub source_camera_name: Option<Option<String>>,
    /// ONVIF host address.
    /// `Some(None)` clears; `Some(Some(v))` sets; omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub onvif_host: Option<Option<String>>,
    /// ONVIF service port.
    /// `Some(None)` clears; `Some(Some(v))` sets; omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub onvif_port: Option<Option<i32>>,
    /// ONVIF username.
    /// `Some(None)` clears; `Some(Some(v))` sets; omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub onvif_user: Option<Option<String>>,
    /// ONVIF password — **write-only**.
    /// `Some(None)` clears the stored password; `Some(Some(v))` updates it;
    /// omitted = leave existing password unchanged. Never echo back.
    #[serde(default, deserialize_with = "double_option")]
    pub onvif_password: Option<Option<String>>,
    /// Camera make (ONVIF `Manufacturer`, or MANUAL entry for a non-ONVIF camera).
    /// Matched against the bundled compatibility DB (issue #48). `Some(Some(v))`
    /// sets, `Some(None)` clears, omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub make: Option<Option<String>>,
    /// Camera model. Same double-option semantics as [`Self::make`].
    #[serde(default, deserialize_with = "double_option")]
    pub model: Option<Option<String>>,
    /// Camera firmware (informational only, never gates a compat match). Same
    /// double-option semantics as [`Self::make`].
    #[serde(default, deserialize_with = "double_option")]
    pub firmware: Option<Option<String>>,
}

fn default_true() -> bool {
    true
}

// ─── recording policies ───────────────────────────────────────────────────────

/// Response shape for a recording policy row.
#[derive(Debug, Serialize)]
pub struct RecordingPolicyDto {
    pub id: Uuid,
    /// Human label for a named, reusable policy. `null` ⇒ an anonymous
    /// per-camera copy-on-write fork ("custom"), not offered for reuse.
    pub name: Option<String>,
    pub is_default: bool,
    pub mode: RecordingMode,
    pub live_storage_id: Option<Uuid>,
    pub live_retention_hours: i32,
    pub archive_enabled: bool,
    pub archive_storage_id: Option<Uuid>,
    pub archive_schedule: Option<String>,
    pub archive_retention_hours: Option<i32>,
    /// Size cap (BYTES) on LIVE-stage footage. `null` ⇒ no cap. UI presents GB.
    pub live_max_bytes: Option<i64>,
    /// Size cap (BYTES) on ARCHIVE-stage footage. `null` ⇒ no cap. UI presents GB.
    pub archive_max_bytes: Option<i64>,
    /// Per-policy FRACTIONAL free-space floor override (0..1) on the live disk.
    /// `null` ⇒ system default (`MIN_FREE_FRACTION`, 0.05). UI presents %.
    pub live_min_free_pct: Option<f32>,
    /// Per-policy ABSOLUTE free-space floor override (BYTES) on the live disk.
    /// `null` ⇒ system default (`MIN_FREE_BYTES`, 50 GiB). UI presents GB.
    pub live_min_free_bytes: Option<i64>,
    /// Low-water spill buffer (BYTES): how far past the trigger eviction overshoots
    /// so it batches. `null`/0 ⇒ no hysteresis. UI presents GB.
    pub live_spill_low_water_bytes: Option<i64>,
    /// Absolute maximum-retention cap (DAYS): footage older than this is deleted
    /// across both stages regardless of the size caps or per-tier windows. `null`
    /// ⇒ OFF (no cap; the default). An opt-in data-minimization ceiling.
    pub max_retention_days: Option<i32>,
    pub motion_pre_seconds: i32,
    pub motion_post_seconds: i32,
    pub motion_sensitivity: String,
    /// Manual-mode motion floor as a FRACTION of frame area (0..1) — same unit as
    /// `motion_score`. Clients display it as `× 100` = %.
    pub motion_threshold: Option<f32>,
    pub motion_keyframes_only: bool,
    pub record_stream: String,
    pub record_audio: bool,
}

/// Deserialize `Option<Option<T>>` so an explicit JSON `null` becomes `Some(None)`
/// ("clear this field to NULL"), distinct from an ABSENT field (`None` — "leave
/// unchanged"). Serde's stock `Option` impl collapses `null` to the OUTER `None`,
/// erasing that distinction; pairing this with `#[serde(default)]` restores it.
/// Without it, a policy save that sends `"archive_max_bytes": null` to drop the
/// cap is read as "unchanged" → inherits the base policy's cap → then fails the
/// `archive_max_bytes requires archive_enabled` cross-field check (archive off).
fn double_option<'de, T, D>(de: D) -> Result<Option<Option<T>>, D::Error>
where
    T: Deserialize<'de>,
    D: serde::Deserializer<'de>,
{
    Deserialize::deserialize(de).map(Some)
}

/// `PUT /config/cameras/{id}/policy` or `PUT /config/policy/default` body.
///
/// All fields are optional; omitted fields retain their current value.
#[derive(Debug, Default, Deserialize)]
pub struct UpdatePolicyRequest {
    pub mode: Option<RecordingMode>,
    pub live_storage_id: Option<Uuid>,
    pub live_retention_hours: Option<i32>,
    pub archive_enabled: Option<bool>,
    #[serde(default, deserialize_with = "double_option")]
    pub archive_storage_id: Option<Option<Uuid>>,
    #[serde(default, deserialize_with = "double_option")]
    pub archive_schedule: Option<Option<String>>,
    #[serde(default, deserialize_with = "double_option")]
    pub archive_retention_hours: Option<Option<i32>>,
    /// Size cap (BYTES) on LIVE-stage footage. `Some(None)` clears it (→ NULL =
    /// no cap); omitted leaves it unchanged. Same pattern as
    /// `archive_retention_hours`.
    #[serde(default, deserialize_with = "double_option")]
    pub live_max_bytes: Option<Option<i64>>,
    /// Size cap (BYTES) on ARCHIVE-stage footage. `Some(None)` clears it. Only
    /// valid (validated cross-field) when `archive_enabled` is effectively true.
    #[serde(default, deserialize_with = "double_option")]
    pub archive_max_bytes: Option<Option<i64>>,
    /// Per-policy FRACTIONAL free-space floor (0..1). `Some(None)` clears it (→
    /// system default); omitted leaves unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub live_min_free_pct: Option<Option<f32>>,
    /// Per-policy ABSOLUTE free-space floor (BYTES). `Some(None)` clears it.
    #[serde(default, deserialize_with = "double_option")]
    pub live_min_free_bytes: Option<Option<i64>>,
    /// Low-water spill buffer (BYTES). `Some(None)`/0 clears it (no hysteresis).
    #[serde(default, deserialize_with = "double_option")]
    pub live_spill_low_water_bytes: Option<Option<i64>>,
    /// Absolute maximum-retention cap (DAYS). `Some(None)` clears it (→ NULL = OFF,
    /// no cap); omitted leaves it unchanged. Same `Some(None)`-clears pattern as
    /// the size caps.
    #[serde(default, deserialize_with = "double_option")]
    pub max_retention_days: Option<Option<i32>>,
    pub motion_pre_seconds: Option<i32>,
    pub motion_post_seconds: Option<i32>,
    pub motion_sensitivity: Option<String>,
    /// Fraction of frame area (0..1); `Some(None)` clears it (→ default floor).
    /// `#[serde(default, deserialize_with = "double_option")]` ensures a JSON
    /// `null` sends `Some(None)` ("clear") rather than collapsing to `None`
    /// ("leave unchanged"), which is the bug for "remove manual threshold".
    #[serde(default, deserialize_with = "double_option")]
    pub motion_threshold: Option<Option<f32>>,
    pub motion_keyframes_only: Option<bool>,
    pub record_stream: Option<String>,
    pub record_audio: Option<bool>,
}

/// `POST /config/policies` request body — create a **named, reusable** policy.
///
/// All recording knobs are optional; omitted fields take the same defaults the
/// schema/default policy use. `name` is required (a reusable policy must be named
/// — anonymous forks are created internally by the per-camera copy-on-write path,
/// never via this endpoint). Reuses [`UpdatePolicyRequest`]'s field shapes for the
/// knobs so the same `apply_*` merge logic and validation apply.
#[derive(Debug, Deserialize)]
pub struct CreatePolicyRequest {
    pub name: String,
    #[serde(flatten)]
    pub fields: UpdatePolicyRequest,
}

/// `PUT /config/policies/{id}` request body — edit a named policy.
///
/// `name` (when present) renames the policy; the rest are the usual partial
/// recording-knob patch.
#[derive(Debug, Deserialize)]
pub struct UpdateNamedPolicyRequest {
    pub name: Option<String>,
    #[serde(flatten)]
    pub fields: UpdatePolicyRequest,
}

// ─── camera groups ────────────────────────────────────────────────────────────

/// Response shape for a camera group with its member camera ids.
#[derive(Debug, Serialize)]
pub struct CameraGroupDto {
    pub id: Uuid,
    pub name: String,
    /// The named policy applied to this group's members (unless a member has its
    /// own direct policy). `null` ⇒ the group inherits the global default.
    pub policy_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    /// Member camera UUIDs (a camera belongs to at most one group).
    pub camera_ids: Vec<Uuid>,
}

/// `POST /config/groups` request body.
#[derive(Debug, Deserialize)]
pub struct CreateGroupRequest {
    pub name: String,
    /// Optional policy to apply to members. `null`/omitted ⇒ inherit the default.
    #[serde(default)]
    pub policy_id: Option<Uuid>,
    /// Initial member camera ids (optional). A camera already in another group is
    /// MOVED here.
    #[serde(default)]
    pub camera_ids: Vec<Uuid>,
}

/// `PUT /config/groups/{id}` request body. `name` is required (rename or keep);
/// `policy_id` is `Option<Option<Uuid>>` so `Some(None)` clears the group policy
/// while omitting it leaves the policy unchanged.
#[derive(Debug, Deserialize)]
pub struct UpdateGroupRequest {
    pub name: Option<String>,
    // `double_option` so an explicit JSON `null` deserializes to `Some(None)`
    // ("clear / inherit the default") rather than collapsing to the outer
    // `None` ("unchanged"). The admin "Inherit — use global default" choice
    // sends `null`; without this it would silently keep the old group policy.
    #[serde(default, deserialize_with = "double_option")]
    pub policy_id: Option<Option<Uuid>>,
}

/// `PUT /config/groups/{id}/members` request body — replaces membership wholesale.
#[derive(Debug, Deserialize)]
pub struct SetMembersRequest {
    pub camera_ids: Vec<Uuid>,
}

// ─── storages ─────────────────────────────────────────────────────────────────

/// Response shape for a storage row with live free-space data.
#[derive(Debug, Serialize)]
pub struct StorageDto {
    pub id: Uuid,
    pub name: String,
    pub path: String,
    /// Optional CONFIGURED capacity cap (manual override). Usually null.
    pub total_bytes: Option<i64>,
    /// Live FILESYSTEM total size at `path` (statvfs). The admin draws the capacity
    /// bar from this when no manual cap is set, so capacity shows with no config.
    pub fs_total_bytes: Option<i64>,
    pub free_bytes: Option<i64>,
    /// OPTIONAL explicit media-glyph override (`"ssd"`/`"hdd"`/`"disk"`). `null`
    /// means "infer from the name". The admin console shows the picker's current
    /// selection from this; it computes the displayed glyph as `icon ?? infer(name)`.
    pub icon: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// `POST /config/storages` request body.
#[derive(Debug, Deserialize)]
pub struct CreateStorageRequest {
    pub name: String,
    pub path: String,
    pub total_bytes: Option<i64>,
    /// Optional media-glyph override (`ssd`/`hdd`/`disk`); omitted/`null` infers from name.
    pub icon: Option<String>,
}

/// `PUT /config/storages/{id}` request body.
#[derive(Debug, Deserialize)]
pub struct UpdateStorageRequest {
    pub name: Option<String>,
    pub path: Option<String>,
    /// Change the capacity cap: `Some(Some(n))` sets it (bytes), `Some(None)`
    /// clears it (→ uncapped), omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub total_bytes: Option<Option<i64>>,
    /// Change the media-glyph override: `Some(Some("ssd"))` pins it, `Some(None)`
    /// clears it back to name-inference, omitted = unchanged.
    #[serde(default, deserialize_with = "double_option")]
    pub icon: Option<Option<String>>,
}

/// `POST /config/policies/{id}/change-storage` — repoint a policy's live/archive
/// storage and (optionally) drain its existing footage to the new disk.
#[derive(Debug, Deserialize)]
pub struct ChangeStorageRequest {
    /// Which storage role to repoint: `"live"` or `"archive"`.
    pub stage: String,
    /// The storage to point the policy at.
    pub to_storage_id: Uuid,
    /// When true, enqueue a background drain of EXISTING footage from the old disk
    /// to the new one. When false, only NEW footage lands on the new disk (existing
    /// stays put and keeps serving correctly — resolved by `storage_id`).
    #[serde(default)]
    pub migrate_existing: bool,
}

/// `POST /config/policies/{id}/change-storage` response.
#[derive(Debug, Serialize)]
pub struct ChangeStorageResponse {
    /// The policy now points at the new storage (always true on success).
    pub repointed: bool,
    /// The enqueued drain job id when `migrate_existing` and there was footage to
    /// move; `null` otherwise.
    pub migration_id: Option<Uuid>,
    pub segments_to_move: i64,
    pub bytes_to_move: i64,
}

/// Query parameters for `GET /config/fs/list`.
#[derive(Debug, Deserialize)]
pub struct FsListQuery {
    /// Absolute directory to list. Omitted → defaults to `/data` (falling back
    /// to `/` if that doesn't exist) — see `config_routes::list_fs`.
    pub path: Option<String>,
}

/// One directory entry returned by `GET /config/fs/list`.
#[derive(Debug, Serialize)]
pub struct FsDirEntryDto {
    pub name: String,
    /// Full canonical path (parent joined with `name`), ready to pass back in
    /// as the next `?path=`.
    pub path: String,
}

/// Response for `GET /config/fs/list` — the "Browse…" folder picker used when
/// choosing a recording-storage path in the admin console.
#[derive(Debug, Serialize)]
pub struct FsListResponseDto {
    /// Canonicalized echo of the path that was listed.
    pub path: String,
    /// Canonical parent directory, `null` at the filesystem root.
    pub parent: Option<String>,
    /// Whether `path` exists and is a directory. When `false`, `dirs` is empty
    /// and the UI treats this as "type a new path / navigate up" rather than
    /// an error.
    pub exists: bool,
    /// Subdirectories only — never files. Sorted by name, case-insensitive.
    pub dirs: Vec<FsDirEntryDto>,
}

/// Request body for `POST /config/fs/check` — preflight a candidate recording
/// path (used by the setup wizard and the console before a storage is saved).
#[derive(Debug, Deserialize)]
pub struct FsCheckRequest {
    /// Absolute path the recorder would write footage to.
    pub path: String,
}

/// Response for `POST /config/fs/check` — writability + free-space preflight for
/// a recording path. Unlike storage creation (which *rejects* a bad path), this
/// reports granular facts so the wizard can render a live status line and decide
/// whether to block "Next". `status` is the server's verdict: `ok` (safe to
/// record), `warn` (usable but risky — e.g. very low free space, or free space
/// couldn't be read), or `error` (recording would fail — not writable, not a
/// directory, outside the media root, or zero bytes free).
#[derive(Debug, Serialize)]
pub struct FsCheckResponse {
    /// Canonicalized path when it exists, else the input path echoed back.
    pub path: String,
    /// Whether the path is under the recorder's writable media root.
    pub under_media_root: bool,
    /// Whether the path currently exists.
    pub exists: bool,
    /// Whether the existing path is a directory (`false` when it doesn't exist).
    pub is_dir: bool,
    /// Whether files can be created here. `true`/`false` when the api could
    /// prove it by writing a throwaway file (in the directory, or its parent
    /// when the dir doesn't exist yet); `null` when the api's own `/data` mount
    /// is read-only (the standard compose — the recorder holds the RW mount), so
    /// writability can't be judged from this container.
    pub writable: Option<bool>,
    /// Filesystem size in bytes (`null` if `statvfs` is unavailable).
    pub total_bytes: Option<i64>,
    /// Space available to the recorder in bytes (`null` if unavailable).
    pub free_bytes: Option<i64>,
    /// Verdict: `"ok"` | `"warn"` | `"error"`.
    pub status: String,
    /// Human-readable explanation of the verdict, safe to show in the UI.
    pub message: String,
}

/// `GET /config/frigate` — current Frigate/MQTT integration settings. The
/// password is WRITE-ONLY: never returned; `has_password` says whether one is set.
#[derive(Debug, Serialize)]
pub struct FrigateConfigDto {
    pub enabled: bool,
    pub mqtt_url: String,
    pub mqtt_prefix: String,
    pub mqtt_user: Option<String>,
    pub has_password: bool,
    pub api_base: String,
    pub min_score: f32,
    pub catchup_hours: i64,
    pub version: i64,
}

/// `PUT /config/frigate` request. `mqtt_password = None` leaves the stored
/// password unchanged; `Some("")` clears it. Optional fields keep their current
/// value semantics via sensible defaults applied server-side.
#[derive(Debug, Deserialize)]
pub struct UpdateFrigateConfigRequest {
    pub enabled: bool,
    pub mqtt_url: String,
    pub mqtt_prefix: Option<String>,
    pub mqtt_user: Option<String>,
    pub mqtt_password: Option<String>,
    pub api_base: Option<String>,
    pub min_score: Option<f32>,
    pub catchup_hours: Option<i64>,
}

/// `POST /config/frigate/test` — broker-reachability check result.
#[derive(Debug, Serialize)]
pub struct FrigateTestResult {
    pub ok: bool,
    pub detail: String,
}

/// `POST /config/frigate/test-http` request — probe the Frigate URL bases
/// server-side (the browser can't cross-origin probe them itself). A blank or
/// absent field means "skip that target", not an error.
#[derive(Debug, Deserialize)]
pub struct FrigateHttpTestRequest {
    /// go2rtc REST base, e.g. `http://frigate-host:1984`.
    #[serde(default)]
    pub go2rtc_api_base: Option<String>,
    /// Frigate HTTP API base, e.g. `http://frigate-host:5000`.
    #[serde(default)]
    pub http_api_base: Option<String>,
}

/// One probed URL base's outcome. `ok: null` ⇒ skipped (blank input).
/// `detail` is a short operator-ready explanation either way.
#[derive(Debug, Serialize)]
pub struct FrigateHttpTargetResult {
    pub ok: Option<bool>,
    pub detail: String,
}

/// `POST /config/frigate/test-http` response — per-target results.
#[derive(Debug, Serialize)]
pub struct FrigateHttpTestResult {
    pub go2rtc: FrigateHttpTargetResult,
    pub http: FrigateHttpTargetResult,
}

// ─── server / streaming settings ─────────────────────────────────────────────

/// `GET /config/server` response — server & streaming base-URL settings.
///
/// These govern how the API and recorder build RTSP/API URLs for Crumb's own
/// go2rtc restreamer and for a BYO external Frigate. Empty string means "fall
/// back to the container's environment variable / internal docker service name."
#[derive(Debug, Serialize)]
pub struct ServerSettingsDto {
    /// Human-facing reachable address of this Crumb server
    /// (e.g. `"http://192.168.1.50:8080"`). Informational; not used for
    /// internal URL construction.
    pub server_address: String,
    /// RTSP base for Crumb's own go2rtc restreamer
    /// (e.g. `"rtsp://192.168.1.50:18554"`). Used by desktop/Android native
    /// clients to build live RTSP URLs for cameras served by Crumb.
    pub crumb_rtsp_base: String,
    /// HTTP API base for Crumb's own embedded go2rtc
    /// (e.g. `"http://recorder:1984"`). Used by the API's MSE proxy and
    /// frame-grab routes.
    pub crumb_api_base: String,
    /// RTSP base for an external (BYO) Frigate's go2rtc
    /// (e.g. `"rtsp://frigate-host:8554"`). Only needed when cameras have
    /// `served_by = "frigate"`.
    pub frigate_rtsp_base: String,
    /// HTTP API base for the external Frigate go2rtc REST API (:1984 — MSE
    /// proxy, frame-grab for Frigate-served cameras).
    /// (e.g. `"http://frigate-host:1984"`).
    /// Kept for back-compat; new code should prefer `frigate_go2rtc_api_base`.
    pub frigate_api_base: String,
    /// HTTP API base for the external Frigate go2rtc REST API (:1984).
    /// Used by cameras/playback frame+MSE+WebRTC proxy for `served_by="frigate"` cams.
    /// Empty string → fall back to env `GO2RTC_API_BASE` / internal default.
    pub frigate_go2rtc_api_base: String,
    /// HTTP base for the Frigate HTTP event/snapshot API (:5000).
    /// Used by events.rs snapshot/backfill for `served_by="frigate"` cams.
    /// Empty string → fall back to env `FRIGATE_API_BASE` / `frigate_config.api_base`.
    pub frigate_http_api_base: String,
    /// Motion-decode backend for all cameras: `"auto"`/`"cuda"`/`"vaapi"`/`"cpu"`.
    /// Empty ⇒ the recorder's `MOTION_HWACCEL` env default. The recorder
    /// hot-reloads its motion workers when this changes.
    pub motion_hwaccel: String,
    /// DRI render node for `motion_hwaccel="vaapi"` (e.g. `/dev/dri/renderD128`).
    /// Empty ⇒ the recorder's `MOTION_VAAPI_DEVICE` env default.
    pub motion_vaapi_device: String,
    /// Monotonically increasing version counter; bumped on every PUT. Clients
    /// poll this (via `/status`) to detect changes and reload stream URLs.
    pub version: i64,
}

/// `PUT /config/server` request body.
///
/// All fields are required. Pass empty strings to fall back to the container
/// environment / internal docker service-name defaults.
#[derive(Debug, Deserialize)]
pub struct UpdateServerSettingsRequest {
    pub server_address: String,
    pub crumb_rtsp_base: String,
    pub crumb_api_base: String,
    pub frigate_rtsp_base: String,
    /// Legacy combined Frigate API base. Consumers that have not migrated to
    /// the split fields may still send this; the handler copies it into both
    /// `frigate_go2rtc_api_base` and `frigate_http_api_base` when those are
    /// absent so existing admin-console saves keep working.
    #[serde(default)]
    pub frigate_api_base: String,
    /// HTTP API base for the external Frigate go2rtc REST endpoint (:1984).
    /// When omitted/empty the handler falls back to `frigate_api_base`.
    #[serde(default)]
    pub frigate_go2rtc_api_base: String,
    /// HTTP base for the Frigate HTTP event/snapshot API (:5000).
    /// When omitted/empty the handler falls back to `frigate_api_base`.
    #[serde(default)]
    pub frigate_http_api_base: String,
    /// Motion-decode backend: `"auto"`/`"cuda"`/`"vaapi"`/`"cpu"`. Empty ⇒ the
    /// recorder's `MOTION_HWACCEL` env default. `#[serde(default)]` only avoids a
    /// deserialization error when the field is omitted — `PUT /config/server` is a
    /// WHOLE-ROW replace, so the client must send a complete body (see admin.html's
    /// stash pattern); the server does NOT merge omitted fields.
    #[serde(default)]
    pub motion_hwaccel: String,
    /// DRI render node for VAAPI decode (e.g. `/dev/dri/renderD128`). Empty ⇒ env.
    #[serde(default)]
    pub motion_vaapi_device: String,
}

// ─── motion-decode truth (decode-status panel) ────────────────────────────────

/// Accelerator capabilities detected inside the recorder container
/// (refreshed on every recorder boot). Part of [`DecodeStatusDto`].
#[derive(Debug, Serialize)]
pub struct RecorderCapabilitiesDto {
    /// DRI render nodes present in the container (full paths, e.g.
    /// `"/dev/dri/renderD128"`). Empty ⇒ VAAPI decode cannot work (the render
    /// node isn't mapped in — needs the vaapi compose overlay).
    pub dri_devices: Vec<String>,
    /// Whether any `/dev/nvidia*` device node is present (NVIDIA GPU mapped
    /// into the recorder container via the gpu compose overlay).
    pub nvidia: bool,
    /// Hwaccels the recorder's bundled ffmpeg was COMPILED with
    /// (`ffmpeg -hwaccels`, e.g. `["vdpau","cuda","vaapi",...]`). Compiled-in
    /// support, not runtime usability.
    pub ffmpeg_hwaccels: Vec<String>,
    /// When the recorder last refreshed this report (its last boot).
    pub detected_at: DateTime<Utc>,
}

/// One camera's decode-backend truth. Part of [`DecodeStatusDto`].
#[derive(Debug, Serialize)]
pub struct CameraDecodeStatusDto {
    pub camera_id: Uuid,
    /// Camera display name (for UI convenience).
    pub camera_name: String,
    /// Backend the operator requested (effective `server_settings` → env value
    /// at worker spawn): `"auto"` | `"cuda"` | `"vaapi"` | `"cpu"`.
    pub requested: String,
    /// Backend the live ffmpeg decode child was launched with:
    /// `"cuda"` | `"vaapi"` | `"cpu"` | `"none"` (no local decode —
    /// Frigate-sourced motion or no sub-stream).
    pub active: String,
    /// Short human explanation when `requested != active` (or when the
    /// launched backend is expected to fail); `null` when all is well.
    pub fallback_reason: Option<String>,
    /// When the recorder last (re)started this camera's decode child.
    pub updated_at: DateTime<Utc>,
    /// Source audio sample rate (Hz) probed at record start; `null` if unknown /
    /// no audio / no status row yet.
    pub audio_sample_rate: Option<i32>,
    /// `true` when the recorder is re-encoding this camera's audio to 48 kHz AAC
    /// (source rate > 48 kHz), `false` when bit-exact copied, `null` when unknown.
    pub audio_transcoding: Option<bool>,
}

/// `GET /config/decode-status` response — what the recorder is ACTUALLY using
/// for motion decode, per camera, plus the container's accelerator surface.
#[derive(Debug, Serialize)]
pub struct DecodeStatusDto {
    /// `null` when the recorder has never reported (older recorder image or
    /// not booted yet) — render as "no report yet", NOT as "no devices".
    pub capabilities: Option<RecorderCapabilitiesDto>,
    /// One entry per camera the recorder is (or was last) running a motion
    /// worker for, ordered by camera name. Disabled/removed cameras are
    /// dropped by the recorder/FK, so absence here means "not decoding".
    pub cameras: Vec<CameraDecodeStatusDto>,
}

// ─── motion RAM-cache telemetry (migration 0039) ──────────────────────────────

/// Global motion-cache filesystem truth. Part of [`MotionCacheStatusDto`].
#[derive(Debug, Serialize)]
pub struct MotionCacheGlobalDto {
    /// Free bytes on the filesystem backing `MOTION_CACHE_DIR`.
    pub free_bytes: i64,
    /// Total bytes of that filesystem (the tmpfs sizing, e.g.
    /// `MOTION_CACHE_TMPFS_BYTES`).
    pub total_bytes: i64,
    /// Whether any Motion-mode camera currently has its cache dir active
    /// (false when every Motion camera has fallen back to direct-to-storage,
    /// or shadow mode is on).
    pub caching_active: bool,
    /// `MOTION_RECORDING_SHADOW` — every segment persists regardless of the
    /// buffer's verdict; ring numbers below are for validation only.
    pub shadow_mode: bool,
    pub updated_at: DateTime<Utc>,
}

/// One Motion-mode camera's RAM ring occupancy + API-computed projection.
/// Part of [`MotionCacheStatusDto`].
#[derive(Debug, Serialize)]
pub struct CameraMotionCacheDto {
    pub camera_id: Uuid,
    /// Camera display name.
    pub camera_name: String,
    /// `recording_policies.mode` for this camera — always `"motion"` (Crumb
    /// only ever surfaces Motion-mode cameras in this list), included anyway
    /// so the UI doesn't have to assume it.
    pub mode: String,
    /// Number of segments currently sitting in this camera's RAM ring buffer.
    /// `None` when the recorder has never reported this camera's occupancy.
    pub ring_segments: Option<i32>,
    /// Summed `size_bytes` of those pending segments. `None` alongside
    /// `ring_segments`.
    pub ring_bytes: Option<i64>,
    /// When the recorder last reported this camera's ring occupancy. `None`
    /// when never reported.
    pub updated_at: Option<DateTime<Utc>>,
    /// Observed bytes/sec for this camera over its recent live segments (last
    /// ~1h), used to derive `projected_ring_bytes`. `None` when there isn't
    /// enough recent segment history to estimate a rate (e.g. a camera that
    /// was just switched to Motion mode, or has been quiet for over an hour).
    pub observed_bytes_per_sec: Option<f64>,
    /// Projected steady-state ring need in bytes: `observed_bytes_per_sec *
    /// (motion_pre_seconds + RING_SLACK_SECS + 2 * SEGMENT_SECONDS)` — see
    /// `config_routes::project_camera_ring_bytes`. This is computed whether or
    /// not caching is currently active, so it works as a planning tool BEFORE
    /// flipping a camera to Motion mode. `None` when `observed_bytes_per_sec`
    /// is `None`.
    pub projected_ring_bytes: Option<i64>,
}

/// `GET /config/motion-cache-status` response — the recorder's motion RAM
/// cache truth plus the API's per-camera projection, so the admin console can
/// show both "what's used right now" and "what will Motion mode cost".
#[derive(Debug, Serialize)]
pub struct MotionCacheStatusDto {
    /// `null` when the recorder has never reported this tick (older recorder
    /// image or not booted yet) — render as "no cache telemetry yet", NOT as
    /// zero usage.
    pub global: Option<MotionCacheGlobalDto>,
    /// One entry per Motion-mode camera, ordered by camera name.
    /// Continuous-mode cameras never appear here.
    pub cameras: Vec<CameraMotionCacheDto>,
    /// Summed `projected_ring_bytes` across every camera that has one (a
    /// camera with no observed rate yet is simply excluded from the sum, not
    /// treated as zero).
    pub total_projected_bytes: i64,
}

/// `POST /config/cameras/{id}/redetect` response.
///
/// The handler re-runs ONVIF `GetProfiles`/`GetStreamUri` against the camera's
/// stored ONVIF credentials, updates the camera row, and forces a go2rtc
/// producer restart. Returns the newly detected source URLs and the full
/// updated camera DTO.
#[derive(Debug, Serialize)]
pub struct RedetectResponse {
    /// The raw RTSP main-stream URI returned by ONVIF `GetStreamUri`.
    pub source_url: String,
    /// The raw RTSP sub-stream URI, if the camera exposes a second profile.
    pub source_sub_url: Option<String>,
    /// Whether ONVIF `GetServices` reported a PTZ `XAddr` (i.e. this camera
    /// supports PTZ control via ONVIF). `false` when the probe failed or the
    /// camera has no PTZ service — the operator can always tick PTZ manually.
    pub ptz_supported: bool,
    /// The full, updated camera DTO (re-read from DB after the update).
    pub camera: CameraDto,
}

/// Status shape for a "Change storage" drain job.
#[derive(Debug, Serialize)]
pub struct StorageMigrationDto {
    pub id: Uuid,
    pub policy_id: Uuid,
    pub from_storage_id: Uuid,
    pub to_storage_id: Uuid,
    pub status: String,
    pub total_segments: i64,
    pub moved_segments: i64,
    pub moved_bytes: i64,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

// ─── timeline ─────────────────────────────────────────────────────────────────

/// Query parameters for `GET /timeline`.
#[derive(Debug, Deserialize)]
pub struct TimelineQuery {
    /// Comma-separated list of camera UUIDs.
    pub camera_ids: String,
    /// ISO 8601 start timestamp (inclusive).
    pub start: DateTime<Utc>,
    /// ISO 8601 end timestamp (exclusive).
    pub end: DateTime<Utc>,
    /// Max number of merged spans to return (pagination). Omitted → server
    /// default cap. Clamped server-side to a hard maximum.
    pub limit: Option<usize>,
    /// Number of merged spans to skip before returning `limit` (pagination).
    /// Omitted → 0.
    pub offset: Option<usize>,
}

/// A merged recorded span for a single camera.  Contiguous segments are merged
/// server-side; the client draws one bar per span.
#[derive(Debug, Serialize)]
pub struct RecordedSpan {
    pub camera_id: Uuid,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// Whether any segment in this span has motion.
    pub has_motion: bool,
    /// `"live"` or `"archive"`.  Informational — clients do not need to
    /// differentiate for display, but admin tooling may use it.
    pub stage: String,
}

/// Response for `GET /timeline`.
#[derive(Debug, Serialize)]
pub struct TimelineResponse {
    pub spans: Vec<RecordedSpan>,
    /// Total merged spans available for the query window (before pagination).
    pub total: usize,
    /// Whether more spans exist beyond this page (`offset + spans.len() < total`).
    /// Clients page by incrementing `offset` until this is `false`.
    pub has_more: bool,
}

// ─── playback ─────────────────────────────────────────────────────────────────

/// Query parameters for `GET /play/{camera_id}`.
#[derive(Debug, Deserialize)]
pub struct PlaybackQuery {
    /// Target timestamp — the API resolves the segment(s) that cover it.
    pub ts: DateTime<Utc>,
    /// Stream to serve.  Default: `"main"`.
    #[serde(default = "default_stream")]
    pub stream: String,
}

fn default_stream() -> String {
    "main".to_owned()
}

/// Query parameters for `GET /play/aligned`.
#[derive(Debug, Deserialize)]
pub struct AlignedPlaybackQuery {
    /// Comma-separated camera UUIDs.
    pub camera_ids: String,
    pub ts: DateTime<Utc>,
    #[serde(default = "default_stream")]
    pub stream: String,
}

/// A resolved segment URL ready for the client to consume.
#[derive(Debug, Serialize)]
pub struct ResolvedSegment {
    pub camera_id: Uuid,
    pub segment_id: Uuid,
    /// HTTP URL the client fetches (e.g. `GET /segments/{id}`).  The API
    /// serves the file via tower-http static-file / range support.
    pub url: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub duration_ms: i32,
    pub has_motion: bool,
}

// ─── live streaming ───────────────────────────────────────────────────────────

/// Query for the live MSE proxy `GET /live/{camera_id}/stream.mp4`.
/// `stream` selects the main (default) or sub feed.
#[derive(Debug, Deserialize)]
pub struct LiveStreamQuery {
    pub stream: Option<String>,
}

/// Response for `GET /cameras/{camera_id}/streams`.
///
/// Post P0-GO2RTC lighter-lockdown, `webrtc_*_url` are API-relative paths to
/// the API's authenticated WebRTC SDP proxy (`POST /live/{id}/webrtc`), not
/// direct go2rtc URLs — go2rtc's REST API has no LAN host-publish anymore. The
/// `rtsp_*_url` fields are still real `rtsp://` URLs to go2rtc's RTSP listener
/// (LAN-published, unchanged for clients), but now carry embedded
/// `user:pass@` credentials (`GO2RTC_USER`/`GO2RTC_PASS`) since go2rtc's RTSP
/// now requires auth — desktop/Android connect exactly as before with zero
/// code changes (standard RTSP userinfo syntax).
#[derive(Debug, Serialize)]
pub struct LiveStreamsResponse {
    pub camera_id: Uuid,
    /// API-relative WebRTC SDP-proxy path for the main stream
    /// (`/live/{id}/webrtc?stream=main`).
    pub webrtc_main_url: Option<String>,
    /// API-relative WebRTC SDP-proxy path for the sub stream.
    pub webrtc_sub_url: Option<String>,
    /// RTSP URL for the main stream — LAN-reachable, with embedded
    /// `GO2RTC_USER:GO2RTC_PASS@` credentials for Crumb-owned cameras (go2rtc
    /// RTSP auth). SENSITIVE: contains a shared credential valid for any
    /// camera on this server; treat this response like any other
    /// authenticated, per-user payload (JWT/RBAC-gated, not further exposed).
    pub rtsp_main_url: String,
    /// RTSP URL for the sub stream (same credential note as `rtsp_main_url`).
    pub rtsp_sub_url: Option<String>,
}

// ─── export ───────────────────────────────────────────────────────────────────

fn default_codec() -> String {
    "copy".to_owned()
}

fn default_container() -> String {
    "mp4".to_owned()
}

/// `POST /export` request body.
#[derive(Debug, Deserialize)]
pub struct CreateExportRequest {
    pub camera_ids: Vec<Uuid>,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// Burn wall-clock timestamp overlay onto each frame.
    #[serde(default = "default_true")]
    pub burn_timestamp: bool,
    /// Include audio track in the export.  Defaults to `true` for backward
    /// compatibility with older clients that do not send this field.
    #[serde(default = "default_true")]
    pub include_audio: bool,
    /// Video codec for the export: `"copy"` (stream-copy, lossless fast),
    /// `"h264"` (libx264), or `"h265"` (libx265).  Unknown values are treated
    /// as `"copy"`.  Defaults to `"copy"`.
    #[serde(default = "default_codec")]
    pub video_codec: String,
    /// Output container format: `"mp4"` or `"mkv"`.  Unknown values are
    /// treated as `"mp4"`.  Defaults to `"mp4"`.
    #[serde(default = "default_container")]
    pub container: String,
    /// If `Some` and non-empty, all per-camera files are bundled into a single
    /// AES-256 encrypted ZIP (`crumb_export.zip`) and the raw files are
    /// deleted.  `None` or empty string → standard per-camera download
    /// behaviour (no ZIP, no encryption).
    #[serde(default)]
    pub password: Option<String>,
}

/// One clip in a batch export: a single camera over its own time range.
#[derive(Debug, Clone, Deserialize)]
pub struct BatchExportItem {
    pub camera_id: Uuid,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

/// `POST /export/batch` request body — an commercial-VMS-style export list. Each item
/// is one camera + one time range (ranges/cameras may differ per item). Output
/// settings are global and apply to every clip; the whole list is bundled into a
/// SINGLE archive (`crumb_export.zip`, AES-256 when `password` is set).
#[derive(Debug, Deserialize)]
pub struct CreateBatchExportRequest {
    pub items: Vec<BatchExportItem>,
    #[serde(default = "default_true")]
    pub burn_timestamp: bool,
    #[serde(default = "default_true")]
    pub include_audio: bool,
    #[serde(default = "default_codec")]
    pub video_codec: String,
    #[serde(default = "default_container")]
    pub container: String,
    #[serde(default)]
    pub password: Option<String>,
}

/// Status of an export job.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ExportStatus {
    Queued,
    Running,
    Done,
    Failed,
    /// User-cancelled (terminal). The ffmpeg process is killed, output cleaned up,
    /// and the concurrency slot freed. Not counted by the concurrency cap.
    Cancelled,
}

/// In-memory export job record (stored in `AppState::export_jobs`).
#[derive(Debug, Clone, Serialize)]
pub struct ExportJob {
    pub id: Uuid,
    pub status: ExportStatus,
    pub camera_ids: Vec<Uuid>,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub burn_timestamp: bool,
    pub created_at: DateTime<Utc>,
    /// Per-camera output file paths (relative to `export_dir`) once done.
    pub output_files: Vec<ExportOutputFile>,
    /// Human-readable error message if `status == Failed`.
    pub error: Option<String>,
    /// Progress 0–100, updated during the ffmpeg run.
    pub progress_pct: u8,
}

/// A single exported file for one camera (or the whole-job ZIP archive).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportOutputFile {
    pub camera_id: Uuid,
    /// Download URL.  Per-camera: `GET /export/{job_id}/files/{camera_id}`.
    /// ZIP archive: `GET /export/{job_id}/archive`.
    pub download_url: String,
    pub size_bytes: u64,
    /// Basename of the file on disk, including extension (e.g. `"a1b2….mkv"`
    /// or `"crumb_export.zip"`).  Used by the download handler to locate the
    /// file and set `Content-Type`.
    ///
    /// `#[serde(default)]` so that old persisted `jsonb` rows that pre-date
    /// this field still deserialize (they get an empty string, which the
    /// download handler will never see for a `Done` job written by old code,
    /// but it prevents a hard deserialization failure on rehydration).
    #[serde(default)]
    pub filename: String,
}

/// `POST /export` response.
#[derive(Debug, Serialize)]
pub struct CreateExportResponse {
    pub job_id: Uuid,
    /// Polling URL.
    pub status_url: String,
}

// ─── system status ────────────────────────────────────────────────────────────

/// `GET /status` response.
#[derive(Debug, Serialize)]
pub struct SystemStatusResponse {
    pub storages: Vec<StorageStatusEntry>,
    pub cameras: Vec<CameraStatusEntry>,
    /// Timestamp of the recorder's last liveness heartbeat (from the
    /// `recorder_heartbeat` table the recorder upserts every ~10 s).  `None`
    /// if the recorder has never written one.  Clients compare against `now()`
    /// to decide whether the recorder daemon is live.
    pub recorder_heartbeat: Option<DateTime<Utc>>,
    /// OS process id of the recorder at its last heartbeat (diagnostic).
    pub recorder_pid: Option<i32>,
    /// Number of camera workers the recorder reported running at its last
    /// heartbeat.
    pub recorder_active_cameras: Option<i32>,
    /// Opaque fingerprint of camera + recording-policy config (see
    /// `db::config_version`). Clients poll `/status` and, when this changes,
    /// silently re-fetch the camera list + reconnect — so a server-side config
    /// edit propagates without a manual refresh. Empty string when no cameras.
    #[serde(default)]
    pub config_version: String,
    /// Platform-wide bookmarks-UI toggle. When `false`, clients hide the bookmark
    /// button(s) everywhere. `#[serde(default)]`/true-default keeps older clients
    /// (and tokens that pre-date this field) showing bookmarks.
    #[serde(default = "default_true")]
    pub bookmarks_enabled: bool,
}

/// Per-storage entry in the status response.
#[derive(Debug, Serialize)]
pub struct StorageStatusEntry {
    pub id: Uuid,
    pub name: String,
    pub path: String,
    /// Configured size cap for this storage (`None` when uncapped).
    pub total_bytes: Option<i64>,
    /// Total size of the underlying filesystem (statvfs), independent of any cap.
    /// Lets clients draw a real capacity bar even when no cap is set — without it
    /// the bar's denominator is unknown and renders wrong.
    pub fs_total_bytes: Option<i64>,
    pub free_bytes: Option<i64>,
    /// Bytes used by recorded segments in this storage (from the segments index).
    pub used_bytes: i64,
    /// RESOLVED media glyph (`"ssd"`/`"hdd"`/`"disk"`) — the operator override if
    /// set, else inferred from the name. Clients render this directly (they don't
    /// re-implement the heuristic); see `crumb_common::icons::storage_icon_kind`.
    pub icon: String,
}

/// Per-camera entry in the status response.
#[derive(Debug, Serialize)]
pub struct CameraStatusEntry {
    pub id: Uuid,
    pub name: String,
    pub enabled: bool,
    /// Whether the segment index has a segment whose `end_ts` is within the
    /// last 2 × `segment_seconds` — i.e. the camera appears to be recording.
    pub recording: bool,
    /// Whether the most recent segment has motion AND is fresh enough that the
    /// camera is considered to have motion "right now" (within the freshness
    /// window).  Drives the live-wall motion indicator.  Latency is bounded by
    /// segment length (motion is only known when a segment closes).
    pub recent_motion: bool,
    /// `end_ts` of the most recent segment, or `None` if no segments exist.
    pub last_segment_end: Option<DateTime<Utc>>,
}

// ─── filmstrip ────────────────────────────────────────────────────────────────

/// Query parameters for `GET /filmstrip/{camera_id}`.
#[derive(Debug, Deserialize)]
pub struct FilmstripQuery {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// Desired output thumbnail width in pixels.  Default: `160`.
    #[serde(default = "default_thumb_width")]
    pub width: u32,
}

fn default_thumb_width() -> u32 {
    160
}

/// A single thumbnail frame in the filmstrip.
#[derive(Debug, Serialize)]
pub struct FilmstripFrame {
    /// Timestamp this frame represents.
    pub ts: DateTime<Utc>,
    /// URL: `GET /filmstrip/{camera_id}/frame?ts=<ts>`.
    pub url: String,
}

/// `GET /filmstrip/{camera_id}` response.
#[derive(Debug, Serialize)]
pub struct FilmstripResponse {
    pub camera_id: Uuid,
    pub frames: Vec<FilmstripFrame>,
}

// ─── update-available check (issue #7) ─────────────────────────────────────────

/// Query parameters for `GET /updates/latest`.
#[derive(Debug, Deserialize)]
pub struct UpdatesLatestQuery {
    /// `"1"` forces an immediate re-check ("Check now",
    /// `docs/UPDATE-SYSTEM-PLAN.md` §2.5), subject to a 60s minimum interval
    /// between actual forced `GitHub` fetches (a repeat click inside that
    /// window serves the cached value, `checked_at` unchanged). Anything else,
    /// including an absent param, is the normal cached path (§2.1).
    #[serde(default)]
    pub refresh: Option<String>,
}

/// `GET /updates/latest` response — see `docs/UPDATE-SYSTEM-PLAN.md` §2.1/§2.5.
///
/// `enabled:false` ⇒ every other field is `null` (this, not a 404, is how a
/// disabled check is told apart from an old server that lacks the route at
/// all) and `?refresh=1` is silently ignored — disabled means zero `GitHub`
/// requests, with no exception for a manual "Check now" click.
///
/// While enabled, `latest_version` / `notes_url` / `published_at` /
/// `checked_at` are only `None` in the narrow case where the api has never
/// completed a `GitHub` fetch yet (no cached value, e.g. right after boot with
/// `GitHub` unreachable); once a fetch succeeds they stay populated afterwards
/// even through later outages (stale-while-error — `checked_at` just stops
/// advancing).
#[derive(Debug, Serialize)]
pub struct UpdateCheckResponse {
    pub enabled: bool,
    /// Newest stable release tag from `GitHub`, without the leading `v`.
    pub latest_version: Option<String>,
    /// `GitHub` release page URL (release notes).
    pub notes_url: Option<String>,
    pub published_at: Option<DateTime<Utc>>,
    /// This server's own build version (the `VERSION` file), so the web
    /// console's notice needs zero client-side comparison logic.
    pub server_version: Option<String>,
    /// `latest_version > server_version`, strict `SemVer` 2.0.0 precedence.
    /// `None` when either version fails to parse (e.g. a local `-dev` build) —
    /// "no signal", never a false "you're up to date".
    pub server_update_available: Option<bool>,
    /// When the returned release data was last actually refreshed from
    /// `GitHub` (not merely requested) — an older timestamp during an outage
    /// is the intentional stale-while-error signal.
    pub checked_at: Option<DateTime<Utc>>,
}
