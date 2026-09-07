// SPDX-License-Identifier: AGPL-3.0-or-later

//! Standard response headers: the two site-wide ones on every response, and
//! the Content-Security-Policy on the `/admin` console document only.
//!
//! These exercise the REAL `response_headers.rs` helpers `main.rs` uses (the
//! module is `#[path]`-included, the same idiom as `tests/support/mod.rs`), so
//! a future refactor that drops a layer fails here. No database is needed: the
//! layers are state-independent, so the router is built over `()`.

#[path = "../src/response_headers.rs"]
mod response_headers;

use axum::{body::Body, http::Request, routing::get, Router};
use tower::ServiceExt as _;

/// A stand-in for `main.rs`'s router: one plain JSON-ish route plus `/admin`
/// carrying the console's CSP layer, all wrapped in the site-wide headers.
fn app() -> Router {
    response_headers::with_site_headers(
        Router::new()
            .route("/health", get(|| async { "ok" }))
            .route(
                "/admin",
                get(|| async { "<!doctype html>" }).layer(response_headers::admin_csp_layer()),
            ),
    )
}

async fn head(path: &str, name: &str) -> Option<String> {
    let res = app()
        .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
        .await
        .expect("router::oneshot");
    res.headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned)
}

#[tokio::test]
async fn every_response_carries_nosniff_and_no_referrer() {
    for path in ["/health", "/admin"] {
        assert_eq!(
            head(path, "x-content-type-options").await.as_deref(),
            Some("nosniff"),
            "{path} must send X-Content-Type-Options"
        );
        assert_eq!(
            head(path, "referrer-policy").await.as_deref(),
            Some("no-referrer"),
            "{path} must send Referrer-Policy"
        );
    }
}

#[tokio::test]
async fn admin_document_carries_the_console_csp() {
    let csp = head("/admin", "content-security-policy")
        .await
        .expect("/admin must send a Content-Security-Policy");
    assert_eq!(csp, response_headers::ADMIN_CSP);
    // The directives the console's own surface needs, spelled out here so a
    // widening edit to the constant has to be made deliberately in two places.
    assert!(csp.contains("default-src 'self'"));
    assert!(csp.contains("img-src 'self' data: blob:"));
    assert!(csp.contains("frame-ancestors 'self'"));
    assert!(csp.contains("object-src 'none'"));
}

#[tokio::test]
async fn non_document_responses_carry_no_csp() {
    // The CSP is scoped to the console document; JSON/media responses (consumed
    // by native clients) must not gain a policy header.
    assert_eq!(head("/health", "content-security-policy").await, None);
}
