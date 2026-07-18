-- 0071_lpr_engine_none.sql
--
-- Add 'none' as a first-class per-camera LPR engine value: "LPR is off for
-- this camera". The engine dropdown becomes the SINGLE per-camera LPR control —
-- the legacy `lpr_enabled` checkbox ("crumb-alpr worker should read this
-- camera") duplicated and could contradict it, so it is now DERIVED from the
-- engine (`lpr_engine IN ('crumb-alpr','both')`) everywhere:
--
--   * the admin console no longer shows the checkbox;
--   * `update_camera_lpr` writes the derived value;
--   * `get_camera_lpr_config` (which feeds the crumb-alpr worker's
--     GET /lpr/worker-config poll) computes it from the engine at read time,
--     so the stored column is only a back-compat mirror.
--
-- The backfill below re-derives the stored `lpr_enabled` from the engine so
-- the column agrees with the new rule from the moment this migration runs.
--
-- Idempotent (DROP IF EXISTS + re-ADD; the UPDATE is a pure re-derivation),
-- matching every migration.

ALTER TABLE cameras DROP CONSTRAINT IF EXISTS cameras_lpr_engine_chk;
ALTER TABLE cameras
    ADD CONSTRAINT cameras_lpr_engine_chk
    CHECK (lpr_engine IN ('none', 'frigate', 'crumb-alpr', 'both'));

UPDATE cameras SET lpr_enabled = (lpr_engine IN ('crumb-alpr', 'both'));
