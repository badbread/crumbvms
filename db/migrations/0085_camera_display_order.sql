-- 0085_camera_display_order.sql
--
-- Admin-set camera display order. The web console's camera list lets an admin
-- drag cameras into the order every client shows them in (GET /cameras, the
-- auto-built "All Cameras" grid, camera pickers), set with
-- PUT /config/camera-order.
--
-- NULL means "not placed": those cameras follow the placed ones, in natural
-- name order (db::camera_name_order). A fleet nobody has ordered is all NULL,
-- so it keeps the name order it had before this migration, and a camera added
-- later lands at the end until an admin places it.
--
-- Display only. The recorder never reads this column, and it does not touch
-- recording, retention or any footage.

ALTER TABLE cameras ADD COLUMN IF NOT EXISTS display_order integer;
