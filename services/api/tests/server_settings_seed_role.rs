// SPDX-License-Identifier: AGPL-3.0-or-later

//! The `server_settings` bootstrap must not seed either `crumb_*` base column
//! from the recorder's own view of go2rtc (issue #630).
//!
//! `ensure_server_settings_table` runs on EVERY process start, in both the api
//! and the recorder, and backfills any EMPTY column from that process's env.
//! The recorder's `CRUMB_GO2RTC_RTSP_BASE` is `rtsp://localhost:8554` in the
//! shipped compose, so the first recorder restart after the column was emptied
//! wrote loopback into the column the api hands to native clients: every camera
//! on every desktop and phone went to "Reconnecting" while recorded playback
//! kept working. That is what made every configuration-only workaround
//! temporary.
//!
//! `crumb_api_base` has the same shape: the recorder's compose default was
//! `http://localhost:1984`, nothing in the recorder reads that key, and the api
//! proxies iOS/macOS live (MSE and WebRTC signaling), `frame.jpg` snapshots and
//! notification images through the column. A poisoned value points the api at
//! its own container, where nothing is listening, and recording again looks
//! perfectly healthy.
//!
//! # Concurrency
//!
//! `server_settings` is a singleton row, so every test here takes
//! [`SERVER_SETTINGS_LOCK`] and restores the column it found before returning.
//! Both tests set `CRUMB_GO2RTC_RTSP_BASE` in this process; the lock keeps that
//! serialized within this test binary.

mod support;

use crumb_common::db::{ensure_server_settings_table, SettingsSeedRole};
use deadpool_postgres::Pool;
use support::*;

/// One stored base column. `column` is always a literal from this file.
async fn stored(pool: &Pool, column: &str) -> String {
    let client = pool.get().await.expect("pool.get");
    client
        .query_one(
            &format!("SELECT {column} FROM server_settings WHERE id = 1"),
            &[],
        )
        .await
        .expect("select base column")
        .get(0)
}

/// The stored client-facing RTSP base.
async fn stored_base(pool: &Pool) -> String {
    stored(pool, "crumb_rtsp_base").await
}

/// `updated_at` for the singleton row.
async fn stored_updated_at(pool: &Pool) -> chrono::DateTime<chrono::Utc> {
    let client = pool.get().await.expect("pool.get");
    client
        .query_one("SELECT updated_at FROM server_settings WHERE id = 1", &[])
        .await
        .expect("select updated_at")
        .get(0)
}

async fn set_column(pool: &Pool, column: &str, value: &str) {
    let client = pool.get().await.expect("pool.get");
    client
        .execute(
            &format!("UPDATE server_settings SET {column} = $1 WHERE id = 1"),
            &[&value],
        )
        .await
        .expect("update base column");
}

async fn set_base(pool: &Pool, value: &str) {
    set_column(pool, "crumb_rtsp_base", value).await;
}

/// The bug, against a real row: with the column empty and the recorder's
/// loopback env value set, a recorder-role bootstrap must leave the column
/// alone, while an api-role bootstrap still carries a routable,
/// client-reachable value over.
#[tokio::test]
async fn recorder_bootstrap_leaves_the_client_facing_rtsp_base_empty() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let pool = app.pool();
    let original = stored_base(pool).await;

    // Exactly what the shipped compose puts in the recorder's environment.
    std::env::set_var("CRUMB_GO2RTC_RTSP_BASE", "rtsp://localhost:8554");
    set_base(pool, "").await;

    ensure_server_settings_table(pool, SettingsSeedRole::Recorder)
        .await
        .expect("recorder bootstrap");
    assert_eq!(
        stored_base(pool).await,
        "",
        "the recorder must never write its own dial address into the \
         client-facing column"
    );

    // A second recorder start is still a no-op (the race in #630 was "whichever
    // process wins", so this must hold however many times it runs).
    ensure_server_settings_table(pool, SettingsSeedRole::Recorder)
        .await
        .expect("recorder bootstrap, again");
    assert_eq!(stored_base(pool).await, "");

    // The api, with a routable value, still seeds: an install that relies on
    // the env fallback keeps working.
    std::env::set_var("CRUMB_GO2RTC_RTSP_BASE", "rtsp://192.0.2.50:18554");
    ensure_server_settings_table(pool, SettingsSeedRole::Api)
        .await
        .expect("api bootstrap");
    assert_eq!(stored_base(pool).await, "rtsp://192.0.2.50:18554");

    set_base(pool, &original).await;
    std::env::remove_var("CRUMB_GO2RTC_RTSP_BASE");
}

/// The second half of the same defect: `crumb_api_base` is what the api dials
/// for go2rtc's REST API, and the recorder used to seed it with its own
/// loopback view.
#[tokio::test]
async fn recorder_bootstrap_leaves_the_crumb_api_base_alone() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let pool = app.pool();
    let original = stored(pool, "crumb_api_base").await;

    // What the shipped compose used to put in the recorder's environment.
    std::env::set_var("CRUMB_GO2RTC_API_BASE", "http://localhost:1984");
    set_column(pool, "crumb_api_base", "").await;

    ensure_server_settings_table(pool, SettingsSeedRole::Recorder)
        .await
        .expect("recorder bootstrap");
    assert_eq!(
        stored(pool, "crumb_api_base").await,
        "",
        "the recorder must never seed the go2rtc REST base the api dials"
    );

    // The api still seeds it, so an env-configured install keeps working.
    std::env::set_var("CRUMB_GO2RTC_API_BASE", "http://192.0.2.50:1984");
    ensure_server_settings_table(pool, SettingsSeedRole::Api)
        .await
        .expect("api bootstrap");
    assert_eq!(
        stored(pool, "crumb_api_base").await,
        "http://192.0.2.50:1984"
    );

    set_column(pool, "crumb_api_base", &original).await;
    std::env::remove_var("CRUMB_GO2RTC_API_BASE");
}

/// The bootstrap used to rewrite the row on every start without touching
/// `updated_at`, so a value written minutes ago still showed a timestamp from
/// weeks earlier. It now only writes when the backfill actually changes
/// something, and then `updated_at` moves.
#[tokio::test]
async fn bootstrap_updated_at_is_honest() {
    let _guard = SERVER_SETTINGS_LOCK.lock().await;
    let app = TestApp::new().await;
    let pool = app.pool();
    let original = stored_base(pool).await;

    std::env::remove_var("CRUMB_GO2RTC_RTSP_BASE");
    std::env::remove_var("CRUMB_GO2RTC_API_BASE");
    set_base(pool, "rtsp://192.0.2.51:18554").await;
    // Run it once so every column this process could seed is already filled;
    // whatever is left is a genuine no-op, whichever env vars the host has set.
    ensure_server_settings_table(pool, SettingsSeedRole::Api)
        .await
        .expect("first bootstrap");

    let before = stored_updated_at(pool).await;
    ensure_server_settings_table(pool, SettingsSeedRole::Api)
        .await
        .expect("no-op bootstrap");
    assert_eq!(
        stored_updated_at(pool).await,
        before,
        "a bootstrap that changes nothing must not touch the row"
    );

    // A real backfill moves the timestamp.
    set_base(pool, "").await;
    std::env::set_var("CRUMB_GO2RTC_RTSP_BASE", "rtsp://192.0.2.52:18554");
    let before = stored_updated_at(pool).await;
    ensure_server_settings_table(pool, SettingsSeedRole::Api)
        .await
        .expect("seeding bootstrap");
    assert_eq!(stored_base(pool).await, "rtsp://192.0.2.52:18554");
    assert!(
        stored_updated_at(pool).await > before,
        "a backfill that writes a value must move updated_at"
    );

    set_base(pool, &original).await;
    std::env::remove_var("CRUMB_GO2RTC_RTSP_BASE");
}
