-- Pill LAYOUT for the HA on-video badge (issue #497): how wide the pill is,
-- and where its icon + label sit inside it.
--
-- Migration 0062 gave a badge a `pill` shape and the renderers sized it to hug
-- its content. That is the right default, but it leaves an operator with no way
-- to say "make these four pills the same width so they line up down the door
-- frame", and no way to move the label off the leading edge once a pill IS
-- wider than its content. Live testing of the v0.2.0 overlay editor asked for
-- both.
--
-- Two nullable columns, both a SMALL closed vocabulary rather than free pixels,
-- so all four renderers (web console, desktop, Android, iOS) can agree on the
-- result exactly:
--
--   overlay_pill_width  = 'auto' (or NULL) | 'narrow' | 'medium' | 'wide'
--   overlay_text_align  = 'start' (or NULL) | 'center' | 'end'
--
-- Resolution rule, identical in every renderer (and only for a `pill`; a dot
-- ignores both):
--
--   width:  auto/NULL => the measured content width, i.e. today's hug-the-
--                        content rendering, byte for byte
--           narrow    => exactly 4x the pill's HEIGHT
--           medium    => exactly 6x the pill's HEIGHT
--           wide      => exactly 8x the pill's HEIGHT
--   align:  start/NULL => the icon + label group sits against the leading
--                         edge, i.e. today's rendering
--           center     => the group is centred in the pill
--           end        => the group sits against the trailing edge
--
-- The fixed widths are multiples of the badge HEIGHT because height is the one
-- length every renderer already derives identically from `overlay_size` and the
-- pane scale — a pixel width would mean four different answers on four
-- different panes. A fixed width is EXACT, not a minimum: a label too long for
-- it ellipsizes (every renderer already does), which is what makes "these all
-- line up" actually hold.
--
-- NULL in both columns — which is what every existing row gets — is today's
-- behavior, so no placed badge anywhere changes appearance from this migration.
--
-- Value-checked here as well as by the API's validators, mirroring the 0062
-- shape / 0059 color CHECKs, so a bad value is refused by the database too.

ALTER TABLE camera_ha_links
    ADD COLUMN IF NOT EXISTS overlay_pill_width text;
ALTER TABLE camera_ha_links
    ADD COLUMN IF NOT EXISTS overlay_text_align text;

-- Idempotent (DROP IF EXISTS + re-ADD, the 0071/0076 pattern): ALTER TABLE ...
-- ADD CONSTRAINT has no IF NOT EXISTS form, and the runner records
-- schema_migrations in a SEPARATE statement from the apply — so an interrupted
-- boot must be able to re-run this file harmlessly instead of erroring with
-- SQLSTATE 42710 and refusing to start the api and the recorder.
ALTER TABLE camera_ha_links
    DROP CONSTRAINT IF EXISTS camera_ha_links_overlay_pill_width_enum;
ALTER TABLE camera_ha_links
    ADD CONSTRAINT camera_ha_links_overlay_pill_width_enum
        CHECK (overlay_pill_width IS NULL
               OR overlay_pill_width IN ('auto', 'narrow', 'medium', 'wide'));

ALTER TABLE camera_ha_links
    DROP CONSTRAINT IF EXISTS camera_ha_links_overlay_text_align_enum;
ALTER TABLE camera_ha_links
    ADD CONSTRAINT camera_ha_links_overlay_text_align_enum
        CHECK (overlay_text_align IS NULL
               OR overlay_text_align IN ('start', 'center', 'end'));
