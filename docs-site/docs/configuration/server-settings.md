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
of the box, but the moment an admin sets a value in the console's **Server**
section, that value wins.

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

- **Server**, under **Administer**: this server's address, the Crumb
  restream bases native clients use to reach live RTSP and WebRTC (plus a
  read-only badge showing whether the RTSP restream requires a password,
  which only `GO2RTC_AUTH` changes), the bookmarks on/off switch for all
  clients, update checks (the same toggle that overrides
  `UPDATE_CHECK_ENABLED`, DB wins), scrub previews (the live-editable
  `THUMB_PREGEN_*` / `THUMB_CACHE_*` knobs), and **Run setup again** to
  reopen the first-run wizard.
- **Recording**, recording profiles: retention, size and time caps, storage
  tiers (see [Recording & Storage](/recording/)).
- **Storage**, the storage locations plus the storage advisor's
  per-profile fill-rate and retention cards.
- **Detection & clips**, the Frigate detection integration's stream and API
  bases, the motion-decode backend (see
  [Hardware decode](/configuration/hardware-decode)), and clip generation
  options (see [Integrations](/integrations/)).
- **Home Assistant**, connection settings, a global overview of every linked
  entity across all cameras, and orphaned-link detection (see
  [Home Assistant](/integrations/home-assistant)).
- **LPR**, license-plate recognition: the per-camera engine selection
  (none / Frigate / crumb-alpr / both), OCR-confidence floor, detection
  zones, the plate watchlist with match fuzziness, and the crumb-alpr ingest
  token (see [License plate recognition](/integrations/lpr)).
- **Notifications**, channels, per-camera rules, quiet hours (see
  [Notifications](/notifications/)).
- **Users & security**, accounts, roles, per-camera access grants (see
  [Users & access](/admin-console/users-and-access)).

Each of these is covered in more depth in its own section; this page is
just the rule for how console settings and environment defaults interact.
