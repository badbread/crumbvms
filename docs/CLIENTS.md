# CrumbVMS clients, install & connect

CrumbVMS's server is the recorder. You watch live, scrub the timeline, and manage
cameras through a **client**. There are five:

| Client | Platform | Tech | How you get it |
|---|---|---|---|
| **Web admin** | any browser | served by the API at `/admin` | nothing to install |
| **Desktop** | Windows 10/11 | Flutter + native libmpv | installer from Releases |
| **Desktop** | Linux | Flutter + libmpv | build from source |
| **Apple** | macOS 13+ | native SwiftUI | zip from Releases |
| **Apple / mobile** | iOS 16+ | native SwiftUI | *TestFlight, not set up yet* |
| **Android** | Android 8.0+ | Kotlin / Media3 | `.apk` from Releases |

> **Honest status (alpha).** The web console is production-ready. The
> **Windows desktop and Android** clients are the daily-driver, most-tested
> clients. **macOS and iOS** work and are ready to try, but are rougher. There
> are **no signed installers or app-store listings yet**, you sideload, and
> your OS will warn you about an unsigned app (steps below to get past it). This
> is expected for a self-hosted alpha.

---

## Before you install any native client

You need three things:

1. **A running CrumbVMS server** on your LAN (or reachable over your own VPN /
   Tailscale). See the [README](../README.md) "Run" section or
   [docs/AI-INSTALL.md](AI-INSTALL.md).
2. **An account**, your admin login, or a user the admin created for you.
3. **The server reachable** on port **8080** (HTTP) or **8443** (HTTPS). Native
   clients can auto-discover it ("Find my server" scans your subnet), or you
   type the address in yourself.

> **Live video needs one server-side setting.** For native clients to play live
> RTSP, the admin must set the server's reachable stream address once, in the
> web console under **Server & streaming** (e.g. `rtsp://<server-host>:18554`).
> The web console itself works without it. If native clients connect and list
> cameras but live panes stay black, this is almost always why.

---

## Web console (no install)

Open **`http://<server-host>:8080/admin`** in any browser. On first server run
you create the administrator here. The web console covers admin, live view,
playback, clips, and export, it's the fastest way to confirm your server works
before installing anything native.

---

## Android

**Requires:** Android 8.0 or newer.

1. On the **Releases** page, download the latest `app-release.apk`.
2. Your browser/Files app will ask to allow installing unknown apps, allow it
   for that app (Settings → Apps → *that app* → Install unknown apps). This is
   normal for any app not from the Play Store.
3. Open the downloaded `.apk` → **Install**.
4. Launch CrumbVMS → **Find my server** (scans your Wi-Fi network) or tap **Enter
   manually** and type `http://<server-host>:8080`. Log in.

**Verify the download (optional but recommended).** Because the alpha APK isn't
distributed through a paid code-signing / Play Store channel, each release also
publishes an `app-release.apk.sha256` checksum file next to the APK. Download
both into the same folder and confirm they match before installing:

```bash
sha256sum -c app-release.apk.sha256   # Linux/macOS; prints "OK"
# Windows PowerShell:
(Get-FileHash app-release.apk -Algorithm SHA256).Hash -eq `
  (Get-Content app-release.apk.sha256).Split(' ')[0].Trim()
```

CrumbVMS is not on the Play Store during the alpha; sideloading the APK is the
expected path. Updates = download the newer APK and install over the top (it
keeps your saved views and settings).

---

## Windows desktop

**Requires:** Windows 10 or 11 (64-bit). The desktop client is a native
**Flutter** app (video renders through `media_kit`/libmpv), no WebView2 or other
runtime to install.

1. On the **Releases** page, download the Windows installer for CrumbVMS.
   `libmpv-2.dll` is bundled with it, so there's no separate file to manage and
   nothing to copy next to the exe by hand.
2. Run the installer. Windows **SmartScreen** will warn about an unrecognized app
   (it's unsigned during the alpha): click **More info → Run anyway**, then install.
3. Launch **CrumbVMS** from the Start Menu.
4. Use **Find my server** or enter `http://<server-host>:8080`, then log in.

Updates = run the newer installer over the top.

---

## macOS (Apple desktop app)

**Requires:** macOS 13 (Ventura) or newer; Apple silicon or Intel.

1. On the **Releases** page, download `CrumbVMS-macos-<version>.zip`.
2. Unzip it and drag **`CrumbVMS.app`** to **Applications**.
3. **First launch:** right-click (or Control-click) `CrumbVMS.app` → **Open** →
   **Open** again. This is required because the app isn't notarized during the
   alpha, a normal double-click will be blocked by Gatekeeper with "cannot be
   opened." You only need the right-click-Open once.
4. Use **Find my server** or enter `http://<server-host>:8080`, then log in.

---

## iOS (Apple mobile app)

**Requires:** iOS 16 or newer.

**Status: built and working, but not yet distributable.** The iOS app runs today
(it shares the macOS SwiftUI codebase), but there is **no iOS tester path yet.**
Apple doesn't allow sideloading a build onto someone else's iPhone the way Android
does, the only route to testers is **TestFlight**, which requires the paid
**Apple Developer Program** (~$99/year) that hasn't been set up. Until then, iOS
is "works on the maintainer's phone," not something you can install.

Once TestFlight is set up, this becomes: install the **TestFlight** app from the
App Store, open your invite, tap **Install**, then point the app at your server
(**Find my server** or `http://<server-host>:8080`). TestFlight handles updates
automatically.

---

## Linux desktop (from source)

There's no prebuilt Linux artifact yet. Build the Flutter client from source on a
machine with the Flutter SDK, Rust (the client keeps a Rust core via
`flutter_rust_bridge`), and libmpv dev libraries, see `apps/desktop-flutter/`.
Video renders through `media_kit`/libmpv.

---

## Connecting a client to your server (all native clients)

Every native client asks for your server on first run:

- **Find my server**, scans your local subnet for a CrumbVMS server on ports 8080
  and 8443 and lists what it finds. Easiest on a normal home LAN.
- **Enter manually**, type `http://<server-host>:8080` (or `https://…:8443` if
  you set up TLS). Use this over a VPN / Tailscale, or when discovery is blocked
  by client isolation on your Wi-Fi.

Then sign in with your CrumbVMS account. What you can see and do (which cameras,
whether you can play back recordings, export, PTZ, etc.) follows the **role**
your admin assigned you, a limited account may see only some cameras or live
only, by design.

**If live is black but cameras list fine:** the server's RTSP reachable address
isn't set, ask your admin to set it under **Server & streaming** (see the note
at the top).

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| "Find my server" finds nothing | Wi-Fi **client isolation** (common on guest networks) blocks device-to-device traffic, enter the address manually, or join the same LAN segment as the server. |
| Connects, lists cameras, live panes black | Server RTSP address not set (**Server & streaming**), or the client can't reach port **18554**. |
| Windows: video panes black | The bundled `libmpv-2.dll` isn't next to `CrumbVMS.exe`, reinstall with the installer rather than copying the exe out by hand. |
| Windows: "Windows protected your PC" | SmartScreen on the unsigned alpha build, **More info → Run anyway**. |
| macOS: "CrumbVMS can't be opened" | Gatekeeper on the un-notarized alpha build, **right-click → Open** the first time. |
| Android: "app not installed" | You already have a build signed with a *different* key, uninstall the old one first (this won't happen for updates of the same alpha build). |
