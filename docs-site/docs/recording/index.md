---
title: Recording & Storage
sidebar_label: Overview
slug: /recording/
---

# Recording & Storage

Recording in Crumb is a straight copy from the camera to disk, no
re-encoding, and every recorded segment is indexed in Postgres, which is
the single source of truth for what footage exists and where it lives. A
recording's file on disk without a matching database row is treated as an
orphan: Crumb adopts it back into the index when it can, or quarantines it
to a `_quarantine/` folder for review rather than deleting it on sight. A
database row pointing at a missing file is treated as dangling and removed.
Neither state is allowed to persist silently.

## The two recording modes

**Continuous** records every frame to disk the whole time a camera is
active, the well-understood default, and the safe choice while you're
still getting a feel for a camera's scene.

**Motion** is different from what that name implies in most consumer NVRs.
Cameras in Motion mode buffer in a RAM cache and only persist to disk when
motion is actually detected, pre-roll, the event itself, and post-roll;
idle time between events is never written to disk at all. See
[Recording modes](/recording/recording-modes) for the full mechanism and
its safety rails.

## Recording policies and storage

Every camera belongs to exactly one named recording policy, which sets how
it records and how long its footage is kept (retention windows, size caps,
which storage tiers). There is no inheritance chain to reason about:
assigning the same policy to several cameras at once is how you get shared
behavior, and camera groups are just a bulk way to do that assignment. See
[Recording policies](/recording/policies-and-groups) and
[Storage tiers](/recording/storage-tiers).

## Protecting specific footage

A bookmark can be created with protection, which exempts the footage around
it from every automatic deletion path, retention sweeps, size caps, and the
absolute retention cap alike, for a time-boxed window you choose (up to 30
days). See [Bookmarks](/recording/bookmarks).

## In this section

- [Recording modes](/recording/recording-modes)
- [Recording policies](/recording/policies-and-groups)
- [Storage tiers](/recording/storage-tiers)
- [Bookmarks](/recording/bookmarks)
