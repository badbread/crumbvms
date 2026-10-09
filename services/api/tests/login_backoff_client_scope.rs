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
//! Two things keep that from becoming a way around the brake:
//!
//! - the client is the TCP peer unless the peer is a configured trusted proxy,
//!   so a client talking to the api directly cannot pick its own key with a
//!   forged `X-Forwarded-For`;
//! - a separate, higher account-wide ceiling counts failures from every client
//!   together, so spreading attempts over many addresses still runs into it.
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
    login_via(app, peer, None, username, password).await
}

/// [`login_from`] with an optional `X-Forwarded-For` header.
async fn login_via(
    app: &TestApp,
    peer: &str,
    forwarded_for: Option<&str>,
    username: &str,
    password: &str,
) -> axum::http::Response<axum::body::Body> {
    let mut builder = axum::http::Request::builder()
        .method("POST")
        .uri("/auth/login")
        .header("content-type", "application/json");
    if let Some(xff) = forwarded_for {
        builder = builder.header("x-forwarded-for", xff);
    }
    let mut req = builder
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

/// The configured proxy in the trusted-proxy tests, and a LAN host that is not
/// one.
const PROXY_PEER: &str = "192.0.2.10:44000";
const DIRECT_PEER: &str = "192.0.2.50:51000";

async fn app_behind_proxy() -> TestApp {
    TestApp::new_with_config(|cfg| {
        cfg.trust_proxy = true;
        cfg.trusted_proxies = "192.0.2.10".to_owned();
    })
    .await
}

#[tokio::test]
async fn forged_forwarded_for_from_a_direct_peer_is_ignored() {
    // TRUST_PROXY is on, but this request reaches the api directly, not through
    // the configured proxy. A fresh X-Forwarded-For value on every attempt must
    // not buy a fresh backoff counter: all six attempts key on the TCP peer.
    let app = app_behind_proxy().await;
    let admin = seed_admin(app.pool()).await;

    for i in 0..5 {
        let forged = format!("198.51.100.{}", i + 1);
        let resp = login_via(
            &app,
            DIRECT_PEER,
            Some(&forged),
            &admin.username,
            "wrong-password",
        )
        .await;
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED, "attempt {i}");
    }
    let sixth = login_via(
        &app,
        DIRECT_PEER,
        Some("198.51.100.200"),
        &admin.username,
        &admin.password,
    )
    .await;
    assert_eq!(
        sixth.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "a rotated header from a non-proxy peer must not escape that peer's backoff"
    );
}

#[tokio::test]
async fn trusted_proxy_forwarded_for_is_honoured() {
    // Through the configured proxy, the header does name the client: one
    // client behind the proxy backs off without blocking another.
    let app = app_behind_proxy().await;
    let admin = seed_admin(app.pool()).await;

    for _ in 0..5 {
        let resp = login_via(
            &app,
            PROXY_PEER,
            Some("198.51.100.1"),
            &admin.username,
            "wrong-password",
        )
        .await;
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }
    let blocked = login_via(
        &app,
        PROXY_PEER,
        Some("198.51.100.1"),
        &admin.username,
        &admin.password,
    )
    .await;
    assert_eq!(blocked.status(), StatusCode::TOO_MANY_REQUESTS);

    // The client-supplied left-most entry is not believed: the proxy's own
    // right-most entry still names 198.51.100.1, so this is still blocked.
    let spoofed_left = login_via(
        &app,
        PROXY_PEER,
        Some("203.0.113.5, 198.51.100.1"),
        &admin.username,
        &admin.password,
    )
    .await;
    assert_eq!(spoofed_left.status(), StatusCode::TOO_MANY_REQUESTS);

    let other = login_via(
        &app,
        PROXY_PEER,
        Some("198.51.100.2"),
        &admin.username,
        &admin.password,
    )
    .await;
    assert_eq!(
        other.status(),
        StatusCode::OK,
        "a different client behind the same proxy is not blocked"
    );
}

/// A distinct client address for the `i`-th rotating attempt.
fn rotating_client(i: usize) -> String {
    format!("198.51.100.{}", i + 1)
}

#[tokio::test]
async fn rotating_client_addresses_still_hit_the_account_ceiling() {
    // 29 failures, each from a different address: no single client is near its
    // own threshold, and the account is just under its ceiling (30).
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    for i in 0..29 {
        app.state
            .record_login_failure(&admin.username, &rotating_client(i));
    }

    // The 30th failure arrives over HTTP from yet another address. It is
    // still answered normally (401) ...
    let thirtieth = login_from(&app, "203.0.113.30:50000", &admin.username, "wrong").await;
    assert_eq!(thirtieth.status(), StatusCode::UNAUTHORIZED);

    // ... and now the account is braked for every client, including one that
    // has never failed and holds the correct password.
    let fresh = login_from(&app, "203.0.113.31:50000", &admin.username, &admin.password).await;
    assert_eq!(
        fresh.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "spreading failures over many addresses must still reach the account ceiling"
    );
    let retry_after: u64 = fresh
        .headers()
        .get(axum::http::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse().ok())
        .expect("Retry-After on the account-wide 429");
    assert!(
        (1..=30).contains(&retry_after),
        "first account-wide backoff is 30 s, got {retry_after}"
    );
}

#[tokio::test]
async fn owner_is_not_locked_out_below_the_account_ceiling() {
    // One client fails until its own backoff engages, and others add failures
    // too, but the account stays under 30: the owner, on their own address,
    // signs in normally.
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    for _ in 0..13 {
        app.state
            .record_login_failure(&admin.username, "198.51.100.1");
    }
    for i in 0..15 {
        app.state
            .record_login_failure(&admin.username, &rotating_client(i + 100));
    }
    assert!(
        app.state
            .login_retry_after(&admin.username, "198.51.100.1")
            .is_some(),
        "the noisy client is in its own backoff"
    );

    let owner = login_from(&app, CLIENT_B, &admin.username, &admin.password).await;
    assert_eq!(
        owner.status(),
        StatusCode::OK,
        "28 failures across clients must not lock the owner out"
    );
}

#[tokio::test]
async fn account_ceiling_counts_across_clients_at_the_state_layer() {
    let app = TestApp::new().await;
    let username = unique("ceiling-user");
    for i in 0..29 {
        app.state
            .record_login_failure(&username, &rotating_client(i));
    }
    assert!(
        app.state
            .login_retry_after(&username, "203.0.113.77")
            .is_none(),
        "29 failures: under the ceiling"
    );
    app.state
        .record_login_failure(&username, &rotating_client(29));
    assert!(
        app.state
            .login_retry_after(&username, "203.0.113.77")
            .is_some(),
        "30 failures across clients: account-wide backoff for every client"
    );
    // Another account is unaffected.
    assert!(app
        .state
        .login_retry_after(&unique("other-user"), "203.0.113.77")
        .is_none());
}
