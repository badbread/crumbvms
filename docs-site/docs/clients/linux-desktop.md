---
title: Linux desktop
sidebar_label: Linux desktop
slug: /clients/linux-desktop
---

# Linux desktop

There's no prebuilt Linux artifact, and I want to be honest: Linux is the
least-proven target right now. The desktop client is a native Flutter app (a
Flutter shell plus a Rust core over FFI, with video through `media_kit`/libmpv),
and while it's the daily driver on Windows, the Flutter Linux runner hasn't been
built or exercised end to end yet. Treat a Linux build as "you may be the first
person to get it running," not a supported path.

If you want to attempt it, build from source under `apps/desktop-flutter/` on a
machine with the Flutter SDK, the Rust toolchain (the client keeps a Rust core
via `flutter_rust_bridge`), and libmpv development libraries installed. See that
directory in the repository for the current build steps.

Once built, it connects to a server the same way every other native client
does: "Find my server" or entering `http://<server-host>:8080` by hand,
then signing in. See [Clients overview](/clients/) for the shared
connection steps.

If all you need is live view and playback, the
[web console](/clients/web-console) runs in any Linux browser with nothing to
build.
