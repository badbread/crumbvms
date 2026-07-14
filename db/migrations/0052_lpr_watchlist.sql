-- 0052_lpr_watchlist.sql
--
-- LPR Phase 2: plate watchlist + alerts. A curated set of plates the operator
-- wants to be notified about (a BOLO list, a "tell me when this car arrives"
-- list). When LPR capture ingests a read whose normalized plate matches an
-- entry with `notify = true`, the ingester emits a `plate_watchlist_hit` system
-- event, which the notification engine (notifications.rs) fans out over the
-- SAME channels (Discord/Slack/Pushover/Telegram/ntfy/webhook) as every other
-- alert — see 0032_system_alerts.sql. Default-off feature layered on the
-- default-off LPR capture (0051_lpr.sql): no watchlist entries => no alerts.
--
-- Fully idempotent (IF NOT EXISTS / ON CONFLICT DO NOTHING) so it is safe to
-- (re-)apply on a long-lived database, matching every other migration here.

CREATE TABLE IF NOT EXISTS lpr_watchlist (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Normalized plate (uppercase ASCII alphanumerics, see normalize_plate).
    -- Matched exactly against an ingested read's normalized plate.
    plate      text        NOT NULL,
    -- Friendly name shown in alerts + clients ("Mom's car", "Stolen — BOLO").
    label      text,
    note       text,
    -- Optional UI tag color (#rrggbb); clients may ignore it.
    color      text,
    -- Whether a match fires an alert. false = "track/label but stay silent".
    notify     boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- One entry per normalized plate: the write path upserts on this, and a
-- duplicate BOLO for the same plate is a mistake, not two rows.
CREATE UNIQUE INDEX IF NOT EXISTS lpr_watchlist_plate ON lpr_watchlist(plate);

-- Register the alert rule so `plate_watchlist_hit` appears in the admin
-- Notifications panel and routes over the configured channels, exactly like the
-- health alerts. cooldown_secs 300 is a per-camera backstop (a moving-plate
-- read is already one-per-vehicle-pass; this only damps rapid re-passes).
-- bypass_quiet_hours defaults false: a curated-convenience alert, not a
-- footage-loss emergency — the admin can flip it for a genuine BOLO list.
INSERT INTO system_alert_rules
    (event_key, enabled, threshold_secs, threshold_fraction, bypass_quiet_hours, cooldown_secs)
VALUES
    ('plate_watchlist_hit', true, NULL, NULL, false, 300)
ON CONFLICT (event_key) DO NOTHING;
