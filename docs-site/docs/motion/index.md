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

Object-level detection, telling a person apart from a car apart from a
package, is a separate, deliberately out-of-scope concern for Crumb
itself: if you already run (or want to run) a dedicated object detector,
Crumb can show its results as icons on the same timeline. See
[Integrations](/integrations/).

## In this section

- [Detectors](/motion/detectors), the detector choices and how they
  differ.
- [Tuning](/motion/tuning), exclusion zones and per-camera sensitivity.
- [Frigate as a detection source](/motion/frigate-as-source), showing
  object-level detections alongside pixel motion.
