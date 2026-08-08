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

/// The go2rtc stream name for a camera's CLIENT-facing REPAIRED MAIN
/// (`<name>_mainv`). `pub(crate)` because `playback.rs` builds the client
/// `rtsp_mainv_url` from it — the two must never drift apart.
///
/// Registered ONLY when `main_repair_transcode_enabled` is on AND the reconcile
/// pass has detected that the SDP go2rtc SERVES for the main lacks video `fmtp`
/// (per-camera — see [`stream_served_video_lacks_fmtp`]). See [`reconcile`].
pub(crate) fn mainv_name(go2rtc_name: &str) -> String {
    format!("{go2rtc_name}_mainv")
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

/// Build the go2rtc source for a camera's `<name>_mainv` — the client-facing
/// REPAIRED MAIN the Android live client plays for a camera whose real main
/// Media3 cannot bring up (`IllegalArgumentException: missing attribute fmtp`).
///
/// It reads the EXISTING `<name>` main stream by name (go2rtc's documented
/// restream-and-transcode form), so it shares that stream's single producer and
/// adds no extra camera session; go2rtc only spawns the ffmpeg process while a
/// consumer is attached, so an idle `_mainv` costs nothing.
///
/// **This is a TRANSCODE (`#video=h264`), not a copy — and that difference is the
/// whole point.** The obvious cheaper mirror of [`subv_src`]
/// (`ffmpeg:<name>#video=copy`) does fix the missing `fmtp` (the copy re-extracts
/// the H.265 parameter sets so go2rtc republishes `sprop-vps/sps/pps`), but go2rtc
/// then bundles those parameter sets into an RTP **Aggregation Packet** at every
/// keyframe, and Media3's `RtpH265Reader` has never implemented AP depacketization
/// (androidx/media#1008) — so the copy-remux only trades the fmtp rejection for a
/// `processAggregationPacket` crash. Verified on a real LPR H.265 stream
/// (2026-08-08): the raw main and a copy-remux both stay unplayable on Media3;
/// only re-encoding to H.264 produces a main this device can decode. No `#width`,
/// so the transcode stays at the source resolution (this is the HD rung); `#audio=aac`
/// keeps audio in a form an RTSP client can play, as [`mobile_src`] does.
/// Pure + unit-tested.
fn mainv_src(main_stream: &str) -> String {
    format!("ffmpeg:{main_stream}#video=h264#audio=aac")
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

/// Longest go2rtc error body we keep when reporting a rejected stream. go2rtc's
/// own rejections are one short line ("streams: source with spaces may be
/// insecure"); the cap only exists so a misconfigured `crumb_api_base` pointing
/// at something that answers with an HTML error page cannot dump a page into the
/// log and the `system_events` detail.
const MAX_GO2RTC_ERROR_BODY: usize = 200;

/// Why one managed stream failed to apply — the distinction that decides whether
/// an operator gets a per-camera alert (issue #519).
///
/// [`ApplyError::Rejected`] is CAMERA-SPECIFIC and actionable: go2rtc answered a
/// `4xx` and, on confirmation, does not have the stream. That camera records
/// nothing until its source is fixed, and the reason (from go2rtc's body) is
/// something the operator can act on — so it raises `camera_stream_rejected`.
///
/// [`ApplyError::Unavailable`] is NOT camera-specific: a transport error or a
/// `5xx` means go2rtc couldn't be asked at all, which affects every camera at
/// once. Raising a per-camera alert for it would page the operator N times for
/// one fault, so it is logged only — exactly the pre-#519 behavior for these
/// cases. `recorder_offline` / `camera_offline` remain the signals for a
/// restreamer that is down.
#[derive(Debug)]
enum ApplyError {
    Rejected(String),
    Unavailable(String),
}

impl std::fmt::Display for ApplyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rejected(m) | Self::Unavailable(m) => f.write_str(m),
        }
    }
}

/// Turn go2rtc's refusal of a stream into one operator-readable line.
///
/// The body is the whole point (issue #519): go2rtc's status code alone says
/// nothing, but its body names the actual reason — `"streams: source with spaces
/// may be insecure"` for the very common case of an RTSP URL pasted out of a
/// camera's web UI with a literal space in the path. Whitespace is collapsed so
/// a multi-line body stays one log line / one alert detail, credentials are
/// redacted (a body that echoes the source would otherwise leak the camera
/// password), and the result is truncated to [`MAX_GO2RTC_ERROR_BODY`].
///
/// Pure + unit-tested; the network half is exercised by the `put_stream` tests
/// against a stub go2rtc.
fn go2rtc_reject_reason(status: reqwest::StatusCode, body: &str) -> String {
    let collapsed = body.split_whitespace().collect::<Vec<_>>().join(" ");
    let redacted = crumb_common::redact::redact_url_credentials(&collapsed);
    if redacted.is_empty() {
        return format!("HTTP {status}");
    }
    let mut short: String = redacted.chars().take(MAX_GO2RTC_ERROR_BODY).collect();
    if redacted.chars().count() > MAX_GO2RTC_ERROR_BODY {
        short.push('…');
    }
    format!("HTTP {status}: {short}")
}

/// Is `name` currently registered in go2rtc? Used only to interpret a non-success
/// `PUT` (see [`put_stream`]) — never to decide what to apply.
async fn stream_exists(
    c: &reqwest::Client,
    api_base: &str,
    name: &str,
    auth: (&str, &str),
) -> Result<bool> {
    let url = format!("{}/api/streams", api_base.trim_end_matches('/'));
    let resp = c
        .get(&url)
        .basic_auth(auth.0, Some(auth.1))
        .send()
        .await
        .with_context(|| format!("GET go2rtc streams to confirm {name} ({url})"))?;
    if !resp.status().is_success() {
        anyhow::bail!("go2rtc GET /api/streams -> HTTP {}", resp.status());
    }
    let body: serde_json::Value = resp
        .json()
        .await
        .context("parse go2rtc /api/streams response")?;
    match body {
        serde_json::Value::Object(map) => Ok(map.contains_key(name)),
        _ => anyhow::bail!("go2rtc /api/streams did not return a JSON object"),
    }
}

/// PUT a stream into go2rtc (idempotent — sets/replaces the stream by name).
///
/// # A non-success status is not, on its own, proof of anything (issue #519)
///
/// go2rtc answers a `4xx` in two completely different situations:
///
/// * **The stream WAS registered.** Its immediate source probe failed (camera
///   briefly unreachable), or its post-registration `PatchConfig` failed because
///   Crumb mounts `go2rtc.yaml` read-only — see [`patch_stream`]. Recording is
///   fine; treating this as a failure would fire a false alarm on every healthy
///   camera add, which is the exact class of bug issue #520 is about.
/// * **The stream was REJECTED and does not exist.** go2rtc refused the source
///   outright — e.g. `400 "streams: source with spaces may be insecure"` for an
///   RTSP URL with a literal space, which operators paste straight out of a
///   camera's web UI. This used to return `Ok(())`: the camera row existed, the
///   console showed it as normal, nothing was ever recorded, and the only trace
///   was the recorder reconnect-looping against a restream that was never there.
///
/// The status cannot tell those apart, so this asks go2rtc what actually
/// happened: on any non-success, read the body (which carries the reason) and
/// confirm against `GET /api/streams` whether the stream is now registered.
/// Present ⇒ benign, `Ok(())` as before. Absent ⇒ a real rejection, returned as
/// an error so [`apply_stream`]'s caller can warn AND raise a
/// `camera_stream_rejected` system event naming the reason.
///
/// Only a `4xx` gets that treatment. A transport error or a `5xx` is
/// [`ApplyError::Unavailable`] — go2rtc couldn't be asked, which is a
/// server-wide fault, not this camera's fault (the pre-#519 behavior, kept).
///
/// If the confirming GET itself fails we deliberately assume "registered"
/// (`Ok(())`): a false alarm is worse than a delayed one, the reconcile loop
/// retries within seconds, and a go2rtc that is genuinely unreachable makes the
/// `PUT` a transport error, which still fails here.
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
) -> std::result::Result<(), ApplyError> {
    let url = format!("{}/api/streams", api_base.trim_end_matches('/'));
    let resp = match c
        .put(&url)
        .basic_auth(auth.0, Some(auth.1))
        .query(&[("name", name), ("src", src)])
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            return Err(ApplyError::Unavailable(format!(
                "PUT go2rtc stream {name} ({url}): {e}"
            )))
        }
    };
    let status = resp.status();
    if status.is_success() {
        return Ok(());
    }
    // Body first (it names the reason), then confirm what go2rtc actually did.
    let body = resp.text().await.unwrap_or_default();
    let reason = go2rtc_reject_reason(status, &body);
    if status.is_server_error() {
        return Err(ApplyError::Unavailable(format!(
            "go2rtc PUT {name} -> {reason}"
        )));
    }
    match stream_exists(c, api_base, name, auth).await {
        Ok(true) => {
            tracing::debug!(
                stream = %name,
                reason = %reason,
                "go2rtc PUT answered non-success but the stream is registered; treating as applied"
            );
            Ok(())
        }
        Ok(false) => Err(ApplyError::Rejected(format!(
            "go2rtc rejected the stream source ({reason})"
        ))),
        Err(e) => {
            tracing::debug!(
                stream = %name,
                reason = %reason,
                error = %format!("{e:#}"),
                "go2rtc PUT answered non-success and the confirming GET failed; assuming applied (will retry)"
            );
            Ok(())
        }
    }
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
    /// `true` ⇒ the SDP advertises video with no `a=fmtp` for a codec that needs
    /// one (needs the `_subv` repair), `false` ⇒ it has one. A name is ABSENT
    /// when no verdict could be reached — no producer attached yet, no SDP, no
    /// video section, or a codec that carries no out-of-band parameter sets
    /// (MJPEG) — which callers must treat as "don't know", never as "broken".
    video_lacks_fmtp: std::collections::HashMap<String, bool>,
    /// Per stream name, the SAME verdict as [`video_lacks_fmtp`] but read from the
    /// SDP go2rtc SERVES to RTSP consumers instead of the producer's SDP. Used
    /// ONLY for the `_mainv` main repair; `_subv` keeps using the producer side.
    /// See [`stream_served_video_lacks_fmtp`] for why the main needs the served
    /// side (an incomplete producer `a=fmtp` that go2rtc cannot re-emit) while the
    /// sub does not (a sub is often un-consumed, so it has no served SDP at all).
    video_lacks_fmtp_served: std::collections::HashMap<String, bool>,
}

/// Does a video codec carry its parameter sets OUT OF BAND, i.e. in `a=fmtp`?
///
/// Only H.264 and H.265 do among the payloads cameras actually serve: their
/// SPS/PPS (and VPS) ride in `sprop-parameter-sets` / `sprop-vps` and a decoder
/// cannot start without them, which is why a missing `a=fmtp` breaks the stream
/// (#483). RTP/JPEG (M-JPEG) is the counter-example that motivated this gate
/// (#521): every JPEG frame is self-describing, RFC 2435 defines no format
/// parameters at all, so a perfectly healthy MJPEG SDP never has an `a=fmtp` and
/// remuxing it can never add one.
///
/// The name is the encoding name from `a=rtpmap`, compared case-insensitively
/// (SDP encoding names are case-insensitive; cameras ship both `H265` and the
/// `HEVC` spelling).
fn video_codec_needs_fmtp(encoding_name: &str) -> bool {
    matches!(
        encoding_name.to_ascii_uppercase().as_str(),
        "H264" | "H265" | "HEVC"
    )
}

/// The encoding name from an `a=rtpmap:<pt> <encoding>/<clock>[/<params>]` line,
/// or `None` if this is not an rtpmap line / has no encoding name.
fn rtpmap_encoding_name(line: &str) -> Option<&str> {
    // `a=rtpmap:` is matched case-insensitively, as the `a=fmtp:` scan is.
    const PREFIX_LEN: usize = "a=rtpmap:".len();
    if !line
        .get(..PREFIX_LEN)
        .is_some_and(|p| p.eq_ignore_ascii_case("a=rtpmap:"))
    {
        return None;
    }
    // Skip the payload type, then take the encoding name up to the `/clock`.
    let (_pt, enc) = line[PREFIX_LEN..].split_once(char::is_whitespace)?;
    let name = enc.trim_start().split('/').next().unwrap_or("").trim();
    (!name.is_empty()).then_some(name)
}

/// Does this SDP describe a video track that is BROKEN by a missing `a=fmtp`?
///
/// `None` ⇒ no verdict (empty SDP, no `m=video` section at all, or a video codec
/// that does not carry parameter sets out of band — see below). `Some(true)`
/// ⇒ the video track carries no `a=fmtp` line, which is exactly the condition
/// that makes Android's Media3 RTSP client throw
/// `IllegalArgumentException: missing attribute fmtp` and reconnect-loop the
/// tile forever (#483). Such a stream has no out-of-band parameter sets at all
/// (ffprobe on it reports "non-existing PPS 0 referenced / no frame!").
///
/// A missing `a=fmtp` is only evidence of breakage for codecs that are SUPPOSED
/// to have one: the verdict is gated on the video track's `a=rtpmap` encoding
/// name via [`video_codec_needs_fmtp`]. An MJPEG sub (`JPEG/90000`) legitimately
/// has no fmtp, and flagging it bought a permanent per-camera ffmpeg remux that
/// reproduced the same fmtp-less SDP while steering Android off the always-warm
/// raw sub (#521). Unknown/absent codec ⇒ `None` (no repair), which
/// [`resolve_needs_subv`] treats as "don't know", never as "broken".
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
    let mut needs_fmtp = false;
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
        } else if in_video {
            if let Some(enc) = rtpmap_encoding_name(line) {
                needs_fmtp |= video_codec_needs_fmtp(enc);
            }
        }
    }
    if !saw_video {
        return None;
    }
    if has_fmtp {
        return Some(false);
    }
    // No fmtp: only a verdict for codecs that should have had one.
    needs_fmtp.then_some(true)
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

/// Reach a verdict for one entry of go2rtc's `/api/streams` object, but from the
/// SDP go2rtc SERVES to its RTSP consumers rather than the one it RECEIVES from
/// the camera (that is [`stream_video_lacks_fmtp`]).
///
/// The two can disagree, and for the `_mainv` main repair only the SERVED side is
/// correct. A camera can advertise an `a=fmtp` that is INCOMPLETE for its codec —
/// the reference LPR camera (a Uniview) sends an H.265 main whose fmtp carries
/// `sprop-sps` + `sprop-pps` but no `sprop-vps` — and go2rtc, unable to assemble a
/// complete HEVC parameter set, then serves consumers an SDP with NO `a=fmtp` at
/// all. The producer SDP looks healthy ([`sdp_video_lacks_fmtp`] sees the fmtp
/// line and returns `Some(false)`), yet every RTSP client — Android's Media3
/// included — gets the fmtp-less SERVED SDP and throws `missing attribute fmtp`.
/// Detecting on the served SDP catches this class (any reason go2rtc drops the
/// fmtp, not just missing VPS); the main is always consumed by the recorder, so a
/// served SDP is reliably present.
///
/// Only RTSP consumers count: that is the transport Crumb's clients use, and a
/// WebRTC consumer negotiates a wholly different SDP that says nothing about the
/// RTSP restream. First RTSP consumer that yields a verdict wins — they all see
/// the same served track. `None` (no RTSP consumer attached yet, no SDP, no video
/// section) is "don't know", handled by [`resolve_needs_subv`]'s sticky rule
/// exactly like the producer side. Pure + unit-tested.
fn stream_served_video_lacks_fmtp(entry: &serde_json::Value) -> Option<bool> {
    entry
        .get("consumers")?
        .as_array()?
        .iter()
        .filter(|c| {
            c.get("format_name")
                .and_then(serde_json::Value::as_str)
                .is_some_and(|f| f.eq_ignore_ascii_case("rtsp"))
        })
        .filter_map(|c| c.get("sdp")?.as_str())
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
        if let Some(lacks) = stream_served_video_lacks_fmtp(entry) {
            idx.video_lacks_fmtp_served.insert(name.clone(), lacks);
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
    let main_repair_enabled = state.config().main_repair_transcode_enabled;

    // Which cameras actually need the REPAIRED-MAIN `_mainv` transcode, this pass.
    //
    // Gated on `main_repair_transcode_enabled` (default off): the repair is a
    // full-res re-encode with real recorder CPU cost, so it is opt-in — off means
    // the map stays empty and nothing changes for anyone. When on, it is
    // per-camera and detection-driven — but unlike `_subv`, the verdict comes from
    // the SDP go2rtc SERVES (`video_lacks_fmtp_served`), not the producer SDP.
    // A main can advertise an INCOMPLETE `a=fmtp` (e.g. H.265 with sps+pps but no
    // sprop-vps, the reference LPR camera) that looks healthy on the producer side
    // yet leaves go2rtc serving consumers a fmtp-less SDP — the exact thing that
    // makes Media3 throw `missing attribute fmtp`. See
    // [`stream_served_video_lacks_fmtp`]. The main is always consumed by the
    // recorder, so a served SDP is reliably present; a momentary gap yields
    // `None`, handled by `resolve_needs_subv`'s sticky-across-unknown rule.
    let mut needs_mainv: std::collections::HashMap<&str, bool> =
        std::collections::HashMap::with_capacity(streams.len());
    for s in &streams {
        let needed = main_repair_enabled
            && resolve_needs_subv(
                index.video_lacks_fmtp_served.get(&s.go2rtc_name).copied(),
                state.mainv_needed(&s.go2rtc_name),
            );
        needs_mainv.insert(s.go2rtc_name.as_str(), needed);
        state.set_mainv_needed(&s.go2rtc_name, needed);
    }
    // Forget cameras that no longer exist (deleted between passes).
    state.retain_mainv_needed(&streams.iter().map(|s| s.go2rtc_name.clone()).collect());

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
            if needs_mainv
                .get(s.go2rtc_name.as_str())
                .copied()
                .unwrap_or(false)
            {
                names.push(mainv_name(&s.go2rtc_name));
            }
            if mobile_enabled {
                names.push(mobile_name(&s.go2rtc_name));
            }
            names
        })
        .collect();

    for s in &streams {
        // Issue #519: the two streams whose source an OPERATOR typed. A go2rtc
        // rejection of either means this camera cannot record (main) or cannot
        // do pixel motion (sub), so it is collected here and reported once, per
        // camera, through the `camera_stream_rejected` latch below.
        let mut rejection: Option<String> = None;

        if let Err(e) = apply_stream(
            &c,
            api_base,
            &s.go2rtc_name,
            &s.source_url,
            existing,
            &managed,
            auth,
        )
        .await
        {
            rejection = rejection.or_else(|| classify_apply_error("main", &s.go2rtc_name, &e));
        }
        let has_sub = s
            .source_sub_url
            .as_deref()
            .is_some_and(|u| !u.trim().is_empty());
        if has_sub {
            let sub = sub_name(&s.go2rtc_name);
            if let Err(e) = apply_stream(
                &c,
                api_base,
                &sub,
                s.source_sub_url.as_deref().unwrap_or_default(),
                existing,
                &managed,
                auth,
            )
            .await
            {
                rejection = rejection.or_else(|| classify_apply_error("sub", &sub, &e));
            }
        }
        report_stream_rejection(state, s, rejection).await;
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
            apply_stream_logged(
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
        // The client-facing REPAIRED MAIN (`_mainv`), a full-res H.265->H.264
        // transcode registered ONLY when the operator opted the repair in AND this
        // camera's main was detected publishing video with no `a=fmtp`. Kept in
        // lockstep with `playback.rs`'s `rtsp_mainv_url` for the same reason as
        // `_subv`: a stale `_mainv` left registered would let the client advertise
        // a stream we no longer maintain. Deleted the moment it stops being needed
        // (repair disabled, firmware fix, or camera swap behind the same row).
        let mainv = mainv_name(&s.go2rtc_name);
        if needs_mainv
            .get(s.go2rtc_name.as_str())
            .copied()
            .unwrap_or(false)
        {
            apply_stream_logged(
                &c,
                api_base,
                &mainv,
                &mainv_src(&s.go2rtc_name),
                existing,
                &managed,
                auth,
            )
            .await;
        } else if existing.contains(&mainv) {
            if let Err(e) = delete_stream(&c, api_base, &mainv, auth).await {
                tracing::warn!(
                    stream = %mainv,
                    error = %crumb_common::redact::redact_url_credentials(&format!("{e:#}")),
                    "go2rtc: dropping no-longer-needed repaired main failed (will retry)"
                );
            } else {
                tracing::info!(stream = %mainv, "go2rtc: main no longer needs the fmtp repair; removed");
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
            apply_stream_logged(
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
    // Forget rejection latches for cameras deleted between passes, so a reused
    // `go2rtc_name` can't inherit a stale "already alerted" flag.
    state.retain_stream_rejected(&streams.iter().map(|s| s.go2rtc_name.clone()).collect());
    Ok(())
}

/// Split one stream's failure into "the operator needs to know" vs "just log
/// it" (issue #519).
///
/// A [`ApplyError::Rejected`] is returned as the alert detail fragment
/// (`"main stream — go2rtc rejected the stream source (HTTP 400: …)"`); an
/// [`ApplyError::Unavailable`] is logged exactly as the pre-#519 code did and
/// returns `None`, because go2rtc being unreachable is one fault affecting every
/// camera, not N per-camera faults worth N pushes.
fn classify_apply_error(role: &str, name: &str, e: &ApplyError) -> Option<String> {
    match e {
        ApplyError::Rejected(m) => Some(format!("{role} stream — {m}")),
        ApplyError::Unavailable(m) => {
            tracing::warn!(stream = %name, error = %m, "go2rtc stream apply failed");
            None
        }
    }
}

/// Raise (or clear) the `camera_stream_rejected` alert for one camera, on the
/// state TRANSITION only (issue #519).
///
/// The reconcile loop re-tries a rejected stream on every pass — and a missing
/// stream reads as a count shortfall, which escalates the loop to a pass every
/// ~5 s — so writing the event unconditionally would mean a `system_events` row
/// and a push notification several times a minute for as long as the camera
/// stays misconfigured. The latch on [`AppState`] means exactly one event per
/// broken→fixed cycle, mirroring the `camera_offline` watchdog's own latch.
///
/// Clearing on success is what re-arms it: once the operator fixes the URL and
/// the stream applies, a later regression alerts again.
async fn report_stream_rejection(
    state: &AppState,
    s: &crumb_common::db::CameraStream,
    rejection: Option<String>,
) {
    let already = state.stream_rejected(&s.go2rtc_name);
    match rejection {
        Some(reason) => {
            if already {
                tracing::debug!(
                    camera_id = %s.id,
                    stream = %s.go2rtc_name,
                    reason = %reason,
                    "go2rtc still rejecting this camera's stream (already alerted)"
                );
                return;
            }
            let detail = format!("camera \"{}\": {reason}", s.name);
            tracing::warn!(
                camera_id = %s.id,
                stream = %s.go2rtc_name,
                reason = %reason,
                "go2rtc REJECTED this camera's stream — it will record nothing until the source is fixed"
            );
            // Structured tokens for alert-text templating (migration 0079).
            let meta = serde_json::json!({ "reason": reason });
            if let Err(e) = crumb_common::db::insert_system_event_full(
                state.pool(),
                "camera_stream_rejected",
                Some(s.id),
                Some(&detail),
                None,
                Some(&meta),
            )
            .await
            {
                // Don't latch on a failed insert — retry on the next pass.
                tracing::warn!(error = %e, camera_id = %s.id, "insert_system_event(camera_stream_rejected) failed");
            } else {
                state.set_stream_rejected(&s.go2rtc_name, true);
            }
        }
        None => {
            if already {
                tracing::info!(
                    camera_id = %s.id,
                    stream = %s.go2rtc_name,
                    "go2rtc now accepts this camera's stream (previously rejected)"
                );
                state.set_stream_rejected(&s.go2rtc_name, false);
            }
        }
    }
}

/// Reconcile a single managed stream with the right verb (`PUT` to create /
/// `PATCH` to update in place), redacting credentials from the error message.
///
/// Returns the failure instead of swallowing it (issue #519) so the caller can
/// decide what it means: the two operator-facing streams (main + sub) route a
/// [`ApplyError::Rejected`] into a `camera_stream_rejected` system event, while
/// the derived streams just log. Either way one bad camera never aborts the
/// pass — the caller logs and moves on.
///
/// Credentials are redacted here, once, for every path: `{e:#}` prints the whole
/// context chain (".. : connection refused"), which is what an operator needs
/// when go2rtc is down, but reqwest embeds the FULL request URL (including the
/// `?src=<camera-url>` query, with the camera's percent-encoded `user:pass@`) in
/// that error.
#[allow(clippy::too_many_arguments)]
async fn apply_stream(
    c: &reqwest::Client,
    api_base: &str,
    name: &str,
    src: &str,
    existing: &HashSet<String>,
    managed: &HashSet<String>,
    auth: (&str, &str),
) -> std::result::Result<(), ApplyError> {
    let res = match choose_verb(existing.contains(name), src, managed) {
        StreamVerb::Create => put_stream(c, api_base, name, src, auth).await,
        StreamVerb::Patch => patch_stream(c, api_base, name, src, auth)
            .await
            .map_err(|e| ApplyError::Unavailable(format!("{e:#}"))),
    };
    res.map_err(|e| match e {
        ApplyError::Rejected(m) => {
            ApplyError::Rejected(crumb_common::redact::redact_url_credentials(&m))
        }
        ApplyError::Unavailable(m) => {
            ApplyError::Unavailable(crumb_common::redact::redact_url_credentials(&m))
        }
    })
}

/// [`apply_stream`] for a DERIVED stream (`_subv`, `_mobile`) — nothing an
/// operator typed, so a failure is logged exactly as before #519 and never
/// raises a per-camera alert.
#[allow(clippy::too_many_arguments)]
async fn apply_stream_logged(
    c: &reqwest::Client,
    api_base: &str,
    name: &str,
    src: &str,
    existing: &HashSet<String>,
    managed: &HashSet<String>,
    auth: (&str, &str),
) {
    if let Err(e) = apply_stream(c, api_base, name, src, existing, managed, auth).await {
        tracing::warn!(stream = %name, error = %e, "go2rtc stream apply failed");
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
    // Best-effort: drop the repaired-main transcode too (a no-op if it was never
    // registered — go2rtc DELETE tolerates a missing name).
    let _ = delete_stream(&c, api_base, &mainv_name(go2rtc_name), auth).await;
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
    // The repaired main is derived from `<name>`, so it must be re-dialled with it
    // (its ffmpeg reader is bound to the old main object otherwise).
    if let Err(e) = delete_stream(&c, api_base, &mainv_name(go2rtc_name), auth).await {
        tracing::warn!(go2rtc_name, error = %format!("{e:#}"), "reconnect: DELETE repaired-main stream failed (ignoring)");
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

    // ── go2rtc stream rejection (issue #519) ────────────────────────────────
    //
    // The bug: `put_stream` returned `Ok(())` for every non-5xx answer, so
    // go2rtc's `400 "streams: source with spaces may be insecure"` — which
    // registers NOTHING — was recorded as a successful apply. The camera row
    // existed, the console showed it as normal, and nothing was ever recorded.
    //
    // These drive the real HTTP path against a stub that answers exactly the way
    // go2rtc does in each case, because the whole fix is "the status code alone
    // is not the answer, ask go2rtc what it actually has".

    /// Spawn a stub go2rtc on an ephemeral port. `put_status`/`put_body` are what
    /// it answers to BOTH `PUT` and `PATCH /api/streams` (go2rtc gives the same
    /// status to a rejected source on either verb); `streams_json` is what `GET
    /// /api/streams` then reports (i.e. whether the stream actually landed).
    /// Returns its base URL.
    async fn stub_go2rtc(
        put_status: u16,
        put_body: &'static str,
        streams_json: &'static str,
    ) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = axum::Router::new().route(
            "/api/streams",
            axum::routing::put(move || async move {
                (
                    axum::http::StatusCode::from_u16(put_status).unwrap(),
                    put_body,
                )
            })
            .patch(move || async move {
                (
                    axum::http::StatusCode::from_u16(put_status).unwrap(),
                    put_body,
                )
            })
            .get(move || async move {
                (
                    [(axum::http::header::CONTENT_TYPE, "application/json")],
                    streams_json,
                )
            }),
        );
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn put_stream_fails_when_go2rtc_rejected_the_source() {
        // go2rtc's real answer to an RTSP URL with a literal space, and its real
        // follow-up state: the stream is NOT there.
        let base = stub_go2rtc(400, "streams: source with spaces may be insecure\n", "{}").await;
        let c = client().unwrap();
        let err = put_stream(
            &c,
            &base,
            "front_door",
            "rtsp://cam.invalid:554/odd path/cam",
            ("u", "p"),
        )
        .await
        .expect_err("a 400 with the stream absent must NOT be reported as applied (#519)");
        assert!(
            matches!(err, ApplyError::Rejected(_)),
            "a 4xx with the stream absent is this camera's fault, not go2rtc being down: {err}"
        );
        // The operator needs go2rtc's own reason, not just a status code.
        let msg = err.to_string();
        assert!(
            msg.contains("400"),
            "status must survive into the message: {msg}"
        );
        assert!(
            msg.contains("source with spaces may be insecure"),
            "go2rtc's reason must survive into the message: {msg}"
        );
    }

    #[tokio::test]
    async fn put_stream_tolerates_a_4xx_when_the_stream_was_actually_registered() {
        // The other 4xx: go2rtc DID register the stream and then failed its own
        // post-registration config write (Crumb mounts go2rtc.yaml read-only) or
        // its immediate source probe. Treating this as a failure would fire a
        // false alarm on healthy cameras — the #520 class of bug.
        let base = stub_go2rtc(400, "failed to write config", r#"{"front_door":{}}"#).await;
        let c = client().unwrap();
        put_stream(
            &c,
            &base,
            "front_door",
            "rtsp://cam.invalid/live",
            ("u", "p"),
        )
        .await
        .expect("a 4xx whose stream IS registered must stay a success");
    }

    #[tokio::test]
    async fn put_stream_treats_5xx_as_unavailable_not_a_camera_fault() {
        // A 5xx means go2rtc could not be asked — server-wide, so it must never
        // raise a per-camera alert (it would page once per camera for one fault).
        let base = stub_go2rtc(500, "boom", "{}").await;
        let c = client().unwrap();
        let err = put_stream(
            &c,
            &base,
            "front_door",
            "rtsp://cam.invalid/live",
            ("u", "p"),
        )
        .await
        .expect_err("a 5xx is still a failure");
        assert!(
            matches!(err, ApplyError::Unavailable(_)),
            "5xx must not be attributed to the camera: {err}"
        );
    }

    #[tokio::test]
    async fn put_stream_succeeds_on_2xx_without_a_confirming_get() {
        // The happy path must not pay for the confirmation round-trip: the stub
        // reports an EMPTY stream list, which would look like a rejection if the
        // 2xx path consulted it.
        let base = stub_go2rtc(200, "", "{}").await;
        let c = client().unwrap();
        put_stream(
            &c,
            &base,
            "front_door",
            "rtsp://cam.invalid/live",
            ("u", "p"),
        )
        .await
        .expect("2xx is a success, full stop");
    }

    #[tokio::test]
    async fn put_stream_assumes_applied_when_the_confirming_get_is_unusable() {
        // Fail-safe direction: if go2rtc's answer to the confirming GET can't be
        // read, prefer a delayed alert over a false one — the reconcile loop
        // retries within seconds.
        let base = stub_go2rtc(400, "who knows", "not json at all").await;
        let c = client().unwrap();
        put_stream(
            &c,
            &base,
            "front_door",
            "rtsp://cam.invalid/live",
            ("u", "p"),
        )
        .await
        .expect("an unreadable confirmation must not invent a rejection");
    }

    // ── a source-URL EDIT must not swallow a rejection (issue #519, re-opened) ──
    //
    // `reconcile` reaches an ALREADY-registered stream, so [`apply_stream`]
    // chooses `PATCH`. These prove WHY a source-URL edit had to be re-routed
    // through `reconnect` (DELETE+PUT): the PATCH path swallows a go2rtc
    // rejection, the Create path (which reconnect's DELETE forces) surfaces it.

    #[tokio::test]
    async fn a_patch_in_place_swallows_a_go2rtc_rejection_the_bug() {
        // The pre-fix silence: go2rtc REFUSES the newly-typed source (400, stream
        // absent) but the name is already registered, so `apply_stream` PATCHes —
        // and a PATCH only bails on 5xx, so the refusal is discarded as Ok. This
        // is exactly why `update_camera` must NOT push a source change through
        // reconcile; the assertion documents the swallow it used to rely on.
        let base = stub_go2rtc(400, "streams: source with spaces may be insecure\n", "{}").await;
        let c = client().unwrap();
        let present = names(&["front_door"]);
        let managed = names(&["front_door"]);
        apply_stream(
            &c,
            &base,
            "front_door",
            "rtsp://cam.invalid:554/odd path/cam",
            &present,
            &managed,
            ("u", "p"),
        )
        .await
        .expect(
            "the PATCH path swallows a 4xx — this is the #519-for-edits bug the fix routes around",
        );
    }

    #[tokio::test]
    async fn the_create_path_reconnect_forces_surfaces_a_rejection() {
        // After `reconnect`'s DELETE the name is ABSENT, so `apply_stream` takes
        // the Create (`PUT`) path — which confirms by existence and returns the
        // rejection. This is the signal a source-URL edit now gets.
        let base = stub_go2rtc(400, "streams: source with spaces may be insecure\n", "{}").await;
        let c = client().unwrap();
        let absent = names(&[]);
        let managed = names(&["front_door"]);
        let err = apply_stream(
            &c,
            &base,
            "front_door",
            "rtsp://cam.invalid:554/odd path/cam",
            &absent,
            &managed,
            ("u", "p"),
        )
        .await
        .expect_err("an absent stream + 4xx must surface as a rejection");
        assert!(
            matches!(err, ApplyError::Rejected(_)),
            "an edit to a go2rtc-refused source is this camera's fault: {err}"
        );
        assert!(
            err.to_string()
                .contains("source with spaces may be insecure"),
            "the operator needs go2rtc's own reason: {err}"
        );
    }

    #[tokio::test]
    async fn a_valid_source_edit_applies_cleanly() {
        // The good edit: the Create path with a 2xx is a plain success.
        let base = stub_go2rtc(200, "", "{}").await;
        let c = client().unwrap();
        let absent = names(&[]);
        let managed = names(&["front_door"]);
        apply_stream(
            &c,
            &base,
            "front_door",
            "rtsp://cam.invalid:554/live",
            &absent,
            &managed,
            ("u", "p"),
        )
        .await
        .expect("a valid source must apply without an alert");
    }

    #[test]
    fn reject_reason_carries_the_body_and_collapses_it_to_one_line() {
        let r = go2rtc_reject_reason(
            reqwest::StatusCode::BAD_REQUEST,
            "streams: source with spaces\n  may be insecure\n",
        );
        assert_eq!(
            r, "HTTP 400 Bad Request: streams: source with spaces may be insecure",
            "a multi-line body must stay one log line / one alert detail"
        );
    }

    #[test]
    fn reject_reason_survives_an_empty_body() {
        let r = go2rtc_reject_reason(reqwest::StatusCode::BAD_REQUEST, "   \n");
        assert_eq!(r, "HTTP 400 Bad Request");
    }

    #[test]
    fn reject_reason_redacts_credentials_echoed_back_by_go2rtc() {
        let r = go2rtc_reject_reason(
            reqwest::StatusCode::BAD_REQUEST,
            "bad source rtsp://admin:hunter2@cam.invalid/live",
        );
        assert!(
            !r.contains("hunter2"),
            "a body that echoes the source must not leak the camera password: {r}"
        );
    }

    #[test]
    fn reject_reason_truncates_a_runaway_body() {
        let body = "x".repeat(MAX_GO2RTC_ERROR_BODY * 3);
        let r = go2rtc_reject_reason(reqwest::StatusCode::BAD_REQUEST, &body);
        assert!(r.ends_with('…'), "truncation must be visible: {r}");
        assert!(
            r.chars().count() < MAX_GO2RTC_ERROR_BODY + 40,
            "an HTML error page must not land in a notification: {} chars",
            r.chars().count()
        );
    }

    #[test]
    fn only_a_rejection_becomes_an_operator_alert() {
        // The routing rule the alert depends on: a camera-specific refusal is
        // reported, an unreachable go2rtc is only logged.
        assert_eq!(
            classify_apply_error("main", "front_door", &ApplyError::Rejected("nope".into())),
            Some("main stream — nope".to_owned())
        );
        assert_eq!(
            classify_apply_error(
                "sub",
                "front_door_sub",
                &ApplyError::Unavailable("connection refused".into())
            ),
            None,
            "go2rtc being down is one fault, not one per camera"
        );
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

    /// A healthy M-JPEG sub's real SDP (#521), IPs genericised. RTP/JPEG defines
    /// no format parameters, so the absence of `a=fmtp` here is CORRECT, and the
    /// `_subv` remux reproduces this SDP byte-for-byte fmtp-less.
    const SDP_MJPEG: &str = "v=0\r\n\
        o=- 1786058169509450 1 IN IP4 192.0.2.20\r\n\
        t=0 0\r\n\
        a=control:*\r\n\
        m=video 0 RTP/AVP 96\r\n\
        c=IN IP4 0.0.0.0\r\n\
        a=rtpmap:96 JPEG/90000\r\n\
        a=recvonly\r\n\
        a=control:track1\r\n";

    #[test]
    fn sdp_verdict_is_unknown_for_codecs_without_parameter_sets() {
        // MJPEG has nothing to put in an fmtp — flagging it bought a permanent
        // per-camera ffmpeg remux that could not possibly help (#521).
        assert_eq!(sdp_video_lacks_fmtp(SDP_MJPEG), None);
        assert!(
            !SDP_MJPEG.contains("a=fmtp:"),
            "fixture must stay fmtp-less — that is the whole point",
        );
        // H264/H265 with no fmtp is still the #483 breakage, in either spelling.
        assert_eq!(
            sdp_video_lacks_fmtp("v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"),
            Some(true),
        );
        assert_eq!(
            sdp_video_lacks_fmtp("v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\n"),
            Some(true),
        );
        assert_eq!(
            sdp_video_lacks_fmtp("v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 hevc/90000\r\n"),
            Some(true),
        );
        // ...and H264 WITH an fmtp stays healthy.
        assert_eq!(
            sdp_video_lacks_fmtp(
                "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n\
                 a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z2QAM6wVFKCgL/lQ,aO48sA==\r\n"
            ),
            Some(false),
        );
        // An unrecognised / absent video codec is "don't know", not "broken":
        // no repair is registered for a payload we cannot reason about.
        assert_eq!(
            sdp_video_lacks_fmtp("v=0\r\nm=video 0 RTP/AVP 98\r\na=rtpmap:98 VP8/90000\r\n"),
            None,
        );
        assert_eq!(
            sdp_video_lacks_fmtp("v=0\r\nm=video 0 RTP/AVP 26\r\n"),
            None
        );
    }

    #[test]
    fn rtpmap_encoding_name_parses_the_codec() {
        assert_eq!(rtpmap_encoding_name("a=rtpmap:96 H264/90000"), Some("H264"));
        assert_eq!(rtpmap_encoding_name("A=RTPMAP:96 JPEG/90000"), Some("JPEG"));
        // Optional /encoding-params tail (audio-style) and stray whitespace.
        assert_eq!(
            rtpmap_encoding_name("a=rtpmap:97 MPEG4-GENERIC/16000/1"),
            Some("MPEG4-GENERIC"),
        );
        assert_eq!(
            rtpmap_encoding_name("a=rtpmap:96  H265/90000"),
            Some("H265")
        );
        // Not an rtpmap line, or malformed.
        assert_eq!(rtpmap_encoding_name("a=control:track1"), None);
        assert_eq!(rtpmap_encoding_name("a=rtpmap:96"), None);
        assert_eq!(rtpmap_encoding_name(""), None);
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

    /// The reference LPR camera's real PRODUCER SDP (a Uniview), IP genericised.
    /// Its H.265 video track HAS an `a=fmtp` — but only `sprop-sps`+`sprop-pps`,
    /// no `sprop-vps`. That reads as HEALTHY on the producer side (a fmtp line is
    /// present), which is exactly why producer-side detection never flagged it.
    const SDP_LPR_PRODUCER_INCOMPLETE_FMTP: &str = "v=0\r\n\
        o=- 1001 1 IN IP4 192.0.2.6\r\n\
        s=VCP IPC Realtime stream\r\n\
        m=video 0 RTP/AVP 108\r\n\
        c=IN IP4 192.0.2.6\r\n\
        a=control:rtsp://192.0.2.6/media/video1/video\r\n\
        a=rtpmap:108 H265/90000\r\n\
        a=fmtp:108 sprop-sps=QgEBAWAAAAMAsAAAAwAAAwB7oAPAgBDlja7ky/NwEBAQQAAA+gAAGGox; sprop-pps=RAHA8rA7JA==\r\n\
        a=recvonly\r\n";

    /// What go2rtc then SERVES to an RTSP consumer for that same LPR main: unable
    /// to assemble a complete HEVC parameter set from the vps-less producer fmtp,
    /// it emits the video track with NO `a=fmtp` at all — the exact SDP that makes
    /// Media3 throw `missing attribute fmtp`. This is a real captured consumer SDP.
    const SDP_LPR_SERVED_NO_FMTP: &str = "v=0\r\n\
        o=- 1 1 IN IP4 0.0.0.0\r\n\
        s=go2rtc/1.9.14\r\n\
        c=IN IP4 0.0.0.0\r\n\
        t=0 0\r\n\
        m=video 0 RTP/AVP 96\r\n\
        a=rtpmap:96 H265/90000\r\n\
        a=recvonly\r\n\
        a=control:trackID=0\r\n";

    #[test]
    fn served_verdict_catches_a_main_the_producer_verdict_misses() {
        // The whole bug: producer HAS an fmtp (incomplete), served has NONE. Only
        // the served side reflects what Media3 actually receives, so `_mainv` must
        // key on it.
        let lpr = serde_json::json!({
            "producers": [{ "sdp": SDP_LPR_PRODUCER_INCOMPLETE_FMTP }],
            "consumers": [{ "format_name": "rtsp", "sdp": SDP_LPR_SERVED_NO_FMTP }],
        });
        assert_eq!(
            stream_video_lacks_fmtp(&lpr),
            Some(false),
            "producer fmtp line present ⇒ producer side looks healthy",
        );
        assert_eq!(
            stream_served_video_lacks_fmtp(&lpr),
            Some(true),
            "served SDP has no video fmtp ⇒ this is what breaks Media3",
        );
    }

    #[test]
    fn served_verdict_only_trusts_rtsp_consumers() {
        // A healthy H.265 main: the served SDP carries a full fmtp, so no repair.
        let healthy_served = serde_json::json!({
            "consumers": [{ "format_name": "rtsp", "sdp": SDP_HEALTHY }],
        });
        assert_eq!(stream_served_video_lacks_fmtp(&healthy_served), Some(false));

        // A WebRTC consumer negotiates a wholly different SDP that says nothing
        // about the RTSP restream, so it must be ignored — not treated as a
        // verdict. With only a WebRTC consumer, the verdict is unknown.
        let webrtc_only = serde_json::json!({
            "consumers": [{ "format_name": "webrtc", "sdp": SDP_LPR_SERVED_NO_FMTP }],
        });
        assert_eq!(stream_served_video_lacks_fmtp(&webrtc_only), None);

        // No consumer attached yet ⇒ unknown (sticky), never "broken".
        assert_eq!(
            stream_served_video_lacks_fmtp(&serde_json::json!({ "consumers": [] })),
            None,
        );
        assert_eq!(stream_served_video_lacks_fmtp(&serde_json::json!({})), None);
    }

    #[test]
    fn index_carries_the_served_verdict_separately() {
        // The LPR entry: producer verdict false (has fmtp), served verdict true
        // (fmtp stripped). The two maps must not be conflated.
        let body = serde_json::json!({
            "lpr": {
                "producers": [{ "sdp": SDP_LPR_PRODUCER_INCOMPLETE_FMTP }],
                "consumers": [{ "format_name": "rtsp", "sdp": SDP_LPR_SERVED_NO_FMTP }],
            },
        });
        let idx = index_from_streams(body.as_object().unwrap());
        assert_eq!(idx.video_lacks_fmtp.get("lpr"), Some(&false));
        assert_eq!(idx.video_lacks_fmtp_served.get("lpr"), Some(&true));
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

    // ── repaired main (`_mainv`) transcode (LPR H.265 / missing-fmtp) ────────

    #[test]
    fn mainv_name_and_src_shapes() {
        assert_eq!(mainv_name("lpr"), "lpr_mainv");
        // Sources the MAIN stream by name (shares its producer).
        assert_eq!(mainv_src("lpr"), "ffmpeg:lpr#video=h264#audio=aac");
    }

    #[test]
    fn mainv_src_is_a_transcode_not_a_copy() {
        // The critical difference from `_subv`, verified empirically (2026-08-08):
        // a copy-remux of an H.265 main fixes the fmtp but go2rtc then emits an RTP
        // Aggregation Packet for the parameter sets that Media3 cannot depacketize,
        // so the repaired main MUST re-encode to H.264 to be playable on Android.
        let src = mainv_src("lpr");
        assert!(src.contains("#video=h264"), "must re-encode to h264: {src}");
        assert!(!src.contains("#video=copy"), "must not be a copy: {src}");
        // Full resolution: no width cap (this is the HD rung, unlike `_mobile`).
        assert!(
            !src.contains("#width"),
            "must stay at source resolution: {src}"
        );
    }

    #[test]
    fn mainv_src_is_never_an_rtsp_alias_collision() {
        // Like `_subv`/`_mobile`, an `ffmpeg:` source can never trip the PATCH
        // alias guard, so `_mainv` PATCHes in place rather than forcing PUT.
        let managed = names(&["lpr", "lpr_sub", "lpr_mainv"]);
        assert!(!is_patch_alias_collision(&mainv_src("lpr"), &managed));
        assert_eq!(
            choose_verb(true, &mainv_src("lpr"), &managed),
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
