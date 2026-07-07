-- Per-policy ABSOLUTE maximum-retention cap (GDPR/UK-DPA data-minimization).
--
-- Adds `recording_policies.max_retention_days`: an optional hard UPPER BOUND on
-- how old ANY footage under a policy may get, across BOTH the live and archive
-- stages. `NULL` (the default) ⇒ OFF — no cap, today's behaviour, so this can
-- never surprise-delete footage on an existing install. When set to N days the
-- recorder deletes segments whose `start_ts` is older than N days regardless of
-- the size caps or the per-tier live/archive retention windows. It is an
-- ADDITIONAL constraint layered on top of the existing knobs, not a replacement:
-- footage still expires under `live_retention_hours` / `archive_retention_hours`
-- and the size caps as before; this only ever removes footage SOONER, never
-- keeps it longer.
--
-- Legal framing: there is NO fixed statutory retention number (GDPR Art. 5(1)(e)
-- / the ICO both say "no fixed min/max"), so we deliberately store an operator-
-- chosen value and hardcode nothing. See docs/DECISIONS.md.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE VIEW (safe to re-run
-- on every boot / a fresh DB). No BEGIN/COMMIT — the runner wraps a
-- non-CONCURRENTLY file in a single implicit transaction.

ALTER TABLE recording_policies
    ADD COLUMN IF NOT EXISTS max_retention_days integer;

-- Re-declare the canonical effective-policy view so the recorder can read the
-- new column as `p_max_retention_days` through the same join every sweep uses.
-- CREATE OR REPLACE VIEW only APPENDS the new trailing column; all existing
-- columns keep their name/order (a hard requirement of CREATE OR REPLACE VIEW),
-- so this is behaviour-identical for every existing consumer. Kept byte-for-byte
-- in sync with 0019 plus the one appended column.
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
    p.max_retention_days      AS p_max_retention_days
FROM cameras c
LEFT JOIN camera_group_members m ON m.camera_id = c.id
LEFT JOIN camera_groups g ON g.id = m.group_id
JOIN recording_policies p ON p.id = COALESCE(
    c.policy_id,
    g.policy_id,
    (SELECT id FROM recording_policies WHERE is_default LIMIT 1)
);
