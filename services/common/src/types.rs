// SPDX-License-Identifier: AGPL-3.0-or-later

//! Domain types that map **exactly** to the PostgreSQL schema defined in
//! `db/migrations/0001_initial_schema.sql`.
//!
//! Column-level correspondence is called out in each struct's doc comment.
//! `tokio-postgres` features `with-chrono-0_4`, `with-uuid-1`, and
//! `with-serde_json-1` are enabled so the ORM-like row extraction in `db.rs`
//! can call `row.get::<_, DateTime<Utc>>(…)`, `row.get::<_, Uuid>(…)`, etc.
//! directly — no intermediate string parsing.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ─── storages ────────────────────────────────────────────────────────────────

/// `storages` table row.
///
/// A dumb named location on the filesystem.  All retention / archiving policy
/// lives on the *camera*, not here.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Storage {
    /// `storages.id`
    pub id: Uuid,
    /// `storages.name` — human label, e.g. `"NVMe-Live"` or `"NAS-Archive"`.
    pub name: String,
    /// `storages.path` — absolute filesystem path the recorder can write to.
    pub path: String,
    /// `storages.total_bytes` — optional, for quota display in the UI.
    pub total_bytes: Option<i64>,
    /// `storages.icon` — OPTIONAL operator override for the media glyph, stored as
    /// a kind (`"ssd"`/`"hdd"`/`"disk"`). `None` (the default) means "infer from
    /// the name" (NVMe→SSD, Spinner→HDD, …), so this only exists for cases the
    /// name heuristic gets wrong (e.g. a flash array named "Bulk").
    pub icon: Option<String>,
    /// `storages.created_at`
    pub created_at: DateTime<Utc>,
}

/// A "Change storage" drain job: move every segment of `policy_id` currently on
/// `from_storage_id` to `to_storage_id`. Enqueued by the API (after it repoints
/// the policy) and executed by the recorder's migration worker under the same
/// in-process lock as archiving/eviction, so footage moves never race. Status:
/// `pending` → `running` → `done` | `failed`. Progress fields tick as it drains.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageMigration {
    /// `storage_migrations.id`
    pub id: Uuid,
    /// The effective policy whose footage is being relocated.
    pub policy_id: Uuid,
    /// Where the footage currently sits (the old disk).
    pub from_storage_id: Uuid,
    /// Where the footage is being moved to (the policy's new disk).
    pub to_storage_id: Uuid,
    /// `pending` | `running` | `done` | `failed` | `cancelled`.
    pub status: String,
    /// Segments to move at enqueue time (snapshot; drain is idempotent if it grows).
    pub total_segments: i64,
    /// Segments successfully relocated so far.
    pub moved_segments: i64,
    /// Bytes successfully relocated so far.
    pub moved_bytes: i64,
    /// Failure detail when `status = 'failed'`.
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// DB-backed Frigate / MQTT integration settings (a single row, `id = 1`).
///
/// Both the recorder (per-camera Frigate motion loops) and the API (the detection
/// provider) read this and **hot-reload** when `version` changes — they poll it
/// and reconnect MQTT with the new credentials, no process restart. The table is
/// seeded once from the legacy `FRIGATE_*` env vars so existing deployments carry
/// over; after that the DB is authoritative.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrigateSettings {
    /// Master switch. When false the feature is off regardless of `mqtt_url`.
    pub enabled: bool,
    /// MQTT broker URL, e.g. `mqtt://192.0.2.10:1883`. Empty ⇒ effectively disabled.
    pub mqtt_url: String,
    /// Topic prefix, default `"frigate"`.
    pub mqtt_prefix: String,
    /// Optional broker username.
    pub mqtt_user: Option<String>,
    /// Optional broker password (stored as-is; the API never returns it to clients).
    pub mqtt_password: Option<String>,
    /// API-only: Frigate HTTP base for the startup event backfill.
    pub api_base: String,
    /// Confidence floor (0..1) for an object to count.
    pub min_score: f32,
    /// API-only: how many hours back to backfill events on (re)connect.
    pub catchup_hours: i64,
    /// Monotonic version, bumped on every update. Processes compare it to detect a
    /// change and reconnect.
    pub version: i64,
}

// ─── ha_config / camera_ha_links ─────────────────────────────────────────────

/// Singleton Home Assistant connection settings (`ha_config`, migration 0048).
/// One base URL + a long-lived access token (write-only — never returned to a
/// client) + an enable flag + a monotonic `version` (bumped on edit so future
/// consumers hot-reload). `base_url`/`token` fall back to `HA_BASE_URL`/`HA_TOKEN`
/// env when the DB fields are empty (DB wins).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HaSettings {
    /// Master switch. When false the integration is dormant regardless of URL.
    pub enabled: bool,
    /// HA base URL, e.g. `http://homeassistant.local:8123`. Empty ⇒ disabled.
    pub base_url: String,
    /// Long-lived access token (stored as-is; the API never returns it to
    /// clients — the admin DTO exposes only whether one is set).
    pub token: Option<String>,
    /// Monotonic version, bumped on every update.
    pub version: i64,
}

/// One camera ↔ HA entity link (`camera_ha_links`, migration 0048).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CameraHaLink {
    pub id: uuid::Uuid,
    pub camera_id: uuid::Uuid,
    /// HA entity id, e.g. `binary_sensor.front_door` or `light.living_room`.
    pub entity_id: String,
    /// `"motion"` (feeds recording/timeline), `"sensor"` (status-only overlay,
    /// wired in a later phase), or `"actuator"` (light/switch/scene control).
    pub role: String,
    /// HA `device_class` captured at link time (`motion`, `door`, `window`, ...),
    /// a snapshot of intent used to pick the glyph without re-querying HA. May be
    /// `None` for entities that report no class.
    pub device_class: Option<String>,
    /// Optional button/label caption (defaults to the HA friendly name in the UI).
    pub label: Option<String>,
    /// Display order within the camera.
    pub sort_order: i32,
}

// ─── recording_policies ──────────────────────────────────────────────────────

/// Strongly-typed mirror of the `mode` column constraint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RecordingMode {
    Continuous,
    Motion,
}

impl RecordingMode {
    /// Deserialise from the `text` value stored in Postgres.
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "continuous" => Some(Self::Continuous),
            "motion" => Some(Self::Motion),
            _ => None,
        }
    }

    /// Serialise to the `text` value Postgres expects.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Continuous => "continuous",
            Self::Motion => "motion",
        }
    }
}

/// Strongly-typed mirror of the `motion_sensitivity` column constraint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MotionSensitivity {
    Dynamic,
    Manual,
}

impl MotionSensitivity {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "dynamic" => Some(Self::Dynamic),
            "manual" => Some(Self::Manual),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Dynamic => "dynamic",
            Self::Manual => "manual",
        }
    }
}

/// Strongly-typed mirror of the `record_stream` column constraint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RecordStream {
    Main,
    Sub,
}

impl RecordStream {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "main" => Some(Self::Main),
            "sub" => Some(Self::Sub),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Main => "main",
            Self::Sub => "sub",
        }
    }
}

/// `recording_policies` table row.
///
/// The global default is the single row where `is_default = true`.  Every
/// camera owns its own policy row (cloned from the default, fields overridden).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingPolicy {
    /// `recording_policies.id`
    pub id: Uuid,
    /// `recording_policies.name` — human label for a **named, reusable** policy
    /// (e.g. `"Default"`, `"24/7 high-res"`). `None` ⇒ an anonymous per-camera
    /// copy-on-write fork (a "custom" policy not offered for reuse). Added by the
    /// `ensure_named_policies_and_groups` migration; the default row is backfilled
    /// to `"Default"`.
    pub name: Option<String>,
    /// `recording_policies.is_default`
    pub is_default: bool,
    /// `recording_policies.mode`
    pub mode: RecordingMode,
    /// `recording_policies.live_storage_id`
    pub live_storage_id: Option<Uuid>,
    /// `recording_policies.live_retention_hours`
    pub live_retention_hours: i32,
    /// `recording_policies.archive_enabled`
    pub archive_enabled: bool,
    /// `recording_policies.archive_storage_id`
    pub archive_storage_id: Option<Uuid>,
    /// `recording_policies.archive_schedule` — cron expression, e.g. `"0 3 * * *"`.
    pub archive_schedule: Option<String>,
    /// `recording_policies.archive_retention_hours`
    pub archive_retention_hours: Option<i32>,
    /// `recording_policies.live_max_bytes` — size cap (BYTES) on the camera's
    /// LIVE-stage footage. `None` ⇒ no size cap (time-based retention only).
    /// When the live total exceeds this, the recorder evicts the OLDEST live
    /// segments early (archives them when `archive_enabled`, else deletes). This
    /// is the size half of "retention time OR max size, whichever hits first".
    pub live_max_bytes: Option<i64>,
    /// `recording_policies.archive_max_bytes` — size cap (BYTES) on the camera's
    /// ARCHIVE-stage footage. `None` ⇒ no size cap (archive_retention_hours
    /// alone). When the archive total exceeds this, the recorder DELETES the
    /// oldest archived segments. Only meaningful when `archive_enabled`.
    pub archive_max_bytes: Option<i64>,
    /// `recording_policies.live_min_free_pct` — per-policy override of the
    /// FRACTIONAL free-space floor (0.0..1.0) on this policy's live disk. `None`
    /// ⇒ fall back to the global `MIN_FREE_FRACTION` env (default 0.05). The
    /// stricter of the fractional and absolute floors wins (see
    /// `archive::free_floor_decision`). Setting any headroom also opts the policy
    /// into the free-floor eviction check even without a size cap or archiving.
    pub live_min_free_pct: Option<f32>,
    /// `recording_policies.live_min_free_bytes` — per-policy override of the
    /// ABSOLUTE free-space floor (BYTES) on this policy's live disk. `None` ⇒ fall
    /// back to the global `MIN_FREE_BYTES` env (default 50 GiB). Still subject to
    /// the `< total/2` small-disk guard so an oversized floor on a tiny disk
    /// safely degrades to the fractional floor.
    pub live_min_free_bytes: Option<i64>,
    /// `recording_policies.live_spill_low_water_bytes` — the LOW-WATER spill
    /// buffer (BYTES). `None`/`0` ⇒ no hysteresis (eviction drains to exactly the
    /// cap / clears exactly the free-floor deficit, today's behaviour). When set,
    /// a triggered eviction overshoots — draining live down to
    /// `live_max_bytes - spill`, freeing the disk up to `floor + spill`, and
    /// draining archive down to `archive_max_bytes - spill` — so eviction works in
    /// batches (moving a chunk of the oldest footage to Archive at once) instead
    /// of nibbling one segment per tick at the boundary. One knob for all three.
    pub live_spill_low_water_bytes: Option<i64>,
    /// `recording_policies.max_retention_days` — ABSOLUTE maximum age (DAYS) any
    /// footage under this policy may reach, across BOTH the live and archive
    /// stages. `None` ⇒ OFF (no cap; the default). When set to `N`, the recorder
    /// deletes segments older than `N` days regardless of the size caps or the
    /// per-tier `live_retention_hours` / `archive_retention_hours` windows — a
    /// hard upper bound for data-minimization (GDPR/UK-DPA), not a replacement for
    /// the other knobs. It only ever removes footage SOONER, never keeps it
    /// longer. Protected bookmarks are still honoured (an explicit human pin wins
    /// over the automatic cap). There is no fixed statutory number — the value is
    /// entirely operator-chosen; see `docs/DECISIONS.md`.
    pub max_retention_days: Option<i32>,
    /// `recording_policies.motion_pre_seconds`
    pub motion_pre_seconds: i32,
    /// `recording_policies.motion_post_seconds`
    pub motion_post_seconds: i32,
    /// `recording_policies.motion_sensitivity`
    pub motion_sensitivity: MotionSensitivity,
    /// `recording_policies.motion_threshold` — the Manual-mode motion floor as a
    /// **fraction of frame area (0.0..1.0)**, the SAME unit as `segments.motion_score`,
    /// `motion_grid.score/threshold`, and [`crate`]'s blob constants. Only meaningful
    /// when `motion_sensitivity = Manual`; `None` ⇒ use the blob-area default floor.
    /// (Fraction everywhere internally; "%" exists only as a UI display transform.)
    pub motion_threshold: Option<f32>,
    /// `recording_policies.motion_keyframes_only`
    pub motion_keyframes_only: bool,
    /// `recording_policies.record_stream`
    pub record_stream: RecordStream,
    /// `recording_policies.record_audio` — when `false`, the ffmpeg recorder
    /// drops the audio track (`-an`).  Defaults to `true` (audio kept).
    pub record_audio: bool,
}

// ─── camera groups ───────────────────────────────────────────────────────────

/// `camera_groups` table row — a named, reusable grouping of cameras that share a
/// recording policy.
///
/// A camera belongs to AT MOST ONE recording group (enforced by the
/// `one_group_per_camera` unique index on `camera_group_members`). The effective
/// policy for a camera resolves as: its own direct `cameras.policy_id` → else its
/// group's `policy_id` → else the global default (`recording_policies.is_default`).
/// Created by the `ensure_named_policies_and_groups` migration; no groups exist on
/// a fresh DB, so there is zero behaviour change until an operator creates one.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CameraGroup {
    /// `camera_groups.id`
    pub id: Uuid,
    /// `camera_groups.name` — human label, e.g. `"Perimeter"`.
    pub name: String,
    /// `camera_groups.policy_id` — the named policy applied to this group's
    /// members (unless a member has its own direct policy). `None` ⇒ the group
    /// itself inherits the global default.
    pub policy_id: Option<Uuid>,
    /// `camera_groups.created_at`
    pub created_at: DateTime<Utc>,
}

// ─── cameras ─────────────────────────────────────────────────────────────────

/// DB-backed server / streaming settings (a single row, `id = 1`).
///
/// Both the recorder and the API read this per-request (cheap singleton SELECT)
/// to resolve the live stream bases for Crumb's own restreamer and an optional
/// external Frigate go2rtc.  When a field is empty string the caller falls back
/// to the corresponding environment variable so a fresh install with no DB row
/// still works once the operator fills the Server settings page.
///
/// Seeded once from env (`CRUMB_GO2RTC_RTSP_BASE`, `CRUMB_GO2RTC_API_BASE`,
/// `GO2RTC_RTSP_BASE`, `GO2RTC_API_BASE`, `FRIGATE_API_BASE`,
/// `GO2RTC_API_BASE`) on first table creation; after that the DB row is
/// authoritative.
///
/// Migration 0014 split the old `frigate_api_base` (which conflated two services)
/// into two explicit fields; the legacy column is retained for back-compat.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerSettings {
    /// Operator-visible reachable host, informational + future use.
    /// e.g. `"http://192.168.1.50:8080"`.  Does not affect stream resolution.
    pub server_address: String,
    /// Base RTSP URL for Crumb's own restreamer (port :18554 by default).
    /// e.g. `"rtsp://crumb-host:18554"`.
    pub crumb_rtsp_base: String,
    /// Base HTTP URL for Crumb's go2rtc API (MSE/WebRTC/frame proxy; the
    /// go2rtc binary runs embedded in the recorder container).
    /// e.g. `"http://recorder:1984"`.
    pub crumb_api_base: String,
    /// Base RTSP URL for an external (BYO) Frigate's go2rtc.
    /// e.g. `"rtsp://frigate-host:8554"`.  Empty ⇒ fall back to env.
    pub frigate_rtsp_base: String,
    /// Base HTTP URL for the external Frigate's go2rtc API (MSE/WebRTC/frame proxy,
    /// port :1984). Seeded from `GO2RTC_API_BASE`.  Empty ⇒ fall back to env.
    ///
    /// This field is the authoritative split of the old `frigate_api_base` for the
    /// go2rtc REST side. Kept for back-compat (= `frigate_go2rtc_api_base`).
    pub frigate_api_base: String,
    /// Base HTTP URL for Crumb's go2rtc MSE/WebRTC/frame-proxy side of an external
    /// Frigate-bundled go2rtc (port :1984). Seeded from env `GO2RTC_API_BASE`.
    /// Added by migration 0014. Empty ⇒ fall back to env / `frigate_api_base`.
    pub frigate_go2rtc_api_base: String,
    /// Base HTTP URL for the external Frigate HTTP API (event snapshots/backfill,
    /// port :5000). Seeded from env `FRIGATE_API_BASE`.
    /// Added by migration 0014. Empty ⇒ fall back to env.
    pub frigate_http_api_base: String,
    /// `motion_hwaccel` — admin-editable motion-decode backend for ALL cameras:
    /// `"auto"` (probe NVDEC, else CPU), `"cuda"` (NVDEC), `"vaapi"` (Intel/AMD
    /// iGPU), or `"cpu"`. Empty ⇒ the recorder falls back to its `MOTION_HWACCEL`
    /// env default. The recorder hot-reloads its motion workers when this changes.
    /// Note: `cuda`/`vaapi` also require the matching device to be mapped into the
    /// recorder container (the gpu/vaapi compose overlay); the admin UI surfaces
    /// this prerequisite.
    #[serde(default)]
    pub motion_hwaccel: String,
    /// `motion_vaapi_device` — DRI render node for `motion_hwaccel = "vaapi"`
    /// (e.g. `/dev/dri/renderD128`). Empty ⇒ the recorder's `MOTION_VAAPI_DEVICE`
    /// env default. Ignored for non-VAAPI backends.
    #[serde(default)]
    pub motion_vaapi_device: String,
    /// Monotonic version, bumped on every `update_server_settings` call.
    pub version: i64,
}

/// `cameras` table row, with the joined policy and storage rows embedded.
///
/// The recorder loads this via a JOIN so it has everything it needs in one
/// allocation.  The raw `policy_id` foreign key is also kept for change
/// detection hashing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Camera {
    /// `cameras.id`
    pub id: Uuid,
    /// `cameras.name`
    pub name: String,
    /// `cameras.enabled`
    pub enabled: bool,
    /// `cameras.go2rtc_name` — key in Crumb's or Frigate's embedded go2rtc.
    pub go2rtc_name: String,
    /// `cameras.main_url` — after migration 0012 this holds the RELATIVE go2rtc
    /// stream name (e.g. `"driveway"`).  Legacy rows keep their full absolute URL;
    /// `resolve_stream_url` handles both cases (pass-through for `"://"` rows).
    pub main_url: String,
    /// `cameras.sub_url` — RTSP sub stream URL (motion analysis + wall tiles).
    /// Relative stream name after 0012 (e.g. `"driveway_sub"`), or an absolute
    /// URL for legacy rows.
    pub sub_url: Option<String>,
    /// `cameras.source_url` — the RAW camera RTSP URL (the go2rtc producer
    /// source). `None` for legacy/externally-managed streams. When set, the API
    /// owns this camera's go2rtc stream config (reconcile manages go2rtc streams).
    pub source_url: Option<String>,
    /// `cameras.source_sub_url` — raw sub-stream source, if the camera has one.
    pub source_sub_url: Option<String>,
    /// `cameras.policy_id` — the camera's OWN direct recording policy. `None` ⇒
    /// the camera inherits (its group's policy, else the global default). After
    /// the named-policies migration this column is nullable; legacy cameras keep
    /// their cloned per-camera policy so behaviour is unchanged.
    pub policy_id: Option<Uuid>,
    /// The recording group this camera belongs to (`camera_group_members`), if
    /// any. A camera is in at most one group. Used so the UI can show "inherited
    /// from group X"; the recorder ignores it (the effective policy is already
    /// resolved into [`Self::policy`]).
    pub group_id: Option<Uuid>,
    /// RESOLVED effective recording policy (its own → group's → default),
    /// computed by the `COALESCE` JOIN in [`crate::db`]. This is what the recorder
    /// and all clients act on; inheritance is invisible past this point.
    pub policy: RecordingPolicy,
    /// `cameras.motion_mask` — exclusion zones to IGNORE in motion analysis.
    /// JSON array of normalized rectangles `[x, y, w, h]` (each 0..1, fraction
    /// of the frame). Legacy pixel polygons `[[x,y],…]` are still accepted.
    pub motion_mask: Option<serde_json::Value>,
    /// `cameras.onvif_motion` — when true, use ONVIF events instead of pixel-diff.
    pub onvif_motion: bool,
    /// `cameras.motion_source` — **DEPRECATED (migration 0049)**, superseded by
    /// the additive `motion_{pixel,frigate,ha}_enabled` set below. Kept only
    /// because `v_camera_effective_policy` references it; no recorder/API logic
    /// reads it. Do not add new reads.
    pub motion_source: String,
    /// The ADDITIVE motion-source set (`cameras.motion_pixel_enabled` /
    /// `motion_frigate_enabled` / `motion_ha_enabled`, migration 0049). A camera
    /// records on the UNION of every enabled source; each is toggled
    /// independently. Sub-config lives elsewhere: [`Self::motion_algorithm`]
    /// (pixel), `frigate_config` (Frigate), `camera_ha_links` (Home Assistant).
    /// Zero sources enabled on a Motion-mode camera = no detector = the recorder
    /// fails OPEN (records everything). See `docs/DECISIONS.md` (additive
    /// multi-source motion) and `docs/MOTION-DETECTION-DESIGN.md`.
    pub motion_pixel_enabled: bool,
    pub motion_frigate_enabled: bool,
    pub motion_ha_enabled: bool,
    /// `cameras.motion_algorithm` — which pixel detector to run when the pixel
    /// source is enabled: `"census"` (default), `"framediff"`, `"mog2"`,
    /// `"opticalflow"`, or `"ensemble"`. Ignored by the Frigate/HA sources.
    pub motion_algorithm: String,
    /// `cameras.camera_type` — physical camera form-factor, used purely for the
    /// admin-console tree/header glyph: `"ptz"`, `"dome"`, `"bullet"`, `"lpr"`,
    /// or `"other"`. `None` (legacy rows) is rendered as the generic/other icon.
    /// The recorder ignores it.
    pub camera_type: Option<String>,
    /// `cameras.icon` — OPTIONAL operator override for the console glyph, stored
    /// as a glyph key (`"cam_ptz"`/`"cam_dome"`/`"cam_bullet"`/`"cam_lpr"`/
    /// `"cam_other"`). `None` (the default) means "derive from `camera_type`", so
    /// picking a type still drives the icon; this only exists so an operator can
    /// pin a different glyph than the type would imply. The recorder ignores it.
    pub icon: Option<String>,
    /// `cameras.motion_grid_cols` / `motion_grid_rows` — the operator's chosen
    /// exclusion-zone *authoring* grid resolution in the motion tuner (e.g. 16×9
    /// coarse … 48×27 fine). Purely a UI preference so the tuner reopens at the
    /// grid the user last picked, per camera. `None` (the default) ⇒ the client's
    /// default (16×9). The recorder ignores these (its analysis grid is fixed).
    pub motion_grid_cols: Option<i16>,
    /// See [`Camera::motion_grid_cols`].
    pub motion_grid_rows: Option<i16>,
    /// `cameras.created_at`
    pub created_at: DateTime<Utc>,
    // ── columns added by migration 0012 ──────────────────────────────────────
    /// `cameras.served_by` — which restreamer owns this camera's go2rtc stream:
    /// `"crumb"` (Crumb's own, port :18554) or `"frigate"` (external BYO).
    /// Default `"crumb"` so legacy rows and new cameras default to Crumb-managed.
    pub served_by: String,
    /// `cameras.source_camera_name` — the external detection provider's (e.g.
    /// Frigate's) name for this camera, used to map incoming events to the correct
    /// Crumb camera UUID via [`crate::db::load_camera_name_map`].
    pub source_camera_name: Option<String>,
    /// `cameras.onvif_host` — ONVIF device hostname / IP for PTZ commands.
    pub onvif_host: Option<String>,
    /// `cameras.onvif_port` — ONVIF service port (default 80).
    pub onvif_port: Option<i32>,
    /// `cameras.onvif_user` — ONVIF authentication username.
    pub onvif_user: Option<String>,
    /// `cameras.onvif_password` — ONVIF authentication password.
    ///
    /// **NEVER included in any API response DTO** (`CameraDto` in api-routes).
    /// Carried in the `Camera` struct ONLY so `ptz.rs` and `discover.rs` can read
    /// it from the DB without an extra query.
    pub onvif_password: Option<String>,
}

impl Camera {
    /// Derive the RTSP URL for the main stream.
    ///
    /// Prefers `main_url` (populated by the seed / UI) but falls back to the
    /// go2rtc naming convention `rtsp://<base>/<go2rtc_name>` when the env
    /// override is set.
    pub fn main_rtsp_url(&self, go2rtc_base: &str) -> String {
        if !self.main_url.is_empty() {
            self.main_url.clone()
        } else {
            format!("{}/{}", go2rtc_base.trim_end_matches('/'), self.go2rtc_name)
        }
    }

    /// Derive the RTSP URL for the sub stream used by motion analysis.
    ///
    /// Prefers `sub_url` from the DB row; falls back to the go2rtc `_sub`
    /// convention (`<go2rtc_name>_sub`).
    pub fn sub_rtsp_url(&self, go2rtc_base: &str) -> String {
        if let Some(url) = &self.sub_url {
            if !url.is_empty() {
                return url.clone();
            }
        }
        format!(
            "{}/{}_sub",
            go2rtc_base.trim_end_matches('/'),
            self.go2rtc_name
        )
    }

    /// The sub-stream RTSP URL ONLY if the camera actually has one.
    ///
    /// Unlike [`Self::sub_rtsp_url`], this does NOT synthesise a `<name>_sub`
    /// URL — a camera with no `sub_url` returns `None` so motion analysis is
    /// skipped rather than 404-looping on a nonexistent stream.
    pub fn sub_rtsp_url_opt(&self) -> Option<String> {
        self.sub_url
            .as_ref()
            .map(|u| u.trim().to_owned())
            .filter(|u| !u.is_empty())
    }
}

// ─── segments ────────────────────────────────────────────────────────────────

/// Mirror of the `stage` column constraint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SegmentStage {
    Live,
    Archive,
}

impl SegmentStage {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "live" => Some(Self::Live),
            "archive" => Some(Self::Archive),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Live => "live",
            Self::Archive => "archive",
        }
    }
}

/// Mirror of the `stream` column constraint (segments table).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SegmentStream {
    Main,
    Sub,
}

impl SegmentStream {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "main" => Some(Self::Main),
            "sub" => Some(Self::Sub),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Main => "main",
            Self::Sub => "sub",
        }
    }
}

/// `segments` table row — THE index.  One row per recorded fMP4 segment.
///
/// Moving a file = updating `storage_id`, `stage`, and `path` in this row.
/// Clients never need to know which physical disk holds the bytes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Segment {
    /// `segments.id`
    pub id: Uuid,
    /// `segments.camera_id`
    pub camera_id: Uuid,
    /// `segments.storage_id` — current location; updated on archive move.
    pub storage_id: Uuid,
    /// `segments.stage`
    pub stage: SegmentStage,
    /// `segments.path` — relative path within the storage root.
    pub path: String,
    /// `segments.stream`
    pub stream: SegmentStream,
    /// `segments.start_ts`
    pub start_ts: DateTime<Utc>,
    /// `segments.end_ts`
    pub end_ts: DateTime<Utc>,
    /// `segments.duration_ms`
    pub duration_ms: i32,
    /// `segments.has_motion` — timeline colour-coding and future smart search.
    pub has_motion: bool,
    /// `segments.size_bytes`
    pub size_bytes: i64,
    /// Normalized bounding box `[x, y, w, h]` (0..1 fractions of the frame) of the
    /// motion at this segment's peak-motion frame, for the clip player's
    /// motion-highlight auto-zoom. `None` when the segment has no motion (or was
    /// recorded before the bbox columns existed). Populated only by the SELECTs
    /// that need it; other Segment reads leave it `None`.
    pub motion_bbox: Option<[f32; 4]>,
}

// ─── motion signal ───────────────────────────────────────────────────────────

/// Internal motion signal emitted by `motion.rs` and consumed by `recording.rs`.
///
/// Sent over a per-camera `tokio::sync::mpsc` channel.  The interface is kept
/// deliberately generic — a future Frigate-MQTT or ONVIF source only needs to
/// produce this type; the recording side does not change.
///
/// Maps to the semantic shape described in `docs/01-recording-engine.md` and
/// `docs/RECORDER-CORRECTNESS.md` item 15.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MotionSignal {
    /// The camera this event belongs to.
    pub camera_id: Uuid,
    /// Wall-clock UTC when motion was first detected.
    pub started_at: DateTime<Utc>,
    /// Wall-clock UTC when motion stopped (i.e. the post-buffer expired).
    /// `None` while motion is still in progress.
    pub stopped_at: Option<DateTime<Utc>>,
    /// Highest per-frame changed-pixel fraction observed during this event,
    /// in the range `[0.0, 1.0]`.
    pub peak_score: f32,
    /// Normalized bounding box `[x, y, w, h]` (0..1 fractions of the frame) of the
    /// largest motion blob at the peak-motion frame of this event. `None` when no
    /// region was captured (e.g. a Frigate-sourced signal, or a synthetic stop).
    /// `recording.rs` stamps it onto the overlapping segment with the top score.
    pub bbox: Option<[f32; 4]>,
}

// ─── views ───────────────────────────────────────────────────────────────────

/// `views` table row — a named camera layout shared across all clients.
///
/// `layout` is one of the constrained strings (`"1x1"`, `"2x2"`, `"3x3"`,
/// `"4x4"`, `"1plus5"`).  `slots` is a free-form JSON object mapping slot
/// index strings to camera UUID strings, e.g. `{"0": "<uuid>", "1": "<uuid>"}`.
///
/// The column is `jsonb`; `tokio-postgres` maps it to `serde_json::Value`
/// via the `with-serde_json-1` feature — no intermediate string parsing.
///
/// `owner_id` was added by migration `0030_view_owner.sql`.  A `None` value
/// means the view is a legacy "global" row visible to all users.  When set,
/// the view is private to that user (plus admins and anyone in `view_shares`).
#[derive(Debug, Clone, Serialize)]
pub struct View {
    /// `views.id`
    pub id: Uuid,
    /// `views.name` — human-readable label, e.g. `"Perimeter"`.
    pub name: String,
    /// `views.layout` — grid identifier, e.g. `"2x2"`.
    pub layout: String,
    /// `views.slots` — `{"<slotIndex>": "<cameraUuid>"}`.
    pub slots: serde_json::Value,
    /// `views.owner_id` — UUID of the user who created this view, or `None`
    /// for legacy global rows that pre-date ownership.
    pub owner_id: Option<Uuid>,
    /// `views.icon` — user-chosen quick-switch glyph (e.g. `"🚗"`), or `None`
    /// for a view that has never had one set. Added by `0041_view_icon.sql`;
    /// clients fall back to their own default when absent.
    pub icon: Option<String>,
    /// `views.created_at`
    pub created_at: DateTime<Utc>,
}

// ─── bookmarks ─────────────────────────────────────────────────────────────────

/// A saved playback moment — a camera + timestamp with an optional description.
///
/// Server-side and shared across all clients (desktop/mobile/web), so a bookmark
/// made on one device appears in everyone's list and jumps to that camera+time.
///
/// `protect_until` is reserved for a future "protected retention" feature (keep
/// the footage at this moment from being auto-archived/deleted until the given
/// time); it is currently always `NULL` and carries no behaviour.
#[derive(Debug, Clone, Serialize)]
pub struct Bookmark {
    /// `bookmarks.id`
    pub id: Uuid,
    /// `bookmarks.camera_id` — the camera this moment belongs to.
    pub camera_id: Uuid,
    /// Joined `cameras.name`, populated by the list query (None on create / when
    /// not joined). Lets the cross-camera list label each row without a lookup.
    pub camera_name: Option<String>,
    /// `bookmarks.ts` — the bookmarked moment in the footage.
    pub ts: DateTime<Utc>,
    /// `bookmarks.description` — optional free-text note.
    pub description: Option<String>,
    /// `bookmarks.protect_until` — while > now(), the footage window below is kept
    /// from auto-archive/delete; NULL = not protected.
    pub protect_until: Option<DateTime<Utc>>,
    /// `bookmarks.protect_start_ts` / `protect_end_ts` — the protected footage
    /// window around the moment (NULL when not protected).
    pub protect_start_ts: Option<DateTime<Utc>>,
    pub protect_end_ts: Option<DateTime<Utc>>,
    /// `bookmarks.created_at` — when the bookmark was made.
    pub created_at: DateTime<Utc>,
}

// ─── motion grid (motion tuner) ────────────────────────────────────────────────

/// The live per-camera motion view published by the recorder for the tuner.
///
/// `cells` is a row-major jsonb array of length `cols * rows`, each value 0..100
/// (% of that cell's pixels that are foreground in the latest frame). The grid is
/// FINE (e.g. 80×45) and rendered as the detector's actual changing pixels —
/// post-exclusion, post-morphology — not coarse boxes.
///
/// `score` is the latest frame's largest-connected-blob area as a fraction of the
/// frame (0..1) — the SAME quantity that drives the recording trigger and the
/// timeline `motion_score`. `threshold` is the effective floor it is compared
/// against (0..1). Publishing both lets the tuner draw a coherent live meter and
/// threshold marker on one shared scale.
#[derive(Debug, Clone, Serialize)]
pub struct MotionGrid {
    pub cols: i16,
    pub rows: i16,
    pub cells: serde_json::Value,
    pub score: f32,
    pub threshold: f32,
    pub updated_at: DateTime<Utc>,
}

// ─── recorder heartbeat ────────────────────────────────────────────────────────

/// Liveness heartbeat written by the recorder process (`recorder_heartbeat`
/// singleton row, id = 1).  The recorder upserts `updated_at = now()` on a
/// fixed interval; the API reads it for the `/status` endpoint so the Server
/// health panel can distinguish "recorder daemon is alive" from "old segments
/// still on disk but the daemon is wedged".
#[derive(Debug, Clone, Serialize)]
pub struct RecorderHeartbeat {
    /// Wall-clock time of the last heartbeat write.
    pub updated_at: DateTime<Utc>,
    /// OS process id of the recorder that wrote it (diagnostic).
    pub pid: Option<i32>,
    /// Number of camera workers actively running at the last write.
    pub active_cameras: i32,
}

// ─── motion-decode truth telemetry (migration 0035) ──────────────────────────

/// Accelerator capabilities detected INSIDE the recorder container
/// (`recorder_capabilities` singleton row, id = 1; refreshed on recorder boot).
///
/// The admin console uses this to explain WHY a requested decode backend
/// can't work — e.g. `motion_hwaccel = "vaapi"` with an empty `dri_devices`
/// means the render node isn't mapped in (missing vaapi compose overlay).
#[derive(Debug, Clone, Serialize)]
pub struct RecorderCapabilities {
    /// DRI render nodes present in the container (full paths, e.g.
    /// `/dev/dri/renderD128`). Empty ⇒ VAAPI decode cannot work.
    pub dri_devices: Vec<String>,
    /// Any `/dev/nvidia*` device node present (NVIDIA GPU mapped in).
    pub nvidia: bool,
    /// Hwaccels the bundled ffmpeg was COMPILED with (`ffmpeg -hwaccels`).
    /// Compiled-in support, not runtime usability.
    pub ffmpeg_hwaccels: Vec<String>,
    /// When the recorder last refreshed this row (its boot time).
    pub detected_at: DateTime<Utc>,
}

/// Per-camera decode-backend truth (`camera_decode_status`, one row per
/// camera; upserted by the motion task on every ffmpeg decode (re)start).
#[derive(Debug, Clone, Serialize)]
pub struct CameraDecodeStatus {
    pub camera_id: Uuid,
    /// Camera display name (joined from `cameras` for UI convenience).
    pub camera_name: String,
    /// Backend the operator requested at worker spawn:
    /// `"auto"` | `"cuda"` | `"vaapi"` | `"cpu"`.
    pub requested: String,
    /// Backend the live ffmpeg decode child was launched with:
    /// `"cuda"` | `"vaapi"` | `"cpu"` | `"none"` (no local decode).
    pub active: String,
    /// Short human explanation when `requested != active` (or the launched
    /// backend is expected to fail); `None` when all is well.
    pub fallback_reason: Option<String>,
    pub updated_at: DateTime<Utc>,
}

// ─── motion RAM-cache telemetry (migration 0039) ──────────────────────────────

/// Global motion-cache filesystem truth (`motion_cache_status`, singleton row
/// id = 1). Refreshed periodically by the recorder — see
/// `docs/MOTION-RECORDING.md` and `MOTION_CACHE_DIR`/`MOTION_CACHE_TMPFS_BYTES`.
#[derive(Debug, Clone, Serialize)]
pub struct MotionCacheStatus {
    /// Free bytes on the filesystem backing `MOTION_CACHE_DIR` (statvfs).
    pub free_bytes: i64,
    /// Total bytes of that filesystem (the tmpfs sizing).
    pub total_bytes: i64,
    /// Whether any Motion-mode camera currently has its cache dir active.
    pub caching_active: bool,
    /// `MOTION_RECORDING_SHADOW` — every segment persists regardless of the
    /// buffer's verdict; ring numbers are for validation only while this is set.
    pub shadow_mode: bool,
    pub updated_at: DateTime<Utc>,
}

/// Per-camera motion RAM-ring occupancy (`camera_motion_cache_status`, one row
/// per Motion-mode camera; absent for Continuous-mode cameras).
#[derive(Debug, Clone, Serialize)]
pub struct CameraMotionCacheStatus {
    pub camera_id: Uuid,
    /// Camera display name (joined from `cameras` for UI convenience).
    pub camera_name: String,
    /// Number of segments currently sitting in this camera's RAM ring buffer.
    pub ring_segments: i32,
    /// Summed `size_bytes` of those pending segments.
    pub ring_bytes: i64,
    pub updated_at: DateTime<Utc>,
}

// ─── users ───────────────────────────────────────────────────────────────────

/// Mirror of the `role` column constraint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UserRole {
    Admin,
    Viewer,
}

impl UserRole {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "admin" => Some(Self::Admin),
            "viewer" => Some(Self::Viewer),
            _ => None,
        }
    }

    /// Serialise to the `text` value Postgres expects.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Admin => "admin",
            Self::Viewer => "viewer",
        }
    }
}

/// `users` table row.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    /// `users.id`
    pub id: Uuid,
    /// `users.username`
    pub username: String,
    /// `users.password_hash` — never expose over the API.
    pub password_hash: String,
    /// `users.role` — legacy binary role, kept as a back-compat mirror. The
    /// authoritative permissions now come from the assigned [`Role`] (`role_id`).
    pub role: UserRole,
    /// `users.camera_ids` — LEGACY per-user camera list (superseded by the role's
    /// cameras). NOTE: the column is `jsonb`; deserialise via
    /// `serde_json::from_value(row.get("camera_ids"))?`.
    pub camera_ids: Vec<Uuid>,
    /// `users.role_id` — the assigned permission [`Role`] (source of truth for
    /// capabilities + camera access). `None` only for rows not yet migrated.
    pub role_id: Option<Uuid>,
}

// ─── roles (RBAC) ──────────────────────────────────────────────────────────────

/// Bookmark visibility a role grants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum BookmarkScope {
    /// No bookmark access.
    #[default]
    None,
    /// See/manage only bookmarks the user created (on the role's cameras).
    Own,
    /// See ALL bookmarks on the role's cameras (and create), but edit/delete
    /// only one's OWN — a read-all, manage-own tier. Serialized as `"viewall"`.
    ViewAll,
    /// See and manage (edit/delete) ALL bookmarks on the role's cameras.
    All,
}

/// Capability set carried by a [`Role`]. Serde defaults keep it forward-compatible:
/// a key missing from the stored jsonb reads as the conservative default.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Capabilities {
    /// Create + download exports.
    #[serde(default)]
    pub export: bool,
    /// Watch recorded footage / scrub the timeline. Off ⇒ live-only.
    #[serde(default)]
    pub playback: bool,
    /// Browse the Clips tab.
    #[serde(default)]
    pub clips: bool,
    /// Pan/tilt/zoom control.
    #[serde(default)]
    pub ptz: bool,
    /// Bookmark visibility/creation level.
    #[serde(default)]
    pub bookmarks: BookmarkScope,
    /// Create + share saved views.
    #[serde(default)]
    pub manage_views: bool,
}

impl Capabilities {
    /// Everything enabled — the effective caps for the built-in admin role.
    #[must_use]
    pub fn all() -> Self {
        Self {
            export: true,
            playback: true,
            clips: true,
            ptz: true,
            bookmarks: BookmarkScope::All,
            manage_views: true,
        }
    }
}

/// `roles` table row — a named permission profile (capabilities + camera scope).
#[derive(Debug, Clone, Serialize)]
pub struct Role {
    pub id: Uuid,
    pub name: String,
    /// Built-in all-access role; `capabilities`/`camera_ids` are ignored for it.
    pub is_admin: bool,
    pub capabilities: Capabilities,
    /// Cameras members of this role may access (ignored when `is_admin`).
    pub camera_ids: Vec<Uuid>,
    pub created_at: DateTime<Utc>,
}

impl Role {
    /// Effective capabilities — admin roles get everything regardless of stored caps.
    #[must_use]
    pub fn effective_caps(&self) -> Capabilities {
        if self.is_admin {
            Capabilities::all()
        } else {
            self.capabilities.clone()
        }
    }
}

// ─── sessions (revocable auth) ─────────────────────────────────────────────────

/// `sessions` table row — a server-side record of one issued access token,
/// keyed by the token's `jti` claim (see migration `0033_sessions.sql`).
///
/// The presence of a matching un-revoked row is what lets the `AuthUser`
/// extractor honour revocation: revoking sets `revoked_at`, and the extractor
/// (via an in-memory revocation cache) then rejects any token whose `jti` is
/// revoked — even a 10-year "remember me" token that is otherwise still valid
/// by signature + `exp`.
#[derive(Debug, Clone, Serialize)]
pub struct Session {
    /// The token's `jti` claim (a UUID). Primary key.
    pub jti: Uuid,
    /// Owning user id (`users.id`).
    pub user_id: Uuid,
    /// Human-friendly device/client label for the "your sessions" UI. Advisory.
    pub label: Option<String>,
    /// Best-effort client IP captured at issue time. Advisory.
    pub ip: Option<String>,
    /// Whether this was minted as a long-lived "remember me" token.
    pub long_lived: bool,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    /// Mirror of the token's `exp`, so a housekeeping sweep can prune dead rows.
    pub expires_at: DateTime<Utc>,
    /// `None` ⇒ active; `Some(_)` ⇒ revoked at this instant (extractor rejects it).
    pub revoked_at: Option<DateTime<Utc>>,
}
