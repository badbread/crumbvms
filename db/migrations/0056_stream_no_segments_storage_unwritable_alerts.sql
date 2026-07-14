-- 0056_stream_no_segments_storage_unwritable_alerts.sql
--
-- Registers two new recorder footage-loss system/health alert event_keys in
-- `system_alert_rules` (seeded by 0032_system_alerts.sql), so the recorder's
-- `db::insert_system_event(pool, "<key>", ...)` calls actually reach an operator
-- instead of being dropped by the notification engine's "unknown event_key ->
-- skip" guard (services/api/src/notifications.rs `dispatch_system_events_tick`).
--
-- `stream_no_segments` — a camera's ffmpeg keeps CONNECTING (no EOF, no error)
-- but never closes a segment within the stall watchdog, so the watchdog kills
-- and reconnects it forever and ZERO footage is recorded. This is the
-- smart-codec / long-GOP failure: with `-c copy -f segment` a segment only
-- closes on a keyframe, so a Hikvision/Dahua "H.264+/H.265+" adaptive/long-GOP
-- (or very low-fps) camera can produce no segment for longer than the watchdog
-- and silently record nothing. Fired by services/recorder/src/recording.rs
-- (`run`) after N (=3) consecutive stall->reconnect cycles that produced no
-- segments — detail names the camera and suggests raising
-- SEGMENT_RECEIPT_TIMEOUT_SECS or disabling the smart codec. It is URGENT
-- (actual footage loss): bypasses quiet hours; no threshold (the recorder's
-- 3-cycle counter is the gate); 900s cooldown so a persistently-stalling camera
-- doesn't spam.
--
-- `storage_unwritable` — the recorder cannot create a camera's media directory
-- under the storage root because the host media dir is root-owned and the
-- recorder runs as non-root uid 1001 (the default-install footgun): every
-- reconnect fails EACCES and NO footage is saved. Fired by
-- services/recorder/src/recording.rs (`run_ffmpeg_loop`, section "2. Build
-- output path") on a PermissionDenied `create_dir_all`. Also URGENT: bypasses
-- quiet hours; no threshold; 900s cooldown.
--
-- Idempotent (ON CONFLICT DO NOTHING), matching every other migration here —
-- never clobbers an admin's saved preference on re-apply.

INSERT INTO system_alert_rules (event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs) VALUES
    ('stream_no_segments', true, NULL, NULL, true, 900),
    ('storage_unwritable', true, NULL, NULL, true, 900)
ON CONFLICT (event_key) DO NOTHING;
