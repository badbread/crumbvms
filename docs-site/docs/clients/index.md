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
| Desktop | Windows 10/11 | installer from Releases |
| Desktop | Linux | build from source |
| Apple desktop | macOS 13+ | zip from Releases |
| Apple mobile | iOS 16+ | not yet distributable, see [iOS](/clients/ios) |
| Android | Android 8.0+ | `.apk` from Releases |

**Honest status.** The web console is production-ready. The Windows
desktop and Android clients are the daily-driver, most-tested paths.
macOS and iOS both work and are ready to try, but are rougher. None of the
native clients have a signed installer or app-store listing yet, so
installing one means sideloading and getting past your OS's warning about
an unrecognized app. That's expected for a self-hosted project without a
release budget behind it yet, not a sign of anything wrong with the build.

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
