# Contributing to CrumbVMS

Thanks for your interest in CrumbVMS. It's a self-hosted, operator-grade NVR
built by one maintainer, and thoughtful contributions are welcome, bug fixes,
tests, docs, and well-scoped features alike.

CrumbVMS is licensed **AGPL-3.0-or-later**. By contributing, you agree your
work is contributed under that license.

## Project direction

CrumbVMS is **solo-maintained**. Bug reports and small fixes are very welcome —
they're the most valuable contributions and the easiest to merge. For anything
larger, **open an issue first** to discuss fit and direction before you build;
big unsolicited feature PRs are hard to review and may not match where the
project is headed, so they can be declined. This keeps the review load
sustainable for one person and the codebase coherent.

## Before you start

- For anything larger than a small fix, **open an issue first** to discuss the
  approach. It saves you from building something that doesn't fit, and it lets
  us flag overlap with in-flight work.
- Report **security vulnerabilities privately**, see [SECURITY.md](SECURITY.md),
  not the public issue tracker.

## Building and running

CrumbVMS is a Rust workspace plus native clients and a web console:

```
services/   # Rust workspace: common, api, recorder (api also serves /admin)
apps/       # desktop (Tauri + libmpv), android (Kotlin/Compose), ios
db/         # numbered SQL migrations, applied on boot
docs/       # design specs and runbooks
```

To stand up a working instance, follow **[docs/AI-INSTALL.md](docs/AI-INSTALL.md)**
(the agent-runnable, secure-by-default install runbook) or the manual path in
the [README](README.md#run): `scripts/setup-env.sh` → `docker compose up -d` →
`http://<host>:8080/admin`. We don't duplicate install steps here, that
runbook is the single source of truth.

### Client build notes (high level)

- **Desktop** (`apps/desktop`): Tauri + WebView2 shell over native libmpv. On
  Windows, `libmpv-2.dll` must sit next to the built exe or the video panes
  render black.
- **Android** (`apps/android`): Kotlin / Jetpack Compose / Media3, built with
  Gradle (JDK 21, SDK 34).
- **iOS** (`apps/ios`): Swift; still partial and gated on further work.

Each client's manifests (`Cargo.toml`, `build.gradle.kts`, Swift package files)
are the authoritative source for toolchain versions and dependencies.

## The CI gate

Every pull request must pass the same checks CI runs
(see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)). Run them locally
before you push:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --workspace
```

Clippy warnings are treated as errors (`-D warnings`), so a clean `clippy` run
is required, not just a green `test`.

The integration tests need a Postgres to talk to. A throwaway one:

```bash
docker run -d --name crumb-test-pg -e POSTGRES_PASSWORD=test \
  -e POSTGRES_DB=crumb -p 127.0.0.1:5442:5432 postgres:16-alpine
DATABASE_URL=postgres://postgres:test@localhost:5442/crumb cargo test --workspace
docker rm -f crumb-test-pg
```

## AI-assisted contributions

AI-assisted PRs are welcome, much of CrumbVMS is built that way. The repo ships
an agent guide, **[AGENTS.md](AGENTS.md)**, that Claude Code loads automatically
(via `CLAUDE.md`) and other tools (Codex, Cursor, …) read directly. It carries
the project's ratified direction and golden rules, secure by default, recorder
correctness, the CI gate, migration registration, install-guide sync, so an AI
session starts on the same page as the maintainer. If you use an AI tool that
reads neither file, paste `AGENTS.md` into its context yourself.

Two things don't change with AI in the loop:

- **You own the contribution.** Review and understand what your session
  produced before opening a PR, "the AI wrote it" doesn't survive review, and
  your CLA and commit sign-off certify *you* have the right to submit it.
- The gate, the conventions, and the install-guide rule apply to generated code
  exactly as to handwritten code.

## Coding conventions

- **Match the surrounding code.** Follow the style, naming, and structure of the
  file you're editing rather than importing a different convention.
- Keep changes focused. One logical change per PR makes review tractable.
- Add or update tests for behavior you change, the recorder and motion paths in
  particular are covered by unit/golden tests; keep them green.
- **Keep the install guide honest.** If your change touches how a fresh install
  is stood up or configured, `docker-compose*.yml` (services, ports, volumes,
  required secrets), `.env.example` / `scripts/setup-env.sh` keys, the first-run
  flow, image pull-vs-build, TLS/Caddy, backups, or notifications/monitoring —
  update [docs/AI-INSTALL.md](docs/AI-INSTALL.md) (and the README manual path)
  in the **same** change. This is a standing repo rule; PRs that drift from it
  will be asked to fix it.

## Contributor License Agreement (CLA)

Before your code is merged, CrumbVMS asks you to agree to a **Contributor License
Agreement**. It's the standard [Apache Individual CLA v2.0](CLA.md), adopted
as-is. **You keep full ownership** of your contributions, the CLA grants the
Project a broad, sublicensable license so CrumbVMS can keep its own licensing
coherent and future-proof (it stays AGPL-3.0 for everyone). This is normal for a
solo-maintained project and protects both you and the users.

**Signing is one comment, once.** On your first pull request, an automated CLA
check posts a link to [CLA.md](CLA.md) and a one-line statement to reply with.
Post that comment and you're signed, for that PR and every future one, tied to
your GitHub account. No forms, no email, no printing.

Full text: **[CLA.md](CLA.md)**.

### Commit sign-off (retained)

We also keep the lightweight **Developer Certificate of Origin** sign-off as a
per-commit origin certification. Every commit carries a `Signed-off-by` trailer
matching the commit author, add it with `-s`:

```bash
git commit -s -m "Fix segment index race on boot"
```

The full DCO text lives in the [DCO](DCO) file. Forgot it?
`git commit --amend -s --no-edit`, or `git rebase --signoff <base>` for a whole
branch.

## Pull requests

Use the [pull request template](.github/pull_request_template.md). Before you
open a PR, confirm:

- CI checks pass locally (`fmt` / `clippy -D warnings` / `test`).
- You've signed the [CLA](CLA.md) (one comment on your first PR, the bot
  prompts you).
- Every commit is `Signed-off-by` (`-s`).
- `docs/AI-INSTALL.md` (and the README manual path) is updated if your change
  touched the install/config surface.

Thanks for helping make CrumbVMS better.
