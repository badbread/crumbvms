// SPDX-License-Identifier: AGPL-3.0-or-later

//! Notification alert-text templating.
//!
//! A tiny, pure, dependency-free `%token%` substitution engine shared by the
//! notification dispatch layer. Operators author per-alert-type message and
//! title templates (stored on `system_alert_rules`); this module renders them
//! against an event's tokens.
//!
//! # Syntax
//!
//! A token is `%name%` where `name` is one or more of `[A-Za-z0-9_]`. Anything
//! else is literal text, including a bare `%`, `%%`, or a `%` followed by a
//! non-token character (`50% free` renders verbatim).
//!
//! # Resolution rules (deliberate, and covered by tests)
//!
//! - A **known** token is replaced by its value.
//! - An **unknown** token (`%typo%`) is left **literal** — including its
//!   delimiters — so a mistake is visible in the output rather than silently
//!   rendering blank. This is intentional: an operator who fat-fingers `%camra%`
//!   should see `%camra%` in the alert and go fix it.
//!
//! # Safety
//!
//! Rendering only ever performs string substitution from a fixed token map —
//! there is no expression evaluation, no recursion into replacement values (a
//! value that itself contains `%camera%` is NOT re-expanded), and no way for a
//! token to resolve to anything but the safe, event-scoped values the caller
//! puts in the map. The rendered string is plain text; the provider dispatch
//! layer is responsible for JSON-escaping it (which it does for free by building
//! bodies with `serde_json`), so a template containing quotes/newlines/braces
//! can never break or inject into a provider payload.

use std::collections::BTreeMap;

/// The built-in default message template for a system alert.
///
/// Reproduces the wording the hardcoded formatter produced before templating
/// existed (`[Crumb] ⚠️ {title} — {detail} (at {ts})`): `%event%` expands to
/// the friendly alert-type title and `%detail%` to the legacy free text, so the
/// default output is byte-identical per event type until an operator edits it.
pub const DEFAULT_SYSTEM_MESSAGE_TEMPLATE: &str = "[Crumb] ⚠️ %event% — %detail% (at %datetime%)";

/// The built-in default message template for a system alert with no `detail`.
///
/// Mirrors the old formatter's empty-detail branch (`[Crumb] ⚠️ {title} (at
/// {ts})`) so an alert that carries no detail string does not render a dangling
/// separator.
pub const DEFAULT_SYSTEM_MESSAGE_TEMPLATE_NO_DETAIL: &str = "[Crumb] ⚠️ %event% (at %datetime%)";

/// The suggested default title template (shown as the editor placeholder).
///
/// NOTE: this is the *suggested* form for an operator who wants a custom title.
/// When `title_template` is NULL the dispatch layer keeps each provider's own
/// existing default title construction unchanged, so leaving the field blank
/// never alters current behaviour.
pub const DEFAULT_SYSTEM_TITLE_TEMPLATE: &str = "Crumb: %event%";

/// Maximum accepted template length (characters), enforced at the API boundary.
pub const MAX_TEMPLATE_LEN: usize = 2000;

/// Pick the built-in default message template for a system alert, honouring the
/// old empty-detail branch so default output stays identical in both cases.
#[must_use]
pub fn default_system_message_template(has_detail: bool) -> &'static str {
    if has_detail {
        DEFAULT_SYSTEM_MESSAGE_TEMPLATE
    } else {
        DEFAULT_SYSTEM_MESSAGE_TEMPLATE_NO_DETAIL
    }
}

/// The effective message template for a system alert: the operator's override
/// when set, otherwise the built-in default. A `None`/blank override "restores
/// the default" purely by falling through here.
#[must_use]
pub fn effective_message_template(override_template: Option<&str>, has_detail: bool) -> String {
    match override_template {
        Some(t) if !t.trim().is_empty() => t.to_owned(),
        _ => default_system_message_template(has_detail).to_owned(),
    }
}

/// Render `template`, substituting every known `%token%` from `tokens` and
/// leaving unknown tokens literal. See the module docs for the exact syntax and
/// resolution rules.
#[must_use]
pub fn render(template: &str, tokens: &BTreeMap<String, String>) -> String {
    let mut out = String::with_capacity(template.len());
    let bytes = template.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            // Scan a maximal run of token characters after the '%'.
            let start = i + 1;
            let mut j = start;
            while j < bytes.len() && is_token_char(bytes[j]) {
                j += 1;
            }
            // A token requires at least one token char AND a closing '%'.
            if j > start && j < bytes.len() && bytes[j] == b'%' {
                // Safe: token chars are ASCII, so this slice is on a char
                // boundary.
                let name = &template[start..j];
                if let Some(val) = tokens.get(name) {
                    out.push_str(val);
                } else {
                    // Unknown token — emit it literally, delimiters and all.
                    out.push('%');
                    out.push_str(name);
                    out.push('%');
                }
                i = j + 1;
                continue;
            }
            // Not a token: emit the '%' literally and move on.
            out.push('%');
            i += 1;
            continue;
        }
        // Copy the next full UTF-8 char (bytes[i] is not '%').
        let ch_len = utf8_len(bytes[i]);
        out.push_str(&template[i..i + ch_len]);
        i += ch_len;
    }
    out
}

/// `[A-Za-z0-9_]` — the characters allowed inside a token name.
const fn is_token_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// Byte length of the UTF-8 sequence that starts with `b`.
const fn utf8_len(b: u8) -> usize {
    if b < 0x80 {
        1
    } else if b >> 5 == 0b110 {
        2
    } else if b >> 4 == 0b1110 {
        3
    } else {
        4
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    #[test]
    fn substitutes_known_tokens() {
        let t = tokens(&[("camera", "Front Door"), ("event", "Camera offline")]);
        assert_eq!(
            render("%event% on %camera%", &t),
            "Camera offline on Front Door"
        );
    }

    #[test]
    fn unknown_token_stays_literal() {
        let t = tokens(&[("camera", "Front Door")]);
        // A typo must be VISIBLE, not silently blank.
        assert_eq!(render("%camra% at %camera%", &t), "%camra% at Front Door");
    }

    #[test]
    fn bare_and_doubled_percent_are_literal() {
        let t = tokens(&[("x", "1")]);
        assert_eq!(render("50% free", &t), "50% free");
        assert_eq!(render("100%% sure", &t), "100%% sure");
        assert_eq!(render("% not a token", &t), "% not a token");
        assert_eq!(render("trailing %", &t), "trailing %");
    }

    #[test]
    fn adjacent_tokens_and_empty_value() {
        let t = tokens(&[("a", "X"), ("b", ""), ("c", "Z")]);
        assert_eq!(render("%a%%b%%c%", &t), "XZ");
    }

    #[test]
    fn replacement_values_are_not_re_expanded() {
        // A value that itself looks like a token is emitted verbatim, never
        // recursed into (no injection via crafted values).
        let t = tokens(&[("detail", "see %camera%"), ("camera", "SECRET")]);
        assert_eq!(render("%detail%", &t), "see %camera%");
    }

    #[test]
    fn builtins_survive_unicode_in_template() {
        let t = tokens(&[("event", "Camera offline"), ("detail", "café")]);
        assert_eq!(
            render("[Crumb] ⚠️ %event% — %detail%", &t),
            "[Crumb] ⚠️ Camera offline — café"
        );
    }

    #[test]
    fn default_template_reproduces_legacy_wording() {
        // The pre-templating formatter was:
        //   with detail:    [Crumb] ⚠️ {title} — {detail} (at {ts})
        //   without detail: [Crumb] ⚠️ {title} (at {ts})
        let ts = "2026-01-02 03:04:05 UTC";
        let t = tokens(&[
            ("event", "Camera offline"),
            ("detail", "camera \"Front Door\" has no fresh RTP for 130s"),
            ("datetime", ts),
        ]);
        assert_eq!(
            render(default_system_message_template(true), &t),
            "[Crumb] ⚠️ Camera offline — camera \"Front Door\" has no fresh RTP for 130s (at 2026-01-02 03:04:05 UTC)"
        );

        let t2 = tokens(&[("event", "Recorder offline"), ("datetime", ts)]);
        assert_eq!(
            render(default_system_message_template(false), &t2),
            "[Crumb] ⚠️ Recorder offline (at 2026-01-02 03:04:05 UTC)"
        );
    }

    #[test]
    fn override_wins_and_blank_restores_default() {
        // A set template overrides; None or a blank/whitespace value falls back
        // to the built-in default ("Restore default" = clear to NULL).
        assert_eq!(
            effective_message_template(Some("BOLO %plate% at %camera%"), true),
            "BOLO %plate% at %camera%"
        );
        assert_eq!(
            effective_message_template(None, true),
            DEFAULT_SYSTEM_MESSAGE_TEMPLATE
        );
        assert_eq!(
            effective_message_template(Some("   "), true),
            DEFAULT_SYSTEM_MESSAGE_TEMPLATE
        );
        assert_eq!(
            effective_message_template(None, false),
            DEFAULT_SYSTEM_MESSAGE_TEMPLATE_NO_DETAIL
        );
    }

    #[test]
    fn rendered_text_is_json_safe() {
        // Proof of golden-rule-1 safety: a template packed with the characters
        // that would break a hand-built JSON string (quotes, backslashes,
        // newlines, braces, control chars) still produces VALID JSON when the
        // rendered text is placed in a serde_json body — because serde escapes
        // it. This mirrors exactly how every provider dispatch builds its body.
        let t = tokens(&[
            ("event", "Watchlist \"hit\""),
            ("detail", "line1\nline2\ttab \\ {\"json\":true} </script>"),
            ("plate", "7ABC\"123"),
        ]);
        let rendered = render("%event%: %detail% [%plate%] 100% {done}", &t);
        let body = serde_json::json!({ "content": rendered });
        let serialized = serde_json::to_string(&body).expect("serialize");
        // Round-trips: valid JSON, and the value survives intact.
        let back: serde_json::Value = serde_json::from_str(&serialized).expect("parse");
        assert_eq!(back["content"].as_str().unwrap(), rendered);
    }
}
