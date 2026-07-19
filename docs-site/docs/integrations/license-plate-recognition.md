---
title: License-plate recognition (LPR)
sidebar_label: License plates (LPR)
slug: /integrations/lpr
---

# License-plate recognition

Crumb can keep a searchable database of the plates it sees, alert you when a
watchlisted plate shows up, and hold a crop image of each read. It's off by
default, it's gated by the `view_plates` capability, and every read is
camera-scoped like everything else in Crumb. You choose, per camera, which
engine does the reading.

There are two engines, and you can run either one, or both side by side:

- **Frigate native LPR** reads plates on the MQTT event stream Crumb already
  consumes. No new services, no new keys. If you already run Frigate for object
  detection, this is the zero-effort path.
- **The `crumb-alpr` worker** is Crumb's own local OCR engine: an opt-in Python
  sidecar running [`fast-alpr`](https://github.com/ankandrew/fast-alpr),
  100% local, no cloud, no GPU. I wrote it because Frigate's native LPR misread
  most plates on my wide overview-angle entry camera, and I wanted something I
  could run on the same box that reads better on that angle.

## Turn it on and pick an engine per camera

LPR has one global switch and one per-camera control.

- **Global:** enable LPR and set the retention window in the console's **LPR**
  section (the API is `GET`/`PUT /config/lpr`). It ships disabled. With LPR
  disabled, nothing is captured no matter what the cameras say, and the Plates
  nav entry stays hidden.
- **Per camera:** one **Engine** dropdown with four values, and it is the single
  per-camera LPR control:
  - **None** means LPR is off for that camera.
  - **Frigate** accepts plate reads from Frigate's native LPR on the event
    stream. This is the default for a new camera.
  - **Crumb (fast-alpr)** accepts reads POSTed by the local worker.
  - **Both** accepts reads from either engine (each read is tagged by its
    `source_id`, which is what makes the benchmark below possible).

The server enforces that selection at the moment a read arrives: the ingester
looks up the camera's engine and drops any read whose source the engine doesn't
accept. So a `None` or `Crumb`-only camera silently ignores Frigate's plate
reads, and vice versa. If you're running Frigate LPR and see no plates, this is
the first thing to check: LPR enabled globally, and the camera's engine set to
**Frigate** or **Both**.

## Engine A: Frigate native LPR

If Frigate is already configured for LPR, its plate reads ride the same
`frigate/events` MQTT stream Crumb subscribes to for object detections. Enable
LPR globally, set the camera's engine to **Frigate**, and reads start landing in
the Plates tab. Nothing else to install.

The honest caveat: on a wide overview angle where the plate is small in frame,
Frigate's native LPR missed a lot in my testing. If that describes your entry
camera, the local worker below is the reason it exists.

## Engine B: the `crumb-alpr` local worker

The worker is an opt-in container behind the `alpr` Compose profile. It pulls
frames from that camera's go2rtc restream over RTSP, gates on cheap frame-diff
motion, runs `fast-alpr` (a YOLOv9-t ONNX plate detector plus a CCT-xs ONNX OCR),
votes across the frames of a single vehicle pass, and POSTs **one best read per
pass** to Crumb's `POST /lpr/reads` with a real plate crop attached. From there
the read flows through Crumb's existing plate pipeline (dedup, watchlist, alerts,
ignore-list, timeline) exactly like a Frigate read.

One worker instance reads one camera. Run several instances for several cameras.

**Setup, in order:**

1. Enable LPR globally (above).
2. In **Admin → LPR**, mint an **ingest token** with the rotate-token control
   (`POST /config/lpr/rotate-token`). It's shown once. The token is how the
   worker authenticates; the server rejects any read when LPR is disabled.
3. Set that camera's **Engine** to **Crumb (fast-alpr)** or **Both**.
4. Set the worker's env in `.env`: at minimum `CRUMB_API_BASE`,
   `LPR_INGEST_TOKEN`, `LPR_CAMERA_ID`, and `LPR_RTSP_URL` (the full table of
   knobs and their defaults lives in `services/alpr-worker/README.md`).
5. Start it: `docker compose --profile alpr up -d --build crumb-alpr`.

The worker polls `GET /lpr/worker-config` (ingest-token auth, not a user login)
for its per-camera zones and confidence floor, so you can retune from the console
without restarting the container. Parked-car dedup means a car sitting in view
reads once, not on a loop: a plate only re-emits after it's been unseen for a
while (45 seconds by default).

### Power and hardware

This is the part I'm proud of. The worker is CPU-only and the models are tiny
(7 MB detector, 3 MB OCR). Motion-gated, it idles most of the time. On a single
1080p entry camera it costs roughly a third of one CPU core at idle and about
half a core during an actual plate pass, single-digit watts.

The one thing to leave alone: `LPR_ORT_THREADS` and `LPR_CV_THREADS` default to
`1` on purpose. The models are small enough that ONNX Runtime's default (one
thread per core) turns each inference into an all-core spin-wait that burns
15 to 40 W for no extra speed. Keep them at 1 unless you've measured a reason not
to on a genuinely weak CPU.

## Detection zones

Each camera can carry read zones so the worker only bothers with the part of the
frame where plates actually appear. Zones are normalized polygons stored on the
camera (`include` and `exclude` lists, coordinates 0 to 1). The rule is: keep a
plate if its box centroid is inside an include polygon (or if no include polygon
is defined, the whole frame is fair game) and not inside any exclude polygon. You
draw them in the LPR section's per-camera zone editor over a live snapshot.

## Watchlist, ignore list, and fuzzy matching

- **Watchlist:** add plates you care about (`GET`/`POST /lpr/watchlist`, `DELETE /lpr/watchlist/:id`;
  reads are `view_plates`-gated, writes are admin). A watchlist hit fans out as a
  `plate_watchlist_hit` alert with the crop attached.
- **Ignore list:** plates Crumb drops entirely at ingest: an ignored plate is
  never stored and never shows up in search, not merely muted from alerts. It
  fails closed.
- **Fuzzy matching:** matching is length-scaled character tolerance, not trigram
  similarity. The fuzz value (0 to 0.5, set alongside the enable toggle) means
  "up to this fraction of the plate's characters may differ" and works out to
  `floor(fuzz × length)` allowed edits. On top of that, **visually confusable
  characters cost zero edits**: O/0/D, I/1, B/8, S/5, Z/2, and G/6. A night-time
  OCR flip on one of those can never push a real watchlisted plate over the
  budget, which is the behavior I want (I'd rather never miss an alert).

## Searching and retention

Search the read database with `GET /plates` (exact, prefix, contains, or fuzzy
match). Crops are served by `GET /plates/:id/crop`. Retention is a day count set
in the LPR section, and a storage-footprint card there shows how much disk the
stored reads and crops are using (`GET /lpr/storage`).

## Print a plate report

Any single sighting exports as a clean one-page PDF from the desktop client: the
plate, the sighting time (with a timezone you pick), the camera, both the full
frame and the plate crop, and a short dossier of that plate's other recent
sightings. If the plate is on your watchlist, the report leads with a red
watchlist banner. It saves or shares through the normal system dialog, so you can
hand a sighting to whoever needs it (an HOA, an insurer, the police) without
screenshotting the app.

## The A/B benchmark

Set a camera's engine to **Both** and every vehicle pass gets read by both
engines, each read tagged by its source. The desktop app
(`apps/desktop-flutter`) has a **Benchmark** screen, reachable from the Plates
screen whenever at least one dual-engine camera exists, that puts the two engines
head to head.

`GET /lpr/ab-report` clusters the raw reads into vehicle passes at report time
(there's no stored "pass" entity), pairing Frigate and worker reads that fall
within a short window (8 seconds by default). The screen shows two side-by-side
stat cards (reads, passes seen, hit rate, average confidence, accuracy) and a
newest-first list of paired passes. Each row carries the pass's context frame and
the tight plate crop, both click-to-enlarge, plus both engines' plate and
confidence and a match / differ / miss verdict. Every image rides an
authenticated source, either the detection-event snapshot or the stored worker
crop, never an unauthenticated provider URL.

Admins can confirm the true plate for a pass; that confirmation
(`POST /lpr/ab-confirm`) is stored normalized and keyed to the pass, and it's
what anchors the accuracy numbers. The confirm prompt shows both images again so
you can read the plate before you type it.

## Licensing

The `fast-alpr` wrappers are MIT. The default detector weights are YOLOv9-derived
(GPL-3.0, which is compatible with Crumb's AGPL-3.0). Those weights are **not
vendored**: they download at first run, so Crumb never redistributes them. For an
air-gapped install you pre-fetch them (see the Dockerfile comment and
`docs/LPR-NATIVE-ENGINE-PLAN.md`).

## Your responsibility

A searchable database of license plates is regulated in some places. Running it
lawfully is on you as the operator; see [Responsible use](/responsible-use).
