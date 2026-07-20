// SPDX-License-Identifier: AGPL-3.0-or-later

//! Environment-variable driven configuration.
//!
//! All tunables are read at startup via [`Config::from_env`].  No config file
//! is used; Docker Compose injects the variables.  Every field has a
//! documented default so the service can start for local development with a
//! minimal `.env`.
//!
//! # Example
//!
//! ```no_run
//! use crumb_common::config::Config;
//! let cfg = Config::from_env().expect("invalid configuration");
//! println!("segment length: {}s", cfg.segment_seconds);
//! ```

use anyhow::{Context, Result};
use std::env;
use std::sync::OnceLock;

/// Fully-resolved runtime configuration.
#[derive(Debug, Clone)]
pub struct Config {
    // ── database ───────────────────────────────────────────────────────────
    /// `DATABASE_URL` — deadpool-postgres connection string.
    ///
    /// Example: `postgresql://crumb:secret@localhost:5432/crumb`
    pub database_url: String,

    /// `DB_POOL_SIZE` — maximum connections in the deadpool.  Default: `32`
    /// (was 10 — the recorder spawns ~2 DB-using tasks per camera (recording +
    /// motion) plus heartbeat/archive/reconcile; 10 starved at 16+ cameras). Raise
    /// via env for >16 cameras (≈ 2*cameras + 10); also raise Postgres max_connections.
    pub db_pool_size: usize,

    // ── streaming ──────────────────────────────────────────────────────────
    /// `GO2RTC_RTSP_BASE` — base URL for Frigate's embedded go2rtc RTSP server.
    ///
    /// Default: `""` (empty — the recorder resolves the real value from
    /// `server_settings` at startup; this env value is a fallback only). Set to
    /// e.g. `rtsp://frigate-host:8554` to override without using the admin UI.
    pub go2rtc_rtsp_base: String,

    /// `CRUMB_GO2RTC_RTSP_BASE` — base URL for the **crumb-owned** go2rtc RTSP
    /// server (distinct from Frigate's embedded go2rtc).
    ///
    /// Crumb manages its own go2rtc instance (default port 18554) to serve
    /// cameras that it owns directly.  When the recorder resolves the RTSP URL
    /// for a `served_by = 'crumb'` camera it first consults `server_settings`
    /// (populated via the admin UI or the env-seed); this env var is a
    /// defense-in-depth fallback so the recorder can self-heal if the DB row
    /// was never written (finding #20 / #1 interaction).
    ///
    /// Default: `""` (no homelab IP baked in — must be configured per
    /// deployment via this env var or the admin UI).  Set to e.g.
    /// `rtsp://crumb-host:18554`.
    pub crumb_go2rtc_rtsp_base: String,

    /// `GO2RTC_USER` / `GO2RTC_PASS` -- Basic-auth / RTSP-auth credentials for
    /// Crumb's OWN go2rtc restreamer (P0-GO2RTC lighter lockdown). The recorder
    /// embeds these into the RTSP URL it connects ffmpeg to for
    /// `served_by = 'crumb'` cameras, since go2rtc's RTSP listener now requires
    /// auth (see `go2rtc/go2rtc.yaml`) and the recorder's connection crosses the
    /// Docker bridge network (not real loopback), so it is not exempt.
    ///
    /// Default: `""` (empty) — deliberately NOT `require_secret` here, unlike
    /// `crumb_api::config::ApiConfig::go2rtc_user/pass` (which IS required):
    /// this shared `Config` backs many recorder unit tests that call
    /// `Config::from_env()` without setting every var, and an empty value here
    /// only degrades to a failed RTSP connect attempt (recorder retries; no
    /// security hole, since go2rtc — not the recorder — enforces the auth).
    /// The REAL enforcement is `docker-compose.yml`'s `${GO2RTC_USER:?...}` /
    /// `${GO2RTC_PASS:?...}`, which fail `docker compose up` fast if unset, and
    /// go2rtc.yaml's `${GO2RTC_USER}` substitution. `from_env` logs a `warn!` if
    /// empty so a misconfigured non-compose deployment doesn't fail silently.
    pub go2rtc_user: String,
    pub go2rtc_pass: String,

    // ── recording ──────────────────────────────────────────────────────────
    /// `SEGMENT_SECONDS` — target segment duration in seconds.
    ///
    /// Must be in the range `[2, 6]`.  Default: `4`.
    pub segment_seconds: u32,

    // ── storage ────────────────────────────────────────────────────────────
    /// `LIVE_STORAGE_PATH` — filesystem path for live recordings inside the
    /// container.
    ///
    /// Default: `/data/live`
    pub live_storage_path: String,

    /// `LIVE_STORAGE_NAME` — human label inserted/upserted into `storages`.
    ///
    /// Default: `"NVMe-Live"`
    pub live_storage_name: String,

    /// `ARCHIVE_STORAGE_PATH` — filesystem path for archive recordings.
    ///
    /// Default: `/data/archive`
    pub archive_storage_path: String,

    /// `ARCHIVE_STORAGE_NAME` — human label for the archive storage row.
    ///
    /// Default: `"Bulk-Archive"`
    pub archive_storage_name: String,

    /// `RECORDER_TZ` — IANA timezone the per-camera archive-schedule cron is
    /// evaluated in, so a "Daily at 02:00" schedule fires at **local** 02:00
    /// (DST-correct), not 02:00 UTC. Falls back to `TZ`, else `UTC` when neither
    /// is set (matching the documented .env.example contract).
    pub archive_cron_tz: chrono_tz::Tz,

    // ── motion ─────────────────────────────────────────────────────────────
    /// `MOTION_HWACCEL` — hardware acceleration mode for motion sub-stream
    /// decode.
    ///
    /// Accepted values: `cuda` (NVDEC via ffmpeg `-hwaccel cuda`), `vaapi`
    /// (Intel/AMD iGPU via ffmpeg `-hwaccel vaapi`), `cpu` (software decode), or
    /// `auto` (probe at startup — uses NVDEC when available, otherwise CPU).
    ///
    /// Default: `auto`.
    pub motion_hwaccel: HwAccel,

    /// `MOTION_VAAPI_DEVICE` — DRI render node used for VAAPI decode when
    /// `MOTION_HWACCEL=vaapi`. Must be mapped into the container (and the
    /// container user must have render-group access). Ignored for non-VAAPI modes.
    ///
    /// Default: `/dev/dri/renderD128` (the usual Intel iGPU render node; AMD
    /// iGPUs and multi-GPU hosts may enumerate a different node).
    pub motion_vaapi_device: String,

    /// `MAX_GPU_DECODE_SESSIONS` — global semaphore cap on concurrent NVDEC
    /// sessions (correctness item 11).
    ///
    /// Default: `4`.
    pub max_gpu_decode_sessions: usize,

    // ── supervisor ─────────────────────────────────────────────────────────
    /// `CONFIG_POLL_SECONDS` — how often the supervisor diffs the DB camera
    /// list vs running workers.
    ///
    /// Default: `30`.
    pub config_poll_seconds: u64,

    /// `RECONCILE_INTERVAL_SECONDS` — how often the background reconcile pass
    /// (adopt orphan files + repair `size_bytes` drift + prune dangling rows)
    /// re-runs after the first startup pass.
    ///
    /// Reconcile used to run only once at startup, so any orphan a recording
    /// reconnect or a motion-mode gap left on disk stayed un-indexed (invisible
    /// to the stats and to size-cap eviction) until the next recorder restart.
    /// Running it on a timer keeps the segment index converged with the
    /// filesystem within one interval, so the per-policy usage numbers and
    /// eviction always act on real bytes.
    ///
    /// Default: `900` (15 minutes). Floored to 60 s.
    pub reconcile_interval_seconds: u64,

    /// `RECONCILE_PAUSED` — when true, the recorder runs NO reconcile passes
    /// (neither the startup catch-up nor the periodic loop). Recording, motion,
    /// and retention/eviction continue normally.
    ///
    /// This is a maintenance switch: reconcile adopts orphan files on disk and,
    /// on a `(camera_id, stream, start_ts)` key conflict, rewrites the existing
    /// row's location to match what it last saw on disk. That is correct for
    /// healing crash drift, but it races any deliberate out-of-band file movement
    /// (a storage migration / tiering / disk swap), so such operations MUST pause
    /// reconcile first. Default: `false`.
    pub reconcile_paused: bool,

    // ── seed ───────────────────────────────────────────────────────────────
    /// `SEED_ADMIN_USERNAME` — username for the bootstrap admin user.
    ///
    /// Default: `admin`.
    pub seed_admin_username: String,

    /// `SEED_ADMIN_PASSWORD_HASH` — bcrypt/argon2 hash for the bootstrap admin.
    ///
    /// If empty the seed subcommand will error rather than insert a blank hash.
    pub seed_admin_password_hash: String,

    // ── motion recording (RAM pre-buffer + persist-on-motion) ────────────────
    /// `MOTION_CACHE_DIR` — container-internal directory ffmpeg writes segments
    /// into for Motion-mode cameras (a RAM-backed tmpfs mount is the intended
    /// deployment, hence "cache", but any writable path works). The recorder's
    /// `MotionBuffer` decides per-segment whether to copy a cached segment into
    /// storage (persist) or delete it from the cache (discard). Continuous-mode
    /// cameras are completely unaffected — they always write directly to the
    /// storage root, exactly as before this feature existed.
    ///
    /// Default: `/cache/motion`.
    pub motion_cache_dir: String,

    /// `MOTION_RECORDING_SHADOW` — when `true`, Motion-mode cameras keep
    /// recording and indexing every segment exactly as today (direct to
    /// storage, no cache dir, no discards — byte-for-byte unchanged file
    /// operations), but the recorder ALSO runs the `MotionBuffer` decision in
    /// parallel and stamps the verdict on `segments.motion_shadow_keep`
    /// (migration 0037) for prod validation before actually enabling the
    /// cache/discard behaviour.
    ///
    /// Default: `false`.
    pub motion_recording_shadow: bool,

    /// `MOTION_UNHEALTHY_ALERT_SECS` — minimum continuous-unhealthy duration
    /// (seconds) before the recorder emits a `motion_detector_unhealthy`
    /// `system_events` row for a camera.
    ///
    /// The detector health signal itself (the `health_tx`/`health_rx` watch
    /// channel that drives fail-open recording) flips immediately on every
    /// transition — this knob delays only the ALERT, not the safety rail.
    /// Flaky cameras (e.g. Reolink units that self-reboot) commonly blip
    /// unhealthy for well under a minute and self-heal; without hysteresis
    /// every blip paged the operator. A detector that recovers before this
    /// threshold elapses emits no alert at all; one that is still unhealthy
    /// once the threshold elapses emits exactly one alert for that episode.
    ///
    /// Default: `180` (3 minutes). `0` is a valid value — it disables the
    /// delay entirely, restoring immediate-alert-on-transition behaviour.
    /// `u64` so there is no negative value to guard against.
    pub motion_unhealthy_alert_secs: u64,
}

/// Hardware acceleration backend for motion sub-stream decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HwAccel {
    /// NVDEC via `ffmpeg -hwaccel cuda`.
    Cuda,
    /// VAAPI via `ffmpeg -hwaccel vaapi` — Intel/AMD integrated-GPU fixed-function
    /// decode (e.g. Intel Quick Sync). Often the most power-efficient option on a
    /// box with an iGPU: the media block lives on the already-powered CPU package,
    /// so it has none of a discrete card's fixed "wake-up" power cost. Requires the
    /// DRI render node ([`Config::motion_vaapi_device`], default
    /// `/dev/dri/renderD128`) mapped into the container with render-group access.
    Vaapi,
    /// Software (CPU) decode.
    Cpu,
    /// Probe at startup: use NVDEC when [`nvdec_available`] returns `true`,
    /// otherwise fall back to CPU.  This is the default and the correct choice
    /// for distributable deployments where GPU presence is unknown at image-build
    /// time.
    Auto,
}

impl HwAccel {
    fn from_str(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "cuda" => Some(Self::Cuda),
            "vaapi" => Some(Self::Vaapi),
            "cpu" => Some(Self::Cpu),
            "auto" => Some(Self::Auto),
            _ => None,
        }
    }

    /// Returns the ffmpeg `-hwaccel` argument value, or `None` for CPU.
    ///
    /// **Important:** callers MUST resolve [`HwAccel::Auto`] to `Cuda` or `Cpu`
    /// via [`nvdec_available`] BEFORE calling this method.  `Auto` is a
    /// configuration intent, not a runtime decision; `ffmpeg_flag` is only ever
    /// called on a fully-resolved `Cuda`/`Cpu` value after that probe.
    pub fn ffmpeg_flag(self) -> Option<&'static str> {
        match self {
            Self::Cuda => Some("cuda"),
            Self::Vaapi => Some("vaapi"),
            Self::Cpu => None,
            // Auto should be resolved before ffmpeg_flag is called.
            // Returning None (CPU) is the safe fallback if a caller forgets.
            Self::Auto => None,
        }
    }

    /// Canonical lowercase token for this backend (`"cuda"`/`"vaapi"`/`"cpu"`/
    /// `"auto"`). Used for change-detection fingerprints, logging, and the
    /// admin-editable `server_settings.motion_hwaccel` round-trip.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cuda => "cuda",
            Self::Vaapi => "vaapi",
            Self::Cpu => "cpu",
            Self::Auto => "auto",
        }
    }

    /// Resolve an admin-supplied setting string into a backend, falling back to
    /// `default` when the value is empty or unrecognised.
    ///
    /// This is how the recorder reconciles the DB-backed (admin-editable)
    /// `server_settings.motion_hwaccel` with the env-configured default: an empty
    /// or bad DB value means "inherit the env default", never a hard failure.
    #[must_use]
    pub fn from_setting(s: &str, default: Self) -> Self {
        Self::from_str(s).unwrap_or(default)
    }
}

/// Probe whether NVDEC (cuda hwaccel) is actually usable in THIS
/// process/container.
///
/// Runs `ffmpeg -hide_banner -hwaccels` and checks whether the output contains
/// the string `cuda`.  The result is cached in a [`OnceLock`] so repeated calls
/// are free after the first probe.
///
/// Returns `false` when:
/// - `ffmpeg` is not on `PATH` (spawn error),
/// - the process exits with a non-zero status,
/// - the output does not mention `cuda`.
///
/// The cheap `-hwaccels` probe reports *built-in* support rather than *runtime*
/// usability (a host can list cuda but lack the driver/device).  A false-positive
/// causes motion to attempt cuda; the per-camera ffmpeg will then fail and the
/// existing NVDEC semaphore/EOF watchdog recovers to CPU.  See Risk R5 in the
/// distributability spec; escalate to the `-init_hw_device cuda` probe only if
/// false-positives are observed.
///
/// # Examples
///
/// ```no_run
/// use crumb_common::config::nvdec_available;
/// if nvdec_available() {
///     println!("NVDEC is available; using cuda hwaccel");
/// } else {
///     println!("No NVDEC; using CPU decode");
/// }
/// ```
pub fn nvdec_available() -> bool {
    static CACHE: OnceLock<bool> = OnceLock::new();
    *CACHE.get_or_init(|| {
        match std::process::Command::new("ffmpeg")
            .args(["-hide_banner", "-hwaccels"])
            .output()
        {
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let stderr = String::from_utf8_lossy(&output.stderr);
                // ffmpeg -hwaccels may print to stdout or stderr depending on version.
                let has_cuda = stdout.contains("cuda") || stderr.contains("cuda");
                tracing::debug!(
                    has_cuda,
                    ffmpeg_hwaccels_stdout = %stdout.trim(),
                    "NVDEC probe complete"
                );
                has_cuda
            }
            Err(e) => {
                tracing::debug!(error = %e, "NVDEC probe: ffmpeg not found or spawn failed; assuming CPU");
                false
            }
        }
    })
}

impl Config {
    /// Read configuration from the process environment.
    ///
    /// Returns an error if any required variable is missing or a value cannot
    /// be parsed.
    ///
    /// # Errors
    ///
    /// Returns [`anyhow::Error`] with context describing which variable failed.
    pub fn from_env() -> Result<Self> {
        // DATABASE_URL is a secret (embeds the DB password) → support the
        // `_FILE` convention so it can come from a Docker secret instead of
        // plaintext .env (audit Risk #9). Falls back to the plain env var.
        let database_url = require_secret("DATABASE_URL")?;

        // Empty default: the recorder resolves the real value from server_settings
        // (the DB-backed singleton updated via the admin UI).  This env var is a
        // fallback only; no homelab IPs are baked into the binary.
        let go2rtc_rtsp_base = optional_env("GO2RTC_RTSP_BASE", "");

        // Crumb-owned go2rtc RTSP base (distinct from Frigate's embedded instance).
        // Also empty by default — must be set per deployment; no homelab IP baked in.
        let crumb_go2rtc_rtsp_base = optional_env("CRUMB_GO2RTC_RTSP_BASE", "");

        let segment_seconds: u32 = parse_env("SEGMENT_SECONDS", 4)?;
        anyhow::ensure!(
            (2..=6).contains(&segment_seconds),
            "SEGMENT_SECONDS must be in [2, 6], got {segment_seconds}"
        );

        // Default is "auto" so a fresh install works on both GPU and CPU hosts
        // without any env configuration.  "cuda" and "cpu" are explicit overrides.
        let hwaccel_str = optional_env("MOTION_HWACCEL", "auto");
        let motion_hwaccel = HwAccel::from_str(&hwaccel_str).with_context(|| {
            format!("MOTION_HWACCEL must be 'cuda', 'vaapi', 'cpu', or 'auto', got '{hwaccel_str}'")
        })?;

        Ok(Self {
            database_url,
            db_pool_size: parse_env("DB_POOL_SIZE", 32)?,
            go2rtc_rtsp_base,
            crumb_go2rtc_rtsp_base,
            go2rtc_user: {
                let v = optional_env("GO2RTC_USER", "");
                if v.is_empty() {
                    tracing::warn!(
                        "GO2RTC_USER is unset — RTSP connections to Crumb's own go2rtc will be \
                         unauthenticated and fail once go2rtc.yaml's RTSP auth is enabled \
                         (docker-compose.yml normally requires this var; only a non-compose \
                         deployment or a test harness should ever see this)"
                    );
                }
                v
            },
            go2rtc_pass: optional_env("GO2RTC_PASS", ""),
            segment_seconds,
            live_storage_path: optional_env("LIVE_STORAGE_PATH", "/data/live"),
            live_storage_name: optional_env("LIVE_STORAGE_NAME", "NVMe-Live"),
            archive_storage_path: optional_env("ARCHIVE_STORAGE_PATH", "/data/archive"),
            archive_storage_name: optional_env("ARCHIVE_STORAGE_NAME", "Bulk-Archive"),
            // RECORDER_TZ wins; otherwise inherit the container's TZ (compose
            // forwards it, and setup-env.sh sets it to the host zone) so a
            // non-US operator's archive/retention cron matches their wall clock.
            // UTC only if neither is set (bare-metal with no TZ at all) — matches
            // the documented .env.example contract ("if unset the default is UTC,
            // NOT any local zone"). (#228)
            archive_cron_tz: parse_tz_env("RECORDER_TZ", &optional_env("TZ", "UTC")),
            motion_hwaccel,
            motion_vaapi_device: optional_env("MOTION_VAAPI_DEVICE", "/dev/dri/renderD128"),
            max_gpu_decode_sessions: parse_env("MAX_GPU_DECODE_SESSIONS", 4)?,
            config_poll_seconds: parse_env("CONFIG_POLL_SECONDS", 30)?,
            reconcile_interval_seconds: parse_env("RECONCILE_INTERVAL_SECONDS", 900)?,
            reconcile_paused: parse_bool_env("RECONCILE_PAUSED", false)?,
            seed_admin_username: optional_env("SEED_ADMIN_USERNAME", "admin"),
            seed_admin_password_hash: optional_env("SEED_ADMIN_PASSWORD_HASH", ""),
            motion_cache_dir: optional_env("MOTION_CACHE_DIR", "/cache/motion"),
            motion_recording_shadow: parse_bool_env("MOTION_RECORDING_SHADOW", false)?,
            motion_unhealthy_alert_secs: parse_env("MOTION_UNHEALTHY_ALERT_SECS", 180)?,
        })
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Read a secret from `{key}_FILE` (a file path — e.g. a Docker secret mounted
/// at `/run/secrets/...`) if set and non-empty, otherwise from `{key}`. The
/// `_FILE` form keeps secrets out of the process environment and plaintext
/// `.env` (audit Risk #9). Returns `None` if neither is set.
pub fn secret_env(key: &str) -> Option<String> {
    if let Ok(path) = env::var(format!("{key}_FILE")) {
        let path = path.trim();
        if !path.is_empty() {
            if let Ok(contents) = std::fs::read_to_string(path) {
                return Some(contents.trim().to_owned());
            }
            // A configured _FILE that can't be read is a hard misconfig; fall
            // through to the plain var so startup can still surface a clear error.
        }
    }
    env::var(key).ok().filter(|v| !v.is_empty())
}

/// Like [`secret_env`] but errors if the secret is absent from both sources.
fn require_secret(key: &str) -> Result<String> {
    secret_env(key).with_context(|| format!("required secret '{key}' (or '{key}_FILE') is not set"))
}

/// Parse an IANA timezone from `key`, falling back to `default` (and to
/// `UTC` if even that fails to parse).
///
/// The fallback is deliberately non-fatal — a typo'd `RECORDER_TZ` must not
/// stop the recorder from booting — but it must be LOUD: silently swallowing
/// it runs the archive cron in the wrong timezone with no clue why (audit
/// #84).
fn parse_tz_env(key: &str, default: &str) -> chrono_tz::Tz {
    // An env var set to an empty string (compose forwards keys as `${VAR:-}`, so
    // an unset key still materializes as "") means "not configured": use the
    // default, don't treat "" as an invalid-zone error. (#228/#229)
    let raw = optional_env(key, default);
    let raw = if raw.trim().is_empty() {
        default.to_owned()
    } else {
        raw
    };
    match raw.parse::<chrono_tz::Tz>() {
        Ok(tz) => tz,
        Err(_) => {
            let fallback = default
                .parse::<chrono_tz::Tz>()
                .unwrap_or(chrono_tz::Tz::UTC);
            tracing::error!(
                "env var '{key}' = '{raw}' is not a valid IANA timezone \
                 (e.g. 'America/Los_Angeles'); falling back to '{fallback}' — \
                 the archive cron will run in that zone"
            );
            fallback
        }
    }
}

fn optional_env(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_owned())
}

fn parse_env<T>(key: &str, default: T) -> Result<T>
where
    T: std::str::FromStr + std::fmt::Display,
    T::Err: std::fmt::Display,
{
    match env::var(key) {
        // Empty (or whitespace-only) means "not configured": compose forwards
        // keys as `${VAR:-}`, so an unset key still arrives as "". Treat it as
        // the default rather than a fatal parse error that would fail boot.
        // (#229; mirrors parse_bool_env's empty handling.)
        Ok(val) if val.trim().is_empty() => Ok(default),
        Ok(val) => val
            .parse::<T>()
            .map_err(|e| anyhow::anyhow!("env var '{key}' = '{val}' could not be parsed: {e}")),
        Err(_) => Ok(default),
    }
}

/// Parse a boolean env var LENIENTLY: accepts `1`/`0`, `true`/`false`, `yes`/`no`,
/// `on`/`off` (case-insensitive). Empty or unset → `default`.
///
/// The env-var UX, `.env.example`, `setup-env.sh`, and the compose defaults all
/// use the `=1` / `=0` convention (e.g. `MOTION_RECORDING_SHADOW=0`). Rust's
/// `bool::from_str` only accepts `true`/`false`, so parsing those with the generic
/// [`parse_env`] crashes the recorder on every fresh install. This helper matches
/// the documented convention instead.
fn parse_bool_env(key: &str, default: bool) -> Result<bool> {
    match env::var(key) {
        Ok(val) => {
            let v = val.trim();
            if v.is_empty() {
                return Ok(default);
            }
            match v.to_ascii_lowercase().as_str() {
                "1" | "true" | "yes" | "on" => Ok(true),
                "0" | "false" | "no" | "off" => Ok(false),
                other => Err(anyhow::anyhow!(
                    "env var '{key}' = '{other}' is not a boolean (use 1/0, true/false, yes/no, or on/off)"
                )),
            }
        }
        Err(_) => Ok(default),
    }
}

#[cfg(test)]
mod tests {
    use super::{optional_env, parse_env, parse_tz_env};

    /// Audit #84: an invalid TZ value must fall back (non-fatal, now loudly
    /// logged) to the caller's default when that parses — never panic, never
    /// silently pick a surprise zone.
    #[test]
    fn parse_tz_env_falls_back_on_invalid_value() {
        // Unique key name: the process env is shared across parallel tests.
        std::env::set_var("CRUMB_TEST_TZ_INVALID", "Not/AZone");
        assert_eq!(
            parse_tz_env("CRUMB_TEST_TZ_INVALID", "Europe/Berlin"),
            chrono_tz::Tz::Europe__Berlin,
            "an invalid env value must fall back to the caller's default"
        );
        std::env::remove_var("CRUMB_TEST_TZ_INVALID");
    }

    /// Control: a valid value parses, and an unset key yields the default.
    #[test]
    fn parse_tz_env_parses_valid_value_and_unset_default() {
        std::env::set_var("CRUMB_TEST_TZ_VALID", "Asia/Tokyo");
        assert_eq!(
            parse_tz_env("CRUMB_TEST_TZ_VALID", "America/Los_Angeles"),
            chrono_tz::Tz::Asia__Tokyo
        );
        std::env::remove_var("CRUMB_TEST_TZ_VALID");
        assert_eq!(
            parse_tz_env("CRUMB_TEST_TZ_UNSET", "America/Los_Angeles"),
            chrono_tz::Tz::America__Los_Angeles
        );
    }

    /// #229: compose forwards keys as `${VAR:-}`, so an unset key arrives as an
    /// empty string. parse_env must treat that as "use the default", not a fatal
    /// parse error that would fail boot.
    #[test]
    fn parse_env_treats_empty_as_default() {
        std::env::set_var("CRUMB_TEST_EMPTY_NUM", "");
        assert_eq!(
            parse_env::<u32>("CRUMB_TEST_EMPTY_NUM", 32).unwrap(),
            32,
            "an empty env value must fall back to the default, not error"
        );
        std::env::set_var("CRUMB_TEST_WS_NUM", "   ");
        assert_eq!(
            parse_env::<u32>("CRUMB_TEST_WS_NUM", 32).unwrap(),
            32,
            "a whitespace-only env value must fall back to the default"
        );
        std::env::set_var("CRUMB_TEST_SET_NUM", "8");
        assert_eq!(parse_env::<u32>("CRUMB_TEST_SET_NUM", 32).unwrap(), 8);
        std::env::remove_var("CRUMB_TEST_EMPTY_NUM");
        std::env::remove_var("CRUMB_TEST_WS_NUM");
        std::env::remove_var("CRUMB_TEST_SET_NUM");
    }

    /// #228: with RECORDER_TZ unset, the archive cron inherits TZ (this is how
    /// the recorder resolves it: `parse_tz_env("RECORDER_TZ", optional_env("TZ", …))`),
    /// and an empty RECORDER_TZ (the `${VAR:-}` case) is treated as unset.
    #[test]
    fn archive_tz_inherits_tz_when_recorder_tz_absent() {
        // RECORDER_TZ unset -> inherit TZ.
        std::env::set_var("CRUMB_TEST_TZ_INHERIT", "Europe/Berlin");
        assert_eq!(
            parse_tz_env(
                "CRUMB_TEST_RECORDER_TZ_UNSET",
                &optional_env("CRUMB_TEST_TZ_INHERIT", "America/Los_Angeles")
            ),
            chrono_tz::Tz::Europe__Berlin,
            "an unset RECORDER_TZ must inherit TZ"
        );
        // RECORDER_TZ present but empty -> still treated as unset, inherit TZ.
        std::env::set_var("CRUMB_TEST_RECORDER_TZ_EMPTY", "");
        assert_eq!(
            parse_tz_env(
                "CRUMB_TEST_RECORDER_TZ_EMPTY",
                &optional_env("CRUMB_TEST_TZ_INHERIT", "America/Los_Angeles")
            ),
            chrono_tz::Tz::Europe__Berlin,
            "an empty RECORDER_TZ must be treated as unset and inherit TZ"
        );
        std::env::remove_var("CRUMB_TEST_TZ_INHERIT");
        std::env::remove_var("CRUMB_TEST_RECORDER_TZ_EMPTY");
    }
}
