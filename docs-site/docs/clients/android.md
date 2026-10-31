---
title: Android
sidebar_label: Android
slug: /clients/android
---

# Android

**Requires:** Android 8.0 or newer.

1. On the Releases page, download `app-release.apk`.
2. Your browser or Files app will ask permission to install unknown apps.
   Allow it for that app (Settings → Apps → the app → Install unknown
   apps). This is normal for any app not distributed through the Play
   Store.
3. Open the downloaded `.apk` and tap Install.
4. Launch Crumb, then tap "Find my server" (scans your Wi-Fi network) or
   "Enter manually" and type `http://<server-host>:8080`. Log in.

## What you can do here

Android is the other client I use daily, so it's close to feature-complete.
Live wall, timeline playback with an Auto / Full / Data-saver quality control
(Data-saver plays a 640p transcode and shows an "SD" badge; Auto uses full
quality on Wi-Fi and Data-saver on a metered connection), clips and export
(mark an in and an out point on the timeline, then export that window straight
from playback, with second-accurate start and end times and a Cancel button
while the job runs),
per-camera PTZ, a snapshot button (single-camera views), the LPR license-plate
reads tab, and Home Assistant: on-video badges plus a per-camera entity sheet,
both able to operate a linked Control entity directly, not just show its
state. See
[the client feature rundown](/clients/#what-each-client-can-do) for how this
compares to the other clients.

## The LPR tab

The LPR tab is a calm list of license-plate reads. At the top there is just a search bar; the
filter button beside it opens one sheet with cameras, time range, "ends at", exact or fuzzy
match, how to view the list (List, Gallery, or Grouped by plate), **Hide regulars** and
**Merge duplicates**. A small strip of chips appears under the search bar only while a filter
is off its default, and tapping a chip clears it. Hide regulars drops plates seen often in the
last 30 days; plates on your watchlist always show. In landscape the search bar sits next to the
tabs.

Each row shows the plate crop at its real shape, the plate, its name if you gave it one (long
names scroll), and the camera, time and confidence. Tap a row to open the plate's page. Press and
hold for a larger look and quick actions: copy the plate, watch it, correct a misread, make a PDF
report, or open the moment in Playback. Watching, ignoring, naming and correcting plates are for
admins; everyone with the **View license plates** permission can copy, report and play back.

The plate page keeps the video of the sighting pinned at the top, with play and pause, 10 second
skips, a scrubber, mute, pinch to zoom and a bookmark button. Under it, **Visits** lists each time
the plate showed up (tap one to play it), **History** shows the hours of the day it is usually
seen, which cameras see it and the last 30 days (tap a bar for its number), and **Details** holds
the name, watchlist state, known misreads (with Undo) and **Correct plate**. In landscape the
video sits on the left and the tabs on the right. Hide regulars and the history need a server
that has the plate-history endpoint; on an older server they are simply not shown.

## Verifying the download (optional but recommended)

The APK is signed with the project's release keystore in CI, but it isn't
distributed through the Play Store, so no store vouches for the download
itself. Each release therefore also publishes an `app-release.apk.sha256`
checksum file next to the APK. Download both into the same folder and confirm they match
before installing:

```bash
sha256sum -c app-release.apk.sha256   # Linux/macOS; prints "OK"
```

```powershell
# Windows PowerShell:
(Get-FileHash app-release.apk -Algorithm SHA256).Hash -eq `
  (Get-Content app-release.apk.sha256).Split(' ')[0].Trim()
```

## Updating

Crumb isn't on the Play Store during the alpha, so updating means
downloading the newer APK and installing it over the top. Your saved views
and settings are kept.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Find my server" finds nothing | Wi-Fi client isolation (common on guest networks) blocks device-to-device traffic; enter the address manually instead. |
| Connects, lists cameras, live panes stay black | The server's RTSP address isn't set; ask your admin to set it under Server & streaming. |
| "App not installed" | A different build signed with a different key is already installed; uninstall the old one first. This shouldn't happen for a normal update of the same alpha build. |
