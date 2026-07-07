#!/bin/sh
# Crumb NVR — container entrypoint
#
# Ordering correctness (audit 2026-06-22 #5):
#   The standalone `seed` binary assumes the schema ALREADY exists — it calls
#   db::assert_storages_unique_name / upsert_storage / etc. against real tables.
#   It does NOT run migrations. The canonical migration applier is each service's
#   own startup (the `crumb-recorder` binary runs run_migrations *fatally* at the
#   top of main; the API does the same). So `seed` must NEVER run before the
#   schema has been migrated, or it crashes — and because seed used to run
#   UNCONDITIONALLY before the recorder, a fresh (especially external) Postgres
#   crash-looped the recorder container until the API happened to win the
#   migrate race.
#
#   Fix: gate the seed on schema readiness. The seed self-asserts the schema
#   (db::assert_storages_unique_name) before touching any table, so a successful
#   run == the schema is migrated AND the seed applied. We retry it on a bounded
#   loop: as soon as a migrator (the API or a prior recorder boot) has applied
#   the schema, the seed succeeds and we stop. If the schema has NOT appeared
#   within the bounded wait, we SKIP the seed (non-fatal) and exec the recorder
#   anyway: the recorder's own run_migrations is the canonical applier, so the
#   schema gets created regardless, and the next idempotent container start seeds.
#   The recorder is therefore never blocked from booting by the seed.
#
#   Using exec for the final launch replaces this shell with the recorder so
#   SIGTERM from Docker reaches the recorder directly (correct PID 1 behaviour).
#
# Usage (from Dockerfile CMD / docker-compose command):
#   entrypoint.sh crumb-recorder   # production (default)
#   entrypoint.sh seed             # run seed only (debugging; still schema-gated)
set -eu

APP="${1:-crumb-recorder}"

# How long to wait for the schema before giving up and letting the app migrate.
# 60 * 1s = 60s ceiling. Generous enough for the API/recorder to apply migrations
# on a fresh DB, short enough not to wedge a genuinely broken stack.
SEED_SCHEMA_WAIT_TRIES="${SEED_SCHEMA_WAIT_TRIES:-60}"

# Probe the DB for a migrated schema WITHOUT psql (not in the runtime image):
# `seed` itself asserts storages.UNIQUE(name) before touching any table, so a
# missing/partial schema makes it exit non-zero immediately. We treat that exit
# as "schema not ready yet" and retry, rather than letting it kill the container.
schema_ready_seed() {
    # Run the seed; it is idempotent and safe to re-run. Success == schema ready
    # AND seed applied. Failure == schema not ready yet (or a transient DB blip).
    /usr/local/bin/seed
}

i=0
seeded=0
while [ "${i}" -lt "${SEED_SCHEMA_WAIT_TRIES}" ]; do
    if schema_ready_seed; then
        echo "[entrypoint] seed complete (schema migrated, idempotent pass applied)"
        seeded=1
        break
    fi
    i=$((i + 1))
    echo "[entrypoint] schema not ready yet (seed attempt ${i}/${SEED_SCHEMA_WAIT_TRIES}); waiting for a migrator to apply the schema…"
    sleep 1
done

if [ "${seeded}" -ne 1 ]; then
    echo "[entrypoint] WARNING: schema still not ready after ${SEED_SCHEMA_WAIT_TRIES}s; skipping seed and launching ${APP} anyway."
    echo "[entrypoint] The app runs run_migrations on startup (canonical applier); the next restart will seed."
fi

echo "[entrypoint] launching ${APP}"
exec "/usr/local/bin/${APP}"
