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

/// Frigate camera name → detect resolution `(width, height)` in pixels, from
/// Frigate's `/api/config`. Needed because the live MQTT attribute boxes are
/// **pixel corners at the detect resolution** (verified on 0.18 against the
/// same event's normalized HTTP box) — without the frame dimensions no live
/// crop box can be normalized and every fresh read renders crop-less until an
/// API restart re-runs the HTTP backfill. Shared like [`SharedCameraMap`]:
/// fetched at provider start, refreshed on the same reload tick.
type SharedDetectDims = Arc<RwLock<HashMap<String, (f32, f32)>>>;

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
    /// Frigate camera name → detect `(width, height)`, from `/api/config`.
    /// Empty until the first successful fetch (crop boxes then fall back to
    /// `None`, exactly the old behavior); refreshed on the reload tick so a
    /// Frigate that was down at start, or a detect-resolution change, self-heals.
    detect_dims: SharedDetectDims,
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
            detect_dims: Arc::new(RwLock::new(HashMap::new())),
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
    /// transient DB error (never blanks a working map). The same tick also
    /// refreshes the Frigate detect resolutions (see [`SharedDetectDims`]) so a
    /// Frigate that was unreachable at start, or whose detect config changed,
    /// self-heals within a cycle.
    fn spawn_camera_map_reload(&self) {
        let pool = self.pool.clone();
        let map = Arc::clone(&self.camera_map);
        let dims = Arc::clone(&self.detect_dims);
        let api_base = self.cfg.api_base.clone();
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
                        // Refresh the detect resolutions on the same cadence.
                        // Keep the previous map on error (never blank a working
                        // one) — a fetch failure only means crop boxes normalize
                        // with possibly stale dims until the next tick.
                        if !api_base.trim().is_empty() {
                            match fetch_detect_dims(&api_base).await {
                                Ok(fresh) => {
                                    let mut guard = dims
                                        .write()
                                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                                    if *guard != fresh {
                                        let n = fresh.len();
                                        *guard = fresh;
                                        info!(cameras = n, "detection: Frigate detect resolutions reloaded");
                                    }
                                }
                                Err(e) => debug!(
                                    error = %e,
                                    "detection: Frigate detect-resolution reload failed (keeping previous)"
                                ),
                            }
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

        // ── 1.5 Frigate detect resolutions ────────────────────────────────────
        // The live MQTT attribute boxes are pixel corners at each camera's
        // detect resolution; without these dims no live crop box can be
        // normalized (issue #157). Non-fatal: on failure the reload task retries
        // on its tick, and until then reads simply carry no crop (old behavior).
        if !self.cfg.api_base.trim().is_empty() {
            match fetch_detect_dims(&self.cfg.api_base).await {
                Ok(fresh) => {
                    let n = fresh.len();
                    *self
                        .detect_dims
                        .write()
                        .unwrap_or_else(std::sync::PoisonError::into_inner) = fresh;
                    info!(cameras = n, "FrigateProvider: loaded detect resolutions");
                }
                Err(e) => warn!(
                    error = %e,
                    "FrigateProvider: detect-resolution fetch failed (crop boxes unavailable until retry)"
                ),
            }
        }

        // ── 2. MQTT subscription ──────────────────────────────────────────────
        let topic = format!("{}/events", self.cfg.mqtt_prefix);

        // Parse host + port (+ any URL-embedded creds) from the MQTT URL.
        // rumqttc expects host/port separately.
        let endpoint = parse_mqtt_url(&self.cfg.mqtt_url)?;

        let mut mqttoptions = MqttOptions::new(
            format!("crumb-api-{}", uuid::Uuid::new_v4()),
            &endpoint.host,
            endpoint.port,
        );
        mqttoptions.set_keep_alive(Duration::from_secs(30));
        mqttoptions.set_clean_session(true);
        // Allow internal reconnection queue depth.
        mqttoptions.set_inflight(100);
        // Broker authentication (optional). The homelab broker Frigate already
        // publishes to requires credentials; an anonymous broker leaves these
        // unset. The explicit `mqtt_user`/`mqtt_password` config fields win;
        // otherwise fall back to credentials embedded in the URL
        // (`mqtt://user:pass@host`).
        let mqtt_user = self.cfg.mqtt_user.clone().or(endpoint.username);
        let mqtt_password = self.cfg.mqtt_password.clone().or(endpoint.password);
        if let Some(user) = mqtt_user {
            mqttoptions.set_credentials(user, mqtt_password.unwrap_or_default());
        }

        let (client, mut event_loop) = AsyncClient::new(mqttoptions, 512);

        // Subscribe on first connection; rumqttc re-sends subscriptions on
        // reconnect automatically with clean_session = false, but since we use
        // clean_session = true we re-subscribe in the ConnAck handler.
        let topic_clone = topic.clone();
        let healthy_clone = Arc::clone(&self.healthy);
        let camera_map_clone = Arc::clone(&self.camera_map);
        let detect_dims_clone = Arc::clone(&self.detect_dims);
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
                            // Read the maps under scoped guards so they're
                            // dropped before the `.await` below (RwLock guard
                            // is !Send).
                            let parsed = {
                                let dims = detect_dims_clone
                                    .read()
                                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                                let map = camera_map_clone
                                    .read()
                                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                                process_mqtt_payload(&publish.payload, &map, min_score, &dims)
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
    //
    // NO `alias = "attributes"` here (issue #151): the MQTT `after`/`before`
    // state object carries the per-detection box list under `current_attributes`
    // AND, separately, an object-shaped `attributes` summary map (label → max
    // score). Aliasing `attributes` onto this field makes serde see the same
    // field twice on every 0.18 event → a *duplicate field* error that fails the
    // whole-envelope parse ("MQTT payload schema mismatch") and drops EVERY
    // detection. The unaliased `attributes` key is simply ignored (unknown
    // field). The HTTP `/api/events` `data` object is a *different* struct
    // (`FrigateApiEventData`) where the list is named `attributes` and there is
    // no `current_attributes` collision — that struct keeps the alias.
    #[serde(default, deserialize_with = "de_attributes")]
    current_attributes: Vec<serde_json::Value>,
    // The tracked object's best-snapshot summary. Frigate keeps the attributes
    // OF THE SNAPSHOT FRAME here (`snapshot.attributes`, same pixel-corner box
    // shape as `current_attributes` entries) — on the late frames that actually
    // emit a plate read (`current_attributes` already empty, plate out of view)
    // this is where the crop box still lives. Raw JSON so any shape change is
    // harmless (same tolerance discipline as `current_attributes`).
    #[serde(default)]
    snapshot: Option<serde_json::Value>,
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

/// Pull the `license_plate` attribute's raw box out of a Frigate attribute
/// list (`current_attributes` / `data.attributes` / `snapshot.attributes`),
/// VERBATIM — no unit interpretation here. The wire convention differs by
/// transport (both verified live on 0.18 against the same event, issue #157):
/// the HTTP `/api/events` `data.attributes` box is **normalized `[x, y, w, h]`**
/// (top-left + size in `0..=1`), while the MQTT `current_attributes` /
/// `snapshot.attributes` box is **pixel corners `[x1, y1, x2, y2]`** at the
/// camera's detect resolution. [`normalize_plate_box`] disambiguates and
/// normalizes. Tolerant: a missing entry, a non-numeric or non-4-element `box`,
/// or the plate attribute simply being absent all yield `None` — never an error.
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
/// live `/api/events` payload — e.g. `[0.7646, 0.5611, 0.0536, 0.0556]` and,
/// on 0.18, `[0.7973958, 0.7870370, 0.0635416, 0.0796296]`. Snapshots are
/// full-frame (`snapshots.crop=false`), so these fractions map straight onto the
/// snapshot the report crops — the common path needs no frame dimensions.
///
/// This is **defensive** parsing (issue #142): 0.18 was verified to use the
/// same shape as before, but a future Frigate must not be able to silently
/// break crops, so three plausible shapes are tolerated in a fixed precedence.
///
/// # Precedence (first match wins)
///
/// 1. **Normalized `[x, y, w, h]`** — all coords in `0..=1`, `w>0 && h>0`, and
///    the box FITS as origin+size (`x+w <= 1 && y+h <= 1`). Returned as-is. This
///    is the primary/observed Frigate shape and always wins when it applies, so
///    a real (small) plate box is never re-interpreted as anything else.
/// 2. **Normalized corners `[x1, y1, x2, y2]`** — all coords in `0..=1`,
///    `x2>x1 && y2>y1`, reached only when the values do NOT already validate as
///    a fitting `xywh` (rule 1). Converted to `[x1, y1, x2-x1, y2-y1]`. Since a
///    real plate's `w`/`h` are small, an `xywh` plate has `x2<x1` (its `w` slot
///    is smaller than its `x` slot) and can never satisfy the corners test —
///    the disambiguation is robust for real plates.
/// 3. **Clamped normalized `[x, y, w, h]`** — an in-unit box that overflows the
///    frame and is not valid corners: clamp the size so it stays inside
///    (best-effort for slightly-out-of-range data).
/// 4. **Pixel corners `[x1, y1, x2, y2]`** (any coord `>1`) WITH frame
///    dimensions: divide by the frame size. This is the **verified live MQTT
///    shape** (issue #157): Frigate 0.18 publishes the attribute box as pixel
///    corners at the camera's detect resolution — e.g. MQTT `[1569, 638, 1668,
///    695]` for the very event whose HTTP form is the normalized `[0.8172,
///    0.5907, 0.0516, 0.0528]` × a 1920x1080 detect. Corners win whenever
///    `x2>x1 && y2>y1`; a pixel `[x, y, w, h]` that can't be corners (`w <= x`
///    — a plate's width is far smaller than its typical offset) falls through
///    to origin+size scaling, clamped inside the frame.
/// 5. Pixel coords with no frame dimensions: `None` — we don't invent a scale.
///
/// Returns `None` for a `None` input or a degenerate (zero-area) box.
fn normalize_plate_box(raw: Option<[f32; 4]>, frame: Option<(f32, f32)>) -> Option<[f32; 4]> {
    let [a, b, c, d] = raw?;
    let in_unit = |v: f32| (0.0..=1.0).contains(&v);

    if in_unit(a) && in_unit(b) && in_unit(c) && in_unit(d) {
        // Rule 1 — clean, fitting [x, y, w, h] (the shape Frigate sends). Wins
        // whenever it applies, so a real plate box is never read as corners.
        if c > 0.0 && d > 0.0 && a + c <= 1.0 && b + d <= 1.0 {
            return Some([a, b, c, d]);
        }
        // Rule 2 — normalized corners [x1, y1, x2, y2], only when NOT a fitting
        // xywh above. All in-unit with x2>x1 && y2>y1 ⇒ the derived w/h are >0
        // and the box is inside the frame by construction.
        if c > a && d > b {
            return Some([a, b, c - a, d - b]);
        }
        // Rule 3 — in-unit xywh that overflows the frame: clamp the size inside.
        let cw = c.clamp(0.0, 1.0 - a);
        let ch = d.clamp(0.0, 1.0 - b);
        return (cw > 0.0 && ch > 0.0).then_some([a, b, cw, ch]);
    }

    // Rule 4 — pixel coords: only normalizable with frame dimensions.
    if let Some((fw, fh)) = frame {
        if fw > 0.0 && fh > 0.0 {
            let nx = (a / fw).clamp(0.0, 1.0);
            let ny = (b / fh).clamp(0.0, 1.0);
            // Corners [x1, y1, x2, y2] first — the verified Frigate MQTT shape.
            // A real pixel-corners plate always has x2>x1 && y2>y1, so this
            // reading wins whenever it applies.
            if c > a && d > b {
                let nx2 = (c / fw).clamp(0.0, 1.0);
                let ny2 = (d / fh).clamp(0.0, 1.0);
                return (nx2 > nx && ny2 > ny).then_some([nx, ny, nx2 - nx, ny2 - ny]);
            }
            // Pixel [x, y, w, h] fallback (defensive; not observed on the wire).
            let nw = (c / fw).clamp(0.0, 1.0 - nx);
            let nh = (d / fh).clamp(0.0, 1.0 - ny);
            return (nw > 0.0 && nh > 0.0).then_some([nx, ny, nw, nh]);
        }
    }

    // Rule 5 — pixel coords, no frame dims: don't guess a scale.
    None
}

/// Pull the plate attribute box out of a `snapshot` sub-object's `attributes`
/// list (raw JSON). Frigate keeps the snapshot FRAME's attributes here, so the
/// late, boxless frames that actually emit a plate read (empty
/// `current_attributes` — the plate already left view) still carry the crop
/// box of the moment the snapshot was taken. Same tolerant contract as
/// [`plate_box_from_attributes`]: any missing/odd shape yields `None`.
fn plate_box_from_snapshot(snapshot: Option<&serde_json::Value>) -> Option<[f32; 4]> {
    snapshot
        .and_then(|s| s.get("attributes"))
        .and_then(serde_json::Value::as_array)
        .and_then(|a| plate_box_from_attributes(a))
}

/// Process one MQTT payload and, if it passes all filters, return a
/// [`NormalizedEvent`].  Returns `Ok(None)` when the event is filtered.
///
/// `detect_dims` maps the Frigate camera name to its detect resolution (from
/// `/api/config`) — required to normalize the pixel-corner attribute boxes the
/// live MQTT feed carries (issue #157). An absent entry only costs the crop
/// box, never the plate text or the detection.
fn process_mqtt_payload(
    payload: &bytes::Bytes,
    camera_map: &HashMap<String, Uuid>,
    min_score: f32,
    detect_dims: &HashMap<String, (f32, f32)>,
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
        // Plate crop box. The stored `snapshot_url` serves Frigate's
        // best-snapshot, so only THAT frame's own `snapshot.attributes` box is
        // guaranteed to line up with the image a client crops (issue #179). The
        // live `current_attributes` is this MQTT frame, which is frequently a
        // different frame than the best snapshot, so a crop to it lands off the
        // plate — on the hood after the car moved, or off-frame (a black crop).
        // Prefer the snapshot box; fall back to `current_attributes` only when
        // the snapshot carries none. When neither exists the box is left None
        // and the client renders the full frame instead of a mismatched crop.
        // Boxes are pixel corners at the detect resolution (needs `detect_dims`);
        // a normalized 0..1 box (the HTTP shape) passes through regardless.
        // Best-effort — None never affects the plate text / detection path.
        plate_box: normalize_plate_box(
            plate_box_from_snapshot(after.snapshot.as_ref())
                .or_else(|| plate_box_from_attributes(&after.current_attributes)),
            detect_dims.get(&after.camera).copied(),
        ),
        // Frigate hands Crumb a snapshot URL to proxy, not raw crop bytes.
        plate_crop: None,
        raw: raw_value,
    }))
}

/// Fetch each camera's detect resolution from Frigate's `/api/config` —
/// `cameras.<name>.detect.{width,height}`. The live MQTT attribute boxes are
/// pixel corners at this resolution, so without these dims no live crop box
/// can be normalized (issue #157). Parsed leniently off raw JSON (the config
/// document is huge and version-varying); cameras without usable dims are
/// simply absent from the map.
async fn fetch_detect_dims(api_base: &str) -> Result<HashMap<String, (f32, f32)>> {
    let url = format!("{}/api/config", api_base.trim_end_matches('/'));
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .context("build reqwest client")?;
    let resp = client
        .get(&url)
        .send()
        .await
        .context("Frigate /api/config request")?;
    if !resp.status().is_success() {
        anyhow::bail!("Frigate /api/config returned HTTP {}", resp.status());
    }
    let config: serde_json::Value = resp
        .json()
        .await
        .context("parse Frigate /api/config JSON")?;
    Ok(detect_dims_from_config(&config))
}

/// Pure extraction half of [`fetch_detect_dims`] (unit-testable): pull
/// `cameras.<name>.detect.{width,height}` pairs out of a Frigate config
/// document, skipping cameras with missing or non-positive dimensions.
fn detect_dims_from_config(config: &serde_json::Value) -> HashMap<String, (f32, f32)> {
    let mut out = HashMap::new();
    let Some(cameras) = config.get("cameras").and_then(serde_json::Value::as_object) else {
        return out;
    };
    for (name, cam) in cameras {
        let detect = cam.get("detect");
        let w = detect
            .and_then(|d| d.get("width"))
            .and_then(serde_json::Value::as_f64);
        let h = detect
            .and_then(|d| d.get("height"))
            .and_then(serde_json::Value::as_f64);
        if let (Some(w), Some(h)) = (w, h) {
            #[allow(clippy::cast_possible_truncation)]
            if w > 0.0 && h > 0.0 {
                out.insert(name.clone(), (w as f32, h as f32));
            }
        }
    }
    out
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
    // Plate crop box. Frigate's HTTP `/api/events` `data` object names this list
    // `attributes` (verified on 0.18: `data.attributes[].box`), whereas the MQTT
    // state object uses `current_attributes` — accept BOTH via `alias` (issue
    // #142) so the HTTP backfill actually captures the plate crop box instead of
    // silently yielding None. Tolerant/default so an odd/absent shape is
    // harmless. See `plate_box_from_attributes`.
    #[serde(default, alias = "attributes", deserialize_with = "de_attributes")]
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
            plate_crop: None,
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

/// A broker endpoint parsed from an MQTT URL: host, port, and any credentials
/// embedded in the URL's userinfo (`mqtt://user:pass@host`).
#[derive(Debug, PartialEq, Eq)]
struct MqttEndpoint {
    host: String,
    port: u16,
    username: Option<String>,
    password: Option<String>,
}

/// Parse an MQTT broker URL into host, port, and any embedded credentials.
///
/// Uses the `url` crate for a proper authority parse so it handles the cases the
/// old naive `split_once(':')` got wrong:
/// - **IPv6 literals** — `mqtt://[::1]:1883` (the bare `::1` splits at the first
///   colon and mangles the host); the brackets are stripped from the returned
///   host so rumqttc gets the bare address it needs to resolve.
/// - **Userinfo** — `mqtt://user:pass@host` (the `user:pass@host` authority also
///   splits wrong on the first colon). Any credentials are returned separately.
///
/// Accepts a bare `host[:port]` with no scheme (a default `mqtt://` is prepended)
/// and `mqtts://`. Port defaults to 1883 when absent.
fn parse_mqtt_url(url: &str) -> Result<MqttEndpoint> {
    // The `url` crate needs a scheme to parse an authority; accept the legacy
    // bare `host[:port]` form by supplying one.
    let with_scheme = if url.contains("://") {
        url.to_owned()
    } else {
        format!("mqtt://{url}")
    };

    let parsed = ::url::Url::parse(&with_scheme)
        .with_context(|| format!("MQTT URL '{url}' is not a valid URL"))?;

    let host = parsed
        .host_str()
        .filter(|h| !h.is_empty())
        .with_context(|| format!("MQTT URL '{url}' has no host"))?;
    // `url` returns IPv6 hosts bracketed (`[::1]`); rumqttc wants the bare
    // address for socket/DNS resolution.
    let host = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host)
        .to_owned();

    let port = parsed.port().unwrap_or(1883);

    // Credentials embedded in the URL, if any. An empty username means none.
    let username = match parsed.username() {
        "" => None,
        u => Some(u.to_owned()),
    };
    let password = parsed.password().map(ToOwned::to_owned);

    Ok(MqttEndpoint {
        host,
        port,
        username,
        password,
    })
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
        let ep = parse_mqtt_url("mqtt://192.0.2.10:1883").unwrap();
        assert_eq!(ep.host, "192.0.2.10");
        assert_eq!(ep.port, 1883);
        assert_eq!(ep.username, None);
        assert_eq!(ep.password, None);
    }

    #[test]
    fn parse_mqtt_url_without_port() {
        let ep = parse_mqtt_url("mqtt://192.0.2.10").unwrap();
        assert_eq!(ep.host, "192.0.2.10");
        assert_eq!(ep.port, 1883);
    }

    #[test]
    fn parse_mqtt_url_no_scheme() {
        let ep = parse_mqtt_url("192.0.2.10:1883").unwrap();
        assert_eq!(ep.host, "192.0.2.10");
        assert_eq!(ep.port, 1883);
    }

    #[test]
    fn parse_mqtt_url_ipv6_literal() {
        // The old split_once(':') parser mangled bracketed IPv6 literals. The
        // brackets must be stripped so rumqttc gets the bare address.
        let ep = parse_mqtt_url("mqtt://[::1]:1883").unwrap();
        assert_eq!(ep.host, "::1");
        assert_eq!(ep.port, 1883);

        // IPv6 without an explicit port defaults to 1883.
        let ep2 = parse_mqtt_url("mqtt://[2001:db8::1]").unwrap();
        assert_eq!(ep2.host, "2001:db8::1");
        assert_eq!(ep2.port, 1883);
    }

    #[test]
    fn parse_mqtt_url_with_credentials() {
        // user:pass@host — the old parser split on the first ':' and produced a
        // bogus host/port; the creds must now be extracted and the host clean.
        let ep = parse_mqtt_url("mqtt://frigate:s3cr3t@broker.lan:1884").unwrap();
        assert_eq!(ep.host, "broker.lan");
        assert_eq!(ep.port, 1884);
        assert_eq!(ep.username.as_deref(), Some("frigate"));
        assert_eq!(ep.password.as_deref(), Some("s3cr3t"));
    }

    #[test]
    fn parse_mqtt_url_ipv6_with_credentials() {
        // Both hard cases at once: userinfo AND a bracketed IPv6 literal.
        let ep = parse_mqtt_url("mqtts://user:pw@[fe80::1]:8883").unwrap();
        assert_eq!(ep.host, "fe80::1");
        assert_eq!(ep.port, 8883);
        assert_eq!(ep.username.as_deref(), Some("user"));
        assert_eq!(ep.password.as_deref(), Some("pw"));
    }

    #[test]
    fn parse_mqtt_url_username_only() {
        // A username with no password is valid userinfo.
        let ep = parse_mqtt_url("mqtt://frigate@broker.lan").unwrap();
        assert_eq!(ep.host, "broker.lan");
        assert_eq!(ep.username.as_deref(), Some("frigate"));
        assert_eq!(ep.password, None);
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
        let result = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new()).unwrap();
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
        let result = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new()).unwrap();
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
        let result = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new()).unwrap();
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
        let result = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new()).unwrap();
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
        let result = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new()).unwrap();
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
        let result = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new()).unwrap();
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
        let result = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new()).unwrap();
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
        let result = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new()).unwrap();
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
        // Pixel corners [x1,y1,x2,y2] — the VERIFIED live Frigate 0.18 MQTT
        // shape (issue #157): the real captured attribute box [1569, 638,
        // 1668, 695] on a 1920x1080 detect must match the normalized xywh
        // ([0.8172, 0.5907, 0.0516, 0.0528]) the HTTP API returned for the
        // very same event.
        let got = normalize_plate_box(Some([1569.0, 638.0, 1668.0, 695.0]), Some((1920.0, 1080.0)))
            .expect("pixel corners normalize with dims");
        assert!((got[0] - 0.817_187_5).abs() < 1e-5, "x1 = 1569/1920");
        assert!((got[1] - 0.590_740_7).abs() < 1e-5, "y1 = 638/1080");
        assert!((got[2] - 0.051_562_5).abs() < 1e-5, "w = (1668-1569)/1920");
        assert!((got[3] - 0.052_777_8).abs() < 1e-5, "h = (695-638)/1080");
    }

    #[test]
    fn normalize_plate_box_pixel_xywh_fallback_with_frame_dims() {
        // A pixel box that CANNOT be corners (c <= a: 100 <= 300) falls through
        // to the defensive origin+size scaling.
        let got =
            normalize_plate_box(Some([300.0, 150.0, 100.0, 50.0]), Some((1000.0, 500.0))).unwrap();
        assert!((got[0] - 0.3).abs() < 1e-6, "x = 300/1000");
        assert!((got[1] - 0.3).abs() < 1e-6, "y = 150/500");
        assert!((got[2] - 0.1).abs() < 1e-6, "w = 100/1000");
        assert!((got[3] - 0.1).abs() < 1e-6, "h = 50/500");
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
    fn normalize_plate_box_prefers_xywh_over_corners_for_the_real_018_shape() {
        // The captured Frigate 0.18 attribute box is normalized [x, y, w, h]
        // with a small w/h. It FITS as origin+size, so rule 1 (xywh) wins and it
        // passes through unchanged — it must NOT be re-read as corners (as
        // corners its x2=0.0635 < x1=0.7974, so the corners test can't even
        // match — the disambiguation is robust for a real plate).
        let got = normalize_plate_box(
            Some([0.797_395_8, 0.787_037, 0.063_541_6, 0.079_629_6]),
            None,
        )
        .expect("0.18 xywh box normalizes");
        assert!((got[0] - 0.797_395_8).abs() < 1e-5, "x passthrough");
        assert!((got[1] - 0.787_037).abs() < 1e-5, "y passthrough");
        assert!(
            (got[2] - 0.063_541_6).abs() < 1e-5,
            "w passthrough (not x2-x1)"
        );
        assert!(
            (got[3] - 0.079_629_6).abs() < 1e-5,
            "h passthrough (not y2-y1)"
        );
    }

    #[test]
    fn normalize_plate_box_accepts_normalized_corners() {
        // Corners [x1, y1, x2, y2] with x2>x1 && y2>y1 that do NOT fit as xywh
        // (x+w = 0.10+0.95 = 1.05 > 1, so rule 1 can't claim it) → converted to
        // [x1, y1, x2-x1, y2-y1].
        let got = normalize_plate_box(Some([0.10, 0.20, 0.95, 0.98]), None)
            .expect("corners box normalizes");
        assert!((got[0] - 0.10).abs() < 1e-6, "x1");
        assert!((got[1] - 0.20).abs() < 1e-6, "y1");
        assert!((got[2] - 0.85).abs() < 1e-6, "w = x2 - x1");
        assert!((got[3] - 0.78).abs() < 1e-6, "h = y2 - y1");
    }

    #[test]
    fn normalize_plate_box_corners_stay_inside_frame() {
        // A corners box near the far edge that does NOT fit as xywh
        // (0.15 + 0.9 > 1) is read as corners → w/h keep it inside the frame by
        // construction (x1+w = x2 <= 1, y1+h = y2 <= 1).
        let got =
            normalize_plate_box(Some([0.15, 0.10, 0.90, 0.95]), None).expect("edge corners box");
        assert!((got[0] - 0.15).abs() < 1e-6, "x1");
        assert!((got[1] - 0.10).abs() < 1e-6, "y1");
        assert!((got[2] - 0.75).abs() < 1e-6, "w = x2 - x1, inside frame");
        assert!((got[3] - 0.85).abs() < 1e-6, "h = y2 - y1, inside frame");
        assert!(got[0] + got[2] <= 1.0 + 1e-6, "x1 + w <= 1");
        assert!(got[1] + got[3] <= 1.0 + 1e-6, "y1 + h <= 1");
    }

    #[test]
    fn frigate_018_http_event_extracts_plate_and_box() {
        // The real Frigate 0.18 HTTP `/api/events` shape the maintainer captured:
        // plate + scores + the `license_plate` attribute box all live under
        // `data`, and the attribute list is named `attributes` (NOT
        // `current_attributes`). Deserialize it and assert both the plate string
        // and the normalized [x, y, w, h] crop box are extracted.
        let body = serde_json::json!({
            "id": "1700000000.123-abcd",
            "camera": "driveway",
            "label": "car",
            "start_time": 1_700_000_000.0f64,
            "end_time": 1_700_000_020.0f64,
            "has_snapshot": true,
            "false_positive": null,
            "zones": ["driveway"],
            "data": {
                "score": 0.9,
                "top_score": 0.95,
                "recognized_license_plate": ["23134X1", 0.994f64],
                "box": [0.79, 0.78, 0.86, 0.87],
                "region": [0.7, 0.7, 0.95, 0.95],
                "attributes": [
                    {"label": "license_plate",
                     "box": [0.797_395_8, 0.787_037, 0.063_541_6, 0.079_629_6],
                     "score": 0.8}
                ]
            }
        });
        let ev: FrigateApiEvent =
            serde_json::from_value(body).expect("0.18 HTTP event deserializes");
        let data = ev.data.expect("data present");

        // Plate string extracted from `data.recognized_license_plate` (HTTP).
        let (plate, score) = data
            .recognized_license_plate
            .clone()
            .expect("plate present under data");
        assert_eq!(plate, "23134X1");
        assert!((score.expect("plate score") - 0.994).abs() < 1e-3);

        // Attribute box captured (via the `attributes` alias) and normalized.
        let bbox = normalize_plate_box(plate_box_from_attributes(&data.current_attributes), None)
            .expect("plate crop box extracted from data.attributes");
        assert!((bbox[0] - 0.797_395_8).abs() < 1e-5);
        assert!((bbox[1] - 0.787_037).abs() < 1e-5);
        assert!((bbox[2] - 0.063_541_6).abs() < 1e-5);
        assert!((bbox[3] - 0.079_629_6).abs() < 1e-5);
    }

    #[test]
    fn frigate_mqtt_event_extracts_plate_under_after() {
        // Sibling to the HTTP test: the MQTT envelope carries the plate on
        // `after.recognized_license_plate` (a [plate, score] array) and the box
        // on `after.current_attributes`. Confirms the plate is read from `after`
        // (not `data`) on the MQTT path.
        let cam_id = Uuid::new_v4();
        let payload = serde_json::json!({
            "type": "end",
            "before": null,
            "after": {
                "id": "abc123", "camera": "driveway", "label": "car",
                "sub_label": null,
                "recognized_license_plate": ["23134X1", 0.994f64],
                "score": 0.9, "top_score": 0.95,
                "start_time": 1_000_000.0f64, "end_time": 1_000_020.0f64,
                "current_zones": ["driveway"], "false_positive": false, "has_snapshot": true,
                "current_attributes": [
                    {"label": "license_plate",
                     "box": [0.797_395_8, 0.787_037, 0.063_541_6, 0.079_629_6],
                     "score": 0.8}
                ]
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), cam_id);
        let bytes = bytes::Bytes::from(payload.to_string());
        let ev = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new())
            .unwrap()
            .unwrap();
        assert_eq!(ev.recognized_plate.as_deref(), Some("23134X1"));
        assert!((ev.plate_confidence.expect("confidence") - 0.994).abs() < 1e-3);
        let bbox = ev.plate_box.expect("plate_box captured on MQTT path");
        assert!((bbox[0] - 0.797_395_8).abs() < 1e-5);
        assert!((bbox[2] - 0.063_541_6).abs() < 1e-5);
    }

    #[test]
    fn frigate_018_mqtt_after_with_attributes_summary_map_parses() {
        // Regression for #151. Frigate 0.18's live MQTT `after` object carries
        // BOTH the per-detection box list (`current_attributes`, an array) AND a
        // separate object-shaped `attributes` summary map (label → max score).
        // The old `#[serde(alias = "attributes")]` on `current_attributes` made
        // serde see the field twice → a duplicate-field error that failed the
        // whole-envelope parse ("MQTT payload schema mismatch") on EVERY 0.18
        // event, silently dropping all detections. The unaliased field must
        // ignore the summary map and still read the box from `current_attributes`.
        let cam_id = Uuid::new_v4();
        let payload = serde_json::json!({
            "type": "new",
            "before": null,
            "after": {
                "id": "abc123", "camera": "driveway", "label": "car",
                "sub_label": null,
                "recognized_license_plate": ["23134X1", 0.994f64],
                "score": 0.9, "top_score": 0.95,
                "start_time": 1_000_000.0f64, "end_time": null,
                "current_zones": ["driveway"], "false_positive": false, "has_snapshot": true,
                // The object-shaped summary map that 0.18 sends alongside.
                "attributes": {"license_plate": 0.994, "car": 0.9},
                "current_attributes": [
                    {"label": "license_plate",
                     "box": [0.797_395_8, 0.787_037, 0.063_541_6, 0.079_629_6],
                     "score": 0.8}
                ]
            }
        });
        let mut map = HashMap::new();
        map.insert("driveway".to_owned(), cam_id);
        let bytes = bytes::Bytes::from(payload.to_string());
        let ev = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new())
            .expect("0.18 after with attributes summary map must parse")
            .expect("event produced");
        assert_eq!(ev.recognized_plate.as_deref(), Some("23134X1"));
        let bbox = ev.plate_box.expect("plate_box captured");
        assert!((bbox[0] - 0.797_395_8).abs() < 1e-5);
        assert!((bbox[2] - 0.063_541_6).abs() < 1e-5);
    }

    #[test]
    fn frigate_http_event_accepts_current_attributes_alias() {
        // Defensive: if a Frigate build ever names the HTTP `data` list
        // `current_attributes` (the MQTT name) instead of `attributes`, the
        // alias still captures the box — neither name silently drops the crop.
        let body = serde_json::json!({
            "id": "x", "camera": "driveway", "label": "car",
            "start_time": 1.0f64, "has_snapshot": true,
            "data": {
                "score": 0.9,
                "current_attributes": [
                    {"label": "license_plate", "box": [0.4, 0.5, 0.2, 0.15], "score": 0.8}
                ]
            }
        });
        let ev: FrigateApiEvent = serde_json::from_value(body).expect("deserializes");
        let data = ev.data.expect("data present");
        let bbox = normalize_plate_box(plate_box_from_attributes(&data.current_attributes), None)
            .expect("box via current_attributes alias");
        assert!((bbox[0] - 0.4).abs() < 1e-6);
        assert!((bbox[2] - 0.2).abs() < 1e-6);
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
        let ev = process_mqtt_payload(&bytes, &map, 0.3, &HashMap::new())
            .unwrap()
            .unwrap();
        let bbox = ev.plate_box.expect("plate_box captured");
        assert!((bbox[0] - 0.4).abs() < 1e-6);
        assert!((bbox[1] - 0.5).abs() < 1e-6);
        assert!((bbox[2] - 0.2).abs() < 1e-6);
        assert!((bbox[3] - 0.15).abs() < 1e-6);
    }

    #[test]
    fn process_mqtt_prefers_snapshot_box_over_current_attributes() {
        // Issue #179: the stored snapshot_url serves Frigate's best-snapshot, so
        // the crop box MUST come from `snapshot.attributes` (that frame's own
        // box), not `current_attributes` (this MQTT frame, frequently a
        // different frame). When both are present they must resolve to the
        // SNAPSHOT box so the crop lines up with the image the client renders.
        let cam_id = Uuid::new_v4();
        let payload = serde_json::json!({
            "type": "end",
            "after": {
                "id": "abc123", "camera": "lpr", "label": "car",
                "recognized_license_plate": ["23134X1", 0.994f64],
                "score": 0.9, "top_score": 0.95,
                "start_time": 1_000_000.0f64, "end_time": 1_000_020.0f64,
                "current_zones": [], "false_positive": false, "has_snapshot": true,
                // This MQTT frame's box — a DIFFERENT frame than the best snapshot.
                "current_attributes": [
                    {"label": "license_plate", "box": [100, 100, 200, 150], "score": 0.8}
                ],
                "snapshot": {
                    "frame_time": 1_000_010.0f64,
                    "attributes": [
                        {"label": "license_plate", "box": [1569, 638, 1668, 695], "score": 0.79}
                    ]
                }
            }
        });
        let mut map = HashMap::new();
        map.insert("lpr".to_owned(), cam_id);
        let mut dims = HashMap::new();
        dims.insert("lpr".to_owned(), (1920.0_f32, 1080.0_f32));
        let bytes = bytes::Bytes::from(payload.to_string());
        let ev = process_mqtt_payload(&bytes, &map, 0.3, &dims)
            .unwrap()
            .unwrap();
        let bbox = ev.plate_box.expect("snapshot plate_box");
        // Snapshot box (1569/1920 ≈ 0.817), NOT the current-frame box (100/1920 ≈ 0.052).
        assert!(
            (bbox[0] - 0.817_187_5).abs() < 1e-5,
            "must use the frame-consistent snapshot box, not current_attributes"
        );
    }

    #[test]
    fn process_mqtt_end_frame_gets_box_from_snapshot_attributes() {
        // Full-pipeline sibling of the peek test: an `end` frame with empty
        // current_attributes but a snapshot carrying the pixel-corner plate box
        // must emit an event whose plate_box is normalized — this is the frame
        // that actually creates the plate read, so the crop box lands AT INGEST
        // instead of waiting for a restart's HTTP backfill (issue #157).
        let cam_id = Uuid::new_v4();
        let payload = serde_json::json!({
            "type": "end",
            "before": null,
            "after": {
                "id": "abc123", "camera": "lpr", "label": "car",
                "sub_label": null,
                "recognized_license_plate": ["23134X1", 0.994f64],
                "score": 0.9, "top_score": 0.95,
                "start_time": 1_000_000.0f64, "end_time": 1_000_020.0f64,
                "current_zones": [], "false_positive": false, "has_snapshot": true,
                "current_attributes": [],
                "snapshot": {
                    "frame_time": 1_000_010.0f64,
                    "attributes": [
                        {"label": "license_plate", "box": [1569, 638, 1668, 695], "score": 0.79}
                    ]
                }
            }
        });
        let mut map = HashMap::new();
        map.insert("lpr".to_owned(), cam_id);
        let mut dims = HashMap::new();
        dims.insert("lpr".to_owned(), (1920.0_f32, 1080.0_f32));
        let bytes = bytes::Bytes::from(payload.to_string());
        let ev = process_mqtt_payload(&bytes, &map, 0.3, &dims)
            .unwrap()
            .unwrap();
        assert_eq!(ev.recognized_plate.as_deref(), Some("23134X1"));
        let bbox = ev
            .plate_box
            .expect("plate_box from snapshot.attributes at ingest");
        assert!((bbox[0] - 0.817_187_5).abs() < 1e-5);
        assert!((bbox[2] - 0.051_562_5).abs() < 1e-5);
    }

    #[test]
    fn detect_dims_from_config_parses_cameras() {
        // The subset of Frigate /api/config we consume: cameras.<name>.detect.
        // Cameras with missing or non-positive dims are skipped, never invented.
        let config = serde_json::json!({
            "mqtt": {"host": "127.0.0.1"},
            "cameras": {
                "lpr": {"detect": {"width": 1920, "height": 1080, "enabled": true}},
                "driveway": {"detect": {"width": 1280, "height": 720}},
                "nodetect": {"ffmpeg": {}},
                "zero": {"detect": {"width": 0, "height": 720}}
            }
        });
        let dims = detect_dims_from_config(&config);
        assert_eq!(dims.get("lpr"), Some(&(1920.0, 1080.0)));
        assert_eq!(dims.get("driveway"), Some(&(1280.0, 720.0)));
        assert_eq!(dims.get("nodetect"), None, "no detect block → skipped");
        assert_eq!(dims.get("zero"), None, "non-positive dims → skipped");
        assert_eq!(detect_dims_from_config(&serde_json::json!({})).len(), 0);
    }
}
