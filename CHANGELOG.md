# Changelog

All notable changes to CrumbVMS, kept for the people testing it. This project is
one maintainer working in the open; the pace below is what "90% of the way to v1"
looks like from the inside. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); dates are the day a change
landed on `main`.

Crumb is **alpha**. Versions before 1.0 make no compatibility promises, read the
[Alpha Tester Terms](docs/ALPHA-TESTER-TERMS.md) before you rely on it.

## [0.2.0] - UNRELEASED

Where 0.1.1 hardened what was already there, 0.2.0 finishes a feature that had
been half-built for two releases: Home Assistant. Crumb could show a linked
entity's state on the live wall, but you could not do anything with it, and
authoring those links was a thin, awkward surface. This cycle rebuilt the
authoring layer end to end and made the badges interactive: tap a light to turn
it on, drag a slider to dim it, read a sensor's real value and units off the
frame. The other headline items are adaptive live-wall quality on every client
and human-readable plate names in LPR. Later in the cycle three more landed:
a camera whose main stream a phone cannot decode now gets a fast, on-demand HD
repair instead of a permanent SD fallback, the console's notifications surface
was redesigned around named channels, and LPR plates gained real tooling, copy
a plate, name it, and pull a report that lists every sighting.

The back half of the cycle was a different kind of work. Two audit sweeps went
looking for the class of bug where Crumb looks healthy and is not: an install
whose media directory the recorder cannot write, a motion detector that picked a
GPU that was never there, a camera whose stream go2rtc rejected while the console
said it was added. Those are the fixes below that matter most, because none of
them announced themselves.

### The Home Assistant overhaul

- **Authoring got a real home.** Home Assistant is now its own area in the admin
  console instead of a scattering of per-camera fields (#458), including
  orphaned-entity detection that flags a link whose entity no longer exists. The
  entity picker was widened from a narrow allow-list to every controllable
  domain plus numeric sensors (#448), and each linked entity now carries an
  editable role, device_class, and label (#453), validated against the entity's
  real domain (#452).
- **One icon vocabulary.** Badges used to drift between clients because each
  mapped icons on its own; there is now a single canonical closed icon set,
  enforced server-side and mapped identically on desktop, Android, and iOS
  (#455, #447), with numeric sensor units rendered on the badge and detail card
  (#454).
- **Per-entity control config.** A link can require a confirmation tap before it
  actuates and can restrict which actions it exposes (#456), authored from the
  same console link editor that sets its icon and style (#457).
- **The icon vocabulary grew by 23 slugs**, grill and smoker and landscape
  lighting among them, added in genuine lockstep across the server validator, the
  console, and all three clients (#482).
- **Badges can be styled per state.** A link can carry a second background colour
  used only while the entity is on (#493, migration 0076), authored in the
  console with an on/off preview (#490) and rendered on desktop (#491), iOS
  (#492), and Android (#489). Left unset, a placed badge looks exactly as it did
  before.
- **Pill geometry is authorable.** Badge width (auto, narrow, medium, wide, sized
  as multiples of the pill's own height so all four renderers derive it
  identically) and text alignment are now per-link settings (#534, migration
  0078). Unset again means no change to a badge you have already placed. Android
  pill labels also stopped overflowing their background, by measuring at the same
  clamped font size they render at (#499).
- **The desktop overlay editor was restructured** around a sticky top bar and a
  badge-anchored popover, because the old floating panel covered the badge you
  were editing (#495). Esc and ✕ are now cancel rather than an implicit save; an
  edited session asks before it discards.
- **A quick-toggle hides the on-video overlays** without unlinking anything:
  desktop covers the wall and the maximized pane and binds it to `H` (#487), iOS
  and Android cover fullscreen live (#486, #488). On Android, hiding also stands
  the Home Assistant poll down.
- Console link-picker labels now say what they add, and the stale "Motion tab"
  copy is gone (#481).

### Interactive badges

- **Device control shipped on all four surfaces.** A default-off actuators
  capability gates a new control endpoint (#427); the on-video badge card gained
  actuator buttons on desktop (#426), iOS (#425), and Android, and the
  interaction model settled on a direct tap: a single tap actuates a simple
  device such as a light or a switch, and only cover- or lock-type entities open
  a card first (#429, #430, #431).
- **Value controls.** Dimmable lights, covers, and fans get a slider for
  brightness, position, and speed, wired through a new value-setting control on
  the server (#460) and surfaced on desktop (#461), iOS (#462), and Android
  (#463), with the detail card's icon color matched to the badge (#466, #467,
  #468).
- **A control never claims a state it did not set.** The iOS value slider holds
  at the value you committed until the poll agrees or a timeout elapses, instead
  of snapping back mid-drag (#474), and a slider release that is cancelled at the
  confirmation prompt or whose request fails now returns the thumb to the real
  value rather than stranding it (#508). On a cover, the old behaviour could read
  80% while the cover sat at 20%. In the same spirit, an iOS light or switch
  reporting `unavailable` or `unknown` greys out like every other domain instead
  of rendering a confident "Off" (#538).

### An install that cannot silently record nothing

- **Storage is preflighted before the stack ever starts.** `scripts/setup-env.sh`
  now names the media directory's filesystem, actually tries to create a file
  there as uid 1001 (the user the recorder runs as), warns when free space is
  under 10 GiB, and prints the server-side fix for NFS, SMB, FUSE and the other
  mounts that remap ownership. A definite failure ends the script with a non-zero
  exit instead of letting you bring up a stack that records nothing while live
  view, which touches no disk, looks perfectly healthy (#514). An inconclusive
  answer still lets the install proceed and tells you what to check by hand.
- **Hardware decode stopped guessing.** `MOTION_HWACCEL` now defaults to `cpu`
  (#478 in the shipped config, #513 in the code and image defaults), because the
  old `auto` only asked whether cuda was compiled into ffmpeg, which is true on
  every host running the published image. On a GPU-less machine that meant every
  motion decoder died before its first frame, forever. `auto` now probes a real
  cuda device once at runtime and resolves to CPU when the probe fails, times
  out, or cannot start, and any backend that produces no frames is demoted to CPU
  for that camera instead of relaunching the same failing flags (#531). The
  reason is reported in decode status and motion health rather than left for you
  to infer.
- **The console stopped re-pinning a decode backend you never chose.** Saving any
  unrelated server setting used to coerce a blank hardware-decode field to
  `auto`, quietly undoing the new default; blank now stays blank and means
  "inherit the environment" (#536).
- **A migration interrupted between apply and record no longer bricks the boot.**
  Five already-shipped migrations used a bare `ADD CONSTRAINT`, so a boot killed
  at the wrong moment re-ran the file into a duplicate-object error and neither
  api nor recorder would start until the database was edited by hand. They are
  re-appliable now, with a test that fails the build if a new migration
  reintroduces the pattern (#513).
- **First-run errors say what actually went wrong** (#532). The Home Assistant
  and Frigate connection tests check the shape of the response instead of
  accepting any 200, so a login page no longer reports Connected. The storage
  check can finally tell read-only from healthy, which it could not before
  because the api mounts media read-only and its write probe therefore always
  failed. Saving a storage path that does not exist or cannot be written is
  refused rather than accepted in silence. A wrong password says so instead of
  "Session expired", a rate-limited request surfaces its retry window, and
  ffmpeg's stderr is mapped to something readable with credentials redacted.

### Recorder correctness

Losing footage is the one unforgivable bug, so these two get their own heading.

- **Reconcile can no longer wipe a storage's segment index when the disk is not
  there.** The dangling-row pass deleted an index row whenever the file did not
  stat, with nothing checking that the storage root was the real, mounted volume.
  A present-but-empty root, an unmounted `noauto` disk, a dropped network mount, a
  bind source Docker created for you, made every row look dangling, and one pass
  could delete that storage's entire index. The bytes survived; the motion flags,
  bounding boxes, durations, and clip and bookmark links did not. Two independent
  guards now fail toward doing nothing: a marker file at the storage root, without
  which the pass deletes nothing at all, and a per-storage circuit breaker that
  latches when a single pass finds both more than 100 missing files and more than
  half the rows missing (#515).
- **The marker is written only after real footage lands.** As first shipped, the
  recording path planted it as soon as the directory was created, which on the
  exact failure the guard exists for wrote a false confirmation onto an empty
  mountpoint. It now goes down on the first genuinely committed segment, the same
  signal the boot-time seeding uses (#542).

### HD live on a phone

The 0.2.0 fallback ladder (#529) kept an all-H.265 camera watchable on Android,
but "watchable" often meant the SD sub-stream. This cycle finished the job.

- **The ladder stopped being trigger-happy.** Android used to step down on any
  playback error, including a transient network or IO blip, so a momentary
  hiccup could park a perfectly decodable camera at low resolution. It now steps
  down only on a real, deterministic playback failure (#561).
- **A main the phone's decoder rejects can now be repaired in HD.** An opt-in,
  per-camera, on-demand server-side transcode of the main from H.265 to H.264
  gives the phone an HD stream it can actually play (#591). Detection reads the
  SDP go2rtc actually serves to clients rather than the camera's own producer
  SDP, so a camera that advertises `fmtp` but has it dropped downstream, the
  reference Uniview LPR among them (its `fmtp` is missing sprop-vps), is
  correctly flagged and repaired (#592). The client reaches for the repaired
  main first, so fullscreen starts fast instead of stalling on the doomed raw
  main (#594). The Uniview LPR compatibility entry was sharpened to that precise
  root cause (#596).

### Notifications, redesigned

- **The console Notifications pane was rebuilt** around named channels, an
  inline alert-text editor, and quiet hours (#583, migrations 0079 and 0080).
- **Alert text is yours to write.** Every system-alert type's text is
  customizable, so the message that reaches your phone can say what you would
  have said (#568).
- **Snapshots are chosen per channel.** Each channel carries its own snapshot
  mode, none, plate, vehicle, or both, gated on what that channel can actually
  deliver (#572).

### Added

- **Adaptive live-wall quality** on every client: the wall steps stream quality
  down under thermal or decode pressure and back up when it clears, so a busy
  wall degrades gracefully instead of stuttering (Android #422, Apple #423,
  desktop #424).
- **Human-readable plate names in LPR.** A plate you have named shows that name
  wherever the plate appears (reads, watchlist, and detail), with the raw plate
  still legible underneath (#418, and the clients #419, #420, #421).
- **Plate tooling that treats a plate as a thing you work with.** Copy a plate
  number to the clipboard from the web console and Android (#549), iOS (#548),
  and desktop (#551), and name a plate straight from the Plates tab, distinct
  from watchlisting it (#548, #551). The plate report grew up too: desktop
  previews it in-app with real options, including listing every occurrence
  (#554), and Android can Open it, Save it to Downloads, or Share it (#563), and
  now lists every sighting rather than only the capped thumbnails (#565). Engine
  Benchmark plate crops decode via the engine codec instead of pure Dart, for
  speed (#545).
- **A timeline toggle that solos the selected camera's motion** on desktop, so
  one camera's activity stays legible against everything else's (#574).
- An **admin-only scrubbed diagnostics bundle** on the server, the counterpart
  to the desktop diagnostics added in 0.1.1 (#385).
- **Motion-detector-down** state is now surfaced in decode-status and the admin
  console, and the recorder alerts when a detector is broken from startup rather
  than failing silently (#415, #413).
- An opt-out for the go2rtc RTSP restream's auth (`GO2RTC_AUTH=off`) for setups
  that terminate access control elsewhere (#417).
- A **`camera_stream_rejected` alert** (#528, migration 0077), raised when go2rtc
  refuses a camera's stream. It is on by default, ignores quiet hours, and
  latches so one bad URL cannot spam the channel.
- **`TESTING.md`**, a tester onboarding guide, plus a structured bug-report issue
  form so a report arrives with the version, platform, and logs already in it
  (#512).

### Changed

- **Digital-zoom ceilings raised** and aligned across clients: Android playback
  to 10x (#405), iOS and desktop to 30x (#408), plus trackpad pinch-to-zoom on
  desktop laptops (#410).
- Media tokens minted by an older client are no longer rejected after an
  upgrade: the server fills in default capability claims instead (#407), which
  retires the post-upgrade blank-thumbnail window that 0.1.1 listed as a known
  issue.
- **`MOTION_HWACCEL` defaults to `cpu` on a new install** (#478, #513). An `.env`
  written by 0.1.1 pins the value explicitly, so upgrading does not change your
  setting; see "Upgrading from 0.1.1" below.
- **`PUT /config/server` merges instead of replacing.** A partial body used to
  clear every setting it did not mention. Omitted fields are now left alone and
  an empty string clears a field back to its environment default (#533). The
  console always sent complete bodies, so this is a fix for anything driving the
  API directly.
- **The first-run wizard no longer assigns cameras to a group.** The step existed
  and worked, but groups are authoritative for policy and the wizard was the one
  place you could set one without seeing what it inherited; it now happens in the
  console, where the inheritance is visible (#510).
- **Desktop `Esc` is scoped.** With the keyboard shortcuts actually reaching the
  app again (#494, #496), `Esc` deliberately does not fire while a text field has
  focus or a dialog is open.
- **The camera editor's Home Assistant entity entry is mode-aware** instead of
  one field pretending to fit every case (#579).
- **The Server dashboard reads more honestly.** Retention is shown in days
  rather than hours, policy-source labels say where a value actually comes from,
  and the Cameras tab scrolls (#581); long lists collapse by default so the page
  stays navigable on a big install (#589).
- **`docs/AI-INSTALL.md` was brought back in sync** with the current compose
  files and scripts, so the runbook once again matches what a fresh install
  actually does (#577).

### Fixed

- Android keeps the playhead where you scrubbed even when it lands in a gap
  (#406), holds digital zoom across motion-segment boundaries (#387), and uses
  the Download glyph for the playback wall's Export action (#389).
- Server discovery no longer prefers a TLS URL the app cannot actually use
  (#403).
- Setup fails early with a clear message when a bind-mounted config file is
  missing, instead of booting into a confusing state (#397).
- Frame-back works in the desktop LPR plate popup (#392), and the A/B report
  carries the plate bounding box so crops line up (#393).
- **A camera go2rtc rejects now tells you.** `PUT` of a stream only failed on a
  5xx, so a 400, which registers nothing, was recorded as success: the camera
  appeared added, no warning, no event, and the recorder reconnect-looped
  forever. Registration is now confirmed by reading the stream back (#528), and
  editing an existing camera's source URL goes through the same path, which it
  did not before (#540). That edit fix also stops a rename leaving an orphaned
  stream behind.
- **No more false "motion detector unhealthy" on a main-only camera.** Motion
  reads the sub-stream, so a camera without one has its pixel detector parked by
  design, but the startup-armed timer alerted about it after every recorder
  restart. That state is still reported as degraded and recording still fails
  open; it just no longer arms an alert (#525). The Detection tab now warns at the
  moment you tick pixel analysis on a camera that has no sub-stream (#527).
- **Android plays cameras that are H.265 all the way down.** Media3's RTSP stack
  cannot bring up H.265, and the old recovery was a single main-to-sub step, which
  on an all-H.265 camera just swapped one undecodable stream for another. There is
  now a fallback ladder ending at the server's on-demand H.264 transcode, ordered
  differently for fullscreen and wall tiles and for metered connections, with the
  transcode always last because it costs a real ffmpeg on the server (#529).
- **Filling in only the Frigate go2rtc field stopped redirecting Frigate's HTTP
  API.** The console was syncing a deprecated column to the go2rtc base, which
  sent every Frigate snapshot and clip proxy at the wrong port; the two fields are
  now one, clearly labelled (#518).
- **The `_subv` repair stream is targeted rather than universal.** The video-only
  sub restream that fixes H.264 SDPs missing their `fmtp` line for Media3 (#485)
  is now registered only for the cameras whose sub-stream is positively detected
  as broken (#501), and the detection is gated on the video codec so MJPEG
  cameras, which have no `fmtp` by specification, are no longer mis-flagged
  forever (#526).
- **Desktop keyboard shortcuts fire again.** They had been inert in shipped
  builds: the handlers sat below a focus node that permanently owned the route's
  focused child, so nothing was ever dispatched to them. The live wall's snapshot,
  maximize, fullscreen, and camera-number banks (#494) and Playback's transport
  and frame-step keys (#496) all work. The maximized pane also keeps its
  right-click menu while a stream is still connecting (#484).
- Server discovery, the console, and the wizard: a `serverTz` crash outside the
  wizard left the schedule panel empty and could persist a cleared archive
  schedule, and Detection Save silently dropped painted zones (#510).
- **The timeline scrubber populates fast on a long history.** Motion intensity
  is bucketed in SQL instead of scanning every row, which had turned the
  scrubber populate into a multi-second wait (#576).
- **Storage seeding no longer creates duplicate ghost rows.** Seeding is
  path-idempotent, with name-to-path lookups, so a re-seed finds the storage it
  already made instead of inventing a twin (#585).
- The motion tuner's sensitivity control no longer errors when switching a
  grouped camera from auto to manual (#587).
- A maximized live camera on desktop stays maximized across minimize and
  restore, instead of quietly returning to the wall (#570).
- **Frigate ingest is no longer dead by default.** The MQTT packet limit was too
  small for Frigate's event payloads; it was raised so events actually arrive
  (#559).
- **Android landscape polish.** The playback back arrow no longer floats in the
  centre of the video, it sits top-left; the quality chip shows "A" instead of a
  truncated "AUT" in the compact landscape bar; and the single-camera view now
  labels which camera is loaded without adding a top bar (#604).
- **The license-plate PDF report no longer runs into its own heading.** The large
  plate number and the date-time line beneath it now have a clear gap (#603).
- **Dropdowns work in the desktop app's embedded console.** The composited webview
  the desktop uses to embed the web console cannot paint a native `<select>`
  popup, so Server-settings dropdowns did nothing there. An embed-only shim now
  renders the options as a DOM list and writes the choice back through the normal
  change event; the browser console is untouched (#608).
- **The Android multi-camera playback wall batches its motion-intensity requests**
  instead of firing one per camera, so scrubbing a large wall no longer trips the
  server's rate limiter, bringing Android in line with desktop and iOS (#607).
- **The install script warns on a small storage disk, not just a nearly-full one,**
  and its next-step hint matches the README's two commands, plus a set of
  install-doc corrections surfaced by a fresh-install audit (#606).

### Security

- **Scoped media tokens can no longer reach the rest of the API.** These are the
  short-lived, narrow claims in `?token=` media URLs. A camera's stream endpoint,
  which hands back RTSP URLs carrying the server's long-lived restreamer
  credentials, sat where a media principal could reach it (#516). Rather than
  patch that endpoint alone, the default was inverted: a media-scoped token is now
  rejected everywhere, and exactly the ten media handlers that need it opt back in
  (#543). A new endpoint is therefore safe by default. No client change was
  needed; all four already authenticate these calls with the bearer session.
- **`/auth` no longer carries the permissive CORS header.** It covered
  unauthenticated bootstrap and login, which had no reason to be reachable
  cross-origin (#516).
- **`mqtts://` is refused instead of silently connecting in plaintext.** Both MQTT
  clients used to strip the scheme and connect in the clear, so an operator who
  configured `mqtts://` had broker credentials on the wire believing they were
  encrypted. TLS is not implemented here; the URL is rejected at configuration
  time, at test time, and at connect time, so the failure is loud (#530).
- **Two footage and snapshot routes were tightened to match the capability
  model.** The filmstrip scrub-thumbnail endpoints now require the `playback`
  capability, like `/timeline`, `/play`, and `/segments`, and the notification
  channel-test path re-checks the owner's current camera grant before it fetches a
  snapshot, the same re-resolve the alert engine already does each tick (#602).
- Dependency work cleared four `rustls-webpki` certificate-verification
  advisories by dropping a transitive TLS stack from the MQTT client and bumping
  rustls (#476).

### Upgrading from 0.1.1

An in-place upgrade from the v0.1.1 published images was tested end to end. It is
a drop-in: `.env` needs no changes, the new migrations apply in a single pass on
first boot, footage came through byte-identical, and logins, roles, policies, and
the authenticated RTSP restream default were all intact afterwards.

```bash
git pull
docker compose pull
docker compose up -d
```

If you pinned `CRUMB_VERSION` in `.env`, set it to the new version before you
pull. If you never set it, you are on `latest` and the pull is enough.

- **Migrations run themselves.** First boot applies 0072 through 0080; there is
  no manual step and no separate downtime beyond the container restart.
- **No new required settings.** `GO2RTC_AUTH` is the only new key, and leaving it
  unset keeps the secure default: the RTSP restream stays authenticated.
- **The redesigned Notifications pane needs nothing from you.** Migrations 0079
  and 0080 are additive; existing notification settings carry over, and the new
  alert-text and per-channel snapshot options sit at their defaults until you
  set them.
- **`MOTION_HWACCEL` needs a decision, but not urgently.** A new install now
  defaults to `cpu`. An `.env` generated by 0.1.1 contains an explicit
  `MOTION_HWACCEL=auto`, so upgrading leaves you on `auto`, and that is fine:
  `auto` no longer picks a GPU that is not there. It probes a real cuda device at
  runtime and falls back to CPU when the probe fails, and a backend that decodes
  nothing is demoted per camera. To adopt the new default anyway, set
  `MOTION_HWACCEL=cpu` in `.env` and `docker compose up -d` the recorder, or leave
  the console's hardware-decode field blank and set it there. If you have a GPU
  you actually want used, name it (`cuda` or `vaapi`) rather than relying on
  `auto`.
- **Non-admin roles cannot control Home Assistant devices** until you grant them
  the new `actuators` capability. Migration 0074 adds it default-off for every
  existing role, so nobody silently gains the ability to unlock a door on upgrade.
  Admins are unaffected.
- **Motion health is a new surface.** Cameras that were quietly degraded before
  will start reporting it. That is the feature working, not the upgrade breaking
  something.
- **Back the database up first** (see `docs/BACKUP.md`), as with any upgrade.
- **Rolling back is reasoned, not tested.** The new migrations are additive, so
  pinning the previous `CRUMB_VERSION` and running `docker compose up -d` should
  bring 0.1.1 back up against the upgraded schema: you lose the new features, not
  the footage. A downgrade was never actually executed, so treat that as an
  argument, not a rehearsal, and take the backup.

### All merged changes

Every pull request merged since 0.1.1, newest first:

- fix(admin): DOM dropdown fallback so selects work in the desktop webview embed (#608)
- fix(android): batch the multi-camera playback-wall timeline intensity (#607)
- fix(install): close the four fresh-install-audit findings (#606)
- ci(release): block a release tag whose versions do not match the tag (#605)
- fix(android): landscape single-camera UI polish (back-arrow, Auto label, camera name) (#604)
- fix(clients): space the plate-report heading off the date-time line (#603)
- fix(api): gate filmstrip on the playback capability; scope channel-test to current grants (#602)
- docs(cameras): sharpen the Uniview LPR compatibility entry to the precise fmtp root cause (#596)
- fix(android): try the repaired main (mainv) before the doomed raw main (#594)
- fix(api): flag the _mainv repair from the SERVED SDP, not the producer (#592)
- fix(android): fast step-down + opt-in HD repair for a main with no fmtp (#591)
- fix(desktop): collapse long Server-dashboard lists by default (#589)
- fix(desktop): gate motion-tuner sensitivity for grouped cameras (#587)
- fix(recorder): path-idempotent storage seeding + name->path lookups (#585)
- feat(notifications): redesign the console Notifications pane (channels, alert-text editor, quiet hours) (#583)
- fix(desktop): retention days unit, accurate policy-source labels, scrollable Cameras tab (#581)
- feat(admin): mode-aware HA entity entry rework in the camera editor (#579)
- docs(install): fix AI-INSTALL drift against current compose and scripts (#577)
- perf(timeline): bucket motion intensity in SQL instead of scanning every row (#576)
- feat(desktop): timeline toggle to solo the selected camera's motion (#574)
- feat(notify): per-channel snapshot mode (none/plate/vehicle/both), capability-gated (#572)
- fix(desktop): keep a maximized live camera maximized across minimize/restore (#570)
- feat(notify): customizable alert text across all system-alert types (#568)
- docs(readme): v0.2.0 release audit touch-ups (#566)
- fix(android): list every plate sighting in the report, not just the capped thumbnails (#565)
- feat(android): offer Open / Save to Downloads / Share for LPR plate reports (#563)
- fix(android): only step down the live fallback ladder on real playback failure (#561)
- fix(frigate): raise the MQTT packet limit so Frigate ingest is not dead by default (#559)
- fix: correct release-prep copy defects and code/compose config drift (#557)
- docs(api): pin the HA placement PUT as a whole-object replace (#555)
- feat(desktop): preview the plate report in-app, and give it real options (#554)
- feat(desktop): copy a plate to the clipboard, and name a plate from the Plates tab (#551)
- feat(lpr): copy the plate number to the clipboard (web console + Android) (#549)
- feat(ios): copy a plate number, and name a plate, from the Plates tab (#548)
- perf(desktop): Engine Benchmark plate crops decode via the engine codec, not pure-Dart (#545)
- docs: bring the release documentation current for v0.2.0 (#544)
- fix(api): gate the credential/session/notification surface against scoped media tokens (#543)
- fix(recorder): write the storage marker only after a committed segment, not at dir creation (#542)
- fix(api): route a camera source-URL edit through reconnect so a go2rtc rejection surfaces (#540)
- fix(ios): grey HA badge on unavailable/unknown light/switch instead of a confident Off (#538)
- fix(web): blank decode backend stays blank instead of pinning 'auto' (#536)
- feat(ha): pill badge width + text alignment across every renderer (#534)
- fix(api): PUT /config/server merges instead of replacing the whole row (#533)
- fix(console,api): first-run error-message quality pass (#532)
- fix(api,recorder): reject mqtts:// instead of silently connecting in plaintext (#530)
- fix(recorder): make MOTION_HWACCEL=auto probe a real cuda device and fall back to CPU when hardware decode fails (#531)
- fix(android): walk a fallback ladder to the server transcode for all-H265 cameras (#529)
- fix(api): surface go2rtc stream rejections; stop false camera_offline on newly added cameras (#528)
- fix(admin): warn on the Detection tab when a camera has no sub-stream (#527)
- fix(api): gate the _subv fmtp repair on the video codec (#526)
- fix(recorder): no false motion_detector_unhealthy for a camera with no sub-stream (#525)
- fix(api): require a full session for stream URLs, drop CORS from /auth (#516)
- fix(api): stop the console writing the go2rtc base into the Frigate HTTP base (#518)
- fix(recorder): guard the dangling-row pass against an unmounted storage (#515)
- feat(install): preflight storage so an install cannot silently record nothing (#514)
- fix(db,recorder): make ADD CONSTRAINT migrations re-appliable; default MOTION_HWACCEL to cpu in code (#513)
- docs: add TESTING.md tester onboarding + convert bug report to an issue form (#512)
- fix(console): serverTz crash outside the wizard, Detection Save dropping zones + grouped-camera edits, retire the wizard group step (#510)
- fix(ios): never let the HA value slider assert a value that was not sent (#508)
- docs: refresh screenshots and copy for the v0.2.0 release (#500)
- perf(api): register `_subv` only for the cameras whose sub SDP is actually broken (#501)
- feat(desktop): restructure the HA overlay editor around a top bar + badge popover (#495)
- fix(desktop): make Playback's keyboard shortcuts actually fire (#496)
- fix(desktop): make the live wall's keyboard shortcuts actually fire (#494)
- feat(android): quick-toggle to hide on-video Home Assistant overlays (#488)
- feat(desktop): global quick-toggle to hide all Home Assistant overlays (#487)
- feat(desktop): render per-state HA badge backgrounds (bg_color_on) (#491)
- feat(admin): author per-state HA badge background (bg_color_on) (#490)
- feat(ha): expand canonical badge-icon vocabulary (grill/smoker/landscape + 20 more) (#482)
- fix(android): scale HA pill badges like desktop so labels stop overflowing (#499)
- feat(ha): per-state badge background contract (overlay_bg_color_on) (#493)
- feat(ios): render per-state HA badge backgrounds (#492)
- feat(ios): quick-toggle to hide Home Assistant overlays on live video (#486)
- fix(desktop): keep the maximized pane's right-click menu available while a stream is connecting (#484)
- feat(android): render per-state HA badge background color (#489)
- fix(api,android): video-only `_subv` sub restream repairs H264 fmtp for Media3, scoped to Android (#485)
- fix(admin): clarify HA entity-link picker labels + fix stale "Motion tab" copy (#481)
- chore(release): v0.2.0 version bump + changelog + docs (#475)
- fix(recorder): default MOTION_HWACCEL to cpu so motion works on GPU-less hosts (#478)
- fix(deps,api,recorder): clear rustls-webpki cert-verify advisories + log/trim nits (#476)
- fix(ios): hold the HA value slider at the committed value until the poll converges (#474)
- fix(android): restore UTF-8 in LiveFullscreenScreen comment (#471)
- fix(android): don't render HA entity popup inside the PiP window (#469) (#470)
- feat(ios): match HA detail-card icon to the on-video badge color (#467)
- fix(android): make the HA value slider usable + popup visuals match the badge (#442 Slice 1 follow-ups) (#468)
- feat(desktop): match HA detail card icon color to badge + add entity/type rows (#466)
- feat(android): HA value slider for brightness/position/speed (#442 Slice 1) (#463)
- feat(ios): value slider for HA percent controls (brightness/position/speed) (#462)
- feat(desktop): HA value-setting slider for dimmable lights/covers/fans (#461)
- feat(ha): value-setting HA controls (brightness/position/speed), #442 Slice 1 (#460)
- docs(integrations): bring the Home Assistant page up to date with epic #445 (#459)
- feat(admin): unify Home Assistant into its own console area (#441) (#458)
- feat(admin): HA link authoring — icon/style + control config (#439) (#457)
- feat(ha): per-link control config — require_confirm + allowed_actions (#440) (#456)
- feat(ha): one canonical closed icon vocabulary, enforced + mapped on all clients (#455)
- feat(clients): render numeric HA sensor units on badge + entity detail (#454)
- feat(ha-links): editable role, device_class, and label per linked entity (#453)
- feat(api/ha): validate link role vs domain; expose sensor unit (#452)
- feat(ha): widen entity picker to all controllable + numeric-sensor domains (#448)
- fix(android): unify HA badge and entity-sheet icon/color mapping (#447)
- docs(map): add Home Assistant control parity row; fix stale Android overlay cell (#432)
- feat(android): Home Assistant control (Phase 2) with direct-tap interaction model (#431)
- feat(ios): HA single-tap actuates simple devices; card only for cover/lock (#428) (#430)
- feat(desktop): single-click actuates HA badge directly; card only for cover/lock (#428) (#429)
- feat(desktop): HA device controls on the on-video badge card (#187) (#426)
- feat(ios): HA control Phase 2, actuator buttons on the entity detail card (#425)
- feat(api): Home Assistant control endpoint + default-off actuators capability (#427)
- feat(desktop): adaptive live-wall quality, guardrail + backpressure (#382) (#424)
- feat(apple): adaptive live-wall quality (thermalState backpressure + decode guardrail) (#383) (#423)
- feat(android): adaptive live-wall quality (guardrail + decode backpressure) (#422)
- feat(desktop): show operator-given plate name over the raw plate (LPR) (#421)
- feat(android): show operator-assigned plate name over the raw plate in LPR UI (#420)
- feat(ios): show operator-assigned plate name in LPR reads and watchlist (#419)
- feat(lpr): human-readable plate names shown wherever a plate appears (#363) (#418)
- feat(go2rtc): first-class RTSP restream auth opt-out (GO2RTC_AUTH=off) (#417)
- docs(decisions): record no-autoheal-in-default-stack decision (#396) (#416)
- feat(api): surface motion-detector-down state in decode-status + admin console (#415)
- docs(recorder): VAAPI render-node robustness + escalated motion-decode-failure log (#414)
- fix(recorder): alert when a motion detector is broken from startup (#411) (#413)
- fix(desktop): support trackpad pinch-to-zoom on laptops (#410)
- fix(ios,desktop): raise digital-zoom ceilings to 30x to match Android (#408)
- fix(api): default media-token capability claims instead of rejecting old tokens (#407)
- fix(android): keep the playhead where the user scrubbed, even in a gap (#406)
- fix(android): raise the digital-zoom ceiling from 5x to 10x (#405)
- fix(clients): stop discovery preferring a TLS URL the app cannot use (#403)
- fix(setup): fail early when a bind-mounted config file is missing (#397)
- docs: warn about the NVIDIA driver-upgrade trap on GPU hosts (#395)
- perf(api,desktop): carry plate bbox in the ab-report (#393)
- fix(desktop): make frame-back work in the LPR plate popup (#392)
- fix(android): use Download glyph for playback wall Export action (#389)
- fix(android): keep playback digital zoom across motion-segment gaps (#387)
- feat(api): admin-only scrubbed diagnostics bundle (server side of #180) (#385)
- fix(release): bump all client versions to 0.1.1 + document the step (#381)

## [0.1.1] - 2026-07-20

A hardening release. Where 0.1.0 was about building the seat, 0.1.1 is about
making it trustworthy. This cycle was driven by an intensive, multi-model audit
program run with **Fable**: instead of a single review pass it ran repeated
adversarial sweeps over the whole system, the recorder, the API, all four
clients, install and upgrade, and the seams between server and client, each one
finding an issue, then independently trying to *refute* it, and only then fixing
it. That program produced the 60-plus changes below. Almost none of them change
what Crumb does; they change how much you can rely on it not to drop footage,
leak a credential, or lie to you on screen.

### The audit program

- **Recorder correctness got the most scrutiny**, because losing footage is the
  one unforgivable bug. The storage-migration copy now refuses to unlink the only
  copy of a segment (#282), quarantine pruning ages from entry time and spares
  collision losers (#283), the retention ceiling is truly absolute even for
  disabled cameras (#285), and a per-worker live-storage cache lets a reconnect
  survive a database outage (#286).
- **API security and reliability**: media tokens now carry the minter's real
  capabilities instead of a hardcoded full set (#326), a security batch tightened
  log redaction, XSS, and export/events authorization (#333), export bytes and
  the filmstrip window are bounded so one request cannot fill the disk or OOM the
  api (#314, #295), and the go2rtc reconcile loop is serialized against stream
  teardown (#315).
- **A final cross-boundary pass** hunted for cases where a server change diverged
  from how a client actually calls it, the class that produced the black license
  plate crops, and fixed the survivors: media tokens now carry `view_plates` so
  crops load (#365), plus honest clips paging totals, live and plate-clip
  capability gating, and a false motion-strip gap on long-GOP cameras (#374).
- **Every client was audited on its own.** iOS and macOS reached 0.1.0 feature
  parity (#261) and then took a batch of correctness, security, and memory fixes
  (#345 through #353, #377). Android hardened its coroutine and lifecycle handling
  and stopped rendering stale Home Assistant state as live (#306 through #313,
  #362, #376). The desktop client landed a long stability and UX pass (#324
  through #334, #361, #375).

### Added

- In-app desktop **Diagnostics**: bounded log capture, a verbose toggle, and a
  scrubbed export (#274).
- Seamless carousel and hotspot camera switching with no black gap (#268), and a
  draggable Home Assistant edit panel with labelled dot badges (#267).
- On-video Home Assistant badges on Android live (#266).
- **iOS and macOS reached feature parity with 0.1.0**: HA overlays, the LPR
  client, audio, data-saver, and the live and playback UX (#261).
- Camera compatibility: Reolink CX410 and EmpireTech IPC-B54IR-ASE-2.8MM-S3
  (#258).

### Changed

- The playback motion strip fetches intensity in one batched request instead of
  one per camera, backed by a sargable query bound that turns an O(retention)
  scan into O(window) (#259, #264); the clients chunk that batch to stay within
  the server cap (#375, #377).

### Known issues

- After upgrading, a running desktop, Android, or iOS client may show blank
  thumbnails or stalled media for up to about 15 minutes while its cached media
  tokens expire. Restart the client to clear it immediately. This is fixed
  permanently in the next release (#366).

### All merged changes

Every pull request merged since 0.1.0, newest first:

- fix(api): v0.1.1 cross-boundary audit batch (clips total, live cap, plate-clip cap, long-GOP intensity) (#374)
- fix(ios): use batched timeline-intensity endpoint instead of per-camera fan-out (#377)
- fix(android): grey HA badges after 2 missed polls (client-side staleness) (#376)
- fix(desktop): chunk motion-intensity batch into <=64-camera requests (#375)
- fix(ios): shield content on .inactive so the app-switcher snapshot can't leak it (#353)
- fix(ios): don't discard a successful login on a transient /auth/me failure (#352)
- fix(ios): hop HEVC-retag totalSize write to the main actor (#351)
- fix(ios): stream export downloads to disk instead of buffering in memory (#350)
- fix(ios): downsample plate images before caching (#349)
- fix(ios): within-segment seeks and failed media-token mints during playback (#348)
- fix(api): carry view_plates in media tokens so plate crops load (regression) (#365)
- fix(desktop): v0.1.1 verification-pass polish (6 fixes) (#361)
- fix(android): rethrow CancellationException at scopedUrl sites; clamp HA/motion poll backoff (#362)
- docs(ops): remove the postgres container before volume swap in DR recovery (#360)
- docs: v0.1.1 presentation hygiene + release-process bump step (#359)
- fix(install): secrets-overlay project name, password escaping, env/TZ/DR hygiene (#357)
- fix(ios): stop the live stream controller when PiP closes after detaching (#347)
- fix(ios): hop session-token clear to the main actor on a 401 (#346)
- fix(ios): clamp trun sample_count to prevent OOM on malformed fMP4 (#345)
- fix(desktop): carry camera identity with the pending player, not widget.camera (#330)
- fix(desktop): funnel live-wall 401s into the re-auth prompt (#334)
- fix(api): security hardening batch — log redaction, XSS, and export/events authz (#333)
- fix(desktop): guard disposed-mid-load players, detach error-path dispose (#332)
- fix(desktop): honor stream-override menu on the maximized live pane (#331)
- fix(desktop): detach playback pane player disposal from the UI isolate (#329)
- fix(desktop): restore from maximize when the maximized camera drops out of _shown (#328)
- fix(desktop): bound wedged stream-swaps with a timeout + recover a missed first-frame race (#327)
- fix(api): media tokens carry the minter's real caps, not a hardcoded full set (#326)
- fix(desktop): key HA-placement tracking by surface, not camera id (#325)
- fix(desktop): harden diagnostics log scrubbing to redact URL credentials (#324)
- fix(api): serialize go2rtc reconcile against stream teardown (delete race) (#315)
- fix(api): cap total finished-export bytes so a burst can't fill the disk (#314)
- fix(android): minor correctness cleanups (clip-player guard, stale comments) (#313)
- fix(android): map SSLHandshakeException to a specific message instead of the generic one (#312)
- fix(android): close export Create button's double-submit window (#311)
- fix(android): let CenteredTimeline's pinch-zoom span clamp match the host's own range (#310)
- fix(android): make Time.parseToMillis lenient instead of crashing on parse failure (#309)
- fix(android): move snapshot JPEG compress + MediaStore I/O off the main thread (#308)
- fix(android): lifecycle-gate HA-states poll and pause clip player on background (#307)
- fix(android): guard scopedUrl() at 4 unguarded call sites in PlaybackViewModel (#306)
- fix(api): harden clip-media ffmpeg spawns and the Frigate proxy read (#296)
- fix(api): bound the filmstrip window so one request can't OOM the api (#295)
- chore(recorder): hygiene batch — live-sweep h>0 guard, TZ invariant wording, audit invariants 30-33 (#287)
- fix(recorder): cache the resolved live storage per worker — a reconnect survives a DB outage (#286)
- fix(recorder): footage lifecycle covers disabled cameras — the retention ceiling is truly absolute (#285)
- fix(recorder): credit the floor deficit only for moves off the floor filesystem (#284)
- fix(recorder): quarantine prune ages from ENTRY time and exempts -rN collision losers (#283)
- fix(recorder): same-file guard in the storage-migration copy — never unlink the only copy (#282)
- ci(release): macOS attach creates the Release if missing; Windows zip ships a sha256 (#275)
- feat(desktop): in-app Diagnostics — bounded log capture, verbose toggle, scrubbed export (#180) (#274)
- fix(desktop): actually freeze a maximized carousel/hotspot slot (#273)
- fix(desktop): gate post-open seeks on file-loaded — frame-step no longer jumps a segment on quiet footage (#272)
- fix(desktop): fall back to per-camera intensity when the server lacks the batch endpoint (#271)
- feat(desktop): seamless carousel/hotspot camera switching (no black gap) (#254) (#268)
- feat(desktop): draggable HA edit panel + Dot badges show their label (#255) (#267)
- feat(android): render on-video Home Assistant badges on live (#263) (#266)
- fix(android): quality label no longer wraps 'AUTO' to two lines (#265)
- iOS/macOS: v0.1.0 parity — Home Assistant overlays, LPR client, audio, data-saver, live/playback UX (#261)
- perf(timeline): batch the per-camera intensity fan-out into one request (#256) (#264)
- perf(timeline): stop the motion-strip refresh from stacking under load (#256) (#260)
- perf(timeline): sargable start_ts bound on the intensity query — O(retention) → O(window) (#256) (#259)
- chore(release): add pr-changelog.sh (per-PR bulleted change list) + document it (#257)
- data(cameras): add Reolink CX410 + EmpireTech IPC-B54IR-ASE-2.8MM-S3 (closes #181, #182) (#258)

## [0.1.0] - 2026-07-18

The week after the first public cut. The theme: turn a working recorder into a
seat you'd actually want to sit in: a native desktop rewrite, license-plate
review, mobile-friendly streaming, and a lot of small details that add up.

### Added

**A native desktop client, rewritten in Flutter.** The desktop app was rebuilt
from the ground up (libmpv under Flutter, the Rust core kept over FFI) so live
video composites *under* native UI instead of a web view stapled over it. Full
feature port: the multi-camera live wall (maximize, digital zoom, per-tile
stream choice), a PTZ builder, playback with the scrubbable timeline, clips,
batch export, and the "special" wall tiles (carousels, motion-following hotspot,
clocks, web panes). Session persistence via Windows DPAPI so login survives a
relaunch.

**License-plate recognition, now with Crumb's own engine.** LPR began as a review
surface over Frigate's plate reads, and it grew a second source: Crumb's own local
ALPR (fast-alpr), a CPU-only, motion-gated worker that idles most of the time. Pick
per camera which engine reads it (Frigate, Crumb, both, or none). Run both and the
new **A/B benchmark** scores them head to head on your own cameras: which read the
plate, which missed, where they agreed or differed, crops side by side to confirm.
Around the reads: a searchable **LPR** tab, a **watchlist** with confusable-character
fuzzy matching (shows you live which misreads it accepts) and an **ignore** list, one
row per car instead of duplicate piles, and the cropped plate rendered in-app
(gallery, detail, PDF report). Verified against Frigate 0.17 and the 0.18 beta on a
live feed.

**Mobile-friendly live + playback.** An on-demand low-bitrate path for cheap
remote viewing: a server-side `<name>_mobile` transcode plus per-client quality
selection: Android's adaptive **Auto / Full / Data-saver**, and a matching
**Data-saver** tier on the desktop wall (per-camera or as the wall default, with
an "SD" badge on panes that are running it). Playback got an on-demand low-res
proxy too, with buffering tuned for a phone on cell data.

**Home Assistant, feed and overlay.** Link cameras to Home Assistant entities
from the admin console or the desktop app, and feed HA (or any MQTT source) in as
an **additional motion signal** alongside Crumb's own pixel motion. New this cycle:
an **on-video overlay**. Drag a linked entity's badge onto the live frame where it
physically sits and it shows that entity's live state on the wall (open/closed,
on/off), with a customizable icon (sixty to choose from), shape, color, size, and
caption. Android surfaces the same linked entities read-only. Control (actuating a
switch from its badge) is the next step.

**Storage advisor.** A per-camera storage footprint table with honest policy
labels and a whole-database "Crumb data footprint" breakdown, so you can see where
the disk actually goes.

**Camera compatibility database.** An in-app "what is this camera and does it
work" identifier, a growing make/model/firmware compat list, manual entry, and a
one-click "contribute this camera" issue prefilled from what Crumb detected.

**Update awareness.** An opt-in update-available check with an unobtrusive
"there's a newer release" banner and a **Check now** action across the desktop,
Android, macOS/iOS clients and the admin About page. Off by default; no
phone-home unless you turn it on.

**Frame-accurate scrubbing infrastructure.** A pre-generated preview proxy so
revisiting a spot on the timeline is a ~1 ms cached read instead of a ~250 ms
re-decode, with the tunables (preview size, cadence) exposed in the admin
console.

**More clients.** A macOS app reached export + playback parity with Windows; the
iOS app got smooth timeline scrubbing and a proper portrait playback layout
(both still pre-distribution, see the README on the iOS funding note).

**RBAC.** A "view all bookmarks, manage your own" role tier, and per-capability
gating for the new surfaces (LPR, view management).

**Android quality-of-life.** Audio on/off in recorded playback, a Live **take
snapshot** button, and a **Share** action that opens the Android system share
sheet for a saved snapshot or export.

### Changed

- **The install seeds the admin by default.** `scripts/setup-env.sh` now
  generates a memorable passphrase as `SEED_ADMIN_PASSWORD` and prints it once,
  so the admin account exists at first boot and the unauthenticated bootstrap
  window stays closed. The browser create-admin wizard is now the opt-in path
  (blank the seed to use it).
- **Recording policies replaced group inheritance.** Every camera now belongs to
  one explicitly named recording policy instead of inheriting through camera
  groups, so what a camera records by is never a guess. The old NULL-inherit /
  group-inheritance model was retired.
- **Admin console rebuilt** around a sections rail with a list→detail layout,
  reconciled onto `main`.
- **The "Plates" tab is now "LPR"** across every client (label only, the
  underlying routes, capabilities and APIs are unchanged).
- **Digital zoom pulls the full-quality (main) stream** so a zoomed-in live tile
  is sharp instead of upscaling the sub-stream.
- Playback clip player got its own minimal transport (play/pause, back-to-start,
  ±1-frame stepping with frame-accurate seeking) instead of the stock overlay.

### Fixed

- **Frigate 0.18 compatibility.** The 0.18 beta MQTT event shape failed the
  whole-envelope parse on *every* event (a serde duplicate-field regression);
  and, once flowing, live reads stored no plate crop box because 0.18 sends the
  box as pixel corners on a different frame than the recognized text. Both fixed
  and covered by fixtures built from the real wire payloads.
- **Audio.** Recorded segments now capture audio and normalize it
  to gap-filled 48 kHz AAC so it plays on Android; a mid-playback volume glitch
  on Android was fixed.
- **Gapless playback** across recorded segment boundaries on desktop and macOS
  (no more blackout at the segment seam).
- **Recorder robustness.** Frigate motion now *fails open* on a wedged MQTT
  broker (a stuck broker can't silently stop recording); plus the full sweep of
  the 2026-07-12 recorder audit (see Hardened).
- **ONVIF.** Backfill host/credentials from the camera's source URL so "Identify"
  and PTZ work on cameras added by RTSP URL alone.
- Timeline shows the date when scrubbed off "today"; wall scrub tiles show
  "no footage" instead of freezing; thumbnail extraction forced to MJPEG (fixed a
  100%-scrub 404); Android Edit-view layout; and a long tail of client polish.
- **Timezones actually work now.** The recorder's archive/retention cron
  inherits the container `TZ` instead of hardcoding America/Los_Angeles, and the
  admin console shows schedule times in the server's real timezone instead of a
  hardcoded "Pacific" label (#228, #237).
- **`.env` keys stopped being silent no-ops.** Compose now forwards the
  code-read keys it previously dropped (`RECORDER_TZ`, `HA_BASE_URL`/`HA_TOKEN`/
  `HA_TOKEN_FILE`, `DB_POOL_SIZE`, `MAINTENANCE_UNTIL`,
  `CAMERA_OFFLINE_BOOT_GRACE_SECS`, the `THUMB_*` set), and the env parsers
  treat an empty value as unset instead of failing boot (#229).
- **First-run wizard storage cap.** On a nearly-full disk the prefilled
  keep-at-most cap could invert to *unlimited*; it now floors at 80% of free
  space (#227).
- **The Windows desktop release ships the Flutter client.** The `v*` tag
  workflow was still building the retired Tauri app; it now builds
  `apps/desktop-flutter` and attaches an unzip-and-run
  `CrumbVMS-windows-<tag>.zip` to the Release, with a real Crumb app icon
  instead of the Flutter placeholder.

### Hardened (recorder correctness)

Losing footage is the one unforgivable bug, so the recorder gets extra scrutiny.
This cycle: two independent correctness audits with the findings implemented and
re-audited (a same-path archive move and a dead stall-watchdog among the
critical ones), new documented correctness invariants, and tests added for the
paths that were changed. Plus a **leak-scan CI gate** that blocks internal/homelab
identifiers from ever reaching `main`, hermetic singleton tests, and the Android
app now builds on every PR.

## [0.0.1] - 2026-07-07

**First public release.** The operator-grade core: a Rust recorder writing plain
MP4 with a Postgres segment index as the single source of truth; a frame-level
scrubbable timeline (4K H.265 handed straight to the decoder, no server
transcode) with Frigate's motion and object detections drawn on one bar; a
saveable multi-camera live wall; motion recording that buffers in RAM and only
persists on motion; a batch export list to MP4 or AES-256-encrypted ZIP with
optional timestamp burn-in; custom roles with per-camera access; a first-run
wizard with generated secrets, LAN-only by default; and native desktop
(then Tauri), Android, and web-admin clients. Runs entirely on your own hardware,
no cloud, no account, no telemetry.

[Unreleased]: https://github.com/badbread/crumbvms/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/badbread/crumbvms/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/badbread/crumbvms/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/badbread/crumbvms/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/badbread/crumbvms/releases/tag/v0.0.1
