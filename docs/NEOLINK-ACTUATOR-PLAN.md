> **SUPERSEDED (2026-07-10).** Issue #25 pivoted to a direct Reolink HTTP-API client — see [`REOLINK-ACTUATOR-PLAN.md`](REOLINK-ACTUATOR-PLAN.md) (the plan) and [`REOLINK-CONTROL-ARCH-DECISION.md`](REOLINK-CONTROL-ARCH-DECISION.md) (why). Retained as the rejected-alternative record.

# Neolink actuator control: implementable design + phased plan (issue #25)

Status: DESIGN, ratified by the #26 hardware spike (neolink v0.6.2, Reolink
CX410 fw v3.1.0.3429) AND by the maintainer on all four open decisions (§13, now
RESOLVED). This document refines the design sketch in issue #25 against the
codebase as of 2026-07-09 (post #31/#34/#39: `update_check_enabled` and the
scrub-preview tunables are the current precedent for settings, and migration
0046 is taken, so this feature owns **0047**).

**Ratified decisions (detail + consequences threaded through the doc; see §13):**

- **D1 = dedicated broker (CHOSEN).** A separate `mosquitto-neolink` container
  under the `neolink` profile: no published host ports, `allow_anonymous false`,
  password from a setup-env-generated `NEOLINK_MQTT_PASSWORD`. This is THE broker
  for the neolink control plane, never the shared Frigate mosquitto. (§2, §8.)
- **D2 = yes.** On each successful connect the api publishes an empty retained
  message to `{prefix}/config` to scrub neolink's retained creds-config,
  best-effort with caveats. (§2, §4.1.)
- **D3 = yes, gated.** Siren ships behind the operator-declared `siren` cap with
  an explicit "unvalidated on real hardware (spike CX410 had none)" note; not
  blocked. (§4.3, §7.1, docs.)
- **D4 = live admin-console `server_settings` knob (CHOSEN), not a client-side
  constant.** The floodlight momentary/auto-revert default is a nullable
  `server_settings` column resolved per-use (DB wins, NULL -> env, #39 /
  `update_check_enabled` precedence), with a sane server-side max clamp. (§3.1,
  §4.3, §4.4, §7.1, §8.2.)

Scope reminder (unchanged from #25): neolink is a **control sidecar only**.
Cameras keep their native RTSP `source_url` and `served_by='crumb'`. Actuators
in scope: floodlight, siren, status-LED, IR, PIR, reboot. Out of scope, parked:
neolink-as-RTSP-source (battery/Baichuan-only cams), two-way audio.

**Non-Reolink operators pay nothing for this feature: it is OFF at three
independent layers and is a post-setup optional integration, never part of the
base install or the first-run wizard. See §14 (Setup gating & zero-footprint).**

---

## 1. Verified spike facts (these are load-bearing; do not re-derive)

| Fact | Design consequence |
|---|---|
| Control topics `neolink/{name}/control/{floodlight\|led\|ir\|pir\|reboot}`, published **non-retained** | Publish QoS 1, retain=false. A broker restart can never re-fire an actuation. |
| Status topics `neolink/{name}/status/{floodlight\|motion}` **retained**; `neolink/{name}/status` and `neolink/status` carry `connected` | Subscriber gets current floodlight state immediately on (re)connect. Connected-status drives a health row. |
| `status/preview` is a base64 JPEG stream (heavy, non-retained) | Never subscribe to `{prefix}/+/status/preview`. Enumerate the wanted status subtopics explicitly; no `status/#` wildcard. |
| Floodlight `off` restores the camera's prior/auto (night) mode, it does not force-dark | TTL revert payload is plain `off`. No "restore auto" special case. |
| Actuation latency < 1 s, and `status/floodlight` echoes real state | Optimistic UI on 200-from-publish, with the retained status echo as the confirmed-state backstop via `/status` polling. |
| CX410 exposes **no siren** (`control/siren` is a no-op) | Capabilities are operator-declared per camera (`neolink_caps`); clients draw buttons only from declared caps. Siren payload semantics remain hardware-unverified (see open decision D3). |
| **neolink publishes its full config, including the camera username + password, to a RETAINED `neolink/config` topic** | A broker password alone is insufficient: any authed client on a shared broker can read Reolink creds. This forces the broker-isolation decision in §2. |
| Image entrypoint runs args verbatim: `neolink mqtt --config <toml>`; config schema is v0.6.2 `[mqtt]` + `[[cameras]]` | Compose service pins tag `v0.6.2` (never `latest`/`master`) with an explicit `command`. |

---

## 2. HEADLINE DECISION: broker isolation for the neolink control plane

The retained `neolink/config` topic carries the Reolink camera credentials.
Threat: on the shared bundled mosquitto (currently `allow_anonymous true`) or
on an operator's existing broker, any client that can subscribe (the Frigate
integration, Home Assistant, anything on the LAN reaching the loopback-published
port) reads camera creds at rest, forever, because the message is retained.

Three candidate mitigations were evaluated:

### Option A (RATIFIED / CHOSEN): dedicated, profile-gated `mosquitto-neolink` broker

A second tiny mosquitto instance under the same `neolink` compose profile.
Options B and C below are recorded for the decision trail; A is what ships.

- **No published host ports at all.** neolink and the api both reach it over
  the compose network (`mqtt://mosquitto-neolink:1883`). This is stricter than
  the Frigate mosquitto (which publishes `127.0.0.1:1883` because Frigate
  usually runs on another host); neolink runs inside the stack, so nothing
  needs host reachability.
- **Password-required** (`allow_anonymous false`, `password_file`). The
  password is `NEOLINK_MQTT_PASSWORD`, generated by `scripts/setup-env.sh`
  (never hardcoded, printed, or logged). The password file is created at
  container start from the env var via a small `entrypoint: sh -c` wrapper
  running `mosquitto_passwd -b -c` before `exec`ing mosquitto (same in-compose
  wrapper style as the `backup-offsite` service).
- The retained-creds topic now lives on a broker whose only two clients are
  neolink and the Crumb api. The Frigate bus, and anything else on the LAN,
  never sees it.

Why A over the others: zero behavior change for existing `frigate`-profile
users (their broker stays as-is), no mosquitto ACL-file surface to author and
maintain, hard isolation instead of policy isolation, and the marginal cost is
one ~10 MB idle container that only exists when the profile is active.

### Option B (rejected as the default; documented for BYO-broker operators)

ACLs on a shared broker: `password_file` + `acl_file` giving the neolink user
`readwrite neolink/#`, the api user `read neolink/#` + its Frigate topics, and
denying `neolink/#` to everyone else. Rejected as the bundled default because
it forces auth onto the existing Frigate mosquitto (a breaking change for
current `frigate`-profile installs) and because ACL files are easy to get
subtly wrong. It IS the right guidance for operators who insist on one
existing external broker, so `docs-site/docs/integrations/neolink.md` must
document the exact ACL requirements and the `neolink/config` retained-creds
warning prominently.

### Option C (not currently available): suppress the config publish

v0.6.2 has no documented switch to disable the `neolink/config` publish. Do
not claim otherwise in docs. Filed as a revisit trigger (and a candidate
upstream contribution): if neolink gains a suppress/redact option, the
dedicated-broker requirement can be relaxed to a recommendation.

### Retained-config scrub (D2, RATIFIED yes)

On every successful MQTT connect, the api publishes a zero-length retained
message to `{prefix}/config`, deleting the retained copy from the broker.
Best-effort, and documented as such: it does not protect against a subscriber
connected at the moment neolink (re)publishes, and neolink re-publishes on its
own restart, so this is defense-in-depth layered on top of the dedicated broker,
not a substitute for it. Cheap (one publish per connect); implemented in §4.1.

---

## 3. Data model

### 3.1 Migration `db/migrations/0047_neolink_binding.sql`

0046 (`scrub_pregen_settings`) is the current tail of the `MIGRATIONS` array in
`services/common/src/db.rs`; **0047 is confirmed free**. Golden rule 4: the
file must be added to the `MIGRATIONS` array in the same change or it silently
never runs. Idempotent style (ADD COLUMN IF NOT EXISTS, CREATE TABLE IF NOT
EXISTS, CREATE OR REPLACE VIEW), no BEGIN/COMMIT, matching 0042's comments.

```sql
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS neolink_name text,          -- NULL = not neolink-bound
    ADD COLUMN IF NOT EXISTS neolink_caps jsonb;         -- e.g. ["floodlight","led","pir"]

-- TTL-revert journal: restart-safe momentary actuations.
CREATE TABLE IF NOT EXISTS camera_actuations (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id      uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    actuator       text NOT NULL,                        -- floodlight|led|ir|pir|siren
    revert_payload text NOT NULL,                        -- 'off' (spike-confirmed for floodlight)
    created_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    reverted_at    timestamptz                           -- NULL = revert still owed
);
CREATE INDEX IF NOT EXISTS camera_actuations_pending_idx
    ON camera_actuations (expires_at) WHERE reverted_at IS NULL;

-- Confirmed-state cache written by the MQTT status subscriber, read by /status.
CREATE TABLE IF NOT EXISTS neolink_camera_status (
    camera_id        uuid PRIMARY KEY REFERENCES cameras(id) ON DELETE CASCADE,
    connected        boolean NOT NULL DEFAULT false,
    floodlight_state text,                               -- retained-echo value, e.g. 'on'/'off'
    last_motion_ts   timestamptz,
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- D4: floodlight momentary/auto-revert default, a LIVE admin-console knob on the
-- server_settings singleton. Nullable = "operator never touched it" -> the
-- resolver falls back to the NEOLINK_FLOODLIGHT_REVERT_SECS env default. DB value
-- wins when set. Mirrors the scrub-preview tunables (#39) and update_check_enabled
-- (#31) exactly: nullable column, DB-wins, NULL->env, resolved per-use (no
-- restart). `server_settings` is the existing id=1 singleton; ADD COLUMN only.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS neolink_floodlight_revert_secs integer;   -- NULL = use env default

CREATE OR REPLACE VIEW v_camera_effective_policy AS
SELECT
    -- ... byte-for-byte the 0042 column list, THEN append at the very end:
    c.neolink_name AS c_neolink_name,
    c.neolink_caps AS c_neolink_caps
FROM ...;
```

**View trap (the one #25 flags, now made precise):** `get_camera` reads
`v_camera_effective_policy`, not the `cameras` table, so the new columns never
surface unless the view is re-declared. `CREATE OR REPLACE VIEW` only permits
APPENDING trailing columns, so `c_neolink_name` / `c_neolink_caps` go at the
tail, **after** `p_max_retention_days`, even though they are camera columns and
the c_/p_ grouping looks wrong. 0042 is the template; copy its full column list
verbatim and append.

Rust side: `Camera` in `services/common/src/types.rs` gains
`neolink_name: Option<String>` and `neolink_caps: Option<Vec<String>>` (parse
the jsonb array; unknown strings tolerated, clients just will not render them);
the row-mapping in `db.rs` reads the two new view columns; the camera
create/update DTOs and `PUT /config/cameras/{id}` in `config_routes.rs` accept
them (partial-update semantics identical to the `onvif_*` fields). Wizard and
console code touch only the fields they edit (config-precedence ground rule).

### 3.2 `neolink_config` singleton (runtime ensure-table, NOT a migration)

Mirror `ensure_frigate_config_table` exactly (`db.rs` ~line 1257): a
`CREATE TABLE IF NOT EXISTS` + `INSERT ... ON CONFLICT DO NOTHING` seed from
env, called from `main.rs` at boot next to the frigate ensure.

```
neolink_config (
    id            smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled       boolean NOT NULL DEFAULT false,
    mqtt_url      text NOT NULL DEFAULT '',      -- e.g. mqtt://mosquitto-neolink:1883
    mqtt_prefix   text NOT NULL DEFAULT 'neolink',
    mqtt_user     text,
    mqtt_password text,                          -- write-only through the API, like frigate
    version       bigint NOT NULL DEFAULT 1,
    updated_at    timestamptz NOT NULL DEFAULT now()
)
```

Env seed keys (first boot only; DB wins thereafter, per the `update_check_enabled`
(#31) and scrub-preview (#39) precedent): `NEOLINK_MQTT_URL`,
`NEOLINK_MQTT_PREFIX`, `NEOLINK_MQTT_USER`, `NEOLINK_MQTT_PASSWORD` (+
`NEOLINK_MQTT_PASSWORD_B64` fallback, cloning the Frigate `$`-escaping
workaround). DB accessors mirror the frigate trio: `get_neolink_settings`,
`update_neolink_settings` (bumps `version`; `mqtt_password = None` leaves the
stored password unchanged, `Some("")` clears), `neolink_config_version`.

### 3.3 D4: floodlight-revert default as a live `server_settings` knob

The floodlight momentary/auto-revert default is server-owned, not a client
constant. The `server_settings.neolink_floodlight_revert_secs` column (added in
0047, §3.1) is resolved at the point of use, exactly like
`services/api/src/scrub_settings.rs::resolve` and `updates.rs::resolve_enabled`:

- A tiny resolver (new `neolink_settings.rs`, or a helper on the neolink module)
  reads the nullable column and falls back to `ApiConfig`'s env default
  (`NEOLINK_FLOODLIGHT_REVERT_SECS`, default 30) when NULL, re-clamping to the
  same bounds the console setter enforces (**1..=3600 s** server-side max clamp
  retained; that is the only surviving piece of the old "3600 s clamp" idea).
- Resolved **per actuation** (the actuator handler in §4.3 calls it when a
  floodlight `on` arrives without an explicit `duration_s`), so an admin edit
  takes effect on the very next tap with no restart. The value is NOT cached in
  the boot-time `ApiConfig` snapshot.
- Setter: `update_neolink_floodlight_revert_secs(pool, Option<i32>)` (NULL to
  reset to env), driven by the admin-console field in §7.1. No `version` bump is
  needed (unlike the MQTT connection settings) because nothing reconnects, the
  next resolve simply reads the new row.

Client-supplied `duration_s` still overrides for a one-off tap; the knob is the
default the clients omit-and-inherit, and the revert engine's server-side truth.

---

## 4. Backend: `services/api/src/neolink/`

New module, three files plus `mod.rs`:

### 4.1 `client.rs`: one supervised rumqttc client

Clone the Frigate provider's shape (`detection/frigate.rs`):

- One `AsyncClient` per process. Capped exponential back-off **1 s -> 30 s,
  reset on ConnAck** in the disconnect/error arm (rumqttc 0.24 inserts no delay
  itself; without this an unreachable broker hot-spins a core on the box shared
  with the recorder). Raced against a stop signal for prompt shutdown.
- Subscriptions (explicit, never `status/#`, to dodge the JPEG preview firehose):
  `{prefix}/status`, `{prefix}/+/status`, `{prefix}/+/status/floodlight`,
  `{prefix}/+/status/motion`.
- A `neolink_name -> camera_id` map loaded from the cameras table, shared via
  `Arc<RwLock<HashMap>>` and reloaded every 60 s (clone `CAMERA_MAP_RELOAD` +
  `camera_map_snapshot`; same self-heal rationale: bind a camera after boot and
  it starts working within a cycle, no restart).
- Status handling: upsert `neolink_camera_status` (connected from
  `{name}/status`, floodlight_state from the retained echo, last_motion_ts from
  `status/motion`). Broker-level disconnect flips a shared "bus down" flag and,
  after a grace period, raises a `neolink_disconnected` system alert through
  the existing `system_alert_rules` machinery in `alerts.rs`.
- Publish path: the route handlers publish through this client (QoS 1,
  retain=false, payload per §4.3). Expose a small handle
  (`NeolinkHandle { publish(...), connected() }`) on `AppState` so routes and
  the revert engine share the one client.
- On connect (D2, ratified): publish an empty **retained** payload to
  `{prefix}/config` to scrub neolink's retained creds-config. Best-effort; log at
  debug, never fail the connect on a publish error.

### 4.2 `main.rs` supervisor (clone the Frigate block, ~line 350)

Poll `neolink_config_version` on the same cadence; on change, stop the current
client task and (re)start from `get_neolink_settings`. `enabled=false` or empty
`mqtt_url` means no client runs (log "neolink disabled in settings"). An admin
edit on the Integrations page reconnects with no api restart.

### 4.3 Actuator endpoint

`POST /cameras/:id/actuator`, mounted via `neolink::routes()` merged in
`main.rs` next to `ptz::routes()` (axum `:id` path-param style).

Request: `{ "actuator": "floodlight|siren|led|ir|pir", "action": "on|off|auto|trigger", "duration_s": u32? }`

Handler order mirrors `ptz.rs::ptz_command` exactly:

1. `user.require_actuators()?` then `user.assert_camera_access(camera_id)?`
2. `db::get_camera` -> 404 if absent
3. 404 `"camera is not neolink-bound"` if `neolink_name` is NULL (parallel to
   PTZ's "camera is not PTZ"); 404 if the neolink client is not running
   (integration disabled)
4. Validate `actuator` against `neolink_caps` -> 400 with the missing cap named
5. Validate `action` per actuator: floodlight/led/pir accept on/off; ir accepts
   on/off/auto; **siren accepts `trigger` only** (one-shot; D3, ships gated
   behind the operator-declared `siren` cap and carries the "unvalidated on real
   hardware" caveat in docs and in the 400 message if the payload is rejected
   upstream). `duration_s` only valid with `action=on`; clamp server-side to
   1..=3600.
6. Publish `{action}` to `{prefix}/{neolink_name}/control/{actuator}`,
   retain=false, QoS 1
7. If `action=on` for the floodlight and `duration_s` is **absent**, resolve the
   D4 default via §3.3 (`server_settings.neolink_floodlight_revert_secs` ->
   env). A present `duration_s` overrides. Then insert a `camera_actuations` row
   (revert_payload `off`) and arm an in-process revert timer. If an un-reverted
   row already exists for this (camera, actuator), supersede it (mark reverted,
   note "superseded") so re-tapping extends rather than double-reverts.
8. `action=off` with a pending row = early cancel: publish `off`, mark the row
   reverted now. 200 `{}` on publish accept (optimistic; confirmed state
   arrives via `/status`).

The momentary default is server-owned (D4, §3.3): clients that want the default
simply omit `duration_s`, and the server resolves the live admin knob. A client
MAY still send an explicit `duration_s` for a one-off longer/shorter tap.

`POST /cameras/:id/reboot`: `AdminUser` extractor (the existing 403-on-non-admin
wrapper in `auth_mw.rs`), because a reboot interrupts recording. Same
neolink-bound checks; publishes to `control/reboot`; no journal row.

### 4.4 `revert.rs`: server-side TTL revert engine

The "closed laptop must not leave the floodlight on all night" invariant. The
TTL itself is server truth: it comes from the request's `duration_s` or, when
omitted for a floodlight, the D4 resolved default (§3.3), never from a
client-held timer. That is precisely why a `server_settings` knob (not a
client constant) is the right home for the default: the value that actually
governs the revert lives on the same side as the engine that enforces it.

- **Arm-on-publish:** tokio timer per pending actuation; on expiry, publish
  `revert_payload` and set `reverted_at`.
- **Boot sweep:** at api start (and supervisor client restart), scan
  `camera_actuations WHERE reverted_at IS NULL`: expired rows get the revert
  published immediately; future rows get timers re-armed. An api restart can
  never strand an actuator.
- **Periodic safety sweep** every 30 s over the same partial index, catching
  lost timers and reverts that failed to publish (defense in depth; the sweep
  is idempotent because publishing `off` twice is harmless, spike-confirmed
  that `off` = restore-auto).
- **Broker down at expiry:** the row stays un-reverted; the sweep retries after
  reconnect; if a revert stays owed past a grace window (60 s), raise a
  `neolink_revert_failed` system alert naming the camera and actuator. This is
  the physical-world analogue of recorder correctness: prefer noisy failure
  over a silently stuck floodlight.

Unit tests target the pure decision logic (which rows are due, supersede
semantics, clamp); integration tests exercise journal arm/sweep against
Postgres (harness rules in §9).

---

## 5. RBAC: new `actuators` capability (NOT reused from PTZ)

Sounding a siren or lighting a floodlight is a physical-world action, distinct
from "can view" and from PTZ. Changes, all mirroring the `ptz` capability:

- `Capabilities` (`services/common/src/types.rs` ~line 877): add
  `#[serde(default)] pub actuators: bool`. Serde-default false means every
  stored role jsonb reads as denied until an admin opts in (forward-compatible,
  conservative).
- `Capabilities::all()`: `actuators: true` (admin implies it).
- `auth_mw.rs`: `can_actuators()` (admin || capability) + `require_actuators()`
  returning the standard 403; `fallback_caps` stays deny-by-default (the
  serde default covers it, but keep the explicit `actuators: false` in the two
  literal `Capabilities { .. }` constructions at ~lines 196/513).
- Role editor in `admin.html`: one checkbox next to PTZ.
- Per-camera scoping rides the existing `assert_camera_access` grant check;
  no new mechanism.

---

## 6. Status surface

No WebSocket/SSE exists; clients poll `GET /status`. Extend
`CameraStatusEntry` (`services/api/src/dto.rs` ~line 1369) with optional,
`#[serde(skip_serializing_if = "Option::is_none")]` fields so older clients
ignore them and non-neolink cameras emit nothing:

```rust
pub neolink_connected: Option<bool>,       // Some(..) only when neolink-bound
pub floodlight_state:  Option<String>,     // confirmed state from the retained echo
pub actuation_expires: Option<DateTime<Utc>>, // pending momentary revert, drives countdown UI
```

`status.rs` batch-loads `neolink_camera_status` plus the pending-actuation rows
once (two queries, joined in memory by camera_id), not per-camera inside the
existing `JoinSet` fan-out. `actuation_expires` lets clients render the
countdown ring from server truth instead of a local timer that drifts or dies
with the tab.

---

## 7. Clients (COMPONENT-MAP section 3: parity stated explicitly)

**Web admin + desktop first. Android + iOS are DEFERRED follow-ups, not
dropped**; tracked as Phase 6 tasks below and in the cross-client parity table
so the gap stays visible.

### 7.1 Web admin (`services/api/src/admin.html`)

One file, inline script, `on*=` wired plain functions, `esc()` for all
interpolation, `api()` for authed fetches, semantic colors
`var(--ok)`/`var(--warn)`/`var(--danger)`; sanity-check with `node --check` on
the extracted script block; rebuild the api to see changes (it is
`include_str!`-embedded; `grep -a`).

- **Integrations -> Neolink page**, cloned from the Frigate settings block
  (backed by `GET/PUT /config/neolink` in `config_routes.rs`, next to
  `/config/frigate` at ~line 3098; password write-only, never echoed; a
  `POST /config/neolink/test` TCP-reachability probe cloned from
  `/config/frigate/test`). Shows bus connected/disconnected state. **Also hosts
  the D4 "Floodlight auto-revert default (seconds)" field** (empty = inherit the
  env default; live per-use resolve per §3.3, like the scrub-preview tunables'
  console fields), backed by the setter in §3.3.
- **Camera editor:** `neolink_name` text field + capability checkboxes
  (floodlight, siren, led, ir, pir) persisting to `neolink_caps`. Help text:
  "must match the `name` in neolink.toml". The siren checkbox carries the D3
  "unvalidated on real hardware" hint.
- **Live tile overlay buttons** drawn from `neolink_caps` x `caps.actuators`:
  floodlight tap = on for the server-resolved default duration (client omits
  `duration_s`) + countdown (from `actuation_expires`), tap again = revert now;
  siren (where declared) press-and-hold ~600 ms to arm (accidental-tap guard) +
  cooldown; LED/PIR plain toggles. No caps, or older server, or 404: no buttons,
  graceful degrade.

### 7.2 Desktop (`apps/desktop/src/app.js`)

Extend the existing PTZ control-tile pattern (`buildPtzPanelHtml` ~4302 /
`wirePtzPanel` ~4332, gating as at ~1848 `caps.ptz`): an actuator cluster in
the pane toolbar, gated on `caps.actuators` AND the camera reporting
`neolink_caps`, same interactions as web. True on-video mpv ASS-overlay
buttons (like the PTZ wheel) are polish, deferred; the toolbar cluster ships
first. Windows note stands: `libmpv-2.dll` beside the exe.

### 7.3 Android (`apps/android`) + iOS/macOS (`apps/ios`): deferred

Actuator bar beside the existing PTZ composables/views + an `actuator()` API
client method + the `/status` fields. Explicitly listed in Phase 6 and in the
COMPONENT-MAP parity row so no session "forgets" them.

---

## 8. Deployment (golden rule 5: install guide must not drift)

### 8.1 Compose (`docker-compose.yml`, validated with `docker compose config` on dev1, real docker)

```yaml
  neolink:
    profiles: ["neolink"]
    image: quantumentangledandy/neolink:v0.6.2   # pinned; RE project, never latest/master
    restart: unless-stopped
    command: ["mqtt", "--config", "/etc/neolink.toml"]
    volumes:
      - ./neolink/neolink.toml:/etc/neolink.toml:ro
    environment: [ TZ=${TZ:-America/Los_Angeles} ]
    # No ports. Control-plane only; reaches cameras + broker over the network.

  mosquitto-neolink:            # Option A dedicated broker (see section 2)
    profiles: ["neolink"]
    image: eclipse-mosquitto:2
    restart: unless-stopped
    # No published host ports: in-stack clients only (neolink + crumb api).
    # entrypoint wrapper: mosquitto_passwd -b -c from NEOLINK_MQTT_PASSWORD,
    # write a listener+password_file+allow_anonymous-false conf, exec mosquitto.
```

The existing `mosquitto` service stays exactly as-is (`profiles: ["frigate"]`,
anonymous, loopback-published): no breaking change for current installs. It
does NOT gain the `neolink` profile; the two buses are separate by design.

### 8.2 Secrets + files

- `scripts/setup-env.sh`: generate `NEOLINK_MQTT_PASSWORD` with the existing
  `gen_secret`/`gen_password` helpers; write a commented `NEOLINK_MQTT_*`
  block (URL default `mqtt://mosquitto-neolink:1883`, prefix `neolink`, user
  `neolink`) plus the commented D4 fallback `NEOLINK_FLOODLIGHT_REVERT_SECS=30`
  (the env floor the admin knob falls back to when the `server_settings` value
  is NULL). Never printed, never logged; `.env` stays gitignored.
- `neolink/neolink.example.toml`: committed, commented v0.6.2 `[mqtt]` +
  `[[cameras]]` skeleton with placeholder creds. The `[mqtt]` block must point at
  the dedicated broker (`server = "mosquitto-neolink"`, `port = 1883`) and carry
  the **same** `NEOLINK_MQTT_PASSWORD` (and `neolink` user) the operator put in
  `.env` and that `mosquitto-neolink` loads into its password file, so a comment
  spells that coupling out. The real `neolink/neolink.toml` (contains that
  broker password AND the Reolink camera passwords) is **added to `.gitignore`**
  in the same change. Crumb-generated TOML stays rejected (the api has no
  writable config mount); revisit trigger recorded in DECISIONS.
- `.env.example`: the same commented `NEOLINK_MQTT_*` block.

### 8.3 Install-surface sweep (same change, per golden rule 5)

`docs/AI-INSTALL.md` (optional-integration step with a Verify), `docs/COMPOSE.md`
(profile table), README manual path, `.env.example`, `scripts/setup-env.sh`,
`docs-site/docs/integrations/neolink.md` (NEW, operator-facing, cloned in tone
from `integrations/frigate.md`, including the BYO-broker ACL guidance + the
retained-creds warning) and `docs-site/docs/configuration/environment-reference.md`
(the `NEOLINK_*` keys). User-facing docs rule applies: the docs-site page is
the documentation of record, not this plan.

---

## 9. Testing + CI notes for implementers

Gate before any push (unchanged): `cargo fmt --all -- --check`,
`cargo clippy --all-targets -- -D warnings`, `cargo test --workspace` against a
throwaway Postgres (`crumb-test-pg` recipe in AGENTS.md).

**DB-test harness trap (cost issue #9 three CI rounds; do not rediscover):**
integration tests must `run_migrations` against the real `public` schema and
isolate by unique keys (unique camera names/uuids per test), NOT by a
`search_path` schema; and the test pool needs `max_size >= 8` or concurrent
tests deadlock on connection starvation.

Specific test obligations:

- Migration 0047 registered-and-applies test rides the existing migration
  test; add an assertion that `v_camera_effective_policy` exposes
  `c_neolink_name`/`c_neolink_caps`.
- Revert engine: unit tests for due-row selection, supersede, clamp; an
  integration test that inserts an expired un-reverted row and asserts the
  boot sweep marks it reverted (publish mocked through the handle trait).
- Capability: `require_actuators` denied for a default role, allowed for
  admin and for an opted-in role; endpoint 403/404/400 matrix.
- Serde: `CameraStatusEntry` omits the neolink fields when None (byte-level
  JSON assertion), old-client compatibility proof.

---

## 10. COMPONENT-MAP propagation walk (golden rule 8)

Rows that fire for this change, each updated or satisfied in the change that
triggers it:

- **A (new endpoint/DTO):** `/cameras/:id/actuator`, `/cameras/:id/reboot`,
  `/config/neolink`, CameraStatusEntry fields.
- **B (new setting/env):** `NEOLINK_MQTT_*` seed keys + `neolink_config`
  singleton; the D4 `server_settings.neolink_floodlight_revert_secs` admin knob
  + its `NEOLINK_FLOODLIGHT_REVERT_SECS` env fallback; env-reference docs page.
- **C (new migration):** 0047 + MIGRATIONS registration.
- **E (new camera capability):** actuators join PTZ/imaging in the camera
  editor + per-camera caps.
- **G (RBAC change):** new capability, role editor, deny-by-default.
- **H (admin console):** Integrations page, camera editor, live-tile buttons.
- **I (install/compose/secret):** section 8 sweep list.
- **L (user-visible capability):** announce path (README feature list,
  docs-site, release notes).
- **M (decision):** section 11 entry.
- **Section 3 (cross-client parity):** add an "Actuators (neolink)" row: web
  admin SHIPPED, desktop SHIPPED, Android DEFERRED, iOS/macOS DEFERRED.

`docs/COMPONENT-MAP.md` itself gains the new surface (the neolink sidecar +
its example TOML) in §1.3.

## 11. Required DECISIONS.md entry (write in the Phase 1 change)

Title: "Reolink control via neolink sidecar over MQTT; dedicated broker for
the control plane".

- **Chosen:** unmodified neolink v0.6.2 container, profile-gated, no published
  ports, control/status plane only; one supervised rumqttc client + version-bump
  hot reload; `POST /cameras/:id/actuator` mirroring ptz.rs; server-side TTL
  revert journal + boot sweep; new `actuators` capability; operator-declared
  per-camera `neolink_name`/`neolink_caps`; **dedicated password-protected
  `mosquitto-neolink` broker (D1)** because neolink publishes camera credentials
  to a retained `neolink/config` topic (spike-verified), making a shared broker
  with password-only auth insufficient; **best-effort retained-config scrub on
  connect (D2)** as defense-in-depth on top of the dedicated broker; **siren
  shipped gated behind an operator-declared `siren` cap with an
  "unvalidated on real hardware" caveat (D3)** rather than held pending
  siren-capable hardware; **the floodlight momentary/auto-revert default as a
  live `server_settings` admin knob resolved per-use (D4)**, nullable-column /
  DB-wins / NULL->env with a 1..=3600 s server clamp, following the #39
  scrub-preview and #31 `update_check_enabled` precedent.
- **Rejected:** neolink-as-a-crate (huge dep tree incl. gstreamer tracking a
  fast-moving RE project; golden rule 6); Home Assistant as control plane
  (mandatory third service); client-side revert timers (closed laptop = light
  on all night); read-then-restore revert (racy, model-dependent; spike showed
  plain `off` restores auto); ACLs on the shared Frigate mosquitto as the
  default (D1 alternative: breaking change to existing installs, ACL authoring
  risk; kept as documented BYO-broker guidance); Crumb-generated neolink TOML
  (api has no writable config mount); **a client-side floodlight-revert constant
  (D4 alternative: the TTL that governs a physical light would then live on the
  wrong side of the wire from the engine that enforces it, and could not be
  retuned without shipping every client).**
- **Revisit triggers:** neolink gains a config-publish suppress/redact option
  or a config API; a battery/Baichuan-only camera use case appears
  (neolink-as-source, parked); clients need push (WebSocket/SSE) rather than
  `/status` polling for confirmed state; the neolink project stalls or a
  firmware update breaks the pinned tag; a second MQTT consumer needs the
  neolink bus (would reopen ACL-vs-dedicated); **reliable Reolink model/actuator
  detection becomes available, which would unlock the camera-add "enable
  floodlight/siren control?" proactive nudge currently deferred as a fast-follow
  (§14).**

---

## 12. Phased task breakdown

Every task ends green on the full gate (fmt, clippy -D warnings, workspace
tests, §9 harness rules). Model tags: Sonnet unless flagged. One branch per
task or per phase at the implementer's discretion, but Phase 1 lands before
anything depending on it.

### Phase 1: schema + capability foundation

**T1. Migration 0047 + Camera plumbing** (Sonnet, M)
Files: `db/migrations/0047_neolink_binding.sql` (the two `cameras` columns, the
`camera_actuations` + `neolink_camera_status` tables, the
`server_settings.neolink_floodlight_revert_secs` D4 column, and the
`CREATE OR REPLACE VIEW`), `services/common/src/db.rs` (MIGRATIONS array + row
mapping + camera update), `services/common/src/types.rs` (Camera fields),
`services/api/src/config_routes.rs` + `dto.rs` (camera create/update DTOs).
Accept: migration applies on fresh + existing DB; view exposes the two new
camera columns at the tail; `server_settings` gains the nullable D4 column;
`PUT /config/cameras/{id}` round-trips `neolink_name`/`neolink_caps`; partial
update leaves them untouched when omitted.

**T2. `neolink_config` singleton + settings routes** (Sonnet, S)
Files: `services/common/src/db.rs` (`ensure_neolink_config_table`,
get/update/version fns), `services/api/src/main.rs` (boot ensure),
`services/api/src/config_routes.rs` (`GET/PUT /config/neolink`,
`POST /config/neolink/test`), `dto.rs`.
Accept: seed-from-env on first boot only; password write-only (GET never
returns it, None leaves unchanged, `""` clears); PUT bumps version.

**T3. `actuators` RBAC capability** (Sonnet, S)
Files: `services/common/src/types.rs` (Capabilities + all()),
`services/api/src/auth_mw.rs` (`can_actuators`/`require_actuators` + the two
literal constructions), `services/api/src/admin.html` (role-editor checkbox).
Accept: stored roles without the key deserialize to false; admin true; role
editor persists it; `node --check` passes on the extracted script.

### Phase 2: MQTT control plane

**T4. Supervised neolink MQTT client + main.rs supervisor** (Sonnet, L)
Files: `services/api/src/neolink/{mod,client}.rs`, `main.rs` (supervisor block
+ AppState handle), `services/api/src/alerts.rs` (`neolink_disconnected` rule).
Accept: back-off caps at 30 s and resets on ConnAck; explicit status
subscriptions only (a `status/preview` publish is never received);
`neolink_camera_status` upserts from retained echo on connect; version bump
reconnects without api restart; disabled config runs no client.

**T5. Actuator + reboot endpoints** (Sonnet, M)
Files: `services/api/src/neolink/routes.rs`, `main.rs` (merge routes),
`dto.rs`.
Accept: full 403/404/400 matrix from §4.3 (capability, camera grant, not-bound,
undeclared cap, bad action, clamp); a floodlight `on` with no `duration_s`
resolves the D4 default (T5a) rather than a hardcoded number; siren gated on the
declared `siren` cap; publish is QoS 1 retain=false to the exact spike topic;
reboot requires AdminUser.

**T5a. D4 floodlight-revert default: `server_settings` resolver + setter**
(Sonnet, S)
Files: `services/api/src/neolink_settings.rs` (new resolver, cloning
`scrub_settings.rs::resolve`: nullable DB column over the
`NEOLINK_FLOODLIGHT_REVERT_SECS` env default, clamp 1..=3600),
`services/common/src/db.rs` (`update_neolink_floodlight_revert_secs(Option<i32>)`),
`services/api/src/config.rs` (env default), `services/api/src/config_routes.rs`
(field on `GET/PUT /config/neolink`).
Accept: NULL column resolves to the env default; a set value wins and is
re-clamped; `""`/null via the API resets to NULL->env; resolve is per-call (no
`ApiConfig` snapshot), proven by a unit test on the pure merge like the
scrub-preview tests; no `version` bump required.

**T6. TTL revert engine + boot/periodic sweep** (Sonnet, L; **[OPUS] review
pass on the failure-mode matrix**, this is the physical-world-safety core)
Files: `services/api/src/neolink/revert.rs`, `db.rs` (journal accessors),
`alerts.rs` (`neolink_revert_failed`).
Accept: §9 revert tests green; kill-the-api-mid-TTL scenario reverts on
next boot; broker-down revert retries then alerts; supersede + early-cancel
semantics proven; sweep idempotent.

### Phase 3: status

**T7. `/status` join** (Sonnet, S)
Files: `services/api/src/status.rs`, `dto.rs`.
Accept: fields absent (not null) for non-neolink cameras and older payload
shape unchanged; two batch queries, no per-camera N+1; `actuation_expires`
reflects the pending journal row.

### Phase 4: clients (web + desktop)

**T8. Web admin: Integrations page + camera editor** (Sonnet, M)
Files: `services/api/src/admin.html`.
Accept: page clones the Frigate one (enable, url, prefix, user, write-only
password, test button, connected badge) plus the D4 "Floodlight auto-revert
default (seconds)" field (empty = inherit env; live per-use resolve); camera
editor fields persist incl. the D3-hinted siren checkbox; `esc()` on all
interpolations; `node --check` green; api rebuilt to verify.

**T9. Web admin: live-tile actuator buttons** (Sonnet, M)
Files: `services/api/src/admin.html`.
Accept: buttons drawn only from `neolink_caps` AND `caps.actuators`;
floodlight countdown driven by `actuation_expires`; tap-again cancels; siren
press-hold 600 ms guard; no-caps/older-server degrade renders nothing.

**T10. Desktop: actuator cluster on the PTZ tile pattern** (Sonnet, M)
Files: `apps/desktop/src/app.js` (+ rebuild per
docs: Tauri bakes ../src into the exe; rebuild + relaunch + CDP-verify before
claiming done; `libmpv-2.dll` beside the exe).
Accept: same interaction matrix as T9; gated `caps.actuators`; verified live
against a dev server via CDP.

### Phase 5: deployment + docs + governance

**T11. Compose + dedicated broker + secrets** (Sonnet, M; **[OPUS] for the
mosquitto-neolink auth wrapper + a broker-isolation threat-model check**)
Files: `docker-compose.yml`, `scripts/setup-env.sh`, `.env.example`,
`.gitignore`, `neolink/neolink.example.toml`.
Accept: `docker compose config` clean on dev1 (real docker, not a YAML
parser); plain `up -d` starts neither new service; `--profile neolink` starts
both; broker rejects anonymous; no published ports on either new service; no
secret printed or logged.

**T12. Docs sweep** (Sonnet, M)
Files: `docs/AI-INSTALL.md`, `docs/COMPOSE.md`, README,
`docs-site/docs/integrations/neolink.md` (new),
`docs-site/docs/configuration/environment-reference.md`.
Accept: AI-INSTALL step has a Verify; docs-site page is operator-language and
carries the BYO-broker ACL + retained-creds warning; env reference lists every
`NEOLINK_*` key.

**T13. COMPONENT-MAP + DECISIONS entries** (Sonnet, S; ideally folded into the
Phase 1 and T11 changes rather than a trailing task, per golden rules 7/8)
Files: `docs/COMPONENT-MAP.md`, `docs/DECISIONS.md`.
Accept: §10 rows + parity row present; §11 entry verbatim in spirit.

### Phase 6 (deferred, tracked): mobile parity

**T14. Android actuator bar** (Sonnet, L): Compose actuator row by the PTZ
controls, `actuator()` API method, `/status` fields; build on dev1, verify via
wireless ADB. **T15. iOS/macOS** (Sonnet, L): SwiftUI equivalent in
`apps/ios/Crumb/` (NOT apps/desktop), build on macmini.

Effort roughly matches #25's estimate: backend 4-6 focused days (Phases 1-3),
web+desktop 3-4, deploy/docs 1, mobile 2-3 each when scheduled.

---

## 13. Decisions (all RESOLVED by the maintainer, 2026-07-10)

- **D1 = dedicated broker (RESOLVED).** Ship Option A, a dedicated
  `mosquitto-neolink` container under the `neolink` profile: no published host
  ports, `allow_anonymous false`, password from a setup-env-generated
  `NEOLINK_MQTT_PASSWORD`. This is the neolink control plane's broker, never the
  shared Frigate mosquitto. Option B (ACLs on a shared broker) is kept only as
  documented BYO-broker guidance; Option C (upstream config-suppress) is a
  revisit trigger. Threaded through §2, §8, T11.
- **D2 = yes (RESOLVED).** The api publishes an empty retained message to
  `{prefix}/config` on each connect, best-effort with the documented caveats.
  Implemented in §4.1 / T4.
- **D3 = yes, gated (RESOLVED).** Siren ships behind the operator-declared
  `siren` cap with an explicit "unvalidated on real hardware (spike CX410 had
  none)" note in the camera editor and docs-site page; the feature is not held.
  §4.3, §7.1, T8, T12.
- **D4 = live `server_settings` admin knob (RESOLVED).** The floodlight
  momentary/auto-revert default is `server_settings.neolink_floodlight_revert_secs`
  (nullable, DB-wins, NULL->`NEOLINK_FLOODLIGHT_REVERT_SECS` env, resolved
  per-use, 1..=3600 s server clamp), NOT a client-side constant. Threaded
  through §3.1, §3.3, §4.3, §4.4, §7.1, §8.2, and tasks T1/T5/T5a/T8.

Nothing here remains blocking; the phased breakdown in §12 is cleared to start.

---

## 14. Setup gating & zero-footprint for non-Reolink installs

A maintainer question: does adding neolink cost anything for the operator who
has no Reolink cameras? Answer: no. The feature is inert until an operator who
actually wants it turns it on, and it is never presented during base install or
first-run. Concretely, it is OFF at three independent layers, any one of which
suffices:

1. **Compose profile (nothing runs).** Both new services carry
   `profiles: ["neolink"]`. A plain `docker compose up -d` starts neither the
   `neolink` sidecar nor the dedicated `mosquitto-neolink` broker. Zero extra
   containers, images, ports, or RAM on a default stack. (The base stack stays
   the 4-container default; §8.1.)
2. **Backend dormant unless configured.** The `neolink_config` singleton
   defaults `enabled=false` with an empty `mqtt_url`, so the §4.2 supervisor
   starts **no** MQTT client task, exactly like the Frigate provider when
   `FRIGATE_MQTT_URL` is unset. And no camera has a `neolink_name`, so even a
   running client has nothing to talk to. The api spins up identically whether
   or not neolink exists.
3. **UI gated (no buttons, no page noise).** Live-tile actuator buttons render
   only when a camera reports `neolink_caps` AND the user holds the `actuators`
   capability (deny-by-default). A non-Reolink operator sees no actuator UI on
   any tile. The Integrations -> Neolink page exists but is just another opt-in
   integration card alongside Frigate, not a step anyone is forced through.

**It is a post-setup OPTIONAL integration, not part of the base install or the
first-run wizard.** The wizard (migration 0027 onboarding) does not mention
neolink; a non-Reolink operator never encounters a neolink decision. An operator
who has Reolinks and wants actuator control enables it on demand: open
Integrations -> Neolink (Frigate-shaped), turn it on, point it at the dedicated
broker, then set each Reolink camera's `neolink_name` + caps in the camera
editor. This mirrors how Frigate detection is opt-in today.

**v1 is manual opt-in.** The proactive camera-add nudge, "we detected a Reolink,
enable floodlight/siren control?", is recorded as an explicit **FAST-FOLLOW,
not v1.** Caveat that gates it: Reolink model/actuator detection is not reliable
(the spike showed the CX410 advertises no siren and neolink does not
advertise caps), so a nudge risks offering controls a given model does not have.
The fast-follow would need a confidence check (e.g. ONVIF/Baichuan model probe
plus a "you can adjust these" confirmation) before it earns its place; until
then, operator-declared caps in the camera editor are the source of truth and
manual enablement is the shipped path. Recorded as a revisit trigger in the
DECISIONS entry (§11) rather than built now.
