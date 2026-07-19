---
title: Clips
sidebar_label: Clips
slug: /playback/clips
---

# Clips

The Clips tab is a feed of short, interesting moments from your cameras, so you
can review what happened without scrubbing through hours of timeline. Each entry
is a thumbnail you can click to watch a short overview of the moment.

A clip is deliberately a brief **overview** of an event, not the whole thing.
By default each one renders up to 30 seconds (admin-configurable down to 10),
and there's a hard 30-second ceiling baked in, so a long event is trimmed to
that overview rather than played end to end. A short event keeps its natural
length, and an event that's still in progress shows an "ongoing" badge. When a
clip is trimmed, the player tells you the full event length and offers to open
it on the timeline; that's where you watch the whole thing.

## Where clips come from

Crumb pulls clips from two places, automatically, and shows them in one list:

- **Motion**: whenever a camera saw movement, Crumb turns those stretches of its
  own recorded footage into clips. This works on any camera Crumb records, with
  no extra setup.
- **Detections**: if you've connected a detector like
  [Frigate](/integrations/frigate) (or turned on Crumb's own plate reader),
  its detections show up as clips too, labelled with what was detected.

You don't choose a source per clip; they're merged into a single feed, newest
first, so "show me what happened" is one place to look.

## Reviewing a clip

Click a clip to play it. From there you can jump straight to that moment on the
full [timeline](/playback/scrubbing) if you want the surrounding context, or move
to the next clip to keep scanning. A clip you want to keep can be
[bookmarked](/recording/bookmarks) so it's protected from automatic cleanup, or
[exported](/playback/export) to save or share.

## Filtering the feed

The feed can be narrowed to a single camera, a time range, or a type, All,
Detections, or Motion, so a question like "did anyone come to the front door
this afternoon" turns into a short, scannable list instead of a full evening
of footage.
