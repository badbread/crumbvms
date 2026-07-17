-- 0056_camera_lpr.sql
--
-- Per-camera LPR settings for the Crumb-native engine (the `crumb-alpr`
-- fast-alpr worker) and engine selection. All additive + nullable/defaulted, so
-- existing cameras are unaffected and Frigate-only setups keep working unchanged.
--
--   lpr_enabled        : whether the crumb-alpr worker should read this camera.
--   lpr_engine         : which plate source feeds this camera's reads —
--                          'frigate'    : Frigate native LPR on the event stream
--                                         (the existing behavior);
--                          'crumb-alpr' : the local fast-alpr worker POSTing to
--                                         /lpr/reads;
--                          'both'       : accept reads from either engine (each
--                                         tagged by plate_reads.source_id).
--   lpr_min_confidence : per-camera OCR-confidence floor for stored reads.
--   lpr_zones          : detection zones for the worker as
--                          {"include":[[[x,y],...],...],
--                           "exclude":[[[x,y],...],...]}
--                        with normalized 0..1 coordinates. `include` = "only read
--                        plates whose box centroid is inside one of these"; an
--                        empty/absent `include` means the whole frame. `exclude`
--                        = "ignore plates inside these". Mirrors the existing
--                        cameras.motion_mask jsonb convention.
--
-- Idempotent (IF NOT EXISTS / guarded ADD CONSTRAINT), matching every migration.

ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS lpr_enabled        boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS lpr_engine         text    NOT NULL DEFAULT 'frigate',
    ADD COLUMN IF NOT EXISTS lpr_min_confidence real    NOT NULL DEFAULT 0.80,
    ADD COLUMN IF NOT EXISTS lpr_zones          jsonb;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'cameras_lpr_engine_chk'
    ) THEN
        ALTER TABLE cameras
            ADD CONSTRAINT cameras_lpr_engine_chk
            CHECK (lpr_engine IN ('frigate', 'crumb-alpr', 'both'));
    END IF;
END $$;
