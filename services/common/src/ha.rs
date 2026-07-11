//! Shared Home Assistant REST client + event source, used by both the API
//! (admin config, entity picker, Phase-2 sensor surfacing) and the recorder
//! (`motion_source='ha'`). REST-only in Phase 1/2; a WebSocket source (#53) will
//! implement the same [`HaEventSource`] trait later with no change to callers.
//!
//! # Correctness invariant (do NOT weaken)
//!
//! A failed poll returns `Err`. The caller's loop then **exits**, which is what
//! arms the recorder's fail-open rail (a `motion_source='ha'` camera records
//! *everything* while HA is unreachable, rather than sitting motion-gated and
//! silently missing footage). The bounded HTTP timeout below is the liveness
//! check — a dead HA surfaces as an `Err` in ~5s, so there is no keepalive to
//! maintain. **Never** turn a poll failure into `Ok(empty)` or an in-loop retry:
//! that reopens the ~39s footage-loss window the transport spike measured.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use anyhow::{Context, Result};
use async_trait::async_trait;
use chrono::{DateTime, Utc};

use crate::types::HaSettings;

/// A Home Assistant REST client (base URL + long-lived token). Timeouts are
/// bounded so a dead/hung HA surfaces as an `Err` quickly.
#[derive(Clone)]
pub struct HaClient {
    http: reqwest::Client,
    base_url: String,
    token: String,
}

impl HaClient {
    /// Build a client from settings, or `None` if HA isn't configured (no base
    /// URL / token) so callers can treat "unconfigured" distinctly from an error.
    pub fn from_settings(s: &HaSettings) -> Option<Self> {
        let token = s.token.clone().unwrap_or_default();
        if s.base_url.trim().is_empty() || token.trim().is_empty() {
            return None;
        }
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(5))
            .build()
            .ok()?;
        Some(Self {
            http,
            base_url: s.base_url.trim_end_matches('/').to_owned(),
            token,
        })
    }

    async fn get(&self, path: &str) -> Result<reqwest::Response> {
        // The token is a header, never in the URL, so a reqwest error string
        // (URL + kind) can't leak it.
        self.http
            .get(format!("{}{path}", self.base_url))
            .bearer_auth(&self.token)
            .send()
            .await
            .context("Home Assistant request failed")
    }

    /// `GET /api/` — a cheap authenticated reachability check. `Ok` on 2xx.
    pub async fn test_connection(&self) -> Result<()> {
        let resp = self.get("/api/").await?;
        let code = resp.status();
        if code.is_success() {
            Ok(())
        } else if code.as_u16() == 401 {
            anyhow::bail!("Home Assistant rejected the token (HTTP 401)")
        } else {
            anyhow::bail!("Home Assistant returned HTTP {}", code.as_u16())
        }
    }

    /// `GET /api/states` — the full array of entity state objects.
    pub async fn get_states(&self) -> Result<Vec<serde_json::Value>> {
        let resp = self.get("/api/states").await?;
        if !resp.status().is_success() {
            anyhow::bail!("Home Assistant returned HTTP {}", resp.status().as_u16());
        }
        resp.json().await.context("Home Assistant states parse")
    }

    /// Current `(entity_id, state)` for the given entities. HA has no bulk
    /// get-by-id, so this filters the full `/api/states` read (cheap at homelab
    /// scale; the one bounded request doubles as the liveness check).
    pub async fn get_states_for(&self, entity_ids: &[String]) -> Result<Vec<(String, String)>> {
        let all = self.get_states().await?;
        let wanted: HashSet<&str> = entity_ids.iter().map(String::as_str).collect();
        Ok(all
            .iter()
            .filter_map(|s| {
                let eid = s.get("entity_id")?.as_str()?;
                if !wanted.contains(eid) {
                    return None;
                }
                let state = s.get("state")?.as_str()?.to_owned();
                Some((eid.to_owned(), state))
            })
            .collect())
    }
}

/// One observed state edge for a linked entity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntityEdge {
    pub entity_id: String,
    pub on: bool,
    pub at: DateTime<Utc>,
}

/// Map an HA state string to on/off, or `None` for indeterminate states.
/// `None` must NOT be read as "off": an entity going `unavailable` must not look
/// like "motion stopped" and cut recording.
pub fn edge_on(state: &str) -> Option<bool> {
    match state.trim().to_ascii_lowercase().as_str() {
        "on" | "open" | "detected" | "true" | "home" | "motion" | "occupied" => Some(true),
        "off" | "closed" | "clear" | "false" | "not_home" | "no_motion" => Some(false),
        _ => None, // unavailable / unknown / anything else: no new information
    }
}

/// Map an HA `device_class` to the Crumb event **label slug** used for a
/// motion-role sensor's timeline glyph + notification text. The slug is the
/// per-label `icon_key` (see `crumb_common::detection::icon_key_for_label`), so
/// clients render the matching glyph and capitalize the slug for display.
///
/// `"motion"` deliberately collapses the plain-motion classes: it reuses the
/// existing motion glyph, which is filtered out of the timeline dot row, so an
/// HA motion sensor reads as motion (like the pixel/Frigate sources) rather than
/// a distinct icon. Unknown / absent classes fall back to `"sensor"`.
#[must_use]
pub fn label_for_device_class(device_class: Option<&str>) -> &'static str {
    let normalized = device_class.map(|c| c.trim().to_ascii_lowercase());
    match normalized.as_deref() {
        Some("motion" | "moving" | "vibration") => "motion",
        Some("occupancy" | "presence") => "occupancy",
        Some("door" | "opening") => "door",
        Some("window") => "window",
        Some("garage_door") => "garage",
        _ => "sensor",
    }
}

/// Diff current `(entity_id, state)` readings against the last-known on/off map,
/// emitting an edge per *changed* entity and updating `last`. Pure + testable.
///
/// The FIRST observation of an entity seeds `last` silently (no edge), so a fresh
/// source (startup or reconnect) never emits a spurious edge. Indeterminate
/// states (`edge_on` → `None`) emit nothing and leave `last` unchanged.
pub fn diff_edges(
    readings: &[(String, String)],
    last: &mut HashMap<String, bool>,
    now: DateTime<Utc>,
) -> Vec<EntityEdge> {
    let mut edges = Vec::new();
    for (eid, state) in readings {
        let Some(on) = edge_on(state) else { continue };
        match last.get(eid) {
            Some(&prev) if prev == on => {} // unchanged
            Some(_) => {
                last.insert(eid.clone(), on);
                edges.push(EntityEdge {
                    entity_id: eid.clone(),
                    on,
                    at: now,
                });
            }
            None => {
                last.insert(eid.clone(), on); // first observation: seed, no edge
            }
        }
    }
    edges
}

/// Transport-agnostic source of HA state edges. The Phase-2 impl polls REST; a
/// WebSocket impl (#53) will slot in with no caller change. `next_edges` MUST
/// return `Err` (not `Ok(empty)`) on a transport failure — see the module
/// invariant.
#[async_trait]
pub trait HaEventSource: Send {
    async fn next_edges(&mut self) -> Result<Vec<EntityEdge>>;
}

/// REST poll source: sleep the interval, read the linked entities' current
/// state, diff to edges. A failed read propagates as `Err` (the 5s client
/// timeout bounds a dead HA) so the caller's loop exits and fails open.
pub struct HaPollSource {
    client: HaClient,
    entity_ids: Vec<String>,
    last: HashMap<String, bool>,
    interval: Duration,
}

impl HaPollSource {
    pub fn new(client: HaClient, entity_ids: Vec<String>) -> Self {
        Self {
            client,
            entity_ids,
            last: HashMap::new(),
            interval: Duration::from_secs(1),
        }
    }
}

#[async_trait]
impl HaEventSource for HaPollSource {
    async fn next_edges(&mut self) -> Result<Vec<EntityEdge>> {
        tokio::time::sleep(self.interval).await;
        // One bounded request. A transport error propagates as `Err` on purpose:
        // the caller loop exits and the recorder fails open. NEVER retry here.
        let readings = self.client.get_states_for(&self.entity_ids).await?;
        Ok(diff_edges(&readings, &mut self.last, Utc::now()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ts() -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(1_700_000_000, 0).unwrap()
    }

    #[test]
    fn edge_on_mapping() {
        assert_eq!(edge_on("on"), Some(true));
        assert_eq!(edge_on("OPEN"), Some(true));
        assert_eq!(edge_on("detected"), Some(true));
        assert_eq!(edge_on("off"), Some(false));
        assert_eq!(edge_on("closed"), Some(false));
        assert_eq!(edge_on("clear"), Some(false));
        // Indeterminate states are None, NOT off.
        assert_eq!(edge_on("unavailable"), None);
        assert_eq!(edge_on("unknown"), None);
        assert_eq!(edge_on(""), None);
    }

    #[test]
    fn device_class_label_mapping() {
        assert_eq!(label_for_device_class(Some("door")), "door");
        assert_eq!(label_for_device_class(Some("opening")), "door");
        assert_eq!(label_for_device_class(Some("window")), "window");
        assert_eq!(label_for_device_class(Some("garage_door")), "garage");
        assert_eq!(label_for_device_class(Some("occupancy")), "occupancy");
        assert_eq!(label_for_device_class(Some("presence")), "occupancy");
        // Plain-motion classes collapse to the (dot-row-filtered) motion glyph.
        assert_eq!(label_for_device_class(Some("motion")), "motion");
        assert_eq!(label_for_device_class(Some("MOVING")), "motion");
        // Absent / unknown classes fall back to the generic sensor glyph.
        assert_eq!(label_for_device_class(None), "sensor");
        assert_eq!(label_for_device_class(Some("smoke")), "sensor");
        assert_eq!(label_for_device_class(Some("")), "sensor");
    }

    #[test]
    fn diff_seeds_silently_then_emits_on_change() {
        let t = ts();
        let mut last = HashMap::new();
        let door = "binary_sensor.door".to_owned();

        // First observation seeds without emitting (no spurious startup/reconnect edge).
        assert!(diff_edges(&[(door.clone(), "off".into())], &mut last, t).is_empty());

        // off -> on emits a rising edge.
        let e = diff_edges(&[(door.clone(), "on".into())], &mut last, t);
        assert_eq!(e.len(), 1);
        assert!(e[0].on);
        assert_eq!(e[0].entity_id, door);

        // on -> on emits nothing.
        assert!(diff_edges(&[(door.clone(), "on".into())], &mut last, t).is_empty());

        // on -> off emits a falling edge.
        let e = diff_edges(&[(door.clone(), "off".into())], &mut last, t);
        assert_eq!(e.len(), 1);
        assert!(!e[0].on);

        // unavailable emits nothing AND does not flip the stored state to off.
        assert!(diff_edges(&[(door.clone(), "unavailable".into())], &mut last, t).is_empty());
        assert_eq!(last.get(&door), Some(&false));
    }

    // ── mock-HA integration: the real reqwest client + poll source against a
    //    stand-in HA HTTP server. Validates the fail-open TRIGGER end to end —
    //    a poll failure must surface as `Err` (which exits the loop and arms the
    //    recorder's fail-open rail). This is the automated proxy for the
    //    real-hardware "kill HA → records everything" test; it needs no live HA.
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Stand-in HA: serves `GET /api/` and `GET /api/states` for one sensor whose
    /// state the test can flip, and can be switched to fail (HTTP 500) mid-run.
    struct MockHa {
        sensor_state: Mutex<String>,
        fail: AtomicBool,
    }

    /// Bind a stand-in HA on a loopback port and return its base URL.
    async fn spawn_mock_ha(mock: Arc<MockHa>) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let mock = Arc::clone(&mock);
                tokio::spawn(async move {
                    // Read the request head (until CRLF CRLF); a GET has no body.
                    let mut buf = Vec::new();
                    let mut tmp = [0u8; 1024];
                    loop {
                        match sock.read(&mut tmp).await {
                            Ok(0) => return,
                            Ok(n) => {
                                buf.extend_from_slice(&tmp[..n]);
                                if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                                    break;
                                }
                            }
                            Err(_) => return,
                        }
                    }
                    let req = String::from_utf8_lossy(&buf);
                    let path = req.split_whitespace().nth(1).unwrap_or("/");
                    let (status, body) = if mock.fail.load(Ordering::SeqCst) {
                        ("500 Internal Server Error", String::new())
                    } else if path == "/api/" {
                        ("200 OK", r#"{"message":"API running."}"#.to_owned())
                    } else if path == "/api/states" {
                        let st = mock.sensor_state.lock().unwrap().clone();
                        (
                            "200 OK",
                            format!(r#"[{{"entity_id":"binary_sensor.test","state":"{st}"}}]"#),
                        )
                    } else {
                        ("404 Not Found", String::new())
                    };
                    let resp = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = sock.write_all(resp.as_bytes()).await;
                    let _ = sock.shutdown().await;
                });
            }
        });
        base
    }

    fn settings_for(base: String) -> HaSettings {
        HaSettings {
            enabled: true,
            base_url: base,
            token: Some("test-token".to_owned()),
            version: 1,
        }
    }

    #[tokio::test]
    async fn mock_ha_healthy_reads_then_failure_returns_err() {
        let mock = Arc::new(MockHa {
            sensor_state: Mutex::new("off".to_owned()),
            fail: AtomicBool::new(false),
        });
        let base = spawn_mock_ha(Arc::clone(&mock)).await;
        let client = HaClient::from_settings(&settings_for(base)).expect("client builds");

        // Reachability + a real state read over real HTTP.
        client.test_connection().await.expect("test_connection ok");
        let entity = "binary_sensor.test".to_owned();
        let states = client
            .get_states_for(std::slice::from_ref(&entity))
            .await
            .expect("states");
        assert_eq!(states, vec![(entity.clone(), "off".to_owned())]);

        // Poll source: first poll seeds silently, then off->on emits a rising edge.
        let mut src = HaPollSource::new(client.clone(), vec![entity.clone()]);
        assert!(
            src.next_edges().await.expect("poll 1").is_empty(),
            "first observation seeds without a spurious edge"
        );
        *mock.sensor_state.lock().unwrap() = "on".to_owned();
        let edges = src.next_edges().await.expect("poll 2");
        assert_eq!(edges.len(), 1);
        assert!(edges[0].on);
        assert_eq!(edges[0].entity_id, entity);

        // THE fail-open trigger: HA starts failing → the poll returns Err. The
        // caller's loop exits on this, which is what makes the camera fail open.
        mock.fail.store(true, Ordering::SeqCst);
        let failed = src.next_edges().await;
        assert!(
            failed.is_err(),
            "a failed poll MUST return Err to arm fail-open, got {failed:?}"
        );
    }

    #[tokio::test]
    async fn mock_ha_unreachable_returns_err() {
        // A closed loopback port stands in for an unreachable HA.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let client = HaClient::from_settings(&settings_for(base)).expect("client builds");
        assert!(
            client.get_states().await.is_err(),
            "an unreachable HA must surface as Err (arms fail-open)"
        );
    }
}
