// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for the plate desk aggregates behind the redesigned LPR
//! page: `GET /lpr/overview` (today's header totals and the regulars /
//! returning / first-time split) and `POST /lpr/plates/stats` (per-plate
//! history). Covers the counts and windows, hour/day bucketing in the server
//! time zone (including a DST-shifted local midnight), grant scoping (a viewer
//! never has reads from a camera it cannot see counted), the `view_plates`
//! gate, and the input limits.
//!
//! The tests share one Postgres with every other test binary, so every test
//! uses its own freshly seeded cameras and unique plate strings, and the
//! overview tests always pass explicit `camera_ids`.
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

use axum::body::to_bytes;
use axum::http::StatusCode;
use chrono::{DateTime, Duration, TimeZone, Utc};
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db;
use crumb_common::types::{BookmarkScope, Capabilities};

use support::*;

const LA: chrono_tz::Tz = chrono_tz::America::Los_Angeles;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// A plate string no other test (or test run) will produce.
fn fresh_plate() -> String {
    format!("T{}", &Uuid::new_v4().simple().to_string()[..9]).to_uppercase()
}

fn utc(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
}

async fn seed_read(pool: &Pool, camera_id: Uuid, plate: &str, ts: DateTime<Utc>) {
    db::upsert_plate_read(
        pool,
        &db::UpsertPlateReadParams {
            camera_id,
            ts,
            plate: db::normalize_plate(plate),
            plate_raw: Some(plate.to_owned()),
            confidence: Some(0.9),
            source_id: "frigate".to_owned(),
            provider_event_id: Some(unique("pid")),
            event_id: None,
            snapshot_url: None,
            bbox: None,
            crop: None,
            raw: serde_json::json!({}),
        },
    )
    .await
    .expect("seed plate_read");
}

async fn app_la() -> TestApp {
    TestApp::new_with_config(|c| c.server_tz = LA).await
}

async fn admin_token(app: &TestApp) -> String {
    let admin = seed_admin(app.pool()).await;
    login(app, &admin.username, &admin.password).await
}

async fn stats(app: &TestApp, token: &str, plates: &[&str]) -> serde_json::Value {
    let resp = app
        .send(post_auth_json(
            "/lpr/plates/stats",
            token,
            &serde_json::json!({ "plates": plates }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    body_json(resp).await
}

fn entry<'a>(v: &'a serde_json::Value, plate: &str) -> Option<&'a serde_json::Value> {
    v["plates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["plate"] == plate)
}

fn ints(v: &serde_json::Value) -> Vec<i64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_i64().unwrap())
        .collect()
}

// ── POST /lpr/plates/stats ──────────────────────────────────────────────────

#[tokio::test]
async fn stats_counts_windows_and_tz_buckets() {
    let app = app_la().await;
    let cam = seed_camera(app.pool()).await;
    let plate = fresh_plate();

    let now = Utc::now() - Duration::seconds(5);
    let reads = [
        now,
        now - Duration::days(2),
        now - Duration::days(10),
        now - Duration::days(40),
        // 01:30 UTC = 17:30 PST: lands in the 17h bucket in Los Angeles, not 1h.
        utc("2026-01-15T01:30:00Z"),
    ];
    for ts in reads {
        seed_read(app.pool(), cam, &plate, ts).await;
    }

    let token = admin_token(&app).await;
    let v = stats(&app, &token, &[&plate]).await;
    assert_eq!(v["tz"], "America/Los_Angeles");
    assert_eq!(v["regular_min_reads_30d"], 5);
    let e = entry(&v, &plate).expect("plate present");

    // Expected buckets, computed the same way in Los Angeles local time.
    let today = Utc::now().with_timezone(&LA).date_naive();
    let mut days = vec![0i64; 30];
    let mut hours = vec![0i64; 24];
    for ts in reads {
        let local = ts.with_timezone(&LA);
        hours[chrono::Timelike::hour(&local) as usize] += 1;
        let back = (today - local.date_naive()).num_days();
        if (0..30).contains(&back) {
            days[(29 - back) as usize] += 1;
        }
    }
    assert_eq!(ints(&e["hours"]), hours, "hour-of-day buckets in LA time");
    assert_eq!(ints(&e["days30"]), days, "30-day buckets, oldest first");
    assert!(hours[17] >= 1, "the 01:30Z read is a 5 PM read in LA");
    assert_eq!(days[29], 1, "today's read is the last bucket");

    assert_eq!(e["total"], 5);
    assert_eq!(e["seen_30d"], days.iter().sum::<i64>());
    assert_eq!(e["seen_30d"], 3);
    assert_eq!(e["seen_7d"], days[23..].iter().sum::<i64>());
    assert_eq!(e["seen_7d"], 2);
    assert_eq!(
        e["first_seen"].as_str().map(utc),
        Some(utc("2026-01-15T01:30:00Z"))
    );
    let last = utc(e["last_seen"].as_str().unwrap());
    assert!(
        (last - now).num_milliseconds().abs() < 5,
        "last_seen = newest read"
    );
    let prev = utc(e["prev_seen"].as_str().unwrap());
    assert!(
        (prev - (now - Duration::days(2))).num_milliseconds().abs() < 5,
        "prev_seen = newest read before today"
    );
    let cams = e["cameras"].as_array().unwrap();
    assert_eq!(cams.len(), 1);
    assert_eq!(cams[0]["camera_id"], cam.to_string());
    assert_eq!(cams[0]["n"], 5);
}

#[tokio::test]
async fn stats_utc_server_buckets_differently() {
    // Same instant, UTC server: the 01:30Z read is a 1 AM read.
    let app = TestApp::new_with_config(|c| c.server_tz = chrono_tz::UTC).await;
    let cam = seed_camera(app.pool()).await;
    let plate = fresh_plate();
    seed_read(app.pool(), cam, &plate, utc("2026-01-15T01:30:00Z")).await;
    let token = admin_token(&app).await;
    let v = stats(&app, &token, &[&plate]).await;
    assert_eq!(v["tz"], "UTC");
    let e = entry(&v, &plate).unwrap();
    let h = ints(&e["hours"]);
    assert_eq!(h[1], 1);
    assert_eq!(h.iter().sum::<i64>(), 1);
    assert!(e["prev_seen"].as_str().is_some());
}

#[tokio::test]
async fn stats_scoped_to_camera_grants() {
    let app = app_la().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    let shared = fresh_plate();
    let hidden = fresh_plate();
    let now = Utc::now() - Duration::seconds(5);
    for i in 0..2 {
        seed_read(app.pool(), cam_a, &shared, now - Duration::hours(i)).await;
    }
    for i in 0..3 {
        seed_read(app.pool(), cam_b, &shared, now - Duration::hours(i)).await;
    }
    seed_read(app.pool(), cam_b, &hidden, now).await;

    // Viewer granted only cam_a: cam_b's reads are never counted, and a plate
    // seen only on cam_b does not exist for them.
    let user = seed_viewer(app.pool(), &[cam_a]).await;
    let token = login(&app, &user.username, &user.password).await;
    let v = stats(&app, &token, &[&shared, &hidden]).await;
    let e = entry(&v, &shared).expect("shared plate visible");
    assert_eq!(e["total"], 2);
    assert_eq!(ints(&e["hours"]).iter().sum::<i64>(), 2);
    assert_eq!(ints(&e["days30"]).iter().sum::<i64>(), 2);
    let cams = e["cameras"].as_array().unwrap();
    assert_eq!(cams.len(), 1);
    assert_eq!(cams[0]["camera_id"], cam_a.to_string());
    assert!(entry(&v, &hidden).is_none(), "out-of-scope plate omitted");

    // Asking for cam_b explicitly does not widen the scope.
    let resp = app
        .send(post_auth_json(
            "/lpr/plates/stats",
            &token,
            &serde_json::json!({ "plates": [&shared], "camera_ids": [cam_b] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert!(v["plates"].as_array().unwrap().is_empty());

    // The admin sees both cameras, busiest first.
    let token = admin_token(&app).await;
    let v = stats(&app, &token, &[&shared]).await;
    let e = entry(&v, &shared).unwrap();
    assert_eq!(e["total"], 5);
    let cams = e["cameras"].as_array().unwrap();
    assert_eq!(cams[0]["camera_id"], cam_b.to_string());
    assert_eq!(cams[0]["n"], 3);
    assert_eq!(cams[1]["n"], 2);
}

/// A viewer scoped to `cameras` but WITHOUT the `view_plates` capability.
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
        .expect("create_role");
    seed_viewer_user(pool, role.id).await
}

#[tokio::test]
async fn plate_desk_denied_without_view_plates() {
    let app = app_la().await;
    let cam = seed_camera(app.pool()).await;
    let plate = fresh_plate();
    seed_read(app.pool(), cam, &plate, Utc::now()).await;
    let user = seed_viewer_no_plates(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app
        .send(post_auth_json(
            "/lpr/plates/stats",
            &token,
            &serde_json::json!({ "plates": [&plate] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let resp = app
        .send(get_auth(&format!("/lpr/overview?camera_ids={cam}"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // And both require a session at all.
    let resp = app.send(get("/lpr/overview")).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn stats_input_limits_and_normalization() {
    let app = app_la().await;
    let cam = seed_camera(app.pool()).await;
    let plate = fresh_plate();
    seed_read(app.pool(), cam, &plate, Utc::now()).await;
    let token = admin_token(&app).await;

    // Over the cap: 400.
    let many: Vec<String> = (0..201).map(|i| format!("ZZ{i}")).collect();
    let resp = app
        .send(post_auth_json(
            "/lpr/plates/stats",
            &token,
            &serde_json::json!({ "plates": many }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Exactly the cap is fine.
    let ok: Vec<String> = (0..200).map(|i| format!("ZZ{i}")).collect();
    let resp = app
        .send(post_auth_json(
            "/lpr/plates/stats",
            &token,
            &serde_json::json!({ "plates": ok }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);

    // Empty list: empty answer.
    let v = stats(&app, &token, &[]).await;
    assert!(v["plates"].as_array().unwrap().is_empty());

    // Lower-case / punctuated spellings normalize to the stored plate and
    // de-duplicate; junk that normalizes to nothing is dropped.
    let spaced = format!("{}-{}", &plate[..3], &plate[3..]).to_lowercase();
    let v = stats(&app, &token, &[&spaced, &plate, "--"]).await;
    let arr = v["plates"].as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["plate"], plate.as_str());
    assert_eq!(arr[0]["total"], 1);
}

// ── GET /lpr/overview ───────────────────────────────────────────────────────

#[tokio::test]
async fn overview_counts_split_and_local_day() {
    let app = app_la().await;
    let cam = seed_camera(app.pool()).await;
    let other = seed_camera(app.pool()).await;
    let pool = app.pool();

    // 2026-03-10 in Los Angeles is PDT (UTC-7): the local day runs
    // 07:00Z Mar 10 .. 07:00Z Mar 11.
    let day_start = LA
        .with_ymd_and_hms(2026, 3, 10, 0, 0, 0)
        .unwrap()
        .with_timezone(&Utc);
    assert_eq!(day_start, utc("2026-03-10T07:00:00Z"));
    let noon = day_start + Duration::hours(12);

    // Regular: 4 reads in the previous 20 days + 1 today = 5 in 30 days.
    let regular = fresh_plate();
    for d in [3, 8, 13, 20] {
        seed_read(pool, cam, &regular, noon - Duration::days(d)).await;
    }
    seed_read(pool, cam, &regular, noon).await;
    // ...and a read AFTER the day, which must not count toward anything.
    seed_read(pool, cam, &regular, noon + Duration::days(1)).await;

    // Returning: seen at 23:30 local the night before (06:30Z on Mar 10, so
    // the same UTC date but the previous local day) + once today.
    let returning = fresh_plate();
    seed_read(pool, cam, &returning, utc("2026-03-10T06:30:00Z")).await;
    seed_read(pool, cam, &returning, noon).await;

    // Old: last seen 60 days ago, only 1 read in the window: returning too.
    let old = fresh_plate();
    seed_read(pool, cam, &old, noon - Duration::days(60)).await;
    seed_read(pool, cam, &old, noon).await;

    // First-time: two reads today, the first just after local midnight.
    let newbie = fresh_plate();
    seed_read(pool, cam, &newbie, utc("2026-03-10T07:30:00Z")).await;
    seed_read(pool, cam, &newbie, noon).await;

    // First-time AND on the watchlist.
    let watched = fresh_plate();
    seed_read(pool, cam, &watched, noon).await;
    db::upsert_watchlist_entry(
        pool,
        &db::UpsertWatchlistParams {
            plate: watched.clone(),
            label: None,
            note: None,
            color: None,
            notify: false,
            kind: "watch".to_owned(),
        },
    )
    .await
    .unwrap();

    // Noise on a camera the request does not include.
    seed_read(pool, other, &fresh_plate(), noon).await;
    seed_read(pool, other, &regular, noon).await;

    let token = admin_token(&app).await;
    let resp = app
        .send(get_auth(
            &format!("/lpr/overview?day=2026-03-10&camera_ids={cam}"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["day"], "2026-03-10");
    assert_eq!(v["tz"], "America/Los_Angeles");
    assert_eq!(v["reads_today"], 6, "{v}");
    assert_eq!(v["unique_today"], 5, "{v}");
    assert_eq!(v["new_today"], 2, "{v}");
    assert_eq!(v["watchlist_hits_today"], 1, "{v}");
    assert_eq!(v["split"]["regulars"], 1, "{v}");
    assert_eq!(v["split"]["returning"], 2, "{v}");
    assert_eq!(v["split"]["first_time"], 2, "{v}");
    assert_eq!(v["regular_min_reads_30d"], 5);

    // The previous local day sees only the 23:30 read.
    let resp = app
        .send(get_auth(
            &format!("/lpr/overview?day=2026-03-09&camera_ids={cam}"),
            &token,
        ))
        .await;
    let v = body_json(resp).await;
    assert_eq!(v["reads_today"], 1, "{v}");
    assert_eq!(v["new_today"], 1, "{v}");

    // Bad camera ids are a 400; bad days fail to parse (400).
    let resp = app
        .send(get_auth("/lpr/overview?camera_ids=nope", &token))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let resp = app
        .send(get_auth("/lpr/overview?day=2026-13-40", &token))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn overview_scoped_to_camera_grants() {
    let app = app_la().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    let noon = utc("2026-02-02T20:00:00Z");
    let mine = fresh_plate();
    seed_read(app.pool(), cam_a, &mine, noon).await;
    seed_read(app.pool(), cam_b, &fresh_plate(), noon).await;
    seed_read(app.pool(), cam_b, &fresh_plate(), noon).await;
    // The viewer's plate has history on the camera they cannot see: for them
    // it is still a first-time plate.
    seed_read(app.pool(), cam_b, &mine, noon - Duration::days(3)).await;

    let user = seed_viewer(app.pool(), &[cam_a]).await;
    let token = login(&app, &user.username, &user.password).await;
    for q in [
        "/lpr/overview?day=2026-02-02".to_owned(),
        format!("/lpr/overview?day=2026-02-02&camera_ids={cam_a},{cam_b}"),
    ] {
        let resp = app.send(get_auth(&q, &token)).await;
        assert_eq!(resp.status(), StatusCode::OK);
        let v = body_json(resp).await;
        assert_eq!(v["reads_today"], 1, "{q}: {v}");
        assert_eq!(v["unique_today"], 1, "{q}: {v}");
        assert_eq!(v["new_today"], 1, "{q}: {v}");
    }
    // Only out-of-scope cameras requested: zeros, not an error.
    let resp = app
        .send(get_auth(
            &format!("/lpr/overview?day=2026-02-02&camera_ids={cam_b}"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(body_json(resp).await["reads_today"], 0);

    let token = admin_token(&app).await;
    let resp = app
        .send(get_auth(
            &format!("/lpr/overview?day=2026-02-02&camera_ids={cam_a},{cam_b}"),
            &token,
        ))
        .await;
    let v = body_json(resp).await;
    assert_eq!(v["reads_today"], 3, "{v}");
    assert_eq!(v["new_today"], 2, "{v}");
    assert_eq!(v["split"]["returning"], 1, "{v}");
}
