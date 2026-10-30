// SPDX-License-Identifier: AGPL-3.0-or-later

//! Integration tests for plate corrections (issue #673): the
//! `/lpr/plate-aliases` CRUD, `/lpr/plate-alias-suggestions`, and alias
//! resolution in `GET /plates`, `POST /lpr/plates/stats`, `GET /lpr/overview`
//! and ingest-time watchlist matching. Covers authentication, the
//! `view_plates` gate on reads, admin-only writes, chain flattening, camera
//! scoping of the counts, and that undoing a correction restores the raw view.
//!
//! The tests share one Postgres with every other test binary, and aliases are
//! global, so every test uses its own cameras and unique plate strings.
#![allow(clippy::too_many_lines)]
#![allow(clippy::items_after_statements)]

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

/// A plate string no other test (or test run) will produce.
fn fresh_plate() -> String {
    format!("T{}", &Uuid::new_v4().simple().to_string()[..9]).to_uppercase()
}

/// `plate` with its last character replaced by `X`: one real (non-confusable)
/// edit away, the shape of a typical one-character misread.
fn misread_of(plate: &str) -> String {
    format!("{}X", &plate[..plate.len() - 1])
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

fn delete_auth(uri: &str, token: &str) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("DELETE")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(axum::body::Body::empty())
        .unwrap()
}

async fn admin_token(app: &TestApp) -> String {
    let admin = seed_admin(app.pool()).await;
    login(app, &admin.username, &admin.password).await
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

async fn correct(app: &TestApp, token: &str, alias: &str, canonical: &str) -> StatusCode {
    app.send(post_auth_json(
        "/lpr/plate-aliases",
        token,
        &serde_json::json!({ "alias": alias, "canonical": canonical }),
    ))
    .await
    .status()
}

async fn plates_exact(app: &TestApp, token: &str, cam: Uuid, q: &str) -> serde_json::Value {
    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam}&q={q}&match=exact"),
            token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    body_json(resp).await
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

#[tokio::test]
async fn aliases_require_auth_view_plates_and_admin_writes() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;

    // No session at all.
    for uri in [
        "/lpr/plate-aliases",
        "/lpr/plate-alias-suggestions?plate=ABC123",
    ] {
        let resp = app.send(get(uri)).await;
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED, "{uri}");
    }

    // Without view_plates, even the reads are refused.
    let user = seed_viewer_no_plates(app.pool(), &[cam]).await;
    let token = login(&app, &user.username, &user.password).await;
    for uri in [
        "/lpr/plate-aliases",
        "/lpr/plate-alias-suggestions?plate=ABC123",
    ] {
        let resp = app.send(get_auth(uri, &token)).await;
        assert_eq!(resp.status(), StatusCode::FORBIDDEN, "{uri}");
    }

    // A viewer WITH view_plates can read but not write.
    let viewer = seed_viewer(app.pool(), &[cam]).await;
    let vtoken = login(&app, &viewer.username, &viewer.password).await;
    let resp = app.send(get_auth("/lpr/plate-aliases", &vtoken)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    let canonical = fresh_plate();
    let alias = misread_of(&canonical);
    assert_eq!(
        correct(&app, &vtoken, &alias, &canonical).await,
        StatusCode::FORBIDDEN,
        "POST /lpr/plate-aliases is admin-only"
    );
    let admin = admin_token(&app).await;
    assert_eq!(
        correct(&app, &admin, &alias, &canonical).await,
        StatusCode::CREATED
    );
    let resp = app
        .send(delete_auth(&format!("/lpr/plate-aliases/{alias}"), &vtoken))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "DELETE /lpr/plate-aliases is admin-only"
    );
    let resp = app
        .send(delete_auth(&format!("/lpr/plate-aliases/{alias}"), &admin))
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    // Gone: a second delete is a 404.
    let resp = app
        .send(delete_auth(&format!("/lpr/plate-aliases/{alias}"), &admin))
        .await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn alias_rejects_blank_and_self() {
    let app = TestApp::new().await;
    let token = admin_token(&app).await;
    let plate = fresh_plate();
    assert_eq!(
        correct(&app, &token, "---", &plate).await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        correct(&app, &token, &plate, "  ").await,
        StatusCode::BAD_REQUEST
    );
    // Same plate after normalization.
    assert_eq!(
        correct(&app, &token, &plate.to_lowercase(), &plate).await,
        StatusCode::BAD_REQUEST
    );
    let resp = app
        .send(get_auth("/lpr/plate-alias-suggestions?plate=--", &token))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn correction_resolves_in_search_stats_and_overview_and_undo_restores() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let canonical = fresh_plate();
    let alias = misread_of(&canonical);
    let now = Utc::now() - Duration::seconds(5);
    seed_read(app.pool(), cam, &canonical, now).await;
    seed_read(app.pool(), cam, &canonical, now - Duration::minutes(1)).await;
    seed_read(app.pool(), cam, &alias, now - Duration::minutes(2)).await;
    let token = admin_token(&app).await;

    // Name the canonical plate so the corrected read picks the name up.
    let resp = app
        .send(put_auth_json(
            "/lpr/plate-labels",
            &token,
            &serde_json::json!({ "plate": &canonical, "label": "Test car" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Before: two plates.
    let v = plates_exact(&app, &token, cam, &canonical).await;
    assert_eq!(v["total"], 2);
    let ov_uri = format!("/lpr/overview?camera_ids={cam}");
    let ov = body_json(app.send(get_auth(&ov_uri, &token)).await).await;
    assert_eq!(ov["reads_today"], 3);
    assert_eq!(ov["unique_today"], 2);

    // The suggestion for the misread is the canonical plate, with its reads.
    let resp = app
        .send(get_auth(
            &format!(
                "/lpr/plate-alias-suggestions?plate={}",
                alias.to_lowercase()
            ),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let sug = body_json(resp).await;
    assert_eq!(sug["plate"], alias);
    assert_eq!(sug["canonical_plate"], alias);
    assert_eq!(sug["reads"], 1);
    let first = &sug["suggestions"][0];
    assert_eq!(first["plate"], canonical);
    assert_eq!(first["reads"], 2);
    assert_eq!(first["distance"], 1);
    assert_eq!(first["display_name"], "Test car");

    // Correct it.
    let resp = app
        .send(post_auth_json(
            "/lpr/plate-aliases",
            &token,
            &serde_json::json!({ "alias": &alias, "canonical": &canonical }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let created = body_json(resp).await;
    assert_eq!(created["alias"]["alias_plate"], alias);
    assert_eq!(created["alias"]["canonical_plate"], canonical);
    assert_eq!(created["alias"]["reads"], 1);
    assert!(created["alias"]["created_by"].is_string());

    // Search: an exact search for the canonical plate returns the misread
    // too, served as the canonical plate with the raw read kept.
    let v = plates_exact(&app, &token, cam, &canonical).await;
    assert_eq!(v["total"], 3);
    let reads = v["plates"].as_array().unwrap();
    assert!(reads.iter().all(|r| r["plate"] == canonical));
    assert!(reads.iter().all(|r| r["display_name"] == "Test car"));
    let corrected: Vec<_> = reads
        .iter()
        .filter(|r| !r["corrected_from"].is_null())
        .collect();
    assert_eq!(corrected.len(), 1);
    assert_eq!(corrected[0]["corrected_from"], alias);
    // Searching the misread string still finds the read (raw text is kept).
    let v = plates_exact(&app, &token, cam, &alias).await;
    assert_eq!(v["total"], 1);
    assert_eq!(v["plates"][0]["plate"], canonical);
    // Contains on the canonical string finds the corrected read as well.
    let resp = app
        .send(get_auth(
            &format!("/plates?camera_ids={cam}&q={canonical}&match=contains"),
            &token,
        ))
        .await;
    assert_eq!(body_json(resp).await["total"], 3);

    // Stats: one entry with all three reads, whichever string is asked for.
    let v = stats(&app, &token, &[&canonical, &alias]).await;
    let entries = v["plates"].as_array().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["plate"], canonical);
    assert_eq!(entries[0]["total"], 3);
    assert_eq!(entries[0]["cameras"][0]["n"], 3);
    let v = stats(&app, &token, &[&alias]).await;
    assert_eq!(v["plates"][0]["plate"], canonical);
    assert_eq!(v["plates"][0]["total"], 3);

    // Overview: one unique plate today.
    let ov = body_json(app.send(get_auth(&ov_uri, &token)).await).await;
    assert_eq!(ov["reads_today"], 3);
    assert_eq!(ov["unique_today"], 1);
    assert_eq!(ov["new_today"], 1);

    // The profile's list of known misreads.
    let resp = app
        .send(get_auth(
            &format!("/lpr/plate-aliases?canonical={}", canonical.to_lowercase()),
            &token,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let list = body_json(resp).await;
    let list = list.as_array().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["alias_plate"], alias);
    assert_eq!(list[0]["reads"], 1);

    // The misread is no longer suggested against the canonical plate's
    // own misread (it already counts as it).
    let sug = body_json(
        app.send(get_auth(
            &format!("/lpr/plate-alias-suggestions?plate={alias}"),
            &token,
        ))
        .await,
    )
    .await;
    assert_eq!(sug["canonical_plate"], canonical);
    assert!(sug["suggestions"]
        .as_array()
        .unwrap()
        .iter()
        .all(|s| s["plate"] != canonical));

    // Undo: back to two plates, raw reads untouched.
    let resp = app
        .send(delete_auth(&format!("/lpr/plate-aliases/{alias}"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    let v = plates_exact(&app, &token, cam, &canonical).await;
    assert_eq!(v["total"], 2);
    let v = plates_exact(&app, &token, cam, &alias).await;
    assert_eq!(v["plates"][0]["plate"], alias);
    assert!(v["plates"][0]["corrected_from"].is_null());
    let ov = body_json(app.send(get_auth(&ov_uri, &token)).await).await;
    assert_eq!(ov["unique_today"], 2);
}

#[tokio::test]
async fn chains_are_flattened_and_reversal_swaps() {
    let app = TestApp::new().await;
    let pool = app.pool();
    let token = admin_token(&app).await;
    let a = fresh_plate();
    let b = fresh_plate();
    let c = fresh_plate();

    // A -> B, then B -> C: A moves to C, nothing points at an alias.
    assert_eq!(correct(&app, &token, &a, &b).await, StatusCode::CREATED);
    let resp = app
        .send(post_auth_json(
            "/lpr/plate-aliases",
            &token,
            &serde_json::json!({ "alias": &b, "canonical": &c }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let created = body_json(resp).await;
    assert_eq!(created["moved"], serde_json::json!([a.clone()]));
    assert_eq!(db::resolve_plate_alias(pool, &a).await.unwrap(), c);
    assert_eq!(db::resolve_plate_alias(pool, &b).await.unwrap(), c);

    // D -> A (A is itself an alias of C): stored as D -> C.
    let d = fresh_plate();
    assert_eq!(correct(&app, &token, &d, &a).await, StatusCode::CREATED);
    assert_eq!(db::resolve_plate_alias(pool, &d).await.unwrap(), c);

    // Reverse B -> C as C -> B: B becomes canonical, C and the others follow.
    assert_eq!(correct(&app, &token, &c, &b).await, StatusCode::CREATED);
    for p in [&a, &c, &d] {
        assert_eq!(db::resolve_plate_alias(pool, p).await.unwrap(), b);
    }
    assert_eq!(db::resolve_plate_alias(pool, &b).await.unwrap(), b);
    let mut of_b: Vec<String> = db::plate_aliases_of(pool, std::slice::from_ref(&b))
        .await
        .unwrap()
        .into_iter()
        .map(|(alias, _)| alias)
        .collect();
    of_b.sort();
    let mut want = vec![a.clone(), c.clone(), d.clone()];
    want.sort();
    assert_eq!(of_b, want);
    // No alias is anyone's canonical plate.
    for p in [&a, &c, &d] {
        assert!(db::plate_aliases_of(pool, std::slice::from_ref(p))
            .await
            .unwrap()
            .is_empty());
    }
}

#[tokio::test]
async fn counts_are_camera_scoped() {
    let app = TestApp::new().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    let canonical = fresh_plate();
    let alias = misread_of(&canonical);
    let hidden = fresh_plate();
    let hidden_near = misread_of(&hidden);
    let now = Utc::now() - Duration::seconds(5);
    seed_read(app.pool(), cam_a, &canonical, now).await;
    seed_read(app.pool(), cam_a, &alias, now).await;
    seed_read(app.pool(), cam_b, &alias, now).await;
    seed_read(app.pool(), cam_b, &alias, now).await;
    // A plate only seen on cam_b.
    seed_read(app.pool(), cam_b, &hidden, now).await;

    let admin = admin_token(&app).await;
    assert_eq!(
        correct(&app, &admin, &alias, &canonical).await,
        StatusCode::CREATED
    );

    let viewer = seed_viewer(app.pool(), &[cam_a]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    // The alias list counts only cam_a's read of the misread.
    let list = body_json(
        app.send(get_auth(
            &format!("/lpr/plate-aliases?canonical={canonical}"),
            &token,
        ))
        .await,
    )
    .await;
    assert_eq!(list[0]["reads"], 1);
    // Stats: cam_a only (canonical + one misread).
    let v = stats(&app, &token, &[&canonical]).await;
    assert_eq!(v["plates"][0]["total"], 2);
    let v = stats(&app, &admin, &[&canonical]).await;
    assert_eq!(v["plates"][0]["total"], 4);

    // Suggestions never reveal a plate seen only on a camera out of scope.
    let sug = body_json(
        app.send(get_auth(
            &format!("/lpr/plate-alias-suggestions?plate={hidden_near}"),
            &token,
        ))
        .await,
    )
    .await;
    assert!(sug["suggestions"].as_array().unwrap().is_empty());
    let sug = body_json(
        app.send(get_auth(
            &format!("/lpr/plate-alias-suggestions?plate={hidden_near}"),
            &admin,
        ))
        .await,
    )
    .await;
    assert_eq!(sug["suggestions"][0]["plate"], hidden);
}

#[tokio::test]
async fn ingest_matching_resolves_corrections() {
    let app = TestApp::new().await;
    let pool = app.pool();
    let token = admin_token(&app).await;
    let watched = fresh_plate();
    let misread = misread_of(&watched);
    let ignored = fresh_plate();
    let ignored_misread = format!("Q{}", &ignored[1..]);

    db::upsert_watchlist_entry(
        pool,
        &db::UpsertWatchlistParams {
            plate: watched.clone(),
            label: None,
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
            plate: ignored.clone(),
            label: None,
            note: None,
            color: None,
            notify: true,
            kind: "ignore".to_owned(),
        },
    )
    .await
    .unwrap();

    // Exact matching (fuzz 0): the misreads do not match on their own.
    assert!(db::match_watchlist(pool, &misread, 0.0)
        .await
        .unwrap()
        .is_none());
    assert!(!db::is_plate_ignored(pool, &ignored_misread, 0.0)
        .await
        .unwrap());

    // Once corrected, they match as their canonical plate.
    assert_eq!(
        correct(&app, &token, &misread, &watched).await,
        StatusCode::CREATED
    );
    assert_eq!(
        correct(&app, &token, &ignored_misread, &ignored).await,
        StatusCode::CREATED
    );
    let hit = db::match_watchlist(pool, &misread, 0.0).await.unwrap();
    assert_eq!(hit.map(|e| e.plate), Some(watched.clone()));
    assert!(db::is_plate_ignored(pool, &ignored_misread, 0.0)
        .await
        .unwrap());
}

/// The alias list and the suggestions endpoint must not reveal plate strings
/// (misreads or canonical plates) that were only read on cameras the caller
/// cannot see, nor the creating admin's username.
#[tokio::test]
async fn alias_list_and_suggestions_are_camera_scoped() {
    let app = TestApp::new().await;
    let cam_a = seed_camera(app.pool()).await;
    let cam_b = seed_camera(app.pool()).await;
    let now = Utc::now() - Duration::seconds(5);

    // Visible correction: both plates read on cam_a.
    let vis_canon = fresh_plate();
    let vis_alias = misread_of(&vis_canon);
    seed_read(app.pool(), cam_a, &vis_canon, now).await;
    seed_read(app.pool(), cam_a, &vis_alias, now).await;
    // Hidden correction: both plates only ever read on cam_b.
    let hid_canon = fresh_plate();
    let hid_alias = misread_of(&hid_canon);
    seed_read(app.pool(), cam_b, &hid_canon, now).await;
    seed_read(app.pool(), cam_b, &hid_alias, now).await;
    // Mixed: canonical read on both cameras, misread only on cam_b: visible
    // through the canonical.
    let mix_canon = fresh_plate();
    let mix_alias = misread_of(&mix_canon);
    seed_read(app.pool(), cam_a, &mix_canon, now).await;
    seed_read(app.pool(), cam_b, &mix_alias, now).await;

    let admin = admin_token(&app).await;
    for (a, c) in [
        (&vis_alias, &vis_canon),
        (&hid_alias, &hid_canon),
        (&mix_alias, &mix_canon),
    ] {
        assert_eq!(correct(&app, &admin, a, c).await, StatusCode::CREATED);
    }

    let viewer = seed_viewer(app.pool(), &[cam_a]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let list = body_json(app.send(get_auth("/lpr/plate-aliases", &token)).await).await;
    let rows = list.as_array().unwrap();
    let has = |alias: &str| rows.iter().any(|r| r["alias_plate"] == alias);
    assert!(has(&vis_alias), "visible correction is listed");
    assert!(has(&mix_alias), "visible via its canonical plate");
    assert!(!has(&hid_alias), "cam_b-only correction must not leak");
    assert!(
        !rows.iter().any(|r| r["canonical_plate"] == hid_canon.as_str()),
        "cam_b-only canonical plate must not leak"
    );
    assert!(
        rows.iter().all(|r| r["created_by"].is_null()),
        "non-admins never see admin usernames"
    );

    // Admins still see everything, including who made the correction.
    let list = body_json(app.send(get_auth("/lpr/plate-aliases", &admin)).await).await;
    let rows = list.as_array().unwrap();
    assert!(rows.iter().any(|r| r["alias_plate"] == hid_alias.as_str()));
    assert!(rows
        .iter()
        .any(|r| r["alias_plate"] == hid_alias.as_str() && r["created_by"].is_string()));

    // Suggestions: the hidden plate's group is not revealed.
    let sug = body_json(
        app.send(get_auth(
            &format!("/lpr/plate-alias-suggestions?plate={hid_canon}"),
            &token,
        ))
        .await,
    )
    .await;
    assert!(sug["aliases"].as_array().unwrap().is_empty());
    assert_eq!(sug["reads"], 0);
    let sug = body_json(
        app.send(get_auth(
            &format!("/lpr/plate-alias-suggestions?plate={hid_alias}"),
            &token,
        ))
        .await,
    )
    .await;
    assert_eq!(
        sug["canonical_plate"], hid_alias.as_str(),
        "a hidden canonical plate is not disclosed"
    );
    // Admin sees the real canonical plate.
    let sug = body_json(
        app.send(get_auth(
            &format!("/lpr/plate-alias-suggestions?plate={hid_alias}"),
            &admin,
        ))
        .await,
    )
    .await;
    assert_eq!(sug["canonical_plate"], hid_canon.as_str());
    // Visible group still reports its aliases to the scoped viewer.
    let sug = body_json(
        app.send(get_auth(
            &format!("/lpr/plate-alias-suggestions?plate={vis_canon}"),
            &token,
        ))
        .await,
    )
    .await;
    assert_eq!(sug["aliases"][0], vis_alias.as_str());
}
