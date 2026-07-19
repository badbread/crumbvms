# Changelog

All notable changes to CrumbVMS, kept for the people testing it. This project is
one maintainer working in the open; the pace below is what "90% of the way to v1"
looks like from the inside. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); dates are the day a change
landed on `main`.

Crumb is **alpha**. Versions before 1.0 make no compatibility promises, read the
[Alpha Tester Terms](docs/ALPHA-TESTER-TERMS.md) before you rely on it.

## [0.1.0] - 2026-07-18

The week after the first public cut. The theme: turn a working recorder into a
seat you'd actually want to sit in: a native desktop rewrite, license-plate
review, mobile-friendly streaming, and a lot of small details that add up.

### Added

**A native desktop client, rewritten in Flutter.** The desktop app was rebuilt
from the ground up (libmpv under Flutter, the Rust core kept over FFI) so live
video composites *under* native UI instead of a web view stapled over it. Full
feature port: the multi-camera live wall (maximize, digital zoom, per-tile
stream choice), a PTZ builder, playback with the scrubbable timeline, clips,
batch export, and the "special" wall tiles (carousels, motion-following hotspot,
clocks, web panes). Session persistence via Windows DPAPI so login survives a
relaunch.

**License-plate recognition, now with Crumb's own engine.** LPR began as a review
surface over Frigate's plate reads, and it grew a second source: Crumb's own local
ALPR (fast-alpr), a CPU-only, motion-gated worker that idles most of the time. Pick
per camera which engine reads it (Frigate, Crumb, both, or none). Run both and the
new **A/B benchmark** scores them head to head on your own cameras: which read the
plate, which missed, where they agreed or differed, crops side by side to confirm.
Around the reads: a searchable **LPR** tab, a **watchlist** with confusable-character
fuzzy matching (shows you live which misreads it accepts) and an **ignore** list, one
row per car instead of duplicate piles, and the cropped plate rendered in-app
(gallery, detail, PDF report). Verified against Frigate 0.17 and the 0.18 beta on a
live feed.

**Mobile-friendly live + playback.** An on-demand low-bitrate path for cheap
remote viewing: a server-side `<name>_mobile` transcode plus per-client quality
selection: Android's adaptive **Auto / Full / Data-saver**, and a matching
**Data-saver** tier on the desktop wall (per-camera or as the wall default, with
an "SD" badge on panes that are running it). Playback got an on-demand low-res
proxy too, with buffering tuned for a phone on cell data.

**Home Assistant, feed and overlay.** Link cameras to Home Assistant entities
from the admin console or the desktop app, and feed HA (or any MQTT source) in as
an **additional motion signal** alongside Crumb's own pixel motion. New this cycle:
an **on-video overlay**. Drag a linked entity's badge onto the live frame where it
physically sits and it shows that entity's live state on the wall (open/closed,
on/off), with a customizable icon (sixty to choose from), shape, color, size, and
caption. Android surfaces the same linked entities read-only. Control (actuating a
switch from its badge) is the next step.

**Storage advisor.** A per-camera storage footprint table with honest policy
labels and a whole-database "Crumb data footprint" breakdown, so you can see where
the disk actually goes.

**Camera compatibility database.** An in-app "what is this camera and does it
work" identifier, a growing make/model/firmware compat list, manual entry, and a
one-click "contribute this camera" issue prefilled from what Crumb detected.

**Update awareness.** An opt-in update-available check with an unobtrusive
"there's a newer release" banner and a **Check now** action across the desktop,
Android, macOS/iOS clients and the admin About page. Off by default; no
phone-home unless you turn it on.

**Frame-accurate scrubbing infrastructure.** A pre-generated preview proxy so
revisiting a spot on the timeline is a ~1 ms cached read instead of a ~250 ms
re-decode, with the tunables (preview size, cadence) exposed in the admin
console.

**More clients.** A macOS app reached export + playback parity with Windows; the
iOS app got smooth timeline scrubbing and a proper portrait playback layout
(both still pre-distribution, see the README on the iOS funding note).

**RBAC.** A "view all bookmarks, manage your own" role tier, and per-capability
gating for the new surfaces (LPR, view management).

**Android quality-of-life.** Audio on/off in recorded playback, a Live **take
snapshot** button, and a **Share** action that opens the Android system share
sheet for a saved snapshot or export.

### Changed

- **The install seeds the admin by default.** `scripts/setup-env.sh` now
  generates a memorable passphrase as `SEED_ADMIN_PASSWORD` and prints it once,
  so the admin account exists at first boot and the unauthenticated bootstrap
  window stays closed. The browser create-admin wizard is now the opt-in path
  (blank the seed to use it).
- **Recording policies replaced group inheritance.** Every camera now belongs to
  one explicitly named recording policy instead of inheriting through camera
  groups, so what a camera records by is never a guess. The old NULL-inherit /
  group-inheritance model was retired.
- **Admin console rebuilt** around a sections rail with a list→detail layout,
  reconciled onto `main`.
- **The "Plates" tab is now "LPR"** across every client (label only, the
  underlying routes, capabilities and APIs are unchanged).
- **Digital zoom pulls the full-quality (main) stream** so a zoomed-in live tile
  is sharp instead of upscaling the sub-stream.
- Playback clip player got its own minimal transport (play/pause, back-to-start,
  ±1-frame stepping with frame-accurate seeking) instead of the stock overlay.

### Fixed

- **Frigate 0.18 compatibility.** The 0.18 beta MQTT event shape failed the
  whole-envelope parse on *every* event (a serde duplicate-field regression);
  and, once flowing, live reads stored no plate crop box because 0.18 sends the
  box as pixel corners on a different frame than the recognized text. Both fixed
  and covered by fixtures built from the real wire payloads.
- **Audio.** Recorded segments now capture audio and normalize it
  to gap-filled 48 kHz AAC so it plays on Android; a mid-playback volume glitch
  on Android was fixed.
- **Gapless playback** across recorded segment boundaries on desktop and macOS
  (no more blackout at the segment seam).
- **Recorder robustness.** Frigate motion now *fails open* on a wedged MQTT
  broker (a stuck broker can't silently stop recording); plus the full sweep of
  the 2026-07-12 recorder audit (see Hardened).
- **ONVIF.** Backfill host/credentials from the camera's source URL so "Identify"
  and PTZ work on cameras added by RTSP URL alone.
- Timeline shows the date when scrubbed off "today"; wall scrub tiles show
  "no footage" instead of freezing; thumbnail extraction forced to MJPEG (fixed a
  100%-scrub 404); Android Edit-view layout; and a long tail of client polish.
- **Timezones actually work now.** The recorder's archive/retention cron
  inherits the container `TZ` instead of hardcoding America/Los_Angeles, and the
  admin console shows schedule times in the server's real timezone instead of a
  hardcoded "Pacific" label (#228, #237).
- **`.env` keys stopped being silent no-ops.** Compose now forwards the
  code-read keys it previously dropped (`RECORDER_TZ`, `HA_BASE_URL`/`HA_TOKEN`/
  `HA_TOKEN_FILE`, `DB_POOL_SIZE`, `MAINTENANCE_UNTIL`,
  `CAMERA_OFFLINE_BOOT_GRACE_SECS`, the `THUMB_*` set), and the env parsers
  treat an empty value as unset instead of failing boot (#229).
- **First-run wizard storage cap.** On a nearly-full disk the prefilled
  keep-at-most cap could invert to *unlimited*; it now floors at 80% of free
  space (#227).
- **The Windows desktop release ships the Flutter client.** The `v*` tag
  workflow was still building the retired Tauri app; it now builds
  `apps/desktop-flutter` and attaches an unzip-and-run
  `CrumbVMS-windows-<tag>.zip` to the Release, with a real Crumb app icon
  instead of the Flutter placeholder.

### Hardened (recorder correctness)

Losing footage is the one unforgivable bug, so the recorder gets extra scrutiny.
This cycle: two independent correctness audits with the findings implemented and
re-audited (a same-path archive move and a dead stall-watchdog among the
critical ones), new documented correctness invariants, and tests added for the
paths that were changed. Plus a **leak-scan CI gate** that blocks internal/homelab
identifiers from ever reaching `main`, hermetic singleton tests, and the Android
app now builds on every PR.

## [0.0.1] - 2026-07-07

**First public release.** The operator-grade core: a Rust recorder writing plain
MP4 with a Postgres segment index as the single source of truth; a frame-level
scrubbable timeline (4K H.265 handed straight to the decoder, no server
transcode) with Frigate's motion and object detections drawn on one bar; a
saveable multi-camera live wall; motion recording that buffers in RAM and only
persists on motion; a batch export list to MP4 or AES-256-encrypted ZIP with
optional timestamp burn-in; custom roles with per-camera access; a first-run
wizard with generated secrets, LAN-only by default; and native desktop
(then Tauri), Android, and web-admin clients. Runs entirely on your own hardware,
no cloud, no account, no telemetry.

[0.1.0]: https://github.com/badbread/crumbvms/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/badbread/crumbvms/releases/tag/v0.0.1
