// SPDX-License-Identifier: AGPL-3.0-or-later

//! Scrub sprite strips (`GET /filmstrip/{camera_id}/sprite`) against a real
//! Postgres: the capability + per-camera scope gates, the scoped `?token=`
//! media path, the "404 until pre-generated" contract the clients' fallback
//! relies on, the layout headers, and the orphan sweep that keeps a sprite
//! from outliving its segment. See `tests/support/mod.rs` for the harness.
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
use chrono::SecondsFormat;
use uuid::Uuid;

use support::*;

/// A unique temp dir removed on drop (the api suite avoids the tempfile crate).
struct TempDir(std::path::PathBuf);
impl TempDir {
    fn new(prefix: &str) -> Self {
        let p = std::env::temp_dir().join(format!("{prefix}-{}", Uuid::new_v4().simple()));
        std::fs::create_dir_all(&p).expect("create temp dir");
        Self(p)
    }
    fn path(&self) -> &std::path::Path {
        &self.0
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Fixture {
    app: TestApp,
    cache: TempDir,
    _storage: TempDir,
    cam_a: Uuid,
    cam_b: Uuid,
    seg_a: Uuid,
    seg_a_start: chrono::DateTime<chrono::Utc>,
    viewer_token: String,
}

async fn fixture() -> Fixture {
    let cache = TempDir::new("crumb-test-sprite-cache");
    let cache_path = cache.path().to_str().unwrap().to_owned();
    let app = TestApp::new_with_config(move |c| c.thumb_cache_dir = cache_path).await;
    let pool = app.pool().clone();
    let storage = TempDir::new("crumb-test-sprite-storage");
    let storage_id = seed_storage(&pool, storage.path().to_str().unwrap()).await;
    let cam_a = seed_camera(&pool).await;
    let cam_b = seed_camera(&pool).await;
    let seg_a = seed_segment_with_file(&pool, cam_a, storage_id, storage.path()).await;
    let seg_a_start: chrono::DateTime<chrono::Utc> = pool
        .get()
        .await
        .unwrap()
        .query_one("SELECT start_ts FROM segments WHERE id = $1", &[&seg_a])
        .await
        .unwrap()
        .get(0);
    let viewer = seed_viewer(&pool, &[cam_a]).await;
    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    Fixture {
        app,
        cache,
        _storage: storage,
        cam_a,
        cam_b,
        seg_a,
        seg_a_start,
        viewer_token,
    }
}

fn ts_param(t: chrono::DateTime<chrono::Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// Write a fake sprite where the generator would have put it.
async fn plant_sprite(
    cache: &std::path::Path,
    cam: Uuid,
    seg: Uuid,
    bytes: &[u8],
) -> std::path::PathBuf {
    let dir = cache.join(".thumbs").join(cam.to_string()).join("sprites");
    tokio::fs::create_dir_all(&dir).await.unwrap();
    // The seeded segment is 4 s long: four 160 px tiles.
    let p = dir.join(format!("{seg}_w160_t4.jpg"));
    tokio::fs::write(&p, bytes).await.unwrap();
    p
}

#[tokio::test]
async fn sprite_is_404_until_generated_then_served_with_layout() {
    let fx = fixture().await;
    let t = fx.seg_a_start + chrono::Duration::milliseconds(1500);
    let path = format!("/filmstrip/{}/sprite?ts={}", fx.cam_a, ts_param(t));

    // Not generated yet: a plain 404 (the clients fall back to /frame).
    let resp = fx.app.send(get_auth(&path, &fx.viewer_token)).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    plant_sprite(fx.cache.path(), fx.cam_a, fx.seg_a, b"jpeg-bytes").await;
    let resp = fx.app.send(get_auth(&path, &fx.viewer_token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let h = resp.headers();
    let hv = |k: &str| h.get(k).and_then(|v| v.to_str().ok()).map(str::to_owned);
    assert_eq!(hv("content-type").as_deref(), Some("image/jpeg"));
    assert_eq!(
        hv("x-crumb-sprite-start-ms"),
        Some(fx.seg_a_start.timestamp_millis().to_string())
    );
    assert_eq!(
        hv("x-crumb-sprite-end-ms"),
        Some((fx.seg_a_start.timestamp_millis() + 4000).to_string())
    );
    assert_eq!(hv("x-crumb-sprite-tiles").as_deref(), Some("4"));
    assert_eq!(hv("x-crumb-sprite-columns").as_deref(), Some("4"));
    assert_eq!(hv("x-crumb-sprite-interval-ms").as_deref(), Some("1000"));
    assert_eq!(hv("x-crumb-sprite-tile-width").as_deref(), Some("160"));
    let body = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    assert_eq!(&body[..], b"jpeg-bytes");

    // Outside any segment: 404 (no footage), never a neighbour's sprite.
    let gap = fx.seg_a_start - chrono::Duration::hours(3);
    let resp = fx
        .app
        .send(get_auth(
            &format!("/filmstrip/{}/sprite?ts={}", fx.cam_a, ts_param(gap)),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn sprite_enforces_camera_scope_and_playback_capability() {
    let fx = fixture().await;
    plant_sprite(fx.cache.path(), fx.cam_a, fx.seg_a, b"x").await;
    let t = ts_param(fx.seg_a_start + chrono::Duration::seconds(1));

    // Another camera's sprite: refused before anything is looked up.
    let resp = fx
        .app
        .send(get_auth(
            &format!("/filmstrip/{}/sprite?ts={t}", fx.cam_b),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // A live-only role (playback: false) scoped to the camera: refused.
    let caps = crumb_common::types::Capabilities {
        playback: false,
        ..generous_viewer_caps()
    };
    let role = seed_viewer_role_with_caps(fx.app.pool(), &[fx.cam_a], caps).await;
    let live_only = seed_viewer_user(fx.app.pool(), role).await;
    let lo_token = login(&fx.app, &live_only.username, &live_only.password).await;
    let resp = fx
        .app
        .send(get_auth(
            &format!("/filmstrip/{}/sprite?ts={t}", fx.cam_a),
            &lo_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // No credential at all: 401.
    let resp = fx
        .app
        .send(get(&format!("/filmstrip/{}/sprite?ts={t}", fx.cam_a)))
        .await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn sprite_accepts_a_scoped_media_token_for_its_camera_only() {
    let fx = fixture().await;
    plant_sprite(fx.cache.path(), fx.cam_a, fx.seg_a, b"x").await;
    let t = ts_param(fx.seg_a_start + chrono::Duration::seconds(2));

    let resp = fx
        .app
        .send(get_auth(
            &format!("/media-token?camera={}", fx.cam_a),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v: serde_json::Value =
        serde_json::from_slice(&to_bytes(resp.into_body(), usize::MAX).await.unwrap()).unwrap();
    let media = v["token"].as_str().unwrap().to_owned();

    let ok = fx
        .app
        .send(get(&format!(
            "/filmstrip/{}/sprite?ts={t}&token={media}",
            fx.cam_a
        )))
        .await;
    assert_eq!(ok.status(), StatusCode::OK);

    // The same media token can't reach another camera.
    let other = fx
        .app
        .send(get(&format!(
            "/filmstrip/{}/sprite?ts={t}&token={media}",
            fx.cam_b
        )))
        .await;
    assert_eq!(other.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn orphan_sweep_removes_only_sprites_of_deleted_segments() {
    let fx = fixture().await;
    let live = plant_sprite(fx.cache.path(), fx.cam_a, fx.seg_a, b"live").await;
    let orphan = plant_sprite(fx.cache.path(), fx.cam_a, Uuid::new_v4(), b"gone").await;
    let dir = live.parent().unwrap().to_owned();
    // Files the sweeper must never touch even though no segment matches them.
    let stranger = dir.join("notes.txt");
    let tmp = dir.join(format!("{}_w160_t4.jpg.tmp9", Uuid::new_v4()));
    tokio::fs::write(&stranger, b"keep").await.unwrap();
    tokio::fs::write(&tmp, b"in flight").await.unwrap();

    let removed = support::scrub_sprite::sweep_orphan_sprites(
        fx.app.pool(),
        fx.cache.path().to_str().unwrap(),
    )
    .await;
    assert_eq!(removed, 1);
    assert!(live.exists(), "a sprite whose segment exists must stay");
    assert!(
        !orphan.exists(),
        "a sprite whose segment is gone must be removed"
    );
    assert!(
        stranger.exists() && tmp.exists(),
        "non-sprite files are never touched"
    );

    // Delete the segment row (as retention would): its sprite goes next sweep.
    fx.app
        .pool()
        .get()
        .await
        .unwrap()
        .execute("DELETE FROM segments WHERE id = $1", &[&fx.seg_a])
        .await
        .unwrap();
    let removed = support::scrub_sprite::sweep_orphan_sprites(
        fx.app.pool(),
        fx.cache.path().to_str().unwrap(),
    )
    .await;
    assert_eq!(removed, 1);
    assert!(!live.exists());

    // And the endpoint no longer resolves anything for that instant.
    let t = ts_param(fx.seg_a_start + chrono::Duration::seconds(1));
    let resp = fx
        .app
        .send(get_auth(
            &format!("/filmstrip/{}/sprite?ts={t}", fx.cam_a),
            &fx.viewer_token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
