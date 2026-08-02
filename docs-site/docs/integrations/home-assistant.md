---
title: Home Assistant
sidebar_label: Home Assistant
slug: /integrations/home-assistant
---

# Using Home Assistant with Crumb

Home Assistant is the integration I most wanted, because it's already
self-hosted, so it fits Crumb's rule that an optional integration must have a
self-hosted path and that footage never leaves your control. Crumb talks to your
HA over its REST API, reads state, and, for entities you've marked as controls,
calls services back. Nothing about your cameras is sent to HA, and no footage
leaves Crumb.

What works today:

- **HA sensors on the timeline, and as a recording trigger.** A camera's linked
  motion or door sensors can drive recording, alongside (or instead of) pixel and
  Frigate motion.
- **Live entity badges pinned on the video**, with an icon, shape, color, size,
  and opacity you choose per entity.
- **Control from the badge.** Entities linked with the **Control** role, lights,
  switches, fans, sirens, covers, locks, buttons, scenes, and scripts, can be
  operated right from the badge: tap a simple device to fire its action, or open
  a small action card for a device like a cover or lock that has more than one
  meaningful action.
- **A Home Assistant hub** in the console: connection settings, every linked
  entity across every camera in one searchable table, and detection of links
  whose entity has since disappeared from HA ("orphaned").

Seeing a badge never implies being able to operate it; control is gated by its
own permission, see [Permissions](#permissions) below.

## Connect Crumb to Home Assistant

You need a base URL and a long-lived access token. Make the token from a
**dedicated non-admin HA user**: the integration only reads state and calls
services, and a non-admin token is enough for both, which was confirmed on live
HA hardware. Configure it in the console under its own **Home Assistant**
section, a dedicated hub rather than being tucked under Detection & clips. It
stays dormant until you enable it.

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

In the camera editor's **Home Assistant** section (under its Motion tab) you
link the camera to HA entities and save the set with `PUT /cameras/:id/ha/links`.
Each linked entity gets:

- A **role**: **Motion** (a binary sensor that can trigger recording), **Sensor**
  (status only, shown but never a trigger and never actuated), or **Control**
  (stored as `actuator` in the API; actuatable, gated by the `actuators`
  permission).
- A **device class** (HA's own classification, motion, door, temperature, and
  so on), captured from HA at link time and used to pick a sensible default
  badge icon without re-querying HA.
- A **label**, the text shown on the badge and in pickers; defaults to the HA
  entity's friendly name.

Three pickers add entities, one per role:

- **+ Add sensor** searches `binary_sensor` entities for a **Motion** link. The
  relevant device classes (motion, occupancy, presence, moving, door, window,
  opening, garage door) are grouped first, with the rest under a "show all"
  toggle, so nothing is unreachable.
- **+ Add value** searches numeric `sensor` entities (temperature, humidity, and
  so on) for a **Sensor** link; the entity's unit is carried through so a badge
  or detail card can show, for example, `72°F` instead of a bare number.
- **+ Add control** searches every domain Crumb can actuate for a **Control**
  link: `light`, `switch`, `fan`, `siren`, `cover`, `lock`, `button`,
  `input_button`, `scene`, and `script`, grouped by domain.

Every picker has a search box, and an entity already linked under that role
shows as "(linked)" instead of being hidden.

The role is validated against the entity's actual HA domain when you save: a
Control link needs one of the actuatable domains above, a Motion link needs a
`binary_sensor`, and a Sensor link accepts any domain. That turns a mismatch,
say trying to make a temperature sensor a motion trigger, into an explained
error at save time instead of a link that silently never fires.

## The Home Assistant hub

The console's **Home Assistant** section is also a hub. Alongside the
connection settings it lists every linked entity across every camera on the
server in one table (camera, entity id, role, device class, label, live state),
with a search box and clicking a row opens that camera. Turn on **Orphaned
only** to filter to links whose entity id no longer appears in HA's own state
list, which is exactly what "orphaned" means here: the entity was renamed,
removed, or its integration was reconfigured on the HA side, so the link now
points at nothing. A banner at the top counts how many links are currently
orphaned. Fixing one means opening that camera's Motion tab, removing the stale
link, and relinking the entity's new id if it still exists in HA. Orphan
detection needs a reachable HA; if HA is unreachable or not enabled, the hub
says so instead of guessing.

## Home Assistant as a recording trigger

Motion sources in Crumb are additive: a camera can enable pixel analysis, Frigate
detections, and HA sensors at once, and it records on the **union** of whatever
is enabled. Turn on **Home Assistant sensors** for a camera and its linked
Motion-role sensors start triggering recording. The recorder polls those sensors
about once a second, with a short grace period so a sensor ending and another
starting a moment later doesn't fragment the recording. That one-second latency
is absorbed by the motion pre-buffer, so you don't lose the run-up.

The correctness rule worth knowing: this **fails open**. If HA becomes
unreachable, a motion-mode camera records everything rather than risk missing
footage while HA is down. Door and window sensor openings also get labeled glyphs
on the timeline, written best-effort so a database hiccup can never cost you a
segment.

## Badges on the video

Open a camera's live view in the desktop, iOS, or Android app and a linked
entity with a placement shows up as a badge pinned to the picture. Positions are
stored as fractions of the video frame, not the pane, so a badge stays on the
door as the tile changes shape. Placing a badge, dragging it into position for
the first time, is done from the desktop app's live view; once placed, it
renders (and, for a Control link, actuates) the same way on every client. Live
state comes from `GET /ha/states` on a short cache.

State honesty is built in: an unknown, unavailable, or stale entity renders grey
and dimmed, **never** as "closed" or "off". A badge that looked closed on a dead
HA connection would be the overlay version of the footage-loss bug, so it's
treated the same way. Tapping a Sensor- or Motion-role badge opens a read-only
card with the friendly name, current state, a relative "N ago", the raw entity
id, and a stale note when it applies. What tapping a Control-role badge does is
covered in [Controlling actuators from live video](#controlling-actuators-from-live-video)
below.

## Customize a badge

Icon, shape, color, size, and opacity are editable per link, either from the
camera's Home Assistant section in the console or from the desktop app's live
view (which also handles outline, pinned captions, and the free-drag
positioning itself):

- **Icon**, from a closed vocabulary of about 65 slugs covering contacts and
  openings, motion and presence, lighting, power and switches, climate, safety
  and alarms, cameras and media, network, vehicles and delivery, appliances,
  time, automation, and a generic fallback. Every slug maps to a real glyph on
  all three native clients (desktop, iOS, Android), so an icon you pick renders
  the same everywhere instead of degrading to a generic dot on a client that
  doesn't know it. Leave it unset and Crumb picks a sensible default from the
  entity's device class.
- **Shape:** a compact **dot** or a labelled **pill**.
- **Color** for the foreground and, on a pill, the background (`#RRGGBB`).
- **Size** multiplier and **opacity** (down to nearly transparent).
- **Outline** (a white edge plus shadow) so a badge pops on a busy scene, and
  **pinned captions** (live state text and/or last-changed age) next to the
  badge, both set from the desktop live view's badge editor.

The desktop editor supports undo and multi-select align/group operations;
everything saves when you hit Done. The console's style editor shows a small
preview of the badge's shape and color, but has no live-video canvas to render
the real glyph on, so the icon shows there as its slug name rather than the
actual symbol.

## Control config for actuators

Every Control-role link has its own control settings, editable next to the link
in the camera's Home Assistant section:

- **Require confirmation before firing any action.** When on, every client asks
  before it sends the action, one more tap or click after the one that would
  otherwise fire immediately. This is a client-side gate, not a server-side
  restriction.
- **Restrict which actions this control allows.** Off by default, meaning every
  action the entity's domain supports is available. Turn it on to narrow the
  set, for example a garage door you only ever want to close from Crumb, never
  open. This one is enforced server-side: an action outside the allowed set is
  refused with a 403 even if a client tried to send it directly.

What each domain supports, in plain terms:

| Entity type | Actions |
|---|---|
| Lights | Turn on, turn off, toggle, set brightness |
| Switches, sirens | Turn on, turn off, toggle |
| Fans | Turn on, turn off, toggle, set speed |
| Covers (garage doors, blinds, shades) | Open, close, stop, set position |
| Locks | Lock, unlock |
| Buttons | Press |
| Scenes, scripts | Run |

That set is intentionally narrow, only actions an operator would plausibly want
from a camera view, and only ones whose effect is obvious from the button.
Crumb only ever calls a fixed HA service matching the action word for a link
you authored; a client can never send an arbitrary HA domain, service, or
entity id, only a link id plus an action word the server looks up against the
domain it derived from that link's own stored entity.

**Value controls (brightness, position, speed).** A dimmable light, a cover that
reports its position, and a fan with a speed all get a **slider** on the camera
view, not just an on/off tap. Drag it and Crumb sets the level directly, for
example a hallway light to 40 percent or a shade halfway down. The value is a
plain percentage from 0 to 100 that Crumb checks before it ever reaches Home
Assistant. A light that is not dimmable, or a cover that does not report a
position, simply shows no slider. If you restrict which actions a control allows
(above), "set brightness", "set position", and "set speed" are ordinary entries
in that list, so you can offer the slider on some controls and not others.

## Controlling actuators from live video

Tap or click a Control badge on live video and Crumb fires the action, or, for
a device like a cover or lock that has more than one meaningful action, opens a
small card so you pick which one. If the link has **require confirmation** on,
you'll get one more prompt before anything happens. Nothing is inferred about
what "on" or "closed" should mean; the action word and the HA service it maps to
are fixed by the domain table above, on the server.

## Permissions

Controlling any actuator, on any client, requires the `actuators` role
capability, which is **off by default** on every role except the built-in admin
role (admins always have it). Grant it to a role under **Users & security →
Roles** if operators using that role should be able to fire actions, and grant
it deliberately: it lets a role operate physical hardware, garage doors, locks,
lights, sirens, linked to any camera that role can already see. A scoped media
token (the kind used for embedding a video pane) never carries this capability
no matter what, so control only ever works from an authenticated client
session.

## What's next

The roadmap here is a WebSocket transport for sub-second edges and picking
entities by HA area instead of a flat search. Neither is a promise, and the
page above is what actually ships today.
