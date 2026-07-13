// SPDX-License-Identifier: AGPL-3.0-or-later

//! On-demand low-bitrate playback variant: `GET /segments/{id}/low.mp4`.
//!
//! Recorded segments are served byte-for-byte by [`crate::playback::serve_segment`]
//! — the camera's native main stream, typically multi-megabit H.265. That is
//! instant on a LAN but unplayable over a poor cellular link, where the sustained
//! throughput can be a tenth of the segment bitrate. This module adds a **quality
//! lever** to the same segment: a transcoded 640p / ~15 fps / CRF 28 H.264
//! variant (≈300–600 kbps) produced **only when a client requests it** and then
//! cached, so a good connection pays nothing (the client just keeps using
//! `/segments/{id}`) and a bad one gets a stream it can actually keep up with.
//!
//! It is a deliberate near-copy of the clip-preview machinery in
//! [`crate::clips`] (on-demand `libx264` transcode, cached under `export_dir`,
//! LRU-pruned, concurrency-bounded by the shared `clip_gen_semaphore`, `ETag`'d),
//! reusing the same proven properties:
//!
//! * **Secure by default.** Same auth as `/segments/{id}`: `require_playback()` +
//!   `assert_camera_access()` + the scoped per-camera `?token=` media claim (the
//!   [`AuthUser`] extractor accepts it), so it serves directly as a `<video>` /
//!   `ExoPlayer` source. The same path-traversal guard
//!   ([`crate::playback::guard_path_traversal`]) runs before any file I/O.
//! * **Read-only footage.** The API mounts media read-only; this reads the
//!   segment file and writes ONLY to its own cache under `export_dir`. The
//!   recorder is never touched — zero recording-correctness risk.
//! * **Content-addressed cache.** A segment's bytes never change once written
//!   (retention only ever deletes the whole segment, which 404s here), so the
//!   low variant is immutable and cached hard by segment id — repeat scrubs over
//!   the same footage hit the cache.

use std::path::{Path as FsPath, PathBuf};

use axum::{
    body::Body,
    extract::{Path, Request, State},
    http::{header, HeaderMap, StatusCode},
    response::Response,
    routing::get,
    Router,
};
use tokio::process::Command;
use tower::ServiceExt as _;
use tower_http::services::ServeFile;
use uuid::Uuid;

use crumb_common::db;

use crate::{auth_mw::AuthUser, error::ApiError, playback::guard_path_traversal, state::AppState};

/// Same ffmpeg the clip machinery uses (bundled jellyfin-ffmpeg in the API image).
const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";

/// Long, immutable cache lifetime (30 days) — a segment's footage never changes.
const CACHE_MAX_AGE_SECS: u64 = 30 * 24 * 60 * 60;

/// Mount `GET /segments/{id}/low.mp4`. Lives in `media_routes` (no 30 s JSON
/// timeout; `AuthUser` accepts `?token=`), a sibling of the raw
/// `/segments/{id}` route which stays byte-transparent.
pub fn routes() -> Router<AppState> {
    Router::new().route("/segments/:segment_id/low.mp4", get(get_segment_low))
}

/// `GET /segments/{segment_id}/low.mp4` — generate (once, cached) + serve a
/// low-bitrate H.264 variant of one recorded segment, with HTTP range support.
///
/// # Errors
///
/// * `400` — path traversal detected (also emits `WARN`), matching `serve_segment`.
/// * `403` — caller cannot access the camera that owns this segment.
/// * `404` — segment row not found, or the file is missing on disk.
/// * `500` — storage row missing / transcode failed.
async fn get_segment_low(
    user: AuthUser,
    State(state): State<AppState>,
    Path(segment_id): Path<Uuid>,
    req: Request,
) -> Result<Response, ApiError> {
    // ── capability + scope (identical to serve_segment) ───────────────────────
    user.require_playback()?;
    let seg = db::get_segment(state.pool(), segment_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("segment {segment_id} not found")))?;
    user.assert_camera_access(seg.camera_id)?;

    // ── content-addressed cache short-circuit ─────────────────────────────────
    let etag = seg_low_etag(segment_id);
    if let Some(resp) = not_modified_if_match(req.headers(), &etag) {
        return Ok(resp);
    }

    // ── resolve + guard the source segment path (same rules as serve_segment) ─
    let storage = db::get_storage(state.pool(), seg.storage_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| {
            ApiError::Internal(anyhow::anyhow!(
                "segment {segment_id} storage row missing (storage_id={}); refusing to guess a mount",
                seg.storage_id
            ))
        })?;
    let storage_root = PathBuf::from(storage.path);
    let absolute = storage_root.join(&seg.path);
    let src = guard_path_traversal(&storage_root, &absolute, segment_id)?;

    // ── generate once, then serve the cached faststart MP4 via ServeFile ──────
    let cache_dir = PathBuf::from(&state.config().export_dir).join("segcache");
    tokio::fs::create_dir_all(&cache_dir).await.ok();
    let out = cache_dir.join(format!("{segment_id}.low.mp4"));
    if tokio::fs::metadata(&out).await.is_err() {
        generate_low_file(&state, &src, &out).await?;
        prune_cache(&cache_dir, state.config().segment_low_cache_max_bytes).await;
    }

    let resp = ServeFile::new(&out)
        .oneshot(req)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("ServeFile: {e}")))?;
    let (parts, body) = resp.into_parts();
    let mut resp = Response::from_parts(parts, Body::new(body));
    add_cache_headers(&mut resp, &etag);
    Ok(resp)
}

/// Transcode one segment file to a **faststart** low-bitrate H.264 MP4 at `out`,
/// waiting for completion. Writes to a unique temp file then atomically renames,
/// so a crashed/concurrent run never leaves a half file for `ServeFile`. Holds
/// the shared `clip_gen_semaphore` (same bound as clip previews) for the transcode.
///
/// Ladder: `libx264 -preset ultrafast -vf scale=640:-2 -r 15 -crf 28`, matching
/// the proven clip-preview downscale, but KEEPING audio (AAC mono ~40 kbps) —
/// the recorded segment already carries 48 kHz AAC (recorder normalizes it), so
/// the mobile viewer showing someone footage still hears it. Re-encoding audio
/// (rather than `-c copy`) yields a clean, continuous AAC track within the
/// segment. Cameras with no audio track simply produce no audio (aac is a no-op).
async fn generate_low_file(state: &AppState, src: &FsPath, out: &FsPath) -> Result<(), ApiError> {
    let _permit = state
        .clip_gen_semaphore()
        .acquire_owned()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("clip-gen semaphore closed: {e}")))?;
    // Another request may have produced it while we waited for the permit.
    if tokio::fs::metadata(out).await.is_ok() {
        return Ok(());
    }
    let tmp = out.with_file_name(format!("{}.partial.mp4", Uuid::new_v4()));
    let args = low_transcode_args(&src.to_string_lossy(), &tmp.to_string_lossy());
    let status = Command::new(FFMPEG_BIN)
        .args(&args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;
    match status {
        Ok(s) if s.success() => tokio::fs::rename(&tmp, out)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("cache low.mp4 rename: {e}"))),
        other => {
            let _ = tokio::fs::remove_file(&tmp).await;
            Err(ApiError::Internal(anyhow::anyhow!(
                "ffmpeg low transcode failed: {other:?}"
            )))
        }
    }
}

/// Build the ffmpeg argv for the low-bitrate transcode of a single input file to
/// `out` (a faststart MP4). Pure + unit-tested so the ladder can't silently drift.
fn low_transcode_args(input: &str, out: &str) -> Vec<String> {
    [
        "-y",
        "-i",
        input,
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-vf",
        "scale=640:-2",
        "-r",
        "15",
        "-crf",
        "28",
        // Keep audio, but small: AAC mono ~40 kbps. If the source has no audio
        // track ffmpeg just emits none.
        "-c:a",
        "aac",
        "-ac",
        "1",
        "-b:a",
        "40k",
        "-movflags",
        "+faststart",
        out,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

/// Keep the low-variant cache under `max_bytes` by deleting the oldest
/// `*.low.mp4` (by mtime) until it fits. Best-effort — mirrors
/// `clips::prune_clip_cache`. Extension-filtered so it can only ever remove files
/// this module produced.
async fn prune_cache(dir: &FsPath, max_bytes: u64) {
    let Ok(mut rd) = tokio::fs::read_dir(dir).await else {
        return;
    };
    let mut files: Vec<(std::time::SystemTime, u64, PathBuf)> = Vec::new();
    let mut total: u64 = 0;
    while let Ok(Some(ent)) = rd.next_entry().await {
        let p = ent.path();
        if !p.to_string_lossy().ends_with(".low.mp4") {
            continue;
        }
        let Ok(md) = ent.metadata().await else {
            continue;
        };
        total += md.len();
        files.push((md.modified().unwrap_or(std::time::UNIX_EPOCH), md.len(), p));
    }
    if total <= max_bytes {
        return;
    }
    files.sort_by_key(|(m, _, _)| *m); // oldest first
    for (_, len, p) in files {
        if total <= max_bytes {
            break;
        }
        if tokio::fs::remove_file(&p).await.is_ok() {
            total = total.saturating_sub(len);
        }
    }
}

/// A strong-ish `ETag` for a segment's low variant — content-addressed by the
/// (immutable) segment id, so repeat requests revalidate with a tiny 304.
fn seg_low_etag(segment_id: Uuid) -> String {
    format!("\"{segment_id}-low\"")
}

/// `Cache-Control` for the immutable low variant.
fn cache_control() -> String {
    format!("public, max-age={CACHE_MAX_AGE_SECS}, immutable")
}

/// Stamp `Cache-Control` (immutable) + `ETag` onto an already-built response.
fn add_cache_headers(resp: &mut Response, etag: &str) {
    let h = resp.headers_mut();
    if let Ok(v) = cache_control().parse() {
        h.insert(header::CACHE_CONTROL, v);
    }
    if let Ok(v) = etag.parse() {
        h.insert(header::ETAG, v);
    }
}

/// If the request's `If-None-Match` matches `etag`, return a bare 304 (with cache
/// headers re-stated). Mirrors `clips::not_modified_if_match`.
fn not_modified_if_match(headers: &HeaderMap, etag: &str) -> Option<Response> {
    let inm = headers.get(header::IF_NONE_MATCH)?.to_str().ok()?;
    let hit = inm == "*"
        || inm
            .split(',')
            .map(str::trim)
            .any(|t| t == etag || t.trim_start_matches("W/") == etag);
    if !hit {
        return None;
    }
    Some(
        Response::builder()
            .status(StatusCode::NOT_MODIFIED)
            .header(header::ETAG, etag)
            .header(header::CACHE_CONTROL, cache_control())
            .body(Body::empty())
            .expect("static 304 response builds"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcode_args_are_the_low_ladder() {
        let a = low_transcode_args("/data/live/cam/seg.mp4", "/tmp/x.partial.mp4");
        // Downscale + fps cap + CRF ladder (matches clip previews) …
        assert!(a.windows(2).any(|w| w == ["-vf", "scale=640:-2"]));
        assert!(a.windows(2).any(|w| w == ["-r", "15"]));
        assert!(a.windows(2).any(|w| w == ["-crf", "28"]));
        assert!(a.windows(2).any(|w| w == ["-preset", "ultrafast"]));
        assert!(a.windows(2).any(|w| w == ["-c:v", "libx264"]));
        // … but unlike clip previews, KEEP audio (mobile viewers showing footage).
        assert!(a.windows(2).any(|w| w == ["-c:a", "aac"]));
        assert!(!a.iter().any(|s| s == "-an"));
        // Seekable output for ServeFile Range support.
        assert!(a.windows(2).any(|w| w == ["-movflags", "+faststart"]));
        // Input then output ordering.
        let ii = a.iter().position(|s| s == "-i").unwrap();
        assert_eq!(a[ii + 1], "/data/live/cam/seg.mp4");
        assert_eq!(a.last().unwrap(), "/tmp/x.partial.mp4");
    }

    #[test]
    fn etag_is_stable_and_low_scoped() {
        let id = Uuid::new_v4();
        assert_eq!(seg_low_etag(id), seg_low_etag(id));
        let e = seg_low_etag(id);
        assert!(e.starts_with('"') && e.ends_with('"'));
        assert!(e.contains("-low"));
    }

    #[test]
    fn cache_control_is_immutable_and_long() {
        let cc = cache_control();
        assert!(cc.contains("public"));
        assert!(cc.contains("immutable"));
        assert!(cc.contains(&format!("max-age={CACHE_MAX_AGE_SECS}")));
    }

    #[test]
    fn if_none_match_hits_and_misses() {
        use axum::http::HeaderValue;
        let id = Uuid::new_v4();
        let etag = seg_low_etag(id);

        let mut h = HeaderMap::new();
        h.insert(header::IF_NONE_MATCH, HeaderValue::from_str(&etag).unwrap());
        let r = not_modified_if_match(&h, &etag).expect("exact match → 304");
        assert_eq!(r.status(), StatusCode::NOT_MODIFIED);
        assert!(r.headers().get(header::ETAG).is_some());
        assert!(r.headers().get(header::CACHE_CONTROL).is_some());

        // Wildcard + weak-validator list membership.
        let mut h = HeaderMap::new();
        h.insert(header::IF_NONE_MATCH, HeaderValue::from_static("*"));
        assert!(not_modified_if_match(&h, &etag).is_some());
        let mut h = HeaderMap::new();
        h.insert(
            header::IF_NONE_MATCH,
            HeaderValue::from_str(&format!("\"other\", W/{etag}")).unwrap(),
        );
        assert!(not_modified_if_match(&h, &etag).is_some());

        // Miss + absent.
        let mut h = HeaderMap::new();
        h.insert(header::IF_NONE_MATCH, HeaderValue::from_static("\"nope\""));
        assert!(not_modified_if_match(&h, &etag).is_none());
        assert!(not_modified_if_match(&HeaderMap::new(), &etag).is_none());
    }
}
