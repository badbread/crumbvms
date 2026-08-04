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

**A container dies with `not a directory: Are you trying to mount a
directory onto a file`,** naming `caddy/Caddyfile` or
`go2rtc/go2rtc.yaml`. That config file is missing from your copy of the
repo. Compose bind-mounts it into the container, and when the source file
doesn't exist Docker silently creates an empty **directory** in its place,
then fails to mount it over a file. The error describes the symptom, not
the cause.

Remove the directory Docker left behind and restore the real file:

```bash
rmdir caddy/Caddyfile          # the empty directory Docker created
git checkout -- caddy/Caddyfile
docker compose up -d
```

Both the `rmdir` and the restore are needed: leaving the directory in
place makes the next `up` fail exactly the same way. `scripts/setup-env.sh`
now checks for this before you start the stack, so re-running it will also
tell you which file is missing.

This usually means the deployment directory holds a partial copy of the
repo rather than a full checkout, which is easy to end up with when running
from prebuilt images and only copying what looks necessary.

## After startup

**`/health` stays `503`.** Give Postgres a moment to finish starting and
the migrations to run; check `docker compose logs postgres` if it doesn't
clear within a minute or two.

**GPU not found for motion decode.** Drop the GPU overlay and run on CPU
(`MOTION_HWACCEL=cpu`, the default); recording itself never needed the GPU in the
first place. See [Hardware decode](/configuration/hardware-decode).

**The recorder won't start, and the error mentions
`/run/nvidia-persistenced/socket: no such file or directory`.** The host's
NVIDIA driver was upgraded, but the machine hasn't been rebooted since, so
the kernel module still loaded in memory no longer matches the newly
installed userspace libraries. Confirm it with `nvidia-smi` on the host, a
mismatch reports:

```
Failed to initialize NVML: Driver/library version mismatch
```

**Fix: reboot the host.** Rolling Crumb back to an earlier image does not
help, the fault is on the host, not in Crumb.

This one is worth understanding because of *when* it bites. A container
that is already running keeps working fine after the driver upgrade,
because its GPU mounts were established before the upgrade happened. So
the stack looks completely healthy, sometimes for hours or days. The
failure only appears the next time a container is **recreated**, which
might be a Crumb update, a `docker compose up -d`, or an unrelated
restart. In other words the machine can quietly lose the ability to
restart its own recorder, and you find out at the worst moment. If your
host installs updates automatically (Ubuntu and Debian do by default),
see [Hardware decode](/configuration/hardware-decode) for how to stop
driver upgrades landing unattended.

Only installs that hand the recorder an NVIDIA device are affected. The
base stack boots GPU-free, and VAAPI installs are unaffected.

If a reboot has to wait and you would rather be recording than have GPU
stats, start the recorder without the GPU by dropping the GPU overlay from
your `docker compose` command. Note that removing the device reservation
alone is not enough, the NVIDIA container toolkit also activates on the
`NVIDIA_VISIBLE_DEVICES` environment variable, so that must be set to
`void` as well. Reboot at the next opportunity and put the overlay back.

**Motion events stopped and storage is filling faster than usual, on a VAAPI
(iGPU) install.** On a host with more than one GPU, the `/dev/dri/renderD*`
node numbers can reorder across a driver upgrade + reboot, so a
`MOTION_VAAPI_DEVICE` pinned to `renderD128` can end up pointing at a card
with no VAAPI. Motion decode then fails to initialise and the recorder falls
**open** to continuous recording, it keeps all footage, but silently. Confirm
it in the recorder logs:

```bash
docker compose logs recorder | grep -i "VAAPI decode init FAILING"
```

A match (or a raw `Failed to initialise VAAPI connection` from ffmpeg)
confirms the wrong render node. **Fix:** map the iGPU by its stable by-path
symlink instead of the bare number (`MOTION_VAAPI_DEVICE=/dev/dri/by-path/pci-<addr>-render`),
or switch motion decode to CPU, which is immune to this whole class of
problem. Both are covered in
[Hardware decode](/configuration/hardware-decode). If you set the decode mode
in the admin console, remember the stored DB value **overrides** the
`MOTION_HWACCEL` / `MOTION_VAAPI_DEVICE` env vars, change it in the console
too, or an env-only fix will appear to do nothing.

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
