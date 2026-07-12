// SPDX-License-Identifier: AGPL-3.0-or-later

//! Per-camera resource sampler — non-invasive CPU / memory / GPU attribution.
//!
//! # Responsibility
//!
//! A background task (spawned from `main`, alongside the heartbeat / archive
//! tasks) wakes every [`SAMPLE_INTERVAL_SECONDS`] and attributes the host's
//! ffmpeg resource usage back to individual cameras, then upserts one
//! [`camera_resource_stats`](crumb_common::db::upsert_camera_resource_stats) row
//! per camera. The desktop **Statistics** table reads these through the
//! admin-only `GET /stats/cameras` endpoint (CPU% / Mem / GPU% columns).
//!
//! # Why a sampler (and not in-process accounting)
//!
//! Each [`CameraWorker`](crate::CameraWorker) shells out to two ffmpeg children:
//!
//! * a **recording** child (`-c copy`, ~zero CPU) whose output path contains the
//!   camera UUID (`{live}/{camera_id}/…mp4`), and
//! * a **motion** child that decodes the sub-stream (the real CPU/GPU consumer),
//!   whose input URL contains the camera's go2rtc stream name.
//!
//! Those children are the recorder's direct subprocesses, so we identify them by
//! reading `/proc` for processes whose `comm` is `ffmpeg` AND whose `PPid` is the
//! recorder's own pid, then map each to a camera via its cmdline. This keeps the
//! hot recording/motion path completely untouched — the sampler only ever *reads*
//! `/proc` and queries NVML; it never signals or stats the ffmpeg children
//! in a way that could perturb decoding.
//!
//! # Platform
//!
//! `/proc` sampling is **Linux-only** (prod is Linux/Docker). On any other target
//! the task is a no-op that upserts nothing, so the workspace still builds and
//! runs on the Windows dev workstation.
//!
//! # GPU attribution (best-effort)
//!
//! GPU% is derived from **NVML** per-PID utilisation (`nvml-wrapper`) and is
//! strictly best-effort. NVML reads device telemetry as **non-root** (the
//! recorder runs as uid 1001), unlike `nvidia-smi pmon -s u`, which needs root
//! to enumerate per-PID GPU usage and so always reported 0/NULL inside the
//! container. The container has the NVIDIA `utility` driver capability
//! (`NVIDIA_DRIVER_CAPABILITIES=…,utility`) so `libnvidia-ml` is injected.
//!
//! Each tick we call `Device::process_utilization_stats` for the samples newer
//! than the ones the previous tick consumed, which yields a batch of
//! [`ProcessUtilizationSample`]s — typically SEVERAL per GPU process (the
//! driver buffers at sub-second cadence) — each with a `pid` and a `dec_util`
//! (decode-engine %). We attribute **`dec_util`** — the quantity that actually
//! moves when ffmpeg NVDEC-decodes a sub-stream — to a camera by averaging each
//! pid's samples over the tick and summing those means across the camera's
//! ffmpeg child pids, reusing the exact PID→camera mapping already built for
//! CPU/mem.
//!
//! ## Host-PID → container-PID translation
//!
//! NVML reports **host** PIDs (it talks to the driver, which lives in the host
//! PID namespace), but the recorder runs in its own container PID namespace, so
//! the ffmpeg child pids we sum over (from the recorder's `/proc`) are
//! **container** PIDs. Left unreconciled the two never match and GPU% is a
//! permanent 0. To bridge them we read the **host** procfs, bind-mounted
//! read-only at `/host/proc` (the node_exporter pattern), and for each GPU
//! host-pid take the last field of its `NSpid:` line — the value in the
//! innermost (our) namespace — **gated on a matching `/proc/<pid>/ns/pid`** so a
//! different container's ffmpeg whose container PID happens to collide
//! numerically (e.g. Frigate decoding the same go2rtc streams) can never be
//! misattributed. If `/host/proc` isn't mounted the translation is skipped and
//! GPU% degrades to `NULL` (CPU/mem are unaffected).
//!
//! If NVML can't init (no GPU / no driver / missing `utility` cap), every tick's
//! `gpu_pct` is `NULL` and a single init-failure warning is logged. Any per-tick
//! NVML query error also yields `NULL` for that tick. A GPU sampling failure
//! never affects CPU/mem accounting.

use std::sync::LazyLock;

use deadpool_postgres::Pool;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Process-wide NVML handle, initialised once on first use.
///
/// `Some(nvml)` when an NVIDIA driver + `libnvidia-ml` are present (the recorder
/// container, which ships the `utility` driver capability); `None` otherwise —
/// e.g. the Windows dev workstation or a GPU-less host — in which case `gpu_pct`
/// is always `NULL` and a one-time warning is logged. `Nvml` is `Send + Sync`, so
/// a single shared handle is fine across the sampler ticks.
///
/// Mirrors the desktop crate's `NVML` static (`nvml-wrapper` 0.10).
static NVML: LazyLock<Option<nvml_wrapper::Nvml>> =
    LazyLock::new(|| nvml_wrapper::Nvml::init().ok());

/// How often the sampler attributes ffmpeg usage to cameras and upserts rows.
///
/// 10 s matches the recorder heartbeat cadence and is well under the API's 60 s
/// staleness window, so a healthy sampler always reports fresh numbers.
const SAMPLE_INTERVAL_SECONDS: u64 = 10;

/// `_SC_CLK_TCK` (USER_HZ) — clock ticks per second for `/proc/<pid>/stat`
/// `utime`/`stime`.
///
/// 100 on every Linux platform Crumb targets (x86-64 / aarch64). Hardcoded
/// deliberately to keep the recorder crate free of a `libc` dependency, mirroring
/// the existing `EXDEV = 18` hardcode in `reconcile.rs`. If a future exotic kernel
/// uses a different USER_HZ the only effect is a proportionally mis-scaled CPU%,
/// never a crash.
#[cfg(target_os = "linux")]
const CLK_TCK: f64 = 100.0;

/// Spawn the per-camera resource sampler task.
///
/// Returns the [`JoinHandle`](tokio::task::JoinHandle) so the supervisor can join
/// it (bounded) on shutdown. The task runs until `cancel` fires.
pub fn spawn(pool: Pool, cancel: CancellationToken) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        run(pool, cancel).await;
    })
}

/// Sampler loop: every [`SAMPLE_INTERVAL_SECONDS`], attribute ffmpeg usage to
/// cameras and upsert one row per camera.
///
/// A failed tick (DB blip, transient `/proc` read error) is logged and retried on
/// the next tick — a sampling error must never kill the loop.
async fn run(pool: Pool, cancel: CancellationToken) {
    info!(
        interval_s = SAMPLE_INTERVAL_SECONDS,
        "per-camera resource sampler started"
    );

    // Linux-only state: previous-tick CPU jiffies per pid, to compute deltas.
    #[cfg(target_os = "linux")]
    let mut sampler = LinuxSampler::new();
    // Latch so the "NVML unavailable" warning is logged at most once.
    #[cfg(target_os = "linux")]
    let mut gpu_warned = false;

    let mut interval =
        tokio::time::interval(tokio::time::Duration::from_secs(SAMPLE_INTERVAL_SECONDS));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = interval.tick() => {
                #[cfg(target_os = "linux")]
                {
                    if let Err(e) = sampler.tick(&pool, &mut gpu_warned).await {
                        warn!(error = %e, "resource sampler tick failed; will retry");
                    }
                }
                // Non-Linux: nothing to sample. The task stays alive (so the
                // supervisor's join logic is identical across platforms) but
                // upserts nothing.
                #[cfg(not(target_os = "linux"))]
                {
                    let _ = &pool;
                }
            }
            () = cancel.cancelled() => {
                info!("resource sampler shutting down");
                break;
            }
        }
    }
}

// ─── Linux /proc sampler ──────────────────────────────────────────────────────

#[cfg(target_os = "linux")]
mod linux {
    use super::{CLK_TCK, SAMPLE_INTERVAL_SECONDS};
    use std::collections::HashMap;

    use anyhow::{Context, Result};
    use deadpool_postgres::Pool;
    use tracing::{debug, warn};
    use uuid::Uuid;

    /// One camera's accumulated resource usage for a single tick.
    #[derive(Default)]
    pub(super) struct CameraUsage {
        pub cpu_jiffies: u64,
        pub mem_kb: u64,
        pub pids: Vec<i32>,
    }

    /// Per-tick CPU-delta state plus the camera roster lookup.
    pub(super) struct LinuxSampler {
        /// pid → cumulative `utime + stime` (clock ticks) from the previous tick.
        prev_jiffies: HashMap<i32, u64>,
        /// When the previous successful sample was taken. CPU% divides the
        /// jiffies delta by the MEASURED wall time since then, not the nominal
        /// [`SAMPLE_INTERVAL_SECONDS`]: with `MissedTickBehavior::Skip` a
        /// delayed/skipped tick can make the real gap much longer than 10 s,
        /// and dividing by the nominal interval would overstate CPU%.
        prev_sample_at: Option<std::time::Instant>,
        /// Newest NVML sample timestamp (µs) already consumed, passed back to
        /// `process_utilization_stats` so each tick only sees NEW samples.
        last_gpu_sample_ts: u64,
    }

    impl LinuxSampler {
        pub(super) fn new() -> Self {
            Self {
                prev_jiffies: HashMap::new(),
                prev_sample_at: None,
                last_gpu_sample_ts: 0,
            }
        }

        /// One sampling pass: enumerate the recorder's ffmpeg children, attribute
        /// each to a camera, compute CPU%/mem/GPU%, and upsert one row per camera
        /// that has a running ffmpeg (cameras with none keep their last row, which
        /// the API ages out after 60 s).
        pub(super) async fn tick(&mut self, pool: &Pool, gpu_warned: &mut bool) -> Result<()> {
            // 1. Load the camera roster (id, go2rtc_name) so we can map a motion
            //    ffmpeg's sub-stream URL to a camera when the UUID is absent.
            let cameras = crumb_common::db::list_cameras_all(pool)
                .await
                .context("loading camera roster for resource sampling")?;
            let by_go2rtc: HashMap<String, Uuid> = cameras
                .iter()
                .map(|c| (c.go2rtc_name.clone(), c.id))
                .collect();
            let camera_ids: Vec<Uuid> = cameras.iter().map(|c| c.id).collect();

            // 2. Walk /proc for ffmpeg children of THIS recorder process,
            //    noting WHEN the jiffies were sampled so CPU% can divide by the
            //    real elapsed time (see `prev_sample_at`).
            let sampled_at = std::time::Instant::now();
            let my_pid = std::process::id() as i32;
            let procs = collect_ffmpeg_children(my_pid);

            // 3. Attribute each ffmpeg pid to a camera and accumulate jiffies/mem.
            let mut per_camera: HashMap<Uuid, CameraUsage> = HashMap::new();
            let mut seen_pids: Vec<i32> = Vec::with_capacity(procs.len());
            for p in &procs {
                seen_pids.push(p.pid);
                let Some(camera_id) = attribute_to_camera(&p.cmdline, &camera_ids, &by_go2rtc)
                else {
                    continue;
                };
                let entry = per_camera.entry(camera_id).or_default();
                entry.cpu_jiffies = entry.cpu_jiffies.saturating_add(p.jiffies);
                entry.mem_kb = entry.mem_kb.saturating_add(p.rss_kb);
                entry.pids.push(p.pid);
            }

            // 4. Best-effort per-PID GPU utilisation (pid → gpu %, averaged over
            //    the tick's NVML samples, then summed/clamped per camera).
            //    Missing/empty ⇒ None for every camera.
            let gpu_by_pid = sample_gpu_by_pid(gpu_warned, &mut self.last_gpu_sample_ts);

            // 5. Compute CPU% from the jiffies delta vs the previous tick, mem MB,
            //    and GPU% (sum over the camera's pids), then upsert.
            //
            // CPU% divides by the MEASURED elapsed time since the previous
            // successful sample. On the first tick there is no previous sample;
            // every per-pid delta is 0 there anyway (prev defaults to now), so
            // the nominal-interval fallback only avoids a 0/0.
            #[allow(clippy::cast_precision_loss)]
            let elapsed_secs = self
                .prev_sample_at
                .map_or(SAMPLE_INTERVAL_SECONDS as f64, |prev| {
                    sampled_at.duration_since(prev).as_secs_f64()
                })
                .max(0.001);
            let mut new_prev: HashMap<i32, u64> = HashMap::with_capacity(procs.len());
            for p in &procs {
                new_prev.insert(p.pid, p.jiffies);
            }

            for (camera_id, usage) in &per_camera {
                // CPU%: Σ (this-tick jiffies − prev-tick jiffies) over the camera's
                // pids, divided by (elapsed × CLK_TCK), ×100. New pids (no prev
                // entry) contribute 0 this tick and a real value next tick.
                let mut delta_jiffies: u64 = 0;
                for pid in &usage.pids {
                    let now = new_prev.get(pid).copied().unwrap_or(0);
                    let prev = self.prev_jiffies.get(pid).copied().unwrap_or(now);
                    delta_jiffies = delta_jiffies.saturating_add(now.saturating_sub(prev));
                }
                let cpu_pct = cpu_pct_from_delta(delta_jiffies, elapsed_secs);

                #[allow(clippy::cast_precision_loss)]
                let mem_mb = (usage.mem_kb as f64) / 1024.0;

                // GPU%: sum the per-pid utilisation for this camera's pids. If
                // nvidia-smi gave us nothing, gpu_by_pid is empty ⇒ None.
                let gpu_pct: Option<f64> = if let Some(map) = gpu_by_pid.as_ref() {
                    let sum: f64 = usage
                        .pids
                        .iter()
                        .filter_map(|pid| map.get(pid).copied())
                        .sum();
                    Some(sum.min(100.0))
                } else {
                    None
                };

                if let Err(e) = crumb_common::db::upsert_camera_resource_stats(
                    pool, *camera_id, cpu_pct, mem_mb, gpu_pct,
                )
                .await
                {
                    warn!(camera_id = %camera_id, error = %e, "upsert_camera_resource_stats failed");
                } else {
                    debug!(
                        camera_id = %camera_id,
                        cpu_pct,
                        mem_mb,
                        gpu_pct = ?gpu_pct,
                        pids = ?usage.pids,
                        "camera resource sample"
                    );
                }
            }

            // 6. Carry forward this tick's jiffies (pruning pids that have exited
            //    so the map can't grow without bound) and its sample instant.
            self.prev_jiffies = new_prev;
            self.prev_sample_at = Some(sampled_at);

            Ok(())
        }
    }

    /// CPU% for one camera over one tick: the summed jiffies delta of its pids,
    /// over the MEASURED wall-clock seconds those jiffies accumulated in.
    ///
    /// Pure arithmetic, split out for unit testing: `delta / (elapsed × CLK_TCK)
    /// × 100` — e.g. 500 jiffies (5 s of CPU at USER_HZ=100) over 5 s elapsed is
    /// one fully-busy core = 100%.
    fn cpu_pct_from_delta(delta_jiffies: u64, elapsed_secs: f64) -> f64 {
        #[allow(clippy::cast_precision_loss)]
        let delta = delta_jiffies as f64;
        delta / (elapsed_secs * CLK_TCK) * 100.0
    }

    /// A single ffmpeg child of the recorder.
    struct FfmpegProc {
        pid: i32,
        /// `utime + stime` in clock ticks (cumulative).
        jiffies: u64,
        /// Resident set size in kB (`VmRSS`).
        rss_kb: u64,
        /// The full cmdline (NUL bytes already replaced with spaces).
        cmdline: String,
    }

    /// Scan `/proc` for processes whose `comm` is `ffmpeg` and whose `PPid` equals
    /// `parent_pid` (this recorder), returning their cpu jiffies, RSS, and cmdline.
    ///
    /// Errors on individual processes (which may exit mid-scan) are skipped, never
    /// propagated — a racing pid disappearing is normal.
    fn collect_ffmpeg_children(parent_pid: i32) -> Vec<FfmpegProc> {
        let mut out = Vec::new();
        let Ok(entries) = std::fs::read_dir("/proc") else {
            return out;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let Ok(pid) = name.parse::<i32>() else {
                continue;
            };

            // `comm` is the executable name; cheap reject of non-ffmpeg pids.
            let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
            if comm.trim() != "ffmpeg" {
                continue;
            }

            // /proc/<pid>/stat: fields 14 (utime) and 15 (stime) are jiffies; the
            // PPid is field 4. The 2nd field (comm) is parenthesised and may
            // contain spaces, so split AFTER the closing ')'.
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
            let Some((ppid, jiffies)) = parse_stat(&stat) else {
                continue;
            };
            if ppid != parent_pid {
                continue;
            }

            let rss_kb = read_vmrss_kb(pid).unwrap_or(0);
            let cmdline = read_cmdline(pid);

            out.push(FfmpegProc {
                pid,
                jiffies,
                rss_kb,
                cmdline,
            });
        }
        out
    }

    /// Parse `(PPid, utime + stime)` from the contents of `/proc/<pid>/stat`.
    ///
    /// Field layout (1-indexed): `pid (comm) state ppid ... utime(14) stime(15)`.
    /// `comm` is wrapped in parentheses and may itself contain spaces and `)`, so
    /// we split on the LAST `')'` and index the remaining whitespace-separated
    /// fields from there (field 3 = state onwards).
    fn parse_stat(stat: &str) -> Option<(i32, u64)> {
        let close = stat.rfind(')')?;
        // Everything after ") " — first token here is field 3 (state).
        let rest = stat.get(close + 1..)?.trim_start();
        let fields: Vec<&str> = rest.split_whitespace().collect();
        // rest[0] = state (field 3), so:
        //   ppid  = field 4  → rest index 1
        //   utime = field 14 → rest index 11
        //   stime = field 15 → rest index 12
        let ppid: i32 = fields.get(1)?.parse().ok()?;
        let utime: u64 = fields.get(11)?.parse().ok()?;
        let stime: u64 = fields.get(12)?.parse().ok()?;
        Some((ppid, utime.saturating_add(stime)))
    }

    /// Read `VmRSS` (kB) from `/proc/<pid>/status`. Returns `None` if absent.
    fn read_vmrss_kb(pid: i32) -> Option<u64> {
        let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
        for line in status.lines() {
            if let Some(rest) = line.strip_prefix("VmRSS:") {
                // "VmRSS:\t   12345 kB"
                return rest.split_whitespace().next().and_then(|n| n.parse().ok());
            }
        }
        None
    }

    /// Read `/proc/<pid>/cmdline` (NUL-separated argv) as a space-joined string.
    fn read_cmdline(pid: i32) -> String {
        match std::fs::read(format!("/proc/{pid}/cmdline")) {
            Ok(bytes) => bytes
                .split(|&b| b == 0)
                .filter(|s| !s.is_empty())
                .map(|s| String::from_utf8_lossy(s).into_owned())
                .collect::<Vec<_>>()
                .join(" "),
            Err(_) => String::new(),
        }
    }

    /// Map one ffmpeg cmdline to a camera id.
    ///
    /// Two attribution paths, in priority order:
    ///
    /// 1. **Recording child** — its output path is `{live}/{camera_id}/…mp4`, so
    ///    the camera UUID appears literally in the cmdline. We match the first
    ///    known camera id that occurs as a substring.
    /// 2. **Motion child** — `-c copy` is absent and the cmdline carries the
    ///    sub-stream URL (`…/<go2rtc_name>` or `…/<go2rtc_name>_sub`). We match the
    ///    longest go2rtc name that appears as a substring (longest-first so
    ///    `front_door` wins over a hypothetical `front`).
    ///
    /// Returns `None` when neither path matches (e.g. an ffmpeg the recorder spawns
    /// for some unrelated purpose).
    fn attribute_to_camera(
        cmdline: &str,
        camera_ids: &[Uuid],
        by_go2rtc: &HashMap<String, Uuid>,
    ) -> Option<Uuid> {
        // 1. UUID in the recording output path — most reliable.
        for id in camera_ids {
            if cmdline.contains(&id.to_string()) {
                return Some(*id);
            }
        }

        // 2. go2rtc stream name in the sub-stream URL. Match longest name first so
        //    a name that is a prefix of another can't shadow the more specific one.
        let mut names: Vec<(&String, &Uuid)> = by_go2rtc.iter().collect();
        names.sort_by_key(|(name, _)| std::cmp::Reverse(name.len()));
        for (name, id) in names {
            if !name.is_empty() && cmdline.contains(name.as_str()) {
                return Some(*id);
            }
        }

        None
    }

    // ── GPU (best-effort, via NVML) ─────────────────────────────────────────────

    /// Per-PID GPU **decode** utilisation (%) via NVML, best-effort.
    ///
    /// Returns:
    /// * `Some(map)` — NVML is up and `process_utilization_stats` returned a (possibly
    ///   empty) sample set. An empty map is a valid "0%" state (no process is decoding
    ///   right now), distinct from "no GPU telemetry".
    /// * `None` — NVML failed to init (no GPU / driver / `utility` cap), or the
    ///   device / query errored this tick. The caller records `gpu_pct = NULL`. The
    ///   one-time NVML-init-failure warning is logged via the `gpu_warned` latch so a
    ///   GPU-less host doesn't spam the log.
    ///
    /// The driver buffers MANY `ProcessUtilizationSample`s per process (it
    /// samples internally at sub-second cadence), so each pid typically appears
    /// several times per query. `last_gpu_sample_ts` is the newest sample
    /// timestamp (µs) consumed by the previous tick: it is passed as
    /// `last_seen_timestamp` so only NEW samples come back, and those are
    /// **averaged** per pid (see [`average_util_per_pid`]) — summing them would
    /// overcount utilisation by the number of buffered samples. On return it is
    /// advanced to the newest timestamp seen this tick.
    ///
    /// We read `dec_util` (NVDEC engine %) per pid. Unlike `nvidia-smi pmon -s u`,
    /// NVML's per-process utilisation works **without root**, so it actually
    /// populates inside the non-root (uid 1001) recorder container, which has the
    /// `utility` driver capability. Decode is the engine ffmpeg's `-c copy` recording
    /// children don't touch and the motion/sub-stream decoders do, so `dec_util` is
    /// the right per-camera GPU signal.
    ///
    /// The map is keyed by **container** PID (what the caller's `usage.pids`
    /// hold): when `/host/proc` is mounted each GPU host-pid is translated back
    /// to its container pid (see [`host_pid_to_container_pid`]); otherwise the
    /// raw host pid is used, which only matches when the recorder shares the host
    /// PID namespace.
    fn sample_gpu_by_pid(
        gpu_warned: &mut bool,
        last_gpu_sample_ts: &mut u64,
    ) -> Option<HashMap<i32, f64>> {
        let Some(nvml) = super::NVML.as_ref() else {
            warn_once_nvml(gpu_warned);
            return None;
        };

        let device = nvml.device_by_index(0).ok()?;

        // Ask only for samples NEWER than the previous tick's newest (the driver
        // filters on `last_seen_timestamp`). First tick: `None` = everything the
        // driver still buffers (a short trailing window). A `NotFound` (no
        // process has used the GPU since the cursor) is a legitimate empty
        // result, not a telemetry failure → return an empty map (all cameras 0%).
        let since = if *last_gpu_sample_ts == 0 {
            None
        } else {
            Some(*last_gpu_sample_ts)
        };
        let samples = match device.process_utilization_stats(since) {
            Ok(s) => s,
            Err(nvml_wrapper::error::NvmlError::NotFound) => return Some(HashMap::new()),
            Err(_) => return None,
        };

        // NVML pids are HOST pids. Translate them to the recorder's container
        // namespace when the host procfs is available; without it we can't
        // attribute GPU at all (host pids won't match container child pids), so
        // report NULL rather than a misleading 0%.
        let translate = std::path::Path::new(HOST_PROC).is_dir();
        // `?` early-returns None if we can't establish our own namespace, i.e.
        // can't safely translate host↔container pids. (Before the cursor is
        // advanced, so an aborted tick re-reads the same samples next time.)
        let my_ns = if translate { Some(my_pid_ns()?) } else { None };

        let mut per_pid: Vec<(i32, f64)> = Vec::with_capacity(samples.len());
        for s in samples {
            // Advance the cursor over EVERY returned sample — including ones we
            // skip below — so the next tick never re-consumes this window.
            *last_gpu_sample_ts = (*last_gpu_sample_ts).max(s.timestamp);
            let key = if translate {
                // Only host processes in OUR pid namespace yield a key; others
                // (Frigate, host daemons) are skipped — never misattributed.
                match host_pid_to_container_pid(s.pid, my_ns.as_deref()) {
                    Some(cpid) => cpid,
                    None => continue,
                }
            } else {
                // `pid` is u32; recorder pids fit in i32. Skip anything that
                // doesn't (can't match a child pid anyway).
                match i32::try_from(s.pid) {
                    Ok(pid) => pid,
                    Err(_) => continue,
                }
            };
            // dec_util is the NVDEC engine % for this process at this sample.
            per_pid.push((key, f64::from(s.dec_util)));
        }

        Some(average_util_per_pid(&per_pid))
    }

    /// Collapse `(pid, utilisation)` samples into one **mean** utilisation per
    /// pid.
    ///
    /// `process_utilization_stats` returns every buffered sample per process
    /// since the given timestamp, so one pid usually contributes several
    /// samples per tick. Summing them (the old behaviour) overcounted by the
    /// number of buffered samples (e.g. three 40% samples → "120%"); the mean
    /// is the process's utilisation over the tick. Pure arithmetic, split out
    /// for unit testing.
    fn average_util_per_pid(samples: &[(i32, f64)]) -> HashMap<i32, f64> {
        let mut acc: HashMap<i32, (f64, u32)> = HashMap::new();
        for &(pid, util) in samples {
            let entry = acc.entry(pid).or_insert((0.0, 0));
            entry.0 += util;
            entry.1 += 1;
        }
        acc.into_iter()
            .map(|(pid, (sum, n))| (pid, sum / f64::from(n)))
            .collect()
    }

    /// Read-only bind mount of the **host** `/proc` (the node_exporter pattern),
    /// used to translate NVML's host PIDs to the recorder's container PIDs.
    /// Absent ⇒ translation is skipped and GPU% degrades to `NULL`.
    const HOST_PROC: &str = "/host/proc";

    /// This recorder's own PID-namespace identity (`pid:[inode]`), read from
    /// `/proc/self/ns/pid`. Compared against a host process's namespace before
    /// trusting its inner PID, so a colliding container pid from a *different*
    /// namespace can't be folded into our totals. `None` only if the symlink is
    /// unreadable (shouldn't happen on Linux).
    fn my_pid_ns() -> Option<String> {
        std::fs::read_link("/proc/self/ns/pid")
            .ok()
            .map(|p| p.to_string_lossy().into_owned())
    }

    /// Translate a GPU **host** pid to its **container** pid within OUR pid
    /// namespace, via the host procfs `NSpid:` line.
    ///
    /// Returns `None` (skip this pid) when `/host/proc/<pid>` is gone, its
    /// `ns/pid` differs from `my_ns` (a different container or a host process),
    /// or `NSpid` has a single entry (not namespaced relative to us). The
    /// namespace gate is what makes a numerically-colliding container pid from
    /// e.g. Frigate impossible to misattribute.
    fn host_pid_to_container_pid(host_pid: u32, my_ns: Option<&str>) -> Option<i32> {
        // Cheap, decisive reject: must share our PID namespace. (As uid 1001 the
        // `ns/pid` symlink is only readable for our own same-uid children, so
        // other containers' processes fail here regardless.)
        let ns = std::fs::read_link(format!("{HOST_PROC}/{host_pid}/ns/pid")).ok()?;
        if Some(ns.to_string_lossy().as_ref()) != my_ns {
            return None;
        }
        let status = std::fs::read_to_string(format!("{HOST_PROC}/{host_pid}/status")).ok()?;
        for line in status.lines() {
            if let Some(rest) = line.strip_prefix("NSpid:") {
                // "NSpid:\t<host>\t…\t<container>" — the last field is the value
                // in the innermost (our) namespace. A process in our namespace,
                // viewed through the host procfs, always lists ≥2 entries; a lone
                // entry means it isn't nested below us, so skip it.
                let parts: Vec<&str> = rest.split_whitespace().collect();
                if parts.len() < 2 {
                    return None;
                }
                return parts.last()?.parse().ok();
            }
        }
        None
    }

    /// Log the "NVML unavailable" warning at most once.
    fn warn_once_nvml(gpu_warned: &mut bool) {
        if !*gpu_warned {
            *gpu_warned = true;
            warn!(
                "NVML init failed (no NVIDIA GPU/driver, or the container lacks the \
                 'utility' driver capability); reporting gpu_pct = NULL for all \
                 cameras. Warning logged once."
            );
        }
    }

    #[cfg(test)]
    mod tests {
        use super::{average_util_per_pid, cpu_pct_from_delta};

        /// CPU% must be computed against the MEASURED elapsed time: the same
        /// jiffies delta over a longer real gap is a lower utilisation. (The old
        /// code always divided by the nominal 10 s interval, overstating CPU%
        /// whenever a tick ran late or was skipped.)
        #[test]
        fn cpu_pct_uses_measured_elapsed_time() {
            // 500 jiffies = 5 s of CPU at USER_HZ=100. Over 5 s elapsed that is
            // one fully-busy core: 100%.
            assert!((cpu_pct_from_delta(500, 5.0) - 100.0).abs() < 1e-9);
            // The same 500 jiffies over a real gap of 20 s (one skipped tick) is
            // 25% — dividing by the nominal 10 s would have claimed 50%.
            assert!((cpu_pct_from_delta(500, 20.0) - 25.0).abs() < 1e-9);
            // No work → 0%, whatever the elapsed time.
            assert!(cpu_pct_from_delta(0, 7.3).abs() < 1e-9);
        }

        /// A pid's buffered NVML samples must be AVERAGED into one utilisation,
        /// never summed. (The old code summed: three 40% samples became "120%".)
        #[test]
        fn gpu_samples_are_averaged_per_pid_not_summed() {
            let samples = [(10, 30.0), (10, 50.0), (10, 40.0), (20, 12.0)];
            let map = average_util_per_pid(&samples);
            assert_eq!(map.len(), 2);
            // pid 10: mean(30, 50, 40) = 40 — a sum would have said 120.
            assert!((map[&10] - 40.0).abs() < 1e-9);
            // A single sample is its own mean.
            assert!((map[&20] - 12.0).abs() < 1e-9);
            // No samples at all → empty map (a valid all-0% state).
            assert!(average_util_per_pid(&[]).is_empty());
        }
    }
}

#[cfg(target_os = "linux")]
use linux::LinuxSampler;
