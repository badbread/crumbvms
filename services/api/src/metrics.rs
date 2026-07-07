// SPDX-License-Identifier: AGPL-3.0-or-later

//! Prometheus-style metrics endpoint (audit Risk #6).
//!
//! `GET /metrics` exposes operational gauges in the Prometheus text exposition
//! format — no external metrics crate, just a formatted string built on demand
//! from data the process already has: DB pool saturation, export-job counts by
//! status, recorder heartbeat age, build info, and API uptime. This is the
//! "operators are blind" fix: a scraper (or even `curl`) can now see pool
//! saturation and a dead recorder before they cause data loss.
//!
//! Unauthenticated by design (standard for Prometheus scrape targets); the body
//! contains no secrets, only counts/gauges. Keep it on the internal network /
//! behind the reverse proxy.

use std::fmt::Write as _;
use std::sync::OnceLock;
use std::time::Instant;

use axum::{extract::State, http::header, response::IntoResponse, routing::get, Router};

use crumb_common::db;

use crate::dto::ExportStatus;
use crate::state::AppState;

/// Process start instant, set once at startup by [`init_start`]; powers the
/// `crumb_api_uptime_seconds` gauge.
static START: OnceLock<Instant> = OnceLock::new();

/// Record the process start time. Call once from `main` before serving.
pub fn init_start() {
    let _ = START.set(Instant::now());
}

fn uptime_secs() -> u64 {
    START.get().map_or(0, |s| s.elapsed().as_secs())
}

/// Mount the `/metrics` route.
pub fn routes() -> Router<AppState> {
    Router::new().route("/metrics", get(metrics))
}

#[allow(clippy::cast_possible_wrap)]
async fn metrics(State(state): State<AppState>) -> impl IntoResponse {
    let mut out = String::with_capacity(1536);

    // ── build info ─────────────────────────────────────────────────────────
    let _ = writeln!(out, "# HELP crumb_build_info Build metadata (always 1).");
    let _ = writeln!(out, "# TYPE crumb_build_info gauge");
    let _ = writeln!(
        out,
        "crumb_build_info{{version=\"{}\",git_sha=\"{}\"}} 1",
        crate::VERSION.trim(),
        crate::GIT_SHA.unwrap_or("unknown"),
    );

    // ── uptime ─────────────────────────────────────────────────────────────
    let _ = writeln!(out, "# HELP crumb_api_uptime_seconds API process uptime.");
    let _ = writeln!(out, "# TYPE crumb_api_uptime_seconds gauge");
    let _ = writeln!(out, "crumb_api_uptime_seconds {}", uptime_secs());

    // ── DB pool ────────────────────────────────────────────────────────────
    let st = state.pool().status();
    let _ = writeln!(out, "# HELP crumb_db_pool_max Configured max pool size.");
    let _ = writeln!(out, "# TYPE crumb_db_pool_max gauge");
    let _ = writeln!(out, "crumb_db_pool_max {}", st.max_size as i64);
    let _ = writeln!(
        out,
        "# HELP crumb_db_pool_size Current pool size (open connections)."
    );
    let _ = writeln!(out, "# TYPE crumb_db_pool_size gauge");
    let _ = writeln!(out, "crumb_db_pool_size {}", st.size as i64);
    let _ = writeln!(
        out,
        "# HELP crumb_db_pool_available Idle connections available now."
    );
    let _ = writeln!(out, "# TYPE crumb_db_pool_available gauge");
    let _ = writeln!(out, "crumb_db_pool_available {}", st.available as i64);
    let _ = writeln!(
        out,
        "# HELP crumb_db_pool_waiting Tasks waiting for a connection."
    );
    let _ = writeln!(out, "# TYPE crumb_db_pool_waiting gauge");
    let _ = writeln!(out, "crumb_db_pool_waiting {}", st.waiting as i64);

    // ── export jobs by status ────────────────────────────────────────────────
    let (mut queued, mut running, mut done, mut failed, mut cancelled) =
        (0i64, 0i64, 0i64, 0i64, 0i64);
    for entry in state.export_jobs() {
        match entry.value().status {
            ExportStatus::Queued => queued += 1,
            ExportStatus::Running => running += 1,
            ExportStatus::Done => done += 1,
            ExportStatus::Failed => failed += 1,
            ExportStatus::Cancelled => cancelled += 1,
        }
    }
    let _ = writeln!(
        out,
        "# HELP crumb_export_jobs Export jobs currently tracked, by status."
    );
    let _ = writeln!(out, "# TYPE crumb_export_jobs gauge");
    let _ = writeln!(out, "crumb_export_jobs{{status=\"queued\"}} {queued}");
    let _ = writeln!(out, "crumb_export_jobs{{status=\"running\"}} {running}");
    let _ = writeln!(out, "crumb_export_jobs{{status=\"done\"}} {done}");
    let _ = writeln!(out, "crumb_export_jobs{{status=\"failed\"}} {failed}");
    let _ = writeln!(out, "crumb_export_jobs{{status=\"cancelled\"}} {cancelled}");

    // ── recorder heartbeat ───────────────────────────────────────────────────
    // Age in seconds since the last recorder heartbeat (-1 = never seen). A high
    // value means the recorder is down even though the API is up.
    let (age, active) = match db::read_recorder_heartbeat(state.pool()).await {
        Ok(Some(hb)) => (
            (chrono::Utc::now() - hb.updated_at).num_seconds(),
            i64::from(hb.active_cameras),
        ),
        Ok(None) => (-1, 0),
        Err(_) => (-1, 0),
    };
    let _ = writeln!(out, "# HELP crumb_recorder_heartbeat_age_seconds Seconds since last recorder heartbeat (-1 if never).");
    let _ = writeln!(out, "# TYPE crumb_recorder_heartbeat_age_seconds gauge");
    let _ = writeln!(out, "crumb_recorder_heartbeat_age_seconds {age}");
    let _ = writeln!(
        out,
        "# HELP crumb_recorder_active_cameras Camera workers reported at last heartbeat."
    );
    let _ = writeln!(out, "# TYPE crumb_recorder_active_cameras gauge");
    let _ = writeln!(out, "crumb_recorder_active_cameras {active}");

    ([(header::CONTENT_TYPE, "text/plain; version=0.0.4")], out)
}
