// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for the two routes that stopped carrying a login token in
//! a URL: the export downloads (now `Authorization: Bearer` only) and the new
//! single-use console-handoff code that the desktop client uses to open the web
//! console in the operator's real browser.
//!
//! Same harness as `auth_rbac.rs` (see `tests/support/mod.rs`): the real `src/`
//! modules recompiled into this test binary, running against a real Postgres.
//!
//! # Running locally
//!
//! ```sh
//! cargo test -p crumb-api --test auth_handoff
//! ```
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

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use axum::body::to_bytes;
use axum::http::StatusCode;
use chrono::Utc;
use uuid::Uuid;

use support::dto::{ExportJob, ExportOutputFile, ExportStatus};
use support::*;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
}

/// Per-process export directory, pointed at by `EXPORT_DIR` so the download
/// handler resolves files here instead of the production `/exports` volume.
///
/// `get_or_init` blocks every other caller until the first one has both created
/// the directory and set the env var, so a test that calls this before building
/// its `TestApp` always sees a config built from it.
fn export_root() -> &'static Path {
    static EXPORT_ROOT: OnceLock<PathBuf> = OnceLock::new();
    EXPORT_ROOT.get_or_init(|| {
        let mut p = std::env::temp_dir();
        p.push(format!("crumb-test-exports-{}", Uuid::new_v4().simple()));
        std::fs::create_dir_all(&p).expect("create temp export dir");
        std::env::set_var("EXPORT_DIR", &p);
        p
    })
}

/// Register a completed one-camera export job with a real file on disk, so the
/// download route can stream it. Returns the job id.
fn seed_done_export_job(app: &TestApp, camera_id: Uuid) -> Uuid {
    let job_id = Uuid::new_v4();
    let dir = export_root().join(job_id.to_string());
    std::fs::create_dir_all(&dir).expect("create job export dir");
    let filename = format!("{camera_id}.mp4");
    let bytes: &[u8] = b"crumb test export payload";
    std::fs::write(dir.join(&filename), bytes).expect("write export output file");

    let now = Utc::now();
    app.state.export_jobs().insert(
        job_id,
        ExportJob {
            id: job_id,
            status: ExportStatus::Done,
            camera_ids: vec![camera_id],
            start: now,
            end: now,
            burn_timestamp: false,
            created_at: now,
            output_files: vec![ExportOutputFile {
                camera_id,
                download_url: format!("/export/{job_id}/files/{camera_id}"),
                size_bytes: bytes.len() as u64,
                filename,
            }],
            error: None,
            progress_pct: 100,
        },
    );
    job_id
}

/// Build an unauthenticated `POST` with a JSON body (the handoff exchange is
/// called by a browser that has no credentials yet).
fn post_json(uri: &str, body: &serde_json::Value) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("POST")
        .uri(uri)
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body.to_string()))
        .unwrap()
}

// ─── export downloads ───────────────────────────────────────────────────────

#[tokio::test]
async fn export_download_rejects_a_login_token_in_the_query() {
    let _ = export_root();
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let camera_id = seed_camera(app.pool()).await;
    let job_id = seed_done_export_job(&app, camera_id);

    let resp = app
        .send(get(&format!(
            "/export/{job_id}/files/{camera_id}?token={token}"
        )))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "a login token in the query must not authenticate a per-camera export download"
    );

    let resp = app
        .send(get(&format!("/export/{job_id}/archive?token={token}")))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "a login token in the query must not authenticate an archive download"
    );
}

#[tokio::test]
async fn export_download_accepts_the_authorization_header() {
    let _ = export_root();
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let camera_id = seed_camera(app.pool()).await;
    let job_id = seed_done_export_job(&app, camera_id);

    let resp = app
        .send(get_auth(
            &format!("/export/{job_id}/files/{camera_id}"),
            &token,
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "an export download authenticated with the Authorization header must succeed"
    );
}

// ─── console handoff ────────────────────────────────────────────────────────

#[tokio::test]
async fn handoff_code_exchanges_for_a_working_session() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(post_auth_json(
            "/auth/handoff",
            &token,
            &serde_json::json!({}),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "minting a handoff code");
    let body = body_json(resp).await;
    let code = body["code"]
        .as_str()
        .expect("code in the response")
        .to_owned();
    assert!(code.len() >= 32, "the code must not be guessable: {code}");
    assert!(
        body["expires_in"].as_u64().unwrap_or(0) > 0,
        "the response states how long the code lives"
    );

    let resp = app
        .send(post_json(
            "/auth/handoff/exchange",
            &serde_json::json!({ "code": code }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "exchanging the handoff code");
    let handed_off = body_json(resp).await["token"]
        .as_str()
        .expect("token in the exchange response")
        .to_owned();
    assert_ne!(
        handed_off, token,
        "the browser must get its own session, not a copy of the client's"
    );

    // It really is a session for the same user.
    let resp = app.send(get_auth("/auth/me", &handed_off)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        body_json(resp).await["id"].as_str(),
        Some(admin.user_id.to_string().as_str()),
        "the handed-off session belongs to the user who minted the code"
    );

    // And it is a real `sessions` row, so "sign out everywhere" reaches it.
    let resp = app
        .send(
            axum::http::Request::builder()
                .method("DELETE")
                .uri("/auth/sessions/all")
                .header("authorization", format!("Bearer {token}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "sign out all devices");

    let resp = app.send(get_auth("/auth/me", &handed_off)).await;
    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "signing out everywhere must also end the handed-off browser session"
    );
}

#[tokio::test]
async fn a_handoff_code_is_single_use() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(post_auth_json(
            "/auth/handoff",
            &token,
            &serde_json::json!({}),
        ))
        .await;
    let code = body_json(resp).await["code"]
        .as_str()
        .expect("code in the response")
        .to_owned();

    let first = app
        .send(post_json(
            "/auth/handoff/exchange",
            &serde_json::json!({ "code": code }),
        ))
        .await;
    assert_eq!(first.status(), StatusCode::OK);

    let second = app
        .send(post_json(
            "/auth/handoff/exchange",
            &serde_json::json!({ "code": code }),
        ))
        .await;
    assert_eq!(
        second.status(),
        StatusCode::UNAUTHORIZED,
        "a handoff code must not be redeemable twice"
    );
}

#[tokio::test]
async fn an_expired_handoff_code_is_rejected() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;

    // The TTL is a parameter of the mint so this does not have to sleep for the
    // production window.
    let code = app
        .state
        .issue_handoff_code(admin.user_id, None, Duration::from_millis(1));
    tokio::time::sleep(Duration::from_millis(20)).await;

    let resp = app
        .send(post_json(
            "/auth/handoff/exchange",
            &serde_json::json!({ "code": code }),
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::UNAUTHORIZED,
        "an expired handoff code must not be redeemable"
    );
}

#[tokio::test]
async fn an_unknown_handoff_code_is_rejected() {
    let app = TestApp::new().await;

    let resp = app
        .send(post_json(
            "/auth/handoff/exchange",
            &serde_json::json!({ "code": "not-a-real-code" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn a_media_token_cannot_mint_a_handoff_code() {
    let app = TestApp::new().await;
    let pool = app.pool().clone();
    let camera_id = seed_camera(&pool).await;
    let viewer = seed_viewer(&pool, &[camera_id]).await;
    let viewer_token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(get_auth(
            &format!("/media-token?camera={camera_id}"),
            &viewer_token,
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "minting a scoped media token"
    );
    let media_token = body_json(resp).await["token"]
        .as_str()
        .expect("token in the media-token response")
        .to_owned();

    let resp = app
        .send(
            axum::http::Request::builder()
                .method("POST")
                .uri(format!("/auth/handoff?token={media_token}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "a scoped media token must not be tradeable for a console session"
    );
}
