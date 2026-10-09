// SPDX-License-Identifier: AGPL-3.0-or-later

//! Recorder-side RTSP base resolution (issue #630).
//!
//! `server_settings.crumb_rtsp_base` has two audiences that need DIFFERENT
//! values, and both used to read the same column:
//!
//! * the **api** hands it to native clients, so it must be an address a phone
//!   or a desktop on the LAN can dial;
//! * the **recorder** dials it for its own ffmpeg workers, and go2rtc is
//!   embedded in the recorder container, so the only correct value there is
//!   loopback.
//!
//! Because the column has to be client-reachable, the recorder was pulling its
//! own embedded go2rtc out through the host's published port and back in
//! through the bridge NAT, roughly doubling container network I/O for the
//! whole camera fleet, continuously.
//!
//! This module owns the recorder half of that split, and it is the ONLY
//! resolver the recorder uses: `recording.rs` and `motion.rs` had each grown a
//! copy and the copies had diverged (the motion copy fell straight back to the
//! Frigate-side base, so on a split install with the column empty a
//! Crumb-served camera's motion sub-stream resolved against Frigate's go2rtc).
//! One function, two call sites, no room for drift.
//!
//! The client-facing half stays in `services/api/src/go2rtc.rs::resolve_bases`,
//! which keeps reading the column, and the settings bootstrap no longer lets
//! the recorder's own "where I dial" value leak into it (see
//! [`crate::db::client_rtsp_base_seed`]).

use deadpool_postgres::Pool;
use tracing::debug;

use crate::config::{self, Config};
use crate::db;
use crate::types::ServerSettings;

/// Port the shipped `go2rtc/go2rtc.yaml` `rtsp:` listener binds INSIDE the
/// recorder container (`listen: ":8554"`; `18554` is only the host publish).
pub const DEFAULT_EMBEDDED_RTSP_PORT: u16 = 8554;

/// Env override for [`DEFAULT_EMBEDDED_RTSP_PORT`].
///
/// An operator who edits `rtsp.listen` in `go2rtc/go2rtc.yaml` sets this to the
/// same port. The port is deliberately NOT parsed out of that file:
/// `crumb-common` would have to read a recorder-container path and hand-parse
/// YAML whose values can be `${VAR}` placeholders, and a parse failure would
/// land on the recording path. A documented constant plus an override cannot
/// fail that way.
const LOOPBACK_PORT_ENV: &str = "CRUMB_GO2RTC_LOOPBACK_PORT";

/// The loopback RTSP base the recorder uses for its own embedded go2rtc.
///
/// `127.0.0.1` rather than `localhost`: no DNS, and go2rtc's RTSP auth
/// exemption is keyed on the peer being a true loopback address. Credentials
/// are still injected by the callers exactly as before, go2rtc simply ignores
/// them on this path.
#[must_use]
pub fn embedded_loopback_rtsp_base() -> String {
    let port = std::env::var(LOOPBACK_PORT_ENV)
        .ok()
        .and_then(|v| v.trim().parse::<u16>().ok())
        .filter(|p| *p != 0)
        .unwrap_or(DEFAULT_EMBEDDED_RTSP_PORT);
    format!("rtsp://127.0.0.1:{port}")
}

/// Is this URL's host a loopback address?
///
/// Used to keep a "where the recorder dials go2rtc" value out of the
/// client-facing column: a client handed `rtsp://localhost:8554` resolves it to
/// ITSELF, which is how issue #630 took live view down on every phone and
/// desktop while recorded playback kept working.
///
/// Byte scan rather than a URL parser so a malformed value can never panic on
/// the recording path. An unparseable or hostname authority returns `false`
/// (not known to be loopback).
#[must_use]
pub fn host_is_loopback(url: &str) -> bool {
    let after_scheme = url.split_once("://").map_or(url, |(_, rest)| rest);
    // The authority ends at the first '/'; userinfo (if any) ends at the last
    // '@' inside it.
    let authority = after_scheme.split('/').next().unwrap_or("");
    let host_port = match authority.rsplit_once('@') {
        Some((_userinfo, host)) => host,
        None => authority,
    };
    // Strip the port, minding bracketed IPv6 literals (`[::1]:8554`).
    let host = if let Some(rest) = host_port.strip_prefix('[') {
        rest.split_once(']').map_or(rest, |(h, _)| h)
    } else {
        host_port.split_once(':').map_or(host_port, |(h, _)| h)
    };
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    host.parse::<std::net::IpAddr>()
        .is_ok_and(|ip| ip.is_loopback())
}

/// Pure resolution of the recorder's `(crumb_rtsp_base, frigate_rtsp_base)`.
///
/// * `embedded` (`GO2RTC_EMBEDDED` is anything but `false`, the default):
///   go2rtc runs in this process's own container, so routing through the host
///   is never correct. The crumb base is `loopback_base` and the DB column is
///   ignored entirely, including when an operator has filled it in.
/// * NOT embedded: the existing order is kept so an external-restreamer
///   install keeps its escape hatch, and it is the repo-wide config precedence
///   (admin-set DB value wins over env, empty DB value falls back to env): the
///   DB column, then `CRUMB_GO2RTC_RTSP_BASE`, then `GO2RTC_RTSP_BASE` as the
///   final backstop for a single-host prototype that set only the generic var
///   (#20).
///
/// The Frigate base is unchanged in both postures: the DB column, else
/// `GO2RTC_RTSP_BASE`.
#[must_use]
pub fn resolve_recorder_bases(
    settings: Option<&ServerSettings>,
    crumb_env: &str,
    frigate_env: &str,
    embedded: bool,
    loopback_base: &str,
) -> (String, String) {
    // A column holding only whitespace counts as empty; a real value is passed
    // through byte-for-byte.
    let non_empty = |v: &str| (!v.trim().is_empty()).then(|| v.to_owned());

    let frigate = settings
        .and_then(|s| non_empty(&s.frigate_rtsp_base))
        .unwrap_or_else(|| frigate_env.to_owned());

    let crumb = if embedded {
        loopback_base.to_owned()
    } else {
        settings
            .and_then(|s| non_empty(&s.crumb_rtsp_base))
            .or_else(|| non_empty(crumb_env))
            .unwrap_or_else(|| frigate_env.to_owned())
    };

    (crumb, frigate)
}

/// Resolve the recorder's RTSP bases from the DB plus this process's env.
///
/// The single resolver for BOTH recorder call sites (the recording worker and
/// the motion worker). A DB error or a missing settings row degrades to the env
/// values, exactly as before: the recorder must never stop recording because
/// the settings row is unreadable.
pub async fn resolve_recorder_rtsp_bases(pool: &Pool, config: &Config) -> (String, String) {
    let settings = db::get_server_settings(pool).await.ok().flatten();
    let embedded = config::go2rtc_embedded_env();
    let loopback = embedded_loopback_rtsp_base();
    let (crumb, frigate) = resolve_recorder_bases(
        settings.as_ref(),
        &config.crumb_go2rtc_rtsp_base,
        &config.go2rtc_rtsp_base,
        embedded,
        &loopback,
    );

    if embedded {
        if let Some(column) = settings
            .as_ref()
            .map(|s| s.crumb_rtsp_base.trim())
            .filter(|v| !v.is_empty() && *v != crumb)
        {
            debug!(
                client_facing_base = %crate::redact::redact_url_credentials(column),
                recorder_base = %crumb,
                "go2rtc is embedded in this container; dialing it over loopback and ignoring \
                 the client-facing server_settings.crumb_rtsp_base (set GO2RTC_EMBEDDED=false \
                 if you run an external restreamer)"
            );
        }
    }

    (crumb, frigate)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A settings row carrying only the two RTSP bases this module reads.
    fn settings(crumb: &str, frigate: &str) -> ServerSettings {
        ServerSettings {
            server_address: String::new(),
            crumb_rtsp_base: crumb.to_owned(),
            crumb_api_base: String::new(),
            frigate_rtsp_base: frigate.to_owned(),
            frigate_api_base: String::new(),
            frigate_go2rtc_api_base: String::new(),
            frigate_http_api_base: String::new(),
            motion_hwaccel: String::new(),
            motion_vaapi_device: String::new(),
            version: 1,
        }
    }

    const LOOPBACK: &str = "rtsp://127.0.0.1:8554";

    /// The reported bug: a wizard-completed install has the host-derived,
    /// client-facing address in the column, and the recorder used it, pulling
    /// its own embedded go2rtc back in through the bridge NAT.
    #[test]
    fn embedded_ignores_a_populated_client_facing_column() {
        let s = settings("rtsp://192.0.2.50:18554", "");
        let (crumb, _) = resolve_recorder_bases(
            Some(&s),
            "rtsp://192.0.2.50:18554", // operator "seatbelt" env, also client-facing
            "",
            true,
            LOOPBACK,
        );
        assert_eq!(crumb, LOOPBACK, "embedded go2rtc is dialed over loopback");
    }

    /// Embedded mode is unconditional: no DB row, or an empty column, resolves
    /// to the same loopback base rather than to either env var.
    #[test]
    fn embedded_is_loopback_without_a_settings_row() {
        let (crumb, frigate) =
            resolve_recorder_bases(None, "rtsp://192.0.2.50:18554", "", true, LOOPBACK);
        assert_eq!(crumb, LOOPBACK);
        assert_eq!(frigate, "", "no Frigate configured stays empty");

        let s = settings("   ", "");
        let (crumb, _) = resolve_recorder_bases(Some(&s), "", "", true, LOOPBACK);
        assert_eq!(crumb, LOOPBACK);
    }

    /// `GO2RTC_EMBEDDED=false` keeps the documented order: the admin-set column
    /// wins, then `CRUMB_GO2RTC_RTSP_BASE`, then `GO2RTC_RTSP_BASE`.
    #[test]
    fn external_restreamer_keeps_the_documented_order() {
        // Column set, so the column wins (admin-set DB value beats env).
        let s = settings("rtsp://192.0.2.60:8554", "");
        let (crumb, _) = resolve_recorder_bases(
            Some(&s),
            "rtsp://192.0.2.61:8554",
            "rtsp://192.0.2.62:8554",
            false,
            LOOPBACK,
        );
        assert_eq!(crumb, "rtsp://192.0.2.60:8554");

        // Column empty, so the crumb-specific env var.
        let s = settings("", "");
        let (crumb, _) = resolve_recorder_bases(
            Some(&s),
            "rtsp://192.0.2.61:8554",
            "rtsp://192.0.2.62:8554",
            false,
            LOOPBACK,
        );
        assert_eq!(crumb, "rtsp://192.0.2.61:8554");

        // Both empty, so the generic backstop (single-host prototype).
        let (crumb, _) =
            resolve_recorder_bases(Some(&s), "", "rtsp://192.0.2.62:8554", false, LOOPBACK);
        assert_eq!(crumb, "rtsp://192.0.2.62:8554");
    }

    /// Second defect in #630: `motion.rs` fell straight back to
    /// `GO2RTC_RTSP_BASE`, the FRIGATE base on a split install, so a
    /// Crumb-served camera's motion sub-stream was opened against Frigate's
    /// go2rtc. Both recorder call sites now share this one resolver, so the
    /// recording path and the motion path cannot resolve differently.
    #[test]
    fn split_install_never_resolves_crumb_against_the_frigate_base() {
        let frigate_env = "rtsp://192.0.2.70:8554"; // BYO Frigate's go2rtc
        let crumb_env = "rtsp://192.0.2.71:18554";

        // Embedded (the default): loopback, nothing Frigate-shaped.
        let s = settings("", frigate_env);
        let (crumb, frigate) =
            resolve_recorder_bases(Some(&s), crumb_env, frigate_env, true, LOOPBACK);
        assert_eq!(crumb, LOOPBACK);
        assert_eq!(frigate, frigate_env, "the Frigate base is untouched");

        // External restreamer, column empty: the crumb-specific var, NOT the
        // Frigate one.
        let (crumb, frigate) =
            resolve_recorder_bases(Some(&s), crumb_env, frigate_env, false, LOOPBACK);
        assert_eq!(crumb, crumb_env);
        assert_eq!(frigate, frigate_env);
    }

    /// The Frigate base resolves identically in both postures.
    #[test]
    fn frigate_base_prefers_the_column_then_env() {
        let s = settings("", "rtsp://192.0.2.80:8554");
        for embedded in [true, false] {
            let (_, frigate) =
                resolve_recorder_bases(Some(&s), "", "rtsp://192.0.2.81:8554", embedded, LOOPBACK);
            assert_eq!(frigate, "rtsp://192.0.2.80:8554");
        }
        let empty = settings("", "");
        for embedded in [true, false] {
            let (_, frigate) = resolve_recorder_bases(
                Some(&empty),
                "",
                "rtsp://192.0.2.81:8554",
                embedded,
                LOOPBACK,
            );
            assert_eq!(frigate, "rtsp://192.0.2.81:8554");
        }
    }

    #[test]
    fn loopback_hosts_are_recognized() {
        assert!(host_is_loopback("rtsp://localhost:8554"));
        assert!(host_is_loopback("rtsp://LocalHost"));
        assert!(host_is_loopback("rtsp://127.0.0.1:8554/driveway"));
        assert!(host_is_loopback("rtsp://127.1.2.3:8554"));
        assert!(host_is_loopback("rtsp://[::1]:8554"));
        assert!(host_is_loopback("rtsp://user:pass@127.0.0.1:8554"));
    }

    #[test]
    fn routable_hosts_are_not_loopback() {
        assert!(!host_is_loopback("rtsp://192.0.2.50:18554"));
        assert!(!host_is_loopback("rtsp://crumb.example:18554/front"));
        assert!(!host_is_loopback(""));
        assert!(!host_is_loopback("rtsp://"));
        assert!(!host_is_loopback("rtsp://[not-an-ip]:1"));
        // A host that merely CONTAINS a loopback label is not loopback.
        assert!(!host_is_loopback("rtsp://localhost.example.net:18554"));
    }
}
