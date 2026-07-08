---
title: Exporting footage
sidebar_label: Export
slug: /playback/export
---

# Exporting footage

When you need to hand footage to someone (a neighbor, an insurer, the police),
Crumb lets you pull the relevant moments out and save them as ordinary video
files, without giving anyone access to your system.

## Building an export list

Rather than exporting one clip at a time, Crumb works from a list. As you review
[clips](/playback/clips) or scrub the [timeline](/playback/scrubbing), you add the
moments you care about to an export list, from one camera or several, across a
whole afternoon if you need to. When the list is complete you export it in one
action and Crumb packages everything together into a single archive you can
download.

This mirrors how a professional operator assembles an evidence package: gather
the relevant moments first, review the list, then export once.

## What you get

The export is a downloadable archive of standard video files, playable in any
normal video player, no Crumb software required on the other end. Because the
files are plain video, the person you hand them to never needs an account, a
login, or any access to your cameras or recordings.

## Where exports live and how long they last

Exports are written to their own storage area (`EXPORT_DIR`), separate from your
recorded footage, so building an export never touches or competes with recording.
Completed exports are cleaned up automatically after a while
(`EXPORT_TTL_SECONDS`, 24 hours by default) so they don't accumulate. Download
the archive when it's ready; if it expires before you get to it, just export the
list again.

See the [environment reference](/configuration/environment-reference) for those
two settings. Most installs never need to change them.
