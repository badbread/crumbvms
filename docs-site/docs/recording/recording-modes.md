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

## Recommendation for a new camera

Start a new camera on Continuous, or on Motion with shadow mode enabled
(records everything as normal, but stamps each segment with the
keep/discard verdict the motion buffer would have made), until its motion
detector is tuned against real footage from that camera's actual scene.
Only switch a camera to live Motion mode after checking what would have
been discarded under shadow mode. An untuned detector missing a real event
is a worse outcome than the disk space Motion mode saves.

See [Motion & Detection](/motion/) for tuning the detector itself.
