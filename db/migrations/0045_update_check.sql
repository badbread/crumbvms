-- Operator opt-in toggle for the update-available check (issue #7). NULL means
-- "the operator has never touched this" -> services/api/src/config.rs falls
-- back to the UPDATE_CHECK_ENABLED env var (default false, D3: OFF BY
-- DEFAULT, so a fresh install makes zero GitHub requests until the operator
-- explicitly opts in via the admin console or the env).
--
-- Nullable + no DEFAULT (unlike bookmarks_enabled's NOT NULL DEFAULT true,
-- migration 0029) is deliberate: it distinguishes "never set" from an explicit
-- false, matching the house server_settings precedence rule (admin-set DB
-- value wins over env; an unset/NULL DB value falls back to env).
--
-- Additive + nullable, so it is safe on an already-running install.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS update_check_enabled boolean;
