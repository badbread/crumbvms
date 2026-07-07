// SPDX-License-Identifier: AGPL-3.0-or-later

//! Per-client token-bucket rate limiting.
//!
//! A dependency-free limiter: a `DashMap` of token buckets keyed by client IP.
//!
//! ## Key selection (#17 — spoofable XFF fix)
//!
//! By default the key is the **TCP peer socket IP** — the address the kernel
//! accepted the connection from. This is unforgeable (an attacker cannot change
//! their TCP peer address) and correct for direct-to-Docker or LAN deployments.
//!
//! When the service sits behind a trusted reverse proxy (Nginx, Caddy, Traefik,
//! etc.) that strips/rewrites `X-Forwarded-For`, set:
//!
//! ```text
//! TRUST_PROXY=1
//! ```
//!
//! With `TRUST_PROXY` set the limiter reads the **first** `X-Forwarded-For` hop
//! instead, which is the real client IP as seen by the proxy.  Only enable this
//! when you control the proxy — a public-facing deployment without a stripping
//! proxy leaves XFF spoofable, defeating per-IP throttling entirely.
//!
//! `TRUST_PROXY` is read **once at startup** (via [`trust_proxy_from_env`]) and
//! baked into [`RateLimiter`]; there is no runtime reload.
//!
//! Applied as an axum layer over the JSON routes only (auth/timeline/status/
//! config/views/ptz) — NOT over media/segment serving, which is high-frequency
//! by nature during playback. The generous default (burst 240, ~4 req/s refill)
//! never bothers a normal operator but caps a runaway/abusive client. Rate-
//! limited responses return `429 Too Many Requests`.
//!
//! NOTE: the bucket map is not pruned; at homelab IP cardinality this is
//! negligible. Add a periodic sweep if ever exposed to the open internet.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use axum::{
    extract::{ConnectInfo, Request, State},
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use dashmap::DashMap;
use serde_json::json;

/// Read whether the `TRUST_PROXY` env var is set (any non-empty value enables
/// it).  Call once at startup and pass the result to [`RateLimiter::new`].
///
/// # Design note
///
/// Reading at startup rather than per-request avoids a `std::env::var` call in
/// the hot path and makes the policy explicit and observable in logs.
pub fn trust_proxy_from_env() -> bool {
    std::env::var("TRUST_PROXY").is_ok_and(|v| !v.trim().is_empty())
}

/// Shared token-bucket rate limiter.
pub struct RateLimiter {
    buckets: DashMap<String, Bucket>,
    /// Max tokens (burst capacity).
    capacity: f64,
    /// Tokens replenished per second (sustained rate).
    refill_per_sec: f64,
    /// Whether to trust `X-Forwarded-For` for the client key.
    ///
    /// `false` (default) → always use the TCP peer IP.
    /// `true` → use the first XFF hop when present, fall back to peer IP.
    trust_proxy: bool,
}

struct Bucket {
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    /// Create a shared limiter.
    ///
    /// - `capacity` = burst size (requests).
    /// - `refill_per_sec` = sustained requests/second per client.
    /// - `trust_proxy` = whether to key on `X-Forwarded-For` (see module doc).
    ///   Pass [`trust_proxy_from_env()`] to honour the `TRUST_PROXY` env var.
    pub fn new(capacity: u32, refill_per_sec: f64) -> Arc<Self> {
        let trust_proxy = trust_proxy_from_env();
        if trust_proxy {
            tracing::info!("rate limiter: TRUST_PROXY=1 — keying on X-Forwarded-For (first hop)");
        } else {
            tracing::info!("rate limiter: keying on TCP peer IP (TRUST_PROXY not set)");
        }
        Arc::new(Self {
            buckets: DashMap::new(),
            capacity: f64::from(capacity),
            refill_per_sec,
            trust_proxy,
        })
    }

    /// Consume one token for `key`. Returns `true` if allowed, `false` if the
    /// bucket is empty. Fully synchronous (no await while the entry is locked).
    fn check(&self, key: &str) -> bool {
        let now = Instant::now();
        let mut bucket = self.buckets.entry(key.to_owned()).or_insert(Bucket {
            tokens: self.capacity,
            last: now,
        });
        let elapsed = now.duration_since(bucket.last).as_secs_f64();
        bucket.last = now;
        bucket.tokens = (bucket.tokens + elapsed * self.refill_per_sec).min(self.capacity);
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

/// axum middleware (used via `from_fn_with_state`). Rejects with 429 when the
/// client's bucket is exhausted.
///
/// The client key is:
/// - **TCP peer IP** (default, `TRUST_PROXY` not set) — unforgeable.
/// - **First `X-Forwarded-For` hop** (`TRUST_PROXY=1`) — real client IP when a
///   stripping proxy sits in front; spoofable without one.
pub async fn rate_limit_mw(
    State(limiter): State<Arc<RateLimiter>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let key = if limiter.trust_proxy {
        // Trust mode: try to read the real client IP from XFF.
        req.headers()
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.split(',').next())
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| peer.ip().to_string())
    } else {
        // Default (no proxy trust): use the TCP peer address directly.
        peer.ip().to_string()
    };

    if limiter.check(&key) {
        next.run(req).await
    } else {
        tracing::warn!(client = %key, "rate limit exceeded — returning 429");
        (
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({
                "error": "Too Many Requests",
                "message": "rate limit exceeded; slow down"
            })),
        )
            .into_response()
    }
}
