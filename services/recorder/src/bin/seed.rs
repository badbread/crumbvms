// SPDX-License-Identifier: AGPL-3.0-or-later

//! Crumb NVR — database seed utility.
//!
//! # Purpose
//!
//! Idempotently populates the database with the minimum data needed to start
//! recording.  Designed to be run once after `docker compose up` when setting
//! up a new instance, and safe to re-run on every container start
//! (correctness item 13 — all writes use `ON CONFLICT … DO NOTHING` or
//! `DO UPDATE` so duplicate rows are never created).
//!
//! # What it seeds
//!
//! 1. **storages** — one live-storage row and one archive-storage row, using
//!    the paths from env vars (`LIVE_STORAGE_PATH` / `ARCHIVE_STORAGE_PATH`).
//!    Idempotent via `ON CONFLICT (name) DO UPDATE SET path = EXCLUDED.path`.
//!
//! 2. **recording_policies** — the single global default policy row
//!    (`is_default = true`).  Skipped if the row already exists
//!    (the unique partial index `one_default_policy` on `recording_policies`
//!    enforces at most one default row; we use `ON CONFLICT DO NOTHING`).
//!
//! 3. **users** — the bootstrap admin user.  Requires `SEED_ADMIN_USERNAME`
//!    and `SEED_ADMIN_PASSWORD_HASH` env vars.  Skipped if the username
//!    already exists.
//!
//! 4. **cameras** (optional) — reads a JSON file at `SEED_CAMERAS_JSON` (if
//!    set) and upserts camera rows.  Skipped if the env var is not set.
//!    The default cameras for the prototype are
//!    seeded inline when `SEED_DEFAULT_CAMERAS=true` is set.
//!
//! # Usage
//!
//! ```sh
//! # Standalone
//! DATABASE_URL=postgresql://… \
//!   SEED_ADMIN_PASSWORD_HASH='$argon2id$…' \
//!   seed
//!
//! # Via docker compose
//! docker compose run --rm recorder seed
//! ```
//!
//! # Correctness (item 13)
//!
//! The `storages` table must have `UNIQUE(name)`.  The seed binary asserts this
//! at startup via [`db::assert_storages_unique_name`] rather than silently
//! inserting duplicates that would cause nondeterministic storage selection.
//!
//! # Schema-awareness (#5)
//!
//! The entrypoint `docker-compose up` starts the recorder and the seed as
//! separate commands.  On a fresh external Postgres the seed may start BEFORE
//! `run_migrations` has applied the schema.  To avoid a crash-loop the seed:
//!
//! 1. Probes whether the `storages` table exists.  If it is absent the
//!    schema has not been applied yet; the seed exits with a clear message and
//!    a non-zero status so the orchestrator (or the operator) knows to run
//!    migrations first.
//! 2. The `assert_storages_unique_name` check is run ONLY after we confirm the
//!    table exists, so a missing-table error is caught once with a useful
//!    message rather than surfacing as an obscure constraint-lookup failure.
//!
//! The entrypoint script already runs migrations before the seed in the
//! packaged image; this guard is belt-and-suspenders so a standalone `seed`
//! run against an unprepared DB gives an actionable error instead of panicking.

use anyhow::{Context, Result};
use crumb_common::{config::Config, db, logging};
use tracing::{error, info, warn};
use uuid::Uuid;

#[tokio::main]
async fn main() -> Result<()> {
    logging::init();

    let config = Config::from_env().context("reading configuration")?;
    info!("Crumb seed starting");

    let pool = db::build_pool(&config.database_url, 2).context("building database pool")?;

    // #5: Guard against a not-yet-migrated database.
    //
    // Probe whether the core schema tables exist before attempting any inserts.
    // On a fresh external Postgres where `run_migrations` has not been run yet,
    // the `storages`, `recording_policies`, `users`, and `cameras` tables are
    // absent, and attempting inserts causes confusing errors like "relation
    // 'storages' does not exist" rather than a useful diagnostic.
    //
    // We check for `storages` as the representative table: it is created in
    // migration 0001 (the very first migration), so its presence confirms the
    // baseline schema is in place.  If absent we exit with a clear error
    // instead of crash-looping.
    if !schema_is_ready(&pool).await {
        // WARN, not ERROR: on a fresh `docker compose up` the recorder entrypoint
        // RETRIES the seed in a loop while a migrator (recorder/api main) applies
        // the schema on boot, so an early attempt finding no tables yet is an
        // EXPECTED transient during startup, not a failure. Logging it at ERROR
        // tripped the fresh-install smoke's "no ERROR lines" check on every clean
        // boot. Still exit non-zero so the entrypoint's retry loop detects it and
        // waits; if migrations never apply, the migrator logs its own ERROR.
        warn!(
            "Schema tables not present yet — waiting for migrations to be applied \
             (recorder/api main applies them on boot). Seed exiting without \
             modifying the database; the entrypoint will retry."
        );
        // Exit with a non-zero status so docker compose / the entrypoint script
        // can detect this and retry.  We use std::process::exit rather than
        // anyhow::bail so the message above (already logged) is not doubled by
        // anyhow's error chain display.
        std::process::exit(1);
    }

    // Verify schema has the UNIQUE(name) constraint on storages (correctness item 13).
    // Gated on schema_is_ready above so the pg_constraint query below doesn't
    // fail on "relation 'storages' does not exist".
    db::assert_storages_unique_name(&pool)
        .await
        .context("schema assertion: storages.name must have a UNIQUE constraint")?;

    // ── 1. Storage rows ────────────────────────────────────────────────────────

    let live_storage =
        db::upsert_storage(&pool, &config.live_storage_name, &config.live_storage_path)
            .await
            .context("upserting live storage")?;
    info!(
        id   = %live_storage.id,
        name = %live_storage.name,
        path = %live_storage.path,
        "live storage seeded"
    );

    // §6.5: when ARCHIVE_STORAGE_PATH is absent/empty (or the same path as live),
    // seed the archive storage pointing at the LIVE storage path so a fresh
    // install doesn't reference a non-existent second disk.  The operator can
    // change it later in the admin UI.
    let archive_path = config.archive_storage_path.trim().to_owned();
    let (archive_name, archive_path_effective) =
        if archive_path.is_empty() || archive_path == config.live_storage_path.trim() {
            // No distinct archive disk configured — reuse the live storage.
            (
                config.live_storage_name.clone(),
                config.live_storage_path.clone(),
            )
        } else {
            (config.archive_storage_name.clone(), archive_path)
        };

    let archive_storage = db::upsert_storage(&pool, &archive_name, &archive_path_effective)
        .await
        .context("upserting archive storage")?;
    info!(
        id   = %archive_storage.id,
        name = %archive_storage.name,
        path = %archive_storage.path,
        same_as_live = (archive_storage.id == live_storage.id),
        "archive storage seeded"
    );

    // ── 2. Default recording policy ───────────────────────────────────────────

    let default_policy_id = seed_default_policy(&pool, live_storage.id, archive_storage.id)
        .await
        .context("seeding default recording policy")?;

    // ── 3. Admin user (optional) ──────────────────────────────────────────────
    // Phase 0 has no API/auth layer yet, so the admin user is optional. Seed it
    // only when SEED_ADMIN_PASSWORD_HASH is provided; otherwise skip with a
    // warning so the recorder is never blocked from starting by a missing
    // credential.
    if config.seed_admin_password_hash.is_empty() {
        warn!(
            "SEED_ADMIN_PASSWORD_HASH not set; skipping admin user seed \
             (set it before the auth/API layer ships)"
        );
    } else {
        seed_admin_user(
            &pool,
            &config.seed_admin_username,
            &config.seed_admin_password_hash,
        )
        .await
        .context("seeding admin user")?;
    }

    // ── 4a. Optional camera JSON ───────────────────────────────────────────────

    if let Ok(cameras_path) = std::env::var("SEED_CAMERAS_JSON") {
        seed_cameras_from_json(&pool, &cameras_path, default_policy_id)
            .await
            .context("seeding cameras from JSON")?;
    } else {
        info!("SEED_CAMERAS_JSON not set; skipping JSON camera seed");
    }

    // ── 4b. Optional default prototype cameras ────────────────────────────────
    //
    // When SEED_DEFAULT_CAMERAS=true, seed the known Frigate/go2rtc cameras
    // from the prototype environment.  archive_enabled is
    // FALSE for all default cameras — the archive path is off for Phase 0.
    //
    // This is a convenience for the prototype environment only; operators who
    // supply SEED_CAMERAS_JSON or configure cameras through the UI do not need
    // this.

    let seed_defaults = std::env::var("SEED_DEFAULT_CAMERAS")
        .map(|v| v.eq_ignore_ascii_case("true") || v == "1")
        .unwrap_or(false);

    if seed_defaults {
        seed_default_prototype_cameras(&pool, default_policy_id)
            .await
            .context("seeding default prototype cameras")?;
    } else {
        info!("SEED_DEFAULT_CAMERAS not set; skipping prototype camera seed");
    }

    info!("Crumb seed complete");
    Ok(())
}

// ─── seed helpers ─────────────────────────────────────────────────────────────

/// Insert the global default recording policy if it does not already exist.
///
/// Uses the partial unique index `one_default_policy` (ON `is_default` WHERE
/// `is_default = true`) combined with `ON CONFLICT DO NOTHING`, so a re-run
/// does not overwrite operator changes to the default policy.
///
/// Returns the UUID of the default policy row (either the one just inserted or
/// the pre-existing one).
///
/// Prototype defaults:
/// * mode = continuous
/// * live_retention_hours = 48 (2 days)
/// * archive_enabled = **false** — archive path is off for Phase 0 prototype
/// * archive_schedule = "0 3 * * *"
/// * archive_retention_hours = 720 (30 days) — dormant until archive_enabled
/// * motion_pre_seconds = 5, motion_post_seconds = 10
/// * motion_sensitivity = dynamic
/// * record_stream = main
async fn seed_default_policy(
    pool: &deadpool_postgres::Pool,
    live_storage_id: Uuid,
    archive_storage_id: Uuid,
) -> Result<Uuid> {
    let client = pool.get().await.context("db pool get")?;

    // First, check if a default policy already exists.  We need its ID regardless.
    let existing = client
        .query_opt(
            "SELECT id FROM recording_policies WHERE is_default = true",
            &[],
        )
        .await
        .context("checking for existing default policy")?;

    if let Some(row) = existing {
        let id: Uuid = row.get("id");
        info!(id = %id, "default recording policy already exists; skipping insert");
        return Ok(id);
    }

    // Insert fresh default policy.
    //
    // archive_enabled = false is intentional for Phase 0 prototype.  Operators
    // enable archiving per-camera through the UI after validating live recording.
    let row = client
        .query_one(
            r"
            INSERT INTO recording_policies (
                name,
                is_default,
                mode,
                live_storage_id,
                live_retention_hours,
                archive_enabled,
                archive_storage_id,
                archive_schedule,
                archive_retention_hours,
                motion_pre_seconds,
                motion_post_seconds,
                motion_sensitivity,
                motion_keyframes_only,
                record_stream
            )
            VALUES (
                'Default',  -- name
                true,       -- is_default
                'continuous',
                $1,         -- live_storage_id
                48,         -- live_retention_hours (2 days)
                false,      -- archive_enabled: OFF for Phase 0
                $2,         -- archive_storage_id (present but inactive)
                '0 3 * * *',
                720,        -- archive_retention_hours (30 days, dormant)
                5,          -- motion_pre_seconds
                10,         -- motion_post_seconds
                'dynamic',
                false,      -- motion_keyframes_only
                'main'      -- record_stream
            )
            RETURNING id
            ",
            &[&live_storage_id, &archive_storage_id],
        )
        .await
        .context("inserting default recording policy")?;

    let id: Uuid = row.get("id");
    info!(
        id              = %id,
        live_storage_id = %live_storage_id,
        archive_enabled = false,
        "default recording policy inserted (archive_enabled=false for Phase 0)"
    );
    Ok(id)
}

/// Insert the bootstrap admin user if the username does not already exist.
///
/// # Arguments
///
/// * `pool`          — database pool.
/// * `username`      — value of `SEED_ADMIN_USERNAME`.
/// * `password_hash` — pre-computed hash (never store plaintext).
async fn seed_admin_user(
    pool: &deadpool_postgres::Pool,
    username: &str,
    password_hash: &str,
) -> Result<()> {
    let client = pool.get().await.context("db pool get")?;

    let rows_affected = client
        .execute(
            r"
            INSERT INTO users (username, password_hash, role, camera_ids)
            VALUES ($1, $2, 'admin', '[]'::jsonb)
            ON CONFLICT (username) DO NOTHING
            ",
            &[&username, &password_hash],
        )
        .await
        .context("inserting admin user")?;

    if rows_affected == 0 {
        info!(username = %username, "admin user already exists; skipping");
    } else {
        info!(username = %username, "admin user inserted");
    }

    Ok(())
}

/// Parse a JSON file of camera definitions and upsert each row.
///
/// The JSON schema mirrors the `cameras` table columns, minus `id` and
/// `created_at` (auto-generated).  `policy_id` is omitted — each camera is
/// assigned the default policy.
///
/// # Expected JSON shape
///
/// Use RELATIVE stream names (post-0012 model) — the base URL is resolved at
/// runtime from `server_settings`. Legacy absolute URLs (`rtsp://…`) are also
/// accepted and passed through unchanged by `resolve_stream_url`.
///
/// ```json
/// [
///   {
///     "name": "driveway",
///     "go2rtc_name": "driveway",
///     "main_url": "driveway",
///     "sub_url":  "driveway_sub",
///     "enabled": true
///   }
/// ]
/// ```
async fn seed_cameras_from_json(
    pool: &deadpool_postgres::Pool,
    json_path: &str,
    default_policy_id: Uuid,
) -> Result<()> {
    let contents = tokio::fs::read_to_string(json_path)
        .await
        .with_context(|| format!("reading camera seed JSON from {json_path}"))?;

    let cameras: Vec<SeedCamera> = serde_json::from_str(&contents)
        .with_context(|| format!("parsing camera seed JSON from {json_path}"))?;

    info!(count = cameras.len(), path = %json_path, "seeding cameras from JSON");

    for cam in &cameras {
        upsert_camera(pool, cam, default_policy_id).await?;
    }

    Ok(())
}

/// Seed the known prototype cameras.
///
/// **DEV ONLY** — gated behind `SEED_DEFAULT_CAMERAS=true` (default false).
/// Do NOT ship this enabled in production.
///
/// Cameras now use the RELATIVE-name model (§6.5 / O2): `main_url` holds the
/// go2rtc stream name (e.g. `"driveway"`), `sub_url` holds `"driveway_sub"`.
/// Absolute RTSP URLs are resolved at runtime via `resolve_stream_url` +
/// server_settings, so no `192.0.2.10` literal bakes in.
/// `served_by` defaults to `"crumb"` (the DB column default); these prototype
/// cameras are assumed to be Crumb-restreamed in a fresh dev install.
async fn seed_default_prototype_cameras(
    pool: &deadpool_postgres::Pool,
    default_policy_id: Uuid,
) -> Result<()> {
    // Relative names: main_url = go2rtc_name, sub_url = go2rtc_name + "_sub".
    // No absolute URL or host baked in — the operator sets server_settings in
    // the admin UI after first run.
    let prototype_cameras: &[SeedCamera] = &[
        SeedCamera {
            name: "Driveway".to_owned(),
            go2rtc_name: "driveway".to_owned(),
            main_url: "driveway".to_owned(),
            sub_url: Some("driveway_sub".to_owned()),
            enabled: true,
        },
        SeedCamera {
            name: "Backdoor".to_owned(),
            go2rtc_name: "backdoor".to_owned(),
            main_url: "backdoor".to_owned(),
            sub_url: Some("backdoor_sub".to_owned()),
            enabled: false,
        },
        SeedCamera {
            name: "Backyard".to_owned(),
            go2rtc_name: "backyard".to_owned(),
            main_url: "backyard".to_owned(),
            sub_url: Some("backyard_sub".to_owned()),
            enabled: false,
        },
        SeedCamera {
            name: "Front Door".to_owned(),
            go2rtc_name: "frontdoor".to_owned(),
            main_url: "frontdoor".to_owned(),
            sub_url: Some("frontdoor_sub".to_owned()),
            enabled: false,
        },
        SeedCamera {
            name: "Front Yard".to_owned(),
            go2rtc_name: "frontyard".to_owned(),
            main_url: "frontyard".to_owned(),
            sub_url: Some("frontyard_sub".to_owned()),
            enabled: true,
        },
        SeedCamera {
            name: "Front Room".to_owned(),
            go2rtc_name: "frontroom".to_owned(),
            main_url: "frontroom".to_owned(),
            sub_url: None,  // no sub-stream for this camera
            enabled: false, // indoor — start disabled
        },
        SeedCamera {
            name: "Family Room".to_owned(),
            go2rtc_name: "famroom".to_owned(),
            main_url: "famroom".to_owned(),
            sub_url: None,  // no sub-stream for this camera
            enabled: false, // indoor — start disabled
        },
        SeedCamera {
            name: "Garage".to_owned(),
            go2rtc_name: "garage".to_owned(),
            main_url: "garage".to_owned(),
            sub_url: None,
            enabled: false,
        },
        SeedCamera {
            name: "LPR".to_owned(),
            go2rtc_name: "lpr".to_owned(),
            main_url: "lpr".to_owned(),
            sub_url: None,
            enabled: true,
        },
        SeedCamera {
            name: "Side Gate".to_owned(),
            go2rtc_name: "sidegate".to_owned(),
            main_url: "sidegate".to_owned(),
            sub_url: Some("sidegate_sub".to_owned()),
            enabled: true,
        },
        SeedCamera {
            name: "Side Yard".to_owned(),
            go2rtc_name: "sideyard".to_owned(),
            main_url: "sideyard".to_owned(),
            sub_url: None,
            enabled: false,
        },
    ];

    info!(
        count = prototype_cameras.len(),
        "seeding default prototype cameras"
    );

    for cam in prototype_cameras {
        upsert_camera(pool, cam, default_policy_id).await?;
    }

    Ok(())
}

/// Insert a single camera row if it does not already exist (idempotent on
/// `go2rtc_name`).
///
/// Correctness item 13: uses `ON CONFLICT (go2rtc_name) DO NOTHING` so repeated
/// seed runs never insert duplicate rows.
///
/// **Insert-only — the seed NEVER updates an existing camera.** The seed exists
/// purely to *bootstrap* a fresh database; an existing camera's `enabled`,
/// `main_url`, `sub_url`, `name`, and `policy_id` are all operator-controlled
/// (via the API / UI) and must survive every container restart. An earlier
/// `DO UPDATE SET … enabled = EXCLUDED.enabled, main_url = EXCLUDED.main_url, …`
/// re-applied the hardcoded prototype defaults on *every* startup — silently
/// re-disabling cameras the operator had enabled and reverting cameras that had
/// been re-pointed at the crumb go2rtc restreamer back to their stale seed URLs.
/// To change an existing camera, use `PUT /config/cameras/{id}`, not the seed.
async fn upsert_camera(
    pool: &deadpool_postgres::Pool,
    cam: &SeedCamera,
    default_policy_id: Uuid,
) -> Result<()> {
    let client = pool.get().await.context("db pool get")?;

    let rows_affected = client
        .execute(
            r"
            INSERT INTO cameras (name, enabled, go2rtc_name, main_url, sub_url, policy_id)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (go2rtc_name) DO NOTHING
            ",
            &[
                &cam.name,
                &cam.enabled,
                &cam.go2rtc_name,
                &cam.main_url,
                &cam.sub_url,
                &default_policy_id,
            ],
        )
        .await
        .with_context(|| format!("inserting camera '{}'", cam.go2rtc_name))?;

    if rows_affected == 0 {
        // ON CONFLICT DO NOTHING → the camera already exists; leave it untouched.
        info!(go2rtc_name = %cam.go2rtc_name, "camera already exists; skipping (operator config preserved)");
    } else {
        info!(
            name        = %cam.name,
            go2rtc_name = %cam.go2rtc_name,
            enabled     = cam.enabled,
            "camera inserted"
        );
    }

    Ok(())
}

// ─── domain types ─────────────────────────────────────────────────────────────

/// Minimal camera definition read from the optional seed JSON file or used
/// for inline prototype camera definitions.
#[derive(Debug, serde::Deserialize)]
struct SeedCamera {
    name: String,
    go2rtc_name: String,
    main_url: String,
    sub_url: Option<String>,
    #[serde(default = "default_true")]
    enabled: bool,
}

fn default_true() -> bool {
    true
}

// ─── schema readiness probe (#5) ─────────────────────────────────────────────

/// Returns `true` when the baseline schema tables are present in the database.
///
/// Checks for the `storages` table, which is created by migration 0001 (the
/// first migration).  Its presence is a reliable proxy for "migrations have
/// been applied at least once."
///
/// A `false` return means the seed must exit rather than inserting into
/// non-existent tables.  A DB connectivity failure is also treated as `false`
/// (the caller's error message instructs the operator to run migrations first,
/// which requires a reachable DB).
async fn schema_is_ready(pool: &deadpool_postgres::Pool) -> bool {
    let client = match pool.get().await {
        Ok(c) => c,
        Err(e) => {
            error!(error = %e, "seed: cannot connect to database for schema probe");
            return false;
        }
    };

    // `pg_tables` is always available (it's a system catalog view); querying it
    // does not require the application schema to exist.
    match client
        .query_opt(
            "SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'storages'",
            &[],
        )
        .await
    {
        Ok(Some(_)) => true,
        Ok(None) => false,
        Err(e) => {
            error!(error = %e, "seed: schema readiness probe failed");
            false
        }
    }
}
