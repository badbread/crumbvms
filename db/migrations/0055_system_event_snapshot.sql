-- 0055_system_event_snapshot.sql
--
-- LPR alert snapshots: let a `plate_watchlist_hit` alert carry the detection
-- snapshot (the car+plate frame Frigate captured) so image-capable notification
-- channels (Discord/Pushover/Telegram) can attach it, exactly like motion
-- alerts already do. `system_events` gains an optional `snapshot_url` (the
-- provider-relative snapshot path from the matching plate read); the
-- notification engine resolves + fetches it and attaches per channel, gated by
-- that channel's existing `include_snapshot` toggle (the user's on/off).
--
-- Nullable, so every existing `insert_system_event` path (recorder/health
-- alerts, which have no image) simply leaves it NULL. Idempotent.

ALTER TABLE system_events
    ADD COLUMN IF NOT EXISTS snapshot_url text;
