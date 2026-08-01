# Home Assistant management + customization audit

Tracker: **epic #445**. This document is the audit of record for the HA
management/customization overhaul. It was produced from a three-surface audit
(backend/data-model, admin console, clients) of the shipped HA integration
(the #52 epic and #187 control) against both "what an operator needs" and the
ratified epic #52 vision.

## Bottom line

The **plumbing is strong**: the connection lifecycle (URL/token/enable/test,
write-only token), per-camera linking, full overlay styling with drag-to-place
(desktop), render parity (all three clients honor every persisted overlay
field), and the actuation security path (server-derived domain, static
allowlist, no passthrough, sanitized audit, deny-by-default `actuators`, media
tokens hardcoded off) are all solid. The auditors found **no security holes**.

The **authoring / management layer is thin**: most "set it up and customize it"
actions are desktop-only, inferred-and-immutable, or missing. That layer is the
subject of this overhaul.

Already closed pending merge (base-control refinements, separate from this
overhaul): Android control and the single-tap-actuate interaction model land in
PRs #429/#430/#431.

## Capability snapshot (what exists today)

| Surface | Has | Notably lacks |
|---|---|---|
| Backend | `ha_config` singleton; `camera_ha_links` (role motion/sensor/actuator, device_class, label, sort_order); per-link placement + full overlay style endpoints; entity picker proxy; RBAC-projected `/ha/states`; `POST /cameras/:id/ha/action` with a static on/off/press allowlist; `motion_source='ha'` recorder path | value-setting actions; per-link CRUD; server-enforced icon vocabulary; role/domain validation; `camera_overlays` unification |
| Admin console | connect/test, per-camera link add/remove/save, searchable grouped picker, HA-as-motion toggle, `actuators` RBAC checkbox | role/device_class selectors; editable label; icon picker; any overlay styling; per-control config; global links overview; a single coherent HA area |
| Clients | render parity (all overlay_* fields); desktop authoring (link dialog + drag-place + style + ~65-slug icon picker); control on desktop/iOS (card model) | mobile authoring (by design); Android control (in-flight #431); one shared icon vocabulary; mobile progressive disclosure; server-backed PTZ |

## Gaps by theme

### 1. Adding / managing entities
- **#433 — the entity picker can't offer cover/lock/fan/siren/button/script or
  numeric sensor.** The `controls` domain resolves to light/switch/scene only;
  binary_sensor is the only sensor. All of cover/lock/fan/siren/button/
  input_button/script are supported by the action allowlist and numeric
  `sensor` by the sensor role, but none are pickable through the normal flow.
  The flagship confirm-gated lock/garage control has buttons wired but **no UI
  path to create the link.** Top-ranked; small fix; unblocks the headline use
  case. (backend + client audits both #1)
- Link authoring is replace-the-whole-set, not per-link CRUD (medium; awkward
  concurrency, clients must hold the full set to mutate one row).
- No global "all HA links across cameras" overview or orphaned-entity detection
  (part of #441).

### 2. Controlled-or-not
- **#435 — "controllable" is implicit.** Encoded by which +Add button you
  press; a device that is both a sensor and controllable needs two rows. Needs
  a visible per-entity "controllable" concept.

### 3. Type / role / device-class
- **#434 — role + device_class are inferred and immutable.** Role can't change
  after add, device_class is HA-inherited and never selectable, and nothing
  validates that role matches the domain (an actuator link on a temperature
  sensor silently never fires). Needs explicit selectors + server-side
  role/domain validation.

### 4. Icons
- **#438 — no single closed icon vocabulary; it drifts across clients.** Desktop
  ~65 slugs, iOS ~40, Android ~20. An icon picked on desktop (blinds, valve, ev,
  pool, ...) silently falls back to a generic glyph on mobile. Epic #52 specced
  a closed vocabulary rendered natively three ways. Real correctness bug.
- **#439 — the console has no icon picker at all** (icon authoring is
  desktop-only).
- **#437 — Android's badge and entity-sheet use two different icon/color
  mappings** that disagree with each other. Cheap to unify; de-risks #438.

### 5. Control coverage
- **#442 — control is on/off/press only.** No dimming, cover position
  ("garage half-open"), thermostat setpoint, fan speed, color, or media. The
  deferred "value-setting controls" (epic P4); the capability ceiling. Large.
- **#440 — no per-entity control config** (require-confirm, allowed-actions)
  authored server-side; confirm is hardcoded client-side for cover/lock only.
  Safety-relevant for locks/garage/siren.

### 6. Customization (overlay)
- **#439 — the console can author none of it.** The backend supports label
  editing and full overlay styling per link, but only the desktop client
  exposes it. For a feature managed "from the one place," add the non-visual
  authoring (label, icon, size band, show-state/age, default color) to the
  console.
- **#443 — the unified `camera_overlays` widget layer is unbuilt.** HA overlays
  are server-backed and cross-device, but PTZ custom panels still persist to a
  client-local store, so PTZ placements are invisible cross-device (the exact
  "root weirdness" epic #52 P4 set out to kill). Fold PTZ + HA into one
  server-backed declarative widget layer rendered three ways. Strategic.

### 7. Parity / discoverability
- **#441 — HA config and linking are split across two pages**; no single HA
  area (part of the global-overview item).
- **#444 — mobile has no progressive disclosure / clustering** (icon-only ->
  icon+state -> full chip by pane size) and no global show/hide; both clients
  draw the full badge at all sizes.
- Mobile is render-only for authoring (by design in v1; noted for completeness).

### Freebies
- **#436 — stale `motion_source` 400** ("must be pixel or frigate") wrongly
  rejects the now-valid `ha`. Trivial.
- Placement/style-only edits do not bump `ha_config.version` (minor staleness on
  non-polling clients).

## Phased plan

### Tier 1 — Quick wins (highest leverage, small)
#433 widen picker, #434 role/device_class selectors + validation, #435 explicit
controllable, #436 motion_source error, #437 Android badge/sheet unify. The
#433 picker fix alone unblocks the flagship lock/garage control.

### Tier 2 — Medium (the "manage everything from one place" bulk)
#438 closed icon vocabulary (server-enforced + all clients), #439 console
authoring of labels/icons/overlay defaults, #440 per-entity control config,
#441 coherent HA console area + global overview.

### Tier 3 — Strategic (capability ceiling + signature deliverable)
#442 value-setting controls, #443 unified `camera_overlays` layer folding in
PTZ, #444 mobile progressive disclosure.

Each item is its own issue and PR; epic #445 tracks the whole. Sequencing is
Tier 1 -> Tier 2 -> Tier 3.
