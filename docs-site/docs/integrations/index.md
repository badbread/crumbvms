---
title: Integrations
sidebar_label: Overview
slug: /integrations/
---

# Integrations

Crumb is deliberately narrow in scope: it records, plays back, and gives
you an operator's console for your cameras. It does not run its own object
detection, and it doesn't try to be a general home-automation hub. Where a
job is better done by dedicated, already-excellent software, Crumb's approach
is to sit next to that software rather than rebuild it. The one place Crumb
does run its own recognition is license plates, and even there it's opt-in
and can defer to Frigate instead (see below).

## Object detection

If you already run (or want to run) an object detector, Crumb can consume
its detections and show them as icons on the same timeline as pixel
motion, distinguishing a person from a car from a package at a glance,
with no object detection running inside Crumb itself. See
[Object detection](/integrations/frigate) for how the integration works
and what it requires.

## License plates

Crumb can keep a searchable database of the plates it sees, alert you on a
watchlist, and hold a crop of each read. You choose per camera which engine
does the reading: Frigate's native LPR on the event stream, or Crumb's own
opt-in local OCR worker (`crumb-alpr`, CPU-only, no cloud), or both side by
side with a built-in A/B benchmark. It's off by default. See
[License plates (LPR)](/integrations/lpr).

## Home Assistant

If you run Home Assistant, Crumb can connect to it (a base URL plus a
long-lived access token, ideally from a dedicated non-admin HA user) so you
can link a camera to its HA `binary_sensor`s and controls, use those sensors
as a recording trigger, and drag entity badges onto the live video (in the
desktop app) for at-a-glance state next to the picture. Badges show state;
control is not shipped yet. It's REST-only, reads state from your own HA, and
sends no footage anywhere. You configure it in the console under Detection &
clips (the same panel as Frigate), where it stays dormant until you enable
it; a `HA_BASE_URL` / `HA_TOKEN_FILE` env fallback exists for headless setups
but the console value wins. Off by default, like every integration here. See
[Home Assistant](/integrations/home-assistant).

## Every integration is bring-your-own

Nothing in this section is bundled with Crumb, and nothing here is
required for Crumb to work. Every integration point is off by default,
opt-in, and has a fully self-hosted path, consistent with the project's
no-mandatory-cloud-services stance in general.
