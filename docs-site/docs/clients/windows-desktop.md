---
title: Windows desktop
sidebar_label: Windows desktop
slug: /clients/windows-desktop
---

# Windows desktop

**Requires:** Windows 10 or 11 (64-bit). The
[WebView2 runtime](https://developer.microsoft.com/microsoft-edge/webview2/),
preinstalled on Windows 11; on Windows 10 the app prompts to install it if
missing.

1. On the Releases page, download `CrumbVMS_<version>_x64-setup.exe`. The
   video library is bundled inside it, so there's no separate file to
   manage. An `.msi` is also provided if you prefer that format.
2. Run the installer. Windows SmartScreen will warn about an unrecognized
   app, it's unsigned during the alpha: click "More info" then "Run
   anyway," then install.
3. Launch Crumb from the Start Menu.
4. Use "Find my server" or enter `http://<server-host>:8080`, then log in.

Updating is running the newer installer over the top.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Video panes black | The bundled video library isn't next to the executable; reinstall rather than copying the exe by hand. |
| "Windows protected your PC" | SmartScreen on the unsigned alpha build; click "More info" then "Run anyway." |
| Connects, lists cameras, live panes stay black | The server's RTSP address isn't set; see [Server settings](/configuration/server-settings). |
