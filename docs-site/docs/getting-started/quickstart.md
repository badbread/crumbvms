---
title: Quickstart
sidebar_label: Quickstart
slug: /getting-started/quickstart
---

# Quickstart

Get Crumb running in a few minutes on a Linux host with Docker. See [Requirements](/getting-started/requirements) for what your host needs, and [Install with Docker Compose](/getting-started/install-docker-compose) for the full explanation of each step.

## 1. Get the repository and generate secrets

```bash
git clone https://github.com/badbread/crumbvms.git crumb && cd crumb
./scripts/setup-env.sh
```

This writes a gitignored `.env` with strong, randomly generated secrets. At the end it prints your admin username (`admin`) and a memorable password like `IcyApples473` (also saved as `SEED_ADMIN_PASSWORD` in `.env`). Jot it down: you'll sign in with it at step 5, then change it in the console. (Prefer to create the admin in the browser instead? Blank out `SEED_ADMIN_PASSWORD` in `.env` before step 3 and first run gives you the create-admin wizard instead.)

## 2. Point to your storage (optional for trials)

Edit `.env` and set `MEDIA_HOST_PATH` to a disk with real headroom:

```
MEDIA_HOST_PATH=/mnt/your-disk/crumb-data
```

The default `./_data` folder works for testing, but cameras fill terabytes over time. If you point at a disk of your own, make the directory writable by the recorder's user (uid 1001) before bringing the stack up, or nothing records:

```bash
sudo mkdir -p /mnt/your-disk/crumb-data
sudo chown -R 1001:1001 /mnt/your-disk/crumb-data
```

(`setup-env.sh` already does this for the default `./_data`. A directory Docker auto-creates ends up root-owned, the recorder can't write, and footage is silently lost while live view still works.)

## 3. Bring up the stack

```bash
docker compose pull
docker compose up -d
```

If you forked the repo or pinned a version that isn't published yet, `pull` will report "not found," use the build-from-source override instead:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

## 4. Verify it's running

```bash
curl -fsS http://localhost:8080/health
```

Should print the health response and exit 0 (`curl -fsS` prints the body, not a status line). A `503` for the first few seconds is normal while the database finishes migrations.

## 5. Open the browser

`http://<host-lan-ip>:8080/admin`

Sign in with the admin username and the memorable password `setup-env.sh` printed (also saved in `.env`), then change it in the console. From there a wizard walks you through confirming the server address, choosing storage and retention, and finding cameras on your network.

## Next steps

- [First-run wizard](/getting-started/first-run-wizard) for the full walkthrough
- [Adding a camera](/cameras/adding-a-camera) to get your first stream
- [Clients](/clients/) to download the desktop or Android app
- [Responsible use](/responsible-use) before you rely on Crumb for anything

For the full, step-by-step explanation of each of these commands, see [Install with Docker Compose](/getting-started/install-docker-compose).
