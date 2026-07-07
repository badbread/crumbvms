// SPDX-License-Identifier: AGPL-3.0-or-later

//! Permission-role CRUD (admin-only).
//!
//! A *role* is a named permission profile carrying BOTH a capability set (what a
//! member may do) AND a camera set (which cameras a member may see). Users are
//! assigned a role (`users.role_id`). These are DISTINCT from `camera_groups`,
//! which drive recording policy.
//!
//! | Method   | Path                | Auth  | Description                          |
//! |----------|---------------------|-------|--------------------------------------|
//! | `GET`    | `/config/roles`     | Admin | List all roles (admin-first)         |
//! | `POST`   | `/config/roles`     | Admin | Create a non-admin role → 201        |
//! | `GET`    | `/config/roles/:id` | Admin | One role                             |
//! | `PUT`    | `/config/roles/:id` | Admin | Edit name/capabilities/cameras       |
//! | `DELETE` | `/config/roles/:id` | Admin | Delete (refused if in use / `is_admin`)|
//!
//! Mounted under `/config` by `config_routes::routes()`. Every write invalidates
//! the `AppState` roles cache so capability/camera edits take effect on the next
//! request without a re-login.

use anyhow::Context as _;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use uuid::Uuid;

use crumb_common::{
    db,
    types::{Capabilities, Role},
};

use crate::{auth_mw::AdminUser, error::ApiError, state::AppState};

/// Mount the role routes (merged into the `/config` namespace).
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/roles", get(list_roles).post(create_role))
        .route(
            "/roles/:id",
            get(get_role).put(update_role).delete(delete_role),
        )
}

// ─── request DTOs ───────────────────────────────────────────────────────────

/// `POST /config/roles` body.
#[derive(Debug, Deserialize)]
pub struct CreateRoleRequest {
    pub name: String,
    #[serde(default)]
    pub capabilities: Capabilities,
    #[serde(default)]
    pub camera_ids: Vec<Uuid>,
}

/// `PUT /config/roles/:id` body — only provided fields change. `is_admin` is
/// immutable (the built-in admin role cannot be edited or deleted).
#[derive(Debug, Deserialize)]
pub struct UpdateRoleRequest {
    pub name: Option<String>,
    pub capabilities: Option<Capabilities>,
    pub camera_ids: Option<Vec<Uuid>>,
}

// ─── handlers ───────────────────────────────────────────────────────────────

async fn list_roles(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<Role>>, ApiError> {
    let roles = db::list_roles(state.pool()).await.context("list_roles")?;
    Ok(Json(roles))
}

async fn create_role(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<CreateRoleRequest>,
) -> Result<(StatusCode, Json<Role>), ApiError> {
    let name = body.name.trim();
    if name.is_empty() {
        return Err(ApiError::BadRequest("role name is required".to_owned()));
    }
    let role = db::create_role(state.pool(), name, &body.capabilities, &body.camera_ids)
        .await
        .map_err(|e| {
            let m = e.to_string();
            if m.contains("23505") || m.contains("unique") || m.contains("duplicate") {
                ApiError::Conflict(format!("a role named '{name}' already exists"))
            } else {
                ApiError::Internal(e)
            }
        })?;
    state.invalidate_roles_cache();
    tracing::info!(role_id = %role.id, name = %role.name, "role created");
    Ok((StatusCode::CREATED, Json(role)))
}

async fn get_role(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<Role>, ApiError> {
    let role = db::get_role(state.pool(), id)
        .await
        .context("get_role")?
        .ok_or_else(|| ApiError::NotFound(format!("role {id} not found")))?;
    Ok(Json(role))
}

async fn update_role(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateRoleRequest>,
) -> Result<Json<Role>, ApiError> {
    if let Some(ref n) = body.name {
        if n.trim().is_empty() {
            return Err(ApiError::BadRequest("role name cannot be empty".to_owned()));
        }
    }
    let updated = db::update_role(
        state.pool(),
        id,
        body.name.as_deref().map(str::trim),
        body.capabilities.as_ref(),
        body.camera_ids.as_deref(),
    )
    .await
    .map_err(|e| {
        let m = e.to_string();
        if m.contains("23505") || m.contains("unique") || m.contains("duplicate") {
            ApiError::Conflict("a role with that name already exists".to_owned())
        } else {
            ApiError::Internal(e)
        }
    })?
    .ok_or_else(|| {
        ApiError::NotFound(format!(
            "role {id} not found or is the built-in admin role (immutable)"
        ))
    })?;
    state.invalidate_roles_cache();
    tracing::info!(role_id = %id, "role updated");
    Ok(Json(updated))
}

async fn delete_role(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    // Refuse if any user is still assigned to this role — reassign them first.
    let in_use = db::count_users_with_role(state.pool(), id)
        .await
        .context("count_users_with_role")?;
    if in_use > 0 {
        return Err(ApiError::Conflict(format!(
            "cannot delete a role with {in_use} assigned user(s) — reassign them first"
        )));
    }
    let rows = db::delete_role(state.pool(), id)
        .await
        .context("delete_role")?;
    if rows == 0 {
        return Err(ApiError::NotFound(format!(
            "role {id} not found or is the built-in admin role (cannot delete)"
        )));
    }
    state.invalidate_roles_cache();
    tracing::info!(role_id = %id, "role deleted");
    Ok(StatusCode::NO_CONTENT)
}
