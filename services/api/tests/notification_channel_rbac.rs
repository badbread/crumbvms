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
    };
    let role = db::create_role(pool, &unique("role"), &caps, cameras)
        .await
        .expect("create_role (no view_plates)");
    seed_viewer_user(pool, role.id).await
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

    // Viewer granted only cam_a.
    let user = seed_viewer(app.pool(), &[cam_a]).await;
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
            include_snapshot: false,
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
            include_snapshot: false,
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
