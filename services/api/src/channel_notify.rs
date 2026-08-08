// SPDX-License-Identifier: AGPL-3.0-or-later

//! Third-party notification channel dispatch.
//!
//! [`dispatch`] is the single entry-point: given a [`NotificationChannel`] row and
//! a [`ChannelMessage`], it formats and POSTs the outbound HTTP request to the
//! appropriate service.
//!
//! # Supported kinds and image capability
//!
//! Each channel carries a [`SnapshotMode`] (`none`/`plate`/`vehicle`/`both`),
//! but a provider can only deliver what its transport allows. The capability is
//! the hard gate ([`provider_image_capability`]); the mode is the operator's
//! preference within it.
//!
//! | `kind`    | Delivery                                                | Image capability            |
//! |-----------|---------------------------------------------------------|-----------------------------|
//! | `discord` | POST webhook `payload_json` + multipart `file[N]`       | **Multi** (plate+vehicle)   |
//! | `telegram`| `sendPhoto` (1) / `sendMediaGroup` (2) / `sendMessage`  | **Multi** (plate+vehicle)   |
//! | `pushover`| POST multipart; single `attachment` field              | **Single** (`both`→plate)   |
//! | `ntfy`    | POST topic URL; file as body + `Filename`/`Message` hdr | **Single** (`both`→plate)   |
//! | `slack`   | POST incoming-webhook JSON `{text}`; link in text       | **None** (no byte path)     |
//! | `webhook` | POST JSON `{camera, kind, label, ts, web_url, ...}`     | **None** (JSON only)        |
//!
//! `slack` and `webhook` cannot carry raw image bytes: a Slack incoming webhook
//! only accepts an `image_url` its servers must fetch (Crumb is LAN-only, so a
//! LAN `web_url` is unreachable — a real file upload needs a bot token +
//! `files.upload`, out of scope), and the generic webhook is a JSON contract by
//! design. Both stay text/link-only regardless of the channel's mode.
//!
//! Returns `Err` on any non-2xx response or network failure so the engine can log
//! `status='failed'`.  The caller is responsible for sending the notification
//! WITHOUT an image when the snapshot fetch fails (never drop the alert).

use std::process::Stdio;
use std::time::Duration;

use anyhow::{anyhow, bail, Context as _};
use chrono::{DateTime, Utc};
use reqwest::multipart;
use serde_json::json;
use tokio::io::AsyncWriteExt as _;
use uuid::Uuid;

use crumb_common::db::{NotificationChannel, SnapshotMode};

/// Hard cap on a snapshot body proxied/fetched from an upstream provider
/// (go2rtc / Frigate). A JPEG frame is well under this; the cap exists purely so
/// a hostile or broken upstream that streams an unbounded body can't OOM the
/// api. Shared by every snapshot-fetch path (channel dispatch, the LPR system
/// alert path in `notifications.rs`, and the `/events/:id/snapshot` proxy).
pub(crate) const MAX_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024; // 8 MiB

/// Read an HTTP response body into memory, aborting if it exceeds `max` bytes.
///
/// `reqwest::Response::bytes()` buffers the whole body with no bound — an
/// upstream that declares a huge (or omits its) Content-Length and keeps sending
/// could exhaust memory. This reads chunk-by-chunk and bails the moment the
/// accumulated size would exceed `max`, so a runaway body is dropped early
/// rather than fully buffered. Also fast-rejects when the declared
/// Content-Length already exceeds the cap.
pub(crate) async fn read_body_capped(
    mut resp: reqwest::Response,
    max: usize,
) -> anyhow::Result<Vec<u8>> {
    if let Some(len) = resp.content_length() {
        if len > max as u64 {
            bail!("upstream body Content-Length {len} exceeds cap of {max} bytes");
        }
    }
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = resp.chunk().await.context("read upstream body chunk")? {
        if buf.len() + chunk.len() > max {
            bail!("upstream body exceeds cap of {max} bytes");
        }
        buf.extend_from_slice(&chunk);
    }
    Ok(buf)
}

/// A notification message built once per engine event and shared across all
/// matching channels.
pub struct ChannelMessage {
    /// Human-readable camera name from the DB. For `kind == "system"` events
    /// with no associated camera this is a fixed placeholder (see
    /// [`notifications::run_notification_engine`](crate::notifications)) —
    /// system alerts are not camera-scoped the way motion/detection are.
    pub camera_name: String,
    /// `'motion'` | `'detection'` | `'system'` (P0-HEALTH-NOTIFY: recorder/
    /// camera health, storage, and other footage-loss-relevant conditions —
    /// see `system_alert_rules.event_key` for the full list of system kinds,
    /// carried here in `label`).
    pub kind: &'static str,
    /// Optional human-readable label. For `detection` this is the object
    /// label (e.g. `"person"`, `"car"`); for `system` this is the human title
    /// of the alert (e.g. `"Recorder offline"`).
    pub label: Option<String>,
    /// Timestamp of the originating event.
    pub ts: DateTime<Utc>,
    /// Best-effort public deep-link to the playback view. `None` when no public
    /// URL is configured for this installation.
    pub web_url: Option<String>,
    /// Full vehicle/detection frame JPEG bytes, when available. The legacy
    /// "snapshot" — the whole frame a `vehicle`/`both` mode attaches, and the
    /// defensive fallback for `plate` mode when no crop could be produced.
    pub vehicle_snapshot: Option<Vec<u8>>,
    /// Tight plate-crop JPEG bytes, when available (derived once per event from
    /// the vehicle frame + `plate_bbox`, or a crumb-alpr stored crop). Attached
    /// by `plate`/`both` modes where the provider can carry it.
    pub plate_snapshot: Option<Vec<u8>>,
    /// `kind == "system"` only: the free-text detail string from
    /// `system_events.detail` (e.g. "camera X has written no new segment for
    /// 130s"), appended to the message body / exposed as the `%detail%` token.
    pub detail: Option<String>,
    /// `kind == "system"` only: the resolved message-body template (operator
    /// override or the built-in default), rendered by [`ChannelMessage::text`]
    /// via `crumb_common::alert_template`. `None` for motion/detection (and as a
    /// defensive fallback for system) keeps the legacy hardcoded wording.
    pub template: Option<String>,
    /// `kind == "system"` only: the operator's custom provider-title template.
    /// `None` keeps each provider's existing default title construction
    /// unchanged (so an unset title never alters current behaviour).
    pub title_template: Option<String>,
    /// `kind == "system"` only: the event's structured `meta` tokens (migration
    /// 0079), merged UNDER the built-ins when rendering (a built-in like
    /// `%camera%` can never be shadowed by a meta key).
    pub meta: Option<serde_json::Value>,
}

impl ChannelMessage {
    /// Build the `%token%` map for templating: the always-available built-ins
    /// plus the event's structured `meta`. Built-ins are inserted LAST so a
    /// meta key can never shadow `%camera%`/`%event%`/etc.
    ///
    /// Timezone: date/time render in UTC, matching the `ts` formatting the
    /// notification path has always used. This is not a per-user local time; if
    /// per-user timezone is ever added it belongs there, not baked in here.
    fn token_map(&self) -> std::collections::BTreeMap<String, String> {
        let mut map = std::collections::BTreeMap::new();
        // Meta first (lowest priority) — flat object of scalar values only.
        if let Some(serde_json::Value::Object(obj)) = &self.meta {
            for (k, v) in obj {
                if let Some(s) = json_scalar_to_string(v) {
                    map.insert(k.clone(), s);
                }
            }
        }
        // Built-ins (win over any meta key of the same name).
        map.insert("camera".to_owned(), self.camera_name.clone());
        map.insert("date".to_owned(), self.ts.format("%Y-%m-%d").to_string());
        map.insert("time".to_owned(), self.ts.format("%H:%M:%S").to_string());
        map.insert(
            "datetime".to_owned(),
            self.ts.format("%Y-%m-%d %H:%M:%S UTC").to_string(),
        );
        map.insert(
            "event".to_owned(),
            self.label
                .clone()
                .unwrap_or_else(|| "System alert".to_owned()),
        );
        map.insert("detail".to_owned(), self.detail.clone().unwrap_or_default());
        map
    }

    /// Human-readable one-liner suitable for all channel types.
    ///
    /// For a system alert with a resolved [`template`](Self::template) the text
    /// is rendered via `crumb_common::alert_template` (operator-customizable).
    /// Motion/detection — and a system event with no template (defensive) — use
    /// the legacy hardcoded wording, unchanged.
    pub fn text(&self) -> String {
        if let Some(tpl) = &self.template {
            return crumb_common::alert_template::render(tpl, &self.token_map());
        }
        let cam = &self.camera_name;
        let ts = self.ts.format("%Y-%m-%d %H:%M:%S UTC");
        if self.kind == "system" {
            let title = self.label.as_deref().unwrap_or("System alert");
            return match &self.detail {
                Some(d) if !d.is_empty() => format!("[Crumb] ⚠️ {title} — {d} (at {ts})"),
                _ => format!("[Crumb] ⚠️ {title} (at {ts})"),
            };
        }
        match &self.label {
            Some(lbl) if self.kind == "detection" => {
                format!("[Crumb] {lbl} detected on {cam} at {ts}")
            }
            _ => format!("[Crumb] Motion on {cam} at {ts}"),
        }
    }

    /// The operator's custom provider title, rendered, when a `title_template`
    /// is set; otherwise `None` so the provider keeps its own default title.
    pub fn rendered_title(&self) -> Option<String> {
        self.title_template
            .as_ref()
            .map(|tpl| crumb_common::alert_template::render(tpl, &self.token_map()))
    }

    /// Resolve this channel's snapshot mode + the provider's image capability +
    /// the images actually available into the ordered list of files to attach.
    ///
    /// Returns `(filename, bytes)` pairs (0, 1, or 2). The order is meaningful:
    /// for a two-image provider in `both` mode the vehicle frame is first and
    /// the plate crop second (the crop is the more informative of the two, but
    /// the frame gives context). See [`plan_images`] for the full matrix.
    fn images_for<'a>(&'a self, ch: &NotificationChannel) -> Vec<(&'static str, &'a [u8])> {
        let cap = provider_image_capability(ch.kind.as_str());
        plan_images(
            ch.snapshot_mode,
            cap,
            self.vehicle_snapshot.is_some(),
            self.plate_snapshot.is_some(),
        )
        .into_iter()
        .filter_map(|src| match src {
            ImgSource::Vehicle => self.vehicle_snapshot.as_deref().map(|b| ("vehicle.jpg", b)),
            ImgSource::Plate => self.plate_snapshot.as_deref().map(|b| ("plate.jpg", b)),
        })
        .collect()
    }
}

/// A provider's raw ability to carry image bytes over its transport.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ImageCap {
    /// No byte path at all (Slack incoming-webhook, generic webhook) — the
    /// channel is text/link-only no matter what mode is set.
    None,
    /// Exactly one image per message (Pushover attachment, ntfy body file).
    Single,
    /// Two or more images per message (Discord multipart, Telegram media group).
    Multi,
}

/// Which stored image a planned attachment slot refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ImgSource {
    Vehicle,
    Plate,
}

/// The image capability of a channel `kind`. Kept in lock-step with the admin
/// console's `NOTIF_ATTACHES_SNAP`/mode-gating map (`admin.html`).
pub(crate) fn provider_image_capability(kind: &str) -> ImageCap {
    match kind {
        "discord" | "telegram" => ImageCap::Multi,
        "pushover" | "ntfy" => ImageCap::Single,
        // slack: incoming webhooks have no byte upload path, and a LAN image_url
        // is unreachable by Slack's servers. webhook: JSON contract by design.
        _ => ImageCap::None,
    }
}

/// Resolve `(mode, capability, available images)` into the ordered list of
/// concrete images to attach. Pure and total (no I/O) so the whole matrix is
/// unit-tested without a provider.
///
/// The fallbacks are deliberate:
/// * `plate`/`both` with no plate crop falls back to the vehicle frame (never
///   an error — a watchlist hit should still carry *an* image), and
/// * a single-image provider in `both` mode sends the plate crop (more
///   informative) when available, else the vehicle frame.
pub(crate) fn plan_images(
    mode: SnapshotMode,
    cap: ImageCap,
    have_vehicle: bool,
    have_plate: bool,
) -> Vec<ImgSource> {
    if mode == SnapshotMode::None || cap == ImageCap::None {
        return Vec::new();
    }
    let vehicle = have_vehicle.then_some(ImgSource::Vehicle);
    let plate = have_plate.then_some(ImgSource::Plate);
    match cap {
        ImageCap::None => Vec::new(),
        ImageCap::Single => match mode {
            SnapshotMode::None => Vec::new(),
            SnapshotMode::Vehicle => vehicle.into_iter().collect(),
            // Plate crop preferred; vehicle frame is the fallback.
            SnapshotMode::Plate | SnapshotMode::Both => plate.or(vehicle).into_iter().collect(),
        },
        ImageCap::Multi => match mode {
            SnapshotMode::None => Vec::new(),
            SnapshotMode::Vehicle => vehicle.into_iter().collect(),
            SnapshotMode::Plate => plate.or(vehicle).into_iter().collect(),
            // Both: vehicle first (context), plate second (detail); whichever is
            // present. If only one exists, that one alone.
            SnapshotMode::Both => vehicle.into_iter().chain(plate).collect(),
        },
    }
}

// ─── plate crop (server-side, via ffmpeg) ──────────────────────────────────────

/// The ffmpeg binary path — jellyfin-ffmpeg symlinked by the api runtime image
/// (the same binary `filmstrip.rs` uses for thumbnails). No new dependency: the
/// api already shells out to ffmpeg for image work, and there is no in-process
/// image crate in the tree.
const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";

/// Resolve the ffmpeg binary: the jellyfin-ffmpeg symlink in the runtime image
/// when present, else bare `ffmpeg` on `PATH` (dev boxes, CI). Keeping the
/// fallback means the crop path also works outside the container image.
fn ffmpeg_bin() -> &'static str {
    if std::path::Path::new(FFMPEG_BIN).exists() {
        FFMPEG_BIN
    } else {
        "ffmpeg"
    }
}

/// Margin added around the plate box on every side, as a fraction of the box's
/// own width/height, so the crop carries a little vehicle context and isn't a
/// pixel-tight sliver.
const PLATE_CROP_MARGIN: f64 = 0.4;

/// Wall-clock cap on one crop (a single-frame transcode of an in-memory JPEG is
/// sub-second; the cap only bounds a wedged ffmpeg).
const PLATE_CROP_TIMEOUT_SECS: u64 = 8;

/// Expand a normalized `[x, y, w, h]` plate box (fractions of the full frame,
/// the shape stored in `system_events.meta.plate_bbox`) by [`PLATE_CROP_MARGIN`]
/// and clamp it inside `[0, 1]`. Returns `None` for a degenerate box so the
/// caller falls back to the vehicle frame rather than emitting an empty crop.
pub(crate) fn plate_crop_rect(bbox: [f64; 4], margin: f64) -> Option<[f64; 4]> {
    let [x, y, w, h] = bbox;
    if !(w > 0.0 && h > 0.0) {
        return None;
    }
    let mx = w * margin;
    let my = h * margin;
    let nx = (x - mx).clamp(0.0, 1.0);
    let ny = (y - my).clamp(0.0, 1.0);
    let right = (x + w + mx).clamp(0.0, 1.0);
    let bottom = (y + h + my).clamp(0.0, 1.0);
    let nw = right - nx;
    let nh = bottom - ny;
    (nw > 0.0 && nh > 0.0).then_some([nx, ny, nw, nh])
}

/// Build the ffmpeg args to crop the normalized `rect` out of a JPEG read from
/// stdin (`pipe:0`) and re-encode a single JPEG to stdout (`pipe:1`).
///
/// The crop rectangle is expressed against the input's own `iw`/`ih`, so we
/// never need to know the frame's pixel dimensions. Width/height are additionally
/// `min`-clamped against `iw-x`/`ih-y` (the `\,` escapes the comma so ffmpeg
/// reads it as a function argument, not a filter separator) to defend against a
/// sub-pixel rounding overrun on the right/bottom edge.
pub(crate) fn plate_crop_ffmpeg_args(rect: [f64; 4]) -> Vec<String> {
    let [x, y, w, h] = rect;
    let vf = format!(
        "crop=min(iw*{w:.6}\\,iw-iw*{x:.6}):min(ih*{h:.6}\\,ih-ih*{y:.6}):iw*{x:.6}:ih*{y:.6}"
    );
    vec![
        "-y".to_owned(),
        "-loglevel".to_owned(),
        "error".to_owned(),
        "-i".to_owned(),
        "pipe:0".to_owned(),
        "-frames:v".to_owned(),
        "1".to_owned(),
        "-an".to_owned(),
        "-vf".to_owned(),
        vf,
        "-q:v".to_owned(),
        "3".to_owned(),
        "-f".to_owned(),
        "mjpeg".to_owned(),
        "pipe:1".to_owned(),
    ]
}

/// Produce a tight plate-crop JPEG from an already-fetched vehicle-frame JPEG
/// and a normalized `[x, y, w, h]` plate box.
///
/// Best-effort: any failure (degenerate box, ffmpeg missing/errors, empty or
/// over-cap output) returns `None`, and the caller falls back to the vehicle
/// frame — a watchlist alert is never dropped or errored over a crop miss. No
/// extra network fetch: the vehicle bytes were already retrieved once per event.
pub(crate) async fn crop_plate_jpeg(vehicle_jpeg: &[u8], bbox: [f64; 4]) -> Option<Vec<u8>> {
    let rect = plate_crop_rect(bbox, PLATE_CROP_MARGIN)?;
    let args = plate_crop_ffmpeg_args(rect);

    let mut child = match tokio::process::Command::new(ffmpeg_bin())
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
    {
        Ok(child) => child,
        Err(e) => {
            tracing::debug!(error = %e, "plate crop: spawn ffmpeg failed");
            return None;
        }
    };

    // Feed the JPEG on a separate task so a full stdout pipe can't deadlock the
    // write (classic pipe-buffer deadlock if we wrote stdin then read stdout).
    let mut stdin = child.stdin.take()?;
    let input = vehicle_jpeg.to_vec();
    let writer = tokio::spawn(async move {
        let _ = stdin.write_all(&input).await;
        let _ = stdin.shutdown().await;
    });

    let output = tokio::time::timeout(
        Duration::from_secs(PLATE_CROP_TIMEOUT_SECS),
        child.wait_with_output(),
    )
    .await;
    let _ = writer.await;

    let output = match output {
        Ok(Ok(o)) => o,
        Ok(Err(e)) => {
            tracing::debug!(error = %e, "plate crop: ffmpeg wait failed");
            return None;
        }
        Err(_) => {
            tracing::debug!("plate crop: ffmpeg timed out");
            return None;
        }
    };
    if !output.status.success() {
        tracing::debug!(status = ?output.status.code(), "plate crop: ffmpeg non-zero exit");
        return None;
    }
    if output.stdout.is_empty() || output.stdout.len() > MAX_SNAPSHOT_BYTES {
        tracing::debug!(
            bytes = output.stdout.len(),
            "plate crop: empty or over-cap output"
        );
        return None;
    }
    Some(output.stdout)
}

/// Coerce a JSON scalar to a token string. Objects/arrays/null are skipped
/// (returns `None`) — `meta` is expected to be a flat scalar map, and this keeps
/// a stray nested value from rendering as `[object]` noise in an alert.
fn json_scalar_to_string(v: &serde_json::Value) -> Option<String> {
    match v {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Number(n) => Some(n.to_string()),
        serde_json::Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

/// Dispatch a notification to a single channel.
///
/// Returns `Ok(())` on success (any 2xx from the remote) or `Err` with a
/// descriptive message on any failure so the engine can log `status='failed'`.
///
/// # Errors
///
/// Returns an error when:
/// - the channel `kind` has a missing or invalid `config` field,
/// - the HTTP request cannot be sent (network error, timeout), or
/// - the upstream service returns a non-2xx response.
pub async fn dispatch(
    http: &reqwest::Client,
    ch: &NotificationChannel,
    msg: &ChannelMessage,
) -> anyhow::Result<()> {
    match ch.kind.as_str() {
        "discord" => dispatch_discord(http, ch, msg).await,
        "slack" => dispatch_slack(http, ch, msg).await,
        "pushover" => dispatch_pushover(http, ch, msg).await,
        "telegram" => dispatch_telegram(http, ch, msg).await,
        "ntfy" => dispatch_ntfy(http, ch, msg).await,
        "webhook" => dispatch_webhook(http, ch, msg).await,
        other => bail!("unknown channel kind '{other}'"),
    }
}

// ─── helpers ──────────────────────────────────────────────────────────────────

/// Extract a string field from a channel's `config` jsonb.
fn cfg_str<'a>(config: &'a serde_json::Value, key: &str) -> anyhow::Result<&'a str> {
    config
        .get(key)
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("channel config missing or empty '{key}' field"))
}

/// Assert a response is 2xx; return `Err` with the status otherwise.
async fn assert_ok(resp: reqwest::Response, label: &str) -> anyhow::Result<()> {
    let status = resp.status();
    if status.is_success() {
        return Ok(());
    }
    let body = resp
        .text()
        .await
        .unwrap_or_else(|_| "<unreadable>".to_owned());
    bail!("{label}: HTTP {status}: {body}")
}

// ─── Discord ──────────────────────────────────────────────────────────────────

async fn dispatch_discord(
    http: &reqwest::Client,
    ch: &NotificationChannel,
    msg: &ChannelMessage,
) -> anyhow::Result<()> {
    let webhook_url = cfg_str(&ch.config, "webhook_url").context("discord config")?;
    let text = msg.text();

    // Discord multipart carries multiple files (`file[0]`, `file[1]`), so `both`
    // sends the vehicle frame AND the plate crop.
    let images = msg.images_for(ch);
    if !images.is_empty() {
        let payload = json!({ "content": text }).to_string();
        let part_payload = multipart::Part::text(payload)
            .mime_str("application/json")
            .context("discord: mime payload_json")?;
        let mut form = multipart::Form::new().part("payload_json", part_payload);
        for (i, (name, bytes)) in images.iter().enumerate() {
            let part = multipart::Part::bytes(bytes.to_vec())
                .file_name(*name)
                .mime_str("image/jpeg")
                .context("discord: mime snapshot")?;
            form = form.part(format!("file[{i}]"), part);
        }
        let resp = http
            .post(webhook_url)
            .multipart(form)
            .send()
            .await
            .context("discord: send multipart")?;
        return assert_ok(resp, "discord").await;
    }

    // JSON-only (no image).
    let body = json!({ "content": text });
    let resp = http
        .post(webhook_url)
        .json(&body)
        .send()
        .await
        .context("discord: send json")?;
    assert_ok(resp, "discord").await
}

// ─── Slack ────────────────────────────────────────────────────────────────────

async fn dispatch_slack(
    http: &reqwest::Client,
    ch: &NotificationChannel,
    msg: &ChannelMessage,
) -> anyhow::Result<()> {
    let webhook_url = cfg_str(&ch.config, "webhook_url").context("slack config")?;
    // Incoming webhooks don't support file uploads. Include the web_url in the
    // text for now (v1); a block-kit attachment image_url is a v2 improvement.
    let mut text = msg.text();
    if let Some(url) = &msg.web_url {
        text.push(' ');
        text.push_str(url);
    }
    let body = json!({ "text": text });
    let resp = http
        .post(webhook_url)
        .json(&body)
        .send()
        .await
        .context("slack: send")?;
    assert_ok(resp, "slack").await
}

// ─── Pushover ─────────────────────────────────────────────────────────────────

async fn dispatch_pushover(
    http: &reqwest::Client,
    ch: &NotificationChannel,
    msg: &ChannelMessage,
) -> anyhow::Result<()> {
    let app_token = cfg_str(&ch.config, "app_token").context("pushover config")?;
    let user_key = cfg_str(&ch.config, "user_key").context("pushover config")?;

    let title = msg
        .rendered_title()
        .unwrap_or_else(|| format!("Crumb – {}", msg.label.as_deref().unwrap_or(msg.kind)));
    let message = msg.text();

    // Pushover requires multipart even without an attachment.
    let mut form = multipart::Form::new()
        .text("token", app_token.to_owned())
        .text("user", user_key.to_owned())
        .text("title", title)
        .text("message", message);

    if let Some(url) = &msg.web_url {
        form = form
            .text("url", url.clone())
            .text("url_title", "Open in Crumb");
    }

    // Pushover carries a single `attachment`; `both` therefore resolves to one
    // image (the plate crop, when available — see `plan_images`).
    if let Some((name, bytes)) = msg.images_for(ch).first() {
        let part = multipart::Part::bytes(bytes.to_vec())
            .file_name(*name)
            .mime_str("image/jpeg")
            .context("pushover: mime snapshot")?;
        form = form.part("attachment", part);
    }

    let resp = http
        .post("https://api.pushover.net/1/messages.json")
        .multipart(form)
        .send()
        .await
        .context("pushover: send")?;
    assert_ok(resp, "pushover").await
}

// ─── Telegram ────────────────────────────────────────────────────────────────

async fn dispatch_telegram(
    http: &reqwest::Client,
    ch: &NotificationChannel,
    msg: &ChannelMessage,
) -> anyhow::Result<()> {
    let bot_token = cfg_str(&ch.config, "bot_token").context("telegram config")?;
    let chat_id = cfg_str(&ch.config, "chat_id").context("telegram config")?;
    let caption = msg.text();

    // Telegram: one photo → `sendPhoto`; two → `sendMediaGroup` (so `both` sends
    // the vehicle frame AND the plate crop as an album); none → text below.
    let images = msg.images_for(ch);
    if images.len() == 1 {
        let (name, bytes) = images[0];
        let url = format!("https://api.telegram.org/bot{bot_token}/sendPhoto");
        let part = multipart::Part::bytes(bytes.to_vec())
            .file_name(name)
            .mime_str("image/jpeg")
            .context("telegram: mime snapshot")?;
        let form = multipart::Form::new()
            .text("chat_id", chat_id.to_owned())
            .text("caption", caption)
            .part("photo", part);
        let resp = http
            .post(&url)
            .multipart(form)
            .send()
            .await
            .context("telegram: sendPhoto")?;
        return assert_ok(resp, "telegram").await;
    }
    if images.len() >= 2 {
        // sendMediaGroup: a JSON `media` array referencing each attached file by
        // `attach://<field>`; the caption rides on the first item only.
        let url = format!("https://api.telegram.org/bot{bot_token}/sendMediaGroup");
        let mut form = multipart::Form::new().text("chat_id", chat_id.to_owned());
        let mut media = Vec::with_capacity(images.len());
        for (i, (name, bytes)) in images.iter().enumerate() {
            let mut item = json!({
                "type": "photo",
                "media": format!("attach://{name}"),
            });
            if i == 0 {
                item["caption"] = json!(caption);
            }
            media.push(item);
            let part = multipart::Part::bytes(bytes.to_vec())
                .file_name(*name)
                .mime_str("image/jpeg")
                .context("telegram: mime media")?;
            form = form.part((*name).to_owned(), part);
        }
        form = form.text("media", serde_json::Value::Array(media).to_string());
        let resp = http
            .post(&url)
            .multipart(form)
            .send()
            .await
            .context("telegram: sendMediaGroup")?;
        return assert_ok(resp, "telegram").await;
    }

    // Text-only.
    let url = format!("https://api.telegram.org/bot{bot_token}/sendMessage");
    let mut body = json!({
        "chat_id": chat_id,
        "text": caption,
    });
    if let Some(web_url) = &msg.web_url {
        // Parse mode HTML lets us embed a hyperlink in the message.
        body["text"] = json!(format!(
            "{caption}\n<a href=\"{web_url}\">Open in Crumb</a>"
        ));
        body["parse_mode"] = json!("HTML");
    }
    let resp = http
        .post(&url)
        .json(&body)
        .send()
        .await
        .context("telegram: sendMessage")?;
    assert_ok(resp, "telegram").await
}

// ─── ntfy ─────────────────────────────────────────────────────────────────────

async fn dispatch_ntfy(
    http: &reqwest::Client,
    ch: &NotificationChannel,
    msg: &ChannelMessage,
) -> anyhow::Result<()> {
    let topic_url = cfg_str(&ch.config, "topic_url").context("ntfy config")?;
    let body_text = msg.text();
    // Tags: the kind and optionally the label.
    let tags = match &msg.label {
        Some(lbl) if msg.kind == "detection" => format!("{},{lbl}", msg.kind),
        _ => msg.kind.to_owned(),
    };

    // A custom title template wins; otherwise keep the existing camera-name
    // title. Strip CR/LF: the ntfy title rides in an HTTP header, and a newline
    // from a rendered template would otherwise be rejected as an invalid header
    // value (failing the whole dispatch).
    let title = msg
        .rendered_title()
        .unwrap_or_else(|| format!("Crumb – {}", msg.camera_name))
        .replace(['\r', '\n'], " ");

    // ntfy carries a single attachment by sending the FILE as the request body
    // with a `Filename` header (raw bytes; the topic server is LAN-reachable).
    // When we do that the message text has to move from the body into the
    // `Message` header, which — like `Title` — cannot hold a raw newline, so we
    // flatten CR/LF to spaces (a minor, documented limitation of the image
    // path). `both` resolves to one image (plate preferred).
    let image = msg.images_for(ch).into_iter().next();

    let mut req = http
        .post(topic_url)
        .header("Title", title)
        .header("Tags", tags);
    if let Some(url) = &msg.web_url {
        req = req.header("Click", url.as_str());
    }
    let req = match image {
        Some((name, bytes)) => req
            .header("Filename", name)
            .header("Message", body_text.replace(['\r', '\n'], " "))
            .body(bytes.to_vec()),
        None => req.body(body_text),
    };

    let resp = req.send().await.context("ntfy: send")?;
    assert_ok(resp, "ntfy").await
}

// ─── Generic webhook ─────────────────────────────────────────────────────────

async fn dispatch_webhook(
    http: &reqwest::Client,
    ch: &NotificationChannel,
    msg: &ChannelMessage,
) -> anyhow::Result<()> {
    let url = cfg_str(&ch.config, "url").context("webhook config")?;
    // camera_id is not in ChannelMessage (by design — it's resolved by the engine
    // before calling dispatch). We include the camera name only here.
    //
    // The generic webhook is a JSON contract: it never carries raw image bytes.
    // We do surface the channel's `snapshot_mode` so a consumer can decide
    // whether to go fetch an image itself (via `web_url` / the media API).
    let body = json!({
        "camera":        msg.camera_name,
        "kind":          msg.kind,
        "label":         msg.label,
        "ts":            msg.ts,
        "web_url":       msg.web_url,
        "snapshot_mode": ch.snapshot_mode.as_str(),
    });
    let resp = http
        .post(url)
        .json(&body)
        .send()
        .await
        .context("webhook: send")?;
    assert_ok(resp, "webhook").await
}

// ─── Secret masking ──────────────────────────────────────────────────────────

/// The config keys that carry secrets for each channel kind.
///
/// Any string-valued key in this list is replaced with `"***"` before the
/// `config` object is returned to the client via GET.
const SECRET_KEYS: &[&str] = &[
    "webhook_url", // discord / slack
    "app_token",   // pushover
    "user_key",    // pushover
    "bot_token",   // telegram
    "topic_url",   // ntfy — contains the topic URL which may carry a token
    "url",         // generic webhook
];

/// Return a copy of `config` with all known secret string fields replaced by
/// `"***"`.  Non-secret fields (e.g. `"chat_id"`) are left unchanged.
///
/// Callers must apply this before serialising a [`NotificationChannel`] into an
/// API response.
pub fn mask_channel_config(config: &serde_json::Value) -> serde_json::Value {
    let Some(obj) = config.as_object() else {
        return config.clone();
    };
    let mut out = obj.clone();
    for key in SECRET_KEYS {
        if let Some(v) = out.get_mut(*key) {
            if v.is_string() {
                *v = json!("***");
            }
        }
    }
    serde_json::Value::Object(out)
}

/// Fetch a live JPEG snapshot from go2rtc for `camera_id`.
///
/// Used by the engine before dispatching channel notifications that want a
/// snapshot.  Returns `None` on any error so the caller can degrade gracefully
/// (send the notification without an image) rather than silently dropping it.
///
/// Internally replicates the go2rtc frame-fetch logic from `cameras.rs` without
/// the HTTP response wrapper (we want raw bytes here).
///
/// `go2rtc_user` / `go2rtc_pass` (P0-GO2RTC lighter lockdown): Basic-auth
/// credentials for Crumb's OWN go2rtc REST API (required now that go2rtc's API
/// auth applies to this cross-Docker-bridge-network call). Sent ONLY when the
/// camera is Crumb-owned (`served_by != "frigate"`) — a Frigate-served camera's
/// external go2rtc is a separate BYO instance with its own credentials.
pub async fn fetch_snapshot(
    http: &reqwest::Client,
    camera_id: Uuid,
    crumb_go2rtc_api: &str,
    frigate_go2rtc_api: &str,
    pool: &deadpool_postgres::Pool,
    go2rtc_user: &str,
    go2rtc_pass: &str,
) -> Option<Vec<u8>> {
    // Resolve go2rtc_name and served_by from DB.
    let (go2rtc_name, served_by) =
        match crumb_common::db::get_camera_go2rtc_info(pool, camera_id).await {
            Ok(Some(info)) => info,
            Ok(None) => {
                tracing::debug!(%camera_id, "snapshot: camera not found in DB");
                return None;
            }
            Err(e) => {
                tracing::debug!(error = %e, "snapshot: DB lookup failed");
                return None;
            }
        };

    let is_frigate = served_by == "frigate";
    let api_base = if is_frigate {
        frigate_go2rtc_api.trim_end_matches('/')
    } else {
        crumb_go2rtc_api.trim_end_matches('/')
    };
    let upstream = format!("{api_base}/api/frame.jpeg?src={go2rtc_name}");

    // One attempt only — we don't retry here (the engine is fire-and-forget;
    // a cold camera just sends without a snapshot).
    let mut req = http.get(&upstream);
    if !is_frigate {
        req = req.basic_auth(go2rtc_user, Some(go2rtc_pass));
    }
    match req.send().await {
        Ok(resp) if resp.status().is_success() => {
            match read_body_capped(resp, MAX_SNAPSHOT_BYTES).await {
                Ok(b) => {
                    tracing::debug!(%camera_id, bytes = b.len(), "snapshot fetched");
                    Some(b)
                }
                Err(e) => {
                    tracing::debug!(error = %e, "snapshot: body read failed (or over cap)");
                    None
                }
            }
        }
        Ok(resp) => {
            tracing::debug!(status = %resp.status(), "snapshot: non-2xx from go2rtc");
            None
        }
        Err(e) => {
            tracing::debug!(error = %e, "snapshot: request failed");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        crop_plate_jpeg, ffmpeg_bin, plan_images, plate_crop_ffmpeg_args, plate_crop_rect,
        provider_image_capability, ImageCap, ImgSource,
    };
    use crumb_common::db::SnapshotMode;

    // ── provider capability map (must match admin.html NOTIF_IMG_CAP) ──────────

    #[test]
    fn provider_capabilities_are_honest() {
        assert_eq!(provider_image_capability("discord"), ImageCap::Multi);
        assert_eq!(provider_image_capability("telegram"), ImageCap::Multi);
        assert_eq!(provider_image_capability("pushover"), ImageCap::Single);
        assert_eq!(provider_image_capability("ntfy"), ImageCap::Single);
        // No byte path over these transports — must stay text/link-only.
        assert_eq!(provider_image_capability("slack"), ImageCap::None);
        assert_eq!(provider_image_capability("webhook"), ImageCap::None);
        assert_eq!(provider_image_capability("unknown"), ImageCap::None);
    }

    // ── mode → image plan matrix ───────────────────────────────────────────────

    #[test]
    fn plan_none_mode_never_attaches() {
        for cap in [ImageCap::None, ImageCap::Single, ImageCap::Multi] {
            assert!(plan_images(SnapshotMode::None, cap, true, true).is_empty());
        }
    }

    #[test]
    fn plan_no_byte_provider_never_attaches() {
        for mode in [
            SnapshotMode::Plate,
            SnapshotMode::Vehicle,
            SnapshotMode::Both,
        ] {
            assert!(plan_images(mode, ImageCap::None, true, true).is_empty());
        }
    }

    #[test]
    fn plan_single_provider_picks_one() {
        // vehicle → the frame.
        assert_eq!(
            plan_images(SnapshotMode::Vehicle, ImageCap::Single, true, true),
            vec![ImgSource::Vehicle]
        );
        // plate → the crop when present.
        assert_eq!(
            plan_images(SnapshotMode::Plate, ImageCap::Single, true, true),
            vec![ImgSource::Plate]
        );
        // both on a single-image provider → the plate crop (more informative).
        assert_eq!(
            plan_images(SnapshotMode::Both, ImageCap::Single, true, true),
            vec![ImgSource::Plate]
        );
        // plate with no crop → falls back to the vehicle frame (never empty).
        assert_eq!(
            plan_images(SnapshotMode::Plate, ImageCap::Single, true, false),
            vec![ImgSource::Vehicle]
        );
    }

    #[test]
    fn plan_multi_provider_both_sends_two() {
        assert_eq!(
            plan_images(SnapshotMode::Both, ImageCap::Multi, true, true),
            vec![ImgSource::Vehicle, ImgSource::Plate]
        );
        // both with only the frame available → just the frame.
        assert_eq!(
            plan_images(SnapshotMode::Both, ImageCap::Multi, true, false),
            vec![ImgSource::Vehicle]
        );
        // both with only the crop available → just the crop.
        assert_eq!(
            plan_images(SnapshotMode::Both, ImageCap::Multi, false, true),
            vec![ImgSource::Plate]
        );
        // plate → crop; vehicle → frame.
        assert_eq!(
            plan_images(SnapshotMode::Plate, ImageCap::Multi, true, true),
            vec![ImgSource::Plate]
        );
        assert_eq!(
            plan_images(SnapshotMode::Vehicle, ImageCap::Multi, true, true),
            vec![ImgSource::Vehicle]
        );
    }

    #[test]
    fn plan_is_empty_when_no_images_available() {
        assert!(plan_images(SnapshotMode::Both, ImageCap::Multi, false, false).is_empty());
        assert!(plan_images(SnapshotMode::Vehicle, ImageCap::Single, false, false).is_empty());
    }

    // ── crop geometry ──────────────────────────────────────────────────────────

    #[test]
    fn crop_rect_expands_and_clamps() {
        // Centered small box; a 0.4 margin (of the box size) grows each side.
        let r = plate_crop_rect([0.40, 0.40, 0.20, 0.20], 0.4).expect("rect");
        // mx = my = 0.08 → x=0.32, y=0.32, w=h=0.36.
        assert!((r[0] - 0.32).abs() < 1e-9);
        assert!((r[1] - 0.32).abs() < 1e-9);
        assert!((r[2] - 0.36).abs() < 1e-9);
        assert!((r[3] - 0.36).abs() < 1e-9);
        // Always inside the frame.
        assert!(r[0] + r[2] <= 1.0 + 1e-9);
        assert!(r[1] + r[3] <= 1.0 + 1e-9);
    }

    #[test]
    fn crop_rect_clamps_to_frame_edges() {
        // Box hard against the top-left with a big margin must not go negative.
        let r = plate_crop_rect([0.0, 0.0, 0.5, 0.5], 1.0).expect("rect");
        assert!(r[0].abs() < 1e-9);
        assert!(r[1].abs() < 1e-9);
        assert!(r[0] + r[2] <= 1.0 + 1e-9);
        assert!(r[1] + r[3] <= 1.0 + 1e-9);
    }

    #[test]
    fn crop_rect_rejects_degenerate_box() {
        assert!(plate_crop_rect([0.5, 0.5, 0.0, 0.2], 0.4).is_none());
        assert!(plate_crop_rect([0.5, 0.5, 0.2, 0.0], 0.4).is_none());
    }

    #[test]
    fn crop_ffmpeg_args_build_expected_filter() {
        let args = plate_crop_ffmpeg_args([0.32, 0.32, 0.36, 0.36]);
        // stdin/stdout piping + forced mjpeg muxer.
        assert!(args.contains(&"pipe:0".to_owned()));
        assert!(args.contains(&"pipe:1".to_owned()));
        assert!(args.windows(2).any(|w| w == ["-f", "mjpeg"]));
        // The crop filter expresses the rect against iw/ih (no pixel dims needed)
        // and min-clamps width/height (escaped comma) against the right/bottom.
        let vf = args
            .iter()
            .position(|a| a == "-vf")
            .map(|i| args[i + 1].clone())
            .expect("-vf present");
        assert!(vf.starts_with("crop=min(iw*0.360000\\,iw-iw*0.320000):"));
        assert!(vf.contains("min(ih*0.360000\\,ih-ih*0.320000)"));
        assert!(vf.ends_with(":iw*0.320000:ih*0.320000"));
    }

    // ── end-to-end crop via ffmpeg (skips when no ffmpeg is available) ─────────

    /// Minimal baseline-JPEG SOF dimension reader (no image crate in the tree).
    fn jpeg_dims(data: &[u8]) -> Option<(u16, u16)> {
        let mut i = 2usize; // skip SOI (FFD8)
        while i + 9 < data.len() {
            if data[i] != 0xFF {
                i += 1;
                continue;
            }
            let marker = data[i + 1];
            // SOF0..SOF15 carry the frame size, except DHT(C4)/JPG(C8)/DAC(CC).
            if (0xC0..=0xCF).contains(&marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            {
                let h = u16::from_be_bytes([data[i + 5], data[i + 6]]);
                let w = u16::from_be_bytes([data[i + 7], data[i + 8]]);
                return Some((w, h));
            }
            let len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
            i += 2 + len;
        }
        None
    }

    /// Generate a solid-color JPEG of `w`x`h` via ffmpeg, or `None` if ffmpeg is
    /// unavailable (so the caller can skip rather than fail the gate).
    fn make_test_jpeg(w: u32, h: u32) -> Option<Vec<u8>> {
        let out = std::process::Command::new(ffmpeg_bin())
            .args([
                "-y",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                &format!("color=c=red:s={w}x{h}"),
                "-frames:v",
                "1",
                "-f",
                "mjpeg",
                "pipe:1",
            ])
            .output()
            .ok()?;
        (out.status.success() && !out.stdout.is_empty()).then_some(out.stdout)
    }

    #[tokio::test]
    async fn crop_produces_a_smaller_valid_jpeg_of_expected_size() {
        let Some(src) = make_test_jpeg(200, 100) else {
            eprintln!("skipping crop_produces_...: ffmpeg not available");
            return;
        };
        assert_eq!(jpeg_dims(&src), Some((200, 100)), "synthetic source dims");

        let bbox = [0.40, 0.40, 0.20, 0.20];
        let rect = plate_crop_rect(bbox, 0.4).expect("rect");
        let cropped = crop_plate_jpeg(&src, bbox)
            .await
            .expect("crop should succeed with ffmpeg present");

        let (cw, ch) = jpeg_dims(&cropped).expect("cropped is a valid JPEG");
        // Expected pixel size = round(frame * normalized crop), within ffmpeg's
        // sub-pixel rounding of ±2px.
        let want_w = (200.0 * rect[2]).round() as i32;
        let want_h = (100.0 * rect[3]).round() as i32;
        assert!(
            (i32::from(cw) - want_w).abs() <= 2,
            "cropped width {cw} not near expected {want_w}"
        );
        assert!(
            (i32::from(ch) - want_h).abs() <= 2,
            "cropped height {ch} not near expected {want_h}"
        );
        // A crop is strictly smaller than the full frame.
        assert!(cw < 200 && ch < 100);
    }
}
