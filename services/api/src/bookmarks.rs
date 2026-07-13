// SPDX-License-Identifier: AGPL-3.0-or-later

//! Bookmarks CRUD — saved playback moments (camera + time + optional note),
//! shared server-side across all clients.
//!
//! # Endpoints
//!
//! | Method   | Path                       | Auth   | Description                                  |
//! |----------|----------------------------|--------|----------------------------------------------|
//! | `GET`    | `/bookmarks`               | Bearer | List bookmarks (scope-filtered per role)     |
//! | `GET`    | `/bookmarks?camera_id=...` | Bearer | List one camera's bookmarks (timeline markers)|
//! | `POST`   | `/bookmarks`               | Bearer | Create `{camera_id, ts, description?}` → 201  |
//! | `PATCH`  | `/bookmarks/:id`           | Bearer | Edit `{description}` (null clears)            |
//! | `DELETE` | `/bookmarks/:id`           | Bearer | Delete by UUID; `204` or `404`               |
//!
//! # Bookmark scope (Phase 2 RBAC)
//!
//! [`AuthUser::bookmarks_scope`] returns one of three values:
//!
//! * [`BookmarkScope::None`] — viewer has no bookmark access; all routes return 403.
//! * [`BookmarkScope::Own`]  — viewer sees / modifies only their OWN bookmarks, and
//!   only for cameras they can access.
//! * [`BookmarkScope::ViewAll`] — viewer SEES all bookmarks for cameras they can
//!   access and may create, but may edit/delete only their OWN (read-all,
//!   manage-own).
//! * [`BookmarkScope::All`]  — viewer (or admin) may see AND manage (edit/delete)
//!   all bookmarks for cameras they can access.
//!
//! Admins always resolve to `All` (via [`AuthUser::bookmarks_scope`]).

use anyhow::Context as _;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, patch},
    Json, Router,
};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use serde::Deserialize;
use uuid::Uuid;

use crumb_common::{
    db,
    types::{Bookmark, BookmarkScope},
};

use crate::{auth_mw::AuthUser, error::ApiError, state::AppState};

/// Mount the bookmark routes (merged at the top level → `/bookmarks`).
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/bookmarks", get(list_bookmarks).post(create_bookmark))
        .route(
            "/bookmarks/:id",
            patch(update_bookmark).delete(delete_bookmark),
        )
}

// ─── request DTOs ─────────────────────────────────────────────────────────────

/// Optional `?camera_id=` filter on `GET /bookmarks`.
#[derive(Debug, Deserialize)]
pub struct BookmarkQuery {
    pub camera_id: Option<Uuid>,
}

/// `POST /bookmarks` body.
#[derive(Debug, Deserialize)]
pub struct CreateBookmarkRequest {
    pub camera_id: Uuid,
    /// The bookmarked moment, RFC-3339 (e.g. `"2026-06-21T17:03:52Z"`).
    pub ts: String,
    /// Optional free-text note.
    pub description: Option<String>,
    /// Protected retention: keep the clip around the moment from auto-archive/
    /// delete for this many days (clamped 1..30). Absent/0/null = not protected.
    pub protect_days: Option<i64>,
    /// Seconds of footage to protect BEFORE the moment (clamped 0..3600; default 60).
    pub protect_pre_seconds: Option<i64>,
    /// Seconds of footage to protect AFTER the moment (clamped 0..3600; default 300).
    pub protect_post_seconds: Option<i64>,
}

/// `PATCH /bookmarks/:id` body — edit the note (omit/null clears it).
#[derive(Debug, Deserialize)]
pub struct UpdateBookmarkRequest {
    pub description: Option<String>,
}

// ─── handlers ─────────────────────────────────────────────────────────────────

/// `GET /bookmarks` — list bookmarks, filtered by role scope and camera access.
///
/// * `BookmarkScope::None`  → 403.
/// * `BookmarkScope::Own`   → bookmarks created by this user for cameras they
///   can access (newest first). When `?camera_id=` is given, asserts camera
///   access and returns that camera's bookmarks owned by this user (newest first).
/// * `BookmarkScope::ViewAll` / `BookmarkScope::All` → all bookmarks for cameras
///   the user can access (newest first). When `?camera_id=` is given, asserts
///   camera access and returns that camera's bookmarks (oldest first, for
///   timeline marker order). `ViewAll` differs from `All` only at edit/delete
///   time (see [`check_bookmark_access`]), not in what it can see.
async fn list_bookmarks(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<BookmarkQuery>,
) -> Result<Json<Vec<Bookmark>>, ApiError> {
    match user.bookmarks_scope() {
        BookmarkScope::None => Err(ApiError::Forbidden(
            "your role does not permit bookmark access".to_owned(),
        )),

        BookmarkScope::Own => {
            if let Some(cam) = q.camera_id {
                // Camera filter: assert access, then return only own bookmarks for
                // that camera. The `Bookmark` type doesn't carry `created_by`, so
                // we use `list_bookmarks_by_user` (which filters by `created_by`)
                // and then filter to the requested camera in Rust — avoids a new
                // DB query while keeping the code simple.
                user.assert_camera_access(cam)?;
                let list = db::list_bookmarks_by_user(state.pool(), user.user_id)
                    .await
                    .context("list_bookmarks_by_user")?;
                let filtered: Vec<Bookmark> =
                    list.into_iter().filter(|b| b.camera_id == cam).collect();
                Ok(Json(filtered))
            } else {
                // No camera filter: return all own bookmarks for accessible cameras.
                let list = db::list_bookmarks_by_user(state.pool(), user.user_id)
                    .await
                    .context("list_bookmarks_by_user")?;
                let filtered: Vec<Bookmark> = list
                    .into_iter()
                    .filter(|b| user.can_access_camera(b.camera_id))
                    .collect();
                Ok(Json(filtered))
            }
        }

        BookmarkScope::ViewAll | BookmarkScope::All => {
            if let Some(cam) = q.camera_id {
                user.assert_camera_access(cam)?;
                let list = db::list_bookmarks_for_camera(state.pool(), cam)
                    .await
                    .context("list_bookmarks_for_camera")?;
                Ok(Json(list))
            } else {
                let all = db::list_bookmarks(state.pool())
                    .await
                    .context("list_bookmarks")?;
                let filtered: Vec<Bookmark> = all
                    .into_iter()
                    .filter(|b| user.can_access_camera(b.camera_id))
                    .collect();
                Ok(Json(filtered))
            }
        }
    }
}

/// `POST /bookmarks` — create a bookmark at `(camera_id, ts)` with an optional note.
async fn create_bookmark(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<CreateBookmarkRequest>,
) -> Result<(StatusCode, Json<Bookmark>), ApiError> {
    // 403 if the role disallows bookmarks entirely.
    if matches!(user.bookmarks_scope(), BookmarkScope::None) {
        return Err(ApiError::Forbidden(
            "your role does not permit bookmark access".to_owned(),
        ));
    }

    // Camera scope: viewer must have access.
    user.assert_camera_access(body.camera_id)?;

    let ts = DateTime::parse_from_rfc3339(body.ts.trim())
        .map_err(|_| ApiError::BadRequest(format!("ts must be RFC-3339, got '{}'", body.ts)))?
        .with_timezone(&Utc);
    // Normalise a blank/whitespace note to NULL.
    let desc = body
        .description
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    // Protected retention: when protect_days > 0, keep the clip [ts-pre, ts+post]
    // from auto-archive/delete until now()+days. Clamp days 1..30, pre/post 0..3600.
    let (protect_until, protect_start, protect_end) = match body.protect_days {
        Some(d) if d > 0 => {
            let days = d.clamp(1, 30);
            let pre = body.protect_pre_seconds.unwrap_or(60).clamp(0, 3600);
            let post = body.protect_post_seconds.unwrap_or(300).clamp(0, 3600);
            (
                Some(Utc::now() + chrono::Duration::days(days)),
                Some(ts - chrono::Duration::seconds(pre)),
                Some(ts + chrono::Duration::seconds(post)),
            )
        }
        _ => (None, None, None),
    };

    let bm = db::create_bookmark(
        state.pool(),
        body.camera_id,
        ts,
        desc,
        Some(user.user_id),
        protect_until,
        protect_start,
        protect_end,
    )
    .await
    .context("create_bookmark")?;

    tracing::info!(bookmark_id = %bm.id, camera_id = %bm.camera_id, "bookmark created");
    Ok((StatusCode::CREATED, Json(bm)))
}

/// `PATCH /bookmarks/:id` — edit a bookmark's note.
///
/// Enforces bookmark scope: `None` → 403; `Own`/`ViewAll` → must be creator;
/// `All` → any accessible camera.
async fn update_bookmark(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateBookmarkRequest>,
) -> Result<Json<Bookmark>, ApiError> {
    check_bookmark_access(&user, state.pool(), id).await?;

    let desc = body
        .description
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let updated = db::update_bookmark_description(state.pool(), id, desc)
        .await
        .context("update_bookmark_description")?
        .ok_or_else(|| ApiError::NotFound(format!("bookmark {id} not found")))?;
    Ok(Json(updated))
}

/// `DELETE /bookmarks/:id` — remove a bookmark.
///
/// Enforces bookmark scope: `None` → 403; `Own`/`ViewAll` → must be creator;
/// `All` → any accessible camera.
async fn delete_bookmark(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    check_bookmark_access(&user, state.pool(), id).await?;

    let rows = db::delete_bookmark(state.pool(), id)
        .await
        .context("delete_bookmark")?;
    if rows == 0 {
        return Err(ApiError::NotFound(format!("bookmark {id} not found")));
    }
    tracing::info!(bookmark_id = %id, "bookmark deleted");
    Ok(StatusCode::NO_CONTENT)
}

// ─── helpers ──────────────────────────────────────────────────────────────────

/// Shared access guard for PATCH/DELETE on a single bookmark.
///
/// 1. `BookmarkScope::None` → 403 immediately.
/// 2. Loads `(camera_id, created_by)` from the DB — 404 if the row is missing.
/// 3. Asserts camera access (viewer can only touch bookmarks for their cameras).
/// 4. For `BookmarkScope::Own` and `BookmarkScope::ViewAll`: additionally
///    requires the caller is the creator (both are manage-own tiers — `ViewAll`
///    can *see* everyone's but only *modify* its own). Only `All` may edit/delete
///    another user's bookmark.
async fn check_bookmark_access(user: &AuthUser, pool: &Pool, id: Uuid) -> Result<(), ApiError> {
    if matches!(user.bookmarks_scope(), BookmarkScope::None) {
        return Err(ApiError::Forbidden(
            "your role does not permit bookmark access".to_owned(),
        ));
    }

    let (camera_id, created_by) = db::get_bookmark_owner(pool, id)
        .await
        .context("get_bookmark_owner")?
        .ok_or_else(|| ApiError::NotFound(format!("bookmark {id} not found")))?;

    user.assert_camera_access(camera_id)?;

    if matches!(
        user.bookmarks_scope(),
        BookmarkScope::Own | BookmarkScope::ViewAll
    ) {
        let is_owner = created_by.is_some_and(|u| u == user.user_id);
        if !is_owner {
            return Err(ApiError::Forbidden(
                "you can only modify your own bookmarks".to_owned(),
            ));
        }
    }

    Ok(())
}
