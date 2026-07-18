// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for the LPR dual-engine A/B benchmark endpoints:
//! `GET /lpr/ab-report` (view_plates-gated, camera-scoped) and
//! `POST /lpr/ab-confirm` (admin-only ground truth). The pure pairing rules
//! live in `crumb_common::lpr_ab` with their own unit tests; these tests cover
//! the HTTP contract: RBAC deny paths, the empty report for non-`both`
//! cameras, end-to-end pairing over seeded `plate_reads`, and the
//! confirm → accuracy round trip.
//!
//! Structure mirrors `lpr_plates.rs` (crate-root re-includes via
//! `tests/support/mod.rs`, so `main.rs`'s curated clippy allowances repeat
//! here for `--all-targets -D warnings` parity).
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
use chrono::{DateTime, Duration, Utc};
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db;
use crumb_common::types::{BookmarkScope, Capabilities};

use support::*;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
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
    };
    let role = db::create_role(pool, &unique("role"), &caps, cameras)
        .await
        .expect("create_role");
    seed_viewer_user(pool, role.id).await
}

/// Seed one plate read at an explicit ts/engine/confidence, unique per call.
async fn seed_read(
    pool: &Pool,
    camera_id: Uuid,
    source_id: &str,
    plate: &str,
    confidence: f32,
    ts: DateTime<Utc>,
) {
    db::upsert_plate_read(
        pool,
        &db::UpsertPlateReadParams {
            camera_id,
            ts,
            plate: db::normalize_plate(plate),
            plate_raw: Some(plate.to_owned()),
            confidence: Some(confidence),
            source_id: source_id.to_owned(),
            provider_event_id: Some(unique("abpid")),
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

/// Flip a seeded camera to dual-engine LPR so the benchmark covers it.
async fn make_both(pool: &Pool, camera_id: Uuid) {
    db::update_camera_lpr(pool, camera_id, "both", 0.0, None)
        .await
        .expect("update_camera_lpr");
}

#[tokio::test]
async fn ab_report_denied_without_view_plates() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    make_both(app.pool(), cam).await;

    let user = seed_viewer_no_plates(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app
        .send(get_auth(&format!("/lpr/ab-report?camera_id={cam}"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn ab_confirm_requires_admin() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    make_both(app.pool(), cam).await;

    // A viewer WITH view_plates can read the report but must NOT set truth.
    let user = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app
        .send(post_auth_json(
            "/lpr/ab-confirm",
            &token,
            &serde_json::json!({
                "camera_id": cam,
                "bucket_ts": Utc::now(),
                "true_plate": "ABC123",
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

/// A caller whose scope holds no `both`-engine camera gets the empty report
/// (`cameras: []`) — the clients key the Benchmark UI's visibility off that.
#[tokio::test]
async fn ab_report_empty_without_both_cameras() {
    let app = TestApp::new().await;
    // Default-seeded camera keeps lpr_engine = 'frigate'.
    let cam = seed_camera(app.pool()).await;
    let user = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app.send(get_auth("/lpr/ab-report", &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["cameras"].as_array().unwrap().len(), 0);
    assert_eq!(v["total_passes"], 0);
    assert!(v["passes"].as_array().unwrap().is_empty());
}

/// Camera scoping mirrors `/plates`: a `both` camera outside the viewer's
/// grants is silently dropped, even when requested explicitly.
#[tokio::test]
async fn ab_report_scoped_to_grants() {
    let app = TestApp::new().await;
    let cam_ab = seed_camera(app.pool()).await;
    make_both(app.pool(), cam_ab).await;
    let cam_other = seed_camera(app.pool()).await;

    // Viewer WITH view_plates, granted only the non-benchmark camera.
    let user = seed_viewer(app.pool(), &[cam_other]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app
        .send(get_auth(
            &format!("/lpr/ab-report?camera_id={cam_ab}"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(
        v["cameras"].as_array().unwrap().len(),
        0,
        "out-of-scope both-camera must be dropped, not 403'd"
    );
}

/// End-to-end: seeded reads pair into passes (Frigate's refinement dup
/// collapses; the crumb read joins the same pass), the confirm endpoint
/// records truth on the echoed pass key, and the re-fetched report scores
/// each engine against it.
#[tokio::test]
async fn ab_report_pairs_and_scores_confirmed_truth() {
    let app = TestApp::new().await;
    let pool = app.pool();
    let cam = seed_camera(pool).await;
    make_both(pool, cam).await;

    // t0 on a whole second so the derived bucket_ts is exactly t0.
    let t0 = crumb_common::lpr_ab::bucket_key(Utc::now() - Duration::minutes(10));
    // Pass 1: Frigate self-duplicates (refinement 5 s later, one char off,
    // higher confidence); crumb-alpr reads once. One physical vehicle.
    seed_read(pool, cam, "frigate", "9GXVL98", 0.70, t0).await;
    seed_read(
        pool,
        cam,
        "frigate",
        "9GXV498",
        0.87,
        t0 + Duration::seconds(5),
    )
    .await;
    seed_read(
        pool,
        cam,
        "crumb-alpr",
        "9GXVL98",
        0.99,
        t0 + Duration::seconds(1),
    )
    .await;
    // Pass 2 (4 min later): Frigate only — a crumb-alpr miss.
    seed_read(
        pool,
        cam,
        "frigate",
        "ZZTOP01",
        0.91,
        t0 + Duration::seconds(240),
    )
    .await;

    let admin = seed_admin(pool).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let uri = format!("/lpr/ab-report?camera_id={cam}");
    let resp = app.send(get_auth(&uri, &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;

    assert_eq!(v["cameras"].as_array().unwrap().len(), 1);
    assert_eq!(v["total_passes"], 2);
    assert_eq!(v["both_seen"], 1);
    // The both-pass disagrees (9GXV498 vs 9GXVL98) → agreement 0.
    assert!((v["agreement_rate"].as_f64().unwrap() - 0.0).abs() < 1e-6);
    assert_eq!(v["frigate"]["total_reads"], 3);
    assert_eq!(v["crumb_alpr"]["total_reads"], 1);
    assert_eq!(v["frigate"]["passes_seen"], 2);
    assert_eq!(v["crumb_alpr"]["passes_seen"], 1);
    assert!((v["frigate"]["hit_rate"].as_f64().unwrap() - 1.0).abs() < 1e-6);
    assert!((v["crumb_alpr"]["hit_rate"].as_f64().unwrap() - 0.5).abs() < 1e-6);
    // Nothing confirmed yet.
    assert_eq!(v["frigate"]["confirmed"], 0);
    assert!(v["frigate"]["accuracy"].is_null());

    // Newest-first: passes[1] is the both-pass at t0.
    let passes = v["passes"].as_array().unwrap();
    assert_eq!(passes.len(), 2);
    let both_pass = &passes[1];
    assert_eq!(
        both_pass["frigate"]["plate"], "9GXV498",
        "frigate keeps its higher-confidence refinement"
    );
    assert_eq!(both_pass["frigate"]["read_count"], 2, "dup collapsed");
    assert_eq!(both_pass["crumb_alpr"]["plate"], "9GXVL98");
    assert_eq!(both_pass["agree"], false);
    assert!(both_pass["true_plate"].is_null());
    let miss_pass = &passes[0];
    assert_eq!(miss_pass["frigate"]["plate"], "ZZTOP01");
    assert!(miss_pass["crumb_alpr"].is_null(), "crumb missed pass 2");
    assert!(miss_pass["agree"].is_null());

    // Confirm the both-pass's truth with the echoed key. Raw plate text is
    // normalized server-side ("9gxv-l98" -> "9GXVL98").
    let bucket_ts = both_pass["bucket_ts"].as_str().unwrap();
    let resp = app
        .send(post_auth_json(
            "/lpr/ab-confirm",
            &token,
            &serde_json::json!({
                "camera_id": cam,
                "bucket_ts": bucket_ts,
                "true_plate": "9gxv-l98",
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let truth = body_json(resp).await;
    assert_eq!(truth["true_plate"], "9GXVL98");
    assert_eq!(truth["camera_id"], cam.to_string());

    // Re-fetch: truth attached, crumb correct, frigate wrong; aggregates follow.
    let resp = app.send(get_auth(&uri, &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let both_pass = &v["passes"].as_array().unwrap()[1];
    assert_eq!(both_pass["true_plate"], "9GXVL98");
    assert_eq!(both_pass["frigate_correct"], false);
    assert_eq!(both_pass["crumb_alpr_correct"], true);
    assert_eq!(v["frigate"]["confirmed"], 1);
    assert_eq!(v["frigate"]["correct"], 0);
    assert!((v["frigate"]["accuracy"].as_f64().unwrap() - 0.0).abs() < 1e-6);
    assert_eq!(v["crumb_alpr"]["confirmed"], 1);
    assert_eq!(v["crumb_alpr"]["correct"], 1);
    assert!((v["crumb_alpr"]["accuracy"].as_f64().unwrap() - 1.0).abs() < 1e-6);

    // Re-confirming the same pass key overwrites (typo correction).
    let resp = app
        .send(post_auth_json(
            "/lpr/ab-confirm",
            &token,
            &serde_json::json!({
                "camera_id": cam,
                "bucket_ts": bucket_ts,
                "true_plate": "9GXV498",
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let resp = app.send(get_auth(&uri, &token)).await;
    let v = body_json(resp).await;
    let both_pass = &v["passes"].as_array().unwrap()[1];
    assert_eq!(both_pass["frigate_correct"], true);
    assert_eq!(both_pass["crumb_alpr_correct"], false);
}

#[tokio::test]
async fn ab_confirm_rejects_blank_plate_and_unknown_camera() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // "---" normalizes to empty -> 400.
    let cam = seed_camera(app.pool()).await;
    let resp = app
        .send(post_auth_json(
            "/lpr/ab-confirm",
            &token,
            &serde_json::json!({
                "camera_id": cam,
                "bucket_ts": Utc::now(),
                "true_plate": "---",
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Unknown camera -> 404, not a 500 from the FK.
    let resp = app
        .send(post_auth_json(
            "/lpr/ab-confirm",
            &token,
            &serde_json::json!({
                "camera_id": Uuid::new_v4(),
                "bucket_ts": Utc::now(),
                "true_plate": "ABC123",
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
