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

/// Does this `GET /api/` body actually look like Home Assistant?
///
/// Home Assistant answers `{"message": "API running."}`. Anything that is not a
/// JSON object with a non-empty `message` string (an HTML login page, a bare
/// "OK", an array) is some other web server, and reporting it as "Connected"
/// sends the operator off configuring entities against a router admin page.
/// Deliberately shape-based rather than exact-string, so an HA release that
/// reworded the text does not start failing a healthy install.
#[must_use]
pub fn looks_like_home_assistant(body: &str) -> bool {
    let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(body.trim())
    else {
        return false;
    };
    map.get("message")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|m| !m.trim().is_empty())
}

/// `host[:port]` of a base URL, with any `user:pass@` userinfo stripped, for
/// operator-facing messages. (The HA token is a header, never part of the URL,
/// so it can't reach here; userinfo is stripped anyway on principle.)
fn host_port(base_url: &str) -> String {
    let s = base_url.trim();
    let s = s.split_once("://").map_or(s, |(_, rest)| rest);
    let s = s.split(['/', '?', '#']).next().unwrap_or(s);
    s.rsplit_once('@').map_or(s, |(_, host)| host).to_owned()
}

/// Split `host[:port]` (IPv6-literal aware) into its host and optional port.
fn split_host_port(hp: &str) -> (String, Option<String>) {
    if let Some(rest) = hp.strip_prefix('[') {
        if let Some((h, tail)) = rest.split_once(']') {
            return (
                format!("[{h}]"),
                tail.strip_prefix(':')
                    .filter(|p| !p.is_empty())
                    .map(str::to_owned),
            );
        }
    }
    match hp.rsplit_once(':') {
        Some((h, p)) if !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()) => {
            (h.to_owned(), Some(p.to_owned()))
        }
        _ => (hp.to_owned(), None),
    }
}

/// Deepest source in an error chain, first line only — reqwest's own `Display`
/// repeats the URL the operator just typed; the root cause ("Connection
/// refused", "dns error", …) is the part worth showing.
fn deepest_line(e: &reqwest::Error) -> String {
    let mut src: &dyn std::error::Error = e;
    while let Some(next) = src.source() {
        src = next;
    }
    src.to_string()
        .lines()
        .next()
        .unwrap_or("request failed")
        .to_owned()
}

/// Turn a transport-level reqwest failure into a sentence an operator can act
/// on. Every one of "HA is switched off", "nothing is listening on that port",
/// "that hostname doesn't resolve" and "the base URL has no scheme" used to
/// surface as the same four words ("Home Assistant request failed").
fn transport_error(base_url: &str, e: &reqwest::Error) -> anyhow::Error {
    let hp = host_port(base_url);
    let (host, port) = split_host_port(&hp);
    let detail = deepest_line(e);
    let low = detail.to_ascii_lowercase();

    // A base URL with no (or a non-http) scheme, e.g. "host:8123", isn't a URL
    // reqwest can use at all: it fails while BUILDING the request, before any
    // socket is opened. Checked on the URL itself as well as the error kind, so
    // the message doesn't depend on which reqwest error variant that produces.
    let http_scheme = ["http://", "https://"].iter().any(|p| {
        base_url
            .trim()
            .get(..p.len())
            .is_some_and(|s| s.eq_ignore_ascii_case(p))
    });
    if !http_scheme || e.is_builder() {
        return anyhow::anyhow!(
            "'{}' is not a valid address. The Home Assistant address must start with \
             http:// or https:// (for example http://homeassistant.local:8123).",
            base_url.trim()
        );
    }
    if e.is_timeout() {
        return anyhow::anyhow!(
            "Home Assistant did not answer in time at {hp}. \
             Check that it is running and reachable from this server."
        );
    }
    if low.contains("dns error")
        || low.contains("failed to lookup address")
        || low.contains("name or service not known")
        || low.contains("nodename nor servname")
        || low.contains("no such host")
    {
        return anyhow::anyhow!(
            "Could not find a host called '{host}' on your network. \
             Check the spelling, or use the IP address instead."
        );
    }
    if low.contains("connection refused") || e.is_connect() {
        return match port {
            Some(p) => anyhow::anyhow!(
                "Nothing answered at {host}:{p}. Is Home Assistant running, and is that \
                 the right port? (Home Assistant is usually :8123.)"
            ),
            None => anyhow::anyhow!(
                "Nothing answered at {host}. Is Home Assistant running, and is that the \
                 right address? (Home Assistant is usually on port 8123.)"
            ),
        };
    }
    anyhow::anyhow!("Could not reach Home Assistant at {hp} ({detail}).")
}

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
            .map_err(|e| transport_error(&self.base_url, &e))
    }

    /// `GET /api/` — a cheap authenticated reachability check.
    ///
    /// A 2xx is necessary but NOT sufficient: any web server (a router login
    /// page, a NAS, a mistyped port that happens to answer) returns 200 for
    /// `GET /api/`, and treating that as success reported "Connected" for a
    /// base URL that is not Home Assistant at all. Home Assistant's `/api/`
    /// answers `{"message": "API running."}`, so the body shape is checked too
    /// (see [`looks_like_home_assistant`]).
    pub async fn test_connection(&self) -> Result<()> {
        let resp = self.get("/api/").await?;
        let code = resp.status();
        if code.as_u16() == 401 {
            anyhow::bail!("Home Assistant rejected the token (HTTP 401)")
        }
        if !code.is_success() {
            anyhow::bail!("Home Assistant returned HTTP {}", code.as_u16())
        }
        let body = resp.text().await.unwrap_or_default();
        if looks_like_home_assistant(&body) {
            Ok(())
        } else {
            anyhow::bail!(
                "Something answered at that address, but it is not Home Assistant. \
                 Check the host and port (Home Assistant is usually :8123)."
            )
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

    /// `POST /api/services/<domain>/<service>` with `{"entity_id": ...}` — the
    /// outbound control path (Phase 2, issue #187).
    ///
    /// # Security contract (do NOT weaken)
    ///
    /// `domain` and `service` must be caller-chosen CONSTANTS, never strings
    /// that came off the wire: this method builds a URL path from them. The API
    /// obtains both from a static per-domain allowlist keyed by the linked
    /// entity's own domain (`api/src/ha.rs::allowed_spec`), so a client can
    /// never reach an arbitrary HA service. `entity_id` is the stored link's
    /// entity, never a client-supplied one, and travels in the JSON body.
    ///
    /// The token is a header (as everywhere in this client), so the error
    /// strings below cannot leak it.
    ///
    /// # Errors
    ///
    /// Returns an error if HA is unreachable, rejects the token, or answers
    /// non-2xx. The message carries only the HTTP status, no upstream body.
    pub async fn call_service(&self, domain: &str, service: &str, entity_id: &str) -> Result<()> {
        self.call_service_with(domain, service, entity_id, &[])
            .await
    }

    /// `POST /api/services/<domain>/<service>` with `{"entity_id": ...}` plus the
    /// given `extra` service-data key/value pairs (e.g. `brightness_pct` for a
    /// value action). Same security contract as [`call_service`]: `domain`,
    /// `service`, and every `extra` KEY must be caller-chosen `&'static`
    /// constants from the API's allowlist spec, never strings off the wire; only
    /// the numeric VALUES originate from a validated request. `entity_id` is the
    /// stored link's entity and travels in the JSON body, never the URL.
    ///
    /// # Errors
    ///
    /// Returns an error if HA is unreachable, rejects the token, or answers
    /// non-2xx. The message carries only the HTTP status, no upstream body.
    pub async fn call_service_with(
        &self,
        domain: &str,
        service: &str,
        entity_id: &str,
        extra: &[(&str, serde_json::Value)],
    ) -> Result<()> {
        let mut body = serde_json::Map::new();
        body.insert("entity_id".to_owned(), serde_json::json!(entity_id));
        for (k, v) in extra {
            body.insert((*k).to_owned(), v.clone());
        }
        let resp = self
            .http
            .post(format!("{}/api/services/{domain}/{service}", self.base_url))
            .bearer_auth(&self.token)
            .json(&serde_json::Value::Object(body))
            .send()
            .await
            .context("Home Assistant service call failed")?;
        let code = resp.status();
        if code.is_success() {
            Ok(())
        } else if code.as_u16() == 401 {
            anyhow::bail!("Home Assistant rejected the token (HTTP 401)")
        } else {
            anyhow::bail!("Home Assistant returned HTTP {}", code.as_u16())
        }
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
    /// Also accepts `POST /api/services/<domain>/<service>` and records the
    /// request line so the control path's URL construction is assertable.
    struct MockHa {
        sensor_state: Mutex<String>,
        fail: AtomicBool,
        /// `("<method> <path>", "<body>")` for every service call received.
        service_calls: Mutex<Vec<(String, String)>>,
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
                    // A POST carries a body after the head; read exactly
                    // Content-Length more bytes so the assertion below sees it.
                    let head = String::from_utf8_lossy(&buf).to_string();
                    let head_end = head.find("\r\n\r\n").map_or(head.len(), |i| i + 4);
                    let want: usize = head
                        .lines()
                        .filter_map(|l| l.split_once(':'))
                        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
                        .and_then(|(_, v)| v.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    while buf.len() < head_end + want {
                        match sock.read(&mut tmp).await {
                            Ok(0) => break,
                            Ok(n) => buf.extend_from_slice(&tmp[..n]),
                            Err(_) => break,
                        }
                    }
                    let req = String::from_utf8_lossy(&buf).to_string();
                    let method = req.split_whitespace().next().unwrap_or("GET").to_owned();
                    let path_owned = req.split_whitespace().nth(1).unwrap_or("/").to_owned();
                    let path = path_owned.as_str();
                    let req_body = req.get(head_end..).unwrap_or("").to_owned();
                    let (status, body) = if mock.fail.load(Ordering::SeqCst) {
                        ("500 Internal Server Error", String::new())
                    } else if method == "POST" && path.starts_with("/api/services/") {
                        mock.service_calls
                            .lock()
                            .unwrap()
                            .push((format!("{method} {path}"), req_body));
                        ("200 OK", "[]".to_owned())
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
            service_calls: Mutex::new(Vec::new()),
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
    async fn call_service_posts_domain_service_and_entity_then_errors_on_failure() {
        let mock = Arc::new(MockHa {
            sensor_state: Mutex::new("off".to_owned()),
            fail: AtomicBool::new(false),
            service_calls: Mutex::new(Vec::new()),
        });
        let base = spawn_mock_ha(Arc::clone(&mock)).await;
        let client = HaClient::from_settings(&settings_for(base)).expect("client builds");

        client
            .call_service("cover", "close_cover", "cover.garage")
            .await
            .expect("service call ok");

        let calls = mock.service_calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "POST /api/services/cover/close_cover");
        // The entity travels in the BODY, never the URL.
        let body: serde_json::Value = serde_json::from_str(&calls[0].1).expect("json body");
        assert_eq!(body["entity_id"], "cover.garage");
        assert_eq!(
            body.as_object().map(|o| o.len()),
            Some(1),
            "body carries exactly entity_id, nothing else"
        );

        // A failing HA surfaces as Err (the handler maps this to a 502).
        mock.fail.store(true, Ordering::SeqCst);
        assert!(client
            .call_service("lock", "unlock", "lock.front")
            .await
            .is_err());
    }

    #[tokio::test]
    async fn call_service_with_puts_extra_params_in_the_body_not_the_url() {
        let mock = Arc::new(MockHa {
            sensor_state: Mutex::new("off".to_owned()),
            fail: AtomicBool::new(false),
            service_calls: Mutex::new(Vec::new()),
        });
        let base = spawn_mock_ha(Arc::clone(&mock)).await;
        let client = HaClient::from_settings(&settings_for(base)).expect("client builds");

        // A value action (set_brightness rides turn_on) carries its percent in the
        // service data, alongside the entity id, never in the URL path.
        client
            .call_service_with(
                "light",
                "turn_on",
                "light.kitchen",
                &[("brightness_pct", serde_json::json!(62))],
            )
            .await
            .expect("service call ok");

        let calls = mock.service_calls.lock().unwrap().clone();
        assert_eq!(calls.len(), 1);
        // The URL is built from the &'static domain/service only.
        assert_eq!(calls[0].0, "POST /api/services/light/turn_on");
        let body: serde_json::Value = serde_json::from_str(&calls[0].1).expect("json body");
        assert_eq!(body["entity_id"], "light.kitchen");
        // Sent as a JSON integer, and it is exactly entity_id + the one extra key.
        assert_eq!(body["brightness_pct"], 62);
        assert!(body["brightness_pct"].is_i64() || body["brightness_pct"].is_u64());
        assert_eq!(body.as_object().map(|o| o.len()), Some(2));
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

    // ── first-run error-message quality (issue #517) ─────────────────────────

    #[test]
    fn ha_shape_accepts_real_api_body_and_rejects_other_servers() {
        assert!(looks_like_home_assistant(r#"{"message": "API running."}"#));
        assert!(looks_like_home_assistant(
            "  {\"message\":\"API running.\"}\n"
        ));
        // Another HA wording would still pass — the check is shape-based.
        assert!(looks_like_home_assistant(
            r#"{"message":"API funktioniert."}"#
        ));
        // Anything that is not an object with a message is not Home Assistant.
        assert!(!looks_like_home_assistant(
            "<html><body>Login</body></html>"
        ));
        assert!(!looks_like_home_assistant("OK"));
        assert!(!looks_like_home_assistant("[]"));
        assert!(!looks_like_home_assistant(r#"{"status":"ok"}"#));
        assert!(!looks_like_home_assistant(r#"{"message":"  "}"#));
        assert!(!looks_like_home_assistant(""));
    }

    #[test]
    fn host_port_strips_scheme_userinfo_and_path() {
        assert_eq!(host_port("http://ha.example:8123/"), "ha.example:8123");
        assert_eq!(host_port("https://u:p@ha.example/api"), "ha.example");
        assert_eq!(
            split_host_port("ha.example:8123").1.as_deref(),
            Some("8123")
        );
        assert_eq!(split_host_port("ha.example").1, None);
        assert_eq!(
            split_host_port("[::1]:8123"),
            ("[::1]".to_owned(), Some("8123".to_owned()))
        );
    }

    /// A plain web server that is NOT Home Assistant must fail the test, not
    /// render as "Connected" (the console's green verdict).
    #[tokio::test]
    async fn test_connection_rejects_a_non_home_assistant_web_server() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let mut tmp = [0u8; 1024];
                let _ = sock.read(&mut tmp).await;
                let body = "<html><body>Router login</body></html>";
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = sock.write_all(resp.as_bytes()).await;
                let _ = sock.shutdown().await;
            }
        });
        let client = HaClient::from_settings(&settings_for(base)).expect("client builds");
        let err = client
            .test_connection()
            .await
            .expect_err("a 200 from a non-HA server must NOT report success");
        assert!(
            err.to_string().contains("not Home Assistant"),
            "unexpected message: {err}"
        );
    }

    #[tokio::test]
    async fn unreachable_port_names_the_host_and_port() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base = format!("http://{addr}");
        drop(listener);
        let client = HaClient::from_settings(&settings_for(base)).expect("client builds");
        let err = client.test_connection().await.expect_err("closed port");
        let msg = err.to_string();
        assert!(
            msg.contains(&addr.port().to_string()) && msg.contains("Nothing answered"),
            "unexpected message: {msg}"
        );
        assert!(!msg.contains("Home Assistant request failed"));
    }

    #[tokio::test]
    async fn base_url_without_a_scheme_says_so() {
        let client =
            HaClient::from_settings(&settings_for("ha.example:8123".to_owned())).expect("builds");
        let err = client.test_connection().await.expect_err("not a URL");
        assert!(
            err.to_string()
                .contains("must start with http:// or https://"),
            "unexpected message: {err}"
        );
    }
}
