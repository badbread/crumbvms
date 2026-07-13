-- Per-camera recorded-audio status, so the admin console can show when a
-- camera's audio is being TRANSCODED (its source sample rate is > 48 kHz, which
-- Android/web hardware AAC decoders reject) versus bit-exact COPIED. Written by
-- the recorder's record loop at each (re)connect from the probed source rate;
-- read by GET /config/decode-status (LEFT JOINed onto the decode-status list).
--
-- Mirrors camera_decode_status's convention: one row per actively-recording
-- camera, absence means "unknown / not recording". Cleaned up with the camera
-- (FK ON DELETE CASCADE) and when a worker stops.
CREATE TABLE IF NOT EXISTS camera_audio_status (
    camera_id     uuid        PRIMARY KEY
                              REFERENCES cameras(id) ON DELETE CASCADE,
    -- Source audio sample rate in Hz, probed at record start. NULL when the
    -- probe failed / the camera streams no audio.
    sample_rate   integer,
    -- true  = recorder is re-encoding this camera's audio to 48 kHz AAC
    --         (source rate > 48 kHz, or an unknown/failed probe);
    -- false = bit-exact copy (source already client-safe, or audio disabled).
    transcoding   boolean     NOT NULL DEFAULT false,
    updated_at    timestamptz NOT NULL DEFAULT now()
);
