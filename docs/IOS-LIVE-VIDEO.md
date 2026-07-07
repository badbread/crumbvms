# Crumb iOS, Live Video Architecture (and the road to it)

**Status:** SHIPPED 2026-06-26. This documents what the iOS client uses for live
video, **why**, and every approach that was tried and rejected, so the dead ends
aren't re-walked. Companion to [IOS-APP-PLAN.md](IOS-APP-PLAN.md), which is the
current source of truth for the as-built Apple clients.

> **Signaling has since moved behind the authenticated API.** WebRTC signaling now
> goes through the api's authenticated SDP proxy (`POST /live/{camera_id}/webrtc`),
> not a direct call to go2rtc's REST port. The direct `:11984` endpoints described
> below are the original bring-up path and are kept for the historical record and
> the codec/ICE debugging notes; for the shipped auth model see
> [IOS-APP-PLAN.md](IOS-APP-PLAN.md) and `docs/COMPOSE.md` ("the security model").

## TL;DR, what it uses now

| Surface | Transport | Player | Codec | Notes |
|---|---|---|---|---|
| **Live wall** (tiles) | go2rtc **WebRTC** (WHEP) | native `stasel/WebRTC` → `RTCMTLVideoView` | H.264 **sub** stream | Light enough for many tiles; no zoom needed. |
| **Fullscreen** (1 camera) | go2rtc **WebRTC** (WHEP) | **`WKWebView`** (WebKit WebRTC) | H.265 **main** stream | WebKit decodes HEVC; browser composites the `<video>`, so **pinch-zoom stays live & crisp**. |

Both connect to the WHEP signaling endpoint `http://<host>:11984/api/webrtc?src=<name>`
and depend on the **go2rtc WebRTC server config** below.

## ⚠️ Server prerequisite, go2rtc WebRTC must advertise a LAN ICE candidate

**Without this, all WebRTC silently fails ICE and clients fall back to ~1fps
snapshots.** This bit us hard; it is not optional.

go2rtc runs in a **bridge** container (embedded inside the recorder). By default
it only sees its container IP (`172.x`) and otherwise advertises the host's
**public** IP via STUN, neither is reachable for a LAN phone, so ICE never
connects.

Two changes (see committed [`go2rtc/go2rtc.yaml`](../go2rtc/go2rtc.yaml) +
[`docker-compose.yml`](../docker-compose.yml)):

1. **Advertise the LAN host candidate.** In `go2rtc.yaml`:
   ```yaml
   webrtc:
     listen: ":8556"
     candidates:
       - ${WEBRTC_CANDIDATE}   # set to <server-LAN-ip>:8556 in .env
       - stun:8556             # keeps remote/WAN working
   ```
2. **Publish the media port** in `docker-compose.yml`:
   ```yaml
   - "0.0.0.0:8556:8556/tcp"
   - "0.0.0.0:8556:8556/udp"
   ```
3. Set `WEBRTC_CANDIDATE=<server-LAN-ip>:8556` in `.env`, then
   `docker compose up -d --force-recreate recorder` (go2rtc is embedded in the
   recorder container).

### Why 8556, not go2rtc's default 8555

A **host-network Frigate** (which bundles its own go2rtc) commonly already owns
host `:8555`. Crumb's bridge container can't republish a host port Frigate holds —
`docker compose up` fails with `address already in use`, and a failed recreate
**stops recording**. We moved Crumb's go2rtc WebRTC to **8556** to sidestep the
collision. If a deployment has no Frigate, 8555 is fine; the port just has to be
free, published, and matched in `listen` + `candidates` + the Docker mapping.

**Verify:** `POST` any SDP offer to `:11984/api/webrtc?src=<cam>` and confirm the
answer contains `... <server-LAN-ip> 8556 typ host` (not only `srflx` public-IP
lines).

## Camera codec reality (drove every decision)

- **Main streams are H.265 (HEVC)**, full-FPS, the quality stream.
- **Sub streams are H.264**, but **~5 FPS**, fine for small wall tiles, **not**
  acceptable for fullscreen.
- So fullscreen *must* play the **H.265 main** stream at full FPS. That single
  fact eliminated most "easy" options below.

Confirm a camera's codecs by `POST`ing an H.264-only vs H.265 SDP offer to the
WHEP endpoint and reading which `a=rtpmap` the answer selects (or `codecs not
matched` 500 = the source is the other codec).

## The dead ends (do not re-try these)

1. **AVPlayer + HLS**, go2rtc serves HLS as **HEVC-in-MPEG-TS** (`segment.ts`).
   Apple HLS only supports HEVC in **fMP4/CMAF**, never in MPEG-TS → black screen
   on every H.265 camera. (H.264 cameras play fine, which is why *some* worked.)
2. **AVPlayer + go2rtc fMP4** (`/api/stream.mp4`), that endpoint is an MSE/MediaSource
   stream for browsers. `AVPlayer` rejects the live unbounded fMP4 → status
   `failed`, "operation stopped".
3. **Native WebRTC (`stasel/WebRTC`) for H.265**, the prebuilt iOS binary has the
   H.265 *core* (bitstream parser) but **no ObjC VideoToolbox H.265 decoder** (there
   are `RTCVideoDecoderH264`/VP8/VP9/AV1 classes, none for H265). HEVC-over-WebRTC
   on Apple is a **WebKit/Safari-only** path (Apple's proprietary RTP format), not
   exposed to libwebrtc. So native WebRTC works for the **H.264 sub** (the wall) but
   never the H.265 main.
4. **VLCKit + RTSP** (`rtsp://host:18554/<name>`), libVLC bundles an ancient
   LIVE555 (2016) that can't parse go2rtc's `c=IN IP4 0.0.0.0` SDP: *"Unable to
   determine our source address: invalid IP 0.0.0.0"* → stuck buffering forever,
   `time=0`. (RTP-over-UDP through Docker NAT is also broken; TCP didn't save it.)
5. **VLCKit + HTTP fMP4** (`/api/stream.mp4`), this **worked**: full-FPS H.265,
   ~1s. **But** VLCKit renders into a GL/Metal layer that **freezes on any zoom**:
   a `scaleEffect` transform magnifies a screen-res frame (soft) *and* freezes; a
   real frame-resize re-renders crisp *but* stalls the player. Never crisp **and**
   live. That killed VLC for the zoom requirement, and we dropped the ~30 MB
   dependency (app went 111 MB → 19 MB).

## What finally worked, and why

**Fullscreen = WebRTC inside a `WKWebView`.** WebKit's WebRTC stack decodes H.265
(Safari's HEVC-WebRTC path), and the browser composites the `<video>` element, so
the scroll-view pinch-zoom stays **live and crisp**, no GL-layer freeze. We host a
tiny WHEP player page (`Crumb/Video/Web/WebRTCWebView.swift`), loaded with the
go2rtc base as its origin so `fetch('/api/webrtc?src=…')` is same-origin.

**Wall = native WebRTC.** N light peer connections to the H.264 sub-streams,
snapshot backdrop that fades on first frame, reconnect-on-scroll. Once the
go2rtc candidate fix landed, these connect live (they were silently on snapshots
before).

### Key files
- `apps/ios/Crumb/Video/Web/WebRTCWebView.swift`, fullscreen WKWebView WHEP player.
- `apps/ios/Crumb/Video/WebRTC/WebRTCManager.swift` + `WebRTCVideoView.swift`, wall tiles.
- `apps/ios/Crumb/Networking/MediaUrls.swift`, `whepURL` / `go2rtcBase`.

## Follow-ups
- **Auth (done).** Live WebRTC no longer hits go2rtc directly on the LAN; signaling
  now goes through the api's authenticated SDP proxy (`POST /live/{camera_id}/webrtc`).
  See `docs/COMPOSE.md` ("the security model") for the current posture.
- **macOS (done, native).** macOS shipped as a native SwiftUI target sharing the iOS
  codebase (not Mac Catalyst); see [IOS-APP-PLAN.md](IOS-APP-PLAN.md) for the live
  paths it uses.
- **PiP / AirPlay.** Deferred, non-trivial with the WebRTC paths.
