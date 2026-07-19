# CrumbVMS, agent guide

This file is the shared ground rules for **any** AI coding session in this repo —
the maintainer's and contributors' alike. Claude Code loads it via `CLAUDE.md`;
other tools read `AGENTS.md` directly. If you are an AI agent: these rules are
not suggestions, and a PR that violates them will be declined no matter how good
the code is.

## What Crumb is (and is not)

CrumbVMS is a **self-hosted, operator-grade** network video recorder: a Rust
backend (`services/`) + Postgres + a Crumb-managed go2rtc restreamer (embedded
in the recorder container, supervised by the recorder process), native
desktop (Flutter/libmpv) and Android (Kotlin/Compose) clients, and a web admin
console served by the API at `/admin`. The UX bar is a leading commercial VMS,
not a hobby dashboard.

**Direction (ratified, do not re-litigate or "helpfully" work around):**

- **Free and open source, AGPL-3.0-or-later, forever.** No paid tier, no
  license enforcement, no open-core split. Do not build, scaffold, or advertise
  monetization of any kind.
- **The operator's hardware is the whole world.** No telemetry, no analytics,
  no phone-home, no mandatory cloud services or accounts. Optional integrations
  must always have a self-hosted path and must never be the only path.
- **Footage never leaves the operator's control.** Any feature that would ship
  video, thumbnails, or metadata to a third party is out of scope.

## Golden rules

1. **Secure by default.** Crumb records security cameras; a misconfiguration is
   a privacy hazard. Every new HTTP endpoint is authenticated and goes through
   the existing RBAC (admin vs role capabilities + per-camera grants). Media
   URLs use the scoped short-lived `?token=` media claims, never the bearer JWT.
   Never widen default port exposure, never bind new services to `0.0.0.0`
   without need, never weaken the LAN-only posture. Never invent, hardcode,
   print, or log secrets, `scripts/setup-env.sh` generates them; `.env` is
   gitignored and stays that way.
2. **Recorder correctness is sacred.** Losing footage is the one unforgivable
   bug. Anything touching recording, segment indexing, retention/eviction,
   reconcile, storage migration, or DB migrations gets tests and extra
   scrutiny, read `docs/RECORDER-CORRECTNESS.md` first. When in doubt, prefer
   the change that cannot delete or orphan footage.
3. **The gate must be green before any push/PR** (same checks as CI —
   `.github/workflows/ci.yml`):
   ```bash
   cargo fmt --all -- --check
   cargo clippy --all-targets -- -D warnings   # warnings are errors
   cargo test --workspace                      # needs a Postgres, see below
   ```
   Throwaway test database for the integration tests:
   ```bash
   docker run -d --name crumb-test-pg -e POSTGRES_PASSWORD=test \
     -e POSTGRES_DB=crumb -p 127.0.0.1:5442:5432 postgres:16-alpine
   DATABASE_URL=postgres://postgres:test@localhost:5442/crumb cargo test --workspace
   docker rm -f crumb-test-pg
   ```
4. **New migrations must be registered.** Migrations are numbered SQL in
   `db/migrations/`, applied on boot **only if** listed in the `MIGRATIONS`
   array in `services/common/src/db.rs` (both api and recorder embed them).
   A migration file that isn't registered silently never runs.
5. **Keep the install guide honest.** If a change touches how a fresh install
   is stood up or configured, `docker-compose*.yml` (services, ports, volumes,
   profiles, required secrets), `.env.example` / `scripts/setup-env.sh` keys,
   the first-run wizard flow, image pull-vs-build, TLS/Caddy, backups, or
   notifications/monitoring, update **`docs/AI-INSTALL.md`** (and the README
   manual path) in the **same** change. That runbook must never drift from
   reality; its "For maintainers" section lists what to re-verify.
6. **Don't add heavyweight dependencies casually.** New crates/libraries with
   large trees, new background services, or new build-time downloads need an
   issue discussion first. Never bump ffmpeg/go2rtc/Postgres majors as a side
   effect of another change.
7. **Respect the decision log.** `docs/DECISIONS.md` records significant
   architecture decisions, the alternatives that were rejected and why, and the
   concrete triggers that would reopen each question. Before proposing (or
   "helpfully" implementing) a different approach to something it covers, read
   the entry, re-litigate only if one of its revisit triggers has actually
   fired, and say so explicitly. In the other direction: when a session makes a
   significant design decision, anything where a credible alternative was
   researched and rejected, add an entry (what was chosen, what was rejected,
   the trade-offs accepted, revisit triggers) in the same change. Decisions that
   live only in a chat session are lost to the next one.

8. **Consult the component map before changing behavior.**
   `docs/COMPONENT-MAP.md` is the inventory of every surface (backend, the
   clients, install guide, CI, README, marketing site, docs site) and a
   change-propagation matrix organized by change type. At the start of any
   feature or behavior change, run down the matching rows and update every
   listed surface in the same change, or state explicitly what is deferred.
   When a session adds a new surface or a new kind of change, it updates the
   map in the same change, exactly as this file requires for `docs/DECISIONS.md`.

## Map of the codebase

- `services/common`, shared types, DB layer, config, **the `MIGRATIONS` array**.
- `services/api`, axum HTTP API; also serves the admin console and owns the
  go2rtc reconcile loop. Routes use axum `:id`-style path params.
- `services/recorder`, recording, motion detection (pluggable detectors),
  retention/eviction, decode telemetry. The always-must-work component.
- `services/api/src/admin.html`, the **entire** web admin console: one large
  file with inline `<script>`, embedded via `include_str!` (rebuild the api to
  see changes; some tools misdetect it as binary, `grep -a`). Conventions:
  plain functions wired by `on*=` attributes (every referenced handler must
  exist), `esc()` for interpolation, `api()` helper for authed fetches,
  semantic colors `var(--ok)`/`var(--warn)`/`var(--danger)`. Sanity-check with
  `node --check` on the extracted script block.
- `apps/desktop-flutter`, the live desktop client: Flutter over a Rust core
  via `flutter_rust_bridge`, video through `media_kit`/libmpv. Windows note:
  `libmpv-2.dll` must sit next to the built exe or video panes render black
  (media_kit bundles it into the Release folder). `apps/desktop` is the
  retired Tauri client, kept for reference; not built by CI or releases.
- `apps/android`, Kotlin/Compose/Media3, Gradle (JDK 17, SDK 34).
- `db/migrations/`, numbered SQL (see golden rule 4).
- `docs/`, design docs and runbooks; `docs/ROADMAP.md` for larger initiatives.

Seams that have bitten before:

- **go2rtc streams are managed at runtime** by the api's reconcile loop from the
  `cameras` table. Never hand-add streams or credentials to `go2rtc/go2rtc.yaml`
  (listener config only), and never point `crumb_api_base` anywhere but Crumb's
  own go2rtc REST endpoint.
- The api mounts media storage **read-only**; the recorder holds the RW mount.
  Don't "fix" that, and don't assume the api can write under `/data`.
- Config precedence: admin-set DB `server_settings` values win over env
  defaults; empty DB value falls back to env. Wizard/console code must only
  ever write the specific fields it edits.

## Setting Crumb up (for users, or to get a dev instance)

Follow **`docs/AI-INSTALL.md`**, an agent-runnable, secure-by-default runbook
(host prep → secrets → `docker compose up -d` → first-run wizard or API), with a
Verify check after every step. Read its Ground rules first: LAN-only, generated
secrets, never expose to the public internet on your own initiative. Manual
path: `scripts/setup-env.sh` → `docker compose up -d` →
`http://<host>:8080/admin`.

## Contribution mechanics

Human rules live in `CONTRIBUTING.md` (issue-first for anything non-trivial,
focused PRs, tests for changed behavior). Non-negotiables for agent sessions:

- Every commit carries a DCO sign-off (`git commit -s`) from the human author.
  The human owns and must review what an AI session produces before opening a PR.
- Match the surrounding code's style; don't reformat or "clean up" code you
  aren't changing.
- Bugs follow the bug workflow: file a GitHub issue (`bug` label + area label),
  fix on a one-bug-per-branch `fix/<slug>` branch, and put `Fixes #<n>` in the
  PR. Footage-threatening or won't-boot bugs may hotfix straight to a `fix/`
  branch. Same flow for every component; details in `CONTRIBUTING.md`.
- Security vulnerabilities go through GitHub private reporting
  (see `SECURITY.md`), never the public tracker or a PR description.
