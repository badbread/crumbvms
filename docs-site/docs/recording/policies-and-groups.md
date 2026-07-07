---
title: Policies and groups
sidebar_label: Policies and groups
slug: /recording/policies-and-groups
---

# Policies and groups

A recording policy is a named bundle of retention settings: which storage
tier to write to, a size cap, a minimum time to keep, and optionally an
absolute maximum retention cap that applies regardless of size. Every
camera has a policy, cloned from a default (or a group's policy) at the
moment the camera is created.

## Camera groups

Cameras can be organized into groups, and a group can carry its own
policy, applied to every camera in it. This is how you run, for example,
an "always record" group for cameras where continuous footage matters and
a "motion only" group for lower-priority cameras, adding both kinds of
camera in the same discovery batch and assigning each to its group as you
go.

Groups support inheritance, so a policy set at the group level applies to
every member without having to configure each camera individually, while
still allowing a specific camera's policy to be overridden if it needs to
differ from its group.

## Size caps and the absolute retention cap

Two different enforcement mechanisms apply, and they interact
deliberately:

- **Per-tier retention** (a size cap and/or a minimum keep-time) governs
  the normal eviction sweep, and it skips footage that's been moved to an
  archive tier, the archiver owns deleting that footage once its own
  window has passed.
- **The absolute maximum retention cap** is a hard ceiling that overrides
  that scoping on purpose: if set, it removes footage older than the
  configured number of days regardless of whether it's live or archived.
  It's off by default (no surprise pruning on an existing install), and it
  can only ever make footage disappear sooner than the other settings
  would, never later.

A protected bookmark is exempt from both, see [Bookmarks](/recording/bookmarks).
