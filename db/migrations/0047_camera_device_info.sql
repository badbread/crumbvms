-- Camera device identity captured from ONVIF GetDeviceInformation.
--
-- make/model/firmware are populated from the authenticated ONVIF
-- GetDeviceInformation call (the same probe discovery already runs), by an
-- explicit POST /cameras/:id/identify, or by manual entry in the camera editor.
-- They are matched against the bundled camera-compatibility database to surface
-- known quirks and recommended settings in the console (docs/DECISIONS.md,
-- 2026-07-10). Firmware is informational only, never used to gate a match.
--
-- All nullable and additive: cameras added by raw RTSP URL (no ONVIF) simply
-- leave these NULL and show as "Not identified".
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS make TEXT;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS model TEXT;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS firmware TEXT;
