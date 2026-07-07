-- Migration 0005: live per-cell motion grid (for the motion tuner).
--
-- The recorder publishes a coarse per-cell motion-intensity grid per camera
-- (computed from the motion diff, BEFORE the exclusion mask is applied, so the
-- tuner can show the operator exactly which areas are triggering motion). The
-- desktop "motion tuner" polls it live while open and lets the user paint
-- exclusion boxes over the hot areas.
--
-- Singleton-per-camera (PK = camera_id). `cells` is a row-major jsonb array of
-- length cols*rows, each value 0..100 (% of that cell's pixels that changed).
--
-- IF NOT EXISTS makes this idempotent; the recorder also ensures it at startup
-- so the tuner works without a manual migration.

CREATE TABLE IF NOT EXISTS motion_grid (
    camera_id  uuid PRIMARY KEY REFERENCES cameras(id) ON DELETE CASCADE,
    updated_at timestamptz NOT NULL DEFAULT now(),
    cols       smallint NOT NULL,
    rows       smallint NOT NULL,
    cells      jsonb NOT NULL DEFAULT '[]'::jsonb
);
