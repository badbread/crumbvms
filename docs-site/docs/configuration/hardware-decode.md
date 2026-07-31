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

On a host with more than one GPU, point `MOTION_VAAPI_DEVICE` at the iGPU's
**stable by-path symlink** rather than a bare `renderD128`, see
[Keeping a VAAPI (iGPU) host stable](#keeping-a-vaapi-igpu-host-stable) below
for why this matters.

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

:::note The DB setting wins over the env var
If you set the decode mode in the admin console, that value is stored in the
database (`server_settings.motion_hwaccel` / `motion_vaapi_device`) and
**overrides** the `MOTION_HWACCEL` / `MOTION_VAAPI_DEVICE` environment
variables. Changing the env var then has no effect until you also change it in
the console (or clear the stored value). This trips people up during recovery:
an env-only fix looks correct but does nothing while a DB value is set.
:::

## Keeping a VAAPI (iGPU) host stable

This section only matters if you gave the recorder an Intel/AMD iGPU via VAAPI,
**and the host has more than one GPU** (a common case: an iGPU for decode plus a
discrete NVIDIA card). CPU and single-GPU installs can skip it.

The `/dev/dri/renderD128`, `renderD129`, ... node **numbers** are assigned at
boot and are not guaranteed stable across reboots when multiple GPUs are
present. A GPU-driver upgrade followed by a reboot can renumber them, moving the
iGPU from `renderD128` to `renderD129` and handing `renderD128` to the other
card.

If `MOTION_VAAPI_DEVICE` still names `renderD128`, VAAPI decode now points at a
card with no VAAPI. Every motion-decode ffmpeg process exits immediately with
`Failed to initialise VAAPI connection`, motion detection stops producing
frames, and the recorder **fails open to continuous recording**, it keeps all
footage, but does so silently, so nothing looks broken until you notice motion
events have stopped or storage is filling faster than expected. (The recorder
now logs a distinct, greppable `ERROR` line for exactly this case, search the
recorder logs for `VAAPI decode init FAILING`.)

**Robust fix: map the iGPU by its stable by-path symlink.** Every render node
also has a name under `/dev/dri/by-path/` that is derived from the GPU's PCI
address, which does not change across reboots. Point `MOTION_VAAPI_DEVICE` at
that instead of the volatile number:

```bash
ls -l /dev/dri/by-path
# find the *-render entry whose target is your iGPU's renderD* node, e.g.
#   pci-0000:00:02.0-render -> ../renderD128
```

```ini
# .env  (0000:00:02.0 is the classic Intel iGPU address; use YOURS)
MOTION_VAAPI_DEVICE=/dev/dri/by-path/pci-0000:00:02.0-render
```

ffmpeg follows the symlink to whichever `renderD*` the iGPU currently owns, so a
future driver upgrade can no longer repoint decode at the wrong card.

**Immune-by-design alternative: use CPU decode.** Motion analysis runs at a
downscaled ~320px, ~5 fps, so software decode is cheap, and it cannot be
affected by render-node reordering, driver mismatches, or device-mapping
problems at all. If the iGPU's power savings don't justify the extra operational
fragility on your host, `MOTION_HWACCEL=cpu` (or the console's CPU option) is a
safe, robust choice.

## Keeping an NVIDIA host stable

This section only matters if you gave the recorder an NVIDIA GPU. VAAPI
and CPU installs can skip it.

Upgrading the host's NVIDIA driver replaces the userspace libraries, but
the kernel module already loaded in memory stays at the old version until
the machine reboots. Until then the two disagree, `nvidia-smi` reports
`Driver/library version mismatch`, and Docker can no longer start a
container that asks for the GPU.

The dangerous part is the delay. Containers that are already running keep
working, because their GPU mounts were established before the upgrade. The
stack looks healthy, possibly for days. The breakage only surfaces the next
time a container is **recreated**, so a machine can silently lose the
ability to restart its own recorder and only reveal it during an update, or
after a power cut. For a recorder that is supposed to be running
unattended, that is a bad way to find out.

Two things make this much less likely to catch you:

**Reboot after a driver upgrade.** Not eventually, as part of the upgrade.
Then confirm with `nvidia-smi` before assuming you are back.

**Don't let driver upgrades happen unattended.** Ubuntu and Debian enable
`unattended-upgrades` out of the box, so this can happen without anyone
running `apt` at all, and it will not reboot for you. On those systems you
can hold the driver and kernel back while still receiving ordinary security
patches, by dropping a file into `/etc/apt/apt.conf.d/`:

```
Unattended-Upgrade::Package-Blacklist {
        "^nvidia-";
        "^libnvidia-";
        "^xserver-xorg-video-nvidia";
        "^linux-image";
        "^linux-headers";
        "^linux-generic";
        "^linux-modules";
};
```

Driver and kernel updates then happen when *you* choose, paired with the
reboot they need. Check it took effect with:

```bash
sudo unattended-upgrade --dry-run --debug | grep -i blacklist
```

Kernel upgrades are worth holding for the same reason: a new kernel without
a reboot leaves the running module and the installed modules out of step.

If you hit this, [Troubleshooting](/troubleshooting/) covers recovery,
including how to get the recorder running again without the GPU when a
reboot has to wait.
