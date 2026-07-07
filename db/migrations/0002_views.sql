-- Saved Views — named camera layouts shared across all clients (web/desktop/mobile).
--
-- A "view" captures a layout id (e.g. "2x2", "1plus5") plus the camera assigned
-- to each tile slot. Stored server-side so a saved view follows the operator to
-- any client (mirrors a leading commercial VMS's Views).
--
-- NOTE: migrations in this dir are applied by the postgres image only on FIRST
-- init of an empty data dir. For an already-running database, apply this table
-- manually (CREATE TABLE IF NOT EXISTS ...). It is idempotent.

CREATE TABLE IF NOT EXISTS views (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text NOT NULL,
    -- Layout preset id understood by the clients ("1x1","2x2","3x3","4x4","1plus5").
    layout     text NOT NULL,
    -- JSON object mapping tile slot index (as a string) -> camera UUID (as a string),
    -- e.g. {"0":"<uuid>","1":"<uuid>"}. Slots may be sparse.
    slots      jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS views_created ON views (created_at);
