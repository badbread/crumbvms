// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shared test harness for the auth/RBAC integration suite.
//!
//! # Why this file re-includes the crate's `src/` modules
//!
//! `crumb-api` is a **binary-only** crate (see `services/api/Cargo.toml` —
//! only a `[[bin]]`, no `[lib]`), and every module in `src/` is a private
//! `mod` in `main.rs` (not `pub mod`). That means an ordinary Cargo
//! integration test under `tests/` — which compiles as an entirely separate
//! crate — cannot `use crumb_api::auth_mw::AuthUser` or similar: there is no
//! library target to link against, and the modules aren't part of any public
//! surface.
//!
//! Rather than weaken production code (adding a `[lib]` target / making
//! modules `pub` is out of scope for this test-only change — see
//! `docs/RELEASE-PLAN.md` P0-AUTHTEST, which restricts changes to
//! `services/api/tests/`), this harness re-includes the REAL source files
//! directly via `#[path = "../src/....rs"]`, recompiled into the test
//! binary's own `crate::` namespace. This is not a copy or a reimplementation
//! — it is the literal same `auth.rs` / `auth_mw.rs` / `playback.rs` / etc.
//! source, so the tests exercise the actual JWT/Argon2/RBAC enforcement code,
//! not a stand-in.
//!
//! Only the modules needed to build a real `axum::Router` covering the
//! auth/RBAC surface are included (auth, config admin-gate, playback, clips,
//! export, events snapshot, roles, discovery, stream-test + the `ffprobe`
//! helper they share). Heavier modules with no bearing on auth/RBAC (Frigate
//! MQTT detection ingestion, notifications, go2rtc reconcile loop, metrics)
//! are deliberately left out — the router built here is a faithful
//! **subset** of production routing, not the full app.
//!
//! # Database
//!
//! Tests run against a REAL Postgres (see `docs/RELEASE-PLAN.md` P0-AUTHTEST
//! — "against the CI Postgres service or testcontainers"). Point
//! `TEST_DATABASE_URL` (falls back to `DATABASE_URL`, then a sensible local
//! default) at an empty/throwaway Postgres 16 database; `run_migrations` self
//! -provisions the whole schema from the embedded migration SQL, exactly as
//! production does on first boot. Migrations run once per test-binary
//! process (guarded by a `tokio::sync::OnceCell`); every test then seeds its
//! own uniquely-named rows (random suffix) so tests can run concurrently
//! against the same shared schema without colliding.

#![allow(dead_code)] // not every helper is used by every test file

// ── real source modules, recompiled into this test binary ──────────────────
#[path = "../../src/auth.rs"]
pub mod auth;
#[path = "../../src/auth_mw.rs"]
pub mod auth_mw;
#[path = "../../src/clips.rs"]
pub mod clips;
#[path = "../../src/config.rs"]
pub mod config;
#[path = "../../src/config_routes.rs"]
pub mod config_routes;
#[path = "../../src/discover.rs"]
pub mod discover;
#[path = "../../src/dto.rs"]
pub mod dto;
#[path = "../../src/error.rs"]
pub mod error;
#[path = "../../src/events.rs"]
pub mod events;
#[path = "../../src/export.rs"]
pub mod export;
#[path = "../../src/export_store.rs"]
pub mod export_store;
#[path = "../../src/ffprobe.rs"]
pub mod ffprobe;
#[path = "../../src/filmstrip.rs"]
pub mod filmstrip;
#[path = "../../src/go2rtc.rs"]
pub mod go2rtc;
#[path = "../../src/playback.rs"]
pub mod playback;
#[path = "../../src/ptz.rs"]
pub mod ptz;
#[path = "../../src/roles.rs"]
pub mod roles;
#[path = "../../src/state.rs"]
pub mod state;
#[path = "../../src/stream_test.rs"]
pub mod stream_test;
// -- additional route modules so test_router() can cover the FULL API surface
//    for the auth-invariant walk (still tests/-only #[path] includes, no [lib] /
//    pub-module change to production; audit 2026-07-05). Every dep of these
//    resolves to an already-included module above (channel_notify<->notifications
//    is a mutual pair). --
#[path = "../../src/bookmarks.rs"]
pub mod bookmarks;
#[path = "../../src/cameras.rs"]
pub mod cameras;
#[path = "../../src/channel_notify.rs"]
pub mod channel_notify;
#[path = "../../src/notifications.rs"]
pub mod notifications;
#[path = "../../src/stats.rs"]
pub mod stats;
#[path = "../../src/status.rs"]
pub mod status;
#[path = "../../src/timeline.rs"]
pub mod timeline;
#[path = "../../src/views.rs"]
pub mod views;

use std::sync::atomic::{AtomicU32, Ordering};

use axum::Router;
use deadpool_postgres::Pool;
use tower::ServiceExt as _;
use uuid::Uuid;

use crumb_common::{
    db,
    types::{Capabilities, UserRole},
};

use crate::support::state::AppState;

/// Default local Postgres URL used when neither `TEST_DATABASE_URL` nor
/// `DATABASE_URL` is set — matches the `.env.example` throwaway dev creds so
/// `docker run -e POSTGRES_USER=crumb -e POSTGRES_PASSWORD=change-me -e
/// POSTGRES_DB=crumb -p 5432:5432 postgres:16-alpine` just works.
const DEFAULT_TEST_DB_URL: &str = "postgresql://crumb:change-me@127.0.0.1:5432/crumb";

/// A unique-enough per-process counter so parallel tests get distinct
/// usernames/camera names even when called within the same millisecond.
static COUNTER: AtomicU32 = AtomicU32::new(0);

/// Generate a short unique suffix for test row names (username, camera name,
/// role name, storage name, ...). Combines a process-local counter with a
/// random UUID fragment so concurrent test binaries (unlikely, but cheap to
/// guard) don't collide either.
pub fn unique(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let frag = Uuid::new_v4().simple().to_string();
    format!("{prefix}_{n}_{}", &frag[..8])
}

/// Resolve the Postgres URL the whole test binary uses.
fn database_url() -> String {
    std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap_or_else(|_| DEFAULT_TEST_DB_URL.to_owned())
}

/// Build a `config::ApiConfig` for tests. Sets the handful of required env
/// vars (`JWT_SECRET`, `GO2RTC_USER`/`GO2RTC_PASS`) if absent so
/// `ApiConfig::from_env` (the REAL startup path — same validation as
/// production) succeeds without needing a `.env` file on the test host.
fn ensure_env() {
    // Safe defaults only set if unset — never clobber a deliberately-set env
    // (e.g. a CI job pointing at a specific throwaway Postgres).
    if std::env::var("DATABASE_URL").is_err() {
        std::env::set_var("DATABASE_URL", database_url());
    }
    if std::env::var("JWT_SECRET").is_err() {
        // Must be >= 32 bytes (ApiConfig::from_env enforces this) and not the
        // known weak placeholder.
        std::env::set_var(
            "JWT_SECRET",
            "test-only-secret-do-not-use-in-prod-aaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        );
    }
    if std::env::var("GO2RTC_USER").is_err() {
        std::env::set_var("GO2RTC_USER", "test_go2rtc_user");
    }
    if std::env::var("GO2RTC_PASS").is_err() {
        std::env::set_var("GO2RTC_PASS", "test_go2rtc_pass");
    }
    // Short JWT expiry by default so the "expired token" test doesn't need a
    // long sleep; individual tests that need a specific expiry mint their own
    // token via /auth/login regardless.
    if std::env::var("JWT_EXPIRY_SECONDS").is_err() {
        std::env::set_var("JWT_EXPIRY_SECONDS", "86400");
    }
}

// Guards the migration run so it executes exactly once per test-binary
// process even though many `#[tokio::test]` functions call `test_state()`
// concurrently (each `#[tokio::test]` gets its own single-threaded runtime,
// so a plain `OnceLock::get()/set()` check-then-act race is NOT benign here:
// several of the embedded migration files issue bare `CREATE TYPE`/`CREATE
// TABLE`/`CREATE INDEX` (not all guarded by `IF NOT EXISTS`), so two
// connections racing through `run_migrations` concurrently produced real
// `duplicate key value violates unique constraint` and even Postgres
// deadlock errors in practice. A `tokio::sync::Mutex` held for the whole
// "have we migrated yet" check+run makes every concurrent caller queue
// behind the first, which then does the one-time work while everyone else
// waits and reuses the result.
static MIGRATE_ONCE: tokio::sync::Mutex<bool> = tokio::sync::Mutex::const_new(false);

/// Build a fresh [`AppState`] wired to the shared test Postgres, running
/// migrations exactly once per process (idempotent + tracked via
/// `schema_migrations`, so this is also safe if called from multiple test
/// binaries hitting the same DB).
pub async fn test_state() -> AppState {
    ensure_env();
    let cfg = config::ApiConfig::from_env().expect("ApiConfig::from_env (test env)");
    let pool: Pool =
        db::build_pool(&cfg.database_url, cfg.db_pool_size).expect("build_pool (test DB)");

    // Fail fast with a clear message if Postgres isn't reachable — this is the
    // single most common "why did every test fail" cause for this suite.
    {
        let client = pool.get().await.unwrap_or_else(|e| {
            panic!(
                "cannot connect to test Postgres at {:?}: {e}\n\
                 Start one first, e.g.:\n\
                 docker run --rm -d --name crumb-test-pg \\\n  \
                 -e POSTGRES_USER=crumb -e POSTGRES_PASSWORD=change-me -e POSTGRES_DB=crumb \\\n  \
                 -p 5432:5432 postgres:16-alpine",
                cfg.database_url
            )
        });
        client
            .execute("SELECT 1", &[])
            .await
            .expect("SELECT 1 against test Postgres");
    }

    // Serialize the one-time migration run across all concurrently-starting
    // tests (see MIGRATE_ONCE doc comment above for why this must be a real
    // lock, not a best-effort check).
    {
        let mut done = MIGRATE_ONCE.lock().await;
        if !*done {
            db::run_migrations(&pool)
                .await
                .expect("run_migrations against test Postgres");
            db::ensure_named_policies_and_groups(&pool)
                .await
                .expect("ensure_named_policies_and_groups");
            seed_default_policy_if_absent(&pool).await;
            *done = true;
        }
    }

    AppState::new(pool, cfg)
}

/// Seed the single global-default `recording_policies` row (`is_default =
/// true`) if absent.
///
/// Production seeds this via the recorder's separate `seed` binary
/// (`services/recorder/src/bin/seed.rs`), which this test harness
/// deliberately does NOT link (it's a standalone `[[bin]]`, not exposed for
/// reuse, and pulling it in would drag in the recorder's whole camera/ONVIF
/// seeding flow just for one INSERT). `db::clone_default_policy` /
/// `db::get_default_policy` — both exercised indirectly by camera seeding and
/// the config routes here — hard-require exactly one such row to exist
/// (`one_default_policy` partial unique index caps it at ≤ 1), so tests that
/// create a camera need it present first. Mirrors `seed.rs`'s own INSERT
/// (same columns/defaults: continuous mode, no storage yet, 48h live
/// retention, archive off).
async fn seed_default_policy_if_absent(pool: &Pool) {
    let client = pool.get().await.expect("pool.get (seed_default_policy)");
    let count: i64 = client
        .query_one(
            "SELECT COUNT(*)::bigint FROM recording_policies WHERE is_default",
            &[],
        )
        .await
        .expect("count default policies")
        .get(0);
    if count > 0 {
        return;
    }
    client
        .execute(
            r"
            INSERT INTO recording_policies (
                is_default, mode, live_storage_id, live_retention_hours,
                archive_enabled, archive_storage_id, archive_schedule, archive_retention_hours,
                motion_pre_seconds, motion_post_seconds, motion_sensitivity,
                motion_keyframes_only, record_stream
            )
            VALUES (
                true, 'continuous', NULL, 48,
                false, NULL, NULL, NULL,
                5, 10, 'dynamic',
                false, 'main'
            )
            ",
            &[],
        )
        .await
        .expect("seed default recording_policies row");
}

/// Build the subset router this suite exercises: `/auth`, `/config` (admin
/// gate), and the media/playback/clips/export/events routes that enforce
/// per-camera RBAC. Mirrors the mounting in `main.rs` closely enough to be a
/// faithful test of the real routing + extractor stack (same `routes()`
/// calls as production; layers like gzip/CORS/rate-limit are auth-orthogonal
/// and omitted for test simplicity).
pub fn test_router() -> Router<AppState> {
    Router::new()
        .nest("/auth", auth::routes())
        // P0-SESSIONS scoped-media-token mint (top-level GET /media-token).
        .merge(auth::media_token_routes())
        .nest("/config", config_routes::routes())
        .merge(playback::routes())
        .merge(export::routes())
        .merge(filmstrip::routes())
        .merge(events::json_routes())
        .merge(events::media_routes())
        .merge(clips::json_routes())
        .merge(clips::media_routes())
        // -- full-surface: the remaining viewer-facing JSON + media route groups
        //    (mirrors main.rs's json_routes/media_routes merges, minus the
        //    rate-limit/timeout/gzip layers that don't bear on auth) so the
        //    auth-invariant walk covers every route, not just the RBAC subset. --
        .merge(cameras::json_routes())
        .merge(cameras::routes())
        .merge(views::routes())
        .merge(bookmarks::routes())
        .merge(timeline::routes())
        .merge(status::routes())
        .merge(stats::routes())
        .merge(stats::heavy_routes())
        .merge(ptz::routes())
        .merge(notifications::routes())
}

/// A running instance of the test app: state + built router, ready to
/// `.oneshot(request)`.
pub struct TestApp {
    pub state: AppState,
    pub router: Router,
}

impl TestApp {
    pub async fn new() -> Self {
        let state = test_state().await;
        let router = test_router().with_state(state.clone());
        Self { state, router }
    }

    pub fn pool(&self) -> &Pool {
        self.state.pool()
    }

    /// Send a request through the router and return the response.
    pub async fn send(
        &self,
        req: axum::http::Request<axum::body::Body>,
    ) -> axum::http::Response<axum::body::Body> {
        self.router
            .clone()
            .oneshot(req)
            .await
            .expect("router::oneshot is infallible for a well-formed Request")
    }
}

// ─── seeding helpers ────────────────────────────────────────────────────────

/// A seeded viewer/admin role + user, with the plaintext password kept around
/// so the test can exercise `POST /auth/login`.
pub struct SeededUser {
    pub user_id: Uuid,
    pub username: String,
    pub password: String,
    pub role_id: Option<Uuid>,
}

/// Create an admin user (assigned the built-in admin role). Returns the
/// plaintext password for use against `/auth/login`.
pub async fn seed_admin(pool: &Pool) -> SeededUser {
    let username = unique("admin");
    let password = "correct horse battery staple".to_owned();
    let hash = hash_password_for_test(&password);
    let admin_role_id = db::get_admin_role_id(pool)
        .await
        .expect("get_admin_role_id")
        .expect("admin role seeded by migration 0028");
    let user = db::create_user(
        pool,
        &username,
        &hash,
        UserRole::Admin,
        &[],
        Some(admin_role_id),
    )
    .await
    .expect("create_user (admin)");
    SeededUser {
        user_id: user.id,
        username,
        password,
        role_id: Some(admin_role_id),
    }
}

/// Create a viewer role scoped to exactly `camera_ids`, with the given
/// capabilities (defaults to a generous "can do everything a viewer can do"
/// set — playback/clips/export/ptz all `true` — so scope-denial tests are
/// unambiguously about camera scope, not a missing capability).
pub async fn seed_viewer_role(pool: &Pool, camera_ids: &[Uuid]) -> Uuid {
    let name = unique("role");
    let caps = Capabilities {
        export: true,
        playback: true,
        clips: true,
        ptz: true,
        bookmarks: crumb_common::types::BookmarkScope::All,
        manage_views: true,
    };
    let role = db::create_role(pool, &name, &caps, camera_ids)
        .await
        .expect("create_role (viewer)");
    role.id
}

/// Create a viewer user assigned to `role_id`.
pub async fn seed_viewer_user(pool: &Pool, role_id: Uuid) -> SeededUser {
    let username = unique("viewer");
    let password = "correct horse battery staple".to_owned();
    let hash = hash_password_for_test(&password);
    let user = db::create_user(pool, &username, &hash, UserRole::Viewer, &[], Some(role_id))
        .await
        .expect("create_user (viewer)");
    SeededUser {
        user_id: user.id,
        username,
        password,
        role_id: Some(role_id),
    }
}

/// Convenience: seed a viewer role scoped to `camera_ids` + a user assigned
/// to it, in one call.
pub async fn seed_viewer(pool: &Pool, camera_ids: &[Uuid]) -> SeededUser {
    let role_id = seed_viewer_role(pool, camera_ids).await;
    seed_viewer_user(pool, role_id).await
}

/// Hash a password the same way `auth.rs::hash_password` does (Argon2id,
/// random salt). Duplicated here (rather than calling the private
/// `auth::hash_password`) only because keeping the seeding helper decoupled
/// from `auth.rs`'s internals is simpler; the verification path under test is
/// still the real `auth::login` handler's `verify_password`.
fn hash_password_for_test(password: &str) -> String {
    use argon2::{
        password_hash::{PasswordHasher, SaltString},
        Argon2,
    };
    let salt_bytes = *Uuid::new_v4().as_bytes();
    let salt = argon2::password_hash::SaltString::encode_b64(&salt_bytes)
        .expect("16-byte UUID is a valid SaltString");
    let _ = SaltString::from_b64; // keep import used across argon2 versions
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .expect("argon2 hash")
        .to_string()
}

/// Seed a storage row pointing at a real temp directory (so `ServeFile`
/// actually has bytes to serve for the "own camera, 200" playback test).
pub async fn seed_storage(pool: &Pool, path: &str) -> Uuid {
    let name = unique("storage");
    let storage = db::create_storage(pool, &name, path, None, None)
        .await
        .expect("create_storage");
    storage.id
}

/// Seed a minimal camera (own policy cloned from the global default) and
/// return its id.
pub async fn seed_camera(pool: &Pool) -> Uuid {
    let name = unique("cam");
    let go2rtc_name = unique("go2rtc");
    let policy_id = db::clone_default_policy(pool)
        .await
        .expect("clone_default_policy");
    let params = db::CreateCameraParams {
        name: &name,
        go2rtc_name: &go2rtc_name,
        main_url: "rtsp://127.0.0.1:18554/does-not-matter",
        sub_url: None,
        source_url: None,
        source_sub_url: None,
        enabled: true,
        policy_id,
        motion_mask: None,
        onvif_motion: false,
        motion_source: "pixel",
        motion_algorithm: "census",
        camera_type: None,
        icon: None,
        served_by: "crumb",
        source_camera_name: None,
        onvif_host: None,
        onvif_port: None,
        onvif_user: None,
        onvif_password: None,
    };
    let camera = db::create_camera(pool, &params)
        .await
        .expect("create_camera");
    camera.id
}

/// Seed a segment row for `camera_id` on `storage_id`, with a REAL file
/// written to `{storage_root}/{relative_path}` so `GET /segments/{id}` can
/// actually 200 with bytes (not just DB metadata). Returns the segment id.
pub async fn seed_segment_with_file(
    pool: &Pool,
    camera_id: Uuid,
    storage_id: Uuid,
    storage_root: &std::path::Path,
) -> Uuid {
    let rel_path = format!("{}/seg.mp4", unique("segdir"));
    let abs_path = storage_root.join(&rel_path);
    tokio::fs::create_dir_all(abs_path.parent().unwrap())
        .await
        .expect("mkdir segment dir");
    tokio::fs::write(&abs_path, b"fake mp4 bytes for range-serving test")
        .await
        .expect("write fake segment file");

    let now = chrono::Utc::now();
    let client = pool.get().await.expect("pool.get (seed_segment)");
    let row = client
        .query_one(
            r"
            INSERT INTO segments
                (camera_id, storage_id, stage, path, stream, start_ts, end_ts, duration_ms, has_motion, size_bytes)
            VALUES ($1, $2, 'live', $3, 'main', $4, $5, 4000, false, 64)
            RETURNING id
            ",
            &[
                &camera_id,
                &storage_id,
                &rel_path,
                &now,
                &(now + chrono::Duration::seconds(4)),
            ],
        )
        .await
        .expect("insert segment");
    row.get::<_, Uuid>("id")
}

/// Seed a detection `events` row for `camera_id` with a snapshot path, so
/// `GET /events/{id}/snapshot` has something to scope-check. The provider URL
/// deliberately points nowhere reachable — tests only assert the
/// auth/scope gate fires (403/401) BEFORE any upstream fetch is attempted;
/// they do not assert on the eventual 502.
pub async fn seed_event(pool: &Pool, camera_id: Uuid) -> Uuid {
    let client = pool.get().await.expect("pool.get (seed_event)");
    let now = chrono::Utc::now();
    let row = client
        .query_one(
            r"
            INSERT INTO events (camera_id, ts, label, score, thumb_path, snapshot_url)
            VALUES ($1, $2, 'person', 0.9, NULL, '/does/not/exist.jpg')
            RETURNING id
            ",
            &[&camera_id, &now],
        )
        .await
        .expect("insert event");
    row.get::<_, Uuid>("id")
}

// ─── HTTP helpers ───────────────────────────────────────────────────────────

/// Build a `POST /auth/login` request body.
pub fn login_body(username: &str, password: &str) -> serde_json::Value {
    serde_json::json!({ "username": username, "password": password })
}

/// Perform a real login through the router and return the bearer token.
/// Exercises the actual `auth::login` handler (Argon2 verify + JWT mint).
pub async fn login(app: &TestApp, username: &str, password: &str) -> String {
    let body = login_body(username, password).to_string();
    let req = axum::http::Request::builder()
        .method("POST")
        .uri("/auth/login")
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body))
        .unwrap();
    let resp = app.send(req).await;
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    assert!(
        status.is_success(),
        "login failed unexpectedly: {status} body={}",
        String::from_utf8_lossy(&bytes)
    );
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    v["token"]
        .as_str()
        .expect("token field in LoginResponse")
        .to_owned()
}

/// Build a bare (unauthenticated) GET request.
pub fn get(uri: &str) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("GET")
        .uri(uri)
        .body(axum::body::Body::empty())
        .unwrap()
}

/// Build a GET request with a Bearer token.
pub fn get_auth(uri: &str, token: &str) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("GET")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(axum::body::Body::empty())
        .unwrap()
}

/// Build a POST request with a Bearer token and a JSON body.
pub fn post_auth_json(
    uri: &str,
    token: &str,
    body: &serde_json::Value,
) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("POST")
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .header("content-type", "application/json")
        .body(axum::body::Body::from(body.to_string()))
        .unwrap()
}
