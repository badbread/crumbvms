---
title: Recording policies
sidebar_label: Recording policies
slug: /recording/policies-and-groups
---

# Recording policies

A recording policy is a named, reusable recording profile. Every camera
belongs to exactly one, always. There is no "unset" state and no
inheritance chain to trace: whatever policy a camera is on is the whole
story for how it records and how long its footage lives.

The admin console calls these **profiles**; the database and this
documentation call them **policies**. Same thing. I use "policy" from here
on.

## What a policy actually holds

A policy is more than retention. In one named bundle it carries:

- **What to record**: the mode (Continuous or Motion), whether the main or
  sub stream is captured, and whether audio is kept.
- **The motion capture window**: pre-roll and post-roll seconds, motion
  sensitivity, and (in Manual mode) the motion threshold. These only
  matter for Motion-mode cameras.
- **Where footage lands**: the live storage location, and optionally an
  archive location plus the cron schedule that moves footage there.
- **How long it stays**: the live retention window, an optional archive
  window, optional size caps, an optional absolute retention cap, and
  optional free-space headroom.

See [Recording modes](/recording/recording-modes) for mode behavior and
[Storage tiers](/recording/storage-tiers) for the storage and retention
knobs in detail.

## The Default policy

Every new camera joins the **Default** policy. It does not get a private
copy cloned at creation; it joins the actual shared Default row. That means
if you edit Default, every camera still on it follows immediately. Default
cannot be deleted, and it is the policy new cameras keep joining, so treat
it as your house baseline.

## Tweaking one camera

When you change a recording setting on a single camera (say you flip one
camera to Motion mode, or shorten its retention), Crumb does not quietly
mutate the shared policy underneath every other camera on it. Instead it
splits that one camera onto its own policy, auto-named after the camera. No
dialog, no naming step.

A few things follow from that:

- **If your edit happens to match a policy that already exists**, the
  camera joins that policy instead of minting a new one. Set a camera's
  values back to Default's values and it rejoins Default.
- **Auto-created policies clean themselves up.** A policy Crumb minted for
  a deviation is deleted automatically once its last camera moves off it,
  so you do not accumulate dead single-camera policies.
- **Rename an auto-created policy and it becomes a keeper.** Giving it a
  name promotes it to an operator template: it stays around even at zero
  cameras, so you can reuse it. Policies you create yourself are never
  auto-deleted.

The upshot is that the policy list is honest: every policy you see is
either one you made on purpose or one that a real per-camera deviation
created, and single-camera deviations get a subtle "auto-created when
\<camera\> deviated from its policy" note in the console so you know where
they came from.

## Size caps are a shared budget

This is the one that surprises people, so it is worth stating plainly: a
size cap belongs to the **policy**, not to each camera on it. Five cameras
sharing one policy with a 500 GB live cap share that 500 GB between them,
with the oldest footage across all five evicted first. That is the intended
meaning of putting cameras on the same policy. If you want each camera to
have its own budget, put it on its own policy.

## Camera groups

Groups still exist in v0.1.0, but only as a bulk-assign convenience, not as
an inheritance layer. Assigning a policy to a group writes that policy
directly onto every member camera's own assignment. There is no
group-level policy that members silently inherit; the group is just a
shortcut for "set these cameras to this policy in one action."

Two consequences to know:

- While a camera is in a group, its per-camera recording settings are
  **locked**. To give one camera custom settings you ungroup it first, then
  edit it (which splits it onto its own policy as described above).
- Changing a group's policy re-pins every current member to the new policy
  at that moment. It is a write, not a live link.

I am in the middle of retiring groups in favor of plain policy membership,
since a policy's member list already is the group. For now they are still
here and behave as described. Do not build a mental model around group
inheritance; there isn't any.

## Per-tier retention and the absolute retention cap

Two different enforcement mechanisms apply, and they interact
deliberately:

- **Per-tier retention** (the live window, the archive window, and any size
  cap) governs the normal eviction sweep. The live sweep skips footage
  that has been moved to an archive tier; the archiver owns deleting that
  footage once its own window has passed.
- **The absolute maximum retention cap** is a hard ceiling that overrides
  that scoping on purpose: if set, it removes footage older than the
  configured number of days regardless of whether it is live or archived.
  It is off by default (no surprise pruning on an existing install), and it
  can only ever make footage disappear sooner than the other settings
  would, never later.

A protected bookmark is exempt from both, see [Bookmarks](/recording/bookmarks).
