// SPDX-License-Identifier: AGPL-3.0-or-later

//! Notification system — device registration, rules, snoozes, presence, log, engine,
//! and third-party channel management.
//!
//! # Endpoints
//!
//! | Method   | Path                              | Auth          | Description                         |
//! |----------|-----------------------------------|---------------|-------------------------------------|
//! | `POST`   | `/notifications/devices`          | Bearer        | Register/re-register a push device  |
//! | `GET`    | `/notifications/devices`          | Bearer        | List caller's devices               |
//! | `DELETE` | `/notifications/devices/{id}`     | Bearer        | Delete a device (caller-owned only) |
//! | `GET`    | `/notifications/rules`            | Bearer        | List caller's rules                 |
//! | `PUT`    | `/notifications/rules`            | Bearer        | Upsert default rule (camera NULL)   |
//! | `PUT`    | `/notifications/rules/{cam}`      | Bearer        | Upsert per-camera rule              |
//! | `POST`   | `/notifications/snooze`           | Bearer        | Snooze a device                     |
//! | `DELETE` | `/notifications/snooze`           | Bearer        | Clear a snooze                      |
//! | `POST`   | `/presence`                       | Bearer        | Set device or user presence         |
//! | `GET`    | `/notifications/log`              | Bearer        | Recent notification log rows        |
//! | `GET`    | `/notifications/channels`         | Bearer        | List caller's channels (+ globals)  |
//! | `POST`   | `/notifications/channels`         | Bearer        | Create a channel                    |
//! | `PUT`    | `/notifications/channels/{id}`    | Bearer        | Update a channel                    |
//! | `DELETE` | `/notifications/channels/{id}`    | Bearer        | Delete a channel                    |
//! | `POST`   | `/notifications/channels/{id}/test` | Bearer      | Test-fire a channel                 |
//! | `GET`    | `/notifications/settings`           | Bearer       | Global notification on/off flag     |
//! | `PUT`    | `/notifications/settings`           | Bearer Admin | Toggle global notifications         |
//!
//! # Engine
//!
//! [`run_notification_engine`] is a background task (spawned from `main.rs` like the
//! heartbeat alerter).  It polls `events` every 3 s, fans out over every registered
//! device, evaluates rule gates, and writes `notification_log` rows on pass.
//! Additionally it fans out over every enabled [`db::NotificationChannel`] and
//! dispatches outbound HTTP notifications via [`crate::channel_notify::dispatch`].
//! Channel gate behaviour is driven by the owner's `notification_rules` (per-camera
//! override → user default → system default), including presence gating.  Global
//! channels (no owner) use system defaults and are never presence-gated.

use std::collections::HashMap;
use std::time::Instant;

use anyhow::Context as _;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use uuid::Uuid;

use crumb_common::{db, types::UserRole};

use crate::{
    auth_mw::{AdminUser, AuthUser},
    channel_notify::{self, ChannelMessage},
    error::ApiError,
    go2rtc::resolve_bases,
    state::AppState,
};

// ─── route mount ─────────────────────────────────────────────────────────────

/// Mount all notification routes (merged at the top level).
pub fn routes() -> Router<AppState> {
    Router::new()
        // Devices
        .route(
            "/notifications/devices",
            post(register_device).get(list_devices),
        )
        .route("/notifications/devices/:id", delete(delete_device))
        // Rules
        .route(
            "/notifications/rules",
            get(list_rules).put(upsert_default_rule),
        )
        .route("/notifications/rules/:camera_id", put(upsert_camera_rule))
        // Snooze
        .route(
            "/notifications/snooze",
            post(add_snooze_handler).delete(clear_snooze_handler),
        )
        // Presence (top-level, mirrors common webhook pattern)
        .route("/presence", post(set_presence))
        // Log
        .route("/notifications/log", get(get_log))
        // Third-party channels
        .route(
            "/notifications/channels",
            get(list_channels).post(create_channel),
        )
        .route(
            "/notifications/channels/:id",
            put(update_channel).delete(delete_channel_handler),
        )
        .route("/notifications/channels/:id/test", post(test_channel))
        // Global settings (GET: any bearer; PUT: admin only)
        .route(
            "/notifications/settings",
            get(get_notification_settings).put(put_notification_settings),
        )
        // System/health alert rules (P0-HEALTH-NOTIFY): GET any bearer (so
        // clients can show current config), PUT admin only.
        .route("/notifications/system-alerts", get(list_system_alerts))
        .route(
            "/notifications/system-alerts/:event_key",
            put(update_system_alert),
        )
}

// ─── request / response DTOs ──────────────────────────────────────────────────

/// `POST /notifications/devices` body.
#[derive(Debug, Deserialize)]
pub struct RegisterDeviceRequest {
    /// Stable per-install identity (generated by the app, persisted across relaunches).
    pub install_id: String,
    /// `'android'` | `'ios'` | `'web'`  (default `'android'`)
    pub platform: Option<String>,
    /// `'websocket'` | `'unifiedpush'` | `'fcm'`  (default `'websocket'`)
    pub transport: Option<String>,
    /// Required for `unifiedpush` / `fcm`; absent for `websocket`.
    pub push_token: Option<String>,
    /// Human name, e.g. `"the maintainer's Pixel 9"`.
    pub device_name: Option<String>,
}

/// `PUT /notifications/rules` and `PUT /notifications/rules/:camera_id` body.
///
/// All fields are optional: absent means "keep current value on update; use
/// system default on insert".  `null` is treated the same as absent.
#[derive(Debug, Deserialize)]
pub struct UpsertRuleRequest {
    pub presence_mode: Option<String>,
    pub notify_motion: Option<bool>,
    pub notify_detection: Option<bool>,
    pub object_labels: Option<Vec<String>>,
    pub min_score: Option<f32>,
    pub min_duration_secs: Option<i32>,
    pub quiet_start_hour: Option<i32>,
    pub quiet_end_hour: Option<i32>,
    pub cooldown_secs: Option<i32>,
}

/// `POST /notifications/snooze` body.
#[derive(Debug, Deserialize)]
pub struct SnoozeRequest {
    pub install_id: String,
    /// `None` → all cameras on this device.
    pub camera_id: Option<Uuid>,
    /// How many minutes to snooze (clamped 1..=1440).
    pub minutes: i64,
}

/// `DELETE /notifications/snooze` body.
#[derive(Debug, Deserialize)]
pub struct ClearSnoozeRequest {
    pub install_id: String,
    /// Absent → clear the all-cameras snooze.
    pub camera_id: Option<Uuid>,
}

/// `POST /presence` body.
#[derive(Debug, Deserialize)]
pub struct SetPresenceRequest {
    /// When set, updates ONLY the matching device (caller must own it).
    pub install_id: Option<String>,
    /// When set (and caller is Admin), updates ALL devices for this user.
    pub user_id: Option<Uuid>,
    /// `'home'` | `'away'`
    pub state: String,
}

/// `GET /notifications/log` query parameters.
#[derive(Debug, Deserialize)]
pub struct LogQuery {
    pub limit: Option<i64>,
}

// ─── device endpoints ─────────────────────────────────────────────────────────

/// `POST /notifications/devices` — register or re-register a push device.
async fn register_device(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<RegisterDeviceRequest>,
) -> Result<(StatusCode, Json<db::PushDevice>), ApiError> {
    if body.install_id.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "install_id must not be empty".to_owned(),
        ));
    }
    let platform = body.platform.as_deref().unwrap_or("android");
    if !matches!(platform, "android" | "ios" | "web") {
        return Err(ApiError::BadRequest(format!(
            "platform must be 'android', 'ios', or 'web'; got '{platform}'"
        )));
    }
    let transport = body.transport.as_deref().unwrap_or("websocket");
    if !matches!(transport, "websocket" | "unifiedpush" | "fcm") {
        return Err(ApiError::BadRequest(format!(
            "transport must be 'websocket', 'unifiedpush', or 'fcm'; got '{transport}'"
        )));
    }

    let device = db::register_push_device(
        state.pool(),
        user.user_id,
        body.install_id.trim(),
        platform,
        transport,
        body.push_token.as_deref(),
        body.device_name.as_deref(),
    )
    .await
    .context("register_push_device")?;

    tracing::info!(device_id = %device.id, install_id = %device.install_id, "push device registered");
    Ok((StatusCode::OK, Json(device)))
}

/// `GET /notifications/devices` — list the caller's registered devices.
async fn list_devices(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<db::PushDevice>>, ApiError> {
    let devices = db::list_push_devices(state.pool(), user.user_id)
        .await
        .context("list_push_devices")?;
    Ok(Json(devices))
}

/// `DELETE /notifications/devices/:id` — delete a device scoped to the caller.
async fn delete_device(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let deleted = db::delete_push_device(state.pool(), id, user.user_id)
        .await
        .context("delete_push_device")?;
    if deleted {
        tracing::info!(device_id = %id, "push device deleted");
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound(format!(
            "device {id} not found or not owned by caller"
        )))
    }
}

// ─── rules endpoints ──────────────────────────────────────────────────────────

/// `GET /notifications/rules` — list the caller's notification rules.
async fn list_rules(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<db::NotificationRule>>, ApiError> {
    let rules = db::list_notification_rules(state.pool(), user.user_id)
        .await
        .context("list_notification_rules")?;
    Ok(Json(rules))
}

/// Shared logic for upserting a rule for `(user_id, camera_id)`.
async fn do_upsert_rule(
    pool: &Pool,
    user_id: Uuid,
    camera_id: Option<Uuid>,
    body: UpsertRuleRequest,
) -> Result<Json<db::NotificationRule>, ApiError> {
    let presence_mode = body.presence_mode.as_deref().unwrap_or("away_only");
    if !matches!(presence_mode, "off" | "away_only" | "always") {
        return Err(ApiError::BadRequest(format!(
            "presence_mode must be 'off', 'away_only', or 'always'; got '{presence_mode}'"
        )));
    }
    let p = db::UpsertNotificationRuleParams {
        user_id,
        camera_id,
        presence_mode: presence_mode.to_owned(),
        notify_motion: body.notify_motion.unwrap_or(true),
        notify_detection: body.notify_detection.unwrap_or(true),
        object_labels: body.object_labels,
        min_score: body.min_score,
        min_duration_secs: body.min_duration_secs,
        quiet_start_hour: body.quiet_start_hour,
        quiet_end_hour: body.quiet_end_hour,
        cooldown_secs: body.cooldown_secs.unwrap_or(90),
    };
    let rule = db::upsert_notification_rule(pool, &p)
        .await
        .context("upsert_notification_rule")?;
    Ok(Json(rule))
}

/// `PUT /notifications/rules` — upsert the caller's default rule (`camera_id` NULL).
async fn upsert_default_rule(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<UpsertRuleRequest>,
) -> Result<Json<db::NotificationRule>, ApiError> {
    do_upsert_rule(state.pool(), user.user_id, None, body).await
}

/// `PUT /notifications/rules/:camera_id` — upsert a per-camera override rule.
async fn upsert_camera_rule(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
    Json(body): Json<UpsertRuleRequest>,
) -> Result<Json<db::NotificationRule>, ApiError> {
    user.assert_camera_access(camera_id)?;
    do_upsert_rule(state.pool(), user.user_id, Some(camera_id), body).await
}

// ─── snooze endpoints ─────────────────────────────────────────────────────────

/// Resolve the caller's device by `(user_id, install_id)`.
///
/// Returns `NotFound` when the device doesn't exist or isn't owned by the caller.
async fn resolve_device(
    pool: &Pool,
    user_id: Uuid,
    install_id: &str,
) -> Result<db::PushDevice, ApiError> {
    let devices = db::list_push_devices(pool, user_id)
        .await
        .context("list_push_devices (resolve)")?;
    devices
        .into_iter()
        .find(|d| d.install_id == install_id)
        .ok_or_else(|| {
            ApiError::NotFound(format!(
                "device with install_id '{install_id}' not found for caller"
            ))
        })
}

/// `POST /notifications/snooze` — snooze a device for `minutes` minutes.
async fn add_snooze_handler(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<SnoozeRequest>,
) -> Result<StatusCode, ApiError> {
    let device = resolve_device(state.pool(), user.user_id, &body.install_id).await?;
    let minutes = body.minutes.clamp(1, 1440);
    let until = Utc::now() + chrono::Duration::minutes(minutes);
    db::add_snooze(state.pool(), device.id, body.camera_id, until)
        .await
        .context("add_snooze")?;
    tracing::info!(device_id = %device.id, camera_id = ?body.camera_id, minutes, "snooze added");
    Ok(StatusCode::NO_CONTENT)
}

/// `DELETE /notifications/snooze` — clear a snooze for a device.
async fn clear_snooze_handler(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<ClearSnoozeRequest>,
) -> Result<StatusCode, ApiError> {
    let device = resolve_device(state.pool(), user.user_id, &body.install_id).await?;
    db::clear_snooze(state.pool(), device.id, body.camera_id)
        .await
        .context("clear_snooze")?;
    Ok(StatusCode::NO_CONTENT)
}

// ─── presence endpoint ────────────────────────────────────────────────────────

/// `POST /presence` — update device or user-wide presence state.
///
/// Two forms:
/// - `{install_id, state}` — update a single device owned by the caller.
/// - `{user_id, state}` — update all devices for a user; caller must be Admin.
async fn set_presence(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<SetPresenceRequest>,
) -> Result<StatusCode, ApiError> {
    let presence = body.state.as_str();
    if !matches!(presence, "home" | "away") {
        return Err(ApiError::BadRequest(format!(
            "state must be 'home' or 'away'; got '{presence}'"
        )));
    }

    match (body.install_id.as_deref(), body.user_id) {
        (Some(install_id), _) => {
            // Per-device form — caller must own the device.
            db::set_device_presence(state.pool(), user.user_id, install_id, presence, "app")
                .await
                .context("set_device_presence")?;
            tracing::debug!(install_id, presence, "device presence updated");
        }
        (None, Some(target_user_id)) => {
            // Per-user (webhook) form — Admin only.
            if !matches!(user.role, UserRole::Admin) {
                return Err(ApiError::Forbidden(
                    "setting presence for another user requires the admin role".to_owned(),
                ));
            }
            db::set_user_presence(state.pool(), target_user_id, presence, "webhook")
                .await
                .context("set_user_presence")?;
            tracing::info!(user_id = %target_user_id, presence, "user presence updated via webhook");
        }
        (None, None) => {
            return Err(ApiError::BadRequest(
                "provide either install_id (device) or user_id (all-devices webhook)".to_owned(),
            ));
        }
    }

    Ok(StatusCode::NO_CONTENT)
}

// ─── log endpoint ─────────────────────────────────────────────────────────────

/// `GET /notifications/log?limit=` — recent notification log rows.
///
/// Viewers see only rows for their own devices; Admins see all.
async fn get_log(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<LogQuery>,
) -> Result<Json<Vec<db::NotificationLog>>, ApiError> {
    let limit = q.limit.unwrap_or(100).clamp(1, 1000);
    let is_admin = matches!(user.role, UserRole::Admin);
    let rows = db::list_notification_log(state.pool(), Some(user.user_id), is_admin, limit)
        .await
        .context("list_notification_log")?;
    Ok(Json(rows))
}

// ─── channel DTOs ────────────────────────────────────────────────────────────

/// `POST /notifications/channels` body.
///
/// A channel is a **destination** only: connection config, camera scope, and
/// snapshot preference.  All filter behaviour (triggers, object labels, quiet
/// hours, cooldown, presence gating) is governed by the **owner's**
/// `notification_rules`.
#[derive(Debug, Deserialize)]
pub struct CreateChannelRequest {
    /// Channel kind: `'discord'`|`'slack'`|`'pushover'`|`'telegram'`|`'ntfy'`|`'webhook'`
    pub kind: String,
    /// Human-readable label, e.g. `"Team Discord"`.
    pub name: String,
    /// Per-kind secrets/settings (see module-level doc for per-kind shapes).
    pub config: JsonValue,
    /// `None`/absent → all cameras the owner can access.
    pub camera_ids: Option<Vec<Uuid>>,
    pub include_snapshot: Option<bool>,
    /// Admin-only: set to `true` to make the channel global (no owner).
    /// Ignored for non-Admin callers (the channel is always owned by the caller).
    #[serde(default)]
    pub global: bool,
}

/// `PUT /notifications/channels/:id` body.
///
/// `config` is optional: absent/`null` means "keep the stored config unchanged"
/// so a PATCH that doesn't re-supply credentials doesn't wipe them.
#[derive(Debug, Deserialize)]
pub struct UpdateChannelRequest {
    pub name: Option<String>,
    pub enabled: Option<bool>,
    /// Omit entirely to keep stored config (secret preservation).
    pub config: Option<JsonValue>,
    pub camera_ids: Option<Vec<Uuid>>,
    pub include_snapshot: Option<bool>,
}

/// A channel row with secrets masked, safe for API responses.
///
/// Only destination fields are exposed.  Filter behaviour is read from the
/// owner's `notification_rules` endpoint, not from this response.
#[derive(Debug, Serialize)]
pub struct ChannelResponse {
    pub id: Uuid,
    pub user_id: Option<Uuid>,
    pub kind: String,
    pub name: String,
    pub enabled: bool,
    /// Config with secret string fields replaced by `"***"`.
    pub config: JsonValue,
    pub camera_ids: Option<Vec<Uuid>>,
    pub include_snapshot: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl ChannelResponse {
    fn from_channel(ch: db::NotificationChannel) -> Self {
        let masked_config = channel_notify::mask_channel_config(&ch.config);
        Self {
            id: ch.id,
            user_id: ch.user_id,
            kind: ch.kind,
            name: ch.name,
            enabled: ch.enabled,
            config: masked_config,
            camera_ids: ch.camera_ids,
            include_snapshot: ch.include_snapshot,
            created_at: ch.created_at,
            updated_at: ch.updated_at,
        }
    }
}

// ─── channel endpoints ────────────────────────────────────────────────────────

/// `GET /notifications/channels` — list caller's channels (+ global channels for Admins).
async fn list_channels(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<ChannelResponse>>, ApiError> {
    let is_admin = matches!(user.role, UserRole::Admin);
    let channels = db::list_notification_channels(state.pool(), user.user_id, is_admin)
        .await
        .context("list_notification_channels")?;
    Ok(Json(
        channels
            .into_iter()
            .map(ChannelResponse::from_channel)
            .collect(),
    ))
}

/// `POST /notifications/channels` — create a notification channel.
async fn create_channel(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<CreateChannelRequest>,
) -> Result<(StatusCode, Json<ChannelResponse>), ApiError> {
    if !matches!(
        body.kind.as_str(),
        "discord" | "slack" | "pushover" | "telegram" | "ntfy" | "webhook"
    ) {
        return Err(ApiError::BadRequest(format!(
            "kind must be one of discord/slack/pushover/telegram/ntfy/webhook; got '{}'",
            body.kind
        )));
    }
    if body.name.trim().is_empty() {
        return Err(ApiError::BadRequest("name must not be empty".to_owned()));
    }

    // P0-5: a non-admin may not scope a channel to cameras outside their grants.
    assert_camera_ids_in_scope(&user, body.camera_ids.as_deref())?;

    // Only Admins may create global channels (user_id = NULL).
    let owner = if body.global && matches!(user.role, UserRole::Admin) {
        None
    } else {
        Some(user.user_id)
    };

    let p = db::CreateChannelParams {
        user_id: owner,
        kind: body.kind,
        name: body.name.trim().to_owned(),
        enabled: true,
        config: body.config,
        camera_ids: body.camera_ids,
        include_snapshot: body.include_snapshot.unwrap_or(true),
    };
    let ch = db::create_notification_channel(state.pool(), &p)
        .await
        .context("create_notification_channel")?;

    tracing::info!(
        channel_id = %ch.id,
        kind = %ch.kind,
        name = %ch.name,
        "notification channel created"
    );
    Ok((StatusCode::CREATED, Json(ChannelResponse::from_channel(ch))))
}

/// Reject a non-admin caller supplying `camera_ids` outside their own grants
/// (P0-5). A channel's camera scope must never exceed what its owner is allowed
/// to see, so a Viewer may only list cameras in their assigned scope. Admins may
/// set any cameras. An absent/empty list is always allowed — it means "all
/// cameras the owner can access", which the fan-out already intersects with the
/// owner's live grants, so it can never leak a camera the owner loses access to.
fn assert_camera_ids_in_scope(
    user: &AuthUser,
    camera_ids: Option<&[Uuid]>,
) -> Result<(), ApiError> {
    if user.is_admin() {
        return Ok(());
    }
    if let Some(ids) = camera_ids {
        for id in ids {
            if !user.camera_ids.contains(id) {
                return Err(ApiError::Forbidden(format!(
                    "camera {id} is not in your assigned camera list"
                )));
            }
        }
    }
    Ok(())
}

/// Resolve a channel and assert the caller owns it (or is Admin).
///
/// Returns `NotFound` when no row exists, `Forbidden` when owned by another user.
async fn resolve_owned_channel(
    pool: &Pool,
    id: Uuid,
    user: &AuthUser,
) -> Result<db::NotificationChannel, ApiError> {
    let ch = db::get_notification_channel(pool, id)
        .await
        .context("get_notification_channel")?
        .ok_or_else(|| ApiError::NotFound(format!("channel {id} not found")))?;

    // Global channels (user_id = None) are only editable by Admins.
    let is_admin = matches!(user.role, UserRole::Admin);
    let is_owner = ch.user_id == Some(user.user_id);
    if !is_admin && !is_owner {
        return Err(ApiError::Forbidden(
            "channel not owned by caller".to_owned(),
        ));
    }
    Ok(ch)
}

/// `PUT /notifications/channels/:id` — update a channel.
async fn update_channel(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateChannelRequest>,
) -> Result<Json<ChannelResponse>, ApiError> {
    let existing = resolve_owned_channel(state.pool(), id, &user).await?;

    // P0-5: a non-admin may not widen a channel's camera scope beyond their
    // grants (only checks a newly-supplied list; an absent list keeps existing).
    assert_camera_ids_in_scope(&user, body.camera_ids.as_deref())?;

    let params = db::UpdateChannelParams {
        id,
        name: body
            .name
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .unwrap_or(existing.name),
        enabled: body.enabled.unwrap_or(existing.enabled),
        config: body.config, // None = keep stored
        camera_ids: body.camera_ids.or(existing.camera_ids),
        include_snapshot: body.include_snapshot.unwrap_or(existing.include_snapshot),
    };

    let ch = db::update_notification_channel(state.pool(), &params)
        .await
        .context("update_notification_channel")?
        .ok_or_else(|| ApiError::NotFound(format!("channel {id} not found")))?;

    tracing::info!(channel_id = %id, "notification channel updated");
    Ok(Json(ChannelResponse::from_channel(ch)))
}

/// `DELETE /notifications/channels/:id` — delete a channel.
async fn delete_channel_handler(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    // Ownership check — also confirms the row exists.
    resolve_owned_channel(state.pool(), id, &user).await?;

    let deleted = db::delete_notification_channel(state.pool(), id)
        .await
        .context("delete_notification_channel")?;

    if deleted {
        tracing::info!(channel_id = %id, "notification channel deleted");
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound(format!("channel {id} not found")))
    }
}

/// `POST /notifications/channels/:id/test` — fire a sample notification immediately.
///
/// Builds a synthetic [`ChannelMessage`] (with a live snapshot when
/// `include_snapshot` is true) and calls [`channel_notify::dispatch`].
/// Returns `{"ok": true}` on success or `{"ok": false, "error": "..."}` on failure.
async fn test_channel(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let ch = resolve_owned_channel(state.pool(), id, &user).await?;

    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build reqwest client: {e}")))?;

    // Fetch a live snapshot if the channel wants one and we can get it.
    let snapshot = if ch.include_snapshot {
        let b = resolve_bases(&state).await;
        channel_notify::fetch_snapshot(
            &http,
            // Pick any accessible camera for the test — use the first camera_id in
            // the channel's list, or try to find any enabled camera as fallback.
            ch.camera_ids
                .as_ref()
                .and_then(|ids| ids.first().copied())
                .unwrap_or(Uuid::nil()),
            &b.crumb_api,
            &b.frigate_go2rtc_api,
            state.pool(),
            &state.config().go2rtc_user,
            &state.config().go2rtc_pass,
        )
        .await
    } else {
        None
    };

    let msg = ChannelMessage {
        camera_name: "Test Camera".to_owned(),
        kind: "motion",
        label: None,
        ts: Utc::now(),
        web_url: None,
        snapshot,
        detail: None,
    };

    match channel_notify::dispatch(&http, &ch, &msg).await {
        Ok(()) => {
            tracing::info!(channel_id = %id, kind = %ch.kind, "test notification sent");
            Ok(Json(serde_json::json!({ "ok": true })))
        }
        Err(e) => {
            tracing::warn!(channel_id = %id, error = %e, "test notification failed");
            Ok(Json(
                serde_json::json!({ "ok": false, "error": e.to_string() }),
            ))
        }
    }
}

// ─── global notification settings ────────────────────────────────────────────

/// Wire shape for `GET /notifications/settings` and `PUT /notifications/settings`.
#[derive(Debug, Serialize, Deserialize)]
pub struct NotificationSettingsResponse {
    /// When `false` the engine consumes events but sends nothing.
    pub enabled: bool,
    /// Global quiet-hours window used ONLY by the system/health alerts
    /// pipeline (P0-HEALTH-NOTIFY) — camera motion/detection quiet hours
    /// remain per-user via `notification_rules`. `None`/absent = no quiet
    /// hours. Both must be set together for the window to apply.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_quiet_start_hour: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_quiet_end_hour: Option<i32>,
}

/// `GET /notifications/settings` — read the global notification master switch
/// + the system-alerts quiet-hours window.
///
/// Any authenticated user may call this (so clients can display a banner when
/// the system-wide switch is off).
async fn get_notification_settings(
    _user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<NotificationSettingsResponse>, ApiError> {
    let enabled = db::get_notifications_enabled(state.pool())
        .await
        .context("get_notifications_enabled")?;
    let (qs, qe) = db::get_system_alert_quiet_hours(state.pool())
        .await
        .context("get_system_alert_quiet_hours")?;
    Ok(Json(NotificationSettingsResponse {
        enabled,
        system_quiet_start_hour: qs,
        system_quiet_end_hour: qe,
    }))
}

/// `PUT /notifications/settings` — toggle the global notification master switch
/// and/or the system-alerts quiet-hours window.
///
/// Admin-only.  When `enabled` is `false` the engine continues to advance its
/// cursor through new events (so the backlog does not grow) but skips all
/// device pushes and channel dispatches for that tick.  Flipping it back to
/// `true` resumes delivery without replaying any suppressed events.
async fn put_notification_settings(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(body): Json<NotificationSettingsResponse>,
) -> Result<Json<NotificationSettingsResponse>, ApiError> {
    db::set_notifications_enabled(state.pool(), body.enabled)
        .await
        .context("set_notifications_enabled")?;
    db::set_system_alert_quiet_hours(
        state.pool(),
        body.system_quiet_start_hour,
        body.system_quiet_end_hour,
    )
    .await
    .context("set_system_alert_quiet_hours")?;
    tracing::info!(enabled = body.enabled, "global notification switch updated");
    Ok(Json(NotificationSettingsResponse {
        enabled: body.enabled,
        system_quiet_start_hour: body.system_quiet_start_hour,
        system_quiet_end_hour: body.system_quiet_end_hour,
    }))
}

// ─── system alert rules (P0-HEALTH-NOTIFY) ───────────────────────────────────

/// `GET /notifications/system-alerts` — list all system/health alert rules.
///
/// Any authenticated user may call this (mirrors `/notifications/settings` —
/// read access is not sensitive; only mutation is admin-gated).
async fn list_system_alerts(
    _user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<db::SystemAlertRule>>, ApiError> {
    let rules = db::list_system_alert_rules(state.pool())
        .await
        .context("list_system_alert_rules")?;
    Ok(Json(rules))
}

/// `PUT /notifications/system-alerts/:event_key` body. All fields optional:
/// absent means "keep the stored value unchanged".
#[derive(Debug, Deserialize)]
pub struct UpdateSystemAlertRequest {
    pub enabled: Option<bool>,
    pub threshold_secs: Option<Option<i32>>,
    pub threshold_fraction: Option<Option<f32>>,
    pub bypass_quiet_hours: Option<bool>,
    pub cooldown_secs: Option<i32>,
}

/// `PUT /notifications/system-alerts/:event_key` — update one system-alert
/// rule (on/off, threshold, quiet-hours bypass, cooldown). Admin-only.
///
/// Rules are seeded by migration `0032_system_alerts.sql`; this endpoint only
/// updates an existing row (404 for an unknown `event_key`) — it never
/// creates new event types via the API.
async fn update_system_alert(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(event_key): Path<String>,
    Json(body): Json<UpdateSystemAlertRequest>,
) -> Result<Json<db::SystemAlertRule>, ApiError> {
    let p = db::UpdateSystemAlertRuleParams {
        enabled: body.enabled,
        threshold_secs: body.threshold_secs,
        threshold_fraction: body.threshold_fraction,
        bypass_quiet_hours: body.bypass_quiet_hours,
        cooldown_secs: body.cooldown_secs,
    };
    let rule = db::update_system_alert_rule(state.pool(), &event_key, &p)
        .await
        .context("update_system_alert_rule")?
        .ok_or_else(|| ApiError::NotFound(format!("system alert rule '{event_key}' not found")))?;
    tracing::info!(event_key = %event_key, "system alert rule updated");
    Ok(Json(rule))
}

// ─── notification engine ──────────────────────────────────────────────────────

/// System-default rule values used when a device has no matching rule.
const DEFAULT_PRESENCE_MODE: &str = "away_only";
const DEFAULT_COOLDOWN_SECS: i32 = 90;

/// How often the engine polls for new events.
const ENGINE_POLL_SECS: u64 = 3;

/// Re-read the `notifications_enabled` flag at most once per this many seconds.
/// A cheap SELECT every ~15 s keeps the gate responsive without adding per-tick
/// DB round-trips on every 3 s poll.
const ENABLED_CACHE_SECS: u64 = 15;

/// Max events fetched per tick (bounds one tick's DB read).
const ENGINE_BATCH: i64 = 200;

/// Background notification engine.
///
/// Runs every [`ENGINE_POLL_SECS`] seconds, polling `events` for rows newer than
/// the last processed timestamp.  For each event it fans out over:
///
/// - Every registered **push device**: evaluates all gate conditions and writes a
///   `notification_log` row on pass (transport delivery is a future increment).
/// - Every enabled **notification channel**: resolves the owner's effective rule
///   (per-camera override → user default → system default), applies all gates
///   including presence, and dispatches via [`crate::channel_notify::dispatch`].
///
/// Initialised at boot to `Utc::now()` — history is NOT replayed.
///
/// Cooldown state is in-memory: `HashMap<(id, camera_id), Instant>`.
/// On restart the cooldown resets to zero (acceptable for a first-increment engine).
///
/// # Gate evaluation order (device path and channel path share the same gates)
///
/// 1. Presence mode (off / `away_only` / always)  — owner's rule; global channels skip this
/// 2. Event type (motion / detection)
/// 3. Object label filter
/// 4. Min score
/// 5. Min duration
/// 6. Quiet hours
/// 7. Snooze (device path only)
/// 8. Cooldown (in-memory)
///
/// Only events with lifecycle `'start'` are processed (so each unique event fires
/// at most once).
///
/// `go2rtc_user` / `go2rtc_pass` (P0-GO2RTC lighter lockdown): Basic-auth
/// credentials for Crumb's own go2rtc REST API, needed for the snapshot fetch
/// below now that go2rtc's API requires auth for non-loopback callers. This
/// engine task owns only a `Pool` (not `AppState`/`ApiConfig`), so the
/// credentials are threaded in explicitly from `main.rs` rather than cloning
/// the whole config.
pub async fn run_notification_engine(
    pool: Pool,
    go2rtc_user: String,
    go2rtc_pass: String,
    maintenance_until: std::sync::Arc<std::sync::atomic::AtomicI64>,
) {
    // Initialise to "now" so we don't replay history on startup.
    let mut last_ts: DateTime<Utc> = Utc::now();
    // recently-seen id set to avoid double-processing on the boundary row.
    let mut seen_ids: std::collections::HashSet<Uuid> = std::collections::HashSet::new();
    // In-memory cooldown maps:
    //   device path: (device_id, camera_id) → Instant of last pass.
    //   channel path: (channel_id, camera_id) → Instant of last pass.
    let mut cooldown_map: HashMap<(Uuid, Uuid), Instant> = HashMap::new();
    let mut channel_cooldown_map: HashMap<(Uuid, Uuid), Instant> = HashMap::new();
    // Cached global enable flag + the Instant we last refreshed it.
    let mut notifications_enabled: bool = true;
    let mut enabled_checked_at: Option<Instant> = None;

    // P0-HEALTH-NOTIFY: independent cursor + cooldown map for the system-events
    // (health/footage-loss) poller. Kept entirely separate from the camera-event
    // state above: system events have no device fan-out, no presence/label/
    // score/duration gating, and use `system_alert_rules` (not
    // `notification_rules`) for enable/threshold/quiet-hours-bypass — the two
    // pipelines only share the tick cadence, the channel list, and `dispatch`.
    let mut sys_last_ts: DateTime<Utc> = Utc::now();
    let mut sys_seen_ids: std::collections::HashSet<Uuid> = std::collections::HashSet::new();
    // Keyed by (event_key interned as a fixed string via camera_id substitution
    // isn't possible for a String key in a Copy-friendly map, so this uses
    // (String, Uuid) with Uuid::nil() standing in for "no camera").
    let mut sys_cooldown_map: HashMap<(String, Uuid), Instant> = HashMap::new();

    // Single reqwest client shared across all ticks for connection reuse.
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .unwrap_or_default();

    let mut ticker = tokio::time::interval(tokio::time::Duration::from_secs(ENGINE_POLL_SECS));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    tracing::info!(poll_secs = ENGINE_POLL_SECS, "notification engine started");

    loop {
        ticker.tick().await;

        // ── system/health events (independent of the camera-event pipeline
        //    below — runs every tick regardless of whether any camera event
        //    arrived, and is NOT gated by the camera events.is_empty() early
        //    return that follows) ────────────────────────────────────────────
        dispatch_system_events_tick(
            &pool,
            &http_client,
            &mut sys_last_ts,
            &mut sys_seen_ids,
            &mut sys_cooldown_map,
            &maintenance_until,
        )
        .await;

        // ── fetch new events ──────────────────────────────────────────────────
        let events = match db::events_since(&pool, last_ts, ENGINE_BATCH).await {
            Ok(e) => e,
            Err(err) => {
                tracing::warn!(error = %err, "notification engine: events_since failed");
                continue;
            }
        };

        if events.is_empty() {
            continue;
        }

        // Advance cursor to the latest ts in this batch (even if all are filtered).
        let new_last = events.last().map_or(last_ts, |e| e.ts);

        // ── global enable gate ────────────────────────────────────────────────
        //
        // Re-read from DB at most once per ENABLED_CACHE_SECS to stay responsive
        // without adding a DB round-trip to every 3 s tick.
        //
        // When OFF: advance last_ts + seen_ids (cursor moves forward) so that
        // re-enabling does NOT backlog old events.  Skip all dispatch for this tick.
        let needs_refresh =
            enabled_checked_at.is_none_or(|t| t.elapsed().as_secs() >= ENABLED_CACHE_SECS);
        if needs_refresh {
            match db::get_notifications_enabled(&pool).await {
                Ok(v) => {
                    notifications_enabled = v;
                    enabled_checked_at = Some(Instant::now());
                }
                Err(err) => {
                    // DB error: keep the last-known value (fail-open = keep sending
                    // rather than silently swallowing alerts on a transient blip).
                    tracing::warn!(
                        error = %err,
                        "notification engine: get_notifications_enabled failed; keeping last value"
                    );
                }
            }
        }

        if !notifications_enabled {
            // Consume events without dispatching anything.
            for event in &events {
                seen_ids.insert(event.id);
            }
            last_ts = new_last;
            if seen_ids.len() > (ENGINE_BATCH as usize) * 4 {
                seen_ids.clear();
            }
            tracing::debug!(
                batch = events.len(),
                "notification engine: global switch OFF — events consumed, dispatch skipped"
            );
            continue;
        }

        // ── load devices + owners (one round-trip per tick) ───────────────────
        let devices_with_owners = match db::list_devices_with_owner(&pool).await {
            Ok(d) => d,
            Err(err) => {
                tracing::warn!(error = %err, "notification engine: list_devices_with_owner failed");
                continue;
            }
        };

        // ── load enabled channels once per tick ───────────────────────────────
        let enabled_channels = match db::list_enabled_channels(&pool).await {
            Ok(c) => c,
            Err(err) => {
                tracing::warn!(error = %err, "notification engine: list_enabled_channels failed");
                Vec::new()
            }
        };

        if devices_with_owners.is_empty() && enabled_channels.is_empty() {
            last_ts = new_last;
            seen_ids.clear();
            continue;
        }

        // ── load all rules in one pass (group by user_id for lookup) ──────────
        // Build a per-user rule cache: user_id → Vec<NotificationRule> (sorted
        // default-first by the DB query).
        //
        // Include BOTH device owners (device path) AND channel owners (channel
        // path) so the channel fan-out can resolve the effective rule without an
        // extra DB round-trip per channel.  Global channels (user_id=None) are
        // skipped — they use the system default (no entry in the cache).
        let mut user_ids: std::collections::HashSet<Uuid> = devices_with_owners
            .iter()
            .map(|(d, _, _)| d.user_id)
            .collect();
        for ch in &enabled_channels {
            if let Some(uid) = ch.user_id {
                user_ids.insert(uid);
            }
        }

        let mut rules_cache: HashMap<Uuid, Vec<db::NotificationRule>> = HashMap::new();
        for uid in &user_ids {
            match db::list_notification_rules(&pool, *uid).await {
                Ok(rules) => {
                    rules_cache.insert(*uid, rules);
                }
                Err(err) => {
                    tracing::warn!(error = %err, user_id = %uid, "notification engine: list_notification_rules failed");
                }
            }
        }

        // ── resolve channel-owner grants from the DB (P0-5) ───────────────────
        // The channel fan-out must intersect delivery with the OWNER's real
        // access (role + per-camera grants + capabilities), resolved fresh from
        // the DB — NOT inferred from the push-device snapshot (an owner with no
        // registered device would otherwise appear to have no access, or, worse,
        // a channel's own camera_ids would silently replace the owner check).
        // Global channels (user_id = None) have no owner and are unrestricted.
        let mut owner_grants: HashMap<Uuid, db::UserGrants> = HashMap::new();
        for ch in &enabled_channels {
            if let Some(uid) = ch.user_id {
                if let std::collections::hash_map::Entry::Vacant(e) = owner_grants.entry(uid) {
                    match db::resolve_user_grants(&pool, uid).await {
                        Ok(Some(g)) => {
                            e.insert(g);
                        }
                        // Owner row missing (deleted) → leave absent; the
                        // fan-out treats "no grants" as no camera access.
                        Ok(None) => {}
                        Err(err) => {
                            tracing::warn!(error = %err, user_id = %uid, "notification engine: resolve_user_grants failed");
                        }
                    }
                }
            }
        }

        let now = Utc::now();

        for event in &events {
            // Skip already-processed boundary events.
            if seen_ids.contains(&event.id) {
                continue;
            }

            // Only fire on START lifecycle (each unique event once).
            if event.lifecycle != "start" {
                continue;
            }

            let kind = if event.source_id == "motion" {
                "motion"
            } else {
                "detection"
            };

            // ── per-device fan-out ────────────────────────────────────────────
            for (device, owner_role, owner_camera_ids) in &devices_with_owners {
                // Access check: Admin sees all; Viewer must have the camera.
                let can_access = matches!(owner_role, UserRole::Admin)
                    || owner_camera_ids.contains(&event.camera_id);
                if !can_access {
                    tracing::debug!(
                        device_id = %device.id,
                        camera_id = %event.camera_id,
                        "engine: device owner cannot access camera — skip"
                    );
                    continue;
                }

                // Resolve effective rule: per-camera → user default → system default.
                let user_rules = rules_cache
                    .get(&device.user_id)
                    .map_or(&[] as &[db::NotificationRule], Vec::as_slice);

                let effective_rule = resolve_effective_rule(user_rules, event.camera_id);

                // ── Gate 1: presence mode ─────────────────────────────────────
                let presence_mode =
                    effective_rule.map_or(DEFAULT_PRESENCE_MODE, |r| r.presence_mode.as_str());

                match presence_mode {
                    "off" => {
                        tracing::debug!(device_id = %device.id, "engine: gate presence=off — drop");
                        continue;
                    }
                    "away_only" if device.presence != "away" => {
                        tracing::debug!(
                            device_id = %device.id,
                            presence = %device.presence,
                            "engine: gate presence=away_only but device is home — drop"
                        );
                        continue;
                    }
                    _ => {}
                }

                // ── Gate 2: event type ────────────────────────────────────────
                let (notify_motion, notify_detection) =
                    effective_rule.map_or((true, true), |r| (r.notify_motion, r.notify_detection));

                let type_ok = match kind {
                    "motion" => notify_motion,
                    _ => notify_detection,
                };
                if !type_ok {
                    tracing::debug!(
                        device_id = %device.id,
                        kind,
                        "engine: gate type disabled — drop"
                    );
                    continue;
                }

                // ── Gate 3: object label filter ───────────────────────────────
                if kind == "detection" {
                    if let Some(rule) = effective_rule {
                        if let Some(labels) = &rule.object_labels {
                            if !labels.is_empty() && !labels.contains(&event.label) {
                                tracing::debug!(
                                    device_id = %device.id,
                                    label = %event.label,
                                    "engine: gate object_labels — drop"
                                );
                                continue;
                            }
                        }
                    }
                }

                // ── Gate 4: min_score ─────────────────────────────────────────
                if let Some(rule) = effective_rule {
                    if let Some(min_score) = rule.min_score {
                        if event.score < min_score {
                            tracing::debug!(
                                device_id = %device.id,
                                score = event.score,
                                min_score,
                                "engine: gate min_score — drop"
                            );
                            continue;
                        }
                    }
                }

                // ── Gate 5: min_duration_secs ─────────────────────────────────
                if let Some(rule) = effective_rule {
                    if let Some(min_dur) = rule.min_duration_secs {
                        if let Some(end_ts) = event.end_ts {
                            let dur = (end_ts - event.ts).num_seconds();
                            if dur < i64::from(min_dur) {
                                tracing::debug!(
                                    device_id = %device.id,
                                    dur,
                                    min_dur,
                                    "engine: gate min_duration — drop"
                                );
                                continue;
                            }
                        }
                        // end_ts absent (ongoing event) → skip this gate.
                    }
                }

                // ── Gate 6: quiet hours ───────────────────────────────────────
                if let Some(rule) = effective_rule {
                    if let (Some(qstart), Some(qend)) = (rule.quiet_start_hour, rule.quiet_end_hour)
                    {
                        let hour = now.with_timezone(&chrono::Local).hour_from_utc_with_local();
                        if in_quiet_hours(hour, qstart, qend) {
                            tracing::debug!(
                                device_id = %device.id,
                                hour,
                                qstart,
                                qend,
                                "engine: gate quiet_hours — drop"
                            );
                            continue;
                        }
                    }
                }

                // ── Gate 7: snooze ────────────────────────────────────────────
                let snoozes = match db::active_snoozes_for_device(&pool, device.id, now).await {
                    Ok(s) => s,
                    Err(err) => {
                        tracing::warn!(error = %err, device_id = %device.id, "engine: active_snoozes_for_device failed");
                        Vec::new()
                    }
                };

                let is_snoozed = snoozes
                    .iter()
                    .any(|(cam, _until)| cam.is_none() || cam == &Some(event.camera_id));
                if is_snoozed {
                    tracing::debug!(device_id = %device.id, "engine: gate snooze — drop");
                    continue;
                }

                // ── Gate 8: cooldown (in-memory) ──────────────────────────────
                let cooldown_secs =
                    i64::from(effective_rule.map_or(DEFAULT_COOLDOWN_SECS, |r| r.cooldown_secs));
                let cooldown_key = (device.id, event.camera_id);
                if let Some(&last_pass) = cooldown_map.get(&cooldown_key) {
                    let elapsed = last_pass.elapsed().as_secs() as i64;
                    if elapsed < cooldown_secs {
                        tracing::debug!(
                            device_id = %device.id,
                            elapsed,
                            cooldown_secs,
                            "engine: gate cooldown — drop"
                        );
                        continue;
                    }
                }

                // ── All gates passed: log + update cooldown ───────────────────
                cooldown_map.insert(cooldown_key, Instant::now());

                if let Err(err) = db::insert_notification_log(
                    &pool,
                    Some(event.id),
                    Some(event.camera_id),
                    Some(device.id),
                    kind,
                    "suppressed",
                    Some("pass: would deliver (transport pending)"),
                )
                .await
                {
                    tracing::warn!(error = %err, "notification engine: insert_notification_log failed");
                } else {
                    tracing::debug!(
                        device_id = %device.id,
                        event_id = %event.id,
                        kind,
                        "notification engine: PASS — log row written"
                    );
                }
            }

            // ── channel fan-out ───────────────────────────────────────────────
            //
            // Each enabled channel is a destination only.  Gate evaluation is
            // driven by the **owner's** effective `notification_rule` (per-camera
            // override → user default → system default), mirroring the device path.
            //
            // Global channels (user_id = NULL) use the system default rule and
            // skip presence gating — they act as admin-firehose integrations.
            //
            // Snapshot is fetched at most once per event (after the first pass
            // collects passing channels) and shared across all channels that want it.

            // First pass: evaluate gates for all channels, collect passing ones.
            let mut passing_channels: Vec<&db::NotificationChannel> = Vec::new();
            for ch in &enabled_channels {
                // ── Step 1: access + camera-scope check ───────────────────────
                //
                // For owned channels the owner's access (Admin = all; Viewer =
                // their camera_ids) is the outer bound.  The channel's own
                // camera_ids list, when non-empty, further narrows that scope.
                // For global channels (no owner) only the channel's own
                // camera_ids scope applies (empty = all).
                if let Some(ch_owner_id) = ch.user_id {
                    // Owner access (role + per-camera grants) resolved from the
                    // DB — the OUTER bound, always enforced (P0-5). A missing
                    // entry means the owner was deleted / unresolvable → no
                    // access (non-admin, empty cameras) → drop.
                    let grants = owner_grants.get(&ch_owner_id);
                    let owner_is_admin = grants.is_some_and(|g| g.is_admin);
                    let owner_cam_ids: &[Uuid] = grants.map_or(&[], |g| g.camera_ids.as_slice());

                    // INTERSECT (not replace): the event's camera must be within
                    // the owner's access AND (if the channel has an explicit
                    // camera_ids scope) within that scope too. An empty channel
                    // scope means "all cameras the owner can access".
                    if !owner_is_admin && !owner_cam_ids.contains(&event.camera_id) {
                        continue;
                    }
                    let ch_cam_ids = ch.camera_ids.as_deref().unwrap_or(&[]);
                    if !ch_cam_ids.is_empty() && !ch_cam_ids.contains(&event.camera_id) {
                        continue;
                    }
                } else {
                    // Global channel: apply only the channel's own camera_ids scope.
                    let ch_cam_ids = ch.camera_ids.as_deref().unwrap_or(&[]);
                    if !ch_cam_ids.is_empty() && !ch_cam_ids.contains(&event.camera_id) {
                        continue;
                    }
                }

                // ── Step 2: resolve the owner's effective rule ────────────────
                //
                // Global channels (no owner) get the system default (rules_cache
                // will have no entry for None) and skip presence gating.
                let is_global = ch.user_id.is_none();
                let owner_rules: &[db::NotificationRule] = ch
                    .user_id
                    .and_then(|uid| rules_cache.get(&uid))
                    .map_or(&[], Vec::as_slice);
                let effective_rule = resolve_effective_rule(owner_rules, event.camera_id);

                // ── Step 3: presence gate (owned channels only) ───────────────
                if !is_global {
                    let presence_mode =
                        effective_rule.map_or(DEFAULT_PRESENCE_MODE, |r| r.presence_mode.as_str());
                    if presence_mode == "off" {
                        tracing::debug!(channel_id = %ch.id, "engine: channel gate presence=off — drop");
                        continue;
                    }
                    if presence_mode == "away_only" {
                        // Determine owner presence: home if ANY device is 'home'.
                        let owner_presence = if let Some(owner_id) = ch.user_id {
                            owner_presence_from_devices(&devices_with_owners, owner_id)
                        } else {
                            "away"
                        };
                        if owner_presence != "away" {
                            tracing::debug!(
                                channel_id = %ch.id,
                                owner_presence,
                                "engine: channel gate presence=away_only but owner is home — drop"
                            );
                            continue;
                        }
                    }
                    // "always" — no presence gate needed.
                }

                // ── Step 4: event type gate ───────────────────────────────────
                let (notify_motion, notify_detection) =
                    effective_rule.map_or((true, true), |r| (r.notify_motion, r.notify_detection));
                let type_ok = match kind {
                    "motion" => notify_motion,
                    _ => notify_detection,
                };
                if !type_ok {
                    tracing::debug!(channel_id = %ch.id, kind, "engine: channel gate type disabled — drop");
                    continue;
                }

                // ── Step 5: object label filter ───────────────────────────────
                if kind == "detection" {
                    if let Some(rule) = effective_rule {
                        if let Some(labels) = &rule.object_labels {
                            if !labels.is_empty() && !labels.contains(&event.label) {
                                tracing::debug!(
                                    channel_id = %ch.id,
                                    label = %event.label,
                                    "engine: channel gate object_labels — drop"
                                );
                                continue;
                            }
                        }
                    }
                }

                // ── Step 6: min_score gate ────────────────────────────────────
                if let Some(rule) = effective_rule {
                    if let Some(min_score) = rule.min_score {
                        if event.score < min_score {
                            tracing::debug!(
                                channel_id = %ch.id,
                                score = event.score,
                                min_score,
                                "engine: channel gate min_score — drop"
                            );
                            continue;
                        }
                    }
                }

                // ── Step 7: min_duration gate ─────────────────────────────────
                if let Some(rule) = effective_rule {
                    if let Some(min_dur) = rule.min_duration_secs {
                        if let Some(end_ts) = event.end_ts {
                            let dur = (end_ts - event.ts).num_seconds();
                            if dur < i64::from(min_dur) {
                                tracing::debug!(
                                    channel_id = %ch.id,
                                    dur,
                                    min_dur,
                                    "engine: channel gate min_duration — drop"
                                );
                                continue;
                            }
                        }
                        // end_ts absent (ongoing) → skip this gate.
                    }
                }

                // ── Step 8: quiet hours gate ──────────────────────────────────
                if let Some(rule) = effective_rule {
                    if let (Some(qstart), Some(qend)) = (rule.quiet_start_hour, rule.quiet_end_hour)
                    {
                        let hour = now.with_timezone(&chrono::Local).hour_from_utc_with_local();
                        if in_quiet_hours(hour, qstart, qend) {
                            tracing::debug!(
                                channel_id = %ch.id,
                                hour,
                                qstart,
                                qend,
                                "engine: channel gate quiet_hours — drop"
                            );
                            continue;
                        }
                    }
                }

                // ── Step 9: cooldown (in-memory, keyed channel_id+camera_id) ──
                let cooldown_secs =
                    i64::from(effective_rule.map_or(DEFAULT_COOLDOWN_SECS, |r| r.cooldown_secs));
                let ch_cooldown_key = (ch.id, event.camera_id);
                if let Some(&last_pass) = channel_cooldown_map.get(&ch_cooldown_key) {
                    if (last_pass.elapsed().as_secs() as i64) < cooldown_secs {
                        tracing::debug!(
                            channel_id = %ch.id,
                            cooldown_secs,
                            "engine: channel gate cooldown — drop"
                        );
                        continue;
                    }
                }

                passing_channels.push(ch);
            }

            if !passing_channels.is_empty() {
                // Resolve camera name for the message (one DB call per event, not per channel).
                let camera_name = match db::get_camera(&pool, event.camera_id).await {
                    Ok(Some(cam)) => cam.name,
                    Ok(None) => format!("camera {}", event.camera_id),
                    Err(e) => {
                        tracing::warn!(error = %e, "engine: get_camera for channel msg failed");
                        format!("camera {}", event.camera_id)
                    }
                };

                // Fetch snapshot once if any passing channel wants it.
                let needs_snapshot = passing_channels.iter().any(|ch| ch.include_snapshot);
                let snapshot: Option<Vec<u8>> = if needs_snapshot {
                    // We don't have AppState here (the engine task owns only the pool),
                    // so we fetch go2rtc bases from DB directly.
                    let settings = crumb_common::db::get_server_settings(&pool)
                        .await
                        .ok()
                        .flatten();
                    let crumb_api = settings
                        .as_ref()
                        .map(|s| s.crumb_api_base.as_str())
                        .filter(|v| !v.is_empty())
                        .unwrap_or("http://recorder:1984")
                        .to_owned();
                    let frigate_api = settings
                        .as_ref()
                        .map(|s| {
                            if s.frigate_go2rtc_api_base.is_empty() {
                                s.frigate_api_base.as_str()
                            } else {
                                s.frigate_go2rtc_api_base.as_str()
                            }
                        })
                        .filter(|v| !v.is_empty())
                        .unwrap_or("http://frigate:1984")
                        .to_owned();
                    channel_notify::fetch_snapshot(
                        &http_client,
                        event.camera_id,
                        &crumb_api,
                        &frigate_api,
                        &pool,
                        &go2rtc_user,
                        &go2rtc_pass,
                    )
                    .await
                } else {
                    None
                };

                let label_opt = if event.label.is_empty() {
                    None
                } else {
                    Some(event.label.clone())
                };

                for ch in passing_channels {
                    let msg = ChannelMessage {
                        camera_name: camera_name.clone(),
                        kind: if kind == "motion" {
                            "motion"
                        } else {
                            "detection"
                        },
                        label: label_opt.clone(),
                        ts: event.ts,
                        web_url: None, // no public URL configured
                        snapshot: if ch.include_snapshot {
                            snapshot.clone()
                        } else {
                            None
                        },
                        detail: None,
                    };

                    let (status, reason) = match channel_notify::dispatch(&http_client, ch, &msg)
                        .await
                    {
                        Ok(()) => {
                            tracing::debug!(
                                channel_id = %ch.id,
                                kind,
                                "engine: channel notification sent"
                            );
                            channel_cooldown_map.insert((ch.id, event.camera_id), Instant::now());
                            ("sent", None)
                        }
                        Err(e) => {
                            tracing::warn!(
                                channel_id = %ch.id,
                                kind,
                                error = %e,
                                "engine: channel notification failed"
                            );
                            ("failed", Some(e.to_string()))
                        }
                    };

                    if let Err(err) = db::insert_channel_notification_log(
                        &pool,
                        Some(event.id),
                        Some(event.camera_id),
                        Some(ch.id),
                        kind,
                        status,
                        reason.as_deref(),
                    )
                    .await
                    {
                        tracing::warn!(
                            error = %err,
                            "engine: insert_channel_notification_log failed"
                        );
                    }
                }
            }

            seen_ids.insert(event.id);
        }

        // Advance the cursor.
        last_ts = new_last;

        // Bound the seen_ids set to avoid unbounded growth (keep only the last
        // 2×ENGINE_BATCH ids — enough to cover boundary dedup across two ticks).
        if seen_ids.len() > (ENGINE_BATCH as usize) * 4 {
            seen_ids.clear();
        }
    }
}

// ─── system/health alerts pipeline (P0-HEALTH-NOTIFY) ─────────────────────────

/// Placeholder `camera_id` used as the cooldown-map key for system events that
/// have no associated camera (e.g. `recorder_offline`, `low_disk`). Never
/// written to the DB — purely an in-memory map key.
const NO_CAMERA_COOLDOWN_KEY: Uuid = Uuid::nil();

/// One tick of the system/health events poller: drains new `system_events`
/// rows, evaluates each against its `system_alert_rules` config (enabled,
/// quiet-hours-bypass, cooldown), and fans out over every enabled
/// [`db::NotificationChannel`] via [`channel_notify::dispatch`] — the exact
/// same dispatch function and channel list the camera-event path uses.
///
/// Deliberately does NOT touch push devices: system/health alerts are an
/// admin/operator concern (this is the audience the third-party channels
/// serve — Discord/Slack/ntfy/etc. for a homelab operator), not a per-user
/// mobile-app notification with presence/snooze semantics. Extending to
/// push devices would need its own design (whose presence? whose snooze?)
/// and was out of scope for this pass.
///
/// Respects the SAME global `notifications_enabled` master switch as the
/// camera-event path (re-read fresh each call — cheap, and this poller runs
/// far less often than the 3 s camera-event tick would if it shared the
/// enabled-cache; simplicity over micro-optimization here).
/// Fetch a stored detection snapshot (the `system_events.snapshot_url` set for
/// `plate_watchlist_hit`) so an LPR alert can attach the car+plate image.
///
/// Resolves a provider-relative path against the Frigate HTTP API base from the
/// DB (server settings' `frigate_http_api_base`, then legacy `frigate_api_base`,
/// then the Frigate integration row's `api_base`); an absolute `http(s)://` URL
/// is fetched as-is. Best-effort: any miss (no base configured, non-2xx, network
/// error) returns `None` and the alert simply goes out without an image — never
/// an error. Mirrors the resolution in `events.rs::get_event_snapshot` (minus
/// the env fallback, which this background path can't reach).
async fn fetch_provider_snapshot(
    pool: &Pool,
    http_client: &reqwest::Client,
    snapshot_url: &str,
) -> Option<Vec<u8>> {
    let full_url = if snapshot_url.starts_with("http://") || snapshot_url.starts_with("https://") {
        snapshot_url.to_owned()
    } else {
        let base = match db::get_server_settings(pool).await {
            Ok(Some(s)) if !s.frigate_http_api_base.trim().is_empty() => {
                Some(s.frigate_http_api_base)
            }
            Ok(Some(s)) if !s.frigate_api_base.trim().is_empty() => Some(s.frigate_api_base),
            _ => db::get_frigate_settings(pool)
                .await
                .ok()
                .flatten()
                .map(|f| f.api_base)
                .filter(|v| !v.trim().is_empty()),
        }?;
        format!("{}{}", base.trim_end_matches('/'), snapshot_url)
    };
    match http_client.get(&full_url).send().await {
        Ok(resp) if resp.status().is_success() => resp.bytes().await.ok().map(|b| b.to_vec()),
        Ok(resp) => {
            tracing::debug!(status = %resp.status(), "lpr alert snapshot: provider non-2xx");
            None
        }
        Err(e) => {
            tracing::debug!(error = %e, "lpr alert snapshot: fetch failed");
            None
        }
    }
}

// `pub(crate)` (not private) purely so the RBAC-fan-out integration test can
// drive a single tick directly — it stays crate-internal (no public API
// surface; the api is a binary-only crate).
pub(crate) async fn dispatch_system_events_tick(
    pool: &Pool,
    http_client: &reqwest::Client,
    last_ts: &mut DateTime<Utc>,
    seen_ids: &mut std::collections::HashSet<Uuid>,
    cooldown_map: &mut HashMap<(String, Uuid), Instant>,
    maintenance_until: &std::sync::atomic::AtomicI64,
) {
    let events = match db::system_events_since(pool, *last_ts, ENGINE_BATCH).await {
        Ok(e) => e,
        Err(err) => {
            tracing::warn!(error = %err, "notification engine: system_events_since failed");
            return;
        }
    };
    if events.is_empty() {
        return;
    }
    let new_last = events.last().map_or(*last_ts, |e| e.ts);

    // ── maintenance-window gate (issue #46) ───────────────────────────────────
    //
    // When an admin has armed a maintenance window (`POST /config/maintenance`),
    // operational HEALTH alerts are SUPPRESSED for its duration: the events are
    // still consumed (cursor + seen advance so re-arming doesn't backlog), still
    // visible in `system_events`, but nothing is dispatched to any channel. This
    // is the whole-pipeline gate that stops a planned/normal recorder restart —
    // which legitimately stops writing segments for ~60-90s during go2rtc
    // reconcile — from paging the operator. Mirrors the `notifications_enabled`
    // master-switch contract below.
    let until = maintenance_until.load(std::sync::atomic::Ordering::Relaxed);
    if crate::state::maintenance_active_at(until, Utc::now().timestamp()) {
        for event in &events {
            seen_ids.insert(event.id);
        }
        *last_ts = new_last;
        tracing::info!(
            batch = events.len(),
            maintenance_until = until,
            "notification engine: maintenance window active — health alerts suppressed (consumed, not dispatched)"
        );
        return;
    }

    match db::get_notifications_enabled(pool).await {
        Ok(false) => {
            // Master switch off: consume without dispatching, same contract
            // as the camera-event path.
            for event in &events {
                seen_ids.insert(event.id);
            }
            *last_ts = new_last;
            return;
        }
        Ok(true) => {}
        Err(err) => {
            tracing::warn!(
                error = %err,
                "notification engine: get_notifications_enabled (system path) failed; proceeding as enabled"
            );
        }
    }

    let enabled_channels = match db::list_enabled_channels(pool).await {
        Ok(c) => c,
        Err(err) => {
            tracing::warn!(error = %err, "notification engine: list_enabled_channels (system path) failed");
            Vec::new()
        }
    };

    // ── resolve owner grants for owned channels (P0-5) ────────────────────────
    // System-event fan-out previously checked ONLY the channel's own camera_ids
    // scope, never the owner's role/capabilities — so a low-privilege user's
    // channel could receive a `plate_watchlist_hit` (plate string + crop) with
    // no `view_plates` grant, or a camera-tagged health alert for a camera the
    // owner can't see. Resolve each owner's real grants from the DB and gate on
    // them below. Global channels (user_id = None, admin-managed) are the
    // operator firehose and stay unrestricted.
    let mut owner_grants: HashMap<Uuid, db::UserGrants> = HashMap::new();
    for ch in &enabled_channels {
        if let Some(uid) = ch.user_id {
            if let std::collections::hash_map::Entry::Vacant(e) = owner_grants.entry(uid) {
                match db::resolve_user_grants(pool, uid).await {
                    Ok(Some(g)) => {
                        e.insert(g);
                    }
                    Ok(None) => {}
                    Err(err) => {
                        tracing::warn!(error = %err, user_id = %uid, "notification engine: resolve_user_grants (system path) failed");
                    }
                }
            }
        }
    }

    let rules = match db::list_system_alert_rules(pool).await {
        Ok(r) => r,
        Err(err) => {
            tracing::warn!(error = %err, "notification engine: list_system_alert_rules failed");
            Vec::new()
        }
    };
    let rule_map: HashMap<&str, &db::SystemAlertRule> =
        rules.iter().map(|r| (r.event_key.as_str(), r)).collect();

    let (quiet_start, quiet_end) = match db::get_system_alert_quiet_hours(pool).await {
        Ok(v) => v,
        Err(err) => {
            tracing::warn!(error = %err, "notification engine: get_system_alert_quiet_hours failed");
            (None, None)
        }
    };

    let now = Utc::now();
    let hour = now.with_timezone(&chrono::Local).hour_from_utc_with_local();
    let in_quiet_window =
        matches!((quiet_start, quiet_end), (Some(s), Some(e)) if in_quiet_hours(hour, s, e));

    for event in &events {
        if seen_ids.contains(&event.id) {
            continue;
        }
        seen_ids.insert(event.id);

        let Some(rule) = rule_map.get(event.event_key.as_str()).copied() else {
            // Unknown event_key (e.g. an older/newer binary skew) — log and skip
            // rather than dispatching with no configured gate at all.
            tracing::debug!(event_key = %event.event_key, "system event: no matching rule; skipping");
            continue;
        };
        if !rule.enabled {
            continue;
        }

        // ── quiet hours gate (unless this event bypasses it) ──────────────
        if in_quiet_window && !rule.bypass_quiet_hours {
            tracing::debug!(event_key = %event.event_key, "system event: gate quiet_hours — drop");
            continue;
        }

        // ── cooldown gate (in-memory, keyed by event_key + camera_id) ─────
        //
        // For `plate_watchlist_hit` the plate is folded into the identity
        // (issue #126): keying on `(event_key, camera_id)` alone collapses two
        // DIFFERENT watchlisted plates seen at the same camera within the
        // window — the second BOLO would be silently suppressed. Same plate =>
        // same key => still cooled down (no re-alert spam for one plate);
        // different plate => different key => alerts independently.
        let cooldown_ident = match plate_cooldown_discriminator(event) {
            Some(plate) => format!("{}:{plate}", event.event_key),
            None => event.event_key.clone(),
        };
        let cooldown_key = (
            cooldown_ident,
            event.camera_id.unwrap_or(NO_CAMERA_COOLDOWN_KEY),
        );
        if let Some(&last_pass) = cooldown_map.get(&cooldown_key) {
            if (last_pass.elapsed().as_secs() as i64) < i64::from(rule.cooldown_secs) {
                tracing::debug!(event_key = %event.event_key, "system event: gate cooldown — drop");
                continue;
            }
        }

        if enabled_channels.is_empty() {
            continue;
        }

        // Camera-scoped channels: only deliver a camera-tagged system event
        // (e.g. camera_offline) to channels whose camera_ids scope includes
        // it (empty scope = all cameras, same convention as the camera-event
        // path). System-wide events (camera_id = None) go to every channel
        // regardless of scope — they're not about any one camera.
        let camera_name = match event.camera_id {
            Some(cam_id) => match db::get_camera(pool, cam_id).await {
                Ok(Some(cam)) => Some(cam.name),
                Ok(None) => Some(format!("camera {cam_id}")),
                Err(e) => {
                    tracing::warn!(error = %e, "system event: get_camera failed");
                    Some(format!("camera {cam_id}"))
                }
            },
            None => None,
        };

        let title = system_alert_title(&event.event_key);
        cooldown_map.insert(cooldown_key, Instant::now());

        // LPR watchlist hits carry a detection snapshot (the car+plate frame).
        // Fetch it ONCE if any channel wants images; each channel then attaches
        // it or not per its own `include_snapshot` toggle (the user's on/off).
        let snapshot: Option<Vec<u8>> = match &event.snapshot_url {
            Some(url) if enabled_channels.iter().any(|c| c.include_snapshot) => {
                fetch_provider_snapshot(pool, http_client, url).await
            }
            _ => None,
        };

        for ch in &enabled_channels {
            // ── owner RBAC gate for OWNED channels (P0-5) ─────────────────────
            // Global channels (no owner) skip this — admin-managed firehose.
            if let Some(owner_id) = ch.user_id {
                let grants = owner_grants.get(&owner_id);
                let owner_is_admin = grants.is_some_and(|g| g.is_admin);

                // A plate watchlist hit carries the plate string + crop: only
                // deliver to a channel whose owner holds `view_plates`.
                if event.event_key == "plate_watchlist_hit"
                    && !owner_is_admin
                    && !grants.is_some_and(|g| g.view_plates)
                {
                    continue;
                }

                // A camera-tagged system event requires the owner's camera grant
                // (same intersect rule as the camera-event path). System-wide
                // events (camera_id = None) are not about any one camera and are
                // not camera-gated here.
                if let Some(cam_id) = event.camera_id {
                    let owner_cam_ids: &[Uuid] = grants.map_or(&[], |g| g.camera_ids.as_slice());
                    if !owner_is_admin && !owner_cam_ids.contains(&cam_id) {
                        continue;
                    }
                }
            }

            if let (Some(cam_id), Some(ch_scope)) = (event.camera_id, ch.camera_ids.as_deref()) {
                if !ch_scope.is_empty() && !ch_scope.contains(&cam_id) {
                    continue;
                }
            }

            let msg = ChannelMessage {
                camera_name: camera_name
                    .clone()
                    .unwrap_or_else(|| "Crumb server".to_owned()),
                kind: "system",
                label: Some(title.to_owned()),
                ts: event.ts,
                web_url: None,
                snapshot: if ch.include_snapshot {
                    snapshot.clone()
                } else {
                    None
                },
                detail: event.detail.clone(),
            };

            let (status, reason) = match channel_notify::dispatch(http_client, ch, &msg).await {
                Ok(()) => {
                    tracing::info!(channel_id = %ch.id, event_key = %event.event_key, "system alert dispatched");
                    ("sent", None)
                }
                Err(e) => {
                    tracing::warn!(channel_id = %ch.id, event_key = %event.event_key, error = %e, "system alert dispatch failed");
                    ("failed", Some(e.to_string()))
                }
            };

            if let Err(err) = db::insert_channel_notification_log(
                pool,
                Some(event.id),
                event.camera_id,
                Some(ch.id),
                &event.event_key,
                status,
                reason.as_deref(),
            )
            .await
            {
                tracing::warn!(error = %err, "notification engine: insert_channel_notification_log (system) failed");
            }
        }
    }

    *last_ts = new_last;
    if seen_ids.len() > (ENGINE_BATCH as usize) * 4 {
        seen_ids.clear();
    }
}

/// Human-readable title for a `system_events.event_key`, used as the
/// [`ChannelMessage::label`] for system alerts. Unknown keys (shouldn't
/// happen — `dispatch_system_events_tick` only reaches here for keys with a
/// matching rule) fall back to the raw key.
fn system_alert_title(event_key: &str) -> &str {
    match event_key {
        "recorder_offline" => "Recorder offline",
        "camera_offline" => "Camera offline",
        "premature_rollover" => "Footage evicted early (premature rollover)",
        "low_disk" => "Low disk space",
        "policy_over_cap" => "Recording policy over size cap",
        "backup_failed" => "Database backup failed",
        "frigate_disconnected" => "Frigate/MQTT disconnected",
        "motion_detector_unhealthy" => "Motion detector unhealthy (recording every segment)",
        "motion_cache_unavailable" => "Motion cache unavailable (recording continuously)",
        "storage_persist_failed" => "Storage write failed — footage at risk",
        "stream_no_segments" => "Camera records nothing (no segments — check keyframe interval)",
        "storage_unwritable" => "Recorder can't write to storage — footage NOT being saved",
        "plate_watchlist_hit" => "License-plate watchlist hit",
        other => other,
    }
}

/// Per-plate cooldown discriminator for `plate_watchlist_hit` (issue #126).
///
/// The system event carries no structured plate column, but the ingester writes
/// the normalized plate (uppercase, no interior spaces) as the third
/// whitespace token of the detail (`"watchlisted plate <PLATE> ..."`), so it is
/// recovered by position — robust to the trailing label/confidence text, which
/// varies between reads of the same plate. Returns `None` for any other event
/// key, and (fail-safe) for a detail that doesn't parse: the caller then keys on
/// the plateless identity, i.e. it over-suppresses rather than risks spamming.
fn plate_cooldown_discriminator(event: &db::SystemEvent) -> Option<&str> {
    if event.event_key != "plate_watchlist_hit" {
        return None;
    }
    event.detail.as_deref()?.split_whitespace().nth(2)
}

// ─── helpers ─────────────────────────────────────────────────────────────────

/// Determine a user's effective presence from the already-loaded
/// `devices_with_owners` snapshot.
///
/// Returns `"home"` when ANY device belonging to `owner_id` has
/// `presence = 'home'`; `"away"` otherwise (no devices registered, or all
/// devices away / unknown).
///
/// The fail-safe default (`"away"`) means a channel owner with NO registered
/// devices still receives notifications — the absence of device state does NOT
/// silence alerts.
fn owner_presence_from_devices(
    devices_with_owners: &[(db::PushDevice, UserRole, Vec<Uuid>)],
    owner_id: Uuid,
) -> &'static str {
    let any_home = devices_with_owners
        .iter()
        .filter(|(d, _, _)| d.user_id == owner_id)
        .any(|(d, _, _)| d.presence == "home");
    if any_home {
        "home"
    } else {
        "away"
    }
}

/// Resolve the effective rule for an event: per-camera override → user default → None.
///
/// `None` means "use system defaults".
fn resolve_effective_rule(
    user_rules: &[db::NotificationRule],
    camera_id: Uuid,
) -> Option<&db::NotificationRule> {
    // Per-camera override first.
    if let Some(rule) = user_rules.iter().find(|r| r.camera_id == Some(camera_id)) {
        return Some(rule);
    }
    // User default (camera_id IS NULL).
    user_rules.iter().find(|r| r.camera_id.is_none())
}

/// Return `true` when `hour` falls inside `[quiet_start, quiet_end)`, handling
/// midnight wrap-around (e.g. start=22, end=6 → quiet from 22:00 to 06:00).
fn in_quiet_hours(hour: u32, quiet_start: i32, quiet_end: i32) -> bool {
    let h = hour as i32;
    let s = quiet_start.clamp(0, 23);
    let e = quiet_end.clamp(0, 23);
    if s <= e {
        h >= s && h < e
    } else {
        // Wraps midnight: [s, 24) ∪ [0, e)
        h >= s || h < e
    }
}

/// Extract the current local hour from a `DateTime<Utc>` using the server's
/// local timezone.
trait LocalHour {
    fn hour_from_utc_with_local(&self) -> u32;
}

impl LocalHour for DateTime<chrono::Local> {
    fn hour_from_utc_with_local(&self) -> u32 {
        use chrono::Timelike as _;
        self.hour()
    }
}

// ─── compile-time tests ───────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn sys_event(event_key: &str, detail: Option<&str>) -> db::SystemEvent {
        db::SystemEvent {
            id: Uuid::new_v4(),
            event_key: event_key.to_owned(),
            camera_id: Some(Uuid::new_v4()),
            ts: Utc::now(),
            detail: detail.map(ToOwned::to_owned),
            snapshot_url: None,
        }
    }

    #[test]
    fn plate_discriminator_distinguishes_plates() {
        // Two different plates at the same camera must yield different
        // discriminators (so their cooldown keys differ → both alert).
        let a = sys_event(
            "plate_watchlist_hit",
            Some("watchlisted plate ABC123 seen (confidence 90%)"),
        );
        let b = sys_event(
            "plate_watchlist_hit",
            Some("watchlisted plate XYZ789 (\"BOLO\") seen (confidence 71%)"),
        );
        assert_eq!(plate_cooldown_discriminator(&a), Some("ABC123"));
        assert_eq!(plate_cooldown_discriminator(&b), Some("XYZ789"));
        assert_ne!(
            plate_cooldown_discriminator(&a),
            plate_cooldown_discriminator(&b)
        );
    }

    #[test]
    fn plate_discriminator_stable_across_confidence_refinement() {
        // The SAME plate with a different trailing confidence must yield the
        // SAME discriminator (so the cooldown still suppresses re-alerts).
        let first = sys_event(
            "plate_watchlist_hit",
            Some("watchlisted plate ABC123 seen (confidence 80%)"),
        );
        let refined = sys_event(
            "plate_watchlist_hit",
            Some("watchlisted plate ABC123 seen (confidence 95%)"),
        );
        assert_eq!(
            plate_cooldown_discriminator(&first),
            plate_cooldown_discriminator(&refined)
        );
    }

    #[test]
    fn plate_discriminator_only_for_watchlist_hits() {
        // A non-plate system event never carries a plate discriminator, so its
        // cooldown identity stays the bare event_key.
        let health = sys_event("camera_offline", Some("camera Front Door went offline"));
        assert_eq!(plate_cooldown_discriminator(&health), None);
        // A malformed/empty detail falls back to None (plateless key = safe).
        let malformed = sys_event("plate_watchlist_hit", Some(""));
        assert_eq!(plate_cooldown_discriminator(&malformed), None);
    }

    #[test]
    fn quiet_hours_no_wrap() {
        // 22:00–06:00 style is NOT tested here; this is the simpler 08:00–20:00.
        assert!(in_quiet_hours(10, 8, 20));
        assert!(!in_quiet_hours(7, 8, 20));
        assert!(!in_quiet_hours(20, 8, 20)); // end is exclusive
    }

    #[test]
    fn quiet_hours_midnight_wrap() {
        // 22:00 to 06:00 next day.
        assert!(in_quiet_hours(23, 22, 6));
        assert!(in_quiet_hours(0, 22, 6));
        assert!(in_quiet_hours(5, 22, 6));
        assert!(!in_quiet_hours(6, 22, 6)); // end exclusive
        assert!(!in_quiet_hours(12, 22, 6));
    }

    #[test]
    fn resolve_rule_prefers_per_camera() {
        let cam = Uuid::new_v4();
        let other = Uuid::new_v4();
        let rules = vec![
            db::NotificationRule {
                id: Uuid::new_v4(),
                user_id: Uuid::new_v4(),
                camera_id: None, // default
                presence_mode: "always".to_owned(),
                notify_motion: true,
                notify_detection: true,
                object_labels: None,
                min_score: None,
                min_duration_secs: None,
                quiet_start_hour: None,
                quiet_end_hour: None,
                cooldown_secs: 90,
                created_at: Utc::now(),
                updated_at: Utc::now(),
            },
            db::NotificationRule {
                id: Uuid::new_v4(),
                user_id: Uuid::new_v4(),
                camera_id: Some(cam),
                presence_mode: "off".to_owned(),
                notify_motion: false,
                notify_detection: false,
                object_labels: None,
                min_score: None,
                min_duration_secs: None,
                quiet_start_hour: None,
                quiet_end_hour: None,
                cooldown_secs: 90,
                created_at: Utc::now(),
                updated_at: Utc::now(),
            },
        ];
        // Per-camera rule for `cam` wins.
        let r = resolve_effective_rule(&rules, cam).unwrap();
        assert_eq!(r.presence_mode, "off");

        // Another camera falls through to the default.
        let r2 = resolve_effective_rule(&rules, other).unwrap();
        assert_eq!(r2.presence_mode, "always");
    }

    #[test]
    fn owner_presence_home_if_any_device_home() {
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let make_device = |user_id: Uuid, presence: &str| db::PushDevice {
            id: Uuid::new_v4(),
            user_id,
            install_id: "x".to_owned(),
            platform: "android".to_owned(),
            transport: "websocket".to_owned(),
            push_token: None,
            device_name: None,
            presence: presence.to_owned(),
            presence_source: None,
            presence_updated_at: None,
            last_seen: Utc::now(),
            created_at: Utc::now(),
        };

        // One device away, one home → owner is home.
        let devices: Vec<(db::PushDevice, UserRole, Vec<Uuid>)> = vec![
            (make_device(owner, "away"), UserRole::Admin, vec![]),
            (make_device(owner, "home"), UserRole::Admin, vec![]),
            (make_device(other, "home"), UserRole::Admin, vec![]),
        ];
        assert_eq!(owner_presence_from_devices(&devices, owner), "home");

        // All devices away → owner is away.
        let devices2: Vec<(db::PushDevice, UserRole, Vec<Uuid>)> =
            vec![(make_device(owner, "away"), UserRole::Admin, vec![])];
        assert_eq!(owner_presence_from_devices(&devices2, owner), "away");

        // No devices registered → away (fail-safe).
        let devices3: Vec<(db::PushDevice, UserRole, Vec<Uuid>)> = vec![];
        assert_eq!(owner_presence_from_devices(&devices3, owner), "away");
    }
}
