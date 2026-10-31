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
#   CRUMB_VERSION=v0.3.0

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

## Notes for 0.2.0 to 0.3.0

An in-place upgrade from the v0.2.0 published images was tested end to end, and
so was rolling back. `.env` needs no changes: every new key is optional. The
four new migrations applied once each on first boot, footage came through
byte-identical, recording carried on, and devices that were signed in stayed
signed in. Upgrade the server before the clients; a 0.3.0 desktop's "Open in
browser" needs a 0.3.0 server.

Five things can need action, depending on your setup:

- **You scrape `/metrics`.** It now needs a credential and answers 401 without
  one. Set `METRICS_TOKEN` (for example `openssl rand -hex 32`) and give your
  Prometheus job a matching `bearer_token`, or use an admin session token.
  `/health` and `/version` stay open.
- **You run your own reverse proxy with `TRUST_PROXY=1`.** `X-Forwarded-For`
  is now read only from addresses in `TRUSTED_PROXIES`, which defaults to the
  bundled Caddy. Behind nginx, Traefik, or similar, set `TRUSTED_PROXIES` to
  that proxy's address as the api sees it, or every user behind it shares one
  rate-limit and login-backoff key. The bundled Caddy needs nothing.
- **Your database password is still the example value.** The api now refuses
  to start while `DATABASE_URL`'s password is `change-me`, as it already did for
  the other placeholder secrets. The recorder keeps recording meanwhile. Change
  it in Postgres first (`docker compose exec postgres psql -U crumb -c "ALTER
  USER crumb WITH PASSWORD '<new>';"`), then in both `POSTGRES_PASSWORD` and
  `DATABASE_URL`, then `docker compose up -d`. An `.env` from
  `scripts/setup-env.sh` already has a generated password.
- **Exports fail with "Permission denied".** An export volume created by an
  earlier image is owned by root, which the api cannot write, so exports, the
  clip cache, and scrub previews all fail (#692). Fresh installs get a writable
  volume now, and the api logs one clear error at boot when it finds the old
  one. Fix it once with `docker compose exec -u root api chown 1001:1001
  /exports`.
- **Non-admin users managed notification channels.** That is now the
  `manage_channels` role permission, which migration 0081 adds switched off for
  every non-admin role. Grant it to the roles that should keep it. Existing
  channels keep delivering either way.

Worth knowing, no action needed:

- **The macOS app 0.2.0 cannot download finished exports** from a 0.3.0
  server, because it was the last client sending the login token in the URL.
  Update the Mac app; until then, finished exports download from the web
  console. The Windows and Android apps are unaffected.
- **Account changes now reach signed-in devices.** Removing a user, or changing
  their password or role, signs out their devices at once.
- **Limits that did not exist before:** one export covers at most a day per
  camera (`EXPORT_MAX_RANGE_SECONDS`) and 50 cameras; a protected bookmark's
  window is capped at one hour in total, so a 60 minutes before plus 60 after
  request is scaled to 30 and 30; non-admin users can hold 50 active protected
  bookmarks (`BOOKMARK_MAX_PROTECTED_PER_USER`). A busy media queue now answers
  "retry" instead of hanging.
- **Notification channels no longer follow redirects.** A channel saved as
  `http://` for a server that redirects to `https://` needs its address updated.
- **Notification text uses the server's time zone.** Compose defaults `TZ` to
  UTC; `scripts/setup-env.sh` sets your host's zone.
- **If you changed `rtsp.listen` in `go2rtc/go2rtc.yaml`,** set
  `CRUMB_GO2RTC_LOOPBACK_PORT` to match. The recorder now dials its embedded
  go2rtc over loopback on 8554 unless told otherwise.
- **The console can no longer be framed by another site** (for example a Home
  Assistant iframe panel). The desktop app is unaffected.
- **First boot can take a little longer** on a large events table while
  migrations 0082 and 0083 build their indexes.
- **Take a database backup first**, as with
  any upgrade.
- **Rolling back was rehearsed**: pinning `CRUMB_VERSION=v0.2.0` and
  `docker compose up -d` brought 0.2.0 up healthy on the 0.3.0 schema, serving
  the same footage. The new migrations are additive. You lose the new features,
  not the footage, and `/metrics` is open again.

## Notes for 0.1.1 to 0.2.0

This one was tested end to end as an in-place upgrade from the published
v0.1.1 images. It is a drop-in: `.env` needs no changes, the new migrations
(0072 through 0080) apply in a single pass on first boot, footage came
through byte-identical, and logins, roles, policies, and the authenticated
RTSP restream default were all intact afterwards. Four things are worth
knowing before you run it.

**No new required settings.** `GO2RTC_AUTH` is the only new key, and leaving
it unset keeps the secure default: the LAN RTSP restream stays
authenticated.

**`MOTION_HWACCEL` behaves differently, but your setting does not change.**
A new install now defaults to `cpu`. An `.env` generated by 0.1.1 contains an
explicit `MOTION_HWACCEL=auto`, so upgrading leaves you on `auto`, and that is
fine now. `auto` used to ask only whether cuda was compiled into ffmpeg, which
is true on every host running the published image, so on a GPU-less machine it
picked NVDEC and motion never decoded a frame. It now opens a real cuda device
at startup and resolves to `cpu` when that fails, times out, or cannot start,
and a backend that decodes nothing is demoted to CPU for that camera with the
reason shown in the console's decode-status panel. To move to the new default
anyway, set `MOTION_HWACCEL=cpu` in `.env` and bring the recorder back up, or
leave the console's hardware-decode field blank. If you have a GPU you want
used, name it (`cuda` or `vaapi`) rather than relying on `auto`.

**Non-admin roles cannot control Home Assistant devices** until you grant
them the new `actuators` capability in the console. Migration 0074 adds it
default-off to every existing role, so nobody gains the ability to unlock a
door merely by upgrading. Admins are unaffected.

**Motion health is a new surface.** Cameras that were quietly degraded before
will start reporting it, most often a camera with no sub-stream. That is the
feature working rather than the upgrade breaking something.

Rolling this one back should be the plain compose steps below: every new
migration is additive, so 0.1.1 runs against the 0.2.0 schema and you lose
the new features, not the footage. That is reasoning from the migrations, not
a rehearsed procedure, so take the backup.

## Rollback

Versioned images make rollback symmetrical with upgrade:

```bash
cd /opt/crumb/app

# In .env, set CRUMB_VERSION back to the previous tag, e.g. v0.1.1

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
