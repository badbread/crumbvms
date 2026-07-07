---
title: The go2rtc model
sidebar_label: go2rtc model
slug: /cameras/go2rtc-model
---

# The go2rtc model

Crumb embeds its own copy of go2rtc, a restreamer, inside the recorder
process rather than running it as a separate container. The recorder
process spawns and supervises it directly.

## Why a restreamer at all

Without one, every consumer of a camera, recording, live view in the web
console, a desktop client, a phone, would each open its own RTSP session
directly to the camera. Most cameras support only a handful of concurrent
sessions before they start refusing connections. go2rtc sits in the
middle: one session to the camera, fanned out to as many consumers as
actually need it.

This is also why, if you run Frigate alongside Crumb, Frigate should
consume Crumb's streams rather than dialing the cameras a second time; see
[Using Frigate with Crumb](/integrations/frigate).

## Streams are managed at runtime, never hand-edited

The committed `go2rtc/go2rtc.yaml` in the repository holds only listener
configuration, which ports to bind, not which cameras exist. The actual
list of streams is owned entirely by the admin console: adding a camera in
the console writes it to the database and the API's reconcile loop pushes
that into go2rtc's own API at runtime. Removing or editing a camera works
the same way in reverse.

This means the source of truth for what Crumb records is always the
`cameras` table, never a YAML file, and the reconcile loop periodically
double-checks that go2rtc's actual state matches what the database says it
should be, correcting drift without operator involvement.

## Not directly reachable

go2rtc's own REST API is not published to your LAN. Only the API container
can reach it, over Crumb's internal Docker network, authenticated with
credentials generated at setup. This closes off a surface that would
otherwise let anyone on the network enumerate or tamper with camera
streams directly, bypassing Crumb's own user roles and per-camera access
grants.

RTSP itself (the actual video, not the management API) is published to
your LAN so native clients can connect, with its own authentication layered
on top; see [Server settings](/configuration/server-settings) for setting
the address clients use to reach it.
