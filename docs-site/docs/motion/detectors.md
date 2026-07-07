---
title: Detectors
sidebar_label: Detectors
slug: /motion/detectors
---

# Detectors

Motion detection is pluggable per camera, so different cameras can use
whichever detector fits their scene.

- **Census** (default) applies a small structural transform to each frame
  before comparing it to a background model, which makes it resistant to
  shadow and lighting-driven false triggers that a raw pixel-difference
  approach is prone to. This is the recommended default for most scenes.
- **Frame difference** is the simpler pixel-difference approach: fast, but
  more sensitive to lighting changes and shadows than Census.
- **MOG2** is a Gaussian mixture background subtractor, a heavier but more
  adaptive background model for scenes with more complex, gradually
  changing backgrounds.
- **Optical flow** looks at motion vectors between frames rather than
  static pixel differences, useful for distinguishing genuine directional
  movement from noise.
- **Ensemble** combines multiple detectors' judgments rather than relying
  on one.

All detectors use a decaying-histogram adaptive threshold underneath
(see [Tuning](/motion/tuning)) that learns each camera's normal background
activity level over time, rather than a single fixed sensitivity number
that has to be hand-tuned per scene and per time of day.

## Choosing one

Census is the right starting point for nearly every camera. Switch only if
a specific scene is giving you trouble, a lot of tree or foliage movement
might do better with a heavier background model, and a scene where
direction of movement matters (a driveway versus a sidewalk, say) might
benefit from optical flow. Changing detectors is a per-camera setting, not
a stack-wide one.
