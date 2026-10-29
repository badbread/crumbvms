// SPDX-License-Identifier: AGPL-3.0-or-later

//! `footage_expired` on bookmarks (moment deleted by retention vs a recording
//! gap inside the retained range) and `oldest_footage_ts` on `GET /cameras`.

mod support;

use axum::http::StatusCode;
use chrono::{DateTime, Duration, DurationRound, SecondsFormat, Utc};
use crumb_common::db;
use support::*;
use uuid::Uuid;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .expect("read body");
    serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
}

/// Whole-second "now", so values round-trip through Postgres exactly.
fn now_secs() -> DateTime<Utc> {
    Utc::now()
        .duration_trunc(Duration::seconds(1))
        .expect("trunc")
}

async fn insert_segment(
    pool: &deadpool_postgres::Pool,
    camera_id: Uuid,
    storage_id: Uuid,
    start: DateTime<Utc>,
    secs: i64,
) {
    let client = pool.get().await.expect("pool.get");
    let path = format!("{}/seg.mp4", unique("seg"));
    client
        .execute(
            r"
            INSERT INTO segments
                (camera_id, storage_id, stage, path, stream, start_ts, end_ts,
                 duration_ms, has_motion, size_bytes)
            VALUES ($1, $2, 'live', $3, 'main', $4, $5, $6, false, 64)
            ",
            &[
                &camera_id,
                &storage_id,
                &path,
                &start,
                &(start + Duration::seconds(secs)),
                &i32::try_from(secs * 1000).expect("duration fits"),
            ],
        )
        .await
        .expect("insert segment");
}

async fn bookmark(
    pool: &deadpool_postgres::Pool,
    camera_id: Uuid,
    ts: DateTime<Utc>,
    note: &str,
) -> Uuid {
    db::create_bookmark(pool, camera_id, ts, Some(note), None, None, None, None)
        .await
        .expect("create_bookmark")
        .id
}

fn expired_by_note(v: &serde_json::Value) -> Vec<(String, bool)> {
    v.as_array()
        .expect("bookmark array")
        .iter()
        .map(|b| {
            (
                b["description"].as_str().unwrap_or_default().to_owned(),
                b["footage_expired"]
                    .as_bool()
                    .expect("footage_expired is a bool"),
            )
        })
        .collect()
}

#[tokio::test]
async fn bookmark_footage_expired_distinguishes_retention_from_gaps() {
    let app = TestApp::new().await;
    let storage = seed_storage(app.pool(), &format!("/tmp/{}", unique("bm-expired"))).await;
    let cam = seed_camera(app.pool()).await;
    let empty_cam = seed_camera(app.pool()).await;
    let now = now_secs();

    // Retained footage: one segment two hours ago, one ten minutes ago, with a
    // gap between them.
    insert_segment(app.pool(), cam, storage, now - Duration::hours(2), 4).await;
    insert_segment(app.pool(), cam, storage, now - Duration::minutes(10), 4).await;

    bookmark(
        app.pool(),
        cam,
        now - Duration::hours(3),
        "before-retention",
    )
    .await;
    bookmark(
        app.pool(),
        cam,
        now - Duration::hours(2) + Duration::seconds(2),
        "covered",
    )
    .await;
    bookmark(app.pool(), cam, now - Duration::hours(1), "gap").await;
    bookmark(
        app.pool(),
        empty_cam,
        now - Duration::hours(1),
        "no-segments",
    )
    .await;

    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(get_auth(&format!("/bookmarks?camera_id={cam}"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let mut got = expired_by_note(&body_json(resp).await);
    got.sort();
    assert_eq!(
        got,
        vec![
            ("before-retention".to_owned(), true),
            ("covered".to_owned(), false),
            ("gap".to_owned(), false),
        ]
    );

    let resp = app
        .send(get_auth(
            &format!("/bookmarks?camera_id={empty_cam}"),
            &token,
        ))
        .await;
    assert_eq!(
        expired_by_note(&body_json(resp).await),
        vec![("no-segments".to_owned(), true)],
        "a camera with no segments at all has no footage for any bookmark"
    );

    // The unfiltered list carries the same flag.
    let resp = app.send(get_auth("/bookmarks", &token)).await;
    let all = expired_by_note(&body_json(resp).await);
    assert!(all.contains(&("before-retention".to_owned(), true)));
    assert!(all.contains(&("gap".to_owned(), false)));

    // Re-creating an expired bookmark (the desktop's undo) reports it as
    // expired straight away.
    let resp = app
        .send(post_auth_json(
            "/bookmarks",
            &token,
            &serde_json::json!({
                "camera_id": cam,
                "ts": (now - Duration::hours(5)).to_rfc3339_opts(SecondsFormat::Secs, true),
                "description": "recreated",
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    assert_eq!(body_json(resp).await["footage_expired"], true);
}

#[tokio::test]
async fn cameras_list_reports_oldest_footage_ts() {
    let app = TestApp::new().await;
    let storage = seed_storage(app.pool(), &format!("/tmp/{}", unique("oldest-footage"))).await;
    let cam = seed_camera(app.pool()).await;
    let empty_cam = seed_camera(app.pool()).await;
    let now = now_secs();
    let oldest = now - Duration::days(3);
    insert_segment(app.pool(), cam, storage, now - Duration::hours(1), 4).await;
    insert_segment(app.pool(), cam, storage, oldest, 4).await;

    // A viewer granted only `cam` sees only `cam` (grant scoping unchanged).
    let viewer = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;
    let resp = app.send(get_auth("/cameras", &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let list = v.as_array().expect("camera array");
    assert_eq!(list.len(), 1);
    let got: DateTime<Utc> = list[0]["oldest_footage_ts"]
        .as_str()
        .expect("oldest_footage_ts string")
        .parse()
        .expect("rfc3339");
    assert_eq!(got, oldest);
    // recording_mode is the camera's effective policy mode.
    let effective = db::get_camera(app.pool(), cam)
        .await
        .expect("get_camera")
        .expect("camera exists")
        .policy
        .mode;
    assert_eq!(list[0]["recording_mode"], effective.as_str());
    assert!(matches!(
        list[0]["recording_mode"].as_str(),
        Some("continuous" | "motion")
    ));

    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let resp = app.send(get_auth("/cameras", &token)).await;
    let v = body_json(resp).await;
    let row = v
        .as_array()
        .expect("camera array")
        .iter()
        .find(|c| c["id"] == serde_json::json!(empty_cam))
        .expect("admin sees the empty camera");
    assert!(
        row["oldest_footage_ts"].is_null(),
        "a camera with no segments reports null"
    );

    // Point the empty camera at its own motion-mode policy: GET /cameras
    // reports the effective mode.
    {
        let c = app.pool().get().await.expect("pool.get");
        let motion_policy: Uuid = c
            .query_one(
                r"
                INSERT INTO recording_policies (
                    name, is_default, mode,
                    live_storage_id, live_retention_hours,
                    archive_enabled, archive_storage_id, archive_schedule,
                    archive_retention_hours,
                    motion_pre_seconds, motion_post_seconds,
                    motion_sensitivity, motion_threshold,
                    motion_keyframes_only, record_stream, record_audio
                )
                SELECT
                    $1, false, 'motion',
                    live_storage_id, live_retention_hours,
                    archive_enabled, archive_storage_id, archive_schedule,
                    archive_retention_hours,
                    motion_pre_seconds, motion_post_seconds,
                    motion_sensitivity, motion_threshold,
                    motion_keyframes_only, record_stream, record_audio
                FROM recording_policies
                WHERE is_default = true
                RETURNING id
                ",
                &[&unique("motion-policy")],
            )
            .await
            .expect("insert motion policy")
            .get(0);
        c.execute(
            "UPDATE cameras SET policy_id = $2 WHERE id = $1",
            &[&empty_cam, &motion_policy],
        )
        .await
        .expect("assign policy");
    }
    let resp = app.send(get_auth("/cameras", &token)).await;
    let v = body_json(resp).await;
    let row = v
        .as_array()
        .expect("camera array")
        .iter()
        .find(|c| c["id"] == serde_json::json!(empty_cam))
        .expect("admin sees the empty camera");
    assert_eq!(row["recording_mode"], "motion");
}
