-- 0015_notifications.sql
--
-- First-party push-notification system. Registered push devices, per-user /
-- per-camera rules (incl. the presence dimension), snoozes, and a delivery log.
-- All additive + idempotent (IF NOT EXISTS) so it is safe to (re-)apply on a
-- long-lived database. Motion events themselves are NOT created here — they now
-- land in the existing `events` table (source_id = 'motion'); this migration only
-- adds the notification-specific tables.

-- A registered push target (one row per app install per user).
CREATE TABLE IF NOT EXISTS push_devices (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Stable per-install identity (the app generates + persists a random id). This is
    -- the device's identity for re-registration, since websocket devices have no push
    -- token. The transport-specific token (below) can change/refresh independently.
    install_id          text NOT NULL,
    platform            text NOT NULL DEFAULT 'android'
                            CHECK (platform IN ('android', 'ios', 'web')),
    -- Pluggable delivery: a self-hosted websocket (foreground service), a
    -- UnifiedPush endpoint, or FCM. The engine dispatches via the matching transport.
    transport           text NOT NULL DEFAULT 'websocket'
                            CHECK (transport IN ('websocket', 'unifiedpush', 'fcm')),
    push_token          text,                  -- UnifiedPush endpoint URL / FCM token; NULL for websocket
    device_name         text,
    presence            text NOT NULL DEFAULT 'away'
                            CHECK (presence IN ('home', 'away')),
    presence_source     text,                  -- 'heuristic' | 'app' | 'webhook'
    presence_updated_at timestamptz,
    last_seen           timestamptz NOT NULL DEFAULT now(),
    created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_devices_user ON push_devices(user_id);
-- A given install registers once per user (re-register updates the row in place).
CREATE UNIQUE INDEX IF NOT EXISTS push_devices_user_install
    ON push_devices(user_id, install_id);

-- Per-user notification rule. camera_id NULL = the user's default applied to any
-- camera without its own override.
CREATE TABLE IF NOT EXISTS notification_rules (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    camera_id         uuid REFERENCES cameras(id) ON DELETE CASCADE,
    -- The presence dimension: never / only when this device is away / always.
    presence_mode     text NOT NULL DEFAULT 'away_only'
                          CHECK (presence_mode IN ('off', 'away_only', 'always')),
    notify_motion     boolean NOT NULL DEFAULT true,
    notify_detection  boolean NOT NULL DEFAULT true,
    object_labels     text[],                 -- e.g. {person,car}; NULL = any label (Frigate)
    min_score         real,                   -- NULL = no floor
    min_duration_secs integer,                -- NULL = no minimum event duration
    quiet_start_hour  integer,                -- 0..23, NULL = no quiet hours
    quiet_end_hour    integer,
    cooldown_secs     integer NOT NULL DEFAULT 90,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
-- One rule per (user, camera); the per-user default is the row with camera_id IS NULL.
CREATE UNIQUE INDEX IF NOT EXISTS notification_rules_user_cam
    ON notification_rules(user_id, camera_id) WHERE camera_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS notification_rules_user_default
    ON notification_rules(user_id) WHERE camera_id IS NULL;
CREATE INDEX IF NOT EXISTS notification_rules_camera ON notification_rules(camera_id);

-- An active snooze for a device (camera_id NULL = all cameras for that device).
CREATE TABLE IF NOT EXISTS notification_snoozes (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id  uuid NOT NULL REFERENCES push_devices(id) ON DELETE CASCADE,
    camera_id  uuid REFERENCES cameras(id) ON DELETE CASCADE,
    until      timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notification_snoozes_device
    ON notification_snoozes(device_id, until);

-- Delivery / decision log: history, the in-app "recent alerts" list, and debugging
-- why something did or didn't fire. No FK on event_id (events may be pruned).
CREATE TABLE IF NOT EXISTS notification_log (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id   uuid,
    camera_id  uuid,
    device_id  uuid,                  -- the push device a notification went to (app push)
    channel_id uuid,                  -- the third-party channel a notification went to
    kind       text NOT NULL,         -- 'motion' | 'detection'
    status     text NOT NULL CHECK (status IN ('sent', 'failed', 'suppressed')),
    reason     text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notification_log_created
    ON notification_log(created_at DESC);
CREATE INDEX IF NOT EXISTS notification_log_camera
    ON notification_log(camera_id, created_at DESC);

-- Third-party outbound notifier integrations (Slack/Discord/Pushover/etc.). A second
-- category of notifier alongside app push: pure outbound HTTP, no Crumb app required.
-- user_id NULL = a global channel (admin-managed); otherwise owned by that user.
CREATE TABLE IF NOT EXISTS notification_channels (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid REFERENCES users(id) ON DELETE CASCADE,
    kind             text NOT NULL
                         CHECK (kind IN ('discord', 'slack', 'pushover', 'telegram', 'ntfy', 'webhook')),
    name             text NOT NULL,
    enabled          boolean NOT NULL DEFAULT true,
    -- Per-kind connection secret(s): {"webhook_url":..} / {"user_key":..,"app_token":..} /
    -- {"bot_token":..,"chat_id":..} / {"topic_url":..}. Masked in GET responses.
    config           jsonb NOT NULL,
    -- Filters (presence does NOT apply to channels — they have no home/away).
    camera_ids       uuid[],            -- NULL/empty = all cameras the owner can access
    notify_motion    boolean NOT NULL DEFAULT true,
    notify_detection boolean NOT NULL DEFAULT true,
    object_labels    text[],
    min_score        real,
    quiet_start_hour integer,
    quiet_end_hour   integer,
    cooldown_secs    integer NOT NULL DEFAULT 90,
    include_snapshot boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notification_channels_user ON notification_channels(user_id);
CREATE INDEX IF NOT EXISTS notification_channels_enabled ON notification_channels(enabled);
