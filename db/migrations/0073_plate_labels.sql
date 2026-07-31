-- 0073_plate_labels.sql
--
-- Human-readable names for license plates (issue #363). An operator names a
-- plate once ("Mom's car", "Delivery van"), keyed by the normalized plate
-- string, and every client shows the name instead of the raw plate wherever
-- that plate appears: LPR reads, plate detail, the watchlist, and alert text.
--
-- This is a FIRST-CLASS naming table, deliberately separate from the watchlist
-- (0052_lpr_watchlist.sql). The watchlist is an alert / BOLO list; a plate name
-- is display metadata that applies to ALL reads of a plate, watchlisted or not.
-- The read path resolves a display name as
--   COALESCE(plate_labels.label, lpr_watchlist.label)
-- keyed on the normalized plate, so an existing watchlist label keeps working
-- while a plate_labels entry, when present, is the canonical name that wins.
--
-- Keying is the EXACT normalized plate string (uppercase ASCII alphanumerics,
-- see normalize_plate). v1 does not apply a name to fuzzy / confusable variants;
-- that is a deferred follow-up (see docs/DECISIONS.md).
--
-- Fully idempotent (IF NOT EXISTS) so it is safe to (re-)apply on a long-lived
-- database, matching every other migration here.

CREATE TABLE IF NOT EXISTS plate_labels (
    -- Normalized plate (uppercase ASCII alphanumerics, see normalize_plate).
    -- The name is keyed exactly on this string; it is the primary key, so a
    -- second naming of the same plate edits the existing row (the write path
    -- upserts on it).
    plate      text        PRIMARY KEY,
    -- The human-readable name shown wherever the plate appears ("Mom's car").
    label      text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
