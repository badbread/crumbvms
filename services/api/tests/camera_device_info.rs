// SPDX-License-Identifier: AGPL-3.0-or-later

//! Manual make/model/firmware entry via the camera-edit PUT (`PUT
//! /config/cameras/:id`), issue #48. A non-ONVIF camera (or one the ONVIF probe
//! got wrong) can set or clear its compatibility identity by hand; the ONVIF
//! `identify` endpoint writes the same columns. Verifies the double-option merge:
//! a value sets, `null` clears, an omitted field is left unchanged.

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
// Glob so support's `pub mod auth_mw`/`dto`/`state`/… re-export into the crate
// root, where the `#[path]`-included source resolves them as `crate::…`.
use support::*;

fn put_auth_json(
    uri: &str,
    token: &str,
    body: &serde_json::Value,
) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("PUT")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body.to_string()))
        .unwrap()
}

#[tokio::test]
async fn manual_make_model_sets_merges_and_clears() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let cam = seed_camera(app.pool()).await;
    let uri = format!("/config/cameras/{cam}");

    // 1. Set all three by hand.
    let resp = app
        .send(put_auth_json(
            &uri,
            &token,
            &serde_json::json!({ "make": "Uniview", "model": "IPC2124", "firmware": "1.2.3" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let info = db::get_camera_device_info(app.pool(), cam).await.unwrap();
    assert_eq!(
        (info.0.as_deref(), info.1.as_deref(), info.2.as_deref()),
        (Some("Uniview"), Some("IPC2124"), Some("1.2.3"))
    );

    // 2. Omitting make/model/firmware (editing an unrelated field) leaves them.
    let resp = app
        .send(put_auth_json(
            &uri,
            &token,
            &serde_json::json!({ "name": "front-door" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let info = db::get_camera_device_info(app.pool(), cam).await.unwrap();
    assert_eq!(
        (info.0.as_deref(), info.1.as_deref(), info.2.as_deref()),
        (Some("Uniview"), Some("IPC2124"), Some("1.2.3")),
        "omitted device fields must stay unchanged"
    );

    // 3. Explicit null clears a column back to NULL.
    let resp = app
        .send(put_auth_json(
            &uri,
            &token,
            &serde_json::json!({ "make": null, "model": null, "firmware": null }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let info = db::get_camera_device_info(app.pool(), cam).await.unwrap();
    assert_eq!((info.0, info.1, info.2), (None, None, None));
}

#[tokio::test]
async fn manual_make_over_length_is_rejected() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let cam = seed_camera(app.pool()).await;
    let uri = format!("/config/cameras/{cam}");

    let too_long = "x".repeat(201);
    let resp = app
        .send(put_auth_json(
            &uri,
            &token,
            &serde_json::json!({ "make": too_long }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}
