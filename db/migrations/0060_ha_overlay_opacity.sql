-- Per-badge opacity for the HA on-video overlay (issue #170 follow-up): an
-- operator can dim a placed badge (and PTZ buttons get the same client-side,
-- persisted in their local JSON — no column). NULL = fully opaque (default),
-- so existing badges render unchanged.
--
-- Additive to migration 0058/0059's placement + style columns; reset (with the
-- rest of the style) when a placement is cleared. Range mirrors the client
-- clamp (0.05..1.0); the API clamps on write, this CHECK is the backstop.

ALTER TABLE camera_ha_links
    ADD COLUMN IF NOT EXISTS overlay_opacity real;

ALTER TABLE camera_ha_links
    ADD CONSTRAINT camera_ha_links_overlay_opacity_range
        CHECK (overlay_opacity IS NULL
               OR (overlay_opacity >= 0.05 AND overlay_opacity <= 1.0));
