# CrumbVMS Component Map: every surface a change can touch

This is the anti-drift map for the whole system. The problem it solves: a
feature or behavior change lands in one component and silently misses the
others (a client, the web admin, the install guide, the marketing site, the
README). This file is the checklist that makes "nothing gets missed"
mechanical instead of heroic.

## How to use this map (instruction to future sessions)

1. **At the START of any feature or behavior change**, find your change in
   section 2 (the change-propagation matrix). A change usually matches more
   than one row: apply every matching row's checklist. Treat unchecked
   surfaces as open work, not as optional polish.
2. **For user-facing features**, also walk section 3 (cross-client parity)
   and state explicitly which clients ship the feature now and which are
   deliberately deferred. A feature silently shipped on one client is a bug
   in process, even if the code is perfect.
3. **Keep this map self-maintaining.** When a session adds a new surface
   (a new client, a new doc that must stay honest, a new workflow, a new
   config file) or a new kind of change that this matrix does not cover,
   update this file in the same change. Same rule AGENTS.md applies to
   `docs/DECISIONS.md`.
4. This map complements, never replaces, the golden rules in `AGENTS.md`.
   Where a row says "golden rule N", that rule is the authority; the row is
   just the reminder placed where you will trip over it.

All paths below are repo-relative and verified to exist as of 2026-07-06.

---

## 1. Component and surface inventory

### 1.1 Backend

| Component | Path(s) | Owns | Built / deployed by |
|---|---|---|---|
| Shared crate | `services/common/src/` (`config.rs`, `db.rs`, `types.rs`, `detection.rs`, `logging.rs`, `redact.rs`, `icons.rs`, `ha.rs` (Home Assistant client + REST poll source + `device_class → label` map, shared by api and recorder)) | Shared types, DB layer, **the `MIGRATIONS` array** (in `db.rs`, search `static MIGRATIONS`), env config, secret redaction | Compiled into both service images |
| API service | `services/api/src/` (`main.rs` router at the `json_routes` / `media_routes` split; `config_routes.rs`, `dto.rs`, `auth.rs`, `auth_mw.rs`, `roles.rs`, `cameras.rs`, `timeline.rs`, `playback.rs`, `export.rs`, `export_store.rs`, `filmstrip.rs`, `clips.rs`, `events.rs`, `detection_ingester.rs`, `detection/`, `bookmarks.rs`, `views.rs`, `ptz.rs`, `notifications.rs`, `channel_notify.rs`, `status.rs`, `stats.rs`, `stream_test.rs`, `discover.rs`, `go2rtc.rs`, `alerts.rs`, `db_backup.rs`, `metrics.rs`, `rate_limit.rs`, `updates.rs`, `ha.rs` (Home Assistant integration: `ha_config` + `camera_ha_links` + entity picker, REST-only in Phase 1; see `docs/DECISIONS.md` 2026-07-10 and issue #52)) | HTTP API, auth/RBAC, go2rtc reconcile loop, admin console serving, DB backup task, Home Assistant integration | `services/api/Dockerfile`; image `<prefix>/api:<version>` via CI `images` job |
| — background task: **event janitor** | `services/api/src/main.rs` (spawned next to the export TTL sweeper) → `db::close_stale_open_events` in `services/common/src/db.rs` | `end_ts` convergence for the `events` table: closes any open event whose `updated_at` liveness stamp is older than 30 min (`end_ts = GREATEST(ts, updated_at)`), so `end_ts` can never be NULL-forever. Runs in the API, NOT the recorder (golden rule 2). See `docs/design/CLIP-MODEL.md` §2.3 and `docs/DECISIONS.md` 2026-07-16 | part of the API service image |
| Recorder service | `services/recorder/src/` (`recording.rs`, `motion.rs`, `archive.rs`, `reconcile.rs`, `go2rtc_embed.rs`, `frigate_motion.rs`, `ha_motion.rs` (Home Assistant motion source; writes labeled `'ha'` events), `source_health.rs` (additive-source fail-open aggregation: `FailOpenGate`), `decode_probe.rs`, `resource_stats.rs`; **additive motion**: `motion::run` spawns one loop per enabled `motion_{pixel,frigate,ha}_enabled` source, `recording::MotionUnion` unions their edges for the buffer, `aggregate_health` collapses per-source health — see `docs/DECISIONS.md` 2026-07-10) | Recording, motion detection, retention/eviction, segment index, embedded go2rtc supervision. The always-must-work component (golden rule 2) | `services/recorder/Dockerfile`; image `<prefix>/recorder:<version>` |
| DB schema | `db/migrations/0001..NNNN_*.sql` + the `MIGRATIONS` array in `services/common/src/db.rs` | Schema history. A migration file not listed in the array **silently never runs** (golden rule 4) | Applied on boot by whichever service starts first |

### 1.2 Clients (five)

| Client | Path(s) | Notes |
|---|---|---|
| Web admin console | `services/api/src/admin.html` (single file, inline `<script>`, embedded via `include_str!`) | The entire web UI: admin, wizard, live, playback, clips, export, notifications, users/RBAC. Rebuild the api to see changes. Conventions: `esc()` for interpolation, `api()` for authed fetches, every `on*=` handler must exist, semantic colors `var(--ok)/--warn/--danger`. Sanity check: `node --check` the extracted script block |
| Windows/Linux desktop | **current: `apps/desktop-flutter/`** (Flutter + `flutter_rust_bridge` Rust core, video via `media_kit`/libmpv; `lib/main.dart`, `lib/ui/` screens, `lib/api/`, `lib/state/`, `lib/src/` bridge). **Retiring: `apps/desktop/`** (Tauri + WebView2, `src/app.js` + `src-tauri/`) | Native rewrite from Tauri to Flutter, ratified `docs/DECISIONS.md` 2026-07-10; Flutter *replaces* the Tauri UI (it is not a second client). `libmpv-2.dll` must sit next to the exe on Windows or panes are black. Still embeds the server's `/admin` (token SSO, `#token=...&embed=1`) for management, so admin console changes surface here too. Newer feature rows below already point at `apps/desktop-flutter/`; treat any bare `apps/desktop/src/app.js` reference in an older row as the retiring Tauri path |
| Android | `apps/android/app/src/main/java/video/crumb/app/` (`data/` REST layer: `CrumbApi.kt`, `CrumbRepository.kt`, `Models.kt`, `MediaUrls.kt`, `MediaTokenCache.kt`, `SecureStore.kt`; `feature/` screens: `about`, `auth`, `clips`, `export`, `live`, `playback`, `settings`, `tuner`; `ui/`, `di/`) | Kotlin/Compose/Media3, Gradle (JDK 21, SDK 34). Built on dev hosts, released by `.github/workflows/android-release.yml` (signed APK on `v*` tag) |
| iOS + macOS | `apps/ios/Crumb/` (`Features/`: `Auth`, `Bookmarks`, `Clips`, `Export`, `Live`, `Playback`, `Settings`, `Tuner`; `Networking/`, `Models/`, `Platform/`; `project.yml` XcodeGen; `Info-macOS.plist`, `Crumb-macOS.entitlements`) | Native SwiftUI, one project targets both platforms. Built via Mac host (`scripts/release/ios.sh`) |
| (removed) web viewer | `web/` was deleted 2026-07-01; `admin.html` is the one web client | Any doc still referencing a `web` image or the Next.js viewer is stale |

### 1.3 Install, config, and ops surface

| Surface | Path(s) | Notes |
|---|---|---|
| Compose stack | `docker-compose.yml` (canonical), `docker-compose.build.yml`, `docker-compose.override.example.yml`, `docker-compose.gpu.example.yml`, `docker-compose.vaapi.example.yml`, `docker-compose.secrets.example.yml`, `docker-compose.smoke.yml` | Changing services/ports/volumes/profiles/env here triggers golden rule 5 (install-guide honesty). Validate with `docker compose config` on a real Docker host |
| Env and secrets | `.env.example`, `scripts/setup-env.sh`, `scripts/setup-secrets.sh` | Secrets are generated, never hardcoded. `.env` is gitignored |
| Helper scripts | `scripts/enable-hwaccel.sh`, `scripts/backup-db.sh`, `scripts/restore-db.sh`, `scripts/systemd/`, `scripts/test/` | |
| Sidecar config | `go2rtc/go2rtc.yaml` (listener config ONLY, streams are DB-managed), `caddy/Caddyfile`, `mosquitto/mosquitto.conf` | Never hand-add streams or credentials to go2rtc.yaml |
| Install runbook | `docs/AI-INSTALL.md` (agent-runnable; has a "For maintainers" re-verify list), README "Run" section, `docs/IMAGES.md` (pull vs build), `docs/BACKUP.md`, `docs/TLS.md` | Golden rule 5: these must never drift from the compose/env reality |

### 1.4 CI, release, and repo hygiene

| Surface | Path(s) | Notes |
|---|---|---|
| CI gate | `.github/workflows/ci.yml` (jobs: `rust` fmt/clippy/test, `desktop-lint`, `desktop-linux`, `images` recorder+api) | Golden rule 3: fmt, clippy `-D warnings`, workspace tests green before push/PR |
| Fresh-install smoke | `.github/workflows/smoke.yml` + `docker-compose.smoke.yml` | Boots the stack from scratch; install-surface changes must keep it green |
| Android release | `.github/workflows/android-release.yml` | `v*` tag, signed APK + sha256 on the GitHub Release. Keystore is a CI secret. Also `workflow_dispatch` (input: `release_tag`) to re-ship an Android-only fix onto an existing release without a new tag — bump `apps/android/version.properties` `VERSION_CODE` first |
| CLA bot | `.github/workflows/cla.yml`, `CLA.md`, `CCLA.md`, `DCO` | |
| Release orchestration | `scripts/release/` (`release.sh`, `lib.sh`, `backend.sh`, `android.sh`, `ios.sh`, `desktop-windows.sh`, `desktop-linux.sh`, `README.md`), `VERSION`, `docs/RELEASE.md` | Multi-host build fan-out over SSH; versioned-image deploy/rollback contract |
| GitHub presence | `README.md`, `.github/ISSUE_TEMPLATE/`, `.github/pull_request_template.md`, `.github/FUNDING.yml`, `.github/media/` (README GIFs/screenshots), `LICENSE`, `NOTICE`, `SECURITY.md`, `CONTRIBUTING.md` | README screenshots/GIFs live in `.github/media/` and go stale when the UI changes |

### 1.5 Docs and marketing

| Surface | Path(s) | Notes |
|---|---|---|
| Engineering docs | `docs/` (notably `DECISIONS.md`, `RECORDER-CORRECTNESS.md`, `ROADMAP.md`, `MOTION-RECORDING.md`, `MOTION-DETECTION-DESIGN.md`, `MOTION-ADAPTIVE-THRESHOLD.md`, `MOBILE-PERFORMANCE.md`, plus design docs) | `DECISIONS.md` is governed by golden rule 7 |
| User docs | `docs/AI-INSTALL.md`, `docs/CLIENTS.md` (client install and connect), `docs/RESPONSIBLE-USE.md`, `docs/ALPHA-TESTER-TERMS.md`, `docs/BACKUP.md`, `docs/TLS.md`, `docs/OPS-BACKUP-RECOVERY.md` | These are the seed content for the public docs site |
| Public docs site | `docs-site/` (Docusaurus), published at `docs.crumbvms.com`; the docs-site build model is recorded in `docs/DECISIONS.md` | Live. It is a propagation surface in every user-facing change below: update the matching `docs-site/docs/` page in the same change |
| Camera compatibility DB | `data/camera-compatibility.json` (source of truth, schema in `data/README.md`) → `scripts/gen-camera-compat.mjs` (zero-dep) → `docs-site/docs/cameras/compatibility.md` (generated, gitignored). Wired into `docs.yml` and `docs-site/Dockerfile` | PR-curated, no telemetry. Same JSON is the intended input to the future in-app "identify camera + known quirks" hint (`serde_json`); see `docs/DECISIONS.md` 2026-07-10 |
| Marketing site | `site/` (`index.html` hand-edited home, `privacy.html`, `updates/posts/*.md` authored, `updates/` + `feed.xml` + `sitemap.xml` + `data.json` generated by `site/scripts/build.mjs`, `styles/`, `app.js`, `assets/`) | Author a post in `updates/posts/`, run `node scripts/build.mjs` (Node 18+, zero deps), commit sources AND generated output. Copy rules: capability-first and humble tone, no em-dashes, generic references to other NVRs only |
| Brand | `brand/crumb-vms-design-system/` | Logos, tokens; the site and clients draw from it |

---

## 2. Change-propagation matrix

Find every row that matches your change and run its checklist. Rows compose:
a "new camera capability" is usually also a "new/changed API endpoint" and a
"user-visible capability".

**Every change, always (the floor):**

- [ ] CI gate green before push (fmt, clippy `-D warnings`, `cargo test --workspace` with a Postgres) (golden rule 3)
- [ ] DCO sign-off on commits; stage explicit paths only for a scoped commit, never `git add <dir>`
- [ ] If the change embodies a design decision with a researched-and-rejected alternative: add a `docs/DECISIONS.md` entry (golden rule 7)
- [ ] If the change touches anything in section 1.3: run row I below (install-guide honesty, golden rule 5)

### A. New or changed HTTP API endpoint or DTO

| Surface | Path | Why |
|---|---|---|
| Handler + router | `services/api/src/<module>.rs`, wired in `services/api/src/main.rs` (`json_routes` vs `media_routes`) | JSON routes get gzip + 30s timeout + rate limit; media routes deliberately get none of those. Put the endpoint on the right side |
| Request/response shapes | `services/api/src/dto.rs` | The canonical serde shapes every client mirrors |
| AuthN/AuthZ | `services/api/src/auth.rs`, `auth_mw.rs`, `roles.rs` | Golden rule 1: every endpoint authenticated, through RBAC (admin vs role capabilities + per-camera grants). Media URLs use scoped short-lived `?token=` media claims, never the bearer JWT |
| Web admin | `services/api/src/admin.html` (`api()` helper) | If the console consumes it |
| Desktop | `apps/desktop/src/app.js` | If the desktop consumes it |
| Android | `apps/android/.../data/CrumbApi.kt` + `CrumbRepository.kt` + `Models.kt` (and `MediaUrls.kt`/`MediaTokenCache.kt` for media) | Retrofit interface + repository + DTO mirrors |
| iOS/macOS | `apps/ios/Crumb/Networking/` + `Models/` | Swift mirrors of the DTOs |
| Tests | same-crate `#[cfg(test)]` or integration tests | Changed behavior gets tests (CONTRIBUTING) |
| API reference | ROADMAP initiative 4 plans a generated OpenAPI spec from `dto.rs`; until it exists, the doc-comment tables in `config_routes.rs` are the reference and must be updated | Prevents a hand-written reference from drifting |

### B. New server setting, env var, or config key

| Surface | Path | Why |
|---|---|---|
| Config struct | `services/api/src/config.rs` and/or `services/common/src/config.rs` (doc-commented) | The code-side truth |
| Env template | `.env.example` | What a fresh install sees |
| Setup script | `scripts/setup-env.sh` (and `setup-secrets.sh` if secret-shaped) | If the key should be generated or prompted |
| Compose | `docker-compose.yml` environment blocks (api and/or recorder), plus any example variant that mentions it | The container must actually receive it |
| Admin console | `services/api/src/admin.html` server-settings section, if DB-overridable | Config precedence: DB `server_settings` wins over env; empty DB value falls back to env. Console code must only write the fields it edits |
| First-run wizard | wizard flow in `admin.html` (setup_complete, migration `0027`) | If the setting belongs in onboarding |
| Install runbook | `docs/AI-INSTALL.md` (step 2 and the "For maintainers" list) | Golden rule 5 |
| Docs site | `docs-site/docs/configuration/*` page | |

### C. New DB migration

| Surface | Path | Why |
|---|---|---|
| SQL file | `db/migrations/00NN_<name>.sql` (next free number) | |
| Registration | `MIGRATIONS` array in `services/common/src/db.rs` | Golden rule 4: an unregistered migration silently never runs |
| Tests | `cargo test --workspace` against a throwaway Postgres (see AGENTS.md) | Migrations apply on boot in both services; a broken one takes down both |
| Correctness review | `docs/RECORDER-CORRECTNESS.md` if the migration touches `segments`, retention, storage, or anything footage-adjacent | Golden rule 2 |
| Backup/restore | `docs/BACKUP.md` / `scripts/backup-db.sh` if the schema change affects what a restore must contain | |

### D. Recording, retention, eviction, storage, or reconcile change

| Surface | Path | Why |
|---|---|---|
| Read first | `docs/RECORDER-CORRECTNESS.md` | Golden rule 2: losing footage is the one unforgivable bug. Prefer the change that cannot delete or orphan footage |
| Recorder code | `services/recorder/src/recording.rs`, `archive.rs`, `reconcile.rs`, `motion.rs` | |
| Tests | mandatory for this area, no exceptions | |
| Design docs | `docs/MOTION-RECORDING.md` if the mechanism changes | Documents the ratified mechanism |
| Policy UI | `admin.html` policy/storage editors; desktop Recorder Health panels in `app.js` | Per-policy knobs (size caps, headroom, `max_retention_days`) surface here. Policy MODEL (named membership, `origin`, deviation-edit, collapse migration) is `docs/design/POLICY-MODEL.md`; Phases 1–2 are server-only (endpoint request/response shapes unchanged, so no client change): Phase 2 (migration `0068`) makes `policy_id`/`name` NOT NULL, retires the grouped-camera triggers, and makes group endpoints write-through. Phase 3 reworked the admin UI (all `admin.html`, no API change): the Recording section is a policy manager (per-policy mode/members/storage/retention rows, inline rename, deviation "auto-created when <camera>" hint); the camera Recording tab is a single policy select; a Motion-tab tuning save toasts the mint/join transition with Rename/Undo; and the groups UI is retired (Cameras page shows a Policy column, no groups card; the policy page's "Cameras on this policy" + bulk "Assign cameras" is the one assignment path). `stats.rs` dropped the `Custom — <camera>` label fallback |
| Decision log | `docs/DECISIONS.md` | Retention/recording design choices are exactly what it exists for |
| Migration | rows C above if schema changes | |

### D2. Audio/video encoding change (recorder segments, export, any transcode)

| Surface | Path | Why |
|---|---|---|
| **Best practice (audio)** | **Recorded/exported audio MUST be decodable on every client: copy it when the source rate is already client-safe (≤ 48 kHz), transcode to 48 kHz AAC only when it isn't (> 48 kHz).** | Android/web hardware AAC decoders reject rates above 48 kHz: a camera streaming 64 kHz logs `MediaCodecInfo: NoSupport [sampleRate.support, 64000] [c2.android.aac.decoder]` and plays SILENT, even though desktop's software ffmpeg decoder handles it. Don't blanket-transcode (wastes CPU on the already-safe majority); don't blanket-copy (silences > 48 kHz cameras). See `docs/DECISIONS.md` 2026-07-12 and `docs/RECORDER-CORRECTNESS.md` #23 |
| Recorder | `services/recorder/src/recording.rs` — `probe_audio_sample_rate` + `audio_needs_transcode` + `audio_segmenter_args` (after `-c copy`, overriding only audio): `≤48k → -c:a copy -copyinkf:a`, else `-c:a aac -ar 48000` | The record path picks per camera from the probed rate; a failed probe → transcode (safe) |
| Export | `services/api/src/export.rs` codec args | **Known follow-up:** still `-c:a copy` (+ `-copyinkf:a`) and NOT yet sample-rate-normalized, so an exported clip can still carry a rate a phone won't play — normalize to 48 kHz here too |
| Video | keep video a **bit-exact copy** (`-c copy`); retag containers, don't transcode (`-tag:v hvc1` for HEVC so Apple decodes it) | Transcoding video is expensive + lossy; audio re-encode is negligible next to copied video |
| Tests | assert the audio args encode AAC @ 48 kHz (not copy); any integration check asserts `nb_read_packets > 0` on the audio stream | A declared-but-empty OR wrong-sample-rate track still probes as a healthy stream |
| Decision log | `docs/DECISIONS.md` | Encoding choices with rejected alternatives (copy / per-client software decoder / conditional transcode) |

### E. New camera capability (PTZ, imaging, ONVIF, stream handling)

| Surface | Path | Why |
|---|---|---|
| API | `services/api/src/ptz.rs`, `cameras.rs`, `config_routes.rs`, `stream_test.rs`, `discover.rs` (plus row A) | |
| go2rtc seam | `services/api/src/go2rtc.rs` (reconcile), `services/recorder/src/go2rtc_embed.rs` | Streams are managed at runtime from the `cameras` table. Never hand-edit `go2rtc/go2rtc.yaml` beyond listeners; never point `crumb_api_base` anywhere but Crumb's own go2rtc REST endpoint. Reconcile is diff-based (PATCH existing, PUT missing; see DECISIONS 2026-07-06), do not regress to PUT-all |
| Clients | desktop `app.js` (on-video PTZ panel), android `feature/live`, iOS `Features/Live`, `admin.html` | Parity walk, section 3 |
| Client setup doc | `docs/CLIENTS.md` | If the operator must configure anything (e.g. the reachable stream address for native live video) |
| Camera compatibility DB | `data/camera-compatibility.json` | When a specific make/model shows a quirk or needs a workaround (codec/stream oddity, ONVIF gap), add or update its entry and regenerate (`node scripts/gen-camera-compat.mjs`). PR-curated, no telemetry |

### F. Motion detection change (detectors, thresholds, tuner)

| Surface | Path | Why |
|---|---|---|
| Detector code | `services/recorder/src/motion.rs` (the `MotionDetector` trait + census/framediff/mog2/opticalflow/ensemble impls), `frigate_motion.rs` for Frigate-as-source | |
| Tests | `cargo test motion::` before any deploy touching `motion.rs` | House rule from prior regressions |
| Units | `motion_threshold` is a fraction 0..1 everywhere; "%" is display-only | Cross-component unit contract |
| Tuner UIs | `admin.html` motion tuner, desktop inline tuner in `app.js`, android `feature/tuner`, iOS `Features/Tuner` | Four tuner surfaces exist; a new knob must reach all four or be explicitly deferred |
| Docs | `docs/MOTION-DETECTION-DESIGN.md`, `docs/MOTION-ADAPTIVE-THRESHOLD.md` | |
| Schema | per-camera detector/threshold settings ride `cameras`/policies: rows B and C | |

### G. Auth, RBAC, sessions, or security posture change

| Surface | Path | Why |
|---|---|---|
| Server | `services/api/src/auth.rs`, `auth_mw.rs`, `roles.rs`, `rate_limit.rs`; sessions (migration `0033`), roles (migration `0028`) | Golden rule 1 in full: secure by default, no new `0.0.0.0` binds, no widened port exposure, no invented/logged secrets |
| Media tokens | scoped `?token=` mint (`auth.rs` media_token_routes) and every client's media-URL builder: android `MediaTokenCache.kt`/`MediaUrls.kt`, desktop `app.js`, iOS `Networking/` | Media must never carry the bearer JWT |
| Client auth flows | `admin.html` login, desktop token SSO into embedded `/admin`, android `feature/auth` + `SecureStore.kt`, iOS `Features/Auth` | Token shape/lifetime changes break clients quietly |
| Wizard/seed | `SEED_ADMIN_*` envs, `auth::seed_admin_if_absent` | First-boot path |
| Disclosure | `SECURITY.md` | Vulnerabilities go through GitHub private reporting, never a public issue/PR |
| Install runbook | `docs/AI-INSTALL.md` | If login/first-boot behavior changes |

### H. Admin console (web) feature

| Surface | Path | Why |
|---|---|---|
| The file | `services/api/src/admin.html` | One file, inline script, `include_str!`: rebuild the api image/binary to see changes. Some tools misdetect it as binary (`grep -a`) |
| Conventions | `esc()` on all interpolation, `api()` for fetches, every `on*=` handler defined, semantic colors, settings-UX principles (sticky header, collapsible, live-preview, tab persistence) | |
| Syntax check | `node --check` on the extracted script block | Cheapest smoke test for an 8800-line file |
| Desktop embed | desktop embeds `/admin#token=...&embed=1`; verify the change renders in the embedded WebView too | The console is also a desktop surface |
| Wizard | if onboarding changed: `docs/AI-INSTALL.md` section 6a must match what the wizard actually asks | Golden rule 5 |

### I. Install, compose, env, secret, or image change (golden rule 5)

| Surface | Path | Why |
|---|---|---|
| Compose files | `docker-compose.yml` + every variant that mentions the changed service/port/volume/profile (`.build`, `.override.example`, `.gpu.example`, `.vaapi.example`, `.secrets.example`, `.smoke`) | Variants drift one by one if not swept together |
| Env surface | `.env.example`, `scripts/setup-env.sh`, `scripts/setup-secrets.sh` | |
| Install runbook | `docs/AI-INSTALL.md`, in the SAME change; re-verify the items its "For maintainers" section lists | The runbook must never drift from reality |
| README | the manual Run path in `README.md` | |
| Smoke CI | `.github/workflows/smoke.yml` + `docker-compose.smoke.yml` must still pass | The executable proof of the install path |
| Image docs | `docs/IMAGES.md`, `docs/RELEASE.md` if image names/tags/registry change | |
| Hardware decode | `scripts/enable-hwaccel.sh` + the gpu/vaapi example composes | If devices/runtime flags change |
| Validation | `docker compose config` on a real Docker host, not a YAML parser | Known trap |
| Docs site | `docs-site/docs/getting-started/*` + `configuration/*` pages | Update the affected page in the same change |

### J. Notification system change (channels, rules, devices)

| Surface | Path | Why |
|---|---|---|
| Server | `services/api/src/notifications.rs`, `channel_notify.rs`, `alerts.rs`; migrations `0015`/`0017`/`0032` | |
| Admin console | notifications section in `admin.html` | Rules/history CRUD |
| Clients | android polling/local-notification path, desktop toasts, iOS `Settings` | Delivery ends on a client |
| Env/config | rows B and I for any new channel credential (`ALERT_WEBHOOK_URL`, ntfy/Pushover keys) | Never log or hardcode channel secrets |
| Docs | `docs/AI-INSTALL.md` section 9 (monitoring/alerting); `docs-site/docs/notifications/*` | |

### K. Release, versioning, or CI change

| Surface | Path | Why |
|---|---|---|
| Workflows | `.github/workflows/ci.yml`, `smoke.yml`, `android-release.yml`, `cla.yml` | The CI gate definition IS golden rule 3; changing it changes the gate for everyone |
| Version | `VERSION`, image tags `${CRUMB_IMAGE_PREFIX}/{api,recorder}:${CRUMB_VERSION}` in `docker-compose.yml` | |
| Orchestrator | `scripts/release/*.sh` | Multi-host build fan-out must match reality |
| Docs | `docs/RELEASE.md`, `docs/IMAGES.md`, `docs/CLIENTS.md` (how users obtain each artifact) | |
| Runner note | if a checkout has `core.fileMode false`, committed scripts can lose the executable bit: `git update-index --chmod=+x` for anything CI executes | Known CI-breaking trap |

### L. User-visible capability (anything you would announce)

Run the parity walk in section 3, then:

| Surface | Path | Why |
|---|---|---|
| README | `README.md` Features/Screenshots; media in `.github/media/` | The front door; screenshots go stale when UI changes |
| Marketing update post | `site/updates/posts/YYYY-MM-DD-slug.md`, then `cd site && node scripts/build.mjs`, commit sources and generated `updates/`, `feed.xml`, `sitemap.xml`, `data.json`, `index.html` | The updates feed is the public changelog |
| Homepage copy | `site/index.html` only if the capability is headline-worthy | Hand-edited outside the generated markers |
| Client guide | `docs/CLIENTS.md` if install/UX steps change | |
| Docs site | `docs-site/docs/` feature page for the affected area | Update in the same change |
| Copy rules | capability-first and humble tone, no em-dashes in drafted copy, generic references to other NVRs only, LAN IPs/camera names in screenshots are fine | House style, non-negotiable |

### M. Significant design decision (alternative researched and rejected)

| Surface | Path | Why |
|---|---|---|
| Decision log | `docs/DECISIONS.md` new entry at top: chosen, rejected, trade-offs, revisit triggers | Golden rule 7; decisions living only in a chat session are lost |
| Roadmap | `docs/ROADMAP.md` if the decision changes or completes a scoped initiative | Keep "where we are today" true |

---

## 3. Cross-client parity

Five clients exist. For any user-facing feature, decide and STATE which of
them ship it. "The others come later" is fine; "the others were forgotten"
is not. The web admin console doubles as the desktop's management surface
(embedded), so console-only features still reach desktop users.

| Feature area | Web admin (`services/api/src/admin.html`) | Desktop (`apps/desktop/src/app.js`) | Android (`apps/android/.../feature/`) | iOS/macOS (`apps/ios/Crumb/Features/`) |
|---|---|---|---|---|
| Login, server discovery | login + wizard sections | connect screen (multi-port subnet scan) | `auth/` + Find my server | `Auth/` |
| Live wall / viewing | live section | wall builder, carousels, hotspot, PTZ tiles | `live/` | `Live/` |
| Playback + timeline | playback section | timeline, scrub, prefetch, zoom | `playback/` | `Playback/` |
| Clips | clips section | clips view | `clips/` | `Clips/` |
| Export | export section | export list | `export/` | `Export/` |
| Bookmarks | bookmarks UI | bookmark UI | `AddBookmarkDialog.kt` (in `ui/`) | `Bookmarks/` |
| PTZ / imaging | camera controls | on-video PTZ panel (customizable) | `live/` player controls | `Live/` |
| Motion tuner | tuner section | inline tuner | `tuner/` | `Tuner/` |
| Views (saved layouts) | views handling | views + server-backed `/views` | server-backed views | `Platform/`/`Features` |
| Settings | server settings + users/RBAC | settings + embedded `/admin` | `settings/` | `Settings/` |
| Notifications | rules + history CRUD | toasts | poll + local notifications | `Settings/` |
| Update notice (issue #7) | Server settings toggle + status/"Check now" (the console's own update IS the server update) | Phase 2, not yet shipped (`docs/UPDATE-SYSTEM-PLAN.md` §7 C2) | Phase 2, not yet shipped (§7 C3) | Phase 2, not yet shipped, iOS lowest priority per D5 (§7 C4) |
| License plates (LPR, `docs/DECISIONS.md` 2026-07-13; backend: `plates.rs` `GET /plates`, `plate_reads`/`lpr_config` migration `0051`, Frigate ingest in `detection/frigate.rs`, `view_plates` cap; engine = Frigate native LPR, external engines incl. OpenALPR via a future `POST /lpr/reads`) | **Phase 0**: enable/retention toggle in Detection & clips + `view_plates` role checkbox + a Plates list | **Phase 0**: "Plates" tab (gated on `MeResponse.plates_enabled`), list → click-to-playback (the Flutter client `apps/desktop-flutter/`) | Deferred (Phase 3+) | Deferred (Phase 3+) |
| LPR alerts / watchlist (LPR Phase 2, `docs/DECISIONS.md` 2026-07-13; backend: `lpr_watchlist` migration `0052`, `/lpr/watchlist` GET `view_plates` / POST+DELETE admin-only in `plates.rs`, match+emit in `detection_ingester.rs`, `plate_watchlist_hit` event_key rides `system_events`/`notifications.rs` fan-out) | Plates → **Watchlist** manager (add/remove/notify) + `plate_watchlist_hit` in Notifications → System alerts | "Plates" tab watchlist manager + add-to-watchlist from a read | Phase 2 client watchlist manager + add-to-watchlist from a read | Deferred (Phase 3+) |

Parity walk for a new feature:

1. Which of the five clients get it now? Which are deferred, and is the
   deferral recorded (issue or `docs/ROADMAP.md` backlog)?
2. Does each shipping client use the same API contract (`dto.rs` shapes,
   media `?token=` claims)? Divergent client-side reimplementations are how
   parity silently breaks later.
3. Do all shipping clients degrade gracefully when the server is older than
   the client (missing endpoint returns 404)? Clients poll `/status`
   `config_version` for config propagation; feature detection beats version
   sniffing.
4. Update the table above if the feature adds a new feature AREA.

---

## 4. Maintaining this map

- New component, client, workflow, config file, or doc-that-must-stay-honest:
  add it to section 1 and to every matrix row it belongs to, in the same
  change that creates it.
- New KIND of change the matrix does not cover: add a row to section 2.
- A surface removed (like `web/` was): delete its entries here and grep the
  other docs for stale references while you are at it.
- This file states file paths only, never behavior details; behavior truth
  lives in the linked docs and the code. If a path here stops existing, fix
  this file, do not leave it lying.
