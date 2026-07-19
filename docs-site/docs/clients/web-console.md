---
title: Web console
sidebar_label: Web console
slug: /clients/web-console
---

# Web console

No install needed. Open `http://<server-host>:8080/admin` in any modern
browser. On first server run you sign in with the seeded admin credentials
`setup-env.sh` printed (they're also saved in `.env`); the browser
create-admin bootstrap only appears if you deliberately blanked the seed
before first boot (see [First-run wizard](/getting-started/first-run-wizard)).

The web console is Crumb's administration surface, and it's the most
production-ready piece Crumb has today. It's where you add and configure
cameras, manage users and roles, set retention and recording, tune motion,
configure detection and clips, wire up Home Assistant, and manage
license-plate recognition. It's the fastest way to confirm a fresh server is
healthy before you install anything native.

What it is not is a video player. The console shows still-frame previews (a
snapshot when you test a camera's stream, and a live-frame preview in the
motion tuner), but it does not play live video or scrub recorded timelines in
the browser. Watching live, scrubbing playback, exporting clips, and PTZ are
what the native desktop and mobile clients are for. See
[the client feature rundown](/clients/#what-each-client-can-do).

Console surfaces worth calling out:

- **LPR (license plates).** A dedicated section for plate recognition: enable
  it, pick the engine and confidence, draw per-camera detection zones, and
  manage the watchlist and its fuzzy-match tolerance. The plate reads themselves
  are browsed in the native clients' LPR tab.
- **Home Assistant.** Connect Crumb to your Home Assistant (a base URL plus a
  token) and link each camera to its HA entities, so those sensors and controls
  can drive recording and show up as the entity overlay in the desktop client.

If you've set up [TLS](/configuration/tls), the same console is also
available at `https://<server-host>:8443/admin`, with the expected
self-signed certificate warning on a LAN install with no public domain.
