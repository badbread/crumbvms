// SPDX-License-Identifier: AGPL-3.0-or-later

//! Home Assistant as a motion source (Phase 2). A camera with
//! `motion_source='ha'` is *triggered for recording* by its linked HA
//! motion/door `binary_sensor`s instead of pixel analysis, emitting the same
//! [`MotionSignal`](crumb_common::MotionSignal) start/stop the pixel pipeline
//! and the Frigate source do, so `recording.rs` is unchanged and cannot tell
//! which source produced the signal.
//!
//! Two things happen at each tracker transition, in this order and never the
//! other way round:
//!   1. **The `MotionSignal` is emitted first and unconditionally** — it drives
//!      footage (feeds the `MotionBuffer`). Nothing below may delay or gate it.
//!   2. **A labeled `events` row is written best-effort** ([`db::upsert_ha_event`]),
//!      derived from the *opening* sensor's `device_class` (Door / Window / …).
//!      This is surfacing only: a DB hiccup is logged and ignored, exactly like
//!      the generic motion-event write in `recording.rs`. A failed glyph write
//!      can never cost a segment. The label never rides the `MotionSignal`, so
//!      that type stays source-agnostic.
//!
//! Transport is REST polling via [`crumb_common::ha::HaPollSource`]. The
//! correctness rule is the shared one and is load-bearing: a failed poll returns
//! `Err` → this loop exits → the supervisor's `report_health(false)` fails the
//! camera **OPEN** (a Motion-mode camera records everything while HA is
//! unreachable). Never turn a poll failure into a retry here.
//!
//! The tracker/state-machine is pure + unit-tested. Structural twin of
//! `frigate_motion.rs`, minus the object-TTL: polling re-reads absolute sensor
//! state every tick, so a sensor held `on` is real, not stale.

use std::collections::{HashMap, HashSet};

use anyhow::{anyhow, Result};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use crumb_common::db;
use crumb_common::ha::{EntityEdge, HaClient, HaEventSource, HaPollSource};
use crumb_common::types::Camera;

use crate::frigate_motion::{emit, Transition};
use crate::MotionTx;

/// Once no linked sensor is `on`, wait this long before emitting STOP so a sensor
/// ending and another beginning a moment later don't fragment the recording.
/// Mirrors the pixel pipeline + the Frigate source.
const STOP_GRACE: chrono::Duration = chrono::Duration::seconds(5);

/// A tracker transition. Carries the *opening* entity + its `device_class` so the
/// loop can both emit the source-agnostic [`MotionSignal`] AND write the labeled
/// surfacing row. The label is fixed by whichever sensor opened the event.
#[derive(Debug, Clone, PartialEq)]
pub enum HaTransition {
    Start {
        started_at: DateTime<Utc>,
        entity_id: String,
        device_class: Option<String>,
    },
    Stop {
        started_at: DateTime<Utc>,
        stopped_at: DateTime<Utc>,
        entity_id: String,
        device_class: Option<String>,
    },
}

impl HaTransition {
    /// Map to the source-agnostic wire [`Transition`] (peak_score is constant:
    /// a binary sensor has no confidence score). The entity/class are dropped —
    /// they never ride the `MotionSignal`.
    fn to_signal_transition(&self) -> Transition {
        match *self {
            HaTransition::Start { started_at, .. } => Transition::Start {
                started_at,
                peak_score: 1.0,
            },
            HaTransition::Stop {
                started_at,
                stopped_at,
                ..
            } => Transition::Stop {
                started_at,
                stopped_at,
                peak_score: 1.0,
            },
        }
    }
}

/// The event currently open, so a STOP can be labeled with the same opening
/// entity that a START was.
#[derive(Debug, Clone)]
struct OpenEvent {
    entity_id: String,
    device_class: Option<String>,
    started_at: DateTime<Utc>,
}

/// Per-camera event state driven by HA sensor on/off edges.
///
/// Unlike [`crate::frigate_motion::CameraTracker`] there is **no object-TTL**:
/// polling re-reads absolute state every tick, so a PIR/contact held `on` for
/// minutes is real (not a dropped `end`). `recording.rs`'s `MAX_OPEN_SIGNAL_SECS`
/// backstop still force-expires a genuinely wedged START, so a sensor stuck `on`
/// in HA forever cannot pin recording forever.
#[derive(Debug, Default)]
pub struct HaTracker {
    /// `entity_id → device_class` for every linked motion sensor (fixes labels).
    class_by_entity: HashMap<String, Option<String>>,
    on: HashSet<String>,
    /// `Some` while an event is open (the opening entity fixes the label).
    open: Option<OpenEvent>,
    /// When the on-set last became empty (begins the STOP-grace countdown).
    empty_since: Option<DateTime<Utc>>,
}

impl HaTracker {
    fn new(class_by_entity: HashMap<String, Option<String>>) -> Self {
        Self {
            class_by_entity,
            ..Self::default()
        }
    }

    /// Fold one edge in. Returns `Some(Start)` exactly when the first sensor
    /// turns on after being idle; that sensor's `device_class` fixes the label.
    pub fn observe(&mut self, edge: &EntityEdge, now: DateTime<Utc>) -> Option<HaTransition> {
        if edge.on {
            let was_empty = self.on.is_empty();
            self.on.insert(edge.entity_id.clone());
            self.empty_since = None; // an active sensor cancels any pending stop
            if was_empty && self.open.is_none() {
                let device_class = self.class_by_entity.get(&edge.entity_id).cloned().flatten();
                self.open = Some(OpenEvent {
                    entity_id: edge.entity_id.clone(),
                    device_class: device_class.clone(),
                    started_at: now,
                });
                return Some(HaTransition::Start {
                    started_at: now,
                    entity_id: edge.entity_id.clone(),
                    device_class,
                });
            }
        } else {
            self.on.remove(&edge.entity_id);
            if self.on.is_empty() && self.open.is_some() && self.empty_since.is_none() {
                self.empty_since = Some(now);
            }
        }
        None
    }

    /// Emit STOP once the on-set has been empty for [`STOP_GRACE`]. At most once
    /// per event.
    pub fn tick(&mut self, now: DateTime<Utc>) -> Option<HaTransition> {
        if self.on.is_empty() {
            if let (Some(open), Some(empty_since)) = (self.open.as_ref(), self.empty_since) {
                if now.signed_duration_since(empty_since) >= STOP_GRACE {
                    let t = HaTransition::Stop {
                        started_at: open.started_at,
                        stopped_at: now,
                        entity_id: open.entity_id.clone(),
                        device_class: open.device_class.clone(),
                    };
                    self.reset();
                    return Some(t);
                }
            }
        }
        None
    }

    /// Close an in-progress event immediately (loop teardown) so `recording.rs`
    /// never keeps a dangling event across a reconnect.
    pub fn force_stop(&mut self, now: DateTime<Utc>) -> Option<HaTransition> {
        let open = self.open.as_ref()?;
        let t = HaTransition::Stop {
            started_at: open.started_at,
            stopped_at: now,
            entity_id: open.entity_id.clone(),
            device_class: open.device_class.clone(),
        };
        self.reset();
        Some(t)
    }

    fn reset(&mut self) {
        self.on.clear();
        self.open = None;
        self.empty_since = None;
    }
}

/// Emit a tracker transition: the `MotionSignal` FIRST (drives footage), then the
/// best-effort labeled surfacing row (never gates or delays the signal).
async fn publish(motion_tx: &MotionTx, pool: &Pool, camera_id: uuid::Uuid, t: &HaTransition) {
    // 1. Footage-driving signal, unconditionally, before anything can fail.
    emit(motion_tx, camera_id, t.to_signal_transition());
    // 2. Labeled surfacing row, best-effort. A failure here is invisible to
    //    recording — logged and ignored, exactly like the generic motion event.
    let (entity_id, device_class, started_at, stopped_at) = match t {
        HaTransition::Start {
            started_at,
            entity_id,
            device_class,
        } => (entity_id, device_class, *started_at, None),
        HaTransition::Stop {
            started_at,
            stopped_at,
            entity_id,
            device_class,
        } => (entity_id, device_class, *started_at, Some(*stopped_at)),
    };
    if let Err(e) = db::upsert_ha_event(
        pool,
        camera_id,
        entity_id,
        device_class.as_deref(),
        started_at,
        stopped_at,
    )
    .await
    {
        warn!(camera_id = %camera_id, error = %e, "failed to persist HA event (surfacing only)");
    }
}

/// Run the HA motion source for one camera until `cancel` fires, HA settings
/// change, or a poll fails. `links` is this camera's `role='motion'` entities as
/// `(entity_id, device_class)`. Returns `Ok(())` on cancel / config-change (a
/// clean reconnect) and `Err` on a poll failure. It reports the source HEALTHY
/// (via `health_tx`) only AFTER a poll succeeds — never optimistically before —
/// so a persistently-failing source stays unhealthy and the supervisor's
/// fail-open grace accumulates instead of being reset by a premature "healthy".
/// On any exit the supervisor reports unhealthy, so a Motion-mode camera fails
/// OPEN.
#[allow(clippy::too_many_arguments)]
pub async fn run_ha_motion_loop(
    camera: &Camera,
    client: HaClient,
    links: Vec<(String, Option<String>)>,
    motion_tx: &MotionTx,
    cancel: &CancellationToken,
    pool: &Pool,
    start_version: i64,
    health_tx: &crate::MotionHealthTx,
    alert_gate: &std::sync::Arc<crate::motion::UnhealthyAlertGate>,
    alert_after_secs: u64,
) -> Result<()> {
    let entity_ids: Vec<String> = links.iter().map(|(e, _)| e.clone()).collect();
    let class_by_entity: HashMap<String, Option<String>> = links.into_iter().collect();
    info!(camera_id = %camera.id, entities = entity_ids.len(), "ha motion: polling sensors");
    let mut source = HaPollSource::new(client, entity_ids);
    let mut tracker = HaTracker::new(class_by_entity);

    let result: Result<()> = loop {
        if cancel.is_cancelled() {
            break Ok(());
        }
        // STOP-grace tick + hot-reload check, done BETWEEN polls — NOT as a
        // concurrent `select!` arm racing the poll. A periodic janitor tick racing
        // `next_edges()` would win the ~1s race and CANCEL the in-flight HTTP poll
        // before it could complete or hit its 5s timeout, so a hung/unreachable HA
        // would never surface as `Err` and the camera would never fail OPEN (the
        // exact silent-drop this transport was chosen to avoid). Checked here, the
        // poll always runs to completion.
        if let Some(t) = tracker.tick(Utc::now()) {
            publish(motion_tx, pool, camera.id, &t).await;
        }
        if db::ha_config_version(pool).await.unwrap_or(start_version) != start_version {
            info!(camera_id = %camera.id, "ha config changed; reconnecting");
            break Ok(());
        }

        // Poll, racing ONLY cancellation. `next_edges` bounds itself with the
        // client's 5s timeout, so a dead HA returns `Err` within ~5s → the loop
        // exits `Err` → the supervisor fails the camera OPEN.
        let edges = tokio::select! {
            () = cancel.cancelled() => break Ok(()),
            r = source.next_edges() => r,
        };
        match edges {
            Ok(batch) => {
                // A successful poll — even an empty one — proves HA is reachable,
                // so the source is healthy. Reported HERE (not before the poll):
                // a source that keeps failing never reaches this, so its health
                // stays false and the fail-open grace accumulates. `report_health`
                // dedups, so this is a no-op after the first success.
                crate::motion::report_health(
                    health_tx,
                    pool,
                    camera.id,
                    true,
                    "ha reachable",
                    alert_gate,
                    alert_after_secs,
                )
                .await;
                let now = Utc::now();
                for e in &batch {
                    if let Some(t) = tracker.observe(e, now) {
                        publish(motion_tx, pool, camera.id, &t).await;
                    }
                }
            }
            // A failed poll exits the loop → the supervisor fails the camera OPEN.
            // NEVER swallow this into a retry (see module doc).
            Err(e) => break Err(anyhow!("ha motion poll error: {e}")),
        }
    };

    // Close any in-progress event so recording.rs doesn't hold it across reconnect.
    if let Some(t) = tracker.force_stop(Utc::now()) {
        publish(motion_tx, pool, camera.id, &t).await;
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
    fn tracker(pairs: &[(&str, Option<&str>)]) -> HaTracker {
        HaTracker::new(
            pairs
                .iter()
                .map(|(e, c)| ((*e).to_owned(), c.map(str::to_owned)))
                .collect(),
        )
    }

    #[test]
    fn start_only_on_first_on_carries_opening_class() {
        let mut t = tracker(&[("a", Some("door")), ("b", Some("motion"))]);
        // First sensor 'a' opens the event and fixes the label to its class.
        match t.observe(&edge("a", true, at(0)), at(0)) {
            Some(HaTransition::Start {
                entity_id,
                device_class,
                ..
            }) => {
                assert_eq!(entity_id, "a");
                assert_eq!(device_class.as_deref(), Some("door"));
            }
            other => panic!("expected Start, got {other:?}"),
        }
        // A second sensor turning on does not open a new event (no relabel).
        assert!(t.observe(&edge("b", true, at(1)), at(1)).is_none());
    }

    #[test]
    fn stop_after_grace_keeps_opening_entity() {
        let mut t = tracker(&[("a", Some("window"))]);
        t.observe(&edge("a", true, at(0)), at(0));
        t.observe(&edge("a", false, at(0)), at(0)); // on-set now empty
        assert!(t.tick(at(4)).is_none()); // before grace
        match t.tick(at(6)) {
            Some(HaTransition::Stop {
                entity_id,
                device_class,
                started_at,
                ..
            }) => {
                assert_eq!(entity_id, "a");
                assert_eq!(device_class.as_deref(), Some("window"));
                assert_eq!(started_at, at(0)); // same event the START opened
            }
            other => panic!("expected Stop, got {other:?}"),
        }
    }

    #[test]
    fn new_on_within_grace_cancels_stop() {
        let mut t = tracker(&[("a", Some("door")), ("b", Some("door"))]);
        t.observe(&edge("a", true, at(0)), at(0));
        t.observe(&edge("a", false, at(0)), at(0));
        // On-set empty; another sensor fires within the grace window: event stays open.
        assert!(t.observe(&edge("b", true, at(3)), at(3)).is_none());
        assert!(t.tick(at(7)).is_none()); // no stop past the original grace
    }

    #[test]
    fn no_ttl_a_held_on_sensor_never_auto_stops() {
        // The inverse of the Frigate tracker's stale-object expiry: an entity
        // held `on` with no `off` edge must NOT auto-stop.
        let mut t = tracker(&[("a", Some("motion"))]);
        t.observe(&edge("a", true, at(0)), at(0));
        assert!(t.tick(at(100_000)).is_none());
    }

    #[test]
    fn force_stop_only_when_active() {
        let mut t = tracker(&[("a", None)]);
        assert!(t.force_stop(at(0)).is_none());
        t.observe(&edge("a", true, at(0)), at(0));
        match t.force_stop(at(1)) {
            Some(HaTransition::Stop { entity_id, .. }) => assert_eq!(entity_id, "a"),
            other => panic!("expected Stop, got {other:?}"),
        }
    }

    #[test]
    fn signal_transition_is_source_agnostic() {
        // The wire Transition drops entity/class and uses the constant score.
        let ht = HaTransition::Start {
            started_at: at(0),
            entity_id: "a".to_owned(),
            device_class: Some("door".to_owned()),
        };
        assert_eq!(
            ht.to_signal_transition(),
            Transition::Start {
                started_at: at(0),
                peak_score: 1.0,
            }
        );
    }
}
