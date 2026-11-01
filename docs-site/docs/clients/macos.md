---
title: macOS
sidebar_label: macOS
slug: /clients/macos
---

# macOS

**Requires:** macOS 13 (Ventura) or newer, Apple silicon or Intel.

The macOS app is a native SwiftUI client that shares its codebase with the iOS
app. It's a different app from the Windows/Linux desktop client, and I keep it
current on the core watch-and-review path rather than driving it daily, so it's
a bit rougher.

**Not fully tested in 0.3.0.** The macOS app builds and passes its automated
tests against this release, but it has not had the hands-on testing the
Windows and Android clients got, and it does not have most of 0.3.0's new
desktop and Android features. Server-side changes (camera order, plate
corrections, searching plates by name) do reach it. Please report anything that
breaks.

1. On the Releases page, download `CrumbVMS-macos-<version>.zip`.
2. Unzip it and drag `Crumb.app` to Applications.
3. First launch: right-click (or Control-click) `Crumb.app`, choose
   Open, then Open again. This is required because the app isn't signed or
   notarized during the alpha, a normal double-click gets blocked by Gatekeeper
   with "cannot be opened." You only need to do this once. On macOS 15
   (Sequoia) and newer, right-click Open no longer offers the bypass: try to
   open the app once, then go to System Settings, Privacy & Security, and click
   Open Anyway.
4. Use "Find my server" or enter `http://<server-host>:8080`, then log in.

## What you can do here

Live view, timeline playback, clips, export, bookmarks, motion tuning, PTZ,
an Auto / Full / Data saver quality control, an LPR tab (a list or gallery of
plate reads with watchlist and plate names), and Home Assistant, on-video
badges plus tap-to-actuate control for a linked Control entity. The newer
surfaces I've built on the Windows desktop and Android clients are not in the
Apple app yet, for example the redesigned license-plate page (a page per plate
with its history, and correcting a misread) and one-second scrub previews. See
[the client feature rundown](/clients/#what-each-client-can-do) if a specific
feature is what you're after.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Crumb can't be opened" | Gatekeeper on the un-notarized alpha build; right-click, then Open, the first time (on macOS 15 or newer: System Settings, Privacy & Security, Open Anyway). |
| Finished exports won't download | A Mac app from 0.2.0 can't download exports from a 0.3.0 server. Update the Mac app along with the server; until then, download finished exports from the web console. |
| Connects, lists cameras, live panes stay black | The server's RTSP address isn't set; see [Server settings](/configuration/server-settings). |
