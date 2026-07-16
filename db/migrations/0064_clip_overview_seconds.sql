-- Clips: server-configurable overview length (seconds a generated clip renders).
-- A clip is a short, representative OVERVIEW of an event, not the full event
-- (the timeline owns whole-event viewing). Admin-editable in Server settings;
-- default 30s, clamped 10..=120 by the API. A compiled 120s hard ceiling in the
-- render path is the permanent safety floor. Idempotent.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS clip_overview_seconds INT NOT NULL DEFAULT 30;
