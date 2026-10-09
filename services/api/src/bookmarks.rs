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

// ─── protected-bookmark limits ────────────────────────────────────────────────

/// Default cap on a non-admin user's simultaneously active protected bookmarks
/// (`BOOKMARK_MAX_PROTECTED_PER_USER` overrides; `0` disables the cap).
const DEFAULT_MAX_PROTECTED_PER_USER: i64 = 50;

/// A bookmark `ts` may be at most this far ahead of the server clock (client
/// clock skew allowance). Anything later is rejected: a protected window that
/// reaches into footage not yet recorded would pin it against every eviction path.
const MAX_FUTURE_SKEW_SECS: i64 = 300;

/// Upper bound on the total protected window (pre + post seconds). When a request
/// exceeds it, both sides are scaled down proportionally.
const MAX_PROTECT_WINDOW_SECS: i64 = 3600;

/// Parse the per-user cap. Unset/blank/malformed/negative falls back to the
/// default; `0` means unlimited.
fn parse_max_protected(raw: Option<&str>) -> i64 {
    raw.and_then(|v| v.trim().parse::<i64>().ok())
        .filter(|v| *v >= 0)
        .unwrap_or(DEFAULT_MAX_PROTECTED_PER_USER)
}

fn max_protected_per_user() -> i64 {
    parse_max_protected(
        std::env::var("BOOKMARK_MAX_PROTECTED_PER_USER")
            .ok()
            .as_deref(),
    )
}

/// `true` when `ts` is further ahead of `now` than the skew allowance.
fn ts_too_far_in_future(ts: DateTime<Utc>, now: DateTime<Utc>) -> bool {
    ts > now + chrono::Duration::seconds(MAX_FUTURE_SKEW_SECS)
}

/// Clamp the protected window: each side to 0..=3600 s, then scale both down
/// proportionally if their sum exceeds [`MAX_PROTECT_WINDOW_SECS`].
fn clamp_protect_window(pre: i64, post: i64) -> (i64, i64) {
    let pre = pre.clamp(0, 3600);
    let post = post.clamp(0, 3600);
    let total = pre + post;
    if total <= MAX_PROTECT_WINDOW_SECS {
        return (pre, post);
    }
    let pre_scaled = pre * MAX_PROTECT_WINDOW_SECS / total;
    (pre_scaled, MAX_PROTECT_WINDOW_SECS - pre_scaled)
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
    /// Seconds of footage to protect BEFORE the moment (clamped 0..3600; default 60;
    /// the pre+post total is capped at 3600 s).
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
    if ts_too_far_in_future(ts, Utc::now()) {
        return Err(ApiError::BadRequest(
            "ts must not be in the future".to_owned(),
        ));
    }
    // Normalise a blank/whitespace note to NULL.
    let desc = body
        .description
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    // Protected retention: when protect_days > 0, keep the clip [ts-pre, ts+post]
    // from auto-archive/delete until now()+days. Clamp days 1..30, window <= 1 h.
    let bm = match body.protect_days {
        Some(d) if d > 0 => {
            let days = d.clamp(1, 30);
            let (pre, post) = clamp_protect_window(
                body.protect_pre_seconds.unwrap_or(60),
                body.protect_post_seconds.unwrap_or(300),
            );
            let protect_until = Utc::now() + chrono::Duration::days(days);
            let protect_start = ts - chrono::Duration::seconds(pre);
            let protect_end = ts + chrono::Duration::seconds(post);
            // Admins are exempt from the count cap; `0` disables it.
            let cap = max_protected_per_user();
            if user.is_admin() || cap == 0 {
                db::create_bookmark(
                    state.pool(),
                    body.camera_id,
                    ts,
                    desc,
                    Some(user.user_id),
                    Some(protect_until),
                    Some(protect_start),
                    Some(protect_end),
                )
                .await
                .context("create_bookmark")?
            } else {
                db::create_protected_bookmark_capped(
                    state.pool(),
                    body.camera_id,
                    ts,
                    desc,
                    user.user_id,
                    protect_until,
                    protect_start,
                    protect_end,
                    cap,
                )
                .await
                .context("create_protected_bookmark_capped")?
                .ok_or_else(|| {
                    ApiError::BadRequest(format!(
                        "protected bookmark limit reached ({cap}); remove or let expire an                          existing protected bookmark first"
                    ))
                })?
            }
        }
        _ => db::create_bookmark(
            state.pool(),
            body.camera_id,
            ts,
            desc,
            Some(user.user_id),
            None,
            None,
            None,
        )
        .await
        .context("create_bookmark")?,
    };

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cap_parsing_defaults_and_overrides() {
        assert_eq!(parse_max_protected(None), DEFAULT_MAX_PROTECTED_PER_USER);
        assert_eq!(
            parse_max_protected(Some("")),
            DEFAULT_MAX_PROTECTED_PER_USER
        );
        assert_eq!(
            parse_max_protected(Some("abc")),
            DEFAULT_MAX_PROTECTED_PER_USER
        );
        assert_eq!(
            parse_max_protected(Some("-3")),
            DEFAULT_MAX_PROTECTED_PER_USER
        );
        assert_eq!(parse_max_protected(Some(" 7 ")), 7);
        assert_eq!(parse_max_protected(Some("0")), 0);
    }

    #[test]
    fn future_ts_allows_small_skew_only() {
        let now = Utc::now();
        assert!(!ts_too_far_in_future(now, now));
        assert!(!ts_too_far_in_future(now - chrono::Duration::days(3), now));
        assert!(!ts_too_far_in_future(
            now + chrono::Duration::seconds(MAX_FUTURE_SKEW_SECS),
            now
        ));
        assert!(ts_too_far_in_future(
            now + chrono::Duration::seconds(MAX_FUTURE_SKEW_SECS + 1),
            now
        ));
        assert!(ts_too_far_in_future(now + chrono::Duration::hours(2), now));
    }

    #[test]
    fn window_is_capped_and_proportional() {
        assert_eq!(clamp_protect_window(60, 300), (60, 300));
        assert_eq!(clamp_protect_window(-5, 99_999), (0, 3600));
        assert_eq!(clamp_protect_window(3600, 3600), (1800, 1800));
        let (pre, post) = clamp_protect_window(3600, 0);
        assert_eq!((pre, post), (3600, 0));
        let (pre, post) = clamp_protect_window(3000, 1000);
        assert!(pre + post <= MAX_PROTECT_WINDOW_SECS);
        assert!(pre > post);
    }
}
