# Architecture decisions, and when to revisit them

A log of significant design decisions: what was chosen, what was rejected, and
the concrete triggers that should reopen the question. Add new entries at the
top. Keep entries honest about trade-offs, the point of this file is that a
future session (human or AI) can tell whether the world has changed enough to
revisit.

---

## 2026-07-18, Desktop release ships the Flutter client, not the retired Tauri app

**Status.** Decided during the v0.1.0 readiness audit; NOT yet implemented. The
tag-triggered `windows-release.yml` workflow and the ci.yml `desktop-lint` /
`desktop-linux` jobs still build `apps/desktop/src-tauri`, and must be repointed
to `apps/desktop-flutter` before v0.1.0 is tagged. (`macos-release.yml` builds
the native SwiftUI app via XcodeGen and is unaffected by this repoint.)

**Context.** The desktop client was rewritten in Flutter (libmpv over
`flutter_rust_bridge`; see the 2026-07-10 entry). Every desktop feature since,
the LPR Plates tab, the Home Assistant on-video overlay, the Data-saver tier,
the PTZ panel, and the A/B benchmark, lives only in `apps/desktop-flutter`. The
release path still builds the old Tauri crate, so tagging v0.1.0 today would
publish a Windows installer with none of the release's headline features.

**Chosen.** Repoint `windows-release.yml` and the CI desktop jobs to build
`apps/desktop-flutter` (the SwiftUI macOS app has its own workflow and is
separate; Linux as per-platform packaging lands), and drop the Tauri crate from
the release path.
**Rejected.** Ship the Tauri installer for v0.1.0 (advertises features the
shipped app does not have). Hold the desktop client out of v0.1.0 entirely (web
console + Android only, a worse story than shipping the real client).
**Trade-offs accepted.** Flutter Windows packaging and code signing must be
wired up. macOS packaging/notarization needs a Mac and the paid Apple Developer
account (the same blocker as the iOS app), so the macOS desktop release may lag
Windows. The Flutter Linux runner is unproven.
**Revisit.** If Flutter desktop packaging proves impractical on a platform, or
if the Tauri app is ever revived.

## 2026-07-18, First-run admin: seed by default with a memorable passphrase, keep the bootstrap window closed

**Status.** Implemented in `scripts/setup-env.sh`. It generates a memorable
two-word-plus-digits passphrase (e.g. `IcyApples473`) as `SEED_ADMIN_PASSWORD`,
prints it once at the end of the run, and the api seeds the `admin` user with it
at first boot. The browser create-admin wizard is now the opt-in path (blank the
seed to use it). Docs updated to "sign in with the printed password."

**Context.** `POST /auth/bootstrap` is unauthenticated, gated only by "refuse if
an admin already exists" (`auth.rs`). A blank seed leaves an unauthenticated
window on first run where anyone who can reach `:8080` on the LAN can claim the
admin account; the seed exists specifically to close that window (per the
`auth.rs` comment). But the previous `setup-env.sh` generated a random base64
password and deliberately did NOT print it, so the docs' "create your admin in
the browser" story was false, an operator hit a login screen for a password they
were never shown.

**Chosen.** Keep seeding by default (window stays closed) AND make the password
memorable and visible, so the documented "sign in with this password" flow is
true.
**Rejected.** Stop seeding by default (reopens the unauthenticated bootstrap
window, a secure-by-default regression). Keep seeding but leave the password a
random string (usable, but a worse first-run UX and no better on recovery).
**Trade-offs accepted.** A two-word + three-digit passphrase is roughly 21 bits
of entropy, weak for a password. It is acceptable only as a LAN-only STARTER
credential behind the login rate-limiter, meant to be changed after first login,
and is documented as such.
**Revisit.** If the console becomes internet-exposed by default, if login
rate-limiting is removed, or if a real first-run pairing/token mechanism replaces
the seed.

## 2026-07-17, Per-camera LPR: the engine dropdown is the single control (`none` added, `lpr_enabled` derived, source gate enforced at ingest)

**Status.** Built on `feat/lpr-admin-console`. Migration 0071 widens
`cameras_lpr_engine_chk` to `('none','frigate','crumb-alpr','both')` and
re-derives the stored `lpr_enabled`; `update_camera_lpr` /
`get_camera_lpr_config` derive `enabled` from the engine; the detection
ingester gates each plate read on the camera's engine accepting the read's
source; the admin console gained a dedicated LPR section (global knobs +
per-camera engine table + zone editor + watchlist/reads) and lost the
per-camera "worker should read this camera" checkbox.

**Context.** Migration 0069 gave each camera TWO LPR controls: `lpr_engine`
("which plate source feeds this camera") and `lpr_enabled` ("should the
crumb-alpr worker read this camera"). They overlapped and could contradict
(engine `crumb-alpr` with the checkbox off, engine `frigate` with it on), the
UI needed a paragraph to explain the difference, and there was no way to say
"LPR off for this camera" at all — the engine semantic was also only half
enforced (the crumb-alpr side at `POST /lpr/reads`, nothing on the Frigate
ingest side, so a `crumb-alpr`-only camera still silently stored Frigate
reads).

**Decision.** The engine dropdown is the SINGLE per-camera control, with
`none` as a first-class value meaning LPR off for that camera. `lpr_enabled`
survives only as a derived back-compat mirror (`engine IN
('crumb-alpr','both')`): the DB write derives it, the read path computes it in
SQL (so the worker's `GET /lpr/worker-config` poll keys off the engine even
against a stale column), and 0071 backfills it. The engine semantic is now
enforced symmetrically at the single choke point every read passes through
(the detection ingester): a read is stored only when the camera's engine
accepts its source, fail-closed on DB errors like the ignore-list, because the
per-camera setting is an operator privacy control.

**Rejected.**

- *Keeping two independent controls (checkbox + engine).* Redundant state
  that can contradict itself; every contradiction is a support question and
  the checkbox's only non-redundant state (worker-engine camera the worker
  should skip) is better expressed by switching the engine.
- *Dropping the `lpr_enabled` column outright.* Breaks the deployed worker's
  `cfg.enabled` check for zero benefit; a derived column costs one SQL
  expression and keeps old workers correct.
- *A separate per-camera on/off toggle beside the engine (`none` not in the
  enum).* Same two-control contradiction with new paint.
- *Gating Frigate-sourced reads in `detection/frigate.rs` instead of the
  ingester.* Leaves `POST /lpr/reads` and any future provider to re-implement
  the same rule; the ingester is the one path every read already crosses.

**Trade-offs accepted.** One extra `cameras` lookup per plate-carrying event
in the ingester (plates are low-rate; acceptable). Existing `crumb-alpr`-only
cameras stop storing Frigate reads — that is the documented 0069 semantic
finally enforced, but it IS a behavior change for anyone relying on the leak.
A camera whose engine was `both`/`crumb-alpr` with the old checkbox off
becomes worker-readable after the 0071 backfill (the engine now wins).

**Revisit triggers.** A third engine source appears (the accept-rule match in
the ingester grows; consider a source→engine capability table). Operators ask
for "store reads but never worker-scan" (would need the two-control split
back, as an explicit worker toggle). Per-camera LPR config grows past what a
table row holds comfortably (dedicated per-camera LPR detail pane).

---

## 2026-07-17, LPR A/B benchmark: passes derived at report time (two-phase clustering), truth keyed on (camera_id, bucket_ts)

**Status.** Built on `feat/lpr-ab-benchmark`. Backend: `GET /lpr/ab-report` +
`POST /lpr/ab-confirm` in `plates.rs`, pure pairing logic in
`services/common/src/lpr_ab.rs`, `lpr_pass_truth` table (migration 0070).
Desktop: a Benchmark dialog off the Plates screen, visible only when the server
reports a `lpr_engine = 'both'` camera. This is the "engine comparison" item
the 2026-07-17 native-engine plan deferred (its §10), now scoped to the two
built-in engines.

**Context.** With `lpr_engine = 'both'` every physical vehicle pass produces
`plate_reads` rows from BOTH Frigate's native LPR and the crumb-alpr worker —
plus Frigate's own self-duplication (it re-emits a read for the same pass as
its OCR refines, e.g. `9GXVL98` then `9GXV498` ~5 s apart, under different
provider event ids). To score the engines head-to-head (hit rate, agreement,
accuracy against operator-confirmed truth) the reads must be grouped into
per-vehicle "passes", but no pass entity exists in the schema and the two
engines share no join key.

**Decision.** Passes are **derived at report time, never stored**: a pure
in-memory clustering (`lpr_ab.rs`, unit-tested without a DB) over the raw
reads in the requested range. Two phases: (1) intra-engine collapse — reads
chain into a cluster when within the pairing window (default 8 s, query-tunable)
of the cluster's latest read AND fuzzy-matching its plate under the **same
length-scaled Levenshtein model the watchlist uses** (`levenshtein` /
`allowed_edits`, reused not reimplemented; pairing fuzz defaults to 0.25,
independent of the operator's alert fuzz which is often 0), keeping one best
read (highest confidence) per engine-cluster; (2) cross-engine one-to-one
pairing, greedy by fuzzy-plate agreement first, then pure time proximity — so
two cars passing close together pair with their own reads, while a wild
engine disagreement still lands in ONE pass (a disagreement to surface, not
two fake misses). Ground truth (`lpr_pass_truth`) is keyed on
**`(camera_id, bucket_ts)`** where `bucket_ts` is the pass's earliest kept-read
timestamp floored to whole seconds — echoed verbatim by the client on confirm.

**Rejected.**

- *Storing passes (a `lpr_passes` table maintained at ingest).* A stored
  grouping freezes today's clustering bugs into data, needs migration/backfill
  churn to tune the window, and adds ingest-path risk for a reporting feature.
  Derived-on-read costs a few ms over ≤10 k reads and lets the operator re-run
  the same data under a different window/fuzz instantly.
- *Truth keyed on a representative read id.* Simpler-looking, but retention
  prunes `plate_reads` (the id dangles) and the "representative" read can
  change as clustering parameters move; the time-bucket key survives both and
  degrades benignly (an orphaned truth just shows the pass unconfirmed again).
- *Time-only cross-engine pairing.* Merges two cars that pass within the
  window; the fuzzy-first tier fixes that without splitting genuine
  disagreements.
- *SQL window-function clustering.* The fuzzy-plate chain condition
  (Levenshtein against the cluster's evolving best) doesn't express cleanly in
  SQL; in Rust it is trivially unit-testable.

**Trade-offs accepted.** A pass's `bucket_ts` can shift if a straggler read
arrives after an operator confirms (orphaning that truth row) — benign and
rare, since engines finish refining within seconds and operators confirm
minutes later. Report stats cap at the newest 10 000 reads per query
(`truncated` flag tells the client to narrow the range). Intra-engine garbage
reads far outside the fuzzy budget split into separate passes and inflate
"miss" counts slightly.

**Revisit triggers.** A third engine joins the comparison (the pairing is
two-engine-shaped; N-way needs a different pass model). Operators report
orphaned confirmations in practice → move truth to a stored-pass model.
Cameras with continuous traffic (parking lots) where the >10 k-read cap or the
greedy pairing visibly misgroups → revisit stored passes / SQL pre-bucketing.

---

## 2026-07-17, Crumb-native LPR engine: `fast-alpr` sidecar via `POST /lpr/reads`, keeping `plate_reads` engine-agnostic

**Status.** Building on `feat/lpr-native`. Backend (ingest endpoint + crop
plumbing + per-camera columns + worker-config) done and gated; the `crumb-alpr`
worker and admin/wizard surfaces follow. Fires the revisit trigger of the
2026-07-13 LPR entry below ("a validation month shows Frigate LPR materially
under the canceled cloud plan's hit rate → wire the operator's OpenALPR box or a
`fast-alpr` sidecar through `POST /lpr/reads`").

**Context.** The 2026-07-13 decision chose Frigate native LPR as the only engine.
Validation on Frigate `0.18-beta` showed it materially weak on the operator's
overview angle. The paid OpenALPR/Rekor engine reads better, but its "Watchman
Home" (Basic) license was proven to **hard-block all non-cloud data delivery** —
the agent's own log refuses a local destination and force-restarts — and the Pro
tier that unlocks a local webhook is too costly. The open-source OpenALPR C++
engine is 2018-era, worse than current Frigate, and painful to build. So Crumb
needs its own free, fully-local, better-than-Frigate engine.

**Decision.** Add a Crumb-native OCR engine, **`fast-alpr`** (a YOLOv9-t ONNX
plate detector plus a CCT-xs ONNX OCR), run as an **opt-in `crumb-alpr` Python
sidecar** (compose `alpr` profile). It pulls a camera's go2rtc restream,
motion-gates, votes across a vehicle pass, and POSTs one read to a new
**`POST /lpr/reads`** (authenticated by the `lpr_config` ingest token, not a user
JWT). The endpoint builds a `crumb-alpr` `NormalizedEvent` and pushes it into the
**same detection-ingester channel Frigate uses**, so dedup, ignore-list,
watchlist, alerts, and the timeline mirror are reused verbatim — the only new
plumbing is carrying the crop JPEG bytes into `plate_reads.crop`. `plate_reads`
stays engine-agnostic (already tags each read by `source_id`). Per-camera
`lpr_engine` (`frigate` / `crumb-alpr` / `both`), `lpr_min_confidence`, and
`lpr_zones` (include/exclude polygons) columns (migration 0069) drive the worker,
which polls `GET /lpr/worker-config` so admin edits apply without a restart.
Benchmarked on real operator footage: 24 of 25 frames correct at ~0.99 char
confidence, ~37 ms/frame CPU-only, so ~7 percent of one core motion-gated. No GPU.

**Alternatives rejected.** (1) **OpenALPR Pro** (~72 USD/mo/camera) — cost, and
still a cloud-license gate. (2) **Resurrect OSS OpenALPR** — old engine, worse
than Frigate, build pain. (3) **Rust-native ONNX via the `ort` crate** — deferred:
reimplementing the YOLOv9 and CCT pre/post-processing in Rust is real work; the
Python sidecar ships now and reuses `fast-alpr`'s CCTV tuning. (4) **OpenALPR
local 8355 pull API on Basic** — its `/list` needs a diagnostic mode that appears
license-gated; unreliable.

**Trade-offs accepted.** A new optional Python service and image (golden rule 6):
justified because it is opt-in, isolated, and only runs when enabled. Model
weights are **YOLOv9-derived (GPL-3.0)** — compatible with Crumb's AGPL-3.0 — and
are **not vendored**: they download at first run, so Crumb never redistributes
them (air-gapped installs pre-fetch; see `docs/LPR-NATIVE-ENGINE-PLAN.md`). The
Python sidecar is heavier per-inference than the paid engine's C++, but light
enough for a single gated camera. `plate_reads.crop` now stores bytea for the
external path (Frigate still uses `snapshot_url`).

**Revisit triggers.** `fast-alpr` accuracy underperforms in real use → try a
different open model, add the CCTV re-detect/upscale tuning, or the Rust-native
port. The Python dependency or image size becomes a maintenance burden → port to
Rust `ort` (weights are already ONNX). A maintained permissively-licensed
detector appears → swap it to drop the GPL-weight exposure entirely. An operator
wants a live three-way `crumb-alpr` vs `frigate` vs `openalpr` comparison → build
the deferred stats panel (every read is already `source_id`-tagged).

## 2026-07-16, Recording policies: explicit named membership replaces NULL-inherit + anonymous COW forks

**Status.** Phase 1 (server-only) landed the `origin` column + the collapse
migration (`0067`), `create_camera` joins Default, the deviation-edit semantics,
and the reaper predicate. **Phase 2 (server-only) landed here:** migration
`0068` drops the 0020/0021 grouped-camera triggers, pins every inheriting camera
to the policy the effective-policy view resolved (grouped → group's policy, else
Default), and enforces `cameras.policy_id NOT NULL` + `recording_policies.name
NOT NULL` + a unique index on `name`; the boot shim
(`ensure_named_policies_and_groups`) that previously ran `ALTER COLUMN policy_id
DROP NOT NULL` on **every boot** was inverted to a guarded `SET NOT NULL` (L4);
the group endpoints became **write-through** (a group pins its members'
`policy_id` directly — no inheritance), `camera` policy assignment maps the old
`Some(None)` "clear to inherit" to joining Default, and `require_assignable_policy`
reduced to existence. The `camera_groups`/`camera_group_members` tables are kept
DORMANT for one release (rollback comfort); `v_camera_effective_policy` is
untouched (its COALESCE degenerates to leg 1). Phase 3 (admin UI: policy
manager, member lists, bulk assign, group-UI retirement, dropping the `"Custom —
…"` label fallbacks, and the final groups-table drop) is staged per
`docs/design/POLICY-MODEL.md` §8 and NOT yet landed.

**Context.** A camera's effective recording policy resolved through a
three-leg COALESCE (`v_camera_effective_policy`: own `policy_id` → group's
`policy_id` → the `is_default` row), and three code paths minted **anonymous
(`name IS NULL`) copy-on-write policy rows**: every `POST /config/cameras`
cloned the Default into a fresh fork (`config_routes.rs` `create_camera` →
`clone_default_policy`), every save from the admin Motion tab PUT
`/config/cameras/{id}/policy` (the COW fork path) even with unchanged values,
and the desktop Motion Tuner used the same endpoint. Result in prod: unnamed
policies byte-identical to Default that no UI could see or manage ("ghosts"),
exposed when the Storage Advisor started labelling them "Custom — \<camera\>".
The NULL-inherit state also carried a real recorder hazard: an inheriting
camera resolves through `(SELECT id FROM recording_policies WHERE
is_default)`, so a missing/duplicated default row silently drops the camera
from the recorder's inner JOIN — it just stops recording, no error.

**Decision.** Every camera holds a NOT NULL `policy_id` to a **named** policy.
(1) *Deviation auto-creates*: a camera-scoped settings edit on a shared policy
mints a new policy auto-named after the camera (renameable), joins it — no
naming dialog. (2) *De-dup on create*: if the edited field-set exactly matches
an existing policy (all behavior columns, `IS NOT DISTINCT FROM`), the camera
**joins** that policy instead; reverting to Default's values rejoins Default.
(3) *Reap empties, keep templates*: a new `origin` column
(`'operator'`|`'deviation'`) distinguishes auto-created deviation policies
(reaped when memberless) from operator-created templates (kept at zero
members); renaming a deviation policy promotes it to `'operator'`.
(4) *Default is first-class*: new cameras join the Default **row** (no clone,
no NULL); `is_default` keeps meaning "the policy new cameras join" and stays
undeletable. (5) *Camera groups retire*: a policy's member list **is** the
group; group tables/endpoints are dissolved into direct assignment + a bulk
"assign policy to cameras" action (the 0020/0021 triggers already made a
group nothing more than an indirection naming one policy assignment).
One-shot migration collapses byte-identical forks into Default, names
genuinely-distinct ones after their camera, and pins every camera, under the
invariant that **no camera's effective policy field-values change** and no
merge may make footage immediately eviction-eligible (byte-cap pools are
compared before collapsing; unsafe merges keep the fork as a named policy
instead).

**Rejected.**
- *Keep NULL-inherit + fix the fork leak*: keeps the invisible state and the
  0-defaults-silently-stops-recording hazard; the DB cannot enforce "every
  camera has a policy" while NULL means something.
- *Interrogate on deviation* (naming dialog before every edit): friction on
  the most common tuning action; auto-name + rename-later matches VMS
  convention.
- *Per-camera overlay/deltas on top of a policy* (Milestone-style "override
  flags"): more faithful to "tweak one camera" but reintroduces two sources of
  truth per knob; revisit if policy-count explosion materializes.
- *Keep groups as a separate assignment layer*: a group was already
  policy-exclusive and authoritative (migrations 0020/0021); two mechanisms
  for one job is where the confusion came from.

**Trade-offs accepted.** Collapsing/joining policies pools the shared
`live_max_bytes`/`archive_max_bytes` budget across the merged membership
(that is the intended meaning of "same policy"); a one-time worker respawn
per repointed camera (the effective-policy id is in the recorder's change
fingerprint); the policy list can grow with one policy per deviating camera
(visible and manageable, unlike the ghosts).

**Revisit triggers.** Operators with large fleets report the policy list
becoming noise from many single-camera deviation policies (→ revisit the
overlay model). A need re-emerges for camera grouping *unrelated to
recording* (bulk ops, UI folders) (→ reintroduce groups as pure tags with no
policy pointer). The recorder gains per-camera knobs that don't belong on a
policy (→ keep them on `cameras`, as motion sources already are).

---

## 2026-07-16, Clips are fixed-length event overviews; the timeline owns whole-event viewing; open events are janitor-closed

**Context.** `GET /clip/{id}/clip.mp4` rendered a detection/motion event's full
`[start, end)` window: the renderer concatenates every overlapping 4 s segment
and transcodes it (`services/api/src/clips.rs`). Event windows are unbounded in
practice — Frigate tracks a parked car for hours, and ~123 `events` rows had
`end_ts = NULL` (never closed; oldest a month old). In prod (2026-07-16) one
~10-hour event made the renderer build a multi-hour transcode; concurrent
client retries (each a fresh cache miss, since the cache file never finished)
consumed all `CLIP_GEN_MAX_CONCURRENCY` permits and pinned the API at 600%+
CPU, starving ALL clip playback. A 30 s hard clamp shipped as a stopgap
(`fix/clip-window-clamp`).

**Decision — a clip is an overview.** A clip is a short, representative
snippet of an event, *by definition* independent of event length. The rendered
window is `[start − pre_roll, start − pre_roll + overview_len)`, truncated to
the event end (+ post-roll) when the event is shorter. `overview_len` is an
admin-tunable server setting (`clip_overview_seconds`, default 30, clamped
10–30, same pattern as `clip_pre_roll_seconds`); a compiled hard ceiling
(30 s) remains as the safety floor — a clip is a glance-level overview, and
beyond ~30 s it drifts back toward "watch the event". Watching the *whole* event is the
timeline's job — recorded playback streams segments directly with no
whole-event transcode — so clients surface event duration + an "ongoing" flag
in the feed and make the existing "View on timeline" deep-link the explicit
"see the whole event" affordance. `q=preview` and `q=full` are two renditions
(640p vs source resolution) of the *same* overview window; both are generated
once to the cache and served as files, with a per-clip singleflight so
concurrent misses transcode exactly once, and cache keys/ETags that include
the window parameters now that they are tunable.

**Decision — events must close themselves.** `end_ts` correctness is owned by
an API-side *event janitor* (new background task next to the existing cache
sweeper): every open event whose `updated_at` (new column, stamped on every
upsert) is older than a stale timeout (default 30 min) is closed with
`end_ts = GREATEST(ts, updated_at)`, `lifecycle = 'end'`. A late genuine `end`
from the provider self-heals via the existing
`end_ts = COALESCE(EXCLUDED.end_ts, events.end_ts)` upsert. The recorder is
deliberately untouched: its `events` writes are surfacing-only and best-effort
by design, and the footage-affecting analogue already exists
(`MAX_OPEN_SIGNAL_SECS` in `recording.rs`).

**Rejected.**
- *Clip = full event (status quo)*: the incident; also unbounded memory in the
  Frigate proxy path.
- *Peak-anchored clip window*: no peak timestamp exists (`events.top_score`
  has no `peak_ts`, and Frigate `update` messages are mostly filtered out), so
  it cannot be computed today; onset + pre-roll is where causality lives and
  matches the thumbnail. Retrofit for motion clips only (via
  `segments.motion_score`) is a later polish option.
- *`q=full` = whole event*: recreates the incident and conflates quality with
  scope; whole-event viewing is the timeline, whole-event *files* are exports.
- *Bounding events at ingest (cap `end_ts − ts`)*: events are ground truth — a
  car parked 10 h *is* a 10 h event; the render is what must be bounded.
- *Janitor in the recorder / DB trigger*: the recorder must not gain DB
  lifecycle duties near the footage path (golden rule 2); a trigger hides
  policy in the schema and can't express "stale" cleanly.
- *503 on semaphore exhaustion*: with singleflight + short (≤30 s) transcodes
  the queue drains in seconds; bounded awaiting is simpler than teaching four
  clients a retry-after protocol.

**Consequences.** New migrations (`events.updated_at`,
`server_settings.clip_overview_seconds`); `/clips` descriptors gain
`ongoing` + the response gains `overview_seconds`; both clip caches (`preview`
and now `full`) are files under `{export_dir}/clips` swept by the existing
TTL/byte-budget sweeper; clients drop the `&_r=` cache-bust retry (server
files make retries idempotent); the Frigate clip proxy only proxies events
short enough to be overviews and falls back to own-footage rendering
otherwise. The 123 legacy NULL rows close automatically one janitor period
after deploy.

**Revisit triggers.** Operators demand true whole-event clip *downloads* (→
route through the export system, not the clip endpoint). A provider starts
delivering a reliable peak timestamp (→ revisit peak-anchoring). The clips
feed moves to pre-generated/notification-time media (→ revisit on-demand
generation entirely). `clip_overview_seconds` upper clamp proves too small for
a real workflow (→ raise ceiling, re-check transcode cost).

---

## 2026-07-16, Android recorded-playback seeking: add `+global_sidx` to the recorder mux (not HLS, not a server index)

**Problem.** On the Android client, recorded-playback seeking was completely
broken — frame-step (both directions), scrubbing, and datetime-jump all snapped
back to the start of the current segment. Desktop (mpv/libmpv) seeks the same
footage fine. Reported as "Android frame stepping doesn't work at all, forward
and back."

**Root cause (proven on-device via logcat + `ffprobe` across the whole segment
fleet).** The recorder writes fragmented MP4 (`+frag_keyframe+empty_moov+default_base_moof`)
with **no `sidx` (segment-index) box**. Media3/ExoPlayer's `FragmentedMp4Extractor`
builds a seekable `SeekMap` *only* from an `sidx`; absent one it reports the
stream unseekable and every `seekTo` collapses to position 0 (observed as
`onPositionDiscontinuity reason=2 (SEEK_ADJUSTMENT) -> 0`). libmpv scans the
byte stream directly and never needed the box, which is why only Android broke.
This is a footage-*playback* defect, not a footage-integrity one, but the fix
touches the always-must-work recorder so it went through golden-rule-2 gates
(below).

**Options considered:**

| # | Option | Verdict |
|---|--------|---------|
| 1 | **Add `+global_sidx` to the recorder's `-segment_format_options movflags`** | **CHOSEN.** One flag on the existing `-c copy` remux — no re-encode. Writes one `sidx` per finished segment (~176 B, into reserved space at finalize, not a rewrite). Makes the *same* footage seekable by ExoPlayer; desktop is byte-for-byte unaffected in behavior. |
| 2 | **Re-mux/serve recorded playback as HLS** (fMP4 segments + a media playlist) | **REJECTED** (Fable adversarial round). Would replace a working native-mp4 seek model in every client with a playlist model, and regress the *good* desktop mpv in-segment scrub. Frigate's poor H.265 scrubbing is a *browser HEVC-decode* limitation, not an HLS win — Crumb decodes natively (mpv + ExoPlayer MediaCodec) and doesn't share it. No seek-smoothness upside for the cost. |
| 3 | **Server-side seek index / custom container** | **REJECTED.** Same conclusion as the 2026-07-07 scrub-preview entry (option 4/5): nothing inside a ~2 MB / 4 s segment is worth indexing server-side, and an index cannot create keyframes. The real gap was purely the missing in-container `sidx` box, which the muxer already knows how to emit. |
| 4 | **Client-only workaround** (custom ExoPlayer `SeekMap`, or force-decode-from-0) | **REJECTED.** Fragile per-client reimplementation of what the container standard already specifies; would have to be rebuilt for every future client. Fix the bytes once, at the source. |

**Gates run before touching the recorder (golden rule 2 — recorder correctness):**

- **Crash safety.** A segment killed mid-write is **byte-identical** with vs.
  without the flag (786 460 B, same box layout) — the `sidx` only lands when the
  muxer finalizes the file, so `+global_sidx` introduces **no new footage-loss
  mode**. This is why it composes with the existing `+frag_keyframe+empty_moov`
  crash-safety flags rather than weakening them.
- **Finalize I/O.** +176 bytes/segment, filled into reserved space (`global_sidx`
  reserves the box up-front); measured no full-file rewrite at close. Negligible.
- **Objective seek proof (Gate 3, headless — no device).** A real Media3
  `FragmentedMp4Extractor` unit test (`apps/android/.../SidxSeekTest.kt`) over two
  real Crumb HEVC segments (same source, remuxed with vs. without `+global_sidx`):
  the `+sidx` segment yields a seekable `SeekMap` that seeks to distinct
  mid-segment frames; the no-`sidx` segment is not seekable (reproduces the bug).
  This ships as a permanent regression test so a future mux change that drops the
  box fails CI instead of silently re-breaking Android.

**Trades knowingly accepted.** ~176 B/segment (well under 0.01% of a ~2 MB segment). The
Android client still needs a step *redesign* (play-until-next-frame) for smooth
per-frame stepping — seekability is necessary but the ms-seek stepping shape is
a separate client change; tracked separately. Fix does nothing for, and is
independent of, the desktop Driveway frame-step edge (that camera's GOP, handled
client-side).

**Revisit triggers:** a client appears that *does* want HLS/DASH for adaptive
bitrate (re-evaluate option 2 as an *additional* delivery path, never a
replacement for the native-mp4 seek model); segment length grows past minutes
(then a coarser index inside a segment could matter); ExoPlayer/Media3 gains the
ability to build a `SeekMap` without an `sidx` (then the flag is optional, though
harmless).

---

## 2026-07-16, CI publishes amd64-only Docker images (dropped the arm64 multi-arch leg)

CI (`.github/workflows/ci.yml`) built the api + recorder images multi-arch
(`linux/amd64,linux/arm64`) on every push to `main`. The arm64 leg is a
QEMU-emulated Rust release compile that took ~60-70 min, so every backend
deploy off a `main` sha waited well over an hour for an image, versus ~7 min
for amd64 alone.

**Chosen:** build `linux/amd64` only (dropped the arm64 platform and the QEMU
setup step).

**Rejected:** amd64 on every push + arm64 only on release tags (`v*`). Cleaner
in theory, but the project has no tagged releases yet and no known ARM
operator, so it was ceremony for a hypothetical.

**Trade-off accepted:** anyone wanting to run the **Crumb server** (recorder +
api) on ARM hardware — a Raspberry Pi / ARM SBC, an ARM cloud instance, or an
Apple Silicon Mac via Docker Desktop — no longer gets a native image and would
run amd64 under emulation (slow) or build it locally. The clients are
unaffected (Android ships its own APK; the desktop app is a separate build).

**Revisit when:** a real operator wants to self-host the server on ARM, or the
project starts cutting tagged public releases for varied hardware — at which
point re-add arm64, ideally gated to `tags: v*` so per-push deploys stay fast.

---

## 2026-07-15, One shared drag-to-place overlay editor (PTZ panels + HA badges) with raw-tracked snapping; per-badge HA style stored on camera_ha_links (migration 0059)

The desktop client had two drag-to-place editors: the shared
`apps/desktop-flutter/lib/ui/overlay_editor/` (used only by HA badges) and
the PTZ panel builder's own older copy in `lib/ui/ptz/`. Both had the same
unusable UX: aggressive snapping that trapped drags/resizes, and per-pointer-
move `notifyListeners()` rebuilding the whole layer + editor bar + palette
(the stutter).

**Chosen:**

- **One editor.** The PTZ builder was ported onto the shared
  `overlay_editor/` (a `PtzOverlayButtonItem` adapter over `PtzPanelButton`;
  view-mode ONVIF dispatch and button visuals stay PTZ-local in
  `ptz_panel_overlay.dart`/`ptz_panel_palette.dart`). The PTZ builder's
  private drag/snap/bar code was deleted (`ptz_panel_editor_bar.dart`, plus
  the never-wired `ptz_custom_panel.dart`/`ptz_interaction_overlay.dart`).
- **Raw-tracked snapping.** The root cause of "snaps like crazy": the old
  code applied the snap delta to the already-snapped position every tick, so
  a snapped item could only escape if one pointer event out-ran the radius.
  The editor now accumulates the UNSNAPPED gesture position and snaps that —
  standard editor feel; escape is just moving past the radius. Plus: radius
  7→6px, resize snaps to edges only (never centers), hold-Alt bypasses
  snapping per gesture, and a Snap on/off toggle lives in the bar.
- **Split notifications.** The controller notifies structure changes
  (selection/add/remove/mode) normally, but drag ticks fire only a
  lightweight `geometry` ticker that just re-positions each item's
  `Positioned` (visual subtrees are prebuilt and wrapped in
  `RepaintBoundary`).
- **Selection tooling** shared by both hosts: multi-select
  (click/Shift-Ctrl-toggle/marquee), align/distribute, match-width/height/
  size to the last-clicked item, an explicit numeric size field, and
  group/ungroup (`OverlayItem.groupId` — persisted in PTZ button JSON;
  session-only for HA badges, whose placement PUT has no group field).
- **Per-badge HA style on `camera_ha_links`** (migration 0059, mirroring
  0058's placement columns): `overlay_color` ('#RRGGBB'), `overlay_icon`
  (curated slug), `overlay_show_state`/`overlay_show_age` (pin the live
  state text / relative age next to the badge). Written by the existing
  placement PUT (admin), carried over by `replace_camera_ha_links`, reset
  when a placement is cleared. The link-level `label` can also be edited via
  the placement PUT with the `PUT /config/ha` token convention (omitted =
  unchanged, "" = clear). Badge captions/hover/tap-card are all anchored to
  the badge's placed position (the old tile-corner card collided with the
  camera-name label and back button).

**Rejected:**

| Option | Why not |
|---|---|
| Fix the PTZ editor in place and keep two editors | Two copies of drag/snap/selection logic to maintain and the HA editor had the same defects; the shared editor was always the plan (issue #170 §3.3 P1). |
| Snap hysteresis (larger escape threshold once snapped) | Treats the symptom; raw-position tracking is how every layout tool behaves and needs no second tunable. |
| A separate `ha_badge_style` table | Same wipe/join issues that rejected a separate placements table in 0058; the style is 1:1 with the placement. |
| Storing HA badge groups server-side | Needs a schema field for a purely layout-time convenience; revisit if operators ask for persistent badge groups. |

**Revisit triggers:** operators asking for roaming (server-side) PTZ panels
(would reuse the placement plumbing precedent); persistent HA badge groups;
a second client (Android/web) porting the overlay editor (the
geometry/controller layer is Flutter-foundation-only by design).

---

## 2026-07-14, Live plate crop boxes: normalize Frigate's pixel-corner MQTT boxes with detect dims fetched from /api/config (issue #157)

Frigate 0.18 sends the `license_plate` attribute box in **two different
conventions by transport**, verified live against the same event: the HTTP
`/api/events` `data.attributes` box is normalized `[x, y, w, h]`, while the
live MQTT `current_attributes` / `snapshot.attributes` box is **pixel corners
`[x1, y1, x2, y2]` at the camera's detect resolution** — which is not carried
in the MQTT payload. Without the frame dimensions, live reads could never
store a crop box at ingest (and there is no periodic HTTP backfill; only an
API restart ever filled them in).

**Chosen:** fetch each camera's detect resolution from Frigate `/api/config`
at provider start and refresh it on the existing 1-minute camera-map reload
tick; interpret a pixel box (with dims) as **corners first** — a real plate
always has `x2>x1 && y2>y1` — with a defensive origin+size fallback. Also read
the box from `snapshot.attributes` (the emitting frames have empty
`current_attributes`, but Frigate keeps the snapshot frame's attributes on the
`snapshot` sub-object). Best-effort throughout: a missing/failed dims fetch
only costs the crop, never the plate text or detection.

**Rejected / not chosen:**

| Option | Why not |
|---|---|
| **One-shot HTTP `GET /api/events/{id}` per boxless read** (take the normalized HTTP box at emit time) | Adds a per-read HTTP round-trip and an availability dependency inside the MQTT hot loop; racy right at `end` (the event row may not be finalized). The config fetch is one small request a minute with the same self-heal property. |
| **Derive dims from the payload** (e.g. `snapshot.region`) | Regions are square crops, not the frame; nothing in the MQTT payload states the detect resolution. Guessing a scale risks silently wrong crops — worse than no crop. |
| **Interpret pixel boxes as `[x, y, w, h]`** (the old speculative rule 4) | Disproven by live capture; corners is the observed convention. A pixel plate box read as xywh would produce a garbage crop whenever `x2 ≤ 1 − x1` fails etc. The xywh reading is kept only as a fallback for values that cannot be corners. |

**Revisit triggers:** a Frigate release that changes the MQTT attribute-box
convention or starts carrying detect dims (or normalized boxes) in the event
payload; crop-box support for a second detection provider (would motivate
moving dims discovery behind the provider trait).

---

## 2026-07-14, Backward wall-clock step: preserve existing footage over the colliding segment (recorder, issue #144 item 2)

On an RTC-less SBC the wall clock can jump **backward** after an NTP sync. Since
segment filenames are strftime-encoded (`%Y%m%dT%H%M%SZ.mp4`, second
resolution), a backward step makes a new segment's filename/timestamp collide
with an **already-persisted, already-indexed** segment. The DB row key is
`(camera_id, stream, start_ts)`, so the two segments are indistinguishable at
the index level.

**Chosen:** when the persist path (Motion-mode cache→storage copy, the step the
recorder controls) detects that the destination file already exists, it (a)
writes the new segment to a non-colliding `-rN` sibling name instead of
overwriting, and (b) indexes it with a **DO-NOTHING** insert so the older
segment keeps its row. Net: the **existing indexed footage always wins**; the
colliding new segment survives on disk as an un-indexed orphan (never deleted).
The partial-cleanup on a failed copy (item 7) only ever removes a destination
confirmed absent immediately beforehand, so it can never delete good footage.

**Rejected / not chosen:**

| Option | Why not |
|---|---|
| **Index BOTH colliding segments** (change the conflict key to include `path` or add a monotonic counter) | Requires a schema migration + a filename-scheme change and ripples through reconcile/retention/export. Out of scope for a correctness fix; the safe outcome (keep the older, orphan the newer) loses no footage. |
| **Let the UPSERT repoint the row to the new segment** | Steals the row from the older segment, turning *its* still-present file into an un-adoptable orphan — i.e. drops the older footage from the timeline. Backward from the goal. |
| **Fully prevent the direct-to-storage (Continuous-mode) file truncation** | ffmpeg writes those files itself and O_TRUNCs the colliding name before the recorder ever sees the segment; preventing it needs a filename-uniqueness change (the schema option above). Flagged as a residual: the recorder-controlled cache path — the common SBC/Motion-mode case — is fully protected; the direct path is detected/logged only. |

**Revisit triggers:** reports of clock-step footage loss on Continuous-mode
cameras (would justify the monotonic-counter filename scheme), or a decision to
support sub-second segment resolution (would change the collision surface).

---

## 2026-07-13, Fuzzy plate matching: length-scaled character tolerance (edit distance), superseding pg_trgm trigram similarity

The watchlist/ignore "fuzzy match" (from the same-day ignore-list + fuzzy entry
below) originally matched a read against a watch/ignore plate with Postgres
`pg_trgm` `similarity(read, target) >= 1 - fuzz`. In practice this was unusable:
trigram similarity for short, word-boundary-free strings like plates is
dominated by the padding trigrams, so a **single** wrong character on a 7-char
plate scores ~0.45 — below the tightest reachable threshold (fuzz is clamped to
0.5 → threshold 0.5). The feature therefore could not catch the exact case it
exists for (Frigate ALPR misreading one character), and the "%" exposed to the
operator mapped to nothing intuitive.

**Chosen:** match by **normalized character edit distance**. Normalize both
sides (uppercase, keep only `A–Z0–9`), and accept when
`levenshtein(read, target) <= floor(fuzz * len(target))`. fuzz stays the same
stored 0..0.5 float (no migration); its meaning becomes "what fraction of the
plate's characters may differ" — 20 % ≈ 1 character on a 6–7 char plate, 0 % =
exact. Computed in Rust over the (small) watch/ignore set, so it no longer
issues any trigram SQL on these paths. The desktop watchlist panel reproduces
the identical rule to render a **live preview** of the misreads a given fuzz
would accept for the plate being typed (truthful only because both sides run the
same arithmetic).

**Rejected / not chosen:**

| Option | Why not |
|---|---|
| **Keep pg_trgm, just lower the floor / relabel the %** | The metric itself is wrong for plates (padding-trigram dominated); no threshold in the allowed range catches a 1-char misread on a 7-char plate. Relabeling an unusable control is lipstick. |
| **`fuzzystrmatch` `levenshtein()` in SQL** | Adds another Postgres contrib-extension dependency (same BYO-Postgres boot-fragility class as the pg_trgm issue just fixed); the watch/ignore sets are tiny, so Rust-side distance is simpler and dependency-free. |
| **Store an integer edit budget instead of the 0..0.5 float** | Would need a migration + DTO/type churn and a length-independent budget (2 edits is lenient on a 3-char plate, strict on an 8-char one). Length-scaling off the existing float avoids the migration and behaves sensibly across plate lengths. |
| **New separate control for the char model** | The existing fuzz field already means "how loose", so reinterpreting it keeps one knob; only the label/preview changed. |

`pg_trgm` is still used (and still guarded by `pg_trgm_available()`) for the
Plates **search box's** fuzzy `q` mode — that path is unaffected.

**Revisit triggers:**
- A non-Latin / variable-length plate region where character edit distance is a
  poor similarity notion (e.g. scripts where OCR confusions are visual-radical,
  not character-substitution).
- Operators wanting position-weighted tolerance (e.g. "ignore the last digit")
  — would argue for a richer rule than a flat edit budget.
- Watch/ignore lists growing large enough (thousands) that per-read full-table
  distance scans matter; then reintroduce an indexed prefilter.

---

## 2026-07-13, License-plate recognition: Frigate native LPR as the engine, engine-agnostic `plate_reads` + gated "Plates" surface; replaces the paid OpenALPR/Rekor cloud plan

**Context.** The operator paid for the Rekor (OpenALPR) cloud plan solely for a
searchable plate-reads dashboard. Crumb already ingests Frigate events, and the
pipeline is plate-aware at the type level (`DetectionLabel::LicensePlate`,
`sub_label`, `raw` JSONB); Frigate's native LPR emits plate strings on the
already-consumed `frigate/events` stream (`recognized_license_plate`, and a
matched-known-plate `sub_label`). The operator's requirement is **moving plates
only** (they don't want static/parked plates) — which is exactly what Frigate's
motion-gated LPR does, and what its "does not run on stationary vehicles"
limitation makes it good at.

**Decision — engine: Frigate native LPR; Crumb stays engine-agnostic.** The api
parses the plate from the existing Frigate ingestion (`detection/frigate.rs`,
MQTT + HTTP paths → `NormalizedEvent.recognized_plate`) and never embeds an OCR
engine. A dedicated **`plate_reads`** table (normalized `plate` + `plate_raw`,
confidence, region, vehicle jsonb, bbox, crop bytea, `source_id`, `event_id`
FK, dedup on `(source_id, provider_event_id)`, `gin_trgm_ops` index; migration
`0051`, registered) sits BESIDE the shared `events` row (each source keeps
writing its labeled row, per the additive-motion-sources rule), so plate
search / history / hotlists don't contort the shared `events` schema. Capture is
gated on an **`lpr_config`** DB singleton (`enabled` DEFAULT false — a plate
database is opt-in), same shape as `ha_config`. A new **`view_plates`**
capability gates `GET /plates` (Crumb's FIRST capability-gated read endpoint;
`/events` is deliberately left camera-scope-only). Clients gate the "Plates" tab
on `MeResponse.plates_enabled` (LPR on AND `view_plates`); the desktop tab is
appended last so existing tab indices don't shift. An **engine escape hatch**
is designed-in (built later only if needed): an authed `POST /lpr/reads`
(generated ingest token) lets an external engine — the operator's existing
continuous-scan OpenALPR box, or a MIT `fast-alpr` sidecar reading a go2rtc
`_sub` stream — write the same `plate_reads` via `source_id='openalpr'` etc.,
with zero Crumb code change.

**Rejected.** (a) Plate-in-`sub_label`-only / zero-migration: every UI query
(fuzzy search, per-plate history, hotlist join, vehicle attrs) fights the
shared `events` schema and mixed `sub_label` semantics. (b) OpenALPR OSS as the
in-Crumb engine: AGPL-compatible but dormant since 2016, accuracy below the
cloud plan — instead the operator's existing OpenALPR *box* stays an optional
external source via the ingest endpoint. (c) CodeProject.AI ALPR: SSPL,
(A)GPL-incompatible — never linked, bundled, or documented as an option.
(d) Building a sidecar first: pays an engine + service cost for reads Frigate
already produces on the existing stream. (e) Crops on the media volume: the api
mount is read-only (seam) — crops are bytea in Postgres, retention-pruned api-side.

**Trade-offs accepted.** Frigate LPR is prosumer (tuning required; no
state/region or make/model — the one durable cloud-plan advantage) and reads
plates off the lower-res/low-fps `detect` stream, so fast/distant plates trail
a continuous-mainstream scanner — acceptable for the moving-plate use case, and
the ingest endpoint keeps OpenALPR available if not. Plate data is
privacy-sensitive: default-off, `view_plates`-gated, retention-pruned. Desktop
gains its first feature-gated tab. `pg_trgm` enters the schema (trusted, in-image).

**Revisit triggers.** A validation month shows Frigate LPR materially under the
canceled cloud plan's hit rate on moving plates → wire the operator's OpenALPR
box (or a `fast-alpr` sidecar) through `POST /lpr/reads`. A second
capability-gated read surface appears → extract a shared client tab-gating
helper (the desktop const-tab-list refactor deferred here). Frigate renames the
LPR fields → re-verify the ingester parsing. Operator wants vehicle
make/model/color search → reopen engine choice (paid add-on vs OSS classifiers).

---

## 2026-07-13, LPR alerts: plate watchlist rides the existing system-alerts pipeline (no new notification machinery)

**Context.** LPR Phase 0 shipped plate capture + a searchable `plate_reads`
surface. The operator asked for **alerts** — "tell me when this plate is seen".
Crumb already has a mature system-alerts pipeline: `system_events` rows fanned
out over six notification channels (Discord/Slack/Pushover/Telegram/ntfy/webhook)
with per-event enable/cooldown/quiet-hours config (`system_alert_rules`,
migration 0032; engine in `notifications.rs`). The health watchdogs
(`alerts.rs`) already feed it.

**Decision — a curated plate watchlist that emits a `system_events` row.** A new
**`lpr_watchlist`** table (migration 0052; `plate` normalized + UNIQUE, `label`,
`note`, `color`, `notify`) holds plates the operator cares about. The detection
ingester (`detection_ingester.rs::maybe_alert_watchlist`), right after recording
a read, does an **exact** normalized-plate lookup (`match_watchlist`, `notify =
true` only) and, on a match, calls `insert_system_event("plate_watchlist_hit",
camera_id, detail)` — reusing the entire existing fan-out, config UI, cooldown,
and quiet-hours machinery. A seed row registers the `plate_watchlist_hit`
event_key so it appears in the admin Notifications panel like any other alert.
Watchlist CRUD is `/lpr/watchlist` (GET gated on `view_plates`; POST/DELETE
**admin-only**). Managed in admin console (Plates → Watchlist) and both clients.

**Dedup — alert once per read, on the match TRANSITION.** A per-read `alerted`
boolean (`plate_reads`, migration 0053) latches the alert: the ingester checks
the watchlist on every read (insert AND lifecycle-refinement UPDATE) but only
while `alerted` is false, then sets it once fired. This fires exactly once per
read AND catches a plate that only becomes the watchlisted value on a later
refinement (a misread converging onto the BOLO plate mid-pass) — the original
alert-on-INSERT-only (`xmax = 0`) design silently missed that case (Fable review
H1). The rule's 300 s per-camera cooldown still backstops rapid distinct passes.

**Rejected.** (a) A dedicated plate-alert delivery path (its own channels/config)
— pointless duplication of a working six-channel pipeline the operator already
configured. (b) Reusing `notification_rules` (the per-(user, camera) motion
pipeline) — it carries owner/presence/object-label dimensions a plate hotlist
doesn't have, exactly why `system_alert_rules` exists separately. (c) Fuzzy /
prefix watchlist matching for v1 — trigram-close plates would fire false BOLO
alerts; exact-only is the safe default (search already offers fuzzy for humans).
(d) A `manage_watchlist` capability — no non-admin operator use case yet; writes
stay admin-only (secure default), reads ride the existing `view_plates` gate.

**Trade-offs accepted.** Cooldown is keyed `(event_key, camera_id)`, not per
plate, so two different watchlisted plates crossing the same camera inside 300 s
can suppress the second alert — acceptable given moving-plate reads are already
one-per-pass and rare. Exact match means an OCR misread of a watchlisted plate
won't alert (the read is still captured + searchable). Plate-read retention is
independent of footage retention (its own daily prune); a watchlist entry never
expires.

**Revisit triggers.** Operators want per-plate cooldown or "alert on the second
sighting" semantics → move the latch/cooldown key to include the plate. False
misses from OCR variance hurt a real BOLO use case → add opt-in fuzzy matching
with a similarity floor. A non-admin "watchlist manager" role is requested → add
a `manage_watchlist` capability rather than widening admin.

---

## 2026-07-13, LPR ignore-list + fuzzy matching (two revisit triggers above fired same-day)

**Context.** Live use surfaced two gaps the alerts entry above predicted. (1)
Frigate zones don't restrict *detection* — a parked car outside the intended
area is still detected + plate-read, and Frigate-side object masking is fiddly,
so the plate DB fills with a nuisance plate. (2) Frigate's native ALPR misreads
more than the retired OpenALPR cloud, so exact watchlist matching (chosen for v1
to avoid false BOLO alerts) misses real hits — the "OCR variance hurts a real
BOLO use case" revisit trigger.

**Decision — ignore-list (skip-capture) + a global fuzziness knob** (migration
0054). The watchlist gains a `kind`: `watch` (alert, unchanged) or `ignore`. An
`ignore` plate is dropped at ingest — `detection_ingester` checks
`is_plate_ignored` *before* upsert and returns, so a nuisance plate is neither
stored nor alerted (skip-capture, matching OpenALPR's ignore-list semantics —
the operator explicitly wants it gone, not archived). `lpr_config.watchlist_fuzz`
(0..0.5, admin-set) loosens matching: when > 0 the ingester matches reads
against watch/ignore entries by pg_trgm `similarity >= 1 - fuzz` (threshold
floored so a stray large fuzz can't match everything), else exact. Fuzz applies
to BOTH kinds — a near-misread of an ignored nuisance plate should also be
dropped.

**Rejected.** (a) Capture-but-hide for ignored plates — keeps the DB bloating
with the exact nuisance the operator is trying to silence; skip-capture is the
direct intent (they can un-ignore to resume capture). (b) Per-entry match mode
instead of a global fuzz — more UI for no real gain; one similarity knob is
easier to reason about, and Frigate's drift is roughly uniform. (c) Fixing this
purely Frigate-side (object masks / `required_zones`) — correct but fiddly and
not always practical; the ignore-list is the operator's own backstop, and both
can be used together.

**Trade-offs accepted.** Fuzzy matching can over-match at high fuzz (a distinct
plate near an ignored one gets dropped) — hence the 0.5 cap + the floored
threshold, and it's off (0) by default. Skip-capture means an ignored plate has
no forensic record while ignored. `similarity()` on every ingested plate is one
extra indexed query per read — negligible at plate-event rates.

**Revisit triggers.** Over-matching complaints → move fuzz per-entry, or add a
"why did this match" debug. Operators want ignored plates still recorded (just
un-alerted/hidden) → add a capture-but-hidden third kind rather than changing
`ignore`.

---

## 2026-07-13, Recorded audio: ALWAYS re-encode to gap-filled 48 kHz AAC (supersedes the 2026-07-12 copy-when-safe split)

**Context.** The 2026-07-12 decision recorded audio with a per-camera split:
copy bit-exact when the source rate is "client-safe" (≤ 48 kHz), transcode only
the rates Android/web reject (> 48 kHz). Its premise was that a ≤ 48 kHz rate is
safe to copy. On-device diagnostics (Media3 1.4.1, SM-S921U) proved that **false**:
recorded playback was silent on Android for a **48 kHz** camera on the copy path.

**Root cause (measured).** A bit-exact `-c:a copy` preserves the camera's audio
*timeline* verbatim, and cheap camera audio clocks drift ~1 %: the container
timestamps promise more time than the AAC frames deliver (measured ~32 ms
phantom gap per 4 s segment; 61 of 62 frames non-uniform). ExoPlayer's
`DefaultAudioSink` enforces sample-continuous audio — once accumulated drift
crosses ~200 ms it throws `UnexpectedDiscontinuityException` and, because the
audio renderer is the player's master clock, the position lurches, segments
"end" early, and the whole player wedges (silent audio, stalled video). libmpv
(desktop) and the RTSP live path don't slave to strict sample continuity, which
is why only Android fMP4 playback broke.

**Decision.** The recorder ALWAYS re-encodes audio (when `record_audio`):
`-af aresample=async=1:first_pts=0 -c:a aac -ar 48000`. Video stays a bit-exact
`-c copy`.

**Alternatives considered.**

| Option | Verdict |
|---|---|
| **Always re-encode + `aresample=async`** | **Chosen.** `aresample=async=1` resamples onto a strictly continuous lattice, filling genuine gaps with silence (preserving A/V alignment). Measured 0/192 discontinuous frames after (vs 61/62 before). |
| Keep the copy-when-safe split | Rejected: its premise is empirically false; timeline continuity — not sample rate — is what matters, and only re-encode guarantees it. |
| Plain re-encode (`-c:a aac` without `aresample`) | Rejected: still inherits the input's jittery frame PTS (measured 75/187 discontinuous) — this is why SD/low.mp4 still threw the occasional discontinuity. `aresample=async` is the load-bearing part. |
| Client-side (tolerate the discontinuity in a custom `AudioSink`) | Rejected/tested: making the sink swallow the discontinuity turned it into a silent continuous clock lurch that dragged **video** down too. No correct client-only fix exists (the audio renderer is the master clock). |
| Per-client serve variant (video-copy + audio-reencode on demand) | Rejected: ships a workaround for defective recorded *data*; bad cache economics (full-segment-sized entries); export/iOS/web still inherit the broken timeline. Fix the data at the source instead. |

**Trades accepted.** A mono/stereo AAC encode is < 1 % of a core per camera
(negligible; the CPU-saving that motivated the copy path is not worth silent
audio). `-copyinkf:a` is dropped (it only mattered for the `-c copy` keyframe
gate — RECORDER-CORRECTNESS #23). Existing footage recorded on the copy path
(only ~1–2 days, since #103) is **not** retroactively fixed, but it already
plays with audio via Data-saver's on-demand re-encode (`/segments/{id}/low.mp4`).

**Revisit triggers.** If the `aac` encoder ever becomes a measurable CPU problem
on a large deployment, revisit selective copy — but only for sources *proven*
sample-continuous, not merely ≤ 48 kHz. If a future ExoPlayer/Media3 gains a
"trust sample count over container PTS" mode for progressive sources, the copy
path could return.

---

## 2026-07-13, Mobile performance: on-demand per-segment low-bitrate transcode (not continuous stream / ABR), Auto default

**Context.** Recorded playback and fullscreen live were unusable over poor
cellular: `GET /segments/{id}` served the full main-stream bytes (multi-Mbps
H.265) with no downscale option anywhere, and fullscreen live started on HD main.
The 2026-07-07 scrub-preview decision listed "WAN/remote scrubbing becomes a
first-class target" as an explicit revisit trigger — that trigger fired.

**Decision.** Add an on-demand, cached, operator-side low-bitrate variant, and an
Auto/Full/Data-saver client selector defaulting to **Auto**:

- **Playback:** `GET /segments/{id}/low.mp4` transcodes one segment to
  640p/15fps/CRF28 H.264 (+ AAC mono), produced on first request and cached
  (`{export_dir}/segcache`, LRU, ETag'd). A near-copy of the `clips.rs`
  preview machinery — same semaphore, same read-only media mount, same
  path-traversal guard, same auth (`?token=`). The recorder is never touched.
- **Live:** the reconcile loop registers a per-camera `<name>_mobile` go2rtc
  ffmpeg transcode of the sub (or main) stream; go2rtc pulls it only while a
  consumer is attached (zero idle cost). Gated by `MOBILE_STREAM_ENABLED`.
- **Client (Android):** Auto = Full on unmetered, Low on metered; the on-demand
  transcode therefore runs ONLY when a client actually asks for Low.

Full write-up: `docs/MOBILE-PERFORMANCE.md`.

**Alternatives considered.**

| # | Option | Verdict |
|---|--------|---------|
| 1 | **Per-segment `q=low` variant** | **Chosen.** One-line client URL change; cacheable/idempotent per segment (repeat scrubs hit cache); reuses clip machinery wholesale; failure isolation per 4 s unit. |
| 2 | Continuous time-range transcode (`/play/.../low.mp4?start=`) | Rejected for v1: replaces the whole segment/prefetch/seek client model with a long-lived stream a seek must restart, holds a semaphore permit for the whole session, output not reusable across scrubs. Kept as the v2 shape (it also removes any residual segment-boundary audio seam). |
| 3 | HLS/DASH ABR ladder | Rejected: ≥2 encode ladders (double CPU) + playlist generation + a client player-mode change, overkill for a single-operator VMS; a manual/auto two-level selector matches the commercial-app UX at a fraction of the complexity. |
| 4 | Pre-transcode everything at record time | Rejected outright: permanent CPU+storage for footage mostly never watched, and it touches the sacred write path. On-demand + cache is strictly better. |
| 5 | Cloud/third-party transcode or relay | Out of scope — violates the ratified direction (footage never leaves operator hardware). |

**Trades knowingly accepted.**

- One ffmpeg spawn per 4 s segment on a cache miss (mitigated by cache + the
  N-deep prefetch; `-preset ultrafast` at 640p is many-× realtime).
- The `<name>_mobile` live transcode runs beside the recorder (go2rtc is embedded
  in the recorder container). On-demand and bounded to one process per active
  mobile viewer, disable-able via `MOBILE_STREAM_ENABLED=false`.
- Default-on mobile stream doubles the go2rtc stream table; inert until consumed.

**Revisit triggers.**

- Measured per-segment spawn overhead dominates on real hosts → switch playback
  to option 2 (continuous-range transcode), which also subsumes any audio seam.
- Multi-user remote viewing becomes common → reconsider option 3 (real ABR).
- ROADMAP dual-stream recording ships → "Low" should prefer a *recorded* sub
  segment over an on-the-fly transcode; design the selector so they compose.
- Recorder-host CPU contention reports → make the live mobile transcode default
  off, or move go2rtc to a separate restreamer host.

---

## 2026-07-12, Recorded audio: copy when client-safe, transcode only the rates Android rejects

**Context.** The Android client played recorded footage silent while desktop
played the same footage with sound. Device logs showed the segment's audio track
present but rejected by the hardware decoder: `MediaCodecInfo: NoSupport
[sampleRate.support, 64000] [c2.android.aac.decoder]`. The camera streams AAC at
64 kHz; Android's/web hardware AAC decoders cap at 48 kHz, while desktop's
software ffmpeg decoder handles higher rates — so a bit-exact copy was decodable
on desktop only. AAC rates above 48 kHz (64/88.2/96 kHz) are the entire problem
set; every standard rate ≤ 48 kHz plays on every client.

**Decision — conditional: copy when already client-safe, transcode only the
oddballs.** At record start the recorder probes the source audio sample rate
(`probe_audio_sample_rate`, a bounded best-effort ffprobe of the go2rtc restream —
a local consumer, not a camera connection) and `audio_segmenter_args` picks per
camera:
- source **≤ 48 kHz** → **bit-exact copy** (`-c:a copy -copyinkf:a`): zero
  re-encode, zero added CPU, source fidelity preserved.
- source **> 48 kHz** → **transcode to 48 kHz AAC** (`-c:a aac -ar 48000`) so it
  plays on every client.
- **probe failed / go2rtc not ready** → transcode (the always-safe default).

The copy path keeps `-copyinkf:a` (RECORDER-CORRECTNESS #23: RTP-AAC audio is
never key-flagged, so a plain `-c copy` would drop the whole declared audio
track). The transcode path re-encodes from decoded PCM, so it has no keyframe
gate.

**Rejected — always transcode to 48 kHz (blanket).** Simplest (no probe), and it
was the first cut — but it re-encodes EVERY camera's audio including the majority
already at a safe rate: wasted CPU + a tiny generational quality loss for no
benefit. The probe is cheap and the copy path is strictly better when the source
is already fine.

**Rejected — always keep bit-exact copy.** Leaves any > 48 kHz camera silent on
Android/web.

**Rejected — a per-client software decoder (Media3 FFmpeg extension on Android).**
Heavyweight new dependency, build-from-source, Android-only; normalizing at the
source fixes every client.

**Trade-offs accepted.** A bounded best-effort ffprobe at each (re)connect (falls
back to transcode on failure, so it never blocks or breaks recording); for the
transcoded oddballs only, tiny quality loss + per-segment AAC encoder priming.
Operators see which cameras are transcoding in the admin camera menu, with a hint
to set the camera's audio ≤ 48 kHz to avoid it. The EXPORT path
(`services/api/src/export.rs`) still copies audio unconditionally and is NOT yet
rate-aware — a known follow-up so shared clips of > 48 kHz cameras play on phones.

**Revisit if.** The per-connect probe cost matters (→ cache the rate per session);
or a lossless requirement emerges for the > 48 kHz cameras (→ copy + document the
Android caveat).

---

## 2026-07-12, Recorder audit hardening: the free-space floor frees real bytes, fail-open survives every seam, boot-reap tolerates contention

**Context.** A two-round adversarial audit of the recorder (issues #70–#84, PR
#85) found a class of footage-safety bugs. Fixing them forced several decisions
where a plausible alternative was rejected, and the audit iterated
(fix → re-audit → fix): a few round-1/round-2 fixes were themselves reverted or
reshaped once a later pass proved them unsafe — those reversals are decisions too.

**Decision — the free-space (ENOSPC) floor must FREE bytes, not relocate them.**
When the floor is in deficit and a segment's archive move would land on the SAME
filesystem as the live storage (the default compose layout: `/data/archive` on
the live disk) AND that filesystem is the one actually in deficit, the sweep
DELETES the oldest live segment instead of archive-moving it in place. This is a
deliberate, narrow exception to correctness item #7 (the live sweep normally
skips archive-enabled cameras, the archiver owns their deletion), in the exact
spirit of item #22 (the `max_retention_days` ceiling also overrides #7): losing
the OLDEST footage beats losing ALL FUTURE footage to a 100%-full disk that
ENOSPC-halts recording on every camera. It stays bound by every other safety
rule, oldest-first, protected bookmarks excluded, file-then-row (#10), serialized
on `ARCHIVE_GUARD` (#8), and only triggers when a move genuinely cannot free the
deficit disk (`st_dev` identity of segment-fs == archive-fs == floor-fs); a
segment on a different disk falls through to the normal lossless move. A loud
`premature_rollover` system event fires so the loss is visible, never silent.

**Decision — fail-open is an invariant across EVERY seam, not just steady state
(item #19 extended).** Concretely: (a) worker-lifetime motion state, the
`MotionBuffer` / `MotionUnion` / `pending_signals` are carried across an ffmpeg
reconnect (the R1 cache sweep gets a keep-set so it won't delete carried pre-roll,
and a flip-guard prevents a cache/storage-flavour mismatch from self-copy-
truncating an indexed segment), so a reconnect mid-event no longer drops the event
tail; (b) the `MotionUnion` is kept consistent through an unhealthy (frozen)
window, edges are folded and the newest is stashed and replayed on thaw, and a
STOP replayed onto an Idle buffer enters `PostBuffer` (`apply_replayed_edge`) so
an event that ran entirely inside the window still keeps its post-roll; (c) a
detector reports HEALTHY only when it can actually produce a verdict, the Frigate
source on a granted MQTT SubAck (not ConnAck), the pixel detector after warm-up;
(d) a panicked motion-source task is supervised (a `JoinSet`, the motion-side twin
of the service-task watchdog) and immediately reads unhealthy → fail-open; (e) a
`MotionSignal` dropped on a full channel flips the source to fail-open via an
interposed health watch rather than being silently lost.

**Rejected / not chosen:**

| Option | Verdict |
|---|---|
| Free-space floor **archive-moves** oldest live footage even when the move frees nothing (pre-fix behaviour) | Rejected, on the default shared-fs layout it freed 0 bytes every tick, the disk filled to 100%, and ffmpeg ENOSPC-halted recording on every camera. A no-op that reads as success is worse than a bounded, loud deletion. |
| Free-space floor deletes any same-archive-fs segment **without checking it is on the deficit disk** (a round-2 fix, reverted in round-3) | Rejected, on a repointed-storage config it deleted footage on a disk that frees nothing on the full disk: unbounded loss, zero benefit. The delete now also requires segment-fs == floor(deficit)-fs. |
| A **time-based `MotionUnion` stale-key expiry** to un-wedge a lost STOP (a round-2 fix, reverted in round-3) | Rejected, it can't tell a lost STOP from a genuinely-long event (an HA occupancy/contact sensor held on for hours; a pixel event through a storm). On a MULTI-source camera, expiring the long event's key let a second source's STOP close the union and DISCARD footage while a healthy source still asserted motion (golden rule 2). The wedge is covered the footage-safe way (over-record) by the #81 loss-debt fail-open + the motion-source supervision. |
| Signal a dropped-`MotionSignal` fail-open by writing `false` into `motion.rs`'s `aggregate_health` watch | Rejected, that watch dedups on `last_sent`, so a foreign `false` would never be re-published `true`: permanent fail-open with no recovery. An interposed second watch (`forward_motion_health`) folds signal-loss into health and recovers when the channel drains. |
| Boot index-reap **permanently skips** any `DROP INDEX` that hits a lock timeout | Rejected, it conflates a real in-progress manual `CREATE INDEX CONCURRENTLY` (must skip) with transient contention (a busy boot, autovacuum), leaving a droppable INVALID index un-dropped so a later `CREATE INDEX IF NOT EXISTS` silently no-ops. The reap now re-checks `pg_stat_progress_create_index` on a timeout: skip only a genuine build, retry transient contention. |
| Keep the stall watchdog as a per-`select!`-iteration `timeout(read)` | Rejected, a co-scheduled telemetry tick (45s < 90s) returned from the select and rebuilt the timeout every iteration, so it never fired → silent dead recording on a half-open stream. The watchdog is now a dedicated arm anchored to the last segment receipt. |

**Cost accepted.** The shared-fs floor deletes un-archived live footage of
archive-enabled cameras when the disk would otherwise fill, an explicit, loud
exception (not silent). Several fail-open paths deliberately OVER-record (a lost
STOP over-records until the next event; a warm-up window persists idle footage),
disk-waste bounded by retention, never loss, the correct direction per item #19.

**Revisit triggers.** A source-identity-keyed `MotionUnion` (each open key tagged
by source) lands → the lost-STOP wedge can be closed without over-record, and the
"no time-based expiry" rejection can be revisited. Per-GPU decode accounting lands
→ the floor's single-fs assumption could generalize to multi-disk deficit
tracking. A hermetic api-integration-test harness lands (issue #88) → the
`server_settings`-sharing test flakiness surfaced during this work is resolved.

---

## 2026-07-11, Admin console: rebuild to a sections-rail + list→detail model (not a reskin)

**Context.** The web admin console (`services/api/src/admin.html`, also embedded
by the desktop client per the hybrid-console decision below) used a Milestone
Management-Client layout: a left tree with every camera / profile / storage / user
nested under collapsible section roots, plus a right-hand editor pane. The
operator's repeated complaint was the **format/layout itself** ("looks like a
toy"; wanted a modern sections-rail + content-pane layout like current
self-hosted NVR consoles), not just the styling. Two prior attempts restyled
the same tree and were rejected for exactly that reason.

**Decision — change the information architecture, not just the CSS.**
- The left rail is **sections-only**, grouped under three eyebrows
  (Configure / Intelligence / Administer). No items nest in the rail.
- Each section renders its **list in the content pane** (Cameras → stat tiles +
  camera table; Recording → profiles; Users & security → roles + users), and
  selecting a row opens that item's **detail/editor** (list→detail) with a
  "‹ Section" breadcrumb back; the rail keeps the active section highlighted.
- A visual reskin rode along: cool near-black ground, a **single amber accent**
  (the old amber+cyan dual-accent retired), rounder geometry, one consistent
  card / pill / form component kit, and label-over-input forms.

**Rejected.**
- *Reskin the existing tree-nested layout* (the first two attempts): a
  "format/layout" complaint is about the IA, not the colors — repainting the
  same bones does not address it.
- *Keep the Milestone tree-with-children model*: familiar to VMS operators, but
  it was the thing being rejected; the sections-rail + list→detail model is what
  the operator asked for and approved via a mockup.

**Consequences / trade-offs.** Cameras/profiles/users sit one extra click away
than when nested in the rail (rail → list → item) — accepted; it declutters the
rail and matches the operator's approved mockup. Because the desktop client embeds `/admin`
(hybrid-console decision below), it inherits this redesign for free.

**Revisit triggers.** Operators report list→detail is slower for their workflow
than direct tree access; or the desktop client stops embedding `/admin` (which
would change the shared-surface calculus behind investing here).

---

## 2026-07-10, Desktop client: rewrite native in Flutter (keep the Rust core), retire the Tauri/WebView2 airspace model

**Context.** The desktop client is Tauri 2 + wry/WebView2 with native Win32
child video panes composited *above* the web chrome (the "airspace" model). Live
and playback are fast, but the operator kept hitting a class of jank: panes
return to the wrong camera, the on-video PTZ controls feel crude, and the whole
thing "feels weird, not native" on Windows, one of the project's golden goals.
This reopens the 2026-06-15 KEEP-TAURI decision (golden rule 7). A research spike
confirmed the interim "composition-hosted WebView2" fix (option 2b) is a wall in
wry 0.55: wry hard-wires HWND-hosted WebView2, and a composition controller you
create is an orphan webview carrying none of Tauri's IPC, so `sync_panes` /
pane stats / events all break, getting composition means abandoning Tauri
anyway. The deciding input came from asking the operator whether "not native" was
the window/video *behavior* or **also the look of the UI itself** (buttons,
menus, fonts, scroll feel like a website). Answer: **also the look.** That rules
out every option that keeps the 13k-line web UI.

**Decision — full native rewrite, toolkit = Flutter**, keeping the existing Rust
core via `flutter_rust_bridge` and rendering video through `media_kit`/libmpv
(external-texture). Native compositing makes on-video overlays (PTZ, and the
planned Home-Assistant status icons) **first-class native widgets**, deleting the
airspace bug class outright. This is a **UI-only rewrite**: the tested Rust (mpv
management, the client) is preserved behind the FFI bridge, not reimplemented.
Flutter *replaces* the Tauri desktop UI, it does not add a codebase, the surface
count is unchanged (web-admin + SwiftUI iOS/macOS + desktop).

**Decision — hybrid management console.** The settings/users/policies/setup-wizard
UI (the largest, least-trafficked slice, already shared with the web admin) stays
an **embedded web view** (system browser on Linux, where Flutter desktop webview
is weak); only the daily video surfaces (live wall, playback, on-video overlay)
are native. Saves ~2-3 months and keeps those screens auto-synced with the web
console. Accepted trade-off: the settings screens keep a web look; the surfaces
the operator lives in do not.

**Rejected.**
- *WinUI 3 / WPF* (Windows-only native): permanently forks the on-hold-not-dead
  Linux desktop against the maintainer's not-over-forking value; its only edges
  (deepest Windows-Fluent integration, MIT license) don't outweigh a permanent
  fork. A cross-platform toolkit serves Windows now and Linux later from one
  codebase.
- *Qt / QML* (cross-platform native): credible runner-up, retained as the
  fallback if Flutter desktop maturity disappoints, but heavier (bundled Chromium
  via QtWebEngine), LGPL dynamic-link/relink obligations inside an AGPL app, a
  two-hop Rust↔C++↔QML bridge, and no turnkey mpv-texture equal to `media_kit`.
- *Path B (custom Win32 + composition-WebView2 shell, keep the web UI)* and
  *tighten-in-place on the current airspace model*: both keep the web UI, which
  the "also the look" answer rules out; the spike also showed composition means
  leaving Tauri regardless.
- *Video into the webview (one web layer)*: reintroduces browser-video
  latency/fps limits; never on the table for an NVR.

**Consequences.** The reconcile "wrong-camera-on-return" fix (~25 slot-keyed
sites in `apps/desktop`) is **shelved as throwaway**, a native rewrite gets pane
identity for free. The SwiftUI iOS/macOS app is **not** absorbed (it works; don't
destabilize live iOS video chasing one-codebase purity). Linux stays on hold, but
Flutter makes it near-free when it un-holds. Rough phasing (wide error bars,
~4-6 months with the hybrid console): P0 de-risk spike (Flutter shell + the Rust
bridge + `media_kit` rendering one live camera with one native overlay, proving
mpv-texture + Rust-FFI + native compositing hold together before committing) →
P1 live wall + HA overlay as first-class native widgets (the headline proof, and
the surface the operator complained about) → P2 playback → P3 the rest
(clips/export/tuner/bookmarks/views) → P5 Linux target + packaging when un-held.

**Revisit triggers.** Flutter desktop or `media_kit` maturity regresses or goes
unmaintained (→ Qt fallback). Linux is declared truly dead **and** deep
Windows-native integration becomes a priority (→ reconsider WinUI).
`flutter_rust_bridge` can't keep pace with the Rust core's surface (→ thinner FFI
or Qt/cxx). The P0 spike shows mpv-texture + Rust-FFI + native compositing don't
hold together acceptably (→ reconsider the rewrite premise before P1).

---

## 2026-07-10, Additive multi-source motion: cameras enable N sources at once; fail-open aggregates on residual coverage

**Context.** Motion source was an exclusive single pick (`cameras.motion_source` =
`pixel`|`frigate`|`ha`). The operator wants it **additive**: a camera can enable
several sources at once (e.g. pixel + an HA door sensor as a backstop) and record
on the **union** of their triggers. This reopens the motion-source model
(golden rule 7). Ratified with a Fable design pass; implemented in increments
(schema/plumbing first, recorder core next).

**Decision — data model: three boolean columns.** Replace the enum with
`motion_pixel_enabled` / `motion_frigate_enabled` / `motion_ha_enabled`
(`NOT NULL DEFAULT false`), backfilled from the old value so **no existing camera
changes behavior** (migration 0049). Sub-config already lives elsewhere
(`motion_algorithm` for pixel, `frigate_config`, `camera_ha_links`), so the
booleans only say *which loops run*. The `motion_source` column is **kept but
deprecated** (nothing reads it): dropping it would force re-declaring
`v_camera_effective_policy` (the append-only view trap), so it stays. The view is
re-declared to *append* the three new `c_*` columns (allowed by CREATE OR REPLACE;
existing columns keep name+order). **Zero sources enabled on a Motion-mode camera
= no detector = fail open** (records everything, footage-safe); the admin warns
before saving that state. Rejected: a `TEXT[]`/set column (array-op querying;
a typo'd element is a silent no-op) and a join table (over-built for a closed
3-source set, adds a join to every camera load).

**Decision — orchestration: N supervised loops + a per-camera `SourceMux`.** One
supervised source loop per enabled source (today's per-camera supervisor cloned
N ways), but do **not** point them all at the shared `motion_tx` and trust
`recording.rs` to union. A per-camera `SourceMux` sits between the loops and the
existing `(motion_tx, health_tx)`: it (1) ORs the per-source open flags into the
single-open-event `MotionSignal` stream `recording.rs` has always seen
(preserving `MotionBuffer::apply_signal`'s single-source invariant), and (2)
aggregates per-source health into the one `health_tx` the buffer reads. Why the
mux and not "let recording.rs union": `apply_signal` was authored single-source
(each source's own tracker already unions its events before emitting), so two
sources feeding independent `started_at` START/STOP pairs could have one source's
STOP close the buffer while another is still open → **a recording gap = footage
loss**. The mux removes the risk and keeps the recorder core unchanged. (Revisit
if a test proves `apply_signal` unions independent interleaved pairs — the mux's
*union* role could retire, but its *health-aggregation* role stays.)

**Decision — fail-open rule (the crux): aggregate on residual coverage, with an
asymmetric grace.** The camera fails open (records everything) when **(a) ALL
enabled sources are unhealthy (immediate, no grace), OR (b) ANY enabled source
has been hard-DOWN continuously past `motion_source_down_grace` (default 60s)**.
Otherwise it is healthy and motion-gated on its working sources. Rationale: a
source is added precisely to catch what the others miss, so its silent death must
eventually fail open (clause b) — but a still-working source buys a bounded grace
so one flaky source doesn't force record-everything on every reconnect. "Hard-down"
(loop erroring / in backoff) accrues down-time; a **clean config-version exit**
(the loop returns `Ok` and re-runs within a tick) is *reconfiguring*, not down,
and never trips clause (b) — this is what stops the flapping. Per-source
`motion_detector_unhealthy` alerts fire **by name** so a dead added-source is
loud, not silent; the operator's release valve is to **disable** that source
(untick it → out of the enabled set → can't force fail-open). This reduces
**exactly to today** for a single-source camera: one source down → clause (a) →
immediate fail open. Rejected: fail-open-if-ANY-unhealthy (every added source
becomes a permanent disk-filling liability that flaps on reconnect);
degrade-to-healthy-only (silently discards exactly the events the operator added
a source to catch = footage loss of declared-important events).

**Decision — surfacing: each source owns its event row; `recording.rs` writes
none.** In the additive model the mux feeds `recording.rs` a source-blind unioned
signal that *cannot* be labeled, so `recording.rs` stops writing `events` rows
entirely. Each source loop writes its own labeled row at its transitions: pixel →
`'motion'` (move `upsert_motion_event` out of `recording.rs`'s
`drain_and_persist_motion` into `run_pixel_diff_loop`), HA → `'ha'`/device-class
(slice 3, unchanged), Frigate → its detection rows (ingester, unchanged). This
also **fixes an existing double-surface**: today a Frigate camera gets both a
generic `'motion'` row (from `recording.rs`) and its `'frigate'` rows; relocating
the write leaves only the richer `'frigate'` rows. The slice-3
`motion_source=='ha'` suppression gate is deleted — it existed only because HA
reused the shared motion signal.

**Sequencing.** PR #55 (exclusive HA) ships as the single-source *mechanics*
(`ha_motion.rs`/`HaTracker`/labeled events/poll source are reused verbatim);
additive is this follow-up. Also fixes a #55 gap found in passing: the API's
`normalize_motion_source` rejects `'ha'`, so the exclusive model was not actually
settable via the API — additive replaces that validator with the booleans.

**Blocking correctness gate (verify on real hardware before merge):** (1)
`SourceMux` unit test — interleaved pixel/HA START/STOP with unrelated
`started_at` produce one continuous window; a STOP from one source while another
is open does NOT close recording. (2) On a pixel+HA camera: kill HA → after the
60s grace records EVERYTHING; blip HA (< grace) with pixel healthy → NO fail-open
flap; disable pixel too (all down) → immediate fail open; a pixel-only camera's
fail-open timing is unchanged. (3) `cargo test motion::` + full gate.

**Revisit triggers.** A test proves `apply_signal` unions independent interleaved
pairs → the mux's union role can retire. A 4th+ source arrives → reconsider a set
column. Operators find the 60s residual-coverage grace too long/short → make
`motion_source_down_grace` a per-policy knob. A WS `HaEventSource` lands, changing
HA down-vs-reconfiguring semantics → re-verify the grace classification.

---

## 2026-07-10, HA motion surfacing: the recorder writes the labeled event row; `MotionSignal` stays source-agnostic; generic motion row suppressed for HA cameras

**Context.** Phase 2 makes a `motion_source='ha'` camera trigger recording from
its linked HA motion/door sensors. The recorder already turns each drained
`MotionSignal` into a generic `'motion'/'motion'` row in the shared `events`
table (`db::upsert_motion_event`, called from `drain_and_persist_motion`), which
is what the notification engine and timeline consume. Slice 3 wants an HA-door
event to read as **"Door"** with its own timeline glyph, not as anonymous
motion — the question was *who writes the labeled row and where the label lives*.

**Decision — the recorder writes a LABELED `'ha'` event row itself, at the same
`HaTracker` Start/Stop transition where it emits the signal (option b).** The
linchpin: the recorder *already* writes these event rows, so this is not new
scope in the always-must-work component — it upgrades the existing generic write
to a labeled one, done in `ha_motion.rs` where the linked entities' `device_class`
is already in hand. `db::upsert_ha_event` mirrors `upsert_motion_event`
(`source_id='ha'`, `provider_event_id="ha:{entity}:{start_ms}"`, same
START-inserts/STOP-updates idempotency) and wraps the same `upsert_detection_event`
the Frigate ingester uses, so it renders through the existing labeled-glyph
pipeline with **no new rendering model**. The `device_class → label` map
(`crumb_common::ha::label_for_device_class`) is one pure, unit-tested fn:
door/opening→`door`, window→`window`, occupancy/presence→`occupancy`,
garage_door→`garage`, motion/moving/vibration→`motion` (reuses the existing
dot-row-filtered motion glyph), null/unknown→`sensor`. The **opening** sensor
fixes the label for the whole event (decided at Start, never relabeled
mid-event).

**`MotionSignal` stays byte-for-byte source-agnostic** — no `device_class`, no
source tag. The label rides a *separate* best-effort DB write, never the signal.
`recording.rs` and the pixel/Frigate paths are untouched.

**Ordering + best-effort are load-bearing.** `ha_motion.rs` emits the
footage-driving `MotionSignal` **first and unconditionally**, then writes the
labeled row best-effort (a DB error is logged and ignored, exactly like the
generic motion write). A failed glyph write can never cost a segment.

**Generic motion row suppressed for HA cameras.** `drain_and_persist_motion`
takes `write_generic_motion_event` (`false` iff `motion_source='ha'`) gating only
the `upsert_motion_event` loop — **never** the `buf.apply_signal` loop — so the
record/persist decision is byte-identical and only the surfacing row's owner
changes. Without this an HA door-open would write both a `'motion'` and an `'ha'`
row and double-fire the 3s-polling notification engine.

**/status live badge: reuse the existing `recent_motion`.** HA motion flows
through `segments.has_motion` like any motion, so the "motion now" badge already
lights for HA cameras with zero new code. No `ha_triggered` bool (it would mean
the same thing and invite skew). A per-tile "Door"/"Occupancy" caption is
presentation, read from the existing labeled `events` feed; `status.rs` unchanged.

**Rejected.** (a) A second **api-side poller** of the same entities to write
labels — reintroduces exactly the region/label skew this avoids (two independent
polls, independent failures) for no benefit, since the recorder already writes
the row. (c) Carrying `device_class` through a `MotionSignal` side channel into
`recording.rs` — spreads HA knowledge into the source-agnostic component and is
more plumbing than (b), which quarantines all HA knowledge in `ha_motion.rs`.

**Deferred (honest).** The client-side Path2D glyphs for the new keys
(`door`/`window`/`occupancy`/`garage`/`sensor`) across web/desktop/Android/iOS and
`docs/DETECTION-ICONS.md` are a follow-up presentation slice; until they land an
HA event renders with the generic/fallback glyph (no breakage). A DB
round-trip / suppression integration test is deferred: `crumb-common` has no
integration-test harness (only the api does), and the write path is a thin
wrapper transitively covered by the api ingester tests + the pure unit tests;
the runtime fail-open validation covers the recorder path end-to-end.

**Revisit triggers.** A non-recording `role='sensor'` status entity (P3) needs
surfacing without a recording poll → that is the one case a lightweight api-side
read returns; decide it then, not now. If a second consumer ever needs the
per-event source/label off the wire, reopen the source-agnostic-`MotionSignal`
choice (today nothing does).

---

## 2026-07-10, Home Assistant integration: HA-native transport, REST-polling first (WebSocket deferred), one non-admin token, camera-linked entities

**Context.** Home Assistant is the ideal integration for a self-hosted VMS (it
IS self-hosted, so it fits "optional integrations must have a self-hosted path,
footage never leaves your control"). Goal: HA motion/door sensors surface on the
timeline and can trigger recording; HA lights/switches/scenes become on-video
controls; and (later) an on-video widget overlay. This entry covers the
transport and the Phase-1 foundation (epic #52). Two Fable design passes + a
real-hardware spike informed it.

**Decision — transport: HA-native APIs on ONE long-lived access token (LLAT),
not MQTT.** Outbound control uses HA's REST service API
(`POST /api/services/<domain>/<service>`); inbound sensor state will use HA's
API too. One credential (a non-admin HA user's LLAT) + base URL, stored like
`frigate_config` (DB singleton `ha_config`, write-only token, env fallback for
empty fields, monotonic `version` for hot-reload). MQTT is **not** used for this
integration because HA core has no first-class "call an arbitrary service over
MQTT" path (control would need a hand-authored per-button automation); MQTT
remains the right tool for the *separate* Crumb→HA MQTT-Discovery roadmap item.

**Decision — inbound: REST polling first; WebSocket deferred behind a
transport-agnostic source.** The spike (live HA 2026.7.1) validated REST control
(~30-40ms, **non-admin token can call services** — no admin rights needed) and
WS `subscribe_trigger` (~30ms), but found a **silent WS peer drop took ~39s to
detect** via a blind send loop. That is a recorder-correctness issue: the
fail-open rail flips health only on loop *exit*, so an undetected-dead WS leaves
a `motion_source='ha'` camera health=true and motion-gated → **silently missing
footage** for the dead window. REST polling makes this property free: a poll is a
bounded GET with a timeout, so a dead HA surfaces as a timed-out poll within one
interval → the loop errors → fail-open fires in ~1s. Polling also needs **no new
dependency** (`tokio-tungstenite`, #53, deferred) and no keepalive code; its 1s
latency is absorbed by the motion RAM pre-buffer for recording and is nothing for
a status chip. Missed sub-second blips don't affect motion/door sensors (they
hold state for seconds). So Phase 2's `ha_motion.rs` consumes an internal
`HaEventSource` trait; `HaPollSource` (REST) ships first, `HaWsSource` drops in
later, changing no data model, endpoint, or client, gated on a real-TCP-partition
retest + WS keepalive (ping/pong).

**Decision — model: `camera_ha_links` table** (camera → N entities, role
`motion`/`actuator`), queried directly (not via `v_camera_effective_policy`).
Controls (Phase 3) reuse the `actuators` RBAC capability shared with the Reolink
plan; the client sends a `link_id`, never a raw HA entity id.

**Rejected.** MQTT statestream inbound (YAML-only HA config + broker + no control
path); per-action HA automations; **WS-first** (deferred on the 39s dead-peer
finding + the new dependency); requiring an admin HA token (spike proved
non-admin works); extending the views model for links (wrong scope).

**Entity picker + filtering (Phase 1, decided with the review).** The
`GET /ha/entities` endpoint stays dumb: it returns `device_class` (free from the
states call) and does **no** server-side class whitelist; the client filters and
groups. The sensor picker whitelists relevant classes (motion/occupancy/
presence/moving/door/window/opening/garage_door) and buckets the rest under a
collapsed "Other sensors" + a show-all toggle, so nothing is unreachable.
`camera_ha_links.device_class` is captured at link time as a **snapshot of
intent** (drives the glyph without re-querying HA); if an operator reclasses the
entity in HA later, the link keeps the old class until re-linked — that is
correct, do not "fix" it into a live re-query. The `role` CHECK reserves
`sensor` (status-only overlay widgets, P3) alongside `motion`/`actuator` so P2/P3
need no migration. Rejected: server-side class whitelist (server owning a policy
list that needs edits); splitting `motion` vs `door` roles (device_class carries
that; a door that triggers recording is `role=motion, device_class=door`).

**Revisit triggers.** The real-TCP-partition WS retest passes *and* sub-second
per-edge fidelity is wanted → promote `HaWsSource` (with keepalive) via #53. HA
ships scoped tokens → the unscoped-LLAT caveat improves. A shared internal event
bus lands → the API could relay motion to the recorder over one connection.
**HA-area filtering** wanted (link a camera to its room's entities) → needs the
entity/area registry (WS API or a registry helper), lands with the WS phase.

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

**Refinements from a design review (2026-07-10), folded in before implementation:**
- **The `match` block is a first-class, machine-first schema concept.** Entries
  carry an explicit normalized `match` (make + make_aliases + models +
  `*`-globs); an entry without a valid `match` block is documentation-only and
  never auto-matched. Rejected contributor-supplied **regex** (review burden +
  ReDoS); normalized exact strings plus `*` globs cover the real cases (lens/
  region model suffixes). Matching is two-tier: exact make+model = "identified",
  make/alias-only = "possible match, verify" (never asserts quirks as fact).
  **Firmware never gates matching** (vendor-arbitrary formats); it is stored and
  shown as "reported on firmware X" only.
- **The contribute target is a GitHub issue _form_
  (`.github/ISSUE_TEMPLATE/camera-report.yml`) plus a copy-button modal**, not a
  raw prefilled-body URL. This is a narrowing of "pre-filled GitHub issue", not a
  reversal: rejected the raw-body URL for its ~8 KB ceiling, confusing
  logged-out UX, and unstructured triage. The admin console shows the full
  server-built report in a modal (the operator's review step) with a copy
  button, then opens the issue form prefilled with only short values.
- **The contribute payload is built server-side from a whitelist**
  (`GET /cameras/:id/compat-report`, admin-only): make/model/firmware + stream
  observations + support flags only. Credentials, IP/host, ports, any URL, and
  the operator's camera name are excluded by construction (camera name is an
  optional field the user types), because `cameras.onvif_password` /
  `source_url` are one join away and a client-assembled report would eventually
  leak one.
- **Stream fingerprint demoted to data, not a matcher.** Stream observations
  (codec/profile/pix_fmt/range) are captured and displayed and auto-included in
  the contribute report, but fingerprint _matching_ stays deferred behind the
  revisit trigger below (the "PPS id out of range" signal is an ffmpeg log
  string that shifts across versions, and full-range yuvj420p is common across
  unrelated models).

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
builds, so `cargo clippy` on a Linux build host matches CI and "run the gate before pushing"
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
