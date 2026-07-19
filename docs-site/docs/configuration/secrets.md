---
title: Secrets
sidebar_label: Secrets
slug: /configuration/secrets
---

# Secrets

Crumb never invents, hardcodes, or logs secrets. Every secret a fresh
install needs is generated for you.

## What gets generated

Running `scripts/setup-env.sh` writes a gitignored `.env` containing:

- **`POSTGRES_PASSWORD`**, generated with `openssl rand -hex 32`.
- **`JWT_SECRET`**, also 32 random bytes, used to sign the API's session
  tokens. The API refuses to start if this is left at the placeholder value
  from `.env.example`.
- **`GO2RTC_USER`** (a fixed, non-secret label) and **`GO2RTC_PASS`**
  (a generated secret), the Basic-auth and RTSP-auth credentials for
  Crumb's embedded restreamer.
- **`SEED_ADMIN_PASSWORD`**, a memorable passphrase like `IcyApples473`,
  generated for your admin account and **printed once** at the end of the
  `setup-env.sh` run. Write it down. It also lives in `.env` as
  `SEED_ADMIN_PASSWORD`, so you can always read it back later.

The script refuses to overwrite an existing `.env` unless you pass
`--force`, so re-running it by accident won't silently rotate secrets out
from under a running stack.

## The admin account

Crumb seeds an admin account by default. `setup-env.sh` generates a
memorable passphrase (something like `IcyApples473`), stores it as
`SEED_ADMIN_PASSWORD` in `.env`, and prints it once at the end of its run.
On first boot the api creates the `admin` user with that password, so the
console is protected from the very first request, there is no window where
`/admin` is reachable without a login. That password is what you sign in
with at `/admin`; change it in the console (**Users & security**) after your
first login if you want something you chose yourself.

If you missed the printout, read it straight out of the file:

```bash
grep SEED_ADMIN_PASSWORD .env
```

There is no script flag that recovers it later: the password prints on the
run that generates it, and re-running the script without `--force` just
refuses to touch the existing file. Once `.env` exists, the `grep` above is
the way to read the password back.

**Prefer the browser create-admin wizard instead?** Blank out
`SEED_ADMIN_PASSWORD` in `.env` (and leave `SEED_ADMIN_PASSWORD_HASH` empty)
before first boot. With no seed, the api leaves the bootstrap open and you
create the admin yourself at `/admin` on first run. This is opt-in on
purpose: it reopens a short unauthenticated bootstrap window until you
complete the wizard, so only do it if you'll finish setup immediately on a
trusted network.

## Rotating secrets

`scripts/setup-env.sh --force` regenerates the whole set into a fresh `.env`,
but **do not treat that as a complete Postgres rotation.** Postgres stores
its role password inside its own data volume (`crumb_pgdata`); rewriting
`POSTGRES_PASSWORD` / `DATABASE_URL` in `.env` does not change what the
running database expects, so api and recorder will fail to authenticate
after a plain `docker compose up -d`. To actually rotate the DB password you
have to change it inside Postgres too:

```bash
# 1. Regenerate .env (new POSTGRES_PASSWORD + DATABASE_URL, new JWT/go2rtc secrets)
scripts/setup-env.sh --force

# 2. Point Postgres itself at the new password (source the new value first)
set -a; . ./.env; set +a
docker compose up -d postgres
docker compose exec -T postgres \
  psql -U "$POSTGRES_USER" -d postgres \
  -c "ALTER USER \"$POSTGRES_USER\" WITH PASSWORD '$POSTGRES_PASSWORD';"

# 3. Bring the rest up on the new credentials
docker compose up -d
```

The other generated secrets are simpler: `JWT_SECRET` just invalidates
existing sessions (everyone re-logs in), and rotating
`GO2RTC_USER`/`GO2RTC_PASS` requires restarting both `recorder` and `api`,
since both need the new credentials to keep talking to the embedded
restreamer.

If you'd rather avoid the Postgres dance entirely, rotate on a clean slate:
stop the stack, remove the `crumb_pgdata` volume, and let the new `.env`
provision a fresh database (you lose the segment index, so restore a
[backup](/configuration/backups) after, or accept re-indexing from disk).

## Where secrets live, and don't

- `.env` is gitignored and stays that way. Never commit it.
- The API's per-user credentials are Argon2-hashed in Postgres, never
  stored or logged in plaintext.
- Per-camera RTSP/ONVIF credentials live in the `cameras` table, not in
  `.env` or the go2rtc configuration file, and are never embedded into
  the committed `go2rtc/go2rtc.yaml` (that file holds listener
  configuration only; streams are managed at runtime).
- Live media URLs use short-lived, scoped `?token=` claims, not the
  long-lived bearer session token, so a leaked media link can't be turned
  into full account access.
- The LPR ingest token (minted in **Admin → LPR**, "Rotate ingest token")
  is shown once at creation and never again. It goes in `.env` as
  `LPR_INGEST_TOKEN` for the crumb-alpr worker. Rotating it invalidates the
  old one immediately, so update any running worker with the new value.
- Secrets that support it can come from a file instead of the environment
  via the `_FILE` convention (`DATABASE_URL_FILE`, `JWT_SECRET_FILE`,
  `GO2RTC_USER_FILE` / `GO2RTC_PASS_FILE`, `SEED_ADMIN_PASSWORD_FILE`,
  `HA_TOKEN_FILE`). Point one at a Docker-secret path and Crumb reads the
  file, keeping the plaintext value out of the process environment and
  `.env`. See `scripts/setup-secrets.sh` and
  `docker-compose.secrets.example.yml`.

## If you hand-edit `.env` instead of using the script

`.env.example` documents every key, but if you copy it directly and leave
`GO2RTC_USER`/`GO2RTC_PASS` blank, `docker compose up` will fail fast with
a "variable is not set" error rather than booting with empty credentials.
That's deliberate: there is no insecure fallback for those two values.
