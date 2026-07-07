-- 0038_motion_detector_unhealthy_alert.sql
--
-- commercial-VMS-style motion recording (RAM pre-buffer + persist-on-motion), spec
-- item 4 (fail-open safety rail): registers `motion_detector_unhealthy` as a
-- first-class system/health alert event_key in `system_alert_rules` (seeded by
-- migration 0032_system_alerts.sql), so the recorder's
-- `db::insert_system_event(pool, "motion_detector_unhealthy", ...)` calls
-- (services/recorder/src/motion.rs `report_health`) actually reach an operator
-- instead of being silently dropped by the notification engine's
-- "unknown event_key -> skip" guard (services/api/src/notifications.rs).
--
-- Fired when a Motion-mode camera's motion detector goes unhealthy (the
-- 12s frame-stall / 15s frame-receipt watchdog fires, the motion task dies,
-- Frigate motion is selected but not configured, or the camera has no
-- sub-stream) — at that point the recording task fails OPEN and persists
-- every segment (as if Continuous) until health returns, so this is an
-- ADVISORY event (footage is NOT being lost — only the disk-saving benefit of
-- Motion mode is temporarily suspended) rather than a footage-loss-critical
-- one. Defaults mirror the other advisory-tier events (`policy_over_cap`,
-- `frigate_disconnected`): enabled, no quiet-hours bypass, 900s cooldown so a
-- flapping detector doesn't spam.
--
-- Idempotent (ON CONFLICT DO NOTHING), matching every other migration here —
-- never clobbers an admin's saved preference on re-apply.

INSERT INTO system_alert_rules (event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs) VALUES
    ('motion_detector_unhealthy', true, NULL, NULL, false, 900)
ON CONFLICT (event_key) DO NOTHING;
