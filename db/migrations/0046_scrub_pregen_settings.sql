-- Admin-console overrides for the scrub-preview runtime tunables (issue #10).
-- NULL means "the operator has never touched this in the console" -> the
-- consumers fall back to the THUMB_* env defaults (services/api/src/config.rs).
-- Nullable + no DEFAULT, matching update_check_enabled (migration 0045):
-- NULL must be distinguishable from an explicit value, per the house
-- server_settings precedence rule (admin-set DB value wins over env).
--
-- THUMB_PREGEN_WIDTH deliberately has NO column here (ratified maintainer
-- decision D1, issue #10): width is part of the thumbnail cache key, and a
-- console value that drifted from the clients' fixed scrub-still width would
-- silently waste all pre-generation CPU + storage. It stays env/compose-only;
-- the admin console displays it read-only. See docs/DECISIONS.md.
--
-- Additive + nullable, so it is safe on an already-running install.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS thumb_pregen_enabled        boolean,
    ADD COLUMN IF NOT EXISTS thumb_pregen_lookback_hours integer,
    ADD COLUMN IF NOT EXISTS thumb_pregen_scan_secs      integer,
    ADD COLUMN IF NOT EXISTS thumb_cache_max_bytes       bigint,
    ADD COLUMN IF NOT EXISTS thumb_cache_ttl_seconds     bigint;
