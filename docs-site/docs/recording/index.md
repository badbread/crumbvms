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
orphan and either adopted or cleaned up; a database row pointing at a
missing file is treated as dangling and removed. Neither state is allowed
to persist silently.

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

## Policies, groups, and storage

Retention is governed by named policies (how much to keep, for how long,
across which storage tiers), which can be applied per camera or per
camera group so a whole group inherits the same settings at once. See
[Policies and groups](/recording/policies-and-groups) and
[Storage tiers](/recording/storage-tiers).

## Protecting specific footage

A bookmark can be marked protected, which exempts it from every automatic
deletion path, retention sweeps, size caps, and the absolute retention
cap alike, until you unpin it. See [Bookmarks](/recording/bookmarks).

## In this section

- [Recording modes](/recording/recording-modes)
- [Policies and groups](/recording/policies-and-groups)
- [Storage tiers](/recording/storage-tiers)
- [Bookmarks](/recording/bookmarks)
