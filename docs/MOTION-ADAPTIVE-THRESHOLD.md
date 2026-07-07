# Adaptive (learning) motion threshold, design

**Date:** 2026-06-23
**Status:** Shipped.
**Replaces:** the `DynamicSensitivity` calibrator (`mean + 3σ` over a 300-frame,
background-only rolling window) in `services/recorder/src/motion.rs`.

## Why the old "dynamic" failed

Observed on prod (2026-06-23): every camera's effective floor sat at exactly
`BLOB_FRACTION` (0.0030 = 0.3% of frame), so any intermittent ≥0.3% blob (a tree
gust, a car on the street, headlights) registered as motion → notification flood.

Two root causes:
1. **Feedback trap.** The calibrator was fed *only background frames* (frames
   below the current floor). The moment a nuisance blob crossed 0.003 it was
   labeled "motion" and withheld, so the floor could never learn to sit *above*
   the recurring nuisance. It converged to the quiet baseline (~0) → clamped to
   the 0.3% minimum.
2. **No memory.** A 300-frame (~30 s) window with no persistence and no
   time-of-day awareness, it relearned nothing useful and reset on every restart.

## Goal

A floor that **learns each scene's normal activity from history** and settles
*just above the recurring nuisance band*, so real (rarer, usually larger)
events still pass, adapting to day/night and weather, surviving restarts, and
costing ~nothing per frame. Fundamental limit acknowledged: a purely statistical
floor cannot tell a distant person from a branch of the same size, that's what
exclusion zones and Frigate object detection are for. This errs **low** (a few
false positives beats a missed person).

## Algorithm, percentile-over-a-decaying-histogram, with a diurnal profile

Per camera, the detector holds:

- `hist[NB]`, a **decaying histogram** of per-frame scores. `NB = 64` buckets,
  geometric edges over `[BLOB_FRACTION, MAX_THRESHOLD]` (0.003 → 0.5); bucket 0 =
  "quiet" (`< BLOB_FRACTION`). f32 weights.
- `total`, sum of bucket weights.
- `diurnal[24]`, a per-hour-of-day EMA of the computed floor. **This is the
  "historical data":** over days it learns "this camera at 02:00 normally needs
  floor X" (headlights at night, shadows midday).
- `floor`, the current effective floor returned to the detector.

**Per frame** (`observe(score, now)`), O(1):
- increment `hist[bucket(score)]`, `total += 1`. (One add. Nothing else.)
- **Feed EVERY frame**, including frames currently classified as motion. This is
  the key change from the old trap: the learner must SEE the nuisance to rise
  above it. (A sustained real event is a tiny fraction of a multi-hour horizon,
  so it can't drag a high percentile up, see safety.)

**Periodically** (`recompute`, every ~`RECOMPUTE_SECS` = 15 s of wall time):
- **Decay** toward a long horizon: scale all buckets + `total` by
  `DECAY^(elapsed_min)` with a half-life of `HORIZON_MIN` (default ~120 min), an
  exponential window of a couple hours that tracks weather/light without thrash.
- **Live floor** = the score at the `PERCENTILE` (default **0.97**) of the CDF,
  i.e. just above 97% of recent activity. If the scene is genuinely quiet (the
  97th percentile is still in bucket 0), it stays near the minimum, we don't
  invent noise.
- **Diurnal update:** `diurnal[hour] = α·live + (1-α)·diurnal[hour]`,
  `α = DIURNAL_ALPHA` (≈0.05, slow, learns over days).
- **Effective floor** = `clamp( max(live, diurnal[hour]) , MIN_THRESHOLD,
  MAX_THRESHOLD )`. Taking the max anchors a temporarily-quiet scene to what this
  hour historically needs, so the floor doesn't sag right before the nightly
  headlight parade.

**Persistence** (every `PERSIST_SECS` = 300 s, one small UPSERT/camera):
- `motion_baseline(camera_id PK, diurnal jsonb[24], hist jsonb[64], total,
  updated_at)`. On startup the detector **loads** it → starts already-trained
  (no cold-start back to 0.0030). New migration `0016_motion_baseline.sql`.

## Safety (must not blind a camera or miss real motion)

- Hard clamp `[BLOB_FRACTION, MAX_THRESHOLD=0.5]` (unchanged).
- **Sustained-event robustness:** a person standing for 5 min ≈ 4.5k frames; over
  a ~2 h horizon (~10⁵–10⁶ frames) that's ≤~3%, it cannot move the 97th
  percentile into the event band. (High percentile + long horizon = robust to the
  minority of "interesting" frames, which is exactly what we want.)
- Errs low: `PERCENTILE` is moderate (0.97, not 0.999) and there is no extra
  multiplicative margin, so the floor lands at the *top of the nuisance band*, not
  inside the real-event band.
- All knobs (`PERCENTILE`, `HORIZON_MIN`, `DIURNAL_ALPHA`, `RECOMPUTE_SECS`,
  `PERSIST_SECS`) are named consts, tunable against real captured clips.
- `Manual` sensitivity is untouched (the escape hatch / per-camera override).

## Cost (the "don't tax the system" requirement)

- Per frame: 1 histogram increment. (vs the old per-frame mean/σ over a 300-deque
 , the new path is *cheaper* per frame.)
- Every 15 s: one 64-bucket decay + percentile scan + 1 EMA write. Negligible.
- Every 5 min: 1 tiny UPSERT per camera (~11 rows total). Negligible DB load.
- Memory: ~64+24 f32 per camera. Trivial.

## Tests (behavioral, `cargo test motion::` on build-host before any deploy)

1. **Quiet scene** → floor stays at `BLOB_FRACTION` (don't invent noise).
2. **Tree-noisy scene** (frequent 0.5–1.5% blobs) → floor rises **above** that
   band (≈the 97th pct), suppressing it.
3. **Real event passes:** after training on nuisance, a 5% blob still exceeds the
   floor.
4. **Sustained event doesn't blind:** a long high-score burst doesn't push the
   floor above the burst level (percentile robustness).
5. **Diurnal:** training only at "hour=2" raises `diurnal[2]` but not `diurnal[14]`.
6. **Persistence round-trip:** serialize → deserialize → identical floor (warm start).

## Rollout / validation

Deploy as a canary, then verify: the noisy (tree/street) cameras'
`motion_grid.threshold` should climb off 0.0030 within minutes, and their
motion-event counts should drop sharply while quieter cameras' real events keep
firing. Watch for any camera whose floor pins at `MAX_THRESHOLD` (a sign the scene
or a param is off) and for a drop in *legitimate* motion recordings.
