---
title: macOS
sidebar_label: macOS
slug: /clients/macos
---

# macOS

**Requires:** macOS 13 (Ventura) or newer, Apple silicon or Intel.

1. On the Releases page, download `CrumbVMS-macos-<version>.zip`.
2. Unzip it and drag `CrumbVMS.app` to Applications.
3. First launch: right-click (or Control-click) `CrumbVMS.app`, choose
   Open, then Open again. This is required because the app isn't notarized
   during the alpha, a normal double-click gets blocked by Gatekeeper with
   "cannot be opened." You only need the right-click-Open once.
4. Use "Find my server" or enter `http://<server-host>:8080`, then log in.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "CrumbVMS can't be opened" | Gatekeeper on the un-notarized alpha build; right-click, then Open, the first time. |
| Connects, lists cameras, live panes stay black | The server's RTSP address isn't set; see [Server settings](/configuration/server-settings). |
