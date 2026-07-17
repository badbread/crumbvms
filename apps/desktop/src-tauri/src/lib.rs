// SPDX-License-Identifier: AGPL-3.0-or-later

//! Crumb Client: the Tauri shell over native libmpv video panes.
//!
//! The webview hosts the UI chrome (commercial-VMS-style: views navigator, layout
//! grid, Live/Playback tabs, timeline). Each video tile in the webview is just
//! a placeholder `<div>`; the actual video is a native Win32 child window that a
//! libmpv instance renders into (hardware-decoded), composited *over* the
//! WebView2 control and kept pixel-aligned with the placeholder.
//!
//! Because the native pane sits ON TOP of the webview, it receives the mouse —
//! so the panes use a real window class (`CS_DBLCLKS`) whose WndProc forwards
//! clicks / double-clicks to the UI as Tauri events (`pane-click`,
//! `pane-dblclick`). That lets the webview implement select / maximize even
//! though the video covers the tile.
//!
//! The UI drives the video through one reconciling command, [`sync_panes`]:
//! it passes the full set of `{id, url, rect}` it wants on screen, and the Rust
//! side creates / moves / reloads / destroys native panes to match.

#[cfg(target_os = "linux")]
mod linux_panes;
mod mpv;

use std::collections::HashMap;
#[cfg(windows)]
use std::collections::HashSet;
use std::sync::{LazyLock, Mutex, OnceLock};

use mpv::Mpv;
use serde::{Deserialize, Serialize};
#[cfg(windows)]
use tauri::Emitter;
use tauri::{AppHandle, Manager};

#[cfg(windows)]
use winapi::{
    shared::{
        minwindef::{LPARAM, LRESULT, TRUE, UINT, WPARAM},
        windef::{HGDIOBJ, HWND, POINT},
    },
    um::{
        libloaderapi::GetModuleHandleW,
        wingdi::{CombineRgn, CreateRectRgn, DeleteObject, RGN_DIFF},
        winuser::{
            CreateWindowExW, DefWindowProcW, DestroyWindow, LoadCursorW, MoveWindow,
            RegisterClassW, ReleaseCapture, ScreenToClient, SetCapture, SetWindowPos, SetWindowRgn,
            CS_DBLCLKS, CS_HREDRAW, CS_VREDRAW, HWND_TOP, IDC_ARROW, MK_LBUTTON, SWP_HIDEWINDOW,
            SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, WM_CAPTURECHANGED, WM_LBUTTONDBLCLK,
            WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_RBUTTONDOWN, WNDCLASSW,
            WS_CHILD, WS_CLIPSIBLINGS, WS_VISIBLE,
        },
    },
};

/// Wheel delta per notch. 120 is the Win32 `WHEEL_DELTA` and the de-facto
/// cross-platform convention (the Linux GLArea backend synthesizes ±120/notch),
/// so `zoom_pane` uses it on every platform — not Windows-gated.
const WHEEL_DELTA_UNIT: i32 = 120;

/// One native video pane: a native child surface + the mpv instance + the URL it's
/// playing. The surface differs per platform (Win32 child HWND on Windows; a
/// GtkGLArea fed by the mpv OpenGL render API on Linux), but the mpv-control fields
/// (`mpv`, `url`, `zoom_log2`, `pan_x`, `pan_y`) are common so the platform-neutral
/// commands (zoom/pan/seek/speed/mute/stats/…) compile and work on both.
#[cfg(not(target_os = "linux"))]
struct Pane {
    /// HWND stored as `isize` so the struct is `Send` (raw HWND is not).
    child_hwnd: isize,
    mpv: Mpv,
    url: String,
    /// Digital-zoom state (mpv video-zoom is log2: 0.0 = 1x). 0 = no zoom.
    zoom_log2: f64,
    /// Digital pan as a fraction of the window (mpv video-pan-x/y). 0 = centered.
    pan_x: f64,
    pan_y: f64,
}

/// Linux pane: a `GtkGLArea` (stored as a raw pointer `isize` so the struct stays
/// `Send`, like the Windows HWND) overlaid on the webview, plus the mpv render
/// context that draws into its FBO. See `linux_panes`.
#[cfg(target_os = "linux")]
struct Pane {
    /// The mpv OpenGL render context. Declared BEFORE `mpv` so it drops first
    /// (`mpv_render_context_free` must run before the core terminates). The GLArea
    /// widget itself lives in `linux_panes::AREAS` (keyed by pane id).
    render_ctx: mpv::RenderCtx,
    mpv: Mpv,
    url: String,
    zoom_log2: f64,
    pan_x: f64,
    pan_y: f64,
}

#[derive(Default)]
struct AppState {
    /// Keyed by caller-supplied pane id (e.g. the camera id or "slotN").
    panes: Mutex<HashMap<String, Pane>>,
    /// Serializes the multi-phase pane-lifecycle ops (sync/clear/reload). `sync_panes`
    /// RELEASES the `panes` data lock between its phases (so the watchdog / HUD / zoom
    /// commands aren't blocked during slow mpv init); this guard stops two lifecycle
    /// ops from interleaving in that gap. Lock order is ALWAYS sync_lock → panes
    /// → PANE_IDS. The HWND→id map (`PANE_IDS`, a separate static) is taken WHILE
    /// holding `panes` in sync_panes/clear_panes; the WndProc takes only PANE_IDS.
    /// Never take PANE_IDS before `panes` (would invert the order and can deadlock).
    /// Today this holds only by single-thread UI affinity — see review R7 to make
    /// it structural (Arc<Mpv> + lock-free FFI, fold the map into AppState).
    sync_lock: Mutex<()>,
}

/// A pane the UI wants on screen: an id, a stream URL, and its rect in CSS px
/// (the placeholder div's `getBoundingClientRect`).
#[derive(Clone, Deserialize)]
struct PaneSpec {
    id: String,
    url: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    /// Lower-left corner notch (CSS px) to cut out of this pane so a DOM control
    /// (the PTZ wheel) shows through there. 0 = no notch (full rectangle). Read by
    /// the Windows backend's `apply_corner_notch`; Linux uses an mpv overlay instead.
    #[serde(default)]
    #[cfg_attr(not(windows), allow(dead_code))]
    notch_w: f64,
    #[serde(default)]
    #[cfg_attr(not(windows), allow(dead_code))]
    notch_h: f64,
    /// Keep the current digital zoom/pan when this pane's URL changes. A playback
    /// segment advance loads the SAME camera's next file, so zeroing the zoom would
    /// snap the operator's zoomed-in view back to full frame on every boundary.
    /// Default false — a LIVE camera SWITCH (different camera) still resets zoom.
    #[serde(default)]
    preserve_zoom: bool,
}

/// Per-pane digital-zoom state returned to the UI (so it can decide drag = box-zoom
/// at 1× vs drag = pan when zoomed, and keep its mirror in sync across resets).
#[derive(Serialize)]
struct PaneZoom {
    id: String,
    zoom: f64,
}

// ─── globals for the native WndProc ─────────────────────────────────────────
//
// The WndProc is a bare `extern "system"` fn with no user context, so it reads
// these process-globals to (a) map an HWND back to its pane id and (b) reach the
// Tauri AppHandle to emit events.

/// App handle, set once during setup so the pane WndProc can emit events.
static APP: OnceLock<AppHandle> = OnceLock::new();

/// Map of child HWND (as isize) → pane id, for click forwarding.
#[cfg(windows)]
static PANE_IDS: LazyLock<Mutex<HashMap<isize, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// ─── Win32 helpers ──────────────────────────────────────────────────────────

#[cfg(windows)]
fn wide(s: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

/// WndProc for pane windows: forward mouse clicks to the UI, delegate the rest.
#[cfg(windows)]
unsafe extern "system" fn pane_wndproc(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_LBUTTONDOWN => {
            // Capture the mouse so the drag's WM_MOUSEMOVE/WM_LBUTTONUP keep
            // coming back to THIS pane even when the cursor leaves the tile —
            // otherwise pane-dragend is missed and the JS drag state leaks.
            SetCapture(hwnd);
            // Forward left-click + position (pane-client px) so the webview can
            // both select the tile and drive PTZ click-to-center on the video.
            let x = (lparam & 0xFFFF) as i16 as i32;
            let y = ((lparam >> 16) & 0xFFFF) as i16 as i32;
            emit_pane_click(hwnd, x, y);
            0
        }
        WM_LBUTTONDBLCLK => {
            emit_pane_event(hwnd, "pane-dblclick");
            0
        }
        WM_MOUSEMOVE => {
            // Forward moves only while the left button is held — a drag. Used to
            // pan a digitally-zoomed pane. lParam is client px.
            if (wparam & MK_LBUTTON as WPARAM) != 0 {
                let x = (lparam & 0xFFFF) as i16 as i32;
                let y = ((lparam >> 16) & 0xFFFF) as i16 as i32;
                emit_pane_drag(hwnd, x, y);
            }
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_LBUTTONUP => {
            ReleaseCapture();
            emit_pane_event(hwnd, "pane-dragend");
            0
        }
        WM_CAPTURECHANGED => {
            // Capture stolen (e.g. another window) — end any drag cleanly.
            emit_pane_event(hwnd, "pane-dragend");
            0
        }
        WM_RBUTTONDOWN => {
            // Forward right-click + position so the webview can show a context menu.
            let x = (lparam & 0xFFFF) as i16 as i32;
            let y = ((lparam >> 16) & 0xFFFF) as i16 as i32;
            emit_pane_rightclick(hwnd, x, y);
            0
        }
        WM_MOUSEWHEEL => {
            // wParam HIWORD = signed wheel delta (multiple of 120; precision
            // devices send sub-120 deltas). Forward the RAW delta (don't truncate
            // with /120 — that drops sub-notch scrolls); zoom_pane scales by /120.
            // lParam holds SCREEN coords for the wheel message (unlike the button
            // messages, which are client) — convert to client before forwarding.
            let raw = ((wparam >> 16) & 0xFFFF) as i16 as i32; // +forward = zoom in
            let mut pt = POINT {
                x: (lparam & 0xFFFF) as i16 as i32,
                y: ((lparam >> 16) & 0xFFFF) as i16 as i32,
            };
            ScreenToClient(hwnd, &mut pt);
            emit_pane_wheel(hwnd, raw, pt.x, pt.y);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Look up the pane id for `hwnd` and emit `event` with it to the webview.
#[cfg(windows)]
fn emit_pane_event(hwnd: HWND, event: &str) {
    let id = PANE_IDS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(&(hwnd as isize))
        .cloned();
    if let (Some(id), Some(app)) = (id, APP.get()) {
        let _ = app.emit(event, id);
    }
}

/// Emit a left-click on a pane with the click position (pane-client physical
/// px). The webview uses it to select the tile and, for PTZ cameras, to drive
/// click-to-center / click-to-pan on the video.
#[cfg(windows)]
fn emit_pane_click(hwnd: HWND, x: i32, y: i32) {
    let id = PANE_IDS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(&(hwnd as isize))
        .cloned();
    if let (Some(id), Some(app)) = (id, APP.get()) {
        let _ = app.emit(
            "pane-click",
            serde_json::json!({ "id": id, "x": x, "y": y }),
        );
    }
}

/// Emit a right-click on a pane with the click position (pane-client physical
/// px), so the webview can position a context menu over the tile.
#[cfg(windows)]
fn emit_pane_rightclick(hwnd: HWND, x: i32, y: i32) {
    let id = PANE_IDS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(&(hwnd as isize))
        .cloned();
    if let (Some(id), Some(app)) = (id, APP.get()) {
        let _ = app.emit(
            "pane-rightclick",
            serde_json::json!({ "id": id, "x": x, "y": y }),
        );
    }
}

/// Emit a left-drag move on a pane (pane-client px) — used to pan a zoomed pane.
#[cfg(windows)]
fn emit_pane_drag(hwnd: HWND, x: i32, y: i32) {
    let id = PANE_IDS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(&(hwnd as isize))
        .cloned();
    if let (Some(id), Some(app)) = (id, APP.get()) {
        let _ = app.emit("pane-drag", serde_json::json!({ "id": id, "x": x, "y": y }));
    }
}

/// Emit a mouse-wheel event on a pane: signed `delta` notches + cursor position
/// (pane-client physical px). The webview branches on PTZ-capability — PTZ
/// optical zoom vs. digital (mpv `video-zoom`) zoom.
#[cfg(windows)]
fn emit_pane_wheel(hwnd: HWND, delta: i32, x: i32, y: i32) {
    let id = PANE_IDS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(&(hwnd as isize))
        .cloned();
    if let (Some(id), Some(app)) = (id, APP.get()) {
        let _ = app.emit(
            "pane-wheel",
            serde_json::json!({ "id": id, "delta": delta, "x": x, "y": y }),
        );
    }
}

/// The registered pane window class name (registered once, lazily).
#[cfg(windows)]
static PANE_CLASS: LazyLock<Vec<u16>> = LazyLock::new(|| unsafe {
    let name = wide("CrumbPaneClass");
    let wc = WNDCLASSW {
        style: CS_DBLCLKS | CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(pane_wndproc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: GetModuleHandleW(std::ptr::null()) as _,
        hIcon: std::ptr::null_mut(),
        hCursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW),
        hbrBackground: std::ptr::null_mut(), // mpv paints every pixel; no erase
        lpszMenuName: std::ptr::null(),
        lpszClassName: name.as_ptr(),
    };
    // Ignore the return: a duplicate registration just means it's already there.
    RegisterClassW(&wc);
    name
});

/// The top-level window's HWND, via raw-window-handle (version-stable).
#[cfg(windows)]
fn parent_hwnd(win: &tauri::WebviewWindow) -> Result<HWND, String> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let handle = win.window_handle().map_err(|e| e.to_string())?;
    match handle.as_raw() {
        RawWindowHandle::Win32(h) => Ok(h.hwnd.get() as HWND),
        _ => Err("main window is not a Win32 window".into()),
    }
}

/// Create a child window (our pane class, so it gets double-click messages).
#[cfg(windows)]
unsafe fn create_child(parent: HWND, x: i32, y: i32, w: i32, h: i32) -> HWND {
    CreateWindowExW(
        0,
        PANE_CLASS.as_ptr(),
        std::ptr::null(),
        WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
        x,
        y,
        w,
        h,
        parent,
        std::ptr::null_mut(),
        GetModuleHandleW(std::ptr::null()) as _,
        std::ptr::null_mut(),
    )
}

/// Configure a freshly created mpv instance for a tile and start playback.
/// Windows only (`wid` window embedding); Linux uses `linux_panes` + the render API.
#[cfg(windows)]
fn configure_mpv(child_hwnd: isize, url: &str) -> Result<Mpv, String> {
    let mpv = Mpv::create(&libmpv_path())?;
    mpv.set_option("wid", &child_hwnd.to_string())?;
    mpv.set_option("hwdec", "auto")?;
    mpv.set_option("vo", "gpu")?;
    // Do NOT use profile=low-latency: it sets cache=no + fflags=nobuffer (ZERO
    // buffering), which makes high-bitrate RTSP MAIN streams freeze on the
    // slightest network jitter (the desktop-only stall — Frigate and Android both
    // buffer and ride it out). A small jitter buffer trades ~1-2 s of latency for
    // stable live video, which is the right call for a surveillance wall.
    mpv.set_option("cache", "yes")?;
    mpv.set_option("demuxer-readahead-secs", "2.0")?;
    // Bound the demuxer cache (M1): a live wall never seeks backward, so keep the back
    // buffer tiny — the default would grow to tens of MiB PER pane over a long session
    // (×16 panes = real RAM). 32 MiB forward is ~16× the 2 s readahead at 8 Mbps, so the
    // jitter buffer is never byte-starved.
    mpv.set_option("demuxer-max-bytes", "32MiB")?;
    mpv.set_option("demuxer-max-back-bytes", "1MiB")?;
    mpv.set_option("rtsp-transport", "tcp")?;
    mpv.set_option("keep-open", "yes")?;
    mpv.set_option("prefetch-playlist", "yes")?;
    mpv.set_option("gapless-audio", "yes")?;
    // Stream resilience: give up on a dead RTSP feed after ~10 s of no data and
    // let FFmpeg attempt reconnects, so a transient drop recovers instead of
    // freezing on the last frame. A hard stall is also caught by the frontend
    // watchdog (live_pane_progress → reload_pane).
    mpv.set_option("network-timeout", "10")?;
    // analyzeduration/probesize: FFmpeg's stream-probe phase otherwise gates the
    // FIRST frame by ~5 s (libavformat's default analyzeduration) — and since every
    // wall pane probes in parallel, the whole wall stays black for ~5 s, then fills
    // in at once. go2rtc re-streams clean single-track H.264/H.265, so 0.5 s / 0.5 MB
    // is ample to detect the codec; this is the dominant time-to-first-frame win.
    // (M6) Dropped the FFmpeg `reconnect=*` flags that used to be here — they are
    // libavformat HTTP-protocol options and are no-ops for `rtsp://` URLs. RTSP
    // resilience is handled by `network-timeout` above + the frontend stall watchdog.
    let _ = mpv.set_option("demuxer-lavf-o", "analyzeduration=500000,probesize=500000");
    // Muted by default — a full wall of audio is chaos. The UI unmutes the
    // focused/maximized camera (play-on-focus) or on the speaker toggle.
    mpv.set_option("mute", "yes")?;
    mpv.initialize()?;
    mpv.loadfile(url)?;
    Ok(mpv)
}

/// Carve a lower-left corner notch out of a pane's window region (so DOM behind
/// it — the PTZ wheel — is visible + clickable there), or restore the full
/// rectangle when `nw`/`nh` are 0. Called on every sync, so it both applies and
/// clears as the active PTZ tile changes.
#[cfg(windows)]
unsafe fn apply_corner_notch(hwnd: HWND, pw: i32, ph: i32, nw: i32, nh: i32) {
    if nw <= 0 || nh <= 0 || nw >= pw || nh >= ph {
        // No (valid) notch → clear any previous region back to a full rectangle.
        SetWindowRgn(hwnd, std::ptr::null_mut(), TRUE);
        return;
    }
    let full = CreateRectRgn(0, 0, pw, ph);
    let notch = CreateRectRgn(0, ph - nh, nw, ph); // lower-left corner, pane-local
    CombineRgn(full, full, notch, RGN_DIFF);
    DeleteObject(notch as HGDIOBJ); // combined into `full`; free the temp
                                    // The window takes ownership of `full` — do NOT delete it here.
    SetWindowRgn(hwnd, full, TRUE);
}

/// CSS px → physical px (DPI scale). Windows positions child HWNDs in physical px;
/// Linux uses logical-px widget geometry (see `linux_panes::apply_rect`).
#[cfg(windows)]
fn scale_rect(x: f64, y: f64, w: f64, h: f64, scale: f64) -> (i32, i32, i32, i32) {
    (
        (x * scale).round() as i32,
        (y * scale).round() as i32,
        (w * scale).round().max(1.0) as i32,
        (h * scale).round().max(1.0) as i32,
    )
}

/// Path to the libmpv shared library — next to the exe, else let the OS loader
/// resolve it by name. `libmpv-2.dll` on Windows, `libmpv.so.2` on Linux.
fn libmpv_path() -> String {
    #[cfg(target_os = "linux")]
    const LIB: &str = "libmpv.so.2";
    #[cfg(not(target_os = "linux"))]
    const LIB: &str = "libmpv-2.dll";
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let p = dir.join(LIB);
            if p.exists() {
                return p.to_string_lossy().into_owned();
            }
        }
    }
    LIB.to_string()
}

/// Run a closure on the main (UI) thread and return its `Result`.
fn on_main<F, T>(app: &AppHandle, f: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String> + Send + 'static,
    T: Send + 'static,
{
    let (tx, rx) = std::sync::mpsc::channel();
    app.run_on_main_thread(move || {
        let _ = tx.send(f());
    })
    .map_err(|e| e.to_string())?;
    // Bounded wait (review R5): a busy/blocked UI thread — e.g. a slow
    // mpv_terminate_destroy running on it — must not park this IPC-worker thread
    // forever, which would also freeze every other pane command queued behind
    // sync_lock. On timeout return a recoverable Err so the JS watchdog retries
    // rather than the app hanging.
    rx.recv_timeout(std::time::Duration::from_secs(10))
        .map_err(|e| format!("main-thread op did not complete: {e}"))?
}

// ─── Tauri commands ─────────────────────────────────────────────────────────

/// Reconcile the live set of native panes to exactly `panes`.
#[tauri::command]
#[allow(clippy::type_complexity)] // Windows phase-1 returns a (mpvs, hwnds, new) tuple
fn sync_panes(app: AppHandle, panes: Vec<PaneSpec>) -> Result<Vec<PaneZoom>, String> {
    #[cfg(target_os = "linux")]
    {
        linux_panes::sync_panes(&app, panes)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (&app, &panes);
        Err("native panes are not implemented on this platform".into())
    }
    #[cfg(windows)]
    {
        // Serialize the whole multi-phase op. The panes DATA lock is released between
        // phases (so the watchdog / HUD / zoom commands run during slow mpv init); this
        // guard stops a second sync/clear/reload from interleaving in that gap.
        let st = app.state::<AppState>();
        let _sync = st.sync_lock.lock().unwrap_or_else(|p| p.into_inner());

        // ── PHASE 1 (UI thread, brief data lock): WINDOWS only ───────────────────────
        // Win32 window ops are thread-affine (UI thread) but fast: create new child
        // windows, move/reload existing panes, and detach stale panes from the map. The
        // SLOW mpv init/teardown is deferred to phase 2 (off the UI thread + off the
        // data lock). Returns (stale mpvs to drop, stale windows to destroy, new
        // (id,hwnd,url) tuples whose mpv still needs initializing).
        let app1 = app.clone();
        let specs1 = panes.clone();
        let (stale_mpvs, stale_hwnds, new_panes): (
            Vec<Mpv>,
            Vec<isize>,
            Vec<(String, isize, String)>,
        ) = on_main(&app, move || {
            let win = app1.get_webview_window("main").ok_or("no main window")?;
            let scale = win.scale_factor().map_err(|e| e.to_string())?;
            let parent = parent_hwnd(&win)?;
            let state = app1.state::<AppState>();
            let mut map = state.panes.lock().unwrap_or_else(|p| p.into_inner());

            let wanted: HashSet<&str> = specs1.iter().map(|p| p.id.as_str()).collect();

            // Detach stale panes from the map (mpv drop + window destroy deferred).
            let stale_ids: Vec<String> = map
                .keys()
                .filter(|k| !wanted.contains(k.as_str()))
                .cloned()
                .collect();
            let mut stale_hwnds: Vec<isize> = Vec::new();
            let mut stale_mpvs: Vec<Mpv> = Vec::new();
            for id in stale_ids {
                if let Some(pane) = map.remove(&id) {
                    PANE_IDS
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .remove(&pane.child_hwnd);
                    stale_hwnds.push(pane.child_hwnd);
                    stale_mpvs.push(pane.mpv);
                }
            }

            // Update EXISTING panes (move + reload-on-url-change) — fast.
            for spec in &specs1 {
                if let Some(pane) = map.get_mut(&spec.id) {
                    let (px, py, pw, ph) = scale_rect(spec.x, spec.y, spec.w, spec.h, scale);
                    unsafe {
                        let hwnd = pane.child_hwnd as HWND;
                        MoveWindow(hwnd, px, py, pw, ph, TRUE);
                        SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
                    }
                    if pane.url != spec.url {
                        pane.mpv.loadfile(&spec.url)?;
                        // A replacing loadfile is a jump / camera-switch, never a
                        // gapless boundary advance (those skip sync_panes). Drop any
                        // segment the playback prefetch appended for the OLD position
                        // so mpv can't auto-advance to it after this file ends. No-op
                        // for live panes (single-entry playlists).
                        let _ = pane.mpv.playlist_clear();
                        pane.url = spec.url.clone();
                        if spec.preserve_zoom {
                            // Same camera, next playback segment — keep the
                            // operator's digital zoom/pan. Re-assert the stored
                            // transform in case the loadfile perturbed it.
                            let (z, px, py) = (pane.zoom_log2, pane.pan_x, pane.pan_y);
                            let _ = pane.mpv.set_property("video-zoom", &format!("{z}"));
                            let _ = pane.mpv.set_property("video-pan-x", &format!("{px}"));
                            let _ = pane.mpv.set_property("video-pan-y", &format!("{py}"));
                        } else {
                            // New stream → reset digital zoom to 1x centered.
                            pane.zoom_log2 = 0.0;
                            pane.pan_x = 0.0;
                            pane.pan_y = 0.0;
                            let _ = pane.mpv.set_property("video-zoom", "0");
                            let _ = pane.mpv.set_property("video-pan-x", "0");
                            let _ = pane.mpv.set_property("video-pan-y", "0");
                        }
                    }
                }
            }

            // Create NEW child windows (fast, thread-affine); mpv init in phase 2.
            let mut new_panes: Vec<(String, isize, String)> = Vec::new();
            for spec in &specs1 {
                if map.contains_key(&spec.id) {
                    continue;
                }
                let (px, py, pw, ph) = scale_rect(spec.x, spec.y, spec.w, spec.h, scale);
                let child = unsafe { create_child(parent, px, py, pw, ph) };
                if child.is_null() {
                    return Err("CreateWindowExW returned null".into());
                }
                unsafe {
                    SetWindowPos(
                        child,
                        HWND_TOP,
                        0,
                        0,
                        0,
                        0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
                    );
                }
                new_panes.push((spec.id.clone(), child as isize, spec.url.clone()));
            }
            Ok((stale_mpvs, stale_hwnds, new_panes))
        })?;

        // ── PHASE 2 (worker thread, NO data lock, NO UI thread): mpv teardown + init ─
        // The slow part. Running it here keeps WebView2 painting and leaves the panes
        // data lock free for the watchdog/HUD/zoom while panes come up. Both teardown
        // (mpv_terminate_destroy) and init (mpv create+initialize+loadfile) run in
        // parallel so the wall comes up in ~one pane's time, not cascading.
        let inited: Vec<(String, isize, String, Result<Mpv, String>)> = std::thread::scope(|s| {
            for mpv in stale_mpvs {
                s.spawn(move || drop(mpv)); // mpv_terminate_destroy off the UI thread
            }
            let handles: Vec<_> = new_panes
                .iter()
                .map(|(id, hwnd, url)| {
                    let hwnd = *hwnd;
                    let url_thread = url.clone();
                    (
                        id.clone(),
                        hwnd,
                        url.clone(),
                        s.spawn(move || configure_mpv(hwnd, &url_thread)),
                    )
                })
                .collect();
            handles
                .into_iter()
                .map(|(id, hwnd, url, h)| {
                    let res = h
                        .join()
                        .unwrap_or_else(|_| Err("mpv init thread panicked".into()));
                    (id, hwnd, url, res)
                })
                .collect()
        });

        // ── PHASE 3 (UI thread, brief data lock): insert/destroy windows + notches ───
        let app3 = app.clone();
        let specs3 = panes;
        on_main(&app, move || {
            let win = app3.get_webview_window("main").ok_or("no main window")?;
            let scale = win.scale_factor().map_err(|e| e.to_string())?;
            let state = app3.state::<AppState>();
            let mut map = state.panes.lock().unwrap_or_else(|p| p.into_inner());

            // Insert successfully-initialized new panes; destroy windows of failed inits.
            for (id, hwnd, url, res) in inited {
                match res {
                    Ok(mpv) => {
                        PANE_IDS
                            .lock()
                            .unwrap_or_else(|p| p.into_inner())
                            .insert(hwnd, id.clone());
                        map.insert(
                            id,
                            Pane {
                                child_hwnd: hwnd,
                                mpv,
                                url,
                                zoom_log2: 0.0,
                                pan_x: 0.0,
                                pan_y: 0.0,
                            },
                        );
                    }
                    Err(e) => {
                        eprintln!("sync_panes: mpv init failed for {id}: {e}");
                        unsafe { DestroyWindow(hwnd as HWND) };
                    }
                }
            }

            // Destroy the (now mpv-detached) stale windows.
            for hwnd in stale_hwnds {
                unsafe { DestroyWindow(hwnd as HWND) };
            }

            // Apply (or clear) the lower-left PTZ-wheel notch for each pane.
            for spec in &specs3 {
                if let Some(pane) = map.get(&spec.id) {
                    let (_, _, pw, ph) = scale_rect(spec.x, spec.y, spec.w, spec.h, scale);
                    let nw = (spec.notch_w * scale).round() as i32;
                    let nh = (spec.notch_h * scale).round() as i32;
                    unsafe { apply_corner_notch(pane.child_hwnd as HWND, pw, ph, nw, nh) };
                }
            }
            // Return the post-sync zoom state of every pane so the UI mirror stays
            // accurate across stream-change resets (drag = box-zoom vs pan decision).
            let zooms: Vec<PaneZoom> = map
                .iter()
                .map(|(id, p)| PaneZoom {
                    id: id.clone(),
                    zoom: p.zoom_log2,
                })
                .collect();
            Ok(zooms)
        })
    }
}

/// Destroy all native panes (e.g. when leaving the video view).
#[tauri::command]
fn clear_panes(app: AppHandle) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        linux_panes::clear_panes(&app)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = &app;
        Ok(())
    }
    #[cfg(windows)]
    {
        // Serialize with sync_panes/reload_pane (lock order sync_lock → panes). Held
        // across BOTH phases below (like sync_panes) so a second lifecycle op can't
        // interleave while the mpv teardown is still running on its own thread.
        let st = app.state::<AppState>();
        let sync_guard = st.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
        let app2 = app.clone();
        // ── PHASE 1 (UI thread, brief data lock): drain the map + destroy windows.
        // Window destruction is thread-affine but fast; the SLOW part
        // (mpv_terminate_destroy) is deferred to phase 2, off the UI thread.
        let mpvs: Vec<Mpv> = on_main(&app, move || {
            let state = app2.state::<AppState>();
            let mut hwnds: Vec<isize> = Vec::new();
            let mut mpvs: Vec<Mpv> = Vec::new();
            {
                let mut map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
                let mut ids = PANE_IDS.lock().unwrap_or_else(|p| p.into_inner());
                for (_, pane) in map.drain() {
                    ids.remove(&pane.child_hwnd);
                    hwnds.push(pane.child_hwnd);
                    mpvs.push(pane.mpv);
                }
            }
            for hwnd in hwnds {
                unsafe { DestroyWindow(hwnd as HWND) };
            }
            Ok(mpvs)
        })?;

        // ── PHASE 2 (worker thread, NOT the UI thread): drop the mpv instances in
        // parallel. This is what actually runs `mpv_terminate_destroy`, the slow
        // part — previously this ran inside a `thread::scope` INSIDE the `on_main`
        // closure, which still blocked the UI thread until every drop finished (a
        // 16-pane wall froze the whole webview for that long). Spawning here lets
        // `clear_panes` return immediately; `sync_lock` is held until the scope
        // (and thus every drop) completes, so a following sync_panes/reload_pane
        // still can't interleave with this teardown.
        std::thread::scope(|s| {
            for mpv in mpvs {
                s.spawn(move || drop(mpv));
            }
        });
        drop(sync_guard);
        Ok(())
    }
}

/// Hide or show native panes WITHOUT destroying them or their mpv instances.
///
/// `ids = None` targets ALL panes (the modal-occlusion case: while a DOM modal is
/// up, `SWP_HIDEWINDOW` removes the HWND_TOP panes from the screen but keeps each
/// mpv instance alive + decoding, so closing the modal brings the streams back
/// instantly with no reconnect freeze). `ids = Some([...])` targets just those
/// panes — used by the Live-tab reconnect to keep a reconnecting pane HIDDEN
/// behind a DOM "Connecting…" placeholder until its first live frame is ready,
/// then reveal it (no black-screen cascade as each stream re-opens). On show, the
/// pane is re-raised to HWND_TOP (the webview may have repainted over its old
/// z-order while it was hidden).
#[tauri::command]
fn set_panes_hidden(app: AppHandle, hidden: bool, ids: Option<Vec<String>>) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        linux_panes::set_panes_hidden(&app, hidden, ids)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (&app, hidden, ids);
        Ok(())
    }
    #[cfg(windows)]
    {
        let app2 = app.clone();
        on_main(&app, move || {
            let filter: Option<HashSet<String>> = ids.map(|v| v.into_iter().collect());
            let state = app2.state::<AppState>();
            let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
            for (id, pane) in map.iter() {
                if let Some(f) = &filter {
                    if !f.contains(id) {
                        continue;
                    }
                }
                let hwnd = pane.child_hwnd as HWND;
                unsafe {
                    if hidden {
                        SetWindowPos(
                            hwnd,
                            0 as HWND,
                            0,
                            0,
                            0,
                            0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_HIDEWINDOW,
                        );
                    } else {
                        // Re-raise to HWND_TOP and show in one call.
                        SetWindowPos(
                            hwnd,
                            HWND_TOP,
                            0,
                            0,
                            0,
                            0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
                        );
                    }
                }
            }
            Ok(())
        })
    }
}

/// Pause/resume a single pane by id.
#[tauri::command]
fn set_pane_paused(app: AppHandle, id: String, paused: bool) -> Result<(), String> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get(&id).ok_or("no such pane")?;
    pane.mpv
        .set_property("pause", if paused { "yes" } else { "no" })
}

/// Per-pane playback progress (mpv `time-pos`, seconds) for the live stall
/// watchdog. The frontend samples this every few seconds; a live pane whose
/// time-pos hasn't advanced is frozen and gets `reload_pane`d.
#[tauri::command]
fn live_pane_progress(app: AppHandle) -> HashMap<String, f64> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let mut out = HashMap::new();
    for (id, pane) in map.iter() {
        let t = pane
            .mpv
            .get_property("time-pos")
            .and_then(|s| s.parse::<f64>().ok())
            .unwrap_or(-1.0);
        out.insert(id.clone(), t);
    }
    out
}

/// Per-pane mpv telemetry for the performance HUD.
///
/// Cumulative counters (`drop_count`, `dec_drop_count`) — the frontend derives
/// per-second rates from deltas between polls. `hwdec` is the mpv
/// `hwdec-current` value (`"cuda"`, `"no"`, `""` while loading). `decode_fps` is
/// the estimated post-filter output rate; compare to `container_fps` (source).
#[derive(Serialize, Clone)]
struct PaneStats {
    width: i64,
    height: i64,
    decode_fps: f64,
    container_fps: f64,
    drop_count: i64,
    dec_drop_count: i64,
    hwdec: String,
    video_bitrate: f64,
    cache_secs: f64,
    avsync: f64,
}

/// Read mpv telemetry for every live pane (resolution, decode fps, dropped-frame
/// counts, hardware-decode status, bitrate, cache, A/V sync). Polled by the HUD;
/// all reads are cheap property lookups on the existing mpv instances.
#[tauri::command]
fn pane_stats(app: AppHandle) -> HashMap<String, PaneStats> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let mut out = HashMap::new();
    for (id, pane) in map.iter() {
        let getf = |name: &str| {
            pane.mpv
                .get_property(name)
                .and_then(|s| s.parse::<f64>().ok())
        };
        let geti = |name: &str| {
            pane.mpv
                .get_property(name)
                .and_then(|s| s.parse::<i64>().ok())
        };
        out.insert(
            id.clone(),
            PaneStats {
                width: geti("width")
                    .or_else(|| geti("video-params/w"))
                    .unwrap_or(0),
                height: geti("height")
                    .or_else(|| geti("video-params/h"))
                    .unwrap_or(0),
                decode_fps: getf("estimated-vf-fps").unwrap_or(0.0),
                container_fps: getf("container-fps").unwrap_or(0.0),
                drop_count: geti("frame-drop-count").unwrap_or(0),
                dec_drop_count: geti("decoder-frame-drop-count").unwrap_or(0),
                hwdec: pane.mpv.get_property("hwdec-current").unwrap_or_default(),
                video_bitrate: getf("video-bitrate").unwrap_or(0.0),
                cache_secs: getf("demuxer-cache-duration").unwrap_or(0.0),
                avsync: getf("avsync").unwrap_or(0.0),
            },
        );
    }
    out
}

/// Host-level telemetry for the performance HUD: the client process's cumulative
/// CPU time (the frontend derives % from deltas) and resident memory, plus
/// best-effort NVIDIA GPU stats via NVML (all `None` on a non-NVIDIA host).
#[derive(Serialize, Clone, Default)]
struct HostStats {
    cpu_time_secs: f64,
    mem_mb: f64,
    num_cpus: u32,
    gpu_util: Option<f64>,
    gpu_dec_util: Option<f64>,
    gpu_mem_mb: Option<f64>,
    gpu_mem_total_mb: Option<f64>,
    gpu_name: Option<String>,
}

/// NVML handle, initialised once (loads `nvml.dll` at runtime via libloading).
/// `None` when no NVIDIA driver/GPU is present — the HUD shows "—" for GPU.
/// Shared HTTP client for export downloads — built once so a batch export reuses
/// the connection pool / TLS session instead of rebuilding a Client per file
/// (review S6).
static HTTP: LazyLock<reqwest::Client> = LazyLock::new(reqwest::Client::new);

static NVML: LazyLock<Option<nvml_wrapper::Nvml>> =
    LazyLock::new(|| nvml_wrapper::Nvml::init().ok());

/// Sample the client host's CPU/memory (winapi) + GPU (NVML, best-effort).
#[tauri::command]
fn host_stats() -> HostStats {
    let mut s = HostStats {
        num_cpus: std::thread::available_parallelism()
            .map(|n| n.get() as u32)
            .unwrap_or(1),
        ..Default::default()
    };

    #[cfg(windows)]
    unsafe {
        use winapi::shared::minwindef::FILETIME;
        use winapi::um::processthreadsapi::{GetCurrentProcess, GetProcessTimes};
        use winapi::um::psapi::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};

        let proc = GetCurrentProcess();
        let zero = FILETIME {
            dwLowDateTime: 0,
            dwHighDateTime: 0,
        };
        let (mut creation, mut exit, mut kernel, mut user) = (zero, zero, zero, zero);
        if GetProcessTimes(proc, &mut creation, &mut exit, &mut kernel, &mut user) != 0 {
            let to_u64 =
                |ft: FILETIME| (u64::from(ft.dwHighDateTime) << 32) | u64::from(ft.dwLowDateTime);
            // kernel + user time, in 100 ns units → seconds.
            s.cpu_time_secs = (to_u64(kernel) + to_u64(user)) as f64 / 1e7;
        }
        let mut pmc: PROCESS_MEMORY_COUNTERS = std::mem::zeroed();
        pmc.cb = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
        if GetProcessMemoryInfo(proc, &mut pmc, pmc.cb) != 0 {
            s.mem_mb = pmc.WorkingSetSize as f64 / 1e6;
        }
    }

    #[cfg(target_os = "linux")]
    {
        // /proc/self/stat: utime (field 14) + stime (field 15) in USER_HZ ticks.
        // comm (field 2) may contain spaces/parens, so split after the last ')'.
        if let Ok(stat) = std::fs::read_to_string("/proc/self/stat") {
            if let Some((_, rest)) = stat.rsplit_once(')') {
                let f: Vec<&str> = rest.split_whitespace().collect();
                if f.len() > 12 {
                    let utime: f64 = f[11].parse().unwrap_or(0.0);
                    let stime: f64 = f[12].parse().unwrap_or(0.0);
                    s.cpu_time_secs = (utime + stime) / 100.0; // USER_HZ = 100
                }
            }
        }
        // /proc/self/statm: field 2 = resident set size in pages.
        if let Ok(statm) = std::fs::read_to_string("/proc/self/statm") {
            if let Some(res) = statm.split_whitespace().nth(1) {
                let pages: f64 = res.parse().unwrap_or(0.0);
                s.mem_mb = pages * 4096.0 / 1e6; // page size 4 KiB
            }
        }
    }

    if let Some(nvml) = NVML.as_ref() {
        if let Ok(dev) = nvml.device_by_index(0) {
            if let Ok(u) = dev.utilization_rates() {
                s.gpu_util = Some(f64::from(u.gpu));
            }
            if let Ok(d) = dev.decoder_utilization() {
                s.gpu_dec_util = Some(f64::from(d.utilization));
            }
            if let Ok(m) = dev.memory_info() {
                s.gpu_mem_mb = Some(m.used as f64 / 1e6);
                s.gpu_mem_total_mb = Some(m.total as f64 / 1e6);
            }
            if let Ok(n) = dev.name() {
                s.gpu_name = Some(n);
            }
        }
    }

    s
}

/// Reload a pane's source (reconnect a frozen live stream) by re-issuing
/// `loadfile` on its stored URL.
#[tauri::command]
fn reload_pane(app: AppHandle, id: String) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        linux_panes::reload_pane(&app, id)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (&app, &id);
        Err("native panes are not implemented on this platform".into())
    }
    #[cfg(windows)]
    {
        // A plain `loadfile` reuses the SAME mpv instance, which doesn't reliably
        // recover a wedged RTSP demuxer (the watchdog couldn't clear a stall, but
        // leaving + returning to Live — a full teardown/recreate — could). So fully
        // recreate the mpv instance on the same child window: drop the stuck one, then
        // build a fresh one. Runs on the UI thread (mpv attaches to the wid window).
        // Serialize with sync_panes/clear_panes (lock order sync_lock → panes) so a
        // watchdog reload can't interleave with sync_panes' lock-released init phase.
        let st = app.state::<AppState>();
        let _sync = st.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
        let app2 = app.clone();
        on_main(&app, move || {
            let state = app2.state::<AppState>();
            let mut map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
            let pane = map.remove(&id).ok_or("no such pane")?;
            let hwnd = pane.child_hwnd;
            let url = pane.url.clone();
            drop(pane.mpv); // mpv_terminate_destroy releases the window before we re-attach
            match configure_mpv(hwnd, &url) {
                Ok(mpv) => {
                    map.insert(
                        id.clone(),
                        Pane {
                            child_hwnd: hwnd,
                            mpv,
                            url,
                            zoom_log2: 0.0,
                            pan_x: 0.0,
                            pan_y: 0.0,
                        },
                    );
                    Ok(())
                }
                Err(e) => {
                    // R1: re-init failed and the pane is already out of the map. Destroy
                    // the orphan child window + drop its id mapping so the next sync_panes
                    // recreates the pane cleanly — otherwise a dead window would occlude a
                    // black tile forever (the JS watchdog calls scheduleSync on rejection).
                    #[cfg(windows)]
                    {
                        PANE_IDS
                            .lock()
                            .unwrap_or_else(|p| p.into_inner())
                            .remove(&hwnd);
                        unsafe { DestroyWindow(hwnd as HWND) };
                    }
                    Err(e)
                }
            }
        })
    }
}

/// Draw (or clear) a transparent ASS overlay ON a pane's video via mpv's
/// `osd-overlay` — used for the in-view PTZ wheel. Because mpv composites it into
/// the video output, the wheel is genuinely semi-transparent over the live image
/// (no carved/black box, no window clipping). Empty `ass` clears it.
/// `res_x`/`res_y` define the ASS coordinate space (we pass the pane's CSS size,
/// which mpv scales to the window — so the wheel lands at the same place at any DPI).
#[tauri::command]
fn set_pane_overlay(
    app: AppHandle,
    id: String,
    ass: String,
    res_x: f64,
    res_y: f64,
) -> Result<(), String> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get(&id).ok_or("no such pane")?;
    // No OSD margins → the ASS res space maps to the FULL window (so lower-left
    // positioning is exact).
    let _ = pane.mpv.set_property("osd-margin-x", "0");
    let _ = pane.mpv.set_property("osd-margin-y", "0");
    let rx = (res_x.max(1.0)).round() as i64;
    let ry = (res_y.max(1.0)).round() as i64;
    let fmt = if ass.is_empty() { "none" } else { "ass-events" };
    let rxs = rx.to_string();
    let rys = ry.to_string();
    // osd-overlay id format data res_x res_y z hidden compute_bounds
    let args: [&str; 9] = [
        "osd-overlay",
        "1",
        fmt,
        ass.as_str(),
        rxs.as_str(),
        rys.as_str(),
        "0",
        "no",
        "no",
    ];
    pane.mpv.command(&args)
}

/// Mute/unmute a single pane's audio (play-on-focus + the speaker toggle).
#[tauri::command]
fn set_pane_muted(app: AppHandle, id: String, muted: bool) -> Result<(), String> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get(&id).ok_or("no such pane")?;
    pane.mpv
        .set_property("mute", if muted { "yes" } else { "no" })
}

/// Seek a single pane to an absolute position in seconds (for playback).
///
/// `keyframe = Some(true)` snaps to the nearest keyframe (mpv `seek absolute+keyframes`)
/// — far cheaper than decoding forward to an exact frame and visually equivalent for
/// surveillance scrubbing, so the scrub hot path uses it. The default (exact `time-pos`
/// write) is kept for segment-load seeks where landing on the precise offset matters.
#[tauri::command]
fn seek_pane(
    app: AppHandle,
    id: String,
    seconds: f64,
    keyframe: Option<bool>,
) -> Result<(), String> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get(&id).ok_or("no such pane")?;
    if keyframe.unwrap_or(false) {
        pane.mpv
            .command(&["seek", &format!("{seconds:.3}"), "absolute+keyframes"])
    } else {
        pane.mpv.set_property("time-pos", &format!("{seconds:.3}"))
    }
}

/// Append a URL to a pane's mpv playlist (gapless segment prefetch). mpv's
/// `prefetch-playlist` demuxes the appended file while the current one is still
/// playing, so the decoder is already warm when the boundary arrives.
#[tauri::command]
fn append_pane_next(app: AppHandle, id: String, url: String) -> Result<(), String> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get(&id).ok_or("no such pane")?;
    pane.mpv.loadfile_append(&url)
}

/// Advance a pane to the next playlist entry (the segment appended by
/// [`append_pane_next`]). `weak` means "do nothing if there is no next entry"
/// rather than erroring. Also updates the stored URL so a subsequent
/// `sync_panes` doesn't see a stale mismatch and re-loadfile.
#[tauri::command]
fn advance_pane(app: AppHandle, id: String, url: String) -> Result<(), String> {
    let state = app.state::<AppState>();
    let mut map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get_mut(&id).ok_or("no such pane")?;
    pane.mpv.command(&["playlist-next", "weak"])?;
    // Drop the now-played entry so the playlist never grows past {current, next}
    // over a long linear playback (each boundary appends one). `playlist-clear`
    // keeps the current file, so this can't perturb what's on screen; the next
    // prefetch re-appends. Best-effort — a hiccup here only leaves a stale entry.
    let _ = pane.mpv.playlist_clear();
    pane.url = url;
    Ok(())
}

/// Set playback speed for a single pane.
#[tauri::command]
fn set_pane_speed(app: AppHandle, id: String, speed: f64) -> Result<(), String> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get(&id).ok_or("no such pane")?;
    pane.mpv.set_property("speed", &format!("{speed}"))
}

/// Step one frame forward (`forward=true`) or backward in a pane (playback).
/// mpv's `frame-step`/`frame-back-step` pause playback and advance a single frame.
#[tauri::command]
fn frame_step_pane(app: AppHandle, id: String, forward: bool) -> Result<(), String> {
    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get(&id).ok_or("no such pane")?;
    pane.mpv.command(&[if forward {
        "frame-step"
    } else {
        "frame-back-step"
    }])
}

/// Grab a still from a pane to a JPEG in the user's Pictures\Crumb folder.
/// Uses mpv's `screenshot-to-file` (the actual decoded frame, no OSD). Returns
/// the saved path.
#[tauri::command]
fn snapshot_pane(app: AppHandle, id: String) -> Result<String, String> {
    // Windows uses USERPROFILE; Linux/macOS use HOME.
    let base = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .map(std::path::PathBuf::from)
        .map_err(|_| "neither USERPROFILE nor HOME set".to_string())?;
    let dir = base.join("Pictures").join("CrumbVMS");
    std::fs::create_dir_all(&dir).map_err(|e| format!("create snapshot dir: {e}"))?;
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let safe_id = id.replace(|c: char| !c.is_ascii_alphanumeric(), "_");
    let path = dir.join(format!("snap-{safe_id}-{ts}.jpg"));
    let path_str = path.to_string_lossy().into_owned();

    let state = app.state::<AppState>();
    let map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get(&id).ok_or("no such pane")?;
    pane.mpv
        .command(&["screenshot-to-file", &path_str, "video"])?;
    Ok(path_str)
}

/// Toggle the OS window between fullscreen and windowed — the "camera wall"
/// immersive mode. The frontend pairs this with hiding its own chrome (top bar +
/// toolbar) so only the camera tiles remain, filling the whole screen.
#[tauri::command]
fn set_window_fullscreen(window: tauri::Window, on: bool) -> Result<(), String> {
    window.set_fullscreen(on).map_err(|e| e.to_string())
}

/// Open the folder exported clips landed in (the chosen export dir, or the user's
/// Downloads when none was picked) in the OS file browser — backs the
/// export-complete popup's "Open folder" button.
///
/// Uses `tauri_plugin_opener` (same as [`reveal_path`]) instead of spawning a
/// Windows-only `explorer` process, so this also works on Linux/macOS.
#[tauri::command]
fn open_export_folder(app: AppHandle, dir: Option<String>) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    let dir = match dir {
        Some(d) if !d.trim().is_empty() => std::path::PathBuf::from(d),
        _ => std::env::var("USERPROFILE")
            .or_else(|_| std::env::var("HOME"))
            .map(|p| std::path::PathBuf::from(p).join("Downloads"))
            .map_err(|_| "neither USERPROFILE nor HOME set".to_string())?,
    };
    app.opener()
        .open_path(dir.to_string_lossy().into_owned(), None::<&str>)
        .map_err(|e| format!("open folder: {e}"))
}

/// Reveal a file in the OS file manager — on Windows, select it in Explorer; on
/// other platforms, open its containing folder. Backs the snapshot-saved toast's
/// clickable location.
#[tauri::command]
fn reveal_path(app: AppHandle, path: String) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        let _ = app;
        std::process::Command::new("explorer")
            .arg("/select,")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("reveal: {e}"))?;
        Ok(())
    }
    #[cfg(not(target_os = "windows"))]
    {
        use tauri_plugin_opener::OpenerExt;
        let parent = std::path::Path::new(&path)
            .parent()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or(path);
        app.opener()
            .open_path(parent, None::<&str>)
            .map_err(|e| e.to_string())
    }
}

/// Open a URL (e.g. the server's `/admin` console) in the default browser.
#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    app.opener()
        .open_url(url, None::<&str>)
        .map_err(|e| e.to_string())
}

// ── Session-token at-rest encryption (Windows DPAPI) ─────────────────────────
//
// The webview persists the session token in localStorage (`crumb_token`) so a
// restart doesn't force a re-login. localStorage is a plaintext file on disk —
// anything with read access to the user's profile (another local account,
// malware, a stolen/imaged drive) can lift a long-lived "remember me" token
// straight out of it. DPAPI's `CryptProtectData` ties the ciphertext to the
// current Windows user (+ machine), so the file on disk is useless without
// that user's login session — a meaningful bar-raise for a single-user
// desktop app with no other secret-storage dependency to add.
//
// Non-Windows (Linux/macOS): no equivalent is wired up here. These commands
// return the input UNCHANGED (clearly marked below) rather than failing, so
// the JS side can call them unconditionally on every platform; the token
// stays plaintext in localStorage on those platforms, same as before this fix.
// A real fix there would be the macOS Keychain / a Secret Service (libsecret)
// integration — tracked as follow-up, not done here.

#[cfg(windows)]
fn dpapi_protect(plaintext: &[u8]) -> Result<Vec<u8>, String> {
    use winapi::um::dpapi::CryptProtectData;
    use winapi::um::winbase::LocalFree;
    use winapi::um::wincrypt::DATA_BLOB;

    let mut input = DATA_BLOB {
        cbData: u32::try_from(plaintext.len()).map_err(|_| "data too large".to_string())?,
        pbData: plaintext.as_ptr().cast_mut(),
    };
    let mut output = DATA_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptProtectData(
            &mut input,
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            &mut output,
        )
    };
    if ok == 0 {
        return Err("CryptProtectData failed".to_string());
    }
    let out = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe { LocalFree(output.pbData.cast()) };
    Ok(out)
}

#[cfg(windows)]
fn dpapi_unprotect(ciphertext: &[u8]) -> Result<Vec<u8>, String> {
    use winapi::um::dpapi::CryptUnprotectData;
    use winapi::um::winbase::LocalFree;
    use winapi::um::wincrypt::DATA_BLOB;

    let mut input = DATA_BLOB {
        cbData: u32::try_from(ciphertext.len()).map_err(|_| "data too large".to_string())?,
        pbData: ciphertext.as_ptr().cast_mut(),
    };
    let mut output = DATA_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptUnprotectData(
            &mut input,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
            &mut output,
        )
    };
    if ok == 0 {
        return Err("CryptUnprotectData failed (wrong user, or not DPAPI data)".to_string());
    }
    let out = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe { LocalFree(output.pbData.cast()) };
    Ok(out)
}

/// Encrypt an arbitrary string (the session token) at rest via Windows DPAPI,
/// returning it base64-encoded so it's safe to stash in localStorage as a plain
/// string. Non-Windows: returns the plaintext unchanged (see module note above).
#[tauri::command]
fn secret_encrypt(plaintext: String) -> Result<String, String> {
    #[cfg(windows)]
    {
        use base64::Engine;
        let enc = dpapi_protect(plaintext.as_bytes())?;
        Ok(base64::engine::general_purpose::STANDARD.encode(enc))
    }
    #[cfg(not(windows))]
    {
        Ok(plaintext)
    }
}

/// Reverse of [`secret_encrypt`]. Non-Windows: returns the input unchanged.
#[tauri::command]
fn secret_decrypt(ciphertext: String) -> Result<String, String> {
    #[cfg(windows)]
    {
        use base64::Engine;
        let raw = base64::engine::general_purpose::STANDARD
            .decode(&ciphertext)
            .map_err(|e| format!("base64 decode: {e}"))?;
        let dec = dpapi_unprotect(&raw)?;
        String::from_utf8(dec).map_err(|e| format!("utf8 decode: {e}"))
    }
    #[cfg(not(windows))]
    {
        Ok(ciphertext)
    }
}

/// The most recent folder the user actually picked via [`pick_export_folder`]
/// (canonicalized), remembered server-side so [`save_export_file`] doesn't have
/// to trust a bare `dest_dir` string round-tripped through the webview/JS (which
/// could otherwise be an arbitrary path — an arbitrary-file-write IPC surface).
static LAST_PICKED_EXPORT_DIR: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);

/// Native folder picker for the export destination. Returns the chosen absolute
/// path, or `None` if the user cancelled.
#[tauri::command]
async fn pick_export_folder() -> Option<String> {
    let picked = rfd::AsyncFileDialog::new()
        .set_title("Choose export destination folder")
        .pick_folder()
        .await?;
    let path = picked.path();
    // Canonicalize so later comparisons in save_export_file aren't fooled by
    // `..`/symlinks/relative components.
    let canon = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    *LAST_PICKED_EXPORT_DIR
        .lock()
        .unwrap_or_else(|p| p.into_inner()) = Some(canon.clone());
    Some(canon.to_string_lossy().into_owned())
}

/// Stream an exported clip (its authed `?token=` download URL) straight to a
/// chosen folder, bypassing the browser Downloads path. Returns the written
/// file path on success.
///
/// `dest_dir` is validated against the folder [`pick_export_folder`] actually
/// returned last (rather than trusted as-is) — the webview only ever ROUND-TRIPS
/// that string (via localStorage) back to us, so accepting any string here would
/// let anything running as this webview write an arbitrary file to an arbitrary
/// path. An existing file at the destination is also never silently overwritten.
#[tauri::command]
async fn save_export_file(
    url: String,
    dest_dir: String,
    filename: String,
) -> Result<String, String> {
    use tokio::io::AsyncWriteExt;

    let requested = std::path::PathBuf::from(&dest_dir);
    let requested_canon = std::fs::canonicalize(&requested).unwrap_or(requested);
    {
        let last = LAST_PICKED_EXPORT_DIR
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        match last.as_ref() {
            Some(picked) if *picked == requested_canon => {}
            _ => return Err("export destination was not chosen via the folder picker".to_string()),
        }
    }

    // Sanitise the filename (the dir is now verified, but the filename still
    // comes straight from the export metadata).
    let safe: String = filename
        .chars()
        .map(|c| {
            if matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') {
                '_'
            } else {
                c
            }
        })
        .collect();
    let dest = requested_canon.join(&safe);

    // Never silently clobber an existing file at the destination.
    if tokio::fs::metadata(&dest).await.is_ok() {
        return Err(format!("a file already exists at {}", dest.display()));
    }

    let mut resp = HTTP
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("request failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("download failed: HTTP {}", resp.status()));
    }

    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true) // belt-and-suspenders against a TOCTOU overwrite race
        .open(&dest)
        .await
        .map_err(|e| format!("create {}: {e}", dest.display()))?;
    while let Some(chunk) = resp.chunk().await.map_err(|e| format!("download: {e}"))? {
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("write: {e}"))?;
    }
    file.flush().await.map_err(|e| format!("flush: {e}"))?;
    Ok(dest.to_string_lossy().into_owned())
}

/// Digital zoom a pane by `delta_steps` wheel notches, centered on the cursor
/// (`cx`,`cy` in pane-client physical px; `pane_w`/`pane_h` the pane size in the
/// same units). Uses mpv `video-zoom` (log2) + `video-pan-x/y` (window fraction)
/// and keeps the image point under the cursor fixed as the scale changes.
#[tauri::command]
fn zoom_pane(
    app: AppHandle,
    id: String,
    delta_steps: f64,
    cx: f64,
    cy: f64,
    pane_w: f64,
    pane_h: f64,
) -> Result<f64, String> {
    if pane_w <= 0.0 || pane_h <= 0.0 {
        return Ok(0.0);
    }
    const ZOOM_STEP: f64 = 0.20; // log2 units per notch (~1.149× each)
    const ZMAX: f64 = 3.0; // 8× cap
    let state = app.state::<AppState>();
    let mut map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get_mut(&id).ok_or("no such pane")?;

    // delta_steps is the RAW wheel delta (multiple of 120); convert to notches.
    let notches = delta_steps / f64::from(WHEEL_DELTA_UNIT);
    let z0 = pane.zoom_log2;
    let z1 = (z0 + notches * ZOOM_STEP).clamp(0.0, ZMAX);
    let s0 = 2f64.powf(z0);
    let s1 = 2f64.powf(z1);

    let (px, py) = if z1 <= 0.0 {
        (0.0, 0.0) // back to 1× → no pan (avoids drift / black bars)
    } else {
        // mpv-FAITHFUL cursor-anchored pan — the SAME model as `zoom_pane_rect`.
        // mpv `video-pan` is a fraction of the SCALED video,
        // so a point at window-fraction `u` (center-origin) shows image content
        // `img = u/s − Q`. Keeping the point under the cursor fixed across the
        // scale change s0→s1 gives `Q1 = Q0 + u·(1/s1 − 1/s0)` — NO `s1/s0`
        // factor. The old `u − (s1/s0)·(u − Q0)` form treated pan as a window
        // fraction (mpv's actual unit is scaled-video), so it drifted off the
        // cursor as you zoomed AND left `video-pan` in a unit the box-zoom path
        // (which is mpv-faithful) then misread.
        let u = cx / pane_w - 0.5;
        let v = cy / pane_h - 0.5;
        let dq = 1.0 / s1 - 1.0 / s0;
        // Clamp so we never pan past the image edge (show black bars).
        let pmax = 0.5 * (1.0 - 1.0 / s1);
        let nx = (pane.pan_x + u * dq).clamp(-pmax, pmax);
        let ny = (pane.pan_y + v * dq).clamp(-pmax, pmax);
        (nx, ny)
    };

    pane.mpv.set_property("video-zoom", &format!("{z1}"))?;
    pane.mpv.set_property("video-pan-x", &format!("{px}"))?;
    pane.mpv.set_property("video-pan-y", &format!("{py}"))?;
    pane.zoom_log2 = z1;
    pane.pan_x = px;
    pane.pan_y = py;
    Ok(z1)
}

/// Box-zoom a pane to a drawn rectangle (`x0,y0`→`x1,y1` in pane-client px;
/// `pane_w`/`pane_h` the pane size, same units) — commercial-VMS-style "draw a box, zoom
/// to it". Scales so the box fills the pane (aspect-preserving) on top of any
/// current zoom, then pans so the box centre is centred. Returns the new
/// `video-zoom` (log2). A too-small box is treated as a click (no-op).
#[tauri::command]
#[allow(clippy::too_many_arguments)] // id + box (x0,y0,x1,y1) + pane (w,h) + app
fn zoom_pane_rect(
    app: AppHandle,
    id: String,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    pane_w: f64,
    pane_h: f64,
) -> Result<f64, String> {
    const ZMAX: f64 = 3.0; // 8× cap (matches zoom_pane)
    if pane_w <= 0.0 || pane_h <= 0.0 {
        return Ok(0.0);
    }
    let state = app.state::<AppState>();
    let mut map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get_mut(&id).ok_or("no such pane")?;

    let bw = (x1 - x0).abs();
    let bh = (y1 - y0).abs();
    // Ignore boxes that are really just a click/tiny drag.
    if bw < pane_w * 0.04 || bh < pane_h * 0.04 {
        return Ok(pane.zoom_log2);
    }
    let bcx = (x0 + x1) / 2.0;
    let bcy = (y0 + y1) / 2.0;

    let z0 = pane.zoom_log2;
    let s0 = 2f64.powf(z0);
    // Fill the box (aspect-preserving) → relative zoom factor on top of current.
    let fit = (pane_w / bw).min(pane_h / bh);
    let z1 = (z0 + fit.log2()).clamp(0.0, ZMAX);
    let s1 = 2f64.powf(z1);

    // Box centre in current-view normalized, center-origin coords. mpv's
    // `video-pan` (Q) is a fraction of the SCALED video, so the image content
    // shown at pane fraction `u` is `m = u/s − Q`. To move the box-centre content
    // to the pane centre (where `m = −Q1`): Q1 = Q0 − u/s0 — divide by the OLD
    // scale, and NO `s1` factor (the previous `-s1*(u-Q0)/s0` over-panned by the
    // full new scale, flinging the view way off).
    let u = bcx / pane_w - 0.5;
    let v = bcy / pane_h - 0.5;
    let pmax = 0.5 * (1.0 - 1.0 / s1);
    let px = (pane.pan_x - u / s0).clamp(-pmax, pmax);
    let py = (pane.pan_y - v / s0).clamp(-pmax, pmax);

    pane.mpv.set_property("video-zoom", &format!("{z1}"))?;
    pane.mpv.set_property("video-pan-x", &format!("{px}"))?;
    pane.mpv.set_property("video-pan-y", &format!("{py}"))?;
    pane.zoom_log2 = z1;
    pane.pan_x = px;
    pane.pan_y = py;
    Ok(z1)
}

/// Pan a digitally-zoomed pane by a drag delta (`dx`,`dy` in pane-client px;
/// `pane_w`/`pane_h` the pane size in the same units). No-op when the pane isn't
/// zoomed. Dragging moves the image with the cursor (grab-to-pan); pan is
/// clamped so the image never shows black bars.
#[tauri::command]
fn pan_pane(
    app: AppHandle,
    id: String,
    dx: f64,
    dy: f64,
    pane_w: f64,
    pane_h: f64,
) -> Result<(), String> {
    if pane_w <= 0.0 || pane_h <= 0.0 {
        return Ok(());
    }
    let state = app.state::<AppState>();
    let mut map = state.panes.lock().unwrap_or_else(|p| p.into_inner());
    let pane = map.get_mut(&id).ok_or("no such pane")?;
    if pane.zoom_log2 <= 0.0 {
        return Ok(()); // only pan when zoomed in
    }
    const PAN_GAIN: f64 = 0.5; // < 1.0 → pans slower than the raw cursor delta
    let s1 = 2f64.powf(pane.zoom_log2);
    let pmax = 0.5 * (1.0 - 1.0 / s1);
    let nx = (pane.pan_x + (dx / pane_w) * PAN_GAIN).clamp(-pmax, pmax);
    let ny = (pane.pan_y + (dy / pane_h) * PAN_GAIN).clamp(-pmax, pmax);
    pane.mpv.set_property("video-pan-x", &format!("{nx}"))?;
    pane.mpv.set_property("video-pan-y", &format!("{ny}"))?;
    pane.pan_x = nx;
    pane.pan_y = ny;
    Ok(())
}

// ── LAN server discovery ─────────────────────────────────────────────────────
// "Find my server" on the login screen: unicast-scan a /24 for Crumb servers by
// probing the unauthenticated GET /health and matching the "service":"crumb-api"
// signature. Done in Rust (not browser fetch) to avoid CORS and to read the
// device's own LAN IP. Mirrors the Android client's scan.

#[derive(Serialize)]
struct DiscoveredServer {
    url: String,
    ip: String,
    port: u16,
    version: Option<String>,
}

impl DiscoveredServer {
    fn scheme_is_https(&self) -> bool {
        self.url.starts_with("https://")
    }
}

/// Best-effort local IPv4 of the active interface. A UDP "connect" reveals the
/// outbound source address without sending any packets.
fn local_ipv4() -> Option<std::net::Ipv4Addr> {
    let sock = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect("8.8.8.8:80").ok()?;
    match sock.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(v4) => Some(v4),
        std::net::IpAddr::V6(_) => None,
    }
}

/// The device's own /24 as a CIDR string (e.g. `198.51.100.0/24`), for prefilling the
/// "scan a specific subnet" field.
#[tauri::command]
fn local_subnet_cidr() -> Option<String> {
    let o = local_ipv4()?.octets();
    Some(format!("{}.{}.{}.0/24", o[0], o[1], o[2]))
}

/// Resolve a user-entered range to host IPs. `None`/empty → the local /24. Accepts
/// CIDR (scans that /24), a `a.b.c` base, a single `a.b.c.d`, or `a.b.c.x-y`.
fn scan_hosts(range: &Option<String>) -> Option<Vec<std::net::Ipv4Addr>> {
    use std::net::Ipv4Addr;
    let base24 = |o: [u8; 4]| {
        (1u8..=254)
            .map(move |l| Ipv4Addr::new(o[0], o[1], o[2], l))
            .collect()
    };
    let r = range.as_deref().map(str::trim).unwrap_or("");
    if r.is_empty() {
        return Some(base24(local_ipv4()?.octets()));
    }
    // Dash range on the last octet: a.b.c.x-y (or a.b.c.x-a.b.c.y).
    if let Some((lo, hi)) = r.split_once('-') {
        let lp: Vec<u8> = lo
            .trim()
            .split('.')
            .filter_map(|s| s.parse().ok())
            .collect();
        let hl: Option<u8> = hi.trim().parse().ok().or_else(|| {
            hi.trim()
                .split('.')
                .filter_map(|s| s.parse().ok())
                .next_back()
        });
        if lp.len() == 4 {
            if let Some(h) = hl {
                if h >= lp[3] {
                    return Some(
                        (lp[3]..=h)
                            .map(|l| Ipv4Addr::new(lp[0], lp[1], lp[2], l))
                            .collect(),
                    );
                }
            }
        }
        return None;
    }
    // CIDR or base → scan the address's /24.
    let addr = r.split('/').next().unwrap_or(r);
    let parts: Vec<u8> = addr.split('.').filter_map(|s| s.parse().ok()).collect();
    if r.contains('/') && parts.len() >= 3 {
        return Some(base24([parts[0], parts[1], parts[2], 0]));
    }
    match parts.len() {
        3 => Some(base24([parts[0], parts[1], parts[2], 0])),
        4 => Some(vec![Ipv4Addr::new(parts[0], parts[1], parts[2], parts[3])]),
        _ => None,
    }
}

fn extract_json_str(json: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\"");
    let i = json.find(&pat)?;
    let rest = json[i + pat.len()..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start().strip_prefix('"')?;
    let end = rest.find('"')?;
    let v = &rest[..end];
    if v.is_empty() {
        None
    } else {
        Some(v.to_owned())
    }
}

async fn probe_server(
    client: &reqwest::Client,
    scheme: &str,
    ip: std::net::Ipv4Addr,
    port: u16,
) -> Option<DiscoveredServer> {
    let base = format!("{scheme}://{ip}:{port}");
    // /health carries "service":"crumb-api" even when the DB is degraded (503).
    let body = client
        .get(format!("{base}/health"))
        .send()
        .await
        .ok()?
        .text()
        .await
        .ok()?;
    if !body.contains("crumb-api") {
        return None;
    }
    let version = match client.get(format!("{base}/version")).send().await {
        Ok(r) => r
            .text()
            .await
            .ok()
            .and_then(|t| extract_json_str(&t, "version")),
        Err(_) => None,
    };
    Some(DiscoveredServer {
        url: base,
        ip: ip.to_string(),
        port,
        version,
    })
}

#[tauri::command]
async fn discover_servers(
    port: Option<u16>,
    range: Option<String>,
) -> Result<Vec<DiscoveredServer>, String> {
    use futures::stream::{self, StreamExt};
    let hosts =
        scan_hosts(&range).ok_or_else(|| "could not determine a subnet to scan".to_string())?;
    // Probe a small set of (scheme, port) candidates per host — a Crumb server is
    // commonly reachable on plain HTTP :8080 *and/or* Caddy TLS :8443, so scanning
    // only :8080 (the old behaviour) missed any TLS-only or non-default-port
    // instance. An explicit port from the UI is probed on both schemes so a custom
    // deployment is still found.
    // (is_https, port). A borrowed `&'static str` scheme here would cross the
    // stream closure boundary and trip the `tauri::command` macro's HRTB check,
    // so carry a bool and derive the scheme string inside the async block.
    let mut candidates: Vec<(bool, u16)> = vec![(false, 8080), (true, 8443)];
    if let Some(p) = port {
        if !candidates.iter().any(|(_, cp)| *cp == p) {
            candidates.push((false, p));
            candidates.push((true, p));
        }
    }
    let build = |accept_invalid: bool| {
        reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_millis(500))
            .timeout(std::time::Duration::from_millis(1200))
            // Discovery only reads the unauthenticated /health signature; a LAN
            // server's TLS cert is typically self-signed, so don't reject it here.
            .danger_accept_invalid_certs(accept_invalid)
            .build()
            .map_err(|e| e.to_string())
    };
    let http = build(false)?;
    let https = build(true)?;
    // Materialize the (ip, scheme, port) probe list into an OWNED Vec before
    // streaming it: a borrowing iterator (over `hosts`/`candidates`) held across
    // the `.await` trips rustc's "FnOnce is not general enough" HRTB check.
    let probes: Vec<(std::net::Ipv4Addr, bool, u16)> = hosts
        .iter()
        .flat_map(|&ip| candidates.iter().map(move |&(https, p)| (ip, https, p)))
        .collect();
    let mut found: Vec<DiscoveredServer> = stream::iter(probes)
        .map(|(ip, is_https, p)| {
            let http = http.clone();
            let https = https.clone();
            async move {
                let (client, scheme) = if is_https {
                    (&https, "https")
                } else {
                    (&http, "http")
                };
                probe_server(client, scheme, ip, p).await
            }
        })
        .buffer_unordered(64)
        .filter_map(|x| async move { x })
        .collect()
        .await;
    // Collapse the plain+TLS front doors of a *single* host into one entry: if the
    // same IP answers on both http:8080 and https:8443, keep only the secure URL.
    // Distinct hosts (different IPs) and genuinely different ports stay separate.
    let dual: std::collections::HashSet<String> = found
        .iter()
        .filter(|s| s.scheme_is_https())
        .filter(|s| s.port == 8443)
        .map(|s| s.ip.clone())
        .collect();
    found.retain(|s| !(s.port == 8080 && !s.scheme_is_https() && dual.contains(&s.ip)));
    found.sort_by_key(|s| {
        let octet =
            s.ip.rsplit('.')
                .next()
                .and_then(|o| o.parse::<u8>().ok())
                .unwrap_or(0);
        (octet, s.port)
    });
    Ok(found)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(AppState::default())
        .setup(|app| {
            // Stash the handle so the native pane WndProc can emit events.
            let _ = APP.set(app.handle().clone());
            // Kill the WebView2 default ("browser") right-click menu app-wide — this
            // is a desktop app, not a browser, so "Back / Reload / Save as / Inspect"
            // must never appear. A DOM `contextmenu` preventDefault (we keep one too)
            // can't cover the native libmpv video panes — they never deliver the
            // event to the DOM — and it races page load; this CONTROLLER-level
            // setting covers every surface with no race. The app's own tile context
            // menu is custom DOM, so it is unaffected.
            #[cfg(windows)]
            if let Some(win) = app.get_webview_window("main") {
                let _ = win.with_webview(|webview| unsafe {
                    if let Ok(core) = webview.controller().CoreWebView2() {
                        if let Ok(settings) = core.Settings() {
                            let _ = settings.SetAreDefaultContextMenusEnabled(false);
                        }
                    }
                });
            }
            // Dev-only: exercise the real Linux sync_panes (multi-pane) without a
            // login, for headless verification. Gated behind CRUMB_PANES_TEST.
            #[cfg(target_os = "linux")]
            if std::env::var("CRUMB_PANES_TEST").is_ok() {
                let app_h = app.handle().clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(2500));
                    // `realtime` paces the synthetic source to wall-clock so mpv
                    // doesn't decode it flat-out (untimed lavfi buffers unboundedly).
                    // Override with a real rtsp:// URL via CRUMB_PANES_URL.
                    let url = std::env::var("CRUMB_PANES_URL").unwrap_or_else(|_| {
                        "av://lavfi:testsrc=size=640x480:rate=30,realtime".to_string()
                    });
                    let mk = |id: &str, x: f64| PaneSpec {
                        id: id.to_string(),
                        url: url.clone(),
                        x,
                        y: 60.0,
                        w: 480.0,
                        h: 320.0,
                        notch_w: 0.0,
                        notch_h: 0.0,
                        preserve_zoom: false,
                    };
                    match linux_panes::sync_panes(
                        &app_h,
                        vec![mk("slot0", 40.0), mk("slot1", 560.0)],
                    ) {
                        Ok(z) => eprintln!("[panes-test] sync_panes ok: {} panes", z.len()),
                        Err(e) => eprintln!("[panes-test] sync_panes ERROR: {e}"),
                    }
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            sync_panes,
            clear_panes,
            set_panes_hidden,
            set_pane_paused,
            set_pane_muted,
            seek_pane,
            append_pane_next,
            advance_pane,
            set_pane_speed,
            frame_step_pane,
            snapshot_pane,
            zoom_pane,
            zoom_pane_rect,
            pan_pane,
            live_pane_progress,
            pane_stats,
            host_stats,
            reload_pane,
            set_pane_overlay,
            set_window_fullscreen,
            open_export_folder,
            reveal_path,
            open_url,
            pick_export_folder,
            save_export_file,
            discover_servers,
            local_subnet_cidr,
            secret_encrypt,
            secret_decrypt
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
