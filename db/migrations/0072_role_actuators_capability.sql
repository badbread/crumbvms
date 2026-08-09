-- 0072_role_actuators_capability.sql — the `actuators` role capability.
--
-- Capabilities live in the `roles.capabilities` jsonb (migration 0028), so a new
-- capability needs no column: the Rust `Capabilities` struct reads a missing key
-- as its serde default, and `actuators` defaults to FALSE (deny). This migration
-- therefore changes NO effective permission. It exists to (a) make the new key
-- explicit in stored rows so the admin console's checkbox reflects real stored
-- state rather than an implied default, and (b) record in the schema history
-- when the capability appeared.
--
-- `actuators` gates `POST /cameras/:id/ha/action` (issue #187) and, later, the
-- Reolink actuators: operating PHYSICAL devices, garage doors, locks, sirens,
-- linked to a camera. It is deny-by-default on purpose. Being able to SEE a
-- camera, or even the live state of its linked entities, must never imply being
-- able to operate them. Admin roles bypass capabilities entirely (`is_admin`),
-- so they are left untouched here.
--
-- Idempotent: only rows that do not already carry the key are touched.

UPDATE roles
SET capabilities = capabilities || '{"actuators": false}'::jsonb
WHERE NOT is_admin
  AND NOT (capabilities ? 'actuators');
