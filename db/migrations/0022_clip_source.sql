-- Clips feature (docs/CLIPS-FEATURE-SCOPE.md): per-camera clip source + global default.
--
-- `cameras.clip_source` (frigate | crumb | NULL = follow the global default)
-- governs where a camera's DETECTION clips come from. Motion clips are ALWAYS
-- generated from our own footage, so this column never affects motion.
--
-- `server_settings.default_clip_source` is the deployment-wide default applied to
-- any camera whose own `clip_source` is NULL. Defaults to 'crumb' (our own
-- recordings) so the feature works with zero Frigate dependency out of the box.
--
-- Idempotent (ADD COLUMN IF NOT EXISTS) — safe to re-run / apply on an existing DB.
ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS clip_source TEXT;

ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS default_clip_source TEXT NOT NULL DEFAULT 'crumb';
