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
//! (via `db::list_thumbnail_times`, which intersects the fixed grid with
//! recorded `segments` coverage so gap slots are never listed) and builds
//! download URLs pointing at `GET /filmstrip/{id}/frame`.
//!
//! ## On-demand extraction (fallback)
//!
//! When `list_thumbnail_times` finds NO recorded coverage anywhere in the
//! requested range (a brand-new camera, or a window entirely before its first
//! segment), the list endpoint falls back to a synthetic grid spaced every
//! `DEFAULT_THUMB_INTERVAL_SECS` seconds across the range so the client still
//! has something to probe as the background task catches up.  Each synthetic
//! entry points at the same `frame` endpoint which will attempt to locate the
//! file on disk; if the file is not there (because the background task has
//! not run yet), the frame endpoint returns 404.
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
pub(crate) const DEFAULT_THUMB_INTERVAL_SECS: i64 = 4;

/// Bounds on the requested thumbnail width. The width is part of the cache key,
/// so clamping here keeps the number of distinct cached resolutions finite.
const THUMB_MIN_WIDTH: u32 = 48;
const THUMB_MAX_WIDTH: u32 = 640;

/// Hard ceiling on a single filmstrip window. The endpoint builds one grid
/// entry per `DEFAULT_THUMB_INTERVAL_SECS`, so an unbounded range would
/// allocate an enormous Vec (and OOM the process — filmstrip lives on the
/// no-timeout, no-rate-limit media router). No real scrub window is anywhere
/// near a week; past this we reject with 400 rather than allocate.
const FILMSTRIP_MAX_RANGE_SECS: i64 = 7 * 24 * 60 * 60;

/// Monotonic counter for unique temp-file suffixes during atomic thumbnail
/// writes (ffmpeg renders to `<final>.tmpN`, then we rename into place).
static TMP_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

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
/// `db::list_thumbnail_times` is coverage-aware: it already excludes grid
/// slots that fall in a recording gap. The only remaining fallback case is a
/// range with NO recorded coverage at all (a camera newly added, or a window
/// entirely before its first segment) — there `db_times` comes back empty and
/// we synthesise the plain grid so the client still gets slots to probe as
/// the background task catches up (each will 404 until it does).
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

    // Bound the window before it reaches the grid builder. An unbounded range
    // (e.g. year 1000 → 9999) would synthesise tens of billions of slots and
    // OOM the api on this no-timeout router; reject it up front with a clear
    // 400 instead. `thumbnail_grid_slots` also caps the allocation as a
    // defense-in-depth backstop for any other caller.
    if (q.end - q.start).num_seconds() > FILMSTRIP_MAX_RANGE_SECS {
        return Err(ApiError::BadRequest(format!(
            "filmstrip window too large: max {FILMSTRIP_MAX_RANGE_SECS} seconds"
        )));
    }

    // Query coverage-filtered thumbnail slot timestamps from the DB.
    let db_times = db::list_thumbnail_times(
        state.pool(),
        camera_id,
        q.start,
        q.end,
        DEFAULT_THUMB_INTERVAL_SECS,
    )
    .await?;

    let timestamps: Vec<DateTime<Utc>> = if db_times.is_empty() {
        // No recorded coverage anywhere in the range: synthesise the plain
        // grid (unfiltered) rather than return nothing.
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

    // Snap the requested timestamp to a fixed global grid so arbitrary scrub
    // cursor times settle onto shared cache keys (a mid-scrub jitter no longer
    // produces a fresh filename + decode per tick), key the cache on the clamped
    // width, then ensure the frame exists, extracting on demand (singleflight +
    // atomic write) if the background pre-generation worker hasn't produced it.
    // The `.thumbs` cache lives under the WRITABLE export volume (the live/archive
    // roots are read-only in the api container). See `thumb_frame_path`.
    let grid_ms = DEFAULT_THUMB_INTERVAL_SECS * 1000;
    let ts_ms = q.ts.timestamp_millis().div_euclid(grid_ms) * grid_ms;
    let snapped_ts = Utc.timestamp_millis_opt(ts_ms).single().unwrap_or(q.ts);
    let w = q.width.clamp(THUMB_MIN_WIDTH, THUMB_MAX_WIDTH);
    let (thumbs_root, frame_path) =
        thumb_frame_path(state.config().thumb_cache_base(), camera_id, ts_ms, w);
    ensure_thumbnail(&state, camera_id, snapped_ts, w).await?;

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

// ─── shared cache-path + ensure helpers ───────────────────────────────────────

/// On-disk cache path for a thumbnail:
/// `{export_dir}/.thumbs/{camera}/{ts_ms}_w{width}.jpg`. Returns
/// `(thumbs_root_dir, frame_file)`. Shared by the request handler and the
/// background pre-generation worker so both agree on the exact layout.
pub(crate) fn thumb_frame_path(
    export_dir: &str,
    camera_id: Uuid,
    ts_ms: i64,
    width: u32,
) -> (PathBuf, PathBuf) {
    let root = PathBuf::from(export_dir)
        .join(THUMBS_SUBDIR)
        .join(camera_id.to_string());
    let frame = root.join(format!("{ts_ms:013}_w{width}.jpg"));
    (root, frame)
}

/// Ensure a thumbnail exists for the (already grid-snapped) `snapped_ts` at
/// `width`, extracting it once under the singleflight lock if absent. Reused by
/// the request path and the Phase 1 background worker. Returns the cache path.
pub(crate) async fn ensure_thumbnail(
    state: &AppState,
    camera_id: Uuid,
    snapped_ts: DateTime<Utc>,
    width: u32,
) -> Result<PathBuf, ApiError> {
    let w = width.clamp(THUMB_MIN_WIDTH, THUMB_MAX_WIDTH);
    let (thumbs_root, frame_path) = thumb_frame_path(
        state.config().thumb_cache_base(),
        camera_id,
        snapped_ts.timestamp_millis(),
        w,
    );
    if tokio::fs::metadata(&frame_path).await.is_ok() {
        return Ok(frame_path);
    }
    // Singleflight: serialize concurrent misses on this key so only one caller
    // extracts (background worker vs on-demand request, or two scrubbers).
    let lock = state.thumb_inflight_lock(&frame_path);
    let _flight = lock.lock().await;
    if tokio::fs::metadata(&frame_path).await.is_err() {
        extract_thumbnail(state, camera_id, snapped_ts, w, &thumbs_root, &frame_path).await?;
    }
    Ok(frame_path)
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
    let w = width.clamp(THUMB_MIN_WIDTH, THUMB_MAX_WIDTH);

    tokio::fs::create_dir_all(thumbs_root)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("create thumbs dir: {e}")))?;

    // Atomic write: ffmpeg renders to a unique temp file, then we rename it into
    // place. A rename on the same filesystem is atomic, so a concurrent reader
    // (or the Phase 1 background writer racing an on-demand request) can never
    // observe a half-written JPEG. The `.tmp*` suffix keeps the `.jpg`-only
    // sweeper from touching an in-flight temp.
    let seq = TMP_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut tmp_os = frame_path.as_os_str().to_owned();
    tmp_os.push(format!(".tmp{seq}"));
    let tmp_path = PathBuf::from(tmp_os);

    // Cap concurrent extractions so a fast multi-camera scrub (each miss is one
    // single-frame ffmpeg) can't spawn a storm, mirroring the `/play` and
    // clip-gen semaphores. The permit is held only for the decode below and
    // released on drop when this function returns.
    let _permit = state
        .thumb_semaphore()
        .acquire_owned()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("thumb semaphore closed: {e}")))?;

    let args = thumb_ffmpeg_args(
        offset_secs,
        w,
        &seg_abs.to_string_lossy(),
        &tmp_path.to_string_lossy(),
    );

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

    if !status.status.success() || tokio::fs::metadata(&tmp_path).await.is_err() {
        let _ = tokio::fs::remove_file(&tmp_path).await;
        return Err(ApiError::NotFound(format!(
            "could not extract a thumbnail at {} for camera {camera_id}",
            ts.to_rfc3339()
        )));
    }

    // Publish atomically: rename the completed temp into the final cache path.
    tokio::fs::rename(&tmp_path, frame_path)
        .await
        .map_err(|e| {
            let _ = std::fs::remove_file(&tmp_path);
            ApiError::Internal(anyhow::anyhow!("finalize thumbnail: {e}"))
        })?;

    Ok(())
}

// ─── helpers ──────────────────────────────────────────────────────────────────

/// Generate timestamp slots across `[start, end)` anchored to a fixed global
/// grid of `interval_secs`, unfiltered by recorded coverage.
///
/// Thin wrapper over `db::thumbnail_grid_slots` — the SAME grid
/// `list_thumbnail_times` filters by segment coverage, kept here as the
/// zero-coverage fallback so a brand-new camera (or a window entirely before
/// its first segment) still gets slots to probe. See that function's doc
/// comment for the floor/anchor semantics.
fn generate_synthetic_timestamps(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    interval_secs: i64,
) -> Vec<DateTime<Utc>> {
    db::thumbnail_grid_slots(start, end, interval_secs)
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

/// Build the ffmpeg args for a single-frame thumbnail extraction.
///
/// Factored out for a regression guard: the output muxer MUST be forced with
/// `-f mjpeg` because the atomic-write temp path ends in `.tmp{seq}` (not
/// `.jpg`), so ffmpeg cannot infer the format from the extension. Without it,
/// every extraction fails to open the output ("Unable to choose an output
/// format") and `serve_frame` 404s. See `thumb_ffmpeg_args_forces_mjpeg`.
fn thumb_ffmpeg_args(offset_secs: f64, width: u32, input: &str, output: &str) -> Vec<String> {
    vec![
        "-y".to_owned(),
        "-ss".to_owned(),
        format!("{offset_secs:.3}"),
        "-i".to_owned(),
        input.to_owned(),
        "-frames:v".to_owned(),
        "1".to_owned(),
        "-an".to_owned(),
        "-vf".to_owned(),
        format!("scale={width}:-2"),
        "-q:v".to_owned(),
        "4".to_owned(),
        // Force the muxer: the temp output ends in `.tmp{seq}`, not `.jpg`.
        "-f".to_owned(),
        "mjpeg".to_owned(),
        output.to_owned(),
    ]
}

#[cfg(test)]
mod tests {
    use super::thumb_ffmpeg_args;

    #[test]
    fn thumb_ffmpeg_args_forces_mjpeg() {
        // The atomic-write output ends in `.tmp{n}`, so ffmpeg can't infer the
        // muxer from the extension. If `-f mjpeg` ever goes missing, extraction
        // fails to open the output and every scrub frame 404s (the shipped-broken
        // regression this guards against).
        let args = thumb_ffmpeg_args(2.5, 160, "/data/archive/cam/seg.mp4", "/thumbs/x.jpg.tmp7");
        let f = args
            .iter()
            .position(|a| a == "-f")
            .expect("ffmpeg args must force an output format");
        assert_eq!(
            args.get(f + 1).map(String::as_str),
            Some("mjpeg"),
            "output muxer must be mjpeg",
        );
        // ffmpeg's positional output is last; single frame; no audio.
        assert_eq!(args.last().map(String::as_str), Some("/thumbs/x.jpg.tmp7"));
        assert!(args.iter().any(|a| a == "-frames:v"));
        assert!(args.iter().any(|a| a == "-an"));
    }
}
