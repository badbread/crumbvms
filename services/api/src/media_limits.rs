// SPDX-License-Identifier: AGPL-3.0-or-later

//! Bounds for the media router: work-semaphore waits and the per-client request
//! budget.
//!
//! # Why
//!
//! The media routes (segment serving, filmstrip frames, clip renditions, live
//! stills, export downloads) each gate their expensive work behind a shared
//! [`tokio::sync::Semaphore`]. Those acquires used to be plain
//! `acquire_owned().await`, i.e. an **unbounded** queue: at saturation a request
//! parked forever holding its connection, never answering, and one busy client
//! could keep every other viewer waiting with no signal at all.
//!
//! [`acquire_bounded`] makes every such acquire time-limited. A caller that does
//! not get a permit inside its budget gets `503 Service Unavailable` plus a
//! `Retry-After` hint, so the client backs off and the connection is released.
//! Answering "busy, try again" is strictly better than an open-ended hang: the
//! clients already treat a failed media fetch as "show the placeholder and poll
//! again", which is exactly the desired behaviour under load.
//!
//! # Choosing a wait budget
//!
//! The budget is per call site, sized against how long the guarded work itself
//! takes:
//!
//! | Budget | Guarded work | Reasoning |
//! |--------|--------------|-----------|
//! | [`CLIP_GEN_WAIT`] (15 s) | clip / low-bitrate transcode, clip thumbnail | The transcode itself is capped at 120 s but in practice runs in seconds (a segment is ~4 s of video, a clip window <= 30 s). 15 s absorbs a full queue ahead of us without pinning a connection for the transcode cap. |
//! | [`THUMB_EXTRACT_WAIT`] (5 s) | single-frame filmstrip ffmpeg | Each extraction is one frame (typically well under a second, hard cap 12 s). Scrubbing fires bursts of dozens, and the useful answer is fast-or-nothing: a scrub thumbnail that arrives after 5 s is already off screen. |
//! | [`FRAME_PROXY_WAIT`] (5 s) | live JPEG still proxied from go2rtc | Low-bandwidth walls poll each tile about once a second, so a wait longer than a poll interval only builds a backlog. |
//!
//! # Per-client request budget
//!
//! [`MEDIA_RATE_BURST`] / [`MEDIA_RATE_REFILL_PER_SEC`] size the media router's
//! own token bucket (a second, much larger bucket than the JSON routes'). See
//! those constants for the arithmetic against real client polling behaviour.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use crate::error::ApiError;

// ─── work-semaphore wait budgets ──────────────────────────────────────────────

/// Wait budget for the clip-generation semaphore (clip renditions, low-bitrate
/// segment variants, clip thumbnails). See the module table.
pub const CLIP_GEN_WAIT: Duration = Duration::from_secs(15);

/// Wait budget for the thumbnail-extraction semaphore (filmstrip frames).
pub const THUMB_EXTRACT_WAIT: Duration = Duration::from_secs(5);

/// Wait budget for the live-still proxy semaphore (`/cameras/:id/frame.jpg`).
pub const FRAME_PROXY_WAIT: Duration = Duration::from_secs(5);

/// `Retry-After` seconds sent with the 503. Short: the queue that turned this
/// caller away drains in seconds, and the clients poll on their own cadence
/// anyway.
const RETRY_AFTER_SECS: u64 = 2;

// ─── per-client media request budget ──────────────────────────────────────────

/// Burst capacity of the media router's per-client token bucket.
///
/// The heaviest legitimate burst a single client produces is timeline
/// scrubbing, which fires filmstrip frame requests dozens at a time (call it
/// 60 for a wide scrub across a full strip). 1200 absorbs twenty such bursts
/// back to back before a single request is refused.
pub const MEDIA_RATE_BURST: u32 = 1200;

/// Sustained refill of the media router's per-client token bucket, in requests
/// per second.
///
/// Arithmetic against the real clients:
///
/// * Android low-bandwidth wall: 16 tiles polling `frame.jpg` at 1 Hz = 16 req/s
///   (its adaptive backoff only ever lowers that, to 1 per 5 s per tile).
/// * iOS low-bandwidth tiles: 16 tiles at one per 1.2 s = about 13 req/s; the
///   WebRTC backdrop poll is 16 tiles at one per 2 s = 8 req/s.
/// * Segment playback opens a handful of `/segments/:id` and
///   `/segments/:id/low.mp4` requests per seek.
///
/// A client doing all of that at once sits around 30 to 40 req/s. 240 leaves
/// roughly a 6x margin, so it never touches a real operator (even several
/// devices sharing one address behind a proxy that does not set
/// `X-Forwarded-For`), while still stopping a runaway loop, which produces
/// thousands per second, well before it can queue meaningful work.
pub const MEDIA_RATE_REFILL_PER_SEC: f64 = 240.0;

/// Time-to-first-byte budget for the media router.
///
/// `tower_http`'s `TimeoutLayer` bounds only the handler future, not the
/// response body (body timeouts are a separate `ResponseBodyTimeoutLayer`), so
/// this cannot cut a long segment download, an export archive, or an open-ended
/// live `stream.mp4`: those all return their headers immediately and stream
/// afterwards. What it does bound is the media routes that *produce* something
/// before answering, the longest being an on-demand clip or low-bitrate
/// transcode: 120 s of ffmpeg plus a 15 s [`CLIP_GEN_WAIT`]. Three minutes
/// clears that with slack and still guarantees every media request terminates.
pub const MEDIA_RESPONSE_TIMEOUT: Duration = Duration::from_mins(3);

// ─── bounded acquire ──────────────────────────────────────────────────────────

/// Acquire a permit from `sem`, giving up after `wait`.
///
/// `what` names the resource in the log line and the client-visible message
/// (e.g. `"clip transcode"`). On timeout this returns
/// [`ApiError::ServiceUnavailableRetry`], which renders 503 with a `Retry-After`
/// header; the caller must simply `?` it and let the request end.
///
/// A closed semaphore is impossible in practice (nothing calls `close()`), so it
/// maps to a 500 exactly as the plain acquires it replaces did.
pub async fn acquire_bounded(
    sem: &Arc<Semaphore>,
    wait: Duration,
    what: &str,
) -> Result<OwnedSemaphorePermit, ApiError> {
    match tokio::time::timeout(wait, Arc::clone(sem).acquire_owned()).await {
        Ok(Ok(permit)) => Ok(permit),
        Ok(Err(e)) => Err(ApiError::Internal(anyhow::anyhow!(
            "{what} semaphore closed: {e}"
        ))),
        Err(_) => {
            tracing::warn!(
                resource = what,
                wait_secs = wait.as_secs(),
                "media work queue saturated, returning 503"
            );
            Err(ApiError::ServiceUnavailableRetry {
                message: format!("{what} queue is saturated; retry shortly"),
                retry_after: RETRY_AFTER_SECS,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{acquire_bounded, ApiError};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::Semaphore;

    #[tokio::test]
    async fn saturated_semaphore_yields_503_within_the_budget() {
        // Zero permits: nothing can ever be acquired, so this MUST come back as
        // the 503 path rather than parking forever (the whole point of the
        // bounded acquire).
        let sem = Arc::new(Semaphore::new(0));
        let started = std::time::Instant::now();
        let err = acquire_bounded(&sem, Duration::from_millis(120), "test work")
            .await
            .expect_err("a zero-permit semaphore can never hand out a permit");

        match err {
            ApiError::ServiceUnavailableRetry {
                ref message,
                retry_after,
            } => {
                assert!(
                    message.contains("test work"),
                    "message should name the resource: {message}"
                );
                assert!(retry_after >= 1, "a Retry-After hint must be sent");
            }
            other => panic!("expected ServiceUnavailableRetry, got {other:?}"),
        }
        assert_eq!(err.status(), axum::http::StatusCode::SERVICE_UNAVAILABLE);
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "the acquire must give up at its budget, not queue forever"
        );
    }

    #[tokio::test]
    async fn free_semaphore_hands_out_a_permit_immediately() {
        let sem = Arc::new(Semaphore::new(1));
        let permit = acquire_bounded(&sem, Duration::from_secs(5), "test work")
            .await
            .expect("a free semaphore must hand out a permit");
        assert_eq!(sem.available_permits(), 0);
        drop(permit);
        assert_eq!(sem.available_permits(), 1);
    }
}
