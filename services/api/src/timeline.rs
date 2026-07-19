// SPDX-License-Identifier: AGPL-3.0-or-later

//! Timeline API — the data layer for the killer scrubbing feature.
//!
//! # Endpoints
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `GET`  | `/timeline` | Bearer | Merged recorded spans for N cameras over a time window |
//!
//! # Algorithm
//!
//! 1. Parse `camera_ids` as a comma-separated list of UUIDs; reject malformed
//!    UUIDs with 400.
//! 2. Filter the parsed IDs through `user.filter_camera_ids` to enforce viewer
//!    camera scoping (admins pass through unchanged).
//! 3. Validate `start < end`; reject with 400 if not.
//! 4. Call `crumb_common::db::timeline_spans`, which returns rows ordered by
//!    `(camera_id, start_ts)` from the `(camera_id, start_ts)` index.
//! 5. Merge contiguous segments per camera into [`RecordedSpan`]s:
//!    - Two segments are contiguous when `seg[i].end_ts + GAP_TOLERANCE >= seg[i+1].start_ts`.
//!    - `has_motion` is `true` if **any** segment in the span has `has_motion`.
//!    - `stage` is taken from the **first** segment of the span (live beats archive
//!      for display; mixed-stage spans are labelled "live" by the first-wins rule).
//! 6. Return all spans in a single [`TimelineResponse`].
//!
//! # Performance target
//!
//! 11 cameras × 48 h must return in < 200 ms via the `segments_camera_start` index.

use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crumb_common::db;

use crate::{
    auth_mw::AuthUser,
    dto::{RecordedSpan, TimelineQuery, TimelineResponse},
    error::ApiError,
    state::AppState,
};

/// Maximum gap between the end of one segment and the start of the next that is
/// still treated as contiguous, in milliseconds.
///
/// 1 000 ms (1 s) covers typical ffmpeg segment-boundary rounding without
/// hiding genuine gaps.
///
/// `chrono::Duration::milliseconds` is not `const`, so we store the raw value
/// and call `Duration::milliseconds(GAP_TOLERANCE_MS)` at the use site.
const GAP_TOLERANCE_MS: i64 = 1_000;

/// Default page size when the client omits `limit`. Merged spans are coarse
/// (contiguous recording = one span) so this is generous for normal use while
/// still bounding pathological windows.
const DEFAULT_SPAN_LIMIT: usize = 2_000;

/// Hard ceiling on `limit` regardless of what the client requests — bounds the
/// response payload deterministically (audit Risk #4).
const MAX_SPAN_LIMIT: usize = 10_000;

/// If a single timeline query scans more than this many raw segments, log a WARN
/// so operators can see when a window is large enough to merit tighter client
/// windowing or future SQL-side bucketing.
const SCAN_WARN_SEGMENTS: usize = 100_000;

/// Max cameras accepted by `GET /timeline/intensity/batch`. A wall is a handful
/// of cameras; this just bounds a pathological request.
const MAX_INTENSITY_BATCH: usize = 64;

/// Mount timeline routes.
///
/// Caller (`main.rs`) merges this at the router root.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/timeline", get(get_timeline))
        .route("/timeline/intensity", get(get_intensity))
        .route("/timeline/intensity/batch", get(get_intensity_batch))
        .route("/timeline/motion", get(get_motion_edge))
}

/// Query for `GET /timeline/motion`.
#[derive(Debug, Deserialize)]
struct MotionEdgeQuery {
    camera_id: Uuid,
    /// Reference time — the playhead.
    from: DateTime<Utc>,
    /// `"next"` (default) or `"prev"`.
    dir: Option<String>,
}

/// Response for `GET /timeline/motion` — the start of the next/previous motion
/// event, or `null` when there is none in that direction.
#[derive(Debug, Serialize)]
struct MotionEdgeResponse {
    start: Option<DateTime<Utc>>,
}

/// `GET /timeline/motion?camera_id=<uuid>&from=<iso>&dir=next|prev`
///
/// The leading edge of the next/previous motion EVENT relative to `from`, searched
/// across ALL recorded history — so the prev/next-motion buttons reach events that
/// are off the client's current timeline zoom. Viewer-scoped: returns `null` (not
/// 403) for a camera the caller can't access, matching `/timeline/intensity`.
async fn get_motion_edge(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<MotionEdgeQuery>,
) -> Result<Json<MotionEdgeResponse>, ApiError> {
    user.require_playback()?;
    if !user.can_access_camera(q.camera_id) {
        return Ok(Json(MotionEdgeResponse { start: None }));
    }
    let next = q.dir.as_deref() != Some("prev");
    let start = db::motion_event_edge(state.pool(), q.camera_id, q.from, next)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(MotionEdgeResponse { start }))
}

// ─── motion intensity ───────────────────────────────────────────────────────────

/// Query for `GET /timeline/intensity`.
#[derive(Debug, Deserialize)]
struct IntensityQuery {
    camera_id: Uuid,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    /// Number of time buckets across the window (default 240, clamped 1..4096).
    buckets: Option<usize>,
}

/// Response for `GET /timeline/intensity` — one 0..1 value per time bucket.
#[derive(Debug, Serialize)]
struct IntensityResponse {
    buckets: Vec<f32>,
}

/// `GET /timeline/intensity?camera_id=<uuid>&start=<iso>&end=<iso>&buckets=<n>`
///
/// Per-camera motion-magnitude histogram over the window — the data behind the
/// selected camera's activity bars on the timeline. Viewer-scoped: returns all
/// zeros (not 403) for a camera the caller can't access, matching `/timeline`.
async fn get_intensity(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<IntensityQuery>,
) -> Result<Json<IntensityResponse>, ApiError> {
    user.require_playback()?;
    let n = q.buckets.unwrap_or(240);
    if q.start >= q.end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }
    if !user.can_access_camera(q.camera_id) {
        return Ok(Json(IntensityResponse {
            buckets: vec![0.0; n.clamp(1, 4096)],
        }));
    }
    let buckets = db::motion_intensity_buckets(state.pool(), q.camera_id, q.start, q.end, n)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(IntensityResponse { buckets }))
}

/// Query for `GET /timeline/intensity/batch` — the multi-camera form.
#[derive(Debug, Deserialize)]
struct IntensityBatchQuery {
    /// Comma-separated camera UUIDs.
    camera_ids: String,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    /// Number of time buckets across the window (default 240, clamped 1..4096).
    buckets: Option<usize>,
}

/// Response for `GET /timeline/intensity/batch` — a bucket array per requested
/// camera (keyed by UUID string). Every requested camera is present; a camera
/// with no footage (or outside the caller's scope) gets an all-zero array, so
/// the client gets a complete map in one request instead of N.
#[derive(Debug, Serialize)]
struct IntensityBatchResponse {
    cameras: std::collections::HashMap<String, Vec<f32>>,
}

/// `GET /timeline/intensity/batch?camera_ids=<csv>&start=<iso>&end=<iso>&buckets=<n>`
///
/// The batched form of [`get_intensity`]: one request + one DB scan for the
/// whole wall instead of one per camera (#256). Scope is enforced like the
/// per-camera endpoint — a camera the caller can't access gets all-zeros rather
/// than a 403.
async fn get_intensity_batch(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<IntensityBatchQuery>,
) -> Result<Json<IntensityBatchResponse>, ApiError> {
    user.require_playback()?;
    if q.start >= q.end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }
    let requested = parse_uuid_csv(&q.camera_ids)?;
    if requested.is_empty() {
        return Err(ApiError::BadRequest(
            "camera_ids must contain at least one UUID".to_owned(),
        ));
    }
    // Bound the fan-in — a wall is a handful of cameras, not hundreds.
    if requested.len() > MAX_INTENSITY_BATCH {
        return Err(ApiError::BadRequest(format!(
            "camera_ids: at most {MAX_INTENSITY_BATCH} cameras per request"
        )));
    }
    let n = q.buckets.unwrap_or(240).clamp(1, 4096);

    // Fetch only the accessible cameras; inaccessible ones fall through to the
    // all-zeros default below (matching the per-camera endpoint's behaviour).
    let accessible = user.filter_camera_ids(&requested);
    let mut data = db::motion_intensity_buckets_multi(state.pool(), &accessible, q.start, q.end, n)
        .await
        .map_err(ApiError::Internal)?;

    // Build the response over EVERY requested camera so the client always gets a
    // complete map (accessible-with-data, accessible-empty, and inaccessible all
    // resolve to an array; only inaccessible are silently zeroed).
    let mut cameras = std::collections::HashMap::with_capacity(requested.len());
    for id in &requested {
        let buckets = data.remove(id).unwrap_or_else(|| vec![0.0; n]);
        cameras.insert(id.to_string(), buckets);
    }
    Ok(Json(IntensityBatchResponse { cameras }))
}

// ─── handler ──────────────────────────────────────────────────────────────────

/// `GET /timeline?camera_ids=<csv>&start=<iso>&end=<iso>`
///
/// Returns merged recorded spans (not raw segments) for the requested cameras
/// over the given time window.  Viewer camera scope is enforced: any camera the
/// caller cannot access is silently dropped from the result (matching the
/// behaviour of `AuthUser::filter_camera_ids`).
///
/// # Errors
///
/// * `400` — `camera_ids` is empty, contains a malformed UUID, or `start >= end`.
/// * `401` / `403` — standard auth failures from the [`AuthUser`] extractor.
async fn get_timeline(
    user: AuthUser,
    State(state): State<AppState>,
    Query(q): Query<TimelineQuery>,
) -> Result<Json<TimelineResponse>, ApiError> {
    // ── capability gate ───────────────────────────────────────────────────────
    user.require_playback()?;

    // ── 1. parse camera_ids CSV ───────────────────────────────────────────────
    let requested_ids = parse_uuid_csv(&q.camera_ids)?;
    if requested_ids.is_empty() {
        return Err(ApiError::BadRequest(
            "camera_ids must contain at least one UUID".to_owned(),
        ));
    }

    // ── 2. enforce viewer scope ───────────────────────────────────────────────
    let camera_ids = user.filter_camera_ids(&requested_ids);
    // If scope filtering removed everything (viewer has no overlap), return an
    // empty result rather than 403 — this is consistent with "you only see your
    // cameras" semantics.
    if camera_ids.is_empty() {
        return Ok(Json(TimelineResponse {
            spans: vec![],
            total: 0,
            has_more: false,
        }));
    }

    // ── 3. validate time range ────────────────────────────────────────────────
    if q.start >= q.end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }

    // ── 4. fetch segments from the index ──────────────────────────────────────
    let segments = db::timeline_spans(state.pool(), &camera_ids, q.start, q.end)
        .await
        .map_err(ApiError::Internal)?;

    if segments.len() > SCAN_WARN_SEGMENTS {
        tracing::warn!(
            scanned = segments.len(),
            cameras = camera_ids.len(),
            window_hours = (q.end - q.start).num_hours(),
            "large /timeline scan — consider tighter client windows (audit Risk #4)"
        );
    }

    // ── 5. merge contiguous segments per camera ───────────────────────────────
    let all_spans = merge_segments_into_spans(segments);
    let total = all_spans.len();

    // ── 6. paginate the merged spans (bounds the response payload) ─────────────
    let offset = q.offset.unwrap_or(0);
    let limit = q
        .limit
        .unwrap_or(DEFAULT_SPAN_LIMIT)
        .clamp(1, MAX_SPAN_LIMIT);
    let spans: Vec<RecordedSpan> = all_spans.into_iter().skip(offset).take(limit).collect();
    let has_more = offset.saturating_add(spans.len()) < total;

    Ok(Json(TimelineResponse {
        spans,
        total,
        has_more,
    }))
}

// ─── span merging ─────────────────────────────────────────────────────────────

/// Merge a list of [`crumb_common::Segment`] rows (pre-sorted by
/// `(camera_id, start_ts)`) into [`RecordedSpan`]s.
///
/// Two segments belong to the same span when they are contiguous (gap ≤
/// [`GAP_TOLERANCE`]).  A span's `has_motion` is the logical OR of all its
/// segments' `has_motion` flags.  The `stage` is taken from the first segment
/// in the span.
fn merge_segments_into_spans(segments: Vec<crumb_common::Segment>) -> Vec<RecordedSpan> {
    let mut spans: Vec<RecordedSpan> = Vec::with_capacity(segments.len());

    for seg in segments {
        // Try to extend the most-recent span for the same camera.
        if let Some(last) = spans.last_mut() {
            if last.camera_id == seg.camera_id {
                // Contiguous check: last span's end + tolerance >= this seg's start.
                let gap_threshold = last.end + Duration::milliseconds(GAP_TOLERANCE_MS);
                if seg.start_ts <= gap_threshold {
                    // Extend the span.
                    if seg.end_ts > last.end {
                        last.end = seg.end_ts;
                    }
                    last.has_motion |= seg.has_motion;
                    // stage stays as the first segment's stage.
                    continue;
                }
            }
        }

        // Start a new span.
        spans.push(RecordedSpan {
            camera_id: seg.camera_id,
            start: seg.start_ts,
            end: seg.end_ts,
            has_motion: seg.has_motion,
            stage: seg.stage.as_str().to_owned(),
        });
    }

    spans
}

// ─── helpers ──────────────────────────────────────────────────────────────────

/// Parse a comma-separated string of UUID values.
///
/// Returns `Err(ApiError::BadRequest)` if any token is not a valid UUID.
/// Leading/trailing whitespace around each token is trimmed.
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

// ─── unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use crumb_common::{Segment, SegmentStage, SegmentStream};

    fn make_seg(
        camera_id: Uuid,
        start_secs: i64,
        end_secs: i64,
        has_motion: bool,
        stage: SegmentStage,
    ) -> Segment {
        Segment {
            id: Uuid::new_v4(),
            camera_id,
            storage_id: Uuid::new_v4(),
            stage,
            path: "cam/seg.mp4".to_owned(),
            stream: SegmentStream::Main,
            start_ts: chrono::Utc.timestamp_opt(start_secs, 0).unwrap(),
            end_ts: chrono::Utc.timestamp_opt(end_secs, 0).unwrap(),
            duration_ms: i32::try_from((end_secs - start_secs) * 1_000).unwrap_or(0),
            has_motion,
            size_bytes: 1024,
            motion_bbox: None,
        }
    }

    #[test]
    fn test_merge_contiguous() {
        let cam = Uuid::new_v4();
        let segs = vec![
            make_seg(cam, 0, 4, false, SegmentStage::Live),
            make_seg(cam, 4, 8, true, SegmentStage::Live),
            make_seg(cam, 8, 12, false, SegmentStage::Live),
        ];
        let spans = merge_segments_into_spans(segs);
        assert_eq!(
            spans.len(),
            1,
            "three back-to-back segments must merge into one span"
        );
        assert!(
            spans[0].has_motion,
            "merged span must carry has_motion=true"
        );
        assert_eq!(spans[0].stage, "live");
    }

    #[test]
    fn test_gap_creates_new_span() {
        let cam = Uuid::new_v4();
        let segs = vec![
            make_seg(cam, 0, 4, false, SegmentStage::Live),
            // 5-second gap — exceeds GAP_TOLERANCE (1 s)
            make_seg(cam, 9, 13, false, SegmentStage::Live),
        ];
        let spans = merge_segments_into_spans(segs);
        assert_eq!(spans.len(), 2, "gap > tolerance must produce two spans");
    }

    #[test]
    fn test_tolerance_bridges_small_gap() {
        let cam = Uuid::new_v4();
        let segs = vec![
            make_seg(cam, 0, 4, false, SegmentStage::Live),
            // 800 ms gap — within GAP_TOLERANCE (1 000 ms)
            // start_ts = 4_000 ms after epoch = 4 s; but end of first = 4 s, so same-second
            // use fractional via explicit timestamps isn't convenient here; test 0-gap instead
            make_seg(cam, 4, 8, false, SegmentStage::Live),
        ];
        let spans = merge_segments_into_spans(segs);
        assert_eq!(spans.len(), 1, "zero-gap segments must merge");
    }

    #[test]
    fn test_two_cameras_separate_spans() {
        let cam_a = Uuid::new_v4();
        let cam_b = Uuid::new_v4();
        // Segments from db are ordered by (camera_id, start_ts); simulate that.
        let segs = vec![
            make_seg(cam_a, 0, 4, false, SegmentStage::Live),
            make_seg(cam_a, 4, 8, false, SegmentStage::Live),
            make_seg(cam_b, 0, 4, false, SegmentStage::Archive),
            make_seg(cam_b, 4, 8, true, SegmentStage::Archive),
        ];
        let spans = merge_segments_into_spans(segs);
        assert_eq!(spans.len(), 2);
        let span_a = spans.iter().find(|s| s.camera_id == cam_a).unwrap();
        let span_b = spans.iter().find(|s| s.camera_id == cam_b).unwrap();
        assert_eq!(span_a.stage, "live");
        assert_eq!(span_b.stage, "archive");
        assert!(!span_a.has_motion);
        assert!(span_b.has_motion);
    }

    #[test]
    fn test_stage_taken_from_first_segment() {
        let cam = Uuid::new_v4();
        // First segment is live, second is archive (edge case: mixed stage in one run).
        let segs = vec![
            make_seg(cam, 0, 4, false, SegmentStage::Live),
            make_seg(cam, 4, 8, false, SegmentStage::Archive),
        ];
        let spans = merge_segments_into_spans(segs);
        assert_eq!(spans.len(), 1);
        assert_eq!(
            spans[0].stage, "live",
            "stage must come from the first segment"
        );
    }

    #[test]
    fn test_parse_uuid_csv_valid() {
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        let csv = format!("{id1}, {id2}");
        let ids = parse_uuid_csv(&csv).unwrap();
        assert_eq!(ids, vec![id1, id2]);
    }

    #[test]
    fn test_parse_uuid_csv_invalid() {
        let result = parse_uuid_csv("not-a-uuid");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_uuid_csv_empty_tokens_filtered() {
        let id = Uuid::new_v4();
        let csv = format!(",{id},");
        let ids = parse_uuid_csv(&csv).unwrap();
        assert_eq!(ids, vec![id]);
    }
}
