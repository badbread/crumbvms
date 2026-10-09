// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shared application state passed to every axum handler via [`axum::extract::State`].
//!
//! `AppState` is cheaply `Clone`-able (`Arc` under the hood for the expensive
//! fields) and `Send + Sync + 'static` so it satisfies axum's handler bounds
//! automatically.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, OnceLock};
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

/// How long one `jti`'s resolved session state (does the row still exist, and
/// what per-user camera grants does its owner hold) may be trusted before it is
/// re-read from the DB. Unlike the revoked set, this cache is *positive*: an
/// unknown `jti` is resolved against the DB there and then, so a token minted a
/// millisecond ago on another API replica is never spuriously rejected. The TTL
/// therefore only bounds how long a change made by ANOTHER replica (a user
/// edit, an account removal) can go unnoticed here; a change made on THIS
/// process clears the cache synchronously.
const SESSION_CACHE_TTL_SECS: i64 = 30;

/// Cap on the session cache. One entry per `jti` seen recently, so this is
/// bounded by real sessions in normal use; the cap only matters if a caller
/// replays many distinct signed tokens. Cleared wholesale when exceeded (the
/// next request for each live session simply re-resolves).
const SESSION_CACHE_MAX_ENTRIES: usize = 10_000;

/// Consecutive failed logins for one account, from one client, tolerated before
/// the backoff engages (issue #127). Below this, every attempt is let through to
/// the normal credential check; at/above it, attempts are rejected with 429 until
/// the backoff elapses.
const LOGIN_FAIL_THRESHOLD: u32 = 5;

/// Base backoff (seconds) applied at the moment the threshold is first crossed;
/// it doubles for each additional failure (see [`login_backoff_secs`]).
const LOGIN_BACKOFF_BASE_SECS: u64 = 2;

/// Hard cap (seconds) on the backoff — the exponential growth is clamped here
/// so sustained guessing settles at a fixed 15-minute block rather than growing
/// without bound.
const LOGIN_BACKOFF_CAP_SECS: u64 = 900;

/// Prune the login-failure map once it exceeds this many distinct keys, so a
/// flood of random usernames (or clients) cannot grow it without bound. Only
/// entries no longer in backoff are dropped (an active block is always kept).
const LOGIN_FAILURES_MAX_ENTRIES: usize = 10_000;

/// Separator between the username and the client key in a login-failure map
/// key. ASCII unit separator: it cannot occur in a client key (an IP string)
/// and, being a control character, is not something a username can smuggle in
/// to collide with another account's bucket.
const LOGIN_KEY_SEP: char = '\u{1f}';

/// The login-failure map key for one (account, client) pair.
///
/// Keying on BOTH is what makes the backoff a per-client brake rather than an
/// account-wide one: repeated failures from one client no longer stop the
/// account's real owner signing in from their own machine. The per-client
/// request bucket in `rate_limit.rs` remains the global limiter on top.
fn login_key(username: &str, client: &str) -> String {
    format!("{username}{LOGIN_KEY_SEP}{client}")
}

/// Prune the console-handoff map once it exceeds this many outstanding codes.
/// Codes live for seconds and are consumed on first use, so a healthy install
/// holds a handful; the cap only bounds a pathological caller that mints codes
/// it never redeems. Only already-expired entries are dropped.
const HANDOFF_MAX_ENTRIES: usize = 1_000;

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

/// Account-wide ceiling: this many failed logins for one username, from any
/// mix of clients, within [`ACCOUNT_FAIL_WINDOW`] puts the whole account under
/// a backoff. One client cannot reach it on its own: its per-(account, client)
/// backoff (5 free attempts, then waits of 2, 4, 8, ... s) admits at most 13
/// failures in any 15 minutes, so 30 takes at least three client addresses
/// each failing as fast as their own backoff allows.
const ACCOUNT_FAIL_CEILING: usize = 30;

/// The sliding window [`ACCOUNT_FAIL_CEILING`] is counted over.
const ACCOUNT_FAIL_WINDOW: Duration = Duration::from_mins(15);

/// First account-wide backoff (seconds) once the ceiling is reached; it doubles
/// for every further failure while the account is under pressure, clamped to
/// [`LOGIN_BACKOFF_CAP_SECS`] (see [`account_backoff_secs`]).
const ACCOUNT_BACKOFF_BASE_SECS: u64 = 30;

/// An account under pressure returns to normal once this long passes with no
/// failed attempt (rejected 429s are not attempts). Twice the backoff cap, so
/// sitting out one capped block does not by itself reset the escalation.
const ACCOUNT_QUIET_RESET: Duration = Duration::from_mins(30);

/// Account-wide backoff (seconds) for the `strikes`-th failure recorded while
/// the account is over its ceiling (`strikes >= 1`):
/// `min(cap, base * 2^(strikes - 1))`. Pure, for unit testing.
fn account_backoff_secs(strikes: u32) -> u64 {
    let factor = 1_u64
        .checked_shl(strikes.saturating_sub(1))
        .unwrap_or(u64::MAX);
    ACCOUNT_BACKOFF_BASE_SECS
        .saturating_mul(factor)
        .min(LOGIN_BACKOFF_CAP_SECS)
}

/// Account-wide failed-login state for one username (all clients together).
struct AccountFailState {
    /// Times of the most recent failures, oldest first, at most
    /// [`ACCOUNT_FAIL_CEILING`] of them.
    recent: VecDeque<Instant>,
    /// Failures recorded while over the ceiling; drives the escalation. `0`
    /// means the account is not under pressure.
    strikes: u32,
    /// Instant until which every attempt on this account is rejected.
    blocked_until: Instant,
}

impl AccountFailState {
    fn last_failure(&self) -> Option<Instant> {
        self.recent.back().copied()
    }

    /// Whether the ceiling's worth of failures all fall inside the window.
    fn over_ceiling(&self) -> bool {
        self.recent.len() >= ACCOUNT_FAIL_CEILING
            && match (self.recent.front(), self.recent.back()) {
                (Some(first), Some(last)) => {
                    last.saturating_duration_since(*first) <= ACCOUNT_FAIL_WINDOW
                }
                _ => false,
            }
    }
}

/// Cached Home Assistant `/api/states` snapshot backing `GET /ha/states`
/// (issue #170). There is no standing poller: the handler refreshes on demand
/// when this is older than the TTL, so a wall with no HA badges (or no client
/// open) costs HA zero traffic. The `states` are the raw `/api/states` array
/// (shared behind an `Arc` so a caller clones the handle, not the payload, out
/// from under the lock); the per-caller RBAC projection happens after.
#[derive(Clone)]
pub struct HaStatesCache {
    /// When this snapshot was fetched from HA (monotonic).
    pub fetched_at: Instant,
    /// Raw HA `/api/states` array.
    pub states: Arc<Vec<serde_json::Value>>,
}

/// Failed-login state for one (account, client) pair (issue #127).
#[derive(Clone, Copy)]
struct FailState {
    /// Consecutive failed logins since the last success/reset.
    failures: u32,
    /// Instant until which new attempts for this pair are rejected. A value
    /// at/before `now` means "not currently blocked".
    blocked_until: Instant,
}

/// One outstanding console-handoff code (see [`AppState::issue_handoff_code`]).
#[derive(Clone, Copy)]
struct HandoffEntry {
    /// The user the code was minted for.
    user_id: Uuid,
    /// The `jti` of the session that asked for the code, when it has one
    /// (pre-P0-SESSIONS tokens do not). The exchange rejects a code whose
    /// originating session has since been signed out.
    jti: Option<Uuid>,
    /// Instant after which the code is no longer redeemable.
    expires_at: Instant,
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

    /// Bounds concurrent `GET /cameras/{id}/frame.jpg` fetches from go2rtc. The
    /// low-bandwidth walls on Android and iOS poll one still per tile per
    /// second, and a request against a camera that is down holds its slot for
    /// the whole retry ladder, so the proxy needs its own bound rather than an
    /// unbounded fan-out. Permit count = `config.frame_proxy_max_concurrency`.
    frame_semaphore: Arc<Semaphore>,

    /// Cameras whose live still could not be fetched recently. See
    /// [`FrameLatch`]. Memory-only and self-healing: a restart just means the
    /// first poll after it pays the full ladder again.
    frame_unavailable: FrameLatch,

    /// Per-key in-flight locks for thumbnail extraction (singleflight). Keyed by
    /// the final cache path; a request serializes on its key so two concurrent
    /// misses on the same slot (e.g. the Phase 1 background writer racing an
    /// on-demand request) extract once instead of both spawning ffmpeg.
    thumb_inflight: DashMap<std::path::PathBuf, Arc<tokio::sync::Mutex<()>>>,

    /// Per-key in-flight locks for clip-media generation (singleflight). Keyed by
    /// the final cache path; concurrent misses on the same clip serialize so it
    /// transcodes exactly once (the direct fix for the 2026-07-16 retry-storm
    /// incident, where each stalled retry spawned another full ffmpeg). Same
    /// pattern and lifecycle as `thumb_inflight`.
    clip_inflight: DashMap<std::path::PathBuf, Arc<tokio::sync::Mutex<()>>>,

    /// Serializes go2rtc reconcile passes against camera-stream teardown. A
    /// reconcile pass is additive (it PUTs every DB stream but never prunes), so
    /// a periodic pass that snapshots the camera list *before* a camera delete
    /// but applies its PUTs *after* the delete tore the stream down would
    /// resurrect the deleted camera's go2rtc stream permanently. `reconcile()`
    /// and `remove()` both hold this for their duration so the teardown can
    /// never interleave with a pass's read-then-apply. Low-frequency operations,
    /// so a single global lock is fine.
    go2rtc_reconcile_lock: Arc<tokio::sync::Mutex<()>>,

    /// Cameras (by `go2rtc_name`) whose SUB stream needs the video-only `_subv`
    /// repair — i.e. whose producer SDP advertises a video track with NO
    /// `a=fmtp` line, which Android's Media3 RTSP client rejects outright
    /// (#483). `DashMap<_, ()>` used as a concurrent set, exactly like
    /// [`revoked_jtis`](Inner::revoked_jtis).
    ///
    /// Written by the go2rtc reconcile pass (which reads every producer's SDP
    /// out of the `GET /api/streams` response it already fetches) and read by
    /// `playback.rs` to decide whether to advertise `rtsp_subv_url` for a
    /// camera. **Membership is the exception, not the rule:** on the reference
    /// install exactly one camera of eleven is affected, and every other camera
    /// keeps attaching to the always-warm raw `_sub`.
    ///
    /// In-memory with no migration, deliberately: this is a runtime-detectable
    /// property of the camera's current firmware/stream, not operator
    /// configuration, so a restart should re-derive it rather than trust a
    /// stale row. An empty set (cold start, before the first pass completes)
    /// means "nobody needs the repair", which is the safe direction: a client
    /// falls back to the raw sub and is no worse off than before #483.
    subv_needed: DashMap<String, ()>,

    /// Cameras (by `go2rtc_name`) whose MAIN stream needs the `_mainv` repair —
    /// the reconcile pass read the main producer's SDP out of `GET /api/streams`
    /// and found a video track with no `a=fmtp` (see `go2rtc::sdp_video_lacks_fmtp`).
    /// `DashMap<_, ()>` used as a concurrent set, exactly like
    /// [`subv_needed`](Inner::subv_needed), and sticky across an unknown verdict
    /// for the same reason. In-memory / no migration for the same reason too: it is
    /// a runtime property of go2rtc's current answer, not operator configuration.
    /// Only ever populated when `main_repair_transcode_enabled` is on; empty
    /// otherwise, so a client sees no `rtsp_mainv_url` and behaves exactly as
    /// before this feature.
    mainv_needed: DashMap<String, ()>,

    /// Cameras (by `go2rtc_name`) whose stream go2rtc is currently REJECTING —
    /// the reconcile pass tried to create the stream, go2rtc answered a
    /// non-success status, and a confirming `GET /api/streams` showed the
    /// stream is genuinely absent (issue #519). `DashMap<_, ()>` used as a
    /// concurrent set, exactly like [`subv_needed`](Inner::subv_needed).
    ///
    /// This is the state-transition latch for the `camera_stream_rejected`
    /// system event. The reconcile loop re-tries a rejected stream on every
    /// pass — as often as every `CHECK_INTERVAL` (~5 s), because a missing
    /// stream reads as a stream-count shortfall — so without a latch a
    /// permanently-bad source URL would write a `system_events` row (and fire a
    /// push) several times a minute, forever. Membership means "the operator
    /// has already been told about this one"; the entry is dropped the moment
    /// the stream applies cleanly, so a later regression alerts again.
    ///
    /// In-memory with no migration, deliberately, for the same reason as
    /// `subv_needed`: it is a runtime property of go2rtc's current answer, not
    /// operator configuration. A restart re-derives it, costing at most one
    /// repeat alert for a still-broken camera — the same trade-off the
    /// `camera_offline` watchdog latch already makes.
    stream_rejected: DashMap<String, ()>,

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

    /// In-memory cache of resolved session state, keyed by `jti`. The value is
    /// `(grants, checked_at_unix)` where `grants` is `Some(camera_ids)` for a
    /// session whose row still exists and is not revoked (carrying the owning
    /// user's per-user camera grants, read from the row rather than trusted from
    /// the token) and `None` for a session that is gone.
    ///
    /// This is the positive counterpart to `revoked_jtis`. That set answers "was
    /// this session signed out", which cannot answer "did this session's row
    /// ever exist" — a deleted user's rows vanish through
    /// `sessions.user_id ON DELETE CASCADE`, so their still-signed token read as
    /// "not revoked" and kept working. A `jti` missing from this cache is
    /// resolved against the DB on the spot (never assumed live and never assumed
    /// dead), so a token minted moments ago, here or on another replica, is
    /// accepted immediately; after that first resolution the check is a
    /// lock-free `DashMap` lookup. Entries are dropped wholesale whenever a user
    /// row changes (see [`AppState::invalidate_session_cache`]), the same
    /// refresh-on-write discipline `roles_cache` and `revoked_jtis` follow.
    session_cache: DashMap<Uuid, (Option<Vec<Uuid>>, i64)>,

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

    /// Account-wide failed-login ceiling, keyed on the submitted username alone
    /// (see [`ACCOUNT_FAIL_CEILING`]). The per-(account, client) counter above
    /// keeps one noisy client from locking the owner out; this one caps the
    /// total guessing rate against an account however many client addresses
    /// the attempts come from. Memory-only, same as `login_failures`.
    login_account_failures: DashMap<String, AccountFailState>,

    /// Which TCP peers may name the client in `X-Forwarded-For`
    /// (`TRUST_PROXY` + `TRUSTED_PROXIES`). Shared with the request limiter so
    /// both attribute a request to the same client.
    proxy_trust: Arc<crate::rate_limit::ProxyTrust>,
    /// Outstanding single-use console-handoff codes, keyed by the code itself.
    /// Memory-only and deliberately so: a code is valid for seconds, and losing
    /// the map on restart only means the operator clicks "Open in browser"
    /// again (the fail-safe direction).
    handoff_codes: DashMap<String, HandoffEntry>,

    /// Demand-driven cache behind `GET /ha/states` (issue #170). `None` until
    /// the first request. The `tokio::sync::Mutex` makes a refresh single-flight:
    /// concurrent callers on a stale cache collapse to one HA `/api/states`
    /// request (the others wait on the lock, then read the fresh snapshot).
    ha_states: tokio::sync::Mutex<Option<HaStatesCache>>,

    /// Sender half of the detection-event channel consumed by the
    /// `detection_ingester` task. Set once at startup (in `main.rs`, right after
    /// the channel is created) via [`AppState::set_event_tx`]. The `POST
    /// /lpr/reads` external-ingest handler clones it to push a `crumb-alpr`
    /// `NormalizedEvent` into the SAME pipeline Frigate uses, so all downstream
    /// plate logic (dedup, ignore-list, watchlist, alerts, timeline mirror) is
    /// reused verbatim. `OnceLock` avoids an `AppState::new` signature change
    /// (and the constructor runs before the channel exists).
    event_tx: OnceLock<tokio::sync::mpsc::Sender<crumb_common::NormalizedEvent>>,
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
        let frame_semaphore = Arc::new(Semaphore::new(config.frame_proxy_max_concurrency));

        // Health-alert maintenance window (issue #46). Off by default; an
        // optional `MAINTENANCE_UNTIL` env (unix seconds) lets a deployment
        // pre-arm a window at boot (e.g. during a scripted cutover) without an
        // admin API call. A past/zero/unparseable value means "not armed".
        let maintenance_until = std::env::var("MAINTENANCE_UNTIL")
            .ok()
            .and_then(|v| v.trim().parse::<i64>().ok())
            .unwrap_or(0);

        let proxy_trust = Arc::new(crate::rate_limit::ProxyTrust::new(
            config.trust_proxy,
            &config.trusted_proxies,
        ));

        Self(Arc::new(Inner {
            pool,
            config,
            jwt_encoding_key: encoding_key,
            jwt_decoding_key: decoding_key,
            export_jobs: DashMap::new(),
            export_cancels: DashMap::new(),
            play_semaphore,
            clip_gen_semaphore,
            clip_inflight: DashMap::new(),
            go2rtc_reconcile_lock: Arc::new(tokio::sync::Mutex::new(())),
            subv_needed: DashMap::new(),
            mainv_needed: DashMap::new(),
            stream_rejected: DashMap::new(),
            thumb_semaphore,
            frame_semaphore,
            frame_unavailable: FrameLatch::default(),
            thumb_inflight: DashMap::new(),
            roles_cache: DashMap::new(),
            revoked_jtis: DashMap::new(),
            revoked_jtis_loaded_at: AtomicI64::new(0),
            session_cache: DashMap::new(),
            maintenance_until: Arc::new(AtomicI64::new(maintenance_until)),
            login_failures: DashMap::new(),
            login_account_failures: DashMap::new(),
            proxy_trust,
            handoff_codes: DashMap::new(),
            ha_states: tokio::sync::Mutex::new(None),
            event_tx: OnceLock::new(),
        }))
    }

    /// Install the detection-event channel sender (once, at startup). Called from
    /// `main.rs` immediately after the channel is created and before the router
    /// starts serving, so the `POST /lpr/reads` handler always sees it set.
    /// A second call is ignored (returns the sender back) — the channel is
    /// created exactly once.
    pub fn set_event_tx(&self, tx: tokio::sync::mpsc::Sender<crumb_common::NormalizedEvent>) {
        let _ = self.0.event_tx.set(tx);
    }

    /// Borrow the detection-event channel sender, if installed. `None` only in
    /// the window before `main.rs` wires it (or in tests that never do), in which
    /// case the ingest handler returns `503`.
    #[inline]
    pub fn event_tx(&self) -> Option<&tokio::sync::mpsc::Sender<crumb_common::NormalizedEvent>> {
        self.0.event_tx.get()
    }

    /// Borrow the demand-driven HA `/api/states` cache (issue #170). The
    /// `GET /ha/states` handler locks it, refreshes on TTL expiry, and reads the
    /// snapshot back out; the lock serializes refreshes into a single HA request.
    #[inline]
    pub fn ha_states_cache(&self) -> &tokio::sync::Mutex<Option<HaStatesCache>> {
        &self.0.ha_states
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

    // ── session cache (liveness + per-user camera grants) ─────────────────────

    /// Resolve a session `jti` to the owning user's per-user camera grants, or
    /// `None` when the session no longer exists (removed account, pruned row, a
    /// `jti` that never had a row, or one belonging to a different user).
    ///
    /// Cached per `jti` for [`SESSION_CACHE_TTL_SECS`]; a miss costs exactly one
    /// query, so the common warm path adds no DB round trip. Both outcomes are
    /// cached, so a client looping on a dead token does not re-query every time.
    ///
    /// # Errors
    ///
    /// Propagates a DB failure rather than guessing. The caller turns that into
    /// a 5xx, never a 401: a transient database blip must not look like "you
    /// have been signed out" to a client that would then discard its token.
    pub async fn resolve_session(
        &self,
        jti: Uuid,
        user_id: Uuid,
    ) -> anyhow::Result<Option<Vec<Uuid>>> {
        let now = chrono::Utc::now().timestamp();
        if let Some(entry) = self.0.session_cache.get(&jti) {
            let (grants, checked_at) = entry.value();
            if now - *checked_at < SESSION_CACHE_TTL_SECS {
                return Ok(grants.clone());
            }
        }
        let grants = crumb_common::db::resolve_live_session(self.pool(), jti, user_id).await?;
        // Bound memory against a caller replaying many distinct signed tokens.
        if self.0.session_cache.len() > SESSION_CACHE_MAX_ENTRIES {
            self.0.session_cache.clear();
        }
        self.0.session_cache.insert(jti, (grants.clone(), now));
        Ok(grants)
    }

    /// Drop every cached session so the next request re-reads liveness and the
    /// per-user camera grants from the DB. Call after any change to a user row
    /// (edit, removal) or after revoking sessions, so the change lands on that
    /// user's very next request instead of waiting out the TTL.
    #[inline]
    pub fn invalidate_session_cache(&self) {
        self.0.session_cache.clear();
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

    /// Clone the live-still proxy concurrency semaphore handle (cheap `Arc`
    /// clone). Used by `GET /cameras/{id}/frame.jpg` to cap concurrent go2rtc
    /// still fetches.
    #[inline]
    pub fn frame_semaphore(&self) -> Arc<Semaphore> {
        Arc::clone(&self.0.frame_semaphore)
    }

    /// Decide how the still proxy should fetch `camera_id`'s live still. See
    /// [`FrameLatch::attempt_at`].
    #[inline]
    pub fn frame_attempt(&self, camera_id: Uuid, ttl: Duration) -> FrameAttempt {
        self.0
            .frame_unavailable
            .attempt_at(camera_id, ttl, Instant::now())
    }

    /// Latch `camera_id`'s live still as unavailable for `ttl`. Call it only
    /// when a FULL retry ladder exhausted its attempts, never from the
    /// single-attempt path (see [`FrameLatch`]).
    #[inline]
    pub fn mark_frame_unavailable(&self, camera_id: Uuid, ttl: Duration) {
        self.0
            .frame_unavailable
            .mark_at(camera_id, ttl, Instant::now());
    }

    /// Clear `camera_id`'s unavailable latch after a successful still fetch, so
    /// a camera that comes back is served the normal way on the next poll.
    #[inline]
    pub fn clear_frame_unavailable(&self, camera_id: Uuid) {
        self.0.frame_unavailable.clear(camera_id);
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

    /// Get (or create) the singleflight lock for a clip-media cache key. The
    /// Clips media handler locks it around the "check file, else generate"
    /// sequence so two concurrent misses on the same clip transcode exactly once
    /// (the second serves the file the first produced). Same map-clear +
    /// atomic-write correctness story as [`thumb_inflight_lock`].
    pub fn clip_inflight_lock(&self, path: &std::path::Path) -> Arc<tokio::sync::Mutex<()>> {
        if self.0.clip_inflight.len() > 8192 {
            self.0.clip_inflight.clear();
        }
        self.0
            .clip_inflight
            .entry(path.to_path_buf())
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone()
    }

    /// Clone the shared go2rtc reconcile/teardown lock. A go2rtc `reconcile()`
    /// pass and a stream `remove()` both hold this for their duration so a
    /// camera delete can never interleave with a pass's read-then-apply and
    /// resurrect the deleted camera's stream. See the field docs on
    /// [`go2rtc_reconcile_lock`](Inner::go2rtc_reconcile_lock).
    pub fn go2rtc_reconcile_lock(&self) -> Arc<tokio::sync::Mutex<()>> {
        Arc::clone(&self.0.go2rtc_reconcile_lock)
    }

    // ── `_subv` repair flags (#483 follow-up) ─────────────────────────────────

    /// Does this camera's sub stream need the video-only `_subv` repair? See the
    /// field docs on [`subv_needed`](Inner::subv_needed). `false` for anything
    /// the reconcile pass has not positively flagged, including a cold start.
    #[inline]
    pub fn subv_needed(&self, go2rtc_name: &str) -> bool {
        self.0.subv_needed.contains_key(go2rtc_name)
    }

    /// Record this pass's verdict for one camera. Idempotent, so the reconcile
    /// pass can call it unconditionally every time.
    pub fn set_subv_needed(&self, go2rtc_name: &str, needed: bool) {
        if needed {
            self.0.subv_needed.insert(go2rtc_name.to_owned(), ());
        } else {
            self.0.subv_needed.remove(go2rtc_name);
        }
    }

    /// Drop flags for cameras that no longer exist, so a deleted camera's entry
    /// cannot pin memory or resurface if its `go2rtc_name` is later reused.
    pub fn retain_subv_needed(&self, live: &std::collections::HashSet<String>) {
        self.0.subv_needed.retain(|name, ()| live.contains(name));
    }

    // ── `_mainv` repair flags (LPR H.265 main / missing-fmtp) ──────────────────

    /// Does this camera's MAIN stream need the `_mainv` repair transcode? See the
    /// field docs on [`mainv_needed`](Inner::mainv_needed). `false` for anything
    /// the reconcile pass has not positively flagged, including a cold start and
    /// every camera when `main_repair_transcode_enabled` is off.
    #[inline]
    pub fn mainv_needed(&self, go2rtc_name: &str) -> bool {
        self.0.mainv_needed.contains_key(go2rtc_name)
    }

    /// Record this pass's verdict for one camera. Idempotent, so the reconcile
    /// pass can call it unconditionally every time.
    pub fn set_mainv_needed(&self, go2rtc_name: &str, needed: bool) {
        if needed {
            self.0.mainv_needed.insert(go2rtc_name.to_owned(), ());
        } else {
            self.0.mainv_needed.remove(go2rtc_name);
        }
    }

    /// Drop flags for cameras that no longer exist, so a deleted camera's entry
    /// cannot pin memory or resurface if its `go2rtc_name` is later reused.
    pub fn retain_mainv_needed(&self, live: &std::collections::HashSet<String>) {
        self.0.mainv_needed.retain(|name, ()| live.contains(name));
    }

    // ── go2rtc stream-rejection latch (issue #519) ────────────────────────────

    /// Has the operator already been alerted that go2rtc is rejecting this
    /// camera's stream? See the field docs on
    /// [`stream_rejected`](Inner::stream_rejected).
    #[inline]
    pub fn stream_rejected(&self, go2rtc_name: &str) -> bool {
        self.0.stream_rejected.contains_key(go2rtc_name)
    }

    /// Record this pass's verdict for one camera. Idempotent, so the reconcile
    /// pass can call it unconditionally every time.
    pub fn set_stream_rejected(&self, go2rtc_name: &str, rejected: bool) {
        if rejected {
            self.0.stream_rejected.insert(go2rtc_name.to_owned(), ());
        } else {
            self.0.stream_rejected.remove(go2rtc_name);
        }
    }

    /// Drop latches for cameras that no longer exist, so a deleted camera's
    /// entry cannot pin memory or suppress a genuine alert if its
    /// `go2rtc_name` is later reused.
    pub fn retain_stream_rejected(&self, live: &std::collections::HashSet<String>) {
        self.0
            .stream_rejected
            .retain(|name, ()| live.contains(name));
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

    // ── login backoff, keyed on (account, client) (issue #127) ────────────────

    /// If this `username`/`client` pair is currently within its failed-login
    /// backoff window, return `Some(retry_after_secs)` (always ≥ 1 while
    /// blocked); otherwise `None`. The login handler calls this FIRST and, on
    /// `Some`, rejects with 429 + `Retry-After` before any DB lookup or password
    /// verification.
    ///
    /// `client` comes from `rate_limit::client_key`, so it honours `TRUST_PROXY`
    /// exactly as the request bucket does.
    ///
    /// Two brakes apply, and the longer wait wins: the (account, client) pair's
    /// own backoff, and the account-wide one that engages once the account
    /// passes [`ACCOUNT_FAIL_CEILING`] failures from any mix of clients.
    pub fn login_retry_after(&self, username: &str, client: &str) -> Option<u64> {
        let now = Instant::now();
        let pair = self
            .0
            .login_failures
            .get(&login_key(username, client))
            .map(|st| st.blocked_until);
        let account = self
            .0
            .login_account_failures
            .get(username)
            .map(|st| st.blocked_until);
        let until = pair.into_iter().chain(account).max()?;
        if until <= now {
            return None;
        }
        // Round any sub-second remainder up to 1 so a still-blocked attempt never
        // advertises `Retry-After: 0`.
        Some(until.saturating_duration_since(now).as_secs().max(1))
    }

    /// The shared client-attribution policy (`TRUST_PROXY` +
    /// `TRUSTED_PROXIES`). The login handler and the request limiter both
    /// derive the client through it.
    #[inline]
    pub fn proxy_trust(&self) -> &Arc<crate::rate_limit::ProxyTrust> {
        &self.0.proxy_trust
    }

    /// Record one failed login for the `username`/`client` pair, incrementing
    /// its consecutive failure count and (once past the threshold)
    /// stamping/extending the backoff window. Cheap, synchronous, lock-free per
    /// entry.
    pub fn record_login_failure(&self, username: &str, client: &str) {
        let now = Instant::now();

        // Bound memory against a spray of random usernames (or clients): once
        // large, drop entries that are no longer blocked (an active block is
        // always retained).
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
            .entry(login_key(username, client))
            .or_insert(fresh);
        entry.failures = entry.failures.saturating_add(1);
        if let Some(secs) = login_backoff_secs(entry.failures) {
            entry.blocked_until = now + Duration::from_secs(secs);
        }
        drop(entry);

        self.record_account_failure(username, now);
    }

    /// Count one failure toward the account-wide ceiling for `username`, and
    /// stamp the account backoff once it is over. Called for every failure,
    /// whichever client it came from.
    fn record_account_failure(&self, username: &str, now: Instant) {
        // Same memory bound as the per-pair map: when large, keep only accounts
        // that are blocked or still under pressure. Dropping a partial count
        // only ever relaxes the brake.
        if self.0.login_account_failures.len() > LOGIN_FAILURES_MAX_ENTRIES {
            self.0.login_account_failures.retain(|_, st| {
                st.blocked_until > now
                    || (st.strikes > 0
                        && st.last_failure().is_some_and(|t| {
                            now.saturating_duration_since(t) < ACCOUNT_QUIET_RESET
                        }))
            });
        }

        let mut st = self
            .0
            .login_account_failures
            .entry(username.to_owned())
            .or_insert_with(|| AccountFailState {
                recent: VecDeque::with_capacity(ACCOUNT_FAIL_CEILING),
                strikes: 0,
                blocked_until: now,
            });
        // A long enough quiet spell ends the pressure and the history with it.
        if st
            .last_failure()
            .is_some_and(|t| now.saturating_duration_since(t) >= ACCOUNT_QUIET_RESET)
        {
            st.recent.clear();
            st.strikes = 0;
        }
        st.recent.push_back(now);
        while st.recent.len() > ACCOUNT_FAIL_CEILING {
            st.recent.pop_front();
        }
        if st.strikes > 0 || st.over_ceiling() {
            st.strikes = st.strikes.saturating_add(1);
            st.blocked_until = now + Duration::from_secs(account_backoff_secs(st.strikes));
        }
    }

    /// Clear any failed-login state for the `username`/`client` pair after a
    /// successful login, so a legitimate user who eventually gets their password
    /// right resets the counter (and their next fat-finger starts from zero
    /// again). Only this client's counter is cleared; a different client's
    /// accumulated failures for the same account stand on their own, and so
    /// does the account-wide count (it decays with time, not with a success,
    /// so one successful sign-in does not hand anyone a fresh allowance).
    pub fn record_login_success(&self, username: &str, client: &str) {
        self.0.login_failures.remove(&login_key(username, client));
    }

    // ── console handoff codes ─────────────────────────────────────────────────

    /// Mint a single-use handoff code for `user_id` (issued by the session
    /// identified by `jti`, when it has one) and remember it for `ttl`.
    ///
    /// The code is ~30 bytes of OS-CSPRNG entropy rendered as lowercase hex, so
    /// it is URL-safe without escaping. Callers hand it to a browser in a URL
    /// fragment; the browser trades it for a real session at
    /// `POST /auth/handoff/exchange`.
    ///
    /// `ttl` is a parameter rather than a constant so tests can drive the
    /// expiry path without sleeping for the production window.
    pub fn issue_handoff_code(&self, user_id: Uuid, jti: Option<Uuid>, ttl: Duration) -> String {
        let now = Instant::now();

        // Bound memory: drop codes that can no longer be redeemed anyway.
        if self.0.handoff_codes.len() > HANDOFF_MAX_ENTRIES {
            self.0.handoff_codes.retain(|_, e| e.expires_at > now);
        }

        // Two v4 UUIDs, hex-rendered: `Uuid::new_v4` draws from the OS CSPRNG
        // (getrandom), and using it keeps this dependency-free.
        let code = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        self.0.handoff_codes.insert(
            code.clone(),
            HandoffEntry {
                user_id,
                jti,
                expires_at: now + ttl,
            },
        );
        code
    }

    /// Redeem a handoff code, returning the user id and the issuing session's
    /// `jti` on success. The entry is removed whether or not it was still
    /// valid, so a code is usable at most once; an expired or unknown code
    /// yields `None`.
    pub fn consume_handoff_code(&self, code: &str) -> Option<(Uuid, Option<Uuid>)> {
        let (_, entry) = self.0.handoff_codes.remove(code)?;
        if entry.expires_at <= Instant::now() {
            return None;
        }
        Some((entry.user_id, entry.jti))
    }
}

/// Pure predicate for "is the maintenance window in effect at `now`": armed
/// (`until > 0`) and not yet expired (`now < until`). Factored out so the guard
/// logic is unit-testable without constructing an `AppState`.
#[inline]
pub fn maintenance_active_at(until: i64, now: i64) -> bool {
    until > 0 && now < until
}

/// How the live-still proxy should fetch a camera's frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameAttempt {
    /// The full cold-start retry ladder. Only a failed attempt of this kind may
    /// arm the latch.
    Full,
    /// One attempt, no inter-attempt sleeps. Its failure leaves the latch alone.
    Single,
}

/// Per-camera "last full fetch failed" latch for the live-still proxy, as a
/// monotonic deadline per camera.
///
/// While the deadline is in the future the proxy makes a single attempt instead
/// of the full ladder, so a wall of tiles pointed at a camera that is down does
/// not hold a permit for the whole ladder on every poll. Rules that keep a slow
/// but healthy camera from getting stuck:
///
/// * only a failed FULL ladder arms the latch; a failed single attempt never
///   extends it, so the deadline is reached no matter how often the wall polls;
/// * once the deadline passes, the next request gets [`FrameAttempt::Full`] and
///   claims the probe by re-arming the deadline, so concurrent polls stay on the
///   single attempt while one request proves recovery;
/// * a success on any path clears the entry.
#[derive(Default)]
pub struct FrameLatch {
    until: DashMap<Uuid, Instant>,
}

impl FrameLatch {
    /// Decide how to fetch `camera_id`'s still at time `now`.
    pub fn attempt_at(&self, camera_id: Uuid, ttl: Duration, now: Instant) -> FrameAttempt {
        let Some(mut entry) = self.until.get_mut(&camera_id) else {
            return FrameAttempt::Full;
        };
        if now < *entry {
            return FrameAttempt::Single;
        }
        // Expired: this request is the probe. Hold the window for `ttl` so the
        // other polls keep the cheap path until the probe reports back.
        *entry = now + ttl;
        FrameAttempt::Full
    }

    /// Latch `camera_id` as unavailable until `now + ttl`.
    pub fn mark_at(&self, camera_id: Uuid, ttl: Duration, now: Instant) {
        // Cheap unbounded-growth guard: entries are one per camera, but a
        // pathological id churn would still be capped.
        if self.until.len() > 4096 {
            self.until.clear();
        }
        self.until.insert(camera_id, now + ttl);
    }

    /// Drop the latch for `camera_id` after a successful fetch.
    pub fn clear(&self, camera_id: Uuid) {
        self.until.remove(&camera_id);
    }
}

#[cfg(test)]
mod tests {
    use super::{
        account_backoff_secs, login_backoff_secs, login_key, maintenance_active_at, FrameAttempt,
        FrameLatch, ACCOUNT_BACKOFF_BASE_SECS, ACCOUNT_FAIL_CEILING, ACCOUNT_FAIL_WINDOW,
        LOGIN_BACKOFF_BASE_SECS, LOGIN_BACKOFF_CAP_SECS, LOGIN_FAIL_THRESHOLD,
    };
    use std::time::{Duration, Instant};
    use uuid::Uuid;

    /// Simulate the still proxy against a camera whose frames take `latency` to
    /// arrive after it was last "cold", with the per-attempt timeouts the
    /// handler uses (`single_timeout` for the single path, `full_timeout` per
    /// full-ladder attempt, 4 attempts). Returns true when the request succeeds.
    fn request(
        latch: &FrameLatch,
        id: Uuid,
        ttl: Duration,
        now: Instant,
        latency: Duration,
        single_timeout: Duration,
        full_timeout: Duration,
    ) -> bool {
        match latch.attempt_at(id, ttl, now) {
            FrameAttempt::Full => {
                // Every ladder attempt waits the same latency, so it succeeds
                // iff the latency fits one attempt's timeout.
                if latency <= full_timeout {
                    latch.clear(id);
                    true
                } else {
                    latch.mark_at(id, ttl, now);
                    false
                }
            }
            FrameAttempt::Single => {
                if latency <= single_timeout {
                    latch.clear(id);
                    true
                } else {
                    // Deliberately no mark_at: a single-attempt failure must
                    // not extend the latch.
                    false
                }
            }
        }
    }

    #[test]
    fn frame_latch_slow_camera_recovers_within_one_window_when_polled_every_second() {
        let latch = FrameLatch::default();
        let id = Uuid::new_v4();
        let ttl = Duration::from_secs(10);
        let t0 = Instant::now();
        let at = |s: u64| t0 + Duration::from_secs(s);

        // Second 0: the camera is down, the full ladder fails and arms the latch.
        assert!(!request(
            &latch,
            id,
            ttl,
            at(0),
            Duration::from_mins(1),
            Duration::from_secs(2),
            Duration::from_secs(5)
        ));

        // From then on the camera is slow (3 s to a frame) but healthy. The
        // single path times out at 2 s, as the old fast path did; the wall polls
        // every second. It must be served again no later than one window later.
        let mut recovered_at = None;
        for s in 1..=12 {
            if request(
                &latch,
                id,
                ttl,
                at(s),
                Duration::from_secs(3),
                Duration::from_secs(2),
                Duration::from_secs(5),
            ) {
                recovered_at = Some(s);
                break;
            }
        }
        let recovered_at = recovered_at.expect("slow camera never recovered");
        assert!(recovered_at <= 10, "recovered too late: {recovered_at}s");
        assert_eq!(recovered_at, 10, "probe runs exactly when the window ends");
        // And it stays served normally afterwards.
        assert_eq!(latch.attempt_at(id, ttl, at(11)), FrameAttempt::Full);
    }

    #[test]
    fn frame_latch_single_failure_does_not_extend_and_probe_is_claimed_once() {
        let latch = FrameLatch::default();
        let id = Uuid::new_v4();
        let ttl = Duration::from_secs(10);
        let t0 = Instant::now();
        let at = |s: u64| t0 + Duration::from_secs(s);

        latch.mark_at(id, ttl, at(0));
        assert_eq!(latch.attempt_at(id, ttl, at(5)), FrameAttempt::Single);
        assert_eq!(latch.attempt_at(id, ttl, at(9)), FrameAttempt::Single);
        // Window over: exactly one caller gets the full ladder, the rest stay on
        // the single attempt while the probe runs.
        assert_eq!(latch.attempt_at(id, ttl, at(10)), FrameAttempt::Full);
        assert_eq!(latch.attempt_at(id, ttl, at(10)), FrameAttempt::Single);
        assert_eq!(latch.attempt_at(id, ttl, at(11)), FrameAttempt::Single);
        // A failed probe re-arms for a fresh window; a successful one clears it.
        latch.mark_at(id, ttl, at(14));
        assert_eq!(latch.attempt_at(id, ttl, at(23)), FrameAttempt::Single);
        assert_eq!(latch.attempt_at(id, ttl, at(24)), FrameAttempt::Full);
        latch.clear(id);
        assert_eq!(latch.attempt_at(id, ttl, at(25)), FrameAttempt::Full);
        assert_eq!(latch.attempt_at(id, ttl, at(25)), FrameAttempt::Full);
    }

    #[test]
    fn account_backoff_doubles_from_base_and_caps() {
        assert_eq!(account_backoff_secs(1), ACCOUNT_BACKOFF_BASE_SECS);
        assert_eq!(account_backoff_secs(2), ACCOUNT_BACKOFF_BASE_SECS * 2);
        assert_eq!(account_backoff_secs(3), ACCOUNT_BACKOFF_BASE_SECS * 4);
        assert_eq!(account_backoff_secs(6), LOGIN_BACKOFF_CAP_SECS);
        assert_eq!(account_backoff_secs(u32::MAX), LOGIN_BACKOFF_CAP_SECS);
    }

    #[test]
    fn one_client_alone_cannot_reach_the_account_ceiling_in_a_window() {
        // Replay the per-pair schedule: each failure lands the moment the
        // previous backoff lapses. Count how many fit in one account window.
        let window = ACCOUNT_FAIL_WINDOW.as_secs();
        let mut t = 0_u64;
        let mut failures = 0_u32;
        while t <= window {
            failures += 1;
            t += login_backoff_secs(failures).unwrap_or(0);
        }
        assert!(
            usize::try_from(failures).unwrap() < ACCOUNT_FAIL_CEILING,
            "one client fits {failures} failures in a window; the ceiling must stay above that"
        );
    }

    #[test]
    fn login_key_separates_clients_for_the_same_account() {
        // The whole point of the composite key: one account seen from two
        // clients occupies two independent buckets, so failures from one can
        // never block the other.
        assert_ne!(
            login_key("operator", "198.51.100.7"),
            login_key("operator", "203.0.113.9")
        );
        // ... and the same pair always maps to the same bucket.
        assert_eq!(
            login_key("operator", "198.51.100.7"),
            login_key("operator", "198.51.100.7")
        );
    }

    #[test]
    fn login_key_does_not_collide_across_accounts() {
        // Two different accounts never share a bucket, including the awkward
        // case of a username that itself contains the separator.
        assert_ne!(
            login_key("operator\u{1f}198.51.100.7", "203.0.113.9"),
            login_key("operator", "198.51.100.7")
        );
        assert_ne!(
            login_key("operator", "198.51.100.7"),
            login_key("operator2", "198.51.100.7")
        );
    }

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
