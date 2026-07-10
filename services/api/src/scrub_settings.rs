// SPDX-License-Identifier: AGPL-3.0-or-later

//! Effective scrub-preview runtime tunables (issue #10).
//!
//! Five of the `THUMB_PREGEN_*` / `THUMB_CACHE_*` knobs move to admin-console
//! overrides (migration 0046, nullable `server_settings` columns): the DB
//! value wins when set, `NULL` (never touched) falls back to the env default
//! in `ApiConfig`. This mirrors `services/api/src/updates.rs::resolve_enabled`
//! exactly.
//!
//! `THUMB_PREGEN_WIDTH` stays env-only (ratified maintainer decision D1,
//! issue #10): it is part of the thumbnail cache key, and a console width
//! that drifted from the playback clients' fixed scrub-still width (480)
//! would make every pre-generated file a cache key nobody requests — the
//! pregen CPU and storage would be silently wasted while scrubbing quietly
//! degraded to on-demand extraction. See `docs/DECISIONS.md`.
//!
//! Both background consumers ([`crate::thumb_pregen`]'s worker and the
//! thumbnail-cache sweeper in `main.rs::export_ttl_sweeper`) call [`resolve`]
//! once per cycle rather than reading the boot-time `ApiConfig` snapshot, so
//! an admin-console change takes effect within one tick without a restart
//! (D2, `docs/SCRUB-PREGEN-TUNABLES-PLAN.md` §3).

use deadpool_postgres::Pool;

use crumb_common::db::ScrubPregenOverrides;

use crate::config::ApiConfig;

/// Effective scrub-preview settings for one cycle: the admin-console DB
/// override when set, else the matching `THUMB_*` env default. Every field is
/// re-clamped to the same bounds the console setters enforce (defense in
/// depth against a hand-edited row).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScrubSettings {
    pub pregen_enabled: bool,
    pub pregen_lookback_hours: i64,
    pub pregen_scan_secs: u64,
    pub cache_max_bytes: u64,
    pub cache_ttl_seconds: u64,
    // Width stays `ApiConfig`-only (D1) — not part of this struct; callers
    // that need it read `cfg.thumb_pregen_width` directly.
}

impl ScrubSettings {
    /// The env-only settings, used as the very first cycle's "last-known"
    /// value before any resolve has ever succeeded, and as the sweeper's
    /// fallback on a resolve failure with no prior successful resolve.
    pub(crate) fn from_env(cfg: &ApiConfig) -> Self {
        EnvDefaults::from_config(cfg).into_settings()
    }
}

/// The env-config side of the precedence merge, split out from [`ApiConfig`]
/// so [`merge`] is unit-testable without booting a full `ApiConfig` (which
/// requires `JWT_SECRET`/`GO2RTC_*` env vars via `ApiConfig::from_env`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct EnvDefaults {
    pregen_enabled: bool,
    pregen_lookback_hours: i64,
    pregen_scan_secs: u64,
    cache_max_bytes: u64,
    cache_ttl_seconds: u64,
}

impl EnvDefaults {
    pub(crate) fn from_config(cfg: &ApiConfig) -> Self {
        Self {
            pregen_enabled: cfg.thumb_pregen_enabled,
            pregen_lookback_hours: cfg.thumb_pregen_lookback_hours,
            pregen_scan_secs: cfg.thumb_pregen_scan_secs,
            cache_max_bytes: cfg.thumb_cache_max_bytes,
            cache_ttl_seconds: cfg.thumb_cache_ttl_seconds,
        }
    }

    fn into_settings(self) -> ScrubSettings {
        ScrubSettings {
            pregen_enabled: self.pregen_enabled,
            pregen_lookback_hours: self.pregen_lookback_hours,
            pregen_scan_secs: self.pregen_scan_secs,
            cache_max_bytes: self.cache_max_bytes,
            cache_ttl_seconds: self.cache_ttl_seconds,
        }
    }
}

/// Merge DB overrides over the env defaults, re-clamping every field to the
/// same bounds the console setters enforce. Pure — no DB, no `ApiConfig` —
/// so precedence + clamping are unit-tested directly (see `tests` below).
pub(crate) fn merge(overrides: ScrubPregenOverrides, env: EnvDefaults) -> ScrubSettings {
    let pregen_lookback_hours = overrides
        .pregen_lookback_hours
        .unwrap_or(env.pregen_lookback_hours)
        .clamp(0, 168);
    let pregen_scan_secs = overrides
        .pregen_scan_secs
        .map_or(env.pregen_scan_secs, |v| {
            u64::try_from(v.clamp(5, 3600)).unwrap_or(60)
        });
    let cache_max_bytes = overrides.cache_max_bytes.map_or(env.cache_max_bytes, |v| {
        u64::try_from(v.max(104_857_600)).unwrap_or(env.cache_max_bytes)
    });
    let cache_ttl_seconds = overrides
        .cache_ttl_seconds
        .map_or(env.cache_ttl_seconds, |v| {
            u64::try_from(v.clamp(3600, 31_536_000)).unwrap_or(2_592_000)
        });

    ScrubSettings {
        pregen_enabled: overrides.pregen_enabled.unwrap_or(env.pregen_enabled),
        pregen_lookback_hours,
        pregen_scan_secs,
        cache_max_bytes,
        cache_ttl_seconds,
    }
}

/// Resolve the effective scrub-preview settings for this cycle: one
/// `server_settings` read + per-field `unwrap_or(env default)`.
///
/// # Errors
///
/// Propagates the underlying DB error. Callers (the pre-gen worker, the
/// cache sweeper) treat a resolve failure as "keep the last-known settings"
/// and log a `warn!` rather than aborting — both are best-effort background
/// loops, and a transient DB blip must never kill either of them.
pub async fn resolve(pool: &Pool, cfg: &ApiConfig) -> anyhow::Result<ScrubSettings> {
    let overrides = crumb_common::db::get_scrub_pregen_settings(pool).await?;
    Ok(merge(overrides, EnvDefaults::from_config(cfg)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> EnvDefaults {
        EnvDefaults {
            pregen_enabled: false,
            pregen_lookback_hours: 2,
            pregen_scan_secs: 60,
            cache_max_bytes: 21_474_836_480,
            cache_ttl_seconds: 2_592_000,
        }
    }

    #[test]
    fn null_overrides_fall_back_to_env_for_every_field() {
        let settings = merge(ScrubPregenOverrides::default(), env());
        assert_eq!(settings.pregen_enabled, env().pregen_enabled);
        assert_eq!(settings.pregen_lookback_hours, env().pregen_lookback_hours);
        assert_eq!(settings.pregen_scan_secs, env().pregen_scan_secs);
        assert_eq!(settings.cache_max_bytes, env().cache_max_bytes);
        assert_eq!(settings.cache_ttl_seconds, env().cache_ttl_seconds);
    }

    #[test]
    fn db_set_value_wins_over_env_for_every_field() {
        let overrides = ScrubPregenOverrides {
            pregen_enabled: Some(true),
            pregen_lookback_hours: Some(10),
            pregen_scan_secs: Some(30),
            cache_max_bytes: Some(1_000_000_000),
            cache_ttl_seconds: Some(3600),
        };
        let settings = merge(overrides, env());
        assert!(settings.pregen_enabled);
        assert_eq!(settings.pregen_lookback_hours, 10);
        assert_eq!(settings.pregen_scan_secs, 30);
        assert_eq!(settings.cache_max_bytes, 1_000_000_000);
        assert_eq!(settings.cache_ttl_seconds, 3600);
    }

    #[test]
    fn partial_overrides_only_win_for_the_fields_actually_set() {
        // Only `pregen_enabled` was ever touched in the console — every other
        // field must still fall back to env.
        let overrides = ScrubPregenOverrides {
            pregen_enabled: Some(true),
            ..Default::default()
        };
        let settings = merge(overrides, env());
        assert!(settings.pregen_enabled);
        assert_eq!(settings.pregen_lookback_hours, env().pregen_lookback_hours);
        assert_eq!(settings.pregen_scan_secs, env().pregen_scan_secs);
        assert_eq!(settings.cache_max_bytes, env().cache_max_bytes);
        assert_eq!(settings.cache_ttl_seconds, env().cache_ttl_seconds);
    }

    #[test]
    fn hand_edited_out_of_bounds_db_row_comes_back_clamped() {
        // A hand-edited row (or a future downgrade) could hold a value outside
        // what the console setters would ever write — `merge` must re-clamp
        // defensively rather than trust the stored value verbatim.
        let overrides = ScrubPregenOverrides {
            pregen_enabled: None,
            pregen_lookback_hours: Some(-50),
            pregen_scan_secs: Some(1),
            cache_max_bytes: Some(0),
            cache_ttl_seconds: Some(1),
        };
        let settings = merge(overrides, env());
        assert_eq!(settings.pregen_lookback_hours, 0, "clamped to the 0 floor");
        assert_eq!(settings.pregen_scan_secs, 5, "clamped to the 5s floor");
        assert_eq!(
            settings.cache_max_bytes, 104_857_600,
            "clamped to the 100 MiB floor (D5)"
        );
        assert_eq!(settings.cache_ttl_seconds, 3600, "clamped to the 1h floor");

        let overrides_high = ScrubPregenOverrides {
            pregen_enabled: None,
            pregen_lookback_hours: Some(999),
            pregen_scan_secs: Some(999_999),
            cache_max_bytes: None,
            cache_ttl_seconds: Some(999_999_999),
        };
        let settings_high = merge(overrides_high, env());
        assert_eq!(
            settings_high.pregen_lookback_hours, 168,
            "clamped to the 168h ceiling"
        );
        assert_eq!(
            settings_high.pregen_scan_secs, 3600,
            "clamped to the 3600s ceiling"
        );
        assert_eq!(
            settings_high.cache_ttl_seconds, 31_536_000,
            "clamped to the 1-year ceiling"
        );
    }

    #[test]
    fn from_env_matches_the_config_fields_directly() {
        // Sanity check on `EnvDefaults`/`ScrubSettings` field wiring without
        // needing a full `ApiConfig::from_env()` boot.
        let e = env();
        let settings = e.into_settings();
        assert_eq!(settings.pregen_enabled, e.pregen_enabled);
        assert_eq!(settings.pregen_lookback_hours, e.pregen_lookback_hours);
        assert_eq!(settings.pregen_scan_secs, e.pregen_scan_secs);
        assert_eq!(settings.cache_max_bytes, e.cache_max_bytes);
        assert_eq!(settings.cache_ttl_seconds, e.cache_ttl_seconds);
    }
}
