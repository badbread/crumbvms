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
    auth_mw::{AuthUser, LegacyQueryTokenUser},
    dto::{
        CreateBatchExportRequest, CreateExportRequest, CreateExportResponse, ExportJob,
        ExportOutputFile, ExportStatus,
    },
    error::ApiError,
    state::AppState,
};

// ─── ffmpeg binary path ───────────────────────────────────────────────────────

/// Absolute path to the ffmpeg binary inside the container runtime image.
/// The Dockerfile symlinks `/usr/lib/jellyfin-ffmpeg/ffmpeg` to this path.
const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";

/// Upper bound on clips in a single batch export job (guards ffmpeg fan-out).
const MAX_BATCH_ITEMS: usize = 50;

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
        .route(
            "/export/:job_id",
            get(get_export_status).delete(cancel_export),
        )
        .route(
            "/export/:job_id/files/:camera_id",
            get(download_export_file),
        )
        .route("/export/:job_id/archive", get(download_archive))
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
    if body.camera_ids.is_empty() {
        return Err(ApiError::BadRequest(
            "camera_ids must contain at least one camera".to_owned(),
        ));
    }
    if body.start >= body.end {
        return Err(ApiError::BadRequest(
            "start must be strictly before end".to_owned(),
        ));
    }

    // Scope: ALL-OR-NOTHING. Reject if ANY requested camera is outside the
    // caller's assigned list, matching /export/batch (create_batch_export) and
    // the archive download — a caller never gets a silently-narrowed partial
    // export they didn't ask for.
    if let Some(denied) = body
        .camera_ids
        .iter()
        .find(|c| !user.can_access_camera(**c))
    {
        return Err(ApiError::Forbidden(format!(
            "camera {denied} is not in your assigned camera list"
        )));
    }
    // All accessible now; filter still runs to dedup.
    let effective_ids = user.filter_camera_ids(&body.camera_ids);

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
    // Same gate as get_export_status: export capability + access to ≥1 job camera.
    user.require_export()?;
    let job = state
        .export_jobs()
        .get(&job_id)
        .map(|r| r.clone())
        .ok_or_else(|| ApiError::NotFound(format!("export job {job_id} not found")))?;
    if user.filter_camera_ids(&job.camera_ids).is_empty() {
        return Err(ApiError::Forbidden(
            "you do not have access to this export job".to_owned(),
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
    // Export downloads keep the legacy full-JWT-via-?token= path (audit
    // 2026-07-05 #2); every other media route is fail-closed. See
    // `LegacyQueryTokenUser`.
    LegacyQueryTokenUser(user): LegacyQueryTokenUser,
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
    let dl_name = output_entry.filename.clone();

    let response = axum::response::Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CONTENT_LENGTH, output_entry.size_bytes.to_string())
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{dl_name}\""),
        )
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
    // Multi-camera archive: keeps the legacy full-JWT-via-?token= path (audit
    // 2026-07-05 #2) since there's no single-camera scoped token for it yet.
    LegacyQueryTokenUser(user): LegacyQueryTokenUser,
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
            "attachment; filename=\"crumb_export.zip\"",
        )
        .body(body)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("build archive response: {e}")))?;

    Ok(response)
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
        args.extend(["-c:a".to_owned(), "copy".to_owned()]);
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
}

/// Await an ffmpeg `child` while watching `token`. On cancel, SIGKILL + reap the
/// child (so no zombie) and return [`WaitOutcome::Cancelled`]. This interrupts a
/// long single-camera encode promptly, not just between cameras.
async fn wait_or_cancel(
    child: &mut tokio::process::Child,
    token: &CancellationToken,
) -> WaitOutcome {
    tokio::select! {
        res = child.wait() => WaitOutcome::Finished(res),
        () = token.cancelled() => {
            // `kill()` sends SIGKILL AND reaps the child (awaits its exit).
            let _ = child.kill().await;
            WaitOutcome::Cancelled
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
        let mut child = match Command::new(FFMPEG_BIN)
            .args(&args)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
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
        let cam_range_pct = (100 / n_cameras).max(1).min(100) as u8;

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

        let exit_status = match wait_or_cancel(&mut child, &cancel).await {
            WaitOutcome::Cancelled => {
                cancel_job(&state, job_id, &export_dir).await;
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

    if body.items.is_empty() {
        return Err(ApiError::BadRequest(
            "items must contain at least one clip".to_owned(),
        ));
    }
    if body.items.len() > MAX_BATCH_ITEMS {
        return Err(ApiError::BadRequest(format!(
            "too many clips in one batch (max {MAX_BATCH_ITEMS})"
        )));
    }

    // Validate + scope every item up front (fail the whole request on a bad one).
    let mut items: Vec<(Uuid, chrono::DateTime<Utc>, chrono::DateTime<Utc>)> =
        Vec::with_capacity(body.items.len());
    for it in &body.items {
        if it.start >= it.end {
            return Err(ApiError::BadRequest(
                "each clip's start must be strictly before its end".to_owned(),
            ));
        }
        user.assert_camera_access(it.camera_id)?;
        items.push((it.camera_id, it.start, it.end));
    }

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
    let password = body.password.filter(|p| !p.is_empty());
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

    let mut child = Command::new(FFMPEG_BIN)
        .args(&args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
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

    let exit_status = match wait_or_cancel(&mut child, token).await {
        WaitOutcome::Cancelled => return Ok(ClipStep::Cancelled),
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
    // (camera id, on-disk filename, zip entry name) for each clip that produced
    // output. The camera id is kept so a single plain file can be served via the
    // per-camera download endpoint when we skip zipping.
    let mut produced: Vec<(Uuid, String, String)> = Vec::with_capacity(n);

    for (idx, (camera_id, start, end)) in items.iter().enumerate() {
        #[allow(clippy::cast_possible_truncation)]
        let cam_base_pct = (idx * 100 / n).min(99) as u8;
        #[allow(clippy::cast_possible_truncation)]
        let cam_range_pct = (100 / n).max(1).min(100) as u8;
        let seq = idx + 1;
        let cam_short: String = camera_id
            .to_string()
            .replace('-', "")
            .chars()
            .take(8)
            .collect();
        let filename = format!("clip{seq:02}_{cam_short}.{ext}");
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
                let entry = format!(
                    "clip{seq:02}_{cam_short}_{}.{ext}",
                    start.format("%Y%m%d-%H%M%S")
                );
                produced.push((*camera_id, filename, entry));
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

    // Packaging rule: produce ONE zip iff a password is set OR there is more than
    // one output file. A single plain file (no password) is served as-is via the
    // per-camera endpoint. The zip is AES-256 encrypted when a password is given,
    // otherwise Stored (unencrypted).
    let output_files: Vec<ExportOutputFile> = if password.is_some() || produced.len() > 1 {
        // Disk filenames to clean up after zipping (captured before `produced`
        // moves into the blocking closure).
        let cleanup: Vec<String> = produced.iter().map(|(_, disk, _)| disk.clone()).collect();

        // Bundle every clip into ONE archive on a blocking thread (zip is sync I/O).
        let zip_path = export_dir.join("crumb_export.zip");
        let zip_path_clone = zip_path.clone();
        let export_dir_clone = export_dir.clone();
        let pw = password.clone();
        let result = tokio::task::spawn_blocking(move || -> std::io::Result<()> {
            use zip::write::FileOptions;
            use zip::AesMode;
            use zip::CompressionMethod;

            let out_file = std::fs::File::create(&zip_path_clone)?;
            let mut zw = zip::write::ZipWriter::new(out_file);
            for (_camera_id, disk_name, entry_name) in &produced {
                // Separate scopes per branch so the differently-typed FileOptions
                // (AES carries the password lifetime) never need to unify.
                if let Some(p) = &pw {
                    let opts = FileOptions::<()>::default()
                        .compression_method(CompressionMethod::Stored)
                        .with_aes_encryption(AesMode::Aes256, p.as_str());
                    zw.start_file(entry_name.as_str(), opts)?;
                } else {
                    // Stored (no compression) — video is already compressed, and the
                    // zip crate build here doesn't enable the deflate feature.
                    let opts =
                        FileOptions::<()>::default().compression_method(CompressionMethod::Stored);
                    zw.start_file(entry_name.as_str(), opts)?;
                }
                let mut src = std::fs::File::open(export_dir_clone.join(disk_name))?;
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

        // Only the archive remains downloadable.
        for disk_name in &cleanup {
            let _ = tokio::fs::remove_file(export_dir.join(disk_name)).await;
        }
        let zip_size = tokio::fs::metadata(&zip_path).await.map_or(0, |m| m.len());

        vec![ExportOutputFile {
            camera_id: Uuid::nil(),
            download_url: format!("/export/{job_id}/archive"),
            size_bytes: zip_size,
            filename: "crumb_export.zip".to_owned(),
        }]
    } else {
        // Exactly one file, no password → leave it as a plain video download
        // served via the per-camera endpoint.
        let (camera_id, disk_name, _entry) = &produced[0];
        let size_bytes = tokio::fs::metadata(export_dir.join(disk_name))
            .await
            .map_or(0, |m| m.len());
        vec![ExportOutputFile {
            camera_id: *camera_id,
            download_url: format!("/export/{job_id}/files/{camera_id}"),
            size_bytes,
            filename: disk_name.clone(),
        }]
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

        let outcome = wait_or_cancel(&mut child, &token).await;
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
        let outcome = wait_or_cancel(&mut child, &token).await;
        assert!(matches!(outcome, WaitOutcome::Finished(Ok(s)) if s.success()));
    }
}
