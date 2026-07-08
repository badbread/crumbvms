---
title: Clips
sidebar_label: Clips
slug: /playback/clips
---

# Clips

The Clips tab is a feed of short, interesting moments from your cameras, so you
can review what happened without scrubbing through hours of timeline. Each entry
is a thumbnail you can click to watch the moment it captured.

## Where clips come from

Crumb pulls clips from two places, automatically, and shows them in one list:

- **Motion**: whenever a camera saw movement, Crumb turns those stretches of its
  own recorded footage into clips. This works on any camera Crumb records, with
  no extra setup.
- **Detections**: if you've connected [Frigate](/integrations/frigate), its
  object detections (a person, a car, a package) show up as clips too, labelled
  with what was detected.

You don't choose a source per clip; they're merged into a single feed, newest
first, so "show me what happened" is one place to look.

## Reviewing a clip

Click a clip to play it. From there you can jump straight to that moment on the
full [timeline](/playback/scrubbing) if you want the surrounding context, or move
to the next clip to keep scanning. A clip you want to keep can be
[bookmarked](/recording/bookmarks) so it's protected from automatic cleanup, or
[exported](/playback/export) to save or share.

## Filtering the feed

The feed can be narrowed to a camera, a time range, or (for Frigate detections) a
label, so a question like "did anyone come to the front door this afternoon"
turns into a short, scannable list instead of a full evening of footage.
