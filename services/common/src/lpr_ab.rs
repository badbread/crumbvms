// SPDX-License-Identifier: AGPL-3.0-or-later

//! LPR dual-engine A/B benchmark: pairing `plate_reads` into vehicle
//! "passes" and computing per-engine comparison stats.
//!
//! On a camera with `lpr_engine = 'both'`, every physical vehicle pass is read
//! by BOTH Frigate's native LPR (`source_id = "frigate"`) and the crumb-alpr
//! fast-alpr worker (`source_id = "crumb-alpr"`). This module derives, purely
//! in memory, which reads belong to the same physical pass so the two engines
//! can be scored head-to-head. Nothing here touches the database — the API
//! route feeds it reads + confirmed truths and serializes the result — so the
//! clustering rules are unit-testable without Postgres.
//!
//! # Pairing algorithm (two phases)
//!
//! 1. **Intra-engine collapse.** Per `(camera, engine)`, reads are clustered
//!    greedily in timestamp order: a read joins an existing cluster when it is
//!    within `window` of the cluster's latest read (chain-extension) AND its
//!    plate fuzzy-matches the cluster's current best plate under the same
//!    length-scaled Levenshtein model the watchlist uses
//!    ([`db::levenshtein`] within [`db::allowed_edits`] of the longer plate).
//!    This collapses Frigate's self-duplication (it emits a second read for
//!    the same pass as its OCR refines, e.g. `9GXVL98` then `9GXV498` ~5 s
//!    later). Each cluster keeps its single best read: highest confidence,
//!    ties to the latest (most-refined) read.
//! 2. **Cross-engine pairing.** Per camera, the surviving frigate and
//!    crumb-alpr cluster-bests are matched one-to-one, greedily by (a) fuzzy
//!    plate agreement first, then (b) pure time proximity, both bounded by
//!    `window` between cluster start times. Tier (a) keeps two cars that pass
//!    close together correctly paired with their own reads; tier (b) still
//!    pairs a pass where the engines disagree wildly (that disagreement is
//!    exactly what the benchmark needs to surface, so it must not split into
//!    two "miss" passes). Leftover clusters become single-engine passes — an
//!    engine miss.
//!
//! # Pass key
//!
//! A pass's stable identity is `(camera_id, bucket_ts)` where `bucket_ts` is
//! the earliest kept-read timestamp in the pass truncated to whole seconds.
//! Operator confirmations (`lpr_pass_truth`, migration 0070) are stored under
//! that key and re-attached by exact equality. Reads become immutable seconds
//! after a pass ends (Frigate refinements update in-place only while its event
//! is live), so a key derived minutes later is stable in practice; a truth row
//! orphaned by a late refinement is benign (the pass shows unconfirmed again).

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::db;
use crate::types::PlateRead;

/// `plate_reads.source_id` for Frigate's native LPR.
pub const ENGINE_FRIGATE: &str = "frigate";
/// `plate_reads.source_id` for the crumb-alpr fast-alpr worker.
pub const ENGINE_CRUMB: &str = "crumb-alpr";

/// The one read that represents an engine's view of a pass: the
/// highest-confidence read among the engine's collapsed duplicates.
#[derive(Debug, Clone)]
pub struct EngineBest {
    /// `plate_reads.id` of the kept read (for crop/snapshot lookups).
    pub read_id: Uuid,
    /// Normalized plate of the kept read.
    pub plate: String,
    pub confidence: Option<f32>,
    /// Sibling detection event of the kept read, when one exists.
    pub event_id: Option<Uuid>,
    /// Timestamp of the kept read.
    pub ts: DateTime<Utc>,
    /// How many raw reads this engine contributed to the pass (collapsed
    /// duplicates included) — surfaces Frigate's self-duplication rate.
    pub read_count: usize,
}

/// One derived vehicle pass: at most one best read per engine.
#[derive(Debug, Clone)]
pub struct Pass {
    pub camera_id: Uuid,
    /// Stable pass key (with `camera_id`): earliest kept-read ts in the pass,
    /// truncated to whole seconds.
    pub bucket_ts: DateTime<Utc>,
    pub frigate: Option<EngineBest>,
    pub crumb_alpr: Option<EngineBest>,
}

impl Pass {
    /// Whether both engines read this pass and agreed on the normalized plate.
    /// `None` when either engine missed the pass (agreement is undefined).
    #[must_use]
    pub fn agree(&self) -> Option<bool> {
        match (&self.frigate, &self.crumb_alpr) {
            (Some(f), Some(c)) => Some(f.plate == c.plate),
            _ => None,
        }
    }
}

/// Per-engine aggregate over a report window.
#[derive(Debug, Clone, Default)]
pub struct EngineAggregate {
    /// Raw `plate_reads` rows this engine produced in the window (before
    /// duplicate collapse).
    pub total_reads: usize,
    /// Passes in which this engine produced at least one read.
    pub passes_seen: usize,
    /// Mean confidence of this engine's kept best reads (reads with no
    /// reported confidence are excluded). `None` when nothing to average.
    pub avg_confidence: Option<f32>,
    /// `passes_seen / total_passes`; `None` when there are no passes.
    pub hit_rate: Option<f32>,
    /// Passes with an operator-confirmed truth where this engine has a read.
    pub confirmed: usize,
    /// Confirmed passes where this engine's plate equals the true plate.
    pub correct: usize,
    /// `correct / confirmed`; `None` when nothing is confirmed. Measures OCR
    /// correctness when the engine DID read — misses are hit-rate's job.
    pub accuracy: Option<f32>,
}

/// The full A/B aggregate: totals plus one [`EngineAggregate`] per engine.
/// Agreement is symmetric between the engines, so it lives here rather than
/// being duplicated into both engine blocks.
#[derive(Debug, Clone, Default)]
pub struct AbStats {
    pub total_passes: usize,
    /// Passes where both engines produced a read.
    pub both_seen: usize,
    /// Both-seen passes where the normalized plates were identical.
    pub agree: usize,
    /// `agree / both_seen`; `None` when no pass was seen by both.
    pub agreement_rate: Option<f32>,
    pub frigate: EngineAggregate,
    pub crumb_alpr: EngineAggregate,
}

/// Truncate to whole seconds — the pass-key precision (sub-second jitter in
/// the earliest read must not change the key). The confirm endpoint applies
/// the same truncation to the client-echoed key so equality always holds.
#[must_use]
pub fn bucket_key(ts: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::<Utc>::from_timestamp(ts.timestamp(), 0).unwrap_or(ts)
}

/// The existing watchlist fuzzy rule applied symmetrically: two plates match
/// when their Levenshtein distance is within the length-scaled edit budget of
/// the LONGER plate (the more permissive reference — a refinement that adds a
/// character must still match its shorter predecessor).
fn plates_fuzzy_match(a: &str, b: &str, fuzz: f32) -> bool {
    let reference = if a.chars().count() >= b.chars().count() {
        a
    } else {
        b
    };
    db::levenshtein(a, b) <= db::allowed_edits(reference, fuzz)
}

/// One intra-engine cluster being grown in phase 1.
struct Cluster<'a> {
    best: &'a PlateRead,
    min_ts: DateTime<Utc>,
    last_ts: DateTime<Utc>,
    count: usize,
}

impl<'a> Cluster<'a> {
    fn new(read: &'a PlateRead) -> Self {
        Self {
            best: read,
            min_ts: read.ts,
            last_ts: read.ts,
            count: 1,
        }
    }

    fn absorb(&mut self, read: &'a PlateRead) {
        // Higher confidence wins; a missing confidence loses to any reported
        // one; ties go to the later (most-refined) read.
        let cur = self.best.confidence.unwrap_or(-1.0);
        let new = read.confidence.unwrap_or(-1.0);
        if new > cur || ((new - cur).abs() < f32::EPSILON && read.ts >= self.best.ts) {
            self.best = read;
        }
        self.min_ts = self.min_ts.min(read.ts);
        self.last_ts = self.last_ts.max(read.ts);
        self.count += 1;
    }

    fn into_best(self) -> (DateTime<Utc>, EngineBest) {
        (
            self.min_ts,
            EngineBest {
                read_id: self.best.id,
                plate: self.best.plate.clone(),
                confidence: self.best.confidence,
                event_id: self.best.event_id,
                ts: self.best.ts,
                read_count: self.count,
            },
        )
    }
}

/// Cluster `reads` into derived passes. `reads` may arrive in any order and
/// may contain other `source_id`s (ignored); `window_secs` is the maximum gap
/// that chains reads into one pass (and the cross-engine pairing bound);
/// `fuzz` (`0.0..=0.5`) is the length-scaled Levenshtein tolerance used both
/// to collapse an engine's own refinements and to prefer same-plate pairs
/// across engines. Passes are returned newest-first (by `bucket_ts`).
#[must_use]
pub fn pair_passes(reads: &[PlateRead], window_secs: i64, fuzz: f32) -> Vec<Pass> {
    let window = chrono::Duration::seconds(window_secs.max(0));

    // Deterministic processing order: ts asc, then id (stable across calls
    // regardless of how the query returned rows).
    let mut ordered: Vec<&PlateRead> = reads
        .iter()
        .filter(|r| r.source_id == ENGINE_FRIGATE || r.source_id == ENGINE_CRUMB)
        .collect();
    ordered.sort_by(|a, b| a.ts.cmp(&b.ts).then_with(|| a.id.cmp(&b.id)));

    // Phase 1: intra-engine clusters, keyed by (camera, engine-is-frigate).
    let mut clusters: HashMap<(Uuid, bool), Vec<Cluster<'_>>> = HashMap::new();
    for read in ordered {
        let key = (read.camera_id, read.source_id == ENGINE_FRIGATE);
        let bucket = clusters.entry(key).or_default();
        // Candidate clusters: still within the chain window of this read and
        // fuzzy-matching its plate. Among candidates, extend the one touched
        // most recently (the natural "same car still in frame" chain).
        let target = bucket
            .iter_mut()
            .filter(|c| read.ts - c.last_ts <= window)
            .filter(|c| plates_fuzzy_match(&read.plate, &c.best.plate, fuzz))
            .max_by_key(|c| c.last_ts);
        match target {
            Some(c) => c.absorb(read),
            None => bucket.push(Cluster::new(read)),
        }
    }

    // Phase 2: cross-engine pairing per camera.
    let mut per_camera: HashMap<Uuid, (Vec<(DateTime<Utc>, EngineBest)>, Vec<(DateTime<Utc>, EngineBest)>)> =
        HashMap::new();
    for ((camera_id, is_frigate), bucket) in clusters {
        let entry = per_camera.entry(camera_id).or_default();
        let side = if is_frigate { &mut entry.0 } else { &mut entry.1 };
        side.extend(bucket.into_iter().map(Cluster::into_best));
    }

    let mut passes: Vec<Pass> = Vec::new();
    for (camera_id, (frigate, crumb)) in per_camera {
        // Candidate (frigate, crumb) pairs within the window, sorted so
        // same-plate (fuzzy) pairs pair first, then closest-in-time — greedy
        // one-to-one matching over that order.
        let mut candidates: Vec<(u8, i64, usize, usize)> = Vec::new();
        for (fi, (f_ts, f)) in frigate.iter().enumerate() {
            for (ci, (c_ts, c)) in crumb.iter().enumerate() {
                let delta = (*f_ts - *c_ts).num_milliseconds().abs();
                if delta <= window.num_milliseconds() {
                    let tier = u8::from(!plates_fuzzy_match(&f.plate, &c.plate, fuzz));
                    candidates.push((tier, delta, fi, ci));
                }
            }
        }
        candidates.sort_unstable();
        let mut f_used = vec![false; frigate.len()];
        let mut c_used = vec![false; crumb.len()];
        let mut pairs: Vec<(usize, usize)> = Vec::new();
        for (_, _, fi, ci) in candidates {
            if !f_used[fi] && !c_used[ci] {
                f_used[fi] = true;
                c_used[ci] = true;
                pairs.push((fi, ci));
            }
        }
        for (fi, ci) in pairs {
            let (f_ts, f) = frigate[fi].clone();
            let (c_ts, c) = crumb[ci].clone();
            passes.push(Pass {
                camera_id,
                bucket_ts: bucket_key(f_ts.min(c_ts)),
                frigate: Some(f),
                crumb_alpr: Some(c),
            });
        }
        for (fi, (f_ts, f)) in frigate.iter().enumerate() {
            if !f_used[fi] {
                passes.push(Pass {
                    camera_id,
                    bucket_ts: bucket_key(*f_ts),
                    frigate: Some(f.clone()),
                    crumb_alpr: None,
                });
            }
        }
        for (ci, (c_ts, c)) in crumb.iter().enumerate() {
            if !c_used[ci] {
                passes.push(Pass {
                    camera_id,
                    bucket_ts: bucket_key(*c_ts),
                    frigate: None,
                    crumb_alpr: Some(c.clone()),
                });
            }
        }
    }

    // Newest-first, deterministic tie-break by camera.
    passes.sort_by(|a, b| {
        b.bucket_ts
            .cmp(&a.bucket_ts)
            .then_with(|| a.camera_id.cmp(&b.camera_id))
    });
    passes
}

/// Look up the confirmed truth for a pass: exact `(camera_id, bucket_ts)` key.
#[must_use]
pub fn truth_for<'a>(
    pass: &Pass,
    truths: &'a HashMap<(Uuid, DateTime<Utc>), String>,
) -> Option<&'a String> {
    truths.get(&(pass.camera_id, pass.bucket_ts))
}

/// Whether an engine's best read for a pass matches the confirmed truth.
/// `None` when the engine missed the pass or no truth is confirmed.
#[must_use]
pub fn engine_correct(best: Option<&EngineBest>, truth: Option<&String>) -> Option<bool> {
    match (best, truth) {
        (Some(b), Some(t)) => Some(&b.plate == t),
        _ => None,
    }
}

/// Aggregate the full A/B stats over ALL passes in the window (callers
/// paginate the pass list separately so the stats never depend on the page).
/// `reads` is the same raw slice given to [`pair_passes`] (for per-engine raw
/// totals); `truths` maps `(camera_id, bucket_ts)` to the normalized true
/// plate.
#[must_use]
#[allow(clippy::cast_precision_loss)]
pub fn compute_stats(
    reads: &[PlateRead],
    passes: &[Pass],
    truths: &HashMap<(Uuid, DateTime<Utc>), String>,
) -> AbStats {
    let mut stats = AbStats {
        total_passes: passes.len(),
        ..AbStats::default()
    };
    stats.frigate.total_reads = reads.iter().filter(|r| r.source_id == ENGINE_FRIGATE).count();
    stats.crumb_alpr.total_reads = reads.iter().filter(|r| r.source_id == ENGINE_CRUMB).count();

    let mut f_conf: (f64, usize) = (0.0, 0);
    let mut c_conf: (f64, usize) = (0.0, 0);
    for pass in passes {
        let truth = truth_for(pass, truths);
        if let Some(f) = &pass.frigate {
            stats.frigate.passes_seen += 1;
            if let Some(c) = f.confidence {
                f_conf.0 += f64::from(c);
                f_conf.1 += 1;
            }
            if let Some(correct) = engine_correct(pass.frigate.as_ref(), truth) {
                stats.frigate.confirmed += 1;
                stats.frigate.correct += usize::from(correct);
            }
        }
        if let Some(c) = &pass.crumb_alpr {
            stats.crumb_alpr.passes_seen += 1;
            if let Some(conf) = c.confidence {
                c_conf.0 += f64::from(conf);
                c_conf.1 += 1;
            }
            if let Some(correct) = engine_correct(pass.crumb_alpr.as_ref(), truth) {
                stats.crumb_alpr.confirmed += 1;
                stats.crumb_alpr.correct += usize::from(correct);
            }
        }
        if let Some(agree) = pass.agree() {
            stats.both_seen += 1;
            stats.agree += usize::from(agree);
        }
    }

    let ratio = |num: usize, den: usize| -> Option<f32> {
        (den > 0).then(|| num as f32 / den as f32)
    };
    stats.frigate.hit_rate = ratio(stats.frigate.passes_seen, stats.total_passes);
    stats.crumb_alpr.hit_rate = ratio(stats.crumb_alpr.passes_seen, stats.total_passes);
    stats.agreement_rate = ratio(stats.agree, stats.both_seen);
    stats.frigate.accuracy = ratio(stats.frigate.correct, stats.frigate.confirmed);
    stats.crumb_alpr.accuracy = ratio(stats.crumb_alpr.correct, stats.crumb_alpr.confirmed);
    if f_conf.1 > 0 {
        stats.frigate.avg_confidence = Some((f_conf.0 / f_conf.1 as f64) as f32);
    }
    if c_conf.1 > 0 {
        stats.crumb_alpr.avg_confidence = Some((c_conf.0 / c_conf.1 as f64) as f32);
    }
    stats
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_read(
        camera: Uuid,
        source: &str,
        plate: &str,
        confidence: Option<f32>,
        ts: DateTime<Utc>,
    ) -> PlateRead {
        PlateRead {
            id: Uuid::new_v4(),
            camera_id: camera,
            ts,
            plate: plate.to_owned(),
            plate_raw: Some(plate.to_owned()),
            confidence,
            region: None,
            source_id: source.to_owned(),
            event_id: Some(Uuid::new_v4()),
            snapshot_url: None,
            bbox: None,
        }
    }

    fn t0() -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(1_760_000_000, 0).unwrap()
    }

    fn secs(s: i64) -> chrono::Duration {
        chrono::Duration::seconds(s)
    }

    /// Frigate's real-world self-duplication (two reads of one pass, ~5 s
    /// apart, one character apart as its OCR refines) collapses into a single
    /// pass carrying the higher-confidence refinement.
    #[test]
    fn intra_engine_duplicates_collapse() {
        let cam = Uuid::new_v4();
        let reads = vec![
            mk_read(cam, ENGINE_FRIGATE, "9GXVL98", Some(0.70), t0()),
            mk_read(cam, ENGINE_FRIGATE, "9GXV498", Some(0.87), t0() + secs(5)),
        ];
        let passes = pair_passes(&reads, 8, 0.25);
        assert_eq!(passes.len(), 1, "one physical pass, not two");
        let f = passes[0].frigate.as_ref().expect("frigate best kept");
        assert_eq!(f.plate, "9GXV498", "higher-confidence refinement wins");
        assert_eq!(f.read_count, 2, "both raw reads counted");
        assert!(passes[0].crumb_alpr.is_none());
        assert_eq!(passes[0].bucket_ts, t0(), "bucket = earliest read ts");
    }

    /// Both engines read the same car → one pass with both bests, agreement.
    #[test]
    fn cross_engine_pairing_and_agreement() {
        let cam = Uuid::new_v4();
        let reads = vec![
            mk_read(cam, ENGINE_FRIGATE, "9GXVL98", Some(0.70), t0()),
            mk_read(cam, ENGINE_FRIGATE, "9GXV498", Some(0.87), t0() + secs(5)),
            mk_read(cam, ENGINE_CRUMB, "9GXV498", Some(0.99), t0() + secs(1)),
        ];
        let passes = pair_passes(&reads, 8, 0.25);
        assert_eq!(passes.len(), 1);
        let p = &passes[0];
        assert_eq!(p.frigate.as_ref().unwrap().plate, "9GXV498");
        assert_eq!(p.crumb_alpr.as_ref().unwrap().plate, "9GXV498");
        assert_eq!(p.agree(), Some(true));

        let stats = compute_stats(&reads, &passes, &HashMap::new());
        assert_eq!(stats.total_passes, 1);
        assert_eq!(stats.both_seen, 1);
        assert_eq!(stats.agreement_rate, Some(1.0));
        assert_eq!(stats.frigate.total_reads, 2);
        assert_eq!(stats.crumb_alpr.total_reads, 1);
        assert_eq!(stats.frigate.hit_rate, Some(1.0));
        assert_eq!(stats.crumb_alpr.hit_rate, Some(1.0));
        // Avg confidence is over KEPT bests (0.87 / 0.99), not raw reads.
        assert!((stats.frigate.avg_confidence.unwrap() - 0.87).abs() < 1e-6);
        assert!((stats.crumb_alpr.avg_confidence.unwrap() - 0.99).abs() < 1e-6);
    }

    /// Engines disagreeing beyond the fuzzy budget still pair by time — the
    /// disagreement must surface as one pass, not split into two misses.
    #[test]
    fn cross_engine_disagreement_still_pairs() {
        let cam = Uuid::new_v4();
        let reads = vec![
            mk_read(cam, ENGINE_FRIGATE, "ABC123", Some(0.80), t0()),
            mk_read(cam, ENGINE_CRUMB, "XYZ789", Some(0.90), t0() + secs(2)),
        ];
        let passes = pair_passes(&reads, 8, 0.25);
        assert_eq!(passes.len(), 1, "time-proximity pairs a wild disagreement");
        assert_eq!(passes[0].agree(), Some(false));
        let stats = compute_stats(&reads, &passes, &HashMap::new());
        assert_eq!(stats.both_seen, 1);
        assert_eq!(stats.agreement_rate, Some(0.0));
    }

    /// One engine missing → single-engine pass; hit rates reflect the miss.
    #[test]
    fn engine_miss_is_a_single_engine_pass() {
        let cam = Uuid::new_v4();
        let reads = vec![
            mk_read(cam, ENGINE_FRIGATE, "ABC123", Some(0.8), t0()),
            mk_read(cam, ENGINE_FRIGATE, "DDD888", Some(0.9), t0() + secs(600)),
            mk_read(cam, ENGINE_CRUMB, "DDD888", Some(0.95), t0() + secs(601)),
        ];
        let passes = pair_passes(&reads, 8, 0.25);
        assert_eq!(passes.len(), 2);
        let stats = compute_stats(&reads, &passes, &HashMap::new());
        assert_eq!(stats.total_passes, 2);
        assert_eq!(stats.frigate.passes_seen, 2);
        assert_eq!(stats.crumb_alpr.passes_seen, 1);
        assert_eq!(stats.frigate.hit_rate, Some(1.0));
        assert_eq!(stats.crumb_alpr.hit_rate, Some(0.5));
        assert_eq!(stats.both_seen, 1);
    }

    /// Two different cars inside one window: the fuzzy-plate pairing tier
    /// keeps each engine's reads attached to the right car even though every
    /// cross combination is within the time window.
    #[test]
    fn two_cars_in_window_pair_by_plate() {
        let cam = Uuid::new_v4();
        let reads = vec![
            mk_read(cam, ENGINE_FRIGATE, "AAA111", Some(0.8), t0()),
            mk_read(cam, ENGINE_CRUMB, "BBB999", Some(0.9), t0() + secs(1)),
            mk_read(cam, ENGINE_FRIGATE, "BBB999", Some(0.8), t0() + secs(3)),
            mk_read(cam, ENGINE_CRUMB, "AAA111", Some(0.9), t0() + secs(4)),
        ];
        let passes = pair_passes(&reads, 8, 0.25);
        assert_eq!(passes.len(), 2, "two cars, two passes");
        for p in &passes {
            assert_eq!(
                p.agree(),
                Some(true),
                "each engine pair must land on the same car: {p:?}"
            );
        }
    }

    /// The same plate re-appearing outside the window is a separate pass.
    #[test]
    fn window_separates_repeat_visits() {
        let cam = Uuid::new_v4();
        let reads = vec![
            mk_read(cam, ENGINE_FRIGATE, "ABC123", Some(0.8), t0()),
            mk_read(cam, ENGINE_FRIGATE, "ABC123", Some(0.9), t0() + secs(300)),
        ];
        let passes = pair_passes(&reads, 8, 0.25);
        assert_eq!(passes.len(), 2, "outside the window = a new visit");
    }

    /// Accuracy against operator-confirmed truth: correct iff the engine's
    /// normalized plate equals the normalized true plate.
    #[test]
    fn accuracy_with_confirmed_truth() {
        let cam = Uuid::new_v4();
        let reads = vec![
            mk_read(cam, ENGINE_FRIGATE, "9GXV498", Some(0.87), t0()),
            mk_read(cam, ENGINE_CRUMB, "9GXVL98", Some(0.99), t0() + secs(1)),
        ];
        let passes = pair_passes(&reads, 8, 0.25);
        assert_eq!(passes.len(), 1);
        let mut truths = HashMap::new();
        truths.insert((cam, passes[0].bucket_ts), "9GXVL98".to_owned());

        assert_eq!(
            engine_correct(passes[0].frigate.as_ref(), truth_for(&passes[0], &truths)),
            Some(false)
        );
        assert_eq!(
            engine_correct(
                passes[0].crumb_alpr.as_ref(),
                truth_for(&passes[0], &truths)
            ),
            Some(true)
        );

        let stats = compute_stats(&reads, &passes, &truths);
        assert_eq!(stats.frigate.confirmed, 1);
        assert_eq!(stats.frigate.correct, 0);
        assert_eq!(stats.frigate.accuracy, Some(0.0));
        assert_eq!(stats.crumb_alpr.confirmed, 1);
        assert_eq!(stats.crumb_alpr.correct, 1);
        assert_eq!(stats.crumb_alpr.accuracy, Some(1.0));
        // An unconfirmed pass elsewhere contributes nothing to accuracy.
        assert_eq!(stats.agreement_rate, Some(0.0));
    }

    /// Sub-second jitter in the earliest read never changes the pass key.
    #[test]
    fn bucket_ts_truncates_to_seconds() {
        let cam = Uuid::new_v4();
        let jittered = DateTime::<Utc>::from_timestamp(1_760_000_000, 730_000_000).unwrap();
        let reads = vec![mk_read(cam, ENGINE_CRUMB, "ABC123", Some(0.9), jittered)];
        let passes = pair_passes(&reads, 8, 0.25);
        assert_eq!(passes[0].bucket_ts, t0());
    }

    /// Reads from engines outside the benchmark (e.g. a future third source)
    /// are ignored rather than polluting the pairing.
    #[test]
    fn foreign_sources_are_ignored() {
        let cam = Uuid::new_v4();
        let reads = vec![mk_read(cam, "openalpr", "ABC123", Some(0.9), t0())];
        assert!(pair_passes(&reads, 8, 0.25).is_empty());
    }

    /// Zero fuzz degrades gracefully: only exact-equal plates chain, so the
    /// refinement dup becomes two passes (documented trade-off, not a crash).
    #[test]
    fn zero_fuzz_is_exact_chaining() {
        let cam = Uuid::new_v4();
        let reads = vec![
            mk_read(cam, ENGINE_FRIGATE, "9GXVL98", Some(0.70), t0()),
            mk_read(cam, ENGINE_FRIGATE, "9GXV498", Some(0.87), t0() + secs(5)),
        ];
        let passes = pair_passes(&reads, 8, 0.0);
        assert_eq!(passes.len(), 2);
    }
}
