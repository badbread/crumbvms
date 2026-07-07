// SPDX-License-Identifier: AGPL-3.0-or-later

//! Network camera-discovery endpoint for the admin console's **Scan network /
//! Find cameras** button.
//!
//! | Method | Path                       | Auth  | Returns                          |
//! |--------|----------------------------|-------|----------------------------------|
//! | `POST` | `/config/discover`         | Admin | JSON list of discovered cameras  |
//! | `POST` | `/config/discover/probe`   | Admin | Deep single-IP probe (see below) |
//! | `GET`  | `/config/camera-brands`    | Admin | Brand-picker dropdown entries    |
//!
//! # Request body
//!
//! ```json
//! { "range": "192.168.1.0/24", "username": "admin", "password": "secret" }
//! ```
//!
//! | Field        | Required | Default            | Notes                              |
//! |--------------|----------|--------------------|-------------------------------------|
//! | `range`      | yes      | —                  | CIDR / dash range / single IP       |
//! | `username`   | no       | none               | ONVIF username                      |
//! | `password`   | no       | none               | ONVIF password                      |
//! | `timeout_ms` | no       | [`PROBE_TIMEOUT`]  | per-host budget override, 500–8000  |
//!
//! `range` accepts three forms:
//!  * **CIDR**: `192.168.1.0/24`
//!  * **dash range**: `192.168.1.1-254` (last octet) or `192.168.1.1-192.168.1.254`
//!  * **single IP**: `192.168.1.50`
//!
//! `username` / `password` are optional ONVIF credentials. They are NOT required
//! to *detect* a camera (ONVIF mandates that `GetSystemDateAndTime` answer
//! without auth) — but they ARE required to auto-fill the real RTSP stream URL,
//! because `GetStreamUri` is an authenticated call.
//!
//! `timeout_ms` optionally stretches the per-host probe/detail budget beyond the
//! default [`PROBE_TIMEOUT`] (clamped to [`MIN_TIMEOUT_MS`]..=[`MAX_TIMEOUT_MS`]).
//! The admin UI passes this when re-scanning a single known IP whose camera is a
//! slow ONVIF responder (Reolink's near-single-threaded ONVIF server is the
//! canonical case) — the default budget is tuned for a fast `/24` sweep and can
//! make a busy Reolink miss the window and silently vanish from results. This
//! does NOT change [`SCAN_TOTAL_TIMEOUT`] or [`SCAN_CONCURRENCY`]; a single-IP
//! re-scan only ever spawns one task, so the wall-clock cap is a non-issue.
//!
//! # Why unicast (not WS-Discovery multicast)
//!
//! The API runs in a *bridged* Docker container. Multicast WS-Discovery
//! (239.255.255.250:3702) does not cross the bridge to the camera LAN, so it is
//! useless here. Instead we do a **unicast** scan: for every IP in the requested
//! range we open ordinary TCP/HTTP connections, which route fine off the bridge.
//!
//! # Scan strategy (per IP, all under tight timeouts)
//!
//! 1. **ONVIF probe** — POST an unauthenticated `GetSystemDateAndTime` SOAP
//!    envelope to `http://<ip>:<port>/onvif/device_service` for a few common
//!    ports. A well-formed SOAP response ⇒ it is an ONVIF device; the working
//!    service URL is recorded.
//! 2. **Authenticated detail** (only when creds were supplied *and* ONVIF was
//!    found) — via the `onvif` crate (same as `ptz.rs`): `GetDeviceInformation`
//!    (manufacturer/model/firmware) then `GetProfiles` + `GetStreamUri` for the
//!    REAL main + sub RTSP URLs.
//! 3. **RTSP fallback** — TCP-connect port 554 and send an `OPTIONS` request; a
//!    well-formed RTSP reply marks the host as a probable camera even when it is
//!    not ONVIF, and yields a best-effort `rtsp://<ip>:554/` candidate (empty
//!    path — the operator fills it in).
//! 4. **Port hint** — note which of {80, 554, 8000, 8080} accept a TCP connect.
//!
//! IPs that show no camera signal at all are skipped. Concurrency is bounded and
//! the whole scan is wrapped in a hard wall-clock cap.
//!
//! # `POST /config/discover/probe` — brand-aware single-IP deep probe
//!
//! Some cameras (Reolink in particular) either answer ONVIF too slowly for the
//! range scan's tight per-host budget, or answer ONVIF fine but return an
//! empty/placeholder `GetStreamUri` — so the range scan hands back a bare
//! `rtsp://ip:554/` the operator has to complete by hand. This endpoint is the
//! admin UI's "try harder on just this one IP" action:
//!
//! ```json
//! { "ip": "192.168.1.50", "username": "admin", "password": "secret", "brand": "reolink" }
//! ```
//!
//! It tries, in order: (a) single-IP ONVIF discovery with a generous budget
//! (reuses [`probe_host`]); (b) if that doesn't yield a usable main stream URL,
//! brand-aware RTSP path candidates from [`BRAND_TABLE`] (or, with `brand`
//! omitted/`"auto"`, a prevalence-ordered superset of every brand — see
//! [`auto_candidates`]), each validated with the SAME `ffprobe` helper
//! ([`crate::ffprobe::probe_video`]) the `/config/test-stream` button uses,
//! stopping at the first candidate that reports a real video stream. The whole
//! request is capped at [`PROBE_ENDPOINT_TIMEOUT`] regardless of how many
//! candidates remain. `GET /config/camera-brands` returns the brand list (key +
//! label) for the UI's dropdown.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use axum::{
    routing::{get, post},
    Json, Router,
};
use ipnet::Ipv4Net;
use onvif::soap::client::{AuthType, ClientBuilder, Credentials};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;
use url::Url;

use crate::{auth_mw::AdminUser, error::ApiError, ffprobe};

// ─── tuning constants ──────────────────────────────────────────────────────────

/// Hard cap on the number of hosts a single scan may probe. Rejects abusively
/// large ranges (e.g. a `/16` = 65k hosts) before any network I/O. A `/22`
/// (1024 hosts) is the largest sensible camera subnet.
const MAX_HOSTS: usize = 1024;

/// Max IPs probed simultaneously. Bounds socket/fd pressure so a `/24` finishes
/// in a few seconds without opening 254 sockets at once.
const SCAN_CONCURRENCY: usize = 64;

/// Per-IP TCP connect timeout (port-open check + RTSP/ONVIF dial).
const CONNECT_TIMEOUT: Duration = Duration::from_millis(1200);

/// Per-IP overall probe budget (ONVIF SOAP round-trip + RTSP). Kept short so a
/// dead IP never stalls the scan; a `/24` of dead IPs finishes in
/// ~ceil(254/64) * this. Overridable per-request via `timeout_ms` (clamped to
/// [`MIN_TIMEOUT_MS`]..=[`MAX_TIMEOUT_MS`]) for single-IP re-scans of
/// known-slow cameras.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Lower bound for a request-supplied `timeout_ms` override. Below this the
/// probe couldn't complete even a single ONVIF round-trip on a healthy LAN.
const MIN_TIMEOUT_MS: u64 = 500;

/// Upper bound for a request-supplied `timeout_ms` override. High enough to
/// give a busy Reolink room to answer; low enough that a single stuck host
/// can't stall an operator-facing re-scan for an unreasonable time.
const MAX_TIMEOUT_MS: u64 = 8000;

/// Whole-scan wall-clock cap. A pathological range (max hosts, all silently
/// dropping packets) can't tie the handler up longer than this.
const SCAN_TOTAL_TIMEOUT: Duration = Duration::from_mins(1);

/// Common ONVIF device-service HTTP ports, tried in order until one answers.
const ONVIF_PORTS: &[u16] = &[80, 8000, 8080, 8899, 2020];

/// Ports whose open/closed state is reported back as a "looks like a camera" hint.
const HINT_PORTS: &[u16] = &[80, 554, 8000, 8080];

/// Standard RTSP port (probed for the non-ONVIF fallback).
const RTSP_PORT: u16 = 554;

/// Default RTSP port used to render a brand's candidate path templates when the
/// caller doesn't supply one (see [`ProbeRequest::port`]).
const DEFAULT_RTSP_PORT: u16 = 554;

/// Per-candidate ffprobe budget for `POST /config/discover/probe`'s brand-path
/// fallback. Short enough that a handful of dead candidates don't eat the
/// [`PROBE_ENDPOINT_TIMEOUT`] wall-clock cap, long enough for a real camera to
/// answer an RTSP `DESCRIBE`/first-frame handshake.
const CANDIDATE_PROBE_TIMEOUT: Duration = Duration::from_secs(7);

/// Hard cap on how many brand-path candidates `POST /config/discover/probe`
/// will try before giving up — bounds worst-case work for a single request
/// regardless of how large the "auto" superset grows.
const MAX_CANDIDATES: usize = 8;

/// Whole-request wall-clock cap for `POST /config/discover/probe`, covering
/// the single-IP ONVIF attempt plus every candidate probe. A single
/// unreachable IP can't hang the handler past this even if every candidate
/// times out individually.
const PROBE_ENDPOINT_TIMEOUT: Duration = Duration::from_secs(30);

// ─── brand-aware RTSP path hints ────────────────────────────────────────────────

/// One brand's ordered candidate RTSP path templates. `{main}`/`{sub}` are
/// placeholders replaced by [`render_candidate`] — kept as a marker in the
/// template purely for documentation/matching purposes (the templates below
/// hard-code the actual path per stream, since brands don't share a single
/// `{main}`/`{sub}` substitution point in the same way `rtsp_main`/`rtsp_sub`
/// do in [`DiscoveredCamera`]).
///
/// Ordered by how likely each is to be the RIGHT path for that brand — the
/// first one that ffprobes successfully wins, so cheaper/likelier guesses go
/// first.
struct BrandPaths {
    /// Machine key, e.g. `"reolink"` — matches [`ProbeRequest::brand`] and the
    /// key returned by `GET /config/camera-brands`.
    key: &'static str,
    /// Human label for the UI dropdown.
    label: &'static str,
    /// Ordered `(main_path, sub_path)` candidates. `sub_path` is `None` when a
    /// brand's template has no distinct sub-stream path (e.g. Axis).
    paths: &'static [(&'static str, Option<&'static str>)],
}

/// Brand → ordered RTSP path candidates, keyed by [`BrandPaths::key`].
///
/// Camera firmware rarely advertises a spec-compliant ONVIF media profile with
/// a working `GetStreamUri` (Reolink in particular). When ONVIF detail fails
/// or returns an empty/placeholder URL, these hard-coded per-brand path
/// conventions are the industry's de-facto standard and let discovery still
/// hand back a WORKING stream URL instead of a bare `rtsp://ip:554/`.
const BRAND_TABLE: &[BrandPaths] = &[
    BrandPaths {
        key: "reolink",
        label: "Reolink",
        paths: &[
            ("/h264Preview_01_main", Some("/h264Preview_01_sub")),
            ("/h265Preview_01_main", Some("/h265Preview_01_sub")),
            // E-series (Reolink Argus/E1 etc.) uses a shorter path without the
            // codec prefix.
            ("/Preview_01_main", Some("/Preview_01_sub")),
        ],
    },
    BrandPaths {
        key: "hikvision",
        label: "Hikvision",
        paths: &[("/Streaming/Channels/101", Some("/Streaming/Channels/102"))],
    },
    BrandPaths {
        key: "dahua",
        label: "Dahua",
        paths: &[(
            "/cam/realmonitor?channel=1&subtype=0",
            Some("/cam/realmonitor?channel=1&subtype=1"),
        )],
    },
    BrandPaths {
        key: "amcrest",
        label: "Amcrest",
        // Amcrest is Dahua-OEM firmware; same path convention.
        paths: &[(
            "/cam/realmonitor?channel=1&subtype=0",
            Some("/cam/realmonitor?channel=1&subtype=1"),
        )],
    },
    BrandPaths {
        key: "uniview",
        label: "Uniview",
        paths: &[("/media/video1", Some("/media/video2"))],
    },
    BrandPaths {
        key: "axis",
        label: "Axis",
        paths: &[("/axis-media/media.amp", None)],
    },
    BrandPaths {
        key: "tplink",
        label: "TP-Link / Tapo",
        paths: &[("/stream1", Some("/stream2"))],
    },
    BrandPaths {
        key: "generic",
        label: "Generic / ONVIF only",
        // No brand-specific guesses — rely entirely on ONVIF `GetStreamUri`.
        paths: &[],
    },
];

/// Look up a brand's candidate paths by key (case-insensitive). Unknown keys
/// (including `None`) return an empty slice — callers fall back to the "auto"
/// superset via [`auto_candidates`].
fn brand_paths(brand: Option<&str>) -> &'static [(&'static str, Option<&'static str>)] {
    let Some(brand) = brand else { return &[] };
    BRAND_TABLE
        .iter()
        .find(|b| b.key.eq_ignore_ascii_case(brand))
        .map_or(&[], |b| b.paths)
}

/// "Auto" superset used when the caller omits `brand` (or passes `"auto"`):
/// every brand's candidates concatenated in prevalence order (Reolink and
/// Hikvision/Dahua-family cameras dominate the consumer/prosumer market this
/// scanner targets), deduplicated by path pair, capped at [`MAX_CANDIDATES`]
/// by the caller.
fn auto_candidates() -> Vec<(&'static str, Option<&'static str>)> {
    let order = [
        "reolink",
        "hikvision",
        "dahua",
        "uniview",
        "tplink",
        "axis",
        "amcrest",
    ];
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for key in order {
        for &pair in brand_paths(Some(key)) {
            if seen.insert(pair) {
                out.push(pair);
            }
        }
    }
    out
}

/// Render one path template into a full RTSP URL, embedding credentials (when
/// supplied) via [`inject_rtsp_credentials`] and using `port` (defaulting to
/// [`DEFAULT_RTSP_PORT`]).
fn render_candidate(ip: &str, port: u16, path: &str, user: &str, password: &str) -> String {
    let bare = format!("rtsp://{ip}:{port}{path}");
    if user.is_empty() {
        bare
    } else {
        inject_rtsp_credentials(&bare, user, password)
    }
}

// ─── DTOs ──────────────────────────────────────────────────────────────────────

/// `POST /config/discover` request body.
#[derive(Debug, Deserialize)]
pub struct DiscoverRequest {
    /// IP range: CIDR (`192.168.1.0/24`), dash range (`192.168.1.1-254`), or a
    /// single IP (`192.168.1.50`).
    pub range: String,
    /// Optional ONVIF username — needed to auto-fill the stream URL.
    #[serde(default)]
    pub username: Option<String>,
    /// Optional ONVIF password.
    #[serde(default)]
    pub password: Option<String>,
    /// Optional per-host probe/detail budget override, in milliseconds.
    /// Clamped to [`MIN_TIMEOUT_MS`]..=[`MAX_TIMEOUT_MS`] before use; absent
    /// or `None` keeps the [`PROBE_TIMEOUT`] default. The admin UI sets this
    /// when re-scanning a single known IP whose camera is a slow ONVIF
    /// responder (e.g. Reolink) that the default budget would miss.
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

/// One discovered camera (or camera-like host).
#[derive(Debug, Serialize, Default)]
pub struct DiscoveredCamera {
    /// Dotted-quad IP address.
    pub ip: String,
    /// Whether the host answered an unauthenticated ONVIF probe.
    pub is_onvif: bool,
    /// The ONVIF device-service URL that answered (e.g.
    /// `http://192.168.1.5/onvif/device_service`), when `is_onvif`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub onvif_service_url: Option<String>,
    /// Manufacturer (from authenticated `GetDeviceInformation`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manufacturer: Option<String>,
    /// Model.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Firmware version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub firmware: Option<String>,
    /// Real main-stream RTSP URL (from `GetStreamUri`), when creds yielded it.
    /// For the non-ONVIF RTSP fallback this is a best-effort `rtsp://<ip>:554/`
    /// candidate the operator must complete.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtsp_main: Option<String>,
    /// Real sub-stream RTSP URL, when the camera exposed a 2nd profile.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtsp_sub: Option<String>,
    /// Open ports among [`HINT_PORTS`] (a "looks like a camera" hint).
    pub open_ports: Vec<u16>,
    /// Short human-readable status, e.g. "ONVIF — credentials needed for stream URL".
    pub note: String,
}

/// `POST /config/discover` response.
#[derive(Debug, Serialize)]
pub struct DiscoverResponse {
    /// Discovered cameras, sorted by IP.
    pub cameras: Vec<DiscoveredCamera>,
    /// Number of hosts actually probed.
    pub scanned: usize,
    /// True if the scan hit its wall-clock cap before finishing every host.
    pub truncated: bool,
}

/// `GET /config/camera-brands` entry — one row of the brand-picker dropdown.
#[derive(Debug, Serialize)]
pub struct CameraBrandDto {
    /// Machine key — pass back as `brand` in [`ProbeRequest`].
    pub key: &'static str,
    /// Human label for display.
    pub label: &'static str,
}

/// `POST /config/discover/probe` request body.
#[derive(Debug, Deserialize)]
pub struct ProbeRequest {
    /// Single target IP (dotted-quad).
    pub ip: String,
    /// Optional ONVIF/RTSP username.
    #[serde(default)]
    pub username: Option<String>,
    /// Optional ONVIF/RTSP password.
    #[serde(default)]
    pub password: Option<String>,
    /// Brand key from `GET /config/camera-brands` (e.g. `"reolink"`). Omitted
    /// or `"auto"` tries a prevalence-ordered superset of all known brands'
    /// candidate paths (see [`auto_candidates`]).
    #[serde(default)]
    pub brand: Option<String>,
    /// RTSP port to use when rendering brand-path candidates. Defaults to
    /// [`DEFAULT_RTSP_PORT`] (554).
    #[serde(default)]
    pub port: Option<u16>,
}

/// One candidate URL tried by `POST /config/discover/probe`, in order.
#[derive(Debug, Serialize)]
pub struct TriedCandidate {
    /// The candidate RTSP URL (credentials embedded, if any — never logged,
    /// but it IS returned here since the caller already supplied them).
    pub url: String,
    /// Whether ffprobe found a usable video stream at this URL.
    pub ok: bool,
    /// ffprobe's failure message, when `ok` is false.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// `POST /config/discover/probe` response.
#[derive(Debug, Serialize, Default)]
pub struct ProbeResponse {
    /// True as soon as ANY candidate (ONVIF or brand-path) yields a working
    /// video stream.
    pub ok: bool,
    /// Whether the host answered ONVIF (independent of `ok` — a camera can be
    /// ONVIF-discoverable but still need a brand-path fallback for the stream
    /// URL, e.g. an ONVIF profile with an empty/placeholder `GetStreamUri`).
    pub is_onvif: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manufacturer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The working main-stream RTSP URL, when found.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtsp_main: Option<String>,
    /// The working sub-stream RTSP URL, when found (only ever set alongside a
    /// successful `rtsp_main` — sub is never probed/returned on its own).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rtsp_sub: Option<String>,
    /// Every candidate tried, in order, with its outcome — lets the UI show
    /// "tried these, none worked" instead of a bare failure.
    pub tried: Vec<TriedCandidate>,
    /// Short human-readable summary.
    pub note: String,
}

// ─── route registration ─────────────────────────────────────────────────────────

/// Mount the discovery routes. Caller merges this under `/config`.
pub fn routes() -> Router<crate::state::AppState> {
    Router::new()
        .route("/discover", post(discover))
        .route("/discover/probe", post(discover_probe))
        .route("/camera-brands", get(camera_brands))
}

// ─── handler ─────────────────────────────────────────────────────────────────────

/// `POST /config/discover` — unicast-scan an IP range for cameras.
async fn discover(
    _admin: AdminUser,
    Json(req): Json<DiscoverRequest>,
) -> Result<Json<DiscoverResponse>, ApiError> {
    let ips = parse_range(req.range.trim())?;
    if ips.is_empty() {
        return Err(ApiError::BadRequest(
            "the range resolved to zero usable host addresses".to_owned(),
        ));
    }
    if ips.len() > MAX_HOSTS {
        return Err(ApiError::BadRequest(format!(
            "range covers {} hosts; the maximum per scan is {MAX_HOSTS} \
             (use a smaller range, e.g. a /22 or narrower)",
            ips.len()
        )));
    }

    let creds = match (
        req.username
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
        req.password.as_deref(),
    ) {
        (Some(u), p) => Some(Credentials {
            username: u.to_owned(),
            // Password may legitimately be empty; only the username gates auth.
            password: p.unwrap_or_default().to_owned(),
        }),
        _ => None,
    };

    let scanned = ips.len();
    let creds = Arc::new(creds);

    // Per-host budget: default unless the caller stretched it for a known-slow
    // camera (see `timeout_ms` doc on `DiscoverRequest`). Concurrency and the
    // overall wall-clock cap are untouched.
    let probe_timeout = resolve_probe_timeout(req.timeout_ms);

    // Bounded-concurrency fan-out: one task per IP, but a shared semaphore caps
    // how many run at once (matches the JoinSet pattern used in status.rs). The
    // whole collection is wrapped in a wall-clock cap; on timeout we keep what
    // finished and flag the result truncated.
    let sem = Arc::new(Semaphore::new(SCAN_CONCURRENCY));
    let mut set: JoinSet<Option<DiscoveredCamera>> = JoinSet::new();
    for ip in ips {
        let sem = sem.clone();
        let creds = creds.clone();
        set.spawn(async move {
            // A closed semaphore is impossible here (never closed), so unwrap is safe.
            let _permit = sem.acquire_owned().await.ok()?;
            probe_host(ip, (*creds).as_ref(), probe_timeout).await
        });
    }

    let collected = tokio::time::timeout(SCAN_TOTAL_TIMEOUT, async {
        let mut out = Vec::new();
        while let Some(joined) = set.join_next().await {
            if let Ok(Some(cam)) = joined {
                out.push(cam);
            }
        }
        out
    })
    .await;

    // On timeout, keep whatever finished, flag the result truncated, and abort
    // the still-running probes so we don't leak tasks past the cap.
    let truncated = collected.is_err();
    let mut cameras = collected.unwrap_or_else(|_| {
        set.abort_all();
        tracing::warn!(
            hosts = scanned,
            "camera discovery scan hit the {}s wall-clock cap; results may be partial",
            SCAN_TOTAL_TIMEOUT.as_secs()
        );
        Vec::new()
    });

    // Stable, human-friendly ordering by numeric IP.
    cameras.sort_by_key(|c| c.ip.parse::<Ipv4Addr>().map_or(0, u32::from));

    tracing::info!(
        scanned,
        found = cameras.len(),
        with_creds = creds.is_some(),
        truncated,
        "camera discovery scan complete"
    );

    Ok(Json(DiscoverResponse {
        cameras,
        scanned,
        truncated,
    }))
}

/// `GET /config/camera-brands` — static brand list for the discovery UI's
/// brand-picker dropdown (used both to label results and to drive
/// `POST /config/discover/probe`'s `brand` field).
async fn camera_brands(_admin: AdminUser) -> Json<Vec<CameraBrandDto>> {
    Json(
        BRAND_TABLE
            .iter()
            .map(|b| CameraBrandDto {
                key: b.key,
                label: b.label,
            })
            .collect(),
    )
}

/// `POST /config/discover/probe` — deep single-IP probe for the "rescan this
/// camera" flow.
///
/// Tries, in order:
/// 1. Single-IP ONVIF discovery (same code path as the range scan) — if it
///    yields a usable main stream URL, that's the answer.
/// 2. Otherwise, brand-aware RTSP path candidates (see [`BRAND_TABLE`]),
///    validated with the same `ffprobe` the stream-test endpoints use,
///    stopping at the first candidate that reports a real video stream.
///
/// The whole request is capped at [`PROBE_ENDPOINT_TIMEOUT`] regardless of how
/// many candidates remain, so a single bad IP can't hang the handler.
async fn discover_probe(
    _admin: AdminUser,
    Json(req): Json<ProbeRequest>,
) -> Result<Json<ProbeResponse>, ApiError> {
    let ip: Ipv4Addr =
        req.ip.trim().parse().map_err(|_| {
            ApiError::BadRequest(format!("'{}' is not a valid IPv4 address", req.ip))
        })?;

    let user = req
        .username
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or_default()
        .to_owned();
    let password = req.password.unwrap_or_default();

    let creds = if user.is_empty() {
        None
    } else {
        Some(Credentials {
            username: user.clone(),
            password: password.clone(),
        })
    };

    let port = req.port.unwrap_or(DEFAULT_RTSP_PORT);

    let result = tokio::time::timeout(
        PROBE_ENDPOINT_TIMEOUT,
        probe_single_ip(
            ip,
            creds.as_ref(),
            req.brand.as_deref(),
            port,
            &user,
            &password,
        ),
    )
    .await
    .unwrap_or_else(|_| ProbeResponse {
        note: format!(
            "Probe timed out after {}s without finding a working stream.",
            PROBE_ENDPOINT_TIMEOUT.as_secs()
        ),
        ..Default::default()
    });

    Ok(Json(result))
}

/// Core logic for [`discover_probe`], split out so the outer handler can wrap
/// it in the wall-clock [`PROBE_ENDPOINT_TIMEOUT`] cap.
async fn probe_single_ip(
    ip: Ipv4Addr,
    creds: Option<&Credentials>,
    brand: Option<&str>,
    port: u16,
    user: &str,
    password: &str,
) -> ProbeResponse {
    // ── (a) single-IP ONVIF discovery, reusing the range-scan's per-host probe ──
    // Give it the same generous budget as a single-IP re-scan (MAX_TIMEOUT_MS)
    // since this endpoint exists specifically for slow-ONVIF-responder cameras.
    if let Some(cam) = probe_host(ip, creds, Duration::from_millis(MAX_TIMEOUT_MS)).await {
        if cam.is_onvif && cam.rtsp_main.is_some() {
            return ProbeResponse {
                ok: true,
                is_onvif: true,
                manufacturer: cam.manufacturer,
                model: cam.model,
                rtsp_main: cam.rtsp_main,
                rtsp_sub: cam.rtsp_sub,
                tried: Vec::new(),
                note: "ONVIF — stream URL auto-filled".to_owned(),
            };
        }
        // ONVIF answered but didn't yield a usable stream URL (or no creds were
        // supplied to authenticate GetStreamUri) — fall through to brand paths,
        // but keep the identity info we already learned.
        let brand_result = try_brand_paths(ip, port, brand, user, password).await;
        return ProbeResponse {
            is_onvif: cam.is_onvif,
            manufacturer: cam.manufacturer.or(brand_result.manufacturer),
            model: cam.model.or(brand_result.model),
            ..brand_result
        };
    }

    // ── (b) not ONVIF (or ONVIF probe itself failed) — brand-path fallback ──
    try_brand_paths(ip, port, brand, user, password).await
}

/// Try brand-path RTSP candidates in order, ffprobe-validating each, stopping
/// at the first one that reports a real video stream. Bounded to
/// [`MAX_CANDIDATES`] total attempts.
async fn try_brand_paths(
    ip: Ipv4Addr,
    port: u16,
    brand: Option<&str>,
    user: &str,
    password: &str,
) -> ProbeResponse {
    let is_auto = brand.is_none_or(|b| b.eq_ignore_ascii_case("auto"));
    let candidates: Vec<(&'static str, Option<&'static str>)> = if is_auto {
        auto_candidates()
    } else {
        brand_paths(brand).to_vec()
    };

    if candidates.is_empty() {
        return ProbeResponse {
            note: if brand.is_some() {
                "No path hints for this brand — rely on ONVIF or enter the path manually."
                    .to_owned()
            } else {
                "ONVIF did not yield a stream URL, and no brand was given to guess a path."
                    .to_owned()
            },
            ..Default::default()
        };
    }

    let ip_str = ip.to_string();
    let mut tried = Vec::new();

    for (main_path, sub_path) in candidates.into_iter().take(MAX_CANDIDATES) {
        let main_url = render_candidate(&ip_str, port, main_path, user, password);
        match ffprobe::probe_video(&main_url, CANDIDATE_PROBE_TIMEOUT).await {
            Ok(_stats) => {
                let sub_url = sub_path.map(|p| render_candidate(&ip_str, port, p, user, password));
                tried.push(TriedCandidate {
                    url: main_url.clone(),
                    ok: true,
                    error: None,
                });
                return ProbeResponse {
                    ok: true,
                    rtsp_main: Some(main_url),
                    rtsp_sub: sub_url,
                    tried,
                    note: "Brand-path guess confirmed by stream probe".to_owned(),
                    ..Default::default()
                };
            }
            Err(e) => {
                tried.push(TriedCandidate {
                    url: main_url,
                    ok: false,
                    error: Some(e),
                });
            }
        }
    }

    ProbeResponse {
        tried,
        note: "No brand-path candidate produced a working stream — enter the path manually."
            .to_owned(),
        ..Default::default()
    }
}

/// Resolve the effective per-host probe budget from an optional request-supplied
/// `timeout_ms`, clamping to [`MIN_TIMEOUT_MS`]..=[`MAX_TIMEOUT_MS`]. Absent ⇒
/// [`PROBE_TIMEOUT`] (the existing default, unchanged behaviour).
fn resolve_probe_timeout(timeout_ms: Option<u64>) -> Duration {
    match timeout_ms {
        Some(ms) => Duration::from_millis(ms.clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)),
        None => PROBE_TIMEOUT,
    }
}

// ─── range parsing ───────────────────────────────────────────────────────────────

/// Parse the `range` string into a concrete list of IPv4 host addresses.
///
/// Accepts CIDR, last-octet dash range, full dash range, and a single IP. For a
/// CIDR the network + broadcast addresses are excluded (they are never cameras),
/// except for a `/32` which yields the single host.
fn parse_range(input: &str) -> Result<Vec<Ipv4Addr>, ApiError> {
    if input.is_empty() {
        return Err(ApiError::BadRequest("range must not be empty".to_owned()));
    }

    // ── single IP ──
    if let Ok(ip) = input.parse::<Ipv4Addr>() {
        return Ok(vec![ip]);
    }

    // ── CIDR ──
    if input.contains('/') {
        let net: Ipv4Net = input.parse().map_err(|_| {
            ApiError::BadRequest(format!(
                "'{input}' is not a valid CIDR (e.g. 192.168.1.0/24)"
            ))
        })?;
        // Reject an oversize prefix BEFORE materializing the host list (a /16
        // would otherwise allocate 65k addresses just to be rejected). prefix
        // <22 ⇒ >1022 usable hosts > MAX_HOSTS.
        if net.prefix_len() < 22 {
            return Err(ApiError::BadRequest(format!(
                "CIDR /{} covers more than {MAX_HOSTS} hosts; use /22 or narrower",
                net.prefix_len()
            )));
        }
        let hosts: Vec<Ipv4Addr> = net.hosts().collect();
        // `Ipv4Net::hosts()` already omits network/broadcast for prefixes < 31,
        // and returns both addresses for /31 and the single addr for /32.
        return Ok(hosts);
    }

    // ── dash range ──
    if let Some((lo_str, hi_str)) = input.split_once('-') {
        let lo_str = lo_str.trim();
        let hi_str = hi_str.trim();
        let lo: Ipv4Addr = lo_str
            .parse()
            .map_err(|_| ApiError::BadRequest(format!("'{lo_str}' is not a valid IPv4 address")))?;

        // The high side is either a full IP (`192.168.1.254`) or a bare last octet
        // (`254`), in which case it inherits the low IP's first three octets.
        let hi: Ipv4Addr = if let Ok(full) = hi_str.parse::<Ipv4Addr>() {
            full
        } else if let Ok(last) = hi_str.parse::<u8>() {
            let o = lo.octets();
            Ipv4Addr::new(o[0], o[1], o[2], last)
        } else {
            return Err(ApiError::BadRequest(format!(
                "'{hi_str}' is not a valid range end (use 254 or 192.168.1.254)"
            )));
        };

        let lo_u = u32::from(lo);
        let hi_u = u32::from(hi);
        if hi_u < lo_u {
            return Err(ApiError::BadRequest(
                "range end is lower than range start".to_owned(),
            ));
        }
        // Guard the size here too so a huge dash range fails before allocating.
        if (hi_u - lo_u) as usize >= MAX_HOSTS {
            return Err(ApiError::BadRequest(format!(
                "dash range covers {} hosts; the maximum per scan is {MAX_HOSTS}",
                hi_u - lo_u + 1
            )));
        }
        return Ok((lo_u..=hi_u).map(Ipv4Addr::from).collect());
    }

    Err(ApiError::BadRequest(format!(
        "'{input}' is not a valid range — use CIDR (192.168.1.0/24), \
         a dash range (192.168.1.1-254), or a single IP"
    )))
}

// ─── per-host probe ──────────────────────────────────────────────────────────────

/// Probe a single host. Returns `Some` when the host shows *any* camera signal
/// (ONVIF or RTSP or an open camera-ish port), else `None`. `budget` is the
/// effective per-host timeout — [`PROBE_TIMEOUT`] by default, or the clamped
/// request-supplied `timeout_ms` override (see [`resolve_probe_timeout`]).
async fn probe_host(
    ip: Ipv4Addr,
    creds: Option<&Credentials>,
    budget: Duration,
) -> Option<DiscoveredCamera> {
    // Wrap the whole per-host probe so one slow IP can't exceed its budget.
    tokio::time::timeout(budget, probe_host_inner(ip, creds, budget))
        .await
        .ok()
        .flatten()
}

async fn probe_host_inner(
    ip: Ipv4Addr,
    creds: Option<&Credentials>,
    budget: Duration,
) -> Option<DiscoveredCamera> {
    let mut cam = DiscoveredCamera {
        ip: ip.to_string(),
        ..Default::default()
    };

    // ── port hints (cheap; informs the heuristic) ──
    for &p in HINT_PORTS {
        if tcp_open(ip, p).await {
            cam.open_ports.push(p);
        }
    }

    // ── ONVIF probe on the common device-service ports ──
    let mut onvif_url: Option<String> = None;
    for &port in ONVIF_PORTS {
        // Skip a port we already know is closed (80/8000/8080 covered by hints).
        if HINT_PORTS.contains(&port) && !cam.open_ports.contains(&port) {
            continue;
        }
        let url = format!("http://{ip}:{port}/onvif/device_service");
        if onvif_responds(&url, budget).await {
            onvif_url = Some(url);
            break;
        }
    }

    if let Some(url) = onvif_url {
        cam.is_onvif = true;
        cam.onvif_service_url = Some(url.clone());

        // ── authenticated detail (only with creds) ──
        if let Some(creds) = creds {
            match onvif_details(&url, creds).await {
                Ok(detail) => {
                    cam.manufacturer = detail.manufacturer;
                    cam.model = detail.model;
                    cam.firmware = detail.firmware;
                    // Embed the working credentials into the returned RTSP URLs.
                    // GetStreamUri never includes them — the SOAP layer authed
                    // the ONVIF call, but the RTSP URL itself still needs
                    // user:pass@ for ffprobe (test-stream/test-frame), go2rtc,
                    // and the recorder. Without this, discovery reported
                    // "found" URLs that then 401'd everywhere downstream.
                    // Mirrors the redetect path (`resolve_streams`' inject).
                    cam.rtsp_main = detail
                        .rtsp_main
                        .as_deref()
                        .map(|u| inject_rtsp_credentials(u, &creds.username, &creds.password));
                    cam.rtsp_sub = detail
                        .rtsp_sub
                        .as_deref()
                        .map(|u| inject_rtsp_credentials(u, &creds.username, &creds.password));
                    cam.note = if cam.rtsp_main.is_some() {
                        "ONVIF — stream URL auto-filled".to_owned()
                    } else {
                        "ONVIF — connected, but no stream URL was returned".to_owned()
                    };
                }
                Err(e) => {
                    tracing::debug!(%ip, error = %e, "ONVIF authenticated detail failed");
                    "ONVIF — credentials rejected or detail unavailable".clone_into(&mut cam.note);
                }
            }
        } else {
            "ONVIF — enter credentials to auto-fill the stream URL".clone_into(&mut cam.note);
        }
        return Some(cam);
    }

    // ── RTSP fallback (non-ONVIF cameras) ──
    if rtsp_responds(ip).await {
        if !cam.open_ports.contains(&RTSP_PORT) {
            cam.open_ports.push(RTSP_PORT);
        }
        cam.rtsp_main = Some(format!("rtsp://{ip}:{RTSP_PORT}/"));
        "RTSP server — not ONVIF; complete the stream path manually".clone_into(&mut cam.note);
        return Some(cam);
    }

    // No camera signal: report only if a camera-ish port was open AND it's not a
    // bare web server (port 80 alone is too weak a signal to surface).
    if cam.open_ports.iter().any(|&p| p == RTSP_PORT || p == 8000) {
        "Open camera-style port — could not confirm ONVIF/RTSP".clone_into(&mut cam.note);
        return Some(cam);
    }

    None
}

// ─── low-level probes ────────────────────────────────────────────────────────────

/// TCP connect with [`CONNECT_TIMEOUT`]; true ⇒ the port accepted a connection.
async fn tcp_open(ip: Ipv4Addr, port: u16) -> bool {
    let addr = SocketAddr::from((IpAddr::V4(ip), port));
    matches!(
        tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await,
        Ok(Ok(_))
    )
}

/// POST an unauthenticated `GetSystemDateAndTime` SOAP envelope and check for a
/// SOAP response. ONVIF mandates this call answer without credentials, so it is
/// the canonical "is this an ONVIF device?" probe. `budget` is the effective
/// per-host timeout (see [`probe_host`]) and becomes the reqwest client's
/// request timeout — this is the knob that actually needs to stretch for a
/// slow ONVIF responder, since the request would otherwise be cut off
/// mid-response regardless of the outer [`tokio::time::timeout`] budget.
async fn onvif_responds(service_url: &str, budget: Duration) -> bool {
    const ENVELOPE: &str = concat!(
        r#"<?xml version="1.0" encoding="UTF-8"?>"#,
        r#"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">"#,
        r#"<s:Body xmlns:tds="http://www.onvif.org/ver10/device/wsdl">"#,
        r#"<tds:GetSystemDateAndTime/></s:Body></s:Envelope>"#
    );

    let Ok(client) = reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(budget)
        .build()
    else {
        return false;
    };

    let resp = client
        .post(service_url)
        .header(
            reqwest::header::CONTENT_TYPE,
            // SOAP 1.2 with the GetSystemDateAndTime action.
            "application/soap+xml; charset=utf-8; \
             action=\"http://www.onvif.org/ver10/device/wsdl/GetSystemDateAndTime\"",
        )
        .body(ENVELOPE)
        .send()
        .await;

    match resp {
        Ok(r) => {
            // ONVIF returns 200 on success; some firmwares return 400/500 with a
            // SOAP Fault body — still proof it speaks ONVIF. Confirm via the body.
            let body = r.text().await.unwrap_or_default();
            let lc = body.to_ascii_lowercase();
            lc.contains("getsystemdateandtimeresponse")
                || lc.contains("systemdateandtime")
                || (lc.contains("envelope") && lc.contains("onvif"))
        }
        Err(_) => false,
    }
}

/// Open port 554 and send an RTSP `OPTIONS`; true ⇒ a well-formed `RTSP/1.0`
/// reply came back (a real RTSP server, ONVIF or not).
async fn rtsp_responds(ip: Ipv4Addr) -> bool {
    let addr = SocketAddr::from((IpAddr::V4(ip), RTSP_PORT));
    let Ok(Ok(mut stream)) = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await
    else {
        return false;
    };

    let req = format!(
        "OPTIONS rtsp://{ip}:{RTSP_PORT}/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Crumb-Discovery\r\n\r\n"
    );
    if !tokio::time::timeout(CONNECT_TIMEOUT, stream.write_all(req.as_bytes()))
        .await
        .is_ok_and(|r| r.is_ok())
    {
        return false;
    }

    let mut buf = [0u8; 256];
    match tokio::time::timeout(CONNECT_TIMEOUT, stream.read(&mut buf)).await {
        Ok(Ok(n)) if n > 0 => {
            let head = String::from_utf8_lossy(&buf[..n]);
            head.starts_with("RTSP/")
        }
        _ => false,
    }
}

// ─── authenticated ONVIF detail (manufacturer/model + real stream URIs) ──────────

/// Authenticated detail fetched from an ONVIF device.
#[derive(Default)]
struct OnvifDetail {
    manufacturer: Option<String>,
    model: Option<String>,
    firmware: Option<String>,
    rtsp_main: Option<String>,
    rtsp_sub: Option<String>,
}

/// Build device/media clients (same pattern as `ptz.rs`) and fetch device info +
/// stream URIs. Best-effort: a failure of any sub-call degrades that field to
/// `None` rather than failing the whole host.
async fn onvif_details(service_url: &str, creds: &Credentials) -> anyhow::Result<OnvifDetail> {
    let device_url: Url = service_url.parse()?;

    let device_client = ClientBuilder::new(&device_url)
        .credentials(Some(creds.clone()))
        .auth_type(AuthType::Any)
        .build();

    let mut detail = OnvifDetail::default();

    // ── GetDeviceInformation ──
    if let Ok(info) =
        schema::devicemgmt::get_device_information(&device_client, &Default::default()).await
    {
        detail.manufacturer = non_empty(&info.manufacturer);
        detail.model = non_empty(&info.model);
        detail.firmware = non_empty(&info.firmware_version);
    }

    // ── media service URL (discover, else well-known fallback) ──
    let media_url = discover_media_url(&device_client, &device_url).await;
    let media_client = ClientBuilder::new(&media_url)
        .credentials(Some(creds.clone()))
        .auth_type(AuthType::Any)
        .build();

    // ── GetProfiles → GetStreamUri for the first two profiles ──
    if let Ok(profiles) = schema::media::get_profiles(&media_client, &Default::default()).await {
        let mut tokens = profiles
            .profiles
            .into_iter()
            .map(|p| schema::onvif::ReferenceToken(p.token.0));

        if let Some(tok) = tokens.next() {
            detail.rtsp_main = stream_uri(&media_client, tok).await;
        }
        if let Some(tok) = tokens.next() {
            detail.rtsp_sub = stream_uri(&media_client, tok).await;
        }
    }

    Ok(detail)
}

/// `GetStreamUri` for one profile, requesting RTSP-over-RTSP transport. Returns
/// the URI on success, `None` on any error (best-effort).
async fn stream_uri(
    media_client: &onvif::soap::client::Client,
    profile_token: schema::onvif::ReferenceToken,
) -> Option<String> {
    let req = schema::media::GetStreamUri {
        stream_setup: schema::onvif::StreamSetup {
            stream: schema::onvif::StreamType::RtpUnicast,
            transport: schema::onvif::Transport {
                protocol: schema::onvif::TransportProtocol::Rtsp,
                tunnel: vec![],
            },
        },
        profile_token,
    };
    match schema::media::get_stream_uri(media_client, &req).await {
        Ok(resp) => non_empty(&resp.media_uri.uri),
        Err(e) => {
            tracing::debug!(error = %e, "ONVIF GetStreamUri failed");
            None
        }
    }
}

/// Discover the media service `XAddr` via `GetServices`, falling back to the
/// well-known `/onvif/media_service` path off the device base. Mirrors the
/// resilient discovery in `ptz.rs`.
async fn discover_media_url(device_client: &onvif::soap::client::Client, device_url: &Url) -> Url {
    let fallback: Url = {
        let host = device_url.host_str().unwrap_or("127.0.0.1");
        let port = device_url.port().unwrap_or(80);
        format!("http://{host}:{port}/onvif/media_service")
            .parse()
            .unwrap_or_else(|_| device_url.clone())
    };

    let services = match schema::devicemgmt::get_services(device_client, &Default::default()).await
    {
        Ok(r) => r,
        Err(_) => return fallback,
    };

    for service in &services.service {
        if matches!(
            service.namespace.as_str(),
            "http://www.onvif.org/ver10/media/wsdl" | "http://www.onvif.org/ver20/media/wsdl"
        ) {
            if let Ok(u) = Url::parse(&service.x_addr) {
                return u;
            }
        }
    }
    fallback
}

/// Trim a string and return `None` when it is blank (ONVIF often returns empty
/// strings rather than omitting a field).
fn non_empty(s: &str) -> Option<String> {
    let t = s.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_owned())
    }
}

// ─── C7: ONVIF re-detect (called by api-routes' redetect handler) ──────────────

/// Result of re-running ONVIF discovery against a camera's stored credentials.
///
/// Contains the raw camera source URIs (returned by `GetStreamUri` — these are
/// what goes into `cameras.source_url`/`source_sub_url`, NOT the re-stream
/// addresses). PTZ support is detected via `GetServices`; on failure it
/// defaults to `false` and the operator may tick PTZ manually (Risk R7).
pub(crate) struct RedetectResult {
    /// Raw RTSP main-stream URI from `GetStreamUri` on the first media profile.
    pub source_url: String,
    /// Raw RTSP sub-stream URI from `GetStreamUri` on the second profile, if any.
    pub source_sub_url: Option<String>,
    /// Whether the camera advertises a PTZ service via `GetServices`.
    pub ptz_supported: bool,
}

/// Re-run ONVIF `GetProfiles` / `GetStreamUri` against `host:port` with the
/// supplied credentials and return new source URLs + PTZ capability.
///
/// PTZ is probed by checking whether `GetServices` returns a PTZ `XAddr`
/// (namespace `http://www.onvif.org/ver20/ptz/wsdl`). On any ONVIF error the
/// result degrades gracefully: stream URIs are required (return `Err` if absent),
/// but PTZ defaults to `false` so the operator can tick it manually (Risk R7).
///
/// # Credential injection (#6)
///
/// ONVIF `GetStreamUri` returns the raw camera RTSP URL, which many firmware
/// builds emit WITHOUT embedded credentials (e.g. `rtsp://10.0.0.1:554/h264`).
/// When go2rtc tries to open that URL as a producer it will fail auth, silently
/// stopping recording for the camera.  We inject the stored ONVIF username and
/// password into both `source_url` and `source_sub_url` via
/// [`url::Url::set_username`] / [`url::Url::set_password`], URL-encoding the
/// values so special characters in passwords do not break the RTSP URI.
///
/// Credentials are injected ONLY when they are non-empty — some cameras accept
/// anonymous RTSP and deliberately return a URL without a userinfo component.
///
/// # Reachability probe (#6)
///
/// A successful `GetStreamUri` response from the camera does not guarantee that
/// the returned RTSP URL is reachable (wrong path, network ACL, etc.). After
/// resolving `source_url` we perform a TCP-level reachability probe (same
/// function used during discovery) against the camera's RTSP port (extracted
/// from the URL, defaulting to 554). On probe failure we log a warning but
/// still return `Ok` — the URL may be valid on a different network path, and
/// the operator should see the warning in logs. Trusting go2rtc's 400 response
/// alone (the old behaviour) is insufficient because go2rtc defers the source
/// probe and answers 400 for any registration, success or failure.
///
/// # COALESCE sub (#6)
///
/// When the ONVIF device reports only one media profile (no sub stream),
/// `source_sub_url` is `None` in the returned [`RedetectResult`]. Callers
/// (`config_routes.rs` → `db::update_camera_onvif_and_sources`) should treat
/// `None` as "preserve the existing sub URL" rather than overwriting it with
/// NULL. The db layer performs `COALESCE($3, source_sub_url)` for the sub
/// column; this behaviour is documented here for callers.
///
/// # Errors
///
/// Returns `Err` when the ONVIF device is unreachable, rejects credentials, or
/// reports zero media profiles. Partial failures (sub-stream absent, PTZ service
/// absent) are not errors.
pub(crate) async fn redetect_camera_streams(
    host: &str,
    port: u16,
    user: &str,
    password: &str,
) -> anyhow::Result<RedetectResult> {
    let service_url = format!("http://{host}:{port}/onvif/device_service");
    let creds = Credentials {
        username: user.to_owned(),
        password: password.to_owned(),
    };

    // Re-use onvif_details for the media/stream-URI part.
    let detail = onvif_details(&service_url, &creds).await?;

    let raw_main = detail.rtsp_main.ok_or_else(|| {
        anyhow::anyhow!("ONVIF re-detect: no main stream profile returned for {host}:{port}")
    })?;

    // ── credential injection ──────────────────────────────────────────────────
    // Inject stored ONVIF credentials into the returned RTSP URLs so the go2rtc
    // producer can authenticate against the camera.  Skip injection when the
    // URL cannot be parsed (fall back to the raw URL to avoid data loss).
    let source_url = inject_rtsp_credentials(&raw_main, user, password);
    let source_sub_url = detail
        .rtsp_sub
        .as_deref()
        .map(|raw| inject_rtsp_credentials(raw, user, password));

    // ── post-redetect reachability probe ──────────────────────────────────────
    // Probe TCP connectivity to the RTSP port so the operator sees a warning
    // when the camera's returned URL is on an unreachable address/port rather
    // than silently relying on go2rtc's deferred probe (which returns 400 for
    // both success and failure).
    //
    // The probe uses the host/port from the returned RTSP URL when parseable;
    // falls back to the ONVIF management host (same camera, different path).
    let (probe_host_str, probe_port) = Url::parse(&source_url).ok().map_or_else(
        || (host.to_owned(), RTSP_PORT),
        |u| {
            let h = u.host_str().unwrap_or(host).to_owned();
            let p = u.port().unwrap_or(RTSP_PORT);
            (h, p)
        },
    );

    let reachable = tokio::time::timeout(
        CONNECT_TIMEOUT,
        TcpStream::connect(format!("{probe_host_str}:{probe_port}")),
    )
    .await
    .is_ok_and(|r| r.is_ok());

    if !reachable {
        tracing::warn!(
            rtsp_url = %source_url,
            onvif_host = %host,
            probe_host = %probe_host_str,
            probe_port,
            "ONVIF re-detect: TCP probe to RTSP port failed — URL may be unreachable; \
             recording will begin once the camera is reachable"
        );
    }

    // PTZ probe: check GetServices for a PTZ XAddr.
    // Failure → false (acceptable for v1; operator ticks PTZ manually).
    let ptz_supported = probe_ptz_service(&service_url, &creds).await;

    Ok(RedetectResult {
        source_url,
        // None = camera has only one profile; caller preserves existing sub URL.
        source_sub_url,
        ptz_supported,
    })
}

/// Inject ONVIF credentials (username/password) into an RTSP URL's userinfo
/// component, URL-encoding both so special characters do not corrupt the URI.
///
/// Returns the original URL string unchanged when:
/// * `user` is empty (anonymous access — no credentials to inject).
/// * The URL cannot be parsed (avoids data loss; caller logs as-needed).
/// * `set_username` / `set_password` fail (e.g. `cannot-be-a-base` URLs).
fn inject_rtsp_credentials(url_str: &str, user: &str, password: &str) -> String {
    // Nothing to inject when there is no username.
    if user.is_empty() {
        return url_str.to_owned();
    }
    let Ok(mut u) = Url::parse(url_str) else {
        // Unparseable URL — return as-is rather than corrupting it.
        return url_str.to_owned();
    };
    // `set_username`/`set_password` percent-encode the value so any special
    // characters (e.g. `@`, `:`, `%`, spaces) do not break the URL.
    if u.set_username(user).is_err() {
        return url_str.to_owned();
    }
    // Password may legitimately be empty (camera accepting username-only auth).
    let _ = u.set_password(if password.is_empty() {
        None
    } else {
        Some(password)
    });
    u.to_string()
}

/// Probe whether the ONVIF device at `service_url` advertises a PTZ service.
///
/// Returns `true` when `GetServices` lists the PTZ namespace; `false` on any
/// error or when PTZ is absent. Acceptable false-negative rate (Risk R7).
async fn probe_ptz_service(service_url: &str, creds: &Credentials) -> bool {
    let Ok(device_url) = service_url.parse::<Url>() else {
        return false;
    };
    let device_client = ClientBuilder::new(&device_url)
        .credentials(Some(creds.clone()))
        .auth_type(AuthType::Any)
        .build();
    match schema::devicemgmt::get_services(&device_client, &Default::default()).await {
        Ok(resp) => resp
            .service
            .iter()
            .any(|s| s.namespace.as_str().contains("onvif.org/ver20/ptz")),
        Err(_) => false,
    }
}

// ─── tests ───────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_ip() {
        let v = parse_range("192.168.1.50").unwrap();
        assert_eq!(v, vec![Ipv4Addr::new(192, 168, 1, 50)]);
    }

    #[test]
    fn cidr_24_excludes_network_and_broadcast() {
        let v = parse_range("192.168.1.0/24").unwrap();
        assert_eq!(v.len(), 254);
        assert_eq!(v[0], Ipv4Addr::new(192, 168, 1, 1));
        assert_eq!(v[253], Ipv4Addr::new(192, 168, 1, 254));
    }

    #[test]
    fn cidr_32_single_host() {
        let v = parse_range("192.168.1.7/32").unwrap();
        assert_eq!(v, vec![Ipv4Addr::new(192, 168, 1, 7)]);
    }

    #[test]
    fn dash_range_last_octet() {
        let v = parse_range("192.168.1.1-254").unwrap();
        assert_eq!(v.len(), 254);
        assert_eq!(v[0], Ipv4Addr::new(192, 168, 1, 1));
        assert_eq!(v[253], Ipv4Addr::new(192, 168, 1, 254));
    }

    #[test]
    fn dash_range_full_ip() {
        let v = parse_range("192.168.1.10-192.168.1.20").unwrap();
        assert_eq!(v.len(), 11);
        assert_eq!(v[0], Ipv4Addr::new(192, 168, 1, 10));
        assert_eq!(v[10], Ipv4Addr::new(192, 168, 1, 20));
    }

    #[test]
    fn dash_range_inverted_rejected() {
        assert!(parse_range("192.168.1.20-10").is_err());
    }

    #[test]
    fn oversize_cidr_rejected() {
        // /16 = 65534 hosts > MAX_HOSTS
        assert!(parse_range("192.168.0.0/16").is_err());
    }

    #[test]
    fn oversize_dash_rejected() {
        assert!(parse_range("192.168.0.0-192.168.255.255").is_err());
    }

    #[test]
    fn garbage_rejected() {
        assert!(parse_range("not-an-ip").is_err());
        assert!(parse_range("").is_err());
    }

    // ── inject_rtsp_credentials ───────────────────────────────────────────────

    #[test]
    fn inject_creds_no_existing_userinfo() {
        // Bare URL: credentials should be injected.
        let result = inject_rtsp_credentials("rtsp://10.0.0.1:554/h264", "admin", "secret");
        let u = Url::parse(&result).unwrap();
        assert_eq!(u.username(), "admin");
        assert_eq!(u.password(), Some("secret"));
        assert_eq!(u.host_str(), Some("10.0.0.1"));
        assert_eq!(u.port(), Some(554));
        assert!(u.path().contains("h264"));
    }

    #[test]
    fn inject_creds_empty_user_is_noop() {
        // When user is empty, return the original URL unchanged.
        let url = "rtsp://10.0.0.1:554/h264";
        let result = inject_rtsp_credentials(url, "", "ignored");
        assert_eq!(result, url);
    }

    #[test]
    fn inject_creds_special_chars_percent_encoded() {
        // '@' and ':' in the password MUST be percent-encoded so they don't break
        // the URL structure (a raw '@' would split userinfo from host; a raw ':'
        // would split user:pass). go2rtc/ffmpeg percent-decode the userinfo before
        // dialing the camera, so the encoded form is the correct thing to store.
        let result =
            inject_rtsp_credentials("rtsp://10.0.0.2:554/stream1", "cam_user", "p@ss:w0rd!");
        let u = Url::parse(&result).unwrap();
        assert_eq!(u.username(), "cam_user");
        // url::Url::password() returns the value AS STORED in the URL — percent-encoded.
        assert_eq!(u.password(), Some("p%40ss%3Aw0rd!"));
        // The URL structure is intact despite the special chars.
        assert_eq!(u.host_str(), Some("10.0.0.2"));
        assert_eq!(u.port(), Some(554));
    }

    #[test]
    fn inject_creds_overwrite_existing_userinfo() {
        // If the camera's GetStreamUri already returned a URL with creds, they
        // should be overwritten with the stored ONVIF creds (the DB is authoritative).
        let result = inject_rtsp_credentials(
            "rtsp://old_user:old_pass@10.0.0.3:554/cam",
            "new_user",
            "new_pass",
        );
        let u = Url::parse(&result).unwrap();
        assert_eq!(u.username(), "new_user");
        assert_eq!(u.password(), Some("new_pass"));
    }

    #[test]
    fn inject_creds_empty_password_sets_no_password() {
        // A non-empty user but empty password → no password component.
        let result = inject_rtsp_credentials("rtsp://10.0.0.4:554/live", "admin", "");
        let u = Url::parse(&result).unwrap();
        assert_eq!(u.username(), "admin");
        assert_eq!(u.password(), None);
    }

    #[test]
    fn inject_creds_unparseable_url_returned_unchanged() {
        // Malformed URL should be returned as-is, never panicking.
        let bad = "not a url at all @@";
        let result = inject_rtsp_credentials(bad, "admin", "pass");
        assert_eq!(result, bad);
    }

    // ── resolve_probe_timeout ─────────────────────────────────────────────────

    #[test]
    fn resolve_timeout_absent_uses_default() {
        // No override supplied ⇒ existing behaviour is unchanged.
        assert_eq!(resolve_probe_timeout(None), PROBE_TIMEOUT);
    }

    #[test]
    fn resolve_timeout_within_range_passes_through() {
        assert_eq!(resolve_probe_timeout(Some(3000)), Duration::from_secs(3));
    }

    #[test]
    fn resolve_timeout_below_min_clamped_up() {
        // Below MIN_TIMEOUT_MS (including 0) clamps up to the floor.
        assert_eq!(
            resolve_probe_timeout(Some(0)),
            Duration::from_millis(MIN_TIMEOUT_MS)
        );
        assert_eq!(
            resolve_probe_timeout(Some(100)),
            Duration::from_millis(MIN_TIMEOUT_MS)
        );
    }

    #[test]
    fn resolve_timeout_above_max_clamped_down() {
        // A pathologically large value (or u64::MAX) clamps down to the ceiling
        // rather than letting a single host stall an operator-facing re-scan.
        assert_eq!(
            resolve_probe_timeout(Some(60_000)),
            Duration::from_millis(MAX_TIMEOUT_MS)
        );
        assert_eq!(
            resolve_probe_timeout(Some(u64::MAX)),
            Duration::from_millis(MAX_TIMEOUT_MS)
        );
    }

    #[test]
    fn resolve_timeout_boundary_values_pass_through_unclamped() {
        assert_eq!(
            resolve_probe_timeout(Some(MIN_TIMEOUT_MS)),
            Duration::from_millis(MIN_TIMEOUT_MS)
        );
        assert_eq!(
            resolve_probe_timeout(Some(MAX_TIMEOUT_MS)),
            Duration::from_millis(MAX_TIMEOUT_MS)
        );
    }

    // ── brand table ───────────────────────────────────────────────────────────

    #[test]
    fn reolink_returns_h264_h265_and_preview_variants_in_order() {
        let paths = brand_paths(Some("reolink"));
        assert_eq!(
            paths,
            &[
                ("/h264Preview_01_main", Some("/h264Preview_01_sub")),
                ("/h265Preview_01_main", Some("/h265Preview_01_sub")),
                ("/Preview_01_main", Some("/Preview_01_sub")),
            ]
        );
    }

    #[test]
    fn reolink_lookup_is_case_insensitive() {
        assert_eq!(brand_paths(Some("Reolink")), brand_paths(Some("reolink")));
        assert_eq!(brand_paths(Some("REOLINK")), brand_paths(Some("reolink")));
    }

    #[test]
    fn hikvision_paths() {
        assert_eq!(
            brand_paths(Some("hikvision")),
            &[("/Streaming/Channels/101", Some("/Streaming/Channels/102"))]
        );
    }

    #[test]
    fn dahua_and_amcrest_share_the_same_paths() {
        let dahua = brand_paths(Some("dahua"));
        let amcrest = brand_paths(Some("amcrest"));
        assert_eq!(dahua, amcrest);
        assert_eq!(
            dahua,
            &[(
                "/cam/realmonitor?channel=1&subtype=0",
                Some("/cam/realmonitor?channel=1&subtype=1")
            )]
        );
    }

    #[test]
    fn uniview_paths() {
        assert_eq!(
            brand_paths(Some("uniview")),
            &[("/media/video1", Some("/media/video2"))]
        );
    }

    #[test]
    fn axis_has_no_sub_path() {
        let paths = brand_paths(Some("axis"));
        assert_eq!(paths.len(), 1);
        assert_eq!(paths[0].1, None);
    }

    #[test]
    fn tplink_paths() {
        assert_eq!(
            brand_paths(Some("tplink")),
            &[("/stream1", Some("/stream2"))]
        );
    }

    #[test]
    fn generic_and_unknown_brand_return_empty() {
        assert!(brand_paths(Some("generic")).is_empty());
        assert!(brand_paths(Some("not-a-real-brand")).is_empty());
        assert!(brand_paths(None).is_empty());
    }

    #[test]
    fn every_brand_key_is_lookupable_via_the_table() {
        // Guards against a copy/paste key typo silently making a brand
        // unreachable from brand_paths().
        for b in BRAND_TABLE {
            assert_eq!(brand_paths(Some(b.key)), b.paths, "brand {}", b.key);
        }
    }

    #[test]
    fn auto_candidates_is_nonempty_and_deduplicated() {
        let candidates = auto_candidates();
        assert!(!candidates.is_empty());
        let mut seen = std::collections::HashSet::new();
        for c in &candidates {
            assert!(seen.insert(*c), "duplicate candidate: {c:?}");
        }
        // Dahua and Amcrest share identical paths — auto should list the pair
        // once, not twice.
        let dahua_pair = (
            "/cam/realmonitor?channel=1&subtype=0",
            Some("/cam/realmonitor?channel=1&subtype=1"),
        );
        assert_eq!(candidates.iter().filter(|&&c| c == dahua_pair).count(), 1);
    }

    #[test]
    fn auto_candidates_leads_with_reolink() {
        // Reolink is the canonical slow/flaky-ONVIF brand this whole feature
        // targets; it must be tried early in the auto superset.
        let candidates = auto_candidates();
        assert_eq!(candidates[0].0, "/h264Preview_01_main");
    }

    // ── render_candidate ─────────────────────────────────────────────────────

    #[test]
    fn render_candidate_no_creds() {
        let url = render_candidate("192.168.1.50", 554, "/h264Preview_01_main", "", "");
        assert_eq!(url, "rtsp://192.168.1.50:554/h264Preview_01_main");
    }

    #[test]
    fn render_candidate_with_creds_are_injected_and_encoded() {
        let url = render_candidate(
            "192.168.1.50",
            554,
            "/h264Preview_01_main",
            "admin",
            "p@ss:w0rd",
        );
        let parsed = Url::parse(&url).unwrap();
        assert_eq!(parsed.username(), "admin");
        // Special characters percent-encoded (see inject_rtsp_credentials tests).
        assert_eq!(parsed.password(), Some("p%40ss%3Aw0rd"));
        assert_eq!(parsed.path(), "/h264Preview_01_main");
    }

    #[test]
    fn render_candidate_custom_port() {
        let url = render_candidate("10.0.0.5", 8554, "/media/video1", "user", "pass");
        let parsed = Url::parse(&url).unwrap();
        assert_eq!(parsed.port(), Some(8554));
    }

    #[test]
    fn render_candidate_preserves_query_string_path() {
        // Dahua/Amcrest paths carry a query string — make sure it survives
        // both the no-creds and creds-injected render.
        let bare = render_candidate(
            "10.0.0.6",
            554,
            "/cam/realmonitor?channel=1&subtype=0",
            "",
            "",
        );
        assert_eq!(
            bare,
            "rtsp://10.0.0.6:554/cam/realmonitor?channel=1&subtype=0"
        );

        let with_creds = render_candidate(
            "10.0.0.6",
            554,
            "/cam/realmonitor?channel=1&subtype=0",
            "admin",
            "secret",
        );
        let parsed = Url::parse(&with_creds).unwrap();
        assert_eq!(parsed.username(), "admin");
        assert_eq!(parsed.path(), "/cam/realmonitor");
        assert_eq!(parsed.query(), Some("channel=1&subtype=0"));
    }
}
