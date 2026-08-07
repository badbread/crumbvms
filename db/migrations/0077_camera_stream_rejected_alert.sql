-- 0077_camera_stream_rejected_alert.sql
--
-- Registers the `camera_stream_rejected` system/health alert event_key in
-- `system_alert_rules` (seeded by 0032_system_alerts.sql), so the API's
-- `db::insert_system_event(pool, "camera_stream_rejected", ...)` call actually
-- reaches an operator instead of being dropped by the notification engine's
-- "unknown event_key -> skip" guard (services/api/src/notifications.rs
-- `dispatch_system_events_tick`).
--
-- `camera_stream_rejected` (issue #519) — Crumb's go2rtc REFUSED to register a
-- camera's stream: the reconcile pass PUT the stream, go2rtc answered a 4xx, and
-- a confirming GET /api/streams showed the stream is genuinely absent. The
-- camera row exists and looks completely normal in the console, but there is no
-- restream behind it, so the recorder reconnect-loops forever and ZERO footage
-- is recorded. The overwhelmingly common cause is a source URL with a literal
-- space (go2rtc: "streams: source with spaces may be insecure") pasted straight
-- out of a camera's own web UI; percent-encoding the path fixes it. Fired by
-- services/api/src/go2rtc.rs (`reconcile` -> `report_stream_rejection`) with the
-- camera id and go2rtc's own rejection reason in the detail, on the
-- accepted->rejected TRANSITION only (an in-memory latch, mirroring the
-- camera_offline watchdog, keeps a permanently-bad URL from re-firing every
-- reconcile pass).
--
-- URGENT (actual footage loss, and invisible without this alert): bypasses quiet
-- hours; no threshold (the confirming GET is the gate); 900s cooldown so a
-- process restart that re-arms the in-memory latch can't turn into a burst.
--
-- Idempotent (ON CONFLICT DO NOTHING), matching every other migration here --
-- never clobbers an admin's saved preference on re-apply.

INSERT INTO system_alert_rules (event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs) VALUES
    ('camera_stream_rejected', true, NULL, NULL, true, 900)
ON CONFLICT (event_key) DO NOTHING;
