// SPDX-License-Identifier: AGPL-3.0-or-later

//! Stale-heartbeat alerting + system/health watchdogs (P0-HEALTH-NOTIFY).
//!
//! ## Legacy path: [`run_heartbeat_watchdog`]
//!
//! The recorder upserts a liveness heartbeat (`recorder_heartbeat`) every ~10 s.
//! The API is the always-on component, so it is the natural place to watch that
//! heartbeat and shout when it goes stale — the key failure mode is "the recorder
//! died while the stack keeps running", which nothing else would surface
//! (audit Risk #6).
//!
//! When `ALERT_WEBHOOK_URL` is configured, [`run_heartbeat_watchdog`] polls the
//! heartbeat every [`POLL_INTERVAL_SECS`] and POSTs a small JSON body to the
//! webhook when the heartbeat age exceeds [`STALE_THRESHOLD_SECS`] (and once more
//! on recovery). The body carries BOTH `content` (Discord) and `text` (Slack) so
//! a single generic webhook works with either; Pushover/ntfy can be added later.
//! This path is independent of, and predates, the system-alerts pipeline below —
//! kept as-is for anyone already relying on the raw-webhook env var.
//!
//! An `alerted` latch ensures exactly one alert per stale episode (no spam) and
//! one recovery message when the heartbeat comes back.
//!
//! ## System-alerts pipeline (P0-HEALTH-NOTIFY)
//!
//! [`run_system_health_watchdogs`] is the new, always-on (no env var required)
//! background task that feeds the SAME `system_events` table the notification
//! engine (`notifications.rs`) polls, which fans out over the SAME 6 channels
//! used for motion/detection alerts — configured per-event in the admin
//! Notifications panel's "System alerts" section (backed by
//! `system_alert_rules`, migration `0032_system_alerts.sql`).
//!
//! Fully wired here (state-transition watchdogs, each independently gated by
//! its `system_alert_rules.enabled` flag + `threshold_secs`):
//!
//! - `recorder_offline` — recorder heartbeat stale beyond threshold.
//! - `camera_offline` — motion-aware liveness check (see [`check_camera_offline`]):
//!   a Continuous-mode camera has written no new segment for longer than
//!   threshold; a Motion-mode camera's `camera_motion_cache_status` heartbeat
//!   has gone stale (idle-but-recording Motion cameras stay silent for minutes
//!   without a segment, so segment age alone is not a valid liveness signal for
//!   them). Covers both "camera unreachable" and "a should-be-recording camera
//!   silently stopped writing".
//! - `frigate_disconnected` — the API's Frigate detection provider
//!   (`detection/frigate.rs`) stamps a `frigate_heartbeat` (migration 0034) on
//!   each MQTT `ConnAck` + keep-alive; stale beyond threshold means the Frigate
//!   integration dropped and detection events are no longer being ingested.
//!   Skips entirely when Frigate has never connected (no heartbeat row).
//!
//! `premature_rollover` is emitted directly by the recorder's eviction path
//! (`services/recorder/src/archive.rs::emit_premature_rollover_if_early`) —
//! this module does not poll for it, only the notification engine does.
//!
//! `motion_detector_unhealthy` (migration 0038) is likewise emitted directly by
//! the recorder — `services/recorder/src/motion.rs::report_health`, on a
//! Motion-mode camera's detector going unhealthy (watchdog fired, motion task
//! died, Frigate motion selected-but-unconfigured, or no sub-stream). Advisory
//! only: the recording task fails OPEN and persists every segment while
//! unhealthy, so no footage is lost — only Motion mode's disk saving is paused.
//!
//! `motion_cache_unavailable` (migration 0040) is the same fail-open alert one
//! layer lower: emitted directly by the recorder —
//! `services/recorder/src/recording.rs`, section "2b. Motion-mode RAM cache
//! dir" — when a Motion-mode camera's tmpfs RAM cache dir can't be resolved or
//! created (e.g. the tmpfs mounted root-owned instead of `mode: 01777`, so the
//! recorder's non-root uid 1001 gets `EACCES`; see docs/MOTION-RECORDING.md).
//! Also advisory only: the recording task falls back to direct-to-storage and
//! no footage is lost, only Motion mode's disk saving is paused.
//!
//! Best-effort, cleanly-fits extras (see module docs on each function for what
//! is and is not covered):
//!
//! - `low_disk` — any storage's free space below the configured fraction.
//! - `policy_over_cap` — any policy at/over its live or archive byte cap.
//! - `backup_failed` — staleness BACKSTOP for the API's own built-in nightly
//!   backup job (`db_backup.rs`, which also emits `backup_failed` directly on
//!   a failed run): fires when the newest dump under `BACKUP_DIR` is stale
//!   beyond threshold. Skips when the dir is unset/empty (no false alarm on a
//!   deploy with backups disabled). The `segments` table is the sole mp4->time
//!   index, so a silently-stopped backup is a real durability risk.
//!
//! (All P0-HEALTH-NOTIFY system-alert event keys are now wired.)

use std::collections::HashMap;
use std::time::Duration;

use chrono::Utc;
use deadpool_postgres::Pool;
use uuid::Uuid;

use crumb_common::db;
use crumb_common::RecordingMode;

/// How often the watchdog checks the heartbeat.
const POLL_INTERVAL_SECS: u64 = 30;

/// Heartbeat age beyond which the recorder is considered down.
const STALE_THRESHOLD_SECS: i64 = 60;

/// Background task: watch the recorder heartbeat and POST to `webhook_url` on
/// stale → recovery transitions. Runs until the process exits. Never panics; a
/// failed DB read or webhook POST logs a WARN and the loop continues.
pub async fn run_heartbeat_watchdog(pool: Pool, webhook_url: String) {
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap_or_default();

    let mut alerted = false;
    let mut ticker = tokio::time::interval(Duration::from_secs(POLL_INTERVAL_SECS));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    tracing::info!(
        poll_secs = POLL_INTERVAL_SECS,
        stale_secs = STALE_THRESHOLD_SECS,
        "heartbeat watchdog started"
    );

    loop {
        ticker.tick().await;

        let hb = match db::read_recorder_heartbeat(&pool).await {
            Ok(h) => h,
            Err(e) => {
                tracing::warn!(error = %e, "heartbeat watchdog: DB read failed");
                continue;
            }
        };

        let now = chrono::Utc::now();
        let age = hb.as_ref().map(|h| (now - h.updated_at).num_seconds());
        let stale = age.is_none_or(|a| a > STALE_THRESHOLD_SECS);

        if stale && !alerted {
            let msg = match age {
                Some(a) => format!(
                    "🔴 Crumb recorder heartbeat STALE — last beat {a}s ago \
                     (threshold {STALE_THRESHOLD_SECS}s). Recording may be down."
                ),
                None => "🔴 Crumb recorder heartbeat MISSING — the recorder may not \
                         be running."
                    .to_owned(),
            };
            post(&http, &webhook_url, &msg).await;
            alerted = true;
        } else if !stale && alerted {
            let a = age.unwrap_or(0);
            post(
                &http,
                &webhook_url,
                &format!("🟢 Crumb recorder RECOVERED — heartbeat fresh ({a}s ago)."),
            )
            .await;
            alerted = false;
        }
    }
}

/// POST a message to the webhook with both `content` and `text` keys.
async fn post(http: &reqwest::Client, url: &str, message: &str) {
    let body = serde_json::json!({ "content": message, "text": message });
    match http.post(url).json(&body).send().await {
        Ok(resp) if resp.status().is_success() => {
            tracing::info!("heartbeat alert delivered to webhook");
        }
        Ok(resp) => {
            tracing::warn!(status = %resp.status(), "heartbeat alert webhook returned non-2xx");
        }
        Err(e) => tracing::warn!(error = %e, "heartbeat alert webhook POST failed"),
    }
}

// ─── system-alerts pipeline (P0-HEALTH-NOTIFY) ────────────────────────────────

/// How often the system-health watchdogs re-check their state.
///
/// Deliberately much coarser than the notification engine's 3 s event poll —
/// these are minute-scale health signals, not motion events, and the checks
/// below (recorder heartbeat read, N camera segment lookups, N storage statvfs
/// calls, N policy byte sums) are cheap but not free-to-run every 3 s forever.
const HEALTH_POLL_SECS: u64 = 20;

/// Default recorder-heartbeat staleness threshold (seconds) used when the
/// `recorder_offline` rule's `threshold_secs` is unset. Matches
/// [`STALE_THRESHOLD_SECS`] so the two paths agree by default.
const DEFAULT_RECORDER_OFFLINE_SECS: i64 = 60;

/// Default per-camera "no new segment" staleness threshold (seconds) used
/// when the `camera_offline` rule's `threshold_secs` is unset.
const DEFAULT_CAMERA_OFFLINE_SECS: i64 = 120;

/// Default recorder-startup grace (seconds) for the `camera_offline` watchdog
/// (issue #46). After the recorder (re)starts, every camera legitimately has NO
/// new segment while go2rtc reconciles and the streams reconnect — a window
/// that can approach [`DEFAULT_CAMERA_OFFLINE_SECS`] and false-fire "camera
/// offline" on a perfectly normal restart. For `boot_grace` seconds after a
/// recorder boot is first observed, the watchdog holds its fire (it does NOT
/// clear a pre-existing outage latch). A genuinely-offline camera still alerts
/// once the grace elapses. Override with `CAMERA_OFFLINE_BOOT_GRACE_SECS`.
const DEFAULT_CAMERA_OFFLINE_BOOT_GRACE_SECS: i64 = 180;

/// Resolve the recorder-startup grace, honoring the
/// `CAMERA_OFFLINE_BOOT_GRACE_SECS` env override (clamped `>= 0`; a malformed
/// value falls back to the default). Read once per watchdog start.
fn camera_offline_boot_grace_secs() -> i64 {
    std::env::var("CAMERA_OFFLINE_BOOT_GRACE_SECS")
        .ok()
        .and_then(|v| v.trim().parse::<i64>().ok())
        .map_or(DEFAULT_CAMERA_OFFLINE_BOOT_GRACE_SECS, |v| v.max(0))
}

/// Default low-disk free-space fraction floor used when the `low_disk` rule's
/// `threshold_fraction` is unset.
const DEFAULT_LOW_DISK_FRACTION: f32 = 0.05;

/// Default Frigate-connectivity staleness threshold (seconds) used when the
/// `frigate_disconnected` rule's `threshold_secs` is unset. The provider stamps
/// its heartbeat on the MQTT keep-alive (~30s), so this comfortably exceeds a
/// couple of keep-alive intervals to avoid false positives on a live link.
const DEFAULT_FRIGATE_OFFLINE_SECS: i64 = 120;

/// Default DB-backup staleness threshold (seconds) used when the `backup_failed`
/// rule's `threshold_secs` is unset. ~25h, so the built-in daily backup job
/// (`db_backup.rs`) has generous slack before its newest dump is called stale.
const DEFAULT_BACKUP_STALE_SECS: i64 = 90_000;

/// Background task: the always-on system/health watchdog loop feeding
/// `system_events` (consumed by the notification engine in `notifications.rs`).
/// Unlike [`run_heartbeat_watchdog`] this requires no env var — it is always
/// spawned; each individual check is gated by its own `system_alert_rules`
/// row (`enabled` flag), so an admin who wants none of this can disable every
/// row and the loop becomes a cheap no-op poll.
///
/// State-transition latches (`recorder_was_stale`, `camera_was_offline`) live
/// in-memory for the life of the process, mirroring [`run_heartbeat_watchdog`]:
/// exactly one `system_events` row is written per stale→OK transition (plus a
/// recovery row), not one per poll tick. On restart the latch resets, so a
/// condition that was already stale before restart fires again once — an
/// acceptable trade-off (never silently missing a still-ongoing outage) over
/// persisting watchdog latch state.
pub async fn run_system_health_watchdogs(pool: Pool) {
    let mut recorder_was_stale = false;
    // Per-camera "currently considered offline" latch.
    let mut camera_was_offline: HashMap<Uuid, bool> = HashMap::new();
    // "Frigate currently considered disconnected" latch.
    let mut frigate_was_disconnected = false;
    // "DB backup currently considered stale" latch.
    let mut backup_was_stale = false;

    // Recorder-startup grace tracking (issue #46). `recorder_boot_at` is the
    // Instant we last observed the recorder (re)start; the API watchdog's own
    // start seeds it, so an API restart also gets a grace window (we can't tell
    // from here whether the recorder is also fresh). A change in the heartbeat
    // `pid` (recorder process replaced) resets it. `last_recorder_pid` remembers
    // the last pid we saw so we can detect that change.
    let boot_grace_secs = camera_offline_boot_grace_secs();
    let mut recorder_boot_at = tokio::time::Instant::now();
    let mut last_recorder_pid: Option<i32> = None;

    let mut ticker = tokio::time::interval(Duration::from_secs(HEALTH_POLL_SECS));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    tracing::info!(
        poll_secs = HEALTH_POLL_SECS,
        camera_offline_boot_grace_secs = boot_grace_secs,
        "system-health watchdogs started"
    );

    loop {
        ticker.tick().await;

        // Observe recorder boot: a fresh heartbeat pid (recorder process id
        // changed) means the recorder restarted — reset the grace window so the
        // camera-offline watchdog tolerates the reconnect gap. `None` pid (no
        // heartbeat row yet) leaves the seed value in place.
        match db::read_recorder_heartbeat(&pool).await {
            Ok(Some(hb)) => {
                if let Some(pid) = hb.pid {
                    if last_recorder_pid != Some(pid) {
                        if last_recorder_pid.is_some() {
                            // A real pid change (not the first observation) =
                            // recorder restart → re-arm the grace.
                            recorder_boot_at = tokio::time::Instant::now();
                            tracing::info!(
                                pid,
                                "system-health: recorder restart observed (pid changed) — camera-offline grace re-armed"
                            );
                        }
                        last_recorder_pid = Some(pid);
                    }
                }
            }
            Ok(None) => {}
            Err(e) => {
                tracing::warn!(error = %e, "system-health: read_recorder_heartbeat (boot tracking) failed");
            }
        }
        #[allow(clippy::cast_possible_wrap)]
        let secs_since_recorder_boot = recorder_boot_at.elapsed().as_secs() as i64;

        // Load all rules once per tick (7 rows — negligible).
        let rules = match db::list_system_alert_rules(&pool).await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(error = %e, "system-health watchdogs: list_system_alert_rules failed");
                continue;
            }
        };
        let rule_map: HashMap<&str, &db::SystemAlertRule> =
            rules.iter().map(|r| (r.event_key.as_str(), r)).collect();

        check_recorder_offline(
            &pool,
            rule_map.get("recorder_offline").copied(),
            &mut recorder_was_stale,
        )
        .await;
        check_camera_offline(
            &pool,
            rule_map.get("camera_offline").copied(),
            &mut camera_was_offline,
            secs_since_recorder_boot,
            boot_grace_secs,
        )
        .await;
        check_low_disk(&pool, rule_map.get("low_disk").copied()).await;
        check_policy_over_cap(&pool, rule_map.get("policy_over_cap").copied()).await;
        check_frigate_disconnected(
            &pool,
            rule_map.get("frigate_disconnected").copied(),
            &mut frigate_was_disconnected,
        )
        .await;
        check_backup_failed(
            &pool,
            rule_map.get("backup_failed").copied(),
            &mut backup_was_stale,
        )
        .await;
    }
}

/// `recorder_offline` — mirrors [`run_heartbeat_watchdog`]'s staleness check
/// but writes to `system_events` (the configurable pipeline) instead of a
/// single hardcoded webhook.
async fn check_recorder_offline(
    pool: &Pool,
    rule: Option<&db::SystemAlertRule>,
    was_stale: &mut bool,
) {
    let Some(rule) = rule else { return };
    if !rule.enabled {
        *was_stale = false; // don't fire a stale transition report while disabled
        return;
    }
    let threshold = i64::from(
        rule.threshold_secs
            .unwrap_or(DEFAULT_RECORDER_OFFLINE_SECS as i32),
    );

    let hb = match db::read_recorder_heartbeat(pool).await {
        Ok(h) => h,
        Err(e) => {
            tracing::warn!(error = %e, "system-health: read_recorder_heartbeat failed");
            return;
        }
    };
    let now = Utc::now();
    let age = hb.as_ref().map(|h| (now - h.updated_at).num_seconds());
    let stale = age.is_none_or(|a| a > threshold);

    if stale && !*was_stale {
        let detail = match age {
            Some(a) => {
                format!("recorder heartbeat stale — last beat {a}s ago (threshold {threshold}s)")
            }
            None => "recorder heartbeat missing — the recorder may not be running".to_owned(),
        };
        if let Err(e) = db::insert_system_event(pool, "recorder_offline", None, Some(&detail)).await
        {
            tracing::warn!(error = %e, "system-health: insert_system_event(recorder_offline) failed");
        } else {
            *was_stale = true;
        }
    } else if !stale && *was_stale {
        *was_stale = false;
        // No explicit "recovered" event key exists yet (v1 scope: alert on the
        // problem, not the all-clear) — the next `recorder_offline` occurrence
        // will simply fire again from a fresh transition.
    }
}

/// Outcome of the Frigate-connectivity check. Kept as a pure, DB-free decision
/// (see [`frigate_transition`]) so it can be unit-tested exhaustively.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FrigateTransition {
    /// Was healthy, now stale beyond threshold — emit `frigate_disconnected`.
    Fire,
    /// Fresh again (or never-connected) while latched disconnected — clear the latch.
    Clear,
    /// No state change this tick.
    NoChange,
}

/// Decide the Frigate-connectivity transition purely from the heartbeat age.
///
/// `last_seen == None` means Frigate has NEVER connected (or isn't configured) —
/// that is NOT an outage, so it never fires; it only clears a stale latch (e.g.
/// Frigate was disabled while flagged disconnected).
fn frigate_transition(
    last_seen: Option<chrono::DateTime<Utc>>,
    now: chrono::DateTime<Utc>,
    threshold_secs: i64,
    was_disconnected: bool,
) -> FrigateTransition {
    let Some(ts) = last_seen else {
        return if was_disconnected {
            FrigateTransition::Clear
        } else {
            FrigateTransition::NoChange
        };
    };
    let stale = (now - ts).num_seconds() > threshold_secs;
    match (stale, was_disconnected) {
        (true, false) => FrigateTransition::Fire,
        (false, true) => FrigateTransition::Clear,
        _ => FrigateTransition::NoChange,
    }
}

/// `frigate_disconnected` — the API's Frigate provider stamps `frigate_heartbeat`
/// on every successful MQTT packet (`ConnAck` / keep-alive / event). When that
/// goes stale beyond threshold the Frigate integration has dropped: no detection
/// events are landing on the timeline even though the recorder itself is fine.
/// Fires once per disconnect episode (latched), mirroring
/// [`check_recorder_offline`]. Skips entirely when Frigate has never connected
/// (no heartbeat row), so a deployment that doesn't use Frigate never alerts.
async fn check_frigate_disconnected(
    pool: &Pool,
    rule: Option<&db::SystemAlertRule>,
    was_disconnected: &mut bool,
) {
    let Some(rule) = rule else { return };
    if !rule.enabled {
        *was_disconnected = false; // don't fire a transition report while disabled
        return;
    }
    let threshold = i64::from(
        rule.threshold_secs
            .unwrap_or(DEFAULT_FRIGATE_OFFLINE_SECS as i32),
    );

    let last_seen = match db::read_frigate_heartbeat(pool).await {
        Ok(h) => h,
        Err(e) => {
            tracing::warn!(error = %e, "system-health: read_frigate_heartbeat failed");
            return;
        }
    };

    match frigate_transition(last_seen, Utc::now(), threshold, *was_disconnected) {
        FrigateTransition::Fire => {
            let age = last_seen
                .map(|t| (Utc::now() - t).num_seconds())
                .unwrap_or_default();
            let detail = format!(
                "Frigate MQTT connectivity lost — no heartbeat for {age}s (threshold \
                 {threshold}s); detection events are not being ingested"
            );
            if let Err(e) =
                db::insert_system_event(pool, "frigate_disconnected", None, Some(&detail)).await
            {
                tracing::warn!(error = %e, "system-health: insert_system_event(frigate_disconnected) failed");
            } else {
                *was_disconnected = true;
            }
        }
        FrigateTransition::Clear => *was_disconnected = false,
        FrigateTransition::NoChange => {}
    }
}

/// Pure staleness decision for the newest DB dump's age. `None` age = no dumps
/// found (fresh install where the first scheduled dump hasn't run yet, or the
/// backup job is disabled) → NOT stale, so no false alarm. Testable.
fn backup_is_stale(newest_age_secs: Option<i64>, threshold_secs: i64) -> bool {
    newest_age_secs.is_some_and(|a| a > threshold_secs)
}

/// Age (seconds) of the newest `*.sql` / `*.sql.gz` dump under `dir` (recursed),
/// or `None` when the dir is missing/unreadable or holds no dumps. Best-effort:
/// unreadable entries are skipped, not errored.
fn newest_backup_age_secs(dir: &str) -> Option<i64> {
    fn walk(dir: &std::path::Path, best: &mut Option<std::time::SystemTime>) {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in rd.flatten() {
            let path = entry.path();
            let Ok(ft) = entry.file_type() else { continue };
            if ft.is_dir() {
                walk(&path, best);
            } else if path.extension().is_some_and(|e| e == "gz" || e == "sql") {
                if let Ok(m) = entry.metadata().and_then(|md| md.modified()) {
                    if best.is_none_or(|b| m > b) {
                        *best = Some(m);
                    }
                }
            }
        }
    }
    let mut best = None;
    walk(std::path::Path::new(dir), &mut best);
    best.map(|t| {
        std::time::SystemTime::now()
            .duration_since(t)
            .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
    })
}

/// `backup_failed` (staleness backstop) — reads the newest DB dump's age from
/// the mounted `BACKUP_DIR` (where the API's built-in backup job, `db_backup.rs`,
/// writes) and fires when it exceeds threshold, i.e. dumps have silently
/// stopped appearing. The backup job also reports its own failures directly;
/// this check additionally catches "the job never ran at all" (crash-looping
/// api, wedged task). The `segments` table is the SOLE mp4→time index, so a
/// stale backup is a real data-durability risk (see the footage-reliability
/// audit). Skips when `BACKUP_DIR` is unset or holds no dumps yet — no false
/// alarm on a fresh install or a deploy with backups disabled. Latched: one
/// alert per stale episode, mirroring [`check_recorder_offline`].
async fn check_backup_failed(
    pool: &Pool,
    rule: Option<&db::SystemAlertRule>,
    was_stale: &mut bool,
) {
    let Some(rule) = rule else { return };
    if !rule.enabled {
        *was_stale = false;
        return;
    }
    let Some(dir) = std::env::var("BACKUP_DIR")
        .ok()
        .filter(|d| !d.trim().is_empty())
    else {
        return; // backups not wired into the api — nothing to check
    };
    let threshold = i64::from(
        rule.threshold_secs
            .unwrap_or(DEFAULT_BACKUP_STALE_SECS as i32),
    );
    let age = newest_backup_age_secs(&dir);
    let stale = backup_is_stale(age, threshold);

    if stale && !*was_stale {
        let a = age.unwrap_or_default();
        let detail = format!(
            "database backup is stale — newest dump is {a}s old (threshold {threshold}s). \
             The segments table is the only mp4->time index, so a failed backup risks \
             un-seekable footage after a disk loss."
        );
        if let Err(e) = db::insert_system_event(pool, "backup_failed", None, Some(&detail)).await {
            tracing::warn!(error = %e, "system-health: insert_system_event(backup_failed) failed");
        } else {
            *was_stale = true;
        }
    } else if !stale && *was_stale {
        *was_stale = false;
    }
}

/// Pure decision for the recorder-startup grace (issue #46): should the
/// `camera_offline` watchdog HOLD its fire because the recorder booted too
/// recently for a missing segment to be meaningful?
///
/// `secs_since_boot` is how long ago the current recorder boot was observed
/// (the API's own watchdog start counts as a boot, since on an API restart we
/// can't know the recorder isn't also fresh). Returns `true` while still inside
/// the grace window, i.e. the alert should be suppressed. Only suppresses NEW
/// offline transitions — an already-latched outage is untouched (handled at the
/// call site) so a real outage that predates the boot still reports.
fn within_boot_grace(secs_since_boot: i64, grace_secs: i64) -> bool {
    secs_since_boot < grace_secs
}

/// Pure decision: given the age (seconds) of whichever liveness signal
/// applies — segment age for Continuous, `camera_motion_cache_status.updated_at`
/// age for idle Motion — is the camera offline? `None` (no row/segment at all)
/// is treated as offline (a camera that has never reported anything is not
/// "alive and idle"). Shared by both signals in [`check_camera_offline`] so the
/// >, not >=, boundary and the "absence = offline" rule can't drift between them.
fn offline_from_age(age_secs: Option<i64>, threshold_secs: i64) -> bool {
    age_secs.is_none_or(|a| a > threshold_secs)
}

/// `camera_offline` — for every enabled camera, checks a liveness signal and
/// fires once per camera per offline→online cycle when it exceeds the
/// configured threshold.
///
/// **Motion-aware** (was purely segment-age-based; see docs/MOTION-RECORDING.md
/// for the RAM-cache design that made the old check false-fire). Crumb has two
/// recording modes with very different "no new segment" semantics:
///
/// - **Continuous-mode** cameras (and Motion-mode cameras running under
///   `MOTION_RECORDING_SHADOW`, which persists every segment just like
///   Continuous — see the "shadow mode" paragraph below) write a segment
///   continuously, so [`db::camera_last_segment`] going stale IS the outage
///   signal. Unchanged from before: camera unreachable, sub-stream stalled and
///   reconnecting, disk full upstream of this check, etc. all show up the same
///   way — "no new segment" — which is the actual footage-loss-relevant fact.
/// - **Motion-mode** cameras legitimately write NO segment while idle (footage
///   buffers in a RAM ring and is discarded unless motion is detected — see
///   `services/recorder/src/recording.rs` `MotionBuffer`), so segment age alone
///   cannot distinguish "quiet" from "dead". Instead this uses the freshness of
///   that camera's `camera_motion_cache_status` row
///   (`db::camera_motion_cache_status_updated_at`), which the recorder upserts
///   on a ~45 s tick (`MOTION_CACHE_STATUS_INTERVAL_SECS`) for every Motion-mode
///   camera *regardless of whether it's currently caching anything* — a fresh
///   row means the recorder's worker for that camera is alive and idle (not
///   offline); a stale/absent row means the worker died, which is a genuine
///   outage. A truly-offline Motion camera's sub-stream also dies, which
///   independently fires `motion_detector_unhealthy`
///   (`services/recorder/src/motion.rs`) — this check does not rely on that
///   alone, but it means a Motion camera's outage is covered from two angles.
///
/// Effective mode is read straight off `cam.policy.mode`, already resolved
/// own→group→default by the `v_camera_effective_policy` view
/// (see `CAMERA_SELECT_SQL` in `services/common/src/db.rs`) — group-inherited
/// Motion cameras are handled correctly, not just directly-assigned ones.
///
/// Known gap (documented, not fixed here): the API has no visibility into
/// *per-camera* shadow mode — `motion_cache_status.shadow_mode` is a single
/// global flag (`MOTION_RECORDING_SHADOW` is a recorder-wide env var, not a
/// per-camera setting), so when shadow mode is on, ALL Motion cameras are
/// persisting every segment like Continuous — this check reads that flag and
/// falls back to the segment-based liveness for every Motion camera while it's
/// set, so shadow-mode cameras are never wrongly treated as "idle-motion" when
/// they are in fact behaving like Continuous.
///
/// Edge case worth flagging: on a non-shadow Motion camera, if the MAIN stream
/// dies but the SUB stream (motion analysis) stays up, the cache-status
/// heartbeat keeps ticking (it doesn't touch the main stream) — `camera_offline`
/// would not fire even though nothing is being recorded. `motion_detector_unhealthy`
/// only fires when the motion detector itself unhealthy, which is a different
/// failure. This is a real coverage gap but narrower than the false-positive
/// storm being fixed, and no clean single signal covers it without also
/// reintroducing false alarms on the common idle-camera case.
///
/// Recorder-startup grace (issue #46): `secs_since_recorder_boot` is how long
/// ago the current recorder boot (or the API watchdog's own start) was
/// observed. While that is under `boot_grace_secs`, a NEW camera-offline
/// transition is held — the transient reconnect gap after a (re)start is not a
/// real outage. A camera that stays silent past the grace still fires. This
/// applies identically to both liveness signals.
async fn check_camera_offline(
    pool: &Pool,
    rule: Option<&db::SystemAlertRule>,
    was_offline: &mut HashMap<Uuid, bool>,
    secs_since_recorder_boot: i64,
    boot_grace_secs: i64,
) {
    let Some(rule) = rule else { return };
    if !rule.enabled {
        was_offline.clear();
        return;
    }
    let threshold = i64::from(
        rule.threshold_secs
            .unwrap_or(DEFAULT_CAMERA_OFFLINE_SECS as i32),
    );
    let in_boot_grace = within_boot_grace(secs_since_recorder_boot, boot_grace_secs);

    let cameras = match db::list_enabled_cameras(pool).await {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(error = %e, "system-health: list_enabled_cameras failed");
            return;
        }
    };

    // Global shadow-mode flag: while on, every Motion camera behaves like
    // Continuous (persists every segment), so it must use the segment-based
    // signal too (see the doc comment's "shadow mode" gap above). Best-effort:
    // a read failure just means we treat shadow mode as off (Motion cameras use
    // the cache-status heartbeat) — same fallback as an unconfigured or
    // never-reported global row.
    let shadow_mode = match db::read_motion_cache_status(pool).await {
        Ok(status) => status.is_some_and(|s| s.shadow_mode),
        Err(e) => {
            tracing::warn!(error = %e, "system-health: read_motion_cache_status failed");
            false
        }
    };

    let now = Utc::now();
    for cam in &cameras {
        let use_cache_heartbeat = cam.policy.mode == RecordingMode::Motion && !shadow_mode;

        // `signal` names which liveness check produced `age`, purely for the
        // alert detail message — the offline/online decision itself is the
        // same `offline_from_age` regardless of which column fed it.
        let (age, signal) = if use_cache_heartbeat {
            let cache_updated_at =
                match db::camera_motion_cache_status_updated_at(pool, cam.id).await {
                    Ok(ts) => ts,
                    Err(e) => {
                        tracing::warn!(
                            error = %e,
                            camera_id = %cam.id,
                            "system-health: camera_motion_cache_status_updated_at failed"
                        );
                        continue;
                    }
                };
            (
                cache_updated_at.map(|ts| (now - ts).num_seconds()),
                "motion-cache heartbeat",
            )
        } else {
            let last = match db::camera_last_segment(pool, cam.id).await {
                Ok(l) => l,
                Err(e) => {
                    tracing::warn!(error = %e, camera_id = %cam.id, "system-health: camera_last_segment failed");
                    continue;
                }
            };
            (
                last.as_ref().map(|s| (now - s.start_ts).num_seconds()),
                "segment",
            )
        };
        let offline = offline_from_age(age, threshold);
        let was = was_offline.get(&cam.id).copied().unwrap_or(false);

        // Recorder-startup grace (issue #46): during the post-boot reconnect
        // window, hold a NEW offline transition — the missing segment is the
        // expected go2rtc-reconcile gap, not an outage. We do NOT latch
        // `was_offline` here, so the very next tick after the grace elapses
        // re-evaluates and fires if the camera is genuinely still silent. An
        // already-latched outage (`was == true`) is untouched by the grace.
        if offline && !was && in_boot_grace {
            tracing::debug!(
                camera_id = %cam.id,
                secs_since_recorder_boot,
                boot_grace_secs,
                "system-health: camera_offline suppressed inside recorder-startup grace"
            );
            continue;
        }

        if offline && !was {
            let detail = match age {
                Some(a) => format!(
                    "camera \"{}\" has no fresh {signal} for {a}s (threshold {threshold}s)",
                    cam.name
                ),
                None => format!("camera \"{}\" has never reported a {signal}", cam.name),
            };
            if let Err(e) =
                db::insert_system_event(pool, "camera_offline", Some(cam.id), Some(&detail)).await
            {
                tracing::warn!(error = %e, camera_id = %cam.id, "system-health: insert_system_event(camera_offline) failed");
            } else {
                was_offline.insert(cam.id, true);
            }
        } else if !offline && was {
            was_offline.insert(cam.id, false);
        }
    }

    // Drop latches for cameras that no longer exist/are disabled so the map
    // can't grow unboundedly across camera churn.
    let live_ids: std::collections::HashSet<Uuid> = cameras.iter().map(|c| c.id).collect();
    was_offline.retain(|id, _| live_ids.contains(id));
}

/// `low_disk` — any storage's free-space fraction below the configured floor.
///
/// Best-effort / "cleanly fits" extra (see module docs): unlike
/// `recorder_offline`/`camera_offline` this has no in-memory latch, so it
/// re-fires every tick while the condition persists — the engine's own
/// per-`(event_key, camera_id)` cooldown (from `system_alert_rules.cooldown_secs`)
/// is what prevents spam, not a local transition latch. Acceptable because
/// low-disk is inherently a level-triggered condition an admin wants
/// reminded of periodically, not a one-shot edge.
async fn check_low_disk(pool: &Pool, rule: Option<&db::SystemAlertRule>) {
    let Some(rule) = rule else { return };
    if !rule.enabled {
        return;
    }
    let floor = rule
        .threshold_fraction
        .unwrap_or(DEFAULT_LOW_DISK_FRACTION)
        .clamp(0.0, 1.0);

    let storages = match db::list_storages(pool).await {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(error = %e, "system-health: list_storages failed");
            return;
        }
    };

    for storage in &storages {
        let Some((total, free)) = storage_statvfs(&storage.path) else {
            continue; // unreadable path this tick — skip, don't alert on a read failure
        };
        if total <= 0 {
            continue;
        }
        #[allow(clippy::cast_precision_loss)]
        let free_frac = free as f64 / total as f64;
        if free_frac < f64::from(floor) {
            let detail = format!(
                "storage \"{}\" ({}) has {:.1}% free (floor {:.1}%)",
                storage.name,
                storage.path,
                free_frac * 100.0,
                f64::from(floor) * 100.0
            );
            if let Err(e) = db::insert_system_event(pool, "low_disk", None, Some(&detail)).await {
                tracing::warn!(error = %e, storage = %storage.name, "system-health: insert_system_event(low_disk) failed");
            }
        }
    }
}

/// `policy_over_cap` — any recording policy currently at/over its configured
/// live or archive byte cap.
///
/// Best-effort / "cleanly fits" extra: this is intentionally an ADVISORY
/// signal, distinct from `premature_rollover`. Being over cap is expected to
/// self-correct within a tick or two once the recorder's size-eviction sweep
/// runs (see `services/recorder/src/archive.rs::policy_size_eviction_sweep`) —
/// it is not itself footage loss. It fires (subject to the engine's cooldown)
/// so an admin notices a policy that is chronically over cap (undersized
/// budget for its camera set) even though the recorder is handling it
/// gracefully.
async fn check_policy_over_cap(pool: &Pool, rule: Option<&db::SystemAlertRule>) {
    let Some(rule) = rule else { return };
    if !rule.enabled {
        return;
    }

    let policies = match db::list_policies(pool).await {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(error = %e, "system-health: list_policies failed");
            return;
        }
    };

    for policy in &policies {
        let label = policy.name.as_deref().unwrap_or("<unnamed>");

        if let Some(cap) = policy.live_max_bytes.filter(|c| *c > 0) {
            match db::policy_stage_bytes(pool, policy.id, crumb_common::SegmentStage::Live).await {
                Ok(used) if used > cap => {
                    let detail = format!(
                        "policy \"{label}\" live footage {used} bytes over cap {cap} bytes"
                    );
                    if let Err(e) =
                        db::insert_system_event(pool, "policy_over_cap", None, Some(&detail)).await
                    {
                        tracing::warn!(error = %e, policy_id = %policy.id, "system-health: insert_system_event(policy_over_cap/live) failed");
                    }
                }
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!(error = %e, policy_id = %policy.id, "system-health: policy_stage_bytes(live) failed");
                }
            }
        }

        if policy.archive_enabled {
            if let Some(cap) = policy.archive_max_bytes.filter(|c| *c > 0) {
                match db::policy_stage_bytes(pool, policy.id, crumb_common::SegmentStage::Archive)
                    .await
                {
                    Ok(used) if used > cap => {
                        let detail = format!(
                            "policy \"{label}\" archive footage {used} bytes over cap {cap} bytes"
                        );
                        if let Err(e) =
                            db::insert_system_event(pool, "policy_over_cap", None, Some(&detail))
                                .await
                        {
                            tracing::warn!(error = %e, policy_id = %policy.id, "system-health: insert_system_event(policy_over_cap/archive) failed");
                        }
                    }
                    Ok(_) => {}
                    Err(e) => {
                        tracing::warn!(error = %e, policy_id = %policy.id, "system-health: policy_stage_bytes(archive) failed");
                    }
                }
            }
        }
    }
}

/// Query `(total_bytes, free_bytes)` for the filesystem containing `path` via
/// `statvfs(2)`. Returns `None` when the path is inaccessible or on non-Unix
/// build targets (dev compilation on Windows).
///
/// Mirrors the identical helper in `status.rs`/`stats.rs`/`config_routes.rs`;
/// kept local (per that existing convention in this codebase) so this module
/// doesn't need to expose a private function from another module.
fn storage_statvfs(path: &str) -> Option<(i64, i64)> {
    #[cfg(unix)]
    {
        use std::ffi::CString;
        let c_path = CString::new(path.as_bytes()).ok()?;
        // SAFETY: `c_path` is a valid NUL-terminated string; `buf` is a
        // zero-initialised local whose address we pass to the well-documented
        // POSIX `statvfs(3)` syscall.
        let mut buf = unsafe { std::mem::zeroed::<libc::statvfs>() };
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &raw mut buf) };
        if rc != 0 {
            return None;
        }
        #[allow(clippy::cast_lossless)]
        let bsize = buf.f_bsize as u64;
        #[allow(clippy::cast_lossless)]
        let total = (buf.f_blocks as u64).saturating_mul(bsize);
        #[allow(clippy::cast_lossless)]
        let free = (buf.f_bfree as u64).saturating_mul(bsize);
        Some((
            i64::try_from(total).unwrap_or(i64::MAX),
            i64::try_from(free).unwrap_or(i64::MAX),
        ))
    }

    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A heartbeat `secs_ago` seconds before `now`. `Option` is the shape
    /// [`frigate_transition`] takes, so the wrap is intentional.
    #[allow(clippy::unnecessary_wraps)]
    fn ts(secs_ago: i64, now: chrono::DateTime<Utc>) -> Option<chrono::DateTime<Utc>> {
        Some(now - chrono::Duration::seconds(secs_ago))
    }

    #[test]
    fn frigate_never_connected_never_fires() {
        let now = Utc::now();
        // No heartbeat row = Frigate never connected / not configured -> not an outage.
        assert_eq!(
            frigate_transition(None, now, 120, false),
            FrigateTransition::NoChange
        );
        // ...but a stale latch is cleared (e.g. Frigate disabled while flagged).
        assert_eq!(
            frigate_transition(None, now, 120, true),
            FrigateTransition::Clear
        );
    }

    #[test]
    fn frigate_fresh_heartbeat_is_ok() {
        let now = Utc::now();
        assert_eq!(
            frigate_transition(ts(30, now), now, 120, false),
            FrigateTransition::NoChange
        );
        // Fresh again after being latched disconnected -> recover (clear latch).
        assert_eq!(
            frigate_transition(ts(30, now), now, 120, true),
            FrigateTransition::Clear
        );
    }

    #[test]
    fn frigate_stale_heartbeat_fires_once() {
        let now = Utc::now();
        // Stale + not yet latched -> fire.
        assert_eq!(
            frigate_transition(ts(200, now), now, 120, false),
            FrigateTransition::Fire
        );
        // Already latched -> no repeat (one alert per disconnect episode).
        assert_eq!(
            frigate_transition(ts(200, now), now, 120, true),
            FrigateTransition::NoChange
        );
    }

    #[test]
    fn frigate_threshold_is_strict() {
        let now = Utc::now();
        // Exactly at threshold is NOT stale (strict >).
        assert_eq!(
            frigate_transition(ts(120, now), now, 120, false),
            FrigateTransition::NoChange
        );
        // One second past -> stale -> fire.
        assert_eq!(
            frigate_transition(ts(121, now), now, 120, false),
            FrigateTransition::Fire
        );
    }

    #[test]
    fn backup_stale_decision() {
        assert!(
            !backup_is_stale(None, 90_000),
            "no dumps found -> not stale (no false alarm on fresh install)"
        );
        assert!(
            !backup_is_stale(Some(1_000), 90_000),
            "fresh dump -> not stale"
        );
        assert!(
            !backup_is_stale(Some(90_000), 90_000),
            "exactly at threshold -> not stale (strict >)"
        );
        assert!(
            backup_is_stale(Some(90_001), 90_000),
            "past threshold -> stale"
        );
    }

    #[test]
    fn newest_backup_age_missing_dir_is_none() {
        assert!(
            newest_backup_age_secs("/nonexistent/crumb/backup/dir/xyz").is_none(),
            "a missing backup dir must yield None (check skips), not a spurious age"
        );
    }

    // ── Guard 2: recorder-startup grace (issue #46) ───────────────────────────

    #[test]
    fn boot_grace_suppresses_inside_window() {
        // 10s since boot, 180s grace → still in grace → suppress the transition.
        assert!(within_boot_grace(10, 180));
        assert!(within_boot_grace(0, 180));
        assert!(
            within_boot_grace(179, 180),
            "one second before the grace ends is still grace"
        );
    }

    #[test]
    fn boot_grace_lets_real_outage_through_after_window() {
        // At/after the grace boundary, a genuinely-silent camera must alert.
        assert!(
            !within_boot_grace(180, 180),
            "exactly at the grace boundary the grace is over (strict <)"
        );
        assert!(!within_boot_grace(600, 180));
    }

    #[test]
    fn boot_grace_zero_disables_suppression() {
        // grace_secs == 0 (env override) → never suppress; every offline fires.
        assert!(!within_boot_grace(0, 0));
        assert!(!within_boot_grace(5, 0));
    }

    // ── Motion-aware camera_offline: offline_from_age ─────────────────────────
    //
    // Shared by both liveness signals (segment age for Continuous, motion-cache
    // heartbeat age for idle Motion) — one boundary rule for both.

    #[test]
    fn offline_from_age_no_signal_is_offline() {
        // No segment / no cache-status row at all -> offline (never proven alive).
        assert!(offline_from_age(None, 120));
    }

    #[test]
    fn offline_from_age_fresh_is_online() {
        assert!(!offline_from_age(Some(0), 120));
        assert!(!offline_from_age(Some(119), 120));
    }

    #[test]
    fn offline_from_age_threshold_is_strict() {
        // Exactly at threshold is NOT yet offline (strict >), matching the
        // frigate/backup checks' boundary convention elsewhere in this file.
        assert!(!offline_from_age(Some(120), 120));
        assert!(offline_from_age(Some(121), 120));
    }

    #[test]
    fn offline_from_age_idle_motion_camera_within_heartbeat_cadence_is_online() {
        // An idle Motion-mode camera with no motion for a long time is still
        // "alive" as long as its ~45s cache-status heartbeat keeps landing —
        // this is the false-alarm this feature fixes: age here reflects time
        // since the last heartbeat tick, not time since the last segment.
        assert!(!offline_from_age(Some(45), 120));
        assert!(!offline_from_age(Some(90), 120));
    }

    #[test]
    fn offline_from_age_dead_motion_worker_still_detected() {
        // If the recorder's worker for this camera dies, the heartbeat stops
        // landing entirely -> the row goes stale past threshold -> offline.
        assert!(offline_from_age(Some(300), 120));
    }
}
