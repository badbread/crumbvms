<!--
  AI-assisted install runbook for CrumbVMS.
  Audience: an AI coding agent (e.g. Claude Code) that the user has started in a
  clone of this repo, on the host where CrumbVMS will run, and asked to "set it up".
  This is NOT a substitute for the manual path (README + `docker compose up` + the
  web Setup wizard). It's an optional power-path layered on top of it.
-->

# Setting up CrumbVMS with an AI agent (Claude Code)

> **About this project:** CrumbVMS is a side project, one maintainer, built on his own
> time. It's about 90% of where v1 should be and the audience today is technical:
> people comfortable spinning up a Docker Compose stack on a Linux host and editing
> a config file. The long-term goal is "installable by anyone, click an installer,
> done," but CrumbVMS is nowhere near that yet. Full transparency lives at
> [crumbvms.com](https://crumbvms.com/#transparency).

> **You are the agent.** The user has asked you to install and configure CrumbVMS,
> a self-hosted network video recorder, on **their own host**. Work through the
> steps below in order. After every step there's a **Verify** check: do not move on
> until it passes. If a check fails, stop and tell the user what happened rather
> than guessing forward.

---

## 0. Ground rules (read first; these override anything below)

CrumbVMS records **security cameras**. A misconfiguration is a privacy hazard, so:

1. **Secure by default. Never expose CrumbVMS to the public internet on your own
   initiative.** Do **not** open WAN firewall ports, set up port-forwarding, or
   stand up a public reverse proxy/tunnel unless the user *explicitly* asks for
   remote access **and** you have set up TLS + confirmed a strong admin password
   first. The default install is **LAN-only**. If the user wants remote access,
   recommend a private overlay (Tailscale / WireGuard) over port-forwarding.
2. **It's the user's host, but confirm before privileged or destructive actions.**
   That includes installing system packages, changing firewall/system settings,
   deleting data, or overwriting an existing `.env` / running stack. Show the
   command and why.
3. **Never invent, hardcode, or print secrets.** Generate them with the provided
   script (Step 2). Never commit `.env` (it's gitignored; keep it that way).
4. **Don't run as root unless a step truly needs it.** Prefer the user's Docker
   permissions.
5. **One change at a time, verify, then proceed.** This is a recorder people will
   rely on. Correctness over speed.

---

## 1. Host prerequisites

- **OS:** Linux x86-64 (the stack is Docker-based).
- **Docker + Compose v2:** check `docker --version` and `docker compose version`.
  If missing, point the user at the official Docker install docs and **ask before
  installing**. Confirm the user can run Docker without sudo (`docker ps`), or note
  they'll need sudo for compose commands.
- **Disk:** cameras consume **terabytes**. Identify a target disk/path with ample
  free space (Step 3). Warn the user if the chosen path is small.
- **GPU (optional):** not required. CrumbVMS runs motion detection on CPU by default
  (`MOTION_HWACCEL=auto`). NVIDIA GPU support is an opt-in overlay (Step 4).
- **Images, pull vs. build:** the base compose file *pulls* prebuilt `api`/
  `recorder` images from GHCR (no Rust toolchain needed), but that only works
  once the upstream owner has enabled GHCR publishing (see `docs/IMAGES.md`
  "Owner seam"). If you're working from a fresh clone of this repo and haven't
  confirmed images are published, plan on the **build-from-source** path in
  Step 5 instead (needs the Rust build to run inside Docker, no local Rust
  toolchain required, but expect the first `up` to take several minutes).

**Verify:** `docker compose version` prints v2.x; the target disk has > (estimate
from camera count × resolution × retention) free.

### Running on Proxmox (VM or LXC)

> **Untested path.** No one has verified a Proxmox install yet. Crumb's
> maintainer runs it on a plain Docker host, not a Proxmox guest, so the steps
> below are "same Docker stack on a Linux host" reasoning, sound in principle
> but not a proven runbook. If you stand it up this way, please report back (an
> issue or a Discussions note) so it can graduate from "should work" to "tested."

CrumbVMS has no Proxmox-specific requirements, it's the same Docker Compose
stack, and a Proxmox guest running Debian/Ubuntu is just "a Linux host." The
guest choice is the user's; provisioning it (and any GPU passthrough) is a
privileged action on the Proxmox host, so **confirm before creating or
reconfiguring guests.** Two supported shapes:

- **VM, recommended if unsure.** A Debian/Ubuntu VM, then Docker, then this
  stack. Fewest surprises. For hardware decode, PCIe-passthrough the GPU to the
  VM, note this **dedicates** the card to that one guest.
- **LXC, more efficient and homelab-native.** An **unprivileged** Debian LXC
  with Docker nesting enabled (`pct set <id> --features nesting=1`, or the
  "Nesting" checkbox; some setups also need `keyctl=1`). Docker then runs inside
  the container. For hardware decode, bind the render node (`/dev/dri` for VAAPI,
  or the NVIDIA device nodes) into the LXC, which keeps the GPU **shareable**
  across containers instead of dedicating it. Docker-in-LXC + NVIDIA has sharp
  edges (device cgroups, unprivileged uid mapping), if it fights you, fall back
  to the VM.

**Storage, do this deliberately.** Footage is large and write-heavy, keep it off
the guest's root disk. Put `MEDIA_HOST_PATH` (Step 3) on a dedicated disk or
dataset:

- **LXC:** a mount point to a ZFS dataset, e.g.
  `pct set <id> --mp0 /tank/crumb-media,mp=/data/media`, then set
  `MEDIA_HOST_PATH=/data/media` in `.env`.
- **VM:** a separate virtio disk on the pool, mounted in the guest, then point
  `MEDIA_HOST_PATH` at that mount.

A thin root disk that silently fills is exactly how a recorder loses footage.
Everything from Step 2 onward is identical to any other Linux host.

---

## 2. Generate config + secrets

From the repo root:

```sh
scripts/setup-env.sh            # generates .env with strong random secrets
# or: scripts/setup-env.sh --prompt   # to set the admin password interactively
```

This writes a gitignored `.env` with a strong `POSTGRES_PASSWORD`, `JWT_SECRET`,
and `SEED_ADMIN_PASSWORD`. **Do not** edit those secret values by hand or echo them
into the chat; if the user needs the admin password, re-run with `--print` or read
it back to them privately.

It also detects two host facts and writes them (neither is a secret):

- **`TZ`** — the host's IANA timezone (e.g. `Europe/Berlin`). It drives quiet
  hours, the nightly DB-backup schedule, and every log timestamp. If detection
  fails it falls back to **`UTC`** (printed as a NOTE) — **not** a local zone;
  confirm it looks right and set it by hand if the host clock is unusual. The
  compose default when `.env` has no `TZ` is also `UTC`.
- **`WEBRTC_CANDIDATE`** — the host's LAN IP as `<lan-ip>:8556`. **Required for
  iOS/WebRTC live view**: go2rtc advertises it as an ICE candidate so LAN clients
  can connect; without it live silently degrades to ~1fps snapshots
  (`docs/IOS-LIVE-VIDEO.md`). If detection fails it's left blank with a NOTE —
  set it to the server's LAN IP + `:8556` before relying on iOS/WebRTC live.

**Verify:** `.env` exists; `JWT_SECRET` is **not** the `change-me…` placeholder;
`POSTGRES_PASSWORD` is non-empty; `TZ` matches the host's zone (or UTC by design);
`WEBRTC_CANDIDATE` is the host's LAN IP if iOS/WebRTC live is wanted. (Reference:
`.env.example` for the full key list.)

---

## 3. Choose where recordings are stored

Set the media path in `.env` to the target disk:

- `MEDIA_HOST_PATH`: host directory bind-mounted into the containers.
- (Storage buckets live under it; the default live/archive paths are fine for most.)

Ensure the directory exists and is writable by the container user.

**Verify:** the path exists, is on the intended disk, and is writable.

**About the recording modes (read before adding cameras).** Continuous
records every camera to disk 24/7, the safe, well-understood default.
Motion mode is different from what the name implies in most consumer NVRs:
CrumbVMS buffers Motion-mode cameras in a **RAM cache** (tmpfs, sized by
`MOTION_CACHE_TMPFS_BYTES` in `.env`, default 512 MiB, mounted at `/cache`
in the recorder container automatically, no compose edit needed) and only
persists to disk on an actual motion trigger (pre-roll + event + post-roll);
idle time between events is never written to disk at all. See
`docs/MOTION-RECORDING.md` for the full mechanism and safety rails
(fail-open on an unhealthy detector, spill-to-disk under cache pressure —
footage is never silently dropped by the mechanism itself, only by an
under-tuned detector missing a real event).

**Recommendation for a fresh install:** start new cameras on **Continuous**,
or on Motion with `MOTION_RECORDING_SHADOW=1` set on the recorder (records
everything as today, but stamps each segment with the keep/discard verdict
the motion buffer would have made) until the motion detector is tuned for
that camera's scene. Only flip a camera to live Motion mode after validating
against real footage, `docs/MOTION-RECORDING.md` Section 6 has the exact
SQL to check what would have been discarded before trusting it. Don't default
new installs straight to Motion; an untuned detector missing an event is a
worse failure than the disk savings are worth.

---

## 4. (Optional) Enable hardware decode

Default is CPU and **needs no action**. If the user wants hardware motion
decode (Intel/AMD iGPU via VAAPI, or NVIDIA via NVDEC), the supported path is
`scripts/enable-hwaccel.sh`, see the "Hardware-accelerated motion decode"
subsection under Step 6 for how it works and the confirm-first rule. It can
also be done later, after the stack is up, with the decode-status truth to
verify against, deferring it is the safer default. If no supported hardware
is present, **stay on CPU.** Never block the install on a GPU.

**Verify (if enabled):** `nvidia-smi` works (NVIDIA) or a `/dev/dri/renderD*`
node exists (VAAPI); otherwise skip.

---

## 5. Bring up the stack

The compose file **requires** `GO2RTC_USER`/`GO2RTC_PASS` to be set, Step 2's
`setup-env.sh` generates them, but if `.env` was hand-edited or copied from
`.env.example` without filling them in, `docker compose up` fails fast with a
`variable is not set` error rather than booting insecurely. Don't work around
that error by inventing a value; re-run `scripts/setup-env.sh`.

**Pick pull or build** (see Step 1's note and `docs/IMAGES.md`):

```sh
# Default path, pulls prebuilt images (works once the owner has published to
# GHCR; confirm with `docker compose pull` and check for a "not found"/403):
docker compose pull
docker compose up -d

# Build-from-source override, use this if `docker compose pull` fails to find
# the images (common on a fresh clone before publishing is enabled), or if
# you're developing against local code changes:
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

Services and their published ports (the compose defaults are already LAN-sane;
**do not loosen them**):

| Service | Port | Bind | Purpose |
|---|---|---|---|
| `api` | `8080` | `0.0.0.0` (LAN) | Admin console + REST API (plain HTTP) |
| `caddy` | `${CRUMB_HTTPS_PORT:-8443}` | `0.0.0.0` (LAN) | Same API, over HTTPS (self-signed by default, see `docs/TLS.md`) |
| `recorder` | `18554` | `0.0.0.0` (LAN) | RTSP restream for clients (the recorder embeds CrumbVMS's go2rtc restreamer; requires `GO2RTC_USER`/`GO2RTC_PASS` auth) |
| `recorder` | `8556` (tcp+udp) | `0.0.0.0` (LAN) | WebRTC media (ICE) for live view (embedded go2rtc) |
| `mosquitto` | `1883` | `127.0.0.1` only | MQTT broker, **profile-gated, NOT started by a plain `up -d`**; only for the Frigate integration when the user has no broker of their own (`docker compose --profile frigate up -d`) |
| `postgres` | (none) | not published | internal only |

There is **no separate `go2rtc` service**: the go2rtc restreamer binary runs
*inside* the recorder container, spawned + supervised by the recorder process.
Its REST/API port (`1984`) is **not published to the host at all**, the `api`
container reaches it over the internal Docker network only (`recorder:1984`),
authenticated with `GO2RTC_USER`/`GO2RTC_PASS`. Don't add a host port for it.
(Upgrading an install that predates the embedding? `docker compose up -d
--remove-orphans` removes the old standalone go2rtc container.)

The `recorder` service sets `stop_grace_period: 90s` — its clean shutdown
finalizes in-flight segments and storage-migration batches, and Docker's
default 10 s grace would SIGKILL it mid-teardown. Don't remove or shorten it.

Two more things run by default and need no action: the **nightly Postgres
dump built into the `api` service** (no separate container, see Step 8) and
the migrations/first-run seed baked into `recorder`/`api` startup.
`backup-offsite` is profile-gated (`--profile offsite`) and does **not**
start with a stock `up -d` (Step 8).

**Verify:**
- `docker compose ps`: all services `running`/`healthy`.
- `curl -fsS http://localhost:8080/health` → `200 OK` (it probes DB + recorder;
  503 means a component is still coming up. Wait and retry a few times).
- `docker compose logs recorder | grep -i "migration"` shows migrations applied.

---

## 6. First-run configuration (two paths)

Pick ONE with the user.

### 6a. Hand off to the web Setup wizard (simplest)
Tell the user to open **`http://<host-lan-ip>:8080/admin`**. On a fresh install it
launches a guided wizard. It opens with a one-time **tester-terms gate**, an
AS-IS / no-warranty / not-your-only-security / lawful-use acknowledgement the
operator reads and checks to continue (recorded server-side once an admin exists,
via `PUT /config/beta-terms`). Then:

1. **Create admin**, the account they'll sign in with.
2. **Server address**, pre-filled from the connection; only change if wrong.
3. **Storage**, confirm the recording disk (path + a live capacity bar), set
   **"Keep at most"** (GB) and **"Keep at least"** (days). These write the default
   recording policy, so every camera added afterwards inherits them. The path is
   **preflighted live** (`POST /config/fs/check`): a green line confirms free
   space, and the wizard **refuses to advance** if the folder isn't writable or
   reports zero free bytes, so a full/unwritable disk can't silently record
   nothing.
4. **Find your cameras**, enter an IP range (pre-filled with the server's likely
   `/24`) and a **credential list**, add one username/password set per camera
   brand ("＋ Add another credential set"), then **Scan**. The sweep runs with the
   first set; any ONVIF camera still lacking a usable stream URL then gets the
   remaining sets tried one-by-one until one works, and the working login is
   saved on that camera. Discovered cameras appear in a table (IP, model,
   ONVIF/RTSP, stream state, "needs credentials" means no set fit). Cameras
   already added are greyed out. A per-camera **Creds…** entry handles one-off
   logins inline (a working one-off is remembered for the rest of the session).
5. **Choose cameras to add**, tick the ones to onboard (all stream-ready cameras
   are pre-ticked), edit names/URLs inline, and **Verify** each (shows a live
   thumbnail + resolution/codec/fps). There's also **＋ Add one manually** for a
   camera that's offline right now.
6. **Review & add**, confirm the list and optionally pick a **group per
   camera** (each group applies its own recording policy, e.g. an
   "always record" group and a "motion only" group in the same batch; a
   "set all to…" convenience and inline group creation are provided).
   Committing adds each camera in turn with per-row ✓/✗ feedback. Streams
   come online within a minute.
7. **Object detection (optional)**, point CrumbVMS at an existing Frigate (go2rtc +
   HTTP API bases), with a **Test** button that probes both bases server-side
   (`POST /config/frigate/test-http` → per-target ✓/✕ + detail). Skip if they
   don't run Frigate, motion detection works without it. If the user has no
   MQTT broker for Frigate's events, the bundled one is profile-gated:
   `docker compose --profile frigate up -d` starts it (see the port table).
8. **Motion decoding (optional)**, Auto / CPU / Intel-AMD iGPU (VAAPI) /
   NVIDIA (NVDEC) for the motion-analysis decode. The step shows the recorder's
   **real capability report** (render nodes / NVIDIA device); picking a hardware
   backend whose device isn't mapped into the recorder container shows the exact
   compose-overlay commands to fix it (see "Hardware-accelerated motion decode"
   below). CPU/Auto are fine defaults, skipping is normal.
9. **Notifications (optional)**, add one destination (ntfy / Pushover / webhook)
   with a **Save & send test** button. Full options (per-camera rules, quiet
   hours, Discord/Slack/Telegram, system alerts) live in Settings → Notifications.
10. **Additional users (optional)**, list existing accounts and add users
    inline (username, password ≥ 8 chars, role). Roles control cameras +
    capabilities; fine-grained control is Settings → Users & Security.
11. **Done.**

You're finished; they take it from here. (Skipping the camera steps adds nothing —
secure by default; steps 7–10 are all optional and skippable.)

**After the wizard — License-plate recognition (optional).** Not a wizard step;
it lives in the console under **Settings → Detection & clips**. OFF by default.
If the user runs their cameras through Frigate with Frigate's native LPR enabled,
plate reads arrive on the event stream Crumb already ingests — flip
**License-plate recognition** on there (and set a **retention** window; older
plate reads are pruned automatically) to start capturing them into the
searchable **LPR** tab. No new services or env keys; it reuses the Frigate
integration. A plate database is privacy-sensitive, so it stays opt-in, and
viewing it needs the **View license plates** role capability (Settings → Users &
Security). Plate-read retention is independent of footage/storage retention.
REST-driven install: `PUT /config/lpr {"enabled":true,"retention_days":90}`.

To be **alerted** when a specific plate is seen, add it to the **watchlist** in
the **LPR** tab (or `POST /lpr/watchlist {"plate":"7ABC123","label":"…"}`,
admin-only). A watchlisted plate raises a **License-plate watchlist hit** alert
routed over the same notification channels as every other alert — enable/tune it
under Settings → Notifications → System alerts. No extra services or env keys.

**After the wizard — Home Assistant (optional).** Also not a wizard step; it
lives in the console under **Settings → Detection & clips → Home Assistant**
(same panel as Frigate). OFF by default, fully self-hosted, footage never leaves
Crumb. If the user runs Home
Assistant, connect Crumb to it with the HA **base URL** and a **long-lived
access token** (generate it from a dedicated *non-admin* HA user's profile), so
cameras can be linked to HA entities and entity **badges** (door/lock/sensor
state) dropped onto the live video. Configure it in the console
(`PUT /config/ha {"base_url":"http://<ha-host>:8123","token":"…","enabled":true}`;
the token is write-only, never returned, and travels only in the `Authorization`
header). No new services, ports, or generated secrets — it reuses the existing
stack. A headless env fallback exists (`HA_BASE_URL` + `HA_TOKEN` or, preferred,
`HA_TOKEN_FILE` a Docker-secret path; see `.env.example`), but the console value
wins when both are set, and the integration stays dormant until enabled.

### 6b. Drive it yourself via the REST API (full hands-off)
All wizard steps have API equivalents. Do them in order:

1. **Create the admin.** `POST /auth/bootstrap` `{username, password}` (use the
   `SEED_ADMIN_PASSWORD` from Step 2, or ask the user). Returns a bearer token; use
   it for every call below. Then record the operator's acceptance of the tester
   terms, `PUT /config/beta-terms` `{accept: true}` (the web wizard's opening
   AS-IS gate; `GET /auth/setup-status` reports `beta_terms_accepted`).
2. **Server address.** `PUT /config/server` with the host's **LAN** address
   (`server_address`, `crumb_rtsp_base`, …). Use the LAN IP, never a public one.
   (`GET /auth/setup-status` returns a suggested address derived from the request,
   plus `suggested_scan_range`, the server's own `/24`, a good default for the
   discovery scan below. It's `null` when the console was reached by hostname.)
3. **Storage + retention.** Confirm/adjust the disk via `GET`/`POST /config/storages`,
   optionally preflight the path first with `POST /config/fs/check` `{path}` →
   `{status: "ok"|"warn"|"error", writable, free_bytes, total_bytes, message}`
   (reject an `error`: not writable, outside the media root, or zero free space),
   then point the default policy at it and set caps in ONE call:
   `PUT /config/policy/default` `{live_storage_id, live_max_bytes, live_retention_hours}`
   (bytes and hours). Every camera clones this policy on creation, so this is how
   you set "record continuously, keep N days / M GB" globally.
4. **Discover cameras.** `POST /config/discover` scans an IP range for ONVIF/RTSP
   cameras. Credentials are optional (detection needs none; reading each camera's
   real stream URL does) and travel in the **body**, never a query string:

   ```jsonc
   // POST /config/discover
   { "range": "192.168.1.0/24", "username": "admin", "password": "•••" }

   // 200 response (abridged)
   {
     "scanned": 254,
     "truncated": false,
     "cameras": [
       { "ip": "192.168.1.50", "is_onvif": true,
         "manufacturer": "Hikvision", "model": "DS-2CD2043",
         "rtsp_main": "rtsp://admin:•••@192.168.1.50:554/Streaming/Channels/101",
         "rtsp_sub":  "rtsp://admin:•••@192.168.1.50:554/Streaming/Channels/102",
         "note": "ONVIF, 2 profiles" }
     ]
   }
   ```

   Big ranges hit a 60 s wall-clock cap (`truncated: true`), split into
   `/26`-sized chunks and call once per chunk (the web wizard does exactly this to
   drive its progress bar). A single IP (`"range": "192.168.1.50"`) works for a
   per-device credential retry; pass `"timeout_ms"` (500–8000) to stretch the
   per-host budget for a single known-slow responder (e.g. Reolink).

   If a candidate's ONVIF `GetStreamUri` came back empty (or the camera isn't
   ONVIF at all), `POST /config/discover/probe` `{ip, username?, password?,
   brand?, port?}` re-tries that ONE IP with brand-aware RTSP path guesses
   (Reolink/Hikvision/Dahua/Uniview/Axis/TP-Link conventions, see
   `GET /config/camera-brands` for the list) validated with a real ffprobe,
   stopping at the first path that yields a video stream.
5. **Validate BEFORE adding.** For each candidate, `POST /config/test-stream`
   `{url}` → `{ok, width, height, codec, fps}` (and `POST /config/test-frame`
   `{url}` → one JPEG). Throttle to ~3 concurrent, cameras drop RTSP past a few
   sessions. Failed probes aren't fatal (a busy camera can still be added).
6. **Add them, sequential bulk loop.** There is **no bulk endpoint**; loop
   `POST /config/cameras` once per camera, carrying the ONVIF identity so PTZ /
   re-detect work later:

   ```jsonc
   // For each discovered+chosen camera:
   // POST /config/cameras
   {
     "name": "Front Door",
     "source_url":     "rtsp://admin:•••@192.168.1.50:554/Streaming/Channels/101",
     "source_sub_url": "rtsp://admin:•••@192.168.1.50:554/Streaming/Channels/102",
     "onvif_host": "192.168.1.50", "onvif_port": 80,
     "onvif_user": "admin", "onvif_password": "•••"
     // "camera_type": "ptz"  // only if discovery flagged PTZ
   }
   ```

   Each create clones the default policy (Step 3) and kicks a go2rtc reconcile.
   Treat one failure as non-fatal and continue; a **409 Conflict** means the
   `name`/stream is already taken, retry with a suffixed name. Re-running is safe:
   skip any IP already present in `GET /config/cameras` (match on `onvif_host` or
   the host part of `source_url`). To group them, `POST /config/groups` `{name}`
   then `PUT /config/groups/:id/members` `{camera_ids}` after the loop, one
   PUT per group (cameras can go in different groups, e.g. always-record vs
   motion-only; members = the group's existing ids ∪ the new ids).
   For an already-added ONVIF camera you can re-probe with
   `POST /config/cameras/:id/redetect`.
7. **Motion decode backend (optional).** `PUT /config/server` with the full body
   from `GET /config/server`, overriding only `motion_hwaccel`
   (`"auto"|"cpu"|"vaapi"|"cuda"`) and `motion_vaapi_device` (e.g.
   `"/dev/dri/renderD128"`, only meaningful for vaapi). The PUT is a
   **whole-row replace**, always send back every field you fetched, changing
   only these two. Then **verify the truth** with `GET /config/decode-status`:
   per camera it reports `requested` vs `active` plus a human `fallback_reason`
   when they differ (e.g. the render node isn't mapped into the recorder
   container, see "Hardware-accelerated motion decode" below). `capabilities:
   null` means the recorder hasn't reported yet (older image / not booted) —
   not "no devices". Skipping this step entirely is fine: `auto` is the default.
8. **Notifications (optional).** `POST /notifications/channels`
   `{kind, name, config, camera_ids: [], include_snapshot: true, enabled: true,
   global: true}`, `kind` ∈ `ntfy|pushover|webhook|discord|slack|telegram`,
   `config` holds the provider fields (ntfy: `{topic_url}`; pushover:
   `{app_token, user_key}`; webhook: `{url}`). Then prove it delivers:
   `POST /notifications/channels/{id}/test` → `{ok, error?}`. Per-camera rules
   and quiet hours are `PUT /notifications/rules[/{camera_id}]`.
9. **Additional users (optional).** `GET /config/roles` for the role list
   (entries carry `id`, `name`, `is_admin`), then per user
   `POST /config/users` `{username, password, role: "viewer", role_id: "<uuid>"}`
   (or `role: "admin"` with no `role_id` for another administrator). Prefer a
   non-admin role, least privilege. `GET /config/users` to list,
   `DELETE /config/users/{id}` to remove.
10. **Finish.** `PUT /config/setup-complete` `{complete: true}`.

**Verify:** `GET /auth/setup-status` → `setup_complete: true`; at least one camera
present; `GET /status` (or the recorder logs) shows it recording within ~30s.

### Hardware-accelerated motion decode (optional)

Only the **motion-analysis** decode uses a decoder (recording is stream-copy).
The base stack boots GPU-free (`motion_hwaccel: auto` → CPU when no NVIDIA GPU is
present). To decode on hardware, the matching device must be **mapped into the
recorder container**, Docker never lets a running container grant itself
devices, so this is always a host-side compose change (Frigate has the same
constraint).

**You are running on the host, so you CAN automate this**, it's the one place
full automation is legitimate. The supported path is the committed helper:

```bash
scripts/enable-hwaccel.sh                    # autodetects; or --backend vaapi|nvdec
```

It detects the host's hardware (`/dev/dri/renderD*` render nodes for VAAPI;
working `nvidia-smi` + container toolkit for NVDEC), writes the matching stanza
into `docker-compose.override.yml` (auto-loaded by every plain
`docker compose up -d`, gitignored), and restarts the recorder. It refuses to
touch an existing override (it prints the stanza to merge by hand) and refuses
cleanly when no supported hardware exists. Per the ground rules, **show the
user the command and what it will write before running it** (`--print` emits
the stanza without writing); a compose/device change is a confirm-first action.
After it runs, verify with `GET /config/decode-status`, don't assume.

The manual equivalents, if the user prefers to see the moving parts, are the
committed overlays at the repo root:

- **Intel/AMD iGPU (VAAPI)**, `docker-compose.vaapi.example.yml`:

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.vaapi.example.yml up -d recorder
  ```

  Set `RENDER_GID` in `.env` to the host's render-group GID
  (`getent group render | cut -d: -f3`) so the non-root container user can open
  the node, and `MOTION_VAAPI_DEVICE` if the iGPU's render node isn't
  `/dev/dri/renderD128` (check `ls -l /dev/dri/by-path`).

- **NVIDIA (NVDEC)**, `docker-compose.gpu.example.yml` (host needs the NVIDIA
  driver + `nvidia-container-toolkit`):

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.gpu.example.yml up -d recorder
  ```

Whatever is requested, `GET /config/decode-status` (or the console's
**Detection & clips → Motion decoding** panel, which renders the same data as a
status strip + per-camera badges) shows the **requested-vs-active truth** per
camera, with an operator-ready `fallback_reason` when the recorder had to fall
back to CPU. A wrong pick is safe: the recorder logs a warning and falls back to
CPU automatically.

---

## 7. Confirm it actually works

- A camera is **recording** (segments accumulating / `/status` healthy).
- **Live view** loads at `http://<host>:8080/admin` (or a native client pointed at
  the LAN address). `https://<host>:${CRUMB_HTTPS_PORT:-8443}/admin` also works
  (self-signed cert warning expected, see `docs/TLS.md`); mention it as an
  option but don't require it.
- Motion is being detected on an active camera.

Report the result to the user with the LAN URL and the admin username (not the
password in plaintext).

---

## 8. Back up the recording index (do NOT skip)

The Postgres `segments` table is the **sole map** from every recorded `.mp4` to
its camera and time, lose it and the footage on disk becomes un-seekable,
un-exportable data. The **api service itself runs a nightly `pg_dump`**
(03:15 local, default ON, plus an immediate catch-up dump on boot when no
fresh backup exists) with rotation into `DB_BACKUP_HOST_PATH` (default
`./backups`), so a stock `docker compose up -d` is already taking backups —
**as long as that directory is writable by uid 1001** (the api's user).
`scripts/setup-env.sh` prepares the default dir; if backups were disabled
with a permissions warning in `docker compose logs api`, run
`sudo chown -R 1001:1001 <DB_BACKUP_HOST_PATH>` and `docker compose restart
api`. (A failed/unwritable backup never takes the api down, it logs, raises
the `backup_failed` alert, and carries on serving.)

- **Single-box home install:** on-host nightly dumps are an accepted posture —
  just confirm they land: `ls -lh <DB_BACKUP_HOST_PATH>/daily/` shows a recent
  `.sql.gz` (the boot catch-up means this appears within a minute of first
  start, no need to wait for 03:15).
- **Disaster resilience (recommended when possible):** get a copy **off-host**,
  so a fire/theft/disk failure can't take out the footage AND its only index
  together. Two options, both in `docs/BACKUP.md`:
  - Simplest: point `DB_BACKUP_HOST_PATH` at a **NAS/NFS mount** (writable by
    uid 1001).
  - Or enable the opt-in service: `docker compose --profile offsite up -d`
    (rclone → SFTP / S3 / NAS / …).

**Verify:** a `.sql.gz` under `DB_BACKUP_HOST_PATH/daily/` that is < 24 h old,
and `docker compose logs api | grep -i backup` shows `database backup written`
(not a permissions warning). For real peace of mind, run one **restore drill**
(`docs/BACKUP.md`), an untested backup isn't a backup.

---

## 9. Monitoring & alerting (recommended)

CrumbVMS can notify the user when something breaks, via the admin **Notifications**
panel (Discord / Slack / Pushover / Telegram / ntfy / webhook):

- Add a **channel** (their destination).
- The **System alerts**, `recorder_offline`, `camera_offline`, `low_disk`,
  `backup_failed`, `frigate_disconnected`, are rule-based and mostly **on by
  default**; they fire to the channel(s) when the recorder dies, a camera stops
  writing, disk runs low, the backup goes stale, or Frigate disconnects.

**Suppress false alarms during planned maintenance.** Before a deliberate stack
cutover or recorder restart, arm a **maintenance window** so the transient
"no new segment" gap (go2rtc reconcile takes ~60–90 s on a normal restart)
doesn't page anyone: `POST /config/maintenance {"minutes": 15}` (admin;
`minutes: 0` disarms, `GET /config/maintenance` reads current state). While
active, all system/health alerts are still recorded but not dispatched. Two
extra safety nets need no action: a **recorder-startup grace**
(`CAMERA_OFFLINE_BOOT_GRACE_SECS`, default `180`) automatically holds
`camera_offline` alerts for the reconnect window after the recorder (re)starts,
and `MAINTENANCE_UNTIL` (unix-seconds env, default off) can pre-arm a window at
boot for scripted cutovers.

**Important limitation, cover the API itself separately.** The alert engine
runs **inside the API process**, so it catches recorder/camera/disk/backup
problems but **cannot report the API itself being down** (a crash-loop, an OOM).
For that, add a small **external uptime check** hitting
`http://<host>:8080/health` from a *different* machine, Uptime Kuma,
healthchecks.io, or a one-line cron that curls `/health` and alerts on failure.
Without it, an API outage is silent until someone notices a client won't connect.

**Update notifications (optional, off by default; issue #7).** CrumbVMS can
tell the operator when a newer release exists, via `GET /updates/latest` and a
toggle in the admin **Server** settings ("Enable update checks"). This is the
**one opt-in exception** to the LAN-only/no-egress posture in Step 0: when
enabled, the api periodically (at most a few times an hour, cached 6h) makes a
plain HTTPS `GET` to `api.github.com` for the latest `badbread/crumbvms`
release tag, a version number, nothing else. No telemetry, no client
identifiers, no counts are sent, and there's no download/auto-install, it is
strictly a "you're behind, here's the release notes link" notice. **Default is
OFF** (`UPDATE_CHECK_ENABLED=false`): a fresh install makes zero requests to
github.com until the operator explicitly flips the switch. Enable it via the
admin console, or set `UPDATE_CHECK_ENABLED=true` in `.env` before first boot.
An "enabled" answer includes a manual **"Check now"** button that forces an
immediate re-check (rate-limited server-side to protect GitHub's API).

---

## 10. Remote access (ONLY if the user asks)

Default = LAN-only, do nothing. If the user wants to reach CrumbVMS away from home:

- **Recommended:** a private overlay, **Tailscale** or **WireGuard**. No ports
  exposed to the internet; camera feeds stay private.
- **If they insist on public exposure:** require **TLS** (a reverse proxy with a
  real cert) **and** a strong admin password, and warn explicitly that this puts an
  authenticated camera system on the open internet. Never do this silently or by
  default.

---

## Troubleshooting (common)

- `docker compose` fails → Docker daemon not running / user lacks Docker perms.
- `docker compose up` refuses to start, error mentions `GO2RTC_USER`/
  `GO2RTC_PASS` "is required" → `.env` is missing those keys (hand-edited or
  copied from `.env.example` verbatim); re-run `scripts/setup-env.sh`.
- `docker compose pull` errors with "not found" / "denied" / 403 on
  `ghcr.io/badbread/crumbvms/...` → images aren't published yet for this
  repo/fork (see `docs/IMAGES.md` "Owner seam"). Use the build override
  instead: `docker compose -f docker-compose.yml -f docker-compose.build.yml
  up -d --build`.
- `/health` stays 503 → give Postgres a moment; check `docker compose logs postgres`.
- Port 8080 (or 8443/18554/8556) in use → another service on the host; remap
  the conflicting port in `docker-compose.yml` (or override `CRUMB_HTTPS_PORT`
  in `.env` for Caddy).
- GPU not found → drop the GPU overlay, run CPU (`MOTION_HWACCEL=auto`).
- Camera won't connect → wrong RTSP URL / credentials; verify with the test-stream
  endpoint and `ffprobe` before adding.
- Browser warns "not private" / "not trusted" at `https://<host>:8443` →
  expected on a fresh install (Caddy's self-signed internal CA, see
  `docs/TLS.md`); not a sign of misconfiguration. Click through once, or
  import the CA per that doc.

## What NOT to do (recap)

- ❌ Expose to the internet / open WAN ports / port-forward by default.
- ❌ Invent, hardcode, print, or commit secrets.
- ❌ Disable authentication or weaken the admin password.
- ❌ Barrel past a failed Verify check.

---

## For maintainers (keeping this runbook honest)

This doc encodes real endpoints, ports, and scripts, so it can drift from the code.
Unlike prose docs, an agent-runnable runbook is **testable**: add a CI job that, on
a clean VM, runs these steps end-to-end (`setup-env.sh` → `docker compose up -d` →
wait for `/health` → bootstrap + add a synthetic RTSP camera via the API →
assert it records) and fails if any Verify check fails. That turns "the install
works" into a green check and stops this file from rotting against the compose /
API surface.

**This runbook MUST be updated in the same change that touches any of the
install/config surface it describes.** If your PR/commit changes any of the
following, re-read this file top to bottom and fix whatever it says, don't
leave it for a follow-up:

- `docker-compose.yml`, services added/removed, published ports, required
  (`:?`-guarded) env vars, volumes, healthchecks, or profile gating.
- `.env.example` / `scripts/setup-env.sh`, new/renamed/removed config keys, or
  a change to what's generated vs. left blank.
- Image publishing/pull-vs-build story (`docs/IMAGES.md`), e.g. once GHCR
  publishing is enabled by default, the "pull may not work yet" caveats in
  Step 1/5/Troubleshooting here should be softened or removed.
- First-run flow, wizard steps (`admin.html` `WIZARD_ALL_STEPS`) or the
  underlying REST endpoints (`auth.rs`, `config_routes.rs`).
- Backup/monitoring/remote-access defaults, the api's built-in DB backup job
  (`services/api/src/db_backup.rs` + its `DB_BACKUP_*` env), the
  `backup-offsite` service, the notification/system-alerts surface, or
  TLS/Caddy behavior.
- Motion-recording defaults, the recorder's tmpfs cache mount/size
  (`MOTION_CACHE_TMPFS_BYTES`, `MOTION_CACHE_DIR`) or shadow mode
  (`MOTION_RECORDING_SHADOW`), see `docs/MOTION-RECORDING.md`.

Anchors this doc depends on (update here if they move):
`scripts/setup-env.sh`, `docker-compose.yml` (ports above),
`docker-compose.build.yml`, `docker-compose.gpu.example.yml`, `docs/IMAGES.md`,
`docs/TLS.md`, `docs/BACKUP.md`, `GET /health`, `GET /admin`,
`GET /auth/needs-bootstrap`, `GET /auth/setup-status` (incl. `suggested_scan_range`),
`POST /auth/bootstrap`, `PUT /config/server`, `GET|POST /config/storages`,
`PUT /config/policy/default`, `POST /config/cameras`, `GET|POST /config/groups`,
`PUT /config/groups/:id/members`, `GET /config/fs/list`, `POST /config/fs/check`,
`POST /config/discover`, `POST /config/discover/probe`, `GET /config/camera-brands`,
`POST /config/test-stream`, `POST /config/test-frame`,
`GET /config/decode-status` (requested-vs-active motion-decode truth),
`POST /config/frigate/test-http` (server-side probe of the Frigate URL bases),
`docker-compose.vaapi.example.yml` (VAAPI overlay),
`scripts/enable-hwaccel.sh` (one-command hardware-decode setup),
`GET|POST /notifications/channels`, `POST /notifications/channels/{id}/test`,
`GET|POST /config/maintenance` (health-alert maintenance window; env
`MAINTENANCE_UNTIL`, `CAMERA_OFFLINE_BOOT_GRACE_SECS`),
`GET|POST /config/users`, `GET /config/roles`,
`PUT /config/setup-complete`, `docs/MOTION-RECORDING.md` (motion-mode RAM
cache: `MOTION_CACHE_TMPFS_BYTES`, `MOTION_CACHE_DIR`, `MOTION_RECORDING_SHADOW`,
`segments.motion_shadow_keep`).
