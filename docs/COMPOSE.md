# The Compose file, explained

`docker-compose.yml` is intentionally terse: it's the config, not the manual.
This doc is the manual. It walks the stack service by service and captures the
"why" (and the foot-guns) that used to live as long comment blocks inside the
file. If you're just installing, you don't need any of this, follow
[docs/AI-INSTALL.md](AI-INSTALL.md) or the README. Read this when you're editing
the Compose file or debugging the stack.

## How the stack is run

The base stack boots **GPU-free on any Docker host** and is **manually
managed** — `docker compose up -d` / `docker compose down`. It is not adopted by
doco-cd or Portainer; `docker compose down` is the kill switch.

```bash
./scripts/setup-env.sh   # writes .env with strong generated secrets
docker compose pull      # fetch the prebuilt api/recorder images (docs/IMAGES.md)
docker compose up -d      # boots; create your admin at http://<host>:8080/admin
```

- **Build from source** instead of pulling (developers, air-gapped, or before a
  fork has published images): add the build overlay.
  ```bash
  docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
  ```
  There is no `build:` stanza in the base file by design, so a stock
  `up -d` never triggers a Rust compile. See [docs/IMAGES.md](IMAGES.md).
- **GPU decode** (optional NVDEC / VAAPI): add the matching overlay. Without it,
  `MOTION_HWACCEL=auto` resolves to CPU, so motion still works with no GPU.
  ```bash
  docker compose -f docker-compose.yml -f docker-compose.gpu.example.yml up -d     # NVIDIA/NVDEC
  docker compose -f docker-compose.yml -f docker-compose.vaapi.example.yml up -d   # Intel/AMD iGPU
  ```

The `x-logging` anchor pins **json-file logging with rotation** on the crumb
services so `docker logs` is reliable regardless of the host daemon's default
driver. (A host whose Docker default was a `syslog` driver with no listener once
silently dropped recorder logs, leaving a footage-loss incident forensically
blind.) It's bounded so logs can't fill the disk. Note: no docker log driver
survives a container **recreate** — ship logs to an external aggregator if you
need retention across deploys.

## postgres

The **api/recorder embedded migration runner** (`crumb_common::db::run_migrations`)
is the **single source of truth** for the schema: it applies every migration in
filename order on boot and records each in `schema_migrations`.

> **Do NOT also mount `db/migrations` into `/docker-entrypoint-initdb.d`.**
> Postgres would run the SQL on *first init without recording it*, so
> `run_migrations` would then see a fully-built schema with an empty
> `schema_migrations`, misfire its baseline, and fail to re-apply the view
> migrations (0019's `CREATE OR REPLACE VIEW` can't replace the already-wider
> 0042 view: "cannot drop columns from view"), booting a broken schema.

No host port is published by default. Uncomment the `ports` line to inspect the
DB locally on `127.0.0.1:5432`.

## recorder (and the embedded go2rtc)

The recorder image bakes in Crumb's **own go2rtc restreamer** (the same pinned
upstream version the old standalone `go2rtc` service ran). It's spawned and
supervised by the recorder process itself (`services/recorder/src/go2rtc_embed.rs`).
The recorder is the right host because it restarts rarely — an **api** restart
must never drop live client streams. Crumb manages go2rtc streams at **runtime**
via go2rtc's REST API (PUT/DELETE + a reconcile loop from the `cameras` table);
the committed `./go2rtc/go2rtc.yaml` holds **listener config only** — never
hand-add cameras or credentials there.

The `go2rtc` **network alias** on the recorder keeps old installs working: an
`.env` (or stale DB setting) that still says `go2rtc:1984` / `rtsp://go2rtc:8554`
resolves to the recorder (which now hosts go2rtc) instead of NXDOMAIN.

### § go2rtc — the security model (P0-GO2RTC)

go2rtc's REST API (`:1984`) has **no host publish** — it lives inside the
recorder container, reachable only over the internal compose network as
`recorder:1984`. Left LAN-exposed, anyone on the network could enumerate/PUT/
DELETE any camera stream via the REST API, bypassing Crumb's JWT/RBAC/per-camera
grants.

- The **api** reaches the REST API at `recorder:1984` for the reconcile
  PUT/DELETE loop and the MSE/WebRTC-SDP/frame.jpeg proxies, authenticating with
  Basic auth (`GO2RTC_USER`/`GO2RTC_PASS`) — Docker bridge traffic is not
  "localhost" to go2rtc, so its `local_auth` still applies.
- **RTSP** (`:8554` → published as `18554`) **is** LAN-exposed and go2rtc
  **requires RTSP auth**. The api embeds the credentials into the
  `rtsp://user:pass@host:18554/<name>` URLs it hands out via
  `GET /cameras/{id}/streams`, so anonymous LAN watching is blocked but
  authorized desktop/Android clients need no changes. (The recorder's own ffmpeg
  reaches RTSP over true loopback, which go2rtc exempts from auth.)
- **WebRTC signaling** goes through the authenticated api SDP proxy
  (`POST /live/{camera_id}/webrtc`); iOS uses this. The WebRTC **media** plane
  (ICE, `:8556`) is LAN-exposed but only carries the negotiated video of an
  already-authorized session — no stream-management surface. Port is **8556**,
  not go2rtc's default 8555, so a host-network Frigate/go2rtc can keep 8555.
- **MSE/fMP4** (`GET /live/{camera_id}/stream.mp4`) and **JPEG stills**
  (`GET /cameras/{camera_id}/frame.jpg`) remain fully api-proxied.

> **Residual risk:** RTSP + WebRTC-media auth is a single **shared** credential,
> not per-user/per-camera. Anyone who extracts it (packet capture, a compromised
> client, decompiling an app) can watch any camera over RTSP — the same model a
> commercial VMS or Frigate uses. This is defense-in-depth against opportunistic
> LAN scanning, **not** a replacement for the api's per-user JWT/RBAC on the
> MSE/WebRTC-signaling/JPEG planes.

### recorder volumes and the motion RAM cache

- `${MEDIA_HOST_PATH}:/data` — one broad media root, **read-write** (the
  recorder owns all writes). Add a disk by mounting it under the host media dir
  and adding the storage path `/data/<subdir>` in the admin UI; no compose edit
  needed.
- `/proc:/host/proc:ro` — lets the per-camera resource sampler translate NVML's
  host PIDs to container PIDs (via NSpid) so the Statistics GPU% column
  attributes decode to the right camera. Optional; remove it and GPU% degrades
  to `—`, CPU/Mem unaffected.
- The **tmpfs `/cache`** is the RAM-backed motion pre/post-roll ring buffer
  (see [docs/MOTION-RECORDING.md](MOTION-RECORDING.md)). Cameras in recording
  mode **Motion** buffer here and only persist to `/data` on an actual motion
  trigger; idle footage evaporates with zero idle disk writes. A spill persists
  the oldest buffered segments to `/data` rather than losing them.

> **`mode: 01777` on the tmpfs is load-bearing.** The recorder runs as non-root
> (uid 1001) and must `mkdir /cache/motion/<camera>/`. Without world-writable +
> sticky, the tmpfs mounts root-owned `0755`, mkdir fails with `EACCES`, and the
> recorder **silently falls back to direct-to-storage** — Motion mode then
> records everything. Size the cache via `MOTION_CACHE_TMPFS_BYTES` (default
> 512 MiB); the `memory: 4g` limit already covers it (tmpfs pages count against
> the container cgroup), so raise both together if you size it up.

The recorder **healthcheck** verifies the recorder is PID 1 (it has no HTTP
server; it exec's to become PID 1, so a dead recorder = a dead container).

Forwarded env knobs on this service: `RECORDER_TZ` overrides the recorder's
timezone independently (it inherits `TZ` when unset);
`HA_BASE_URL`/`HA_TOKEN`/`HA_TOKEN_FILE` wire the optional Home Assistant
integration (token inline, or read from a mounted file); `DB_POOL_SIZE` sizes
the sqlx connection pool (empty = the code default).

## api

Serves the HTTP API and the web admin console at `/admin` on `:8080`. Every
protected endpoint requires a JWT; the open (unauthenticated) endpoints are
`/health`, `/version`, `/metrics` (Prometheus scrape, no secrets), the `/admin`
page itself, `/auth/login`, and the first-run
`/auth/needs-bootstrap` + `/auth/setup-status` + `/auth/bootstrap`.

- Mounts the **same media root read-only** (`/data:ro`) — the api only reads
  recorded files; the recorder owns writes. Storage paths added in the UI must
  live under `MEDIA_ROOT` so both containers see them.
- **`EXPORT_DIR` defaults to a top-level `/exports`, not under `/data:ro`.**
  Docker can't create a nested mountpoint inside a read-only bind on a fresh
  install (the subdir wouldn't exist yet), which left the api stuck in
  `Created`. Exports live on their own `crumb_exports` volume.
- Stream-base env vars are **fallbacks only**; the admin "Server & streaming"
  settings (`server_settings` table) override them per request. With that table
  empty, the internal compose service names serve the web UI's live MSE/WebRTC.
- **Frigate detection is optional and bring-your-own.** Point `FRIGATE_MQTT_URL`
  at the broker your own Frigate already publishes to and set each camera's
  Frigate name in the admin UI. Empty `FRIGATE_MQTT_URL` ⇒ the whole detection
  subsystem stays disabled.
- Other forwarded knobs: the same `HA_BASE_URL`/`HA_TOKEN`/`HA_TOKEN_FILE`
  (Home Assistant) and `DB_POOL_SIZE` as the recorder; `MAINTENANCE_UNTIL`
  (unix seconds) suppresses low-disk/camera-offline alerts during planned
  maintenance; `CAMERA_OFFLINE_BOOT_GRACE_SECS` is the grace period before
  offline alerts fire after boot (empty = default 180); and the `THUMB_*` set
  tunes the timeline thumbnail cache and pre-generation (cache dir, size cap,
  TTL, extract concurrency and timeout, widths, pre-gen toggle and lookback).
  All default sensibly when unset; see [`.env.example`](../.env.example).

### Built-in nightly DB backup (P0-BACKUP)

The `segments` table is the **sole** mp4→camera/time index — lose it and the
`.mp4` files on disk are effectively unplayable. The api runs a daily `pg_dump`
(03:15 local by default) with daily/weekly/monthly rotation into the `/backups`
mount, on by default, plus a catch-up dump on boot when the newest backup is
stale. This replaced the old `db-backup` sidecar (same on-disk layout, one less
image); failures surface through the `backup_failed` system alert.

> Point `DB_BACKUP_HOST_PATH` at a **different disk** than the live recordings,
> and `chown -R 1001:1001` it (the api's uid). If it isn't writable, the api
> logs a warning and disables backups — it never fails the container. See
> [docs/BACKUP.md](BACKUP.md).

## caddy (optional TLS)

Reverse-proxies the api and terminates **HTTPS on `:8443`**. Additive: the api
keeps publishing plain HTTP on `:8080` unchanged, so existing clients that
hardcode `http://host:8080` keep working. Default is Caddy's **internal CA** (a
local self-signed leaf, no ACME, no domain, no port-forwarding). Remove the
service entirely to drop TLS; nothing depends on it.

> The published and container-side ports both use `${CRUMB_HTTPS_PORT}` — the
> Caddyfile binds `{$CRUMB_HTTPS_PORT}`, so a hardcoded container-side port would
> forward to a dead port the moment an operator customized it. Keep both on the
> same var. See [docs/TLS.md](TLS.md).

## mosquitto (opt-in `frigate` profile)

A bundled MQTT broker for the Frigate integration, **profile-gated** so a plain
`up -d` never starts it. You only need it if you don't already have a broker.
Bound to `127.0.0.1:1883` **on the Crumb host only** — so it's reachable by a
Frigate running on the *same* host, but **not** by a Frigate on another box. If
your Frigate lives elsewhere, give it its own broker rather than exposing this
one to the LAN (the localhost bind is deliberate; don't widen it by default).

```bash
docker compose --profile frigate up -d            # stack + bundled broker
docker compose --profile frigate up -d mosquitto  # just the broker, later
```

## crumb-alpr (opt-in `alpr` profile)

Crumb's own local license-plate OCR worker (fast-alpr), **profile-gated** so a
plain `up -d` never starts it. One instance per camera: it pulls that camera's
go2rtc restream, motion-gates, runs plate recognition, and POSTs reads to the
api's `POST /lpr/reads`. Enable LPR and mint an ingest token in Admin → LPR
first, then set the env knobs: `CRUMB_API_BASE` (defaults to the internal
`http://api:8080`), `LPR_INGEST_TOKEN`, `LPR_CAMERA_ID`, and `LPR_RTSP_URL`.
Built from source (no published image yet); the full knob table is in
[services/alpr-worker/README.md](../services/alpr-worker/README.md).

```bash
docker compose --profile alpr up -d --build crumb-alpr
```

## backup-offsite (opt-in `offsite` profile)

The api's built-in backup writes to `DB_BACKUP_HOST_PATH`, which is still a
directory on **this** host — a fire/theft/PSU event takes out the segments
index, the footage, and the backups together. This service closes that gap by
periodically pushing that directory to an off-host rclone remote (SFTP/S3/B2/NAS,
~70 backends). **Off by default**, gated behind the `offsite` profile; empty
`BACKUP_OFFSITE_REMOTE` ⇒ the container idles as a no-op instead of failing.

```bash
docker compose --profile offsite up -d
```

Simpler alternative that needs no extra service: point `DB_BACKUP_HOST_PATH`
itself at a NAS/NFS mount so the api writes off-host directly. Use one or the
other, not both. See [docs/BACKUP.md](BACKUP.md).

## Environment variables

The Compose file lists each service's env vars with their defaults inline. The
**canonical, annotated list of every knob** (with sizing rules of thumb) is
[`.env.example`](../.env.example); `scripts/setup-env.sh` generates a working
`.env` with strong secrets from it. Required secrets fail fast at
`docker compose up` with a clear message if missing (e.g. `GO2RTC_USER is
required (run scripts/setup-env.sh)`).

## Upgrading from an older install

- **Embedded go2rtc:** the standalone `go2rtc` service was folded into the
  recorder container. Drop the old container with
  `docker compose up -d --remove-orphans`. If your `.env` still pins
  `CRUMB_GO2RTC_API_BASE=http://go2rtc:1984`, delete that line (blank ⇒ the
  compose defaults are correct); it keeps working either way via the recorder's
  `go2rtc` network alias, and migration 0036 resets a stale DB-held value.
- **db-backup sidecar:** the nightly dump is now built into the api (same
  on-disk layout). A leftover `db-backup` container from an older deploy is
  removed by the same `--remove-orphans`.
