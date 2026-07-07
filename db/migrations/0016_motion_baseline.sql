-- Motion adaptive-threshold persistence (migration 0016).
--
-- Stores the learned histogram + diurnal EMA per camera so the adaptive
-- threshold survives process restarts (warm-start, no cold-reset to BLOB_FRACTION).
--
-- hist    : JSONB array of 64 f32 bucket weights (geometric bins over
--           [BLOB_FRACTION, MAX_THRESHOLD]).
-- diurnal : JSONB array of 24 f32 EMA values (one per hour-of-day).
-- total   : sum of all bucket weights (maintained alongside hist for O(1) decay).
-- updated_at is refreshed on every UPSERT so stale rows are easy to spot.

CREATE TABLE IF NOT EXISTS motion_baseline (
    camera_id  uuid        PRIMARY KEY
                           REFERENCES cameras(id) ON DELETE CASCADE,
    hist       jsonb       NOT NULL,
    diurnal    jsonb       NOT NULL,
    total      double precision NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
