---
title: First-run wizard
sidebar_label: First-run wizard
slug: /getting-started/first-run-wizard
---

# First-run wizard

After `docker compose up -d`, open `http://<host-lan-ip>:8080/admin`. On a
fresh install this launches a guided setup wizard.

## Tester terms

The wizard opens with a one-time acknowledgement: Crumb is provided as is,
with no warranty, is not your only security system, and lawful use of the
recording is your responsibility. This is recorded once an admin account
exists. See [Responsible use](/responsible-use) for the full terms.

## 1. Create admin

The account you'll sign in with going forward.

## 2. Server address

Pre-filled from the connection you used to reach the wizard. Only change
this if it's wrong, for example if you reached the console through a
hostname rather than its LAN IP and want native clients to use the IP
instead.

## 3. Storage

Confirm the recording disk, shown with a live capacity bar, and set:

- **Keep at most** (a size cap, in GB)
- **Keep at least** (a minimum retention window, in days)

These become the default recording policy, so every camera you add
afterward inherits them. The chosen path is checked live for free space and
writability before you can continue: the wizard will not let you proceed
with a folder that isn't writable or reports zero free space, so a
misconfigured disk can't silently record nothing.

## 4. Find your cameras

Enter an IP range (pre-filled with your server's likely subnet) and one or
more username/password sets, one per camera brand if you have more than
one, then scan. The sweep tries the first credential set against every
discovered camera; any camera that doesn't yield a usable stream URL gets
the remaining sets tried in turn, and whichever one works is remembered for
that camera. Cameras that still need credentials are flagged in the
results table, and you can supply a one-off login for just that camera
inline.

## 5. Choose cameras to add

Every camera that's ready to stream is pre-selected. You can rename them,
edit the stream URL, and verify each one, which shows a live thumbnail plus
its resolution, codec, and frame rate. There's also a manual add option for
a camera that happens to be offline right now.

## 6. Review and add

Confirm the list, and optionally assign a group per camera, since each
group can carry its own recording policy (an "always record" group and a
"motion only" group in the same batch, for example). Adding the batch shows
per-camera success or failure as it goes; streams come online within about
a minute.

## 7. Object detection (optional)

If you already run an object detector, point Crumb at its stream and HTTP
API bases here, with a test button that checks both before you save. Skip
this if you don't run one, motion detection works fine without it. See
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
