-- Record the operator's one-time, in-product acceptance of the CrumbVMS Beta
-- Tester Terms (AS-IS / no-warranty / not-your-only-security / lawful-use),
-- captured by the opening gate of the first-run setup wizard.
--
-- `beta_terms_accepted_at` NULL  = the terms were never accepted.
-- `beta_terms_version`     lets a materially-changed terms document re-prompt
--                          (acceptance is version-scoped).
--
-- Additive + nullable, so it is safe on an already-running install: it simply
-- shows the gate the next time the first-run wizard opens (if ever — an install
-- that has already completed setup never re-runs it unprompted).
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS beta_terms_accepted_at timestamptz;
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS beta_terms_version text NOT NULL DEFAULT '';
