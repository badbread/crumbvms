-- Migration 0007: detection events schema extension
-- Safe to run multiple times (all DDL uses IF NOT EXISTS / IF EXISTS guards).
-- Applied automatically on first init by docker-entrypoint-initdb.d.
-- Also applied at runtime by ensure_detection_columns() in services/common/src/db.rs.

-- Add Frigate camera-name mapping column to cameras table.
-- The value is the Frigate camera name (e.g. "driveway") used in MQTT
-- after.camera. Null means the camera has no Frigate counterpart.
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS source_camera_name TEXT;

-- Extend the events table (stub created in migration 0001) to the production
-- detection-event schema. All columns are nullable so existing rows are
-- unaffected and old code continues to work without the detection feature.
ALTER TABLE events
    ADD COLUMN IF NOT EXISTS source_id            TEXT,
    ADD COLUMN IF NOT EXISTS provider_event_id    TEXT,
    ADD COLUMN IF NOT EXISTS sub_label            TEXT,
    ADD COLUMN IF NOT EXISTS top_score            REAL,
    ADD COLUMN IF NOT EXISTS end_ts               TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS bbox_x1              REAL,
    ADD COLUMN IF NOT EXISTS bbox_y1              REAL,
    ADD COLUMN IF NOT EXISTS bbox_x2              REAL,
    ADD COLUMN IF NOT EXISTS bbox_y2              REAL,
    ADD COLUMN IF NOT EXISTS zones                TEXT[],
    ADD COLUMN IF NOT EXISTS snapshot_url         TEXT,
    ADD COLUMN IF NOT EXISTS raw                  JSONB,
    ADD COLUMN IF NOT EXISTS lifecycle            TEXT
        CHECK (lifecycle IS NULL OR lifecycle IN ('start', 'update', 'end'));

-- Deduplication index: exactly one row per (source_id, provider_event_id).
-- The partial WHERE clause excludes legacy rows where source_id IS NULL so
-- they never conflict with each other.
CREATE UNIQUE INDEX IF NOT EXISTS events_provider_dedup
    ON events (source_id, provider_event_id)
    WHERE source_id IS NOT NULL;

-- Primary query pattern: events for a camera in a time window.
CREATE INDEX IF NOT EXISTS events_camera_ts
    ON events (camera_id, ts);

-- Label filtering index (used when ?labels= filter is active).
CREATE INDEX IF NOT EXISTS events_camera_label_ts
    ON events (camera_id, label, ts);
