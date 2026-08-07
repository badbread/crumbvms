// SPDX-License-Identifier: AGPL-3.0-or-later

//! CORS policy for the HTTP API, and the router composition that scopes it.
//!
//! # Why CORS exists here at all
//!
//! None of Crumb's own front ends need it. The desktop (Flutter/libmpv),
//! Android and iOS clients are native HTTP callers, and the web admin console
//! is served by this same API at `/admin`, so its `fetch()` calls are
//! same-origin. The permissive layer is retained only so that an operator's own
//! LAN page or script can talk to their own server without a proxy — a
//! convenience, never a requirement.
//!
//! # Why `/auth` is carved out
//!
//! `Access-Control-Allow-Origin: *` on the `/auth` subtree lets **any** page a
//! browser happens to load script the operator's server across origins. Two
//! concrete consequences on an otherwise-correctly-deployed install:
//!
//! * `POST /auth/bootstrap` is unauthenticated by design (first-run admin
//!   creation). Wildcard CORS means a page in a different tab can reach a
//!   freshly-installed, not-yet-bootstrapped server and create the first admin
//!   before the operator does.
//! * `POST /auth/login` becomes a cross-origin credential-guessing oracle: the
//!   attacking page can read each response body rather than being blind to it,
//!   which is the difference between a usable attack and a useless one.
//!
//! Removing the header does not restore any capability an attacker had to
//! *earn*; it just puts the browser's same-origin policy back in front of the
//! credential surface. Nothing Crumb ships calls `/auth` cross-origin, so there
//! is no compatibility cost. (Whether the remaining routes need the permissive
//! layer at all is a separate, wider question — see `docs/DECISIONS.md`.)

use axum::Router;
use tower_http::cors::{Any, CorsLayer};

use crate::state::AppState;

/// The permissive CORS layer applied to the non-`/auth` API surface.
pub fn permissive() -> CorsLayer {
    CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any)
}

/// Compose the API router so CORS covers `cors_scoped` but **not** `no_cors`.
///
/// This relies on axum's documented `Router::layer` semantics: a layer applies
/// only to the routes registered *before* the `.layer()` call, so anything
/// merged afterwards is deliberately outside it. Keeping that subtlety in one
/// named function (rather than inline in `main.rs`) is what makes the carve-out
/// directly testable — a future refactor that merges `/auth` in the wrong order
/// silently re-adds the wildcard, and the test in
/// `services/api/tests/auth_rbac.rs` is what catches it.
///
/// Pass the `/auth` subtree as `no_cors`. Layers that should cover *everything*
/// (tracing, and the shared JSON rate-limit/timeout/compression stack, which is
/// applied to each subtree before it gets here) go outside this call.
pub fn compose(cors_scoped: Router<AppState>, no_cors: Router<AppState>) -> Router<AppState> {
    cors_scoped.layer(permissive()).merge(no_cors)
}
