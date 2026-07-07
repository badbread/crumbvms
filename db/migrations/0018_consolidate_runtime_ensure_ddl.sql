-- Consolidate runtime `ensure_*` DDL into a canonical numbered migration.
--
-- For most of the project's history the group / named-policy / byte-cap /
-- advanced-storage / storage-migrations / server-settings / per-camera-icon /
-- etc. schema existed ONLY in Rust `ensure_*` shims run at startup, with NO
-- matching numbered .sql. This migration mirrors that DDL verbatim so that:
--
--   (a) a FRESH database built purely from 0001..00NN (without the ensure_*
--       shims ever running) is byte-identical to the current production schema;
--   (b) the EXISTING production DB — which already has every object below via the
--       ensure_* shims — is completely UNAFFECTED, because every statement is a
--       guaranteed no-op when the object already exists.
--
-- The migration runner WILL execute this file on prod (0018+ are not in the
-- baseline-skip set), so every statement MUST be idempotent. The verbatim-from-
-- shim forms below already run harmlessly against prod on every boot.
--
-- The `ensure_*` functions are intentionally LEFT IN PLACE (belt-and-suspenders /
-- cross-process boot ordering). This file is purely additive duplication of DDL
-- already guaranteed present; it does NOT remove the shims.
--
-- No BEGIN/COMMIT and no CONCURRENTLY: the runner wraps a non-CONCURRENTLY file
-- in a single implicit transaction.

-- ── recording_policies: byte-cap columns (ensure_policy_size_cap_columns) ──────
ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS live_max_bytes    bigint;
ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS archive_max_bytes bigint;

-- ── recording_policies: advanced storage columns (ensure_policy_advanced_storage_columns) ──
ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS live_min_free_pct          real;
ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS live_min_free_bytes        bigint;
ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS live_spill_low_water_bytes bigint;

-- ── recording_policies.motion_threshold → real fraction (ensure_motion_threshold_fraction) ──
-- Self-guarding: converts the legacy integer basis-points encoding to a real
-- fraction ONLY while the column is still `integer`. A fresh DB (0001 created it
-- `real`) or an already-converted prod column is untouched (never double-divides).
DO $$
BEGIN
  IF (SELECT data_type FROM information_schema.columns
      WHERE table_name = 'recording_policies'
        AND column_name = 'motion_threshold') = 'integer' THEN
    ALTER TABLE recording_policies
      ALTER COLUMN motion_threshold TYPE real
      USING (motion_threshold::real / 10000.0);
  END IF;
END $$;

-- ── Named policies + camera groups + nullable policy_id (ensure_named_policies_and_groups) ──
-- 1. Named policies: add the label column + backfill the default.
ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS name text;
UPDATE recording_policies SET name = 'Default' WHERE is_default AND name IS NULL;

-- 2. Allow a camera to inherit (NULL policy_id). Idempotent: DROP NOT NULL is a
--    no-op if already nullable.
ALTER TABLE cameras ALTER COLUMN policy_id DROP NOT NULL;

-- 3. Camera groups + their (optional) shared policy.
CREATE TABLE IF NOT EXISTS camera_groups (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text NOT NULL,
    policy_id  uuid REFERENCES recording_policies(id),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- 4. Group membership (cascades on group OR camera delete).
CREATE TABLE IF NOT EXISTS camera_group_members (
    group_id  uuid NOT NULL REFERENCES camera_groups(id)  ON DELETE CASCADE,
    camera_id uuid NOT NULL REFERENCES cameras(id)        ON DELETE CASCADE,
    PRIMARY KEY (group_id, camera_id)
);

-- 5. A camera belongs to AT MOST ONE recording group.
CREATE UNIQUE INDEX IF NOT EXISTS one_group_per_camera
    ON camera_group_members (camera_id);
-- NOTE: the "exactly one default policy" runtime sanity check in the
-- ensure_named_policies_and_groups shim is an app-level assertion, NOT DDL, and
-- intentionally has no SQL equivalent here.

-- ── cameras: source_url / source_sub_url (ensure_camera_source_columns) ────────
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS source_url text;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS source_sub_url text;

-- ── cameras: motion_source / motion_algorithm (ensure_motion_source_columns) ───
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS motion_source    TEXT NOT NULL DEFAULT 'pixel',
    ADD COLUMN IF NOT EXISTS motion_algorithm TEXT NOT NULL DEFAULT 'census';

-- ── cameras.camera_type (ensure_camera_type_column) ────────────────────────────
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS camera_type TEXT
        CHECK (camera_type IS NULL
               OR camera_type IN ('ptz','dome','bullet','lpr','other'));

-- ── cameras.icon (ensure_cameras_icon_column) ──────────────────────────────────
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS icon TEXT
        CHECK (icon IS NULL
               OR icon IN ('cam_ptz','cam_dome','cam_bullet','cam_lpr','cam_other'));

-- ── cameras.motion_grid_cols / motion_grid_rows (ensure_cameras_motion_grid_columns) ──
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS motion_grid_cols SMALLINT
        CHECK (motion_grid_cols IS NULL
               OR (motion_grid_cols >= 1 AND motion_grid_cols <= 256));
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS motion_grid_rows SMALLINT
        CHECK (motion_grid_rows IS NULL
               OR (motion_grid_rows >= 1 AND motion_grid_rows <= 256));

-- ── storages.icon (ensure_storages_icon_column) ────────────────────────────────
ALTER TABLE storages
    ADD COLUMN IF NOT EXISTS icon TEXT
        CHECK (icon IS NULL OR icon IN ('ssd','hdd','disk'));

-- ── segments.motion_score (ensure_segments_motion_score_column) ────────────────
ALTER TABLE segments ADD COLUMN IF NOT EXISTS motion_score real;

-- ── storage_migrations table + index (ensure_storage_migrations_table) ─────────
-- Full 5-value status CHECK (incl. 'cancelled') from the start; 0014 only widens
-- the CHECK on an already-existing table, so a fresh DB needs the table created
-- here with the complete constraint.
CREATE TABLE IF NOT EXISTS storage_migrations (
    id              uuid PRIMARY KEY,
    policy_id       uuid NOT NULL,
    from_storage_id uuid NOT NULL REFERENCES storages(id) ON DELETE RESTRICT,
    to_storage_id   uuid NOT NULL REFERENCES storages(id) ON DELETE RESTRICT,
    status          text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','running','done','failed','cancelled')),
    total_segments  bigint NOT NULL DEFAULT 0,
    moved_segments  bigint NOT NULL DEFAULT 0,
    moved_bytes     bigint NOT NULL DEFAULT 0,
    error           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS storage_migrations_status_idx
    ON storage_migrations (status, created_at);

-- ── camera_resource_stats table (ensure_camera_resource_stats) ─────────────────
CREATE TABLE IF NOT EXISTS camera_resource_stats (
    camera_id  uuid PRIMARY KEY REFERENCES cameras(id) ON DELETE CASCADE,
    cpu_pct    double precision NOT NULL DEFAULT 0,
    mem_mb     double precision NOT NULL DEFAULT 0,
    gpu_pct    double precision,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ── frigate_config table (ensure_frigate_config_table) ─────────────────────────
-- DDL ONLY. The singleton seed row is deliberately NOT inserted here: the shim
-- seeds it from runtime env vars (ON CONFLICT (id) DO NOTHING). Seeding a default
-- row in this migration would win the race (run_migrations runs before the shim
-- on a fresh recorder boot) and silently discard the operator's FRIGATE_* env
-- config. Leaving the table empty here preserves today's env-driven seed exactly.
CREATE TABLE IF NOT EXISTS frigate_config (
    id            smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled       boolean NOT NULL DEFAULT false,
    mqtt_url      text NOT NULL DEFAULT '',
    mqtt_prefix   text NOT NULL DEFAULT 'frigate',
    mqtt_user     text,
    mqtt_password text,
    api_base      text NOT NULL DEFAULT '',
    min_score     real NOT NULL DEFAULT 0.3,
    catchup_hours integer NOT NULL DEFAULT 24,
    version       bigint NOT NULL DEFAULT 1,
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ── server_settings: motion_hwaccel / motion_vaapi_device (ensure_server_settings_table) ──
-- The table + its base/frigate-split columns already have numbered coverage
-- (0012 + 0014). These two columns are the only server_settings columns that
-- existed ONLY in the shim. The CREATE TABLE IF NOT EXISTS guards a fresh DB
-- where 0012 baseline-created the table; the env-driven seed stays in the shim.
CREATE TABLE IF NOT EXISTS server_settings (
    id                smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    server_address    text NOT NULL DEFAULT '',
    crumb_rtsp_base   text NOT NULL DEFAULT '',
    crumb_api_base    text NOT NULL DEFAULT '',
    frigate_rtsp_base text NOT NULL DEFAULT '',
    frigate_api_base  text NOT NULL DEFAULT '',
    version           bigint NOT NULL DEFAULT 1,
    updated_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS frigate_go2rtc_api_base text NOT NULL DEFAULT '';
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS frigate_http_api_base text NOT NULL DEFAULT '';
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS motion_hwaccel text NOT NULL DEFAULT '';
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS motion_vaapi_device text NOT NULL DEFAULT '';

-- ── segments.storage_id FK → ON DELETE RESTRICT (ensure_segments_storage_fk_restrict) ──
-- Catalog-driven: locate the FK on segments.storage_id by referencing column
-- (whatever its auto-generated name), and only drop+recreate it as ON DELETE
-- RESTRICT when it is not already RESTRICT. A no-op on a DB that already has the
-- right rule (incl. a fresh DB whose FK was created RESTRICT). confdeltype: 'r'
-- = RESTRICT, 'a' = NO ACTION, 'c' = CASCADE, 'n' = SET NULL, 'd' = SET DEFAULT.
DO $$
DECLARE
    v_conname     text;
    v_confdeltype "char";
BEGIN
    SELECT con.conname, con.confdeltype
      INTO v_conname, v_confdeltype
    FROM pg_constraint con
    JOIN pg_class      rel ON rel.oid = con.conrelid
    JOIN pg_namespace  nsp ON nsp.oid = rel.relnamespace
    JOIN pg_attribute  att ON att.attrelid = con.conrelid
                          AND att.attnum = con.conkey[1]
    WHERE con.contype = 'f'
      AND rel.relname = 'segments'
      AND att.attname = 'storage_id'
      AND nsp.nspname = current_schema();

    IF v_conname IS NULL THEN
        -- No FK present at all (unexpected for a real schema). Add it as RESTRICT.
        ALTER TABLE segments
            ADD CONSTRAINT segments_storage_id_fkey
            FOREIGN KEY (storage_id) REFERENCES storages(id) ON DELETE RESTRICT;
    ELSIF v_confdeltype <> 'r' THEN
        -- Swap the existing FK to ON DELETE RESTRICT.
        EXECUTE format('ALTER TABLE segments DROP CONSTRAINT %I', v_conname);
        ALTER TABLE segments
            ADD CONSTRAINT segments_storage_id_fkey
            FOREIGN KEY (storage_id) REFERENCES storages(id) ON DELETE RESTRICT;
    END IF;
END $$;
