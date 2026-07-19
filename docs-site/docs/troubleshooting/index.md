---
title: Troubleshooting
sidebar_label: Overview
slug: /troubleshooting/
---

# Troubleshooting

Common issues, roughly in the order you're likely to hit them: getting the
stack up, first-run setup, and everyday client connection problems.

## Docker Compose won't start

**`docker compose` fails outright.** Either the Docker daemon isn't
running, or your user lacks permission to talk to it. Confirm with
`docker ps`; if that also fails, fix Docker access before anything else.

**`docker compose up` refuses to start, mentioning `GO2RTC_USER` or
`GO2RTC_PASS` "is required."** `.env` is missing those keys, usually
because it was hand-edited or copied from `.env.example` without filling
them in. Re-run `scripts/setup-env.sh` rather than inventing values; the
compose file deliberately has no insecure fallback for these two.

**`docker compose pull` errors with "not found," "denied," or a 403** on
the `ghcr.io/badbread/crumbvms/...` images. Images aren't published for the
repository or fork you're running yet. Use the build-from-source override
instead:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

**A published port is already in use.** Another service on the host owns
it. Remap the conflicting port in `docker-compose.yml`, or override
`CRUMB_HTTPS_PORT` in `.env` for the Caddy HTTPS port.

## After startup

**`/health` stays `503`.** Give Postgres a moment to finish starting and
the migrations to run; check `docker compose logs postgres` if it doesn't
clear within a minute or two.

**GPU not found for motion decode.** Drop the GPU overlay and run on CPU
(`MOTION_HWACCEL=auto`); recording itself never needed the GPU in the
first place. See [Hardware decode](/configuration/hardware-decode).

## Cameras

**A camera won't connect.** Usually a wrong RTSP URL or credentials.
Verify the stream URL independently (`ffprobe`, or VLC's network stream
open) before assuming Crumb is at fault; the admin console's test-stream
action does the same check server-side when adding a camera.

## Native clients

**Browser warns "not private" or "not trusted" at the HTTPS port.**
Expected on a fresh install using Caddy's self-signed internal certificate
authority, not a sign of misconfiguration. See [TLS](/configuration/tls)
for clicking through it once, or trusting the certificate authority
properly.

**Native client connects and lists cameras, but live video panes stay
black.** By far the most common native-client issue: the server's
reachable streaming address hasn't been set in the admin console. See
[Server settings](/configuration/server-settings).

**"Find my server" finds nothing.** Wi-Fi client isolation, common on
guest networks, blocks device-to-device discovery traffic. Enter the
server address manually instead, or join the same network segment as the
server.

**Windows: video panes black even though the app connects.** `libmpv-2.dll`
isn't sitting next to `crumb_desktop.exe`; re-unzip the release rather than
moving files by hand. See [Windows desktop](/clients/windows-desktop).

**Windows: "Windows protected your PC."** SmartScreen flagging the
unsigned alpha build; "More info" then "Run anyway."

**macOS: "CrumbVMS can't be opened."** Gatekeeper on the un-notarized alpha
build; right-click the app, choose Open, then Open again, just the first
time. See [macOS](/clients/macos).

**Android: "app not installed."** A build signed with a different key is
already present; uninstall the old one first. This shouldn't happen for a
normal update of the same alpha build. See [Android](/clients/android).

## Getting help

Crumb is a one-maintainer side project without a formal support channel
yet. If you've worked through the above and are still stuck, check the
project's GitHub repository for how to open an issue, and include your
Crumb version, how you deployed (Docker Compose, which client build), and
what you've already tried.
