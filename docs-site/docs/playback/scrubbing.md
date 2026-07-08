---
title: Timeline scrubbing & previews
sidebar_label: Timeline scrubbing
slug: /playback/scrubbing
---

# Timeline scrubbing & previews

When you drag along the timeline to find a moment in recorded footage, Crumb
shows a small preview image that updates as you move, so you can spot the right
frame without playing through everything. It works the same in the desktop app,
the mobile apps, and the web console.

## It just works, and gets faster as you go

You don't have to turn anything on. The first time you drag to a spot, Crumb
grabs a preview frame from the recording; after that, that spot is remembered,
so dragging back and forth over a region you've already looked at is instant.
Scrubbing a whole wall of cameras at the same moment works the same way.

This smoothness is the reason Crumb records its own footage instead of reading a
detector's recordings; if you run Frigate, see [why Crumb records its own
footage](/integrations/frigate#why-crumb-records-its-own-footage-and-doesnt-read-frigates).

Two optional settings can make it even better on larger systems. Most people
never need either one.

## Make the *first* drag instant too (background previews)

By default, the very first time you scrub to a brand-new spot, Crumb builds that
preview on the spot, a brief moment of work before the image appears. If you'd
rather have previews ready in advance so even the first drag is instant, turn on
background pre-generation. Crumb then quietly builds previews for recent footage
as it records.

The trade-off is honest: it uses some ongoing CPU and a little disk space
whether or not you scrub much, which is why it's off by default (a small box
shouldn't do work nobody asked for). Turn it on if you review footage often and
want it to feel instant everywhere.

In your `.env`:

```bash
THUMB_PREGEN_ENABLED=true
```

Then apply it:

```bash
docker compose up -d api
```

The fine-tuning knobs (how far back to build, how often, what size) are in the
[environment reference](/configuration/environment-reference); the defaults are
sensible.

## Keep it snappy on a busy hard-drive system (put previews on an SSD)

Previews are tiny images, and on most setups it makes no difference where they
live. But if you run **a lot of cameras for weeks on a regular spinning hard
drive**, reading all those small scattered files can get slow, exactly when
you're trying to scrub. If you have a spare SSD or NVMe drive, point the preview
cache at it so scrubbing stays snappy while your footage stays on the big, cheap
drive.

This is completely safe. Previews are just cached copies of frames Crumb can
always rebuild. If that SSD fills up, fails, or you wipe it, no footage is lost:
Crumb regenerates previews from the recordings as needed.

1. Mount the fast drive into the `api` container (a compose volume, for example
   at `/mnt/thumbs`).
2. In your `.env`:

   ```bash
   THUMB_CACHE_DIR=/mnt/thumbs
   ```

3. Apply it:

   ```bash
   docker compose up -d api
   ```

## You don't have to manage the cache

Crumb keeps the preview cache from growing forever on its own: once it passes a
size or age limit, the oldest previews are dropped, and any preview that's
missing is simply rebuilt the next time it's needed. If you ever want to change
those limits, they're in the [environment reference](/configuration/environment-reference).
