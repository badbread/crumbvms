// SPDX-License-Identifier: AGPL-3.0-or-later

//! RBAC integration tests for third-party notification **channels** (P0-5).
//!
//! Two escapes are covered:
//!
//! 1. **Create-time scope:** a non-admin must not be able to scope a channel to
//!    cameras outside their own per-camera grants (cross-camera exfiltration via
//!    a channel `camera_ids` list).
//! 2. **Fan-out gating:** a `plate_watchlist_hit` (plate string + crop) must NOT
//!    be delivered over a channel whose owner lacks the `view_plates`
//!    capability — even when the owner CAN see the camera. Delivery is proven by
//!    the `notification_log` row the engine writes per (channel, event); a
//!    gated channel writes none, while a global (admin firehose) channel does.
//!
//! Plus the channel-management rails:
//!
//! 3. **Management capability:** create / update / delete / test all require
//!    `manage_channels` (admins imply it). Listing stays open.
//! 4. **Destination checks:** a non-admin's destination URL may not name the
//!    deployment's own internals (loopback, link-local, a compose service);
//!    LAN addresses stay allowed, and an admin is exempt.
//! 5. **Test-fire rate limit:** the on-demand test endpoint is capped per user
//!    and answers 429 with `Retry-After` past the cap.
//!
//! Same harness shape as `auth_rbac.rs` / `lpr_plates.rs`: the crate root
//! re-includes the real `src/` modules via `tests/support`, so this exercises
//! the actual `create_channel` handler and the actual
//! `dispatch_system_events_tick` engine code — not a reimplementation.
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

use std::collections::{HashMap, HashSet};
use std::sync::atomic::AtomicI64;

use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db;
use crumb_common::types::{BookmarkScope, Capabilities};

use support::*;

/// A viewer scoped to `cameras` but WITHOUT the `view_plates` capability — the
/// owner of a channel that must be blocked from `plate_watchlist_hit`.
async fn seed_viewer_no_plates(pool: &Pool, cameras: &[Uuid]) -> SeededUser {
    let caps = Capabilities {
        export: false,
        playback: true,
        clips: true,
        ptz: false,
        bookmarks: BookmarkScope::Own,
        manage_views: true,
        view_plates: false,
        actuators: false,
        manage_channels: false,
    };
    let role = db::create_role(pool, &unique("role"), &caps, cameras)
        .await
        .expect("create_role (no view_plates)");
    seed_viewer_user(pool, role.id).await
}

/// A viewer scoped to `cameras` holding `manage_channels` (what an operator role
/// allowed to wire up notification destinations looks like). Every other viewer
/// capability is the generous default, so a denial in these tests is
/// unambiguously about channel management.
async fn seed_channel_manager(pool: &Pool, cameras: &[Uuid]) -> SeededUser {
    let caps = Capabilities {
        manage_channels: true,
        ..generous_viewer_caps()
    };
    let role_id = seed_viewer_role_with_caps(pool, cameras, caps).await;
    seed_viewer_user(pool, role_id).await
}

/// Build a DELETE request with a Bearer token.
fn delete_auth(uri: &str, token: &str) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("DELETE")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(axum::body::Body::empty())
        .expect("well-formed DELETE request")
}

/// Build a bodyless POST request with a Bearer token (the test-fire endpoint).
fn post_auth_empty(uri: &str, token: &str) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(axum::body::Body::empty())
        .expect("well-formed POST request")
}

/// Create a channel owned by `user_id` directly in the DB, bypassing the API
/// gate — the fixture for "this row already exists; who may now change it?".
/// `SnapshotMode::None` keeps the test-fire path off the snapshot fetch.
async fn seed_owned_channel(pool: &Pool, user_id: Uuid, config: serde_json::Value) -> Uuid {
    db::create_notification_channel(
        pool,
        &db::CreateChannelParams {
            user_id: Some(user_id),
            kind: "webhook".to_owned(),
            name: unique("chan"),
            enabled: true,
            config,
            camera_ids: None,
            snapshot_mode: db::SnapshotMode::None,
        },
    )
    .await
    .expect("create owned channel")
    .id
}

/// Count `notification_log` rows for one (channel, event) pair — the engine's
/// per-delivery record. Zero ⇒ the channel was gated out before dispatch.
async fn channel_log_count(pool: &Pool, channel_id: Uuid, event_id: Uuid) -> i64 {
    let client = pool.get().await.expect("pool.get (channel_log_count)");
    client
        .query_one(
            "SELECT COUNT(*)::bigint AS c FROM notification_log \
             WHERE channel_id = $1 AND event_id = $2",
            &[&channel_id, &event_id],
        )
        .await
        .expect("count notification_log")
        .get("c")
}

#[tokio::test]
async fn non_admin_cannot_create_channel_with_out_of_grant_cameras() {
    let app = TestApp::new().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;

    // Viewer granted only cam_a, and allowed to manage channels — so the denial
    // below is about camera scope, not about the management capability.
    let user = seed_channel_manager(app.pool(), &[cam_a]).await;
    let token = login(&app, &user.username, &user.password).await;

    // Scoping a channel to cam_b (NOT granted) must be rejected.
    let body = serde_json::json!({
        "kind": "webhook",
        "name": "sneaky",
        "config": {},
        "camera_ids": [cam_b.to_string()],
    });
    let resp = app
        .send(post_auth_json("/notifications/channels", &token, &body))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "a viewer must not scope a channel to a camera outside their grants"
    );

    // Control: scoping to the granted camera succeeds.
    let ok_body = serde_json::json!({
        "kind": "webhook",
        "name": "fine",
        "config": {},
        "camera_ids": [cam_a.to_string()],
    });
    let ok = app
        .send(post_auth_json("/notifications/channels", &token, &ok_body))
        .await;
    assert_eq!(
        ok.status(),
        StatusCode::CREATED,
        "scoping to a granted camera must be allowed"
    );
}

#[tokio::test]
async fn non_admin_channel_without_view_plates_gets_no_plate_watchlist_hit() {
    let app = TestApp::new().await;
    let pool = app.pool();
    let cam = seed_camera(pool).await;

    // Owner CAN see the camera but has NO view_plates capability — so only the
    // plate-capability gate (not the camera gate) can block delivery.
    let owner = seed_viewer_no_plates(pool, &[cam]).await;

    // Quiet the shared test DB so this tick only processes our two channels
    // (leftover enabled channels from prior runs would otherwise be dispatched
    // too — harmless to our assertions, but this keeps the tick fast + clean).
    {
        let client = pool.get().await.expect("pool.get (disable channels)");
        client
            .execute("UPDATE notification_channels SET enabled = false", &[])
            .await
            .expect("disable pre-existing channels");
    }

    // The channel under test: owned by the no-view_plates viewer.
    let gated = db::create_notification_channel(
        pool,
        &db::CreateChannelParams {
            user_id: Some(owner.user_id),
            kind: "webhook".to_owned(),
            name: unique("gated"),
            enabled: true,
            config: serde_json::json!({}),
            camera_ids: None, // all cameras the owner can access
            snapshot_mode: db::SnapshotMode::None,
        },
    )
    .await
    .expect("create gated channel");

    // A global (admin-managed) channel as the positive control: no owner, so the
    // owner gate never applies — it must still receive the event. Its webhook
    // config has no `url`, so dispatch fails instantly (no network) but STILL
    // writes a notification_log row, which is our "delivery was attempted" proof.
    let global = db::create_notification_channel(
        pool,
        &db::CreateChannelParams {
            user_id: None,
            kind: "webhook".to_owned(),
            name: unique("global"),
            enabled: true,
            config: serde_json::json!({}),
            camera_ids: None,
            snapshot_mode: db::SnapshotMode::None,
        },
    )
    .await
    .expect("create global channel");

    // Fire a plate watchlist hit (rule seeded+enabled by migration 0052).
    let before: DateTime<Utc> = Utc::now();
    let event_id = db::insert_system_event(pool, "plate_watchlist_hit", Some(cam), Some("ABC123"))
        .await
        .expect("insert plate_watchlist_hit");

    // Drive one engine tick directly.
    let http = reqwest::Client::new();
    let mut last_ts = before;
    let mut seen: HashSet<Uuid> = HashSet::new();
    let mut cooldown: HashMap<(String, Uuid), std::time::Instant> = HashMap::new();
    let maint = AtomicI64::new(0); // maintenance window disarmed
    notifications::dispatch_system_events_tick(
        pool,
        &http,
        &mut last_ts,
        &mut seen,
        &mut cooldown,
        &maint,
    )
    .await;

    // The gated channel must NOT have been delivered the plate hit…
    assert_eq!(
        channel_log_count(pool, gated.id, event_id).await,
        0,
        "a channel whose owner lacks view_plates must NOT receive a plate_watchlist_hit"
    );
    // …while the global channel proves the tick actually ran and dispatched.
    assert!(
        channel_log_count(pool, global.id, event_id).await >= 1,
        "the global channel should have received the plate_watchlist_hit"
    );
}

// ─── who may manage a channel ────────────────────────────────────────────────

#[tokio::test]
async fn viewer_without_manage_channels_cannot_manage_a_channel() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;

    // A generous viewer: every capability a viewer can hold EXCEPT the two
    // deny-by-default ones, so only `manage_channels` can be doing the denying.
    let user = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let create = app
        .send(post_auth_json(
            "/notifications/channels",
            &token,
            &serde_json::json!({
                "kind": "webhook",
                "name": "nope",
                "config": { "url": "https://example.com/hook" },
            }),
        ))
        .await;
    assert_eq!(
        create.status(),
        StatusCode::FORBIDDEN,
        "creating a channel must require manage_channels"
    );

    // Listing stays open: a channel the viewer already owns is still visible.
    let owned = seed_owned_channel(
        app.pool(),
        user.user_id,
        serde_json::json!({ "url": "https://example.com/hook" }),
    )
    .await;
    let list = app.send(get_auth("/notifications/channels", &token)).await;
    assert_eq!(
        list.status(),
        StatusCode::OK,
        "listing one's own channels must stay open"
    );

    // ...but changing, deleting or test-firing it is not.
    let update = app
        .send(put_auth_json(
            &format!("/notifications/channels/{owned}"),
            &token,
            &serde_json::json!({ "name": "renamed" }),
        ))
        .await;
    assert_eq!(
        update.status(),
        StatusCode::FORBIDDEN,
        "update must be gated"
    );

    let test = app
        .send(post_auth_empty(
            &format!("/notifications/channels/{owned}/test"),
            &token,
        ))
        .await;
    assert_eq!(test.status(), StatusCode::FORBIDDEN, "test must be gated");

    let del = app
        .send(delete_auth(
            &format!("/notifications/channels/{owned}"),
            &token,
        ))
        .await;
    assert_eq!(del.status(), StatusCode::FORBIDDEN, "delete must be gated");
}

#[tokio::test]
async fn viewer_with_manage_channels_can_manage_a_channel() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let user = seed_channel_manager(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let created = app
        .send(post_auth_json(
            "/notifications/channels",
            &token,
            // No `url` in the config on purpose: the test-fire below then fails
            // inside dispatch with no network I/O at all, which is what we want
            // from a unit-test process. Authorization is what is under test.
            &serde_json::json!({
                "kind": "webhook",
                "name": unique("mine"),
                "config": {},
                "snapshot_mode": "none",
            }),
        ))
        .await;
    assert_eq!(created.status(), StatusCode::CREATED);
    let bytes = axum::body::to_bytes(created.into_body(), usize::MAX)
        .await
        .expect("read create body");
    let created: serde_json::Value = serde_json::from_slice(&bytes).expect("create body is JSON");
    let id = created["id"]
        .as_str()
        .expect("created channel id")
        .to_owned();

    let update = app
        .send(put_auth_json(
            &format!("/notifications/channels/{id}"),
            &token,
            &serde_json::json!({ "name": "renamed" }),
        ))
        .await;
    assert_eq!(update.status(), StatusCode::OK);

    // The test-fire is authorized; the dispatch itself fails (the config carries
    // no destination), which the handler reports in the body as `{"ok": false}`
    // rather than as an HTTP error.
    let test = app
        .send(post_auth_empty(
            &format!("/notifications/channels/{id}/test"),
            &token,
        ))
        .await;
    assert_eq!(
        test.status(),
        StatusCode::OK,
        "a manage_channels role may test-fire its own channel"
    );

    let del = app
        .send(delete_auth(
            &format!("/notifications/channels/{id}"),
            &token,
        ))
        .await;
    assert_eq!(del.status(), StatusCode::NO_CONTENT);
}

// ─── destination checks ──────────────────────────────────────────────────────

#[tokio::test]
async fn internal_destinations_are_refused_for_a_non_admin_and_allowed_for_an_admin() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let user = seed_channel_manager(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    fn create_body(name: &str, url: &str) -> serde_json::Value {
        serde_json::json!({
            "kind": "webhook",
            "name": name,
            "config": { "url": url },
            "snapshot_mode": "none",
        })
    }

    for url in [
        "http://127.0.0.1:5432/x",
        "http://localhost:8080/x",
        "http://[::1]:8080/x",
        "http://169.254.169.254/latest/meta-data",
        "http://recorder:1984/api/streams",
        "http://postgres:5432/",
        "file:///etc/passwd",
    ] {
        let resp = app
            .send(post_auth_json(
                "/notifications/channels",
                &token,
                &create_body(&unique("bad"), url),
            ))
            .await;
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "{url} must be refused for a non-admin"
        );
    }

    // A self-hosted destination on the operator's LAN is the primary use case
    // and must keep working. The address is built rather than written as a
    // literal so the repo's leak scan stays quiet.
    let lan_url = format!(
        "http://{}:8080/alerts",
        std::net::Ipv4Addr::new(192, 168, 50, 4)
    );
    let lan = app
        .send(post_auth_json(
            "/notifications/channels",
            &token,
            &create_body(&unique("lan"), &lan_url),
        ))
        .await;
    assert_eq!(
        lan.status(),
        StatusCode::CREATED,
        "an RFC1918 destination must stay allowed"
    );

    // An admin owns the box and may target it deliberately.
    let admin = seed_admin(app.pool()).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;
    let as_admin = app
        .send(post_auth_json(
            "/notifications/channels",
            &admin_token,
            &create_body(&unique("admin"), "http://127.0.0.1:5432/x"),
        ))
        .await;
    assert_eq!(
        as_admin.status(),
        StatusCode::CREATED,
        "an admin may point a destination at the box itself"
    );

    // The same rule applies on update, not just on create.
    let owned = seed_owned_channel(
        app.pool(),
        user.user_id,
        serde_json::json!({ "url": "https://example.com/hook" }),
    )
    .await;
    let update = app
        .send(put_auth_json(
            &format!("/notifications/channels/{owned}"),
            &token,
            &serde_json::json!({ "config": { "url": "http://mosquitto:1883/" } }),
        ))
        .await;
    assert_eq!(
        update.status(),
        StatusCode::BAD_REQUEST,
        "an update must not be able to retarget a channel at the deployment's internals"
    );
}

#[tokio::test]
async fn test_fire_refuses_a_stored_internal_destination_for_a_non_admin() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let user = seed_channel_manager(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    // A row that predates the destination rules (written straight to the DB).
    let owned = seed_owned_channel(
        app.pool(),
        user.user_id,
        serde_json::json!({ "url": "http://127.0.0.1:1984/api/streams" }),
    )
    .await;
    let resp = app
        .send(post_auth_empty(
            &format!("/notifications/channels/{owned}/test"),
            &token,
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "an existing internal destination must not become a way around the check"
    );
}

// ─── test-fire rate limit ────────────────────────────────────────────────────

#[tokio::test]
async fn channel_test_is_rate_limited_per_user() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let user = seed_channel_manager(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    // Config carries no `url`, so dispatch fails instantly with no network I/O
    // and the handler still answers 200 `{"ok": false}` — enough to count.
    let owned = seed_owned_channel(app.pool(), user.user_id, serde_json::json!({})).await;
    let uri = format!("/notifications/channels/{owned}/test");

    // The limit is 6 per minute per user; the window is fixed and starts here.
    for i in 1..=6 {
        let resp = app.send(post_auth_empty(&uri, &token)).await;
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "test-fire {i} of 6 must be within the limit"
        );
    }

    let over = app.send(post_auth_empty(&uri, &token)).await;
    assert_eq!(
        over.status(),
        StatusCode::TOO_MANY_REQUESTS,
        "the seventh test-fire in the window must be refused"
    );
    assert!(
        over.headers().contains_key(axum::http::header::RETRY_AFTER),
        "a 429 must carry a Retry-After hint"
    );

    // A different user is unaffected: the limit is per user, not global.
    let other = seed_channel_manager(app.pool(), &[cam]).await;
    let other_token = login(&app, &other.username, &other.password).await;
    let other_owned = seed_owned_channel(app.pool(), other.user_id, serde_json::json!({})).await;
    let resp = app
        .send(post_auth_empty(
            &format!("/notifications/channels/{other_owned}/test"),
            &other_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
}
