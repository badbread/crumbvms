// SPDX-License-Identifier: AGPL-3.0-or-later

//! Detection-event ingester background task.
//!
//! Consumes [`NormalizedEvent`]s from the shared `mpsc` channel produced by
//! detection providers and upserts them into the `events` table.
//!
//! # Deduplication
//!
//! The upsert uses `ON CONFLICT (source_id, provider_event_id) WHERE source_id
//! IS NOT NULL DO UPDATE` so replaying MQTT messages or HTTP backfill is
//! idempotent.  The first `update` (snapshot available) INSERTs; the `end`
//! message UPDATEs `end_ts`, `top_score`, and `lifecycle`.
//!
//! # Error handling
//!
//! Individual upsert failures are logged at WARN and the ingester continues.
//! Only a closed channel (sender side dropped) causes the task to exit.

use deadpool_postgres::Pool;
use tokio::sync::mpsc;
use tracing::{info, warn};

use crumb_common::{
    db::{
        get_lpr_settings, insert_system_event_with_snapshot, is_plate_ignored, mark_plate_alerted,
        match_watchlist, normalize_plate, upsert_detection_event, upsert_plate_read,
        UpsertDetectionEventParams, UpsertPlateReadParams,
    },
    detection::NormalizedEvent,
};

/// Run the detection-event ingester loop.
///
/// Receives [`NormalizedEvent`]s from `rx` until the channel is closed (all
/// senders have been dropped), persisting each event via an upsert.
///
/// This function is intended to be spawned with `tokio::spawn`.  It exits
/// cleanly when the channel closes; callers do not need to cancel it manually.
pub async fn run(mut rx: mpsc::Receiver<NormalizedEvent>, pool: Pool) {
    info!("detection ingester: started");

    while let Some(ev) = rx.recv().await {
        let params = UpsertDetectionEventParams {
            camera_id: ev.camera_id,
            start_ts: ev.start_ts,
            label: ev.label.as_str().to_owned(),
            score: ev.score,
            source_id: ev.source_id.clone(),
            provider_event_id: ev.provider_event_id.clone(),
            sub_label: ev.sub_label.clone(),
            top_score: ev.top_score,
            end_ts: ev.end_ts,
            zones: ev.zones.clone(),
            snapshot_url: ev.snapshot_url.clone(),
            raw: ev.raw.clone(),
            lifecycle: ev.lifecycle.as_str().to_owned(),
        };

        match upsert_detection_event(&pool, &params).await {
            Ok(id) => {
                tracing::debug!(
                    event_id = %id,
                    source = %ev.source_id,
                    provider_event_id = %ev.provider_event_id,
                    label = %ev.label.as_str(),
                    lifecycle = %ev.lifecycle.as_str(),
                    "detection ingester: upserted event"
                );
                // LPR: if this event carries a plate and capture is enabled,
                // record it in the plate-domain store beside the events row.
                if let Some(plate) = ev.plate_string() {
                    maybe_record_plate(&pool, &ev, id, &plate).await;
                }
            }
            Err(e) => {
                warn!(
                    error = %e,
                    source = %ev.source_id,
                    provider_event_id = %ev.provider_event_id,
                    "detection ingester: upsert failed"
                );
            }
        }
    }

    info!("detection ingester: channel closed, exiting");
}

/// Record a plate read for an event that carried one, but only when LPR capture
/// is enabled (`lpr_config.enabled`). Off by default, so enabling Frigate
/// detections alone never silently builds a plate database. The read is deduped
/// on `(source_id, provider_event_id)` and linked to its sibling `events` row
/// via `event_id`. Best-effort: failures are logged, never fatal to ingestion.
async fn maybe_record_plate(
    pool: &Pool,
    ev: &NormalizedEvent,
    event_id: uuid::Uuid,
    plate_raw: &str,
) {
    let normalized = normalize_plate(plate_raw);
    if normalized.is_empty() {
        return; // OCR noise / non-alphanumeric — nothing worth storing
    }
    match get_lpr_settings(pool).await {
        Ok(Some(cfg)) if cfg.enabled => {
            // Ignore-list (migration 0054): a plate on an `ignore` entry is
            // dropped entirely — not stored, never alerted. The pragmatic
            // backstop for a nuisance plate (e.g. a parked car Frigate keeps
            // reading) when Frigate-side object masking isn't practical.
            match is_plate_ignored(pool, &normalized, cfg.watchlist_fuzz).await {
                Ok(true) => {
                    tracing::debug!(plate = %plate_raw, camera = %ev.camera_id, "detection ingester: plate ignored (ignore-list) — dropped");
                    return;
                }
                Ok(false) => {}
                Err(e) => warn!(error = %e, "detection ingester: is_plate_ignored failed"),
            }
            let params = UpsertPlateReadParams {
                camera_id: ev.camera_id,
                ts: ev.start_ts,
                plate: normalized.clone(),
                plate_raw: Some(plate_raw.to_owned()),
                // ONLY the plate-specific OCR score. NOT the object's top_score:
                // that's the *vehicle* detection confidence (often 0.9+), and
                // storing it as plate confidence would green-light a mediocre OCR
                // read (and the upsert's GREATEST would keep the inflated value
                // forever). NULL when the engine gives no plate score — clients
                // render that as "—".
                confidence: ev.plate_confidence,
                source_id: ev.source_id.clone(),
                provider_event_id: Some(ev.provider_event_id.clone()),
                event_id: Some(event_id),
                snapshot_url: ev.snapshot_url.clone(),
                // Plate crop box, normalized [x, y, w, h] fractions of the
                // snapshot frame (None when the provider gave none / it couldn't
                // be normalized). Best-effort, purely additive.
                bbox: ev.plate_box,
                raw: ev.raw.clone(),
            };
            match upsert_plate_read(pool, &params).await {
                Ok(up) => {
                    tracing::debug!(
                        plate_read_id = %up.id,
                        plate = %plate_raw,
                        camera = %ev.camera_id,
                        inserted = up.inserted,
                        "detection ingester: recorded plate read"
                    );
                    // Check the watchlist on every read (insert AND lifecycle
                    // refinement), gated on the row's persisted `alerted` flag so
                    // it fires exactly once — but still catches a plate that only
                    // becomes the watchlisted value on a later refinement UPDATE
                    // (a misread that converges onto the BOLO plate mid-pass).
                    if !up.alerted {
                        maybe_alert_watchlist(pool, ev, &normalized, up.id, cfg.watchlist_fuzz)
                            .await;
                    }
                }
                Err(e) => warn!(
                    error = %e,
                    source = %ev.source_id,
                    "detection ingester: plate_read upsert failed"
                ),
            }
        }
        Ok(_) => { /* LPR disabled — capture nothing */ }
        Err(e) => warn!(error = %e, "detection ingester: get_lpr_settings failed"),
    }
}

/// Emit a `plate_watchlist_hit` system event when the just-recorded plate
/// matches a notifying watchlist entry, then mark the read `alerted` so a later
/// refinement UPDATE of the same row cannot re-fire. The notification engine
/// (`notifications.rs`) fans it out over the configured channels and prepends
/// the camera name, so the detail here carries only the plate-specific facts.
/// Best-effort: a lookup/insert failure is logged, never fatal to ingestion.
async fn maybe_alert_watchlist(
    pool: &Pool,
    ev: &NormalizedEvent,
    normalized: &str,
    plate_read_id: uuid::Uuid,
    fuzz: f32,
) {
    let entry = match match_watchlist(pool, normalized, fuzz).await {
        Ok(Some(e)) => e,
        Ok(None) => return, // not watchlisted (or notify disabled) — leave `alerted` false
        Err(e) => {
            warn!(error = %e, "detection ingester: match_watchlist failed");
            return;
        }
    };

    let label = entry
        .label
        .as_deref()
        .filter(|l| !l.is_empty())
        .map(|l| format!(" (\"{l}\")"))
        .unwrap_or_default();
    let conf = ev
        .plate_confidence
        .map_or_else(|| "—".to_owned(), |c| format!("{:.0}%", c * 100.0));
    let detail = format!(
        "watchlisted plate {plate}{label} seen (confidence {conf})",
        plate = entry.plate
    );

    // Carry the detection snapshot (the car+plate frame) so image-capable
    // notification channels can attach it — the notification engine resolves +
    // fetches it, gated by each channel's own `include_snapshot` toggle.
    if let Err(e) = insert_system_event_with_snapshot(
        pool,
        "plate_watchlist_hit",
        Some(ev.camera_id),
        Some(&detail),
        ev.snapshot_url.as_deref(),
    )
    .await
    {
        // Leave `alerted` false so a later refinement UPDATE retries the alert.
        warn!(error = %e, "detection ingester: insert_system_event(plate_watchlist_hit) failed");
        return;
    }
    info!(plate = %entry.plate, camera = %ev.camera_id, "detection ingester: watchlist hit alerted");
    // Latch the row so a subsequent lifecycle UPDATE of the same read (or a
    // re-processed MQTT message) does not re-fire the alert.
    if let Err(e) = mark_plate_alerted(pool, plate_read_id).await {
        warn!(error = %e, "detection ingester: mark_plate_alerted failed");
    }
}
