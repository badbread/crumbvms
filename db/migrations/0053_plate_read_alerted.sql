-- 0053_plate_read_alerted.sql
--
-- LPR watchlist-alert correctness (Fable review H1). The Phase 2 alert fired
-- only on a fresh INSERT of a plate read, but Frigate refines
-- `recognized_license_plate` across an event's lifecycle: a pass can INSERT a
-- misread (not watchlisted, no alert) and then UPDATE the same row to the
-- actual watchlisted plate — an UPDATE, so the old insert-gated alert never
-- fired even though the stored plate ends up being exactly the BOLO plate.
--
-- Fix: track whether a read has already alerted, so the ingester can alert on
-- the match TRANSITION (plate matches AND not-yet-alerted) instead of on insert
-- — still exactly one alert per read/pass, but no longer blind to mid-pass
-- refinement. Idempotent, matching every other migration.

ALTER TABLE plate_reads
    ADD COLUMN IF NOT EXISTS alerted boolean NOT NULL DEFAULT false;
