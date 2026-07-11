// SPDX-License-Identifier: AGPL-3.0-or-later

//! Fail-open health aggregation for **additive** motion sources.
//!
//! A camera can enable several motion sources at once (pixel + Frigate + Home
//! Assistant); the recorder runs one supervised loop per enabled source and they
//! all feed the same `MotionSignal` stream. But the recording task reads a single
//! health bool per camera (the fail-open rail: unhealthy = record everything).
//! [`FailOpenGate`] collapses the per-source health into that one bool.
//!
//! The rule (ratified in `docs/DECISIONS.md`, additive multi-source motion):
//!
//! > The camera is HEALTHY (motion-gated) only while **at least one source is
//! > healthy AND no source has been hard-DOWN past the grace**. Otherwise it
//! > fails OPEN (records everything).
//!
//! Two clauses, deliberately asymmetric:
//! * **(a) all sources unhealthy → fail open immediately** (no grace). When
//!   nothing is detecting, honor the fail-open invariant at once.
//! * **(b) any one source hard-DOWN past [`Self::grace`] → fail open.** A source
//!   is *added* to catch what the others miss, so its silent death must
//!   eventually fail open — but a still-working source buys a bounded grace so
//!   one flaky source doesn't force record-everything on every reconnect.
//!
//! A **clean reconnect / config reload** is [`SourceHealth::Reconfiguring`], NOT
//! `Down` — it never accrues down-time, so normal reconnects never trip clause
//! (b). This is what stops the flapping.
//!
//! Reduces exactly to today for a single-source camera: one source, down →
//! clause (a) "all unhealthy" → immediate fail open, identical to the previous
//! single-`report_health(false)` behavior.

use std::collections::HashMap;

use chrono::{DateTime, Duration, Utc};

/// The additive motion sources a camera can enable. Used as the per-source key so
/// each source's health is tracked (and alerted) independently.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SourceKind {
    Pixel,
    Frigate,
    Ha,
}

impl SourceKind {
    /// Stable label for logs / per-source alerts ("by name" so a dead added
    /// source is loud, not silent).
    pub fn as_str(self) -> &'static str {
        match self {
            SourceKind::Pixel => "pixel",
            SourceKind::Frigate => "frigate",
            SourceKind::Ha => "ha",
        }
    }
}

/// One source's health as the gate sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceHealth {
    /// The source loop is running and detecting.
    Healthy,
    /// The source loop is erroring / in back-off since `since`. Accrues down-time
    /// toward clause (b).
    Down { since: DateTime<Utc> },
    /// The source loop exited cleanly (config-version bump / cancel) and is about
    /// to re-run — a transient, does NOT accrue down-time. Counts as "not
    /// healthy" for clause (a) but never trips clause (b).
    Reconfiguring,
}

/// Default grace before a single hard-down source (with others still working)
/// forces a global fail-open. Conservative: the only footage exposure during the
/// window is the delta-coverage of the one dead source, then fail-open catches
/// everything.
pub const DEFAULT_SOURCE_DOWN_GRACE: Duration = Duration::seconds(60);

/// Aggregates per-source health into the single camera fail-open bool.
#[derive(Debug)]
pub struct FailOpenGate {
    grace: Duration,
    sources: HashMap<SourceKind, SourceHealth>,
}

impl FailOpenGate {
    /// Create a gate over exactly the enabled sources, each starting `Down` at
    /// `now` (a source is not proven healthy until its loop reports so — until
    /// then the camera fails open, the safe direction). An empty set (no enabled
    /// sources on a Motion-mode camera) is permanently fail-open.
    pub fn new(enabled: &[SourceKind], now: DateTime<Utc>, grace: Duration) -> Self {
        let sources = enabled
            .iter()
            .map(|&k| (k, SourceHealth::Down { since: now }))
            .collect();
        Self { grace, sources }
    }

    /// Record a source's current health.
    pub fn set(&mut self, source: SourceKind, health: SourceHealth) {
        // Only sources in the enabled set matter; ignore anything else.
        if let Some(slot) = self.sources.get_mut(&source) {
            *slot = health;
        }
    }

    /// The camera health bool for the fail-open rail: `true` = healthy
    /// (motion-gated), `false` = fail open (record everything).
    pub fn healthy(&self, now: DateTime<Utc>) -> bool {
        if self.sources.is_empty() {
            return false; // no detector at all → fail open
        }
        let any_healthy = self
            .sources
            .values()
            .any(|h| matches!(h, SourceHealth::Healthy));
        let any_down_past_grace = self.sources.values().any(|h| {
            matches!(h, SourceHealth::Down { since } if now.signed_duration_since(*since) >= self.grace)
        });
        any_healthy && !any_down_past_grace
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(secs: i64) -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(1_700_000_000 + secs, 0).unwrap()
    }
    const GRACE: Duration = Duration::seconds(60);

    #[test]
    fn single_source_reduces_to_today() {
        // Pixel-only: healthy while healthy, fail open immediately when down.
        let mut g = FailOpenGate::new(&[SourceKind::Pixel], at(0), GRACE);
        assert!(!g.healthy(at(0))); // starts Down until it reports healthy
        g.set(SourceKind::Pixel, SourceHealth::Healthy);
        assert!(g.healthy(at(1)));
        g.set(SourceKind::Pixel, SourceHealth::Down { since: at(2) });
        assert!(!g.healthy(at(2))); // all-unhealthy → immediate fail open (no grace)
    }

    #[test]
    fn zero_sources_is_fail_open() {
        let g = FailOpenGate::new(&[], at(0), GRACE);
        assert!(!g.healthy(at(0)));
    }

    #[test]
    fn healthy_partner_graces_a_down_source_then_fails_open() {
        // pixel + ha; ha dies while pixel keeps working.
        let mut g = FailOpenGate::new(&[SourceKind::Pixel, SourceKind::Ha], at(0), GRACE);
        g.set(SourceKind::Pixel, SourceHealth::Healthy);
        g.set(SourceKind::Ha, SourceHealth::Healthy);
        assert!(g.healthy(at(1)));
        // ha goes down at t=10; pixel still healthy → graced, still motion-gated.
        g.set(SourceKind::Ha, SourceHealth::Down { since: at(10) });
        // down@10 + grace 60 = 70: healthy up to 69, fail open at 71 even though
        // pixel is still healthy (ha was added to catch what pixel misses, so its
        // silent death must eventually fail open).
        assert!(g.healthy(at(30)));
        assert!(g.healthy(at(69)));
        assert!(!g.healthy(at(71)));
    }

    #[test]
    fn brief_reconfigure_does_not_flap() {
        // A partner reconfiguring (clean reconnect) never trips the grace clause.
        let mut g = FailOpenGate::new(&[SourceKind::Pixel, SourceKind::Ha], at(0), GRACE);
        g.set(SourceKind::Pixel, SourceHealth::Healthy);
        g.set(SourceKind::Ha, SourceHealth::Reconfiguring);
        // pixel healthy + ha reconfiguring → still healthy, forever (no down-time).
        assert!(g.healthy(at(5)));
        assert!(g.healthy(at(10_000)));
    }

    #[test]
    fn all_unhealthy_fails_open_immediately_even_if_reconfiguring() {
        let mut g = FailOpenGate::new(&[SourceKind::Pixel, SourceKind::Ha], at(0), GRACE);
        g.set(SourceKind::Pixel, SourceHealth::Reconfiguring);
        g.set(SourceKind::Ha, SourceHealth::Reconfiguring);
        // Nothing detecting → fail open at once (no grace on clause a).
        assert!(!g.healthy(at(1)));
    }

    #[test]
    fn recovery_returns_to_motion_gated() {
        let mut g = FailOpenGate::new(&[SourceKind::Pixel, SourceKind::Ha], at(0), GRACE);
        g.set(SourceKind::Pixel, SourceHealth::Healthy);
        g.set(SourceKind::Ha, SourceHealth::Down { since: at(0) });
        assert!(!g.healthy(at(100))); // ha down past grace → fail open
        g.set(SourceKind::Ha, SourceHealth::Healthy); // ha recovers
        assert!(g.healthy(at(101)));
    }
}
