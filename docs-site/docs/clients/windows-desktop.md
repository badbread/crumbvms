---
title: Windows desktop
sidebar_label: Windows desktop
slug: /clients/windows-desktop
---

# Windows desktop

**Requires:** Windows 10 or 11 (64-bit). Nothing else to install first. The
desktop client is a native Flutter app that renders video through libmpv,
bundled in the zip alongside the exe, so there's no separate runtime to set up.
It does embed a small admin-console pane using the Windows WebView2 runtime,
which ships with Windows 11 and is already present on most Windows 10 machines;
if it's missing, that one pane just opens in your default browser instead and
nothing else changes.

1. On the Releases page, download `CrumbVMS-windows-<version>.zip`. libmpv and
   everything else the app needs are inside it, so there's no separate file to
   manage.
2. Unzip it anywhere, keeping the files together: `crumb_desktop.exe` needs
   `libmpv-2.dll` and the `data/` folder next to it. Run `crumb_desktop.exe`.
   Windows SmartScreen will warn about an unrecognized app, it's unsigned during
   the alpha: click "More info" then "Run anyway."
3. Optionally right-click `crumb_desktop.exe` to pin it to Start or the taskbar.
4. Use "Find my server" or enter `http://<server-host>:8080`, then log in.

Updating is unzipping the newer release over the top, or into a fresh folder.

## What you can do here

This is one of the two clients I drive every day, so it's the most complete.
Live wall with per-camera stream quality including a Data-saver tier (a
low-bitrate transcode, marked with an "SD" chip on the tile), timeline
playback, clips and export, per-camera PTZ controls, the LPR license-plate
reads tab with plate crops and watchlist search, and a Home Assistant entity
overlay that paints your linked sensor and control states on top of the live
video, and lets you operate a linked Control entity right from its badge. See
[the client feature rundown](/clients/#what-each-client-can-do) for how this
compares to the other clients.

## Design your own views

![The desktop client's view setup screen: a list of saved views on the left with
a name field, grid presets, column and row steppers, and draggable special tiles
for carousel, hotspot, image, clock, text, detections and web, next to a live
preview of a seven-box layout with one large camera, three stacked tiles, and a
tile marked hotspot with auto-follow.](/img/screenshots/custom-view-designer.png)

A view is a saved layout of the live wall. Start from a preset (2x2, 3x3, 1+5,
1+7, Hero) or set the column and row counts yourself, then hold Shift to merge
and split boxes into the shape you want. Drop a camera into a box, or drag one
of the special tiles onto it:

- **Carousel**, a box that cycles through a set of cameras.
- **Hotspot**, a box that follows the most recently active camera on its own.
- **Image**, **Clock**, and **Text**, for a logo, a wall clock, or a label.
- **Detections**, a running feed of recent detection events.
- **Web**, an embedded web pane.

Name the view and give it an emoji, and it saves to the server against your
account, so the same views are there when you sign in from another machine.
Creating or editing one needs the `manage_views` capability. Two things stay
local to the machine you are on: the order the views are listed in, and which
one you star as the view that opens on launch. The same screen is where you
rename or delete views you already have.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Video panes black | `libmpv-2.dll` isn't next to `crumb_desktop.exe`; re-unzip the release rather than moving the exe out on its own. |
| "Windows protected your PC" | SmartScreen on the unsigned alpha build; click "More info" then "Run anyway." |
| Connects, lists cameras, live panes stay black | The server's RTSP address isn't set; see [Server settings](/configuration/server-settings). |
