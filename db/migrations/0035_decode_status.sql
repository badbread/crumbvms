-- Migration 0035: motion-decode truth telemetry
--
-- The admin console lets an operator pick a motion-decode backend (auto /
-- cuda / vaapi / cpu via server_settings.motion_hwaccel), but the recorder
-- silently falls back to CPU when the requested accelerator isn't usable
-- inside its container (render node not mapped, NVDEC session cap, no GPU).
-- These two tables let the API report what the recorder is ACTUALLY doing so
-- the UI can show "requested vaapi → running on cpu (renderD128 not mapped)".
--
-- * recorder_capabilities — singleton (id = 1), refreshed on every recorder
--   boot: which accel devices exist INSIDE the recorder container
--   (/dev/dri/renderD*, /dev/nvidia*) and which hwaccels the bundled ffmpeg
--   was compiled with (`ffmpeg -hwaccels`).
--
-- * camera_decode_status — one row per camera, upserted by the motion task
--   each time it (re)starts its ffmpeg decode child: requested backend,
--   ACTIVE backend (derived from the launched ffmpeg args + device presence),
--   and a human-readable fallback_reason when they differ. Rows cascade with
--   the camera; the recorder deletes a row when its worker is stopped for a
--   disabled/removed camera.
--
-- No seed rows: absence means "recorder has never reported" (older recorder
-- image or not booted yet) — the API returns capabilities: null / an empty
-- cameras list, which the UI should render as "no report yet", not as CPU.
--
-- IF NOT EXISTS keeps this idempotent so the migration runner can re-apply it.
CREATE TABLE IF NOT EXISTS recorder_capabilities (
    id              smallint    PRIMARY KEY DEFAULT 1,
    -- Full paths of DRI render nodes present in the container,
    -- e.g. {"/dev/dri/renderD128"}. Empty ⇒ VAAPI cannot work.
    dri_devices     text[]      NOT NULL DEFAULT '{}',
    -- Any /dev/nvidia* device node present (NVIDIA GPU mapped in).
    nvidia          boolean     NOT NULL DEFAULT false,
    -- Hwaccels the bundled ffmpeg was COMPILED with (`ffmpeg -hwaccels`);
    -- compiled-in support, not runtime usability.
    ffmpeg_hwaccels text[]      NOT NULL DEFAULT '{}',
    detected_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT recorder_capabilities_singleton CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS camera_decode_status (
    camera_id       uuid        PRIMARY KEY
                                REFERENCES cameras(id) ON DELETE CASCADE,
    -- Backend the operator requested (effective server_settings → env value
    -- at worker spawn): 'auto' | 'cuda' | 'vaapi' | 'cpu'.
    requested       text        NOT NULL,
    -- Backend the live ffmpeg decode child was launched with:
    -- 'cuda' | 'vaapi' | 'cpu' | 'none' (no local decode — Frigate-sourced
    -- motion or no sub-stream).
    active          text        NOT NULL,
    -- Short human-readable explanation when requested != active (or when the
    -- launched backend is expected to fail); NULL when all is well.
    fallback_reason text,
    updated_at      timestamptz NOT NULL DEFAULT now()
);
