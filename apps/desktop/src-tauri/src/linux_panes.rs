// SPDX-License-Identifier: AGPL-3.0-or-later

//! Linux native video-pane backend: render libmpv into per-pane `GtkGLArea`s
//! overlaid on the wry/webkit2gtk webview, via the mpv OpenGL render API. This is
//! the real implementation behind the `#[cfg(target_os = "linux")]` arms of
//! `sync_panes` / `clear_panes` / `set_panes_hidden` / `reload_pane`.
//!
//! Mirrors the Windows backend's command/event contract, but the surface is a
//! GTK widget (GTK owns it, so it composites correctly on X11 AND Wayland) rather
//! than a `wid`-embedded child window. The de-risking spike (commit history) proved
//! the approach; this module makes it the production path.
//!
//! GTK is main-thread-only, so every entry point marshals its widget work through
//! [`crate::on_main`]. Per-thread widget handles live in thread-locals; the
//! `Pane` parked in `AppState.panes` holds only `Send` data (the GLArea as an
//! `isize` identity, plus the `Send` mpv + render context).

use gtk::glib;
use gtk::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::OnceLock;

use crate::mpv::{Mpv, RenderCtx};
use crate::{AppState, Pane, PaneSpec, PaneZoom};
use tauri::{AppHandle, Emitter, Manager};

// ── main-thread widget registries (GTK objects are !Send) ─────────────────────
thread_local! {
    /// The `GtkOverlay` we reparent the webview under (created once).
    static OVERLAY: RefCell<Option<gtk::Overlay>> = const { RefCell::new(None) };
    /// pane id → its `GtkGLArea` widget.
    static AREAS: RefCell<HashMap<String, gtk::GLArea>> = RefCell::new(HashMap::new());
}

// ── GL proc resolution via eglGetProcAddress (see spike notes) ────────────────
type EglGetProcAddr = unsafe extern "C" fn(*const c_char) -> *mut c_void;

fn egl_gpa() -> Option<EglGetProcAddr> {
    static F: OnceLock<Option<usize>> = OnceLock::new();
    let raw = *F.get_or_init(|| unsafe {
        let lib = libloading::Library::new("libEGL.so.1").ok()?;
        let sym: libloading::Symbol<EglGetProcAddr> = lib.get(b"eglGetProcAddress\0").ok()?;
        let addr = *sym as usize;
        std::mem::forget(lib);
        Some(addr)
    });
    raw.map(|a| unsafe { std::mem::transmute::<usize, EglGetProcAddr>(a) })
}

fn resolve(name: &str) -> *mut c_void {
    let Some(f) = egl_gpa() else {
        return std::ptr::null_mut();
    };
    CString::new(name)
        .map(|c| unsafe { f(c.as_ptr()) })
        .unwrap_or(std::ptr::null_mut())
}

unsafe extern "C" fn mpv_get_proc(_ctx: *mut c_void, name: *const c_char) -> *mut c_void {
    let n = CStr::from_ptr(name).to_str().unwrap_or("");
    resolve(n)
}

type GlGetIntegerv = unsafe extern "C" fn(u32, *mut i32);
const GL_DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;

fn current_draw_fbo() -> i32 {
    let p = resolve("glGetIntegerv");
    if p.is_null() {
        return 0;
    }
    let f: GlGetIntegerv = unsafe { std::mem::transmute(p) };
    let mut fbo: i32 = 0;
    unsafe { f(GL_DRAW_FRAMEBUFFER_BINDING, &mut fbo) };
    fbo
}

// ── widget-tree helpers ───────────────────────────────────────────────────────
fn find_by_type(w: &gtk::Widget, type_name: &str) -> Option<gtk::Widget> {
    if w.type_().name() == type_name {
        return Some(w.clone());
    }
    if let Some(c) = w.dynamic_cast_ref::<gtk::Container>() {
        for child in c.children() {
            if let Some(found) = find_by_type(&child, type_name) {
                return Some(found);
            }
        }
    }
    None
}

/// Reparent the webview under a `GtkOverlay` (once) so panes can float on top, and
/// (panes are positioned individually via `apply_rect` on each GLArea).
fn ensure_overlay(win: &tauri::WebviewWindow) -> Result<gtk::Overlay, String> {
    if let Some(ov) = OVERLAY.with(|o| o.borrow().clone()) {
        return Ok(ov);
    }
    let gtk_win = win.gtk_window().map_err(|e| format!("gtk_window: {e}"))?;
    let root: gtk::Widget = gtk_win.upcast();
    let webview = find_by_type(&root, "WebKitWebView").ok_or("no WebKitWebView")?;
    let container = webview
        .parent()
        .ok_or("webview has no parent")?
        .downcast::<gtk::Box>()
        .map_err(|_| "webview parent is not a GtkBox")?;
    container.remove(&webview);
    let overlay = gtk::Overlay::new();
    container.pack_start(&overlay, true, true, 0);
    overlay.add(&webview);
    overlay.show();
    OVERLAY.with(|o| *o.borrow_mut() = Some(overlay.clone()));
    Ok(overlay)
}

/// Position + size a pane's GLArea over the webview via margins + size_request
/// (halign/valign Start anchor it to the top-left of the overlay). JS already
/// multiplied the rect by devicePixelRatio → it's physical px; GTK widget geometry
/// is logical px (GTK re-multiplies by the widget scale-factor), so divide by the
/// scale factor here. The FBO handed to mpv uses physical px (see `render_one`).
fn apply_rect(area: &gtk::GLArea, spec: &PaneSpec) {
    let s = f64::from(area.scale_factor().max(1));
    #[allow(clippy::cast_possible_truncation)]
    {
        area.set_margin_start((spec.x / s) as i32);
        area.set_margin_top((spec.y / s) as i32);
        area.set_size_request((spec.w / s).max(1.0) as i32, (spec.h / s).max(1.0) as i32);
    }
}

/// Render handler: draw mpv's current frame into the GLArea's FBO. Uses `try_lock`
/// so a frame is skipped (not deadlocked) if a lifecycle op holds the panes lock.
fn render_one(app: &AppHandle, id: &str, area: &gtk::GLArea) {
    let scale = area.scale_factor();
    let w = area.allocated_width() * scale;
    let h = area.allocated_height() * scale;
    area.attach_buffers();
    let fbo = current_draw_fbo();
    let st = app.state::<AppState>();
    // try_lock so a frame is skipped (not deadlocked) if a lifecycle op holds it.
    let Ok(panes) = st.panes.try_lock() else {
        return;
    };
    if let Some(p) = panes.get(id) {
        let _ = p.render_ctx.render_fbo(fbo, w, h, true);
        // Required with ADVANCED_CONTROL: tell mpv the frame was displayed, else it
        // treats every frame as dropped and buffers unboundedly (OOM under software
        // GL, where rendering can't keep the timer's pace).
        p.render_ctx.report_swap();
    }
}

/// Coalescing flag: at most one main-loop redraw is scheduled at a time.
static RENDER_PENDING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// mpv render update callback — fires on an ARBITRARY thread when a frame is ready.
/// mpv may fire it in bursts, so coalesce to ONE scheduled main-loop redraw (else
/// per-update `idle_add`s pile up and leak). Renders all panes; GTK's `queue_render`
/// coalesces and panes without a new frame just re-present cheaply. Never touches
/// GTK on this thread.
unsafe extern "C" fn on_mpv_update(_ctx: *mut c_void) {
    use std::sync::atomic::Ordering;
    if RENDER_PENDING.swap(true, Ordering::AcqRel) {
        return; // a redraw is already queued
    }
    glib::idle_add(|| {
        RENDER_PENDING.store(false, Ordering::Release);
        AREAS.with(|a| {
            for area in a.borrow().values() {
                area.queue_render();
            }
        });
        glib::ControlFlow::Break
    });
}

fn configure_mpv_linux() -> Result<Mpv, String> {
    let mpv = Mpv::create(&crate::libmpv_path())?;
    mpv.set_option("vo", "libmpv")?; // render-API output
    mpv.set_option("hwdec", "auto")?;
    mpv.set_option("cache", "yes")?;
    mpv.set_option("demuxer-readahead-secs", "2.0")?;
    mpv.set_option("demuxer-max-bytes", "32MiB")?;
    mpv.set_option("demuxer-max-back-bytes", "1MiB")?;
    mpv.set_option("rtsp-transport", "tcp")?;
    mpv.set_option("keep-open", "yes")?;
    mpv.set_option("network-timeout", "10")?;
    let _ = mpv.set_option("demuxer-lavf-o", "analyzeduration=500000,probesize=500000");
    mpv.set_option("mute", "yes")?;
    mpv.initialize()?;
    Ok(mpv)
}

/// Emit a pane pointer event with coords in physical px (the Windows convention;
/// GDK reports logical px). For pane-click / pane-drag / pane-rightclick.
fn emit_xy(app: &AppHandle, event: &str, id: &str, area: &gtk::GLArea, x: f64, y: f64) {
    let s = f64::from(area.scale_factor().max(1));
    let _ = app.emit(
        event,
        serde_json::json!({ "id": id, "x": x * s, "y": y * s }),
    );
}

/// Connect GTK pointer/scroll handlers that emit the SAME `pane-*` events as the
/// Windows WndProc: `pane-click`/`pane-drag`/`pane-rightclick`/`pane-wheel` carry
/// `{id,x,y[,delta]}` in pane-client physical px (wheel in ±120 units); `pane-dblclick`
/// and `pane-dragend` carry just the id string. JS handlers are platform-neutral.
fn wire_pane_events(app: &AppHandle, area: &gtk::GLArea, id: &str) {
    use gtk::gdk;
    area.add_events(
        gdk::EventMask::BUTTON_PRESS_MASK
            | gdk::EventMask::BUTTON_RELEASE_MASK
            | gdk::EventMask::POINTER_MOTION_MASK
            | gdk::EventMask::SCROLL_MASK,
    );
    {
        let (app, id) = (app.clone(), id.to_string());
        area.connect_button_press_event(move |area, ev| {
            let (x, y) = ev.position();
            if cfg!(debug_assertions) {
                eprintln!("[pane-evt] {id} press btn={} @ {x:.0},{y:.0}", ev.button());
            }
            match ev.button() {
                1 => {
                    if ev.event_type() == gdk::EventType::DoubleButtonPress {
                        let _ = app.emit("pane-dblclick", &id);
                    } else {
                        emit_xy(&app, "pane-click", &id, area, x, y);
                    }
                }
                3 => emit_xy(&app, "pane-rightclick", &id, area, x, y),
                _ => {}
            }
            glib::Propagation::Stop
        });
    }
    {
        let (app, id) = (app.clone(), id.to_string());
        area.connect_motion_notify_event(move |area, ev| {
            if ev.state().contains(gdk::ModifierType::BUTTON1_MASK) {
                let (x, y) = ev.position();
                emit_xy(&app, "pane-drag", &id, area, x, y);
            }
            glib::Propagation::Proceed
        });
    }
    {
        let (app, id) = (app.clone(), id.to_string());
        area.connect_button_release_event(move |_area, ev| {
            if ev.button() == 1 {
                let _ = app.emit("pane-dragend", &id);
            }
            glib::Propagation::Stop
        });
    }
    {
        let (app, id) = (app.clone(), id.to_string());
        area.connect_scroll_event(move |area, ev| {
            let (x, y) = ev.position();
            let delta = match ev.direction() {
                gdk::ScrollDirection::Up => 120.0,
                gdk::ScrollDirection::Down => -120.0,
                gdk::ScrollDirection::Smooth => -ev.delta().1 * 120.0,
                _ => 0.0,
            };
            if delta != 0.0 {
                let s = f64::from(area.scale_factor().max(1));
                let _ = app.emit(
                    "pane-wheel",
                    serde_json::json!({ "id": id, "delta": delta, "x": x * s, "y": y * s }),
                );
            }
            glib::Propagation::Stop
        });
    }
}

/// The SLOW, GL-independent half of standing up a pane's mpv instance: create the
/// player, set options, initialize (this is where mpv probes the stream — the
/// part worth running off the main thread) and start `loadfile`. Safe to call on
/// any thread — `Mpv` is `Send` and this never touches GTK/GL. Split out so
/// `sync_panes` can run one of these per NEW pane in parallel (mirrors the
/// Windows backend's phase-2 parallel `configure_mpv`), instead of the old
/// one-pane-at-a-time chain that blocked the whole GTK main loop for a cold wall.
fn spawn_mpv_slow(url: &str) -> Result<Mpv, String> {
    let mpv = configure_mpv_linux()?;
    mpv.loadfile(url)?;
    Ok(mpv)
}

/// The FAST, GL-dependent half: bind a render context to an already-initialized
/// `mpv` for the GLArea that is current on THIS (main) thread, and wire the
/// redraw callback. Must run on the GTK main thread with `area.make_current()`
/// already called.
fn bind_render_ctx(mpv: &Mpv) -> Result<RenderCtx, String> {
    let render_ctx = mpv.create_render_context(mpv_get_proc, std::ptr::null_mut())?;
    // Drive rendering from mpv's update callback — render only when a new frame is
    // ready (no polling timer, so software GL can't fall behind and OOM). The
    // callback coalesces and redraws all panes, so it needs no per-pane context.
    render_ctx.set_update_callback(on_mpv_update, std::ptr::null_mut());
    Ok(render_ctx)
}

/// Build a fresh mpv instance + render context bound to an ALREADY-current GLArea
/// and start it playing `url`. Used by `reload_pane` (single pane, latency there
/// doesn't matter — no batching to parallelize).
fn spawn_mpv_for_area(app: &AppHandle, id: &str, url: &str) -> Result<(Mpv, RenderCtx), String> {
    let mpv = spawn_mpv_slow(url)?;
    let render_ctx = bind_render_ctx(&mpv)?;
    let _ = (app, id); // kept for symmetry / future per-pane wiring
    Ok((mpv, render_ctx))
}

/// Create just the GLArea half of a pane (widget realize is GTK-main-thread-only,
/// but fast — no mpv/network work happens here). Split out of `create_pane` so a
/// cold multi-pane wall can realize every widget up front, then init every mpv
/// instance IN PARALLEL on worker threads (see `sync_panes`), instead of the
/// widget-then-mpv-then-widget-then-mpv serial chain that used to freeze the GTK
/// main loop for as long as N cold-starts took.
fn create_area(
    app: &AppHandle,
    overlay: &gtk::Overlay,
    spec: &PaneSpec,
) -> Result<gtk::GLArea, String> {
    let area = gtk::GLArea::new();
    area.set_has_depth_buffer(false);
    area.set_has_stencil_buffer(false);
    area.set_halign(gtk::Align::Start);
    area.set_valign(gtk::Align::Start);

    let app_r = app.clone();
    let id_r = spec.id.clone();
    area.connect_render(move |area, _ctx| {
        render_one(&app_r, &id_r, area);
        glib::Propagation::Stop
    });

    wire_pane_events(app, &area, &spec.id);

    overlay.add_overlay(&area);
    area.show();
    area.realize();
    area.make_current();
    if let Some(err) = area.error() {
        return Err(format!("GLArea realize: {err}"));
    }
    apply_rect(&area, spec);
    Ok(area)
}

/// Tear down one pane (GL context current so the render-context free is valid).
fn destroy_pane(id: &str, pane: Pane, overlay: &gtk::Overlay) {
    pane.render_ctx.clear_update_callback(); // stop callbacks before freeing the ctx
    if let Some(area) = AREAS.with(|a| a.borrow_mut().remove(id)) {
        area.make_current();
        drop(pane); // render_ctx (GL current) then mpv
        overlay.remove(&area);
    } else {
        drop(pane);
    }
}

// ── command entry points (called from lib.rs cfg(linux) arms) ─────────────────

/// Reconcile the live set of panes to exactly `specs`.
///
/// Mirrors the Windows backend's three-phase split (see `lib.rs::sync_panes`):
/// GTK widget work is main-thread-only so it can't be fully off-loaded, but the
/// SLOW part — mpv `initialize`/`loadfile`, which probes the stream over the
/// network — is run for every NEW pane IN PARALLEL on worker threads, not
/// chained one-at-a-time on the GTK main loop. Previously a cold N-pane wall
/// blocked the entire UI for `sum(per-pane cold-start time)`; this brings it down
/// to roughly `max(...)`, and a single failed pane no longer aborts the rest (the
/// old `?` inside the per-spec loop would bail the whole batch on one bad camera).
pub fn sync_panes(app: &AppHandle, specs: Vec<PaneSpec>) -> Result<Vec<PaneZoom>, String> {
    let st = app.state::<AppState>();
    let _sync = st.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
    let app2 = app.clone();

    // ── PHASE 1 (main thread): remove stale, update existing (fast — no mpv
    // init), and create+realize the GLArea widget for every NEW pane. Returns the
    // (id, url) pairs that still need an mpv instance spun up.
    let new_specs: Vec<PaneSpec> = crate::on_main(app, {
        let specs = specs.clone();
        move || {
            let st = app2.state::<AppState>();
            let win = app2.get_webview_window("main").ok_or("no main window")?;
            let overlay = ensure_overlay(&win)?;

            let desired: std::collections::HashSet<String> =
                specs.iter().map(|s| s.id.clone()).collect();

            // Remove panes no longer wanted (collect ids first to avoid holding the
            // lock across teardown, which pumps GTK).
            let stale: Vec<String> = {
                let panes = st.panes.lock().unwrap_or_else(|p| p.into_inner());
                panes
                    .keys()
                    .filter(|k| !desired.contains(*k))
                    .cloned()
                    .collect()
            };
            for id in stale {
                let pane = st
                    .panes
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .remove(&id);
                if let Some(pane) = pane {
                    destroy_pane(&id, pane, &overlay);
                }
            }

            // Update existing panes (cheap: rect + loadfile-on-url-change reuses the
            // SAME mpv instance) and collect the specs that need a brand new pane.
            let mut new_specs = Vec::new();
            for spec in &specs {
                let existing = {
                    let panes = st.panes.lock().unwrap_or_else(|p| p.into_inner());
                    panes.get(&spec.id).map(|p| p.url.clone())
                };
                if let Some(url) = existing {
                    AREAS.with(|a| {
                        if let Some(area) = a.borrow().get(&spec.id) {
                            apply_rect(area, spec);
                        }
                    });
                    if url != spec.url {
                        let mut panes = st.panes.lock().unwrap_or_else(|p| p.into_inner());
                        if let Some(p) = panes.get_mut(&spec.id) {
                            let _ = p.mpv.loadfile(&spec.url);
                            p.url = spec.url.clone();
                            if !spec.preserve_zoom {
                                p.zoom_log2 = 0.0;
                                p.pan_x = 0.0;
                                p.pan_y = 0.0;
                                let _ = p.mpv.set_property("video-zoom", "0");
                                let _ = p.mpv.set_property("video-pan-x", "0");
                                let _ = p.mpv.set_property("video-pan-y", "0");
                            }
                        }
                    }
                } else {
                    // New pane: create + realize the GLArea now (fast, main-thread-only);
                    // its mpv instance is spawned in phase 2, off this thread.
                    match create_area(&app2, &overlay, spec) {
                        Ok(area) => {
                            AREAS.with(|a| a.borrow_mut().insert(spec.id.clone(), area));
                            new_specs.push(spec.clone());
                        }
                        Err(e) => {
                            // Don't abort the whole batch over one bad widget — log and
                            // move on so the rest of the wall still comes up.
                            eprintln!("sync_panes: GLArea create failed for {}: {e}", spec.id);
                        }
                    }
                }
            }
            Ok(new_specs)
        }
    })?;

    // ── PHASE 2 (worker threads, NOT the GTK main thread): the slow part — spin
    // up mpv (initialize + loadfile) for every new pane IN PARALLEL. `Mpv` is
    // `Send` and this never touches GTK/GL, so it's safe here.
    let spawned: Vec<(String, Result<Mpv, String>)> = std::thread::scope(|s| {
        let handles: Vec<_> = new_specs
            .iter()
            .map(|spec| {
                let id = spec.id.clone();
                let url = spec.url.clone();
                (id, s.spawn(move || spawn_mpv_slow(&url)))
            })
            .collect();
        handles
            .into_iter()
            .map(|(id, h)| {
                let res = h
                    .join()
                    .unwrap_or_else(|_| Err("mpv init thread panicked".into()));
                (id, res)
            })
            .collect()
    });

    // ── PHASE 3 (main thread): bind each new mpv's render context (GL-dependent,
    // needs the GLArea current) and insert into the pane map; tear down the
    // widget for any pane whose mpv failed to init.
    let app3 = app.clone();
    crate::on_main(app, move || {
        let st = app3.state::<AppState>();
        let overlay = OVERLAY.with(|o| o.borrow().clone());
        for (id, res) in spawned {
            let area = AREAS.with(|a| a.borrow().get(&id).cloned());
            let Some(area) = area else { continue }; // widget vanished (shouldn't happen)
            match res {
                Ok(mpv) => {
                    area.make_current();
                    match bind_render_ctx(&mpv) {
                        Ok(render_ctx) => {
                            let url = new_specs
                                .iter()
                                .find(|s| s.id == id)
                                .map(|s| s.url.clone())
                                .unwrap_or_default();
                            st.panes.lock().unwrap_or_else(|p| p.into_inner()).insert(
                                id,
                                Pane {
                                    render_ctx,
                                    mpv,
                                    url,
                                    zoom_log2: 0.0,
                                    pan_x: 0.0,
                                    pan_y: 0.0,
                                },
                            );
                        }
                        Err(e) => {
                            eprintln!("sync_panes: render context failed for {id}: {e}");
                            AREAS.with(|a| a.borrow_mut().remove(&id));
                            if let Some(ov) = &overlay {
                                ov.remove(&area);
                            }
                        }
                    }
                }
                Err(e) => {
                    eprintln!("sync_panes: mpv init failed for {id}: {e}");
                    AREAS.with(|a| a.borrow_mut().remove(&id));
                    if let Some(ov) = &overlay {
                        ov.remove(&area);
                    }
                }
            }
        }
        // Re-run get-child-position to apply the latest rects.
        if let Some(ov) = &overlay {
            ov.queue_resize();
        }
        Ok(())
    })?;

    // Report the current zoom of every pane the caller asked for (matches the
    // previous return contract: one PaneZoom per requested spec that now exists).
    let st2 = app.state::<AppState>();
    let map = st2.panes.lock().unwrap_or_else(|p| p.into_inner());
    Ok(specs
        .iter()
        .filter_map(|spec| {
            map.get(&spec.id).map(|p| PaneZoom {
                id: spec.id.clone(),
                zoom: p.zoom_log2,
            })
        })
        .collect())
}

pub fn clear_panes(app: &AppHandle) -> Result<(), String> {
    let st = app.state::<AppState>();
    let _sync = st.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
    let app2 = app.clone();
    crate::on_main(app, move || {
        let st = app2.state::<AppState>();
        let overlay = OVERLAY.with(|o| o.borrow().clone());
        let all: Vec<(String, Pane)> = {
            let mut panes = st.panes.lock().unwrap_or_else(|p| p.into_inner());
            panes.drain().collect()
        };
        for (id, pane) in all {
            if let Some(ov) = &overlay {
                destroy_pane(&id, pane, ov);
            } else {
                pane.render_ctx.clear_update_callback();
                AREAS.with(|a| a.borrow_mut().remove(&id));
                drop(pane);
            }
        }
        Ok(())
    })
}

pub fn set_panes_hidden(
    app: &AppHandle,
    hidden: bool,
    ids: Option<Vec<String>>,
) -> Result<(), String> {
    crate::on_main(app, move || {
        AREAS.with(|a| {
            for (id, area) in a.borrow().iter() {
                let target = ids.as_ref().is_none_or(|list| list.contains(id));
                if target {
                    area.set_visible(!hidden);
                }
            }
        });
        Ok(())
    })
}

/// Reload a pane's source by fully RECREATING its mpv instance + render context
/// (not a plain `loadfile` reuse of the same instance). Mirrors the Windows
/// backend (`lib.rs::reload_pane`): a plain `loadfile` doesn't reliably clear a
/// wedged RTSP demuxer, but a full teardown/recreate does. The GLArea widget
/// itself is kept (only its mpv backing is replaced), so the pane's screen
/// position/z-order is untouched.
pub fn reload_pane(app: &AppHandle, id: String) -> Result<(), String> {
    let st = app.state::<AppState>();
    let _sync = st.sync_lock.lock().unwrap_or_else(|p| p.into_inner());
    let app2 = app.clone();
    crate::on_main(app, move || {
        let st = app2.state::<AppState>();
        let old = {
            let mut panes = st.panes.lock().unwrap_or_else(|p| p.into_inner());
            panes.remove(&id)
        };
        let Some(old_pane) = old else {
            return Err(format!("no pane {id}"));
        };
        let url = old_pane.url.clone();

        let area = AREAS.with(|a| a.borrow().get(&id).cloned());
        let Some(area) = area else {
            // Pane data existed but its widget didn't — drop the old mpv/ctx and
            // report failure so the JS watchdog's scheduleSync() rebuilds cleanly.
            drop(old_pane);
            return Err(format!("no GLArea widget for pane {id}"));
        };

        // GL context current so the old render-context free (Mpv/RenderCtx Drop,
        // field order enforces render_ctx-before-mpv) and the new context create
        // are both valid.
        area.make_current();
        drop(old_pane); // render_ctx.free() then mpv_terminate_destroy, old stream torn down

        match spawn_mpv_for_area(&app2, &id, &url) {
            Ok((mpv, render_ctx)) => {
                st.panes.lock().unwrap_or_else(|p| p.into_inner()).insert(
                    id,
                    Pane {
                        render_ctx,
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
                // Recreate failed — the pane is now out of the map but the GLArea
                // widget is still there (blank/erroring). Remove it too so the next
                // sync_panes recreates the pane cleanly rather than leaving a dead
                // widget occluding a black tile forever.
                AREAS.with(|a| a.borrow_mut().remove(&id));
                if let Some(ov) = OVERLAY.with(|o| o.borrow().clone()) {
                    ov.remove(&area);
                }
                Err(e)
            }
        }
    })
}
