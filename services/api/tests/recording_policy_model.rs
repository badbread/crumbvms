// SPDX-License-Identifier: AGPL-3.0-or-later

//! Phase 1 of the recording-policy model redesign (docs/design/POLICY-MODEL.md):
//! every camera belongs to a NAMED policy; a camera-scoped edit no-ops when
//! unchanged, de-dups onto an existing named policy, edits its own deviation in
//! place, or mints a new named deviation policy — and the collapse migration
//! folds byte-identical ghost forks into Default under the pool/drain guards.
//!
//! FOOTAGE-SACRED coverage: the migration test (isolated throwaway database)
//! asserts the invariant that every camera's EFFECTIVE policy values are
//! unchanged and that the pool/drain guards keep an un-mergeable fork instead of
//! collapsing it.

// The harness (`mod support`) `#[path]`-includes the real `src/` modules, which
// clippy re-lints in this test binary; mirror auth_rbac.rs's allow-set.
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

use axum::http::StatusCode;
use crumb_common::db;
use support::*;
use uuid::Uuid;

// ── small request/response helpers ───────────────────────────────────────────

fn post_auth_json(
    uri: &str,
    token: &str,
    body: &serde_json::Value,
) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body.to_string()))
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

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> serde_json::Value {
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .expect("read response body");
    serde_json::from_slice(&bytes).expect("parse response JSON")
}

fn parse_uuid(v: &serde_json::Value, key: &str) -> Uuid {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("field {key} missing/not a string in {v}"))
        .parse()
        .expect("valid uuid")
}

/// A retention-hours value chosen high and per-call-unique so a deviation's
/// field-set stays globally distinct in the shared test DB (it never collides
/// with the Default's 48h nor another test's/leftover deviation), so
/// `find_matching_policy` mints rather than accidentally joining a stray row.
fn uniq_hours() -> i32 {
    let n = Uuid::new_v4().as_u128();
    500_000 + (n % 400_000) as i32
}

/// Create a camera through the real `POST /config/cameras` route (legacy path:
/// go2rtc_name + main_url, no source_url ⇒ no go2rtc reconcile) and return its
/// id + name. Under the new model this camera JOINS the Default policy row.
async fn create_camera_on_default(app: &TestApp, token: &str) -> (Uuid, String) {
    let name = unique("cam");
    let go2 = unique("go2");
    let body = serde_json::json!({
        "name": name,
        "go2rtc_name": go2,
        "main_url": "rtsp://127.0.0.1:18554/does-not-matter",
        "enabled": true,
    });
    let resp = app
        .send(post_auth_json("/config/cameras", token, &body))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED, "camera create must 201");
    let v = body_json(resp).await;
    (parse_uuid(&v, "id"), name)
}

// ── endpoint semantics (shared DB, isolated by this test's own rows) ──────────

/// A newly-created camera JOINS the Default policy row — no clone, no ghost fork.
#[tokio::test]
async fn create_camera_joins_default_row() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let default_id = db::get_default_policy(app.pool())
        .await
        .expect("get_default_policy")
        .id;
    let (cam_id, _name) = create_camera_on_default(&app, &token).await;

    let cam = db::get_camera(app.pool(), cam_id)
        .await
        .expect("get_camera")
        .expect("camera exists");
    assert_eq!(
        cam.policy_id,
        Some(default_id),
        "a new camera must be pinned to the Default policy row, not a clone"
    );
    assert!(cam.policy.is_default, "effective policy is the default");
}

/// An unchanged save (empty patch) mints/forks NOTHING — the regression guard for
/// the old Motion-tab ghost factory.
#[tokio::test]
async fn no_op_save_mints_nothing() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let default_id = db::get_default_policy(app.pool())
        .await
        .expect("get_default_policy")
        .id;
    let (cam_id, _name) = create_camera_on_default(&app, &token).await;

    let resp = app
        .send(put_auth_json(
            &format!("/config/cameras/{cam_id}/policy"),
            &token,
            &serde_json::json!({}),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(parse_uuid(&v, "id"), default_id, "no-op returns Default");
    assert_eq!(v["is_default"], serde_json::json!(true));

    let cam = db::get_camera(app.pool(), cam_id)
        .await
        .expect("get_camera")
        .expect("camera");
    assert_eq!(
        cam.policy_id,
        Some(default_id),
        "unchanged save must NOT fork the camera off Default"
    );
}

/// A genuine deviation mints a new named policy after the camera (origin
/// 'deviation'), and pins the camera to it.
#[tokio::test]
async fn deviation_edit_mints_named_policy() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let default_id = db::get_default_policy(app.pool())
        .await
        .expect("default")
        .id;
    let (cam_id, cam_name) = create_camera_on_default(&app, &token).await;
    let hours = uniq_hours();

    let resp = app
        .send(put_auth_json(
            &format!("/config/cameras/{cam_id}/policy"),
            &token,
            &serde_json::json!({ "live_retention_hours": hours }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    let new_id = parse_uuid(&v, "id");
    assert_ne!(new_id, default_id, "deviation must not reuse Default");
    assert_eq!(v["is_default"], serde_json::json!(false));
    assert_eq!(v["origin"], serde_json::json!("deviation"));
    assert_eq!(
        v["name"],
        serde_json::json!(cam_name),
        "auto-named after camera"
    );
    assert_eq!(v["live_retention_hours"], serde_json::json!(hours));

    let cam = db::get_camera(app.pool(), cam_id)
        .await
        .expect("get_camera")
        .expect("camera");
    assert_eq!(cam.policy_id, Some(new_id));
}

/// Reverting a deviated camera to Default's values rejoins Default and inline-reaps
/// the now-orphaned deviation policy (de-dup collapse + reap).
#[tokio::test]
async fn revert_to_default_rejoins_and_reaps() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let default = db::get_default_policy(app.pool()).await.expect("default");
    let (cam_id, _name) = create_camera_on_default(&app, &token).await;
    let policy_uri = format!("/config/cameras/{cam_id}/policy");

    // Deviate.
    let resp = app
        .send(put_auth_json(
            &policy_uri,
            &token,
            &serde_json::json!({ "live_retention_hours": uniq_hours() }),
        ))
        .await;
    let dev_id = parse_uuid(&body_json(resp).await, "id");
    assert_ne!(dev_id, default.id);

    // Revert the changed knob to Default's value.
    let resp = app
        .send(put_auth_json(
            &policy_uri,
            &token,
            &serde_json::json!({ "live_retention_hours": default.live_retention_hours }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(parse_uuid(&v, "id"), default.id, "rejoined Default");
    assert_eq!(v["is_default"], serde_json::json!(true));

    let cam = db::get_camera(app.pool(), cam_id)
        .await
        .expect("get_camera")
        .expect("camera");
    assert_eq!(cam.policy_id, Some(default.id));
    assert!(
        db::get_policy(app.pool(), dev_id)
            .await
            .expect("get_policy")
            .is_none(),
        "the orphaned deviation policy must be inline-reaped"
    );
}

/// De-dup: editing a camera onto an operator template's exact values JOINS that
/// template (no new policy) and reaps the deviation it left behind.
#[tokio::test]
async fn dedup_join_to_template_reaps_old_deviation() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let hours = uniq_hours();
    // Operator template = Default's values with a unique retention.
    let tmpl_name = unique("Indoor");
    let resp = app
        .send(post_auth_json(
            "/config/policies",
            &token,
            &serde_json::json!({ "name": tmpl_name, "live_retention_hours": hours }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    let tmpl = body_json(resp).await;
    let tmpl_id = parse_uuid(&tmpl, "id");
    assert_eq!(tmpl["origin"], serde_json::json!("operator"));

    let (cam_id, _name) = create_camera_on_default(&app, &token).await;
    let policy_uri = format!("/config/cameras/{cam_id}/policy");

    // First deviate to a DIFFERENT unique value (mints a deviation policy).
    let resp = app
        .send(put_auth_json(
            &policy_uri,
            &token,
            &serde_json::json!({ "live_retention_hours": uniq_hours() }),
        ))
        .await;
    let dev_id = parse_uuid(&body_json(resp).await, "id");
    assert_ne!(dev_id, tmpl_id);

    // Now edit to exactly match the template ⇒ join it, reap the old deviation.
    let resp = app
        .send(put_auth_json(
            &policy_uri,
            &token,
            &serde_json::json!({ "live_retention_hours": hours }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(parse_uuid(&v, "id"), tmpl_id, "camera joined the template");

    let cam = db::get_camera(app.pool(), cam_id)
        .await
        .expect("get_camera")
        .expect("camera");
    assert_eq!(cam.policy_id, Some(tmpl_id));
    assert!(
        db::get_policy(app.pool(), dev_id)
            .await
            .expect("get_policy")
            .is_none(),
        "the left-behind deviation must be reaped"
    );
    // The operator template survives (it is referenced now, and never reaped).
    assert!(db::get_policy(app.pool(), tmpl_id)
        .await
        .expect("get_policy")
        .is_some());
}

/// Editing a camera that SOLELY owns a deviation policy edits that policy IN
/// PLACE (same id) rather than minting a second one.
#[tokio::test]
async fn sole_owner_deviation_edited_in_place() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let (cam_id, _name) = create_camera_on_default(&app, &token).await;
    let policy_uri = format!("/config/cameras/{cam_id}/policy");

    let resp = app
        .send(put_auth_json(
            &policy_uri,
            &token,
            &serde_json::json!({ "live_retention_hours": uniq_hours() }),
        ))
        .await;
    let dev_id = parse_uuid(&body_json(resp).await, "id");

    let hours2 = uniq_hours();
    let resp = app
        .send(put_auth_json(
            &policy_uri,
            &token,
            &serde_json::json!({ "live_retention_hours": hours2 }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(
        parse_uuid(&v, "id"),
        dev_id,
        "edited the SAME deviation in place"
    );
    assert_eq!(v["live_retention_hours"], serde_json::json!(hours2));
    assert_eq!(v["origin"], serde_json::json!("deviation"));
}

/// Renaming a deviation policy via `PUT /config/policies/{id}` promotes it to an
/// operator template (a keeper: never reaped even at zero members).
#[tokio::test]
async fn rename_deviation_promotes_to_operator() {
    let app = TestApp::new().await;
    let admin = seed_admin(app.pool()).await;
    let token = login(&app, &admin.username, &admin.password).await;

    let (cam_id, _name) = create_camera_on_default(&app, &token).await;
    let resp = app
        .send(put_auth_json(
            &format!("/config/cameras/{cam_id}/policy"),
            &token,
            &serde_json::json!({ "live_retention_hours": uniq_hours() }),
        ))
        .await;
    let dev = body_json(resp).await;
    let dev_id = parse_uuid(&dev, "id");
    assert_eq!(dev["origin"], serde_json::json!("deviation"));

    let new_name = unique("Kept");
    let resp = app
        .send(put_auth_json(
            &format!("/config/policies/{dev_id}"),
            &token,
            &serde_json::json!({ "name": new_name }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v = body_json(resp).await;
    assert_eq!(v["name"], serde_json::json!(new_name));
    assert_eq!(
        v["origin"],
        serde_json::json!("operator"),
        "renaming a deviation promotes it to an operator template"
    );

    let promoted = db::get_policy(app.pool(), dev_id)
        .await
        .expect("get_policy")
        .expect("policy");
    assert_eq!(promoted.origin, "operator");
}

// ── db-layer reap semantics (scoped to explicit ids) ─────────────────────────

/// Build a `PolicyFields` for a named policy = Default's shape with a distinct
/// retention. A free fn (not a closure) so the returned borrow can outlive the
/// call across the `&str` argument + captured `&str`s.
fn mk_fields<'a>(
    name: &'a str,
    hours: i32,
    mode: &'a str,
    sens: &'a str,
    stream: &'a str,
) -> db::PolicyFields<'a> {
    db::PolicyFields {
        name: Some(name),
        mode,
        live_storage_id: None,
        live_retention_hours: hours,
        archive_enabled: false,
        archive_storage_id: None,
        archive_schedule: None,
        archive_retention_hours: None,
        live_max_bytes: None,
        archive_max_bytes: None,
        live_min_free_pct: None,
        live_min_free_bytes: None,
        live_spill_low_water_bytes: None,
        max_retention_days: None,
        motion_pre_seconds: 5,
        motion_post_seconds: 10,
        motion_sensitivity: sens,
        motion_threshold: None,
        motion_keyframes_only: false,
        record_stream: stream,
        record_audio: true,
    }
}

/// `reap_policy_if_orphan_deviation` deletes ONLY a memberless deviation policy;
/// operator templates and referenced deviations are kept.
#[tokio::test]
async fn inline_reap_targets_only_orphan_deviations() {
    let app = TestApp::new().await;
    let pool = app.pool();

    let base = db::get_default_policy(pool).await.expect("default");
    let mode = base.mode.as_str().to_owned();
    let sens = base.motion_sensitivity.as_str().to_owned();
    let stream = base.record_stream.as_str().to_owned();

    // Memberless deviation ⇒ reaped.
    let dev_name = unique("dev");
    let dev = db::create_policy(
        pool,
        &mk_fields(&dev_name, uniq_hours(), &mode, &sens, &stream),
        "deviation",
    )
    .await
    .expect("create deviation");
    assert_eq!(dev.origin, "deviation");
    assert!(db::reap_policy_if_orphan_deviation(pool, dev.id)
        .await
        .expect("reap"));
    assert!(db::get_policy(pool, dev.id).await.expect("get").is_none());

    // Memberless operator template ⇒ kept.
    let op_name = unique("op");
    let op = db::create_policy(
        pool,
        &mk_fields(&op_name, uniq_hours(), &mode, &sens, &stream),
        "operator",
    )
    .await
    .expect("create operator");
    assert!(!db::reap_policy_if_orphan_deviation(pool, op.id)
        .await
        .expect("reap"));
    assert!(db::get_policy(pool, op.id).await.expect("get").is_some());

    // Promote flips a deviation to operator; then it survives the reaper.
    let keep_name = unique("keeper");
    let keeper = db::create_policy(
        pool,
        &mk_fields(&keep_name, uniq_hours(), &mode, &sens, &stream),
        "deviation",
    )
    .await
    .expect("create deviation (promote)");
    assert!(db::promote_policy_to_operator(pool, keeper.id)
        .await
        .expect("promote"));
    assert!(!db::reap_policy_if_orphan_deviation(pool, keeper.id)
        .await
        .expect("reap"));
    assert!(db::get_policy(pool, keeper.id)
        .await
        .expect("get")
        .is_some());
}

// ── the collapse migration (isolated throwaway database) ──────────────────────

const MIGRATION_0067_SQL: &str =
    include_str!("../../../db/migrations/0067_recording_policy_origin_collapse.sql");

/// A throwaway, fully-migrated database that DROPs itself on scope exit — the
/// migration test mutates GLOBAL policy state (the single default row + every
/// anonymous fork), so it must not share the public test schema.
struct IsolatedDb {
    pool: deadpool_postgres::Pool,
    admin_url: String,
    dbname: String,
}

impl Drop for IsolatedDb {
    fn drop(&mut self) {
        let admin_url = self.admin_url.clone();
        let dbname = self.dbname.clone();
        tokio::spawn(async move {
            if let Ok(admin) = db::build_pool(&admin_url, 1) {
                if let Ok(c) = admin.get().await {
                    // FORCE terminates any lingering connections to the throwaway DB.
                    let _ = c
                        .execute(
                            &format!("DROP DATABASE IF EXISTS {dbname} WITH (FORCE)"),
                            &[],
                        )
                        .await;
                }
            }
        });
    }
}

/// Create + migrate an isolated database. Returns `None` (skip) when there is no
/// reachable test Postgres or the role may not `CREATE DATABASE`.
async fn make_isolated_db() -> Option<IsolatedDb> {
    let admin_url = std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .ok()?;
    // Split off any query string, then swap the dbname path segment.
    let (conn_part, query) = match admin_url.split_once('?') {
        Some((a, b)) => (a.to_owned(), Some(b.to_owned())),
        None => (admin_url.clone(), None),
    };
    let (prefix, _old_db) = conn_part.rsplit_once('/')?;
    let dbname = format!("crumb_mig_{}", Uuid::new_v4().simple());

    // CREATE DATABASE on a pool connected to the original (admin) database.
    {
        let admin = db::build_pool(&admin_url, 2).ok()?;
        let c = admin.get().await.ok()?;
        // `execute` runs in autocommit (no txn), which CREATE DATABASE requires.
        if c.execute(&format!("CREATE DATABASE {dbname}"), &[])
            .await
            .is_err()
        {
            return None;
        }
    }

    let new_conn = format!("{prefix}/{dbname}");
    let new_url = match query {
        Some(q) => format!("{new_conn}?{q}"),
        None => new_conn,
    };
    let pool = db::build_pool(&new_url, 8).ok()?;
    db::run_migrations(&pool).await.ok()?;
    db::ensure_named_policies_and_groups(&pool).await.ok()?;
    Some(IsolatedDb {
        pool,
        admin_url,
        dbname,
    })
}

async fn insert_default_policy_with_cap(pool: &deadpool_postgres::Pool, live_cap: i64) -> Uuid {
    let client = pool.get().await.expect("pool.get");
    let row = client
        .query_one(
            r"
            INSERT INTO recording_policies (
                is_default, name, origin, mode, live_storage_id, live_retention_hours,
                archive_enabled, live_max_bytes,
                motion_pre_seconds, motion_post_seconds, motion_sensitivity,
                motion_keyframes_only, record_stream
            )
            VALUES (true, 'Default', 'operator', 'continuous', NULL, 48,
                    false, $1, 5, 10, 'dynamic', false, 'main')
            RETURNING id
            ",
            &[&live_cap],
        )
        .await
        .expect("insert default policy");
    row.get(0)
}

async fn seed_cam(pool: &deadpool_postgres::Pool, policy_id: Uuid) -> (Uuid, String) {
    let suffix = Uuid::new_v4().simple().to_string();
    let name = format!("cam_{suffix}");
    let params = db::CreateCameraParams {
        name: &name,
        go2rtc_name: &format!("go2rtc_{suffix}"),
        main_url: "rtsp://127.0.0.1:18554/does-not-matter",
        sub_url: None,
        source_url: None,
        source_sub_url: None,
        enabled: true,
        policy_id,
        motion_mask: None,
        onvif_motion: false,
        motion_source: "pixel",
        motion_algorithm: "census",
        camera_type: None,
        icon: None,
        served_by: "crumb",
        source_camera_name: None,
        onvif_host: None,
        onvif_port: None,
        onvif_user: None,
        onvif_password: None,
        ptz_control_enabled: true,
    };
    let id = db::create_camera(pool, &params)
        .await
        .expect("create_camera")
        .id;
    (id, name)
}

async fn policy_exists(pool: &deadpool_postgres::Pool, id: Uuid) -> bool {
    db::get_policy(pool, id)
        .await
        .expect("get_policy")
        .is_some()
}

async fn camera_policy_id(pool: &deadpool_postgres::Pool, id: Uuid) -> Option<Uuid> {
    db::get_camera(pool, id)
        .await
        .expect("get_camera")
        .expect("camera")
        .policy_id
}

async fn policy_name(pool: &deadpool_postgres::Pool, id: Uuid) -> Option<String> {
    db::get_policy(pool, id)
        .await
        .expect("get_policy")
        .and_then(|p| p.name)
}

/// The collapse migration folds a byte-identical ghost fork into Default, but a
/// pool-guard fork (would exceed Default's cap) and a drain-guard fork (in-flight
/// storage migration) are KEPT and named after their camera; a genuinely-distinct
/// fork is named; an ownerless fork is deleted; and every camera's EFFECTIVE
/// policy values are unchanged (the invariant).
#[tokio::test]
async fn migration_collapse_pool_and_drain_guards_and_invariant() {
    let Some(iso) = make_isolated_db().await else {
        eprintln!("skipping: no reachable test Postgres / cannot CREATE DATABASE");
        return;
    };
    let pool = &iso.pool;

    // Default carries a small live cap so a large fork can't merge into it.
    let cap: i64 = 1000;
    let default_id = insert_default_policy_with_cap(pool, cap).await;

    // A storage for the over-cap camera's segment + the drain-guard migration.
    let storage = db::create_storage(pool, "s1", "/tmp/crumb-mig-test", None, None)
        .await
        .expect("create storage")
        .id;

    // F1: identical to Default, small (no segments) ⇒ collapses into Default.
    let f1 = db::clone_default_policy(pool).await.expect("clone f1");
    let (cam1, _n1) = seed_cam(pool, f1).await;

    // F2: distinct from Default (different retention) ⇒ kept + named.
    let f2 = db::clone_default_policy(pool).await.expect("clone f2");
    {
        let c = pool.get().await.unwrap();
        c.execute(
            "UPDATE recording_policies SET live_retention_hours = 999 WHERE id = $1",
            &[&f2],
        )
        .await
        .expect("mutate f2");
    }
    let (cam2, cam2_name) = seed_cam(pool, f2).await;

    // F3: identical to Default but its camera has a live segment > cap ⇒ pool
    // guard KEEPS it (merging would blow Default's cap) + names it.
    let f3 = db::clone_default_policy(pool).await.expect("clone f3");
    let (cam3, cam3_name) = seed_cam(pool, f3).await;
    {
        let c = pool.get().await.unwrap();
        let start = chrono::Utc::now();
        let end = start + chrono::Duration::seconds(4);
        c.execute(
            r"
            INSERT INTO segments
                (camera_id, storage_id, stage, path, stream, start_ts, end_ts,
                 duration_ms, has_motion, size_bytes)
            VALUES ($1, $2, 'live', 'seg.mp4', 'main', $3, $4, 4000, false, 5000)
            ",
            &[&cam3, &storage, &start, &end],
        )
        .await
        .expect("insert big segment");
    }

    // F4: identical to Default but has an in-flight storage migration ⇒ drain
    // guard KEEPS it + names it.
    let f4 = db::clone_default_policy(pool).await.expect("clone f4");
    let (cam4, cam4_name) = seed_cam(pool, f4).await;
    {
        let c = pool.get().await.unwrap();
        c.execute(
            r"
            INSERT INTO storage_migrations
                (id, policy_id, from_storage_id, to_storage_id, status)
            VALUES (gen_random_uuid(), $1, $2, $2, 'pending')
            ",
            &[&f4, &storage],
        )
        .await
        .expect("insert pending storage_migration");
    }

    // F5: identical to Default, ownerless (no camera) ⇒ deleted outright.
    let f5 = db::clone_default_policy(pool).await.expect("clone f5");

    // ── invariant: snapshot each camera's EFFECTIVE policy values BEFORE, run
    //    the collapse, then assert row-for-row IS NOT DISTINCT FROM. All on ONE
    //    connection so the TEMP TABLE is visible to the post-collapse compare.
    let client = pool.get().await.expect("pool.get (invariant)");
    client
        .batch_execute(
            r"
            CREATE TEMP TABLE inv_before AS
            SELECT c_id, p_mode, p_live_retention_hours, p_archive_enabled,
                   p_archive_retention_hours, p_live_max_bytes, p_archive_max_bytes,
                   p_motion_sensitivity, p_motion_threshold, p_record_stream,
                   p_record_audio, p_live_storage_id, p_archive_storage_id,
                   p_motion_pre_seconds, p_motion_post_seconds
            FROM v_camera_effective_policy;
            ",
        )
        .await
        .expect("snapshot effective policy");

    // Run the REAL migration SQL against the constructed forks.
    client
        .batch_execute(MIGRATION_0067_SQL)
        .await
        .expect("run collapse migration");

    let violations: i64 = client
        .query_one(
            r"
            SELECT COUNT(*)::bigint
            FROM v_camera_effective_policy v
            JOIN inv_before b ON b.c_id = v.c_id
            WHERE NOT (
                    v.p_mode                    IS NOT DISTINCT FROM b.p_mode
                AND v.p_live_retention_hours    IS NOT DISTINCT FROM b.p_live_retention_hours
                AND v.p_archive_enabled         IS NOT DISTINCT FROM b.p_archive_enabled
                AND v.p_archive_retention_hours IS NOT DISTINCT FROM b.p_archive_retention_hours
                AND v.p_live_max_bytes          IS NOT DISTINCT FROM b.p_live_max_bytes
                AND v.p_archive_max_bytes       IS NOT DISTINCT FROM b.p_archive_max_bytes
                AND v.p_motion_sensitivity      IS NOT DISTINCT FROM b.p_motion_sensitivity
                AND v.p_motion_threshold        IS NOT DISTINCT FROM b.p_motion_threshold
                AND v.p_record_stream           IS NOT DISTINCT FROM b.p_record_stream
                AND v.p_record_audio            IS NOT DISTINCT FROM b.p_record_audio
                AND v.p_live_storage_id         IS NOT DISTINCT FROM b.p_live_storage_id
                AND v.p_archive_storage_id      IS NOT DISTINCT FROM b.p_archive_storage_id
                AND v.p_motion_pre_seconds      IS NOT DISTINCT FROM b.p_motion_pre_seconds
                AND v.p_motion_post_seconds     IS NOT DISTINCT FROM b.p_motion_post_seconds
            )
            ",
            &[],
        )
        .await
        .expect("invariant compare")
        .get(0);
    assert_eq!(
        violations, 0,
        "MIGRATION INVARIANT VIOLATED: some camera's effective policy values changed"
    );
    drop(client);

    // F1 collapsed into Default.
    assert!(
        !policy_exists(pool, f1).await,
        "identical fork must be deleted"
    );
    assert_eq!(
        camera_policy_id(pool, cam1).await,
        Some(default_id),
        "F1's camera must repoint to Default"
    );

    // F2 (distinct) kept + named after its camera.
    assert!(policy_exists(pool, f2).await, "distinct fork must survive");
    assert_eq!(
        policy_name(pool, f2).await.as_deref(),
        Some(cam2_name.as_str())
    );
    assert_eq!(camera_policy_id(pool, cam2).await, Some(f2));

    // F3 (pool guard) kept + named.
    assert!(
        policy_exists(pool, f3).await,
        "over-cap fork must survive (pool guard)"
    );
    assert_eq!(
        policy_name(pool, f3).await.as_deref(),
        Some(cam3_name.as_str())
    );
    assert_eq!(camera_policy_id(pool, cam3).await, Some(f3));

    // F4 (drain guard) kept + named.
    assert!(
        policy_exists(pool, f4).await,
        "draining fork must survive (drain guard)"
    );
    assert_eq!(
        policy_name(pool, f4).await.as_deref(),
        Some(cam4_name.as_str())
    );
    assert_eq!(camera_policy_id(pool, cam4).await, Some(f4));

    // F5 (ownerless) deleted.
    assert!(
        !policy_exists(pool, f5).await,
        "ownerless fork must be deleted"
    );
}
