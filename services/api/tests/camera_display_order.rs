// SPDX-License-Identifier: AGPL-3.0-or-later

//! Admin-set camera display order (`PUT /config/camera-order`, migration 0085).
//! Placed cameras come first in the stored order on both camera lists
//! (`GET /cameras` and `GET /config/cameras`); unplaced cameras follow in name
//! order; an empty list resets; duplicates are refused; viewers cannot set it;
//! and changing it changes `/status`'s `config_version` so clients refresh.

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
use crumb_common::db;
use support::*;
use uuid::Uuid;

async fn json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .expect("read body");
    serde_json::from_slice(&bytes).expect("json body")
}

/// The ids from a camera-list response, keeping only `ours` (other tests'
/// cameras share the database), in response order.
async fn listed(app: &TestApp, uri: &str, token: &str, ours: &[Uuid]) -> Vec<Uuid> {
    let resp = app.send(get_auth(uri, token)).await;
    assert_eq!(resp.status(), StatusCode::OK, "{uri}");
    json(resp)
        .await
        .as_array()
        .expect("camera list")
        .iter()
        .map(|c| c["id"].as_str().unwrap().parse::<Uuid>().unwrap())
        .filter(|id| ours.contains(id))
        .collect()
}

async fn rename(app: &TestApp, id: Uuid, name: &str) {
    let client = app.pool().get().await.unwrap();
    client
        .execute("UPDATE cameras SET name = $2 WHERE id = $1", &[&id, &name])
        .await
        .unwrap();
}

// One test so nothing else in this binary sets the order concurrently: the
// order is fleet-wide, and every PUT resets cameras it does not list.
#[tokio::test]
async fn admin_sets_display_order_for_every_client() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let (a, b, c) = (
        seed_camera(app.pool()).await,
        seed_camera(app.pool()).await,
        seed_camera(app.pool()).await,
    );
    let tag = unique("ord");
    rename(&app, a, &format!("{tag} cam 1")).await;
    rename(&app, b, &format!("{tag} cam 2")).await;
    rename(&app, c, &format!("{tag} cam 10")).await;
    let ours = [a, b, c];

    // Nothing placed: natural name order, "cam 2" before "cam 10".
    let resp = app
        .send(put_auth_json(
            "/config/camera-order",
            &token,
            &serde_json::json!({ "camera_ids": [] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert_eq!(listed(&app, "/cameras", &token, &ours).await, vec![a, b, c]);
    let before = db::config_version(app.pool()).await.unwrap();

    // Place c then a; b is left out, so it follows them.
    let resp = app
        .send(put_auth_json(
            "/config/camera-order",
            &token,
            &serde_json::json!({ "camera_ids": [c, a, Uuid::new_v4()] }),
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::NO_CONTENT,
        "unknown ids are ignored"
    );
    assert_eq!(listed(&app, "/cameras", &token, &ours).await, vec![c, a, b]);
    assert_eq!(
        listed(&app, "/config/cameras", &token, &ours).await,
        vec![c, a, b]
    );
    assert_ne!(
        db::config_version(app.pool()).await.unwrap(),
        before,
        "a new order must change config_version so clients re-fetch"
    );

    // Duplicates are refused and leave the stored order alone.
    let resp = app
        .send(put_auth_json(
            "/config/camera-order",
            &token,
            &serde_json::json!({ "camera_ids": [a, a] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    assert_eq!(listed(&app, "/cameras", &token, &ours).await, vec![c, a, b]);

    // A viewer cannot set it.
    let viewer = seed_viewer(app.pool(), &ours).await;
    let vtoken = login(&app, &viewer.username, &viewer.password).await;
    let resp = app
        .send(put_auth_json(
            "/config/camera-order",
            &vtoken,
            &serde_json::json!({ "camera_ids": [b, a, c] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    // ...but sees the admin's order.
    assert_eq!(
        listed(&app, "/cameras", &vtoken, &ours).await,
        vec![c, a, b]
    );

    // An empty list resets to name order.
    let resp = app
        .send(put_auth_json(
            "/config/camera-order",
            &token,
            &serde_json::json!({ "camera_ids": [] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert_eq!(listed(&app, "/cameras", &token, &ours).await, vec![a, b, c]);
}
