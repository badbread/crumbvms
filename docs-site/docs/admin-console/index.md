---
title: Admin Console
sidebar_label: Overview
slug: /admin-console/
---

# Admin Console

The admin console is Crumb's web interface, served directly by the server
at `/admin`. It is a full management console, not just a viewer: everything
from first-run setup through day-to-day live viewing, playback, camera
management, and user administration happens here, and it's also the most
production-ready of Crumb's clients today.

## What it covers

- **Live view.** A multi-camera wall with saveable, per-device layouts:
  carousels, an auto-hotspot tile that follows recent motion, PTZ tiles,
  clocks, and web panes, alongside individual camera tiles with on-video
  PTZ, focus, and iris control where a camera supports it.
- **Playback.** A frame-level, scrubbable timeline per camera, jump to the
  next or previous motion event, and digital zoom into a clip without
  needing camera-side PTZ.
- **Clips and export.** Review motion events as a filmstrip, then build a
  batch export list across a review session and export it as MP4 or an
  encrypted archive.
- **Cameras.** Discovery, adding, editing, grouping, and stream testing.
  See [Cameras & Streams](/cameras/).
- **Recording and storage.** Recording profiles (each camera is pinned to a
  named profile), size caps, storage tiers, and the storage advisor's
  per-profile fill-rate and retention cards. See
  [Recording & Storage](/recording/).
- **Motion tuning.** Per-camera detector choice, exclusion zones drawn
  directly on the live image. See [Motion & Detection](/motion/).
- **Detection and clips.** The Frigate detection integration, Home Assistant
  connection settings (link a camera's HA motion, sensor, and actuator
  entities, and use HA sensors as a recording trigger), and clip options.
  See [Integrations](/integrations/).
- **LPR.** License-plate recognition: per-camera engine (none, Frigate,
  crumb-alpr, or both), an OCR-confidence floor, detection zones, and a plate
  watchlist (watch or ignore entries, with adjustable match fuzziness). The
  optional crumb-alpr worker is Crumb's own local plate OCR.
- **Users and security.** Custom roles carrying both a capability set and a
  base set of cameras, plus optional extra per-camera grants on top for an
  individual user, so a limited account can be restricted to specific
  cameras, or to live view only. See
  [Users & access](/admin-console/users-and-access).
- **Server.** The streaming address native clients use to reach live video,
  hardware decode selection, update checks, scrub previews, and other
  console-side settings that override environment defaults. See
  [Server settings](/configuration/server-settings).
- **Notifications.** Channels, rules, and quiet hours. See
  [Notifications](/notifications/).
- **Health panels.** Per-profile storage usage, decode status
  (requested versus actually active hardware backend per camera), and
  system alerts for conditions like a disconnected camera, low disk, or a
  stale backup.

## Getting to it

Open `http://<server-host>:8080/admin` in any browser (or the HTTPS port
if you've set up [TLS](/configuration/tls)). On a fresh install, this is
also where the [first-run wizard](/getting-started/first-run-wizard) runs.
