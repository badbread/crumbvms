// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shared application state passed to every axum handler via [`axum::extract::State`].
//!
//! `AppState` is cheaply `Clone`-able (`Arc` under the hood for the expensive
//! fields) and `Send + Sync + 'static` so it satisfies axum's handler bounds
//! automatically.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use dashmap::DashMap;
use deadpool_postgres::Pool;
use jsonwebtoken::{DecodingKey, EncodingKey};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::config::ApiConfig;
use crate::dto::ExportJob;

/// How long the in-memory revoked-`jti` set may be trusted before a background
/// re-read from the DB. A revoke performed on THIS process refreshes the set
/// synchronously (immediate effect); this TTL only bounds staleness for a
/// revoke performed by ANOTHER API replica sharing the same Postgres. Short so
/// "sign out all devices" from one replica takes effect everywhere within a few
/// seconds.
const REVOCATION_CACHE_TTL_SECS: i64 = 15;

/// Inner state, heap-allocated once and reference-counted.
struct Inner {
    /// Deadpool-postgres connection pool.  Shared with the recorder's schema.
    pool: Pool,

    /// Fully-resolved API configuration (env vars read once at startup).
    config: ApiConfig,

    /// JWT HMAC-SHA256 encoding key (derived from `JWT_SECRET`).
    jwt_encoding_key: EncodingKey,

    /// JWT HMAC-SHA256 decoding key (derived from `JWT_SECRET`).
    jwt_decoding_key: DecodingKey,

    /// In-memory export job tracker.
    ///
    /// Keys are [`Uuid`]s returned to the client at `POST /export`.  Values
    /// contain the current status + output file paths once complete.
    ///
    /// `DashMap` provides interior-mutable concurrent access without a `Mutex`.
    /// Jobs are cleaned up by the TTL sweeper task in `main.rs`.
    export_jobs: DashMap<Uuid, ExportJob>,

    /// Per-job cancellation tokens, keyed by export job id. `DELETE /export/:id`
    /// fires the token; the worker's `tokio::select!` interrupts the running
    /// ffmpeg (mid-encode), kills + reaps it, and marks the job `Cancelled`. The
    /// entry is removed when the job reaches any terminal state.
    export_cancels: DashMap<Uuid, CancellationToken>,

    /// Bounds concurrent DB checkouts held by the `/play/aligned` fan-out so a
    /// burst of multi-camera aligned-playback requests cannot starve the pool.
    /// Permit count = `config.playback_max_concurrency`.
    play_semaphore: Arc<Semaphore>,

    /// Bounds concurrent on-demand clip re-encodes (the Clips tab). Each
    /// uncached clip first-play is one libx264 ffmpeg; this caps the CPU spike
    /// when several viewers play at once. Permit count =
    /// `config.clip_gen_max_concurrency`.
    clip_gen_semaphore: Arc<Semaphore>,

    /// In-memory cache of permission [`Role`]s keyed by id. The `AuthUser`
    /// extractor resolves a token's `role_id` to its effective capabilities +
    /// cameras through this, so per-request auth costs no DB round-trip after the
    /// first. Cleared whenever a role is created/updated/deleted so admin edits
    /// take effect on the very next request (no re-login). Lazily populated on miss.
    roles_cache: DashMap<Uuid, crumb_common::types::Role>,

    /// In-memory set of REVOKED session `jti`s (P0-SESSIONS). The `AuthUser`
    /// extractor consults this (not the DB) on every request so revocation adds
    /// no per-request round-trip — the same "cache the DB truth, refresh on
    /// write" pattern as `roles_cache`. Presence ⇒ the token is dead. Populated
    /// from `sessions WHERE revoked_at IS NOT NULL AND not expired`, rebuilt
    /// synchronously on any revoke and lazily on a short TTL (see
    /// [`REVOCATION_CACHE_TTL_SECS`]) to pick up revokes from other replicas.
    /// `DashMap<_, ()>` used as a concurrent set (no `DashSet` dependency).
    revoked_jtis: DashMap<Uuid, ()>,

    /// Unix-seconds timestamp of the last successful `revoked_jtis` refresh.
    /// `0` ⇒ never loaded (forces an initial load on first auth). Compared
    /// against `REVOCATION_CACHE_TTL_SECS` to decide when to re-read.
    revoked_jtis_loaded_at: AtomicI64,

    /// Health-alert maintenance window (issue #46). Unix-seconds timestamp
    /// until which operational HEALTH/system alerts (camera offline, recorder
    /// down, low disk, Frigate disconnect, backup failed) are SUPPRESSED —
    /// still evaluated + logged by the watchdogs, but not dispatched to any
    /// notification channel. `0` ⇒ no window armed. Set via
    /// `POST /config/maintenance {minutes}` (admin), read every tick by the
    /// system-events dispatcher. In-memory (no migration): a maintenance
    /// window is inherently transient, so losing it on an API restart is the
    /// safe default (alerts resume, never silently stay suppressed).
    maintenance_until: Arc<AtomicI64>,
}

/// Cheaply-cloneable handle to shared API state.
///
/// # Usage in handlers
///
/// ```rust,no_run
/// use axum::extract::State;
/// use crumb_api::state::AppState;
///
/// async fn my_handler(State(state): State<AppState>) {
///     let pool = state.pool();
///     let cfg  = state.config();
/// }
/// ```
#[derive(Clone)]
pub struct AppState(Arc<Inner>);

impl AppState {
    /// Construct from a pool and config.  JWT keys are derived from
    /// `config.jwt_secret` using HMAC-SHA256.
    ///
    /// # Panics
    ///
    /// Panics if `config.jwt_secret` is empty (caught earlier by
    /// [`ApiConfig::from_env`] validation).
    pub fn new(pool: Pool, config: ApiConfig) -> Self {
        let encoding_key = EncodingKey::from_secret(config.jwt_secret.as_bytes());
        let decoding_key = DecodingKey::from_secret(config.jwt_secret.as_bytes());
        let play_semaphore = Arc::new(Semaphore::new(config.playback_max_concurrency));
        let clip_gen_semaphore = Arc::new(Semaphore::new(config.clip_gen_max_concurrency));

        // Health-alert maintenance window (issue #46). Off by default; an
        // optional `MAINTENANCE_UNTIL` env (unix seconds) lets a deployment
        // pre-arm a window at boot (e.g. during a scripted cutover) without an
        // admin API call. A past/zero/unparseable value means "not armed".
        let maintenance_until = std::env::var("MAINTENANCE_UNTIL")
            .ok()
            .and_then(|v| v.trim().parse::<i64>().ok())
            .unwrap_or(0);

        Self(Arc::new(Inner {
            pool,
            config,
            jwt_encoding_key: encoding_key,
            jwt_decoding_key: decoding_key,
            export_jobs: DashMap::new(),
            export_cancels: DashMap::new(),
            play_semaphore,
            clip_gen_semaphore,
            roles_cache: DashMap::new(),
            revoked_jtis: DashMap::new(),
            revoked_jtis_loaded_at: AtomicI64::new(0),
            maintenance_until: Arc::new(AtomicI64::new(maintenance_until)),
        }))
    }

    /// Resolve a permission role by id, caching the result. Returns `None` if the
    /// role no longer exists. Used by the auth extractor on every request.
    pub async fn role_by_id(&self, role_id: Uuid) -> Option<crumb_common::types::Role> {
        if let Some(r) = self.0.roles_cache.get(&role_id) {
            return Some(r.clone());
        }
        match crumb_common::db::get_role(self.pool(), role_id).await {
            Ok(Some(role)) => {
                self.0.roles_cache.insert(role_id, role.clone());
                Some(role)
            }
            _ => None,
        }
    }

    /// Drop all cached roles so the next request re-reads from the DB. Call after
    /// any role create/update/delete so capability/camera edits apply immediately.
    #[inline]
    pub fn invalidate_roles_cache(&self) {
        self.0.roles_cache.clear();
    }

    // ── revocation cache (P0-SESSIONS) ────────────────────────────────────────

    /// Rebuild the in-memory revoked-`jti` set from the DB. Called synchronously
    /// after any revoke (so it takes effect on THIS process's very next request)
    /// and lazily by [`Self::is_jti_revoked`] when the TTL lapses.
    ///
    /// Failure to read is logged and left as-is (fail-closed would lock everyone
    /// out on a transient DB blip; the DB is the source of truth and the next
    /// refresh retries). Returns `Ok(())` even on a query error after logging.
    pub async fn refresh_revoked_jtis(&self) {
        match crumb_common::db::list_revoked_jtis(self.pool()).await {
            Ok(jtis) => {
                self.0.revoked_jtis.clear();
                for jti in jtis {
                    self.0.revoked_jtis.insert(jti, ());
                }
                self.0
                    .revoked_jtis_loaded_at
                    .store(chrono::Utc::now().timestamp(), Ordering::Relaxed);
            }
            Err(e) => {
                tracing::warn!("failed to refresh revoked-jti cache: {e}");
            }
        }
    }

    /// Whether `jti` has been revoked. Refreshes the cache from the DB first if
    /// it has never been loaded or the short TTL has lapsed (to observe revokes
    /// made by another API replica). On the hot path — after the initial load
    /// and within the TTL — this is a lock-free `DashMap` lookup, no DB I/O.
    pub async fn is_jti_revoked(&self, jti: Uuid) -> bool {
        let now = chrono::Utc::now().timestamp();
        let loaded_at = self.0.revoked_jtis_loaded_at.load(Ordering::Relaxed);
        if loaded_at == 0 || now - loaded_at >= REVOCATION_CACHE_TTL_SECS {
            self.refresh_revoked_jtis().await;
        }
        self.0.revoked_jtis.contains_key(&jti)
    }

    /// Borrow the database connection pool.
    #[inline]
    pub fn pool(&self) -> &Pool {
        &self.0.pool
    }

    /// Borrow the resolved API configuration.
    #[inline]
    pub fn config(&self) -> &ApiConfig {
        &self.0.config
    }

    /// Borrow the JWT encoding key (for `POST /auth/login`).
    #[inline]
    pub fn jwt_encoding_key(&self) -> &EncodingKey {
        &self.0.jwt_encoding_key
    }

    /// Borrow the JWT decoding key (for the auth middleware extractor).
    #[inline]
    pub fn jwt_decoding_key(&self) -> &DecodingKey {
        &self.0.jwt_decoding_key
    }

    /// Borrow the export job map.
    #[inline]
    pub fn export_jobs(&self) -> &DashMap<Uuid, ExportJob> {
        &self.0.export_jobs
    }

    /// Borrow the per-job cancellation-token map (see [`Inner::export_cancels`]).
    #[inline]
    pub fn export_cancels(&self) -> &DashMap<Uuid, CancellationToken> {
        &self.0.export_cancels
    }

    /// Clone the playback concurrency semaphore handle (cheap `Arc` clone).
    /// Used by `/play/aligned` to cap concurrent pool checkouts.
    #[inline]
    pub fn play_semaphore(&self) -> Arc<Semaphore> {
        Arc::clone(&self.0.play_semaphore)
    }

    /// Clone the clip-generation concurrency semaphore handle (cheap `Arc`
    /// clone). Used by the Clips media handler to cap concurrent ffmpeg
    /// re-encodes.
    #[inline]
    pub fn clip_gen_semaphore(&self) -> Arc<Semaphore> {
        Arc::clone(&self.0.clip_gen_semaphore)
    }

    // ── health-alert maintenance window (issue #46) ───────────────────────────

    /// Clone the shared maintenance-window handle (cheap `Arc` clone). Passed
    /// to the notification engine so its system-events dispatcher can consult
    /// the window every tick without borrowing the whole `AppState`.
    #[inline]
    pub fn maintenance_handle(&self) -> Arc<AtomicI64> {
        Arc::clone(&self.0.maintenance_until)
    }

    /// Arm (or, with `minutes == 0`, immediately clear) the health-alert
    /// maintenance window. Returns the resulting `maintenance_until` unix-seconds
    /// timestamp (`0` when cleared).
    pub fn arm_maintenance(&self, minutes: i64) -> i64 {
        let until = if minutes <= 0 {
            0
        } else {
            chrono::Utc::now().timestamp() + minutes.saturating_mul(60)
        };
        self.0.maintenance_until.store(until, Ordering::Relaxed);
        until
    }

    /// Current `maintenance_until` unix-seconds timestamp (`0` = not armed).
    /// Note this returns the raw stored value even if it is in the past — pass
    /// it to [`maintenance_active_at`] for the "is a window currently in effect"
    /// question (the handler's `MaintenanceStatus` and the engine's dispatcher
    /// both do exactly that).
    #[inline]
    pub fn maintenance_until(&self) -> i64 {
        self.0.maintenance_until.load(Ordering::Relaxed)
    }
}

/// Pure predicate for "is the maintenance window in effect at `now`": armed
/// (`until > 0`) and not yet expired (`now < until`). Factored out so the guard
/// logic is unit-testable without constructing an `AppState`.
#[inline]
pub fn maintenance_active_at(until: i64, now: i64) -> bool {
    until > 0 && now < until
}

#[cfg(test)]
mod tests {
    use super::maintenance_active_at;

    #[test]
    fn maintenance_off_when_unarmed() {
        // until == 0 => never active regardless of clock.
        assert!(!maintenance_active_at(0, 1_000));
        assert!(!maintenance_active_at(0, 0));
    }

    #[test]
    fn maintenance_active_within_window() {
        // now strictly before until => suppressed.
        assert!(maintenance_active_at(2_000, 1_999));
        assert!(maintenance_active_at(2_000, 0));
    }

    #[test]
    fn maintenance_expires_at_boundary() {
        // now == until (or past) => window over, alerts resume.
        assert!(!maintenance_active_at(2_000, 2_000));
        assert!(!maintenance_active_at(2_000, 2_001));
    }
}
