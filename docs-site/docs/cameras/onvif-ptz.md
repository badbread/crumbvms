---
title: ONVIF PTZ
sidebar_label: ONVIF PTZ
slug: /cameras/onvif-ptz
---

# ONVIF pan/tilt/zoom, focus, and iris

Cameras discovered or added with their ONVIF identity intact get
on-video pan/tilt/zoom control directly in the live view, along with
focus and iris control where the camera exposes it over ONVIF's imaging
service.

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
service, and Crumb needs its ONVIF credentials, normally captured
automatically during discovery. A camera added purely by RTSP URL without
going through ONVIF discovery won't have PTZ available; re-detecting it
against its ONVIF identity (if it has one) fills this in without needing
to re-add the camera from scratch.
