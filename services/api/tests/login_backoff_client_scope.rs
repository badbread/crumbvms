// SPDX-License-Identifier: AGPL-3.0-or-later

//! The repeated-failure login backoff is keyed on (account, client), not on the
//! account alone.
//!
//! Before this, five wrong-password attempts against a username blocked that
//! username for everyone: whoever submitted them decided, for the next fifteen
//! minutes, that the account's real owner could not sign in. Keying the counter
//! on the client as well keeps the brake on the client that is failing while
//! leaving the account reachable from anywhere else. The per-client request
//! bucket (`rate_limit.rs`) is unchanged and still the global limiter.
//!
//! Same harness as the rest of the suite: `tests/support` re-includes the real
//! `src/` modules, so these drive the actual `auth::login` handler and the
//! actual `AppState` counters.

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

use std::net::SocketAddr;

use axum::extract::ConnectInfo;
use axum::http::StatusCode;

// Glob so support's `pub mod auth_mw`/`state`/… re-export into the crate root,
// where the `#[path]`-included source resolves them as `crate::…`.
use support::*;

const CLIENT_A: &str = "198.51.100.11:51000";
const CLIENT_B: &str = "203.0.113.22:51000";

/// One `POST /auth/login` carrying a `ConnectInfo` peer address, the way
/// `into_make_service_with_connect_info` supplies it in production.
async fn login_from(
    app: &TestApp,
    peer: &str,
    username: &str,
    password: &str,
) -> axum::http::Response<axum::body::Body> {
    let mut req = axum::http::Request::builder()
        .method("POST")
        .uri("/auth/login")
        .header("content-type", "application/json")
        .body(axum::body::Body::from(
            login_body(username, password).to_string(),
        ))
        .unwrap();
    let addr: SocketAddr = peer.parse().expect("test peer address");
    req.extensions_mut().insert(ConnectInfo(addr));
    app.send(req).await
}

#[tokio::test]
async fn failures_from_one_client_do_not_block_the_account_elsewhere() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    // Six wrong-password attempts from client A: the first five are plain 401s
    // (threshold is 5), the sixth is A's own 429.
    for i in 0..5 {
        let resp = login_from(&app, CLIENT_A, &admin.username, "wrong-password").await;
        assert_eq!(
            resp.status(),
            StatusCode::UNAUTHORIZED,
            "attempt {i} from client A should still be a plain 401"
        );
    }
    let blocked = login_from(&app, CLIENT_A, &admin.username, "wrong-password").await;
    assert_eq!(
        blocked.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "client A must be in backoff after crossing the threshold"
    );
    // ... and stays blocked there even with the correct password.
    let blocked_correct = login_from(&app, CLIENT_A, &admin.username, &admin.password).await;
    assert_eq!(blocked_correct.status(), StatusCode::TOO_MANY_REQUESTS);

    // The regression this test exists for: the SAME account, from a different
    // client, is untouched. A wrong password is a 401 (not a 429) ...
    let other_wrong = login_from(&app, CLIENT_B, &admin.username, "wrong-password").await;
    assert_eq!(
        other_wrong.status(),
        StatusCode::UNAUTHORIZED,
        "client B must not inherit client A's backoff"
    );
    // ... and the correct password signs in.
    let other_ok = login_from(&app, CLIENT_B, &admin.username, &admin.password).await;
    assert_eq!(
        other_ok.status(),
        StatusCode::OK,
        "the account owner must still be able to sign in from their own client"
    );
}

#[tokio::test]
async fn counters_are_tracked_per_client_pair() {
    // The same invariant at the state layer, without the HTTP round trip, so a
    // failure here points straight at the counter rather than at routing.
    let app = TestApp::new().await;
    let username = unique("backoff-user");

    for _ in 0..5 {
        app.state.record_login_failure(&username, "198.51.100.11");
    }
    assert!(
        app.state
            .login_retry_after(&username, "198.51.100.11")
            .is_some(),
        "the failing client is in backoff"
    );
    assert!(
        app.state
            .login_retry_after(&username, "203.0.113.22")
            .is_none(),
        "a different client for the same account is not"
    );

    // A success clears only the client that succeeded.
    app.state.record_login_success(&username, "198.51.100.11");
    assert!(
        app.state
            .login_retry_after(&username, "198.51.100.11")
            .is_none(),
        "a successful sign-in resets that client's counter"
    );
}
