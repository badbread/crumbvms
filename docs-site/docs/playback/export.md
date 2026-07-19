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
whole afternoon if you need to. A single export job takes up to 50 clips. When
the list is complete you export it in one action and Crumb produces the video
files for you to download.

This mirrors how a professional operator assembles an evidence package: gather
the relevant moments first, review the list, then export once.

## Options

A few switches on the export, all optional:

- **Burn in the timestamp.** Overlay the recording date and time on the video
  itself, so the footage carries its own timing even after it's copied around.
- **Include audio**, for cameras that recorded it.
- **Password-protect the download.** Set a password and Crumb wraps the export
  in an AES-256 encrypted ZIP, so it's useless to anyone who intercepts the
  file without the password. Hand the password over separately.

## What you get

If you export a single clip with no password, you get a plain video file,
playable in any normal video player. As soon as there's more than one clip, or
you set a password, Crumb bundles the files into one ZIP instead (encrypted
when a password is set, a plain archive otherwise). Either way it's standard
video, so the person you hand it to never needs an account, a login, or any
access to your cameras or recordings, and with a password they need only the
password.

## Where exports live and how long they last

Exports are written to their own storage area (`EXPORT_DIR`), separate from your
recorded footage, so building an export never touches or competes with recording.
Completed exports are cleaned up automatically after a while
(`EXPORT_TTL_SECONDS`, 24 hours by default) so they don't accumulate. Download
the export when it's ready; if it expires before you get to it, just export the
list again.

See the [environment reference](/configuration/environment-reference) for those
two settings. Most installs never need to change them.
