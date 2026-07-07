-- 0017_notification_settings.sql
--
-- Global master enable/disable switch for the notification engine.
-- Kept separate from server_settings on purpose — toggling notifications must
-- NOT bump the streaming-config version (which triggers go2rtc reconciles).
--
-- Singleton table (id = 1, enforced by a CHECK constraint). Fully idempotent
-- (IF NOT EXISTS + ON CONFLICT DO NOTHING) so it can be re-applied safely.

CREATE TABLE IF NOT EXISTS notification_settings (
    id         smallint    PRIMARY KEY DEFAULT 1,
    enabled    boolean     NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT notification_settings_singleton CHECK (id = 1)
);

-- Seed the singleton row; no-op on an existing DB.
INSERT INTO notification_settings (id, enabled)
VALUES (1, true)
ON CONFLICT (id) DO NOTHING;
