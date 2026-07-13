// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for `GET /plates` — the LPR plate-reads endpoint, and
//! Crumb's FIRST capability-gated *read* surface. Covers `view_plates` gating
//! (the deny path), camera scoping, admin passthrough, and the dynamic
//! prefix/fuzzy search query (the hand-built `$N`-parameterized SQL).
//!
//! Structure mirrors `auth_rbac.rs`: this test binary's crate root re-includes
//! the crate's own (private, bin-only) source modules via `tests/support/mod.rs`
//! `#[path]` includes, so the same curated clippy allowances `main.rs` declares
//! must be repeated here for `--all-targets -D warnings` parity.
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
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db;
use crumb_common::types::{BookmarkScope, Capabilities};

use support::*;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn seed_plate(pool: &Pool, camera_id: Uuid, plate: &str) {
    db::upsert_plate_read(
        pool,
        &db::UpsertPlateReadParams {
            camera_id,
            ts: chrono::Utc::now(),
            plate: db::normalize_plate(plate),
            plate_raw: Some(plate.to_owned()),
            confidence: Some(0.9),
            source_id: "frigate".to_owned(),
            // Unique per seed: the tests share one Postgres, and the dedup index
            // on (source_id, provider_event_id) would otherwise let one test's
            // read UPSERT-clobber another's (moving its camera_id) under parallel
            // execution.
            provider_event_id: Some(unique("pid")),
            event_id: None,
            snapshot_url: None,
            raw: serde_json::json!({}),
        },
    )
    .await
    .expect("seed plate_read");
}

/// A viewer scoped to `cameras` but WITHOUT the `view_plates` capability.
async fn seed_viewer_no_plates(pool: &Pool, cameras: &[Uuid]) -> SeededUser {
    let caps = Capabilities {
        export: false,
        playback: true,
        clips: true,
        ptz: false,
        bookmarks: BookmarkScope::Own,
        manage_views: true,
        view_plates: false,
    };
    let role = db::create_role(pool, &unique("role"), &caps, cameras)
        .await
        .expect("create_role");
    seed_viewer_user(pool, role.id).await
}

#[tokio::test]
async fn plates_denied_without_view_plates_capability() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    seed_plate(app.pool(), cam, "ABC123").await;

    let user = seed_viewer_no_plates(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app
        .send(get_auth(&format!("/plates?camera_ids={cam}"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn plates_camera_scoped_to_grants() {
    let app = TestApp::new().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    seed_plate(app.pool(), cam_a, "AAA111").await;
    seed_plate(app.pool(), cam_b, "BBB222").await;

    // Viewer WITH view_plates, but granted only cam_a.
    let user = seed_viewer(app.pool(), &[cam_a]).await;
    let token = login(&app, &user.username, &user.password).await;

    // Requests BOTH cameras; the out-of-scope one must be silently dropped.
    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam_a},{cam_b}"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let plates = v["plates"].as_array().unwrap();
    assert_eq!(plates.len(), 1, "viewer must see only their granted camera");
    assert_eq!(plates[0]["plate"], "AAA111");
    assert_eq!(plates[0]["camera_id"], cam_a.to_string());
}

#[tokio::test]
async fn plates_admin_sees_all_requested_cameras() {
    let app = TestApp::new().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    seed_plate(app.pool(), cam_a, "AAA111").await;
    seed_plate(app.pool(), cam_b, "BBB222").await;

    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam_a},{cam_b}"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["total"], 2);
    assert_eq!(v["plates"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn plates_prefix_and_fuzzy_search() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    seed_plate(app.pool(), cam, "ABC123").await;
    seed_plate(app.pool(), cam, "XYZ789").await;

    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // prefix: only ABC123 (exercises the `plate LIKE $n || '%'` param path).
    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam}&q=ABC&match=prefix"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let plates = v["plates"].as_array().unwrap();
    assert_eq!(plates.len(), 1);
    assert_eq!(plates[0]["plate"], "ABC123");

    // fuzzy: a one-character miss still surfaces ABC123 via trigram similarity
    // (exercises the `plate % $n` + `similarity(plate, $n)` param reuse).
    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam}&q=ABC124&match=fuzzy"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let found: Vec<String> = v["plates"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["plate"].as_str().unwrap().to_owned())
        .collect();
    assert!(
        found.iter().any(|p| p == "ABC123"),
        "fuzzy search should surface ABC123, got {found:?}"
    );
}
