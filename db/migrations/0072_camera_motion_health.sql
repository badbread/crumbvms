-- 0072_camera_motion_health.sql
--
-- Per-camera CURRENT motion-detector health, so an operator looking at the
-- admin console can SEE that a Motion-mode camera's detector is down and the
-- recorder is failing OPEN (recording continuously as a fallback) right now.
--
-- Why a dedicated current-state row instead of scanning system_events:
-- the recorder already emits a `motion_detector_unhealthy` system_events row
-- (services/recorder/src/motion.rs), and migration 0038 routes it to the
-- notification engine. But that is an EVENT (edge), not a STATE (level): there
-- is no matching "healthy again" row, so events alone cannot answer "is this
-- camera unhealthy RIGHT NOW?" (the whole reason the #411 fault ran ~5 days
-- unseen: the fail-open safety worked, so continuous segments looked identical
-- to a busy scene). This table is the LEVEL signal: exactly one row per camera,
-- upserted by the recorder's health aggregator (motion.rs `aggregate_health`)
-- on every camera-level health TRANSITION in either direction, so it always
-- reflects the current state, not "ever fired".
--
-- `healthy = false` means the camera's motion detection is currently down and
-- the recording task is failing open (persisting every segment as if Continuous
-- mode) until health returns — footage is NOT being lost, only the disk-saving
-- benefit of Motion mode is suspended. `changed_at` is when the CURRENT state
-- began (advanced only when `healthy` flips, so it reads as "unhealthy since
-- <time>"); `updated_at` is the last write (staleness of the report).
--
-- Rows cascade with the camera; the recorder also deletes a camera's row when
-- it stops that camera's worker (disabled/removed), mirroring
-- camera_decode_status. No seed rows: absence means "recorder has never
-- reported" (older recorder image, not booted, or the camera is not in Motion
-- mode) — the API surfaces that as null, which the UI renders as "no report",
-- NOT as unhealthy.
--
-- IF NOT EXISTS keeps this idempotent for the migration runner.
CREATE TABLE IF NOT EXISTS camera_motion_health (
    camera_id  uuid        PRIMARY KEY
                           REFERENCES cameras(id) ON DELETE CASCADE,
    -- Current camera-level motion-detector health. false = failing open
    -- (recording continuously as a fallback) right now.
    healthy    boolean     NOT NULL,
    -- Short human-readable cause when unhealthy (which source(s) are down);
    -- NULL when healthy.
    reason     text,
    -- When the CURRENT healthy value began (advanced only on a flip).
    changed_at timestamptz NOT NULL DEFAULT now(),
    -- Last write of this row (report freshness / staleness).
    updated_at timestamptz NOT NULL DEFAULT now()
);
