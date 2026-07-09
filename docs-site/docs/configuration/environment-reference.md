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

## PostgreSQL

| Key | Default | Notes |
|---|---|---|
| `POSTGRES_USER` | `crumb` | |
| `POSTGRES_PASSWORD` | generated | strong random value from `setup-env.sh` |
| `POSTGRES_DB` | `crumb` | |
| `DATABASE_URL` | derived | full connection string used by api + recorder |
| `DB_POOL_SIZE` | code default | connection pool size; rule of thumb is roughly `2 * cameras + 10` |

## Streaming (go2rtc)

Crumb's own go2rtc restreamer runs embedded in the recorder container. The
values below are fallbacks: once you set the server's address in the admin
console's Server & streaming settings, that value wins.

| Key | Default | Notes |
|---|---|---|
| `CRUMB_GO2RTC_API_BASE` | empty | leave blank, internal compose defaults are correct |
| `CRUMB_GO2RTC_RTSP_BASE` | empty | leave blank; set the public RTSP address in the admin console instead |
| `GO2RTC_USER` | generated | required; compose fails fast if unset |
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

| Key | Default | Notes |
|---|---|---|
| `THUMB_PREGEN_ENABLED` | `false` | build scrub previews in the background so the *first* drag is instant too; costs some ongoing CPU + disk |
| `THUMB_PREGEN_LOOKBACK_HOURS` | `2` | how far back to build previews when the worker starts |
| `THUMB_PREGEN_SCAN_SECS` | `60` | how often to build previews for newly-recorded footage |
| `THUMB_PREGEN_WIDTH` | `160` | preview width in pixels |
| `THUMB_CACHE_DIR` | (`EXPORT_DIR`) | where the preview cache lives; point at an SSD/NVMe mount to keep scrubbing fast on a spinning-disk system |
| `THUMB_EXTRACT_MAX_CONCURRENCY` | scales with cores | how many previews Crumb builds at once; default is roughly half the CPU cores |
| `THUMB_CACHE_MAX_BYTES` | `21474836480` (20 GiB) | preview cache size budget; oldest previews are dropped past this |
| `THUMB_CACHE_TTL_SECONDS` | `2592000` (30 days) | preview cache age budget |

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
| `API_BIND` | `0.0.0.0:8080` | set `127.0.0.1:8080` for localhost-only |

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
| `CAMERA_OFFLINE_BOOT_GRACE_SECS` | `180` | holds camera-offline alerts for this long after a recorder restart |
| `MAINTENANCE_UNTIL` | empty | unix-seconds timestamp to pre-arm a maintenance window at boot |

## Update-available check (issue #7)

| Key | Default | Notes |
|---|---|---|
| `UPDATE_CHECK_ENABLED` | `false` | opt-in; when `true`, the api periodically asks github.com for the latest CrumbVMS release tag (version number only, nothing sent) so clients can show an "update available" notice. `false` means zero github.com requests, ever. The admin console's "Enable update checks" toggle (Server settings) overrides this once set — DB wins over env. |

## Seed (admin bootstrap)

| Key | Default | Notes |
|---|---|---|
| `SEED_ADMIN_USERNAME` | `admin` | |
| `SEED_ADMIN_PASSWORD` | empty | plaintext; only needed for a headless install, otherwise create the admin in the browser wizard |
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
| `FRIGATE_MQTT_URL` | empty | leaving this unset disables the entire detection subsystem, no background task runs |
| `FRIGATE_MQTT_USER` / `FRIGATE_MQTT_PASSWORD` / `FRIGATE_MQTT_PASSWORD_B64` | empty | broker auth, only if required |
| `FRIGATE_MQTT_PREFIX` | `frigate` | |
| `FRIGATE_API_BASE` | empty | fallback; the admin console setting overrides it |
| `FRIGATE_MIN_SCORE` | `0.3` | detection confidence floor |
| `FRIGATE_CATCHUP_HOURS` | `24` | how far back to backfill on startup |
