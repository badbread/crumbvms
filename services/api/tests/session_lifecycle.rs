// SPDX-License-Identifier: AGPL-3.0-or-later

//! Session lifecycle: what happens to a signed-in device when the account
//! behind it changes.
//!
//! A Crumb token can live for years (the mobile "keep me signed in" option), so
//! "the account changed" has to reach tokens that were already handed out. This
//! suite pins that contract end to end, through the real router, the real
//! `AuthUser` extractor and a real Postgres:
//!
//! * removing an account ends its sessions,
//! * setting a new password ends its sessions,
//! * changing its role ends its sessions,
//! * changing only its extra cameras does NOT end its sessions, but the new
//!   camera set is in force on the very next request,
//! * a save that changes nothing signs nobody out,
//! * an admin editing their own account keeps the session they are editing from,
//! * a token with no session id is refused,
//! * and none of the above disturbs the scoped media tokens the media routes
//!   depend on.
//!
//! Harness, database setup and fixtures are shared with `auth_rbac.rs`; see
//! `tests/support/mod.rs`.
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
use chrono::Utc;
use uuid::Uuid;

use support::*;

// ─── local helpers ──────────────────────────────────────────────────────────

/// Build a DELETE request carrying a Bearer token.
fn delete_auth(uri: &str, token: &str) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("DELETE")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(axum::body::Body::empty())
        .unwrap()
}

/// Is this token still a working session? Probes `GET /auth/me`, which every
/// client hits and which takes the plain `AuthUser` extractor.
async fn session_status(app: &TestApp, token: &str) -> StatusCode {
    app.send(get_auth("/auth/me", token)).await.status()
}

/// Assert the token still authenticates.
async fn assert_session_alive(app: &TestApp, token: &str, why: &str) {
    assert_eq!(
        session_status(app, token).await,
        StatusCode::OK,
        "session should still be valid: {why}"
    );
}

/// Assert the token no longer authenticates.
async fn assert_session_dead(app: &TestApp, token: &str, why: &str) {
    assert_eq!(
        session_status(app, token).await,
        StatusCode::UNAUTHORIZED,
        "session should have ended: {why}"
    );
}

/// Mint a scoped media token for `camera` using a full session token.
async fn mint_media_token(app: &TestApp, token: &str, camera: Uuid) -> String {
    let resp = app
        .send(get_auth(&format!("/media-token?camera={camera}"), token))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "media-token mint");
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    v["token"].as_str().expect("token in response").to_owned()
}

// ─── the account is removed ─────────────────────────────────────────────────

#[tokio::test]
async fn removing_a_user_ends_their_sessions() {
    // The gap this closes: `sessions.user_id` is ON DELETE CASCADE, so removing
    // a user made their session rows VANISH rather than be flagged revoked. A
    // "has this jti been revoked" test then answered "no" for a token whose
    // owner no longer existed, and the token kept working until its `exp`,
    // which for a remembered mobile login is years away.
    let app = TestApp::new().await;
    let pool = app.pool().clone();

    let cam = seed_camera(&pool).await;
    let role_id = seed_viewer_role(&pool, &[cam]).await;
    let viewer = seed_viewer_user(&pool, role_id).await;
    let admin = seed_admin(&pool).await;

    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;

    // Baseline: the viewer can reach their camera.
    let ok = app
        .send(get_auth(&format!("/cameras/{cam}/streams"), &viewer_token))
        .await;
    assert_eq!(ok.status(), StatusCode::OK, "viewer reaches their camera");

    let del = app
        .send(delete_auth(
            &format!("/config/users/{}", viewer.user_id),
            &admin_token,
        ))
        .await;
    assert_eq!(del.status(), StatusCode::NO_CONTENT, "user removed");

    // The removed account's token is dead on a scoped route...
    let after = app
        .send(get_auth(&format!("/cameras/{cam}/streams"), &viewer_token))
        .await;
    assert_eq!(
        after.status(),
        StatusCode::UNAUTHORIZED,
        "a removed user's token must not still reach camera data"
    );
    // ...and everywhere else.
    assert_session_dead(&app, &viewer_token, "the account was removed").await;
}

// ─── the credential or the role changes ─────────────────────────────────────

#[tokio::test]
async fn changing_a_password_ends_that_users_sessions() {
    let app = TestApp::new().await;
    let pool = app.pool().clone();

    let cam = seed_camera(&pool).await;
    let role_id = seed_viewer_role(&pool, &[cam]).await;
    let viewer = seed_viewer_user(&pool, role_id).await;
    let admin = seed_admin(&pool).await;

    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;
    assert_session_alive(&app, &viewer_token, "just signed in").await;

    let resp = app
        .send(put_auth_json(
            &format!("/config/users/{}", viewer.user_id),
            &admin_token,
            &serde_json::json!({ "password": "a different long password" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "password updated");

    assert_session_dead(&app, &viewer_token, "the password was changed").await;
    // The account itself still works, with the new credential.
    let fresh = login(&app, &viewer.username, "a different long password").await;
    assert_session_alive(&app, &fresh, "signed in again with the new password").await;
}

#[tokio::test]
async fn changing_a_role_ends_that_users_sessions() {
    let app = TestApp::new().await;
    let pool = app.pool().clone();

    let cam_a = seed_camera(&pool).await;
    let cam_b = seed_camera(&pool).await;
    let role_a = seed_viewer_role(&pool, &[cam_a]).await;
    let role_b = seed_viewer_role(&pool, &[cam_b]).await;
    let viewer = seed_viewer_user(&pool, role_a).await;
    let admin = seed_admin(&pool).await;

    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(put_auth_json(
            &format!("/config/users/{}", viewer.user_id),
            &admin_token,
            &serde_json::json!({ "role_id": role_b, "camera_ids": [] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "role reassigned");

    assert_session_dead(&app, &viewer_token, "the assigned role was changed").await;
}

// ─── only the extra cameras change ──────────────────────────────────────────

#[tokio::test]
async fn changing_extra_cameras_applies_on_the_next_request() {
    // Per-user camera grants used to be baked into the token at login and were
    // only re-read at the next login, so an admin taking a camera away from
    // someone changed nothing for a phone that was already signed in. They are
    // now read from the user row on each request. Because that makes the new
    // set effective immediately, this edit deliberately does NOT sign the user
    // out: they keep working, with the access they are supposed to have.
    let app = TestApp::new().await;
    let pool = app.pool().clone();

    let cam_a = seed_camera(&pool).await;
    let cam_b = seed_camera(&pool).await;
    // The role carries cam_a; cam_b will be granted per-user, then taken back.
    let role_id = seed_viewer_role(&pool, &[cam_a]).await;
    let viewer = seed_viewer_user(&pool, role_id).await;
    let admin = seed_admin(&pool).await;

    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;

    // Before: cam_b is out of scope.
    let denied = app
        .send(get_auth(
            &format!("/cameras/{cam_b}/streams"),
            &viewer_token,
        ))
        .await;
    assert_eq!(
        denied.status(),
        StatusCode::FORBIDDEN,
        "cam_b is not granted yet"
    );

    // Grant cam_b on top of the role, same role, same everything else.
    let resp = app
        .send(put_auth_json(
            &format!("/config/users/{}", viewer.user_id),
            &admin_token,
            &serde_json::json!({ "role_id": role_id, "camera_ids": [cam_b] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "extra camera granted");

    // Same token, no re-login: the grant is live.
    assert_session_alive(
        &app,
        &viewer_token,
        "an extra-cameras edit is not a sign-out",
    )
    .await;
    let granted = app
        .send(get_auth(
            &format!("/cameras/{cam_b}/streams"),
            &viewer_token,
        ))
        .await;
    assert_eq!(
        granted.status(),
        StatusCode::OK,
        "a newly granted camera must be reachable without signing in again"
    );

    // Now take it back. This is the direction that matters: it must bite at
    // once, not at the user's next login.
    let resp = app
        .send(put_auth_json(
            &format!("/config/users/{}", viewer.user_id),
            &admin_token,
            &serde_json::json!({ "role_id": role_id, "camera_ids": [] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "extra camera withdrawn");

    let revoked = app
        .send(get_auth(
            &format!("/cameras/{cam_b}/streams"),
            &viewer_token,
        ))
        .await;
    assert_eq!(
        revoked.status(),
        StatusCode::FORBIDDEN,
        "a withdrawn camera grant must stop working on the next request"
    );
    // The role's own camera is untouched: union semantics are unchanged.
    let still_ok = app
        .send(get_auth(
            &format!("/cameras/{cam_a}/streams"),
            &viewer_token,
        ))
        .await;
    assert_eq!(
        still_ok.status(),
        StatusCode::OK,
        "the role's own cameras must be unaffected"
    );
}

// ─── a save that changes nothing ────────────────────────────────────────────

#[tokio::test]
async fn a_no_op_save_does_not_sign_anyone_out() {
    // The console re-PUTs the whole form on every Save, so "nothing actually
    // changed" is the common case and must be harmless.
    let app = TestApp::new().await;
    let pool = app.pool().clone();

    let cam = seed_camera(&pool).await;
    let role_id = seed_viewer_role(&pool, &[cam]).await;
    let viewer = seed_viewer_user(&pool, role_id).await;
    let admin = seed_admin(&pool).await;

    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(put_auth_json(
            &format!("/config/users/{}", viewer.user_id),
            &admin_token,
            &serde_json::json!({
                "username": viewer.username,
                "role": "viewer",
                "role_id": role_id,
                "camera_ids": [],
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "no-op save accepted");

    assert_session_alive(&app, &viewer_token, "the save changed nothing").await;
}

// ─── an admin editing their own account ─────────────────────────────────────

#[tokio::test]
async fn self_edit_keeps_the_acting_session_and_ends_the_others() {
    // Changing your own password must not eject you from the console mid-edit,
    // but it must still end your OTHER devices.
    let app = TestApp::new().await;
    let pool = app.pool().clone();

    let admin = seed_admin(&pool).await;
    let acting = login(&app, &admin.username, &admin.password).await;
    let other_device = login(&app, &admin.username, &admin.password).await;
    assert_ne!(acting, other_device, "two distinct sessions");

    let resp = app
        .send(put_auth_json(
            &format!("/config/users/{}", admin.user_id),
            &acting,
            &serde_json::json!({ "password": "my new long admin password" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "self password change");

    assert_session_alive(&app, &acting, "the admin edited their own account").await;
    assert_session_dead(&app, &other_device, "another device of the same admin").await;
}

// ─── a token with no session id ─────────────────────────────────────────────

#[tokio::test]
async fn a_token_without_a_session_id_is_rejected() {
    // Every token any released client has ever held carries a `jti` (the
    // sessions table predates the first public release), so a token without one
    // is either forged or from a pre-release build. It could never be signed
    // out, so it is refused.
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    let now = Utc::now();
    let claims = support::dto::Claims {
        sub: admin.user_id.to_string(),
        exp: u64::try_from((now + chrono::Duration::hours(1)).timestamp()).unwrap(),
        iat: u64::try_from(now.timestamp()).unwrap(),
        role: "admin".to_owned(),
        camera_ids: vec![],
        role_id: admin.role_id.map(|r| r.to_string()),
        jti: None,
    };
    let sessionless = jsonwebtoken::encode(
        &jsonwebtoken::Header::default(),
        &claims,
        app.state.jwt_encoding_key(),
    )
    .expect("encode session-less test token");

    let resp = app.send(get_auth("/auth/me", &sessionless)).await;
    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "a signed token with no session id must not authenticate"
    );
}

#[tokio::test]
async fn a_token_whose_session_row_never_existed_is_rejected() {
    // Signature and expiry are valid, the user exists, the jti is simply not a
    // session. Proves the check is positive (the row must be there), not merely
    // "is this jti on the revoked list".
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    let now = Utc::now();
    let claims = support::dto::Claims {
        sub: admin.user_id.to_string(),
        exp: u64::try_from((now + chrono::Duration::hours(1)).timestamp()).unwrap(),
        iat: u64::try_from(now.timestamp()).unwrap(),
        role: "admin".to_owned(),
        camera_ids: vec![],
        role_id: admin.role_id.map(|r| r.to_string()),
        jti: Some(Uuid::new_v4().to_string()),
    };
    let orphan = jsonwebtoken::encode(
        &jsonwebtoken::Header::default(),
        &claims,
        app.state.jwt_encoding_key(),
    )
    .expect("encode orphan-session test token");

    let resp = app.send(get_auth("/auth/me", &orphan)).await;
    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "a token whose session row does not exist must not authenticate"
    );
}

// ─── scoped media tokens are untouched ──────────────────────────────────────

#[tokio::test]
async fn scoped_media_tokens_still_work() {
    // Media tokens are a different token type with no session row of their own
    // (they self-expire in minutes). The session checks must not reach them, or
    // every thumbnail, clip and segment a browser loads with `?token=` breaks.
    let app = TestApp::new().await;
    let pool = app.pool().clone();

    let storage_root = TempDir::new("crumb-test-sessions");
    let storage_id = seed_storage(&pool, storage_root.path().to_str().unwrap()).await;
    let cam = seed_camera(&pool).await;
    let seg = seed_segment_with_file(&pool, cam, storage_id, storage_root.path()).await;

    let role_id = seed_viewer_role(&pool, &[cam]).await;
    let viewer = seed_viewer_user(&pool, role_id).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let media = mint_media_token(&app, &token, cam).await;
    let resp = app
        .send(get(&format!("/segments/{seg}?token={media}")))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "a scoped media token must still serve its camera's segment bytes"
    );
}

/// Minimal temp-dir helper (this crate has no `tempfile` dependency, and adding
/// one for a test is out of scope). Removes the directory on drop, best effort.
struct TempDir(std::path::PathBuf);

impl TempDir {
    fn new(prefix: &str) -> Self {
        let mut p = std::env::temp_dir();
        p.push(format!("{prefix}-{}", Uuid::new_v4().simple()));
        std::fs::create_dir_all(&p).expect("create temp storage dir");
        Self(p)
    }
    fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
