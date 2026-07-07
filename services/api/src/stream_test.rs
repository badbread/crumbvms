// SPDX-License-Identifier: AGPL-3.0-or-later

//! Stream-test endpoints for the admin console's **Test stream** button.
//!
//! Lets an operator validate a camera's RTSP/HTTP stream URL — typically the one
//! they've just typed into the Edit-camera modal, *before* saving:
//!
//! | Method | Path                  | Returns                                   |
//! |--------|-----------------------|-------------------------------------------|
//! | `POST` | `/config/test-stream` | JSON stats (res / codec / fps / bitrate)  |
//! | `POST` | `/config/test-frame`  | one `image/jpeg` frame (snapshot preview) |
//!
//! Both shell out to the bundled `ffprobe` / `ffmpeg` (the same binaries the export
//! pipeline uses) against the URL, each under a hard timeout (`kill_on_drop` cleans
//! up the child if we time out) plus an ffmpeg `-rw_timeout`, so a dead URL fails
//! fast with a clear message instead of hanging a worker.
//!
//! Admin-only — the same capability as configuring camera URLs. The URL is read
//! from the request BODY (never a query string) so credentials in
//! `rtsp://user:pass@host` aren't logged.

use std::process::Stdio;
use std::time::Duration;

use axum::{
    http::header,
    response::{IntoResponse, Response},
    routing::post,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::{
    auth_mw::AdminUser,
    error::ApiError,
    ffprobe::{self, is_supported_scheme},
    state::AppState,
};

/// Symlinked into PATH by the API Dockerfile (jellyfin-ffmpeg).
const FFMPEG_BIN: &str = "/usr/local/bin/ffmpeg";

/// Hard cap per probe/grab so a dead URL can't tie up a worker.
const TEST_TIMEOUT_SECS: u64 = 12;
/// ffmpeg/ffprobe socket open/read timeout (microseconds) — fail fast on a silent
/// or unreachable source rather than blocking the whole [`TEST_TIMEOUT_SECS`].
const RW_TIMEOUT_US: &str = "8000000";

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/test-stream", post(test_stream))
        .route("/test-frame", post(test_frame))
}

#[derive(Deserialize)]
struct TestRequest {
    url: String,
}

/// Stream probe result. Always returned with HTTP 200 (even on failure) so the
/// admin UI can render a friendly error inline; `ok=false` carries `error`.
#[derive(Serialize, Default)]
struct TestStreamResult {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    width: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    height: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fps: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    bitrate_kbps: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    audio_codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

// ─── POST /config/test-stream ──────────────────────────────────────────────────

async fn test_stream(_admin: AdminUser, Json(req): Json<TestRequest>) -> Json<TestStreamResult> {
    let url = req.url.trim().to_owned();
    if url.is_empty() {
        return Json(TestStreamResult {
            error: Some("No URL provided.".to_owned()),
            ..Default::default()
        });
    }

    match ffprobe::probe_video(&url, Duration::from_secs(TEST_TIMEOUT_SECS)).await {
        Err(e) => Json(TestStreamResult {
            error: Some(e),
            ..Default::default()
        }),
        Ok(stats) => Json(TestStreamResult {
            ok: true,
            width: stats.width,
            height: stats.height,
            codec: stats.codec,
            fps: stats.fps,
            bitrate_kbps: stats.bitrate_kbps,
            audio_codec: stats.audio_codec,
            error: None,
        }),
    }
}

// ─── POST /config/test-frame ───────────────────────────────────────────────────

async fn test_frame(_admin: AdminUser, Json(req): Json<TestRequest>) -> Result<Response, ApiError> {
    let url = req.url.trim().to_owned();
    if url.is_empty() {
        return Err(ApiError::BadRequest("No URL provided.".to_owned()));
    }
    if !is_supported_scheme(&url) {
        return Err(ApiError::BadRequest(
            "Unsupported URL — use rtsp:// or http(s)://.".to_owned(),
        ));
    }

    let mut args = vec![
        "-hide_banner".to_owned(),
        "-loglevel".to_owned(),
        "error".to_owned(),
    ];
    args.extend(ffprobe::input_opts(&url, RW_TIMEOUT_US));
    // Decode ONLY keyframes. Without this, ffmpeg grabs the very first decodable
    // frame after connecting mid-GOP, which on most cameras is a black/partial
    // P-frame (no full reference yet) — the "test stream shows a black screen" bug.
    // Skipping to the first I-frame guarantees a complete, real image... almost:
    // cameras using GDR / intra-refresh (seen on some Uniview HEVC streams) spread
    // the "keyframe" refresh across several frames, so the very first one ffmpeg
    // hands back can still be partially/fully black. Grabbing a SECOND keyframe
    // and preferring it (falling back to the first if the second never lands)
    // works around that without regressing the common case.
    args.push("-skip_frame".to_owned());
    args.push("nokey".to_owned());
    args.push("-i".to_owned());
    args.push(url);
    // Two frames, no audio, MJPEG to stdout. `-q:v 3` keeps the preview crisp.
    // Concatenated JPEGs land back-to-back on stdout; `last_complete_jpeg` picks
    // the last fully-received one.
    args.extend([
        "-frames:v".to_owned(),
        "2".to_owned(),
        "-an".to_owned(),
        "-q:v".to_owned(),
        "3".to_owned(),
        "-f".to_owned(),
        "image2pipe".to_owned(),
        "-vcodec".to_owned(),
        "mjpeg".to_owned(),
        "pipe:1".to_owned(),
    ]);

    match run_capture_frame(FFMPEG_BIN, &args).await {
        Ok(FrameCapture { stdout, stderr, .. }) => {
            if let Some(jpeg) = last_complete_jpeg(&stdout) {
                Ok((
                    [
                        (header::CONTENT_TYPE, "image/jpeg"),
                        (header::CACHE_CONTROL, "no-store"),
                    ],
                    jpeg.to_vec(),
                )
                    .into_response())
            } else {
                tracing::debug!(stderr = %stderr, "test-frame: no complete JPEG in ffmpeg output");
                let hint = ffprobe::first_line(&stderr);
                Err(ApiError::BadRequest(if hint.is_empty() {
                    "Connected but no frame arrived — the camera may use a very long \
                     keyframe interval."
                        .to_owned()
                } else {
                    format!(
                        "Connected but no frame arrived — the camera may use a very long \
                         keyframe interval. ({hint})"
                    )
                }))
            }
        }
        Err(e) => Err(ApiError::BadRequest(e)),
    }
}

// ─── helpers ───────────────────────────────────────────────────────────────────
//
// `is_supported_scheme` and `input_opts` are shared with `discover.rs`'s
// brand-hint prober via [`crate::ffprobe`] (see that module for the RTSP vs.
// generic `-timeout`/`-rw_timeout` quirk this guards against). `test_stream`
// delegates entirely to `ffprobe::probe_video`; `test_frame` still shells out
// to `ffmpeg` directly (frame-grab, not ffprobe) so it reuses only the input
// option builder.

/// Result of [`run_capture_frame`]: buffered stdout/stderr plus whether the child
/// actually exited (`true`) or was killed after [`TEST_TIMEOUT_SECS`] (`false`,
/// `stdout`/`stderr` are whatever had been read so far).
struct FrameCapture {
    stdout: Vec<u8>,
    stderr: String,
    // kept for callers/tests that want to distinguish timeout from a clean exit
    #[allow(dead_code)]
    exited: bool,
}

/// Like [`run_capture`], but reads the child's stdout/stderr incrementally as they
/// arrive instead of only via `wait_with_output` after the process exits.
///
/// This matters for the frame grab: with a plain `wait_with_output` + outer
/// `tokio::time::timeout`, a timeout drops the wait future (and — because the
/// `Child` was spawned with `kill_on_drop(true)` — kills the process) but throws
/// away whatever bytes had already been piped to us. A long-GOP camera might have
/// happily delivered one complete JPEG for the first keyframe and be mid-way
/// through the second when the 12s cap hits; we'd rather hand back the frame we
/// already have than a bare timeout error. So here we pump stdout/stderr into
/// buffers on their own tasks and only race `child.wait()` against the timeout —
/// on timeout we kill the child and return whatever had been buffered.
async fn run_capture_frame(bin: &str, args: &[String]) -> Result<FrameCapture, String> {
    use tokio::io::AsyncReadExt;

    let mut child = Command::new(bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("failed to start {bin}: {e}"))?;

    let mut stdout_pipe = child
        .stdout
        .take()
        .ok_or_else(|| format!("{bin}: no stdout pipe"))?;
    let mut stderr_pipe = child
        .stderr
        .take()
        .ok_or_else(|| format!("{bin}: no stderr pipe"))?;

    // Pump both pipes concurrently on their own tasks so neither can back-pressure
    // the other (and so we're still collecting bytes while we wait on the child).
    let stdout_task = tokio::spawn(async move {
        let mut buf = Vec::new();
        let _ = stdout_pipe.read_to_end(&mut buf).await;
        buf
    });
    let stderr_task = tokio::spawn(async move {
        let mut buf = Vec::new();
        let _ = stderr_pipe.read_to_end(&mut buf).await;
        buf
    });

    let wait_result =
        tokio::time::timeout(Duration::from_secs(TEST_TIMEOUT_SECS), child.wait()).await;

    let (exited, timed_out) = match wait_result {
        Ok(Ok(_status)) => (true, false),
        Ok(Err(e)) => return Err(format!("{bin} failed: {e}")),
        Err(_) => {
            // Timed out — kill the child so the pipe-reader tasks see EOF and
            // finish (kill_on_drop would also reap it, but we're not dropping
            // `child` here since we still want its stdout/stderr).
            let _ = child.start_kill();
            let _ = child.wait().await;
            (false, true)
        }
    };

    // The child (or our kill) has produced EOF on both pipes by now, so these
    // joins resolve promptly regardless of which branch above we took.
    let stdout = stdout_task.await.unwrap_or_default();
    let stderr_bytes = stderr_task.await.unwrap_or_default();
    let stderr = String::from_utf8_lossy(&stderr_bytes).into_owned();

    if timed_out && !has_complete_jpeg(&stdout) {
        return Err(format!(
            "Timed out after {TEST_TIMEOUT_SECS}s — the stream didn't respond. \
             The stream may have a long keyframe interval."
        ));
    }

    Ok(FrameCapture {
        stdout,
        stderr,
        exited,
    })
}

/// Quick check for whether `bytes` contains at least one complete JPEG
/// (SOI `FF D8` ... EOI `FF D9`), without allocating — used to decide whether a
/// timeout should still be treated as a (partial) success.
fn has_complete_jpeg(bytes: &[u8]) -> bool {
    last_complete_jpeg(bytes).is_some()
}

/// Find the LAST complete JPEG image in a buffer that may contain several
/// concatenated JPEGs (as produced by ffmpeg's `image2pipe` muxer with
/// `-frames:v N`, N > 1) and/or a truncated trailing one (e.g. the process was
/// killed mid-write).
///
/// A JPEG is delimited by the SOI marker `FF D8` and the EOI marker `FF D9`.
/// Scans for every `FF D8` start marker, and for each candidate finds the next
/// `FF D9` at-or-after it; the LAST such complete `(start, end)` pair wins. A
/// dangling/truncated start with no following `FF D9` is simply skipped in favor
/// of the previous complete one. Returns `None` if no complete JPEG is present.
fn last_complete_jpeg(bytes: &[u8]) -> Option<&[u8]> {
    const SOI: [u8; 2] = [0xFF, 0xD8];
    const EOI: [u8; 2] = [0xFF, 0xD9];

    let mut best: Option<(usize, usize)> = None; // (start, end_exclusive)
    let mut i = 0usize;
    while i + 1 < bytes.len() {
        if bytes[i] == SOI[0] && bytes[i + 1] == SOI[1] {
            let start = i;
            // Look for the matching EOI starting right after the SOI marker.
            if let Some(eoi_rel) = find_marker(&bytes[start + 2..], EOI) {
                let end = start + 2 + eoi_rel + 2; // include the EOI marker bytes
                best = Some((start, end));
                i = end; // continue scanning after this complete JPEG
                continue;
            }
            // No EOI found after this SOI — truncated tail; stop scanning, the
            // best complete JPEG found so far (if any) is the answer.
            break;
        }
        i += 1;
    }

    best.map(|(start, end)| &bytes[start..end])
}

/// Byte-string search for a 2-byte marker; returns the offset of its first byte.
fn find_marker(haystack: &[u8], marker: [u8; 2]) -> Option<usize> {
    haystack
        .windows(2)
        .position(|w| w[0] == marker[0] && w[1] == marker[1])
}

#[cfg(test)]
mod tests {
    use super::last_complete_jpeg;

    /// Builds a minimal-but-valid-looking JPEG: SOI, some payload bytes that
    /// deliberately do NOT contain a stray `FF D9`, then EOI.
    fn fake_jpeg(payload: &[u8]) -> Vec<u8> {
        let mut v = vec![0xFF, 0xD8];
        v.extend_from_slice(payload);
        v.push(0xFF);
        v.push(0xD9);
        v
    }

    #[test]
    fn single_jpeg_returns_itself() {
        let jpeg = fake_jpeg(b"only-frame");
        let got = last_complete_jpeg(&jpeg).expect("expected a complete JPEG");
        assert_eq!(got, jpeg.as_slice());
    }

    #[test]
    fn two_concatenated_jpegs_returns_the_last_one() {
        let first = fake_jpeg(b"first-frame-maybe-black");
        let second = fake_jpeg(b"second-frame-clean");
        let mut buf = Vec::new();
        buf.extend_from_slice(&first);
        buf.extend_from_slice(&second);

        let got = last_complete_jpeg(&buf).expect("expected a complete JPEG");
        assert_eq!(got, second.as_slice());
        assert_ne!(got, first.as_slice());
    }

    #[test]
    fn three_concatenated_jpegs_returns_the_last_one() {
        let frames: Vec<Vec<u8>> = (0..3)
            .map(|i| fake_jpeg(format!("frame-{i}").as_bytes()))
            .collect();
        let mut buf = Vec::new();
        for f in &frames {
            buf.extend_from_slice(f);
        }

        let got = last_complete_jpeg(&buf).expect("expected a complete JPEG");
        assert_eq!(got, frames[2].as_slice());
    }

    #[test]
    fn truncated_tail_falls_back_to_previous_complete_jpeg() {
        // A full first frame followed by a second SOI whose EOI never arrived
        // (e.g. the process was killed mid-write of the second keyframe).
        let first = fake_jpeg(b"complete-frame");
        let mut buf = Vec::new();
        buf.extend_from_slice(&first);
        buf.push(0xFF);
        buf.push(0xD8); // start of a second frame...
        buf.extend_from_slice(b"partial-bytes-no-eoi-marker");
        // deliberately no trailing FF D9

        let got = last_complete_jpeg(&buf).expect("expected the first complete JPEG");
        assert_eq!(got, first.as_slice());
    }

    #[test]
    fn garbage_returns_none() {
        let buf = b"not a jpeg at all, just some ffmpeg stderr noise".to_vec();
        assert!(last_complete_jpeg(&buf).is_none());
    }

    #[test]
    fn empty_buffer_returns_none() {
        assert!(last_complete_jpeg(&[]).is_none());
    }

    #[test]
    fn soi_with_no_eoi_at_all_returns_none() {
        let buf = fake_jpeg(b"x");
        // Strip the trailing EOI to simulate a fully truncated single frame.
        let truncated = &buf[..buf.len() - 2];
        assert!(last_complete_jpeg(truncated).is_none());
    }

    #[test]
    fn eoi_bytes_can_appear_inside_payload_without_confusing_the_scanner() {
        // Payload contains an FF D9-looking byte pair; make sure the scanner still
        // finds the correct (first) EOI it encounters rather than skipping past it,
        // and that a subsequent frame is still picked up correctly.
        let mut payload_with_lookalike = vec![0x01, 0x02];
        // NOT the real EOI in isolation — our fake_jpeg helper appends the *real*
        // terminating EOI after this, so the frame actually ends at the FIRST
        // FF D9 encountered, consistent with "last complete JPEG we can find"
        // since scanning for EOI takes the first candidate after SOI.
        payload_with_lookalike.extend_from_slice(&[0xFF, 0xD9]);
        let first = fake_jpeg(&payload_with_lookalike);
        let second = fake_jpeg(b"second-clean-frame");
        let mut buf = Vec::new();
        buf.extend_from_slice(&first);
        buf.extend_from_slice(&second);

        // Whatever the first frame resolves to, the LAST complete JPEG must still
        // be the second frame in full.
        let got = last_complete_jpeg(&buf).expect("expected a complete JPEG");
        assert_eq!(got, second.as_slice());
    }
}
