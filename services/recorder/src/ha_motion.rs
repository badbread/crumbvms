// SPDX-License-Identifier: AGPL-3.0-or-later

//! Home Assistant as a motion source (Phase 2). A camera with
//! `motion_source='ha'` is *triggered for recording* by its linked HA
//! motion/door `binary_sensor`s instead of pixel analysis — emitting the same
//! [`MotionSignal`](crumb_common::MotionSignal) start/stop the pixel pipeline
//! and the Frigate source do, so `recording.rs` is unchanged and cannot tell
//! which source produced the signal.
//!
//! Transport is REST polling via [`crumb_common::ha::HaPollSource`]. The
//! correctness rule is the shared one and is load-bearing: a failed poll returns
//! `Err` → this loop exits → the supervisor's `report_health(false)` fails the
//! camera **OPEN** (a Motion-mode camera records everything while HA is
//! unreachable). Never turn a poll failure into a retry here.
//!
//! The tracker/state-machine is pure + unit-tested; only the poll plumbing needs
//! a live HA. Structural twin of `frigate_motion.rs`, minus the object-TTL:
//! polling re-reads absolute sensor state every tick, so a sensor held `on` is
//! real, not stale.

use std::collections::HashSet;
use std::time::Duration;

use anyhow::{anyhow, Result};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use tokio_util::sync::CancellationToken;
use tracing::info;

use crumb_common::ha::{EntityEdge, HaClient, HaEventSource, HaPollSource};
use crumb_common::types::Camera;

use crate::frigate_motion::{emit, Transition};
use crate::MotionTx;

/// Once no linked sensor is `on`, wait this long before emitting STOP so a sensor
/// ending and another beginning a moment later don't fragment the recording.
/// Mirrors the pixel pipeline + the Frigate source.
const STOP_GRACE: chrono::Duration = chrono::Duration::seconds(5);

/// Janitor tick: STOP-grace check + hot-reload poll.
const TICK: Duration = Duration::from_secs(1);

/// Per-camera event state driven by HA sensor on/off edges.
///
/// Unlike [`crate::frigate_motion::CameraTracker`] there is **no object-TTL**:
/// polling re-reads absolute state every tick, so a PIR/contact held `on` for
/// minutes is real (not a dropped `end`). `recording.rs`'s `MAX_OPEN_SIGNAL_SECS`
/// backstop still force-expires a genuinely wedged START, so a sensor stuck `on`
/// in HA forever cannot pin recording forever.
#[derive(Debug, Default)]
pub struct HaTracker {
    on: HashSet<String>,
    /// `Some` while an event is open — wall-clock of the first sensor that fired.
    started_at: Option<DateTime<Utc>>,
    /// When the on-set last became empty (begins the STOP-grace countdown).
    empty_since: Option<DateTime<Utc>>,
}

impl HaTracker {
    /// Fold one edge in. Returns `Some(Start)` exactly when the first sensor
    /// turns on after being idle.
    pub fn observe(&mut self, edge: &EntityEdge, now: DateTime<Utc>) -> Option<Transition> {
        if edge.on {
            let was_empty = self.on.is_empty();
            self.on.insert(edge.entity_id.clone());
            self.empty_since = None; // an active sensor cancels any pending stop
            if was_empty && self.started_at.is_none() {
                self.started_at = Some(now);
                return Some(Transition::Start {
                    started_at: now,
                    peak_score: 1.0, // a binary sensor has no confidence score
                });
            }
        } else {
            self.on.remove(&edge.entity_id);
            if self.on.is_empty() && self.started_at.is_some() && self.empty_since.is_none() {
                self.empty_since = Some(now);
            }
        }
        None
    }

    /// Emit STOP once the on-set has been empty for [`STOP_GRACE`]. At most once
    /// per event.
    pub fn tick(&mut self, now: DateTime<Utc>) -> Option<Transition> {
        if self.on.is_empty() {
            if let (Some(started_at), Some(empty_since)) = (self.started_at, self.empty_since) {
                if now.signed_duration_since(empty_since) >= STOP_GRACE {
                    self.reset();
                    return Some(Transition::Stop {
                        started_at,
                        stopped_at: now,
                        peak_score: 1.0,
                    });
                }
            }
        }
        None
    }

    /// Close an in-progress event immediately (loop teardown) so `recording.rs`
    /// never keeps a dangling event across a reconnect.
    pub fn force_stop(&mut self, now: DateTime<Utc>) -> Option<Transition> {
        let started_at = self.started_at?;
        self.reset();
        Some(Transition::Stop {
            started_at,
            stopped_at: now,
            peak_score: 1.0,
        })
    }

    fn reset(&mut self) {
        self.on.clear();
        self.started_at = None;
        self.empty_since = None;
    }
}

/// Run the HA motion source for one camera until `cancel` fires, HA settings
/// change, or a poll fails. Returns `Ok(())` on cancel / config-change (a clean
/// reconnect) and `Err` on a poll failure. Either way the caller
/// (`motion::run`) reports health false, so a Motion-mode camera fails OPEN.
pub async fn run_ha_motion_loop(
    camera: &Camera,
    client: HaClient,
    entity_ids: Vec<String>,
    motion_tx: &MotionTx,
    cancel: &CancellationToken,
    pool: &Pool,
    start_version: i64,
) -> Result<()> {
    info!(camera_id = %camera.id, entities = entity_ids.len(), "ha motion: polling sensors");
    let mut source = HaPollSource::new(client, entity_ids);
    let mut tracker = HaTracker::default();
    let mut janitor = tokio::time::interval(TICK);
    janitor.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    let result: Result<()> = loop {
        tokio::select! {
            () = cancel.cancelled() => break Ok(()),
            _ = janitor.tick() => {
                if let Some(t) = tracker.tick(Utc::now()) {
                    emit(motion_tx, camera.id, t);
                }
                // Hot-reload: an admin edit to HA settings bumps the version; exit
                // cleanly so the supervisor reconnects with the fresh config.
                if crumb_common::db::ha_config_version(pool)
                    .await
                    .unwrap_or(start_version)
                    != start_version
                {
                    info!(camera_id = %camera.id, "ha config changed; reconnecting");
                    break Ok(());
                }
            }
            edges = source.next_edges() => {
                match edges {
                    Ok(batch) => {
                        let now = Utc::now();
                        for e in &batch {
                            if let Some(t) = tracker.observe(e, now) {
                                emit(motion_tx, camera.id, t);
                            }
                        }
                    }
                    // A failed poll exits the loop → the supervisor fails the
                    // camera OPEN. NEVER swallow this into a retry (see module doc).
                    Err(e) => break Err(anyhow!("ha motion poll error: {e}")),
                }
            }
        }
    };

    // Close any in-progress event so recording.rs doesn't hold it across reconnect.
    if let Some(t) = tracker.force_stop(Utc::now()) {
        emit(motion_tx, camera.id, t);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(secs: i64) -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(1_700_000_000 + secs, 0).unwrap()
    }
    fn edge(id: &str, on: bool, t: DateTime<Utc>) -> EntityEdge {
        EntityEdge {
            entity_id: id.to_owned(),
            on,
            at: t,
        }
    }

    #[test]
    fn start_only_on_first_on() {
        let mut t = HaTracker::default();
        assert!(matches!(
            t.observe(&edge("a", true, at(0)), at(0)),
            Some(Transition::Start { .. })
        ));
        // A second sensor turning on does not open a new event.
        assert!(t.observe(&edge("b", true, at(1)), at(1)).is_none());
    }

    #[test]
    fn stop_after_grace_not_before() {
        let mut t = HaTracker::default();
        t.observe(&edge("a", true, at(0)), at(0));
        t.observe(&edge("a", false, at(0)), at(0)); // on-set now empty
        assert!(t.tick(at(4)).is_none()); // before grace
        assert!(matches!(t.tick(at(6)), Some(Transition::Stop { .. }))); // after grace
    }

    #[test]
    fn new_on_within_grace_cancels_stop() {
        let mut t = HaTracker::default();
        t.observe(&edge("a", true, at(0)), at(0));
        t.observe(&edge("a", false, at(0)), at(0)); // empty, grace counting
        // Another sensor fires within the grace window: same event stays open.
        assert!(t.observe(&edge("b", true, at(3)), at(3)).is_none());
        assert!(t.tick(at(7)).is_none()); // no stop past the original grace
    }

    #[test]
    fn no_ttl_a_held_on_sensor_never_auto_stops() {
        // The inverse of the Frigate tracker's stale-object expiry: an entity
        // held `on` with no `off` edge must NOT auto-stop.
        let mut t = HaTracker::default();
        t.observe(&edge("a", true, at(0)), at(0));
        assert!(t.tick(at(100_000)).is_none());
    }

    #[test]
    fn force_stop_only_when_active() {
        let mut t = HaTracker::default();
        assert!(t.force_stop(at(0)).is_none());
        t.observe(&edge("a", true, at(0)), at(0));
        assert!(matches!(t.force_stop(at(1)), Some(Transition::Stop { .. })));
    }
}
