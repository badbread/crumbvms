// SPDX-License-Identifier: AGPL-3.0-or-later

//! Boot-time accelerator capability detection (motion-decode truth telemetry).
//!
//! The admin console's "Motion decoding" panel lets an operator request a
//! decode backend, but hardware acceleration only works when the matching
//! device is mapped INTO the recorder container (the gpu/vaapi compose
//! overlays). This module probes, once per boot, what is actually visible
//! from inside the container:
//!
//! * `/dev/dri/renderD*` render nodes (VAAPI),
//! * any `/dev/nvidia*` device node (NVDEC/CUDA),
//! * the hwaccels the bundled ffmpeg was COMPILED with (`ffmpeg -hwaccels`).
//!
//! The result is persisted to the `recorder_capabilities` singleton row
//! (migration 0035) so the API's `GET /config/decode-status` can explain WHY
//! a requested backend fell back to CPU. Telemetry only — a probe or write
//! failure is logged and never affects recording or motion.

use deadpool_postgres::Pool;
use tracing::{info, warn};

/// How long the runtime cuda probe may take before it is treated as "no usable
/// device". The probe decodes nothing (a 64×64 `nullsrc`, one frame) and returns
/// in milliseconds on a healthy host; the deadline exists only so a wedged
/// driver can never stall a motion worker's (re)connect.
const CUDA_PROBE_TIMEOUT_SECS: u64 = 15;

/// Probe the container's accelerator surface and persist it (best-effort).
///
/// Called once from the supervisor's boot sequence. Errors are logged, never
/// propagated — a missing report only degrades the admin decode-status panel.
pub async fn publish(pool: &Pool) {
    let dri_devices = list_dri_render_nodes();
    let nvidia = nvidia_device_present();
    let ffmpeg_hwaccels = ffmpeg_hwaccels().await;

    info!(
        dri_devices = ?dri_devices,
        nvidia,
        ffmpeg_hwaccels = ?ffmpeg_hwaccels,
        "decode capability probe complete"
    );

    if let Err(e) =
        crumb_common::db::write_recorder_capabilities(pool, &dri_devices, nvidia, &ffmpeg_hwaccels)
            .await
    {
        warn!(error = %e, "failed to persist recorder capabilities; decode-status panel will show no report");
    }
}

/// Whether an ffmpeg **cuda hardware device can actually be created** in this
/// container — the probe that resolves `MOTION_HWACCEL=auto` (issue #479).
///
/// `crumb_common::config::nvdec_available()` answers a different question: "was
/// cuda compiled into this ffmpeg". The bundled image answers yes on every host,
/// so resolving `auto` with it picked cuda on GPU-less hosts; every per-camera
/// motion ffmpeg then exited immediately and the EOF/reconnect watchdog
/// relaunched the same failing flags forever, leaving motion detection down
/// (and, via fail-open, every camera recording continuously) until an operator
/// intervened.
///
/// The probe here runs
/// `ffmpeg -init_hw_device cuda=… -f lavfi -i nullsrc -frames:v 1 -f null -`,
/// which exits non-zero unless a real device was opened (on a deviceless host:
/// `Cannot load libcuda.so.1` / `Device creation failed`). Result cached for the
/// process lifetime — a GPU cannot appear in a running container anyway (Docker
/// never grants a live container new devices), and a recorder restart re-probes.
///
/// Fails SAFE: a spawn error, a non-zero exit, or a timeout all read as "no
/// cuda", which sends `auto` to software decode — the backend that works
/// everywhere.
pub(crate) async fn cuda_runtime_available() -> bool {
    static CACHE: tokio::sync::OnceCell<bool> = tokio::sync::OnceCell::const_new();
    *CACHE.get_or_init(probe_cuda_runtime).await
}

/// One-shot body of [`cuda_runtime_available`] (kept separate so the cache above
/// stays a two-liner).
async fn probe_cuda_runtime() -> bool {
    // Cheap gate first: no point spawning the device probe when the binary has
    // no cuda support at all.
    let compiled = ffmpeg_hwaccels()
        .await
        .iter()
        .any(|m| m.eq_ignore_ascii_case("cuda"));
    if !compiled {
        info!("cuda runtime probe: this ffmpeg has no cuda hwaccel compiled in; motion decode auto → cpu");
        return false;
    }
    let device_nodes = nvidia_device_present();
    let probe = tokio::process::Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-init_hw_device",
            "cuda=crumbprobe",
            "-f",
            "lavfi",
            "-i",
            "nullsrc=s=64x64",
            "-frames:v",
            "1",
            "-f",
            "null",
            "-",
        ])
        .output();
    match tokio::time::timeout(
        std::time::Duration::from_secs(CUDA_PROBE_TIMEOUT_SECS),
        probe,
    )
    .await
    {
        Ok(Ok(o)) if o.status.success() => {
            info!(
                nvidia_device_nodes = device_nodes,
                "cuda runtime probe: hardware device created; motion decode auto → cuda"
            );
            true
        }
        Ok(Ok(o)) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            info!(
                status = ?o.status.code(),
                nvidia_device_nodes = device_nodes,
                ffmpeg_stderr = %stderr.trim(),
                "cuda runtime probe: ffmpeg has cuda compiled in but NO usable device here \
                 (map a GPU via the gpu compose overlay to use it); motion decode auto → cpu"
            );
            false
        }
        Ok(Err(e)) => {
            warn!(error = %e, "cuda runtime probe failed to spawn ffmpeg; motion decode auto → cpu");
            false
        }
        Err(_elapsed) => {
            warn!(
                timeout_s = CUDA_PROBE_TIMEOUT_SECS,
                "cuda runtime probe timed out; motion decode auto → cpu"
            );
            false
        }
    }
}

/// List `/dev/dri/renderD*` nodes (full paths, sorted).
///
/// Render nodes (`renderD128`, `renderD129`, …) are what VAAPI opens; the
/// primary nodes (`card0`, …) are deliberately excluded.
fn list_dri_render_nodes() -> Vec<String> {
    let mut nodes: Vec<String> = match std::fs::read_dir("/dev/dri") {
        Ok(entries) => entries
            .filter_map(std::result::Result::ok)
            .filter(|e| e.file_name().to_string_lossy().starts_with("renderD"))
            .map(|e| e.path().to_string_lossy().into_owned())
            .collect(),
        // No /dev/dri at all — the common no-overlay case, not an error.
        Err(_) => Vec::new(),
    };
    nodes.sort();
    nodes
}

/// Whether any `/dev/nvidia*` device node is present (e.g. `/dev/nvidia0`,
/// `/dev/nvidiactl`) — i.e. an NVIDIA GPU is mapped into the container.
///
/// Device nodes are the truth for container mapping; `nvidia-smi` on PATH
/// proves nothing about the runtime device surface.
fn nvidia_device_present() -> bool {
    match std::fs::read_dir("/dev") {
        Ok(entries) => entries
            .filter_map(std::result::Result::ok)
            .any(|e| e.file_name().to_string_lossy().starts_with("nvidia")),
        Err(_) => false,
    }
}

/// Run `ffmpeg -hide_banner -hwaccels` and parse the method list.
///
/// Output shape (stdout on modern builds, stderr on some older ones):
///
/// ```text
/// Hardware acceleration methods:
/// vdpau
/// cuda
/// vaapi
/// ```
///
/// Returns an empty list when ffmpeg can't be spawned — honest "unknown", the
/// UI treats it the same as "no accel support".
async fn ffmpeg_hwaccels() -> Vec<String> {
    let output = match tokio::process::Command::new("ffmpeg")
        .args(["-hide_banner", "-hwaccels"])
        .output()
        .await
    {
        Ok(o) => o,
        Err(e) => {
            warn!(error = %e, "ffmpeg -hwaccels probe failed to spawn");
            return Vec::new();
        }
    };
    // ffmpeg -hwaccels may print to stdout or stderr depending on version.
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    parse_hwaccels(&text)
}

/// Parse the `-hwaccels` listing: every non-empty line after the
/// "Hardware acceleration methods:" header.
fn parse_hwaccels(text: &str) -> Vec<String> {
    text.lines()
        .skip_while(|l| !l.starts_with("Hardware acceleration methods"))
        .skip(1)
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::parse_hwaccels;

    #[test]
    fn parses_typical_hwaccels_output() {
        let out = "Hardware acceleration methods:\nvdpau\ncuda\nvaapi\nqsv\n\n";
        assert_eq!(parse_hwaccels(out), vec!["vdpau", "cuda", "vaapi", "qsv"]);
    }

    #[test]
    fn missing_header_yields_empty() {
        assert!(parse_hwaccels("ffmpeg: command not found").is_empty());
    }

    #[test]
    fn empty_method_list_yields_empty() {
        assert!(parse_hwaccels("Hardware acceleration methods:\n").is_empty());
    }
}
