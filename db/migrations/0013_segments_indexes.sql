-- Migration 0013: canonical segments indexes
-- =============================================================================
-- Canonical home for the three indexes that ensure_segments_indexes() self-heals
-- at runtime.  A fresh DB (no existing data) gets them via this migration runner.
-- An existing prod DB gets them from the ensure_* shim (called at startup before
-- any recording loops start).  Both paths land the same indexes; IF NOT EXISTS
-- makes this idempotent in all cases.
--
-- All indexes are NON-CONCURRENT (no CONCURRENTLY keyword) so this file runs
-- safely as a single implicit transaction via run_migrations()' batch_execute
-- (no explicit BEGIN/COMMIT here — that would nest and break atomic rollback).
-- On an existing large DB the ensure_* shim already created these non-concurrently
-- at startup, so the runner's IF NOT EXISTS check is a fast catalog no-op.
-- =============================================================================

-- 1. UNIQUE index — structurally prevents duplicate (camera_id, stream, start_ts)
--    rows (the prod 28-byte skeleton / double-counted eviction budget root cause).
--    The live insert path's ON CONFLICT ... DO UPDATE depends on this index.
CREATE UNIQUE INDEX IF NOT EXISTS segments_uniq_cam_stream_start
    ON segments (camera_id, stream, start_ts);

-- 2. EVICTION covering index — makes policy_stage_bytes SUM index-only and
--    list_policy_segments_oldest_first an ordered index scan rather than a
--    full seq-scan + external-merge sort every 60 s.
CREATE INDEX IF NOT EXISTS segments_stage_start
    ON segments (stage, start_ts);

-- 3. TIMELINE index — the cross-camera timeline query (timeline_spans) filters
--    only on a time window; without a start_ts index it seq-scans all footage.
CREATE INDEX IF NOT EXISTS segments_start_ts
    ON segments (start_ts);
