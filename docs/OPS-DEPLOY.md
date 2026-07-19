# Crumb, Deployment & Secrets Runbook

Operator guide for installing, configuring, and securing a Crumb deployment.
Pairs with:
- `docs/OPS-BACKUP-RECOVERY.md`, backups + disaster recovery (read this too).
- `docs/RELEASE.md`, versioned images, deploy-by-pull, rollback.

The stack: a Rust **recorder**, a Rust/axum **API**, **Postgres** (the segment
index = source of truth), and **go2rtc** (Crumb's own restreamer, embedded in and
supervised by the recorder container), run as a docker-compose stack on a single
host (`/opt/crumb/app`).

---

## 1. First install

```bash
git clone <repo> /opt/crumb/app
cd /opt/crumb/app

# Generate a .env with strong secrets (see "Secrets" below).
scripts/setup-env.sh                   # zero-edit: strong secrets + sane defaults

# Boots GPU-free (MOTION_HWACCEL=auto → CPU when no GPU is present).
docker compose up -d
docker compose ps                      # postgres healthy, recorder (embeds go2rtc) + api up
```

Then open **`http://<host>:8080/admin`** and **sign in as `admin`** with the
memorable passphrase `scripts/setup-env.sh` printed (stored as
`SEED_ADMIN_PASSWORD` in `.env`); the first-run wizard resumes at the
tester-terms step (the admin is already seeded, so there's no create-admin step).
After logging in, set the reachable address under **Server & streaming** (e.g.
`rtsp://<host>:18554`) and add cameras in the **Cameras** page. Change the starter
admin password in the console after first login.

- **Create the admin in the browser instead:** blank `SEED_ADMIN_PASSWORD` in
  `.env` before first boot; the wizard then shows its create-admin step.
- **GPU (optional):** add the overlay to enable NVDEC motion decode:
  `docker compose -f docker-compose.yml -f docker-compose.gpu.example.yml up -d`.
- **Storage:** one broad media root (`MEDIA_HOST_PATH` → `/data`) is bind-mounted
  RW into the recorder and RO into the API. Add a disk by mounting it under that
  host dir and adding the storage path `/data/<subdir>` in the admin UI, no
  compose edit; the recorder creates the subdir on first write.

Then do the post-install hardening:
- Install the backup cron (`docs/OPS-BACKUP-RECOVERY.md`).
- Enable the pre-commit secret guard if this is a working clone (below).
- Run a tested-restore drill before going live.

---

## 2. Secrets hygiene (interim posture)

Full vault integration is deferred. The
interim posture is: **strong generated secrets in a gitignored `.env`, plus a
hook that blocks committing it.**

### Generate / rotate secrets

`scripts/setup-env.sh` writes a `.env` (mode 600) with:
- `POSTGRES_PASSWORD`, `openssl rand -hex 32`
- `JWT_SECRET`, `openssl rand -hex 32` (the API requires ≥ 32 bytes)
- `SEED_ADMIN_PASSWORD`, a **memorable passphrase generated and seeded by
  default** (e.g. `IcyApples473`). `setup-env.sh` prints it and stores it here,
  and the API hashes it with argon2 at startup to create the `admin` user. This
  is the secure default: it closes the unauthenticated `/auth/bootstrap` window a
  blank seed would leave open. Use `--prompt` to set your own, or blank the value
  to hand admin creation to the browser wizard.

```bash
scripts/setup-env.sh                  # generate secrets + seed an admin; prints the passphrase
scripts/setup-env.sh --prompt         # set your own admin password interactively
scripts/setup-env.sh --print          # also echo the passphrase to stdout after writing
scripts/setup-env.sh --force          # ROTATE: overwrite an existing .env
```

It refuses to clobber an existing `.env` without `--force`, so it's safe to
re-run. Rotating `JWT_SECRET` invalidates outstanding tokens (users re-login);
rotating `POSTGRES_PASSWORD` requires also updating the role in Postgres
(`ALTER ROLE crumb PASSWORD '...'`), for the bundled DB the simplest path is
a fresh init or an explicit `ALTER ROLE`.

### Keep secrets out of git

- `.env`, `.env.*`, `*.env` (except `*.env.example`), `backups/`, and `*.sql.gz`
  are gitignored.
- Install the pre-commit hook in each working clone:
  ```bash
  git config core.hooksPath .githooks
  ```
  It blocks staging a `.env` / key / backup, and flags obvious inline secrets in
  the diff. Bypass a single commit (rarely) with `git commit --no-verify`.

### The DB_POOL_SIZE knob

`api` and `recorder` read `DB_POOL_SIZE` (an integer; default **32** in code).
It's left **unset** in `docker-compose.yml` so the code default applies (note:
there's no ready-made line to uncomment, so add `DB_POOL_SIZE` to `.env` and wire
it into the api/recorder `environment:` blocks to override). For real camera
counts, size it for concurrent load, roughly **2 × cameras + 10** (e.g. 42 for
16 cameras, 74 for 32). Undersizing it causes pool-saturation hangs under load.

---

## 3. Postgres topology: bundled vs external

By default Postgres runs **inside** the stack (bundled `postgres` service, data
in the `crumb_pgdata` volume). That makes the recording host a single point of
failure for the index. To remove that SPOF, run Postgres on a **separate host**
(**no code change required, only `DATABASE_URL`**).

Mechanism: `docker-compose.override.example.yml`.

```bash
cp docker-compose.override.example.yml docker-compose.override.yml
# In .env, point DATABASE_URL at the remote host:
#   DATABASE_URL=postgresql://crumb:STRONGPASS@192.0.2.30:5432/crumb
```

The override parks the bundled `postgres` service behind an inactive profile and
clears `depends_on` on api + recorder, so they connect to the remote DB instead.
The default (bundled DB) is untouched, delete `docker-compose.override.yml` to
revert.

**Schema provisioning** on the remote DB: the api/recorder embed a migration
runner that applies every `db/migrations/*.sql` (idempotently, tracked in a
`schema_migrations` table) at startup, so an **empty external Postgres
self-provisions** on first boot, no manual step required. If you prefer to
pre-provision (or to apply migrations before the binaries connect), you can still
run them by hand:

```bash
for f in db/migrations/*.sql; do
  psql "postgresql://crumb:STRONGPASS@<remote-host>:5432/crumb" -v ON_ERROR_STOP=1 -f "$f"
done
```

`scripts/backup-db.sh` and `restore-db.sh` detect when the bundled `postgres`
service isn't running and fall back to operating over `DATABASE_URL`, so the same
backup cron keeps working against the remote DB (install `postgresql-client` on
the cron host so `pg_dump`/`psql` are on PATH).

Full disaster-recovery rationale and the "why the DB is the source of truth"
explanation live in `docs/OPS-BACKUP-RECOVERY.md`.

---

## 4. Validate compose before deploying

After any compose / `.env` change:

```bash
cd /opt/crumb/app
docker compose config >/dev/null && echo OK     # base file parses + substitutes
# With the remote-DB override active:
docker compose -f docker-compose.yml -f docker-compose.override.yml config >/dev/null && echo OK
```

`docker compose config` fully resolves variable substitution and merges
overrides, so it catches typos and bad references before they hit a deploy.

---

## 5. Day-2 operations cheat sheet

```bash
docker compose ps                          # service health
docker compose logs -f --tail=100 recorder # follow recorder logs (JSON)
docker compose logs -f --tail=100 api
docker compose restart recorder            # bounce one service
docker compose pull && docker compose up -d # deploy a pinned version (docs/RELEASE.md)
scripts/backup-db.sh                        # ad-hoc backup before risky changes
docker compose down                         # full stop (the kill switch)
```
