// SPDX-License-Identifier: AGPL-3.0-or-later

//! `PUT /cameras/:id/ha/links/:link_id/placement` — whole-object REPLACE
//! semantics (issue #552).
//!
//! This endpoint is the one write path in the API that deliberately does NOT
//! merge. `PUT /config/server` adopted merge semantics in #472/#533 (omitted
//! key ⇒ leave the stored value alone); this route keeps replace semantics
//! because its body IS the badge's complete appearance and its style columns
//! have no `""` state to mean "clear" — a hex color and a closed vocabulary can
//! only be reset with `null`, so a merge reading would leave an operator no way
//! to undo an override.
//!
//! | Body | Meaning |
//! |---|---|
//! | body-level `null` | clear the placement entirely |
//! | field omitted **or** explicit `null` | that override is UNSET (back to the derived default) |
//! | field with a value | set it |
//!
//! `label` is the single exception: it is a LINK-level field riding along on
//! this body, so it follows the `PUT /config/ha` token convention (omitted ⇒
//! unchanged, `""` ⇒ cleared).
//!
//! These tests are the guard rail on that asymmetry. They are written to FAIL
//! if the DTO is ever "helpfully" converted to `Option<Option<_>>` merge
//! semantics without also updating the desktop client, which sends the badge's
//! current values forward on every save and clears an override by sending
//! `null` (`ha_overlay_controller.dart`'s `endEditAndSave`, and
//! `HaOverlayBadgeItem.resetStyle`). `docs/DECISIONS.md` (2026-08-07) records
//! the alternatives that were rejected.

mod support;

use axum::body::to_bytes;
use axum::http::StatusCode;
use crumb_common::db;
use serde_json::{json, Value};
use support::*;
use uuid::Uuid;

async fn body_json(resp: axum::http::Response<axum::body::Body>) -> Value {
    let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).expect("response body is JSON")
}

/// A camera with exactly one HA link on it, plus an admin token. Returns
/// `(token, camera_id, link_id)`.
async fn seed_camera_with_link(app: &TestApp) -> (String, Uuid, Uuid) {
    let admin = seed_admin(app.pool()).await;
    let token = login(app, &admin.username, &admin.password).await;
    let camera_id = seed_camera(app.pool()).await;
    let tuples: Vec<db::HaLinkInsert> = vec![(
        "binary_sensor.front_door".to_owned(),
        "sensor".to_owned(),
        Some("door".to_owned()),
        Some("Front Door".to_owned()),
        0,
        false,
        None,
    )];
    let links = db::replace_camera_ha_links(app.pool(), camera_id, &tuples)
        .await
        .expect("replace_camera_ha_links");
    (token, camera_id, links[0].id)
}

fn placement_uri(camera_id: Uuid, link_id: Uuid) -> String {
    format!("/cameras/{camera_id}/ha/links/{link_id}/placement")
}

/// A placement with EVERY optional field set to a distinct, recognizable value,
/// so a field that survives (or doesn't) is unambiguous rather than accidentally
/// equal to its default.
fn fully_styled_body() -> Value {
    json!({
        "x": 0.25,
        "y": 0.75,
        "size": 2.5,
        "color": "#11AA22",
        "icon": "garage",
        "show_state": true,
        "show_age": true,
        "opacity": 0.5,
        "shape": "pill",
        "bg_color": "#332211",
        "bg_color_on": "#44FF55",
        "pill_width": "wide",
        "text_align": "center",
        "outline": true,
    })
}

/// The style keys a partial body would omit. Position (`x`/`y`) is excluded:
/// it is REQUIRED, so it can never be the thing that goes missing.
const STYLE_KEYS: [&str; 12] = [
    "overlay_size",
    "overlay_color",
    "overlay_icon",
    "overlay_show_state",
    "overlay_show_age",
    "overlay_opacity",
    "overlay_shape",
    "overlay_bg_color",
    "overlay_bg_color_on",
    "overlay_pill_width",
    "overlay_text_align",
    "overlay_outline",
];

/// PUT [`fully_styled_body`] and assert the response actually carries every
/// value. Returns the response DTO. Doing this as a hard assertion (rather than
/// a fire-and-forget setup step) is what keeps the later "it got reset"
/// assertions non-vacuous: they can only pass because a reset happened, not
/// because the value was never stored.
async fn seed_full_style(app: &TestApp, token: &str, camera_id: Uuid, link_id: Uuid) -> Value {
    let resp = app
        .send(put_auth_json(
            &placement_uri(camera_id, link_id),
            token,
            &fully_styled_body(),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK, "styled PUT must succeed");
    let dto = body_json(resp).await;
    assert_eq!(dto["overlay_x"], json!(0.25));
    assert_eq!(dto["overlay_y"], json!(0.75));
    assert_eq!(dto["overlay_size"], json!(2.5));
    assert_eq!(dto["overlay_color"], json!("#11AA22"));
    assert_eq!(dto["overlay_icon"], json!("garage"));
    assert_eq!(dto["overlay_show_state"], json!(true));
    assert_eq!(dto["overlay_show_age"], json!(true));
    assert_eq!(dto["overlay_opacity"], json!(0.5));
    assert_eq!(dto["overlay_shape"], json!("pill"));
    assert_eq!(dto["overlay_bg_color"], json!("#332211"));
    assert_eq!(dto["overlay_bg_color_on"], json!("#44FF55"));
    assert_eq!(dto["overlay_pill_width"], json!("wide"));
    assert_eq!(dto["overlay_text_align"], json!("center"));
    assert_eq!(dto["overlay_outline"], json!(true));
    dto
}

/// Read the link back through `GET /cameras/:id/ha/links` so the assertions are
/// against PERSISTED state, not just the PUT's echo.
async fn reload_link(app: &TestApp, token: &str, camera_id: Uuid, link_id: Uuid) -> Value {
    let resp = app
        .send(get_auth(&format!("/cameras/{camera_id}/ha/links"), token))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let links = body_json(resp).await;
    links
        .as_array()
        .expect("links is an array")
        .iter()
        .find(|l| l["id"] == json!(link_id.to_string()))
        .cloned()
        .expect("the seeded link is still listed")
}

/// The default every style field falls back to once unset.
fn assert_style_is_default(dto: &Value) {
    assert_eq!(dto["overlay_size"], json!(1.0), "size falls back to 1.0");
    assert_eq!(
        dto["overlay_opacity"],
        json!(1.0),
        "opacity falls back to 1.0"
    );
    assert_eq!(dto["overlay_color"], json!(null));
    assert_eq!(dto["overlay_icon"], json!(null));
    assert_eq!(dto["overlay_show_state"], json!(false));
    assert_eq!(dto["overlay_show_age"], json!(false));
    assert_eq!(dto["overlay_shape"], json!(null));
    assert_eq!(dto["overlay_bg_color"], json!(null));
    assert_eq!(dto["overlay_bg_color_on"], json!(null));
    assert_eq!(dto["overlay_pill_width"], json!(null));
    assert_eq!(dto["overlay_text_align"], json!(null));
    assert_eq!(dto["overlay_outline"], json!(false));
}

// ─── the replace contract ────────────────────────────────────────────────────

/// THE pin. A body that names only the position resets every style field it did
/// not mention. This is the behavior issue #552 flagged, and it is deliberate:
/// the body is the whole placement. If this test starts failing, the endpoint
/// has quietly acquired merge semantics and every client that clears an override
/// by dropping it (or by sending `null`) has silently stopped working.
#[tokio::test]
async fn a_position_only_body_resets_every_unnamed_style_field() {
    let app = TestApp::new().await;
    let (token, camera_id, link_id) = seed_camera_with_link(&app).await;
    seed_full_style(&app, &token, camera_id, link_id).await;

    let resp = app
        .send(put_auth_json(
            &placement_uri(camera_id, link_id),
            &token,
            &json!({ "x": 0.4, "y": 0.6 }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let dto = body_json(resp).await;

    // The named fields took effect...
    assert_eq!(dto["overlay_x"], json!(0.4));
    assert_eq!(dto["overlay_y"], json!(0.6));
    // ...and every unnamed style field is back to its default.
    assert_style_is_default(&dto);
    assert_style_is_default(&reload_link(&app, &token, camera_id, link_id).await);
}

/// Omission and an explicit `null` are the SAME request. Asserted field by
/// field against a common baseline so this cannot pass by accident: both bodies
/// must land on byte-identical stored state.
#[tokio::test]
async fn omitting_a_style_field_is_identical_to_sending_it_as_null() {
    let app = TestApp::new().await;
    let (token, camera_id, link_id) = seed_camera_with_link(&app).await;

    // Path A: omit the style keys entirely.
    seed_full_style(&app, &token, camera_id, link_id).await;
    let resp = app
        .send(put_auth_json(
            &placement_uri(camera_id, link_id),
            &token,
            &json!({ "x": 0.4, "y": 0.6 }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let omitted = body_json(resp).await;

    // Path B: name every style key with an explicit null (the numeric/bool
    // fields have non-null defaults, so they are the ones a merge reading would
    // treat differently; they are exercised by path A's reset above).
    seed_full_style(&app, &token, camera_id, link_id).await;
    let resp = app
        .send(put_auth_json(
            &placement_uri(camera_id, link_id),
            &token,
            &json!({
                "x": 0.4,
                "y": 0.6,
                "color": null,
                "icon": null,
                "shape": null,
                "bg_color": null,
                "bg_color_on": null,
                "pill_width": null,
                "text_align": null,
            }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let explicit_null = body_json(resp).await;

    for key in STYLE_KEYS {
        assert_eq!(
            omitted[key], explicit_null[key],
            "`{key}` must mean the same thing omitted as it does explicitly null"
        );
    }
    assert_style_is_default(&omitted);
    assert_style_is_default(&explicit_null);
}

/// A style value survives a PUT that carries it forward — the flip side of the
/// reset assertions, and what every real client does. Without this, "everything
/// resets" would be indistinguishable from "the endpoint ignores the body".
#[tokio::test]
async fn a_body_that_carries_the_style_forward_preserves_it() {
    let app = TestApp::new().await;
    let (token, camera_id, link_id) = seed_camera_with_link(&app).await;
    seed_full_style(&app, &token, camera_id, link_id).await;

    // Move the badge the way a client does: re-send the whole object with only
    // the position changed.
    let mut body = fully_styled_body();
    body["x"] = json!(0.4);
    body["y"] = json!(0.6);
    let resp = app
        .send(put_auth_json(
            &placement_uri(camera_id, link_id),
            &token,
            &body,
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let dto = body_json(resp).await;

    assert_eq!(dto["overlay_x"], json!(0.4));
    assert_eq!(dto["overlay_y"], json!(0.6));
    assert_eq!(dto["overlay_color"], json!("#11AA22"));
    assert_eq!(dto["overlay_icon"], json!("garage"));
    assert_eq!(dto["overlay_shape"], json!("pill"));
    assert_eq!(dto["overlay_bg_color"], json!("#332211"));
    assert_eq!(dto["overlay_bg_color_on"], json!("#44FF55"));
    assert_eq!(dto["overlay_pill_width"], json!("wide"));
    assert_eq!(dto["overlay_text_align"], json!("center"));
    assert_eq!(dto["overlay_size"], json!(2.5));
    assert_eq!(dto["overlay_opacity"], json!(0.5));
    assert_eq!(dto["overlay_outline"], json!(true));
    assert_eq!(dto["overlay_show_state"], json!(true));
    assert_eq!(dto["overlay_show_age"], json!(true));
}

/// A body-level `null` unplaces the badge and resets the whole style with it.
#[tokio::test]
async fn a_null_body_clears_the_placement_and_every_override() {
    let app = TestApp::new().await;
    let (token, camera_id, link_id) = seed_camera_with_link(&app).await;
    seed_full_style(&app, &token, camera_id, link_id).await;

    let resp = app
        .send(put_auth_json(
            &placement_uri(camera_id, link_id),
            &token,
            &json!(null),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    let dto = body_json(resp).await;

    assert_eq!(dto["overlay_x"], json!(null), "the badge is unplaced");
    assert_eq!(dto["overlay_y"], json!(null));
    assert_eq!(
        dto["overlay_size"],
        json!(null),
        "size clears with the placement"
    );
    assert_eq!(dto["overlay_opacity"], json!(null));
    assert_eq!(dto["overlay_color"], json!(null));
    assert_eq!(dto["overlay_icon"], json!(null));
    assert_eq!(dto["overlay_shape"], json!(null));
    assert_eq!(dto["overlay_bg_color"], json!(null));
    assert_eq!(dto["overlay_bg_color_on"], json!(null));
    assert_eq!(dto["overlay_pill_width"], json!(null));
    assert_eq!(dto["overlay_text_align"], json!(null));
    assert_eq!(dto["overlay_outline"], json!(false));
    assert_eq!(dto["overlay_show_state"], json!(false));
    assert_eq!(dto["overlay_show_age"], json!(false));
    // The LINK itself survives, label and all — only the placement went away.
    assert_eq!(dto["label"], json!("Front Door"));
    assert_eq!(dto["entity_id"], json!("binary_sensor.front_door"));
}

// ─── `label`: the one merge-semantics field on this body ─────────────────────

/// `label` does NOT follow the replace rule, because the console's link editor
/// owns it too and the two writers would clobber each other. Omitted leaves it
/// alone, `""` clears it, a value sets it (trimmed).
#[tokio::test]
async fn label_is_the_one_field_this_body_merges() {
    let app = TestApp::new().await;
    let (token, camera_id, link_id) = seed_camera_with_link(&app).await;
    let uri = placement_uri(camera_id, link_id);

    // Omitted ⇒ unchanged, even though every style field around it resets.
    let resp = app
        .send(put_auth_json(&uri, &token, &json!({ "x": 0.4, "y": 0.6 })))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        body_json(resp).await["label"],
        json!("Front Door"),
        "an omitted label must survive a placement PUT"
    );

    // Explicit null ⇒ also unchanged (same token convention as `PUT /config/ha`).
    let resp = app
        .send(put_auth_json(
            &uri,
            &token,
            &json!({ "x": 0.4, "y": 0.6, "label": null }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(body_json(resp).await["label"], json!("Front Door"));

    // A value sets it, trimmed.
    let resp = app
        .send(put_auth_json(
            &uri,
            &token,
            &json!({ "x": 0.4, "y": 0.6, "label": "  Side Gate  " }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(body_json(resp).await["label"], json!("Side Gate"));

    // `""` clears it.
    let resp = app
        .send(put_auth_json(
            &uri,
            &token,
            &json!({ "x": 0.4, "y": 0.6, "label": "" }),
        ))
        .await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(body_json(resp).await["label"], json!(null));
    assert_eq!(
        reload_link(&app, &token, camera_id, link_id).await["label"],
        json!(null)
    );
}

// ─── position is required, which bounds the blast radius ─────────────────────

/// `x`/`y` have no serde default, so a STYLE-ONLY body cannot be sent at all —
/// it is rejected before it can reset anything. That is what keeps the replace
/// contract's footgun narrow: a partial body has to deliberately name a
/// position, which reads as "I am placing this badge", not "I am tweaking one
/// property". Pinned because adding a default to either coordinate would widen
/// the exposure without any other test noticing.
#[tokio::test]
async fn a_style_only_body_without_a_position_is_rejected() {
    let app = TestApp::new().await;
    let (token, camera_id, link_id) = seed_camera_with_link(&app).await;
    seed_full_style(&app, &token, camera_id, link_id).await;

    let resp = app
        .send(put_auth_json(
            &placement_uri(camera_id, link_id),
            &token,
            &json!({ "bg_color_on": "#010203" }),
        ))
        .await;
    assert_eq!(
        resp.status(),
        StatusCode::UNPROCESSABLE_ENTITY,
        "a body with no x/y must be refused, not treated as a patch"
    );

    // And nothing was written: the style is exactly as seeded.
    let dto = reload_link(&app, &token, camera_id, link_id).await;
    assert_eq!(dto["overlay_bg_color_on"], json!("#44FF55"));
    assert_eq!(dto["overlay_x"], json!(0.25));
}
