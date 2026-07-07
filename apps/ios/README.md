# Crumb iOS

Native SwiftUI client for the Crumb VMS (iOS 16+). Talks to the unchanged Crumb
API; mirrors the Android app's behavior. See
[../../docs/IOS-APP-PLAN.md](../../docs/IOS-APP-PLAN.md) for the build plan and
[../../docs/IOS-LIVE-VIDEO.md](../../docs/IOS-LIVE-VIDEO.md) for the live-video
architecture (and the dead ends, read it before touching live video).

## Build

The Xcode project is **generated** from `project.yml` with
[XcodeGen](https://github.com/yonyz/XcodeGen), `Crumb.xcodeproj` is gitignored.

```sh
brew install xcodegen
cd apps/ios
xcodegen generate        # writes Crumb.xcodeproj
open Crumb.xcodeproj      # then set your signing Team and Run
```

CLI build/deploy to a connected device:
```sh
xcodebuild build -project Crumb.xcodeproj -scheme Crumb \
  -destination 'platform=iOS,id=<device-udid>' -allowProvisioningUpdates
```

## Dependencies (SPM, pinned in project.yml)

- `stasel/WebRTC`, native WebRTC for the live-wall tiles (H.264 sub-streams).

Fullscreen live uses `WKWebView` + WebRTC (no extra dependency) because WebKit
decodes H.265, which native libwebrtc on iOS cannot.

## ⚠️ Server prerequisite for live video

Live WebRTC needs go2rtc to advertise a **LAN-reachable ICE candidate** and the
media port published, or it silently falls back to ~1 fps snapshots. See
[../../docs/IOS-LIVE-VIDEO.md](../../docs/IOS-LIVE-VIDEO.md):

- `go2rtc.yaml` → `webrtc.candidates: [ ${WEBRTC_CANDIDATE}, stun:8556 ]`
- `docker-compose.yml` → publish `8556:8556` tcp+udp
- `.env` → `WEBRTC_CANDIDATE=<server-LAN-ip>:8556`

(Port 8556, not go2rtc's default 8555, to avoid colliding with a host-network
Frigate that may already own 8555.)
