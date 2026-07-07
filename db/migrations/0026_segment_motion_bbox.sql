-- Clips motion-highlight: persist WHERE the motion was for each motion segment so
-- the clip player can auto-zoom to that region. Stored as a normalized bounding
-- box (0..1 fractions of the frame, resolution-independent) of the largest motion
-- blob at the segment's peak-motion frame. NULL on segments without motion (or
-- recorded before this migration). Lives with the segment, so it is evicted with
-- the footage and needs no separate retention. Idempotent.
ALTER TABLE segments
    ADD COLUMN IF NOT EXISTS motion_bbox_x REAL,
    ADD COLUMN IF NOT EXISTS motion_bbox_y REAL,
    ADD COLUMN IF NOT EXISTS motion_bbox_w REAL,
    ADD COLUMN IF NOT EXISTS motion_bbox_h REAL;
