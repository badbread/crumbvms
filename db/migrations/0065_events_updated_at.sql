-- Events: `updated_at` liveness column for the API-side event janitor. Every
-- provider message that touches an event stamps `updated_at = now()` (in
-- `upsert_detection_event`); the janitor closes any still-open event whose
-- `updated_at` is older than the stale timeout, so `end_ts` can never again be
-- NULL-forever (the 2026-07-16 incident had ~123 never-closed rows, oldest a
-- month old). Idempotent.
ALTER TABLE events
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- Seed EXISTING open rows so a month-old never-closed event is immediately
-- janitor-eligible: set `updated_at = ts` (the event's own start) for open rows
-- only. Without this, `ADD COLUMN ... DEFAULT now()` would stamp every legacy
-- open row at migration time, delaying their close by a full stale window and
-- pinning end_ts to the deploy moment (wrong by up to a month). Targeted to the
-- open rows — not a full-table rewrite.
UPDATE events SET updated_at = ts WHERE end_ts IS NULL;
