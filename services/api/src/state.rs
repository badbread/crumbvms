// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shared application state passed to every axum handler via [`axum::extract::State`].
//!
//! `AppState` is cheaply `Clone`-able (`Arc` under the hood for the expensive
//! fields) and `Send + Sync + 'static` so it satisfies axum's handler bounds
//! automatically.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

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

/// Consecutive failed logins for one username tolerated before the per-username
/// backoff engages (issue #127). Below this, every attempt is let through to the
/// normal credential check; at/above it, attempts are rejected with 429 until
/// the backoff elapses.
const LOGIN_FAIL_THRESHOLD: u32 = 5;

/// Base backoff (seconds) applied at the moment the threshold is first crossed;
/// it doubles for each additional failure (see [`login_backoff_secs`]).
const LOGIN_BACKOFF_BASE_SECS: u64 = 2;

/// Hard cap (seconds) on the per-username backoff — the exponential growth is
/// clamped here so a sustained attack settles at a fixed 15-minute block rather
/// than growing without bound.
const LOGIN_BACKOFF_CAP_SECS: u64 = 900;

/// Prune the login-failure map once it exceeds this many distinct usernames, so
/// an attacker spraying random usernames cannot grow it without bound. Only
/// entries no longer in backoff are dropped (an active block is always kept).
const LOGIN_FAILURES_MAX_ENTRIES: usize = 10_000;

/// Backoff duration (seconds) for `failures` consecutive login failures, or
/// `None` while still under [`LOGIN_FAIL_THRESHOLD`]. The engaged value is
/// `min(cap, base * 2^(failures - threshold))` — exponential, clamped. Pure and
/// clock-free so the backoff schedule is unit-testable in isolation.
fn login_backoff_secs(failures: u32) -> Option<u64> {
    if failures < LOGIN_FAIL_THRESHOLD {
        return None;
    }
    let steps = failures - LOGIN_FAIL_THRESHOLD;
    // `2^steps`, saturating: a very large failure count must not overflow the
    // shift (>=64 would be UB for `<<`); `checked_shl` yields None there.
    let factor = 1_u64.checked_shl(steps).unwrap_or(u64::MAX);
    let secs = LOGIN_BACKOFF_BASE_SECS.saturating_mul(factor);
    Some(secs.min(LOGIN_BACKOFF_CAP_SECS))
}

/// Per-username failed-login state for the brute-force backoff (issue #127).
#[derive(Clone, Copy)]
struct FailState {
    /// Consecutive failed logins since the last success/reset.
    failures: u32,
    /// Instant until which new attempts for this username are rejected. A value
    /// at/before `now` means "not currently blocked".
    blocked_until: Instant,
}

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

    /// Bounds concurrent on-demand thumbnail ffmpeg extractions (the filmstrip
    /// scrubber). A fast multi-camera scrub can miss the cache on many frames at
    /// once; without a cap each miss spawns a single-frame ffmpeg, a spawn storm.
    /// Permit count = `config.thumb_extract_max_concurrency`.
    thumb_semaphore: Arc<Semaphore>,

    /// Per-key in-flight locks for thumbnail extraction (singleflight). Keyed by
    /// the final cache path; a request serializes on its key so two concurrent
    /// misses on the same slot (e.g. the Phase 1 background writer racing an
    /// on-demand request) extract once instead of both spawning ffmpeg.
    thumb_inflight: DashMap<std::path::PathBuf, Arc<tokio::sync::Mutex<()>>>,

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

    /// Per-username failed-login tracker for the brute-force backoff (issue
    /// #127). Keyed by the SUBMITTED username verbatim — applied identically
    /// whether or not that account exists, so it leaks no existence oracle. The
    /// login handler consults this BEFORE any DB lookup or password verify and
    /// rejects a blocked username with 429 + `Retry-After` (it never sleeps and
    /// holds the connection). Memory-only (no table/migration): a restart clears
    /// it, which only ever RELAXES the limit — the fail-open direction, so lost
    /// state can never lock a legitimate user out. This is IN ADDITION to the
    /// shared per-IP request bucket, not a replacement.
    login_failures: DashMap<String, FailState>,
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
        let thumb_semaphore = Arc::new(Semaphore::new(config.thumb_extract_max_concurrency));

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
            thumb_semaphore,
            thumb_inflight: DashMap::new(),
            roles_cache: DashMap::new(),
            revoked_jtis: DashMap::new(),
            revoked_jtis_loaded_at: AtomicI64::new(0),
            maintenance_until: Arc::new(AtomicI64::new(maintenance_until)),
            login_failures: DashMap::new(),
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

    /// Clone the thumbnail-extraction concurrency semaphore handle (cheap `Arc`
    /// clone). Used by the filmstrip handler to cap concurrent single-frame
    /// ffmpeg extractions during a scrub.
    #[inline]
    pub fn thumb_semaphore(&self) -> Arc<Semaphore> {
        Arc::clone(&self.0.thumb_semaphore)
    }

    /// Get (or create) the singleflight lock for a thumbnail cache key. Callers
    /// lock it around the "check file, else extract" sequence so concurrent
    /// misses on the same key extract exactly once.
    ///
    /// The map holds only transient per-key locks; if it grows large (many
    /// distinct on-demand thumbnails), it is cleared wholesale. Dropping an entry
    /// mid-flight at worst permits one redundant extraction (atomic writes keep
    /// that correct), never corruption.
    pub fn thumb_inflight_lock(&self, path: &std::path::Path) -> Arc<tokio::sync::Mutex<()>> {
        if self.0.thumb_inflight.len() > 8192 {
            self.0.thumb_inflight.clear();
        }
        self.0
            .thumb_inflight
            .entry(path.to_path_buf())
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone()
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

    // ── per-username login backoff (issue #127) ───────────────────────────────

    /// If `username` is currently within its failed-login backoff window, return
    /// `Some(retry_after_secs)` (always ≥ 1 while blocked); otherwise `None`.
    /// The login handler calls this FIRST and, on `Some`, rejects with 429 +
    /// `Retry-After` before any DB lookup or password verification.
    pub fn login_retry_after(&self, username: &str) -> Option<u64> {
        let now = Instant::now();
        let st = self.0.login_failures.get(username)?;
        if st.blocked_until <= now {
            return None;
        }
        // Round any sub-second remainder up to 1 so a still-blocked attempt never
        // advertises `Retry-After: 0`.
        Some(
            st.blocked_until
                .saturating_duration_since(now)
                .as_secs()
                .max(1),
        )
    }

    /// Record one failed login for `username`, incrementing its consecutive
    /// failure count and (once past the threshold) stamping/extending the
    /// backoff window. Cheap, synchronous, lock-free per entry.
    pub fn record_login_failure(&self, username: &str) {
        let now = Instant::now();

        // Bound memory against username-spray: once large, drop entries that are
        // no longer blocked (an active block is always retained).
        if self.0.login_failures.len() > LOGIN_FAILURES_MAX_ENTRIES {
            self.0.login_failures.retain(|_, st| st.blocked_until > now);
        }

        let fresh = FailState {
            failures: 0,
            blocked_until: now,
        };
        let mut entry = self
            .0
            .login_failures
            .entry(username.to_owned())
            .or_insert(fresh);
        entry.failures = entry.failures.saturating_add(1);
        if let Some(secs) = login_backoff_secs(entry.failures) {
            entry.blocked_until = now + Duration::from_secs(secs);
        }
    }

    /// Clear any failed-login state for `username` after a successful login, so
    /// a legitimate user who eventually gets their password right resets the
    /// counter (and their next fat-finger starts from zero again).
    pub fn record_login_success(&self, username: &str) {
        self.0.login_failures.remove(username);
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
    use super::{
        login_backoff_secs, maintenance_active_at, LOGIN_BACKOFF_BASE_SECS, LOGIN_BACKOFF_CAP_SECS,
        LOGIN_FAIL_THRESHOLD,
    };

    #[test]
    fn login_backoff_none_below_threshold() {
        for f in 0..LOGIN_FAIL_THRESHOLD {
            assert_eq!(login_backoff_secs(f), None, "no backoff under threshold");
        }
    }

    #[test]
    fn login_backoff_exponential_then_capped() {
        // At the threshold the block is exactly the base; each further failure
        // doubles it, up to the hard cap.
        assert_eq!(
            login_backoff_secs(LOGIN_FAIL_THRESHOLD),
            Some(LOGIN_BACKOFF_BASE_SECS)
        );
        assert_eq!(
            login_backoff_secs(LOGIN_FAIL_THRESHOLD + 1),
            Some(LOGIN_BACKOFF_BASE_SECS * 2)
        );
        assert_eq!(
            login_backoff_secs(LOGIN_FAIL_THRESHOLD + 2),
            Some(LOGIN_BACKOFF_BASE_SECS * 4)
        );
        // A large failure count saturates at the cap, never overflows the shift.
        assert_eq!(
            login_backoff_secs(LOGIN_FAIL_THRESHOLD + 200),
            Some(LOGIN_BACKOFF_CAP_SECS)
        );
        assert_eq!(login_backoff_secs(u32::MAX), Some(LOGIN_BACKOFF_CAP_SECS));
    }

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
