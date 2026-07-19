---
title: Storage tiers
sidebar_label: Storage tiers
slug: /recording/storage-tiers
---

# Storage tiers

Crumb writes into one broad media root, bind-mounted into both the
recorder and the API (read-write for the recorder, read-only for the API).
Within that root, footage can live across multiple named storage
locations, typically a live tier on fast storage and an archive tier for
older footage on larger, cheaper storage, though a single-disk install
with no archive tier at all is equally valid.

## Adding a disk

Adding storage doesn't require a compose file edit or a restart of the
stack's shape. Mount the new disk (or a subdirectory of an existing mount)
under the same host media path, then add the corresponding path in the
admin console. The path you add must live **under the media root**; if it
already exists it has to be a directory, and a path that doesn't exist yet
is accepted as long as its parent is a reachable directory. The recorder
creates the directory (and the per-camera subdirectories under it) on its
first write.

## How footage moves between tiers

When a policy has an archive tier configured, footage moves there on the
policy's archive schedule (a cron expression) once it is older than the
live-tier window. A cap or free-space eviction can also move footage early,
before its schedule fires, if the live disk needs the room. Every move
follows the same crash-safe sequence: copy, verify the copy (size and
CRC32 checksum), update the database row to point at the new location and
stage, then delete the source. A reader only ever sees the old location or
the new one, never a half-moved state, and startup reconciliation scans
both live and archive storage so an interruption partway through a move
gets picked back up rather than leaving orphaned or dangling data behind.

## Free-space headroom (and the always-on floor)

Eviction does not have to wait for a disk to be completely full. Two things
keep headroom in reserve:

- **A server-wide floor that is always on.** Crumb keeps a minimum amount of
  free space on the live disk no matter what, 5% of the disk or 50 GiB,
  whichever is stricter (both overridable with the `MIN_FREE_FRACTION` and
  `MIN_FREE_BYTES` environment variables). A full disk means ffmpeg records
  nothing, and losing footage is the one failure I refuse to allow, so this
  backstop fires even on a policy with no size cap and no archive tier.
- **Per-policy headroom overrides.** A policy can set its own free-space
  floor, typically stricter (a percentage, a byte amount, or both), on its
  own live disk. When
  free space drops below that floor, eviction kicks in early: the oldest
  footage is moved to archive if the policy has an archive tier, or deleted
  if it doesn't, until the headroom is back.

Crumb never refuses to record because a disk is full. It always resolves
pressure by freeing space, never by dropping incoming footage.

## Low-water batching

There is one more per-policy knob, a low-water buffer, and it is purely
about *how* eviction runs, not *when* it triggers. Without it, eviction
nibbles a single segment at a time right at the boundary and re-checks
every tick. With a low-water buffer set, a triggered eviction overshoots by
that many bytes, draining a chunk of the oldest footage to archive (or
deleting it) in one pass, then going quiet until the disk creeps back to the
boundary. It smooths eviction into batches; it does not make eviction start
any sooner.

## The storage advisor

The console's **Storage** section carries a storage advisor that reads your
actual recorded data and answers "how full is this getting, how long does
footage really last, and what is eating the space." Per storage location it
shows:

- Total, used, and free space, plus the fill rate over the last 24 hours
  and 7 days.
- How many days of footage the location can sustainably hold at the current
  rate, and how many days until it fills, or a note that it has reached
  steady state (eviction keeping pace rather than the disk still filling).
- The retention you have configured versus the retention the current fill
  rate can actually sustain, so you can bring the two in line.
- A stacked bar of used space broken down by recording policy, with a
  per-camera footprint table underneath (bytes on disk, share of the drive,
  GB per day, days retained, stream, mode, and which policy each camera is
  on). Any space Crumb did not write shows up as "other."
- Up to a few plain-language suggestions when something looks off.

Alongside the per-location cards there is a server-wide **Crumb data
footprint** breakdown: everything Crumb keeps on disk or in Postgres, not
just recordings. Recordings, LPR plate images, the clip and playback and
thumbnail caches, exports, and the database itself each get a line with its
size and where it physically lives, so you can see the whole footprint at a
glance rather than hunting across volumes. The whole advisor is admin-only.
