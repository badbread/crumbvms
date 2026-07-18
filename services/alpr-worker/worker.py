#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""crumb-alpr — Crumb-native license-plate-recognition worker.

Pulls frames from a Crumb go2rtc restream, motion-gates them (so it idles most of
the time — like a dedicated ALPR box), runs fast-alpr (a YOLOv9-t ONNX plate
detector + a CCT-xs ONNX OCR), votes across the frames of one vehicle pass, and
POSTs a single best read per pass to Crumb's ``POST /lpr/reads``. 100% local — no
cloud, no third-party agent. Models are fetched at first run (not vendored).

Everything is configured via environment variables (12-factor); see the module
constants below and ``services/alpr-worker/README.md``.
"""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import logging
import os
import sys
import time
import uuid
from dataclasses import dataclass, field

import cv2
import numpy as np
import onnxruntime as ort
import requests
from fast_alpr import ALPR

# ── logging ─────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=os.environ.get("LPR_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s crumb-alpr: %(message)s",
)
log = logging.getLogger("crumb-alpr")


# ── config ──────────────────────────────────────────────────────────────────
def _req(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        log.error("missing required env %s", name)
        sys.exit(2)
    return v


API_BASE = _req("CRUMB_API_BASE").rstrip("/")  # e.g. http://api:8080
INGEST_TOKEN = _req("LPR_INGEST_TOKEN")
CAMERA_ID = _req("LPR_CAMERA_ID")  # Crumb camera UUID
RTSP_URL = _req("LPR_RTSP_URL")  # go2rtc restream RTSP for this camera

# Analysis rate while a pass is active (fps). Motion gating means we run the
# models only on frames with activity, so this bounds the busy-state CPU.
SAMPLE_FPS = float(os.environ.get("LPR_SAMPLE_FPS", "5"))
# A read is kept only if its mean OCR confidence clears this.
MIN_CONF = float(os.environ.get("LPR_MIN_CONFIDENCE", "0.80"))
# Motion gate: a frame is "active" if the changed-pixel fraction exceeds this.
MOTION_MIN_FRAC = float(os.environ.get("LPR_MOTION_MIN_FRAC", "0.0008"))
# A motion-quiet gap this long (seconds) ends the current pass and emits its vote.
PASS_GAP_S = float(os.environ.get("LPR_PASS_GAP_SECONDS", "2.0"))
# Safety cap: emit + reset a pass after this long even if motion never settles.
PASS_MAX_S = float(os.environ.get("LPR_PASS_MAX_SECONDS", "15.0"))
DETECTOR = os.environ.get("LPR_DETECTOR", "yolo-v9-t-384-license-plate-end2end")
OCR = os.environ.get("LPR_OCR", "cct-xs-v2-global-model")
HTTP_TIMEOUT = float(os.environ.get("LPR_HTTP_TIMEOUT", "10"))
# How often to re-poll GET /lpr/worker-config (zones + min-confidence) so admin
# edits apply without restarting the worker.
CONFIG_POLL_S = float(os.environ.get("LPR_CONFIG_POLL_SECONDS", "30"))
# Presence-based dedup ("parked-car detection"): a plate is emitted ONCE when it
# appears, then suppressed for as long as it stays continuously visible. It is
# re-emitted only after it has been ABSENT (unseen) for this long — i.e. the
# vehicle actually left and (re)appeared. So a car parked in view reads once, not
# once per pass. Lower = quicker to treat a brief disappearance as a new arrival;
# higher = stricter about re-reads.
REAPPEAR_GAP_S = float(os.environ.get("LPR_REAPPEAR_GAP_SECONDS", "45"))
# The read's stored image is the WHOLE frame (a Frigate-style context snapshot),
# not a pre-cropped plate: the clients derive the tight plate crop themselves from
# the normalized bbox, so shipping the full frame lets crumb-alpr reads render the
# same "context photo + derived crop" as Frigate reads. Downscale it to keep the
# payload under the server's crop-byte cap.
FRAME_MAX_W = int(os.environ.get("LPR_FRAME_MAX_WIDTH", "1280"))
FRAME_JPEG_Q = int(os.environ.get("LPR_FRAME_JPEG_QUALITY", "82"))
# ONNX Runtime intra-op threads per session. The models are tiny (7 MB detector,
# 3 MB OCR); ORT's default of one thread per core makes every inference a
# 16-way coordination exercise whose spin-waiting pegs EVERY core between
# frames. One thread is both cheaper AND (for these models) not measurably
# slower. Raise only on very weak CPUs where single-core inference can't hold
# LPR_SAMPLE_FPS.
ORT_THREADS = int(os.environ.get("LPR_ORT_THREADS", "1"))
# OpenCV's internal parallel_for pool, same story as ORT_THREADS: fanning a
# ~10 ms MOG2/medianBlur call out across every core costs more in coordination
# than it saves, and keeps otherwise-idle cores awake.
CV_THREADS = int(os.environ.get("LPR_CV_THREADS", "1"))
cv2.setNumThreads(CV_THREADS)
# Emit a one-line pipeline stats summary every N seconds (0 disables).
STATS_S = float(os.environ.get("LPR_STATS_SECONDS", "60"))


def _ort_session_options() -> ort.SessionOptions:
    """Session options that keep tiny-model inference off the all-core path:
    a small fixed thread count, sequential execution, and no spin-waiting
    (spinning burns whole idle cores between 5 fps inferences)."""
    so = ort.SessionOptions()
    so.intra_op_num_threads = ORT_THREADS
    so.inter_op_num_threads = 1
    so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    try:
        so.add_session_config_entry("session.intra_op.allow_spinning", "0")
        so.add_session_config_entry("session.inter_op.allow_spinning", "0")
    except Exception:  # older onnxruntime without these keys — thread cap still applies
        pass
    return so


# ── per-pass vote accumulator ────────────────────────────────────────────────
@dataclass
class PassVote:
    """Accumulates candidate reads across the frames of one vehicle pass."""

    votes: dict[str, float] = field(default_factory=dict)  # plate -> summed conf
    count: dict[str, int] = field(default_factory=dict)  # plate -> frame count
    # Best single frame's artefacts, kept for the emitted read. `best_crop` is a
    # misnomer for API compatibility: it now holds the whole context frame JPEG
    # (the client derives the plate crop from `best_bbox`), sent as crop_jpeg_b64.
    best_conf: float = 0.0
    best_crop: bytes | None = None
    best_bbox: list[float] | None = None  # [x, y, w, h] normalized
    best_region: str | None = None
    # Wall-clock (epoch seconds) of the best frame — sent as the read's `ts` so
    # the clip player centres on when the plate was actually IN FRAME. Without
    # it the server stamps now() at INGEST, which is at pass-emit (after voting,
    # after the car has left), and the plate-clip pop-up lands seconds too late.
    best_epoch: float = 0.0
    started: float = 0.0

    def active(self) -> bool:
        return bool(self.votes)

    def add(self, plate: str, conf: float, crop: bytes | None, bbox, region):
        if not self.active():
            self.started = time.monotonic()
        self.votes[plate] = self.votes.get(plate, 0.0) + conf
        self.count[plate] = self.count.get(plate, 0) + 1
        if conf > self.best_conf:
            self.best_conf, self.best_crop, self.best_bbox, self.best_region = (
                conf,
                crop,
                bbox,
                region,
            )
            self.best_epoch = time.time()

    def winner(self) -> tuple[str, float] | None:
        """Plate with the most summed confidence; its mean confidence."""
        if not self.votes:
            return None
        plate = max(self.votes, key=lambda p: self.votes[p])
        return plate, self.votes[plate] / self.count[plate]

    def reset(self):
        self.__init__()


# ── plate extraction from one frame ──────────────────────────────────────────
def _encode_context_jpeg(frame: np.ndarray) -> bytes | None:
    """Downscale + JPEG-encode the WHOLE frame as the read's context snapshot.
    The clients render this as the full photo and derive the tight plate crop
    from the normalized bbox — so we ship the frame, never a pre-crop."""
    h, w = frame.shape[:2]
    if w > FRAME_MAX_W:
        img = cv2.resize(
            frame,
            (FRAME_MAX_W, max(1, round(h * FRAME_MAX_W / w))),
            interpolation=cv2.INTER_AREA,
        )
    else:
        img = frame
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, FRAME_JPEG_Q])
    return buf.tobytes() if ok else None


def read_frame(alpr: ALPR, frame: np.ndarray):
    """Return the highest-confidence (plate, conf, frame_jpeg, bbox_norm, region)
    read in this frame, or None. `frame_jpeg` is the whole (downscaled) frame, not
    a plate crop. Confidence is the mean per-character OCR score."""
    h, w = frame.shape[:2]
    best = None
    for r in alpr.predict(frame):
        if not r.ocr or not r.ocr.text:
            continue
        conf = float(np.mean(r.ocr.confidence))
        if best is not None and conf <= best[1]:
            continue
        b = r.detection.bounding_box
        # Clamp the plate box to the frame; store it normalized for the client crop.
        x1, y1 = max(0, b.x1), max(0, b.y1)
        x2, y2 = min(w, b.x2), min(h, b.y2)
        if x2 <= x1 or y2 <= y1:
            continue
        bbox_norm = [x1 / w, y1 / h, (x2 - x1) / w, (y2 - y1) / h]
        region = getattr(r.ocr, "region", None) or None
        best = (r.ocr.text, conf, bbox_norm, region)
    if best is None:
        return None
    # Encode the context frame once, for the winning detection only.
    text, conf, bbox_norm, region = best
    return (text, conf, _encode_context_jpeg(frame), bbox_norm, region)


# ── detection zones (from GET /lpr/worker-config) ────────────────────────────
def _point_in_poly(x: float, y: float, poly: list) -> bool:
    """Ray-cast point-in-polygon test. `poly` is [[x, y], ...] normalized 0..1."""
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if ((yi > y) != (yj > y)) and (
            x < (xj - xi) * (y - yi) / ((yj - yi) or 1e-9) + xi
        ):
            inside = not inside
        j = i
    return inside


def in_zones(cx: float, cy: float, zones: dict | None) -> bool:
    """Keep a plate whose bbox centroid is (cx, cy) iff it is inside an include
    polygon (or none are defined) AND not inside any exclude polygon. Coords are
    normalized 0..1, matching the read bbox and the stored zone polygons."""
    if not zones:
        return True
    include = zones.get("include") or []
    exclude = zones.get("exclude") or []
    if include and not any(_point_in_poly(cx, cy, p) for p in include):
        return False
    if any(_point_in_poly(cx, cy, p) for p in exclude):
        return False
    return True


def zone_mask_for(zones: dict | None, shape: tuple[int, int]) -> np.ndarray | None:
    """Rasterize the include/exclude zones to a binary mask at frame size, for
    clipping the MOTION mask. Rationale: the zone filter already rejects any
    read outside the include region AFTER inference — so motion outside it
    (canonically: trees swaying at the top of the frame, all day, every day)
    can never yield an accepted read and must not be allowed to trigger
    inference either. Returns None when no zones are set (whole frame active).
    """
    if not zones:
        return None
    include = zones.get("include") or []
    exclude = zones.get("exclude") or []
    if not include and not exclude:
        return None
    h, w = shape
    if include:
        m = np.zeros((h, w), dtype=np.uint8)
        for poly in include:
            pts = np.array([[round(x * w), round(y * h)] for x, y in poly], np.int32)
            cv2.fillPoly(m, [pts], 255)
    else:
        m = np.full((h, w), 255, dtype=np.uint8)
    for poly in exclude:
        pts = np.array([[round(x * w), round(y * h)] for x, y in poly], np.int32)
        cv2.fillPoly(m, [pts], 0)
    return m


def fetch_config(session: requests.Session) -> dict:
    """Poll GET /lpr/worker-config for this camera's zones + min-confidence.
    Returns {} on failure; the worker then keeps its last-known config (or env
    defaults / whole-frame on first fetch)."""
    try:
        resp = session.get(
            f"{API_BASE}/lpr/worker-config",
            params={"camera_id": CAMERA_ID},
            headers={"X-Ingest-Token": INGEST_TOKEN},
            timeout=HTTP_TIMEOUT,
        )
        if resp.status_code == 200:
            return resp.json()
        log.warning("worker-config HTTP %s: %s", resp.status_code, resp.text[:120])
    except requests.RequestException as e:
        log.warning("worker-config fetch failed: %s", e)
    return {}


# ── ingest ───────────────────────────────────────────────────────────────────
def post_read(session: requests.Session, plate: str, conf: float, vote: PassVote):
    body = {
        "camera_id": CAMERA_ID,
        "plate": plate,
        "confidence": round(conf, 4),
        "region": vote.best_region,
        "bbox": vote.best_bbox,
        "provider_event_id": uuid.uuid4().hex,
        # Timestamp of the BEST frame (when the plate was clearest / the car was
        # in frame), not emit time — so the plate-clip pop-up centres on the car.
        # RFC3339 UTC (chrono parses it). Falls back to server now() if unset.
        "ts": (
            datetime.fromtimestamp(vote.best_epoch, tz=timezone.utc).isoformat()
            if vote.best_epoch
            else None
        ),
    }
    if vote.best_crop:
        body["crop_jpeg_b64"] = base64.standard_b64encode(vote.best_crop).decode()
    try:
        resp = session.post(
            f"{API_BASE}/lpr/reads",
            json=body,
            headers={"X-Ingest-Token": INGEST_TOKEN},
            timeout=HTTP_TIMEOUT,
        )
        if resp.status_code == 202:
            log.info("read %s (conf %.2f) accepted", plate, conf)
        elif resp.status_code == 403:
            log.warning("ingest 403 — LPR capture disabled or token unset server-side")
        elif resp.status_code == 401:
            log.error("ingest 401 — LPR_INGEST_TOKEN does not match server")
        else:
            log.warning("ingest HTTP %s: %s", resp.status_code, resp.text[:200])
    except requests.RequestException as e:
        log.warning("ingest POST failed: %s", e)


# ── main loop ─────────────────────────────────────────────────────────────────
def run():
    log.info(
        "loading fast-alpr (detector=%s ocr=%s ort_threads=%d)…",
        DETECTOR,
        OCR,
        ORT_THREADS,
    )
    alpr = ALPR(
        detector_model=DETECTOR,
        detector_providers=["CPUExecutionProvider"],
        detector_sess_options=_ort_session_options(),
        ocr_model=OCR,
        ocr_providers=["CPUExecutionProvider"],
        ocr_sess_options=_ort_session_options(),
    )
    session = requests.Session()
    bg = cv2.createBackgroundSubtractorMOG2(history=200, varThreshold=32, detectShadows=False)
    vote = PassVote()
    period = 1.0 / max(SAMPLE_FPS, 0.1)
    last_motion = 0.0
    cfg: dict = {}
    last_cfg = 0.0
    last_read: dict = {}     # plate -> monotonic time last seen (presence tracking)
    pass_new: set = set()    # plates that NEWLY appeared during the current pass
    # Pipeline stats (logged every STATS_S so gating efficacy is observable).
    st_grab = st_proc = st_motion = st_infer = 0
    st_frac_max = 0.0
    last_stats = time.monotonic()
    # Cached zone raster for motion-mask clipping (rebuilt when zones/shape change).
    zmask: np.ndarray | None = None
    zmask_key: tuple | None = None

    while True:
        cap = cv2.VideoCapture(RTSP_URL, cv2.CAP_FFMPEG)
        if not cap.isOpened():
            log.warning("cannot open stream %s — retrying in 5s", RTSP_URL)
            time.sleep(5)
            continue
        log.info("stream open; watching for plates")
        last_process = 0.0
        try:
            while True:
                # grab() (and thus DRAIN) EVERY frame so the FFmpeg buffer never
                # grows — a sleep-per-frame would let latency and timestamp drift
                # accumulate on a live stream. grab() decodes but skips the
                # YUV→BGR conversion + copy; we retrieve() only the frames we
                # actually analyze (SAMPLE_FPS of them per second).
                if not cap.grab():
                    log.warning("stream read failed — reconnecting")
                    break
                now = time.monotonic()
                st_grab += 1

                if STATS_S > 0 and now - last_stats >= STATS_S:
                    log.info(
                        "stats: %ds — frames=%d analyzed=%d motion=%d infer=%d "
                        "frac_max=%.5f (gate=%.5f)",
                        round(now - last_stats),
                        st_grab,
                        st_proc,
                        st_motion,
                        st_infer,
                        st_frac_max,
                        MOTION_MIN_FRAC,
                    )
                    st_grab = st_proc = st_motion = st_infer = 0
                    st_frac_max = 0.0
                    last_stats = now

                # Refresh per-camera config periodically.
                if now - last_cfg >= CONFIG_POLL_S:
                    cfg = fetch_config(session) or cfg
                    last_cfg = now

                # Defense-in-depth (the server enforces these too): honor the
                # per-camera enable + engine. Keep draining, but do no analysis.
                engine = cfg.get("engine", "crumb-alpr")
                if cfg.get("enabled") is False or engine not in ("crumb-alpr", "both"):
                    continue

                # Pace the expensive detect+OCR to SAMPLE_FPS while still draining
                # every frame above.
                if now - last_process < period:
                    continue
                last_process = now
                ok, frame = cap.retrieve()
                if not ok or frame is None:
                    continue
                st_proc += 1

                # A malformed zone shape / bad frame must never crash the loop
                # (which would crash-restart-crash forever under `restart:
                # unless-stopped`). Log and skip the frame instead.
                try:
                    min_conf = float(cfg.get("min_confidence", MIN_CONF))
                    zones = cfg.get("zones")
                    mask = bg.apply(frame)
                    # Despeckle before counting: raw MOG2 flags scattered single
                    # pixels (sensor/IR/compression noise) that at 1080p easily
                    # exceed MOTION_MIN_FRAC, defeating the gate entirely. A 3x3
                    # median wipes isolated pixels but preserves the contiguous
                    # blob of anything vehicle-sized.
                    mask = cv2.medianBlur(mask, 3)
                    # Clip motion to the detection zones (see zone_mask_for) so
                    # perpetual out-of-zone motion (swaying trees…) can't hold
                    # the inference gate open around the clock.
                    key = (repr(zones), mask.shape)
                    if key != zmask_key:
                        zmask = zone_mask_for(zones, mask.shape)
                        zmask_key = key
                    if zmask is not None:
                        mask = cv2.bitwise_and(mask, zmask)
                    frac = float(np.count_nonzero(mask)) / mask.size
                    st_frac_max = max(st_frac_max, frac)
                    if frac >= MOTION_MIN_FRAC:
                        last_motion = now
                        st_motion += 1
                        st_infer += 1
                        got = read_frame(alpr, frame)
                        if got and got[1] >= min_conf:
                            plate, conf, crop, bbox, region = got
                            # Zone filter: keep only plates whose box centroid is
                            # in the allowed region (include ∧ ¬exclude).
                            cx, cy = bbox[0] + bbox[2] / 2, bbox[1] + bbox[3] / 2
                            if in_zones(cx, cy, zones):
                                # Presence-based dedup: a plate is a NEW sighting
                                # only if it hasn't been seen for REAPPEAR_GAP_S
                                # (the vehicle left and came back). A parked /
                                # persistently-visible plate keeps refreshing
                                # last_read, so it is emitted only on arrival.
                                if now - last_read.get(plate, -1e9) > REAPPEAR_GAP_S:
                                    pass_new.add(plate)
                                last_read[plate] = now
                                vote.add(plate, conf, crop, bbox, region)

                    # End-of-pass: emit the winner ONLY if it newly appeared this
                    # pass (a parked plate still sitting in view is not re-emitted).
                    if vote.active() and (
                        now - last_motion >= PASS_GAP_S
                        or now - vote.started >= PASS_MAX_S
                    ):
                        w = vote.winner()
                        if w and w[0] in pass_new:
                            post_read(session, w[0], w[1], vote)
                        vote.reset()
                        pass_new = set()
                        # Drop plates unseen longer than the gap (vehicle left), so
                        # last_read stays small and a true re-arrival re-emits.
                        last_read = {
                            p: t for p, t in last_read.items() if now - t <= REAPPEAR_GAP_S
                        }
                except Exception:
                    log.exception("frame processing error — skipping this frame")
        finally:
            cap.release()


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        pass
