---
title: Bookmarks
sidebar_label: Bookmarks
slug: /recording/bookmarks
---

# Bookmarks

A bookmark marks a specific moment on a camera's timeline for later
reference, separate from the general playback and export tools.

## Protected retention

When you create a bookmark you can protect the footage around that moment
from automatic deletion. Protection is set at creation time: you choose how
many days to keep it (1 to 30) and, optionally, how much footage on each
side of the moment to cover (by default 60 seconds before and 300 seconds
after, up to an hour each way). Crumb then holds that window against every
automatic deletion path, the normal per-tier retention sweep, size caps,
and the absolute maximum retention cap alike, for as long as the protection
lasts. It is the one override that outranks every other retention setting,
because a human decision to keep something specific should win over a
general policy.

Protection is deliberately **time-boxed**, not permanent. It expires on its
own once the days you set have passed, and the footage then rejoins normal
retention accounting. There is no "unpin" step and no way to protect
footage forever, that ceiling of 30 days is on purpose, so a pile of
protected bookmarks can never quietly erode the disk savings a retention
policy is meant to provide. If you need footage kept beyond its protection
window, export it before the window ends. Editing a bookmark only changes
its note; deleting the bookmark is the way to end protection early.

## When a bookmark's footage has been deleted

Unprotected bookmarks do not keep footage. Once retention deletes the
recordings at a bookmark's moment, the bookmark stays in the list but its
footage is gone. The desktop app marks such bookmarks with a **Footage
deleted** badge, and opening one in playback says **Footage deleted** along
with the time this camera's recordings now start, instead of a misleading
"no motion" message.

Crumb never removes these bookmarks on its own. When you want to tidy up,
use **Remove expired** at the top of the bookmarks list: it asks once, then
removes every bookmark whose footage is gone. A bookmark that falls in a
short gap inside the footage you still have (no motion, or the camera was
offline for a moment) is not counted as expired.

## Deleting a bookmark

Clicking the delete button asks for confirmation first. Hold **Shift** while
clicking to delete straight away. Either way, a message with an **Undo**
button appears for a few seconds; Undo puts the bookmark back with the same
camera, time and note. If it was protected, the protection is restored too,
for the time it had left (rounded up to whole days). A protection that had
already run out is not restored.
