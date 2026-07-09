<p align="center">
  <img src=".github/readme-banner.png" alt="CrumbVMS · Follow the trail." width="100%">
</p>

<h1 align="center">CrumbVMS</h1>

<p align="center">
  <b>An operator-grade NVR for your own cameras: frame-level H.265 scrubbing, a saveable live wall, native clients.</b><br>
  Frigate detects. Crumb is the room you sit in.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-blue"></a>
  <img alt="Status: alpha" src="https://img.shields.io/badge/status-alpha-orange">
  <img alt="Backend: Rust" src="https://img.shields.io/badge/backend-Rust-orange?logo=rust">
  <img alt="Self-hosted: no cloud, no telemetry" src="https://img.shields.io/badge/self--hosted-no%20cloud%20·%20no%20telemetry-brightgreen">
  <a href="https://github.com/sponsors/badbread"><img alt="Sponsor" src="https://img.shields.io/badge/sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors"></a>
</p>

<p align="center">
  <img src=".github/media/hero-scrub.gif" width="90%" alt="Scrubbing the CrumbVMS timeline and jumping to the next motion event across multiple cameras.">
</p>

> [!WARNING]
> **Pre-release, no warranty, use at your own risk.** CrumbVMS is unfinished alpha software
> that records security cameras. It may fail to record, lose footage, or have security bugs.
> **Don't rely on it as your only security system.** It is provided **AS IS**, with no
> warranty (see [LICENSE](LICENSE)). Testing it? Read the
> [Alpha Tester Terms](docs/ALPHA-TESTER-TERMS.md) and
> [Responsible & lawful use](docs/RESPONSIBLE-USE.md) first; recording people (especially
> audio) is regulated, and lawful use is your responsibility.

## The itch this scratches

I spent about thirty years in IT and worked with most of the enterprise NVRs along the way.
One commercial VMS, the kind that runs control rooms, got the client experience right: grab
the timeline and scrub a dozen cameras frame by frame, hunting for a gray blob of pixels in
grainy 3 a.m. footage, and the software just keeps up. Then it revoked my test license and
removed its free camera tier, and I found there was nothing self-hosted that felt like that.
The open-source world had solved detection brilliantly. Nobody had built the seat you review
it from.

So I built it. CrumbVMS is a self-hosted video management system focused on the operator
experience: a recorder with a timeline you can actually scrub across a dozen cameras (4K
H.265 handed straight to the decoder, no server transcode), a multi-camera live wall you can
save and rearrange, a batch export list, and roles with per-camera access. Detection stays
Frigate's job; Crumb draws Frigate's detections right on its timeline. It runs entirely on
your own hardware, so there's no cloud, no account, no telemetry, and your footage is plain
MP4 on a disk you own. That matters to me, but it's the how, not the why.

It's a side project: one maintainer, built on his own time, running at home in production
today. Eleven cameras, multiple storage volumes, recording day in and day out for months.
**It's about 90% of where I want v1 to be.** The recorder, the Windows desktop client, and
the Android app are the polished daily drivers; the macOS app is ready to try but still rough,
and the iOS app is built and ready for testing but not yet distributable (Apple requires a paid
developer account, see [License](#license)). Client details: [install guide](docs/CLIENTS.md).

> **Built with AI, openly.** I use AI to build CrumbVMS itself and the
> [crumbvms.com](https://crumbvms.com/) site. The words, decisions, engineering judgment, and
> testing are mine; AI is the power tool that lets a side project move at this pace.

## Already running Frigate? Good. Keep it.

**Crumb is built to sit next to Frigate, not replace it.** I run Frigate myself and have for
years; it's the best open-source object detector there is, which is exactly why Crumb doesn't
try to redo detection. But Frigate's *playback* is a web viewer: fine for checking an event,
painful for frame-by-frame investigation across a dozen cameras and a full day, and browsers
still struggle to scrub 4K H.265. Crumb is the missing piece: a real scrubbable timeline
(H.265 handed natively to libmpv/Media3), a saveable multi-camera wall, a native desktop
client, a batch export list, and roles with per-camera access, with Frigate's object
detections drawn right on the timeline over MQTT. Run both: **Frigate detects, Crumb is the
room you sit in.**

**"Why not just read Frigate's recordings?"** Because a smooth, frame-accurate, multi-camera
scrubbable timeline is a property of how footage is recorded, not how it's played back. Frigate's
files play fine, but the things that make scrubbing feel instant (short clock-aligned
keyframe-guaranteed fMP4 segments, a wall-clock index, a pre-generated preview proxy so a drag
doesn't re-decode 4K H.265 on every tick) have to be baked in at record time, and can't be
recovered by reading Frigate's storage after the fact. So Crumb owns recording and composes with
Frigate at the detection and clip level instead. The full, nerdy version is in the
[Frigate integration guide](https://docs.crumbvms.com/integrations/frigate#why-crumb-records-its-own-footage-and-doesnt-read-frigates).

**It fits whatever Frigate setup you already have.** Both pull RTSP, so the simplest thing is
to point each at your cameras and run them side by side, no reconfiguration. If you'd rather
a camera only get pulled once, connect them, and it works either direction: Crumb can ingest
your existing Frigate's go2rtc streams, or you can point Frigate at Crumb's restreamer
(`rtsp://<crumb-host>:18554/<name>`) so the recorder, your clients, and Frigate all fan out
from one connection. Do whatever fits your setup. There's a config example in the
[Frigate integration guide](https://docs.crumbvms.com/integrations/frigate).

```text
   IP cameras                 ┌────────────────────────┐           your disk
   RTSP · ONVIF   ──────────▶ │        CrumbVMS        │ ────────▶ plain MP4
                              │                        │
   Frigate (optional)         │   record · timeline    │           Desktop
   object detection  ───────▶ │   wall · export        │ ────────▶ Android
   over MQTT                  │                        │           Web
                              └────────────────────────┘           macOS · iOS
```

No Frigate? Crumb runs fine on its own: it has built-in pixel-motion detection (with
exclusion zones and pluggable detectors) for recording triggers and timeline events. It just
never does object, face, or plate recognition itself. That's Frigate's job, and Frigate is
better at it than anything I would bolt on.

No Home Assistant integration yet but it is planned. If you have any thoughts on what it
should include please open an issue.

> [!IMPORTANT]
> ## Looking for testers
> **This is the first public release, and I need help testing it.** CrumbVMS runs clean on my
> own hardware, but that's exactly the problem: it's one person, one set of
> cameras, one GPU, one disk layout. The only way to learn how it holds up in the real world is
> to get it onto hardware that isn't mine. If you run cameras at home (bonus points for an
> existing Frigate setup) and want to help shake it out, I'd genuinely value your feedback on
> **every** part of it: the install, hardware decode on your GPU, your camera brands and
> codecs, playback and export, and the desktop/mobile clients.
>
> **How to help:** stand it up ([Install](#install) below, or hand the [AI install guide](docs/AI-INSTALL.md)
> to your coding assistant), then tell me what broke. Bugs, rough edges, and confusing steps all
> go in [**GitHub Issues**](https://github.com/badbread/crumbvms/issues); read the
> [Alpha Tester Terms](docs/ALPHA-TESTER-TERMS.md) first. Early testers are how this gets good,
> so thank you.

## What it does

**Investigate**
- Frame-level scrubbable timeline (H.265 native, no server transcode), with pre-generated previews so revisiting a spot is a ~1 ms cached read, not a ~250 ms re-decode
- Jump to the next/previous motion event; digital zoom into a clip
- Motion dots **and** Frigate object icons on one timeline bar
- Bookmarks with protected (never-auto-deleted) retention

**Watch**
- Multi-camera live wall with saveable, per-device layouts
- Carousels, auto-hotspot tile that follows motion, PTZ tiles, clocks, web panes
- On-video ONVIF PTZ / focus / iris control

**Keep**
- Rust recorder; the Postgres segment index is the single source of truth
- **Motion mode buffers in RAM and only persists on motion** (idle is never written)
- Named retention policies + camera groups with inheritance; per-policy size caps + free-space headroom
- Recordings are plain MP4 on your disk, in a predictable layout; the schema is open

**Control**
- First-run wizard, generated secrets, LAN-only by default
- Custom roles with per-camera / per-group access
- Batch export list to MP4 or AES-256 encrypted ZIP, optional timestamp burn-in
- Native desktop (Tauri/libmpv), Android (Compose/Media3), web admin; macOS (rough) + iOS (built)

> Crumb records and lets you investigate; Frigate detects. They compose over MQTT.

<p align="center">
  <img src=".github/media/clip-zoom.gif" width="80%" alt="A motion clip auto-zoomed into the region where motion was detected, showing what triggered the alert.">
  <br><sub>Configurable auto-zoom to the area motion was detected in, so a clip shows you what set off the alert at a glance.</sub>
</p>

## Screenshots

<table>
  <tr>
    <td width="50%"><img src=".github/media/wall-builder.png" alt="Live-wall builder with carousels, hotspots, PTZ tiles and clocks"><br><sub><b>Build a live wall</b>: carousels, hotspots, PTZ tiles, clocks, web panes.</sub></td>
    <td width="50%"><img src=".github/media/motion-tuning.png" alt="Draw motion exclusion zones on the live image, pick a detector"><br><sub><b>Tune motion</b>: draw exclusion zones on the live image, pick a detector.</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src=".github/media/clips.png" alt="Motion clip review with a filmstrip of events"><br><sub><b>Review clips</b>: motion events as a filmstrip, zoom into the moment.</sub></td>
    <td width="50%"><img src=".github/media/export-select.png" alt="Select a span on the timeline and export it"><br><sub><b>Export</b>: select a span on the timeline, batch it to one archive.</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src=".github/media/users-rbac.png" alt="Role editor with per-camera access grants"><br><sub><b>RBAC</b>: custom roles with per-camera and per-group access.</sub></td>
    <td width="50%"><img src=".github/media/playback-timeline.png" alt="Multi-camera color-coded playback timeline"><br><sub><b>Timeline</b>: every camera's motion, color-coded, on one bar.</sub></td>
  </tr>
</table>

## How it compares

|  | **CrumbVMS** | **Frigate** | **Scrypted** | **Blue Iris** | **ZoneMinder** |
|---|---|---|---|---|---|
| License | AGPL-3.0 | MIT | Open core | Commercial ($) | GPL |
| Primary focus | Operator/timeline layer + recording | Object-detection NVR | Integration hub + NVR | All-in-one NVR | Classic NVR |
| Object detection | **BYO Frigate** (composes) | ✅ built-in | ✅ plugins | ✅ (DeepStack / CodeProject) | Basic / add-ons |
| Scrubbable timeline | ✅ frame-level, native (libmpv) | ✅ web-based | ✅ web-based | ✅ native | Basic |
| Native desktop client | ✅ Tauri/libmpv | ❌ (web) | ❌ (web) | ✅ Windows | ❌ (web) |
| Mobile app | ✅ Android (iOS in progress) | via HA / 3rd-party | ✅ | ✅ | 3rd-party |
| Multi-cam saveable wall | ✅ | ✅ camera groups | limited | ✅ | limited |
| Batch export | ✅ list → MP4 / AES-256 zip | manual | limited | ✅ | limited |
| RBAC / per-camera roles | ✅ | ✅ roles + per-camera | limited | ✅ | ✅ |
| Cloud / account required | **Never** | Never | Optional | Never | Never |
| Runs on | Linux + Docker | Linux + Docker | cross-platform | Windows | Linux |

<sub>Comparisons are my best-effort read as of 2026; corrections welcome via an issue. Crumb is alpha; Blue Iris and ZoneMinder are mature, shipping products. And to be clear one more time: the Frigate column isn't a knock. Frigate wins at detection, which is why Crumb delegates detection to it.</sub>

## Install

**What you need:** one machine on your home network with **Docker** installed and some free
disk for recordings. Linux is ideal; Windows and macOS work via Docker Desktop. New to Docker?
Install [Docker Engine](https://docs.docker.com/engine/install/) (Linux) or
[Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows/macOS) first, then
come back here.

Then run these commands in a terminal. They generate strong secrets for you, download prebuilt
images (no compiling), and start everything. There is nothing to hand-edit.

```bash
# 1. Get the code
git clone https://github.com/badbread/crumbvms.git
cd crumbvms

# 2. Generate a .env file with strong random secrets
./scripts/setup-env.sh

# 3. Download the images and start the stack (recorder + api + postgres)
docker compose pull
docker compose up -d

# 4. Confirm every service came up healthy
docker compose ps
```

**Then open `http://<your-server-ip>:8080/admin` in a browser.** A first-run wizard walks you
through the rest: accept the alpha terms, create your admin login, set the address your phone
and desktop apps will use, and add your first camera by its name and RTSP URL. Crumb restreams
it and starts recording right away. To stop everything, run `docker compose down`.

That's the whole install. A few options if you want them:

- **Let an AI set it up for you.** Hand [`docs/AI-INSTALL.md`](docs/AI-INSTALL.md) to Claude
  Code, Cursor, or a similar coding agent and it runs the whole thing, verifying each step. New
  to Docker? This is the hands-off path.
- **Use native apps** instead of the browser (Windows/macOS desktop, Android). See the
  [client install guide](docs/CLIENTS.md).
- **Build from source** instead of pulling images (you're developing Crumb, running air-gapped,
  or using a fork that hasn't published images):
  `docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build`
- **Running on Proxmox?** Same stack in a Debian/Ubuntu VM or LXC, though nobody has
  verified that path yet. See [Running on Proxmox](docs/AI-INSTALL.md#running-on-proxmox-vm-or-lxc)
  for the VM-vs-LXC tradeoff, GPU passthrough, and where to put recordings.
  ([docs/IMAGES.md](docs/IMAGES.md)).

> Headless/CI: set `SEED_ADMIN_PASSWORD` in `.env` to skip the browser wizard. For a
> remote/registry image deploy and rollback, see [docs/RELEASE.md](docs/RELEASE.md) and
> [docs/OPS-DEPLOY.md](docs/OPS-DEPLOY.md).

<details>
<summary><b>Bring your own Frigate</b>: detection icons on the timeline</summary>

CrumbVMS does **not** bundle Frigate and never runs its own object, face, or plate detection.
Detection is Frigate's job. If you point CrumbVMS at **your own** running Frigate, CrumbVMS
stores and displays whatever labels Frigate produces, including named people or license
plates, if you've configured Frigate for that, because it's your data from your tool. You're
responsible for lawful use of any such recognition (some places regulate biometric
identifiers). To get detection icons on the timeline:

1. Set `FRIGATE_MQTT_URL` (in `.env` or the admin UI) to the MQTT broker your Frigate already
   publishes to. (No broker? A bundled `mosquitto` is available behind a compose profile:
   `docker compose --profile frigate up -d`, then point your Frigate at it.)
2. For each camera, set its **Frigate camera name** (`source_camera_name`) in the admin camera
   editor so CrumbVMS maps Frigate's events to your cameras.

When `FRIGATE_MQTT_URL` is empty the entire detection subsystem stays disabled.

</details>

<details>
<summary><b>GPU (optional)</b>: hardware motion decode</summary>

The base stack runs GPU-free: `MOTION_HWACCEL=auto` probes for NVDEC and falls back to CPU
when no NVIDIA GPU is present. The quickest way to enable hardware motion decode is the helper,
which detects the host's hardware, writes a `docker-compose.override.yml`, and restarts the
recorder:

```bash
scripts/enable-hwaccel.sh          # autodetects; or --backend vaapi|nvdec
```

Or by hand, on an NVIDIA host with the nvidia-container-toolkit, add the GPU overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.example.yml up -d
```

For an Intel/AMD iGPU (VAAPI / Quick Sync) use the VAAPI overlay instead. See the header of
`docker-compose.vaapi.example.yml` for the `RENDER_GID` / `MOTION_VAAPI_DEVICE` prerequisites:

```bash
docker compose -f docker-compose.yml -f docker-compose.vaapi.example.yml up -d
```

The admin console's **Detection & clips → Motion decoding** panel (backed by
`GET /config/decode-status`) shows the requested-vs-active decode truth per camera, with the
reason whenever the recorder had to fall back to CPU.

> **Tested on Intel + NVIDIA.** AMD (Ryzen APUs / Radeon) is *expected* to work: the CPU
> decode path is vendor-neutral and VAAPI covers AMD iGPUs (Mesa `radeonsi`) the same way it
> covers Intel, but it hasn't been verified yet. On AMD, VAAPI may need `mesa-va-drivers`
> available to the recorder; reports from AMD hosts are welcome.

</details>

<details>
<summary><b>Storage</b>: disks, and RAM-buffered motion recording</summary>

One broad media root (`MEDIA_HOST_PATH`, default `./_data`) is bind-mounted to `/data` in both
containers (read-write for the recorder, read-only for the API). To add a disk, mount it under
that host dir (or a subdir) and add the storage path `/data/<subdir>` in the admin UI. No
compose edit needed; the recorder creates the subdir on first write.

Cameras set to recording mode **Motion** buffer in a RAM (tmpfs) cache and only persist to
`/data` when motion is detected. Idle time is never written to disk. Sized via
`MOTION_CACHE_TMPFS_BYTES` (default 512 MiB); see [docs/MOTION-RECORDING.md](docs/MOTION-RECORDING.md)
for the mechanism, RAM sizing, and the shadow-mode (`MOTION_RECORDING_SHADOW=1`) validation
runbook for trying it on real footage before flipping a camera's mode live. **Continuous** mode
is unaffected; it always writes straight to disk.

</details>

## Documentation

**Full documentation lives at [docs.crumbvms.com](https://docs.crumbvms.com/)**, install,
configuration, cameras, recording, motion, clients, and troubleshooting, all in one
searchable place. Start there.

For contributors working in this repo:

- **Install (agent-runnable):** [docs/AI-INSTALL.md](docs/AI-INSTALL.md) · client setup [docs/CLIENTS.md](docs/CLIENTS.md)
- **Configuration:** [docs/COMPOSE.md](docs/COMPOSE.md) (the Compose file, explained) · [docs/IMAGES.md](docs/IMAGES.md) (prebuilt images) · [.env.example](.env.example) (every env knob)
- **Architecture & design:** [docs/DECISIONS.md](docs/DECISIONS.md) · [docs/RECORDER-CORRECTNESS.md](docs/RECORDER-CORRECTNESS.md)
- **Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md) · [AGENTS.md](AGENTS.md) (ground rules for AI coding sessions)

```
services/   # Rust backend: common (types, DB, migrations), api (axum + web admin at /admin), recorder
apps/       # desktop (Tauri + mpv), android (Kotlin/Compose), ios
db/         # PostgreSQL migrations; the segment index is the single source of truth
site/       # crumbvms.com source (static, zero-dep build)
```

## License

CrumbVMS is **free and open source software**, licensed under **AGPL-3.0-or-later** (see
[LICENSE](LICENSE) and [NOTICE](NOTICE)). All of it, recording, every client, playback,
export, and detection integration, is free, with no camera limits and nothing gated. I've had
a free tier pulled out from under me; I'm not doing that to anyone else.

It's built and maintained by one person. If CrumbVMS is useful to you and you'd like to help
keep it going, [GitHub Sponsors](https://github.com/sponsors/badbread) or
[Buy Me a Coffee](https://buymeacoffee.com/badbread) is appreciated, never required.

**What sponsorship funds first: the iOS app.** It's built and ready for testing, but Apple
requires a $99/year Apple Developer account before it can be distributed (even through
TestFlight). That account is the first concrete thing donations go toward. The moment it's
covered, iOS testing goes live for everyone.

<p align="center">
  <a href="https://buymeacoffee.com/badbread"><img src=".github/media/ios-funding-goal.svg" width="92%" alt="Funding goal: $0 of $99 raised toward the Apple Developer account that unlocks the iOS app. Leave a crumb to help."></a>
</p>

> Follow the trail.
