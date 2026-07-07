// SPDX-License-Identifier: AGPL-3.0-or-later

//! Environment-variable driven configuration for `crumb-api`.
//!
//! All values are read once at startup via [`ApiConfig::from_env`].  Docker
//! Compose injects the environment.  Every field has a documented default so
//! the service can start in development with a minimal `.env`.
//!
//! # Example
//!
//! ```no_run
//! use crumb_api::config::ApiConfig;
//! let cfg = ApiConfig::from_env().expect("invalid configuration");
//! println!("listening on {}", cfg.bind_addr);
//! ```

use anyhow::{Context, Result};
use std::{collections::HashMap, env, net::SocketAddr};

use crate::ptz::OnvifCameraConfig;

/// Fully-resolved runtime configuration for the API service.
#[derive(Debug, Clone)]
pub struct ApiConfig {
    // -- database -----------------------------------------------------------
    /// `DATABASE_URL` -- deadpool-postgres connection string.
    ///
    /// Example: `postgresql://crumb:secret@localhost:5432/crumb`
    pub database_url: String,

    /// `DB_POOL_SIZE` -- maximum connections in the deadpool.  Default: `32`
    /// (was 10 — too small: at 16+ cameras the concurrent recording/motion tasks
    /// plus API clients starved a 10-conn pool, causing multi-second hangs and
    /// dropped writes). Set higher via env for >16 cameras (≈ 2*cameras + 10).
    pub db_pool_size: usize,

    /// `PLAYBACK_MAX_CONCURRENCY` -- max concurrent DB checkouts the `/play/aligned`
    /// fan-out may hold at once (a shared semaphore). Bounds the unbounded
    /// per-camera task spawn so a burst of multi-camera aligned-playback requests
    /// cannot starve the pool. Default: `8`.
    pub playback_max_concurrency: usize,

    // -- network ------------------------------------------------------------
    /// `API_BIND` -- socket address the HTTP server listens on.
    ///
    /// Default: `0.0.0.0:8080`
    pub bind_addr: SocketAddr,

    // -- auth ---------------------------------------------------------------
    /// `JWT_SECRET` -- HMAC-SHA256 signing key for JWT tokens.
    ///
    /// Must be at least 32 bytes of entropy.  Required (no default).
    pub jwt_secret: String,

    /// `JWT_EXPIRY_SECONDS` -- how long a token lives.  Default: `86400` (24 h).
    pub jwt_expiry_seconds: u64,

    // -- storage roots ------------------------------------------------------
    /// `LIVE_STORAGE_PATH` -- in-container mount point for live recordings.
    ///
    /// Mounted read-only from the host (same bind as the recorder's live dir).
    /// Default: `/data/live`
    ///
    /// No longer read by request handlers: a segment's file is now resolved SOLELY
    /// by its `storage_id` (→ `storages.path`), never by a stage→mount guess (A1).
    /// Retained as the documented operational mount contract (the compose bind
    /// still mounts this path read-only); kept in the struct so the env var stays
    /// part of the config surface.
    #[allow(dead_code)]
    pub live_storage_path: String,

    /// `ARCHIVE_STORAGE_PATH` -- in-container mount point for archive footage.
    ///
    /// Mounted read-only from the host.
    /// Default: `/data/archive`
    ///
    /// No longer read by request handlers: a segment's file is now resolved SOLELY
    /// by its `storage_id` (→ `storages.path`), never by a stage→mount guess (A1).
    /// Retained as the documented operational mount contract (the compose bind
    /// still mounts this path read-only); kept in the struct so the env var stays
    /// part of the config surface.
    #[allow(dead_code)]
    pub archive_storage_path: String,

    // -- go2rtc -------------------------------------------------------------
    /// `GO2RTC_RTSP_BASE` -- base RTSP URL of Frigate's (external) go2rtc.
    ///
    /// Default: `""` (empty). The live value is read from the `server_settings`
    /// DB table (set via the admin "Server & streaming" page); this env is a
    /// fallback for when the DB row has an empty value.
    pub go2rtc_rtsp_base: String,

    /// `GO2RTC_API_BASE` -- base HTTP URL of Frigate's go2rtc REST API.
    ///
    /// Default: `""` (empty). Fallback behind `server_settings.frigate_api_base`.
    pub go2rtc_api_base: String,

    /// `CRUMB_GO2RTC_API_BASE` -- base HTTP URL of Crumb's OWN go2rtc
    /// restreamer, which runs EMBEDDED inside the `recorder` container (the
    /// recorder spawns + supervises the go2rtc binary — see
    /// `services/recorder/src/go2rtc_embed.rs`). The API reaches it over the
    /// internal compose network by the recorder's service name, so it need NOT
    /// be exposed to the host. The live MSE proxy uses this for cameras served
    /// by the restreamer.
    ///
    /// Default: `http://recorder:1984` (internal Docker Compose service name —
    /// host-agnostic and safe to keep as a binary default).
    pub crumb_go2rtc_api_base: String,

    /// `CRUMB_GO2RTC_RTSP_BASE` -- RTSP base of Crumb's own go2rtc restreamer.
    ///
    /// Default: `""` (empty). Fallback behind `server_settings.crumb_rtsp_base`.
    /// The compose file sets this per service (`rtsp://localhost:8554` for the
    /// recorder — go2rtc lives in its container — and leaves the api's empty)
    /// so an in-Docker fresh install records without operator configuration.
    pub crumb_go2rtc_rtsp_base: String,

    /// `GO2RTC_USER` / `GO2RTC_PASS` -- Basic-auth credentials for Crumb's OWN
    /// go2rtc restreamer (P0-GO2RTC lighter lockdown, see `docker-compose.yml`
    /// and `go2rtc/go2rtc.yaml`). Required (no default; `from_env` errors if
    /// unset) since go2rtc.yaml's `rtsp`/`api` auth blocks always reference
    /// `${GO2RTC_USER}`/`${GO2RTC_PASS}` — an empty credential would either
    /// break go2rtc's env substitution or (worse) silently disable auth.
    ///
    /// Used to:
    /// * authenticate the API's own internal go2rtc REST calls (stream.mp4
    ///   proxy, webrtc SDP proxy, frame.jpeg proxy, reconcile PUT/DELETE) —
    ///   these cross the Docker bridge network, which go2rtc does NOT treat as
    ///   "localhost", so they are subject to auth like any other caller.
    /// * embed into the `rtsp://user:pass@host:18554/<name>` URLs returned by
    ///   `GET /cameras/{id}/streams` so desktop/Android native RTSP playback
    ///   keeps working with zero client-side changes.
    ///
    /// Supports the `_FILE` Docker-secret convention via `require_secret`.
    pub go2rtc_user: String,
    pub go2rtc_pass: String,

    // -- export -------------------------------------------------------------
    /// `EXPORT_DIR` -- directory where completed export MP4 files are written.
    ///
    /// Default: `/data/exports`
    pub export_dir: String,

    /// `EXPORT_TTL_SECONDS` -- how long export files are kept before cleanup.
    ///
    /// Default: `86400` (24 h)
    pub export_ttl_seconds: u64,

    /// `EXPORT_MAX_CONCURRENT` -- max export jobs allowed to be Queued/Running at
    /// once. Bounds unbounded ffmpeg spawning (each export is one ffmpeg per
    /// camera). Default: `2`.
    pub export_max_concurrent: usize,

    /// `CLIP_GEN_MAX_CONCURRENCY` -- max simultaneous on-demand clip transcodes
    /// (the Clips tab). Each play streams one libx264 ffmpeg, paced by the
    /// client's read; the permit is held for the play's lifetime, so this caps
    /// concurrent clip plays. Thumbnails (single-frame) are not gated. Default: `4`.
    pub clip_gen_max_concurrency: usize,

    /// `CLIP_CACHE_MAX_BYTES` -- soft byte budget for the on-demand clip cache
    /// (`{export_dir}/clips`). The TTL sweeper evicts oldest-by-mtime past this
    /// budget in addition to the 24 h age rule, so a burst of plays can't grow
    /// the cache unbounded within a day. Default: `10 GiB`.
    pub clip_cache_max_bytes: u64,

    // -- detection (Frigate) -----------------------------------------------
    /// `FRIGATE_API_BASE` -- base URL of Frigate's HTTP API, used by the
    /// snapshot proxy handler to fetch detection JPEGs.
    ///
    /// Default: `""` (empty). The live value is read from `server_settings`
    /// (`frigate_api_base`) or `frigate_config` (`api_base`); this env is the
    /// final fallback. Only consulted when the `detection` feature is enabled
    /// and a `GET /events/{id}/snapshot` request arrives with a relative URL.
    pub frigate_api_base: String,

    // NB: the #11 frigate go2rtc-vs-HTTP split lives in `server_settings`
    // (frigate_go2rtc_api_base / frigate_http_api_base, migration 0014), resolved
    // per-request by go2rtc::resolve_bases + events.rs. The startup ENV fallbacks
    // are the existing `go2rtc_api_base` (GO2RTC_API_BASE, :1984) and
    // `frigate_api_base` (FRIGATE_API_BASE, :5000) above — no separate ApiConfig
    // fields are needed.

    // -- alerting -----------------------------------------------------------
    /// `ALERT_WEBHOOK_URL` -- optional generic JSON webhook. When set, a
    /// watchdog POSTs `{content, text}` (Discord reads `content`, Slack reads
    /// `text`) when the recorder heartbeat goes stale (>60 s) and again on
    /// recovery. Empty/unset disables alerting (no-op watchdog).
    pub alert_webhook_url: Option<String>,

    // -- admin bootstrap ----------------------------------------------------
    /// `SEED_ADMIN_USERNAME` -- bootstrap admin username, created at startup if
    /// no admin exists yet.  Default: `admin`.
    pub seed_admin_username: String,

    /// `SEED_ADMIN_PASSWORD` -- plaintext bootstrap admin password (hashed at
    /// startup).  Empty disables seeding.  No default (set in `.env`).
    pub seed_admin_password: String,

    // -- ONVIF PTZ ----------------------------------------------------------
    /// `ONVIF_CONFIG` -- JSON object keyed by camera `go2rtc_name` containing
    /// ONVIF connection parameters for PTZ-capable cameras.
    ///
    /// Example value:
    ///
    /// ```json
    /// {"lpr":{"host":"198.51.100.6","port":80,"user":"admin","password":"secret"}}
    /// ```
    ///
    /// Missing or empty `ONVIF_CONFIG` is **not** an error -- the service
    /// starts normally; `POST /cameras/:id/ptz` returns 404 for every camera.
    pub onvif_cameras: HashMap<String, OnvifCameraConfig>,
}

impl ApiConfig {
    /// Read configuration from the process environment.
    ///
    /// # Errors
    ///
    /// Returns [`anyhow::Error`] with context describing which variable failed.
    pub fn from_env() -> Result<Self> {
        // DATABASE_URL and JWT_SECRET are secrets → support the `_FILE`
        // convention (Docker secrets) in addition to plaintext env (Risk #9).
        let database_url = require_secret("DATABASE_URL")?;
        let jwt_secret = require_secret("JWT_SECRET")?;
        anyhow::ensure!(
            jwt_secret.len() >= 32,
            "JWT_SECRET must be at least 32 bytes; got {} bytes",
            jwt_secret.len()
        );
        // Backstop: refuse to start on the known weak placeholder value.  The
        // primary prevention is `setup-env.sh` generating a strong secret; this
        // catch fires only if someone hand-wrote the placeholder into .env.
        const WEAK_JWT: &str = "change-me-generate-with-openssl-rand-hex-32";
        anyhow::ensure!(
            jwt_secret != WEAK_JWT,
            "JWT_SECRET is the known placeholder value; generate a real one \
             (openssl rand -hex 32) or let setup-env.sh / the auto-secret bootstrap create it"
        );

        let bind_str = optional_env("API_BIND", "0.0.0.0:8080");
        let bind_addr: SocketAddr = bind_str
            .parse()
            .with_context(|| format!("API_BIND '{bind_str}' is not a valid socket address"))?;

        let onvif_cameras = parse_onvif_config()?;

        Ok(Self {
            database_url,
            db_pool_size: parse_env("DB_POOL_SIZE", 32)?,
            playback_max_concurrency: parse_env("PLAYBACK_MAX_CONCURRENCY", 8usize)?.max(1),
            bind_addr,
            jwt_secret,
            jwt_expiry_seconds: parse_env("JWT_EXPIRY_SECONDS", 86_400_u64)?,
            live_storage_path: optional_env("LIVE_STORAGE_PATH", "/data/live"),
            archive_storage_path: optional_env("ARCHIVE_STORAGE_PATH", "/data/archive"),
            go2rtc_rtsp_base: optional_env("GO2RTC_RTSP_BASE", ""),
            go2rtc_api_base: optional_env("GO2RTC_API_BASE", ""),
            crumb_go2rtc_api_base: optional_env("CRUMB_GO2RTC_API_BASE", "http://recorder:1984"),
            crumb_go2rtc_rtsp_base: optional_env("CRUMB_GO2RTC_RTSP_BASE", ""),
            go2rtc_user: require_secret("GO2RTC_USER")?,
            go2rtc_pass: require_secret("GO2RTC_PASS")?,
            export_dir: optional_env("EXPORT_DIR", "/data/exports"),
            export_ttl_seconds: parse_env("EXPORT_TTL_SECONDS", 86_400_u64)?,
            export_max_concurrent: parse_env("EXPORT_MAX_CONCURRENT", 2usize)?.max(1),
            clip_gen_max_concurrency: parse_env("CLIP_GEN_MAX_CONCURRENCY", 4usize)?.max(1),
            clip_cache_max_bytes: parse_env("CLIP_CACHE_MAX_BYTES", 10_737_418_240_u64)?,
            frigate_api_base: optional_env("FRIGATE_API_BASE", ""),
            alert_webhook_url: optional_env_opt("ALERT_WEBHOOK_URL"),
            seed_admin_username: optional_env("SEED_ADMIN_USERNAME", "admin"),
            // Secret: supports SEED_ADMIN_PASSWORD_FILE (Docker secret) too.
            seed_admin_password: crumb_common::config::secret_env("SEED_ADMIN_PASSWORD")
                .unwrap_or_default(),
            onvif_cameras,
        })
    }
}

// -- helpers ------------------------------------------------------------------

/// Resolve a required secret via the shared `_FILE`-aware reader (Docker secret
/// file path in `{key}_FILE`, else plain `{key}` env). Errors if absent in both.
fn require_secret(key: &str) -> Result<String> {
    crumb_common::config::secret_env(key)
        .with_context(|| format!("required secret '{key}' (or '{key}_FILE') is not set"))
}

fn optional_env(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_owned())
}

/// Read an optional env var, returning `None` when unset OR set-but-empty
/// (so `FOO=` in a generated `.env` disables the feature rather than passing an
/// empty string downstream).
fn optional_env_opt(key: &str) -> Option<String> {
    match env::var(key) {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => None,
    }
}

fn parse_env<T>(key: &str, default: T) -> Result<T>
where
    T: std::str::FromStr + std::fmt::Display,
    T::Err: std::fmt::Display,
{
    match env::var(key) {
        Ok(val) => val
            .parse::<T>()
            .map_err(|e| anyhow::anyhow!("env var '{key}' = '{val}' could not be parsed: {e}")),
        Err(_) => Ok(default),
    }
}

/// Parse the ONVIF config from the environment.
///
/// The config is a JSON object keyed by camera `go2rtc_name`:
///
/// ```json
/// {"<go2rtc_name>": {"host": "...", "port": 80, "user": "...", "password": "..."}}
/// ```
///
/// It is provided **base64-encoded** via `ONVIF_CONFIG_B64` so the JSON (with
/// its quotes/braces, and a password that may contain shell metacharacters)
/// survives `.env` + docker-compose substitution unmangled. Raw `ONVIF_CONFIG`
/// is still accepted as a fallback for local/dev use.
///
/// Returns an empty map when neither var is set or both are empty (not an
/// error). Returns an error when a present value can't be decoded/parsed.
fn parse_onvif_config() -> Result<HashMap<String, OnvifCameraConfig>> {
    use base64::Engine as _;

    let json = match env::var("ONVIF_CONFIG_B64") {
        Ok(b64) if !b64.trim().is_empty() => {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(b64.trim())
                .context("ONVIF_CONFIG_B64 is not valid base64")?;
            Some(String::from_utf8(bytes).context("ONVIF_CONFIG_B64 decoded to non-UTF-8")?)
        }
        _ => match env::var("ONVIF_CONFIG") {
            Ok(raw) if !raw.trim().is_empty() => Some(raw),
            _ => None,
        },
    };

    match json {
        None => Ok(HashMap::new()),
        Some(val) => serde_json::from_str::<HashMap<String, OnvifCameraConfig>>(&val)
            .with_context(|| {
                "ONVIF config is not valid JSON; expected an object keyed by go2rtc_name, \
                 e.g. {\"lpr\":{\"host\":\"198.51.100.6\",\"port\":80,\"user\":\"admin\",\"password\":\"...\"}}"
            }),
    }
}
