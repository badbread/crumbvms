-- 0043_storage_persist_failed_alert.sql
--
-- Registers `storage_persist_failed` as a first-class system/health alert
-- event_key in `system_alert_rules` (seeded by 0032_system_alerts.sql), so the
-- recorder's `db::insert_system_event(pool, "storage_persist_failed", ...)` call
-- (services/recorder/src/recording.rs, `persist_cached_segment`) reaches an
-- operator instead of being dropped by the notification engine's
-- "unknown event_key -> skip" guard (services/api/src/notifications.rs).
--
-- Fired when a Motion-mode camera's RAM (tmpfs) cache needs to spill/persist a
-- buffered segment to disk but the copy INTO storage fails — typically the
-- storage tier is full (ENOSPC) or read-only (EROFS). Unlike
-- `motion_cache_unavailable` (advisory: footage is NOT lost, the recorder just
-- falls open to direct-to-disk), this condition THREATENS footage — the segment
-- is still in the RAM buffer and cannot be written, so it is lost if the tmpfs
-- cache is reclaimed or the process restarts. "Spill never drops"
-- (docs/RECORDER-CORRECTNESS.md item 20) holds only while the destination
-- accepts writes; this event surfaces the case where it can't. It is therefore
-- URGENT: bypasses quiet hours, fires immediately (no threshold). 900s cooldown
-- so a spill that hits many buffered segments at once doesn't spam (the recorder
-- also throttles the emit to once/minute per process). Audit 2026-07-05 (R2).
--
-- Idempotent (ON CONFLICT DO NOTHING) — never clobbers an admin's saved pref.

INSERT INTO system_alert_rules (event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs) VALUES
    ('storage_persist_failed', true, NULL, NULL, true, 900)
ON CONFLICT (event_key) DO NOTHING;
