---
title: iOS
sidebar_label: iOS
slug: /clients/ios
---

# iOS

**Requires:** iOS 16 or newer.

**Status: built and working, but not yet distributable.** The iOS app runs
today, it shares its codebase with the macOS app, but there is no tester
path yet. Apple doesn't allow sideloading a build onto someone else's
iPhone the way Android does; the only route to alpha testers is
TestFlight, which requires the paid Apple Developer Program that hasn't
been set up yet. Until then, iOS is "works on the maintainer's phone," not
something you can install.

Once TestFlight is set up, this becomes: install the TestFlight app from
the App Store, open your invite, tap Install, then point the app at your
server (Find my server, or enter `http://<server-host>:8080`). TestFlight
handles updates automatically from there.

## What it can do

Because it shares the macOS SwiftUI codebase, the feature set matches the Apple
desktop app: live view, timeline playback, clips, export, bookmarks, and motion
tuning. The newer surfaces I've built on the Windows desktop and Android clients
are not in the Apple app yet: no LPR license-plate tab, no Home Assistant
overlay, and no Data-saver quality tier. See
[the client feature rundown](/clients/#what-each-client-can-do) for the full
comparison.
