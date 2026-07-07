-- First-run setup wizard: tracks whether the guided onboarding has been finished,
-- so the wizard shows on a fresh install and never reappears once done.
-- Backfill: any install that ALREADY has an admin user is treated as set up, so
-- existing deployments don't suddenly get the wizard on upgrade. Idempotent.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS setup_complete BOOLEAN NOT NULL DEFAULT false;

UPDATE server_settings
   SET setup_complete = true
 WHERE EXISTS (SELECT 1 FROM users WHERE role = 'admin');
