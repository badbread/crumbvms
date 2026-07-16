---
title: Integrations
sidebar_label: Overview
slug: /integrations/
---

# Integrations

Crumb is deliberately narrow in scope: it records, plays back, and gives
you an operator's console for your cameras. It does not run object
detection itself, and it doesn't try to be a general home-automation hub.
Where a job is better done by dedicated, already-excellent software,
Crumb's approach is to sit next to that software rather than rebuild it.

## Object detection

If you already run (or want to run) an object detector, Crumb can consume
its detections and show them as icons on the same timeline as pixel
motion, distinguishing a person from a car from a package at a glance,
with no detection running inside Crumb itself. See
[Object detection](/integrations/frigate) for how the integration works
and what it requires.

## Home Assistant

If you run Home Assistant, Crumb can connect to it (a base URL plus a
long-lived access token, ideally from a dedicated non-admin HA user) so you
can link cameras to HA entities and drag entity badges, a door, a lock, a
temperature or motion sensor, onto the live video for at-a-glance state next
to the picture. It's REST-only, reads state from your own HA, and sends no
footage anywhere. You configure it in the console under Detection & clips
(the same panel as Frigate), where it stays dormant until you enable it; a
`HA_BASE_URL` / `HA_TOKEN_FILE` env fallback exists for headless setups but
the console value wins. Off by default, like every integration here.

## Every integration is bring-your-own

Nothing in this section is bundled with Crumb, and nothing here is
required for Crumb to work. Every integration point is off by default,
opt-in, and has a fully self-hosted path, consistent with the project's
no-mandatory-cloud-services stance in general.
