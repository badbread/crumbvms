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
