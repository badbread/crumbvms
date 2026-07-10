# Reolink actuator control via direct HTTP-API client: implementable design + phased plan (issue #25)

Status: DESIGN, ratified by the maintainer 2026-07-10. This document
**supersedes `docs/NEOLINK-ACTUATOR-PLAN.md`**, which is retained as the
rejected-alternative record for the neolink-MQTT sidecar architecture. The
"why" behind the pivot — the retained-credential leak, the dead siren on the
spike CX410, the two-container/broker footprint, and the fact that the earlier
"rejected in-process" alternative was the port-9000 binary Baichuan protocol
and never the documented HTTP API — lives in
`docs/REOLINK-CONTROL-ARCH-DECISION.md` and is not re-argued here.

**Ratified decisions baked into this plan (do not re-litigate):**

- **Architecture = direct Reolink HTTP-API client, in-process, reqwest.**
  Login→token auth, HTTPS-first with HTTP fallback, the documented CGI command
  set (`AudioAlarmPlay`, `SetWhiteLed`, `SetIrLights`, `SetPowerLed`,
  `SetPirInfo`, `Reboot`), and **`GetAbility` for per-model capability
  detection** (replacing the old plan's operator-declared `neolink_caps`).
  No container, no broker, no MQTT, no new secret.
- **Battery/Baichuan-only Reolinks are OUT of scope** (parked; revisit
  trigger). Those cameras also cannot be Crumb RTSP sources today.
- **Siren ships GATED** behind the detected capability and is documented as
  model/firmware-flaky (D3 stands; HA core #91517, #98594, #159989).
- **D4 stands:** the floodlight momentary/auto-revert default is a live
  `server_settings` admin knob (nullable column, DB-wins, NULL→env, resolved
  per-use; the #39 / #31 precedent), not a client constant.
- **Dropped entirely:** the `neolink` container, the dedicated
  `mosquitto-neolink` broker, D1 (broker isolation) + D2 (retained-config
  scrub), the rumqttc MQTT client task (old T4), `NEOLINK_MQTT_PASSWORD` and
  the whole `NEOLINK_MQTT_*` env block, the profile-gated compose services,
  `neolink.toml`, and every retained-topic concern. None of these have a
  successor; the problems they solved do not exist without the bus.

Scope (unchanged from #25): actuator **control** only. Cameras keep their
native RTSP `source_url` and `served_by='crumb'`. Actuators in scope:
floodlight, siren, status-LED, IR, PIR, reboot. Out of scope, parked:
Reolink-as-RTSP-source for battery cams, two-way audio.

**Non-Reolink operators pay nothing: no camera bound → completely dormant,
exactly like ONVIF/PTZ today. See §12.**

---

## 1. Architecture

```
Crumb api ──HTTPS:443 (fallback HTTP:80)──> Reolink camera  /cgi-bin/api.cgi
  (reqwest, Login→token, POST JSON command arrays, LAN-only)
```

One new module, `services/api/src/reolink/`, living entirely inside the api
process. It is the same authed-device-HTTP shape the api already ships twice:

- `services/api/src/ptz.rs` — per-request ONVIF SOAP to the camera, per-camera
  creds resolved from DB columns, stateless, `require_ptz()` →
  `assert_camera_access()` handler order. The actuator endpoint mirrors
  `ptz_command` line-for-line (§4.3).
- `services/api/src/detection/frigate.rs:648` — `reqwest::Client::builder()`
  for an authed service. `reqwest` is already a workspace dependency; **no new
  crates** (golden rule 6 satisfied by construction).

Control is synchronous request/response: the handler knows success or failure
before it returns, so there is no optimistic-publish-then-reconcile dance. The
server-side TTL-revert journal (§4.4) still exists — it enforces the
closed-laptop invariant — but it arms off a call the server already knows
landed.

Differences from the neolink plan worth naming once:

| Concern | neolink-MQTT plan | This plan |
|---|---|---|
| Transport | fire-and-forget MQTT publish | synchronous HTTP, result in-hand |
| Confirmed state | retained status-topic echoes | poll `GetWhiteLed` etc. (§4.5) + write-through after each successful command |
| Capabilities | operator-declared `neolink_caps` checkboxes | **auto-detected** from `GetAbility`, cached (§4.2) |
| Floodlight surface | `on\|off` only | full mode set (off/auto/onatnight/schedule/adaptive) + brightness |
| Siren off | did not exist in the protocol | `AudioAlarmPlay manual_switch:0` — a real off |
| Creds at rest | DB + neolink.toml + retained broker topic | DB only |
| New processes | 2 containers + broker + supervised MQTT task | none |

---

## 2. Verified facts this design leans on

From `docs/REOLINK-CONTROL-ARCH-DECISION.md` (triangulated across
`reolink_aio`, `fwestenberg/reolink`, and Reolink community docs; confidence
high on command shapes):

| Fact | Design consequence |
|---|---|
| All commands are `POST /cgi-bin/api.cgi?cmd=<Cmd>&token=<tok>` with a JSON **array** body; `Login` returns `Token{name, leaseTime}` | One small client with a per-camera token cache (§4.1); token rides the query string. |
| `reolink_aio` tries HTTPS:443 first, falls back to HTTP:80 (old firmwares are HTTP-only) | Mirror it. Accept self-signed certs on the HTTPS path (Reolink certs are self-signed); LAN-only posture, same as ONVIF today. Cache the working scheme per camera in memory. |
| Siren: `{"cmd":"AudioAlarmPlay","action":0,"param":{"alarm_mode":"manul","manual_switch":1,"times":2,"channel":0}}` — `manual_switch` 1/0 = on/off; `alarm_mode:"times"` plays N cycles. (`"manul"` is Reolink's own spelling; keep it.) | Siren on/off is manual-mode; Crumb's own TTL revert bounds it (§4.4) rather than the camera-side duration, because a duration-started siren cannot be stopped early on some models (HA #159989). |
| Floodlight: `{"cmd":"SetWhiteLed","param":{"WhiteLed":{"state":1,"channel":0,"mode":1,"bright":100}}}` with modes off/auto/onatnight/schedule/adaptive and `bright` 1..=100; `GetWhiteLed` reads current config | `SetWhiteLed` is an **absolute** setter — there is no neolink-style "off restores auto" magic. The revert engine therefore snapshots the pre-actuation `GetWhiteLed` state and restores it (§4.4). |
| `SetIrLights` (`state: "Auto"\|"On"\|"Off"`), `SetPowerLed`, `SetPirInfo`, `Reboot` | Straight command mappings; per-actuator action validation in §4.3. |
| `GetAbility` returns a per-channel abilities map; `reolink_aio`'s `supported(channel, cap)` / `api_version(cap)` gates every control per model | Capability auto-detection (§4.2). Crumb caches the derived caps per camera; clients render buttons only from the cache. |
| Error shape: HTTP 200 with `[{"cmd":…,"code":1,"error":{"rspCode":-9,"detail":"not support"}}]`; known codes include `-9` not-support (HA #91517), `-17` rcv-failed (HA #98594), auth/lease failures | Central rspCode mapping in the client (§4.1): `-9` → 409 "not supported on this model" + prune the cached cap; auth failure → one re-login retry then 502. |
| Some firmwares lock accounts after rapid failed logins; leases can be short | Cache tokens per camera, refresh before expiry, back off on repeated auth failure (never hot-loop a login). |

The #26 spike CX410 (fw v3.1.0.3429) remains available as real verification
hardware for T3/T4.

---

## 3. Data model

### 3.1 Credential storage: dedicated `reolink_*` columns (DECIDED)

Two options were weighed:

- **Reuse the `onvif_*` columns.** Same physical device, usually the same
  admin credentials. Rejected: the ports/schemes differ (Reolink ONVIF is
  typically :8000; the HTTP API is :443/:80 with an HTTPS-then-HTTP probe), so
  `onvif_port` cannot be reused and a scheme column would be needed anyway;
  it would couple two independent features (an operator must not have to
  configure ONVIF to get actuator buttons, or vice versa); and NULL-ness of
  `onvif_host` already means "no PTZ", which would become ambiguous.
- **Dedicated `reolink_*` columns** (CHOSEN). `reolink_host IS NOT NULL` is
  the binding sentinel (the direct successor of the old `neolink_name`), the
  camera editor offers a one-click "copy from ONVIF" prefill for the common
  same-device case, and the two features stay orthogonal. No env fallback is
  needed (unlike `ONVIF_CONFIG` there is no legacy deployment to honor).

### 3.2 Migration `db/migrations/0047_reolink_actuators.sql`

0046 (`scrub_pregen_settings`) is the current tail of the `MIGRATIONS` array
in `services/common/src/db.rs` (verified 2026-07-10); **0047 is confirmed
free**. Golden rule 4: the file must be added to the `MIGRATIONS` array in the
same change or it silently never runs. Idempotent style (ADD COLUMN IF NOT
EXISTS, CREATE TABLE IF NOT EXISTS, CREATE OR REPLACE VIEW), no BEGIN/COMMIT,
comments matching 0042's.

```sql
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS reolink_host     text,   -- NULL = not Reolink-bound
    ADD COLUMN IF NOT EXISTS reolink_user     text,
    ADD COLUMN IF NOT EXISTS reolink_password text,   -- write-only via API, like onvif_password
    ADD COLUMN IF NOT EXISTS reolink_caps     jsonb,  -- CACHED GetAbility-derived caps,
                                                      -- e.g. ["floodlight","siren","ir","pir","power_led"]
    ADD COLUMN IF NOT EXISTS reolink_caps_updated_at timestamptz;  -- cache freshness

-- TTL-revert journal: restart-safe momentary actuations (ported unchanged in
-- shape from the neolink plan; revert_payload is now the JSON command param
-- to replay, not an MQTT payload string — see §4.4).
CREATE TABLE IF NOT EXISTS camera_actuations (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id      uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    actuator       text NOT NULL,          -- floodlight|siren|led|ir|pir
    revert_payload text NOT NULL,          -- JSON: the SetWhiteLed/AudioAlarmPlay param to restore
    created_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    reverted_at    timestamptz             -- NULL = revert still owed
);
CREATE INDEX IF NOT EXISTS camera_actuations_pending_idx
    ON camera_actuations (expires_at) WHERE reverted_at IS NULL;

-- Confirmed-state cache written by the §4.5 poller (and write-through after
-- each successful command), read by /status. last_motion_ts from the neolink
-- plan is DROPPED: Crumb's own motion pipeline covers motion; polling
-- GetMdState would be redundant.
CREATE TABLE IF NOT EXISTS reolink_camera_status (
    camera_id        uuid PRIMARY KEY REFERENCES cameras(id) ON DELETE CASCADE,
    reachable        boolean NOT NULL DEFAULT false,
    floodlight_state jsonb,                -- last-read WhiteLed object (state/mode/bright)
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- D4 (SURVIVES, renamed): floodlight momentary/auto-revert default as a LIVE
-- admin knob on the server_settings singleton. Nullable = "operator never
-- touched it" -> resolver falls back to the REOLINK_FLOODLIGHT_REVERT_SECS
-- env default. Mirrors the scrub-preview tunables (#39) and
-- update_check_enabled (#31) exactly: nullable column, DB-wins, NULL->env,
-- resolved per-use (no restart). ADD COLUMN only on the id=1 singleton.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS reolink_floodlight_revert_secs integer;  -- NULL = env default

CREATE OR REPLACE VIEW v_camera_effective_policy AS
SELECT
    -- ... byte-for-byte the CURRENT view column list, THEN append at the very end:
    c.reolink_host            AS c_reolink_host,
    c.reolink_user            AS c_reolink_user,
    c.reolink_password        AS c_reolink_password,
    c.reolink_caps            AS c_reolink_caps,
    c.reolink_caps_updated_at AS c_reolink_caps_updated_at
FROM ...;
```

**View trap (unchanged from the neolink plan, still load-bearing):**
`get_camera` reads `v_camera_effective_policy`, not the `cameras` table, so
the new columns never surface unless the view is re-declared. `CREATE OR
REPLACE VIEW` only permits APPENDING trailing columns, so the `c_reolink_*`
columns go at the tail — after everything, even though the c_/p_ grouping
looks wrong. 0042 is the template; copy the current full column list verbatim
and append.

Rust side: `Camera` in `services/common/src/types.rs` gains
`reolink_host/user/password: Option<String>`,
`reolink_caps: Option<Vec<String>>` (parse the jsonb array; unknown strings
tolerated — clients just don't render them), and
`reolink_caps_updated_at: Option<DateTime<Utc>>`; the row mapping in `db.rs`
reads the new view columns; the camera create/update DTOs and
`PUT /config/cameras/{id}` in `config_routes.rs` accept host/user/password
with **partial-update semantics identical to the `onvif_*` fields**
(password write-only: omitted = unchanged, `""` = clear; GET never returns
it). `reolink_caps` is **not** operator-writable through the camera DTO — it
is owned by the detection path (§4.2); the DTO exposes it read-only.

### 3.3 D4 resolver (ported, renamed)

`services/api/src/reolink/settings.rs` (or a helper in the module) clones
`scrub_settings.rs::resolve`: read the nullable
`server_settings.reolink_floodlight_revert_secs`, fall back to `ApiConfig`'s
`REOLINK_FLOODLIGHT_REVERT_SECS` env default (default **30**), clamp
**1..=3600 s** server-side. Resolved **per actuation** (never cached in the
boot `ApiConfig` snapshot), so an admin edit takes effect on the next tap with
no restart. Setter `update_reolink_floodlight_revert_secs(pool, Option<i32>)`
(NULL resets to env), surfaced on the same settings panel that hosts the
scrub-preview tunables (§7.1). No `version` bump machinery — nothing
reconnects; the next resolve reads the new row.

There is **no `reolink_config` singleton** and no Integrations-page service
config (the neolink plan's §3.2 dies with the broker): with direct HTTP there
is no external service to point at. The per-camera binding IS the entire
configuration, exactly like ONVIF PTZ.

---

## 4. Backend: `services/api/src/reolink/`

New module: `mod.rs`, `client.rs`, `caps.rs`, `routes.rs`, `revert.rs`,
`poll.rs`. Merged in `main.rs` next to `ptz::routes()` (axum `:id` path-param
style).

### 4.1 `client.rs`: the HTTP client + token cache

- **One shared `reqwest::Client`** built like `frigate.rs:648` (timeouts:
  ~5 s connect, ~10 s total), plus a second builder with
  `danger_accept_invalid_certs(true)` for the HTTPS path (Reolink ships
  self-signed certs; this is LAN-only device traffic, the same trust model as
  cleartext ONVIF SOAP today — document, don't hide).
- **Scheme probe:** first contact tries `https://host/cgi-bin/api.cgi`, falls
  back to `http://host` on connect/TLS error; the working scheme is cached in
  memory per camera (a `DashMap`/`RwLock<HashMap<Uuid, _>>` on `AppState`,
  same shape as existing shared maps).
- **Token cache:** `HashMap<Uuid, TokenEntry { token, expires_at }>`. `Login`
  once per camera, reuse until ~60 s before `leaseTime` expiry, then
  re-login. On an auth-failure rspCode mid-flight: drop the cached token,
  re-login **once**, retry the command once, then fail. On repeated login
  failures, back off (cap ~60 s) before the next attempt — some firmwares
  lock accounts on rapid failed logins; never hot-loop.
- **Command surface** (each a typed fn returning `anyhow::Result<Value>` or a
  typed DTO): `login`, `get_ability`, `get_dev_info` (model/firmware for the
  editor display and issue reports), `get_white_led`, `set_white_led(state,
  mode, bright)`, `audio_alarm_play(manual_switch | times)`,
  `set_ir_lights(state)`, `set_power_led(state)`, `set_pir_info(enabled)`,
  `reboot`. Request construction and response parsing are **pure functions**
  (build the JSON array body / parse the `code`/`rspCode` envelope) so they
  unit-test without a network.
- **Error mapping**, centralized: transport error → `502`-style
  `ApiError::Internal` with the camera named; `rspCode -9 / "not support"` →
  `ApiError::Conflict`-class response `"'<actuator>' is not supported by this
  camera model/firmware"` **and** prune that cap from the cached
  `reolink_caps` (self-healing when `GetAbility` over-promised, the E1-Zoom
  case, HA #91517); auth rspCodes → the retry-once path above; anything else
  (e.g. `-17 rcv failed`) → 502 with the rspCode + detail surfaced verbatim
  in the error string so operators can search HA's issue corpus.
- **Never log credentials or tokens** (the `?token=` query string must be
  redacted in any logged URL). Passwords stay in memory only, like
  `OnvifCameraConfig`.
- Credential resolution mirrors `ptz.rs::resolve_onvif_config` minus the env
  arm: DB columns only; NULL `reolink_host` → 404 `"camera is not
  Reolink-bound"` (parallel to "camera is not PTZ").

### 4.2 `caps.rs`: capability auto-detection (replaces operator-declared caps)

- `detect(camera) -> Vec<Cap>`: call `GetAbility` (plus `GetDevInfo` for
  display), map the abilities to Crumb's actuator caps. The authoritative
  ability-key → capability mapping is `reolink_aio`'s `supported()` /
  `api_version()` table (e.g. floodlight ⇔ `GetWhiteLed` api version > 0,
  siren ⇔ the audio-alarm ability); the implementer lifts the exact key names
  from `reolink_aio/api.py` and verifies against the CX410. Cap vocabulary:
  `floodlight`, `siren`, `ir`, `pir`, `power_led` (reboot is not a cap; every
  Reolink can reboot).
- **When it runs:** (a) automatically when a camera's `reolink_host`/creds
  are set or changed (bind-time), (b) on demand via
  `POST /cameras/:id/reolink/detect` (admin-only; the camera editor's
  "Detect capabilities" button), (c) lazily refreshed by the §4.5 poller when
  `reolink_caps_updated_at` is older than ~24 h. Results upsert
  `reolink_caps` + `reolink_caps_updated_at`.
- Detection failure (camera unreachable, bad creds) leaves the cache
  untouched and returns the error to the caller — bind-time detection failing
  must not block saving the camera (the editor shows the error; the operator
  can retry).
- **Siren stays gated AND flagged (D3):** even when detected, the cap is
  rendered with the "model/firmware-flaky" caveat — `GetAbility` advertising
  the audio alarm does not guarantee `AudioAlarmPlay` works (HA #91517
  E1 Zoom `-9/not support`, #98594 RLC-510WA `-17/rcv failed`, #159989 Atlas
  PT Ultra can't-stop-during-duration). The docs-site page carries the same
  caveat and links those issues as the compatibility oracle.

### 4.3 `routes.rs`: actuator + reboot + detect endpoints

`POST /cameras/:id/actuator` — request:

```json
{ "actuator": "floodlight|siren|led|ir|pir",
  "action":   "on|off|auto",
  "duration_s": 30,          // optional; only with action=on
  "brightness": 80 }         // optional; floodlight only, 1..=100
```

Handler order mirrors `ptz.rs::ptz_command` exactly:

1. `user.require_actuators()?` then `user.assert_camera_access(camera_id)?`
2. `db::get_camera` → 404 if absent
3. 404 `"camera is not Reolink-bound"` if `reolink_host` is NULL
4. Validate `actuator` against the **cached** `reolink_caps` → 400 naming the
   missing cap (with a hint to run capability detection if the cache is
   empty)
5. Validate `action` per actuator: floodlight accepts on/off/auto (+ optional
   `brightness`); ir accepts on/off/auto; led/pir accept on/off; **siren
   accepts on/off** (a real off now exists — `manual_switch:0`). `duration_s`
   only valid with `action=on`; clamp 1..=3600 (floodlight) / 1..=300
   (siren — a shorter hard cap for the annoyance-critical actuator).
   `brightness` clamped 1..=100.
6. Execute the mapped command **synchronously** via `client.rs`; the mapped
   Reolink calls are: floodlight on → `SetWhiteLed{state:1, mode:manual-on,
   bright}`; floodlight off → `SetWhiteLed{state:0, mode:off}`; floodlight
   auto → `SetWhiteLed{mode:auto/night}`; siren on →
   `AudioAlarmPlay{alarm_mode:"manul", manual_switch:1}`; siren off →
   `manual_switch:0`; ir/led/pir → their setters. Errors map per §4.1 —
   the client gets a real result, not an optimistic 200.
7. **Momentary arming:** if `action=on` for floodlight or siren:
   - floodlight with `duration_s` absent → resolve the D4 default (§3.3);
     siren with `duration_s` absent → default **10 s** (env-overridable
     `REOLINK_SIREN_DEFAULT_SECS`; a siren must never default to minutes).
   - **Snapshot-then-act:** read the pre-actuation state (`GetWhiteLed` for
     floodlight; siren's revert is statically `manual_switch:0`) and store it
     as `revert_payload` JSON in a `camera_actuations` row. If the pre-read
     fails, store the static fallback (`{state:0, mode:auto}` for
     floodlight). See §4.4 for why snapshot-restore replaces the neolink
     plan's plain-`off` revert.
   - Arm the in-process revert timer. If an un-reverted row already exists
     for (camera, actuator), supersede it (mark reverted, note "superseded")
     so re-tapping extends rather than double-reverts.
8. `action=off` with a pending row = early cancel: execute the off, mark the
   row reverted now. Respond with the confirmed result plus
   `actuation_expires` so the client can render the countdown from server
   truth.

`POST /cameras/:id/reboot` — `AdminUser` extractor (the existing
403-on-non-admin wrapper in `auth_mw.rs`), because a reboot interrupts
recording. Same bound-camera checks; calls `Reboot`; no journal row.

`POST /cameras/:id/reolink/detect` — `AdminUser`; runs §4.2 detection on
demand; returns the detected caps + model/firmware from `GetDevInfo`.

### 4.4 `revert.rs`: server-side TTL revert engine (ported; one semantic change)

The "closed laptop must not leave the floodlight on all night" invariant,
unchanged in structure from the neolink plan:

- **Arm-on-success:** tokio timer per pending actuation, armed only after the
  actuating HTTP call succeeded (stronger than the old arm-on-publish); on
  expiry, replay `revert_payload` via `client.rs` and set `reverted_at`.
- **Boot sweep:** at api start, scan `camera_actuations WHERE reverted_at IS
  NULL`: expired rows get the revert executed immediately; future rows get
  timers re-armed. An api restart can never strand an actuator.
- **Periodic safety sweep** every 30 s over the same partial index, catching
  lost timers and reverts whose HTTP call failed. Idempotent: replaying a
  `SetWhiteLed` restore or a `manual_switch:0` twice is harmless.
- **Camera unreachable at expiry:** the row stays un-reverted; the sweep
  retries; if a revert stays owed past a 60 s grace window, raise a
  `reolink_revert_failed` system alert (existing `system_alert_rules`
  machinery in `alerts.rs`) naming the camera and actuator. Prefer noisy
  failure over a silently stuck floodlight.

**Semantic change vs the neolink plan — snapshot-restore instead of plain
`off` (flagged for the maintainer, recommended):** the neolink revert payload
was the literal string `off` because the spike showed neolink's `off`
*restores the camera's auto mode*. The HTTP API has no such magic:
`SetWhiteLed` is an absolute setter, and `{state:0, mode:off}` would force a
night-auto camera dark — the revert would *break* the operator's standing
config. The old DECISIONS text rejected "read-then-restore" as racy and
model-dependent, but that rejection was reasoned inside neolink's toggle
semantics; under an absolute-setter API, restoring the snapshotted
`GetWhiteLed` object is the only revert that provably returns the camera to
its prior behavior. Race window (operator changes the mode in the Reolink app
mid-TTL and the revert stomps it) is accepted and documented; the static
`mode:auto` fallback covers a failed pre-read. Siren needs no snapshot: its
resting state is always off.

Unit tests target the pure decision logic (due-row selection, supersede,
clamps); integration tests exercise journal arm/sweep against Postgres, with
the HTTP execution mocked through a small transport trait on the client (the
same seam the neolink plan used for its publish handle) — no new dev-deps.

### 4.5 `poll.rs`: confirmed-state poller (replaces the MQTT status subscriber)

A single lightweight tokio task (spawned from `main.rs` beside the other
background loops), which:

- Every **60 s**, lists Reolink-bound cameras (reusing the existing
  camera-map reload pattern) and, for each, calls `GetWhiteLed` (only when
  the `floodlight` cap is cached); upserts `reolink_camera_status`
  (`reachable`, `floodlight_state`). Failures mark `reachable=false`; a
  camera that stays unreachable does not spam — back off per camera to 5 min.
- Refreshes `reolink_caps` per §4.2(c) when stale.
- **Write-through:** the §4.3 handler and the revert engine also upsert
  `reolink_camera_status` after every successful command, so /status
  reflects an actuation within one client poll without waiting for the next
  poller pass.
- **Zero cameras bound → the task finds an empty list and sleeps.** No
  connections, no log noise, no config. (This is the whole "supervisor"
  story now; the neolink plan's version-bump reconnect loop has no successor
  because there is no connection to manage.)

No system alert for "integration down" exists anymore as a global concept —
per-camera unreachability surfaces via `reachable=false` in `/status` (and
the existing camera-offline signals cover the camera actually being gone).
`reolink_revert_failed` (§4.4) is the one new alert rule.

---

## 5. RBAC: `actuators` capability (ported UNCHANGED from the neolink plan)

Sounding a siren or lighting a floodlight is a physical-world action, distinct
from "can view" and from PTZ. All mirroring the `ptz` capability:

- `Capabilities` (`services/common/src/types.rs`, `ptz` is at ~889): add
  `#[serde(default)] pub actuators: bool`. Serde-default false = every stored
  role jsonb reads as denied until an admin opts in.
- `Capabilities::all()`: `actuators: true` (admin implies it).
- `auth_mw.rs`: `can_actuators()` (admin || capability) + `require_actuators()`
  returning the standard 403 (clone `can_ptz`/`require_ptz` at ~145/~181);
  keep the explicit `actuators: false` in the literal `Capabilities { .. }`
  constructions.
- Role editor in `admin.html`: one checkbox next to PTZ.
- Per-camera scoping rides the existing `assert_camera_access` grant check;
  no new mechanism.

---

## 6. Status surface (ported; field renames only)

No WebSocket/SSE exists; clients poll `GET /status`. Extend
`CameraStatusEntry` (`services/api/src/dto.rs`) with optional,
`#[serde(skip_serializing_if = "Option::is_none")]` fields so older clients
ignore them and non-Reolink cameras emit nothing:

```rust
pub reolink_reachable: Option<bool>,          // Some(..) only when Reolink-bound
pub floodlight_state:  Option<Value>,         // last confirmed WhiteLed {state,mode,bright}
pub actuation_expires: Option<DateTime<Utc>>, // pending momentary revert, drives countdown UI
```

`status.rs` batch-loads `reolink_camera_status` plus the pending-actuation
rows once (two queries, joined in memory by camera_id), never per-camera
inside the existing `JoinSet` fan-out. `actuation_expires` lets clients render
the countdown ring from server truth instead of a local timer that drifts or
dies with the tab.

---

## 7. Clients (COMPONENT-MAP section 3: parity stated explicitly)

**Web admin + desktop first. Android + iOS are DEFERRED follow-ups, not
dropped**; tracked as Phase 5 tasks and in the cross-client parity table so
the gap stays visible. Clients are transport-agnostic — they see the same
endpoint + `/status` fields the neolink plan promised, so the client sections
port nearly verbatim.

### 7.1 Web admin (`services/api/src/admin.html`)

One file, inline script, `on*=` wired plain functions, `esc()` for all
interpolation, `api()` for authed fetches, semantic colors
`var(--ok)`/`var(--warn)`/`var(--danger)`; sanity-check with `node --check`
on the extracted script block; rebuild the api to see changes
(`include_str!`-embedded; `grep -a`).

- **Camera editor: "Reolink control" section** (replaces the old plan's
  Integrations→Neolink page — there is no service-level config to host):
  host, user, write-only password (never echoed), a "copy from ONVIF" prefill
  button, and a **"Detect capabilities"** button that calls
  `/cameras/:id/reolink/detect` and renders the detected caps as read-only
  badges plus the model/firmware from `GetDevInfo`. The siren badge carries
  the D3 "model/firmware-flaky" hint. No checkboxes: caps are detected, not
  declared.
- **D4 knob** — the "Floodlight auto-revert default (seconds)" field (empty =
  inherit the env default; live per-use resolve per §3.3) lives on the same
  settings panel as the scrub-preview tunables, since there is no
  integration page for it to live on.
- **Live tile overlay buttons** drawn from cached `reolink_caps` ×
  `caps.actuators`: floodlight tap = on for the server-resolved default
  (client omits `duration_s`) + countdown from `actuation_expires`, tap again
  = revert now; optional brightness slider on long-press (polish, may defer);
  siren press-and-hold ~600 ms to arm (accidental-tap guard) + explicit
  off button while sounding; LED/PIR/IR plain toggles. No caps, older server,
  or 404 → no buttons, graceful degrade.

### 7.2 Desktop (`apps/desktop/src/app.js`)

Extend the existing PTZ control-tile pattern (`buildPtzPanelHtml` /
`wirePtzPanel`, gating as with `caps.ptz`): an actuator cluster in the pane
toolbar, gated on `caps.actuators` AND the camera reporting `reolink_caps`,
same interactions as web. True on-video mpv ASS-overlay buttons (like the PTZ
wheel) are polish, deferred; the toolbar cluster ships first. Windows note
stands: rebuild the exe (Tauri bakes ../src in) and keep `libmpv-2.dll`
beside it.

### 7.3 Android (`apps/android`) + iOS/macOS (`apps/ios`): deferred

Actuator bar beside the existing PTZ composables/views + an `actuator()` API
client method + the `/status` fields. Explicitly listed in Phase 5 and in the
COMPONENT-MAP parity row so no session "forgets" them.

---

## 8. Deployment + install surface (golden rule 5) — the big win

Compared with the neolink plan, the operator-facing surface nearly vanishes:

| Surface | neolink plan | This plan |
|---|---|---|
| `docker-compose.yml` | +2 services, profile, entrypoint wrapper | **no change** |
| Secrets | `NEOLINK_MQTT_PASSWORD` generated by setup-env | **no new secret** |
| Config files | `neolink.toml` + example + .gitignore entry | **none** |
| `.env` keys | `NEOLINK_MQTT_*` block | two optional commented defaults: `REOLINK_FLOODLIGHT_REVERT_SECS=30`, `REOLINK_SIREN_DEFAULT_SECS=10` |
| Enablement | broker up + toml authored + Integrations page + per-camera name | **per-camera binding in the camera editor. That's it.** |

Concretely, the same-change sweep (golden rule 5) is docs-only:

- `scripts/setup-env.sh` + `.env.example`: the two commented `REOLINK_*`
  defaults (no generation, nothing secret).
- `docs/AI-INSTALL.md`: a short optional-integration note ("Reolink actuator
  control needs no install step; bind cameras in the admin camera editor")
  with a Verify. No compose, TLS, or backup implications.
- README manual path: one feature-list line.
- `docs-site/docs/integrations/reolink.md` (NEW, operator-facing, replaces
  the planned neolink page): what it does, how to bind a camera, the caps
  auto-detection, the siren flakiness caveat with the HA issue links, the
  HTTPS-first/HTTP-fallback + self-signed-cert LAN-only note, battery-cam
  out-of-scope note.
- `docs-site/docs/configuration/environment-reference.md`: the two
  `REOLINK_*` keys.

No `docs/COMPOSE.md` change (nothing in compose changes).

---

## 9. Testing + CI notes for implementers

Gate before any push (unchanged, every task below): `cargo fmt --all --
--check`, `cargo clippy --all-targets -- -D warnings`,
`cargo test --workspace` against a throwaway Postgres (`crumb-test-pg` recipe
in AGENTS.md).

**DB-test harness trap (cost issue #9 three CI rounds; do not rediscover):**
integration tests must `run_migrations` against the real `public` schema and
isolate by unique keys (unique camera names/uuids per test), NOT by a
`search_path` schema; and the test pool needs `max_size >= 8` or concurrent
tests deadlock on connection starvation.

Specific test obligations:

- Migration 0047 registered-and-applies rides the existing migration test;
  assert `v_camera_effective_policy` exposes the `c_reolink_*` columns.
- Client pure functions: command-body construction (exact JSON incl.
  `"manul"`), envelope parsing, rspCode mapping (`-9` → not-supported +
  cap-prune, auth → retry-once), token-expiry refresh decision. No network.
- Revert engine: due-row selection, supersede, clamps, snapshot-vs-fallback
  payload choice; an integration test that inserts an expired un-reverted row
  and asserts the boot sweep executes it (transport mocked via the client
  trait).
- Capability: `require_actuators` denied for a default role, allowed for
  admin and an opted-in role; endpoint 403/404/400/409 matrix incl. the
  not-bound 404 and the `-9` prune path.
- Serde: `CameraStatusEntry` omits the Reolink fields when None (byte-level
  JSON assertion), old-client compatibility proof.
- **Hardware verification (not CI):** run the floodlight on/revert cycle and
  capability detection against the #26 spike CX410 before calling Phase 2
  done; record the observed `GetAbility` keys in the PR.

---

## 10. COMPONENT-MAP propagation walk (golden rule 8)

Rows that fire, each updated or satisfied in the change that triggers it:

- **A (new endpoint/DTO):** `/cameras/:id/actuator`, `/cameras/:id/reboot`,
  `/cameras/:id/reolink/detect`, camera DTO `reolink_*` fields,
  `CameraStatusEntry` fields.
- **B (new setting/env):** `server_settings.reolink_floodlight_revert_secs`
  admin knob + `REOLINK_FLOODLIGHT_REVERT_SECS` / `REOLINK_SIREN_DEFAULT_SECS`
  env defaults; env-reference docs page.
- **C (new migration):** 0047 + MIGRATIONS registration.
- **E (new camera capability):** actuators join PTZ/imaging in the camera
  editor + per-camera caps (auto-detected).
- **G (RBAC change):** new capability, role editor, deny-by-default.
- **H (admin console):** camera-editor section, settings-panel knob,
  live-tile buttons.
- **I (install/docs):** §8 sweep list (docs-only; no compose/secret rows).
- **L (user-visible capability):** announce path (README feature list,
  docs-site, release notes).
- **M (decision):** §11 entry.
- **Section 3 (cross-client parity):** add an "Actuators (Reolink)" row: web
  admin SHIPPED, desktop SHIPPED, Android DEFERRED, iOS/macOS DEFERRED.

`docs/COMPONENT-MAP.md` itself gains the new surface (the
`services/api/src/reolink/` device-HTTP client seam) in §1.3. The neolink
sidecar surface is never added (it never shipped).

## 11. Required DECISIONS.md entry (write in the Phase 1 change) — FINALIZED

> **Title:** Reolink actuator control via a direct in-process HTTP-API client
> (not a neolink-MQTT sidecar).
>
> **Chosen:** A small `services/api/src/reolink/` module using `reqwest`
> (already in-tree) that logs in for a token and POSTs the documented Reolink
> CGI commands (`AudioAlarmPlay` siren with a real on AND off, `SetWhiteLed`
> floodlight with real mode/brightness, `SetIrLights`, `SetPowerLed`,
> `SetPirInfo`, `Reboot`), with **per-model capability auto-detection from
> `GetAbility`** cached per camera (replacing operator-declared caps).
> Mirrors `ptz.rs` (authed device HTTP, per-camera DB creds) and `frigate.rs`
> (reqwest client). Dedicated `reolink_*` camera columns (not `onvif_*`
> reuse: ports/schemes differ and the features must stay orthogonal). Reuses
> the prior plan's `actuators` RBAC capability, the `camera_actuations`
> TTL-revert journal + boot/periodic sweep (closed-laptop invariant), the
> `server_settings` floodlight-revert live knob (D4, #39/#31 precedent), and
> the `/status` surface. Revert is snapshot-restore of the pre-actuation
> `GetWhiteLed` state (the HTTP API's setters are absolute; neolink's
> off-restores-auto semantics do not exist here). HTTPS-first with HTTP
> fallback and self-signed-cert acceptance, LAN-only, same posture as ONVIF
> today. Siren ships capability-gated with a documented model/firmware-flaky
> caveat (HA core #91517, #98594, #159989).
>
> **Rejected:**
> - **neolink container over MQTT (the prior #25/PR #44 plan,
>   `docs/NEOLINK-ACTUATOR-PLAN.md`).** Required two extra containers **and a
>   dedicated MQTT broker** solely to isolate neolink's **retained
>   `neolink/config` credential leak** (spike-verified: it publishes camera
>   user+password to a retained topic any subscriber can read). Its siren has
>   no off-signal by design and was a **no-op on a siren-equipped CX410** in
>   the #26 spike. Its floodlight is on/off-only vs the HTTP API's full mode
>   set. It tracks a fast-moving reverse-engineered Baichuan-protocol binary
>   pinned at v0.6.2. The entire D1/D2 broker-isolation apparatus existed only
>   to paper over the bus's credential exposure; the HTTP API removes the
>   exposure outright and needs zero new processes.
> - **neolink-as-a-crate (binary Baichuan port-9000 protocol in-process).**
>   Rejected earlier for its huge dependency tree incl. gstreamer tracking a
>   fast-moving RE project (golden rule 6). **Note:** that earlier rejection
>   was of the **binary port-9000 protocol crate, NOT the documented Reolink
>   HTTP API** — the HTTP API was never weighed until
>   `docs/REOLINK-CONTROL-ARCH-DECISION.md`, which is why #25 initially
>   reached for the sidecar.
> - **Home Assistant as the control plane** — mandatory third service; a
>   self-hosted VMS should not depend on another platform for a first-party
>   feature.
> - **Client-side revert timers** — closed laptop = light on all night; the
>   TTL must live on the same side as the engine enforcing it.
> - **Plain-`off` revert payload** (the neolink plan's approach) — valid only
>   under neolink's off-restores-auto toggle semantics; under the HTTP API's
>   absolute setters it would force night-auto cameras dark, so
>   snapshot-restore replaces it (with a static mode-auto fallback when the
>   pre-read fails).
>
> **Revisit triggers:** a battery/Baichuan-only Reolink (no ONVIF/RTSP/HTTP)
> use case appears with real demand (would reopen neolink-as-source, still
> parked); Reolink deprecates or auth-gates the CGI API in a firmware line
> Crumb targets; `reolink_aio`'s issue corpus shows a model class where the
> light-class actuators (not just siren) are broadly unsupported; clients
> need push (WebSocket/SSE) rather than `/status` polling for confirmed
> state; a second, unrelated need for an MQTT control bus emerges in Crumb;
> reliable model/actuator detection confidence plus UX work unlocks the
> camera-add "enable floodlight/siren control?" proactive nudge (deferred
> fast-follow, §12).

---

## 12. Setup gating & zero-footprint for non-Reolink installs

Even simpler than the neolink plan's three layers, because there is no
service at all — the feature is structurally identical to ONVIF PTZ:

1. **Nothing to run.** No compose service, no broker, no image, no port, no
   secret. A default install is byte-identical with or without this feature.
2. **Backend dormant unless a camera is bound.** No camera has a
   `reolink_host`, so the §4.5 poller finds an empty list and sleeps, the
   token cache is empty, and no HTTP client ever fires. The api boots
   identically.
3. **UI gated.** Live-tile actuator buttons render only when a camera has
   cached `reolink_caps` AND the user holds the `actuators` capability
   (deny-by-default). The camera editor's "Reolink control" section is just
   another collapsed optional block, like ONVIF.

**It is a post-setup OPTIONAL binding, not part of the base install or the
first-run wizard.** The wizard does not mention Reolink. An operator who has
Reolinks opens the camera editor, fills in host + credentials (or clicks
"copy from ONVIF"), hits "Detect capabilities", and gets exactly the buttons
the camera supports.

**v1 is manual opt-in.** The proactive camera-add nudge ("this looks like a
Reolink — enable floodlight/siren control?") stays a **FAST-FOLLOW, not v1** —
but note it got materially easier under this architecture: `GetAbility` +
`GetDevInfo` give a *reliable* probe (the blocker under neolink was precisely
that caps were guesswork), so the fast-follow is now mostly UX, not
detection. Recorded as a revisit trigger in §11.

---

## 13. Phased task breakdown

Every Rust task ends green on the full gate (`cargo fmt --all -- --check`,
`cargo clippy --all-targets -- -D warnings`, `cargo test --workspace` against
the throwaway Postgres) and observes the §9 db-test-harness rules (real
`public` schema + unique-key isolation, NOT search_path schemas; pool
`max_size >= 8`). Model tags: Sonnet unless flagged. Phase 1 lands before
anything depending on it.

Gone vs the neolink plan: old T2 (`neolink_config` singleton), T4 (MQTT
client + supervisor), T11 (compose + broker + secrets), and the Integrations
page half of T8. New: the client/caps tasks T3/T4.

### Phase 1: schema + capability foundation

**T1. Migration 0047 + Camera plumbing** (Sonnet, M)
Files: `db/migrations/0047_reolink_actuators.sql` (the five `cameras`
columns, `camera_actuations`, `reolink_camera_status`, the
`server_settings.reolink_floodlight_revert_secs` D4 column, the
`CREATE OR REPLACE VIEW` tail-append), `services/common/src/db.rs`
(MIGRATIONS array + row mapping + camera update), `services/common/src/types.rs`
(Camera fields), `services/api/src/config_routes.rs` + `dto.rs` (camera DTOs:
host/user/password writable with onvif_*-style partial-update + write-only
password; caps read-only).
Accept: migration applies on fresh + existing DB; view exposes the
`c_reolink_*` columns at the tail; `PUT /config/cameras/{id}` round-trips
host/user/password; omitted fields untouched; password never echoed;
`reolink_caps` not writable via the DTO.

**T2. `actuators` RBAC capability** (Sonnet, S)
Files: `services/common/src/types.rs` (Capabilities + all()),
`services/api/src/auth_mw.rs` (`can_actuators`/`require_actuators` + the
literal constructions), `services/api/src/admin.html` (role-editor checkbox).
Accept: stored roles without the key deserialize to false; admin true; role
editor persists it; `node --check` passes on the extracted script.

### Phase 2: the Reolink HTTP client + endpoints

**T3. `reolink/client.rs`: HTTP client, auth/token cache, command set,
error mapping** (Sonnet, L; **[OPUS] review pass on credential/token
handling + the auth-retry/backoff logic** — this is the security-sensitive
core: creds in memory, token redaction in logs, lockout avoidance)
Files: `services/api/src/reolink/{mod,client}.rs`, `state.rs` (token/scheme
caches on AppState).
Accept: pure-function tests for every command body (exact JSON incl.
`"manul"`) and the envelope/rspCode parser; HTTPS→HTTP fallback and scheme
caching proven with the transport trait; token refresh before lease expiry;
auth failure → single re-login retry → backoff (no hot-loop); `-9` maps to
the not-supported error; no credential or `?token=` value ever logged.

**T4. `reolink/caps.rs`: GetAbility capability detection + cache +
`/cameras/:id/reolink/detect`** (Sonnet, M)
Files: `services/api/src/reolink/{caps,routes}.rs`, `db.rs` (caps upsert).
Accept: ability→cap mapping lifted from `reolink_aio` and unit-tested against
recorded `GetAbility` fixtures; bind-time detection best-effort (failure
doesn't block camera save); detect endpoint AdminUser-gated, returns caps +
model/firmware; cache prune on `-9` verified. **Hardware check:** run detect
against the spike CX410 and record the observed ability keys in the PR.

**T5. Actuator + reboot endpoints** (Sonnet, M)
Files: `services/api/src/reolink/routes.rs`, `main.rs` (merge routes),
`dto.rs`.
Accept: full 403/404/400/409 matrix from §4.3 (capability, camera grant,
not-bound, missing cap, bad action, clamps incl. the siren 1..=300 cap and
brightness 1..=100); floodlight `on` with no `duration_s` resolves the D4
default (T5a), siren defaults to `REOLINK_SIREN_DEFAULT_SECS`; synchronous
error propagation (a failed camera call is not a 200); reboot requires
AdminUser.

**T5a. D4 floodlight-revert default: `server_settings` resolver + setter**
(Sonnet, S)
Files: `services/api/src/reolink/settings.rs` (resolver cloning
`scrub_settings.rs::resolve`: nullable DB column over the
`REOLINK_FLOODLIGHT_REVERT_SECS` env default, clamp 1..=3600),
`services/common/src/db.rs` (setter), `services/api/src/config.rs` (env
defaults incl. `REOLINK_SIREN_DEFAULT_SECS`), `services/api/src/config_routes.rs`
(field beside the scrub-preview tunables).
Accept: NULL resolves to env; set value wins and is re-clamped; null via the
API resets to NULL→env; resolve is per-call (no ApiConfig snapshot), proven
by a unit test on the pure merge.

**T6. TTL revert engine + boot/periodic sweep** (Sonnet, L; **[OPUS] review
pass on the failure-mode matrix** — this is the physical-world-safety core)
Files: `services/api/src/reolink/revert.rs`, `db.rs` (journal accessors),
`alerts.rs` (`reolink_revert_failed`).
Accept: §9 revert tests green; snapshot-then-act stores the `GetWhiteLed`
state (static fallback on pre-read failure); kill-the-api-mid-TTL reverts on
next boot; camera-unreachable revert retries then alerts within the grace
window; supersede + early-cancel semantics proven; sweep idempotent.

### Phase 3: status

**T7. Confirmed-state poller + `/status` join** (Sonnet, M)
Files: `services/api/src/reolink/poll.rs`, `main.rs` (spawn),
`status.rs`, `dto.rs`.
Accept: fields absent (not null) for non-Reolink cameras, older payload shape
unchanged; two batch queries, no per-camera N+1; write-through after a
successful actuation; zero bound cameras = idle task, no HTTP, no log noise;
per-camera backoff on unreachable; `actuation_expires` reflects the pending
journal row.

### Phase 4: clients (web + desktop)

**T8. Web admin: camera-editor Reolink section + D4 knob** (Sonnet, M)
Files: `services/api/src/admin.html`.
Accept: host/user/write-only password + "copy from ONVIF" prefill + "Detect
capabilities" button rendering cap badges + model/firmware; siren badge
carries the D3 flaky hint; D4 field on the settings panel (empty = inherit
env); `esc()` on all interpolations; `node --check` green; api rebuilt to
verify.

**T9. Web admin: live-tile actuator buttons** (Sonnet, M)
Files: `services/api/src/admin.html`.
Accept: buttons drawn only from cached `reolink_caps` AND `caps.actuators`;
floodlight countdown driven by `actuation_expires`; tap-again cancels; siren
press-hold 600 ms guard + explicit off while sounding; no-caps/older-server
degrade renders nothing.

**T10. Desktop: actuator cluster on the PTZ tile pattern** (Sonnet, M)
Files: `apps/desktop/src/app.js` (+ rebuild: Tauri bakes ../src into the exe;
rebuild + relaunch + CDP-verify before claiming done; `libmpv-2.dll` beside
the exe).
Accept: same interaction matrix as T9; gated on `caps.actuators`; verified
live against a dev server via CDP.

### Phase 5: docs + governance (+ deferred mobile)

**T11. Docs sweep** (Sonnet, S — was M; no compose/broker/secret content)
Files: `docs/AI-INSTALL.md` (short optional note + Verify), README feature
line, `scripts/setup-env.sh` + `.env.example` (two commented `REOLINK_*`
defaults), `docs-site/docs/integrations/reolink.md` (new, operator-facing:
binding, auto-detection, siren caveat + HA issue links, HTTPS/self-signed
LAN-only note, battery-cam scope note),
`docs-site/docs/configuration/environment-reference.md`.
Accept: AI-INSTALL Verify present; docs-site page is operator-language; env
reference lists both `REOLINK_*` keys; no compose docs touched.

**T12. COMPONENT-MAP + DECISIONS entries** (Sonnet, S; ideally folded into
the Phase 1 change rather than trailing, per golden rules 7/8)
Files: `docs/COMPONENT-MAP.md`, `docs/DECISIONS.md`.
Accept: §10 rows + parity row present; §11 entry verbatim in spirit
(including the binary-Baichuan-vs-HTTP-API clarification and the
snapshot-restore revert rejection note).

**T13. Android actuator bar** (Sonnet, L, DEFERRED): Compose actuator row by
the PTZ controls, `actuator()` API method, `/status` fields; build on dev1,
verify via wireless ADB. **T14. iOS/macOS** (Sonnet, L, DEFERRED): SwiftUI
equivalent in `apps/ios/Crumb/` (NOT apps/desktop), build on macmini.

Effort: backend 3-5 focused days (Phases 1-3; roughly one day lighter than
the neolink plan — no MQTT client, no supervisor, no broker), web + desktop
3-4, docs half a day, mobile 2-3 each when scheduled.

---

## 14. Deltas + open points for the maintainer

Everything above is implementable as written; two design nuances made inside
this plan (consistent with the ratified direction, flagged for visibility):

1. **Snapshot-restore revert (§4.4)** replaces the neolink plan's plain-`off`
   revert payload, because `SetWhiteLed` is absolute and plain-off would
   force night-auto cameras dark. Accepted race (operator edits mode in the
   Reolink app mid-TTL) is documented; static mode-auto fallback covers a
   failed pre-read.
2. **Siren gets its own short default TTL** (`REOLINK_SIREN_DEFAULT_SECS`,
   default 10 s, hard clamp 300 s) separate from the D4 floodlight knob — a
   siren inheriting a 30 s+ floodlight default felt wrong, and manual-mode +
   server revert avoids the camera-side-duration trap (HA #159989). The env
   default is deliberately not a `server_settings` knob in v1 (YAGNI; add it
   the first time an operator asks).
