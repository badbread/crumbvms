# Crumb, Apple clients (iOS + macOS): current state

**Status:** IMPLEMENTED. This document originally described a pre-build plan (authored
2026-06-16); it has been rewritten (2026-07-02) to describe what actually shipped, since the
plan and the built app diverged in several places (most notably: macOS is a **native SwiftUI
target sharing the iOS codebase**, not Mac Catalyst, and live video is **WebRTC on iOS /
fMP4+VideoToolbox on macOS**, not HLS). Treat this as the source of truth for "what the Apple
clients do today"; see `apps/ios/Crumb/` for the code.

## TL;DR

A single Xcode project (`apps/ios/Crumb.xcodeproj`, generated from `project.yml`) builds two
targets, **`Crumb`** (iOS 16+) and **`Crumb-mac`** (macOS 13+), sharing one SwiftUI codebase
under `apps/ios/Crumb/`, split by `#if os(iOS)` / `#if os(macOS)` only where the platforms
genuinely differ (video transport, mouse vs. touch gestures, window chrome). Both talk to the
same Crumb API the Android/desktop/web clients use, same JWT auth, same endpoints, same
`?token=` media-auth scheme.

## Live video: what actually shipped (differs from the original plan)

The original plan assumed HLS-first-then-WebRTC. What shipped instead, per platform:

| Platform | Live transport | Why |
|---|---|---|
| **iOS** | **WebRTC** (`Video/WebRTC/WebRTCManager.swift`, `WebRTCVideoView.swift`, via the `stasel/WebRTC` SPM package) against go2rtc's WHEP-style signaling, rendered in a `WKWebView`. Sub-second latency from day one, the HLS "ship something simple first" phase was skipped once WebRTC proved tractable. | H.264 sub-streams decode fine in the WKWebView's WebRTC stack; **H.265/HEVC does not** (no browser HEVC WebRTC decode), which is why the fMP4 path below exists. |
| **iOS (H.265 cameras) + macOS (all live)** | **go2rtc fragmented-MP4** (`/api/stream.mp4`, passthrough, H.265 stays H.265) demuxed incrementally client-side (`Video/Fmp4/Fmp4Demuxer.swift`) into `CMSampleBuffer`s, decoded by **VideoToolbox**, and displayed on an `AVSampleBufferDisplayLayer` (`Fmp4Player.swift`, `Fmp4VideoView`). This is the smooth, full-res path for cameras the WKWebView/WebRTC route can't handle, and macOS's whole live-wall path (macOS has no WKWebView-based WebRTC live view at all). | Native hardware H.265 decode with none of the WKWebView/WebRTC-in-a-browser overhead; the same VideoToolbox decoder recorded playback already uses. |
| **Both** | **Recorded playback**: `AVPlayer`/`AVPlayerLayer` over `/segments/{id}` (native progressive-download HTTP with server-side Range support), with an `AVAssetResourceLoaderDelegate`-based **probe-first, range-streamed** HEVC `hev1`→`hvc1` retag only when the segment actually needs it, see "Instant seek" below. | `AVPlayer` speaks fMP4-over-HTTP natively; no custom demuxer needed for finite, seekable files (only the endless live stream needs `Fmp4Demuxer`). |

## Instant recorded-playback seek (the M4 rework, read this before touching `HEVCRetag.swift`)

Recorded fMP4 segments are muxed by `ffmpeg -c copy`, which tags HEVC sample entries `hev1` —
a FourCC **AVFoundation refuses to decode** (it requires `hvc1`; ExoPlayer on Android accepts
both, which is why this is Apple-only). An early implementation "fixed" this by downloading the
**entire segment**, patching the FourCC in memory, and serving it from a byte buffer, which
meant every scrubber jump blocked on a full-segment download. That is gone. The current design
(`Features/Playback/HEVCRetag.swift`, wired from `SegmentPlayer.feed` in `PlaybackView.swift`):

1. **Probe, don't download** (`HEVCRetag.probe(url:)`): a bounded, growing `Range:` GET (starts
   at 64 KB, grows to a max of 4 MB) reads just far enough to capture a complete `moov` box and
   inspect its video sample entry's FourCC.
2. **`hvc1` / AVC (`avc1`/`avc3`) / no video track → passthrough.** The origin
   `/segments/{id}?token=...` URL is handed straight to a plain `AVURLAsset`, AVPlayer performs
   its own native HTTP range requests against the server's `ServeFile`-backed Range support
   (`services/api/src/playback.rs`), so seeking is exactly as instant as any ordinary
   progressive-download HTTP asset. Zero app code sits in the loading path.
3. **`hev1` → range-streamed retag** (`HEVCRetagLoaderDelegate`, still on the `crumbhevc://`
   custom scheme): only the small `moov` header is fetched and patched in memory (the original
   byte-for-byte `hev1`→`hvc1` rewrite, unchanged and still correct). Every other byte range
   AVFoundation asks for, i.e. the `moof`/`mdat` fragments that make up nearly the entire file
  , is **proxied straight through** to the origin with a matching `Range:` header and streamed
   back as it arrives; nothing beyond the header is ever fully buffered. A scrubber jump now
   costs one bounded range request, not a whole-file download.
4. **Inconclusive probe → whole-file fallback.** If the box layout can't be confidently parsed
   within the probe budget, `HEVCRetagLoaderDelegate` falls back to the original
   download-then-patch-then-serve behavior rather than risking a broken/black player. Correctness
   beats performance when the fast path can't be trusted.

## Architecture (as built, not as planned)

```
apps/ios/Crumb/
  App/            CrumbApp.swift (@main, RootView incl. biometric-lock gate), AppContainer (DI),
                  AppSettings (UserDefaults prefs), Theme
  Networking/      CrumbAPI (async URLSession), KeychainStore (JWT), MediaUrls (?token= URLs),
                  MediaSession (ephemeral URLSession for tokened media), ServerDiscovery (LAN
                  /health subnet scan)
  Models/         Codable DTOs mirroring services/api/src/dto.rs + Android's data/Models.kt
  Features/
    Auth/         LoginView + AuthViewModel (login, LAN auto-discovery)
    Live/         LiveWallView (grid + custom pane layouts on macOS), LiveFullscreenView
                  (WebRTC/fMP4 + PiP + PTZ), CameraTileView, LiveViewModel (camera-list
                  self-heal, server-backed saved views), ViewEditorView / LayoutEditorView
    Playback/     PlaybackView (SegmentPlayer + PiP), CenteredTimelineView (Canvas, precomputed
                  spans/detections), HEVCRetag (probe + range-streamed retag), PlaybackViewModel
    Clips/        ClipsView, ClipPlayerView (motion-highlight auto-zoom)
    Export/       ExportView + ExportViewModel (NSSavePanel on macOS, Share sheet on iOS)
    Bookmarks/    BookmarksView (server-backed, shared with all clients)
    Tuner/        MotionTunerView (admin-only motion-sensitivity/mask editor)
    Settings/     SettingsView (incl. biometric-lock toggle), AboutView
  Video/
    WebRTC/       WebRTCManager, WebRTCVideoView (iOS live, WKWebView-hosted)
    Fmp4/         Fmp4Demuxer (incremental box parser for the endless live stream),
                  Fmp4Player (Fmp4VideoView, VideoToolbox + AVSampleBufferDisplayLayer)
  Platform/       Platform.swift (cross-platform SwiftUI shims), PlayerLayerView
                  (AVPlayerLayer host), Zoomable (pinch/pan/scroll-zoom), MacTopNav,
                  BiometricLock (Face ID/Touch ID/passcode app-lock), PictureInPicture
                  (AVPlayerLayer + AVSampleBufferDisplayLayer PiP controllers)
  UI/             CenteredTimelineView helpers, ViewChipsView, ModeTabs, dialogs
```

- **Auth:** JWT in **Keychain** (`KeychainStore`); `Authorization: Bearer` on every authenticated
  API call. A 401 clears the session (`KeychainStore.clearSession()`), which `AppContainer`
  observes to flip back to `LoginView`.
- **Media auth:** segment bytes, filmstrip frames, event snapshots, export downloads are tokened
  URLs (`?token=`) fetched via the ephemeral `.crumbMedia` `URLSession` (never the disk-cached
  `.shared` session, so the token never touches disk), `AVPlayer`/`AsyncImage`-equivalent
  (`TokenedAsyncImage`) call sites can't set an `Authorization` header.
- **Server URL** is user-entered and editable in Settings; **LAN auto-discovery**
  (`ServerDiscovery.swift`) scans the device's /24 for `GET /health` matching the
  `"service":"crumb-api"` fingerprint (a unicast TCP scan, not mDNS, the API runs in a bridged
  Docker container that multicast never reaches), mirroring Android's `ServerDiscovery.kt`.

## Feature parity with Android/desktop (implemented)

- **Server-backed saved views** (`/views` API, GET/POST/DELETE): `LiveViewModel.loadViews()` /
  `createView()` / `deleteView()`, wired into `LiveWallView`'s view chips. Views are owner-scoped
  and shared across all clients; "editing" a view is delete-then-recreate (the server has no
  update endpoint). The macOS custom pane `ViewLayout` doesn't currently round-trip through
  `/views` (server contract is ordered camera-id slots only), tracked as a follow-up, not a
  regression versus the old device-local-only store.
- **Camera-list self-heal:** `LiveViewModel.loadCameras()` retries once (with a short backoff) on
  an empty response or a transient failure before surfacing an error; a 401 defers to the
  existing logout/re-auth path instead of leaving a blank wall.
- **Biometric app-lock** (opt-in, off by default): `Platform/BiometricLock.swift` uses
  `LocalAuthentication`'s `deviceOwnerAuthentication` policy (Face ID/Touch ID, falling back to
  the device passcode/macOS password). Gates `RootView` on cold launch and iOS background→
  foreground transitions when enabled (Settings → Account).
- **Picture-in-Picture** (iOS only): `Platform/PictureInPicture.swift` provides
  `PlayerPictureInPicture` (`AVPlayerLayer`-based, for recorded playback) and
  `LivePictureInPicture` (`AVSampleBufferDisplayLayer` content-source PiP, for the live fMP4
  view). macOS has no PiP concept here, matching the desktop Tauri client.
- **`.textContentType` autofill hints** on the login form's server/username/password fields
  (`Platform.textContentTypeCompat`, mapped to `UITextContentType` on iOS / `NSTextContentType`
  on macOS, `NSTextContentType.URL` needs macOS 14+ so the macOS build skips that one hint at
  the current macOS-13 deployment target).
- **macOS App Sandbox:** `Crumb-macOS.entitlements` carries `com.apple.security.app-sandbox` +
  the two entitlements the app actually needs, `network.client` (talks to the user's own
  server) and `files.user-selected.read-write` (the Export sheet's `NSSavePanel` save flow).
- **Demuxer resync:** `Fmp4Demuxer.parse()` scans forward for the next plausible top-level box
  boundary on a malformed/corrupt box instead of stalling the whole live stream until the
  buffer's 8 MB safety-valve wipes it.
- **Timeline precompute:** `CenteredTimelineView` parses `spans`/`detectionEvents` once per data
  change (`.task(id:)` keyed on a cheap count+boundary identity) instead of re-parsing ISO-8601
  timestamps on every `Canvas` redraw (i.e. every scrub tick).

## What's still Android-only / not yet on Apple

- Push notifications (APNs) for motion/detection alerts; the backend has the notification
  scaffold, but an APNs transport is unbuilt on Apple.
- Low-bandwidth snapshot-poll mode (Android's `lowbw` toggle).

## Stack

SwiftUI (iOS 16+ / macOS 13+), `URLSession` + `async/await` + `Codable`, `AVPlayer`/
`AVPlayerLayer` for recorded playback, WebRTC (iOS)/VideoToolbox+fMP4 (both, esp. macOS) for
live, Keychain for the JWT, `?token=` media auth, SF Symbols for detection glyphs,
`LocalAuthentication` for the app-lock, `AVKit`'s `AVPictureInPictureController` for PiP. Not
cross-platform, native throughout, sharing one codebase across the two Apple targets via
`#if os()`.
