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

/// The go2rtc stream name for a camera's CLIENT-facing, VIDEO-ONLY sub restream
/// (`<name>_subv`). `pub(crate)` because `playback.rs` builds the client
/// `rtsp_subv_url` from it — the two must never drift apart.
///
/// Registered ONLY for cameras whose sub actually needs the repair, as detected
/// per-pass by [`sdp_video_lacks_fmtp`]. See [`reconcile`].
pub(crate) fn subv_name(go2rtc_name: &str) -> String {
    format!("{go2rtc_name}_subv")
}

/// The go2rtc stream name for a camera's on-demand MOBILE transcode.
fn mobile_name(go2rtc_name: &str) -> String {
    format!("{go2rtc_name}_mobile")
}

/// Build the go2rtc source for a camera's `<name>_subv` — the video-only sub
/// restream the ANDROID live wall plays for the FEW cameras that need it (#483).
/// Desktop and iOS stay on the raw `<name>_sub`; see `playback.rs`'s
/// `rtsp_subv_url` for why the choice is the client's.
///
/// It reads the EXISTING `<name>_sub` stream by name (go2rtc's documented
/// restream form), so it shares that stream's single producer and adds no extra
/// camera session; go2rtc only spawns the ffmpeg process while a consumer is
/// attached, so an idle `_subv` costs nothing.
///
/// `#video=copy` is a **remux, never a re-encode** (verified against a live
/// camera: identical h264/High/640x360 in and out). Two things come out of it,
/// both required:
///
/// * **Audio is dropped** — go2rtc passes `-an` when no `#audio` is requested.
///   The wall is muted, and two-way audio / listen uses the WebRTC path.
/// * **The H264 parameter sets are recovered.** Some cameras (verified: Reolink)
///   advertise an H264 track with NO `sprop-parameter-sets`, and go2rtc's plain
///   restream passes that gap straight through — so `<name>_sub` publishes a
///   video track with no `a=fmtp` line at all (ffprobe on such a stream reports
///   "non-existing PPS 0 referenced / no frame!"). Android Media3 requires fmtp
///   and throws `IllegalArgumentException: missing attribute fmtp`, so the tile
///   reconnect-loops forever. Passing the bitstream through ffmpeg recovers the
///   in-band SPS/PPS, and go2rtc then republishes a proper
///   `a=fmtp:96 …sprop-parameter-sets=…`.
///
/// Deliberately NOT an `rtsp://…/<name>_sub?video` source: that form also yields
/// a video-only SDP, but it leaves the video track's fmtp missing (so Media3
/// still fails), and its single-segment path collides with a managed stream name,
/// which would force reconcile down the `PUT` path forever (see
/// [`is_patch_alias_collision`]). An `ffmpeg:` source can never alias-collide, so
/// `_subv` `PATCH`es in place exactly like `_mobile`. Pure + unit-tested.
fn subv_src(sub_stream: &str) -> String {
    format!("ffmpeg:{sub_stream}#video=copy")
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
    // `#audio=aac` transcodes audio too (go2rtc drops audio with `-an` when no
    // `#audio` is given). This matters for the no-sub case, where the mobile
    // stream sources the MAIN stream whose audio the viewer expects; AAC is safer
    // than a copy (which could pass through G.711 an RTSP client can't decode).
    format!("ffmpeg:{input_stream}#video=h264#width={width}#audio=aac")
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

/// What one `GET /api/streams` pass tells us about go2rtc's current state.
///
/// Both fields come out of the SAME response, deliberately: the reconcile pass
/// already had to fetch the stream names, and go2rtc includes each producer's
/// raw SDP in that payload, so detecting broken subs costs **zero** extra
/// requests and cannot itself slow a pass down or dial a camera.
#[derive(Debug, Default)]
struct StreamIndex {
    /// The stream names go2rtc currently has (the JSON object's keys).
    names: HashSet<String>,
    /// Per stream name, a DEFINITE verdict on its producer's video track:
    /// `true` ⇒ the SDP advertises video with no `a=fmtp` (needs the `_subv`
    /// repair), `false` ⇒ it has one. A name is ABSENT when no verdict could be
    /// reached — no producer attached yet, no SDP, or no video section — which
    /// callers must treat as "don't know", never as "broken".
    video_lacks_fmtp: std::collections::HashMap<String, bool>,
}

/// Does this SDP describe a video track with NO `a=fmtp` attribute?
///
/// `None` ⇒ no verdict (empty SDP, or no `m=video` section at all). `Some(true)`
/// ⇒ the video track carries no `a=fmtp` line, which is exactly the condition
/// that makes Android's Media3 RTSP client throw
/// `IllegalArgumentException: missing attribute fmtp` and reconnect-loop the
/// tile forever (#483). Such a stream has no out-of-band parameter sets at all
/// (ffprobe on it reports "non-existing PPS 0 referenced / no frame!").
///
/// Attributes belong to the media section they follow, so this walks sections
/// rather than scanning the whole SDP: a `a=fmtp` on the AUDIO track must not
/// make a broken video track look healthy. Session-level lines (before the
/// first `m=`) are skipped for the same reason. Pure + unit-tested against real
/// SDPs from the reference install.
fn sdp_video_lacks_fmtp(sdp: &str) -> Option<bool> {
    let mut in_video = false;
    let mut saw_video = false;
    let mut has_fmtp = false;
    for line in sdp.lines() {
        let line = line.trim_end_matches('\r');
        if let Some(media) = line.strip_prefix("m=") {
            // A second video section would be unusual; the first one is the one
            // a player builds its track from, so stop looking after it ends.
            if saw_video {
                break;
            }
            in_video = media.starts_with("video");
            saw_video |= in_video;
        } else if in_video && line.to_ascii_lowercase().starts_with("a=fmtp:") {
            has_fmtp = true;
        }
    }
    saw_video.then_some(!has_fmtp)
}

/// Reach a verdict for one entry of go2rtc's `/api/streams` object.
///
/// A stream can have several producers (go2rtc keeps one per source). We take
/// the FIRST producer that yields a verdict: they all restream the same camera,
/// and a stream with no producer attached yet yields `None` (unknown) rather
/// than a guess. Pure + unit-tested.
fn stream_video_lacks_fmtp(entry: &serde_json::Value) -> Option<bool> {
    entry
        .get("producers")?
        .as_array()?
        .iter()
        .filter_map(|p| p.get("sdp")?.as_str())
        .find_map(sdp_video_lacks_fmtp)
}

/// GET go2rtc's current stream index (`GET /api/streams`) — the names it has,
/// plus the per-stream SDP verdict described on [`StreamIndex`].
///
/// [`reconcile`] uses the names to choose CREATE (`PUT`, name missing) vs
/// in-place UPDATE (`PATCH`, name present) per stream. On any error the caller
/// falls back to an empty index, so every stream is treated as missing (PUT-all,
/// the pre-fan-out-fix behavior) and every verdict is "unknown" — a go2rtc that
/// is unreachable / mid-restart still gets its full set applied, and no camera
/// is newly accused of needing the repair.
async fn get_stream_index(
    c: &reqwest::Client,
    api_base: &str,
    auth: (&str, &str),
) -> Result<StreamIndex> {
    let url = format!("{}/api/streams", api_base.trim_end_matches('/'));
    let resp = c
        .get(&url)
        .basic_auth(auth.0, Some(auth.1))
        .send()
        .await
        .with_context(|| format!("GET go2rtc stream index ({url})"))?;
    if !resp.status().is_success() {
        anyhow::bail!("go2rtc GET /api/streams -> HTTP {}", resp.status());
    }
    let body: serde_json::Value = resp
        .json()
        .await
        .context("parse go2rtc /api/streams response")?;
    match body {
        serde_json::Value::Object(map) => Ok(index_from_streams(&map)),
        _ => anyhow::bail!("go2rtc /api/streams did not return a JSON object"),
    }
}

/// Decide whether a camera needs the `_subv` repair, given THIS pass's verdict
/// for its `_sub` stream and what we believed last pass.
///
/// * a definite verdict always wins — this is how a camera gets flagged, and how
///   it gets un-flagged again after a firmware fix or a camera swap;
/// * `None` (unknown: no producer attached yet, no SDP, no video section) is
///   STICKY. A `_sub` between producers must not silently lose a repair a live
///   Android session is currently playing, nor gain one it never needed;
/// * unknown with nothing remembered ⇒ `false`. That is the fail-safe
///   direction: the client falls back to the always-warm raw sub, exactly as it
///   behaved before #483, instead of every camera paying for a lazy remux.
///
/// Pure + unit-tested.
fn resolve_needs_subv(verdict: Option<bool>, previously_needed: bool) -> bool {
    verdict.unwrap_or(previously_needed)
}

/// Build a [`StreamIndex`] from go2rtc's `/api/streams` object (pure — split out
/// so the parse is unit-testable against captured payloads without a go2rtc).
fn index_from_streams(map: &serde_json::Map<String, serde_json::Value>) -> StreamIndex {
    let mut idx = StreamIndex {
        names: map.keys().cloned().collect(),
        ..StreamIndex::default()
    };
    for (name, entry) in map {
        if let Some(lacks) = stream_video_lacks_fmtp(entry) {
            idx.video_lacks_fmtp.insert(name.clone(), lacks);
        }
    }
    idx
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
    // Hold the reconcile/teardown lock for the whole read-then-apply pass. This
    // pass is additive (PUT every DB stream, never prune), so without this a
    // camera delete's stream teardown could land *between* our stream-list read
    // and our PUTs and be undone — resurrecting the deleted camera's stream
    // permanently (#294). `remove()` takes the same lock.
    let lock = state.go2rtc_reconcile_lock();
    let _guard = lock.lock().await;

    let api_base = &state.config().crumb_go2rtc_api_base;
    let auth = (
        state.config().go2rtc_user.as_str(),
        state.config().go2rtc_pass.as_str(),
    );
    let streams = crumb_common::db::list_camera_streams(state.pool()).await?;
    let c = client()?;

    // What go2rtc currently has: stream names, plus the per-stream SDP verdict
    // used below to decide who needs `_subv`. On error (unreachable /
    // mid-restart), an empty index ⇒ every stream is treated as missing
    // (PUT-all, the pre-fix behavior, exactly what a cold/empty go2rtc needs)
    // and every verdict is "unknown" (see `needs_subv`).
    let index = get_stream_index(&c, api_base, auth)
        .await
        .unwrap_or_default();
    let existing = &index.names;

    let mobile_enabled = state.config().mobile_stream_enabled;
    let mobile_width = state.config().mobile_stream_width;

    // Which cameras actually need the video-only `_subv` repair, this pass.
    //
    // #483 follow-up: the first cut of `_subv` registered it for EVERY camera
    // with a sub and pointed the client at it, which meant an eleven-tile
    // Android wall cold-spawned eleven lazy ffmpeg remuxes on open. On the
    // reference install exactly ONE camera of eleven publishes H264 with no
    // `sprop-parameter-sets` — the rest were always fine on the raw `_sub`. So
    // detect the broken ones and repair only those.
    //
    // `resolve_needs_subv` is STICKY across an unknown verdict: a camera whose
    // `_sub` has no producer attached at this instant (cold start, mid-redial)
    // keeps whatever it was last known to be, so a transient blind spot can
    // never tear down a working repair mid-session — nor invent one. Never seen
    // at all ⇒ not needed, which is the safe default: the client falls back to
    // the always-warm raw sub and is no worse off than before #483.
    let mut needs_subv: std::collections::HashMap<&str, bool> =
        std::collections::HashMap::with_capacity(streams.len());
    for s in &streams {
        let has_sub = s
            .source_sub_url
            .as_deref()
            .is_some_and(|u| !u.trim().is_empty());
        let needed = has_sub
            && resolve_needs_subv(
                index
                    .video_lacks_fmtp
                    .get(&sub_name(&s.go2rtc_name))
                    .copied(),
                state.subv_needed(&s.go2rtc_name),
            );
        needs_subv.insert(s.go2rtc_name.as_str(), needed);
        state.set_subv_needed(&s.go2rtc_name, needed);
    }
    // Forget cameras that no longer exist (deleted between passes).
    state.retain_subv_needed(&streams.iter().map(|s| s.go2rtc_name.clone()).collect());

    // Every name WE manage (main + sub + mobile) — for the PATCH alias-collision
    // guard. (The mobile source is `ffmpeg:…`, never `rtsp://`, so it can't
    // itself alias-collide, but keeping the full managed set is correct.)
    // `_subv` is only ours for cameras we are actually repairing.
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
            if needs_subv
                .get(s.go2rtc_name.as_str())
                .copied()
                .unwrap_or(false)
            {
                names.push(subv_name(&s.go2rtc_name));
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
            existing,
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
                existing,
                &managed,
                auth,
            )
            .await;
        }
        // #483 follow-up: the client-facing VIDEO-ONLY sub, derived from the
        // `_sub` stream above — registered ONLY for a camera whose sub actually
        // publishes video with no `a=fmtp`, and DELETED again the moment it
        // stops needing it (a firmware update, or a camera swapped behind the
        // same row). Keeping a stale `_subv` around would be harmless to
        // go2rtc but would leave `playback.rs` free to advertise a stream we no
        // longer maintain, so the two are kept in lockstep here.
        let subv = subv_name(&s.go2rtc_name);
        if needs_subv
            .get(s.go2rtc_name.as_str())
            .copied()
            .unwrap_or(false)
        {
            apply_stream(
                &c,
                api_base,
                &subv,
                &subv_src(&sub_name(&s.go2rtc_name)),
                existing,
                &managed,
                auth,
            )
            .await;
        } else if existing.contains(&subv) {
            // Best-effort: a failed DELETE just leaves an idle, consumerless
            // stream that costs nothing and gets retried next pass.
            if let Err(e) = delete_stream(&c, api_base, &subv, auth).await {
                tracing::warn!(
                    stream = %subv,
                    error = %crumb_common::redact::redact_url_credentials(&format!("{e:#}")),
                    "go2rtc: dropping no-longer-needed video-only sub failed (will retry)"
                );
            } else {
                tracing::info!(stream = %subv, "go2rtc: sub no longer needs the fmtp repair; removed");
            }
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
                existing,
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
    // Serialize teardown against a reconcile pass (#294): a pass that snapshotted
    // this camera before the delete must not re-PUT its stream after we tear it
    // down. Holding the same lock reconcile() takes means the two never
    // interleave — the pass either finishes before we delete, or reads the
    // post-delete camera set and never re-adds us.
    let lock = state.go2rtc_reconcile_lock();
    let _guard = lock.lock().await;

    let api_base = &state.config().crumb_go2rtc_api_base;
    let auth = (
        state.config().go2rtc_user.as_str(),
        state.config().go2rtc_pass.as_str(),
    );
    let c = client()?;
    delete_stream(&c, api_base, go2rtc_name, auth).await?;
    delete_stream(&c, api_base, &sub_name(go2rtc_name), auth).await?;
    // Best-effort: drop the video-only client sub too (a no-op if the camera
    // never had a sub — go2rtc DELETE tolerates a missing name).
    let _ = delete_stream(&c, api_base, &subv_name(go2rtc_name), auth).await;
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
    // The video-only client sub is derived from `_sub`, so it must be re-dialled
    // with it (its ffmpeg reader is bound to the old `_sub` object otherwise).
    if let Err(e) = delete_stream(&c, api_base, &subv_name(go2rtc_name), auth).await {
        tracing::warn!(go2rtc_name, error = %format!("{e:#}"), "reconnect: DELETE video-only sub stream failed (ignoring)");
    }
    // Drop the mobile transcode too, so a source-URL change re-derives it fresh
    // (its input stream name is unchanged, but symmetry with reconcile's PUT-all
    // keeps the managed set consistent). Best-effort.
    if let Err(e) = delete_stream(&c, api_base, &mobile_name(go2rtc_name), auth).await {
        tracing::warn!(go2rtc_name, error = %format!("{e:#}"), "reconnect: DELETE mobile stream failed (ignoring)");
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
            "ffmpeg:driveway_sub#video=h264#width=640#audio=aac"
        );
        assert_eq!(
            mobile_src("driveway", 480),
            "ffmpeg:driveway#video=h264#width=480#audio=aac"
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

    // ── detecting WHICH subs need the repair (#483 follow-up) ───────────────

    /// The real SDP of the one broken camera on the reference install (a
    /// Reolink), IPs genericised. Note the shape that makes this test matter:
    /// the VIDEO track has no `a=fmtp`, but the AUDIO track below it does. A
    /// naive `sdp.contains("a=fmtp:")` would call this stream healthy and the
    /// Android tile would go on reconnect-looping forever.
    const SDP_BROKEN: &str = "v=0\r\n\
        o=- 1786058169509450 1 IN IP4 192.0.2.12\r\n\
        s=Session streamed by \"preview\"\r\n\
        i=reolink rtsp stream\r\n\
        t=0 0\r\n\
        a=control:*\r\n\
        m=video 0 RTP/AVP 96\r\n\
        c=IN IP4 0.0.0.0\r\n\
        a=rtpmap:96 H264/90000\r\n\
        a=control:track1\r\n\
        m=audio 0 RTP/AVP 97\r\n\
        a=rtpmap:97 MPEG4-GENERIC/16000\r\n\
        a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr\r\n\
        a=control:track2\r\n";

    /// A healthy camera's real SDP (same install), IPs genericised.
    const SDP_HEALTHY: &str = "v=0\r\n\
        o=- 1785682862462808 1 IN IP4 192.0.2.4\r\n\
        t=0 0\r\n\
        a=control:*\r\n\
        m=video 0 RTP/AVP 96\r\n\
        c=IN IP4 0.0.0.0\r\n\
        a=rtpmap:96 H264/90000\r\n\
        a=fmtp:96 packetization-mode=1;profile-level-id=640033;sprop-parameter-sets=Z2QAM6wVFKCgL/lQ,aO48sA==\r\n\
        a=control:track1\r\n\
        m=audio 0 RTP/AVP 97\r\n\
        a=rtpmap:97 MPEG4-GENERIC/16000\r\n\
        a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr\r\n\
        a=control:track2\r\n";

    #[test]
    fn sdp_verdict_reads_the_video_section_only() {
        // The whole point: audio fmtp must not mask a missing video fmtp.
        assert_eq!(sdp_video_lacks_fmtp(SDP_BROKEN), Some(true));
        assert_eq!(sdp_video_lacks_fmtp(SDP_HEALTHY), Some(false));
        assert!(
            SDP_BROKEN.contains("a=fmtp:"),
            "fixture must keep the audio fmtp that makes a naive scan wrong",
        );
    }

    #[test]
    fn sdp_verdict_is_unknown_without_a_video_section() {
        // No verdict is NOT a "broken" verdict — an audio-only or empty SDP must
        // never flag a camera into paying for a remux.
        assert_eq!(sdp_video_lacks_fmtp(""), None);
        assert_eq!(
            sdp_video_lacks_fmtp("v=0\r\nm=audio 0 RTP/AVP 97\r\na=fmtp:97 x\r\n"),
            None,
        );
        // Session-level attributes before the first `m=` belong to no track.
        assert_eq!(sdp_video_lacks_fmtp("v=0\r\na=fmtp:96 stray\r\n"), None);
    }

    #[test]
    fn sdp_verdict_tolerates_lf_only_and_case() {
        assert_eq!(
            sdp_video_lacks_fmtp("v=0\nm=video 0 RTP/AVP 96\na=rtpmap:96 H264/90000\n"),
            Some(true),
        );
        assert_eq!(
            sdp_video_lacks_fmtp("v=0\nm=video 0 RTP/AVP 96\nA=FMTP:96 packetization-mode=1\n"),
            Some(false),
        );
    }

    #[test]
    fn stream_verdict_walks_producers() {
        let broken = serde_json::json!({ "producers": [{ "sdp": SDP_BROKEN }] });
        let healthy = serde_json::json!({ "producers": [{ "sdp": SDP_HEALTHY }] });
        assert_eq!(stream_video_lacks_fmtp(&broken), Some(true));
        assert_eq!(stream_video_lacks_fmtp(&healthy), Some(false));

        // No producer attached yet (the cold-start / lazily-dialled case) is the
        // single most likely reason for an unknown verdict, and must stay unknown.
        assert_eq!(
            stream_video_lacks_fmtp(&serde_json::json!({ "producers": [] })),
            None,
        );
        assert_eq!(stream_video_lacks_fmtp(&serde_json::json!({})), None);
        assert_eq!(stream_video_lacks_fmtp(&serde_json::Value::Null), None);
        // A producer with no SDP is skipped in favour of one that has it.
        let mixed = serde_json::json!({
            "producers": [{ "url": "rtsp://cam/1" }, { "sdp": SDP_BROKEN }],
        });
        assert_eq!(stream_video_lacks_fmtp(&mixed), Some(true));
    }

    #[test]
    fn index_carries_names_and_only_definite_verdicts() {
        let body = serde_json::json!({
            "famroom_sub":  { "producers": [{ "sdp": SDP_BROKEN }] },
            "backdoor_sub": { "producers": [{ "sdp": SDP_HEALTHY }] },
            "garage_sub":   { "producers": [] },
        });
        let idx = index_from_streams(body.as_object().unwrap());
        assert_eq!(
            idx.names,
            names(&["famroom_sub", "backdoor_sub", "garage_sub"]),
        );
        assert_eq!(idx.video_lacks_fmtp.get("famroom_sub"), Some(&true));
        assert_eq!(idx.video_lacks_fmtp.get("backdoor_sub"), Some(&false));
        // Producerless ⇒ NO entry at all, so the caller sees "unknown", not false.
        assert_eq!(idx.video_lacks_fmtp.get("garage_sub"), None);
    }

    #[test]
    fn needs_subv_defaults_off_and_is_sticky_while_unknown() {
        // A definite verdict always wins, in both directions.
        assert!(resolve_needs_subv(Some(true), false), "flag on detection");
        assert!(
            !resolve_needs_subv(Some(false), true),
            "un-flag once the camera reports fmtp again",
        );
        // Unknown keeps what we had: never tear down a repair a live Android
        // session is playing just because the producer blinked...
        assert!(resolve_needs_subv(None, true));
        // ...and never invent one. Nothing known ⇒ nothing to repair, which is
        // the whole fail-safe posture of this feature.
        assert!(!resolve_needs_subv(None, false));
    }

    // ── video-only client sub (#483) ────────────────────────────────────────

    #[test]
    fn subv_name_and_src_shapes() {
        assert_eq!(subv_name("famroom"), "famroom_subv");
        // Sources the EXISTING `_sub` stream by name (shares its producer) and
        // COPIES video. No `#audio` ⇒ go2rtc passes `-an` ⇒ audio dropped.
        assert_eq!(
            subv_src(&sub_name("famroom")),
            "ffmpeg:famroom_sub#video=copy"
        );
    }

    #[test]
    fn subv_src_is_a_copy_not_a_transcode() {
        // Guard against someone "helpfully" turning this into a re-encode: the
        // whole point is a remux that recovers SPS/PPS at zero decode cost.
        let src = subv_src(&sub_name("driveway"));
        assert!(src.contains("#video=copy"), "must copy, got: {src}");
        assert!(!src.contains("#video=h264"), "must not re-encode: {src}");
        assert!(!src.contains("#audio"), "must not request audio: {src}");
    }

    #[test]
    fn subv_src_is_never_an_rtsp_alias_collision() {
        // The reason `_subv` uses an `ffmpeg:` source rather than
        // `rtsp://…/<name>_sub?video`: an rtsp source whose single-segment path
        // equals a managed stream name trips the alias guard, which would force
        // PUT (object replacement) on EVERY reconcile pass. An `ffmpeg:` source
        // can't alias-collide, so `_subv` PATCHes in place like `_mobile`.
        let managed = names(&["famroom", "famroom_sub", "famroom_subv"]);
        assert!(!is_patch_alias_collision(
            &subv_src(&sub_name("famroom")),
            &managed
        ));
        assert_eq!(
            choose_verb(true, &subv_src(&sub_name("famroom")), &managed),
            StreamVerb::Patch
        );
        // ...whereas the rejected rtsp form WOULD collide (documents the trap).
        assert!(is_patch_alias_collision(
            "rtsp://127.0.0.1:8554/famroom_sub?video",
            &managed
        ));
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
