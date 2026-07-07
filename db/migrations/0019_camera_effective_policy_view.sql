-- v_camera_effective_policy — the canonical "camera joined to its EFFECTIVE
-- recording policy" view.
--
-- This encapsulates the effective-policy resolution that was previously
-- HAND-DUPLICATED ~12× across services/common/src/db.rs:
--
--     LEFT JOIN camera_group_members m ON m.camera_id = c.id
--     LEFT JOIN camera_groups        g ON g.id = m.group_id
--     JOIN recording_policies p ON p.id = COALESCE(
--         c.policy_id,                                              -- own policy
--         g.policy_id,                                              -- group's policy
--         (SELECT id FROM recording_policies WHERE is_default LIMIT 1)  -- global default
--     )
--
-- Resolution order is OWN → GROUP → GLOBAL-DEFAULT, byte-for-byte identical to
-- the COALESCE every call site used. The `camera_group_members(camera_id)` unique
-- index (`one_group_per_camera`) guarantees the LEFT JOIN to membership cannot
-- fan a camera out into multiple rows, so this view is exactly one row per camera
-- (Phase-1 load-bearing invariant).
--
-- Column aliases mirror CAMERA_SELECT_SQL exactly:
--   * every `cameras` column as  c_<name>
--   * the camera's group id        as  c_group_id   (from camera_group_members.group_id)
--   * every EFFECTIVE recording-policy column as  p_<name>
-- so the existing row-mapping (camera_from_row) reads the SAME alias names whether
-- it queries the view or the old inline SELECT.
--
-- Idempotent via CREATE OR REPLACE VIEW (safe to re-run on every boot / fresh DB).
-- Behaviour-IDENTICAL foundation only: this introduces NO new resolution
-- semantics; it is the single definition the call sites now share.

CREATE OR REPLACE VIEW v_camera_effective_policy AS
SELECT
    c.id              AS c_id,
    c.name            AS c_name,
    c.enabled         AS c_enabled,
    c.go2rtc_name     AS c_go2rtc_name,
    c.main_url        AS c_main_url,
    c.sub_url         AS c_sub_url,
    c.source_url      AS c_source_url,
    c.source_sub_url  AS c_source_sub_url,
    c.policy_id       AS c_policy_id,
    m.group_id        AS c_group_id,
    c.motion_mask     AS c_motion_mask,
    c.onvif_motion    AS c_onvif_motion,
    c.motion_source     AS c_motion_source,
    c.motion_algorithm  AS c_motion_algorithm,
    c.camera_type       AS c_camera_type,
    c.icon              AS c_icon,
    c.motion_grid_cols  AS c_motion_grid_cols,
    c.motion_grid_rows  AS c_motion_grid_rows,
    c.created_at        AS c_created_at,
    c.served_by         AS c_served_by,
    c.source_camera_name AS c_source_camera_name,
    c.onvif_host        AS c_onvif_host,
    c.onvif_port        AS c_onvif_port,
    c.onvif_user        AS c_onvif_user,
    c.onvif_password    AS c_onvif_password,
    p.id                      AS p_id,
    p.name                    AS p_name,
    p.is_default              AS p_is_default,
    p.mode                    AS p_mode,
    p.live_storage_id         AS p_live_storage_id,
    p.live_retention_hours    AS p_live_retention_hours,
    p.archive_enabled         AS p_archive_enabled,
    p.archive_storage_id      AS p_archive_storage_id,
    p.archive_schedule        AS p_archive_schedule,
    p.archive_retention_hours AS p_archive_retention_hours,
    p.live_max_bytes          AS p_live_max_bytes,
    p.archive_max_bytes       AS p_archive_max_bytes,
    p.live_min_free_pct          AS p_live_min_free_pct,
    p.live_min_free_bytes        AS p_live_min_free_bytes,
    p.live_spill_low_water_bytes AS p_live_spill_low_water_bytes,
    p.motion_pre_seconds      AS p_motion_pre_seconds,
    p.motion_post_seconds     AS p_motion_post_seconds,
    p.motion_sensitivity      AS p_motion_sensitivity,
    p.motion_threshold        AS p_motion_threshold,
    p.motion_keyframes_only   AS p_motion_keyframes_only,
    p.record_stream           AS p_record_stream,
    p.record_audio            AS p_record_audio
FROM cameras c
LEFT JOIN camera_group_members m ON m.camera_id = c.id
LEFT JOIN camera_groups g ON g.id = m.group_id
JOIN recording_policies p ON p.id = COALESCE(
    c.policy_id,
    g.policy_id,
    (SELECT id FROM recording_policies WHERE is_default LIMIT 1)
);
