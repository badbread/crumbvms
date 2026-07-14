// SPDX-License-Identifier: AGPL-3.0-or-later

//! Frigate detection-event provider.
//!
//! Implements [`DetectionSource`] by subscribing to the `frigate/events` MQTT
//! topic and (on startup) fetching recent events via Frigate's HTTP API for
//! gap recovery.
//!
//! # Filtering rules (§4.4)
//!
//! 1. Skip `false_positive == true`.
//! 2. Skip `score < FRIGATE_MIN_SCORE` (default `0.3`).
//! 3. For `type = "new"`: process immediately as `Start` (surface the detection
//!    early; the snapshot is filled in later by the `update`).
//! 4. For `type = "update"`: only process when `before.has_snapshot == false`
//!    AND `after.has_snapshot == true` (snapshot just became available).
//! 5. For `type = "end"`: always process.
//! 6. Map `after.camera` → `camera_id` via startup `HashMap`.
//!    Unknown cameras are logged at WARN and dropped.
//!
//! # Reconnection
//!
//! rumqttc's `EventLoop::poll()` re-attempts the connection after a disconnect,
//! but rumqttc 0.24 inserts NO delay before retrying a failed connect — so an
//! unreachable broker would hot-spin the poll loop (pegging a core on the box
//! shared with the recorder).  This provider therefore adds its own capped
//! exponential back-off (1s → 30s, reset on a successful `ConnAck`) in the
//! disconnect/error arm, raced against the stop signal so shutdown stays prompt.
//!
//! # HTTP backfill
//!
//! On startup (before entering the MQTT loop) the provider fetches
//! `GET {FRIGATE_API_BASE}/api/events?after=<ts>&limit=500` to recover events
//! that arrived while Crumb was offline.  The `after` timestamp is
//! `FRIGATE_CATCHUP_HOURS` hours before now.

use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, RwLock,
    },
    time::Duration,
};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use rumqttc::{AsyncClient, Event, MqttOptions, Packet, QoS};
use serde::Deserialize;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crumb_common::db::load_camera_name_map;
use crumb_common::detection::{DetectionLabel, DetectionSource, EventLifecycle, NormalizedEvent};

/// How often the Frigate camera-name map is reloaded from the DB.
///
/// The map (`source_camera_name` → camera UUID) is loaded at startup, but a
/// camera's `source_camera_name` can be set *after* the API boots (e.g. on a
/// fresh deploy, or when an operator maps a camera later). Without a periodic
/// reload the map would stay frozen — every detection silently dropped as
/// "unmapped" until the API is restarted. Reloading on this interval makes the
/// provider self-heal within one cycle.
const CAMERA_MAP_RELOAD: Duration = Duration::from_mins(1);

/// A camera map shared between the live MQTT loop, the backfill, and the
/// periodic reload task. `RwLock` (not `ArcSwap`) keeps the dependency surface
/// minimal; reads are a brief `HashMap` lookup with no `.await` held.
type SharedCameraMap = Arc<RwLock<HashMap<String, Uuid>>>;

/// Read a snapshot clone of the camera map (poison-tolerant). Cheap — the map is
/// one small entry per camera — and avoids holding the lock across an `.await`.
fn camera_map_snapshot(map: &SharedCameraMap) -> HashMap<String, Uuid> {
    map.read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
}

// ── FrigateConfig ─────────────────────────────────────────────────────────────

/// Runtime configuration for the Frigate provider (read from env vars).
#[derive(Debug, Clone)]
pub struct FrigateConfig {
    /// `FRIGATE_MQTT_URL` — e.g. `mqtt://192.0.2.10:1883`.
    pub mqtt_url: String,
    /// `FRIGATE_MQTT_PREFIX` — topic prefix, default `"frigate"`.
    pub mqtt_prefix: String,
    /// `FRIGATE_MQTT_USER` — optional MQTT username (broker auth). `None` = anonymous.
    pub mqtt_user: Option<String>,
    /// MQTT password (broker auth). From `FRIGATE_MQTT_PASSWORD`, or
    /// `FRIGATE_MQTT_PASSWORD_B64` (base64) to survive `.env`/compose `$`-escaping.
    pub mqtt_password: Option<String>,
    /// `FRIGATE_API_BASE` — HTTP base for event catchup, e.g. `http://192.0.2.10:5000`.
    pub api_base: String,
    /// `FRIGATE_MIN_SCORE` — confidence floor, default `0.3`.
    pub min_score: f32,
    /// `FRIGATE_CATCHUP_HOURS` — how far back to fetch on startup, default `24`.
    pub catchup_hours: i64,
}

impl FrigateConfig {
    /// Read Frigate configuration from environment variables.
    ///
    /// Returns `None` when `FRIGATE_MQTT_URL` is absent or empty — this is the
    /// normal "no Frigate" case where no provider should be instantiated.
    ///
    /// Superseded by [`from_settings`](Self::from_settings) (the DB is now the
    /// source of truth); kept as the documented `FRIGATE_*` env-var contract that
    /// `db::ensure_frigate_config_table` seeds from on first boot.
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
            // BYO-Frigate: no homelab IP baked in. Empty default = the event
            // ingester's HTTP catch-up is inert until the operator sets the
            // Frigate API base (env FRIGATE_API_BASE or the admin Integrations page).
            api_base: std::env::var("FRIGATE_API_BASE").unwrap_or_default(),
            min_score: std::env::var("FRIGATE_MIN_SCORE")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(0.3_f32),
            catchup_hours: std::env::var("FRIGATE_CATCHUP_HOURS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(24_i64),
        })
    }

    /// Build from the DB-backed [`FrigateSettings`] (the hot-reloadable source of
    /// truth). `None` when disabled or the broker URL is empty.
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
            api_base: s.api_base.clone(),
            min_score: s.min_score,
            catchup_hours: s.catchup_hours,
        })
    }
}

// ── FrigateProvider ───────────────────────────────────────────────────────────

/// Frigate MQTT + HTTP backfill detection-event provider.
///
/// # Construction
///
/// Use [`FrigateProvider::new`] to build the provider.  Pass `camera_map`
/// loaded from `SELECT id, source_camera_name FROM cameras`.
///
/// # Thread safety
///
/// `FrigateProvider` is `Send + Sync`.  The camera map lives behind an
/// `RwLock` so a background task can reload it from the DB while the MQTT loop
/// reads it; the `healthy` flag is an atomic.
pub struct FrigateProvider {
    cfg: FrigateConfig,
    /// Frigate camera name → Crumb camera UUID. Reloaded periodically (see
    /// [`CAMERA_MAP_RELOAD`]) so a `source_camera_name` set after startup takes
    /// effect without an API restart.
    camera_map: SharedCameraMap,
    /// DB pool, used by the periodic camera-map reload task.
    pool: Pool,
    /// Atomic health flag.  `true` when the MQTT event loop last delivered a
    /// successful packet.
    healthy: Arc<AtomicBool>,
    /// Signals the MQTT loop to stop.
    stop_tx: tokio::sync::watch::Sender<bool>,
    stop_rx: tokio::sync::watch::Receiver<bool>,
}

impl FrigateProvider {
    /// Construct a new [`FrigateProvider`].
    ///
    /// `camera_map` should be loaded via
    /// `crumb_common::db::load_camera_name_map`; `pool` is used to reload it
    /// periodically so a late `source_camera_name` self-heals.
    #[must_use]
    pub fn new(cfg: FrigateConfig, camera_map: HashMap<String, Uuid>, pool: Pool) -> Self {
        let (stop_tx, stop_rx) = tokio::sync::watch::channel(false);
        Self {
            cfg,
            camera_map: Arc::new(RwLock::new(camera_map)),
            pool,
            healthy: Arc::new(AtomicBool::new(false)),
            stop_tx,
            stop_rx,
        }
    }

    /// Spawn a background task that reloads the camera-name map from the DB every
    /// [`CAMERA_MAP_RELOAD`]. This is what makes a `source_camera_name` set after
    /// the provider started take effect without an API restart. The task stops
    /// when the provider's stop signal fires, and keeps the previous map on a
    /// transient DB error (never blanks a working map).
    fn spawn_camera_map_reload(&self) {
        let pool = self.pool.clone();
        let map = Arc::clone(&self.camera_map);
        let mut stop_rx = self.stop_rx.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(CAMERA_MAP_RELOAD);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            interval.tick().await; // consume the immediate first tick (loaded at startup)
            loop {
                tokio::select! {
                    _ = interval.tick() => {
                        match load_camera_name_map(&pool).await {
                            Ok(fresh) => {
                                let mut guard =
                                    map.write().unwrap_or_else(std::sync::PoisonError::into_inner);
                                if *guard != fresh {
                                    let n = fresh.len();
                                    *guard = fresh;
                                    info!(mapped_cameras = n, "detection: camera name map reloaded");
                                }
                            }
                            Err(e) => warn!(
                                error = %e,
                                "detection: camera map reload failed (keeping previous map)"
                            ),
                        }
                    }
                    res = stop_rx.changed() => {
                        // Break on an explicit stop OR a closed channel. When all
                        // senders drop (e.g. start() returned on the channel-closed
                        // path), changed() returns Err immediately and forever — so
                        // without the is_err() check this arm would hot-spin a core.
                        if res.is_err() || *stop_rx.borrow() {
                            break;
                        }
                    }
                }
            }
        });
    }
}

#[async_trait::async_trait]
impl DetectionSource for FrigateProvider {
    fn id(&self) -> &'static str {
        "frigate"
    }

    async fn start(&self, tx: mpsc::Sender<NormalizedEvent>) -> Result<()> {
        // ── 0. Periodic camera-map reload ─────────────────────────────────────
        // Keep the name map fresh so a `source_camera_name` set AFTER startup
        // takes effect without an API restart (the "mapped_cameras: 0" silent-
        // drop bug). Runs for the life of the provider; stops on the stop signal.
        self.spawn_camera_map_reload();

        // ── 1. HTTP backfill ──────────────────────────────────────────────────
        let backfill_since = Utc::now() - chrono::Duration::hours(self.cfg.catchup_hours);
        info!(
            since = %backfill_since,
            "FrigateProvider: starting HTTP backfill"
        );
        // Snapshot the map — don't hold the RwLock across the backfill's awaits.
        let backfill_map = camera_map_snapshot(&self.camera_map);
        if let Err(e) = http_backfill(&self.cfg, &backfill_map, backfill_since, &tx).await {
            warn!(error = %e, "FrigateProvider: HTTP backfill failed (continuing with MQTT)");
        }

        // ── 2. MQTT subscription ──────────────────────────────────────────────
        let topic = format!("{}/events", self.cfg.mqtt_prefix);

        // Parse host + port from the MQTT URL.  rumqttc expects them separately.
        let (host, port) = parse_mqtt_url(&self.cfg.mqtt_url)?;

        let mut mqttoptions =
            MqttOptions::new(format!("crumb-api-{}", uuid::Uuid::new_v4()), &host, port);
        mqttoptions.set_keep_alive(Duration::from_secs(30));
        mqttoptions.set_clean_session(true);
        // Allow internal reconnection queue depth.
        mqttoptions.set_inflight(100);
        // Broker authentication (optional). The homelab broker Frigate already
        // publishes to requires credentials; an anonymous broker leaves these unset.
        if let Some(user) = &self.cfg.mqtt_user {
            mqttoptions.set_credentials(user, self.cfg.mqtt_password.clone().unwrap_or_default());
        }

        let (client, mut event_loop) = AsyncClient::new(mqttoptions, 512);

        // Subscribe on first connection; rumqttc re-sends subscriptions on
        // reconnect automatically with clean_session = false, but since we use
        // clean_session = true we re-subscribe in the ConnAck handler.
        let topic_clone = topic.clone();
        let healthy_clone = Arc::clone(&self.healthy);
        let camera_map_clone = Arc::clone(&self.camera_map);
        let min_score = self.cfg.min_score;
        let mut stop_rx = self.stop_rx.clone();

        info!(mqtt_url = %self.cfg.mqtt_url, topic = %topic, "FrigateProvider: connecting to MQTT");

        // Reconnect back-off. rumqttc 0.24 has no built-in reconnect delay, so a
        // failed connect (e.g. the broker not yet up — `api` only depends_on
        // postgres, not mosquitto) returns immediately and would hot-spin poll().
        // Back off 1s → 30s (doubling), reset to 1s on a successful connect.
        const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);
        let mut reconnect_delay = Duration::from_secs(1);

        // Connectivity heartbeat (frigate_disconnected alert): stamp
        // `frigate_heartbeat` on any successful packet, throttled to at most this
        // often, so the system-health watchdog can tell a live-but-quiet link
        // from a real outage. See db::write_frigate_heartbeat / migration 0034.
        const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(20);
        let hb_pool = self.pool.clone();
        let mut last_hb: Option<std::time::Instant> = None;

        // Drive the event loop.
        loop {
            tokio::select! {
                // Stop signal.
                _ = stop_rx.changed() => {
                    if *stop_rx.borrow() {
                        info!("FrigateProvider: stop signal received");
                        let _ = client.disconnect().await;
                        break;
                    }
                }

                notification = event_loop.poll() => {
                    // Refresh the connectivity heartbeat (throttled) on ANY
                    // successful packet — ConnAck, keepalive PingResp, or an event
                    // — so frigate_disconnected doesn't false-fire during a
                    // connected-but-quiet period. On an Err (disconnect) we skip,
                    // letting the heartbeat go stale so the watchdog sees the outage.
                    if notification.is_ok()
                        && last_hb.is_none_or(|t| t.elapsed() >= HEARTBEAT_INTERVAL)
                    {
                        if let Err(e) = crumb_common::db::write_frigate_heartbeat(&hb_pool).await {
                            warn!(error = %e, "FrigateProvider: heartbeat write failed");
                        }
                        last_hb = Some(std::time::Instant::now());
                    }
                    match notification {
                        Ok(Event::Incoming(Packet::ConnAck(_))) => {
                            info!("FrigateProvider: MQTT connected, subscribing to {}", topic_clone);
                            healthy_clone.store(true, Ordering::Relaxed);
                            reconnect_delay = Duration::from_secs(1); // connected → reset back-off
                            if let Err(e) = client.subscribe(&topic_clone, QoS::AtLeastOnce).await {
                                warn!(error = %e, "FrigateProvider: subscribe failed");
                            }
                        }
                        Ok(Event::Incoming(Packet::Publish(publish))) => {
                            // Read the map under a scoped guard so it's dropped
                            // before the `.await` below (RwLock guard is !Send).
                            let parsed = {
                                let map = camera_map_clone
                                    .read()
                                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                                process_mqtt_payload(&publish.payload, &map, min_score)
                            };
                            match parsed {
                                Ok(Some(event)) => {
                                    if tx.send(event).await.is_err() {
                                        info!("FrigateProvider: channel closed, stopping");
                                        break;
                                    }
                                }
                                Ok(None) => {
                                    // Filtered (false positive, low score, 'new', unmapped camera, etc.)
                                    debug!("FrigateProvider: MQTT event filtered");
                                }
                                Err(e) => {
                                    warn!(error = %e, "FrigateProvider: MQTT payload parse error");
                                }
                            }
                        }
                        Ok(Event::Incoming(Packet::Disconnect)) | Err(_) => {
                            healthy_clone.store(false, Ordering::Relaxed);
                            // rumqttc 0.24 retries with NO delay, so without this
                            // back-off an unreachable broker hot-spins the loop and
                            // steals CPU from the co-located recorder. Wait (capped,
                            // doubling) before letting poll() retry; race the wait
                            // against the stop signal so shutdown stays responsive.
                            warn!(
                                delay_ms = reconnect_delay.as_millis() as u64,
                                "FrigateProvider: MQTT disconnected/unreachable, backing off before reconnect"
                            );
                            tokio::select! {
                                () = tokio::time::sleep(reconnect_delay) => {}
                                _ = stop_rx.changed() => {
                                    if *stop_rx.borrow() {
                                        info!("FrigateProvider: stop signal received during reconnect back-off");
                                        let _ = client.disconnect().await;
                                        break;
                                    }
                                }
                            }
                            reconnect_delay = (reconnect_delay * 2).min(MAX_RECONNECT_DELAY);
                        }
                        _ => {
                            // ConnAck, SubAck, PingReq/Resp, etc. — ignore.
                        }
                    }
                }
            }
        }

        Ok(())
    }

    async fn stop(&self) -> Result<()> {
        let _ = self.stop_tx.send(true);
        Ok(())
    }

    fn is_healthy(&self) -> bool {
        self.healthy.load(Ordering::Relaxed)
    }
}

// ── MQTT payload parsing ──────────────────────────────────────────────────────

/// Top-level Frigate MQTT event envelope.
#[derive(Debug, Deserialize)]
struct FrigateEventPayload {
    #[serde(rename = "type")]
    event_type: String,
    before: Option<FrigateEventState>,
    after: FrigateEventState,
}

/// State of a tracked object at a point in its lifetime.
#[derive(Debug, Deserialize)]
struct FrigateEventState {
    id: String,
    camera: String,
    label: String,
    #[serde(default, deserialize_with = "de_sub_label")]
    sub_label: Option<String>,
    // Frigate's native LPR fills this on a tracked car/motorcycle: the raw OCR
    // plate, sent as a `[plate, score]` array (e.g. `["23134X1", 0.994]`) — so
    // capture BOTH the text and the embedded confidence. `de_plate_scored`
    // tolerates a bare string too (score None). `recognized_license_plate_score`
    // is a fallback for any version that sends the score as its own field.
    #[serde(default, deserialize_with = "de_plate_scored")]
    recognized_license_plate: Option<(String, Option<f32>)>,
    recognized_license_plate_score: Option<f32>,
    score: Option<f32>,
    top_score: Option<f32>,
    start_time: f64,
    end_time: Option<f64>,
    #[serde(default)]
    current_zones: Vec<String>,
    false_positive: Option<bool>,
    #[serde(default)]
    has_snapshot: bool,
    // Pixel box [x, y, w, h] — object bounding_box normalisation is Phase 2.
    // box: Option<[i32; 4]>,
    //
    // Sub-detections within the tracked object (Frigate's native LPR fills a
    // `license_plate` entry here whose `box` is the plate region). Captured
    // tolerantly as raw JSON so a missing/odd-shaped attribute never fails the
    // whole-envelope parse (which would silently drop the detection) — same
    // tolerance discipline as `de_sub_label`. See `plate_box_from_attributes`.
    #[serde(default, deserialize_with = "de_attributes")]
    current_attributes: Vec<serde_json::Value>,
}

/// Deserialize Frigate's `sub_label`, tolerating both wire shapes.
///
/// Frigate ≥0.14 sends `sub_label` as a `[name, score]` array (recognized
/// faces / license plates with a confidence score); older versions sent a bare
/// string. Accept both (and `null`), keeping just the name. Without this, any
/// event carrying a scored sub-label fails the *whole-envelope* parse
/// ("MQTT payload schema mismatch") and the detection is silently dropped.
fn de_sub_label<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    use serde_json::Value;
    Ok(match Option::<Value>::deserialize(d)? {
        Some(Value::String(s)) => Some(s),
        Some(Value::Array(a)) => a
            .into_iter()
            .next()
            .and_then(|v| v.as_str().map(str::to_owned)),
        _ => None,
    })
}

/// Deserialize a scored recognition field (`recognized_license_plate`) that
/// Frigate sends as a `[value, score]` array (e.g. `["23134X1", 0.994]`),
/// keeping BOTH the text and the embedded confidence. Tolerates a bare string
/// (score `None`) and `null`. Unlike [`de_sub_label`], this does not discard
/// the score — the plate-read `confidence` column depends on it.
#[allow(clippy::type_complexity)]
fn de_plate_scored<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<(String, Option<f32>)>, D::Error> {
    use serde_json::Value;
    Ok(match Option::<Value>::deserialize(d)? {
        Some(Value::String(s)) => Some((s, None)),
        Some(Value::Array(a)) => {
            let mut it = a.into_iter();
            let name = it.next().and_then(|v| v.as_str().map(str::to_owned));
            #[allow(clippy::cast_possible_truncation)]
            let score = it.next().and_then(|v| v.as_f64()).map(|f| f as f32);
            name.map(|n| (n, score))
        }
        _ => None,
    })
}

/// Deserialize Frigate's `current_attributes` tolerantly into a list of raw
/// JSON values. Frigate sends an array of `{label, box, score}` objects, but a
/// future/odd shape (or an explicit `null`) must NOT fail the whole-envelope
/// parse — that would silently drop the detection. Anything that isn't a JSON
/// array yields an empty list; each element is preserved verbatim for
/// [`plate_box_from_attributes`] to inspect. Mirrors the [`de_sub_label`] /
/// [`de_plate_scored`] tolerance pattern.
fn de_attributes<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Vec<serde_json::Value>, D::Error> {
    use serde_json::Value;
    Ok(match Option::<Value>::deserialize(d)? {
        Some(Value::Array(a)) => a,
        _ => Vec::new(),
    })
}

/// Pull the `license_plate` attribute's raw box out of Frigate's
/// `current_attributes` list, as `[x, y, w, h]` — Frigate's *attribute* box
/// convention: **normalized** top-left + size (each coord in `0..=1`), confirmed
/// against a live `/api/events` payload. (This differs from Frigate's *object*
/// `box`, which is pixel corners; the attribute box is not.) Tolerant: a missing
/// entry, a non-numeric or non-4-element `box`, or the plate attribute simply
/// being absent all yield `None` — never an error.
fn plate_box_from_attributes(attrs: &[serde_json::Value]) -> Option<[f32; 4]> {
    for a in attrs {
        if a.get("label").and_then(serde_json::Value::as_str) != Some("license_plate") {
            continue;
        }
        let arr = a.get("box").and_then(serde_json::Value::as_array)?;
        if arr.len() != 4 {
            return None;
        }
        let mut out = [0f32; 4];
        for (slot, v) in out.iter_mut().zip(arr) {
            let f = v.as_f64()?;
            #[allow(clippy::cast_possible_truncation)]
            {
                *slot = f as f32;
            }
        }
        return Some(out);
    }
    None
}

/// Normalize a raw Frigate plate *attribute* box to `[x, y, w, h]` fractions of
/// the full frame — the exact shape the clients' crop math expects.
///
/// Frigate reports the `license_plate` attribute box as **normalized
/// `[x, y, w, h]`** (top-left + size, each coord in `0..=1`), verified against a
/// live `/api/events` payload — e.g. `[0.7646, 0.5611, 0.0536, 0.0556]`. And
/// snapshots are full-frame (`snapshots.crop=false`), so these fractions map
/// straight onto the snapshot the report crops. So the common path is a direct
/// clamp-and-passthrough — no frame dimensions needed.
///
/// * Normalized `[x, y, w, h]` (all coords in `0..=1`): clamp the origin into the
///   frame and the size so the box stays inside it. The primary/observed case.
/// * Pixel `[x, y, w, h]` (any coord > 1) WITH frame dimensions: divide by the
///   frame size. (Not exercised today — the ingest paths pass `None` — but kept
///   so a future caller that has the detect resolution can hand it in.)
/// * Pixel coords with no frame dimensions: `None` — we don't invent a scale.
///
/// Returns `None` for a `None` input or a degenerate (zero-area) box.
fn normalize_plate_box(raw: Option<[f32; 4]>, frame: Option<(f32, f32)>) -> Option<[f32; 4]> {
    let [x, y, w, h] = raw?;
    let in_unit = |v: f32| (0.0..=1.0).contains(&v);

    // Normalized [x, y, w, h] — the shape Frigate actually sends. Clamp inside.
    if in_unit(x) && in_unit(y) && in_unit(w) && in_unit(h) {
        let cx = x.clamp(0.0, 1.0);
        let cy = y.clamp(0.0, 1.0);
        let cw = w.clamp(0.0, 1.0 - cx);
        let ch = h.clamp(0.0, 1.0 - cy);
        return (cw > 0.0 && ch > 0.0).then_some([cx, cy, cw, ch]);
    }

    // Pixel [x, y, w, h]: only normalizable with frame dimensions.
    if let Some((fw, fh)) = frame {
        if fw > 0.0 && fh > 0.0 {
            let nx = (x / fw).clamp(0.0, 1.0);
            let ny = (y / fh).clamp(0.0, 1.0);
            let nw = (w / fw).clamp(0.0, 1.0 - nx);
            let nh = (h / fh).clamp(0.0, 1.0 - ny);
            return (nw > 0.0 && nh > 0.0).then_some([nx, ny, nw, nh]);
        }
    }

    None
}

/// Process one MQTT payload and, if it passes all filters, return a
/// [`NormalizedEvent`].  Returns `Ok(None)` when the event is filtered.
fn process_mqtt_payload(
    payload: &bytes::Bytes,
    camera_map: &HashMap<String, Uuid>,
    min_score: f32,
) -> Result<Option<NormalizedEvent>> {
    let raw_value: serde_json::Value =
        serde_json::from_slice(payload).context("MQTT payload is not valid JSON")?;

    let envelope: FrigateEventPayload =
        serde_json::from_value(raw_value.clone()).context("MQTT payload schema mismatch")?;

    let after = &envelope.after;

    // Filter 1: false positive.
    if after.false_positive.unwrap_or(false) {
        return Ok(None);
    }

    // Filter 2: confidence floor.
    let score = after.score.unwrap_or(0.0);
    if score < min_score {
        return Ok(None);
    }

    // Filter 3/4/5: lifecycle.
    let lifecycle = match envelope.event_type.as_str() {
        "new" => {
            // Surface the detection AS SOON as Frigate sees it (it carries the
            // label/score/camera already) instead of waiting for the snapshot to
            // be generated — that wait added ~several seconds to the live wall's
            // detection icon. The thumbnail isn't lost: the later snapshot 'update'
            // upserts it in (snapshot_url uses COALESCE). False positives are still
            // gated by the false_positive + min_score filters above.
            EventLifecycle::Start
        }
        "update" => {
            // Only process when snapshot just became available.
            let before_had = envelope.before.as_ref().is_some_and(|b| b.has_snapshot);
            let after_has = after.has_snapshot;
            if before_had || !after_has {
                return Ok(None);
            }
            EventLifecycle::Update
        }
        "end" => EventLifecycle::End,
        other => {
            warn!(event_type = other, "FrigateProvider: unknown event type");
            return Ok(None);
        }
    };

    // Filter 6: camera mapping.
    let camera_id = if let Some(id) = camera_map.get(&after.camera) {
        *id
    } else {
        warn!(
            frigate_camera = %after.camera,
            "FrigateProvider: unmapped camera — add source_camera_name to cameras table"
        );
        return Ok(None);
    };

    // Store the Frigate-relative path (no base URL here — process_mqtt_payload
    // is a pure fn without access to FrigateConfig). The API snapshot proxy
    // prepends FRIGATE_API_BASE at request time.
    let snapshot_url = if after.has_snapshot {
        Some(format!("/api/events/{}/snapshot.jpg", after.id))
    } else {
        None
    };

    let top_score = after.top_score.unwrap_or(score);
    let start_ts = ts_from_f64(after.start_time);
    let end_ts = after.end_time.map(ts_from_f64);

    Ok(Some(NormalizedEvent {
        source_id: "frigate".to_owned(),
        camera_id,
        provider_event_id: after.id.clone(),
        lifecycle,
        label: DetectionLabel::from_str(&after.label),
        sub_label: after.sub_label.clone(),
        score,
        top_score,
        start_ts,
        end_ts,
        bounding_box: None, // Phase 2
        zones: after.current_zones.clone(),
        snapshot_url,
        recognized_plate: after
            .recognized_license_plate
            .as_ref()
            .map(|(p, _)| p.clone()),
        // Prefer the score embedded in the [plate, score] array; fall back to a
        // separate score field if a Frigate version sends one that way.
        plate_confidence: after
            .recognized_license_plate
            .as_ref()
            .and_then(|(_, s)| *s)
            .or(after.recognized_license_plate_score),
        // Plate crop box. Frigate MQTT boxes are absolute pixels and the event
        // carries no frame dimensions, so this normalizes only when the box is
        // already in 0..1 fractions; a pixel box yields None (the raw box is
        // still preserved verbatim in `raw` for inspection). Best-effort — a
        // None here never affects the plate text / detection path.
        plate_box: normalize_plate_box(plate_box_from_attributes(&after.current_attributes), None),
        raw: raw_value,
    }))
}

// ── HTTP backfill ─────────────────────────────────────────────────────────────

/// Frigate HTTP API event shape (subset of fields we use).
#[derive(Debug, Deserialize)]
struct FrigateApiEvent {
    id: String,
    camera: String,
    label: String,
    #[serde(default, deserialize_with = "de_sub_label")]
    sub_label: Option<String>,
    start_time: f64,
    end_time: Option<f64>,
    #[serde(default)]
    has_snapshot: bool,
    // Frigate 0.17's HTTP API returns `false_positive: null` for in-progress
    // events. `#[serde(default)]` only covers an ABSENT field, not an explicit
    // null, so this MUST be Option or the whole array fails to deserialize
    // (the original cause of "parse Frigate API backfill JSON").
    #[serde(default)]
    false_positive: Option<bool>,
    #[serde(default)]
    zones: Vec<String>,
    // The real confidence scores live INSIDE `data` in the HTTP API; the
    // top-level `top_score` is null. Without this the score filter would drop
    // every backfilled event.
    #[serde(default)]
    data: Option<FrigateApiEventData>,
}

/// Nested `data` object in Frigate's HTTP `/api/events` response — where the
/// real confidence scores live (top-level `score`/`top_score` are null).
#[derive(Debug, Deserialize, Default)]
struct FrigateApiEventData {
    score: Option<f32>,
    top_score: Option<f32>,
    // Frigate's HTTP API nests the LPR result under `data` (like the scores);
    // same `[plate, score]` shape as MQTT, so keep the score.
    #[serde(default, deserialize_with = "de_plate_scored")]
    recognized_license_plate: Option<(String, Option<f32>)>,
    recognized_license_plate_score: Option<f32>,
    // Plate crop box, mirroring the MQTT `current_attributes`. Tolerant/default
    // so it's harmless if this backfill payload omits it or names it differently
    // (yields no box → None). See `plate_box_from_attributes`.
    #[serde(default, deserialize_with = "de_attributes")]
    current_attributes: Vec<serde_json::Value>,
}

/// Fetch recent events from Frigate's HTTP API and forward them to `tx`.
///
/// Uses `GET {api_base}/api/events?after={unix_ts}&limit=500`.
/// Errors are non-fatal: the caller logs a WARN and continues with MQTT.
async fn http_backfill(
    cfg: &FrigateConfig,
    camera_map: &HashMap<String, Uuid>,
    since: DateTime<Utc>,
    tx: &mpsc::Sender<NormalizedEvent>,
) -> Result<()> {
    let after_ts = since.timestamp();
    let url = format!(
        "{}/api/events?after={}&limit=500",
        cfg.api_base.trim_end_matches('/'),
        after_ts,
    );

    info!(url = %url, "FrigateProvider: fetching HTTP backfill");

    // Use reqwest (already in services/api deps) for the HTTP call.
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .context("build reqwest client")?;

    let resp = client
        .get(&url)
        .send()
        .await
        .context("Frigate API backfill request")?;

    if !resp.status().is_success() {
        anyhow::bail!("Frigate API backfill returned HTTP {}", resp.status());
    }

    let events: Vec<FrigateApiEvent> = resp
        .json()
        .await
        .context("parse Frigate API backfill JSON")?;

    info!(
        count = events.len(),
        "FrigateProvider: HTTP backfill received events"
    );

    let mut forwarded = 0u32;
    for ev in events {
        if ev.false_positive.unwrap_or(false) {
            continue;
        }
        // Scores are nested under `data` in the HTTP API (top-level is null).
        let data_score = ev.data.as_ref().and_then(|d| d.score);
        let data_top = ev.data.as_ref().and_then(|d| d.top_score);
        let score = data_score.or(data_top).unwrap_or(0.0);
        if score < cfg.min_score {
            continue;
        }
        let Some(&camera_id) = camera_map.get(&ev.camera) else {
            warn!(
                frigate_camera = %ev.camera,
                "FrigateProvider: backfill unmapped camera"
            );
            continue;
        };

        let snapshot_url = if ev.has_snapshot {
            Some(format!("/api/events/{}/snapshot.jpg", ev.id))
        } else {
            None
        };

        let top_score = data_top.or(data_score).unwrap_or(score);
        let lifecycle = if ev.end_time.is_some() {
            EventLifecycle::End
        } else {
            EventLifecycle::Update
        };
        let recognized_plate = ev
            .data
            .as_ref()
            .and_then(|d| d.recognized_license_plate.as_ref())
            .map(|(p, _)| p.clone());
        let plate_confidence = ev.data.as_ref().and_then(|d| {
            d.recognized_license_plate
                .as_ref()
                .and_then(|(_, s)| *s)
                .or(d.recognized_license_plate_score)
        });
        let plate_box = ev.data.as_ref().and_then(|d| {
            normalize_plate_box(plate_box_from_attributes(&d.current_attributes), None)
        });

        let event = NormalizedEvent {
            source_id: "frigate".to_owned(),
            camera_id,
            provider_event_id: ev.id.clone(),
            lifecycle,
            label: DetectionLabel::from_str(&ev.label),
            sub_label: ev.sub_label,
            score,
            top_score,
            start_ts: ts_from_f64(ev.start_time),
            end_ts: ev.end_time.map(ts_from_f64),
            bounding_box: None,
            zones: ev.zones,
            snapshot_url,
            recognized_plate,
            plate_confidence,
            plate_box,
            raw: serde_json::json!({
                "id": ev.id,
                "camera": ev.camera,
                "label": ev.label,
                "score": score,
                "top_score": top_score,
                "start_time": ev.start_time,
                "end_time": ev.end_time,
                "has_snapshot": ev.has_snapshot,
                "source": "http_backfill"
            }),
        };

        if tx.send(event).await.is_err() {
            break;
        }
        forwarded += 1;
    }

    info!(forwarded, "FrigateProvider: HTTP backfill forwarded events");
    Ok(())
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Convert a Unix timestamp in fractional seconds (Frigate's wire format) to
/// `DateTime<Utc>`.  Saturates to `UNIX_EPOCH` on underflow.
fn ts_from_f64(ts: f64) -> DateTime<Utc> {
    let secs = ts.floor() as i64;
    let nanos = ((ts - ts.floor()) * 1_000_000_000.0) as u32;
    DateTime::from_timestamp(secs, nanos).unwrap_or_else(Utc::now)
}

/// Parse `host` and `port` from an `mqtt://host:port` URL.
///
/// Also accepts `mqtt://host` (defaults to port 1883).
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

// ── unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ts_from_f64_round_trip() {
        let ts = 1_607_123_955.475_377_f64;
        let dt = ts_from_f64(ts);
        assert_eq!(dt.timestamp(), 1_607_123_955);
    }

    #[test]
    fn parse_mqtt_url_with_port() {
        let (host, port) = parse_mqtt_url("mqtt://192.0.2.10:1883").unwrap();
        assert_eq!(host, "192.0.2.10");
        assert_eq!(port, 1883);
    }

    #[test]
    fn parse_mqtt_url_without_port() {
        let (host, port) = parse_mqtt_url("mqtt://192.0.2.10").unwrap();
        assert_eq!(host, "192.0.2.10");
        assert_eq!(port, 1883);
    }

    #[test]
    fn parse_mqtt_url_no_scheme() {
        let (host, port) = parse_mqtt_url("192.0.2.10:1883").unwrap();
        assert_eq!(host, "192.0.2.10");
        assert_eq!(port, 1883);
    }

    #[test]
    fn process_skips_false_positive() {
        let payload = serde_json::json!({
            "type": "end",
            "before": null,
            "after": {
                "id": "abc123",
                "camera": "driveway",
                "label": "person",
                "sub_label": null,
                "score": 0.9,
                "top_score": 0.9,
                "start_time": 1_000_000.0f64,
                "end_time": 1_000_010.0f64,
                "current_zones": [],
                "false_positive": true,
                "has_snapshot": true
            }
        });
        let map = HashMap::new();
        let bytes = bytes::Bytes::from(payload.to_string());
        let result = process_mqtt_payload(&bytes, &map, 0.3).unwrap();
        assert!(result.is_none(), "false_positive must be filtered");
    }

    #[test]
    fn process_skips_low_score() {
        let payload = serde_json::json!({
            "type": "end",
            "before": null,
            "after": {
                "id": "abc123",
                "camera": "driveway",
                "label": "person",
                "sub_label": null,
                "score": 0.1,
                "top_score": 0.1,
                "start_time": 1_000_000.0f64,
                "end_time": 1_000_010.0f64,
                "current_zones": [],
                "false_positive": false,
                "has_snapshot": false
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), Uuid::new_v4());
        let bytes = bytes::Bytes::from(payload.to_string());
        let result = process_mqtt_payload(&bytes, &map, 0.3).unwrap();
        assert!(result.is_none(), "score below min must be filtered");
    }

    #[test]
    fn process_accepts_new_type_as_start() {
        // type=new is surfaced immediately (lifecycle Start) so the live wall's
        // detection icon appears without waiting for the snapshot 'update'; the
        // snapshot is filled in later via COALESCE. (Still gated by the
        // false_positive + min_score filters.)
        let cam_id = Uuid::new_v4();
        let payload = serde_json::json!({
            "type": "new",
            "before": null,
            "after": {
                "id": "abc123",
                "camera": "driveway",
                "label": "person",
                "sub_label": null,
                "score": 0.8,
                "top_score": 0.8,
                "start_time": 1_000_000.0f64,
                "end_time": null,
                "current_zones": [],
                "false_positive": false,
                "has_snapshot": false
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), cam_id);
        let bytes = bytes::Bytes::from(payload.to_string());
        let result = process_mqtt_payload(&bytes, &map, 0.3).unwrap();
        assert!(
            result.is_some(),
            "type=new must be accepted (surfaced early)"
        );
        let ev = result.unwrap();
        assert_eq!(ev.camera_id, cam_id);
        assert_eq!(ev.lifecycle, EventLifecycle::Start);
        assert_eq!(ev.label, DetectionLabel::Person);
    }

    #[test]
    fn process_skips_update_without_snapshot_transition() {
        let cam_id = Uuid::new_v4();
        // before.has_snapshot=false, after.has_snapshot=false → filter
        let payload = serde_json::json!({
            "type": "update",
            "before": {
                "id": "abc123", "camera": "driveway", "label": "person",
                "sub_label": null, "score": 0.8, "top_score": 0.8,
                "start_time": 1_000_000.0f64, "end_time": null,
                "current_zones": [], "false_positive": false, "has_snapshot": false
            },
            "after": {
                "id": "abc123", "camera": "driveway", "label": "person",
                "sub_label": null, "score": 0.85, "top_score": 0.85,
                "start_time": 1_000_000.0f64, "end_time": null,
                "current_zones": ["driveway"], "false_positive": false, "has_snapshot": false
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), cam_id);
        let bytes = bytes::Bytes::from(payload.to_string());
        let result = process_mqtt_payload(&bytes, &map, 0.3).unwrap();
        assert!(
            result.is_none(),
            "update without snapshot transition must be filtered"
        );
    }

    #[test]
    fn process_accepts_update_with_snapshot_transition() {
        let cam_id = Uuid::new_v4();
        // before.has_snapshot=false, after.has_snapshot=true → accept
        let payload = serde_json::json!({
            "type": "update",
            "before": {
                "id": "abc123", "camera": "driveway", "label": "person",
                "sub_label": null, "score": 0.8, "top_score": 0.8,
                "start_time": 1_000_000.0f64, "end_time": null,
                "current_zones": [], "false_positive": false, "has_snapshot": false
            },
            "after": {
                "id": "abc123", "camera": "driveway", "label": "person",
                "sub_label": null, "score": 0.85, "top_score": 0.85,
                "start_time": 1_000_000.0f64, "end_time": null,
                "current_zones": ["driveway"], "false_positive": false, "has_snapshot": true
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), cam_id);
        let bytes = bytes::Bytes::from(payload.to_string());
        let result = process_mqtt_payload(&bytes, &map, 0.3).unwrap();
        assert!(
            result.is_some(),
            "snapshot transition update must be accepted"
        );
        let ev = result.unwrap();
        assert_eq!(ev.camera_id, cam_id);
        assert_eq!(ev.lifecycle, EventLifecycle::Update);
        assert_eq!(ev.label, DetectionLabel::Person);
    }

    #[test]
    fn process_accepts_end_always() {
        let cam_id = Uuid::new_v4();
        let payload = serde_json::json!({
            "type": "end",
            "before": null,
            "after": {
                "id": "abc123", "camera": "driveway", "label": "car",
                "sub_label": null, "score": 0.75, "top_score": 0.9,
                "start_time": 1_000_000.0f64, "end_time": 1_000_020.0f64,
                "current_zones": ["driveway"], "false_positive": false, "has_snapshot": false
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), cam_id);
        let bytes = bytes::Bytes::from(payload.to_string());
        let result = process_mqtt_payload(&bytes, &map, 0.3).unwrap();
        assert!(result.is_some(), "type=end must always be accepted");
        let ev = result.unwrap();
        assert_eq!(ev.lifecycle, EventLifecycle::End);
        assert_eq!(ev.label, DetectionLabel::Car);
        assert!(ev.end_ts.is_some());
    }

    #[test]
    fn process_accepts_scored_sub_label_array() {
        // Frigate ≥0.14 sends sub_label as a [name, score] array (face/LPR
        // recognition). Must parse, not fail the whole envelope, and keep the name.
        let cam_id = Uuid::new_v4();
        let payload = serde_json::json!({
            "type": "end",
            "before": null,
            "after": {
                "id": "abc123", "camera": "driveway", "label": "car",
                "sub_label": ["Jay's Car", 0.966f64], "score": 0.9, "top_score": 0.95,
                "start_time": 1_000_000.0f64, "end_time": 1_000_020.0f64,
                "current_zones": ["driveway"], "false_positive": false, "has_snapshot": true
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), cam_id);
        let bytes = bytes::Bytes::from(payload.to_string());
        let result = process_mqtt_payload(&bytes, &map, 0.3).unwrap();
        assert!(result.is_some(), "scored sub_label array must parse");
        assert_eq!(result.unwrap().sub_label.as_deref(), Some("Jay's Car"));
    }

    #[test]
    fn process_logs_warn_unmapped_camera() {
        // camera "unknown_cam" not in map → Ok(None)
        let payload = serde_json::json!({
            "type": "end",
            "before": null,
            "after": {
                "id": "abc123", "camera": "unknown_cam", "label": "person",
                "sub_label": null, "score": 0.9, "top_score": 0.9,
                "start_time": 1_000_000.0f64, "end_time": 1_000_010.0f64,
                "current_zones": [], "false_positive": false, "has_snapshot": false
            }
        });
        let map = HashMap::new(); // empty — no mapping
        let bytes = bytes::Bytes::from(payload.to_string());
        let result = process_mqtt_payload(&bytes, &map, 0.3).unwrap();
        assert!(result.is_none(), "unmapped camera must return None");
    }

    #[test]
    fn plate_box_from_attributes_extracts_license_plate() {
        let attrs = vec![
            serde_json::json!({"label": "car", "box": [1.0, 2.0, 3.0, 4.0], "score": 0.9}),
            serde_json::json!({"label": "license_plate", "box": [10.0, 20.0, 30.0, 40.0], "score": 0.8}),
        ];
        let got = plate_box_from_attributes(&attrs).expect("license_plate box");
        for (g, want) in got.iter().zip([10.0_f32, 20.0, 30.0, 40.0]) {
            assert!((g - want).abs() < 1e-6);
        }
    }

    #[test]
    fn plate_box_from_attributes_tolerates_bad_shapes() {
        // No license_plate entry, odd-length box, non-numeric, absent box, and a
        // non-object element must all yield None rather than panic/parse-fail.
        assert_eq!(
            plate_box_from_attributes(&[serde_json::json!({"label": "car", "box": [1, 2, 3, 4]})]),
            None,
            "no license_plate entry"
        );
        assert_eq!(
            plate_box_from_attributes(&[
                serde_json::json!({"label": "license_plate", "box": [1, 2, 3]})
            ]),
            None,
            "3-element box"
        );
        assert_eq!(
            plate_box_from_attributes(&[
                serde_json::json!({"label": "license_plate", "box": [1, "x", 3, 4]})
            ]),
            None,
            "non-numeric coord"
        );
        assert_eq!(
            plate_box_from_attributes(&[serde_json::json!({"label": "license_plate"})]),
            None,
            "missing box"
        );
        assert_eq!(
            plate_box_from_attributes(&[serde_json::json!("not-an-object")]),
            None,
            "non-object element"
        );
    }

    #[test]
    fn normalize_plate_box_with_frame_dims() {
        // Pixel [x,y,w,h] over a 1000x500 frame → [x,y,w,h] fractions.
        let got =
            normalize_plate_box(Some([100.0, 50.0, 300.0, 150.0]), Some((1000.0, 500.0))).unwrap();
        assert!((got[0] - 0.1).abs() < 1e-6, "x = 100/1000");
        assert!((got[1] - 0.1).abs() < 1e-6, "y = 50/500");
        assert!((got[2] - 0.3).abs() < 1e-6, "w = 300/1000");
        assert!((got[3] - 0.3).abs() < 1e-6, "h = 150/500");
    }

    #[test]
    fn normalize_plate_box_pixels_without_dims_is_none() {
        // A pixel box (coords > 1) and no frame dims: we do NOT guess a scale.
        assert_eq!(
            normalize_plate_box(Some([100.0, 50.0, 300.0, 150.0]), None),
            None
        );
    }

    #[test]
    fn normalize_plate_box_normalized_passthrough() {
        // The real Frigate shape: normalized [x, y, w, h], no frame dims → as-is.
        let got = normalize_plate_box(Some([0.7646, 0.5611, 0.0536, 0.0556]), None).unwrap();
        assert!((got[0] - 0.7646).abs() < 1e-4);
        assert!((got[1] - 0.5611).abs() < 1e-4);
        assert!((got[2] - 0.0536).abs() < 1e-4, "w passthrough");
        assert!((got[3] - 0.0556).abs() < 1e-4, "h passthrough");
    }

    #[test]
    fn normalize_plate_box_clamps_box_inside_frame() {
        // A normalized origin with an over-large size is clamped to the frame,
        // never emitted spilling past the edge.
        let got = normalize_plate_box(Some([0.8, 0.9, 0.5, 0.5]), None).unwrap();
        assert!((got[0] - 0.8).abs() < 1e-6);
        assert!((got[1] - 0.9).abs() < 1e-6);
        assert!((got[2] - 0.2).abs() < 1e-6, "w clamped to 1-0.8");
        assert!((got[3] - 0.1).abs() < 1e-6, "h clamped to 1-0.9");
    }

    #[test]
    fn normalize_plate_box_rejects_degenerate_and_none() {
        // Zero-area box (w or h == 0) → None; None input → None.
        assert_eq!(normalize_plate_box(Some([0.5, 0.5, 0.0, 0.1]), None), None);
        assert_eq!(normalize_plate_box(Some([0.5, 0.5, 0.1, 0.0]), None), None);
        assert_eq!(normalize_plate_box(None, Some((1000.0, 500.0))), None);
    }

    #[test]
    fn process_mqtt_captures_normalized_plate_box() {
        // A license_plate attribute box (Frigate's normalized [x, y, w, h]) is
        // captured and surfaced as [x, y, w, h] on the event.
        let cam_id = Uuid::new_v4();
        let payload = serde_json::json!({
            "type": "end",
            "before": null,
            "after": {
                "id": "abc123", "camera": "driveway", "label": "car",
                "sub_label": null, "score": 0.9, "top_score": 0.95,
                "start_time": 1_000_000.0f64, "end_time": 1_000_020.0f64,
                "current_zones": ["driveway"], "false_positive": false, "has_snapshot": true,
                "current_attributes": [
                    {"label": "license_plate", "box": [0.4, 0.5, 0.2, 0.15], "score": 0.8}
                ]
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), cam_id);
        let bytes = bytes::Bytes::from(payload.to_string());
        let ev = process_mqtt_payload(&bytes, &map, 0.3).unwrap().unwrap();
        let bbox = ev.plate_box.expect("plate_box captured");
        assert!((bbox[0] - 0.4).abs() < 1e-6);
        assert!((bbox[1] - 0.5).abs() < 1e-6);
        assert!((bbox[2] - 0.2).abs() < 1e-6);
        assert!((bbox[3] - 0.15).abs() < 1e-6);
    }
}
