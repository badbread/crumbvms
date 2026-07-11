# crumb_desktop — Flutter desktop client (P0 de-risk spike)

Phase-0 de-risk spike for the desktop-client rewrite (see
`docs/DECISIONS.md`, 2026-07-10 "Desktop client: rewrite native in Flutter").
It proves, on **one** camera pane, that the three pieces the rewrite depends on
hold together on the real Windows toolchain:

1. **media_kit / libmpv** renders a live camera into a Flutter external texture
   (hardware decode).
2. **flutter_rust_bridge** calls the existing Windows-native Rust core — here a
   port of `apps/desktop/src-tauri`'s `host_stats` (winapi CPU/mem + NVML GPU).
3. A **native Flutter overlay** composites over the video texture with real
   hit-testing — the HUD, a draggable PTZ stub, and Flutter-native digital
   zoom/pan (wheel = zoom-to-cursor, drag = pan, double-tap = reset). This is
   the inverse of the retired Tauri "airspace" model (native video *on top* of
   the web UI) that made the old client feel non-native.

This is a spike, not the product: one hard-coded pane, no auth, no wall, no
playback. Those are P1+.

## Layout

- `lib/main.dart` — the whole spike UI (video + overlays + zoom/pan).
- `rust/src/api/host.rs` — the FRB-exposed `host_stats` port.
- `lib/src/rust/`, `rust/src/frb_generated.rs` — flutter_rust_bridge generated
  bindings (committed; regenerate with `flutter_rust_bridge_codegen generate`).

## Build & run

Windows builds run on the `winbuild` VM (this workstation is kept clean of dev
tooling). Toolchain: Flutter 3.44.6, flutter_rust_bridge_codegen 2.12, Rust
1.97, VS Build Tools 2022.

```sh
flutter pub get
flutter_rust_bridge_codegen generate          # if Rust API changed
# The stream URL is a build-time define so no site address lands in the repo.
# Omit it to fall back to a generic lavfi test pattern.
flutter run -d windows --dart-define=STREAM_URL=rtsp://HOST:PORT/CAMERA
```

The build bundle under `build/windows/x64/runner/Release/` is self-contained
(bundled `libmpv-2.dll`, ANGLE, the Rust dylib) and can be copied to real
hardware to judge rendering/feel — `winbuild` itself is headless and GPU-less,
so it builds but cannot render.
