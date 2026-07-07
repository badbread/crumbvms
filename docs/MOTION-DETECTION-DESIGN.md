# Crumb Motion Detection, Redesign

**Status:** Shipped. This design replaced the original global-%-changed detector in
`services/recorder/src/motion.rs`; the blob-area approach it describes is now the
default (census) detector, one of several pluggable detectors.
**Scope:** Pure-Rust motion analysis on a 320×~180 8-bit grayscale sub-stream frame
(no OpenCV). Drives the recording trigger, the per-segment timeline `motion_score`,
and the live "motion now" indicator.

---

## 1. Diagnosis, why the current detector is wrong

The current pipeline (`run_pixel_diff_loop`) is:

```
prev_frame ──absdiff──► diff ──mask──► count_eroded_above_threshold ──► score = changed / total
                                                                          score ≥ floor ⇒ motion
```

It has **two independent root causes** of bad behavior, plus a UX/scale problem.

### 1.1 Prev-frame diff is not a background model

`frame_absdiff(&prev_frame, &curr_frame, …)` compares each frame to the **immediately
preceding frame**. This is equivalent to a background model with `alpha = 1.0`, the
most extreme possible adaptation rate. Consequences, all observed:

- **Stopped objects vanish.** A person who stops walking produces ~zero diff against the
  previous (nearly identical) frame within 1–2 frames, so motion "ends" and recording
  stops while the person is still standing in view. A real NVR must keep recording.
- **Lighting drift trips it.** AGC ramps, sunrise, drifting cloud shadow, and IR-cut
  transitions change every frame slightly. Per-frame this is below threshold, but there
  is no stable reference to drift *against*, the moment the rate of change crosses the
  per-pixel threshold (e.g., an IR cut switch, a headlight sweep), the whole frame lights
  up as "changed."
- **No persistence / no notion of "the scene as it should look."** Every decision is made
  against a 1-frame-old snapshot, so the detector has no memory of the quiescent scene.

Every reference system we surveyed (Frigate, ZoneMinder, a leading commercial VMS, even the
lightweight `motion` daemon) uses a **running/weighted-average background model**, not a
prev-frame diff. Frigate: `accumulateWeighted, alpha=0.01`. ZoneMinder: 6.25 % indoor
blend. The one system that uses a near-prev-frame approach (`motion`, alpha=0.5) is
explicitly documented as unsuitable for keeping recordings running while a subject is
present. **This is the single highest-value fix.**

### 1.2 "% of whole frame changed" conflates scattered noise with a compact object

`score = changed_pixels / total_pixels` is a **global pixel count**. It collapses all
spatial information. The detector cannot distinguish:

- **600 scattered noise pixels** spread across the frame (sensor grain, AGC shimmer,
  timestamp-digit flicker, H.264 macroblock-boundary churn, tree-leaf glitter), *not a
  real object*; from
- **600 pixels forming one compact person-shaped blob**, *a real object*.

Both score `600 / 57600 ≈ 1.04 %` and are treated identically.

The recently-added 3×3 relaxed erosion (`count_eroded_above_threshold`,
`MIN_NEIGHBOURS_ON = 4`) is a real improvement, it deletes truly isolated speckle, but
it does **not** solve the conflation, because after erosion the code *still sums every
surviving pixel across the whole frame*. Correlated noise (a shimmering tree, a flag, rain
streaks) survives erosion as many small clusters whose total can still cross the floor,
while the floor has to be set so low to catch a small/distant person (≈0.3 %) that it has
almost no margin against that correlated noise.

The correct question is **"is there a compact connected region big enough to be a real
object?"**, a *blob-area* test, not a *total-pixel-fraction* test. This requires
**connected-component labeling**: group adjacent changed pixels into blobs, measure each
blob's pixel area, and decide on the **largest blob** (or the sum of blobs above a minimum
size), not on the global count.

> Concrete illustration at 320×180 (57,600 px):
> - 200 *scattered* noise speckles → after labeling, ~200 blobs of 1–3 px each → largest
>   blob ≈ 3 px → **no motion**.
> - One *distant person* of 200 contiguous px → 1 blob of 200 px → largest blob = 200 px →
>   **motion**.
> The global-fraction detector scores both at 0.35 % and cannot tell them apart.

### 1.3 The four mismatched scales (UX failure)

Four things that *should* be on one scale are on four different ones:

| Surface | Current scale |
|---|---|
| User threshold knob (`motion_threshold`) | 0–100, interpreted as **% of frame** (default 25 ⇒ "25 % of frame must change"). |
| Actual detection floor | `MIN_MOTION_AREA_FRACTION = 0.003` (0.3 %) and `MIN_THRESHOLD = 0.004`. |
| Dynamic auto-threshold | `mean + 3σ` of the changed-pixel fraction. |
| Live tuner grid | per-cell `% of cell pixels changed` (0–100), unrelated to the trigger. |
| Persisted timeline score | `peak_score` = changed-pixel fraction. |

A default of 25 means **"trigger when 25 % of the frame changes"**, i.e., 14,400 px on a
320×180 frame. A person mid-frame is ~1,800–4,000 px (3–7 %); a person on a wide 4K view is
~1–2 %. **The default knob value can never be reached by a real event.** Meanwhile the
*real* trigger is the hidden 0.3 % floor, so the knob the operator turns and the meter they
watch have nothing to do with what actually fires. There is no way for a user to "watch
real motion cross the line," because the meter, the line, and the detector are three
different quantities.

---

## 2. Recommended pipeline (pure Rust, 320×~180 grayscale)

The new per-frame pipeline. Every stage is O(N) or O(N·k) with tiny constants on a
~57 k-pixel frame; see §6.

```
curr_frame (u8, W×H from ffmpeg gray pipe)
   │
   ├─(a) background model:  bg (f32, W×H)  EMA update, alpha by state
   │
   ├─(b) per-pixel diff vs bg + threshold ⇒ binary mask (u8 0/255)
   │
   ├─(c) morphology: 3×3 erode (denoise) → 3×3 dilate ×2 (bridge body gaps)
   │
   ├─(d) connected-component labeling (two-pass union-find) ⇒ blobs + areas
   │
   └─(e) DECISION: largest_blob_area ≥ MIN_BLOB_AREA  (+ lightning gate)
            └─► motion bool, motion_score = largest_blob_area / total_px
```

Mask application (`apply_mask`) stays exactly where it is, zero the diff inside excluded
zones, **after** the per-pixel threshold and **before** morphology, so masked regions never
form blobs. The live tuner grid (`compute_motion_grid`) is computed from the pre-mask diff
as today (so the operator can see what to mask).

### (a) Background model, weighted running average (replaces prev-frame diff)

Keep a per-camera `bg: Vec<f32>` of length `W·H`, initialized from the first decoded frame
(not zeros, zeros would make the first ~100 frames read as full-frame motion). Update each
frame with an exponential moving average:

```rust
// per pixel i, each frame:
bg[i] = bg[i] * (1.0 - alpha) + (curr[i] as f32) * alpha;
```

**Two adaptation rates (the "alarm blend" pattern from ZoneMinder/Frigate):**

| State | alpha | Time constant @ ~8 fps sub-stream | Why |
|---|---|---|---|
| Idle (no motion) | `BG_ALPHA_IDLE = 0.01` | ~100 frames ≈ 12 s | Absorbs slow lighting drift; stable reference. |
| Active (motion event) | `BG_ALPHA_ACTIVE = 0.002` | ~500 frames ≈ 60 s | Background **freezes-ish** so a stationary subject is NOT absorbed into the background mid-event, keeps recording running while someone stands still. |

Rationale for the slow active rate rather than a hard freeze: a hard freeze (alpha 0) lets
a genuine permanent change (a parked car that arrives and stays) hold the event open
forever. A very slow non-zero rate re-absorbs a truly stationary object over ~minute,
which matches operator expectation (an arrived-and-parked car should stop generating an
event after ~a minute, a person who is merely pausing should not).

This single change fixes both §1.1 failures (stopped objects, lighting drift).

> **Why not MOG2/KNN?** They model each pixel as a mixture of Gaussians (~60 bytes/px,
> ~3.3 MB/cam) and effectively require OpenCV. The single-EMA running average is the
> pure-Rust equivalent every lightweight NVR uses: 1 f32/px (≈230 KB/cam at 320×180), one
> multiply-add per pixel per frame. We adopt it.

### (b) Per-pixel diff + threshold

```rust
// PIXEL_DIFF_THRESHOLD = 25 (unchanged)
mask[i] = if (curr[i] as f32 - bg[i]).abs() > PIXEL_DIFF_THRESHOLD as f32 { 255 } else { 0 };
```

`25` is correct and stays: Frigate uses 30, ZoneMinder 25, `motion` 32, PyImageSearch 25.
It is a resolution-independent luminance delta (0–255) and is **not** the problem. Apply
the exclusion mask here (zero `mask[i]` inside excluded zones).

### (c) Morphology, erode then dilate (opening + bridge)

1. **Erode (3×3, ≥4-of-8 neighbours)**, reuse the existing `count_eroded_above_threshold`
   logic, but emit a *mask* instead of a count. Deletes isolated speckle before labeling
   (also shrinks the work for the labeler).
2. **Dilate (3×3, 2 iterations)**, a pixel turns on if any 8-neighbour is on. This bridges
   the gaps inside a moving person (dark clothing, limbs, background showing through) so the
   body becomes **one** connected blob instead of a dozen fragments, without this, no
   fragment is large enough to pass `MIN_BLOB_AREA`. This is the step Frigate/PyImageSearch
   rely on (`dilate iterations=2`).

Net effect = a morphological *opening* (denoise) followed by closing-ish dilation
(consolidate). At 320×180 a 3×3 kernel with 2 dilate iterations is the right physical
scale (matches Frigate at similar frame sizes).

> Optional, deferrable: a 5×5 box blur on `curr` *before* the diff to kill H.264
> macroblock-boundary artefacts. At 320 px wide the artefacts are mild and the
> erode+dilate already handles most speckle, so this is **not** in the v1 default; add it
> only if a specific noisy camera needs it. Cost would be ~1.4 M MACs/frame (negligible).

### (d) Connected-component labeling (the new core, trivial in pure Rust)

We need blob areas. Two standard pure-Rust options; **use two-pass union-find** (no
recursion, no stack-overflow risk, cache-friendly, ~O(N·α)):

- **Pass 1:** scan row-major. For each on-pixel, look at its already-labeled W and N
  neighbours (4-connectivity is sufficient after dilation; 8-connectivity optional).
  - no labeled neighbour → assign a new label;
  - one labeled neighbour → copy it;
  - two different labels → assign one and `union(a, b)` in a `Vec<u32>` disjoint-set
    (path-compressed `find`).
- **Pass 2:** scan again, replacing each label with its `find(root)`, and accumulate
  `area[root] += 1` (and optionally bounding box for debug overlays).

```rust
// sketch
let mut parent: Vec<u32> = Vec::new();          // disjoint-set
let mut labels = vec![0u32; w * h];             // 0 = background
// pass 1: assign + union (4-conn: check left & up)
// pass 2: resolve roots, sum area per root
// result: areas: HashMap<u32, u32> (or a Vec indexed by compacted root id)
let largest_blob = areas.values().copied().max().unwrap_or(0);
```

No external crate, no OpenCV. ~80 lines. This is a textbook algorithm and is the same thing
`findContours`+`contourArea` does for us in the OpenCV world.

### (e) Decision, largest blob area, not global fraction

```rust
let motion = largest_blob >= MIN_BLOB_AREA && !lightning;
let motion_score = largest_blob as f32 / total_pixels;   // 0.0..1.0, persisted
```

We gate on **largest single blob** (cheaper, and a single big compact region is the
strongest "real object" signal). A near-equivalent "sum of all blobs ≥ MIN_BLOB_AREA" is
available if a camera legitimately sees two simultaneous distant subjects; **default to
largest-blob** and keep "sum of qualifying blobs" as a possible later refinement.

**`MIN_BLOB_AREA`, absolute and fractional, scaled to 320×180 (57,600 px):**

| Object @ 320×180 | Approx blob px (post-dilate) | Fraction |
|---|---|---|
| Scattered noise (post-erode) | 0–3 px each | ~0 % |
| Swaying branch / small bird | 30–150 px | 0.05–0.26 % |
| Distant person (~10–13 m, wide FOV) | 150–450 px | 0.26–0.78 % |
| Person mid-frame | 1,800–4,000 px | 3–7 % |
| Vehicle | 3,000–20,000 px | 5–35 % |

**Recommended default `MIN_BLOB_AREA = 175 px` (≈0.30 % of frame).** This is the
convergent answer across all four reference systems normalized to 320×180:

- Frigate auto-formula `w·h/1000` = 57 px (their permissive floor; ours is stricter
  because we dilate more aggressively).
- ZoneMinder "Default" min-blob 0.3 % = 173 px; "Best-high" 0.12 % = 69 px.
- `motion` 1500 px @ 640×480 normalized to 320×180 ≈ 281 px.
- A real person on a wide view is ~150–450 px, so 175 px catches them; a swaying branch
  fragment is ≤150 px and a denoised noise blob is ≤3 px, so both are rejected.

It is stored/used as an **absolute pixel count** internally (so it does not silently change
meaning if the probed height differs from 180), but it is **derived from a fraction** of the
actual `W·H` so it scales automatically across cameras with different aspect ratios:
`MIN_BLOB_AREA = round(BLOB_FRACTION * total_pixels)`, default `BLOB_FRACTION = 0.0030`.

**Lightning / whole-frame-change gate** (from Frigate/ZoneMinder): if the *total* on-pixel
fraction after threshold exceeds `LIGHTNING_FRACTION = 0.50` (50 % of frame), treat the
frame as a global illumination change, **do not emit motion**, and bump the background to
the fast rate (`BG_ALPHA_LIGHTNING = 0.15`) for that frame so the model re-converges quickly
after an IR cut / headlight sweep / lights-on. Cheap: it's the existing total count divided
by total pixels.

### Hysteresis / state machine (keep as-is)

`MOTION_START_FRAMES = 3` (consecutive qualifying frames to start) and
`MOTION_STOP_HYSTERESIS = 15` (consecutive non-qualifying frames to stop) are sound and
unchanged. Add a **warm-up**: emit no motion for the first `WARMUP_FRAMES = 60` frames while
`bg` stabilizes (during warm-up, still update `bg` at the idle rate).

---

## 3. Default parameter values (all scaled to 320×~180)

| Constant | Value | Rationale |
|---|---|---|
| `MOTION_FRAME_WIDTH` | 320 (keep) | Good blob resolution; Frigate uses smaller. |
| `PIXEL_DIFF_THRESHOLD` | 25 (keep) | Luminance-delta noise floor; resolution-independent; matches references. |
| `BG_ALPHA_IDLE` | 0.01 | ~12 s background time constant @ ~8 fps; absorbs lighting drift. Frigate default. |
| `BG_ALPHA_ACTIVE` | 0.002 | ~60 s; near-freeze during events so a paused subject isn't absorbed. |
| `BG_ALPHA_LIGHTNING` | 0.15 | Fast re-converge after a whole-frame illumination change. |
| Erode rule | 3×3, ≥4-of-8 (keep `MIN_NEIGHBOURS_ON=4`) | Deletes isolated/2×2 speckle, keeps a real blob's interior. |
| Dilate | 3×3, 2 iterations | Bridges body gaps into one blob (the step we're missing today). |
| CC connectivity | 4-conn (8-conn optional) | Sufficient after dilation; cheaper. |
| `BLOB_FRACTION` (→ `MIN_BLOB_AREA`) | 0.0030 ⇒ **175 px** @ 320×180 | Catches person ≥~10 m, rejects branch/noise. Convergent across ZM/Frigate/motion. |
| `LIGHTNING_FRACTION` | 0.50 | Reject whole-frame illumination changes (IR cut, headlights, lights-on). |
| `MOTION_START_FRAMES` | 3 (keep) | Suppresses single-frame spikes. |
| `MOTION_STOP_HYSTERESIS` | 15 (keep) | Avoids fragmenting one event. |
| `WARMUP_FRAMES` | 60 | No triggers while `bg` converges (~26 %→ stable). |
| Dynamic σ | `mean + 3σ` of **largest-blob fraction** (keep 3σ) | Same calibration idea, new metric (see §4). |
| Dynamic floor | `BLOB_FRACTION` (0.0030) | Auto-threshold can't drop below the blob-area floor. |

Sensitivity presets (the only knob the user sees; see §4):

| Preset | `MIN_BLOB_AREA` @ 320×180 | Fraction | Catches |
|---|---|---|---|
| High | 80 px | 0.14 % | small animals, distant person |
| **Medium (default)** | **175 px** | **0.30 %** | person at ~10–13 m and closer |
| Low | 400 px | 0.69 % | near/mid person, vehicles; ignores most clutter |

---

## 4. What we persist, and the single user-facing scale

### 4.1 Persisted score (timeline `motion_score`)

Persist **`motion_score = largest_blob_area / total_pixels`** (0.0–1.0), the same quantity
the detector decides on. `peak_score` over an event becomes "peak largest-blob fraction."
This makes the timeline bar a meaningful analog of *object size*, and it is **the same
number** the live meter shows and the threshold marker sits on. (Many NVR timelines are
only binary motion/no-motion; ours can show graduated intensity, a genuine improvement.)

Timeline bar rendering: map `motion_score` to bar height with a saturating scale, e.g.
`height = (motion_score / 0.05).clamp(0,1)` so a 5 %-of-frame blob (clearly a close subject)
saturates the bar and sub-1 % distant subjects are still visibly above the baseline.

### 4.2 The ONE control: "Minimum object size" (a.k.a. Sensitivity)

Replace the 0–100 "% of frame" `motion_threshold` knob with a **single intuitive control
on the same scale as the meter and the detector**. Two equally good framings, expose
*one*:

- **Minimum object size** (recommended, most literal): the size of the smallest blob that
  counts, expressed as **% of frame area**, range **0.05 %–3 %**, default **0.30 %**. This
  *is* `BLOB_FRACTION`. Internally `MIN_BLOB_AREA = round(value/100 * total_pixels)`.
- Or **Sensitivity 0–100** mapping inversely/non-linearly onto the same `BLOB_FRACTION`
  (e.g., `0→3 %`, `50→0.30 %`, `100→0.05 %`). Use this only if a 0–100 slider is preferred
  for continuity; the underlying value is still a blob-area fraction.

**Critical UX requirement, everything on one scale.** The live tuner must show, on a
single axis (fraction of frame, 0–1, log-friendly):

1. **The live meter** = current frame's `largest_blob_area / total_pixels` (a moving bar).
2. **The threshold marker** = `BLOB_FRACTION` (the line, set by the knob).
3. (Dynamic mode) the auto-threshold line = `mean + 3σ` of the largest-blob fraction.

So the operator walks in front of the camera, watches the **largest-blob meter** jump, and
drags the **threshold line** to just below where their body peaks but above where the branch
peaks. Meter, line, detector decision, and persisted timeline value are now **the same
quantity**, which is exactly what is broken today (four different quantities).

The existing 16×9 hot-spot grid stays as a complementary "where is motion" view for drawing
exclusion masks; add a "largest blob this frame: N px (X.XX %)" numeric readout so the
operator can pick a number directly.

### 4.3 Dynamic mode

Keep `mean + 3σ` auto-calibration, but feed it the **largest-blob fraction** per background
frame instead of the global changed-pixel fraction. Floor it at `BLOB_FRACTION` so it can't
collapse below the noise floor. Continue to update only on background (non-motion, non-active)
frames so real motion never poisons the rolling stats (existing gate is correct).

---

## 5. Migration plan from current `motion.rs`

### Keep unchanged
- The ffmpeg gray-pipe decode path (CUDA/CPU, `scale…,format=gray`, raw `pipe:1`),
  ffprobe geometry probe, stderr drain, NVDEC semaphore, back-off loop, cancellation —
  all correct, untouched.
- `frame_absdiff` (still useful), the erosion **neighbour rule** (`MIN_NEIGHBOURS_ON=4`),
  `apply_mask` / `apply_norm_rect` / `apply_polygon`, `compute_motion_grid`,
  `MOTION_START_FRAMES`, `MOTION_STOP_HYSTERESIS`, the `MotionState` machine, `send_signal`,
  `MotionSignal` shape.
- `DynamicSensitivity` struct and `mean+3σ` math (the *input metric* changes; the math
  doesn't).

### Add
1. **`bg: Vec<f32>`** per loop, initialized from the first frame; EMA update with
   state-dependent alpha (`BG_ALPHA_IDLE` / `BG_ALPHA_ACTIVE` / `BG_ALPHA_LIGHTNING`).
   Diff becomes `|curr - bg|` instead of `|prev - curr|`. `prev_frame`/buffer-swap can be
   dropped.
2. **`fn threshold_mask(curr, bg, thr) -> Vec<u8>`** producing the binary mask (replaces the
   inline count).
3. **`fn erode_mask(&mask) -> Vec<u8>`** and **`fn dilate_mask(&mask, iters) -> Vec<u8>`**
   (refactor the existing erosion neighbour-count into a mask-emitting form; add dilate).
4. **`fn connected_components(&mask, w, h) -> (largest_blob_px, total_on_px)`**, two-pass
   union-find. ~80 lines, unit-tested (single blob, two blobs, scattered speckle → largest
   ≈ 0, full-frame → largest ≈ total).
5. **Lightning gate** using `total_on_px / total_pixels > LIGHTNING_FRACTION`.
6. **Warm-up counter** (`WARMUP_FRAMES`).
7. Config plumbing for the new sensitivity control (`BLOB_FRACTION`, presets) on
   `camera.policy`.

### Change
- **Score:** `score = largest_blob_px / total_pixels` (was `changed/total`). This flows
  unchanged into `peak_score` → `MotionSignal.peak_score` → timeline. **No DB/schema change
  needed**, `motion_score` is already a 0–1 fraction; only its *meaning* sharpens
  (object-size fraction vs scattered-pixel fraction). Document the semantic change in the
  migration notes.
- **Decision:** `motion_detected = score >= effective_floor && !lightning`, where
  `effective_floor` = `BLOB_FRACTION` (manual) or `max(dyn_sens.threshold, BLOB_FRACTION)`
  (dynamic). Drop `MIN_MOTION_AREA_FRACTION` (replaced by `BLOB_FRACTION`) and align
  `MIN_THRESHOLD` to it.
- **Tuner/UI:** retire the 0–100 "% of frame" `motion_threshold` semantics; expose
  "Minimum object size" (or Sensitivity) mapping to `BLOB_FRACTION`. Add the largest-blob
  meter + threshold marker on one shared scale, plus the numeric "largest blob = N px"
  readout. Live indicator ("motion now") is just `score >= effective_floor` on the same
  number.

### Coherence outcome
After migration, **one quantity**, largest-blob-area fraction, drives the recording
trigger, the persisted timeline `motion_score`, the live "motion now" indicator, the tuner
meter, and the threshold marker. The operator can finally watch real motion cross the line
they set.

### Suggested commit order (each independently testable)
1. Running-average background model (swap prev-frame for `bg` EMA, dual alpha, warm-up).
   *Fixes stopped-object + lighting drift with the old global score still in place.*
2. Connected-components + largest-blob decision + `BLOB_FRACTION` floor + lightning gate.
   *Fixes the noise/compact-object conflation; switches the score.*
3. Dynamic mode fed by largest-blob fraction.
4. Tuner/config UI rework (sensitivity knob + unified meter/marker scale).

---

## 6. Performance, does it run per-camera at frame rate?

Frame = 320×180 = **57,600 px**. Per-frame, per-camera cost:

| Stage | Work | Ops (order) |
|---|---|---|
| EMA bg update | 1 mul-add / px | ~58 k MAC |
| Diff + threshold | 1 sub + abs + cmp / px | ~58 k |
| Mask apply | bounded by masked area | ≤58 k |
| Erode | ≤8 neighbour reads / on-px | ≤~0.5 M (interior on-pixels only) |
| Dilate ×2 | ≤8 reads / px × 2 | ~0.9 M |
| Connected components | 2 passes + path-compressed union-find | ~2·58 k + α ≈ ~150 k |
| Decision/score | max over blob areas | ≤ #blobs |

Total ≈ **~1.5–2 M simple integer/float ops per frame**. On a modern CPU core that is well
under **~0.5 ms/frame** in release Rust (the EMA, diff, and morphology auto-vectorize;
union-find is branchy but tiny). At a 5–15 fps sub-stream that is **<1 % of one core per
camera** for the analysis math, decode (ffmpeg/NVDEC) dominates, exactly as today.

Memory adds **one `f32` background buffer (~230 KB/cam)** plus the label buffer
(`u32`, ~230 KB) and a couple of `u8` masks (~58 KB each), well under 1 MB/camera, scratch
buffers reused across frames (allocate once outside the loop, like the existing
`diff_buf`/`prev_frame`/`curr_frame`).

**Conclusion:** the full pipeline including connected-component labeling is comfortably
cheap to run per-camera at frame rate in pure Rust. No OpenCV, no GPU compute, no new
crates required.
