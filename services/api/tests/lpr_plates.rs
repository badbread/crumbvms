// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for `GET /plates` — the LPR plate-reads endpoint, and
//! Crumb's FIRST capability-gated *read* surface. Covers `view_plates` gating
//! (the deny path), camera scoping, admin passthrough, and the dynamic
//! prefix/fuzzy search query (the hand-built `$N`-parameterized SQL).
//!
//! Structure mirrors `auth_rbac.rs`: this test binary's crate root re-includes
//! the crate's own (private, bin-only) source modules via `tests/support/mod.rs`
//! `#[path]` includes, so the same curated clippy allowances `main.rs` declares
//! must be repeated here for `--all-targets -D warnings` parity.
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
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db;
use crumb_common::types::{BookmarkScope, Capabilities};

use support::*;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn seed_plate(pool: &Pool, camera_id: Uuid, plate: &str) {
    db::upsert_plate_read(
        pool,
        &db::UpsertPlateReadParams {
            camera_id,
            ts: chrono::Utc::now(),
            plate: db::normalize_plate(plate),
            plate_raw: Some(plate.to_owned()),
            confidence: Some(0.9),
            source_id: "frigate".to_owned(),
            // Unique per seed: the tests share one Postgres, and the dedup index
            // on (source_id, provider_event_id) would otherwise let one test's
            // read UPSERT-clobber another's (moving its camera_id) under parallel
            // execution.
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

#[tokio::test]
async fn plates_denied_without_view_plates_capability() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    seed_plate(app.pool(), cam, "ABC123").await;

    let user = seed_viewer_no_plates(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app
        .send(get_auth(&format!("/plates?camera_ids={cam}"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn plates_camera_scoped_to_grants() {
    let app = TestApp::new().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    seed_plate(app.pool(), cam_a, "AAA111").await;
    seed_plate(app.pool(), cam_b, "BBB222").await;

    // Viewer WITH view_plates, but granted only cam_a.
    let user = seed_viewer(app.pool(), &[cam_a]).await;
    let token = login(&app, &user.username, &user.password).await;

    // Requests BOTH cameras; the out-of-scope one must be silently dropped.
    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam_a},{cam_b}"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let plates = v["plates"].as_array().unwrap();
    assert_eq!(plates.len(), 1, "viewer must see only their granted camera");
    assert_eq!(plates[0]["plate"], "AAA111");
    assert_eq!(plates[0]["camera_id"], cam_a.to_string());
}

#[tokio::test]
async fn plates_admin_sees_all_requested_cameras() {
    let app = TestApp::new().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    seed_plate(app.pool(), cam_a, "AAA111").await;
    seed_plate(app.pool(), cam_b, "BBB222").await;

    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam_a},{cam_b}"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["total"], 2);
    assert_eq!(v["plates"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn plates_prefix_and_fuzzy_search() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    seed_plate(app.pool(), cam, "ABC123").await;
    seed_plate(app.pool(), cam, "XYZ789").await;

    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // prefix: only ABC123 (exercises the `plate LIKE $n || '%'` param path).
    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam}&q=ABC&match=prefix"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let plates = v["plates"].as_array().unwrap();
    assert_eq!(plates.len(), 1);
    assert_eq!(plates[0]["plate"], "ABC123");

    // fuzzy: a one-character miss still surfaces ABC123 via trigram similarity
    // (exercises the `plate % $n` + `similarity(plate, $n)` param reuse).
    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam}&q=ABC124&match=fuzzy"),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let found: Vec<String> = v["plates"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["plate"].as_str().unwrap().to_owned())
        .collect();
    assert!(
        found.iter().any(|p| p == "ABC123"),
        "fuzzy search should surface ABC123, got {found:?}"
    );
}

// ── plate watchlist (`/lpr/watchlist`) ───────────────────────────────────────

fn delete_auth(uri: &str, token: &str) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("DELETE")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(axum::body::Body::empty())
        .unwrap()
}

fn put_auth_json(
    uri: &str,
    token: &str,
    body: &serde_json::Value,
) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("PUT")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body.to_string()))
        .unwrap()
}

#[tokio::test]
async fn watchlist_read_denied_without_view_plates() {
    let app = TestApp::new().await;
    let user = seed_viewer_no_plates(app.pool(), &[]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app.send(get_auth("/lpr/watchlist", &token)).await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn watchlist_write_requires_admin() {
    let app = TestApp::new().await;
    // A viewer WITH view_plates can read, but must NOT be able to add entries.
    let cam = seed_camera(app.pool()).await;
    let user = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app
        .send(post_auth_json(
            "/lpr/watchlist",
            &token,
            &serde_json::json!({ "plate": "ABC123" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn watchlist_admin_add_list_delete() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // Add (plate is normalized server-side: "abc-123" -> "ABC123").
    let resp = app
        .send(post_auth_json(
            "/lpr/watchlist",
            &token,
            &serde_json::json!({ "plate": "abc-123", "label": "Mom's car" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let entry = body_json(resp).await;
    assert_eq!(entry["plate"], "ABC123");
    assert_eq!(entry["label"], "Mom's car");
    assert_eq!(entry["notify"], true);
    let id = entry["id"].as_str().unwrap().to_owned();

    // List contains it.
    let resp = app.send(get_auth("/lpr/watchlist", &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let list = body_json(resp).await;
    let arr = list.as_array().unwrap();
    assert!(arr.iter().any(|e| e["plate"] == "ABC123"));

    // Delete it.
    let resp = app
        .send(delete_auth(&format!("/lpr/watchlist/{id}"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // A second delete is a 404 (gone).
    let resp = app
        .send(delete_auth(&format!("/lpr/watchlist/{id}"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn watchlist_add_rejects_blank_plate() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // "---" normalizes to empty — must 400, never store a blank watchlist row.
    let resp = app
        .send(post_auth_json(
            "/lpr/watchlist",
            &token,
            &serde_json::json!({ "plate": "---" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// The DB-level contract the ingester's alert hook relies on: a `notify = true`
/// entry matches (exact, normalized), a `notify = false` entry does not, and
/// `upsert_plate_read` reports insert-vs-update so an alert fires once per pass.
#[tokio::test]
async fn watchlist_match_and_upsert_inserted_flag() {
    let app = TestApp::new().await;
    let pool = app.pool();

    db::upsert_watchlist_entry(
        pool,
        &db::UpsertWatchlistParams {
            plate: db::normalize_plate("WATCH1"),
            label: Some("BOLO".to_owned()),
            note: None,
            color: None,
            notify: true,
            kind: "watch".to_owned(),
        },
    )
    .await
    .unwrap();
    db::upsert_watchlist_entry(
        pool,
        &db::UpsertWatchlistParams {
            plate: db::normalize_plate("SILENT9"),
            label: None,
            note: None,
            color: None,
            notify: false,
            kind: "watch".to_owned(),
        },
    )
    .await
    .unwrap();

    assert!(
        db::match_watchlist(pool, "WATCH1", 0.0)
            .await
            .unwrap()
            .is_some(),
        "notify=true entry must match"
    );
    assert!(
        db::match_watchlist(pool, "SILENT9", 0.0)
            .await
            .unwrap()
            .is_none(),
        "notify=false entry must not match (no alert)"
    );
    assert!(
        db::match_watchlist(pool, "NOTLISTED", 0.0)
            .await
            .unwrap()
            .is_none(),
        "unlisted plate must not match"
    );

    // First upsert of a provider_event_id INSERTs; replaying it UPDATEs.
    let cam = seed_camera(pool).await;
    let pid = unique("pass");
    let mk = |conf: f32| db::UpsertPlateReadParams {
        camera_id: cam,
        ts: chrono::Utc::now(),
        plate: db::normalize_plate("WATCH1"),
        plate_raw: Some("WATCH1".to_owned()),
        confidence: Some(conf),
        source_id: "frigate".to_owned(),
        provider_event_id: Some(pid.clone()),
        event_id: None,
        snapshot_url: None,
        bbox: None,
        crop: None,
        raw: serde_json::json!({}),
    };
    let first = db::upsert_plate_read(pool, &mk(0.8)).await.unwrap();
    assert!(first.inserted, "first read of a new event is an INSERT");
    let second = db::upsert_plate_read(pool, &mk(0.9)).await.unwrap();
    assert!(
        !second.inserted,
        "replaying the same provider_event_id is an UPDATE, not a new pass"
    );
    assert_eq!(first.id, second.id, "same row refined, not duplicated");

    // The `alerted` latch (Fable H1): a fresh read is not-yet-alerted; after
    // marking, a later refinement UPDATE reports alerted=true so the ingester
    // won't re-fire.
    assert!(
        !first.inserted || !first.alerted,
        "a fresh read starts un-alerted"
    );
    assert!(!second.alerted, "still un-alerted until explicitly marked");
    db::mark_plate_alerted(pool, first.id).await.unwrap();
    let third = db::upsert_plate_read(pool, &mk(0.95)).await.unwrap();
    assert!(
        third.alerted,
        "a refinement UPDATE after marking must report alerted=true (no re-fire)"
    );
}

/// Ignore-list + fuzzy matching (migration 0054). `ignore` entries are found by
/// `is_plate_ignored` (not by `match_watchlist`), and fuzz loosens both.
#[tokio::test]
async fn ignore_list_and_fuzzy_matching() {
    let app = TestApp::new().await;
    let pool = app.pool();

    db::upsert_watchlist_entry(
        pool,
        &db::UpsertWatchlistParams {
            plate: db::normalize_plate("PARKEDCAR9"),
            label: Some("nuisance".to_owned()),
            note: None,
            color: None,
            notify: false,
            kind: "ignore".to_owned(),
        },
    )
    .await
    .unwrap();

    // Exact ignore match; unrelated plate not ignored.
    assert!(db::is_plate_ignored(pool, "PARKEDCAR9", 0.0).await.unwrap());
    assert!(!db::is_plate_ignored(pool, "TOTALLYDIFF", 0.0)
        .await
        .unwrap());
    // An ignore entry is NOT a watch match (won't alert).
    assert!(
        db::match_watchlist(pool, "PARKEDCAR9", 0.0)
            .await
            .unwrap()
            .is_none(),
        "ignore entry must not be returned as a watch/alert match"
    );

    // A single-character misread (PARKEDCAR9 -> PARKEDCAB9): exact (fuzz 0) does
    // NOT match; under fuzz it does.
    assert!(
        !db::is_plate_ignored(pool, "PARKEDCAB9", 0.0).await.unwrap(),
        "at fuzz 0 only the exact plate is ignored"
    );
    assert!(
        db::is_plate_ignored(pool, "PARKEDCAB9", 0.5).await.unwrap(),
        "a 1-char misread of an ignored plate should also be ignored under fuzz"
    );

    // Watch + fuzzy alert match.
    db::upsert_watchlist_entry(
        pool,
        &db::UpsertWatchlistParams {
            plate: db::normalize_plate("BOLOPLATE1"),
            label: Some("BOLO".to_owned()),
            note: None,
            color: None,
            notify: true,
            kind: "watch".to_owned(),
        },
    )
    .await
    .unwrap();
    assert!(db::match_watchlist(pool, "BOLOPLATE1", 0.0)
        .await
        .unwrap()
        .is_some());
    assert!(
        db::match_watchlist(pool, "BOLOPLATE2", 0.0)
            .await
            .unwrap()
            .is_none(),
        "exact match only at fuzz 0"
    );
    assert!(
        db::match_watchlist(pool, "BOLOPLATE2", 0.5)
            .await
            .unwrap()
            .is_some(),
        "a 1-char misread of a watched plate should alert under fuzz"
    );
}

/// The length-scaled character-tolerance model (migration 0054, replacing the
/// old pg_trgm similarity threshold). `allowed_edits = floor(fuzz * len)` where
/// `len` is the *entry* plate's normalized length, and a read matches iff its
/// Levenshtein distance to the entry is within that budget. All plates here are
/// distinctive so they don't collide with other tests sharing the Postgres.
#[tokio::test]
async fn watchlist_character_tolerance_model() {
    let app = TestApp::new().await;
    let pool = app.pool();

    // Ignore entry, 9 chars. At fuzz 0.2, allowed_edits = floor(0.2 * 9) =
    // floor(1.8) = 1, so a single-character misread is tolerated.
    db::upsert_watchlist_entry(
        pool,
        &db::UpsertWatchlistParams {
            plate: db::normalize_plate("PARKEDCAR"),
            label: Some("nuisance".to_owned()),
            note: None,
            color: None,
            notify: false,
            kind: "ignore".to_owned(),
        },
    )
    .await
    .unwrap();
    // distance("PARKEDCAB", "PARKEDCAR") = 1  <= 1  -> ignored.
    assert!(
        db::is_plate_ignored(pool, "PARKEDCAB", 0.2).await.unwrap(),
        "a 1-char misread of a 9-char ignore plate is within floor(0.2*9)=1 edit"
    );
    // A wildly different plate is far outside the 1-edit budget.
    assert!(
        !db::is_plate_ignored(pool, "ZZ0000ZZ", 0.2).await.unwrap(),
        "an unrelated plate must not be swept up by fuzzy ignore matching"
    );
    // fuzz 0 -> floor(0.0*9)=0 edits: only an exact (post-normalize) match.
    assert!(
        !db::is_plate_ignored(pool, "PARKEDCAB", 0.0).await.unwrap(),
        "at fuzz 0 a 1-char misread is NOT ignored"
    );

    // Watch entry, 7 chars. At fuzz 0.2, allowed_edits = floor(0.2 * 7) =
    // floor(1.4) = 1.
    db::upsert_watchlist_entry(
        pool,
        &db::UpsertWatchlistParams {
            plate: db::normalize_plate("7ABC123"),
            label: Some("BOLO".to_owned()),
            note: None,
            color: None,
            notify: true,
            kind: "watch".to_owned(),
        },
    )
    .await
    .unwrap();
    // distance("7ABC124", "7ABC123") = 1  <= 1  -> alert match.
    let m = db::match_watchlist(pool, "7ABC124", 0.2).await.unwrap();
    assert_eq!(
        m.as_ref().map(|e| e.plate.as_str()),
        Some("7ABC123"),
        "a 1-char misread of a 7-char watch plate matches under floor(0.2*7)=1 edit"
    );
    // distance("7XYZ123", "7ABC123") = 3 (ABC -> XYZ)  > 1  -> no match.
    assert!(
        db::match_watchlist(pool, "7XYZ123", 0.2)
            .await
            .unwrap()
            .is_none(),
        "a 3-char difference exceeds the 1-edit budget at fuzz 0.2"
    );

    // Normalization: fuzz 0 requires an exact match, but only AFTER stripping
    // non-alphanumerics and upper-casing, so "7abc-123" == "7ABC123".
    let norm = db::match_watchlist(pool, "7abc-123", 0.0).await.unwrap();
    assert_eq!(
        norm.as_ref().map(|e| e.plate.as_str()),
        Some("7ABC123"),
        "normalization makes 7abc-123 an exact match at fuzz 0"
    );
    // ...but a real 1-char misread is not an exact match at fuzz 0.
    assert!(
        db::match_watchlist(pool, "7ABC124", 0.0)
            .await
            .unwrap()
            .is_none(),
        "at fuzz 0 only exact (post-normalize) plates match"
    );
}

#[tokio::test]
async fn lpr_config_requires_admin() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    // A viewer WITH view_plates still must not read/write the LPR config.
    let user = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;

    let resp = app.send(get_auth("/config/lpr", &token)).await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "GET /config/lpr is admin-only"
    );
}

#[tokio::test]
async fn lpr_config_never_leaks_ingest_token() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let resp = app.send(get_auth("/config/lpr", &token)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    // The catastrophic regression to guard: the write-only ingest token must
    // NEVER appear in the response — only the boolean `has_ingest_token`.
    assert!(
        v.get("ingest_token").is_none(),
        "response must not carry the ingest_token, got: {v}"
    );
    assert!(v.get("has_ingest_token").is_some());
}

/// Regression for #125: a partial `PUT /config/lpr` body must leave the fields
/// the caller omitted at their currently-stored values (serde defaults must not
/// nuke retention/fuzz when only `enabled` is sent).
#[tokio::test]
async fn lpr_config_partial_update_preserves_other_fields() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    // First, set all fields to distinctive non-default values.
    let resp = app
        .send(put_auth_json(
            "/config/lpr",
            &token,
            &serde_json::json!({
                "enabled": true,
                "retention_days": 45,
                "watchlist_fuzz": 0.3,
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["enabled"], true);
    assert_eq!(v["retention_days"], 45);
    assert!((v["watchlist_fuzz"].as_f64().unwrap() - 0.3).abs() < 1e-6);

    // Now send a PARTIAL update touching only `enabled`. retention_days and
    // watchlist_fuzz must be untouched, not reset to serde defaults.
    let resp = app
        .send(put_auth_json(
            "/config/lpr",
            &token,
            &serde_json::json!({ "enabled": false }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["enabled"], false, "the field we sent must change");
    assert_eq!(
        v["retention_days"], 45,
        "omitted retention_days must be preserved, not reset"
    );
    assert!(
        (v["watchlist_fuzz"].as_f64().unwrap() - 0.3).abs() < 1e-6,
        "omitted watchlist_fuzz must be preserved, not reset"
    );

    // And a partial update of just watchlist_fuzz leaves enabled/retention.
    let resp = app
        .send(put_auth_json(
            "/config/lpr",
            &token,
            &serde_json::json!({ "watchlist_fuzz": 0.1 }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["enabled"], false, "omitted enabled must be preserved");
    assert_eq!(
        v["retention_days"], 45,
        "omitted retention_days must be preserved"
    );
    assert!((v["watchlist_fuzz"].as_f64().unwrap() - 0.1).abs() < 1e-6);
}
