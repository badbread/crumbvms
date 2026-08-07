// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shared MQTT guards and limits.
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

// ── incoming packet-size limit ────────────────────────────────────────────────

/// Env override for the MQTT packet-size limit, in bytes. Escape hatch only —
/// [`DEFAULT_MAX_PACKET_BYTES`] is meant to be large enough that nobody needs
/// this, but a payload that outgrows even that must be fixable without a
/// rebuild. Named in every oversize-payload log line so the message is
/// self-service.
pub const MAX_PACKET_ENV: &str = "FRIGATE_MQTT_MAX_PACKET_BYTES";

/// Crumb's incoming/outgoing MQTT packet-size limit, in bytes (256 KiB).
///
/// rumqttc 0.24 defaults **both** limits to 10 KiB (`10 * 1024`, see
/// `MqttOptions::default`), and a single incoming packet over that limit is not
/// skipped — it fails the whole event loop with
/// `StateError::Deserialization(PayloadSizeLimitExceeded)`, which tears the
/// connection down. Because the offending message is still queued (or retained)
/// on the broker, every reconnect hits it again: an infinite
/// connect → oversize → disconnect loop in which no Frigate event is ever
/// ingested (issue: Frigate MQTT payloads exceed the default limit).
///
/// A real `frigate/events` payload measured **11409 bytes** — barely over the
/// default — and that envelope is not bounded by anything Crumb controls: it
/// carries `before` *and* `after` full object state, per-object attribute lists,
/// recognized-plate arrays, and (on newer Frigate) tracked-object path data, all
/// of which grow with the number of detected attributes. 256 KiB is ~23x the
/// observed payload, leaves headroom for Frigate versions that add fields, and
/// still bounds a single connection's read buffer to something trivial next to
/// the recorder's frame buffers. It is a ceiling, not an allocation: rumqttc
/// only ever buffers what the broker actually sends.
pub const DEFAULT_MAX_PACKET_BYTES: usize = 256 * 1024;

/// Floor for [`MAX_PACKET_ENV`]: rumqttc's own default. Refusing to go below it
/// means a fat-fingered override can never make the situation *worse* than the
/// stock library behaviour this fix exists to correct.
pub const MIN_MAX_PACKET_BYTES: usize = 10 * 1024;

/// Ceiling for [`MAX_PACKET_ENV`] (16 MiB): the limit is what stops a hostile or
/// broken broker from making Crumb buffer without bound, so the escape hatch
/// must not be able to remove the bound entirely. Also the MQTT 3.1.1 maximum
/// packet size is 256 MiB, so this stays comfortably inside the protocol.
pub const MAX_MAX_PACKET_BYTES: usize = 16 * 1024 * 1024;

/// Resolve the packet-size limit from a raw env value.
///
/// Split from [`max_packet_bytes`] so the parsing/clamping rules are unit
/// testable without mutating process environment. Anything unparseable, zero, or
/// out of range falls back to (or is clamped into) the supported window rather
/// than failing the connection: an operator typo must not take Frigate ingest
/// down, which is the exact failure mode being fixed here.
#[must_use]
pub fn resolve_max_packet_bytes(raw: Option<&str>) -> usize {
    raw.map(str::trim)
        .filter(|v| !v.is_empty())
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|v| *v > 0)
        .map_or(DEFAULT_MAX_PACKET_BYTES, |v| {
            v.clamp(MIN_MAX_PACKET_BYTES, MAX_MAX_PACKET_BYTES)
        })
}

/// The packet-size limit both MQTT clients apply, honouring [`MAX_PACKET_ENV`].
///
/// Read at connect time (not once at startup) so a restart is the only thing
/// needed to pick up a changed value, and so each reconnect re-reads it.
#[must_use]
pub fn max_packet_bytes() -> usize {
    resolve_max_packet_bytes(std::env::var(MAX_PACKET_ENV).ok().as_deref())
}

/// The one operator-facing sentence for "a broker message was bigger than our
/// limit", shared by the API ingester and the recorder motion source so both
/// say the same diagnosable thing.
///
/// Deliberately spells out the consequence (nothing is ingested / the loop
/// restarts forever) and names the knob: the failure this replaces was a raw
/// rumqttc string on one side and a generic "disconnected/unreachable" on the
/// other, indistinguishable from the broker simply being down.
#[must_use]
pub fn oversize_payload_message(payload_bytes: usize, limit_bytes: usize) -> String {
    format!(
        "a Frigate MQTT message of {payload_bytes} bytes exceeded Crumb's incoming MQTT packet \
         limit of {limit_bytes} bytes, so the broker connection was dropped. This repeats on \
         every reconnect while the oversized message is queued or retained, and NO Frigate \
         events are processed meanwhile. Raise the limit by setting {MAX_PACKET_ENV} (bytes, \
         max {MAX_MAX_PACKET_BYTES}) and restarting Crumb."
    )
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

    #[test]
    fn default_limit_clears_a_real_frigate_payload() {
        // The payload measured on the live instance that triggered this fix, and
        // rumqttc 0.24's own default that failed on it.
        const OBSERVED: usize = 11409;
        const RUMQTTC_DEFAULT: usize = 10 * 1024;
        const { assert!(OBSERVED > RUMQTTC_DEFAULT, "the bug premise") };
        const { assert!(DEFAULT_MAX_PACKET_BYTES > OBSERVED * 20) };
    }

    #[test]
    fn unset_or_junk_falls_back_to_the_default() {
        for raw in [
            None,
            Some(""),
            Some("   "),
            Some("lots"),
            Some("-1"),
            Some("0"),
        ] {
            assert_eq!(
                resolve_max_packet_bytes(raw),
                DEFAULT_MAX_PACKET_BYTES,
                "expected {raw:?} to fall back"
            );
        }
    }

    #[test]
    fn override_is_honoured_and_clamped() {
        assert_eq!(resolve_max_packet_bytes(Some("524288")), 524_288);
        assert_eq!(resolve_max_packet_bytes(Some(" 524288 ")), 524_288);
        // Below rumqttc's own default → clamped up, never worse than stock.
        assert_eq!(resolve_max_packet_bytes(Some("1")), MIN_MAX_PACKET_BYTES);
        // Absurdly large → clamped down; the bound must stay a bound.
        assert_eq!(
            resolve_max_packet_bytes(Some("999999999999")),
            MAX_MAX_PACKET_BYTES
        );
    }

    #[test]
    fn oversize_message_names_the_sizes_and_the_knob() {
        let msg = oversize_payload_message(11409, DEFAULT_MAX_PACKET_BYTES);
        assert!(msg.contains("11409"), "{msg}");
        assert!(msg.contains("262144"), "{msg}");
        assert!(msg.contains(MAX_PACKET_ENV), "{msg}");
        // The consequence must be spelled out — the whole point is that this is
        // NOT confusable with a broker being down.
        assert!(msg.contains("NO Frigate"), "{msg}");
    }
}
