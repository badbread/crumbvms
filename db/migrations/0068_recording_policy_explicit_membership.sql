-- 0068_recording_policy_explicit_membership.sql
--
-- Phase 2 of the recording-policy model redesign (docs/design/POLICY-MODEL.md,
-- section 5 "Migration B"). Server-only. FOOTAGE-SACRED: this repoints camera
-- policy pointers and enforces NOT NULL, so a wrong pin could drop a camera from
-- the recorder's inner JOIN (silent stop-recording) or change its effective
-- retention. Read the design's migration-safety invariant (section 5) first.
--
-- Invariant held here: for every camera, the effective-policy field VALUES
-- resolved by v_camera_effective_policy are UNCHANGED (ids may change, values may
-- not). Every camera that was inheriting (policy_id IS NULL) is pinned to the
-- SAME row the view's COALESCE resolves today: a grouped camera to its group's
-- policy (else Default), an ungrouped inheritor to Default. No segment row is
-- touched, and every policy DELETE below targets only an UNREFERENCED row, so no
-- footage can be dropped or orphaned.
--
-- This whole file is a NON-CONCURRENTLY migration, so the runner applies it as
-- ONE implicit transaction. It is idempotent: the trigger drops are IF EXISTS;
-- after the first run no camera has a NULL policy_id and no policy has a NULL
-- name, so the pin/backfill steps are no-ops and the SET NOT NULL / unique-index
-- steps are already satisfied (IF NOT EXISTS on the index).
--
-- v_camera_effective_policy is intentionally left UNTOUCHED: with every
-- cameras.policy_id now non-NULL the COALESCE always takes leg 1 and the group
-- legs are dead but harmless — no append-only-view redefinition needed.

-- 1. Drop the migration-0021 grouped-camera triggers + their functions. They
--    exist to police the NULL-inherit + groups model this phase removes, and the
--    reject trigger (BEFORE UPDATE OF policy_id, raising when a grouped camera is
--    given a direct policy_id) would ABORT step 2's pin UPDATE if left in place
--    (landmine L3). Drop triggers before functions; IF EXISTS so re-runs and a
--    fresh DB (triggers created by 0021, always present here) are both safe.
DROP TRIGGER IF EXISTS trg_reject_override_on_grouped_camera ON cameras;
DROP TRIGGER IF EXISTS trg_clear_override_on_group_join ON camera_group_members;
DROP FUNCTION IF EXISTS crumb_reject_override_on_grouped_camera();
DROP FUNCTION IF EXISTS crumb_clear_override_on_group_join();

-- 2. Pin every GROUPED inheritor to its group's effective policy — exactly the
--    value the view's leg 2/3 resolves today (group's policy_id, else Default),
--    so effective field-values are unchanged. Uses a per-row scalar subquery for
--    the Default so a group WITH a policy still pins correctly even on a
--    (degenerate/un-seeded) DB with no default row.
UPDATE cameras c
   SET policy_id = COALESCE(
           g.policy_id,
           (SELECT id FROM recording_policies WHERE is_default LIMIT 1)
       )
  FROM camera_group_members m
  JOIN camera_groups g ON g.id = m.group_id
 WHERE m.camera_id = c.id
   AND c.policy_id IS NULL;

-- 3. Pin every remaining (ungrouped) inheritor to the Default row — exactly the
--    value the view's leg 3 resolves today.
UPDATE cameras
   SET policy_id = (SELECT id FROM recording_policies WHERE is_default LIMIT 1)
 WHERE policy_id IS NULL;

-- 4. Every camera now belongs to a policy: enforce it structurally. This is the
--    recorder-correctness win (a camera can no longer resolve through a missing
--    is_default fallback and silently stop recording). No-op if already NOT NULL.
ALTER TABLE cameras ALTER COLUMN policy_id SET NOT NULL;

-- 5a. Defensive backfill: name any NULL-name policy a mixed-version writer may
--     have created since Phase 1 (0067). Same rule as 0067 step 4 — name after
--     the owning camera, suffixed on collision; delete ownerless (unreferenced ⇒
--     footage-safe) rows outright. Do NOT bake deployment camera names into this
--     file; they come from data at run time.
DO $name$
DECLARE
    p_id     uuid;
    cam_name text;
    cand     text;
    n        int;
BEGIN
    FOR p_id IN
        SELECT id FROM recording_policies
         WHERE name IS NULL AND NOT is_default
         ORDER BY id
    LOOP
        SELECT c.name INTO cam_name
          FROM cameras c
         WHERE c.policy_id = p_id
         ORDER BY c.created_at, c.id
         LIMIT 1;

        IF cam_name IS NULL THEN
            DELETE FROM recording_policies WHERE id = p_id;
            CONTINUE;
        END IF;

        cand := cam_name;
        n := 1;
        WHILE EXISTS (
            SELECT 1 FROM recording_policies WHERE name = cand AND id <> p_id
        ) LOOP
            n := n + 1;
            cand := cam_name || ' ' || n::text;
        END LOOP;

        UPDATE recording_policies SET name = cand WHERE id = p_id;
    END LOOP;
END
$name$;

-- 5b. Resolve any DUPLICATE names before adding the unique index. Uniqueness was
--     never enforced, so two operator templates could share a name. Keep the
--     canonical one (Default wins, then oldest id) and suffix the rest " 2",
--     " 3", … against ALL names so the result is globally unique.
DO $dedupe$
DECLARE
    r    record;
    cand text;
    n    int;
BEGIN
    FOR r IN
        SELECT p.id, p.name
          FROM recording_policies p
         WHERE p.name IS NOT NULL
           AND p.id <> (
                 SELECT p2.id FROM recording_policies p2
                  WHERE p2.name = p.name
                  ORDER BY p2.is_default DESC, p2.id
                  LIMIT 1
             )
         ORDER BY p.name, p.id
    LOOP
        cand := r.name;
        n := 1;
        WHILE EXISTS (
            SELECT 1 FROM recording_policies WHERE name = cand AND id <> r.id
        ) LOOP
            n := n + 1;
            cand := r.name || ' ' || n::text;
        END LOOP;
        UPDATE recording_policies SET name = cand WHERE id = r.id;
    END LOOP;
END
$dedupe$;

-- 5c. Every policy now has a name: enforce it. No-op if already NOT NULL.
ALTER TABLE recording_policies ALTER COLUMN name SET NOT NULL;

-- 5d. And names are unique (the console's policy manager keys on them). IF NOT
--     EXISTS so re-runs are a no-op.
CREATE UNIQUE INDEX IF NOT EXISTS recording_policies_name_uidx
    ON recording_policies (name);

-- 6. camera_groups / camera_group_members are intentionally KEPT (dormant) for
--    one release so a rollback to a group-aware binary still has its tables. A
--    later cleanup migration drops them (design section 8, Phase 3). Do NOT drop
--    them here.
