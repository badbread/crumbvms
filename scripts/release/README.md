# Crumb, "update all clients" release orchestrator

One command fans a release out to every build host over SSH, from the Windows
workstation (Git Bash). Or just ask the Claude session to "update all clients" /
"release" and it prompts for which targets.

> This is the **multi-host client/backend orchestration**. For backend image
> versioning, registries, and rollback, see [../../docs/RELEASE.md](../../docs/RELEASE.md).

```bash
bash scripts/release/release.sh all                 # backend + android + ios + both desktops
bash scripts/release/release.sh backend android     # pick targets
bash scripts/release/release.sh desktop             # both desktop builds
bash scripts/release/release.sh backend --api-only  # api only (no recorder blip)
```

## Build hosts

Three hosts do the builds, reached as SSH aliases you define in `~/.ssh/config`.
The defaults are placeholders, set them for your environment via the `CRUMB_*`
env vars (see `lib.sh`). The scripts tar the repo over SSH to each host where
needed:

| Target | Host role | SSH alias env | Code gets there via | What runs |
|---|---|---|---|---|
| Backend deploy | prod host | `CRUMB_PROD_HOST` | tar over SSH → `$CRUMB_PROD_APP` (default `/opt/crumb/app`) | `docker compose build/up api recorder` |
| Backend gate | build host | `CRUMB_BUILD_HOST` | tar over SSH → `~/crumb-gate` | `cargo fmt --check` + `clippy -D warnings` + `test` |
| Android | build host | `CRUMB_BUILD_HOST` | tar over SSH → `~/projects/crumb-android` | `./gradlew assembleDebug` → publish `~/apk-serve/crumb.apk` (http :8088) |
| iOS | Mac host | `CRUMB_MAC_HOST` | repo at `$CRUMB_MAC_REPO` (mount or checkout on the Mac) | `xcodebuild -scheme Crumb` (unsigned compile) |
| Desktop (Linux) | build host | `CRUMB_BUILD_HOST` | tar over SSH → `~/projects/crumb-desktop` | `cargo build` in `src-tauri` (gtk/mpv pane backend) |
| Desktop (Windows) | local workstation |, (local) | synced repo → local run-dir (`CRUMB_DESKTOP_RUN_DIR`) | `cargo build` in the run-dir + libmpv-2.dll next to the exe |

Order is fixed: **backend is gated then deployed first**, so a freshly-deployed
API is live before the clients ship. A failed gate aborts the deploy. Desktop
(Windows) is the one target that builds **locally** (it's Windows-native).

## Scripts

- `release.sh`, orchestrator (picks targets, runs in order, prints a summary).
- `backend.sh`, `--gate-only` / `--no-gate` / `--api-only`.
- `android.sh`, sync + `assembleDebug` + publish APK.
- `ios.sh`, `xcodebuild` over SSH (unsigned compile check).
- `desktop-linux.sh`, sync + `cargo build` on the build host.
- `desktop-windows.sh`, local `cargo build` + place libmpv-2.dll (path via `CRUMB_LIBMPV_DLL`).
- `lib.sh`, shared host/path config (set hosts via `CRUMB_BUILD_HOST`/`CRUMB_PROD_HOST`/`CRUMB_MAC_HOST`).

## Prerequisites

- SSH aliases for your build/prod/Mac hosts working with key auth (set via the
  `CRUMB_*` env vars above).
- The Mac host must be **awake** for iOS builds. Consider `caffeinate` for
  unattended runs.

## Builds vs distributable bundles

The client targets produce **runnable debug builds**, not signed/distributable
installers, enough to ship the latest code to your own devices. Turning those
into artifacts others install is separate work:

- **iOS signing**, `ios.sh` is an unsigned compile only. A device/TestFlight build
  needs a signing identity + provisioning (free Apple ID = 7-day on-device; the
  $99 Apple Developer Program = TestFlight/App Store). Add an `--archive`/`--device`
  path once that's set up.
- **Desktop (Linux) .deb**, `desktop-linux.sh` does `cargo build`; a `.deb` needs
  `cargo tauri build` (the bundle config already declares the deb deps). Add once
  tauri-cli is set up on the build host.
- **Desktop (Windows) installer**, `cargo tauri build` produces an MSI/NSIS, but
  the bundle config doesn't yet ship `libmpv-2.dll` as a resource, so a packaged
  installer would be missing it. Add the DLL to bundle resources first.
- **Web**, secondary console; no prod deploy target wired.
