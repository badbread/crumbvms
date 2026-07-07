-- 0036: go2rtc moved INSIDE the recorder container.
--
-- The standalone `go2rtc` compose service is gone — the same pinned go2rtc
-- binary is now baked into the recorder image and supervised by the recorder
-- process (services/recorder/src/go2rtc_embed.rs). That kills the old internal
-- compose DNS name `go2rtc`: once the container is removed the name no longer
-- resolves, and on some Docker/DNS setups a dangling service name can even
-- fall through to an unrelated LAN host — the exact base-URL poison this
-- consolidation exists to eliminate.
--
-- Auto-heal existing installs: any server_settings row still pinning the OLD
-- internal default `http://go2rtc:1984` is reset to '' (empty), which means
-- "fall back to the CRUMB_GO2RTC_API_BASE env" — and the new compose file sets
-- that correctly (api → http://recorder:1984; recorder → http://localhost:1984,
-- go2rtc now being in-container). Custom values (an external restreamer, a
-- host address) are intentionally left untouched.
UPDATE server_settings
   SET crumb_api_base = ''
 WHERE crumb_api_base IN ('http://go2rtc:1984', 'http://go2rtc:1984/');
