-- Per-badge shape / background / outline for the HA on-video overlay (issue
-- #170 readability follow-up): an operator can switch a placed badge between
-- the compact icon "dot" and a labelled "pill", give it a solid background
-- color, and add a white outline + drop shadow so it pops on a busy scene.
-- All additive to migrations 0058-0060; NULL / false means "use the default"
-- (dot shape, default dark background, no outline), so existing badges render
-- unchanged in shape.
--
-- Note the paired client change: the badge background is now drawn OPAQUE and
-- dimmed only by overlay_opacity (migration 0060), replacing a hardcoded
-- translucent scrim — so an existing badge at the default opacity (NULL = 1.0)
-- now reads as a solid dark chip instead of a see-through one. That is the
-- intended readability fix (#170), not a data change.
--
-- overlay_bg_color is a '#RRGGBB' hex string (client-parsed; format-checked
-- here, mirroring overlay_color's 0059 CHECK). overlay_shape is a tiny closed
-- vocabulary. overlay_outline is a plain boolean (default off).

ALTER TABLE camera_ha_links
    ADD COLUMN IF NOT EXISTS overlay_shape    text,
    ADD COLUMN IF NOT EXISTS overlay_bg_color text,
    ADD COLUMN IF NOT EXISTS overlay_outline  boolean NOT NULL DEFAULT false;

ALTER TABLE camera_ha_links
    ADD CONSTRAINT camera_ha_links_overlay_shape_vocab
        CHECK (overlay_shape IS NULL OR overlay_shape IN ('dot', 'pill')),
    ADD CONSTRAINT camera_ha_links_overlay_bg_color_hex
        CHECK (overlay_bg_color IS NULL OR overlay_bg_color ~ '^#[0-9a-fA-F]{6}$');
