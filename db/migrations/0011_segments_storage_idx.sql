-- Crumb NVR — segments (storage_id, start_ts) INDEX for the Change-storage drain
-- ============================================================================
-- The "Change storage" migration drains a policy's segments off a disk in
-- oldest-first batches: `WHERE storage_id = $ ... ORDER BY start_ts LIMIT n`,
-- re-run until the source is empty. None of the existing indexes lead on
-- storage_id, so every batch SELECT falls back to a full scan of the segments
-- table — O(rows x batches) over a many-hundred-thousand-row table. This index
-- turns each batch into a tight range scan that also satisfies the ORDER BY
-- without a sort.
--
-- The recorder/API also create this at startup via
-- db::ensure_segments_storage_index (non-concurrently, before the recording
-- loops). This file is for fresh installs / manual application.
--
-- ⚠️  CREATE INDEX CONCURRENTLY: CANNOT run inside a transaction block — do NOT
--     wrap in BEGIN/COMMIT. Online (no ACCESS EXCLUSIVE lock). An interrupted
--     build leaves an INVALID index; DROP INDEX CONCURRENTLY <name> and re-run.
-- ============================================================================

CREATE INDEX CONCURRENTLY IF NOT EXISTS segments_storage_start
    ON segments (storage_id, start_ts);
