# Crumb, "update all clients" release orchestrator

One command fans a release out to every build host over SSH, from the Windows
workstation (Git Bash). Or just ask the Claude session to "update all clients" /
"release" and it prompts for which targets.

> This is the **multi-host client/backend orchestration**. For backend image
> versioning, registries, and rollback, see [../../docs/RELEASE.md](../../docs/RELEASE.md).

```bash
bash scripts/release/release.sh all                 # backend + android + ios
bash scripts/release/release.sh backend android     # pick targets
bash scripts/release/release.sh backend --api-only  # api only (no recorder blip)
```

> **Desktop is not a target here anymore.** The Windows desktop ships via
> `.github/workflows/windows-release-flutter.yml` on the `v*` tag; the Tauri
> `desktop-windows.sh` / `desktop-linux.sh` scripts are retired and exit
> immediately if invoked.

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

Order is fixed: **backend is gated then deployed first**, so a freshly-deployed
API is live before the clients ship. A failed gate aborts the deploy.

## Scripts

- `release.sh`, orchestrator (picks targets, runs in order, prints a summary).
- `backend.sh`, `--gate-only` / `--no-gate` / `--api-only`.
- `android.sh`, sync + `assembleDebug` + publish APK.
- `ios.sh`, `xcodebuild` over SSH (unsigned compile check).
- `desktop-linux.sh` / `desktop-windows.sh`, **retired** Tauri builds; each
  prints a pointer to `windows-release-flutter.yml` and exits.
- `pr-changelog.sh`, one bullet per merged PR in a range (default: since the
  last tag). Standalone, no SSH/hosts; feeds the release notes (see
  `docs/RELEASE.md`).
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
- **Desktop**, distributed separately: the Windows Flutter client is built and
  zipped by `.github/workflows/windows-release-flutter.yml` on the `v*` tag.
- **Web**, secondary console; no prod deploy target wired.
