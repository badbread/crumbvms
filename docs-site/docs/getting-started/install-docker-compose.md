---
title: Install with Docker Compose
sidebar_label: Install with Docker Compose
slug: /getting-started/install-docker-compose
---

# Install with Docker Compose

This is the full, step-by-step install path. If you just want the fast path, see the [Quickstart](/getting-started/quickstart). If you're setting up with an AI coding agent instead, see [Install with an AI agent](/getting-started/install-with-ai-agent), which follows the same steps with an added Verify check after each one.

## 1. Get the repository and generate secrets

```bash
git clone https://github.com/badbread/crumbvms.git crumb && cd crumb
./scripts/setup-env.sh
```

`scripts/setup-env.sh` writes a gitignored `.env` with strong, randomly
generated secrets (a Postgres password, a JWT signing secret, and the
go2rtc restreamer's Basic-auth credentials). It refuses to overwrite an
existing `.env` unless you pass `--force`. At the end it also prints your
admin username (`admin`) and a memorable password like `IcyApples473`, saved
as `SEED_ADMIN_PASSWORD` in `.env`. The admin account is created on first
boot, and you sign in with those at `/admin` (step 4), then change the
password in the console. (Prefer to create the admin in the browser instead?
Blank out `SEED_ADMIN_PASSWORD` in `.env` before bringing the stack up and
first run gives you the create-admin wizard instead, opt-in.)

Don't hand-edit the generated secrets, and don't commit `.env`, it stays
gitignored by design.

## 2. Choose where recordings are stored

By default, `.env` points `MEDIA_HOST_PATH` at `./_data` next to the repo.
For anything beyond a quick trial, point it at a disk with real headroom:

```
MEDIA_HOST_PATH=/mnt/your-disk/crumb-data
```

Make sure the directory exists and is writable by the recorder's container
user (uid 1001) before you bring the stack up:

```bash
sudo mkdir -p /mnt/your-disk/crumb-data
sudo chown -R 1001:1001 /mnt/your-disk/crumb-data
```

`setup-env.sh` does this automatically for the default `./_data`, but a
custom path that Docker auto-creates on first `up` ends up root-owned. The
recorder then can't write to it and footage is silently lost, while live
view (which touches no disk) still works and the setup wizard still shows
green, so this is worth getting right up front. You can add more disks later
without touching the compose file: mount them under this same host path (or a
subdirectory) and add the storage path in the admin console.

## 3. Bring up the stack

```bash
docker compose pull
docker compose up -d
docker compose ps
```

`docker compose pull` fetches the prebuilt `api` and `recorder` images from
`ghcr.io/badbread/crumbvms` (public, no login needed). If you're running a
fork whose images aren't published, or `pull` reports "not found," use the
build-from-source override instead:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

The base compose file requires `GO2RTC_USER` and `GO2RTC_PASS` to be set. If
you generated `.env` with `setup-env.sh` this is already handled; if you
hand-edited `.env` from `.env.example` and left those blank, `docker compose
up` will fail fast with a clear "variable is not set" error rather than
booting insecurely. Re-run `scripts/setup-env.sh` instead of inventing
values.

**Verify:** `docker compose ps` shows every service `running` (or
`healthy`), and:

```bash
curl -fsS http://localhost:8080/health
```

returns `200 OK`. A `503` for the first few seconds is normal while
Postgres and migrations finish; retry.

## What's running

| Service | Port | Reachable from | Purpose |
|---|---|---|---|
| `api` | 8080 | LAN | Admin console + REST API, plain HTTP |
| `caddy` | 8443 (default) | LAN | Same API over HTTPS, self-signed by default |
| `recorder` | 18554 | LAN | RTSP restream for native clients |
| `recorder` | 8556 (tcp+udp) | LAN | WebRTC media for live view |
| `postgres` | none | internal only | not published to the host |

There is no separate go2rtc container: Crumb's restreamer runs embedded
inside the `recorder` process. Its own REST API is not published to the
LAN at all, only reachable from the `api` container over the internal
Docker network.

Two things also run automatically with no extra steps: a nightly Postgres
backup (see [Backups](/configuration/backups)) and the database migrations
that bring a fresh Postgres up to the current schema.

## 4. Finish setup in the browser

Open `http://<host-lan-ip>:8080/admin` and sign in with the admin username
and the memorable password `setup-env.sh` printed (also in `.env`), then
change it in the console. A first-run wizard then walks you through accepting
the tester terms, confirming the server's address, choosing storage and
retention, and finding cameras on your network. (If you blanked
`SEED_ADMIN_PASSWORD` in step 1, the wizard opens with a create-admin step
instead of a sign-in.) See
[First-run wizard](/getting-started/first-run-wizard) for the full
walkthrough.

## Optional: HTTPS, hardware decode, remote access

- **HTTPS** is already running by default at `https://<host>:8443` with a
  self-signed certificate; see [TLS](/configuration/tls) for what the
  browser warning means and how to trust or replace the certificate.
- **Hardware-accelerated motion decode** is opt-in; see
  [Hardware decode](/configuration/hardware-decode).
- **Remote access** should go through a private overlay like Tailscale or
  WireGuard, not port-forwarding. The default install is LAN-only on
  purpose; see the ground rules in
  [Install with an AI agent](/getting-started/install-with-ai-agent) for
  why, and don't expose Crumb to the public internet without TLS and a
  strong admin password already in place.

## Stopping the stack

```bash
docker compose down
```

This is the full stop, the kill switch. Your data (media files, the
Postgres volume) is untouched; `docker compose up -d` brings it back the
way you left it.
