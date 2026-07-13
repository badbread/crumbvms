<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# Mobile / poor-connection performance

Playing recorded footage and fullscreen live over a **poor cellular link** used
to be near-unusable: every play attempt stalled, every scrub restarted a large
download. This doc records why, and the on-demand, operator-hardware-only design
that fixes it — plus what is shipped vs. deferred.

Footage never leaves the operator's server: every quality variant here is just a
smaller representation of the same footage, produced by the operator's own
hardware and served over the same authenticated channel. No cloud, no telemetry,
no third party (per `AGENTS.md`).

## Root cause

- **Recorded playback always fetched the full main-stream bytes.** The recorder
  records one stream per camera with `-c copy` (default `main`, typically 2K/4K
  H.265 at multi-Mbps), and `GET /segments/{id}` serves that file byte-for-byte.
  There was **no downscale option anywhere on the playback path**. A 4 s segment
  is ~2–4 MB; poor cellular sustains a fraction of that bitrate, so playback can
  never keep up.
- **Fullscreen live always started on the HD main stream** (sub only on an H.265
  *codec* failure, not on bandwidth), so it was a slideshow on cellular.
- Only the live **grid** used the sub stream, and nothing measured link quality
  on the playback path.

The commercial-VMS answer is a per-connection "mobile server" transcode. Crumb's
equivalent is below.

## Design: on-demand, cached, operator-side

### Phase 1 — low-bitrate recorded playback (shipped)

`GET /segments/{id}/low.mp4` (module `services/api/src/segment_low.rs`) returns a
transcoded **640p / 15 fps / CRF 28 H.264** variant (with AAC mono audio) of one
recorded segment, produced **only when a client requests it** and then cached.

- Reuses the proven clip-preview machinery: `libx264 -preset ultrafast`, cached
  under `{export_dir}/segcache`, LRU-pruned to `SEGMENT_LOW_CACHE_MAX_BYTES`,
  ETag'd and immutable (a segment's bytes never change), concurrency-bounded by
  the shared `clip_gen_semaphore`.
- **Auth is identical to `/segments/{id}`**: `require_playback()` +
  `assert_camera_access()` + the scoped per-camera `?token=` media claim. The
  same path-traversal guard (`playback::guard_path_traversal`) runs before any
  file I/O. The API mounts media **read-only**; this writes only to its own
  cache. **The recorder is never touched — zero recording-correctness risk.**
- **Bonus:** transcoding to H.264 640p also sidesteps H.265 decode weakness on
  older Android devices — Data-saver doubles as a compatibility mode.

Client (Android): a playback quality selector **Auto / Full / Data saver**
(default **Auto**), persisted in `SecureStore`. Auto = Full on Wi-Fi/unmetered,
Low on metered/cellular; Data saver = always `low.mp4`; Full = always the
recorded bytes. When "low" is active the client appends `/low.mp4` to the segment
URL; switching quality re-resolves the current playhead.

Why per-segment (vs. a continuous time-range transcode or HLS ABR): it slots
into the existing resolve→segment client model with a one-line URL change, is
cacheable/idempotent per segment (repeat scrubs hit the cache), and reuses the
clip machinery wholesale. A continuous-range transcode was considered (it also
smooths audio across boundaries) but rejected for v1 because it replaces the
client's whole segment/prefetch/seek model with a long-lived per-session stream
that a seek must restart; keep it as the v2 shape if per-segment spawn overhead
disappoints. Full ABR was rejected as overkill for a single-operator VMS. See
`docs/DECISIONS.md` (2026-07-13, mobile performance).

### Phase 2 — on-demand mobile live transcode (shipped)

The API reconcile loop registers a per-camera **`<name>_mobile`** go2rtc stream
(`services/api/src/go2rtc.rs`) whose source is an ffmpeg transcode
(`ffmpeg:<input>#video=h264#width=MOBILE_STREAM_WIDTH`) of the camera's **sub**
stream (or **main** when there is no sub), referenced by go2rtc stream name so it
shares that stream's single producer. go2rtc only spawns the transcode ffmpeg
**while a consumer is connected**, so an idle mobile stream costs nothing.

Exposed to clients as `rtsp_mobile_url`. Gated by `MOBILE_STREAM_ENABLED`
(default on). Removed with the camera.

> **Operator note (recorder-host CPU).** go2rtc is embedded in the **recorder**
> container, so when a mobile client connects, the transcode ffmpeg runs beside
> the recorder. It is on-demand (zero idle cost) and bounded to one process per
> active mobile viewer, but on a CPU-starved host you can disable it with
> `MOBILE_STREAM_ENABLED=false` — clients then fall back to the sub stream.

Client (Android): on a **metered** link, fullscreen live starts on the sub
stream (or `rtsp_mobile_url` when the camera has no sub) instead of HD main; the
"SD · tap for HD" badge forces HD.

### Phase 0 — client buffering quick wins (shipped, Android)

- A dedicated WAN-tuned playback `LoadControl` (larger buffer window + a 30 s
  retained back-buffer, so small backward scrubs replay from RAM instead of
  re-downloading), in `MediaFactory.newPlaybackPlayer`.
- Playback prefetch lead raised 2 s → 3.5 s to hide one resolve round-trip.
- Fullscreen live sub-stream-first on metered + a tappable HD/SD override.

The same `newPlaybackPlayer` also fixes the **no-audio-in-playback** bug (#106):
it declares `USAGE_MEDIA` audio attributes with audio-focus handling (the muted
live tiles never requested focus) and re-asserts the intended volume across media
transitions.

## New env knobs (API), all optional with sane defaults

| Key | Default | Meaning |
|---|---|---|
| `SEGMENT_LOW_CACHE_MAX_BYTES` | `2 GiB` | Byte budget for the `low.mp4` cache (`{export_dir}/segcache`), LRU-pruned. |
| `MOBILE_STREAM_ENABLED` | `true` | Register the on-demand `<name>_mobile` go2rtc transcode. `false` → clients fall back to the sub stream on metered live. |
| `MOBILE_STREAM_WIDTH` | `640` | Target width (px) of the mobile transcode; height derived to preserve aspect. |

## Success criteria (to validate on device)

On a throttled ~1 Mbps / 150 ms RTT link: pressing play reaches steady playback
in < 3 s and sustains ≥ 95 % of wall-clock time playing; a scrub release shows
moving video in < 3 s; server CPU for one remote viewer < 1 core at 640p
ultrafast.

## Deferred / future

- **Continuous-range playback transcode** as a v2 shape if per-segment spawn
  overhead measures badly (also removes any residual segment-boundary audio
  seam). See the DECISIONS entry's revisit triggers.
- Extend the `low.mp4` quality lever to the desktop/web clients (they get it
  nearly free).
- Interaction with ROADMAP dual-stream recording: when a *recorded* low-res
  track exists, "Low" should prefer it over an on-the-fly transcode.
- On-device verification of the #106 audio fix and the throttled-link success
  criteria above.
