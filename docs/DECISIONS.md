# Architecture decisions, and when to revisit them

A log of significant design decisions: what was chosen, what was rejected, and
the concrete triggers that should reopen the question. Add new entries at the
top. Keep entries honest about trade-offs, the point of this file is that a
future session (human or AI) can tell whether the world has changed enough to
revisit.

---

## 2026-07-10, Camera compatibility database: JSON source, generated docs, PR-curated (and the ratified in-app identify/contribute direction)

**Context.** Cameras vary in ways Crumb can't fully paper over (codec quirks,
firmware bitstream oddities, ONVIF gaps). The first concrete case: a Uniview LPR
whose H265 main uses RTP aggregation packets plus a `PPS id out of range`
bitstream quirk that Android's Media3 RTSP HEVC path can't decode, so phone
fullscreen live silently drops to the H264 sub. ffprobe on the go2rtc restream
confirmed it is specific to that stream (clean 4K H265 mains from other cameras
play full HD on the same phone). That is exactly the kind of hard-won, per-model
knowledge a self-hosted VMS community should pool, the way iSpy/Agent DVR and
Frigate do.

**Decision (built now).** A community-curated **camera compatibility database**:
- `data/camera-compatibility.json` is the single source of truth (schema in
  `data/README.md`).
- `scripts/gen-camera-compat.mjs` (zero-dependency, Node built-ins only, same
  ethos as `sync-arch-docs.mjs`) renders it into
  `docs-site/docs/cameras/compatibility.md`, which is **gitignored and
  regenerated on every build** (local, CI `docs.yml`, and the Docker image
  build) so it cannot drift from the data.
- Contributions are **by pull request only**. Crumb never auto-collects camera
  data: no telemetry, no phone-home (project direction).

**JSON, not YAML.** JSON parses with Node built-ins (keeps the generator
zero-dependency, honoring the docs-site CI convention) and is directly readable
by the Rust backend (`serde_json`) for the future in-app hint below, so the same
one file serves docs and app. Rejected: YAML (would add a parser dependency and
isn't a native Rust read); a hand-maintained markdown table (drifts, no
machine-readable form).

**Ratified direction (NOT built yet, tracked as a feature).** Bundle the JSON in
the server image and, in the admin console:
1. **Identify** the operator's cameras, primarily via ONVIF
   `GetDeviceInformation` (Manufacturer/Model/Firmware; the proven approach used
   by Scrypted and Home Assistant), with an optional **stream fingerprint**
   (codec/profile/full-range/packetization signature, e.g. the LPR's own
   full-range + `PPS out of range` signature) as a secondary signal. Crumb does
   not store make/model today, so capturing it is part of the feature.
2. If matched, surface **"camera identified" + the known quirks and recommended
   settings** inline.
3. If unmatched, offer a **user-initiated "contribute this camera" button that
   opens a pre-filled GitHub issue in the operator's own browser** (detected
   make/model/codec/fingerprint + their optional notes), which they review and
   submit under their own account.

**Rejected (hard line): the server auto-submitting entries to the repo.** It
would be outbound data to a third party on the server's own initiative (the
phone-home the project forbids), would require a write credential baked into an
open-source binary (golden rule 1: no hardcoded secrets, and it would be
trivially extracted and abused), and would let unvetted content flow into the
repo with no maintainer gate. The browser-redirect-to-prefilled-issue pattern
gives the same one-click ease with zero server egress, no bundled secret, and a
human PR review, so it is the only sanctioned shape.

**Revisit triggers:**
- The compatibility corpus grows large enough that a flat JSON file is unwieldy
  (split by vendor, or move to per-entry files with a merge step).
- A contributor pattern emerges where the pre-filled-issue flow is too much
  friction and a **self-hosted, opt-in** submission target (never a default,
  never phone-home) is genuinely wanted, revisit *how*, not *whether*, egress
  happens.
- ONVIF identification proves unreliable across enough models that the stream
  fingerprint has to become the primary matcher.

---

## 2026-07-09, Update check: re-check every launch + always-present About field (stale-state fix)

**Problem.** The first client cut of #7 checked once per client and throttled
even the launch check to 24h, and it hid the update field and "Check now"
whenever the last response said the feature was disabled. On-device testing
surfaced a trap: a client that first checked while the operator had the server
switch OFF cached "disabled" and then had no way to discover it was later turned
ON — no auto re-check for 24h, and no reachable "Check now" (it was gated behind
the stale enabled state). The only recovery was wiping app data.

**Chosen.** Across all clients (desktop, Android, iOS/macOS):

- The launch/login check runs on **every cold launch**, ungated by the 24h
  timer (guarded per-process against re-spam). The 24h throttle now governs
  only periodic re-checks while the app stays open.
- The Settings/About screen carries an **always-present update field whenever
  the server reports the check enabled**, and **opening it triggers a fresh
  check**, with **"Check now" always reachable there**. The field hides only on
  `enabled:false`/404.

**Rejected.**

- *Check-once + 24h-throttled launch check* (the original): simplest, but
  strands a client that checked during a disabled window for a full day with no
  manual recovery.
- *A background/periodic poller* to notice enable-flips sooner: heavier than a
  notify-only nicety warrants; app launch and the About screen are natural,
  cheap re-check triggers that cover it.

**Revisit triggers.** Every-launch checks become a measurable server/GitHub
load concern (they shouldn't: the api caches ≤6h and the client→server hop is
LAN-local); or a client gains a real background presence where a periodic
poller becomes worthwhile.

---

## 2026-07-09, Scrub-preview tunables: per-tick `server_settings` re-query; width stays env-only

**Problem.** Issue #10 asks to move the thumbnail pre-generation worker's and
cache sweeper's runtime tunables from env-only (`ApiConfig`, read once at
boot) to the admin console, following the `clip_preroll`/`update_check_enabled`
`server_settings` precedence (DB wins, `NULL` falls back to env). Unlike those
two, the consumers here are **background loops**, not per-request handlers, so
a console change also has to reach an already-running worker without a
restart. `docs/SCRUB-PREGEN-TUNABLES-PLAN.md` is the full design; this entry
records the ratified decisions (D1-D5).

**Chosen.**

- **Five nullable `server_settings` columns** (migration `0046`):
  `thumb_pregen_enabled`, `thumb_pregen_lookback_hours`,
  `thumb_pregen_scan_secs`, `thumb_cache_max_bytes`, `thumb_cache_ttl_seconds`.
  Same shape as `update_check_enabled`: DB value wins when set, `NULL` (never
  touched) falls back to the matching `THUMB_*` env default.
- **Live-reload = per-tick direct re-query (D2), not a cached-settings
  struct.** `services/api/src/scrub_settings.rs::resolve(pool, cfg)` does one
  `query_opt` per cycle; both the pre-gen worker (`thumb_pregen.rs`, one query
  per `scan_secs`) and the cache sweeper (`main.rs::export_ttl_sweeper`, one
  query per minute) call it fresh. Roughly 2 tiny queries/minute total against
  a pool that serves every API request, unmeasurable, and mirrors the existing
  `updates.rs::resolve_enabled` call-per-use pattern exactly. A resolve
  failure keeps the last-known-good values and logs a `warn!` rather than
  aborting either background loop.
- **Mid-backfill kill switch + watermark clear on disable (D3).** The worker
  never exits when disabled: it idles (one settings SELECT per `scan_secs`)
  instead. A console "disable" is honored within seconds even mid-backfill,
  re-checked between cameras and every 256 extracted slots within one camera.
  An enabled-to-disabled transition clears the per-camera watermark map, so
  re-enabling always starts a fresh `pregen_lookback_hours` backfill rather
  than grinding through the entire disabled gap (the operator asked for pregen
  *now*, not a surprise multi-day catch-up).
- **`THUMB_PREGEN_WIDTH` stays env-only (D1).** Width is part of the
  thumbnail cache key (`.../{ts_ms}_w{width}.jpg`); the playback clients pin
  their requested width (480, matched to the scrub-still tile size). A console
  width that drifted from that value would make every pre-generated file sit
  at a cache key nobody ever requests, 100% of the pregen CPU + storage
  silently wasted while scrubbing quietly degrades to on-demand extraction,
  with nothing failing loudly. `GET /config/scrub-preview` still surfaces the
  effective width, read-only (`source: "env-only"`), so the operator sees the
  whole picture in one panel.
- **No "reset to env default" affordance (D4).** Matches `update_check_enabled`
  shipping without one: plain serde can't distinguish an absent field from an
  explicit JSON `null` without a double-`Option` PATCH helper, and once a knob
  is touched in the console the DB value wins for good.
- **100 MiB `thumb_cache_max_bytes` floor (D5).** A near-zero budget would
  make the sweeper delete every thumbnail every minute, silently defeating the
  feature; the clamping setter enforces the floor server-side regardless of
  what the console sends.

**Rejected.**

- *Shared cached-settings struct with TTL/invalidation* (an `AppState` field
  refreshed periodically, or invalidated by the PUT handler). No hot-path
  reader exists to justify the machinery: these are 1-2 reads/minute
  background loops, and an invalidation seam is a new way to silently go
  stale (PUT handler forgets to invalidate) that per-tick re-query doesn't
  have. Revisit if a future hot-path consumer of these settings appears, or a
  multi-replica API deployment makes per-tick staleness (currently bounded to
  one tick) visible.
- *Config-file reload / `SIGHUP`.* No precedent anywhere in Crumb; the DB is
  already the one settings plane (`server_settings`), and adding a second
  reload mechanism for one feature would be inconsistent with every other
  console-editable setting.
- *Exposing `THUMB_PREGEN_WIDTH` as a sixth column with a warning label*
  (option B in the plan doc). The cache-key-coherence foot-gun above was
  judged not worth it for v1; revisit if a client ships a different scrub tile
  size or an operator has a concrete reason to shrink pregen storage via
  width rather than the cache-budget/TTL knobs that already exist for that.
- *Forced cache regeneration on a width change.* Not proposed even under
  option B: old files can't be safely deleted mid-serve, and a mixed-width
  cache is already structurally coherent (width is part of the key, so
  nothing is ever served wrong), just potentially wasteful. Stale-width files
  age out via the existing TTL sweeper on their own.

**Trade-offs accepted.** Up to one `scan_secs` (60s default) of staleness on
"enable" (an idle tick just costs one SELECT); up to 256 slots / one camera
of in-flight work before a "disable" is fully honored during a large backfill.
Both are explicit, bounded costs of the per-tick model, not silent.

**Revisit triggers.** A hot-path consumer of these settings appears (revisit
D2, add the cached-settings struct). A client ships a scrub tile size other
than 480px (revisit D1, expose width with per-client negotiation). Operators
ask for "reset to env default" (revisit D4, double-`Option` clear support).
Multi-replica API deployments make per-tick staleness visible in practice
(revisit D2).

---

## 2026-07-09, Update-available check: api-mediated, notify-only, opt-in / OFF BY DEFAULT

**Problem.** Issue #7 asks for a non-intrusive "update available → release
notes" signal across every client (web console, Windows/Linux/macOS desktop,
Android, iOS), so an install doesn't silently drift for months without the
operator noticing a new release exists. `docs/UPDATE-SYSTEM-PLAN.md` is the
full design; this entry records the decisions ratified for Phase 1 (server).

**Chosen.**

- **Notify-only (D1).** Version comparison and a release-notes link only. No
  download, no install, no update channels, and the recorder is never touched
  by any part of this feature — footage/metadata are structurally uninvolved.
- **Api-mediated, not per-client direct polling (D2).** Only `services/api`
  (`services/api/src/updates.rs`) talks to `GitHub`; every client (including
  the web console) consumes its own server's `GET /updates/latest`. One
  implementation, one cache, one operator off-switch that actually turns the
  whole thing off site-wide, instead of five client codebases each with their
  own `GitHub` HTTP code and their own switch.
- **Opt-in, OFF BY DEFAULT (D3).** `UPDATE_CHECK_ENABLED` defaults to `false`;
  the admin-editable `server_settings.update_check_enabled` (migration
  `0045_update_check.sql`, nullable — DB wins, `NULL` falls back to env) can
  turn it on. A fresh install makes **zero** requests to `github.com` until
  the operator explicitly opts in via the admin console or the env var. This
  is the plan doc's non-default alternative, deliberately chosen over its
  "recommended enabled" option to keep Crumb's no-phone-home posture intact
  out of the box — the checker is a value-add an operator turns on, not a
  default behavior a privacy-conscious install has to notice and turn off.
- **Stable releases only, via `releases/latest` (D6).** That `GitHub` endpoint
  already excludes drafts and pre-releases, so channel selection needs no
  extra code for Phase 1.
- **Manual "Check now" (§2.5), added mid-implementation.** `?refresh=1` forces
  an immediate re-check bypassing the 6h cache TTL, gated to a separate 60s
  minimum interval between actual forced `GitHub` hits so a burst of manual
  clicks can't stampede the 60/h/IP unauthenticated rate limit. The disabled
  state still wins unconditionally: `refresh=1` while disabled makes zero
  requests, there is no "one-off check while disabled" escape hatch.
- **No Tauri built-in updater (D4).** Its value is install/relaunch machinery,
  which #7 explicitly excludes; using it only for version detection would
  still require its manifest format and a signing keypair at build time for a
  job a 20-line fetch + hand-rolled `SemVer` compare does against one endpoint.

**Rejected.**

- *Per-client direct `GitHub` polling as the default.* More resilient to a
  disabled/old server, but five implementations, five off-switches to keep in
  sync, and every client device (including wall displays) hitting `GitHub`
  independently instead of one cached point per site. Not ruled out forever —
  see revisit triggers.
- *On-by-default (the plan doc's original recommendation).* Would surface the
  feature to exactly the operators it's meant to help without them hunting for
  a toggle, but costs a fresh install non-zero external egress before the
  operator has made any choice at all — a worse trade against the project's
  "operator's hardware is the whole world, no phone-home" direction than the
  minor discoverability cost of an opt-in switch.
- *A server-hosted artifact/manifest system as the #7 vehicle.* Explicitly
  deferred to the `docs/UPDATE-SYSTEM-PLAN.md` §6 future extension (real
  install automation, if ever demanded) — out of scope for a notify-only
  nicety.
- *Tauri's built-in updater for detection only.* See D4 above.

**Trade-offs accepted.** A client talking to an older server that lacks the
route gets a 404 and shows nothing — the accepted cost of server-mediation.
Version-level granularity misses an Android intra-version re-ship
(`workflow_dispatch` bumping `VERSION_CODE` without a new tag). An unparsable
own version (a local `-dev` build) shows no banner rather than guessing.

**Revisit triggers.** Real operator demand for in-app download/install
surfaces (→ design the §6 future extension properly, with signing and scoped
tokens). `GitHub`'s REST API terms or rate limits change in a way that makes
server-side caching insufficient. A legitimate need emerges for a client to
check `GitHub` directly (e.g. a client that is never paired with a Crumb
server) — revisit D2. Enough operators report never noticing the admin
console toggle exists that the opt-in default becomes counterproductive —
revisit D3 (the plan doc's original recommendation is preserved above as the
alternative to fall back to).

---

## 2026-07-09, Pin the Rust toolchain (CI + `rust-toolchain.toml`) instead of tracking `stable`

**Problem.** CI installed Rust via `dtolnay/rust-toolchain@stable` (unpinned)
and runs clippy with `-D warnings`. When Rust 1.97 released, its clippy began
flagging an untouched `match` in `services/recorder/src/resource_stats.rs` as
`clippy::question_mark`, turning the gate red on a docs-only merge (#29) with
zero relevant code change. Green-this-morning / red-this-afternoon with no code
change is exactly the failure mode a floating toolchain + `-D warnings` invites.

**Chosen.** Pin the toolchain to an explicit version in two coordinated,
cross-referenced places: `rust-toolchain.toml` at the repo root (governs local
builds, so `cargo clippy` on dev1 matches CI and "run the gate before pushing"
actually catches what CI catches) and the `toolchain:` input on the CI
`dtolnay/rust-toolchain` steps (governs CI). Rust is now bumped deliberately by
editing both, not surprise-upgraded. First pin: `1.97.0`.

**Rejected.**

- *Keep tracking `stable`.* Zero-maintenance until it isn't: any new stable that
  adds or tightens a lint can break CI with no code change, and it broke on
  literally the first run after 1.97 shipped.
- *Drop `-D warnings`.* Removes the fragility but also removes the guard that
  keeps the tree clippy-clean; trading a real correctness signal for convenience.
- *`rust-toolchain.toml` alone, CI left on `@stable`.* Works via rustup's
  auto-switch, but relies on a subtle interaction (CI installs stable, cargo
  silently switches to the toml version). Explicit pinning in both spots reads
  clearly to a future maintainer.

**Revisit triggers.** Bumping the pin becomes frequent toil (wanting the newest
stable often), or the two pin sites drift apart in practice — then consolidate
to a single source of truth (e.g. an action that reads `rust-toolchain.toml`,
accepting the extra CI dependency).

---

## 2026-07-08, macOS/iOS export: adopt the desktop batch-list model (single-shot export retired)

**Problem.** The SwiftUI (macOS/iOS) export flow had drifted from the
Windows/Linux desktop client: it exported a single time window across N
selected cameras (`POST /export`), while the desktop builds a **list** of
clips (each its own camera + range), with a batch summary, an optional
AES-256 ZIP password, and one job for the whole list (`POST /export/batch`).
Issue #22 tracks the parity gap; the maintainer's direction (2026-07-08) is
"mimic the Windows client as closely as possible".

**Chosen.** Port the desktop batch-list model to the SwiftUI client
(`ExportViewModel` holds `[ExportClip]` + an add/edit-clip builder with a
frame-preview scrubber; `ExportView` renders list ⇄ builder on the left and
the global output panel — format, burn-in, audio, password, batch summary,
"Export N clips" — on the right). Submission goes through the existing
server `POST /export/batch`; job polling/cancel is unchanged. Entry points
seed the builder the way the desktop does: playback passes the viewed camera
plus the bracketed timeline selection (builder opens pre-filled, one click to
add); the Exports tab starts in list mode with the selected wall camera
pre-picked.

**Rejected.**

- *Keeping the single-shot model* (or shipping both flows side by side):
  re-litigating the ratified "desktop is the reference UX" direction, and two
  export UIs is worse than one.
- *A Windows-identical persisted destination-folder picker on macOS/iOS.*
  Platform-inappropriate: sandboxed macOS/iOS apps get durable folder access
  only via security-scoped bookmarks, and iOS has no folder workflow at all.
  Outputs keep the platform-native ends: NSSavePanel per output file (macOS)
  and the share sheet fed a locally-downloaded file (iOS) — preserving the
  C1/C2 token-leak fixes. Revisit if operators ask for one-click batch saves.

**Deferred, stated explicitly (component-map §3 parity walk):**

- **Android** still has the single-shot export flow; porting the batch model
  there is follow-up work under issue #22's umbrella, not silently dropped.
- **Wall-tile thumbnail crispness** (issue #22 item 5) — since addressed:
  the playback wall + single-camera scrub previews requested ~160px stills
  that blurred blown up to tile size on a large display. The scrub-still width
  is now a shared constant (iOS `MediaUrls.scrubThumbWidth` = 480) kept equal
  to the server's `THUMB_PREGEN_WIDTH` default (raised 160 → 480) so the two
  agree and requests hit the pre-generated cache when it is enabled (and are
  cached lazily at that width, grid-snapped, when it is not — the default).
  480 sits at the top of the maintainer's suggested 320–480 range: notably
  crisper without paying the full 640 cap on per-tick on-demand extraction for
  a multi-camera wall. Trade-off: when an operator enables pre-generation the
  cache is ~3–4× the bytes of the old 160px cache; lowering `THUMB_PREGEN_WIDTH`
  is safe and just drops those clients back to on-demand at their width.
- Issue #22 item 6 (format-set parity) was verified a **no-op**: both clients
  already offer exactly MP4/MKV × {H.264 (MP4 only), H.265, copy}.

**Revisit triggers:** the desktop export flow changes shape (this port
follows it); operators request persisted batch-save destinations on macOS.

---

## 2026-07-07, Scrub preview: pre-generated JPEG proxy (API-side); keyframe index rejected

**Problem.** Timeline scrubbing does not yet feel like a leading commercial VMS:
buttery, instant scrub (including synchronized multi-camera) and frame-accurate
seek. The open question was whether that requires (a) a low-res preview proxy,
(b) a finer-than-per-segment seek index, or (c) a custom video container. A
grounded audit (`services/api/src/filmstrip.rs`, `services/recorder/src/recording.rs`,
`motion.rs`, the segment schema, and all four clients) answered it.

**Findings that shaped the decision:**

- The preview-proxy plumbing already exists as an explicit "Phase 1":
  `filmstrip.rs` serves `/filmstrip/{cam}` + `/frame` from on-demand single-frame
  ffmpeg extraction cached under `{export_dir}/.thumbs`. `db::list_thumbnail_times`
  is a stub returning empty; there is no background pre-generation. iOS (single-cam
  plus a multi-camera synchronized wall), Android (single-cam), and the desktop
  export-preview already consume these frames. The UX is built; the server starves it.
- Two live defects make the existing cache nearly useless: thumbnail filenames are
  exact millisecond timestamps but clients request arbitrary cursor times, so the
  hit rate is near zero and every scrub re-spawns ffmpeg; and extraction has no
  concurrency cap (unlike `/play`'s `play_semaphore`) and `.thumbs` is never evicted.
- Segments are standard fMP4, ~4 s each (`SEGMENT_SECONDS`, clamped 2-6), written
  `-movflags +frag_keyframe+empty_moov+default_base_moof` (fragment boundaries are
  keyframe boundaries). Only the policy-selected stream is recorded (default `main`);
  the sub stream is NOT recorded for playback.

**Options considered:**

| # | Option | Verdict |
|---|--------|---------|
| 1 | **Pre-generate the JPEG preview proxy, API-side background worker** reusing `extract_thumbnail`, deriving slot times from `segments` coverage (no migration), grid-aligned cache keys, hour subdirs | **CHOSEN.** Zero recorder changes, zero write-path risk (API mount is read-only), covers all cameras and both recording modes, and three client UIs already render it. |
| 2 | Recorder piggyback on the motion decoder's in-RAM frames | Deferred. The motion frames are grayscale (`format=gray`); color needs a filtergraph split; coverage holes (Frigate-source cameras bypass the frame pipeline); couples a cosmetic feature to the always-must-work recorder. Revisit only if option 1's API-side CPU is measured too high. |
| 3 | Dedicated long-running ffmpeg-per-camera off go2rtc | Rejected. Duplicates the sub-stream decode the motion task already pays, the exact cost the power-optimization work fought. |
| 4 | **Finer-grained seek index** (per-keyframe / byte offsets) | **REJECTED.** At 4 s segments over LAN with native fMP4 fragment parsing in every player, nothing inside a ~2 MB segment is worth indexing server-side. Frame accuracy is a decode problem an index cannot solve (an index cannot create keyframes); all three players already expose exact-seek / frame-step. Would matter only if segments were 5-15 minutes. |
| 5 | Custom video container | Out of scope. A container buys storage packing / inline metadata / evidence integrity, not scrub smoothness, and would cost fMP4 interop + per-client demuxers + write-path risk. |
| 6 | Dual-stream recording (record sub continuously for cheap multi-cam scrub) | Out of scope here; separate write-path decision, tracked as ROADMAP dual-stream (#7) and option 5 of the 2026-07-03 motion-recording entry. Do not bundle. |

**Chosen approach.** Finish the preview proxy as an API-side, read-side feature.
Phase 0 (grid-snap cache keys + extraction semaphore + `.thumbs` eviction) fixes
the two live defects and stands alone. Phase 1 adds the background pre-generation
worker and a real `list_thumbnail_times` derived from `segments` (no new table, no
migration). Phase 2 adds the desktop timeline preview UI (the one client lacking
it). Phasing in `docs/ROADMAP.md` initiative 8.

**Trades knowingly accepted:**

- Preview granularity equals the generation interval (recommended 10 s), so during
  a drag the preview steps at ~10 s; sub-second precision still comes from the real
  video on release (desktop already live-seeks in-segment). This matches commercial
  VMS behavior.
- Thumbnails are extra small files (~16-39 GB and 2.6-6.5 M files for 10 cams / 30 d
  at recommended settings, under 1% of video bytes; file count is the real cost,
  mitigated by hour subdirs; sprite atlases deferred until file count actually hurts).
- The Phase 1 thumbnail-retention task is a NEW deletion path; it is path-guarded to
  `.thumbs`, extension-filtered to `.jpg`, and gets a test, per golden rule 2.

**Revisit triggers:**

- API-side extraction CPU measured unacceptably high on real deployments, reopen
  option 2 (recorder motion-decoder piggyback).
- Segment length raised beyond ~15 s, or WAN/remote scrubbing becomes a first-class
  target, reopen option 4 (finer index) and sprite atlases.
- `.thumbs` file count demonstrably hurts backup/inode performance, build sprite atlases.

## 2026-07-06, Docs site: Docusaurus, self-hosted behind cloudflared (docs.crumbvms.com)

**Context.** Crumb needs a public, versioned, searchable documentation site in
the style of Frigate's. `docs/ROADMAP.md` initiative 4 had leaned MkDocs Material
as an unratified note. The site is built in `docs-site/`.

**Decision.** Docusaurus v3, classic preset, docs-only mode. Client-side local
search (`@easyops-cn/docusaurus-search-local`, a build-time lunr index, zero
external calls), built-in versioning cut at pinned releases (deferred during
alpha), no third-party trackers/analytics/CDN fonts, static output that is always
self-hostable. Single-source: user docs authored in `docs-site/docs/`; a
whitelisted subset of `docs/` engineering docs (`DECISIONS.md`,
`RECORDER-CORRECTNESS.md`, `MOTION-RECORDING.md`) is copied into an Architecture
section at build time by `scripts/sync-arch-docs.mjs` (those generated pages are
gitignored and regenerated on every build, local and CI, so they cannot drift).
Anti-drift is enforced by `docs/COMPONENT-MAP.md` (the docs site is a propagation
surface) plus a CI link-check build on every docs PR (`.github/workflows/docs.yml`,
`onBrokenLinks: 'throw'`).

**Deploy: self-hosted, not Cloudflare Pages.** The site ships as an `nginx:alpine`
image (`docs-site/Dockerfile` + `nginx.conf` + `docker-compose.yml`) served as a
static site on port 3000 and reached over a Cloudflare tunnel at
`docs.crumbvms.com`, the same self-hosted pattern the `crumbvms.com` marketing
site already uses. This was chosen over a managed static host (Cloudflare Pages)
because it matches the running marketing-site setup, keeps everything self-hosted
(consistent with the product's own posture), and adds no new hosting dependency.

**Rejected:** MkDocs Material (second, Python, doc toolchain next to the Node
marketing site; versioning is a `mike` bolt-on); Astro Starlight (versioning only
via an immature plugin); VitePress (no built-in versioning); mdBook
(single-book, no versioning). Algolia DocSearch rejected on privacy grounds
regardless of generator. Cloudflare Pages rejected for deploy (see above).

**Cost accepted.** Docusaurus is a large npm dev-dependency tree, but it is
build-time-only tooling in an isolated `docs-site/` workspace: it never ships in a
product image and adds nothing to the runtime (golden rule 6 reviewed). Builds run
on dev hosts and CI, never on the clean workstation. The docs-site Docker build
context is the repo root (not `docs-site/` alone) so the sync script can see
`docs/` and `docs-site/` as siblings; called out in the Dockerfile/compose.

**Revisit triggers:** Starlight ships first-class versioning and the npm tree
becomes a maintenance burden; the docs corpus needs capabilities Docusaurus lacks;
the local-search plugin is abandoned and forces a swap; or the self-hosted static
path is retired in favor of a managed static host (then revisit Cloudflare Pages).

---

## 2026-07-06, go2rtc stream model: reconcile PATCHes existing streams, only PUTs missing ones

**Context.** Crumb is the sole puller of each camera: the api's reconcile loop
(`services/api/src/go2rtc.rs`) owns go2rtc's stream table and every consumer
(recorder record, recorder motion, Frigate, live desktop/Android clients,
snapshots) is supposed to fan out from **one** producer per stream, so a camera
sees exactly two RTSP sessions (main + sub) no matter how many viewers. It did
not. On the session-capped Uniview LPR camera, live and snapshot consumers were
intermittently refused at RTSP `SETUP`, and `GET /api/streams?src=<cam>` showed
`consumers: null` on every camera even while recording was live.

Root cause (verified against go2rtc v1.9.14 source + live prod, read-only):
go2rtc's `PUT /api/streams` handler does `streams[name] = NewStream(...)`, an
**unconditional replace**. The reconcile loop re-`PUT`s all managed streams every
`RECONCILE_INTERVAL` (60 s) for drift correction, so every minute each stream's
in-memory object was swapped for a fresh idle one. The old object kept its live
camera session and attached consumers running (orphaned, invisible to the API);
every consumer that attached in a later window landed on a new object and had to
**dial the camera again**. Steady state converged to one camera RTSP session per
long-lived consumer, and on a capped camera that exhausts the slots. H.265 was a
red herring.

**Decision.** Make reconcile **diff-based**. Each pass `GET`s the names go2rtc
already has; a MISSING name is created with `PUT` (a fresh name orphans nothing —
this is the cold-start / go2rtc-restart path, unchanged), and an EXISTING name is
updated in place with `PATCH`, which go2rtc implements as `SetSource` on the
existing object, a true no-op for an unchanged source on a running producer, and
no object replacement, so consumers keep sharing the one producer. `reconnect()`
(DELETE + `PUT`) stays the explicit "source really changed, force a re-dial" path.
One guard: go2rtc's `Patch()` aliases instead of applying the source when the
source is `rtsp://` with a single-segment path equal to a managed stream name, so
Crumb detects that collision and keeps `PUT` for those (no prod camera hits it).
We do **not** diff sources against the GET body, go2rtc masks credentials in API
responses, so a compare would be unreliable. Control-plane only: one file plus
unit tests, no recorder / DB / compose / client / migration changes.

**Rejected / not chosen:**

| Option | Verdict |
|---|---|
| **Keep PUT-all, accept the churn** | Rejected. It is the bug: orphaned producers accumulate one camera session per consumer and exhaust session-capped cameras; observability (`consumers`) is blind fleet-wide. |
| **Client-side applied-state map** (only PUT when desired != applied) | Rejected. Still trusts PUT-replace, re-clobbers once per api restart, and `PATCH` is the in-place primitive go2rtc actually provides. |
| **Carry a one-hunk patch to go2rtc** making `New()` a no-op for identical sources | Rejected for now. Fixes it for all API consumers but means patching/forking the pinned binary (golden rule 6); the `PATCH`-verb fix needs no binary change. Worth proposing upstream separately. |
| **Fall back to the sub-stream for capped cameras** | Rejected earlier in-session. Masks a fundamental control-plane defect; three clients would still each take a slot. |

**Cost accepted.** Reconcile now issues an extra `GET` per pass (negligible; passes
are rare in steady state). During the deploy transition, orphans created by the old
PUT-all behavior persist until the next go2rtc/recorder restart clears them (a
one-time artifact). `DELETE` also orphans running producers (documented on
`reconnect()`): after a camera swap, consumers on the old object keep pulling the
old source until their own watchdogs (~12 s recorder) reconnect, inherent to
go2rtc's API, not fixable here without a "drain consumers" primitive it doesn't
expose.

**Revisit triggers:**

- go2rtc upstream makes `PUT` idempotent for identical sources, then the
  create/patch split can collapse back to PUT-always.
- A camera source legitimately needs the single-segment `rtsp://` path form that
  the alias guard currently steers to `PUT`, then implement a first-class
  DELETE+PUT fallback for it.
- A need for immediate source propagation without `reconnect()` (e.g. bulk camera
  re-IP), consider a "drain consumers" admin action, not resurrecting PUT-all.

---

## 2026-07-06, Storage: Crumb owns recording/storage; do not read Frigate's storage for playback

**Context.** Crumb's headline value is smooth, frame-level timeline scrubbing
across many cameras. The question came up: for operators who already run Frigate,
could Crumb keep its own clients and operator UI but let **Frigate own recording
and archiving**, with Crumb's timeline/playback reading Frigate's stored footage
directly instead of Crumb's own storage system, as an optional "compose with
Frigate" mode? A deep dive (2026-07-06, reasoned against Frigate 0.17.x stable,
verified from docs.frigate.video and the `dev` source) settled it. Note the
inverse topology already ratified earlier (2026-06-19): Crumb is the streaming
hub and sole NVR, Frigate pulls from Crumb; this is its storage-side counterpart.

**Decision.** Crumb keeps owning recording and storage. Composition with Frigate
stays at the **event / clip / live-stream** level (MQTT detection events, proxied
clips and snapshots, live-stream peer), never at the storage level. The pivotal
finding: Crumb's smooth scrubbing is a property of its **recorder** (2 to 6 s
clock-aligned, keyframe-guaranteed fMP4 segments plus the Postgres index plus
prefetch), not its player. Frigate's stored files are faststart plain MP4 and are
seekable by libmpv/Media3, so raw file seekability is **not** the blocker one
might assume; the recorder properties that make scrubbing smooth simply cannot be
recovered by reading Frigate's storage.

**Rejected / not chosen:**

| Option | Verdict |
|---|---|
| **Frigate owns storage, Crumb's operator UI treats those cameras as first-class** | Rejected. Four core guarantees are unimplementable or structurally degraded (see below). A mode that silently downgrades Crumb's sacred guarantees for some cameras is worse than no mode. |
| **Read-only "Frigate history browser" overlay** (explicitly second-class) | Deferred, not rejected. Buildable as a bounded feature: mirror Frigate's recordings API into a side table (never the `segments` table), RO-mount its recordings dir behind the existing path-guarded file server, badge footage as Frigate-owned, no protect/policy knobs, best-effort export. Real work for a second-class experience; build only on demonstrated user demand. |
| **Compose at the event/clip/stream level (already shipped)** | Chosen. Gets nearly all the "already runs Frigate" value with zero storage coupling. |

The five decisive limitations of a "Frigate owns storage" mode:
1. **Segment shape is uncontrolled.** Frigate cuts ~10 s segments at the camera's
   keyframe (no forced GOP, no clock alignment, audio stripped by default). Seek
   precision and multi-camera boundary sync degrade to the operator's camera
   settings, versus Crumb's 2 to 6 s clock-aligned keyframe-guaranteed segments.
2. **Timeline gaps are the steady state.** Frigate's tiered retention deliberately
   turns each camera's history into islands of footage as tiers age out; Crumb's
   contiguous-scrub / prefetch model has no good answer to per-camera gaps.
3. **Protected bookmarks are unimplementable.** Frigate has no "hold a time range"
   primitive (only `retain_indefinitely` on detected-object events), and its
   emergency pruner deletes the oldest hour regardless of retention. The only
   honest fallback (copy protected footage into Crumb storage) reintroduces
   Crumb-owned storage into the mode.
4. **Index and lifecycle races.** Frigate's index is single-writer SQLite, local
   disk only, schema changing every minor release; any Crumb mirror is always
   stale against hourly plus 5-minute emergency deletion, so mid-scrub 404s and
   mid-export file loss are structural, not transient. No equivalent for per-policy
   size caps, free-space headroom, archive tiers, or the max-retention cap.
5. **Recorder correctness becomes someone else's cache.** Frigate's cache overflow
   discards the oldest unprocessed segments (documented silent footage loss), the
   exact failure the 2026-07-03 motion-recording decision rejected by name. Crumb's
   UI would present footage it can neither protect nor detect the loss of, which
   makes golden rule 2 (losing footage is the one unforgivable bug) unenforceable
   for the footage it displays.

**Cost accepted.** An operator with a large existing Frigate archive cannot browse
it inside Crumb today; the compose story is detection/clips/live, not "see my old
Frigate recordings." That is accepted over silently downgrading the storage
guarantees Crumb treats as sacred.

**Revisit triggers:**
- **Frigate adds a retention-hold (protect-a-time-range) API and a stable
  recordings API contract** → reconsider the bounded read-only overlay above.
- **Real user demand for a read-only "browse my existing Frigate archive inside
  Crumb" view** → build it as the explicitly second-class overlay, never as a peer
  storage backend.

---

## 2026-07-05, Retention: a configurable time cap + a neutral over-retention nudge (no hardcoded jurisdictional number)

**Context.** A pass over EU/UK data-minimization considerations flagged two things.
GDPR Art. 5(1)(e) requires footage be kept "no longer than necessary" for a
documented purpose, and the ICO explicitly says there is **no fixed statutory
min/max**. The "30 days / 72 hours"
figures operators cite are sector custom or an individual DPA's non-binding
benchmark, **not law**. Liability sits with the **operator** (CrumbVMS holds no
footage and is neither controller nor processor); the vendor's only exposure is
if a product feature *misstates the law*.

**Decision.**
1. **Feature, an opt-in, per-policy absolute time cap** (`max_retention_days`,
   migration `0042`). It sits alongside the existing size caps
   (`live_max_bytes`/`archive_max_bytes`) and the per-tier retention windows. It
   is a *hard ceiling across both live and archive stages*: footage older than
   the cap is deleted regardless of the other knobs. **Default OFF** (`NULL`) so
   it can never surprise-delete on an existing install, and when set it only ever
   removes footage *sooner*, never keeps it longer. Protected bookmarks still win
   (an explicit human pin is never auto-deleted). The recorder enforces it in
   `archive::max_retention_sweep` under the same crash-safe file-then-row ordering
   and `ARCHIVE_GUARD` serialization as the other sweeps.
2. **UI nudge, general information + disclaimer only.** A neutral note next to
   the retention controls in the policy editor: *"Keep footage only as long as you
   need it for your purpose. Some places regulate how long recordings of people
   may be kept, review your retention against your purpose and local law."* plus
   an explicit "this is general information, not legal advice, and does not assess
   your compliance" line.

**Rejected / not chosen:**

| Option | Verdict |
|---|---|
| **Hardcode a default number** (e.g. ship "30 days" as *the* retention or as the field's default) | Rejected, there is NO fixed legal number; presenting one as "the GDPR number" is exactly the misstatement that creates vendor liability. The field ships blank (OFF); the operator chooses. |
| **Assess/assert compliance in-app** ("✓ GDPR-compliant", "you are over the limit") | Rejected, a compliance *judgement* is legal advice and forfeits the liability-free framing. The nudge is deliberately non-committal: general info + disclaimer, never a verdict. |
| **Make the cap a replacement for the size/tier retention knobs** | Rejected, it's an *additional* constraint. Folding it into the existing knobs would change their meaning and risk deleting footage operators expected the tier settings to keep. |
| **Delete protected/bookmarked footage to honour the cap strictly** | Rejected, an explicit human "protect from auto-delete" pin must win over an automatic ceiling (golden rule 2: prefer the change that cannot surprise-delete footage). Documented as a known exemption in `docs/RESPONSIBLE-USE.md`. |

**Cost accepted.** The cap is not a strict guarantee (protected bookmarks and,
by construction, the batch-per-tick drain mean "older than N days" converges
rather than being instantaneous), and the nudge intentionally gives the operator
no compliance answer, both are deliberate: correctness/anti-footage-loss and
liability-framing discipline outrank a stricter or more opinionated design.

**Revisit triggers:**
- **A DPA (or statute) publishes a *binding numeric* retention limit** for a
  jurisdiction Crumb operators are in → revisit whether to surface that specific
  number (still as the operator's choice, clearly scoped to that jurisdiction),
  never as a global default.
- Operators report the batch-drain convergence is too slow to satisfy a real
  retention obligation → revisit the per-tick batch limit / add an immediate
  purge path.
- A future counsel review lands on whether an in-app retention/DPIA nudge is safe
  as framed → adjust wording to match.

---

## 2026-07-05, Contributor licensing: CLA (Apache ICLA v2.0), superseding DCO-only

**Context.** Crumb is AGPL-3.0, "free and open source, forever" for users. The
maintainer wants to preserve future optionality, specifically the ability to
**dual-license** (offer a paid commercial license alongside AGPL, the
MongoDB/Qt model) or otherwise change licensing course, without foreclosing it
before the project goes public. That ability requires the maintainer to hold, or
be granted, a sublicensable copyright license over all contributions.

**Prior stance.** CONTRIBUTING said **DCO, not a CLA**, chosen for
contributor-friendliness. But the DCO only certifies a contributor's *right to
submit*; it grants **no relicensing rights**. Under DCO-only, once outside
contributions land, the maintainer could never dual-license or relicense those
parts without tracking down every contributor. Pre-launch, solo, no outside
contributors yet → the maintainer owns 100%, so this is the cheapest moment to
change.

**Decision.** Adopt a **Contributor License Agreement** for outside
contributions: the **Apache Individual CLA v2.0**, adopted as-is (only the party
name changed), in `CLA.md`. Section 2's "sublicense" grant is what preserves
dual-licensing; contributors keep ownership. Enforced by the free
`contributor-assistant` CLA bot (`.github/workflows/cla.yml`), one comment per
contributor. The DCO per-commit sign-off is **retained** as a lightweight origin
certification, not the operative license grant.

**Rejected / not chosen:**

| Option | Verdict |
|---|---|
| **DCO only** (prior) | Rejected, no relicensing rights; permanently forecloses dual-licensing once contributions arrive. |
| **Copyright assignment** | Rejected, heavier, worse optics for a trust-first solo project; a broad license grant achieves the goal without taking ownership. |
| **Switch to source-available / non-compete** (BSL, PolyForm Shield) to block commercial exploitation outright | Not chosen now, forfeits the "open source" identity and reverses the public AGPL-forever commitment; premature before knowing whether Crumb is a business. The CLA keeps this door open without walking through it. |
| **Custom-drafted CLA** | Rejected, defeats the "no lawyer needed" goal; adopting a recognized standard as-is is the low-risk path. |

**Cost accepted.** CLAs add contributor friction (some decline to sign) and can
read as a "trust me" ask. Accepted because the optionality outweighs the
marginal friction this early, and the bot makes signing one click. **Not a
lawyer**, the ICLA text is adopted unmodified; a lawyer's review is deferred
until an actual commercial-license transaction, when it pays for itself.

**Revisit triggers:**
- Crumb commits permanently to "no commercial licensing, ever" → the CLA's
  relicensing purpose is moot; drop back to DCO-only to cut friction.
- A contributor base forms and CLA friction measurably deters contributions →
  reconsider (e.g. DCO + a narrower inbound license grant).
- An actual dual-license deal materializes → get the lawyer review then.

---

## 2026-07-03, Motion recording: RAM pre-buffer + persist-on-motion

**Problem.** `RecordingMode::Motion` was cosmetic: ffmpeg recorded 24/7 and
retention was purely time/size-based, identical to Continuous. Motion mode
delivered zero disk or storage savings.

**Research summary** (full survey in the session that produced this entry;
mechanism doc in `docs/MOTION-RECORDING.md`):

- **Enterprise / control-room VMS platforms** generally never gate capture: they
  ingest continuously into a short RAM pre-buffer and flush to the recording
  store on a trigger, so pre-event footage is always available.
- Some **prosumer NVRs** gate capture in motion mode, and their own docs note
  that true pre-alarm playback then requires continuous mode.
- The cleanest **hybrid** records a low-res sub-stream continuously and the main
  stream only on motion.
- Some consumer NVRs label a mode "motion-only" but actually record continuously
  and prune afterward, so the saving is retention-side, not ingest-side.
- **Frigate**: continuous 10 s segments into a tmpfs cache; a mover keeps only
  segments overlapping motion/events ± pre/post capture. Its worst documented
  failures are cache-related (tmpfs exhaustion, orphaned handles from crashed
  ffmpeg → silent footage loss).
- **ZoneMinder / Blue Iris communities**: recommend continuous recording over
  motion-gated capture because missed detections lose footage forever.

**Convergent industry finding:** every system that prioritizes not losing
footage captures first and decides afterward; the disagreement is only *where*
undecided footage waits (RAM / tmpfs / disk) and *how long* before the
keep-or-drop call is final.

**Options considered:**

| # | Option | Verdict |
|---|--------|---------|
| 1 | Capture-gating (start/stop ffmpeg on motion) | Rejected outright, no pre-roll, misses event starts, a missed detection means footage never existed. No reliability-focused system does this. |
| 2 | **RAM cache + persist-on-motion (the commercial-VMS model)** | **CHOSEN**, zero idle disk writes, zero idle storage; maps directly onto the existing 2–6 s segment pipeline and the already-built `MotionBuffer` state machine. |
| 3 | Record to disk → prune non-motion at segment close | Rejected: full continuous disk write load and transient storage "for no reason". |
| 4 | Record to disk → prune at retention with a grace window (24–72 h full-coverage safety net) | Rejected same grounds as 3. Chief advantage lost: a missed detection could still be recovered within the grace window. |
| 5 | Dual-stream hybrid (sub-stream continuous + main motion-gated) | Deferred to roadmap, best long-term answer for "never blind, still cheap", but a second recording pipeline + playback source switching is a separate project. Layers cleanly on top of option 2. |

**Safety rails that made option 2 acceptable** (both are invariants, see
`docs/RECORDER-CORRECTNESS.md`):

1. **Fail-open**: a camera whose motion detector is unhealthy (stalled
   sub-stream, dead decoder, no frames analyzed yet) persists *everything*
   until detection recovers, and raises a health alert. Blind-but-recording
   beats blind-and-empty.
2. **Spill, never drop**: cache pressure persists the oldest buffered segments
   to disk instead of deleting them. Footage is never lost to a full cache
   (Frigate's worst failure mode).
3. **Shadow mode** (`MOTION_RECORDING_SHADOW=1`) for rollout: record
   everything as before while stamping `segments.motion_shadow_keep` with the
   verdict the buffer would have made, so the keep/drop behavior is validated
   against real footage before any camera goes live.

**Trades knowingly accepted:**

- A genuinely missed detection (below threshold, not a pipeline failure) means
  that footage **never existed**. There is no safety net by design.
- A recorder crash loses whatever was in RAM, bounded by pre-roll seconds
  (commercial VMSes have the same property).
- Pre/post-roll resolution rounds to segment boundaries (2–6 s).

**Revisit triggers:**

- Missed-event reports from testers/users where the detector simply scored the
  motion below threshold → revisit option 4 (grace-window prune) as an opt-in
  per-policy "keep everything for N hours" safety net, or accelerate option 5.
- Deployments on hardware where RAM is scarcer than disk (SBCs, tiny NAS
  boxes) → option 3/4 as an alternative cache backend (disk cache dir instead
  of tmpfs, the commercial-VMS "disk-based pre-buffer" fallback).
- Demand for full 24/7 timeline coverage alongside motion savings → option 5
  (dual-stream hybrid, already on `docs/ROADMAP.md`).
- If shadow-mode validation shows the detector's keep/drop verdicts are not
  trustworthy on real footage, do **not** ship enforce mode, fix detection
  first or fall back to option 4.
