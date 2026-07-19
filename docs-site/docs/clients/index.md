---
title: Clients
sidebar_label: Overview
slug: /clients/
---

# Clients

Crumb's server is the recorder. You watch live video, scrub the timeline,
and manage cameras through a client. There are five, covering six
platforms:

| Client | Platform | How you get it |
|---|---|---|
| Web admin | any browser | nothing to install, served by the server itself |
| Desktop | Windows 10/11 | zip from Releases |
| Desktop | Linux | build from source |
| Apple desktop | macOS 13+ | zip from Releases |
| Apple mobile | iOS 16+ | not yet distributable, see [iOS](/clients/ios) |
| Android | Android 8.0+ | `.apk` from Releases |

**Honest status.** The web console is production-ready for administration. The
Windows desktop and Android clients are the daily-driver, most-tested paths for
actually watching video, and they carry the newest features. macOS and iOS both
work and are ready to try, but are rougher and lag on features. None of the
native clients have a signed installer or app-store listing yet, so installing
one means sideloading and getting past your OS's warning about an unrecognized
app. That's expected for a self-hosted project without a release budget behind
it yet, not a sign of anything wrong with the build.

## What each client can do

The clients don't all do the same things yet. The Windows desktop and Android
clients are where I build first, so they're the most complete. The macOS and
iOS apps share one SwiftUI codebase and cover the core watch-and-review path but
don't have the newer surfaces. The web console administers the server but plays
no video.

| Feature | Web console | Windows desktop | Android | macOS / iOS |
|---|---|---|---|---|
| Camera & server administration | yes | partial (embedded console pane) | no | no |
| Live view | no | yes | yes | yes |
| Timeline playback | no | yes | yes | yes |
| Clips & export | no | yes | yes | yes |
| PTZ controls | no | yes | yes | no |
| Data-saver / adaptive quality | n/a | yes (Data-saver tier, "SD" chip) | yes (Auto / Full / Data-saver) | no |
| LPR (license-plate) reads tab | configures LPR | yes | yes | no |
| Home Assistant | configures & links | entity overlay on live video | read-only entity sheet | no |
| Snapshot button | no | yes | yes (single-camera views) | no |

Notes:

- **Data-saver / adaptive quality** plays a low-bitrate transcode to save
  bandwidth. On desktop it's a per-camera stream tier marked with an "SD" chip;
  on Android the quality control is Auto / Full / Data-saver, where Auto uses
  full quality on Wi-Fi and Data-saver on a metered connection.
- **LPR** reads are browsed in the desktop and Android LPR tab (plate crops,
  watchlist search, fuzzy preview). The web console is where LPR is configured
  (engine, detection zones, watchlist).
- **Home Assistant** is configured and linked in the web console. The desktop
  client paints linked entity states as an overlay on live video; Android shows
  a read-only per-camera entity sheet.

## Before installing any native client

You need three things:

1. **A running Crumb server** on your LAN, or reachable over your own VPN.
   See [Install with Docker Compose](/getting-started/install-docker-compose).
2. **An account**, your admin login or one an admin created for you.
3. **The server reachable** on port 8080 (HTTP) or 8443 (HTTPS). Native
   clients can auto-discover it with "Find my server," which scans your
   subnet, or you can type the address in by hand.

**Live video needs one server-side setting.** For native clients to play
live RTSP, an admin sets the server's reachable streaming address once, in
the console under Server & streaming. If native clients connect and list
cameras but live panes stay black, this is almost always why; see
[Server settings](/configuration/server-settings).

## Connecting any native client

Every native client asks for your server on first run. "Find my server"
scans your local subnet and lists what it finds, easiest on a normal home
network. "Enter manually" takes `http://<server-host>:8080` (or
`https://…:8443` with TLS set up), the path to use over a VPN or when
discovery is blocked by client isolation on your Wi-Fi.

What you can see and do afterward, which cameras, whether you can play
back, export, or use PTZ, follows the role your account was assigned. A
limited account may only see some cameras, or only live view, by design.

## In this section

- [Android](/clients/android)
- [Windows desktop](/clients/windows-desktop)
- [Linux desktop](/clients/linux-desktop)
- [macOS](/clients/macos)
- [iOS](/clients/ios)
- [Web console](/clients/web-console)
