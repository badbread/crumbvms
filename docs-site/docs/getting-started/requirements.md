---
title: Requirements
sidebar_label: Requirements
slug: /getting-started/requirements
---

# Requirements

## Host

- **Operating system:** Linux, x86-64. The stack is Docker-based, so any
  distribution that runs a current Docker Engine works.
- **Docker + Docker Compose v2.** Check with `docker --version` and
  `docker compose version`. Confirm you can run Docker without `sudo`
  (`docker ps`), or plan on prefixing compose commands with `sudo`.
- **Disk space.** Cameras consume terabytes over time. Estimate from camera
  count, resolution, and how long you want to keep footage, and point the
  media path at a disk with real headroom. Storage is a broad root directory
  that both the recorder and the API mount; adding a second disk later is a
  matter of mounting it under that root and adding the path in the admin
  console, no reinstall needed.
- **Network.** Cameras and the Crumb host need to be reachable from each
  other, normally the same LAN. Clients (desktop, Android, the browser) also
  need to reach the host's HTTP port and, for live RTSP playback in native
  apps, the RTSP port.

## GPU (optional)

Not required. Motion detection runs on CPU by default
(`MOTION_HWACCEL=auto`), and recording itself is never re-encoded (`-c copy`
straight from the camera), so no decoder is needed for recording at all.
Hardware-accelerated motion decode is an opt-in overlay for Intel/AMD iGPUs
(VAAPI) or NVIDIA GPUs (NVDEC); see
[Hardware decode](/configuration/hardware-decode).

## Cameras

- RTSP-capable IP cameras. ONVIF support lets the setup wizard's discovery
  step find cameras and read their stream URLs automatically; cameras
  without ONVIF can still be added by hand with a known RTSP URL.
- H.264 or H.265 are both supported for recording (no server-side
  transcode); native clients decode H.265 directly.

## Images: pull or build

The default install path pulls prebuilt `api` and `recorder` container
images, so no Rust toolchain is needed on the host. That depends on the
project owner having published images for the repository or fork you are
running; if `docker compose pull` reports the images can't be found, the
build-from-source override handles it instead, still with no local Rust
toolchain required (the compile happens inside the build container). See
[Install with Docker Compose](/getting-started/install-docker-compose) for
both paths.

## Clients

Each native client has its own minimums:

| Client | Minimum |
|---|---|
| Web console | any modern browser, nothing to install |
| Windows desktop | Windows 10 or 11 (64-bit) |
| Android | Android 8.0 or newer |
| macOS | macOS 13 (Ventura) or newer |
| iOS | iOS 16 or newer (not yet distributable, see [iOS](/clients/ios)) |
| Linux desktop | build from source (see [Linux desktop](/clients/linux-desktop)) |

See [Clients](/clients/) for install steps and current status per platform.
