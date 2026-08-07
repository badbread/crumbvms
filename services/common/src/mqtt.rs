// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shared MQTT URL guards.
//!
//! Crumb's MQTT clients (the API's Frigate detection ingester and the
//! recorder's Frigate-as-motion-source loop) both build a **plaintext** rumqttc
//! connection: `rumqttc` is pinned with `default-features = false`, so no TLS
//! transport is compiled in at all.
//!
//! Historically both `parse_mqtt_url()` helpers *accepted* a `mqtts://` URL and
//! then silently stripped the scheme, connecting in cleartext. An operator who
//! configured `mqtts://` believed their broker credentials were encrypted when
//! they were not, a silent security downgrade (issue #477).
//!
//! [`check_plaintext_scheme`] is the single chokepoint that makes that fail
//! loudly instead. It is deliberately narrow: it rejects only the schemes that
//! *imply TLS*, so every URL form that works today keeps working.

/// The operator-facing message used everywhere a TLS MQTT URL is refused.
///
/// Kept as one constant so the admin console 400, the API provider log, and the
/// recorder motion-source log all say exactly the same thing.
pub const MQTT_TLS_UNSUPPORTED: &str =
    "TLS MQTT is not yet supported: Crumb's MQTT client is built without a TLS \
     transport, so a 'mqtts://' URL would connect in cleartext. Use 'mqtt://' on a \
     trusted LAN, or file an issue to request TLS support.";

/// Schemes that an operator would reasonably read as "this connection is
/// encrypted". Compared lowercase, without the `://`.
const TLS_SCHEMES: [&str; 5] = ["mqtts", "ssl", "mqtt+ssl", "tls", "wss"];

/// Reject an MQTT URL whose scheme implies TLS.
///
/// Returns `Ok(())` for `mqtt://`, for a bare `host[:port]` with no scheme, and
/// for any other non-TLS scheme (behavior for those is unchanged). Returns
/// `Err(MQTT_TLS_UNSUPPORTED)` for `mqtts://` and friends so the caller can fail
/// the connection, or 400 the config write, instead of quietly downgrading.
///
/// # Errors
///
/// Errors when `url`'s scheme is one of [`TLS_SCHEMES`].
pub fn check_plaintext_scheme(url: &str) -> Result<(), &'static str> {
    let trimmed = url.trim();
    let Some((scheme, _)) = trimmed.split_once("://") else {
        // No scheme at all — the legacy bare `host[:port]` form. Plaintext by
        // definition, nothing to mislead the operator.
        return Ok(());
    };
    if TLS_SCHEMES.contains(&scheme.to_ascii_lowercase().as_str()) {
        return Err(MQTT_TLS_UNSUPPORTED);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plaintext_schemes_are_accepted() {
        for url in [
            "mqtt://broker.lan:1883",
            "mqtt://user:pw@broker.lan",
            "mqtt://[2001:db8::1]:1883",
            "broker.lan:1883",
            "192.0.2.10",
            "",
        ] {
            assert!(
                check_plaintext_scheme(url).is_ok(),
                "expected {url} to be accepted"
            );
        }
    }

    #[test]
    fn tls_schemes_are_rejected() {
        for url in [
            "mqtts://broker.lan:8883",
            "MQTTS://broker.lan:8883",
            "  mqtts://user:pw@[fe80::1]:8883  ",
            "ssl://broker.lan:8883",
            "mqtt+ssl://broker.lan",
            "tls://broker.lan",
            "wss://broker.lan/mqtt",
        ] {
            assert_eq!(
                check_plaintext_scheme(url),
                Err(MQTT_TLS_UNSUPPORTED),
                "expected {url} to be rejected"
            );
        }
    }

    #[test]
    fn message_names_the_scheme_and_the_way_out() {
        // The operator has to be able to act on this without reading the source.
        assert!(MQTT_TLS_UNSUPPORTED.contains("mqtts://"));
        assert!(MQTT_TLS_UNSUPPORTED.contains("mqtt://"));
    }
}
