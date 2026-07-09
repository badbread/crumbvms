// SPDX-License-Identifier: AGPL-3.0-or-later

//! Background thumbnail pre-generation worker (Phase 1; live-reload, issue #10).
//!
//! Off by default (`THUMB_PREGEN_ENABLED`, or the admin-console "Scrub
//! previews" toggle). When on, it rolls forward over each enabled camera's
//! recently-recorded footage, extracting a thumbnail per grid slot so timeline
//! scrubbing is fast on the FIRST touch, not just on revisit.
//!
//! It shares the grid interval, the cache path, the singleflight lock, and the
//! extraction semaphore with the on-demand request path
//! ([`crate::filmstrip::ensure_thumbnail`]), so the worker and live requests
//! never double-extract or fight over resources.
//!
//! Slot selection is coverage-aware: `db::list_thumbnail_times` intersects the
//! fixed grid with recorded `segments` coverage, so a recording gap never
//! produces a slot here in the first place (issue #9) — no wasted ffmpeg spawn
//! that can only 404.
//!
//! Cost note: the FIRST pass backfills `pregen_lookback_hours` of history
//! sequentially (gentle, one extraction in flight at a time); steady state only
//! generates the handful of new slots recorded since the previous scan.
//!
//! # Live-reload (issue #10)
//!
//! Unlike the original Phase 1 version, this worker never exits when
//! disabled: it loops forever, calling [`crate::scrub_settings::resolve`] at
//! the top of every cycle so an admin-console change (enable/disable, or any
//! of the four tunable knobs) takes effect without a restart:
//!
//! * **Enable** takes effect within one `pregen_scan_secs` (idling ticks just
//!   cost a single settings SELECT).
//! * **Disable** takes effect within seconds even mid-backfill: the pass
//!   re-checks the effective `pregen_enabled` between cameras and every 256
//!   extracted slots within one camera, abandoning immediately on a `false`.
//! * **Disable → enable** clears the per-camera watermark map (D3), so a
//!   re-enable always starts a fresh `pregen_lookback_hours` backfill rather
//!   than grinding through the entire disabled gap.
//! * A settings-resolve failure keeps the last-known-good values and logs a
//!   `warn!` — a transient DB blip must never kill this background loop.
//!
//! `THUMB_PREGEN_WIDTH` stays the boot-time `ApiConfig` value throughout (D1,
//! env-only) — it is never resolved per cycle.

use std::collections::HashMap;

use chrono::{Duration, TimeZone, Utc};
use uuid::Uuid;

use crumb_common::db;

use crate::{filmstrip, scrub_settings::ScrubSettings, state::AppState};

/// Run the live-reloading pre-generation loop. Never returns; always safe to
/// spawn unconditionally (an idle/disabled tick costs one settings SELECT).
pub async fn run(state: AppState) {
    tracing::info!(
        "thumb pre-generation: worker started (settings resolved fresh each cycle; \
         admin console: Server settings > Scrub previews)"
    );

    // Per-camera high-water mark: the newest instant we've generated up to.
    let mut watermark: HashMap<Uuid, i64> = HashMap::new();
    // Last known good settings — used verbatim, unchanged, whenever a
    // resolve fails (keep-last-known-values policy). Seeded from the env
    // defaults so the very first cycle has something sane even if the very
    // first resolve fails.
    let mut current = ScrubSettings::from_env(state.config());
    // `None` until the first successful resolve, so the initial state is
    // always logged (via `Some(prev) != Some(now)`) without treating it as an
    // enabled -> disabled TRANSITION (nothing was running before it).
    let mut was_enabled: Option<bool> = None;

    loop {
        match crate::scrub_settings::resolve(state.pool(), state.config()).await {
            Ok(s) => current = s,
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "thumb pre-gen: settings resolve failed; keeping last-known values"
                );
            }
        }

        if let Some(prev) = was_enabled {
            if should_clear_watermark_on_transition(prev, current.pregen_enabled) {
                tracing::info!(
                    "thumb pre-generation: disabled; watermarks cleared \
                     (re-enable will start a fresh lookback backfill)"
                );
                watermark.clear();
            }
        }
        if was_enabled != Some(current.pregen_enabled) {
            if current.pregen_enabled {
                tracing::info!(
                    grid_secs = filmstrip::DEFAULT_THUMB_INTERVAL_SECS,
                    width = state.config().thumb_pregen_width,
                    lookback_hours = current.pregen_lookback_hours,
                    scan_secs = current.pregen_scan_secs,
                    "thumb pre-generation: enabled"
                );
            } else {
                tracing::info!(
                    "thumb pre-generation: disabled (enable it in the admin console, \
                     Server settings > Scrub previews, or THUMB_PREGEN_ENABLED)"
                );
            }
        }
        was_enabled = Some(current.pregen_enabled);

        if current.pregen_enabled {
            run_backfill_cycle(&state, &current, &mut watermark).await;
        }

        tokio::time::sleep(std::time::Duration::from_secs(current.pregen_scan_secs)).await;
    }
}

/// Whether the per-camera watermark map must be cleared given the previous
/// and newly-resolved `pregen_enabled` state (D3): only on an actual
/// enabled -> disabled transition, never on disabled -> enabled (that's the
/// normal "start backfilling" case) and never when the state didn't change.
fn should_clear_watermark_on_transition(was_enabled: bool, now_enabled: bool) -> bool {
    was_enabled && !now_enabled
}

/// Re-check the effective `pregen_enabled` state via a fresh settings
/// resolve (a single 1-row `server_settings` SELECT). Used as the
/// mid-backfill kill switch so a console "disable" lands within seconds
/// instead of waiting for the whole cycle to finish.
///
/// Fails OPEN (`true`) on a resolve error: this is only a *faster* disable
/// path — the outer per-cycle resolve in [`run`] already logs the failure and
/// will re-check (and, if still disabled, stop cleanly) next cycle regardless.
async fn recheck_enabled(state: &AppState) -> bool {
    match crate::scrub_settings::resolve(state.pool(), state.config()).await {
        Ok(s) => s.pregen_enabled,
        Err(_) => true,
    }
}

/// Run one backfill/catch-up pass over every enabled camera, using the
/// resolved `settings` for this cycle. Re-checks `pregen_enabled` between
/// cameras and every 256 extracted slots within a camera so a console
/// "disable" mid-pass is honored within seconds, not after the whole cycle
/// completes.
async fn run_backfill_cycle(
    state: &AppState,
    settings: &ScrubSettings,
    watermark: &mut HashMap<Uuid, i64>,
) {
    let now_ms = Utc::now().timestamp_millis();
    let Some(until) = Utc.timestamp_millis_opt(now_ms).single() else {
        // Should be unreachable (Utc::now() is always in range); skip this
        // cycle rather than panic a background worker over a clock oddity.
        return;
    };
    let lookback_ms = Duration::hours(settings.pregen_lookback_hours).num_milliseconds();
    let width = state.config().thumb_pregen_width;

    let cameras = match db::list_enabled_cameras(state.pool()).await {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(error = %e, "thumb pre-gen: listing cameras failed");
            return;
        }
    };

    for cam in &cameras {
        // Mid-backfill kill switch: re-check BETWEEN cameras so a toggle-off
        // during a large multi-camera pass is honored within one camera, not
        // after every camera finishes.
        if !recheck_enabled(state).await {
            tracing::info!("thumb pre-generation: disabled mid-cycle; abandoning this pass");
            return;
        }

        let from_ms = watermark
            .get(&cam.id)
            .copied()
            .unwrap_or(now_ms - lookback_ms);
        let Some(since) = Utc.timestamp_millis_opt(from_ms).single() else {
            continue;
        };
        if since >= until {
            watermark.insert(cam.id, now_ms);
            continue;
        }

        // Coverage-aware grid slots: gap slots (no recorded footage) are
        // already excluded, so every extraction below has real footage to
        // read.
        let slots = match db::list_thumbnail_times(
            state.pool(),
            cam.id,
            since,
            until,
            filmstrip::DEFAULT_THUMB_INTERVAL_SECS,
        )
        .await
        {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    camera_id = %cam.id,
                    error = %e,
                    "thumb pre-gen: listing thumbnail times failed"
                );
                continue;
            }
        };

        let mut steps: u64 = 0;
        for ts in slots {
            // No-op if already cached.
            let _ = filmstrip::ensure_thumbnail(state, cam.id, ts, width).await;
            steps += 1;
            // Yield periodically so a large initial backfill can't monopolize
            // the runtime between the semaphore-bounded extractions.
            if steps.is_multiple_of(64) {
                tokio::task::yield_now().await;
            }
            // Mid-backfill kill switch: also re-check WITHIN one camera's
            // backfill (a 4x multiple of the yield cadence above), so a huge
            // single-camera initial pass (e.g. a long lookback) still honors
            // a toggle-off in seconds rather than only after that camera
            // finishes.
            if steps.is_multiple_of(256) && !recheck_enabled(state).await {
                tracing::info!(
                    camera_id = %cam.id,
                    "thumb pre-generation: disabled mid-backfill; abandoning this camera's pass"
                );
                return;
            }
        }
        watermark.insert(cam.id, now_ms);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watermark_clears_only_on_enabled_to_disabled_transition() {
        assert!(
            should_clear_watermark_on_transition(true, false),
            "an actual enabled -> disabled transition must clear (D3)"
        );
        assert!(
            !should_clear_watermark_on_transition(false, true),
            "disabled -> enabled is a normal backfill start, not a clear trigger"
        );
        assert!(
            !should_clear_watermark_on_transition(true, true),
            "no transition (stayed enabled) must never clear"
        );
        assert!(
            !should_clear_watermark_on_transition(false, false),
            "no transition (stayed disabled) must never clear"
        );
    }
}
