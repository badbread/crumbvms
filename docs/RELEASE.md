# Crumb, Release, Deploy & Rollback

How Crumb goes from a git commit to a known, versioned, deployable, and
*rollback-able* artifact.

> **Building/deploying all clients at once** (backend + Android + iOS over SSH to
> configured build hosts) is handled by the orchestrator in
> [../scripts/release/](../scripts/release/README.md): `bash scripts/release/release.sh all`.

---

## TL;DR

- **CI** (`.github/workflows/ci.yml`) runs on every push/PR to `main`: Rust
  `fmt`/`clippy`/`build`/`test`, then builds the `recorder` and `api`
  Docker images, tagging each with the **git short SHA** (and the **version** on
  a `v*` git tag).
- **Versioning**: a release is a git tag `vMAJOR.MINOR.PATCH`. The tag's images
  carry that version tag.
- **Deploy**: set `CRUMB_IMAGE_PREFIX` + `CRUMB_VERSION` in
  `.env` and `docker compose pull && up -d`, no source, no local build.
- **Rollback**: set `CRUMB_VERSION` back to the previous tag, `pull && up -d`.

---

## Images & tags

`docker-compose.yml` references images as:

```
${CRUMB_IMAGE_PREFIX:-ghcr.io/badbread/crumbvms}/recorder:${CRUMB_VERSION:-latest}
${CRUMB_IMAGE_PREFIX:-ghcr.io/badbread/crumbvms}/api:${CRUMB_VERSION:-latest}
```

(The web admin console ships inside the `api` image; there is no separate `web`
image.)

- **Unset (default)** → pull `ghcr.io/badbread/crumbvms/recorder:latest` from
  GHCR (no local compile). See `docs/IMAGES.md`.
- **Build from source instead** → add the build override
  (`docker-compose.build.yml`), which retags the result `crumbvms/<svc>:local`.
- **Point at another registry/version** → e.g.
  `ghcr.io/acme/crumbvms/recorder:v1.2.0`.

CI tags every image with:

| Trigger                | Tags produced                          |
|------------------------|----------------------------------------|
| push to `main`         | `sha-<short>`, `latest`                |
| git tag `v1.2.0`       | `sha-<short>`, `v1.2.0`                |
| pull request           | `sha-<short>` (build only, never pushed)|

The short-SHA tag means every build is traceable to an exact commit, even
between releases.

---

## Cutting a release

1. Land changes on `main` (CI green: fmt, clippy, build, test, images build).
2. Tag and push:
   ```bash
   git tag -a v1.2.0 -m "Crumb v1.2.0"
   git push origin v1.2.0
   ```
3. CI builds `recorder` and `api` and tags them `v1.2.0` (+ short SHA). If a
   registry is configured (below), they're pushed; otherwise they're built and
   validated but not pushed.

Use [semver](https://semver.org/): bump PATCH for fixes, MINOR for
backward-compatible features, MAJOR for breaking changes (e.g. a DB migration
that isn't backward compatible, call those out in release notes).

---

## Registry configuration (optional, non-fatal if absent)

CI does **not** hard-fail when no registry is configured, it still builds and
validates the images, it just doesn't push. To enable pushing:

- **GHCR (simplest)**, set a repository/org **variable** `REGISTRY` to
  `ghcr.io/<owner>/crumbvms`. CI logs in with the built-in `GITHUB_TOKEN`
  (needs `packages: write`, already granted in the workflow) and pushes.
- **Other registry (ECR, Docker Hub, Artifactory)**, set:
  - variable `REGISTRY` = `<registry-host>/<namespace>/crumbvms`
  - variable `REGISTRY_HOST` = the login host (e.g. `registry-1.docker.io`)
  - secrets `REGISTRY_USERNAME` / `REGISTRY_PASSWORD`

Until then, releases are reproducible from source: any tagged commit can be
checked out and built with `docker compose -f docker-compose.yml -f
docker-compose.build.yml build`.

---

## Production deploy

On the Crumb host (`/opt/crumb/app`):

```bash
# One-time: configure where images come from and which version to run.
# In .env:
#   CRUMB_IMAGE_PREFIX=ghcr.io/badbread/crumbvms
#   CRUMB_VERSION=v1.2.0

cd /opt/crumb/app
# Always back up the index before changing versions (migrations may run):
scripts/backup-db.sh

docker compose pull            # fetch the pinned version's images
docker compose up -d           # recreate changed services only

docker compose ps              # confirm healthy
docker compose logs --tail=50 api recorder
```

Notes:
- The api/recorder embed a migration runner (`crumb_common::db::run_migrations`)
  that is the **single** source of truth for the schema. On every startup it
  applies any not-yet-applied `db/migrations/*.sql` in filename order and records
  each in a `schema_migrations` table, fresh install and upgrade alike, so adding
  a migration in a new version applies automatically on deploy. (The bundled
  `postgres` deliberately does **not** also apply the SQL via
  `/docker-entrypoint-initdb.d`: that ran the SQL without recording it, so the
  runner then misfired its first-run baseline and failed to re-apply the view
  migrations, a broken 18/44 schema on a fresh boot.) Still back up the DB before
  deploying, and call out breaking/non-additive migrations in release notes.
- If you deploy by building from source instead of pulling, add the build
  override (the base file has no `build:` stanza, so a plain `up -d --build`
  compiles nothing): `docker compose -f docker-compose.yml -f
  docker-compose.build.yml up -d --build`. That override tags the result
  `crumbvms/<svc>:local` regardless of `CRUMB_VERSION`.

---

## Rollback

Versioned images make rollback a one-liner. To go from `v1.2.0` back to `v1.1.0`:

```bash
cd /opt/crumb/app
# In .env: CRUMB_VERSION=v1.1.0
docker compose pull
docker compose up -d
docker compose ps
```

**Caveat, database migrations are not auto-reversed.** If the version you're
rolling *away from* applied a schema migration, rolling the images back does not
undo it. Options:
1. Prefer backward-compatible (additive) migrations so an older binary still runs
   against the newer schema (the common case).
2. If a migration is breaking, treat rollback as a restore: stop services,
   `scripts/restore-db.sh` the pre-upgrade backup (that's why we back up before
   every deploy), then `docker compose up -d` on the old version.

Keep at least the last two released versions' images available (don't prune the
registry aggressively) so rollback is always one `pull` away.

---

## Local / dev builds

Nothing above is required for development. To build from source instead of
pulling images, add the build override:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
# builds crumbvms/<svc>:local from source
```

See `docs/IMAGES.md` for the pull-vs-build details.
