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
import logging
import os
import sys
import time
import uuid
from dataclasses import dataclass, field

import cv2
import numpy as np
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


# ── per-pass vote accumulator ────────────────────────────────────────────────
@dataclass
class PassVote:
    """Accumulates candidate reads across the frames of one vehicle pass."""

    votes: dict[str, float] = field(default_factory=dict)  # plate -> summed conf
    count: dict[str, int] = field(default_factory=dict)  # plate -> frame count
    # Best single frame's artefacts, kept for the emitted read's crop + bbox.
    best_conf: float = 0.0
    best_crop: bytes | None = None
    best_bbox: list[float] | None = None  # [x, y, w, h] normalized
    best_region: str | None = None
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

    def winner(self) -> tuple[str, float] | None:
        """Plate with the most summed confidence; its mean confidence."""
        if not self.votes:
            return None
        plate = max(self.votes, key=lambda p: self.votes[p])
        return plate, self.votes[plate] / self.count[plate]

    def reset(self):
        self.__init__()


# ── plate extraction from one frame ──────────────────────────────────────────
def read_frame(alpr: ALPR, frame: np.ndarray):
    """Return the highest-confidence (plate, conf, crop_jpeg, bbox_norm, region)
    read in this frame, or None. Confidence is the mean per-character OCR score."""
    h, w = frame.shape[:2]
    best = None
    for r in alpr.predict(frame):
        if not r.ocr or not r.ocr.text:
            continue
        conf = float(np.mean(r.ocr.confidence))
        if best is not None and conf <= best[1]:
            continue
        b = r.detection.bounding_box
        # Clamp to the frame and encode a tight JPEG crop of the plate.
        x1, y1 = max(0, b.x1), max(0, b.y1)
        x2, y2 = min(w, b.x2), min(h, b.y2)
        crop_jpeg = None
        if x2 > x1 and y2 > y1:
            ok, buf = cv2.imencode(".jpg", frame[y1:y2, x1:x2])
            if ok:
                crop_jpeg = buf.tobytes()
        bbox_norm = [x1 / w, y1 / h, (x2 - x1) / w, (y2 - y1) / h]
        region = getattr(r.ocr, "region", None) or None
        best = (r.ocr.text, conf, crop_jpeg, bbox_norm, region)
    return best


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
        "ts": None,  # server stamps now() when omitted
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
    log.info("loading fast-alpr (detector=%s ocr=%s)…", DETECTOR, OCR)
    alpr = ALPR(detector_model=DETECTOR, ocr_model=OCR)
    session = requests.Session()
    bg = cv2.createBackgroundSubtractorMOG2(history=200, varThreshold=32, detectShadows=False)
    vote = PassVote()
    period = 1.0 / max(SAMPLE_FPS, 0.1)
    last_motion = 0.0
    cfg: dict = {}
    last_cfg = 0.0

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
                # Read (and thus DRAIN) EVERY frame so the FFmpeg buffer never
                # grows — a sleep-per-frame would let latency and timestamp drift
                # accumulate on a live stream.
                ok, frame = cap.read()
                if not ok:
                    log.warning("stream read failed — reconnecting")
                    break
                now = time.monotonic()

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

                # A malformed zone shape / bad frame must never crash the loop
                # (which would crash-restart-crash forever under `restart:
                # unless-stopped`). Log and skip the frame instead.
                try:
                    min_conf = float(cfg.get("min_confidence", MIN_CONF))
                    zones = cfg.get("zones")
                    mask = bg.apply(frame)
                    frac = float(np.count_nonzero(mask)) / mask.size
                    if frac >= MOTION_MIN_FRAC:
                        last_motion = now
                        got = read_frame(alpr, frame)
                        if got and got[1] >= min_conf:
                            plate, conf, crop, bbox, region = got
                            # Zone filter: keep only plates whose box centroid is
                            # in the allowed region (include ∧ ¬exclude).
                            cx, cy = bbox[0] + bbox[2] / 2, bbox[1] + bbox[3] / 2
                            if in_zones(cx, cy, zones):
                                vote.add(plate, conf, crop, bbox, region)

                    # End-of-pass: motion settled or safety cap → emit the vote.
                    if vote.active() and (
                        now - last_motion >= PASS_GAP_S
                        or now - vote.started >= PASS_MAX_S
                    ):
                        w = vote.winner()
                        if w:
                            post_read(session, w[0], w[1], vote)
                        vote.reset()
                except Exception:
                    log.exception("frame processing error — skipping this frame")
        finally:
            cap.release()


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        pass
