# CrumbVMS, Prebuilt Images (pull, don't compile)

`docker-compose.yml`'s `api` and `recorder` services are Rust binaries. Building
them from source is a real compile (dependencies + two release binaries), fine
for a developer, painful for someone who just wants to try CrumbVMS. This doc
covers the default (pull a prebuilt image), how to pin a version, how to build
from source instead, and the one-time step the *owner* of a fork/deployment must
do before strangers can pull.

See also: [`docs/RELEASE.md`](RELEASE.md) (tagging/versioning/rollback) and
[`docs/AI-INSTALL.md`](AI-INSTALL.md) (the guided install runbook).

---

## The default: pull

A stock `docker-compose.yml` has **no `build:` stanza** on `api`/`recorder` —
only `image:`:

```yaml
image: ${CRUMB_IMAGE_PREFIX:-ghcr.io/badbread/crumbvms}/api:${CRUMB_VERSION:-latest}
image: ${CRUMB_IMAGE_PREFIX:-ghcr.io/badbread/crumbvms}/recorder:${CRUMB_VERSION:-latest}
```

So the zero-edit path is:

```bash
./scripts/setup-env.sh   # writes .env with strong generated secrets
docker compose pull       # fetches api/recorder (+ postgres/caddy/etc.) images
docker compose up -d      # boots; create your admin in the browser at /admin
```

No Rust toolchain, no local compile, no waiting on `cargo build --release`.

### Pinning a version

Set both in `.env` (see `.env.example`):

```
CRUMB_IMAGE_PREFIX=ghcr.io/badbread/crumbvms
CRUMB_VERSION=v1.2.0
```

Then `docker compose pull && docker compose up -d`. Leaving `CRUMB_VERSION`
unset tracks `latest` (whatever's newest on `main`), fine for trying CrumbVMS out,
but pin an explicit `vX.Y.Z` for a production deployment so upgrades are a
deliberate, reproducible action (and rollback is just setting the var back).
See [`docs/RELEASE.md`](RELEASE.md#rollback) for the rollback procedure.

`CRUMB_IMAGE_PREFIX` also lets you point at a **different** registry/namespace
entirely, e.g. your own fork's GHCR path, a private registry mirror, or a
self-hosted registry, with no compose edits.

---

## Building from source instead

Use this if you're developing CrumbVMS, running air-gapped, or the images
described above aren't published yet (see "Owner seam" below). Layer the build
override on top of the base file:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

`docker-compose.build.yml` re-adds `build: {context: ., dockerfile:
services/<svc>/Dockerfile}` for `api` and `recorder`, and re-tags the result
`crumbvms/<svc>:local` so it never collides with a pulled registry tag. Nothing
else in the stack changes, postgres, caddy, mosquitto, and the backup
sidecar are unaffected either way. (The go2rtc restreamer is embedded in the
recorder image itself, its pinned binary is copied in at build time, so
there is no separate go2rtc image to pull or build.)

Rebuilding after a code change:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml build api recorder
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d
```

Tip: copy `docker-compose.build.yml` to `docker-compose.build.local.yml`
(gitignored) if you want to tweak it without touching the committed file.

---

## Owner seam: enabling GHCR publishing

**Until this is done, the default `docker-compose.yml` has nothing to pull** —
anyone running from this repo today must use the build override above. This is
the one manual step that flips the default over to "pull, don't compile" for
everyone downstream.

CI (`.github/workflows/ci.yml`, the `images` job) already builds `api` and
`recorder` on every push/PR and is *capable* of pushing them to GHCR, it just
doesn't push until told where. To enable it:

1. **Set the `REGISTRY` repository (or org) variable** to
   `ghcr.io/badbread/crumbvms`, GitHub repo → Settings → Secrets and variables →
   Actions → Variables → New repository variable → name `REGISTRY`, value
   `ghcr.io/badbread/crumbvms`. (This intentionally matches
   `docker-compose.yml`'s default `CRUMB_IMAGE_PREFIX`, so a fresh install's
   `docker compose pull` finds the right images with zero config.)
2. **Push to `main` (or push a `v*` tag)**, CI's `images` job logs into GHCR
   with the built-in `GITHUB_TOKEN` (already granted `packages: write` in the
   workflow) and pushes:
   - every push to `main` → tags `sha-<short>` + `latest`
   - every `v*` tag → tags `sha-<short>` + the version (e.g. `v1.2.0`)
   - pull requests → build-only, never pushed (tags computed but `push: false`)
3. **Make the GHCR packages public.** By default, packages pushed by CI to a
   *private* repo are created **private**, an anonymous `docker pull` will
   403. Go to the package page (github.com/badbread?tab=packages, or the
   package's own page after the first push → Package settings) for both
   `crumb/api` and `crumb/recorder`, and change visibility to **Public**. Do
   this for each image the first time it's created; it doesn't need repeating
   on later pushes to the same package.
4. **Optional but recommended:** link the packages to the repo (Package
   settings → "Connect Repository") so they show up on the repo's sidebar and
   inherit repo-level access notes.

Until steps 1–3 are done, CI still builds and validates the images every run
(so nothing is untested), it just keeps them local to the runner
(`docker/build-push-action`'s `load: true` path) instead of publishing them.
See the "Resolve registry + push policy" step in `ci.yml` for the exact
fallback logic.

### Other registries (not GHCR)

The same job supports any OCI registry: set the `REGISTRY` variable to
`<registry-host>/<namespace>/crumb`, plus a `REGISTRY_HOST` variable (the login
host, if different from `ghcr.io`) and `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`
secrets. See the `Log in to registry` step in `ci.yml`. Then set matching
`CRUMB_IMAGE_PREFIX` values in downstream `.env` files.

---
