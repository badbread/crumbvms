-- Migration 0004: recorder liveness heartbeat
--
-- The recorder process upserts a single row (id = 1) on a fixed interval
-- (~10s).  The API reads `updated_at` for the `/status` recorder_heartbeat
-- field so the Server health panel can show real process liveness — not just
-- per-camera segment freshness.  A stale `updated_at` means the recorder
-- daemon itself is wedged or down even if old segments still exist.
--
-- Singleton enforced by CHECK (id = 1) + a seeded row.  IF NOT EXISTS makes
-- this idempotent so the orchestrator can apply it on every container startup.

CREATE TABLE IF NOT EXISTS recorder_heartbeat (
    id             smallint     PRIMARY KEY DEFAULT 1,
    updated_at     timestamptz  NOT NULL DEFAULT now(),
    pid            integer,
    active_cameras integer      NOT NULL DEFAULT 0,
    CONSTRAINT recorder_heartbeat_singleton CHECK (id = 1)
);

INSERT INTO recorder_heartbeat (id, updated_at, active_cameras)
VALUES (1, now(), 0)
ON CONFLICT (id) DO NOTHING;
