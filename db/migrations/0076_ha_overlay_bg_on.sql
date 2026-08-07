-- Per-STATE background color for the HA on-video badge (wave A of the badge
-- customization rework). Migration 0062 gave a placed badge one solid
-- background (overlay_bg_color); an operator who wants "dark when the door is
-- shut, red when it is open" has no way to say so, because a single column
-- cannot carry two states.
--
-- The chosen model is inherit-from-base, one extra nullable column:
--
--   overlay_bg_color     = the BASE background. It renders when the entity
--                          reads off AND when the entity is indeterminate or
--                          stale (unknown/unavailable/no reading yet). Meaning
--                          unchanged from 0062, so every existing badge keeps
--                          rendering exactly as it does today.
--   overlay_bg_color_on  = an OVERRIDE that applies ONLY while the entity reads
--                          on. NULL (the default, and the value every existing
--                          row gets) means "inherit the base", i.e. today's
--                          single-background behavior.
--
-- Renderer resolution, identical in every client:
--     on      => bg_color_on ?? bg_color ?? default #17171B
--     any other state => bg_color ?? default #17171B
--
-- Format-checked here as a '#RRGGBB' hex string, mirroring the 0059
-- overlay_color and 0062 overlay_bg_color CHECKs, so a bad value is refused by
-- the database as well as by the API's valid_overlay_color gate.

ALTER TABLE camera_ha_links
    ADD COLUMN IF NOT EXISTS overlay_bg_color_on text;

ALTER TABLE camera_ha_links
    ADD CONSTRAINT camera_ha_links_overlay_bg_color_on_hex
        CHECK (overlay_bg_color_on IS NULL OR overlay_bg_color_on ~ '^#[0-9a-fA-F]{6}$');
