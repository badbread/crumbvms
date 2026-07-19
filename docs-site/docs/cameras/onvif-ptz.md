---
title: ONVIF PTZ
sidebar_label: ONVIF PTZ
slug: /cameras/onvif-ptz
---

# ONVIF pan/tilt/zoom, focus, and iris

Cameras with their ONVIF identity intact can be given on-video pan/tilt/zoom
control directly in the live view, along with focus and iris control where
the camera exposes it over ONVIF's imaging service. It's off by default and
you turn it on per camera (see below).

## Turning PTZ on

PTZ controls are **off by default on every camera**, even ONVIF-discovered
ones. Plenty of ONVIF cameras are fixed, with no pan/tilt/zoom motor at all,
and speak ONVIF only so Crumb can find their streams; showing them a PTZ
joystick would just be misleading. So Crumb waits for you to say which
cameras actually move.

To turn it on, open the camera in the admin console, and in the ONVIF / PTZ
section check **"This camera has pan/tilt/zoom controls."** Once that's on
and the camera is reachable over ONVIF, clients show the PTZ joystick and
accept PTZ commands. Turn it off again and the joystick disappears. A fixed
or non-ONVIF camera was never actually controllable, so leaving it off costs
nothing.

## Where it shows up

- **Live view:** a PTZ overlay appears on a camera tile when the camera
  supports it, letting you pan, tilt, and zoom directly on the video.
- **Wall builder:** PTZ controls can be placed as their own tile or
  overlay in a custom live-wall layout, alongside carousels and other
  tiles.
- **Custom on-video panels:** buttons can be arranged directly on top of
  the video image itself, in an editable panel mode, rather than only in a
  fixed side control strip.

## Requirements

The camera needs to support ONVIF's PTZ (and, for focus/iris, imaging)
service, Crumb needs its ONVIF credentials (normally captured automatically
during discovery), and the "This camera has pan/tilt/zoom controls" switch
needs to be on. A camera added purely by RTSP URL without going through
ONVIF discovery won't have PTZ available; re-detecting it against its ONVIF
identity (if it has one) fills in the ONVIF side without needing to re-add
the camera from scratch, and you then flip the switch on.
