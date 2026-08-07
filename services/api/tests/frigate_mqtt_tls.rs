// SPDX-License-Identifier: AGPL-3.0-or-later

//! `PUT /config/frigate` + `POST /config/frigate/test` must refuse a
//! TLS-implying broker URL (issue #477).
//!
//! Crumb pins `rumqttc` with `default-features = false`, so no TLS transport is
//! compiled in at all. The old behavior accepted `mqtts://`, stripped the
//! scheme, and connected in cleartext — the operator believed their broker
//! credentials were encrypted and they were not. `docs/DECISIONS.md`
//! (2026-08-06) records why the fix is a loud rejection rather than switching
//! rumqttc's rustls feature back on.
//!
//! These tests cover the CONFIG-TIME half of the guard. The connect-time half
//! (both `parse_mqtt_url()` helpers) is unit-tested in
//! `services/api/src/detection/frigate.rs` and
//! `services/recorder/src/frigate_motion.rs`; the guard itself in
//! `services/common/src/mqtt.rs`.

mod support;

use axum::body::to_bytes;
use axum::http::StatusCode;
use support::*;

async fn body_text(resp: axum::http::Response<axum::body::Body>) -> String {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The `frigate_config` singleton is seeded at runtime by
/// `ensure_frigate_config_table` (deliberately NOT by a migration, so the
/// env-driven seed wins on a fresh boot). The test DB has only the migrations,
/// so seed the row the same way the shim does.
async fn ensure_frigate_row(app: &TestApp) {
    crumb_common::db::ensure_frigate_config_table(app.pool())
        .await
        .expect("ensure_frigate_config_table");
}

fn frigate_body(url: &str) -> serde_json::Value {
    serde_json::json!({
        "enabled": false,
        "mqtt_url": url,
        "mqtt_prefix": "frigate",
        "api_base": "",
        "min_score": 0.3,
        "catchup_hours": 24,
    })
}

#[tokio::test]
async fn put_config_frigate_rejects_mqtts_url() {
    let app = TestApp::new().await;
    ensure_frigate_row(&app).await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(put_auth_json(
            "/config/frigate",
            &token,
            &frigate_body("mqtts://broker.example:8883"),
        ))
        .await;

    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "mqtts:// must be refused, not stored and connected in the clear"
    );
    let body = body_text(resp).await;
    assert!(
        body.contains("TLS MQTT is not yet supported"),
        "the 400 must tell the operator what to do; got: {body}"
    );
}

/// The guard runs even with `enabled: false` — otherwise a URL saved while the
/// integration is off would silently downgrade the moment it is switched on.
#[tokio::test]
async fn put_config_frigate_rejects_ssl_scheme_while_disabled() {
    let app = TestApp::new().await;
    ensure_frigate_row(&app).await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let mut body = frigate_body("ssl://broker.example:8883");
    body["enabled"] = serde_json::Value::Bool(false);

    let resp = app
        .send(put_auth_json("/config/frigate", &token, &body))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// Control: a plaintext URL still saves exactly as before. Without this the
/// rejection tests could pass against a route that 400s on everything.
#[tokio::test]
async fn put_config_frigate_accepts_plaintext_mqtt_url() {
    let app = TestApp::new().await;
    ensure_frigate_row(&app).await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(put_auth_json(
            "/config/frigate",
            &token,
            &frigate_body("mqtt://broker.example:1883"),
        ))
        .await;

    assert_eq!(resp.status(), StatusCode::OK, "plaintext mqtt:// must save");
    let body = body_text(resp).await;
    assert!(
        body.contains("mqtt://broker.example:1883"),
        "the saved row should echo the URL back; got: {body}"
    );
}

/// The reachability probe is a bare TCP connect, so for a `mqtts://` URL it
/// would happily answer "Reachable" for a link Crumb refuses to make. It must
/// report the unsupported scheme instead.
#[tokio::test]
async fn test_config_frigate_reports_tls_scheme_instead_of_probing() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(post_auth_json(
            "/config/frigate/test",
            &token,
            &frigate_body("mqtts://broker.example:8883"),
        ))
        .await;

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_text(resp).await;
    assert!(
        body.contains("\"ok\":false") && body.contains("TLS MQTT is not yet supported"),
        "the probe must report the unsupported scheme; got: {body}"
    );
}
