// SPDX-License-Identifier: AGPL-3.0-or-later

//! Minimal libmpv client-API binding, loaded at runtime via `libloading`.
//!
//! We deliberately avoid a link-time dependency on libmpv: the app ships
//! `libmpv-2.dll` next to the executable and loads it dynamically. Only the
//! handful of client-API functions the Crumb Client needs are bound here.
//!
//! mpv's client API is thread-safe; callers additionally serialize access
//! through a `Mutex` in the Tauri managed state.

use libloading::Library;
use std::ffi::{c_char, c_int, c_void, CString};
use std::ptr;

type MpvHandle = *mut c_void;

type FnCreate = unsafe extern "C" fn() -> MpvHandle;
type FnInitialize = unsafe extern "C" fn(MpvHandle) -> c_int;
type FnTerminate = unsafe extern "C" fn(MpvHandle);
type FnSetOptionString = unsafe extern "C" fn(MpvHandle, *const c_char, *const c_char) -> c_int;
type FnSetPropertyString = unsafe extern "C" fn(MpvHandle, *const c_char, *const c_char) -> c_int;
type FnGetPropertyString = unsafe extern "C" fn(MpvHandle, *const c_char) -> *mut c_char;
type FnFree = unsafe extern "C" fn(*mut c_void);
type FnCommand = unsafe extern "C" fn(MpvHandle, *const *const c_char) -> c_int;

// ─── render API (OpenGL) — Linux only ─────────────────────────────────────────
//
// Used by the Linux backend to render each pane into a `GtkGLArea`'s framebuffer
// (the `wid` window-embedding model the Windows backend uses has no Wayland
// equivalent). These symbols ship in the same `libmpv` and are resolved lazily by
// [`Mpv::create_render_context`]. Gated to Linux so Windows (which uses
// `wid`/`vo=gpu`) never references them. See `render.h` / `render_gl.h`.
#[cfg(target_os = "linux")]
pub use render_gl::*;

#[cfg(target_os = "linux")]
mod render_gl {
    use super::MpvHandle;
    use std::ffi::{c_char, c_int, c_void};

    /// Opaque `mpv_render_context*`.
    pub type MpvRenderContext = *mut c_void;

    /// `mpv_render_param` — a tagged `{type, data}` pair passed in NULL-terminated
    /// arrays to the render-context create/render calls.
    #[repr(C)]
    pub struct MpvRenderParam {
        pub type_: c_int,
        pub data: *mut c_void,
    }

    /// `mpv_opengl_init_params` — the app-supplied GL proc-address loader. The
    /// current header has exactly these two members (`extra_exts` was removed).
    #[repr(C)]
    pub struct MpvOpenglInitParams {
        pub get_proc_address:
            Option<unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void>,
        pub get_proc_address_ctx: *mut c_void,
    }

    /// `mpv_opengl_fbo` — the target framebuffer for one `render` call.
    #[repr(C)]
    pub struct MpvOpenglFbo {
        pub fbo: c_int,
        pub w: c_int,
        pub h: c_int,
        pub internal_format: c_int,
    }

    // mpv_render_param_type enum values (stable ABI).
    pub(super) const MPV_RENDER_PARAM_INVALID: c_int = 0;
    pub(super) const MPV_RENDER_PARAM_API_TYPE: c_int = 1;
    pub(super) const MPV_RENDER_PARAM_OPENGL_INIT_PARAMS: c_int = 2;
    pub(super) const MPV_RENDER_PARAM_OPENGL_FBO: c_int = 3;
    pub(super) const MPV_RENDER_PARAM_FLIP_Y: c_int = 4;
    pub(super) const MPV_RENDER_PARAM_ADVANCED_CONTROL: c_int = 10;

    /// Update callback — invoked by mpv on an arbitrary thread when a redraw is
    /// wanted.
    pub type MpvRenderUpdateFn = unsafe extern "C" fn(cb_ctx: *mut c_void);

    pub(super) type FnRenderCreate =
        unsafe extern "C" fn(*mut MpvRenderContext, MpvHandle, *mut MpvRenderParam) -> c_int;
    pub(super) type FnRenderSetUpdate =
        unsafe extern "C" fn(MpvRenderContext, Option<MpvRenderUpdateFn>, *mut c_void);
    pub(super) type FnRenderRender =
        unsafe extern "C" fn(MpvRenderContext, *mut MpvRenderParam) -> c_int;
    pub(super) type FnRenderReportSwap = unsafe extern "C" fn(MpvRenderContext);
    pub(super) type FnRenderFree = unsafe extern "C" fn(MpvRenderContext);
}

/// A single libmpv instance bound to a host window (via the `wid` option).
pub struct Mpv {
    _lib: Library, // kept alive so the resolved fn pointers stay valid
    handle: MpvHandle,
    f_initialize: FnInitialize,
    f_terminate: FnTerminate,
    f_set_option_string: FnSetOptionString,
    f_set_property_string: FnSetPropertyString,
    f_get_property_string: FnGetPropertyString,
    f_free: FnFree,
    f_command: FnCommand,
}

// The mpv client API is thread-safe and the raw handle is only ever touched
// behind a Mutex in the app state.
unsafe impl Send for Mpv {}

impl Mpv {
    /// Load `libmpv-2.dll` from `dll_path` (or a name resolvable by the OS
    /// loader — exe dir / PATH) and create an uninitialized mpv context.
    pub fn create(dll_path: &str) -> Result<Self, String> {
        unsafe {
            let lib =
                Library::new(dll_path).map_err(|e| format!("load libmpv ({dll_path}): {e}"))?;
            let f_create: FnCreate = *lib.get(b"mpv_create\0").map_err(sym_err)?;
            let f_initialize: FnInitialize = *lib.get(b"mpv_initialize\0").map_err(sym_err)?;
            let f_terminate: FnTerminate = *lib.get(b"mpv_terminate_destroy\0").map_err(sym_err)?;
            let f_set_option_string: FnSetOptionString =
                *lib.get(b"mpv_set_option_string\0").map_err(sym_err)?;
            let f_set_property_string: FnSetPropertyString =
                *lib.get(b"mpv_set_property_string\0").map_err(sym_err)?;
            let f_get_property_string: FnGetPropertyString =
                *lib.get(b"mpv_get_property_string\0").map_err(sym_err)?;
            let f_free: FnFree = *lib.get(b"mpv_free\0").map_err(sym_err)?;
            let f_command: FnCommand = *lib.get(b"mpv_command\0").map_err(sym_err)?;

            let handle = f_create();
            if handle.is_null() {
                return Err("mpv_create returned null".into());
            }
            Ok(Mpv {
                _lib: lib,
                handle,
                f_initialize,
                f_terminate,
                f_set_option_string,
                f_set_property_string,
                f_get_property_string,
                f_free,
                f_command,
            })
        }
    }

    /// Set an option (must be called before [`Mpv::initialize`] for window opts).
    pub fn set_option(&self, name: &str, value: &str) -> Result<(), String> {
        let n = cstr(name)?;
        let v = cstr(value)?;
        let r = unsafe { (self.f_set_option_string)(self.handle, n.as_ptr(), v.as_ptr()) };
        ok(r, || format!("set_option {name}={value}"))
    }

    /// Set a property at runtime (e.g. `pause`, `speed`, `time-pos`).
    pub fn set_property(&self, name: &str, value: &str) -> Result<(), String> {
        let n = cstr(name)?;
        let v = cstr(value)?;
        let r = unsafe { (self.f_set_property_string)(self.handle, n.as_ptr(), v.as_ptr()) };
        ok(r, || format!("set_property {name}={value}"))
    }

    /// Read a property as a string (e.g. `time-pos`, `core-idle`). Returns None
    /// if the property is unavailable. The mpv-allocated string is freed via
    /// `mpv_free`.
    pub fn get_property(&self, name: &str) -> Option<String> {
        let n = cstr(name).ok()?;
        unsafe {
            let raw = (self.f_get_property_string)(self.handle, n.as_ptr());
            if raw.is_null() {
                return None;
            }
            let s = std::ffi::CStr::from_ptr(raw).to_string_lossy().into_owned();
            (self.f_free)(raw as *mut c_void);
            Some(s)
        }
    }

    /// Initialize the player after options/`wid` are set.
    pub fn initialize(&self) -> Result<(), String> {
        let r = unsafe { (self.f_initialize)(self.handle) };
        ok(r, || "mpv_initialize".to_string())
    }

    /// Run a command as a NULL-terminated argv (e.g. `["loadfile", url]`).
    pub fn command(&self, args: &[&str]) -> Result<(), String> {
        let owned: Vec<CString> = args.iter().map(|s| cstr(s)).collect::<Result<_, _>>()?;
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(ptr::null());
        let r = unsafe { (self.f_command)(self.handle, ptrs.as_ptr()) };
        ok(r, || format!("command {args:?}"))
    }

    pub fn loadfile(&self, url: &str) -> Result<(), String> {
        self.command(&["loadfile", url])
    }

    pub fn loadfile_append(&self, url: &str) -> Result<(), String> {
        self.command(&["loadfile", url, "append"])
    }

    pub fn playlist_clear(&self) -> Result<(), String> {
        self.command(&["playlist-clear"])
    }

    /// Create an OpenGL render context for this player (Linux render-API path).
    ///
    /// `get_proc_address` resolves GL symbols against the *current* GL context
    /// (e.g. the `GtkGLArea`'s, via libepoxy), and `get_proc_ctx` is passed back to
    /// it opaquely. Requires `vo=libmpv` to have been set before [`Mpv::initialize`].
    ///
    /// The 6 render symbols are resolved here (not in [`Mpv::create`]) so platforms
    /// that never call this — Windows, which uses `wid`/`vo=gpu` — don't load them.
    ///
    /// # Lifetime / drop-ordering (critical)
    ///
    /// The returned [`RenderCtx`] borrows fn pointers that live inside this `Mpv`'s
    /// loaded library. It **must be dropped before** the owning `Mpv` (whose `Drop`
    /// terminates the core and can unload the library), and its `Drop`
    /// (`mpv_render_context_free`) **must run with the GL context current**. Callers
    /// enforce both by field order (render ctx before mpv) + an explicit
    /// `make_current()` at teardown.
    #[cfg(target_os = "linux")]
    pub fn create_render_context(
        &self,
        get_proc_address: unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void,
        get_proc_ctx: *mut c_void,
    ) -> Result<RenderCtx, String> {
        unsafe {
            let f_create: FnRenderCreate = *self
                ._lib
                .get(b"mpv_render_context_create\0")
                .map_err(sym_err)?;
            let f_set_update: FnRenderSetUpdate = *self
                ._lib
                .get(b"mpv_render_context_set_update_callback\0")
                .map_err(sym_err)?;
            let f_render: FnRenderRender = *self
                ._lib
                .get(b"mpv_render_context_render\0")
                .map_err(sym_err)?;
            let f_report_swap: FnRenderReportSwap = *self
                ._lib
                .get(b"mpv_render_context_report_swap\0")
                .map_err(sym_err)?;
            let f_free: FnRenderFree = *self
                ._lib
                .get(b"mpv_render_context_free\0")
                .map_err(sym_err)?;

            let api = cstr("opengl")?;
            let mut init = MpvOpenglInitParams {
                get_proc_address: Some(get_proc_address),
                get_proc_address_ctx: get_proc_ctx,
            };
            let mut advanced: c_int = 1; // we drive the render loop ourselves
            let mut params = [
                MpvRenderParam {
                    type_: MPV_RENDER_PARAM_API_TYPE,
                    data: api.as_ptr() as *mut c_void,
                },
                MpvRenderParam {
                    type_: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                    data: std::ptr::addr_of_mut!(init).cast::<c_void>(),
                },
                MpvRenderParam {
                    type_: MPV_RENDER_PARAM_ADVANCED_CONTROL,
                    data: std::ptr::addr_of_mut!(advanced).cast::<c_void>(),
                },
                MpvRenderParam {
                    type_: MPV_RENDER_PARAM_INVALID,
                    data: ptr::null_mut(),
                },
            ];
            let mut ctx: MpvRenderContext = ptr::null_mut();
            let r = f_create(&mut ctx, self.handle, params.as_mut_ptr());
            if r < 0 || ctx.is_null() {
                return Err(format!("mpv_render_context_create failed ({r})"));
            }
            Ok(RenderCtx {
                ctx,
                f_set_update,
                f_render,
                f_report_swap,
                f_free,
            })
        }
    }
}

/// An OpenGL render context bound to an [`Mpv`] instance. See
/// [`Mpv::create_render_context`] for the hard drop-ordering rule.
#[cfg(target_os = "linux")]
pub struct RenderCtx {
    ctx: MpvRenderContext,
    f_set_update: FnRenderSetUpdate,
    f_render: FnRenderRender,
    f_report_swap: FnRenderReportSwap,
    f_free: FnRenderFree,
}

// The render context is only ever touched on the GTK main thread (behind the same
// app-state Mutex as `Mpv`); the raw pointer is moved between threads only while
// parked in that map.
#[cfg(target_os = "linux")]
unsafe impl Send for RenderCtx {}

#[cfg(target_os = "linux")]
impl RenderCtx {
    /// Register mpv's update callback. `cb` fires on an arbitrary thread when a
    /// redraw is wanted — it must only marshal a repaint to the GTK main loop, never
    /// render directly. `cb_ctx` is passed back opaquely.
    pub fn set_update_callback(&self, cb: MpvRenderUpdateFn, cb_ctx: *mut c_void) {
        unsafe { (self.f_set_update)(self.ctx, Some(cb), cb_ctx) }
    }

    /// Detach the update callback (call before teardown so no callback fires during
    /// `mpv_render_context_free`).
    pub fn clear_update_callback(&self) {
        unsafe { (self.f_set_update)(self.ctx, None, std::ptr::null_mut()) }
    }

    /// Render the current frame into the bound GL framebuffer `fbo` (sized `w`×`h`
    /// in physical px). `flip_y` accounts for GL's bottom-left origin.
    pub fn render_fbo(&self, fbo: i32, w: i32, h: i32, flip_y: bool) -> Result<(), String> {
        let mut fbo_param = MpvOpenglFbo {
            fbo,
            w,
            h,
            internal_format: 0,
        };
        let mut flip: c_int = c_int::from(flip_y);
        let mut params = [
            MpvRenderParam {
                type_: MPV_RENDER_PARAM_OPENGL_FBO,
                data: std::ptr::addr_of_mut!(fbo_param).cast::<c_void>(),
            },
            MpvRenderParam {
                type_: MPV_RENDER_PARAM_FLIP_Y,
                data: std::ptr::addr_of_mut!(flip).cast::<c_void>(),
            },
            MpvRenderParam {
                type_: MPV_RENDER_PARAM_INVALID,
                data: ptr::null_mut(),
            },
        ];
        let r = unsafe { (self.f_render)(self.ctx, params.as_mut_ptr()) };
        ok(r, || "mpv_render_context_render".to_string())
    }

    /// Tell mpv a buffer swap just happened (paired with `ADVANCED_CONTROL`).
    pub fn report_swap(&self) {
        unsafe { (self.f_report_swap)(self.ctx) }
    }
}

#[cfg(target_os = "linux")]
impl Drop for RenderCtx {
    fn drop(&mut self) {
        // MUST run with the GL context current and BEFORE the owning Mpv drops.
        unsafe { (self.f_free)(self.ctx) }
    }
}

impl Drop for Mpv {
    fn drop(&mut self) {
        unsafe { (self.f_terminate)(self.handle) };
    }
}

fn cstr(s: &str) -> Result<CString, String> {
    CString::new(s).map_err(|_| format!("string contains interior NUL: {s:?}"))
}

fn ok(code: c_int, ctx: impl FnOnce() -> String) -> Result<(), String> {
    if code < 0 {
        Err(format!("libmpv error {code} in {}", ctx()))
    } else {
        Ok(())
    }
}

fn sym_err(e: libloading::Error) -> String {
    format!("libmpv symbol missing: {e}")
}
