// SPDX-License-Identifier: AGPL-3.0-or-later

//! `PUT /config/server` merge semantics (issue #472).
//!
//! The endpoint used to be a whole-row replace whose DTO carried
//! `#[serde(default)]`, so a partial programmatic body silently reset every
//! field it did not mention back to `""` (⇒ the container env fallback). This
//! suite pins the three states the request DTO now distinguishes:
//!
//! | Body | Meaning |
//! |---|---|
//! | key omitted / `null` | leave the stored column alone |
//! | `"value"` | set it |
//! | `""` | clear it ⇒ fall back to the container env |
//!
//! `""` deliberately stays a real, distinct state: Crumb's config precedence is
//! "admin-set DB value wins over env, EMPTY DB value falls back to env", so
//! clearing a field is the only way to undo a setting through the API.
//!
//! `docs/DECISIONS.md` (2026-08-06) records the alternatives that were rejected.
//!
//! # Concurrency
//!
//! `server_settings` is a singleton row. Every test here takes
//! [`SERVER_SETTINGS_LOCK`] so they cannot interleave with each other. The
//! columns they touch (`server_address`, the stream/Frigate bases, the motion
//! decode pair) are disjoint from the `thumb_*` / `beta_terms_*` columns the
//! scrub-preview and beta-terms tests in `auth_rbac.rs` mutate, so a
//! concurrently-running test BINARY cannot perturb these assertions either.

mod support;

use axum::body::to_bytes;
use axum::http::StatusCode;
use serde_json::{json, Value};
use support::*;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).expect("response body is JSON")
}

/// Every settable key, with a distinct recognizable value per field so a
/// cross-wired assignment shows up as a wrong value rather than a passing test.
fn full_body() -> Value {
    json!({
        "server_address":          "http://192.0.2.9:8080",
        "crumb_rtsp_base":         "rtsp://192.0.2.9:18554",
        "crumb_api_base":          "http://192.0.2.9:1984",
        "frigate_rtsp_base":       "rtsp://192.0.2.8:8554",
        "frigate_go2rtc_api_base": "http://192.0.2.8:1984",
        "frigate_http_api_base":   "http://192.0.2.8:5000",
        "motion_hwaccel":          "cpu",
        "motion_vaapi_device":     "/dev/dri/renderD128",
    })
}

/// Keys the DTO accepts and echoes back, in the order a caller thinks about
/// them. Used to assert "everything except X is untouched" without listing the
/// fields eight times.
const SETTABLE: [&str; 8] = [
    "server_address",
    "crumb_rtsp_base",
    "crumb_api_base",
    "frigate_rtsp_base",
    "frigate_go2rtc_api_base",
    "frigate_http_api_base",
    "motion_hwaccel",
    "motion_vaapi_device",
];

/// PUT the full baseline body and return the resulting settings DTO.
async fn seed_baseline(app: &TestApp, token: &str) -> Value {
    let resp = app
        .send(put_auth_json("/config/server", token, &full_body()))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "baseline PUT must succeed");
    body_json(resp).await
}

/// Assert every settable field except those in `except` is byte-identical
/// between two settings DTOs.
fn assert_unchanged_except(before: &Value, after: &Value, except: &[&str]) {
    for key in SETTABLE {
        if except.contains(&key) {
            continue;
        }
        assert_eq!(
            before[key], after[key],
            "field `{key}` must survive a body that never mentions it"
        );
    }
}

/// The bug: a partial body must not reset the fields it omits.
#[tokio::test]
async fn partial_put_preserves_unmentioned_fields() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let before = seed_baseline(&app, &token).await;

    // The exact shape a script would send to switch the decode backend.
    let resp = app
        .send(put_auth_json(
            "/config/server",
            &token,
            &json!({ "motion_hwaccel": "vaapi" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let after = body_json(resp).await;

    assert_eq!(after["motion_hwaccel"], "vaapi", "the one sent key applies");
    assert_unchanged_except(&before, &after, &["motion_hwaccel"]);

    // And it is actually persisted, not just echoed.
    let reread = body_json(app.send(get_auth("/config/server", &token)).await).await;
    assert_eq!(reread["motion_hwaccel"], "vaapi");
    assert_unchanged_except(&before, &reread, &["motion_hwaccel"]);
}

/// An explicit empty string is a CLEAR, not a no-op: that is how an operator
/// returns a setting to its container-environment default.
#[tokio::test]
async fn explicit_empty_string_clears_the_field() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let before = seed_baseline(&app, &token).await;
    assert_eq!(before["crumb_rtsp_base"], "rtsp://192.0.2.9:18554");

    let resp = app
        .send(put_auth_json(
            "/config/server",
            &token,
            &json!({ "crumb_rtsp_base": "" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let after = body_json(resp).await;

    assert_eq!(
        after["crumb_rtsp_base"], "",
        "an explicit \"\" must clear the column (⇒ env fallback), not merge away"
    );
    assert_unchanged_except(&before, &after, &["crumb_rtsp_base"]);
}

/// `null` is JSON's way of omitting a key; it must behave like omission, NOT
/// like `""`. Otherwise a client that spreads a partial object over defaults
/// would clear fields by accident.
#[tokio::test]
async fn explicit_null_behaves_like_an_omitted_key() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let before = seed_baseline(&app, &token).await;

    let resp = app
        .send(put_auth_json(
            "/config/server",
            &token,
            &json!({ "server_address": "http://192.0.2.11:8080", "crumb_rtsp_base": null }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let after = body_json(resp).await;

    assert_eq!(after["server_address"], "http://192.0.2.11:8080");
    assert_unchanged_except(&before, &after, &["server_address"]);
}

/// Regression guard for the console and first-run wizard, which both send a
/// COMPLETE body: the whole-row path must behave exactly as it did before the
/// DTO changed.
#[tokio::test]
async fn full_row_put_is_unchanged() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // Start from a different row so "unchanged" can't pass vacuously.
    seed_baseline(&app, &token).await;

    let body = json!({
        "server_address":          "http://192.0.2.20:8080",
        "crumb_rtsp_base":         "rtsp://192.0.2.20:18554",
        "crumb_api_base":          "http://192.0.2.20:1984",
        "frigate_rtsp_base":       "",
        "frigate_go2rtc_api_base": "",
        "frigate_http_api_base":   "",
        "motion_hwaccel":          "auto",
        "motion_vaapi_device":     "",
    });
    let resp = app
        .send(put_auth_json("/config/server", &token, &body))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let after = body_json(resp).await;

    for key in SETTABLE {
        assert_eq!(
            after[key], body[key],
            "a full-row PUT must write `{key}` verbatim, including empties"
        );
    }
}

/// A partial PUT still bumps `version`, so the recorder and clients re-read.
#[tokio::test]
async fn partial_put_still_bumps_the_version_counter() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let before = seed_baseline(&app, &token).await;
    let v0 = before["version"].as_i64().expect("version is an integer");

    let resp = app
        .send(put_auth_json(
            "/config/server",
            &token,
            &json!({ "motion_vaapi_device": "/dev/dri/renderD129" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let after = body_json(resp).await;

    assert_eq!(after["version"].as_i64(), Some(v0 + 1));
    assert_eq!(after["motion_vaapi_device"], "/dev/dri/renderD129");
}

/// An empty body `{}` is a legal no-op merge: nothing changes but the version.
#[tokio::test]
async fn empty_body_changes_nothing_but_the_version() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let before = seed_baseline(&app, &token).await;

    let resp = app
        .send(put_auth_json("/config/server", &token, &json!({})))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let after = body_json(resp).await;

    assert_unchanged_except(&before, &after, &[]);
    assert_eq!(
        after["version"].as_i64(),
        before["version"].as_i64().map(|v| v + 1)
    );
}
