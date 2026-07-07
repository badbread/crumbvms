<!--
Thanks for contributing to CrumbVMS! Please read CONTRIBUTING.md if you
haven't. Fill out the sections below and complete the checklist.
-->

## Summary

<!-- What does this PR do, and why? Link any related issue (e.g. "Closes #123"). -->

## Changes

<!-- Bullet the notable changes. -->

-

## How this was tested

<!-- Commands run, manual verification, cameras/clients exercised, etc. -->

## Checklist

- [ ] **CI is green locally**, `cargo fmt --all -- --check`,
      `cargo clippy --all-targets -- -D warnings`, and `cargo test --workspace`
      all pass.
- [ ] **Every commit is signed off (DCO)**, `Signed-off-by:` trailer via
      `git commit -s`. See [CONTRIBUTING.md](../CONTRIBUTING.md).
- [ ] **Install docs updated if needed**, if this change touches the
      install/config surface (`docker-compose*.yml`, `.env.example` /
      `scripts/setup-env.sh` keys, first-run flow, images, TLS/Caddy, backups,
      notifications), I updated [docs/AI-INSTALL.md](../docs/AI-INSTALL.md) and
      the README manual path in the same PR. *(Standing repo rule.)*
- [ ] Tests added/updated for changed behavior where it makes sense.
- [ ] No secrets, tokens, or real host/camera IPs in the diff.
