// SPDX-License-Identifier: AGPL-3.0-or-later

//! Standard response headers applied by the API.
//!
//! Two groups, deliberately scoped differently:
//!
//! * **Every response** carries `X-Content-Type-Options: nosniff` (a browser
//!   must honour the declared `Content-Type` rather than guessing from the
//!   bytes) and `Referrer-Policy: no-referrer` (no Crumb URL, and in
//!   particular no `?token=` media URL, is ever put in a `Referer` header sent
//!   to another origin).
//! * **The `/admin` document only** carries a `Content-Security-Policy`. The
//!   console is one self-contained page: its script and styles are inline, its
//!   icons are inline SVG, every `fetch()` is a same-origin relative path, and
//!   the only non-`'self'` image sources it uses are `data:` (the inline
//!   placeholder glyphs) and `blob:` (snapshot frames handed back by
//!   `URL.createObjectURL`). The policy below is exactly that surface and
//!   nothing wider. It is not attached to the API's JSON/media responses,
//!   which are not documents and whose consumers are native clients.
//!
//! `'unsafe-inline'` is present for scripts and styles because the console is
//! a single `include_str!`-embedded file with one inline `<script>` and inline
//! `style=` attributes throughout. Splitting it into hashed external assets is
//! a much larger change to how the console is built and served; the policy
//! still removes the whole class of remote-origin loading, framing, `<base>`
//! rewriting, plugin embedding, and cross-origin form posting.

use axum::http::{header, HeaderValue};
use axum::Router;
use tower_http::set_header::SetResponseHeaderLayer;

/// Content-Security-Policy for the `/admin` console document.
pub const ADMIN_CSP: &str = "default-src 'self'; \
     script-src 'self' 'unsafe-inline'; \
     style-src 'self' 'unsafe-inline'; \
     img-src 'self' data: blob:; \
     media-src 'self' blob:; \
     connect-src 'self'; \
     frame-ancestors 'self'; \
     base-uri 'none'; \
     object-src 'none'; \
     form-action 'self'";

/// Wrap `router` so every response it produces carries the two site-wide
/// headers. Apply this outermost, so it covers the `/auth` subtree (which is
/// deliberately merged outside the CORS layer, see `cors::compose`) as well as
/// the rest of the API.
#[must_use]
pub fn with_site_headers<S>(router: Router<S>) -> Router<S>
where
    S: Clone + Send + Sync + 'static,
{
    router
        .layer(SetResponseHeaderLayer::overriding(
            header::X_CONTENT_TYPE_OPTIONS,
            HeaderValue::from_static("nosniff"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::REFERRER_POLICY,
            HeaderValue::from_static("no-referrer"),
        ))
}

/// The `Content-Security-Policy` layer for the `/admin` route only.
#[must_use]
pub fn admin_csp_layer() -> SetResponseHeaderLayer<HeaderValue> {
    SetResponseHeaderLayer::overriding(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(ADMIN_CSP),
    )
}

#[cfg(test)]
mod tests {
    use super::ADMIN_CSP;

    /// The policy must stay a valid single-line header value (no control
    /// characters), and must keep the directives the console actually needs.
    #[test]
    fn admin_csp_is_a_valid_header_value_with_the_expected_directives() {
        axum::http::HeaderValue::from_static(ADMIN_CSP);
        for directive in [
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data: blob:",
            "media-src 'self' blob:",
            "connect-src 'self'",
            "frame-ancestors 'self'",
            "base-uri 'none'",
            "object-src 'none'",
            "form-action 'self'",
        ] {
            assert!(
                ADMIN_CSP.contains(directive),
                "missing directive: {directive}"
            );
        }
    }
}
