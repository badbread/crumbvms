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
        let msg = first_line(&stderr);
        return Err(if msg.is_empty() {
            "Could not open the stream.".to_owned()
        } else {
            msg
        });
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
        assert!(is_supported_scheme("rtsp://10.0.0.1/x"));
        assert!(is_supported_scheme("RTSP://10.0.0.1/x"));
        assert!(is_supported_scheme("rtsps://10.0.0.1/x"));
        assert!(is_supported_scheme("http://10.0.0.1/x"));
        assert!(is_supported_scheme("https://10.0.0.1/x"));
        assert!(!is_supported_scheme("file:///etc/passwd"));
        assert!(!is_supported_scheme("ftp://10.0.0.1/x"));
        assert!(!is_supported_scheme(""));
    }

    #[test]
    fn rtsp_uses_dash_timeout_not_rw_timeout() {
        let opts = input_opts("rtsp://10.0.0.1/x", "5000000");
        assert_eq!(opts, vec!["-rtsp_transport", "tcp", "-timeout", "5000000"]);
    }

    #[test]
    fn http_uses_rw_timeout() {
        let opts = input_opts("http://10.0.0.1/x", "5000000");
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
}
