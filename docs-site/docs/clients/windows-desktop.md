---
title: Windows desktop
sidebar_label: Windows desktop
slug: /clients/windows-desktop
---

# Windows desktop

**Requires:** Windows 10 or 11 (64-bit). Nothing else to install first. The
desktop client is a native Flutter app that renders video through libmpv,
bundled inside the installer, so there's no separate runtime to set up. It does
embed a small admin-console pane using the Windows WebView2 runtime, which
ships with Windows 11 and is already present on most Windows 10 machines; if
it's missing, that one pane just opens in your default browser instead and
nothing else changes.

1. On the Releases page, download `CrumbVMS_<version>_x64-setup.exe`. libmpv
   and everything else the app needs are bundled inside it, so there's no
   separate file to manage.
2. Run the installer. Windows SmartScreen will warn about an unrecognized
   app, it's unsigned during the alpha: click "More info" then "Run
   anyway," then install.
3. Launch Crumb from the Start Menu.
4. Use "Find my server" or enter `http://<server-host>:8080`, then log in.

Updating is running the newer installer over the top.

## What you can do here

This is one of the two clients I drive every day, so it's the most complete.
Live wall with per-camera stream quality including a Data-saver tier (a
low-bitrate transcode, marked with an "SD" chip on the tile), timeline
playback, clips and export, per-camera PTZ controls, the LPR license-plate
reads tab with plate crops and watchlist search, and a Home Assistant entity
overlay that paints your linked sensor and control states on top of the live
video. See [the client feature rundown](/clients/#what-each-client-can-do) for
how this compares to the other clients.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Video panes black | The bundled libmpv isn't next to the executable; reinstall rather than copying the exe by hand. |
| "Windows protected your PC" | SmartScreen on the unsigned alpha build; click "More info" then "Run anyway." |
| Connects, lists cameras, live panes stay black | The server's RTSP address isn't set; see [Server settings](/configuration/server-settings). |
