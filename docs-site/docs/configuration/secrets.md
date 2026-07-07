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
- **`SEED_ADMIN_PASSWORD`**, a random URL-safe token, only used if you
  choose the headless install path. The normal path is to leave the admin
  password unset here and create the account in the browser wizard
  instead.

The script refuses to overwrite an existing `.env` unless you pass
`--force`, so re-running it by accident won't silently rotate secrets out
from under a running stack.

## Getting the generated admin password back

If you used `--prompt` or the headless `SEED_ADMIN_PASSWORD` path and need
to see the generated value:

```bash
scripts/setup-env.sh --print
```

This only prints what was just generated, it does not regenerate or rotate
anything by itself.

## Rotating secrets

Re-run with `--force` to generate a fresh set:

```bash
scripts/setup-env.sh --force
docker compose up -d
```

Rotating `GO2RTC_USER`/`GO2RTC_PASS` requires restarting both `recorder`
and `api`, since both need the new credentials to keep talking to the
embedded restreamer.

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

## If you hand-edit `.env` instead of using the script

`.env.example` documents every key, but if you copy it directly and leave
`GO2RTC_USER`/`GO2RTC_PASS` blank, `docker compose up` will fail fast with
a "variable is not set" error rather than booting with empty credentials.
That's deliberate: there is no insecure fallback for those two values.
