-- 0040_motion_cache_unavailable_alert.sql
--
-- commercial-VMS-style motion recording (RAM pre-buffer + persist-on-motion):
-- registers `motion_cache_unavailable` as a first-class system/health alert
-- event_key in `system_alert_rules` (seeded by migration 0032_system_alerts.sql),
-- so the recorder's `db::insert_system_event(pool, "motion_cache_unavailable", ...)`
-- calls (services/recorder/src/recording.rs, section "2b. Motion-mode RAM cache
-- dir") actually reach an operator instead of being silently dropped by the
-- notification engine's "unknown event_key -> skip" guard
-- (services/api/src/notifications.rs).
--
-- Fired when a Motion-mode camera's tmpfs RAM cache can't be used — the cache
-- dir path was rejected (nested under/equal to a storage root) or
-- `create_dir_all` failed (e.g. the tmpfs mounted root-owned instead of
-- `mode: 01777`, so the recorder's non-root uid 1001 gets EACCES; see
-- docs/MOTION-RECORDING.md) — at which point the recorder fails OPEN and
-- persists every segment to disk (as if Continuous) until the next worker
-- respawn re-resolves the cache dir. Footage is NOT lost (see
-- docs/RECORDER-CORRECTNESS.md item 19), only the disk-saving benefit of
-- Motion mode is temporarily suspended, so this is an ADVISORY event —
-- defaults mirror the other advisory-tier events (`motion_detector_unhealthy`,
-- `frigate_disconnected`): enabled, no quiet-hours bypass, 900s cooldown so a
-- repeatedly-respawning worker doesn't spam.
--
-- Idempotent (ON CONFLICT DO NOTHING), matching every other migration here —
-- never clobbers an admin's saved preference on re-apply.

INSERT INTO system_alert_rules (event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs) VALUES
    ('motion_cache_unavailable', true, NULL, NULL, false, 900)
ON CONFLICT (event_key) DO NOTHING;
