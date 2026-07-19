---
title: Server settings
sidebar_label: Server settings
slug: /configuration/server-settings
---

# Server settings

Some of Crumb's configuration lives in the database rather than `.env`, so
it can be changed from the admin console at any time without editing files
or restarting containers. The clearest example is the server's streaming
addresses: `.env` carries fallback values that let a fresh install work out
of the box, but the moment an admin sets a value in the console's Server &
streaming panel, that value wins.

## Precedence rule

For any setting that exists in both places: an admin-set value in the
`server_settings` table always overrides the environment default. An empty
console value falls back to the environment. This means:

- A fresh install with nothing configured in the console works using the
  internal Docker service names baked into `docker-compose.yml`.
- Setting the server's real LAN address in the console (so native desktop
  and Android clients can reach RTSP over the actual network, not
  `localhost`) is a one-time console change, not an `.env` edit and
  restart.
- Console code is written to only ever touch the specific field it's
  editing on save, so changing one setting never has a side effect on an
  unrelated one.

## What lives in the console

The most common settings an operator changes after first-run setup:

- **Server**, under this section: the streaming addresses native clients use
  to reach live RTSP and WebRTC, update checks (the same toggle that
  overrides `UPDATE_CHECK_ENABLED`, DB wins), and scrub previews (the
  live-editable `THUMB_PREGEN_*` / `THUMB_CACHE_*` knobs).
- **Storage**, recording profiles, size and time caps, storage tiers, plus
  the storage advisor's per-profile fill-rate and retention cards (see
  [Recording & Storage](/recording/)).
- **Motion decoding**, the requested hardware-decode backend (see
  [Hardware decode](/configuration/hardware-decode)).
- **Detection & clips**, the Frigate detection integration's stream and API
  bases, Home Assistant connection settings, and clip generation options
  (see [Integrations](/integrations/)).
- **LPR**, license-plate recognition: the per-camera engine selection
  (none / Frigate / crumb-alpr / both), OCR-confidence floor, detection
  zones, the plate watchlist with match fuzziness, and the crumb-alpr ingest
  token.
- **Notifications**, channels, per-camera rules, quiet hours (see
  [Notifications](/notifications/)).
- **Users & security**, accounts, roles, per-camera access grants (see
  [Users & access](/admin-console/users-and-access)).

Each of these is covered in more depth in its own section; this page is
just the rule for how console settings and environment defaults interact.
