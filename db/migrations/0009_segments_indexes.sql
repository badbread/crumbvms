-- Crumb NVR — segments UNIQUE + covering/timeline INDEXES (one-time, live-DB)
-- ============================================================================
-- Source: an internal footage-reliability audit (P1 #5, #9; P2 #10, #11)
--
-- Run AFTER 0008_segments_repair.sql has DE-DUPED + clamped + purged. Building
-- the unique index on a table that still has dup (camera_id,stream,start_ts)
-- groups will FAIL — that's the safety interlock.
--
-- ⚠️  EVERY statement here uses CREATE INDEX CONCURRENTLY, which:
--     * CANNOT run inside a transaction block — do NOT wrap this file in BEGIN/COMMIT.
--     * Does NOT take an ACCESS EXCLUSIVE lock — the recorder keeps reading/writing
--       while the index builds online.
--     * If a build is interrupted it leaves an INVALID index; drop it
--       (`DROP INDEX CONCURRENTLY <name>;`) and re-run that one statement.
--
-- Apply each statement SEPARATELY (psql runs them one at a time when fed a file,
-- which is correct — they are not in a txn). All are IF NOT EXISTS so re-running
-- the file is safe once the indexes exist.
--
-- ⚠️  DOES NOT auto-apply (initdb-only beyond 0001). Apply MANUALLY, after 0008.
-- ============================================================================

-- 1. THE UNIQUE INDEX — structurally kills the duplicate-row class (the 28-byte
--    skeleton rows, the double-counted eviction budget, double-export). The live
--    insert path's ON CONFLICT (camera_id, stream, start_ts) DO UPDATE (db.rs)
--    depends on THIS index existing.
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS segments_uniq_cam_stream_start
    ON segments (camera_id, stream, start_ts);

-- 2. EVICTION covering index — makes policy_stage_bytes' SUM index-only and
--    list_policy_segments_oldest_first an ordered index scan instead of the
--    prod-observed Parallel Seq Scan of all rows + external-merge disk sort
--    every 60s. INCLUDE carries the columns the sweep reads so the heap is
--    never touched.
CREATE INDEX CONCURRENTLY IF NOT EXISTS segments_stage_start
    ON segments (stage, start_ts)
    INCLUDE (size_bytes, camera_id, storage_id, path);

-- 3. TIMELINE index — the all-cameras timeline query (timeline_spans) filtered
--    only on a time window; without a start_ts index it seq-scans all footage to
--    find a 2h slice. (camera_id, start_ts) already exists from 0001; this adds
--    the global time ordering the cross-camera window needs.
CREATE INDEX CONCURRENTLY IF NOT EXISTS segments_start_ts
    ON segments (start_ts);
