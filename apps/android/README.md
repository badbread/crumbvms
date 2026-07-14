# Crumb, Android client

Native Android client for the Crumb NVR. Kotlin + Jetpack Compose, with
**Media3/ExoPlayer** for all video (hardware decode via MediaCodec), no
WebView, no React Native. Built to match the scrub feel of the desktop/web
clients within mobile constraints.

## Features (v1)

- **Auth**, login against the API (admin/viewer), token stored in
  `EncryptedSharedPreferences`. Server URL is configurable on the login screen
  (so it works over Tailscale).
- **Live**, camera wall with 1 / 2×2 / list layouts. Grid tiles pull the
  **sub-stream** (low bandwidth); tap a tile for a full-screen **main-stream**
  view. RTSP via go2rtc, hardware-decoded by ExoPlayer.
- **Playback**, single-camera, color-coded timeline scrubber (recorded =
  blue, motion = amber), filmstrip thumbnails while dragging, play/pause,
  0.5–8× speed, jump to next/prev motion, jump to time. Continuous playback
  stitches consecutive segments.
- **Export**, pick cameras + a time window, burn-in toggle, submit an export
  job, poll to completion, then save the MP4 to the device's public **Downloads**
  (`MediaStore`, folder `CrumbVMS/`) or share it. Both fetch the bytes with the
  session token in an `Authorization` header (never in the URL) — Download writes
  to Downloads, Share hands off a scoped `content://` FileProvider Uri.

## Architecture

```
app/src/main/java/com/crumb/nvr/
  data/        Retrofit API, kotlinx.serialization models, repository,
               EncryptedSharedPreferences store, media-URL builder (?token=)
  di/          AppContainer (manual DI, no Hilt/KSP), appContainer() accessor
  ui/theme/    Material3 dark theme + brand palette + timeline colors
  ui/player/   Shared PlayerSurface (Media3 PlayerView) + MediaFactory
  ui/nav/      Route constants
  ui/Time.kt   RFC-3339 <-> display time helpers
  feature/auth, feature/live, feature/playback, feature/export
  MainActivity.kt   NavHost wiring
```

Browser-style media elements (ExoPlayer/Coil) can't set an `Authorization`
header, so streaming media URLs carry a short-lived scoped `?token=`, the API
accepts this on `/segments` and `/filmstrip/*/frame`. Export downloads, by
contrast, go through an in-app authenticated request (bearer header, never a
token in the URL) — see `feature/export`.

## Build

Requires **JDK 21** and the **Android SDK** (platform `android-34`,
build-tools `34.0.0`). The repo includes a Gradle wrapper (Gradle 8.10.2).

```bash
# point Gradle at your SDK
echo "sdk.dir=/path/to/Android/Sdk" > local.properties

./gradlew assembleDebug          # -> app/build/outputs/apk/debug/app-debug.apk
```

On the homelab dev box (`build-host`) the toolchain is already installed; the helper
env is sourced from `~/.crumb-android-env`:

```bash
ssh build-host
source ~/.crumb-android-env
cd ~/crumb-android-src/android
./gradlew assembleDebug
```

## Install

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Or sideload `crumb-debug.apk` directly (enable "install unknown apps").

The default server URL is baked at build time
(`DEFAULT_SERVER_URL` in `app/build.gradle.kts`, currently
`http://192.0.2.10:8080`) and is overridable on the login screen.

## Known limitations (v1)

- The camera list uses the admin-only `/config/cameras` endpoint; **viewer**
  accounts see an explanatory empty state until a viewer-scoped camera-list
  endpoint exists (shared gap with the web client).
- Cleartext HTTP is allowed (`usesCleartextTraffic=true`) for LAN/Tailscale use.
- Notifications (motion alerts) are a Phase-2 seam, not built in v1.
- Multi-cam synced playback is desktop-only; phone playback is single-camera.
