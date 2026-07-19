---
title: Admin Console
sidebar_label: Overview
slug: /admin-console/
---

# Admin Console

The admin console is Crumb's web interface, served directly by the server
at `/admin`. It is a management console, not a video player: everything
from first-run setup through camera and recording configuration, motion
tuning, and user administration happens here, and it's also the most
production-ready of Crumb's clients today. Watching live video, scrubbing
playback, and exporting clips are what the native desktop and Android
clients are for, see [Clients](/clients/).

## What it covers

- **First-run setup.** On a fresh install the
  [first-run wizard](/getting-started/first-run-wizard) runs here:
  confirming the server address, choosing storage and retention, and
  finding cameras on your network.
- **Cameras.** Discovery, adding, editing, grouping, and stream testing.
  See [Cameras & Streams](/cameras/).
- **Recording and storage.** Recording profiles (each camera is pinned to a
  named profile), size caps, storage tiers, and the storage advisor's
  per-profile fill-rate and retention cards. See
  [Recording & Storage](/recording/).
- **Motion tuning.** The motion tuner: per-camera detector choice, and
  exclusion zones drawn over a still-frame preview of the camera. See
  [Motion & Detection](/motion/).
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
