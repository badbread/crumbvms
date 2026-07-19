---
title: Motion & Detection
sidebar_label: Overview
slug: /motion/
---

# Motion & Detection

Crumb's own motion detection drives the recording trigger in Motion mode
(see [Recording modes](/recording/recording-modes)), the timeline's motion
indicator, and notification rules. It runs entirely on your own hardware,
on a downscaled grayscale frame from each camera's sub-stream, and doesn't
require an object detector to be useful on its own.

General object-level detection, telling a person apart from a car apart
from a package, is deliberately not something Crumb's own motion pipeline
does: if you already run (or want to run) a dedicated object detector,
Crumb can show its results as icons on the same timeline. The one kind of
recognition Crumb does ship is an optional, opt-in, fully local
license-plate reader, off unless you turn it on. See
[Integrations](/integrations/).

## In this section

- [Detectors](/motion/detectors), the detector choices and how they
  differ.
- [Tuning](/motion/tuning), exclusion zones and per-camera sensitivity.
- [Motion sources](/motion/frigate-as-source), how pixel analysis, Frigate
  detections, and Home Assistant sensors can each trigger recording, together
  or on their own.
