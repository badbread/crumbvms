-- 0057_update_available_alert.sql
--
-- Registers `update_available` as a system/health alert event_key in
-- `system_alert_rules` (seeded by 0032_system_alerts.sql), so the API's
-- update-notifier (services/api/src/updates.rs `run_update_notifier`) can route
-- a "a newer Crumb release is available" signal through the SAME notification
-- channels (Discord/Slack/Pushover/Telegram/ntfy/webhook) as the health and
-- plate alerts, instead of the event being dropped by the notification engine's
-- "unknown event_key -> skip" guard (services/api/src/notifications.rs
-- `dispatch_system_events_tick`).
--
-- OFF BY DEFAULT (`enabled = false`), deliberately unlike every other seeded
-- system-alert row (which default `true`). This mirrors the update-available
-- check's own opt-in / off-by-default posture (docs/DECISIONS.md
-- "Update-available check", D3: a fresh install makes ZERO requests to GitHub
-- until the operator opts in). Turning update notifications into a channel page
-- would otherwise be a phone-home behavior a privacy-conscious install has to
-- notice and turn off; instead it is a value-add the operator turns on. Note
-- the double gate: the notifier only emits this event when the update check
-- itself is enabled (server_settings.update_check_enabled / UPDATE_CHECK_ENABLED)
-- AND this rule is on.
--
-- Advisory, not urgent: `bypass_quiet_hours = false` (a new release at 3am is
-- not worth waking anyone). No threshold (the notifier's own per-version latch
-- is the edge-trigger). Long cooldown (6h) as a spam backstop behind that latch;
-- real releases are days/weeks apart so it never collapses two distinct
-- versions.
--
-- Idempotent (ON CONFLICT DO NOTHING), matching every other migration here —
-- never clobbers an admin's saved preference on re-apply.

INSERT INTO system_alert_rules (event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs) VALUES
    ('update_available', false, NULL, NULL, false, 21600)
ON CONFLICT (event_key) DO NOTHING;
