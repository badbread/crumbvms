// SPDX-License-Identifier: AGPL-3.0-or-later

//! `GET /events` plate redaction, the LPR retention prune of plate-bearing
//! events, and the protected-bookmark limits on `POST /bookmarks`.

mod support;

use axum::http::StatusCode;
use chrono::{Duration, SecondsFormat, Utc};
use crumb_common::{
    db,
    types::{BookmarkScope, Capabilities},
};
use support::*;
use uuid::Uuid;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .expect("read body");
    serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
}

fn caps(view_plates: bool, bookmarks: BookmarkScope) -> Capabilities {
    Capabilities {
        export: false,
        playback: true,
        clips: true,
        ptz: false,
        bookmarks,
        manage_views: true,
        view_plates,
        actuators: false,
        manage_channels: false,
    }
}

async fn insert_event(
    pool: &deadpool_postgres::Pool,
    camera_id: Uuid,
    ts: chrono::DateTime<Utc>,
    label: &str,
    sub_label: Option<&str>,
    raw: serde_json::Value,
) -> Uuid {
    let client = pool.get().await.expect("pool.get");
    let pid = unique("pe");
    client
        .query_one(
            r"INSERT INTO events (camera_id, ts, label, score, source_id, provider_event_id,
                                  sub_label, raw)
              VALUES ($1, $2, $3, 0.9, 'frigate', $4, $5, $6) RETURNING id",
            &[&camera_id, &ts, &label, &pid, &sub_label, &raw],
        )
        .await
        .expect("insert event")
        .get(0)
}

fn events_uri(cam: Uuid) -> String {
    let start = (Utc::now() - Duration::hours(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
    let end = (Utc::now() + Duration::hours(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
    format!("/events?camera_ids={cam}&start={start}&end={end}")
}

fn sub_labels(v: &serde_json::Value) -> Vec<(String, Option<String>)> {
    v["events"]
        .as_array()
        .expect("events array")
        .iter()
        .map(|e| {
            (
                e["label"].as_str().unwrap_or_default().to_owned(),
                e["sub_label"].as_str().map(str::to_owned),
            )
        })
        .collect()
}

#[tokio::test]
async fn events_redact_plate_sub_labels_without_view_plates() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let now = Utc::now();
    insert_event(
        app.pool(),
        cam,
        now,
        "license_plate",
        Some("7ABC123"),
        serde_json::json!({}),
    )
    .await;
    insert_event(
        app.pool(),
        cam,
        now - Duration::seconds(5),
        "car",
        Some("7ABC123"),
        serde_json::json!({ "after": { "recognized_license_plate": ["7ABC123", 0.9] } }),
    )
    .await;
    insert_event(
        app.pool(),
        cam,
        now - Duration::seconds(10),
        "person",
        Some("Alex"),
        serde_json::json!({ "after": { "recognized_license_plate": null } }),
    )
    .await;

    // Without view_plates: plate strings are gone, a recognized-person name stays.
    let role =
        seed_viewer_role_with_caps(app.pool(), &[cam], caps(false, BookmarkScope::Own)).await;
    let viewer = seed_viewer_user(app.pool(), role).await;
    let token = login(&app, &viewer.username, &viewer.password).await;
    let resp = app.send(get_auth(&events_uri(cam), &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let got = sub_labels(&body_json(resp).await);
    assert_eq!(got.len(), 3);
    for (label, sub) in &got {
        match label.as_str() {
            "license_plate" | "car" => {
                assert_eq!(*sub, None, "{label} sub_label must be redacted");
            }
            "person" => assert_eq!(sub.as_deref(), Some("Alex")),
            other => panic!("unexpected label {other}"),
        }
    }

    // With view_plates: untouched.
    let role = seed_viewer_role_with_caps(app.pool(), &[cam], caps(true, BookmarkScope::Own)).await;
    let viewer = seed_viewer_user(app.pool(), role).await;
    let token = login(&app, &viewer.username, &viewer.password).await;
    let resp = app.send(get_auth(&events_uri(cam), &token)).await;
    let got = sub_labels(&body_json(resp).await);
    assert!(got
        .iter()
        .any(|(l, s)| l == "license_plate" && s.as_deref() == Some("7ABC123")));
}

#[tokio::test]
async fn plate_event_prune_deletes_plate_events_and_scrubs_others() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let old = Utc::now() - Duration::days(400);
    let plate_ev = insert_event(
        app.pool(),
        cam,
        old,
        "license_plate",
        Some("7ABC123"),
        serde_json::json!({ "plate": "7ABC123" }),
    )
    .await;
    let car_ev = insert_event(
        app.pool(),
        cam,
        old,
        "car",
        Some("7ABC123"),
        serde_json::json!({ "after": { "id": "x", "recognized_license_plate": ["7ABC123", 0.9] } }),
    )
    .await;
    let recent_plate = insert_event(
        app.pool(),
        cam,
        Utc::now(),
        "license_plate",
        Some("7ABC123"),
        serde_json::json!({}),
    )
    .await;

    // The cutoff sits between the old rows and the fresh one.
    let cutoff = Utc::now() - Duration::days(300);
    db::prune_plate_events(app.pool(), cutoff)
        .await
        .expect("prune_plate_events");

    let client = app.pool().get().await.expect("pool.get");
    let gone = client
        .query_opt("SELECT 1 FROM events WHERE id = $1", &[&plate_ev])
        .await
        .unwrap();
    assert!(gone.is_none(), "old plate-labelled event is deleted");
    let row = client
        .query_one(
            "SELECT sub_label, raw FROM events WHERE id = $1",
            &[&car_ev],
        )
        .await
        .unwrap();
    assert_eq!(row.get::<_, Option<String>>(0), None);
    let raw: serde_json::Value = row.get(1);
    assert_eq!(raw, serde_json::json!({ "after": { "id": "x" } }));
    let kept = client
        .query_opt("SELECT 1 FROM events WHERE id = $1", &[&recent_plate])
        .await
        .unwrap();
    assert!(
        kept.is_some(),
        "events inside the retention window are kept"
    );
}

fn bookmark_body(cam: Uuid, ts: chrono::DateTime<Utc>, protect_days: i64) -> serde_json::Value {
    serde_json::json!({
        "camera_id": cam,
        "ts": ts.to_rfc3339_opts(SecondsFormat::Secs, true),
        "protect_days": protect_days,
        "protect_pre_seconds": 3600,
        "protect_post_seconds": 3600,
    })
}

#[tokio::test]
async fn bookmark_in_the_future_is_rejected_and_window_is_capped() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let viewer = seed_viewer_with_bookmark_scope(app.pool(), &[cam], BookmarkScope::Own).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let far = Utc::now() + Duration::hours(2);
    let resp = app
        .send(post_auth_json(
            "/bookmarks",
            &token,
            &bookmark_body(cam, far, 30),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    // Same for an unprotected bookmark.
    let resp = app
        .send(post_auth_json(
            "/bookmarks",
            &token,
            &bookmark_body(cam, far, 0),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // A bookmark at "now" is fine, and its window (2 x 3600 s requested) is
    // capped at one hour in total.
    let resp = app
        .send(post_auth_json(
            "/bookmarks",
            &token,
            &bookmark_body(cam, Utc::now(), 30),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let v = body_json(resp).await;
    let start: chrono::DateTime<Utc> = v["protect_start_ts"].as_str().unwrap().parse().unwrap();
    let end: chrono::DateTime<Utc> = v["protect_end_ts"].as_str().unwrap().parse().unwrap();
    assert!((end - start).num_seconds() <= 3600);
}

#[tokio::test]
async fn protected_bookmark_cap_is_enforced_per_user_in_the_db_layer() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let a = seed_viewer_with_bookmark_scope(app.pool(), &[cam], BookmarkScope::Own).await;
    let b = seed_viewer_with_bookmark_scope(app.pool(), &[cam], BookmarkScope::Own).await;
    let now = Utc::now();
    let until = now + Duration::days(7);

    for i in 0..2 {
        let r = db::create_protected_bookmark_capped(
            app.pool(),
            cam,
            now - Duration::minutes(i),
            None,
            a.user_id,
            until,
            now - Duration::minutes(i + 1),
            now,
            2,
        )
        .await
        .expect("capped insert");
        assert!(r.is_some(), "bookmark {i} is under the cap");
    }
    let third = db::create_protected_bookmark_capped(
        app.pool(),
        cam,
        now,
        None,
        a.user_id,
        until,
        now,
        now,
        2,
    )
    .await
    .expect("capped insert");
    assert!(
        third.is_none(),
        "third active protected bookmark is refused"
    );

    // The cap is per user.
    let other = db::create_protected_bookmark_capped(
        app.pool(),
        cam,
        now,
        None,
        b.user_id,
        until,
        now,
        now,
        2,
    )
    .await
    .expect("capped insert");
    assert!(other.is_some());
}
