-- Migration 0006: live motion score + effective threshold on motion_grid.
--
-- Part of the motion-detection redesign (docs/MOTION-DETECTION-DESIGN.md). The
-- detector now decides on the LARGEST connected blob's area, not a global
-- changed-pixel count. The recorder publishes that frame's largest-blob area as a
-- fraction of the frame (`score`, 0..1) plus the effective floor it is compared
-- against (`threshold`, 0..1) so the motion tuner can render a coherent live
-- meter and threshold marker — the same quantity that drives the recording
-- trigger and the timeline motion_score.
--
-- The `cells` grid is also now FINE (80×45) and carries the detector's actual
-- foreground (post-exclusion, post-morphology), so the tuner paints changing
-- pixels rather than coarse 16×9 boxes. No schema change is needed for that —
-- only cols/rows/cells values change.
--
-- IF NOT EXISTS makes this idempotent; the recorder also ensures these columns at
-- startup (ensure_motion_grid_table) so the tuner works without a manual run.

ALTER TABLE motion_grid ADD COLUMN IF NOT EXISTS score     real NOT NULL DEFAULT 0;
ALTER TABLE motion_grid ADD COLUMN IF NOT EXISTS threshold real NOT NULL DEFAULT 0;
