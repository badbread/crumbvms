---
title: Hardware decode
sidebar_label: Hardware decode
slug: /configuration/hardware-decode
---

# Hardware-accelerated motion decode

Recording itself never re-encodes video, camera streams are copied
straight to disk. Only the motion-analysis path needs a decoder, and the
default stack runs that on CPU with no action required (`MOTION_HWACCEL=auto`,
which falls back to CPU whenever no supported GPU is present).

## Enabling it

Because Docker never lets a running container grant itself new devices,
mapping a GPU or iGPU into the recorder is always a host-side compose
change. The supported path is the bundled helper script:

```bash
scripts/enable-hwaccel.sh                # autodetects; or --backend vaapi|nvdec
```

It detects the host's hardware (render nodes under `/dev/dri` for VAAPI,
a working `nvidia-smi` plus the container toolkit for NVDEC), writes the
matching stanza into a gitignored `docker-compose.override.yml` (loaded
automatically by every plain `docker compose up -d`), and restarts the
recorder. It refuses to touch an existing override file, printing the
stanza to merge by hand instead, and refuses cleanly if no supported
hardware is present. Pass `--print` to see what it would write without
applying it.

## Manual overlays

If you'd rather see the moving parts, the committed overlay files at the
repository root do the same thing by hand:

**Intel/AMD iGPU (VAAPI):**

```bash
docker compose -f docker-compose.yml -f docker-compose.vaapi.example.yml up -d recorder
```

Set `RENDER_GID` in `.env` to the host's render-group GID
(`getent group render | cut -d: -f3`), and `MOTION_VAAPI_DEVICE` if the
iGPU's render node isn't the default `/dev/dri/renderD128`.

**NVIDIA (NVDEC):**

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.example.yml up -d recorder
```

Requires the NVIDIA driver and `nvidia-container-toolkit` on the host.

## Verifying what's actually active

A requested backend and an actually-active backend aren't always the same
thing, if the matching device isn't mapped into the container, the
recorder logs a warning and falls back to CPU rather than failing. Check
the truth with:

```bash
GET /config/decode-status
```

or the admin console's motion-decoding panel, which shows the same data:
per camera, the requested backend, the active one, and a human-readable
reason whenever they differ. `capabilities: null` means the recorder
hasn't reported in yet (an older image, or it just hasn't booted), not
that no devices exist.

A wrong pick is always safe: the recorder falls back to CPU automatically
rather than failing to decode at all.
