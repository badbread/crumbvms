-- Bookmarks — saved playback moments (camera + time + optional note), shared
-- server-side so a bookmark made on any client (desktop/mobile/web) shows in
-- everyone's list and jumps to that camera+time.
--
-- `protect_until` is reserved for a FUTURE "protected retention" feature (keep the
-- footage at this moment from auto-archive/delete until the given time); it is
-- NULL today and carries no behaviour yet.
--
-- NOTE: migrations in this dir are applied by the postgres image only on FIRST
-- init of an empty data dir. For an already-running database, the API applies
-- this at startup via db::ensure_bookmarks_table() (idempotent CREATE IF NOT EXISTS).

CREATE TABLE IF NOT EXISTS bookmarks (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id     uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    -- The bookmarked moment in the footage.
    ts            timestamptz NOT NULL,
    -- Optional free-text note (NULL = none).
    description   text,
    -- Who created it (users.id); nullable, no FK so user deletion never orphans.
    created_by    uuid,
    -- Protected retention: while protect_until > now() the recorder keeps the
    -- footage window [protect_start_ts, protect_end_ts] from auto-archive/delete.
    protect_until    timestamptz,
    protect_start_ts timestamptz,
    protect_end_ts   timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bookmarks_camera_ts ON bookmarks (camera_id, ts);
CREATE INDEX IF NOT EXISTS bookmarks_created ON bookmarks (created_at);
