# CrumbVMS Roadmap

This is a living roadmap of "eventually" work for CrumbVMS, the free, open-source (AGPL-3.0-or-later) self-hosted NVR (Rust recorder/API + Tauri/libmpv desktop + Kotlin/Compose Android + go2rtc + optional Frigate). It is not a sprint plan or a commitment; it is the place where larger initiatives are scoped, grounded in the current code, and broken into phases so any future session can pick up an item with full context.

Each headline initiative below is written to be actionable cold: it cites the actual files involved, states where the code is today versus where it's going, and carries a phased checklist with effort tags, explicit dependencies, and the open decisions that are the maintainer's to make. The short backlog at the end is tracked elsewhere and listed here only for completeness.

## Legend, effort sizes

| Tag | Meaning | Rough scale |
|-----|---------|-------------|
| S | Small | Hours to a day; localized change, no new subsystem |
| M | Medium | A few days; one new module or a cross-file change |
| L | Large | A week-plus; new subsystem, schema, or cross-service work |
| XL | Extra large | Multi-week; spans services + clients + ops + verification |

Effort is engineering size, not priority. Decisions for the maintainer are called out per initiative; anything tagged as a legal/business gate is explicitly not an engineering decision.

## Headline initiatives

### 1. Independent notification system (push/alerts, Frigate-independent)

A rules engine living in the always-on API turns motion, detection, and health signals into per-camera, scheduled, cooldown-gated notifications delivered via ntfy / webhook / email plus an in-app channel, with no mandatory cloud and no hard Frigate dependency, it works for any operator running their own server.

#### Where we are today

Alerting is a single hardcoded webhook watchdog. `services/api/src/alerts.rs` (`run_heartbeat_watchdog`) is the only notifier: when `ALERT_WEBHOOK_URL` is set it polls `recorder_heartbeat` every 30s and POSTs a `{content,text}` (Discord/Slack-shaped) payload once on stale (>60s) and once on recovery, via a single `alerted` latch. It is wired in `services/api/src/main.rs:365-374`; the config field `alert_webhook_url` is in `services/api/src/config.rs:122-127`. There are no rules, no per-camera scoping, no history, and no person/disk/camera-offline alerts.

The event sources a real engine needs already exist:

| Signal | Where it lives today |
|--------|----------------------|
| Detection events | `events` table (`db/migrations/0001_initial_schema.sql:89`, productionized by `db/migrations/0007_detection_events.sql`, label/score/zones/snapshot_url/lifecycle, dedup + `events_camera_ts`/`events_camera_label_ts` indexes). Normalized via `crumb_common::detection::NormalizedEvent` + `DetectionLabel`; ingested by `services/api/src/detection_ingester.rs`; provider-agnostic `DetectionSource` trait (`services/common/src/detection.rs:43`), Frigate gated on `FRIGATE_MQTT_URL` (`main.rs:235-287`). |
| Motion | Recorder emits `MotionSignal{camera_id,started_at,stopped_at,peak_score}` (`services/common/src/types.rs:398`) from `motion.rs` (`run_pixel_diff_loop`, START ~1573 / STOP ~1611). Stays in-process, consumed only by `recording.rs`. API infers "motion now" indirectly in `services/api/src/status.rs:130-140` from the last segment's `has_motion` + freshness. |
| Health | `recorder_heartbeat` (alerts.rs + status.rs:167), per-camera staleness (`camera_last_segment`, status.rs:130), storage free/used via statvfs + `storage_used_bytes` (status.rs:79-104). |

Infrastructure that makes this cheap: the API is the always-on component and already has `reqwest` (alerts + snapshot proxy) and `rumqttc` (detection). The recorder also depends on `rumqttc` and runs it as a subscriber in `services/recorder/src/frigate_motion.rs:366-405`. A `mosquitto` broker is already in `docker-compose.yml:160-168` (127.0.0.1:1883, LAN-local). Android already declares `POST_NOTIFICATIONS` (`apps/android/app/src/main/AndroidManifest.xml:6`) but has zero FCM/Firebase/foreground-service/WorkManager/notification code, it polls via Retrofit (`CrumbRepository.status()/events()/activeDetections()` in `apps/android/.../data/CrumbRepository.kt`). The API has no WebSocket support. The per-camera/policy/group/zone model (motion_mask zones, named policies, groups) already exists.

#### Where we are going

Operators get trustworthy, low-noise mobile + desktop notifications for the events that matter, "person at the front door at night", "camera offline", "disk almost full", "recorder down", generated entirely by Crumb (works with the built-in pixel/MOG2 detectors and with detection events, with or without Frigate), self-hostable end to end, and free of any mandatory Google/cloud dependency.

The architecture: put the rules engine + dispatcher in the API (the always-on component that already owns `events`, the health reads, `reqwest`, and `rumqttc`). Generalize the inert `alerts.rs` watchdog into one of several evaluator tasks that all emit a uniform internal `CrumbEvent{kind,camera_id,severity,ts,payload}` onto a tokio mpsc bus. A rules engine filters each event by camera × type × schedule (TZ from `RECORDER_TZ`) × zone (against `events.zones` / motion_mask) × min_score × per-rule cooldown, the cooldown being the primary weapon against the tree/street false-motion nuisance common on outdoor cameras. Matching rules fan out to enabled channels. New DB tables follow the existing idempotent `ensure_*` pattern in `main.rs`, no migration-runner needed.

The hardest constraint is mobile push without mandatory FCM. The clean answer for a distributable self-hosted product is the UnifiedPush/ntfy pattern: Crumb publishes to an ntfy topic and the operator runs their own ntfy server (self-hosted ntfy does not use Firebase). For the first-party Crumb Android app, the lowest-effort reliable path given today's code is a WorkManager periodic poll (or foreground-service + SSE/long-poll) of a new `GET /notifications?since=` that the app renders as local notifications via the already-declared permission, zero Google project, zero cloud. True FCM stays an optional, opt-in "battery-optimal background delivery" channel layered later (it requires a per-distributor Firebase project, which contradicts the no-mandatory-cloud goal, so it must never be the only path).

#### Plan

Phase A, MVP: engine + history + one default channel (L)

- [ ] Add tables via `ensure_*` (idempotent, mirror `main.rs`): `notification_rules` (camera_id NULL=all, event_type, severity, schedule jsonb, zones text[], min_score, cooldown_secs, enabled, per-rule channel set) and `notifications` (history: rule_id, camera_id, event_type, ts, title, body, snapshot_url, dedup_key, per-channel delivery status) (M)
- [ ] Define internal `CrumbEvent{kind,camera_id,severity,ts,payload}` + a tokio mpsc bus in the API (S)
- [ ] Refactor `alerts.rs` heartbeat watchdog into a `recorder_down` evaluator that emits `CrumbEvent` instead of POSTing directly (keep the stale/recovery latch) (S)
- [ ] Add evaluators: detection-event (tap the ingester channel or poll `events`), camera-offline (stateful watchdog over `camera_last_segment` with hysteresis + recovery), disk-threshold (statvfs % high-water from status.rs logic) (M)
- [ ] Rules engine: per-event filter by camera × type × schedule(TZ) × zone × min_score × cooldown; write a `notifications` row; dispatch (M)
- [ ] Dispatchers: generalize the proven `{content,text}` webhook + add an ntfy publisher (HTTP POST to topic; title/priority/click/attach snapshot) (M)
- [ ] Admin console: a Notifications section in `admin.html` to CRUD rules + view recent history (M)
- [ ] Config: `NTFY_BASE_URL`/`NTFY_TOPIC`/`NTFY_TOKEN`, `SMTP_*`; keep `ALERT_WEBHOOK_URL` backward-compatible as a seeded default rule (S)

Phase B, In-app Crumb push (Android, no FCM) (M)

- [ ] `GET /notifications?since=<ts>` (viewer-scoped via `AuthUser.filter_camera_ids`, like `/events`) + optional `GET /notifications/stream` (SSE/long-poll) (M)
- [ ] Android: foreground service OR WorkManager periodic poll → local notification via the declared `POST_NOTIFICATIONS`; tap deep-links to live/playback at the event time (M)
- [ ] Android device/subscriber registry table so the server can target/scope (and later carry an ntfy/UnifiedPush endpoint) (S)
- [ ] Desktop (Tauri): toast on new notification via the same `/notifications` endpoint (S)

Phase C, More channels + richer rules (M)

- [ ] SMTP email dispatcher with snapshot attachment (proxy via the existing `/events/{id}/snapshot`) (M)
- [ ] Pushover + Telegram dispatchers (generic HTTP, thin) (S)
- [ ] Per-rule quiet hours, severity→priority mapping, snooze/ack from the notification, digest/rollup to fight bursts (M)
- [ ] Zone-aware nuisance-suppression presets for the common tree/street outdoor-camera cases (S)

Phase D, Native sub-second motion + optional FCM (M)

- [ ] Recorder publishes `MotionSignal` start/stop to mosquitto (rumqttc already a dep); API subscribes via the `frigate_motion.rs`/`detection_ingester.rs` pattern → motion `CrumbEvent`s independent of segment cadence (M), shares the Phase 2 bus work from initiative 2 (see Cross-cutting)
- [ ] UnifiedPush endpoint registration so a generic distributor (incl. self-hosted ntfy) delivers in background without a foreground service (M)
- [ ] OPTIONAL opt-in FCM channel for battery-optimal background delivery (requires an operator-supplied Firebase project; never the only path) (M)

#### Dependencies

- API service as the engine home: `services/api` (always-on; already has `events` + `reqwest` + `rumqttc`)
- Detection pipeline for person/car triggers: `services/common/src/detection.rs` + `services/api/src/detection_ingester.rs` + the `events` table (migration 0007)
- Health signals: `recorder_heartbeat` + `camera_last_segment` + statvfs in `status.rs` and `alerts.rs`
- Optional broker for native-motion-as-event: mosquitto in `docker-compose.yml` + rumqttc (already in recorder + api)
- Android client: `apps/android` (`POST_NOTIFICATIONS` declared; needs foreground-service/WorkManager + new `/notifications` consumption in `CrumbRepository.kt`)
- Self-hosted ntfy server (operator-run) for the recommended no-FCM mobile path
- TZ for schedules: reuse `RECORDER_TZ`/`America/Los_Angeles` (`services/common/src/config.rs`)

#### Decisions for the maintainer

- Default mobile-push path: ntfy/UnifiedPush (self-hosted, recommended) vs first-party Crumb-app foreground-service poll vs both, decides whether MVP ships an ntfy dependency or stays purely first-party.
- Is true FCM ever in scope? It conflicts with "no mandatory cloud", confirm it stays an optional opt-in channel, never a requirement.
- Run the bundled mosquitto for native-motion-as-event, or keep MVP API-side polling of `events` + health (no broker until sub-second motion alerts are wanted)?
- Default disk high-water threshold (e.g. 90%) and camera-offline grace/hysteresis window before alerting, to avoid flapping.
- Where notification rules live first: server admin console only (fastest, `admin.html`), or also desktop/Android settings.
- Default per-rule cooldown (e.g. 5 min) and whether bursty cameras get digest/rollup by default, the main false-motion-noise control.
- Should rules attach to existing camera GROUPS/POLICIES (reuse that model) or stay per-camera + global?
- Notification retention policy for the new history table (TTL sweep like export jobs?).

### 2. MQTT events for Home Assistant (Frigate-less)

Add an MQTT publisher in the API that mirrors Crumb's own motion / recording / online state onto a broker using Home Assistant MQTT Discovery, so a Crumb deployment with no Frigate auto-creates HA motion / connectivity / recording entities with zero YAML.

#### Where we are today

Crumb has substantial rumqttc plumbing, but it is 100% consumer-side, there is no publish path anywhere (a grep for `client.publish` / `set_last_will` / `homeassistant` / `retain` returns only `Packet::Publish` matches in the consumers). What is directly reusable:

1. API consumer + ingester. `services/api/src/detection/frigate.rs` is a full rumqttc 0.24 `AsyncClient`/`EventLoop` client: ConnAck-driven (re)subscribe, capped exponential reconnect back-off (1s→30s, since 0.24 has no built-in delay), optional `set_credentials`, and `parse_mqtt_url()` (mqtt:// / mqtts:// / bare host, default 1883). `services/api/src/detection_ingester.rs` is a clean `mpsc::Receiver<NormalizedEvent>` upsert loop, the single chokepoint every detection event already flows through, the natural place to also publish. Both wired in `main.rs:235-287` under `#[cfg(feature="detection")]`, runtime-gated on `FrigateConfig::from_env()`.
2. Recorder-side rumqttc + motion state machine. `services/recorder/src/frigate_motion.rs` has its own per-camera client, a duplicate `parse_mqtt_url()`, and a pure unit-tested `CameraTracker`/`Transition::{Start,Stop}`. The true origin of motion is `motion.rs` emitting `MotionSignal` (`services/common/src/types.rs:399`) over an mpsc to `recording.rs` (consumed recording.rs:112-116). The signal's own doc says it is deliberately source-agnostic.
3. Config conventions. `FrigateConfig`/`FrigateMotionConfig::from_env()` show the exact URL-gate + prefix-default + user + password-or-`_B64` pattern to copy (`base64` already a dep in both crates).
4. Online/offline + recording state are already DERIVED, not event-sourced. `status.rs:130-140` computes per-camera `recording` (last segment age ≤ `HEALTH_STALENESS_SECS=15`) and `recent_motion` (`has_motion` && age ≤ `MOTION_FRESHNESS_SECS=12`), plus the heartbeat (status.rs:167). So "is this camera recording/online" is computable in the API from existing data, no new recorder plumbing.
5. Infra is ready. `docker-compose.yml:160-168` ships `eclipse-mosquitto:2` (127.0.0.1:1883, TZ America/Los_Angeles); the API has the `FRIGATE_MQTT_*` env block (lines 132-139); `rumqttc`/`bytes`/`async-trait` are present (`services/api/Cargo.toml:17-25`). There is no internal event-bus yet (only admin.html toast CSS), greenfield for the fan-out bus.

#### Where we are going

A Frigate-less Crumb is a first-class Home Assistant citizen out of the box. Per camera it publishes motion ON/OFF (`binary_sensor`, device_class=motion), recording ON/OFF (device_class=running), and online/offline (device_class=connectivity), plus one Crumb-bridge availability sensor, all via HA MQTT Discovery so HA auto-creates entities grouped under one device per camera. Snapshots (camera/image entity) are a stretch goal. The whole thing is toggle-able and additive: disabled by default (nothing changes), and when enabled it coexists with the existing Frigate consumer on the same or a different broker.

The publisher belongs in the API, not the recorder: the API already owns the long-lived broker pattern and the ingester chokepoint, already derives recording/online state + heartbeat, and one API process = one MQTT client + one LWT (exactly the HA availability model). The recorder is the single-writer hot path (advisory-locked, mem-capped, co-located with NVDEC) and we deliberately keep MQTT back-off/CPU off it. New module: `services/api/src/mqtt/` with a `CrumbMqttConfig::from_env()` (new `CRUMB_MQTT_*` vars, do not overload `FRIGATE_MQTT_*`, since publish and consume are independent roles and a Frigate-less user has no Frigate broker), a publisher task built on the shared connect/back-off skeleton, and a state-projector. Design the projector to read from a `broadcast`/NOTIFY source, not bake in MQTT-only, so the notification system (initiative 1) consumes the same internal motion/recording bus.

#### Plan

Phase 0, Shared MQTT plumbing + config (S)

- [ ] Factor `parse_mqtt_url` + the AsyncClient connect/ConnAck/back-off skeleton out of `detection/frigate.rs` and `recorder/frigate_motion.rs` into a shared `crumb_common::mqtt` helper (removes existing duplication, gives the publisher a tested base) (S)
- [ ] Add `CrumbMqttConfig::from_env()`: `CRUMB_MQTT_URL` (gate; default `mqtt://mosquitto:1883`), `CRUMB_MQTT_PREFIX` (default `crumb`), `CRUMB_MQTT_USER`, `CRUMB_MQTT_PASSWORD(_B64)`, `CRUMB_DISCOVERY_PREFIX` (default `homeassistant`), `CRUMB_MQTT_ENABLE`, copy the password/`_B64` pattern verbatim (S)
- [ ] Add the `CRUMB_MQTT_*` block to the api environment in `docker-compose.yml` (next to `FRIGATE_MQTT_*`) + `.env` docs (S)

Phase 1, Publisher task + HA Discovery (motion via status-poll) (M)

- [ ] New `services/api/src/mqtt/` module: long-lived publisher on the shared skeleton; `set_last_will` on `crumb/bridge/availability=offline` (retained), publish online on ConnAck (M)
- [ ] Discovery emitter: per camera publish RETAINED config to `homeassistant/binary_sensor/crumb_<id>_{motion,recording,connectivity}/config` with unique_id, state_topic, `device{identifiers,name,manufacturer:CrumbVMS,model}`, device_class, `availability[]`; build a topic-safe camera slug (M)
- [ ] State projector v1: internal tick reusing status.rs's recording/recent_motion derivation, diff per camera, publish ON/OFF edges to `crumb/<cam>/{motion,recording}` + `crumb/<cam>/availability` retained (M)
- [ ] Re-publish discovery on `config_version` change (add/remove/rename) and on reconnect; publish per-camera availability=offline on removal (S)
- [ ] Wire the task in `main.rs` behind the `CRUMB_MQTT` gate, mirroring the detection block (S)

Phase 2, Real-time motion bus (sub-second) (M)

- [ ] Add an internal event bus the recorder publishes `MotionSignal` start/stop edges to, consumable by both the MQTT publisher and the notification system, recommend Postgres LISTEN/NOTIFY (no new infra) or a small recorder→API push; design as `crumb_common` so notifications reuse it (M), this is the SHARED bus also needed by initiative 1 Phase D
- [ ] API subscribes and publishes motion edges directly (replaces poll-diff for motion latency; keep poll as the recording/online source or reconcile backstop) (S)
- [ ] Reconcile/retained-state safety: on (re)connect, re-assert current state so HA isn't stuck on a stale retained ON (S)

Phase 3, Snapshots + polish (stretch) (M)

- [ ] Optional camera/image entity: publish a JPEG still to `crumb/<cam>/snapshot` (reuse the per-camera still proxy / filmstrip frame extraction) + `homeassistant/camera/crumb_<id>/config` (M)
- [ ] Admin console toggle + status for the MQTT bridge (enable, broker, last-publish, entity count) so it's configurable without env edits (M)
- [ ] Docs: a "Crumb + Home Assistant (no Frigate)" guide; verify end-to-end against a real HA + mosquitto on a build host (S)

#### Dependencies

- `rumqttc`, `bytes`, `async-trait` already in `services/api/Cargo.toml` (publisher needs no new crates; `base64` present for `_B64`)
- `eclipse-mosquitto:2` already in `docker-compose.yml` (or point `CRUMB_MQTT_URL` at HA's broker)
- Phase 2 depends on a recorder change to fan out `MotionSignal` (today it only reaches recording.rs over mpsc), shared with initiative 1
- Phase 1 motion-via-poll depends on status.rs's recording/recent_motion derivation + `config_version`
- Phase 3 snapshot depends on the per-camera still proxy (`cameras.rs`) / filmstrip frame extraction (`filmstrip.rs`)
- A live Home Assistant + MQTT broker for end-to-end verification (on a build host)

#### Decisions for the maintainer

- New `CRUMB_MQTT_*` env vars vs reusing `FRIGATE_MQTT_*`, recommend NEW (independent roles, possibly different brokers). Confirm.
- Motion truth in v1: status-poll diff (zero recorder change, 1–5s latency, ship now) vs real-time bus first (LISTEN/NOTIFY, more work). Recommend poll-first then upgrade.
- Topic identity for `<camera>`: stable UUID (rename-proof, ugly in HA) vs go2rtc_name/slug (human-friendly, breaks on rename). Recommend UUID in unique_id/topics + display name in HA device name.
- Which entities ship in v1: motion + connectivity + recording confirmed; camera/image snapshot deferred to Phase 3, OK?
- Internal bus mechanism for Phase 2 (and the notification system): Postgres LISTEN/NOTIFY (no new infra, already have a pool) vs tokio broadcast pushed recorder→API over HTTP/gRPC. Recommend LISTEN/NOTIFY.
- Default broker when enabled: bundled mosquitto vs the user's existing HA/Mosquitto add-on broker (most HA users already run one). Default to bundled but document pointing at HA's broker.

### 3. Prebuilt distribution & signed releases

Ship Crumb as prebuilt public Docker images (deploy-by-pull + an offline tarball for air-gapped installs), a code-signed Windows desktop installer, and a signed sideload APK, so nobody has to compile a Rust workspace to run it. Crumb is free and open source (AGPL-3.0-or-later); prebuilt artifacts are about convenience and trust (signatures, provenance, SmartScreen reputation), not secrecy. Building from source stays a first-class path.

#### Where we are today

The build infrastructure is roughly 70% there; the gap is wiring + signing + an offline path + clients-in-CI, not new architecture.

Backend: `services/api/Dockerfile` and `services/recorder/Dockerfile` are two-stage builds whose runtime stage is `debian:bookworm-slim` + jellyfin-ffmpeg + a single `COPY --from=builder` compiled binary. `docker-compose.yml` already parameterizes images as `${CRUMB_IMAGE_PREFIX:-crumbvms}/<svc>:${CRUMB_VERSION:-local}`, so the same file builds locally (default `local`) or pulls by tag from a registry. `.env.example` documents the deploy-by-pull toggle. `docs/RELEASE.md` specifies the versioned-image/rollback flow; `docs/IMAGES.md` the publishing "owner seam". Workspace license is `AGPL-3.0-or-later` (LICENSE + NOTICE at the repo root). (The `web/` Next.js app an earlier revision of this section covered was removed, the admin console ships inside the api image.)

CI (build-but-don't-push today): `.github/workflows/ci.yml` runs fmt/clippy/build/test, then builds the service images and tags via docker/metadata-action (`sha-<short>`, `latest` on main, `v*` on tag). Push is gated on a `vars.REGISTRY` that is unset, so the `images` job builds-and-validates only and never pushes. No registry is wired yet.

Desktop (two real gaps): `apps/desktop/src-tauri/tauri.conf.json` has `bundle.active:true, targets:"all"` (will produce NSIS+MSI on Windows) but NO `bundle.windows` signing block. CRITICAL: the app loads `libmpv-2.dll` from next-to-the-exe at runtime, and that DLL is not in the repo and not in `bundle.resources`, an installer built today ships an app that can't play video. No desktop bundle has been built here. CI does not build the desktop.

Android (signing not wired): the release buildType has R8 `isMinifyEnabled=true` + `isShrinkResources=true` + proguard, but no `signingConfigs{}`, no keystore, and a hardcoded `versionCode=1`/`versionName="0.1.0"`. Only a debug APK is produced today. CI does not build the APK.

#### Where we are going

Anyone can install and run the full product, backend stack, the Windows Crumb Client, and Android app, from prebuilt artifacts: public Docker images on GHCR (`docker compose pull`, no login), a signed `.exe`/`.msi`, a signed `.apk`, plus config templates. Works online and air-gapped (offline image tarball), with a clean upgrade/rollback story, no cloud dependency, no telemetry.

Approach: close four concrete gaps rather than redesign. Backend: set the CI `REGISTRY` var to the `crumbvms` GHCR org and mark the packages PUBLIC, the existing `images` job flips from build-only to build-and-push using the built-in `GITHUB_TOKEN` (already `packages:write`), no workflow rewrite; users pull with zero auth. Air-gapped: a `scripts/build-offline-bundle.sh` that `docker save`s the images to a gzip tarball shipped with an image-only compose, byte-identical images, only the delivery channel differs; pin every third-party image by digest. Desktop: fix the libmpv gap FIRST (add `libmpv-2.dll` + deps to `bundle.resources`/`externalBin`), then add a `bundle.windows` signing config and a real cert (start unsigned-alpha or OV, upgrade to EV for instant SmartScreen reputation), signing via Tauri `signCommand` in CI. Android: add a release `signingConfigs{}` (keystore as a base64 CI secret, never in repo), bump `versionCode` to a CI-injected monotonic value, distribute the signed APK via GitHub Releases (sideload; F-Droid worth evaluating later). Then extend the single `ci.yml` into a `v*`-tag release flow with images-push + desktop + android jobs feeding a `release` job.

#### Plan

Phase 0, Decisions (prereqs) (S)

- [ ] Reserve/confirm the `crumbvms` GitHub org + GHCR namespace; packages visibility decision (recommend PUBLIC, free anonymous pulls, matches the AGPL direction) (S)
- [ ] Decide desktop cert path: unsigned-alpha → OV → EV; budget the cert (S)
- [ ] Optional, not gating: trademark registration for the "CrumbVMS" name (protecting a free project's identity from squatters) (S)

Phase 1, Backend deploy-by-pull (M)

- [ ] Set CI repo/org var `REGISTRY=ghcr.io/crumbvms`; mark packages PUBLIC (flips the existing `images` job to push, no rewrite) (S)
- [ ] Cut the first `v0.1.0` git tag; confirm CI pushes recorder/api images tagged v0.1.0 + sha (S)
- [ ] Verify the stock `docker compose pull && docker compose up -d` path from a clean machine with NO registry auth (S)
- [ ] Pin third-party images (postgres:16-alpine, eclipse-mosquitto:2, alexxit/go2rtc) by digest in the shipped compose (S)

Phase 2, Air-gapped (offline tarball) (S)

- [ ] Add `scripts/build-offline-bundle.sh`: `docker save` all images | gzip → `crumb-vX-images.tar.gz` (S)
- [ ] Ship offline bundle = tarball + image-only compose.yml + .env.example + load-and-up instructions (S)
- [ ] Test on a network-isolated host: `docker load` + `docker compose up -d` from a clean machine (S)
- [ ] Document upgrade-via-tarball + rollback (load older tarball, flip `CRUMB_VERSION`) extending `docs/RELEASE.md` (S)

Phase 3, Desktop self-contained + signed installer (M)

- [ ] FIX FIRST: bundle `libmpv-2.dll` (+ deps) via `tauri.conf.json` `bundle.resources`/`externalBin` so the installer actually plays video (M)
- [ ] Add `bundle.windows` signing config (certificateThumbprint or signCommand) (S)
- [ ] Acquire OV (or EV) cert; store the key in a cloud HSM/key vault; wire Tauri `signCommand` against it (M)
- [ ] Add a CI `desktop` job (windows runner): `tauri build` → sign → upload .msi/.exe artifact (M)
- [ ] Verify the installed signed app on a clean Windows box (no SmartScreen block for EV; documented click-through for OV/unsigned) (S)

Phase 4, Android signed sideload APK (S)

- [ ] Add release `signingConfigs{}` in `app/build.gradle.kts`; store the keystore as a base64 CI secret (never in repo) (S)
- [ ] Replace hardcoded `versionCode=1` with a CI-injected monotonic build number (S)
- [ ] Add a CI `android` job → signed release APK (R8 already on) (S)
- [ ] Publish the APK via GitHub Releases; document install + the Unknown-Sources step; evaluate F-Droid later (S)

Phase 5, Unified release pipeline + user docs (M)

- [ ] Extend `ci.yml` into a `v*`-tag release flow: images-push + desktop + android jobs feed a `release` job attaching desktop+android artifacts to the GitHub Release (M)
- [ ] Write the user-facing INSTALL/UPGRADE/ROLLBACK doc set (online + air-gapped), drawn from `docs/RELEASE.md` + `OPS-DEPLOY.md` with all internal IPs/hosts genericized (M)
- [ ] Dry-run the full release end-to-end into a throwaway clean-VM environment (M)

#### Dependencies

- Phase 1 depends on Phase 0's org/namespace decision
- Phase 2 (offline) reuses Phase 1's tagged images (build the tarball from the same pushed images)
- Phase 3 desktop installer is BLOCKED on the `libmpv-2.dll` bundling fix (must precede signing or the signed app is broken)
- Phase 3 signing depends on acquiring a cert (external lead time, start early)
- Phase 4 depends on creating + securely storing an Android release keystore
- Phase 5 release pipeline depends on Phases 1/3/4 jobs existing

#### Decisions for the maintainer

- Packages visibility: PUBLIC GHCR (recommended) vs private-with-tokens, private pulls contradict the free/open direction and add permanent support friction for zero benefit.
- Desktop code-signing tier + budget: unsigned alpha (SmartScreen warning) → OV (~$200-400/yr, HSM-stored, still warns until reputation builds) → EV (instant reputation, pricier). When to buy?
- Android distribution: GitHub Releases sideload first; F-Droid and/or Play Store later (each brings its own signing/review overhead).
- Trademark the name? Optional protection for a free project's identity; not a blocker for anything.

### 4. AI-configurable documentation

Turn Crumb's docs into a layered system, a published human/AI site, a single machine-readable config + OpenAPI reference generated from the Rust source, and a shipped MCP server, so a user can point their own AI assistant at it and have it configure the install (add cameras, set policies, tune motion) via the existing authed admin API.

> **Update (2026-07-06): the docs site is shipped, and the generator question is ratified.** The published human/AI site (Layer 1) is built with Docusaurus in `docs-site/` and deploys self-hosted at `docs.crumbvms.com`; see the `docs/DECISIONS.md` entry. The remaining Layer 2/3 work (OpenAPI from `utoipa`, the single generated env/config reference, `llms.txt`, and the `crumb-mcp` server) is unchanged and slots into the docs site's later phases.

#### Where we are today

The user-facing docs site is live at `docs.crumbvms.com` (Docusaurus, `docs-site/`), with the repo `docs/` directory holding contributor/engineering docs (a curated subset of which is published to the site's Architecture section by `scripts/sync-arch-docs.mjs`). What does NOT exist yet: `llms.txt`, an OpenAPI/Swagger spec, or a JSON Schema for config. No `utoipa`/`aide`/`openapi` crate is in any `Cargo.toml`.

The configurable surface, however, is real, authed, and complete, this is the asset to wrap. The admin REST API lives in `services/api/src/config_routes.rs` (1891 lines, doc-commented with per-endpoint tables): full CRUD for cameras (`/config/cameras`), named + default recording policies (`/config/policy/default`, `/config/policies`), camera groups with inheritance (`/config/groups`), storages (`/config/storages`), users (`/config/users`), plus per-camera policy copy-on-write (`PUT /config/cameras/{id}/policy`), per-camera motion source/algorithm (pixel/frigate; census/framediff/mog2/opticalflow/ensemble), stream test (`/config/test-stream`, `/config/test-frame` in `stream_test.rs`), and network discovery (`/config/discover` in `discover.rs`). The route map is in `services/api/src/main.rs:305-356`. The canonical request/response shapes are centralized in `services/api/src/dto.rs` (704 lines, serde snake_case), the single best source for a generated config reference. Auth (`auth.rs`, `auth_mw.rs`): JWT bearer (`Authorization: Bearer` or `?token=`), two roles, admin (full config) and viewer (scoped to `camera_ids`); a ~10yr "remember" token exists (`auth.rs:134`). No API-key/scope mechanism beyond JWT yet. Env vars are documented in code via doc-commented `ApiConfig` (`config.rs`) and `crumb_common::config` (`services/common/src/config.rs`), mirrored in `.env.example`, in three places that can drift. A self-contained admin web console at `GET /admin` (`services/api/src/admin.html`, 2267 lines) already signs in via `/auth` and drives `/config/*`, proof the API is a sufficient configuration surface; the MCP server is the same idea for an AI client instead of a browser.

#### Where we are going

Two audiences, one source of truth. Humans get a clean, navigable, published docs site. An end-user's own AI assistant reads the docs to understand Crumb, then DRIVES configuration of a live install, add a camera from an RTSP URL, assign/edit a recording policy, pick a motion algorithm, run a stream test, through the existing authed admin API, safely (scoped token, read-vs-write tool separation, confirmation on destructive ops). Doc/code drift is eliminated by GENERATING reference material from the code (`dto.rs` + route definitions + `ApiConfig` structs), never hand-maintaining it.

Layer it so each phase ships standalone value and later phases reuse earlier artifacts. Layer 1 (the published Docusaurus site) is shipped; the remaining Layer 1 work is the AI-ingestion layer: `/llms.txt` (curated index) + `/llms-full.txt` served at site root and `/.well-known/llms.txt`. Layer 2 is the keystone: adopt `utoipa` + `utoipa-axum` to emit compile-time OpenAPI from the existing types (derive `ToSchema` on `dto.rs`, `#[utoipa::path]` on the handlers), served at `GET /openapi.json`; emit JSON Schema for policy/camera/storage shapes; and generate ONE env-var reference from the doc-commented `ApiConfig` so `.env.example` and docs stop being three hand-synced copies. Layer 3 ships `crumb-mcp`, a thin stdio/HTTP MCP server wrapping `/config/*`, `/status`, `/stats/cameras`, `/config/test-stream`, `/config/discover` as tools the user's agent calls. Auth reuses the existing JWT (generate a scoped token in the admin console, paste into the MCP client). Safety: split read tools (always allowed) from write tools (gated behind `--allow-write` + per-call confirmation, delete-class requiring an extra confirm), annotated with readOnly/destructive hints; a follow-on adds a revocable named-token / "config-agent" scope so an agent token is least-privilege and independently revocable (today only admin/viewer + the 10yr remember token exist).

#### Plan

Phase 1, AI ingestion layer (the published docs site is shipped) (M)

- [x] Publish a navigable docs site (done: Docusaurus at `docs.crumbvms.com`, `docs-site/`).
- [ ] Generate `/llms.txt` (curated linked index) + `/llms-full.txt` (full corpus); serve at site root and `/.well-known/llms.txt` per llmstxt.org (S)
- [ ] Author the "AI install-assistant" recipe page: paste-in system prompt + worked camera-add example (curl-based against `/config` until the MCP server ships) (S)

Phase 2, Generated machine-readable reference (OpenAPI + config schema) (L)

- [ ] Add `utoipa` + `utoipa-axum`; derive `ToSchema` on `services/api/src/dto.rs` structs and `#[utoipa::path]` on config_routes/auth/status/stats/stream_test/discover handlers (L)
- [ ] Serve `GET /openapi.json` (+ optional Scalar/Swagger UI) from `main.rs` alongside `/version`, `/health`, `/metrics` (S)
- [ ] Emit JSON Schema for recording-policy/camera/storage shapes; wire the OpenAPI spec into the docs site as the API reference page (M)
- [ ] Generate ONE env-var reference from the doc-commented `ApiConfig` + common config; make `.env.example` and docs derive from it to kill three-way drift (M)
- [ ] Add a CI check (extends `.github/workflows/ci.yml`) that fails if the committed `openapi.json` / env reference is stale vs the build (S)

Phase 3, Ship the MCP config server + token scoping (L)

- [ ] Build `crumb-mcp` wrapping `/config/*`, `/status`, `/stats/cameras`, `/config/test-stream`, `/config/discover` as MCP tools (list/add/edit cameras, policies, groups, storages; set_motion_algorithm; test_stream; discover_cameras; system_status) (L)
- [ ] Auth: consume the existing JWT as `Authorization: Bearer`; add an admin-console "Generate AI agent token" UI (M)
- [ ] Safety: split read vs write tools, gate writes behind `--allow-write` + per-call confirmation, require an extra confirm on delete-class tools; annotate with readOnly/destructive hints (M)
- [ ] API follow-on: add a revocable named-token / "config-agent" scope so an agent token is least-privilege and independently revocable (today only admin/viewer + the 10yr remember token exist, auth.rs:134) (M)
- [ ] Package: distribute `crumb-mcp` (npx/cargo install) + a copy-paste MCP client config block; update the install-assistant recipe to drive the tools end-to-end and verify the worked example on prod (M)

#### Dependencies

- A build host with Node/npm for the docs-site build and MCP TS packaging
- The existing authed admin API in `config_routes.rs` + `auth.rs` (the surface the MCP server wraps), already shipped
- `services/api/src/dto.rs` as the canonical field source for OpenAPI/JSON-Schema generation
- The existing CI gate `.github/workflows/ci.yml` (fmt+clippy+build+test) to add the spec-staleness check
- `utoipa` / `utoipa-axum` (Phase 2); MCP SDK (TS `@modelcontextprotocol/sdk` or a Rust MCP crate) for Phase 3
- Phase 3 depends on Phase 2's OpenAPI spec (the MCP tool definitions and the docs API reference both consume it)

#### Decisions for the maintainer

- Docs tooling: resolved to Docusaurus, self-hosted at `docs.crumbvms.com` (see the `docs/DECISIONS.md` entry).
- MCP server language: Rust (matches the workspace, one toolchain) vs TypeScript (faster to ship, most mature SDK, easy npx distribution). Leans TS for speed unless single-binary distribution matters.
- Token/scope model: minimum is reuse the existing admin JWT (fast, but an agent token == full admin, revocable only on next fresh login) vs a new revocable named-token + "config-agent" scope. Decide whether to invest in the scope work in Phase 3 or accept admin-JWT for v1.
- Write-safety default: should the MCP server default to read-only (require `--allow-write`), recommended, and what confirmation UX is acceptable for destructive tools (delete camera/policy/storage/user)?
- Drift policy: make generated OpenAPI + env reference canonical and have `.env.example`/docs derive from them (recommended), or keep hand-written `.env.example` authoritative and only cross-check in CI?
- llms.txt hosting: served from the public docs site so the MCP recipe can point the user's agent at a fetchable docs URL.

### 5. All-in-one container image (single-container distribution)

Decided direction (2026-07-03): ship an official all-in-one image **alongside** the
compose stack, Frigate/Home-Assistant style. It is a packaging artifact built from
the same binaries, not an architecture change, and not a replacement for compose,
which stays the canonical dev/power-user path.

#### Where we are today

The default install is a multi-service compose stack. The 2026-07-03 consolidation
batch is shrinking it: mosquitto is profile-gated (`--profile frigate`), db-backup
is being folded into the api, and go2rtc is being embedded into the recorder
container, landing at **postgres + api + recorder (+ optional caddy)**. That is
fine for technical self-hosters, but "installable by anyone" audiences live on
one-click platforms (Unraid Community Apps, CasaOS, Portainer templates, TrueNAS
SCALE), and those want ONE container with volume mounts, `docker compose` plus
eight service definitions reads as complexity even when the command is one line.
The multi-container layout has also been the highest bug-density seam (the
`crumb_api_base` poison, go2rtc DNS fallthrough, device overlays).

#### Where we are going

A single `crumbvms/crumb` (working tag name: `:aio`) image: s6-overlay (or
equivalent) supervising **postgres + api + recorder** (go2rtc already lives inside
the recorder by then) in one container. Two volumes, media (`/data`) and state
(pgdata + backups), one port (8080), same env vars as compose, same admin console
and setup wizard on first boot. `docker run` one-liner in the README; listings on
the one-click platforms follow from it.

#### Plan

- [ ] **Phase 0, prerequisite (in progress, not this initiative):** the
      consolidation batch lands (embedded go2rtc in the recorder, db-backup in the
      api, mosquitto profile-gated). The AIO scope shrinks to exactly three
      supervised processes. (S, already underway)
- [ ] **Phase 1, the image (L):** AIO Dockerfile building on the existing
      api/recorder images' artifacts; s6-overlay service tree (postgres first with
      initdb-on-empty-volume, then api + recorder); env mapping identical to
      compose (`.env` keys become container env); container healthcheck = the
      api's `/health`; graceful shutdown ordering (recorder finalizes segments
      before postgres stops). The Postgres **major-version upgrade story** must be
      designed here, not discovered later: pin PG major, detect data-dir version at
      boot, refuse-with-instructions (or auto `pg_upgrade`) on mismatch.
- [ ] **Phase 2, publish + CI (M):** build/push in the existing image workflow
      (see `docs/IMAGES.md` owner seam); the fresh-install CI smoke test gets an
      AIO variant (boot the one container, wizard-bootstrap via API, record a test
      stream). Docs: an INSTALL-AIO page + README section; AI-INSTALL gets an AIO
      branch ("one container or compose, ask the user").
- [ ] **Phase 3, platform listings (M, per platform):** Unraid CA template,
      CasaOS appfile, Portainer/TrueNAS templates. Each is a small manifest
      pointing at the GHCR image + volume/port/env docs. Start with Unraid
      (largest self-hosted NVR audience overlap).
- [ ] **Phase 4, migration paths (S):** documented compose→AIO and AIO→compose
      moves (same volume contracts make this mostly "point the mounts at the same
      dirs"); `scripts/` helper if it proves fiddly in practice.

#### Dependencies

- The consolidation batch (embedded go2rtc especially), without it the AIO
  supervises five processes instead of three.
- GHCR publishing enabled (`docs/IMAGES.md` owner seam), since platform listings
  point at public images.
- Hardware decode inside the AIO uses the same device-mapping reality as compose
  (`--device /dev/dri` / `--gpus` on the `docker run`); `enable-hwaccel.sh` grows
  an AIO mode or the listings document the flags.

#### Decisions for the maintainer

- Postgres-in-container is the deliberate trade (accept owning the pg_upgrade
  story) vs migrating Crumb to SQLite, SQLite is rejected for now: two writer
  services and heavy sqlx investment make it a rewrite, not a packaging change.
- Tag scheme: `:aio` suffix vs a separate `crumbvms/crumb-aio` repo.
- Which one-click platforms are launch targets vs later (suggested: Unraid first).
- Whether caddy/TLS ships inside the AIO (suggested: no, LAN-plain-HTTP default,
  document a reverse-proxy recipe; TLS-in-AIO doubles the config surface).

### 6. Frigate as a recording source ("keep Frigate, add Crumb on top")

Let a camera's **recorded footage** come from an existing Frigate install, per
camera, while every Crumb client keeps talking only to the Crumb API. An
existing Frigate user gets Crumb's whole viewing layer, the desktop wall,
timeline, PTZ, views, RBAC, bookmarks, exports, **without re-recording or
migrating anything**, and switching that camera to Crumb-owned recording later
is one dropdown instead of a leap of faith. This is an adoption wedge aimed
squarely at the largest self-hosted NVR community, not a change of identity:
Crumb's own recorder stays the first-class path.

#### Where we are today

The per-source abstraction pattern this needs is already shipped **twice**:

- Detections: provider-agnostic `DetectionSource` trait
  (`services/common/src/detection.rs`) with Frigate-over-MQTT as one impl,
  normalized into Crumb's own `events` table.
- Clips: the Clips tab is source-abstracted with a per-camera
  `clip_source: frigate | own`, proxying Frigate clip media through the api.
- Live: cameras can already be `served_by='frigate'`, Crumb pulls live video
  from Frigate's go2rtc (`GO2RTC_RTSP_BASE`/`GO2RTC_API_BASE` env). The console
  has a server-side Frigate URL-base test (`POST /config/frigate/test-http`).

What does NOT exist: recorded **playback** and the **timeline** for a camera
always come from Crumb's own segments (`/play`, `/segments`, timeline routes).
There is no `recording_source` concept; storage/retention pages assume Crumb
owns the bytes. Relevant Frigate API surface (version-coupled): recordings as
HLS VOD (`/vod/<Y-M>/<D>/<H>/<camera>/master.m3u8`), `/api/<camera>/recordings`
+ `/recordings/summary` (time-range + per-hour presence), arbitrary time-range
export (`/api/<camera>/start/<ts>/end/<ts>/clip.mp4`). Hard-won lesson already
on the books: Frigate wire formats change between minors (the `sub_label`
array break), every consumer must parse tolerantly and pin a supported range.

#### Where we are going

A per-camera `recording_source: crumb | frigate`. For `frigate` cameras the
api answers the same client-facing contracts from Frigate's HTTP API:
timeline built from recordings-summary + events (showing Frigate's
motion-only retention gaps honestly), playback via Frigate's HLS VOD proxied
through the api (auth via Crumb's scoped media tokens, as everywhere), export
via Frigate's time-range clip endpoint. Clients change minimally: mpv
(desktop) and ExoPlayer (Android) both play HLS natively, so the playback
descriptor just says "HLS at this URL" for those cameras. Admin UX degrades
gracefully: motion tuner, decode panel, storage policies, and retention show
"managed by Frigate" for frigate-sourced cameras. RBAC, bookmarks, views,
sharing, everything that lives in the Crumb API, works unchanged.

#### Plan

- [ ] **Phase 0, spike + version matrix (S/M):** against a real Frigate,
      validate the VOD/summary/clip endpoints end-to-end (auth model incl.
      Frigate 0.14+ authenticated port vs internal :5000), measure HLS-through-
      proxy latency in mpv/ExoPlayer, and pin the supported Frigate version
      range. Output: a short doc with the exact endpoints + shapes.
- [ ] **Phase 1, backend (L):** `recording_source` column + admin plumbing;
      a `RecordingSource`-style seam over the playback/timeline/export paths
      (mirror the `DetectionSource`/`clip_source` precedent); Frigate timeline
      mapper; authenticated HLS/VOD proxy with scoped media tokens; tolerant
      DTOs. Storage/retention endpoints report "external" for these cameras.
- [ ] **Phase 2, desktop MVP (M):** playback descriptor gains an HLS variant;
      timeline renders the Frigate-sourced data; wall/live unchanged
      (`served_by='frigate'` already covers it). Verify seek/scrub behavior on
      HLS in mpv (segment granularity differs from Crumb's 4s).
- [ ] **Phase 3, Android + export + polish (M):** ExoPlayer HLS path, export
      via Frigate's clip endpoint into the existing export-list flow, admin
      "managed by Frigate" degradation, wizard/console copy for mixed fleets.
- [ ] **Phase 4, docs + marketing surface (S):** AI-INSTALL + README "already
      running Frigate?" section; the public roadmap entry itself is part of the
      pitch to the Frigate community.

#### Dependencies

- A real Frigate instance for the spike; CI needs a containerized Frigate
  fixture or recorded HTTP fixtures.
- The Frigate URL-base config + test plumbing (shipped) and the tolerant-
  parsing discipline from the detections integration.
- No schema/behavior coupling to initiatives 1–5; can be scheduled freely,
  but NOT before the tester launch, it doubles the support matrix and the
  first wave should exercise Crumb-owned recording.

#### Decisions for the maintainer

- Supported Frigate version range (suggest: current stable minus one minor;
  refuse older with a clear message rather than half-working).
- Timeline fidelity for frigate cameras: recordings-presence + events only
  (cheap, Phase 1) vs also ingesting Frigate's motion/review data for the
  fine-grained activity row (more API surface, more churn exposure).
- Whether frigate-sourced cameras count toward anything storage-related at all
  (suggest: shown, clearly labeled external, never counted in budgets).
- Positioning: quiet capability vs headline "works with your existing Frigate"
  launch message once it ships.

### 7. Dual-stream hybrid recording ("Motion + Lo-Res Always")

A hybrid recording mode: record the **sub-stream** continuously
at low bitrate/resolution while the **main stream** stays motion-gated via the
RAM-buffer mechanism (`docs/MOTION-RECORDING.md`). An operator gets a
continuous, low-cost visual record of everything (enough to answer "did
anything happen here between 2 and 4am, and roughly what") while still only
paying full main-stream storage for the moments that actually matter, a
middle ground between Continuous (full cost, full coverage) and Motion
(near-zero idle cost, zero idle coverage).

#### Where we are today

This initiative explicitly builds on the persist-on-motion mechanism above: a
Motion-mode camera today buffers its **main** stream in the tmpfs ring buffer
and persists only on a motion trigger; its sub-stream is used solely for
motion analysis and is never recorded at all (motion detection intentionally
runs on the low-res sub stream for decode cost reasons, see
`docs/RECORDER-CORRECTNESS.md` #12). So the two streams already have separate
treatment end to end (separate go2rtc restreams, separate ffmpeg decode
paths, `segments.stream IN ('main','sub')` already models per-segment stream
identity), the schema and pipeline seam this needs is not new, just unused
in this combination today.

#### Where we are going

A third recording mode (name TBD, "Hybrid" reads clearly) alongside
Continuous and Motion: the sub-stream segments continuously to disk
(untouched by the motion buffer, same as a Continuous camera but on the sub
stream instead of main), while the main-stream segments flow through the
existing motion ring buffer exactly as Motion mode does today. Playback for a
time range with no main-stream footage falls back to the sub-stream
recording, lower resolution, but real, continuous video, instead of
nothing. Timeline rendering needs to distinguish "full-quality (main,
motion-triggered)" spans from "lo-res-only (sub, continuous)" spans so an
operator can tell at a glance which parts of the timeline have the good
footage.

#### Plan

- [ ] **Design (S):** confirm the third recording-mode value and how
      `cameras`/policy rows model it (a new `recording_mode` value alongside
      `continuous`/`motion`, or a pair of independent per-stream toggles —
      the latter is more flexible but a bigger schema/UI lift).
- [ ] **Recorder (M):** run the existing continuous-segment write path for the
      sub-stream unconditionally in Hybrid mode, in parallel with the
      existing motion-buffered main-stream path, these are already two
      separate ffmpeg processes per camera today, so this is wiring, not new
      decode infrastructure.
- [ ] **Retention/storage (M):** sub-stream continuous segments need their own
      retention accounting (they're much cheaper per second than main, but
      not free), extend the existing per-policy size-cap model rather than
      inventing a parallel budget.
- [ ] **Timeline/playback (M):** desktop + Android + web timeline needs a
      visual distinction between motion-triggered main-stream spans and
      continuous sub-stream-only spans; playback needs to select whichever
      stream actually has footage for the requested time range instead of
      assuming main.
- [ ] **Docs (S):** extend `docs/MOTION-RECORDING.md` with the hybrid mode
      once it ships, and the sizing guidance for sub-stream continuous
      storage cost.

#### Dependencies

- Requires the persist-on-motion motion-buffer mechanism (this file's
  predecessor feature, `docs/MOTION-RECORDING.md`) to exist first, Hybrid
  mode is additive on top of it, not a separate mechanism.
- Reuses the existing dual-stream architecture (separate main/sub go2rtc
  restreams + ffmpeg decode paths) already in the recorder.

#### Decisions for the maintainer

- Schema shape: a third `recording_mode` enum value vs. independent per-stream
  toggles (continuous/motion/off, chosen separately for main and sub).
- Whether sub-stream continuous footage counts against the same size cap as
  main-stream footage, or gets its own separate, smaller budget by default.
- Whether this ships as a distinct named mode in the UI ("Hybrid") or as an
  advanced option layered onto Motion mode ("also record sub-stream
  continuously").

### 8. Instant timeline scrub (pre-generated preview proxy)

Make timeline scrubbing feel instant, on every client and across multiple cameras at once, by finishing the already-scaffolded low-res thumbnail preview proxy so the server pre-generates frames instead of decoding one on demand per scrub tick. Decision and rejected alternatives (notably a finer seek index and a custom container) are recorded in `docs/DECISIONS.md` (2026-07-07).

#### Where we are today

The preview-proxy plumbing exists as an explicit "Phase 1" but is server-starved. `services/api/src/filmstrip.rs` serves `/filmstrip/{cam}` (list) + `/frame` (JPEG) from on-demand single-frame ffmpeg extraction cached at `{export_dir}/.thumbs/{cam}/{ts_ms}.jpg`; `crumb_common::db::list_thumbnail_times` is a stub returning empty, and there is no background pre-generation. The client UIs already consume it: iOS single-cam (`PlaybackView`) plus a multi-camera synchronized wall (`PlaybackWallView`), Android single-cam (`PlaybackScreen`), and the desktop export-preview scrubber. Two live defects cripple the cache: filenames are exact-millisecond but clients request arbitrary cursor times (near-zero hit rate, an ffmpeg re-spawn per scrub), and extraction has no concurrency cap (contrast `/play`'s `play_semaphore`) with `.thumbs` never evicted.

Segments are standard fMP4 ~4 s each; the per-segment seek index is sufficient (a finer keyframe index was evaluated and rejected, see the decision entry). The desktop is the only client whose main playback timeline live-seeks the real mpv panes instead of showing thumbnails, so it stalls when a drag crosses segment boundaries (an mpv `loadfile` per 4 s).

#### Where we are going

The server pre-generates the preview frames so a scrub is a static-file fetch (~5-20 ms LAN) instead of a 150-500 ms ffmpeg spawn, N cameras at once, on hardware the operator already owns. iOS and Android get the win with zero client changes; desktop gains a timeline preview it lacks today. All work is API-side / read-side, off the recorder write path (golden rule 2 unaffected), and preserves standard fMP4 (no interop loss).

#### Plan

> **Status (2026-07-09):** Phase 0 and the core of Phase 1 (background pre-generation, `THUMB_CACHE_DIR`, config knobs, coverage-aware `list_thumbnail_times`) shipped in #2 and #9. Policy-tied thumbnail retention and the admin-console tunables below remain.

Phase 0, cache hygiene, API only, standalone (S)

- [x] Grid-snap the frame timestamp in `serve_frame` and emit grid-aligned slots in `list_filmstrip` (floor to `SEGMENT_SECONDS`) so repeat and multi-cam-wall scrubs hit warm cache (S)
- [x] Global extraction semaphore mirroring `playback.rs`'s `play_semaphore` to cap concurrent ffmpeg spawns (S)
- [x] Size/age-capped `.thumbs` eviction task, path-guarded to `.thumbs`, `.jpg` only, tested (S)

Phase 1, pre-generation, API + `db.rs` stub, no migration (M)

- [x] Background per-camera worker reusing `extract_thumbnail`, interval-driven, semaphore-bounded (shipped in #2 as `thumb_pregen.rs`) (M)
- [x] Implement `list_thumbnail_times` as grid slots intersected with recorded `segments` coverage (kills 404 slots in gaps; no new table) (S)
- [ ] Thumbnail retention tied to policy retention, a NEW delete path, path-guarded + tested (S)
- [x] Config knobs (`THUMB_PREGEN_ENABLED` + lookback/scan/width, cache size/age budget) → `.env.example` / environment reference (golden rule 5) (S)
- [x] Optional `THUMB_CACHE_DIR` to place the scrub cache on fast/separate storage (e.g. an NVMe partition) while footage stays on bulk HDD, matching the random-read-hot thumbnail workload to the right medium. Low-risk: thumbnails are regenerable and the on-demand path self-heals a wiped cache, so the thumb drive can be cheap and non-redundant (a failure only makes scrubbing temporarily slower, never loses footage) (S)
- [ ] Follow-up (post-ship): expose the runtime-safe tunables (the pre-generation on/off toggle, lookback/scan/width, and the cache size/age budget) in the admin console via DB `server_settings`, so an operator can turn pre-generation on/off and adjust the cache budget without editing `.env` and restarting. Requires the pre-gen worker and the cache sweeper to read these live from `server_settings` rather than the startup `ApiConfig` snapshot. `THUMB_CACHE_DIR` stays env/compose-only: it is a filesystem mount (like the storage paths), not a preference (M)

Phase 2, desktop preview UI, `apps/desktop/src/app.js` only (M)

- [ ] Timeline hover/drag thumbnail strip (webview territory, no pane z-order issue) (M)
- [ ] Optional full drag swap-grid using the existing native-pane hide/show: JPEG grid while dragging, mpv resolves full-res on release (M)

Phase 3, client polish, optional (S)

- [ ] Android playback-wall scrub tiles (iOS parity); client-side grid-snap of requested timestamps; prefetch around the playhead (S)

Phase 4, efficiency, only if measured need (M)

- [ ] Recorder motion-decoder color-split piggyback to remove the per-interval spawn (needs its own DECISIONS entry + motion tests), and/or sprite atlases if `.thumbs` file count hurts (M)

#### Decisions for the maintainer

- Generation interval (preview granularity vs. CPU/storage): 10 s recommended; 4 s equals per-segment, richer but ~6.5 M files over 30 d at 10 cameras.
- Whether pre-generation backfills history at low priority, or relies on the on-demand fallback to self-heal history as users scrub it.

### Cross-cutting

Two pairs of initiatives share infrastructure. Building the shared piece once, deliberately, avoids two divergent half-implementations.

#### Shared internal event bus (notifications + MQTT)

Both the notification system (initiative 1) and the HA MQTT publisher (initiative 2) want the same thing: real-time `MotionSignal` start/stop edges crossing from the recorder into the API, where today they stay in-process (`recording.rs` only) and the API can only infer "motion now" by polling `status.rs`. Both initiatives independently propose the same fix, a single internal `crumb_event` / motion bus, recommended as Postgres LISTEN/NOTIFY (no new infra, the pool already exists) or a small recorder→API push.

Build it ONCE, in `crumb_common`, as a source-agnostic bus the recorder publishes to and multiple subscribers consume. The MQTT publisher's state-projector and the notification engine's evaluators should both read from this bus (a `broadcast` / NOTIFY source), not bake in their own transport. This is initiative 2's Phase 2 and initiative 1's Phase D, they are the same work and should be scheduled together.

#### Generated ground truth (distribution + docs)

Distribution (initiative 3) and AI-configurable docs (initiative 4) both depend on machine-readable artifacts generated from the Rust source rather than hand-kept. The OpenAPI spec (`utoipa` from `dto.rs`) and the single generated env-var/config reference are the keystone: the docs site consumes them, the MCP server's tool definitions consume them, and the user-facing INSTALL/config templates in distribution should derive from the same env reference so a shipped `.env.example` can never drift from the binary. The CI staleness check that initiative 4 adds also protects the distribution docs. Treat `dto.rs` + the route definitions + `ApiConfig` as the one source of truth feeding both.

#### Suggested sequence

1. AI-configurable docs Phase 1 + 2 first. The truth-pass + OpenAPI generation is low-risk, high-leverage, and produces the generated ground truth that distribution's user docs and the MCP server both need. Doing the OpenAPI work early means distribution's INSTALL docs are generated, not hand-written-then-stale.
2. Distribution Phase 0 (decisions) in parallel, it is cheap, and the code-signing cert has the longest external lead time. Then Phase 1–2 (online + air-gapped backend) and the libmpv fix at the top of Phase 3, since a broken desktop installer blocks any real tester trial.
3. The shared event bus next, scheduled as one chunk that satisfies both notifications Phase D and MQTT Phase 2. Land the bus, then fan it out to both consumers.
4. MQTT publisher (initiative 2 Phases 0–1) and notifications MVP (initiative 1 Phase A) can proceed against the poll-diff/poll-events sources without the real-time bus, so they need not wait for step 3, but their real-time phases do.
5. Distribution Phases 3–5 (signed desktop + Android + unified release) and the MCP server (initiative 4 Phase 3) round things out; the MCP server depends on the OpenAPI from step 1.

## Backlog (tracked in GitHub Issues)

Smaller items and bug fixes are tracked in
[GitHub Issues](https://github.com/badbread/crumbvms/issues) rather than
enumerated here. Recurring themes include:

- Detector tuning on real clips via the replay bench, pending an ffmpeg host.
- Policy cleanup (fork reaper, stale comments, lock_timeout).
- Camera details page: per-stream model/res/fps/codec via ffprobe.
- ONVIF discovery polish (network scan + "Find cameras" admin UI).
- Footage-reliability follow-ups: no-fsync durability inversion; reconcile-boot race.
- Deferred ops: a secrets vault beyond compose-secrets, Grafana dashboards on `/metrics`.
