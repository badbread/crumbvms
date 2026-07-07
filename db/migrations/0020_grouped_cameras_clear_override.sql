-- Phase 3: camera GROUPS are AUTHORITATIVE. A camera in a group always uses the
-- group's assigned recording profile (storage/retention/archive/mode); it may
-- not also hold its own direct per-camera policy. The effective-policy COALESCE
-- (v_camera_effective_policy: own -> group -> default) puts cameras.policy_id
-- FIRST, so a grouped camera that still has a direct policy_id would silently
-- shadow its group's profile. Clear the direct override on every camera that is
-- currently a member of ANY group so the group's profile governs.
--
-- Idempotent: a camera with policy_id already NULL is left as-is by the
-- `policy_id IS NOT NULL` guard, and re-running the migration is a no-op. On the
-- current prod DB this is EXPECTED to affect ZERO rows — the only grouped camera
-- that had an override (.12 Family Room) was already cleared, so it inherits its
-- group. The statement exists to enforce the invariant generally and to handle
-- stragglers / other deployments.
--
-- FOOTAGE: footage is resolved by each segment's own storage_id (not by policy),
-- so existing footage stays readable; new footage records to the group profile's
-- storage; if an old override pointed at a different disk, that footage drains /
-- archives naturally under the group profile's retention. No active footage move
-- is performed here, and no retention/eviction semantics change.
--
-- An anonymous copy-on-write fork (is_default = false, name IS NULL) left
-- unreferenced by this clear is removed by the recorder's periodic
-- reap_orphan_policy_forks reaper; this migration does not delete forks.

UPDATE cameras
SET policy_id = NULL
WHERE policy_id IS NOT NULL
  AND id IN (SELECT camera_id FROM camera_group_members);
