---
title: Linux desktop
sidebar_label: Linux desktop
slug: /clients/linux-desktop
---

# Linux desktop

There's no prebuilt Linux artifact yet. Build the desktop client from
source on a machine with Rust, Node, and GTK/mpv development libraries
installed, see the desktop app's source under `apps/desktop` in the
repository for the build steps.

The client uses Wayland-native rendering for video where available; a
software-GL fallback works on other setups but uses more memory.

Once built, it connects to a server the same way every other native client
does: "Find my server" or entering `http://<server-host>:8080` by hand,
then signing in. See [Clients overview](/clients/) for the shared
connection steps.
