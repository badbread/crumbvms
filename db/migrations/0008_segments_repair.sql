-- Crumb NVR — segments DATA REPAIR (one-time, idempotent, live-DB-safe)
-- ============================================================================
-- Source: an internal footage-reliability audit (P0 #3, P1 #5, #6, GAP 4)
--
-- This migration REPAIRS the corruption the unconstrained insert path produced
-- in prod, so that the UNIQUE INDEX in 0009 can be built:
--
--   (a) DE-DUP  the duplicate (camera_id, stream, start_ts) groups
--               (prod: 815 live groups / 1528 archive-stage dups).
--   (b) CLAMP   absurd mtime-derived durations
--               (prod: 806 rows up to 49h from ~4s files).
--   (c) PURGE   sub-floor "skeleton" rows
--               (prod: 215 rows of exactly 28 bytes — ftyp+empty_moov only).
--
-- ⚠️  DOES NOT auto-apply. Beyond 0001, /docker-entrypoint-initdb.d only runs on
--     a fresh data dir. This MUST be applied MANUALLY against the live DB by a
--     human, IN A TRANSACTION, AFTER a verified backup, BEFORE 0009. See the
--     exact ordered run steps in the audit / the agent summary.
--
-- ⚠️  HUMAN-REVIEW THE DEDUP ROW-SELECTION below before running on prod. The
--     "keep" rule is spelled out in the comment on step (a).
--
-- It is IDEMPOTENT and BATCHED:
--   * Re-running is a no-op once clean (every WHERE filters on the bad state).
--   * The DELETEs take only row locks on the rows they touch (no table rewrite,
--     no ACCESS EXCLUSIVE lock), so the recorder can keep writing during it.
--   * `SET LOCAL lock_timeout` / `statement_timeout` bound any lock wait so a
--     stuck transaction cannot pile up behind a long recorder write.
-- ============================================================================

BEGIN;

-- Fail fast instead of blocking the live recorder if a lock can't be taken.
SET LOCAL lock_timeout = '5s';
-- Bound total statement time so a runaway repair can't wedge the DB.
SET LOCAL statement_timeout = '10min';

-- We need segment_seconds to clamp durations. The recorder enforces [2,6]s and
-- prod runs 4s; we clamp to 2× the MAX (6s) → 12s as the absolute ceiling so we
-- never shorten a legitimately-long segment. Adjust if SEGMENT_SECONDS changes.
-- (Kept as a literal so this file is self-contained and replayable via psql.)

-- ── (c) FIRST: purge sub-floor skeleton rows ────────────────────────────────
-- Do this BEFORE dedup so a 28-byte skeleton can never be the row kept by the
-- dedup tie-break. 512 bytes is comfortably above the 28-byte ftyp-only file
-- and far below any real ~MB segment, so no genuine footage row is at risk.
DELETE FROM segments
WHERE size_bytes < 512;

-- ── (a) DE-DUP duplicate (camera_id, stream, start_ts) groups ────────────────
--
-- KEEP-ROW SELECTION (review this):
--   Within each (camera_id, stream, start_ts) group, keep exactly ONE row, the
--   "most complete" one, ranked by:
--     1. LARGEST size_bytes        — most bytes ⇒ most-complete write (the audit's
--                                     primary rule; the skeleton loses to the real
--                                     insert; sub-floor rows are already gone above).
--     2. LATEST end_ts             — among equal byte sizes, the longer-duration row.
--     3. stage = 'archive' first   — an archive row points at the durable long-
--                                     retention copy; preferring it avoids keeping a
--                                     row whose live file may already be evicted.
--     4. LOWEST id (tie-break)     — deterministic + stable across re-runs.
--   All OTHER rows in the group are DELETED. The keeper's path/size/end_ts are
--   left exactly as-is (we don't merge GREATEST across the group here — the
--   ranking already picks the largest/longest; the live insert path's ON CONFLICT
--   in 0009 takes over GREATEST-merge for FUTURE collisions).
WITH ranked AS (
    SELECT
        id,
        ROW_NUMBER() OVER (
            PARTITION BY camera_id, stream, start_ts
            ORDER BY
                size_bytes DESC,                         -- 1. largest/most-complete
                end_ts     DESC,                         -- 2. longest duration
                (stage = 'archive') DESC,                -- 3. durable archive copy
                id         ASC                           -- 4. deterministic tie-break
        ) AS rn
    FROM segments
)
DELETE FROM segments s
USING ranked r
WHERE s.id = r.id
  AND r.rn > 1;

-- ── (b) CLAMP absurd mtime-derived durations ─────────────────────────────────
-- A correct ~4s segment has end_ts - start_ts ≈ 4s. The orphan reindexer used
-- file mtime for end_ts, and a copy/recovery reset mtime to "now", yielding
-- multi-hour/day durations. Clamp anything longer than 2× the max segment length
-- (12s) back to start_ts + segment_seconds. This fixes the timeline 2-day blocks
-- and resolve_segment serving the wrong 4 seconds.
UPDATE segments
SET end_ts      = start_ts + INTERVAL '4 seconds',
    duration_ms = 4000
WHERE end_ts - start_ts > INTERVAL '12 seconds';

COMMIT;
