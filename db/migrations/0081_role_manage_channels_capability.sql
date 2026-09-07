-- 0081_role_manage_channels_capability.sql — the `manage_channels` capability.
--
-- Capabilities live in the `roles.capabilities` jsonb (migration 0028), so a new
-- capability needs no column: the Rust `Capabilities` struct reads a missing key
-- as its serde default, and `manage_channels` defaults to FALSE (deny). This
-- migration therefore changes NO effective permission. It exists to (a) make the
-- new key explicit in stored rows so the admin console's checkbox reflects real
-- stored state rather than an implied default, and (b) record in the schema
-- history when the capability appeared.
--
-- `manage_channels` gates creating, editing, deleting and test-firing
-- third-party notification channels (`POST/PUT/DELETE /notifications/channels*`
-- and `POST /notifications/channels/:id/test`). A channel is a standing
-- instruction for the server to send alerts, with snapshot images attached, to
-- an operator-chosen destination, so it is an operator task rather than a
-- per-viewer preference. Deny-by-default on purpose. Admin roles bypass
-- capabilities entirely (`is_admin`), so they are left untouched here.
--
-- Existing channels keep delivering regardless of their owner's capabilities;
-- only management is gated. Listing one's own channels is not gated either.
--
-- Idempotent: only rows that do not already carry the key are touched.

UPDATE roles
SET capabilities = capabilities || '{"manage_channels": false}'::jsonb
WHERE NOT is_admin
  AND NOT (capabilities ? 'manage_channels');
