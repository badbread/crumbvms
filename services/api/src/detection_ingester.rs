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
        get_lpr_settings, normalize_plate, upsert_detection_event, upsert_plate_read,
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
            let params = UpsertPlateReadParams {
                camera_id: ev.camera_id,
                ts: ev.start_ts,
                plate: normalized,
                plate_raw: Some(plate_raw.to_owned()),
                // Prefer a plate-specific score; else the object's top score.
                confidence: ev.plate_confidence.or(Some(ev.top_score)),
                source_id: ev.source_id.clone(),
                provider_event_id: Some(ev.provider_event_id.clone()),
                event_id: Some(event_id),
                snapshot_url: ev.snapshot_url.clone(),
                raw: ev.raw.clone(),
            };
            match upsert_plate_read(pool, &params).await {
                Ok(id) => tracing::debug!(
                    plate_read_id = %id,
                    plate = %plate_raw,
                    camera = %ev.camera_id,
                    "detection ingester: recorded plate read"
                ),
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
