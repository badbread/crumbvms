-- Crumb NVR — initial schema
-- Source of truth: docs/00-architecture.md ("Data model"). PostgreSQL 14+.
-- gen_random_uuid() is in core since PG13. Applied automatically by the postgres
-- container on first init (mounted at /docker-entrypoint-initdb.d).

BEGIN;

-- Dumb named locations. All policy lives on the camera, NOT here.
CREATE TABLE storages (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL UNIQUE,          -- human label, e.g. "NVMe-Live", "NAS-Archive"
                                               -- UNIQUE required: seed is idempotent via ON CONFLICT(name)
    path        text NOT NULL,                 -- filesystem path the recorder can write
    total_bytes bigint,                        -- optional, for quota/UI
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- The GLOBAL DEFAULT lives here as a single row (is_default=true). Each camera
-- gets its own policy row cloned from the default, with individual fields overridden.
CREATE TABLE recording_policies (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    is_default              boolean NOT NULL DEFAULT false,
    mode                    text    NOT NULL DEFAULT 'continuous'
                                CHECK (mode IN ('continuous','motion')),
    live_storage_id         uuid REFERENCES storages(id),
    live_retention_hours    integer NOT NULL DEFAULT 48,          -- e.g. 48 = "2 days on live"
    archive_enabled         boolean NOT NULL DEFAULT false,
    archive_storage_id      uuid REFERENCES storages(id),
    archive_schedule        text    DEFAULT '0 3 * * *',          -- cron-style, e.g. 3am daily
    archive_retention_hours integer,
    motion_pre_seconds      integer NOT NULL DEFAULT 5,
    motion_post_seconds     integer NOT NULL DEFAULT 10,
    motion_sensitivity      text    NOT NULL DEFAULT 'dynamic'
                                CHECK (motion_sensitivity IN ('dynamic','manual')),
    motion_threshold        real,         -- manual floor as FRACTION of frame (0..1); same unit as motion_score
    motion_keyframes_only   boolean NOT NULL DEFAULT false,
    record_stream           text    NOT NULL DEFAULT 'main'
                                CHECK (record_stream IN ('main','sub'))
);

-- Enforce exactly one default policy row.
CREATE UNIQUE INDEX one_default_policy ON recording_policies (is_default) WHERE is_default;

CREATE TABLE cameras (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text NOT NULL,
    enabled      boolean NOT NULL DEFAULT true,
    go2rtc_name  text NOT NULL UNIQUE,          -- key in go2rtc (Frigate's, in the prototype)
                                                -- UNIQUE: seed upserts on conflict(go2rtc_name)
    main_url     text NOT NULL,                 -- rtsp main stream (recording + maximized + export)
    sub_url      text,                          -- rtsp sub stream (wall tiles + motion analysis)
    policy_id    uuid NOT NULL REFERENCES recording_policies(id),
    motion_mask  jsonb,                         -- polygon zones to ignore
    onvif_motion boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- THE INDEX. One row per recorded fMP4 segment. Single source of truth for
-- playback/timeline/export/archive. Moving a file = updating storage_id + path here.
CREATE TABLE segments (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id   uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    storage_id  uuid NOT NULL REFERENCES storages(id),   -- current location; updated on archive move
    stage       text NOT NULL DEFAULT 'live' CHECK (stage IN ('live','archive')),
    path        text NOT NULL,                            -- relative path within storage
    stream      text NOT NULL CHECK (stream IN ('main','sub')),
    start_ts    timestamptz NOT NULL,
    end_ts      timestamptz NOT NULL,
    duration_ms integer NOT NULL,
    has_motion  boolean NOT NULL DEFAULT false,           -- timeline color-coding + future smart search
    size_bytes  bigint NOT NULL
);

-- (camera_id, start_ts) is critical for fast seek.
CREATE INDEX segments_camera_start       ON segments (camera_id, start_ts);
CREATE INDEX segments_camera_stage_start ON segments (camera_id, stage, start_ts);

CREATE TABLE users (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username      text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    role          text NOT NULL CHECK (role IN ('admin','viewer')),
    camera_ids    jsonb NOT NULL DEFAULT '[]'::jsonb   -- viewer's assigned cameras; admin sees all
);

-- ---------------------------------------------------------------------------
-- PHASE 2 stubs — seams only, no logic in v1 (see docs/00-architecture.md).
-- ---------------------------------------------------------------------------
CREATE TABLE events (                          -- Frigate event markers
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id  uuid REFERENCES cameras(id) ON DELETE CASCADE,
    ts         timestamptz NOT NULL,
    label      text,
    score      real,
    thumb_path text
);
CREATE TABLE bookmarks (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id  uuid REFERENCES cameras(id) ON DELETE CASCADE,
    ts         timestamptz NOT NULL,
    note       text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE evidence_locks (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id uuid REFERENCES cameras(id) ON DELETE CASCADE,
    start_ts  timestamptz NOT NULL,
    end_ts    timestamptz NOT NULL,
    reason    text
);
CREATE TABLE smart_search_results (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id  uuid REFERENCES cameras(id) ON DELETE CASCADE,
    ts         timestamptz NOT NULL,
    region     jsonb,
    score      real
);

COMMIT;
