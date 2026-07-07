// SPDX-License-Identifier: AGPL-3.0-or-later

//! Postgres persistence for export jobs.
//!
//! Export jobs used to live only in `AppState::export_jobs` (a `DashMap`), so an
//! API restart silently lost every in-flight and completed job (audit Risk #5/#8:
//! "Export jobs lost on restart (in-memory only)"). This module mirrors the job
//! map into an `export_jobs` table so jobs survive restarts.
//!
//! ## Persistence policy
//!
//! We persist on **status transitions** (Queued → Running → Done/Failed), not on
//! every `progress_pct` tick — progress is high-frequency and ephemeral, and a
//! job that was mid-run when the process died is unrecoverable anyway (the ffmpeg
//! child is gone). On startup, `main.rs` rehydrates the table and marks any job
//! still `Queued`/`Running` as `Failed("interrupted by API restart")` so clients
//! see a terminal state instead of a job that will never progress.
//!
//! All writes are best-effort: a failed persist logs a WARN but never fails the
//! request — the in-memory map remains the live source of truth within a run.

use anyhow::{Context, Result};
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db::get_conn;

use crate::dto::{ExportJob, ExportOutputFile, ExportStatus};

/// Create the `export_jobs` table if it does not exist (idempotent; runs at API
/// startup, mirroring how the recorder ensures its own tables).
pub async fn ensure_export_jobs_table(pool: &Pool) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .batch_execute(
            r"
            CREATE TABLE IF NOT EXISTS export_jobs (
                id             uuid PRIMARY KEY,
                status         text NOT NULL,
                camera_ids     uuid[] NOT NULL,
                start_ts       timestamptz NOT NULL,
                end_ts         timestamptz NOT NULL,
                burn_timestamp boolean NOT NULL,
                created_at     timestamptz NOT NULL,
                output_files   jsonb NOT NULL DEFAULT '[]'::jsonb,
                error          text,
                progress_pct   int NOT NULL DEFAULT 0
            );
            ",
        )
        .await
        .context("ensure_export_jobs_table")?;
    Ok(())
}

/// Wire string for an [`ExportStatus`] (matches the lowercase serde rename).
fn status_str(s: &ExportStatus) -> &'static str {
    match s {
        ExportStatus::Queued => "queued",
        ExportStatus::Running => "running",
        ExportStatus::Done => "done",
        ExportStatus::Failed => "failed",
        ExportStatus::Cancelled => "cancelled",
    }
}

/// Parse a persisted status string back into [`ExportStatus`] (unknown → Queued).
fn status_from(s: &str) -> ExportStatus {
    match s {
        "running" => ExportStatus::Running,
        "done" => ExportStatus::Done,
        "failed" => ExportStatus::Failed,
        "cancelled" => ExportStatus::Cancelled,
        _ => ExportStatus::Queued,
    }
}

/// Insert or update a job by id. Only the mutable fields (status, `output_files`,
/// error, `progress_pct`) are updated on conflict — the immutable request fields
/// are written once at insert.
pub async fn upsert_export_job(pool: &Pool, job: &ExportJob) -> Result<()> {
    let client = get_conn(pool).await?;
    let output_files =
        serde_json::to_value(&job.output_files).context("serialize export output_files")?;
    let progress = i32::from(job.progress_pct);
    let status = status_str(&job.status);
    client
        .execute(
            r"
            INSERT INTO export_jobs
                (id, status, camera_ids, start_ts, end_ts, burn_timestamp,
                 created_at, output_files, error, progress_pct)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            ON CONFLICT (id) DO UPDATE SET
                status       = EXCLUDED.status,
                output_files = EXCLUDED.output_files,
                error        = EXCLUDED.error,
                progress_pct = EXCLUDED.progress_pct
            ",
            &[
                &job.id,
                &status,
                &job.camera_ids,
                &job.start,
                &job.end,
                &job.burn_timestamp,
                &job.created_at,
                &output_files,
                &job.error,
                &progress,
            ],
        )
        .await
        .context("upsert_export_job")?;
    Ok(())
}

/// Load every persisted export job (used once at startup for rehydration).
pub async fn load_all_export_jobs(pool: &Pool) -> Result<Vec<ExportJob>> {
    let client = get_conn(pool).await?;
    let rows = client
        .query(
            r"
            SELECT id, status, camera_ids, start_ts, end_ts, burn_timestamp,
                   created_at, output_files, error, progress_pct
            FROM export_jobs
            ",
            &[],
        )
        .await
        .context("load_all_export_jobs")?;

    let mut jobs = Vec::with_capacity(rows.len());
    for row in rows {
        let output_json: serde_json::Value = row.get("output_files");
        let output_files: Vec<ExportOutputFile> =
            serde_json::from_value(output_json).unwrap_or_default();
        let progress: i32 = row.get("progress_pct");
        let status: String = row.get("status");
        jobs.push(ExportJob {
            id: row.get("id"),
            status: status_from(&status),
            camera_ids: row.get("camera_ids"),
            start: row.get("start_ts"),
            end: row.get("end_ts"),
            burn_timestamp: row.get("burn_timestamp"),
            created_at: row.get("created_at"),
            output_files,
            error: row.get("error"),
            progress_pct: u8::try_from(progress.clamp(0, 100)).unwrap_or(0),
        });
    }
    Ok(jobs)
}

/// Delete a persisted job (called by the TTL sweeper when it evicts the job).
pub async fn delete_export_job(pool: &Pool, id: Uuid) -> Result<()> {
    let client = get_conn(pool).await?;
    client
        .execute("DELETE FROM export_jobs WHERE id = $1", &[&id])
        .await
        .context("delete_export_job")?;
    Ok(())
}
