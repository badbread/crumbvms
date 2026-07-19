---
title: Environment reference
sidebar_label: Environment reference
slug: /configuration/environment-reference
---

# Environment reference

Every key Crumb reads from `.env`, grouped by area. The authoritative copy
lives in `.env.example` in the repository; this page mirrors it for
browsing. Most installs never need to touch most of these, `setup-env.sh`
fills in the values that matter for a first boot.

A few keys further down are read by the code but are **not** wired into
`docker-compose.yml`. Those are flagged inline as "compose override needed",
meaning setting them in `.env` alone does nothing, you have to pass them into
the container yourself with a `docker-compose.override.yml`. I'd rather call
that out honestly than let you set a key that silently never takes effect.

## Time zone

| Key | Default | Notes |
|---|---|---|
| `TZ` | `UTC` | Local wall-clock for the whole stack: quiet hours, the nightly DB backup schedule (`DB_BACKUP_SCHEDULE`), the offsite-sync cron, and every log timestamp. Set an IANA name like `America/Los_Angeles` or `Europe/Berlin`. `setup-env.sh` detects the host's zone and writes it; if it can't, the compose default is `UTC` (not any local zone), so the clock is at least predictable. |

## PostgreSQL

| Key | Default | Notes |
|---|---|---|
| `POSTGRES_USER` | `crumb` | |
| `POSTGRES_PASSWORD` | generated | strong random value from `setup-env.sh` |
| `POSTGRES_DB` | `crumb` | |
| `DATABASE_URL` | derived | full connection string used by api + recorder |
| `DB_POOL_SIZE` | `32` | connection pool size. Fixed default of 32, not a per-camera formula. Raise it past ~16 cameras (rule of thumb `2 * cameras + 10`), and raise Postgres `max_connections` to match. **Compose override needed:** the base compose file doesn't forward this, so set it in a `docker-compose.override.yml`, not just `.env`. |

## WebRTC live (iOS / browser)

| Key | Default | Notes |
|---|---|---|
| `WEBRTC_CANDIDATE` | empty | The server's own LAN IP that go2rtc advertises to WebRTC/iOS clients as an ICE candidate, in the form `<server-LAN-ip>:8556`. Required for the iOS/browser WebRTC live path: without it, LAN clients never complete ICE and live silently degrades to roughly 1fps snapshots. `setup-env.sh` detects and writes the host LAN IP; leave it blank only if you don't use WebRTC/iOS live view. |

## Streaming (go2rtc)

Crumb's own go2rtc restreamer runs embedded in the recorder container. The
values below are fallbacks: once you set the server's address in the admin
console's Server & streaming settings, that value wins.

| Key | Default | Notes |
|---|---|---|
| `CRUMB_GO2RTC_API_BASE` | empty | leave blank, internal compose defaults are correct |
| `CRUMB_GO2RTC_RTSP_BASE` | empty | leave blank; set the public RTSP address in the admin console instead |
| `GO2RTC_USER` | `go2rtc` | a fixed, non-secret Basic-auth username label (not generated); required, compose fails fast if unset |
| `GO2RTC_PASS` | generated | required; required to be strong, rotate with care (needs a recorder + api restart) |
| `GO2RTC_EMBEDDED` | `true` | set `false` only if running an external restreamer |
| `GO2RTC_RTSP_BASE` / `GO2RTC_API_BASE` | empty | a separate, external Frigate go2rtc instance, only used for cameras served by it |

## Recording

| Key | Default | Notes |
|---|---|---|
| `SEGMENT_SECONDS` | `4` | 2 to 6 seconds; short segments mean near-instant seek |

## Motion-mode RAM cache

See [Motion & Detection](/motion/) for the mechanism this configures.

| Key | Default | Notes |
|---|---|---|
| `MOTION_CACHE_TMPFS_BYTES` | `536870912` (512 MiB) | tmpfs size for the pre/post-roll ring buffer; sizing rule of thumb in `.env.example` |
| `MOTION_CACHE_DIR` | `/cache/motion` | only change alongside the compose tmpfs target |
| `MOTION_RECORDING_SHADOW` | `0` | `1` records everything as before but stamps each segment with the keep/discard verdict the buffer would have made, for validating before flipping a camera live |

## Timeline previews (scrubbing)

See [Timeline scrubbing](/playback/scrubbing) for what these do. All optional; the defaults work.

Five of these are also editable live from the admin console (**Server →
Scrub previews**): the env value below is only the *default* until an
operator sets it in the console, at which point the console value wins (no
restart needed, takes effect within one scan interval / cache-sweep tick).
The other two (`THUMB_CACHE_DIR`, `THUMB_PREGEN_WIDTH`) are env/compose-only,
see the Notes column.

**Compose override needed for the env side.** The base `docker-compose.yml`
doesn't forward any `THUMB_*` key into the api container, so the env
*defaults* below only change if you pass them in via a
`docker-compose.override.yml`. The five console-editable knobs are the
exception: those take effect through the database regardless, because the
console writes them to `server_settings` (which the api reads at runtime),
not to the environment. In short: edit these in the console, not `.env`,
unless you're comfortable wiring a compose override for the two env-only ones.

| Key | Default | Console-editable? | Notes |
|---|---|---|---|
| `THUMB_PREGEN_ENABLED` | `false` | yes | build scrub previews in the background so the *first* drag is instant too; costs some ongoing CPU + disk |
| `THUMB_PREGEN_LOOKBACK_HOURS` | `2` | yes | how far back to build previews when the worker starts (console clamps 0-168h) |
| `THUMB_PREGEN_SCAN_SECS` | `60` | yes | how often to build previews for newly-recorded footage (console clamps 5-3600s) |
| `THUMB_PREGEN_WIDTH` | `480` | **no, env-only** | preview width in pixels; must equal the playback clients' scrub-still width or pre-generated previews go unused (silently wasted CPU/storage), which is why this one stays a deployment-time setting, not a console toggle |
| `THUMB_CACHE_DIR` | (`EXPORT_DIR`) | **no, env-only** | where the preview cache lives; point at an SSD/NVMe mount to keep scrubbing fast on a spinning-disk system (a filesystem mount, not a preference) |
| `THUMB_EXTRACT_MAX_CONCURRENCY` | scales with cores | no | how many previews Crumb builds at once; default is roughly half the CPU cores |
| `THUMB_CACHE_MAX_BYTES` | `21474836480` (20 GiB) | yes | preview cache size budget; oldest previews are dropped past this (console floors it at 100 MiB) |
| `THUMB_CACHE_TTL_SECONDS` | `2592000` (30 days) | yes | preview cache age budget (console clamps 1 hour-1 year) |

## Storage

| Key | Default | Notes |
|---|---|---|
| `MEDIA_HOST_PATH` | `./_data` | host directory bind-mounted into both containers |
| `MEDIA_ROOT` | `/data` | container-side root; all storage paths must live under it |
| `LIVE_STORAGE_PATH` | `/data/live` | default live bucket |
| `ARCHIVE_STORAGE_PATH` | `/data/archive` | default archive bucket; unset means archive shares the live disk |

## GPU / motion decode

| Key | Default | Notes |
|---|---|---|
| `MOTION_HWACCEL` | `auto` | `auto` probes for NVDEC and falls back to CPU; `cuda` forces NVDEC, `cpu` forces software decode |

See [Hardware decode](/configuration/hardware-decode) for enabling this.

## API auth

| Key | Default | Notes |
|---|---|---|
| `JWT_SECRET` | generated | at least 32 bytes; the API refuses to boot on the placeholder value |
| `JWT_EXPIRY_SECONDS` | `86400` | token lifetime, 24 hours |

## API server

| Key | Default | Notes |
|---|---|---|
| `API_BIND` | `0.0.0.0:8080` | Leave this at `0.0.0.0:8080`. Docker already gates host exposure through the compose `ports:` mapping. Setting `127.0.0.1:8080` here does **not** lock the API to the host, it binds container-local, so the published port answers nothing while the healthcheck still passes: a silently dead API. To restrict the API to localhost, change the compose port mapping to `"127.0.0.1:8080:8080"` instead. |

## Export

| Key | Default | Notes |
|---|---|---|
| `EXPORT_DIR` | `/exports` | its own volume, not under the read-only `/data` mount |
| `EXPORT_TTL_SECONDS` | `86400` | how long a completed export survives before cleanup |

## Database backup

See [Backups](/configuration/backups) for the full picture.

| Key | Default | Notes |
|---|---|---|
| `DB_BACKUP_ENABLED` | `true` | |
| `DB_BACKUP_HOST_PATH` | `./backups` | must be writable by uid 1001 |
| `DB_BACKUP_SCHEDULE` | `03:15` | local wall-clock time |
| `DB_BACKUP_KEEP_DAYS` | `7` | |
| `DB_BACKUP_KEEP_WEEKS` | `4` | |
| `DB_BACKUP_KEEP_MONTHS` | `0` | `0` disables the monthly tier |

## Off-host backup copy (optional)

| Key | Default | Notes |
|---|---|---|
| `BACKUP_OFFSITE_REMOTE` | empty | an rclone `remote:path`; leaving this empty makes the optional sidecar idle even if started |
| `BACKUP_OFFSITE_SCHEDULE` | `15 5 * * *` | 5-field cron, not the `HH:MM` form the main backup uses |
| `BACKUP_OFFSITE_RCLONE_CONF` | `./rclone.conf` | keep this file out of the repository, same trust level as `.env` |

## Alerting

| Key | Default | Notes |
|---|---|---|
| `ALERT_WEBHOOK_URL` | empty | a generic JSON webhook (Discord/Slack-compatible) for recorder-death paging; empty means silent |
| `CAMERA_OFFLINE_BOOT_GRACE_SECS` | `180` | holds camera-offline alerts for this long after a recorder restart. **Compose override needed:** not forwarded by the base compose file, set it in a `docker-compose.override.yml`. |
| `MAINTENANCE_UNTIL` | empty | unix-seconds timestamp to pre-arm a maintenance window at boot. **Compose override needed:** not forwarded by the base compose file, set it in a `docker-compose.override.yml`. |

## Update-available check (issue #7)

| Key | Default | Notes |
|---|---|---|
| `UPDATE_CHECK_ENABLED` | `false` | opt-in; when `true`, the api periodically asks github.com for the latest CrumbVMS release tag (version number only, nothing sent) so clients can show an "update available" notice. `false` means zero github.com requests, ever. The admin console's "Enable update checks" toggle (Server section) overrides this once set, DB wins over env. |

## Seed (admin bootstrap)

| Key | Default | Notes |
|---|---|---|
| `SEED_ADMIN_USERNAME` | `admin` | |
| `SEED_ADMIN_PASSWORD` | generated by setup-env.sh | plaintext; setup-env.sh generates a memorable passphrase and the api seeds the admin with it by default. Blank it to opt into the browser create-admin wizard instead |
| `SEED_ADMIN_PASSWORD_HASH` | empty | precomputed argon2id hash, an alternative to the plaintext var above |
| `SEED_DEFAULT_CAMERAS` | `false` | dev-only; keep `false` in any real deployment |

## Image source

| Key | Default | Notes |
|---|---|---|
| `CRUMB_IMAGE_PREFIX` | `ghcr.io/badbread/crumbvms` | point at a different registry/namespace |
| `CRUMB_VERSION` | `latest` | pin a specific tag for reproducible upgrades |

## Frigate integration (optional, bring your own)

All of these are unset by default. See [Integrations](/integrations/frigate)
for the full setup.

| Key | Default | Notes |
|---|---|---|
| `FRIGATE_MQTT_URL` | empty | leaving this unset disables **the Frigate MQTT provider** (no broker connection, no background task). It does not touch Crumb's other detection paths, Home Assistant motion sources and the crumb-alpr LPR ingest work independently of it. |
| `FRIGATE_MQTT_USER` / `FRIGATE_MQTT_PASSWORD` / `FRIGATE_MQTT_PASSWORD_B64` | empty | broker auth, only if required |
| `FRIGATE_MQTT_PREFIX` | `frigate` | |
| `FRIGATE_API_BASE` | empty | fallback; the admin console setting overrides it |
| `FRIGATE_MIN_SCORE` | `0.3` | detection confidence floor |
| `FRIGATE_CATCHUP_HOURS` | `24` | how far back to backfill on startup |

## Crumb-native LPR worker (optional, `alpr` profile)

Crumb's own local plate OCR (fast-alpr), no cloud and no third-party agent.
It's opt-in: nothing runs until you start the `alpr` compose profile with
`docker compose --profile alpr up -d --build crumb-alpr`. First enable LPR and
mint an ingest token in **Admin → LPR** (Rotate ingest token), then set the
keys below. One worker instance per camera. See
[Integrations](/integrations/) for the full setup.

| Key | Default | Notes |
|---|---|---|
| `LPR_INGEST_TOKEN` | empty | the rotated token from Admin → LPR; the worker authenticates its `POST /lpr/reads` calls with it |
| `LPR_CAMERA_ID` | empty | the Crumb camera UUID this worker reads |
| `LPR_RTSP_URL` | empty | the go2rtc restream RTSP for that camera, e.g. `rtsp://<go2rtc-user>:<go2rtc-pass>@recorder:8554/<stream-name>` |
| `LPR_MIN_CONFIDENCE` | `0.80` | drop reads below this mean OCR confidence |
| `LPR_SAMPLE_FPS` | `5` | analysis frame rate while a pass is active |
| `LPR_API_BASE` | `http://api:8080` | override only if the worker runs off-host (mapped to the worker's `CRUMB_API_BASE`) |
| `LPR_LOG_LEVEL` | `info` | worker log verbosity |

The worker reads several more tuning knobs (detector/OCR model names, motion
gating, pass timing) with sensible defaults, see
`services/alpr-worker/worker.py` and its README if you need to tune them.

## Home Assistant (optional, off by default)

A self-hosted integration, off until you enable it. Normally you configure
this in the admin console (**Detection & clips → Home Assistant**), which
stores it in the database, and the DB value wins. The keys below are only a
read-time fallback used when the matching DB field is empty. Use a long-lived
token from a dedicated **non-admin** HA user.

| Key | Default | Notes |
|---|---|---|
| `HA_BASE_URL` | empty | e.g. `http://<home-assistant-host>:8123`; fallback for the console's Home Assistant base URL |
| `HA_TOKEN` | empty | a long-lived access token; a secret. Prefer `HA_TOKEN_FILE` in production. |
| `HA_TOKEN_FILE` | empty | path to a Docker-secret file holding the token, e.g. `/run/secrets/ha_token`; read in preference to `HA_TOKEN` |

**Compose override needed.** The base `docker-compose.yml` doesn't forward
`HA_BASE_URL` / `HA_TOKEN` / `HA_TOKEN_FILE` into the api container, so these
env fallbacks only take effect through a `docker-compose.override.yml`. The
console path (which writes to the database) is the supported way to configure
Home Assistant and needs no compose changes.
