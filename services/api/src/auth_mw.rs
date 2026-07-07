// SPDX-License-Identifier: AGPL-3.0-or-later

//! JWT bearer authentication extractors.
//!
//! Two extractors are provided:
//!
//! * [`AuthUser`] — any authenticated user (admin **or** viewer).  Includes
//!   the resolved camera scope so handlers can enforce per-camera access.
//! * [`AdminUser`] — wraps [`AuthUser`] and fails with 403 if the caller is
//!   not an admin.  Use on any config / management endpoint.
//!
//! # Wire format
//!
//! Clients send `Authorization: Bearer <jwt>`.  The JWT is HMAC-SHA256 signed
//! with `JWT_SECRET`.  Claims are decoded from [`crate::dto::Claims`].
//!
//! # Example
//!
//! ```rust,no_run
//! use axum::extract::State;
//! use crumb_api::auth_mw::{AuthUser, AdminUser};
//! use crumb_api::state::AppState;
//! use crumb_api::error::ApiError;
//!
//! async fn viewer_handler(user: AuthUser) -> Result<String, ApiError> {
//!     Ok(format!("hello {}", user.user_id))
//! }
//!
//! async fn admin_handler(admin: AdminUser) -> Result<String, ApiError> {
//!     Ok(format!("admin: {}", admin.0.user_id))
//! }
//! ```

use axum::{
    async_trait,
    extract::FromRequestParts,
    http::{header::AUTHORIZATION, request::Parts},
};
use jsonwebtoken::{decode, Algorithm, Validation};
use uuid::Uuid;

use crumb_common::types::{BookmarkScope, Capabilities, UserRole};

use crate::{
    dto::{Claims, MediaClaims},
    error::ApiError,
    state::AppState,
};

/// The `typ` value stamped on scoped media tokens (see [`MediaClaims`]). Guards
/// against a media token being replayed on a JSON API route and vice-versa.
pub const MEDIA_TOKEN_TYP: &str = "media";

// ─── AuthUser ─────────────────────────────────────────────────────────────────

/// The authenticated principal extracted from a valid JWT bearer token.
///
/// Available in handler signatures as `user: AuthUser`.
///
/// # Camera scope enforcement
///
/// Viewers can only see cameras listed in [`AuthUser::camera_ids`].  Admin
/// users have `camera_ids = []`; handlers must treat an empty list + `Admin`
/// role as "all cameras allowed."
///
/// Use [`AuthUser::can_access_camera`] for the canonical check.
#[derive(Debug, Clone)]
pub struct AuthUser {
    /// UUID of the authenticated user (`users.id`).
    pub user_id: Uuid,
    /// Effective role — `Admin` when the assigned role `is_admin`, else `Viewer`.
    /// Drives the `AdminUser` config-endpoint gate.
    pub role: UserRole,
    /// Camera UUIDs this user may access (resolved from the assigned role; empty
    /// for admins, who bypass the check).
    pub camera_ids: Vec<Uuid>,
    /// Effective capabilities resolved from the assigned role (admin ⇒ all).
    /// Read by Phase-2 capability enforcement (export/playback/clips/ptz/bookmarks).
    pub capabilities: Capabilities,
    /// Assigned permission-role id, if any (surfaced to clients via `/auth/me`).
    pub role_id: Option<Uuid>,
    /// Session id (`jti`) this request authenticated with, if the token carried
    /// one (P0-SESSIONS). `None` for legacy pre-session tokens and for scoped
    /// media tokens. Lets `/auth/refresh` rotate and `/auth/sessions` mark the
    /// current session without re-parsing the JWT.
    pub jti: Option<Uuid>,
}

impl AuthUser {
    /// Whether this principal is an administrator (bypasses all checks).
    #[inline]
    pub fn is_admin(&self) -> bool {
        matches!(self.role, UserRole::Admin)
    }

    /// Return `true` if this user is allowed to access `camera_id`.
    ///
    /// Admins always return `true`.  Viewers must have the ID in their
    /// `camera_ids` list.
    #[inline]
    pub fn can_access_camera(&self, camera_id: Uuid) -> bool {
        self.is_admin() || self.camera_ids.contains(&camera_id)
    }

    /// Assert camera access or return 403.
    pub fn assert_camera_access(&self, camera_id: Uuid) -> Result<(), ApiError> {
        if self.can_access_camera(camera_id) {
            Ok(())
        } else {
            Err(ApiError::Forbidden(format!(
                "camera {camera_id} is not in your assigned camera list"
            )))
        }
    }

    /// Filter a list of camera UUIDs to only those this user can access.
    ///
    /// For admins, returns the input unchanged.  For viewers, returns the
    /// intersection of `ids` with `camera_ids`.
    pub fn filter_camera_ids(&self, ids: &[Uuid]) -> Vec<Uuid> {
        if self.is_admin() {
            ids.to_vec()
        } else {
            ids.iter()
                .copied()
                .filter(|id| self.camera_ids.contains(id))
                .collect()
        }
    }

    // ── capability checks (admins always pass) ────────────────────────────────
    #[inline]
    pub fn can_export(&self) -> bool {
        self.is_admin() || self.capabilities.export
    }
    #[inline]
    pub fn can_playback(&self) -> bool {
        self.is_admin() || self.capabilities.playback
    }
    #[inline]
    pub fn can_clips(&self) -> bool {
        self.is_admin() || self.capabilities.clips
    }
    #[inline]
    pub fn can_ptz(&self) -> bool {
        self.is_admin() || self.capabilities.ptz
    }
    #[inline]
    pub fn can_manage_views(&self) -> bool {
        self.is_admin() || self.capabilities.manage_views
    }
    /// Effective bookmark visibility (admins see all).
    #[inline]
    pub fn bookmarks_scope(&self) -> BookmarkScope {
        if self.is_admin() {
            BookmarkScope::All
        } else {
            self.capabilities.bookmarks
        }
    }

    /// 403 unless `ok`; `what` names the denied capability for the message.
    fn require(ok: bool, what: &str) -> Result<(), ApiError> {
        if ok {
            Ok(())
        } else {
            Err(ApiError::Forbidden(format!(
                "your role does not permit {what}"
            )))
        }
    }
    pub fn require_export(&self) -> Result<(), ApiError> {
        Self::require(self.can_export(), "exporting footage")
    }
    pub fn require_playback(&self) -> Result<(), ApiError> {
        Self::require(self.can_playback(), "recorded playback")
    }
    pub fn require_clips(&self) -> Result<(), ApiError> {
        Self::require(self.can_clips(), "viewing clips")
    }
    pub fn require_ptz(&self) -> Result<(), ApiError> {
        Self::require(self.can_ptz(), "PTZ control")
    }
}

/// Conservative capabilities for a token that carries no resolvable role
/// (legacy pre-RBAC tokens, or a role deleted mid-session). Admins get
/// everything; viewers keep basic view/playback but no privileged actions.
fn fallback_caps(role: UserRole) -> Capabilities {
    match role {
        UserRole::Admin => Capabilities::all(),
        UserRole::Viewer => Capabilities {
            export: false,
            playback: true,
            clips: true,
            ptz: false,
            bookmarks: BookmarkScope::Own,
            manage_views: true,
        },
    }
}

impl AuthUser {
    /// Shared authentication core for the [`AuthUser`] (fail-closed) and
    /// [`ExportDownloadUser`] (permissive) extractors.
    ///
    /// `allow_full_jwt_via_query` is the fail-closed boundary (audit
    /// 2026-07-05 #2): a full login JWT presented via `?token=` puts a login
    /// credential in a URL (proxy/access logs, browser history), so it is
    /// REJECTED by default and accepted only on the multi-camera export
    /// download routes (via [`ExportDownloadUser`]) until they move to a scoped
    /// export token / `Authorization` header. A valid scoped media token via
    /// `?token=` is always accepted, regardless of this flag.
    async fn authenticate(
        parts: &mut Parts,
        state: &AppState,
        allow_full_jwt_via_query: bool,
    ) -> Result<AuthUser, ApiError> {
        // ── 1. extract the token: prefer Authorization: Bearer, else ?token= ──
        // The query-param fallback lets browser <video>/<img>/<a download>
        // elements — which cannot set an Authorization header — authenticate to
        // the media endpoints (/segments, /filmstrip, /export download).
        //
        // `from_query` distinguishes the two sources: a token arriving via
        // `?token=` MAY be a scoped, short-lived media token (P0-SESSIONS), which
        // we accept below and turn into a single-camera principal. A token in the
        // Authorization header is always a full bearer JWT.
        let (token, from_query): (String, bool) = match parts
            .headers
            .get(AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
        {
            Some(h) => (
                h.strip_prefix("Bearer ")
                    .ok_or_else(|| {
                        ApiError::Unauthorized(
                            "Authorization header must use Bearer scheme".to_owned(),
                        )
                    })?
                    .to_owned(),
                false,
            ),
            None => (
                token_from_query(parts.uri.query())
                    .ok_or_else(|| ApiError::Unauthorized("missing bearer token".to_owned()))?,
                true,
            ),
        };

        // ── 1b. scoped media-token fast path (P0-SESSIONS) ────────────────
        // Only from `?token=` (a media token has no place in an API Bearer
        // header). If the token is a valid media token we build a principal
        // scoped to exactly its one camera and return — the media handlers'
        // existing `assert_camera_access` then permits only that camera. A
        // full JWT arriving via `?token=` (legacy media clients) still works:
        // media-token decode fails and we fall through to the full-JWT path.
        if from_query {
            if let Some(user) = try_media_token(&token, state) {
                return Ok(user);
            }
            // ── fail-closed boundary (audit 2026-07-05 #2) ────────────────
            // The token arrived via ?token= but is NOT a scoped media token, so
            // it is a full login JWT (or garbage). A login credential in a URL
            // query can leak into proxy/access logs and browser history. Reject
            // it on every route EXCEPT the export download routes, which opt in
            // via `ExportDownloadUser` until they move to a scoped export token.
            if !allow_full_jwt_via_query {
                return Err(ApiError::Unauthorized(
                    "a login token in a ?token= query parameter is not accepted on this route; \
                     mint a scoped media token (GET /media-token) or use an Authorization: \
                     Bearer header"
                        .to_owned(),
                ));
            }
        }

        // ── 2. decode + verify signature and expiry ───────────────────────
        let mut validation = Validation::new(Algorithm::HS256);
        validation.validate_exp = true;

        let token_data = decode::<Claims>(&token, state.jwt_decoding_key(), &validation)
            .map_err(|e| ApiError::Unauthorized(format!("invalid or expired token: {e}")))?;

        let claims = token_data.claims;

        // ── 2a. legacy full-JWT-via-?token= (permissive routes only) ──────
        // Only reachable when `allow_full_jwt_via_query` is true — the
        // fail-closed check above already rejected a full-JWT-via-?token= on
        // every other route. `debug!` (not `warn!`) because one permissive
        // caller — the web-console camera snapshot — polls frequently and would
        // flood the logs; the permissive routes are explicit + documented (see
        // [`LegacyQueryTokenUser`]), and an *unknown* caller gets the loud 401
        // from the branch above.
        if from_query {
            tracing::debug!(
                sub = %claims.sub,
                "full login JWT accepted via ?token= on a legacy permissive route — migrate \
                 this caller to a scoped media token or an Authorization: Bearer header \
                 (audit 2026-07-05 #2)"
            );
        }

        // ── 2b. revocation check (P0-SESSIONS) ────────────────────────────
        // A token carrying a `jti` is a revocable session (minted at/after
        // P0-SESSIONS). If that jti has been revoked ("sign out this / all
        // devices", or an admin cutting a stolen phone), reject it now even
        // though the signature + exp are still valid. Legacy tokens without a
        // jti are not revocable and pass unchanged (see the migration's
        // back-compat note; an owner-opt-in flag can tighten this later).
        let jti: Option<Uuid> = match claims.jti.as_deref() {
            Some(jti_str) => {
                let jti = jti_str.parse::<Uuid>().map_err(|_| {
                    ApiError::Unauthorized("token jti is not a valid UUID".to_owned())
                })?;
                if state.is_jti_revoked(jti).await {
                    return Err(ApiError::Unauthorized(
                        "this session has been signed out".to_owned(),
                    ));
                }
                Some(jti)
            }
            None => None,
        };

        // ── 3. parse sub → user_id ────────────────────────────────────────
        let user_id = claims
            .sub
            .parse::<Uuid>()
            .map_err(|_| ApiError::Unauthorized("token sub is not a valid UUID".to_owned()))?;

        // ── 4. parse the legacy role + camera scope from the token ─────────
        let legacy_role = UserRole::from_str(&claims.role).ok_or_else(|| {
            ApiError::Unauthorized(format!("unknown role '{}' in token", claims.role))
        })?;
        let legacy_camera_ids = claims
            .camera_ids
            .iter()
            .map(|s| {
                s.parse::<Uuid>().map_err(|_| {
                    ApiError::Unauthorized(format!("camera_id '{s}' in token is not a valid UUID"))
                })
            })
            .collect::<Result<Vec<Uuid>, ApiError>>()?;

        // ── 5. parse role_id (RBAC) ───────────────────────────────────────
        let role_id = claims
            .role_id
            .as_deref()
            .map(|s| {
                s.parse::<Uuid>().map_err(|_| {
                    ApiError::Unauthorized(format!("role_id '{s}' in token is not a valid UUID"))
                })
            })
            .transpose()?;

        // ── 6. resolve effective role → caps + cameras ────────────────────
        // Prefer the assigned role (source of truth, resolved through the cached
        // roles map so admin edits apply immediately). Fall back to the token's
        // legacy scope with conservative caps when there's no role_id (pre-RBAC
        // token) or the role was deleted out from under a live token.
        let (role, camera_ids, capabilities) = match role_id {
            Some(rid) => match state.role_by_id(rid).await {
                Some(r) => {
                    let eff_role = if r.is_admin {
                        UserRole::Admin
                    } else {
                        UserRole::Viewer
                    };
                    let cams = if r.is_admin {
                        Vec::new()
                    } else {
                        // Effective cameras = the role's cameras UNION the user's own
                        // per-user assignment (carried in the token's camera_ids), so a
                        // viewer can be granted extra cameras without a bespoke role.
                        let mut c = r.camera_ids.clone();
                        for id in &legacy_camera_ids {
                            if !c.contains(id) {
                                c.push(*id);
                            }
                        }
                        c
                    };
                    (eff_role, cams, r.effective_caps())
                }
                None => (legacy_role, legacy_camera_ids, fallback_caps(legacy_role)),
            },
            None => (legacy_role, legacy_camera_ids, fallback_caps(legacy_role)),
        };

        Ok(AuthUser {
            user_id,
            role,
            camera_ids,
            capabilities,
            role_id,
            jti,
        })
    }
}

#[async_trait]
impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        // Fail-closed (audit 2026-07-05 #2): a full login JWT via ?token= is
        // rejected here. Scoped media tokens via ?token= and bearer headers work.
        AuthUser::authenticate(parts, state, false).await
    }
}

/// Auth extractor for the export **download** routes, which still accept a full
/// login JWT via `?token=` pending an export-scoped token.
///
/// Identical to [`AuthUser`] except it does NOT fail-close the
/// full-JWT-via-`?token=` path. Only the export downloads use it (audit
/// 2026-07-05 #2): a multi-camera archive has no single-camera scoped media
/// token, and a browser `<a download>` link can't set an `Authorization` header.
/// (The web-console camera snapshot was migrated to a scoped media token, so
/// `/cameras/:id/frame.jpg` is now the fail-closed [`AuthUser`].)
///
/// Every OTHER media route (segments, playback, filmstrip, clips, camera
/// snapshot) rejects the full-JWT-via-`?token=` path. Do not widen this
/// extractor's use without migrating the corresponding client first.
pub struct LegacyQueryTokenUser(pub AuthUser);

#[async_trait]
impl FromRequestParts<AppState> for LegacyQueryTokenUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        Ok(LegacyQueryTokenUser(
            AuthUser::authenticate(parts, state, true).await?,
        ))
    }
}

// ─── AdminUser ────────────────────────────────────────────────────────────────

/// Extractor that requires the caller to have the `admin` role.
///
/// Fails with 403 (not 401) when the token is valid but the user is a viewer.
/// Fails with 401 when no token is present or the token is invalid.
///
/// Access the inner [`AuthUser`] via the tuple-struct field `admin.0`.
// The inner user is exposed for handlers that need it; many only use `AdminUser`
// as an auth gate and never read `.0`, so silence dead_code on the field.
#[derive(Debug, Clone)]
pub struct AdminUser(#[allow(dead_code)] pub AuthUser);

#[async_trait]
impl FromRequestParts<AppState> for AdminUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let user = AuthUser::from_request_parts(parts, state).await?;

        if matches!(user.role, UserRole::Admin) {
            Ok(AdminUser(user))
        } else {
            Err(ApiError::Forbidden(
                "this endpoint requires the admin role".to_owned(),
            ))
        }
    }
}

/// Try to interpret `token` as a scoped, short-lived media token (P0-SESSIONS).
///
/// Returns a single-camera [`AuthUser`] on success, or `None` if the token is
/// not a valid media token (wrong signature/expiry, or not `typ: "media"`) — in
/// which case the caller falls through to the full-JWT path.
///
/// The returned principal is deliberately scoped to exactly the token's one
/// camera (`camera_ids = [cam]`) with a `Viewer` role and full media
/// capabilities: the capability gate was already enforced when the token was
/// minted (the minting user proved camera access), and confining the principal
/// to a single camera means even a granted capability can only ever touch that
/// one camera's media. `user_id` is carried through for audit/log correlation.
fn try_media_token(token: &str, state: &AppState) -> Option<AuthUser> {
    let mut validation = Validation::new(Algorithm::HS256);
    validation.validate_exp = true;
    // A media token has none of the registered claims Validation checks by
    // default besides exp; disable aud/iss checks explicitly (we set none).
    validation.required_spec_claims.clear();

    let data = decode::<MediaClaims>(token, state.jwt_decoding_key(), &validation).ok()?;
    let claims = data.claims;
    if claims.typ != MEDIA_TOKEN_TYP {
        return None;
    }
    let user_id = claims.sub.parse::<Uuid>().ok()?;
    let cam = claims.cam.parse::<Uuid>().ok()?;

    Some(AuthUser {
        user_id,
        role: UserRole::Viewer,
        camera_ids: vec![cam],
        // Full media caps, but hard-scoped to the single camera above.
        capabilities: Capabilities {
            export: true,
            playback: true,
            clips: true,
            ptz: false,
            bookmarks: BookmarkScope::None,
            manage_views: false,
        },
        role_id: None,
        // A media token is not a revocable session; it self-expires in ~15 min.
        jti: None,
    })
}

/// Extract a `token` value from a URL query string (e.g. `w=320&token=xyz`).
///
/// Fallback for browser elements (`<video>` / `<img>` / `<a download>`) that
/// cannot set an Authorization header. JWT characters are URL-safe, so no
/// percent-decoding is required.
fn token_from_query(query: Option<&str>) -> Option<String> {
    let q = query?;
    for pair in q.split('&') {
        if let Some(v) = pair.strip_prefix("token=") {
            if !v.is_empty() {
                return Some(v.to_owned());
            }
        }
    }
    None
}
