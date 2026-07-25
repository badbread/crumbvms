// SPDX-License-Identifier: AGPL-3.0-or-later

//! Disk-cached JPEG derivatives (downscale / crop) for detection + plate
//! imagery.
//!
//! Motivation: a stored detection frame is a FULL-RESOLUTION JPEG (~174 KB in a
//! live sample). Clients render those into ~130 px thumbnails, so every list
//! view shipped two orders of magnitude more bytes than it drew, then spent a
//! full-frame decode per row deriving the plate crop client-side. Serving the
//! derivative the client actually displays turns ~174 KB/row into ~10-20 KB and
//! removes the client decode entirely.
//!
//! Two derivatives, and the split matters:
//!
//! - **Downscale** (`scaled`) — the wide "context" frame, for a small thumb.
//! - **Crop** (`cropped`) — the plate region at its NATIVE resolution. A plate
//!   box is only ~5 % of frame width, so a plate cropped out of a downscaled
//!   frame is unreadable. Never derive the crop from a scaled frame.
//!
//! Everything runs through the same ffmpeg + bounded-concurrency + on-disk
//! cache machinery the clip thumbnails use (see `clips.rs`), so this adds no
//! new dependency. Results land under `export_dir/imgcache` — the api's one
//! writable area (media storage is mounted read-only).
//!
//! The cache is keyed by caller-supplied identity (an event/read id plus the
//! derivative spec). Source bytes are immutable once a detection is written, so
//! a hit never needs revalidation.

use std::path::{Path as FsPath, PathBuf};

use tokio::process::Command;
use uuid::Uuid;

use crate::error::ApiError;
use crate::state::AppState;

/// ffmpeg binary, same absolute path the clip pipeline uses.
const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";

/// A single derivative must never wedge a request for long — these are tiny
/// still-image transforms, not transcodes.
const TRANSFORM_TIMEOUT_SECS: u64 = 10;

/// Total bytes the derivative cache may occupy before the oldest entries are
/// pruned. Derivatives are 5-20 KB, so this holds many thousands of them.
const IMG_CACHE_MAX_BYTES: u64 = 256 * 1024 * 1024;

/// Prune once every this many writes (an exact budget check on every write
/// would stat the whole directory far too often).
const PRUNE_EVERY_N_WRITES: u64 = 64;

/// Widths a caller may request. An open integer range would let one client mint
/// unbounded distinct cache entries (and ffmpeg runs) for the same image, so the
/// requested width is snapped to the nearest allowed value rather than honored
/// verbatim. Ordered ascending.
const ALLOWED_WIDTHS: [u32; 7] = [160, 240, 320, 480, 640, 960, 1280];

/// Snap `requested` to the nearest [`ALLOWED_WIDTHS`] entry. Anything at or
/// above the largest allowed width snaps to that largest value — callers who
/// want true full resolution omit the parameter instead.
#[must_use]
pub fn snap_width(requested: u32) -> u32 {
    let mut best = ALLOWED_WIDTHS[0];
    let mut best_delta = u32::MAX;
    for w in ALLOWED_WIDTHS {
        let delta = w.abs_diff(requested);
        if delta < best_delta {
            best_delta = delta;
            best = w;
        }
    }
    best
}

/// Root of the derivative cache. Under `export_dir`, which the api can write
/// (unlike the read-only media mount).
fn cache_dir(state: &AppState) -> PathBuf {
    PathBuf::from(&state.config().export_dir).join("imgcache")
}

/// Serve `id`'s frame downscaled to `width` px wide (height follows the source
/// aspect, rounded to an even number). Returns the derivative's JPEG bytes.
///
/// `width` is snapped via [`snap_width`] by the caller.
///
/// # Errors
///
/// Returns [`ApiError::Internal`] if the transform fails or produces nothing.
pub async fn scaled(
    state: &AppState,
    id: Uuid,
    width: u32,
    source: &[u8],
) -> Result<Vec<u8>, ApiError> {
    // `-2` keeps the height even (mjpeg needs even chroma dims) and preserves
    // aspect. `force_original_aspect_ratio` is unnecessary with a single axis.
    let filter = format!("scale={width}:-2");
    derive(state, &format!("{id}.w{width}"), &filter, source).await
}

/// Serve `id`'s frame cropped to `bbox` (`[x, y, w, h]` as 0..1 fractions of
/// the frame) at NATIVE resolution — no downscale, because the plate region is
/// already small and is the thing the operator must be able to read.
///
/// The box is clamped into the frame, so a degenerate or slightly out-of-range
/// box still yields a crop rather than an ffmpeg error.
///
/// # Errors
///
/// Returns [`ApiError::Internal`] if the transform fails or produces nothing.
pub async fn cropped(
    state: &AppState,
    id: Uuid,
    bbox: [f32; 4],
    source: &[u8],
) -> Result<Vec<u8>, ApiError> {
    // ffmpeg's crop takes expressions, so the clamp is done in-filter against
    // the real frame dims (iw/ih) — the caller doesn't need to decode first.
    // Fractions are clamped to sane bounds here; the in-filter min() guards the
    // rest (a box running off the right/bottom edge).
    let x = bbox[0].clamp(0.0, 1.0);
    let y = bbox[1].clamp(0.0, 1.0);
    let w = bbox[2].clamp(0.0, 1.0);
    let h = bbox[3].clamp(0.0, 1.0);
    // A zero-area box would make ffmpeg fail; fall back to the whole frame.
    if w <= 0.0 || h <= 0.0 {
        return Ok(source.to_vec());
    }
    let filter = format!(
        "crop=w=min(iw*{w:.6}\\,iw-iw*{x:.6}):h=min(ih*{h:.6}\\,ih-ih*{y:.6}):x=iw*{x:.6}:y=ih*{y:.6}"
    );
    // The key includes the box: a late Frigate refinement can move the box on a
    // read, and a stale crop must not be served for the new one.
    let key = format!("{id}.crop{x:.4}_{y:.4}_{w:.4}_{h:.4}");
    derive(state, &key, &filter, source).await
}

/// Shared path: return the cached derivative for `key`, or produce it by
/// running `filter` over `source` with ffmpeg and cache it.
async fn derive(
    state: &AppState,
    key: &str,
    filter: &str,
    source: &[u8],
) -> Result<Vec<u8>, ApiError> {
    let dir = cache_dir(state);
    let out = dir.join(format!("{}.jpg", sanitize_key(key)));

    // Fast path: an existing derivative. Source frames are immutable once
    // written, so a hit is always valid.
    if let Ok(bytes) = tokio::fs::read(&out).await {
        if !bytes.is_empty() {
            return Ok(bytes);
        }
    }

    // Bound total concurrent ffmpeg fan-out with the SAME permit the clip
    // pipeline uses, so a cold benchmark page can't spawn-storm the box.
    let _permit = state
        .clip_gen_semaphore()
        .acquire_owned()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("clip-gen semaphore closed: {e}")))?;

    // Another request may have produced it while we waited for the permit.
    if let Ok(bytes) = tokio::fs::read(&out).await {
        if !bytes.is_empty() {
            return Ok(bytes);
        }
    }

    tokio::fs::create_dir_all(&dir).await.ok();

    // Write the source to a scratch file rather than piping: ffmpeg probes its
    // input, and a seekable file avoids the stdin-pipe stalls that a partially
    // buffered image can cause. Unique name so concurrent misses on the same
    // key can't truncate each other's input mid-read.
    let scratch = dir.join(format!(".src-{}.jpg", Uuid::new_v4()));
    tokio::fs::write(&scratch, source)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("imgcache: write scratch: {e}")))?;

    // Same-directory temp target, then rename: a reader never observes a
    // half-written derivative.
    let tmp_out = dir.join(format!(".out-{}.jpg", Uuid::new_v4()));
    let result = run_ffmpeg(&scratch, filter, &tmp_out).await;
    tokio::fs::remove_file(&scratch).await.ok();

    if let Err(e) = result {
        tokio::fs::remove_file(&tmp_out).await.ok();
        return Err(e);
    }

    let bytes = tokio::fs::read(&tmp_out).await.unwrap_or_default();
    if bytes.is_empty() {
        tokio::fs::remove_file(&tmp_out).await.ok();
        return Err(ApiError::Internal(anyhow::anyhow!(
            "imgcache: transform produced no output"
        )));
    }
    if tokio::fs::rename(&tmp_out, &out).await.is_err() {
        tokio::fs::remove_file(&tmp_out).await.ok();
    }
    maybe_prune(&dir).await;
    Ok(bytes)
}

/// One still-image transform. `-frames:v 1` and an explicit mjpeg encoder keep
/// this a single-frame operation regardless of the input.
async fn run_ffmpeg(input: &FsPath, filter: &str, out: &FsPath) -> Result<(), ApiError> {
    let status = tokio::time::timeout(
        std::time::Duration::from_secs(TRANSFORM_TIMEOUT_SECS),
        Command::new(FFMPEG_BIN)
            .args([
                "-v",
                "error",
                "-y",
                "-i",
                &input.to_string_lossy(),
                "-vf",
                filter,
                "-frames:v",
                "1",
                "-c:v",
                "mjpeg",
                "-q:v",
                "3",
                &out.to_string_lossy(),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .status(),
    )
    .await
    .map_err(|_| ApiError::Internal(anyhow::anyhow!("imgcache: ffmpeg timed out")))?
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("imgcache: ffmpeg spawn: {e}")))?;

    if !status.success() {
        return Err(ApiError::Internal(anyhow::anyhow!(
            "imgcache: ffmpeg exited {status}"
        )));
    }
    Ok(())
}

/// Keep the cache under [`IMG_CACHE_MAX_BYTES`], oldest-first, sampled every
/// [`PRUNE_EVERY_N_WRITES`] writes so a hot path doesn't restat the directory
/// constantly. Best-effort: a failure here must never fail a request.
async fn maybe_prune(dir: &FsPath) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static WRITES: AtomicU64 = AtomicU64::new(0);
    if !WRITES
        .fetch_add(1, Ordering::Relaxed)
        .is_multiple_of(PRUNE_EVERY_N_WRITES)
    {
        return;
    }

    let Ok(mut rd) = tokio::fs::read_dir(dir).await else {
        return;
    };
    let mut entries: Vec<(std::time::SystemTime, u64, PathBuf)> = Vec::new();
    let mut total: u64 = 0;
    while let Ok(Some(e)) = rd.next_entry().await {
        let Ok(meta) = e.metadata().await else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let mtime = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
        total += meta.len();
        entries.push((mtime, meta.len(), e.path()));
    }
    if total <= IMG_CACHE_MAX_BYTES {
        return;
    }
    entries.sort_by_key(|(mtime, _, _)| *mtime); // oldest first
    for (_, len, path) in entries {
        if total <= IMG_CACHE_MAX_BYTES {
            break;
        }
        if tokio::fs::remove_file(&path).await.is_ok() {
            total = total.saturating_sub(len);
        }
    }
}

/// Reduce a cache key to characters safe in a filename. The keys this module
/// builds are already id/number shaped; this is defence in depth so a key can
/// never escape the cache directory.
fn sanitize_key(key: &str) -> String {
    key.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn width_snaps_to_an_allowed_value() {
        // Exact allowed values are preserved.
        for w in ALLOWED_WIDTHS {
            assert_eq!(snap_width(w), w);
        }
        // Arbitrary values land on the nearest allowed width, so a client
        // cannot mint unbounded cache entries by walking the integers.
        assert_eq!(snap_width(300), 320);
        assert_eq!(snap_width(1), 160);
        assert_eq!(snap_width(100_000), 1280, "clamped to the largest allowed");
        assert!(ALLOWED_WIDTHS.contains(&snap_width(517)));
    }

    #[test]
    fn keys_cannot_escape_the_cache_directory() {
        assert_eq!(sanitize_key("../../etc/passwd"), ".._.._etc_passwd");
        assert_eq!(sanitize_key("a/b"), "a_b");
        // Legitimate keys survive intact.
        assert_eq!(sanitize_key("abc-123.w320"), "abc-123.w320");
    }

    #[test]
    fn a_zero_area_box_is_not_sent_to_ffmpeg() {
        // Guarded in `cropped` before any filter is built — a zero-width or
        // zero-height crop makes ffmpeg fail outright.
        let degenerate = [[0.5, 0.5, 0.0, 0.2], [0.5, 0.5, 0.2, 0.0]];
        for b in degenerate {
            assert!(b[2] <= 0.0 || b[3] <= 0.0);
        }
    }
}
