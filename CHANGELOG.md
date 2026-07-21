# Changelog

All notable changes to CrumbVMS, kept for the people testing it. This project is
one maintainer working in the open; the pace below is what "90% of the way to v1"
looks like from the inside. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); dates are the day a change
landed on `main`.

Crumb is **alpha**. Versions before 1.0 make no compatibility promises, read the
[Alpha Tester Terms](docs/ALPHA-TESTER-TERMS.md) before you rely on it.

## [0.1.1] - 2026-07-20

A hardening release. Where 0.1.0 was about building the seat, 0.1.1 is about
making it trustworthy. This cycle was driven by an intensive, multi-model audit
program run with **Fable**: instead of a single review pass it ran repeated
adversarial sweeps over the whole system, the recorder, the API, all four
clients, install and upgrade, and the seams between server and client, each one
finding an issue, then independently trying to *refute* it, and only then fixing
it. That program produced the 60-plus changes below. Almost none of them change
what Crumb does; they change how much you can rely on it not to drop footage,
leak a credential, or lie to you on screen.

### The audit program

- **Recorder correctness got the most scrutiny**, because losing footage is the
  one unforgivable bug. The storage-migration copy now refuses to unlink the only
  copy of a segment (#282), quarantine pruning ages from entry time and spares
  collision losers (#283), the retention ceiling is truly absolute even for
  disabled cameras (#285), and a per-worker live-storage cache lets a reconnect
  survive a database outage (#286).
- **API security and reliability**: media tokens now carry the minter's real
  capabilities instead of a hardcoded full set (#326), a security batch tightened
  log redaction, XSS, and export/events authorization (#333), export bytes and
  the filmstrip window are bounded so one request cannot fill the disk or OOM the
  api (#314, #295), and the go2rtc reconcile loop is serialized against stream
  teardown (#315).
- **A final cross-boundary pass** hunted for cases where a server change diverged
  from how a client actually calls it, the class that produced the black license
  plate crops, and fixed the survivors: media tokens now carry `view_plates` so
  crops load (#365), plus honest clips paging totals, live and plate-clip
  capability gating, and a false motion-strip gap on long-GOP cameras (#374).
- **Every client was audited on its own.** iOS and macOS reached 0.1.0 feature
  parity (#261) and then took a batch of correctness, security, and memory fixes
  (#345 through #353, #377). Android hardened its coroutine and lifecycle handling
  and stopped rendering stale Home Assistant state as live (#306 through #313,
  #362, #376). The desktop client landed a long stability and UX pass (#324
  through #334, #361, #375).

### Added

- In-app desktop **Diagnostics**: bounded log capture, a verbose toggle, and a
  scrubbed export (#274).
- Seamless carousel and hotspot camera switching with no black gap (#268), and a
  draggable Home Assistant edit panel with labelled dot badges (#267).
- On-video Home Assistant badges on Android live (#266).
- **iOS and macOS reached feature parity with 0.1.0**: HA overlays, the LPR
  client, audio, data-saver, and the live and playback UX (#261).
- Camera compatibility: Reolink CX410 and EmpireTech IPC-B54IR-ASE-2.8MM-S3
  (#258).

### Changed

- The playback motion strip fetches intensity in one batched request instead of
  one per camera, backed by a sargable query bound that turns an O(retention)
  scan into O(window) (#259, #264); the clients chunk that batch to stay within
  the server cap (#375, #377).

### Known issues

- After upgrading, a running desktop, Android, or iOS client may show blank
  thumbnails or stalled media for up to about 15 minutes while its cached media
  tokens expire. Restart the client to clear it immediately. This is fixed
  permanently in the next release (#366).

### All merged changes

Every pull request merged since 0.1.0, newest first:

- fix(api): v0.1.1 cross-boundary audit batch (clips total, live cap, plate-clip cap, long-GOP intensity) (#374)
- fix(ios): use batched timeline-intensity endpoint instead of per-camera fan-out (#377)
- fix(android): grey HA badges after 2 missed polls (client-side staleness) (#376)
- fix(desktop): chunk motion-intensity batch into <=64-camera requests (#375)
- fix(ios): shield content on .inactive so the app-switcher snapshot can't leak it (#353)
- fix(ios): don't discard a successful login on a transient /auth/me failure (#352)
- fix(ios): hop HEVC-retag totalSize write to the main actor (#351)
- fix(ios): stream export downloads to disk instead of buffering in memory (#350)
- fix(ios): downsample plate images before caching (#349)
- fix(ios): within-segment seeks and failed media-token mints during playback (#348)
- fix(api): carry view_plates in media tokens so plate crops load (regression) (#365)
- fix(desktop): v0.1.1 verification-pass polish (6 fixes) (#361)
- fix(android): rethrow CancellationException at scopedUrl sites; clamp HA/motion poll backoff (#362)
- docs(ops): remove the postgres container before volume swap in DR recovery (#360)
- docs: v0.1.1 presentation hygiene + release-process bump step (#359)
- fix(install): secrets-overlay project name, password escaping, env/TZ/DR hygiene (#357)
- fix(ios): stop the live stream controller when PiP closes after detaching (#347)
- fix(ios): hop session-token clear to the main actor on a 401 (#346)
- fix(ios): clamp trun sample_count to prevent OOM on malformed fMP4 (#345)
- fix(desktop): carry camera identity with the pending player, not widget.camera (#330)
- fix(desktop): funnel live-wall 401s into the re-auth prompt (#334)
- fix(api): security hardening batch — log redaction, XSS, and export/events authz (#333)
- fix(desktop): guard disposed-mid-load players, detach error-path dispose (#332)
- fix(desktop): honor stream-override menu on the maximized live pane (#331)
- fix(desktop): detach playback pane player disposal from the UI isolate (#329)
- fix(desktop): restore from maximize when the maximized camera drops out of _shown (#328)
- fix(desktop): bound wedged stream-swaps with a timeout + recover a missed first-frame race (#327)
- fix(api): media tokens carry the minter's real caps, not a hardcoded full set (#326)
- fix(desktop): key HA-placement tracking by surface, not camera id (#325)
- fix(desktop): harden diagnostics log scrubbing to redact URL credentials (#324)
- fix(api): serialize go2rtc reconcile against stream teardown (delete race) (#315)
- fix(api): cap total finished-export bytes so a burst can't fill the disk (#314)
- fix(android): minor correctness cleanups (clip-player guard, stale comments) (#313)
- fix(android): map SSLHandshakeException to a specific message instead of the generic one (#312)
- fix(android): close export Create button's double-submit window (#311)
- fix(android): let CenteredTimeline's pinch-zoom span clamp match the host's own range (#310)
- fix(android): make Time.parseToMillis lenient instead of crashing on parse failure (#309)
- fix(android): move snapshot JPEG compress + MediaStore I/O off the main thread (#308)
- fix(android): lifecycle-gate HA-states poll and pause clip player on background (#307)
- fix(android): guard scopedUrl() at 4 unguarded call sites in PlaybackViewModel (#306)
- fix(api): harden clip-media ffmpeg spawns and the Frigate proxy read (#296)
- fix(api): bound the filmstrip window so one request can't OOM the api (#295)
- chore(recorder): hygiene batch — live-sweep h>0 guard, TZ invariant wording, audit invariants 30-33 (#287)
- fix(recorder): cache the resolved live storage per worker — a reconnect survives a DB outage (#286)
- fix(recorder): footage lifecycle covers disabled cameras — the retention ceiling is truly absolute (#285)
- fix(recorder): credit the floor deficit only for moves off the floor filesystem (#284)
- fix(recorder): quarantine prune ages from ENTRY time and exempts -rN collision losers (#283)
- fix(recorder): same-file guard in the storage-migration copy — never unlink the only copy (#282)
- ci(release): macOS attach creates the Release if missing; Windows zip ships a sha256 (#275)
- feat(desktop): in-app Diagnostics — bounded log capture, verbose toggle, scrubbed export (#180) (#274)
- fix(desktop): actually freeze a maximized carousel/hotspot slot (#273)
- fix(desktop): gate post-open seeks on file-loaded — frame-step no longer jumps a segment on quiet footage (#272)
- fix(desktop): fall back to per-camera intensity when the server lacks the batch endpoint (#271)
- feat(desktop): seamless carousel/hotspot camera switching (no black gap) (#254) (#268)
- feat(desktop): draggable HA edit panel + Dot badges show their label (#255) (#267)
- feat(android): render on-video Home Assistant badges on live (#263) (#266)
- fix(android): quality label no longer wraps 'AUTO' to two lines (#265)
- iOS/macOS: v0.1.0 parity — Home Assistant overlays, LPR client, audio, data-saver, live/playback UX (#261)
- perf(timeline): batch the per-camera intensity fan-out into one request (#256) (#264)
- perf(timeline): stop the motion-strip refresh from stacking under load (#256) (#260)
- perf(timeline): sargable start_ts bound on the intensity query — O(retention) → O(window) (#256) (#259)
- chore(release): add pr-changelog.sh (per-PR bulleted change list) + document it (#257)
- data(cameras): add Reolink CX410 + EmpireTech IPC-B54IR-ASE-2.8MM-S3 (closes #181, #182) (#258)

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

[Unreleased]: https://github.com/badbread/crumbvms/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/badbread/crumbvms/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/badbread/crumbvms/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/badbread/crumbvms/releases/tag/v0.0.1
