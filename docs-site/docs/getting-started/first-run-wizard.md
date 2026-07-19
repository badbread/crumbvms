---
title: First-run wizard
sidebar_label: First-run wizard
slug: /getting-started/first-run-wizard
---

# First-run wizard

`scripts/setup-env.sh` pre-creates the admin account and prints a memorable
password at the end of its run, something like `username: admin / password:
IcyApples473` (also saved as `SEED_ADMIN_PASSWORD` in `.env`). Seeding the
admin up front is deliberate: it closes the unauthenticated bootstrap window
so a fresh box is never briefly wide open.

So after `docker compose up -d`, open `http://<host-lan-ip>:8080/admin` and
**sign in** with that username and password. The guided setup wizard then
opens at the tester-terms step; because the admin already exists, the wizard
skips the create-admin step.

## Tester terms

The wizard opens with a one-time acknowledgement: Crumb is provided as is,
with no warranty, is not your only security system, and lawful use of the
recording is your responsibility. This is recorded once an admin account
exists. See [Responsible use](/responsible-use) for the full terms.

## 1. Create admin (only if you blanked the seed)

You won't see this step on a standard install, since `setup-env.sh` already
seeded the admin and you signed in with it. It appears only if you
deliberately blank `SEED_ADMIN_PASSWORD` in `.env` before the first
`docker compose up`. That reopens the unauthenticated bootstrap window, and
the wizard leads with this step so you close it by picking a username and
setting a password (at least 8 characters), the account you'll sign in with
going forward.

## 2. Server address

Two fields, both pre-filled from the connection you used to reach the
wizard:

- **Server address**, how the console is reached (for example
  `http://198.51.100.50:8080`).
- **Camera streaming base (RTSP)**, what the native desktop and phone apps
  use to pull streams, pre-filled as `rtsp://<host>:18554`.

Only change these if they're wrong, for example if you reached the console
through a hostname rather than its LAN IP and want native clients to use the
IP instead. For encrypted access there's a note about using
`https://<host>:8443` (a Caddy sidecar terminates TLS, self-signed by
default on a LAN install); see [TLS](/configuration/tls).

## 3. Storage

Confirm the recording disk, shown with a live capacity bar, and set:

- **Keep at most** (a size cap, in GB)
- **Keep at least** (a minimum retention window, in days)

These become the default recording policy, so every camera you add
afterward inherits them. The chosen path is checked live before you can
continue. The wizard blocks you from proceeding when the folder is outside
the recorder's storage area (it must live under `/data` inside the
container), when the API can positively tell the path isn't writable, or
when the disk reports zero free bytes. On a standard install the API mounts
the recording disk read-only (the recorder holds the read-write mount), so
it usually can't confirm writability from here; in that case you get a
non-blocking warning that points you at media-directory ownership (the
recorder runs as uid 1001) if recordings later come up empty.

## 4. Find your cameras

Enter an IP range (pre-filled with your server's likely subnet) and one or
more username/password sets, one per camera brand if you have more than
one, then scan. The sweep tries the first credential set against every
discovered camera; any camera that doesn't yield a usable stream URL gets
the remaining sets tried in turn, and whichever one works is remembered for
that camera. Cameras that still need credentials are flagged in the
results table, and you can supply a one-off login for just that camera
inline. A slow camera that dropped out of a sweep can be re-probed on its
own with the per-row Rescan button, and "Add a camera by address" is
available here too if you'd rather skip scanning.

## 5. Choose cameras to add

On the first scan, every camera that's ready to stream is pre-selected; a
re-scan leaves your existing selection alone. A live thumbnail loads for
each selected camera on its own so you can tell which one is which without
pressing anything. You can rename them, edit the stream URL, and verify each
one, which refreshes the thumbnail and adds its resolution, codec, and frame
rate.

There's also "Add a camera by address" for one the scan missed: enter its IP
plus optional credentials, pick the brand, and Discover probes ONVIF and the
brand's known RTSP paths (validated with ffprobe) to fill in the URLs. For a
camera that's genuinely offline right now, type the stream URL in by hand
instead.

## 6. Review and add

Confirm the list, and optionally assign a group per camera, since each
group can carry its own recording policy (an "always record" group and a
"motion only" group in the same batch, for example). You can create, rename,
and delete groups right here without leaving the step. Adding the batch shows
per-camera success or failure as it goes; streams come online within about
a minute.

## 7. Object detection (optional)

If you already run Frigate, point Crumb at its go2rtc and HTTP API bases
here, with a test button that checks both before you save. Skip this if you
don't run it, motion detection works fine without it. See
[Integrations](/integrations/) for the ongoing configuration surface.

## 8. Motion decoding (optional)

Auto, CPU, Intel/AMD iGPU (VAAPI), or NVIDIA (NVDEC) for the motion-analysis
decode path (recording itself is never re-encoded). The step shows what the
recorder can actually see on this host; picking a backend whose device
isn't mapped into the container shows you the exact commands to fix that.
CPU and Auto are both fine defaults, skipping this step is normal. See
[Hardware decode](/configuration/hardware-decode).

## 9. Notifications (optional)

Add one destination (ntfy, Pushover, or a generic webhook) with a save and
test-send button. The full set of options, per-camera rules, quiet hours,
and additional channels, live in Settings afterward.

## 10. Additional users (optional)

Add more accounts inline: username, password, and role. Fine-grained
per-camera access control lives in Settings → Users & security afterward.

## Done

That's it, you're finished with the wizard. Steps 7 through 10 are all
optional and safely skippable; nothing about Crumb's security posture
depends on completing them during first run.

If you close the tab partway through, reopening `/admin` drops you back on
the step you left off. You can also re-run the whole guided setup any time
from **Server** in the console.
