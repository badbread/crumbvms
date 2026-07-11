# Desktop Flutter rewrite — P1 plan (live wall + HA on-video overlays)

Execution plan for **P1** of the native-Flutter desktop-client rewrite. The
architecture decision and its trade-offs live in
[`DECISIONS.md`](DECISIONS.md) (2026-07-10, "Desktop client: rewrite native in
Flutter"); this doc is the how, not the why.

## Status: P0 (de-risk spike) — DONE ✅

The `apps/desktop-flutter/` spike proved, on one live camera pane on real
hardware, that the three load-bearing pieces hold together:

- **media_kit / libmpv** → live camera into a Flutter external texture, hardware
  decode (NVDEC) confirmed.
- **flutter_rust_bridge** → the existing Windows-native Rust core (a port of
  `apps/desktop/src-tauri`'s `host_stats`, winapi + NVML).
- **native overlay compositing** → HUD + draggable PTZ stub + Flutter-native
  digital zoom/pan, composited over the texture with real hit-testing. The
  inverse of the retired Tauri "airspace" model.

**Two things the spike settled — carry into P1:**

1. **FRB bridges the *client/util* core, not the video engine.** The mpv
   management in `src-tauri` (`sync_panes`, `configure_mpv`, WndProc, `wid`
   HWND-embedding, notches, `set_panes_hidden`) *is* the airspace model → it is
   thrown away, not bridged. media_kit owns its own mpv handle + texture; the
   per-pane controls (zoom/pan/seek/speed/mute/frame-step/overlay/stats) become
   Dart calls on media_kit's `Player`.
2. **Digital zoom/pan lives in Flutter, not mpv** (`Transform`/`Matrix4` on the
   texture) — GPU-composited, no per-tick FFI, sub-pixel smooth, identical
   quality since digital zoom just upscales the decoded frame.

## P1 goal

An authenticated multi-camera **live wall** with **Home Assistant entity state
overlaid on the relevant panes as first-class native widgets** — the headline
replacement for the surface the maintainer found non-native, built on the proven
spike patterns.

## ⚠️ Perf gate — do this FIRST (before the wall UI)

The old client used native HWND panes; media_kit gives each tile its own libmpv
instance + texture. **Before building the wall, validate 9-up and 16-up on real
hardware** with the tuned mpv options ported from
`apps/desktop/src-tauri/src/lib.rs::configure_mpv` (`hwdec=auto`, `cache=yes`,
`demuxer-readahead-secs`, `rtsp-transport=tcp`, `demuxer-max-bytes` /
`demuxer-max-back-bytes`, `network-timeout`, `analyzeduration`/`probesize`,
`mute`). Metrics: CPU / GPU / NVDEC / RSS vs the Tauri baseline, plus
time-to-first-frame across a full wall bring-up.

**If per-instance overhead is too high at 16-up, that is a revisit trigger to
settle before the wall is built** — not after. (media_kit exposes mpv options
via `PlayerConfiguration` + the `NativePlayer.setProperty` path used in the
spike.)

## Workstreams

### 1. Rust `crumb_client_core` (no-Tauri lib, FRB-bound)
Extract the portable surface out of the Tauri command wrappers into a lib crate
that FRB binds:
- `host_stats` (done in the spike),
- DPAPI secret encrypt/decrypt (`secret_encrypt`/`secret_decrypt`),
- LAN discovery (`discover_servers` / `local_subnet_cidr` / `probe_server`),
- authed export streaming (`save_export_file` helper).

Leave the mpv/airspace code behind entirely (`sync_panes`, `configure_mpv`,
WndProc, `linux_panes`). Some Tauri commands map to **Flutter plugins**, not FRB:
folder/file pickers → `file_selector`, open URL/folder → `url_launcher`,
fullscreen/window → `window_manager`. Decide FRB-vs-plugin per command.

### 2. Auth + server connection
Login → JWT; DPAPI-encrypted token at rest (via the core); server-discovery UI;
reconnect. Reuse existing API endpoints.

### 3. Stream plumbing (secure by default)
Camera list + go2rtc restream URLs carrying scoped, short-lived media `?token=`
claims — **never the bearer JWT** (golden rule 1). Port the URL logic from the
Tauri client.

### 4. Live wall UI
Grid layouts (1 / 4 / 9 / 16 + saved views); each tile = the spike pane
(media_kit Player + texture + zoom/pan + overlays), **keyed by camera id**
(pane identity is free now — the "wrong camera on return" reconcile bug stays
shelved). Play-on-focus audio, mute-by-default, maximize, stall watchdog
(player-state stream → reload). Reconcile is a Flutter rebuild + Player
lifecycle (create/dispose on wall changes; keep alive while transiently hidden).

### 5. HA on-video overlays (headline)
Entity state (door / window / occupancy / garage / sensor) as native widgets
pinned to their camera pane, position-configurable, wired to the HA phase-2
data. Rendering is proven trivial now — the work is data plumbing + placement
UX, not rendering risk.

## Deferred (unchanged from the decision log)
- Playback / timeline → **P2**
- Clips / export / decode tuner / bookmarks / saved-view editor → **P3**
- Embedded web `/admin` console (hybrid) → later
- Linux → on hold until someone asks (Flutter makes it near-free then)

## Cross-surface (per `COMPONENT-MAP.md`)
- Add `apps/desktop-flutter` as a surface in `COMPONENT-MAP.md` + the README.
- Update the `DECISIONS.md` revisit-trigger note once the perf gate clears.
- `AI-INSTALL.md` is unaffected (the client is not part of the server install).
