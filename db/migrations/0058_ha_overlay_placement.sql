-- HA on-video overlay (desktop first, issue #170): a linked entity may be
-- pinned to a normalized position on the camera's DISPLAYED VIDEO FRAME so a
-- badge (door/motion/light...) can sit over the thing it represents. NULL = the
-- link is not placed (no badge drawn). Coordinates are fractions of the video
-- frame, not the pane, so a badge stays on the door as the tile aspect changes.
--
-- Additive to migration 0048's camera_ha_links; placement is optional and a
-- link with no placement behaves exactly as before. overlay_size is a scale
-- multiplier on the base badge size (1.0 = default), mirroring the PTZ panel's
-- base-size x pane-scale model.

ALTER TABLE camera_ha_links
    ADD COLUMN IF NOT EXISTS overlay_x    double precision,
    ADD COLUMN IF NOT EXISTS overlay_y    double precision,
    ADD COLUMN IF NOT EXISTS overlay_size real;

-- x and y are set together or not at all (a half-placed badge is meaningless),
-- and both live in [0,1] (fractions of the video frame). size is left
-- unconstrained beyond NULL-vs-set; the API clamps it to a sane range.
ALTER TABLE camera_ha_links
    ADD CONSTRAINT camera_ha_links_overlay_xy_paired
        CHECK ((overlay_x IS NULL) = (overlay_y IS NULL)),
    ADD CONSTRAINT camera_ha_links_overlay_range
        CHECK (overlay_x IS NULL
               OR (overlay_x >= 0 AND overlay_x <= 1
                   AND overlay_y >= 0 AND overlay_y <= 1));
