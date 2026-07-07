-- Clips: server-configurable pre-roll (seconds of footage before the event that a
-- clip starts at). Admin-editable in Server settings; default 2s, clamped 0..9 by
-- the API. Post-roll stays fixed for now. Idempotent.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS clip_pre_roll_seconds INT NOT NULL DEFAULT 2;
