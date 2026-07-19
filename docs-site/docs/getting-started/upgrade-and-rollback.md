---
title: Upgrade and rollback
sidebar_label: Upgrade and rollback
slug: /getting-started/upgrade-and-rollback
---

# Upgrade and rollback

Crumb releases are versioned images: a git tag `vMAJOR.MINOR.PATCH` produces
`api` and `recorder` images tagged with that version. Upgrading is a matter
of pointing `.env` at a newer version and pulling; rolling back is the same
in reverse.

## Upgrading

```bash
cd /opt/crumb/app   # or wherever your docker-compose.yml lives

# Back up first: migrations may run as part of the upgrade.
scripts/backup-db.sh

# In .env, pin the version you want (the image prefix already defaults to
# the public ghcr.io/badbread/crumbvms, so leave CRUMB_IMAGE_PREFIX alone
# unless you run a fork on a different registry):
#   CRUMB_VERSION=v0.1.0

docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=50 api recorder
```

Migrations are applied automatically. The `api` and `recorder` containers
each embed a migration runner that is the single source of truth for the
database schema: on every startup it applies any migration not yet marked
as applied, in order, and records it. This runs the same way on a fresh
install and on every upgrade, so a new version that ships a migration
applies it without a separate step. Still back up before upgrading, and
treat any release that calls out a non-additive migration with extra
care (see Rollback below).

If you're building from source rather than pulling images, leave
`CRUMB_VERSION` unset and layer in the build override:
`docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build`.
(The base `docker-compose.yml` has no `build:` stanza, so a plain
`docker compose up -d --build` rebuilds nothing and just runs the pulled
images.)

## Rollback

Versioned images make rollback symmetrical with upgrade:

```bash
cd /opt/crumb/app

# In .env, set CRUMB_VERSION back to the previous tag, e.g. v0.1.0

docker compose pull
docker compose up -d
docker compose ps
```

**The one caveat is database migrations are not automatically reversed.**
Rolling the container images back does not undo a schema change the
now-newer version applied. In practice:

- Most migrations are additive (new nullable columns, new tables), so an
  older binary keeps working fine against a newer schema, and rollback is
  just the compose steps above.
- If a specific release's migration is genuinely breaking, rolling back
  means treating it as a restore: stop the services, restore the
  pre-upgrade database backup you took before upgrading, then bring the
  older version up against the restored database.

This is exactly why the upgrade steps above start with a backup, and why
keeping at least the last couple of released image versions available (not
aggressively pruning a registry) keeps rollback a one-`pull` operation
rather than a rebuild-from-source scramble.

## Versioning

Releases follow [semver](https://semver.org/): patch releases are fixes,
minor releases add features without breaking compatibility, and major
releases may include a breaking change, called out explicitly in the
release notes when a migration isn't backward compatible.

## Local and development builds

None of the above is required for day-to-day development. Layering in the
build override,
`docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build`,
builds and runs local images from source. With `CRUMB_VERSION` left unset
and no override, a plain `docker compose up -d` pulls the published `:latest`
images instead.
