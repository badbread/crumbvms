// SPDX-License-Identifier: AGPL-3.0-or-later

//! Auth / JWT / RBAC camera-scoping integration suite (P0-AUTHTEST).
//!
//! Background: `services/api` had **zero** tests exercising authentication or
//! per-camera authorization before this suite — everything else in the repo
//! (the recorder's 209 tests) is pure logic, no auth. For a self-hosted
//! camera-recording product whose entire pitch is privacy, the code that
//! decides "can this viewer see that camera's video" is the single most
//! important thing to test, and it had nothing.
//!
//! These are REAL integration tests: they run the actual `auth::login`
//! handler (Argon2id verify), the actual `AuthUser`/`AdminUser` axum
//! extractors (JWT decode + role/camera resolution), and the actual
//! `assert_camera_access`/`require_*`/capability gates inside the real
//! `playback.rs` / `clips.rs` / `export.rs` / `events.rs` / `config_routes.rs`
//! handlers — against a real Postgres. See `tests/support/mod.rs` for how the
//! harness re-includes the crate's own (private, bin-only) source modules to
//! make this possible without touching any production file.
//!
//! # Running locally
//!
//! ```sh
//! docker run --rm -d --name crumb-test-pg \
//!   -e POSTGRES_USER=crumb -e POSTGRES_PASSWORD=change-me -e POSTGRES_DB=crumb \
//!   -p 5432:5432 postgres:16-alpine
//! cargo test -p crumb-api --test auth_rbac
//! ```
//!
//! # Lint parity with `main.rs`
//!
//! This test binary's crate root re-includes the same `src/*.rs` files as
//! `main.rs` (see `tests/support/mod.rs`), but crate-level `#![allow(...)]`
//! attributes are NOT inherited from `main.rs` — they belong to that binary's
//! own crate root, not to the modules themselves. Mirror the same curated
//! clippy allowances `main.rs` declares (`services/api/src/main.rs`) here so
//! `cargo clippy --all-targets -D warnings` evaluates the re-included
//! production code under the SAME policy as the real binary, rather than a
//! stricter one purely as an artifact of this test harness's structure.
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

use axum::body::to_bytes;
use axum::http::StatusCode;
use chrono::Utc;
use uuid::Uuid;

use support::*;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
}

// ─── login ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn login_success_returns_token() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    let resp = app
        .send(
            axum::http::Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    login_body(&admin.username, &admin.password).to_string(),
                ))
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert!(v["token"].as_str().is_some_and(|t| !t.is_empty()));
    assert!(v["expires_at"].is_string());
}

#[tokio::test]
async fn login_wrong_password_is_401() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    let resp = app
        .send(
            axum::http::Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    login_body(&admin.username, "definitely wrong password").to_string(),
                ))
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

/// Fire one login attempt and return the raw response (status + headers), so a
/// test can assert on the 429 + `Retry-After` backoff (issue #127) rather than
/// the `login()` helper which panics on non-2xx.
async fn login_attempt(
    app: &TestApp,
    username: &str,
    password: &str,
) -> axum::http::Response<axum::body::Body> {
    app.send(
        axum::http::Request::builder()
            .method("POST")
            .uri("/auth/login")
            .header("content-type", "application/json")
            .body(axum::body::Body::from(
                login_body(username, password).to_string(),
            ))
            .unwrap(),
    )
    .await
}

#[tokio::test]
async fn login_backoff_blocks_after_repeated_failures() {
    // Issue #127: consecutive failed logins for one username must trip a
    // per-username backoff — 429 + Retry-After — on top of the shared per-IP
    // bucket (which this test router doesn't mount, so 429 here can only come
    // from the backoff).
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    // The threshold is 5 (state::LOGIN_FAIL_THRESHOLD): the first 5 wrong-
    // password attempts are plain 401s.
    for i in 0..5 {
        let resp = login_attempt(&app, &admin.username, "wrong-password").await;
        assert_eq!(
            resp.status(),
            StatusCode::UNAUTHORIZED,
            "attempt {i} should be a plain 401 (still under threshold)"
        );
    }

    // The 6th attempt is now blocked: 429 with a Retry-After header, WITHOUT
    // reaching the credential check.
    let blocked = login_attempt(&app, &admin.username, "wrong-password").await;
    assert_eq!(blocked.status(), StatusCode::TOO_MANY_REQUESTS);
    let retry_after = blocked
        .headers()
        .get(axum::http::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
        .expect("429 must carry a numeric Retry-After header");
    assert!(retry_after >= 1, "Retry-After must be a positive backoff");

    // Even the CORRECT password is rejected while blocked (the limiter runs
    // before verification) — proving it doesn't sleep-and-verify.
    let blocked_correct = login_attempt(&app, &admin.username, &admin.password).await;
    assert_eq!(blocked_correct.status(), StatusCode::TOO_MANY_REQUESTS);

    // A DIFFERENT username is unaffected — the backoff is per-username, not a
    // global brake (and unknown users get the same 401 shape, no oracle).
    let other = login_attempt(&app, &unique("other-user"), "whatever").await;
    assert_eq!(other.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn login_backoff_resets_on_success() {
    // A successful login must clear the failure counter so a legitimate user who
    // eventually types the right password isn't punished for earlier typos.
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    // 4 failures — one shy of the threshold, so no block yet.
    for _ in 0..4 {
        let resp = login_attempt(&app, &admin.username, "wrong-password").await;
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    // A correct login succeeds and resets the counter.
    let ok = login_attempt(&app, &admin.username, &admin.password).await;
    assert_eq!(ok.status(), StatusCode::OK);

    // Because the counter reset, four more failures again stay 401 (had the
    // count NOT reset, the 2nd of these — the 6th cumulative failure — would be
    // a 429).
    for i in 0..4 {
        let resp = login_attempt(&app, &admin.username, "wrong-password").await;
        assert_eq!(
            resp.status(),
            StatusCode::UNAUTHORIZED,
            "post-reset attempt {i} should be 401, not blocked"
        );
    }
}

#[tokio::test]
async fn login_unknown_user_is_401_with_same_message_as_wrong_password() {
    // Uniform-401 invariant (auth.rs's own stated design: "no oracle" — the
    // response must not let a caller distinguish "user doesn't exist" from
    // "user exists, password wrong").
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    let unknown_resp = app
        .send(
            axum::http::Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    login_body(&unique("nobody"), "whatever-password").to_string(),
                ))
                .unwrap(),
        )
        .await;
    assert_eq!(unknown_resp.status(), StatusCode::UNAUTHORIZED);
    let unknown_body = body_json(unknown_resp).await;

    let wrongpw_resp = app
        .send(
            axum::http::Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    login_body(&admin.username, "whatever-password").to_string(),
                ))
                .unwrap(),
        )
        .await;
    assert_eq!(wrongpw_resp.status(), StatusCode::UNAUTHORIZED);
    let wrongpw_body = body_json(wrongpw_resp).await;

    assert_eq!(
        unknown_body["message"], wrongpw_body["message"],
        "unknown-user and wrong-password responses must be identical (no username-enumeration oracle)"
    );
}

#[tokio::test]
async fn login_empty_username_or_password_is_400() {
    let app = TestApp::new().await;

    let resp = app
        .send(
            axum::http::Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::json!({"username": "", "password": "x"}).to_string(),
                ))
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let resp = app
        .send(
            axum::http::Request::builder()
                .method("POST")
                .uri("/auth/login")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::json!({"username": "someone", "password": ""}).to_string(),
                ))
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ─── JWT validity ───────────────────────────────────────────────────────────

#[tokio::test]
async fn valid_token_is_accepted_on_auth_me() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app.send(get_auth("/auth/me", &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["username"], admin.username);
    assert_eq!(v["is_admin"], true);
}

#[tokio::test]
async fn missing_token_is_401() {
    let app = TestApp::new().await;
    let resp = app.send(get("/auth/me")).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn garbage_token_is_401() {
    let app = TestApp::new().await;
    let resp = app.send(get_auth("/auth/me", "not-a-jwt-at-all")).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn wrong_signature_token_is_401() {
    // A syntactically valid JWT (three base64url segments) signed with a
    // DIFFERENT key must be rejected — proves the API actually verifies the
    // HMAC signature rather than just parsing the payload.
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let real_token = login(&app, &admin.username, &admin.password).await;

    // Flip a character in the signature segment (last `.`-delimited part).
    let mut parts: Vec<&str> = real_token.split('.').collect();
    assert_eq!(parts.len(), 3, "JWT must have header.payload.signature");
    let sig = parts[2].to_owned();
    let mangled_char = if sig.starts_with('A') { 'B' } else { 'A' };
    let mangled_sig = format!("{mangled_char}{}", &sig[1..]);
    parts[2] = &mangled_sig;
    let tampered = parts.join(".");

    let resp = app.send(get_auth("/auth/me", &tampered)).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn expired_token_is_401() {
    // Mint a token via the real /auth/login path against a JWT_EXPIRY_SECONDS
    // of 0 by hand-crafting one with the auth module's own Claims + signing
    // key, so we exercise the REAL exp-validation branch in auth_mw's
    // extractor (`validation.validate_exp = true`) rather than special-casing
    // test-only logic. We reach into the (test-included) auth module's
    // signing key via AppState, matching exactly how auth.rs::mint_token
    // would build an already-expired token.
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    let now = Utc::now();
    let claims = support::dto::Claims {
        sub: admin.user_id.to_string(),
        // Already expired 1 hour ago.
        exp: u64::try_from((now - chrono::Duration::hours(1)).timestamp()).unwrap(),
        iat: u64::try_from((now - chrono::Duration::hours(2)).timestamp()).unwrap(),
        role: "admin".to_owned(),
        camera_ids: vec![],
        role_id: admin.role_id.map(|r| r.to_string()),
        jti: None,
    };
    let expired_token = jsonwebtoken::encode(
        &jsonwebtoken::Header::default(),
        &claims,
        app.state.jwt_encoding_key(),
    )
    .expect("encode expired test token");

    let resp = app.send(get_auth("/auth/me", &expired_token)).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ─── RBAC camera scoping — the crown jewels ────────────────────────────────
//
// A viewer scoped to camera A must get 403 reaching camera B's streams,
// playback, clips, export, and event snapshot — and 200 (or at least PAST
// the auth/scope gate) for camera A.

struct RbacFixture {
    app: TestApp,
    storage_root: tempdir_shim::TempDir,
    cam_a: Uuid,
    cam_b: Uuid,
    viewer_token: String,
    admin_token: String,
}

/// Minimal `tempfile`-free temp-dir helper: `crumb-api` doesn't depend on the
/// `tempfile` crate, and adding a new dependency is out of scope for a
/// tests-only change. Creates a unique directory under the OS temp dir and
/// removes it (best-effort) on drop.
mod tempdir_shim {
    pub struct TempDir(std::path::PathBuf);
    impl TempDir {
        pub fn new(prefix: &str) -> Self {
            let mut p = std::env::temp_dir();
            p.push(format!("{prefix}-{}", uuid::Uuid::new_v4().simple()));
            std::fs::create_dir_all(&p).expect("create temp storage dir");
            Self(p)
        }
        pub fn path(&self) -> &std::path::Path {
            &self.0
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

async fn build_rbac_fixture() -> RbacFixture {
    let app = TestApp::new().await;
    let pool = app.pool().clone();

    let storage_root = tempdir_shim::TempDir::new("crumb-test-storage");
    let storage_id = seed_storage(&pool, storage_root.path().to_str().unwrap()).await;
    let _ = storage_id; // used below per-test where a segment is seeded

    let cam_a = seed_camera(&pool).await;
    let cam_b = seed_camera(&pool).await;

    let viewer = seed_viewer(&pool, &[cam_a]).await;
    let admin = seed_admin(&pool).await;

    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;

    RbacFixture {
        app,
        storage_root,
        cam_a,
        cam_b,
        viewer_token,
        admin_token,
    }
}

#[tokio::test]
async fn viewer_can_reach_own_camera_streams_but_not_others() {
    let fx = build_rbac_fixture().await;

    let ok = fx
        .app
        .send(get_auth(
            &format!("/cameras/{}/streams", fx.cam_a),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(
        ok.status(),
        StatusCode::OK,
        "viewer must reach their OWN camera's /streams"
    );

    let denied = fx
        .app
        .send(get_auth(
            &format!("/cameras/{}/streams", fx.cam_b),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(
        denied.status(),
        StatusCode::FORBIDDEN,
        "viewer must be REFUSED another camera's /streams (RBAC scoping regression)"
    );
}

#[tokio::test]
async fn viewer_can_play_own_camera_but_not_others() {
    let fx = build_rbac_fixture().await;
    // RFC3339 embeds a literal `+` (UTC offset) which MUST be percent-encoded
    // in a query string, else it decodes as a space and axum's `Query`
    // extractor 400s before the handler (and its scope check) ever runs.
    let ts = Utc::now().to_rfc3339().replace('+', "%2B");

    // /play/{camera_id}?ts=... — own camera: past the scope gate. No segment
    // exists yet for cam_a in this fixture, so 404 ("no segment") is the
    // correct, SCOPE-PASSED outcome; the key assertion is "not 403".
    let own = fx
        .app
        .send(get_auth(
            &format!("/play/{}?ts={ts}", fx.cam_a),
            &fx.viewer_token,
        ))
        .await;
    assert_ne!(
        own.status(),
        StatusCode::FORBIDDEN,
        "viewer must not be scope-denied on their OWN camera's /play"
    );

    let other = fx
        .app
        .send(get_auth(
            &format!("/play/{}?ts={ts}", fx.cam_b),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(
        other.status(),
        StatusCode::FORBIDDEN,
        "viewer must be REFUSED another camera's /play"
    );
}

#[tokio::test]
async fn viewer_can_fetch_own_segment_but_not_others() {
    let fx = build_rbac_fixture().await;
    let pool = fx.app.pool().clone();
    let storage_id = seed_storage(&pool, fx.storage_root.path().to_str().unwrap()).await;

    let seg_a = seed_segment_with_file(&pool, fx.cam_a, storage_id, fx.storage_root.path()).await;
    let seg_b = seed_segment_with_file(&pool, fx.cam_b, storage_id, fx.storage_root.path()).await;

    let own = fx
        .app
        .send(get_auth(&format!("/segments/{seg_a}"), &fx.viewer_token))
        .await;
    assert_eq!(
        own.status(),
        StatusCode::OK,
        "viewer must be able to fetch their OWN camera's segment bytes"
    );
    let bytes = to_bytes(own.into_body(), usize::MAX).await.unwrap();
    assert_eq!(&bytes[..], b"fake mp4 bytes for range-serving test");

    let other = fx
        .app
        .send(get_auth(&format!("/segments/{seg_b}"), &fx.viewer_token))
        .await;
    assert_eq!(
        other.status(),
        StatusCode::FORBIDDEN,
        "viewer must be REFUSED another camera's segment bytes — this is the core \
         privacy-enforcement path (assert_camera_access on /segments/{{id}})"
    );

    // Admin has no scope restriction: must reach both.
    let admin_a = fx
        .app
        .send(get_auth(&format!("/segments/{seg_a}"), &fx.admin_token))
        .await;
    assert_eq!(admin_a.status(), StatusCode::OK);
    let admin_b = fx
        .app
        .send(get_auth(&format!("/segments/{seg_b}"), &fx.admin_token))
        .await;
    assert_eq!(admin_b.status(), StatusCode::OK);
}

#[tokio::test]
async fn viewer_clips_media_scoped_to_own_camera() {
    // clips.rs's media handlers now use `assert_camera_access` → 403 (Forbidden)
    // when the camera is out of scope, matching playback.rs / events.rs (the
    // former 404 "clip not found" was the lone outlier; standardized in the RBAC
    // contract-consistency pass). A genuinely missing clip / no-footage window is
    // still a 404 from a DIFFERENT path, so this test asserts BOTH the status AND
    // that the own-camera path gets past the scope gate to the footage-miss 404.
    let fx = build_rbac_fixture().await;

    // A motion-derived clip id: "m:<camera>:<start_ms>:<end_ms>". No segment
    // exists for either camera in this fixture — that's fine, since we assert
    // on the specific 404 reason, not merely "is it 404".
    let start = Utc::now() - chrono::Duration::seconds(10);
    let end = Utc::now();
    let clip_id_a = format!(
        "m:{}:{}:{}",
        fx.cam_a,
        start.timestamp_millis(),
        end.timestamp_millis()
    );
    let clip_id_b = format!(
        "m:{}:{}:{}",
        fx.cam_b,
        start.timestamp_millis(),
        end.timestamp_millis()
    );

    let other = fx
        .app
        .send(get_auth(
            &format!("/clip/{clip_id_b}/thumbnail.jpg"),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(
        other.status(),
        StatusCode::FORBIDDEN,
        "viewer must be denied another camera's clip with 403 (assert_camera_access), \
         consistent with playback/events — not the old 404"
    );
    let other_body = body_json(other).await;
    assert_eq!(
        other_body["message"],
        format!("camera {} is not in your assigned camera list", fx.cam_b),
        "the 403 must be the SCOPE-denial message specifically (got: {other_body:?})"
    );

    // Own camera: must get PAST the scope gate. There's no footage seeded, so
    // this legitimately 404s too — but it MUST be the footage-miss message,
    // never the scope-denial message.
    let own = fx
        .app
        .send(get_auth(
            &format!("/clip/{clip_id_a}/thumbnail.jpg"),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(own.status(), StatusCode::NOT_FOUND);
    let own_body = body_json(own).await;
    assert_eq!(
        own_body["message"], "no footage for this clip window",
        "viewer must NOT be scope-denied on their OWN camera's clip \
         (got the scope-denial message instead of the footage-miss message: {own_body:?})"
    );
}

#[tokio::test]
async fn viewer_export_batch_scoped_to_own_camera() {
    let fx = build_rbac_fixture().await;

    let start = Utc::now() - chrono::Duration::minutes(5);
    let end = Utc::now();
    let body = serde_json::json!({
        "items": [{ "camera_id": fx.cam_b, "start": start, "end": end }]
    });
    let resp = fx
        .app
        .send(post_auth_json("/export/batch", &fx.viewer_token, &body))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "batch export must reject a clip on a camera outside the viewer's scope"
    );

    let body_own = serde_json::json!({
        "items": [{ "camera_id": fx.cam_a, "start": start, "end": end }]
    });
    let resp_own = fx
        .app
        .send(post_auth_json("/export/batch", &fx.viewer_token, &body_own))
        .await;
    assert_ne!(
        resp_own.status(),
        StatusCode::FORBIDDEN,
        "batch export of the viewer's OWN camera must not be scope-denied (got {})",
        resp_own.status()
    );
}

#[tokio::test]
async fn viewer_single_export_is_all_or_nothing() {
    // create_export (POST /export, the single-range form) is now ALL-OR-NOTHING:
    // a request naming ANY out-of-scope camera is 403'd outright — it no longer
    // silently narrows `camera_ids` to the in-scope subset. This matches
    // /export/batch and the archive download (RBAC contract-consistency pass), so
    // a caller never gets a surprise partial export of only some requested
    // cameras.
    let fx = build_rbac_fixture().await;
    let start = Utc::now() - chrono::Duration::minutes(5);
    let end = Utc::now();

    // Entirely out-of-scope request → 403.
    let all_denied = fx
        .app
        .send(post_auth_json(
            "/export",
            &fx.viewer_token,
            &serde_json::json!({
                "camera_ids": [fx.cam_b],
                "start": start,
                "end": end,
            }),
        ))
        .await;
    assert_eq!(all_denied.status(), StatusCode::FORBIDDEN);

    // Mixed request (one in scope, one not) → 403, NOT a silently-narrowed 202.
    let mixed = fx
        .app
        .send(post_auth_json(
            "/export",
            &fx.viewer_token,
            &serde_json::json!({
                "camera_ids": [fx.cam_a, fx.cam_b],
                "start": start,
                "end": end,
            }),
        ))
        .await;
    assert_eq!(
        mixed.status(),
        StatusCode::FORBIDDEN,
        "a request naming BOTH an in-scope and out-of-scope camera must be REJECTED \
         (all-or-nothing), not silently narrowed to the in-scope subset"
    );
    let body = body_json(mixed).await;
    assert_eq!(
        body["message"],
        format!("camera {} is not in your assigned camera list", fx.cam_b),
        "the 403 must name the specific out-of-scope camera (got: {body:?})"
    );

    // Fully in-scope request → gets past the scope gate (not 403).
    let own = fx
        .app
        .send(post_auth_json(
            "/export",
            &fx.viewer_token,
            &serde_json::json!({
                "camera_ids": [fx.cam_a],
                "start": start,
                "end": end,
            }),
        ))
        .await;
    assert_ne!(
        own.status(),
        StatusCode::FORBIDDEN,
        "a request naming ONLY the viewer's own camera must not be scope-denied (got {})",
        own.status()
    );
}

#[tokio::test]
async fn viewer_event_snapshot_scoped_to_own_camera() {
    let fx = build_rbac_fixture().await;
    let pool = fx.app.pool().clone();

    let event_a = seed_event(&pool, fx.cam_a).await;
    let event_b = seed_event(&pool, fx.cam_b).await;

    let own = fx
        .app
        .send(get_auth(
            &format!("/events/{event_a}/snapshot"),
            &fx.viewer_token,
        ))
        .await;
    assert_ne!(
        own.status(),
        StatusCode::FORBIDDEN,
        "viewer must not be scope-denied fetching their OWN camera's event snapshot \
         (expect a 502 from the unreachable fake snapshot URL, NOT a 403)"
    );

    let other = fx
        .app
        .send(get_auth(
            &format!("/events/{event_b}/snapshot"),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(
        other.status(),
        StatusCode::FORBIDDEN,
        "viewer must be REFUSED another camera's event snapshot"
    );
}

#[tokio::test]
async fn viewer_motion_grid_scoped_to_own_camera() {
    let fx = build_rbac_fixture().await;

    let own = fx
        .app
        .send(get_auth(
            &format!("/cameras/{}/motion-grid", fx.cam_a),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(own.status(), StatusCode::OK);

    let other = fx
        .app
        .send(get_auth(
            &format!("/cameras/{}/motion-grid", fx.cam_b),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(other.status(), StatusCode::FORBIDDEN);
}

// ─── admin-only endpoints ───────────────────────────────────────────────────

#[tokio::test]
async fn non_admin_hitting_config_routes_gets_403() {
    let fx = build_rbac_fixture().await;

    let resp = fx
        .app
        .send(get_auth("/config/cameras", &fx.viewer_token))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "a viewer must be refused ANY /config/* route (admin-only gate via AdminUser)"
    );

    let resp = fx
        .app
        .send(get_auth("/config/roles", &fx.viewer_token))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    let resp = fx
        .app
        .send(get_auth("/config/users", &fx.viewer_token))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn admin_can_reach_config_routes() {
    let fx = build_rbac_fixture().await;

    let resp = fx
        .app
        .send(get_auth("/config/cameras", &fx.admin_token))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = fx
        .app
        .send(get_auth("/config/roles", &fx.admin_token))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn unauthenticated_config_request_is_401_not_403() {
    // No token at all must be 401 (not authenticated), distinct from 403
    // (authenticated but not permitted) — AdminUser's extractor delegates to
    // AuthUser first, which is where the 401 comes from.
    let app = TestApp::new().await;
    let resp = app.send(get("/config/cameras")).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ─── query-param token fallback (media <video>/<img> auth path) ────────────

#[tokio::test]
async fn query_param_media_token_is_scope_checked_and_full_jwt_is_rejected() {
    let fx = build_rbac_fixture().await;
    let pool = fx.app.pool().clone();
    let storage_id = seed_storage(&pool, fx.storage_root.path().to_str().unwrap()).await;
    let seg_a = seed_segment_with_file(&pool, fx.cam_a, storage_id, fx.storage_root.path()).await;
    let seg_b = seed_segment_with_file(&pool, fx.cam_b, storage_id, fx.storage_root.path()).await;

    // A `<video src="/segments/{id}?token=...">` can't set an Authorization
    // header, so it uses a SCOPED media token (GET /media-token) — never the
    // full login JWT (audit 2026-07-05 #2). Mint one scoped to cam_a.
    let media_a = mint_media_token(&fx.app, &fx.viewer_token, fx.cam_a).await;

    // Own camera → OK.
    let own = fx
        .app
        .send(get(&format!("/segments/{seg_a}?token={media_a}")))
        .await;
    assert_eq!(own.status(), StatusCode::OK);

    // Another camera → the media token is scoped to cam_a, so cam_b's segment is
    // FORBIDDEN: the ?token= path enforces the same scoping as the header path.
    let other = fx
        .app
        .send(get(&format!("/segments/{seg_b}?token={media_a}")))
        .await;
    assert_eq!(
        other.status(),
        StatusCode::FORBIDDEN,
        "a scoped media token must enforce the same camera scoping as the header path"
    );

    // Fail-closed: a FULL login JWT via ?token= on a media route is now REJECTED —
    // a login credential in a URL can leak into proxy/access logs and browser
    // history. The supported ?token= credential is a scoped media token.
    let full_jwt = fx
        .app
        .send(get(&format!("/segments/{seg_a}?token={}", fx.viewer_token)))
        .await;
    assert_eq!(
        full_jwt.status(),
        StatusCode::UNAUTHORIZED,
        "a full login JWT via ?token= must be rejected on a fail-closed media route"
    );
}

#[tokio::test]
async fn low_mp4_variant_enforces_camera_scope_like_segments() {
    // The on-demand low-bitrate variant `/segments/{id}/low.mp4` is a NEW
    // authenticated media endpoint (golden rule 1) and must enforce exactly the
    // same camera scoping as its byte-transparent sibling `/segments/{id}`. We
    // assert the auth FENCE only (403 cross-camera, 401 full-JWT) — both are
    // decided before any transcode, so this test needs no ffmpeg.
    let fx = build_rbac_fixture().await;
    let pool = fx.app.pool().clone();
    let storage_id = seed_storage(&pool, fx.storage_root.path().to_str().unwrap()).await;
    let seg_b = seed_segment_with_file(&pool, fx.cam_b, storage_id, fx.storage_root.path()).await;

    // A media token scoped to cam_a must NOT unlock cam_b's low variant.
    let media_a = mint_media_token(&fx.app, &fx.viewer_token, fx.cam_a).await;
    let other = fx
        .app
        .send(get(&format!("/segments/{seg_b}/low.mp4?token={media_a}")))
        .await;
    assert_eq!(
        other.status(),
        StatusCode::FORBIDDEN,
        "low.mp4 must enforce the same per-camera scoping as /segments/{{id}}"
    );

    // A full login JWT via ?token= must be rejected on this fail-closed media route.
    let full_jwt = fx
        .app
        .send(get(&format!(
            "/segments/{seg_b}/low.mp4?token={}",
            fx.viewer_token
        )))
        .await;
    assert_eq!(
        full_jwt.status(),
        StatusCode::UNAUTHORIZED,
        "a full login JWT via ?token= must be rejected on the low.mp4 media route"
    );
}

// The camera snapshot route is now FAIL-CLOSED (audit 2026-07-05 #2): the web
// console (admin.html) mints a scoped media token like every other client, so a
// full login JWT via ?token= is rejected here — while a scoped media token still
// passes (it then 502s on the unreachable go2rtc in tests, proving auth passed).
#[tokio::test]
async fn camera_frame_route_rejects_full_jwt_but_accepts_scoped_token() {
    let fx = build_rbac_fixture().await;

    // Full login JWT via ?token= → rejected.
    let full = fx
        .app
        .send(get(&format!(
            "/cameras/{}/frame.jpg?token={}",
            fx.cam_a, fx.viewer_token
        )))
        .await;
    assert_eq!(
        full.status(),
        StatusCode::UNAUTHORIZED,
        "a full login JWT via ?token= must be rejected on the fail-closed snapshot route"
    );

    // Scoped media token for cam_a → auth passes (only go2rtc reachability fails).
    let media = mint_media_token(&fx.app, &fx.viewer_token, fx.cam_a).await;
    let scoped = fx
        .app
        .send(get(&format!(
            "/cameras/{}/frame.jpg?token={media}",
            fx.cam_a
        )))
        .await;
    assert_ne!(
        scoped.status(),
        StatusCode::UNAUTHORIZED,
        "a scoped media token must pass auth on the snapshot route"
    );
    assert_ne!(scoped.status(), StatusCode::FORBIDDEN);
}

// ─── crumb-alpr plate crop via scoped media token (regression: #364) ──────────
//
// The Android / desktop / iOS clients render a license-plate crop with an
// `<img>`-style request to GET /events/{id}/snapshot carrying a *scoped media
// token* (`?token=`), never the bearer JWT — an image request can't set an
// Authorization header. That snapshot route falls back to the linked
// plate_read's stored `crop` bytes (the crumb-alpr external-engine path) and
// gates that fallback behind the `view_plates` capability.
//
// Regression #364 (media tokens hard-coded `view_plates=false`): every
// crumb-alpr crop came back 403 through the media-token path and rendered as a
// black tile on the clients — even for a viewer who DID hold `view_plates`.
// iPhone was unaffected only because it happened to still hold a pre-regression
// token. These two tests pin the contract end to end: mint a REAL media token
// and prove the crop is served (200) when the minter holds `view_plates`, and
// refused (403) when it does not — so the capability can never again be dropped
// silently on the mint→reconstruct round-trip.

/// Insert a crumb-alpr event with a NULL `snapshot_url` (so `get_event_snapshot`
/// takes the crop-fallback branch, not the Frigate proxy path) linked to a
/// `plate_reads` row carrying `crop` bytes. Returns the event id.
async fn seed_alpr_crop_event(app: &TestApp, camera_id: Uuid, crop: &[u8]) -> Uuid {
    let now = Utc::now();
    let event_id: Uuid = {
        let client = app.pool().get().await.expect("pool.get (alpr event)");
        client
            .query_one(
                "INSERT INTO events (camera_id, ts, label, score, thumb_path, snapshot_url)
                 VALUES ($1, $2, 'car', 0.9, NULL, NULL) RETURNING id",
                &[&camera_id, &now],
            )
            .await
            .expect("insert crumb-alpr event")
            .get("id")
    };

    crumb_common::db::upsert_plate_read(
        app.pool(),
        &crumb_common::db::UpsertPlateReadParams {
            camera_id,
            ts: now,
            plate: crumb_common::db::normalize_plate("ALPR123"),
            plate_raw: Some("ALPR123".to_owned()),
            confidence: Some(0.95),
            source_id: "crumb-alpr".to_owned(),
            provider_event_id: Some(format!("alpr-{event_id}")),
            event_id: Some(event_id),
            snapshot_url: None,
            bbox: None,
            crop: Some(crop.to_vec()),
            raw: serde_json::json!({}),
        },
    )
    .await
    .expect("seed crumb-alpr plate_read");

    event_id
}

/// Seed a viewer whose role lacks `view_plates` (but is otherwise a normal
/// playback viewer) granted the given cameras.
async fn seed_viewer_no_plates(pool: &deadpool_postgres::Pool, cameras: &[Uuid]) -> SeededUser {
    use crumb_common::types::{BookmarkScope, Capabilities};
    let caps = Capabilities {
        export: false,
        playback: true,
        clips: true,
        ptz: false,
        bookmarks: BookmarkScope::Own,
        manage_views: true,
        view_plates: false,
    };
    let role = crumb_common::db::create_role(pool, &unique("noplates-role"), &caps, cameras)
        .await
        .expect("create_role (no view_plates)");
    seed_viewer_user(pool, role.id).await
}

#[tokio::test]
async fn crumb_alpr_crop_served_via_media_token_when_view_plates_held() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;

    // JPEG SOI + APP0 marker bytes; the handler serves these verbatim.
    let crop = vec![0xFFu8, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
    let event_id = seed_alpr_crop_event(&app, cam, &crop).await;

    // seed_viewer grants view_plates, so the minted media token must carry it.
    let viewer = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;
    let media = mint_media_token(&app, &token, cam).await;

    let resp = app
        .send(get(&format!("/events/{event_id}/snapshot?token={media}")))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "a media token minted by a view_plates holder must serve the crumb-alpr crop \
         (regression #364: it used to 403 because the token dropped view_plates)"
    );
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    assert_eq!(
        bytes.as_ref(),
        crop.as_slice(),
        "the served body must be the stored crop bytes, unmodified"
    );
}

#[tokio::test]
async fn crumb_alpr_crop_refused_via_media_token_without_view_plates() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;

    let crop = vec![0xFFu8, 0xD8, 0xFF, 0xE0];
    let event_id = seed_alpr_crop_event(&app, cam, &crop).await;

    // Viewer WITHOUT view_plates → the media token must not carry it, so the
    // crop fallback stays gated (the token can't amplify past its minter).
    let viewer = seed_viewer_no_plates(app.pool(), &[cam]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;
    let media = mint_media_token(&app, &token, cam).await;

    let resp = app
        .send(get(&format!("/events/{event_id}/snapshot?token={media}")))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "a media token minted without view_plates must NOT unlock the crumb-alpr crop"
    );
}

// ─── revocable sessions (P0-SESSIONS) ──────────────────────────────────────────

/// Read the caller's session list and return the jti flagged `is_current`.
async fn current_session_jti(app: &TestApp, token: &str) -> Uuid {
    let resp = app.send(get_auth("/auth/sessions", token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let arr = v.as_array().expect("sessions array");
    let current = arr
        .iter()
        .find(|s| s["is_current"] == serde_json::Value::Bool(true))
        .expect("exactly one current session in the list");
    current["jti"]
        .as_str()
        .expect("jti string")
        .parse::<Uuid>()
        .expect("jti is a uuid")
}

#[tokio::test]
async fn login_creates_a_listable_current_session() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app.send(get_auth("/auth/sessions", &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let arr = v.as_array().expect("sessions array");
    assert_eq!(arr.len(), 1, "one login ⇒ exactly one session");
    assert_eq!(
        arr[0]["is_current"],
        serde_json::Value::Bool(true),
        "the sole session must be flagged as the current one"
    );
}

#[tokio::test]
async fn revoking_current_session_immediately_blocks_the_token() {
    // The crown-jewel of P0-SESSIONS: a token that passes signature + exp must
    // be rejected the instant its session is revoked.
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // Sanity: token works before revoke.
    let before = app.send(get_auth("/auth/me", &token)).await;
    assert_eq!(before.status(), StatusCode::OK);

    let jti = current_session_jti(&app, &token).await;
    let del = app
        .send(
            axum::http::Request::builder()
                .method("DELETE")
                .uri(format!("/auth/sessions/{jti}"))
                .header("authorization", format!("Bearer {token}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(del.status(), StatusCode::NO_CONTENT);

    // Same token, now revoked, must 401 on the very next request.
    let after = app.send(get_auth("/auth/me", &token)).await;
    assert_eq!(
        after.status(),
        StatusCode::UNAUTHORIZED,
        "a revoked session's token must be rejected immediately"
    );
}

#[tokio::test]
async fn revoke_all_devices_kills_every_session_for_that_user() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    // Two independent logins ⇒ two sessions for the same user.
    let token1 = login(&app, &admin.username, &admin.password).await;
    let token2 = login(&app, &admin.username, &admin.password).await;

    let del = app
        .send(
            axum::http::Request::builder()
                .method("DELETE")
                .uri("/auth/sessions/all")
                .header("authorization", format!("Bearer {token1}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(del.status(), StatusCode::OK);

    // BOTH tokens are now dead.
    assert_eq!(
        app.send(get_auth("/auth/me", &token1)).await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        app.send(get_auth("/auth/me", &token2)).await.status(),
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn one_user_cannot_revoke_anothers_session() {
    // The self-service revoke is scoped to the caller's own user_id, so a jti
    // belonging to a different user must be untouched (404, and their token
    // keeps working).
    let app = TestApp::new().await;
    let victim = seed_admin(app.pool()).await;
    let attacker = seed_admin(app.pool()).await;
    let victim_token = login(&app, &victim.username, &victim.password).await;
    let attacker_token = login(&app, &attacker.username, &attacker.password).await;

    let victim_jti = current_session_jti(&app, &victim_token).await;

    // Attacker tries to revoke the victim's session by jti.
    let del = app
        .send(
            axum::http::Request::builder()
                .method("DELETE")
                .uri(format!("/auth/sessions/{victim_jti}"))
                .header("authorization", format!("Bearer {attacker_token}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(
        del.status(),
        StatusCode::NOT_FOUND,
        "revoking someone else's session by jti must 404, not succeed"
    );

    // Victim's token still works.
    assert_eq!(
        app.send(get_auth("/auth/me", &victim_token)).await.status(),
        StatusCode::OK
    );
}

#[tokio::test]
async fn admin_can_sign_out_another_users_devices() {
    let fx = build_rbac_fixture().await;
    // The viewer's own token, and the admin revoking every session for them.
    let viewer = seed_viewer(fx.app.pool(), &[fx.cam_a]).await;
    let viewer_token = login(&fx.app, &viewer.username, &viewer.password).await;
    assert_eq!(
        fx.app
            .send(get_auth("/auth/me", &viewer_token))
            .await
            .status(),
        StatusCode::OK
    );

    let del = fx
        .app
        .send(
            axum::http::Request::builder()
                .method("DELETE")
                .uri(format!("/auth/users/{}/sessions", viewer.user_id))
                .header("authorization", format!("Bearer {}", fx.admin_token))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(del.status(), StatusCode::OK);

    assert_eq!(
        fx.app
            .send(get_auth("/auth/me", &viewer_token))
            .await
            .status(),
        StatusCode::UNAUTHORIZED,
        "admin sign-out-all must kill the target user's token"
    );

    // A viewer must NOT be able to hit the admin revoke route.
    let forbidden = fx
        .app
        .send(
            axum::http::Request::builder()
                .method("DELETE")
                .uri(format!("/auth/users/{}/sessions", viewer.user_id))
                .header("authorization", format!("Bearer {}", fx.viewer_token))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);
}

// ─── scoped media tokens (P0-SESSIONS) ─────────────────────────────────────────

/// Mint a scoped media token for `camera` using `token`; returns the media token.
async fn mint_media_token(app: &TestApp, token: &str, camera: Uuid) -> String {
    let resp = app
        .send(get_auth(&format!("/media-token?camera={camera}"), token))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "minting a media token for an in-scope camera must succeed"
    );
    let v = body_json(resp).await;
    v["token"].as_str().expect("media token").to_owned()
}

#[tokio::test]
async fn media_token_mint_is_scope_checked() {
    let fx = build_rbac_fixture().await;
    // In-scope camera: OK.
    let ok = fx
        .app
        .send(get_auth(
            &format!("/media-token?camera={}", fx.cam_a),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(ok.status(), StatusCode::OK);

    // Out-of-scope camera: 403 — you can't mint a token broader than your access.
    let denied = fx
        .app
        .send(get_auth(
            &format!("/media-token?camera={}", fx.cam_b),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn scoped_media_token_plays_only_its_camera() {
    let fx = build_rbac_fixture().await;
    let pool = fx.app.pool().clone();
    let storage_id = seed_storage(&pool, fx.storage_root.path().to_str().unwrap()).await;
    let seg_a = seed_segment_with_file(&pool, fx.cam_a, storage_id, fx.storage_root.path()).await;
    let seg_b = seed_segment_with_file(&pool, fx.cam_b, storage_id, fx.storage_root.path()).await;

    // Admin mints a media token scoped to cam_a only.
    let media_a = mint_media_token(&fx.app, &fx.admin_token, fx.cam_a).await;

    // That token serves cam_a's segment...
    let own = fx
        .app
        .send(get(&format!("/segments/{seg_a}?token={media_a}")))
        .await;
    assert_eq!(
        own.status(),
        StatusCode::OK,
        "a media token scoped to cam_a must serve cam_a's segment"
    );

    // ...but NOT cam_b's, even though the minting admin could — the token is
    // hard-scoped to its single camera.
    let other = fx
        .app
        .send(get(&format!("/segments/{seg_b}?token={media_a}")))
        .await;
    assert_eq!(
        other.status(),
        StatusCode::FORBIDDEN,
        "a media token scoped to cam_a must NOT serve cam_b, regardless of who minted it"
    );
}

#[tokio::test]
async fn full_jwt_via_query_token_is_rejected_on_media_routes() {
    // Fail-closed (audit 2026-07-05 #2): the legacy `?token=<full login JWT>`
    // media path is now REJECTED — a login credential in a URL can leak into
    // proxy/access logs and browser history. Every current client uses a scoped
    // media token (GET /media-token) for per-camera media; the only remaining
    // full-JWT-via-?token= callers are the documented permissive exceptions
    // (export downloads and the web-console camera snapshot, tested separately).
    let fx = build_rbac_fixture().await;
    let pool = fx.app.pool().clone();
    let storage_id = seed_storage(&pool, fx.storage_root.path().to_str().unwrap()).await;
    let seg_a = seed_segment_with_file(&pool, fx.cam_a, storage_id, fx.storage_root.path()).await;

    let resp = fx
        .app
        .send(get(&format!("/segments/{seg_a}?token={}", fx.viewer_token)))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "a full login JWT via ?token= must be rejected on a fail-closed media route"
    );
}

// ─── auth invariant: no protected route ships unauthenticated ──────────────────
//
// Golden rule 1 (secure by default): a newly-added route must not silently ship
// without auth. axum can't enumerate its own routes, so this table is maintained
// by hand — WHEN YOU ADD A ROUTE, ADD IT HERE (protected → 401 for no
// credentials, or the public allowlist → not-401). The auth extractor
// (AuthUser / AdminUser / LegacyQueryTokenUser) is the FIRST handler parameter
// everywhere, so a missing token yields 401 before any path/query/body extractor
// runs — hence dummy path params are fine. Routed via the full-surface
// test_router() in support/mod.rs. (audit 2026-07-05: "108 routes / 120 AuthUser
// proves nothing — prove it mechanically".)
#[tokio::test]
async fn no_protected_route_is_reachable_without_credentials() {
    use axum::http::Method;
    let app = TestApp::new().await;
    let u = "00000000-0000-0000-0000-000000000000";

    async fn send_status(app: &TestApp, method: Method, uri: String) -> StatusCode {
        let req = axum::http::Request::builder()
            .method(method)
            .uri(&uri)
            .body(axum::body::Body::empty())
            .expect("build request");
        app.send(req).await.status()
    }

    // Every protected route: an unauthenticated request must be rejected 401.
    let protected: Vec<(Method, String)> = vec![
        // -- /auth (authenticated actions) --
        (Method::POST, "/auth/refresh".into()),
        (Method::GET, "/auth/me".into()),
        (Method::GET, "/auth/sessions".into()),
        (Method::DELETE, "/auth/sessions/all".into()),
        (Method::DELETE, format!("/auth/sessions/{u}")),
        (Method::DELETE, format!("/auth/users/{u}/sessions")),
        // -- scoped media-token mint --
        (Method::GET, "/media-token".into()),
        // -- /config/* (admin console; AdminUser) --
        (Method::GET, "/config/cameras".into()),
        (Method::POST, "/config/cameras".into()),
        (Method::PUT, format!("/config/cameras/{u}/policy")),
        (Method::POST, format!("/config/cameras/{u}/redetect")),
        (Method::PUT, format!("/config/cameras/{u}/clip-source")),
        (Method::GET, "/config/policies".into()),
        (Method::POST, "/config/policies".into()),
        (Method::POST, format!("/config/policies/{u}/change-storage")),
        (Method::GET, "/config/migrations".into()),
        (Method::GET, format!("/config/migrations/{u}")),
        (Method::POST, format!("/config/migrations/{u}/retry")),
        (Method::POST, format!("/config/migrations/{u}/cancel")),
        (Method::GET, "/config/decode-status".into()),
        (Method::GET, "/config/motion-cache-status".into()),
        (Method::GET, "/config/frigate".into()),
        (Method::PUT, "/config/frigate".into()),
        (Method::POST, "/config/frigate/test".into()),
        (Method::POST, "/config/frigate/test-http".into()),
        (Method::GET, "/config/groups".into()),
        (Method::POST, "/config/groups".into()),
        (Method::PUT, format!("/config/groups/{u}/members")),
        (Method::GET, "/config/storages".into()),
        (Method::POST, "/config/storages".into()),
        (Method::GET, "/config/fs/list".into()),
        (Method::POST, "/config/fs/check".into()),
        (Method::GET, "/config/users".into()),
        (Method::POST, "/config/users".into()),
        (Method::GET, "/config/roles".into()),
        (Method::POST, "/config/roles".into()),
        (Method::PUT, format!("/config/roles/{u}")),
        (Method::DELETE, format!("/config/roles/{u}")),
        (Method::GET, "/config/clip-sources".into()),
        (Method::PUT, "/config/clip-source-default".into()),
        (Method::GET, "/config/clip-preroll".into()),
        (Method::PUT, "/config/clip-preroll".into()),
        (Method::GET, "/config/scrub-preview".into()),
        (Method::PUT, "/config/scrub-preview".into()),
        (Method::PUT, "/config/setup-complete".into()),
        (Method::GET, "/config/camera-brands".into()),
        (Method::POST, "/config/discover".into()),
        (Method::POST, "/config/discover/probe".into()),
        (Method::POST, "/config/test-stream".into()),
        (Method::POST, "/config/test-frame".into()),
        // -- viewer-facing JSON --
        (Method::GET, "/cameras".into()),
        (Method::GET, "/views".into()),
        (Method::PUT, format!("/views/{u}/icon")),
        (Method::DELETE, format!("/views/{u}")),
        (Method::GET, format!("/views/{u}/shares")),
        (Method::GET, "/bookmarks".into()),
        (Method::GET, "/timeline".into()),
        (Method::GET, "/timeline/intensity".into()),
        (Method::GET, "/timeline/motion".into()),
        (Method::GET, "/status".into()),
        (Method::GET, "/stats/cameras".into()),
        (Method::GET, "/stats/policies".into()),
        (Method::GET, "/stats/storage".into()),
        (Method::POST, format!("/cameras/{u}/ptz")),
        (Method::POST, format!("/cameras/{u}/imaging")),
        (Method::GET, "/events".into()),
        // Detection snapshot proxy: despite a stale "unauthenticated opaque-UUID"
        // comment in main.rs/events.rs, get_event_snapshot actually takes AuthUser,
        // so it is protected (audit 2026-07-05 — the code is more secure than the
        // doc claimed).
        (Method::GET, format!("/events/{u}/snapshot")),
        (Method::GET, "/clips".into()),
        (Method::POST, "/clips/viewed".into()),
        (Method::GET, "/notifications/log".into()),
        (Method::GET, "/notifications/system-alerts".into()),
        (Method::POST, format!("/notifications/channels/{u}/test")),
        (Method::PUT, format!("/notifications/rules/{u}")),
        (Method::POST, "/presence".into()),
        (Method::DELETE, format!("/notifications/devices/{u}")),
        // -- media (fail-closed AuthUser / permissive LegacyQueryTokenUser; with
        //    NO credential at all, both return 401) --
        (Method::GET, "/play/aligned".into()),
        (Method::GET, format!("/play/{u}")),
        (Method::GET, format!("/segments/{u}")),
        (Method::GET, format!("/segments/{u}/low.mp4")),
        (Method::GET, format!("/cameras/{u}/streams")),
        (Method::GET, format!("/cameras/{u}/motion-grid")),
        (Method::GET, format!("/live/{u}/stream.mp4")),
        (Method::POST, format!("/live/{u}/webrtc")),
        (Method::GET, format!("/filmstrip/{u}")),
        (Method::GET, format!("/filmstrip/{u}/frame")),
        (Method::GET, format!("/export/{u}/archive")),
        (Method::GET, format!("/export/{u}/files/{u}")),
        (Method::POST, "/export".into()),
        (Method::POST, "/export/batch".into()),
        (Method::GET, format!("/clip/{u}/clip.mp4")),
        (Method::GET, format!("/clip/{u}/thumbnail.jpg")),
        (Method::GET, format!("/cameras/{u}/frame.jpg")),
        (Method::GET, "/stats/policies/verify".into()),
    ];

    for (m, path) in &protected {
        let st = send_status(&app, m.clone(), path.clone()).await;
        assert_eq!(
            st,
            StatusCode::UNAUTHORIZED,
            "{m} {path} must reject an unauthenticated request with 401 (got {st}); \
             if this is a new PUBLIC route, add it to the allowlist below instead"
        );
    }

    // The intentionally-public allowlist: reachable without credentials. We only
    // assert auth is NOT required (status != 401) — bootstrap 409s once an admin
    // exists, the snapshot proxy 404s for an unknown id, etc. (/health, /version,
    // /admin are defined inline in main.rs, not a route module, so they aren't in
    // test_router() — they're public by construction.)
    let public: Vec<(Method, String)> = vec![
        (Method::POST, "/auth/login".into()),
        (Method::POST, "/auth/bootstrap".into()),
        (Method::GET, "/auth/setup-status".into()),
        (Method::GET, "/auth/needs-bootstrap".into()),
    ];
    for (m, path) in &public {
        let st = send_status(&app, m.clone(), path.clone()).await;
        assert_ne!(
            st,
            StatusCode::UNAUTHORIZED,
            "{m} {path} is a public route and must not require auth (got {st})"
        );
    }
}

// ─── beta tester terms gate (first-run AS-IS acceptance) ──────────────────────

/// The setup probe reports `beta_terms_accepted=false` until an admin records
/// acceptance via `PUT /config/beta-terms`, after which it reports `true`. This
/// backs the first-run wizard's AS-IS gate — the recorded, server-side assent,
/// not merely the client-side checkbox.
#[tokio::test]
async fn beta_terms_acceptance_recorded_and_surfaced() {
    // This test asserts the fresh-install state of the process-wide
    // `server_settings` singleton (beta_terms_accepted=false) and then mutates
    // it. Serialize + reset so a concurrent settings test — or residue from a
    // prior `cargo test` run against a reused Postgres — can't flip that shared
    // row mid-assert (#88).
    let _settings_guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    reset_server_settings(app.pool()).await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // Fresh install: the gate has not been accepted.
    let resp = app.send(get_auth("/auth/setup-status", &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        body_json(resp).await["beta_terms_accepted"],
        serde_json::json!(false)
    );

    // Admin records acceptance.
    let resp = app
        .send(
            axum::http::Request::builder()
                .method("PUT")
                .uri("/config/beta-terms")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(axum::body::Body::from(r#"{"accept":true}"#))
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // The probe now reflects the recorded acceptance.
    let resp = app.send(get_auth("/auth/setup-status", &token)).await;
    assert_eq!(
        body_json(resp).await["beta_terms_accepted"],
        serde_json::json!(true)
    );
}

/// `PUT /config/beta-terms` is admin-only: a valid non-admin token is rejected,
/// so a viewer can't stamp the operator's acceptance of the terms.
#[tokio::test]
async fn beta_terms_acceptance_requires_admin() {
    let app = TestApp::new().await;
    let viewer = seed_viewer(app.pool(), &[]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(
            axum::http::Request::builder()
                .method("PUT")
                .uri("/config/beta-terms")
                .header("authorization", format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(axum::body::Body::from(r#"{"accept":true}"#))
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// ─── scrub-preview runtime tunables (issue #10) ────────────────────────────

/// Build a `PUT` request with a Bearer token and a raw JSON string body
/// (mirrors the inline builder `beta_terms_acceptance_*` above; kept local
/// rather than added to `support/mod.rs` since this is the first PUT test
/// that needs an arbitrary partial JSON body rather than a fixed shape).
fn put_auth_json(uri: &str, token: &str, body: &str) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("PUT")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body.to_owned()))
        .unwrap()
}

/// `GET`/`PUT /config/scrub-preview` is admin-only, same gate as every other
/// `/config/*` route: a viewer token is refused 403, no token at all is 401.
#[tokio::test]
async fn scrub_preview_requires_admin() {
    let app = TestApp::new().await;
    let viewer = seed_viewer(app.pool(), &[]).await;
    let viewer_token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(get_auth("/config/scrub-preview", &viewer_token))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    let resp = app
        .send(put_auth_json(
            "/config/scrub-preview",
            &viewer_token,
            r#"{"pregen_enabled":true}"#,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    let resp = app.send(get("/config/scrub-preview")).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

/// `GET /config/scrub-preview` reflects the env default (`source: "env"`)
/// until an admin `PUT`s a value, at which point it reflects the DB override
/// (`source: "db"`) — the same precedence the pre-gen worker and cache
/// sweeper resolve live. Also covers: the read-only `pregen_width` field
/// (`source: "env-only"`, D1); that a `PUT` with only one field leaves every
/// other field's effective value/source untouched; and that an
/// out-of-bounds `PUT` value is clamped server-side rather than rejected (the
/// `clip_preroll` precedent), including the 100 MiB `cache_max_bytes` floor
/// (D5).
///
/// One test function covering the whole GET/PUT round trip rather than
/// several smaller ones: `server_settings` is a process-wide singleton row
/// (see the db.rs `scrub_pregen_settings_roundtrip_and_clamps` note), so
/// asserting "every OTHER field is untouched" only holds if nothing else is
/// concurrently mutating those same columns — keeping every mutation +
/// assertion of this row in one sequential test avoids that race entirely.
#[tokio::test]
async fn scrub_preview_get_put_roundtrip_and_clamps() {
    // Asserts every scrub knob falls back to its env default (`source: "env"`)
    // on a fresh DB, then mutates them. Serialize + reset the shared
    // `server_settings` singleton so a concurrent settings test — or leftover
    // state from a prior `cargo test` run against a reused Postgres — can't make
    // a knob read `source: "db"` before this test writes it (#88).
    let _settings_guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    reset_server_settings(app.pool()).await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // Fresh DB: every knob falls back to its env default.
    let resp = app.send(get_auth("/config/scrub-preview", &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let before = body_json(resp).await;
    assert_eq!(before["pregen_enabled"]["source"], "env");
    assert_eq!(before["pregen_lookback_hours"]["source"], "env");
    assert_eq!(before["pregen_scan_secs"]["source"], "env");
    assert_eq!(before["cache_max_bytes"]["source"], "env");
    assert_eq!(before["cache_ttl_seconds"]["source"], "env");
    // Read-only, never DB-backed.
    assert_eq!(before["pregen_width"]["source"], "env-only");
    let default_scan_secs = before["pregen_scan_secs"]["value"].clone();
    let default_ttl = before["cache_ttl_seconds"]["value"].clone();

    // PUT only `pregen_enabled` — the house rule is "write only the field
    // that was edited".
    let resp = app
        .send(put_auth_json(
            "/config/scrub-preview",
            &token,
            r#"{"pregen_enabled":true}"#,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let resp = app.send(get_auth("/config/scrub-preview", &token)).await;
    let after_enable = body_json(resp).await;
    assert_eq!(
        after_enable["pregen_enabled"],
        serde_json::json!({"value": true, "source": "db"})
    );
    // Every OTHER field must be untouched: still env-sourced.
    assert_eq!(after_enable["pregen_lookback_hours"]["source"], "env");
    assert_eq!(after_enable["pregen_scan_secs"]["source"], "env");
    assert_eq!(after_enable["cache_max_bytes"]["source"], "env");
    assert_eq!(after_enable["cache_ttl_seconds"]["source"], "env");

    // Now PUT out-of-bounds values for two more fields — clamped, not
    // rejected, and (again) every field not in this PUT stays untouched.
    let resp = app
        .send(put_auth_json(
            "/config/scrub-preview",
            &token,
            r#"{"pregen_lookback_hours":9999,"cache_max_bytes":0}"#,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let resp = app.send(get_auth("/config/scrub-preview", &token)).await;
    let after_clamp = body_json(resp).await;
    assert_eq!(
        after_clamp["pregen_lookback_hours"],
        serde_json::json!({"value": 168, "source": "db", "min": 0, "max": 168}),
        "must clamp to the 168h (1 week) ceiling, not store the raw 9999"
    );
    assert_eq!(
        after_clamp["cache_max_bytes"]["value"],
        serde_json::json!(104_857_600_i64),
        "must clamp to the 100 MiB floor (D5), not store 0"
    );
    // pregen_enabled (set earlier) and the fields never touched by any PUT
    // in this test must still reflect their expected state.
    assert_eq!(after_clamp["pregen_enabled"]["source"], "db");
    assert_eq!(after_clamp["pregen_scan_secs"]["source"], "env");
    assert_eq!(after_clamp["pregen_scan_secs"]["value"], default_scan_secs);
    assert_eq!(after_clamp["cache_ttl_seconds"]["source"], "env");
    assert_eq!(after_clamp["cache_ttl_seconds"]["value"], default_ttl);
}

// ─── bookmark scope: the read-all / manage-own tier (BookmarkScope::ViewAll) ──

/// A `ViewAll` viewer SEES every bookmark on cameras it can access (like `All`)
/// but may edit/delete only its OWN — the "view all, manage own" tier. Proven
/// end-to-end: it lists another user's bookmark, is refused 403 on PATCH/DELETE
/// of that bookmark, and can PATCH/DELETE one it created itself.
#[tokio::test]
async fn bookmark_viewall_sees_all_but_manages_only_own() {
    use crumb_common::types::BookmarkScope;

    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;

    // Owner (any bookmark-capable scope) + the ViewAll viewer, both scoped to
    // the same camera so cross-visibility is about bookmark scope, not camera
    // scope.
    let owner = seed_viewer_with_bookmark_scope(app.pool(), &[cam], BookmarkScope::Own).await;
    let viewer = seed_viewer_with_bookmark_scope(app.pool(), &[cam], BookmarkScope::ViewAll).await;
    let owner_token = login(&app, &owner.username, &owner.password).await;
    let viewer_token = login(&app, &viewer.username, &viewer.password).await;

    // Each user creates a bookmark on the shared camera.
    let mk = |token: &str| {
        post_auth_json(
            "/bookmarks",
            token,
            &serde_json::json!({ "camera_id": cam, "ts": "2026-06-21T17:03:52Z" }),
        )
    };
    let resp = app.send(mk(&owner_token)).await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let owners_bookmark = body_json(resp).await["id"].as_str().unwrap().to_owned();

    let resp = app.send(mk(&viewer_token)).await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let viewers_bookmark = body_json(resp).await["id"].as_str().unwrap().to_owned();

    // ViewAll SEES both (the owner's and its own).
    let resp = app
        .send(get_auth(
            &format!("/bookmarks?camera_id={cam}"),
            &viewer_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let ids: Vec<String> = body_json(resp)
        .await
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b["id"].as_str().unwrap().to_owned())
        .collect();
    assert!(
        ids.contains(&owners_bookmark) && ids.contains(&viewers_bookmark),
        "ViewAll must see every bookmark on the camera, got {ids:?}"
    );

    let patch = |id: &str, token: &str| {
        axum::http::Request::builder()
            .method("PATCH")
            .uri(format!("/bookmarks/{id}"))
            .header("authorization", format!("Bearer {token}"))
            .header("content-type", "application/json")
            .body(axum::body::Body::from(r#"{"description":"edited"}"#))
            .unwrap()
    };
    let delete = |id: &str, token: &str| {
        axum::http::Request::builder()
            .method("DELETE")
            .uri(format!("/bookmarks/{id}"))
            .header("authorization", format!("Bearer {token}"))
            .body(axum::body::Body::empty())
            .unwrap()
    };

    // Managing the OWNER's bookmark is refused — ViewAll is read-all, not
    // manage-all.
    let resp = app.send(patch(&owners_bookmark, &viewer_token)).await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let resp = app.send(delete(&owners_bookmark, &viewer_token)).await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // Managing its OWN bookmark works.
    let resp = app.send(patch(&viewers_bookmark, &viewer_token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let resp = app.send(delete(&viewers_bookmark, &viewer_token)).await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}
