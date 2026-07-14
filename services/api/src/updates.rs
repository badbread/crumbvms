// SPDX-License-Identifier: AGPL-3.0-or-later

//! Update-available check (issue #7, Phase 1 — server).
//!
//! # Endpoints
//!
//! | Method | Path              | Auth               | Description |
//! |--------|-------------------|---------------------|-------------|
//! | `GET`  | `/updates/latest` | Bearer (any user)   | Latest `GitHub` release vs. this server's own version |
//!
//! See `docs/UPDATE-SYSTEM-PLAN.md` for the full design. Restated invariants
//! this module must never violate:
//!
//! * **Notify-only.** No download, no install, the recorder is never touched.
//! * **Opt-in, off by default (D3).** [`crate::config::ApiConfig::update_check_enabled`]
//!   defaults to `false`; the admin-editable `server_settings.update_check_enabled`
//!   DB value (see `crumb_common::db::get_update_check_enabled`) wins when set.
//!   When the resolved state is disabled, this module makes **zero** requests
//!   to `GitHub` — not even for an explicit `?refresh=1` "Check now" click.
//! * **Sends nothing.** The one outbound request is a plain, unauthenticated
//!   `GET` to `GitHub`'s public `releases/latest` endpoint: no query params, no
//!   client identifiers, no counts. That is the line between a version check
//!   and telemetry.
//! * **Cache lives in memory only**, TTL 6h, stale-while-error (a `GitHub`
//!   outage never surfaces as an error to clients, just an older `checked_at`).
//!   Dies with the process on restart; that's fine, no persistence is needed.
//! * **"Check now" (§2.5)** — `?refresh=1` forces an immediate re-check,
//!   bypassing the 6h TTL, but is itself rate-limited to one actual `GitHub`
//!   hit per 60s so a burst of manual clicks (or several authenticated clients
//!   each polling "Check now") can't stampede `GitHub`'s unauthenticated
//!   60/h/IP limit.

use std::future::Future;
use std::sync::OnceLock;

use anyhow::Context as _;
use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use tokio::sync::Mutex;

use crate::{
    auth_mw::AuthUser,
    config::ApiConfig,
    dto::{UpdateCheckResponse, UpdatesLatestQuery},
    error::ApiError,
    state::AppState,
};

/// This server's own build version. Read independently of `crate::VERSION`
/// (`main.rs`'s copy, used by `GET /version`) rather than referencing it
/// directly: `services/api/tests/support/mod.rs` re-includes this file's
/// source under a DIFFERENT crate root (a test binary, not `main.rs`) via
/// `#[path]`, where `crate::VERSION` would not resolve.
const VERSION: &str = include_str!("../../../VERSION");

/// Mount the update-check route.
pub fn routes() -> Router<AppState> {
    Router::new().route("/updates/latest", get(get_latest_update))
}

/// `GET /updates/latest` — any authenticated user (viewers run wall displays
/// and phones too; this is deliberately not admin-only).
async fn get_latest_update(
    _user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<UpdatesLatestQuery>,
) -> Result<Json<UpdateCheckResponse>, ApiError> {
    let enabled = resolve_enabled(state.pool(), state.config()).await?;
    let force = q.refresh.as_deref() == Some("1");
    let server_version = VERSION.trim();
    let response = build_response(enabled, force, server_version, get_release_info).await;
    Ok(Json(response))
}

/// Effective enabled state for the update-available check (house precedence
/// rule: an explicit admin-set `server_settings` value wins; `NULL` — the
/// operator has never touched the toggle — falls back to the
/// `UPDATE_CHECK_ENABLED` env default, which is itself `false` per D3).
///
/// # Errors
///
/// Returns [`ApiError::Internal`] if the settings query fails.
pub(crate) async fn resolve_enabled(pool: &Pool, cfg: &ApiConfig) -> Result<bool, ApiError> {
    let db_value = crumb_common::db::get_update_check_enabled(pool)
        .await
        .map_err(ApiError::Internal)?;
    Ok(db_value.unwrap_or(cfg.update_check_enabled))
}

// ─── response assembly (pure; unit-tested without a DB or network call) ────────

impl UpdateCheckResponse {
    /// `enabled:false` — every other field null, per §2.1.
    fn disabled() -> Self {
        Self {
            enabled: false,
            latest_version: None,
            notes_url: None,
            published_at: None,
            server_version: None,
            server_update_available: None,
            checked_at: None,
        }
    }
}

/// Build the response body from the resolved `enabled` state, this server's
/// own version, and a (test-injectable) cache lookup.
///
/// Split out from the handler so the hard invariant — disabled means zero
/// fetch attempts, even with `force` ("Check now") — is unit-testable without
/// a DB or network call: `get_release` is never invoked at all when `!enabled`.
async fn build_response<F, Fut>(
    enabled: bool,
    force: bool,
    server_version: &str,
    get_release: F,
) -> UpdateCheckResponse
where
    F: FnOnce(bool) -> Fut,
    Fut: Future<Output = Option<CachedRelease>>,
{
    if !enabled {
        return UpdateCheckResponse::disabled();
    }

    let cached = get_release(force).await;
    let server_update_available = cached
        .as_ref()
        .and_then(|c| is_update_available(server_version, &c.latest_version));

    UpdateCheckResponse {
        enabled: true,
        latest_version: cached.as_ref().map(|c| c.latest_version.clone()),
        notes_url: cached.as_ref().map(|c| c.notes_url.clone()),
        published_at: cached.as_ref().map(|c| c.published_at),
        server_version: Some(server_version.to_owned()),
        server_update_available,
        checked_at: cached.as_ref().map(|c| c.checked_at),
    }
}

// ─── SemVer compare (§2.2) ──────────────────────────────────────────────────────

/// Parse a plain `MAJOR.MINOR.PATCH` version (exactly three dot-separated
/// non-negative integers). `None` for anything else — a pre-release/build
/// suffix like `"-dev"`, a missing part, or non-numeric text — per
/// `docs/UPDATE-SYSTEM-PLAN.md` §2.2: an unparsable version is "no signal",
/// deliberately not an error.
fn parse_semver(s: &str) -> Option<(u64, u64, u64)> {
    let mut parts = s.trim().split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None; // extra segments (e.g. "1.2.3.4") — not a plain triple.
    }
    Some((major, minor, patch))
}

/// Whether `latest` is a strictly newer release than `current` (`SemVer`
/// 2.0.0 precedence, tuple-lexicographic since neither side carries a
/// pre-release/build suffix once parsed). `None` — not `Some(false)` — when
/// either fails to parse, so an unparsable local dev build never claims to be
/// "up to date".
fn is_update_available(current: &str, latest: &str) -> Option<bool> {
    let cur = parse_semver(current)?;
    let lat = parse_semver(latest)?;
    Some(lat > cur)
}

// ─── GitHub fetch (the one outbound request) ───────────────────────────────────

const GITHUB_RELEASES_URL: &str = "https://api.github.com/repos/badbread/crumbvms/releases/latest";

/// Short-timeout client for the one-off `GitHub` releases/latest GET. Built
/// fresh per call (mirrors `go2rtc::client()`) — this endpoint fires at most a
/// handful of times a day even under heavy "Check now" use, so there is no
/// hot-path reason to cache the client the way the live MSE proxy does.
fn http_client() -> anyhow::Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .context("build GitHub releases HTTP client")
}

/// The subset of `GitHub`'s release JSON this module needs.
#[derive(Debug, serde::Deserialize)]
struct GithubReleaseJson {
    tag_name: String,
    html_url: String,
    published_at: DateTime<Utc>,
}

/// A cached, already-parsed release — the notes URL, its stripped version
/// tag, and when this cache entry was last refreshed from `GitHub`.
#[derive(Debug, Clone)]
struct CachedRelease {
    latest_version: String,
    notes_url: String,
    published_at: DateTime<Utc>,
    checked_at: DateTime<Utc>,
}

/// Parse a `GitHub` `releases/latest` JSON body into a [`CachedRelease`].
/// Split out from [`fetch_latest_release`] so the parsing / `v`-prefix
/// stripping logic is unit-testable with a literal JSON string — no network
/// call involved.
fn release_from_github_json(
    body: &str,
    checked_at: DateTime<Utc>,
) -> anyhow::Result<CachedRelease> {
    let parsed: GithubReleaseJson =
        serde_json::from_str(body).context("parse GitHub releases/latest JSON")?;
    Ok(CachedRelease {
        latest_version: parsed.tag_name.trim_start_matches('v').to_owned(),
        notes_url: parsed.html_url,
        published_at: parsed.published_at,
        checked_at,
    })
}

/// One-shot `GET` of `GitHub`'s `releases/latest` for `badbread/crumbvms`.
/// That endpoint already excludes drafts and pre-releases, so the result is
/// stable-releases-only by construction (D6). Sends nothing beyond the
/// request itself — no query params, no client identifiers, no counts.
async fn fetch_latest_release() -> anyhow::Result<CachedRelease> {
    let client = http_client()?;
    let resp = client
        .get(GITHUB_RELEASES_URL)
        // GitHub's REST API rejects requests with no User-Agent.
        .header(reqwest::header::USER_AGENT, "crumbvms-update-check")
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await
        .context("GET GitHub releases/latest")?;
    if !resp.status().is_success() {
        anyhow::bail!("GitHub releases/latest -> HTTP {}", resp.status());
    }
    let body = resp
        .text()
        .await
        .context("read GitHub releases/latest body")?;
    release_from_github_json(&body, Utc::now())
}

// ─── in-memory cache: 6h TTL, stale-while-error, 60s "Check now" backoff ───────

/// How long a successful fetch is considered fresh before the organic (non
/// "Check now") path will try again.
const CACHE_TTL_SECS: i64 = 6 * 60 * 60;

/// Minimum spacing between actual `GitHub` hits triggered by `?refresh=1`
/// ("Check now"), independent of the organic TTL — protects the 60/h/IP
/// unauthenticated rate limit from a burst of manual clicks.
const FORCE_MIN_INTERVAL_SECS: i64 = 60;

#[derive(Default)]
struct CacheSlot {
    /// Last successfully parsed release, if any fetch has ever succeeded.
    data: Option<CachedRelease>,
    /// Last fetch ATTEMPT (success or failure) made by the organic TTL path.
    last_attempt_at: Option<DateTime<Utc>>,
    /// Last fetch ATTEMPT (success or failure) made by a forced ("Check now")
    /// call. Tracked separately from `last_attempt_at` so the 60s manual
    /// backoff and the 6h organic backoff don't fight over one clock.
    last_forced_attempt_at: Option<DateTime<Utc>>,
}

/// Decide whether to fetch, then update `slot` in place. Pure with respect to
/// `GitHub` itself — `fetch` is injected, so the TTL / stale-while-error /
/// "Check now" backoff logic is unit-tested with a fake closure and no
/// network call at all (`docs/UPDATE-SYSTEM-PLAN.md` §2.1/§2.5).
async fn refresh_if_needed<F, Fut>(slot: &mut CacheSlot, now: DateTime<Utc>, force: bool, fetch: F)
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = anyhow::Result<CachedRelease>>,
{
    let stale = slot
        .data
        .as_ref()
        .is_none_or(|d| (now - d.checked_at).num_seconds() >= CACHE_TTL_SECS);
    let organic_blocked = slot
        .last_attempt_at
        .is_some_and(|t| (now - t).num_seconds() < CACHE_TTL_SECS);
    let forced_blocked = slot
        .last_forced_attempt_at
        .is_some_and(|t| (now - t).num_seconds() < FORCE_MIN_INTERVAL_SECS);

    let should_fetch = if force {
        !forced_blocked
    } else {
        stale && !organic_blocked
    };
    if !should_fetch {
        return;
    }

    // Every real attempt (forced or organic) counts against the ORGANIC clock
    // — an organic re-check shouldn't fire again moments later regardless of
    // which path triggered the fetch that just happened. The FORCE clock is
    // narrower on purpose: it must only track actual "Check now" clicks, so a
    // click shortly after an organic (TTL-driven) fetch still gets its one
    // immediate manual check rather than being told "just checked".
    slot.last_attempt_at = Some(now);
    if force {
        slot.last_forced_attempt_at = Some(now);
    }

    match fetch().await {
        Ok(fresh) => slot.data = Some(fresh),
        Err(e) => {
            // Stale-while-error: keep serving the last good value (if any)
            // unchanged — never surface a GitHub outage to clients as an
            // error, just an older `checked_at`.
            tracing::warn!(
                error = %e,
                force,
                "update check: GitHub releases fetch failed; serving stale/none cached value"
            );
        }
    }
}

fn cache() -> &'static Mutex<CacheSlot> {
    static CACHE: OnceLock<Mutex<CacheSlot>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(CacheSlot::default()))
}

/// Look up the cached release info, refreshing from `GitHub` first if the TTL
/// (or, when `force`, the 60s "Check now" backoff) allows it. Never called at
/// all when the check is disabled — see [`build_response`].
async fn get_release_info(force: bool) -> Option<CachedRelease> {
    let mut guard = cache().lock().await;
    refresh_if_needed(&mut guard, Utc::now(), force, fetch_latest_release).await;
    guard.data.clone()
}

// ─── background update-available notifier (issue #35) ──────────────────────────

/// System-event key emitted when a newer release is detected. Seeded OFF by
/// default into `system_alert_rules` by migration
/// `0057_update_available_alert.sql`, and dispatched over the configured
/// notification channels by `notifications.rs`.
const UPDATE_AVAILABLE_EVENT_KEY: &str = "update_available";

/// How often the notifier re-evaluates. Aligned with the 6h cache TTL: a poll
/// that finds the cache stale triggers exactly one `GitHub` fetch, so this
/// cadence bounds `GitHub` contact to ~once per 6h (well inside the 60/h/IP
/// unauthenticated limit) while still surfacing a new release within a few hours
/// of it landing.
const UPDATE_NOTIFY_POLL_SECS: u64 = 6 * 60 * 60;

/// Edge-trigger decision for the update-available notifier. Kept pure (no DB, no
/// network) so the once-per-version de-dupe is exhaustively unit-testable.
#[derive(Debug, PartialEq, Eq)]
enum UpdateNotifyDecision {
    /// A newer version is available that has NOT already been notified — emit an
    /// `update_available` system event for it, then latch this version.
    Notify(String),
    /// Server is up to date (or the local build is newer than latest): clear the
    /// latch so the NEXT distinct release re-fires.
    ClearLatch,
    /// No actionable change — already notified this version, or no parseable
    /// signal (unreachable `GitHub` / unparseable dev build). Latch untouched.
    Skip,
}

/// Decide whether to emit an update-available notification this tick.
///
/// * `update_available` — the [`is_update_available`] result: `Some(true)`
///   newer, `Some(false)` up to date, `None` no signal.
/// * `latest_version` — the version tag `GitHub` reported (if any).
/// * `last_notified` — the version this task last emitted an event for (the
///   in-memory latch), or `None` if it has not emitted for the current streak.
///
/// De-dupe rules: a given version fires at most once (latched); a return to
/// up-to-date clears the latch so a later release fires again; an
/// unparseable/absent signal is a no-op that specifically does NOT clear a valid
/// latch (a transient `GitHub` outage must not cause a re-fire when it recovers).
fn update_notify_decision(
    update_available: Option<bool>,
    latest_version: Option<&str>,
    last_notified: Option<&str>,
) -> UpdateNotifyDecision {
    match (update_available, latest_version) {
        (Some(true), Some(latest)) => {
            if last_notified == Some(latest) {
                UpdateNotifyDecision::Skip
            } else {
                UpdateNotifyDecision::Notify(latest.to_owned())
            }
        }
        // Up to date (or local build newer than latest) — reset the latch.
        (Some(false), _) => UpdateNotifyDecision::ClearLatch,
        // No signal (GitHub unreachable, or an unparseable local version).
        _ => UpdateNotifyDecision::Skip,
    }
}

/// Background task (issue #35): periodically checks whether a newer release is
/// available and, on the edge where one first appears, fires an
/// `update_available` system event that the notification engine
/// (`notifications.rs`) fans out over the configured channels.
///
/// Opt-in on BOTH gates, honoring Crumb's no-phone-home posture:
/// 1. the update-available check must be enabled
///    (`server_settings.update_check_enabled` / `UPDATE_CHECK_ENABLED`, off by
///    default per D3) — while off this task makes ZERO `GitHub` requests; and
/// 2. the `update_available` system-alert rule must be enabled (off by default,
///    migration 0057) — while off the task neither fetches nor latches.
///
/// De-dupe is a per-version in-memory latch (see [`update_notify_decision`]): a
/// given version emits one event and only a later distinct release re-fires.
/// The latch resets on process restart — at worst one repeat event for a
/// still-available version after a restart, itself bounded by the rule's 6h
/// cooldown in the engine.
pub async fn run_update_notifier(pool: Pool, cfg: ApiConfig) {
    let server_version = VERSION.trim().to_owned();
    let mut last_notified: Option<String> = None;

    let poll_interval = std::time::Duration::from_secs(UPDATE_NOTIFY_POLL_SECS);
    let mut ticker = tokio::time::interval(poll_interval);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    tracing::info!(
        poll_secs = UPDATE_NOTIFY_POLL_SECS,
        "update-available notifier started"
    );

    loop {
        ticker.tick().await;

        // ── Gate 1: update-available check enabled? (else zero GitHub contact —
        //    the no-phone-home invariant.) ────────────────────────────────────
        match resolve_enabled(&pool, &cfg).await {
            Ok(true) => {}
            Ok(false) => {
                // Off — reset so re-enabling re-notifies for the current release.
                last_notified = None;
                continue;
            }
            Err(e) => {
                tracing::warn!(error = %e, "update notifier: resolve_enabled failed; skipping tick");
                continue;
            }
        }

        // ── Gate 2: the `update_available` system-alert rule must be on (else
        //    nothing would dispatch — don't fetch or latch). ──────────────────
        match crumb_common::db::get_system_alert_rule(&pool, UPDATE_AVAILABLE_EVENT_KEY).await {
            Ok(Some(rule)) if rule.enabled => {}
            Ok(_) => {
                last_notified = None; // rule off/missing — re-enabling re-notifies
                continue;
            }
            Err(e) => {
                tracing::warn!(error = %e, "update notifier: get_system_alert_rule failed; skipping tick");
                continue;
            }
        }

        // ── Both gates open: consult the shared, cached release info. A `None`
        //    here is "no signal" (GitHub unreachable / no data yet) — leave the
        //    latch untouched. ─────────────────────────────────────────────────
        let Some(release) = get_release_info(false).await else {
            continue;
        };
        let available = is_update_available(&server_version, &release.latest_version);

        match update_notify_decision(
            available,
            Some(&release.latest_version),
            last_notified.as_deref(),
        ) {
            UpdateNotifyDecision::Notify(version) => {
                let detail = format!(
                    "Crumb {version} is available (this server runs {server_version}). \
                     Release notes: {}",
                    release.notes_url
                );
                match crumb_common::db::insert_system_event(
                    &pool,
                    UPDATE_AVAILABLE_EVENT_KEY,
                    None,
                    Some(&detail),
                )
                .await
                {
                    Ok(_) => {
                        tracing::info!(
                            version = %version,
                            "update notifier: newer release detected — system event emitted"
                        );
                        last_notified = Some(version);
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "update notifier: insert_system_event(update_available) failed");
                    }
                }
            }
            UpdateNotifyDecision::ClearLatch => last_notified = None,
            UpdateNotifyDecision::Skip => {}
        }
    }
}

// ─── tests ──────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn dt(secs_from_epoch: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(secs_from_epoch, 0).single().unwrap()
    }

    fn sample(checked_at: DateTime<Utc>) -> CachedRelease {
        CachedRelease {
            latest_version: "0.0.2".to_owned(),
            notes_url: "https://github.com/badbread/crumbvms/releases/tag/v0.0.2".to_owned(),
            published_at: checked_at,
            checked_at,
        }
    }

    // ── SemVer compare ──────────────────────────────────────────────────────

    #[test]
    fn parses_plain_versions() {
        assert_eq!(parse_semver("0.0.1"), Some((0, 0, 1)));
        assert_eq!(parse_semver("1.2.3"), Some((1, 2, 3)));
        assert_eq!(parse_semver(" 1.2.3 "), Some((1, 2, 3)));
    }

    #[test]
    fn rejects_prerelease_suffix_and_garbage() {
        // Unparsable ⇒ "no signal" (§2.2), the exact case a local dev build hits.
        assert_eq!(parse_semver("0.0.1-dev"), None);
        assert_eq!(parse_semver("v0.0.1"), None);
        assert_eq!(parse_semver("0.0"), None);
        assert_eq!(parse_semver("0.0.1.2"), None);
        assert_eq!(parse_semver(""), None);
        assert_eq!(parse_semver("not-a-version"), None);
    }

    #[test]
    fn detects_newer_release() {
        assert_eq!(is_update_available("0.0.1", "0.0.2"), Some(true));
        assert_eq!(is_update_available("0.0.2", "0.0.2"), Some(false));
        assert_eq!(is_update_available("0.1.0", "0.0.9"), Some(false));
        assert_eq!(is_update_available("0.9.9", "1.0.0"), Some(true));
    }

    #[test]
    fn unparsable_version_is_no_signal_not_false() {
        assert_eq!(is_update_available("0.0.1-dev", "0.0.2"), None);
        assert_eq!(is_update_available("0.0.1", "not-a-version"), None);
    }

    // ── GitHub JSON parsing ─────────────────────────────────────────────────

    #[test]
    fn parses_github_release_json_and_strips_v_prefix() {
        let body = r#"{
            "tag_name": "v0.0.2",
            "html_url": "https://github.com/badbread/crumbvms/releases/tag/v0.0.2",
            "published_at": "2026-07-20T00:00:00Z"
        }"#;
        let checked = dt(1_000);
        let parsed = release_from_github_json(body, checked).expect("valid JSON parses");
        assert_eq!(parsed.latest_version, "0.0.2");
        assert_eq!(
            parsed.notes_url,
            "https://github.com/badbread/crumbvms/releases/tag/v0.0.2"
        );
        assert_eq!(parsed.checked_at, checked);
    }

    #[test]
    fn rejects_malformed_github_json() {
        assert!(release_from_github_json("not json", Utc::now()).is_err());
        assert!(release_from_github_json("{}", Utc::now()).is_err());
    }

    // ── cache: TTL, stale-while-error, "Check now" backoff (no network) ────

    #[tokio::test]
    async fn fetches_when_cache_is_empty() {
        let mut slot = CacheSlot::default();
        let now = dt(10_000);
        let calls = std::cell::Cell::new(0);
        refresh_if_needed(&mut slot, now, false, || {
            calls.set(calls.get() + 1);
            async move { Ok(sample(now)) }
        })
        .await;
        assert_eq!(calls.get(), 1);
        assert_eq!(slot.data.expect("populated").checked_at, now);
    }

    #[tokio::test]
    async fn does_not_refetch_within_the_ttl() {
        let now0 = dt(10_000);
        let mut slot = CacheSlot::default();
        refresh_if_needed(&mut slot, now0, false, || async move { Ok(sample(now0)) }).await;

        let now1 = now0 + chrono::Duration::minutes(30); // well within 6h
        let calls = std::cell::Cell::new(0);
        refresh_if_needed(&mut slot, now1, false, || {
            calls.set(calls.get() + 1);
            async move { Ok(sample(now1)) }
        })
        .await;
        assert_eq!(
            calls.get(),
            0,
            "organic path must not re-fetch inside the TTL window"
        );
    }

    #[tokio::test]
    async fn refetches_once_the_ttl_elapses() {
        let now0 = dt(10_000);
        let mut slot = CacheSlot::default();
        refresh_if_needed(&mut slot, now0, false, || async move { Ok(sample(now0)) }).await;

        let now1 = now0 + chrono::Duration::seconds(CACHE_TTL_SECS + 1);
        let calls = std::cell::Cell::new(0);
        refresh_if_needed(&mut slot, now1, false, || {
            calls.set(calls.get() + 1);
            async move { Ok(sample(now1)) }
        })
        .await;
        assert_eq!(calls.get(), 1);
        assert_eq!(slot.data.unwrap().checked_at, now1);
    }

    #[tokio::test]
    async fn stale_while_error_keeps_the_old_value_and_old_checked_at() {
        let now0 = dt(10_000);
        let mut slot = CacheSlot::default();
        refresh_if_needed(&mut slot, now0, false, || async move { Ok(sample(now0)) }).await;

        let now1 = now0 + chrono::Duration::seconds(CACHE_TTL_SECS + 1);
        refresh_if_needed(&mut slot, now1, false, || async move {
            Err(anyhow::anyhow!("github is down"))
        })
        .await;

        let data = slot.data.expect("stale value retained on a failed fetch");
        assert_eq!(
            data.checked_at, now0,
            "checked_at must not advance on a failed fetch — that's the client-visible signal"
        );
    }

    #[tokio::test]
    async fn force_bypasses_the_ttl_but_respects_its_own_60s_backoff() {
        let now0 = dt(10_000);
        let mut slot = CacheSlot::default();
        refresh_if_needed(&mut slot, now0, false, || async move { Ok(sample(now0)) }).await;

        // Data is fresh (5s old); force=1 ("Check now") must still hit GitHub once.
        let now1 = now0 + chrono::Duration::seconds(5);
        let calls = std::cell::Cell::new(0);
        refresh_if_needed(&mut slot, now1, true, || {
            calls.set(calls.get() + 1);
            async move { Ok(sample(now1)) }
        })
        .await;
        assert_eq!(
            calls.get(),
            1,
            "Check now must bypass the TTL freshness check"
        );

        // A second forced click 10s later (< 60s) must NOT hit GitHub again.
        let now2 = now1 + chrono::Duration::seconds(10);
        refresh_if_needed(&mut slot, now2, true, || {
            calls.set(calls.get() + 1);
            async move { Ok(sample(now2)) }
        })
        .await;
        assert_eq!(
            calls.get(),
            1,
            "a second Check now inside 60s must serve the cache, not hit GitHub again"
        );
    }

    // ── disabled ⇒ zero fetch attempts, even with force=1 ───────────────────

    #[tokio::test]
    async fn disabled_never_calls_get_release_even_with_force() {
        let calls = std::cell::Cell::new(0);
        let resp = build_response(false, true, "0.0.1", |_force: bool| {
            calls.set(calls.get() + 1);
            async { None::<CachedRelease> }
        })
        .await;

        assert_eq!(
            calls.get(),
            0,
            "disabled must short-circuit before the cache/fetch layer is touched at all"
        );
        assert!(!resp.enabled);
        assert!(resp.latest_version.is_none());
        assert!(resp.server_version.is_none());
        assert!(resp.server_update_available.is_none());
        assert!(resp.checked_at.is_none());
    }

    #[tokio::test]
    async fn enabled_with_no_cached_release_yet_reports_no_signal() {
        // First request ever, GitHub unreachable so far: enabled but no data.
        let resp = build_response(true, false, "0.0.1", |_force: bool| async {
            None::<CachedRelease>
        })
        .await;
        assert!(resp.enabled);
        assert!(resp.latest_version.is_none());
        assert!(resp.server_update_available.is_none());
        assert_eq!(resp.server_version.as_deref(), Some("0.0.1"));
    }

    #[tokio::test]
    async fn enabled_with_cached_release_reports_update_available() {
        let checked = dt(50_000);
        let resp = build_response(true, false, "0.0.1", move |_force: bool| async move {
            Some(sample(checked))
        })
        .await;
        assert!(resp.enabled);
        assert_eq!(resp.latest_version.as_deref(), Some("0.0.2"));
        assert_eq!(resp.server_update_available, Some(true));
        assert_eq!(resp.checked_at, Some(checked));
    }

    // ── update-available notifier: edge-trigger + per-version de-dupe (#35) ──

    #[test]
    fn notify_fires_once_when_a_newer_version_first_appears() {
        // First sighting of a newer version, nothing latched yet → Notify.
        assert_eq!(
            update_notify_decision(Some(true), Some("0.0.2"), None),
            UpdateNotifyDecision::Notify("0.0.2".to_owned())
        );
    }

    #[test]
    fn notify_deduped_for_the_same_version_already_notified() {
        // Same newer version, already latched → Skip (no re-fire every poll).
        assert_eq!(
            update_notify_decision(Some(true), Some("0.0.2"), Some("0.0.2")),
            UpdateNotifyDecision::Skip
        );
    }

    #[test]
    fn notify_refires_for_a_different_newer_version() {
        // A DISTINCT later release supersedes the latched one → Notify again.
        assert_eq!(
            update_notify_decision(Some(true), Some("0.0.3"), Some("0.0.2")),
            UpdateNotifyDecision::Notify("0.0.3".to_owned())
        );
    }

    #[test]
    fn up_to_date_clears_the_latch_so_a_future_release_refires() {
        // Server caught up (or is newer) → clear latch; then the next newer
        // release fires as a fresh edge.
        assert_eq!(
            update_notify_decision(Some(false), Some("0.0.2"), Some("0.0.2")),
            UpdateNotifyDecision::ClearLatch
        );
        assert_eq!(
            update_notify_decision(Some(true), Some("0.0.3"), None),
            UpdateNotifyDecision::Notify("0.0.3".to_owned())
        );
    }

    #[test]
    fn no_signal_never_clears_a_valid_latch() {
        // A transient GitHub outage / unparseable local version = None: a no-op
        // that must NOT clear the latch (else recovery would spuriously re-fire).
        assert_eq!(
            update_notify_decision(None, None, Some("0.0.2")),
            UpdateNotifyDecision::Skip
        );
        assert_eq!(
            update_notify_decision(None, Some("0.0.2"), Some("0.0.2")),
            UpdateNotifyDecision::Skip
        );
    }
}
