# Crumb Motion Recording, RAM buffer + persist-on-motion

**Status:** Shipping. Backend in `services/recorder` (motion cache + persist path);
this doc covers the design rationale, operations, and the shadow-mode validation
runbook.
**Scope:** cameras whose recording mode is **Motion** (continuous-mode cameras are
completely unaffected by anything in this doc).

---

## 1. The problem

Before this feature, "Motion" as a recording mode was a misnomer: every camera
recorded to disk 24/7 regardless of mode, and "motion" only controlled the
`has_motion` timeline flag and the notification trigger. An operator who picked
"Motion" expecting to save disk got the same live-storage growth as Continuous —
just with some segments tagged. For a driveway or side-gate camera with long
idle stretches, that's the majority of its retention budget spent on empty
frames.

## 2. Industry survey (brief)

Before choosing an approach, the recording behavior of comparable systems for
their "motion" mode was checked:

- **Enterprise VMS platforms** typically ingest continuously into a small
  **RAM pre-buffer** and flush it to disk only when a recording trigger (motion,
  analytics event, manual) fires, then keep recording for a configured post-roll.
  Idle time is never written to disk. This is the closest precedent to what Crumb
  needed, and the model this feature is patterned after.
- Some consumer NVRs offer a "motion-only" mode that is really a UX label, not a
  storage behavior: the NVR records continuously and **prunes** non-motion
  segments out of the timeline/retention accounting afterward. It still writes
  every frame to disk; the saving is retention-side, not ingest-side.
- **Frigate** uses a tmpfs (`/tmp/cache`) segment cache and a "segment mover"
  that decides, per completed segment, whether to move it into permanent
  recordings storage based on the recording config (motion/objects/continuous)
  for that time range. Structurally the closest to Crumb's mechanism below.
- **ZoneMinder / Blue Iris communities** broadly prefer continuous recording
  over strict motion-gated capture, because a NVR that only starts writing
  *after* detecting motion systematically clips the first moment of the event
  (detector latency, debounce, frame-diff warm-up), exactly the failure mode
  a pre-roll buffer exists to prevent.

The common thread: nobody serious about not losing footage does naive
"start writing when motion is detected." The buffer has to already contain the
lead-in before the trigger fires.

## 3. Why Crumb chose RAM-buffer + persist-on-motion

Given the survey, the requirements were: (1) zero idle disk writes for Motion
cameras, that's the entire point of the feature: (2) never lose the run-up to
an event (pre-roll); (3) never silently lose footage because of the *mechanism
itself* (as opposed to the operator's own retention/eviction settings, which
are a separate, deliberate policy).

The design is a ring buffer of already-recorded segments held in RAM (tmpfs),
sized to the camera's configured `motion_pre_seconds`. Only when motion is
detected does anything get copied out to persistent storage: the buffered
pre-roll, the segments spanning the motion event itself, and
`motion_post_seconds` of post-roll after motion stops. If motion never
recurs, the buffered segments age out of the ring and are simply overwritten
in RAM, no disk write ever happened for them.

Two rails make this safe to leave running unattended:

- **Fail-open.** If a camera's motion detector is unhealthy, a stalled
  sub-stream, a dead decoder, anything that means Crumb can no longer form a
  keep/discard verdict for that camera, the camera falls back to persisting
  **everything** to disk (behaves like Continuous) until detection recovers,
  and a health alert fires. The failure mode of "can't tell if this is
  interesting" must never be "record nothing"; it must be "record it all and
  tell the operator."
- **Spill.** If the RAM cache nears full (many cameras, a burst of concurrent
  motion, or a paused/slow disk), the oldest buffered segments are persisted
  to disk rather than being evicted from RAM and lost. Cache pressure changes
  *when* something is written, never *whether* it survives. If the cache
  filesystem is genuinely out of space (ENOSPC) and the spill cannot relieve
  it, the camera fails open to **direct-to-storage** recording for the rest of
  the worker's life and raises `motion_cache_unavailable`, rather than letting
  the wedged cache silently stall recording.

**Known limitation — the pixel detector needs a reasonably dense sub-stream.**
The frame-diff detector runs on decoded sub-stream frames at
`MOTION_ANALYSIS_FPS`. A camera that delivers **keyframes-only or a very long
GOP** produces too few *distinct* decoded frames (ffmpeg's `fps` filter pads
the output with byte-identical duplicate frames), so the detector cannot form a
trustworthy keep/discard verdict. Crumb detects this condition (a sustained
majority of exact-duplicate frames) and **fails open** exactly like any other
unhealthy-detector case: the camera records everything and a health alert
fires until distinct frames return. The fix on the camera side is to give the
sub-stream a normal GOP (~1–2s / an I-frame interval at or below the analysis
rate); until then, that camera effectively records in Continuous mode.

Net effect: the only footage that is deliberately never written to disk is
footage nobody ever flagged as motion, on a camera whose detector is
demonstrably healthy, which is exactly the traffic this feature exists to
avoid recording.

## 4. Mechanism

- The recorder still segments each camera's main stream into small (2-6s,
  `SEGMENT_SECONDS`, default 4s) independently-seekable fMP4 segments exactly
  as it does today (see `docs/RECORDER-CORRECTNESS.md` for the segmenting
  invariants, those are unchanged).
- For a Motion-mode camera, each closed segment is first written under the
  recorder's tmpfs cache (`MOTION_CACHE_DIR`, default `/cache/motion`) instead
  of the media root.
- The ring buffer retains the last `motion_pre_seconds` worth of cached
  segments per camera. When a segment ages past that window with no
  keep-worthy verdict pending, its cache file is simply deleted (RAM freed,
  nothing written to `/data`).
- At the moment a segment closes, the motion detector's verdict for that
  segment's time range decides keep or discard. A "keep" verdict is triggered
  by: the segment overlapping an active motion event, the segment falling
  within the pre-roll window before a motion start, or the segment falling
  within `motion_post_seconds` after a motion stop.
- **Persist = copy + fsync + index + delete-from-cache**, in that order (see
  `docs/RECORDER-CORRECTNESS.md` for why that ordering matters and what a
  crash mid-persist looks like). Persisted segments land in the normal
  live-storage layout and are indistinguishable from a Continuous-mode
  segment in the `segments` table and in playback/export, recording mode is
  not something clients or the timeline need to know about after the fact.
- Continuous-mode cameras never enter this path at all; segments are written
  straight to `/data` as before.

## 5. RAM sizing

The tmpfs mount is sized by `MOTION_CACHE_TMPFS_BYTES` (compose) /
`.env.example` has the full worked rule of thumb; the short version:

- A segment is roughly `SEGMENT_SECONDS x bitrate`. At a typical 8 Mbps main
  stream that's about 1 MB/s, so a 4s segment is ~4 MB.
- Per-camera budget ≈ `(motion_pre_seconds + ~12s of in-flight segments) x 1 MB/s`.
- Multiply by the number of Motion-mode cameras sharing the recorder for the
  total. The 512 MiB default comfortably covers roughly 10 cameras at a 30s
  pre-roll; a longer pre-roll, higher-bitrate main streams, or more cameras
  should raise `MOTION_CACHE_TMPFS_BYTES` (and the recorder container's memory
  limit alongside it, tmpfs pages count against the container's memory
  cgroup, not disk).
- Sizing low is not a footage-loss risk by itself (the spill rail persists
  instead of dropping when the cache is full), it just means more disk writes
  than the pre-roll strictly requires, because segments spill to disk earlier
  under pressure. Size generously if RAM is available; it costs nothing at
  idle beyond the reservation.

**Permissions, the tmpfs MUST be `mode: 01777`.** The recorder container runs
as a non-root user (uid 1001), not root, and must be able to
`create_dir_all(MOTION_CACHE_DIR/<camera-id>)` on every worker start. A tmpfs
mount with no explicit `mode` comes up root-owned `0755`, so that `mkdir` gets
`EACCES`. This is a fail-open path, not a fail-closed one: the recorder does
NOT stop recording, it logs an ERROR and falls back to writing that camera's
segments straight to `/data` (direct-to-storage, indexing every segment, same
as Continuous mode), and raises the `motion_cache_unavailable` health alert
(migration `0040_motion_cache_unavailable_alert.sql`) so the loss of the
disk-saving benefit is visible instead of silent. `docker-compose.yml`'s
`/cache` tmpfs already sets `mode: 01777` (world-writable + sticky, like
`/tmp`), do not remove it, and the fresh-install smoke test
(`scripts/test/fresh-install-smoke.sh`) asserts the recorder can actually
create+remove a directory under `MOTION_CACHE_DIR` so a regression here fails
CI instead of shipping.

## 6. Shadow-mode validation runbook

Flipping a camera straight from Continuous to Motion is a one-way trust
decision on day one, the operator has no way to see what the motion buffer
*would have discarded* until it's already gone. Shadow mode removes that
blind spot: it changes nothing about what gets recorded, but stamps every
segment with the verdict the motion buffer would have made.

**1. Enable shadow mode** on the recorder:

```
MOTION_RECORDING_SHADOW=1
```

Restart the recorder. Recording behavior is unchanged, every segment for
every camera is still written to disk exactly as today. The only difference
is that `segments.motion_shadow_keep` (boolean) is now populated: `true` if
the motion buffer would have persisted that segment (event, pre-roll, or
post-roll), `false` if it would have been left to evaporate from RAM.

**2. Let it run for a representative window**, a few days at minimum, long
enough to cover the camera's normal idle/active cycle (weekday vs weekend
traffic, day/night, etc.).

**3. Query reclaimable bytes per camera per day**, segments that shadow mode
says would NOT have been kept:

```sql
SELECT
  camera_id,
  date_trunc('day', start_ts) AS day,
  count(*)                                 AS discardable_segments,
  pg_size_pretty(sum(size_bytes))          AS reclaimable_bytes
FROM segments
WHERE stage = 'live'
  AND motion_shadow_keep = false
  AND start_ts > now() - interval '7 days'
GROUP BY camera_id, day
ORDER BY camera_id, day;
```

This is the headline number for deciding whether Motion mode is worth turning
on for a given camera, high reclaimable bytes on a camera with long idle
stretches (a driveway, a side yard) is the ideal candidate; a camera that's
almost always in motion (a busy sidewalk) will show little to reclaim and may
be better left on Continuous.

**4. Spot-check would-be-dropped spans before going live.** Reclaimable bytes
alone doesn't prove nothing important would have been missed, pull a sample
of the actual discarded spans and watch them:

```sql
SELECT camera_id, start_ts, end_ts, path
FROM segments
WHERE stage = 'live'
  AND motion_shadow_keep = false
  AND camera_id = '<camera-uuid>'
ORDER BY start_ts DESC
LIMIT 50;
```

Play a handful of these clips back (they're still on disk, shadow mode
recorded everything). If any of them show something the operator would have
wanted kept, that's a signal to tune the motion detector (sensitivity, zones,
`motion_pre_seconds`/`motion_post_seconds`) before flipping the mode, not
after.

**5. Flip the camera to Motion mode** once satisfied, and disable
`MOTION_RECORDING_SHADOW` if no other camera still needs validation (leaving
it on is harmless but adds a column write per segment for every camera,
including ones already on Motion).

## 7. RAM telemetry in the admin console

Section 5's sizing rule of thumb is a worked estimate; the admin console also
shows the *actual* numbers so an operator doesn't have to do the arithmetic by
hand or guess whether `MOTION_CACHE_TMPFS_BYTES` is generous enough.

**Mechanism** (mirrors the existing motion-decode-truth telemetry in
`services/recorder/src/motion.rs`'s `report_decode_status`, migration 0035):
each recording worker reports, on a ~45 s tick from the same `tokio::select!`
loop that owns its `MotionBuffer` (never from the persist/discard hot path):

- **Global** (`motion_cache_status`, singleton row): free/total bytes on the
  filesystem backing `MOTION_CACHE_DIR` (the same `statvfs` call the
  cache-pressure spill check already makes), whether caching is active for
  any Motion-mode camera, and whether `MOTION_RECORDING_SHADOW` is on.
- **Per camera** (`camera_motion_cache_status`, Motion-mode cameras only):
  the ring buffer's current occupancy, segment count and summed bytes, via
  `MotionBuffer::ring_stats()`, a read-only accessor with no effect on
  persist/discard decisions.

A failed report is logged at `debug` and skipped, telemetry can never affect
what gets recorded (same warn-and-continue contract as decode-status).

`GET /config/motion-cache-status` (admin-only) serves this back plus one
thing the recorder can't compute for itself: a per-camera **projection** —
`observed bytes/sec` (from recent `segments` rows, works even for a
Continuous-mode camera being considered for a switch to Motion) times
`motion_pre_seconds + RING_SLACK_SECS + 2×SEGMENT_SECONDS`. This is the "will
this fit?" planning tool for BEFORE flipping a camera to Motion mode, not
just a readout of what's already buffered.

The admin console shows this in two places: a compact stat line where a
recording profile's mode is set to Motion, and a fuller gauge + per-camera
table on the Storage page ("Motion cache" section).

## 8. Failure modes and the trades

Being explicit about what this feature trades away, since "record less" always
trades against "might miss something":

- **A missed detection means that footage never existed.** If the motion
  detector fails to trigger on a real event (wrong sensitivity, a dead zone,
  a detector fully offline in a way that isn't caught by the fail-open health
  check), the footage for that event is gone, it was never buffered long
  enough to survive, or the fail-open path didn't engage because the detector
  looked "healthy" while producing wrong verdicts. This is a fundamentally
  different failure than Continuous mode's worst case (footage exists, you
  just have to search for it), there's nothing to search for. Shadow mode
  (Section 6) exists specifically to catch this class of problem before it
  costs real footage, and fail-open (Section 3) catches the "detector is
  visibly broken" subset automatically.
- **A recorder crash loses at most the buffered pre-roll.** Anything in the
  RAM ring buffer that hadn't yet been triggered into a keep verdict is gone
  on an unclean shutdown (tmpfs doesn't survive a container restart, let
  alone a crash), bounded by `motion_pre_seconds`, never more. Anything
  already persisted (copy+fsync+index completed) is safe by the normal
  recorder-correctness guarantees; anything mid-persist at crash time is
  handled by reconcile (see `docs/RECORDER-CORRECTNESS.md`).
- **Pre-roll and post-roll round to segment boundaries, not exact seconds.**
  Because the smallest unit that can be kept or discarded is a whole segment
  (2-6s, `SEGMENT_SECONDS`), a `motion_pre_seconds` of, say, 10s actually
  keeps however many whole segments cover at least that much time, typically
  a few seconds more than requested, never less. This is a deliberate
  simplification (segment-level keep/discard, not sub-segment trimming) and
  matches how Frigate's segment mover behaves for the same reason.
