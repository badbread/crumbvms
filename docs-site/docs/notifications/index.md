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

A channel is a destination: ntfy, Pushover, a generic webhook, or one of
several chat integrations. Add a channel, then send a test notification to
confirm it delivers before relying on it.

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
heartbeating, a camera that's stopped writing new footage, low disk space,
a stale or failed database backup, or a disconnected object-detection
integration. These fire to your configured channels the same way motion
notifications do.

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
