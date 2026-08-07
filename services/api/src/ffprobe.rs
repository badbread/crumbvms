// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shared `ffprobe`-based video-stream probing.
//!
//! Extracted from `stream_test.rs` so both the admin console's **Test stream**
//! button (`stream_test.rs`) and the network-discovery brand-hint prober
//! (`discover.rs`'s `POST /config/discover/probe`) shell out to `ffprobe` the
//! SAME way — same binary, same RTSP-vs-generic timeout-option quirk, same
//! stdout/stderr handling — instead of maintaining two copies that can drift.
//!
//! Callers needing raw stats use [`probe_video`]; `stream_test.rs` additionally
//! renders the friendlier [`crate::stream_test`]-local response shape on top.

use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use tokio::process::Command;

/// Symlinked into PATH by the API Dockerfile (jellyfin-ffmpeg).
pub const FFPROBE_BIN: &str = "/usr/local/bin/ffprobe";

/// Only stream protocols expected for a camera — blocks `file://` and friends so an
/// admin-triggered probe can't be repurposed into a local-file read. Scheme match is
/// case-insensitive and char-boundary safe.
pub fn is_supported_scheme(url: &str) -> bool {
    let u = url.trim_start();
    ["rtsp://", "rtsps://", "http://", "https://"]
        .iter()
        .any(|p| u.get(..p.len()).is_some_and(|s| s.eq_ignore_ascii_case(p)))
}

/// Input options applied before the input: TCP for RTSP + a socket timeout.
///
/// RTSP and the generic AVIO layer name the socket-timeout option DIFFERENTLY,
/// and getting it wrong aborts the ffmpeg/ffprobe command at parse time. In
/// ffmpeg 7 / jellyfin-ffmpeg7 the RTSP demuxer uses `-timeout` (microseconds);
/// passing `-rw_timeout` there is rejected with "Option `rw_timeout` not
/// found", which silently killed every RTSP probe (the "test preview is a
/// black box" bug). (`-stimeout` was removed in ffmpeg 7.) `-rw_timeout` is
/// still the correct option for the http(s)/tcp protocol layer, so keep it
/// for those.
pub(crate) fn input_opts(url: &str, rw_timeout_us: &str) -> Vec<String> {
    let mut v = Vec::new();
    if url.starts_with("rtsp") {
        v.push("-rtsp_transport".to_owned());
        v.push("tcp".to_owned());
        v.push("-timeout".to_owned());
    } else {
        v.push("-rw_timeout".to_owned());
    }
    v.push(rw_timeout_us.to_owned());
    v
}

/// Headline stream stats pulled from ffprobe's `-print_format json` output.
#[derive(Debug, Clone, Serialize, Default)]
pub struct ProbeStats {
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub codec: Option<String>,
    pub fps: Option<f64>,
    pub bitrate_kbps: Option<i64>,
    pub audio_codec: Option<String>,
}

/// Probe `url` with `ffprobe` under a hard `timeout`, returning parsed stream
/// stats on success or a short human-readable message on failure (never a raw
/// ffmpeg stack trace — callers may surface this directly to the admin UI).
///
/// `timeout` bounds BOTH the ffprobe socket read/write timeout (best-effort;
/// clamped to whole seconds for the `-rw_timeout`/`-timeout` microsecond args)
/// and the hard process-kill deadline, so a dead/black-holed URL always fails
/// within `timeout` rather than hanging a worker.
///
/// Credentials embedded in `url` (`rtsp://user:pass@host/...`) are never
/// logged — only the caller-supplied URL is passed as a process argument, and
/// stderr is only surfaced as a short first-line message.
pub async fn probe_video(url: &str, timeout: Duration) -> Result<ProbeStats, String> {
    if !is_supported_scheme(url) {
        return Err("Unsupported URL — use rtsp:// or http(s)://.".to_owned());
    }

    let rw_timeout_us = (timeout.as_micros().max(1)).to_string();

    let mut args = vec![
        "-hide_banner".to_owned(),
        "-loglevel".to_owned(),
        "error".to_owned(),
        "-print_format".to_owned(),
        "json".to_owned(),
        "-show_streams".to_owned(),
        "-show_format".to_owned(),
    ];
    args.extend(input_opts(url, &rw_timeout_us));
    args.push(url.to_owned());

    let (ok, stdout, stderr) = run_capture(FFPROBE_BIN, &args, timeout).await?;
    if !ok {
        return Err(friendly_error(url, &first_line(&stderr)));
    }

    let stats = parse_probe(&stdout)?;
    Ok(stats)
}

/// Spawn `bin args`, capture stdout/stderr, enforce `timeout`.
///
/// `kill_on_drop(true)` means a timeout (which drops the wait future) also
/// reaps the child, so we never leak a hung ffprobe/ffmpeg. Returns
/// `(success, stdout, stderr)`.
pub async fn run_capture(
    bin: &str,
    args: &[String],
    timeout: Duration,
) -> Result<(bool, Vec<u8>, String), String> {
    let child = Command::new(bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("failed to start {bin}: {e}"))?;

    match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(out)) => Ok((
            out.status.success(),
            out.stdout,
            String::from_utf8_lossy(&out.stderr).into_owned(),
        )),
        Ok(Err(e)) => Err(format!("{bin} failed: {e}")),
        Err(_) => Err(format!(
            "Timed out after {}s — the stream didn't respond.",
            timeout.as_secs()
        )),
    }
}

/// First non-blank line of (multi-line) ffmpeg/ffprobe stderr, for a tidy message.
pub fn first_line(s: &str) -> String {
    s.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("")
        .to_owned()
}

// ─── operator-facing error mapping (issue #517) ───────────────────────────────
//
// ffmpeg's stderr was the camera-error UI: an operator who typed the wrong
// password got `[rtsp @ 0x5d901a899040] method DESCRIBE failed: 401Unauthorized`
// (pointer address, missing space, no idea what to do). The handful of failures
// that actually occur on a first run are mapped to a sentence that names the fix;
// anything unrecognised still falls through to the cleaned-up raw line, so a
// novel ffmpeg error is never swallowed.

/// Strip ffmpeg's `[proto @ 0xADDR] ` prefix, redact any `user:pass@` userinfo,
/// and put the missing space back into `401Unauthorized` / `404Not Found`.
fn clean_detail(raw: &str) -> String {
    let mut s = raw.trim();
    // `[rtsp @ 0x59d67f90d5c0] method DESCRIBE failed: …` → `method DESCRIBE …`
    if s.starts_with('[') {
        if let Some((head, tail)) = s.split_once("] ") {
            if head.contains(" @ ") {
                s = tail.trim();
            }
        }
    }
    fix_status_spacing(&redact_userinfo(s))
}

/// Replace `scheme://user:pass@host` with `scheme://…@host` so a credentialed
/// URL echoed back by ffmpeg can't put the password in the console (or a log).
fn redact_userinfo(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find("://") {
        let (before, after) = rest.split_at(i + 3);
        out.push_str(before);
        // Userinfo, if any, ends at the first '@' before the authority ends.
        let auth_end = after.find(['/', '?', ' ', ')']).unwrap_or(after.len());
        if let Some(at) = after[..auth_end].find('@') {
            out.push_str("…@");
            rest = &after[at + 1..];
        } else {
            out.push_str(&after[..auth_end]);
            rest = &after[auth_end..];
        }
    }
    out.push_str(rest);
    out
}

/// `failed: 401Unauthorized` → `failed: 401 Unauthorized`. RTSP status lines
/// come back from ffmpeg with the space eaten, so they don't even read as
/// English. Scoped to text right after `failed: ` so nothing else is touched.
fn fix_status_spacing(s: &str) -> String {
    let Some(i) = s.find("failed: ") else {
        return s.to_owned();
    };
    let (head, tail) = s.split_at(i + "failed: ".len());
    let b = tail.as_bytes();
    if b.len() > 3 && b[..3].iter().all(u8::is_ascii_digit) && b[3].is_ascii_alphabetic() {
        format!("{head}{} {}", &tail[..3], &tail[3..])
    } else {
        s.to_owned()
    }
}

/// `host` and optional `port` of a stream URL, userinfo stripped.
fn url_host_port(url: &str) -> (String, Option<String>) {
    let s = url.trim();
    let s = s.split_once("://").map_or(s, |(_, rest)| rest);
    let s = s.split(['/', '?', '#']).next().unwrap_or(s);
    let s = s.rsplit_once('@').map_or(s, |(_, h)| h);
    if let Some(rest) = s.strip_prefix('[') {
        if let Some((h, tail)) = rest.split_once(']') {
            return (
                format!("[{h}]"),
                tail.strip_prefix(':')
                    .filter(|p| !p.is_empty())
                    .map(str::to_owned),
            );
        }
    }
    match s.rsplit_once(':') {
        Some((h, p)) if !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()) => {
            (h.to_owned(), Some(p.to_owned()))
        }
        _ => (s.to_owned(), None),
    }
}

/// The hostname out of `Failed to resolve hostname front-door.local: Name or …`.
fn unresolved_hostname(detail: &str) -> Option<String> {
    let rest = detail.split_once("resolve hostname ")?.1;
    let name = rest.split([':', ' ']).next()?.trim();
    (!name.is_empty()).then(|| name.to_owned())
}

/// Turn one line of ffmpeg/ffprobe stderr into a message a novice can act on.
///
/// The recognised failure keeps the cleaned raw line as secondary detail in
/// parentheses (the raw text is what a forum search needs); an unrecognised
/// failure returns the cleaned raw line alone, exactly as before.
#[must_use]
pub fn friendly_error(url: &str, raw: &str) -> String {
    let detail = clean_detail(raw);
    let low = detail.to_ascii_lowercase();
    let is_http = {
        let u = url.trim_start().to_ascii_lowercase();
        u.starts_with("http://") || u.starts_with("https://")
    };

    let head = if low.contains("401 unauthorized") || low.contains("failed: 401") {
        Some(
            "The camera rejected the username and password. Check the credentials, and \
             note that some cameras need a separate stream account."
                .to_owned(),
        )
    } else if low.contains("404 not found") || low.contains("failed: 404") {
        Some(
            "Connected to the camera, but there is no stream at that path. Check the \
             stream path (try Discover), or the channel / sub-stream number."
                .to_owned(),
        )
    } else if is_http && low.contains("invalid data found when processing input") {
        Some(
            "That address answered, but it is not a video stream. A camera web-page URL \
             will not work here, you need the RTSP address (usually rtsp://…:554/…)."
                .to_owned(),
        )
    } else if let Some(name) = unresolved_hostname(&detail) {
        Some(format!(
            "Could not find a host called '{name}' on your network. \
             Try the camera's IP address instead."
        ))
    } else if low.contains("connection refused") {
        // Prefer the endpoint ffmpeg actually dialled (it appears in the line as
        // `tcp://host:port?…`), falling back to the URL the operator typed.
        let hp = detail
            .split_once("tcp://")
            .and_then(|(_, r)| r.split(['?', ' ']).next())
            .map(str::to_owned)
            .unwrap_or_default();
        let (host, port) = if hp.is_empty() {
            url_host_port(url)
        } else {
            url_host_port(&format!("tcp://{hp}"))
        };
        Some(match port {
            Some(p) => format!(
                "Nothing is listening on port {p} at {host}. \
                 Check the port (RTSP is usually 554)."
            ),
            None => format!(
                "Nothing at {host} accepted the connection. \
                 Check the address and port (RTSP is usually 554)."
            ),
        })
    } else {
        None
    };

    match head {
        Some(h) if detail.is_empty() => h,
        Some(h) => format!("{h} ({detail})"),
        None if detail.is_empty() => "Could not open the stream.".to_owned(),
        None => detail,
    }
}

/// Parse ffprobe `avg_frame_rate` (e.g. `"30000/1001"`) into fps.
fn parse_fps(s: &str) -> Option<f64> {
    let (n, d) = s.split_once('/')?;
    let n: f64 = n.parse().ok()?;
    let d: f64 = d.parse().ok()?;
    if d == 0.0 {
        None
    } else {
        Some(n / d)
    }
}

/// Pull the headline stats out of ffprobe's `-print_format json` output.
///
/// Returns `Err` when the JSON can't be parsed at all, or when no video stream
/// (and no codec) was found — i.e. the connection succeeded but there's
/// nothing to show.
fn parse_probe(stdout: &[u8]) -> Result<ProbeStats, String> {
    let v: serde_json::Value =
        serde_json::from_slice(stdout).map_err(|_| "Could not parse stream info.".to_owned())?;

    let streams = v.get("streams").and_then(|s| s.as_array());
    let by_type = |t: &str| {
        streams.and_then(|s| {
            s.iter()
                .find(|st| st.get("codec_type").and_then(serde_json::Value::as_str) == Some(t))
        })
    };
    let video = by_type("video");
    let audio = by_type("audio");

    let width = video
        .and_then(|s| s.get("width"))
        .and_then(serde_json::Value::as_i64);
    let height = video
        .and_then(|s| s.get("height"))
        .and_then(serde_json::Value::as_i64);
    let codec = video
        .and_then(|s| s.get("codec_name"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);
    let fps = video
        .and_then(|s| s.get("avg_frame_rate"))
        .and_then(serde_json::Value::as_str)
        .and_then(parse_fps)
        .filter(|f| *f > 0.0);
    // ffprobe reports bit_rate as a STRING; prefer the video stream, fall back to
    // the container format's overall bitrate.
    let bitrate_kbps = video
        .and_then(|s| s.get("bit_rate"))
        .and_then(serde_json::Value::as_str)
        .or_else(|| {
            v.get("format")
                .and_then(|f| f.get("bit_rate"))
                .and_then(serde_json::Value::as_str)
        })
        .and_then(|b| b.parse::<i64>().ok())
        .map(|bps| bps / 1000);
    let audio_codec = audio
        .and_then(|s| s.get("codec_name"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);

    if width.is_none() && codec.is_none() {
        return Err("Connected, but no video stream was found.".to_owned());
    }

    Ok(ProbeStats {
        width,
        height,
        codec,
        fps,
        bitrate_kbps,
        audio_codec,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_schemes() {
        assert!(is_supported_scheme("rtsp://192.0.2.1/x"));
        assert!(is_supported_scheme("RTSP://192.0.2.1/x"));
        assert!(is_supported_scheme("rtsps://192.0.2.1/x"));
        assert!(is_supported_scheme("http://192.0.2.1/x"));
        assert!(is_supported_scheme("https://192.0.2.1/x"));
        assert!(!is_supported_scheme("file:///etc/passwd"));
        assert!(!is_supported_scheme("ftp://192.0.2.1/x"));
        assert!(!is_supported_scheme(""));
    }

    #[test]
    fn rtsp_uses_dash_timeout_not_rw_timeout() {
        let opts = input_opts("rtsp://192.0.2.1/x", "5000000");
        assert_eq!(opts, vec!["-rtsp_transport", "tcp", "-timeout", "5000000"]);
    }

    #[test]
    fn http_uses_rw_timeout() {
        let opts = input_opts("http://192.0.2.1/x", "5000000");
        assert_eq!(opts, vec!["-rw_timeout", "5000000"]);
    }

    #[test]
    fn parse_probe_missing_video_stream_is_error() {
        let json = br#"{"streams":[{"codec_type":"audio","codec_name":"aac"}],"format":{}}"#;
        assert!(parse_probe(json).is_err());
    }

    #[test]
    fn parse_probe_extracts_video_and_audio() {
        let json = br#"{
            "streams": [
                {"codec_type":"video","codec_name":"h264","width":1920,"height":1080,
                 "avg_frame_rate":"30000/1001","bit_rate":"4000000"},
                {"codec_type":"audio","codec_name":"aac"}
            ],
            "format": {"bit_rate":"4200000"}
        }"#;
        let stats = parse_probe(json).unwrap();
        assert_eq!(stats.width, Some(1920));
        assert_eq!(stats.height, Some(1080));
        assert_eq!(stats.codec.as_deref(), Some("h264"));
        assert_eq!(stats.audio_codec.as_deref(), Some("aac"));
        assert_eq!(stats.bitrate_kbps, Some(4000));
        assert!((stats.fps.unwrap() - 29.97).abs() < 0.01);
    }

    #[test]
    fn parse_probe_garbage_json_is_error() {
        assert!(parse_probe(b"not json").is_err());
    }

    // ── operator-facing error mapping (issue #517) ───────────────────────────

    #[test]
    fn wrong_credentials_talk_about_credentials() {
        let m = friendly_error(
            "rtsp://cam.example:554/live",
            "[rtsp @ 0x5d901a899040] method DESCRIBE failed: 401Unauthorized",
        );
        assert!(
            m.starts_with("The camera rejected the username and password."),
            "{m}"
        );
        // Pointer address gone, status line readable, raw detail kept.
        assert!(!m.contains("0x5d901a899040"), "{m}");
        assert!(
            m.contains("method DESCRIBE failed: 401 Unauthorized"),
            "{m}"
        );
    }

    #[test]
    fn wrong_path_talks_about_the_stream_path() {
        let m = friendly_error(
            "rtsp://cam.example:554/nope",
            "[rtsp @ 0x6317bd34b0c0] method DESCRIBE failed: 404Not Found",
        );
        assert!(m.contains("no stream at that path"), "{m}");
        assert!(m.contains("404 Not Found"), "{m}");
    }

    #[test]
    fn http_web_page_is_not_a_video_stream() {
        let m = friendly_error(
            "http://cam.example/",
            "http://cam.example/: Invalid data found when processing input",
        );
        assert!(m.contains("not a video stream"), "{m}");
        // The same ffmpeg text on an rtsp:// URL is NOT the web-page mistake.
        let r = friendly_error(
            "rtsp://cam.example/live",
            "rtsp://cam.example/live: Invalid data found when processing input",
        );
        assert!(!r.contains("not a video stream"), "{r}");
    }

    #[test]
    fn unresolved_host_names_the_host() {
        let m = friendly_error(
            "rtsp://front-door-camera.local:554/live",
            "[tcp @ 0x5d0dd3cfb0c0] Failed to resolve hostname front-door-camera.local: Name or service not known",
        );
        assert!(m.contains("host called 'front-door-camera.local'"), "{m}");
        assert!(m.contains("IP address instead"), "{m}");
    }

    #[test]
    fn connection_refused_names_the_port_ffmpeg_dialled() {
        let m = friendly_error(
            "rtsp://cam.example:5544/live",
            "[tcp @ 0x5a3a326840c0] Connection to tcp://cam.example:5544?timeout=12000000 failed: Connection refused",
        );
        assert!(m.contains("port 5544 at cam.example"), "{m}");
        assert!(m.contains("usually 554"), "{m}");
    }

    #[test]
    fn unrecognised_stderr_falls_through_to_the_cleaned_line() {
        let m = friendly_error(
            "rtsp://cam.example/live",
            "[rtsp @ 0xdeadbeef] something new",
        );
        assert_eq!(m, "something new");
        assert_eq!(
            friendly_error("rtsp://cam.example/live", ""),
            "Could not open the stream."
        );
    }

    #[test]
    fn credentials_are_never_echoed_back() {
        let m = friendly_error(
            "rtsp://bob:hunter2@cam.example/live",
            "rtsp://bob:hunter2@cam.example/live: Invalid data found when processing input",
        );
        assert!(!m.contains("hunter2"), "{m}");
        assert!(m.contains("…@cam.example"), "{m}");
    }

    #[test]
    fn url_host_port_handles_ipv6_and_missing_port() {
        assert_eq!(
            url_host_port("rtsp://u:p@cam.example:554/live"),
            ("cam.example".to_owned(), Some("554".to_owned()))
        );
        assert_eq!(
            url_host_port("rtsp://cam.example/live"),
            ("cam.example".to_owned(), None)
        );
        assert_eq!(
            url_host_port("rtsp://[2001:db8::1]:554/live"),
            ("[2001:db8::1]".to_owned(), Some("554".to_owned()))
        );
    }
}
