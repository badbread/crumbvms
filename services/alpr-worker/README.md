# crumb-alpr — Crumb-native LPR worker

A small, opt-in sidecar that gives Crumb its **own** license-plate-recognition
engine — free, 100% local, no cloud, no third-party agent. It pulls frames from a
Crumb go2rtc restream, motion-gates them, runs [`fast-alpr`](https://github.com/ankandrew/fast-alpr)
(a YOLOv9-t ONNX plate detector + a CCT-xs ONNX OCR), votes across the frames of a
vehicle pass, and POSTs one best read per pass to Crumb's `POST /lpr/reads`. From
there it flows through Crumb's existing plate pipeline (dedup, watchlist, alerts,
ignore-list, timeline) unchanged.

CPU-only by default; no GPU required. Motion-gated it idles most of the time (~a
few % of one core for a single entry camera).

## Configure (environment)

| Var | Required | Default | Meaning |
|---|---|---|---|
| `CRUMB_API_BASE` | ✅ | — | Crumb API base URL, e.g. `http://api:8080` |
| `LPR_INGEST_TOKEN` | ✅ | — | Ingest token (from **Admin → LPR → rotate token**) |
| `LPR_CAMERA_ID` | ✅ | — | Crumb camera UUID this worker reads |
| `LPR_RTSP_URL` | ✅ | — | go2rtc restream RTSP for that camera |
| `LPR_MIN_CONFIDENCE` | | `0.80` | Drop reads below this mean OCR confidence |
| `LPR_SAMPLE_FPS` | | `5` | Analysis rate while a pass is active |
| `LPR_MOTION_MIN_FRAC` | | `0.0008` | Changed-pixel fraction that counts as motion |
| `LPR_REAPPEAR_GAP_SECONDS` | | `45` | Parked-car dedup: a plate re-emits only after being unseen this long (so a car parked in view reads once, not repeatedly) |
| `LPR_PASS_GAP_SECONDS` | | `2.0` | Motion-quiet gap that ends a pass |
| `LPR_PASS_MAX_SECONDS` | | `15.0` | Hard cap before a pass is emitted anyway |
| `LPR_DETECTOR` / `LPR_OCR` | | fast-alpr defaults | Override the ONNX models |
| `LPR_LOG_LEVEL` | | `INFO` | |

One worker instance = one camera. Run several instances for several cameras.

## Run (opt-in compose profile)

```bash
# LPR must be enabled + a token minted server-side first:
#   Admin → LPR → enable, then "rotate token" → copy it into .env as LPR_INGEST_TOKEN
docker compose --profile alpr up -d crumb-alpr
```

## Licensing

`fast-alpr`, `open-image-models`, `fast-plate-ocr` are MIT. The default **detector
weights are YOLOv9-derived (GPL-3.0)** — compatible with Crumb's AGPL-3.0. The
weights are **not vendored**: they download at first run, so Crumb never
redistributes them. For an air-gapped install, pre-fetch them (see the Dockerfile
comment). See `docs/DECISIONS.md`.
