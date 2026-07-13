// SPDX-License-Identifier: AGPL-3.0-or-later

//! go2rtc stream management — makes Crumb the OWNER of its go2rtc's streams.
//!
//! For each Crumb-managed camera (one with a `source_url`), the API defines a
//! go2rtc stream named after the camera's `go2rtc_name`, whose producer is the
//! raw camera RTSP (`source_url`), plus a `<name>_sub` stream when the camera has
//! a sub source. Streams are applied via go2rtc's REST API (`PUT/DELETE
//! /api/streams`) at runtime — so there is no go2rtc restart (no blip on other
//! cameras) and the operator's hand-written `go2rtc.yaml` is NEVER rewritten
//! (any manually-configured streams stay untouched).
//!
//! Runtime API changes don't persist across a go2rtc restart (its config is
//! mounted read-only), so a periodic [`spawn_reconcile_loop`] re-applies the
//! managed set — a go2rtc restart self-heals quickly (see below).
//!
//! # Fan-out: reconcile updates existing streams in place, only creates missing ones
//!
//! go2rtc's `PUT /api/streams` UNCONDITIONALLY REPLACES the in-memory stream
//! object; the old object — with its live camera session and attached consumers —
//! is orphaned but keeps running, invisible to the API and un-joinable by new
//! consumers. So re-`PUT`ting every stream each pass (as this loop used to) forked
//! the sharing domain every `RECONCILE_INTERVAL`: any consumer that attached after
//! a `PUT` landed on a fresh idle object and had to dial the camera AGAIN,
//! converging to one camera RTSP session per long-lived consumer (recorder +
//! motion + Frigate + each live client + each snapshot). On a session-capped
//! camera that exhausts the slots, and new live/snapshot consumers are refused at
//! RTSP `SETUP`. [`reconcile`] therefore GETs the existing names and only `PUT`s
//! the ones go2rtc is MISSING (cold start / go2rtc restart), using in-place
//! `PATCH` ([`patch_stream`]) for streams that already exist — which never
//! replaces the object, so every consumer shares the single producer. See
//! `docs/DECISIONS.md` (go2rtc stream model).
//!
//! # Detection vs. reconcile are decoupled (recorder-restart footage gap)
//!
//! go2rtc is embedded INSIDE the recorder container (see
//! `services/recorder/src/go2rtc_embed.rs`), so a `docker restart` of the
//! recorder — independent of this api process, which keeps running — silently
//! empties go2rtc's stream table. Recording can't resume until this api
//! re-PUTs the streams, so how fast we NOTICE the drop is what determines the
//! footage gap.
//!
//! An earlier version of this loop only checked go2rtc's stream count right
//! after each full reconcile pass, and sped up subsequent passes when short —
//! but in steady state (nothing short) it still slept the full
//! `RECONCILE_INTERVAL` (60 s) between passes, so a recorder-only restart
//! wasn't even noticed until the next tick. Measured recovery: ~50 s,
//! dominated entirely by this detection latency, not by the catch-up itself.
//!
//! [`spawn_reconcile_loop`] now runs a cheap [`get_stream_count`] poll every
//! `CHECK_INTERVAL` (~5 s) and only runs the expensive [`reconcile`] (PUT-all)
//! pass when the count looks short, the count check itself fails (go2rtc mid
//! restart / unreachable), or `RECONCILE_INTERVAL` has elapsed since the last
//! full pass (periodic drift correction / stale-stream cleanup — unchanged
//! cadence). A go2rtc drop is now noticed within one `CHECK_INTERVAL` instead
//! of up to `RECONCILE_INTERVAL`, while full reconciles stay rare in steady
//! state.

use std::collections::HashSet;
use std::time::Duration;

use anyhow::{Context, Result};

use crate::state::AppState;

/// Short-timeout client for the local go2rtc container API.
fn client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .context("build go2rtc client")
}

/// The go2rtc stream name for a camera's SUB stream.
fn sub_name(go2rtc_name: &str) -> String {
    format!("{go2rtc_name}_sub")
}

/// The go2rtc stream name for a camera's on-demand MOBILE transcode.
fn mobile_name(go2rtc_name: &str) -> String {
    format!("{go2rtc_name}_mobile")
}

/// Build the go2rtc source for a camera's `<name>_mobile` transcode. It reads
/// `input_stream` (an EXISTING go2rtc stream — the camera's sub when present,
/// else main) and re-encodes to H.264 capped at `width` px (height derived to
/// preserve aspect). Referencing the stream by NAME (go2rtc's documented
/// restream-and-transcode form, `ffmpeg:<stream>#video=h264`) shares that
/// stream's single producer, so the transcode adds no extra camera session — and
/// go2rtc only launches the ffmpeg process while a consumer is attached, so an
/// idle mobile stream costs nothing. Pure + unit-tested.
fn mobile_src(input_stream: &str, width: u32) -> String {
    format!("ffmpeg:{input_stream}#video=h264#width={width}")
}

/// PUT a stream into go2rtc (idempotent — sets/replaces the stream by name).
///
/// NOTE: go2rtc REGISTERS the stream even when it answers `400` (its immediate
/// source probe failed — e.g. the camera is briefly unreachable). So only a
/// transport error or a `5xx` means the stream wasn't submitted; `4xx` is a probe
/// warning, not a failure.
///
/// `auth` (P0-GO2RTC lighter lockdown): Basic-auth credentials for Crumb's own
/// go2rtc REST API, required now that go2rtc's API auth (`local_auth: true`)
/// applies to this call — it crosses the Docker bridge network by service
/// name, which go2rtc does not treat as "localhost".
async fn put_stream(
    c: &reqwest::Client,
    api_base: &str,
    name: &str,
    src: &str,
    auth: (&str, &str),
) -> Result<()> {
    let url = format!("{}/api/streams", api_base.trim_end_matches('/'));
    let resp = c
        .put(&url)
        .basic_auth(auth.0, Some(auth.1))
        .query(&[("name", name), ("src", src)])
        .send()
        .await
        .with_context(|| format!("PUT go2rtc stream {name} ({url})"))?;
    if resp.status().is_server_error() {
        anyhow::bail!("go2rtc PUT {name} -> HTTP {}", resp.status());
    }
    Ok(())
}

/// PATCH a stream in go2rtc — in-place `SetSource` on the stream's EXISTING
/// object, so its running producer and every attached consumer are left intact
/// (an unchanged source is a true no-op; a changed source takes effect on the
/// producer's next dial). This is the fan-out fix: `put_stream` (`PUT`)
/// UNCONDITIONALLY REPLACES the in-memory stream object, orphaning the live
/// producer + consumers — so re-`PUT`ting every stream each reconcile pass forked
/// the sharing domain, and every consumer that arrived after a `PUT` had to dial
/// the camera again (one camera RTSP session per long-lived consumer, exhausting
/// session-capped cameras). `PATCH` never replaces the object, so all consumers
/// keep sharing the single producer session. It also avoids the spurious per-`PUT`
/// `400` (go2rtc's `PUT` also calls `PatchConfig`, which fails on Crumb's
/// read-only config; `PATCH` does not).
///
/// Only valid for a stream that ALREADY exists — the caller checks presence and
/// uses [`put_stream`] to create a missing one (a fresh name orphans nothing).
/// See [`put_stream`] for why `auth` is required.
async fn patch_stream(
    c: &reqwest::Client,
    api_base: &str,
    name: &str,
    src: &str,
    auth: (&str, &str),
) -> Result<()> {
    let url = format!("{}/api/streams", api_base.trim_end_matches('/'));
    let resp = c
        .patch(&url)
        .basic_auth(auth.0, Some(auth.1))
        .query(&[("name", name), ("src", src)])
        .send()
        .await
        .with_context(|| format!("PATCH go2rtc stream {name} ({url})"))?;
    if resp.status().is_server_error() {
        anyhow::bail!("go2rtc PATCH {name} -> HTTP {}", resp.status());
    }
    Ok(())
}

/// DELETE a stream from go2rtc by name. go2rtc may answer `400`/`404` even when
/// the stream is gone, so only `5xx`/transport errors are treated as failures.
///
/// See [`put_stream`] for why `auth` is required.
async fn delete_stream(
    c: &reqwest::Client,
    api_base: &str,
    name: &str,
    auth: (&str, &str),
) -> Result<()> {
    let url = format!("{}/api/streams", api_base.trim_end_matches('/'));
    let resp = c
        .delete(&url)
        .basic_auth(auth.0, Some(auth.1))
        .query(&[("src", name)])
        .send()
        .await
        .with_context(|| format!("DELETE go2rtc stream {name} ({url})"))?;
    if resp.status().is_server_error() {
        anyhow::bail!("go2rtc DELETE {name} -> HTTP {}", resp.status());
    }
    Ok(())
}

/// GET go2rtc's currently-registered stream count (`GET /api/streams` returns
/// a JSON object keyed by stream name — same endpoint + shape the admin
/// console's "Test" probe already relies on, see
/// `config_routes.rs::test_frigate_http`).
///
/// Used only for the cold-start eager-reconcile check below — never to decide
/// what to PUT/DELETE, so a transient parse hiccup here can't corrupt the
/// managed stream set, only delay how quickly we notice go2rtc looks empty.
async fn get_stream_count(
    c: &reqwest::Client,
    api_base: &str,
    auth: (&str, &str),
) -> Result<usize> {
    let url = format!("{}/api/streams", api_base.trim_end_matches('/'));
    let resp = c
        .get(&url)
        .basic_auth(auth.0, Some(auth.1))
        .send()
        .await
        .with_context(|| format!("GET go2rtc stream count ({url})"))?;
    if !resp.status().is_success() {
        anyhow::bail!("go2rtc GET /api/streams -> HTTP {}", resp.status());
    }
    let body: serde_json::Value = resp
        .json()
        .await
        .context("parse go2rtc /api/streams response")?;
    match body {
        serde_json::Value::Object(map) => Ok(map.len()),
        _ => anyhow::bail!("go2rtc /api/streams did not return a JSON object"),
    }
}

/// GET the SET of stream names go2rtc currently has (`GET /api/streams` keys).
/// Used by [`reconcile`] to choose CREATE (`PUT`, name missing) vs in-place
/// UPDATE (`PATCH`, name present) per stream. On any error the caller falls back
/// to treating every stream as missing (PUT-all) — the pre-fan-out-fix behavior —
/// so a go2rtc that is unreachable / mid-restart still gets its full set applied.
async fn get_stream_names(
    c: &reqwest::Client,
    api_base: &str,
    auth: (&str, &str),
) -> Result<HashSet<String>> {
    let url = format!("{}/api/streams", api_base.trim_end_matches('/'));
    let resp = c
        .get(&url)
        .basic_auth(auth.0, Some(auth.1))
        .send()
        .await
        .with_context(|| format!("GET go2rtc stream names ({url})"))?;
    if !resp.status().is_success() {
        anyhow::bail!("go2rtc GET /api/streams -> HTTP {}", resp.status());
    }
    let body: serde_json::Value = resp
        .json()
        .await
        .context("parse go2rtc /api/streams response")?;
    match body {
        serde_json::Value::Object(map) => Ok(map.into_iter().map(|(k, _)| k).collect()),
        _ => anyhow::bail!("go2rtc /api/streams did not return a JSON object"),
    }
}

/// Which go2rtc verb to reconcile a managed stream with. See [`choose_verb`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StreamVerb {
    /// `PUT` — create a stream go2rtc doesn't have yet (a fresh name orphans
    /// nothing), or the rare alias-collision fallback (see [`choose_verb`]).
    Create,
    /// `PATCH` — in-place update of an existing stream, sharing its live producer.
    Patch,
}

/// Choose the verb for reconciling one managed stream (pure — unit-testable).
///
/// * name NOT present in go2rtc ⇒ [`StreamVerb::Create`] (`PUT`) — creating a
///   fresh name orphans nothing; this covers cold start and go2rtc restart.
/// * name present ⇒ [`StreamVerb::Patch`] (in-place `SetSource`, never replaces
///   the object, so the live producer + consumers are untouched) — UNLESS the
///   source would trip go2rtc's `PATCH` **alias** branch, in which case we keep
///   `PUT` so the source is applied literally rather than aliased.
fn choose_verb(present: bool, src: &str, managed_names: &HashSet<String>) -> StreamVerb {
    if !present {
        return StreamVerb::Create;
    }
    if is_patch_alias_collision(src, managed_names) {
        return StreamVerb::Create;
    }
    StreamVerb::Patch
}

/// go2rtc's `Patch()` **aliases** (instead of applying the source) when the
/// source is `rtsp://` and the URL path is a SINGLE segment matching an existing
/// stream name (`streams[u.Path[1:]]`). Real camera sources never hit this — their
/// paths have multiple segments (`media/video1`, `cam/realmonitor?…`,
/// `Streaming/Channels/101`) or a non-`rtsp` scheme (`onvif://`). The only risk is
/// an operator whose camera source is another restreamer with a single-segment
/// path equal to a managed stream name (e.g. `rtsp://other-nvr/driveway`); for
/// those we keep `PUT` so the source is applied literally, not aliased.
fn is_patch_alias_collision(src: &str, managed_names: &HashSet<String>) -> bool {
    let Some(rest) = src.strip_prefix("rtsp://") else {
        return false;
    };
    // Path after the authority (host[:port]); no '/' ⇒ no path ⇒ can't collide.
    let Some(slash) = rest.find('/') else {
        return false;
    };
    let path = rest[slash + 1..]
        .split(['?', '#'])
        .next()
        .unwrap_or("")
        .trim_end_matches('/');
    !path.is_empty() && !path.contains('/') && managed_names.contains(path)
}

/// Apply ALL Crumb-managed camera streams to go2rtc (idempotent). Called after a
/// camera add/update and periodically so the managed streams survive a go2rtc
/// restart. Never touches manually-configured streams. Per-stream errors are
/// logged but don't abort the pass (one bad camera can't block the others).
///
/// Diff-based: GET the names go2rtc already has, then `PUT` only the MISSING ones
/// and `PATCH` (in-place) the ones that exist. Re-`PUT`ting an existing stream
/// replaced its object and orphaned the live producer + consumers, so the old
/// PUT-all pass forced a fresh camera RTSP session per long-lived consumer — see
/// [`patch_stream`]. To force a real producer re-dial after a source change, use
/// [`reconnect`] (DELETE + `PUT`), not this pass.
pub async fn reconcile(state: &AppState) -> Result<()> {
    let api_base = &state.config().crumb_go2rtc_api_base;
    let auth = (
        state.config().go2rtc_user.as_str(),
        state.config().go2rtc_pass.as_str(),
    );
    let streams = crumb_common::db::list_camera_streams(state.pool()).await?;
    let c = client()?;

    // The names go2rtc already has. On error (unreachable / mid-restart), an
    // empty set ⇒ every stream is treated as missing (PUT-all) — the pre-fix
    // behavior, which is exactly what a cold/empty go2rtc needs.
    let existing = get_stream_names(&c, api_base, auth)
        .await
        .unwrap_or_default();

    let mobile_enabled = state.config().mobile_stream_enabled;
    let mobile_width = state.config().mobile_stream_width;

    // Every name WE manage (main + sub + mobile) — for the PATCH alias-collision
    // guard. (The mobile source is `ffmpeg:…`, never `rtsp://`, so it can't
    // itself alias-collide, but keeping the full managed set is correct.)
    let managed: HashSet<String> = streams
        .iter()
        .flat_map(|s| {
            let has_sub = s
                .source_sub_url
                .as_deref()
                .is_some_and(|u| !u.trim().is_empty());
            let mut names = vec![s.go2rtc_name.clone()];
            if has_sub {
                names.push(sub_name(&s.go2rtc_name));
            }
            if mobile_enabled {
                names.push(mobile_name(&s.go2rtc_name));
            }
            names
        })
        .collect();

    for s in &streams {
        apply_stream(
            &c,
            api_base,
            &s.go2rtc_name,
            &s.source_url,
            &existing,
            &managed,
            auth,
        )
        .await;
        let has_sub = s
            .source_sub_url
            .as_deref()
            .is_some_and(|u| !u.trim().is_empty());
        if has_sub {
            apply_stream(
                &c,
                api_base,
                &sub_name(&s.go2rtc_name),
                s.source_sub_url.as_deref().unwrap_or_default(),
                &existing,
                &managed,
                auth,
            )
            .await;
        }
        // On-demand mobile transcode: source the SUB stream when the camera has
        // one (already low-res), else the MAIN stream. go2rtc pulls it lazily.
        if mobile_enabled {
            let input = if has_sub {
                sub_name(&s.go2rtc_name)
            } else {
                s.go2rtc_name.clone()
            };
            apply_stream(
                &c,
                api_base,
                &mobile_name(&s.go2rtc_name),
                &mobile_src(&input, mobile_width),
                &existing,
                &managed,
                auth,
            )
            .await;
        }
    }
    Ok(())
}

/// Reconcile a single managed stream with the right verb (`PUT` to create /
/// `PATCH` to update in place), redacting credentials from any error log.
/// Per-stream failures are warned and swallowed so one bad camera can't block
/// the pass.
#[allow(clippy::too_many_arguments)]
async fn apply_stream(
    c: &reqwest::Client,
    api_base: &str,
    name: &str,
    src: &str,
    existing: &HashSet<String>,
    managed: &HashSet<String>,
    auth: (&str, &str),
) {
    let res = match choose_verb(existing.contains(name), src, managed) {
        StreamVerb::Create => put_stream(c, api_base, name, src, auth).await,
        StreamVerb::Patch => patch_stream(c, api_base, name, src, auth).await,
    };
    if let Err(e) = res {
        // `{e:#}` prints the whole context chain (".. : connection refused"), not
        // just the outermost context — the transport error is the one thing an
        // operator needs when go2rtc is down/unreachable. But reqwest embeds the
        // FULL request URL (including the `?src=<camera-url>` query, with the
        // camera's percent-encoded `user:pass@`) in that error, so redact
        // credentials before logging.
        let err = crumb_common::redact::redact_url_credentials(&format!("{e:#}"));
        tracing::warn!(stream = %name, error = %err, "go2rtc stream apply failed");
    }
}

/// Remove a camera's go2rtc streams (main + sub) — call after deleting a camera.
pub async fn remove(state: &AppState, go2rtc_name: &str) -> Result<()> {
    let api_base = &state.config().crumb_go2rtc_api_base;
    let auth = (
        state.config().go2rtc_user.as_str(),
        state.config().go2rtc_pass.as_str(),
    );
    let c = client()?;
    delete_stream(&c, api_base, go2rtc_name, auth).await?;
    delete_stream(&c, api_base, &sub_name(go2rtc_name), auth).await?;
    // Best-effort: drop the mobile transcode too (a no-op if it was never
    // registered — go2rtc DELETE tolerates a missing name).
    let _ = delete_stream(&c, api_base, &mobile_name(go2rtc_name), auth).await;
    Ok(())
}

/// Force a producer restart for a camera's streams: DELETE then PUT. `reconcile`
/// alone won't re-dial — it `PATCH`es an existing stream in place (no producer
/// restart), which is the whole point of the fan-out fix. Use this after a
/// source-URL change or a camera swap so the producer reconnects to the new source.
///
/// Implementation: DELETE main + sub, then call [`reconcile`]; the two names are
/// now MISSING, so reconcile `PUT`s them fresh from the DB (the updated
/// `source_url` takes effect on the new producer's dial).
///
/// Caveat (go2rtc `DELETE` semantics): `DELETE /api/streams` only drops the map
/// entry — a running producer with attached consumers is orphaned, not stopped.
/// So after a camera swap, consumers still bound to the OLD object keep pulling
/// the OLD source until their own watchdogs reconnect onto the fresh stream
/// (recorder: ~12 s stall watchdog). This is inherent to go2rtc's API, not
/// something reconcile can avoid without a "drain consumers" primitive go2rtc
/// doesn't expose.
pub async fn reconnect(state: &AppState, go2rtc_name: &str) -> Result<()> {
    let api_base = &state.config().crumb_go2rtc_api_base;
    let auth = (
        state.config().go2rtc_user.as_str(),
        state.config().go2rtc_pass.as_str(),
    );
    let c = client()?;
    // Ignore DELETE errors (stream may not exist yet / already gone).
    if let Err(e) = delete_stream(&c, api_base, go2rtc_name, auth).await {
        tracing::warn!(go2rtc_name, error = %format!("{e:#}"), "reconnect: DELETE main stream failed (ignoring)");
    }
    if let Err(e) = delete_stream(&c, api_base, &sub_name(go2rtc_name), auth).await {
        tracing::warn!(go2rtc_name, error = %format!("{e:#}"), "reconnect: DELETE sub stream failed (ignoring)");
    }
    // Brief pause so go2rtc drops the producer before we re-PUT.
    tokio::time::sleep(Duration::from_millis(200)).await;
    // Re-PUT all managed streams (the updated source_url is now in the DB).
    reconcile(state)
        .await
        .with_context(|| format!("go2rtc reconcile after reconnect for '{go2rtc_name}' failed"))
}

/// Resolved stream-base URLs (DB value falls back to env config when empty).
///
/// Used by `playback.rs`, `cameras.rs`, and `events.rs` to pick the correct
/// go2rtc API base + RTSP base per camera based on `served_by`.
///
/// # Finding #11 — `frigate_api_base` split
///
/// The old single `frigate_api` field conflated two distinct services:
/// * go2rtc REST API at `:1984` — for MSE/WebRTC/frame proxying.
/// * Frigate HTTP API at `:5000` — for event snapshots / event backfill.
///
/// These are now split into `frigate_go2rtc_api` (`:1984`) and
/// `frigate_http_api` (`:5000`).  The legacy `frigate_api` alias is kept for
/// code paths not yet updated and for back-compat.
pub(crate) struct Bases {
    /// RTSP base for Crumb's own go2rtc restreamer (embedded in the recorder
    /// container), e.g. `rtsp://localhost:8554` (recorder) / a host address.
    pub crumb_rtsp: String,
    /// HTTP API base for Crumb's own go2rtc, e.g. `http://recorder:1984`.
    pub crumb_api: String,
    /// RTSP base for an external Frigate-bundled go2rtc, e.g. `rtsp://frigate-host:8554`.
    pub frigate_rtsp: String,
    /// HTTP API (go2rtc REST, `:1984`) for an external Frigate-bundled go2rtc.
    /// Used for MSE/WebRTC proxying and frame.jpeg requests.
    ///
    /// In a fresh install this resolves from `server_settings.frigate_go2rtc_api_base`
    /// (migration 0014), falling back to `GO2RTC_API_BASE` env.
    pub frigate_go2rtc_api: String,
    // NB: the Frigate HTTP API base (:5000, for event snapshots) is resolved
    // independently in events.rs (server_settings.frigate_http_api_base → legacy
    // → frigate_config → env), so it is intentionally NOT carried on Bases.
}

/// Resolve stream bases from the DB `server_settings` row, falling back to env
/// config values when a DB field is empty.
///
/// This is called per-request in playback/cameras/events handlers. The DB read
/// is a single-row PK lookup (negligible cost). The env fallback ensures a fresh
/// install with no `server_settings` row works immediately.
///
/// # Finding #11 — two-field resolution
///
/// `server_settings` gains two new columns via migration 0014:
/// * `frigate_go2rtc_api_base` — seeded from `GO2RTC_API_BASE` env.
/// * `frigate_http_api_base`   — seeded from `FRIGATE_API_BASE` env.
///
/// When those fields are empty (pre-migration or not-yet-configured installs),
/// we fall back to the legacy `frigate_api_base` field so existing deployments
/// keep working without any admin reconfiguration.
pub(crate) async fn resolve_bases(state: &AppState) -> Bases {
    let cfg = state.config();
    let s = crumb_common::db::get_server_settings(state.pool())
        .await
        .ok()
        .flatten();

    let pick = |db_val: Option<String>, env_val: &str| -> String {
        db_val
            .filter(|v| !v.trim().is_empty())
            .unwrap_or_else(|| env_val.to_owned())
    };

    // Resolve Frigate go2rtc REST base (port :1984, for MSE/WebRTC/frame proxy).
    // Priority: new frigate_go2rtc_api_base → legacy frigate_api_base → GO2RTC_API_BASE env.
    let frigate_go2rtc_api = {
        // New split field (migration 0014); `String` field so check for empty.
        let from_new = s
            .as_ref()
            .map(|x| x.frigate_go2rtc_api_base.as_str())
            .filter(|v| !v.trim().is_empty())
            .map(str::to_owned);
        // Legacy unified field (back-compat for pre-0014 rows that lack the new field).
        let from_legacy = s
            .as_ref()
            .map(|x| x.frigate_api_base.as_str())
            .filter(|v| !v.trim().is_empty())
            .map(str::to_owned);
        from_new
            .or(from_legacy)
            .unwrap_or_else(|| cfg.go2rtc_api_base.clone())
    };

    Bases {
        crumb_rtsp: pick(
            s.as_ref().map(|x| x.crumb_rtsp_base.clone()),
            &cfg.crumb_go2rtc_rtsp_base,
        ),
        crumb_api: pick(
            s.as_ref().map(|x| x.crumb_api_base.clone()),
            &cfg.crumb_go2rtc_api_base,
        ),
        frigate_rtsp: pick(
            s.as_ref().map(|x| x.frigate_rtsp_base.clone()),
            &cfg.go2rtc_rtsp_base,
        ),
        frigate_go2rtc_api,
    }
}

/// Steady-state / drift-correction interval: even when the cheap poll never
/// sees a shortfall, force a full reconcile at least this often (stale-stream
/// cleanup, DB/go2rtc drift correction). Unchanged cadence from before this
/// restructure.
// `from_secs(60)` is clearer here than the pedantic-lint's suggested
// `from_mins(1)` (which is also unstable on the pinned toolchain).
#[allow(clippy::duration_suboptimal_units)]
const RECONCILE_INTERVAL: Duration = Duration::from_secs(60);

/// Base cadence of the cheap `get_stream_count` detection poll. Deliberately
/// short (vs. `RECONCILE_INTERVAL`) since a GET is negligible load — this is
/// what bounds how long a go2rtc drop can go unnoticed. See the module doc
/// comment for why this replaced the old "fast-recheck after reconcile"
/// scheme, which only sped up catch-up, not detection.
const CHECK_INTERVAL: Duration = Duration::from_secs(5);

/// Outcome of a single detection poll, used to decide whether this tick
/// should escalate to a full reconcile.
#[derive(Debug, Clone, Copy)]
enum PollOutcome {
    /// `get_stream_count` succeeded and returned a count `>= streams_expected`.
    CaughtUp,
    /// `get_stream_count` succeeded but returned a count short of what the DB
    /// expects (go2rtc just (re)started, or a stream was dropped).
    Shortfall,
    /// `get_stream_count` itself failed (go2rtc unreachable / mid-restart).
    /// Treated the same as `Shortfall` — never treated as caught up.
    CheckFailed,
}

/// Decide whether THIS tick should run a full [`reconcile`] pass (pure —
/// unit-testable without a go2rtc or DB).
///
/// * `streams_expected == 0` (no managed cameras) ⇒ never reconcile from the
///   poll loop; there is nothing to catch up to.
/// * `poll` is `Shortfall` or `CheckFailed` ⇒ reconcile now (this is the fix:
///   detection is no longer gated behind waiting out a full reconcile cycle).
/// * otherwise, reconcile only if `elapsed_since_last_reconcile >=
///   RECONCILE_INTERVAL` (periodic drift correction / stale-stream cleanup —
///   preserves the old steady-state cadence).
fn should_reconcile(
    poll: PollOutcome,
    streams_expected: usize,
    elapsed_since_last: Duration,
) -> bool {
    if streams_expected == 0 {
        return false;
    }
    match poll {
        PollOutcome::Shortfall | PollOutcome::CheckFailed => true,
        PollOutcome::CaughtUp => elapsed_since_last >= RECONCILE_INTERVAL,
    }
}

/// Spawn the reconcile loop: a cheap `get_stream_count` poll every
/// `CHECK_INTERVAL` (~5 s) that escalates to a full [`reconcile`] pass
/// immediately on a detected shortfall, on a failed check, or every
/// `RECONCILE_INTERVAL` (~60 s) regardless (drift correction) — see the
/// module doc comment for why detection and reconcile are split like this.
pub fn spawn_reconcile_loop(state: AppState) {
    tokio::spawn(async move {
        // Run a full reconcile immediately on startup so managed streams are
        // applied without waiting a full CHECK_INTERVAL first.
        if let Err(e) = reconcile(&state).await {
            tracing::warn!(error = %format!("{e:#}"), "go2rtc reconcile failed (will retry)");
        }
        let mut last_reconcile = tokio::time::Instant::now();

        loop {
            tokio::time::sleep(CHECK_INTERVAL).await;

            let streams_expected = crumb_common::db::list_camera_streams(state.pool())
                .await
                .map_or(0, |v| v.len());

            let poll = 'poll: {
                let api_base = &state.config().crumb_go2rtc_api_base;
                let auth = (
                    state.config().go2rtc_user.as_str(),
                    state.config().go2rtc_pass.as_str(),
                );
                let Ok(c) = client() else {
                    break 'poll PollOutcome::CheckFailed;
                };
                match get_stream_count(&c, api_base, auth).await {
                    Ok(n) if n >= streams_expected => PollOutcome::CaughtUp,
                    Ok(_) => PollOutcome::Shortfall,
                    Err(_) => PollOutcome::CheckFailed,
                }
            };

            let elapsed_since_last = last_reconcile.elapsed();
            if should_reconcile(poll, streams_expected, elapsed_since_last) {
                if !matches!(poll, PollOutcome::CaughtUp) {
                    // Concise, no-credentials INFO — this is the "we noticed
                    // fast" signal the whole restructure exists to produce.
                    // Per-poll steady-state ticks stay silent (no 5 s spam).
                    tracing::info!(
                        expected = streams_expected,
                        check_failed = matches!(poll, PollOutcome::CheckFailed),
                        "go2rtc stream count short of expected; reconciling"
                    );
                }
                if let Err(e) = reconcile(&state).await {
                    tracing::warn!(error = %format!("{e:#}"), "go2rtc reconcile failed (will retry)");
                }
                last_reconcile = tokio::time::Instant::now();
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> HashSet<String> {
        list.iter().copied().map(String::from).collect()
    }

    // ── mobile transcode stream (Phase 2) ───────────────────────────────────

    #[test]
    fn mobile_name_and_src_shapes() {
        assert_eq!(mobile_name("driveway"), "driveway_mobile");
        // References an existing stream by name (shares its producer) and caps width.
        assert_eq!(
            mobile_src("driveway_sub", 640),
            "ffmpeg:driveway_sub#video=h264#width=640"
        );
        assert_eq!(
            mobile_src("driveway", 480),
            "ffmpeg:driveway#video=h264#width=480"
        );
    }

    #[test]
    fn mobile_src_is_never_an_rtsp_alias_collision() {
        // The mobile source is an `ffmpeg:` string, not `rtsp://`, so the PATCH
        // alias-collision guard never fires for it — it PATCHes in place like any
        // other existing managed stream.
        let managed = names(&["driveway", "driveway_sub", "driveway_mobile"]);
        assert!(!is_patch_alias_collision(
            &mobile_src("driveway_sub", 640),
            &managed
        ));
        assert_eq!(
            choose_verb(true, &mobile_src("driveway_sub", 640), &managed),
            StreamVerb::Patch
        );
    }

    // ── choose_verb (create-vs-patch fan-out fix) ───────────────────────────

    #[test]
    fn missing_stream_is_created() {
        // Not present in go2rtc (cold start / go2rtc restart) ⇒ PUT to create.
        // A fresh name orphans nothing.
        let managed = names(&["lpr", "lpr_sub"]);
        assert_eq!(
            choose_verb(
                false,
                "rtsp://admin:pw@192.0.2.6:554/media/video1",
                &managed
            ),
            StreamVerb::Create
        );
    }

    #[test]
    fn present_stream_is_patched_not_replaced() {
        // The core of the fan-out fix: an existing stream is PATCHed in place
        // (in-place SetSource), never PUT — a PUT would replace the object and
        // orphan the live producer + consumers, forcing a fresh camera session.
        let managed = names(&["lpr", "lpr_sub"]);
        assert_eq!(
            choose_verb(true, "rtsp://admin:pw@192.0.2.6:554/media/video1", &managed),
            StreamVerb::Patch
        );
    }

    #[test]
    fn alias_collision_falls_back_to_put() {
        // Source is another restreamer whose single-segment path equals a
        // managed stream name — go2rtc's PATCH would ALIAS instead of applying
        // the source, so we keep PUT even though the stream already exists.
        let managed = names(&["driveway", "lpr"]);
        assert!(is_patch_alias_collision(
            "rtsp://other-nvr:8554/driveway",
            &managed
        ));
        assert_eq!(
            choose_verb(true, "rtsp://other-nvr:8554/driveway", &managed),
            StreamVerb::Create
        );
    }

    #[test]
    fn real_camera_sources_never_alias_collide() {
        // Managed names deliberately include segments that appear inside real
        // camera paths, to prove only a whole single-segment path collides.
        let managed = names(&["driveway", "media", "video1", "channels", "101"]);
        // Multi-segment RTSP paths (the common camera shapes) never collide.
        assert!(!is_patch_alias_collision(
            "rtsp://admin:pw@192.0.2.6:554/media/video1",
            &managed
        ));
        assert!(!is_patch_alias_collision(
            "rtsp://192.0.2.5/cam/realmonitor?channel=1&subtype=0",
            &managed
        ));
        assert!(!is_patch_alias_collision(
            "rtsp://192.0.2.8/Streaming/Channels/101",
            &managed
        ));
        // Non-rtsp scheme is never aliased.
        assert!(!is_patch_alias_collision(
            "onvif://admin:pw@192.0.2.5",
            &managed
        ));
        // rtsp with NO path can't collide.
        assert!(!is_patch_alias_collision("rtsp://192.0.2.6:554", &managed));
        // Single-segment path that isn't a managed name ⇒ no collision.
        assert!(!is_patch_alias_collision("rtsp://cam/whatever", &managed));
        // A single-segment path that IS a managed name ⇒ collision (guard fires).
        assert!(is_patch_alias_collision("rtsp://cam/driveway", &managed));
        // Trailing slash is trimmed before the single-segment check.
        assert!(is_patch_alias_collision("rtsp://cam/driveway/", &managed));
    }

    // ── should_reconcile (detection vs. reconcile decoupling) ───────────────

    #[test]
    fn zero_cameras_never_reconciles_from_poll() {
        // No managed cameras: nothing to catch up to, and no drift to
        // correct — the poll loop must never trigger a reconcile, even if
        // the check somehow reports a shortfall or a long time has passed.
        assert!(!should_reconcile(
            PollOutcome::Shortfall,
            0,
            Duration::from_secs(1_000)
        ));
        assert!(!should_reconcile(
            PollOutcome::CaughtUp,
            0,
            RECONCILE_INTERVAL
        ));
    }

    #[test]
    fn shortfall_triggers_immediate_reconcile() {
        // The prod signature: recorder just restarted, go2rtc reports 0 of 22
        // expected streams. Must reconcile THIS tick, regardless of how
        // recently the last full reconcile ran.
        assert!(should_reconcile(
            PollOutcome::Shortfall,
            22,
            Duration::from_secs(0)
        ));
    }

    #[test]
    fn check_failed_triggers_immediate_reconcile() {
        // go2rtc unreachable during the GET itself (e.g. mid-restart) must be
        // treated exactly like a shortfall, not ignored.
        assert!(should_reconcile(
            PollOutcome::CheckFailed,
            22,
            Duration::from_secs(0)
        ));
    }

    #[test]
    fn periodic_elapsed_triggers_reconcile_even_when_caught_up() {
        // Drift correction / stale-stream cleanup: even when go2rtc has
        // everything expected, force a full reconcile once RECONCILE_INTERVAL
        // has elapsed since the last one.
        assert!(should_reconcile(
            PollOutcome::CaughtUp,
            22,
            RECONCILE_INTERVAL
        ));
        assert!(should_reconcile(
            PollOutcome::CaughtUp,
            22,
            RECONCILE_INTERVAL + Duration::from_secs(1)
        ));
    }

    #[test]
    fn steady_caught_up_does_not_reconcile() {
        // Caught up and well within the periodic window: no reconcile this
        // tick — this is what keeps full reconciles rare in steady state.
        assert!(!should_reconcile(
            PollOutcome::CaughtUp,
            22,
            Duration::from_secs(5)
        ));
    }
}
