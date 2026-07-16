// SPDX-License-Identifier: AGPL-3.0-or-later

//! Clip-overview model, Phase 1 (issue #198, docs/design/CLIP-MODEL.md):
//! event-janitor `end_ts` convergence + the upsert self-heal, and the per-clip
//! singleflight lock. Pure window-formula / Frigate-gate / cache-key tests live
//! in `clips.rs`'s own `#[cfg(test)]` module (no DB needed); these exercise the
//! DB-backed pieces against a real Postgres via the shared harness.

// The harness (`mod support`) `#[path]`-includes the real `src/` modules, which
// clippy re-lints in this test binary; mirror the sibling tests' allow-set.
#![allow(clippy::module_name_repetitions)]
#![allow(clippy::option_option)]
#![allow(clippy::too_many_lines)]
#![allow(clippy::items_after_statements)]
#![allow(clippy::cast_possible_truncation)]
#![allow(clippy::cast_sign_loss)]
#![allow(clippy::cast_possible_wrap)]
#![allow(clippy::manual_let_else)]
#![allow(clippy::default_trait_access)]
#![allow(clippy::struct_excessive_bools)]
#![allow(clippy::match_same_arms)]
#![allow(clippy::manual_clamp)]
#![allow(clippy::format_push_string)]

mod support;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use crumb_common::db;
use deadpool_postgres::Pool;
use uuid::Uuid;
// Glob so support's `pub mod state`/… re-export into the crate root.
use support::*;

/// Insert an OPEN detection event (`end_ts` NULL) via the production upsert path,
/// then backdate its `updated_at` so the janitor treats it as stale. Returns its
/// row id + `ts`.
async fn seed_open_event_backdated(
    pool: &Pool,
    camera_id: Uuid,
    provider_event_id: &str,
    backdate_updated_at: DateTime<Utc>,
) -> (Uuid, DateTime<Utc>) {
    let ts = Utc::now() - Duration::hours(3);
    let params = db::UpsertDetectionEventParams {
        camera_id,
        start_ts: ts,
        label: "car".to_owned(),
        score: 0.9,
        source_id: "frigate".to_owned(),
        provider_event_id: provider_event_id.to_owned(),
        sub_label: None,
        top_score: 0.9,
        end_ts: None,
        zones: Vec::new(),
        snapshot_url: None,
        raw: serde_json::json!({ "type": "new" }),
        lifecycle: "start".to_owned(),
    };
    let id = db::upsert_detection_event(pool, &params)
        .await
        .expect("upsert open event");
    // Backdate the liveness stamp so it predates the janitor cutoff.
    let client = pool.get().await.expect("pool.get (backdate)");
    client
        .execute(
            "UPDATE events SET updated_at = $2 WHERE id = $1",
            &[&id, &backdate_updated_at],
        )
        .await
        .expect("backdate updated_at");
    (id, ts)
}

/// Read `(end_ts, lifecycle)` for an event id.
async fn read_event(pool: &Pool, id: Uuid) -> (Option<DateTime<Utc>>, String) {
    let client = pool.get().await.expect("pool.get (read_event)");
    let row = client
        .query_one("SELECT end_ts, lifecycle FROM events WHERE id = $1", &[&id])
        .await
        .expect("select event");
    (row.get("end_ts"), row.get("lifecycle"))
}

#[tokio::test]
async fn janitor_closes_stale_open_event() {
    let state = test_state().await;
    let pool = state.pool();
    let cam = seed_camera(pool).await;
    let pid = unique("frig-stale");
    // updated_at two hours ago → older than a 30-min cutoff.
    let (id, ts) =
        seed_open_event_backdated(pool, cam, &pid, Utc::now() - Duration::hours(2)).await;

    let cutoff = Utc::now() - Duration::minutes(30);
    let n = db::close_stale_open_events(pool, cutoff)
        .await
        .expect("close_stale_open_events");
    assert!(n >= 1, "at least our stale event was closed");

    let (end_ts, lifecycle) = read_event(pool, id).await;
    let end_ts = end_ts.expect("stale event now has a non-NULL end_ts");
    assert_eq!(lifecycle, "end", "janitor flips lifecycle to end");
    assert!(
        end_ts >= ts,
        "end_ts is never before the event start (GREATEST)"
    );
}

#[tokio::test]
async fn provider_end_self_heals_after_janitor_close() {
    let state = test_state().await;
    let pool = state.pool();
    let cam = seed_camera(pool).await;
    let pid = unique("frig-heal");
    let (id, ts) =
        seed_open_event_backdated(pool, cam, &pid, Utc::now() - Duration::hours(2)).await;

    // Janitor closes it with an estimate.
    db::close_stale_open_events(pool, Utc::now() - Duration::minutes(30))
        .await
        .expect("janitor close");
    let (estimate, _) = read_event(pool, id).await;
    assert!(estimate.is_some(), "janitor set an estimate");

    // A genuine provider `end` arrives LATE with a real end far past the estimate.
    let real_end = ts + Duration::minutes(90);
    let params = db::UpsertDetectionEventParams {
        camera_id: cam,
        start_ts: ts,
        label: "car".to_owned(),
        score: 0.9,
        source_id: "frigate".to_owned(),
        provider_event_id: pid.clone(),
        sub_label: None,
        top_score: 0.95,
        end_ts: Some(real_end),
        zones: Vec::new(),
        snapshot_url: None,
        raw: serde_json::json!({ "type": "end" }),
        lifecycle: "end".to_owned(),
    };
    db::upsert_detection_event(pool, &params)
        .await
        .expect("late provider end upsert");

    let (end_ts, _) = read_event(pool, id).await;
    let end_ts = end_ts.expect("still closed");
    // COALESCE(EXCLUDED.end_ts, ...) lets the real end win over the estimate.
    assert_eq!(
        end_ts.timestamp_millis(),
        real_end.timestamp_millis(),
        "the genuine provider end overwrites the janitor estimate"
    );
}

#[tokio::test]
async fn late_update_does_not_reopen_closed_event() {
    let state = test_state().await;
    let pool = state.pool();
    let cam = seed_camera(pool).await;
    let pid = unique("frig-noreopen");
    let (id, ts) =
        seed_open_event_backdated(pool, cam, &pid, Utc::now() - Duration::hours(2)).await;

    db::close_stale_open_events(pool, Utc::now() - Duration::minutes(30))
        .await
        .expect("janitor close");
    let (closed_end, _) = read_event(pool, id).await;
    let closed_end = closed_end.expect("janitor set an end");

    // A mid-event `update` with NO end arrives after the close. COALESCE keeps the
    // janitor's end_ts (the row must NOT reopen); lifecycle may flip to 'update'.
    let params = db::UpsertDetectionEventParams {
        camera_id: cam,
        start_ts: ts,
        label: "car".to_owned(),
        score: 0.8,
        source_id: "frigate".to_owned(),
        provider_event_id: pid.clone(),
        sub_label: None,
        top_score: 0.9,
        end_ts: None,
        zones: Vec::new(),
        snapshot_url: None,
        raw: serde_json::json!({ "type": "update" }),
        lifecycle: "update".to_owned(),
    };
    db::upsert_detection_event(pool, &params)
        .await
        .expect("late update upsert");

    let (end_ts, lifecycle) = read_event(pool, id).await;
    assert_eq!(
        end_ts.map(|t| t.timestamp_millis()),
        Some(closed_end.timestamp_millis()),
        "a late NULL-end update must not reopen the event"
    );
    assert_eq!(lifecycle, "update", "lifecycle reflects the latest message");
}

#[tokio::test]
async fn clip_singleflight_generates_once() {
    // Two concurrent misses on the same clip cache key must serialize on the
    // per-clip lock so the (expensive) generation runs exactly once; the second
    // caller observes the file the first produced. Uses the REAL
    // `AppState::clip_inflight_lock` with a simulated generate (no ffmpeg needed).
    let state = test_state().await;
    let path = std::env::temp_dir().join(format!("crumb-clip-sf-{}.preview.mp4", Uuid::new_v4()));

    let gen_count = Arc::new(AtomicUsize::new(0));
    let produced = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let run = |state: support::state::AppState,
               path: std::path::PathBuf,
               gen_count: Arc<AtomicUsize>,
               produced: Arc<std::sync::atomic::AtomicBool>| async move {
        let lock = state.clip_inflight_lock(&path);
        let _guard = lock.lock().await;
        // "check file, else generate", mirroring get_clip_media.
        if !produced.load(Ordering::SeqCst) {
            gen_count.fetch_add(1, Ordering::SeqCst);
            // Simulate transcode latency so a missing lock would race.
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            produced.store(true, Ordering::SeqCst);
        }
    };

    let a = tokio::spawn(run(
        state.clone(),
        path.clone(),
        gen_count.clone(),
        produced.clone(),
    ));
    let b = tokio::spawn(run(
        state.clone(),
        path.clone(),
        gen_count.clone(),
        produced.clone(),
    ));
    a.await.unwrap();
    b.await.unwrap();

    assert_eq!(
        gen_count.load(Ordering::SeqCst),
        1,
        "singleflight: two concurrent misses generate exactly once"
    );
}
