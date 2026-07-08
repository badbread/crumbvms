// SPDX-License-Identifier: AGPL-3.0-or-later

//! `crumb-api` — HTTP API for the Crumb NVR system.
//!
//! ## Startup sequence
//!
//! 1. Read [`config::ApiConfig`] from environment.
//! 2. Build a `deadpool-postgres` pool via `crumb_common::db::build_pool`.
//! 3. Run `crumb_common::db::run_migrations` (all embedded SQL, idempotent).
//! 4. Call `ensure_segments_indexes` + `ensure_server_settings_table` + all
//!    existing `ensure_*` backstops.
//! 5. Seed the bootstrap admin (headless env-var path).
//! 6. Construct [`state::AppState`] (pool + config + JWT keys + export job map).
//! 7. Build the [`axum::Router`] with all route groups and tower-http layers.
//! 8. Bind to `config.bind_addr` and serve.
//! 9. Spawn background tasks: go2rtc reconcile loop, export TTL sweeper,
//!    heartbeat alerter (opt-in), detection provider (feature-gated).
//!
//! ## Route layout
//!
//! ```text
//! /auth/needs-bootstrap     → auth.rs (no auth — first-run bootstrap probe)
//! /auth/bootstrap           → auth.rs (no auth — first-run admin creation)
//! /auth/login               → auth.rs (no auth — credential verification)
//! /auth/refresh             → auth.rs (Bearer — re-issue token)
//! /auth/me                  → auth.rs (Bearer — caller profile)
//! /config/*                 → config_routes.rs  (admin only)
//! /config/users             → config_routes.rs  (admin — CRUD with last-admin guard)
//! /config/server            → config_routes.rs  (admin — server/streaming settings)
//! /config/cameras/:id/redetect → config_routes.rs (admin — ONVIF re-detect)
//! /config/migrations/:id/retry|cancel → config_routes.rs (admin)
//! /cameras                  → cameras.rs (viewer-safe list, RBAC-scoped)
//! /views                    → views.rs
//! /views/:id                → views.rs
//! /timeline                 → timeline.rs
//! /play/*                   → playback.rs
//! /segments/*               → playback.rs
//! /export/*                 → export.rs
//! /filmstrip/*              → filmstrip.rs
//! /status                   → status.rs
//! /stats/*                  → stats.rs           (admin only)
//! /cameras/:id/ptz          → ptz.rs
//! /cameras/:id/frame.jpg    → cameras.rs
//! /health                   → inline (no auth — DB+heartbeat probe, 503 if degraded)
//! ```

#![warn(clippy::pedantic)]
// Keep pedantic ON, but curate the lints this service intentionally doesn't
// follow (the standard way to use the pedantic group):
#![allow(clippy::module_name_repetitions)]
// `Option<Option<T>>` is the deliberate PATCH/partial-update encoding in the DTOs
// (outer = field present?, inner = value, incl. explicit null) — see config_routes.
#![allow(clippy::option_option)]
// Axum handlers are necessarily long and read top-to-bottom; splitting them for
// a line count hurts readability more than it helps.
#![allow(clippy::too_many_lines)]
#![allow(clippy::items_after_statements)]
// Numeric casts between timestamp/size/index types are intentional and bounded.
#![allow(clippy::cast_possible_truncation)]
#![allow(clippy::cast_sign_loss)]
#![allow(clippy::cast_possible_wrap)]
// Remaining style preferences that don't earn churn in a deployed service.
#![allow(clippy::manual_let_else)]
#![allow(clippy::default_trait_access)]
#![allow(clippy::struct_excessive_bools)]
#![allow(clippy::match_same_arms)]
#![allow(clippy::manual_clamp)]
#![allow(clippy::format_push_string)]

mod alerts;
mod auth;
mod auth_mw;
mod bookmarks;
mod cameras;
mod channel_notify;
mod clips;
mod config;
mod config_routes;
mod db_backup;
#[cfg(feature = "detection")]
mod detection;
#[cfg(feature = "detection")]
mod detection_ingester;
mod discover;
mod dto;
mod error;
mod events;
mod export;
mod export_store;
mod ffprobe;
mod filmstrip;
mod go2rtc;
mod metrics;
mod notifications;
mod playback;
mod ptz;
mod rate_limit;
mod roles;
mod state;
mod stats;
mod status;
mod stream_test;
mod thumb_pregen;
mod timeline;
mod views;

use std::time::Duration;

use axum::{extract::State, http::StatusCode, routing::get, Json, Router};
use serde_json::json;
use tower_http::{
    compression::CompressionLayer,
    cors::{Any, CorsLayer},
    timeout::TimeoutLayer,
    trace::TraceLayer,
};
use tracing::info;

use crumb_common::db::build_pool;
use crumb_common::logging;

use config::ApiConfig;
use state::AppState;

/// Product version, read from the repo-root `VERSION` file at compile time.
/// Single source of truth shared with the Docker image tag (`CRUMB_VERSION`).
const VERSION: &str = include_str!("../../../VERSION");

/// Git commit the binary was built from. Injected by CI / the Dockerfile via the
/// `CRUMB_GIT_SHA` build arg → env var; falls back to `"unknown"` for plain
/// local `cargo build`.
const GIT_SHA: Option<&str> = option_env!("CRUMB_GIT_SHA");

/// Build timestamp (RFC3339), injected the same way as `GIT_SHA`.
const BUILD_TIME: Option<&str> = option_env!("CRUMB_BUILD_TIME");

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // ── 1. logging ────────────────────────────────────────────────────────────
    logging::init();
    metrics::init_start();
    info!("Crumb API starting");

    // ── 2. config ─────────────────────────────────────────────────────────────
    let cfg = ApiConfig::from_env()?;
    let bind_addr = cfg.bind_addr;
    info!(bind_addr = %bind_addr, "configuration loaded");

    // ── 3. database pool ──────────────────────────────────────────────────────
    let pool = build_pool(&cfg.database_url, cfg.db_pool_size)?;
    // Eagerly verify connectivity so we fail fast at startup.
    {
        let client = pool.get().await?;
        client
            .execute("SELECT 1", &[])
            .await
            .map_err(|e| anyhow::anyhow!("database connectivity check failed: {e}"))?;
    }
    info!("database pool ready");

    // ── migration runner ──────────────────────────────────────────────────────
    // Run all embedded migrations (0001–0013) in order, tracking applied files
    // in `schema_migrations`.  On an existing DB the 0001–0011 baseline is
    // marked applied without re-executing, so only 0012/0013 (and any future
    // files) actually run SQL.  Non-fatal for the API (so a read-only API can
    // still surface a clear error); the recorder treats this as fatal (it is the
    // schema owner — see recorder/src/main.rs).
    if let Err(e) = crumb_common::db::run_migrations(&pool).await {
        tracing::warn!(
            error = %e,
            "run_migrations failed (some schema features may be unavailable until fixed)"
        );
    }

    // ── composite segment indexes (self-heal) ─────────────────────────────────
    // Creates the three canonical indexes if they don't exist yet.  Idempotent
    // (IF NOT EXISTS, non-CONCURRENT).  Also called by the recorder; whichever
    // starts first builds them.
    if let Err(e) = crumb_common::db::ensure_segments_indexes(&pool).await {
        tracing::warn!(
            error = %e,
            "ensure_segments_indexes failed (segment queries may full-scan until fixed)"
        );
    }

    // ── server/streaming settings singleton ───────────────────────────────────
    // Ensures the `server_settings` row (id=1) exists, seeded from env vars on
    // first creation.  After that the DB is authoritative.
    if let Err(e) = crumb_common::db::ensure_server_settings_table(&pool).await {
        tracing::warn!(
            error = %e,
            "ensure_server_settings_table failed (Server & streaming settings may be unavailable)"
        );
    }

    // Ensure the motion_grid table exists (the recorder also does this; doing it
    // here means GET /cameras/:id/motion-grid degrades to null instead of 500 if
    // the API ever starts against a DB the recorder hasn't touched).
    if let Err(e) = crumb_common::db::ensure_motion_grid_table(&pool).await {
        tracing::warn!(error = %e, "ensure_motion_grid_table failed (motion tuner may 500 until recorder runs)");
    }
    if let Err(e) = crumb_common::db::ensure_segments_motion_score_column(&pool).await {
        tracing::warn!(error = %e, "ensure_segments_motion_score_column failed (timeline intensity may 500 until recorder runs)");
    }
    // Ensure motion_threshold is a fraction (0..1), not legacy basis points — one
    // unit shared with motion_score. Idempotent + self-guarding (see db.rs).
    if let Err(e) = crumb_common::db::ensure_motion_threshold_fraction(&pool).await {
        tracing::warn!(error = %e, "ensure_motion_threshold_fraction failed (manual thresholds may be mis-scaled)");
    }
    // Ensure detection-event schema columns exist (idempotent; mirrors
    // db/migrations/0007_detection_events.sql). Non-fatal: API starts normally
    // even if this fails (e.g. old schema without events table).
    if let Err(e) = crumb_common::db::ensure_camera_source_columns(&pool).await {
        tracing::warn!(error = %e, "ensure_camera_source_columns failed (self-service camera add may be unavailable)");
    }
    // Per-camera ownership + ONVIF columns (migration 0012 backstop). CAMERA_SELECT_SQL
    // now reads served_by/source_camera_name/onvif_* so they MUST exist before any
    // camera query — without this, the API (whose run_migrations is non-fatal) could
    // boot ahead of the recorder and 500 every camera read until 0012 lands.
    if let Err(e) = crumb_common::db::ensure_camera_ownership_columns(&pool).await {
        tracing::warn!(error = %e, "ensure_camera_ownership_columns failed (camera reads may 500 until migration 0012 is applied)");
    }
    if let Err(e) = crumb_common::db::ensure_detection_columns(&pool).await {
        tracing::warn!(error = %e, "ensure_detection_columns failed (detection events may be unavailable until migration 0007 is applied)");
    }
    // Ensure the per-camera resource-stats table exists so GET /stats/cameras
    // degrades to zeros instead of 500 if the API starts against a DB the recorder
    // hasn't touched yet (the recorder also creates it). Idempotent.
    if let Err(e) = crumb_common::db::ensure_camera_resource_stats(&pool).await {
        tracing::warn!(error = %e, "ensure_camera_resource_stats failed (per-camera CPU/mem/GPU stats may 500 until recorder runs)");
    }
    // Ensure the per-camera size-cap columns exist (live_max_bytes /
    // archive_max_bytes) so policy reads/writes don't 500 if the API starts
    // against a DB the recorder hasn't touched yet (the recorder also adds them).
    if let Err(e) = crumb_common::db::ensure_policy_size_cap_columns(&pool).await {
        tracing::warn!(error = %e, "ensure_policy_size_cap_columns failed (size-cap policy fields may be unavailable until recorder runs)");
    }
    // Per-policy advanced storage columns (free-space headroom + spill buffer). Run
    // here too so policy reads/writes don't 500 against a DB the recorder hasn't
    // touched yet; NULL defaults preserve current eviction behaviour.
    if let Err(e) = crumb_common::db::ensure_policy_advanced_storage_columns(&pool).await {
        tracing::warn!(error = %e, "ensure_policy_advanced_storage_columns failed (advanced storage policy fields may be unavailable until recorder runs)");
    }
    // Per-camera motion source/algorithm columns (pluggable-motion Stage 4). Run
    // here too so camera reads/writes don't 500 against a DB the recorder hasn't
    // touched yet; defaults ('pixel'/'census') preserve current behaviour.
    if let Err(e) = crumb_common::db::ensure_motion_source_columns(&pool).await {
        tracing::warn!(error = %e, "ensure_motion_source_columns failed (per-camera motion source/algorithm unavailable until recorder runs)");
    }
    // Per-camera camera_type column (admin-console glyph only; nullable, NULL ⇒
    // 'other'). Run here too so camera reads/writes don't 500 against a DB the
    // recorder hasn't touched yet.
    if let Err(e) = crumb_common::db::ensure_camera_type_column(&pool).await {
        tracing::warn!(error = %e, "ensure_camera_type_column failed (per-camera type icon unavailable until recorder runs)");
    }
    // Per-camera + per-storage icon OVERRIDE columns (admin-console glyph only;
    // nullable, NULL ⇒ derive from camera_type / infer from name). Every camera +
    // storage SELECT now reads these, so they MUST exist before any such query.
    if let Err(e) = crumb_common::db::ensure_cameras_icon_column(&pool).await {
        tracing::warn!(error = %e, "ensure_cameras_icon_column failed (per-camera icon override unavailable until recorder runs)");
    }
    if let Err(e) = crumb_common::db::ensure_storages_icon_column(&pool).await {
        tracing::warn!(error = %e, "ensure_storages_icon_column failed (per-storage icon override unavailable until recorder runs)");
    }
    // Per-camera motion-tuner grid-size columns (UI preference only; nullable,
    // NULL ⇒ client default 16×9). Both camera SELECTs read them.
    if let Err(e) = crumb_common::db::ensure_cameras_motion_grid_columns(&pool).await {
        tracing::warn!(error = %e, "ensure_cameras_motion_grid_columns failed (per-camera tuner grid-size unavailable until recorder runs)");
    }
    // "Change storage" drain job table — the API enqueues, the recorder drains.
    if let Err(e) = crumb_common::db::ensure_storage_migrations_table(&pool).await {
        tracing::warn!(error = %e, "ensure_storage_migrations_table failed (Change-storage workflow unavailable until recorder runs)");
    }
    // Composite index backing the drain's per-batch SELECT (storage_id, start_ts).
    if let Err(e) = crumb_common::db::ensure_segments_storage_index(&pool).await {
        tracing::warn!(error = %e, "ensure_segments_storage_index failed (Change-storage drain SELECT may full-scan until recorder runs)");
    }
    // Frigate/MQTT settings singleton (seeded from env on first create) — backs
    // the admin Integrations page + the hot-reloadable detection provider.
    if let Err(e) = crumb_common::db::ensure_frigate_config_table(&pool).await {
        tracing::warn!(error = %e, "ensure_frigate_config_table failed (Frigate config page unavailable until recorder runs)");
    }
    if let Err(e) = crumb_common::db::ensure_bookmarks_table(&pool).await {
        tracing::warn!(error = %e, "ensure_bookmarks_table failed (bookmarks unavailable until migration 0010 is applied)");
    }
    // DB-level storage invariant: segments.storage_id must be ON DELETE RESTRICT so
    // a referenced storage can't be deleted out from under footage (A2). Run here
    // too so whichever process boots first applies it; idempotent (swaps the FK
    // only if not already RESTRICT). Non-fatal — the admin delete_storage guard
    // still protects in the meantime.
    if let Err(e) = crumb_common::db::ensure_segments_storage_fk_restrict(&pool).await {
        tracing::warn!(error = %e, "ensure_segments_storage_fk_restrict failed (segments.storage_id FK backstop not enforced this run)");
    }
    // Named, reusable policies + camera groups (with inheritance). Run here too so
    // the API tolerates a fresh DB the recorder hasn't bootstrapped yet; the
    // /config/policies + /config/groups routes 500 until this succeeds. Idempotent.
    if let Err(e) = crumb_common::db::ensure_named_policies_and_groups(&pool).await {
        tracing::warn!(error = %e, "ensure_named_policies_and_groups failed (named policies + camera groups may be unavailable until recorder runs)");
    }

    // ── 3b. bootstrap admin (idempotent; no-op if any admin already exists) ────
    if let Err(e) =
        auth::seed_admin_if_absent(&pool, &cfg.seed_admin_username, &cfg.seed_admin_password).await
    {
        tracing::warn!(error = %e, "admin seed failed (continuing without bootstrap admin)");
    }

    // ── 4. app state ──────────────────────────────────────────────────────────
    let state = AppState::new(pool, cfg.clone());

    // Own Crumb's go2rtc: re-apply all Crumb-managed camera streams now + every
    // 60 s (so a go2rtc restart self-heals). Camera add/update/delete also apply
    // changes immediately; this loop is the safety net.
    go2rtc::spawn_reconcile_loop(state.clone());

    // ── 4b. export-job persistence: ensure table + rehydrate ───────────────────
    // Export jobs are mirrored to Postgres so a restart doesn't lose them. Any
    // job still Queued/Running when we died can't resume (its ffmpeg is gone), so
    // mark it Failed — clients see a terminal state instead of a stuck job.
    if let Err(e) = export_store::ensure_export_jobs_table(state.pool()).await {
        tracing::warn!(error = %e, "ensure_export_jobs_table failed; export persistence disabled this run");
    } else {
        match export_store::load_all_export_jobs(state.pool()).await {
            Ok(jobs) => {
                let (mut rehydrated, mut interrupted) = (0u32, 0u32);
                for mut job in jobs {
                    if matches!(
                        job.status,
                        dto::ExportStatus::Queued | dto::ExportStatus::Running
                    ) {
                        job.status = dto::ExportStatus::Failed;
                        job.error = Some("interrupted by API restart".to_owned());
                        interrupted += 1;
                        if let Err(e) = export_store::upsert_export_job(state.pool(), &job).await {
                            tracing::warn!(error = %e, "failed to persist interrupted export job");
                        }
                    }
                    state.export_jobs().insert(job.id, job);
                    rehydrated += 1;
                }
                tracing::info!(rehydrated, interrupted, "export jobs rehydrated from DB");
            }
            Err(e) => tracing::warn!(error = %e, "load_all_export_jobs failed"),
        }
    }

    // ── 4c. detection provider (optional — runtime-gated on FRIGATE_MQTT_URL) ──
    // When FRIGATE_MQTT_URL is absent (the normal Crumb-standalone case) zero
    // providers are created, the channel is never opened, and no background task
    // runs.  The events table exists but stays empty; /events returns [].
    #[cfg(feature = "detection")]
    {
        use crumb_common::db::{
            frigate_config_version, get_frigate_settings, load_camera_name_map,
        };
        use crumb_common::detection::DetectionSource;
        use detection::frigate::{FrigateConfig, FrigateProvider};

        // One ingester + event channel for the whole process; the Frigate provider
        // is (re)spawned by a supervisor that HOT-RELOADS on a `frigate_config`
        // version bump — an admin edit reconnects MQTT with no API restart.
        let (event_tx, event_rx) = tokio::sync::mpsc::channel::<crumb_common::NormalizedEvent>(512);
        let ingester_pool = state.pool().clone();
        tokio::spawn(async move {
            detection_ingester::run(event_rx, ingester_pool).await;
        });

        let sup_pool = state.pool().clone();
        tokio::spawn(async move {
            let mut current: Option<std::sync::Arc<FrigateProvider>> = None;
            let mut current_version: i64 = -1;
            loop {
                let version = frigate_config_version(&sup_pool)
                    .await
                    .unwrap_or(current_version);
                if version != current_version {
                    // Stop the old provider (disconnects MQTT) before swapping.
                    if let Some(p) = current.take() {
                        let _ = p.stop().await;
                    }
                    current_version = version;
                    let cfg = get_frigate_settings(&sup_pool)
                        .await
                        .ok()
                        .flatten()
                        .as_ref()
                        .and_then(FrigateConfig::from_settings);
                    match cfg {
                        Some(cfg) => {
                            let camera_map =
                                load_camera_name_map(&sup_pool).await.unwrap_or_default();
                            let provider = std::sync::Arc::new(FrigateProvider::new(
                                cfg,
                                camera_map,
                                sup_pool.clone(),
                            ));
                            let p2 = std::sync::Arc::clone(&provider);
                            let tx = event_tx.clone();
                            tokio::spawn(async move {
                                if let Err(e) = p2.start(tx).await {
                                    tracing::error!(error = %e, "Frigate provider exited with error");
                                }
                            });
                            current = Some(provider);
                            info!(
                                version,
                                "detection: Frigate provider (re)started from DB settings"
                            );
                        }
                        None => {
                            info!("detection: Frigate disabled in settings — provider not running");
                        }
                    }
                }
                tokio::time::sleep(std::time::Duration::from_secs(15)).await;
            }
        });
    }

    // ── 5. router ─────────────────────────────────────────────────────────────
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // JSON/API routes get gzip + a 30s request timeout (bounds DB-heavy endpoints
    // like /timeline + fails slow clients fast). MEDIA routes (segment/video
    // serving, export file downloads, filmstrip JPEGs) are deliberately EXCLUDED:
    // gzip would break 206 range requests / waste CPU on already-compressed video,
    // and a 30s timeout would cut large/slow downloads.
    // Per-client rate limiter for the JSON routes (generous: burst 240, ~4/s
    // sustained). Protects auth/timeline/status/config from abuse without
    // touching high-frequency media serving.
    let rate_limiter = rate_limit::RateLimiter::new(240, 4.0);

    let json_routes = Router::new()
        .nest("/auth", auth::routes())
        // Scoped-media-token mint (P0-SESSIONS): GET /media-token?camera=… — an
        // authenticated JSON call, so it lives here (rate-limited + timed out),
        // not among the media routes it hands tokens out for.
        .merge(auth::media_token_routes())
        .nest("/config", config_routes::routes())
        .merge(cameras::json_routes())
        .merge(views::routes())
        .merge(bookmarks::routes())
        .merge(timeline::routes())
        .merge(status::routes())
        .merge(stats::routes())
        .merge(ptz::routes())
        // Detection events list (authenticated, subject to rate-limit + gzip).
        // Snapshot proxy is in media_routes below (authenticated via ?token=, no timeout).
        .merge(events::json_routes())
        // Clips feed (detections + derived motion), source-abstracted.
        .merge(clips::json_routes())
        // Notification devices, rules, snooze, presence, and log.
        .merge(notifications::routes())
        // Layers applied outermost-first: rate-limit (reject early) → timeout →
        // gzip (compress handler output, innermost).
        .layer(CompressionLayer::new())
        // TimeoutLayer::new's 408-on-timeout default is exactly what we want;
        // suppress the deprecation in favour of the (otherwise-identical here)
        // with_status_code form.
        .layer({
            #[allow(deprecated)]
            let timeout = TimeoutLayer::new(std::time::Duration::from_secs(30));
            timeout
        })
        .layer(axum::middleware::from_fn_with_state(
            rate_limiter.clone(),
            rate_limit::rate_limit_mw,
        ));

    let media_routes = Router::new()
        .merge(playback::routes())
        .merge(export::routes())
        .merge(filmstrip::routes())
        // On-demand DB-vs-disk size verification: a filesystem walk that can run
        // long on a large archive, so it lives here (no 30 s timeout) not in
        // json_routes. Admin-gated by its handler's AuthUser extractor.
        .merge(stats::heavy_routes())
        // Per-camera JPEG still proxy (authenticated, no gzip, no timeout).
        .merge(cameras::routes())
        // Detection snapshot proxy (authenticated via AuthUser — Bearer or a
        // scoped ?token=; no gzip, no timeout).
        .merge(events::media_routes())
        // Clip media: generated clip.mp4 + thumbnail.jpg (authenticated; ?token= ok).
        .merge(clips::media_routes());

    let app = Router::new()
        // Health check — no auth, no tracing noise.  Returns 200 OK when DB
        // responds and the recorder heartbeat is fresh; 503 otherwise so
        // Docker / load-balancers can detect degraded state automatically.
        .route("/health", get(health))
        // Build/version diagnostics — no auth (no secrets; aids support + rollback).
        .route("/version", get(version))
        // Server-served admin console (the page itself is public; it signs in to
        // the API via /auth and drives the admin-only /config endpoints).
        .route("/admin", get(serve_admin))
        // Prometheus metrics — no auth (no secrets), no rate limit (scraper).
        .merge(metrics::routes())
        .merge(json_routes)
        .merge(media_routes)
        // Layers applied outermost-first (LIFO evaluation order in tower).
        .layer(TraceLayer::new_for_http())
        .layer(cors)
        .with_state(state.clone());

    // ── 6. export TTL sweeper ─────────────────────────────────────────────────
    let sweeper_state = state.clone();
    let export_ttl = cfg.export_ttl_seconds;
    tokio::spawn(async move {
        export_ttl_sweeper(sweeper_state, export_ttl).await;
    });

    // ── 6a2. session prune sweeper (P0-SESSIONS) ──────────────────────────────
    // Delete `sessions` rows whose token has already expired so the table (which
    // gains a row per login, including 10-year "remember me" tokens) stays
    // bounded. Correctness never depends on this — an expired token is rejected
    // by the JWT `exp` check regardless — so it runs infrequently and best-effort.
    {
        let prune_pool = state.pool().clone();
        tokio::spawn(async move {
            let tick = Duration::from_hours(1);
            loop {
                tokio::time::sleep(tick).await;
                match crumb_common::db::prune_expired_sessions(&prune_pool).await {
                    Ok(n) if n > 0 => info!("pruned {n} expired session row(s)"),
                    Ok(_) => {}
                    Err(e) => tracing::warn!("session prune failed: {e}"),
                }
            }
        });
    }

    // ── 6b. heartbeat webhook alerter (opt-in via ALERT_WEBHOOK_URL) ───────────
    if let Some(url) = cfg.alert_webhook_url.clone() {
        let alert_pool = state.pool().clone();
        tokio::spawn(async move {
            alerts::run_heartbeat_watchdog(alert_pool, url).await;
        });
        info!("heartbeat webhook alerter enabled");
    } else {
        info!("ALERT_WEBHOOK_URL not set — heartbeat alerter disabled");
    }

    // ── 6c. notification engine ───────────────────────────────────────────────
    {
        let notif_pool = state.pool().clone();
        // P0-GO2RTC (lighter lockdown): the engine needs go2rtc's Basic-auth
        // credentials for its snapshot fetch; it owns only a Pool, not AppState.
        let go2rtc_user = cfg.go2rtc_user.clone();
        let go2rtc_pass = cfg.go2rtc_pass.clone();
        // Health-alert maintenance window (issue #46): shared handle so
        // `POST /config/maintenance` can suppress the engine's health-alert
        // dispatch for a planned-maintenance window.
        let maintenance_until = state.maintenance_handle();
        tokio::spawn(async move {
            notifications::run_notification_engine(
                notif_pool,
                go2rtc_user,
                go2rtc_pass,
                maintenance_until,
            )
            .await;
        });
        info!("notification engine started");
    }

    // ── 6d. system/health watchdogs (P0-HEALTH-NOTIFY) ────────────────────────
    //
    // Always on (no env var gate, unlike the legacy ALERT_WEBHOOK_URL path) —
    // feeds `system_events`, consumed by the notification engine above and
    // routed through the same 6 channels. Each individual check is gated by
    // its own `system_alert_rules.enabled` row, so an admin who wants none of
    // this can disable every row via the admin Notifications panel.
    {
        let health_pool = state.pool().clone();
        tokio::spawn(async move {
            alerts::run_system_health_watchdogs(health_pool).await;
        });
        info!("system-health watchdogs started");
    }

    // ── 6e. built-in nightly DB backup (replaces the db-backup sidecar) ───────
    //
    // Daily pg_dump (03:15 local by default) + tiered rotation into the
    // /backups mount, plus an on-boot catch-up dump when the newest backup is
    // missing/stale. Self-gating: DB_BACKUP_ENABLED=false, an unset BACKUP_DIR,
    // or an unwritable dir all disable backups WITHOUT affecting API health
    // (see db_backup.rs module docs).
    {
        let backup_pool = state.pool().clone();
        let backup_db_url = cfg.database_url.clone();
        tokio::spawn(async move {
            db_backup::run_db_backup_job(backup_pool, backup_db_url).await;
        });
    }

    // Phase 1 thumbnail pre-generation (opt-in via THUMB_PREGEN_ENABLED). The
    // worker logs + returns immediately when disabled, so spawning it here is
    // always safe.
    tokio::spawn(thumb_pregen::run(state.clone()));

    // ── 7. bind and serve ─────────────────────────────────────────────────────
    // `into_make_service_with_connect_info` exposes the peer SocketAddr to the
    // rate-limit middleware (ConnectInfo extractor).
    info!(%bind_addr, "listening");
    let listener = tokio::net::TcpListener::bind(bind_addr).await?;
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await?;

    Ok(())
}

// ─── health check ─────────────────────────────────────────────────────────────

/// `GET /health` — liveness/readiness probe used by Docker, load-balancers,
/// and the `/status` Recorder-health panel.
///
/// Checks two things:
///
/// 1. **DB connectivity** — a `SELECT 1` against the pool.  Fails the probe if
///    the pool is exhausted or Postgres is unreachable.
/// 2. **Recorder heartbeat freshness** — the recorder upserts a row every ~10 s.
///    If the most recent write is > 60 s old (or the row is missing) the probe
///    considers the recorder down and includes `"recorder": "stale"`.
///
/// Returns:
/// - `200 OK` when both DB and recorder are healthy.
/// - `503 Service Unavailable` when either check fails, with a JSON body
///   describing which component is unhealthy.  This lets Docker `HEALTHCHECK`
///   and any upstream proxy detect a degraded stack automatically.
///
/// No authentication required — health probes must work before auth is
/// established, and the response body contains no secrets.
async fn health(State(state): State<AppState>) -> (StatusCode, Json<serde_json::Value>) {
    // ── 1. database connectivity ──────────────────────────────────────────────
    let db_ok = match state.pool().get().await {
        Ok(conn) => conn.execute("SELECT 1", &[]).await.is_ok(),
        Err(_) => false,
    };

    // ── 2. recorder heartbeat freshness ──────────────────────────────────────
    // Mirror the alerter threshold: 60 s of silence = stale.
    const STALE_THRESHOLD_SECS: i64 = 60;

    let (recorder_ok, recorder_detail) =
        match crumb_common::db::read_recorder_heartbeat(state.pool()).await {
            Err(_) => (false, "db_error".to_owned()),
            Ok(None) => (false, "missing".to_owned()),
            Ok(Some(hb)) => {
                let age = chrono::Utc::now()
                    .signed_duration_since(hb.updated_at)
                    .num_seconds();
                if age > STALE_THRESHOLD_SECS {
                    (false, format!("stale ({age}s ago)"))
                } else {
                    (true, format!("ok ({age}s ago)"))
                }
            }
        };

    // ── response ──────────────────────────────────────────────────────────────
    // The API's liveness probe reflects the API's OWN health (DB reachable). A
    // stale/missing RECORDER heartbeat is surfaced as "degraded" in the body but
    // does NOT 503 the API probe — otherwise the api container's healthcheck would
    // flap (and autoheal could needlessly restart the API) whenever the recorder
    // is down, which restarting the API can't fix. The recorder is monitored
    // separately (its own healthcheck + the heartbeat alerter).
    let status_code = if db_ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    let overall = if !db_ok {
        "unavailable"
    } else if recorder_ok {
        "ok"
    } else {
        "degraded"
    };

    let body = json!({
        "status": overall,
        "service": "crumb-api",
        "checks": {
            "database": if db_ok { "ok" } else { "unavailable" },
            "recorder": recorder_detail,
        }
    });

    (status_code, Json(body))
}

/// `GET /admin` — the server-served admin console (a single self-contained page,
/// embedded at compile time). It signs in via `/auth/login` and drives the
/// admin-only `/config/*` endpoints, so no separate web build/deploy is needed.
async fn serve_admin() -> axum::response::Html<&'static str> {
    axum::response::Html(include_str!("admin.html"))
}

// ─── version ────────────────────────────────────────────────────────────────────

/// `GET /version` — build/version diagnostics for support + rollback.
///
/// Returns the product version (from the repo `VERSION` file), the git SHA, and
/// the build timestamp. SHA/timestamp are `"unknown"` for local dev builds that
/// did not have the CI build args injected.
async fn version() -> Json<serde_json::Value> {
    Json(json!({
        "service": "crumb-api",
        "version": VERSION.trim(),
        "git_sha": GIT_SHA.unwrap_or("unknown"),
        "built_at": BUILD_TIME.unwrap_or("unknown"),
    }))
}

// ─── export TTL sweeper ───────────────────────────────────────────────────────

/// Background task that removes completed export jobs (and their output files)
/// older than `ttl_seconds`.
///
/// Runs every minute.  Only removes jobs in `Done` or `Failed` state — running
/// jobs are never evicted.
async fn export_ttl_sweeper(state: AppState, ttl_seconds: u64) {
    let ttl = chrono::Duration::seconds(i64::try_from(ttl_seconds).unwrap_or(86_400));
    let tick = Duration::from_mins(1);

    loop {
        tokio::time::sleep(tick).await;

        let now = chrono::Utc::now();
        let jobs = state.export_jobs();
        let expired: Vec<uuid::Uuid> = jobs
            .iter()
            .filter(|entry| {
                let job = entry.value();
                matches!(
                    job.status,
                    dto::ExportStatus::Done
                        | dto::ExportStatus::Failed
                        | dto::ExportStatus::Cancelled
                ) && (now - job.created_at) > ttl
            })
            .map(|entry| *entry.key())
            .collect();

        for job_id in &expired {
            if let Some((_, job)) = jobs.remove(job_id) {
                // Best-effort: remove the export directory for this job.
                let export_path =
                    std::path::Path::new(&state.config().export_dir).join(job_id.to_string());
                match tokio::fs::remove_dir_all(&export_path).await {
                    Ok(()) => tracing::info!(job_id = %job_id, "export job TTL-evicted"),
                    // A cancelled job already removed its dir at cancel time, so a
                    // missing dir here is expected — only a real (dir-still-present)
                    // failure warns.
                    Err(e) if export_path.exists() => tracing::warn!(
                        job_id = %job_id,
                        path = %export_path.display(),
                        error = %e,
                        "failed to remove export directory during TTL sweep"
                    ),
                    Err(_) => {
                        tracing::info!(job_id = %job_id, "export job TTL-evicted (dir already gone)");
                    }
                }
                // Drop the persisted row so the table doesn't grow unbounded.
                if let Err(e) = export_store::delete_export_job(state.pool(), *job_id).await {
                    tracing::warn!(
                        job_id = %job_id,
                        error = %e,
                        "failed to delete persisted export job during TTL sweep"
                    );
                }
                drop(job);
            }
        }

        // Clip cache: clips are generated on demand and cached under
        // {export_dir}/clips; evict files older than the TTL, then evict
        // oldest-by-mtime past the byte budget so a burst of plays can't grow
        // the cache unbounded within a day. (A re-viewed clip regenerates.)
        sweep_clips_cache(
            &state.config().export_dir,
            ttl,
            state.config().clip_cache_max_bytes,
        )
        .await;

        // Thumbnail cache: filmstrip scrub frames cached under
        // {thumb_cache_base}/.thumbs/<camera>/ (EXPORT_DIR, or THUMB_CACHE_DIR if
        // set); evict by age then byte budget so a long scrubbing history can't
        // grow it unbounded. Only .jpg files inside .thumbs are ever removed
        // (guarded in the sweeper).
        sweep_thumbs_cache(
            state.config().thumb_cache_base(),
            chrono::Duration::seconds(
                i64::try_from(state.config().thumb_cache_ttl_seconds).unwrap_or(2_592_000),
            ),
            state.config().thumb_cache_max_bytes,
        )
        .await;
    }
}

/// Evict cached clip media (under `{export_dir}/clips`): first anything older
/// than `ttl` (by mtime), then — if the surviving files still exceed
/// `max_bytes` — the oldest until back under budget.
async fn sweep_clips_cache(export_dir: &str, ttl: chrono::Duration, max_bytes: u64) {
    let dir = std::path::Path::new(export_dir).join("clips");
    let now = std::time::SystemTime::now();
    let max_age =
        std::time::Duration::from_secs(u64::try_from(ttl.num_seconds()).unwrap_or(86_400));

    // Pass 1: age eviction; collect survivors as (path, mtime, size) for pass 2.
    let mut survivors: Vec<(std::path::PathBuf, std::time::SystemTime, u64)> = Vec::new();
    let mut total: u64 = 0;
    let mut rd = match tokio::fs::read_dir(&dir).await {
        Ok(rd) => rd,
        Err(_) => return, // cache dir not created yet
    };
    while let Ok(Some(entry)) = rd.next_entry().await {
        let Ok(meta) = entry.metadata().await else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let mtime = meta.modified().unwrap_or(now);
        let age = now.duration_since(mtime).ok();
        if age.is_some_and(|a| a > max_age) {
            let _ = tokio::fs::remove_file(entry.path()).await;
            continue;
        }
        total += meta.len();
        survivors.push((entry.path(), mtime, meta.len()));
    }

    // Pass 2: byte-budget LRU eviction (oldest mtime first).
    if total > max_bytes {
        survivors.sort_by_key(|(_, mtime, _)| *mtime); // oldest first
        for (path, _, size) in survivors {
            if total <= max_bytes {
                break;
            }
            if tokio::fs::remove_file(&path).await.is_ok() {
                total = total.saturating_sub(size);
            }
        }
    }
}

/// Evict cached filmstrip thumbnails under `{export_dir}/.thumbs` (walked
/// recursively: `<camera>/…/<ts>.jpg`, including Phase-1 hour subdirs). First
/// anything older than `ttl` by mtime, then, if survivors still exceed
/// `max_bytes`, the oldest until back under budget.
///
/// GUARDED: only `.jpg` files inside the canonical `.thumbs` root are ever
/// removed, so it can never touch a segment, export, or clip even if an odd
/// entry appears under the tree.
async fn sweep_thumbs_cache(export_dir: &str, ttl: chrono::Duration, max_bytes: u64) {
    let root_canon =
        match tokio::fs::canonicalize(std::path::Path::new(export_dir).join(".thumbs")).await {
            Ok(p) => p,
            Err(_) => return, // no thumbs cache yet
        };
    let now = std::time::SystemTime::now();
    let max_age =
        std::time::Duration::from_secs(u64::try_from(ttl.num_seconds()).unwrap_or(2_592_000));

    // Pass 1: recursive walk + age eviction; collect survivors for pass 2.
    let mut survivors: Vec<(std::path::PathBuf, std::time::SystemTime, u64)> = Vec::new();
    let mut total: u64 = 0;
    let mut stack: Vec<std::path::PathBuf> = vec![root_canon.clone()];
    while let Some(dir) = stack.pop() {
        let mut rd = match tokio::fs::read_dir(&dir).await {
            Ok(rd) => rd,
            Err(_) => continue,
        };
        while let Ok(Some(entry)) = rd.next_entry().await {
            let path = entry.path();
            let Ok(meta) = entry.metadata().await else {
                continue;
            };
            if meta.is_dir() {
                stack.push(path);
                continue;
            }
            // GUARD: only .jpg files, and only within the canonical .thumbs
            // root. Anything else is left untouched.
            if !meta.is_file()
                || path.extension().and_then(|e| e.to_str()) != Some("jpg")
                || !path.starts_with(&root_canon)
            {
                continue;
            }
            let mtime = meta.modified().unwrap_or(now);
            if now.duration_since(mtime).ok().is_some_and(|a| a > max_age) {
                let _ = tokio::fs::remove_file(&path).await;
                continue;
            }
            total += meta.len();
            survivors.push((path, mtime, meta.len()));
        }
    }

    // Pass 2: byte-budget LRU eviction (oldest mtime first).
    if total > max_bytes {
        survivors.sort_by_key(|(_, mtime, _)| *mtime);
        for (path, _, size) in survivors {
            if total <= max_bytes {
                break;
            }
            if tokio::fs::remove_file(&path).await.is_ok() {
                total = total.saturating_sub(size);
            }
        }
    }
}

#[cfg(test)]
mod thumb_sweep_tests {
    use super::sweep_thumbs_cache;

    /// The sweeper removes `.jpg` thumbnails but NEVER a non-jpg file under
    /// `.thumbs`, and honours the byte budget. Uses `max_bytes = 0` so the
    /// byte-eviction pass runs on all surviving jpgs without needing to age
    /// their mtimes, and a generous ttl so the age pass keeps everything for
    /// pass 2 to act on.
    #[tokio::test]
    async fn sweeps_only_jpgs_within_thumbs() {
        // Manual unique temp dir (the api test-suite avoids the tempfile crate;
        // see tests/support). Keyed by pid so parallel test binaries don't clash.
        let base = std::env::temp_dir().join(format!("crumb-thumbsweep-{}", std::process::id()));
        let _ = tokio::fs::remove_dir_all(&base).await;
        let cam_dir = base.join(".thumbs").join("cam-a");
        tokio::fs::create_dir_all(&cam_dir).await.unwrap();

        let jpg1 = cam_dir.join("0000000001000.jpg");
        let jpg2 = cam_dir.join("0000000002000.jpg");
        let keep = cam_dir.join("do-not-touch.mp4"); // a non-jpg the guard must skip
        tokio::fs::write(&jpg1, b"xxxx").await.unwrap();
        tokio::fs::write(&jpg2, b"yyyy").await.unwrap();
        tokio::fs::write(&keep, b"segment-ish").await.unwrap();

        // ttl huge (nothing age-evicted), byte budget 0 (all jpgs LRU-evicted).
        sweep_thumbs_cache(base.to_str().unwrap(), chrono::Duration::seconds(86_400), 0).await;

        assert!(!jpg1.exists(), "jpg1 should be byte-budget evicted");
        assert!(!jpg2.exists(), "jpg2 should be byte-budget evicted");
        assert!(keep.exists(), "non-jpg file must never be removed");

        let _ = tokio::fs::remove_dir_all(&base).await;
    }
}
