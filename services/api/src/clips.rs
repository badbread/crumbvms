// SPDX-License-Identifier: AGPL-3.0-or-later

//! Clips API: a unified, source-abstracted feed of short clips for the Clips
//! tab.
//!
//! Phase 0: the LIST endpoint only. Detections come from the `events` table;
//! motion "events" are derived on the fly from contiguous `has_motion` segment
//! runs. Each descriptor carries `clip_url`/`thumbnail_url` (media served in
//! later phases) and a resolved `source`: per-camera `clip_source` with the
//! global-default fallback for detections; motion is always `"crumb"` (own
//! footage), since Frigate has no motion clips.

use std::collections::HashMap;
use std::path::{Path as FsPath, PathBuf};

use axum::{
    body::Body,
    extract::{Path, Query, Request, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Duration, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tower::ServiceExt as _;
use tower_http::services::ServeFile;
use uuid::Uuid;

use crumb_common::{db, types::Segment};

use crate::{auth_mw::AuthUser, error::ApiError, state::AppState};

/// Mount `GET /clips` (authenticated JSON route).
pub fn json_routes() -> Router<AppState> {
    Router::new()
        .route("/clips", get(get_clips))
        .route("/clips/viewed", post(mark_viewed))
}

/// Query parameters for `GET /clips`.
#[derive(Debug, Deserialize)]
pub struct ClipsQuery {
    /// Comma-separated camera UUIDs (viewer-scoped).
    pub camera_ids: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// `"detection"` | `"motion"` | `"all"` (default `"all"`).
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub limit: Option<i64>,
}

/// A single clip in the `/clips` response. Source-abstracted: clients render the
/// feed and play `clip_url` without knowing whether it is Frigate- or
/// Crumb-backed.
#[derive(Debug, Serialize)]
pub struct ClipDescriptor {
    /// Opaque handle. `"d:<event-uuid>"` for detections,
    /// `"m:<camera>:<start_ms>:<end_ms>"` for motion. The media endpoints (later
    /// phases) parse this prefix.
    pub id: String,
    pub camera_id: Uuid,
    pub camera_name: String,
    /// `"detection"` | `"motion"`.
    pub kind: String,
    /// Object label for detections; `"motion"` for motion clips.
    pub label: String,
    /// Client glyph/colour selector (the label slug; `"motion"` for motion).
    pub icon_key: String,
    /// Detection confidence (`0.0..=1.0`); `null` for motion.
    pub score: Option<f32>,
    pub start_ts: DateTime<Utc>,
    pub end_ts: DateTime<Utc>,
    pub duration_ms: i64,
    pub thumbnail_url: String,
    /// Lightweight preview MP4 (reduced resolution + frame rate) — the default
    /// the feed players use. Fast to generate, small to cache.
    pub clip_url: String,
    /// Full-resolution MP4 for an explicit "full quality" / download action.
    pub download_url: String,
    /// Resolved media source: `"frigate"` | `"crumb"`.
    pub source: String,
    /// True if the requesting user has already opened this clip — clients render
    /// watched cards subtly dimmer.
    pub viewed: bool,
    /// True while the underlying event is still open (`end_ts` NULL) — the clip is
    /// an overview of the event's opening seconds, and the event has no known end
    /// yet. Always false for motion clips (both bounds are known). Clients render
    /// an "ongoing" badge and treat the clip as a truncated overview.
    pub ongoing: bool,
    /// Normalized `[x, y, w, h]` (0..1 of the frame) of where the motion was, for
    /// the clip player's motion-highlight auto-zoom. Present for motion clips that
    /// captured a region; `null` for detections and bbox-less motion clips.
    pub motion_bbox: Option<[f32; 4]>,
}

/// `GET /clips` response.
#[derive(Debug, Serialize)]
pub struct ClipsResponse {
    pub clips: Vec<ClipDescriptor>,
    pub total: usize,
    /// Server-configured motion-highlight duration (seconds; 0 = disabled). The
    /// clip player auto-zooms to `motion_bbox` for this long at the start of a
    /// motion clip, then eases back to the full frame.
    pub motion_highlight_seconds: i64,
    /// Server-configured clip overview length (seconds) — how long each clip
    /// renders. Clients compute `truncated = ongoing || duration_ms >
    /// overview_seconds * 1000` to show "N s overview — full event H:MM · View on
    /// timeline" without a second round-trip.
    pub overview_seconds: i64,
}

/// A normalized motion region `[x, y, w, h]` (0..1 fractions of the frame).
type MotionBbox = [f32; 4];
/// One candidate segment fed to [`motion_runs`]: `(start, end, has_motion, bbox)`.
type MotionItem = (DateTime<Utc>, DateTime<Utc>, bool, Option<MotionBbox>);
/// A merged motion event: `(start, end, onset_bbox)`.
type MotionRun = (DateTime<Utc>, DateTime<Utc>, Option<MotionBbox>);

const DEFAULT_LIMIT: i64 = 500;
const MAX_LIMIT: i64 = 2_000;
/// Hard cap on how far back a single `/clips` request may scan, regardless of
/// the client's `start`. Bounds the per-camera segment scan + motion derivation
/// cost; clients offer a days selector well within this.
const MAX_CLIP_WINDOW_DAYS: i64 = 31;
/// Motion segments separated by <= this gap merge into one motion event.
const MOTION_MERGE_GAP_MS: i64 = 30_000;
/// Drop motion runs shorter than this (debounce flicker).
const MOTION_MIN_DURATION_MS: i64 = 1_000;

/// `GET /clips?camera_ids=<csv>&start=<iso>&end=<iso>[&type=all|detection|motion][&limit=N]`
///
/// Returns a newest-first, source-abstracted feed of detection and/or motion
/// clips for the requested cameras within `[start, end)`. Viewer camera scope is
/// enforced; out-of-scope cameras yield zero rows.
async fn get_clips(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<ClipsQuery>,
) -> Result<Json<ClipsResponse>, ApiError> {
    user.require_clips()?;
    let requested = parse_uuid_csv(&q.camera_ids)?;
    let camera_ids = user.filter_camera_ids(&requested);
    if camera_ids.is_empty() {
        return Ok(Json(ClipsResponse {
            clips: vec![],
            total: 0,
            motion_highlight_seconds: 0,
            overview_seconds: db::get_clip_overview_seconds(state.pool())
                .await
                .map_err(ApiError::Internal)?,
        }));
    }
    if q.start >= q.end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }
    // Clamp the scan window so an over-eager client can't request an unbounded
    // history in one shot.
    let max_window = Duration::days(MAX_CLIP_WINDOW_DAYS);
    let start = if q.end - q.start > max_window {
        q.end - max_window
    } else {
        q.start
    };
    let want = q.kind.as_deref().unwrap_or("all");
    let want_det = matches!(want, "all" | "detection");
    let want_mot = matches!(want, "all" | "motion");
    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);

    // Camera names + per-camera source overrides (+ the global default).
    let cams = db::list_clip_cameras(state.pool(), &camera_ids)
        .await
        .map_err(ApiError::Internal)?;
    let default_source = db::get_default_clip_source(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    let name_by: HashMap<Uuid, String> = cams.iter().map(|c| (c.id, c.name.clone())).collect();
    let source_by: HashMap<Uuid, String> = cams
        .iter()
        .map(|c| {
            let src = c
                .clip_source
                .clone()
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| default_source.clone());
            (c.id, src)
        })
        .collect();

    let mut clips: Vec<ClipDescriptor> = Vec::new();

    // ── Detections (events table; source = per-camera resolved) ──
    if want_det {
        let dq = db::DetectionEventQuery {
            camera_ids: camera_ids.clone(),
            start,
            end: q.end,
            labels: None,
            limit,
            offset: 0,
        };
        let (rows, _total) = db::list_detection_events(state.pool(), &dq)
            .await
            .map_err(ApiError::Internal)?;
        for r in rows {
            // Motion-labelled detection events duplicate the segment-derived motion
            // clips below — skip them so the feed isn't double-counted.
            if r.label == "motion" {
                continue;
            }
            // `ongoing` = the event is still open (no end yet). Preserve that here
            // rather than destroying it with the `unwrap_or(r.ts)` fallback, so the
            // feed can render an "ongoing" badge and treat the clip as a truncated
            // overview. `end_ts`/`duration_ms` stay EVENT truth (the timeline shows
            // the whole thing).
            let ongoing = r.end_ts.is_none();
            let end = r.end_ts.unwrap_or(r.ts);
            let id = format!("d:{}", r.id);
            clips.push(ClipDescriptor {
                camera_name: name_by.get(&r.camera_id).cloned().unwrap_or_default(),
                source: source_by
                    .get(&r.camera_id)
                    .cloned()
                    .unwrap_or_else(|| "crumb".to_owned()),
                duration_ms: (end - r.ts).num_milliseconds().max(0),
                thumbnail_url: format!("/clip/{id}/thumbnail.jpg"),
                clip_url: format!("/clip/{id}/clip.mp4?q=preview"),
                download_url: format!("/clip/{id}/clip.mp4?q=full"),
                kind: "detection".to_owned(),
                label: r.label,
                icon_key: r.icon_key,
                score: Some(r.score),
                start_ts: r.ts,
                end_ts: end,
                camera_id: r.camera_id,
                viewed: false,
                ongoing,
                motion_bbox: None,
                id,
            });
        }
    }

    // ── Motion (contiguous has_motion segment runs; always Crumb own-footage) ──
    if want_mot {
        for &cam in &camera_ids {
            let segs = db::list_segments_for_range(state.pool(), cam, "main", start, q.end)
                .await
                .map_err(ApiError::Internal)?;
            let items: Vec<MotionItem> = segs
                .iter()
                .map(|s| (s.start_ts, s.end_ts, s.has_motion, s.motion_bbox))
                .collect();
            for (a, b, bbox) in motion_runs(&items) {
                let id = format!(
                    "m:{}:{}:{}",
                    cam,
                    a.timestamp_millis(),
                    b.timestamp_millis()
                );
                clips.push(ClipDescriptor {
                    camera_name: name_by.get(&cam).cloned().unwrap_or_default(),
                    source: "crumb".to_owned(),
                    duration_ms: (b - a).num_milliseconds().max(0),
                    thumbnail_url: format!("/clip/{id}/thumbnail.jpg"),
                    clip_url: format!("/clip/{id}/clip.mp4?q=preview"),
                    download_url: format!("/clip/{id}/clip.mp4?q=full"),
                    kind: "motion".to_owned(),
                    label: "motion".to_owned(),
                    icon_key: "motion".to_owned(),
                    score: None,
                    start_ts: a,
                    end_ts: b,
                    camera_id: cam,
                    viewed: false,
                    // Motion clips always have a known end (both bounds encoded in
                    // the id), so they are never ongoing.
                    ongoing: false,
                    motion_bbox: bbox,
                    id,
                });
            }
        }
    }

    // Newest first, capped.
    clips.sort_by_key(|c| std::cmp::Reverse(c.start_ts));
    clips.truncate(limit as usize);

    // Stamp the per-user "watched" flag in one round-trip over the capped set.
    let ids: Vec<String> = clips.iter().map(|c| c.id.clone()).collect();
    let seen = db::viewed_clip_ids(state.pool(), user.user_id, &ids)
        .await
        .map_err(ApiError::Internal)?;
    for c in &mut clips {
        c.viewed = seen.contains(&c.id);
    }

    let motion_highlight_seconds = db::get_clip_motion_highlight_seconds(state.pool())
        .await
        .map_err(ApiError::Internal)?;
    let overview_seconds = db::get_clip_overview_seconds(state.pool())
        .await
        .map_err(ApiError::Internal)?;

    let total = clips.len();
    Ok(Json(ClipsResponse {
        clips,
        total,
        motion_highlight_seconds,
        overview_seconds,
    }))
}

/// Body for `POST /clips/viewed`.
#[derive(Debug, Deserialize)]
pub struct MarkViewedRequest {
    pub id: String,
}

/// `POST /clips/viewed` — mark a clip as watched by the current user. Idempotent;
/// returns 204. Clients call this when the user opens a clip.
async fn mark_viewed(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<MarkViewedRequest>,
) -> Result<axum::http::StatusCode, ApiError> {
    user.require_clips()?;
    db::mark_clip_viewed(state.pool(), user.user_id, &body.id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

/// Merge contiguous motion segments into motion events: join runs whose gap is
/// <= [`MOTION_MERGE_GAP_MS`] and drop runs shorter than
/// [`MOTION_MIN_DURATION_MS`]. Input must be sorted by start
/// (`list_segments_for_range` orders by `start_ts`). Returns
/// `(start, end, motion_bbox)`, where the bbox is the FIRST captured region in the
/// run (chronologically) — the event's onset, which is what the motion-highlight
/// auto-zoom plays over at the start of the clip.
fn motion_runs(items: &[MotionItem]) -> Vec<MotionRun> {
    let mut runs: Vec<MotionRun> = Vec::new();
    for &(start, end, _, bbox) in items.iter().filter(|i| i.2) {
        if let Some(last) = runs.last_mut() {
            if (start - last.1).num_milliseconds() <= MOTION_MERGE_GAP_MS {
                if end > last.1 {
                    last.1 = end;
                }
                // Keep the earliest captured region for the run.
                if last.2.is_none() {
                    last.2 = bbox;
                }
                continue;
            }
        }
        runs.push((start, end, bbox));
    }
    runs.into_iter()
        .filter(|(a, b, _)| (*b - *a).num_milliseconds() >= MOTION_MIN_DURATION_MS)
        .collect()
}

fn parse_uuid_csv(csv: &str) -> Result<Vec<Uuid>, ApiError> {
    csv.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| {
            s.parse::<Uuid>().map_err(|_| {
                ApiError::BadRequest(format!("'{s}' is not a valid UUID in camera_ids"))
            })
        })
        .collect()
}

// ── media: clip.mp4 + thumbnail.jpg (Phase 1: Crumb own-footage generation) ─────

const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";
/// Post-roll padding after a clip's event window (pre-roll is an admin setting).
const POST_ROLL_MS: i64 = 8_000;

/// Compiled hard ceiling on a rendered clip's length (seconds), and the
/// permanent safety floor of the clip-overview model. A clip is an **overview**
/// of an event — a short, representative snippet — NOT the full event: to watch a
/// whole event the operator opens the timeline (which streams segments directly,
/// with no whole-event transcode). The render length is the admin-tunable
/// `clip_overview_seconds` setting (default 30, clamped 10..=120), and this
/// constant is the second lock: even if that setting were somehow out of range,
/// the render window can never exceed 120 s, so a broken `end_ts` (never closed →
/// "until now", or a 10-hour event) can never again make the renderer concat
/// thousands of 4 s segments into a multi-hour transcode — which in prod
/// (2026-07-16) pinned the API at 600%+ CPU and starved ALL clip playback. Equals
/// `db::CLIP_OVERVIEW_SECONDS_MAX`. See docs/design/CLIP-MODEL.md §2.1.
const MAX_CLIP_MEDIA_SECS: i64 = 120;

/// Compute the overview render window for an event `[ev_start, ev_end?)`:
/// `[ev_start − pre, min(ev_start − pre + overview, ev_end + post))`, then capped
/// at the compiled hard ceiling ([`MAX_CLIP_MEDIA_SECS`]) and guarded against an
/// inverted (`end < start`) window. A short closed event keeps its natural length
/// (the truncation term wins); a long one caps at the overview length. For an
/// **ongoing** event (`ev_end` = `None`) there is no natural end to truncate to,
/// so the window is the full overview length — missing-tail footage truncates
/// naturally at render time (`prepare_clip_inputs` only concats existing
/// segments). See docs/design/CLIP-MODEL.md §2.1.
fn overview_window(
    ev_start: DateTime<Utc>,
    ev_end: Option<DateTime<Utc>>,
    pre_secs: i64,
    overview_secs: i64,
) -> (DateTime<Utc>, DateTime<Utc>) {
    let win_start = ev_start - Duration::seconds(pre_secs);
    let hard_cap = win_start + Duration::seconds(MAX_CLIP_MEDIA_SECS);
    let mut win_end = win_start + Duration::seconds(overview_secs);
    if let Some(end) = ev_end {
        // Closed event: truncate to the event end (+ post-roll) so a short blip
        // stays a short clip rather than padding out to the full overview length.
        win_end = win_end.min(end + Duration::milliseconds(POST_ROLL_MS));
    }
    win_end = win_end.min(hard_cap).max(win_start);
    (win_start, win_end)
}

/// A resolved clip window plus the metadata the media handlers need: the tunable
/// window parameters (part of the cache key/ETag, so a settings change never
/// serves a stale rendition), whether the underlying event is still open, and the
/// raw event bounds (for the Frigate-proxy duration gate).
struct ResolvedClip {
    camera_id: Uuid,
    /// Render window start = event onset − pre-roll.
    start: DateTime<Utc>,
    /// Render window end = overview-capped (and hard-ceiling-capped) end.
    end: DateTime<Utc>,
    /// Resolved `clip_overview_seconds` — part of the cache key/ETag.
    overview_secs: i64,
    /// Resolved `clip_pre_roll_seconds` — part of the cache key/ETag.
    pre_secs: i64,
    /// The event is still open (`end_ts` NULL). Only meaningful for detection
    /// (`d:`) clips; always false for motion (`m:`) clips (both bounds are known).
    ongoing: bool,
    /// Raw event start, for the Frigate-proxy duration gate.
    event_start: DateTime<Utc>,
    /// Raw event end, for the Frigate-proxy duration gate. `None` while ongoing.
    event_end: Option<DateTime<Utc>>,
}

/// Mount the clip media routes. Mounted in `media_routes` (no JSON timeout —
/// generation can take a few seconds). `AuthUser` accepts `?token=`, so these
/// serve directly as `<video>`/`<img>` sources.
pub fn media_routes() -> Router<AppState> {
    Router::new()
        .route("/clip/:id/clip.mp4", get(get_clip_media))
        .route("/clip/:id/thumbnail.jpg", get(get_clip_thumbnail))
}

/// Resolve a clip id to its overview render window + metadata. Pre-roll and
/// overview length are admin-configurable server settings (defaults 2s / 30s,
/// clamped 0..=9 and 10..=120); post-roll is fixed. See [`overview_window`].
async fn resolve_clip(state: &AppState, id: &str) -> Result<ResolvedClip, ApiError> {
    let pre_secs = db::get_clip_pre_roll_seconds(state.pool())
        .await
        .unwrap_or(2);
    let overview_secs = db::get_clip_overview_seconds(state.pool())
        .await
        .unwrap_or(30);
    if let Some(ev) = id.strip_prefix("d:") {
        let ev = ev
            .parse::<Uuid>()
            .map_err(|_| ApiError::BadRequest("malformed clip id".to_owned()))?;
        let (cam, ev_start, ev_end) = db::get_clip_event_window(state.pool(), ev)
            .await
            .map_err(ApiError::Internal)?
            .ok_or_else(|| ApiError::NotFound(format!("clip {id} not found")))?;
        let (start, end) = overview_window(ev_start, ev_end, pre_secs, overview_secs);
        Ok(ResolvedClip {
            camera_id: cam,
            start,
            end,
            overview_secs,
            pre_secs,
            ongoing: ev_end.is_none(),
            event_start: ev_start,
            event_end: ev_end,
        })
    } else if let Some(rest) = id.strip_prefix("m:") {
        let mut it = rest.split(':');
        let cam = it.next().and_then(|s| s.parse::<Uuid>().ok());
        let s_ms = it.next().and_then(|s| s.parse::<i64>().ok());
        let e_ms = it.next().and_then(|s| s.parse::<i64>().ok());
        match (cam, s_ms, e_ms) {
            (Some(cam), Some(s), Some(e)) => {
                let ev_start = Utc
                    .timestamp_millis_opt(s)
                    .single()
                    .ok_or_else(|| ApiError::BadRequest("malformed clip ts".to_owned()))?;
                let ev_end = Utc
                    .timestamp_millis_opt(e)
                    .single()
                    .ok_or_else(|| ApiError::BadRequest("malformed clip ts".to_owned()))?;
                let (start, end) = overview_window(ev_start, Some(ev_end), pre_secs, overview_secs);
                Ok(ResolvedClip {
                    camera_id: cam,
                    start,
                    end,
                    overview_secs,
                    pre_secs,
                    ongoing: false,
                    event_start: ev_start,
                    event_end: Some(ev_end),
                })
            }
            _ => Err(ApiError::BadRequest("malformed clip id".to_owned())),
        }
    } else {
        Err(ApiError::BadRequest("unknown clip id".to_owned()))
    }
}

/// Filesystem-safe form of a clip id (`:` etc. → `_`).
fn sanitize_id(id: &str) -> String {
    id.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

fn seg_abs_path(storage_paths: &HashMap<Uuid, String>, seg: &Segment) -> Result<PathBuf, ApiError> {
    let root = storage_paths.get(&seg.storage_id).ok_or_else(|| {
        ApiError::Internal(anyhow::anyhow!(
            "segment {} storage {} missing",
            seg.id,
            seg.storage_id
        ))
    })?;
    Ok(PathBuf::from(root).join(&seg.path))
}

/// Media quality selector for `GET /clip/:id/clip.mp4?q=preview|full`.
#[derive(Debug, Deserialize)]
pub struct MediaQuery {
    /// `"preview"` (default — small, reduced res/fps) | `"full"` (source res).
    pub q: Option<String>,
}

/// `GET /clip/{id}/clip.mp4` — generate (once, cached) + serve from our footage.
/// `?q=preview` (default) returns a small reduced-res/fps clip; `?q=full`
/// returns a source-resolution clip. Both renditions are the same overview
/// window (§2.6): generated once to a seekable faststart file and served with
/// `ServeFile` (Range/206), so the transcode semaphore covers only the transcode
/// — never the client's read — and client retries are idempotent. Cached
/// separately per quality, keyed by the window parameters so a settings change
/// never serves a stale rendition.
async fn get_clip_media(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(mq): Query<MediaQuery>,
    req: Request,
) -> Result<Response, ApiError> {
    user.require_clips()?;
    let rc = resolve_clip(&state, &id).await?;
    // Camera-access denial is 403 (Forbidden), matching playback.rs / events.rs —
    // NOT 404. `resolve_clip` above already 404s a genuinely missing clip; once it
    // resolves, the clip exists and the only question is authorization.
    user.assert_camera_access(rc.camera_id)?;
    let preview = mq.q.as_deref() != Some("full");
    let quality = if preview { "preview" } else { "full" };

    // Both renditions are cached, seekable files content-addressed by clip id +
    // window params, so both revalidate with a tiny 304 instead of re-fetching.
    let etag = clip_media_etag(&id, quality, rc.overview_secs, rc.pre_secs);
    if let Some(resp) = not_modified_if_match(req.headers(), &etag) {
        return Ok(resp);
    }

    // Frigate-sourced detection clips proxy Frigate's own recorded clip — but only
    // for events short enough to be an overview (§2.4): a long or ongoing Frigate
    // event would buffer its entire multi-hour clip into memory, so it falls
    // straight through to the own-footage overview render below. Any other miss
    // (no clip, Frigate down, source=crumb) also falls back.
    if let Some(ev) = id.strip_prefix("d:").and_then(|s| s.parse::<Uuid>().ok()) {
        if frigate_overview_eligible(&rc) && clip_source_is_frigate(&state, rc.camera_id).await {
            if let Some(bytes) = try_frigate_event_media(&state, ev, "clip.mp4").await {
                let mut resp =
                    ([(header::CONTENT_TYPE, "video/mp4")], Body::from(bytes)).into_response();
                add_clip_cache_headers(&mut resp, &etag);
                return Ok(resp);
            }
        }
    }

    // ── Own-footage: transcode ONCE to a faststart file, serve via ServeFile ──
    // HTML5 <video> (WebView2/Chromium) needs a known-length seekable resource to
    // start promptly and scrub; a length-less streamed transcode makes it buffer
    // a large chunk first. Re-opens of any cached clip are then instant on every
    // client, and the permit is released the moment the transcode finishes.
    let cache_dir = PathBuf::from(&state.config().export_dir).join("clips");
    tokio::fs::create_dir_all(&cache_dir).await.ok();
    let out = cache_dir.join(clip_cache_filename(
        &id,
        quality,
        rc.overview_secs,
        rc.pre_secs,
    ));

    // Per-clip singleflight: concurrent misses on the same rendition serialize on
    // the cache path so they transcode exactly once (the second serves the file
    // the first produced) — the direct fix for the retry-storm incident.
    {
        let lock = state.clip_inflight_lock(&out);
        let _guard = lock.lock().await;
        if tokio::fs::metadata(&out).await.is_err() {
            generate_clip_file(&state, rc.camera_id, rc.start, rc.end, &out, preview).await?;
            prune_clip_cache(&cache_dir, CLIP_RENDITION_CACHE_MAX_BYTES).await;
        }
    }

    let resp = ServeFile::new(&out)
        .oneshot(req)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("ServeFile: {e}")))?;
    let (parts, body) = resp.into_parts();
    let mut resp = Response::from_parts(parts, Body::new(body));
    add_clip_cache_headers(&mut resp, &etag);
    Ok(resp)
}

/// The Frigate `clip.mp4` proxy only runs for events short enough to BE an
/// overview: closed (not ongoing) and no longer than the overview envelope
/// (`overview + pre + post`). Longer or ongoing events skip the proxy and render
/// the own-footage overview instead, so Frigate's entire multi-hour clip never
/// buffers into memory (§2.4). Thumbnails are exempt — a JPEG is bounded by
/// nature — and keep proxying unconditionally.
fn frigate_overview_eligible(rc: &ResolvedClip) -> bool {
    if rc.ongoing {
        return false; // ongoing → skip the proxy (unbounded memory otherwise)
    }
    match rc.event_end {
        Some(end) => {
            let envelope = Duration::seconds(rc.overview_secs + rc.pre_secs)
                + Duration::milliseconds(POST_ROLL_MS);
            (end - rc.event_start) <= envelope
        }
        None => false,
    }
}

/// Long cache lifetime for clip media (thumbnail + preview). A clip's window and
/// underlying footage never change once it exists, so the media is effectively
/// content-addressed by clip id — safe to cache hard. 30 days.
const CLIP_CACHE_MAX_AGE_SECS: u64 = 30 * 24 * 60 * 60;

/// `Cache-Control` value for immutable, content-addressed clip media.
fn clip_cache_control() -> String {
    format!("public, max-age={CLIP_CACHE_MAX_AGE_SECS}, immutable")
}

/// A strong-ish `ETag` for a clip media response, derived from the (immutable)
/// clip id plus a media-kind tag. The clip's footage never changes, so id + kind
/// fully identifies the bytes.
fn clip_etag(id: &str, kind: &str) -> String {
    format!("\"{}-{}\"", sanitize_id(id), kind)
}

/// The window-parameter suffix that makes a clip rendition's cache identity
/// depend on the (now tunable) overview length + pre-roll. Without it, a 30-day
/// immutable `ETag` would pin a stale rendition client-side after a settings
/// change (§2.5.3). E.g. `30s2s` for a 30 s overview with 2 s pre-roll.
fn clip_window_tag(overview_secs: i64, pre_secs: i64) -> String {
    format!("{overview_secs}s{pre_secs}s")
}

/// Cache filename for a clip rendition: `{sanitized_id}.{len}s{pre}s.{quality}.mp4`.
/// The `.{quality}.mp4` tail is what [`prune_clip_cache`] matches; the window tag
/// keys the file to the current settings so old-format files are simply ignored
/// and age out via the sweeper.
fn clip_cache_filename(id: &str, quality: &str, overview_secs: i64, pre_secs: i64) -> String {
    format!(
        "{}.{}.{}.mp4",
        sanitize_id(id),
        clip_window_tag(overview_secs, pre_secs),
        quality
    )
}

/// `ETag` for a clip rendition — id + quality + window params, so a settings
/// change yields a distinct validator and never serves a stale cached rendition.
fn clip_media_etag(id: &str, quality: &str, overview_secs: i64, pre_secs: i64) -> String {
    clip_etag(
        id,
        &format!("{quality}-{}", clip_window_tag(overview_secs, pre_secs)),
    )
}

/// Stamp `Cache-Control` (immutable) + `ETag` onto an already-built clip media
/// response. Used for the paths that don't build headers up-front (`ServeFile`,
/// Frigate proxy). Any pre-existing values are replaced.
fn add_clip_cache_headers(resp: &mut Response, etag: &str) {
    let h = resp.headers_mut();
    if let Ok(v) = clip_cache_control().parse() {
        h.insert(header::CACHE_CONTROL, v);
    }
    if let Ok(v) = etag.parse() {
        h.insert(header::ETAG, v);
    }
}

/// If the request's `If-None-Match` matches `etag`, return a bare 304 (with the
/// cache headers re-stated, as clients expect). Used to short-circuit repeated
/// grid re-fetches of unchanged clip thumbnails/previews.
fn not_modified_if_match(headers: &HeaderMap, etag: &str) -> Option<Response> {
    let inm = headers.get(header::IF_NONE_MATCH)?.to_str().ok()?;
    // Honor a comma-separated list and the `*` wildcard.
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
            .header(header::CACHE_CONTROL, clip_cache_control())
            .body(Body::empty())
            .expect("static 304 response builds"),
    )
}

/// `GET /clip/{id}/thumbnail.jpg` — a single frame near the clip start.
async fn get_clip_thumbnail(
    user: AuthUser,
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    user.require_clips()?;
    let rc = resolve_clip(&state, &id).await?;
    let (cam, start, end) = (rc.camera_id, rc.start, rc.end);
    // Camera-access denial is 403 (Forbidden), matching playback.rs / events.rs —
    // NOT 404. `resolve_clip` above already 404s a genuinely missing clip; once it
    // resolves, the clip exists and the only question is authorization.
    user.assert_camera_access(cam)?;

    // Content-addressed by clip id → serve a 304 straight away on a cache hit,
    // before any Frigate fetch or ffmpeg spawn. This is the grid-speed win: a
    // re-render revalidates with a tiny 304 instead of re-downloading every thumb.
    let etag = clip_etag(&id, "thumb");
    if let Some(resp) = not_modified_if_match(&headers, &etag) {
        return Ok(resp);
    }
    let cache_headers = [
        (header::CONTENT_TYPE, "image/jpeg".to_owned()),
        (header::CACHE_CONTROL, clip_cache_control()),
        (header::ETAG, etag.clone()),
    ];

    if let Some(ev) = id.strip_prefix("d:").and_then(|s| s.parse::<Uuid>().ok()) {
        if clip_source_is_frigate(&state, cam).await {
            if let Some(bytes) = try_frigate_event_media(&state, ev, "thumbnail.jpg").await {
                return Ok((cache_headers, Body::from(bytes)).into_response());
            }
        }
    }
    let cache_dir = PathBuf::from(&state.config().export_dir).join("clips");
    tokio::fs::create_dir_all(&cache_dir).await.ok();
    let out = cache_dir.join(format!("{}.jpg", sanitize_id(&id)));
    if !out.exists() {
        generate_thumbnail(&state, cam, start, end, &out).await?;
    }
    let bytes = tokio::fs::read(&out)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("read thumb: {e}")))?;
    Ok((cache_headers, Body::from(bytes)).into_response())
}

/// Max bytes of cached clip renditions (preview + full) kept on disk by the
/// in-request pruner; oldest by mtime are dropped past this. The periodic sweeper
/// in `main.rs` (`sweep_clips_cache`) additionally enforces a TTL + the larger
/// `CLIP_CACHE_MAX_BYTES` budget.
const CLIP_RENDITION_CACHE_MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024; // 2 GB

/// Build the ffmpeg concat list (a uniquely-named temp file the caller deletes)
/// plus the `(start-offset, duration)` seconds for a clip window. Shared by the
/// live stream and the cached-preview generator.
async fn prepare_clip_inputs(
    state: &AppState,
    camera_id: Uuid,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Result<(PathBuf, f64, f64), ApiError> {
    let pool = state.pool();
    let storage_paths = db::storage_path_map(pool)
        .await
        .map_err(ApiError::Internal)?;
    let segments = db::list_segments_for_range(pool, camera_id, "main", start, end)
        .await
        .map_err(ApiError::Internal)?;
    if segments.is_empty() {
        return Err(ApiError::NotFound(
            "no footage for this clip window".to_owned(),
        ));
    }
    let cache_dir = PathBuf::from(&state.config().export_dir).join("clips");
    tokio::fs::create_dir_all(&cache_dir).await.ok();
    let concat_path = cache_dir.join(format!("{}.concat.txt", Uuid::new_v4()));
    let mut concat = String::new();
    for seg in &segments {
        let abs = seg_abs_path(&storage_paths, seg)?;
        concat.push_str(&format!("file '{}'\n", abs.display()));
    }
    tokio::fs::write(&concat_path, concat.as_bytes())
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("write concat: {e}")))?;

    let first = segments[0].start_ts;
    #[allow(clippy::cast_precision_loss)]
    let ss = if start > first {
        (start - first).num_milliseconds().max(0) as f64 / 1000.0
    } else {
        0.0
    };
    #[allow(clippy::cast_precision_loss)]
    let dur = (end - start).num_milliseconds().max(0) as f64 / 1000.0;
    Ok((concat_path, ss, dur))
}

/// Transcode a clip rendition to a **faststart** MP4 at `out`, waiting for
/// completion. `preview` downscales (640p/10fps, no audio, ultrafast) for fast
/// browsing; full quality keeps source resolution (veryfast, crf 23, AAC audio).
/// Both are the same `[start, end)` overview window. Writes to a unique temp file
/// then atomically renames so a crashed/concurrent run never leaves a half file
/// for `ServeFile` to serve. Holds the clip-gen semaphore for the transcode only
/// (never the client's read), which — together with the ≤120 s window and the
/// per-clip singleflight in the caller — is what removed the slow-reader
/// permit-starvation vector from the 2026-07-16 incident.
async fn generate_clip_file(
    state: &AppState,
    camera_id: Uuid,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    out: &FsPath,
    preview: bool,
) -> Result<(), ApiError> {
    let _permit = state
        .clip_gen_semaphore()
        .acquire_owned()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("clip-gen semaphore closed: {e}")))?;
    // Another request may have produced it while we waited for the permit.
    if tokio::fs::metadata(out).await.is_ok() {
        return Ok(());
    }
    let (concat_path, ss, dur) = prepare_clip_inputs(state, camera_id, start, end).await?;
    let tmp = out.with_file_name(format!("{}.partial.mp4", Uuid::new_v4()));
    // ultrafast for the throwaway downscaled preview; veryfast for full quality.
    let preset = if preview { "ultrafast" } else { "veryfast" };
    let mut args: Vec<String> = vec![
        "-y".to_owned(),
        "-f".to_owned(),
        "concat".to_owned(),
        "-safe".to_owned(),
        "0".to_owned(),
        "-i".to_owned(),
        concat_path.to_string_lossy().into_owned(),
        "-ss".to_owned(),
        format!("{ss:.3}"),
        "-t".to_owned(),
        format!("{dur:.3}"),
        "-c:v".to_owned(),
        "libx264".to_owned(),
        "-preset".to_owned(),
        preset.to_owned(),
    ];
    if preview {
        args.extend(["-vf", "scale=640:-2", "-r", "10", "-crf", "28", "-an"].map(str::to_owned));
    } else {
        args.extend(["-crf", "23", "-c:a", "aac"].map(str::to_owned));
    }
    args.extend(["-movflags".to_owned(), "+faststart".to_owned()]);
    args.push(tmp.to_string_lossy().into_owned());
    let status = Command::new(FFMPEG_BIN)
        .args(&args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;
    let _ = tokio::fs::remove_file(&concat_path).await;
    match status {
        Ok(s) if s.success() => tokio::fs::rename(&tmp, out)
            .await
            .map_err(|e| ApiError::Internal(anyhow::anyhow!("cache clip rename: {e}"))),
        other => {
            let _ = tokio::fs::remove_file(&tmp).await;
            Err(ApiError::Internal(anyhow::anyhow!(
                "ffmpeg clip transcode failed: {other:?}"
            )))
        }
    }
}

/// Keep the clip-rendition cache under `max_bytes` by deleting the oldest
/// finished rendition files (by mtime) until it fits. Matches both `*.preview.mp4`
/// and `*.full.mp4` — the two `{quality}.mp4` tails [`clip_cache_filename`]
/// produces — so both renditions are prunable (landmine §3.5: this matcher must
/// track the filename pattern or the cache stops pruning). In-progress
/// `*.partial.mp4` temp files and `*.concat.txt` lists are deliberately skipped.
/// Best-effort — any error just leaves the cache as-is.
async fn prune_clip_cache(dir: &FsPath, max_bytes: u64) {
    let Ok(mut rd) = tokio::fs::read_dir(dir).await else {
        return;
    };
    let mut files: Vec<(std::time::SystemTime, u64, PathBuf)> = Vec::new();
    let mut total: u64 = 0;
    while let Ok(Some(ent)) = rd.next_entry().await {
        let p = ent.path();
        let name = p.to_string_lossy();
        if !(name.ends_with(".preview.mp4") || name.ends_with(".full.mp4")) {
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

/// Below this mean luma (0..255, sampled from the produced JPEG) a thumbnail is
/// treated as "near-black" and we seek a step deeper for a more representative
/// frame. ~16 is dark-but-not-pitch; a lit scene reads well above this.
const THUMB_NEAR_BLACK_LUMA: f64 = 16.0;
/// Max frame-selection attempts before we accept whatever we got. Bounded so a
/// genuinely dark clip (night, covered lens) never loops or fails the request —
/// a mediocre thumbnail always beats a 500.
const THUMB_MAX_ATTEMPTS: usize = 3;

/// Extract a single representative JPEG frame from the first overlapping segment.
///
/// Two-part fix for solid-black thumbnails (#44):
///  1. **Frame selection** — instead of grabbing the clip's very first frame
///     (often a black GDR/intra-refresh keyframe or the camera's dark warm-up
///     frame), seek a bit *deeper* into the clip window so the thumbnail is a
///     representative frame.
///  2. **Near-black guard** — after producing the jpeg, cheaply measure its mean
///     luma; if it's near-black, retry one step deeper (a couple of attempts,
///     then accept whatever we have). Bounded — never loops, never fails.
async fn generate_thumbnail(
    state: &AppState,
    camera_id: Uuid,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    out: &FsPath,
) -> Result<(), ApiError> {
    let pool = state.pool();
    let storage_paths = db::storage_path_map(pool)
        .await
        .map_err(ApiError::Internal)?;
    let segments = db::list_segments_for_range(pool, camera_id, "main", start, end)
        .await
        .map_err(ApiError::Internal)?;
    let seg = segments
        .first()
        .ok_or_else(|| ApiError::NotFound("no footage for this clip window".to_owned()))?;
    let abs = seg_abs_path(&storage_paths, seg)?;

    // Offset (seconds, relative to the segment) of the clip's start within this
    // segment. We grab *deeper* than this so we skip the black first keyframe.
    #[allow(clippy::cast_precision_loss)]
    let base_off = if start > seg.start_ts {
        (start - seg.start_ts).num_milliseconds().max(0) as f64 / 1000.0
    } else {
        0.0
    };
    // How far the segment runs past our start offset — never seek past it.
    #[allow(clippy::cast_precision_loss)]
    let seg_room =
        ((seg.end_ts - seg.start_ts).num_milliseconds().max(0) as f64 / 1000.0 - base_off).max(0.0);
    // How long the clip window itself is (independent of segment length).
    #[allow(clippy::cast_precision_loss)]
    let clip_len = (end - start).num_milliseconds().max(0) as f64 / 1000.0;

    // Seek target: land past the (often black) first keyframe but ALWAYS leave a
    // little decodable footage after the seek. Seeking to (or past) the segment's
    // last frame makes ffmpeg receive no packets and fail ("Conversion failed"),
    // which produced a 500 and a black motion thumbnail — the previous code had a
    // "leave a hair of headroom" comment but never actually reserved any. `usable`
    // reserves HEADROOM before the segment end.
    const HEADROOM: f64 = 0.3;
    let usable = (seg_room - HEADROOM).max(0.0).min(clip_len);
    let first_step = 1.5_f64.min(clip_len / 3.0).min(usable);
    // Each near-black retry seeks another step deeper, but never past `max_off`.
    let retry_step = first_step.max(0.5);
    let max_off = base_off + usable;

    let mut off = base_off + first_step;
    for attempt in 0..THUMB_MAX_ATTEMPTS {
        // On retries, use an accurate seek (`-ss` AFTER `-i`) so the deeper offset
        // lands precisely rather than snapping back to the same black keyframe.
        let accurate = attempt > 0;
        if grab_frame(&abs, off, out, accurate).await.is_err() {
            // The seek found no frame (a very short / boundary segment). Fall back
            // to the segment's first frame (keyframe at offset 0), guaranteed to
            // exist — a slightly-off frame beats a 500 / black tile.
            let _ = grab_frame(&abs, 0.0, out, false).await;
            return Ok(());
        }

        // Cheap near-black check: sample the produced jpeg's mean luma.
        let luma = mean_luma(out).await;
        if luma.is_none_or(|l| l >= THUMB_NEAR_BLACK_LUMA) {
            // Bright enough (or we couldn't measure) — accept it.
            return Ok(());
        }
        // Near-black: step deeper for the next attempt, clamped inside the window.
        let next = (off + retry_step).min(max_off);
        if (next - off).abs() < f64::EPSILON {
            // No more room to seek — accept whatever we have.
            break;
        }
        off = next;
    }
    Ok(())
}

/// Grab one JPEG frame at `off` seconds into `input`, scaled to 480px wide, to
/// `out`. `accurate` places `-ss` AFTER `-i` (precise, decodes from a keyframe)
/// vs. before (fast keyframe seek).
async fn grab_frame(
    input: &FsPath,
    off: f64,
    out: &FsPath,
    accurate: bool,
) -> Result<(), ApiError> {
    let input_s = input.to_string_lossy().into_owned();
    let out_s = out.to_string_lossy().into_owned();
    let off_s = format!("{off:.3}");
    let mut args: Vec<String> = vec!["-y".to_owned()];
    if accurate {
        // Accurate seek: decode from the preceding keyframe up to `off`.
        args.extend(["-i".to_owned(), input_s, "-ss".to_owned(), off_s]);
    } else {
        // Fast keyframe seek before input.
        args.extend(["-ss".to_owned(), off_s, "-i".to_owned(), input_s]);
    }
    // `-update 1`: write a single image to the fixed output filename; modern
    // ffmpeg's image2 muxer otherwise warns about the missing `%d` pattern.
    args.extend(
        [
            "-frames:v",
            "1",
            "-update",
            "1",
            "-vf",
            "scale=480:-2",
            "-q:v",
            "3",
        ]
        .map(str::to_owned),
    );
    args.push(out_s);
    let status = Command::new(FFMPEG_BIN)
        .args(&args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("spawn ffmpeg: {e}")))?;
    if !status.success() {
        return Err(ApiError::Internal(anyhow::anyhow!(
            "ffmpeg failed for thumbnail ({status})"
        )));
    }
    Ok(())
}

/// Cheaply estimate a JPEG's mean luma (0..255) with a tiny ffmpeg `signalstats`
/// pass over the file. Returns `None` if the value can't be parsed (in which case
/// callers accept the frame rather than retry blindly).
async fn mean_luma(path: &FsPath) -> Option<f64> {
    // `signalstats` yields per-frame Y average; `metadata=print:file=-` writes it
    // to STDOUT as clean `lavfi.signalstats.YAVG=<value>` lines (independent of the
    // log level, unlike plain `metadata=print` which logs at info and is hidden by
    // `-v error`). Scaling to 1x1 first makes YAVG a whole-frame average, computed
    // near-instantly.
    let out = Command::new(FFMPEG_BIN)
        .args([
            "-v",
            "error",
            "-i",
            &path.to_string_lossy(),
            "-vf",
            "scale=1:1,signalstats,metadata=print:file=-",
            "-f",
            "null",
            "-",
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .await
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines()
        .filter_map(|l| l.trim().strip_prefix("lavfi.signalstats.YAVG="))
        .find_map(|v| v.trim().parse::<f64>().ok())
}

// ── Frigate source proxy (Phase 2) ──────────────────────────────────────────

/// True when this camera's effective clip source is Frigate (its own
/// `clip_source`, else the global default). Motion is never resolved here.
async fn clip_source_is_frigate(state: &AppState, cam: Uuid) -> bool {
    let cams = db::list_clip_cameras(state.pool(), &[cam])
        .await
        .unwrap_or_default();
    let own = cams
        .first()
        .and_then(|c| c.clip_source.clone())
        .filter(|s| !s.trim().is_empty());
    let src = if let Some(s) = own {
        s
    } else {
        db::get_default_clip_source(state.pool())
            .await
            .unwrap_or_else(|_| "crumb".to_owned())
    };
    src.eq_ignore_ascii_case("frigate")
}

/// Fetch Frigate event media (`suffix` = `clip.mp4` / `thumbnail.jpg`). Returns
/// the bytes on success, `None` on any miss so the caller falls back to
/// own-footage generation. Frigate base is the admin-editable DB value, else the
/// `FRIGATE_API_BASE` env.
async fn try_frigate_event_media(
    state: &AppState,
    event_id: Uuid,
    suffix: &str,
) -> Option<Vec<u8>> {
    let (pid, _src) = db::get_event_provider(state.pool(), event_id)
        .await
        .ok()??;
    let pid = pid?;
    let base = if let Some(b) = db::frigate_http_base(state.pool()).await.ok().flatten() {
        b
    } else {
        let env = state.config().frigate_api_base.clone();
        if env.trim().is_empty() {
            return None;
        }
        env
    };
    let url = format!(
        "{}/api/events/{}/{}",
        base.trim_end_matches('/'),
        pid,
        suffix
    );
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .ok()?;
    let resp = client.get(&url).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.bytes().await.ok().map(|b| b.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn t(ms: i64) -> DateTime<Utc> {
        Utc.timestamp_millis_opt(ms).unwrap()
    }

    /// Build a `ResolvedClip` for the Frigate-gate tests (the window fields are
    /// irrelevant to the gate, which only reads `ongoing`/`event_*`/`*_secs`).
    fn rc(event_start: DateTime<Utc>, event_end: Option<DateTime<Utc>>) -> ResolvedClip {
        ResolvedClip {
            camera_id: Uuid::nil(),
            start: event_start,
            end: event_end.unwrap_or(event_start),
            overview_secs: 30,
            pre_secs: 2,
            ongoing: event_end.is_none(),
            event_start,
            event_end,
        }
    }

    #[test]
    fn overview_window_short_closed_keeps_natural_length() {
        // A 12 s event (pre 2 s, overview 30 s): the truncation term wins, so the
        // window is [start-2, end+post], NOT padded out to 30 s.
        let start = t(100_000);
        let end = t(112_000);
        let (s, e) = overview_window(start, Some(end), 2, 30);
        assert_eq!(s, start - Duration::seconds(2));
        assert_eq!(e, end + Duration::milliseconds(POST_ROLL_MS));
        assert!(e < s + Duration::seconds(30), "short event stays short");
    }

    #[test]
    fn overview_window_long_closed_caps_at_overview() {
        // A 10-hour event caps at the overview length, never the far-off end.
        let start = t(0);
        let end = t(36_000_000); // +10 h
        let (s, e) = overview_window(start, Some(end), 2, 30);
        assert_eq!(s, start - Duration::seconds(2));
        assert_eq!(e, s + Duration::seconds(30));
        assert_eq!((e - s).num_seconds(), 30);
    }

    #[test]
    fn overview_window_ongoing_is_full_overview_length() {
        // No end (ongoing): window is exactly [start-pre, start-pre+overview].
        let start = t(500_000);
        let (s, e) = overview_window(start, None, 2, 45);
        assert_eq!(s, start - Duration::seconds(2));
        assert_eq!(e, s + Duration::seconds(45));
    }

    #[test]
    fn overview_window_hard_ceiling_and_inverted_guard() {
        // The 120 s compiled ceiling holds even for an out-of-range overview
        // length (the DB clamp is the first lock; this is the second).
        let start = t(0);
        let (s, e) = overview_window(start, None, 0, 10_000);
        assert_eq!((e - s).num_seconds(), MAX_CLIP_MEDIA_SECS);
        // An inverted event (end before start) collapses to the window start,
        // never a negative-length window.
        let start = t(50_000);
        let (s, e) = overview_window(start, Some(t(0)), 0, 30);
        assert_eq!(e, s);
    }

    #[test]
    fn frigate_gate_only_short_closed_events() {
        // 20 s closed event fits the overview envelope (30+2+8 = 40 s) → proxy.
        assert!(frigate_overview_eligible(&rc(t(0), Some(t(20_000)))));
        // 10-minute closed event exceeds it → skip the proxy (own-footage render).
        assert!(!frigate_overview_eligible(&rc(t(0), Some(t(600_000)))));
        // Ongoing event → never proxy (unbounded memory otherwise).
        assert!(!frigate_overview_eligible(&rc(t(0), None)));
    }

    #[test]
    fn clip_cache_key_changes_with_window_params() {
        let id = "d:11111111-1111-1111-1111-111111111111";
        // ETag + filename both change when the tunable overview length changes …
        assert_ne!(
            clip_media_etag(id, "preview", 30, 2),
            clip_media_etag(id, "preview", 60, 2)
        );
        assert_ne!(
            clip_cache_filename(id, "preview", 30, 2),
            clip_cache_filename(id, "preview", 60, 2)
        );
        // … and when the pre-roll changes …
        assert_ne!(
            clip_media_etag(id, "preview", 30, 2),
            clip_media_etag(id, "preview", 30, 5)
        );
        // … and per quality.
        assert_ne!(
            clip_media_etag(id, "preview", 30, 2),
            clip_media_etag(id, "full", 30, 2)
        );
        // Same params → stable.
        assert_eq!(
            clip_media_etag(id, "preview", 30, 2),
            clip_media_etag(id, "preview", 30, 2)
        );
        // The `{quality}.mp4` tail is exactly what `prune_clip_cache` matches.
        assert!(clip_cache_filename(id, "preview", 30, 2).ends_with(".preview.mp4"));
        assert!(clip_cache_filename(id, "full", 30, 2).ends_with(".full.mp4"));
        // ETag stays a valid quoted token with the `:`/`-` in the id sanitized.
        let e = clip_media_etag(id, "preview", 30, 2);
        assert!(e.starts_with('"') && e.ends_with('"') && !e.contains(':'));
    }

    #[test]
    fn motion_runs_merges_within_gap_drops_quiet_and_short() {
        let bb = Some([0.1_f32, 0.2, 0.3, 0.4]);
        let items = vec![
            (t(0), t(5_000), true, bb),           // run A start (carries the region)
            (t(5_000), t(8_000), false, None),    // quiet — ignored
            (t(6_000), t(10_000), true, None),    // within 30s of A → merges to 0..10s
            (t(50_000), t(50_400), true, None),   // 0.4s blip, >30s gap → own run, dropped (<1s)
            (t(120_000), t(125_000), true, None), // far away → new run
        ];
        let runs = motion_runs(&items);
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0], (t(0), t(10_000), bb));
        assert_eq!(runs[1], (t(120_000), t(125_000), None));
    }

    #[test]
    fn motion_runs_first_bbox_wins_when_onset_has_none() {
        // Onset segment had no region; a later merged segment did → adopt the
        // first available region for the run.
        let bb = Some([0.5_f32, 0.5, 0.2, 0.2]);
        let items = vec![
            (t(0), t(5_000), true, None),
            (t(6_000), t(10_000), true, bb),
        ];
        let runs = motion_runs(&items);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0], (t(0), t(10_000), bb));
    }

    #[test]
    fn motion_runs_empty_when_no_motion() {
        let items = vec![
            (t(0), t(5_000), false, None),
            (t(5_000), t(9_000), false, None),
        ];
        assert!(motion_runs(&items).is_empty());
    }

    #[test]
    fn etag_is_stable_and_kind_scoped() {
        // Same id → same thumb etag; preview vs thumb differ; the volatile `:`
        // characters are sanitized so the value is a valid quoted-string token.
        let id = "m:11111111-1111-1111-1111-111111111111:1000:2000";
        assert_eq!(clip_etag(id, "thumb"), clip_etag(id, "thumb"));
        assert_ne!(clip_etag(id, "thumb"), clip_etag(id, "preview"));
        let e = clip_etag(id, "thumb");
        assert!(e.starts_with('"') && e.ends_with('"'));
        assert!(!e.contains(':'));
    }

    #[test]
    fn cache_control_is_immutable_and_long() {
        let cc = clip_cache_control();
        assert!(cc.contains("public"));
        assert!(cc.contains("immutable"));
        assert!(cc.contains(&format!("max-age={CLIP_CACHE_MAX_AGE_SECS}")));
    }

    #[test]
    fn if_none_match_hits_and_misses() {
        use axum::http::HeaderValue;
        let etag = clip_etag("d:abc", "thumb");

        // Exact match → 304.
        let mut h = HeaderMap::new();
        h.insert(header::IF_NONE_MATCH, HeaderValue::from_str(&etag).unwrap());
        let r = not_modified_if_match(&h, &etag).expect("exact match → 304");
        assert_eq!(r.status(), StatusCode::NOT_MODIFIED);
        // 304 re-states cache headers.
        assert!(r.headers().get(header::ETAG).is_some());
        assert!(r.headers().get(header::CACHE_CONTROL).is_some());

        // Weak-validator prefix + list membership → still a hit.
        let mut h = HeaderMap::new();
        h.insert(
            header::IF_NONE_MATCH,
            HeaderValue::from_str(&format!("\"other\", W/{etag}")).unwrap(),
        );
        assert!(not_modified_if_match(&h, &etag).is_some());

        // Wildcard → hit.
        let mut h = HeaderMap::new();
        h.insert(header::IF_NONE_MATCH, HeaderValue::from_static("*"));
        assert!(not_modified_if_match(&h, &etag).is_some());

        // Different etag → miss (serve fresh bytes).
        let mut h = HeaderMap::new();
        h.insert(header::IF_NONE_MATCH, HeaderValue::from_static("\"nope\""));
        assert!(not_modified_if_match(&h, &etag).is_none());

        // Absent header → miss.
        assert!(not_modified_if_match(&HeaderMap::new(), &etag).is_none());
    }

    /// End-to-end frame-selection + near-black guard against a synthesized clip
    /// whose first second is solid black (mimicking a black GDR keyframe / dark
    /// warm-up frame). Requires ffmpeg on PATH at [`FFMPEG_BIN`]; ignored by
    /// default so the normal `cargo test` gate stays hermetic. Run with
    /// `cargo test --workspace -- --ignored thumbnail_guard`.
    #[tokio::test]
    #[ignore = "requires ffmpeg; run explicitly"]
    async fn thumbnail_guard_avoids_black_first_frame() {
        let dir = std::env::temp_dir().join(format!("crumb-thumb-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let clip = dir.join("blackfirst.mp4");

        // 1s black then 5s bright testsrc, 25fps, 1s GOP.
        let synth = Command::new(FFMPEG_BIN)
            .args([
                "-y",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=640x360:d=1:r=25",
                "-f",
                "lavfi",
                "-i",
                "testsrc=s=640x360:d=5:r=25",
                "-filter_complex",
                "[0:v][1:v]concat=n=2:v=1:a=0[v]",
                "-map",
                "[v]",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-g",
                "25",
                clip.to_string_lossy().as_ref(),
            ])
            .status()
            .await
            .expect("spawn ffmpeg synth");
        assert!(synth.success(), "synth clip failed");

        // The naive grab (offset 0, keyframe seek) lands on the black frame …
        let black = dir.join("naive.jpg");
        grab_frame(&clip, 0.0, &black, false).await.unwrap();
        let black_luma = mean_luma(&black).await.expect("luma of naive frame");
        assert!(
            black_luma < THUMB_NEAR_BLACK_LUMA,
            "sanity: naive first frame should be near-black, got {black_luma}"
        );

        // … while a deeper seek (what generate_thumbnail does first) is bright.
        let good = dir.join("deep.jpg");
        grab_frame(&clip, 1.5, &good, false).await.unwrap();
        let good_luma = mean_luma(&good).await.expect("luma of deep frame");
        assert!(
            good_luma >= THUMB_NEAR_BLACK_LUMA,
            "deep-seek frame should not be near-black, got {good_luma}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
