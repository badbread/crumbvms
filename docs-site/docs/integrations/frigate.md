---
title: Frigate
sidebar_label: Frigate
slug: /integrations/frigate
---

# Using Frigate with Crumb

Crumb and Frigate compose at two independent levels. Crumb can be the single
source of camera video that Frigate consumes, and Crumb can ingest the detection
events Frigate produces. You can use either, both, or neither.

They do **not** compose at the storage level: Crumb records and archives its own
footage rather than reading Frigate's recordings. The next section explains why,
because it's a fair question if you already have Frigate storing everything.

## Why Crumb records its own footage, and doesn't read Frigate's

Short version: the thing Crumb is *for*, a smooth, frame-accurate, multi-camera
scrubbable timeline, is a property of how footage gets recorded, not how it gets
played back. Frigate's stored files play fine. What they can't do is hand you
that timeline after the fact, because the properties that make scrubbing feel
instant have to be baked in at record time. Crumb composes with Frigate
everywhere it's cheap to (detections over MQTT, clips, snapshots, live streams).
Storage is the one seam where reading Frigate's files would quietly cost the
experience you came for.

Here's the concrete why, for anyone who wants the detail.

**Smooth scrubbing lives in the recorder, not the player.** Frigate writes
faststart MP4, and libmpv and Media3 will happily seek inside those files, so raw
seekability isn't the blocker. But "the player can seek this file" and "you can
drag a scrubber across a dozen cameras and a full day and have every frame land
instantly" are different problems, and the second one is won or lost at record
time.

**Segments have to be a known, uniform shape.** Crumb records standard fMP4 in
short segments (2 to 6 seconds), clock-aligned, written so every fragment
boundary is also a keyframe boundary (`+frag_keyframe+empty_moov+default_base_moof`).
The player can then land on any segment boundary without hunting backward for the
previous keyframe, and it knows exactly where those boundaries are before it
seeks. Frigate cuts roughly 10-second segments at whatever keyframe your camera
happens to emit: no forced GOP, no clock alignment, audio stripped by default.
Seek precision and cross-camera boundary alignment then degrade to your camera's
settings rather than something Crumb controls.

**Seeking to a wall-clock instant needs a wall-clock index Crumb owns.** To put
the player on "3:47:12 PM on the driveway camera" you need a per-segment index
mapping real time to file and offset, at a granularity fine enough to feel
instant. Crumb keeps that in Postgres, written by the recorder as it records.
Frigate's index is single-writer SQLite on local disk, with a schema that changes
across minor releases, pruned hourly plus a 5-minute emergency sweep. Any index
Crumb mirrored from it would be racing deletion: mid-scrub 404s and mid-export
file-vanish become structural, not occasional.

**Multi-camera sync falls out of clock-aligned segments.** Drag one scrubber and
every camera jumps to the same instant only if their segments are cut on the same
clock. Crumb's are. Segments cut at each camera's own independent keyframe cadence
don't line up, so a synchronized wall becomes approximate.

**The scrub preview has to be pre-generated, or every drag re-decodes H.265.**
When you drag across the timeline you want a thumbnail under the cursor the whole
way. You can't get that by decoding the full-resolution H.265 stream on every
scrub tick: that's hundreds of full-frame decodes a second, and 4K H.265 is
exactly what browsers already choke on. So Crumb pre-generates a low-res JPEG
preview proxy (a small frame roughly every 10 seconds), lands the drag on the
nearest proxy frame instantly, and only decodes the real frame from the actual
video when you let go (see [Timeline scrubbing](/playback/scrubbing)). That proxy
is derived from Crumb's own segment index by a background worker. Reading
Frigate's files, you'd have to build and decode that proxy yourself from footage
whose shape and lifetime you don't control, which throws away the whole reason to
avoid re-decoding.

**Footage you display should be footage you can protect.** Crumb treats losing
footage as the one unforgivable bug. Frigate's tiered retention deliberately
turns each camera's history into islands as tiers age out, and its cache overflow
discards the oldest unprocessed segments by design. It has no "hold this time
range" primitive, only retain-indefinitely on detected-object events. If Crumb's
UI showed footage living in Frigate's store, it would be presenting clips it can't
protect, can't apply per-policy size caps or archive tiers to, and can't even
reliably detect the loss of.

What Crumb *does* compose with Frigate, and always will: detections drawn on the
timeline over MQTT, proxied clips and snapshots, and live-stream sharing in
either direction (the rest of this page). Frigate is a first-rate open-source
object detector, and Crumb doesn't try to redo that. Frigate detects, Crumb is
the room you sit in.

If Frigate ever ships a stable recordings API plus a real retention-hold, a
read-only "browse my existing Frigate archive" view becomes worth revisiting.
That would be an explicitly second-class overlay, never a peer storage backend,
for exactly the reasons above.

## Point Frigate at Crumb's streams (recommended)

Frigate needs the camera video, not just the detection events. Out of the box a
Frigate install pulls RTSP straight from each camera. If Crumb is already pulling
that camera, the camera now has two independent pullers, which doubles its RTSP
sessions. Many cameras allow only a few concurrent sessions before they start
refusing connections, so this is a common cause of streams that will not load.

The better setup is to let Frigate consume Crumb's restream instead of the
camera. Crumb runs its own go2rtc (see [The go2rtc model](/cameras/go2rtc-model))
and publishes each camera over RTSP as:

- `rtsp://<crumb-host>:18554/<name>` for the main stream, and
- `rtsp://<crumb-host>:18554/<name>_sub` for the sub stream,

where `<name>` is the camera's go2rtc name from the admin camera editor. These
streams are authenticated the same way Crumb's own native clients connect; see
[Server settings](/configuration/server-settings) for the exact address and
credentials to use.

Point Frigate at those URLs instead of the camera's own address. Use the sub
stream for Frigate's `detect` role, since a lower resolution is enough for
detection, and the main stream for `record` only if you also have Frigate
recording (Crumb records independently, so most setups do not):

```yaml
# Frigate config.yml
cameras:
  front_door:
    ffmpeg:
      inputs:
        - path: rtsp://<user>:<pass>@<crumb-host>:18554/front_door_sub
          roles: [detect]
        - path: rtsp://<user>:<pass>@<crumb-host>:18554/front_door
          roles: [record]   # only if Frigate also records
```

Now the camera is pulled once, by Crumb, and Frigate fans out from Crumb's
restream. This is the single-puller topology Crumb is built around, and it keeps
session-limited cameras from being exhausted by having two systems dial them.

### Moving an existing Frigate setup alongside Crumb

Two things move separately when you put Crumb next to an existing Frigate
install: the camera **connection** and the **recording**. Keeping them straight
is what makes the transition undramatic.

**The connection (so each camera is pulled once).** You have two ways to avoid
both systems dialing the camera, and either works:

- **Crumb's go2rtc as the hub.** Repoint Frigate's input URLs from the camera
  address to Crumb's restream (the `rtsp://<crumb-host>:18554/...` URLs above),
  one camera at a time. Crumb pulls the camera; Frigate fans out from Crumb.
  Nothing else in your Frigate config changes.
- **Reuse Frigate's go2rtc.** If you'd rather leave Frigate as the puller, point
  Crumb's camera source at Frigate's existing go2rtc restream instead of at the
  camera (Frigate publishes RTSP on port `8554`, for example
  `rtsp://<frigate-host>:8554/<name>`). Crumb then consumes Frigate's stream and
  never dials the camera itself.

Either direction gives you one connection per camera. Which side is "the hub" is
just which go2rtc holds the camera session.

**The recording (the part that isn't automatic).** Crumb records its own footage
into its own storage from the moment you add the camera, and it does not read or
import Frigate's recordings (see
[Why Crumb records its own footage](#why-crumb-records-its-own-footage-and-doesnt-read-frigates)
above). So this is a decision, not a repoint:

- Your existing Frigate recordings stay in Frigate. They don't appear in Crumb's
  timeline, and adding Crumb does not migrate that history across.
- Crumb builds its own recording history going forward. Point it at storage
  you're happy to keep footage on, and set retention there; see
  [Recording & storage](/recording/).
- Decide whether Frigate should keep recording too. If you want Crumb to be the
  recorder, drop the `record` role from Frigate's config so you're not paying
  disk for two copies of everything. If you want both, leave it: they're then
  independent archives on independent retention.

Nothing forces the choice on day one. You can let both record for a while,
confirm Crumb's timeline holds what you expect, and turn Frigate's recording off
later.

## How it connects

Detections arrive over MQTT: Crumb subscribes to the broker Frigate already
publishes events to and draws whatever labels Frigate emits (person, car,
package, and named people or plates if you've configured Frigate for that) as
icons on the timeline, alongside pixel motion. If you don't already have an MQTT
broker, a bundled one is available behind an opt-in Compose profile, so it costs
nothing to a stock install unless you turn it on:

```bash
docker compose --profile frigate up -d
```

## Setup

1. Point Crumb at the MQTT broker your detector publishes to (the
   `FRIGATE_MQTT_URL` environment variable, or the equivalent admin
   console setting).
2. For each camera, set its detector-side camera name in the admin
   camera editor, so Crumb can map incoming events to the right camera.
3. Optionally point Crumb at the detector's HTTP API base as well, for
   snapshot proxying and a startup backfill of recent events. The admin
   console's Frigate settings panel includes a test button that checks
   both bases before you save.

When the MQTT URL is left unset, the entire detection subsystem stays
disabled: no background task runs, and the events surface simply returns
empty results. The behavior of pixel motion detection, recording, and
everything else is completely unaffected either way.

## What you're responsible for

If you enable named recognition (identifying specific people or license
plates) through your own detector, that data is regulated in some places,
Illinois' BIPA is a commonly cited example for named biometric
identifiers. Using it lawfully is on you as the operator; see
[Responsible use](/responsible-use).
