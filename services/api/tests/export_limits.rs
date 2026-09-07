// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for the bounds `POST /export` puts on a single job.
//!
//! Two properties, both asserted against the REAL `create_export` handler via
//! the shared harness (`mod support` `#[path]`-includes the actual `src/`
//! modules, so this is the shipped validation path, not a mirror of it):
//!
//! 1. **A repeated camera produces ONE unit of work.** `filter_camera_ids` is a
//!    scope filter, not a de-duplicator (for an admin it returns the list
//!    verbatim), so a body naming the same camera N times used to enqueue N
//!    sequential full-range ffmpeg runs, all writing the SAME output file with
//!    `-y`, and all counted as ONE job against `EXPORT_MAX_CONCURRENT`. The job
//!    must now carry exactly one entry per DISTINCT camera.
//! 2. **An over-long range is refused up front.** The window is capped by
//!    `EXPORT_MAX_RANGE_SECONDS` (default 86400) and rejected with `400` before
//!    any job, directory, or ffmpeg child is allocated.

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
use chrono::Utc;
use uuid::Uuid;

use support::*;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
}

/// The default `EXPORT_MAX_RANGE_SECONDS` (a full day of one camera). The tests
/// deliberately do NOT set the env var: it is process-wide and every test binary
/// shares it, so they assert against the shipped default instead.
const DEFAULT_MAX_RANGE_SECS: i64 = 86_400;

#[tokio::test]
async fn duplicated_camera_list_produces_one_job_entry_per_distinct_camera() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;

    let start = Utc::now() - chrono::Duration::minutes(5);
    let end = Utc::now();

    // The pathological shape: one camera repeated many times, plus a second one
    // also repeated, in no particular order.
    let resp = app
        .send(post_auth_json(
            "/export",
            &token,
            &serde_json::json!({
                "camera_ids": [cam_b, cam_a, cam_b, cam_a, cam_b, cam_b, cam_b, cam_b],
                "start": start,
                "end": end,
            }),
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::ACCEPTED,
        "a duplicated but in-scope, in-range list is a valid request"
    );

    let body = body_json(resp).await;
    let job_id: Uuid = body["job_id"]
        .as_str()
        .expect("202 body carries a job_id")
        .parse()
        .expect("job_id is a UUID");

    // The job record is inserted BEFORE the worker is spawned, so reading it
    // here is race-free regardless of what the (ffmpeg-less) worker then does.
    let job = app
        .state
        .export_jobs()
        .get(&job_id)
        .map(|r| r.clone())
        .expect("the job the 202 named must exist");

    let mut expected = vec![cam_a, cam_b];
    expected.sort_unstable();
    assert_eq!(
        job.camera_ids, expected,
        "eight camera_ids naming two distinct cameras must become two units of \
         work, not eight ffmpeg runs over the same output file"
    );
}

#[tokio::test]
async fn over_long_export_range_is_rejected_with_400() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let cam = seed_camera(app.pool()).await;

    let start = Utc::now() - chrono::Duration::days(30);
    let end = Utc::now();

    let resp = app
        .send(post_auth_json(
            "/export",
            &token,
            &serde_json::json!({
                "camera_ids": [cam],
                "start": start,
                "end": end,
            }),
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::BAD_REQUEST,
        "a 30-day window is past EXPORT_MAX_RANGE_SECONDS and must be refused"
    );
    let body = body_json(resp).await;
    let message = body["message"].as_str().unwrap_or_default();
    assert!(
        message.contains("range too large"),
        "the 400 should say why it was refused (got: {body:?})"
    );

    // Nothing was allocated: no job exists for this caller at all.
    assert_eq!(
        app.state.export_jobs().len(),
        0,
        "an over-range request must be refused BEFORE a job is allocated"
    );

    // And a window exactly at the cap is still accepted, so the bound is where
    // it is documented to be rather than somewhere just under it.
    let ok = app
        .send(post_auth_json(
            "/export",
            &token,
            &serde_json::json!({
                "camera_ids": [cam],
                "start": end - chrono::Duration::seconds(DEFAULT_MAX_RANGE_SECS),
                "end": end,
            }),
        ))
        .await;
    assert_eq!(
        ok.status(),
        StatusCode::ACCEPTED,
        "a window exactly at EXPORT_MAX_RANGE_SECONDS must still be accepted"
    );
}
