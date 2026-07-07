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
admin console. The recorder creates the necessary subdirectory on its
first write there.

## How footage moves between tiers

When a policy has an archive tier configured, footage moves there after
its live-tier window passes, following a crash-safe sequence: copy, verify
the copy (size and checksum), update the database row to point at the new
location and stage, then delete the source. A reader only ever sees the
old location or the new one, never a half-moved state, and startup
reconciliation scans both live and archive storage so an interruption
partway through a move gets picked back up rather than leaving orphaned or
dangling data behind.

## Headroom and spill

Advanced per-policy settings allow a free-space headroom buffer and a
spill target, so a policy can be configured to move footage out (or stop
accepting new footage on a tier) before a disk actually fills up, rather
than only reacting after the fact.
