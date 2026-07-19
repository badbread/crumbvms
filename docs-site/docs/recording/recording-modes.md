---
title: Recording modes
sidebar_label: Recording modes
slug: /recording/recording-modes
---

# Recording modes

## Continuous

Every frame from the camera is written to disk the whole time it's
active. This is the well-understood default, and the recommended starting
point for a new camera while its motion detector hasn't been tuned to its
specific scene yet.

## Motion

Motion-mode cameras buffer segments in a RAM cache (tmpfs, sized by
`MOTION_CACHE_TMPFS_BYTES`) and persist to disk only when motion is
actually detected: the buffered pre-roll leading up to the event, the
event itself, and a configured post-roll afterward. Idle time between
events never touches disk at all, that's the entire point of the mode.

Two safety rails make this reasonable to leave running unattended:

- **Fail-open.** The instant a camera's motion detector becomes unhealthy,
  a stalled sub-stream, a dead decoder, anything that means Crumb can no
  longer form a trustworthy keep/discard decision, that camera immediately
  starts persisting everything to disk, exactly like Continuous mode,
  until detection is verified healthy again. A health alert fires for the
  duration. "I can't tell if this is interesting" always resolves to
  "record it all," never to "record nothing."
- **Spill.** If the RAM cache nears its configured size, because of many
  cameras, a burst of concurrent motion, or a slow disk, the oldest
  buffered segments are persisted to disk rather than being dropped from
  the cache unwritten. Cache pressure can change *when* something gets
  written, never *whether* it survives.

## Mode lives on the policy

Recording mode is a property of the [recording
policy](/recording/policies-and-groups), not of the camera directly.
Switching one camera on a shared policy to Motion does not flip its
neighbors: Crumb splits that camera onto its own policy (auto-named after
it) and changes the mode there. That is expected, not a bug, and it is why
you will see a new policy appear after the change.

## Shadow mode

Shadow mode is a server-wide diagnostic, not a per-camera toggle. It is off
by default and turned on with the `MOTION_RECORDING_SHADOW` environment
variable in your compose file, which affects **every** Motion-mode camera
at once. While it is on, those cameras keep recording and indexing every
segment exactly like Continuous mode (nothing is discarded), but Crumb also
runs the motion buffer's keep/discard decision in parallel and stamps the
verdict on each segment. That lets you see what Motion mode *would* have
thrown away before you trust it to actually throw anything away. There is
no console switch for this in v0.1.0; it is an env-level opt-in you set once
for the whole server.

## Recommendation for a new camera

Start a new camera on Continuous, or run the server with shadow mode on
while your detectors are still being tuned against real footage from each
camera's actual scene. Only switch a camera to live Motion mode after
checking what would have been discarded. An untuned detector missing a real
event is a worse outcome than the disk space Motion mode saves.

See [Motion & Detection](/motion/) for tuning the detector itself.
