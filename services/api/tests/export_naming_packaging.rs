// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for batch-export packaging (`package` = `zip` | `files`),
//! the index-addressed `GET /export/:job_id/output/:index` download, and
//! `POST /export/estimate`.
//!
//! The ffmpeg step itself is not run here (the harness has no ffmpeg at the
//! production path); download tests register a `Done` job with real files on
//! disk, exactly like `auth_handoff.rs`. File naming and the zip/files packaging
//! decision are unit-tested next to their code in `src/export.rs`.

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

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use axum::body::to_bytes;
use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crumb_common::db;
use crumb_common::types::{SegmentStage, SegmentStream};
use support::dto::{ExportJob, ExportOutputFile, ExportStatus};
use support::*;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null)
}

fn export_root() -> &'static Path {
    static EXPORT_ROOT: OnceLock<PathBuf> = OnceLock::new();
    EXPORT_ROOT.get_or_init(|| {
        let mut p = std::env::temp_dir();
        p.push(format!("crumb-test-exports-{}", Uuid::new_v4().simple()));
        std::fs::create_dir_all(&p).expect("create temp export dir");
        std::env::set_var("EXPORT_DIR", &p);
        p
    })
}

fn utc(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s).unwrap().into()
}

/// Register a `Done` job whose `output_files` are `(camera, disk name, download
/// name)`, each backed by a real file whose bytes are its disk name.
fn seed_done_job(app: &TestApp, outputs: &[(Uuid, &str, &str)], status: ExportStatus) -> Uuid {
    let job_id = Uuid::new_v4();
    let dir = export_root().join(job_id.to_string());
    std::fs::create_dir_all(&dir).unwrap();
    let now = Utc::now();
    let mut files = Vec::new();
    let mut cams = Vec::new();
    for (i, (cam, disk, dl)) in outputs.iter().enumerate() {
        std::fs::write(dir.join(disk), disk.as_bytes()).unwrap();
        if *cam != Uuid::nil() {
            cams.push(*cam);
        }
        files.push(ExportOutputFile {
            camera_id: *cam,
            download_url: format!("/export/{job_id}/output/{i}"),
            size_bytes: disk.len() as u64,
            filename: (*disk).to_owned(),
            download_name: (*dl).to_owned(),
        });
    }
    cams.sort();
    cams.dedup();
    app.state.export_jobs().insert(
        job_id,
        ExportJob {
            id: job_id,
            status,
            camera_ids: cams,
            start: now,
            end: now,
            burn_timestamp: false,
            created_at: now,
            output_files: files,
            error: None,
            progress_pct: 100,
        },
    );
    job_id
}

// ─── request validation ─────────────────────────────────────────────────────

fn batch_body(cam: Uuid, extra: serde_json::Value) -> serde_json::Value {
    let start = Utc::now() - chrono::Duration::minutes(5);
    let mut b = serde_json::json!({
        "items": [{ "camera_id": cam, "start": start, "end": Utc::now() }],
    });
    for (k, v) in extra.as_object().unwrap() {
        b[k] = v.clone();
    }
    b
}

#[tokio::test]
async fn batch_package_option_is_validated() {
    let _ = export_root();
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let cam = seed_camera(app.pool()).await;

    // Default (no field), "zip" and "files" are all accepted.
    for extra in [
        serde_json::json!({}),
        serde_json::json!({ "package": "zip" }),
        serde_json::json!({ "package": "files" }),
        // An empty password means "no password", so it does not conflict.
        serde_json::json!({ "package": "files", "password": "" }),
        serde_json::json!({ "package": "zip", "password": "secret" }),
    ] {
        let resp = app
            .send(post_auth_json(
                "/export/batch",
                &token,
                &batch_body(cam, extra.clone()),
            ))
            .await;
        assert_eq!(resp.status(), StatusCode::ACCEPTED, "{extra}");
        // The ffmpeg-less worker may still be winding down; finish the job here so
        // the shared concurrency cap (429) does not trip the next request.
        for mut j in app.state.export_jobs().iter_mut() {
            j.status = ExportStatus::Failed;
        }
    }

    // A password forces zip.
    let resp = app
        .send(post_auth_json(
            "/export/batch",
            &token,
            &batch_body(
                cam,
                serde_json::json!({ "package": "files", "password": "secret" }),
            ),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let msg = body_json(resp).await["message"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    assert!(msg.contains("password") && msg.contains("zip"), "{msg}");

    // Unknown package value.
    let resp = app
        .send(post_auth_json(
            "/export/batch",
            &token,
            &batch_body(cam, serde_json::json!({ "package": "tar" })),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ─── GET /export/:job_id/output/:index ──────────────────────────────────────

#[tokio::test]
async fn output_route_serves_each_clip_by_index_with_friendly_names() {
    let _ = export_root();
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let cam = seed_camera(app.pool()).await;

    // Two clips from the SAME camera: only the index route can tell them apart.
    let job = seed_done_job(
        &app,
        &[
            (
                cam,
                "Küche 2026-10-29 14.05.06-14.09.10.mp4",
                "Küche 2026-10-29 14.05.06-14.09.10.mp4",
            ),
            (
                cam,
                "Küche 2026-10-29 15.00.00-15.01.00.mp4",
                "Küche 2026-10-29 15.00.00-15.01.00.mp4",
            ),
        ],
        ExportStatus::Done,
    );

    for (i, disk) in [
        "Küche 2026-10-29 14.05.06-14.09.10.mp4",
        "Küche 2026-10-29 15.00.00-15.01.00.mp4",
    ]
    .iter()
    .enumerate()
    {
        let resp = app
            .send(get_auth(&format!("/export/{job}/output/{i}"), &token))
            .await;
        assert_eq!(resp.status(), StatusCode::OK);
        let cd = resp.headers()["content-disposition"]
            .to_str()
            .unwrap()
            .to_owned();
        assert!(
            cd.starts_with("attachment; filename=\"K_che 2026-10-29 "),
            "{cd}"
        );
        assert!(
            cd.contains("; filename*=UTF-8''K%C3%BCche%202026-10-29%20"),
            "{cd}"
        );
        assert!(cd.ends_with(".mp4"), "{cd}");
        assert_eq!(resp.headers()["content-type"], "video/mp4");
        let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        assert_eq!(&bytes[..], disk.as_bytes());
    }

    // Out of range index.
    let resp = app
        .send(get_auth(&format!("/export/{job}/output/2"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    // No bearer.
    let resp = app.send(get(&format!("/export/{job}/output/0"))).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // A login token in the query is not accepted.
    let resp = app
        .send(get(&format!("/export/{job}/output/0?token={token}")))
        .await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn output_route_requires_done_and_camera_access() {
    let _ = export_root();
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    let viewer = seed_viewer(app.pool(), &[cam_a]).await;
    let viewer_token = login(&app, &viewer.username, &viewer.password).await;

    // Not Done yet.
    let running = seed_done_job(&app, &[(cam_a, "a.mp4", "a.mp4")], ExportStatus::Running);
    let resp = app
        .send(get_auth(
            &format!("/export/{running}/output/0"),
            &admin_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Per-entry camera scope.
    let job = seed_done_job(
        &app,
        &[(cam_a, "a.mp4", "A.mp4"), (cam_b, "b.mp4", "B.mp4")],
        ExportStatus::Done,
    );
    let resp = app
        .send(get_auth(&format!("/export/{job}/output/0"), &viewer_token))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let resp = app
        .send(get_auth(&format!("/export/{job}/output/1"), &viewer_token))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // The nil-camera zip entry needs access to EVERY camera in the job, like
    // `/export/:job_id/archive`.
    let zip_job = seed_done_job(
        &app,
        &[(
            Uuid::nil(),
            "crumb_export.zip",
            "Crumb export 2026-10-29 14.05.zip",
        )],
        ExportStatus::Done,
    );
    app.state
        .export_jobs()
        .get_mut(&zip_job)
        .unwrap()
        .camera_ids = vec![cam_a, cam_b];
    let resp = app
        .send(get_auth(
            &format!("/export/{zip_job}/output/0"),
            &viewer_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let resp = app
        .send(get_auth(
            &format!("/export/{zip_job}/output/0"),
            &admin_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(resp.headers()["content-type"], "application/zip");
    assert_eq!(
        resp.headers()["content-disposition"],
        "attachment; filename=\"Crumb export 2026-10-29 14.05.zip\"; \
         filename*=UTF-8''Crumb%20export%202026-10-29%2014.05.zip"
    );

    // The pre-existing archive route keeps working and now uses the friendly name.
    let resp = app
        .send(get_auth(
            &format!("/export/{zip_job}/archive"),
            &admin_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(resp.headers()["content-disposition"]
        .to_str()
        .unwrap()
        .contains("Crumb%20export"));
}

// ─── POST /export/estimate ──────────────────────────────────────────────────

async fn seed_seg(
    app: &TestApp,
    storage: Uuid,
    cam: Uuid,
    stream: SegmentStream,
    start: &str,
    end: &str,
    size: i64,
) {
    let (s, e) = (utc(start), utc(end));
    db::insert_segment(
        app.pool(),
        &db::InsertSegmentParams {
            camera_id: cam,
            storage_id: storage,
            stage: SegmentStage::Live,
            path: format!("{}/seg.mp4", unique("est")),
            stream,
            start_ts: s,
            end_ts: e,
            duration_ms: (e - s).num_milliseconds() as i32,
            has_motion: false,
            motion_score: 0.0,
            size_bytes: size,
            motion_bbox: None,
        },
    )
    .await
    .expect("insert_segment");
}

#[tokio::test]
async fn estimate_prorates_segments_by_overlap() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;
    let storage = seed_storage(app.pool(), "/tmp/crumb-est").await;
    let cam = seed_camera(app.pool()).await;
    let empty_cam = seed_camera(app.pool()).await;

    // Two adjacent 10 s main segments (1000 B, 2000 B), one fully outside, and a
    // sub-stream segment that an export never uses.
    seed_seg(
        &app,
        storage,
        cam,
        SegmentStream::Main,
        "2026-01-01T10:00:00Z",
        "2026-01-01T10:00:10Z",
        1000,
    )
    .await;
    seed_seg(
        &app,
        storage,
        cam,
        SegmentStream::Main,
        "2026-01-01T10:00:10Z",
        "2026-01-01T10:00:20Z",
        2000,
    )
    .await;
    seed_seg(
        &app,
        storage,
        cam,
        SegmentStream::Main,
        "2026-01-01T11:00:00Z",
        "2026-01-01T11:00:10Z",
        5000,
    )
    .await;
    seed_seg(
        &app,
        storage,
        cam,
        SegmentStream::Sub,
        "2026-01-01T10:00:00Z",
        "2026-01-01T10:00:20Z",
        9999,
    )
    .await;

    let resp = app
        .send(post_auth_json(
            "/export/estimate",
            &token,
            &serde_json::json!({ "items": [
                // Half of the first (500 B / 5 s) + half of the second (1000 B / 5 s).
                { "camera_id": cam, "start": "2026-01-01T10:00:05Z", "end": "2026-01-01T10:00:15Z" },
                // Whole first segment and a range that extends past it.
                { "camera_id": cam, "start": "2026-01-01T00:00:00Z", "end": "2026-01-01T10:00:10Z" },
                // A camera with nothing recorded.
                { "camera_id": empty_cam, "start": "2026-01-01T10:00:00Z", "end": "2026-01-01T10:10:00Z" },
            ]}),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    let clips = body["clips"].as_array().unwrap();
    assert_eq!(clips.len(), 3);
    assert_eq!(clips[0]["bytes"], 1500);
    assert!((clips[0]["footage_seconds"].as_f64().unwrap() - 10.0).abs() < 1e-6);
    assert_eq!(clips[1]["bytes"], 1000);
    assert!((clips[1]["footage_seconds"].as_f64().unwrap() - 10.0).abs() < 1e-6);
    assert_eq!(clips[2]["bytes"], 0);
    assert_eq!(clips[2]["footage_seconds"].as_f64().unwrap(), 0.0);
    assert_eq!(body["bytes"], 2500);
    assert!((body["footage_seconds"].as_f64().unwrap() - 20.0).abs() < 1e-6);
}

#[tokio::test]
async fn estimate_applies_the_same_gates_as_batch_export() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    let viewer = seed_viewer(app.pool(), &[cam_a]).await;
    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    let item = |cam: Uuid| serde_json::json!({ "camera_id": cam, "start": "2026-01-01T10:00:00Z", "end": "2026-01-01T10:01:00Z" });

    // No auth.
    let resp = app
        .send(
            axum::http::Request::builder()
                .method("POST")
                .uri("/export/estimate")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::json!({ "items": [item(cam_a)] }).to_string(),
                ))
                .unwrap(),
        )
        .await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // Camera out of scope (all-or-nothing).
    let resp = app
        .send(post_auth_json(
            "/export/estimate",
            &viewer_token,
            &serde_json::json!({ "items": [item(cam_a), item(cam_b)] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // No export capability.
    let no_export = seed_viewer_role_with_caps(
        app.pool(),
        &[cam_a],
        crumb_common::types::Capabilities {
            export: false,
            ..generous_viewer_caps()
        },
    )
    .await;
    let u = seed_viewer_user(app.pool(), no_export).await;
    let t = login(&app, &u.username, &u.password).await;
    let resp = app
        .send(post_auth_json(
            "/export/estimate",
            &t,
            &serde_json::json!({ "items": [item(cam_a)] }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // Empty list, inverted range, over-long range.
    for items in [
        serde_json::json!([]),
        serde_json::json!([{ "camera_id": cam_a, "start": "2026-01-01T10:01:00Z", "end": "2026-01-01T10:00:00Z" }]),
        serde_json::json!([{ "camera_id": cam_a, "start": "2025-01-01T00:00:00Z", "end": "2026-01-01T00:00:00Z" }]),
    ] {
        let resp = app
            .send(post_auth_json(
                "/export/estimate",
                &admin_token,
                &serde_json::json!({ "items": items }),
            ))
            .await;
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "{items}");
    }
}
