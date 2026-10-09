-- Index on events(ts) for time-ordered scans that are not camera-scoped.
--
-- The notification engine polls `SELECT ... FROM events WHERE ts > $1
-- ORDER BY ts ASC LIMIT n` every few seconds. The existing indexes all lead
-- with camera_id or (source_id, provider_event_id), so that query had to scan
-- the whole table and sort it. With a plain btree on ts it becomes a bounded
-- index range scan. The same index serves the LPR retention prune
-- (`WHERE ts < cutoff`).
CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
