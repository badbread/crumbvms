-- 0084_plate_aliases.sql
--
-- Plate corrections (issue #673). Plate OCR sometimes misreads a character,
-- so one car shows up as two plates ("GIF2GAB" and "GIT2GAB"). An admin can
-- say that a misread string is really another plate; every read of the alias
-- then counts as the canonical plate everywhere (search, history stats, the
-- plate desk overview, names, watchlist matching).
--
-- Raw reads are NEVER rewritten. `plate_reads.plate` keeps what the engine
-- read, and resolution happens at query time
--   COALESCE(plate_aliases.canonical_plate, plate_reads.plate)
-- so a correction is undone by deleting its row, and the original OCR text
-- stays available for audit (and for the A/B engine benchmark, which must
-- score the engines on what they actually read).
--
-- One level only: a canonical plate is never itself an alias. The write path
-- (db::create_plate_alias) flattens chains under a lock; the CHECK below only
-- guards the trivial self-alias.
--
-- Both columns are normalized plates (uppercase ASCII alphanumerics, see
-- normalize_plate). Not pruned by plate retention: like plate_labels and the
-- watchlist, an alias is operator curation, not a sighting.
--
-- Fully idempotent (IF NOT EXISTS), matching every other migration here.

CREATE TABLE IF NOT EXISTS plate_aliases (
    -- The misread plate string. Primary key: a string resolves to at most one
    -- canonical plate, and re-correcting it edits the row.
    alias_plate     text        PRIMARY KEY,
    -- The plate the alias really is.
    canonical_plate text        NOT NULL,
    -- The admin who made the correction (kept if the account is deleted).
    created_by      uuid        REFERENCES users (id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plate_aliases_not_self CHECK (alias_plate <> canonical_plate)
);

-- "Which misreads does this plate have?" (the plate profile, exact search and
-- the stats expansion all ask it).
CREATE INDEX IF NOT EXISTS plate_aliases_canonical ON plate_aliases (canonical_plate);
