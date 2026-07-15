-- Per-badge display overrides for the HA on-video overlay (issue #170
-- follow-up): an operator may recolor a placed badge, swap its icon, and pin
-- its live state text and/or last-changed age next to the badge on the wall.
-- All additive to migration 0058's placement columns; NULL / false means "use
-- the state-derived default", so existing badges render exactly as before.
--
-- overlay_color is a '#RRGGBB' hex string (client-parsed; format-checked
-- here). overlay_icon is a curated icon slug the clients map to a glyph
-- (opaque to the server beyond a sanity length check). The show flags are
-- plain booleans (default off) rather than nullable — "unset" and "off" are
-- the same thing for a display toggle.

ALTER TABLE camera_ha_links
    ADD COLUMN IF NOT EXISTS overlay_color text,
    ADD COLUMN IF NOT EXISTS overlay_icon  text,
    ADD COLUMN IF NOT EXISTS overlay_show_state boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS overlay_show_age   boolean NOT NULL DEFAULT false;

ALTER TABLE camera_ha_links
    ADD CONSTRAINT camera_ha_links_overlay_color_hex
        CHECK (overlay_color IS NULL OR overlay_color ~ '^#[0-9a-fA-F]{6}$'),
    ADD CONSTRAINT camera_ha_links_overlay_icon_len
        CHECK (overlay_icon IS NULL
               OR (length(overlay_icon) >= 1 AND length(overlay_icon) <= 64));
