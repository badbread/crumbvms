-- Clips: server-configurable motion-highlight duration. When > 0, the clip player
-- auto-zooms to where the motion was for this many seconds (then pulls back to
-- full frame). 0 = disabled. Admin-editable; default 2s, clamped 0..4 by the API.
-- Idempotent.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS clip_motion_highlight_seconds INT NOT NULL DEFAULT 2;
