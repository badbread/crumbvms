// SPDX-License-Identifier: AGPL-3.0-or-later

//! Per-segment scrub sprite strips.
//!
//! # Endpoint
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `GET`  | `/filmstrip/{camera_id}/sprite?ts=` | Bearer or scoped `?token=` | The sprite strip of the main-stream segment covering `ts`, with its tile layout in response headers |
//!
//! # What a sprite is
//!
//! One small JPEG per recorded segment: [`SPRITE_TILE_WIDTH`] px tiles laid
//! out left to right in a single row, tile `i` showing the segment at
//! `start + i * SPRITE_INTERVAL_MS` (the keyframe at or before that instant).
//! A 4 s segment is four tiles, so a scrubbing client gets 1 s granularity
//! from ONE request per segment instead of one 4 s-grid frame per request.
//!
//! # Who makes them
//!
//! Only the api's background pre-generation worker
//! ([`crate::thumb_pregen`]), behind the same `THUMB_PREGEN_ENABLED` /
//! admin-console "Scrub previews" toggle as the 4 s-grid frames. Never the
//! recorder (golden rule 2), and never on demand: a request for a sprite that
//! has not been generated is a plain 404, and the clients fall back to the
//! existing `GET /filmstrip/{camera_id}/frame` endpoint. A scrub request must
//! never wait on a multi-frame decode.
//!
//! # Lifetime: a sprite never outlives its segment
//!
//! Sprites are cache files under the writable thumbnail cache
//! (`{thumb_cache_base}/.thumbs/{camera}/sprites/{segment_id}_w{w}_t{n}.jpg`),
//! never next to footage, so they cannot hold up or interfere with the
//! recorder's deletion of a segment. Three things keep them from outliving it:
//!
//! 1. The serve path resolves the segment from the DB first and names the file
//!    by that segment's id, so a sprite whose segment is gone is unreachable.
//! 2. [`sweep_orphan_sprites`] (run by the api's cache sweeper) deletes every
//!    sprite whose segment id no longer exists in `segments`.
//! 3. The existing `.thumbs` age/byte-budget sweeper covers sprites like any
//!    other cached JPEG.
//!
//! The generator also re-checks the segment right after publishing a sprite,
//! so the race "segment deleted while its sprite was being rendered" leaves
//! nothing behind.
//!
//! # Response headers
//!
//! The layout travels in headers so one GET returns everything the client
//! needs (no second round-trip for metadata):
//!
//! | Header | Meaning |
//! |--------|---------|
//! | `X-Crumb-Sprite-Start-Ms` | segment start, epoch ms (tile 0's instant) |
//! | `X-Crumb-Sprite-End-Ms` | segment end, epoch ms (exclusive) |
//! | `X-Crumb-Sprite-Interval-Ms` | time between tiles (1000) |
//! | `X-Crumb-Sprite-Tiles` | number of tiles |
//! | `X-Crumb-Sprite-Columns` | tiles per row (= tiles; one row) |
//! | `X-Crumb-Sprite-Tile-Width` | tile width in px (tile height = image height / rows) |

use std::path::{Path as FsPath, PathBuf};
use std::time::Duration;

use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderName, StatusCode},
    response::IntoResponse,
    routing::get,
    Router,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use tokio::process::Command;
use uuid::Uuid;

use crumb_common::{db, types::Segment};

use crate::{auth_mw::MediaOrFullUser, error::ApiError, state::AppState};

/// Tile width in pixels. Small on purpose: a sprite is a scrub preview shown
/// while the cursor moves, and four 160 px tiles are ~10-20 KiB in total.
pub(crate) const SPRITE_TILE_WIDTH: u32 = 160;

/// Time between tiles.
pub(crate) const SPRITE_INTERVAL_MS: i64 = 1000;

/// Upper bound on tiles per sprite, so a pathological segment row (a camera
/// configured with a long `SEGMENT_SECONDS`, or a bad `duration_ms`) can't ask
/// ffmpeg for an enormous strip.
const SPRITE_MAX_TILES: u32 = 16;

/// Subdirectory (per camera, under `.thumbs/{camera}/`) holding sprites.
const SPRITES_SUBDIR: &str = "sprites";

/// Same `.thumbs` root the 4 s-grid frames use (see `filmstrip.rs`).
const THUMBS_SUBDIR: &str = ".thumbs";

/// ffmpeg binary (same path the frame extractor and export pipeline use).
const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";

/// Hard cap on one sprite render (a few keyframe decodes; measured at
/// 0.15-0.55 s CPU per 4 s segment for 1080p-4K HEVC/H.264).
const SPRITE_RENDER_TIMEOUT_SECS: u64 = 20;

/// Unique temp-file suffixes for atomic sprite writes.
static TMP_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// How many segment ids one orphan-check query carries.
const ORPHAN_CHECK_CHUNK: usize = 2000;

const H_START: HeaderName = HeaderName::from_static("x-crumb-sprite-start-ms");
const H_END: HeaderName = HeaderName::from_static("x-crumb-sprite-end-ms");
const H_INTERVAL: HeaderName = HeaderName::from_static("x-crumb-sprite-interval-ms");
const H_TILES: HeaderName = HeaderName::from_static("x-crumb-sprite-tiles");
const H_COLUMNS: HeaderName = HeaderName::from_static("x-crumb-sprite-columns");
const H_TILE_WIDTH: HeaderName = HeaderName::from_static("x-crumb-sprite-tile-width");

// ─── route registry ───────────────────────────────────────────────────────────

/// Mount the sprite route (media router: same timeout + rate-limit layers as
/// the filmstrip frame endpoint).
pub fn routes() -> Router<AppState> {
    Router::new().route("/filmstrip/:camera_id/sprite", get(serve_sprite))
}

/// Query parameters for `GET /filmstrip/{camera_id}/sprite`.
#[derive(Debug, Deserialize)]
pub struct SpriteQuery {
    /// Any instant inside the wanted segment.
    pub ts: DateTime<Utc>,
}

// ─── layout + paths ───────────────────────────────────────────────────────────

/// Number of tiles for a segment of `duration_ms`: one per started
/// [`SPRITE_INTERVAL_MS`], at least 1, at most [`SPRITE_MAX_TILES`]. Pure and
/// deterministic, because the tile count is part of the cache key: the
/// generator and the serve path must always agree on it.
pub(crate) fn sprite_tiles(duration_ms: i64) -> u32 {
    let d = duration_ms.max(1);
    let n = (d + SPRITE_INTERVAL_MS - 1) / SPRITE_INTERVAL_MS;
    u32::try_from(n)
        .unwrap_or(SPRITE_MAX_TILES)
        .clamp(1, SPRITE_MAX_TILES)
}

/// A segment's duration as the sprite sees it: the row's `end_ts - start_ts`
/// (what the timeline and the clients use), falling back to `duration_ms`.
fn segment_span_ms(seg: &Segment) -> i64 {
    let span = (seg.end_ts - seg.start_ts).num_milliseconds();
    if span > 0 {
        span
    } else {
        i64::from(seg.duration_ms)
    }
}

/// `{base}/.thumbs/{camera}/sprites` for a camera.
fn sprites_dir(base: &str, camera_id: Uuid) -> PathBuf {
    PathBuf::from(base)
        .join(THUMBS_SUBDIR)
        .join(camera_id.to_string())
        .join(SPRITES_SUBDIR)
}

/// File name for a segment's sprite. Encodes the tile width and count so a
/// future change to either can never serve a stale layout.
fn sprite_file_name(segment_id: Uuid, tiles: u32) -> String {
    format!("{segment_id}_w{SPRITE_TILE_WIDTH}_t{tiles}.jpg")
}

/// Parse a sprite file name back to its segment id. `None` for anything that
/// is not exactly a sprite this module wrote (the orphan sweeper only ever
/// deletes files this returns `Some` for).
fn parse_sprite_file_name(name: &str) -> Option<Uuid> {
    let stem = name.strip_suffix(".jpg")?;
    let (id, rest) = stem.split_once("_w")?;
    let (w, t) = rest.split_once("_t")?;
    if w.is_empty() || t.is_empty() || !w.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if !t.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Uuid::parse_str(id).ok()
}

/// `(sprites_dir, sprite_file)` for a segment.
pub(crate) fn sprite_path(base: &str, seg: &Segment) -> (PathBuf, PathBuf) {
    let dir = sprites_dir(base, seg.camera_id);
    let tiles = sprite_tiles(segment_span_ms(seg));
    let file = dir.join(sprite_file_name(seg.id, tiles));
    (dir, file)
}

// ─── GET /filmstrip/{camera_id}/sprite ────────────────────────────────────────

/// Serve the sprite strip for the main-stream segment covering `ts`.
///
/// 404 when no segment covers `ts`, or when its sprite has not been
/// generated (pre-generation off, or not caught up yet): the client then falls
/// back to the per-frame endpoint. Never renders on demand.
async fn serve_sprite(
    // Media-read, like the frame endpoint: fetched with a scoped `?token=`.
    // Capability + per-camera scope enforced below.
    MediaOrFullUser(user): MediaOrFullUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
    Query(q): Query<SpriteQuery>,
) -> Result<impl IntoResponse, ApiError> {
    use tokio_util::io::ReaderStream;

    user.require_playback()?;
    user.assert_camera_access(camera_id)?;

    let seg = db::resolve_segment(state.pool(), camera_id, q.ts, "main")
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| {
            ApiError::NotFound(format!(
                "no footage at {} for camera {camera_id}",
                q.ts.to_rfc3339()
            ))
        })?;

    let base = state.config().thumb_cache_base();
    let (dir, file) = sprite_path(base, &seg);
    let not_generated = || {
        ApiError::NotFound(format!(
            "no scrub sprite generated yet for segment {}",
            seg.id
        ))
    };

    // Path traversal guard (defense in depth: the path is built only from two
    // UUIDs and integers, but it is canonicalized and checked like the frame
    // endpoint's).
    let canonical_dir = tokio::fs::canonicalize(&dir)
        .await
        .map_err(|_| not_generated())?;
    let canonical_file = tokio::fs::canonicalize(&file)
        .await
        .map_err(|_| not_generated())?;
    if !canonical_file.starts_with(&canonical_dir) {
        tracing::warn!(%camera_id, path = %canonical_file.display(), "sprite path guard rejected request");
        return Err(ApiError::BadRequest(
            "resolved path escapes the sprite directory".to_owned(),
        ));
    }

    let f = tokio::fs::File::open(&canonical_file)
        .await
        .map_err(|_| not_generated())?;
    let len = f
        .metadata()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("stat sprite: {e}")))?
        .len();

    let tiles = sprite_tiles(segment_span_ms(&seg));
    let body = axum::body::Body::from_stream(ReaderStream::new(f));
    axum::response::Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "image/jpeg")
        .header(header::CONTENT_LENGTH, len.to_string())
        // Immutable for the segment's lifetime, but the segment itself can be
        // deleted by retention: keep it private and bounded rather than the
        // frame endpoint's day-long public cache.
        .header(header::CACHE_CONTROL, "private, max-age=3600")
        .header(H_START, seg.start_ts.timestamp_millis().to_string())
        .header(H_END, seg.end_ts.timestamp_millis().to_string())
        .header(H_INTERVAL, SPRITE_INTERVAL_MS.to_string())
        .header(H_TILES, tiles.to_string())
        .header(H_COLUMNS, tiles.to_string())
        .header(H_TILE_WIDTH, SPRITE_TILE_WIDTH.to_string())
        .body(body)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build sprite response: {e}")))
}

// ─── generation (pre-generation worker only) ──────────────────────────────────

/// Ensure the sprite for `seg` exists, rendering it once under the shared
/// singleflight lock and extraction semaphore if absent. Called only by the
/// background pre-generation worker. Returns `Ok(true)` when a sprite was
/// rendered, `Ok(false)` when it already existed (or the segment vanished).
pub(crate) async fn ensure_sprite(state: &AppState, seg: &Segment) -> Result<bool, ApiError> {
    let (dir, file) = sprite_path(state.config().thumb_cache_base(), seg);
    if tokio::fs::metadata(&file).await.is_ok() {
        return Ok(false);
    }
    let lock = state.thumb_inflight_lock(&file);
    let _flight = lock.lock().await;
    if tokio::fs::metadata(&file).await.is_ok() {
        return Ok(false);
    }

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

    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("create sprites dir: {e}")))?;

    let seq = TMP_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut tmp_os = file.as_os_str().to_owned();
    tmp_os.push(format!(".tmp{seq}"));
    let tmp = PathBuf::from(tmp_os);

    // Same bounded semaphore as on-demand frame extraction, so the worker and
    // live scrub requests share one CPU budget.
    let _permit = crate::media_limits::acquire_bounded(
        &state.thumb_semaphore(),
        crate::media_limits::THUMB_EXTRACT_WAIT,
        "scrub sprite render",
    )
    .await?;

    let tiles = sprite_tiles(segment_span_ms(seg));
    let args = sprite_ffmpeg_args(tiles, &seg_abs.to_string_lossy(), &tmp.to_string_lossy());
    let child = Command::new(FFMPEG_BIN)
        .args(&args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("spawn ffmpeg: {e}")))?;
    let out = tokio::time::timeout(
        Duration::from_secs(SPRITE_RENDER_TIMEOUT_SECS),
        child.wait_with_output(),
    )
    .await
    .map_err(|_| ApiError::Internal(anyhow::anyhow!("sprite render timed out")))?
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("ffmpeg wait: {e}")))?;

    if !out.status.success() || tokio::fs::metadata(&tmp).await.is_err() {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(ApiError::NotFound(format!(
            "could not render a scrub sprite for segment {}",
            seg.id
        )));
    }
    tokio::fs::rename(&tmp, &file).await.map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        ApiError::Internal(anyhow::anyhow!("finalize sprite: {e}"))
    })?;

    // Close the "segment deleted while its sprite was rendering" race: if the
    // row is gone now, drop the file we just published.
    if !segment_still_exists(state, seg.id).await {
        let _ = tokio::fs::remove_file(&file).await;
        return Ok(false);
    }
    Ok(true)
}

/// Whether `id` is still in `segments`. Fails "exists" on a DB error: the
/// orphan sweeper will catch it on a later pass.
async fn segment_still_exists(state: &AppState, id: Uuid) -> bool {
    match db::existing_segment_ids(state.pool(), &[id]).await {
        Ok(alive) => alive.contains(&id),
        Err(_) => true,
    }
}

/// ffmpeg arguments for a sprite strip of `tiles` tiles.
///
/// * `-skip_frame nokey`: decode keyframes only. Every camera in the
///   benchmark fixture set keys once per second, so this still yields one
///   distinct frame per tile at a fraction of a full decode; a longer GOP
///   simply repeats the previous keyframe (the same "keyframe at or before"
///   rule the frame endpoint uses).
/// * `fps=1` picks the frame for each one-second slot. The `fps` filter holds
///   the last input frame back until it sees a later one, so the first frame
///   is split off, re-stamped at `tiles` seconds and appended as a sentinel:
///   that releases the final slot without decoding anything extra, and the
///   sentinel itself lands past the last tile and is never drawn.
/// * `tile={tiles}x1` + `-frames:v 1`: one row, one output image.
/// * `-f mjpeg`: the temp output ends in `.tmp{n}` (see the frame extractor).
fn sprite_ffmpeg_args(tiles: u32, input: &str, output: &str) -> Vec<String> {
    let filter = format!(
        "[0:v]setpts=PTS-STARTPTS,split[a][s];\
         [s]trim=end_frame=1,setpts=PTS-STARTPTS+{tiles}/TB[b];\
         [a][b]concat=n=2:v=1:a=0,fps=1,scale={SPRITE_TILE_WIDTH}:-2,setsar=1,tile={tiles}x1"
    );
    vec![
        "-y".to_owned(),
        "-threads".to_owned(),
        "1".to_owned(),
        "-skip_frame".to_owned(),
        "nokey".to_owned(),
        "-i".to_owned(),
        input.to_owned(),
        "-an".to_owned(),
        "-filter_complex".to_owned(),
        filter,
        "-frames:v".to_owned(),
        "1".to_owned(),
        "-q:v".to_owned(),
        "5".to_owned(),
        "-f".to_owned(),
        "mjpeg".to_owned(),
        output.to_owned(),
    ]
}

// ─── orphan sweep ─────────────────────────────────────────────────────────────

/// Delete every sprite under `{base}/.thumbs/*/sprites/` whose segment no
/// longer exists. Returns how many files were removed.
///
/// GUARDED like the `.thumbs` sweeper: only files whose name parses as a
/// sprite this module wrote, inside the canonical `.thumbs` root, are ever
/// touched. A DB error skips that batch entirely (never deletes on doubt).
pub(crate) async fn sweep_orphan_sprites(pool: &deadpool_postgres::Pool, base: &str) -> usize {
    let Ok(root) = tokio::fs::canonicalize(FsPath::new(base).join(THUMBS_SUBDIR)).await else {
        return 0;
    };
    let mut candidates: Vec<(Uuid, PathBuf)> = Vec::new();
    let Ok(mut cams) = tokio::fs::read_dir(&root).await else {
        return 0;
    };
    while let Ok(Some(cam)) = cams.next_entry().await {
        let dir = cam.path().join(SPRITES_SUBDIR);
        let Ok(mut rd) = tokio::fs::read_dir(&dir).await else {
            continue;
        };
        while let Ok(Some(e)) = rd.next_entry().await {
            let path = e.path();
            if !path.starts_with(&root) {
                continue;
            }
            let Some(id) = path
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(parse_sprite_file_name)
            else {
                continue;
            };
            if e.metadata().await.is_ok_and(|m| m.is_file()) {
                candidates.push((id, path));
            }
        }
    }

    let mut removed = 0;
    for chunk in candidates.chunks(ORPHAN_CHECK_CHUNK) {
        let ids: Vec<Uuid> = chunk.iter().map(|(id, _)| *id).collect();
        let Ok(alive) = db::existing_segment_ids(pool, &ids).await else {
            continue;
        };
        for (id, path) in chunk {
            if !alive.contains(id) && tokio::fs::remove_file(path).await.is_ok() {
                removed += 1;
            }
        }
    }
    removed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiles_one_per_started_second_clamped() {
        assert_eq!(sprite_tiles(4000), 4);
        assert_eq!(sprite_tiles(3999), 4);
        assert_eq!(sprite_tiles(3001), 4);
        assert_eq!(sprite_tiles(3000), 3);
        assert_eq!(sprite_tiles(1), 1);
        assert_eq!(sprite_tiles(0), 1, "a zero-length row still names one tile");
        assert_eq!(sprite_tiles(-5), 1);
        assert_eq!(sprite_tiles(600_000), SPRITE_MAX_TILES);
    }

    #[test]
    fn file_name_round_trips_and_rejects_strangers() {
        let id = Uuid::new_v4();
        let name = sprite_file_name(id, 4);
        assert_eq!(name, format!("{id}_w160_t4.jpg"));
        assert_eq!(parse_sprite_file_name(&name), Some(id));
        // Things the orphan sweeper must never treat as a sprite.
        for bad in [
            "0000000001000_w160.jpg",
            &format!("{id}_w160_t4.jpg.tmp3"),
            &format!("{id}_w160_t4.mp4"),
            &format!("{id}_wx_t4.jpg"),
            &format!("{id}_w160_t.jpg"),
            "not-a-uuid_w160_t4.jpg",
            "segment.mp4",
        ] {
            assert_eq!(parse_sprite_file_name(bad), None, "{bad}");
        }
    }

    #[test]
    fn ffmpeg_args_keyframe_only_single_row_forced_mjpeg() {
        let args = sprite_ffmpeg_args(4, "/data/live/cam/seg.mp4", "/c/x.jpg.tmp1");
        let i = args.iter().position(|a| a == "-i").unwrap();
        let skip = args.iter().position(|a| a == "-skip_frame").unwrap();
        assert!(skip < i, "-skip_frame must be an input option");
        assert_eq!(args[skip + 1], "nokey");
        let f = args.iter().position(|a| a == "-f").unwrap();
        assert_eq!(args[f + 1], "mjpeg");
        assert_eq!(args.last().unwrap(), "/c/x.jpg.tmp1");
        let fc = &args[args.iter().position(|a| a == "-filter_complex").unwrap() + 1];
        assert!(fc.contains("tile=4x1"), "{fc}");
        assert!(fc.contains("fps=1"), "{fc}");
        assert!(
            fc.contains("+4/TB"),
            "sentinel must sit at the tile count: {fc}"
        );
        assert!(fc.contains("scale=160:-2"), "{fc}");
    }
}
