# Reolink actuator control: neolink-MQTT sidecar vs direct Reolink HTTP-API client

Status: **RESEARCH-BACKED ARCHITECTURE DECISION** for issue #25 (Reolink
actuator control). This document re-opens exactly one question that
`docs/NEOLINK-ACTUATOR-PLAN.md` (and PR #44) had treated as settled: **should
#25 drive Reolink actuators through a neolink container over MQTT, or through a
direct, in-process Reolink HTTP-API client** (the approach Home Assistant's
`reolink` integration uses via the `reolink_aio` library)?

The trigger is honest: the #26 hardware spike plus a first read of the prior art
suggest the neolink-MQTT plan reinvented, at higher cost, something the
ecosystem already solves with a plain authed HTTP client, the same shape Crumb
**already uses** for ONVIF PTZ (`services/api/src/ptz.rs`), the Frigate provider
(`services/api/src/detection/frigate.rs`), and go2rtc reconcile. The
DECISIONS-relevant nuance (see §7): the alternative that was previously
"rejected in-process" was **neolink-as-a-crate**, i.e. the reverse-engineered
**binary Baichuan protocol on port 9000** with its gstreamer tree, **not** the
documented Reolink HTTP API. The HTTP API was never actually weighed. This doc
weighs it.

**Bottom line up front: recommend the direct Reolink HTTP-API client.** It
deletes the sidecar container, the dedicated `mosquitto-neolink` broker, and the
entire D1/D2 credential-leak apparatus; it uses a documented, HA-validated API;
and it fits Crumb's existing authed-device-HTTP patterns exactly. The one honest
caveat, siren reliability, is model-dependent under **both** approaches (see
§5), so it is not a differentiator that saves the sidecar.

---

## 1. The two architectures, concretely

### Option N — neolink sidecar over MQTT (the current #25 / PR #44 plan)

```
Crumb api ──MQTT──> mosquitto-neolink ──MQTT──> neolink container ──Baichuan:9000──> Reolink cam
  (rumqttc)          (dedicated broker,           (RE'd binary proto,
                      profiles: [neolink])         pinned v0.6.2)
```

New moving parts on the operator's box: **two extra containers** (`neolink` +
`mosquitto-neolink`), a **dedicated MQTT broker** with generated password, a
supervised rumqttc client + version-bump hot-reload loop, a hand-authored
`neolink.toml` carrying camera creds, and the D1/D2 mitigations for neolink's
retained-credential leak. Control is fire-and-forget over a message bus; state
comes back on retained status topics; a server-side TTL-revert journal exists
partly because MQTT publishes are one-way and the closed-laptop invariant needs
server truth.

### Option H — direct Reolink HTTP-API client (the HA / `reolink_aio` approach)

```
Crumb api ──HTTPS(fallback HTTP)──> Reolink cam  /cgi-bin/api.cgi
  (reqwest, login→token, POST JSON commands)
```

New moving parts: **zero containers, zero brokers.** A small
`services/api/src/reolink/` module with one `reqwest` client (mirroring
`frigate.rs`, which already does `reqwest::Client::builder()` at
`detection/frigate.rs:648`), a login→token step, and request/response DTOs for
the documented commands. Control is a synchronous request/response, so the
handler learns success/failure immediately (no optimistic-then-reconcile dance),
and the TTL-revert engine still exists for the closed-laptop invariant but arms
off a call the server already knows landed.

---

## 2. The documented Reolink HTTP API (tested / cited)

All commands are `POST` to `http://<cam>/cgi-bin/api.cgi?cmd=<Cmd>&token=<tok>`
with a JSON array body. `reolink_aio` (HA's library) and `fwestenberg/reolink`
agree on the shapes below.

**Auth.** `Login` returns a `Token` (`name` + `leaseTime`); the token rides the
query string on every later call. `reolink_aio` tries **HTTPS:443 first, falls
back to HTTP:80**. (Sources: `reolink_aio/api.py`; `fwestenberg/reolink`
`camera_api.py`.)

```json
{"cmd":"Login","action":0,"param":{"User":{"userName":"…","password":"…"}}}
```

**Siren** — `AudioAlarmPlay` (`fwestenberg` `set_siren`, verbatim from code):

```json
{"cmd":"AudioAlarmPlay","action":0,
 "param":{"alarm_mode":"manul","manual_switch":1,"times":2,"channel":0}}
```

`manual_switch:1` = on, `0` = off; `alarm_mode:"times"` plays N cycles then
stops. (`"manul"` is Reolink's own misspelling, keep it.) Officially documented
by Reolink community/support and reproduced in `reolink_aio`.

**Floodlight** — `SetWhiteLed`; **modes** off/auto/onatnight/schedule/adaptive
(+ conditional autoadaptive/scheduleplus), with `state`, `mode`, `bright`,
`ColorTemp`:

```json
{"cmd":"SetWhiteLed","param":{"WhiteLed":{"state":1,"channel":0,"mode":1,"bright":100}}}
```

This is strictly **richer** than neolink's floodlight, which is `on|off` only.
Crumb could expose the real Reolink mode set (e.g. "on at night", "auto",
"schedule", brightness) instead of the two-state toggle the sidecar imposes.

**IR lights** — `SetIrLights` (`{"IrLights":{"channel":0,"state":"Auto"}}`,
also `On`/`Off`). **Status LED** — `SetPowerLed`. **PIR** — `SetPirInfo`.
**Reboot** — `Reboot`. **Capability gating** — `GetAbility` populates an
abilities map; `reolink_aio`'s `supported(channel, cap)` / `api_version(cap)`
decides per-model/per-channel whether each control exists (e.g.
`api_version("GetWhiteLed") > 0`). This gives Crumb a *queryable* capability
source instead of neolink's operator-declared `neolink_caps` guesswork.
(Sources: `reolink_aio/api.py` command/ability tables; `fwestenberg`
`camera_api.py` payloads.)

---

## 3. Comparison

### 3.1 Security (credential exposure, attack surface)

| | Option N (neolink+MQTT) | Option H (HTTP) |
|---|---|---|
| Camera creds at rest | **Leaked**: neolink publishes its full config, incl. camera user+password, to a **retained** `neolink/config` topic (spike-verified on CX410). Any client that can subscribe reads creds forever. | Creds live only in `cameras`/`server_settings` (encrypted-at-rest DB, same as ONVIF creds today). Never on a bus. |
| Mitigations required | D1 dedicated password broker + D2 best-effort retained-scrub-on-connect. D2 is explicitly "does not protect a subscriber connected at republish; neolink re-publishes on restart." | **None.** The leak topic does not exist. |
| New network surface | A new MQTT broker + a new long-lived container speaking a **reverse-engineered** binary protocol to the camera. | One outbound HTTPS client from the api, identical trust model to ONVIF PTZ today. |
| Creds also in | `neolink.toml` (hand-authored, gitignored) **and** the broker password file **and** the retained topic. | DB only. |

Option H is strictly better on security: it removes an at-rest credential leak
that Option N can only *mitigate*, not eliminate, and it adds no broker to
attack. (Sources: spike facts; neolink README `/neolink/config` retained topic;
NEOLINK-ACTUATOR-PLAN §2.)

### 3.2 Footprint / dependencies

| | Option N | Option H |
|---|---|---|
| Containers | +2 (`neolink`, `mosquitto-neolink`), profile-gated | **0** |
| Broker | dedicated mosquitto, generated password, entrypoint wrapper | none |
| Rust deps | rumqttc client + supervisor + version hot-reload | `reqwest` (**already a workspace dep**), `serde` |
| Config artifacts | `neolink.toml` (creds), `.env` `NEOLINK_MQTT_*` block, example TOML, `.gitignore` entry | camera DB columns only |
| Pinned upstream | `quantumentangledandy/neolink:v0.6.2` (must never float to latest) | none |
| Protocol basis | **reverse-engineered** Baichuan port-9000 binary | **documented** HTTP/CGI API |

Option H is the far lighter footprint, and it is what golden rule 6 ("don't add
heavyweight dependencies casually", "new background services need an issue
discussion") points toward. Option N adds a background service *and* a broker.

### 3.3 Capability coverage

| Actuator | Option N (neolink MQTT) | Option H (HTTP API) |
|---|---|---|
| Floodlight | `on\|off` only; `off` restores auto (spike-confirmed) | Full `SetWhiteLed`: off/auto/onatnight/schedule/adaptive + brightness + ColorTemp |
| Siren | `control/siren on` only — **no off signal** in the protocol; **did NOTHING on the spike CX410** (which has a siren) | `AudioAlarmPlay` with explicit on **and** off (`manual_switch 0`) + `times` mode; but model-flaky (see §3.4) |
| Status LED | `led on\|off` | `SetPowerLed` |
| IR | `ir on\|off\|auto` | `SetIrLights` On/Off/Auto |
| PIR | `pir on\|off` | `SetPirInfo` |
| Reboot | `reboot` | `Reboot` |
| Motion/state | retained `status/motion`, `status/floodlight` echoes | polled `GetWhiteLed`/`GetAudioAlarm`/etc., or reuse existing motion pipeline |

Two capability facts favor Option H decisively:

1. **neolink's siren has no "off"** (README: "the message is always 'on' as
   there is no 'off' signal for the siren"). The HTTP API has an explicit off
   (`manual_switch:0`). For a security VMS, "can sound the siren but can't
   silence it from the app" is a real defect.
2. **The spike's neolink siren was a no-op on a siren-equipped CX410.** So
   Option N does not even reliably deliver the one actuator where it looked
   comparable.

Option N's only capability edge is *push* status (retained topics) vs Option H's
*poll*. But Crumb has no WebSocket/SSE anyway, clients already poll `/status`,
so this edge collapses to "poll the camera on the server side," which the api
already does for go2rtc/Frigate.

### 3.4 Reliability & model coverage (the honest part)

Siren over the Reolink **HTTP API is itself model/firmware-flaky**, independent
of neolink:

- **E1 Zoom** — `AudioAlarmPlay` returns `error code 1 … -9/not support`, even
  though the model is on the supported list and the siren works in Reolink's own
  app (HA core issue #91517, unresolved).
- **RLC-510WA** (fw 3.1.0.764) — `AudioAlarmPlay … -17/rcv failed` (HA core
  issue #98594, unresolved).
- **Atlas PT Ultra** — siren started with a duration **can't be turned off**
  until the duration expires; a fix PR was opened then closed (HA core issue
  #159989).

So siren is the residual risk under **either** architecture. This matters for
the decision because siren was the one place the sidecar might have claimed an
advantage, and it does not: neolink's siren failed on the spike hardware, and
the HTTP siren is inconsistent across models. **Floodlight/LED/IR/PIR/reboot,
by contrast, are well-exercised over the HTTP API** (that is what HA users run
daily) and floodlight over neolink was solid in the spike. Neither approach
makes siren universally reliable; both make the light-class actuators reliable.

Net: reliability is **a wash on siren** and **a slight edge to H on
everything else** (documented API, no bus/broker/sidecar links that can each
fail independently, synchronous success/failure instead of fire-and-hope).
(Sources: HA core #91517, #98594, #159989.)

### 3.5 Maintenance

- **Option N** tracks a **fast-moving, one-maintainer reverse-engineering
  project** (neolink is a fork of thirtythreeforty's fork; README: "additional
  features not yet in upstream master"). Crumb must pin `v0.6.2` forever-ish, and
  a Reolink firmware change or a neolink release can break the pin. Two container
  images to watch for CVEs (neolink + mosquitto).
- **Option H** tracks a **documented HTTP API** that Reolink publishes and that
  HA's integration exercises across hundreds of models and firmwares. When a
  model quirk appears, `reolink_aio`'s public issue history is a ready-made
  compatibility oracle Crumb can mine. No image pins, no broker upgrades.

Option H is the lower-maintenance path and the one whose bus-factor risk lives
in a documented spec rather than in a single RE binary.

### 3.6 Crumb-fit

Option H **is** the existing pattern:

- `services/api/src/ptz.rs` already does per-request authed device HTTP (ONVIF
  SOAP over `http://host:port/...`), resolving per-camera creds from DB columns
  with an env fallback. A Reolink client is the same story with a simpler
  transport (JSON POST instead of SOAP).
- `services/api/src/detection/frigate.rs:648` already builds a `reqwest` client
  for an authed device/service. `reqwest` is already in the tree.
- The endpoint mirrors `ptz.rs::ptz_command` line-for-line: `require_actuators()`
  → `assert_camera_access()` → `get_camera` → 404-if-not-Reolink → validate →
  act. The plan's §4.3 handler order is reused wholesale; only the transport
  under it changes from "publish to MQTT" to "POST to the camera."
- Per-camera creds slot into the same DB-columns-win-over-env precedence ONVIF
  already uses (`onvif_host/port/user/password`), so there is a well-worn place
  to store `reolink_host/port/user/password` (or reuse the ONVIF creds when the
  camera is the same device).

Option N, by contrast, introduces Crumb's **first** message-bus control plane,
its **first** dedicated broker, and a hand-authored external config file, none
of which have precedent in the codebase.

---

## 4. RECOMMENDATION

**Build the direct Reolink HTTP-API client (Option H). Drop the neolink sidecar
and the dedicated broker from #25.**

Rationale, ranked:

1. **It eliminates, rather than mitigates, the credential-at-rest leak** that
   forced the entire D1/D2 broker-isolation design. No bus, no retained
   `neolink/config`, no scrub workaround.
2. **Zero new containers, zero broker, uses deps already in the tree**, and is
   the same authed-device-HTTP shape Crumb already ships in `ptz.rs` and
   `frigate.rs`. Golden rule 6 favors it.
3. **Richer, documented, HA-validated capability**: real floodlight modes +
   brightness, a siren with an actual off, `GetAbility`-based per-model gating
   instead of operator-declared guesses.
4. **The sidecar's would-be advantages don't hold**: its siren was a no-op on
   the spike's siren-equipped CX410 and has no off-signal by design; its only
   real edge (push status) is moot because Crumb polls `/status` anyway.
5. **Lower long-term maintenance**: a documented API and HA's issue corpus
   beat pinning a fast-moving reverse-engineered binary plus a broker image.

Honest trade-offs accepted:
- **Siren stays model-flaky** (HA #91517/#98594/#159989). We ship it gated with
  the same "unvalidated / model-dependent" caveat the plan already has (D3),
  and we now have HA's issue trail to set expectations per model.
- We give up neolink's **battery/Baichuan-only camera** reach (cams with no
  ONVIF/RTSP/HTTP). Those cameras also can't be Crumb RTSP sources today, so
  they're out of #25's scope regardless; recorded as a revisit trigger.
- Some very old firmwares expose the HTTP API only over cleartext HTTP:80.
  `reolink_aio` handles this with HTTPS-first-then-HTTP fallback; we mirror that
  and note it's LAN-only traffic (same posture as ONVIF today).

---

## 5. What concretely changes in the #25 plan under each option

### Under Option H (recommended) — what the plan **loses**

Delete from `docs/NEOLINK-ACTUATOR-PLAN.md`:

- **§2 entirely** (broker isolation), and with it **D1** (dedicated
  `mosquitto-neolink`) and **D2** (retained-config scrub) — there is no bus.
- **§4.1 rumqttc client, §4.2 MQTT supervisor** → replaced by a small
  `services/api/src/reolink/client.rs` `reqwest` client + login-token cache
  (clone `frigate.rs`), no version-bump reconnect loop needed for a stateless
  HTTP client.
- **§8.1 compose services** (`neolink`, `mosquitto-neolink`) — gone. No new
  profile, no `docker compose` surface change at all beyond docs.
- **§8.2 secrets**: no `NEOLINK_MQTT_*`, no `neolink.toml`, no broker password.
  Replaced by per-camera `reolink_*` DB columns (or ONVIF-cred reuse) — same
  shape as the existing `onvif_*` columns, populated via the camera editor.
- **§3.2 `neolink_config` singleton** → becomes (optionally) nothing, or a tiny
  `reolink` enable flag; there is no external service to point at.

Keep (near-unchanged) from the plan — this is the load-bearing insight, most of
the plan survives:

- **§3.1 migration 0047** minus the MQTT bits: `camera_actuations` TTL-revert
  journal, the `neolink_camera_status`→`reolink_camera_status` state cache, and
  **D4** (`server_settings.neolink_floodlight_revert_secs` live knob) all still
  apply. Rename `neolink_*` columns to `reolink_*`; `neolink_caps` becomes
  `reolink_caps` (or is derived from `GetAbility`).
- **§4.3 actuator endpoint** handler order — identical; only the publish step
  becomes an HTTP call whose result the handler can check synchronously.
- **§4.4 revert engine** — identical and now *simpler*, since arm-on-success is
  literal (the call returned 200) rather than arm-on-publish-and-hope.
- **§5 `actuators` RBAC capability, §6 `/status` surface, §7 clients** — all
  unchanged; clients don't know or care about the transport.
- **§9 tests, §10 COMPONENT-MAP walk** — unchanged in spirit; drop the
  broker/compose rows, add a "Reolink HTTP client" seam.

Net effect: **Phase 2's T4 (MQTT client) and most of Phase 5's T11 (broker +
compose + secrets) evaporate**; the schema, RBAC, revert engine, status, and
client work is reused almost verbatim. This is a *smaller* build than the
sidecar, not a larger one.

### Under Option N (status quo) — what stays

Everything in `docs/NEOLINK-ACTUATOR-PLAN.md` as written, including the two
extra containers, the dedicated broker, D1, D2, the `neolink.toml` handling, and
the acceptance that the retained-cred leak is *mitigated* not removed and that
siren was unverified/no-op on the spike hardware.

---

## 6. Proposed revised `docs/DECISIONS.md` entry

> **Title:** Reolink actuator control via a direct in-process HTTP-API client
> (not a neolink-MQTT sidecar).
>
> **Chosen:** A small `services/api/src/reolink/` module using `reqwest`
> (already in-tree) that logs in for a token and POSTs the documented Reolink
> CGI commands (`AudioAlarmPlay` siren, `SetWhiteLed` floodlight with real
> mode/brightness, `SetIrLights`, `SetPowerLed`, `SetPirInfo`, `Reboot`), with
> per-model capability gating from `GetAbility`. Mirrors `ptz.rs` (authed device
> HTTP, DB-creds-win-over-env) and `frigate.rs` (reqwest client). Reuses the
> plan's `actuators` RBAC capability, the `camera_actuations` TTL-revert journal
> + boot/periodic sweep (closed-laptop invariant), the `server_settings`
> floodlight-revert live knob (D4), and the `/status` surface. HTTPS-first with
> HTTP fallback, LAN-only, same posture as ONVIF today.
>
> **Rejected:**
> - **neolink container over MQTT (prior #25/PR #44 plan).** Requires two extra
>   containers **and a dedicated MQTT broker** solely to isolate neolink's
>   **retained `neolink/config` credential leak** (spike-verified). Its siren
>   has no off-signal and was a **no-op on a siren-equipped CX410** in the #26
>   spike. It tracks a fast-moving reverse-engineered Baichuan-protocol binary
>   that must be version-pinned. All of D1/D2 exist only to paper over the bus's
>   credential exposure. The HTTP API removes the exposure outright.
> - **neolink-as-a-crate (binary Baichuan port-9000 protocol in-process).**
>   Previously rejected for its huge dependency tree incl. gstreamer against a
>   fast-moving RE project (golden rule 6). *Note:* this earlier rejection was of
>   the **binary protocol crate**, NOT the documented HTTP API — the HTTP API was
>   never weighed until this decision, which is why #25 initially reached for the
>   sidecar.
> - **Home Assistant as the control plane** — mandatory third service; a
>   self-hosted VMS should not depend on another platform for a first-party
>   feature.
>
> **Revisit triggers:** a battery/Baichuan-only Reolink (no ONVIF/RTSP/HTTP)
> use case appears (would reopen neolink-as-source, still parked); Reolink
> deprecates or auth-gates the CGI API in a firmware line Crumb targets;
> `reolink_aio`'s issue corpus shows a model class where the light-actuator
> commands (not just siren) are broadly unsupported; a second, unrelated need
> for an MQTT control bus emerges in Crumb (would re-evaluate a shared bus).

---

## 7. Residual risks (both approaches)

- **Siren is model/firmware-dependent regardless of transport.** Ship it gated
  behind an operator-visible cap with a "may be unsupported on your model"
  note; lean on HA issue history (#91517 E1 Zoom, #98594 RLC-510WA, #159989
  Atlas PT Ultra) to set expectations. Not a reason to prefer the sidecar,
  which failed the same test on the spike CX410.
- **Per-camera / per-model capability gating stays a real task.** Option H can
  *query* it (`GetAbility`), which is better than operator-declared caps, but
  the mapping from ability flags to Crumb's actuator buttons still needs care
  and a graceful "control not supported on this model" degrade.
- **Cleartext-HTTP fallback on old firmware.** LAN-only mitigates it (same as
  ONVIF/PTZ today); document it, don't expose it off-LAN.
- **Token lease expiry / re-login** must be handled (short leases on some
  models); `reolink_aio` re-logs-in on expiry, mirror that.
- **Login rate/lockout**: some firmwares lock an account after rapid failed
  logins; cache the token and back off on auth failure.

---

## 8. Source list & confidence

**Reached and quoted:**
- `reolink_aio/api.py` (HA's library): Login/token, HTTPS-then-HTTP,
  `SetWhiteLed` modes, `AudioAlarmPlay`/`SetAudioAlarm`, `SetIrLights`,
  `SetPowerLed`, `SetPirInfo`, `Reboot`, `GetAbility`/`supported()` gating.
- `fwestenberg/reolink` `camera_api.py`: exact `set_siren` /
  `AudioAlarmPlay` body (`alarm_mode:"manul", manual_switch, times:2,
  channel:0`), `SetWhiteLed` bodies, `Login` body, token-in-query-string,
  `SetIrLights` body.
- neolink `README.md`: reverse-engineered Baichuan port-9000; MQTT control
  topics incl. `control/siren on` ("no off signal"); retained `/neolink/config`
  topic; fork lineage.
- HA core issues #91517 (E1 Zoom `-9/not support`), #98594 (RLC-510WA
  `-17/rcv failed`), #159989 (Atlas PT Ultra can't-turn-off-after-duration).
- Reolink community/support: `AudioAlarmPlay` curl examples (manul/times).
- Crumb repo: `ptz.rs` (ONVIF authed device HTTP, DB-creds precedence),
  `detection/frigate.rs:648` (reqwest client in-tree), NEOLINK-ACTUATOR-PLAN.md.

**Could not reach / limited:**
- The **official Reolink HTTP-API PDF** (loxone mirror) was not fetched
  directly; the CGI command names/params are nonetheless triangulated and
  agree across `reolink_aio`, `fwestenberg`, and Reolink's own support/community
  curl examples, so confidence in the command shapes is **high**.
- The Reolink support page for *manually* triggering the siren documents only
  the app/client UI, **not** curl; the curl form comes from the community/support
  search result and `fwestenberg` code instead. Confidence in the siren body is
  **high** (two independent code sources agree); confidence in siren *behavior
  across models* is deliberately **low/mixed**, which is exactly what §3.4
  reports.

Overall confidence in the recommendation: **high.** The two facts that drive it,
neolink's retained-credential leak and its dead siren on the spike CX410, are
first-hand spike results, and the HTTP API's command set is corroborated by two
independent open-source implementations plus HA's production integration.
