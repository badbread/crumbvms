// SPDX-License-Identifier: AGPL-3.0-or-later

//! Third-party notification channel dispatch.
//!
//! [`dispatch`] is the single entry-point: given a [`NotificationChannel`] row and
//! a [`ChannelMessage`], it formats and POSTs the outbound HTTP request to the
//! appropriate service.
//!
//! # Supported kinds
//!
//! | `kind`    | Delivery                                                       | Snapshot              |
//! |-----------|----------------------------------------------------------------|-----------------------|
//! | `discord` | POST webhook `payload_json` + multipart attachment             | upload (multipart)    |
//! | `slack`   | POST incoming-webhook JSON `{text}`; link in text              | link-only (v1)        |
//! | `pushover`| POST `api.pushover.net` multipart; `attachment` field          | upload (multipart)    |
//! | `telegram`| POST `sendPhoto` multipart OR `sendMessage` JSON               | upload (multipart)    |
//! | `ntfy`    | POST topic URL with body + headers; snapshot link when present | link-only (v1)        |
//! | `webhook` | POST JSON body `{camera, kind, label, ts, web_url}`            | none (URL only)       |
//!
//! Returns `Err` on any non-2xx response or network failure so the engine can log
//! `status='failed'`.  The caller is responsible for sending the notification
//! WITHOUT an image when the snapshot fetch fails (never drop the alert).

use anyhow::{anyhow, bail, Context as _};
use chrono::{DateTime, Utc};
use reqwest::multipart;
use serde_json::json;
use uuid::Uuid;

use crumb_common::db::NotificationChannel;

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
    /// Live camera JPEG snapshot bytes, when available.
    pub snapshot: Option<Vec<u8>>,
    /// `kind == "system"` only: the free-text detail string from
    /// `system_events.detail` (e.g. "camera X has written no new segment for
    /// 130s"), appended to the message body.
    pub detail: Option<String>,
}

impl ChannelMessage {
    /// Human-readable one-liner suitable for all channel types.
    pub fn text(&self) -> String {
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

    if ch.include_snapshot {
        if let Some(bytes) = &msg.snapshot {
            // Multipart: payload_json + snapshot attachment.
            let payload = json!({ "content": text }).to_string();
            let part_payload = multipart::Part::text(payload)
                .mime_str("application/json")
                .context("discord: mime payload_json")?;
            let part_file = multipart::Part::bytes(bytes.clone())
                .file_name("snapshot.jpg")
                .mime_str("image/jpeg")
                .context("discord: mime snapshot")?;
            let form = multipart::Form::new()
                .part("payload_json", part_payload)
                .part("file[0]", part_file);
            let resp = http
                .post(webhook_url)
                .multipart(form)
                .send()
                .await
                .context("discord: send multipart")?;
            return assert_ok(resp, "discord").await;
        }
    }

    // JSON-only (no snapshot).
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

    let title = format!("Crumb – {}", msg.label.as_deref().unwrap_or(msg.kind));
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

    if ch.include_snapshot {
        if let Some(bytes) = &msg.snapshot {
            let part = multipart::Part::bytes(bytes.clone())
                .file_name("snapshot.jpg")
                .mime_str("image/jpeg")
                .context("pushover: mime snapshot")?;
            form = form.part("attachment", part);
        }
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

    if ch.include_snapshot {
        if let Some(bytes) = &msg.snapshot {
            let url = format!("https://api.telegram.org/bot{bot_token}/sendPhoto");
            let part = multipart::Part::bytes(bytes.clone())
                .file_name("snapshot.jpg")
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

    let mut req = http
        .post(topic_url)
        .header("Title", format!("Crumb – {}", msg.camera_name))
        .header("Tags", tags)
        .body(body_text);

    if let Some(url) = &msg.web_url {
        req = req.header("Click", url.as_str());
    }

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
    let body = json!({
        "camera":   msg.camera_name,
        "kind":     msg.kind,
        "label":    msg.label,
        "ts":       msg.ts,
        "web_url":  msg.web_url,
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
