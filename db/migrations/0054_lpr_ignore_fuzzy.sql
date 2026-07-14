-- 0054_lpr_ignore_fuzzy.sql
--
-- LPR Phase 3a: plate ignore-list + fuzzy watchlist matching.
--
-- IGNORE: the watchlist becomes a two-kind list. `kind = 'watch'` (the existing
-- behavior) alerts on a hit; `kind = 'ignore'` SUPPRESSES a plate — the ingester
-- drops a matching read entirely (not stored, never alerted). This is the
-- pragmatic backstop for a persistent nuisance plate (e.g. a parked car Frigate
-- keeps reading) when Frigate-side object masking is impractical. The UNIQUE
-- index on plate already means a plate is watch XOR ignore, never both.
--
-- FUZZY: Frigate's native ALPR misreads more than a dedicated engine, so exact
-- watchlist matching misses. `watchlist_fuzz` (0..0.5) is a single global
-- similarity slack: 0 = exact match (unchanged default), higher = looser. The
-- ingester matches a read against watch/ignore entries by pg_trgm similarity
-- when fuzz > 0 (`similarity(plate, entry.plate) >= 1 - fuzz`), else exact.
-- Applies to BOTH kinds so a near-misread of an ignored plate is still ignored.
--
-- Idempotent, matching every other migration.

ALTER TABLE lpr_watchlist
    ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'watch';

-- Constrain to the two valid kinds. Guard the ADD CONSTRAINT so re-apply is safe
-- (ALTER TABLE ADD CONSTRAINT has no IF NOT EXISTS on older PG).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'lpr_watchlist_kind_chk'
    ) THEN
        ALTER TABLE lpr_watchlist
            ADD CONSTRAINT lpr_watchlist_kind_chk CHECK (kind IN ('watch', 'ignore'));
    END IF;
END $$;

-- Global watchlist match fuzziness (0 = exact). The API clamps writes to 0..0.5;
-- the column is just a real.
ALTER TABLE lpr_config
    ADD COLUMN IF NOT EXISTS watchlist_fuzz real NOT NULL DEFAULT 0;
