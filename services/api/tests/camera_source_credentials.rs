// SPDX-License-Identifier: AGPL-3.0-or-later

//! Camera source URLs mask their password on the way out, and a masked value
//! sent back on `PUT` keeps the stored credential.
//!
//! `source_url` / `source_sub_url` carry the camera's own `user:pass@`
//! credentials inline. `onvif_password` has always been write-only, but these
//! two were returned in clear to every admin session. They now round-trip
//! through the same contract as the ONVIF password: the API hands out a masked
//! value, sending it back unchanged keeps what is stored, and sending a
//! different password replaces it.
//!
//! Same harness as the rest of the suite: `tests/support` re-includes the real
//! `src/` modules, so these drive the actual handlers and read the actual row
//! back out of the database.

mod support;

use axum::http::StatusCode;
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db;
use crumb_common::redact::CREDENTIAL_MASK;

use support::{login, seed_admin, unique, TestApp};

const MAIN_PASSWORD: &str = "hunter2-main";
const SUB_PASSWORD: &str = "hunter2-sub";

fn main_url_with(password: &str) -> String {
    format!("rtsp://cam-operator:{password}@198.51.100.9:554/Streaming/Channels/101")
}

fn sub_url_with(password: &str) -> String {
    format!("rtsp://cam-operator:{password}@198.51.100.9:554/Streaming/Channels/102")
}

/// Seed a Crumb-managed camera whose source URLs carry credentials.
async fn seed_credentialed_camera(pool: &Pool) -> Uuid {
    let name = unique("credcam");
    let go2rtc_name = unique("credstream");
    let policy_id = db::get_default_policy(pool)
        .await
        .expect("get_default_policy")
        .id;
    let main = main_url_with(MAIN_PASSWORD);
    let sub = sub_url_with(SUB_PASSWORD);
    let restream_sub = format!("{go2rtc_name}_sub");
    let params = db::CreateCameraParams {
        name: &name,
        go2rtc_name: &go2rtc_name,
        main_url: &go2rtc_name,
        sub_url: Some(&restream_sub),
        source_url: Some(&main),
        source_sub_url: Some(&sub),
        enabled: true,
        policy_id,
        motion_mask: None,
        onvif_motion: false,
        motion_source: "pixel",
        motion_algorithm: "census",
        camera_type: None,
        icon: None,
        served_by: "crumb",
        source_camera_name: None,
        onvif_host: None,
        onvif_port: None,
        onvif_user: None,
        onvif_password: None,
        ptz_control_enabled: true,
    };
    db::create_camera(pool, &params)
        .await
        .expect("create_camera")
        .id
}

/// The `source_url` / `source_sub_url` actually stored in the database.
async fn stored_sources(pool: &Pool, id: Uuid) -> (String, String) {
    let cam = db::get_camera(pool, id)
        .await
        .expect("get_camera")
        .expect("camera row");
    (
        cam.source_url.expect("source_url stored"),
        cam.source_sub_url.expect("source_sub_url stored"),
    )
}

async fn get_camera_dto(app: &TestApp, token: &str, id: Uuid) -> serde_json::Value {
    let resp = app
        .send(
            axum::http::Request::builder()
                .method("GET")
                .uri(format!("/config/cameras/{id}"))
                .header("authorization", format!("Bearer {token}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "GET /config/cameras/:id");
    let bytes = axum::body::to_bytes(resp.into_body(), 1 << 20)
        .await
        .expect("read camera body");
    serde_json::from_slice(&bytes).expect("camera JSON")
}

async fn put_camera(
    app: &TestApp,
    token: &str,
    id: Uuid,
    body: serde_json::Value,
) -> axum::http::Response<axum::body::Body> {
    app.send(
        axum::http::Request::builder()
            .method("PUT")
            .uri(format!("/config/cameras/{id}"))
            .header("authorization", format!("Bearer {token}"))
            .header("content-type", "application/json")
            .body(axum::body::Body::from(body.to_string()))
            .unwrap(),
    )
    .await
}

#[tokio::test]
async fn get_masks_the_password_and_flags_that_one_is_stored() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let id = seed_credentialed_camera(app.pool()).await;

    let dto = get_camera_dto(&app, &token, id).await;
    let main = dto["source_url"].as_str().expect("source_url present");
    let sub = dto["source_sub_url"]
        .as_str()
        .expect("source_sub_url present");

    assert!(!main.contains(MAIN_PASSWORD), "password returned: {main}");
    assert!(!sub.contains(SUB_PASSWORD), "password returned: {sub}");
    assert_eq!(main, main_url_with(CREDENTIAL_MASK));
    assert_eq!(sub, sub_url_with(CREDENTIAL_MASK));
    // Everything but the password is verbatim, so the operator still recognises
    // and can edit the URL.
    assert!(main.starts_with("rtsp://cam-operator:"), "{main}");
    assert!(main.ends_with("@198.51.100.9:554/Streaming/Channels/101"), "{main}");

    assert_eq!(dto["source_has_credentials"], serde_json::json!(true));
    assert_eq!(dto["source_sub_has_credentials"], serde_json::json!(true));

    // The list endpoint masks identically (it shares camera_to_dto).
    let resp = app
        .send(
            axum::http::Request::builder()
                .method("GET")
                .uri("/config/cameras")
                .header("authorization", format!("Bearer {token}"))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(resp.into_body(), 8 << 20)
        .await
        .expect("read list body");
    let text = String::from_utf8_lossy(&bytes);
    assert!(
        !text.contains(MAIN_PASSWORD) && !text.contains(SUB_PASSWORD),
        "GET /config/cameras returned a camera password"
    );
}

#[tokio::test]
async fn putting_the_masked_url_back_keeps_the_stored_credentials() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let id = seed_credentialed_camera(app.pool()).await;

    // Read it the way the console does, then send the same values back with an
    // unrelated edit (a rename), which is exactly what "Save" does.
    let dto = get_camera_dto(&app, &token, id).await;
    let renamed = unique("renamed");
    let resp = put_camera(
        &app,
        &token,
        id,
        serde_json::json!({
            "name": renamed,
            "source_url": dto["source_url"],
            "source_sub_url": dto["source_sub_url"],
        }),
    )
    .await;
    assert_eq!(resp.status(), StatusCode::OK, "PUT /config/cameras/:id");

    // The rename applied ...
    let after = get_camera_dto(&app, &token, id).await;
    assert_eq!(after["name"].as_str(), Some(renamed.as_str()));
    // ... and the credentials in the DATABASE are untouched (not the mask).
    let (main, sub) = stored_sources(app.pool(), id).await;
    assert_eq!(main, main_url_with(MAIN_PASSWORD));
    assert_eq!(sub, sub_url_with(SUB_PASSWORD));
    assert!(!main.contains(CREDENTIAL_MASK), "the mask was stored: {main}");
    assert!(!sub.contains(CREDENTIAL_MASK), "the mask was stored: {sub}");
}

#[tokio::test]
async fn editing_the_url_around_the_mask_keeps_the_credentials() {
    // The operator retypes the host or path but leaves the masked password
    // alone: the new URL is stored, with the old password spliced back in.
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let id = seed_credentialed_camera(app.pool()).await;

    let moved =
        format!("rtsp://cam-operator:{CREDENTIAL_MASK}@198.51.100.40:554/Streaming/Channels/101");
    let resp = put_camera(&app, &token, id, serde_json::json!({ "source_url": moved })).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let (main, _) = stored_sources(app.pool(), id).await;
    assert_eq!(
        main,
        format!("rtsp://cam-operator:{MAIN_PASSWORD}@198.51.100.40:554/Streaming/Channels/101")
    );
}

#[tokio::test]
async fn a_new_password_replaces_the_stored_one() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let id = seed_credentialed_camera(app.pool()).await;

    let rotated = main_url_with("rotated-password");
    let resp = put_camera(
        &app,
        &token,
        id,
        serde_json::json!({ "source_url": rotated.clone() }),
    )
    .await;
    assert_eq!(resp.status(), StatusCode::OK);

    let (main, sub) = stored_sources(app.pool(), id).await;
    assert_eq!(main, rotated, "a typed password must be taken literally");
    assert_eq!(
        sub,
        sub_url_with(SUB_PASSWORD),
        "an untouched sub stream keeps its own credential"
    );
}
