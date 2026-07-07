-- 0032_system_alerts.sql
--
-- P0-HEALTH-NOTIFY: system/health "footage-loss" alerts, routed through the
-- SAME notification channels (Discord/Slack/Pushover/Telegram/ntfy/webhook) as
-- the existing motion/detection engine, but driven by a SEPARATE rule table —
-- these events have no camera-owner, presence, or object-label dimension, so
-- reusing `notification_rules` would force irrelevant columns onto them.
--
-- Fully idempotent (IF NOT EXISTS / ON CONFLICT DO NOTHING) so it is safe to
-- (re-)apply on a long-lived database, matching every other migration here.

-- Per-event-type configuration: on/off + an optional numeric threshold (unit
-- is event-specific: seconds for offline/heartbeat timers, a 0..1 fraction for
-- low-disk headroom) + whether the event bypasses quiet hours.
--
-- One row per `event_key`. Seeded below with the design defaults from
-- RELEASE-PLAN.md: footage-loss-critical events (recorder down, camera
-- offline, premature rollover, backup failure) default `bypass_quiet_hours =
-- true` — a dead recorder at 3am is exactly when you want to know. The
-- softer/advisory events (low disk, policy over cap, Frigate/MQTT disconnect)
-- default `bypass_quiet_hours = false`.
CREATE TABLE IF NOT EXISTS system_alert_rules (
    event_key           text        PRIMARY KEY,
    enabled             boolean     NOT NULL DEFAULT true,
    -- Event-specific meaning; NULL uses the engine's built-in default for that key:
    --   recorder_offline     — heartbeat staleness threshold, seconds
    --   camera_offline       — per-camera no-new-segment threshold, seconds
    --   premature_rollover   — none (fires on the eviction-below-retention signal itself)
    --   low_disk             — free-space fraction floor (0..1) below which it fires
    --   policy_over_cap      — none (fires whenever a policy is at/over its size cap)
    --   backup_failed        — none (fires on a reported backup-failure signal)
    --   frigate_disconnected — MQTT/detection-silence threshold, seconds
    threshold_secs      integer,
    threshold_fraction  real,
    bypass_quiet_hours  boolean     NOT NULL DEFAULT false,
    cooldown_secs       integer     NOT NULL DEFAULT 900,
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Append-only occurrence log the engine polls, mirroring the `events` table
-- shape closely enough to reuse the same "poll since last_ts, fire once"
-- pattern. `camera_id` is NULL for system-wide events (recorder/backup/Frigate).
-- No FK on camera_id: a camera can be deleted after the event fires without
-- orphaning cleanup concerns (this is a log, not live state).
CREATE TABLE IF NOT EXISTS system_events (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    event_key  text        NOT NULL,
    camera_id  uuid,
    ts         timestamptz NOT NULL DEFAULT now(),
    detail     text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS system_events_ts ON system_events(ts);
CREATE INDEX IF NOT EXISTS system_events_key_cam ON system_events(event_key, camera_id, ts DESC);

-- Seed the known event keys with their design-default flags. ON CONFLICT DO
-- NOTHING so re-applying (or a future migration adjusting the seed) never
-- clobbers an admin's saved preference.
INSERT INTO system_alert_rules (event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs) VALUES
    ('recorder_offline',     true, 60,   NULL, true,  900),
    ('camera_offline',       true, 120,  NULL, true,  900),
    ('premature_rollover',   true, NULL, NULL, true,  900),
    ('backup_failed',        true, NULL, NULL, true,  3600),
    ('low_disk',             true, NULL, 0.05, false, 3600),
    ('policy_over_cap',      true, NULL, NULL, false, 3600),
    ('frigate_disconnected', true, 300,  NULL, false, 900)
ON CONFLICT (event_key) DO NOTHING;

-- Global quiet-hours window for SYSTEM alerts only. System events have no
-- per-user owner (unlike `notification_rules`, which is per-(user, camera)),
-- so a single admin-configured window on the existing `notification_settings`
-- singleton is the natural fit — reusing the row that already carries the
-- global on/off switch. NULL (either bound) = no quiet hours configured,
-- matching the existing per-user default. Each `system_alert_rules` row's
-- `bypass_quiet_hours` flag (seeded above) decides whether THIS window
-- applies to a given event at all.
ALTER TABLE notification_settings
    ADD COLUMN IF NOT EXISTS quiet_start_hour integer,
    ADD COLUMN IF NOT EXISTS quiet_end_hour   integer;
