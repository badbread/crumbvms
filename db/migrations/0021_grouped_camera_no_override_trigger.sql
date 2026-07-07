-- Phase 3 BACKSTOP: structurally enforce the invariant "a camera that is a member
-- of a group must NOT hold a direct per-camera policy override" (cameras.policy_id
-- IS NULL). The effective-policy COALESCE (v_camera_effective_policy: own -> group
-- -> default) puts cameras.policy_id FIRST, so a grouped camera with a direct
-- policy would silently shadow its group's profile.
--
-- The application already enforces this on every NORMAL path (set_group_members
-- clears the override on join; the camera-policy API rejects a pin on a grouped
-- camera). These triggers are the durable, race-proof backstop so the bad state
-- can never be WRITTEN, even if two admin actions interleave.
--
-- Two complementary guards:
--   1) On cameras: reject SETTING a non-NULL policy_id on a camera that is in a
--      group (BEFORE INSERT OR UPDATE OF policy_id). Catches "pin a policy on an
--      already-grouped camera". Clearing to NULL is always allowed.
--   2) On camera_group_members: when a camera is ADDED to a group, clear any
--      direct policy_id it still holds (BEFORE INSERT). Catches "add a camera that
--      already has an override into a group" via ANY insert path, mirroring
--      set_group_members step 4 (idempotent, defense-in-depth).
--
-- Idempotent: CREATE OR REPLACE FUNCTION + DROP TRIGGER IF EXISTS + CREATE TRIGGER.
-- On prod this is an install-only no-op against data (no grouped camera currently
-- holds an override). FOOTAGE-SAFE: touches only cameras.policy_id (the governing
-- pointer), never a segment row.

CREATE OR REPLACE FUNCTION crumb_reject_override_on_grouped_camera()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.policy_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM camera_group_members WHERE camera_id = NEW.id) THEN
        RAISE EXCEPTION
            'camera % is in a group; a grouped camera cannot hold a direct policy_id (change the group profile or ungroup the camera first)',
            NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reject_override_on_grouped_camera ON cameras;
CREATE TRIGGER trg_reject_override_on_grouped_camera
    BEFORE INSERT OR UPDATE OF policy_id ON cameras
    FOR EACH ROW EXECUTE FUNCTION crumb_reject_override_on_grouped_camera();

CREATE OR REPLACE FUNCTION crumb_clear_override_on_group_join()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE cameras SET policy_id = NULL
     WHERE id = NEW.camera_id AND policy_id IS NOT NULL;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clear_override_on_group_join ON camera_group_members;
CREATE TRIGGER trg_clear_override_on_group_join
    BEFORE INSERT ON camera_group_members
    FOR EACH ROW EXECUTE FUNCTION crumb_clear_override_on_group_join();
