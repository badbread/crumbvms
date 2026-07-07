-- Migration 0012: server/streaming settings singleton + camera ownership columns
-- =============================================================================
-- All DDL is additive and idempotent (IF NOT EXISTS / ADD COLUMN IF NOT EXISTS /
-- ON CONFLICT DO NOTHING). Safe to apply to the live crumbvms production DB.
-- Tracked via schema_migrations so it runs ONCE (the runner inserts the filename
-- after a successful apply).
-- =============================================================================
-- NOTE: no explicit BEGIN/COMMIT here — run_migrations() executes each file via
-- batch_execute(), which Postgres runs as a single implicit transaction. Wrapping
-- it again would nest (savepoint) and break atomic rollback on failure.

-- ── server_settings singleton ────────────────────────────────────────────────
-- Mirrors the frigate_config pattern exactly: a single row (id=1 enforced by
-- CHECK), seeded from env by the Rust ensure_server_settings_table() fn.
-- Stores the operator-visible reachable stream bases for Crumb's own restreamer
-- and an optional external Frigate go2rtc.  When a field is empty the recorder
-- / API fall back to the corresponding environment variable.
CREATE TABLE IF NOT EXISTS server_settings (
    id                smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    server_address    text NOT NULL DEFAULT '',      -- operator-facing host (informational)
    crumb_rtsp_base   text NOT NULL DEFAULT '',      -- e.g. "rtsp://crumb-host:18554"
    crumb_api_base    text NOT NULL DEFAULT '',      -- e.g. "http://go2rtc:1984"
    frigate_rtsp_base text NOT NULL DEFAULT '',      -- e.g. "rtsp://frigate-host:8554"
    frigate_api_base  text NOT NULL DEFAULT '',      -- e.g. "http://frigate-host:1984"
    version           bigint NOT NULL DEFAULT 1,
    updated_at        timestamptz NOT NULL DEFAULT now()
);
-- Seed the singleton row; do nothing if it already exists.
INSERT INTO server_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ── camera ownership + Frigate mapping ──────────────────────────────────────
-- served_by: which restreamer owns this camera's go2rtc stream.
--   'crumb'   = Crumb's own embedded go2rtc (port :18554).
--   'frigate' = an external Frigate instance's go2rtc (port :8554).
-- Default 'crumb' means existing rows and new cameras default to Crumb-managed.
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS served_by text NOT NULL DEFAULT 'crumb'
        CHECK (served_by IN ('crumb', 'frigate'));

-- source_camera_name: the external provider's (Frigate's) name for this camera,
-- used to map incoming detection events to the correct Crumb camera UUID.
-- Already added by migration 0007 (ensure_detection_columns), so this is truly
-- a no-op on the prod DB.  Included here so a fresh-install path via the runner
-- gets the column from a single canonical migration.
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS source_camera_name text;

-- ── per-camera ONVIF credentials ─────────────────────────────────────────────
-- Stored in the DB so PTZ commands and the Re-detect flow work without hand-
-- editing ONVIF_CONFIG env on every camera add.  The password is NEVER returned
-- by any API endpoint; db.rs carries it only so ptz.rs / discover.rs can read it.
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS onvif_host     text;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS onvif_port     integer;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS onvif_user     text;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS onvif_password text;

-- ── served_by backfill (heuristic from port in main_url) ────────────────────
-- Crumb's own restreamer uses port :18554; Frigate's go2rtc uses :8554.
-- Only touches rows still at the default ('crumb') to avoid overwriting any
-- row an operator already corrected.  Non-URL main_url values (relative names
-- from a future camera add) match neither pattern and keep 'crumb' (safe default).
UPDATE cameras
    SET served_by = CASE
        WHEN main_url LIKE '%:18554/%' THEN 'crumb'
        WHEN main_url LIKE '%:8554/%'  THEN 'frigate'
        ELSE served_by
    END
WHERE served_by = 'crumb';

-- NOTE (O2): The destructive main_url/sub_url regexp_replace rewrite is
-- intentionally OMITTED per ORCHESTRATOR DECISION O2.  Existing rows keep
-- their absolute URLs verbatim; resolve_stream_url() passes them through
-- unchanged (it checks for "://" and returns the value as-is).  New cameras
-- store only the relative go2rtc stream name in main_url/sub_url; both old
-- and new rows resolve correctly via the same fn.
