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

    Some(tokio::spawn(supervise(bin, config, shutdown)))
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
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                info!("go2rtc: {line}");
            }
        });
    }
    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                warn!("go2rtc: {line}");
            }
        });
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
