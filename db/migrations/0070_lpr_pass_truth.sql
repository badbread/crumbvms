-- 0070_lpr_pass_truth.sql
--
-- Operator-confirmed ground truth for the LPR dual-engine A/B benchmark
-- (cameras with lpr_engine = 'both', where every vehicle pass is read by BOTH
-- Frigate's native LPR and the crumb-alpr fast-alpr worker).
--
-- A "pass" is not a stored entity — it is derived at report time by clustering
-- `plate_reads` (see services/common/src/lpr_ab.rs). Its stable key is
-- (camera_id, bucket_ts) where bucket_ts is the earliest read timestamp in the
-- pass, truncated to whole seconds. The operator looks at the pass's plate
-- image in the Benchmark UI and records the true plate here; each engine's
-- best read for the pass is then scored correct iff its normalized plate
-- equals the normalized true plate.
--
-- One truth row per pass: UNIQUE (camera_id, bucket_ts), upserted on
-- re-confirmation (the operator can correct a typo by confirming again).
-- `true_plate` is stored NORMALIZED (uppercase ASCII alphanumerics), matching
-- plate_reads.plate. Rows cascade away with their camera; `confirmed_by`
-- survives user deletion as NULL (the confirmation itself stays valid).
--
-- Idempotent (IF NOT EXISTS), matching every migration.

CREATE TABLE IF NOT EXISTS lpr_pass_truth (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id    uuid        NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    bucket_ts    timestamptz NOT NULL,             -- pass key: earliest read ts, second precision
    true_plate   text        NOT NULL,             -- NORMALIZED: uppercase alphanumerics
    confirmed_by uuid        REFERENCES users(id) ON DELETE SET NULL,
    confirmed_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (camera_id, bucket_ts)                  -- one truth per pass (also serves lookups)
);
