-- Migration 0039: motion RAM-cache telemetry
--
-- The admin console lets an operator flip a recording profile to "Motion",
-- which now buffers segments in a tmpfs RAM cache instead of writing straight
-- to disk (see docs/MOTION-RECORDING.md, MOTION_CACHE_DIR / MOTION_CACHE_TMPFS_BYTES).
-- There was previously no visibility into how much of that RAM budget is
-- actually in use, or whether the configured cameras will fit in it. These two
-- tables mirror the existing decode-status telemetry pattern (migration 0035:
-- recorder_capabilities + camera_decode_status) so the recorder can report its
-- own truth and the API can surface it without inventing a new mechanism.
--
-- * motion_cache_status — singleton (id = 1), refreshed on a periodic tick by
--   the recorder (same process that owns the motion cache dir): filesystem
--   total/free bytes for MOTION_CACHE_DIR (via statvfs, already read for the
--   cache-pressure spill check), whether caching is active for ANY Motion-mode
--   camera right now, and whether MOTION_RECORDING_SHADOW is on.
--
-- * camera_motion_cache_status — one row per Motion-mode camera, upserted on
--   the same tick: how many segments are currently sitting in that camera's
--   RAM ring buffer and their summed size. Continuous-mode cameras never get a
--   row here (mirrors camera_decode_status's "absence means not applicable").
--
-- No seed rows: absence means "recorder has never reported this tick" (older
-- recorder image or not booted yet) — the API returns null/empty, which the
-- UI renders as "no cache telemetry yet", not as zero usage.
--
-- IF NOT EXISTS keeps this idempotent so the migration runner can re-apply it.
CREATE TABLE IF NOT EXISTS motion_cache_status (
    id              smallint    PRIMARY KEY DEFAULT 1,
    -- Free bytes on the filesystem backing MOTION_CACHE_DIR (statvfs).
    free_bytes      bigint      NOT NULL,
    -- Total bytes of that filesystem (the tmpfs sizing, e.g. MOTION_CACHE_TMPFS_BYTES).
    total_bytes     bigint      NOT NULL,
    -- Whether ANY Motion-mode camera currently has its cache dir active
    -- (false when every Motion camera has fallen back to direct-to-storage,
    -- or when shadow mode is on globally).
    caching_active  boolean     NOT NULL DEFAULT false,
    -- MOTION_RECORDING_SHADOW — every segment is persisted regardless of the
    -- buffer's verdict; the cache/ring numbers are for validation only.
    shadow_mode     boolean     NOT NULL DEFAULT false,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT motion_cache_status_singleton CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS camera_motion_cache_status (
    camera_id       uuid        PRIMARY KEY
                                REFERENCES cameras(id) ON DELETE CASCADE,
    -- Number of segments currently sitting in this camera's RAM ring buffer
    -- (MotionBuffer::pending). 0 when the cache is inactive/fallen-back for
    -- this camera, even though it is still Motion-mode.
    ring_segments   integer     NOT NULL DEFAULT 0,
    -- Summed size_bytes of those pending segments.
    ring_bytes      bigint      NOT NULL DEFAULT 0,
    updated_at      timestamptz NOT NULL DEFAULT now()
);
