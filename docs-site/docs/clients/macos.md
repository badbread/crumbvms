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

1. On the Releases page, download `CrumbVMS-macos-<version>.zip`.
2. Unzip it and drag `CrumbVMS.app` to Applications.
3. First launch: right-click (or Control-click) `CrumbVMS.app`, choose
   Open, then Open again. This is required because the app isn't notarized
   during the alpha, a normal double-click gets blocked by Gatekeeper with
   "cannot be opened." You only need the right-click-Open once.
4. Use "Find my server" or enter `http://<server-host>:8080`, then log in.

## What you can do here

Live view, timeline playback, clips, export, bookmarks, and motion tuning. The
newer surfaces I've built on the Windows desktop and Android clients are not in
the Apple app yet: no LPR license-plate tab, no Home Assistant overlay, and no
Data-saver quality tier. See
[the client feature rundown](/clients/#what-each-client-can-do) if a specific
feature is what you're after.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "CrumbVMS can't be opened" | Gatekeeper on the un-notarized alpha build; right-click, then Open, the first time. |
| Connects, lists cameras, live panes stay black | The server's RTSP address isn't set; see [Server settings](/configuration/server-settings). |
