# Update-available checker: design and task breakdown (issue #7)

Status: **DESIGN, not implemented.** This is the skeleton for
[issue #7, "Update-available checker across all clients"](https://github.com/badbread/crumbvms/issues/7),
written to be implemented task-by-task by separate agent sessions. Read
`AGENTS.md` first; every task below is bound by the golden rules (secure by
default, CI gate, migration registration, install-guide honesty,
DECISIONS/COMPONENT-MAP obligations).

## 0. Scope, straight from issue #7

The deliverable is an **"update available" signal**, nothing more:

- Each client compares its own build version to the latest CrumbVMS release
  and shows a **non-intrusive "update available → release notes" notice**.
- Clients in scope: Windows desktop (Tauri), Linux desktop (Tauri), macOS,
  Android (sideloaded APK), iOS (SwiftUI, **lowest priority**, the App
  Store/TestFlight handles it once distributed), and the web console
  (`/admin`, served by the api, whose "update" is the server image itself).
- Source of truth: **GitHub Releases** for `badbread/crumbvms` (the repo
  already publishes tagged releases via the `*-release` workflows).
- Constraints, verbatim from the issue's recorded maintainer direction:
  - "Must be optional and operator-disableable, no mandatory phone-home. The
    check contacts GitHub (where the software came from), sends no
    telemetry, and can be turned off."
  - "Version check only; footage and metadata are never involved."
  - "No auto-download / auto-install without explicit user action, and never
    auto-update the recorder."
- Explicitly **out of scope** for #7: auto-download, auto-install, artifact
  hosting/serving, artifact signing, update channels, and any self-update
  mechanics (Sparkle, PackageInstaller sessions, the Tauri updater's install
  feature). A fuller update system is sketched as a clearly-labeled future
  extension in §6 and is NOT part of this work.
- Priority: "post-alpha nicety, not blocking." The design and the task
  sizing below are deliberately proportionate to that.

Clarification on direction: contacting GitHub for a **version number** is
ratified as acceptable here (it is where the software came from, it carries
no telemetry, and it can be switched off). This checker must never be
extended to send anything, telemetry stays nonexistent, and footage/metadata
are structurally uninvolved (the code never touches media paths, media
tokens, or the recorder).

## 1. Architecture

```
                       (only while the operator leaves the check enabled)
                    ┌──────────────────────────────────────────────────┐
                    │  GitHub Releases API (badbread/crumbvms)         │
                    │  GET /repos/.../releases/latest  → tag + notes   │
                    └──────────────────────▲───────────────────────────┘
                                           │ one plain HTTPS GET,
                                           │ api-initiated, cached (TTL),
                                           │ nothing sent, version-only
                              ┌────────────┴───────────────┐
                              │  Crumb api (services/api)  │
                              │  updates.rs                │
                              │   • GET /updates/latest    │
                              │   • in-memory cache        │
                              │   • server_settings toggle │
                              └────────────┬───────────────┘
                     LAN, existing :8080/:8443, bearer-JWT authed
          ┌───────────┬───────────┬────────┴──┬───────────┬───────────┐
          ▼           ▼           ▼           ▼           ▼           ▼
      Web admin   Win desktop  Linux desktop  Android    macOS       iOS
      (server-    (banner →    (banner →     (banner →  (banner →  (banner;
       update      release      release       release    release    lowest
       notice)     notes)       notes)        notes)     notes)     priority)
```

Recommended topology (decision point D2): the api owns the single
GitHub-facing check behind `GET /updates/latest`, and every client consumes
that from the server it is already paired and authenticated with. Rationale
(convenience and single-source-of-truth, per the issue's suggestion, not an
anti-phone-home mandate, the maintainer has ratified direct GitHub contact
as acceptable):

- The version-source logic, caching, and semver parsing live in ONE place
  instead of five client codebases.
- The operator's disable switch is ONE switch that actually turns the whole
  thing off for every client on the site, instead of a per-client setting
  audit.
- One cached egress point per site (a handful of GitHub hits per day)
  instead of every wall display and phone polling GitHub independently.
- Clients keep the property that they only ever talk to their own server.

A client talking to an older server that lacks the endpoint gets a 404 and
shows nothing (feature detection, component-map §3 parity item 3). That is
the accepted trade-off of server-mediation: a client can only learn about
updates while its server is new enough and has the check enabled.

Restated invariants: **no new ports, no new binds, no telemetry, never
auto-update the recorder, nothing here touches footage or the recorder
service at all.**

## 2. The framework

### 2.1 Server endpoint

New module `services/api/src/updates.rs`, one route wired into `main.rs` on
the **json** side (`json_routes`: gzip + 30s timeout + rate limit, the right
side for a small JSON response):

`GET /updates/latest`, authenticated, **any** authenticated user (viewers
run wall displays and phones too; this is deliberately not admin-only).
Response DTO (canonical serde shape in `services/api/src/dto.rs`,
component-map row A):

```json
{
  "enabled": true,
  "latest_version": "0.0.2",
  "notes_url": "https://github.com/badbread/crumbvms/releases/tag/v0.0.2",
  "published_at": "2026-07-20T00:00:00Z",
  "server_version": "0.0.1",
  "server_update_available": true,
  "checked_at": "2026-07-21T18:00:00Z"
}
```

- `enabled:false` ⇒ all other fields null; clients show nothing. (Returning
  200 with `enabled:false`, rather than 404, distinguishes "operator turned
  it off" from "old server".)
- `latest_version` is the newest release **tag without the `v` prefix** from
  `GET https://api.github.com/repos/badbread/crumbvms/releases/latest`.
  That GitHub endpoint already excludes pre-releases and drafts, so the
  signal is stable-releases-only by construction (D6).
- `server_version` / `server_update_available`: the api compares its own
  build version (the existing `/version` machinery, `CARGO_PKG_VERSION`)
  so the web console's notice needs zero logic. Client apps compare their
  OWN build version against `latest_version` locally.
- Fetch behavior: lazy fetch on demand with an in-memory cache
  (TTL 6 hours, stale-while-error: keep serving the last good value and
  never surface a GitHub outage to clients as an error, just an older
  `checked_at`). No background task needed, no persistence needed, cache
  dies with the process and that is fine. Honor GitHub rate-limit responses
  by backing off to the next TTL window (unauthenticated limit is 60/h/IP;
  a 6h TTL uses ~4/day).
- The request sends **nothing**: no query params, no client versions, no
  counts, no identifiers beyond the connection itself. Keep it that way,
  this is the line between "version check" and telemetry.
- Endpoint documented in the `config_routes.rs` doc-comment API tables (the
  reference until OpenAPI exists).

### 2.2 Version-compare semantics

- Versions are the release tags without `v` (`VERSION` file / tauri.conf /
  `version.properties` `VERSION_NAME` / the iOS project version all follow
  this already). Compare as SemVer 2.0.0 precedence; treat an unparsable
  version (dev builds like `0.0.1-dev`) as "never show the banner" rather
  than erroring.
- One tiny hand-rolled compare with unit tests per codebase that needs it
  (Rust once in `updates.rs`; a few lines each in JS/Kotlin/Swift). No new
  dependency for this (golden rule 6).
- Notice condition: `latest_version > own_version`, strictly. Equal or
  newer-local (dev tree) shows nothing.
- Android note: the `workflow_dispatch` re-ship path can bump `VERSION_CODE`
  without a new tag; that intra-version re-ship is invisible to this
  checker. Accepted, #7 is a version-level nicety, not a patch-level
  distribution system.

### 2.3 Operator control (the off switch)

House config precedence applies: admin-set DB `server_settings` values win
over env; empty DB value falls back to env.

- **Migration `0045_update_check.sql`**: add
  `update_check_enabled BOOLEAN` (nullable; NULL = fall back to env) to
  `server_settings`. `0044_beta_terms_acceptance.sql` is the current highest,
  so **0045 is the next free number**. **MUST be registered in the
  `MIGRATIONS` array in `services/common/src/db.rs`** (append after the 0044
  entry, ~line 7574); an unregistered migration silently never runs (golden
  rule 4). Nothing footage-adjacent; standard migration test pass suffices.
- **Env fallback key `UPDATE_CHECK_ENABLED`** (default per D3, recommended
  `true`), added to: `services/api/src/config.rs`, `.env.example`,
  `docker-compose.yml` api environment block, a `scripts/setup-env.sh`
  comment (no secret, nothing to generate), `docs/AI-INSTALL.md`, and
  `docs-site/docs/configuration/environment-reference.md` (component-map
  row B).
- **Admin console toggle** in the server-settings area of
  `services/api/src/admin.html`, with plain-language copy: "When enabled,
  this server periodically asks github.com for the latest CrumbVMS version
  number so clients can tell you when an update exists. Nothing is sent, and
  turning this off disables the check for every client." Console code writes
  only this field (house rule).
- Disabled means disabled: the api makes **zero** GitHub requests and the
  endpoint returns `enabled:false`. There is no other egress anywhere in
  this feature.

### 2.4 What this design deliberately does NOT need

Called out so implementers don't cargo-cult the heavier machinery:

- **No media tokens.** There is no artifact download; the endpoint is a
  small JSON route behind the normal bearer JWT. (The scoped `?token=`
  pattern is for media; it is not engaged here.)
- **No new volume, no artifact storage, no signing keys, no new secrets.**
- **No client-side GitHub HTTP code** (under the recommended D2 default).
- **No background task** in the api (lazy fetch + TTL cache).
- **No recorder changes of any kind.**

### 2.5 Manual check ("Check now")

A "Check now" affordance lets the operator force an immediate check instead of
waiting out the 6h TTL. It is a convenience on the SAME endpoint, not a new
egress path:

- **Server:** `GET /updates/latest?refresh=1` bypasses the TTL cache and
  performs one fresh GitHub fetch, then updates the cache. To protect GitHub's
  unauthenticated rate limit (60/h/IP) and stop many authenticated clients from
  stampeding it, the server enforces a **minimum interval between actual forced
  fetches** (60s); a `refresh=1` inside that window serves the cached value
  (with its existing `checked_at`) instead of hitting GitHub. Without `refresh`,
  behavior is exactly as §2.1 (serve cache within TTL).
- **Disabled still means zero egress.** When `update_check_enabled` resolves to
  off, `refresh=1` is ignored: the endpoint returns `enabled:false` and makes
  ZERO GitHub requests. The manual check is only live while the check is
  enabled. There is deliberately NO "one-off check while disabled" mode; it
  would muddy the zero-egress-when-disabled invariant for a nicety.
- **UI:** a "Check now" button in the admin console's update area and in each
  client's Settings/About update area, shown only when the check is enabled. It
  calls `refresh=1`, then refreshes the displayed status ("Checked just now,
  you're up to date" / "vX.Y.Z available → release notes"). Non-destructive, no
  new permission.

## 3. Per-client mechanism

All clients: check once shortly after login/launch and re-check at most
every 24h while running, against their own server's `GET /updates/latest`.
404 or `enabled:false` ⇒ show nothing. The notice is non-intrusive: a
dismissible row/badge in the Settings/About area (dismiss remembers the
dismissed version and stays quiet until a newer one appears), linking to
`notes_url` in the platform browser. No download buttons, no install flows.

| Client | Own version from | Notice surface | Notes |
|---|---|---|---|
| Web console (`admin.html`) | n/a, uses `server_update_available` | banner in the settings/system area: "Server v0.0.2 is available → release notes", plus the literal upgrade commands (`CRUMB_VERSION` pin + `docker compose pull`, per docs/IMAGES.md) | The console ships inside the api image, so its update IS the server update. Notify-only, the operator runs the upgrade; the server never updates itself. |
| Windows desktop (Tauri) | `tauri.conf.json` version via the Tauri API (`getVersion()`) | settings/about badge + dismissible banner in `apps/desktop/src/app.js` | Windows and Linux are one codebase and one task; a JS `fetch` via the existing authed helper, no Rust changes needed. |
| Linux desktop (Tauri) | same | same | Same code path. Release-notes link points at the GitHub release; Linux users build from source per docs/CLIENTS.md. |
| Android | `BuildConfig.VERSION_NAME` | Settings/About row + dismissible banner (Compose) | Plain repository call through the existing Retrofit stack. No `REQUEST_INSTALL_PACKAGES`, no download. |
| macOS | `CFBundleShortVersionString` | Settings row + banner | Shared `UpdateChecker` in `apps/ios/Crumb/Networking/`. |
| iOS | same | same shared code | **Lowest priority** (issue #7): once TestFlight/App Store distribution exists, the platform's own update flow supersedes this notice. Ships only because it is the same shared Swift code as macOS; may be feature-flagged off if distribution lands first. |

On the Tauri built-in updater (evaluated per the issue): **not used for #7.**
Its value is the install/relaunch machinery, exactly what #7 excludes; using
it only for detection would still demand its endpoint manifest format and
its signing keypair at build time, for a job a 20-line `fetch` + semver
compare does against `/updates/latest`. Reconsider it in the §6 future
extension, where install is actually in scope. (Decision point D4.)

## 4. Decision points for the maintainer

Each needs Jason's confirmation before the corresponding task starts.

- **D1, scope.** Confirm #7's notify-only scope is the deliverable and the
  full download/install system stays future work (§6). *Recommended: yes,
  as the issue states.*
- **D2, who talks to GitHub.** (a) Clients consume the api's
  `GET /updates/latest`, only the api contacts GitHub (*recommended*:
  single implementation, single cache, single off-switch that truly turns
  it off site-wide; the issue itself suggests this helper), vs (b) each
  client queries GitHub Releases directly (maintainer-ratified as
  acceptable; more resilient when the server is old or the check is
  disabled server-side, but five implementations, five switches, and every
  client device makes its own external calls). A hybrid (b-with-fallback)
  is not recommended: two code paths for a nicety.
- **D3, default state of the check.** *Recommended: enabled by default*,
  with the off-switch prominent in the admin console, the env fallback
  key, and disclosure in `docs/AI-INSTALL.md` (which otherwise promises
  LAN-only behavior, the runbook must mention this one opt-out egress
  explicitly). Rationale: the issue's whole "why" is that installs silently
  drift; a default-off check helps nobody who doesn't already watch GitHub.
  Alternative: default-off for a strictly zero-egress default posture, at
  the cost of the feature being invisible to exactly the operators it's
  for.
- **D4, Tauri built-in updater.** *Recommended: no for #7* (see §3).
- **D5, iOS inclusion.** *Recommended: include*, it is the same shared
  Swift checker as macOS at near-zero marginal cost, flagged lowest
  priority and droppable if TestFlight distribution lands first.
- **D6, release channels.** *Recommended: stable-only for #7* (the
  `releases/latest` GitHub endpoint gives this for free; pre-releases are
  invisible). Beta-channel awareness belongs to the §6 future extension if
  ever.

## 5. Propagation checklist (docs/COMPONENT-MAP.md walk)

Matching matrix rows, executed across the tasks in §7 (each task names its
slice):

- **Row A (new endpoint/DTO):** `updates.rs` + `main.rs` wiring (json side),
  `dto.rs` shape, auth via the standard authed extractor (any user),
  client mirrors (`admin.html` `api()` helper; desktop `app.js`; Android
  `CrumbApi.kt`/`CrumbRepository.kt`/`Models.kt`; iOS `Networking/` +
  `Models/`), tests, `config_routes.rs` doc-comment API table row.
- **Row B (new config key):** `UPDATE_CHECK_ENABLED` in `config.rs`,
  `.env.example`, `setup-env.sh` comment, `docker-compose.yml` api env
  block, `admin.html` server-settings toggle (DB precedence),
  `docs/AI-INSTALL.md`, docs-site environment reference.
- **Row C (migration):** `0045_update_check.sql` + `MIGRATIONS` registration
  in `services/common/src/db.rs`, workspace tests against a throwaway
  Postgres.
- **Row H (admin console):** `admin.html` toggle + server-update banner;
  `node --check` the extracted script; verify in a browser AND in the
  desktop's embedded `/admin` WebView.
- **Row I (install surface, golden rule 5):** because a config key and env
  default are added: `.env.example`, `setup-env.sh`, `docker-compose.yml`
  (sweep the variants that enumerate api env), `docs/AI-INSTALL.md` in the
  SAME change (including the D3 egress disclosure), README run path only if
  it enumerates env keys, smoke workflow stays green, `docker compose
  config` validated on a real Docker host. No new ports, volumes, services,
  or secrets, so no setup-secrets/TLS/backup impact.
- **Row L (user-visible capability):** `docs/CLIENTS.md` gains a short
  "knowing when to update" note per client; a docs-site operator page
  (or section) covering the notice, the off switch, and exactly what is and
  isn't sent; marketing update post when it ships (house copy rules).
- **Row M, REQUIRED:** a **`docs/DECISIONS.md` entry** lands with the Phase
  1 server change, matching the file's format: chosen (api-mediated
  GitHub version check, notify-only, operator-disableable), rejected
  (per-client direct GitHub polling as default; Tauri updater for
  detection; a server-hosted artifact/manifest system as the #7 vehicle,
  deferred to the future extension), trade-offs (old-server clients see
  nothing; version-level granularity misses Android re-ships), revisit
  triggers (auto-update demand materializes → §6; GitHub API terms/rate
  limits change; clients gain a legitimate need for direct checks).
  **`docs/COMPONENT-MAP.md` §3 parity table gains an "Update notice" row**
  in the same change (map maintenance rule).

## 6. Future extension (explicitly NOT #7)

Recorded so the notify-only scope is a decision, not an accident. A fuller
update system, IF ever demanded, would add: server-hosted release artifacts
(manual upload and/or opt-in GitHub mirroring into an api-RW volume),
sha256 + detached-signature (minisign/ed25519) verification before any
install, scoped short-lived `?token=` media-claims for artifact downloads
(never the bearer JWT), Android PackageInstaller handoff, a signed+notarized
macOS story (Sparkle or self-replace), Windows installer handoff (after
bundling `libmpv-2.dll` as a Tauri resource so an installer-driven update
cannot strand the exe without it), and update channels. Every piece of it
stays operator-approved, install is never automatic without explicit user
action, and the recorder is never auto-updated. None of this is designed
here; it gets its own issue, DECISIONS entry, and plan if a revisit trigger
fires (real operator demand for in-app install, or signed client builds
becoming the norm).

## 7. Phased task breakdown

Ground rules for every task: DCO sign-off; stage explicit paths only
(shared tree, never `git add <dir>`); match surrounding style. Rust
acceptance floor: `cargo fmt --all -- --check` +
`cargo clippy --all-targets -- -D warnings` + `cargo test --workspace`
(throwaway Postgres per AGENTS.md). Client tasks must compile and pass
their CI job. Default model **Sonnet**; nothing in this scope needs Opus
(no crypto, no install execution, no footage-adjacent code). Server PRs
reference `refs #7`; the PR that completes the last in-scope client carries
**`Closes #7`**.

### Phase 1, server (everything depends on S2)

- **S1 Migration + config key.** `db/migrations/0045_update_check.sql`
  (nullable `update_check_enabled` on `server_settings`), **register in
  `MIGRATIONS` in `services/common/src/db.rs`**, db get/update plumbing,
  `UPDATE_CHECK_ENABLED` in `config.rs`, precedence (DB wins, NULL falls
  back to env). Acceptance: Rust gate; migration applies on a fresh
  throwaway Postgres; precedence unit test. Sonnet, small.
- **S2 `GET /updates/latest`.** `services/api/src/updates.rs`: GitHub
  `releases/latest` fetch (existing HTTP client stack), 6h in-memory TTL
  cache with stale-while-error, semver compare + unit tests (including
  unparsable-version ⇒ no signal), the DTO in `dto.rs`, route wired on the
  json side of `main.rs` (any authenticated user), `enabled:false`
  short-circuit making zero external requests, `config_routes.rs` doc-table
  row. Acceptance: Rust gate; unit tests for compare/cache/disabled-path
  (GitHub mocked, tests must not hit the network); manual check on a dev
  stack that disabling the setting stops all egress (observe logs).
  Sonnet, medium.
- **S3 Admin console.** In `services/api/src/admin.html`: the settings
  toggle (writes only its own field) with the §2.3 plain-language copy, and
  the server-update banner ("Server vX.Y.Z available → release notes" +
  upgrade commands) driven by `/updates/latest`. House conventions
  (`esc()`, `api()`, every `on*=` handler defined, semantic color vars).
  Acceptance: `node --check` on the extracted script block; rebuilt api
  serves it; banner verified in a browser AND in the desktop's embedded
  `/admin` WebView (fake a newer release by stubbing the fetch or pointing
  at a test double, do not tag a release to test). Sonnet, medium.
- **S4 Install surface + docs floor.** `.env.example`, `setup-env.sh`
  comment, `docker-compose.yml` api env (+ variant sweep), `docs/AI-INSTALL.md`
  (key + the one-egress disclosure per D3), docs-site environment-reference
  row. Acceptance: `docker compose config` clean on a real Docker host (the
  build/prod host); smoke workflow green; AI-INSTALL "For maintainers" items
  re-verified. Sonnet, small.
- **S5 Decision log + component map.** The `docs/DECISIONS.md` entry and
  `docs/COMPONENT-MAP.md` "Update notice" parity row per §5 row M, in the
  same change series as S1–S4. Acceptance: entries match the files'
  existing formats. Sonnet or Haiku, small.

### Phase 2, clients (mutually independent, parallel after S2)

- **C1 Web console client notice.** Already covered by S3 (the console's
  update IS the server update); listed to make the parity walk explicit.
  No separate task.
- **C2 Desktop (Windows + Linux, one task).** In `apps/desktop/src/app.js`:
  post-login fetch of `/updates/latest` via the existing authed helper,
  compare against `getVersion()`, dismissible settings/about banner
  (remember dismissed version), 24h re-check, 404/`enabled:false` ⇒
  nothing. No Rust changes expected. Acceptance: CI `desktop-lint` +
  `desktop-linux` green; banner verified on the workstation after a REBUILD
  (Tauri bakes `../src` into the exe, a stale exe proves nothing) against a
  dev server stubbed to report a newer version. Sonnet, medium.
- **C3 Android.** Retrofit method in `CrumbApi.kt`, repository +
  `Models.kt` mirror, compare against `BuildConfig.VERSION_NAME`,
  dismissible Settings/About banner (Compose), daily re-check, notes link
  opens the browser. Acceptance: Gradle build + existing checks green
  (build on dev hosts per house setup); banner verified on-device
  (wireless ADB) against a stubbed-newer dev server. Sonnet, medium.
- **C4 macOS + iOS (shared).** `UpdateChecker` in
  `apps/ios/Crumb/Networking/` + `Models/` mirror, Settings row + banner in
  both targets, compare against `CFBundleShortVersionString`, iOS flagged
  lowest-priority per D5. Acceptance: both targets build on the macmini
  (`scripts/release/ios.sh` path); banner verified on macOS against a
  stubbed-newer dev server. Sonnet, medium.

### Phase 3, docs + announcement

- **P1 User docs.** `docs/CLIENTS.md` "knowing when to update" notes,
  docs-site operator section (what the notice is, the off switch, "nothing
  is sent"), README line if warranted. Acceptance: docs-site CI build green
  (`onBrokenLinks: 'throw'`); plain user-facing language, house copy rules
  (no em-dashes). Sonnet or Haiku, small.
- **P2 Marketing update post** when the first clients ship it
  (`site/updates/posts/` + `node scripts/build.mjs`, commit sources AND
  generated output; capability-first humble tone). Haiku or Sonnet, small.

### Dependency spine

```
S1 → S2 → { S3(+C1), C2, C3, C4 }   (all parallel after S2)
S4 parallel with S2/S3 (needs S1's key name)
S5 lands with Phase 1
P1/P2 last; the final client PR carries "Closes #7"
```
