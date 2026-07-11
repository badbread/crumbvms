-- 0049_additive_motion_sources.sql
--
-- Additive motion sources: a camera may enable MORE THAN ONE motion source at
-- once (pixel + Frigate + Home Assistant), and records on the UNION of their
-- triggers. This replaces the exclusive single-value `cameras.motion_source`
-- enum with three independent booleans.
--
-- The old `motion_source` column is KEPT (not dropped): it is referenced by the
-- append-only `v_camera_effective_policy` view, and dropping it would force a
-- view re-declaration (the trap called out in prior migrations). It is now
-- vestigial — no code reads it after this migration — but it is harmless to
-- leave in place. The recorder and API read the three booleans below.
--
-- Backfill maps each existing row to exactly the one source it had, so NO
-- camera changes behavior on upgrade (a 'pixel'/NULL/'' camera stays pixel-only,
-- etc.). See docs/DECISIONS.md (2026-07-10, additive multi-source motion).

ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS motion_pixel_enabled   boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS motion_frigate_enabled boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS motion_ha_enabled      boolean NOT NULL DEFAULT false;

UPDATE cameras SET
    motion_pixel_enabled   = (motion_source IS NULL OR motion_source = '' OR motion_source = 'pixel'),
    motion_frigate_enabled = (motion_source = 'frigate'),
    motion_ha_enabled      = (motion_source = 'ha');

COMMENT ON COLUMN cameras.motion_source IS
    'DEPRECATED (migration 0049): superseded by motion_pixel_enabled / '
    'motion_frigate_enabled / motion_ha_enabled. Kept only because '
    'v_camera_effective_policy references it; no code reads it.';

-- Re-declare v_camera_effective_policy to expose the three new booleans. Per the
-- CREATE OR REPLACE VIEW rule, every existing column keeps its name AND order and
-- the new columns are APPENDED at the end (after p_max_retention_days). This is
-- the whole reason motion_source is kept above — dropping it would break the
-- name/order contract and force a DROP+CREATE. Idempotent + safe to re-run.
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
    c.motion_ha_enabled       AS c_motion_ha_enabled
FROM cameras c
LEFT JOIN camera_group_members m ON m.camera_id = c.id
LEFT JOIN camera_groups g ON g.id = m.group_id
JOIN recording_policies p ON p.id = COALESCE(
    c.policy_id,
    g.policy_id,
    (SELECT id FROM recording_policies WHERE is_default LIMIT 1)
);
