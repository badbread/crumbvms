-- Home Assistant integration: server connection + per-camera entity links.
--
-- ha_config is a singleton (id=1), the same shape as frigate_config: one HA
-- base URL + a long-lived access token (write-only; never returned by the API),
-- an enable flag, and a monotonic version bumped on every edit so consumers
-- hot-reload. Env (HA_BASE_URL / HA_TOKEN) seeds it as a read-time fallback when
-- a field is empty (DB wins; see get_ha_settings).
--
-- camera_ha_links maps a camera to N HA entities, each with a role:
--   'motion'   -> a state-change sensor that FEEDS the record/timeline pipeline
--                 (PIR/occupancy, or a door you want to trigger recording).
--   'sensor'   -> a status-only read entity shown on the overlay (temp, humidity,
--                 display-only door). Never triggers recording. Reserved here,
--                 wired in a later phase.
--   'actuator' -> an HA light/switch/scene the camera view can control.
-- device_class is the entity's HA class captured at link time (motion, door,
-- window, ...), a denormalized snapshot of the operator's intent so glyphs /
-- the hotspot card don't have to re-query HA (see docs/DECISIONS.md 2026-07-10).
-- A table (not columns) because a room legitimately has several sensors and
-- several controls. Queried directly, NOT via v_camera_effective_policy.
--
-- Additive and optional: with no config and no links, the integration is dormant.

CREATE TABLE IF NOT EXISTS ha_config (
    id         smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled    boolean  NOT NULL DEFAULT false,
    base_url   text     NOT NULL DEFAULT '',
    token      text,
    version    bigint   NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ha_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS camera_ha_links (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    camera_id    uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    entity_id    text NOT NULL,
    role         text NOT NULL CHECK (role IN ('motion', 'sensor', 'actuator')),
    device_class text,
    label        text,
    sort_order   integer NOT NULL DEFAULT 0,
    UNIQUE (camera_id, entity_id, role)
);

CREATE INDEX IF NOT EXISTS idx_camera_ha_links_camera ON camera_ha_links (camera_id);
