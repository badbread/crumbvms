---
title: Cameras & Streams
sidebar_label: Overview
slug: /cameras/
---

# Cameras & Streams

Crumb talks to cameras over RTSP, with ONVIF used where available to
discover cameras automatically and read their real stream URLs. Every
camera you add is restreamed by Crumb's own embedded go2rtc process, so
recording, live view, and any number of simultaneous viewers all share one
connection to the camera rather than each opening their own.

## How cameras get added

The [first-run wizard](/getting-started/first-run-wizard) covers the
guided path: scan an IP range, supply credentials, pick which discovered
cameras to onboard. After first run, the admin console's camera
management adds cameras the same way, one at a time or by re-running
discovery.

## In this section

- [Adding a camera](/cameras/adding-a-camera), the ongoing (post-wizard)
  path for adding and validating a camera.
- [The go2rtc model](/cameras/go2rtc-model), why streams are managed at
  runtime rather than hand-edited into a config file.
- [ONVIF PTZ](/cameras/onvif-ptz), pan/tilt/zoom, focus, and iris control
  for cameras that support it.
