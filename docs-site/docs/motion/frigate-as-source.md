---
title: Frigate as a detection source
sidebar_label: Frigate as a source
slug: /motion/frigate-as-source
---

# Frigate as a detection source

Crumb's own detectors work on raw pixel motion; they don't know the
difference between a person, a car, and a blowing branch. If you already
run a dedicated object detector on your own hardware, Crumb can use it in
two ways.

This is entirely optional and entirely bring-your-own: Crumb does not
bundle or run an object detector itself, and pixel motion detection keeps
working the same whether or not an integration is configured. See
[Integrations](/integrations/frigate) for the setup steps and what data
flows where.

## As timeline enrichment (alongside pixel motion)

By default, an integrated detector's events (person, car, package, and so
on, whatever labels it produces) show up as their own icons on the same
timeline as pixel motion, distinguishable at a glance. Pixel motion still
drives recording; the detections are added context. This is additive and
changes nothing about how recording is triggered.

## As the recording trigger (per camera)

You can also let object detections drive recording for a specific camera,
in place of pixel motion. Each camera has a motion source that is either
`pixel` (the default, Crumb's own analysis) or `frigate` (recording is
triggered by the detector's object events). Crumb translates an object
appearing and leaving into the same start and stop signal the pixel
pipeline emits, so recording, pre-roll, and post-roll behave identically;
only the trigger differs.

The reason to do this is precision. On a camera pointed at a busy street or
moving foliage, pixel motion fires constantly on things you don't care
about, whereas object detection only fires on an actual person or vehicle.
Switching just that camera to the `frigate` source removes the nuisance
recordings.

### The trade-off, read this before switching

Object-triggered recording is precise, not fail-safe. If the detector does
not report an object, Crumb records nothing for that camera, and its
timeline shows nothing for that window:

- Pixel motion is fail-safe: any motion records, so it over-records but
  rarely misses.
- Object triggering records only what the detector classifies, so it can
  miss real events the detector does not catch: low light, an object type
  it does not track, a detection below its confidence threshold, heavy
  occlusion, or the detector being down.

For a security camera, missing a real event is usually worse than an extra
recording. So treat this as a per-camera decision. Use the `frigate` source
on nuisance-prone cameras where precision matters, and keep pixel motion,
or continuous recording, on cameras where you cannot afford to miss
anything. If you want both guarantees at once, run the camera on continuous
recording and use the object detections purely for timeline highlights: you
never miss footage, and you still get a smart, searchable timeline.
