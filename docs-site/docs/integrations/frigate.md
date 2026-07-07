---
title: Frigate
sidebar_label: Frigate
slug: /integrations/frigate
---

# Using Frigate with Crumb

Crumb and Frigate compose at two independent levels. Crumb can be the single
source of camera video that Frigate consumes, and Crumb can ingest the detection
events Frigate produces. You can use either, both, or neither.

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

### Moving an existing Frigate setup to Crumb as the hub

If you already run Frigate with its cameras pulling directly, the migration is
just repointing those input URLs from the camera address to the Crumb restream
URLs above, one camera at a time. Nothing else in your Frigate config has to
change. Crumb becomes the single connection to each camera; Frigate keeps doing
detection, now sourced from Crumb.

## Object detection (bring your own)

Crumb does not bundle an object detector and never runs its own object,
face, or plate detection. If you point Crumb at your own running instance
of a compatible detector, Crumb stores and displays whatever labels it
produces, including named people or license plates if you've configured
the detector for that, since at that point it's your data from your own
tool.

## How it connects

Detections arrive over MQTT: Crumb subscribes to the same broker your
detector already publishes events to. If you don't already have an MQTT
broker, a bundled one is available behind an opt-in Compose profile,
so it costs nothing to a stock install unless you turn it on:

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
