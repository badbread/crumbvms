-- 0028_roles.sql — Role-based access control.
--
-- A "role" is a named permission profile that carries BOTH a capability set
-- (what a member may do) AND a camera set (which cameras a member may see).
-- A user is assigned one role. The built-in Administrator role (is_admin=true)
-- bypasses all checks and sees all cameras; its capabilities/camera_ids columns
-- are ignored.
--
-- These permission roles are DISTINCT from camera_groups (which drive recording
-- policy). All statements are idempotent so the boot-time runner can re-apply.

CREATE TABLE IF NOT EXISTS roles (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text NOT NULL UNIQUE,
    is_admin     boolean NOT NULL DEFAULT false,
    -- { export, playback, clips, ptz: bool; bookmarks: "none"|"own"|"all"; manage_views: bool }
    capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Camera UUIDs members of this role may access (ignored for is_admin roles).
    camera_ids   jsonb NOT NULL DEFAULT '[]'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE users ADD COLUMN IF NOT EXISTS role_id uuid REFERENCES roles(id);
CREATE INDEX IF NOT EXISTS users_role_id ON users (role_id);

-- Seed the built-in Administrator role (full access).
INSERT INTO roles (name, is_admin, capabilities, camera_ids)
SELECT 'Administrator', true, '{}'::jsonb, '[]'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM roles WHERE is_admin = true);

-- Seed a default Viewer role (sensible baseline; no cameras until an admin assigns).
INSERT INTO roles (name, is_admin, capabilities, camera_ids)
SELECT 'Viewer', false,
       '{"export": false, "playback": true, "clips": true, "ptz": false, "bookmarks": "own", "manage_views": true}'::jsonb,
       '[]'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM roles WHERE name = 'Viewer');

-- Migrate existing admins → the Administrator role.
UPDATE users
SET role_id = (SELECT id FROM roles WHERE is_admin = true ORDER BY created_at LIMIT 1)
WHERE role = 'admin' AND role_id IS NULL;

-- Migrate each existing non-admin user → a per-user role seeded from their current
-- camera_ids, so no camera access is lost. (Admin can rename/consolidate later.)
DO $$
DECLARE u RECORD; new_role_id uuid;
BEGIN
  FOR u IN SELECT id, username, camera_ids FROM users WHERE role <> 'admin' AND role_id IS NULL LOOP
    INSERT INTO roles (name, is_admin, capabilities, camera_ids)
    VALUES ('Viewer - ' || u.username, false,
            '{"export": false, "playback": true, "clips": true, "ptz": false, "bookmarks": "own", "manage_views": true}'::jsonb,
            COALESCE(u.camera_ids, '[]'::jsonb))
    ON CONFLICT (name) DO UPDATE SET camera_ids = EXCLUDED.camera_ids
    RETURNING id INTO new_role_id;
    UPDATE users SET role_id = new_role_id WHERE id = u.id;
  END LOOP;
END $$;
