-- Phase 3 RBAC: add per-user ownership to saved views.
--
-- owner_id is nullable so that pre-existing "global" rows (created before this
-- migration) keep owner_id = NULL and remain visible to every user, matching
-- the legacy all-shared behaviour.  The API's list query explicitly surfaces
-- NULL-owner rows to all users; only rows with a concrete owner_id are
-- restricted to that owner (and admins/share-grantees via 0031).

ALTER TABLE views
    ADD COLUMN IF NOT EXISTS owner_id uuid REFERENCES users(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS views_owner ON views(owner_id);
