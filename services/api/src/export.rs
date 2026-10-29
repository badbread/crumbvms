// SPDX-License-Identifier: AGPL-3.0-or-later

//! Export routes — async multi-camera evidence export with timestamp burn-in.
//!
//! # Endpoints
//!
//! | Method | Path | Auth | Description |
//! |--------|------|------|-------------|
//! | `POST` | `/export` | Bearer | Start async export job |
//! | `GET`  | `/export/{job_id}` | Bearer | Poll job status + get download links |
//! | `GET`  | `/export/{job_id}/files/{camera_id}` | Bearer | Download a completed per-camera export file |
//! | `GET`  | `/export/{job_id}/archive` | Bearer | Download the ZIP archive (zipped jobs: password-protected OR multi-file) |
//!
//! # Job lifecycle
//!
//! 1. `POST /export` validates camera scope, inserts a `Queued` [`ExportJob`]
//!    into `state.export_jobs()`, spawns a detached tokio task, returns 202.
//! 2. The task marks the job `Running`, runs one ffmpeg process per camera
//!    (concat + trim + optional drawtext burn-in), parses stderr `out_time_ms`
//!    lines to update `progress_pct`, then bundles the output files into ONE ZIP
//!    (AES-256 encrypted when a password is given, otherwise Stored/unencrypted)
//!    whenever a password is set OR more than one file was produced — a single
//!    plain file with no password stays a plain video download. Marks `Done` or
//!    `Failed`.
//! 3. The TTL sweeper in `main.rs` removes completed jobs after the configured
//!    `export_ttl_seconds`.
//!
//! # ffmpeg strategy
//!
//! For each camera:
//! * Query `list_segments_for_range` to get ordered [`Segment`] rows.
//! * Write a temporary concat list to `{export_dir}/{job_id}/{camera_id}_concat.txt`.
//! * Run `/usr/local/bin/ffmpeg`:
//!   - `-f concat -safe 0 -i <concat.txt>`
//!   - `-ss <offset>` and `-t <duration>` to trim to exact `[start, end]`
//!   - Codec/audio/container args depend on `video_codec`, `include_audio`,
//!     `burn_timestamp`, and `container` (see `build_codec_args`).
//! * stderr is read line-by-line; `out_time_ms=` tokens update progress.
//!
//! # Path safety
//!
//! Job ID and camera ID are UUIDs so contain no path separators.  Output paths
//! are constructed as `{export_dir}/{uuid}/{uuid}.{ext}` and never derive from
//! user input.  All download handlers additionally `canonicalize` the resolved
//! path and verify it stays inside `export_dir`.

use std::path::PathBuf;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use chrono::Utc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};
use uuid::Uuid;

use crumb_common::db;
use crumb_common::types::Segment;

use crate::{
    auth_mw::AuthUser,
    dto::{
        BatchExportItem, CreateBatchExportRequest, CreateExportRequest, CreateExportResponse,
        ExportEstimateClip, ExportEstimateRequest, ExportEstimateResponse, ExportJob,
        ExportOutputFile, ExportStatus,
    },
    error::ApiError,
    state::AppState,
};

// ─── ffmpeg binary path ───────────────────────────────────────────────────────

/// Absolute path to the ffmpeg binary inside the container runtime image.
/// The Dockerfile symlinks `/usr/lib/jellyfin-ffmpeg/ffmpeg` to this path.
const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";

/// One validated batch clip: `(camera, start, end)`.
type BatchClip = (Uuid, chrono::DateTime<Utc>, chrono::DateTime<Utc>);

/// Upper bound on clips in a single batch export job (guards ffmpeg fan-out).
const MAX_BATCH_ITEMS: usize = 50;

/// Upper bound on DISTINCT cameras in a single `POST /export` job.
///
/// Both export routes fan out to one sequential ffmpeg run per unit of work, so
/// they get the same ceiling: `/export/batch` counts clips, `/export` counts
/// cameras. 50 is far beyond any real evidence export (the largest reference
/// install has eleven cameras) while still refusing a list that would keep the
/// single job slot busy for hours.
const MAX_EXPORT_CAMERAS: usize = 50;

/// Floor on the per-camera ffmpeg wall-clock budget, so a short export still
/// gets a sane allowance for spin-up, seeking, and a slow disk.
const EXPORT_FFMPEG_TIMEOUT_FLOOR_SECS: u64 = 600;

/// Wall-clock allowance per second of requested range. 4x realtime is very
/// forgiving even for a burn-in re-encode; anything slower than that is a wedged
/// child, not a busy one.
const EXPORT_FFMPEG_TIMEOUT_FACTOR: u64 = 4;

/// Absolute ceiling on the per-camera ffmpeg budget, whatever the range. Without
/// it a maximum-range job could hold its slot for days.
const EXPORT_FFMPEG_TIMEOUT_CEILING_SECS: u64 = 24 * 60 * 60;

/// Wall-clock budget for ONE camera's ffmpeg run over a `range_secs` window.
///
/// A child that neither exits nor gets dropped (a read wedged on a stalled
/// mount, say) used to leave the job `Running` forever, which permanently
/// consumed one of `EXPORT_MAX_CONCURRENT` slots: after enough of them every
/// `POST /export` returned 429 until the api was restarted. Bounding the wait
/// turns that into a `Failed` job with a stored error, which frees the slot and
/// tells the operator what happened.
fn export_ffmpeg_timeout(range_secs: i64) -> std::time::Duration {
    let range = u64::try_from(range_secs.max(0)).unwrap_or(u64::MAX);
    // The floor is a compile-time constant below the ceiling, so `clamp` cannot
    // panic here.
    let scaled = range.saturating_mul(EXPORT_FFMPEG_TIMEOUT_FACTOR).clamp(
        EXPORT_FFMPEG_TIMEOUT_FLOOR_SECS,
        EXPORT_FFMPEG_TIMEOUT_CEILING_SECS,
    );
    std::time::Duration::from_secs(scaled)
}

/// Validate a `POST /export` request's camera list and time range, returning the
/// cameras to actually export: sorted and de-duplicated.
///
/// De-duplication is the load-bearing part. `AuthUser::filter_camera_ids` is a
/// scope filter, NOT a dedup (for an admin it returns the list verbatim), so a
/// body repeating one camera N times used to run N sequential full-range ffmpeg
/// jobs, all writing the SAME `{camera_id}.{ext}` output with `-y`, and all
/// counted as ONE job against `EXPORT_MAX_CONCURRENT`. Collapsing duplicates
/// here makes the work proportional to what the caller can actually receive.
///
/// Kept pure (no state, no DB) so the caps are unit-testable.
fn validate_export_cameras_and_range(
    camera_ids: &[Uuid],
    start: chrono::DateTime<Utc>,
    end: chrono::DateTime<Utc>,
    max_range_seconds: i64,
) -> Result<Vec<Uuid>, ApiError> {
    if camera_ids.is_empty() {
        return Err(ApiError::BadRequest(
            "camera_ids must contain at least one camera".to_owned(),
        ));
    }
    if start >= end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }

    let range_seconds = (end - start).num_seconds();
    if range_seconds > max_range_seconds {
        return Err(ApiError::BadRequest(format!(
            "export range too large: {range_seconds} seconds requested, max {max_range_seconds} \
             (raise EXPORT_MAX_RANGE_SECONDS to allow longer exports)"
        )));
    }

    let mut distinct = camera_ids.to_vec();
    distinct.sort_unstable();
    distinct.dedup();
    if distinct.len() > MAX_EXPORT_CAMERAS {
        return Err(ApiError::BadRequest(format!(
            "too many cameras in one export ({} requested, max {MAX_EXPORT_CAMERAS})",
            distinct.len()
        )));
    }
    Ok(distinct)
}

// ─── route registry ───────────────────────────────────────────────────────────

/// Mount export routes onto the root router.
///
/// Called by `main.rs` with `.merge(export::routes())`.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/export", post(create_export))
        // Static path registered before the dynamic `:job_id` route below; matchit
        // gives static segments priority so `/export/batch` never resolves to a job id.
        .route("/export/batch", post(create_batch_export))
        .route("/export/estimate", post(estimate_export))
        .route(
            "/export/:job_id",
            get(get_export_status).delete(cancel_export),
        )
        .route(
            "/export/:job_id/files/:camera_id",
            get(download_export_file),
        )
        .route("/export/:job_id/archive", get(download_archive))
        .route("/export/:job_id/output/:index", get(download_output))
}

// ─── POST /export ─────────────────────────────────────────────────────────────

/// Start an async export job.
///
/// Validates camera scope, allocates a job UUID, inserts a `Queued` record,
/// spawns the ffmpeg worker task, and returns `202 Accepted` with the job ID
/// and a polling URL.
async fn create_export(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<CreateExportRequest>,
) -> Result<(StatusCode, Json<CreateExportResponse>), ApiError> {
    // ── capability gate ───────────────────────────────────────────────────────
    user.require_export()?;

    // ── validate ──────────────────────────────────────────────────────────────
    // Bounds the request BEFORE any work is allocated: non-empty, ordered,
    // within EXPORT_MAX_RANGE_SECONDS, and at most MAX_EXPORT_CAMERAS DISTINCT
    // cameras. Returns the de-duplicated camera list.
    let effective_ids = validate_export_cameras_and_range(
        &body.camera_ids,
        body.start,
        body.end,
        state.config().export_max_range_seconds,
    )?;

    // Scope: ALL-OR-NOTHING. Reject if ANY requested camera is outside the
    // caller's assigned list, matching /export/batch (create_batch_export) and
    // the archive download — a caller never gets a silently-narrowed partial
    // export they didn't ask for.
    if let Some(denied) = effective_ids.iter().find(|c| !user.can_access_camera(**c)) {
        return Err(ApiError::Forbidden(format!(
            "camera {denied} is not in your assigned camera list"
        )));
    }

    // ── concurrency cap ───────────────────────────────────────────────────────
    // Bound unbounded ffmpeg spawning: refuse new work when too many jobs are
    // already Queued/Running (audit Risk #19). Returns 429 so clients retry.
    let max_concurrent = state.config().export_max_concurrent;
    let active = state
        .export_jobs()
        .iter()
        .filter(|e| {
            matches!(
                e.value().status,
                ExportStatus::Queued | ExportStatus::Running
            )
        })
        .count();
    if active >= max_concurrent {
        return Err(ApiError::TooManyRequests(format!(
            "{active} export job(s) already in progress (max {max_concurrent}); retry shortly"
        )));
    }

    // ── allocate job ──────────────────────────────────────────────────────────
    let job_id = Uuid::new_v4();
    let job = ExportJob {
        id: job_id,
        status: ExportStatus::Queued,
        camera_ids: effective_ids.clone(),
        start: body.start,
        end: body.end,
        burn_timestamp: body.burn_timestamp,
        created_at: Utc::now(),
        output_files: vec![],
        error: None,
        progress_pct: 0,
    };

    // Insert BEFORE spawning so a poll arriving immediately can find it.
    state.export_jobs().insert(job_id, job);
    // Persist the Queued job so it survives an API restart (best-effort).
    persist_job_async(&state, job_id);

    // ── spawn worker ──────────────────────────────────────────────────────────
    // Extract every field we need from `body` before consuming it, so no
    // field is both partially moved and re-borrowed.  The password is taken
    // by value and never surfaces in a log field.
    let job_start = body.start;
    let job_end = body.end;
    let job_burn = body.burn_timestamp;
    let include_audio = body.include_audio;
    let video_codec = body.video_codec;
    let container = body.container;
    // Treat an explicitly set empty string the same as None (no zip mode).
    let password = body.password.filter(|p| !p.is_empty());

    let task_state = state.clone();
    let export_root = PathBuf::from(&state.config().export_dir).join(job_id.to_string());
    // Register a cancellation token BEFORE spawning so a DELETE arriving immediately
    // can find it. The worker selects on this to interrupt ffmpeg mid-encode.
    let cancel = CancellationToken::new();
    state.export_cancels().insert(job_id, cancel.clone());
    tokio::spawn(async move {
        run_export_job(
            task_state,
            job_id,
            effective_ids,
            job_start,
            job_end,
            job_burn,
            include_audio,
            video_codec,
            container,
            password,
            export_root,
            cancel,
        )
        .await;
    });

    Ok((
        StatusCode::ACCEPTED,
        Json(CreateExportResponse {
            job_id,
            status_url: format!("/export/{job_id}"),
        }),
    ))
}

// ─── GET /export/{job_id} ─────────────────────────────────────────────────────

/// Poll export job status.
///
/// Returns the full [`ExportJob`] snapshot.  Viewers are checked against the
/// cameras stored on the job — they cannot poll jobs they didn't create and
/// have no camera access to.
async fn get_export_status(
    user: AuthUser,
    State(state): State<AppState>,
    Path(job_id): Path<Uuid>,
) -> Result<Json<ExportJob>, ApiError> {
    let job = state
        .export_jobs()
        .get(&job_id)
        .map(|r| r.clone())
        .ok_or_else(|| ApiError::NotFound(format!("export job {job_id} not found")))?;

    // Viewers must have access to at least one camera in the job.
    let visible = user.filter_camera_ids(&job.camera_ids);
    if visible.is_empty() {
        return Err(ApiError::Forbidden(
            "you do not have access to this export job".to_owned(),
        ));
    }

    // Return only what the caller can see: strip out-of-scope camera UUIDs and
    // their per-camera download URLs, so polling a job you have only partial
    // access to doesn't disclose cameras outside your scope. The job's creator
    // and admins hold every camera in the job, so they see it unchanged. The
    // single nil-camera ZIP-archive entry names no specific camera, so it is
    // left in place (the archive download handler enforces its own scope).
    let visible_set: std::collections::HashSet<Uuid> = visible.iter().copied().collect();
    let mut job = job;
    job.camera_ids.retain(|c| visible_set.contains(c));
    job.output_files
        .retain(|f| f.camera_id.is_nil() || visible_set.contains(&f.camera_id));

    Ok(Json(job))
}

// ─── DELETE /export/{job_id} ──────────────────────────────────────────────────

/// Cancel a running or queued export job.
///
/// Fires the job's cancel token — the worker interrupts its ffmpeg mid-encode
/// (kills + reaps it), removes the output dir, frees the concurrency slot, and
/// marks the job `Cancelled` — and ALSO eagerly transitions the status to
/// `Cancelled` so an immediate `GET` sees the terminal state. Idempotent:
/// already-terminal jobs (Done/Failed/Cancelled) return success without acting.
/// The cancelled job lingers until the TTL sweeper evicts it, so the client's
/// poller observes one terminal `"cancelled"` and exits cleanly.
async fn cancel_export(
    user: AuthUser,
    State(state): State<AppState>,
    Path(job_id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    user.require_export()?;
    let job = state
        .export_jobs()
        .get(&job_id)
        .map(|r| r.clone())
        .ok_or_else(|| ApiError::NotFound(format!("export job {job_id} not found")))?;
    // Cancelling aborts the WHOLE job, so require access to EVERY camera in it —
    // not just one. The creator and admins hold them all; a viewer with partial
    // access must not be able to kill someone else's multi-camera export.
    // filter_camera_ids drops only out-of-scope cameras, so an equal length
    // means every camera is in the caller's scope.
    if user.filter_camera_ids(&job.camera_ids).len() != job.camera_ids.len() {
        return Err(ApiError::Forbidden(
            "you do not have access to all cameras in this export job".to_owned(),
        ));
    }

    // Already terminal → idempotent no-op success.
    if matches!(
        job.status,
        ExportStatus::Done | ExportStatus::Failed | ExportStatus::Cancelled
    ) {
        return Ok(StatusCode::NO_CONTENT);
    }

    // Signal the worker to interrupt ffmpeg + clean up.
    if let Some(tok) = state.export_cancels().get(&job_id) {
        tok.cancel();
    }
    // Eagerly mark Cancelled, but ONLY if still active — guarding inside the
    // get_mut keeps it atomic per-key so we never clobber a job that JUST raced to
    // Done. The worker also sets Cancelled when its select fires (idempotent).
    if let Some(mut j) = state.export_jobs().get_mut(&job_id) {
        if matches!(j.status, ExportStatus::Queued | ExportStatus::Running) {
            j.status = ExportStatus::Cancelled;
            j.error = Some("cancelled".to_owned());
        }
    }
    persist_job_async(&state, job_id);
    info!(%job_id, "export job cancel requested");
    Ok(StatusCode::NO_CONTENT)
}

// ─── GET /export/{job_id}/files/{camera_id} ───────────────────────────────────

/// Download a completed export file for one camera.
///
/// Streams the output file (MP4 or MKV) directly from the export directory.
/// Fails with 400 if the job is not yet done, or 404 if no output was produced
/// for the requested camera (e.g. the job used password ZIP mode and the raw
/// files were deleted).
async fn download_export_file(
    // Authenticated by the `Authorization: Bearer` header only, like every
    // other route: a login token in a `?token=` query lands in proxy/access
    // logs and browser history. Each client fetches the bytes itself and
    // writes the file, so none of them needs a header-less URL.
    user: AuthUser,
    State(state): State<AppState>,
    Path((job_id, camera_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, ApiError> {
    use axum::http::header;
    use tokio_util::io::ReaderStream;

    // Camera access check first.
    user.assert_camera_access(camera_id)?;

    // Job must exist and be Done.
    let job = state
        .export_jobs()
        .get(&job_id)
        .map(|r| r.clone())
        .ok_or_else(|| ApiError::NotFound(format!("export job {job_id} not found")))?;

    if job.status != ExportStatus::Done {
        return Err(ApiError::BadRequest(format!(
            "export job {job_id} is not complete (status: {:?})",
            job.status
        )));
    }

    // Find the output file entry for this camera.
    let output_entry = job
        .output_files
        .iter()
        .find(|f| f.camera_id == camera_id)
        .ok_or_else(|| {
            ApiError::NotFound(format!(
                "no output file for camera {camera_id} in job {job_id}"
            ))
        })?
        .clone();

    // Build the file path using the stored filename (which encodes the
    // container extension chosen at export time).
    let output_path = PathBuf::from(&state.config().export_dir)
        .join(job_id.to_string())
        .join(&output_entry.filename);

    let export_root = tokio::fs::canonicalize(&state.config().export_dir)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("canonicalize export_dir: {e}")))?;

    let resolved = tokio::fs::canonicalize(&output_path).await.map_err(|_| {
        ApiError::NotFound(format!(
            "output file for camera {camera_id} in job {job_id} does not exist on disk"
        ))
    })?;

    if !resolved.starts_with(&export_root) {
        warn!(
            %job_id,
            %camera_id,
            path = %resolved.display(),
            "path traversal guard rejected export download"
        );
        return Err(ApiError::BadRequest(
            "resolved path escapes the export directory".to_owned(),
        ));
    }

    // Pick Content-Type from the file extension.
    let content_type = match resolved.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "mp4" => "video/mp4",
        "mkv" => "video/x-matroska",
        _ => "application/octet-stream",
    };

    // Stream the file.
    let file = tokio::fs::File::open(&resolved)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("open export file: {e}")))?;

    let stream = ReaderStream::new(file);
    let body = axum::body::Body::from_stream(stream);
    // Use the stored filename as the download name.
    let dl_name = if output_entry.download_name.is_empty() {
        output_entry.filename.clone()
    } else {
        output_entry.download_name.clone()
    };

    let response = axum::response::Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CONTENT_LENGTH, output_entry.size_bytes.to_string())
        .header(header::CONTENT_DISPOSITION, content_disposition(&dl_name))
        .body(body)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build download response: {e}")))?;

    Ok(response)
}

// ─── GET /export/{job_id}/archive ─────────────────────────────────────────────

/// Download the ZIP archive for a zipped job.
///
/// A job is zipped when it had a non-empty `password` (AES-256 encrypted) OR it
/// produced more than one output file (Stored/unencrypted). The per-camera raw
/// files are deleted after the ZIP is built, so this is the only download
/// endpoint for such jobs.
async fn download_archive(
    // Multi-camera archive: no single-camera scoped token fits it, so it takes
    // the full session from the `Authorization: Bearer` header (never a
    // `?token=` query).
    user: AuthUser,
    State(state): State<AppState>,
    Path(job_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    use axum::http::header;
    use tokio_util::io::ReaderStream;

    // Job must exist and be Done.
    let job = state
        .export_jobs()
        .get(&job_id)
        .map(|r| r.clone())
        .ok_or_else(|| ApiError::NotFound(format!("export job {job_id} not found")))?;

    if job.status != ExportStatus::Done {
        return Err(ApiError::BadRequest(format!(
            "export job {job_id} is not complete (status: {:?})",
            job.status
        )));
    }

    // All-or-nothing camera check for archive downloads: the viewer must have
    // access to every camera in the job, not just one, because the archive
    // bundles all cameras' footage into a single file with no per-camera
    // boundaries.
    if job.camera_ids.iter().any(|c| !user.can_access_camera(*c)) {
        return Err(ApiError::Forbidden(
            "you do not have access to all cameras in this export job".to_owned(),
        ));
    }

    // Verify the job actually has a ZIP archive entry.
    let archive_entry = job
        .output_files
        .iter()
        .find(|f| f.camera_id == Uuid::nil())
        .ok_or_else(|| {
            ApiError::NotFound(format!(
                "no archive file for job {job_id} (job may not have used password mode)"
            ))
        })?
        .clone();

    // Build and canonicalize the path.
    let archive_path = PathBuf::from(&state.config().export_dir)
        .join(job_id.to_string())
        .join("crumb_export.zip");

    let export_root = tokio::fs::canonicalize(&state.config().export_dir)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("canonicalize export_dir: {e}")))?;

    let resolved = tokio::fs::canonicalize(&archive_path).await.map_err(|_| {
        ApiError::NotFound(format!(
            "archive file for job {job_id} does not exist on disk"
        ))
    })?;

    if !resolved.starts_with(&export_root) {
        warn!(
            %job_id,
            path = %resolved.display(),
            "path traversal guard rejected archive download"
        );
        return Err(ApiError::BadRequest(
            "resolved path escapes the export directory".to_owned(),
        ));
    }

    // Stream the ZIP file.
    let file = tokio::fs::File::open(&resolved)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("open archive file: {e}")))?;

    let stream = ReaderStream::new(file);
    let body = axum::body::Body::from_stream(stream);

    let response = axum::response::Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/zip")
        .header(header::CONTENT_LENGTH, archive_entry.size_bytes.to_string())
        .header(
            header::CONTENT_DISPOSITION,
            content_disposition(if archive_entry.download_name.is_empty() {
                "crumb_export.zip"
            } else {
                &archive_entry.download_name
            }),
        )
        .body(body)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build archive response: {e}")))?;

    Ok(response)
}

// ─── GET /export/{job_id}/output/{index} ──────────────────────────────────────

/// Download one entry of a job's `output_files` by its 0-based index.
///
/// A batch job can hold several clips from the SAME camera, so
/// `/export/:job_id/files/:camera_id` cannot address them; this route can.
/// Auth mirrors the older routes: `Authorization: Bearer` only, then
/// `assert_camera_access` on the entry's camera, or (for the nil-camera ZIP
/// entry) access to EVERY camera in the job, exactly like `download_archive`.
async fn download_output(
    user: AuthUser,
    State(state): State<AppState>,
    Path((job_id, index)): Path<(Uuid, usize)>,
) -> Result<impl IntoResponse, ApiError> {
    use axum::http::header;
    use tokio_util::io::ReaderStream;

    let job = state
        .export_jobs()
        .get(&job_id)
        .map(|r| r.clone())
        .ok_or_else(|| ApiError::NotFound(format!("export job {job_id} not found")))?;

    if job.status != ExportStatus::Done {
        return Err(ApiError::BadRequest(format!(
            "export job {job_id} is not complete (status: {:?})",
            job.status
        )));
    }

    let entry = job
        .output_files
        .get(index)
        .ok_or_else(|| ApiError::NotFound(format!("no output {index} in job {job_id}")))?
        .clone();

    if entry.camera_id == Uuid::nil() {
        if job.camera_ids.iter().any(|c| !user.can_access_camera(*c)) {
            return Err(ApiError::Forbidden(
                "you do not have access to all cameras in this export job".to_owned(),
            ));
        }
    } else {
        user.assert_camera_access(entry.camera_id)?;
    }

    let output_path = PathBuf::from(&state.config().export_dir)
        .join(job_id.to_string())
        .join(&entry.filename);

    let export_root = tokio::fs::canonicalize(&state.config().export_dir)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("canonicalize export_dir: {e}")))?;

    let resolved = tokio::fs::canonicalize(&output_path).await.map_err(|_| {
        ApiError::NotFound(format!(
            "output {index} of job {job_id} does not exist on disk"
        ))
    })?;

    if !resolved.starts_with(&export_root) {
        warn!(
            %job_id,
            index,
            path = %resolved.display(),
            "path traversal guard rejected export output download"
        );
        return Err(ApiError::BadRequest(
            "resolved path escapes the export directory".to_owned(),
        ));
    }

    let content_type = match resolved.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "mp4" => "video/mp4",
        "mkv" => "video/x-matroska",
        "zip" => "application/zip",
        _ => "application/octet-stream",
    };

    let file = tokio::fs::File::open(&resolved)
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("open export output: {e}")))?;
    let len = file.metadata().await.map_or(entry.size_bytes, |m| m.len());

    let dl_name = if entry.download_name.is_empty() {
        entry.filename.as_str()
    } else {
        entry.download_name.as_str()
    };

    axum::response::Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CONTENT_LENGTH, len.to_string())
        .header(header::CONTENT_DISPOSITION, content_disposition(dl_name))
        .body(axum::body::Body::from_stream(ReaderStream::new(file)))
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build output response: {e}")))
}

// ─── file naming helpers ──────────────────────────────────────────────────────

/// Longest camera-name part of a clip file name, in characters.
const NAME_PART_MAX_CHARS: usize = 60;

/// True for a Windows reserved device name (`CON`, `PRN`, `AUX`, `NUL`,
/// `COM1`-`COM9`, `LPT1`-`LPT9`), case-insensitive. `stem` is the part of the
/// file name before the first dot (Windows reserves `CON.txt` too).
fn is_windows_reserved(stem: &str) -> bool {
    let up = stem.to_ascii_uppercase();
    matches!(up.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (up.len() == 4
            && (up.starts_with("COM") || up.starts_with("LPT"))
            && matches!(up.as_bytes()[3], b'1'..=b'9'))
}

/// Make `raw` safe as (part of) a file name on Windows and POSIX.
///
/// Replaces `< > : " / \ | ? *` and control characters with `_`, collapses
/// whitespace runs, caps at `max_chars` characters (and twice that in bytes),
/// trims spaces and trailing dots, and prefixes `_` to a Windows reserved
/// device name. May return an empty string; callers supply a fallback.
fn sanitize_file_name(raw: &str, max_chars: usize) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut prev_space = true; // swallows leading whitespace
    for c in raw.chars() {
        if c.is_control() || "<>:\"/\\|?*".contains(c) {
            out.push('_');
            prev_space = false;
        } else if c.is_whitespace() {
            if !prev_space {
                out.push(' ');
            }
            prev_space = true;
        } else {
            out.push(c);
            prev_space = false;
        }
    }
    let mut capped: String = out.chars().take(max_chars).collect();
    while capped.len() > max_chars.saturating_mul(2) {
        capped.pop();
    }
    let trimmed = capped.trim_end_matches([' ', '.']);
    let stem = trimmed.split('.').next().unwrap_or("");
    if is_windows_reserved(stem) {
        format!("_{trimmed}")
    } else {
        trimmed.to_owned()
    }
}

/// `{Camera} {YYYY-MM-DD} {HH.MM.SS}-{HH.MM.SS}` in `tz`, or the
/// `{Camera} {date time} to {date time}` form when the clip crosses local
/// midnight. No extension.
fn clip_file_stem(
    camera_part: &str,
    start: chrono::DateTime<Utc>,
    end: chrono::DateTime<Utc>,
    tz: chrono_tz::Tz,
) -> String {
    let s = start.with_timezone(&tz);
    let e = end.with_timezone(&tz);
    if s.date_naive() == e.date_naive() {
        format!(
            "{camera_part} {} {}-{}",
            s.format("%Y-%m-%d"),
            s.format("%H.%M.%S"),
            e.format("%H.%M.%S")
        )
    } else {
        format!(
            "{camera_part} {} to {}",
            s.format("%Y-%m-%d %H.%M.%S"),
            e.format("%Y-%m-%d %H.%M.%S")
        )
    }
}

/// Return `{stem}.{ext}`, or `{stem} (2).{ext}`, `(3)`... when that name is
/// already in `used` (compared case-insensitively, as Windows would).
fn unique_file_name(used: &mut std::collections::HashSet<String>, stem: &str, ext: &str) -> String {
    let mut n = 1u32;
    loop {
        let name = if n == 1 {
            format!("{stem}.{ext}")
        } else {
            format!("{stem} ({n}).{ext}")
        };
        if used.insert(name.to_lowercase()) {
            return name;
        }
        n += 1;
    }
}

/// `Crumb export {YYYY-MM-DD HH.MM}.zip` in `tz` for the job creation time.
fn zip_download_name(created_at: chrono::DateTime<Utc>, tz: chrono_tz::Tz) -> String {
    format!(
        "Crumb export {}.zip",
        created_at.with_timezone(&tz).format("%Y-%m-%d %H.%M")
    )
}

/// RFC 6266 `Content-Disposition`: an ASCII-only `filename` fallback plus the
/// exact UTF-8 name in `filename*` (RFC 5987 percent-encoding).
fn content_disposition(name: &str) -> String {
    let ascii: String = name
        .chars()
        .map(|c| {
            if c.is_ascii() && !c.is_ascii_control() && c != '"' && c != '\\' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let mut pct = String::with_capacity(name.len() * 3);
    for b in name.bytes() {
        if b.is_ascii_alphanumeric() || b"!#$&+-.^_`|~".contains(&b) {
            pct.push(char::from(b));
        } else {
            pct.push_str(&format!("%{b:02X}"));
        }
    }
    format!("attachment; filename=\"{ascii}\"; filename*=UTF-8''{pct}")
}

/// How a batch job's clips are handed back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExportPackage {
    /// Today's rule: one zip when a password is set or >1 clip was produced.
    Zip,
    /// Every clip is its own download.
    Files,
}

/// Parse and cross-check the `package` / `password` request fields.
fn parse_package(package: &str, has_password: bool) -> Result<ExportPackage, ApiError> {
    match package {
        "zip" => Ok(ExportPackage::Zip),
        "files" if has_password => Err(ApiError::BadRequest(
            "a password requires package \"zip\" (encrypted exports are always zipped)".to_owned(),
        )),
        "files" => Ok(ExportPackage::Files),
        other => Err(ApiError::BadRequest(format!(
            "package must be \"zip\" or \"files\" (got \"{other}\")"
        ))),
    }
}

/// Build the job's `output_files` from the clips in `produced` (camera id +
/// file name, already on disk in `export_dir`). Zips them (and removes the
/// loose files) per `package` / `password`; see [`ExportPackage`].
async fn package_outputs(
    export_dir: &std::path::Path,
    job_id: Uuid,
    produced: Vec<(Uuid, String)>,
    password: Option<String>,
    package: ExportPackage,
    zip_name: &str,
) -> Result<Vec<ExportOutputFile>, String> {
    let zip_it = password.is_some() || (package == ExportPackage::Zip && produced.len() > 1);
    if !zip_it {
        let mut out = Vec::with_capacity(produced.len());
        for (i, (camera_id, name)) in produced.into_iter().enumerate() {
            let size_bytes = tokio::fs::metadata(export_dir.join(&name))
                .await
                .map_or(0, |m| m.len());
            out.push(ExportOutputFile {
                camera_id,
                download_url: format!("/export/{job_id}/output/{i}"),
                size_bytes,
                download_name: name.clone(),
                filename: name,
            });
        }
        return Ok(out);
    }

    let zip_path = export_dir.join("crumb_export.zip");
    let cleanup: Vec<String> = produced.iter().map(|(_, n)| n.clone()).collect();
    let zip_path_clone = zip_path.clone();
    let dir = export_dir.to_path_buf();
    let result = tokio::task::spawn_blocking(move || -> std::io::Result<()> {
        use zip::write::FileOptions;
        use zip::AesMode;
        use zip::CompressionMethod;

        let out_file = std::fs::File::create(&zip_path_clone)?;
        let mut zw = zip::write::ZipWriter::new(out_file);
        for (_camera_id, name) in &produced {
            // Separate scopes per branch so the differently-typed FileOptions
            // (AES carries the password lifetime) never need to unify.
            if let Some(p) = &password {
                let opts = FileOptions::<()>::default()
                    .compression_method(CompressionMethod::Stored)
                    .with_aes_encryption(AesMode::Aes256, p.as_str());
                zw.start_file(name.as_str(), opts)?;
            } else {
                // Stored (no compression): video is already compressed, and the
                // zip crate build here doesn't enable the deflate feature.
                let opts =
                    FileOptions::<()>::default().compression_method(CompressionMethod::Stored);
                zw.start_file(name.as_str(), opts)?;
            }
            let mut src = std::fs::File::open(dir.join(name))?;
            std::io::copy(&mut src, &mut zw)?;
        }
        zw.finish()?;
        Ok(())
    })
    .await;
    match result {
        Ok(Ok(())) => {}
        Ok(Err(e)) => return Err(format!("build zip archive: {e}")),
        Err(e) => return Err(format!("zip task panicked: {e}")),
    }

    // Only the archive remains downloadable.
    for name in &cleanup {
        let _ = tokio::fs::remove_file(export_dir.join(name)).await;
    }
    let size_bytes = tokio::fs::metadata(&zip_path).await.map_or(0, |m| m.len());
    Ok(vec![ExportOutputFile {
        camera_id: Uuid::nil(),
        download_url: format!("/export/{job_id}/output/0"),
        size_bytes,
        filename: "crumb_export.zip".to_owned(),
        download_name: zip_name.to_owned(),
    }])
}

// ─── POST /export/estimate ────────────────────────────────────────────────────

/// Estimate the size of a batch export without running it.
///
/// Same `require_export()` gate, per-item validation and per-camera access
/// checks as `POST /export/batch` (shared via [`validate_batch_items`]). Per
/// clip it sums, over the same `main`-stream segments `export_one_clip`
/// selects, `size_bytes * overlap / segment duration` in one SQL aggregate: no
/// file I/O. This approximates a stream-copy export; clients scale it for a
/// re-encode.
async fn estimate_export(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<ExportEstimateRequest>,
) -> Result<Json<ExportEstimateResponse>, ApiError> {
    user.require_export()?;
    let items = validate_batch_items(&user, &state, &body.items)?;

    let mut clips = Vec::with_capacity(items.len());
    let mut bytes: u64 = 0;
    let mut footage_seconds = 0.0_f64;
    for (camera_id, start, end) in &items {
        let (clip_bytes, clip_secs) =
            db::estimate_clip_footage(state.pool(), *camera_id, "main", *start, *end)
                .await
                .map_err(ApiError::Internal)?;
        bytes = bytes.saturating_add(clip_bytes);
        footage_seconds += clip_secs;
        clips.push(ExportEstimateClip {
            bytes: clip_bytes,
            footage_seconds: clip_secs,
        });
    }
    Ok(Json(ExportEstimateResponse {
        bytes,
        footage_seconds,
        clips,
    }))
}

// ─── export worker task ───────────────────────────────────────────────────────

/// Codec + audio arguments computed once per job.
struct CodecArgs {
    /// ffmpeg arguments that control video codec, audio, and container options.
    /// Placed after the `-t` duration and (if burning) after the `-vf` filter.
    args: Vec<String>,
    /// File extension for the output files (`"mp4"` or `"mkv"`).
    ext: &'static str,
}

/// Assemble the codec/audio/container ffmpeg arguments for a job.
///
/// `reencode` is true if either `burn_timestamp` is set (drawtext forces a
/// decode-encode cycle) or the caller explicitly requested a non-copy codec.
fn build_codec_args(
    burn_timestamp: bool,
    include_audio: bool,
    video_codec: &str,
    container: &str,
) -> CodecArgs {
    // Normalise codec + container (unknown values fall back to safe defaults).
    let vc = match video_codec {
        "h264" | "h265" => video_codec,
        _ => "copy",
    };
    let ext: &'static str = if container == "mkv" { "mkv" } else { "mp4" };

    // A re-encode is needed if the drawtext filter is active OR if the caller
    // explicitly chose a codec that requires a decode-encode pass.
    let reencode = burn_timestamp || vc != "copy";

    let mut args: Vec<String> = Vec::new();

    // Video codec args.
    if !reencode {
        args.extend(["-c:v".to_owned(), "copy".to_owned()]);
    } else if vc == "h265" {
        args.extend([
            "-c:v".to_owned(),
            "libx265".to_owned(),
            "-preset".to_owned(),
            "fast".to_owned(),
            "-crf".to_owned(),
            "23".to_owned(),
        ]);
        // Apple / QuickTime requires the hvc1 tag to play H.265 in MP4.
        if ext == "mp4" {
            args.extend(["-tag:v".to_owned(), "hvc1".to_owned()]);
        }
    } else {
        // h264 explicit, or copy-but-burn forces encode → libx264.
        args.extend([
            "-c:v".to_owned(),
            "libx264".to_owned(),
            "-preset".to_owned(),
            "fast".to_owned(),
            "-crf".to_owned(),
            "18".to_owned(),
        ]);
    }

    // Audio args.
    if !include_audio {
        args.push("-an".to_owned());
    } else if reencode {
        args.extend([
            "-c:a".to_owned(),
            "aac".to_owned(),
            "-b:a".to_owned(),
            "128k".to_owned(),
        ]);
    } else {
        // `-copyinkf:a` is MANDATORY on the audio copy path, same reason as the
        // recorder (see recording.rs / docs/RECORDER-CORRECTNESS.md): under
        // `-c copy` ffmpeg drops every packet until the first keyframe-flagged
        // one, and RTP-AAC audio is never key-flagged. The recorded fMP4's trun
        // sample flags faithfully preserve that missing key flag, so even a
        // correctly-recorded segment reads back with its audio unflagged — a
        // plain `-f concat … -c:a copy` would silently drop the audio all over
        // again. (The export output is non-fragmented mp4, so it re-writes
        // proper key flags and stays remux-safe in third-party tools.)
        args.extend([
            "-c:a".to_owned(),
            "copy".to_owned(),
            "-copyinkf:a".to_owned(),
        ]);
    }

    // MP4-specific: move the moov atom to the front for fast web streaming.
    if ext == "mp4" {
        args.extend(["-movflags".to_owned(), "+faststart".to_owned()]);
    }

    CodecArgs { args, ext }
}

/// Absolute on-disk path for a segment, resolved by its `storage_id`
/// (authoritative) via the pre-fetched `storage_paths` map. A segment's physical
/// location is defined SOLELY by its `storage_id` (→ `storages.path`); resolving
/// by `stage` instead breaks the moment a policy's `live_storage` is repointed to
/// another disk (footage then lives on a disk that no longer matches its stage).
/// If the segment's `storage_id` has no row in the map (should never happen —
/// `segments.storage_id` is NOT NULL with an `ON DELETE RESTRICT` FK), FAIL LOUDLY
/// rather than guessing a mount — guessing is the original migration bug. See
/// `crumb_common::db::segment_abs_path`.
fn seg_file_path(
    storage_paths: &std::collections::HashMap<Uuid, String>,
    seg: &Segment,
) -> Result<PathBuf, String> {
    let root = storage_paths.get(&seg.storage_id).ok_or_else(|| {
        format!(
            "segment {} storage row missing (storage_id={}); refusing to guess a mount",
            seg.id, seg.storage_id
        )
    })?;
    Ok(PathBuf::from(root).join(&seg.path))
}

// ─── cancellation primitives ──────────────────────────────────────────────────

/// Outcome of waiting on an ffmpeg child while watching the job's cancel token.
enum WaitOutcome {
    /// ffmpeg exited on its own; carries the `wait()` result.
    Finished(std::io::Result<std::process::ExitStatus>),
    /// The cancel token fired; the child was killed + reaped.
    Cancelled,
    /// The per-camera wall-clock budget elapsed; the child was killed + reaped.
    /// Carries the budget so the caller can name it in the stored job error.
    TimedOut(std::time::Duration),
}

/// Await an ffmpeg `child` while watching `token` and a wall-clock `budget`.
///
/// On cancel, SIGKILL + reap the child (so no zombie) and return
/// [`WaitOutcome::Cancelled`]; this interrupts a long single-camera encode
/// promptly, not just between cameras. On budget expiry, likewise kill + reap
/// and return [`WaitOutcome::TimedOut`] so the caller can FAIL the job. A
/// wedged child must never leave a job `Running` forever, because that
/// permanently consumes one of `EXPORT_MAX_CONCURRENT` slots.
async fn wait_or_cancel(
    child: &mut tokio::process::Child,
    token: &CancellationToken,
    budget: std::time::Duration,
) -> WaitOutcome {
    tokio::select! {
        res = child.wait() => WaitOutcome::Finished(res),
        () = token.cancelled() => {
            // `kill()` sends SIGKILL AND reaps the child (awaits its exit).
            let _ = child.kill().await;
            WaitOutcome::Cancelled
        }
        () = tokio::time::sleep(budget) => {
            let _ = child.kill().await;
            WaitOutcome::TimedOut(budget)
        }
    }
}

/// Per-clip result from [`export_one_clip`].
enum ClipStep {
    /// Produced an output file of this size (bytes).
    Produced(u64),
    /// No segments covered the requested range — caller decides skip vs fail.
    NoSegments,
    /// The job was cancelled mid-encode.
    Cancelled,
}

/// Transition a job to `Cancelled`: remove its output directory, mark the status,
/// drop the cancel token, and persist. Idempotent and never panics. The temp dir
/// removal is best-effort (a half-written job may have partial files).
async fn cancel_job(state: &AppState, job_id: Uuid, export_dir: &std::path::Path) {
    info!(%job_id, "export job cancelled — killing ffmpeg + cleaning up");
    let _ = tokio::fs::remove_dir_all(export_dir).await;
    if let Some(mut job) = state.export_jobs().get_mut(&job_id) {
        job.status = ExportStatus::Cancelled;
        job.error = Some("cancelled".to_owned());
    }
    state.export_cancels().remove(&job_id);
    persist_job_async(state, job_id);
}

/// Worker task: runs one ffmpeg process per camera, tracks progress, optionally
/// builds an AES-256 encrypted ZIP archive, then marks the job `Done` or
/// `Failed`.  Never panics.
// Detached worker fanned out from `create_export`; the request fields are passed
// individually rather than bundled into a struct that exists only to satisfy the
// lint.
#[allow(clippy::too_many_arguments)]
async fn run_export_job(
    state: AppState,
    job_id: Uuid,
    camera_ids: Vec<Uuid>,
    start: chrono::DateTime<Utc>,
    end: chrono::DateTime<Utc>,
    burn_timestamp: bool,
    include_audio: bool,
    video_codec: String,
    container: String,
    password: Option<String>,
    export_dir: PathBuf,
    cancel: CancellationToken,
) {
    info!(%job_id, cameras = camera_ids.len(), "export job starting");

    // Mark running.
    set_job_status(&state, job_id, ExportStatus::Running);

    // Create the per-job output directory.
    if let Err(e) = tokio::fs::create_dir_all(&export_dir).await {
        fail_job(&state, job_id, format!("create export dir: {e}"));
        return;
    }

    let pool = state.pool().clone();
    // Resolve each segment's file by its own storage_id (see seg_file_path); fetch
    // the id→path map once for the whole job rather than per-segment.
    let storage_paths = match db::storage_path_map(&pool).await {
        Ok(m) => m,
        Err(e) => {
            fail_job(&state, job_id, format!("load storages: {e}"));
            return;
        }
    };
    let n_cameras = camera_ids.len();
    let mut output_files: Vec<ExportOutputFile> = Vec::with_capacity(n_cameras);

    // Pre-compute codec args (same for every camera in the job).
    let codec = build_codec_args(burn_timestamp, include_audio, &video_codec, &container);
    let ext = codec.ext;
    // Per-camera wall-clock budget, derived from the requested range.
    let ffmpeg_budget = export_ffmpeg_timeout((end - start).num_seconds());

    for (cam_idx, &camera_id) in camera_ids.iter().enumerate() {
        info!(
            %job_id,
            %camera_id,
            cam = cam_idx + 1,
            total = n_cameras,
            "exporting camera segment"
        );

        // ── a. fetch covering segments ────────────────────────────────────────
        let segments = match db::list_segments_for_range(&pool, camera_id, "main", start, end).await
        {
            Ok(s) => s,
            Err(e) => {
                fail_job(
                    &state,
                    job_id,
                    format!("db error for camera {camera_id}: {e}"),
                );
                return;
            }
        };

        if segments.is_empty() {
            warn!(%job_id, %camera_id, "no segments in range, skipping camera");
            continue;
        }

        // ── b. write concat list ──────────────────────────────────────────────
        let concat_path = export_dir.join(format!("{camera_id}_concat.txt"));
        let mut concat_content = String::new();
        for seg in &segments {
            let abs = match seg_file_path(&storage_paths, seg) {
                Ok(p) => p,
                Err(e) => {
                    fail_job(&state, job_id, e);
                    return;
                }
            };
            // ffmpeg concat format: one `file '<path>'` line per segment.
            concat_content.push_str(&format!("file '{}'\n", abs.display()));
        }
        if let Err(e) = tokio::fs::write(&concat_path, concat_content.as_bytes()).await {
            fail_job(&state, job_id, format!("write concat list: {e}"));
            return;
        }

        // ── c. compute trim parameters ────────────────────────────────────────
        // The first segment may begin before `start`.  Compute -ss offset so
        // the output is trimmed to exactly [start, end].
        let first_seg_start = segments[0].start_ts;
        // Casts from i64 to f64: precision loss is acceptable for millisecond
        // timestamps (f64 has 53-bit mantissa; durations here fit comfortably).
        #[allow(clippy::cast_precision_loss)]
        let ss_secs: f64 = if start > first_seg_start {
            (start - first_seg_start).num_milliseconds().max(0) as f64 / 1000.0
        } else {
            0.0
        };
        #[allow(clippy::cast_precision_loss)]
        let duration_secs: f64 = (end - start).num_milliseconds().max(0) as f64 / 1000.0;

        // ── d. assemble ffmpeg arguments ──────────────────────────────────────
        let filename = format!("{camera_id}.{ext}");
        let output_path = export_dir.join(&filename);
        let mut args: Vec<String> = vec![
            // Overwrite without prompt.
            "-y".to_owned(),
            // Input: concat demuxer.
            "-f".to_owned(),
            "concat".to_owned(),
            "-safe".to_owned(),
            "0".to_owned(),
            "-i".to_owned(),
            concat_path.to_string_lossy().into_owned(),
            // Trim: skip leading gap, output only requested duration.
            "-ss".to_owned(),
            format!("{ss_secs:.3}"),
            "-t".to_owned(),
            format!("{duration_secs:.3}"),
        ];

        if burn_timestamp {
            // Burn wall-clock UTC time per frame.
            //
            // `pts` runs from 0 in the filtergraph; the first output frame
            // corresponds to `start` in UTC.  The `localtime` formatter uses
            // a base epoch (`wall_start_epoch_s`) and adds the current `pts`
            // in seconds so each frame shows its accurate wall-clock time.
            //
            // Format: `%Y-%m-%d %H:%M:%S` (UTC, rendered as localtime
            // because we pass the absolute epoch second as base).
            let wall_start_epoch_s = start.timestamp();
            let drawtext = format!(
                "drawtext=\
                 fontcolor=white:\
                 fontsize=24:\
                 box=1:\
                 boxcolor=black@0.5:\
                 boxborderw=4:\
                 x=10:\
                 y=10:\
                 text='%{{pts\\:localtime\\:{wall_start_epoch_s}\\:%Y-%m-%d %H\\:%M\\:%S}}'"
            );
            args.push("-vf".to_owned());
            args.push(drawtext);
        }

        // Codec / audio / container arguments (computed once above).
        args.extend(codec.args.iter().cloned());

        // Progress pipe: ffmpeg writes `out_time_ms=<us>` to stderr.
        args.extend(["-progress".to_owned(), "pipe:2".to_owned()]);

        args.push(output_path.to_string_lossy().into_owned());

        // ── e. spawn ffmpeg ───────────────────────────────────────────────────
        // kill_on_drop reaps the child if this worker task is ever dropped, so a
        // half-finished encode can't outlive the job that owns it.
        let mut child = match Command::new(FFMPEG_BIN)
            .args(&args)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                fail_job(&state, job_id, format!("spawn ffmpeg for {camera_id}: {e}"));
                return;
            }
        };

        // ── f. read progress from stderr ──────────────────────────────────────
        // We read stderr in the same task (child is held mutably).  Pull the
        // pipe handle out before calling wait().
        let stderr = child.stderr.take();
        let progress_state = state.clone();
        let progress_jid = job_id;
        let progress_dur = duration_secs;
        // Safe: cam_idx < n_cameras <= usize::MAX; result in 0-99 range, fits u8.
        #[allow(clippy::cast_possible_truncation)]
        let cam_base_pct = (cam_idx * 100 / n_cameras).min(99) as u8;
        // Per-camera progress slice; at least 1% so we always make forward progress.
        #[allow(clippy::cast_possible_truncation)]
        let cam_range_pct = (100 / n_cameras).clamp(1, 100) as u8;

        if let Some(stderr_pipe) = stderr {
            tokio::spawn(async move {
                update_progress_from_stderr(
                    progress_state,
                    progress_jid,
                    progress_dur,
                    cam_base_pct,
                    cam_range_pct,
                    stderr_pipe,
                )
                .await;
            });
        }

        let exit_status = match wait_or_cancel(&mut child, &cancel, ffmpeg_budget).await {
            WaitOutcome::Cancelled => {
                cancel_job(&state, job_id, &export_dir).await;
                return;
            }
            WaitOutcome::TimedOut(budget) => {
                fail_job(
                    &state,
                    job_id,
                    format!(
                        "ffmpeg for camera {camera_id} exceeded its {} s budget and was stopped",
                        budget.as_secs()
                    ),
                );
                return;
            }
            WaitOutcome::Finished(Ok(s)) => s,
            WaitOutcome::Finished(Err(e)) => {
                fail_job(&state, job_id, format!("wait ffmpeg for {camera_id}: {e}"));
                return;
            }
        };

        if !exit_status.success() {
            let code = exit_status
                .code()
                .map_or_else(|| "killed by signal".to_owned(), |c| c.to_string());
            fail_job(
                &state,
                job_id,
                format!("ffmpeg exited with {code} for camera {camera_id}"),
            );
            return;
        }

        // ── g. record output file ─────────────────────────────────────────────
        let size_bytes = tokio::fs::metadata(&output_path)
            .await
            .map_or(0, |m| m.len());

        output_files.push(ExportOutputFile {
            camera_id,
            download_url: format!("/export/{job_id}/files/{camera_id}"),
            size_bytes,
            filename: filename.clone(),
            download_name: String::new(),
        });

        // Clean up the temporary concat file.
        let _ = tokio::fs::remove_file(&concat_path).await;
    }

    // ── h. optional: AES-256 ZIP packaging ───────────────────────────────────
    // `password` is `Some` only when the caller supplied a non-empty string
    // (filtered at request-parsing time).  No logging of the password value.
    if let Some(pw) = password {
        // Collect the list of (on-disk path, zip entry name) pairs from
        // the output files we just produced.
        let file_pairs: Vec<(PathBuf, String)> = output_files
            .iter()
            .map(|f| {
                let disk_path = export_dir.join(&f.filename);
                // Camera UUIDs are alphanumeric + hyphens; replace hyphens with
                // underscores for a cleaner zip entry filename.
                let sanitized = f.camera_id.to_string().replace('-', "_");
                let entry_name = format!("crumb_{sanitized}.{ext}");
                (disk_path, entry_name)
            })
            .collect();

        let zip_path = export_dir.join("crumb_export.zip");
        let zip_path_clone = zip_path.clone();

        // Build the ZIP on a blocking thread (the zip crate uses
        // synchronous I/O throughout).
        let result = tokio::task::spawn_blocking(move || -> std::io::Result<()> {
            use zip::write::FileOptions;
            use zip::AesMode;
            use zip::CompressionMethod;

            let out_file = std::fs::File::create(&zip_path_clone)?;
            let mut zw = zip::write::ZipWriter::new(out_file);

            for (disk_path, entry_name) in &file_pairs {
                let opts = FileOptions::<()>::default()
                    .compression_method(CompressionMethod::Stored)
                    .with_aes_encryption(AesMode::Aes256, pw.as_str());
                zw.start_file(entry_name.as_str(), opts)?;
                let mut src = std::fs::File::open(disk_path)?;
                std::io::copy(&mut src, &mut zw)?;
            }

            zw.finish()?;
            Ok(())
        })
        .await;

        match result {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                fail_job(&state, job_id, format!("build zip archive: {e}"));
                return;
            }
            Err(e) => {
                fail_job(&state, job_id, format!("zip task panicked: {e}"));
                return;
            }
        }

        // Delete the raw per-camera files so only the encrypted ZIP
        // remains downloadable (security: the password is the whole point).
        for entry in &output_files {
            let raw_path = export_dir.join(&entry.filename);
            if let Err(e) = tokio::fs::remove_file(&raw_path).await {
                warn!(
                    %job_id,
                    path = %raw_path.display(),
                    error = %e,
                    "failed to delete raw export file after zip packaging"
                );
            }
        }

        // Replace output_files with a single entry pointing at the archive.
        let zip_size = tokio::fs::metadata(&zip_path).await.map_or(0, |m| m.len());

        output_files = vec![ExportOutputFile {
            camera_id: Uuid::nil(),
            download_url: format!("/export/{job_id}/archive"),
            size_bytes: zip_size,
            filename: "crumb_export.zip".to_owned(),
            download_name: String::new(),
        }];
    }

    // If cancelled during the (non-interruptible) ZIP/packaging step, honor it
    // rather than racing to Done.
    if cancel.is_cancelled() {
        cancel_job(&state, job_id, &export_dir).await;
        return;
    }

    // ── i. mark Done ──────────────────────────────────────────────────────────
    if let Some(mut job) = state.export_jobs().get_mut(&job_id) {
        job.status = ExportStatus::Done;
        job.output_files = output_files;
        job.progress_pct = 100;
    }
    // Persist the terminal Done state (with output file metadata) so completed
    // exports remain downloadable across an API restart.
    persist_job_async(&state, job_id);
    state.export_cancels().remove(&job_id);
    info!(%job_id, "export job complete");
}

// ─── POST /export/batch ───────────────────────────────────────────────────────

/// Start an commercial-VMS-style batch export: a list of `{camera, start, end}` clips
/// (cameras + ranges may differ per clip). The outputs are bundled into ONE
/// archive (`crumb_export.zip`) when a password is set OR more than one file is
/// produced (AES-256 when a password is given, otherwise Stored/unencrypted); a
/// single file with no password is left as a plain video download. Output
/// settings are global. Returns `202 Accepted` with the job id + polling URL.
async fn create_batch_export(
    user: AuthUser,
    State(state): State<AppState>,
    Json(body): Json<CreateBatchExportRequest>,
) -> Result<(StatusCode, Json<CreateExportResponse>), ApiError> {
    // ── capability gate ───────────────────────────────────────────────────────
    user.require_export()?;

    // Validate + scope every item up front (fail the whole request on a bad one).
    let items = validate_batch_items(&user, &state, &body.items)?;

    // Packaging. An empty password string means "no password". A password forces
    // zip, so password + "files" is a 400.
    let password = body.password.filter(|p| !p.is_empty());
    let package = parse_package(&body.package, password.is_some())?;

    // Concurrency cap (shared budget with single-range export).
    let max_concurrent = state.config().export_max_concurrent;
    let active = state
        .export_jobs()
        .iter()
        .filter(|e| {
            matches!(
                e.value().status,
                ExportStatus::Queued | ExportStatus::Running
            )
        })
        .count();
    if active >= max_concurrent {
        return Err(ApiError::TooManyRequests(format!(
            "{active} export job(s) already in progress (max {max_concurrent}); retry shortly"
        )));
    }

    let job_id = Uuid::new_v4();
    let mut distinct_cams: Vec<Uuid> = items.iter().map(|(c, _, _)| *c).collect();
    distinct_cams.sort();
    distinct_cams.dedup();
    let overall_start = items
        .iter()
        .map(|(_, s, _)| *s)
        .min()
        .unwrap_or_else(Utc::now);
    let overall_end = items
        .iter()
        .map(|(_, _, e)| *e)
        .max()
        .unwrap_or_else(Utc::now);

    let job = ExportJob {
        id: job_id,
        status: ExportStatus::Queued,
        camera_ids: distinct_cams,
        start: overall_start,
        end: overall_end,
        burn_timestamp: body.burn_timestamp,
        created_at: Utc::now(),
        output_files: vec![],
        error: None,
        progress_pct: 0,
    };
    state.export_jobs().insert(job_id, job);
    persist_job_async(&state, job_id);

    let burn = body.burn_timestamp;
    let include_audio = body.include_audio;
    let video_codec = body.video_codec;
    let container = body.container;
    let task_state = state.clone();
    let export_root = PathBuf::from(&state.config().export_dir).join(job_id.to_string());
    let cancel = CancellationToken::new();
    state.export_cancels().insert(job_id, cancel.clone());
    tokio::spawn(async move {
        run_batch_export_job(
            task_state,
            job_id,
            items,
            burn,
            include_audio,
            video_codec,
            container,
            password,
            package,
            export_root,
            cancel,
        )
        .await;
    });

    Ok((
        StatusCode::ACCEPTED,
        Json(CreateExportResponse {
            job_id,
            status_url: format!("/export/{job_id}"),
        }),
    ))
}

/// Validate a batch (or estimate) item list: non-empty, at most
/// `MAX_BATCH_ITEMS`, each clip ordered and within `EXPORT_MAX_RANGE_SECONDS`
/// (each item is one ffmpeg run), and every camera in the caller's scope
/// (all-or-nothing). Returns `(camera, start, end)` per item, in request order.
fn validate_batch_items(
    user: &AuthUser,
    state: &AppState,
    raw: &[BatchExportItem],
) -> Result<Vec<BatchClip>, ApiError> {
    if raw.is_empty() {
        return Err(ApiError::BadRequest(
            "items must contain at least one clip".to_owned(),
        ));
    }
    if raw.len() > MAX_BATCH_ITEMS {
        return Err(ApiError::BadRequest(format!(
            "too many clips in one batch (max {MAX_BATCH_ITEMS})"
        )));
    }
    let max_range_seconds = state.config().export_max_range_seconds;
    let mut items = Vec::with_capacity(raw.len());
    for it in raw {
        if it.start >= it.end {
            return Err(ApiError::BadRequest(
                "each clip's start must be strictly before its end".to_owned(),
            ));
        }
        let range_seconds = (it.end - it.start).num_seconds();
        if range_seconds > max_range_seconds {
            return Err(ApiError::BadRequest(format!(
                "clip range too large: {range_seconds} seconds requested, max \
                 {max_range_seconds} (raise EXPORT_MAX_RANGE_SECONDS to allow longer exports)"
            )));
        }
        user.assert_camera_access(it.camera_id)?;
        items.push((it.camera_id, it.start, it.end));
    }
    Ok(items)
}

// ─── shared single-clip ffmpeg step ───────────────────────────────────────────

/// Export ONE clip — a single camera over `[start,end]` — to `export_dir/{filename}`.
/// Writes the concat list (`concat_name`), trims to the exact range, applies the
/// shared codec/burn args, and streams ffmpeg progress into the
/// `[cam_base_pct, cam_base_pct+cam_range_pct]` slice of the job. Returns the
/// output size in bytes, `Ok(None)` when the range has no segments (caller decides
/// skip vs fail), or `Err` on a hard failure. Used by batch export.
#[allow(clippy::too_many_arguments)]
async fn export_one_clip(
    state: &AppState,
    job_id: Uuid,
    export_dir: &std::path::Path,
    camera_id: Uuid,
    start: chrono::DateTime<Utc>,
    end: chrono::DateTime<Utc>,
    burn_timestamp: bool,
    codec: &CodecArgs,
    filename: &str,
    concat_name: &str,
    cam_base_pct: u8,
    cam_range_pct: u8,
    token: &CancellationToken,
) -> Result<ClipStep, String> {
    let pool = state.pool();
    // Resolve each segment's file by its own storage_id (see seg_file_path).
    let storage_paths = db::storage_path_map(pool)
        .await
        .map_err(|e| format!("load storages: {e}"))?;

    let segments = db::list_segments_for_range(pool, camera_id, "main", start, end)
        .await
        .map_err(|e| format!("db error for camera {camera_id}: {e}"))?;
    if segments.is_empty() {
        return Ok(ClipStep::NoSegments);
    }

    let concat_path = export_dir.join(concat_name);
    let mut concat_content = String::new();
    for seg in &segments {
        let abs = seg_file_path(&storage_paths, seg)?;
        concat_content.push_str(&format!("file '{}'\n", abs.display()));
    }
    tokio::fs::write(&concat_path, concat_content.as_bytes())
        .await
        .map_err(|e| format!("write concat list: {e}"))?;

    let first_seg_start = segments[0].start_ts;
    #[allow(clippy::cast_precision_loss)]
    let ss_secs: f64 = if start > first_seg_start {
        (start - first_seg_start).num_milliseconds().max(0) as f64 / 1000.0
    } else {
        0.0
    };
    #[allow(clippy::cast_precision_loss)]
    let duration_secs: f64 = (end - start).num_milliseconds().max(0) as f64 / 1000.0;

    let output_path = export_dir.join(filename);
    let mut args: Vec<String> = vec![
        "-y".to_owned(),
        "-f".to_owned(),
        "concat".to_owned(),
        "-safe".to_owned(),
        "0".to_owned(),
        "-i".to_owned(),
        concat_path.to_string_lossy().into_owned(),
        "-ss".to_owned(),
        format!("{ss_secs:.3}"),
        "-t".to_owned(),
        format!("{duration_secs:.3}"),
    ];
    if burn_timestamp {
        let wall_start_epoch_s = start.timestamp();
        let drawtext = format!(
            "drawtext=fontcolor=white:fontsize=24:box=1:boxcolor=black@0.5:boxborderw=4:x=10:y=10:text='%{{pts\\:localtime\\:{wall_start_epoch_s}\\:%Y-%m-%d %H\\:%M\\:%S}}'"
        );
        args.push("-vf".to_owned());
        args.push(drawtext);
    }
    args.extend(codec.args.iter().cloned());
    args.extend(["-progress".to_owned(), "pipe:2".to_owned()]);
    args.push(output_path.to_string_lossy().into_owned());

    // kill_on_drop reaps the child if this worker task is ever dropped, so a
    // half-finished encode can't outlive the job that owns it.
    let mut child = Command::new(FFMPEG_BIN)
        .args(&args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("spawn ffmpeg for {camera_id}: {e}"))?;

    if let Some(stderr_pipe) = child.stderr.take() {
        let progress_state = state.clone();
        tokio::spawn(async move {
            update_progress_from_stderr(
                progress_state,
                job_id,
                duration_secs,
                cam_base_pct,
                cam_range_pct,
                stderr_pipe,
            )
            .await;
        });
    }

    let exit_status = match wait_or_cancel(
        &mut child,
        token,
        export_ffmpeg_timeout((end - start).num_seconds()),
    )
    .await
    {
        WaitOutcome::Cancelled => return Ok(ClipStep::Cancelled),
        WaitOutcome::TimedOut(budget) => {
            return Err(format!(
                "ffmpeg for camera {camera_id} exceeded its {} s budget and was stopped",
                budget.as_secs()
            ))
        }
        WaitOutcome::Finished(Ok(s)) => s,
        WaitOutcome::Finished(Err(e)) => return Err(format!("wait ffmpeg for {camera_id}: {e}")),
    };
    if !exit_status.success() {
        let code = exit_status
            .code()
            .map_or_else(|| "killed by signal".to_owned(), |c| c.to_string());
        return Err(format!("ffmpeg exited with {code} for camera {camera_id}"));
    }

    let size_bytes = tokio::fs::metadata(&output_path)
        .await
        .map_or(0, |m| m.len());
    let _ = tokio::fs::remove_file(&concat_path).await;
    Ok(ClipStep::Produced(size_bytes))
}

// ─── batch export worker ──────────────────────────────────────────────────────

/// Worker: render each clip with [`export_one_clip`], then bundle ALL clips into
/// ONE `crumb_export.zip` (AES-256 when `password` is set, else a plain Deflated
/// zip — a batch is always "exported together" as a single file). Marks the job
/// `Done` or `Failed`. Never panics.
#[allow(clippy::too_many_arguments)]
async fn run_batch_export_job(
    state: AppState,
    job_id: Uuid,
    items: Vec<(Uuid, chrono::DateTime<Utc>, chrono::DateTime<Utc>)>,
    burn_timestamp: bool,
    include_audio: bool,
    video_codec: String,
    container: String,
    password: Option<String>,
    package: ExportPackage,
    export_dir: PathBuf,
    cancel: CancellationToken,
) {
    info!(%job_id, clips = items.len(), "batch export job starting");
    set_job_status(&state, job_id, ExportStatus::Running);

    if let Err(e) = tokio::fs::create_dir_all(&export_dir).await {
        fail_job(&state, job_id, format!("create export dir: {e}"));
        return;
    }

    let codec = build_codec_args(burn_timestamp, include_audio, &video_codec, &container);
    let ext = codec.ext;
    let n = items.len();
    // (camera id, file name) for each clip that produced output. The same
    // friendly name is used on disk and as the zip entry / download name.
    let mut produced: Vec<(Uuid, String)> = Vec::with_capacity(n);

    // Friendly names: `{Camera Name} {date} {start}-{end}.{ext}` in the server's
    // local zone. Camera names come from the DB; fall back to the short id.
    let tz = state.config().server_tz;
    let mut cam_names: std::collections::HashMap<Uuid, String> = std::collections::HashMap::new();
    for (camera_id, _, _) in &items {
        if cam_names.contains_key(camera_id) {
            continue;
        }
        let short: String = camera_id.simple().to_string().chars().take(8).collect();
        let db_name = match db::get_camera(state.pool(), *camera_id).await {
            Ok(Some(c)) => sanitize_file_name(&c.name, NAME_PART_MAX_CHARS),
            _ => String::new(),
        };
        cam_names.insert(*camera_id, if db_name.is_empty() { short } else { db_name });
    }
    let mut used_names: std::collections::HashSet<String> = std::collections::HashSet::new();

    for (idx, (camera_id, start, end)) in items.iter().enumerate() {
        #[allow(clippy::cast_possible_truncation)]
        let cam_base_pct = (idx * 100 / n).min(99) as u8;
        #[allow(clippy::cast_possible_truncation)]
        let cam_range_pct = (100 / n).clamp(1, 100) as u8;
        let stem = clip_file_stem(&cam_names[camera_id], *start, *end, tz);
        let filename = unique_file_name(&mut used_names, &stem, ext);
        let concat_name = format!("batch_{idx}_concat.txt");

        match export_one_clip(
            &state,
            job_id,
            &export_dir,
            *camera_id,
            *start,
            *end,
            burn_timestamp,
            &codec,
            &filename,
            &concat_name,
            cam_base_pct,
            cam_range_pct,
            &cancel,
        )
        .await
        {
            Ok(ClipStep::Produced(_size)) => {
                produced.push((*camera_id, filename));
            }
            Ok(ClipStep::NoSegments) => {
                warn!(%job_id, %camera_id, "batch clip has no segments in range, skipping");
            }
            Ok(ClipStep::Cancelled) => {
                cancel_job(&state, job_id, &export_dir).await;
                return;
            }
            Err(e) => {
                fail_job(&state, job_id, e);
                return;
            }
        }
    }

    if produced.is_empty() {
        fail_job(
            &state,
            job_id,
            "no footage found for any clip in the list".to_owned(),
        );
        return;
    }

    // Packaging rule: zip iff a password is set, or package is "zip" and more than
    // one file was produced. A single plain file (no password) is left as-is; in
    // "files" mode every clip is its own output entry.
    let created_at = state
        .export_jobs()
        .get(&job_id)
        .map_or_else(Utc::now, |j| j.created_at);
    let zip_name = zip_download_name(created_at, tz);
    let output_files =
        match package_outputs(&export_dir, job_id, produced, password, package, &zip_name).await {
            Ok(files) => files,
            Err(e) => {
                fail_job(&state, job_id, e);
                return;
            }
        };

    // Honor a cancel that arrived during the non-interruptible ZIP/packaging step.
    if cancel.is_cancelled() {
        cancel_job(&state, job_id, &export_dir).await;
        return;
    }

    if let Some(mut job) = state.export_jobs().get_mut(&job_id) {
        job.status = ExportStatus::Done;
        job.output_files = output_files;
        job.progress_pct = 100;
    }
    persist_job_async(&state, job_id);
    state.export_cancels().remove(&job_id);
    info!(%job_id, "batch export job complete");
}

// ─── helpers ──────────────────────────────────────────────────────────────────

/// Persist the current DB snapshot of a job, fire-and-forget.
///
/// Clones the job out of the map (releasing the lock) and spawns the upsert so
/// callers stay synchronous and never block on the DB. Best-effort: a failed
/// write logs a WARN; the in-memory map remains authoritative within the run.
///
/// NOTE: the clone happens via `.get()`, so callers MUST have dropped any
/// `get_mut` guard on the same key before calling this (else `DashMap` deadlocks).
fn persist_job_async(state: &AppState, job_id: Uuid) {
    let Some(job) = state.export_jobs().get(&job_id).map(|r| r.clone()) else {
        return;
    };
    let pool = state.pool().clone();
    tokio::spawn(async move {
        if let Err(e) = crate::export_store::upsert_export_job(&pool, &job).await {
            warn!(%job_id, error = %e, "failed to persist export job");
        }
    });
}

/// Transition a job to `Failed` with a human-readable error message.
fn fail_job(state: &AppState, job_id: Uuid, message: String) {
    error!(%job_id, error = %message, "export job failed");
    if let Some(mut job) = state.export_jobs().get_mut(&job_id) {
        job.status = ExportStatus::Failed;
        job.error = Some(message);
    }
    // Terminal: drop the cancel token so the map doesn't leak entries.
    state.export_cancels().remove(&job_id);
    persist_job_async(state, job_id);
}

/// Set job status without touching other fields.
fn set_job_status(state: &AppState, job_id: Uuid, status: ExportStatus) {
    if let Some(mut job) = state.export_jobs().get_mut(&job_id) {
        job.status = status;
    }
    persist_job_async(state, job_id);
}

/// Read ffmpeg's `-progress pipe:2` output and translate elapsed time into a
/// `progress_pct` update on the in-memory job.
///
/// ffmpeg with `-progress pipe:2` emits KV lines on stderr:
/// ```text
/// out_time_ms=1234567
/// ...
/// progress=continue
/// ```
/// We parse `out_time_ms` (microseconds) and map it to the 0-100 range for
/// this camera's slice of the overall job progress.
async fn update_progress_from_stderr(
    state: AppState,
    job_id: Uuid,
    total_duration_secs: f64,
    cam_base_pct: u8,
    cam_range_pct: u8,
    stderr: tokio::process::ChildStderr,
) {
    if total_duration_secs <= 0.0 {
        return;
    }
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        // ffmpeg -progress outputs `out_time_ms=<microseconds>` (despite the
        // name the unit is microseconds, not milliseconds).
        if let Some(val) = line.strip_prefix("out_time_ms=") {
            if let Ok(us) = val.trim().parse::<i64>() {
                #[allow(clippy::cast_precision_loss)]
                let elapsed_secs = us as f64 / 1_000_000.0;
                let ratio = (elapsed_secs / total_duration_secs).clamp(0.0, 1.0);
                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                let pct = cam_base_pct + (ratio * f64::from(cam_range_pct)) as u8;
                if let Some(mut job) = state.export_jobs().get_mut(&job_id) {
                    job.progress_pct = pct;
                }
            }
        }
    }
}

// ─── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Cancelling a job must KILL and REAP the ffmpeg child (no zombie). We stand
    /// a long-lived `sleep` in for ffmpeg: a pre-cancelled token drives
    /// `wait_or_cancel` down the cancel branch, which must SIGKILL the child and
    /// leave it reaped (this is the core of "the ffmpeg child is reaped on cancel").
    #[tokio::test]
    async fn cancel_kills_and_reaps_child() {
        let mut child = tokio::process::Command::new("sleep")
            .arg("60")
            .spawn()
            .expect("spawn sleep stand-in for ffmpeg");

        let token = CancellationToken::new();
        token.cancel(); // already cancelled → take the cancel branch immediately

        let outcome = wait_or_cancel(&mut child, &token, std::time::Duration::from_mins(10)).await;
        assert!(matches!(outcome, WaitOutcome::Cancelled));

        // Dead AND reaped: try_wait returns Some(exit status), no error/zombie.
        let reaped = child.try_wait().expect("try_wait should not error");
        assert!(reaped.is_some(), "ffmpeg child was not reaped after cancel");
    }

    /// With no cancellation, `wait_or_cancel` lets the child finish normally.
    #[tokio::test]
    async fn finishes_when_not_cancelled() {
        let mut child = tokio::process::Command::new("true")
            .spawn()
            .expect("spawn true");
        let token = CancellationToken::new(); // not cancelled
        let outcome = wait_or_cancel(&mut child, &token, std::time::Duration::from_mins(10)).await;
        assert!(matches!(outcome, WaitOutcome::Finished(Ok(s)) if s.success()));
    }

    /// A child that never exits must be KILLED and REAPED when its wall-clock
    /// budget elapses, and reported as `TimedOut` so the job fails with a stored
    /// error instead of sitting `Running` forever and burning a concurrency slot.
    #[tokio::test]
    async fn budget_expiry_kills_reaps_and_reports_timeout() {
        let mut child = tokio::process::Command::new("sleep")
            .arg("60")
            .kill_on_drop(true)
            .spawn()
            .expect("spawn sleep stand-in for ffmpeg");
        let token = CancellationToken::new(); // not cancelled

        let outcome =
            wait_or_cancel(&mut child, &token, std::time::Duration::from_millis(150)).await;
        assert!(
            matches!(outcome, WaitOutcome::TimedOut(_)),
            "a child that outlives its budget must report TimedOut"
        );
        let reaped = child.try_wait().expect("try_wait should not error");
        assert!(
            reaped.is_some(),
            "ffmpeg child was not reaped after timeout"
        );
    }

    // ── per-camera ffmpeg budget ────────────────────────────────────────────────

    #[test]
    fn export_ffmpeg_budget_is_floored_scaled_and_capped() {
        // Short range → the floor, so a 10 s clip still gets spin-up room.
        assert_eq!(
            export_ffmpeg_timeout(10).as_secs(),
            EXPORT_FFMPEG_TIMEOUT_FLOOR_SECS
        );
        // Mid range → 4x realtime.
        assert_eq!(export_ffmpeg_timeout(3600).as_secs(), 3600 * 4);
        // Maximum range → the absolute ceiling, never unbounded.
        assert_eq!(
            export_ffmpeg_timeout(i64::MAX).as_secs(),
            EXPORT_FFMPEG_TIMEOUT_CEILING_SECS
        );
        // Nonsense input is still finite.
        assert_eq!(
            export_ffmpeg_timeout(-5).as_secs(),
            EXPORT_FFMPEG_TIMEOUT_FLOOR_SECS
        );
    }

    // ── POST /export validation ─────────────────────────────────────────────────

    /// Helper: a valid one-hour window.
    fn one_hour() -> (chrono::DateTime<Utc>, chrono::DateTime<Utc>) {
        let start = Utc::now();
        (start, start + chrono::Duration::hours(1))
    }

    #[test]
    fn export_validation_dedups_and_sorts_the_camera_list() {
        let (start, end) = one_hour();
        let a = Uuid::from_u128(1);
        let b = Uuid::from_u128(2);
        // The shape that used to run N sequential full-range ffmpeg jobs writing
        // the SAME output file, all counted as ONE job against the concurrency
        // cap: one camera repeated many times.
        let requested = vec![b, a, b, a, b, b, b, b];
        let out = validate_export_cameras_and_range(&requested, start, end, 86_400)
            .expect("a duplicated but in-range list is valid");
        assert_eq!(out, vec![a, b], "duplicates collapse; order is stable");
    }

    #[test]
    fn export_validation_rejects_an_over_long_range() {
        let start = Utc::now();
        let end = start + chrono::Duration::seconds(86_401);
        let err = validate_export_cameras_and_range(&[Uuid::from_u128(1)], start, end, 86_400)
            .expect_err("a range past the cap must be refused");
        assert_eq!(err.status(), StatusCode::BAD_REQUEST);
        assert!(
            err.to_string().contains("range too large"),
            "message should say why: {err}"
        );
        // Exactly at the cap is fine (the bound is inclusive).
        validate_export_cameras_and_range(
            &[Uuid::from_u128(1)],
            start,
            start + chrono::Duration::seconds(86_400),
            86_400,
        )
        .expect("a range exactly at the cap is allowed");
    }

    #[test]
    fn export_validation_rejects_too_many_distinct_cameras() {
        let (start, end) = one_hour();
        let too_many: Vec<Uuid> = (0..=u128::try_from(MAX_EXPORT_CAMERAS).unwrap())
            .map(Uuid::from_u128)
            .collect();
        let err = validate_export_cameras_and_range(&too_many, start, end, 86_400)
            .expect_err("more distinct cameras than the cap must be refused");
        assert_eq!(err.status(), StatusCode::BAD_REQUEST);

        // The cap counts DISTINCT cameras, so a long list of duplicates passes.
        let mut duplicated = vec![Uuid::from_u128(7); MAX_EXPORT_CAMERAS * 4];
        duplicated.push(Uuid::from_u128(8));
        let out = validate_export_cameras_and_range(&duplicated, start, end, 86_400)
            .expect("duplicates do not count against the camera cap");
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn export_validation_rejects_empty_and_inverted_ranges() {
        let (start, end) = one_hour();
        assert_eq!(
            validate_export_cameras_and_range(&[], start, end, 86_400)
                .expect_err("empty camera list")
                .status(),
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            validate_export_cameras_and_range(&[Uuid::from_u128(1)], end, start, 86_400)
                .expect_err("inverted range")
                .status(),
            StatusCode::BAD_REQUEST
        );
    }

    // ── build_codec_args audio handling ─────────────────────────────────────────

    /// The audio-copy path MUST carry `-copyinkf:a`. The recorder writes fMP4
    /// whose trun sample flags faithfully record that RTP-AAC audio was never
    /// key-flagged, so a plain `-f concat … -c:a copy` re-drops the audio (every
    /// packet before the first "keyframe" is discarded, and none is flagged) —
    /// producing a silent export even from correctly-recorded footage. Guards
    /// the fix from being cleaned away.
    #[test]
    fn copy_audio_export_keeps_initial_non_keyframes() {
        let a = build_codec_args(false, true, "copy", "mp4").args;
        // -c:a copy present, immediately followed/accompanied by -copyinkf:a.
        assert!(
            a.windows(2).any(|w| w == ["-c:a", "copy"]),
            "expected -c:a copy; got {a:?}"
        );
        assert!(
            a.iter().any(|s| s == "-copyinkf:a"),
            "copy-audio export MUST include -copyinkf:a; got {a:?}"
        );
    }

    /// Dropping audio (`include_audio=false`) still emits `-an` and never the
    /// copy flag; the re-encode path transcodes (`-c:a aac`) so the keyframe
    /// gate doesn't apply and the flag is neither needed nor emitted.
    #[test]
    fn no_audio_and_reencode_paths_omit_copyinkf() {
        let dropped = build_codec_args(false, false, "copy", "mp4").args;
        assert!(dropped.iter().any(|s| s == "-an"), "got {dropped:?}");
        assert!(
            !dropped.iter().any(|s| s == "-copyinkf:a"),
            "no audio → no copy flag; got {dropped:?}"
        );

        let reencoded = build_codec_args(true, true, "copy", "mp4").args;
        assert!(
            reencoded.windows(2).any(|w| w == ["-c:a", "aac"]),
            "burn_timestamp forces a re-encode → -c:a aac; got {reencoded:?}"
        );
        assert!(
            !reencoded.iter().any(|s| s == "-copyinkf:a"),
            "re-encode path decodes audio, no keyframe gate; got {reencoded:?}"
        );
    }

    // ── file naming ───────────────────────────────────────────────────────────

    fn utc(s: &str) -> chrono::DateTime<Utc> {
        chrono::DateTime::parse_from_rfc3339(s).unwrap().into()
    }

    #[test]
    fn sanitizer_replaces_illegal_chars_and_collapses_whitespace() {
        assert_eq!(
            sanitize_file_name("Front <Door>: \"A/B\\C|D?E*", 60),
            "Front _Door__ _A_B_C_D_E_"
        );
        assert_eq!(sanitize_file_name("  Back \t\n yard  ", 60), "Back __ yard");
        assert_eq!(sanitize_file_name("a\u{0}b", 60), "a_b");
        // Spaces and trailing dots are trimmed; inner dots survive.
        assert_eq!(sanitize_file_name(" Cam 1. . ", 60), "Cam 1");
        assert_eq!(sanitize_file_name("v1.2 cam", 60), "v1.2 cam");
        assert_eq!(sanitize_file_name("...", 60), "");
        // Non-ASCII passes through untouched.
        assert_eq!(
            sanitize_file_name("Garten Küche 車庫", 60),
            "Garten Küche 車庫"
        );
    }

    #[test]
    fn sanitizer_caps_length_in_chars_and_bytes() {
        let long = "x".repeat(200);
        assert_eq!(sanitize_file_name(&long, 60).chars().count(), 60);
        let cjk = "車".repeat(200);
        let out = sanitize_file_name(&cjk, 60);
        assert!(
            out.chars().count() <= 60 && out.len() <= 120,
            "{}",
            out.len()
        );
    }

    #[test]
    fn sanitizer_prefixes_windows_reserved_names() {
        for n in [
            "CON", "con", "Prn", "AUX", "nul", "COM1", "lpt9", "NUL.txt", "con.mp4",
        ] {
            assert_eq!(sanitize_file_name(n, 60), format!("_{n}"), "{n}");
        }
        for n in ["COM0", "COM10", "CONSOLE", "Console 1", "LPT"] {
            assert_eq!(sanitize_file_name(n, 60), n, "{n}");
        }
    }

    #[test]
    fn clip_stem_same_day_and_cross_midnight() {
        let tz: chrono_tz::Tz = "America/Los_Angeles".parse().unwrap();
        // 2026-10-29 21:05:06Z is 14:05:06 PDT.
        let same = clip_file_stem(
            "Driveway",
            utc("2026-10-29T21:05:06Z"),
            utc("2026-10-29T21:09:10Z"),
            tz,
        );
        assert_eq!(same, "Driveway 2026-10-29 14.05.06-14.09.10");
        // 06:59:50Z..07:00:10Z crosses local midnight? 23:59:50 -> 00:00:10 PDT.
        let cross = clip_file_stem(
            "Driveway",
            utc("2026-10-30T06:59:50Z"),
            utc("2026-10-30T07:00:10Z"),
            tz,
        );
        assert_eq!(cross, "Driveway 2026-10-29 23.59.50 to 2026-10-30 00.00.10");
        // The same instants are one UTC date, so the zone matters.
        let utc_form = clip_file_stem(
            "Driveway",
            utc("2026-10-30T06:59:50Z"),
            utc("2026-10-30T07:00:10Z"),
            chrono_tz::UTC,
        );
        assert_eq!(utc_form, "Driveway 2026-10-30 06.59.50-07.00.10");
    }

    #[test]
    fn duplicate_names_get_a_counter_before_the_extension() {
        let mut used = std::collections::HashSet::new();
        assert_eq!(unique_file_name(&mut used, "Cam 1", "mp4"), "Cam 1.mp4");
        assert_eq!(unique_file_name(&mut used, "Cam 1", "mp4"), "Cam 1 (2).mp4");
        assert_eq!(unique_file_name(&mut used, "CAM 1", "mp4"), "CAM 1 (3).mp4");
        assert_eq!(unique_file_name(&mut used, "Cam 2", "mp4"), "Cam 2.mp4");
    }

    #[test]
    fn zip_name_uses_server_zone_to_the_minute() {
        let tz: chrono_tz::Tz = "America/Los_Angeles".parse().unwrap();
        assert_eq!(
            zip_download_name(utc("2026-10-29T21:05:59Z"), tz),
            "Crumb export 2026-10-29 14.05.zip"
        );
    }

    #[test]
    fn content_disposition_has_ascii_fallback_and_utf8_name() {
        assert_eq!(
            content_disposition("Front Door 2026-10-29 14.05.06-14.09.10.mp4"),
            "attachment; filename=\"Front Door 2026-10-29 14.05.06-14.09.10.mp4\"; \
             filename*=UTF-8''Front%20Door%202026-10-29%2014.05.06-14.09.10.mp4"
        );
        let cd = content_disposition("Küche \"x\".mp4");
        assert!(
            cd.starts_with("attachment; filename=\"K_che _x_.mp4\";"),
            "{cd}"
        );
        assert!(
            cd.ends_with("filename*=UTF-8''K%C3%BCche%20%22x%22.mp4"),
            "{cd}"
        );
        assert!(cd.is_ascii());
    }

    #[test]
    fn package_parsing_rules() {
        assert_eq!(parse_package("zip", false).unwrap(), ExportPackage::Zip);
        assert_eq!(parse_package("zip", true).unwrap(), ExportPackage::Zip);
        assert_eq!(parse_package("files", false).unwrap(), ExportPackage::Files);
        assert!(matches!(
            parse_package("files", true),
            Err(ApiError::BadRequest(_))
        ));
        assert!(matches!(
            parse_package("tar", false),
            Err(ApiError::BadRequest(_))
        ));
    }

    async fn packaging_fixture(names: &[&str]) -> (PathBuf, Uuid, Vec<(Uuid, String)>) {
        let job_id = Uuid::new_v4();
        let dir = std::env::temp_dir().join(format!("crumb-pkg-{job_id}"));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let mut produced = Vec::new();
        for n in names {
            tokio::fs::write(dir.join(n), format!("bytes of {n}"))
                .await
                .unwrap();
            produced.push((Uuid::new_v4(), (*n).to_owned()));
        }
        (dir, job_id, produced)
    }

    #[tokio::test]
    async fn files_mode_lists_every_clip_as_its_own_output() {
        let (dir, job_id, produced) = packaging_fixture(&["A 1.mp4", "A 2.mp4", "B.mp4"]).await;
        let out = package_outputs(
            &dir,
            job_id,
            produced.clone(),
            None,
            ExportPackage::Files,
            "z.zip",
        )
        .await
        .unwrap();
        assert_eq!(out.len(), 3);
        for (i, f) in out.iter().enumerate() {
            assert_eq!(f.download_url, format!("/export/{job_id}/output/{i}"));
            assert_eq!(f.camera_id, produced[i].0);
            assert_eq!(f.filename, produced[i].1);
            assert_eq!(f.download_name, produced[i].1);
            assert!(f.size_bytes > 0);
            assert!(
                dir.join(&f.filename).exists(),
                "files mode keeps loose files"
            );
        }
        assert!(!dir.join("crumb_export.zip").exists());
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }

    #[tokio::test]
    async fn zip_mode_bundles_multiple_clips_but_keeps_a_single_one_plain() {
        let (dir, job_id, produced) = packaging_fixture(&["A.mp4", "B.mp4"]).await;
        let out = package_outputs(
            &dir,
            job_id,
            produced,
            None,
            ExportPackage::Zip,
            "Crumb export 2026-10-29 14.05.zip",
        )
        .await
        .unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].camera_id, Uuid::nil());
        assert_eq!(out[0].filename, "crumb_export.zip");
        assert_eq!(out[0].download_name, "Crumb export 2026-10-29 14.05.zip");
        assert_eq!(out[0].download_url, format!("/export/{job_id}/output/0"));
        assert!(
            !dir.join("A.mp4").exists(),
            "loose clips are removed after zipping"
        );
        // The entries are named with the friendly names.
        let zf = std::fs::File::open(dir.join("crumb_export.zip")).unwrap();
        let mut za = zip::ZipArchive::new(zf).unwrap();
        let mut names: Vec<String> = (0..za.len())
            .map(|i| za.by_index(i).unwrap().name().to_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["A.mp4", "B.mp4"]);
        let _ = tokio::fs::remove_dir_all(&dir).await;

        let (dir, job_id, produced) = packaging_fixture(&["Only.mp4"]).await;
        let out = package_outputs(&dir, job_id, produced, None, ExportPackage::Zip, "z.zip")
            .await
            .unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].filename, "Only.mp4");
        assert_eq!(out[0].download_url, format!("/export/{job_id}/output/0"));
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }

    #[tokio::test]
    async fn a_password_zips_even_a_single_clip() {
        let (dir, job_id, produced) = packaging_fixture(&["Only.mp4"]).await;
        let out = package_outputs(
            &dir,
            job_id,
            produced,
            Some("pw".to_owned()),
            ExportPackage::Zip,
            "z.zip",
        )
        .await
        .unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].filename, "crumb_export.zip");
        assert_eq!(out[0].download_name, "z.zip");
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }
}
