-- Migration 0034: Frigate MQTT connectivity heartbeat
--
-- The API's Frigate detection provider upserts this single row (id = 1) on each
-- successful MQTT ConnAck and periodically while the connection is live (on
-- keepalive/pings and events). The system-health watchdog reads `updated_at` to
-- fire the `frigate_disconnected` alert when Frigate WAS connected and has gone
-- stale beyond the rule's threshold.
--
-- UNLIKE recorder_heartbeat (0004), NO row is seeded here. The row only appears
-- once the provider connects at least once, so the watchdog can tell:
--   * no row      -> Frigate never configured / never connected -> SKIP (no false
--                    alarm on a deployment that doesn't use Frigate)
--   * fresh row   -> connected -> OK
--   * stale row   -> was connected, now gone -> FIRE frigate_disconnected
--
-- IF NOT EXISTS keeps this idempotent so the migration runner can re-apply it.
CREATE TABLE IF NOT EXISTS frigate_heartbeat (
    id         smallint    PRIMARY KEY DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT frigate_heartbeat_singleton CHECK (id = 1)
);
