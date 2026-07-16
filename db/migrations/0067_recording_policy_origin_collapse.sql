-- 0067_recording_policy_origin_collapse.sql
--
-- Phase 1 of the recording-policy model redesign (docs/design/POLICY-MODEL.md).
-- Server-only. FOOTAGE-SACRED: this repoints and deletes recording-policy rows,
-- and byte caps are a POOLED budget per effective-policy id, so a wrong collapse
-- could make footage eviction-eligible or drop a camera from recording. Read the
-- design's migration-safety invariant (design section 5) before editing.
--
-- Invariant held here: for every camera, the effective-policy field VALUES
-- resolved by v_camera_effective_policy are unchanged (ids may change, values may
-- not), AND no segment becomes immediately eviction-eligible. We only ever
-- repoint a camera from a ghost fork onto Default when the fork is byte-for-byte
-- identical to Default on all 20 behaviour columns (so its resolved values do not
-- change) AND merging the fork's usage into Default's pool cannot exceed a byte
-- cap (pool guard) AND the fork has no in-flight storage drain (drain guard).
--
-- This whole file is a NON-CONCURRENTLY migration, so the runner applies it as
-- ONE implicit transaction: every repoint happens strictly before the matching
-- delete, in the same transaction (landmine L2). It is idempotent (re-running is
-- a no-op: the origin column add is IF NOT EXISTS; after the first run no
-- name-IS-NULL forks remain to collapse or name).
--
-- We do NOT drop the migration 0021 grouped-camera triggers here: Phase 1 only
-- repoints cameras that ALREADY hold a direct policy_id (= the fork). Such
-- cameras are ungrouped by construction (0020 cleared overrides on grouped
-- cameras; the 0021 trigger keeps a grouped camera's policy_id NULL), so setting
-- their policy_id to Default's id does not trip trg_reject_override_on_grouped_camera.
-- Pinning grouped/inheriting cameras (the operation the trigger would abort) is
-- deferred to Phase 2 (design section 5, Migration B), which drops the triggers first.
-- We also do NOT touch v_camera_effective_policy or the boot NOT-NULL shim: Phase 1
-- keeps NULL-inherit intact.

-- 1. origin: distinguishes operator-created templates (kept at zero members) from
--    auto-created deviation policies (reaped when memberless). Default is 'operator'
--    so the Default row and every existing named template are templates.
ALTER TABLE recording_policies
    ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'operator'
    CHECK (origin IN ('operator', 'deviation'));

-- 2. Every pre-existing anonymous fork (name IS NULL, not the default) is by
--    construction an auto-created per-camera deviation policy.
UPDATE recording_policies
   SET origin = 'deviation'
 WHERE name IS NULL AND NOT is_default;

-- 3. Collapse byte-identical ghost forks into Default, guarded so no camera's
--    effective values change (identity match) and no footage becomes
--    eviction-eligible (pool guard) and no drain is orphaned (drain guard).
DO $collapse$
DECLARE
    d_id         uuid;
    d_live_cap   bigint;
    d_arch_cap   bigint;
    f_id         uuid;
    used_live    bigint;
    used_arch    bigint;
    fork_live    bigint;
    fork_arch    bigint;
BEGIN
    SELECT id, live_max_bytes, archive_max_bytes
      INTO d_id, d_live_cap, d_arch_cap
      FROM recording_policies
     WHERE is_default
     LIMIT 1;

    IF d_id IS NULL THEN
        -- Fresh / un-seeded DB: no default row, nothing to collapse.
        RETURN;
    END IF;

    FOR f_id IN
        SELECT p.id
          FROM recording_policies p
          JOIN recording_policies d ON d.is_default
         WHERE p.name IS NULL
           AND NOT p.is_default
           AND EXISTS (SELECT 1 FROM cameras c WHERE c.policy_id = p.id)
           AND p.mode                       IS NOT DISTINCT FROM d.mode
           AND p.live_storage_id            IS NOT DISTINCT FROM d.live_storage_id
           AND p.live_retention_hours       IS NOT DISTINCT FROM d.live_retention_hours
           AND p.archive_enabled            IS NOT DISTINCT FROM d.archive_enabled
           AND p.archive_storage_id         IS NOT DISTINCT FROM d.archive_storage_id
           AND p.archive_schedule           IS NOT DISTINCT FROM d.archive_schedule
           AND p.archive_retention_hours    IS NOT DISTINCT FROM d.archive_retention_hours
           AND p.live_max_bytes             IS NOT DISTINCT FROM d.live_max_bytes
           AND p.archive_max_bytes          IS NOT DISTINCT FROM d.archive_max_bytes
           AND p.live_min_free_pct          IS NOT DISTINCT FROM d.live_min_free_pct
           AND p.live_min_free_bytes        IS NOT DISTINCT FROM d.live_min_free_bytes
           AND p.live_spill_low_water_bytes IS NOT DISTINCT FROM d.live_spill_low_water_bytes
           AND p.max_retention_days         IS NOT DISTINCT FROM d.max_retention_days
           AND p.motion_pre_seconds         IS NOT DISTINCT FROM d.motion_pre_seconds
           AND p.motion_post_seconds        IS NOT DISTINCT FROM d.motion_post_seconds
           AND p.motion_sensitivity         IS NOT DISTINCT FROM d.motion_sensitivity
           AND p.motion_threshold           IS NOT DISTINCT FROM d.motion_threshold
           AND p.motion_keyframes_only      IS NOT DISTINCT FROM d.motion_keyframes_only
           AND p.record_stream              IS NOT DISTINCT FROM d.record_stream
           AND p.record_audio               IS NOT DISTINCT FROM d.record_audio
         ORDER BY p.id
    LOOP
        -- Drain guard (landmine L8): an in-flight storage migration resolves its
        -- cameras by this policy id; collapsing it would orphan the drain. Keep
        -- the fork (it is named in step 4 instead).
        IF EXISTS (
            SELECT 1 FROM storage_migrations sm
             WHERE sm.policy_id = f_id
               AND sm.status IN ('pending', 'running')
        ) THEN
            CONTINUE;
        END IF;

        -- Pool guard (landmine L1): merging this fork's usage into Default pools
        -- their segments under Default's live/archive byte caps. If that would
        -- push Default over a cap, the merged pool would be immediately
        -- eviction-eligible, so DO NOT collapse — keep + name the fork instead.
        -- Usage is measured cumulatively: earlier iterations that already merged a
        -- fork into Default are reflected because we recompute Default's usage
        -- from v_camera_effective_policy each iteration (same-transaction visibility).
        IF d_live_cap IS NOT NULL THEN
            SELECT COALESCE(SUM(s.size_bytes), 0) INTO used_live
              FROM segments s
              JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
             WHERE s.stage = 'live' AND v.p_id = d_id;
            SELECT COALESCE(SUM(s.size_bytes), 0) INTO fork_live
              FROM segments s
              JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
             WHERE s.stage = 'live' AND v.p_id = f_id;
            IF used_live + fork_live > d_live_cap THEN
                CONTINUE;
            END IF;
        END IF;

        IF d_arch_cap IS NOT NULL THEN
            SELECT COALESCE(SUM(s.size_bytes), 0) INTO used_arch
              FROM segments s
              JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
             WHERE s.stage = 'archive' AND v.p_id = d_id;
            SELECT COALESCE(SUM(s.size_bytes), 0) INTO fork_arch
              FROM segments s
              JOIN v_camera_effective_policy v ON v.c_id = s.camera_id
             WHERE s.stage = 'archive' AND v.p_id = f_id;
            IF used_arch + fork_arch > d_arch_cap THEN
                CONTINUE;
            END IF;
        END IF;

        -- Safe to collapse: repoint the fork's cameras to Default, THEN delete the
        -- now-unreferenced fork (repoint strictly before delete, same transaction).
        UPDATE cameras SET policy_id = d_id WHERE policy_id = f_id;
        DELETE FROM recording_policies WHERE id = f_id;
    END LOOP;
END
$collapse$;

-- 4. Name the survivors: any remaining anonymous fork is a genuinely-distinct
--    deviation policy (or one a guard kept). Name it after its owning camera,
--    suffixed on collision. Ownerless anonymous rows (no camera references them)
--    are the reaper's food and are deleted outright (unreferenced ⇒ footage-safe).
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
            -- Unreferenced anonymous fork: delete now (nothing resolves to it).
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
