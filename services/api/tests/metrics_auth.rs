// SPDX-License-Identifier: AGPL-3.0-or-later

//! `GET /metrics` is no longer open: it takes an admin session or the
//! configured `METRICS_TOKEN`.
//!
//! The gate is `auth_mw::MetricsAuth`, which is what `metrics.rs` puts in front
//! of its handler. This suite drives that extractor through a real router with
//! a real `AppState`, so it exercises the same decision the endpoint makes.
//! (`metrics.rs` itself is not re-included here: it reads the build constants
//! `main.rs` defines at the crate root, which a test binary has no copy of.
//! Nothing about the authorization decision lives in that file.)

// The harness (`mod support`) `#[path]`-includes the real `src/` modules, which
// clippy re-lints in this test binary; mirror auth_rbac.rs's allow-set so the
// production code is judged under the same policy, not a stricter one.
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::option_option)]
#![allow(clippy::too_many_lines)]
#![allow(clippy::items_after_statements)]
#![allow(clippy::cast_possible_truncation)]
#![allow(clippy::cast_sign_loss)]
#![allow(clippy::cast_possible_wrap)]
#![allow(clippy::manual_let_else)]
#![allow(clippy::default_trait_access)]
#![allow(clippy::struct_excessive_bools)]
#![allow(clippy::match_same_arms)]
#![allow(clippy::manual_clamp)]
#![allow(clippy::format_push_string)]

mod support;

use axum::http::StatusCode;
use axum::{routing::get, Router};
// Glob so support's `pub mod auth_mw`/`state`/… re-export into the crate root,
// where the `#[path]`-included source resolves them as `crate::…`.
use support::*;

/// The scrape token this binary runs with. Set into the environment before the
/// first `ApiConfig::from_env`, so every test here sees the same value.
const SCRAPE_TOKEN: &str = "test-metrics-scrape-token-0123456789";

static SET_TOKEN: std::sync::Once = std::sync::Once::new();

/// A stand-in for the real `/metrics` handler: the same `MetricsAuth` gate in
/// front of a trivial body.
async fn metrics_probe(_auth: auth_mw::MetricsAuth) -> &'static str {
    "crumb_build_info 1\n"
}

/// `/auth` (to mint real tokens) plus the gated probe.
async fn metrics_app() -> TestApp {
    SET_TOKEN.call_once(|| std::env::set_var("METRICS_TOKEN", SCRAPE_TOKEN));
    let state = test_state().await;
    let router = Router::new()
        .nest("/auth", auth::routes())
        .route("/metrics", get(metrics_probe))
        .with_state(state.clone());
    TestApp { state, router }
}

async fn scrape(app: &TestApp, authorization: Option<&str>) -> StatusCode {
    let mut req = axum::http::Request::builder()
        .method("GET")
        .uri("/metrics");
    if let Some(value) = authorization {
        req = req.header("authorization", value);
    }
    app.send(req.body(axum::body::Body::empty()).unwrap())
        .await
        .status()
}

#[tokio::test]
async fn an_unauthenticated_scrape_is_rejected() {
    let app = metrics_app().await;
    assert_eq!(
        scrape(&app, None).await,
        StatusCode::UNAUTHORIZED,
        "metrics must not be readable without credentials"
    );
}

#[tokio::test]
async fn the_configured_scrape_token_is_accepted() {
    let app = metrics_app().await;
    assert_eq!(
        scrape(&app, Some(&format!("Bearer {SCRAPE_TOKEN}"))).await,
        StatusCode::OK
    );
}

#[tokio::test]
async fn a_wrong_scrape_token_falls_through_to_the_admin_gate() {
    // Also the shape of an install with METRICS_TOKEN unset: the token branch
    // never matches, so only an admin session gets through.
    let app = metrics_app().await;
    assert_eq!(
        scrape(&app, Some("Bearer not-the-scrape-token")).await,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn an_admin_session_is_accepted() {
    let app = metrics_app().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    assert_eq!(
        scrape(&app, Some(&format!("Bearer {token}"))).await,
        StatusCode::OK
    );
}

#[tokio::test]
async fn a_viewer_session_is_refused() {
    // Same convention as the rest of the admin surface: a valid but non-admin
    // session is 403, not 401.
    let app = metrics_app().await;
    let viewer = seed_viewer(app.pool(), &[]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;
    assert_eq!(
        scrape(&app, Some(&format!("Bearer {token}"))).await,
        StatusCode::FORBIDDEN
    );
}
