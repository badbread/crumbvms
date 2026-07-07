-- Phase 4 RBAC: explicit view-sharing — an owner can grant named users access
-- to one of their private views without making it global (owner_id = NULL).
--
-- Cascade deletes keep the table consistent automatically:
--   * view deleted → all its share rows disappear.
--   * user deleted → all share rows for that user disappear.

CREATE TABLE IF NOT EXISTS view_shares (
    view_id    uuid        NOT NULL REFERENCES views(id)  ON DELETE CASCADE,
    user_id    uuid        NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (view_id, user_id)
);

CREATE INDEX IF NOT EXISTS view_shares_user ON view_shares(user_id);
