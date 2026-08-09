// SPDX-License-Identifier: AGPL-3.0-or-later

//! `POST /cameras/:id/ha/action` — the actuator control endpoint (issue #187).
//!
//! This is the one route in Crumb that moves PHYSICAL hardware (locks, garage
//! doors, sirens), so every gate in front of it gets an explicit test: the
//! deny-by-default `actuators` capability, per-camera scope, link ownership +
//! role, and the per-domain action allowlist.
//!
//! The harness has no stand-in Home Assistant (the mock-HA server lives in
//! `crumb_common::ha`'s own unit tests, where the real `HaClient` is exercised
//! against it). So the route tests here assert the four verification steps and
//! stop at the HA call BOUNDARY: with HA unconfigured, a fully-authorized,
//! allowlisted request gets the distinct "not enabled" 400, which proves it
//! passed capability + scope + link + allowlist and reached the call site.

mod support;

use axum::http::StatusCode;
use crumb_common::{
    db,
    types::{BookmarkScope, Capabilities},
};
use support::*;
use uuid::Uuid;

/// Capabilities of a normal viewer PLUS `actuators` (what an operator role that
/// is allowed to work the garage door looks like).
fn caps_with_actuators() -> Capabilities {
    Capabilities {
        export: false,
        playback: true,
        clips: true,
        ptz: false,
        bookmarks: BookmarkScope::Own,
        manage_views: true,
        view_plates: false,
        actuators: true,
    }
}

/// Replace a camera's HA links with the given `(entity_id, role)` pairs and
/// return them in insertion order.
async fn seed_links(
    pool: &deadpool_postgres::Pool,
    camera_id: Uuid,
    links: &[(&str, &str)],
) -> Vec<crumb_common::types::CameraHaLink> {
    let mut tuples: Vec<db::HaLinkInsert> = Vec::new();
    for (i, (entity, role)) in links.iter().enumerate() {
        let order = i32::try_from(i).unwrap_or(0);
        // Default control config (migration 0073): no confirm, no action
        // restriction — today's behavior.
        tuples.push((
            (*entity).to_owned(),
            (*role).to_owned(),
            None,
            None,
            order,
            false,
            None,
        ));
    }
    db::replace_camera_ha_links(pool, camera_id, &tuples)
        .await
        .expect("replace_camera_ha_links")
}

/// Seed a single actuator link with an explicit `allowed_actions` restriction
/// (migration 0073) so the server-side enforcement can be exercised end to end.
async fn seed_link_with_allowed_actions(
    pool: &deadpool_postgres::Pool,
    camera_id: Uuid,
    entity: &str,
    allowed_actions: &[&str],
) -> Vec<crumb_common::types::CameraHaLink> {
    let tuples: Vec<db::HaLinkInsert> = vec![(
        entity.to_owned(),
        "actuator".to_owned(),
        None,
        None,
        0,
        false,
        Some(allowed_actions.iter().map(|s| (*s).to_owned()).collect()),
    )];
    db::replace_camera_ha_links(pool, camera_id, &tuples)
        .await
        .expect("replace_camera_ha_links")
}

fn action_body(link_id: Uuid, action: &str) -> serde_json::Value {
    serde_json::json!({ "link_id": link_id, "action": action })
}

async fn body_text(resp: axum::http::Response<axum::body::Body>) -> String {
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .expect("read body");
    String::from_utf8_lossy(&bytes).into_owned()
}

// ─── 401: no credentials ─────────────────────────────────────────────────────

#[tokio::test]
async fn action_without_a_token_is_401() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let req = axum::http::Request::builder()
        .method("POST")
        .uri(format!("/cameras/{cam}/ha/action"))
        .header("content-type", "application/json")
        .body(axum::body::Body::from(
            action_body(Uuid::new_v4(), "turn_on").to_string(),
        ))
        .unwrap();
    assert_eq!(app.send(req).await.status(), StatusCode::UNAUTHORIZED);
}

// ─── 403: authenticated, but not permitted ───────────────────────────────────

#[tokio::test]
async fn action_denied_without_the_actuators_capability() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let links = seed_links(app.pool(), cam, &[("light.kitchen", "actuator")]).await;

    // A generous viewer (playback/clips/export/ptz/view_plates) WITH access to
    // the camera, but no `actuators` — the whole point of the capability.
    let viewer = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(post_auth_json(
            &format!("/cameras/{cam}/ha/action"),
            &token,
            &action_body(links[0].id, "turn_on"),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn action_denied_for_a_camera_outside_the_grant() {
    let app = TestApp::new().await;
    let mine = seed_camera(app.pool()).await;
    let theirs = seed_camera(app.pool()).await;
    let links = seed_links(app.pool(), theirs, &[("lock.front_door", "actuator")]).await;

    // Holds `actuators`, but only for `mine`.
    let role_id = seed_viewer_role_with_caps(app.pool(), &[mine], caps_with_actuators()).await;
    let viewer = seed_viewer_user(app.pool(), role_id).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(post_auth_json(
            &format!("/cameras/{theirs}/ha/action"),
            &token,
            &action_body(links[0].id, "unlock"),
        ))
        .await;
    // Matches the codebase-wide convention for a camera outside the caller's
    // grant (`AuthUser::assert_camera_access` → 403).
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn a_media_token_can_never_actuate() {
    // A scoped media `?token=` credential authenticates for media and can appear
    // in URLs / access logs. It must never work the lock, even when minted by a
    // user whose role DOES hold `actuators`.
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let links = seed_links(app.pool(), cam, &[("lock.front_door", "actuator")]).await;

    let role_id = seed_viewer_role_with_caps(app.pool(), &[cam], caps_with_actuators()).await;
    let viewer = seed_viewer_user(app.pool(), role_id).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let mint = app
        .send(get_auth(&format!("/media-token?camera={cam}"), &token))
        .await;
    assert_eq!(mint.status(), StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body_text(mint).await).expect("mint json");
    let media_token = v["token"].as_str().expect("media token").to_owned();

    let req = axum::http::Request::builder()
        .method("POST")
        .uri(format!("/cameras/{cam}/ha/action?token={media_token}"))
        .header("content-type", "application/json")
        .body(axum::body::Body::from(
            action_body(links[0].id, "unlock").to_string(),
        ))
        .unwrap();
    let resp = app.send(req).await;
    assert_eq!(
        resp.status(),
        StatusCode::FORBIDDEN,
        "a media token must not carry the actuators capability"
    );
}

// ─── 404: the link must exist on THIS camera and be an actuator ──────────────

#[tokio::test]
async fn action_404s_for_unknown_foreign_and_non_actuator_links() {
    let app = TestApp::new().await;
    let mine = seed_camera(app.pool()).await;
    let other = seed_camera(app.pool()).await;

    let mine_links = seed_links(
        app.pool(),
        mine,
        &[
            ("cover.garage", "actuator"),
            ("binary_sensor.driveway", "motion"),
            ("sensor.porch_temp", "sensor"),
        ],
    )
    .await;
    let other_links = seed_links(app.pool(), other, &[("lock.side_gate", "actuator")]).await;

    let role_id =
        seed_viewer_role_with_caps(app.pool(), &[mine, other], caps_with_actuators()).await;
    let viewer = seed_viewer_user(app.pool(), role_id).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let motion_link = mine_links
        .iter()
        .find(|l| l.role == "motion")
        .expect("motion link");
    let sensor_link = mine_links
        .iter()
        .find(|l| l.role == "sensor")
        .expect("sensor link");

    // A link id that does not exist at all.
    // A link that belongs to another camera the caller CAN access (so this is
    // about link ownership, not scope).
    // A link on this camera whose role is not 'actuator'.
    for (label, link_id, action) in [
        ("unknown link", Uuid::new_v4(), "open_cover"),
        ("link of another camera", other_links[0].id, "unlock"),
        ("motion-role link", motion_link.id, "turn_on"),
        ("sensor-role link", sensor_link.id, "turn_on"),
    ] {
        let resp = app
            .send(post_auth_json(
                &format!("/cameras/{mine}/ha/action"),
                &token,
                &action_body(link_id, action),
            ))
            .await;
        assert_eq!(resp.status(), StatusCode::NOT_FOUND, "{label} must 404");
    }
}

// ─── 400: the per-domain action allowlist ────────────────────────────────────

#[tokio::test]
async fn action_400s_when_the_action_is_not_allowlisted_for_the_domain() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let links = seed_links(
        app.pool(),
        cam,
        &[
            ("lock.front_door", "actuator"),
            ("climate.hallway", "actuator"),
        ],
    )
    .await;
    let lock = links
        .iter()
        .find(|l| l.entity_id == "lock.front_door")
        .expect("lock link");
    let climate = links
        .iter()
        .find(|l| l.entity_id == "climate.hallway")
        .expect("climate link");

    let role_id = seed_viewer_role_with_caps(app.pool(), &[cam], caps_with_actuators()).await;
    let viewer = seed_viewer_user(app.pool(), role_id).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    for (label, link_id, action) in [
        // Real HA service, wrong domain for this entity.
        ("turn_on on a lock", lock.id, "turn_on"),
        ("open_cover on a lock", lock.id, "open_cover"),
        // A domain Crumb deliberately does not drive.
        ("any action on a climate entity", climate.id, "turn_on"),
        // Garbage / path-traversal shaped.
        ("garbage action", lock.id, "../homeassistant/restart"),
        ("empty action", lock.id, ""),
    ] {
        let resp = app
            .send(post_auth_json(
                &format!("/cameras/{cam}/ha/action"),
                &token,
                &action_body(link_id, action),
            ))
            .await;
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "{label} must be rejected by the allowlist"
        );
    }
}

#[tokio::test]
async fn an_allowlisted_action_passes_every_gate_and_stops_at_the_ha_boundary() {
    // With HA unconfigured, the request that clears capability + scope + link +
    // allowlist fails with the DISTINCT "not enabled" 400. That is how this
    // suite proves the happy path reaches the HA call site without a stand-in HA
    // (the real client's call is covered in `crumb_common::ha`'s mock-HA tests).
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let links = seed_links(app.pool(), cam, &[("cover.garage", "actuator")]).await;

    let role_id = seed_viewer_role_with_caps(app.pool(), &[cam], caps_with_actuators()).await;
    let viewer = seed_viewer_user(app.pool(), role_id).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(post_auth_json(
            &format!("/cameras/{cam}/ha/action"),
            &token,
            &action_body(links[0].id, "close_cover"),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_text(resp).await;
    assert!(
        body.contains("not enabled"),
        "expected the HA-not-enabled 400 (proving the allowlist passed), got: {body}"
    );
}

// ─── the viewer payload clients render controls from ─────────────────────────

#[tokio::test]
async fn camera_links_payload_carries_the_fields_clients_need() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    let tuples: Vec<db::HaLinkInsert> = vec![(
        "cover.garage".to_owned(),
        "actuator".to_owned(),
        Some("garage".to_owned()),
        Some("Garage door".to_owned()),
        0,
        false,
        None,
    )];
    db::replace_camera_ha_links(app.pool(), cam, &tuples)
        .await
        .expect("replace_camera_ha_links");

    let viewer = seed_viewer(app.pool(), &[cam]).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(get_auth(&format!("/cameras/{cam}/ha/links"), &token))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body_text(resp).await).expect("links json");
    let link = &v[0];
    assert_eq!(link["role"], "actuator");
    assert_eq!(link["entity_id"], "cover.garage");
    assert_eq!(link["label"], "Garage door");
    assert_eq!(link["device_class"], "garage");
    // `link_id` is the field name the action endpoint's body uses; it mirrors
    // the long-standing `id`.
    assert!(link["link_id"].is_string());
    assert_eq!(link["link_id"], link["id"]);
    // Per-link control config (migration 0073) is exposed for clients to honor;
    // an unset link reports today's defaults: no confirm, no action restriction.
    assert_eq!(link["require_confirm"], false);
    assert!(link["allowed_actions"].is_null());
}

// ─── allowed_actions: the server-enforced per-link restriction (issue #440) ──

#[tokio::test]
async fn allowed_actions_lets_a_permitted_action_through_to_the_ha_call() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    // A light restricted to turn_on only. turn_on is BOTH domain-allowlisted and
    // in the link's allowed_actions, so it must pass every gate and reach the HA
    // call boundary (distinct "not enabled" 400, HA being unconfigured here).
    let links =
        seed_link_with_allowed_actions(app.pool(), cam, "light.kitchen", &["turn_on"]).await;

    let role_id = seed_viewer_role_with_caps(app.pool(), &[cam], caps_with_actuators()).await;
    let viewer = seed_viewer_user(app.pool(), role_id).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(post_auth_json(
            &format!("/cameras/{cam}/ha/action"),
            &token,
            &action_body(links[0].id, "turn_on"),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_text(resp).await;
    assert!(
        body.contains("not enabled"),
        "an allowed action must pass the allowed_actions gate and reach the HA call, got: {body}"
    );
}

#[tokio::test]
async fn allowed_actions_forbids_a_domain_valid_but_unlisted_action() {
    let app = TestApp::new().await;
    let cam = seed_camera(app.pool()).await;
    // A light restricted to turn_on only. turn_off IS a valid light action
    // (passes the domain allowlist) but is NOT in allowed_actions, so the
    // server must refuse it with a 403 BEFORE contacting HA — a real
    // restriction, not merely a client-side hint.
    let links =
        seed_link_with_allowed_actions(app.pool(), cam, "light.kitchen", &["turn_on"]).await;

    let role_id = seed_viewer_role_with_caps(app.pool(), &[cam], caps_with_actuators()).await;
    let viewer = seed_viewer_user(app.pool(), role_id).await;
    let token = login(&app, &viewer.username, &viewer.password).await;

    let resp = app
        .send(post_auth_json(
            &format!("/cameras/{cam}/ha/action"),
            &token,
            &action_body(links[0].id, "turn_off"),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
    let body = body_text(resp).await;
    assert!(
        !body.contains("not enabled"),
        "a forbidden action must be refused before the HA call, got: {body}"
    );
}

// ─── the capability itself: default-false everywhere ─────────────────────────

#[tokio::test]
async fn actuators_defaults_to_false_for_a_new_role_and_true_for_admin() {
    let app = TestApp::new().await;

    // A role created with the default capability set does NOT get actuators.
    let defaults = Capabilities::default();
    let role = db::create_role(app.pool(), &unique("defaults-role"), &defaults, &[])
        .await
        .expect("create_role (defaults)");
    assert!(
        !role.capabilities.actuators,
        "a new role must not be able to operate physical devices"
    );

    // A legacy role row persisted BEFORE this capability existed (its jsonb has
    // no `actuators` key) must deserialize to false, not fail to load (#407).
    {
        let client = app.pool().get().await.expect("pool.get");
        client
            .execute(
                r#"UPDATE roles
                   SET capabilities = '{"playback": true, "clips": true,
                                        "bookmarks": "own", "manage_views": true}'::jsonb
                   WHERE id = $1"#,
                &[&role.id],
            )
            .await
            .expect("simulate a pre-actuators role row");
    }
    let legacy = db::get_role(app.pool(), role.id)
        .await
        .expect("get_role (legacy jsonb)")
        .expect("role exists");
    assert!(
        legacy.capabilities.playback,
        "legacy caps still deserialize"
    );
    assert!(
        !legacy.capabilities.actuators,
        "a missing claim must read as DENY, never as granted or an error"
    );

    // ...and the admin role implies it, surfaced to clients via /auth/me.
    let admin = seed_admin(app.pool()).await;
    let admin_token = login(&app, &admin.username, &admin.password).await;
    let me = app.send(get_auth("/auth/me", &admin_token)).await;
    assert_eq!(me.status(), StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body_text(me).await).expect("me json");
    assert_eq!(
        v["capabilities"]["actuators"],
        serde_json::Value::Bool(true),
        "admin implies actuators"
    );

    // A plain viewer sees it as false in the same payload.
    let viewer = seed_viewer(app.pool(), &[]).await;
    let viewer_token = login(&app, &viewer.username, &viewer.password).await;
    let me = app.send(get_auth("/auth/me", &viewer_token)).await;
    let v: serde_json::Value = serde_json::from_str(&body_text(me).await).expect("me json");
    assert_eq!(
        v["capabilities"]["actuators"],
        serde_json::Value::Bool(false)
    );
}
