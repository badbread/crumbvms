// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for the Notifications-pane redesign (WU-1 + WU-4 server
//! halves):
//!
//! * **Quiet-hours range validation** — a whole-hour quiet-hours value must be
//!   in `0..=23`. Before this, a bad value like `2200` (military time pasted
//!   into the old number input) was stored verbatim and only clamped at read
//!   time to a zero-width window, so quiet hours silently never fired. Both the
//!   per-user rules endpoint and the admin system-alerts settings endpoint are
//!   covered.
//! * **Admin lists ALL channels with owner attribution** — the engine fans out
//!   to every enabled channel regardless of owner, but the console previously
//!   listed only the caller's own + global channels, hiding a channel created
//!   under another account. An admin must now see every channel with the
//!   owner's username; a non-admin still sees only their own.
//! * **Global-flag round-trip on update** — `ChannelResponse` exposes `global`,
//!   and toggling it on an update actually persists (`user_id = NULL`). A
//!   non-admin may not change a channel's global scope (403).
//!
//! Same harness as `notification_channel_rbac.rs`: `tests/support` re-includes
//! the real `src/` modules so these exercise the actual handlers.
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::too_many_lines)]

mod support;

use axum::http::StatusCode;
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db;

use support::*;

/// Read a response body into a JSON value.
async fn into_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .expect("read body");
    serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
}

/// Create a channel owned by `user_id` (or global when `None`) directly in the
/// DB, bypassing the create handler so the test controls ownership precisely.
async fn seed_channel(pool: &Pool, user_id: Option<Uuid>, name: &str) -> Uuid {
    db::create_notification_channel(
        pool,
        &db::CreateChannelParams {
            user_id,
            kind: "webhook".to_owned(),
            name: name.to_owned(),
            enabled: true,
            config: serde_json::json!({}),
            camera_ids: None,
            snapshot_mode: db::SnapshotMode::None,
        },
    )
    .await
    .expect("seed channel")
    .id
}

// ─── quiet-hours validation ──────────────────────────────────────────────────

#[tokio::test]
async fn rule_quiet_hours_out_of_range_is_rejected() {
    let app = TestApp::new().await;
    let user = seed_viewer(app.pool(), &[]).await;
    let token = login(&app, &user.username, &user.password).await;

    // 2200 (military time) must be rejected, not stored + clamped.
    for bad in [2200, 24, -1, 700] {
        let body = serde_json::json!({ "quiet_start_hour": bad, "quiet_end_hour": 7 });
        let resp = app
            .send(put_auth_json("/notifications/rules", &token, &body))
            .await;
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "quiet_start_hour={bad} must be rejected"
        );
    }

    // The end hour is validated too.
    let body = serde_json::json!({ "quiet_start_hour": 22, "quiet_end_hour": 99 });
    let resp = app
        .send(put_auth_json("/notifications/rules", &token, &body))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "quiet_end_hour=99");

    // Valid whole-hour windows (including the 0 and 23 boundaries) are accepted.
    for (s, e) in [(22, 7), (0, 23), (23, 0)] {
        let body = serde_json::json!({ "quiet_start_hour": s, "quiet_end_hour": e });
        let resp = app
            .send(put_auth_json("/notifications/rules", &token, &body))
            .await;
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "quiet hours {s}..{e} must be accepted"
        );
    }

    // Absent quiet hours (unset) is always valid.
    let body = serde_json::json!({ "presence_mode": "always" });
    let resp = app
        .send(put_auth_json("/notifications/rules", &token, &body))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "unset quiet hours is valid");
}

#[tokio::test]
async fn system_alert_quiet_hours_out_of_range_is_rejected() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let bad = serde_json::json!({
        "enabled": true,
        "system_quiet_start_hour": 2200,
        "system_quiet_end_hour": 7,
    });
    let resp = app
        .send(put_auth_json("/notifications/settings", &token, &bad))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "system_quiet_start_hour=2200 must be rejected"
    );

    let ok = serde_json::json!({
        "enabled": true,
        "system_quiet_start_hour": 0,
        "system_quiet_end_hour": 23,
    });
    let resp = app
        .send(put_auth_json("/notifications/settings", &token, &ok))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "a valid 0..23 system quiet-hours window must be accepted"
    );
}

// ─── admin lists all channels with owner attribution ─────────────────────────

#[tokio::test]
async fn admin_lists_all_channels_with_owner_attribution() {
    let app = TestApp::new().await;
    let pool = app.pool();

    let admin = seed_admin(pool).await;
    let viewer = seed_viewer(pool, &[]).await;

    let owned_by_viewer = seed_channel(pool, Some(viewer.user_id), &unique("viewer-ch")).await;
    let global_ch = seed_channel(pool, None, &unique("global-ch")).await;

    // Admin: sees BOTH, the foreign one attributed to its owner.
    let atok = login(&app, &admin.username, &admin.password).await;
    let list = into_json(app.send(get_auth("/notifications/channels", &atok)).await).await;
    let arr = list.as_array().expect("channels array");

    let vrow = arr
        .iter()
        .find(|c| c["id"].as_str() == Some(&owned_by_viewer.to_string()))
        .expect("admin must see the viewer-owned channel");
    assert_eq!(
        vrow["global"].as_bool(),
        Some(false),
        "an owned channel is not global"
    );
    assert_eq!(
        vrow["owner_username"].as_str(),
        Some(viewer.username.as_str()),
        "the foreign channel must carry its owner's username"
    );

    let grow = arr
        .iter()
        .find(|c| c["id"].as_str() == Some(&global_ch.to_string()))
        .expect("admin must see the global channel");
    assert_eq!(grow["global"].as_bool(), Some(true), "global flag set");

    // Non-admin: sees ONLY their own channel, never the global one.
    let vtok = login(&app, &viewer.username, &viewer.password).await;
    let vlist = into_json(app.send(get_auth("/notifications/channels", &vtok)).await).await;
    let varr = vlist.as_array().expect("channels array");
    assert!(
        varr.iter()
            .any(|c| c["id"].as_str() == Some(&owned_by_viewer.to_string())),
        "a non-admin sees their own channel"
    );
    assert!(
        !varr
            .iter()
            .any(|c| c["id"].as_str() == Some(&global_ch.to_string())),
        "a non-admin must not see a global channel in this listing"
    );
}

// ─── global-flag round-trip on update + RBAC ─────────────────────────────────

#[tokio::test]
async fn admin_can_toggle_global_and_it_round_trips() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // Create an OWNED channel (global:false) as the admin.
    let create = serde_json::json!({
        "kind": "webhook",
        "name": unique("toggle-ch"),
        "config": {},
        "global": false,
    });
    let resp = app
        .send(post_auth_json("/notifications/channels", &token, &create))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let created = into_json(resp).await;
    assert_eq!(created["global"].as_bool(), Some(false));
    let id = created["id"].as_str().expect("id").to_owned();

    // Toggle global ON via update.
    let upd = serde_json::json!({ "global": true });
    let resp = app
        .send(put_auth_json(
            &format!("/notifications/channels/{id}"),
            &token,
            &upd,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let updated = into_json(resp).await;
    assert_eq!(
        updated["global"].as_bool(),
        Some(true),
        "the update response reflects the new global flag"
    );
    assert!(
        updated["user_id"].is_null(),
        "a global channel has no owner (user_id NULL)"
    );

    // Read it back through the admin listing: still global.
    let list = into_json(app.send(get_auth("/notifications/channels", &token)).await).await;
    let row = list
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"].as_str() == Some(id.as_str()))
        .expect("channel present");
    assert_eq!(
        row["global"].as_bool(),
        Some(true),
        "global flag persisted across a reload"
    );
}

/// #600: unchecking **Enabled** on the CREATE form must produce a disabled
/// channel. `CreateChannelRequest` had no `enabled` field, so serde dropped it
/// and create hardcoded `enabled: true`. Now the field is honored on create, and
/// an absent `enabled` still defaults to true (legacy clients are unchanged).
#[tokio::test]
async fn create_honors_enabled_false_and_defaults_true() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // enabled:false on create -> the channel is created disabled.
    let create = serde_json::json!({
        "kind": "webhook",
        "name": unique("disabled-ch"),
        "config": {},
        "enabled": false,
    });
    let resp = app
        .send(post_auth_json("/notifications/channels", &token, &create))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let created = into_json(resp).await;
    assert_eq!(
        created["enabled"].as_bool(),
        Some(false),
        "enabled:false on create must be honored (#600), not forced true"
    );
    let disabled_id = created["id"].as_str().expect("id").to_owned();

    // Absent enabled -> defaults to true (the common case / legacy clients).
    let create_default =
        serde_json::json!({ "kind": "webhook", "name": unique("default-ch"), "config": {} });
    let resp = app
        .send(post_auth_json(
            "/notifications/channels",
            &token,
            &create_default,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let created_default = into_json(resp).await;
    assert_eq!(
        created_default["enabled"].as_bool(),
        Some(true),
        "an absent enabled still defaults to true"
    );

    // The disabled channel stays disabled across a reload.
    let list = into_json(app.send(get_auth("/notifications/channels", &token)).await).await;
    let row = list
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"].as_str() == Some(disabled_id.as_str()))
        .expect("channel present");
    assert_eq!(
        row["enabled"].as_bool(),
        Some(false),
        "disabled-on-create persisted across a reload"
    );
}

#[tokio::test]
async fn non_admin_cannot_toggle_global() {
    let app = TestApp::new().await;
    let viewer = seed_viewer(app.pool(), &[]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    // Viewer creates their own channel (global is hidden for them; server
    // ignores it on create for non-admins anyway).
    let create = serde_json::json!({ "kind": "webhook", "name": unique("v-ch"), "config": {} });
    let resp = app
        .send(post_auth_json("/notifications/channels", &token, &create))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let id = into_json(resp).await["id"].as_str().unwrap().to_owned();

    // Attempting to promote it to global must be rejected.
    let upd = serde_json::json!({ "global": true });
    let resp = app
        .send(put_auth_json(
            &format!("/notifications/channels/{id}"),
            &token,
            &upd,
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "a non-admin must not change a channel's global scope"
    );
}
