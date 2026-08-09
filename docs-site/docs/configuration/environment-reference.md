---
title: Environment reference
sidebar_label: Environment reference
slug: /configuration/environment-reference
---

# Environment reference

The keys Crumb reads from `.env`, grouped by area (a few generic ones like
`RUST_LOG` and `LOG_FORMAT` are omitted, and so are the deep internals that
exist only to make a test or a support session easier). `.env.example` in the
repository carries the same set with inline comments; this page is the browsable
version of it, and the two are kept in step. Most installs never need to touch
most of these, `setup-env.sh` fills in the values that matter for a first boot.

Every key below is wired into the stock `docker-compose.yml` (the GPU keys
ride in via their opt-in overlay files), so the workflow is uniform: set the
key in `.env`, restart the affected container, done. No
`docker-compose.override.yml` is needed. Where a value is also editable in
the admin console, the console value (stored in the database) wins over the
env default; that's flagged in the notes.

Most secret-bearing keys also answer to a `_FILE` twin (`DATABASE_URL_FILE`,
`JWT_SECRET_FILE`, `SEED_ADMIN_PASSWORD_FILE`, `HA_TOKEN_FILE`) holding a path
to read the value from, for Docker secrets. `GO2RTC_USER`/`GO2RTC_PASS` are the
exception: the embedded go2rtc restreamer expands them straight from the
process environment and compose requires the plain vars, so those two don't
support `_FILE`. Only `HA_TOKEN_FILE` gets its own row below, because the
others are mechanical; see [Secrets](/configuration/secrets) for the list.

## Time zone

| Key | Default | Notes |
|---|---|---|
| `TZ` | `UTC` | Local wall-clock for the whole stack: quiet hours, the nightly DB backup schedule (`DB_BACKUP_SCHEDULE`), the offsite-sync cron, and every log timestamp. Set an IANA name like `America/Los_Angeles` or `Europe/Berlin`. `setup-env.sh` detects the host's zone and writes it; if it can't, the compose default is `UTC` (not any local zone), so the clock is at least predictable. |
| `RECORDER_TZ` | inherits `TZ` | IANA zone the recorder's per-camera archive-schedule cron runs in. Unset or empty means it inherits `TZ` above, which is what you want; set it only to run archive schedules in a different zone than the rest of the stack. A value that fails to parse is logged loudly and falls back rather than stopping the recorder. |

## PostgreSQL

| Key | Default | Notes |
|---|---|---|
| `POSTGRES_USER` | `crumb` | |
| `POSTGRES_PASSWORD` | generated | strong random value from `setup-env.sh` |
| `POSTGRES_DB` | `crumb` | |
| `DATABASE_URL` | derived | full connection string used by api + recorder |
| `DB_POOL_SIZE` | `32` | connection pool size. Fixed default of 32, not a per-camera formula. Raise it past ~16 cameras (rule of thumb `2 * cameras + 10`), and raise Postgres `max_connections` to match. Forwarded by the stock `docker-compose.yml` to both api and recorder; set it in `.env` and restart both containers. |

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
| `GO2RTC_AUTH` | empty (auth ON) | optional restream auth opt-out. Leave unset for the secure default (authenticated LAN RTSP restream). Set to `off` to run an OPEN, credential-free restream on a trusted LAN: any LAN client can then pull every camera at `rtsp://<host>:18554/<name>` with no password. Any value other than `off` (including empty) keeps auth ON. The internal go2rtc REST API (`:1984`) stays authenticated regardless, so `GO2RTC_USER`/`GO2RTC_PASS` are still required. |
| `GO2RTC_RTSP_BASE` / `GO2RTC_API_BASE` | empty | a separate, external Frigate go2rtc instance, only used for cameras served by it |

## Recording

| Key | Default | Notes |
|---|---|---|
| `SEGMENT_SECONDS` | `4` | 2 to 6 seconds; short segments mean near-instant seek |
| `SEGMENT_RECEIPT_TIMEOUT_SECS` | `90` | stall watchdog: how long a worker waits for the next segment before it reconnects. Raise it for a long-GOP camera whose keyframe interval exceeds the default. Clamped to `[20, 3600]`; unset or unparseable falls back to the default rather than erroring. |

## Recorder internals

Tuning knobs for the recorder's supervision loops. The defaults are right
for almost everyone; `RECONCILE_PAUSED` is the only one an operator normally
touches, and only during a deliberate storage migration.

| Key | Default | Notes |
|---|---|---|
| `CONFIG_POLL_SECONDS` | `30` | how often the recorder diffs the database camera list against its running workers to pick up config changes |
| `RECONCILE_INTERVAL_SECONDS` | `900` | how often the reconcile pass re-runs (adopt orphan files on disk, repair size drift, prune dangling index rows); floored to 60 |
| `RECONCILE_PAUSED` | `false` | maintenance switch: `true` runs no reconcile passes at all. Set it while deliberately moving footage files out-of-band (storage migration, disk swap), since reconcile would race the move. Recording, motion, and retention continue normally. |

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
The other three (`THUMB_CACHE_DIR`, `THUMB_PREGEN_WIDTH`,
`THUMB_EXTRACT_MAX_CONCURRENCY`) are env-only, see the Notes column.

All of these are forwarded by the stock `docker-compose.yml` into the api
container: set them in `.env` and restart the api. For the five
console-editable knobs, prefer the console anyway; once an operator sets a
value there, the database copy wins and the env value is just the default.

One honest footnote: a few more `THUMB_*` names exist in the source
(`THUMB_INTERVAL_SECS`, `THUMB_MAX_ATTEMPTS`, `THUMB_MAX_WIDTH`,
`THUMB_MIN_WIDTH`, `THUMB_NEAR_BLACK_LUMA`, `THUMB_EXTRACT_TIMEOUT_SECS`) as
fixed built-in constants (a 4-second preview grid, widths clamped 48-640, a
12-second extract timeout, and the black-frame retry logic). They are *not*
read from the environment and the compose file deliberately does not forward
them, because forwarding a name implies a tunability that does not exist.
Setting them in `.env` does nothing, so they don't get rows here.

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
| `MEDIA_HOST_PATH` | `./_data` | host directory bind-mounted into both containers. It must be writable by **uid 1001**, the user the recorder runs as, or nothing records while live view still looks fine. `setup-env.sh` reads this key as an input, prepares the directory when it can, and preflights it either way, see [Platform notes](/getting-started/platform-notes) |
| `MEDIA_ROOT` | `/data` | container-side root; all storage paths must live under it |
| `LIVE_STORAGE_PATH` | `/data/live` | default live bucket |
| `LIVE_STORAGE_NAME` | `Live` | display name for the live bucket in the console and clients; cosmetic, and only read when the bucket is first created |
| `ARCHIVE_STORAGE_PATH` | `/data/archive` | default archive bucket; unset means archive shares the live disk |
| `ARCHIVE_STORAGE_NAME` | `Archive` | display name for the archive bucket, same rules as above |
| `MIN_FREE_FRACTION` | `0.05` (5%) | free-space floor as a fraction of the disk, `0.0` up to but not including `1.0`. Eviction starts before the disk fills rather than after. An unparseable or out-of-range value falls back to the default without complaining. Re-read on every sweep, so a change takes effect without a restart. A per-policy override, set in the console, replaces it for that policy. See [Storage tiers](/recording/storage-tiers) |
| `MIN_FREE_BYTES` | `53687091200` (50 GiB) | absolute free-space floor. The **stricter** of this and `MIN_FREE_FRACTION` wins, with one guard: if the absolute floor is at least half the disk it is ignored entirely, so a small test disk isn't permanently in eviction. Free space is measured as blocks available to a non-privileged writer, so the filesystem's root reserve doesn't count as free |

## GPU / motion decode

| Key | Default | Notes |
|---|---|---|
| `MOTION_HWACCEL` | `cpu` | `cpu` (the default) forces software decode: it works on any host and is cheap at the ~320px/5fps analysis resolution. `vaapi` forces an Intel/AMD iGPU, `cuda` forces NVDEC. `auto` picks NVDEC only when the recorder can actually create an NVIDIA decode device at startup (it asks ffmpeg to open one, not just whether ffmpeg was built with cuda), and uses `cpu` otherwise, so `auto` on a GPU-less host is software decode, not broken motion. Whatever you pick, a hardware backend that fails to decode a camera is dropped to CPU for that camera and the reason is shown in the console's decode-status panel. The admin console setting (`server_settings.motion_hwaccel`) overrides this, DB wins over env. Only affects motion decode; recording is always stream-copy |
| `MAX_GPU_DECODE_SESSIONS` | `4` | global cap on concurrent NVDEC decode sessions; a camera past the cap decodes on CPU instead of failing |
| `MOTION_VAAPI_DEVICE` | `/dev/dri/renderD128` | DRI render node used when `MOTION_HWACCEL=vaapi`; wired in by the `docker-compose.vaapi.example.yml` overlay, ignored otherwise. On a multi-GPU host prefer the stable `/dev/dri/by-path/pci-<addr>-render` symlink, `renderD*` numbers can reorder across a driver upgrade + reboot. Also overridden by the DB (`server_settings.motion_vaapi_device`). See [Hardware decode](/configuration/hardware-decode) |
| `RENDER_GID` | `993` | host `render` group GID, read by the VAAPI overlay's `group_add` (not by Crumb itself) so the uid-1001 container user can open the render node; find yours with `getent group render` |
| `NVIDIA_VISIBLE_DEVICES` | `all` | which GPUs the NVIDIA container runtime exposes to the recorder; read by the runtime, not by Crumb. Wired in by `docker-compose.gpu.example.yml`, ignored otherwise. Narrow it to a device index or UUID on a host whose other GPUs belong to something else |

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
| `CRUMB_HTTPS_PORT` | `8443` | the port the bundled Caddy serves HTTPS on. Read by Caddy, not by Crumb, and used on **both** sides of the compose port mapping because the Caddyfile binds the templated port; changing it needs the caddy container recreated, not just restarted. The api's plain `:8080` is unaffected. See [TLS](/configuration/tls) |
| `TRUST_PROXY` | unset (off) | tells the api to take the client address from the first hop of `X-Forwarded-For` instead of the TCP peer, for rate-limiting purposes only. Set it when the api sits behind a reverse proxy, including the bundled Caddy: without it every HTTPS request keys on the proxy's container IP, so all your HTTPS users share one rate-limit bucket. Do **not** set it when the api is reachable directly, because then a client can forge its own bucket key. This is a set/unset flag, not a boolean: any non-empty value turns it **on**, including `TRUST_PROXY=false`. Read once at startup, so restart the api after changing it. |

## Export

| Key | Default | Notes |
|---|---|---|
| `EXPORT_DIR` | `/exports` | its own volume, not under the read-only `/data` mount |
| `EXPORT_TTL_SECONDS` | `86400` | how long a completed export survives before cleanup |
| `EXPORT_CACHE_MAX_BYTES` | `21474836480` (20 GiB) | size budget for the on-disk export cache; oldest entries are dropped past it |

## Streams the server generates on demand

Crumb builds two derived streams lazily, only while something is watching. Both
are sized for a phone on a slow link.

| Key | Default | Notes |
|---|---|---|
| `MOBILE_STREAM_ENABLED` | `true` | the on-demand H.264 transcode that mobile clients fall back to when a camera's own streams won't decode on the device, notably a camera that is H.265 all the way down. Turning it off saves server CPU and costs those cameras live view on Android |
| `MOBILE_STREAM_WIDTH` | `640` | transcode width in pixels, floored at 160 |
| `MAIN_REPAIR_TRANSCODE_ENABLED` | `false` | opt-in, per-camera full-resolution H.265 to H.264 transcode of a main stream whose SDP has no `fmtp` attribute. Android's video player rejects such a main ("missing attribute fmtp", seen on some Uniview LPR cameras) and otherwise steps down to the H.264 sub in SD. Leave it off and those cameras play in SD on Android; turn it on to get HD, at the cost of recorder CPU while an Android viewer is watching that camera fullscreen. A cheaper copy-only repair does not work for this case, which is why it is a real re-encode and off by default. The cheapest fix of all, when the camera allows it, is to set the camera's main stream to H.264 in its own web UI |
| `SEGMENT_LOW_CACHE_MAX_BYTES` | `2147483648` (2 GiB) | size budget for the cache of low-resolution playback segments |

## Database backup

See [Backups](/configuration/backups) for the full picture.

| Key | Default | Notes |
|---|---|---|
| `DB_BACKUP_ENABLED` | `true` | only `false`, `0`, `no`, or `off` opts out |
| `DB_BACKUP_HOST_PATH` | `./backups` | host directory holding the dumps; must be writable by uid 1001 |
| `BACKUP_DIR` | `/backups` | the container-side path the above is mounted at. Leave it alone: if it is unset or empty the api disables the backup job entirely, which is not a failure you want to discover from a missing dump |
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
| `CAMERA_OFFLINE_BOOT_GRACE_SECS` | `180` | holds camera-offline alerts for this long after a recorder restart. Forwarded by the stock `docker-compose.yml`; set it in `.env` and restart the api container. |
| `MAINTENANCE_UNTIL` | empty | unix-seconds timestamp to pre-arm a maintenance window at boot. Forwarded by the stock `docker-compose.yml`; set it in `.env` and restart the api container. |
| `MOTION_UNHEALTHY_ALERT_SECS` | `180` | how long a camera's motion detector must stay *continuously* unhealthy before the recorder raises a system alert. This is alert hysteresis for flaky cameras that blip and self-heal; it delays only the alert, never the fail-open recording safety rail. A camera added with a main stream only (no sub-stream) never raises this alert at all: pixel motion needs the sub-stream, so that camera records continuously by design rather than being broken. |

## ONVIF (PTZ, presets, focus)

| Key | Default | Notes |
|---|---|---|
| `ONVIF_CONFIG_B64` | empty | a legacy fallback, and normally left blank. Per-camera ONVIF host and credentials live in the database and are edited in the admin camera editor, which always wins. This key holds the pre-database form: a base64-encoded JSON object keyed by each camera's go2rtc stream name. It is base64 so the JSON survives `.env` and compose substitution unmangled; the raw `ONVIF_CONFIG` name is still read if the base64 one is empty. `setup-env.sh` writes the key blank |

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
| `FRIGATE_MQTT_URL` | empty | leaving this unset disables **the Frigate MQTT provider** (no broker connection, no background task). It does not touch Crumb's other detection paths, Home Assistant motion sources and the crumb-alpr LPR ingest work independently of it. **Plaintext `mqtt://` only** (or a bare `host:port`). Crumb's MQTT client is built without a TLS transport, so an `mqtts://` URL is refused with a clear error instead of being connected in the clear, keep the broker on a trusted LAN. |
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
this in the admin console (its own **Home Assistant** section), which
stores it in the database, and the DB value wins. The keys below are only a
read-time fallback used when the matching DB field is empty. Use a long-lived
token from a dedicated **non-admin** HA user.

| Key | Default | Notes |
|---|---|---|
| `HA_BASE_URL` | empty | e.g. `http://<home-assistant-host>:8123`; fallback for the console's Home Assistant base URL |
| `HA_TOKEN` | empty | a long-lived access token; a secret. Prefer `HA_TOKEN_FILE` in production. |
| `HA_TOKEN_FILE` | empty | path to a Docker-secret file holding the token, e.g. `/run/secrets/ha_token`; read in preference to `HA_TOKEN` |

All three are forwarded by the stock `docker-compose.yml` into both the api
and recorder containers: set them in `.env` and restart both. The console
path (which writes to the database) is still the supported way to configure
Home Assistant, and the DB value wins whenever both are set.
