# SPDX-License-Identifier: AGPL-3.0-or-later
# crumb-alpr — Crumb-native LPR worker (fast-alpr). Opt-in: only built/run when
# the `alpr` compose profile is enabled.
FROM python:3.13-slim

# opencv-python-headless bundles its own ffmpeg for RTSP, but still needs the
# system GL/glib shared libs at import time.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker.py .

# Model weights (YOLOv9-t detector + CCT-xs OCR) download on first run to
# ~/.cache. For an air-gapped install, pre-fetch them into the image by running
# a throwaway prediction at build time (uncomment):
#   RUN python -c "from fast_alpr import ALPR; ALPR(detector_model='yolo-v9-t-384-license-plate-end2end', ocr_model='cct-xs-v2-global-model')"

ENTRYPOINT ["python", "-u", "worker.py"]
