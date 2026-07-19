---
title: Motion sources
sidebar_label: Motion sources
slug: /motion/frigate-as-source
---

# Motion sources: pixel, Frigate, and Home Assistant

Crumb's own detectors work on raw pixel motion; they don't know the
difference between a person, a car, and a blowing branch. That pixel
analysis is one of three things that can trigger recording on a camera, and
you can turn each one on independently:

- **Pixel analysis (Crumb)**, the default: Crumb's own motion detection on
  the camera's sub-stream.
- **Frigate detections**: recording is triggered by Frigate's neural object
  events (person, car, package, and so on).
- **Home Assistant sensors**: recording is triggered by linked Home
  Assistant motion or door/window sensors (PIR, occupancy, a contact
  sensor).

These are additive. A camera records on the **union** of whichever sources
you enable, so you can run pixel analysis and Frigate together, Frigate on
its own, pixel plus a door sensor, or any other combination. In the camera
editor's Motion tab, each source is a separate checkbox.

Frigate and Home Assistant are both entirely optional and entirely
bring-your-own: Crumb does not bundle or run either one, and pixel motion
detection keeps working the same whether or not an integration is
configured. See [Integrations](/integrations/) for the setup steps and what
data flows where.

## Detections on the timeline (independent of the trigger)

Turning a source *on as a trigger* is separate from *showing its events on
the timeline*. Whenever Frigate or Home Assistant is connected, their events
(object labels from Frigate, door/window/motion from Home Assistant) show up
as their own icons on the same timeline as pixel motion, distinguishable at
a glance, whether or not you've made them a recording trigger for that
camera. So you can leave a camera on pixel motion for recording and still
get a smart, labelled timeline from an integrated detector.

## Using Frigate or Home Assistant as the trigger (per camera)

You can let object detections or a sensor drive recording for a specific
camera instead of, or alongside, pixel motion. Crumb translates a source's
"something is happening now" into the same start and stop signal the pixel
pipeline emits, so recording, pre-roll, and post-roll behave identically no
matter which source fired; only the trigger differs.

The reason to lean on Frigate or a sensor is precision. On a camera pointed
at a busy street or moving foliage, pixel motion fires constantly on things
you don't care about, whereas an object detector only fires on an actual
person or vehicle, and a PIR or door sensor only fires on real physical
events. Turning off pixel analysis for just that camera and leaving Frigate
(or the sensor) on removes the nuisance recordings.

### The trade-off, read this before turning pixel motion off

Object- or sensor-triggered recording is precise, but on its own it is not
fail-safe. If the only enabled source doesn't report anything, Crumb records
nothing for that camera in that window:

- Pixel motion is fail-safe: any motion records, so it over-records but
  rarely misses.
- An object or sensor trigger records only what that source reports, so it
  can miss real events the source doesn't catch: low light, an object type
  the detector doesn't track, a detection below its confidence threshold,
  heavy occlusion, a sensor out of range.

One important exception: a source going *unreachable* does not silently drop
footage. If Frigate's broker disconnects, or Home Assistant can't be polled,
or the pixel detector's own task dies, that source is marked unhealthy and
the camera **fails open**, recording everything until the source recovers.
Crumb also raises a health alert. So the miss cases above are the
source-is-up-but-blind ones, not source-is-down.

For a security camera, missing a real event is usually worse than an extra
recording. So treat this as a per-camera decision. Lean on Frigate or a
sensor on nuisance-prone cameras where precision matters, and keep pixel
analysis (or continuous recording) on cameras where you cannot afford to
miss anything. If you want both guarantees at once, run the camera on
continuous recording and use the detections purely for timeline highlights:
you never miss footage, and you still get a smart, searchable timeline.
