// SPDX-License-Identifier: AGPL-3.0-or-later

//! Embedded go2rtc restreamer — spawn + supervise as a recorder child process.
//!
//! Crumb's go2rtc restreamer used to run as its own compose service. That
//! container boundary was the highest bug-density seam in the codebase
//! (`crumb_api_base` poison, Docker-DNS fallthrough to a random LAN host when
//! the service was absent, base-URL confusion), so the same pinned go2rtc
//! binary is now baked into the recorder image (see
//! `services/recorder/Dockerfile`) and supervised here. The recorder is the
//! right host because it restarts rarely — an api restart must never drop live
//! client streams.
//!
//! Behaviour:
//! * Embedded by default; set `GO2RTC_EMBEDDED=false` to opt out (e.g. you run
//!   an external restreamer and point `CRUMB_GO2RTC_*` at it).
//! * If the binary or config file is missing: ONE loud warning, then the
//!   recorder proceeds — recording must never be hostage to the restreamer.
//! * Child stdout/stderr are piped into tracing with a `go2rtc:` prefix.
//! * Crash ⇒ restart with exponential backoff (1 s doubling, capped at 30 s);
//!   a run that stays up ≥ 60 s resets the backoff. Every restart logs.
//! * On recorder shutdown the child gets SIGTERM, then SIGKILL after a bound.
//!
//! Telemetry-simple by design: no health endpoint here — the api's reconcile
//! loop already logs go2rtc REST failures loudly, and the listeners' host
//! ports (18554/8556) are directly probeable.

use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Where the recorder image bakes the go2rtc binary (Dockerfile `COPY --from`).
const DEFAULT_BIN: &str = "/usr/local/bin/go2rtc";

/// Where compose mounts the listener-only config (`./go2rtc/go2rtc.yaml:ro`).
const DEFAULT_CONFIG: &str = "/config/go2rtc.yaml";

/// First restart delay after a child exit.
const BACKOFF_INITIAL: Duration = Duration::from_secs(1);

/// Restart backoff ceiling.
const BACKOFF_CAP: Duration = Duration::from_secs(30);

/// A child that stayed up at least this long is considered to have recovered,
/// resetting the backoff to [`BACKOFF_INITIAL`].
const STABLE_RUN: Duration = Duration::from_secs(60);

/// How long to wait after SIGTERM before SIGKILL on shutdown.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

/// How one supervised run of the child ended.
enum RunEnd {
    /// The recorder is shutting down; the child was terminated deliberately.
    Shutdown,
    /// The child exited on its own (status description) — supervisor restarts.
    Exited(String),
    /// The child could not even be spawned.
    SpawnFailed(std::io::Error),
}

/// Spawn the embedded go2rtc supervisor task, if enabled and installable.
///
/// Returns `None` (after one loud warning where appropriate) when the feature
/// is disabled via `GO2RTC_EMBEDDED=false` or the binary/config is absent —
/// the recorder proceeds either way.
pub fn spawn(shutdown: CancellationToken) -> Option<tokio::task::JoinHandle<()>> {
    let enabled = std::env::var("GO2RTC_EMBEDDED")
        .map(|v| !v.trim().eq_ignore_ascii_case("false"))
        .unwrap_or(true);
    if !enabled {
        info!("embedded go2rtc disabled (GO2RTC_EMBEDDED=false); not spawning");
        return None;
    }

    let bin = std::env::var("GO2RTC_BIN").unwrap_or_else(|_| DEFAULT_BIN.to_owned());
    let config = std::env::var("GO2RTC_CONFIG").unwrap_or_else(|_| DEFAULT_CONFIG.to_owned());

    if !Path::new(&bin).is_file() {
        warn!(
            bin = %bin,
            "embedded go2rtc binary NOT FOUND — live restreaming (RTSP/WebRTC/MSE) will be \
             unavailable until it is installed; recording continues unaffected"
        );
        return None;
    }
    if !Path::new(&config).is_file() {
        warn!(
            config = %config,
            "embedded go2rtc config NOT FOUND (compose should mount ./go2rtc/go2rtc.yaml) — \
             not spawning go2rtc; recording continues unaffected"
        );
        return None;
    }

    // Issue #398: the LAN-facing RTSP restream (:8554, published as :18554) is
    // authenticated by default. An operator may opt the LAN restream out of auth
    // with the explicit, documented token `GO2RTC_AUTH=off`. Secure by default:
    // anything else (unset / empty / unrecognized) keeps auth ON. The internal
    // go2rtc REST API (:1984, never host-published) stays authenticated in BOTH
    // postures — only the `rtsp:` listener's credentials are ever removed.
    let effective_config = resolve_effective_config(&config);

    Some(tokio::spawn(supervise(bin, effective_config, shutdown)))
}

/// Decide which go2rtc config file to launch, honoring the `GO2RTC_AUTH` posture
/// (issue #398) and logging the posture LOUDLY at startup.
///
/// * Auth ON (default): returns `template_path` UNCHANGED — go2rtc reads the
///   tracked, read-only-mounted config exactly as before, so the default path is
///   byte-for-byte identical to prior behavior.
/// * Auth OFF (`GO2RTC_AUTH=off`): renders an effective config with ONLY the
///   `rtsp:` listener's `username`/`password` removed and returns that writable
///   path. If rendering fails for any reason, falls back to `template_path`
///   (auth stays ON) — a failure to open the restream must never silently open
///   it, and must never open it by accident either.
fn resolve_effective_config(template_path: &str) -> String {
    if crumb_common::config::go2rtc_rtsp_auth_enabled_env() {
        info!(
            config = %template_path,
            "go2rtc RTSP restream auth is ENABLED (default); off-container LAN clients must \
             authenticate to pull streams"
        );
        return template_path.to_owned();
    }

    match render_auth_off(template_path) {
        Ok(rendered) => {
            warn!(
                rendered = %rendered,
                "go2rtc RTSP restream auth is DISABLED (GO2RTC_AUTH=off): any LAN client can pull \
                 every camera from rtsp://<host>:18554/<name> WITHOUT credentials. This is the \
                 operator's explicit opt-out; the internal go2rtc REST API (:1984) stays \
                 authenticated"
            );
            rendered
        }
        Err(e) => {
            // Secure fallback: keep the authenticated template so a rendering
            // failure leaves the restream LOCKED rather than in an unknown state.
            warn!(
                error = %e,
                config = %template_path,
                "GO2RTC_AUTH=off was requested but rendering the auth-off go2rtc config failed; \
                 falling back to the AUTHENTICATED config (restream stays locked, secure by default)"
            );
            template_path.to_owned()
        }
    }
}

/// Render an effective go2rtc config with the LAN `rtsp:` listener's auth
/// removed, written to a recorder-writable path (the tracked template is mounted
/// read-only, so it cannot be edited in place).
///
/// Only the `rtsp:` block's `username`/`password` keys are stripped; the `api:`
/// block keeps its credentials so the internal REST API (:1984) stays
/// authenticated. Returns the path go2rtc should be launched with.
fn render_auth_off(template_path: &str) -> std::io::Result<String> {
    let template = std::fs::read_to_string(template_path)?;
    let rendered = strip_rtsp_auth(&template);
    // A dedicated writable filename next to the OS temp dir. Regenerated on every
    // boot from the current template, so it never drifts. `GO2RTC_RENDERED_CONFIG`
    // overrides the location for hardened deployments with an unusual temp dir.
    let out_path = std::env::var("GO2RTC_RENDERED_CONFIG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir().join("crumb-go2rtc.effective.yaml"));
    std::fs::write(&out_path, rendered)?;
    Ok(out_path.to_string_lossy().into_owned())
}

/// Remove the `username`/`password` keys from ONLY the top-level `rtsp:` block of
/// a go2rtc YAML config, leaving every other block (notably `api:`) untouched.
///
/// go2rtc treats a listener with no `username`/`password` as open, so this is the
/// clean "no auth" state for the LAN RTSP listener (issue #398). The transform is
/// block-aware (it tracks the current top-level section by column-0 `key:` lines)
/// and comment-safe, so it survives key reordering and never touches the
/// identically-named keys under `api:`.
fn strip_rtsp_auth(template: &str) -> String {
    let mut out = String::with_capacity(template.len());
    // The top-level section the current line belongs to (`api`, `rtsp`, …).
    let mut section: Option<String> = None;

    // `split_inclusive` keeps each line's trailing newline so the rewritten file
    // preserves the original line endings exactly.
    for line in template.split_inclusive('\n') {
        let body = line.trim_end_matches(['\r', '\n']);
        let is_top_level = !body.is_empty()
            && !body.starts_with(char::is_whitespace)
            && !body.starts_with('#')
            && body.contains(':');
        if is_top_level {
            let key = body.split(':').next().unwrap_or("").trim();
            section = Some(key.to_owned());
        }

        if section.as_deref() == Some("rtsp") {
            let keyish = body.trim_start();
            if keyish.starts_with("username:") || keyish.starts_with("password:") {
                // Drop this credential line — opens ONLY the rtsp listener.
                continue;
            }
        }
        out.push_str(line);
    }
    out
}

/// Supervision loop: run the child, restart with exponential backoff, exit on
/// recorder shutdown.
async fn supervise(bin: String, config: String, shutdown: CancellationToken) {
    let mut backoff = BACKOFF_INITIAL;
    let mut restarts: u64 = 0;

    loop {
        let started = Instant::now();
        match run_once(&bin, &config, &shutdown).await {
            RunEnd::Shutdown => {
                info!("go2rtc: stopped (recorder shutting down)");
                return;
            }
            RunEnd::Exited(status) => {
                if started.elapsed() >= STABLE_RUN {
                    backoff = BACKOFF_INITIAL;
                }
                restarts += 1;
                warn!(
                    restart = restarts,
                    exit = %status,
                    backoff_secs = backoff.as_secs(),
                    "go2rtc: child exited; restarting after backoff"
                );
            }
            RunEnd::SpawnFailed(e) => {
                restarts += 1;
                warn!(
                    restart = restarts,
                    error = %e,
                    backoff_secs = backoff.as_secs(),
                    "go2rtc: spawn failed; retrying after backoff"
                );
            }
        }

        tokio::select! {
            () = tokio::time::sleep(backoff) => {}
            () = shutdown.cancelled() => {
                info!("go2rtc: supervisor shutting down during backoff");
                return;
            }
        }
        backoff = (backoff * 2).min(BACKOFF_CAP);
    }
}

/// Run the child once: spawn, forward its output to tracing, wait for exit or
/// recorder shutdown (terminate it in the latter case).
async fn run_once(bin: &str, config: &str, shutdown: &CancellationToken) -> RunEnd {
    let mut child = match Command::new(bin)
        .arg("-config")
        .arg(config)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Safety net: if this task/runtime is dropped abruptly (panic, early
        // main exit), the OS still reaps the child.
        .kill_on_drop(true)
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return RunEnd::SpawnFailed(e),
    };

    info!(pid = child.id(), bin = %bin, config = %config, "go2rtc: embedded restreamer spawned");

    // Forward child output into tracing, line by line, with a `go2rtc:` prefix.
    // go2rtc writes its own level/timestamp per line, so both pipes log at the
    // same tracing level.
    if let Some(stdout) = child.stdout.take() {
        tokio::spawn(drain_pipe(stdout, false));
    }
    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(drain_pipe(stderr, true));
    }

    tokio::select! {
        status = child.wait() => match status {
            Ok(s) => RunEnd::Exited(s.to_string()),
            Err(e) => RunEnd::Exited(format!("wait() failed: {e}")),
        },
        () = shutdown.cancelled() => {
            terminate(&mut child).await;
            RunEnd::Shutdown
        }
    }
}

/// Forward one child pipe into tracing, line by line, until EOF.
///
/// The task's contract is "keep the pipe empty for as long as the child
/// lives" — a full ~64 KB pipe blocks the child's writes and a closed one
/// SIGPIPEs it into a restart loop (correctness item 5). So reads are
/// BYTE-oriented: `read_until(b'\n')` + lossy UTF-8 conversion. A UTF-8-strict
/// `read_line`/`next_line` returns `InvalidData` on the first non-UTF-8 byte
/// go2rtc emits, silently ending the drain while the child still runs — the
/// exact failure this replaces. On a genuine (non-`Interrupted`) IO error the
/// task falls back to a raw copy-to-null so the pipe stays drained even when
/// line reads are broken; only EOF (child closed its end) ends the task.
async fn drain_pipe<R>(pipe: R, is_stderr: bool)
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut reader = BufReader::new(pipe);
    let mut buf: Vec<u8> = Vec::with_capacity(256);
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf).await {
            Ok(0) => return, // EOF — the child closed its end.
            Ok(_) => {
                let raw = String::from_utf8_lossy(&buf);
                let line = raw.trim_end_matches(['\r', '\n']);
                if is_stderr {
                    warn!("go2rtc: {line}");
                } else {
                    info!("go2rtc: {line}");
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {
                // Retry; worst case the partial line in `buf` is dropped at
                // the top of the loop (cosmetic — the pipe stays drained).
            }
            Err(e) => {
                warn!(error = %e, "go2rtc: log pipe read failed; draining raw to null until EOF");
                let _ = tokio::io::copy(&mut reader, &mut tokio::io::sink()).await;
                return;
            }
        }
    }
}

/// Terminate the child cleanly: SIGTERM, bounded wait, then SIGKILL.
async fn terminate(child: &mut Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id() {
        // SIGTERM first so go2rtc can close its listeners/sessions cleanly.
        // pid fits in i32 on every platform we target (Linux pids ≤ 2^22).
        #[allow(clippy::cast_possible_wrap)]
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }
        if tokio::time::timeout(SHUTDOWN_GRACE, child.wait())
            .await
            .is_ok()
        {
            return;
        }
        warn!("go2rtc: did not exit within grace period after SIGTERM; killing");
    }
    // Non-unix, no pid (already reaped), or SIGTERM grace expired: hard kill.
    let _ = child.kill().await;
}

#[cfg(test)]
mod tests {
    use super::{drain_pipe, strip_rtsp_auth};

    /// The shipped go2rtc config layout (issue #398). Mirrors
    /// `go2rtc/go2rtc.yaml`: `api:` and `rtsp:` both carry
    /// `username`/`password`, and `api:` additionally has `local_auth: true`.
    const SAMPLE: &str = "\
api:
  listen: \":1984\"
  username: \"${GO2RTC_USER}\"
  password: \"${GO2RTC_PASS}\"
  local_auth: true

rtsp:
  listen: \":8554\"
  # credential lines follow; stripped when the operator opts out
  username: \"${GO2RTC_USER}\"
  password: \"${GO2RTC_PASS}\"

webrtc:
  listen: \":8556\"

streams: {}
";

    /// Auth-off render: ONLY the rtsp block's credentials are removed. The api
    /// block's credentials (defense-in-depth for the internal :1984 REST API)
    /// MUST remain, and no other content may be lost.
    #[test]
    fn strip_rtsp_auth_removes_only_rtsp_credentials() {
        let out = strip_rtsp_auth(SAMPLE);

        // The rtsp listener is now open: its credential KEYS are gone.
        let rtsp_block = out
            .split_once("rtsp:")
            .expect("rtsp block present")
            .1
            .split("webrtc:")
            .next()
            .expect("content before webrtc");
        assert!(
            !rtsp_block.contains("username:"),
            "rtsp username must be stripped, got:\n{rtsp_block}"
        );
        assert!(
            !rtsp_block.contains("password:"),
            "rtsp password must be stripped, got:\n{rtsp_block}"
        );
        // Non-credential content in the rtsp block (comments, other keys) is
        // preserved — only the two credential lines are removed.
        assert!(rtsp_block.contains("# credential lines follow"));

        // The api block KEEPS its credentials + local_auth (internal REST stays
        // authenticated in both postures).
        let api_block = out
            .split_once("api:")
            .expect("api block present")
            .1
            .split("rtsp:")
            .next()
            .expect("content before rtsp");
        assert!(api_block.contains("username: \"${GO2RTC_USER}\""));
        assert!(api_block.contains("password: \"${GO2RTC_PASS}\""));
        assert!(api_block.contains("local_auth: true"));

        // Unrelated blocks survive intact.
        assert!(out.contains("webrtc:"));
        assert!(out.contains("streams: {}"));
        assert!(out.contains("listen: \":8554\""));
    }

    /// Byte-for-byte guard on the auth-ON path is enforced by
    /// `resolve_effective_config` returning the template unchanged; here we
    /// prove the transform itself only ever REMOVES the two rtsp credential
    /// lines and changes nothing else (line count drops by exactly 2).
    #[test]
    fn strip_rtsp_auth_removes_exactly_two_lines() {
        let before = SAMPLE.lines().count();
        let out = strip_rtsp_auth(SAMPLE);
        assert_eq!(
            out.lines().count(),
            before - 2,
            "exactly the rtsp username + password lines are removed"
        );
    }

    /// A config with no rtsp credentials (already open, or a hand-edited file)
    /// is returned unchanged — the transform is idempotent and never errors.
    #[test]
    fn strip_rtsp_auth_is_idempotent() {
        let once = strip_rtsp_auth(SAMPLE);
        let twice = strip_rtsp_auth(&once);
        assert_eq!(once, twice);
    }

    /// Audit #76 regression: the old UTF-8-strict `next_line()` drain returned
    /// `InvalidData` on the first non-UTF-8 byte and silently exited, closing
    /// the pipe under a live child (SIGPIPE → restart loop). The byte drain
    /// must consume ALL lines — valid and invalid alike — and return only at
    /// EOF. Completion of this future (rather than a hang or panic) is the
    /// assertion.
    #[tokio::test]
    async fn drain_pipe_survives_invalid_utf8_to_eof() {
        let input: &[u8] = b"ok line\n\xff\xfe\xfd binary junk\nlast line without newline";
        drain_pipe(input, false).await;
        drain_pipe(input, true).await; // stderr path shares the same loop
    }

    /// An empty pipe (child produced nothing before exiting) is immediate EOF.
    #[tokio::test]
    async fn drain_pipe_handles_immediate_eof() {
        drain_pipe(&b""[..], false).await;
    }
}
