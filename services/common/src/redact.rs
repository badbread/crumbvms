// SPDX-License-Identifier: AGPL-3.0-or-later

//! Credential redaction for log lines, and the read/write masking contract for
//! credentialed URLs that round-trip through the API.
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

// ─── read/write masking for credentialed URLs ─────────────────────────────────

/// The stand-in a URL's password is replaced with on the way out of the API.
///
/// Sending it back unchanged means "keep whatever is stored"; sending anything
/// else means "replace the stored password with this". Same contract the ONVIF
/// password field has had (blank keeps it), expressed inside a URL because a
/// camera source URL carries its credentials inline and the operator edits the
/// whole string.
pub const CREDENTIAL_MASK: &str = "********";

/// Byte range of the password inside the first `scheme://user:pass@host`
/// authority in `s` (exclusive of the `:` and the `@`), or `None` when there is
/// no such authority or it carries no `:password` part.
///
/// Same shape rule as [`redact_url_credentials`]: the `@` counts as the end of
/// userinfo only when it precedes the first `/`, so a literal `@` in a path is
/// not mistaken for a credential separator.
fn password_span(s: &str) -> Option<(usize, usize)> {
    let open = s.find("://")? + 3;
    let after = s.get(open..)?;
    let at = after.find('@')?;
    let userinfo = after.get(..at)?;
    if userinfo.contains('/') {
        return None; // the `@` is in the path, not the authority
    }
    let colon = userinfo.find(':')?;
    Some((open + colon + 1, open + at))
}

/// The password carried in `s`'s userinfo, if any. Percent-encoded exactly as
/// it appears in the URL.
#[must_use]
pub fn url_password(s: &str) -> Option<&str> {
    password_span(s).and_then(|(a, b)| s.get(a..b)).filter(|p| !p.is_empty())
}

/// `true` when `s` carries a non-empty userinfo password.
#[must_use]
pub fn url_has_password(s: &str) -> bool {
    url_password(s).is_some()
}

/// `true` when `s`'s userinfo password is exactly [`CREDENTIAL_MASK`], i.e. the
/// caller sent back what the API handed them.
#[must_use]
pub fn url_password_is_masked(s: &str) -> bool {
    url_password(s) == Some(CREDENTIAL_MASK)
}

/// `s` with its userinfo password replaced by [`CREDENTIAL_MASK`]. The username,
/// scheme, host, port, path and query are untouched, so the value still reads as
/// the operator's own URL and still round-trips through a text field. A URL with
/// no password comes back unchanged.
#[must_use]
pub fn mask_url_password(s: &str) -> String {
    match password_span(s) {
        Some((a, b)) if b > a => format!("{}{CREDENTIAL_MASK}{}", &s[..a], &s[b..]),
        _ => s.to_owned(),
    }
}

/// Resolve a submitted URL against the stored one: a submitted password of
/// [`CREDENTIAL_MASK`] means "keep the stored credential", so the stored
/// password is spliced back in. Everything else about the submitted URL wins,
/// so an operator can change the host or path while leaving the masked password
/// alone.
///
/// Anything other than the mask is taken literally, which is how a password is
/// actually changed. When there is no stored password to restore, the submitted
/// value is returned as-is.
#[must_use]
pub fn unmask_url_password(submitted: &str, stored: Option<&str>) -> String {
    if !url_password_is_masked(submitted) {
        return submitted.to_owned();
    }
    let Some(stored_pw) = stored.and_then(url_password) else {
        return submitted.to_owned();
    };
    match password_span(submitted) {
        Some((a, b)) => format!("{}{stored_pw}{}", &submitted[..a], &submitted[b..]),
        None => submitted.to_owned(),
    }
}

#[cfg(test)]
mod mask_tests {
    use super::{
        mask_url_password, unmask_url_password, url_has_password, url_password_is_masked,
        CREDENTIAL_MASK,
    };

    const STORED: &str = "rtsp://admin:hunter2@198.51.100.9:554/Streaming/Channels/101";

    #[test]
    fn masking_keeps_everything_but_the_password() {
        let masked = mask_url_password(STORED);
        assert_eq!(
            masked,
            format!("rtsp://admin:{CREDENTIAL_MASK}@198.51.100.9:554/Streaming/Channels/101")
        );
        assert!(!masked.contains("hunter2"));
        assert!(url_password_is_masked(&masked));
    }

    #[test]
    fn a_url_without_credentials_is_unchanged() {
        let plain = "rtsp://198.51.100.6:554/media/video2";
        assert_eq!(mask_url_password(plain), plain);
        assert!(!url_has_password(plain));
        // Username but no password: nothing to mask.
        let user_only = "rtsp://admin@198.51.100.6:554/media/video2";
        assert_eq!(mask_url_password(user_only), user_only);
        assert!(!url_has_password(user_only));
    }

    #[test]
    fn an_at_sign_in_the_path_is_not_userinfo() {
        let path_at = "https://198.51.100.6/snap@1";
        assert_eq!(mask_url_password(path_at), path_at);
        assert!(!url_has_password(path_at));
    }

    #[test]
    fn round_tripping_the_mask_restores_the_stored_password() {
        let masked = mask_url_password(STORED);
        assert_eq!(unmask_url_password(&masked, Some(STORED)), STORED);
    }

    #[test]
    fn editing_the_host_around_the_mask_keeps_the_password() {
        let edited = format!("rtsp://admin:{CREDENTIAL_MASK}@198.51.100.40:554/Streaming/Channels/102");
        assert_eq!(
            unmask_url_password(&edited, Some(STORED)),
            "rtsp://admin:hunter2@198.51.100.40:554/Streaming/Channels/102"
        );
    }

    #[test]
    fn a_typed_password_replaces_the_stored_one() {
        let retyped = "rtsp://admin:brand-new@198.51.100.9:554/Streaming/Channels/101";
        assert_eq!(unmask_url_password(retyped, Some(STORED)), retyped);
    }

    #[test]
    fn a_mask_with_nothing_stored_is_left_alone() {
        let masked = format!("rtsp://admin:{CREDENTIAL_MASK}@198.51.100.9:554/x");
        assert_eq!(unmask_url_password(&masked, None), masked);
        assert_eq!(
            unmask_url_password(&masked, Some("rtsp://198.51.100.9:554/x")),
            masked
        );
    }

    #[test]
    fn onvif_sources_mask_the_same_way() {
        let onvif = "onvif://admin:hunter2@198.51.100.5?subtype=MediaProfile0";
        let masked = mask_url_password(onvif);
        assert!(!masked.contains("hunter2"));
        assert_eq!(unmask_url_password(&masked, Some(onvif)), onvif);
    }
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
