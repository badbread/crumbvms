-- PTZ controls now default OFF (opt-in), reversing migration 0061's default.
-- Rationale: default-ON showed "This camera has pan/tilt/zoom controls" checked
-- on every camera in the admin console, which reads as PTZ being force-enabled
-- everywhere. Operators want to opt PTZ in only on cameras that actually have
-- it. New cameras now default OFF, and existing cameras are reset to OFF.
--
-- This only changes which cameras EXPOSE PTZ, not whether PTZ is possible: the
-- effective flag is still `ptz = onvif_host IS NOT NULL AND ptz_control_enabled`
-- (see the v_camera_effective_policy view / clients), so a fixed / non-ONVIF
-- camera was never controllable regardless. After this runs, re-check the PTZ
-- box on the cameras that genuinely pan/tilt/zoom.

ALTER TABLE cameras ALTER COLUMN ptz_control_enabled SET DEFAULT false;

UPDATE cameras SET ptz_control_enabled = false;
