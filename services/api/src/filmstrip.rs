// SPDX-License-Identifier: AGPL-3.0-or-later

//! Filmstrip / thumbnail scrub routes.
//!
//! # Endpoints
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `GET`  | `/filmstrip/{camera_id}` | Bearer | List of thumbnail frame URLs for a time range |
//! | `GET`  | `/filmstrip/{camera_id}/frame` | Bearer | Serve a single thumbnail JPEG |
//!
//! # Architecture
//!
//! The API serves **pre-extracted** JPEG frames.  A background task (in the
//! recorder or a future API worker) writes them to:
//!
//! ```text
//! {export_dir}/.thumbs/{camera_id}/{unix_ts_ms}.jpg
//! ```
//!
//! The frame timestamp encoded in the filename is the milliseconds-since-epoch
//! of the frame's wall-clock time.  The API lists frames by scanning the DB
//! (via `db::list_thumbnail_times`, which is currently stubbed and returns an
//! empty vec) and builds download URLs pointing at `GET /filmstrip/{id}/frame`.
//!
//! ## On-demand extraction (fallback)
//!
//! When `list_thumbnail_times` returns no pre-generated frames (Phase 1 stub),
//! the list endpoint generates synthetic frame entries spaced every
//! `DEFAULT_THUMB_INTERVAL_SECS` seconds across the requested range.  Each
//! synthetic entry points at the same `frame` endpoint which will attempt to
//! locate the file on disk; if the file is not there (because the background
//! task has not run yet), the frame endpoint returns 404.
//!
//! ## Path traversal guard
//!
//! The `frame` endpoint derives the file path only from the camera UUID and a
//! millisecond timestamp — both validated from the URL / query string before
//! use.  The resolved path is canonicalized and checked against the thumbs
//! root before the file is opened.
//!
//! ## Caching
//!
//! Frame responses carry `Cache-Control: public, max-age=86400, immutable`
//! because a frame at a given timestamp never changes after it has been
//! written.

use axum::{
    extract::{Path, Query, State},
    http::{header, StatusCode},
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use std::path::{Path as FsPath, PathBuf};
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use serde::Deserialize;
use tokio::process::Command;
use uuid::Uuid;

use crumb_common::db;

use crate::{
    auth_mw::AuthUser,
    dto::{FilmstripFrame, FilmstripQuery, FilmstripResponse},
    error::ApiError,
    state::AppState,
};

/// Spacing between synthetic thumbnail entries when no pre-extracted frames
/// exist.  4 s matches the default `SEGMENT_SECONDS` in the recorder.
const DEFAULT_THUMB_INTERVAL_SECS: i64 = 4;

/// Subdirectory within `live_storage_path` where thumbnails are stored.
const THUMBS_SUBDIR: &str = ".thumbs";

/// ffmpeg binary (jellyfin-ffmpeg symlinked by the runtime image; same path the
/// export pipeline uses).
const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";

/// Hard cap on a single on-demand thumbnail extraction so a bad segment can't
/// tie up a request worker.
const THUMB_EXTRACT_TIMEOUT_SECS: u64 = 12;

// ─── route registry ───────────────────────────────────────────────────────────

/// Mount filmstrip routes onto the root router.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/filmstrip/:camera_id", get(list_filmstrip))
        .route("/filmstrip/:camera_id/frame", get(serve_frame))
}

// ─── GET /filmstrip/{camera_id} ───────────────────────────────────────────────

/// List thumbnail frame URLs for a camera in a time range.
///
/// Returns a [`FilmstripResponse`] where each `frames` entry contains the
/// timestamp and a `GET /filmstrip/{camera_id}/frame?ts=<ts>` URL the client
/// can fetch for the JPEG.
///
/// When no pre-extracted frames exist in the DB (the current Phase 1 state),
/// synthetic entries are generated across the range so the client can
/// conditionally request frames as the background task catches up.
async fn list_filmstrip(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
    Query(q): Query<FilmstripQuery>,
) -> Result<Json<FilmstripResponse>, ApiError> {
    // Enforce camera access.
    user.assert_camera_access(camera_id)?;

    if q.start >= q.end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }

    // Query pre-extracted thumbnail timestamps from the DB.
    let db_times = db::list_thumbnail_times(state.pool(), camera_id, q.start, q.end).await?;

    let timestamps: Vec<DateTime<Utc>> = if db_times.is_empty() {
        // Phase 1 fallback: synthesise frame slots across the range.
        generate_synthetic_timestamps(q.start, q.end, DEFAULT_THUMB_INTERVAL_SECS)
    } else {
        db_times
    };

    // Build frame entries — one per timestamp.
    let frames: Vec<FilmstripFrame> = timestamps
        .into_iter()
        .map(|ts| {
            // RFC 3339 in the query string so the frame endpoint can deserialise it.
            let ts_str = urlencoding::encode(&ts.to_rfc3339()).into_owned();
            let url = format!(
                "/filmstrip/{camera_id}/frame?ts={ts_str}&width={width}",
                width = q.width
            );
            FilmstripFrame { ts, url }
        })
        .collect();

    Ok(Json(FilmstripResponse { camera_id, frames }))
}

// ─── GET /filmstrip/{camera_id}/frame ─────────────────────────────────────────

/// Query parameters for the single-frame endpoint.
#[derive(Debug, Deserialize)]
pub struct FrameQuery {
    /// Timestamp of the frame to serve.
    pub ts: DateTime<Utc>,
    /// Requested width in pixels (informational for v1 — single resolution stored).
    /// Parsed from the query for forward-compat but not yet used to resize.
    #[serde(default = "default_thumb_width")]
    #[allow(dead_code)]
    pub width: u32,
}

fn default_thumb_width() -> u32 {
    160
}

/// Serve a single pre-extracted JPEG thumbnail.
///
/// File path: `{export_dir}/.thumbs/{camera_id}/{ts_ms}.jpg`
///
/// Returns 404 when the file is not yet on disk (background task not run),
/// 400 on path traversal attempts, and `image/jpeg` with immutable caching
/// headers on success.
async fn serve_frame(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
    Query(q): Query<FrameQuery>,
) -> Result<impl IntoResponse, ApiError> {
    use tokio_util::io::ReaderStream;

    // Camera access check.
    user.assert_camera_access(camera_id)?;

    // Derive the file path from the timestamp.
    //
    // Filename = milliseconds since epoch, zero-padded to 13 digits.
    // This is deterministic and contains no user-controlled data beyond the
    // parsed timestamp.
    let ts_ms = q.ts.timestamp_millis();
    // Cache thumbnails under the WRITABLE export volume — the live/archive storage
    // roots are mounted read-only in the API container, so `.thumbs` can't live there.
    let thumbs_root = std::path::PathBuf::from(&state.config().export_dir)
        .join(THUMBS_SUBDIR)
        .join(camera_id.to_string());
    let frame_path = thumbs_root.join(format!("{ts_ms:013}.jpg"));

    // On-demand extraction: there is no background thumbnail task, so if this
    // frame isn't cached yet, pull a single frame from the recorded segment that
    // covers `ts` and write it to the cache path. This is what makes the filmstrip
    // scrubber + clip-start thumbnails actually work (and gives a past-frame still,
    // which the live `frame.jpg` proxy cannot). Subsequent requests hit the cache.
    if tokio::fs::metadata(&frame_path).await.is_err() {
        extract_thumbnail(&state, camera_id, q.ts, q.width, &thumbs_root, &frame_path).await?;
    }

    // Path traversal guard: the resolved path must start with the thumbs root.
    // We canonicalize the root first (it must exist for the guard to be
    // meaningful), then check the resolved frame path.
    let canonical_root = match tokio::fs::canonicalize(&thumbs_root).await {
        Ok(p) => p,
        Err(_) => {
            // The thumbs directory doesn't exist yet (no frames extracted).
            return Err(ApiError::NotFound(format!(
                "no thumbnails available for camera {camera_id}"
            )));
        }
    };

    let canonical_frame = match tokio::fs::canonicalize(&frame_path).await {
        Ok(p) => p,
        Err(_) => {
            return Err(ApiError::NotFound(format!(
                "thumbnail at {} not found for camera {camera_id}",
                q.ts.to_rfc3339()
            )));
        }
    };

    if !canonical_frame.starts_with(&canonical_root) {
        tracing::warn!(
            %camera_id,
            ts = %q.ts,
            path = %canonical_frame.display(),
            "path traversal guard rejected filmstrip frame request"
        );
        return Err(ApiError::BadRequest(
            "resolved path escapes the thumbnail directory".to_owned(),
        ));
    }

    // Open and stream the file.
    let file = tokio::fs::File::open(&canonical_frame)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("open thumbnail: {e}")))?;

    let metadata = file
        .metadata()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("stat thumbnail: {e}")))?;

    let stream = ReaderStream::new(file);
    let body = axum::body::Body::from_stream(stream);

    let response = axum::response::Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "image/jpeg")
        .header(header::CONTENT_LENGTH, metadata.len().to_string())
        // Thumbnails are immutable once written — cache aggressively.
        .header(header::CACHE_CONTROL, "public, max-age=86400, immutable")
        .body(body)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build frame response: {e}")))?;

    Ok(response)
}

// ─── on-demand thumbnail extraction ───────────────────────────────────────────

/// Extract a single JPEG frame at `ts` from the recorded segment covering it,
/// scaled to ~`width`px, and write it to `frame_path` (creating `thumbs_root`).
///
/// Resolves the covering segment via [`db::resolve_segment`] (main stream),
/// computes the in-segment offset, and runs `ffmpeg -ss <off> -i <seg>
/// -frames:v 1 -vf scale=W:-2`. Input-side `-ss` is a fast keyframe seek — plenty
/// accurate for a scrub thumbnail. Returns 404 when no footage covers `ts`.
async fn extract_thumbnail(
    state: &AppState,
    camera_id: Uuid,
    ts: DateTime<Utc>,
    width: u32,
    thumbs_root: &FsPath,
    frame_path: &FsPath,
) -> Result<(), ApiError> {
    let seg = db::resolve_segment(state.pool(), camera_id, ts, "main")
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| {
            ApiError::NotFound(format!(
                "no footage at {} for camera {camera_id}",
                ts.to_rfc3339()
            ))
        })?;

    // Resolve from the segment's own storage row (authoritative): a segment's
    // physical location is defined SOLELY by its storage_id (→ storages.path). A
    // repointed live_storage puts footage on a disk that no longer matches its
    // `stage`, so a stage→mount guess would read the WRONG disk. If the storage row
    // is missing (should never happen — NOT NULL + ON DELETE RESTRICT FK), FAIL
    // LOUDLY rather than guessing a mount.
    let storage = db::get_storage(state.pool(), seg.storage_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!(
                "segment {} storage row missing (storage_id={}); refusing to guess a mount",
                seg.id,
                seg.storage_id
            ))
        })?;
    let seg_abs = PathBuf::from(storage.path).join(&seg.path);

    // In-segment offset (clamped non-negative).
    #[allow(clippy::cast_precision_loss)]
    let offset_secs: f64 = (ts - seg.start_ts).num_milliseconds().max(0) as f64 / 1000.0;
    let w = width.clamp(48, 640);

    tokio::fs::create_dir_all(thumbs_root)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("create thumbs dir: {e}")))?;

    let args: Vec<String> = vec![
        "-y".to_owned(),
        "-ss".to_owned(),
        format!("{offset_secs:.3}"),
        "-i".to_owned(),
        seg_abs.to_string_lossy().into_owned(),
        "-frames:v".to_owned(),
        "1".to_owned(),
        "-an".to_owned(),
        "-vf".to_owned(),
        format!("scale={w}:-2"),
        "-q:v".to_owned(),
        "4".to_owned(),
        frame_path.to_string_lossy().into_owned(),
    ];

    let child = Command::new(FFMPEG_BIN)
        .args(&args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("spawn ffmpeg: {e}")))?;

    let status = tokio::time::timeout(
        Duration::from_secs(THUMB_EXTRACT_TIMEOUT_SECS),
        child.wait_with_output(),
    )
    .await
    .map_err(|_| ApiError::Internal(anyhow::anyhow!("thumbnail extraction timed out")))?
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("ffmpeg wait: {e}")))?;

    if !status.status.success() || tokio::fs::metadata(frame_path).await.is_err() {
        return Err(ApiError::NotFound(format!(
            "could not extract a thumbnail at {} for camera {camera_id}",
            ts.to_rfc3339()
        )));
    }

    Ok(())
}

// ─── helpers ──────────────────────────────────────────────────────────────────

/// Generate evenly-spaced timestamp slots across `[start, end)` with
/// `interval_secs` spacing.
///
/// Always includes a slot at exactly `start`.  The last slot is the largest
/// multiple of `interval_secs` from `start` that is strictly less than `end`.
fn generate_synthetic_timestamps(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    interval_secs: i64,
) -> Vec<DateTime<Utc>> {
    if interval_secs <= 0 {
        return vec![];
    }
    let total_ms = (end - start).num_milliseconds();
    if total_ms <= 0 {
        return vec![];
    }
    let step_ms = interval_secs * 1_000;
    // total_ms and step_ms are both positive here; quotient fits usize on all
    // targets we care about (Linux x86_64 with 48-bit virtual address space).
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let count = (total_ms / step_ms) as usize + 1;
    let start_ms = start.timestamp_millis();

    (0..count)
        .filter_map(|i| {
            #[allow(clippy::cast_possible_wrap)]
            let ts_ms = start_ms + (i as i64) * step_ms;
            // Keep slots strictly before `end`.
            let ts = Utc.timestamp_millis_opt(ts_ms).single()?;
            if ts < end {
                Some(ts)
            } else {
                None
            }
        })
        .collect()
}

// ─── urlencoding helper ───────────────────────────────────────────────────────

/// Minimal percent-encoding for query-string values.
///
/// We only need to encode the `:`, `+`, and space characters that appear in
/// RFC 3339 timestamps.  Using the `urlencoding` crate (already available as
/// a transitive dep via `axum`/`tower-http`).
mod urlencoding {
    /// Percent-encode `s` for safe inclusion in a URL query string.
    pub fn encode(s: &str) -> std::borrow::Cow<'_, str> {
        // The characters that MUST be encoded in query-string values are
        // `+`, `&`, `=`, `#`, and `%` (among others).  RFC 3339 timestamps
        // contain `:` which is safe in query strings per RFC 3986 §3.4 but
        // some parsers reject it without encoding.  We use Rust's standard
        // percent-encode approach via byte iteration.
        let needs_encoding = s.bytes().any(|b| {
            !matches!(b, b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9'
                | b'-' | b'_' | b'.' | b'~')
        });
        if !needs_encoding {
            return std::borrow::Cow::Borrowed(s);
        }
        let mut out = String::with_capacity(s.len() * 3);
        for b in s.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(b as char);
                }
                _ => {
                    out.push('%');
                    out.push(char::from_digit(u32::from(b) >> 4, 16).unwrap_or('0'));
                    out.push(char::from_digit(u32::from(b) & 0xf, 16).unwrap_or('0'));
                }
            }
        }
        std::borrow::Cow::Owned(out)
    }
}
