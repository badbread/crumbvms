// SPDX-License-Identifier: AGPL-3.0-or-later

//! Authentication routes — login, bootstrap, and session management.
//!
//! # Route layout
//!
//! These routes are **nested at `/auth`** by `main.rs`, so the effective paths
//! are:
//!
//! | Method   | Path                       | Auth        | Description                              |
//! |----------|----------------------------|-------------|------------------------------------------|
//! | `GET`    | `/auth/needs-bootstrap`    | none        | True iff zero admin users                |
//! | `POST`   | `/auth/bootstrap`          | none        | Create first admin; 409 if one exists    |
//! | `POST`   | `/auth/login`              | none        | Verify credentials; issue JWT            |
//! | `POST`   | `/auth/refresh`            | Bearer      | Re-issue a fresh token for a valid one   |
//! | `GET`    | `/auth/me`                 | Bearer      | Return the caller's own profile          |
//!
//! User management (create / update / delete / list users) lives exclusively at
//! `/config/users` in `config_routes.rs`, which enforces the last-admin guard.
//! The former `/auth/users/*` routes have been removed — they lacked the guard
//! and could re-open the unauthenticated `/auth/bootstrap` window.
//!
//! # Security invariants
//!
//! * `password_hash` is **never** included in any response body.
//! * Password verification uses [`argon2::Argon2::verify_password`] — no
//!   constant-time string compare.
//! * Tokens are HMAC-SHA256 signed with `state.jwt_encoding_key()`.
//! * Token expiry is enforced by both the [`crate::auth_mw::AuthUser`] extractor
//!   (on every protected request) and the `exp` claim validated here on refresh.
//!
//! # Bootstrap
//!
//! To create the first admin user without an existing token, set these env vars
//! before starting the API (or the recorder's `seed` subcommand, which shares
//! the same vars):
//!
//! ```text
//! SEED_ADMIN_USERNAME=admin
//! SEED_ADMIN_PASSWORD=changeme
//! ```
//!
//! At startup (`main.rs`) the API can optionally call `seed_admin_if_absent`
//! to upsert the initial admin; once a real admin exists the env vars are
//! ignored.  Alternatively, insert the hash directly via psql:
//!
//! ```sql
//! INSERT INTO users (username, password_hash, role, camera_ids)
//! VALUES ('admin', '<argon2-phc-string>', 'admin', '[]');
//! ```

use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use chrono::Utc;
use jsonwebtoken::{encode, Header};
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

use crumb_common::{
    db,
    types::{Session, User, UserRole},
};

use crate::{
    auth_mw::{AdminUser, AuthUser, MEDIA_TOKEN_TYP},
    dto::{
        Claims, LoginRequest, LoginResponse, MeResponse, MediaClaims, MediaTokenResponse,
        SessionDto,
    },
    error::ApiError,
    state::AppState,
};

/// Lifetime of a scoped media token. Must exceed the longest *continuous
/// single-URL* media playback, because unlike recorded segments (each ~4s clip
/// re-mints a fresh URL) a clip is one URL played straight through — a token
/// shorter than the clip 401s mid-playback. 15 min covers realistic event
/// clips with margin. It stays a low-value leak target regardless: the token is
/// scoped to ONE camera and media-only (no PTZ / config / broad export), so a
/// leak into an access log grants at most "view one camera's media for a few
/// minutes", vs the full (up to 10-year, all-camera) login JWT it replaces in
/// URLs. Clients read the real expiry from the response `expires_at`. See
/// [`MediaClaims`] / P0-SESSIONS.
const MEDIA_TOKEN_EXPIRY_SECONDS: i64 = 900;

// ── helpers ───────────────────────────────────────────────────────────────────

/// Hash a plain-text password with Argon2id using a random salt.
///
/// Returns the PHC-encoded string suitable for storing in `users.password_hash`.
///
/// The salt is derived from a random UUID v4, which uses the OS CSPRNG
/// (`getrandom`) internally — the same entropy source as
/// `SaltString::generate` — without requiring a direct `rand_core` dependency.
///
/// # Errors
///
/// Returns [`ApiError::Internal`] if hashing fails (extremely unlikely in
/// practice).
fn hash_password(password: &str) -> Result<String, ApiError> {
    // `Uuid::new_v4()` uses getrandom under the hood (uuid/v4 feature).
    // `encode_b64` produces a valid `SaltString` from the 16 raw bytes.
    let salt_bytes = *Uuid::new_v4().as_bytes();
    let salt =
        SaltString::encode_b64(&salt_bytes).expect("16-byte UUID is always a valid SaltString");
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("argon2 hash failed: {e}")))
}

/// Verify a plain-text password against a stored PHC hash string.
///
/// Returns `true` if the password matches.  Always returns `false` (never
/// errors) on a malformed stored hash — the caller maps `false` to 401.
fn verify_password(password: &str, hash_str: &str) -> bool {
    let Ok(parsed_hash) = PasswordHash::new(hash_str) else {
        tracing::warn!("stored password_hash could not be parsed as PHC string");
        return false;
    };
    Argon2::default()
        .verify_password(password.as_bytes(), &parsed_hash)
        .is_ok()
}

/// A "keep me signed in" token's lifetime: ~10 years. The mobile app opts into
/// this so the session effectively never expires (the user's explicit choice for
/// the save-login feature). Tradeoff: such a token can't be revoked before it
/// expires (the auth extractor validates the signature + `exp` only, with no
/// per-request DB lookup), so revoking a user only takes effect on their next
/// *fresh* login. Acceptable for the single-tenant homelab deployment.
const REMEMBER_EXPIRY_SECONDS: u64 = 3_650 * 24 * 3_600;

/// Build and sign a JWT for `user_id` / `role` / `camera_ids`, and record a
/// revocable [session](crumb_common::types::Session) for it.
///
/// Expiry is `now + jwt_expiry_seconds` from the config, unless `long_lived` is
/// set (the mobile "keep me signed in" path), in which case it is
/// [`REMEMBER_EXPIRY_SECONDS`] (~10 years).
///
/// Every minted token carries a fresh `jti` (session id) and a matching row in
/// `sessions`, so the token can be revoked before it expires (P0-SESSIONS). If
/// the session INSERT fails the mint fails (fail-closed): an un-revocable token
/// is exactly the pre-P0-SESSIONS hazard this task removes, so we do not hand
/// one out silently.
///
/// `label`/`ip` are advisory device metadata for the "your sessions" UI.
///
/// # Errors
///
/// Returns [`ApiError::Internal`] if `jsonwebtoken::encode` or the session
/// INSERT fails.
async fn mint_token(
    state: &AppState,
    user: &User,
    long_lived: bool,
    label: Option<&str>,
    ip: Option<&str>,
) -> Result<LoginResponse, ApiError> {
    let now = Utc::now();
    let expiry_secs = if long_lived {
        REMEMBER_EXPIRY_SECONDS
    } else {
        state.config().jwt_expiry_seconds
    };
    let exp = now
        .checked_add_signed(chrono::Duration::seconds(
            i64::try_from(expiry_secs).unwrap_or(86_400),
        ))
        .unwrap_or(now);

    let exp_unix = u64::try_from(exp.timestamp()).unwrap_or(0);
    let iat_unix = u64::try_from(now.timestamp()).unwrap_or(0);

    // Fresh session id for this token — ties it to a revocable `sessions` row.
    let jti = Uuid::new_v4();

    // Viewers carry their camera list in the token so the extractor can scope
    // requests without a DB round-trip.  Admins get an empty list (see
    // AuthUser::can_access_camera — admin bypasses the list check).
    let camera_ids: Vec<String> = user
        .camera_ids
        .iter()
        .map(std::string::ToString::to_string)
        .collect();

    let claims = Claims {
        sub: user.id.to_string(),
        exp: exp_unix,
        iat: iat_unix,
        role: user.role.as_str().to_owned(),
        camera_ids,
        role_id: user.role_id.map(|r| r.to_string()),
        jti: Some(jti.to_string()),
    };

    let token = encode(&Header::default(), &claims, state.jwt_encoding_key())
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("jwt encode failed: {e}")))?;

    // Record the session BEFORE returning the token. Fail-closed on error.
    db::create_session(state.pool(), jti, user.id, label, ip, long_lived, exp)
        .await
        .map_err(ApiError::Internal)?;

    Ok(LoginResponse {
        token,
        expires_at: exp,
    })
}

/// Best-effort device label from the request's `User-Agent` (truncated), for
/// the "your sessions" UI. Advisory only; never trusted for auth.
fn device_label(headers: &axum::http::HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.chars().take(200).collect::<String>())
        .filter(|s| !s.is_empty())
}

/// Best-effort client IP for the session record. Prefers `X-Forwarded-For`'s
/// first hop (behind the documented reverse proxy) then falls back to nothing —
/// the raw socket peer isn't available here without the `ConnectInfo` extension,
/// and this field is advisory, so absence is acceptable.
fn client_ip(headers: &axum::http::HeaderMap) -> Option<String> {
    headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.split(',').next())
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
}

// ── first-run bootstrap ───────────────────────────────────────────────────────

/// Request body for `POST /auth/bootstrap`.
///
/// Kept private to this module — other modules must not reference it.
/// (api-routes owns `dto.rs`; we avoid touching that file.)
#[derive(Debug, Deserialize)]
struct BootstrapRequest {
    username: String,
    password: String,
}

/// `GET /auth/needs-bootstrap`
///
/// Returns `{"needs_bootstrap": true}` when the database has zero admin users,
/// indicating the first-run create-admin form should be shown.  No authentication
/// required — the page itself is public; the sensitive action is `POST /auth/bootstrap`.
///
/// # Errors
///
/// - `500` — database error.
async fn needs_bootstrap(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let users = db::list_users(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    let any_admin = users.iter().any(|u| matches!(u.role, UserRole::Admin));
    Ok(Json(json!({ "needs_bootstrap": !any_admin })))
}

/// `GET /auth/setup-status`
///
/// Richer first-run probe for the setup wizard. Returns whether an admin still
/// needs creating, whether the guided setup has been finished, and address
/// suggestions derived from the `Host` the operator reached the console on (so
/// the wizard can pre-fill the server/RTSP base — the one thing nobody knows to
/// set). Unauthenticated, like `/auth/needs-bootstrap`: none of this is sensitive
/// and the page needs it before login.
///
/// # Errors
///
/// - `500` — database error.
async fn setup_status(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    let users = db::list_users(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    let any_admin = users.iter().any(|u| matches!(u.role, UserRole::Admin));
    let setup_complete = db::get_setup_complete(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    // Beta-terms gate: "accepted" means accepted at the CURRENT terms version, so
    // a materially-changed terms document re-shows the wizard's opening gate.
    let (bt_accepted, bt_version) = db::get_beta_terms_status(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    let beta_terms_accepted = bt_accepted && bt_version == crate::config_routes::BETA_TERMS_VERSION;

    // Suggest reachable addresses from the Host header the browser used. For the
    // common "stranger hits http://<box-ip>:8080" case this is exactly right; an
    // operator behind a proxy can edit it. RTSP base drops the console port and
    // uses the recorder's published 18554.
    let host = headers
        .get(axum::http::header::HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("")
        .trim()
        .to_owned();
    let hostname = host.split(':').next().unwrap_or("").to_owned();
    let (suggested_address, suggested_rtsp_base) = if host.is_empty() {
        (String::new(), String::new())
    } else if hostname.is_empty() {
        (format!("http://{host}"), String::new())
    } else {
        (format!("http://{host}"), format!("rtsp://{hostname}:18554"))
    };

    // A likely camera subnet to pre-fill the discovery scan. The API can't see the
    // camera LAN from inside the Docker bridge, but the browser reached the console
    // on that LAN, so the Host the request came in on is the best guess: take its
    // IPv4 literal and widen to a /24. A hostname (e.g. `crumb.local`) has no /24,
    // so we leave it `null` and the operator types the range.
    let suggested_scan_range = suggested_scan_range(&hostname);

    Ok(Json(json!({
        "needs_bootstrap": !any_admin,
        "setup_complete": setup_complete,
        "beta_terms_accepted": beta_terms_accepted,
        "suggested_address": suggested_address,
        "suggested_rtsp_base": suggested_rtsp_base,
        "suggested_scan_range": suggested_scan_range,
    })))
}

/// Derive a `<a.b.c>.0/24` scan-range guess from a Host-header hostname.
///
/// Returns `Some("a.b.c.0/24")` only when `hostname` is a dotted-quad IPv4 literal
/// (the common "operator hit `http://<box-ip>:8080`" case). Anything that isn't a
/// bare IPv4 address — a DNS name, an IPv6 literal, an empty string — yields `None`,
/// because there is no well-defined /24 to suggest and the operator will type it.
fn suggested_scan_range(hostname: &str) -> Option<String> {
    // Only a bare IPv4 literal has a meaningful /24; `Ipv4Addr` rejects names,
    // IPv6, ports, and malformed input for us.
    let ip: std::net::Ipv4Addr = hostname.parse().ok()?;
    let [a, b, c, _] = ip.octets();
    Some(format!("{a}.{b}.{c}.0/24"))
}

/// `POST /auth/bootstrap`
///
/// Creates the very first administrator account when none exists yet.  Mints
/// and returns a token so the caller can proceed directly into the admin UI
/// without a separate login step.
///
/// Returns `201 Created` + `LoginResponse` on success, `409 Conflict` once any
/// admin already exists.  **No authentication required** — the endpoint refuses
/// at 409 as soon as one admin is present, so subsequent requests are harmless.
///
/// # Errors
///
/// - `400` — username empty or password shorter than 8 characters.
/// - `409` — an administrator already exists.
/// - `500` — database or hashing error.
async fn bootstrap_admin(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(body): Json<BootstrapRequest>,
) -> Result<(StatusCode, Json<LoginResponse>), ApiError> {
    // ── input validation ──────────────────────────────────────────────────────
    let username = body.username.trim().to_owned();
    if username.is_empty() {
        return Err(ApiError::BadRequest("username is required".to_owned()));
    }
    // Mirror the config_routes::validate_password rule (≥ 8 chars) inline so
    // we don't cross module boundaries (config_routes.rs is owned by api-routes).
    if body.password.len() < 8 {
        return Err(ApiError::BadRequest(
            "password must be at least 8 characters".to_owned(),
        ));
    }

    // ── guard: refuse if any admin already exists ─────────────────────────────
    let users = db::list_users(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    if users.iter().any(|u| matches!(u.role, UserRole::Admin)) {
        return Err(ApiError::Conflict(
            "an administrator already exists".to_owned(),
        ));
    }

    // ── hash + persist ────────────────────────────────────────────────────────
    let hash = hash_password(&body.password)?;
    // Assign the built-in Administrator role (seeded by migration 0028).
    let admin_role_id = db::get_admin_role_id(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    let user = db::create_user(
        state.pool(),
        &username,
        &hash,
        UserRole::Admin,
        &[],
        admin_role_id,
    )
    .await
    .map_err(|e| {
        let msg = e.to_string();
        if msg.contains("23505") || msg.contains("unique") || msg.contains("duplicate") {
            // Extremely unlikely race: another request bootstrapped in parallel.
            ApiError::Conflict("an administrator already exists".to_owned())
        } else {
            ApiError::Internal(e)
        }
    })?;

    tracing::info!(
        user_id  = %user.id,
        username = %user.username,
        "first-run bootstrap: initial admin created"
    );

    let resp = mint_token(
        &state,
        &user,
        false,
        device_label(&headers).as_deref(),
        client_ip(&headers).as_deref(),
    )
    .await?;
    Ok((StatusCode::CREATED, Json(resp)))
}

/// Mount authentication and session routes onto a sub-router.
///
/// `main.rs` nests this under `/auth`.
///
/// User management (create / update / delete / list users) lives at
/// `/config/users` in `config_routes.rs`, which enforces the last-admin guard.
pub fn routes() -> Router<AppState> {
    Router::new()
        // ── first-run bootstrap (no auth required) ────────────────────────
        .route("/needs-bootstrap", get(needs_bootstrap))
        .route("/setup-status", get(setup_status))
        .route("/bootstrap", post(bootstrap_admin))
        // ── session ───────────────────────────────────────────────────────
        .route("/login", post(login))
        .route("/refresh", post(refresh))
        .route("/me", get(me))
        // ── revocable sessions (P0-SESSIONS) ───────────────────────────────
        // List my own sessions; revoke one of mine; sign out ALL my devices.
        .route("/sessions", get(list_my_sessions))
        .route(
            "/sessions/all",
            axum::routing::delete(revoke_all_my_sessions),
        )
        .route("/sessions/:jti", axum::routing::delete(revoke_my_session))
        // Admin: sign out every device of an arbitrary user (e.g. a stolen
        // phone reported by a household member).
        .route(
            "/users/:id/sessions",
            axum::routing::delete(admin_revoke_user_sessions),
        )
}

// ── scoped media tokens (P0-SESSIONS) ──────────────────────────────────────────

/// Mount the scoped-media-token route at the TOP level (not under `/auth`), so
/// the effective path is `GET /media-token`. `main.rs` merges this into the
/// JSON routes. Kept separate from [`routes`] (which nests under `/auth`) only
/// so the path matches the P0-SESSIONS spec exactly.
pub fn media_token_routes() -> Router<AppState> {
    Router::new().route("/media-token", get(media_token))
}

/// Query for `GET /media-token?camera=<uuid>`.
#[derive(Debug, Deserialize)]
struct MediaTokenQuery {
    camera: Uuid,
}

/// `GET /media-token?camera=<uuid>`
///
/// Mint a **scoped, short-lived media token** for the given camera. The caller
/// must be authenticated (full bearer JWT) AND have access to that camera; the
/// returned token is then used ONLY as `?token=` on the media endpoints
/// (segment / live / clip / filmstrip / snapshot / export download) for that one
/// camera, for ~15 min. This replaces putting the full (possibly 10-year) JWT in a
/// URL where it would leak into proxy / access logs.
///
/// # Errors
///
/// - `401` — not authenticated.
/// - `403` — the caller cannot access `camera`.
/// - `500` — signing error.
async fn media_token(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<MediaTokenQuery>,
) -> Result<Json<MediaTokenResponse>, ApiError> {
    // Enforce the SAME per-camera scope the media routes enforce — the point is
    // to hand out a token no broader than what the caller could already reach.
    user.assert_camera_access(q.camera)?;

    let now = Utc::now();
    let exp = now
        .checked_add_signed(chrono::Duration::seconds(MEDIA_TOKEN_EXPIRY_SECONDS))
        .unwrap_or(now);
    let claims = MediaClaims {
        sub: user.user_id.to_string(),
        typ: MEDIA_TOKEN_TYP.to_owned(),
        cam: q.camera.to_string(),
        exp: u64::try_from(exp.timestamp()).unwrap_or(0),
        iat: u64::try_from(now.timestamp()).unwrap_or(0),
    };
    let token = encode(&Header::default(), &claims, state.jwt_encoding_key())
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("media-token encode failed: {e}")))?;

    Ok(Json(MediaTokenResponse {
        token,
        camera_id: q.camera,
        expires_at: exp,
    }))
}

// ── session management handlers (P0-SESSIONS) ──────────────────────────────────

fn session_to_dto(s: Session, current: Option<Uuid>) -> SessionDto {
    let is_current = current == Some(s.jti);
    SessionDto {
        jti: s.jti,
        label: s.label,
        ip: s.ip,
        long_lived: s.long_lived,
        created_at: s.created_at,
        last_seen_at: s.last_seen_at,
        expires_at: s.expires_at,
        revoked_at: s.revoked_at,
        is_current,
    }
}

/// `GET /auth/sessions` — list the caller's own sessions (newest first), with
/// the one the request is using flagged `is_current`.
async fn list_my_sessions(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<SessionDto>>, ApiError> {
    let sessions = db::list_sessions_for_user(state.pool(), user.user_id)
        .await
        .map_err(ApiError::Internal)?;
    let dtos = sessions
        .into_iter()
        .map(|s| session_to_dto(s, user.jti))
        .collect();
    Ok(Json(dtos))
}

/// `DELETE /auth/sessions/:jti` — revoke ONE of the caller's own sessions. The
/// DB update is scoped to `user_id`, so a caller can never revoke someone
/// else's session by guessing a jti. 404 if it isn't theirs / doesn't exist.
async fn revoke_my_session(
    user: AuthUser,
    State(state): State<AppState>,
    Path(jti): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let n = db::revoke_session(state.pool(), jti, Some(user.user_id))
        .await
        .map_err(ApiError::Internal)?;
    // Refresh the in-process cache so the revoke takes effect immediately here.
    state.refresh_revoked_jtis().await;
    if n == 0 {
        return Err(ApiError::NotFound(format!(
            "session {jti} not found (or not yours)"
        )));
    }
    tracing::info!(user_id = %user.user_id, %jti, "session revoked (self)");
    Ok(StatusCode::NO_CONTENT)
}

/// `DELETE /auth/sessions/all` — sign the caller out of ALL devices (revokes
/// every one of their sessions, including the current request's).
async fn revoke_all_my_sessions(
    user: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let n = db::revoke_all_sessions_for_user(state.pool(), user.user_id)
        .await
        .map_err(ApiError::Internal)?;
    state.refresh_revoked_jtis().await;
    tracing::info!(user_id = %user.user_id, revoked = n, "all sessions revoked (self)");
    Ok(Json(json!({ "revoked": n })))
}

/// `DELETE /auth/users/:id/sessions` — ADMIN: sign a given user out of all
/// devices (e.g. a reported stolen phone). Admin-gated by [`AdminUser`].
async fn admin_revoke_user_sessions(
    _admin: AdminUser,
    State(state): State<AppState>,
    Path(user_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let n = db::revoke_all_sessions_for_user(state.pool(), user_id)
        .await
        .map_err(ApiError::Internal)?;
    state.refresh_revoked_jtis().await;
    tracing::info!(%user_id, revoked = n, "all sessions revoked (admin)");
    Ok(Json(json!({ "revoked": n })))
}

// ── /auth/login ───────────────────────────────────────────────────────────────

/// `POST /auth/login`
///
/// Accepts `{ "username": "…", "password": "…" }`, verifies the Argon2id hash,
/// and returns a signed JWT on success.
///
/// # Errors
///
/// - `401` — user not found or password incorrect (same message, no oracle).
/// - `400` — username or password is empty.
/// - `500` — database or internal error.
async fn login(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    Json(body): Json<LoginRequest>,
) -> Result<Json<LoginResponse>, ApiError> {
    // ── input validation ──────────────────────────────────────────────────────
    if body.username.trim().is_empty() {
        return Err(ApiError::BadRequest("username is required".to_owned()));
    }
    if body.password.is_empty() {
        return Err(ApiError::BadRequest("password is required".to_owned()));
    }

    // ── fetch user row ────────────────────────────────────────────────────────
    let user = db::get_user_by_username(state.pool(), body.username.trim())
        .await
        .map_err(ApiError::Internal)?;

    // Constant-time: always run verify_password even when user is absent so the
    // response time does not reveal whether the username exists.
    let (valid, user) = if let Some(u) = user {
        let ok = verify_password(&body.password, &u.password_hash);
        (ok, Some(u))
    } else {
        // Run a dummy verify to burn similar time.
        let _ = verify_password(&body.password, "$argon2id$v=19$m=19456,t=2,p=1$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        (false, None)
    };

    if !valid {
        return Err(ApiError::Unauthorized(
            "invalid username or password".to_owned(),
        ));
    }

    // `user` is Some(_) iff `valid` is true — unwrap is safe here.
    let user = user.expect("user is Some when valid");

    tracing::info!(
        user_id = %user.id,
        username = %user.username,
        role     = %user.role.as_str(),
        "login successful"
    );

    mint_token(
        &state,
        &user,
        body.remember,
        device_label(&headers).as_deref(),
        client_ip(&headers).as_deref(),
    )
    .await
    .map(Json)
}

// ── /auth/refresh ─────────────────────────────────────────────────────────────

/// `POST /auth/refresh`
///
/// Accepts a valid (non-expired) Bearer token and returns a new token with a
/// fresh expiry.  The new token re-fetches the user row so revoked users (or
/// role / camera changes) take effect on the next refresh.
///
/// # Errors
///
/// - `401` — token missing, invalid, or expired.
/// - `404` — user UUID in the token no longer exists in the DB.
/// - `500` — database or internal error.
async fn refresh(
    user: AuthUser,
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
) -> Result<Json<LoginResponse>, ApiError> {
    // Re-fetch the user from the DB so any role / camera_ids changes are
    // reflected in the new token immediately.
    let db_user = db::get_user_by_id(state.pool(), user.user_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("user {} not found", user.user_id)))?;

    tracing::debug!(
        user_id  = %db_user.id,
        username = %db_user.username,
        "token refreshed"
    );

    // A refresh issues a normal-expiry token; the long-lived "remember" path is
    // login-only (the mobile app holds its long-lived token and never refreshes).
    let resp = mint_token(
        &state,
        &db_user,
        false,
        device_label(&headers).as_deref(),
        client_ip(&headers).as_deref(),
    )
    .await?;

    // Session rotation: revoke the OLD session the refresh authenticated with so
    // the just-superseded token can't be reused. Best-effort — the new token is
    // already minted; a failed revoke here leaves the old session valid until
    // its exp (no worse than pre-P0-SESSIONS), so we log rather than fail.
    if let Some(old_jti) = user.jti {
        match db::revoke_session(state.pool(), old_jti, Some(db_user.id)).await {
            Ok(_) => state.refresh_revoked_jtis().await,
            Err(e) => tracing::warn!("refresh: failed to revoke prior session {old_jti}: {e}"),
        }
    }

    Ok(Json(resp))
}

// ── /auth/me ──────────────────────────────────────────────────────────────────

/// `GET /auth/me`
///
/// Returns the authenticated user's profile. Re-fetches from DB so the response
/// always reflects the current state (role, camera assignments).
///
/// # Errors
///
/// - `401` — no/invalid/expired Bearer token.
/// - `404` — user has been deleted since the token was issued.
/// - `500` — database error.
async fn me(user: AuthUser, State(state): State<AppState>) -> Result<Json<MeResponse>, ApiError> {
    let db_user = db::get_user_by_id(state.pool(), user.user_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("user {} not found", user.user_id)))?;

    // Effective role/capabilities/cameras come from the AuthUser extractor (resolved
    // from the assigned role); username comes from the fresh DB row.
    Ok(Json(MeResponse {
        id: db_user.id,
        username: db_user.username,
        role: user.role,
        is_admin: user.is_admin(),
        capabilities: user.capabilities.clone(),
        camera_ids: user.camera_ids.clone(),
        role_id: user.role_id,
    }))
}

// ── bootstrap helper ──────────────────────────────────────────────────────────

/// Seed an initial admin user if no admin exists yet.
///
/// Called from `main.rs` at startup when `SEED_ADMIN_USERNAME` and
/// `SEED_ADMIN_PASSWORD` are set in the environment.  The function is
/// idempotent — if any admin already exists it does nothing.
///
/// # Errors
///
/// Returns an error only if the DB query or hashing fails.  A duplicate
/// username is silently ignored (treated as "already seeded").
pub async fn seed_admin_if_absent(
    pool: &deadpool_postgres::Pool,
    username: &str,
    password: &str,
) -> anyhow::Result<()> {
    if username.is_empty() || password.is_empty() {
        tracing::debug!("SEED_ADMIN_USERNAME or SEED_ADMIN_PASSWORD not set; skipping seed");
        return Ok(());
    }

    // Check whether any admin user already exists.
    let all_users = db::list_users(pool).await?;
    let any_admin = all_users.iter().any(|u| matches!(u.role, UserRole::Admin));
    if any_admin {
        tracing::debug!("admin user already exists; skipping seed");
        return Ok(());
    }

    let salt_bytes = *Uuid::new_v4().as_bytes();
    let salt =
        SaltString::encode_b64(&salt_bytes).expect("16-byte UUID is always a valid SaltString");
    let hash = Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!("seed: argon2 hash failed: {e}"))?
        .to_string();

    let admin_role_id = db::get_admin_role_id(pool).await?;
    match db::create_user(pool, username, &hash, UserRole::Admin, &[], admin_role_id).await {
        Ok(u) => {
            tracing::info!(
                user_id  = %u.id,
                username = %u.username,
                "seeded initial admin user"
            );
        }
        Err(e) => {
            let msg = e.to_string();
            if msg.contains("23505") || msg.contains("unique") || msg.contains("duplicate") {
                // Race between multiple replicas at startup — harmless.
                tracing::warn!("seed: username '{}' already exists; skipping", username);
            } else {
                return Err(e);
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::suggested_scan_range;

    #[test]
    fn scan_range_from_ipv4_widens_to_slash_24() {
        assert_eq!(
            suggested_scan_range("192.168.1.50"),
            Some("192.168.1.0/24".to_owned())
        );
        assert_eq!(
            suggested_scan_range("192.0.2.6"),
            Some("192.0.2.0/24".to_owned())
        );
        // Zeroes the last octet even when the source host is already `.0`.
        assert_eq!(
            suggested_scan_range("192.168.4.0"),
            Some("192.168.4.0/24".to_owned())
        );
    }

    #[test]
    fn scan_range_none_for_non_ipv4_hosts() {
        // DNS names have no /24 to derive.
        assert_eq!(suggested_scan_range("crumb.local"), None);
        assert_eq!(suggested_scan_range("localhost"), None);
        // Empty (missing Host header) → nothing to suggest.
        assert_eq!(suggested_scan_range(""), None);
        // IPv6 literals are not IPv4 /24 subnets.
        assert_eq!(suggested_scan_range("::1"), None);
        assert_eq!(suggested_scan_range("fe80::1"), None);
        // Malformed / out-of-range dotted quads are rejected by the parser.
        assert_eq!(suggested_scan_range("999.1.1.1"), None);
        assert_eq!(suggested_scan_range("192.168.1"), None);
    }
}
