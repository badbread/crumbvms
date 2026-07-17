// SPDX-License-Identifier: AGPL-3.0-or-later

//! Credential redaction for log lines.
//!
//! Camera source URLs carry `user:pass@` credentials. They must never reach a
//! log. The recorder redacts the plain `rtsp://user:pass@host` form it puts on
//! ffmpeg's command line; this module additionally handles the
//! **percent-encoded** form — `rtsp%3A%2F%2Fuser%3Apass%40host` — which is how
//! a credentialed URL carried as a query-string value (`?src=<url>`) surfaces
//! inside a client library's connection-error message. That was leaking camera
//! RTSP passwords into the api's go2rtc reconcile `WARN` logs.

/// Redact `user:pass@` userinfo from every URL-like substring in `s`, covering
/// both plain (`scheme://user:pass@host`) and percent-encoded
/// (`scheme%3A%2F%2Fuser%3Apass%40host`) authorities. Anything not matching the
/// `//<userinfo>@` shape (with the `@` before the first `/`) is left unchanged,
/// so credential-less URLs and ordinary text pass through untouched.
pub fn redact_url_credentials(s: &str) -> String {
    // Plain form, then the two percent-encoding cases (reqwest emits uppercase,
    // but be defensive about lowercase too). Each pass rewrites the userinfo
    // between an authority-open marker and the first following `@`-marker that
    // precedes the next `/`-marker.
    let out = redact_authority(s, "://", "@", "/");
    let out = redact_authority(&out, "%2F%2F", "%40", "%2F");
    redact_authority(&out, "%2f%2f", "%40", "%2f")
}

/// Redact the userinfo of every `open`…`at` authority in `s`, where `at` must
/// occur before the next `slash` to count as authority userinfo (not a literal
/// `@`/`/` inside a path). `open`/`at`/`slash` are the literal or
/// percent-encoded spellings of `//`, `@`, and `/`.
fn redact_authority(s: &str, open: &str, at: &str, slash: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(open_idx) = rest.find(open) {
        let auth_start = open_idx + open.len();
        out.push_str(&rest[..auth_start]);
        let after = &rest[auth_start..];
        let at_pos = after.find(at);
        let slash_pos = after.find(slash);
        match at_pos {
            // `@` present and before any `/` → the preceding span is userinfo.
            Some(a) if slash_pos.is_none_or(|sl| a < sl) => {
                out.push_str("***");
                out.push_str(at);
                rest = &after[a + at.len()..];
            }
            // No userinfo here; keep scanning past this open marker.
            _ => rest = after,
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::redact_url_credentials;

    #[test]
    fn plain_userinfo_redacted() {
        assert_eq!(
            redact_url_credentials("rtsp://admin:secret@192.0.2.1/stream"),
            "rtsp://***@192.0.2.1/stream"
        );
    }

    #[test]
    fn plain_no_credentials_unchanged() {
        assert_eq!(
            redact_url_credentials("rtsp://192.0.2.1:554/noauth"),
            "rtsp://192.0.2.1:554/noauth"
        );
    }

    #[test]
    fn literal_at_in_path_not_redacted() {
        // `@` after the first `/` is a path char, not userinfo.
        assert_eq!(
            redact_url_credentials("https://host/path@x"),
            "https://host/path@x"
        );
    }

    #[test]
    fn percent_encoded_userinfo_redacted() {
        // How reqwest renders `?src=rtsp://admin:pw@host` in a connect error.
        let input = "error sending request for url (http://recorder:1984/api/streams?name=garage&src=rtsp%3A%2F%2Fadmin%3Aexamplepass%40198.51.100.9%3A554%2FStreaming): connection refused";
        let out = redact_url_credentials(input);
        assert!(!out.contains("examplepass"), "password leaked: {out}");
        assert!(
            out.contains("rtsp%3A%2F%2F***%40198.51.100.9"),
            "got: {out}"
        );
        // The credential-less go2rtc api URL is untouched.
        assert!(out.contains("http://recorder:1984/api/streams"));
    }

    #[test]
    fn percent_encoded_no_credentials_unchanged() {
        // The LPR sub stream has no user:pass — must pass through untouched.
        let input = "src=rtsp%3A%2F%2F198.51.100.6%3A554%2Fmedia%2Fvideo2";
        assert_eq!(redact_url_credentials(input), input);
    }

    #[test]
    fn onvif_scheme_percent_encoded_redacted() {
        let input = "src=onvif%3A%2F%2Fadmin%3Apw%40198.51.100.5%3Fsubtype%3DMediaProfile0";
        let out = redact_url_credentials(input);
        assert!(!out.contains("%3Apw%40"), "leaked: {out}");
        assert!(
            out.contains("onvif%3A%2F%2F***%40198.51.100.5"),
            "got: {out}"
        );
    }
}
