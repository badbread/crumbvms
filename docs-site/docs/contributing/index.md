---
title: Contributing
sidebar_label: Overview
slug: /contributing/
---

# Contributing

Crumb is solo-maintained and free and open source, licensed
AGPL-3.0-or-later, forever: no paid tier, no license enforcement, no
open-core split. Thoughtful contributions are welcome, bug fixes, tests,
documentation, and well-scoped features alike.

## Before you start

For anything larger than a small fix, open an issue first to discuss
approach and fit. Bug reports and small fixes are the most valuable and
easiest-to-merge contributions; large unsolicited feature pull requests
are harder to review and may not match the project's direction, so
discussing first saves everyone time.

Report security vulnerabilities privately, see
[Security reporting](/contributing/security), never in a public issue.

## Building and running

The codebase is a Rust workspace plus native clients and a web console:

```
services/   # Rust workspace: common, api, recorder (api also serves /admin)
apps/       # desktop-flutter (Flutter + Rust core, media_kit/libmpv), Android (Kotlin/Compose), iOS/macOS (SwiftUI)
db/         # numbered SQL migrations, applied automatically on boot
docs/       # design specs and runbooks
```

To stand up a working instance, follow
[Install with Docker Compose](/getting-started/install-docker-compose).

## The CI gate

Every pull request runs the same checks as CI, and they're worth running
locally before you push:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --workspace
```

Clippy warnings are treated as errors, so a clean `clippy` run is required,
not just a green `test`. The integration tests need a Postgres instance to
talk to; a throwaway one works fine for local runs.

## Coding conventions

- Match the surrounding code's style rather than importing a different
  convention.
- Keep changes focused, one logical change per pull request.
- Add or update tests for behavior you change. The recording and motion
  paths in particular carry extra scrutiny, since losing footage is
  considered the one unforgivable bug in this project.
- If your change touches how a fresh install is stood up or configured,
  update the install runbook in the same change. This is a standing repo
  rule.

## AI-assisted contributions

AI-assisted pull requests are welcome, much of Crumb is built that way. Two
things don't change with AI in the loop: you own the contribution, review
and understand what a session produced before opening a pull request, and
the same gate, conventions, and install-guide rule apply to generated code
exactly as to hand-written code.

## Contributor License Agreement

Before code is merged, contributors are asked to agree to a Contributor
License Agreement, the standard Apache Individual CLA v2.0, adopted as is.
You keep full ownership of your contributions; the CLA lets the project
keep its own licensing coherent, staying AGPL-3.0 for everyone. Signing is
one comment on your first pull request, an automated check posts a link
and a one-line statement to reply with.

Commits also carry a lightweight Developer Certificate of Origin
sign-off, added with `git commit -s`.
