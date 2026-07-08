// SPDX-License-Identifier: AGPL-3.0-or-later

//! Background thumbnail pre-generation worker (Phase 1).
//!
//! Off by default (`THUMB_PREGEN_ENABLED`). When on, it rolls forward over each
//! enabled camera's recently-recorded footage, extracting a thumbnail per grid
//! slot so timeline scrubbing is fast on the FIRST touch, not just on revisit.
//!
//! It shares the grid interval, the cache path, the singleflight lock, and the
//! extraction semaphore with the on-demand request path
//! ([`crate::filmstrip::ensure_thumbnail`]), so the worker and live requests
//! never double-extract or fight over resources.
//!
//! Cost note: the FIRST pass backfills `THUMB_PREGEN_LOOKBACK_HOURS` of history
//! sequentially (gentle, one extraction in flight at a time); steady state only
//! generates the handful of new slots recorded since the previous scan.

use std::collections::HashMap;

use chrono::{Duration, TimeZone, Utc};
use uuid::Uuid;

use crumb_common::db;

use crate::{filmstrip, state::AppState};

/// Run the pre-generation loop. Returns immediately (after logging) when the
/// feature is disabled, so it is always safe to spawn.
pub async fn run(state: AppState) {
    let (enabled, width, lookback_hours, scan_secs) = {
        let cfg = state.config();
        (
            cfg.thumb_pregen_enabled,
            cfg.thumb_pregen_width,
            cfg.thumb_pregen_lookback_hours,
            cfg.thumb_pregen_scan_secs,
        )
    };
    if !enabled {
        tracing::info!("thumb pre-generation: disabled (THUMB_PREGEN_ENABLED unset)");
        return;
    }

    let grid_ms = filmstrip::DEFAULT_THUMB_INTERVAL_SECS * 1000;
    let lookback_ms = Duration::hours(lookback_hours).num_milliseconds();
    let scan = std::time::Duration::from_secs(scan_secs);
    tracing::info!(
        grid_secs = filmstrip::DEFAULT_THUMB_INTERVAL_SECS,
        width,
        lookback_hours,
        scan_secs,
        "thumb pre-generation: started"
    );

    // Per-camera high-water mark: the newest instant we've generated up to.
    let mut watermark: HashMap<Uuid, i64> = HashMap::new();

    loop {
        let now_ms = Utc::now().timestamp_millis();
        let cameras = match db::list_enabled_cameras(state.pool()).await {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!(error = %e, "thumb pre-gen: listing cameras failed");
                tokio::time::sleep(scan).await;
                continue;
            }
        };

        for cam in &cameras {
            let from_ms = watermark
                .get(&cam.id)
                .copied()
                .unwrap_or(now_ms - lookback_ms);
            // Floor the start to the grid; step forward one slot at a time.
            let mut slot = from_ms.div_euclid(grid_ms) * grid_ms;
            let mut steps: u64 = 0;
            while slot < now_ms {
                if let Some(ts) = Utc.timestamp_millis_opt(slot).single() {
                    // No-op if already cached; a gap (NotFound) is fine — the
                    // on-demand path self-heals if the user ever scrubs there.
                    let _ = filmstrip::ensure_thumbnail(&state, cam.id, ts, width).await;
                }
                slot += grid_ms;
                steps += 1;
                // Yield periodically so a large initial backfill can't monopolize
                // the runtime between the semaphore-bounded extractions.
                if steps.is_multiple_of(64) {
                    tokio::task::yield_now().await;
                }
            }
            watermark.insert(cam.id, now_ms);
        }

        tokio::time::sleep(scan).await;
    }
}
