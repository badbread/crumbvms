// SPDX-License-Identifier: AGPL-3.0-or-later

//! Frigate-as-motion-source (Stage 2 of the pluggable-motion design).
//!
//! Instead of analysing pixels, a camera can be *triggered for recording* by
//! Frigate's neural object detections. This module subscribes to the same
//! `frigate/events` MQTT topic the API's detection ingester consumes (Crumb is
//! simply another subscriber on the broker Frigate already publishes to) and
//! translates an object's lifecycle — `new`/`update` ⇒ present, `end` ⇒ gone —
//! into the very same [`MotionSignal`] start/stop pair the pixel pipeline emits.
//! `recording.rs` is unchanged: it cannot tell which source produced the signal.
//!
//! ## Architecture — per-camera, inside `motion::run`
//!
//! Each camera worker owns its motion task. A Frigate-source camera runs
//! [`run_frigate_motion_loop`] (this module) instead of the pixel-diff loop,
//! reusing `motion::run`'s existing back-off/cancel supervision verbatim. One
//! lightweight MQTT subscription per Frigate camera keeps the workers fully
//! independent (no shared singleton to coordinate with `sync_cameras`); at
//! homelab fleet sizes the extra connections + per-message filtering are
//! negligible. The translation/state-machine pieces ([`classify`],
//! [`CameraTracker`]) are pure and unit-tested; only the thin MQTT plumbing
//! needs a live broker.
//!
//! ## Selection (Stage 2 vs Stage 4)
//!
//! Which cameras use Frigate motion is chosen here by the `FRIGATE_MOTION_CAMERAS`
//! env allow-list ("all", or a comma list of go2rtc / camera names) so the
//! feature is deployable and verifiable now. Stage 4 replaces
//! [`camera_uses_frigate_motion`] with a per-camera `motion_source` DB column.

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use rumqttc::{AsyncClient, Event, MqttOptions, Packet, QoS};
use serde::Deserialize;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};
use uuid::Uuid;

use crumb_common::{types::Camera, MotionSignal};

use crate::MotionTx;

/// An object Frigate hasn't sent an `end` for in this long is assumed gone (a
/// dropped `end` message must not pin recording open forever). Frigate emits
/// `update`s every few seconds for a tracked object, so a 30 s silence is a safe
/// "it left" signal.
const OBJECT_TTL: chrono::Duration = chrono::Duration::seconds(30);

/// Once a camera has no active objects, wait this long before emitting STOP, so
/// one object ending and the next beginning a moment later don't fragment the
/// recording into two events. Mirrors the pixel pipeline's stop-hysteresis.
const STOP_GRACE: chrono::Duration = chrono::Duration::seconds(5);

/// How often the janitor checks for the STOP-grace expiry and stale objects.
const TICK: Duration = Duration::from_secs(1);

// ── configuration ───────────────────────────────────────────────────────────

/// Frigate MQTT connection settings (the recorder's own subset of the API's
/// `FrigateConfig`). Shares the same env var names so a single set of broker
/// credentials configures both services.
#[derive(Debug, Clone)]
pub struct FrigateMotionConfig {
    /// `FRIGATE_MQTT_URL` — e.g. `mqtt://192.0.2.10:1883`. Absence disables the
    /// whole feature (`from_env` returns `None`).
    pub mqtt_url: String,
    /// `FRIGATE_MQTT_PREFIX` — topic prefix, default `"frigate"`.
    pub mqtt_prefix: String,
    /// `FRIGATE_MQTT_USER` — optional broker username.
    pub mqtt_user: Option<String>,
    /// Broker password (`FRIGATE_MQTT_PASSWORD`, or `_B64` base64 to survive
    /// compose `$`-escaping).
    pub mqtt_password: Option<String>,
    /// `FRIGATE_MIN_SCORE` — confidence floor for an object to count, default 0.3.
    pub min_score: f32,
}

impl FrigateMotionConfig {
    /// Read config from the environment. `None` when `FRIGATE_MQTT_URL` is unset
    /// or empty — the normal "no Frigate" case, where no camera can be a Frigate
    /// motion source regardless of the allow-list.
    ///
    /// Superseded by [`from_settings`](Self::from_settings) (DB-backed, hot-
    /// reloadable); kept as the documented env-var contract the DB seeds from.
    #[allow(dead_code)]
    #[must_use]
    pub fn from_env() -> Option<Self> {
        let mqtt_url = std::env::var("FRIGATE_MQTT_URL")
            .ok()
            .filter(|v| !v.trim().is_empty())?;
        Some(Self {
            mqtt_url,
            mqtt_prefix: std::env::var("FRIGATE_MQTT_PREFIX")
                .unwrap_or_else(|_| "frigate".to_owned()),
            mqtt_user: std::env::var("FRIGATE_MQTT_USER")
                .ok()
                .filter(|v| !v.trim().is_empty()),
            mqtt_password: std::env::var("FRIGATE_MQTT_PASSWORD")
                .ok()
                .filter(|v| !v.is_empty())
                .or_else(|| {
                    use base64::Engine as _;
                    std::env::var("FRIGATE_MQTT_PASSWORD_B64")
                        .ok()
                        .and_then(|b| {
                            base64::engine::general_purpose::STANDARD
                                .decode(b.trim())
                                .ok()
                                .and_then(|bytes| String::from_utf8(bytes).ok())
                        })
                }),
            min_score: std::env::var("FRIGATE_MIN_SCORE")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(0.3_f32),
        })
    }

    /// Build from the DB-backed [`FrigateSettings`] (the hot-reloadable source of
    /// truth). `None` when the feature is disabled or the broker URL is empty —
    /// same "no Frigate" semantics as [`from_env`](Self::from_env).
    #[must_use]
    pub fn from_settings(s: &crumb_common::FrigateSettings) -> Option<Self> {
        if !s.enabled || s.mqtt_url.trim().is_empty() {
            return None;
        }
        Some(Self {
            mqtt_url: s.mqtt_url.clone(),
            mqtt_prefix: s.mqtt_prefix.clone(),
            mqtt_user: s.mqtt_user.clone(),
            mqtt_password: s.mqtt_password.clone(),
            min_score: s.min_score,
        })
    }
}

/// Whether `camera` should be driven by Frigate motion rather than pixel-diff.
///
/// Authoritative source is the per-camera `motion_source` column
/// (`"frigate"`); the `FRIGATE_MOTION_CAMERAS` env allow-list (`"all"`, or a
/// comma list matched against the camera's `go2rtc_name` / display `name`)
/// remains as a global override for fleet-wide testing and pre-column rollout.
/// Either being set selects Frigate motion.
#[must_use]
pub fn camera_uses_frigate_motion(camera: &Camera) -> bool {
    if camera.motion_source.eq_ignore_ascii_case("frigate") {
        return true;
    }
    let Ok(list) = std::env::var("FRIGATE_MOTION_CAMERAS") else {
        return false;
    };
    let list = list.trim();
    if list.is_empty() {
        return false;
    }
    if list.eq_ignore_ascii_case("all") {
        return true;
    }
    list.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .any(|name| name == camera.go2rtc_name || name == camera.name)
}

// ── pure event classification ─────────────────────────────────────────────────

/// A motion-relevant view of one Frigate MQTT event: which object on which
/// camera, and whether it just appeared/updated (`ended == false`) or left
/// (`ended == true`). All the recorder needs from Frigate — labels, snapshots,
/// zones are the API ingester's concern.
#[derive(Debug, Clone, PartialEq)]
pub struct ObjEvent {
    pub camera: String,
    pub object_id: String,
    pub ended: bool,
    pub score: f32,
}

/// Minimal Frigate envelope — only the fields motion cares about.
#[derive(Debug, Deserialize)]
struct Envelope {
    #[serde(rename = "type")]
    event_type: String,
    after: After,
}

#[derive(Debug, Deserialize)]
struct After {
    id: String,
    camera: String,
    score: Option<f32>,
    false_positive: Option<bool>,
}

/// Parse + filter one MQTT payload into an [`ObjEvent`], or `None` when it is not
/// motion-relevant (bad JSON, false positive, unknown type, or — for a still-
/// present object — below the score floor). `end` events are accepted regardless
/// of score so a tracked object is always cleared even if its final score dipped.
#[must_use]
pub fn classify(payload: &[u8], min_score: f32) -> Option<ObjEvent> {
    let env: Envelope = serde_json::from_slice(payload).ok()?;
    let after = env.after;
    if after.false_positive.unwrap_or(false) {
        return None;
    }
    let score = after.score.unwrap_or(0.0);
    let ended = match env.event_type.as_str() {
        "new" | "update" => false,
        "end" => true,
        _ => return None,
    };
    if !ended && score < min_score {
        return None;
    }
    Some(ObjEvent {
        camera: after.camera,
        object_id: after.id,
        ended,
        score,
    })
}

// ── per-camera object-lifecycle state machine ─────────────────────────────────

/// A motion transition the loop should publish as a [`MotionSignal`].
#[derive(Debug, Clone, PartialEq)]
pub enum Transition {
    Start {
        started_at: DateTime<Utc>,
        peak_score: f32,
    },
    Stop {
        started_at: DateTime<Utc>,
        stopped_at: DateTime<Utc>,
        peak_score: f32,
    },
}

#[derive(Debug, Clone, Copy)]
struct ObjState {
    last_seen: DateTime<Utc>,
}

/// Tracks the set of active Frigate objects on ONE camera and decides when a
/// recording event starts/stops. Pure and deterministic given an injected `now`
/// — the MQTT loop just feeds it events + periodic ticks.
#[derive(Debug, Default)]
pub struct CameraTracker {
    active: HashMap<String, ObjState>,
    /// `Some` while an event is open — the wall-clock of the first object.
    started_at: Option<DateTime<Utc>>,
    /// Peak object score observed during the current event.
    peak_score: f32,
    /// When the active set last became empty (begins the STOP-grace countdown).
    empty_since: Option<DateTime<Utc>>,
}

impl CameraTracker {
    /// Fold one classified event in. Returns `Some(Start)` exactly when this
    /// event opens a new recording event (the first object after being idle).
    pub fn observe(&mut self, ev: &ObjEvent, now: DateTime<Utc>) -> Option<Transition> {
        if ev.ended {
            self.active.remove(&ev.object_id);
            if self.active.is_empty() && self.started_at.is_some() && self.empty_since.is_none() {
                self.empty_since = Some(now);
            }
            return None;
        }

        let was_empty = self.active.is_empty();
        self.active
            .insert(ev.object_id.clone(), ObjState { last_seen: now });
        self.peak_score = self.peak_score.max(ev.score);
        self.empty_since = None; // a present object cancels any pending stop

        if was_empty && self.started_at.is_none() {
            self.started_at = Some(now);
            Some(Transition::Start {
                started_at: now,
                peak_score: self.peak_score,
            })
        } else {
            None
        }
    }

    /// Periodic maintenance: expire objects Frigate stopped updating (dropped
    /// `end`), then emit `Stop` once the active set has been empty for
    /// [`STOP_GRACE`]. Returns `Some(Stop)` at most once per event.
    pub fn tick(&mut self, now: DateTime<Utc>) -> Option<Transition> {
        // Expire stale objects (no update within OBJECT_TTL). If this empties the
        // set, activity actually ceased at the LAST object's `last_seen` (when
        // updates stopped), not now — so the STOP grace is measured from then.
        // That silence is already ≥ OBJECT_TTL ≥ STOP_GRACE, so a stale object
        // stops on this same tick rather than waiting a second grace window.
        if !self.active.is_empty() {
            let last_activity = self.active.values().map(|s| s.last_seen).max();
            self.active
                .retain(|_, s| now.signed_duration_since(s.last_seen) <= OBJECT_TTL);
            if self.active.is_empty() && self.started_at.is_some() && self.empty_since.is_none() {
                self.empty_since = last_activity;
            }
        }

        if self.active.is_empty() {
            if let (Some(started_at), Some(empty_since)) = (self.started_at, self.empty_since) {
                if now.signed_duration_since(empty_since) >= STOP_GRACE {
                    let peak_score = self.peak_score;
                    self.reset();
                    return Some(Transition::Stop {
                        started_at,
                        stopped_at: now,
                        peak_score,
                    });
                }
            }
        }
        None
    }

    /// Close an in-progress event immediately (used on MQTT teardown so a dropped
    /// connection doesn't leave `recording.rs` with a never-closed event).
    /// Returns `Some(Stop)` only if an event was open.
    pub fn force_stop(&mut self, now: DateTime<Utc>) -> Option<Transition> {
        let started_at = self.started_at?;
        let peak_score = self.peak_score;
        self.reset();
        Some(Transition::Stop {
            started_at,
            stopped_at: now,
            peak_score,
        })
    }

    fn reset(&mut self) {
        self.active.clear();
        self.started_at = None;
        self.peak_score = 0.0;
        self.empty_since = None;
    }
}

/// Map a [`Transition`] to the wire [`MotionSignal`] and `try_send` it. Shared
/// with `ha_motion.rs` so there is one Transition→MotionSignal mapping.
pub(crate) fn emit(motion_tx: &MotionTx, camera_id: Uuid, t: Transition) {
    let signal = match t {
        Transition::Start {
            started_at,
            peak_score,
        } => MotionSignal {
            camera_id,
            started_at,
            stopped_at: None,
            peak_score,
            // Frigate motion is event-level only — no pixel region to highlight.
            bbox: None,
        },
        Transition::Stop {
            started_at,
            stopped_at,
            peak_score,
        } => MotionSignal {
            camera_id,
            started_at,
            stopped_at: Some(stopped_at),
            peak_score,
            bbox: None,
        },
    };
    if let Err(e) = motion_tx.try_send(signal) {
        warn!(camera_id = %camera_id, error = %e, "frigate motion: dropping signal (channel full/closed)");
    }
}

// ── MQTT loop ─────────────────────────────────────────────────────────────────

/// Run the Frigate motion source for one camera until `cancel` fires or the MQTT
/// connection drops. Returns `Ok(())` on cancellation / config-reload and `Err` on
/// a connection error, so `motion::run`'s back-off loop reconnects exactly as it
/// does for the pixel-diff loop. On any teardown an in-progress event is closed
/// with a STOP so `recording.rs` never sees a dangling event.
///
/// Reports the source HEALTHY (via `health_tx`) only AFTER the broker's `ConnAck`
/// confirms a live connection — never optimistically before — so a source that
/// cannot reach the broker stays unhealthy and the supervisor's fail-open grace
/// accumulates instead of being reset by a premature "healthy" (issue #61, the
/// `ha_motion.rs` twin). On any exit the supervisor reports unhealthy, so a
/// Motion-mode camera fails OPEN.
#[allow(clippy::too_many_arguments)]
pub async fn run_frigate_motion_loop(
    camera: &Camera,
    cfg: &FrigateMotionConfig,
    motion_tx: &MotionTx,
    cancel: &CancellationToken,
    pool: &Pool,
    start_version: i64,
    health_tx: &crate::MotionHealthTx,
    alert_gate: &std::sync::Arc<crate::motion::UnhealthyAlertGate>,
    alert_after_secs: u64,
) -> Result<()> {
    let frigate_name = camera.go2rtc_name.clone();
    let topic = format!("{}/events", cfg.mqtt_prefix);
    let (host, port) = parse_mqtt_url(&cfg.mqtt_url)?;

    let mut opts = MqttOptions::new(format!("crumb-recorder-mot-{}", camera.id), &host, port);
    opts.set_keep_alive(Duration::from_secs(30));
    opts.set_clean_session(true);
    opts.set_inflight(100);
    if let Some(user) = &cfg.mqtt_user {
        opts.set_credentials(user, cfg.mqtt_password.clone().unwrap_or_default());
    }
    let (client, mut event_loop) = AsyncClient::new(opts, 256);

    let mut tracker = CameraTracker::default();

    info!(
        camera_id = %camera.id,
        frigate_camera = %frigate_name,
        topic = %topic,
        "frigate motion: connecting"
    );

    // Drive `event_loop.poll()` in a DEDICATED task, forwarding events over a
    // channel. Two constraints force this shape:
    //   1. The 1s STOP-grace janitor must run CONCURRENTLY with event delivery —
    //      an MQTT poll blocks until the next event, which on a quiet camera can
    //      be tens of seconds, far longer than the grace — so the janitor cannot
    //      simply run *between* polls the way `ha_motion.rs` does (its `next_edges`
    //      is a discrete, bounded poll).
    //   2. rumqttc 0.24's `poll()` is NOT cancellation-safe. Racing it against the
    //      janitor in one `select!` (the previous shape) cancelled the in-flight
    //      poll every tick, which can starve rumqttc's keepalive so a wedged /
    //      half-open broker never surfaces as an `Err` — the source would report
    //      healthy forever and the camera would stay motion-gated instead of
    //      failing OPEN (issue #61). Running the poll to completion in its own task
    //      (racing ONLY cancellation, at shutdown) lets keepalive detect the wedge
    //      and return `Err`, which closes the channel below.
    // The main loop then selects the janitor against channel receipt, both
    // cancel-safe.
    let cam_id = camera.id;
    let (ev_tx, mut ev_rx) = tokio::sync::mpsc::channel::<Event>(256);
    let poll_cancel = cancel.clone();
    let poll_task = tokio::spawn(async move {
        loop {
            tokio::select! {
                () = poll_cancel.cancelled() => break,
                res = event_loop.poll() => match res {
                    Ok(ev) => {
                        // Sender error = the main loop is gone (teardown); stop.
                        if ev_tx.send(ev).await.is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        // Connection lost / keepalive failed: drop the sender so the
                        // main loop sees the disconnect and fails the camera OPEN.
                        warn!(camera_id = %cam_id, error = %e, "frigate motion: MQTT connection error");
                        break;
                    }
                }
            }
        }
    });

    let mut janitor = tokio::time::interval(TICK);
    janitor.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let result: Result<()> = loop {
        tokio::select! {
            () = cancel.cancelled() => break Ok(()),
            _ = janitor.tick() => {
                if let Some(t) = tracker.tick(Utc::now()) {
                    emit(motion_tx, camera.id, t);
                }
                // Hot-reload: if an admin changed the Frigate settings, exit
                // cleanly so the supervisor reconnects with the new config.
                if crumb_common::db::frigate_config_version(pool)
                    .await
                    .unwrap_or(start_version)
                    != start_version
                {
                    info!(camera_id = %camera.id, "frigate config changed; reconnecting");
                    break Ok(());
                }
            }
            maybe_ev = ev_rx.recv() => {
                match maybe_ev {
                    Some(Event::Incoming(Packet::ConnAck(_))) => {
                        info!(camera_id = %camera.id, "frigate motion: MQTT connected, subscribing");
                        // Broker confirmed live → NOW healthy. Reported here, not
                        // before the loop: a source that never connects never
                        // reaches this, so its health stays false and the fail-open
                        // grace accumulates instead of being reset by a premature
                        // "healthy" (issue #61). `report_health` dedups.
                        crate::motion::report_health(
                            health_tx,
                            pool,
                            camera.id,
                            true,
                            "frigate MQTT connected",
                            alert_gate,
                            alert_after_secs,
                        )
                        .await;
                        if let Err(e) = client.subscribe(&topic, QoS::AtLeastOnce).await {
                            warn!(camera_id = %camera.id, error = %e, "frigate motion: subscribe failed");
                        }
                    }
                    Some(Event::Incoming(Packet::Publish(publish))) => {
                        if let Some(ev) = classify(&publish.payload, cfg.min_score) {
                            if ev.camera == frigate_name {
                                if let Some(t) = tracker.observe(&ev, Utc::now()) {
                                    emit(motion_tx, camera.id, t);
                                }
                            }
                        }
                    }
                    Some(_) => {} // SubAck, PingResp, outgoing, etc.
                    None => {
                        // Poll task ended: a connection error (or shutdown). Treat as
                        // a lost connection → `Err` so the supervisor backs off and
                        // fails the camera OPEN.
                        break Err(anyhow!("frigate motion MQTT connection lost"));
                    }
                }
            }
        }
    };

    // Stop the poll task (drops `event_loop`, closing the connection) and close any
    // in-progress event so recording.rs doesn't keep it open across a reconnect
    // (the back-off loop will re-START when objects reappear).
    poll_task.abort();
    if let Some(t) = tracker.force_stop(Utc::now()) {
        emit(motion_tx, camera.id, t);
    }
    result
}

/// Parse `host` and `port` from an `mqtt://host:port` (or `mqtts://`, or bare
/// `host[:port]`) URL; defaults to port 1883. Mirrors the API ingester's helper
/// (kept local so the recorder doesn't depend on the api crate).
fn parse_mqtt_url(url: &str) -> Result<(String, u16)> {
    let stripped = url
        .strip_prefix("mqtt://")
        .or_else(|| url.strip_prefix("mqtts://"))
        .unwrap_or(url);
    let (host, port) = if let Some((h, p)) = stripped.split_once(':') {
        let port: u16 = p
            .parse()
            .with_context(|| format!("MQTT URL port '{p}' is not a valid u16"))?;
        (h.to_owned(), port)
    } else {
        (stripped.to_owned(), 1883u16)
    };
    Ok((host, port))
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(event_type: &str, id: &str, camera: &str, score: f32, fp: bool) -> Vec<u8> {
        serde_json::json!({
            "type": event_type,
            "after": { "id": id, "camera": camera, "score": score, "false_positive": fp }
        })
        .to_string()
        .into_bytes()
    }

    #[test]
    fn classify_filters_and_maps() {
        // new/update below floor → None; at/above → present.
        assert!(classify(&payload("new", "o1", "driveway", 0.2, false), 0.3).is_none());
        let ev = classify(&payload("update", "o1", "driveway", 0.8, false), 0.3).unwrap();
        assert_eq!(ev.camera, "driveway");
        assert_eq!(ev.object_id, "o1");
        assert!(!ev.ended);
        // false positive → None even if high score.
        assert!(classify(&payload("update", "o1", "driveway", 0.9, true), 0.3).is_none());
        // end → accepted regardless of score, marked ended.
        let end = classify(&payload("end", "o1", "driveway", 0.0, false), 0.3).unwrap();
        assert!(end.ended);
        // unknown type / bad json → None.
        assert!(classify(&payload("snapshot", "o1", "driveway", 0.9, false), 0.3).is_none());
        assert!(classify(b"not json", 0.3).is_none());
    }

    fn ev(id: &str, ended: bool) -> ObjEvent {
        ObjEvent {
            camera: "driveway".into(),
            object_id: id.into(),
            ended,
            score: 0.8,
        }
    }

    #[test]
    fn tracker_start_on_first_object_only() {
        let mut t = CameraTracker::default();
        let t0 = Utc::now();
        // First object → Start.
        let s = t.observe(&ev("a", false), t0);
        assert!(matches!(s, Some(Transition::Start { .. })));
        // Second concurrent object → no new Start.
        assert!(t.observe(&ev("b", false), t0).is_none());
    }

    #[test]
    fn tracker_stop_after_grace_not_before() {
        let mut t = CameraTracker::default();
        let t0 = Utc::now();
        t.observe(&ev("a", false), t0);
        // Object ends → no immediate stop.
        assert!(t.observe(&ev("a", true), t0).is_none());
        // Before grace elapses → still no stop.
        assert!(t.tick(t0 + chrono::Duration::seconds(2)).is_none());
        // After grace → Stop, carrying the original start + peak.
        let stop = t.tick(t0 + STOP_GRACE + chrono::Duration::seconds(1));
        match stop {
            Some(Transition::Stop {
                started_at,
                peak_score,
                ..
            }) => {
                assert_eq!(started_at, t0);
                assert!((peak_score - 0.8).abs() < 1e-6);
            }
            other => panic!("expected Stop, got {other:?}"),
        }
        // Event is closed — a further tick does nothing.
        assert!(t.tick(t0 + chrono::Duration::seconds(60)).is_none());
    }

    #[test]
    fn tracker_new_object_within_grace_cancels_stop() {
        let mut t = CameraTracker::default();
        let t0 = Utc::now();
        t.observe(&ev("a", false), t0);
        t.observe(&ev("a", true), t0); // a leaves
                                       // b appears 2s later, within the 5s grace → NO stop, NO new start.
        let s = t.observe(&ev("b", false), t0 + chrono::Duration::seconds(2));
        assert!(
            s.is_none(),
            "object within grace must not re-Start (one continuous event)"
        );
        // grace from the FIRST empty no longer applies (b is present) → no stop.
        assert!(t.tick(t0 + chrono::Duration::seconds(10)).is_none());
    }

    #[test]
    fn tracker_stale_object_expires_then_stops() {
        let mut t = CameraTracker::default();
        let t0 = Utc::now();
        t.observe(&ev("ghost", false), t0); // Frigate never sends `end`
                                            // Long after TTL + grace, the janitor expires it and stops.
        let stop = t.tick(t0 + OBJECT_TTL + STOP_GRACE + chrono::Duration::seconds(2));
        assert!(
            matches!(stop, Some(Transition::Stop { .. })),
            "stale object must time out and STOP"
        );
    }

    #[test]
    fn tracker_force_stop_only_when_active() {
        let mut t = CameraTracker::default();
        assert!(t.force_stop(Utc::now()).is_none(), "no event → no stop");
        let t0 = Utc::now();
        t.observe(&ev("a", false), t0);
        assert!(matches!(t.force_stop(t0), Some(Transition::Stop { .. })));
        assert!(t.force_stop(t0).is_none(), "already stopped");
    }

    #[test]
    fn parse_mqtt_url_variants() {
        assert_eq!(
            parse_mqtt_url("mqtt://192.0.2.10:1883").unwrap(),
            ("192.0.2.10".into(), 1883)
        );
        assert_eq!(
            parse_mqtt_url("mqtt://host").unwrap(),
            ("host".into(), 1883)
        );
        assert_eq!(
            parse_mqtt_url("10.0.0.1:1884").unwrap(),
            ("10.0.0.1".into(), 1884)
        );
    }
}
