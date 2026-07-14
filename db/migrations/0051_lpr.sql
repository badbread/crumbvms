-- License-plate recognition (LPR): plate-reads store + config singleton.
--
-- Phase 0 of the LPR feature (see docs/DECISIONS.md, 2026-07-13). Crumb does
-- NOT run an OCR engine: plate strings arrive from Frigate 0.16's native LPR on
-- the `frigate/events` stream Crumb already ingests (as `recognized_license_plate`
-- / a matched-known-plate `sub_label`), or later from an external engine POSTing
-- to the ingest endpoint. Either way the read lands here.
--
-- `plate_reads` is the plate-DOMAIN record. The shared `events` row keeps being
-- written exactly as today (timeline glyphs, /events, notifications unchanged —
-- the additive-motion-sources rule): each read points back at its sibling event
-- via `event_id`. A dedicated table (not `events.sub_label`) because the
-- OpenALPR-style UI needs plate search (exact/partial/fuzzy via trigram),
-- per-plate history, confidence/region/vehicle attrs, and a crop image — none of
-- which the shared `events` schema serves without contorting mixed `sub_label`
-- semantics (face names, HA device classes) and an unindexed text column.
--
-- Additive + optional: with `lpr_config.enabled = false` (the default) nothing
-- writes here, so enabling Frigate detections alone never silently builds a
-- plate database. A plate database is privacy-sensitive; it is opt-in.
--
-- Safe to run multiple times (IF NOT EXISTS / ON CONFLICT guards).

-- Trigram support for partial/fuzzy plate search. Trusted extension since PG13;
-- present in the postgres:16-alpine image the stack ships, so the bundled
-- happy-path always gets it. On an EXTERNAL / BYO-Postgres it may be missing:
-- an older server, a contrib-less package, or a non-superuser DB role that
-- lacks CREATE-EXTENSION privilege. A bare `CREATE EXTENSION` would then raise,
-- abort THIS migration, and — because the boot migration loop stops at the
-- first failure — leave 0052..0055 unapplied; the recorder treats a migration
-- failure as fatal and crash-loops on upgrade. So guard it: swallow only the
-- two "can't install it" errors (insufficient_privilege / undefined_file for a
-- missing contrib .so) and carry on. When the extension is absent the fuzzy
-- index below is skipped and the API degrades fuzzy search to `contains`/exact
-- at runtime (see db::pg_trgm_available). Minimum PG for the bundled fuzzy path
-- is PG13 (trusted pg_trgm); external servers without pg_trgm still work, just
-- without trigram fuzziness.
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EXCEPTION
    WHEN insufficient_privilege OR undefined_file THEN
        RAISE NOTICE 'pg_trgm unavailable (%); fuzzy plate search will degrade to contains/exact', SQLERRM;
END $$;

CREATE TABLE IF NOT EXISTS plate_reads (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id         uuid        NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    ts                timestamptz NOT NULL,               -- read time (event start / update)
    plate             text        NOT NULL,               -- NORMALIZED: uppercase, no spaces/dashes
    plate_raw         text,                               -- as the engine reported it
    confidence        real,                               -- OCR confidence 0..1 (engine-provided)
    region            text,                               -- state/country if the engine provides it
    vehicle           jsonb,                              -- {make, model, color, type} if provided
    bbox_x1           real,                               -- plate box, normalized 0..1 coords
    bbox_y1           real,
    bbox_x2           real,
    bbox_y2           real,
    crop              bytea,                              -- plate crop JPEG (external-engine path; small)
    snapshot_url      text,                               -- provider snapshot path (Frigate path)
    source_id         text        NOT NULL,               -- 'frigate' | 'lpr' | 'openalpr' | ...
    provider_event_id text,                               -- engine dedup key
    event_id          uuid        REFERENCES events(id) ON DELETE SET NULL,  -- sibling events row
    raw               jsonb,                              -- verbatim engine payload
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- Dedup: one row per engine event. Partial (source_id/provider_event_id present)
-- mirrors the events table's dedup so a re-emitted/updated event upserts in place.
CREATE UNIQUE INDEX IF NOT EXISTS plate_reads_provider_dedup
    ON plate_reads (source_id, provider_event_id)
    WHERE source_id IS NOT NULL AND provider_event_id IS NOT NULL;

-- Partial/fuzzy plate search (LIKE '%x%', similarity()). Conditional on the
-- extension: `gin_trgm_ops` only exists once pg_trgm is installed, so on a
-- BYO-Postgres where the CREATE EXTENSION above was skipped this index would
-- fail with "operator class gin_trgm_ops does not exist" and abort the
-- migration. Guard it on pg_extension so the table (and the rest of the
-- migration chain) still applies; fuzzy search degrades to contains/exact.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        CREATE INDEX IF NOT EXISTS plate_reads_plate_trgm
            ON plate_reads USING gin (plate gin_trgm_ops);
    END IF;
END $$;

-- Primary list/query pattern: reads for a camera, newest first.
CREATE INDEX IF NOT EXISTS plate_reads_camera_ts
    ON plate_reads (camera_id, ts DESC);

-- Global newest-first feed + retention prune scan.
CREATE INDEX IF NOT EXISTS plate_reads_ts
    ON plate_reads (ts DESC);

-- Config singleton, same shape as ha_config / frigate_config: an enable flag, a
-- write-only ingest token (Phase 3 external-engine POST path; never returned by
-- the API), a retention window, and a monotonic version column. Unlike HA there
-- is NO env fallback — LPR is admin-toggled only (a privacy-sensitive plate
-- database should be enabled deliberately in the console, see get_lpr_settings).
CREATE TABLE IF NOT EXISTS lpr_config (
    id             smallint    PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled        boolean     NOT NULL DEFAULT false,
    ingest_token   text,                                 -- write-only; for POST /lpr/reads
    retention_days integer     NOT NULL DEFAULT 90,      -- prune plate_reads older than this
    version        bigint      NOT NULL DEFAULT 1,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

INSERT INTO lpr_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
