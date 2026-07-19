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
quality on Wi-Fi and Data-saver on a metered connection), clips and export,
per-camera PTZ, a snapshot button (single-camera views), the LPR license-plate
reads tab, and a read-only Home Assistant entity sheet per camera. See
[the client feature rundown](/clients/#what-each-client-can-do) for how this
compares to the other clients.

## Verifying the download (optional but recommended)

Since the alpha APK isn't distributed through a code-signing or Play Store
channel, each release also publishes an `app-release.apk.sha256` checksum file
next to the APK. Download both into the same folder and confirm they match
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
