---
title: Home Assistant
sidebar_label: Home Assistant
slug: /integrations/home-assistant
---

# Using Home Assistant with Crumb

Home Assistant is the integration I most wanted, because it's already
self-hosted, so it fits Crumb's rule that an optional integration must have a
self-hosted path and that footage never leaves your control. Crumb talks to your
HA over its REST API, reads state, and shows it next to your cameras. Nothing
about your cameras is sent to HA, and no footage leaves Crumb.

Three things work today:

- **HA sensors on the timeline, and as a recording trigger.** A camera's linked
  motion or door sensors can drive recording, alongside (or instead of) pixel and
  Frigate motion.
- **Live entity badges pinned on the video.** Drag a linked entity onto the live
  picture and a badge shows its current state right where the thing is.
- **Per-badge styling.** Icon, shape, color, size, opacity, outline, and pinned
  captions.

**Badge control is shipped.** Tapping a controllable badge acts on the device: a
light, switch, fan, or siren toggles in a single tap; a scene activates, a script
runs, and an automation triggers; a cover or lock opens a small card with its
actions behind a confirm step (a stray click on a wall of tiles must never unlock
a door). It is gated by a dedicated, **off-by-default `actuators` permission** on
the role, so seeing a camera, or a badge's live state, never implies being able
to operate it. Read-only entities (a sensor, a door contact) still just show
their state.

## Connect Crumb to Home Assistant

You need a base URL and a long-lived access token. Make the token from a
**dedicated non-admin HA user**: the integration reads state and calls services,
and a non-admin token is enough for both, which was confirmed on live HA hardware. Configure it in the console under **Detection & clips** (the
same panel as Frigate). It stays dormant until you enable it.

The token is write-only from Crumb's side: it's stored in a single `ha_config`
row and never returned by the API. There's an env fallback (`HA_BASE_URL`,
`HA_TOKEN`, `HA_TOKEN_FILE`) for headless installs, but a value you set in the
console wins over the env default. A test button (`POST /config/ha/test`) checks
reachability before you save. Off by default, like every integration here.

Transport is REST polling. Crumb does not use MQTT for this, and it does not use
a WebSocket yet. That's deliberate: a silently dead WebSocket took about 39
seconds to notice in testing, and for a camera that records on HA motion that's
39 seconds of maybe-missed footage. A polled GET with a timeout surfaces a dead
HA within about a second, so the fail-open behavior below stays honest.

## Link a camera's entities

In the camera editor's **Home Assistant** section you link the camera to HA
entities and save the set with `PUT /cameras/:id/ha/links`. There are two
pickers:

- **Sensors** are `binary_sensor` entities. The picker surfaces the relevant
  device classes first (motion, occupancy, presence, moving, door, window,
  opening, garage door) and tucks the rest under a show-all toggle, so nothing is
  unreachable.
- **Controls** are the actuator domains: `light`, `switch`, `fan`, `siren`,
  `cover`, `lock`, `button`, `input_button`, `scene`, `script`, and `automation`.
  Link one and, with the `actuators` permission, tap its badge to operate it.

The entity's device class is captured at link time and drives the badge glyph
without re-querying HA. Numeric `sensor` entities (temperature, humidity, power,
and the like) are linkable too and render their value with units.

## Home Assistant as a recording trigger

Motion sources in Crumb are additive: a camera can enable pixel analysis, Frigate
detections, and HA sensors at once, and it records on the **union** of whatever
is enabled. Turn on **Home Assistant sensors** for a camera and its linked
motion/door sensors start triggering recording. The recorder polls those sensors
about once a second, with a short grace period so a sensor ending and another
starting a moment later doesn't fragment the recording. That one-second latency
is absorbed by the motion pre-buffer, so you don't lose the run-up.

The correctness rule worth knowing: this **fails open**. If HA becomes
unreachable, a motion-mode camera records everything rather than risk missing
footage while HA is down. Door and window sensor openings also get labeled glyphs
on the timeline, written best-effort so a database hiccup can never cost you a
segment.

## Badges on the video (desktop)

The on-video overlay is in the desktop app (`apps/desktop-flutter`). Open a
camera's live view, drag a linked entity from the palette onto the frame, and it
becomes a badge. Positions are stored as fractions of the video frame, not the
pane, so a badge stays on the door as the tile changes shape. Live state comes
from `GET /ha/states` on a short cache.

State honesty is built in: an unknown, unavailable, or stale entity renders grey
and dimmed, **never** as "closed" or "off". A badge that looked closed on a dead
HA connection would be the overlay version of the footage-loss bug, so it's
treated the same way. Tapping a **read-only** badge (a sensor) opens a card with
the friendly name, current state, a relative "N ago", the raw entity id, and a
stale note when it applies. Tapping a **controllable** badge acts on it directly,
or, for a cover or lock, opens a card with its actions and a confirm step.

## Customize a badge

Each placed badge can be styled independently:

- **Icon** from a curated set of roughly 60 choices.
- **Shape:** a compact **dot** or a labelled **pill**.
- **Color** for the foreground and, on a pill, the background (`#RRGGBB`).
- **Size** multiplier and **opacity** (down to nearly transparent).
- **Outline** (a white edge plus shadow) so a badge pops on a busy scene.
- **Pinned captions:** show the live state text and/or the last-changed age next
  to the badge.

The editor supports undo and multi-select align/group operations; everything
saves when you hit Done.

## What's next

The roadmap here is badge control (calling HA services, gated by the reserved
`actuators` permission), a WebSocket transport for sub-second edges, numeric
sensor widgets, and picking entities by HA area. None of those are promises, and
the page above is what actually ships today.
