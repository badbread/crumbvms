-- Quarantine retention: days to keep files the reconcile loop moved into
-- `<storage_root>/_quarantine/` before the recorder auto-purges them. The
-- quarantine dir otherwise grows unbounded (prod reached 110 GB / 36k files in
-- a month). This is a generous review-then-purge grace window, not purge-blind.
-- `0` DISABLES the prune (keep quarantined files forever) — the opt-out.
-- Admin-editable in Server settings; clamped 0..=3650 by the API/db helpers.
-- Idempotent.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS quarantine_retention_days INT NOT NULL DEFAULT 14;
