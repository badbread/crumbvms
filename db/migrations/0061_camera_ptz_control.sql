-- 0061_camera_ptz_control.sql
--
-- Per-camera "PTZ controls" toggle.
--
-- Until now a camera's PTZ capability was computed purely from whether it has an
-- ONVIF host configured (`ViewerCameraDto.ptz = onvif_host IS NOT NULL`), which
-- every client gates its PTZ controls on. But plenty of ONVIF cameras are FIXED
-- (no pan/tilt/zoom motor) — they speak ONVIF only for stream discovery — yet
-- they wrongly show PTZ controls. This adds an explicit operator switch so PTZ
-- can be turned off for such a camera.
--
-- Default TRUE = NO behavior change on upgrade: an ONVIF camera keeps showing
-- PTZ controls until the operator turns the switch off. The computed capability
-- becomes `ptz = onvif_host IS NOT NULL AND ptz_control_enabled` (folded in the
-- API's ViewerCameraDto), so NO client change is needed — the clients already
-- gate on `camera.ptz`.

ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS ptz_control_enabled boolean NOT NULL DEFAULT true;

-- Re-declare v_camera_effective_policy to expose the new column. Per the
-- CREATE OR REPLACE VIEW rule, every existing column keeps its name AND order
-- and the new column is APPENDED at the very end (after c_motion_ha_enabled).
-- This mirrors the 0049 body verbatim with one appended column. Idempotent +
-- safe to re-run.
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
    p.record_audio            AS p_record_audio,
    p.max_retention_days      AS p_max_retention_days,
    c.motion_pixel_enabled    AS c_motion_pixel_enabled,
    c.motion_frigate_enabled  AS c_motion_frigate_enabled,
    c.motion_ha_enabled       AS c_motion_ha_enabled,
    c.ptz_control_enabled     AS c_ptz_control_enabled
FROM cameras c
LEFT JOIN camera_group_members m ON m.camera_id = c.id
LEFT JOIN camera_groups g ON g.id = m.group_id
JOIN recording_policies p ON p.id = COALESCE(
    c.policy_id,
    g.policy_id,
    (SELECT id FROM recording_policies WHERE is_default LIMIT 1)
);
