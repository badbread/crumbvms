---
title: Bookmarks
sidebar_label: Bookmarks
slug: /recording/bookmarks
---

# Bookmarks

A bookmark marks a specific point or span on a camera's timeline for later
reference, separate from the general playback and export tools.

## Protected retention

A bookmark can be marked protected. Protected footage is exempt from every
automatic deletion path: the normal per-tier retention sweep, size caps,
and the absolute maximum retention cap alike. It's the one override that
outranks every other retention setting, by design, since a human decision
to keep something specific should win over a general policy.

Because of that, protected footage can outlive a policy's configured
retention window, or even the absolute retention cap if one is set.
Unprotect (unpin) a bookmark once it's no longer needed so it rejoins
normal retention accounting; a system that never runs out of protected
bookmarks would otherwise slowly erode the disk savings a retention policy
is meant to provide.
