// SPDX-License-Identifier: AGPL-3.0-or-later

//! Unified API error type.
//!
//! [`ApiError`] is the *only* error type returned from route handlers.  It
//! implements [`axum::response::IntoResponse`] so axum can convert it directly
//! into an HTTP response with the correct status code and a JSON body of the
//! form:
//!
//! ```json
//! { "error": "Not Found", "message": "camera abc not found" }
//! ```
//!
//! Internal (`anyhow::Error`) errors are mapped to 500 and the detail is
//! written to the tracing log rather than the response body, preventing
//! accidental information disclosure.

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use thiserror::Error;

/// All errors a handler can return.
///
/// Variants map 1-to-1 to HTTP status codes.  Prefer the most specific variant
/// over `Internal` when the failure is a client error.
#[derive(Debug, Error)]
pub enum ApiError {
    // ── 400 ──────────────────────────────────────────────────────────────────
    /// Malformed or semantically invalid request.
    #[error("bad request: {0}")]
    BadRequest(String),

    // ── 401 ──────────────────────────────────────────────────────────────────
    /// Missing or invalid `Authorization` header / JWT.
    #[error("unauthorized: {0}")]
    Unauthorized(String),

    // ── 403 ──────────────────────────────────────────────────────────────────
    /// Authenticated but not permitted (wrong role or camera not in scope).
    #[error("forbidden: {0}")]
    Forbidden(String),

    // ── 404 ──────────────────────────────────────────────────────────────────
    /// The requested resource does not exist.
    #[error("not found: {0}")]
    NotFound(String),

    // ── 409 ──────────────────────────────────────────────────────────────────
    /// Conflict, e.g. duplicate username on user creation.
    #[error("conflict: {0}")]
    Conflict(String),

    // ── 422 ──────────────────────────────────────────────────────────────────
    /// Request body failed validation (after successful deserialization).
    #[error("unprocessable entity: {0}")]
    UnprocessableEntity(String),

    // ── 429 ──────────────────────────────────────────────────────────────────
    /// Rate limit hit, or a bounded resource (e.g. concurrent exports) is full.
    #[error("too many requests: {0}")]
    TooManyRequests(String),

    /// Rate limit hit with an explicit client backoff hint: renders 429 plus a
    /// `Retry-After: <secs>` header (issue #127, the per-username login
    /// brute-force backoff).
    #[error("too many requests: {message}")]
    TooManyRequestsRetry { message: String, retry_after: u64 },

    // ── 500 ──────────────────────────────────────────────────────────────────
    /// Unexpected internal error.  Detail is logged but NOT sent to the client.
    #[error("internal server error")]
    Internal(#[source] anyhow::Error),

    // ── 502 ──────────────────────────────────────────────────────────────────
    /// An upstream dependency (e.g. go2rtc, behind the live MSE proxy) was
    /// unreachable or returned an error.  Detail is logged at `warn!` (not
    /// `error!`) so a flapping/restarting upstream does not spam error logs or
    /// trip 5xx-based alerting; the client sees a generic message.
    #[error("bad gateway: {0}")]
    BadGateway(String),
}

impl ApiError {
    /// HTTP status code for this error variant.
    pub fn status(&self) -> StatusCode {
        match self {
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            Self::Forbidden(_) => StatusCode::FORBIDDEN,
            Self::NotFound(_) => StatusCode::NOT_FOUND,
            Self::Conflict(_) => StatusCode::CONFLICT,
            Self::UnprocessableEntity(_) => StatusCode::UNPROCESSABLE_ENTITY,
            Self::TooManyRequests(_) | Self::TooManyRequestsRetry { .. } => {
                StatusCode::TOO_MANY_REQUESTS
            }
            Self::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
            Self::BadGateway(_) => StatusCode::BAD_GATEWAY,
        }
    }

    /// Short machine-readable label (the `"error"` JSON field).
    fn label(&self) -> &'static str {
        match self {
            Self::BadRequest(_) => "Bad Request",
            Self::Unauthorized(_) => "Unauthorized",
            Self::Forbidden(_) => "Forbidden",
            Self::NotFound(_) => "Not Found",
            Self::Conflict(_) => "Conflict",
            Self::UnprocessableEntity(_) => "Unprocessable Entity",
            Self::TooManyRequests(_) | Self::TooManyRequestsRetry { .. } => "Too Many Requests",
            Self::Internal(_) => "Internal Server Error",
            Self::BadGateway(_) => "Bad Gateway",
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = self.status();

        let label = self.label();

        // Internal + BadGateway: log the detail, return a generic message (no
        // internal detail/URL disclosure). BadGateway logs at warn! so a
        // flapping upstream doesn't masquerade as a server fault or trip alerts.
        let message = match &self {
            Self::Internal(e) => {
                tracing::error!(error = ?e, "internal server error");
                "an unexpected error occurred".to_owned()
            }
            Self::BadGateway(detail) => {
                tracing::warn!(detail = %detail, "upstream gateway error");
                "upstream unavailable".to_owned()
            }
            other => {
                // Extract the human message from the Display impl.
                // The Display output is "bad request: <detail>" — strip the prefix.
                let display = other.to_string();
                display
                    .split_once(": ")
                    .map(|(_, msg)| msg.to_owned())
                    .unwrap_or(display)
            }
        };

        let body = Json(json!({
            "error":   label,
            "message": message,
        }));

        let mut response = (status, body).into_response();

        // 429 backoff hint: attach `Retry-After: <secs>` so a well-behaved
        // client (or the login UI) knows how long to wait (issue #127).
        if let Self::TooManyRequestsRetry { retry_after, .. } = &self {
            if let Ok(val) = axum::http::HeaderValue::from_str(&retry_after.to_string()) {
                response
                    .headers_mut()
                    .insert(axum::http::header::RETRY_AFTER, val);
            }
        }

        response
    }
}

// ── convenience conversions ───────────────────────────────────────────────────

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        Self::Internal(e)
    }
}
