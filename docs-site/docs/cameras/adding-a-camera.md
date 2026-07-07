---
title: Adding a camera
sidebar_label: Adding a camera
slug: /cameras/adding-a-camera
---

# Adding a camera

Outside the first-run wizard, cameras are added from the admin console's
camera management screen, the same underlying steps the wizard walks you
through once:

1. **Discover**, scanning an IP range with one or more credential sets, or
   add a camera manually if you already know its RTSP URL.
2. **Validate** the stream before adding it: the console shows a live
   thumbnail plus the detected resolution, codec, and frame rate, so you
   catch a wrong URL or bad credentials before committing.
3. **Add**, choosing a name and, if you use them, a camera group. Each
   camera clones its group's (or the default) recording policy at the
   moment it's created, see [Policies and groups](/recording/policies-and-groups).

An ONVIF-discovered camera keeps its ONVIF identity attached, which is
what makes PTZ control and later credential re-detection work without
re-entering anything. A camera added purely by RTSP URL, without ONVIF,
still records and plays back normally, it just won't have PTZ or focus/iris
control available.

Re-running discovery is safe: any IP already present as a camera is
skipped rather than duplicated.
