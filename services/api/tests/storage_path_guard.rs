// SPDX-License-Identifier: AGPL-3.0-or-later

//! `PUT /config/storages/{id}` path-change guard (audit R11).
//!
//! Segment rows store their path relative to the storage root, so repointing a
//! storage that holds recordings would hide every one of them and let the
//! recorder's sweeps prune their rows. The handler refuses that change with a
//! `409` and points at "Change storage". A rename that resends the unchanged
//! path (the console always sends it) must keep working.

mod support;

use axum::body::to_bytes;
use axum::http::StatusCode;
use serde_json::{json, Value};
use support::*;

struct TempDir(std::path::PathBuf);

impl TempDir {
    fn new(prefix: &str) -> Self {
        let p = std::env::temp_dir().join(format!("{prefix}-{}", uuid::Uuid::new_v4().simple()));
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

async fn body_text(resp: axum::http::Response<axum::body::Body>) -> String {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    String::from_utf8_lossy(&bytes).into_owned()
}

async fn admin_token(app: &TestApp) -> String {
    let admin = seed_admin(app.pool()).await;
    login(app, &admin.username, &admin.password).await
}

#[tokio::test]
async fn path_change_is_refused_while_the_storage_holds_segments() {
    let app = TestApp::new().await;
    let token = admin_token(&app).await;
    let root = TempDir::new("crumb-test-storage-guard");
    let storage_id = seed_storage(app.pool(), root.path().to_str().unwrap()).await;
    let camera_id = seed_camera(app.pool()).await;
    seed_segment_with_file(app.pool(), camera_id, storage_id, root.path()).await;

    let moved = root.path().join("elsewhere");
    let resp = app
        .send(put_auth_json(
            &format!("/config/storages/{storage_id}"),
            &token,
            &json!({ "path": moved.to_str().unwrap() }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let msg = body_text(resp).await;
    assert!(
        msg.contains("Change storage"),
        "the refusal points the operator at the drain: {msg}"
    );

    let stored = crumb_common::db::get_storage(app.pool(), storage_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        stored.path,
        root.path().to_str().unwrap(),
        "the stored path is unchanged"
    );
}

#[tokio::test]
async fn rename_with_the_unchanged_path_still_works() {
    let app = TestApp::new().await;
    let token = admin_token(&app).await;
    let root = TempDir::new("crumb-test-storage-guard");
    let storage_id = seed_storage(app.pool(), root.path().to_str().unwrap()).await;
    let camera_id = seed_camera(app.pool()).await;
    seed_segment_with_file(app.pool(), camera_id, storage_id, root.path()).await;

    let new_name = unique("renamed");
    // The console resends the path on every save; a trailing separator is the
    // same folder and must not count as a change.
    let same_path = format!("{}/", root.path().to_str().unwrap());
    let resp = app
        .send(put_auth_json(
            &format!("/config/storages/{storage_id}"),
            &token,
            &json!({ "name": new_name, "path": same_path }),
        ))
        .await;
    let status = resp.status();
    let text = body_text(resp).await;
    assert_eq!(status, StatusCode::OK, "{text}");
    let v: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["name"], json!(new_name));
    assert_eq!(
        v["path"],
        json!(root.path().to_str().unwrap()),
        "a lexically equal path is not rewritten"
    );
}

#[tokio::test]
async fn path_change_on_an_empty_storage_reaches_normal_validation() {
    let app = TestApp::new().await;
    let token = admin_token(&app).await;
    let root = TempDir::new("crumb-test-storage-guard");
    let storage_id = seed_storage(app.pool(), root.path().to_str().unwrap()).await;

    // No segments: the guard lets the change through to the ordinary path
    // validation. A relative path is rejected there, not by the guard.
    let resp = app
        .send(put_auth_json(
            &format!("/config/storages/{storage_id}"),
            &token,
            &json!({ "path": "relative/folder" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
}
