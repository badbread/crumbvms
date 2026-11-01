---
title: Notifications
sidebar_label: Overview
slug: /notifications/
---

# Notifications

Crumb can notify you when something happens, a motion event, or something
going wrong with the system itself, through the admin console's
Notifications panel.

## Channels

A channel is a destination: Discord, Slack, Telegram, ntfy, Pushover, or a
plain webhook. Add a channel, then send a test notification to
confirm it delivers before relying on it.

Adding, editing, removing and test-sending a destination is limited to
administrators and to roles granted the **Manage notification destinations**
permission, which the console's role editor exposes and which is off by default
(upgrading to 0.3.0 switched it off for every existing non-admin role, so grant it
again to any role that should keep managing destinations). Administrators see
every destination; other users see only their own. Destinations that are already
set up keep delivering either way. A destination has to be an ordinary
`http`/`https` address; a role with the permission cannot point one back at the
Crumb server itself, though an administrator can. Addresses on your own LAN are
fine, which is what a self-hosted ntfy or Home Assistant needs.

### Snapshot images

Each channel chooses what image an alert attaches: no image, the plate crop,
the full vehicle frame, or both. What actually arrives depends on the
provider. Discord and Telegram can carry both the frame and the plate crop.
Pushover and ntfy carry a single image, so "both" sends the plate crop (the
more useful of the two). Slack and the plain webhook cannot attach an image
over their transport, so they send text and a link only; the console shows the
choices a given provider can honor.

### Times in alerts

Discord and Slack understand timestamp markup that their own apps render in
whoever is reading's timezone, so a Crumb alert opened on a phone abroad still
shows the right local time. Crumb uses it for those two. ntfy, Pushover,
Telegram and the plain webhook have no equivalent, so their alerts show the
server's timezone (the `TZ` setting, the same one quiet hours and the nightly
backup use) with the zone abbreviation on the end, for example
`2026-01-15 11:14:05 PST`. The `%date%`, `%time%` and `%datetime%` tokens in a
custom alert template follow exactly the same rule, per destination. Recorded
event times themselves are always stored in UTC; only the display changes.

## Rules

Per-camera rules control which cameras notify, and when, including quiet
hours so a camera that's fine to notify during the day doesn't page you
overnight. Rules are what keeps notifications useful rather than
overwhelming: motion detection alone is noisy (wind, passing cars, shadow
movement), so sensible defaults and per-camera tuning both matter here as
much as they do for the underlying detector, see
[Tuning](/motion/tuning).

## System alerts

Separately from per-camera motion notifications, a set of system-health
alerts is mostly on by default and rule-based: a recorder that's stopped
heartbeating, a camera that's offline or recording nothing, a camera stream
the restreamer refused, footage deleted before its retention was up, low disk
space, storage that can't be written, a recording profile over its size cap,
a stale or failed database backup, a disconnected Frigate/MQTT integration,
and a license-plate watchlist hit. An "update available" alert also exists
but is off by default. Each one can be switched on or off, and footage-loss
alerts break through quiet hours by default. These fire to your configured
channels the same way motion notifications do.

**One limitation worth knowing:** the alerting engine runs inside the API
process itself, so it can report problems with the recorder, a camera, or
disk space, but it cannot report the API process itself being down. If you
want coverage for that case too, a small external uptime check hitting the
server's health endpoint from a different machine closes that gap; see
`docs/AI-INSTALL.md` in the repository for the exact endpoint and setup.

## Maintenance windows

Before a deliberate restart or planned maintenance, arming a maintenance
window suppresses health alerts (they're still recorded, just not
dispatched) for the duration, so a normal, expected restart doesn't page
anyone for the brief gap while streams reconnect.

There is no console button for this yet. An administrator arms one through
the API with `POST /config/maintenance` and a body of `{"minutes": 15}` (up to
1440, a full day; `0` ends the window early), and `GET /config/maintenance`
shows whether one is active. To arm a window from the moment the api starts,
set `MAINTENANCE_UNTIL` in `.env` to a Unix timestamp (see
[Environment reference](/configuration/environment-reference#alerting)).
