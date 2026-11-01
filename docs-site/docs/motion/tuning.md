---
title: Tuning
sidebar_label: Tuning
slug: /motion/tuning
---

# Tuning motion detection

## Exclusion zones

If a specific part of a camera's frame reliably produces false triggers, a
tree branch, a street corner, a flag, paint an exclusion zone directly on
the live image in the camera's **Detection** tab in the admin console (click
or drag to paint, right-click to erase). Motion inside an excluded zone is
ignored entirely for that camera. This is almost always a
better fix than raising a sensitivity threshold across the whole frame,
since it targets the specific nuisance region without also making the
detector less sensitive to a real event happening elsewhere in the same
shot.

## Adaptive threshold

Rather than a single fixed sensitivity number, each camera's detector
learns its own normal background activity level from a rolling history of
recent frames, including a per-hour-of-day profile, so a driveway that
sees passing headlights at night and shifting shadows at midday settles on
a different effective floor for each, without manual retuning as
conditions change. This adapts over hours to days of runtime; a brand new
camera hasn't learned its scene yet, which is part of why starting new
cameras on Continuous (or Motion with shadow mode) until the detector has
settled in is the recommended path, see [Recording modes](/recording/recording-modes).

This is the **Dynamic** sensitivity mode, the default. If you would rather
set the trigger level yourself, switch **Sensitivity mode** to **Manual** and
set the **Triggering floor**: the smallest moving area, as a percentage of
the frame, that counts as motion. The live meter in the Detection tab shows
what the detector is seeing against that floor as you tune.

Exclusion zones and the detector choice belong to the camera itself. The
sensitivity mode, triggering floor, and pre- and post-roll belong to its
[recording policy](/recording/policies-and-groups), so changing them for one
camera on a shared policy moves that camera onto its own policy.

## "False motion" that isn't a bug

Trees, moving shadows, and a busy street are common sources of what looks
like a false trigger but is, technically, real pixel motion. The fix for
that class of nuisance is an exclusion zone (if it's a fixed region of the
frame) or an object detector via [Frigate as a source](/motion/frigate-as-source)
(if you want detection gated on "was this actually a person," not just
"did pixels change"), not chasing a lower sensitivity threshold that will
also make the camera miss real events.
