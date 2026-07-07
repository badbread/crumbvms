// SPDX-License-Identifier: AGPL-3.0-or-later

//! Saved Views CRUD — per-user-owned camera layouts persisted server-side.
//!
//! # Endpoints
//!
//! | Method  | Path                  | Auth   | Description                                      |
//! |---------|-----------------------|--------|--------------------------------------------------|
//! | `GET`   | `/views`              | Bearer | List views visible to the caller                 |
//! | `POST`  | `/views`              | Bearer | Create a view owned by the caller; `201`         |
//! | `DELETE`| `/views/:id`          | Bearer | Delete; owner or admin only; `204` or `404`/`403`|
//! | `PUT`   | `/views/:id/icon`     | Bearer | Set/clear the quick-switch icon; owner/admin; `204`|
//! | `GET`   | `/views/:id/shares`   | Bearer | List user UUIDs shared on a view; owner/admin    |
//! | `PUT`   | `/views/:id/shares`   | Bearer | Replace share list (full set); owner/admin; `204`|
//!
//! # Ownership model (Phase 3)
//!
//! * Every new view has `owner_id = caller.user_id`.
//! * Legacy rows (`owner_id IS NULL`) are visible to all users (backward compat).
//! * Admins see and manage every view.
//! * Callers see their own views + legacy global rows + views shared with them.
//!
//! # Sharing model (Phase 4)
//!
//! * Only the owner (or an admin) may add/remove shares via `PUT /views/:id/shares`.
//! * Share-granted users can read a view but cannot mutate or re-share it.
//! * The list endpoint deliberately omits share lists to avoid N+1 queries;
//!   only the dedicated `GET /views/:id/shares` returns share details.

use anyhow::Context as _;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{delete, get, put},
    Json, Router,
};
use serde::Deserialize;
use uuid::Uuid;

use crumb_common::{db, types::View};

use crate::{auth_mw::AuthUser, error::ApiError, state::AppState};

// ─── router ───────────────────────────────────────────────────────────────────

/// Mount the saved-views routes.
///
/// The caller (`main.rs`) merges this directly into the top-level router so
/// the effective paths are `/views`, `/views/:id`, `/views/:id/icon`, and
/// `/views/:id/shares`.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/views", get(list_views).post(create_view))
        .route("/views/:id", delete(delete_view))
        .route("/views/:id/icon", put(put_icon))
        .route("/views/:id/shares", get(get_shares).put(put_shares))
}

// ─── request DTOs ─────────────────────────────────────────────────────────────

/// `POST /views` request body.
#[derive(Debug, Deserialize)]
pub struct CreateViewRequest {
    /// Human-readable label, e.g. `"Perimeter"`.  Must not be blank.
    pub name: String,
    /// Grid identifier, e.g. `"2x2"`, `"1plus5"`.
    pub layout: String,
    /// Slot-to-camera mapping: `{"<slotIndex>": "<cameraUuid>"}`.
    ///
    /// Defaults to an empty object when absent so callers can create a layout
    /// shell and populate slots separately.
    #[serde(default = "empty_object")]
    pub slots: serde_json::Value,
    /// User-chosen quick-switch glyph, e.g. `"🚗"`. Absent/`null` leaves the
    /// icon unset; the client falls back to its own default.
    #[serde(default)]
    pub icon: Option<String>,
}

fn empty_object() -> serde_json::Value {
    serde_json::Value::Object(serde_json::Map::new())
}

/// `PUT /views/:id/icon` request body.
#[derive(Debug, Deserialize)]
pub struct SetIconRequest {
    /// The new icon, or `null`/absent to clear it back to unset.
    #[serde(default)]
    pub icon: Option<String>,
}

/// `PUT /views/:id/shares` request body.
#[derive(Debug, Deserialize)]
pub struct SetSharesRequest {
    /// The complete desired share list — replaces the current set atomically.
    pub user_ids: Vec<Uuid>,
}

// ─── permission helper ────────────────────────────────────────────────────────

/// Return `true` if `user` may create, delete, or share-manage `view_id`.
///
/// Permitted when:
/// * The caller is an admin (bypasses all checks), OR
/// * `owner_opt` is `Some(uid)` and `uid == caller.user_id`.
///
/// Legacy global rows (`owner_opt == Some(None)`) are admin-only for mutation.
fn can_manage_view(user: &AuthUser, owner_opt: Option<Uuid>) -> bool {
    user.is_admin() || owner_opt.is_some_and(|o| o == user.user_id)
}

// ─── handlers ─────────────────────────────────────────────────────────────────

/// `GET /views` — list views visible to the authenticated caller.
///
/// Admins receive every view.  Non-admins receive their own views, legacy
/// global views (`owner_id IS NULL`), and views explicitly shared with them.
async fn list_views(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<View>>, ApiError> {
    let views = db::list_views_for_user(state.pool(), user.user_id, user.is_admin())
        .await
        .context("list_views")?;
    Ok(Json(views))
}

/// `POST /views` — create a new saved view owned by the caller.
///
/// Returns `201 Created` with the full [`View`] on success.
///
/// # Errors
///
/// - `400` — `name` is blank.
/// - `401` — missing or invalid Bearer token.
/// - `403` — caller's role does not have `manage_views`.
/// - `500` — database error.
async fn create_view(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<CreateViewRequest>,
) -> Result<(StatusCode, Json<View>), ApiError> {
    if !user.can_manage_views() {
        return Err(ApiError::Forbidden(
            "your role does not permit managing views".to_owned(),
        ));
    }

    if body.name.trim().is_empty() {
        return Err(ApiError::BadRequest("name must not be blank".to_owned()));
    }

    let view = db::create_view(
        state.pool(),
        body.name.trim(),
        &body.layout,
        &body.slots,
        Some(user.user_id),
        body.icon.as_deref(),
    )
    .await
    .context("create_view")?;

    tracing::info!(view_id = %view.id, name = %view.name, owner = %user.user_id, "view created");
    Ok((StatusCode::CREATED, Json(view)))
}

/// `DELETE /views/:id` — delete a saved view by UUID.
///
/// Allowed if the caller is the owner or an admin.  Legacy global views
/// (`owner_id IS NULL`) are admin-only.
///
/// Returns `204 No Content` on success.
///
/// # Errors
///
/// - `401` — missing or invalid Bearer token.
/// - `403` — caller does not own the view and is not an admin.
/// - `404` — no view with that UUID.
/// - `500` — database error.
async fn delete_view(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    // Resolve ownership first; 404 before 403 so we don't leak existence.
    let owner_wrap = db::get_view_owner(state.pool(), id)
        .await
        .context("delete_view: get_view_owner")?
        .ok_or_else(|| ApiError::NotFound(format!("view {id} not found")))?;

    if !can_manage_view(&user, owner_wrap) {
        return Err(ApiError::Forbidden(format!(
            "you do not have permission to delete view {id}"
        )));
    }

    let rows = db::delete_view(state.pool(), id)
        .await
        .context("delete_view")?;

    if rows == 0 {
        // Extremely unlikely (row disappeared between the owner check and the
        // DELETE), but handle gracefully.
        return Err(ApiError::NotFound(format!("view {id} not found")));
    }

    tracing::info!(view_id = %id, "view deleted");
    Ok(StatusCode::NO_CONTENT)
}

/// `PUT /views/:id/icon` — set (or clear, with `icon: null`) the view's
/// quick-switch icon.
///
/// This is a full replace, not a merge: whatever `icon` the caller sends is
/// written verbatim, matching [`put_shares`]'s full-replace semantics. A
/// client that wants to *keep* the current icon should simply not call this
/// endpoint — there is no separate partial-update path for view fields.
///
/// Allowed if the caller is the owner or an admin. Legacy global views
/// (`owner_id IS NULL`) are admin-only, same as [`delete_view`].
///
/// Returns `204 No Content` on success.
///
/// # Errors
///
/// - `401` — missing or invalid Bearer token.
/// - `403` — caller does not own the view and is not an admin.
/// - `404` — no view with that UUID.
/// - `500` — database error.
async fn put_icon(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<SetIconRequest>,
) -> Result<StatusCode, ApiError> {
    let owner_wrap = db::get_view_owner(state.pool(), id)
        .await
        .context("put_icon: get_view_owner")?
        .ok_or_else(|| ApiError::NotFound(format!("view {id} not found")))?;

    if !can_manage_view(&user, owner_wrap) {
        return Err(ApiError::Forbidden(format!(
            "you do not have permission to change the icon for view {id}"
        )));
    }

    let rows = db::update_view_icon(state.pool(), id, body.icon.as_deref())
        .await
        .context("put_icon")?;

    if rows == 0 {
        return Err(ApiError::NotFound(format!("view {id} not found")));
    }

    tracing::info!(view_id = %id, icon = ?body.icon, "view icon updated");
    Ok(StatusCode::NO_CONTENT)
}

/// `GET /views/:id/shares` — list the user UUIDs that have been granted access.
///
/// Only the view owner or an admin may inspect the share list.
///
/// Returns `200 Ok` with a `Vec<Uuid>` (empty when no shares exist).
///
/// # Errors
///
/// - `401` — missing or invalid Bearer token.
/// - `403` — caller is not the owner and is not an admin.
/// - `404` — no view with that UUID.
/// - `500` — database error.
async fn get_shares(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<Vec<Uuid>>, ApiError> {
    let owner_wrap = db::get_view_owner(state.pool(), id)
        .await
        .context("get_shares: get_view_owner")?
        .ok_or_else(|| ApiError::NotFound(format!("view {id} not found")))?;

    if !can_manage_view(&user, owner_wrap) {
        return Err(ApiError::Forbidden(format!(
            "you do not have permission to view shares for view {id}"
        )));
    }

    let shares = db::list_view_shares(state.pool(), id)
        .await
        .context("get_shares")?;
    Ok(Json(shares))
}

/// `PUT /views/:id/shares` — replace the share list atomically.
///
/// Body: `{ "user_ids": ["<uuid>", ...] }`.  Passing an empty array clears all
/// shares.  Duplicate UUIDs are silently deduplicated.  Only the view owner or
/// an admin may call this endpoint.
///
/// Returns `204 No Content` on success.
///
/// # Errors
///
/// - `401` — missing or invalid Bearer token.
/// - `403` — caller is not the owner and is not an admin.
/// - `404` — no view with that UUID.
/// - `500` — database error.
async fn put_shares(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<SetSharesRequest>,
) -> Result<StatusCode, ApiError> {
    let owner_wrap = db::get_view_owner(state.pool(), id)
        .await
        .context("put_shares: get_view_owner")?
        .ok_or_else(|| ApiError::NotFound(format!("view {id} not found")))?;

    if !can_manage_view(&user, owner_wrap) {
        return Err(ApiError::Forbidden(format!(
            "you do not have permission to manage shares for view {id}"
        )));
    }

    db::set_view_shares(state.pool(), id, &body.user_ids)
        .await
        .context("put_shares")?;

    tracing::info!(
        view_id = %id,
        share_count = body.user_ids.len(),
        "view shares updated"
    );
    Ok(StatusCode::NO_CONTENT)
}
