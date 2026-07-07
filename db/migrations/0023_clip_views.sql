-- Per-user "watched" state for the Clips feed.
--
-- A clip is marked viewed when the user opens it; the Clips feed then renders
-- watched cards subtly dimmer. Per-user (not systemwide like bookmarks) — a clip
-- you reviewed shouldn't read as reviewed for another operator.
--
-- clip_id is the opaque Clips handle ("d:<event-uuid>" | "m:<cam>:<start>:<end>").
-- Rows are tiny; motion-clip ids whose footage has aged out simply stop matching
-- any feed entry, so stale rows are harmless (a future prune can drop them).
CREATE TABLE IF NOT EXISTS clip_views (
    user_id   UUID        NOT NULL,
    clip_id   TEXT        NOT NULL,
    viewed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, clip_id)
);
