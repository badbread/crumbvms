// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * CrumbVMS — Phase 2: Live Wall
 *
 * Architecture overview:
 *  - Video tiles are empty <div> placeholders. The Rust side composites a
 *    native libmpv child window over each one, pixel-aligned to its rect.
 *  - `sync_panes()` is the single reconciliation call that tells Rust exactly
 *    what panes should exist and where. We call it after every state change
 *    that affects visible tiles (layout change, assignment, resize, maximize).
 *  - State lives in a plain JS object — no framework needed.
 */

// ── Tauri bridge ─────────────────────────────────────────────────────────────
// Tauri 2 exposes invoke via window.__TAURI__.core when withGlobalTauri=true.
const { invoke } = window.__TAURI__.core;

// ── Constants ─────────────────────────────────────────────────────────────────
const LS_TOKEN_KEY   = 'crumb_token';
const LS_SERVER_KEY  = 'crumb_server';
const LS_USER_KEY    = 'crumb_user';      // remembered username (prefill)
const LS_REMEMBER_KEY = 'crumb_remember'; // "keep me signed in" preference ('0'/'1')
const LS_OPTIONS_KEY = 'crumb_options';

// ── Session token at-rest encryption (H4) ────────────────────────────────────
// localStorage is a plaintext file on disk — a long-lived "remember me" token
// sitting in it as cleartext is readable by anything with filesystem access to
// the profile. On Windows, encrypt it with DPAPI (tied to the OS user account)
// before it ever touches localStorage; secret_encrypt/secret_decrypt are
// no-ops (return the input unchanged) on other platforms — see the Rust-side
// note in lib.rs. Callers should use these instead of touching LS_TOKEN_KEY
// directly.
async function saveToken(token) {
  try {
    const enc = await invoke('secret_encrypt', { plaintext: token });
    localStorage.setItem(LS_TOKEN_KEY, enc);
  } catch (e) {
    // Fail closed on the encryption step, not on the login itself — worst case
    // the token doesn't persist and the user has to sign in again next launch.
    console.warn('secret_encrypt failed, token will not persist:', e);
  }
}
async function loadToken() {
  const stored = localStorage.getItem(LS_TOKEN_KEY);
  if (!stored) return null;
  try {
    return await invoke('secret_decrypt', { ciphertext: stored });
  } catch (e) {
    // Undecryptable (different Windows user/machine, or corrupted) — treat as
    // no saved session rather than crashing the boot-restore path.
    console.warn('secret_decrypt failed, dropping stored token:', e);
    localStorage.removeItem(LS_TOKEN_KEY);
    return null;
  }
}

// Height (CSS px) of the per-tile title strip (camera name + REC/motion dots).
// The native video pane is inset below it so the strip stays visible over video.
const TILE_STRIP_PX = 22;

// ── Options (persisted) ─────────────────────────────────────────────────────────
// User preferences that aren't per-view. Backed by localStorage.
//   showInfoBar  — show the per-tile title strip (name + REC/motion indicators)
//   ptzClickMode — what a click on a PTZ video does: 'center' | 'pan' | 'off'
const options = loadOptions();
function loadOptions() {
  const defaults = { showInfoBar: true, ptzClickMode: 'center', ptzStyle: 'edges', ptzWheelCorner: 'bottom-left', showAllCamerasView: true, launchFullscreen: false, liveWallSub: true, maximizeMain: true, hotkeysEnabled: true, zoomClipsToMotion: true, clipsDensity: 'normal' };
  try { return { ...defaults, ...JSON.parse(localStorage.getItem(LS_OPTIONS_KEY) || '{}') }; }
  catch { return { ...defaults }; }
}
function saveOptions() {
  try { localStorage.setItem(LS_OPTIONS_KEY, JSON.stringify(options)); } catch { /* quota */ }
}
/** Current title-strip height (0 when the info bar is hidden). */
function tileStripPx() { return options.showInfoBar ? TILE_STRIP_PX : 0; }

// ── Per-camera live stream preference (main | sub) ────────────────────────────
// Desktop defaults to the FULL MAIN stream, but a constrained client (bandwidth,
// a weak GPU, a remote link) can drop any camera to its low-rate SUB stream.
// Stored client-side by camera id.
const LS_STREAM_PREF = 'crumb_stream_pref';
let streamPref = (() => { try { return JSON.parse(localStorage.getItem(LS_STREAM_PREF) || '{}'); } catch { return {}; } })();
/** The DEFAULT wall stream when a camera has no explicit per-camera override —
 *  sub when the "wall uses sub" option is on (low bandwidth), else main. */
function wallDefaultStream() { return options.liveWallSub !== false ? 'sub' : 'main'; }
/** The EFFECTIVE wall stream for a camera: explicit override, else the wall
 *  default. (Used for the right-click Stream menu's ✓.) */
function getStreamPref(camId) { return streamPref[camId] === 'sub' || streamPref[camId] === 'main' ? streamPref[camId] : wallDefaultStream(); }
/** Set an explicit per-camera override (persists in localStorage — sticks). */
function setStreamPref(camId, which) {
  streamPref[camId] = (which === 'sub') ? 'sub' : 'main';
  try { localStorage.setItem(LS_STREAM_PREF, JSON.stringify(streamPref)); } catch { /* quota */ }
}
// camIds whose MAIN stream produced no frame on maximize this session (e.g. a dead
// or contended main — like an LPR whose main channel is held by another consumer).
// We then maximize to the working SUB instead of a black pane. Sticky per session;
// cleared when streams are refetched (a server-side config change) so a fixed main
// is retried. See scheduleMaximizedMainCheck().
const mainUnavailable = new Set();

/** The live RTSP URL for a camera. On the wall it honours the per-camera override
 *  (else the wall default). A MAXIMIZED / fullscreen tile jumps to MAIN for full
 *  quality when the "maximize uses main" option is on (default), regardless of the
 *  wall choice — so the wall can stay on light sub-streams and full-screen is HD.
 *  Falls back to whichever stream the camera actually has — and if MAIN is known
 *  unavailable this session, a maximized tile uses the SUB (no black). */
function liveStreamUrl(camId, isMaximized) {
  const s = state.streams.get(camId);
  if (!s) return null;
  if (isMaximized && options.maximizeMain !== false) {
    if (mainUnavailable.has(camId)) return s.rtsp_sub_url ?? s.rtsp_main_url;
    return s.rtsp_main_url ?? s.rtsp_sub_url;
  }
  return getStreamPref(camId) === 'sub'
    ? (s.rtsp_sub_url ?? s.rtsp_main_url)
    : (s.rtsp_main_url ?? s.rtsp_sub_url);
}

/** The slot the in-view PTZ overlay covers (active PTZ tile), or null. */
function ptzOverlaySlot() {
  // ptzVideoMode / ptzActiveSlot defined later; guard for early calls.
  if (typeof ptzVideoMode === 'undefined' || ptzVideoMode === 'off') return null;
  if (!ptzCameraId) return null;
  return ptzActiveSlot();
}
/** Bottom inset (CSS px) for a tile. PTZ no longer carves a box — its compact
 *  control cluster floats in the existing top strip and directional control is
 *  on the video itself — so this is always 0. */
function tileBottomInset(_slot) { return 0; }

// Layout definitions: id, label, tile count, CSS class
const LAYOUTS = [
  { id: '1x1',     label: '1×1',  tiles: 1,  cls: 'layout-1x1'     },
  { id: '2x2',     label: '2×2',  tiles: 4,  cls: 'layout-2x2'     },
  { id: '3x3',     label: '3×3',  tiles: 9,  cls: 'layout-3x3'     },
  { id: '1plus5',  label: '1+5',  tiles: 6,  cls: 'layout-1plus5'  },
  { id: '4x4',     label: '4×4',  tiles: 16, cls: 'layout-4x4'     },
];

// ── Saved Views (server-side, shared across all clients via the API) ───────────
// Views live in the Crumb DB (GET/POST/DELETE /views) so a saved layout
// follows the operator to any client (web/desktop/mobile). `viewsCache` holds
// the last-fetched list so rendering stays synchronous.
let viewsCache = [];

// The view the app opens to on launch (user-chosen). Stored client-side; value is
// a saved-view id or the '__all__' sentinel (All Cameras). null = the auto-fit grid.
const LS_DEFAULT_VIEW = 'crumb_default_view';
function getDefaultView() { try { return localStorage.getItem(LS_DEFAULT_VIEW) || null; } catch { return null; } }
function setDefaultView(id) {
  try {
    if (getDefaultView() === id) { localStorage.removeItem(LS_DEFAULT_VIEW); setStatus('Launch view cleared — opens to the full grid.'); }
    else { localStorage.setItem(LS_DEFAULT_VIEW, id); setStatus('Set as the view shown on launch.'); }
  } catch { /* quota */ }
  buildLayoutPresets(); // refresh the ★ badge
}

// User-chosen ordering of saved views (client-side), applied to the toolbar
// buttons AND the Config-View "Start from" list.
const LS_VIEW_ORDER = 'crumb_view_order';
function getViewOrder() { try { return JSON.parse(localStorage.getItem(LS_VIEW_ORDER) || '[]'); } catch { return []; } }
function setViewOrder(ids) { try { localStorage.setItem(LS_VIEW_ORDER, JSON.stringify(ids)); } catch { /* quota */ } }
/** `viewsCache` sorted by the saved order; ids with no saved position keep their
 *  natural order at the end. */
function orderedViews() {
  const order = getViewOrder();
  const pos = id => { const i = order.indexOf(id); return i < 0 ? 1e9 : i; };
  return [...viewsCache].sort((a, b) => pos(a.id) - pos(b.id));
}
/** Move a view one slot up (dir=-1) or down (dir=+1) in the ordering. */
function moveView(id, dir) {
  const ids = orderedViews().map(v => v.id);
  const i = ids.indexOf(id), j = i + dir;
  if (i < 0 || j < 0 || j >= ids.length) return;
  [ids[i], ids[j]] = [ids[j], ids[i]];
  setViewOrder(ids);
  vsRenderLoadList();
  buildLayoutPresets();
}

// Per-view quick-switch icon. Server-side (views.icon, synced via PUT
// /views/:id/icon) is now the source of truth so it follows the operator to any
// client; localStorage is kept only as an offline-first cache/fallback for views
// the server hasn't got an icon for yet (or a stale cache read before the first
// fetch completes).
const LS_VIEW_ICONS = 'crumb_view_icons';
let viewIcons = (() => { try { return JSON.parse(localStorage.getItem(LS_VIEW_ICONS) || '{}'); } catch { return {}; } })();
const VIEW_ICON_CHOICES = ['🎥','📹','🚗','🚙','🌳','🏠','🚪','🅿️','⛰️','🌙','☀️','👁️','🐕','🔑','🚧','🏢','📦','🛣️'];
/** Resolve the icon to show for a view: server value (viewsCache) first, then
 *  the localStorage cache, then the hardcoded default glyph. */
function getViewIcon(id) {
  const v = viewsCache.find(x => x.id === id);
  if (v && v.icon) return v.icon;
  return viewIcons[id] || '🎥';
}
/** Set a view's icon: updates the localStorage cache immediately (so the UI is
 *  never blocked on the network) and best-effort PUTs it to the server so it
 *  syncs to other clients. Also patches viewsCache in place so getViewIcon()
 *  reflects the change without waiting for a refetch. */
function setViewIcon(id, icon) {
  viewIcons[id] = icon;
  try { localStorage.setItem(LS_VIEW_ICONS, JSON.stringify(viewIcons)); } catch { /* quota */ }
  const v = viewsCache.find(x => x.id === id);
  if (v) v.icon = icon;
  pushViewIcon(id, icon);
  buildLayoutPresets();
}

/** Best-effort PUT of a view's icon to the server (fire-and-forget — the
 *  localStorage cache + in-memory viewsCache patch already made the change
 *  visible locally, so a transient network failure here just means the next
 *  client to log in won't see it until it's retried). */
async function pushViewIcon(id, icon) {
  try {
    const res = await fetchWithTimeout(`${state.server}/views/${id}/icon`, {
      method: 'PUT',
      headers: authHeaders(),
      body: JSON.stringify({ icon }),
    });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (!res.ok && res.status !== 204) throw new Error(`PUT /views/:id/icon → ${res.status}`);
  } catch (e) {
    console.warn(`pushViewIcon(${id}) failed (will retry next time the icon changes):`, e);
  }
}

// One-time localStorage→server migration: the very first time this client runs
// after icons became server-side, any view that already has a localStorage icon
// but no server icon gets that icon PUT up to the server, so an operator's
// existing per-view icons (set before this feature existed) aren't silently
// dropped when they next log in from a different machine. Guarded by a
// localStorage flag so it only ever runs once per browser profile — after that,
// setViewIcon()'s own PUT keeps things in sync going forward.
const LS_VIEW_ICON_MIGRATED = 'crumb_view_icons_migrated_v1';
async function migrateLocalViewIconsToServer() {
  try {
    if (localStorage.getItem(LS_VIEW_ICON_MIGRATED)) return;
  } catch {
    return; // localStorage unavailable — nothing to migrate from, nothing to guard.
  }
  const pending = viewsCache.filter(v => !v.icon && viewIcons[v.id]);
  // Best-effort, one at a time is fine — this runs once, in the background, for
  // a handful of views at most.
  for (const v of pending) {
    await pushViewIcon(v.id, viewIcons[v.id]);
    v.icon = viewIcons[v.id]; // reflect locally so getViewIcon() prefers it immediately
  }
  try { localStorage.setItem(LS_VIEW_ICON_MIGRATED, '1'); } catch { /* quota — best effort */ }
}

/** Fetch all views from the API into viewsCache. */
async function fetchViews() {
  try {
    const res = await fetchWithTimeout(`${state.server}/views`, { headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (!res.ok) throw new Error(`GET /views → ${res.status}`);
    viewsCache = await res.json(); // [{id,name,layout,slots,owner_id,icon,created_at}]
  } catch (e) {
    console.warn('fetchViews failed:', e);
  }
}

/** Fetch + render the saved-views list. */
async function refreshViews() {
  await fetchViews();
  renderSavedViews();
}

/** Save the current wall arrangement as a named view (POST /views).
 *  `icon`, when given, travels with the view on creation so a fresh client (or a
 *  second machine) sees the chosen icon immediately instead of only the default. */
async function saveView(name, icon = null) {
  if (!name || !name.trim()) return;
  const slots = {};
  // Store each filled slot's spec. Plain cameras stay a bare camera-id STRING so the
  // existing {idx:cam} contract (web/android) keeps working; richer view-items store
  // their full spec object (jsonb on the server accepts either).
  const tileCount = getLayout().tiles;
  for (let i = 0; i < tileCount; i++) {
    const sp = slotSpec(i);
    if (sp) slots[String(i)] = sp.type === 'camera' ? sp.cameraId : sp;
  }
  // Custom layouts encode their geometry into the layout string ("custom:{json}")
  // so the existing {idx:cam} slots contract (used by web/android) stays clean.
  const layoutField = (state.layoutId === 'custom' && state.customLayout)
    ? 'custom:' + JSON.stringify(state.customLayout)
    : state.layoutId;
  try {
    const res = await fetchWithTimeout(`${state.server}/views`, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({ name: name.trim(), layout: layoutField, slots, icon }),
    });
    if (res.status === 401) { handleUnauthorized(); return null; }
    if (!res.ok) throw new Error(`POST /views → ${res.status}`);
    // The API returns the created ViewDto; capture its id so the caller can set
    // a per-view icon. Fall back to a name match after refresh if absent.
    let created = null;
    try { created = await res.json(); } catch { /* no body */ }
    await refreshViews();
    setStatus(`Saved view "${name.trim()}"`);
    return created?.id ?? (viewsCache.find(v => v.name === name.trim())?.id ?? null);
  } catch (e) {
    setStatus(`Save view failed: ${e}`);
    return null;
  }
}

/** Human label for the status bar: the active VIEW's name (or "All Cameras"),
 *  falling back to the raw layout label for an unsaved custom arrangement. */
function currentViewLabel() {
  if (state.currentViewId === '__all__') return 'All Cameras';
  const v = state.currentViewId && viewsCache.find(x => x.id === state.currentViewId);
  return v ? v.name : getLayout().label;
}

/** Update the status-bar performance alert (CLIENT decode health) — shows ONLY when
 *  something's wrong: frame drops, high CPU, or saturated GPU decode. Cleared when
 *  healthy. Driven by hudTick so it works even with the F8 overlay off. */
function updateStatusAlert(agg, cpuPct, host) {
  const el = document.getElementById('status-alert');
  if (!el) return;
  const parts = [];
  if (agg && agg.dropsPerSec >= 1) parts.push(`⚠ ${agg.dropsPerSec.toFixed(1)} drops/s`);
  if (cpuPct != null && cpuPct >= 85) parts.push(`CPU ${Math.round(cpuPct)}%`);
  const gdec = host?.gpu_dec_util;
  if (gdec != null && gdec >= 90) parts.push(`GPU decode ${Math.round(gdec)}%`);
  el.textContent = parts.length ? parts.join(' · ') : '';
}

/**
 * Apply a saved view by id: restores layout + slot assignments and refreshes
 * the UI the same way the built-in layout/assign flow does.
 */
async function applyView(id) {
  const view = viewsCache.find(v => v.id === id);
  if (!view) return;

  state.currentViewId = id; // for the active-view highlight in the toolbar
  clearAllCarousels();
  state.maximized = null;

  // Decode custom-layout geometry encoded as "custom:{json}" in the layout field.
  if (typeof view.layout === 'string' && view.layout.startsWith('custom:')) {
    try {
      state.customLayout = normalizeCustomLayout(JSON.parse(view.layout.slice(7)));
      state.layoutId = state.customLayout ? 'custom' : '2x2';
    } catch {
      state.customLayout = null;
      state.layoutId = '2x2';
    }
  } else {
    state.customLayout = null;
    state.layoutId = view.layout;
  }

  state.slotMap.clear();
  state.slotItems.clear();
  state.hotspotCam = null;
  Object.entries(view.slots || {}).forEach(([slot, val]) => {
    const i = parseInt(slot, 10);
    const spec = normalizeTileSpec(val);
    if (!spec) return;
    if (spec.type === 'camera') state.slotMap.set(i, spec.cameraId);
    else state.slotItems.set(i, spec);
  });
  applySlotItems(); // derive carousel/ptz/hotspot slotMap entries + start engines

  state.selectedSlot = 0;

  buildLayoutPresets();
  buildCameraList();
  buildTileGrid(); // triggers syncPanes internally
  ptzRefresh();        // re-validate PTZ for the new selection (move/clear the wheel notch)
  pbReflectLayoutChange(); // clear playback maximize + rebuild the pb grid if visible

  // Applying a view changes the SHARED layout + slot assignments, which
  // pbReflectLayoutChange() above already mirrors into the Playback grid. So only
  // jump to Live when we're on a NON-wall view (Settings/Server) — never yank the
  // user out of Playback. (Already on Live → both flags false-ish, no switch.)
  const onPlayback = !els.viewPlayback.classList.contains('hidden');
  const onLive = !els.viewLive.classList.contains('hidden');
  if (!onPlayback && !onLive) {
    await activateTab('live');
  }
}

/** Delete a saved view by id (DELETE /views/:id) — no confirm, no list refresh.
 *  Also drops its client-side icon. Used by deleteView (after confirm) and by the
 *  save-as-replace flow. Caller refreshes the list. */
async function deleteViewQuiet(id) {
  try {
    const res = await fetchWithTimeout(`${state.server}/views/${id}`, { method: 'DELETE', headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); return false; }
    if (!res.ok && res.status !== 204) throw new Error(`DELETE /views → ${res.status}`);
    if (viewIcons[id]) { delete viewIcons[id]; try { localStorage.setItem(LS_VIEW_ICONS, JSON.stringify(viewIcons)); } catch { /* quota */ } }
    return true;
  } catch (e) {
    setStatus(`Delete view failed: ${e}`);
    return false;
  }
}

/** Delete a saved view by id (DELETE /views/:id). Confirms first. */
async function deleteView(id) {
  const view = viewsCache.find(v => v.id === id);
  if (!view) return;
  if (!window.confirm(`Delete saved view "${view.name}"?`)) return;
  if (await deleteViewQuiet(id)) await refreshViews();
}

/** Refresh the toolbar's saved-view UI from viewsCache. The dropdown was removed
 *  (views switch via the quick-switch buttons; save/delete live in Config View),
 *  but a legacy #toolbar-views-select is still populated if present. */
function renderSavedViews() {
  const sel = document.getElementById('toolbar-views-select');
  if (sel) {
    const current = sel.value; // preserve selection across re-render
    sel.innerHTML = '<option value="">— saved views —</option>';
    viewsCache.forEach(view => {
      const opt = document.createElement('option');
      opt.value = view.id;
      opt.textContent = view.name;
      sel.appendChild(opt);
    });
    if (current && viewsCache.find(v => v.id === current)) sel.value = current;
  }
  // Keep the quick-switch view buttons in sync with the views list.
  buildLayoutPresets();
}

// ── View Setup (custom layout builder) ─────────────────────────────────────────
// A commercial-VMS-style "Setup" mode: design a fully custom layout by setting a base
// grid (cols×rows) and dragging cells together into bigger boxes (e.g. a big
// hero on top + a row of small tiles underneath). Each box becomes a tile slot.
// Output: state.customLayout = { cols, rows, cells:[{x,y,w,h}] } (cells tile the
// grid with no overlap). Persisted via /views with layout "custom:{json}".

const VS_MAX = 8; // max cols/rows
// `assign` maps a cell's top-left "x,y" → cameraId (survives merge/split/resize
// by position). `dragCam` holds the camera id mid HTML5-drag from the list.
let vsState = { cols: 4, rows: 3, cells: [], drag: null, assign: new Map(), dragCam: null };
// Config-View interaction mode. OFF (default) = ARRANGE: drag a placed camera
// between boxes. ON = EDIT LAYOUT: drag across boxes to merge them. (Kept outside
// vsState so it survives the vsState resets in vsOpen.)
let vsEditLayout = false;

/** Key a cell by its top-left position for camera-assignment lookup. */
function vsKey(cell) { return `${cell.x},${cell.y}`; }

/** Validate + sanitize a {cols,rows,cells} object. Returns null if unusable. */
function normalizeCustomLayout(cl) {
  if (!cl || typeof cl !== 'object') return null;
  const cols = Math.max(1, Math.min(VS_MAX, parseInt(cl.cols, 10) || 0));
  const rows = Math.max(1, Math.min(VS_MAX, parseInt(cl.rows, 10) || 0));
  if (!Array.isArray(cl.cells) || cl.cells.length === 0) return null;
  const cells = [];
  for (const c of cl.cells) {
    const x = parseInt(c.x, 10), y = parseInt(c.y, 10);
    const w = parseInt(c.w, 10), h = parseInt(c.h, 10);
    if ([x, y, w, h].some(n => Number.isNaN(n))) continue;
    if (x < 0 || y < 0 || w < 1 || h < 1 || x + w > cols || y + h > rows) continue;
    cells.push({ x, y, w, h });
  }
  if (cells.length === 0) return null;
  return { cols, rows, cells: vsSortCells(cells) };
}

/** Sort cells in reading order (top-to-bottom, left-to-right) for stable slots. */
function vsSortCells(cells) {
  return cells.slice().sort((a, b) => (a.y - b.y) || (a.x - b.x));
}

/** A fresh grid of 1×1 cells covering cols×rows. */
function vsUnitCells(cols, rows) {
  const cells = [];
  for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) cells.push({ x, y, w: 1, h: 1 });
  return cells;
}

/** Built-in quick templates for the Setup dialog. */
function vsTemplate(name) {
  switch (name) {
    case '2x2': return { cols: 2, rows: 2, cells: vsUnitCells(2, 2) };
    case '3x3': return { cols: 3, rows: 3, cells: vsUnitCells(3, 3) };
    case '1plus5': return {
      cols: 3, rows: 3,
      cells: [{ x: 0, y: 0, w: 2, h: 2 }, { x: 2, y: 0, w: 1, h: 1 }, { x: 2, y: 1, w: 1, h: 1 },
              { x: 0, y: 2, w: 1, h: 1 }, { x: 1, y: 2, w: 1, h: 1 }, { x: 2, y: 2, w: 1, h: 1 }],
    };
    case '1plus7': return {
      cols: 4, rows: 4,
      cells: [{ x: 0, y: 0, w: 3, h: 3 }, { x: 3, y: 0, w: 1, h: 1 }, { x: 3, y: 1, w: 1, h: 1 },
              { x: 3, y: 2, w: 1, h: 1 }, { x: 0, y: 3, w: 1, h: 1 }, { x: 1, y: 3, w: 1, h: 1 },
              { x: 2, y: 3, w: 1, h: 1 }, { x: 3, y: 3, w: 1, h: 1 }],
    };
    case 'hero-bottom': return { // big hero on top + a row of smalls underneath
      cols: 4, rows: 3,
      cells: [{ x: 0, y: 0, w: 4, h: 2 }, { x: 0, y: 2, w: 1, h: 1 }, { x: 1, y: 2, w: 1, h: 1 },
              { x: 2, y: 2, w: 1, h: 1 }, { x: 3, y: 2, w: 1, h: 1 }],
    };
    default: return null;
  }
}

/** Clear the builder: remove EVERY camera assignment and reset the layout to a
 *  plain unit grid (un-merge all boxes) at the current cols/rows — a full "start
 *  fresh" without leaving the dialog. Grid size + name/icon are kept so the
 *  operator can rebuild; use Save/Apply afterwards to commit the empty layout. */
function vsClearAll() {
  vsState.assign = new Map();
  vsState.cells = vsUnitCells(vsState.cols, vsState.rows);
  vsState.drag = null;
  vsSetError('');
  vsRender();
  vsRenderCameraList();
}

/** Open the View Setup dialog, seeding from the current layout if it's custom. */
function vsOpen() {
  const cur = (state.layoutId === 'custom' && state.customLayout)
    ? normalizeCustomLayout(state.customLayout)
    : null;
  if (cur) {
    vsState = { cols: cur.cols, rows: cur.rows, cells: cur.cells, drag: null, assign: new Map(), dragCam: null };
  } else {
    // Seed from the current preset layout so existing assignments carry over.
    const layout = getLayout();
    if (layout.custom) {
      vsState = { cols: layout.custom.cols, rows: layout.custom.rows, cells: layout.custom.cells.map(c => ({ ...c })), drag: null, assign: new Map(), dragCam: null };
    } else {
      // Approximate a preset grid as cols×rows of unit cells.
      const cols = layout.id === '1x1' ? 1 : layout.id === '2x2' ? 2 : layout.id === '4x4' ? 4 : 3;
      const rows = layout.id === '1x1' ? 1 : layout.id === '2x2' ? 2 : layout.id === '4x4' ? 4 : 3;
      vsState = { cols, rows, cells: vsUnitCells(cols, rows), drag: null, assign: new Map(), dragCam: null };
    }
  }
  // Seed camera assignments from the current wall by sorted-cell position.
  vsSeedAssign();
  // Icon + which saved view (if any) is being edited. Starting fresh: no view,
  // default icon. Picking a saved view from the "Start from" list sets these.
  vsState.selectedIcon = state.currentViewId ? getViewIcon(state.currentViewId) : '🎥';
  vsState.loadedViewId = state.currentViewId || null;
  document.getElementById('vs-name-input').value =
    (vsState.loadedViewId && viewsCache.find(v => v.id === vsState.loadedViewId)?.name) || '';
  vsSetError('');
  document.getElementById('vs-backdrop').classList.remove('hidden');
  document.getElementById('vs-dialog').classList.remove('hidden');
  vsRenderCameraList();
  vsRenderPalette();
  vsRenderLoadList();
  vsRenderIconGrid();
  vsSetEditLayout(false); // always open in arrange-cameras mode
  vsRender();
  // Native video panes sit ABOVE the WebView and would occlude the modal —
  // tear them down (and block re-sync) while it's open, restore on close.
  modalOpened();
}

function vsClose() {
  vsState.drag = null;
  document.getElementById('vs-backdrop').classList.add('hidden');
  document.getElementById('vs-dialog').classList.add('hidden');
  modalClosed();
}

function vsSetError(msg) {
  const el = document.getElementById('vs-error');
  if (!el) return;
  el.textContent = msg || '';
  el.classList.toggle('hidden', !msg);
}

/** Resize the grid to cols×rows while PRESERVING existing box customizations.
 *  Existing boxes (incl. merges) that still fit are kept; ones overhanging the
 *  new bounds are clamped, and ones whose origin falls outside are dropped; any
 *  remaining uncovered grid positions are filled with 1×1 cells so the grid stays
 *  fully tiled. So adding a row/column just adds plain cells instead of wiping the
 *  layout. Camera assignments (keyed by a box's top-left) survive a grow intact. */
function vsSetDims(cols, rows) {
  const newCols = Math.max(1, Math.min(VS_MAX, cols));
  const newRows = Math.max(1, Math.min(VS_MAX, rows));

  const kept = [];
  for (const c of vsState.cells) {
    if (c.x >= newCols || c.y >= newRows) continue;          // origin now outside → drop
    const w = Math.min(c.w, newCols - c.x);
    const h = Math.min(c.h, newRows - c.y);
    if (w >= 1 && h >= 1) kept.push({ x: c.x, y: c.y, w, h }); // keep (clamped if needed)
  }

  // Fill any grid positions not covered by a kept box with 1×1 cells.
  const covered = new Set();
  for (const c of kept) {
    for (let y = c.y; y < c.y + c.h; y++) for (let x = c.x; x < c.x + c.w; x++) covered.add(`${x},${y}`);
  }
  for (let y = 0; y < newRows; y++) for (let x = 0; x < newCols; x++) {
    if (!covered.has(`${x},${y}`)) kept.push({ x, y, w: 1, h: 1 });
  }

  vsState.cols = newCols;
  vsState.rows = newRows;
  vsState.cells = vsSortCells(kept);

  // Drop camera assignments whose box no longer exists (e.g. a removed row), so
  // the camera-list badges + the saved view don't keep a phantom assignment.
  const liveKeys = new Set(vsState.cells.map(vsKey));
  for (const k of [...vsState.assign.keys()]) {
    if (!liveKeys.has(k)) vsState.assign.delete(k);
  }

  vsRender();
  vsRenderCameraList();
}

/** Merge every cell intersecting the rect [x0..x1]×[y0..y1] into one box. */
function vsMergeRegion(x0, y0, x1, y1) {
  let minX = Math.min(x0, x1), maxX = Math.max(x0, x1);
  let minY = Math.min(y0, y1), maxY = Math.max(y0, y1);
  // Expand to fully cover any cell that intersects, to a fixpoint, so the
  // result is always a clean rectangle that tiles with the rest.
  let changed = true;
  while (changed) {
    changed = false;
    for (const c of vsState.cells) {
      const cx2 = c.x + c.w - 1, cy2 = c.y + c.h - 1;
      const intersects = !(c.x > maxX || cx2 < minX || c.y > maxY || cy2 < minY);
      if (intersects) {
        if (c.x < minX) { minX = c.x; changed = true; }
        if (cx2 > maxX) { maxX = cx2; changed = true; }
        if (c.y < minY) { minY = c.y; changed = true; }
        if (cy2 > maxY) { maxY = cy2; changed = true; }
      }
    }
  }
  // The merged box keeps the top-left cell's camera assignment; the cells it
  // absorbs lose theirs (their position no longer hosts a box).
  const keepCam = vsState.assign.get(`${minX},${minY}`);
  vsState.cells.forEach(c => {
    const cx2 = c.x + c.w - 1, cy2 = c.y + c.h - 1;
    if (c.x >= minX && cx2 <= maxX && c.y >= minY && cy2 <= maxY) {
      if (!(c.x === minX && c.y === minY)) vsState.assign.delete(`${c.x},${c.y}`);
    }
  });
  vsState.cells = vsState.cells.filter(c => {
    const cx2 = c.x + c.w - 1, cy2 = c.y + c.h - 1;
    return !(c.x >= minX && cx2 <= maxX && c.y >= minY && cy2 <= maxY);
  });
  vsState.cells.push({ x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 });
  if (keepCam) vsState.assign.set(`${minX},${minY}`, keepCam);
  vsState.cells = vsSortCells(vsState.cells);
}

/** Split a merged cell back into 1×1 cells (top-left keeps the assignment). */
function vsSplitCell(cell) {
  vsState.cells = vsState.cells.filter(c => c !== cell);
  for (let y = cell.y; y < cell.y + cell.h; y++)
    for (let x = cell.x; x < cell.x + cell.w; x++)
      vsState.cells.push({ x, y, w: 1, h: 1 });
  vsState.cells = vsSortCells(vsState.cells);
}

/** Render the builder grid + box count from vsState. */
function vsRender() {
  const grid = document.getElementById('vs-grid');
  if (!grid) return;
  grid.style.gridTemplateColumns = `repeat(${vsState.cols}, 1fr)`;
  grid.style.gridTemplateRows = `repeat(${vsState.rows}, 1fr)`;
  grid.innerHTML = '';

  const sorted = vsSortCells(vsState.cells);
  sorted.forEach((cell, idx) => {
    const div = document.createElement('div');
    const merged = cell.w > 1 || cell.h > 1;
    const spec = normalizeTileSpec(vsState.assign.get(vsKey(cell)));
    div.className = 'vs-cell' + (merged ? ' merged' : '') + (spec ? ' assigned' : '') + (spec ? ` vs-cell-${spec.type}` : '');
    div.style.gridColumn = `${cell.x + 1} / span ${cell.w}`;
    div.style.gridRow = `${cell.y + 1} / span ${cell.h}`;
    div.dataset.cx = cell.x; div.dataset.cy = cell.y;
    div.dataset.cw = cell.w; div.dataset.ch = cell.h;
    const splitBtn = merged ? '<button class="vs-cell-split" title="Split this box">⊟</button>' : '';
    const cfgBtn = (spec && VS_CONFIGURABLE.has(spec.type)) ? '<button class="vs-cell-cfg" title="Configure this item">⚙</button>' : '';
    const clearBtn = spec ? '<button class="vs-cell-clear" title="Remove">×</button>' : '';
    const body = spec
      ? `<span class="vs-cell-item">${vsCellLabel(spec)}</span>`
      : `<span class="vs-cell-drop">drag a camera or item here</span>`;
    div.innerHTML = `<span class="vs-cell-num">${idx + 1}</span>${splitBtn}${cfgBtn}${clearBtn}${body}`;
    div._cell = cell;
    div.addEventListener('pointerdown', vsCellPointerDown);
    div.addEventListener('pointerenter', vsCellPointerEnter);
    // (Assignment is pointer-drag based — see vsDragSpec — because HTML5
    // drag-and-drop is swallowed by Tauri/WebView2's native drag handler.)
    const sb = div.querySelector('.vs-cell-split');
    if (sb) sb.addEventListener('pointerdown', (e) => { e.stopPropagation(); e.preventDefault(); vsSplitCell(cell); vsRender(); });
    const cfg = div.querySelector('.vs-cell-cfg');
    if (cfg) cfg.addEventListener('pointerdown', (e) => { e.stopPropagation(); e.preventDefault(); vsOpenItemConfig(vsKey(cell)); });
    // Configurable items (Text/Image/Web/Carousel/PTZ): double-click OR right-click
    // the box to edit it. The ⚙ is a small secondary affordance; this is the
    // discoverable path, esp. for a Text tile you want to type into.
    if (spec && VS_CONFIGURABLE.has(spec.type)) {
      const edit = (e) => { e.preventDefault(); e.stopPropagation(); vsOpenItemConfig(vsKey(cell)); };
      div.addEventListener('dblclick', edit);
      div.addEventListener('contextmenu', edit);
    }
    const cb = div.querySelector('.vs-cell-clear');
    if (cb) cb.addEventListener('pointerdown', (e) => { e.stopPropagation(); e.preventDefault(); vsState.assign.delete(vsKey(cell)); vsRender(); vsRenderCameraList(); });
    grid.appendChild(div);
  });

  document.getElementById('vs-cols-val').textContent = String(vsState.cols);
  document.getElementById('vs-rows-val').textContent = String(vsState.rows);
  const n = sorted.length;
  document.getElementById('vs-box-count').textContent = `${n} box${n !== 1 ? 'es' : ''}`;
}

/** Inner label for a builder box, by spec type. */
function vsCellLabel(spec) {
  const ico = t => `<span class="vs-cell-ico">${t}</span>`;
  switch (spec.type) {
    case 'camera': { const c = camById(spec.cameraId); return ico('📷') + escHtml(c ? c.name : '(missing camera)'); }
    case 'carousel': { const m = (spec.cameras || []).length; return ico('🔁') + `Carousel · ${m} cam${m !== 1 ? 's' : ''} · ${spec.mode || 'time'}`; }
    case 'hotspot': return ico('🎯') + 'Hotspot';
    case 'ptz': { const c = camById(spec.cameraId); return ico('🕹') + 'PTZ · ' + escHtml(c ? c.name : 'pick a camera'); }
    case 'image': return ico('🖼') + (spec.dataUrl ? 'Image' : 'Image (pick a file)');
    case 'clock': return ico('🕐') + 'Clock';
    case 'text': return ico('🅰') + (spec.text ? escHtml(spec.text.slice(0, 24)) : 'Text (edit me)');
    case 'events': return ico('🔔') + 'Detections';
    case 'web': return ico('🌐') + (spec.url ? escHtml(spec.url.replace(/^https?:\/\//, '').slice(0, 22)) : 'Web (set URL)');
    default: return escHtml(spec.type);
  }
}

/** Plain-TEXT label for a builder box (NO HTML) — used for the drag ghost, whose
 *  text goes into `textContent`. vsCellLabel() returns an HTML string, so feeding
 *  it to textContent rendered the raw "<span class=…>" markup next to the cursor
 *  (the "click-hold shows HTML/CSS code" bug). This returns icon + plain name. */
function vsCellLabelText(spec) {
  switch (spec.type) {
    case 'camera': { const c = camById(spec.cameraId); return '📷 ' + (c ? c.name : '(missing camera)'); }
    case 'carousel': { const m = (spec.cameras || []).length; return `🔁 Carousel · ${m} cam${m !== 1 ? 's' : ''} · ${spec.mode || 'time'}`; }
    case 'hotspot': return '🎯 Hotspot';
    case 'ptz': { const c = camById(spec.cameraId); return '🕹 PTZ · ' + (c ? c.name : 'pick a camera'); }
    case 'image': return '🖼 ' + (spec.dataUrl ? 'Image' : 'Image');
    case 'clock': return '🕐 Clock';
    case 'text': return '🅰 ' + (spec.text ? spec.text.slice(0, 24) : 'Text');
    case 'events': return '🔔 Detections';
    case 'web': return '🌐 ' + (spec.url ? spec.url.replace(/^https?:\/\//, '').slice(0, 22) : 'Web');
    default: return spec.type;
  }
}

// ── Per-box item config (carousel / ptz / image / text / web) ─────────────────
let vsCfgEl = null;
function vsCloseItemConfig() { if (vsCfgEl) { vsCfgEl.remove(); vsCfgEl = null; } }
function vsOpenItemConfig(cellKey) {
  const spec = normalizeTileSpec(vsState.assign.get(cellKey));
  if (!spec || !VS_CONFIGURABLE.has(spec.type)) return;
  vsCloseItemConfig();
  const back = document.createElement('div');
  back.className = 'vs-cfg-backdrop';
  const panel = document.createElement('div');
  panel.className = 'vs-cfg-panel';
  panel.innerHTML = `<div class="vs-cfg-title">Configure — ${spec.type}</div><div class="vs-cfg-body"></div>` +
    `<div class="vs-cfg-actions"><button class="vs-cfg-cancel">Cancel</button><button class="vs-cfg-save">Done</button></div>`;
  const draft = JSON.parse(JSON.stringify(spec));
  vsBuildConfigBody(panel.querySelector('.vs-cfg-body'), draft);
  back.appendChild(panel);
  document.body.appendChild(back);
  vsCfgEl = back;
  panel.querySelector('.vs-cfg-cancel').addEventListener('click', vsCloseItemConfig);
  back.addEventListener('click', (e) => { if (e.target === back) vsCloseItemConfig(); });
  panel.querySelector('.vs-cfg-save').addEventListener('click', () => {
    vsState.assign.set(cellKey, draft);
    vsCloseItemConfig();
    vsRender(); vsRenderCameraList();
  });
}

/** Build the type-specific config controls; mutate `draft` in place. */
function vsBuildConfigBody(body, draft) {
  if (draft.type === 'carousel') {
    body.innerHTML =
      `<label class="vs-cfg-row">Mode <select class="vs-cfg-mode">
        <option value="time">Time — rotate every N seconds</option>
        <option value="motion">Motion — jump to the camera with motion</option>
        <option value="both">Both — motion first, else rotate</option></select></label>` +
      `<label class="vs-cfg-row">Interval (seconds) <input type="number" min="2" max="120" class="vs-cfg-interval"></label>` +
      `<div class="vs-cfg-sub">Cameras to cycle</div><div class="vs-cfg-cams"></div>`;
    body.querySelector('.vs-cfg-mode').value = draft.mode || 'time';
    body.querySelector('.vs-cfg-mode').addEventListener('change', e => { draft.mode = e.target.value; });
    const iv = body.querySelector('.vs-cfg-interval');
    iv.value = Math.round((draft.intervalMs || 8000) / 1000);
    iv.addEventListener('input', e => { draft.intervalMs = Math.max(2, parseInt(e.target.value, 10) || 8) * 1000; });
    if (!Array.isArray(draft.cameras)) draft.cameras = state.cameras.map(c => c.id);
    const cams = body.querySelector('.vs-cfg-cams');
    state.cameras.forEach(c => {
      const row = document.createElement('label');
      row.className = 'vs-cfg-cam';
      row.innerHTML = `<input type="checkbox" ${draft.cameras.includes(c.id) ? 'checked' : ''}><span>${escHtml(c.name)}</span>`;
      row.querySelector('input').addEventListener('change', e => {
        if (e.target.checked) { if (!draft.cameras.includes(c.id)) draft.cameras.push(c.id); }
        else draft.cameras = draft.cameras.filter(x => x !== c.id);
      });
      cams.appendChild(row);
    });
  } else if (draft.type === 'hotspot') {
    body.innerHTML =
      `<div class="vs-cfg-hint">Leave all cameras unchecked for the classic hotspot: click any camera on the wall to show it here.<br>Or pick a set below and this tile auto-follows the camera with the <b>most recent motion</b> (briefly holding each), even if those cameras aren't on the wall.</div>` +
      `<div class="vs-cfg-sub">Auto-follow motion across these cameras</div><div class="vs-cfg-cams"></div>`;
    if (!Array.isArray(draft.cameras)) draft.cameras = [];
    const cams = body.querySelector('.vs-cfg-cams');
    state.cameras.forEach(c => {
      const row = document.createElement('label');
      row.className = 'vs-cfg-cam';
      row.innerHTML = `<input type="checkbox" ${draft.cameras.includes(c.id) ? 'checked' : ''}><span>${escHtml(c.name)}</span>`;
      row.querySelector('input').addEventListener('change', e => {
        if (e.target.checked) { if (!draft.cameras.includes(c.id)) draft.cameras.push(c.id); }
        else draft.cameras = draft.cameras.filter(x => x !== c.id);
      });
      cams.appendChild(row);
    });
  } else if (draft.type === 'ptz') {
    body.innerHTML = `<label class="vs-cfg-row">Camera <select class="vs-cfg-ptzcam"></select></label>` +
      `<div class="vs-cfg-hint">A dedicated PTZ tile turns OFF the on-image PTZ wheel on the other tiles.</div>`;
    const sel = body.querySelector('.vs-cfg-ptzcam');
    state.cameras.forEach(c => { const o = document.createElement('option'); o.value = c.id; o.textContent = c.name; sel.appendChild(o); });
    sel.value = draft.cameraId || (state.cameras[0]?.id || '');
    draft.cameraId = sel.value;
    sel.addEventListener('change', e => { draft.cameraId = e.target.value; });
  } else if (draft.type === 'image') {
    body.innerHTML = `<div class="vs-cfg-row"><input type="file" accept="image/*" class="vs-cfg-imgfile"></div><div class="vs-cfg-imgprev"></div>`;
    const prev = body.querySelector('.vs-cfg-imgprev');
    const showPrev = () => { prev.innerHTML = draft.dataUrl ? `<img src="${draft.dataUrl}" alt="">` : '<span class="vs-cfg-hint">No image selected</span>'; };
    showPrev();
    body.querySelector('.vs-cfg-imgfile').addEventListener('change', async e => {
      const f = e.target.files && e.target.files[0]; if (!f) return;
      try { draft.dataUrl = await vsDownscaleImage(f, 1280); showPrev(); }
      catch { prev.innerHTML = '<span class="vs-cfg-hint">Could not read that image</span>'; }
    });
  } else if (draft.type === 'text') {
    body.innerHTML = `<label class="vs-cfg-row">Text<textarea class="vs-cfg-text" rows="3" placeholder="e.g. LOADING DOCK"></textarea></label>` +
      `<label class="vs-cfg-row">Size (px) <input type="number" min="10" max="72" class="vs-cfg-size"></label>`;
    const ta = body.querySelector('.vs-cfg-text'); ta.value = draft.text || ''; ta.addEventListener('input', e => { draft.text = e.target.value; });
    const sz = body.querySelector('.vs-cfg-size'); sz.value = draft.size || 28; sz.addEventListener('input', e => { draft.size = Math.max(10, Math.min(72, parseInt(e.target.value, 10) || 28)); });
  } else if (draft.type === 'web') {
    body.innerHTML = `<label class="vs-cfg-row">URL <input type="text" class="vs-cfg-url" placeholder="https://…"></label>` +
      `<div class="vs-cfg-hint">Some sites block embedding (X-Frame-Options / CSP).</div>`;
    const u = body.querySelector('.vs-cfg-url'); u.value = draft.url || ''; u.addEventListener('input', e => { draft.url = e.target.value.trim(); });
  }
}

/** Read an image File → a downscaled JPEG data URL (so views stay small in jsonb). */
function vsDownscaleImage(file, maxDim) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
        const w = Math.max(1, Math.round(img.width * scale)), h = Math.max(1, Math.round(img.height * scale));
        const canvas = document.createElement('canvas'); canvas.width = w; canvas.height = h;
        canvas.getContext('2d').drawImage(img, 0, 0, w, h);
        try { resolve(canvas.toDataURL('image/jpeg', 0.82)); } catch (e) { reject(e); }
      };
      img.onerror = reject;
      img.src = reader.result;
    };
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

/** Approximate a built-in preset layout id as a {cols,rows,cells} for the builder. */
function vsPresetToLayout(id) {
  switch (id) {
    case '1x1': return { cols: 1, rows: 1, cells: vsUnitCells(1, 1) };
    case '2x2': return { cols: 2, rows: 2, cells: vsUnitCells(2, 2) };
    case '3x3': return { cols: 3, rows: 3, cells: vsUnitCells(3, 3) };
    case '4x4': return { cols: 4, rows: 4, cells: vsUnitCells(4, 4) };
    case '1plus5': return vsTemplate('1plus5');
    default: return { cols: 2, rows: 2, cells: vsUnitCells(2, 2) };
  }
}

/** Render the "Start from" list of saved views in the Setup dialog. Clicking one
 *  loads its layout + camera assignments + icon into the builder for editing. */
function vsRenderLoadList() {
  const list = document.getElementById('vs-load-list');
  if (!list) return;
  list.innerHTML = '';
  if (!viewsCache.length) {
    list.innerHTML = '<span class="vs-load-empty">No saved views yet — design one below, then Save.</span>';
    return;
  }
  const views = orderedViews();
  const defId = getDefaultView();
  views.forEach((v, i) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'vs-load-btn' + (v.id === vsState.loadedViewId ? ' active' : '');
    b.title = `Edit "${v.name}"`;
    const isDefault = defId === v.id;
    b.dataset.viewId = v.id;
    b.innerHTML =
      `<span class="vs-grip" title="Drag to reorder">⠿</span>` +
      `<span class="vs-load-icon">${getViewIcon(v.id)}</span>` +
      `<span class="vs-load-name">${escHtml(v.name)}</span>` +
      `<span class="vs-load-star${isDefault ? ' on' : ''}" title="${isDefault ? 'Default launch view (click to clear)' : 'Set as the launch view'}">${isDefault ? '★' : '☆'}</span>` +
      `<span class="vs-load-del" title="Delete this view">✕</span>`;
    b.addEventListener('click', () => vsLoadView(v.id));
    // Drag the ⠿ grip to reorder (grip click is swallowed so it never loads the view).
    const grip = b.querySelector('.vs-grip');
    grip.addEventListener('pointerdown', (e) => vsStartReorder(e, v.id));
    grip.addEventListener('click', (e) => e.stopPropagation());
    // ★ default-launch-view toggle.
    b.querySelector('.vs-load-star').addEventListener('click', (e) => { e.stopPropagation(); setDefaultView(v.id); vsRenderLoadList(); });
    // Delete (✕).
    b.querySelector('.vs-load-del').addEventListener('click', async (e) => {
      e.stopPropagation();
      if (!window.confirm(`Delete saved view "${v.name}"?`)) return;
      if (await deleteViewQuiet(v.id)) {
        if (vsState.loadedViewId === v.id) vsState.loadedViewId = null;
        await refreshViews();
        vsRenderLoadList();
      }
    });
    list.appendChild(b);
  });
}

/** Pointer-drag reorder of the saved-views "Start from" list (and the toolbar
 *  buttons it drives). Live-previews by rewriting the order as the pointer passes
 *  over another row, persists on release. Pointer-based, like the rest of the
 *  builder — HTML5 drag-and-drop is swallowed by Tauri/WebView2. */
function vsStartReorder(e, viewId) {
  if (e.button === 2) return;
  e.preventDefault();
  e.stopPropagation();
  let order = orderedViews().map(v => v.id);
  document.body.classList.add('vs-reordering');
  const rowUnder = (x, y) => {
    const el = document.elementFromPoint(x, y);
    return el && el.closest ? el.closest('.vs-load-btn') : null;
  };
  // rAF-throttle the hit-test + live re-render: pointermove fires at 60-120Hz but
  // the elementFromPoint + full list re-render only need to run once per frame
  // (review S8). Collapses a burst of moves into one paint.
  let reorderRaf = false, reorderX = 0, reorderY = 0;
  const move = (ev) => {
    reorderX = ev.clientX; reorderY = ev.clientY;
    if (reorderRaf) return;
    reorderRaf = true;
    requestAnimationFrame(() => {
      reorderRaf = false;
      const row = rowUnder(reorderX, reorderY);
      if (!row) return;
      const overId = row.dataset.viewId;
      if (!overId || overId === viewId) return;
      const from = order.indexOf(viewId), to = order.indexOf(overId);
      if (from < 0 || to < 0 || from === to) return;
      order.splice(to, 0, order.splice(from, 1)[0]); // move dragged id next to the hovered row
      setViewOrder(order);
      vsRenderLoadList();                            // live preview (document listeners survive the re-render)
    });
  };
  const up = () => {
    document.removeEventListener('pointermove', move);
    document.removeEventListener('pointerup', up);
    document.removeEventListener('pointercancel', up); // missed-pointerup leak (R4)
    document.body.classList.remove('vs-reordering');
    setViewOrder(order);
    buildLayoutPresets(); // reflect the new order in the toolbar
    vsRenderLoadList();
  };
  document.addEventListener('pointermove', move);
  document.addEventListener('pointerup', up);
  document.addEventListener('pointercancel', up);
}

/** Load a saved view into the builder: layout geometry, camera assignments,
 *  name, and icon — so the operator can tweak an existing preset and re-save. */
function vsLoadView(id) {
  const view = viewsCache.find(v => v.id === id);
  if (!view) return;
  let cl = null;
  if (typeof view.layout === 'string' && view.layout.startsWith('custom:')) {
    try { cl = normalizeCustomLayout(JSON.parse(view.layout.slice(7))); } catch { cl = null; }
  } else {
    cl = vsPresetToLayout(view.layout);
  }
  if (!cl) { vsSetError('That view has an unreadable layout.'); return; }
  vsState = {
    cols: cl.cols, rows: cl.rows, cells: cl.cells.map(c => ({ ...c })),
    drag: null, assign: new Map(), dragCam: null,
    selectedIcon: getViewIcon(id), loadedViewId: id,
  };
  // Seed camera assignments from the saved view's {slotIdx: camId} by cell order.
  const sorted = vsSortCells(vsState.cells);
  sorted.forEach((cell, i) => {
    const spec = normalizeTileSpec(view.slots ? view.slots[String(i)] : null);
    if (!spec) return;
    if (spec.type === 'camera' && !state.cameras.some(c => c.id === spec.cameraId)) return;
    vsState.assign.set(vsKey(cell), spec);
  });
  document.getElementById('vs-name-input').value = view.name;
  vsSetError('');
  vsRender();
  vsRenderCameraList();
  vsRenderIconGrid();
  vsRenderLoadList();
}

/** Render the inline view-icon picker. Clicking an icon selects it; when editing
 *  an existing view, the change applies to that view's toolbar icon immediately. */
function vsRenderIconGrid() {
  const grid = document.getElementById('vs-icon-grid');
  if (!grid) return;
  grid.innerHTML = '';
  VIEW_ICON_CHOICES.forEach(ic => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'vip-btn' + (ic === vsState.selectedIcon ? ' selected' : '');
    b.textContent = ic;
    b.addEventListener('click', () => {
      vsState.selectedIcon = ic;
      // Persist live ONLY when genuinely editing the loaded view — i.e. the name
      // is unchanged. If it's been renamed (becoming a NEW view, e.g. "Start from
      // Outside" → rename "Inside"), do NOT touch the old view's icon; the picked
      // icon is applied to the new view on Save (vsSaveAsView → setViewIcon).
      const loaded = vsState.loadedViewId
        ? viewsCache.find(v => v.id === vsState.loadedViewId) : null;
      const curName = (document.getElementById('vs-name-input')?.value || '').trim();
      if (loaded && curName === loaded.name) setViewIcon(loaded.id, ic);
      vsRenderIconGrid();
      vsRenderLoadList();
    });
    grid.appendChild(b);
  });
}

/** Render the draggable camera source list in the Setup dialog.
 *  Uses POINTER-based drag (not HTML5 DnD): Tauri/WebView2's native drag handler
 *  swallows HTML5 dragover/drop, so a real mouse just shows a no-drop cursor. */
function vsRenderCameraList() {
  const list = document.getElementById('vs-camera-list');
  if (!list) return;
  list.innerHTML = '';
  if (!state.cameras.length) {
    list.innerHTML = '<div class="vs-camera-empty">No cameras</div>';
    return;
  }
  state.cameras.forEach(cam => {
    const assignedCount = Array.from(vsState.assign.values()).filter(s => {
      const sp = normalizeTileSpec(s);
      return sp && (sp.type === 'camera' || sp.type === 'ptz') && sp.cameraId === cam.id;
    }).length;
    const item = document.createElement('div');
    item.className = 'vs-camera-item';
    item.dataset.camId = cam.id;
    item.innerHTML = `<span class="vs-camera-dot"></span>` +
      `<span class="vs-camera-name">${escHtml(cam.name)}</span>` +
      (assignedCount ? `<span class="vs-camera-badge">${assignedCount}</span>` : '');
    item.addEventListener('pointerdown', (e) => vsCameraStartDrag(e, cam));
    list.appendChild(item);
  });
}

// ── View-item palette ─────────────────────────────────────────────────────────
const VS_PALETTE = [
  { type: 'carousel', icon: '🔁', label: 'Carousel' },
  { type: 'hotspot',  icon: '🎯', label: 'Hotspot' },
  { type: 'ptz',      icon: '🕹', label: 'PTZ' },
  { type: 'image',    icon: '🖼', label: 'Image' },
  { type: 'clock',    icon: '🕐', label: 'Clock' },
  { type: 'text',     icon: '🅰', label: 'Text' },
  { type: 'events',   icon: '🔔', label: 'Detections' },
  { type: 'web',      icon: '🌐', label: 'Web' },
];
/** Types that pop a config panel when dropped / clicked on a box. */
const VS_CONFIGURABLE = new Set(['carousel', 'ptz', 'image', 'text', 'web', 'hotspot']);

/** A fresh default spec for a palette type. */
function vsDefaultSpec(type) {
  switch (type) {
    case 'carousel': return { type: 'carousel', cameras: state.cameras.map(c => c.id), intervalMs: 8000, mode: 'time' };
    case 'hotspot':  return { type: 'hotspot' };
    case 'ptz':      return { type: 'ptz', cameraId: (state.cameras.find(c => /ptz|lpr|dome/i.test(c.name))?.id) || state.cameras[0]?.id || null };
    case 'image':    return { type: 'image', dataUrl: '' };
    case 'clock':    return { type: 'clock' };
    case 'text':     return { type: 'text', text: '', size: 28 };
    case 'events':   return { type: 'events' };
    case 'web':      return { type: 'web', url: '' };
    default:         return null;
  }
}

/** Render the draggable view-item palette chips. */
function vsRenderPalette() {
  const list = document.getElementById('vs-palette-list');
  if (!list) return;
  list.innerHTML = '';
  VS_PALETTE.forEach(p => {
    const chip = document.createElement('div');
    chip.className = 'vs-palette-item';
    chip.title = `Drag "${p.label}" onto a box`;
    chip.innerHTML = `<span class="vs-pal-icon">${p.icon}</span><span class="vs-pal-label">${p.label}</span>`;
    chip.addEventListener('pointerdown', (e) => vsDragSpec(e, p.label, () => vsDefaultSpec(p.type)));
    list.appendChild(chip);
  });
}

/** Generic pointer-drag of a view-item (a camera OR a palette type) onto a box.
 *  `makeSpec()` produces the spec to drop. (Pointer-based, not HTML5 DnD, which
 *  Tauri/WebView2 swallows.) */
function vsDragSpec(e, label, makeSpec) {
  e.preventDefault();
  const item = e.currentTarget;
  item.classList.add('dragging');
  const ghost = document.createElement('div');
  ghost.className = 'vs-drag-ghost';
  ghost.textContent = label;
  document.body.appendChild(ghost);
  const place = (x, y) => { ghost.style.left = `${x + 10}px`; ghost.style.top = `${y + 6}px`; };
  place(e.clientX, e.clientY);
  const cellUnder = (x, y) => {
    const el = document.elementFromPoint(x, y);
    return el && el.closest ? el.closest('#vs-grid .vs-cell') : null;
  };
  const move = (ev) => {
    place(ev.clientX, ev.clientY);
    document.querySelectorAll('#vs-grid .vs-cell.drop-hover').forEach(c => c.classList.remove('drop-hover'));
    cellUnder(ev.clientX, ev.clientY)?.classList.add('drop-hover');
  };
  // Centralized teardown removes move+up+cancel and the floating ghost. Without
  // the pointercancel path, a focus loss / OS gesture / modal teardown mid-drag
  // fires pointercancel (not pointerup), leaking both document listeners and the
  // ghost permanently (review R4).
  const cleanup = () => {
    document.removeEventListener('pointermove', move);
    document.removeEventListener('pointerup', up);
    document.removeEventListener('pointercancel', up);
    ghost.remove();
    item.classList.remove('dragging');
    document.querySelectorAll('#vs-grid .vs-cell.drop-hover').forEach(c => c.classList.remove('drop-hover'));
  };
  const up = (ev) => {
    cleanup();
    if (ev && ev.type === 'pointercancel') return; // interrupted — no drop
    const cell = cellUnder(ev.clientX, ev.clientY);
    if (cell && cell._cell) {
      const spec = makeSpec();
      if (spec) {
        vsState.assign.set(vsKey(cell._cell), spec);
        if (VS_CONFIGURABLE.has(spec.type)) { vsRender(); vsOpenItemConfig(vsKey(cell._cell)); }
      }
    }
    vsRender();
    vsRenderCameraList();
  };
  document.addEventListener('pointermove', move);
  document.addEventListener('pointerup', up);
  document.addEventListener('pointercancel', up);
}

function vsCameraStartDrag(e, cam) {
  vsDragSpec(e, cam.name, () => ({ type: 'camera', cameraId: cam.id }));
}

/** Seed vsState.assign from the current wall slot assignments by cell order. */
function vsSeedAssign() {
  vsState.assign = new Map();
  const sorted = vsSortCells(vsState.cells);
  sorted.forEach((cell, i) => {
    const sp = slotSpec(i);
    if (sp) vsState.assign.set(vsKey(cell), sp);
  });
}

function vsCellPointerDown(e) {
  if (e.button === 2) return; // right-click → handled by the contextmenu edit handler
  e.preventDefault();
  const cell = e.currentTarget._cell;
  if (vsEditLayout) {
    // EDIT LAYOUT mode: drag across cells to merge them.
    vsState.drag = { anchor: cell, current: cell };
    vsHighlight();
    return;
  }
  // ARRANGE mode (default): drag a PLACED item to another box to move/swap it.
  const fromKey = vsKey(cell);
  if (!vsState.assign.get(fromKey)) return; // empty box — nothing to grab
  vsCellMoveDrag(e, fromKey);
}

/** Drag a placed view-item from one box to another (move; swap if the target is
 *  occupied). The intuitive default in the builder — no box reshaping. */
function vsCellMoveDrag(e, fromKey) {
  const spec = vsState.assign.get(fromKey);
  if (!spec) return;
  const ghost = document.createElement('div');
  ghost.className = 'vs-drag-ghost';
  ghost.textContent = vsCellLabelText(spec);
  document.body.appendChild(ghost);
  const place = (x, y) => { ghost.style.left = `${x + 10}px`; ghost.style.top = `${y + 6}px`; };
  place(e.clientX, e.clientY);
  const cellUnder = (x, y) => {
    const el = document.elementFromPoint(x, y);
    return el && el.closest ? el.closest('#vs-grid .vs-cell') : null;
  };
  const move = (ev) => {
    place(ev.clientX, ev.clientY);
    document.querySelectorAll('#vs-grid .vs-cell.drop-hover').forEach(c => c.classList.remove('drop-hover'));
    cellUnder(ev.clientX, ev.clientY)?.classList.add('drop-hover');
  };
  const up = (ev) => {
    document.removeEventListener('pointermove', move);
    document.removeEventListener('pointerup', up);
    document.removeEventListener('pointercancel', up); // missed-pointerup leak (R4)
    ghost.remove();
    document.querySelectorAll('#vs-grid .vs-cell.drop-hover').forEach(c => c.classList.remove('drop-hover'));
    if (ev && ev.type === 'pointercancel') { vsRender(); return; } // interrupted — no move
    const cell = cellUnder(ev.clientX, ev.clientY);
    if (cell && cell._cell) {
      const toKey = vsKey(cell._cell);
      if (toKey !== fromKey) {
        const existing = vsState.assign.get(toKey);
        vsState.assign.set(toKey, spec);
        if (existing) vsState.assign.set(fromKey, existing); // swap
        else vsState.assign.delete(fromKey);                 // plain move
      }
    }
    vsRender();
    vsRenderCameraList();
  };
  document.addEventListener('pointermove', move);
  document.addEventListener('pointerup', up);
  document.addEventListener('pointercancel', up);
}

/** Toggle EDIT-LAYOUT mode + reflect it in the button, hint, and grid affordance. */
function vsSetEditLayout(on) {
  vsEditLayout = !!on;
  document.getElementById('vs-edit-layout-btn')?.classList.toggle('active', vsEditLayout);
  document.getElementById('vs-hint-arrange')?.classList.toggle('hidden', vsEditLayout);
  document.getElementById('vs-hint-edit')?.classList.toggle('hidden', !vsEditLayout);
  document.getElementById('vs-grid')?.classList.toggle('vs-edit-layout', vsEditLayout);
}

function vsCellPointerEnter(e) {
  if (!vsState.drag) return;
  vsState.drag.current = e.currentTarget._cell;
  vsHighlight();
}

/** Highlight the cells inside the current drag rectangle. */
function vsHighlight() {
  const grid = document.getElementById('vs-grid');
  if (!grid || !vsState.drag) return;
  const a = vsState.drag.anchor, b = vsState.drag.current;
  const minX = Math.min(a.x, b.x), maxX = Math.max(a.x + a.w - 1, b.x + b.w - 1);
  const minY = Math.min(a.y, b.y), maxY = Math.max(a.y + a.h - 1, b.y + b.h - 1);
  grid.querySelectorAll('.vs-cell').forEach(div => {
    const c = div._cell;
    const cx2 = c.x + c.w - 1, cy2 = c.y + c.h - 1;
    const inside = !(c.x > maxX || cx2 < minX || c.y > maxY || cy2 < minY);
    div.classList.toggle('selecting', inside);
  });
}

/** End a drag: merge a multi-cell selection. A single click does NOTHING —
 *  splitting is now an explicit ⊟ button (kills the accidental-split frustration
 *  from the old click-to-split model, #8). */
function vsPointerUp() {
  if (!vsState.drag) return;
  const a = vsState.drag.anchor, b = vsState.drag.current;
  vsState.drag = null;
  if (a === b) { vsRender(); return; } // single click on a box → no-op (no split)
  vsMergeRegion(a.x, a.y, b.x, b.y);
  vsRender();
}

/** Apply the builder layout to the live wall (without saving). */
function vsApply() {
  const cl = normalizeCustomLayout(vsState);
  if (!cl) { vsSetError('Layout has no boxes.'); return false; }
  clearAllCarousels();
  state.maximized = null;
  state.customLayout = cl;
  state.layoutId = 'custom';
  state.currentViewId = null; // an unsaved custom arrangement — no active view
  // Map each box (sorted-cell order = slot index) to its assigned camera (#8).
  // Boxes left unassigned in Setup stay empty — the operator placed cameras
  // deliberately, so we don't auto-fill over their intent.
  const newMap = new Map();
  const newItems = new Map();
  state.hotspotCam = null;
  cl.cells.forEach((cell, slot) => {
    const spec = normalizeTileSpec(vsState.assign.get(vsKey(cell)));
    if (!spec) return;
    if (spec.type === 'camera') {
      if (state.cameras.some(c => c.id === spec.cameraId)) newMap.set(slot, spec.cameraId);
    } else {
      newItems.set(slot, spec);
    }
  });
  state.slotMap = newMap;
  state.slotItems = newItems;
  applySlotItems(); // start carousel engines + derive ptz/hotspot slotMap entries
  if (state.selectedSlot >= cl.cells.length) state.selectedSlot = 0;
  buildLayoutPresets();
  buildTileGrid();
  buildCameraList();
  pbReflectLayoutChange();
  return true;
}

/**
 * After a layout change, also rebuild the PLAYBACK grid if it's the visible view
 * (the layout/Setup controls are shared across Live + Playback, but the change
 * handlers are live-centric — without this, playback keeps stale geometry).
 */
function pbReflectLayoutChange() {
  pbState.maximizedSlot = null; // the maximized slot may not exist in the new layout
  const tiles = getLayout().tiles;
  if (pbState.selectedSlot >= tiles) pbState.selectedSlot = 0; // clamp to new layout
  if (els.viewPlayback && !els.viewPlayback.classList.contains('hidden')) {
    pbBuildTileGrid();
    pbResolveAllPanes(pbState.playheadMs, true);
  }
}

/** Apply + persist the builder layout as a named view, with its chosen icon.
 *  Saving REPLACES any existing view(s) of the same name (the API has no update
 *  for name/layout/slots, so we create the new one then delete the old) —
 *  editing "Test" and saving it updates "Test" in place instead of leaving two.
 *  The icon travels on the create call itself (views.icon), so a fresh client
 *  sees it right away instead of only after a follow-up PUT. */
async function vsSaveAsView() {
  const name = document.getElementById('vs-name-input').value.trim();
  if (!name) { vsSetError('Enter a name to save this view.'); return; }
  const icon = vsState.selectedIcon || '🎥';
  if (!vsApply()) return;
  await saveView(name, icon); // POST + refreshViews → viewsCache now has all same-named views
  // Keep exactly one "name": the NEWEST (the one just created); delete the rest.
  // (Robust regardless of POST's return value — the API has no update endpoint
  // for name/layout/slots; icon was already sent on create above.)
  const sameName = viewsCache
    .filter(v => v.name === name)
    .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
  const keep = sameName[0];
  if (keep) {
    setViewIcon(keep.id, icon); // sync the localStorage cache; server already has it from create
    state.currentViewId = keep.id;
    let removed = false;
    for (const v of sameName.slice(1)) removed = (await deleteViewQuiet(v.id)) || removed;
    if (removed) await refreshViews();
  }
  vsClose(); // Save commits AND closes the editor; Apply commits but keeps it open.
}

// ── Application state ─────────────────────────────────────────────────────────
const state = {
  /** Server base URL (user-editable on login) */
  server: '',
  /** Bearer token (null = not logged in) */
  token: null,
  /** Array of CameraDto from GET /cameras (viewer-safe endpoint) */
  cameras: [],
  /** Map<cameraId, {rtsp_main_url, rtsp_sub_url}> — resolved streams */
  streams: new Map(),
  /** Currently active layout id ('1x1'|'2x2'|... preset, or 'custom') */
  layoutId: '2x2',
  /** Custom layout geometry when layoutId==='custom': {cols,rows,cells:[{x,y,w,h}]} */
  customLayout: null,
  /** Map<slotIndex, cameraId> — which camera is in which tile slot */
  slotMap: new Map(),
  /** Which slot is currently "selected" (click to assign) */
  selectedSlot: 0,
  /** Id of the saved view currently applied (for the toolbar active highlight), or null. */
  currentViewId: null,
  /**
   * Maximized state: null | { slotIndex, cameraId }
   * When set, we render a temporary 1×1 layout with just that camera
   * at its MAIN stream URL.
   */
  maximized: null,
  /**
   * Carousel state: Map<slotIndex, { cameras:[cameraId,...], intervalMs, idx, timer, mode }>
   * Each entry drives automatic camera rotation on that tile.
   */
  carousels: new Map(),
  /**
   * Tile (view-item) specs: Map<slotIndex, spec>. The TYPE + config of each box
   * that isn't a plain camera. `slotMap` still holds the camera currently SHOWN in
   * every VIDEO slot (camera / carousel-current / hotspot-current / ptz) so all the
   * existing pane/audio/ptz/playback logic is untouched; DOM tiles (image/clock/
   * text/events/web) have NO slotMap entry, so pane logic skips them automatically.
   *   {type:'camera', cameraId}                         (also represented by slotMap alone)
   *   {type:'carousel', cameras:[id...], intervalMs, mode:'time'|'motion'|'both'}
   *   {type:'hotspot'}                                  shows the camera clicked elsewhere
   *   {type:'ptz', cameraId}                            dedicated PTZ control tile
   *   {type:'image', dataUrl}
   *   {type:'clock'}
   *   {type:'text', text}
   *   {type:'events'}                                   live detections feed
   *   {type:'web', url}
   */
  slotItems: new Map(),
  /** Camera id the hotspot tile(s) currently show (set by clicking a camera). */
  hotspotCam: null,
  /** Capabilities from GET /auth/me (fetched once after login). Null until loaded. */
  caps: null,
  /** True when the signed-in user is an administrator (is_admin from /auth/me). */
  isAdmin: false,
  /** Cached username from GET /auth/me (shown in Settings → Connection). */
  username: '',
};

// ── Tile (view-item) spec helpers ─────────────────────────────────────────────
/** Video tiles own a native pane; DOM tiles render HTML and have no slotMap entry.
 *  NOTE: 'ptz' is a DOM tile — a dedicated CONTROL PANEL (d-pad/zoom/presets), NOT
 *  a second copy of the camera video. */
const VIDEO_TILE_TYPES = new Set(['camera', 'carousel', 'hotspot']);

/** Coerce a stored slot value (legacy camera-id string, or a spec object) into a
 *  spec, or null. */
function normalizeTileSpec(v) {
  if (!v) return null;
  if (typeof v === 'string') return { type: 'camera', cameraId: v };
  if (typeof v === 'object' && typeof v.type === 'string') return v;
  return null;
}

/** The camera a VIDEO tile is currently SHOWING (carousel→current, hotspot→target),
 *  or null for DOM tiles / an unfilled slot. */
function tileSpecCam(spec, slot) {
  if (!spec) return null;
  switch (spec.type) {
    case 'camera': return spec.cameraId || null;
    case 'ptz':    return spec.cameraId || null;
    case 'hotspot':
      // Auto-hotspot (a camera set is configured) follows motion per-slot via slotMap;
      // classic click-hotspot uses the shared global target.
      if (Array.isArray(spec.cameras) && spec.cameras.length) return state.slotMap.get(slot) || null;
      return state.hotspotCam || null;
    case 'carousel': {
      const car = state.carousels.get(slot);
      if (car && car.cameras && car.cameras.length) return car.cameras[car.idx % car.cameras.length];
      return (spec.cameras && spec.cameras[0]) || null;
    }
    default: return null;
  }
}

/** The canonical spec for a slot (for saving / Setup seeding): the slotItems spec
 *  if any, else a plain camera spec derived from slotMap, else null. */
function slotSpec(slot) {
  const it = state.slotItems.get(slot);
  if (it) return it;
  const cam = state.slotMap.get(slot);
  return cam ? { type: 'camera', cameraId: cam } : null;
}

/** Rebuild state.slotMap + start/stop carousel engines to match state.slotItems.
 *  Plain-camera slots keep their slotMap entry; video specs derive a current camera;
 *  DOM specs clear the slotMap entry so no pane is created. */
function applySlotItems() {
  for (const [slot, spec] of [...state.slotItems.entries()]) {
    if (spec.type === 'carousel') {
      carouselStartFromSpec(slot, spec);
    } else if (!VIDEO_TILE_TYPES.has(spec.type)) {
      state.slotMap.delete(slot); // DOM tile (incl. ptz control panel) — no pane
    }
  }
  // Hotspot tiles come in two flavours:
  //  • AUTO-hotspot (spec.cameras set): follows the camera with the most recent motion
  //    among its set, per-slot — even if those cameras aren't on the wall.
  //  • CLICK-hotspot (no camera set): the classic shared target driven by clicking a
  //    camera on the wall.
  const autoHotspots = [];
  const clickHotspots = [];
  for (const [s, sp] of state.slotItems) {
    if (sp.type !== 'hotspot') continue;
    if (Array.isArray(sp.cameras) && sp.cameras.length) autoHotspots.push([s, sp]); else clickHotspots.push(s);
  }
  // Auto-hotspots: seed each from its set (most-recent motion, else first camera) so the
  // tile shows something immediately; hotspotMotionTick() keeps it live afterwards.
  for (const [s, sp] of autoHotspots) {
    const st = hotspotAuto.get(s) || {};
    let cam = state.slotMap.get(s);
    if (!cam || !sp.cameras.includes(cam)) {
      cam = pickHotspotCam(sp.cameras) || sp.cameras[0];
      st.cam = cam; st.lastSwitchTs = 0; st.pinned = false;
    }
    hotspotAuto.set(s, st);
    if (cam) state.slotMap.set(s, cam); else state.slotMap.delete(s);
  }
  // Drop stale per-slot dwell state for hotspots no longer present.
  for (const s of [...hotspotAuto.keys()]) if (!autoHotspots.some(([as]) => as === s)) hotspotAuto.delete(s);
  // Click-hotspots: seed from the first camera on the wall so a freshly-applied view
  // shows something immediately (clicking another camera re-targets it).
  if (clickHotspots.length) {
    if (!state.hotspotCam) {
      for (const [s, cam] of state.slotMap) { if (!clickHotspots.includes(s)) { state.hotspotCam = cam; break; } }
    }
    clickHotspots.forEach(s => { if (state.hotspotCam) state.slotMap.set(s, state.hotspotCam); else state.slotMap.delete(s); });
  }
}

/** Most-recently-moved camera among a set (by camLastMotionTs), or null if none seen yet. */
function pickHotspotCam(cameras) {
  let best = null, bestTs = -1;
  for (const id of cameras) {
    const ts = camLastMotionTs.get(id) || 0;
    if (ts > bestTs) { bestTs = ts; best = id; }
  }
  return best;
}

// ── DOM refs (resolved after DOMContentLoaded) ────────────────────────────────
let els = {};

// ── Status bar ────────────────────────────────────────────────────────────────
function setStatus(msg) {
  if (els.statusText) els.statusText.textContent = msg;
}

// ── Tauri helpers ─────────────────────────────────────────────────────────────

/**
 * Build the pane spec array from current state and call sync_panes.
 * Only tiles that have a camera AND a resolved stream are included.
 * Debounced on resize via the exported `scheduleSync` wrapper.
 */
// Mirror of each live pane's last-synced URL, so the stall watchdog state for a
// slot can be cleared when its camera/stream changes (a new stream's time-pos is
// unrelated to the old one — stale counters could otherwise trip a spurious reload).
let paneUrlMirror = {};
async function syncPanes() {
  // A modal is open — its DOM would be occluded by recreated native panes
  // (HWND_TOP). Never recreate panes while a modal is up; the modal-close path
  // re-syncs. (Guards the rAF/ResizeObserver/debounce races, not just the call.)
  if (modalOpen > 0) return;
  // Determine the working slot assignment for sync purposes.
  // If maximized, just one pane at main stream.
  let paneSpecs = [];

  if (state.maximized !== null) {
    const { slotIndex, cameraId } = state.maximized;
    const el = getTileEl(slotIndex);
    if (el && cameraId) {
      const url = liveStreamUrl(cameraId, true); // maximized → full-quality main
      if (url) {
        const r = el.getBoundingClientRect();
        const strip = tileStripPx();
        const bot = tileBottomInset(slotIndex);
        const maxRect = { x: r.x, y: r.y + strip, w: r.width, h: r.height - strip - bot };
        // Keep every OTHER wall camera's pane WARM (mpv alive + decoding) but fully
        // OCCLUDED behind the maximized pane, instead of tearing them down. Restoring
        // the wall then just resizes panes back to their tiles — no teardown →
        // reconnect → first-keyframe cascade ("windows fill in one at a time").
        // They share the maximized rect and are listed FIRST so the maximized pane,
        // pushed LAST, lands on top (sync_panes raises panes to HWND_TOP in order;
        // WS_CLIPSIBLINGS clips the hidden ones away cleanly). URLs match the
        // non-maximized branch so no stream reloads on maximize/restore.
        const layout = getLayout();
        for (let i = 0; i < layout.tiles; i++) {
          if (i === slotIndex) continue;
          const otherCam = state.slotMap.get(i);
          if (!otherCam) continue;
          const ourl = liveStreamUrl(otherCam, false); // occluded warm panes keep the wall stream
          if (!ourl) continue;
          paneSpecs.push({ id: `slot${i}`, url: ourl, x: maxRect.x, y: maxRect.y, w: maxRect.w, h: maxRect.h });
        }
        paneSpecs.push({ id: `slot${slotIndex}`, url, x: maxRect.x, y: maxRect.y, w: maxRect.w, h: maxRect.h });
      }
    }
  } else {
    const layout = getLayout();
    for (let i = 0; i < layout.tiles; i++) {
      const cameraId = state.slotMap.get(i);
      if (!cameraId) continue;
      // Wall tiles use the per-camera stream pref, defaulting to the light SUB
      // stream (option); maximizing a tile jumps it to full-quality MAIN.
      const url = liveStreamUrl(cameraId, false);
      if (!url) continue;
      const rt = tileRect(i); // active-view-scoped + inset-adjusted (R3)
      if (!rt) continue; // absent or zero-size (not yet rendered)
      paneSpecs.push({ id: `slot${i}`, url, x: rt.x, y: rt.y, w: rt.w, h: rt.h });
    }
  }

  // R5: drop stale watchdog state for any pane whose stream URL changed, and prune
  // mirror entries for panes no longer present — so a slot reassignment can't carry
  // an old camera's stall counters onto a new one.
  const liveIds = new Set(paneSpecs.map(p => p.id));
  for (const spec of paneSpecs) {
    if (paneUrlMirror[spec.id] !== spec.url) {
      delete liveProgressPrev[spec.id];
      delete liveStallState[spec.id];
      paneUrlMirror[spec.id] = spec.url;
    }
  }
  for (const id of Object.keys(paneUrlMirror)) if (!liveIds.has(id)) delete paneUrlMirror[id];

  try {
    await invoke('sync_panes', { panes: paneSpecs });
    const count = paneSpecs.length;
    setStatus(`${state.cameras.length} cameras • ${currentViewLabel()} • ${count} pane${count !== 1 ? 's' : ''} live`);
  } catch (e) {
    setStatus(`sync_panes error: ${e}`);
    console.error('sync_panes failed:', e);
  }
  // Keep the in-view PTZ overlay aligned with the (re-laid-out) active tile.
  ptzOverlayReposition();
}

// Debounced resize sync — 80 ms as specified.
// Routes the resync to whichever view currently owns the native panes: the
// playback grid (pbSyncPanes) when the Playback tab is visible, otherwise the
// live grid (syncPanes). On the Server tab no panes are mounted, so do nothing.
// (Previously this always called syncPanes, so resizing during playback
// repositioned panes from live state — wrong tiles/streams.)
let syncTimer = null;
function scheduleSync() {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(() => {
    if (modalOpen > 0) return; // don't paint panes over an open modal
    if (els.viewPlayback && !els.viewPlayback.classList.contains('hidden')) {
      pbSyncPanes();
    } else if (els.viewLive && !els.viewLive.classList.contains('hidden')) {
      syncPanes();
    }
  }, 80);
}

// ── Modal guard ────────────────────────────────────────────────────────────────
// Native video panes are HWND_TOP (above the WebView) so they occlude any DOM
// modal. Every modal MUST bracket itself with modalOpened()/modalClosed(): open
// HIDES the panes (SWP_HIDEWINDOW — keeps mpv warm/connected) + kills any pending
// debounce + blocks future syncs; close re-shows them and re-aligns geometry.
// The counter handles nested/overlapping modals.
//
// NOTE: we hide (not destroy) the panes so the live streams stay connected while
// the modal is up — closing the modal is then instant, with no reconnect freeze.
// The `modalOpen` guard still no-ops syncPanes/pbSyncPanes/scheduleSync so panes
// are never RECREATED over the modal while it's open.
let modalOpen = 0;
function modalOpened() {
  modalOpen += 1;
  clearTimeout(syncTimer); // kill any in-flight debounced sync
  // Hide (don't destroy) the native panes so they don't occlude the modal but
  // stay warm/connected — closing the modal brings them back with no freeze.
  invoke('set_panes_hidden', { hidden: true }).catch((e) => console.error('set_panes_hidden(true) failed:', e));
}
function modalClosed() {
  modalOpen = Math.max(0, modalOpen - 1);
  if (modalOpen === 0) {
    // Re-show the (still-connected) panes, then re-sync to re-align geometry in
    // case the window was resized while the modal was open.
    invoke('set_panes_hidden', { hidden: false })
      .catch((e) => console.error('set_panes_hidden(false) failed:', e))
      .finally(() => scheduleSync());
  }
}

// ── Options dialog ──────────────────────────────────────────────────────────────
// Houses non-per-view preferences: the title-bar toggle (#2) and the PTZ click
// mode (#5). Brackets itself with modalOpened()/modalClosed() like every modal.
function optOpen() {
  const dlg = document.getElementById('opt-dialog');
  const bd  = document.getElementById('opt-backdrop');
  if (!dlg) return;
  // Reflect current options into the controls.
  const cb = document.getElementById('opt-show-infobar');
  if (cb) cb.checked = !!options.showInfoBar;
  const lf = document.getElementById('opt-launch-fullscreen');
  if (lf) lf.checked = !!options.launchFullscreen;
  const ws = document.getElementById('opt-wall-sub');
  if (ws) ws.checked = options.liveWallSub !== false;
  const mm = document.getElementById('opt-maximize-main');
  if (mm) mm.checked = options.maximizeMain !== false;
  const ac = document.getElementById('opt-show-allcams');
  if (ac) ac.checked = options.showAllCamerasView !== false;
  const zm = document.getElementById('opt-zoom-motion');
  if (zm) zm.checked = options.zoomClipsToMotion !== false;
  const center = document.getElementById('opt-ptz-center');
  const pan    = document.getElementById('opt-ptz-pan');
  const ptzoff = document.getElementById('opt-ptz-off');
  if (center) center.checked = options.ptzClickMode !== 'pan' && options.ptzClickMode !== 'off';
  if (pan)    pan.checked    = options.ptzClickMode === 'pan';
  if (ptzoff) ptzoff.checked = options.ptzClickMode === 'off';
  const edges = document.getElementById('opt-ptz-edges');
  const wheel = document.getElementById('opt-ptz-wheel');
  if (edges) edges.checked = options.ptzStyle !== 'wheel';
  if (wheel) wheel.checked = options.ptzStyle === 'wheel';
  modalOpened();
  bd?.classList.remove('hidden');
  dlg.classList.remove('hidden');
}

function optClose() {
  document.getElementById('opt-dialog')?.classList.add('hidden');
  document.getElementById('opt-backdrop')?.classList.add('hidden');
  modalClosed();
  // showInfoBar may have changed → rebuild tiles so the strips render/clear and
  // the native panes re-inset, then repopulate the indicators immediately.
  if (els.viewLive && !els.viewLive.classList.contains('hidden')) {
    buildTileGrid();
    void liveStatusPoll();
  }
}

async function clearAllPanes() {
  try {
    await invoke('clear_panes');
  } catch (e) {
    console.error('clear_panes failed:', e);
  }
}

// ── API helpers ───────────────────────────────────────────────────────────────

function authHeaders() {
  return { 'Authorization': `Bearer ${state.token}`, 'Content-Type': 'application/json' };
}

// Native fetch, captured so fetchWithTimeout can call it without self-recursion
// after the codebase-wide fetch()→fetchWithTimeout() sweep.
const nativeFetch = window.fetch.bind(window);
const DEFAULT_FETCH_TIMEOUT_MS = 9000;

// Every network fetch goes through this so a half-open socket or a wedged NVR
// can't leave a promise pending forever (review R1). AbortController gives the
// request a hard ceiling; on timeout the fetch rejects (AbortError) like any
// other network failure, so existing catch/!res.ok paths handle it. Callers that
// need a longer budget (login, exports) pass timeoutMs.
async function fetchWithTimeout(url, opts = {}, timeoutMs = DEFAULT_FETCH_TIMEOUT_MS) {
  // Respect a caller-supplied signal by not clobbering it.
  if (opts.signal) return nativeFetch(url, opts);
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    return await nativeFetch(url, { ...opts, signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

// Central authed request against state.server: injects the bearer + a timeout and
// maps 401/403 to the session-drop path ONCE, instead of the branch being
// hand-copied at ~22 sites (review A3). Returns the Response — callers read
// .ok/.json() — and does NOT throw on other non-2xx by default, so fire-and-forget
// callers (PTZ, clips-viewed) keep their semantics. Pass {throwOnError:true} for
// the strict variant.
async function api(path, opts = {}) {
  const { timeoutMs, throwOnError, headers, ...rest } = opts;
  const res = await fetchWithTimeout(
    `${state.server}${path}`,
    { ...rest, headers: { ...authHeaders(), ...(headers || {}) } },
    timeoutMs,
  );
  if (res.status === 401) { handleUnauthorized(); throw new Error('401'); }
  if (res.status === 403) throw Object.assign(new Error('403'), { isForbidden: true });
  if (throwOnError && !res.ok) {
    throw new Error(`${(rest.method || 'GET')} ${path} → ${res.status}`);
  }
  return res;
}

async function apiLogin(server, username, password, remember = true) {
  // Longer budget than polls — auth does a bcrypt verify server-side.
  // `remember: true` mints a long-lived token so the saved session survives client
  // restarts (boot auto-login keeps the user in). When the user unchecks "Keep me
  // signed in" we request a normal (~24h) token and don't persist it.
  const res = await fetchWithTimeout(`${server}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password, remember }),
  }, 15000);
  if (!res.ok) {
    const text = await res.text().catch(() => res.statusText);
    throw new Error(`Login failed (${res.status}): ${text}`);
  }
  return res.json(); // { token, expires_at }
}

async function apiFetchCameras() {
  const res = await api('/cameras'); // viewer-safe endpoint; 401/403 handled centrally
  if (!res.ok) throw new Error(`GET /cameras → ${res.status}`);
  const all = await res.json();
  // Natural-numeric sort by display name so the All Cameras view, the hotkey
  // auto-assignment, and every camera list are consistently alphabetical
  // (".06" < ".08" < ".10", not creation/DB order).
  return all
    .filter(c => c.enabled)
    .sort((a, b) => (a.name || '').localeCompare(b.name || '', undefined, { numeric: true, sensitivity: 'base' }));
}

async function apiFetchStreams(cameraId) {
  const res = await api(`/cameras/${cameraId}/streams`); // 401/403 handled centrally
  if (!res.ok) throw new Error(`GET /cameras/${cameraId}/streams → ${res.status}`);
  return res.json(); // { rtsp_main_url, rtsp_sub_url, ... }
}

// ── Capability gating ─────────────────────────────────────────────────────────

/** Fetch /auth/me once after login; store caps + isAdmin; call applyCaps(). */
async function fetchAndApplyMe() {
  try {
    const res = await api('/auth/me');
    if (!res.ok) return; // non-fatal — degrade gracefully (no gating applied)
    const me = await res.json();
    state.isAdmin  = !!me.is_admin;
    state.caps     = me.capabilities || {};
    state.username = me.username || '';
  } catch {
    // Network or parse failure — leave state.caps null; show everything.
  }
  applyCaps();
}

/** Show/hide tab buttons and control surfaces based on state.caps + state.isAdmin.
 *  Admins always see everything regardless of capabilities. */
function applyCaps() {
  const caps     = state.caps;
  const isAdmin  = state.isAdmin;

  // Nothing to gate until /auth/me has loaded.
  if (!caps && !isAdmin) return;

  // Helper: hide or show a single element by id.
  const gate = (id, visible) => {
    const el = document.getElementById(id);
    if (el) el.classList.toggle('hidden', !visible);
  };

  // Clips tab
  gate('tab-clips-btn',    isAdmin || !!(caps && caps.clips));
  // Export tab
  gate('tab-export-btn',   isAdmin || !!(caps && caps.export));
  // Playback tab
  gate('tab-playback-btn', isAdmin || !!(caps && caps.playback));
  // PTZ: the overlay and toolbar home/presets are only shown by ptzRefresh()
  // dynamically, but we suppress the entire overlay container up-front here so
  // a non-PTZ user never sees it flash open while ptzRefresh() is still in flight.
  const ptzAllowed = isAdmin || !!(caps && caps.ptz);
  const ptzOverlay = document.getElementById('ptz-overlay');
  if (ptzOverlay && !ptzAllowed) ptzOverlay.classList.add('hidden');
  // When playback is disallowed and the user is currently on that tab, redirect.
  if (!isAdmin && caps && !caps.playback) {
    const pb = document.getElementById('view-playback');
    if (pb && !pb.classList.contains('hidden')) {
      activateTab('live');
    }
  }
  // When clips are disallowed and the user is currently on that tab, redirect.
  if (!isAdmin && caps && !caps.clips) {
    const vc = document.getElementById('view-clips');
    if (vc && !vc.classList.contains('hidden')) {
      activateTab('live');
    }
  }
  // When export is disallowed and the user is currently on that tab, redirect.
  if (!isAdmin && caps && !caps.export) {
    const ve = document.getElementById('view-export');
    if (ve && !ve.classList.contains('hidden')) {
      activateTab('live');
    }
  }
}

// ── Re-auth overlay (H6) ──────────────────────────────────────────────────────
// A 401 mid-session (expired/revoked token) used to tear the whole wall down to
// the login screen — which for an unattended camera wall meant every native
// video pane got destroyed (clear_panes) just because a token lapsed. Instead,
// drop the token but keep the app shell + panes exactly as they are, and show a
// modal re-auth overlay on top; on successful sign-in, swap in the new token and
// resume (no reload of cameras/panes needed — nothing else changed).
let reauthShown = false;

function reauthOpen() {
  if (reauthShown) return; // already up (don't stack — repeated 401s while it's open)
  reauthShown = true;
  const user = document.getElementById('reauth-user');
  if (user) user.value = state.username || localStorage.getItem(LS_USER_KEY) || '';
  document.getElementById('reauth-error')?.classList.add('hidden');
  document.getElementById('reauth-backdrop')?.classList.remove('hidden');
  document.getElementById('reauth-dialog')?.classList.remove('hidden');
  document.getElementById('reauth-pass')?.focus();
  // Native panes are HWND_TOP over the WebView (see the "Modal guard" note above)
  // — hide (not destroy) them so the dialog is actually visible, while keeping
  // every stream connected underneath so closing this is instant, no reconnect.
  modalOpened();
}

function reauthClose() {
  if (!reauthShown) return;
  reauthShown = false;
  document.getElementById('reauth-backdrop')?.classList.add('hidden');
  document.getElementById('reauth-dialog')?.classList.add('hidden');
  modalClosed();
}

async function reauthSubmit() {
  const userEl = document.getElementById('reauth-user');
  const passEl = document.getElementById('reauth-pass');
  const errEl  = document.getElementById('reauth-error');
  const btn    = document.getElementById('reauth-submit-btn');
  const username = userEl ? userEl.value.trim() : '';
  const password = passEl ? passEl.value : '';
  if (!username) {
    if (errEl) { errEl.textContent = 'Username is required.'; errEl.classList.remove('hidden'); }
    return;
  }
  if (btn) { btn.disabled = true; btn.textContent = 'Signing in…'; }
  try {
    const remember = localStorage.getItem(LS_REMEMBER_KEY) !== '0';
    const data = await apiLogin(state.server, username, password, remember);
    state.token = data.token;
    if (remember) await saveToken(data.token);
    localStorage.setItem(LS_USER_KEY, username);
    if (passEl) passEl.value = '';
    reauthClose();
    setStatus('Signed back in.');
  } catch (err) {
    if (errEl) { errEl.textContent = err.message; errEl.classList.remove('hidden'); }
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Sign in'; }
  }
}

function handleUnauthorized() {
  // Token expired or revoked. Drop the token (so no further request tries to use
  // it) but do NOT tear down the app shell / native video panes — show a modal
  // re-auth overlay on top instead, so an unattended wall keeps playing.
  state.token = null;
  localStorage.removeItem(LS_TOKEN_KEY);
  clearMediaTokens(); // stale principal's scoped media tokens must not be reused
  reauthOpen();
}

// ── Scoped media tokens (P0-SESSIONS) ──────────────────────────────────────────
// Per-camera media URLs (recorded segments handed to the native mpv panes, clip
// <video>, snapshot/frame <img>, filmstrip thumbnails, the motion-tuner live MSE
// stream) used to carry the FULL login JWT as `?token=` — which then leaks into
// proxy/access logs and into mpv/<video>/<img> sources. That JWT can be valid for
// up to 10 years. Instead we mint a short-lived (~60 s), single-camera scoped
// media token via `GET /media-token?camera=<id>` (called WITH the full JWT in the
// Authorization header) and put THAT in the media URL. The server's try_media_token
// validates it and hard-scopes the request to exactly one camera.
//
// NOT migrated (deliberately): LIVE wall panes (RTSP-direct to go2rtc — no API
// token in the URL to begin with) and export DOWNLOADS (can span multiple cameras
// / the archive, so they keep the full-JWT / Authorization-header pattern).
const MEDIA_TOKEN_REFRESH_MARGIN_MS = 10_000; // refresh if it expires within ~10 s
const mediaTokenCache = new Map();  // cameraId → { token, expiresAtMs }
const mediaTokenInflight = new Map(); // cameraId → Promise<string|null> (dedupe)

// Return a fresh scoped media token for `cameraId`, minting/refreshing as needed.
// Concurrent callers for the same camera share one in-flight request. Returns null
// on failure (401 routes to the re-auth path; the caller must NOT fall back to the
// full JWT — it should let the pane/player retry, which re-requests a token).
async function getMediaToken(cameraId) {
  if (!cameraId || !state.token) return null;
  const cached = mediaTokenCache.get(cameraId);
  if (cached && cached.expiresAtMs - Date.now() > MEDIA_TOKEN_REFRESH_MARGIN_MS) {
    return cached.token;
  }
  const inflight = mediaTokenInflight.get(cameraId);
  if (inflight) return inflight;
  const p = (async () => {
    try {
      const res = await fetchWithTimeout(
        `${state.server}/media-token?camera=${encodeURIComponent(cameraId)}`,
        { headers: authHeaders() },
      );
      if (res.status === 401) { handleUnauthorized(); return null; }
      if (!res.ok) return null;
      const data = await res.json();
      if (!data || !data.token) return null;
      const expMs = data.expires_at ? Date.parse(data.expires_at) : (Date.now() + 60_000);
      mediaTokenCache.set(cameraId, { token: data.token, expiresAtMs: expMs });
      return data.token;
    } catch {
      return null; // transient — caller's retry will re-request
    } finally {
      mediaTokenInflight.delete(cameraId);
    }
  })();
  mediaTokenInflight.set(cameraId, p);
  return p;
}

// Append `?token=<scoped media token>` to a relative media URL for one camera.
// Awaits a fresh token; returns null if none could be minted (do NOT fall back to
// the full JWT). `relUrl` is server-relative (e.g. "/clip/<id>/clip.mp4?q=full").
async function mediaUrlForCamera(cameraId, relUrl) {
  const tok = await getMediaToken(cameraId);
  if (!tok) return null;
  const sep = relUrl.includes('?') ? '&' : '?';
  return state.server + relUrl + sep + 'token=' + encodeURIComponent(tok);
}

// Drop any cached scoped tokens (e.g. on logout / re-auth so a stale principal's
// tokens aren't reused).
function clearMediaTokens() {
  mediaTokenCache.clear();
  mediaTokenInflight.clear();
}

// ── Layout helpers ────────────────────────────────────────────────────────────

// O(1) camera-by-id lookup backed by state.cameraById (rebuilt with state.cameras).
// Replaces O(n) state.cameras.find() in per-row/per-tile render loops (S7).
function camById(id) {
  return (id && state.cameraById) ? (state.cameraById.get(id) || null) : null;
}

function getLayout() {
  if (state.layoutId === 'custom' && state.customLayout) {
    const cl = state.customLayout;
    return { id: 'custom', label: 'Custom', tiles: cl.cells.length, cls: 'layout-custom', custom: cl };
  }
  return LAYOUTS.find(l => l.id === state.layoutId) ?? LAYOUTS[1];
}

function getTileEl(slotIndex) {
  // Scope to the ACTIVE view's grid. Both #tile-grid (live) and #pb-tile-grid
  // (playback) carry the same data-slot attributes, so a document-wide query
  // returned whichever came first in the DOM — the hidden live tile during
  // playback — which mispositioned native mpv panes (review R3, bug 608076e).
  const onPlayback = els.viewPlayback && !els.viewPlayback.classList.contains('hidden');
  const container = onPlayback ? '#pb-tile-grid' : '#tile-grid';
  return document.querySelector(`${container} .tile[data-slot="${slotIndex}"]`);
}

// Inset-adjusted on-screen rect of a tile's video area (title strip inset on top,
// controls inset on bottom), resolved within the ACTIVE view via getTileEl. The
// strip/inset math was hand-repeated at ~10 sites — this is the single source
// (review R3). Returns null when the tile is absent or not yet laid out.
function tileRect(slotIndex) {
  const el = getTileEl(slotIndex);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  if (r.width < 2 || r.height < 2) return null;
  const strip = tileStripPx();
  const bot = tileBottomInset(slotIndex);
  return { el, rect: r, x: r.x, y: r.y + strip, w: r.width, h: r.height - strip - bot };
}

// ── Rendering: layout preset buttons ─────────────────────────────────────────

// The live toolbar's quick-switch row now holds SAVED VIEWS (the grid-size
// presets were removed — views are the presets). Each button shows the view's
// user-chosen icon + name: click applies it, right-click sets its icon. New
// layouts/views are created via the Setup button.
/** Apply the built-in "All Cameras" view — an auto-sized grid of every camera. */
function applyAllCamerasView() {
  clearAllCarousels();
  pbRestoreInjectedSlot();
  state.maximized = null;
  state.hotspotCam = null;
  const cams = state.cameras.map(c => c.id);
  const n = Math.max(1, cams.length);
  const cols = Math.ceil(Math.sqrt(n));
  const rows = Math.ceil(n / cols);
  state.customLayout = { cols, rows, cells: vsUnitCells(cols, rows) };
  state.layoutId = 'custom';
  state.currentViewId = '__all__'; // sentinel → highlights the All Cameras button
  const newMap = new Map();
  cams.forEach((id, i) => newMap.set(i, id));
  state.slotMap = newMap;
  state.slotItems = new Map();
  state.selectedSlot = 0;
  buildLayoutPresets();
  buildCameraList();
  buildTileGrid();
  ptzRefresh();
  pbReflectLayoutChange();
}

function buildLayoutPresets() {
  const container = document.getElementById('toolbar-layout-presets') || els.layoutPresets;
  if (!container) return;
  container.innerHTML = '';

  // Always-available "All Cameras" default view (every camera, auto-grid). Its
  // appearance is toggleable in Options (options.showAllCamerasView).
  if (options.showAllCamerasView !== false && state.cameras.length) {
    const allBtn = document.createElement('button');
    allBtn.className = 'layout-btn view-preset-btn'
      + (state.currentViewId === '__all__' ? ' active' : '')
      + (getDefaultView() === '__all__' ? ' is-default' : '');
    allBtn.title = 'Show every camera · right-click to set as the launch view';
    allBtn.innerHTML = `<span class="vpb-icon">▦</span><span class="layout-btn-label">All Cameras</span>`;
    allBtn.addEventListener('click', applyAllCamerasView);
    allBtn.addEventListener('contextmenu', (e) => { e.preventDefault(); setDefaultView('__all__'); });
    container.appendChild(allBtn);
  }

  if (!viewsCache.length) {
    if (!container.children.length) {
      const hint = document.createElement('span');
      hint.className = 'toolbar-views-empty';
      hint.textContent = 'No views yet — click Config View →';
      container.appendChild(hint);
    }
    return;
  }

  orderedViews().forEach(view => {
    const btn = document.createElement('button');
    btn.className = 'layout-btn view-preset-btn'
      + (view.id === state.currentViewId ? ' active' : '')
      + (getDefaultView() === view.id ? ' is-default' : '');
    btn.dataset.viewId = view.id;
    btn.title = `${view.name} — click to switch · right-click to set as the launch view`;
    btn.innerHTML =
      `<span class="vpb-icon">${getViewIcon(view.id)}</span>` +
      `<span class="layout-btn-label">${escHtml(view.name)}</span>`;
    btn.addEventListener('click', () => applyView(view.id));
    btn.addEventListener('contextmenu', (e) => { e.preventDefault(); setDefaultView(view.id); });
    container.appendChild(btn);
  });
}

function layoutSvgIcon(layoutId) {
  // Thin SVG diagrams matching each layout pattern.
  // Viewport 28×21 with 1px stroke cells.
  const W = 28, H = 21, S = 1.2; // stroke
  const p = S / 2; // inset to avoid clip

  switch (layoutId) {
    case '1x1':
      return `<svg class="layout-icon" viewBox="0 0 ${W} ${H}">
        <rect x="${p}" y="${p}" width="${W - S}" height="${H - S}" />
        <rect class="fill-rect" x="${p}" y="${p}" width="${W - S}" height="${H - S}" />
      </svg>`;

    case '2x2': {
      const cw = (W - S) / 2, ch = (H - S) / 2;
      return `<svg class="layout-icon" viewBox="0 0 ${W} ${H}">
        <rect x="${p}"        y="${p}"         width="${cw - p}" height="${ch - p}" />
        <rect x="${cw + p}"   y="${p}"         width="${cw - p}" height="${ch - p}" />
        <rect x="${p}"        y="${ch + p}"    width="${cw - p}" height="${ch - p}" />
        <rect x="${cw + p}"   y="${ch + p}"    width="${cw - p}" height="${ch - p}" />
      </svg>`;
    }

    case '3x3': {
      const cw = (W - S) / 3, ch = (H - S) / 3;
      let rects = '';
      for (let r = 0; r < 3; r++) for (let c = 0; c < 3; c++) {
        rects += `<rect x="${c * cw + p}" y="${r * ch + p}" width="${cw - S}" height="${ch - S}" />`;
      }
      return `<svg class="layout-icon" viewBox="0 0 ${W} ${H}">${rects}</svg>`;
    }

    case '1plus5': {
      // 3-col × 3-row; big = col 0-1, row 0-1; 5 small cells fill the rest
      const cw = (W - S) / 3, ch = (H - S) / 3;
      return `<svg class="layout-icon" viewBox="0 0 ${W} ${H}">
        <rect x="${p}"          y="${p}"          width="${2*cw - S}" height="${2*ch - S}" />
        <rect class="fill-rect" x="${p}" y="${p}" width="${2*cw - S}" height="${2*ch - S}" />
        <rect x="${2*cw + p}"   y="${p}"          width="${cw - S}"   height="${ch - S}"  />
        <rect x="${2*cw + p}"   y="${ch + p}"     width="${cw - S}"   height="${ch - S}"  />
        <rect x="${p}"          y="${2*ch + p}"   width="${cw - S}"   height="${ch - S}"  />
        <rect x="${cw + p}"     y="${2*ch + p}"   width="${cw - S}"   height="${ch - S}"  />
        <rect x="${2*cw + p}"   y="${2*ch + p}"   width="${cw - S}"   height="${ch - S}"  />
      </svg>`;
    }

    case '4x4': {
      const cw = (W - S) / 4, ch = (H - S) / 4;
      let rects = '';
      for (let r = 0; r < 4; r++) for (let c = 0; c < 4; c++) {
        rects += `<rect x="${c * cw + p}" y="${r * ch + p}" width="${cw - S}" height="${ch - S}" />`;
      }
      return `<svg class="layout-icon" viewBox="0 0 ${W} ${H}">${rects}</svg>`;
    }

    default: return '';
  }
}

// ── Rendering: camera list ────────────────────────────────────────────────────

function buildCameraList() {
  const container = els.cameraList;
  container.innerHTML = '';

  if (state.cameras.length === 0) {
    container.innerHTML = '<div style="padding:12px;font-size:11px;color:var(--text-muted)">No cameras found</div>';
    return;
  }

  // Build reverse map: cameraId → slots using it
  const onWall = new Set();
  state.slotMap.forEach(camId => onWall.add(camId));

  state.cameras.forEach(cam => {
    const isOnWall = onWall.has(cam.id);
    const row = document.createElement('div');
    row.className = `camera-row${isOnWall ? ' on-wall' : ''}`;
    row.dataset.cameraId = cam.id;
    const tok = hotkeyForCamera(cam.id);
    const hk = tok
      ? `<span class="cam-hotkey" title="Press ${escHtml(hotkeyLabel(tok))} to go to this camera">${escHtml(hotkeyLabel(tok))}</span>`
      : '';
    row.title = `Assign "${cam.name}" to selected tile`;
    row.innerHTML = `
      <span class="cam-icon">
        <svg width="14" height="11" viewBox="0 0 14 11" fill="none">
          <rect x="0.5" y="2.5" width="9" height="8" rx="1" stroke="currentColor" stroke-width="1.1"/>
          <path d="M9.5 5L13 3v5l-3.5-2z" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/>
        </svg>
      </span>
      <span class="cam-name">${escHtml(cam.name)}</span>
      ${hk}
      <span class="cam-live-dot"></span>
    `;
    row.addEventListener('click', () => assignCameraToSelectedSlot(cam.id));
    container.appendChild(row);
  });
}

// ── Rendering: tile grid ──────────────────────────────────────────────────────

/**
 * Rebuild the tile grid for the current layout (or maximize state).
 * After building, triggers syncPanes so Rust aligns native windows.
 */
function buildTileGrid() {
  const grid = els.tileGrid;
  grid.innerHTML = '';

  // Panes are recreated → any in-progress drag-pan session is invalid (its slot
  // may now host a different camera). Clear it (defends the mouse-capture leak).
  paneDragState = null;

  // Remove all layout classes (presets + custom) then add the correct one.
  LAYOUTS.forEach(l => grid.classList.remove(l.cls));
  grid.classList.remove('layout-custom');
  // Clear any inline grid template left over from a previous custom layout.
  grid.style.gridTemplateColumns = '';
  grid.style.gridTemplateRows = '';

  if (state.maximized !== null) {
    // Render a single tile for the maximized camera
    grid.classList.add('layout-1x1');
    const { slotIndex, cameraId } = state.maximized;
    const tile = buildTileElement(slotIndex, cameraId, true);
    grid.appendChild(tile);
  } else {
    const layout = getLayout();
    grid.classList.add(layout.cls);

    if (layout.custom) {
      // Custom layout — set the grid template inline and span each tile.
      const cl = layout.custom;
      grid.style.gridTemplateColumns = `repeat(${cl.cols}, 1fr)`;
      grid.style.gridTemplateRows = `repeat(${cl.rows}, 1fr)`;
      cl.cells.forEach((cell, i) => {
        const cameraId = state.slotMap.get(i) ?? null;
        const tile = buildTileElement(i, cameraId, false);
        tile.style.gridColumn = `${cell.x + 1} / span ${cell.w}`;
        tile.style.gridRow = `${cell.y + 1} / span ${cell.h}`;
        grid.appendChild(tile);
      });
    } else {
      for (let i = 0; i < layout.tiles; i++) {
        const cameraId = state.slotMap.get(i) ?? null;
        const tile = buildTileElement(i, cameraId, false);
        grid.appendChild(tile);
      }
    }
  }

  startClockTicker(); // updates any clock view-items (no-op if none)
  // After DOM is updated, measure rects and sync with Rust.
  // Use requestAnimationFrame to ensure layout has been computed.
  requestAnimationFrame(() => syncPanes());
}

/** Build a DOM (non-video) view-item tile — image / clock / text / detections / web.
 *  These render their content directly in the tile and own NO native pane. */
function buildDomTileElement(slotIndex, spec, isMaximized) {
  const tile = document.createElement('div');
  tile.className = ['tile', 'has-camera', 'tile-item', `tile-item-${spec.type}`,
    slotIndex === state.selectedSlot && !isMaximized ? 'selected' : ''].filter(Boolean).join(' ');
  tile.dataset.slot = slotIndex;

  let inner = '';
  if (spec.type === 'image') {
    inner = spec.dataUrl
      ? `<img class="tile-image" src="${spec.dataUrl}" alt="">`
      : `<div class="tile-item-empty">🖼<span>No image — pick one in Config View</span></div>`;
  } else if (spec.type === 'clock') {
    inner = `<div class="tile-clock"><div class="tile-clock-time" data-clock="time">--:--:--</div><div class="tile-clock-date" data-clock="date"></div></div>`;
  } else if (spec.type === 'text') {
    inner = `<div class="tile-text" style="${spec.size ? `font-size:${Math.max(10, Math.min(72, spec.size | 0))}px` : ''}">${escHtml(spec.text || '').replace(/\n/g, '<br>') || '<span class="tile-item-empty"><span>Empty text — edit in Config View</span></span>'}</div>`;
  } else if (spec.type === 'events') {
    inner = `<div class="tile-events" data-events="1"><div class="tile-events-head">DETECTIONS</div><div class="tile-events-list" data-events-list="1"><div class="tile-events-empty">Waiting for detections…</div></div></div>`;
  } else if (spec.type === 'web') {
    inner = spec.url
      ? `<iframe class="tile-web" src="${escHtml(spec.url)}" sandbox="allow-scripts allow-same-origin allow-forms allow-popups" referrerpolicy="no-referrer"></iframe>`
      : `<div class="tile-item-empty">🌐<span>No URL — set one in Config View</span></div>`;
  } else if (spec.type === 'ptz') {
    inner = buildPtzPanelHtml(spec);
  }
  const num = options.showInfoBar ? '' : `<span class="tile-slot-num">${slotIndex + 1}</span>`;
  tile.innerHTML = `${num}${inner}`;
  if (spec.type === 'ptz') wirePtzPanel(tile, spec); // wire d-pad/zoom/presets to its camera
  if (spec.type === 'events') wireEventTile(tile);    // click an event → jump to playback
  tile.addEventListener('click', () => selectSlot(slotIndex));
  tile.addEventListener('dblclick', (e) => { e.stopPropagation(); handleTileDoubleClick(slotIndex); });
  tile.addEventListener('contextmenu', (e) => {
    e.preventDefault(); e.stopPropagation(); selectSlot(slotIndex); ctxOpen(slotIndex, e.clientX, e.clientY);
  });
  return tile;
}

function buildTileElement(slotIndex, cameraId, isMaximized) {
  // DOM view-items render their own HTML (no native pane).
  const itemSpec = state.slotItems.get(slotIndex);
  if (itemSpec && !VIDEO_TILE_TYPES.has(itemSpec.type)) {
    return buildDomTileElement(slotIndex, itemSpec, isMaximized);
  }
  const cam = cameraId ? camById(cameraId) : null;
  const stream = cameraId ? state.streams.get(cameraId) : null;
  const hasStream = !!(stream?.rtsp_main_url ?? stream?.rtsp_sub_url);
  const noStream = cameraId && !hasStream;
  const hasCarousel = state.carousels.has(slotIndex);
  // Video view-items (hotspot/carousel/ptz) render as a camera tile showing their
  // CURRENT camera; an unfilled hotspot gets a dedicated hint instead of "assign".
  const itemType = itemSpec?.type;
  const emptyText = itemType === 'hotspot' ? 'Hotspot — click any camera to show it here'
    : itemType === 'ptz' ? 'PTZ — assign a camera in Config View'
    : 'right-click to assign';

  const tile = document.createElement('div');
  tile.className = [
    'tile',
    cam ? 'has-camera' : '',
    noStream ? 'no-stream' : '',
    slotIndex === state.selectedSlot && !isMaximized ? 'selected' : '',
  ].filter(Boolean).join(' ');
  tile.dataset.slot = slotIndex;

  // commercial-VMS-style title strip: a thin bar at the top of the tile (in the gap the
  // native pane is inset below), carrying the camera name + live indicators
  // (motion / recording). Only shown for filled tiles when the info bar is on;
  // its height MUST equal TILE_STRIP_PX so the pane inset aligns with it.
  const showStrip = options.showInfoBar && !!cam;
  const stripHtml = showStrip ? `
    <div class="tile-strip${noStream ? ' no-stream' : ''}" data-cam="${cam.id}" style="height:${TILE_STRIP_PX}px">
      ${hasCarousel ? '<span class="tile-strip-icon" title="Carousel">&#x27F3;</span>' : ''}
      <span class="tile-strip-name">${escHtml(cam.name)}${noStream ? ' — no stream' : ''}</span>
      <span class="tile-strip-ind">
        <span class="tsi-detections" data-cam="${cam.id}"></span>
        <span class="tsi-perf" data-cam="${cam.id}" title="Decode health"></span>
        <span class="tsi tsi-motion" title="Motion (unclassified)">
          <svg class="tsi-glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M7.76 16.24l-1.41 1.41C4.78 16.1 4 14.05 4 12s.78-4.1 2.34-5.66l1.41 1.41C6.59 8.93 6 10.46 6 12s.59 3.07 1.76 4.24zm9.9-9.9l-1.41 1.41C17.41 8.93 18 10.46 18 12s-.59 3.07-1.76 4.24l1.41 1.41C19.22 16.1 20 14.05 20 12s-.78-4.1-2.34-5.66zM12 10c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm2.83-.83C15.55 9.9 16 10.9 16 12s-.45 2.1-1.17 2.83l1.41 1.41C17.41 15.1 18 13.62 18 12s-.59-3.1-1.76-4.24l-1.41 1.41zM9.17 9.17l-1.41-1.41C6.59 8.9 6 10.38 6 12s.59 3.1 1.76 4.24l1.41-1.41C8.45 14.1 8 13.1 8 12s.45-2.1 1.17-2.83z" fill="currentColor"/></svg>
        </span>
        <span class="tsi tsi-rec" title="Recording">
          <span class="tsi-dot"></span>
        </span>
      </span>
      ${(() => { const t = cam && hotkeyForCamera(cam.id); return t ? `<span class="tile-strip-num" title="Hotkey — press ${escHtml(hotkeyLabel(t))} to go to this camera">${escHtml(hotkeyLabel(t))}</span>` : ''; })()}
    </div>` : '';

  tile.innerHTML = `
    ${stripHtml}
    ${!showStrip ? (cam
      ? (() => { const t = hotkeyForCamera(cam.id); return t ? `<span class="tile-slot-num">${escHtml(hotkeyLabel(t))}</span>` : ''; })()
      : `<span class="tile-slot-num">${slotIndex + 1}</span>`) : ''}
    ${!showStrip && hasCarousel ? '<span class="tile-carousel-badge">&#x27F3; carousel</span>' : ''}
    <div class="tile-empty-hint">
      <svg class="tile-empty-icon" width="24" height="18" viewBox="0 0 24 18" fill="none">
        <rect x="1" y="3" width="15" height="14" rx="1.5" stroke="currentColor" stroke-width="1.2"/>
        <path d="M16 8l6-4v10l-6-4z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>
      </svg>
      <span class="tile-empty-text">${emptyText}</span>
    </div>
    <div class="tile-connecting">
      <span class="tile-connecting-spinner"></span>
      <span class="tile-connecting-text">Connecting…</span>
    </div>
  `;

  // Select tile on single click
  tile.addEventListener('click', () => selectSlot(slotIndex));

  // Double-click: maximize or restore
  tile.addEventListener('dblclick', (e) => {
    e.stopPropagation();
    handleTileDoubleClick(slotIndex);
  });

  // DOM contextmenu (fires on EMPTY tiles — native panes eat the event on filled ones)
  tile.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    e.stopPropagation();
    selectSlot(slotIndex);
    ctxOpen(slotIndex, e.clientX, e.clientY);
  });

  return tile;
}

// ── Live status poll (drives the title-strip REC / motion indicators) ─────────
// Polls GET /status every few seconds while the Live tab is visible and toggles
// each tile-strip's motion / recording dots. /status returns the cameras the
// user can access (admins: all; viewers: their scope), so this works for both.
let liveStatusTimer = null;

// ── Frigate detection icons (live wall) ───────────────────────────────────────
// When Frigate is actively detecting an object on a camera we show its TYPE icon
// on the tile strip — more specific than the generic motion runner. Colors and
// glyphs match the per-label detection contract (icon_key == label slug).
//
// KEYED BY icon_key (the per-label slug the API emits: person, car, truck, bus,
// bicycle, cat, dog, license_plate, face, package, …). Canonical source of truth
// is docs/DETECTION-ICONS.md — regenerate from there, do not hand-edit glyphs.
//
// detectionIconHtml() (inline-SVG) / drawDetIcon() (canvas Path2D) fall back to
// `generic` for any key not present here, so unknown / future labels still
// render a neutral marker.
const DETECTION_ICONS = {
  airplane: { color: '#FF6B22', svg: '<path fill="currentColor" d="M21.5 11.2 13.5 9.2V4.3c0-.8-.65-1.5-1.5-1.5s-1.5.7-1.5 1.5v4.9L2.5 11.2c-.3.07-.5.34-.5.65v1.1c0 .33.31.58.63.5L10.5 12v3.6l-2 1.4c-.16.12-.25.3-.25.5v.9c0 .28.27.48.54.4L12 18l3.21.8c.27.07.54-.12.54-.4v-.9c0-.2-.09-.38-.25-.5l-2-1.4V12l7.87 1.45c.32.08.63-.17.63-.5v-1.1c0-.31-.2-.58-.5-.65z"/>' },
  amazon: { color: '#C8923F', svg: '<path fill="currentColor" d="M4 6.4h16v2.1H4zM5.4 10h13.2l-1 9.1c-.1.92-.88 1.6-1.8 1.6H8.2c-.92 0-1.7-.68-1.8-1.6L5.4 10zm4.6 2.9v4.9h1.5v-4.9H10zm3.5 0v4.9H15v-4.9h-1.5z"/><path fill="currentColor" d="M6 18.8c3.85 1.9 8.15 1.9 12 0 .32-.16.58.24.3.5-1.45 1.25-3.9 1.95-6.3 1.95s-4.85-.7-6.3-1.95c-.28-.26-.02-.66.3-.5z"/>' },
  an_post: { color: '#3E8A6E', svg: '<path fill="currentColor" d="M12 2.5l2.6 6.2 6.7.5-5.1 4.4 1.6 6.5L12 16.9l-5.8 3.7 1.6-6.5L2.7 9.7l6.7-.5L12 2.5z"/>' },
  apple: { color: '#FF1F4A', svg: '<path fill="currentColor" d="M12 7c-1.5-1.5-4-2-6-1-2.5 1.3-3 5-1.5 8.5C5.7 17.5 8 21 10 21c1 0 1.3-.5 2-.5s1 .5 2 .5c2 0 4.3-3.5 5.5-6.5C21 11 20.5 7.3 18 6c-2-1-4.5-.5-6 1z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" fill="none" d="M12 7c0-2 1-3.5 3-4"/>' },
  backpack: { color: '#C0A062', svg: '<path fill="currentColor" d="M12 2c-1.86 0-3.4 1.4-3.6 3.2C6.5 5.9 5 7.8 5 10v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-9c0-2.2-1.5-4.1-3.4-4.8C15.4 3.4 13.86 2 12 2zm0 2c.83 0 1.5.67 1.5 1.5V6h-3v-.5C10.5 4.67 11.17 4 12 4zm-3 8h6a1 1 0 0 1 1 1v3H8v-3a1 1 0 0 1 1-1zm0 6h6v1H9v-1z"/>' },
  banana: { color: '#FF3B61', svg: '<path fill="currentColor" d="M4 9c0 6 5 11 11 11 2.5 0 4.5-1 5-2-2 .5-9 0-12-4S5 6 7 4C5 4 4 6 4 9z"/>' },
  baseball_bat: { color: '#4A48C8', svg: '<path d="M5 19 L16 8" fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round"/><path d="M4.5 20.5 L7 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>' },
  baseball_glove: { color: '#8482EC', svg: '<path fill-rule="evenodd" clip-rule="evenodd" d="M8 21 q-4 0 -4-4.5 Q4 13 6 11 V7.5 q0-1.8 1.6-1.8 q1.6 0 1.6 1.8 V5 q0-1.8 1.6-1.8 q1.6 0 1.6 1.8 v1.4 q0-1.6 1.5-1.6 q1.6 0 1.6 2.2 V12 q2 1 2 4.5 Q19 21 15 21 Z M11.5 13.1 a2.4 2.4 0 1 0 0 4.8 a2.4 2.4 0 1 0 0-4.8 Z" fill="currentColor"/>' },
  bear: { color: '#3FA8B5', svg: '<path fill="currentColor" d="M7 4.5a2.6 2.6 0 0 0-2.4 3.6A6.5 6.5 0 0 0 3.5 12c0 3.6 3.8 6.5 8.5 6.5s8.5-2.9 8.5-6.5c0-1.4-.4-2.7-1.1-3.9A2.6 2.6 0 1 0 15.6 5 9.9 9.9 0 0 0 12 4.4c-1.3 0-2.5.2-3.6.6A2.6 2.6 0 0 0 7 4.5zm2.2 6.2a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 0 1 0-2.2zm5.6 0a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 0 1 0-2.2zM12 13.5c.9 0 1.6.6 1.6 1.3 0 .7-.7 1.2-1.6 1.2s-1.6-.5-1.6-1.2c0-.7.7-1.3 1.6-1.3z"/>' },
  bed: { color: '#63707F', svg: '<path fill="currentColor" d="M3 9a1 1 0 0 1 1 1v3h7v-2a1 1 0 0 1 1-1h7a3 3 0 0 1 3 3v6a1 1 0 0 1-2 0v-1H4v1a1 1 0 0 1-2 0V10a1 1 0 0 1 1-1zm3 1.5a2 2 0 1 1 0 .01z"/>' },
  bench: { color: '#5B6675', svg: '<path fill="currentColor" d="M3 10h18a1 1 0 0 1 1 1v1H2v-1a1 1 0 0 1 1-1zm-1 3h20v1.5H2zm1 1.5h1.6V20a.8.8 0 0 1-1.6 0zm17.4 0H22V20a.8.8 0 0 1-1.6 0z"/>' },
  bicycle: { color: '#FFCC00', svg: '<g fill="currentColor"><circle cx="6" cy="16" r="4"/><circle cx="18" cy="16" r="4"/><path d="M6 16l5-7h6l-3 7H6z" stroke="currentColor" stroke-width="2" stroke-linejoin="round" fill="none"/><path d="M9 9h4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></g>' },
  bird: { color: '#5AC8DA', svg: '<path fill="currentColor" d="M14.5 5.2c-2.8 0-5 2.2-5 5 0 .4-.3.7-.7 1.1-1 .9-2.6 1.7-4.3 1.7 0 1.7 1.6 3.1 3.6 3.1.3 0 .6 0 .9-.1-.5.9-1.4 1.6-2.5 1.9 1 .7 2.3 1.1 3.6 1.1 3.6 0 6.4-2.9 6.4-6.5v-.3l2-2-2.6-.3-1-1.9-.8 2c-.6-.3-1.1-.5-1.8-.6.1-.2.1-.4.1-.7 0-.9.7-1.6 1.6-1.6V5.2zm.6 3.1a.8.8 0 1 1 0 1.6.8.8 0 0 1 0-1.6z"/>' },
  boat: { color: '#E0531A', svg: '<path fill="currentColor" d="M12.75 3.2c0-.55-.6-.9-1.08-.62l-5.5 3.2c-.23.14-.37.39-.37.65V11h-1.3c-.55 0-.94.54-.77 1.06l1.6 4.94H4c-.55 0-1 .45-1 1s.45 1 1 1h.6c.9 0 1.73-.42 2.27-1.12.54.7 1.37 1.12 2.27 1.12h.86c.9 0 1.73-.42 2.27-1.12.54.7 1.37 1.12 2.27 1.12h.86c.9 0 1.73-.42 2.27-1.12.54.7 1.37 1.12 2.27 1.12H20c.55 0 1-.45 1-1s-.45-1-1-1h-.13l1.6-4.94c.17-.52-.22-1.06-.77-1.06H12.75V3.2zM10.75 11H8.25V7.6l2.5-1.45V11z"/>' },
  book: { color: '#626E7D', svg: '<path fill="currentColor" d="M5 3h7v16H6a2 2 0 0 0-1.5.68V4a1 1 0 0 1 1-1zm14 0a1 1 0 0 1 1 1v15.68A2 2 0 0 0 18 19h-5V3zm-1 18H6a2 2 0 0 1 0-4h12a2 2 0 0 1 0 4z"/>' },
  bottle: { color: '#FF2D55', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M10 2h4v3l1.5 2.5c.3.5.5 1.1.5 1.7V20a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2V9.2c0-.6.2-1.2.5-1.7L10 5V2z"/><path stroke="currentColor" stroke-width="1.8" d="M8 13h8"/>' },
  bowl: { color: '#D62A4E', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M3 11h18a9 9 0 0 1-18 0z"/><path stroke="currentColor" stroke-width="1.6" stroke-linecap="round" d="M8 8c0-2 1-3 0-5M12 8c0-2 1-3 0-5M16 8c0-2 1-3 0-5"/>' },
  broccoli: { color: '#E83A5C', svg: '<path fill="currentColor" d="M9 3a3 3 0 0 0-2.8 4A3 3 0 0 0 4 9.8 3 3 0 0 0 6.5 13h11A3 3 0 0 0 20 9.8 3 3 0 0 0 17.8 7 3 3 0 0 0 13 4.2 3 3 0 0 0 9 3z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M10 13l-.5 8M14 13l.5 8M12 13v8"/>' },
  bus: { color: '#F08200', svg: '<path fill="currentColor" d="M5 4h14c1.1 0 2 .9 2 2v11.5c0 .66-.4 1.23-.98 1.48v.52a1.5 1.5 0 0 1-3 0V19H6.98v.5a1.5 1.5 0 0 1-3 0v-.52A1.6 1.6 0 0 1 3 17.5V6c0-1.1.9-2 2-2zm.5 3.5v4h5v-4h-5zm8 0v4h5v-4h-5zM7 14.5a1.25 1.25 0 1 0 0 2.5 1.25 1.25 0 0 0 0-2.5zm10 0a1.25 1.25 0 1 0 0 2.5 1.25 1.25 0 0 0 0-2.5z"/>' },
  cake: { color: '#FF6A8A', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 13c0-2 1.5-3 4-3h8c2.5 0 4 1 4 3v7H4v-7z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M3 20h18M8 10V6.5M12 10V6.5M16 10V6.5"/><path fill="currentColor" d="M8 4.5a1 1 0 0 0 2 0c0-.7-1-1.5-1-1.5s-1 .8-1 1.5zM11 4.5a1 1 0 0 0 2 0c0-.7-1-1.5-1-1.5s-1 .8-1 1.5zM15 4.5a1 1 0 0 0 2 0c0-.7-1-1.5-1-1.5s-1 .8-1 1.5z"/>' },
  canada_post: { color: '#C24B3E', svg: '<path fill="currentColor" d="M12 2.5l2.2 4.9 5.3-1.4-2.4 4.9 4 3.6-5.3.6.3 5.4L12 17.8l-4.1 2.7.3-5.4-5.3-.6 4-3.6L4.5 6l5.3 1.4L12 2.5z"/>' },
  car: { color: '#FF9500', svg: '<path fill="currentColor" d="M3 14.2c0-.5.32-.94.79-1.1l1.86-.62 2.2-3.05c.45-.62 1.17-.99 1.94-.99h4.9c.63 0 1.23.25 1.68.69l2.32 2.32 2.05.51c.62.16 1.05.71 1.05 1.35V16c0 .55-.45 1-1 1h-1.04a2.5 2.5 0 0 1-4.92 0H9.96a2.5 2.5 0 0 1-4.92 0H4c-.55 0-1-.45-1-1v-1.8zM9.2 10.4 7.7 12.5h4.3V10h-1.86c-.37 0-.72.15-.94.4zM13.5 12.5h3.9l-1.7-1.7a1 1 0 0 0-.71-.3H13.5v2zM6.5 16.5a1 1 0 1 0 2 0 1 1 0 0 0-2 0zm9 0a1 1 0 1 0 2 0 1 1 0 0 0-2 0z"/>' },
  carrot: { color: '#FF4060', svg: '<path fill="currentColor" d="M16.2 8.8c1-1.5-.6-3.1-2-2L4.5 16.5c-1.1 1.1.4 2.6 1.5 1.5l10.2-9.2z"/><path fill="currentColor" d="M15 7.5c-.6-2 .2-3.6 1.6-4.4-.2 1.3.1 2.3.9 3-.9-.1-1.8.4-2.5 1.4zM16 7c1.4-1.5 3.2-1.7 4.7-1-1.2.6-1.9 1.4-2 2.5-.6-.8-1.5-1.3-2.7-1.5zM15.6 7.4c-1.9-.6-2.9.1-3.6 1.5 1.3-.3 2.3 0 3 .9.1-1 .3-1.8.6-2.4z"/>' },
  cat: { color: '#5CD679', svg: '<path fill="currentColor" fill-rule="evenodd" d="M5.7 3.8c.5-.4 1.2-.1 1.3.5l.9 3.2a6 6 0 0 1 5.7-.1l.9-3.1c.2-.6.9-.9 1.4-.5.3.2.4.5.4.9l-.5 3.6a6 6 0 0 1 2.5 4.9c0 1.6-.7 3-1.7 4 .5.3 1.2.2 1.6-.3.3-.4 1-.4 1.2.1.2.4 0 .9-.4 1.1-1.4.8-3.2.5-4.2-.7a6.7 6.7 0 0 1-4.4 0 6 6 0 0 1-7.6-5.3 6 6 0 0 1 2.5-5L4.9 4.7c-.1-.4 0-.7.3-.9zM9 12.4c.6 0 1-.5 1-1.1s-.4-1.1-1-1.1-1 .5-1 1.1.4 1.1 1 1.1zm6 0c.6 0 1-.5 1-1.1s-.4-1.1-1-1.1-1 .5-1 1.1.4 1.1 1 1.1z" clip-rule="evenodd"/>' },
  cell_phone: { color: '#606C7B', svg: '<path fill="currentColor" d="M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm0 3.5v11h8v-11zm4 12.5a1 1 0 1 0 0 2 1 1 0 0 0 0-2z"/>' },
  chair: { color: '#5E6A79', svg: '<path fill="currentColor" d="M7 3a1 1 0 0 1 1 1v8h8V4a1 1 0 0 1 2 0v15a1 1 0 0 1-2 0v-3H8v3a1 1 0 0 1-2 0V4a1 1 0 0 1 1-1z"/>' },
  clock: { color: '#64717F', svg: '<path fill="currentColor" d="M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18zm0 2a7 7 0 1 0 0 14 7 7 0 0 0 0-14zm-.9 2.5a.9.9 0 0 1 1.8 0v4.1l2.7 1.6a.9.9 0 1 1-.9 1.55l-3.1-1.8a.9.9 0 0 1-.5-.8z"/>' },
  couch: { color: '#616D7C', svg: '<path fill="currentColor" d="M4 11V8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v3a2 2 0 0 0-1 1.73V15H3v-2.27A2 2 0 0 0 2 11a2 2 0 0 1 2 0zm-2 5h20v2H21v1.5a.75.75 0 0 1-1.5 0V18h-15v1.5a.75.75 0 0 1-1.5 0V18H2z"/>' },
  cow: { color: '#94B23A', svg: '<path fill="currentColor" fill-rule="evenodd" d="M2.2 8.4c-.1-.5.4-.9.8-.6l1.7 1.1c.6-.4 1.4-.6 2.3-.6h7c1.6 0 3 .8 3.9 2l.3-1.9c.1-.6-.1-1.2-.5-1.7l-.8-.9c-.3-.4 0-1 .5-.9l1 .2c1 .2 1.8 1 2 2l.3 1.7c.2 1.1-.1 2.2-.8 3.1-.1.5-.3 1-.5 1.4v3.4c0 .6-.4 1-1 1s-1-.4-1-1v-1.2c-.3.1-.7.2-1 .2v1.2c0 .6-.4 1-1 1s-1-.4-1-1v-1H9v1c0 .6-.4 1-1 1s-1-.4-1-1v-1.2c-.4 0-.7-.1-1-.2v1.4c0 .6-.4 1-1 1s-1-.4-1-1V13c-.6-.8-1-1.7-1-2.8 0-.3 0-.5.1-.8L2.2 8.4zM8.5 9c-1.4 0-2.5 1.1-2.5 2.5S7.1 14 8.5 14 11 12.9 11 11.5 9.9 9 8.5 9z"/>' },
  cup: { color: '#E0244A', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M5 8h11v7a4 4 0 0 1-4 4H9a4 4 0 0 1-4-4V8z"/><path fill="none" stroke="currentColor" stroke-width="1.8" d="M16 10h2a2 2 0 0 1 0 4h-2"/><path stroke="currentColor" stroke-width="1.6" stroke-linecap="round" d="M8 3v2M11.5 3v2"/>' },
  dhl: { color: '#C9A23D', svg: '<path fill="currentColor" d="M2 9.4h7.2l-.6 1.4H2.6l-.6-1.4zm.9 2.2h6.5l-.6 1.4H3.5l-.6-1.4zm10.3-2.2H22l-.55 1.4h-7.6l-.55-1.4zm-.9 2.2h7.5l-.55 1.4h-7.5l.55-1.4z"/><path fill="currentColor" d="M11.3 7.5h2.3l-3.2 9h-2.3l3.2-9z"/>' },
  dining_table: { color: '#56616F', svg: '<path fill="currentColor" d="M3 8h18a1 1 0 0 1 0 2H3a1 1 0 0 1 0-2zm2 3h1.6v9a.8.8 0 0 1-1.6 0zm12.4 0H19v9a.8.8 0 0 1-1.6 0zM8 13h8v1.4H8z"/>' },
  dog: { color: '#2BA84A', svg: '<path fill="currentColor" fill-rule="evenodd" d="M5.6 4.4c1.4-.5 2.7.2 3.5 1.2.9-.4 1.9-.6 2.9-.6s2 .2 2.9.6c.8-1 2.1-1.7 3.5-1.2 1.3.5 1.7 2 1.4 3.5-.2 1-.6 2.2-1 3.3.5.9.7 1.9.7 2.9 0 2.5-1.7 4.6-4 5.4-.3 1.1-.6 1.8-1 2.2-.4.4-1 .5-2.5.5h-.1c-1.5 0-2.1-.1-2.5-.5-.4-.4-.7-1.1-1-2.2-2.3-.8-4-2.9-4-5.4 0-1 .2-2 .7-2.9-.4-1.1-.8-2.3-1-3.3-.3-1.5.1-3 1.4-3.5zM6.3 6.2c-.3.1-.5.6-.3 1.6.2.9.5 1.9.9 2.8l.3-.3c.4-1.3.5-2.6.4-3.5-.1-.5-.3-.7-.4-.7-.4-.1-.8 0-.9.1zm11.4 0c-.1-.1-.5-.2-.9-.1-.1 0-.3.2-.4.7-.1.9 0 2.2.4 3.5l.3.3c.4-.9.7-1.9.9-2.8.2-1-.0-1.5-.3-1.6zM9.5 12.3a.95.95 0 1 0 0 1.9.95.95 0 0 0 0-1.9zm5 0a.95.95 0 1 0 0 1.9.95.95 0 0 0 0-1.9zM12 15.4c-.7 0-1.3.3-1.6.8-.2.3 0 .7.4.8.4.1.8.1 1.2.1s.8 0 1.2-.1c.4-.1.6-.5.4-.8-.3-.5-.9-.8-1.6-.8z" clip-rule="evenodd"/>' },
  donut: { color: '#FF577A', svg: '<path fill="currentColor" fill-rule="evenodd" d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zm0 6a3 3 0 1 1 0 6 3 3 0 0 1 0-6z"/>' },
  dpd: { color: '#C0966B', svg: '<path fill="currentColor" d="M3 6h10a1 1 0 0 1 1 1v3h3.2a1 1 0 0 1 .82.43l2.8 4A1 1 0 0 1 21 16v2h-1.6a2.4 2.4 0 0 1-4.8 0H9.4a2.4 2.4 0 0 1-4.8 0H3a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1zm11 6v3.05A2.4 2.4 0 0 1 16.05 14H19v-.18L16.68 12H14zm-7 3.6a1 1 0 1 0 0 2 1 1 0 0 0 0-2zm10 0a1 1 0 1 0 0 2 1 1 0 0 0 0-2z"/>' },
  elephant: { color: '#2E8B98', svg: '<path fill="currentColor" d="M8.5 4.5C5.7 4.5 3.5 6.7 3.5 9.5v6c0 .8.7 1.5 1.5 1.5s1.5-.7 1.5-1.5V12c0-.6.4-1 1-1s1 .4 1 1v3.5c0 .8.7 1.5 1.5 1.5s1.5-.7 1.5-1.5V11c1 .8 2.3 1.3 3.7 1.3.4 0 .8 0 1.2-.1v3.6c0 1 .3 2 .9 2.9.3.4.8.5 1.2.3.4-.3.5-.8.3-1.2-.4-.6-.6-1.2-.6-1.9V9.5c0-2.8-2.2-5-5-5h-5zm1 3a1 1 0 1 1 0 2 1 1 0 0 1 0-2z"/>' },
  face: { color: '#AF52DE', svg: '<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.8"/><circle cx="9" cy="10" r="1.15" fill="currentColor"/><circle cx="15" cy="10" r="1.15" fill="currentColor"/><path d="M8.2 14.2c.9 1.6 2.3 2.5 3.8 2.5s2.9-.9 3.8-2.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>' },
  fedex: { color: '#C77A3B', svg: '<path fill="currentColor" d="M4 7.5a1 1 0 0 1 1-1h8.5a1 1 0 0 1 1 1v7.5H4z"/><path fill="currentColor" d="M14.5 9.5h3.2a1 1 0 0 1 .82.43l1.98 2.77a1 1 0 0 1 .2.6V15h-7z"/><circle cx="8" cy="16.8" r="2.1" fill="currentColor"/><circle cx="17.4" cy="16.8" r="2.1" fill="currentColor"/><path fill="currentColor" d="M2.4 9h2.1v1.4H2.4zM2 11.4h2.5v1.4H2z"/>' },
  fire_hydrant: { color: '#9A9AA0', svg: '<path fill="currentColor" d="M10 12v7a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1v-7h2.5a1 1 0 0 0 0-2H16V8.5h1.5a.9.9 0 0 0 0-1.8H16V6a4 4 0 0 0-8 0v.7H6.5a.9.9 0 0 0 0 1.8H8V10H6.5a1 1 0 0 0 0 2H10zm0-6a2 2 0 0 1 4 0v4h-4V6z"/>' },
  fork: { color: '#FF6680', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M7 3v4M10 3v4M13 3v4M6.5 7h7a3.5 3.5 0 0 1-3.5 3.5v0M10 10.5V21"/>' },
  frisbee: { color: '#6E6CE0', svg: '<ellipse cx="12" cy="12" rx="9" ry="4" fill="none" stroke="currentColor" stroke-width="2"/><ellipse cx="12" cy="11" rx="5" ry="2.2" fill="currentColor" opacity="0.9"/>' },
  giraffe: { color: '#49C6CC', svg: '<path fill="currentColor" d="M9 20.5c-.4 0-.8-.3-.8-.8l-.4-7.4-1.6 1.3c-.4.3-1 .3-1.3-.1-.3-.4-.3-1 .1-1.3l2.7-2.2.9-6.2c0-.5.5-.9 1-.8.3 0 .5.2.6.4l.7-1.1c.2-.4.7-.5 1.1-.3.3.2.5.5.4.9l-.5 1.7.1 1.6 1.3 7.7c.4 2.4-.9 4.8-3.1 5.8l-.1 1.6c0 .4-.4.8-.8.8H9zm2.3-15a.7.7 0 1 0 0-1.4.7.7 0 0 0 0 1.4zm1.6 1.5a.7.7 0 1 0 0-1.4.7.7 0 0 0 0 1.4zm-1 2.4a.8.8 0 1 0 0-1.6.8.8 0 0 0 0 1.6zm1.6 1.8a.7.7 0 1 0 0-1.4.7.7 0 0 0 0 1.4z"/>' },
  gls: { color: '#6E8A4F', svg: '<path fill="currentColor" d="M12 3a9 9 0 100 18 9 9 0 000-18zm0 2a7 7 0 016.9 5.8h-4.3A3 3 0 0012 9.2V5zm-2 .4v9.2a7 7 0 01-4-6.3 7 7 0 014-2.9zM12 11a1 1 0 110 2 1 1 0 010-2zm2.6 3.8h4.3A7 7 0 0112 19v-4.2a3 3 0 002.6-1z"/>' },
  hair_drier: { color: '#5C6979', svg: '<path fill="currentColor" d="M3 8a4 4 0 0 1 4-4h6a4 4 0 0 1 0 8h-1.2l1 6.8A1 1 0 0 1 11.8 20H9.5a1 1 0 0 1-1-.85L7.4 12H7a4 4 0 0 1-4-4zm4-1.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z"/>' },
  handbag: { color: '#B59554', svg: '<path fill="currentColor" d="M9 6a3 3 0 0 1 6 0v1h2.2a1.5 1.5 0 0 1 1.49 1.33l1.1 9.5A2.5 2.5 0 0 1 17.3 21H6.7a2.5 2.5 0 0 1-2.49-2.67l1.1-9.5A1.5 1.5 0 0 1 6.8 7H9V6zm2 1h2V6a1 1 0 1 0-2 0v1z"/>' },
  horse: { color: '#A8C84A', svg: '<path fill="currentColor" d="M4 12.5c0-2.5 2-4.5 4.5-4.5h5.5c2.2 0 4 1.8 4 4v1c0 1.3-.6 2.5-1.6 3.3l.4 2.5c.1.5-.3.9-.8.9h-.4c-.4 0-.7-.3-.8-.7l-.3-1.9c-.4.1-.7.1-1.1.1H8.6c-.4 0-.8 0-1.1-.1l-.3 1.9c-.1.4-.4.7-.8.7h-.4c-.5 0-.9-.4-.8-.9l.4-2.4C4.7 15.6 4 14.1 4 12.5z"/><path fill="currentColor" d="M13 9.5l1.8-5.4c.2-.6.9-.8 1.4-.4l1 .8c.3.3.5.7.4 1.1l-1.2 4.6c-.2.7-.8 1.2-1.5 1.2H13z"/><path fill="currentColor" d="M15.8 3.2l2.6-.7c.5-.1 1 .3 1 .8l-.1 2.8c0 .5-.4.8-.9.8h-.8l-2.3-2.6c-.4-.5-.2-1.2.5-1.4z"/><rect x="6.3" y="16.5" width="1.6" height="4.5" rx=".8" fill="currentColor"/><rect x="9.3" y="16.5" width="1.6" height="4.5" rx=".8" fill="currentColor"/><rect x="13.3" y="16.5" width="1.6" height="4.5" rx=".8" fill="currentColor"/><rect x="15.6" y="16.5" width="1.6" height="4.5" rx=".8" fill="currentColor"/><path fill="currentColor" d="M4 12c-.8.3-1.4 1.1-1.6 2l-.3 1.4c-.1.5.5.8.9.5.5-.4.8-1 1-1.6l.6-1.8z"/>' },
  hot_dog: { color: '#FF2D55', svg: '<rect x="2.5" y="9" width="19" height="6" rx="3" fill="none" stroke="currentColor" stroke-width="1.8"/><rect x="5" y="10.6" width="14" height="2.8" rx="1.4" fill="currentColor"/>' },
  keyboard: { color: '#586573', svg: '<path fill="currentColor" d="M3 6h18a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2zm2 2.5v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zM5 12v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zM8 15.5v1.5h8v-1.5z"/>' },
  kite: { color: '#6260DE', svg: '<path d="M12 3 L19 10 L12 17 L5 10 Z" fill="currentColor"/><path d="M12 3 V17 M5 10 H19" fill="none" stroke="currentColor" stroke-width="1" opacity="0.35"/><path d="M12 17 q-1.5 2.5 0.5 3.8 q-2 1 -1 -2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>' },
  knife: { color: '#C71F40', svg: '<path fill="currentColor" d="M4 14L18 3c.5-.4 1.2.2.9.8L9 16l-3.2.6L5 20l-.8-.2.5-3.4L4 14z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M9.5 15.5l5.5 5.5"/>' },
  laptop: { color: '#5A6573', svg: '<path fill="currentColor" d="M5 5a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v9H5V5zm1.5 1.5v6h11v-6zM2.5 16h19a.5.5 0 0 1 .47.66l-.5 1.5A1 1 0 0 1 20.5 19h-17a1 1 0 0 1-.95-.84l-.5-1.5A.5.5 0 0 1 2.5 16z"/>' },
  license_plate: { color: '#FFB143', svg: '<rect x="2.5" y="6" width="19" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path fill="currentColor" d="M6 10h2v4H6zm3.5 0h2v4h-2zm3.5 0h5v4h-5z"/>' },
  microwave: { color: '#54606E', svg: '<path fill="currentColor" fill-rule="evenodd" d="M2 5h20a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zm2 3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1V9a1 1 0 0 0-1-1H4zm13 0a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1V9a1 1 0 0 0-1-1h-2zm.5 2a1 1 0 1 1 0 2 1 1 0 0 1 0-2zm0 3.5a1 1 0 1 1 0 2 1 1 0 0 1 0-2z" clip-rule="evenodd"/>' },
  motorcycle: { color: '#E0A800', svg: '<circle cx="5" cy="16.5" r="3.5" fill="currentColor"/><circle cx="19" cy="16.5" r="3.5" fill="currentColor"/><circle cx="5" cy="16.5" r="1.2" fill="none" stroke="currentColor" stroke-width="1.4"/><circle cx="19" cy="16.5" r="1.2" fill="none" stroke="currentColor" stroke-width="1.4"/><path fill="currentColor" d="M3 11.5l3.5-1.5 4 2.5 3-3.5h2.2l1 2 2.3.5v2.5l-3-.5-3.5-1-3 2H8.5l-1.5-2-3 .5z"/><path d="M14.5 8h3.5" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>' },
  mouse: { color: '#67748A', svg: '<path fill="currentColor" d="M12 3a7 7 0 0 1 7 7v4a7 7 0 0 1-14 0v-4a7 7 0 0 1 7-7zm-.9 2.1A5 5 0 0 0 7 10v.9h4V5.1zM13 5.1V11h4v-1a5 5 0 0 0-4-4.9z"/>' },
  nzpost: { color: '#2E6FB0', svg: '<path fill="currentColor" d="M5 19V5h2.4l6.2 8.4V5H16v14h-2.4L7.4 10.6V19H5z"/><path fill="currentColor" d="M17.8 6.1a1.3 1.3 0 110 2.6 1.3 1.3 0 010-2.6z"/>' },
  orange: { color: '#FF3355', svg: '<circle cx="12" cy="13" r="8" fill="currentColor"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" fill="none" d="M12 5c.5-1.5 2-2.5 3.5-2.5"/>' },
  oven: { color: '#525E6C', svg: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="3.5" y="2.5" width="17" height="19" rx="1.5"/><line x1="3.5" y1="8" x2="20.5" y2="8"/><line x1="7" y1="11.5" x2="17" y2="11.5"/></g><g fill="currentColor"><circle cx="6.5" cy="5.25" r="1"/><circle cx="10" cy="5.25" r="1"/><circle cx="13.5" cy="5.25" r="1"/><circle cx="17.5" cy="5.25" r="1"/></g>' },
  package: { color: '#A5825A', svg: '<path fill="currentColor" d="M21 7.5l-9-5-9 5v9l9 5 9-5v-9zm-9 1.31L6.96 6 12 3.19 17.04 6 12 8.81zM5 9.21l6 3.33v6.46l-6-3.33V9.21zm8 9.79v-6.46l6-3.33v6.46L13 19z"/>' },
  parking_meter: { color: '#76767D', svg: '<rect x="7.5" y="3" width="9" height="9" rx="2.4" fill="none" stroke="currentColor" stroke-width="1.8"/><circle cx="12" cy="7.5" r="1.7" fill="currentColor"/><path d="M11 12.5h2l-.5 5.5h-1z" fill="currentColor"/><path d="M9 21h6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>' },
  person: { color: '#FFFFFF', svg: '<path fill="currentColor" d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/>' },
  pizza: { color: '#FF3B61', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 6c5-2 11-2 16 0l-8 15L4 6z"/><circle cx="10" cy="8" r="1.1" fill="currentColor"/><circle cx="14" cy="9" r="1.1" fill="currentColor"/><circle cx="12" cy="13" r="1.1" fill="currentColor"/>' },
  postnl: { color: '#C77F3A', svg: '<path fill="currentColor" d="M3 18l8-12 4 6h-3l2 3h-3l1.4 2.1c.2.3 0 .9-.4.9H3z"/><path fill="currentColor" d="M16.8 9.2l3.6 6.3-1.8 1-3.6-6.3 1.8-1z"/>' },
  postnord: { color: '#3F6DA8', svg: '<path fill="currentColor" d="M12 2.5L3 8v8l9 5.5L21 16V8l-9-5.5zm0 2.3l6.7 4.1L12 13 5.3 8.9 12 4.8zM4.8 10.4l6.3 3.9v5.3l-6.3-3.9v-5.3zm14.4 0v5.3l-6.3 3.9v-5.3l6.3-3.9z"/>' },
  potted_plant: { color: '#586474', svg: '<path fill="currentColor" d="M12 11c0-3 1.5-5.5 5-7-.5 3.5-2 5.5-4 6.4 2-.2 3.5-1.4 5-3.4-1 4-3.5 5.5-6 5.5V14h-1v-1.5C8.5 12.5 6 11 5 7c1.5 2 3 3.2 5 3.4C8 9.5 6.5 7.5 6 4c3.5 1.5 5 4 5 7z"/><path fill="currentColor" d="M7 14h10l-1.2 6a1 1 0 0 1-1 .8H9.2a1 1 0 0 1-1-.8z"/>' },
  purolator: { color: '#B85C45', svg: '<path fill="currentColor" d="M12 2.5l8 4.3v8.4l-8 4.3-8-4.3V6.8l8-4.3zm0 2.3L6.3 7.9 12 11l5.7-3.1L12 4.8zM5.6 9.3v5.1l5.5 3v-5.1l-5.5-3zm12.8 0l-5.5 3v5.1l5.5-3V9.3z"/><path fill="currentColor" d="M11.2 12.8h1.6v4h-1.6z"/>' },
  refrigerator: { color: '#566270', svg: '<g fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" stroke-linecap="round"><rect x="6" y="3" width="12" height="18" rx="1.6"/><line x1="6" y1="9.5" x2="18" y2="9.5"/><line x1="9" y1="5.4" x2="9" y2="7.6"/><line x1="9" y1="12" x2="9" y2="16"/></g>' },
  remote: { color: '#5D6878', svg: '<path fill="currentColor" d="M9 2h6a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm3 2.2a1.4 1.4 0 1 0 0 2.8 1.4 1.4 0 0 0 0-2.8zM9.5 10h2v2h-2zm3 0h2v2h-2zm-3 3h2v2h-2zm3 0h2v2h-2zm-3 3h2v2h-2zm3 0h2v2h-2z"/>' },
  royal_mail: { color: '#9A4D55', svg: '<path fill="currentColor" d="M12 3a4.2 4.2 0 014.2 4.2V9h.8c.7 0 1.3.6 1.3 1.3V19c0 .7-.6 1.3-1.3 1.3H7c-.7 0-1.3-.6-1.3-1.3v-8.7C5.7 9.6 6.3 9 7 9h.8V7.2A4.2 4.2 0 0112 3zm0 2a2.2 2.2 0 00-2.2 2.2V9h4.4V7.2A2.2 2.2 0 0012 5zm0 8.5a1.6 1.6 0 100 3.2 1.6 1.6 0 000-3.2z"/>' },
  sandwich: { color: '#FF5C77', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 8c0-2.2 3.6-4 8-4s8 1.8 8 4H4z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M4 11.5h16M5 15l14-1.5"/><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 16h16v1a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3v-1z"/>' },
  scissors: { color: '#5E6B7C', svg: '<path fill="currentColor" d="M6.5 2a3.5 3.5 0 0 1 2.9 5.45L12 11l6.3-7.7a1 1 0 0 1 1.55 1.27L13.3 12.5l1.3 1.59A3.5 3.5 0 1 1 13 15.5l-1-1.2-1 1.2A3.5 3.5 0 1 1 9.4 14.1L10.7 12.5 4.45 4.55A1 1 0 0 1 5 2.9 3.49 3.49 0 0 1 6.5 2zm0 2a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm11 13a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm-11 0a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z"/>' },
  sheep: { color: '#BBD46A', svg: '<path fill="currentColor" fill-rule="evenodd" d="M9.5 4.2c.7 0 1.3.3 1.7.8.5-.2 1.1-.3 1.6-.3s1.1.1 1.6.3c.4-.5 1-.8 1.7-.8 1.1 0 2 .9 2 2 0 .5-.2 1-.5 1.3 1.4.8 2.4 2.3 2.4 4 0 2.1-1.4 3.8-3.3 4.4l.6 2.6c.1.5-.3.9-.8.9s-.9-.4-.9-.9v-.5h-2v.5c0 .5-.4.9-.9.9s-.9-.4-.8-.9l.1-.5h-2.2l.1.5c.1.5-.3.9-.8.9s-.9-.4-.9-.9v-.5h-2v.5c0 .5-.4.9-.9.9s-.9-.4-.8-.9l.6-2.6C4.4 15.8 3 14.1 3 12c0-1.7 1-3.2 2.4-4-.3-.3-.5-.8-.5-1.3 0-1.1.9-2 2-2 .2 0 .4 0 .6.1zM12 6.6c-1.4 0-2.6 1.2-2.6 2.6S10.6 11.8 12 11.8s2.6-1.2 2.6-2.6S13.4 6.6 12 6.6z"/>' },
  sink: { color: '#5B6877', svg: '<path fill="currentColor" d="M11 3a1 1 0 0 1 2 0v2h3a2 2 0 0 1 2 2v1a1 1 0 0 1-2 0V7h-3v3h7a1 1 0 0 1 1 1 8 8 0 0 1-3 6.24V20a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1v-1.76A8 8 0 0 1 4 12a1 1 0 0 1 1-1h6V3z"/>' },
  skateboard: { color: '#5C5AD8', svg: '<path d="M3 9 q9-3 18 0" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><circle cx="7.5" cy="14" r="2" fill="currentColor"/><circle cx="16.5" cy="14" r="2" fill="currentColor"/><path d="M7.5 11.8 V12.2 M16.5 11.8 V12.2" stroke="currentColor" stroke-width="1.4"/>' },
  skis: { color: '#5856D6', svg: '<g stroke="currentColor" stroke-width="2" stroke-linecap="round" fill="none"><path d="M6 21 L9 4"/><path d="M3.5 5.5 q2.5-1 5 0"/><path d="M14 21 L17 4"/><path d="M11.5 5.5 q2.5-1 5 0"/></g>' },
  snowboard: { color: '#504ECF', svg: '<g transform="rotate(-45 12 12)"><path fill="currentColor" fill-rule="evenodd" clip-rule="evenodd" d="M12 2.2c1.55 0 2.8 1.25 2.8 2.8v14c0 1.55-1.25 2.8-2.8 2.8S9.2 20.55 9.2 19V5c0-1.55 1.25-2.8 2.8-2.8zm0 1.8c-.66 0-1.2.54-1.2 1.2v2.55h2.4V5.2c0-.66-.54-1.2-1.2-1.2zm1.2 5.95h-2.4v4.1h2.4v-4.1zm0 5.5h-2.4V19c0 .66.54 1.2 1.2 1.2s1.2-.54 1.2-1.2v-2.55z"/></g>' },
  spoon: { color: '#FF879B', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M12 3c2.5 0 4 2 4 4.5S14.5 12 12 12s-4-2-4-4.5S9.5 3 12 3z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M12 12v9"/>' },
  sports_ball: { color: '#7472E6', svg: '<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 3.5c-3.2 2.3-3.2 14.7 0 17M12 3.5c3.2 2.3 3.2 14.7 0 17M3.6 9.2c4 1.7 12.8 1.7 16.8 0M4.2 16c4-1.7 11.6-1.7 15.6 0" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>' },
  stop_sign: { color: '#83838A', svg: '<polygon points="8.5,3 15.5,3 21,8.5 21,15.5 15.5,21 8.5,21 3,15.5 3,8.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><rect x="7.5" y="10.5" width="9" height="3" rx="0.6" fill="currentColor"/>' },
  suitcase: { color: '#C7AC78', svg: '<path fill="currentColor" d="M9 4a2 2 0 0 0-2 2v1H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-2V6a2 2 0 0 0-2-2H9zm0 2h6v1H9V6zM4.5 9.5h15V20H4.5V9.5zm4 1.5a.75.75 0 0 0-.75.75v6a.75.75 0 0 0 1.5 0v-6A.75.75 0 0 0 8.5 11zm7 0a.75.75 0 0 0-.75.75v6a.75.75 0 0 0 1.5 0v-6a.75.75 0 0 0-.75-.75z"/>' },
  surfboard: { color: '#6664E2', svg: '<path fill="currentColor" fill-rule="evenodd" d="M5 19C3 11 9 3 13 4c4 1 4 10-4 16-1.5 1-3 1-4-1Zm2.6-2.2 6-9c.3-.45.18-1.05-.27-1.35-.45-.3-1.05-.18-1.35.27l-6 9c-.3.45-.18 1.05.27 1.35.45.3 1.05.18 1.35-.27Z" clip-rule="evenodd"/>' },
  teddy_bear: { color: '#B89A5E', svg: '<path fill="currentColor" d="M7.5 4.2a2.3 2.3 0 0 0-1.6 3.94A4.5 4.5 0 0 0 5 10.5c0 1.9 1.27 3.5 3.06 4.2A2.5 2.5 0 0 0 8 15.5c0 .9.42 1.7 1.07 2.2A2.5 2.5 0 0 0 8.5 19a2.5 2.5 0 0 0 2.5 2.5h2A2.5 2.5 0 0 0 15.5 19c0-.47-.13-.9-.35-1.28A2.74 2.74 0 0 0 16 15.5c0-.28-.02-.54-.06-.8A4.51 4.51 0 0 0 19 10.5c0-.86-.24-1.66-.65-2.35A2.3 2.3 0 1 0 15.1 4.8 4.5 4.5 0 0 0 12 3.6a4.5 4.5 0 0 0-3.1 1.2 2.29 2.29 0 0 0-1.4-.6zM10 9.5a1 1 0 1 1 0 2 1 1 0 0 1 0-2zm4 0a1 1 0 1 1 0 2 1 1 0 0 1 0-2zm-2 2.5c.7 0 1.3.4 1.6 1h-3.2c.3-.6.9-1 1.6-1z"/>' },
  tennis_racket: { color: '#46449E', svg: '<ellipse cx="9.5" cy="9.5" rx="6" ry="7" fill="none" stroke="currentColor" stroke-width="2" transform="rotate(-40 9.5 9.5)"/><path d="M14 14 L20 20" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><path d="M6.5 6.5 L13 13 M5 10 L11 5" stroke="currentColor" stroke-width="0.9" opacity="0.55"/>' },
  tie: { color: '#A88A4B', svg: '<path fill="currentColor" d="M10.2 2h3.6a1 1 0 0 1 .95 1.32l-.7 2.1 1.86 8.36a1 1 0 0 1-.24.9l-2.94 3.1a1 1 0 0 1-1.45 0l-2.94-3.1a1 1 0 0 1-.24-.9l1.86-8.36-.7-2.1A1 1 0 0 1 10.2 2zm1.1 4.3-1.6 7.2L12 16.1l2.3-2.6-1.6-7.2h-1.4z"/>' },
  toaster: { color: '#5F6B7A', svg: '<path fill="currentColor" d="M3 11a3 3 0 0 1 3-3h12a3 3 0 0 1 3 3v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-6zm5-5.5a1 1 0 0 1 1 1V8H7V6.5a1 1 0 0 1 1-1zm4 0a1 1 0 0 1 1 1V8h-2V6.5a1 1 0 0 1 1-1zm5.5 6.5a1 1 0 0 0-1 1v3a1 1 0 0 0 2 0v-3a1 1 0 0 0-1-1z"/>' },
  toilet: { color: '#5C6776', svg: '<path fill="currentColor" d="M6 3h2a1 1 0 0 1 1 1v4h7a1 1 0 0 1 1 1v1a6 6 0 0 1-4 5.66V19h1a1 1 0 0 1 0 2H9a1 1 0 0 1 0-2h1v-3.34A6 6 0 0 1 7 11V4H6a1 1 0 0 1 0-2z"/>' },
  toothbrush: { color: '#606D7E', svg: '<path fill="currentColor" d="M4.2 4.1a1 1 0 0 1 1.32-.5l3.4 1.5a3 3 0 0 1 1.6 1.7l.9 2.5 8.86 9.93a1.5 1.5 0 0 1-2.24 2L9.6 11.6 7.1 10.7a3 3 0 0 1-1.7-1.6L4 5.7a1 1 0 0 1 .2-1.6zm2.3 1.9 1 2.8a1 1 0 0 0 .57.55l1.4.5-.5-1.4a1 1 0 0 0-.53-.57z"/>' },
  traffic_light: { color: '#8E8E93', svg: '<rect x="8.5" y="3" width="7" height="15" rx="2.2" fill="none" stroke="currentColor" stroke-width="1.8"/><circle cx="12" cy="6.5" r="1.4" fill="currentColor"/><circle cx="12" cy="10.5" r="1.4" fill="currentColor"/><circle cx="12" cy="14.5" r="1.4" fill="currentColor"/><path d="M12 18v3" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>' },
  train: { color: '#FF8242', svg: '<path fill="currentColor" d="M7 3c-2.2 0-4 1.8-4 4v8c0 1.66 1.34 3 3 3l-1.3 1.3c-.2.2-.06.55.22.55h1.66c.2 0 .39-.08.53-.22L8.83 18h6.34l1.69 1.63c.14.14.33.22.53.22h1.66c.28 0 .42-.35.22-.55L18 18c1.66 0 3-1.34 3-3V7c0-2.2-1.8-4-4-4H7zm-1.5 13c-.83 0-1.5-.67-1.5-1.5S4.67 13 5.5 13s1.5.67 1.5 1.5S6.33 16 5.5 16zM11 11H5V7h6v4zm2 0V7h6v4h-6zm5.5 5c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/>' },
  truck: { color: '#D97A00', svg: '<path fill="currentColor" d="M3 6.5C3 5.67 3.67 5 4.5 5h8c.83 0 1.5.67 1.5 1.5V9h3.26c.6 0 1.15.36 1.39.91l1.74 4.06c.1.24.16.5.16.76V16c0 .55-.45 1-1 1h-.54a2.5 2.5 0 0 1-4.92 0H9.96a2.5 2.5 0 0 1-4.92 0H4.5C3.67 17 3 16.33 3 15.5v-9zM14 10.5V15h.04a2.5 2.5 0 0 1 4.5-.5H19v-.83L17.43 10.5H14zM6.5 16.5a1 1 0 1 0 2 0 1 1 0 0 0-2 0zm10 0a1 1 0 1 0 2 0 1 1 0 0 0-2 0z"/>' },
  tv: { color: '#647183', svg: '<rect x="3" y="4" width="18" height="12" rx="1.5" fill="currentColor"/><path fill="currentColor" d="M8 19a1 1 0 0 1 1-1h6a1 1 0 0 1 0 2H9a1 1 0 0 1-1-1z"/>' },
  umbrella: { color: '#CBAE73', svg: '<path fill="currentColor" d="M12 2a9 9 0 0 0-9 9 .8.8 0 0 0 .8.8c.45 0 .82-.3 1.1-.6.45-.5 1-.8 1.6-.8s1.15.3 1.6.8c.3.32.68.6 1.1.6s.8-.28 1.1-.6c.18-.2.38-.36.6-.48V19a2 2 0 0 1-4 0 1 1 0 1 0-2 0 4 4 0 0 0 8 0v-8.08c.22.12.42.28.6.48.3.32.68.6 1.1.6s.8-.28 1.1-.6c.45-.5 1-.8 1.6-.8s1.15.3 1.6.8c.28.3.65.6 1.1.6a.8.8 0 0 0 .8-.8 9 9 0 0 0-9-9zm0 2a7 7 0 0 1 5.4 2.55A4 4 0 0 0 16 6c-.9 0-1.72.3-2.4.8A3.96 3.96 0 0 0 12 6c-.6 0-1.15.13-1.6.36A3.97 3.97 0 0 0 8 6c-.5 0-.97.09-1.4.25A7 7 0 0 1 12 4z"/>' },
  ups: { color: '#8A6233', svg: '<path fill="currentColor" d="M12 2.2l-7 2.7v7.3c0 4 2.85 6.6 7 8.6 4.15-2 7-4.6 7-8.6V4.9L12 2.2zm0 2.1l5 1.95v6.25c0 2.95-1.95 4.95-5 6.5-3.05-1.55-5-3.55-5-6.5V6.25L12 4.3zm-2.4 3.4v5c0 1.5 1 2.4 2.4 2.4s2.4-.9 2.4-2.4v-5h-1.6v5c0 .55-.3.85-.8.85s-.8-.3-.8-.85v-5H9.6z"/>' },
  usps: { color: '#7A5C8A', svg: '<path fill="currentColor" d="M3 16l8.7-9.2c.2-.2.55-.05.5.25L11 11h9.3c.35 0 .5.45.2.65L4.2 16.8c-.4.25-.85-.3-.55-.65L3 16z"/><path fill="currentColor" d="M3.6 17.5h17v1.4h-17z"/>' },
  vase: { color: '#596574', svg: '<path fill="currentColor" d="M8 3h8a1 1 0 0 1 .96 1.28l-1 3.4a1 1 0 0 0 .04.64C16.64 9.5 17 11.2 17 13a5 5 0 0 1-10 0c0-1.8.36-3.5 1-4.68a1 1 0 0 0 .04-.64l-1-3.4A1 1 0 0 1 8 3zm2.2 2 .6 2h2.4l.6-2z"/>' },
  wine_glass: { color: '#FF4F6E', svg: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M7 3h10l-1 5a5 5 0 0 1-8 0L7 3z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M12 13v7M8 21h8"/>' },
  zebra: { color: '#34B5C4', svg: '<path fill="currentColor" d="M5 19c-.4 0-.8-.3-.9-.7-.6-2.4 0-4.9 1.6-6.8l3-3.5V5.5c0-.6.3-1 .8-1.2.5-.2 1 0 1.4.4l1.4 1.6 2.7.5c2.1.4 3.7 2.1 4 4.2l.5 3.6c.1.6-.2 1.1-.7 1.3-.5.2-1.1 0-1.4-.5l-.8-1.3v3.6c0 .5-.4.9-.9.9h-1c-.3 0-.5-.2-.5-.5l-.3-3.6-2.1.3-.6 3.5c0 .3-.3.5-.6.5H8c-.4 0-.6-.4-.5-.7l.7-3.3-1.7 1.9c-.4.5-.5 1-.5 1.6 0 .4-.3.8-.7.8H5zm5.6-11.2-.3 1.9 1.5-.6-1.2-1.3zm3.6 2.1.7 1.7 1.4-.7-.6-.8-1.5-.2zm-4 1.4-.9 1.6 1.6-.3.3-1.6-1 .3zm3.1.4-.4 1.7 1.6-.2-.3-1.6-.9.1z"/>' },
  // ── legacy grouped keys (pre per-label contract) — render historical rows ──
  // Old backend collapsed labels into these group keys; keep aliases so events
  // ingested under the old contract still draw a sensible glyph.
  vehicle: { color: '#FF9500', svg: '<path fill="currentColor" d="M3 14.2c0-.5.32-.94.79-1.1l1.86-.62 2.2-3.05c.45-.62 1.17-.99 1.94-.99h4.9c.63 0 1.23.25 1.68.69l2.32 2.32 2.05.51c.62.16 1.05.71 1.05 1.35V16c0 .55-.45 1-1 1h-1.04a2.5 2.5 0 0 1-4.92 0H9.96a2.5 2.5 0 0 1-4.92 0H4c-.55 0-1-.45-1-1v-1.8zM9.2 10.4 7.7 12.5h4.3V10h-1.86c-.37 0-.72.15-.94.4zM13.5 12.5h3.9l-1.7-1.7a1 1 0 0 0-.71-.3H13.5v2zM6.5 16.5a1 1 0 1 0 2 0 1 1 0 0 0-2 0zm9 0a1 1 0 1 0 2 0 1 1 0 0 0-2 0z"/>' },
  animal: { color: '#2BA84A', svg: '<path fill="currentColor" fill-rule="evenodd" d="M5.6 4.4c1.4-.5 2.7.2 3.5 1.2.9-.4 1.9-.6 2.9-.6s2 .2 2.9.6c.8-1 2.1-1.7 3.5-1.2 1.3.5 1.7 2 1.4 3.5-.2 1-.6 2.2-1 3.3.5.9.7 1.9.7 2.9 0 2.5-1.7 4.6-4 5.4-.3 1.1-.6 1.8-1 2.2-.4.4-1 .5-2.5.5h-.1c-1.5 0-2.1-.1-2.5-.5-.4-.4-.7-1.1-1-2.2-2.3-.8-4-2.9-4-5.4 0-1 .2-2 .7-2.9-.4-1.1-.8-2.3-1-3.3-.3-1.5.1-3 1.4-3.5zM6.3 6.2c-.3.1-.5.6-.3 1.6.2.9.5 1.9.9 2.8l.3-.3c.4-1.3.5-2.6.4-3.5-.1-.5-.3-.7-.4-.7-.4-.1-.8 0-.9.1zm11.4 0c-.1-.1-.5-.2-.9-.1-.1 0-.3.2-.4.7-.1.9 0 2.2.4 3.5l.3.3c.4-.9.7-1.9.9-2.8.2-1-.0-1.5-.3-1.6zM9.5 12.3a.95.95 0 1 0 0 1.9.95.95 0 0 0 0-1.9zm5 0a.95.95 0 1 0 0 1.9.95.95 0 0 0 0-1.9zM12 15.4c-.7 0-1.3.3-1.6.8-.2.3 0 .7.4.8.4.1.8.1 1.2.1s.8 0 1.2-.1c.4-.1.6-.5.4-.8-.3-.5-.9-.8-1.6-.8z" clip-rule="evenodd"/>' },
  cycle: { color: '#FFCC00', svg: '<g fill="currentColor"><circle cx="6" cy="16" r="4"/><circle cx="18" cy="16" r="4"/><path d="M6 16l5-7h6l-3 7H6z" stroke="currentColor" stroke-width="2" stroke-linejoin="round" fill="none"/><path d="M9 9h4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></g>' },
  plate: { color: '#FFB143', svg: '<rect x="2.5" y="6" width="19" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path fill="currentColor" d="M6 10h2v4H6zm3.5 0h2v4h-2zm3.5 0h5v4h-5z"/>' },
  // Neutral grey marker for any label not present above (unknown / future class).
  generic: { color: '#8E8E93', svg: '<circle cx="12" cy="12" r="6" fill="currentColor"/>' },
};

function detectionIconHtml(key) {
  const d = DETECTION_ICONS[key] || DETECTION_ICONS.generic;
  return `<span class="tsi tsi-detect" title="${escHtml(key)}" style="color:${d.color}"><svg class="tsi-glyph" viewBox="0 0 24 24" aria-hidden="true">${d.svg}</svg></span>`;
}

// Canvas-drawable version of each detection icon, for the playback-timeline
// glyphs. We draw the SVG primitives DIRECTLY onto the canvas via Path2D rather
// than rasterising an <img> from a data-URI: in WebView2 the <img> path leaves
// `naturalWidth === 0` for SVG data-URIs, so every glyph silently collapsed to
// its fallback dot. DOMParser + Path2D is synchronous, needs no decode, and
// matches the inline-<svg> glyphs used elsewhere (proven across all 102 icons).
const _detIconDom = {};
function detIconSvgEl(key) {
  if (_detIconDom[key]) return _detIconDom[key];
  const d = DETECTION_ICONS[key] || DETECTION_ICONS.generic;
  const doc = new DOMParser().parseFromString(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">' + d.svg + '</svg>', 'image/svg+xml');
  return (_detIconDom[key] = doc.documentElement);
}
// Walk the parsed SVG children, painting each primitive. `currentColor` (or a
// missing fill) resolves to the icon's type colour; <g> passes its fill/stroke
// down. Coordinates are in the 24×24 viewBox; the caller applies the scale.
function drawSvgChildren(ctx, parent, iconColor, inFill, inStroke) {
  for (const el of parent.children) {
    const tag = el.tagName.toLowerCase();
    const fa = el.hasAttribute('fill') ? el.getAttribute('fill') : inFill;
    const sa = el.hasAttribute('stroke') ? el.getAttribute('stroke') : inStroke;
    if (tag === 'g') { drawSvgChildren(ctx, el, iconColor, fa, sa); continue; }
    let p;
    if (tag === 'path') p = new Path2D(el.getAttribute('d') || '');
    else if (tag === 'circle') { p = new Path2D(); p.arc(+el.getAttribute('cx'), +el.getAttribute('cy'), +el.getAttribute('r'), 0, Math.PI * 2); }
    else if (tag === 'ellipse') { p = new Path2D(); p.ellipse(+el.getAttribute('cx'), +el.getAttribute('cy'), +el.getAttribute('rx'), +el.getAttribute('ry'), 0, 0, Math.PI * 2); }
    else if (tag === 'rect') {
      p = new Path2D();
      const x = +el.getAttribute('x'), y = +el.getAttribute('y'), w = +el.getAttribute('width'), h = +el.getAttribute('height'), rx = parseFloat(el.getAttribute('rx')) || 0;
      if (rx && p.roundRect) p.roundRect(x, y, w, h, rx); else p.rect(x, y, w, h);
    } else if (tag === 'line') {
      p = new Path2D(); p.moveTo(+el.getAttribute('x1'), +el.getAttribute('y1')); p.lineTo(+el.getAttribute('x2'), +el.getAttribute('y2'));
    } else continue;
    const op = el.getAttribute('opacity'); if (op != null) ctx.globalAlpha = +op;
    const res = v => (v == null || v === 'currentColor') ? iconColor : v;
    const fill = (fa == null) ? iconColor : fa;
    if (fill !== 'none') { ctx.fillStyle = res(fill); ctx.fill(p, el.getAttribute('fill-rule') === 'evenodd' ? 'evenodd' : 'nonzero'); }
    if (sa && sa !== 'none') {
      ctx.strokeStyle = res(sa);
      ctx.lineWidth = parseFloat(el.getAttribute('stroke-width')) || 1;
      ctx.lineCap = el.getAttribute('stroke-linecap') || 'butt';
      ctx.lineJoin = el.getAttribute('stroke-linejoin') || 'miter';
      ctx.stroke(p);
    }
    if (op != null) ctx.globalAlpha = 1;
  }
}
// Paint detection icon `key` centred at (cx,cy), scaled to `size` px.
function drawDetIcon(ctx, key, cx, cy, size) {
  const d = DETECTION_ICONS[key] || DETECTION_ICONS.generic;
  const el = detIconSvgEl(key);
  const s = size / 24;
  ctx.save();
  ctx.translate(cx - size / 2, cy - size / 2);
  ctx.scale(s, s);
  drawSvgChildren(ctx, el, d.color, null, null);
  ctx.restore();
}

/** Object types Frigate is CURRENTLY (or just-recently) detecting per camera.
 *  Returns Map<cameraId, Set<icon_key>>. In-progress events (no end_ts) plus a
 *  short linger so brief detections don't flicker out the instant they end. */
async function fetchActiveDetections(camIds) {
  if (!camIds.length) return new Map();
  const now = Date.now();
  const start = new Date(now - 25000).toISOString();
  const end   = new Date(now + 5000).toISOString();
  const url = `${state.server}/events?camera_ids=${camIds.join(',')}`
    + `&start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}&limit=100`;
  const res = await fetchWithTimeout(url, { headers: authHeaders() });
  // Throw (not empty Map) on a server error so the caller can tell "no detections
  // right now" from "fetch failed" and keep the last glyphs instead of clearing
  // them (review R2). A genuine empty window still returns an empty Map below.
  if (!res.ok) throw new Error(`GET /events → ${res.status}`);
  const data = await res.json();
  const LINGER_MS = 8000;
  const map = new Map();
  for (const e of (data.events || [])) {
    const active = !e.end_ts || (now - Date.parse(e.end_ts)) < LINGER_MS;
    if (!active) continue;
    // Object detections only — motion is conveyed elsewhere, not as a tile glyph.
    if (!e.icon_key || e.icon_key === 'motion') continue;
    if (!map.has(e.camera_id)) map.set(e.camera_id, new Set());
    map.get(e.camera_id).add(e.icon_key);
  }
  return map;
}

// ── Config propagation ────────────────────────────────────────────────────────
// When the server's config fingerprint (/status `config_version`) changes, a
// camera/policy was edited server-side (stream URL, mode, retention, enable/…).
// Re-fetch cameras + streams and re-sync the panes; `sync_panes` diffs by URL, so
// only the panes whose stream actually changed reconnect — the rest stay warm.
// This is what makes a server edit apply WITHOUT a manual reload.
let liveConfigVersion = null;
let reloadingConfig = false;
let configReloadTimer = null;
function maybeApplyConfigChange(cv) {
  if (!cv) return;
  // Skip the FIRST observation so opening Live doesn't trigger a needless reload.
  if (liveConfigVersion !== null && cv !== liveConfigVersion) {
    // Trailing debounce: a flurry of admin edits (or a reconcile bumping the
    // fingerprint repeatedly) collapses into ONE N-camera refetch instead of
    // queuing a full reload per bump (review S4). reloadingConfig still guards
    // overlap; config propagation is eventually-consistent so the delay is fine.
    clearTimeout(configReloadTimer);
    configReloadTimer = setTimeout(() => { void reloadCameraConfig(); }, 1500);
  }
  liveConfigVersion = cv;
}
async function reloadCameraConfig() {
  if (reloadingConfig || modalOpen > 0) return;
  reloadingConfig = true;
  try {
    let cameras;
    try { cameras = await apiFetchCameras(); } catch { return; } // viewer/network — keep current
    // Capture old main URLs so we only re-arm the black-main probe for cameras
    // whose stream actually changed, not the whole fleet (review S4).
    const oldMain = new Map(cameras.map(c => [c.id, state.streams.get(c.id)?.rtsp_main_url]));
    state.cameras = cameras;
    state.cameraById = new Map(cameras.map(c => [c.id, c])); // id→camera index (S7)
    const results = await Promise.allSettled(cameras.map(c => apiFetchStreams(c.id)));
    results.forEach((r, i) => { if (r.status === 'fulfilled') state.streams.set(cameras[i].id, r.value); });
    for (const c of cameras) {
      if (state.streams.get(c.id)?.rtsp_main_url !== oldMain.get(c.id)) mainUnavailable.delete(c.id);
    }
    setStatus('Server config changed — reconnecting affected cameras…');
    scheduleSync(); // re-derives pane URLs from state.streams; unchanged panes stay live
  } finally {
    reloadingConfig = false;
  }
}

// Re-entrancy + connection-health state for the live status poller (R1/R2).
let statusPollInFlight = false;
let statusPollFailStreak = 0;

// Persistent "connection lost" banner so a wall frozen on stale indicators is
// never mistaken for a quiet one (review R2). Created lazily; toggled by .show.
function setConnLostBanner(show) {
  let el = document.getElementById('conn-lost-banner');
  if (show) {
    if (!el) {
      el = document.createElement('div');
      el.id = 'conn-lost-banner';
      el.textContent = '⚠ Connection lost — indicators may be stale';
      document.body.appendChild(el);
    }
    el.classList.add('show');
  } else if (el) {
    el.classList.remove('show');
  }
}

/** Platform-wide bookmarks toggle, driven by `/status.bookmarks_enabled`. When the
 *  admin disables bookmarks server-side, hide every bookmark button (Playback
 *  transport + cross-camera list + the Clips player) across all tabs. Defaults to
 *  ON when the field is absent (older servers). */
let bookmarksEnabled = true;
function applyBookmarksEnabled(enabled) {
  bookmarksEnabled = enabled !== false;
  for (const id of ['pb-bookmark-add', 'pb-bookmarks-open', 'clips-player-bookmark']) {
    const el = document.getElementById(id);
    if (el) el.style.display = bookmarksEnabled ? '' : 'none';
  }
}

async function liveStatusPoll() {
  if (!els.viewLive || els.viewLive.classList.contains('hidden')) return;
  if (modalOpen > 0) return; // panes/strips are torn down while a modal is open
  // Re-entrancy guard: on a slow/wedged server each 3s tick would otherwise stack
  // another /status + /events pair, piling up pending fetches + sockets (review
  // R1). Skip a tick if the previous one is still in flight.
  if (statusPollInFlight) return;
  statusPollInFlight = true;

  // Scan the strips ONCE per tick and reuse the list for the render loop below
  // (was queried twice every 3s — review S5).
  const strips = [...document.querySelectorAll('#tile-grid .tile-strip[data-cam]')];
  const camIds = strips.map(s => s.dataset.cam);

  // /status (rec + motion) and /events (live detections) in parallel.
  // detMap === null means the detection fetch FAILED → keep last glyphs (vs an
  // empty Map = a real empty window → clear them).
  let cams = null, detMap = null;
  try {
    const [statusRes, dets] = await Promise.all([
      fetchWithTimeout(`${state.server}/status`, { headers: authHeaders() }),
      fetchActiveDetections(camIds).catch(() => null),
    ]);
    if (statusRes.status === 401) { handleUnauthorized(); return; }
    if (statusRes.ok) {
      const sj = await statusRes.json();
      cams = sj.cameras ?? [];
      maybeApplyConfigChange(sj.config_version); // auto-apply server-side config edits
      applyBookmarksEnabled(sj.bookmarks_enabled); // platform-wide bookmark UI toggle
    } else {
      throw new Error(`/status ${statusRes.status}`);
    }
    detMap = dets;
    setConnLostBanner(false); // recovered (or never lost)
    statusPollFailStreak = 0;
  } catch {
    // Transient — keep the last indicator state, but after a few consecutive
    // failures surface that the wall is frozen on stale data (review R2): a
    // security wall that "looks live but isn't" is the dangerous failure mode.
    statusPollFailStreak += 1;
    if (statusPollFailStreak >= 3) setConnLostBanner(true);
    return;
  } finally {
    statusPollInFlight = false;
  }

  const byId = cams ? new Map(cams.map(c => [c.id, c])) : null;
  // Track which cameras (ALL of them, not just the displayed ones) have recent
  // motion — drives motion-mode carousels, which may switch TO an off-screen cam.
  if (cams) {
    liveMotionCams = new Set(cams.filter(c => c.recent_motion).map(c => c.id));
    const seenTs = Date.now();
    for (const id of liveMotionCams) camLastMotionTs.set(id, seenTs);
    carouselMotionTick();
    hotspotMotionTick();
  }
  // Refresh any live detection-feed tiles (does its own throttled /events fetch).
  void updateEventTiles();
  strips.forEach(strip => {
    const camId = strip.dataset.cam;
    const keys  = detMap ? detMap.get(camId) : null;
    const det   = strip.querySelector('.tsi-detections');
    const rec   = strip.querySelector('.tsi-rec');
    const mot   = strip.querySelector('.tsi-motion');

    // Specific detection icons take precedence over the generic motion runner.
    // Only rewrite when we have fresh data (detMap non-null); on a failed
    // detection fetch leave the last glyphs rather than clearing them (R2).
    // Diff the icon-key set before re-parsing HTML — usually unchanged tick to
    // tick, so this skips the innerHTML parse most of the time (S5).
    if (det && detMap) {
      const keyStr = keys ? [...keys].join(',') : '';
      if (strip.dataset.detkeys !== keyStr) {
        det.innerHTML = keys ? [...keys].map(detectionIconHtml).join('') : '';
        strip.dataset.detkeys = keyStr;
      }
    }
    if (mot) mot.classList.toggle('active', !!(byId?.get(camId)?.recent_motion) && !(keys && keys.size));
    if (rec && byId) rec.classList.toggle('active', !!byId.get(camId)?.recording);
  });

  // HUD per-tile decode-health dots are driven by the 1 s HUD sampler (hudTick,
  // running whenever the live wall is up) — no separate pane_stats poll here (J3).
}

// ── HUD: per-tile decode-health badge ─────────────────────────────────────────
// Always-on passive health from mpv telemetry (pane_stats). Green = decoding on
// hardware, keeping up; amber = software/CPU decode of a hi-res stream OR decode
// fps lagging the source; red = actively dropping frames. The tooltip carries
// the numbers. The aggregate footer HUD + benchmark layer on top later.
const LS_HUD = 'crumb_hud_on';
const HUD_TREND_MAX = 150; // ring-buffer length for sparklines + CSV (~2.5 min @1s)
const hudPrev = new Map(); // slot → { total: cumulative drops, t: ms }
const hudState = {
  on: (() => { try { return localStorage.getItem(LS_HUD) === '1'; } catch { return false; } })(),
  pollTimer: null,
  prevHost: null,          // { cpu: cpu_time_secs, t } for CPU%-from-delta
  trend: [],               // [{ t, cpu, gpuDec, drops, decFps, net }]
  lastPanes: {},
  lastAgg: null,
  dpsBySlot: {},
  lastDropsPerSec: 0,
  benchRunning: false,
};
const hudSleep = ms => new Promise(r => setTimeout(r, ms));

/** Update the per-tile decode-health dot + accumulate per-slot drops/sec. */
function hudUpdateBadges(stats) {
  if (!stats) return;
  const now = performance.now();
  let totalDps = 0;
  const bySlot = {};
  for (const [paneId, s] of Object.entries(stats)) {
    const slot = paneIdToSlot(paneId);
    if (slot == null) continue;
    const total = (s.drop_count || 0) + (s.dec_drop_count || 0);
    const prev = hudPrev.get(slot);
    let dps = 0;
    if (prev && now > prev.t) dps = Math.max(0, (total - prev.total) / ((now - prev.t) / 1000));
    hudPrev.set(slot, { total, t: now });
    bySlot[slot] = dps;
    totalDps += dps;

    const dot = document.querySelector(`#tile-grid .tile[data-slot="${slot}"] .tsi-perf`);
    if (!dot) continue;
    const h = s.height || 0;
    const res = h ? `${h}p` : '—';
    const hw = !!(s.hwdec && s.hwdec !== 'no');
    const fps = s.decode_fps || 0, cfps = s.container_fps || 0;
    const mbps = (s.video_bitrate || 0) / 1e6;
    let cls = 'ok';
    if (dps >= 1) cls = 'bad';
    else if (!hw && h >= 1080) cls = 'warn';
    else if (cfps > 0 && fps > 0 && fps < cfps * 0.7) cls = 'warn';
    // Skip the DOM writes when nothing changed — the health class is steady most
    // ticks, and writing className/title forces style work every second (S3).
    const nextClass = `tsi-perf ${cls}`;
    if (dot.className !== nextClass) dot.className = nextClass;
    const nextTitle =
      `${res} · ${fps.toFixed(0)}/${cfps.toFixed(0)} fps · ${hw ? s.hwdec : 'CPU decode'}` +
      (mbps > 0 ? ` · ${mbps.toFixed(1)} Mbps` : '') +
      (dps >= 1 ? ` · ${dps.toFixed(0)} drops/s` : '');
    if (dot.title !== nextTitle) dot.title = nextTitle;
  }
  hudState.dpsBySlot = bySlot;
  hudState.lastDropsPerSec = totalDps;
}

/** Aggregate the per-pane telemetry into wall totals. */
function hudComputeAgg(panes) {
  let streams = 0, decFps = 0, cFps = 0, netBits = 0;
  for (const s of Object.values(panes)) {
    if ((s.width || 0) > 0 || (s.decode_fps || 0) > 0) streams++;
    decFps += s.decode_fps || 0;
    cFps += s.container_fps || 0;
    netBits += s.video_bitrate || 0;
  }
  return { streams, decFps, cFps, netMbps: netBits / 1e6, dropsPerSec: hudState.lastDropsPerSec || 0 };
}

/** Client CPU% (of the whole machine) from the cumulative CPU-time delta. */
function hudCpuPct(host) {
  if (!host) return null;
  const now = performance.now();
  const prev = hudState.prevHost;
  hudState.prevHost = { cpu: host.cpu_time_secs, t: now };
  if (!prev || now <= prev.t) return null;
  const dCpu = host.cpu_time_secs - prev.cpu;
  const dWall = (now - prev.t) / 1000;
  return Math.max(0, Math.min(100, (dCpu / dWall) * 100 / (host.num_cpus || 1)));
}

function hudPushTrend(agg, cpuPct, host) {
  hudState.trend.push({
    t: Date.now(),
    cpu: cpuPct ?? 0,
    gpuDec: host?.gpu_dec_util ?? null,
    drops: agg.dropsPerSec,
    decFps: agg.decFps,
    net: agg.netMbps,
  });
  if (hudState.trend.length > HUD_TREND_MAX) hudState.trend.shift();
}

/** One sample: read mpv + host telemetry, update badges, footer, trend, diag. */
async function hudTick() {
  if (hudState.benchRunning) return; // the benchmark drives its own sampling
  let panes = {}, host = null;
  try { [panes, host] = await Promise.all([invoke('pane_stats'), invoke('host_stats')]); }
  catch { return; }
  hudUpdateBadges(panes);
  if (Object.keys(panes).length) hudState.lastPanes = panes; // keep last live snapshot for the Diagnostics view
  const agg = hudComputeAgg(panes);
  const cpuPct = hudCpuPct(host);
  hudState.lastAgg = { ...agg, cpuPct, host };
  if (agg.streams > 0) hudState.lastLiveAgg = hudState.lastAgg; // snapshot for the Diagnostics view
  updateStatusAlert(agg, cpuPct, host); // status-bar perf alert (works even with F8 off)
  hudPushTrend(agg, cpuPct, host);
  if (hudState.on) hudRenderFooter(agg, cpuPct, host);
  if (srvState.section === 'diag' && els.viewServer && !els.viewServer.classList.contains('hidden')) hudRenderDiag();
}

function hudShouldRun() {
  const live = els.viewLive && !els.viewLive.classList.contains('hidden');
  const diag = els.viewServer && !els.viewServer.classList.contains('hidden') && srvState.section === 'diag';
  return live || diag;
}
function hudStart() {
  if (hudState.pollTimer) return;
  // Adaptive cadence (review S3): 1s while the HUD/Diagnostics is visible or a
  // pane is dropping frames; relax to 2.5s when steady. CPU% derives from
  // wall-time deltas and the trend buffer is timestamped, so both stay correct
  // at any interval. (Self-scheduling setTimeout, not a fixed setInterval.)
  const tick = async () => {
    if (hudShouldRun()) await hudTick();
    const busy = hudState.on
      || (els.viewServer && !els.viewServer.classList.contains('hidden') && srvState.section === 'diag')
      || (hudState.lastDropsPerSec || 0) >= 1;
    hudState.pollTimer = setTimeout(tick, busy ? 1000 : 2500);
  };
  hudState.pollTimer = setTimeout(tick, 1000);
}
function hudStop() {
  if (hudState.pollTimer) { clearTimeout(hudState.pollTimer); hudState.pollTimer = null; }
}

/** F8 (or the Diagnostics toggle): show/hide the aggregate footer; the native
 *  panes re-inset above it via scheduleSync (body.hud-on shrinks the grid). */
function hudToggle(on) {
  hudState.on = (on == null) ? !hudState.on : !!on;
  const f = document.getElementById('hud-footer');
  if (f) f.classList.toggle('hidden', !hudState.on);
  document.body.classList.toggle('hud-on', hudState.on);
  try { localStorage.setItem(LS_HUD, hudState.on ? '1' : '0'); } catch { /* quota */ }
  hudStart();
  scheduleSync(); // re-inset the native panes for the new grid height
  if (hudState.on && hudState.lastAgg) hudRenderFooter(hudState.lastAgg, hudState.lastAgg.cpuPct, hudState.lastAgg.host);
}

function hudSpark(vals, color) {
  const v = vals.filter(x => x != null);
  if (v.length < 2) return '<svg width="50" height="14" aria-hidden="true"></svg>';
  const max = Math.max(1, ...v), n = v.length;
  const pts = v.map((x, i) => `${(i / (n - 1) * 48 + 1).toFixed(1)},${(13 - (x / max) * 12).toFixed(1)}`).join(' ');
  return `<svg width="50" height="14" viewBox="0 0 50 14" aria-hidden="true"><polyline points="${pts}" fill="none" stroke="${color}" stroke-width="1.2"/></svg>`;
}

function hudRenderFooter(agg, cpuPct, host) {
  const el = document.getElementById('hud-footer');
  if (!el || el.classList.contains('hidden')) return;
  const m = (l, v, cls) => `<div class="hud-metric"><div class="hud-l">${l}</div><div class="hud-v ${cls || ''}">${v}</div></div>`;
  const u = s => `<span class="hud-u">${s}</span>`;
  const gpu = host?.gpu_util, gdec = host?.gpu_dec_util;
  el.innerHTML =
    m('Streams', String(agg.streams)) +
    m('Decode', `${Math.round(agg.decFps)}${u(`/${Math.round(agg.cFps)} fps`)}`) +
    m('Drops', `${agg.dropsPerSec.toFixed(1)}${u('/s')}`, agg.dropsPerSec >= 1 ? 'bad' : '') +
    m('CPU', cpuPct == null ? '—' : `${Math.round(cpuPct)}${u('%')}`) +
    m('RAM', host ? srvFmtMem(host.mem_mb) : '—') +
    m('GPU', gpu == null ? '—' : `${Math.round(gpu)}${u('%')}`) +
    m('GPU decode', gdec == null ? '—' : `${Math.round(gdec)}${u('%')}`, gdec >= 90 ? 'bad' : '') +
    m('Network', `${agg.netMbps.toFixed(0)}${u(' Mbps')}`) +
    `<div class="hud-metric hud-sparks"><div class="hud-l">cpu · drops · gpu</div><div class="hud-sparkrow">${
      hudSpark(hudState.trend.map(p => p.cpu), '#3fb950')}${
      hudSpark(hudState.trend.map(p => p.drops), '#f0635c')}${
      hudSpark(hudState.trend.map(p => p.gpuDec), '#e0a92c')}</div></div>`;
}

/** Per-pane diagnostics table (Settings → Diagnostics). */
function hudRenderDiag() {
  const el = document.getElementById('srv-diag-rows');
  if (!el) return;
  const panes = hudState.lastPanes || {};
  // Decode telemetry only exists for cameras with an ACTIVE mpv pane (i.e. on the
  // current wall view). Index it by camera id so we can attach it to the full list.
  const statsByCam = new Map();
  for (const [paneId, s] of Object.entries(panes)) {
    const slot = paneIdToSlot(paneId);
    const camId = slot != null ? state.slotMap.get(slot) : null;
    if (camId) statsByCam.set(camId, { s, slot });
  }
  // Row per CONFIGURED camera (not just on-wall ones) so the list is complete —
  // off-wall cameras show "not on wall" since the desktop only decodes what it shows.
  const allCams = (srvState.allCameras && srvState.allCameras.length)
    ? srvState.allCameras : (state.cameras || []);
  const rows = allCams.slice().sort((a, b) => a.name.localeCompare(b.name)).map(cam => {
    const hit = statsByCam.get(cam.id);
    if (!hit) return { name: cam.name, live: false };
    const s = hit.s;
    const hw = (s.hwdec && s.hwdec !== 'no') ? s.hwdec : 'CPU';
    return {
      name: cam.name, live: true,
      res: s.height ? `${s.height}p` : '—',
      fps: s.decode_fps || 0, cfps: s.container_fps || 0,
      dps: hudState.dpsBySlot[hit.slot] || 0,
      hw, mbps: (s.video_bitrate || 0) / 1e6,
    };
  });
  const aggEl = document.getElementById('srv-diag-agg');
  const a = hudState.lastLiveAgg;
  if (aggEl) aggEl.textContent = a
    ? `${a.streams} streams · ${Math.round(a.decFps)} fps · ${a.dropsPerSec.toFixed(1)} drops/s`
    : '';
  if (!rows.length) { el.innerHTML = '<div class="srv-loading">No cameras configured.</div>'; return; }
  const head = '<div class="srv-stats-head"><span>Camera</span><span class="srv-stats-num">Res</span>' +
    '<span class="srv-stats-num">FPS</span><span class="srv-stats-num">Drops/s</span>' +
    '<span class="srv-stats-num">Decode</span><span class="srv-stats-num">Mbps</span></div>';
  el.innerHTML = head + rows.map(r => {
    if (!r.live) {
      return '<div class="srv-stats-row" style="opacity:.6">' +
        `<span class="srv-stats-name" title="${escHtml(r.name)}">${escHtml(r.name)}</span>` +
        '<span class="srv-stats-num">—</span>' +
        '<span class="srv-stats-num">—</span>' +
        '<span class="srv-stats-num">—</span>' +
        '<span class="srv-stats-num">not on wall</span>' +
        '<span class="srv-stats-num">—</span>' +
        '</div>';
    }
    return '<div class="srv-stats-row">' +
      `<span class="srv-stats-name" title="${escHtml(r.name)}">${escHtml(r.name)}</span>` +
      `<span class="srv-stats-num">${r.res}</span>` +
      `<span class="srv-stats-num${r.cfps > 0 && r.fps < r.cfps * 0.7 ? ' bad' : ''}">${r.fps.toFixed(0)}/${r.cfps.toFixed(0)}</span>` +
      `<span class="srv-stats-num${r.dps >= 1 ? ' bad' : ''}">${r.dps.toFixed(1)}</span>` +
      `<span class="srv-stats-num${r.hw === 'CPU' ? ' bad' : ''}">${escHtml(r.hw)}</span>` +
      `<span class="srv-stats-num">${r.mbps.toFixed(1)}</span>` +
      '</div>';
  }).join('');
}

/** Stress test: force every wall tile to its full-res MAIN stream for ~12 s and
 *  report the decode load — the "how many 4K can this box take" benchmark. */
async function hudRunBenchmark() {
  if (hudState.benchRunning) return;
  if (!els.viewLive || els.viewLive.classList.contains('hidden')) {
    await activateTab('live'); // the stress test needs the live wall
    await hudSleep(900);
  }
  if (!els.viewLive || els.viewLive.classList.contains('hidden')) {
    hudBenchStatus('Could not open the Live wall.');
    return;
  }
  hudState.benchRunning = true;
  document.getElementById('srv-bench-report')?.classList.add('hidden');
  const restoreSub = options.liveWallSub;
  const samples = [];
  const sampleOnce = async () => {
    let panes = {}, host = null;
    try { [panes, host] = await Promise.all([invoke('pane_stats'), invoke('host_stats')]); } catch { return; }
    hudUpdateBadges(panes);
    const agg = hudComputeAgg(panes);
    samples.push({ ...agg, cpu: hudCpuPct(host) || 0, gpuDec: host?.gpu_dec_util ?? null });
  };
  try {
    options.liveWallSub = false; saveOptions();
    if (!els.viewLive.classList.contains('hidden')) syncPanes();
    hudBenchStatus('Switching the wall to full-res main streams…');
    await hudSleep(4500); // let the main streams connect + a keyframe land
    for (let i = 0; i < 12; i++) {
      await hudSleep(1000);
      await sampleOnce();
      hudBenchStatus(`Measuring full-res load… ${i + 1}/12`);
    }
  } finally {
    options.liveWallSub = restoreSub; saveOptions();
    if (!els.viewLive.classList.contains('hidden')) syncPanes();
    hudState.benchRunning = false;
  }
  if (!samples.length) { hudBenchStatus('No samples captured.'); return; }
  const avg = a => a.reduce((s, x) => s + x, 0) / a.length;
  const peak = a => Math.max(...a);
  const streams = samples[samples.length - 1].streams;
  const peakDrops = peak(samples.map(s => s.dropsPerSec));
  const avgDec = avg(samples.map(s => s.decFps)), avgTgt = avg(samples.map(s => s.cFps));
  const ratio = avgTgt > 0 ? avgDec / avgTgt : 1;
  const peakCpu = peak(samples.map(s => s.cpu));
  const gpuVals = samples.map(s => s.gpuDec).filter(x => x != null);
  const peakGpu = gpuVals.length ? peak(gpuVals) : null;
  const verdict = (peakDrops < 1 && ratio > 0.95) ? ['Sustained cleanly', 'ok']
    : (peakDrops < 5 ? ['Minor drops under load', 'warn'] : ['Overloaded — dropping frames', 'bad']);
  hudBenchStatus('');
  hudBenchReport({ streams, peakDrops, ratio, peakCpu, peakGpu, verdict });
  setStatus(`Benchmark: ${verdict[0]} — ${streams}×full-res, peak ${peakDrops.toFixed(1)} drops/s. See Settings → Diagnostics.`);
}
function hudBenchStatus(msg) { const el = document.getElementById('srv-bench-status'); if (el) el.textContent = msg; if (msg) setStatus(msg); }
function hudBenchReport(r) {
  const el = document.getElementById('srv-bench-report');
  if (!el) return;
  const kv = (k, v, cls) => `<div class="srv-kv"><span class="srv-kv-k">${k}</span><span class="srv-kv-v ${cls || ''}">${v}</span></div>`;
  el.innerHTML =
    `<div class="hud-verdict ${r.verdict[1]}">${escHtml(r.verdict[0])} — ${r.streams} × full-res streams</div>` +
    kv('Peak drops', `${r.peakDrops.toFixed(1)}/s`, r.peakDrops >= 1 ? 'bad' : '') +
    kv('Decode vs source', `${Math.round(r.ratio * 100)}%`, r.ratio < 0.95 ? 'bad' : '') +
    kv('Peak client CPU', `${Math.round(r.peakCpu)}%`) +
    kv('Peak GPU decode', r.peakGpu == null ? '—' : `${Math.round(r.peakGpu)}%`, (r.peakGpu ?? 0) >= 90 ? 'bad' : '');
  el.classList.remove('hidden');
}

function liveStatusStart() {
  liveStatusStop();
  void liveStatusPoll();
  liveStatusTimer = setInterval(() => { void liveStatusPoll(); void liveStallWatchdog(); }, 3000);
  // Performance HUD: start the fast sampler + reflect the persisted footer state
  // on the (re)entered live wall (re-insetting the panes above it).
  hudStart();
  document.getElementById('hud-footer')?.classList.toggle('hidden', !hudState.on);
  document.body.classList.toggle('hud-on', hudState.on);
  if (hudState.on) scheduleSync();
}
function liveStatusStop() {
  if (liveStatusTimer !== null) { clearInterval(liveStatusTimer); liveStatusTimer = null; }
  liveProgressPrev = {};
  liveStallState = {};
  // Clear any leftover "Reconnecting…" strip badges.
  document.querySelectorAll('#tile-grid .tile-strip.reconnecting').forEach(s => s.classList.remove('reconnecting'));
}

// ── Live stall watchdog ───────────────────────────────────────────────────────
// A libmpv pane can freeze on the last frame if its RTSP feed drops (server still
// recording, only the client stalled). Sample each pane's playback position; a
// live pane whose time-pos hasn't advanced for ~2 polls (~6 s) is stalled.
//
// Reconnect with EXPONENTIAL BACKOFF rather than every cycle: the first reconnect
// fires after the stall is confirmed, then subsequent attempts wait 1s,2s,4s,8s…
// capped at ~15 s and ~max attempts — so a transient drop recovers fast but a
// truly-down camera isn't hammered. Per-pane counters reset the instant time-pos
// advances again (recovery). The watchdog runs on the ~3 s live poll, so the
// backoff is tracked in wall-clock ms (Date.now) and checked each tick.
const STALL_POLLS_TO_CONFIRM = 2;    // ~6 s of no progress (valid pos not advancing) = stalled
const NOPOS_POLLS_TO_CONFIRM = 4;    // ~12 s with NO decodable position = wedged probe → reload
const RECONNECT_BASE_MS      = 1000; // first backoff after the confirming reload
const RECONNECT_MAX_MS       = 15000;// cap of the exponential phase
const RECONNECT_FAST_ATTEMPTS = 8;   // attempts at exponential backoff before slowing
const RECONNECT_SLOW_MS      = 60000;// after the fast phase: keep retrying ~every 60 s (NEVER give up)
const MAX_RELOADS_PER_TICK   = 3;    // herd cap: a fleet-wide blip can't fire N reconnects at once
let liveProgressPrev = {};
// Per-pane: { stallPolls, attempts, nextAt, noPosPolls } — nextAt is the wall-clock
// ms at which the next reconnect is allowed (0 = reconnect allowed now).
let liveStallState = {};

/** Issue a watchdog reconnect for a stalled/wedged pane, honoring per-pane backoff,
 *  a per-tick herd cap (jittered deferral when exceeded), and a NEVER-give-up slow
 *  retry after the fast phase. Returns true if a reload was actually issued. */
function tryReconnectPane(id, st, now, budget) {
  if (st.nextAt !== 0 && now < st.nextAt) return false;        // backoff not elapsed
  if (budget.used >= MAX_RELOADS_PER_TICK) {                   // herd cap → defer with jitter
    st.nextAt = now + 200 + Math.floor(Math.random() * 1500);
    return false;
  }
  console.warn(`live pane stalled, reconnecting ${id} (attempt ${st.attempts + 1})`);
  setPaneReconnecting(id, true);
  // R1: if the Rust reload fails (mpv re-init error), the pane is dropped from the
  // map and would otherwise stay black forever — a full re-sync recreates it.
  invoke('reload_pane', { id }).catch(() => { scheduleSync(); });
  st.attempts += 1;
  budget.used += 1;
  const base = st.attempts <= RECONNECT_FAST_ATTEMPTS
    ? Math.min(RECONNECT_BASE_MS * (2 ** (st.attempts - 1)), RECONNECT_MAX_MS)
    : RECONNECT_SLOW_MS;
  // Jitter so a fleet-wide outage doesn't resync into a reconnect herd.
  st.nextAt = now + base + Math.floor(Math.random() * 1000);
  return true;
}

async function liveStallWatchdog() {
  if (!els.viewLive || els.viewLive.classList.contains('hidden') || modalOpen > 0) return;
  let prog;
  try { prog = await invoke('live_pane_progress'); } catch { return; }
  const now = Date.now();
  const next = {};
  const budget = { used: 0 }; // R3: cap reconnects this tick so a shared blip doesn't herd
  for (const id of Object.keys(prog)) {
    const t = prog[id];
    next[id] = t;
    const prev = liveProgressPrev[id];
    const st = liveStallState[id] || (liveStallState[id] = { stallPolls: 0, attempts: 0, nextAt: 0, noPosPolls: 0 });

    // R2: no decodable position. Either still probing/connecting (normal, brief) OR
    // wedged at the RTSP probe (half-open port: TCP up, no media — never produces a
    // valid time-pos, so the advance-based stall check below can NEVER catch it).
    // Count consecutive no-position polls; once a fresh connect has clearly had time
    // to work, force a reconnect so the tile can't sit black forever with no badge.
    if (t < 0) {
      st.noPosPolls = (st.noPosPolls || 0) + 1;
      if (st.noPosPolls >= NOPOS_POLLS_TO_CONFIRM && tryReconnectPane(id, st, now, budget)) {
        st.noPosPolls = 0; // give the fresh instance time to connect before counting again
      }
      continue;
    }

    // First good frame after probing/reconnecting → recovered.
    if (prev !== undefined && prev < 0) {
      if (st.attempts > 0 || st.stallPolls > 0) setPaneReconnecting(id, false);
      st.stallPolls = 0; st.attempts = 0; st.nextAt = 0; st.noPosPolls = 0;
      continue;
    }
    // Recovery: time-pos advanced → clear stall + backoff state and the badge.
    if (prev !== undefined && Math.abs(t - prev) >= 0.05) {
      if (st.attempts > 0 || st.stallPolls > 0) setPaneReconnecting(id, false);
      st.stallPolls = 0; st.attempts = 0; st.nextAt = 0; st.noPosPolls = 0;
      continue;
    }

    // Stalled = had a valid position last poll and it didn't advance since.
    const stalled = prev !== undefined && Math.abs(t - prev) < 0.05;
    if (!stalled) continue;

    st.stallPolls += 1;
    if (st.stallPolls < STALL_POLLS_TO_CONFIRM) continue;
    tryReconnectPane(id, st, now, budget); // R3/R4: herd-capped, never-give-up
  }
  liveProgressPrev = next;
}

/** Toggle a subtle "Reconnecting…" state on the tile strip for pane `slotN`.
 *  The strip is DOM (above the native pane) and is keyed by camera id, so we map
 *  the slot index → camera id → strip. No-op if the strip isn't present. */
function setPaneReconnecting(paneId, on) {
  const m = /^slot(\d+)$/.exec(paneId);
  if (!m) return;
  const slot = parseInt(m[1], 10);
  const camId = (state.maximized !== null && state.maximized.slotIndex === slot)
    ? state.maximized.cameraId
    : state.slotMap.get(slot);
  if (!camId) return;
  const strip = document.querySelector(`#tile-grid .tile-strip[data-cam="${camId}"]`);
  if (strip) strip.classList.toggle('reconnecting', on);
}

// ── Live-tab reconnect with "Connecting…" placeholders ────────────────────────
// Returning to Live REUSES the existing native panes (sync_panes loadfiles the
// live URL into each), but a fresh RTSP open goes BLACK until its first keyframe —
// staggered across cameras, that's the "windows fill in one at a time" cascade.
// To kill it WITHOUT keeping the wall decoding in the background, we hide each
// reused pane, show a DOM "Connecting…" placeholder on its tile, let it reconnect
// hidden, and reveal it the instant its live stream produces a frame. A hard
// reveal-all fallback (3 s) bounds the worst case to the previous behaviour.
let liveRevealPoll = null;

/** Toggle the "Connecting…" placeholder on the tile that owns pane `paneId`. */
function setTileConnecting(paneId, on) {
  const slot = paneIdToSlot(paneId);
  if (slot === null) return;
  const tile = getTileEl(slot);
  if (tile) tile.classList.toggle('connecting', on);
}

/** Hide the panes currently on screen (those about to be reconnected) so they
 *  reconnect behind a placeholder instead of flashing black. Returns their ids
 *  (empty on first launch, when no panes exist yet — nothing to placeholder). */
async function liveBeginReconnect() {
  let ids = [];
  try { ids = Object.keys(await invoke('live_pane_progress')); } catch { return []; }
  if (!ids.length) return [];
  try { await invoke('set_panes_hidden', { hidden: true, ids }); } catch { return []; }
  return ids;
}

/** Reveal each hidden pane as soon as its live stream advances past the stale
 *  position it held before the loadfile (i.e. its first live frame decoded).
 *  Reveal-all fallback after 3 s so a pane is never left hidden. */
async function liveRevealOnFirstFrame(ids) {
  if (liveRevealPoll) { clearInterval(liveRevealPoll); liveRevealPoll = null; }
  const pending = new Set(ids);
  const baseline = {};
  try {
    const p = await invoke('live_pane_progress');
    for (const id of ids) baseline[id] = (typeof p[id] === 'number') ? p[id] : -1;
  } catch { for (const id of ids) baseline[id] = -1; }

  const reveal = (id) => {
    pending.delete(id);
    setTileConnecting(id, false);
    invoke('set_panes_hidden', { hidden: false, ids: [id] }).catch(() => {});
  };
  const started = performance.now();
  liveRevealPoll = setInterval(async () => {
    // Left the Live tab mid-reconnect → reveal whatever's left and stop.
    if (!els.viewLive || els.viewLive.classList.contains('hidden')) {
      for (const id of [...pending]) reveal(id);
      clearInterval(liveRevealPoll); liveRevealPoll = null;
      return;
    }
    let prog; try { prog = await invoke('live_pane_progress'); } catch { return; }
    for (const id of [...pending]) {
      const t = prog[id];
      if (typeof t === 'number' && t > 0.02 && Math.abs(t - (baseline[id] ?? -1)) > 0.02) reveal(id);
    }
    if (!pending.size || performance.now() - started > 3000) {
      for (const id of [...pending]) reveal(id); // fallback: never leave a pane hidden
      clearInterval(liveRevealPoll); liveRevealPoll = null;
    }
  }, 150);
}

// ── Tile interaction ──────────────────────────────────────────────────────────

function selectSlot(slotIndex, { routeHotspot = true } = {}) {
  state.selectedSlot = slotIndex;
  // Update selected class without full rebuild
  document.querySelectorAll('.tile').forEach(t => {
    const s = parseInt(t.dataset.slot, 10);
    t.classList.toggle('selected', s === slotIndex);
  });
  // Audio follows the selected camera (only routes when audio is ON).
  reconcileAudio();
  // routeHotspotClick re-targets a hotspot tile + rebuilds the grid — that's a
  // LEFT-click "select" behavior. Skip it for right-click (open-menu), which
  // otherwise switched the on-screen camera (esp. on a maximized PTZ tile).
  if (routeHotspot) routeHotspotClick(slotIndex);
  ptzRefresh();
}

/** If the view has a hotspot tile, clicking a camera elsewhere shows it large in the
 *  hotspot (the classic commercial-VMS monitoring-wall behaviour). No-op otherwise. */
function routeHotspotClick(slotIndex) {
  const clickSlots = [], autoSlots = [];
  for (const [s, sp] of state.slotItems) {
    if (sp.type !== 'hotspot') continue;
    if (Array.isArray(sp.cameras) && sp.cameras.length) autoSlots.push(s); else clickSlots.push(s);
  }
  if ((!clickSlots.length && !autoSlots.length) || clickSlots.includes(slotIndex) || autoSlots.includes(slotIndex)) return;
  const cam = state.slotMap.get(slotIndex);
  if (!cam) return;
  let changed = false;
  // Classic click-hotspots share one global target.
  if (clickSlots.length && cam !== state.hotspotCam) {
    state.hotspotCam = cam;
    clickSlots.forEach(s => state.slotMap.set(s, cam));
    changed = true;
  }
  // Auto-hotspots: a manual click overrides motion-follow temporarily; the dwell timer
  // holds the clicked camera, then motion-follow resumes.
  for (const s of autoSlots) {
    const st = hotspotAuto.get(s) || {};
    st.cam = cam; st.lastSwitchTs = Date.now(); st.pinned = true;
    hotspotAuto.set(s, st);
    if (state.slotMap.get(s) !== cam) { state.slotMap.set(s, cam); changed = true; }
  }
  if (changed) buildTileGrid();
}

function handleTileDoubleClick(slotIndex) {
  if (state.maximized !== null) {
    // Restore from maximize — panes are recreated muted.
    clearTimeout(maximizedMainCheckTimer);
    state.maximized = null;
    audioSlot = null; // old pane is being destroyed/rebuilt
    buildTileGrid();
    buildCameraList();
    // Re-apply audio to the active (selected) slot once panes are rebuilt.
    reapplyAudioAfterRebuild();
  } else {
    // Maximize this slot if it has a camera
    const cameraId = state.slotMap.get(slotIndex);
    if (!cameraId) return; // empty tile — nothing to maximize
    state.maximized = { slotIndex, cameraId };
    buildTileGrid();
    scheduleMaximizedMainCheck(cameraId, slotIndex); // fall back to sub if main is black
    // The maximized pane is the new active slot — re-apply audio once it exists.
    reapplyAudioAfterRebuild();
  }
  ptzRefresh();
}

// ── Maximize → main-stream fallback ───────────────────────────────────────────
// Maximizing switches a tile to the camera's MAIN stream. If that main yields no
// frame within a few seconds (dead/contended main — e.g. an LPR whose main channel
// is held by another consumer), revert to the working SUB so the operator sees the
// camera instead of a black maximized pane, and remember it for the session.
let maximizedMainCheckTimer = null;
function scheduleMaximizedMainCheck(camId, slotIndex) {
  clearTimeout(maximizedMainCheckTimer);
  if (options.maximizeMain === false) return;   // not using main on maximize
  if (mainUnavailable.has(camId)) return;        // already known-bad → already on sub
  const s = state.streams.get(camId);
  if (!s || !s.rtsp_sub_url || !s.rtsp_main_url) return; // no distinct sub to fall back to
  maximizedMainCheckTimer = setTimeout(async () => {
    if (!state.maximized || state.maximized.cameraId !== camId) return; // moved on
    let stats = {};
    try { stats = await invoke('pane_stats'); } catch { return; }
    const st = stats[`slot${slotIndex}`];
    const decoding = st && ((st.width || 0) > 0 || (st.decode_fps || 0) > 0);
    if (decoding) return; // main came up fine — nothing to do
    // Main produced no frame → fall back to the sub for this camera.
    mainUnavailable.add(camId);
    const name = camById(camId)?.name || 'Camera';
    setStatus(`${name}: main stream unavailable — showing sub`);
    if (state.maximized && state.maximized.cameraId === camId) syncPanes(); // re-resolves to sub
  }, 6000);
}

// ── Live audio: follow-the-selection + speaker toggle ─────────────────────────
// Panes are muted by default (Rust). When audio is ON, exactly ONE pane is
// audible — the ACTIVE slot (maximized slot if maximized, else the selected
// slot). Selecting another camera moves audio to it; the speaker button / M
// toggle audio ON/OFF for the currently-active camera.
//   audioOn   = master enable (persists across selection changes)
//   audioSlot = the slot whose pane is CURRENTLY unmuted (null = none)
let audioOn = false;
let audioSlot = null;

/** The slot that should be audible right now: maximized wins, else selected. */
function activeAudioSlot() {
  if (state.maximized !== null) return state.maximized.slotIndex;
  return state.selectedSlot;
}

/** Does this slot currently have a playable pane (camera + resolved stream)? */
function slotHasAudio(slot) {
  if (state.maximized !== null) return state.maximized.slotIndex === slot;
  const camId = state.slotMap.get(slot);
  if (!camId) return false;
  const s = state.streams.get(camId);
  return !!(s?.rtsp_main_url ?? s?.rtsp_sub_url);
}

async function setPaneAudio(slot, on) {
  try {
    await invoke('set_pane_muted', { id: `slot${slot}`, muted: !on });
  } catch (e) {
    /* pane may not exist yet (still being created) */
  }
}

/**
 * Enforce the invariant: when audioOn, exactly the ACTIVE slot is unmuted and
 * every other pane muted; when off, nothing is audible. Mutes the prior audible
 * pane before unmuting the new one so there is never overlap.
 *
 * SERIALIZED via a promise chain: reconcile awaits real IPC (set_pane_muted), so
 * two fast selections must not interleave (which could leave two panes unmuted).
 * Each call queues behind the previous and re-reads the target when it runs.
 */
// Re-apply audio after a pane rebuild. The pane is created asynchronously by the
// scheduled sync, so a single fixed delay can miss on a cold/many-tile box
// (review R6). reconcileAudio is idempotent (re-reads current state, serialized
// via reconcileChain), so two attempts straddling the expected pane-ready window
// land audio on the right pane without plumbing a pane-created signal through.
function reapplyAudioAfterRebuild() {
  setTimeout(reconcileAudio, 350);
  setTimeout(reconcileAudio, 1100);
}

let reconcileChain = Promise.resolve();
function reconcileAudio() {
  reconcileChain = reconcileChain.then(_reconcileAudioImpl, _reconcileAudioImpl);
  return reconcileChain;
}
async function _reconcileAudioImpl() {
  const target = (audioOn && slotHasAudio(activeAudioSlot())) ? activeAudioSlot() : null;
  if (audioSlot === target) { updateAudioButton(); return; }
  if (audioSlot !== null) await setPaneAudio(audioSlot, false);
  if (target !== null) await setPaneAudio(target, true);
  audioSlot = target;
  updateAudioButton();
}

/** Toggle audio ON/OFF for the active (maximized, else selected) camera. */
async function toggleActiveAudio() {
  const slot = activeAudioSlot();
  if (!slotHasAudio(slot)) {
    setStatus('No camera in the selected tile');
    return;
  }
  audioOn = !audioOn;
  await reconcileAudio();
  setStatus(audioOn ? 'Audio on — selected camera' : 'Audio muted');
}

function updateAudioButton() {
  const btn = document.getElementById('audio-toggle-btn');
  if (!btn) return;
  btn.textContent = audioOn ? '🔊' : '🔇';
  btn.classList.toggle('audio-on', audioOn);
  btn.title = audioOn
    ? 'Audio on (M to mute) — follows selected camera'
    : 'Audio off (M to unmute selected camera)';
}

function assignCameraToSelectedSlot(cameraId) {
  if (state.maximized !== null) return; // can't assign while maximized

  // If this camera is already somewhere on the wall, remove it first
  // (the commercial VMS moves cameras, doesn't duplicate)
  state.slotMap.forEach((id, slot) => {
    if (id === cameraId) state.slotMap.delete(slot);
  });

  const layout = getLayout();
  const slot = state.selectedSlot < layout.tiles ? state.selectedSlot : 0;
  carouselStop(slot);
  state.slotItems.delete(slot); // a directly-assigned camera replaces any view-item
  state.slotMap.set(slot, cameraId);

  // Advance selected slot to next empty slot for convenience
  advanceSelectedSlot();

  buildTileGrid();
  buildCameraList();
  ptzRefresh();
  pbReflectLayoutChange();
}

function advanceSelectedSlot() {
  const layout = getLayout();
  const total = layout.tiles;
  // Find the next empty slot after current
  for (let delta = 1; delta <= total; delta++) {
    const next = (state.selectedSlot + delta) % total;
    if (!state.slotMap.has(next)) {
      state.selectedSlot = next;
      return;
    }
  }
  // All full — stay on current
}

// ── Layout activation ─────────────────────────────────────────────────────────

async function activateLayout(layoutId) {
  clearAllCarousels();
  state.slotItems.clear(); // built-in presets are plain camera grids — drop view-items
  state.hotspotCam = null;
  if (state.maximized !== null) {
    state.maximized = null;
  }
  state.layoutId = layoutId;
  state.customLayout = null; // switching to a preset drops any custom geometry
  state.currentViewId = null;

  // Rebuild preset buttons to reflect active state
  buildLayoutPresets();

  // Re-fill slots: keep existing assignments where slots still exist,
  // then auto-fill remaining slots with unassigned cameras in order.
  const layout = LAYOUTS.find(l => l.id === layoutId);
  const newCount = layout.tiles;

  // Drop assignments beyond the new tile count
  const toRemove = [];
  state.slotMap.forEach((_, slot) => { if (slot >= newCount) toRemove.push(slot); });
  toRemove.forEach(s => state.slotMap.delete(s));

  // Auto-fill empty slots
  autoFillSlots();

  // Clamp selected slot
  if (state.selectedSlot >= newCount) state.selectedSlot = 0;

  buildTileGrid();
  buildCameraList();
  ptzRefresh();            // auto-fill may have changed the selected slot's camera
  pbReflectLayoutChange();
  setStatus(`Layout changed to ${layout.label}`);
}

/**
 * Fill empty tile slots with cameras that aren't currently on the wall,
 * in the order they appear in state.cameras.
 */
function autoFillSlots() {
  const layout = getLayout();
  const assignedCams = new Set(state.slotMap.values());
  const unassigned = state.cameras.filter(c => !assignedCams.has(c.id));
  let ui = 0;
  for (let i = 0; i < layout.tiles && ui < unassigned.length; i++) {
    if (!state.slotMap.has(i)) {
      state.slotMap.set(i, unassigned[ui++].id);
    }
  }
}

// ── Tab switching ─────────────────────────────────────────────────────────────

async function activateTab(tabId) {
  // Capability guard: non-admin users cannot activate tabs their role disallows.
  if (!state.isAdmin && state.caps) {
    if (tabId === 'playback' && !state.caps.playback) return;
    if (tabId === 'clips'    && !state.caps.clips)    return;
    if (tabId === 'export'   && !state.caps.export)   return;
  }
  document.querySelectorAll('.tab').forEach(t => {
    t.classList.toggle('active', t.dataset.tab === tabId);
  });
  // Re-skin the whole UI to the cool "review" palette while in Playback so the
  // mode is unmistakable (not just the tile outline) — see body.mode-playback.
  document.body.classList.toggle('mode-playback', tabId === 'playback');
  els.viewExport?.classList.add('hidden'); // the Export view is shown only by its own branch below
  els.viewClips?.classList.add('hidden'); // ditto — the Clips view is shown only by its own branch

  const toolbar = document.getElementById('toolbar');

  const ptzBtn = document.getElementById('toolbar-ptz-btn');

  if (tabId !== 'playback') pbRestoreInjectedSlot(); // undo any detection-peek injection on leaving playback

  if (tabId === 'live') {
    const wasOnLive = !els.viewLive.classList.contains('hidden');
    els.viewLive.classList.remove('hidden');
    els.viewPlayback.classList.add('hidden');
    els.viewServer.classList.add('hidden');
    toolbar.classList.remove('hidden');
    if (ptzBtn) ptzBtn.classList.remove('hidden'); // PTZ is live-only
    pbStopTick();
    srvStopRefresh();
    // Hide the reused panes BEFORE rebuilding the grid so they reconnect behind a
    // "Connecting…" placeholder instead of black-cascading one-by-one. ONLY when
    // coming from another tab — re-clicking Live while already on it (esp. maximized)
    // must NOT reconnect, or the reveal cascade over the maximized stack looks like
    // "scrolling through cameras".
    const reconnectIds = wasOnLive ? [] : await liveBeginReconnect();
    buildTileGrid();
    for (const id of reconnectIds) setTileConnecting(id, true);
    ptzRefresh();
    liveStatusStart(); // drive the title-strip REC / motion indicators
    if (reconnectIds.length) liveRevealOnFirstFrame(reconnectIds);
  } else if (tabId === 'server') {
    els.viewLive.classList.add('hidden');
    els.viewPlayback.classList.add('hidden');
    els.viewServer.classList.remove('hidden');
    toolbar.classList.add('hidden');
    liveStatusStop();
    clearAllCarousels();
    await clearAllPanes();
    pbStopTick();
    // Hide PTZ panel
    ptzCameraId = null;
    ptzPanelSetVisible(false);
    await srvEnter();
  } else if (tabId === 'export') {
    // Export is now a real persistent VIEW (not a modal overlay).
    els.viewLive.classList.add('hidden');
    els.viewPlayback.classList.add('hidden');
    els.viewServer.classList.add('hidden');
    els.viewExport.classList.remove('hidden');
    toolbar.classList.add('hidden');
    liveStatusStop();
    clearAllCarousels();
    await clearAllPanes();
    pbStopTick();
    srvStopRefresh();
    ptzCameraId = null;
    ptzPanelSetVisible(false);
    if (ptzBtn) ptzBtn.classList.add('hidden');
    exportEnter();
  } else if (tabId === 'clips') {
    els.viewLive.classList.add('hidden');
    els.viewPlayback.classList.add('hidden');
    els.viewServer.classList.add('hidden');
    els.viewClips?.classList.remove('hidden');
    toolbar.classList.add('hidden');
    if (ptzBtn) ptzBtn.classList.add('hidden');
    liveStatusStop();
    clearAllCarousels();
    await clearAllPanes();
    pbStopTick();
    srvStopRefresh();
    ptzCameraId = null;
    ptzPanelSetVisible(false);
    clipsEnter();
  } else {
    // Playback
    els.viewLive.classList.add('hidden');
    els.viewPlayback.classList.remove('hidden');
    els.viewServer.classList.add('hidden');
    toolbar.classList.remove('hidden');
    liveStatusStop();
    clearAllCarousels();
    await clearAllPanes();
    srvStopRefresh();
    // PTZ is live-only — hide the bar AND the toolbar toggle in Playback.
    ptzCameraId = null;
    ptzPanelSetVisible(false);
    if (ptzBtn) ptzBtn.classList.add('hidden');
    await pbEnter();
  }
}

// ── Login / logout flow ───────────────────────────────────────────────────────

function showLogin(errorMsg) {
  setCamerasFullscreen(false); // never strand the OS window in fullscreen at the login screen
  stopRecordingAlertPoll();    // clear the at-risk banner when signed out
  stopUpdateCheckPoll();       // clear the update notice when signed out (issue #7)
  bootRetryStop();             // H1: don't keep retrying a boot-time camera load once signed out
  reauthClose();               // H6: don't leave the re-auth overlay up under the login screen
  els.loginScreen.classList.remove('hidden');
  els.topbar.classList.add('hidden');
  els.appShell.classList.add('hidden');
  // The secondary toolbar (Config View / layout presets) and the bottom status
  // bar are app chrome — keep them off the login screen.
  document.getElementById('toolbar')?.classList.add('hidden');
  document.getElementById('statusbar')?.classList.add('hidden');

  if (errorMsg) {
    els.loginError.textContent = errorMsg;
    els.loginError.classList.remove('hidden');
  } else {
    els.loginError.classList.add('hidden');
  }
}

function showApp() {
  els.loginScreen.classList.add('hidden');
  els.topbar.classList.remove('hidden');
  els.appShell.classList.remove('hidden');
  document.getElementById('toolbar').classList.remove('hidden');
  document.getElementById('statusbar')?.classList.remove('hidden');

  const url = new URL(state.server);
  els.serverLabel.textContent = url.host;

  // Begin watching for disk-full / under-provisioned recording risk (every tab).
  startRecordingAlertPoll();
  // Begin the update-available poll (issue #7): checks this server's
  // /updates/latest, re-checks at most every 24h while the app runs.
  startUpdateCheckPoll();
}

// ── Cameras-only fullscreen ("camera wall") ───────────────────────────────────
// Hide ALL app chrome (top bar + toolbar) AND put the OS window in fullscreen, so
// only the camera tiles remain — filling the whole screen. Exit with Esc (or the
// same toolbar button, which reappears once chrome is restored). The native video
// panes are positioned from tile rects, so we scheduleSync() after the reflow.
let camerasFullscreen = false;
function setCamerasFullscreen(on) {
  on = !!on;
  if (on === camerasFullscreen) return;
  camerasFullscreen = on;
  document.body.classList.toggle('cameras-fullscreen', on);
  document.getElementById('toolbar-fullscreen-btn')?.classList.toggle('active', on);
  invoke('set_window_fullscreen', { on }).catch(() => {});
  // Realign native panes after the chrome show/hide reflow and the OS-fullscreen
  // resize (the window 'resize' event also fires scheduleSync, but be explicit).
  scheduleSync();
}
function toggleCamerasFullscreen() { setCamerasFullscreen(!camerasFullscreen); }

async function handleLogin(e) {
  e.preventDefault();

  const server   = els.loginServer.value.trim().replace(/\/+$/, '');
  const username = els.loginUser.value.trim();
  const password = els.loginPass.value;
  const remember = els.loginRemember ? !!els.loginRemember.checked : true;

  if (!server || !username) {
    els.loginError.textContent = 'Server URL and username are required.';
    els.loginError.classList.remove('hidden');
    return;
  }

  els.loginBtn.disabled = true;
  els.loginBtn.textContent = 'Connecting…';
  els.loginError.classList.add('hidden');

  try {
    const data = await apiLogin(server, username, password, remember);
    state.token  = data.token;
    state.server = server;
    // Always remember the server + username for prefill; only persist the TOKEN
    // (the actual session) when "Keep me signed in" is checked.
    localStorage.setItem(LS_SERVER_KEY, server);
    localStorage.setItem(LS_USER_KEY, username);
    localStorage.setItem(LS_REMEMBER_KEY, remember ? '1' : '0');
    if (remember) await saveToken(data.token);
    else localStorage.removeItem(LS_TOKEN_KEY);
    await loadCamerasAndStart();
  } catch (err) {
    els.loginError.textContent = err.message;
    els.loginError.classList.remove('hidden');
  } finally {
    els.loginBtn.disabled = false;
    els.loginBtn.textContent = 'Connect';
  }
}

// "Find my server": scan the LAN for Crumb servers via the native Rust command
// (reqwest, so no CORS). One hit auto-fills the server field; multiple → a pick
// list; none → reveal a subnet field (prefilled with this machine's /24) so the
// user can rescan a neighbouring VLAN.
let loginDiscovering = false;
async function loginDiscover(range) {
  if (loginDiscovering) return;
  loginDiscovering = true;
  const btn = (range == null) ? els.loginDiscoverBtn : els.loginSubnetBtn;
  if (btn) btn.disabled = true;
  if (els.loginDiscoverMsg) els.loginDiscoverMsg.textContent = 'Scanning…';
  if (els.loginDiscoverList) els.loginDiscoverList.innerHTML = '';
  try {
    // port:null → Rust scans its default candidate set (http:8080 + https:8443),
    // so a TLS-only or dual-exposed server is found, not just plain :8080.
    const found = await invoke('discover_servers', { port: null, range: range || null });
    if (!found || found.length === 0) {
      if (els.loginDiscoverMsg) {
        els.loginDiscoverMsg.textContent = range
          ? `No server on ${range}.`
          : 'No server on this network — try another subnet:';
      }
      els.loginSubnetRow?.classList.remove('hidden');
      if (els.loginSubnet && !els.loginSubnet.value) {
        try { const cidr = await invoke('local_subnet_cidr'); if (cidr) els.loginSubnet.value = cidr; } catch { /* ignore */ }
      }
    } else if (found.length === 1) {
      els.loginServer.value = found[0].url;
      if (els.loginDiscoverMsg) els.loginDiscoverMsg.textContent = `Found ${found[0].url}`;
      els.loginUser?.focus();
    } else {
      if (els.loginDiscoverMsg) els.loginDiscoverMsg.textContent = `Found ${found.length} servers — pick one:`;
      if (els.loginDiscoverList) {
        els.loginDiscoverList.innerHTML = found.map(s =>
          `<button type="button" class="btn btn-ghost btn-sm login-found" data-url="${escHtml(s.url)}" style="display:block;width:100%;text-align:left;margin-top:4px">${escHtml(s.url)}${s.version ? ' · v' + escHtml(s.version) : ''}</button>`
        ).join('');
        els.loginDiscoverList.querySelectorAll('.login-found').forEach(b => {
          b.addEventListener('click', () => {
            els.loginServer.value = b.dataset.url;
            els.loginDiscoverList.innerHTML = '';
            if (els.loginDiscoverMsg) els.loginDiscoverMsg.textContent = `Using ${b.dataset.url}`;
            els.loginUser?.focus();
          });
        });
      }
    }
  } catch (e) {
    if (els.loginDiscoverMsg) els.loginDiscoverMsg.textContent = 'Scan failed: ' + (e?.message || e);
  } finally {
    loginDiscovering = false;
    if (btn) btn.disabled = false;
  }
}

async function handleSignOut() {
  liveStatusStop();
  hudStop();          // J1: stop the 1 s telemetry sampler (no live wall after sign-out)
  stopClockTicker();  // J1: stop the shared clock-tile ticker
  clearAllCarousels();
  ctxClose();
  await clearAllPanes();
  state.token    = null;
  state.cameras  = [];
  state.cameraById = new Map();
  state.streams.clear();
  state.slotMap.clear();
  state.maximized  = null;
  state.caps       = null;
  state.isAdmin    = false;
  state.username   = '';
  // Drop only the session token; keep server + username so the login form
  // prefills for an easy re-sign-in.
  localStorage.removeItem(LS_TOKEN_KEY);
  document.getElementById('toolbar').classList.add('hidden');
  ptzPanelSetVisible(false);
  showLogin();
  setStatus('Signed out.');
}

/** On launch (after views load): open to the user's ★ default view if one is set
 *  and still exists, then enter the fullscreen camera wall if that option is on. */
function applyLaunchPreferences() {
  const def = getDefaultView();
  if (def === '__all__') {
    applyAllCamerasView();
  } else if (def && viewsCache.some(v => v.id === def)) {
    applyView(def);
  } else {
    if (def) { try { localStorage.removeItem(LS_DEFAULT_VIEW); } catch { /* gone */ } } // stale id → clear
    // No (valid) launch view set: open to a DEFINED, highlighted view rather than an
    // unselected auto-grid — prefer the first saved view, else All Cameras.
    const first = orderedViews()[0];
    if (first) applyView(first.id);
    else if (options.showAllCamerasView !== false && state.cameras.length) applyAllCamerasView();
  }
  if (options.launchFullscreen) setCamerasFullscreen(true);
}

// ── Post-login: load cameras + streams ───────────────────────────────────────

// Boot-retry state for a server that's unreachable at launch (H1): rather than
// dying on the first failed /cameras fetch and leaving a blank wall with no
// poll loop running, show a visible retry control and keep retrying on a capped
// exponential backoff until the server answers (or the user signs out).
const BOOT_RETRY_BASE_MS = 2000;
const BOOT_RETRY_MAX_MS = 30000;
let bootRetryTimer = null;
let bootRetryAttempt = 0;

function bootRetryStop() {
  if (bootRetryTimer !== null) { clearTimeout(bootRetryTimer); bootRetryTimer = null; }
  bootRetryAttempt = 0;
}

/** Render a visible "couldn't load cameras" state with a Retry button, in place
 *  of the tile grid, and schedule an automatic retry on a capped backoff. */
function showBootRetry(message) {
  buildTileGrid(); // clears any stale tiles/panes-adjacent DOM first
  const grid = els.tileGrid;
  if (grid) {
    grid.innerHTML = `
      <div class="tile-empty-hint boot-retry">
        <span class="tile-empty-text">${escHtml(message)}</span>
        <button id="boot-retry-btn" type="button" class="btn btn-ghost btn-sm" style="margin-top:10px">Retry now</button>
      </div>`;
    document.getElementById('boot-retry-btn')?.addEventListener('click', () => {
      bootRetryStop();
      void loadCamerasAndStart();
    });
  }
  setStatus(message);

  bootRetryAttempt++;
  const delay = Math.min(BOOT_RETRY_MAX_MS, BOOT_RETRY_BASE_MS * 2 ** (bootRetryAttempt - 1));
  bootRetryTimer = setTimeout(() => { bootRetryTimer = null; void loadCamerasAndStart(); }, delay);
}

async function loadCamerasAndStart() {
  setStatus('Loading cameras…');
  showApp();
  buildLayoutPresets();
  // Fetch /auth/me early so capability gating is applied before cameras render.
  await fetchAndApplyMe();

  let cameras;
  try {
    cameras = await apiFetchCameras();
  } catch (err) {
    if (err.isForbidden) {
      // Should not happen with the viewer-safe /cameras endpoint, but handle gracefully.
      buildTileGrid();
      setStatus('403 — access denied for camera list');
      return;
    }
    // Any other failure (network etc.) — don't dead-end the wall: show a visible
    // Retry control and keep retrying on a backoff (H1) instead of returning
    // with liveStatusStart() never called and nothing re-polling.
    showBootRetry(`Camera load failed: ${err.message} — retrying…`);
    return;
  }

  // A previous attempt may have left a retry timer armed; this load succeeded.
  bootRetryStop();
  state.cameras = cameras;
  state.cameraById = new Map(cameras.map(c => [c.id, c])); // id→camera index (S7)
  setStatus(`${cameras.length} camera${cameras.length !== 1 ? 's' : ''} — resolving streams…`);

  // Pre-resolve streams for all cameras in parallel; tolerate individual failures.
  const streamResults = await Promise.allSettled(
    cameras.map(cam => apiFetchStreams(cam.id))
  );
  streamResults.forEach((result, idx) => {
    const cam = cameras[idx];
    if (result.status === 'fulfilled') {
      state.streams.set(cam.id, result.value);
    } else {
      console.warn(`Stream resolve failed for ${cam.name}:`, result.reason);
      // Leave the camera in the list but with no stream — tile shows "no stream"
    }
  });

  // Default to a layout that shows EVERY camera. Pick the tightest grid whose
  // tiles cover the camera count: cols = ceil(√n), rows = ceil(n/cols). Use a
  // named square preset when it matches exactly (1×1/2×2/3×3/4×4), otherwise a
  // custom grid — so e.g. 11 cameras fill a 4×3 wall instead of a sparse 4×4.
  const camCount = Math.max(1, cameras.length);
  const fitCols = Math.min(VS_MAX, Math.ceil(Math.sqrt(camCount)));
  const fitRows = Math.min(VS_MAX, Math.ceil(camCount / fitCols));
  const squarePreset = fitCols === fitRows
    ? ({ 1: '1x1', 2: '2x2', 3: '3x3', 4: '4x4' })[fitCols]
    : null;
  if (squarePreset) {
    state.layoutId = squarePreset;
    state.customLayout = null;
  } else {
    state.layoutId = 'custom';
    state.customLayout = { cols: fitCols, rows: fitRows, cells: vsUnitCells(fitCols, fitRows) };
  }

  // Auto-fill tile slots in camera list order
  state.slotMap.clear();
  autoFillSlots();
  state.selectedSlot = 0;

  buildLayoutPresets();
  buildCameraList();
  buildTileGrid();
  // Status will be updated by syncPanes after the grid is built

  // Fetch + render saved views from the API, THEN honour the user's launch
  // preferences (the ★ default view + the launch-in-fullscreen option) — they
  // need the views loaded to resolve a saved-view id. Also kick off the
  // one-time localStorage→server icon migration in the background — it's
  // best-effort and must not delay getting the wall on screen.
  refreshViews().then(() => {
    applyLaunchPreferences();
    migrateLocalViewIconsToServer();
  });

  // Evaluate PTZ for the initially selected slot
  ptzRefresh();

  // Start the live status poll (REC / motion title-strip indicators)
  liveStatusStart();
}

// ── Keyboard shortcuts ────────────────────────────────────────────────────────

// ── Camera number hotkeys ─────────────────────────────────────────────────────
// Press a digit (1–9, 0 = 10) to "go to" that camera; Shift+digit covers 11–20.
// Context-aware: on the Live wall it MAXIMIZES the camera (press again / Esc to
// restore); on Playback it LOADS that camera's timeline. Assignments auto-follow
// camera order but can be remapped in Settings → This Computer (persisted in
// `options.hotkeys` as { token: cameraId }; empty ⇒ pure auto).

const HOTKEY_TOKENS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0',
  's1', 's2', 's3', 's4', 's5', 's6', 's7', 's8', 's9', 's0'];
/** Human label for a token: "1".."0" plain, "⇧1".."⇧0" shifted. */
function hotkeyLabel(token) { return token.startsWith('s') ? '⇧' + token.slice(1) : token; }
/** A keydown → token ("3", "s3"), or null. Plain digit or Shift+digit only;
 *  uses e.code so Shift+1 ("!") still resolves to digit 1. */
function hotkeyTokenFromEvent(e) {
  if (e.ctrlKey || e.altKey || e.metaKey) return null;
  const m = /^Digit(\d)$/.exec(e.code || '');
  if (!m) return null;
  return (e.shiftKey ? 's' : '') + m[1];
}
/** Auto assignment by camera order: token[i] → cameras[i].id (first 20). */
function hotkeysAuto() {
  const map = {};
  state.cameras.slice(0, HOTKEY_TOKENS.length).forEach((c, i) => { map[HOTKEY_TOKENS[i]] = c.id; });
  return map;
}
/** Configured token→camId map (saved override if any, else auto) — IGNORES the
 *  enabled toggle, for the Settings remap UI which always shows/edits the map. */
function hotkeysConfigured() {
  const custom = options.hotkeys && Object.keys(options.hotkeys).length ? options.hotkeys : null;
  return custom || hotkeysAuto();
}
/** EFFECTIVE map for LIVE use — empty when hotkeys are disabled, which suppresses
 *  BOTH the keydown handler and the tile number badges in one place. */
function hotkeysEffective() {
  return options.hotkeysEnabled === false ? {} : hotkeysConfigured();
}
/** Reverse lookup camId → token (for the camera-list badge), or null. */
function hotkeyForCamera(camId) {
  const map = hotkeysEffective();
  return Object.keys(map).find(tok => map[tok] === camId) || null;
}
/** Resolve a token to a live camera id (must still exist), or null. */
function cameraForHotkey(token) {
  const id = hotkeysEffective()[token];
  return id && state.cameras.some(c => c.id === id) ? id : null;
}

/** "Go to" a camera: Playback → load its timeline; otherwise → maximize on Live. */
function hotkeyGoToCamera(camId) {
  if (els.viewPlayback && !els.viewPlayback.classList.contains('hidden')) {
    const ts = Number.isFinite(pbState.playheadMs) ? pbState.playheadMs : Date.now();
    void goToPlaybackEvent(camId, ts);
  } else {
    void focusLiveCameraMaximized(camId);
  }
}

/** Maximize a specific camera on the Live wall (toggle off if already maximized). */
async function focusLiveCameraMaximized(camId) {
  if (!els.viewLive || els.viewLive.classList.contains('hidden')) await activateTab('live');
  if (state.maximized && state.maximized.cameraId === camId) {
    clearTimeout(maximizedMainCheckTimer);
    state.maximized = null; audioSlot = null;
    buildTileGrid(); buildCameraList();
    reapplyAudioAfterRebuild(); ptzRefresh();
    return;
  }
  const entry = [...state.slotMap.entries()].find(([, c]) => c === camId);
  let slotIndex;
  if (entry) {
    slotIndex = entry[0];
  } else {
    // Camera isn't on the current wall. Prefer an EMPTY slot so the maximized
    // pane is fresh + self-consistent: borrowing a FILLED slot left its slotMap
    // pointing at a DIFFERENT camera, so the video showed this camera while
    // right-click/ctx resolved the borrowed slot's original occupant (and reusing
    // that slot's pane url could flash/stay black). Fall back to selected / 0.
    const layout = getLayout();
    let empty = null;
    for (let i = 0; i < layout.tiles; i++) { if (!state.slotMap.has(i)) { empty = i; break; } }
    slotIndex = empty !== null ? empty : (Number.isInteger(state.selectedSlot) ? state.selectedSlot : 0);
  }
  state.maximized = { slotIndex, cameraId: camId };
  buildTileGrid(); buildCameraList();
  scheduleMaximizedMainCheck(camId, slotIndex); // fall back to sub if main is black
  reapplyAudioAfterRebuild(); ptzRefresh();
}

function handleKeyDown(e) {
  // Ignore if focus is in an input element
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;

  // F8: toggle the live performance HUD footer.
  if (e.key === 'F8') { e.preventDefault(); hudToggle(); return; }

  // Esc: leave the fullscreen camera wall first (before un-maximizing).
  if (e.key === 'Escape' && camerasFullscreen) {
    setCamerasFullscreen(false);
    return;
  }

  // Esc: exit maximize (mirror handleTileDoubleClick's restore so audio +
  // selection are reconciled — panes are recreated muted on restore).
  if (e.key === 'Escape' && state.maximized !== null) {
    state.maximized = null;
    audioSlot = null;
    buildTileGrid();
    buildCameraList();
    reapplyAudioAfterRebuild();
    ptzRefresh();
    return;
  }

  // S: snapshot the active pane to a file
  if (e.key === 's' || e.key === 'S') {
    snapshotActivePane();
    return;
  }

  // M: toggle audio for the active camera
  if (e.key === 'm' || e.key === 'M') {
    toggleActiveAudio();
    return;
  }

  // Number keys: "go to" the assigned camera (1–9, 0 = 10; Shift+digit = 11–20).
  // Context-aware (Live → maximize, Playback → load). Remappable in Settings.
  const hkToken = hotkeyTokenFromEvent(e);
  if (hkToken) {
    const camId = cameraForHotkey(hkToken);
    if (camId) { e.preventDefault(); hotkeyGoToCamera(camId); }
    return;
  }
}

/** Snapshot the active pane (maximized tile, else the selected slot) → file. */
async function snapshotActivePane() {
  const slot = state.maximized ? state.maximized.slotIndex : state.selectedSlot;
  try {
    const path = await invoke('snapshot_pane', { id: `slot${slot}` });
    const name = String(path).split(/[\\/]/).pop();
    showToast({
      icon: '📸',
      title: 'Snapshot saved',
      detail: name,
      detailTitle: `${path}\nClick to show in folder`,
      onDetail: () => invoke('reveal_path', { path }).catch(() => setStatus('Could not open the location.')),
    });
    setStatus(`Snapshot saved → ${path}`);
  } catch (e) {
    showToast({ icon: '⚠', title: 'Snapshot failed', detail: String(e), timeoutMs: 8000 });
    setStatus(`Snapshot failed: ${e}`);
  }
}

// ── Toasts ──────────────────────────────────────────────────────────────────
// Small auto-dismissing notifications pinned to the TOP-RIGHT header zone. That
// band (top bar + toolbar) has no native video panes over it, so a DOM toast is
// always visible there — a toast over the tile grid would hide behind the panes.
function getToastHost() {
  let host = document.getElementById('toast-host');
  if (!host) { host = document.createElement('div'); host.id = 'toast-host'; document.body.appendChild(host); }
  return host;
}
/** showToast({icon?, title, detail?, detailTitle?, onDetail?, timeoutMs?}) → element. */
function showToast({ icon, title, detail, detailTitle, onDetail, timeoutMs = 6000 }) {
  const host = getToastHost();
  const el = document.createElement('div');
  el.className = 'toast';
  let timer = null;
  const close = () => { clearTimeout(timer); el.classList.remove('toast-in'); el.classList.add('toast-out'); setTimeout(() => el.remove(), 200); };
  const arm = () => { timer = setTimeout(close, timeoutMs); };

  const head = document.createElement('div');
  head.className = 'toast-head';
  const ttl = document.createElement('span');
  ttl.className = 'toast-title';
  ttl.textContent = (icon ? `${icon} ` : '') + title;
  const x = document.createElement('button');
  x.className = 'toast-x'; x.type = 'button'; x.textContent = '×'; x.title = 'Dismiss';
  x.addEventListener('click', (e) => { e.stopPropagation(); close(); });
  head.appendChild(ttl); head.appendChild(x);
  el.appendChild(head);

  if (detail) {
    const d = document.createElement('div');
    d.className = 'toast-detail' + (onDetail ? ' toast-link' : '');
    d.textContent = detail;
    if (detailTitle) d.title = detailTitle;
    if (onDetail) d.addEventListener('click', () => { onDetail(); close(); });
    el.appendChild(d);
  }

  host.appendChild(el);
  requestAnimationFrame(() => el.classList.add('toast-in'));
  arm();
  // Pause the auto-dismiss while hovered so the link stays clickable.
  el.addEventListener('mouseenter', () => clearTimeout(timer));
  el.addEventListener('mouseleave', arm);
  return el;
}

// ── PTZ module ────────────────────────────────────────────────────────────────

/** The camera id currently bound to the PTZ controls (null = none). */
let ptzCameraId = null;

/** In-flight guard so rapid selection changes don't stack requests. */
let ptzRefreshInFlight = false;

/**
 * Return the currently "active" camera object (the one that owns the PTZ pad).
 * Maximized state wins; otherwise use the selected slot.
 */
function ptzGetActiveCamera() {
  // ptzActiveSlot() prefers a dedicated PTZ tile (so its camera owns PTZ + the wheel
  // regardless of selection), else the maximized/selected slot.
  const camId = state.slotMap.get(ptzActiveSlot());
  return camId ? (camById(camId) ?? null) : null;
}

/**
 * Fire-and-forget PTZ command to the currently active PTZ camera.
 * Silently swallows network errors — PTZ is best-effort.
 */
async function ptzCmd(body) {
  if (!ptzCameraId) return;
  try {
    await fetchWithTimeout(`${state.server}/cameras/${ptzCameraId}/ptz`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${state.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (e) {
    console.warn('ptz cmd error:', e);
  }
}

/** PTZ command to a SPECIFIC camera (the dedicated PTZ control-tile drives its own
 *  camera, independent of the focus-based ptzCameraId). */
async function ptzTileCmd(cameraId, body) {
  if (!cameraId) return;
  try {
    await fetchWithTimeout(`${state.server}/cameras/${cameraId}/ptz`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${state.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (e) { console.warn('ptz tile cmd error:', e); }
}

/** ONVIF imaging command (focus / iris) to a specific camera — best-effort. */
async function imagingTileCmd(cameraId, action) {
  if (!cameraId) return;
  try {
    await fetchWithTimeout(`${state.server}/cameras/${cameraId}/imaging`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${state.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ action }),
    });
  } catch (e) { console.warn('imaging cmd error:', e); }
}

/** Fetch a camera's ONVIF presets ([{token,name}]) for the PTZ control tile. */
async function ptzFetchPresetsFor(cameraId) {
  if (!cameraId) return [];
  try {
    const res = await fetchWithTimeout(`${state.server}/cameras/${cameraId}/ptz`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${state.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'presets' }),
    });
    if (!res.ok) return [];
    return (await res.json()).presets || [];
  } catch { return []; }
}

// 8-direction unit vectors (pan/tilt) for the PTZ control-tile d-pad.
const PTZ_DIRV = {
  n: { pan: 0, tilt: 1 }, s: { pan: 0, tilt: -1 }, e: { pan: 1, tilt: 0 }, w: { pan: -1, tilt: 0 },
  ne: { pan: 0.71, tilt: 0.71 }, nw: { pan: -0.71, tilt: 0.71 }, se: { pan: 0.71, tilt: -0.71 }, sw: { pan: -0.71, tilt: -0.71 },
};

/** Build the DOM for a dedicated PTZ control tile (d-pad + zoom + presets). */
function buildPtzPanelHtml(spec) {
  const cam = camById(spec.cameraId);
  const name = cam ? escHtml(cam.name) : 'pick a camera in Config View';
  const dirBtn = (d, glyph) => `<button class="tile-ptz-btn" data-dir="${d}">${glyph}</button>`;
  return `<div class="tile-ptz">
    <div class="tile-ptz-fit">
    <div class="tile-ptz-head"><span class="tile-ptz-ico">🕹</span><span class="tile-ptz-cam">${name}</span></div>
    <div class="tile-ptz-pad">
      ${dirBtn('nw', '↖')}${dirBtn('n', '↑')}${dirBtn('ne', '↗')}
      ${dirBtn('w', '←')}<button class="tile-ptz-btn tile-ptz-home" data-dir="home" title="Home">⌂</button>${dirBtn('e', '→')}
      ${dirBtn('sw', '↙')}${dirBtn('s', '↓')}${dirBtn('se', '↘')}
    </div>
    <div class="tile-ptz-extra">
      <button class="tile-ptz-zoom" data-zoom="out">Zoom −</button>
      <button class="tile-ptz-zoom" data-zoom="in">Zoom +</button>
      <select class="tile-ptz-presets" title="Go to a saved preset"><option value="">— preset —</option></select>
    </div>
    <div class="tile-ptz-extra tile-ptz-imaging">
      <button class="tile-ptz-zoom" data-focus="near" title="Focus nearer (hold)">Focus−</button>
      <button class="tile-ptz-zoom" data-focus="far" title="Focus farther (hold)">Focus+</button>
      <button class="tile-ptz-zoom" data-focus="auto" title="Auto-focus">AF</button>
      <button class="tile-ptz-zoom" data-iris="open" title="Open iris (brighter)">Iris+</button>
      <button class="tile-ptz-zoom" data-iris="close" title="Close iris (darker)">Iris−</button>
      <button class="tile-ptz-zoom" data-iris="auto" title="Auto iris">IrisA</button>
    </div>
    </div>
  </div>`;
}

/** Wire a PTZ control tile's buttons + presets to its camera. */
function wirePtzPanel(tile, spec) {
  const cam = spec.cameraId;

  // Scale the control column down to fit the tile so the d-pad/zoom/focus rows
  // never clip when the box is small (transform-scale keeps it crisp + centered).
  const fit = tile.querySelector('.tile-ptz-fit');
  const box = tile.querySelector('.tile-ptz');
  if (fit && box) {
    const rescale = () => {
      fit.style.transform = 'none'; // measure intrinsic size unscaled
      const availW = Math.max(1, box.clientWidth - 16);
      const availH = Math.max(1, box.clientHeight - 16);
      const cw = fit.scrollWidth, ch = fit.scrollHeight;
      if (cw > 1 && ch > 1) {
        const s = Math.min(availW / cw, availH / ch, 1);
        fit.style.transform = s < 0.999 ? `scale(${s})` : 'none';
      }
    };
    rescale();
    tile._ptzRO?.disconnect();
    tile._ptzRO = new ResizeObserver(rescale);
    tile._ptzRO.observe(box);
  }
  tile.querySelectorAll('.tile-ptz-btn[data-dir]').forEach(btn => {
    const dir = btn.dataset.dir;
    if (dir === 'home') {
      btn.addEventListener('click', (e) => { e.stopPropagation(); ptzTileCmd(cam, { action: 'home' }); });
      return;
    }
    const v = PTZ_DIRV[dir]; if (!v) return;
    const start = (e) => { e.stopPropagation(); e.preventDefault(); ptzTileCmd(cam, { action: 'move', pan: v.pan * 0.6, tilt: v.tilt * 0.6, zoom: 0 }); };
    const stop = () => ptzTileCmd(cam, { action: 'stop' });
    btn.addEventListener('pointerdown', start);
    btn.addEventListener('pointerup', stop);
    btn.addEventListener('pointerleave', stop);
    btn.addEventListener('pointercancel', stop);
  });
  tile.querySelectorAll('.tile-ptz-zoom[data-zoom]').forEach(btn => {
    const z = btn.dataset.zoom === 'in' ? 0.5 : -0.5;
    const start = (e) => { e.stopPropagation(); e.preventDefault(); ptzTileCmd(cam, { action: 'move', pan: 0, tilt: 0, zoom: z }); };
    const stop = () => ptzTileCmd(cam, { action: 'stop' });
    btn.addEventListener('pointerdown', start);
    btn.addEventListener('pointerup', stop);
    btn.addEventListener('pointerleave', stop);
  });
  // Focus: hold to drive near/far, release to stop; AF triggers continuous auto-focus.
  tile.querySelectorAll('[data-focus]').forEach(btn => {
    const f = btn.dataset.focus;
    if (f === 'auto') {
      btn.addEventListener('click', (e) => { e.stopPropagation(); imagingTileCmd(cam, 'auto_focus'); });
      return;
    }
    const action = f === 'near' ? 'focus_near' : 'focus_far';
    const start = (e) => { e.stopPropagation(); e.preventDefault(); imagingTileCmd(cam, action); };
    const stop = () => imagingTileCmd(cam, 'focus_stop');
    btn.addEventListener('pointerdown', start);
    btn.addEventListener('pointerup', stop);
    btn.addEventListener('pointerleave', stop);
    btn.addEventListener('pointercancel', stop);
  });
  // Iris: single nudge open/close, or back to auto exposure.
  tile.querySelectorAll('[data-iris]').forEach(btn => {
    const i = btn.dataset.iris;
    const action = i === 'open' ? 'iris_open' : i === 'close' ? 'iris_close' : 'iris_auto';
    btn.addEventListener('click', (e) => { e.stopPropagation(); imagingTileCmd(cam, action); });
  });

  const sel = tile.querySelector('.tile-ptz-presets');
  if (sel) {
    sel.addEventListener('click', (e) => e.stopPropagation());
    sel.addEventListener('change', (e) => {
      const t = e.target.value;
      if (t) { ptzTileCmd(cam, { action: 'preset', preset: t }); e.target.value = ''; }
    });
    ptzFetchPresetsFor(cam).then(presets => {
      presets.forEach(p => {
        const o = document.createElement('option');
        o.value = p.token;
        o.textContent = (p.name && p.name.trim()) ? p.name : `Preset ${p.token}`;
        sel.appendChild(o);
      });
    }).catch(() => {});
  }
}

// ── PTZ video-driven interaction (forwarded from the native pane) ─────────────
// The native pane eats the mouse, so click-to-center / click-to-pan and
// wheel-zoom on the video are forwarded from the Win32 WndProc as Tauri events.
// PTZ uses ONVIF ContinuousMove (open-loop velocity), so we synthesize a timed
// move pulse: velocity ∝ click offset from center, then a Stop. There is no
// position read-back, so centering is an approximation (standard for velocity PTZ).

/** Click interaction mode: 'center' (proportional recenter), 'pan' (hold-to-pan),
 *  'off' (no PTZ active). Driven by options.ptzClickMode when PTZ is shown. */
let ptzVideoMode = 'off';
let ptzPulseTimer = null;
let ptzWheelStopTimer = null;
let ptzPanActive = false; // true while a hold-to-pan (pan mode) drag is in progress

/** Active digital-zoom drag-to-pan session ({id,slot,lastX,lastY}) or null. */
let paneDragState = null;

/** Per-pane digital-zoom mirror (paneId → mpv video-zoom log2; 0 = 1×). Kept in
 *  sync from zoom_pane / zoom_pane_rect return values so a live-pane drag can
 *  choose box-zoom (at 1×) vs grab-to-pan (when already zoomed). Absent ⇒ 1×. */
const paneZoom = new Map();

/** Last camera shown in each PLAYBACK slot (slotIndex → cameraId). Lets pbSyncPanes
 *  tell a same-camera segment advance (preserve digital zoom) from a camera SWITCH
 *  (reset to full frame — e.g. a bookmark/detection jump injects a new camera). */
const pbPaneCam = new Map();

/** Active box-zoom rubber-band session {id, slot, x0, y0, x1, y1} (pane-client
 *  PHYSICAL px) or null. Only on LIVE, non-PTZ panes that are at 1×. */
let paneBox = null;

/** Draw the box-zoom rubber-band on its pane via an mpv ASS overlay (a DOM box
 *  would hide BEHIND the native pane). Coords are pane-client PHYSICAL px; the
 *  overlay res space is CSS px (like the PTZ wheel), so divide by DPR. */
function drawBoxOverlay() {
  if (!paneBox) return;
  const tile = getTileEl(paneBox.slot);
  if (!tile) return;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = r.width, h = Math.max(1, r.height - tileStripPx()); // CSS px = overlay res
  const x0 = Math.round(Math.min(paneBox.x0, paneBox.x1) / dpr);
  const y0 = Math.round(Math.min(paneBox.y0, paneBox.y1) / dpr);
  const x1 = Math.round(Math.max(paneBox.x0, paneBox.x1) / dpr);
  const y1 = Math.round(Math.max(paneBox.y0, paneBox.y1) / dpr);
  // Faint azure fill (#4C9AFF → ASS BGR &HFF9A4C&) + a 2px white border.
  const ass = `{\\an7\\pos(0,0)\\bord2\\shad0\\1c&HFF9A4C&\\1a&HC0&\\3c&HFFFFFF&\\3a&H10&\\p1}` +
    `m ${x0} ${y0} l ${x1} ${y0} l ${x1} ${y1} l ${x0} ${y1}{\\p0}`;
  invoke('set_pane_overlay', { id: paneBox.id, ass, resX: w, resY: h }).catch(() => {});
}

/** Clear any box-zoom rubber-band overlay from a pane. */
function clearBoxOverlay(id) {
  invoke('set_pane_overlay', { id, ass: '', resX: 1, resY: 1 }).catch(() => {});
}

/** The slot whose camera owns the PTZ controls (maximized wins, else selected). */
/** True when the current view has a dedicated PTZ CONTROL tile (a DOM panel). When
 *  present, the on-image PTZ wheel is suppressed everywhere — you steer from the
 *  panel instead. */
function ptzTileSlot() {
  for (const [slot, spec] of state.slotItems) if (spec.type === 'ptz') return slot;
  return null;
}
function ptzActiveSlot() {
  return state.maximized !== null ? state.maximized.slotIndex : state.selectedSlot;
}

const ptzClamp = (v) => Math.max(-1, Math.min(1, v));

/** Normalized click offset from the VIDEO center (−1..1), accounting for the
 *  title strip (the pane is inset below it, so pane height = tile height − strip). */
function ptzNormOffset(slot, xPhys, yPhys) {
  const tile = getTileEl(slot);
  if (!tile) return null;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const paneW = r.width;
  const paneH = Math.max(1, r.height - tileStripPx() - tileBottomInset(slot));
  return {
    nx: ptzClamp(((xPhys / dpr) - paneW / 2) / (paneW / 2)),
    ny: ptzClamp(((yPhys / dpr) - paneH / 2) / (paneH / 2)),
  };
}

/** Issue a move pulse, then auto-Stop after `ms`. Clears BOTH motion timers so a
 *  pending wheel-stop can't cut this pulse short (single motion channel). */
function ptzPulseMove(pan, tilt, ms) {
  clearTimeout(ptzPulseTimer);
  clearTimeout(ptzWheelStopTimer);
  ptzCmd({ action: 'move', pan, tilt, zoom: 0 });
  ptzPulseTimer = setTimeout(() => ptzCmd({ action: 'stop' }), ms);
}

/** Continuous PTZ move toward the click offset (NO auto-stop) — pan-mode steer.
 *  Stops on pointer release (ptzVideoStopPan). Dragging re-steers. */
function ptzVideoSteer(slot, xPhys, yPhys) {
  if (!ptzCameraId || slot !== ptzActiveSlot()) return;
  const o = ptzNormOffset(slot, xPhys, yPhys);
  if (!o) return;
  clearTimeout(ptzPulseTimer);
  clearTimeout(ptzWheelStopTimer);
  ptzPanActive = true;
  // velocity ∝ offset (further from center = faster); continuous until release.
  ptzCmd({ action: 'move', pan: ptzClamp(o.nx), tilt: ptzClamp(-o.ny), zoom: 0 });
}

/** Stop an in-progress hold-to-pan (on pointer release / capture loss). */
function ptzVideoStopPan() {
  if (!ptzPanActive) return;
  ptzPanActive = false;
  ptzCmd({ action: 'stop' });
}

/**
 * Drive PTZ from a forwarded click at pane-client PHYSICAL px (xPhys,yPhys).
 * Center mode: a proportional recenter pulse (click center ≈ no-op; edges pan
 * harder/longer). Pan mode: START a continuous move (held until release; drag to
 * steer — see the pane-drag handler).
 */
function ptzVideoClick(slot, xPhys, yPhys) {
  if (ptzVideoMode === 'off' || !ptzCameraId || slot !== ptzActiveSlot()) return;
  const o = ptzNormOffset(slot, xPhys, yPhys);
  if (!o) return;
  if (ptzVideoMode === 'pan') {
    ptzVideoSteer(slot, xPhys, yPhys); // continuous hold-to-pan; stops on release
  } else {
    const mag = Math.max(Math.abs(o.nx), Math.abs(o.ny));
    if (mag < 0.06) return; // dead-center click → ignore
    ptzPulseMove(ptzClamp(o.nx * 0.7), ptzClamp(-o.ny * 0.7), Math.round(80 + 320 * mag));
  }
}

/** Drive PTZ optical zoom from a forwarded wheel delta (debounced stop). Clears
 *  BOTH motion timers so a pending click-pulse stop can't cut the zoom short. */
function ptzVideoWheel(delta) {
  if (!ptzCameraId) return;
  clearTimeout(ptzPulseTimer);
  clearTimeout(ptzWheelStopTimer);
  ptzCmd({ action: 'move', pan: 0, tilt: 0, zoom: delta > 0 ? 0.5 : -0.5 });
  ptzWheelStopTimer = setTimeout(() => ptzCmd({ action: 'stop' }), 260);
}

// ── PTZ joystick wheel (transparent, composited ON the video via mpv OSD) ─────
// A commercial-VMS-style 8-direction wheel drawn in the active PTZ tile's
// lower-left corner. It is rendered by mpv as a translucent ASS overlay ON the
// live video (see ptzBuildAss / set_pane_overlay) — NOT a DOM element over a
// carved hole — so there is no black box and the mpv window isn't clipped (which
// fixes the slow-refresh that the window region caused). Clicks are forwarded
// from the native pane (pane-click/drag/dragend) and hit-tested with
// ptzWheelHitTest: hub = Home, a wedge = continuous ContinuousMove, release =
// Stop. Zoom is the scroll wheel (ptzVideoWheel). The geometry helpers
// (ptzWheelGeom/ptzBuildAss/ptzWheelHitTest) live further down by ptzOverlayReposition.

/** True while a PTZ control (arrow OR zoom) is held; release (pane-dragend) stops it.
 *  `ptzZoomHeld` ('in'|'out'|null) distinguishes a zoom hold from a direction hold. */
let ptzWheelActive = false;
let ptzZoomHeld = null;
/** True while a focus button (near/far) is held on the video overlay; release
 *  (pane-dragend) issues focus_stop. Iris/AF buttons fire once and don't set this. */
let ptzFocusHeld = false;

/** Clear the wheel OSD from whatever pane currently has it (e.g. on leaving live
 *  — the same slot pane is reused for playback, so the overlay would linger). */
function ptzClearOsd() {
  if (ptzOsdPaneId) {
    invoke('set_pane_overlay', { id: ptzOsdPaneId, ass: '', resX: 1, resY: 1 }).catch(() => {});
    ptzOsdPaneId = null;
  }
}

/** Wire the toolbar PTZ controls (Home button + presets dropdown). The wheel
 *  (direction) + scroll-to-zoom live on the video itself. */
function wirePtzWheel() {
  document.getElementById('ptzo-presets')?.addEventListener('change', (e) => {
    const token = e.target.value;
    if (token) { ptzCmd({ action: 'preset', preset: token }); e.target.value = ''; }
  });
  document.getElementById('ptz-home-btn')?.addEventListener('click', () => ptzCmd({ action: 'home' }));

  // PTZ imaging (focus / iris) toolbar controls — drive the active PTZ camera
  // (ptzCameraId, read at click time). Focus is hold-to-drive; iris/AF are taps.
  {
    const imgCmd = (action) => imagingTileCmd(ptzCameraId, action);
    const holdFocus = (id, action) => {
      const btn = document.getElementById(id);
      if (!btn) return;
      const start = (e) => { e.preventDefault(); imgCmd(action); };
      const stop = () => imgCmd('focus_stop');
      btn.addEventListener('pointerdown', start);
      btn.addEventListener('pointerup', stop);
      btn.addEventListener('pointerleave', stop);
      btn.addEventListener('pointercancel', stop);
    };
    holdFocus('ptzimg-focus-near', 'focus_near');
    holdFocus('ptzimg-focus-far', 'focus_far');
    document.getElementById('ptzimg-af')?.addEventListener('click', () => imgCmd('auto_focus'));
    document.getElementById('ptzimg-iris-open')?.addEventListener('click', () => imgCmd('iris_open'));
    document.getElementById('ptzimg-iris-close')?.addEventListener('click', () => imgCmd('iris_close'));
    document.getElementById('ptzimg-iris-auto')?.addEventListener('click', () => imgCmd('iris_auto'));
  }
}

// ── PTZ panel show/hide helpers ───────────────────────────────────────────────

/**
 * Show or hide the PTZ right panel.
 * After toggling, scheduleSync() so the tile-grid ResizeObserver picks up
 * the new stage width and realigns native panes.
 */
function ptzPanelSetVisible(visible) {
  const wasOn = ptzVideoMode !== 'off';
  if (visible) {
    // Click behavior comes from Options (#5).
    ptzVideoMode = options.ptzClickMode === 'pan' ? 'pan' : 'center';
  } else {
    // Deactivating PTZ: always issue a Stop + clear the hold-to-pan flag. A pane
    // teardown (e.g. number-key tile select) can swallow the pane-dragend that
    // would normally stop a hold-to-pan, otherwise leaving the camera moving.
    ptzVideoStopPan();
    ptzVideoMode = 'off';
    ptzPresets = [];
    ptzPresetsListOpen = false;
  }
  ptzUpdateHint();
  const btn = document.getElementById('toolbar-ptz-btn');
  if (btn) btn.classList.toggle('active', visible);
  // Surface the Home button + preset dropdown in the toolbar while PTZ is active
  // (they're not over the video, so the native panes don't occlude them).
  document.getElementById('ptz-home-btn')?.classList.toggle('hidden', !visible);
  document.getElementById('ptzo-presets')?.classList.toggle('hidden', !visible);
  document.getElementById('ptz-imaging')?.classList.toggle('hidden', !visible);
  document.getElementById('ptz-edit-panel-btn')?.classList.toggle('hidden', !visible);
  // Leaving PTZ (or switching cameras) closes any open panel editor.
  if (!visible && ptzEditMode) ptzPanelEditEnd();
  // Toggling PTZ changes the active tile's pane inset (carves/restores the
  // overlay band) → re-sync panes, then (re)position the overlay.
  if (visible !== wasOn) scheduleSync();
  ptzOverlayReposition();
}

function ptzPanelIsVisible() {
  return ptzVideoMode !== 'off';
}

/** Is the active PTZ tile big enough to host the wheel? Tiny tiles skip it. */
function ptzWheelFitsTile(slot) {
  const tile = getTileEl(slot);
  if (!tile) return false;
  const r = tile.getBoundingClientRect();
  // ≥200 wide so the edge-style bottom row (zoom−, down arrow, Home, zoom+) doesn't
  // crowd; below this the overlay is too cramped to use anyway.
  return r.width >= 200 && (r.height - tileStripPx()) >= 160;
}

/** Geometry (pane CSS px) of every on-video PTZ control — directional arrow tabs
 *  PINNED TO THE EDGES (up/down/left/right), a centre Home, zoom +/- in the bottom
 *  corners, and a Presets pill (top-left). Shared by the ASS drawing + the click
 *  hit-test so the visible controls and clickable areas always line up. */
function ptzCtrlGeom(w, h) {
  const m = 10;
  const al = Math.round(Math.min(78, Math.max(46, w * 0.13)));  // arrow long dim
  const as = Math.round(Math.min(46, Math.max(30, h * 0.10)));  // arrow short dim
  const zs = as;
  const cx = Math.round(w / 2), cy = Math.round(h / 2);
  return {
    up:      { x: cx - al / 2, y: m,           w: al, h: as, pan: 0,  tilt: 1,  dir: 'up' },
    down:    { x: cx - al / 2, y: h - m - as,  w: al, h: as, pan: 0,  tilt: -1, dir: 'down' },
    left:    { x: m,           y: cy - al / 2, w: as, h: al, pan: -1, tilt: 0,  dir: 'left' },
    right:   { x: w - m - as,  y: cy - al / 2, w: as, h: al, pan: 1,  tilt: 0,  dir: 'right' },
    zoomOut: { x: m,                  y: h - m - zs, w: zs, h: zs },          // bottom-left
    home:    { x: w - m - zs * 2 - 6, y: h - m - zs, w: zs, h: zs },          // bottom-right, left of zoom+
    zoomIn:  { x: w - m - zs,         y: h - m - zs, w: zs, h: zs },          // bottom-right corner
    presets: { x: m, y: m, w: 92, h: 24 },
  };
}

/** ASS draw path for a filled chevron centred at (cx,cy), reach `s`, pointing `dir`. */
function ptzChevron(cx, cy, s, dir) {
  const t = Math.max(3, Math.round(s * 0.42));
  const local = [[-s, 0], [0, -s], [s, 0], [s - t, 0], [0, -s + t], [-s + t, 0]];
  const rot = (dx, dy) => dir === 'up' ? [dx, dy] : dir === 'down' ? [dx, -dy]
    : dir === 'left' ? [dy, dx] : [-dy, dx];
  let d = '';
  local.forEach(([dx, dy], i) => { const [ox, oy] = rot(dx, dy); d += `${i === 0 ? 'm' : 'l'} ${Math.round(cx + ox)} ${Math.round(cy + oy)} `; });
  return d;
}

/** Build the mpv ASS overlay (drawn ON the video): edge-pinned arrow tabs + Home
 *  (bottom-right, by zoom) + zoom +/- (bottom corners) + a Presets pill (top-left). */
function ptzBuildEdgeAss(w, h) {
  const g = ptzCtrlGeom(w, h);
  const E = [];
  const rrect = (b, alpha) => `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H101418&\\1a&H${alpha}&\\p1}` +
    `m ${Math.round(b.x)} ${Math.round(b.y)} l ${Math.round(b.x + b.w)} ${Math.round(b.y)} ` +
    `l ${Math.round(b.x + b.w)} ${Math.round(b.y + b.h)} l ${Math.round(b.x)} ${Math.round(b.y + b.h)} {\\p0}`;
  // 4 directional arrow tabs (dark backplate + a white chevron).
  ['up', 'down', 'left', 'right'].forEach(dir => {
    const b = g[dir], ccx = b.x + b.w / 2, ccy = b.y + b.h / 2;
    const reach = Math.round(Math.min(b.w, b.h) * 0.34);
    E.push(rrect(b, '3a'));
    E.push(`{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H0c&\\p1}${ptzChevron(ccx, ccy, reach, dir)}{\\p0}`);
  });
  // Centre Home (dark square + house glyph).
  {
    const b = g.home, ccx = Math.round(b.x + b.w / 2), ccy = Math.round(b.y + b.h / 2), s = Math.round(b.w * 0.24);
    const bx = Math.round(s * 0.62), yb = Math.round(ccy + s * 0.1);
    E.push(rrect(b, '46'));
    E.push(`{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H18&\\p1}` +
      `m ${ccx} ${ccy - s} l ${ccx - s} ${yb} l ${ccx + s} ${yb} ` +
      `m ${ccx - bx} ${yb} l ${ccx + bx} ${yb} l ${ccx + bx} ${ccy + s} l ${ccx - bx} ${ccy + s} {\\p0}`);
  }
  // Zoom buttons (bottom corners): − and +.
  [['zoomOut', false], ['zoomIn', true]].forEach(([key, plus]) => {
    const b = g[key], ccx = Math.round(b.x + b.w / 2), ccy = Math.round(b.y + b.h / 2);
    const hw = Math.round(b.w * 0.26), th = 2;
    E.push(rrect(b, '40'));
    let gl = `m ${ccx - hw} ${ccy - th} l ${ccx + hw} ${ccy - th} l ${ccx + hw} ${ccy + th} l ${ccx - hw} ${ccy + th} `;
    if (plus) gl += `m ${ccx - th} ${ccy - hw} l ${ccx + th} ${ccy - hw} l ${ccx + th} ${ccy + hw} l ${ccx - th} ${ccy + hw} `;
    E.push(`{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H08&\\p1}${gl}{\\p0}`);
  });
  // Presets pill (top-left) + the open list (stacking DOWN beneath it).
  if (ptzPresets.length) {
    const b = g.presets;
    E.push(rrect(b, '30'));
    E.push(`{\\an4\\pos(${Math.round(b.x + 9)},${Math.round(b.y + b.h / 2)})\\bord1\\3c&H000000&\\fs13\\1c&Hffffff&}Presets`);
    const tcx = Math.round(b.x + b.w - 13), tcy = Math.round(b.y + b.h / 2);
    E.push(`{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H10&\\p1}m ${tcx - 5} ${tcy - 2} l ${tcx + 5} ${tcy - 2} l ${tcx} ${tcy + 4} {\\p0}`);
    if (ptzPresetsListOpen) {
      ptzPresets.forEach((pr, i) => {
        const rg = ptzPresetsRowGeom(i, w, h);
        if (rg.y + rg.h > h - 2) return; // clip rows running off the bottom
        E.push(rrect(rg, '12'));
        const nm = assEscape((pr.name && pr.name.trim() ? pr.name : `Preset ${pr.token}`).slice(0, 18));
        E.push(`{\\an4\\pos(${Math.round(rg.x + 8)},${Math.round(rg.y + rg.h / 2)})\\bord1\\3c&H000000&\\fs12\\1c&Hffffff&}${nm}`);
      });
    }
  }
  return E.join('\n');
}

/** Edge-style hit-test (PHYSICAL px). Returns
 *  {kind:'dir',pan,tilt} | {kind:'zoom',dir} | {kind:'home'} | {kind:'presets'} | null. */
function ptzEdgeHit(slot, xPhys, yPhys) {
  const tile = getTileEl(slot); if (!tile) return null;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = r.width, h = r.height - tileStripPx();
  const g = ptzCtrlGeom(w, h);
  const cx = xPhys / dpr, cy = yPhys / dpr;
  const inside = b => cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h;
  if (ptzPresets.length && inside(g.presets)) return { kind: 'presets' };
  if (inside(g.home)) return { kind: 'home' };
  if (inside(g.zoomIn)) return { kind: 'zoom', dir: 'in' };
  if (inside(g.zoomOut)) return { kind: 'zoom', dir: 'out' };
  for (const d of ['up', 'down', 'left', 'right']) {
    if (inside(g[d])) return { kind: 'dir', pan: g[d].pan * 0.6, tilt: g[d].tilt * 0.6 };
  }
  return null;
}

// ── Wheel style (the original lower-left joystick wheel; selectable in Options) ──
const PTZ_W_R = 52, PTZ_W_HUB = 17, PTZ_W_MARGIN = 14;
function ptzWheelGeom(w, h) {
  // Corner-pinned per options.ptzWheelCorner (bottom-left | bottom-right | top-left | top-right).
  const corner = options.ptzWheelCorner || 'bottom-left';
  const left = !corner.includes('right');
  const top  = corner.includes('top');
  return {
    cx: left ? PTZ_W_MARGIN + PTZ_W_R : w - PTZ_W_MARGIN - PTZ_W_R,
    cy: top  ? PTZ_W_MARGIN + PTZ_W_R : h - PTZ_W_MARGIN - PTZ_W_R,
    R: PTZ_W_R, hubR: PTZ_W_HUB, left, top,
  };
}
/** Zoom button geom for the wheel style (on whichever side of the wheel has room). */
function ptzWheelZoomGeom(w, h, which) {
  const g = ptzWheelGeom(w, h), bs = 28;
  const x = g.left ? g.cx + g.R + 10 : g.cx - g.R - 10 - bs;
  return { x, y: which === 'in' ? g.cy - bs - 4 : g.cy + 4, w: bs, h: bs };
}
function ptzBuildWheelAss(w, h) {
  const g = ptzWheelGeom(w, h), rad = d => d * Math.PI / 180;
  const poly = (ccx, ccy, r) => { let d = `m ${Math.round(ccx + r)} ${Math.round(ccy)} `; for (let i = 1; i < 36; i++) { const a = rad(i * 10); d += `l ${Math.round(ccx + r * Math.cos(a))} ${Math.round(ccy + r * Math.sin(a))} `; } return d; };
  const pt = (r, ang) => `${Math.round(g.cx + r * Math.cos(rad(ang)))} ${Math.round(g.cy + r * Math.sin(rad(ang)))}`;
  const rTip = g.R - 5, rArm = g.hubR + 11, rNotch = g.hubR + 19, spread = 21;
  let arrows = '';
  [-90, -45, 0, 45, 90, 135, 180, -135].forEach(c => { arrows += `m ${pt(rTip, c)} l ${pt(rArm, c - spread)} l ${pt(rNotch, c)} l ${pt(rArm, c + spread)} `; });
  const s = Math.max(4, Math.round(g.hubR * 0.6)), bx = Math.round(s * 0.62), yb = Math.round(g.cy - s * 0.15);
  const home = `m ${g.cx} ${g.cy - s} l ${g.cx - s} ${yb} l ${g.cx + s} ${yb} m ${g.cx - bx} ${yb} l ${g.cx + bx} ${yb} l ${g.cx + bx} ${g.cy + s} l ${g.cx - bx} ${g.cy + s} `;
  const E = [
    `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H101418&\\1a&H6e&\\p1}${poly(g.cx, g.cy, g.R)}{\\p0}`,
    `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H0e&\\p1}${arrows}{\\p0}`,
    `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H2a2018&\\1a&H40&\\p1}${poly(g.cx, g.cy, g.hubR)}{\\p0}`,
    `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H18&\\p1}${home}{\\p0}`,
  ];
  const rrect = (b, a) => `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H101418&\\1a&H${a}&\\p1}m ${Math.round(b.x)} ${Math.round(b.y)} l ${Math.round(b.x + b.w)} ${Math.round(b.y)} l ${Math.round(b.x + b.w)} ${Math.round(b.y + b.h)} l ${Math.round(b.x)} ${Math.round(b.y + b.h)} {\\p0}`;
  [['zoomOut', false], ['zoomIn', true]].forEach(([key, plus]) => {
    const b = ptzWheelZoomGeom(w, h, key === 'zoomIn' ? 'in' : 'out');
    const ccx = Math.round(b.x + b.w / 2), ccy = Math.round(b.y + b.h / 2), hw = Math.round(b.w * 0.26), th = 2;
    E.push(rrect(b, '40'));
    let gl = `m ${ccx - hw} ${ccy - th} l ${ccx + hw} ${ccy - th} l ${ccx + hw} ${ccy + th} l ${ccx - hw} ${ccy + th} `;
    if (plus) gl += `m ${ccx - th} ${ccy - hw} l ${ccx + th} ${ccy - hw} l ${ccx + th} ${ccy + hw} l ${ccx - th} ${ccy + hw} `;
    E.push(`{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H08&\\p1}${gl}{\\p0}`);
  });
  // Shared top-left presets pill + list.
  if (ptzPresets.length) {
    const b = ptzCtrlGeom(w, h).presets;
    E.push(rrect(b, '30'));
    E.push(`{\\an4\\pos(${Math.round(b.x + 9)},${Math.round(b.y + b.h / 2)})\\bord1\\3c&H000000&\\fs13\\1c&Hffffff&}Presets`);
    const tcx = Math.round(b.x + b.w - 13), tcy = Math.round(b.y + b.h / 2);
    E.push(`{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H10&\\p1}m ${tcx - 5} ${tcy - 2} l ${tcx + 5} ${tcy - 2} l ${tcx} ${tcy + 4} {\\p0}`);
    if (ptzPresetsListOpen) {
      ptzPresets.forEach((pr, i) => {
        const rg = ptzPresetsRowGeom(i, w, h);
        if (rg.y + rg.h > h - 2) return;
        E.push(rrect(rg, '12'));
        const nm = assEscape((pr.name && pr.name.trim() ? pr.name : `Preset ${pr.token}`).slice(0, 18));
        E.push(`{\\an4\\pos(${Math.round(rg.x + 8)},${Math.round(rg.y + rg.h / 2)})\\bord1\\3c&H000000&\\fs12\\1c&Hffffff&}${nm}`);
      });
    }
  }
  return E.join('\n');
}
function ptzWheelHit(slot, xPhys, yPhys) {
  const tile = getTileEl(slot); if (!tile) return null;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = r.width, h = r.height - tileStripPx();
  const cx = xPhys / dpr, cy = yPhys / dpr;
  const inside = b => cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h;
  if (ptzPresets.length && inside(ptzCtrlGeom(w, h).presets)) return { kind: 'presets' };
  if (inside(ptzWheelZoomGeom(w, h, 'in'))) return { kind: 'zoom', dir: 'in' };
  if (inside(ptzWheelZoomGeom(w, h, 'out'))) return { kind: 'zoom', dir: 'out' };
  const g = ptzWheelGeom(w, h);
  const dx = cx - g.cx, dy = cy - g.cy, dist = Math.hypot(dx, dy);
  if (dist > g.R) return null;
  if (dist <= g.hubR) return { kind: 'home' };
  const idx = (((Math.round((Math.atan2(dy, dx) * 180 / Math.PI) / 45)) % 8) + 8) % 8;
  const vecs = [{ pan: 1, tilt: 0 }, { pan: 0.71, tilt: -0.71 }, { pan: 0, tilt: -1 }, { pan: -0.71, tilt: -0.71 },
    { pan: -1, tilt: 0 }, { pan: -0.71, tilt: 0.71 }, { pan: 0, tilt: 1 }, { pan: 0.71, tilt: 0.71 }];
  const v = vecs[idx];
  return { kind: 'dir', pan: v.pan * 0.6, tilt: v.tilt * 0.6 };
}

// ── On-video imaging (focus / iris) buttons ────────────────────────────────────
// A compact 3×2 grid in the TOP-RIGHT corner (free in both the edge and wheel
// styles), shared by the ASS drawing + the click hit-test. Top row = focus
// (near / AF / far), bottom row = iris (close / auto / open). Focus near/far are
// HOLD buttons (release → focus_stop); AF and the iris buttons fire once.
const PTZ_IMG_BTNS = [
  ['focus_near', 'F-'], ['auto_focus', 'AF'], ['focus_far', 'F+'],
  ['iris_close', 'I-'], ['iris_auto', 'IA'], ['iris_open', 'I+'],
];
/** Geometry (pane CSS px) of the imaging grid + whether it fits without colliding
 *  with the edge-style arrows / the corner wheel. */
function ptzImagingGeom(w, h) {
  const bw = 30, bh = 23, gap = 4, cols = 3, m = 10;
  const gw = cols * bw + (cols - 1) * gap, gh = 2 * bh + gap;
  const x0 = w - m - gw, y0 = m;
  const g = ptzCtrlGeom(w, h);
  // Clear the top-centre up-arrow and the right-edge arrow (edge style); skip when
  // the wheel itself sits in the top-right corner.
  let fits = x0 > 8 && (x0 > g.up.x + g.up.w + 6) && (y0 + gh < g.right.y - 6);
  const corner = options.ptzWheelCorner || 'bottom-left';
  if (options.ptzStyle === 'wheel' && corner.includes('top') && corner.includes('right')) fits = false;
  const cells = PTZ_IMG_BTNS.map(([action, label], i) => ({
    action, label,
    x: x0 + (i % cols) * (bw + gap),
    y: y0 + Math.floor(i / cols) * (bh + gap),
    w: bw, h: bh,
  }));
  return { cells, fits };
}
/** ASS for the imaging grid (empty string when it doesn't fit). */
function ptzBuildImagingAss(w, h) {
  const ig = ptzImagingGeom(w, h);
  if (!ig.fits) return '';
  const rrect = (b, a) => `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H101418&\\1a&H${a}&\\p1}` +
    `m ${Math.round(b.x)} ${Math.round(b.y)} l ${Math.round(b.x + b.w)} ${Math.round(b.y)} ` +
    `l ${Math.round(b.x + b.w)} ${Math.round(b.y + b.h)} l ${Math.round(b.x)} ${Math.round(b.y + b.h)} {\\p0}`;
  const out = [];
  ig.cells.forEach(b => {
    out.push(rrect(b, '40'));
    out.push(`{\\an5\\pos(${Math.round(b.x + b.w / 2)},${Math.round(b.y + b.h / 2)})\\bord1\\3c&H000000&\\fs13\\1c&Hffffff&}${b.label}`);
  });
  return out.join('\n');
}
/** Hit-test a forwarded click against the imaging grid (PHYSICAL px). */
function ptzImagingHit(slot, xPhys, yPhys) {
  const tile = getTileEl(slot); if (!tile) return null;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = r.width, h = r.height - tileStripPx();
  const ig = ptzImagingGeom(w, h);
  if (!ig.fits) return null;
  const cx = xPhys / dpr, cy = yPhys / dpr;
  for (const b of ig.cells) if (cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h) return { kind: 'imaging', action: b.action };
  return null;
}

// ── Custom PTZ control panel (commercial-VMS-style, user-placeable buttons) ─────────
// A per-camera, freely-laid-out set of ONVIF control buttons drawn ON the video
// (mpv ASS) and hit-tested like the wheel/edge styles. Layouts are stored locally
// (localStorage, keyed by camera id); when a camera has a non-empty layout it
// REPLACES the edge/wheel overlay for that camera. An "Edit panel" mode lets the
// user drag buttons from a palette onto the video and reposition / delete them.
const LS_PTZ_PANELS = 'crumb_ptz_panels';
let ptzPanels = (() => { try { return JSON.parse(localStorage.getItem(LS_PTZ_PANELS) || '{}'); } catch { return {}; } })();
function savePtzPanels() { try { localStorage.setItem(LS_PTZ_PANELS, JSON.stringify(ptzPanels)); } catch { /* quota */ } }
function ptzPanelFor(camId) { return (camId && Array.isArray(ptzPanels[camId])) ? ptzPanels[camId] : null; }

let ptzEditMode = false;   // true while customizing a panel
let ptzEditCam = null;     // camera id being edited
let ptzEditDrag = null;    // { id, slot, mode:'move'|'resize', grabOffX?, grabOffY? }
let ptzEditSel = null;     // id of the currently-selected button (shows resize/props)
let ptzSnapGuides = null;  // { vx:[px], hy:[px] } alignment guides drawn while dragging
let ptzPanelSeq = 1;       // monotonic button-id source (avoids Date.now/random)
const PTZ_SNAP_PX = 7;     // snap threshold (CSS px)
const PTZ_RESIZE_HANDLE = 16; // px size of the resize handle (selected button)

// Button kinds → fixed size (CSS px) + how to render/act. x,y in a layout are
// FRACTIONS (0..1) of the pane so positions scale with the tile.
const PTZ_PANEL_KINDS = {
  up:         { w: 46, h: 32, arrow: 'up' },
  down:       { w: 46, h: 32, arrow: 'down' },
  left:       { w: 32, h: 46, arrow: 'left' },
  right:      { w: 32, h: 46, arrow: 'right' },
  home:       { w: 44, h: 32, label: 'Home', act: { kind: 'home' } },
  zoom_in:    { w: 40, h: 32, label: 'Z+', act: { kind: 'zoom', dir: 'in' } },
  zoom_out:   { w: 40, h: 32, label: 'Z−', act: { kind: 'zoom', dir: 'out' } },
  focus_near: { w: 46, h: 30, label: 'F−', act: { kind: 'imaging', action: 'focus_near' } },
  focus_far:  { w: 46, h: 30, label: 'F+', act: { kind: 'imaging', action: 'focus_far' } },
  auto_focus: { w: 40, h: 30, label: 'AF', act: { kind: 'imaging', action: 'auto_focus' } },
  iris_open:  { w: 40, h: 30, label: 'I+', act: { kind: 'imaging', action: 'iris_open' } },
  iris_close: { w: 40, h: 30, label: 'I−', act: { kind: 'imaging', action: 'iris_close' } },
  iris_auto:  { w: 40, h: 30, label: 'IA', act: { kind: 'imaging', action: 'iris_auto' } },
  preset:     { w: 96, h: 30, label: '' },   // label from btn.name
  dpad:       { w: 120, h: 120 },            // combined 3×3 joystick
};
// Arrow direction → pan/tilt unit vector (speed factor applied at dispatch).
const PTZ_ARROW_VEC = { up: { pan: 0, tilt: 1 }, down: { pan: 0, tilt: -1 }, left: { pan: -1, tilt: 0 }, right: { pan: 1, tilt: 0 } };
// 3×3 d-pad cell → pan/tilt vector (index = row*3+col; centre [4] is Home).
const PTZ_DPAD_VEC = [
  { pan: -0.71, tilt: 0.71 }, { pan: 0, tilt: 1 }, { pan: 0.71, tilt: 0.71 },
  { pan: -1, tilt: 0 }, null, { pan: 1, tilt: 0 },
  { pan: -0.71, tilt: -0.71 }, { pan: 0, tilt: -1 }, { pan: 0.71, tilt: -0.71 },
];

const PTZ_BTN_MIN = 4, PTZ_BTN_MAX = 320; // base-size bounds (px @ scale 1); rendered = base×tileScale, floored in ptzPanelBtnRect
/** Effective (possibly user-resized) button size in px. D-pad stays square. */
function ptzBtnSize(btn) {
  const spec = PTZ_PANEL_KINDS[btn.kind] || PTZ_PANEL_KINDS.home;
  const clamp = (v, d) => Math.max(PTZ_BTN_MIN, Math.min(PTZ_BTN_MAX, Math.round(v || d)));
  const bw = clamp(btn.w, spec.w);
  const bh = btn.kind === 'dpad' ? bw : clamp(btn.h, spec.h);
  return { w: bw, h: bh };
}
/** Display label for a labelled button: custom rename wins, else preset name, else default. */
function ptzBtnLabel(btn) {
  const spec = PTZ_PANEL_KINDS[btn.kind] || {};
  return btn.label || (btn.kind === 'preset' ? (btn.name || 'Preset') : (spec.label || ''));
}
// The whole panel scales as one cluster with the tile so it looks IDENTICAL
// whether you arrange it on a big/maximized tile in the editor or view it on a
// small grid tile when closed (WYSIWYG). Button POSITIONS stay tile-fractions;
// button SIZES scale by this factor so the size-to-spacing ratio is preserved.
// Previously sizes were fixed pixels, so the cluster bunched up on a smaller tile
// and spread out with gaps on a bigger one (the "designer vs closed" mismatch).
const PTZ_PANEL_REF = 320; // tile short-side at which the base button sizes render 1:1
function ptzPanelScale(w, h) {
  return Math.max(0.5, Math.min(3, Math.min(w, h) / PTZ_PANEL_REF));
}
/** Pixel rect of a panel button within a w×h pane (scaled + clamped inside). */
function ptzPanelBtnRect(btn, w, h) {
  const base = ptzBtnSize(btn), s = ptzPanelScale(w, h);
  // Floor the RENDERED size so a button is never invisibly small on any tile,
  // while keeping the floor low enough that buttons CAN be shrunk right down.
  const bw = Math.max(8, Math.round(base.w * s)), bh = Math.max(8, Math.round(base.h * s));
  const x = Math.max(0, Math.min(Math.round(btn.x * w), w - bw));
  const y = Math.max(0, Math.min(Math.round(btn.y * h), h - bh));
  return { x, y, w: bw, h: bh };
}

/** Build the ASS for a custom panel. `edit` adds a dashed outline + a delete (✕)
 *  handle on each button and a hint when the panel is empty. */
function ptzBuildCustomAss(w, h, buttons, edit) {
  const E = [];
  const rrect = (b, a, col = '101418') => `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H${col}&\\1a&H${a}&\\p1}` +
    `m ${Math.round(b.x)} ${Math.round(b.y)} l ${Math.round(b.x + b.w)} ${Math.round(b.y)} ` +
    `l ${Math.round(b.x + b.w)} ${Math.round(b.y + b.h)} l ${Math.round(b.x)} ${Math.round(b.y + b.h)} {\\p0}`;
  const text = (cx, cy, s, fs = 13) => `{\\an5\\pos(${Math.round(cx)},${Math.round(cy)})\\bord1\\3c&H000000&\\fs${fs}\\1c&Hffffff&}${s}`;
  const glyphZoom = (b, plus) => {
    const cx = Math.round(b.x + b.w / 2), cy = Math.round(b.y + b.h / 2), hw = Math.round(b.w * 0.22), th = 2;
    let g = `m ${cx - hw} ${cy - th} l ${cx + hw} ${cy - th} l ${cx + hw} ${cy + th} l ${cx - hw} ${cy + th} `;
    if (plus) g += `m ${cx - th} ${cy - hw} l ${cx + th} ${cy - hw} l ${cx + th} ${cy + hw} l ${cx - th} ${cy + hw} `;
    return `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H08&\\p1}${g}{\\p0}`;
  };
  const glyphHome = (b) => {
    const cx = Math.round(b.x + b.w / 2), cy = Math.round(b.y + b.h / 2), s = Math.round(Math.min(b.w, b.h) * 0.26);
    const bx = Math.round(s * 0.62), yb = Math.round(cy + s * 0.1);
    return `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H10&\\p1}` +
      `m ${cx} ${cy - s} l ${cx - s} ${yb} l ${cx + s} ${yb} ` +
      `m ${cx - bx} ${yb} l ${cx + bx} ${yb} l ${cx + bx} ${cy + s} l ${cx - bx} ${cy + s} {\\p0}`;
  };
  const glyphArrow = (b, dir) => {
    const cx = b.x + b.w / 2, cy = b.y + b.h / 2, reach = Math.round(Math.min(b.w, b.h) * 0.34);
    return `{\\an7\\pos(0,0)\\bord0\\shad0\\1c&Hffffff&\\1a&H0c&\\p1}${ptzChevron(cx, cy, reach, dir)}{\\p0}`;
  };
  buttons.forEach(btn => {
    const spec = PTZ_PANEL_KINDS[btn.kind]; if (!spec) return;
    const b = ptzPanelBtnRect(btn, w, h);
    if (btn.kind === 'dpad') {
      // 3×3 joystick: backplate + 8 chevrons + centre Home.
      E.push(rrect(b, '3a'));
      const cw = b.w / 3, ch = b.h / 3;
      for (let i = 0; i < 9; i++) {
        const r = Math.floor(i / 3), c = i % 3;
        const cell = { x: b.x + c * cw, y: b.y + r * ch, w: cw, h: ch };
        if (i === 4) { E.push(glyphHome(cell)); continue; }
        const dir = r === 0 && c === 1 ? 'up' : r === 2 && c === 1 ? 'down' : c === 0 && r === 1 ? 'left'
          : c === 2 && r === 1 ? 'right' : null;
        if (dir) E.push(glyphArrow(cell, dir));
        else { // diagonal: a small dot
          E.push(`{\\an5\\pos(${Math.round(cell.x + cw / 2)},${Math.round(cell.y + ch / 2)})\\bord1\\3c&H000000&\\fs12\\1c&Hcfd8e0&}•`);
        }
      }
    } else {
      E.push(rrect(b, '40'));
      if (spec.arrow) E.push(glyphArrow(b, spec.arrow));
      else if (btn.kind === 'home') E.push(glyphHome(b));
      else if (btn.kind === 'zoom_in') E.push(glyphZoom(b, true));
      else if (btn.kind === 'zoom_out') E.push(glyphZoom(b, false));
      else { // labelled (focus/iris/preset/home/zoom with a rename)
        const lbl = assEscape(ptzBtnLabel(btn)).slice(0, 18);
        const fs = Math.max(10, Math.min(16, Math.round(b.h * 0.42)));
        E.push(text(b.x + b.w / 2, b.y + b.h / 2, lbl, fs));
      }
    }
    if (edit) {
      const selected = btn.id === ptzEditSel;
      // Selection = brighter/thicker amber outline; others = thin cyan.
      const oc = selected ? '2CA3E8' : '4CC9FF', ob = selected ? 2.4 : 1.4;
      E.push(`{\\an7\\pos(0,0)\\bord${ob}\\3c&H${oc}&\\1a&Hff&\\p1}m ${Math.round(b.x)} ${Math.round(b.y)} l ${Math.round(b.x + b.w)} ${Math.round(b.y)} l ${Math.round(b.x + b.w)} ${Math.round(b.y + b.h)} l ${Math.round(b.x)} ${Math.round(b.y + b.h)} {\\p0}`);
      // Red ✕ delete handle (top-right) on every button.
      const hx = b.x + b.w - PTZ_DEL_HANDLE, hy = b.y;
      E.push(rrect({ x: hx, y: hy, w: PTZ_DEL_HANDLE, h: PTZ_DEL_HANDLE }, '20', '2030d0'));
      E.push(text(hx + PTZ_DEL_HANDLE / 2, hy + PTZ_DEL_HANDLE / 2, '×', 13));
      // Resize handle (bottom-right) only on the selected button.
      if (selected) {
        const rx = b.x + b.w - PTZ_RESIZE_HANDLE, ry = b.y + b.h - PTZ_RESIZE_HANDLE;
        E.push(rrect({ x: rx, y: ry, w: PTZ_RESIZE_HANDLE, h: PTZ_RESIZE_HANDLE }, '18', '2CA3E8'));
        E.push(`{\\an7\\pos(0,0)\\bord0\\1c&Hffffff&\\1a&H10&\\p1}m ${Math.round(rx + 3)} ${Math.round(ry + PTZ_RESIZE_HANDLE - 3)} l ${Math.round(rx + PTZ_RESIZE_HANDLE - 3)} ${Math.round(ry + 3)} l ${Math.round(rx + PTZ_RESIZE_HANDLE - 3)} ${Math.round(ry + PTZ_RESIZE_HANDLE - 3)} {\\p0}`);
      }
    }
  });
  // Alignment guides while dragging/resizing (drawn over everything).
  if (edit && ptzSnapGuides) {
    (ptzSnapGuides.vx || []).forEach(x => E.push(`{\\an7\\pos(0,0)\\bord0\\1c&H4CC9FF&\\1a&H40&\\p1}m ${Math.round(x)} 0 l ${Math.round(x) + 1} 0 l ${Math.round(x) + 1} ${Math.round(h)} l ${Math.round(x)} ${Math.round(h)} {\\p0}`));
    (ptzSnapGuides.hy || []).forEach(y => E.push(`{\\an7\\pos(0,0)\\bord0\\1c&H4CC9FF&\\1a&H40&\\p1}m 0 ${Math.round(y)} l ${Math.round(w)} ${Math.round(y)} l ${Math.round(w)} ${Math.round(y) + 1} l 0 ${Math.round(y) + 1} {\\p0}`));
  }
  if (edit && !buttons.length) {
    E.push(`{\\an5\\pos(${Math.round(w / 2)},${Math.round(h / 2)})\\bord1\\3c&H000000&\\fs18\\1c&Hffffff&}Add controls from the bar, then drag them where you want`);
  }
  return E.join('\n');
}

const PTZ_DEL_HANDLE = 16; // px size of the ✕ delete handle in edit mode

/** Hit-test a forwarded click (PHYSICAL px) against a custom panel.
 *  Edit mode → {kind:'edit-delete'|'edit-move', id}. Normal → an action descriptor. */
function ptzCustomHit(slot, xPhys, yPhys, buttons, edit) {
  const tile = getTileEl(slot); if (!tile) return null;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = r.width, h = r.height - tileStripPx();
  const cx = xPhys / dpr, cy = yPhys / dpr;
  const inside = (b) => cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h;
  // Topmost (last drawn) wins → iterate in reverse.
  for (let i = buttons.length - 1; i >= 0; i--) {
    const btn = buttons[i];
    const b = ptzPanelBtnRect(btn, w, h);
    if (!inside(b)) continue;
    if (edit) {
      const del = { x: b.x + b.w - PTZ_DEL_HANDLE, y: b.y, w: PTZ_DEL_HANDLE, h: PTZ_DEL_HANDLE };
      if (inside(del)) return { kind: 'edit-delete', id: btn.id };
      // Resize grip (bottom-right) is live only on the already-selected button.
      if (btn.id === ptzEditSel) {
        const rz = { x: b.x + b.w - PTZ_RESIZE_HANDLE, y: b.y + b.h - PTZ_RESIZE_HANDLE, w: PTZ_RESIZE_HANDLE, h: PTZ_RESIZE_HANDLE };
        if (inside(rz)) return { kind: 'edit-resize', id: btn.id };
      }
      return { kind: 'edit-move', id: btn.id };
    }
    const spec = PTZ_PANEL_KINDS[btn.kind];
    if (btn.kind === 'dpad') {
      const c = Math.max(0, Math.min(2, Math.floor((cx - b.x) / (b.w / 3))));
      const rr = Math.max(0, Math.min(2, Math.floor((cy - b.y) / (b.h / 3))));
      const vec = PTZ_DPAD_VEC[rr * 3 + c];
      return vec ? { kind: 'dir', pan: vec.pan * 0.6, tilt: vec.tilt * 0.6 } : { kind: 'home' };
    }
    if (spec.arrow) { const v = PTZ_ARROW_VEC[spec.arrow]; return { kind: 'dir', pan: v.pan * 0.6, tilt: v.tilt * 0.6 }; }
    if (btn.kind === 'preset') return { kind: 'preset', token: btn.preset };
    if (spec.act) return { ...spec.act };
    return null;
  }
  return null;
}

/** The active panel for the focused PTZ camera, or null. Returns {buttons, edit}. */
function ptzActivePanel() {
  const editing = ptzEditMode && ptzEditCam === ptzCameraId;
  const buttons = ptzPanelFor(ptzCameraId);
  if (editing) return { buttons: buttons || (ptzPanels[ptzCameraId] = []), edit: true };
  if (buttons && buttons.length) return { buttons, edit: false };
  return null;
}

// ── Edit-mode actions (add / move / delete buttons + palette UI) ────────────────
function ptzPanelAddButton(kind, extra) {
  if (!ptzEditCam) return;
  const arr = (ptzPanels[ptzEditCam] ||= []);
  // Place each new button in its own grid slot instead of stacking every one at
  // the same spot. Stacked buttons were pixel-identical and overlapping, so you
  // could never grab the one you just added — the drag hit-test would peel off
  // whichever happened to be on top, leaving the rest behind (looked like "the
  // new button won't move"). The operator drags them wherever afterwards.
  const col = arr.length % 4;
  const row = Math.floor(arr.length / 4) % 4;
  const id = `b${ptzPanelSeq++}`;
  arr.push({ id, kind, x: 0.12 + col * 0.20, y: 0.14 + row * 0.18, ...(extra || {}) });
  ptzEditSel = id;          // select the new button so it's highlighted + obvious
  savePtzPanels();
  ptzPanelEditorRender();   // reflect the new selection in the editor list
  ptzOverlayReposition();
}
function ptzPanelDeleteButton(id) {
  if (!ptzEditCam || !Array.isArray(ptzPanels[ptzEditCam])) return;
  ptzPanels[ptzEditCam] = ptzPanels[ptzEditCam].filter(b => b.id !== id);
  if (ptzEditSel === id) ptzEditSel = null;
  savePtzPanels();
  ptzPanelEditorRender();
  ptzOverlayReposition();
}
/** Select (or clear) a button in edit mode and refresh the editor + overlay. */
function ptzPanelSelect(id) {
  if (ptzEditSel === id) return;
  ptzEditSel = id;
  ptzPanelEditorRender();
  ptzOverlayReposition();
}
/** Candidate snap lines (CSS px) from the OTHER buttons' edges/centres + the pane
 *  edges/centre. Returns { vx:[...], hy:[...] }. */
function ptzSnapLines(buttons, exceptId, w, h) {
  const vx = [0, w / 2, w], hy = [0, h / 2, h];
  buttons.forEach(o => {
    if (o.id === exceptId) return;
    const b = ptzPanelBtnRect(o, w, h);
    vx.push(b.x, b.x + b.w / 2, b.x + b.w);
    hy.push(b.y, b.y + b.h / 2, b.y + b.h);
  });
  return { vx, hy };
}
/** Snap one of `cands` (the moving button's edges along an axis) to the nearest
 *  guide line. Returns { delta, guide } (delta to add to the leading value), or
 *  { delta:0, guide:null } when nothing is within threshold. */
function ptzSnapAxis(cands, lines) {
  let best = null;
  for (const c of cands) for (const g of lines) {
    const d = g - c.at;
    if (Math.abs(d) <= PTZ_SNAP_PX && (!best || Math.abs(d) < Math.abs(best.delta))) best = { delta: d, guide: g };
  }
  return best || { delta: 0, guide: null };
}
function ptzPanelMoveButton(id, slot, xPhys, yPhys) {
  const buttons = ptzPanels[ptzEditCam]; if (!Array.isArray(buttons)) return;
  const btn = buttons.find(b => b.id === id); if (!btn) return;
  const tile = getTileEl(slot); if (!tile) return;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = r.width, h = r.height - tileStripPx();
  // Use the RENDERED (scaled) button size so snap edges align with what's drawn.
  const rr = ptzPanelBtnRect(btn, w, h);
  const sz = { w: rr.w, h: rr.h };
  let px = xPhys / dpr - (ptzEditDrag?.grabOffX ?? sz.w / 2);
  let py = yPhys / dpr - (ptzEditDrag?.grabOffY ?? sz.h / 2);
  // Snap left/centre/right & top/centre/bottom edges to nearby guides.
  const lines = ptzSnapLines(buttons, id, w, h);
  const sx = ptzSnapAxis([{ at: px }, { at: px + sz.w / 2 }, { at: px + sz.w }], lines.vx);
  const sy = ptzSnapAxis([{ at: py }, { at: py + sz.h / 2 }, { at: py + sz.h }], lines.hy);
  px += sx.delta; py += sy.delta;
  ptzSnapGuides = { vx: sx.guide != null ? [sx.guide] : [], hy: sy.guide != null ? [sy.guide] : [] };
  btn.x = Math.max(0, Math.min(1, px / w));
  btn.y = Math.max(0, Math.min(1, py / h));
  ptzOverlayReposition();
}
function ptzPanelResizeButton(id, slot, xPhys, yPhys) {
  const buttons = ptzPanels[ptzEditCam]; if (!Array.isArray(buttons)) return;
  const btn = buttons.find(b => b.id === id); if (!btn) return;
  const tile = getTileEl(slot); if (!tile) return;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = r.width, h = r.height - tileStripPx();
  const s = ptzPanelScale(w, h);
  const left = Math.round(btn.x * w), top = Math.round(btn.y * h);
  let nw = xPhys / dpr - left, nh = yPhys / dpr - top;
  // Snap the right/bottom edges to nearby guides.
  const lines = ptzSnapLines(buttons, id, w, h);
  const sx = ptzSnapAxis([{ at: left + nw }], lines.vx);
  const sy = ptzSnapAxis([{ at: top + nh }], lines.hy);
  nw += sx.delta; nh += sy.delta;
  ptzSnapGuides = { vx: sx.guide != null ? [sx.guide] : [], hy: sy.guide != null ? [sy.guide] : [] };
  // nw/nh are the desired RENDERED size; store the BASE (unscaled) size so the
  // button scales with the tile consistently with every other button.
  const clamp = v => Math.max(PTZ_BTN_MIN, Math.min(PTZ_BTN_MAX, Math.round(v / s)));
  if (btn.kind === 'dpad') { btn.w = btn.h = clamp(Math.max(nw, nh)); }
  else { btn.w = clamp(nw); btn.h = clamp(nh); }
  ptzOverlayReposition();
}
/** Nudge the selected button's size by a factor (editor bar −/+ buttons). */
function ptzPanelResizeSelected(factor) {
  const buttons = ptzPanels[ptzEditCam]; if (!Array.isArray(buttons)) return;
  const btn = buttons.find(b => b.id === ptzEditSel); if (!btn) return;
  const sz = ptzBtnSize(btn);
  const clamp = (v, mn) => Math.max(mn, Math.min(PTZ_BTN_MAX, Math.round(v)));
  btn.w = clamp(sz.w * factor, PTZ_BTN_MIN);
  btn.h = btn.kind === 'dpad' ? btn.w : clamp(sz.h * factor, PTZ_BTN_MIN);
  savePtzPanels();
  ptzOverlayReposition();
}
function ptzPanelEditToggle() {
  if (ptzEditMode) { ptzPanelEditEnd(); return; }
  if (!ptzCameraId) return;
  ptzEditMode = true;
  ptzEditCam = ptzCameraId;
  ptzPanelEditorRender();
  document.getElementById('ptz-panel-editor')?.classList.remove('hidden');
  document.getElementById('ptz-edit-panel-btn')?.classList.add('active');
  ptzOverlayReposition();
}
function ptzPanelEditEnd() {
  ptzEditMode = false;
  ptzEditDrag = null;
  ptzEditCam = null;
  ptzEditSel = null;
  ptzSnapGuides = null;
  savePtzPanels();
  document.getElementById('ptz-panel-editor')?.classList.add('hidden');
  document.getElementById('ptz-edit-panel-btn')?.classList.remove('active');
  ptzOverlayReposition();
}
/** (Re)build the edit palette bar (add-buttons for every control + presets). */
function ptzPanelEditorRender() {
  const bar = document.getElementById('ptz-panel-editor');
  if (!bar) return;
  bar.innerHTML = '';
  const add = (cls, label, onClick) => {
    const b = document.createElement('button');
    b.className = `ptzed-btn${cls ? ' ' + cls : ''}`;
    b.textContent = label;
    b.addEventListener('click', onClick);
    bar.appendChild(b);
  };
  const lab = document.createElement('span'); lab.className = 'ptzed-label'; lab.textContent = 'Add:'; bar.appendChild(lab);
  [['dpad', 'D-pad'], ['up', '▲'], ['down', '▼'], ['left', '◄'], ['right', '►'],
    ['home', 'Home'], ['zoom_in', 'Zoom+'], ['zoom_out', 'Zoom−'],
    ['focus_near', 'Focus−'], ['focus_far', 'Focus+'], ['auto_focus', 'AF'],
    ['iris_open', 'Iris+'], ['iris_close', 'Iris−'], ['iris_auto', 'IrisA'],
  ].forEach(([k, lbl]) => add('', lbl, () => ptzPanelAddButton(k)));
  ptzPresets.forEach(p => {
    const nm = (p.name && p.name.trim()) ? p.name : `Preset ${p.token}`;
    add('ptzed-preset', `★ ${nm}`, () => ptzPanelAddButton('preset', { preset: p.token, name: nm }));
  });
  const spacer = document.createElement('span'); spacer.className = 'ptzed-spacer'; bar.appendChild(spacer);
  add('ptzed-clear', 'Clear all', () => { if (ptzEditCam) { ptzPanels[ptzEditCam] = []; ptzEditSel = null; savePtzPanels(); ptzPanelEditorRender(); ptzOverlayReposition(); } });
  add('ptzed-done', 'Done', ptzPanelEditEnd);

  // Selected-button properties row (rename / resize / delete) — wraps to line 2.
  const sel = ptzEditSel && Array.isArray(ptzPanels[ptzEditCam]) ? ptzPanels[ptzEditCam].find(b => b.id === ptzEditSel) : null;
  if (sel) {
    const brk = document.createElement('span'); brk.className = 'ptzed-break'; bar.appendChild(brk);
    const tag = document.createElement('span'); tag.className = 'ptzed-label'; tag.textContent = 'Selected:'; bar.appendChild(tag);
    // Rename — only for buttons that show text.
    const LABELABLE = new Set(['home', 'zoom_in', 'zoom_out', 'focus_near', 'focus_far', 'auto_focus', 'iris_open', 'iris_close', 'iris_auto', 'preset']);
    if (LABELABLE.has(sel.kind)) {
      const inp = document.createElement('input');
      inp.className = 'ptzed-rename'; inp.type = 'text'; inp.placeholder = 'Label';
      inp.value = ptzBtnLabel(sel);
      inp.addEventListener('input', () => { sel.label = inp.value; savePtzPanels(); ptzOverlayReposition(); });
      bar.appendChild(inp);
    }
    add('', '–', () => ptzPanelResizeSelected(1 / 1.15));
    const szl = document.createElement('span'); szl.className = 'ptzed-label'; szl.textContent = 'size'; bar.appendChild(szl);
    add('', '+', () => ptzPanelResizeSelected(1.15));
    add('ptzed-clear', 'Delete', () => ptzPanelDeleteButton(sel.id));
  }
}

// ── Style dispatchers (custom panel → else Options ptzStyle 'edges' | 'wheel') ──
function ptzBuildAss(w, h) {
  const p = ptzActivePanel();
  if (p) return ptzBuildCustomAss(w, h, p.buttons, p.edit);
  const base = options.ptzStyle === 'wheel' ? ptzBuildWheelAss(w, h) : ptzBuildEdgeAss(w, h);
  const img = ptzBuildImagingAss(w, h);
  return img ? `${base}\n${img}` : base;
}
function ptzCtrlHit(slot, x, y) {
  const p = ptzActivePanel();
  if (p) return ptzCustomHit(slot, x, y, p.buttons, p.edit);
  const im = ptzImagingHit(slot, x, y);
  if (im) return im;
  return options.ptzStyle === 'wheel' ? ptzWheelHit(slot, x, y) : ptzEdgeHit(slot, x, y);
}

/** The pane id currently showing the wheel OSD (or null). */
let ptzOsdPaneId = null;

/** Presets fetched for the active PTZ camera ([{token,name}]); drives the on-video
 *  "Presets ▾" pill + its dropdown. Populated in ptzRefresh. */
let ptzPresets = [];

// The on-image preset list is drawn AS ASS ON the video (not a DOM dropdown). A DOM
// menu would need the pane hidden to be visible → the maximized view went BLACK.
// Drawing on the video keeps the picture live; clicks are forwarded + hit-tested.
let ptzPresetsListOpen = false;

/** Escape a preset name for ASS (drop brace/backslash override chars). */
function assEscape(s) { return String(s).replace(/\\/g, '/').replace(/[{}]/g, ''); }

/** Geometry (pane CSS px) of preset-list row `i`, stacking DOWN below the top-left
 *  Presets pill. */
function ptzPresetsRowGeom(i, w, h) {
  const p = ptzCtrlGeom(w, h).presets;
  const rh = 21, gap = 3, rw = Math.max(p.w, 132);
  return { x: p.x, y: p.y + p.h + gap + i * rh, w: rw, h: rh };
}

/** Hit-test a forwarded click against the open preset list → row index or -1. */
function ptzPresetsRowHit(slot, xPhys, yPhys) {
  if (!ptzPresetsListOpen) return -1;
  const tile = getTileEl(slot); if (!tile) return -1;
  const r = tile.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = r.width, h = r.height - tileStripPx();
  const cx = xPhys / dpr, cy = yPhys / dpr;
  for (let i = 0; i < ptzPresets.length; i++) {
    const g = ptzPresetsRowGeom(i, w, h);
    if (g.y + g.h > h - 2) break; // ran off the bottom of the tile
    if (cx >= g.x && cx <= g.x + g.w && cy >= g.y && cy <= g.y + g.h) return i;
  }
  return -1;
}

function ptzPresetsToggle() { ptzPresetsListOpen = !ptzPresetsListOpen; ptzOverlayReposition(); }
function ptzPresetsListClose() { if (ptzPresetsListOpen) { ptzPresetsListOpen = false; ptzOverlayReposition(); } }

/** Draw/clear the wheel ASS overlay on the active PTZ pane via mpv. Replaces the
 *  old DOM-overlay-over-a-carved-notch (which showed a black box + clipped the
 *  mpv window). Called after every pane sync and on PTZ state change. */
function ptzOverlayReposition() {
  const dom = document.getElementById('ptz-overlay');
  if (dom) dom.classList.add('hidden'); // legacy DOM wheel no longer used
  const slot = ptzOverlaySlot();
  const onLive = els.viewLive && !els.viewLive.classList.contains('hidden');
  // A dedicated PTZ control tile suppresses the on-image wheel everywhere.
  const editingThis = ptzEditMode && ptzEditCam === ptzCameraId;
  const wantId = (slot !== null && onLive && ptzTileSlot() === null && (ptzWheelFitsTile(slot) || editingThis)) ? `slot${slot}` : null;
  // Clear the OSD from a pane that should no longer show the wheel.
  if (ptzOsdPaneId && ptzOsdPaneId !== wantId) {
    invoke('set_pane_overlay', { id: ptzOsdPaneId, ass: '', resX: 1, resY: 1 }).catch(() => {});
    ptzOsdPaneId = null;
  }
  if (wantId) {
    const r = getTileEl(slot).getBoundingClientRect();
    const w = r.width, h = r.height - tileStripPx();
    invoke('set_pane_overlay', { id: wantId, ass: ptzBuildAss(w, h), resX: w, resY: h }).catch(() => {});
    ptzOsdPaneId = wantId;
  }
}

/** Refresh the PTZ overlay hint (no-op now the wheel is self-explanatory). */
function ptzUpdateHint() {
  const hint = document.querySelector('#ptz-overlay .ptzo-hint');
  if (!hint) return;
  hint.textContent = 'hold a direction to move · center = home';
}

/** Apply a changed Options.ptzClickMode to a live PTZ session immediately. */
function applyPtzClickMode() {
  if (ptzVideoMode !== 'off') {
    ptzVideoMode = options.ptzClickMode === 'pan' ? 'pan' : 'center';
    ptzVideoStopPan(); // a mode switch cancels any in-progress hold-to-pan
    ptzUpdateHint();
  }
}

/**
 * Evaluate whether the active camera supports PTZ and auto-show/hide the
 * right panel.  Guarded by an in-flight flag — only one probe at a time.
 */
async function ptzRefresh() {
  // Suppress PTZ entirely when the role disallows it.
  if (!state.isAdmin && state.caps && !state.caps.ptz) {
    ptzCameraId = null;
    ptzPanelSetVisible(false);
    return;
  }
  // Don't show PTZ on Playback tab
  const onPlayback = !document.getElementById('view-playback').classList.contains('hidden');

  // A dedicated PTZ control tile owns PTZ → never show the on-image wheel.
  if (ptzTileSlot() !== null) { ptzCameraId = null; ptzPanelSetVisible(false); return; }

  const activeCam = ptzGetActiveCamera();

  if (!activeCam || onPlayback) {
    ptzCameraId = null;
    ptzPanelSetVisible(false);
    return;
  }

  // Already showing the correct camera — nothing to refresh
  if (activeCam.id === ptzCameraId) return;
  // Switching to a DIFFERENT PTZ camera closes an open panel editor (it's per-camera).
  if (ptzEditMode && ptzEditCam !== activeCam.id) ptzPanelEditEnd();

  if (ptzRefreshInFlight) return;
  ptzRefreshInFlight = true;

  try {
    const res = await fetchWithTimeout(`${state.server}/cameras/${activeCam.id}/ptz`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${state.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'presets' }),
    });

    if (!res.ok) {
      ptzCameraId = null;
      ptzPanelSetVisible(false);
      return;
    }

    const data = await res.json(); // { presets: [{token, name}] }
    ptzCameraId = activeCam.id;

    // Update overlay label
    const lbl = document.getElementById('ptzo-label');
    if (lbl) lbl.textContent = `PTZ — ${activeCam.name}`;

    // Presets drive both the toolbar <select> AND the on-video pill/dropdown.
    ptzPresets = (data.presets ?? []);
    const sel = document.getElementById('ptzo-presets');
    if (sel) {
      sel.innerHTML = '<option value="">-- preset --</option>';
      ptzPresets.forEach(p => {
        const opt = document.createElement('option');
        opt.value = p.token;
        opt.textContent = p.name && p.name.trim() ? p.name : `Preset ${p.token}`;
        sel.appendChild(opt);
      });
    }

    ptzPanelSetVisible(true);
    // The active PTZ camera/slot just (re)resolved — re-sync so the wheel notch
    // is carved on the correct tile (ptzPanelSetVisible only syncs on on/off
    // transitions, not when switching between two PTZ tiles).
    scheduleSync();
  } catch (e) {
    console.warn('ptz refresh error:', e);
    ptzCameraId = null;
    ptzPanelSetVisible(false);
  } finally {
    ptzRefreshInFlight = false;
  }
}

// ── Carousel module ───────────────────────────────────────────────────────────
//
// state.carousels: Map<slotIndex, { cameras:[id,...], intervalMs, idx, timer }>
// Starting a carousel on a slot that already has one replaces it cleanly.
// Stopping clears the timer and removes the entry; buildTileGrid re-badges.

function carouselStart(slotIndex, intervalMs) {
  // Stop any existing carousel on this slot first
  carouselStop(slotIndex);

  const cameras = state.cameras.map(c => c.id);
  if (cameras.length < 2) return; // nothing to cycle

  const entry = { cameras, intervalMs, idx: 0, timer: null };

  // Seed: put the current camera first if it's already in the slot
  const currentCam = state.slotMap.get(slotIndex);
  if (currentCam) {
    const pos = entry.cameras.indexOf(currentCam);
    if (pos > 0) entry.idx = pos;
  }

  const tick = () => {
    entry.idx = (entry.idx + 1) % entry.cameras.length;
    const camId = entry.cameras[entry.idx];
    // Assign directly without advanceSelectedSlot side-effects
    state.slotMap.set(slotIndex, camId);
    buildTileGrid();
  };

  entry.timer = setInterval(tick, intervalMs);
  state.carousels.set(slotIndex, entry);
  buildTileGrid(); // show badge immediately
}

function carouselStop(slotIndex) {
  const entry = state.carousels.get(slotIndex);
  if (!entry) return;
  clearInterval(entry.timer);
  state.carousels.delete(slotIndex);
  buildTileGrid(); // remove badge
}

function clearAllCarousels() {
  state.carousels.forEach(entry => clearInterval(entry.timer));
  state.carousels.clear();
}

/** Cameras with recent motion (from /status). Drives motion-mode carousels. */
let liveMotionCams = new Set();

/** Last time (ms) each camera was seen with recent motion — drives auto-hotspot pick. */
const camLastMotionTs = new Map();
/** Per-slot auto-hotspot state: { cam, lastSwitchTs, pinned }. */
const hotspotAuto = new Map();
/** Hold a freshly-switched auto-hotspot camera this long before switching to another
 *  mover, so a busy wall doesn't strobe (switch immediately, then hold briefly). */
const HOTSPOT_DWELL_MS = 4000;

/** Start a CONFIGURED carousel (from a {type:'carousel'} view-item spec):
 *  selected cameras + mode — 'time' (rotate every N s), 'motion' (jump to whichever
 *  selected camera has motion, hold when quiet), or 'both' (motion priority, else
 *  rotate). The chosen camera lands in slotMap so the normal pane logic shows it. */
function carouselStartFromSpec(slotIndex, spec) {
  carouselStop(slotIndex);
  const all = state.cameras.map(c => c.id);
  let cams = (spec.cameras && spec.cameras.length ? spec.cameras : all).filter(id => all.includes(id));
  if (!cams.length) cams = all;
  if (!cams.length) return;
  const intervalMs = Math.max(2000, spec.intervalMs || 8000);
  const mode = (spec.mode === 'motion' || spec.mode === 'both') ? spec.mode : 'time';
  const entry = { cameras: cams, intervalMs, idx: 0, timer: null, mode };
  const cur = state.slotMap.get(slotIndex);
  const pos = cur ? cams.indexOf(cur) : 0;
  entry.idx = pos >= 0 ? pos : 0;
  state.slotMap.set(slotIndex, cams[entry.idx]);

  entry._show = (i) => {
    // Don't churn the wall while THIS slot is maximized — the maximized view is
    // frozen on one camera, so advancing slotMap + rebuilding every tick would just
    // flash/reconnect the stream and land on the wrong camera when restored.
    if (state.maximized !== null && state.maximized.slotIndex === slotIndex) return;
    entry.idx = ((i % cams.length) + cams.length) % cams.length;
    state.slotMap.set(slotIndex, cams[entry.idx]);
    buildTileGrid();
  };
  // Time component: 'time' always rotates; 'both' rotates only while quiet.
  entry.timer = setInterval(() => {
    if (entry.mode === 'time') { entry._show(entry.idx + 1); return; }
    if (entry.mode === 'both' && !cams.some(id => liveMotionCams.has(id))) entry._show(entry.idx + 1);
  }, intervalMs);
  state.carousels.set(slotIndex, entry);
}

/** On each /status poll, let motion-/both-mode carousels jump to a moving camera. */
function carouselMotionTick() {
  state.carousels.forEach((entry, slot) => {
    if (entry.mode !== 'motion' && entry.mode !== 'both') return;
    const movers = entry.cameras.filter(id => liveMotionCams.has(id));
    if (!movers.length) return; // quiet → hold (motion) / time-rotate handles 'both'
    const curId = entry.cameras[entry.idx];
    if (movers.includes(curId)) return; // already on a moving camera
    entry._show(entry.cameras.indexOf(movers[0]));
  });
}

/** On each /status poll, point each auto-hotspot tile at the camera in its set with the
 *  MOST RECENT motion. Switch immediately when a new camera moves, then hold the new
 *  camera for HOTSPOT_DWELL_MS before switching again (so a busy wall doesn't strobe).
 *  A manual click (routeHotspotClick) pins a camera for one dwell window, then resumes. */
function hotspotMotionTick() {
  if (!hotspotAuto.size) return;
  const now = Date.now();
  let changed = false;
  for (const [slot, sp] of state.slotItems) {
    if (sp.type !== 'hotspot' || !(Array.isArray(sp.cameras) && sp.cameras.length)) continue;
    // Don't churn the wall while this slot is maximized.
    if (state.maximized !== null && state.maximized.slotIndex === slot) continue;
    const st = hotspotAuto.get(slot) || {};
    const movers = sp.cameras.filter(id => liveMotionCams.has(id));
    if (!movers.length) continue; // quiet → hold whatever is showing
    // The most-recently-moved camera in the set.
    let target = movers[0], targetTs = camLastMotionTs.get(movers[0]) || 0;
    for (const id of movers) { const ts = camLastMotionTs.get(id) || 0; if (ts > targetTs) { targetTs = ts; target = id; } }
    if (st.cam && sp.cameras.includes(st.cam) && liveMotionCams.has(st.cam)) {
      // Current camera still moving — hold it (don't hop to an equally-busy neighbour).
      continue;
    }
    if (st.cam === target) continue;
    if (st.lastSwitchTs && now - st.lastSwitchTs < HOTSPOT_DWELL_MS) continue; // dwell
    st.cam = target; st.lastSwitchTs = now; st.pinned = false;
    hotspotAuto.set(slot, st);
    if (state.slotMap.get(slot) !== target) { state.slotMap.set(slot, target); changed = true; }
  }
  if (changed) buildTileGrid();
}

// ── Detection-feed view-item ──────────────────────────────────────────────────
let eventTileSeq = 0, eventTileLastFetch = 0;
/** Refresh any live "Detections" feed tiles with recent /events (newest first).
 *  Throttled (~5s) and a no-op when no feed tile is on screen. */
async function updateEventTiles() {
  const lists = document.querySelectorAll('[data-events-list]');
  if (!lists.length) return;
  const now = Date.now();
  if (now - eventTileLastFetch < 5000) return;
  const camIds = state.cameras.map(c => c.id);
  if (!camIds.length) return;
  const start = new Date(now - 30 * 60 * 1000).toISOString();
  const end   = new Date(now + 5000).toISOString();
  const seq = ++eventTileSeq;
  let events = [];
  try {
    const url = `${state.server}/events?camera_ids=${camIds.join(',')}` +
      `&start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}&limit=40`;
    const res = await fetchWithTimeout(url, { headers: authHeaders() });
    if (!res.ok || seq !== eventTileSeq) return;
    events = (await res.json()).events || [];
  } catch { return; }
  eventTileLastFetch = Date.now(); // throttle only AFTER a successful fetch
  // The /events DTO names the start time `ts` (NOT start_ts — that was the NaN time).
  events.sort((a, b) => Date.parse(b.ts) - Date.parse(a.ts));
  const camName = id => camById(id)?.name || 'Camera';
  const rows = events.slice(0, 40).map(e => {
    const ms = Date.parse(e.ts);
    const t = new Date(ms);
    const hhmmss = [t.getHours(), t.getMinutes(), t.getSeconds()].map(n => String(n).padStart(2, '0')).join(':');
    const key = e.icon_key || 'generic';
    // data-cam/data-ts let a click jump to that moment in Playback (see wireEventTile).
    return `<div class="tile-events-row" data-cam="${escHtml(e.camera_id)}" data-ts="${ms}" title="Open in playback">${detectionIconHtml(key)}` +
      `<span class="tev-cam">${escHtml(camName(e.camera_id))}</span>` +
      `<span class="tev-label">${escHtml(e.label || key)}</span>` +
      `<span class="tev-time">${hhmmss}</span></div>`;
  }).join('');
  document.querySelectorAll('[data-events-list]').forEach(list => {
    list.innerHTML = rows || '<div class="tile-events-empty">No recent detections</div>';
  });
}

// ── Clock view-item ───────────────────────────────────────────────────────────
let clockTimer = null;

/** Fit one clock tile's font to its size. The time is a fixed-width 8-glyph string
 *  ("HH:MM:SS"); size it to fill ~90% of the tile width, capped so time + date fit
 *  the height. Deterministic (avoids the cq-unit/flex quirks). Pushed as --clk-fs;
 *  the date tracks it via calc() in CSS. */
function fitClock(el) {
  const w = el.clientWidth, h = el.clientHeight;
  if (!w || !h) return;
  // 8 monospace glyphs at ~0.6em advance + 7px letter-spacing, fill ~90% width.
  const fsW = (w * 0.90 - 7) / (8 * 0.60);
  // time(1.0) + gap(3px) + date(~0.34) + line slack ⇒ time ≈ 60% of height.
  const fsH = h * 0.60;
  const fs = Math.max(12, Math.min(fsW, fsH, 140));
  el.style.setProperty('--clk-fs', `${fs.toFixed(1)}px`);
}

let clockRO = null;
/** (Re)observe every clock tile so its font refits whenever the tile resizes
 *  (window resize, layout/view change, maximize). Call after a grid rebuild. */
function reflowClocks() {
  if (!clockRO) clockRO = new ResizeObserver(es => es.forEach(e => fitClock(e.target)));
  clockRO.disconnect();
  document.querySelectorAll('.tile-clock').forEach(c => { fitClock(c); clockRO.observe(c); });
}

/** One shared 1s ticker updating every clock tile on the wall (no-op if none). */
function startClockTicker() {
  reflowClocks(); // (re)bind size-fit observers to the current clock tiles
  if (clockTimer) return;
  const tick = () => {
    const clocks = document.querySelectorAll('.tile-clock');
    if (!clocks.length) return;
    const d = new Date();
    const time = [d.getHours(), d.getMinutes(), d.getSeconds()].map(n => String(n).padStart(2, '0')).join(':');
    const date = d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
    clocks.forEach(c => {
      const tEl = c.querySelector('[data-clock="time"]'); if (tEl) tEl.textContent = time;
      const dEl = c.querySelector('[data-clock="date"]'); if (dEl) dEl.textContent = date;
    });
  };
  tick();
  clockTimer = setInterval(tick, 1000);
}
function stopClockTicker() {
  if (clockTimer) { clearInterval(clockTimer); clockTimer = null; }
  if (clockRO) clockRO.disconnect();
}

/** Wire a Detections-feed tile: click a row → jump to that moment in Playback. */
function wireEventTile(tile) {
  const list = tile.querySelector('[data-events-list]');
  if (!list) return;
  list.addEventListener('click', (e) => {
    const row = e.target.closest('.tile-events-row');
    if (!row) return;
    e.stopPropagation();
    const cam = row.dataset.cam;
    const ts = parseInt(row.dataset.ts, 10);
    if (cam && Number.isFinite(ts)) goToPlaybackEvent(cam, ts);
  });
}

/** Open Playback at `tsMs` and, if the camera is on the playback wall, select it so
 *  its footage + motion drive the prominent timeline track. */
/** A camera temporarily placed on the wall to show a clicked detection. We restore
 *  the displaced slot when leaving playback so the Live wall / saved view isn't
 *  permanently altered. {slot, prevCam, prevItem}. */
let pbInjectedSlot = null;
function pbRestoreInjectedSlot() {
  if (!pbInjectedSlot) return;
  const { slot, prevCam, prevItem } = pbInjectedSlot;
  pbInjectedSlot = null;
  if (prevItem) state.slotItems.set(slot, prevItem); else state.slotItems.delete(slot);
  if (prevCam) state.slotMap.set(slot, prevCam); else state.slotMap.delete(slot);
}

async function goToPlaybackEvent(cameraId, tsMs) {
  if (!cameraId || !Number.isFinite(tsMs)) return;
  await activateTab('playback');
  pbRestoreInjectedSlot(); // undo any previous detection peek first
  let slot = [...state.slotMap.entries()].find(([, c]) => c === cameraId)?.[0];
  if (slot === undefined) {
    // Camera not on the wall — place it WITHOUT destroying an assignment: prefer an
    // empty slot; only fall back to the selected slot if the wall is full, and
    // remember what we displace so pbRestoreInjectedSlot can put it back.
    const tiles = getLayout().tiles;
    let target = null;
    for (let i = 0; i < tiles; i++) { if (!state.slotMap.has(i) && !state.slotItems.has(i)) { target = i; break; } }
    if (target === null) target = (Number.isInteger(pbState.selectedSlot) && pbState.selectedSlot < tiles) ? pbState.selectedSlot : 0;
    pbInjectedSlot = { slot: target, prevCam: state.slotMap.get(target), prevItem: state.slotItems.get(target) };
    state.slotMap.set(target, cameraId);
    state.slotItems.delete(target);
    slot = target;
  }
  pbState.selectedSlot = -1;      // defeat pbSelectSlot's same-slot early-return so the
  pbSelectSlot(slot);             // injected camera's motion-intensity histogram refetches
  pbState.maximizedSlot = slot;   // open that camera FULL-SCREEN + focus it
  pbBuildTileGrid();
  await pbJumpTo(tsMs);           // jump to the event moment (resolves + seeks)
}

// ── Context menu module ───────────────────────────────────────────────────────
//
// One singleton floating <div id="ctx-menu"> (in HTML).
// ctxOpen(slot, x, y) builds and positions it.
// Closed by outside-click, Escape, or scroll.

let ctxActiveSlot = null;
// True while the context menu has hidden the native panes so it can render over a
// live tile (the panes are HWND_TOP, above the WebView — see ctxOpen).
let ctxPanesHidden = false;

function ctxClose() {
  const menu = document.getElementById('ctx-menu');
  if (menu) menu.style.display = 'none';
  ctxActiveSlot = null;
  if (ctxPanesHidden) {
    ctxPanesHidden = false;
    // Restore video. set_panes_hidden(false) re-SHOWS every pane but re-raises them in
    // arbitrary order, so immediately re-sync — syncPanes re-raises the maximized pane
    // LAST (on top) so the correct camera surfaces, not a warm occluded one.
    invoke('set_panes_hidden', { hidden: false }).catch(() => {}).finally(() => {
      const onPlayback = els.viewPlayback && !els.viewPlayback.classList.contains('hidden');
      if (onPlayback) pbSyncPanes(); else syncPanes();
    });
  }
}

/**
 * Open the context menu for `slot` at viewport coordinates (menuX, menuY).
 * Already clamped by the caller; we clamp again as a safety net.
 */
function ctxOpen(slot, menuX, menuY) {
  ctxClose(); // reset any open instance
  ctxActiveSlot = slot;

  // The camera shown at this slot — honour the maximize override so a camera
  // maximized from OUTSIDE the current wall (focusLiveCameraMaximized) resolves
  // to the MAXIMIZED camera, not the borrowed slot's original occupant (which
  // made right-click show a different camera than the one on screen).
  const hereCam = (state.maximized !== null && state.maximized.slotIndex === slot)
    ? state.maximized.cameraId
    : state.slotMap.get(slot);

  const menu = document.getElementById('ctx-menu');
  if (!menu) return;
  menu.innerHTML = '';

  // ── "Set camera" item with submenu ───────────────────────────────────────
  const setCamItem = ctxMakeItem('Set camera', true);
  const setCamSub  = document.createElement('div');
  setCamSub.className = 'ctx-submenu';

  // "(empty)" option to clear the slot
  const emptyOpt = ctxMakeItem('(empty)', false);
  emptyOpt.addEventListener('click', () => {
    state.slotMap.delete(slot);
    state.slotItems.delete(slot); // clear any view-item too
    carouselStop(slot); // stop any carousel that was cycling here
    buildTileGrid();
    buildCameraList();
    ptzRefresh();
    ctxClose();
  });
  setCamSub.appendChild(emptyOpt);

  state.cameras.forEach(cam => {
    const item = ctxMakeItem(cam.name, false);
    const isHere = hereCam === cam.id;
    if (isHere) item.style.color = 'var(--live)';
    item.addEventListener('click', () => {
      // commercial-VMS-style move: remove from wherever it currently lives
      state.slotMap.forEach((id, s) => { if (id === cam.id) state.slotMap.delete(s); });
      state.slotItems.delete(slot); // a direct camera replaces any view-item here
      state.slotMap.set(slot, cam.id);
      carouselStop(slot);
      buildTileGrid();
      buildCameraList();
      selectSlot(slot); // highlight the tile we just set
      ptzRefresh();
      ctxClose();
    });
    setCamSub.appendChild(item);
  });

  setCamItem.appendChild(setCamSub);
  menu.appendChild(setCamItem);

  // ── "Stream" submenu (main / sub) — only for a slot showing a camera ───────
  const slotCam = hereCam;
  if (slotCam) {
    const s = state.streams.get(slotCam);
    const hasSub = !!(s && s.rtsp_sub_url);
    const pref = getStreamPref(slotCam);
    const streamItem = ctxMakeItem('Stream', true);
    const streamSub = document.createElement('div');
    streamSub.className = 'ctx-submenu';
    [['main', 'Main — full quality'], ['sub', hasSub ? 'Sub — low bandwidth' : 'Sub — (unavailable)']].forEach(([val, label]) => {
      const it = ctxMakeItem((pref === val ? '✓ ' : ' ') + label, false);
      if (pref === val) it.style.color = 'var(--live)';
      if (val === 'sub' && !hasSub) { it.style.opacity = '0.5'; return streamSub.appendChild(it); }
      it.addEventListener('click', () => {
        setStreamPref(slotCam, val);
        syncPanes(); // sync_panes reloads the pane in place when the URL changes
        ctxClose();
      });
      streamSub.appendChild(it);
    });
    streamItem.appendChild(streamSub);
    menu.appendChild(streamItem);
  }

  // ── Separator ─────────────────────────────────────────────────────────────
  menu.appendChild(ctxMakeSep());

  // ── Maximize / Restore ────────────────────────────────────────────────────
  const isMaxed = state.maximized !== null && state.maximized.slotIndex === slot;
  const maxItem = ctxMakeItem(isMaxed ? 'Restore' : 'Maximize', false);
  maxItem.addEventListener('click', () => {
    handleTileDoubleClick(slot);
    ctxClose();
  });
  menu.appendChild(maxItem);
  // (Carousel is no longer a live right-click action — carousels are configured as
  // a view item in Config View / View Setup. Removed per feedback 2026-06-17.)

  ctxPositionAndShow(menu, menuX, menuY);
}

/** Position the populated #ctx-menu at (menuX,menuY), clamp on-screen, flip submenus
 *  near the right edge, and hide the panes it covers. */
function ctxPositionAndShow(menu, menuX, menuY) {
  menu.style.display = 'block';
  menu.style.left = '0';
  menu.style.top  = '0';
  // Measure after display so offsetWidth/Height are valid
  const mw = menu.offsetWidth  || 180;
  const mh = menu.offsetHeight || 120;
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const x = Math.min(menuX, vw - mw - 4);
  const y = Math.min(menuY, vh - mh - 4);
  menu.style.left = `${Math.max(2, x)}px`;
  menu.style.top  = `${Math.max(2, y)}px`;
  // Submenus fly out to the RIGHT (left:100%) by default; near the right edge
  // there's no room for one, so flip them LEFT (right:100%) to stay on-screen.
  menu.classList.toggle('flip-sub', x + mw + 170 > vw);
  ctxHidePanesUnder(x, y, mw, mh);
}

/** Right-click menu while customizing a PTZ panel: act on the button under the
 *  cursor (rename/resize/reorder/duplicate/delete) or add a new control. */
function ptzEditContextMenu(slot, menuX, menuY, xPhys, yPhys) {
  ctxClose();
  const menu = document.getElementById('ctx-menu');
  if (!menu) return;
  menu.innerHTML = '';
  const buttons = ptzPanels[ptzEditCam] || [];
  // Which button was right-clicked (topmost under the cursor)?
  const hit = ptzCustomHit(slot, xPhys, yPhys, buttons, true); // edit-mode → edit-move/edit-delete/edit-resize
  const btn = hit ? buttons.find(b => b.id === hit.id) : null;

  if (btn) {
    ptzPanelSelect(btn.id);
    const LABELABLE = new Set(['home', 'zoom_in', 'zoom_out', 'focus_near', 'focus_far', 'auto_focus', 'iris_open', 'iris_close', 'iris_auto', 'preset']);
    const head = ctxMakeItem(`${btn.kind === 'preset' ? (btn.name || 'Preset') : (PTZ_PANEL_KINDS[btn.kind]?.label || btn.kind)}`, false);
    head.style.opacity = '0.6'; head.style.pointerEvents = 'none';
    menu.appendChild(head);
    menu.appendChild(ctxMakeSep());
    if (LABELABLE.has(btn.kind)) {
      const ren = ctxMakeItem('Rename…', false);
      ren.addEventListener('click', () => { ctxClose(); ptzPanelSelect(btn.id); document.querySelector('#ptz-panel-editor .ptzed-rename')?.focus(); });
      menu.appendChild(ren);
    }
    const bigger = ctxMakeItem('Bigger', false);
    bigger.addEventListener('click', () => { ptzPanelResizeSelected(1.15); ctxClose(); });
    menu.appendChild(bigger);
    const smaller = ctxMakeItem('Smaller', false);
    smaller.addEventListener('click', () => { ptzPanelResizeSelected(1 / 1.15); ctxClose(); });
    menu.appendChild(smaller);
    const dup = ctxMakeItem('Duplicate', false);
    dup.addEventListener('click', () => {
      const c = { ...btn, id: `b${ptzPanelSeq++}`, x: Math.min(0.92, btn.x + 0.04), y: Math.min(0.92, btn.y + 0.04) };
      (ptzPanels[ptzEditCam] ||= []).push(c); ptzEditSel = c.id; savePtzPanels(); ptzPanelEditorRender(); ptzOverlayReposition(); ctxClose();
    });
    menu.appendChild(dup);
    const front = ctxMakeItem('Bring to front', false);
    front.addEventListener('click', () => { const a = ptzPanels[ptzEditCam]; const i = a.indexOf(btn); if (i >= 0) { a.splice(i, 1); a.push(btn); savePtzPanels(); ptzOverlayReposition(); } ctxClose(); });
    menu.appendChild(front);
    const back = ctxMakeItem('Send to back', false);
    back.addEventListener('click', () => { const a = ptzPanels[ptzEditCam]; const i = a.indexOf(btn); if (i >= 0) { a.splice(i, 1); a.unshift(btn); savePtzPanels(); ptzOverlayReposition(); } ctxClose(); });
    menu.appendChild(back);
    menu.appendChild(ctxMakeSep());
    const del = ctxMakeItem('Delete', false);
    del.classList.add('ctx-item-danger');
    del.addEventListener('click', () => { ptzPanelDeleteButton(btn.id); ctxClose(); });
    menu.appendChild(del);
  } else {
    if (ptzEditSel) ptzPanelSelect(null);
  }

  // "Add control" submenu (always available).
  const addItem = ctxMakeItem('Add control', true);
  const addSub = document.createElement('div');
  addSub.className = 'ctx-submenu';
  const addOpt = (kind, label, extra) => {
    const it = ctxMakeItem(label, false);
    it.addEventListener('click', () => { ptzPanelAddButton(kind, extra); ctxClose(); });
    addSub.appendChild(it);
  };
  [['dpad', 'D-pad'], ['up', 'Up'], ['down', 'Down'], ['left', 'Left'], ['right', 'Right'],
    ['home', 'Home'], ['zoom_in', 'Zoom +'], ['zoom_out', 'Zoom −'],
    ['focus_near', 'Focus −'], ['focus_far', 'Focus +'], ['auto_focus', 'Auto-focus'],
    ['iris_open', 'Iris +'], ['iris_close', 'Iris −'], ['iris_auto', 'Auto-iris'],
  ].forEach(([k, lbl]) => addOpt(k, lbl));
  ptzPresets.forEach(p => addOpt('preset', `★ ${(p.name && p.name.trim()) ? p.name : `Preset ${p.token}`}`, { preset: p.token, name: (p.name && p.name.trim()) ? p.name : `Preset ${p.token}` }));
  addItem.appendChild(addSub);
  menu.appendChild(addItem);

  ctxPositionAndShow(menu, menuX, menuY);
}

/** The native video panes are HWND_TOP (above the WebView), so a DOM menu drawn over
 *  a camera is HIDDEN BEHIND the video. Hide ONLY the panes a menu at (x,y,mw,mh) can
 *  cover — its rect + a submenu fly-out allowance — so the rest of the wall stays
 *  live. mpv stays alive, so ctxClose restores instantly. */
function ctxHidePanesUnder(x, y, mw, mh) {
  // MAXIMIZED: the whole wall is kept WARM, stacked at the same rect BEHIND the
  // maximized pane (fast restore). Hiding just the top pane would uncover the next
  // camera in the stack — the "right-click switches the camera" bug. Hide them ALL
  // (ids omitted) so only the menu shows over black; ctxClose re-raises correctly.
  if (state.maximized !== null) {
    invoke('set_panes_hidden', { hidden: true })
      .then(() => { ctxPanesHidden = true; })
      .catch(() => {});
    return;
  }
  const subW = 180, subH = 360; // submenu fly-out width + generous tall-list height
  const region = { left: x - subW, top: y, right: x + mw + subW, bottom: y + Math.max(mh, subH) };
  const hideIds = [];
  const layout = getLayout();
  for (let i = 0; i < layout.tiles; i++) {
    const el = getTileEl(i);
    if (!el) continue;
    const r = el.getBoundingClientRect();
    if (r.left < region.right && r.right > region.left && r.top < region.bottom && r.bottom > region.top) {
      hideIds.push(`slot${i}`);
    }
  }
  if (hideIds.length) {
    invoke('set_panes_hidden', { hidden: true, ids: hideIds })
      .then(() => { ctxPanesHidden = true; })
      .catch(() => {});
  }
}

function ctxMakeItem(label, hasSub) {
  const el = document.createElement('div');
  el.className = 'ctx-item' + (hasSub ? ' has-sub' : '');
  const span = document.createElement('span');
  span.textContent = label;
  el.appendChild(span);
  if (hasSub) {
    const arrow = document.createElement('span');
    arrow.className = 'ctx-arrow';
    arrow.textContent = '▶';
    el.appendChild(arrow);
    // Click toggles this submenu (and closes sibling submenus). Hover-open made the
    // camera list pop up under the cursor → an errant click switched the camera.
    el.addEventListener('click', (e) => {
      e.stopPropagation();
      const open = el.classList.contains('open');
      el.parentElement?.querySelectorAll(':scope > .ctx-item.has-sub.open').forEach(o => o.classList.remove('open'));
      if (!open) el.classList.add('open');
    });
  }
  return el;
}

function ctxMakeSep() {
  const el = document.createElement('div');
  el.className = 'ctx-sep';
  return el;
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** Parse a pane id ("slot3") back to its slot index, or null. */
function paneIdToSlot(id) {
  const m = /^slot(\d+)$/.exec(String(id));
  return m ? parseInt(m[1], 10) : null;
}

// ── Entry point ───────────────────────────────────────────────────────────────

window.addEventListener('DOMContentLoaded', async () => {
  // Suppress the WebView2 default (browser) right-click menu — this is a desktop
  // app, not a browser, so "Back / Reload / Inspect" shouldn't appear. The app's
  // own context menus (tile assign, etc.) preventDefault + stopPropagation
  // themselves so they still work; text inputs keep their native copy/paste menu.
  document.addEventListener('contextmenu', (e) => {
    const t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
    e.preventDefault();
  });

  // Collect DOM refs
  els = {
    topbar:          document.getElementById('topbar'),
    loginScreen:     document.getElementById('login-screen'),
    appShell:        document.getElementById('app-shell'),
    loginForm:       document.getElementById('login-form'),
    loginServer:     document.getElementById('login-server'),
    loginUser:       document.getElementById('login-user'),
    loginPass:       document.getElementById('login-pass'),
    loginError:      document.getElementById('login-error'),
    loginBtn:        document.getElementById('login-btn'),
    loginRemember:   document.getElementById('login-remember'),
    loginDiscoverBtn: document.getElementById('login-discover-btn'),
    loginDiscoverMsg: document.getElementById('login-discover-msg'),
    loginDiscoverList: document.getElementById('login-discover-list'),
    loginSubnetRow:  document.getElementById('login-subnet-row'),
    loginSubnet:     document.getElementById('login-subnet'),
    loginSubnetBtn:  document.getElementById('login-subnet-btn'),
    serverLabel:     document.getElementById('server-label'),
    signoutBtn:      document.getElementById('signout-btn'),
    // Stub refs — these point to hidden legacy divs; JS still calls
    // els.layoutPresets / els.cameraList without crashing.
    layoutPresets:   document.getElementById('layout-presets'),
    cameraList:      document.getElementById('camera-list'),
    tileGrid:        document.getElementById('tile-grid'),
    viewLive:        document.getElementById('view-live'),
    viewPlayback:    document.getElementById('view-playback'),
    viewServer:      document.getElementById('view-server'),
    viewExport:      document.getElementById('view-export'),
    viewClips:       document.getElementById('view-clips'),
    statusText:      document.getElementById('status-text'),
    // Playback-specific
    pbTileGrid:      document.getElementById('pb-tile-grid'),
    pbTimeline:      document.getElementById('pb-timeline'),
    pbPlayPause:     document.getElementById('pb-play-pause'),
    pbPlayIcon:      document.getElementById('pb-play-icon'),
    pbPauseIcon:     document.getElementById('pb-pause-icon'),
    pbSpeedBtn:      document.getElementById('pb-speed-btn'),
    pbPrevMotion:    document.getElementById('pb-prev-motion'),
    pbNextMotion:    document.getElementById('pb-next-motion'),
    pbTimeDisplay:   document.getElementById('pb-time-display'),
    pbTimeInput:     document.getElementById('pb-time-input'),
    pbTimeGoto:      document.getElementById('pb-time-goto'),
    pbJumpMinusHour: document.getElementById('pb-jump-minus-hour'),
    pbJumpMinusMin:  document.getElementById('pb-jump-minus-min'),
    pbJumpPlusMin:   document.getElementById('pb-jump-plus-min'),
    pbJumpPlusHour:  document.getElementById('pb-jump-plus-hour'),
  };

  // ── Event wiring ──────────────────────────────────────────────────────────

  els.loginForm.addEventListener('submit', handleLogin);
  els.loginDiscoverBtn?.addEventListener('click', () => loginDiscover(null));
  els.loginSubnetBtn?.addEventListener('click', () => loginDiscover(els.loginSubnet?.value || ''));

  els.signoutBtn.addEventListener('click', handleSignOut);

  // Re-auth overlay (H6): a mid-session 401 shows this instead of tearing down
  // to the login screen, so the wall's native panes stay alive underneath.
  document.getElementById('reauth-form')?.addEventListener('submit', (e) => { e.preventDefault(); void reauthSubmit(); });
  document.getElementById('reauth-submit-btn')?.addEventListener('click', () => void reauthSubmit());
  document.getElementById('reauth-signout-btn')?.addEventListener('click', () => { reauthClose(); void handleSignOut(); });

  // Customize the on-video PTZ control panel (commercial-VMS-style placeable buttons).
  document.getElementById('ptz-edit-panel-btn')?.addEventListener('click', ptzPanelEditToggle);

  // Audio speaker toggle (top bar) — listen to the focused/selected camera.
  document.getElementById('audio-toggle-btn').addEventListener('click', toggleActiveAudio);

  document.querySelectorAll('.tab').forEach(tab => {
    tab.addEventListener('click', () => activateTab(tab.dataset.tab));
  });

  // Resize sync: watch the tile grid, the PTZ panel, and the window.
  // The PTZ panel toggling changes the stage flex layout — observing it
  // ensures syncPanes() fires after the grid shrinks/expands.
  const ro = new ResizeObserver(() => scheduleSync());
  ro.observe(els.tileGrid);
  const ptzBar = document.getElementById('ptz-bar');
  if (ptzBar) ro.observe(ptzBar);
  window.addEventListener('resize', scheduleSync);

  document.addEventListener('keydown', handleKeyDown);

  // Native panes sit ON TOP of the webview and capture the mouse, so a tile's
  // DOM click/dblclick never fires over the video. The Rust pane WndProc
  // forwards them as Tauri events — map the pane id (slotN) back to a slot.
  const { listen } = window.__TAURI__.event;
  listen('pane-click', (e) => {
    // payload = { id, x, y } (x,y = pane-client PHYSICAL px)
    const { id, x, y } = e.payload;
    const slot = paneIdToSlot(id);
    if (slot === null) return;
    // In Playback a video click selects the slot (its camera drives the prominent
    // timeline track). When the tile is digitally zoomed (wheel), a drag grabs-to-
    // pan around the image — same as a zoomed LIVE tile. At 1× there's no box-zoom
    // here, so the click is just a select.
    if (els.viewPlayback && !els.viewPlayback.classList.contains('hidden')) {
      pbSelectSlot(slot);
      paneDragState = (paneZoom.get(id) || 0) > 0.01 ? { id, slot, lastX: x, lastY: y } : null;
      paneBox = null;
      return;
    }
    // Capture PTZ-active BEFORE selecting (first click on a PTZ tile just
    // selects; later clicks drive the wheel). On the active PTZ tile, a click
    // inside the lower-left wheel drives PTZ; clicks elsewhere just select.
    const wasPtzSlot = ptzCameraId !== null && slot === ptzActiveSlot();
    selectSlot(slot);
    if (wasPtzSlot) {
      // Custom-panel EDIT mode: a click deletes (✕ handle) or starts moving a button;
      // empty space is a no-op. Never drives PTZ while editing.
      if (ptzEditMode && ptzEditCam === ptzCameraId) {
        const hit = ptzCtrlHit(slot, x, y);
        if (hit && hit.kind === 'edit-delete') { ptzPanelDeleteButton(hit.id); }
        else if (hit && hit.kind === 'edit-resize') { ptzPanelSelect(hit.id); ptzEditDrag = { id: hit.id, slot, mode: 'resize' }; }
        else if (hit && hit.kind === 'edit-move') {
          ptzPanelSelect(hit.id);
          // Preserve the grab point so the button doesn't jump under the cursor.
          const buttons = ptzPanels[ptzEditCam] || [];
          const btn = buttons.find(b => b.id === hit.id);
          const tile = getTileEl(slot); const r = tile?.getBoundingClientRect();
          const dpr = window.devicePixelRatio || 1;
          let grabOffX, grabOffY;
          if (btn && r) {
            const w = r.width, h = r.height - tileStripPx();
            grabOffX = x / dpr - btn.x * w;
            grabOffY = y / dpr - btn.y * h;
          }
          ptzEditDrag = { id: hit.id, slot, mode: 'move', grabOffX, grabOffY };
        } else { if (ptzEditSel) ptzPanelSelect(null); } // clicked empty space → deselect
        paneDragState = null; return;
      }
      // Preset list (drawn on the video as ASS) is open → a click picks a row or
      // dismisses it; never hide the pane (that turned the maximized view black).
      if (ptzPresetsListOpen) {
        const row = ptzPresetsRowHit(slot, x, y);
        if (row >= 0) ptzCmd({ action: 'preset', preset: ptzPresets[row].token });
        ptzPresetsListClose();
        paneDragState = null; return;
      }
      // Unified control hit-test: presets pill, Home, zoom (HOLD), or a direction (HOLD).
      const c = ptzCtrlHit(slot, x, y);
      if (c) {
        if (c.kind === 'presets') { ptzPresetsToggle(); paneDragState = null; return; }
        if (c.kind === 'preset') { ptzCmd({ action: 'preset', preset: c.token }); paneDragState = null; return; }
        if (c.kind === 'home') { ptzCmd({ action: 'home' }); paneDragState = null; return; }
        if (c.kind === 'imaging') {
          // Focus near/far = hold (release → focus_stop via pane-dragend); AF/iris fire once.
          if (c.action === 'focus_near' || c.action === 'focus_far') ptzFocusHeld = true;
          imagingTileCmd(ptzCameraId, c.action);
          paneDragState = null; return;
        }
        clearTimeout(ptzPulseTimer);
        clearTimeout(ptzWheelStopTimer);
        ptzWheelActive = true; // held until pane-dragend (release) → Stop
        ptzZoomHeld = c.kind === 'zoom' ? c.dir : null;
        if (c.kind === 'zoom') ptzCmd({ action: 'move', pan: 0, tilt: 0, zoom: c.dir === 'in' ? 0.5 : -0.5 });
        else ptzCmd({ action: 'move', pan: c.pan, tilt: c.tilt, zoom: 0 });
      } else if (options.ptzClickMode !== 'off') {
        // Click landed on the video, not on an arrow/wheel control: drive PTZ by
        // click position — 'center' recenters on the point, 'pan' starts a
        // hold-to-pan (re-aimed on drag, stopped on release). 'off' disables this.
        ptzVideoClick(slot, x, y);
      }
      paneDragState = null; // PTZ tiles don't digital-pan
    } else if ((paneZoom.get(id) || 0) > 0.01) {
      // Pane is already digitally zoomed → a drag grabs-to-pan.
      paneDragState = { id, slot, lastX: x, lastY: y };
      paneBox = null;
    } else {
      // Pane at 1× → a drag draws a zoom box (commercial-VMS-style "draw a box, zoom
      // to it"); released in pane-dragend via zoom_pane_rect.
      paneBox = { id, slot, x0: x, y0: y, x1: x, y1: y };
      paneDragState = null;
    }
  });
  listen('pane-drag', (e) => {
    const { id, x, y } = e.payload;
    // Custom-panel EDIT mode: drag moves or resizes the grabbed button.
    if (ptzEditDrag) {
      const slot = paneIdToSlot(id);
      if (slot !== null) {
        if (ptzEditDrag.mode === 'resize') ptzPanelResizeButton(ptzEditDrag.id, slot, x, y);
        else ptzPanelMoveButton(ptzEditDrag.id, slot, x, y);
      }
      return;
    }
    // PTZ wheel held: dragging re-aims the continuous move (slide finger around
    // the wheel to change direction). Releasing stops it (pane-dragend).
    if (ptzWheelActive) {
      // Direction hold → re-aim as the finger slides onto another arrow; zoom hold →
      // keep zooming (don't re-aim to a direction).
      if (!ptzZoomHeld) {
        const slot = paneIdToSlot(id);
        if (slot !== null) {
          const c = ptzCtrlHit(slot, x, y);
          if (c && c.kind === 'dir') ptzCmd({ action: 'move', pan: c.pan, tilt: c.tilt, zoom: 0 });
        }
      }
      return;
    }
    // Click-on-video hold-to-pan ('pan' mode): dragging re-aims the continuous
    // move toward the cursor; release (pane-dragend) stops it.
    if (ptzPanActive) {
      const slot = paneIdToSlot(id);
      if (slot !== null) ptzVideoSteer(slot, x, y);
      return;
    }
    // Box-zoom rubber-band in progress → grow the rectangle (drawn via mpv ASS).
    if (paneBox) {
      if (id !== paneBox.id) return;
      paneBox.x1 = x;
      paneBox.y1 = y;
      drawBoxOverlay();
      return;
    }
    if (!paneDragState) return;
    if (id !== paneDragState.id) return;
    const dx = x - paneDragState.lastX;
    const dy = y - paneDragState.lastY;
    paneDragState.lastX = x;
    paneDragState.lastY = y;
    if (dx === 0 && dy === 0) return;
    // Use the tile that actually owns this pane. getTileEl() is a document-wide
    // querySelector, so during playback it can return the HIDDEN live-wall tile
    // (same data-slot, ~0px rect) and break the pan normalization — resolve the
    // playback grid's tile explicitly when the Playback tab is visible.
    const inPlayback = els.viewPlayback && !els.viewPlayback.classList.contains('hidden');
    const tile = inPlayback
      ? els.pbTileGrid.querySelector(`.tile[data-slot="${paneDragState.slot}"]`)
      : getTileEl(paneDragState.slot);
    if (!tile) return;
    const r = tile.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    // The native pane is inset below the title strip (and above the PTZ overlay
    // band on the active PTZ tile); pan_pane normalizes dy by the drawable height.
    const paneH = Math.max(1, r.height - tileStripPx() - tileBottomInset(paneDragState.slot)) * dpr;
    invoke('pan_pane', { id, dx, dy, paneW: r.width * dpr, paneH })
      .catch(() => {});
  });
  listen('pane-dragend', () => {
    if (ptzEditDrag) { ptzEditDrag = null; ptzSnapGuides = null; savePtzPanels(); ptzOverlayReposition(); return; }
    if (ptzWheelActive) { ptzWheelActive = false; ptzZoomHeld = null; ptzCmd({ action: 'stop' }); }
    if (ptzFocusHeld) { ptzFocusHeld = false; imagingTileCmd(ptzCameraId, 'focus_stop'); }
    ptzVideoStopPan(); // stop any in-progress hold-to-pan (legacy path)
    // Finish a box-zoom: clear the rubber-band, then zoom to the drawn rect.
    if (paneBox) {
      const b = paneBox;
      paneBox = null;
      clearBoxOverlay(b.id);
      const tile = getTileEl(b.slot);
      if (tile) {
        const r = tile.getBoundingClientRect();
        const dpr = window.devicePixelRatio || 1;
        invoke('zoom_pane_rect', {
          id: b.id,
          x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1,
          paneW: r.width * dpr,
          paneH: Math.max(1, r.height - tileStripPx()) * dpr,
        }).then(z => paneZoom.set(b.id, z))
          .catch(err => console.warn('zoom_pane_rect failed:', err));
      }
    }
    paneDragState = null;
  });
  listen('pane-dblclick', (e) => {
    const slot = paneIdToSlot(e.payload);
    if (slot === null) return;
    // Route to the visible view's maximize handler (playback has its own state).
    if (els.viewPlayback && !els.viewPlayback.classList.contains('hidden')) {
      pbHandleTileDoubleClick(slot);
    } else {
      handleTileDoubleClick(slot);
    }
  });
  listen('pane-wheel', (e) => {
    // payload = { id, delta (signed notches), x, y } — pane-client PHYSICAL px.
    const { id, delta, x, y } = e.payload;
    const slot = paneIdToSlot(id);
    if (slot === null) return;
    // PLAYBACK: no PTZ here, and the LIVE slotMap is empty — so the live camId
    // lookup below would wrongly bail (this is why playback wheel-zoom broke).
    // Wheel = per-pane digital zoom centered on the cursor, on the playback tile
    // that actually owns this pane.
    if (els.viewPlayback && !els.viewPlayback.classList.contains('hidden')) {
      if (!pbState.slotSegments.get(slot)) return; // no footage → no pane to zoom
      const pbTile = els.pbTileGrid.querySelector(`.tile[data-slot="${slot}"]`);
      if (!pbTile) return;
      const pr = pbTile.getBoundingClientRect();
      const pdpr = window.devicePixelRatio || 1;
      invoke('zoom_pane', {
        id, deltaSteps: delta, cx: x, cy: y,
        paneW: pr.width * pdpr,
        paneH: Math.max(1, pr.height - tileStripPx()) * pdpr,
      }).then(z => paneZoom.set(id, z))
        .catch(err => console.warn('zoom_pane (playback) failed:', err));
      return;
    }
    let camId = null;
    if (state.maximized !== null && state.maximized.slotIndex === slot) {
      camId = state.maximized.cameraId;
    } else {
      camId = state.slotMap.get(slot) ?? null;
    }
    if (!camId) return;
    // Optical PTZ zoom only on the ACTIVE PTZ tile (matches the click path);
    // other tiles — incl. a non-active tile showing the same PTZ camera — get
    // digital zoom, which is the intuitive per-tile behavior.
    if (camId === ptzCameraId && slot === ptzActiveSlot()) {
      ptzVideoWheel(delta);
      return;
    }
    const tile = getTileEl(slot);
    if (!tile) return;
    const r = tile.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    // Native pane is inset below the title strip (and above the PTZ overlay band
    // on the active PTZ tile); cx/cy are pane-relative, so normalize to its size.
    invoke('zoom_pane', {
      id,
      deltaSteps: delta,
      cx: x,
      cy: y,
      paneW: r.width * dpr,
      paneH: Math.max(1, r.height - tileStripPx() - tileBottomInset(slot)) * dpr,
    }).then(z => paneZoom.set(id, z))
      .catch(err => console.warn('zoom_pane failed:', err));
  });

  // ── Playback transport event wiring ──────────────────────────────────────

  els.pbPlayPause.addEventListener('click', pbTogglePlay);
  els.pbSpeedBtn.addEventListener('click', pbCycleSpeed);
  els.pbPrevMotion.addEventListener('click', pbPrevMotion);
  els.pbNextMotion.addEventListener('click', pbNextMotion);
  document.getElementById('pb-goto-first').addEventListener('click', pbJumpToFirst);
  document.getElementById('pb-frame-back').addEventListener('click', () => pbFrameStep(false));
  document.getElementById('pb-frame-fwd').addEventListener('click', () => pbFrameStep(true));
  document.getElementById('pb-goto-last').addEventListener('click', pbJumpToLatest);
  els.pbTimeGoto.addEventListener('click', pbHandleTimeGoto);
  els.pbTimeInput.addEventListener('keydown', e => { if (e.key === 'Enter') pbHandleTimeGoto(); });
  els.pbJumpMinusHour.addEventListener('click', () => pbShiftWindow(-3600_000));
  els.pbJumpMinusMin.addEventListener('click',  () => pbShiftWindow(-600_000));
  els.pbJumpPlusMin.addEventListener('click',   () => pbShiftWindow(600_000));
  els.pbJumpPlusHour.addEventListener('click',  () => pbShiftWindow(3600_000));
  // Wrap, don't pass pbAddBookmark directly — addEventListener would hand it the
  // click Event as camIdArg, so camera_id became the event object → HTTP 422 and
  // the bookmark silently never saved. Call with no args → resolve the camera.
  document.getElementById('pb-bookmark-add')?.addEventListener('click', () => pbAddBookmark());
  document.getElementById('pb-bookmarks-open')?.addEventListener('click', pbOpenBookmarks);

  // ── Toolbar: Saved Views ──────────────────────────────────────────────────
  // Save / delete / build views now live inside the "Config View" dialog (kept
  // off the live toolbar per feedback). The toolbar shows only the quick-switch
  // view buttons (#toolbar-layout-presets) + the Config View button.

  // ── Toolbar: PTZ toggle REMOVED (2026-06-17) ──────────────────────────────
  // PTZ is now an on-image overlay / a dedicated PTZ view item, so the top-bar
  // toggle is gone. The #toolbar-ptz-btn element no longer exists; activateTab's
  // ptzBtn lookups are null-guarded.

  // ── Snapshot the selected camera (also the S hotkey) ───────────────────────
  document.getElementById('toolbar-snapshot-btn')?.addEventListener('click', snapshotActivePane);

  // ── Fullscreen camera wall ─────────────────────────────────────────────────
  document.getElementById('toolbar-fullscreen-btn')?.addEventListener('click', toggleCamerasFullscreen);

  // ── Options dialog wiring ──────────────────────────────────────────────────
  // The ⚙ gear now jumps to Settings → Client (the old modal was relocated there).
  document.getElementById('toolbar-options-btn')?.addEventListener('click', () => {
    srvState.section = 'client';
    void activateTab('server');
  });
  // Settings section nav (Client / Cameras / Statistics / Server / Diagnostics).
  document.querySelectorAll('#srv-nav .srv-nav-btn').forEach(btn => {
    btn.addEventListener('click', () => srvSelectSection(btn.dataset.section));
  });
  document.getElementById('srv-bench-run')?.addEventListener('click', () => void hudRunBenchmark());
  // Inline tuner: selecting a camera in the picker shows it immediately — no
  // separate "Open" click (see srvSelectSection('motion') for the initial load).
  document.getElementById('srv-tuner-cam')?.addEventListener('change', () => void srvOpenTuner());
  document.getElementById('srv-policy-verify')?.addEventListener('click', () => void srvVerifyPolicySizes());
  document.getElementById('recording-alert-banner')?.addEventListener('click', () => {
    void activateTab('server');
    srvSelectSection('server');
  });
  document.getElementById('srv-hotkeys-reset')?.addEventListener('click', srvHotkeyReset);
  // Update-available notice (issue #7): "Check now" forces a fresh server-side
  // check, the release-notes link opens in the OS browser (not the WebView2
  // in-app pane), Dismiss remembers this version only.
  document.getElementById('srv-update-check-btn')?.addEventListener('click', () => void onUpdateCheckNow());
  document.getElementById('srv-update-dismiss-btn')?.addEventListener('click', onUpdateDismiss);
  // Both release-notes links (the always-present field + the dismissible banner)
  // open the notes URL in the OS browser, not the WebView2 in-app pane.
  document.querySelectorAll('.srv-update-link').forEach((el) => {
    el.addEventListener('click', (e) => {
      e.preventDefault();
      const url = e.currentTarget.dataset.url;
      if (url) invoke('open_url', { url }).catch(() => setStatus('Could not open the release notes.'));
    });
  });
  document.getElementById('srv-admin-open')?.addEventListener('click', () => {
    const url = (state.server || '').replace(/\/$/, '') + '/admin';
    if (state.server) invoke('open_url', { url }).catch(() => setStatus('Could not open the console.'));
  });
  // Management section: reload the embedded console + open it in the OS browser.
  document.getElementById('srv-admin-reload')?.addEventListener('click', () => {
    srvState.adminSrcKey = null;              // force a fresh load
    document.getElementById('srv-admin-frame-host')?.querySelector('iframe')?.remove();
    srvEnterAdmin();
  });
  document.getElementById('srv-admin-browser')?.addEventListener('click', () => {
    const url = (state.server || '').replace(/\/$/, '') + '/admin';
    if (state.server) invoke('open_url', { url }).catch(() => setStatus('Could not open the console.'));
  });

  document.getElementById('opt-show-infobar')?.addEventListener('change', (e) => {
    options.showInfoBar = !!e.target.checked;
    saveOptions();
    // No modal-close to trigger the rebuild anymore — apply the title-bar change live.
    if (els.viewLive && !els.viewLive.classList.contains('hidden')) {
      buildTileGrid();
      void liveStatusPoll();
    }
  });
  document.getElementById('opt-launch-fullscreen')?.addEventListener('change', (e) => {
    options.launchFullscreen = !!e.target.checked;
    saveOptions();
  });
  document.getElementById('opt-zoom-motion')?.addEventListener('change', (e) => {
    options.zoomClipsToMotion = !!e.target.checked;
    saveOptions();
  });
  document.getElementById('opt-hotkeys-enabled')?.addEventListener('change', (e) => {
    options.hotkeysEnabled = !!e.target.checked;
    saveOptions();
    buildCameraList();                 // refresh the (hidden) list badges
    srvRenderHotkeys();
    srvSetHotkeysConfigVisible(options.hotkeysEnabled !== false); // collapse the remap UI when off
    if (els.viewLive && !els.viewLive.classList.contains('hidden')) buildTileGrid(); // tile badges on/off
  });
  document.getElementById('opt-wall-sub')?.addEventListener('change', (e) => {
    const wantSub = !!e.target.checked;
    const target  = wantSub ? 'sub-streams (lower bandwidth)' : 'main streams (full quality)';
    // Per-camera right-click stream choices previously SURVIVED this toggle, so
    // flipping it appeared to do nothing for overridden cameras. Gate with a
    // confirm, then clear those overrides so the whole wall really follows the new
    // default — matching the "this resets all streams" expectation.
    const overrideCount = Object.keys(streamPref || {}).length;
    const extra = overrideCount
      ? ` This also clears ${overrideCount} per-camera stream choice${overrideCount === 1 ? '' : 's'} you set by right-clicking.`
      : '';
    if (!window.confirm(`Switch the entire wall to ${target}? All live panes will reload.${extra}`)) {
      e.target.checked = options.liveWallSub !== false; // revert the checkbox
      return;
    }
    options.liveWallSub = wantSub;
    streamPref = {}; // every tile now follows the wall default
    try { localStorage.setItem(LS_STREAM_PREF, JSON.stringify(streamPref)); } catch { /* quota */ }
    saveOptions();
    if (!els.viewLive.classList.contains('hidden')) syncPanes(); // re-resolve wall streams now
  });
  document.getElementById('opt-maximize-main')?.addEventListener('change', (e) => {
    options.maximizeMain = !!e.target.checked;
    saveOptions();
    if (!els.viewLive.classList.contains('hidden')) syncPanes();
  });
  document.getElementById('opt-show-allcams')?.addEventListener('change', (e) => {
    options.showAllCamerasView = !!e.target.checked;
    saveOptions();
    buildLayoutPresets(); // show/hide the All Cameras button immediately
  });
  document.querySelectorAll('input[name="opt-ptz-click"]').forEach(radio => {
    radio.addEventListener('change', (e) => {
      if (!e.target.checked) return;
      const v = e.target.value;
      options.ptzClickMode = (v === 'pan' || v === 'off') ? v : 'center';
      saveOptions();
      applyPtzClickMode();
    });
  });
  document.querySelectorAll('input[name="opt-ptz-style"]').forEach(radio => {
    radio.addEventListener('change', (e) => {
      if (!e.target.checked) return;
      options.ptzStyle = e.target.value === 'wheel' ? 'wheel' : 'edges';
      saveOptions();
      ptzOverlayReposition(); // redraw the active overlay in the chosen style
    });
  });
  document.getElementById('opt-ptz-wheel-corner')?.addEventListener('change', (e) => {
    options.ptzWheelCorner = e.target.value;
    saveOptions();
    ptzOverlayReposition(); // re-pin the wheel to the chosen corner
  });

  // ── View Setup (custom layout builder) wiring ─────────────────────────────

  document.getElementById('toolbar-setup-view-btn').addEventListener('click', vsOpen);
  document.getElementById('vs-close-btn').addEventListener('click', vsClose);
  document.getElementById('vs-cancel-btn').addEventListener('click', vsClose);
  document.getElementById('vs-backdrop').addEventListener('click', vsClose);
  // Apply commits the layout to the live wall but KEEPS the editor open so the
  // operator can keep tweaking; only Save (vsSaveAsView) closes the window.
  document.getElementById('vs-apply-btn').addEventListener('click', () => {
    if (vsApply()) vsSetError('');
  });
  document.getElementById('vs-save-btn').addEventListener('click', () => { void vsSaveAsView(); });

  document.getElementById('vs-cols-minus').addEventListener('click', () => vsSetDims(vsState.cols - 1, vsState.rows));
  document.getElementById('vs-cols-plus').addEventListener('click',  () => vsSetDims(vsState.cols + 1, vsState.rows));
  document.getElementById('vs-rows-minus').addEventListener('click', () => vsSetDims(vsState.cols, vsState.rows - 1));
  document.getElementById('vs-rows-plus').addEventListener('click',  () => vsSetDims(vsState.cols, vsState.rows + 1));

  document.querySelectorAll('.vs-tmpl-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const name = btn.dataset.tmpl;
      if (!name) return; // "Clear all" shares this button class but is wired separately
      if (name === 'reset') { vsState.cells = vsUnitCells(vsState.cols, vsState.rows); vsRender(); return; }
      const tmpl = vsTemplate(name);
      if (tmpl) {
        // Keep camera assignments (by position) + the icon/edited-view across a
        // template switch.
        vsState = { ...tmpl, drag: null, assign: vsState.assign, dragCam: null,
          selectedIcon: vsState.selectedIcon || '🎥', loadedViewId: vsState.loadedViewId || null };
        vsRender();
        vsRenderCameraList();
      }
    });
  });

  // "Clear all" — wipe every camera assignment AND reset the layout to a plain grid.
  document.getElementById('vs-clear-all')?.addEventListener('click', vsClearAll);
  document.getElementById('vs-edit-layout-btn')?.addEventListener('click', () => vsSetEditLayout(!vsEditLayout));

  // End a drag anywhere (pointer may release outside the grid).
  window.addEventListener('pointerup', vsPointerUp);

  // ── Motion Tuner wiring (now an INLINE panel in Settings → Motion tuning) ──
  document.getElementById('mt-clear-btn')?.addEventListener('click', () => {
    mtState.excluded.clear();
    mtDrawGrid();
  });
  document.getElementById('mt-save-btn')?.addEventListener('click', () => { void mtSave(); });
  const mtCanvas = document.getElementById('mt-canvas');
  mtCanvas?.addEventListener('pointerdown', mtPointerDown);
  mtCanvas?.addEventListener('pointermove', mtPointerMove);
  window.addEventListener('pointerup', mtPointerUp);
  // Right-drag erases exclusions — suppress the browser context menu on the grid.
  mtCanvas?.addEventListener('contextmenu', e => e.preventDefault());
  // Motion-tuner grid-size dropdown (exclusion authoring resolution). Persists
  // the choice per camera so the tuner reopens at the grid the user last picked.
  document.getElementById('mt-grid-size')?.addEventListener('change', (e) => {
    const [c, r] = String(e.target.value).split(',').map(Number);
    if (c && r) { mtSetGridDims(c, r); void mtPersistGrid(c, r); }
  });
  // Motion source / algorithm pickers — persist immediately to the camera.
  document.getElementById('mt-motion-source')?.addEventListener('change', () => {
    mtSyncMotionSource();
    void mtApplyMotionConfig();
  });
  document.getElementById('mt-motion-algo')?.addEventListener('change', () => {
    mtSyncMotionSource();
    void mtApplyMotionConfig();
  });
  // Motion-tuner threshold slider (Manual) + Auto (Dynamic) toggle.
  const mtThr = document.getElementById('mt-thresh-slider');
  const mtAuto = document.getElementById('mt-thresh-auto');
  mtThr?.addEventListener('input', () => {
    const pct = Number(mtThr.value);     // slider is in % of frame (min object size)
    mtState.threshold = pct / 100;       // store the canonical FRACTION (0..1)
    mtState.sensitivity = 'manual';     // adjusting the slider implies Manual
    if (mtAuto) mtAuto.checked = false;
    mtThr.disabled = false;
    const val = document.getElementById('mt-thresh-val'); if (val) val.textContent = `${pct.toFixed(2)}%`;
    mtRenderMeter();                     // move the meter marker live
  });
  mtThr?.addEventListener('change', () => { void mtApplyThreshold(); }); // persist on release
  mtAuto?.addEventListener('change', () => {
    if (mtAuto.checked) {
      mtState.sensitivity = 'dynamic';
      if (mtThr) mtThr.disabled = true;
    } else {
      mtState.sensitivity = 'manual';
      if (mtThr) { mtThr.disabled = false; mtState.threshold = Number(mtThr.value) / 100; } // slider % → fraction
    }
    mtRenderMeter();
    void mtApplyThreshold();
  });
  window.addEventListener('resize', () => {
    if (mtInlineActive()) {
      mtResizeCanvas();
      mtDrawGrid();
    }
  });

  // ── Context menu: close on outside-click, Escape, scroll ─────────────────

  document.addEventListener('click', (e) => {
    const menu = document.getElementById('ctx-menu');
    if (menu && !menu.contains(e.target)) ctxClose();
  });

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') ctxClose();
  });

  // Close on page scroll, but NOT when the scroll happens inside the menu itself
  // (the camera submenu is scrollable — wheeling it must not dismiss the menu).
  document.addEventListener('scroll', (e) => {
    const menu = document.getElementById('ctx-menu');
    if (menu && e.target instanceof Node && menu.contains(e.target)) return;
    ctxClose();
  }, true);

  // ── Tauri pane-rightclick: native panes forward right-clicks here ─────────
  listen('pane-rightclick', (e) => {
    // payload = { id: 'slotN', x: physicalPx, y: physicalPx }
    const slot = paneIdToSlot(e.payload.id);
    if (slot === null) return;

    const tile = getTileEl(slot);
    const r   = tile ? tile.getBoundingClientRect() : null;
    const dpr = window.devicePixelRatio || 1;
    // payload x/y are pane-client px (pane origin is below the title strip),
    // so add the strip offset to map back into tile/viewport coordinates.
    const menuX = (r ? r.left : 0) + e.payload.x / dpr;
    const menuY = (r ? r.top : 0) + tileStripPx() + e.payload.y / dpr;

    // While customizing this camera's PTZ panel, right-click acts on the button
    // under the cursor (rename/resize/delete) instead of the camera menu.
    if (ptzEditMode && ptzEditCam === ptzCameraId && slot === ptzActiveSlot()) {
      ptzEditContextMenu(slot, menuX, menuY, e.payload.x, e.payload.y);
      return;
    }

    selectSlot(slot, { routeHotspot: false }); // right-click = open menu, don't re-route hotspot
    if (!tile) { ctxOpen(slot, e.payload.x, e.payload.y); return; }
    ctxOpen(slot, menuX, menuY);
  });

  // Legacy stub — keep the old #save-view-btn wired so nothing throws if the
  // hidden stub element exists (it does, display:none in HTML).
  const legacySaveBtn = document.getElementById('save-view-btn');
  if (legacySaveBtn) {
    legacySaveBtn.addEventListener('click', () => {
      const name = window.prompt('Name this view:');
      if (name && name.trim()) saveView(name.trim());
    });
  }

  // ── In-view PTZ overlay wiring (compact strip cluster: Home / zoom / presets) ─
  // The PTZ wheel (8-direction joystick + center Home), built once and wired
  // here. It lives in a notch carved from the lower-left of the active PTZ tile.
  wirePtzWheel();

  // Resize sync: also watch the playback tile grid
  ro.observe(els.pbTileGrid);

  // Timeline canvas pointer events
  els.pbTimeline.addEventListener('pointerdown', pbTimelinePointerDown);
  els.pbTimeline.addEventListener('pointermove', pbTimelinePointerMove);
  els.pbTimeline.addEventListener('pointerup',   pbTimelinePointerUp);
  els.pbTimeline.addEventListener('pointercancel', pbTimelinePointerUp);
  els.pbTimeline.addEventListener('pointerleave', pbHideMotionHint);
  // Wheel zoom — passive:false so we can preventDefault (stops page scroll)
  els.pbTimeline.addEventListener('wheel', pbTimelineWheel, { passive: false });
  // Right-click → export-range selection menu (#9)
  els.pbTimeline.addEventListener('contextmenu', pbTimelineContextMenu);

  // Frame-step buttons (adjacent to play/pause) + zoom controls + timeline legend
  pbInjectFrameStepButtons();
  pbInjectZoomButtons();
  pbInjectTimelineLegend();

  // Export dialog event wiring. (The transport-bar Export button is gone — Export
  // now has its own top-level tab after Playback; see activateTab.)
  exportWireEvents();

  // Keyboard shortcuts active only when playback tab visible
  document.addEventListener('keydown', pbHandleKey);

  // ── Restore session from localStorage ────────────────────────────────────

  const savedToken  = await loadToken(); // DPAPI-decrypted on Windows (H4)
  const savedServer = localStorage.getItem(LS_SERVER_KEY);

  // Prefill the login form from remembered values (server + username + the
  // "keep me signed in" preference) regardless of whether a token survives.
  const savedUser = localStorage.getItem(LS_USER_KEY);
  const savedRemember = localStorage.getItem(LS_REMEMBER_KEY);
  if (savedServer && els.loginServer) els.loginServer.value = savedServer;
  if (savedUser && els.loginUser) els.loginUser.value = savedUser;
  if (els.loginRemember && savedRemember != null) els.loginRemember.checked = savedRemember !== '0';

  if (savedToken && savedServer) {
    state.token  = savedToken;
    state.server = savedServer;
    // Pre-fill server field in case user needs to re-login later
    els.loginServer.value = savedServer;
    setStatus('Resuming session…');
    try {
      await loadCamerasAndStart();
    } catch (e) {
      // loadCamerasAndStart handles its own errors; this is a belt-and-suspenders catch
      showLogin('Session restore failed — please sign in again.');
    }
  } else {
    // Pre-fill saved server URL if any (no token though)
    if (savedServer) els.loginServer.value = savedServer;
    showLogin();
    setStatus('Ready — please sign in.');
  }
});

// =============================================================================
// PLAYBACK MODULE
// =============================================================================
//
// Architecture:
//   - pb (playback) state lives in `pbState` separate from live `state`.
//   - The playback tile grid (#pb-tile-grid) is a sibling to #tile-grid and
//     uses the same .tile-grid / .layout-* CSS classes.
//   - One playhead drives all panes. A 1-second rAF tick advances the
//     playhead and re-syncs panes when they exhaust their segment.
//   - Timeline is drawn on a <canvas> with pointer-event-based scrubbing.
//
// Color palette (the commercial VMS-inspired):
//   recorded = #2b5aa8   motion overlay = #f59e0b
//   track    = #22304f   gridlines      = #2a3a5c
//   playhead = #e6eaf2
// =============================================================================

// ── Playback state ────────────────────────────────────────────────────────────

const SPEEDS = [0.5, 1, 2, 4, 8];

// Zoom steps: window durations in ms (2 min → 24 h)
const PB_ZOOM_STEPS = [
  2 * 60_000,        // 2 min
  5 * 60_000,        // 5 min
  15 * 60_000,       // 15 min
  30 * 60_000,       // 30 min
  60 * 60_000,       // 1 h
  3 * 3600_000,      // 3 h
  6 * 3600_000,      // 6 h
  12 * 3600_000,     // 12 h
  24 * 3600_000,     // 24 h
];

const pbState = {
  /** Window bounds displayed on the timeline (epoch ms) */
  windowStartMs: 0,
  windowEndMs: 0,
  /** Current playhead position (epoch ms) */
  playheadMs: 0,
  /** True while playing */
  playing: false,
  /** Speed multiplier index into SPEEDS */
  speedIdx: 1,
  /** Merged timeline spans from /timeline: [{start,end,has_motion,camera_id}] */
  spans: [],
  /** Slot whose camera owns the prominent (upper) timeline track (#3). */
  selectedSlot: 0,
  /** Maximized slot index (double-click a tile), or null for the full grid.
   *  Mirrors the live wall's state.maximized but playback-scoped. */
  maximizedSlot: null,
  /** True once playback has been entered this session — gates the snap-to-now
   *  so re-entry (tab switch) preserves the operator's investigation position. */
  everEntered: false,
  /** Active export-range selection { startMs, endMs } or null (#9). */
  exportSel: null,
  /** Selected-camera motion intensity { camId, startMs, endMs, buckets:[0..1] } | null. */
  intensity: null,
  /** Per-camera motion intensity for EVERY camera in the playback grid, keyed by
   *  camera id: { [camId]: { camId, startMs, endMs, bucketMs, buckets:[0..1] } }.
   *  The selected camera is drawn prominent; the rest are faded on the same track
   *  so cross-camera activity stays visible (commercial-VMS model). */
  intensityByCam: {},
  /** Frigate detection events for the loaded window — [{camera_id, ms, key}].
   *  Drawn as per-type glyphs on the timeline for the SELECTED camera. */
  detections: [],
  /**
   * Per-slot segment info:
   *   Map<slotIndex, { cameraId, segmentUrl, segStartMs, segEndMs, segDurationMs } | null>
   *   null means no footage at current time for that slot.
   */
  slotSegments: new Map(),
  /** Per-slot PREFETCHED next segment (P1): same shape as slotSegments values.
   *  Populated ~1 s before the current segment ends so the boundary swap has no
   *  HTTP round-trip on the critical path (kills the per-segment playback hitch). */
  slotNextSeg: new Map(),
  /** rAF tick handle */
  tickHandle: null,
  /** Timestamp of the last tick (for wall-clock delta) */
  lastTickWall: 0,
  /** Whether the timeline pointer is down */
  timelineDragging: false,
  /** Play state captured at drag-start (so we can restore it) */
  wasPlayingBeforeDrag: false,
  /** Debounce timer for scrub seek */
  scrubTimer: null,

  // ── Pan state ──────────────────────────────────────────────────────────────
  /** clientX at pointerdown */
  panStartX: 0,
  /** windowStartMs captured at pointerdown */
  panStartWindowStartMs: 0,
  /** windowEndMs captured at pointerdown */
  panStartWindowEndMs: 0,
  /** Cumulative horizontal movement since pointerdown (px) */
  panTotalDx: 0,
  /** True once movement exceeds the pan-detect threshold (4 px) */
  panIsPan: false,
  /** Debounce timer for pan → reload timeline + resolve panes */
  panReloadTimer: null,
};

function pbGetSpeed() { return SPEEDS[pbState.speedIdx]; }

/** The slots that currently own a native pane: just the maximized one if a tile
 *  is maximized, else every slot in the layout. Used by every pane op (sync /
 *  resolve / seek / speed / pause) so a maximized tile shows one full-screen
 *  camera and the rest are torn down (mirrors the live wall's maximize). */
function pbActiveSlots() {
  if (pbState.maximizedSlot !== null) return [pbState.maximizedSlot];
  const layout = getLayout();
  return Array.from({ length: layout.tiles }, (_, i) => i);
}

// ── API calls ─────────────────────────────────────────────────────────────────

/**
 * Fetch merged timeline spans for all cameras currently on the wall.
 * Returns the raw spans array or [] on error.
 */
async function pbFetchTimeline(cameraIds, startMs, endMs) {
  if (!cameraIds.length) return [];
  const startIso = new Date(startMs).toISOString();
  const endIso   = new Date(endMs).toISOString();
  const url = `${state.server}/timeline?camera_ids=${cameraIds.join(',')}&start=${encodeURIComponent(startIso)}&end=${encodeURIComponent(endIso)}`;
  try {
    const res = await fetchWithTimeout(url, { headers: authHeaders() });
    if (!res.ok) return [];
    const data = await res.json();
    return data.spans ?? [];
  } catch {
    return [];
  }
}

/**
 * Resolve the segment that covers time T (epoch ms) for a camera.
 * Returns a segment object or null (404 / no footage).
 */
async function pbFetchSegment(cameraId, tMs) {
  const tsIso = new Date(tMs).toISOString();
  const url = `${state.server}/play/${encodeURIComponent(cameraId)}?ts=${encodeURIComponent(tsIso)}&stream=main`;
  try {
    const res = await fetchWithTimeout(url, { headers: authHeaders() });
    if (!res.ok) return null;
    const seg = await res.json();
    // Build absolute media URL carrying a short-lived per-camera scoped token
    // (NOT the full login JWT — that would leak into the mpv pane's source + logs).
    // Resolve the token here, before the URL is handed to sync_panes/loadfile, so
    // the pane always receives a ready-to-play URL. Null on token failure → the
    // caller treats it as "no segment" and retries (which re-requests a token).
    const relUrl = seg.url ?? '';
    seg.absoluteUrl = await mediaUrlForCamera(cameraId, relUrl);
    if (!seg.absoluteUrl) return null;
    seg.startMs = new Date(seg.start).getTime();
    seg.endMs   = new Date(seg.end).getTime();
    return seg;
  } catch {
    return null;
  }
}

/** P1: prefetch the NEXT segment for a slot (the one starting at the current
 *  segment's end) into pbState.slotNextSeg, so crossing the boundary during
 *  playback only costs a loadfile — no /play/ HTTP round-trip on the hot path.
 *  Idempotent + de-duped; silently no-ops if there's nothing to prefetch. */
async function pbPrefetchNextSegment(slot) {
  const cur = pbState.slotSegments.get(slot);
  if (!cur || !cur.cameraId) return;
  const have = pbState.slotNextSeg.get(slot);
  if (have && have.segStartMs >= cur.segEndMs) return; // already prefetched the next one
  if (!pbState._prefetching) pbState._prefetching = new Set();
  if (pbState._prefetching.has(slot)) return;          // a fetch is already in flight
  pbState._prefetching.add(slot);
  try {
    const seg = await pbFetchSegment(cur.cameraId, cur.segEndMs + 1);
    // Keep only if it's genuinely a LATER segment (guard against the API returning
    // the same/overlapping one near the boundary).
    if (seg && seg.startMs >= cur.segEndMs - 250) {
      pbState.slotNextSeg.set(slot, {
        cameraId: cur.cameraId,
        segmentUrl: seg.absoluteUrl,
        segStartMs: seg.startMs,
        segEndMs:   seg.endMs,
        segDurationMs: seg.duration_ms ?? (seg.endMs - seg.startMs),
      });
      void invoke('append_pane_next', { id: 'slot' + slot, url: seg.absoluteUrl }).catch(() => {});
    }
  } catch { /* ignore — the boundary resolve will fall back to a live fetch */ }
  finally { pbState._prefetching.delete(slot); }
}

// ── Playback tile selection (drives the prominent timeline track, #3) ─────────

/** Choose a default selected slot: live selection if it has a camera, else the
 *  first slot that does, else 0. */
function pbResolveDefaultSelectedSlot() {
  if (state.slotMap.get(state.selectedSlot)) return state.selectedSlot;
  const layout = getLayout();
  for (let i = 0; i < layout.tiles; i++) {
    if (state.slotMap.get(i)) return i;
  }
  return 0;
}

/** Select a playback slot — its camera's motion becomes the prominent track. */
function pbSelectSlot(slot) {
  if (slot === pbState.selectedSlot) return;
  pbState.selectedSlot = slot;
  document.querySelectorAll('#pb-tile-grid .tile').forEach(t => {
    t.classList.toggle('selected', parseInt(t.dataset.slot, 10) === slot);
  });
  // Re-point the prominent track at the newly-selected camera's already-fetched
  // intensity (instant); the faded other-camera tracks persist. A refetch only
  // happens if this camera isn't cached at the current resolution.
  const newCamId = state.slotMap.get(slot) ?? null;
  pbState.intensity = newCamId ? (pbState.intensityByCam[newCamId] ?? null) : null;
  pbDrawTimeline();
  void pbFetchIntensity();
}

// ── Tile grid (playback) ──────────────────────────────────────────────────────

/**
 * Build the #pb-tile-grid with the same layout/slot assignment as the live wall.
 * Tiles are identical in structure to the live wall; JS assigns label dots
 * via the #pb-tile-grid scoped CSS rule (amber, not live-blue).
 */
function pbBuildTileGrid() {
  const grid = els.pbTileGrid;
  grid.innerHTML = '';
  startClockTicker(); // clock view-items tick in playback too (no-op if none)

  // Inherit the LIVE layout + camera assignments (getLayout()/state.slotMap),
  // including custom (freeform) layouts.
  LAYOUTS.forEach(l => grid.classList.remove(l.cls));
  grid.classList.remove('layout-custom');
  grid.style.gridTemplateColumns = '';
  grid.style.gridTemplateRows = '';

  // Maximized: render a single full-area tile for that slot (mirrors live).
  if (pbState.maximizedSlot !== null) {
    grid.classList.add('layout-1x1');
    const slot = pbState.maximizedSlot;
    const tile = pbBuildTileElement(slot, state.slotMap.get(slot) ?? null);
    grid.appendChild(tile);
    requestAnimationFrame(() => pbSyncPanes());
    return;
  }

  const layout = getLayout();
  grid.classList.add(layout.cls);

  if (layout.custom) {
    const cl = layout.custom;
    grid.style.gridTemplateColumns = `repeat(${cl.cols}, 1fr)`;
    grid.style.gridTemplateRows = `repeat(${cl.rows}, 1fr)`;
    cl.cells.forEach((cell, i) => {
      const cameraId = state.slotMap.get(i) ?? null;
      const tile = pbBuildTileElement(i, cameraId);
      tile.style.gridColumn = `${cell.x + 1} / span ${cell.w}`;
      tile.style.gridRow = `${cell.y + 1} / span ${cell.h}`;
      grid.appendChild(tile);
    });
  } else {
    for (let i = 0; i < layout.tiles; i++) {
      const cameraId = state.slotMap.get(i) ?? null;
      const tile = pbBuildTileElement(i, cameraId);
      grid.appendChild(tile);
    }
  }

  // After layout paint, sync panes
  requestAnimationFrame(() => pbSyncPanes());
}

/** Toggle maximize for a playback slot (double-click). Mirrors the live wall's
 *  handleTileDoubleClick but operates on pbState + re-resolves the visible pane. */
function pbHandleTileDoubleClick(slot) {
  if (pbState.maximizedSlot !== null) {
    pbState.maximizedSlot = null;
  } else {
    if (!state.slotMap.get(slot)) return; // empty tile — nothing to maximize
    pbState.maximizedSlot = slot;
    pbSelectSlot(slot); // the maximized camera drives the prominent timeline track
  }
  pbBuildTileGrid();
  // Force a resolve so the now-sole visible pane has its segment + correct seek
  // (on restore, this re-resolves every camera the grid brings back).
  pbResolveAllPanes(pbState.playheadMs, true);
}

/** Playback render of a DOM view-item: clock/text/image/web/detections behave the
 *  same as live; a PTZ tile shows an "inactive in playback" placeholder. */
function pbBuildDomTileElement(slotIndex, spec) {
  const tile = document.createElement('div');
  tile.className = ['tile', 'has-camera', 'tile-item', `tile-item-${spec.type}`,
    slotIndex === pbState.selectedSlot ? 'selected' : ''].filter(Boolean).join(' ');
  tile.dataset.slot = slotIndex;
  let inner = '';
  if (spec.type === 'ptz') {
    const cam = camById(spec.cameraId);
    inner = `<div class="tile-ptz tile-ptz-inactive"><div class="tile-ptz-head"><span class="tile-ptz-ico">🕹</span><span class="tile-ptz-cam">${cam ? escHtml(cam.name) : 'PTZ'}</span></div><div class="tile-item-empty"><span>PTZ inactive in playback</span></div></div>`;
  } else if (spec.type === 'image') {
    inner = spec.dataUrl ? `<img class="tile-image" src="${spec.dataUrl}" alt="">` : `<div class="tile-item-empty">🖼<span>No image</span></div>`;
  } else if (spec.type === 'clock') {
    inner = `<div class="tile-clock"><div class="tile-clock-time" data-clock="time">--:--:--</div><div class="tile-clock-date" data-clock="date"></div></div>`;
  } else if (spec.type === 'text') {
    inner = `<div class="tile-text" style="${spec.size ? `font-size:${Math.max(10, Math.min(72, spec.size | 0))}px` : ''}">${escHtml(spec.text || '').replace(/\n/g, '<br>')}</div>`;
  } else if (spec.type === 'events') {
    inner = `<div class="tile-events" data-events="1"><div class="tile-events-head">DETECTIONS</div><div class="tile-events-list" data-events-list="1"><div class="tile-events-empty">Waiting for detections…</div></div></div>`;
  } else if (spec.type === 'web') {
    inner = spec.url ? `<iframe class="tile-web" src="${escHtml(spec.url)}" sandbox="allow-scripts allow-same-origin allow-forms allow-popups" referrerpolicy="no-referrer"></iframe>` : `<div class="tile-item-empty">🌐<span>No URL</span></div>`;
  }
  tile.innerHTML = inner;
  if (spec.type === 'events') wireEventTile(tile); // clicking an event jumps the playhead
  tile.addEventListener('click', () => pbSelectSlot(slotIndex));
  tile.addEventListener('dblclick', () => pbHandleTileDoubleClick(slotIndex));
  return tile;
}

function pbBuildTileElement(slotIndex, cameraId) {
  // DOM view-items (clock/text/image/web/detections/PTZ) render their own content.
  const itemSpec = state.slotItems.get(slotIndex);
  if (itemSpec && !VIDEO_TILE_TYPES.has(itemSpec.type)) {
    return pbBuildDomTileElement(slotIndex, itemSpec);
  }
  const cam = cameraId ? camById(cameraId) : null;

  const tile = document.createElement('div');
  tile.className = ['tile', cam ? 'has-camera' : '',
    slotIndex === pbState.selectedSlot ? 'selected' : ''].filter(Boolean).join(' ');
  tile.dataset.slot = slotIndex;

  // Click selects this slot (its camera drives the prominent timeline track).
  // Native panes cover the video, so this DOM click only fires on the strip /
  // empty area; the pane-click handler routes video clicks here in playback.
  tile.addEventListener('click', () => pbSelectSlot(slotIndex));
  // Double-click maximizes / restores (video dblclicks arrive via pane-dblclick).
  tile.addEventListener('dblclick', () => pbHandleTileDoubleClick(slotIndex));

  // Title strip (same as live, minus the live REC/motion dots — those are a
  // "now" concept; in playback the camera's motion is shown on the timeline).
  const showStrip = options.showInfoBar && !!cam;
  const stripHtml = showStrip ? `
    <div class="tile-strip" data-cam="${cam.id}" style="height:${TILE_STRIP_PX}px">
      <span class="tile-strip-name">${escHtml(cam.name)}</span>
      ${(() => { const t = cam && hotkeyForCamera(cam.id); return t ? `<span class="tile-strip-num" title="Hotkey — press ${escHtml(hotkeyLabel(t))} to load this camera">${escHtml(hotkeyLabel(t))}</span>` : ''; })()}
    </div>` : '';

  tile.innerHTML = `
    ${stripHtml}
    ${!showStrip ? (cam
      ? (() => { const t = hotkeyForCamera(cam.id); return t ? `<span class="tile-slot-num">${escHtml(hotkeyLabel(t))}</span>` : ''; })()
      : `<span class="tile-slot-num">${slotIndex + 1}</span>`) : ''}
    <div class="tile-empty-hint">
      <svg class="tile-empty-icon" width="24" height="18" viewBox="0 0 24 18" fill="none">
        <rect x="1" y="3" width="15" height="14" rx="1.5" stroke="currentColor" stroke-width="1.2"/>
        <path d="M16 8l6-4v10l-6-4z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>
      </svg>
      <span class="tile-empty-text">no footage</span>
      ${cam ? `<span class="tile-empty-text tile-empty-cam">${escHtml(cam.name)}</span>` : ''}
    </div>
  `;

  return tile;
}

// ── Pane sync (playback) ──────────────────────────────────────────────────────

/**
 * Build sync_panes spec from pbState.slotSegments and call invoke.
 * Slots with null segment are excluded (no pane shown = black tile).
 */
async function pbSyncPanes() {
  if (modalOpen > 0) return; // don't paint panes over an open modal
  const grid = els.pbTileGrid;
  const paneSpecs = [];

  // pbActiveSlots() = [maximizedSlot] when maximized, else every layout slot —
  // so a maximized tile paints one full pane and the rest are reconciled away.
  for (const i of pbActiveSlots()) {
    const seg = pbState.slotSegments.get(i);
    if (!seg) continue; // no footage — leave tile empty
    const el = grid.querySelector(`.tile[data-slot="${i}"]`);
    if (!el) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) continue;
    const strip = tileStripPx();
    // preserve_zoom: a segment advance is the SAME camera's next file, so the
    // native pane must keep the operator's digital zoom/pan instead of snapping
    // back to full frame on every ~1-minute boundary. A camera SWITCH in the slot
    // (e.g. a bookmark/detection jump) must start at full frame, so reset the zoom.
    const sameCam = pbPaneCam.get(i) === seg.cameraId;
    pbPaneCam.set(i, seg.cameraId);
    paneSpecs.push({ id: `slot${i}`, url: seg.segmentUrl, x: r.x, y: r.y + strip, w: r.width, h: r.height - strip, preserve_zoom: sameCam });
  }

  try {
    // sync_panes returns each pane's post-sync zoom (fresh/reset → 0, preserved →
    // the kept value). Mirror it so the drag = grab-to-pan gating stays accurate.
    const zooms = await invoke('sync_panes', { panes: paneSpecs });
    if (Array.isArray(zooms)) {
      const present = new Set(zooms.map(z => z.id));
      for (const z of zooms) paneZoom.set(z.id, z.zoom);
      for (const id of [...paneZoom.keys()]) {
        if (id.startsWith('slot') && !present.has(id)) paneZoom.delete(id);
      }
    }
  } catch (e) {
    console.error('pbSyncPanes: sync_panes failed:', e);
  }
}

// ── Segment resolution + load ─────────────────────────────────────────────────

/**
 * Resolve the correct segment for every slotted camera at time tMs,
 * update pbState.slotSegments, call sync_panes, then seek each pane.
 *
 * @param {number} tMs - epoch ms of the target playhead position
 * @param {boolean} forceReload - always re-fetch segments (vs. only when segment changes)
 */
// Serialize ALL pane resolves through one in-flight slot, coalescing to the latest
// request. Overlapping resolves (the playback tick + a scrub + a jump firing at
// once) used to interleave sync_panes loadfiles + seeks on the native mpv panes and
// wedge them BLACK ("scroll around playback a bunch → black until you leave + re-
// enter the tab"). Running one at a time removes the interleave; `await` still
// resolves once the panes reflect the latest requested time (coalesced callers
// await the in-flight cycle, which processes their request or a newer one).
async function pbResolveAllPanes(tMs, forceReload = false) {
  pbState._resolveNext = {
    tMs,
    forceReload: forceReload || (pbState._resolveNext?.forceReload ?? false),
  };
  if (pbState._resolveBusy) return pbState._resolveDone;
  pbState._resolveBusy = true;
  let done;
  pbState._resolveDone = new Promise((r) => {
    done = r;
  });
  try {
    while (pbState._resolveNext) {
      const next = pbState._resolveNext;
      pbState._resolveNext = null;
      // eslint-disable-next-line no-await-in-loop -- intentional: one resolve at a time
      await pbResolveAllPanesInner(next.tMs, next.forceReload);
    }
  } finally {
    pbState._resolveBusy = false;
    done();
  }
}

async function pbResolveAllPanesInner(tMs, forceReload = false) {
  const segFetches = [];
  // A forced resolve is a jump/seek — the linear look-ahead prefetch is invalidated.
  if (forceReload) pbState.slotNextSeg.clear();

  // Only resolve the slots that currently own a pane (the maximized one, or all).
  for (const i of pbActiveSlots()) {
    const cameraId = state.slotMap.get(i);
    if (!cameraId) {
      segFetches.push(Promise.resolve({ slot: i, seg: null }));
      continue;
    }

    const existing = pbState.slotSegments.get(i);
    // Skip re-fetch if the existing segment still covers tMs and we're not forcing
    if (!forceReload && existing &&
        tMs >= existing.segStartMs && tMs < existing.segEndMs) {
      segFetches.push(Promise.resolve({ slot: i, seg: existing, cached: true }));
      continue;
    }

    // P1: crossing a boundary — use the prefetched next segment if it covers tMs,
    // so the swap costs only a loadfile, no /play/ HTTP round-trip.
    const pre = pbState.slotNextSeg.get(i);
    if (!forceReload && pre && tMs >= pre.segStartMs && tMs < pre.segEndMs) {
      pbState.slotNextSeg.delete(i); // consume it
      segFetches.push(Promise.resolve({ slot: i, seg: pre, gapless: true }));
      continue;
    }

    segFetches.push(
      pbFetchSegment(cameraId, tMs).then(seg => {
        if (!seg) return { slot: i, seg: null };
        return {
          slot: i,
          seg: {
            cameraId,
            segmentUrl: seg.absoluteUrl,
            segStartMs: seg.startMs,
            segEndMs:   seg.endMs,
            segDurationMs: seg.duration_ms ?? (seg.endMs - seg.startMs),
          },
        };
      })
    );
  }

  const results = await Promise.all(segFetches);

  // Determine which panes need a new URL pushed via sync_panes (gapless
  // boundary advances are handled by mpv's playlist, not a loadfile).
  const needsSync = results.some(r => {
    if (r.gapless) return false;
    const existing = pbState.slotSegments.get(r.slot);
    if (!r.seg && !existing) return false;
    if (!r.seg || !existing) return true;
    return r.seg.segmentUrl !== existing.segmentUrl;
  });

  // Update state
  results.forEach(r => pbState.slotSegments.set(r.slot, r.seg ?? null));

  // Advance gapless panes: mpv's playlist already has the next entry appended
  // (prefetch-playlist demuxed it), so playlist-next transitions with the
  // decoder already warm — no re-init stutter.
  const advanceOps = results.filter(r => r.gapless).map(r =>
    invoke('advance_pane', { id: `slot${r.slot}`, url: r.seg.segmentUrl }).catch(e => {
      console.warn(`advance_pane slot${r.slot} failed:`, e);
    })
  );
  if (advanceOps.length) await Promise.all(advanceOps);

  // Update tile "no footage" styling
  const grid = els.pbTileGrid;
  results.forEach(r => {
    const tile = grid.querySelector(`.tile[data-slot="${r.slot}"]`);
    if (!tile) return;
    if (r.seg) {
      tile.classList.remove('pb-no-footage');
      tile.classList.add('has-camera');
    } else {
      tile.classList.add('pb-no-footage');
      tile.classList.remove('has-camera');
    }
  });

  // P4: only touch mpv when a segment changed (needsSync) or this is an explicit
  // jump (forceReload). A plain boundary tick where everything is still cached needs
  // no IPC at all — the panes already hold the right offset/speed/paused, so skip the
  // 3×N redundant seek/speed/paused round-trips per segment-boundary tick.
  const mustSeek = needsSync || forceReload;
  if (mustSeek) {
    if (needsSync) await pbSyncPanes();

    // Seek panes to the correct offset within their segment. On a forceReload (jump)
    // also seek CACHED panes — the jump moved the playhead within the same file.
    const seekOps = [];
    results.forEach(r => {
      if (!r.seg) return;
      if (!forceReload && r.cached) return;
      if (r.gapless) return;
      const offsetSec = Math.max(0, (tMs - r.seg.segStartMs) / 1000);
      seekOps.push(
        invoke('seek_pane', { id: `slot${r.slot}`, seconds: offsetSec }).catch(e => {
          console.warn(`seek_pane slot${r.slot} failed:`, e);
        })
      );
    });
    if (seekOps.length) await Promise.all(seekOps);

    // A freshly loaded file resets to speed 1 / playing — re-assert our state. (On a
    // pure in-segment jump no file loaded, so speed/paused are already correct.)
    if (needsSync) {
      await pbApplySpeedToAllPanes();
      await pbApplyPausedToAllPanes();
    }
  }
}

/**
 * Called during scrubbing — same as pbResolveAllPanes but also seeks cached panes
 * because the user has moved the playhead within the same segment.
 */
async function pbSeekAllPanes(tMs) {
  const seekOps = [];

  for (const i of pbActiveSlots()) {
    const seg = pbState.slotSegments.get(i);
    if (!seg) continue;

    if (tMs >= seg.segStartMs && tMs < seg.segEndMs) {
      // Same segment — cheap keyframe-snap seek (P3): the scrub hot path doesn't need
      // exact-frame accuracy, and keyframe seeks are far cheaper on H.264/H.265.
      const offsetSec = Math.max(0, (tMs - seg.segStartMs) / 1000);
      seekOps.push(
        invoke('seek_pane', { id: `slot${i}`, seconds: offsetSec, keyframe: true }).catch(() => {})
      );
    }
    // else: out of segment range — full re-resolve will be triggered by pbResolveAllPanes
  }

  if (seekOps.length) await Promise.all(seekOps);
}

async function pbApplySpeedToAllPanes() {
  const speed = pbGetSpeed();
  const ops = [];
  for (const i of pbActiveSlots()) {
    if (!pbState.slotSegments.get(i)) continue;
    ops.push(invoke('set_pane_speed', { id: `slot${i}`, speed }).catch(() => {}));
  }
  if (ops.length) await Promise.all(ops);
}

async function pbApplyPausedToAllPanes() {
  const paused = !pbState.playing;
  const ops = [];
  for (const i of pbActiveSlots()) {
    if (!pbState.slotSegments.get(i)) continue;
    ops.push(invoke('set_pane_paused', { id: `slot${i}`, paused }).catch(() => {}));
  }
  if (ops.length) await Promise.all(ops);
}

// ── Playback tick ─────────────────────────────────────────────────────────────

/**
 * rAF tick: advances pbState.playheadMs by wall-clock delta * speed,
 * redraws timeline, re-resolves panes when they exhaust their segment.
 */
function pbTick(wallNow) {
  if (!pbState.playing) {
    pbState.tickHandle = requestAnimationFrame(pbTick);
    pbState.lastTickWall = wallNow;
    return;
  }

  const wallDelta = wallNow - pbState.lastTickWall;
  pbState.lastTickWall = wallNow;

  // Advance playhead (clamped to "now" — can't play into the future), then
  // recenter so the playhead stays fixed at center and time scrolls through it.
  const advance = wallDelta * pbGetSpeed();
  pbState.playheadMs = Math.min(pbState.playheadMs + advance, Date.now());
  pbRecenter();

  // The centered window scrolls as we play; refresh timeline spans + intensity
  // when it nears the loaded data's edges so the bands don't run out (review #3).
  if (pbState.spansLoadedStart === undefined ||
      pbState.windowStartMs < pbState.spansLoadedStart ||
      pbState.windowEndMs > pbState.spansLoadedEnd) {
    if (!pbState._spanReloadPending) {
      pbState._spanReloadPending = true;
      pbReloadTimeline().finally(() => { pbState._spanReloadPending = false; });
    }
  }

  // Update time display every frame (cheap string op)
  pbUpdateTimeDisplay();

  // Advance the playhead every frame (above, cheap), but throttle the full
  // timeline repaint to ~18fps. The per-frame full canvas clear + per-label
  // measureText + all-camera motion composite was the single hottest main-thread
  // cost during playback, running at the rAF rate (~60fps) while the underlying
  // data changes only a few times/sec (review S1).
  if (wallNow - (pbState.lastDrawWall || 0) >= 55) {
    pbState.lastDrawWall = wallNow;
    pbDrawTimeline();
  }

  // Every ~1000ms of wall time, check if any pane has exhausted its segment
  // We track this by checking if playheadMs is past a pane's segEndMs.
  // We do this check inside the tick but batch the async work so it doesn't block.
  let needsResolve = false;
  for (const i of pbActiveSlots()) {
    const seg = pbState.slotSegments.get(i);
    if (!seg) continue;
    // P1: prefetch the NEXT segment ~1 s before this one ends so the boundary swap
    // has no HTTP round-trip on the critical path (kills the per-segment hitch).
    if (pbState.playheadMs >= seg.segEndMs - 1000 && !pbState.slotNextSeg.get(i)) {
      void pbPrefetchNextSegment(i);
    }
    // At (or just before) the boundary, swap to the (now-prefetched) next segment.
    if (pbState.playheadMs >= seg.segEndMs - 100) needsResolve = true;
  }

  if (needsResolve && !pbState._resolvePending) {
    pbState._resolvePending = true;
    pbResolveAllPanes(pbState.playheadMs, false).finally(() => {
      pbState._resolvePending = false;
    });
  }

  // Pause at the live edge (caught up to now — nothing more to play).
  if (pbState.playheadMs >= Date.now() - 200) {
    pbState.playing = false;
    pbUpdatePlayPauseBtn();
    pbApplyPausedToAllPanes();
  }

  pbState.tickHandle = requestAnimationFrame(pbTick);
}

function pbStartTick() {
  if (pbState.tickHandle) return;
  pbState.lastTickWall = performance.now();
  pbState.tickHandle = requestAnimationFrame(pbTick);
  // Live refresh: re-fetch timeline spans + intensity every few seconds so newly
  // recorded footage appears on the scrubber WITHOUT the operator having to move
  // it (the rAF tick only advances/reloads during playback). Skipped while
  // dragging, while a reload is in flight, or behind a modal.
  if (!pbState.refreshTimer) {
    pbState.refreshTimer = setInterval(() => {
      if (!els.viewPlayback || els.viewPlayback.classList.contains('hidden')) return;
      void updateEventTiles(); // keep any Detections feed tile live in playback too
      if (modalOpen > 0 || pbState.timelineDragging || pbState._spanReloadPending) return;
      pbState._spanReloadPending = true;
      pbReloadTimeline().finally(() => { pbState._spanReloadPending = false; });
    }, 5000);
  }
}

function pbStopTick() {
  if (pbState.tickHandle) {
    cancelAnimationFrame(pbState.tickHandle);
    pbState.tickHandle = null;
  }
  if (pbState.refreshTimer) {
    clearInterval(pbState.refreshTimer);
    pbState.refreshTimer = null;
  }
}

// ── Enter / exit playback ─────────────────────────────────────────────────────

async function pbEnter() {
  // Snap to "now" only on a FRESH entry (first time this session); on re-entry
  // (the operator was investigating and tabbed away) preserve their window /
  // playhead / selection so they land back where they left off.
  const fresh = !pbState.everEntered;
  pbState.everEntered = true;

  if (fresh) {
    const nowMs = Date.now();
    pbState.windowEndMs   = nowMs;
    pbState.windowStartMs = nowMs - 3600_000;
    pbState.playheadMs    = nowMs;
    pbState.exportSel     = null;
    // Pick the camera whose motion is shown prominently (#3): carry over the live
    // selection if it has a camera, else the first slot that does.
    pbState.selectedSlot  = pbResolveDefaultSelectedSlot();
  }

  // Transient playback state always resets on entry.
  pbState.playing = false;
  pbState.speedIdx = 1; // 1x
  pbState.slotSegments.clear();
  pbState.slotNextSeg.clear(); // P1: drop any stale prefetch from a prior session
  pbState._resolvePending = false;
  // Carry a maximized LIVE camera into playback: if a tile was maximized in the
  // live wall, keep it maximized here (playback shares the live layout/slotMap,
  // so the same slot index holds the same camera) and focus its timeline —
  // instead of always dropping back to the full grid.
  if (state.maximized !== null) {
    pbState.maximizedSlot = state.maximized.slotIndex;
    pbState.selectedSlot  = state.maximized.slotIndex;
  } else {
    pbState.maximizedSlot = null; // full grid
  }
  ptzClearOsd(); // the PTZ wheel is live-only; clear it off any reused pane

  // Build the tile grid (same layout as live)
  pbBuildTileGrid();
  pbUpdatePlayPauseBtn();
  pbUpdateSpeedBtn();

  // Fetch timeline spans for the (fresh or restored) window.
  const cameraIds = pbGetWallCameraIds();
  setStatus('Playback — loading timeline…');
  pbState.spans = await pbFetchTimeline(cameraIds, pbState.windowStartMs, pbState.windowEndMs);
  pbState.spansLoadedStart = pbState.windowStartMs;
  pbState.spansLoadedEnd = pbState.windowEndMs;

  // On a fresh entry, jump to the latest recorded footage — landing ~1.5 s INSIDE
  // the last segment, not on its end boundary (segment resolve is start ≤ t < end,
  // so the exact end 404s and nothing loads). On re-entry, keep the saved playhead.
  if (fresh && pbState.spans.length) {
    const ends = pbState.spans.map(s => new Date(s.end).getTime()).filter(Number.isFinite);
    if (ends.length) pbState.playheadMs = Math.min(Math.max(...ends) - 1500, Date.now());
  }
  // Centered model: window is centered on the playhead (re-entry keeps the saved
  // window as-is; fresh recenters on the just-computed latest playhead).
  if (fresh) pbRecenter();

  pbUpdateTimeDisplay();
  pbUpdateZoomLabel();
  pbDrawTimeline();
  void pbFetchIntensity();  // selected-camera activity histogram
  void pbFetchDetections(); // Frigate detection-event glyphs (pbEnter loads the
                            // timeline directly, bypassing pbReloadTimeline)

  // Resolve and load panes at the playhead
  await pbResolveAllPanes(pbState.playheadMs, true);

  pbStartTick();
  setStatus('Playback ready — drag to pan, scroll to zoom, click to seek, Shift+drag to select an export range');
}

function pbGetWallCameraIds() {
  const layout = getLayout();
  const ids = [];
  for (let i = 0; i < layout.tiles; i++) {
    const id = state.slotMap.get(i);
    if (id) ids.push(id);
  }
  return [...new Set(ids)];
}

// ── Transport controls ────────────────────────────────────────────────────────

function pbTogglePlay() {
  pbState.playing = !pbState.playing;
  pbUpdatePlayPauseBtn();
  pbApplyPausedToAllPanes();
}

/**
 * Step all loaded playback panes by exactly one frame.
 * Pauses playback first (frame stepping while playing makes no sense).
 * forward=true  → step forward one frame
 * forward=false → step back one frame
 */
async function pbFrameStep(forward) {
  // Ensure paused
  if (pbState.playing) {
    pbState.playing = false;
    pbUpdatePlayPauseBtn();
    await pbApplyPausedToAllPanes();
  }

  // Invoke frame_step_pane on every VISIBLE slot that has a loaded segment
  // (pbActiveSlots() = just the maximized one when maximized).
  const ops = [];
  for (const slotIdx of pbActiveSlots()) {
    if (!pbState.slotSegments.get(slotIdx)) continue; // no footage in this slot
    ops.push(
      invoke('frame_step_pane', { id: `slot${slotIdx}`, forward }).catch(err => {
        console.warn(`frame_step_pane slot${slotIdx} failed:`, err);
      })
    );
  }
  if (ops.length) await Promise.all(ops);
}

function pbCycleSpeed() {
  pbState.speedIdx = (pbState.speedIdx + 1) % SPEEDS.length;
  pbUpdateSpeedBtn();
  pbApplySpeedToAllPanes();
}

/** The SELECTED camera's motion-intensity histogram for the loaded window — the
 *  exact per-camera data drawn as the red motion bars. Resolved the same way as
 *  pbDrawTimeline. Returns null if none (e.g. nothing loaded yet, or a main-only
 *  camera like LPR that has no sub-stream motion analysis). */
function pbSelectedIntensity() {
  const selCamId = state.slotMap.get(pbState.selectedSlot) ?? null;
  if (!selCamId) return null;
  const i = (pbState.intensity && pbState.intensity.camId === selCamId)
    ? pbState.intensity
    : (pbState.intensityByCam ? pbState.intensityByCam[selCamId] : null);
  return (i && i.buckets && i.buckets.length) ? i : null;
}

/** Motion-run START bucket times (ms) for the selected camera — the leading edge
 *  of each contiguous run of buckets at/above the motion floor (TL_MOTION_ABS),
 *  the same threshold the timeline ribbon uses. Ascending. */
function pbSelectedMotionStarts() {
  const intensity = pbSelectedIntensity();
  if (!intensity) return null;
  const { buckets, startMs } = intensity;
  const n = buckets.length;
  const span = (intensity.endMs - startMs) || 1;
  const bucketMs = intensity.bucketMs || (span / n);
  const on = i => buckets[i] >= TL_MOTION_ABS;
  // Bridge brief sub-threshold dips so one continuous burst isn't split into several
  // "events" (a 30 s event that flickers below the floor a few times is ONE event,
  // not four). A NEW run starts only after an off-gap LONGER than this.
  const COALESCE_GAP_MS = 8000;
  const gapBuckets = Math.max(1, Math.round(COALESCE_GAP_MS / bucketMs));
  const starts = [];
  let lastOn = -Infinity;
  for (let i = 0; i < n; i++) {
    if (!on(i)) continue;
    if (i - lastOn > gapBuckets) starts.push(startMs + i * bucketMs); // new run leading edge
    lastOn = i;
  }
  return starts;
}

/** GET the next/previous motion-event start across FULL history (ms epoch), or
 *  null if none. `dir` is 'next' | 'prev'. Throws on network/HTTP failure so the
 *  caller can fall back to the loaded-window scan. */
async function pbFetchMotionEdge(camId, fromMs, dir) {
  const iso = new Date(fromMs).toISOString();
  const url = `${state.server}/timeline/motion?camera_id=${encodeURIComponent(camId)}` +
    `&from=${encodeURIComponent(iso)}&dir=${dir}`;
  const res = await fetchWithTimeout(url, { headers: authHeaders() });
  if (!res.ok) throw new Error(`GET /timeline/motion → ${res.status}`);
  const j = await res.json();
  return j.start ? Date.parse(j.start) : null;
}

// Prev/Next motion search the WHOLE recording via the backend — not just the
// buckets currently loaded on the timeline — so they reach events off the current
// zoom/scroll. They fall back to the loaded-window scan if the server is
// unreachable.
async function pbPrevMotion() {
  const camId = state.slotMap.get(pbState.selectedSlot) ?? null;
  if (!camId) { setStatus('Select a camera first'); return; }
  try {
    const start = await pbFetchMotionEdge(camId, pbState.playheadMs, 'prev');
    if (start != null) { await pbJumpTo(start); return; }
    setStatus('No earlier motion on this camera');
  } catch { pbPrevMotionLocal(); }
}

async function pbNextMotion() {
  const camId = state.slotMap.get(pbState.selectedSlot) ?? null;
  if (!camId) { setStatus('Select a camera first'); return; }
  try {
    const start = await pbFetchMotionEdge(camId, pbState.playheadMs, 'next');
    if (start != null) { await pbJumpTo(start); return; }
    setStatus('No later motion on this camera');
  } catch { pbNextMotionLocal(); }
}

/** Fallback: previous motion within the LOADED timeline buckets only. */
function pbPrevMotionLocal() {
  const starts = pbSelectedMotionStarts();
  if (!starts || !starts.length) { setStatus('No motion data for the selected camera'); return; }
  const t = pbState.playheadMs;
  let curIdx = -1;
  for (let i = 0; i < starts.length; i++) { if (starts[i] <= t + 500) curIdx = i; else break; }
  if (curIdx > 0) pbJumpTo(starts[curIdx - 1]);
  else if (curIdx < 0) setStatus('No earlier motion on this camera in the loaded range');
  else pbJumpTo(starts[0]);
}

/** Fallback: next motion within the LOADED timeline buckets only. */
function pbNextMotionLocal() {
  const starts = pbSelectedMotionStarts();
  if (!starts) { setStatus('No motion data for the selected camera'); return; }
  const t = pbState.playheadMs;
  const best = starts.find(ms => ms > t + 500);
  if (best !== undefined) pbJumpTo(best);
  else setStatus('No more motion on this camera in the loaded range');
}

async function pbJumpToLatest() {
  // Jump to the NEWEST recorded footage (not "now"). The live edge has no
  // finalized segment yet — seeking there resolved to nothing, which is why the
  // old "Live" button made every tile say "no footage". Fetch a fresh recent
  // window so we find the true latest end even if the operator scrubbed hours
  // back, then land ~1.5 s INSIDE the last segment (resolve is start ≤ t < end).
  const cameraIds = pbGetWallCameraIds();
  const now = Date.now();
  // Look back a full day so we still find the newest footage even if the cameras
  // have been idle for a while (merged /timeline spans make this cheap).
  const spans = await pbFetchTimeline(cameraIds, now - 24 * 3600_000, now + 60_000);
  const ends = spans.map(s => new Date(s.end).getTime()).filter(Number.isFinite);
  if (!ends.length) { setStatus('No recorded footage found'); return; }
  const latestEnd = Math.max(...ends);
  await pbJumpTo(Math.min(latestEnd - 1500, now));
}

/** Jump to the OLDEST recorded footage (mirror of pbJumpToLatest). Looks back far
 *  enough to find the first segment even if retention spans days. */
async function pbJumpToFirst() {
  const cameraIds = pbGetWallCameraIds();
  const now = Date.now();
  const spans = await pbFetchTimeline(cameraIds, now - 30 * 24 * 3600_000, now + 60_000);
  const starts = spans.map(s => new Date(s.start).getTime()).filter(Number.isFinite);
  if (!starts.length) { setStatus('No recorded footage found'); return; }
  await pbJumpTo(Math.min(...starts) + 1000); // land just inside the first segment
}

function pbHandleTimeGoto() {
  const val = els.pbTimeInput.value; // "HH:MM" or "HH:MM:SS"
  if (!val) return;
  // Apply the time-of-day to the DAY currently under the playhead (not today) —
  // otherwise refining the time while reviewing a past day jumps to today and
  // gets clamped to "now", destroying the investigation position.
  const base = new Date(Number.isFinite(pbState.playheadMs) ? pbState.playheadMs : Date.now());
  const [hh, mm, ss = '0'] = val.split(':');
  const target = new Date(base.getFullYear(), base.getMonth(), base.getDate(),
                          parseInt(hh, 10), parseInt(mm, 10), parseInt(ss, 10));
  pbJumpTo(target.getTime());
}

async function pbShiftWindow(deltaMs) {
  // Centered model: shifting time = moving the playhead (the window follows).
  await pbJumpTo(pbState.playheadMs + deltaMs);
}

async function pbReloadTimeline() {
  const cameraIds = pbGetWallCameraIds();
  // Fetch HALF a span of margin beyond each edge so the centered window can
  // scroll during playback without immediately running off the loaded data.
  const span = (pbState.windowEndMs - pbState.windowStartMs) || 3600_000;
  const ls = pbState.windowStartMs - span * 0.5;
  const le = pbState.windowEndMs + span * 0.5;
  pbState.spans = await pbFetchTimeline(cameraIds, ls, le);
  pbState.spansLoadedStart = ls;
  pbState.spansLoadedEnd = le;
  pbDrawTimeline();
  void pbFetchIntensity(); // selected-camera activity histogram for this window
  void pbFetchDetections(); // Frigate detection-event glyphs for this window
}

/** Fetch Frigate detection events for the loaded window across all wall cameras
 *  (one request; drawing filters to the selected camera). Stored in
 *  pbState.detections as [{camera_id, ms, key}]; re-draws the timeline. */
async function pbFetchDetections() {
  const cameraIds = pbGetWallCameraIds();
  if (!cameraIds.length) { pbState.detections = []; return; }
  const ls = pbState.spansLoadedStart, le = pbState.spansLoadedEnd;
  if (!Number.isFinite(ls) || !Number.isFinite(le) || le <= ls) return;
  try {
    const url = `${state.server}/events?camera_ids=${cameraIds.join(',')}`
      + `&start=${encodeURIComponent(new Date(ls).toISOString())}`
      + `&end=${encodeURIComponent(new Date(le).toISOString())}&limit=500`;
    const res = await fetchWithTimeout(url, { headers: authHeaders() });
    if (!res.ok) return;
    const data = await res.json();
    pbState.detections = (data.events || [])
      // Motion events are already rendered as the blue motion bars; drawing each
      // as a glyph too floods the row with redundant neutral "generic" dots.
      // Show OBJECT detections only (person / vehicle / animal / face / …).
      .filter(e => e.icon_key && e.icon_key !== 'motion')
      .map(e => ({ camera_id: e.camera_id, ms: Date.parse(e.ts), key: e.icon_key }))
      .filter(e => Number.isFinite(e.ms));
    pbDrawTimeline();
  } catch { /* transient — keep the last set */ }
}

/**
 * Fetch the selected camera's motion-intensity histogram for the current window
 * (the per-camera activity bars on the upper timeline track). Stored in
 * pbState.intensity and re-rendered; safe to call freely (latest-wins).
 */
let pbIntensitySeq = 0;

// "Nice" motion-histogram bucket widths (ms). We pick a WIDTH from this fixed
// ladder (instead of windowDur / N) and snap the fetched range to ABSOLUTE epoch
// multiples of it. That pins each bucket to a fixed wall-clock slice, so panning
// the scrubber only TRANSLATES the spikes — it never re-buckets them into
// different heights/positions. (The old code fetched exactly [windowStart,
// windowEnd]: every pan shifted the bucket boundaries by an arbitrary ms amount,
// resampling the same motion data differently each frame — the "motion
// indicators change depending on where I scroll" bug.) Only ZOOM changes the
// width, which is a deliberate change of resolution.
const PB_INTENSITY_BUCKET_MS = [
  1_000, 2_000, 5_000, 10_000, 15_000, 30_000,
  60_000, 120_000, 300_000, 600_000, 900_000, 1_800_000, 3_600_000,
];

/** Choose a stable bucket WIDTH (ms) for the current zoom: ~1 bucket / 5 CSS px,
 *  rounded UP to the nearest ladder value so the grid is identical across pans. */
function pbIntensityBucketMs(winDur, cw) {
  const target = Math.max(60, Math.min(240, Math.round((cw || 480) / 5)));
  const raw = Math.max(1000, winDur / target);
  for (const b of PB_INTENSITY_BUCKET_MS) if (b >= raw) return b;
  return PB_INTENSITY_BUCKET_MS[PB_INTENSITY_BUCKET_MS.length - 1];
}

async function pbFetchIntensity() {
  const winStart = pbState.windowStartMs;
  const winEnd   = pbState.windowEndMs;
  const winDur   = (winEnd - winStart) || 3600_000;
  const cw = els.pbTimeline ? Math.round(els.pbTimeline.getBoundingClientRect().width) : 480;
  const bucketMs = pbIntensityBucketMs(winDur, cw);

  // Fetch ±1 window of margin, snapped DOWN/UP to absolute bucketMs boundaries.
  // Epoch alignment is what makes the spikes stable under pan; the margin means
  // panning within the loaded range needs no refetch (the cached bars just slide).
  const center = (winStart + winEnd) / 2;
  const fetchStart = Math.floor((center - winDur) / bucketMs) * bucketMs;
  const fetchEnd   = Math.ceil((center + winDur) / bucketMs) * bucketMs;
  const buckets    = Math.max(1, Math.round((fetchEnd - fetchStart) / bucketMs));

  // Fan out to EVERY camera in the playback grid — the selected one is drawn
  // prominent, the rest faded, so cross-camera activity stays visible (3a).
  const camIds = [...new Set([...state.slotMap.values()].filter(Boolean))];
  const selCamId = state.slotMap.get(pbState.selectedSlot) ?? null;
  if (!camIds.length) {
    pbState.intensity = null;
    pbState.intensityByCam = {};
    pbDrawTimeline();
    return;
  }

  // Drop cached intensity for cameras no longer in the grid.
  for (const id of Object.keys(pbState.intensityByCam)) {
    if (!camIds.includes(id)) delete pbState.intensityByCam[id];
  }

  const atLiveEdge = winEnd >= Date.now() - bucketMs;
  const seq = ++pbIntensitySeq;
  const startIso = new Date(fetchStart).toISOString();
  const endIso   = new Date(fetchEnd).toISOString();

  await Promise.all(camIds.map(async (camId) => {
    // Already have aligned coverage at this resolution, and not at the live edge
    // (where the newest bucket keeps growing)? Reuse it — no refetch, no flicker.
    const cur = pbState.intensityByCam[camId];
    if (cur && cur.bucketMs === bucketMs &&
        cur.startMs <= winStart && cur.endMs >= winEnd && !atLiveEdge) {
      return;
    }
    try {
      const url = `${state.server}/timeline/intensity?camera_id=${encodeURIComponent(camId)}` +
        `&start=${encodeURIComponent(startIso)}&end=${encodeURIComponent(endIso)}&buckets=${buckets}`;
      const res = await fetchWithTimeout(url, { headers: authHeaders() });
      if (!res.ok || seq !== pbIntensitySeq) return; // stale or failed
      const data = await res.json();
      if (seq !== pbIntensitySeq) return; // a newer fetch superseded us during the parse
      pbState.intensityByCam[camId] = { camId, startMs: fetchStart, endMs: fetchEnd, bucketMs, buckets: data.buckets ?? [] };
    } catch { /* leave previous intensity for this camera */ }
  }));

  if (seq !== pbIntensitySeq) return; // superseded by a newer fetch mid-flight
  pbState.intensity = selCamId ? (pbState.intensityByCam[selCamId] ?? null) : null;
  pbDrawTimeline();
}

/**
 * Jump the playhead to a specific epoch ms, clamped to the window.
 * Re-resolves panes. If the target is outside the current window,
 * recenters the window first.
 */
/** Center the visible window on the playhead, keeping the current span (zoom).
 *  The timeline is a CENTERED-PLAYHEAD model (like the Android client): the
 *  playhead is fixed at the horizontal center and time scrolls through it. */
function pbRecenter() {
  const span = (pbState.windowEndMs - pbState.windowStartMs) || 3600_000;
  pbState.windowStartMs = pbState.playheadMs - span / 2;
  pbState.windowEndMs   = pbState.playheadMs + span / 2;
}

async function pbJumpTo(tMs) {
  // Centered model: the playhead never moves off-center — instead the window
  // recenters on the new time (clamped to "now" so we never seek into the future).
  pbState.playheadMs = Math.min(tMs, Date.now());
  pbRecenter();
  pbUpdateTimeDisplay();
  pbDrawTimeline();
  await pbReloadTimeline();
  await pbResolveAllPanes(pbState.playheadMs, true);
}

// ── Bookmarks (server-shared: camera + time + optional note) ────────────────────

/** The focused playback camera = the selected slot's camera (state.slotMap is the
 *  shared Live/Playback slot→camera map); fall back to any slot with footage. */
function pbSelectedCameraId() {
  // Only ever return a REAL camera id. Playback renders each slot from
  // pbState.slotSegments; state.slotMap is the LIVE map and can be stale or hold
  // a non-camera here, so reading it first made the bookmark POST send an invalid
  // camera_id → HTTP 422 (silent on older builds, "Add bookmark failed" now).
  // Prefer the selected slot's actual playback camera, validate with camById, and
  // return null if nothing valid (→ pbAddBookmark shows "select a camera tile").
  const valid = (id) => (id && camById(id)) ? id : null;
  const sel = valid(pbState.slotSegments.get(pbState.selectedSlot)?.cameraId)
           || valid(state.slotMap?.get(pbState.selectedSlot));
  if (sel) return sel;
  for (const seg of pbState.slotSegments.values()) {
    const v = valid(seg?.cameraId);
    if (v) return v;
  }
  return null;
}

/** A small centered modal over the playback view. Returns a `close()` fn. */
function pbOverlay(card) {
  const back = document.createElement('div');
  back.style.cssText = 'position:fixed;inset:0;z-index:9000;background:rgba(0,0,0,.55);' +
    'display:flex;align-items:center;justify-content:center;';
  card.style.cssText = 'background:var(--surface);color:var(--text);border:1px solid var(--border);' +
    'border-radius:10px;padding:18px;min-width:360px;max-width:90vw;max-height:80vh;overflow:auto;' +
    'box-shadow:0 12px 40px rgba(0,0,0,.5);';
  back.appendChild(card);
  // The native libmpv video panes float ABOVE the WebView, so a DOM overlay on the
  // playback view would be hidden behind the video tiles. modalOpened() hides the
  // panes (set_panes_hidden) so the overlay is actually visible; restore on close.
  modalOpened();
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    back.remove();
    modalClosed();
  };
  back.addEventListener('mousedown', e => { if (e.target === back) close(); });
  document.body.appendChild(back);
  return close;
}

/** Bookmark the current moment on the focused camera, with an optional note. */
// Shared "Add bookmark" dialog. Called from the Playback transport (no args →
// uses the selected tile + playhead) and from the Clips player (explicit
// camera + moment + a prefilled description). Same fields/defaults either way.
function pbAddBookmark(camIdArg, atMsArg, defaultDesc) {
  const camId = camIdArg || pbSelectedCameraId();
  if (!camId) { setStatus('Select a camera tile first, then bookmark it.'); return; }
  const cam = camById(camId);
  const atMs = atMsArg != null ? atMsArg
    : (Number.isFinite(pbState.playheadMs) ? pbState.playheadMs : Date.now());

  const card = document.createElement('div');
  card.innerHTML =
    `<div style="font-weight:600;margin-bottom:4px">Add bookmark</div>` +
    `<div style="color:var(--text-muted);font-size:13px;margin-bottom:10px">` +
    `${escHtml(cam ? cam.name : 'Camera')} · ${escHtml(new Date(atMs).toLocaleString())}</div>` +
    `<textarea id="pb-bm-desc" rows="3" placeholder="Description (optional)" ` +
    `style="width:100%;box-sizing:border-box;background:var(--bg);color:var(--text);` +
    `border:1px solid var(--border);border-radius:6px;padding:8px;resize:vertical">` +
    `${escHtml(defaultDesc || '')}</textarea>` +
    `<label style="display:flex;align-items:center;gap:8px;margin-top:12px;font-size:13px;cursor:pointer">` +
    `<input type="checkbox" id="pb-bm-protect"> Protect from auto-delete</label>` +
    `<div id="pb-bm-protect-opts" style="display:none;margin-top:8px;font-size:13px;color:var(--text-muted);` +
    `display:none;align-items:center;gap:6px;flex-wrap:wrap">` +
    `Keep <input id="pb-bm-days" type="number" min="1" max="30" value="7" ` +
    `style="width:52px;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:4px;padding:3px"> days` +
    ` &middot; clip <input id="pb-bm-pre" type="number" min="0" max="60" value="1" ` +
    `style="width:46px;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:4px;padding:3px"> min before /` +
    ` <input id="pb-bm-post" type="number" min="0" max="60" value="5" ` +
    `style="width:46px;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:4px;padding:3px"> min after</div>` +
    `<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:12px">` +
    `<button class="pb-btn pb-btn-xs" id="pb-bm-cancel">Cancel</button>` +
    `<button class="pb-btn pb-btn-xs pb-btn-primary" id="pb-bm-save">Save</button></div>`;
  const close = pbOverlay(card);
  const ta = card.querySelector('#pb-bm-desc');
  ta.focus();
  const protectCb = card.querySelector('#pb-bm-protect');
  const protectOpts = card.querySelector('#pb-bm-protect-opts');
  protectCb.addEventListener('change', () => {
    protectOpts.style.display = protectCb.checked ? 'flex' : 'none';
  });
  card.querySelector('#pb-bm-cancel').addEventListener('click', close);
  card.querySelector('#pb-bm-save').addEventListener('click', async () => {
    const desc = ta.value.trim();
    const body = { camera_id: camId, ts: new Date(atMs).toISOString(), description: desc || null };
    if (protectCb.checked) {
      const days = Math.min(30, Math.max(1, parseInt(card.querySelector('#pb-bm-days').value, 10) || 7));
      const preMin = Math.min(60, Math.max(0, parseInt(card.querySelector('#pb-bm-pre').value, 10) || 0));
      const postMin = Math.min(60, Math.max(0, parseInt(card.querySelector('#pb-bm-post').value, 10) || 0));
      body.protect_days = days;
      body.protect_pre_seconds = preMin * 60;
      body.protect_post_seconds = postMin * 60;
    }
    close();
    try {
      const res = await fetchWithTimeout(`${state.server}/bookmarks`, {
        method: 'POST',
        headers: authHeaders(),
        body: JSON.stringify(body),
      });
      if (res.status === 401) { handleUnauthorized(); return; }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      setStatus(`Bookmark added · ${cam ? cam.name : 'camera'} @ ${new Date(atMs).toLocaleTimeString()}`);
    } catch (e) { setStatus(`Add bookmark failed: ${e.message || e}`); }
  });
}

/** Open the cross-camera bookmarks list; clicking a row jumps to that camera+time. */
async function pbOpenBookmarks() {
  const card = document.createElement('div');
  card.style.minWidth = '460px';
  card.innerHTML =
    `<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:10px">` +
    `<span style="font-weight:600">Bookmarks</span>` +
    `<button class="pb-btn pb-btn-xs" id="pb-bm-close">Close</button></div>` +
    `<div id="pb-bm-list" style="color:var(--text-muted)">Loading…</div>`;
  const close = pbOverlay(card);
  card.querySelector('#pb-bm-close').addEventListener('click', close);
  const list = card.querySelector('#pb-bm-list');

  let rows;
  try {
    const res = await fetchWithTimeout(`${state.server}/bookmarks`, { headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); close(); return; }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    rows = await res.json();
  } catch (e) { list.textContent = `Couldn't load bookmarks: ${e.message || e}`; return; }

  if (!Array.isArray(rows) || rows.length === 0) {
    list.innerHTML = `<div style="padding:8px 0">No bookmarks yet. Use “☆ Bookmark” while reviewing a camera.</div>`;
    return;
  }
  list.innerHTML = '';
  rows.forEach(bm => {
    const row = document.createElement('div');
    row.style.cssText = 'display:flex;align-items:center;gap:10px;padding:8px 6px;border-top:1px solid var(--border-dim);cursor:pointer';
    const when = (() => { const t = Date.parse(bm.ts); return Number.isFinite(t) ? new Date(t).toLocaleString() : bm.ts; })();
    const desc = (bm.description || '').trim();
    const protMs = bm.protect_until ? Date.parse(bm.protect_until) : NaN;
    const protected_ = Number.isFinite(protMs) && protMs > Date.now();
    const protBadge = protected_
      ? ` <span title="Protected until ${escHtml(new Date(protMs).toLocaleString())}" style="color:var(--accent)">🔒</span>`
      : '';
    row.innerHTML =
      `<div style="flex:1;min-width:0">` +
      `<div style="font-size:13px"><span style="color:var(--accent);font-weight:600">${escHtml(bm.camera_name || 'Camera')}</span>` +
      ` <span style="color:var(--text-muted)">· ${escHtml(when)}</span>${protBadge}</div>` +
      `<div style="color:${desc ? 'var(--text)' : 'var(--text-muted)'};font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">` +
      `${escHtml(desc || 'No description')}</div></div>` +
      `<button class="pb-btn pb-btn-xs" data-del="${escHtml(bm.id)}" title="Delete">✕</button>`;
    row.querySelector('[data-del]').addEventListener('click', async (e) => {
      e.stopPropagation();
      try {
        const r = await fetchWithTimeout(`${state.server}/bookmarks/${encodeURIComponent(bm.id)}`, { method: 'DELETE', headers: authHeaders() });
        if (r.ok || r.status === 404) row.remove();
      } catch { /* leave row */ }
    });
    row.addEventListener('click', () => {
      close();
      const ms = Date.parse(bm.ts);
      if (Number.isFinite(ms)) void goToPlaybackEvent(bm.camera_id, ms);
    });
    list.appendChild(row);
  });
}

// ── Transport UI helpers ──────────────────────────────────────────────────────

function pbUpdatePlayPauseBtn() {
  const playing = pbState.playing;
  els.pbPlayIcon.classList.toggle('hidden', playing);
  els.pbPauseIcon.classList.toggle('hidden', !playing);
}

function pbUpdateSpeedBtn() {
  els.pbSpeedBtn.textContent = pbGetSpeed() + 'x';
}

function pbUpdateTimeDisplay() {
  if (!Number.isFinite(pbState.playheadMs)) { els.pbTimeDisplay.textContent = '--:--:--'; return; }
  const d = new Date(pbState.playheadMs);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  if (!pbIsToday(pbState.playheadMs)) {
    const mon = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    els.pbTimeDisplay.textContent = `${mon}/${day} ${hh}:${mm}:${ss}`;
  } else {
    els.pbTimeDisplay.textContent = `${hh}:${mm}:${ss}`;
  }
}

function pbIsToday(epochMs) {
  const d = new Date(epochMs);
  const now = new Date();
  return d.getFullYear() === now.getFullYear() &&
         d.getMonth() === now.getMonth() &&
         d.getDate() === now.getDate();
}

// ── Keyboard shortcuts (playback) ─────────────────────────────────────────────

function pbHandleKey(e) {
  // Only active when playback tab is visible
  if (els.viewPlayback.classList.contains('hidden')) return;
  // Don't hijack typing: space/arrows/s/,/. are playback shortcuts, but when a
  // text field is focused (e.g. the Add-bookmark description) they must reach the
  // field. Guard TEXTAREA too — not just INPUT — or you can't type spaces in notes.
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable) return;

  if (e.key === 'Escape' && pbState.maximizedSlot !== null) {
    pbState.maximizedSlot = null;
    pbBuildTileGrid();
    pbResolveAllPanes(pbState.playheadMs, true);
    return;
  }
  if (e.key === ' ') {
    e.preventDefault();
    pbTogglePlay();
  } else if (e.key === 'ArrowLeft') {
    e.preventDefault();
    pbShiftWindow(-30_000); // -30 seconds
  } else if (e.key === 'ArrowRight') {
    e.preventDefault();
    pbShiftWindow(30_000);
  } else if (e.key === ',') {
    pbPrevMotion();
  } else if (e.key === '.') {
    pbNextMotion();
  } else if (e.key === '<') {
    // Shift+, — step back one frame
    e.preventDefault();
    pbFrameStep(false);
  } else if (e.key === '>') {
    // Shift+. — step forward one frame
    e.preventDefault();
    pbFrameStep(true);
  } else if (e.key === 's' || e.key === 'S') {
    snapshotActivePane();
  }
}

// ── Timeline canvas ───────────────────────────────────────────────────────────
//
// Layout (top to bottom in 68px canvas):
//   0–16px   : time labels + gridlines (text at top)
//   16–26px  : MOTION LANE — 10px tall amber strip (marks where has_motion=true)
//   26–56px  : RECORDED TRACK — blue footage band
//   56–68px  : bottom edge labels (window start/end)
//
// Colors:
//   track bg         = #22304f
//   recorded span    = #2b5aa8
//   motion lane bg   = #1a2540   (slightly darker than track, distinct but not loud)
//   motion mark      = #f59e0b   (full amber — scannable at a glance)
//   gridlines        = #2a3a5c
//   playhead line    = #e6eaf2
//   playhead tri     = #e6eaf2
//   text             = #9aa8c3

// Timeline geometry & palette — motion colored BY CAMERA (a deliberate departure
// from the commercial VMS's flat single-hue band, per the maintainer's request: "a glance
// at the scrubber should tell you WHICH camera moved when"). Every camera present
// in pbState.intensityByCam is drawn in ITS OWN fixed color (cameraMotionColor());
// the SELECTED camera is drawn most prominent (full opacity/tallest ceiling, plus
// the recording-coverage base bar) so it still reads as "the one you're looking
// at", but every other camera keeps its own hue rather than collapsing into one
// faded gray composite. Motion intensity is still encoded as cap HEIGHT and
// OPACITY per camera (taller/brighter = a sustained event) — see drawMotion().
// Palette: empty = dark gray, recording = slate, motion = per-camera color,
// playhead = near-white. A violet overlay marks where >2/3 of the cameras are
// active at once (a distinct hue from any per-camera color, so it always reads
// as "site-wide", not "one more busy camera").
const TL = {
  LABEL_H:    15,   // px reserved for time labels + grid at top
  BOTTOM_H:   16,   // px reserved for window start/end labels at the bottom
  RULER_GRAB_H: 17,
  TEXT_COLOR: '#8B93A1',  // slate-lite (The Trail)
  TRACK_BG:   '#0E0F12',  // crumb-black — near-black canvas background
  REC_BASE:   '#5B6472',  // recording present (static) — slate (continuous)
  MOTION:     '#4C9AFF',  // selected-cam strong/sustained motion — bright azure cap (the "event")
  MOTION_LOW: '#2E5A9C',  // selected-cam any-motion — medium blue ribbon (the "something moved" floor)
  MOTION_FADED: '#41587E', // other-camera motion — dim slate-blue, drawn faded behind
  MULTI_WASH: 'rgba(167,139,250,0.13)', // >2/3-cameras-active band wash — violet (distinct from the blue motion)
  MULTI_BAR:  'rgba(178,150,255,0.92)', // >2/3-cameras-active cap bar at the top of the track
  GRID:       'rgba(255,255,255,0.06)',
  PLAYHEAD:   '#F4F7FB',  // near-white playhead — the dominant cursor, distinct from the blue motion
  LANE_LABEL: 'rgba(220,220,220,0.45)',
};

// Motion is drawn where a bucket's largest-blob fraction clears a FIXED absolute
// floor. The floor sits just above the recorder's own detection floor
// (BLOB_FRACTION = 0.30% of frame, motion.rs) so EVERY event the recorder scored
// as motion is drawn — a person on a wide cam ≈ 1.7% spikes clearly, a strong
// close event tops out, and a quiet camera (score 0) shows nothing.
//
// This is deliberately NOT a per-window relative gate. The old code used
// thr = max(0.012, windowMin + 0.006): the per-window minimum made a FIXED event's
// visibility depend on the rest of the loaded window (the same 1.8% event showed
// in a quiet window and vanished in a slightly-noisier one), and the 1.2% floor
// was 4× the recorder's detection floor — both hid real-but-modest motion. That
// was the "obvious motion at 12:17:52 shows nothing on the timeline" bug.
const TL_MOTION_ABS = 0.004;    // 0.4% largest-blob fraction — ANY motion (the recorder's floor)
const TL_MOTION_STRONG = 0.02;  // 2% largest-blob fraction — a SUBSTANTIAL object (person/vehicle).
                                // Below this = a low muted ribbon ("something moved"); at/above this,
                                // SUSTAINED, = a bright tall cap ("a real event"). The blob-area score
                                // already suppresses scattered tree noise (small largest-blob); this
                                // two-tone split + the sustain gate are what make noise vs. event
                                // readable at a glance, the way the commercial VMS's red run does.

// ── Per-camera motion color (BY-CAMERA timeline mode) ─────────────────────────
// Cameras have no color field in the data model, so we derive one deterministically
// from the camera's id (a stable UUID) — same camera → same color forever, with no
// dependency on fetch/list order (which is NOT guaranteed stable across sessions).
// A hand-picked, well-separated 12-color palette (not a raw hash→hue) so adjacent
// indices never land on muddy/near-identical hues on the dark timeline background;
// index 12+ still gets a color (hash wraps) but distinctness degrades gracefully.
// NOTE: no red — an earlier revision of this timeline moved motion OFF red
// specifically because red reads as alarm/record, not routine motion (see the
// MULTI_WASH/MULTI_BAR violet choice below, made for the same reason). Keep
// this palette red-free so a routine per-camera motion color is never mistaken
// for an alert state.
const CAM_COLOR_PALETTE = [
  '#4C9AFF', // azure   (matches the legacy single-camera MOTION blue for cam #1)
  '#F2994A', // orange
  '#6FCF97', // green
  '#F2C94C', // yellow
  '#BB6BD9', // purple
  '#56CCF2', // cyan
  '#F783AC', // pink
  '#A9DC76', // lime
  '#9B8AFB', // indigo
  '#FFB86B', // amber
  '#5FE3C0', // teal
  '#7AA2F7', // periwinkle
];

/** FNV-1a 32-bit string hash — simple, fast, well-distributed, no dependencies. */
function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

const camColorCache = new Map();
/** Stable color for a camera id, shared by the motion band, the legend, and the
 *  hover-hint dot so all three can never drift apart. Cached per-id (cheap, but
 *  the hash is deterministic anyway — caching just avoids recomputing per frame). */
function cameraMotionColor(camId) {
  if (!camId) return TL.MOTION_FADED;
  let c = camColorCache.get(camId);
  if (!c) {
    c = CAM_COLOR_PALETTE[fnv1a(camId) % CAM_COLOR_PALETTE.length];
    camColorCache.set(camId, c);
  }
  return c;
}

/**
 * Inject frame-step buttons (step-back / step-forward) into the transport bar
 * immediately adjacent to the play/pause button.
 * Called once from DOMContentLoaded, before pbInjectZoomButtons.
 */
function pbInjectFrameStepButtons() {
  // Disabled: superseded by the STATIC frame-step buttons in index.html
  // (#pb-frame-back / #pb-frame-fwd), placed OUTSIDE the motion buttons so the
  // desktop transport order matches Android (first · frame-back · prev-motion ·
  // play · next-motion · frame-fwd · last). Early-return keeps the existing
  // DOMContentLoaded caller untouched; the code below is intentionally dead.
  return;
  const playPauseBtn = document.getElementById('pb-play-pause');
  if (!playPauseBtn) return;

  // Step-back button — insert BEFORE play/pause
  const stepBack = document.createElement('button');
  stepBack.id        = 'pb-step-back';
  stepBack.className = 'pb-btn pb-btn-primary';
  stepBack.title     = 'Step back one frame';
  // Unicode: BLACK LEFT-POINTING DOUBLE TRIANGLE WITH VERTICAL BAR (U+23EE)
  stepBack.textContent = '⏮';
  stepBack.setAttribute('aria-label', 'Step back one frame');
  stepBack.addEventListener('click', () => pbFrameStep(false));
  playPauseBtn.parentNode.insertBefore(stepBack, playPauseBtn);

  // Step-forward button — insert AFTER play/pause
  const stepFwd = document.createElement('button');
  stepFwd.id        = 'pb-step-fwd';
  stepFwd.className = 'pb-btn pb-btn-primary';
  stepFwd.title     = 'Step forward one frame';
  // Unicode: BLACK RIGHT-POINTING DOUBLE TRIANGLE WITH VERTICAL BAR (U+23ED)
  stepFwd.textContent = '⏭';
  stepFwd.setAttribute('aria-label', 'Step forward one frame');
  stepFwd.addEventListener('click', () => pbFrameStep(true));
  playPauseBtn.parentNode.insertBefore(stepFwd, playPauseBtn.nextSibling);
}

/**
 * Inject zoom controls into the transport bar's jump-group area.
 * We insert them as a new group adjacent to the existing ±h/±m buttons.
 * Called once from DOMContentLoaded.
 */
function pbInjectZoomButtons() {
  // Find the jump group (the ±h/±m buttons live there)
  const jumpGroup = document.querySelector('.pb-jump-group');
  if (!jumpGroup) return;

  // Build: separator + "−" zoom out button + span label + "+" zoom in button
  const zoomGroup = document.createElement('div');
  zoomGroup.className = 'pb-jump-group pb-zoom-group';
  // Scale slider: left = zoomed out (wide window), right = zoomed in (narrow).
  const maxIdx = PB_ZOOM_STEPS.length - 1;
  zoomGroup.innerHTML = `
    <span class="pb-jump-label">Zoom</span>
    <button id="pb-zoom-out" class="pb-btn pb-btn-xs" title="Zoom out (wider window)">−</button>
    <input id="pb-zoom-slider" class="pb-zoom-slider" type="range" min="0" max="${maxIdx}" step="1" value="${Math.floor(maxIdx / 2)}" title="Time scale" />
    <button id="pb-zoom-in"  class="pb-btn pb-btn-xs" title="Zoom in (narrower window)">+</button>
    <button id="pb-zoom-label" class="pb-btn pb-btn-xs pb-btn-zoom-label" title="Current time span">1h</button>
  `;
  // Insert after the jump group
  jumpGroup.parentNode.insertBefore(zoomGroup, jumpGroup.nextSibling);

  document.getElementById('pb-zoom-out').addEventListener('click', () => pbZoom(1));
  document.getElementById('pb-zoom-in').addEventListener('click',  () => pbZoom(-1));
  // Slider: drag right → zoom in. Map slider value to a step index (inverted).
  document.getElementById('pb-zoom-slider').addEventListener('input', (e) => {
    const idx = maxIdx - parseInt(e.target.value, 10);
    pbSetZoomIndex(idx, pbState.playheadMs);
  });
}

// Cap the per-camera color key so a large grid doesn't overflow the legend row
// (it lives in a single unobtrusive caption line above the timeline canvas).
const PB_LEGEND_CAM_MAX = 8;

/**
 * Build the timeline legend (the small caption row rendered under the
 * transport bar, above the timeline canvas): a "Recorded" swatch, plus a
 * color→camera key — one swatch per camera that currently has motion data
 * loaded for the visible window, in ITS color (cameraMotionColor()), so the
 * legend can never drift from the bars/hover-dot (same helper, one source).
 * Re-run from pbDrawTimeline() (not just once at DOMContentLoaded) because the
 * camera set with motion in view changes as the grid/window changes.
 */
function pbInjectTimelineLegend() {
  const el = document.getElementById('pb-timeline-legend');
  if (!el) return;

  const swatch = (color) => {
    const s = document.createElement('span');
    s.className = 'pb-legend-swatch';
    s.style.setProperty('--tl-swatch-color', color);
    return s;
  };
  const item = (color, label, tip) => {
    const wrap = document.createElement('span');
    wrap.className = 'pb-legend-item';
    if (tip) wrap.title = tip;
    wrap.appendChild(swatch(color));
    const t = document.createElement('span');
    t.textContent = label;
    wrap.appendChild(t);
    return wrap;
  };

  el.innerHTML = '';
  el.appendChild(item(TL.REC_BASE,
    'Recorded', 'Footage exists on disk for this time'));

  // Cameras with a loaded (non-empty) motion series, sorted by name so the key
  // reads in a stable, scannable order (not fetch/insertion order).
  const camIds = Object.keys(pbState.intensityByCam || {})
    .filter(id => {
      const s = pbState.intensityByCam[id];
      return s && s.buckets && s.buckets.length;
    })
    .map(id => ({ id, cam: camById(id) }))
    .sort((a, b) => (a.cam?.name || a.id).localeCompare(b.cam?.name || b.id, undefined, { numeric: true, sensitivity: 'base' }));

  const shown = camIds.slice(0, PB_LEGEND_CAM_MAX);
  for (const { id, cam } of shown) {
    const label = cam ? cam.name : id.slice(0, 6);
    el.appendChild(item(cameraMotionColor(id), label, `Motion band color for ${label}`));
  }
  const extra = camIds.length - shown.length;
  if (extra > 0) {
    const more = document.createElement('span');
    more.className = 'pb-legend-item pb-legend-more';
    more.title = camIds.slice(PB_LEGEND_CAM_MAX).map(c => c.cam ? c.cam.name : c.id.slice(0, 6)).join(', ');
    more.textContent = `+${extra}`;
    el.appendChild(more);
  }
}

function pbDrawTimeline() {
  const canvas = els.pbTimeline;
  if (!canvas) return;

  // Size canvas to its CSS display size (device-pixel-ratio aware)
  const dpr  = window.devicePixelRatio || 1;
  const rect = canvas.getBoundingClientRect();
  const cw   = rect.width;
  const ch   = rect.height;

  if (cw < 2) return; // not yet painted

  if (canvas.width !== Math.round(cw * dpr) || canvas.height !== Math.round(ch * dpr)) {
    canvas.width  = Math.round(cw * dpr);
    canvas.height = Math.round(ch * dpr);
  }

  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  const winStart  = pbState.windowStartMs;
  const winEnd    = pbState.windowEndMs;
  const winDur    = winEnd - winStart;
  if (winDur <= 0) return;

  // Helper: ms → x pixel
  const msToX = ms => ((ms - winStart) / winDur) * cw;

  // Selected camera (drives the prominent upper track, #3).
  const selCamId = state.slotMap.get(pbState.selectedSlot) ?? null;
  const selCam   = selCamId ? camById(selCamId) : null;

  // ── 1. Background ──────────────────────────────────────────────────────────
  ctx.fillStyle = TL.TRACK_BG;
  ctx.fillRect(0, 0, cw, ch);

  // Ruler grab strip — very slightly lighter so it reads as a draggable bar.
  ctx.fillStyle = 'rgba(255,255,255,0.04)';
  ctx.fillRect(0, 0, cw, TL.LABEL_H);

  // ── 2. Grid lines + time labels ────────────────────────────────────────────
  ctx.strokeStyle = TL.GRID;
  ctx.lineWidth = 1;
  ctx.fillStyle = TL.TEXT_COLOR;
  ctx.font = '10px ui-monospace, Consolas, monospace';
  ctx.textBaseline = 'top';

  const gridIntervalMs = pbPickGridInterval(winDur);
  const firstGrid = Math.ceil(winStart / gridIntervalMs) * gridIntervalMs;

  for (let t = firstGrid; t <= winEnd; t += gridIntervalMs) {
    const x = msToX(t);
    ctx.beginPath();
    ctx.moveTo(x, TL.LABEL_H);
    ctx.lineTo(x, ch - TL.BOTTOM_H);
    ctx.stroke();
    const label = pbFmtGridLabel(t, gridIntervalMs);
    const tw = ctx.measureText(label).width;
    ctx.fillText(label, Math.max(2, x - tw / 2), 2);
  }

  // ── 3. Motion tracks (BY CAMERA) ────────────────────────────────────────────
  // EVERY camera in the playback grid contributes motion to the shared timeline,
  // each drawn in ITS OWN fixed color (cameraMotionColor()) so a glance at the
  // scrubber tells the operator WHICH camera moved when — not just "something
  // moved somewhere". The SELECTED camera is drawn most prominent (full opacity,
  // tallest ceiling) and gets the recording-coverage base bar; every other camera
  // in the grid is drawn in its own color too, just dimmer/shorter, so cross-camera
  // activity stays visible without one camera's color drowning the rest.
  const segStartMs = s => new Date(s.start).getTime();
  const segEndMs   = s => new Date(s.end).getTime();

  const tTop = TL.LABEL_H + 3;
  const tBottom = ch - TL.BOTTOM_H;
  const tH = Math.max(8, tBottom - tTop);
  const baseH = Math.max(3, Math.round(tH * 0.10)); // static recording-bar height (slimmed per feedback — was 0.26; gives motion more room)

  // ~8% largest-blob fraction = a full-height BRIGHT cap. Absolute, not in-view
  // peak, so a busy camera shows modest height — not a wall of red.
  const ABS_PEAK = 0.08;
  // Gap-bridge + sustain are in the TIME domain (not a fixed bucket count) so they
  // never span more wall-clock than intended as zoom changes bucketMs.
  const BRIDGE_MS = 3000;       // merge motion gaps up to ~3 s into one region…
  const MAX_BRIDGE_MS = 12000;  // …but NEVER bridge once a bucket itself spans >12 s
  const SUSTAIN_MS = 1500;      // strong motion must persist this long to earn the bright cap

  // Group a bucket array into maximal CONNECTED motion regions (index ranges
  // [s..e]), bridging OFF gaps up to `gapBridge` buckets so a momentary dip does
  // not fragment one event. Pure + allocation-light. (Unit-tested via CDP.)
  const motionRegions = (buckets, gapBridge) => {
    const regions = [];
    const n = buckets.length;
    const on = i => buckets[i] >= TL_MOTION_ABS;
    let i = 0;
    while (i < n) {
      if (!on(i)) { i++; continue; }
      let e = i, j = i + 1;
      while (j < n) {
        if (on(j)) { e = j; j++; continue; }
        let g = j; while (g < n && !on(g)) g++;        // width of this OFF run
        if (g < n && (g - j) <= gapBridge) { j = g; }  // short internal dip → bridge it
        else break;                                     // real gap / trailing off → close
      }
      regions.push({ s: i, e });
      i = e + 1;
    }
    return regions;
  };

  // Draw one camera's motion series as connected TWO-TONE regions, both tinted
  // with `color` (that camera's fixed color from cameraMotionColor()): a low
  // ribbon for any motion ("something moved"), plus a taller/brighter cap rising
  // out of it ONLY where strong motion is sustained ("a real event") — intensity
  // is still encoded as height (capH) AND opacity, per-camera, exactly as before;
  // only the hue now varies by camera instead of by prominence. `prominent` is
  // true only for the selected camera — it gets the full ceiling + opacity so it
  // still reads as "the one you're looking at"; every other camera is drawn
  // shorter/dimmer in ITS OWN color so it doesn't drown the selected one out.
  const drawMotion = (intensity, prominent, color) => {
    if (!intensity || !intensity.buckets || !intensity.buckets.length) return;
    const buckets = intensity.buckets;
    const n = buckets.length;
    const span = (intensity.endMs - intensity.startMs) || 1;
    const bucketMs = intensity.bucketMs || (span / n);

    const gapBridge = bucketMs >= MAX_BRIDGE_MS ? 0
                    : Math.max(1, Math.round(BRIDGE_MS / bucketMs));
    const sustainBuckets = Math.max(1, Math.round(SUSTAIN_MS / bucketMs));

    // Motion lives ABOVE the recording-bar band (tBottom-baseH) for every camera,
    // so no camera's band is occluded by the selected camera's slate bar.
    const floorY  = tBottom - baseH;
    const usableH = tH - baseH;
    const lowH    = Math.max(2, usableH * (prominent ? 0.16 : 0.13)); // muted ribbon height
    const capCeil = prominent ? usableH : usableH * 0.62;             // non-selected caps stay subtler

    const edgeX = k => msToX(intensity.startMs + (k / n) * span);
    const capH  = v => {
      const nh = Math.min(1, Math.max(0, (v - TL_MOTION_STRONG) / (ABS_PEAK - TL_MOTION_STRONG)));
      return lowH + (0.22 + 0.78 * nh) * (capCeil - lowH); // pokes clearly out of the ribbon
    };

    const regions = motionRegions(buckets, gapBridge);
    if (!regions.length) return;

    ctx.save();
    ctx.fillStyle = color;

    // Pass 1 — LOW ribbon: one flat band per region (width = duration), dimmer.
    ctx.globalAlpha = prominent ? 0.92 : 0.30;
    for (const r of regions) {
      let xL = edgeX(r.s), xR = edgeX(r.e + 1);
      if (xR - xL < 2) xR = xL + 2;          // sub-pixel guard: grow right from true left edge
      ctx.fillRect(xL, floorY - lowH, xR - xL, lowH);
    }

    // Pass 2 — BRIGHT cap: only where STRONG motion is SUSTAINED (>= sustainBuckets
    // consecutive strong buckets). A lone strong bucket — e.g. a coarse-zoom
    // bucket MAX-inflated by one noisy 4 s segment, or a single branch sway —
    // never earns the cap; it stays in the low ribbon. Same color, full opacity.
    ctx.globalAlpha = prominent ? 1 : 0.42;
    const strong = i => buckets[i] >= TL_MOTION_STRONG;
    for (const r of regions) {
      let k = r.s;
      while (k <= r.e) {
        if (!strong(k)) { k++; continue; }
        let m = k; while (m <= r.e && strong(m)) m++;  // strong run [k .. m-1]
        if (m - k >= sustainBuckets) {
          ctx.beginPath();
          ctx.moveTo(edgeX(k), floorY);
          for (let b = k; b < m; b++) {
            const y = floorY - capH(buckets[b]);       // top follows magnitude
            ctx.lineTo(edgeX(b), y);
            ctx.lineTo(edgeX(b + 1), y);
          }
          ctx.lineTo(edgeX(m), floorY);
          ctx.closePath();
          ctx.fill();
        }
        k = m;
      }
    }

    ctx.restore();
  };

  // Build connected TIME spans where MORE THAN 2/3 of the in-view cameras had
  // motion in the same bucket — a site-wide-activity signal (a person crossing the
  // property, or a global light change / false-positive storm). Uses the shared
  // bucket grid (same alignment guard as the faded composite). Needs >=3 cameras
  // for the 2/3 ratio to mean more than "all of them". Returns [{startMs,endMs}].
  const buildMultiCamRegions = () => {
    const byCam = pbState.intensityByCam || {};
    let ref = null;
    const series = [];
    for (const s of Object.values(byCam)) {
      if (!s || !s.buckets || !s.buckets.length) continue;
      if (!ref) ref = s;
      if (s.startMs === ref.startMs && s.bucketMs === ref.bucketMs &&
          s.buckets.length === ref.buckets.length) series.push(s.buckets);
    }
    const total = series.length;
    if (total < 3) return [];                      // 2/3 only meaningful with >=3 cams
    const n = ref.buckets.length;
    const need = (2 / 3) * total;                  // STRICTLY more than 2/3 of cameras
    const hot = new Array(n);
    for (let i = 0; i < n; i++) {
      let c = 0;
      for (let k = 0; k < total; k++) if (series[k][i] >= TL_MOTION_ABS) c++;
      hot[i] = c > need;
    }
    const span = (ref.endMs - ref.startMs) || 1;
    const edge = k => ref.startMs + (k / n) * span;
    const out = [];
    let i = 0;
    while (i < n) {
      if (!hot[i]) { i++; continue; }
      let e = i, j = i + 1;
      while (j < n) {
        if (hot[j]) { e = j; j++; continue; }
        if (j + 1 < n && hot[j + 1]) { j += 1; continue; } // bridge a 1-bucket dip
        break;
      }
      out.push({ startMs: edge(i), endMs: edge(e + 1) });
      i = e + 1;
    }
    return out;
  };

  // a) EVERY OTHER camera in the grid, each in its OWN color (cameraMotionColor).
  // Drawn BEHIND the selected camera, weakest-peak-first so that on overlap the
  // camera with the STRONGEST bucket in view paints last / reads clearest — an
  // arbitrary z-order would let a quiet camera's color bury a louder one's.
  const otherCamIds = Object.keys(pbState.intensityByCam || {}).filter(id => id !== selCamId);
  otherCamIds
    .map(id => {
      const s = pbState.intensityByCam[id];
      const peak = (s && s.buckets && s.buckets.length) ? Math.max(...s.buckets) : 0;
      return { id, s, peak };
    })
    .sort((a, b) => a.peak - b.peak)
    .forEach(({ id, s }) => drawMotion(s, false, cameraMotionColor(id)));

  if (selCamId) {
    // b) RECORDING present (selected) → muted slate base bar along the bottom.
    ctx.fillStyle = TL.REC_BASE;
    pbState.spans.forEach(s => {
      if (s.camera_id !== selCamId) return;
      const x1 = msToX(segStartMs(s));
      ctx.fillRect(x1, tBottom - baseH, Math.max(1.5, msToX(segEndMs(s)) - x1), baseH);
    });

    // c) PROMINENT selected-camera motion (two-tone envelope, own color, on top —
    // drawn last so it's never buried under another camera's band).
    const intensity = (pbState.intensity && pbState.intensity.camId === selCamId)
      ? pbState.intensity
      : (pbState.intensityByCam[selCamId] ?? null);
    drawMotion(intensity, true, cameraMotionColor(selCamId));
  }

  // d) MULTI-CAMERA overlay — where >2/3 of the in-view cameras were active at
  // once. A faint violet wash over the band plus a solid violet cap at the very
  // top of the track, so site-wide activity is glanceable regardless of which
  // single camera is selected. Distinct hue from the blue motion so it reads as a
  // different signal, not "more motion".
  const multiCamRegions = buildMultiCamRegions();
  if (multiCamRegions.length) {
    const top = TL.LABEL_H;
    const bot = tBottom;
    ctx.save();
    for (const r of multiCamRegions) {
      const xL = msToX(r.startMs);
      const xR = Math.max(xL + 2, msToX(r.endMs));
      ctx.fillStyle = TL.MULTI_WASH;
      ctx.fillRect(xL, top, xR - xL, bot - top);
      ctx.fillStyle = TL.MULTI_BAR;
      ctx.fillRect(xL, top, xR - xL, 3);
    }
    ctx.restore();
  }

  // Dim the future (right of "now") + a subtle green "now" line (live edge).
  const nowX = msToX(Date.now());
  if (nowX < cw) {
    const fx = Math.max(0, nowX);
    ctx.fillStyle = 'rgba(0,0,0,0.45)';
    ctx.fillRect(fx, TL.LABEL_H, cw - fx, ch - TL.LABEL_H - TL.BOTTOM_H);
    if (nowX >= 0) {
      ctx.strokeStyle = 'rgba(120,210,120,0.7)';
      ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(nowX, TL.LABEL_H); ctx.lineTo(nowX, ch - TL.BOTTOM_H); ctx.stroke();
    }
  }

  // Faint camera-name watermark in the track (like the commercial VMS).
  ctx.font = '9px ui-monospace, Consolas, monospace';
  ctx.textBaseline = 'middle';
  ctx.textAlign = 'left';
  ctx.fillStyle = TL.LANE_LABEL;
  ctx.fillText(selCam ? selCam.name : 'no camera selected', 6, tTop + tH / 2);

  // ── 4. Export-range brackets (if a selection is active, #9) ────────────────
  if (pbState.exportSel) {
    const xs = msToX(pbState.exportSel.startMs);
    const xe = msToX(pbState.exportSel.endMs);
    // Clamp the highlight fill to the visible canvas so an off-window selection
    // doesn't flood the whole track; only draw a handle/stroke for edges on screen.
    const lo = Math.max(0, Math.min(xs, xe));
    const hi = Math.min(cw, Math.max(xs, xe));
    if (hi > lo) {
      ctx.fillStyle = 'rgba(245,158,11,0.18)';
      ctx.fillRect(lo, TL.LABEL_H, hi - lo, ch - TL.LABEL_H - TL.BOTTOM_H);
    }
    ctx.strokeStyle = '#f5b342';
    ctx.lineWidth = 2;
    const top = TL.LABEL_H, bot = ch - TL.BOTTOM_H;
    [xs, xe].forEach(x => {
      if (x < 0 || x > cw) return; // edge off-screen — don't draw a stray marker
      ctx.beginPath();
      ctx.moveTo(x, top);
      ctx.lineTo(x, bot);
      ctx.stroke();
      // Grab handles: a tab at the TOP and BOTTOM of each edge so it reads as
      // draggable (drag an edge to adjust; Shift+drag the track to make a new one).
      ctx.fillStyle = '#f5b342';
      ctx.fillRect(x - 3, top, 6, 10);
      ctx.fillRect(x - 3, bot - 10, 6, 10);
    });
    // Duration label centred over the box.
    if (hi > lo && hi - lo > 36) {
      const dur = Math.abs(pbState.exportSel.endMs - pbState.exportSel.startMs);
      const label = pbFmtSpan(dur);
      ctx.font = '10px ui-monospace, Consolas, monospace';
      const tw = ctx.measureText(label).width;
      const cx = (lo + hi) / 2;
      ctx.fillStyle = 'rgba(20,16,8,0.8)';
      ctx.fillRect(cx - tw / 2 - 4, top + 2, tw + 8, 14);
      ctx.fillStyle = '#f7c873';
      ctx.textAlign = 'left';
      ctx.textBaseline = 'top';
      ctx.fillText(label, cx - tw / 2, top + 4);
    }
  }

  // ── Detection-event glyphs (selected camera) ───────────────────────────────
  // Per-object icons (person/vehicle/animal/…) at the times Frigate detected them
  // on the SELECTED camera, colour-coded by type. A dark disc backs each so it
  // reads over the motion bars; collision-thinned so dense clusters don't smear
  // (zoom in to separate them).
  if (selCamId && pbState.detections && pbState.detections.length) {
    const iconS = 13;
    const dcy = tTop + iconS / 2 + 1; // icon-row centre, just under the ruler
    const evs = pbState.detections
      .filter(e => e.camera_id === selCamId && e.ms >= winStart && e.ms <= winEnd)
      .sort((a, b) => a.ms - b.ms);
    let lastX = -1e9;
    for (const e of evs) {
      const x = msToX(e.ms);
      if (x - lastX < iconS) continue; // overlapping glyph → skip (revealed on zoom)
      lastX = x;
      // Near-opaque dark disc + faint ring so a glyph never washes out against a
      // tall BLUE motion cap rising into the icon row (the icons sit just under the
      // ruler; a prominent cap can reach up behind them).
      ctx.fillStyle = 'rgba(8,10,14,0.92)';
      ctx.beginPath(); ctx.arc(x, dcy, iconS / 2 + 2, 0, Math.PI * 2); ctx.fill();
      ctx.lineWidth = 1; ctx.strokeStyle = 'rgba(255,255,255,0.22)'; ctx.stroke();
      try {
        drawDetIcon(ctx, e.key, x, dcy, iconS);
      } catch {
        ctx.fillStyle = (DETECTION_ICONS[e.key] || DETECTION_ICONS.generic).color;
        ctx.beginPath(); ctx.arc(x, dcy, 3, 0, Math.PI * 2); ctx.fill();
      }
    }
  }

  // ── 5. Window-span label (centre, bottom edge) + edge timestamps ───────────
  const spanLabel = pbFmtSpan(winDur);
  ctx.fillStyle = TL.TEXT_COLOR;
  ctx.font = '10px ui-monospace, Consolas, monospace';
  ctx.textBaseline = 'bottom';
  ctx.textAlign = 'center';
  ctx.fillText(spanLabel, cw / 2, ch - 2);
  ctx.textAlign = 'left';
  ctx.fillText(pbFmtTime(winStart), 4, ch - 2);
  ctx.textAlign = 'right';
  ctx.fillText(pbFmtTime(winEnd), cw - 4, ch - 2);
  ctx.textAlign = 'left';

  // ── 6. Playhead (blue line bisecting both tracks + floating timestamp) ─────
  const phX = msToX(pbState.playheadMs);
  ctx.strokeStyle = TL.PLAYHEAD;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(phX, TL.LABEL_H - 3);
  ctx.lineTo(phX, ch - TL.BOTTOM_H);
  ctx.stroke();

  // Downward triangle marker at top
  const TRI = 6;
  ctx.fillStyle = TL.PLAYHEAD;
  ctx.beginPath();
  ctx.moveTo(phX - TRI, TL.LABEL_H - 6);
  ctx.lineTo(phX + TRI, TL.LABEL_H - 6);
  ctx.lineTo(phX, TL.LABEL_H);
  ctx.closePath();
  ctx.fill();

  // Floating timestamp at the centered playhead (on a chip for legibility).
  const phLabel = pbFmtTime(pbState.playheadMs);
  ctx.font = 'bold 10px ui-monospace, Consolas, monospace';
  ctx.textBaseline = 'top';
  ctx.textAlign = 'center';
  const lw = ctx.measureText(phLabel).width;
  const lx = Math.max(lw / 2 + 3, Math.min(phX, cw - lw / 2 - 3));
  ctx.fillStyle = 'rgba(8,12,20,0.85)';
  ctx.fillRect(lx - lw / 2 - 4, 0, lw + 8, 13);
  ctx.fillStyle = TL.PLAYHEAD;
  ctx.fillText(phLabel, lx, 1);
  ctx.textAlign = 'left';

  // Keep the per-camera color key in sync — the camera set with motion data in
  // view can change (grid edits, window pan/zoom, a fetch landing) independently
  // of anything else that would call this explicitly.
  pbInjectTimelineLegend();
}

/** Pick a human-readable grid interval for the visible window duration. */
function pbPickGridInterval(winDurMs) {
  const S    = 1_000;
  const MINS = 60_000;
  const HRS  = 3600_000;
  // Aim for ~6–8 gridlines across the canvas width.
  // Steps are chosen so labels stay readable at each zoom level.
  if (winDurMs <=  90 * S)    return 10  * S;      // 10 s  (≤90 s window)
  if (winDurMs <= 300 * S)    return 30  * S;      // 30 s  (≤5 min)
  if (winDurMs <=  15 * MINS) return 2   * MINS;   // 2 min (≤15 min)
  if (winDurMs <=  30 * MINS) return 5   * MINS;   // 5 min (≤30 min)
  if (winDurMs <=  60 * MINS) return 10  * MINS;   // 10 min (≤1 h)
  if (winDurMs <=   3 * HRS)  return 30  * MINS;   // 30 min (≤3 h)
  if (winDurMs <=   6 * HRS)  return HRS;          // 1 h   (≤6 h)
  if (winDurMs <=  24 * HRS)  return 3   * HRS;    // 3 h   (≤24 h)
  return 6 * HRS;                                   // 6 h
}

/** Format a label appropriate to the grid interval.
 *  Prefixes a short date (MM/DD) when the gridline falls on a day other than
 *  today, so scrubbing into the past never loses day context. */
function pbFmtGridLabel(epochMs, intervalMs) {
  const d  = new Date(epochMs);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  let time;
  if (intervalMs >= 3600_000) time = `${hh}:00`;
  else if (intervalMs >= 60_000) time = `${hh}:${mm}`;
  else time = `${hh}:${mm}:${ss}`;
  if (!pbIsToday(epochMs)) {
    const mon = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${mon}/${day} ${time}`;
  }
  return time;
}

/** Human-readable window duration label for the span badge. */
function pbFmtSpan(durMs) {
  const S    = 1_000;
  const MINS = 60_000;
  const HRS  = 3600_000;
  if (durMs < 60 * S)   return `${Math.round(durMs / S)}s`;
  if (durMs < HRS)      return `${Math.round(durMs / MINS)}m`;
  const h = durMs / HRS;
  return Number.isInteger(h) ? `${h}h` : `${h.toFixed(1)}h`;
}

function pbFmtTime(epochMs) {
  const d = new Date(epochMs);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  if (!pbIsToday(epochMs)) {
    const mon = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${mon}/${day} ${hh}:${mm}:${ss}`;
  }
  return `${hh}:${mm}:${ss}`;
}

// ── Timeline pointer events ───────────────────────────────────────────────────
//
// Interaction model (two-zone):
//
//   TOP RULER STRIP (y < TL.RULER_GRAB_H = 18px):
//     CLICK  (movement ≤ 4 px) → seek playhead to that time.
//     DRAG                     → PAN the time window left/right (map-drag).
//                                Dragging RIGHT shifts view EARLIER; LEFT → LATER.
//                                The time-point under the grab position stays put.
//
//   BODY (y ≥ TL.RULER_GRAB_H — motion lane + footage band):
//     CLICK  (movement ≤ 4 px) → seek playhead to that time.
//     DRAG                     → SCRUB the playhead within the current window.
//                                Maps x→time, pauses playback, seeks panes live
//                                (debounced 120 ms).  Restores play state on release.
//
//   WHEEL (any zone) → zoom (existing behaviour, unchanged).
//
// Cursor hints (set on pointermove when not dragging):
//   Ruler strip → ew-resize  (communicate horizontal scroll)
//   Body        → default    (click-to-seek feel)
//   Active drag → grabbing   (pan) or crosshair (scrub) via .dragging class

const PAN_THRESHOLD_PX = 4; // px of movement to commit to a drag

// Extend pbState with scrub-zone drag flag.
// (panIsPan already exists; we add scrubIsScrub for the body zone)
pbState.scrubIsScrub = false; // true once body-drag commits

/** True if the initial pointerdown was in the ruler grab zone. */
pbState.dragInRuler = false;

/** Active export-box drag, or null. {mode:'new',anchorMs} | {mode:'edge',edge}. */
pbState.exportDrag = null;

function pbTimelineXToMs(clientX) {
  const rect = els.pbTimeline.getBoundingClientRect();
  // Guard against a not-yet-laid-out canvas (width 0) → NaN, which would poison
  // playheadMs/window and was the cause of the "scrubber text funkiness" on first
  // paint. Fall back to the current playhead (a no-op seek).
  if (!(rect.width > 0)) return pbState.playheadMs;
  const frac = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
  return pbState.windowStartMs + frac * (pbState.windowEndMs - pbState.windowStartMs);
}

/** Return true if the canvas-relative Y coordinate falls in the ruler grab zone. */
function pbInRulerZone(clientY) {
  const rect = els.pbTimeline.getBoundingClientRect();
  return (clientY - rect.top) < TL.RULER_GRAB_H;
}

/** Inverse of pbTimelineXToMs: epoch ms → clientX (CSS px) for the current window. */
function pbMsToClientX(ms) {
  const rect = els.pbTimeline.getBoundingClientRect();
  if (!(rect.width > 0)) return rect.left;
  const dur = pbState.windowEndMs - pbState.windowStartMs;
  const frac = dur > 0 ? (ms - pbState.windowStartMs) / dur : 0;
  return rect.left + frac * rect.width;
}

// ── Hover motion-attribution readout ──────────────────────────────────────────
// As the cursor moves over the timeline (when not dragging), a floating chip
// lists WHICH cameras have motion at that instant — from the per-camera intensity
// buckets we already fetch. Zero permanent clutter; appears only on hover.
const PB_MOTION_HINT_MAX = 5; // cap names so the chip stays legible
function pbMotionCamerasAt(ms) {
  const byCam = pbState.intensityByCam || {};
  const cams = [];
  for (const [camId, s] of Object.entries(byCam)) {
    if (!s || !s.buckets || !s.buckets.length) continue;
    const span = (s.endMs - s.startMs) || 1;
    const bucketMs = s.bucketMs || (span / s.buckets.length);
    const i = Math.floor((ms - s.startMs) / bucketMs);
    if (i < 0 || i >= s.buckets.length) continue;
    if (s.buckets[i] >= TL_MOTION_ABS) {
      const cam = camById(camId);
      cams.push({ camId, name: cam ? cam.name : camId.slice(0, 6) });
    }
  }
  return cams;
}
function pbMotionHintEl() {
  let el = document.getElementById('pb-motion-hint');
  if (!el) {
    el = document.createElement('div');
    el.id = 'pb-motion-hint';
    el.className = 'pb-motion-hint';
    document.body.appendChild(el);
  }
  return el;
}
function pbShowMotionHint(clientX) {
  const ms = pbTimelineXToMs(clientX);
  const cams = pbMotionCamerasAt(ms);
  const el = pbMotionHintEl();
  const time = pbFmtTime(ms);
  // Each listed camera gets ITS OWN dot color (cameraMotionColor()) instead of one
  // generic dot, so the hover readout matches the band/legend colors 1:1.
  const body = cams.length
    ? cams.slice(0, PB_MOTION_HINT_MAX)
        .map(c => `<span class="pmh-dot" style="background:${cameraMotionColor(c.camId)}"></span>${escHtml(c.name)}`)
        .join('<span class="pmh-sep">, </span>') +
      (cams.length > PB_MOTION_HINT_MAX ? ` +${cams.length - PB_MOTION_HINT_MAX}` : '')
    : `<span class="pmh-none">no motion</span>`;
  el.innerHTML = `<span class="pmh-time">${escHtml(time)}</span>${body}`;
  el.style.display = 'block';
  const w = el.offsetWidth || 160;
  const rect = els.pbTimeline.getBoundingClientRect();
  el.style.left = `${Math.max(4, Math.min(clientX - w / 2, window.innerWidth - w - 4))}px`;
  el.style.top  = `${Math.max(4, rect.top - el.offsetHeight - 6)}px`;
}
function pbHideMotionHint() {
  const el = document.getElementById('pb-motion-hint');
  if (el) el.style.display = 'none';
}

// ── Export-range drag handles ─────────────────────────────────────────────────
const EXPORT_HANDLE_HIT_PX = 7; // px tolerance to grab an export-box edge
/** If clientX is within grab range of an export-box edge, return which edge
 *  ('start' | 'end'); else null. */
function pbExportEdgeAt(clientX) {
  if (!pbState.exportSel) return null;
  const dStart = Math.abs(clientX - pbMsToClientX(pbState.exportSel.startMs));
  const dEnd   = Math.abs(clientX - pbMsToClientX(pbState.exportSel.endMs));
  if (Math.min(dStart, dEnd) > EXPORT_HANDLE_HIT_PX) return null;
  return dStart <= dEnd ? 'start' : 'end';
}

// ── Export-range selection (#9) — the commercial VMS "time selection" brackets ──────────
// Right-click the timeline → set the start/end of an export range. Two amber
// handles bracket the region (drawn in pbDrawTimeline); "Export selection…"
// opens the export dialog pre-filled with the bracketed range.
function pbSetExportEdge(which, tMs) {
  if (!Number.isFinite(tMs)) return;
  tMs = Math.min(tMs, Date.now()); // never select past "now"
  const sel = pbState.exportSel ? { ...pbState.exportSel } : { startMs: null, endMs: null };
  if (which === 'start') sel.startMs = tMs; else sel.endMs = tMs;
  // Seed the missing edge so a range is always visible once one edge is set.
  if (sel.startMs == null) sel.startMs = Math.min(tMs, pbState.playheadMs);
  if (sel.endMs == null)   sel.endMs   = Math.max(tMs, pbState.playheadMs);
  pbState.exportSel = sel;
  pbDrawTimeline();
}

function pbClearExportSel() {
  pbState.exportSel = null;
  pbDrawTimeline();
}

/** Generic single-level floating menu reusing the #ctx-menu element.
 *  items: [{label, onClick, disabled} | {sep:true}]. */
function pbShowMenu(items, x, y) {
  ctxClose();
  const menu = document.getElementById('ctx-menu');
  if (!menu) return;
  menu.innerHTML = '';
  items.forEach(it => {
    if (it.sep) { menu.appendChild(ctxMakeSep()); return; }
    const el = ctxMakeItem(it.label, false);
    if (it.disabled) {
      el.classList.add('disabled');
      el.style.opacity = '0.4';
      el.style.pointerEvents = 'none';
    } else {
      el.addEventListener('click', () => { ctxClose(); it.onClick(); });
    }
    menu.appendChild(el);
  });
  menu.style.display = 'block';
  menu.style.left = '0';
  menu.style.top = '0';
  const mw = menu.offsetWidth || 180;
  const mh = menu.offsetHeight || 120;
  menu.style.left = `${Math.max(2, Math.min(x, window.innerWidth - mw - 4))}px`;
  menu.style.top  = `${Math.max(2, Math.min(y, window.innerHeight - mh - 4))}px`;
}

function pbTimelineContextMenu(e) {
  e.preventDefault();
  const tMs = pbTimelineXToMs(e.clientX);
  const hasSel = !!pbState.exportSel;
  pbShowMenu([
    { label: 'Set export start here', onClick: () => pbSetExportEdge('start', tMs) },
    { label: 'Set export end here',   onClick: () => pbSetExportEdge('end', tMs) },
    { sep: true },
    { label: 'Export selection…', disabled: !hasSel, onClick: () => exportOpenDialog() },
    { label: 'Clear selection',   disabled: !hasSel, onClick: pbClearExportSel },
  ], e.clientX, e.clientY);
}

function pbTimelinePointerDown(e) {
  e.preventDefault();
  try { els.pbTimeline.setPointerCapture(e.pointerId); } catch { /* synthetic/edge */ }
  pbHideMotionHint();

  // Export-range box: grab an existing edge handle, or Shift+drag to draw a new
  // range. Otherwise fall through to the normal pan/seek behaviour below.
  const edge = pbExportEdgeAt(e.clientX);
  if (edge) {
    pbState.exportDrag = { mode: 'edge', edge };
    pbState.timelineDragging = true;
    return;
  }
  if (e.shiftKey) {
    const anchor = Math.min(pbTimelineXToMs(e.clientX), Date.now());
    pbState.exportSel = { startMs: anchor, endMs: anchor };
    pbState.exportDrag = { mode: 'new', anchorMs: anchor };
    pbState.timelineDragging = true;
    pbDrawTimeline();
    return;
  }
  pbState.exportDrag = null;

  pbState.timelineDragging   = true;
  pbState.wasPlayingBeforeDrag = pbState.playing;
  pbState.panStartX              = e.clientX;
  pbState.panStartWindowStartMs  = pbState.windowStartMs;
  pbState.panStartWindowEndMs    = pbState.windowEndMs;
  pbState.panStartPlayheadMs     = pbState.playheadMs;
  pbState.panTotalDx             = 0;
  pbState.panIsPan               = false;
  // Don't pause yet — wait to see if this is a click or a drag.
}

function pbTimelinePointerMove(e) {
  // Export-box drag in progress: drag the edge / sweep a new range.
  if (pbState.exportDrag) {
    e.preventDefault();
    const ms = Math.min(pbTimelineXToMs(e.clientX), Date.now());
    const sel = pbState.exportSel || { startMs: ms, endMs: ms };
    if (pbState.exportDrag.mode === 'new') {
      sel.startMs = Math.min(pbState.exportDrag.anchorMs, ms);
      sel.endMs   = Math.max(pbState.exportDrag.anchorMs, ms);
    } else if (pbState.exportDrag.edge === 'start') {
      sel.startMs = ms;
    } else {
      sel.endMs = ms;
    }
    pbState.exportSel = sel;
    els.pbTimeline.style.cursor = 'ew-resize';
    pbDrawTimeline();
    return;
  }

  if (!pbState.timelineDragging) {
    // Hover: ew-resize over an export-box edge; otherwise grab. Plus the
    // motion-attribution readout (which cameras moved at the cursor's time).
    els.pbTimeline.style.cursor = pbExportEdgeAt(e.clientX) ? 'ew-resize' : 'grab';
    pbShowMotionHint(e.clientX);
    return;
  }
  pbHideMotionHint();
  e.preventDefault();

  const dx = e.clientX - pbState.panStartX;
  pbState.panTotalDx = dx;

  // Centered model: dragging ANYWHERE scrolls time through the fixed center
  // (drag right = back in time, content follows the finger). The playhead stays
  // centered; the window recenters on it.
  if (!pbState.panIsPan && Math.abs(dx) > PAN_THRESHOLD_PX) {
    pbState.panIsPan = true;
    els.pbTimeline.classList.add('dragging');
    if (pbState.playing) {
      pbState.playing = false;
      pbUpdatePlayPauseBtn();
      pbApplyPausedToAllPanes();
    }
  }
  if (!pbState.panIsPan) return; // still deciding (could be a click)

  const rect   = els.pbTimeline.getBoundingClientRect();
  const winDur = pbState.panStartWindowEndMs - pbState.panStartWindowStartMs;
  if (!(rect.width > 0) || !(winDur > 0)) return; // not laid out yet — avoid NaN
  const msPx   = winDur / rect.width;     // ms per CSS pixel
  const deltaMs = -dx * msPx;             // right drag = earlier in time
  const next = pbState.panStartPlayheadMs + deltaMs;
  if (!Number.isFinite(next)) return;
  pbState.playheadMs = Math.min(next, Date.now());
  pbRecenter();

  pbUpdateTimeDisplay();
  pbDrawTimeline();
  pbSchedulePanReload();
}

function pbTimelinePointerUp(e) {
  // Finalize an export-box drag (order the edges; discard an accidental tiny
  // shift-click). Never falls through to the pan/seek logic.
  if (pbState.exportDrag) {
    if (pbState.exportSel) {
      let { startMs, endMs } = pbState.exportSel;
      if (startMs > endMs) [startMs, endMs] = [endMs, startMs];
      pbState.exportSel = (pbState.exportDrag.mode === 'new' && endMs - startMs < 500)
        ? null // a stray shift-click with no sweep → no selection
        : { startMs, endMs };
    }
    pbState.exportDrag = null;
    pbState.timelineDragging = false;
    els.pbTimeline.style.cursor = 'grab';
    try { els.pbTimeline.releasePointerCapture(e.pointerId); } catch { /* synthetic/edge */ }
    pbDrawTimeline();
    return;
  }

  if (!pbState.timelineDragging) return;
  pbState.timelineDragging = false;
  els.pbTimeline.classList.remove('dragging', 'dragging-scrub');
  els.pbTimeline.style.cursor = 'grab';
  try { els.pbTimeline.releasePointerCapture(e.pointerId); } catch { /* synthetic/edge */ }

  if (pbState.panIsPan) {
    // Drag-scroll ended — flush the debounced reload + resolve panes at the
    // new (centered) playhead, then restore play state.
    clearTimeout(pbState.panReloadTimer);
    pbState.panReloadTimer = null;
    pbReloadTimeline().then(() => pbResolveAllPanes(pbState.playheadMs, true));
    if (pbState.wasPlayingBeforeDrag) {
      pbState.playing = true;
      pbUpdatePlayPauseBtn();
      pbApplyPausedToAllPanes();
    }
  } else {
    // Click (no drag): jump to the clicked time — recenters on it.
    if (pbState.playing) {
      pbState.playing = false;
      pbUpdatePlayPauseBtn();
      pbApplyPausedToAllPanes();
    }
    void pbJumpTo(pbTimelineXToMs(e.clientX));
  }
}

/**
 * Debounced reload during live panning — fires 150 ms after the last move.
 * This keeps spans/motion current as the user drags through time without
 * hammering the server on every pixel.
 */
function pbSchedulePanReload() {
  // P2: during a drag, only do a CHEAP in-segment keyframe seek so the visible frame
  // tracks the scrub — do NOT reload the timeline or force-resolve every pane (that
  // floods /play/ + /timeline on each pause and thrashes mpv). The heavy reload +
  // cross-segment resolve runs exactly once, on pointerup (pbTimelinePointerUp).
  clearTimeout(pbState.panReloadTimer);
  pbState.panReloadTimer = setTimeout(() => {
    pbState.panReloadTimer = null;
    void pbSeekAllPanes(pbState.playheadMs);
  }, 100);
}

/** Debounced scrub after a click-seek: resolves panes 120 ms after last move. */
function pbScheduleScrub(tMs) {
  clearTimeout(pbState.scrubTimer);
  pbState.scrubTimer = setTimeout(async () => {
    pbState.scrubTimer = null;
    // Cheap in-segment seek first, then full resolve for cross-segment jumps
    await pbSeekAllPanes(tMs);
    await pbResolveAllPanes(tMs, false);
  }, 120);
}

// ── Timeline zoom ─────────────────────────────────────────────────────────────
//
// Zoom keeps the time under the mouse (or window centre) fixed and expands /
// contracts the visible duration symmetrically around that anchor point.
// Duration is clamped to PB_ZOOM_STEPS bounds (2 min – 24 h).

/**
 * Zoom by snapping to the nearest step in PB_ZOOM_STEPS.
 * direction: -1 = zoom in (shorter window), +1 = zoom out (longer window).
 * anchorMs: the epoch-ms time that should stay fixed on screen (defaults to
 *   window centre).
 */
/** Current zoom step index (nearest step >= the window duration). */
function pbCurrentZoomIdx() {
  const winDur = pbState.windowEndMs - pbState.windowStartMs;
  let idx = PB_ZOOM_STEPS.findIndex(s => s >= winDur);
  if (idx === -1) idx = PB_ZOOM_STEPS.length - 1;
  return idx;
}

/** Step the zoom by `direction` (±1), anchored on `anchorMs` (default centre). */
async function pbZoom(direction, anchorMs) {
  const idx = pbCurrentZoomIdx();
  const nextIdx = Math.max(0, Math.min(PB_ZOOM_STEPS.length - 1, idx + direction));
  if (nextIdx === idx) return; // already at limit
  await pbSetZoomIndex(nextIdx, anchorMs);
}

/** Set the zoom to an absolute step index. Centered model: the playhead stays
 *  fixed at center; only the visible span changes. (`anchorMs` is ignored — zoom
 *  always pivots on the centered playhead.) */
async function pbSetZoomIndex(idx, _anchorMs) {
  idx = Math.max(0, Math.min(PB_ZOOM_STEPS.length - 1, idx));
  const newDur = PB_ZOOM_STEPS[idx];
  pbState.windowStartMs = pbState.playheadMs - newDur / 2;
  pbState.windowEndMs   = pbState.playheadMs + newDur / 2;

  pbDrawTimeline();
  pbUpdateZoomLabel();
  await pbReloadTimeline();
  await pbResolveAllPanes(pbState.playheadMs, true);
}

/** Update the span label button text (e.g. "1h", "15m"). */
function pbUpdateZoomLabel() {
  const btn = document.getElementById('pb-zoom-label');
  if (btn) btn.textContent = pbFmtSpan(pbState.windowEndMs - pbState.windowStartMs);
  // Keep the scale slider in sync with wheel/button zoom (inverted: right = in).
  const slider = document.getElementById('pb-zoom-slider');
  if (slider) slider.value = String((PB_ZOOM_STEPS.length - 1) - pbCurrentZoomIdx());
}

/** Mouse-wheel zoom handler — zooms around the centered playhead. */
function pbTimelineWheel(e) {
  e.preventDefault();
  // deltaY > 0 = scroll down = zoom out (wider window); < 0 = zoom in.
  pbZoom(e.deltaY > 0 ? 1 : -1);
}

// =============================================================================
// EXPORT MODULE
// =============================================================================
//
// Architecture:
//   - An "⬇ Export" button is injected into #pb-transport (right cluster)
//     alongside the zoom group, by exportInjectButton() called from
//     DOMContentLoaded after pbInjectZoomButtons().
//   - Clicking it opens the export dialog (#export-dialog / #export-backdrop).
//   - The dialog pre-fills the playback window times and lists cameras on wall.
//   - On submit: POST /export → poll GET /export/{id} every 1500 ms → on done,
//     trigger one blob download per output file.
//   - Download strategy: fetch the authed URL → blob → object URL → <a download>
//     → click(). Falls back to window.open() if the object URL creation fails
//     (Tauri webview restriction — see note at bottom of module).
//   - Poll is cancelled cleanly on dialog close/cancel at any point.
// =============================================================================

// ── Clips tab ─────────────────────────────────────────────────────────────────
const clipsState = {
  type: 'all',
  cam: '',
  hours: +(localStorage.getItem('clips_hours')) || 24,
  // Paging + date jump. anchorEnd = window end (null = live/now); windowStart =
  // the window start; pageEnds = stack of per-page end-cursors; pageIdx = current
  // page (0-based); oldestShown = oldest clip on the current page (Older cursor).
  anchorEnd: null,
  windowStart: null,
  pageEnds: [],
  pageIdx: 0,
  oldestShown: null,
  quality: 'preview',
  currentId: null,
  wired: false,
  // Server-configured motion-highlight duration (seconds; 0 = off).
  motionHighlightSeconds: 0,
  // Clip-player digital zoom: scale + pan (px), plus flags for the motion-
  // highlight auto-zoom and whether the user has taken manual control.
  zoom: { s: 1, tx: 0, ty: 0 },
  userZoomed: false,
  autoZoomTimer: null,
  dragging: false,
  // Clip-load watchdog: retry a stalled open instead of making the user reopen.
  loadWatchdog: null,
  loadAttempt: 0,
  // Lazy thumbnail loading: the live IntersectionObserver (torn down + rebuilt on
  // each grid render) plus a small bounded-concurrency gate so a scroll that
  // reveals many tiles at once doesn't fire dozens of token mints / image loads
  // simultaneously. Visible tiles are loaded first (observer fires top-down).
  thumbObserver: null,
  thumbInflight: 0,
  thumbQueue: [],
};
// Max concurrent thumbnail loads (token mint + image fetch) in flight at once.
const CLIPS_THUMB_CONCURRENCY = 6;

function clipsEnter() {
  if (!clipsState.wired) {
    clipsState.wired = true;
    document.querySelectorAll('.clips-type').forEach(btn => {
      btn.addEventListener('click', () => {
        document.querySelectorAll('.clips-type').forEach(x => x.classList.toggle('active', x === btn));
        clipsState.type = btn.dataset.ctype;
        clipsLoad();
      });
    });
    document.getElementById('clips-cam')?.addEventListener('change', e => { clipsState.cam = e.target.value; clipsLoad(); });
    document.getElementById('clips-range')?.addEventListener('change', e => {
      clipsState.hours = +e.target.value;
      localStorage.setItem('clips_hours', String(clipsState.hours));
      clipsLoad();
    });
    document.getElementById('clips-density-btn')?.addEventListener('click', () => {
      // Cycle the tile size on each click: compact → normal → large → compact.
      const order = ['compact', 'normal', 'large'];
      const cur = order.indexOf(options.clipsDensity);
      options.clipsDensity = order[(cur + 1) % order.length] || 'normal';
      saveOptions();
      applyClipsDensity();
    });
    document.getElementById('clips-refresh')?.addEventListener('click', () => clipsLoad());
    // Date/time jump: the picked moment becomes the window's END (empty = live/now).
    document.getElementById('clips-when')?.addEventListener('change', e => {
      const v = e.target.value; // 'YYYY-MM-DDTHH:mm' in local time, or '' when cleared
      const d = v ? new Date(v) : null;
      clipsState.anchorEnd = (d && !isNaN(d.getTime())) ? d : null;
      clipsLoad();
    });
    document.getElementById('clips-now')?.addEventListener('click', () => {
      clipsState.anchorEnd = null;
      const w = document.getElementById('clips-when'); if (w) w.value = '';
      clipsLoad();
    });
    document.getElementById('clips-newer')?.addEventListener('click', () => clipsLoad('newer'));
    document.getElementById('clips-older')?.addEventListener('click', () => clipsLoad('older'));
    document.getElementById('clips-player-close')?.addEventListener('click', clipsClosePlayer);
    document.getElementById('clips-player')?.addEventListener('click', e => { if (e.target.id === 'clips-player') clipsClosePlayer(); });
    document.getElementById('clips-player-quality')?.addEventListener('click', clipsToggleQuality);
    document.getElementById('clips-player-snapshot')?.addEventListener('click', clipsSnapshot);
    document.getElementById('clips-player-bookmark')?.addEventListener('click', clipsBookmark);
    document.getElementById('clips-player-playback')?.addEventListener('click', () => {
      // Jump to THIS clip's footage on the playback timeline (camera + moment),
      // not just the playback tab. Reuses the detection-event open flow.
      const c = clipsState.byId?.[clipsState.currentId];
      clipsClosePlayer();
      if (c) void goToPlaybackEvent(c.camera_id, Date.parse(c.start_ts));
      else activateTab('playback');
    });
  }
  // Reflect the persisted range in the selector.
  const rangeSel = document.getElementById('clips-range');
  if (rangeSel) rangeSel.value = String(clipsState.hours);
  // Apply the persisted tile density (also refreshes the button label).
  applyClipsDensity();
  // Populate the camera filter (once cameras are known).
  const camSel = document.getElementById('clips-cam');
  if (camSel && camSel.options.length <= 1 && Array.isArray(state.cameras)) {
    for (const c of state.cameras) {
      const o = document.createElement('option');
      o.value = c.id; o.textContent = c.name;
      camSel.appendChild(o);
    }
  }
  clipsLoad();
}

// Apply the persisted tile-density choice to the grid as a CSS modifier class.
// 'normal' = no modifier (the base .clips-grid rule); compact/large tune the
// auto-fill min tile width + gap (see styles.css .density-*).
function applyClipsDensity() {
  const d = options.clipsDensity === 'compact' || options.clipsDensity === 'large'
    ? options.clipsDensity : 'normal';
  // Update the cycle button's label to the current size.
  const btn = document.getElementById('clips-density-btn');
  if (btn) btn.textContent = 'Tiles: ' + d.charAt(0).toUpperCase() + d.slice(1);
  const grid = document.getElementById('clips-grid');
  if (!grid) return;
  grid.classList.remove('density-compact', 'density-large');
  if (d !== 'normal') grid.classList.add('density-' + d);
}

const CLIPS_PAGE = 200; // clips per page

// Load clips one PAGE at a time, REPLACING the grid so the DOM never grows
// unbounded (at most ~CLIPS_PAGE tiles on screen). `nav`: undefined = fresh page 1
// (window ends at the anchor date, or now); 'older'/'newer' = paginate by time
// cursor. `pageEnds` is a stack of per-page end-cursors so we can walk back.
async function clipsLoad(nav) {
  const grid = document.getElementById('clips-grid');
  const empty = document.getElementById('clips-empty');
  const count = document.getElementById('clips-count');
  const pager = document.getElementById('clips-pager');
  const newerBtn = document.getElementById('clips-newer');
  const olderBtn = document.getElementById('clips-older');
  const pageLbl = document.getElementById('clips-page');
  if (!grid) return;
  const cams = clipsState.cam ? [clipsState.cam] : (state.cameras || []).map(c => c.id);

  if (nav === 'older') {
    if (!clipsState.oldestShown) return;
    // Next page ends just before this page's oldest clip (−1ms avoids re-showing it).
    const nextEnd = new Date(new Date(clipsState.oldestShown).getTime() - 1);
    if (clipsState.pageIdx + 1 >= clipsState.pageEnds.length) clipsState.pageEnds.push(nextEnd);
    clipsState.pageIdx++;
  } else if (nav === 'newer') {
    if (clipsState.pageIdx <= 0) return;
    clipsState.pageIdx--;
  } else {
    // Fresh: page 1 from the anchor (a picked date, or now); window = range hours.
    const end0 = clipsState.anchorEnd ? new Date(clipsState.anchorEnd) : new Date();
    clipsState.windowStart = new Date(end0.getTime() - clipsState.hours * 3600 * 1000);
    clipsState.pageEnds = [end0];
    clipsState.pageIdx = 0;
  }

  clipsResetThumbLoader();
  grid.innerHTML = '<div class="clips-empty">Loading…</div>';
  empty?.classList.add('hidden');
  if (!cams.length) { grid.innerHTML = ''; empty?.classList.remove('hidden'); pager?.classList.add('hidden'); return; }

  const start = clipsState.windowStart;
  const end = clipsState.pageEnds[clipsState.pageIdx];
  const url = `${state.server}/clips?camera_ids=${cams.join(',')}`
    + `&start=${encodeURIComponent(start.toISOString())}&end=${encodeURIComponent(end.toISOString())}`
    + `&type=${clipsState.type}&limit=${CLIPS_PAGE}`;
  let data;
  try {
    const res = await fetchWithTimeout(url, { headers: authHeaders() });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    data = await res.json();
  } catch (e) {
    grid.innerHTML = `<div class="clips-empty">Couldn't load clips: ${escHtml(String(e.message || e))}</div>`;
    return;
  }
  const clips = data.clips || [];
  clipsState.motionHighlightSeconds = +data.motion_highlight_seconds || 0;
  clipsState.byId = {};
  for (const c of clips) clipsState.byId[c.id] = c;
  clipsState.oldestShown = clips.length ? new Date(clips[clips.length - 1].start_ts) : null;

  if (!clips.length) {
    grid.innerHTML = ''; empty?.classList.remove('hidden');
    if (count) count.textContent = '';
    updateClipsPager(pager, newerBtn, olderBtn, pageLbl, 0);
    return;
  }
  grid.innerHTML = clips.map(clipCardHtml).join('');
  grid.querySelectorAll('.clip-card').forEach(card => {
    card.addEventListener('click', () => clipsPlay(card.dataset.id, card.dataset.label));
  });
  if (count) count.textContent = `${clips.length} clip${clips.length !== 1 ? 's' : ''}`;
  updateClipsPager(pager, newerBtn, olderBtn, pageLbl, clips.length);
  grid.scrollTop = 0; // start each page at its newest clip
  clipsFillThumbnails(grid);
}

// Older is offered when the page came back full (probably more); Newer when past
// page 1. The pager hides entirely on a single short page (everything fit).
function updateClipsPager(pager, newerBtn, olderBtn, pageLbl, pageCount) {
  const hasOlder = pageCount >= CLIPS_PAGE;
  const hasNewer = clipsState.pageIdx > 0;
  if (pager) pager.classList.toggle('hidden', !hasOlder && !hasNewer);
  if (newerBtn) newerBtn.disabled = !hasNewer;
  if (olderBtn) olderBtn.disabled = !hasOlder;
  if (pageLbl) pageLbl.textContent = (hasOlder || hasNewer) ? `Page ${clipsState.pageIdx + 1}` : '';
}

function clipCardHtml(c) {
  const t = new Date(c.start_ts);
  const time = t.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const dur = c.duration_ms ? Math.round(c.duration_ms / 1000) + 's' : '';
  const badge = c.kind === 'motion' ? 'Motion' : (c.label || 'Detection');
  // The thumbnail's background-image is filled in AFTER render (clipsFillThumbnails)
  // so its URL can carry a short-lived per-camera scoped token instead of the full
  // login JWT. data-cam + data-thumb (the server-relative thumbnail URL) drive that.
  return `<div class="clip-card${c.viewed ? ' watched' : ''}" data-id="${escHtml(c.id)}" data-label="${escHtml(badge)}" data-cam="${escHtml(c.camera_id || '')}" data-thumb="${escHtml(c.thumbnail_url || '')}">
    <div class="clip-thumb">
      <span class="clip-badge">${escHtml(badge)}</span>
      ${dur ? `<span class="clip-dur">${dur}</span>` : ''}
    </div>
    <div class="clip-meta">
      <div class="clip-cam">${escHtml(c.camera_name || '')}</div>
      <div class="clip-time">${escHtml(time)}</div>
    </div>
  </div>`;
}

// Tear down the lazy-thumbnail loader (observer + pending queue). Called before
// each grid re-render so stale cards aren't loaded and the in-flight gate resets.
function clipsResetThumbLoader() {
  if (clipsState.thumbObserver) { clipsState.thumbObserver.disconnect(); clipsState.thumbObserver = null; }
  clipsState.thumbQueue = [];
  clipsState.thumbInflight = 0;
}

// Lazily fill each rendered clip card's thumbnail with a scoped-media-token URL.
// Rather than firing a token mint + image load for EVERY tile the moment the grid
// renders (a request stampede on a full window of clips), we observe each card and
// only load its thumbnail once it scrolls near the viewport — visible tiles first,
// since the observer fires top-down. Loads run through a small bounded-concurrency
// gate so a fast scroll revealing many tiles doesn't burst dozens at once. The
// per-camera token cache still dedupes, so a wall of clips from one camera costs
// one mint. Cards whose token can't be minted stay thumbnail-less (no JWT fallback).
function clipsFillThumbnails(grid) {
  // Only pick up cards not already observed — so an append pass adds just its new
  // cards to the existing observer instead of re-observing the whole grid.
  const cards = Array.from(grid.querySelectorAll('.clip-card[data-thumb]:not([data-obs])'));
  if (!cards.length) return;
  for (const card of cards) card.dataset.obs = '1';

  // Fallback: no IntersectionObserver (very old WebView) — load eagerly but still
  // bounded, so behaviour is correct even without the lazy path.
  if (typeof IntersectionObserver === 'undefined') {
    for (const card of cards) clipsEnqueueThumb(card);
    return;
  }

  // One persistent observer per grid render (fresh load resets it via
  // clipsResetThumbLoader). Load a card once, then stop observing it. rootMargin
  // pre-loads a viewport's worth below the fold so scrolling reveals warm thumbs.
  if (!clipsState.thumbObserver) {
    clipsState.thumbObserver = new IntersectionObserver((entries, obs) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        obs.unobserve(entry.target);
        clipsEnqueueThumb(entry.target);
      }
    }, { root: grid, rootMargin: '400px 0px', threshold: 0.01 });
  }
  for (const card of cards) clipsState.thumbObserver.observe(card);
}

// Queue a single card's thumbnail load behind the concurrency gate.
function clipsEnqueueThumb(card) {
  clipsState.thumbQueue.push(card);
  clipsPumpThumbQueue();
}

// Drain the thumbnail queue up to CLIPS_THUMB_CONCURRENCY loads in flight.
function clipsPumpThumbQueue() {
  while (clipsState.thumbInflight < CLIPS_THUMB_CONCURRENCY && clipsState.thumbQueue.length) {
    const card = clipsState.thumbQueue.shift();
    clipsState.thumbInflight++;
    clipsLoadOneThumb(card).finally(() => {
      clipsState.thumbInflight--;
      clipsPumpThumbQueue();
    });
  }
}

// Mint the scoped token, resolve the thumbnail URL, and set it as the card's
// background-image. Preloads via an Image() so a decode error leaves the black
// placeholder rather than a broken-image flash. No-op if the card was detached
// (grid re-rendered) or the token couldn't be minted.
async function clipsLoadOneThumb(card) {
  const cam = card.dataset.cam;
  const rel = card.dataset.thumb;
  if (!cam || !rel) return;
  if (!card.isConnected) return; // grid re-rendered before we got here
  const url = await mediaUrlForCamera(cam, rel);
  if (!url) return;             // token mint failed — stay thumbnail-less (no JWT fallback)
  if (!card.isConnected) return; // re-rendered while we awaited the token
  const thumb = card.querySelector('.clip-thumb');
  if (!thumb) return;
  // Preload so a failed fetch/decode doesn't paint a broken image over the black tile.
  await new Promise((resolve) => {
    const img = new Image();
    img.onload = () => {
      if (card.isConnected && thumb.isConnected) {
        thumb.style.backgroundImage = `url('${url.replace(/'/g, '%27')}')`;
      }
      resolve();
    };
    img.onerror = () => resolve(); // leave the black placeholder
    img.src = url;
  });
}

// Build the clip <video> source URL carrying a short-lived per-camera scoped media
// token (resolved from the clip's camera_id) instead of the full login JWT. Async
// because minting/refreshing the token may need a round-trip; callers await it
// before assigning video.src. Returns null if no token could be minted (the caller
// leaves the source unchanged / its watchdog retries — never falls back to the JWT).
async function clipsClipUrl(id, quality) {
  const cam = clipsState.byId?.[id]?.camera_id;
  if (!cam) return null;
  return mediaUrlForCamera(cam, `/clip/${encodeURIComponent(id)}/clip.mp4?q=${quality}`);
}

// Mark a clip watched (server-side, per-user) + dim its card immediately.
function clipsMarkViewed(id) {
  const card = document.querySelector(`.clip-card[data-id="${CSS.escape(id)}"]`);
  if (card) card.classList.add('watched');
  fetchWithTimeout(`${state.server}/clips/viewed`, {
    method: 'POST',
    headers: { ...authHeaders(), 'Content-Type': 'application/json' },
    body: JSON.stringify({ id }),
  }).catch(() => {});
}

// ── Clip-player digital zoom ────────────────────────────────────────────────
// Mirrors the playback pane wheel-zoom: scroll to zoom toward the cursor, drag to
// pan when zoomed, double-click to reset. The motion-highlight auto-zoom (below)
// drives the SAME transform so a manual gesture seamlessly takes over.
const CLIP_ZOOM_MAX = 5;

function clipsApplyZoom(s, tx, ty, animate) {
  const video = document.getElementById('clips-player-video');
  if (!video) return;
  s = Math.max(1, Math.min(CLIP_ZOOM_MAX, s));
  // Clamp pan so the frame edges never pull inside the viewport.
  const W = video.clientWidth || 1, H = video.clientHeight || 1;
  const mx = (s - 1) * W / 2, my = (s - 1) * H / 2;
  tx = Math.max(-mx, Math.min(mx, tx));
  ty = Math.max(-my, Math.min(my, ty));
  clipsState.zoom = { s, tx, ty };
  video.style.transformOrigin = 'center center';
  video.style.transition = animate ? 'transform 0.45s ease' : 'none';
  video.style.transform = `translate(${tx}px, ${ty}px) scale(${s})`;
  video.style.cursor = s > 1 ? 'grab' : '';
}

function clipsResetZoom(animate) {
  if (clipsState.autoZoomTimer) { clearTimeout(clipsState.autoZoomTimer); clipsState.autoZoomTimer = null; }
  clipsState.userZoomed = false;
  clipsState.dragging = false;
  clipsApplyZoom(1, 0, 0, !!animate);
}

// If this clip is a motion clip with a captured region and the server enabled a
// highlight duration, ease into framing that region, hold, then ease back out.
// Zoom the clip player to a normalized [x,y,w,h] motion region. Returns true if it
// zoomed (region present + small enough to be worth it). Shared by the automatic
// highlight and the manual "Zoom to motion" button.
function clipsZoomToBbox(bb, animate) {
  const video = document.getElementById('clips-player-video');
  if (!video || !Array.isArray(bb) || bb.length !== 4) return false;
  const [bx, by, bw, bh] = bb;
  const region = Math.max(bw, bh);
  // Skip when there's no region or it's already most of the frame (no benefit).
  if (!(region > 0) || region > 0.7) return false;
  const W = video.clientWidth || 1, H = video.clientHeight || 1;
  const s = Math.min(4, Math.max(1.4, 0.9 / region));
  const cx = bx + bw / 2, cy = by + bh / 2;
  clipsApplyZoom(s, -s * (cx - 0.5) * W, -s * (cy - 0.5) * H, animate);
  return true;
}

function clipsMaybeHighlight(c) {
  // Client option (Options dialog) gates the auto-zoom-to-motion behavior.
  if (options.zoomClipsToMotion === false) return;
  const hl = clipsState.motionHighlightSeconds || 0;
  const bb = c && c.motion_bbox;
  if (!(hl > 0) || c.kind !== 'motion' || !Array.isArray(bb) || bb.length !== 4) return;
  const video = document.getElementById('clips-player-video');
  if (!video) return;
  const run = () => {
    if (clipsState.userZoomed || clipsState.currentId !== c.id) return;
    if (!clipsZoomToBbox(bb, true)) return;
    clipsState.autoZoomTimer = setTimeout(() => {
      clipsState.autoZoomTimer = null;
      if (!clipsState.userZoomed && clipsState.currentId === c.id) clipsApplyZoom(1, 0, 0, true);
    }, hl * 1000);
  };
  if (video.videoWidth) run();
  else video.addEventListener('loadeddata', run, { once: true });
}

// Wire the zoom gestures once. The video keeps its native controls; a manual
// gesture cancels any in-flight auto-zoom.
function clipsWireZoom() {
  const video = document.getElementById('clips-player-video');
  if (!video || video.dataset.zoomWired) return;
  video.dataset.zoomWired = '1';
  // Clip-load watchdog hooks: playback starting cancels the retry; a media error
  // triggers an immediate retry (bounded by CLIP_MAX_RETRIES).
  video.addEventListener('playing', clipsClearWatchdog);
  video.addEventListener('error', () => { if (clipsState.currentId) clipsRetryLoad(); });
  const takeOver = () => {
    if (clipsState.autoZoomTimer) { clearTimeout(clipsState.autoZoomTimer); clipsState.autoZoomTimer = null; }
    clipsState.userZoomed = true;
  };
  video.addEventListener('wheel', e => {
    e.preventDefault();
    takeOver();
    const { s, tx, ty } = clipsState.zoom;
    const ns = Math.max(1, Math.min(CLIP_ZOOM_MAX, s * (e.deltaY < 0 ? 1.15 : 1 / 1.15)));
    if (ns === 1) { clipsResetZoom(true); return; }
    // Keep the point under the cursor fixed while scaling.
    const r = video.getBoundingClientRect();
    const px = e.clientX - r.left - r.width / 2;
    const py = e.clientY - r.top - r.height / 2;
    const k = ns / s;
    clipsApplyZoom(ns, px - (px - tx) * k, py - (py - ty) * k, false);
  }, { passive: false });
  video.addEventListener('pointerdown', e => {
    if (clipsState.zoom.s <= 1) return; // let native controls handle clicks
    clipsState.dragging = true;
    clipsState._px = e.clientX; clipsState._py = e.clientY;
    video.style.cursor = 'grabbing';
    try { video.setPointerCapture(e.pointerId); } catch { /* ignore */ }
  });
  video.addEventListener('pointermove', e => {
    if (!clipsState.dragging) return;
    const { s, tx, ty } = clipsState.zoom;
    clipsApplyZoom(s, tx + (e.clientX - clipsState._px), ty + (e.clientY - clipsState._py), false);
    clipsState._px = e.clientX; clipsState._py = e.clientY;
  });
  const endDrag = () => { clipsState.dragging = false; const v = document.getElementById('clips-player-video'); if (v && clipsState.zoom.s > 1) v.style.cursor = 'grab'; };
  video.addEventListener('pointerup', endDrag);
  video.addEventListener('pointercancel', endDrag);
  video.addEventListener('dblclick', e => { e.preventDefault(); clipsResetZoom(true); });
}

// ── Clip-load watchdog ──────────────────────────────────────────────────────
// Occasionally a clip's <video> stalls on open (slow first byte / a transient
// network blip) and just sits there; closing and reopening "fixes" it. This arms
// a timer on open and, if playback hasn't actually started, force-reloads the
// source — up to CLIP_MAX_RETRIES times — so the user doesn't have to.
const CLIP_LOAD_TIMEOUT_MS = 4500;
const CLIP_MAX_RETRIES = 2;

function clipsClearWatchdog() {
  if (clipsState.loadWatchdog) { clearTimeout(clipsState.loadWatchdog); clipsState.loadWatchdog = null; }
}

function clipsIsPlaying(v) {
  return !!v && !v.paused && !v.ended && v.readyState >= 3 && v.currentTime > 0;
}

// Re-arm a one-shot check: if the current clip isn't actually playing by the
// deadline, retry the load. Cancelled by the 'playing' event (clipsWireZoom).
function clipsArmWatchdog() {
  clipsClearWatchdog();
  const id = clipsState.currentId;
  clipsState.loadWatchdog = setTimeout(() => {
    clipsState.loadWatchdog = null;
    const v = document.getElementById('clips-player-video');
    if (!v || clipsState.currentId !== id) return; // closed or switched clip
    if (clipsIsPlaying(v)) return;                  // started fine
    clipsRetryLoad();
  }, CLIP_LOAD_TIMEOUT_MS);
}

function clipsRetryLoad() {
  clipsClearWatchdog();
  const id = clipsState.currentId;
  const v = document.getElementById('clips-player-video');
  if (!id || !v) return;
  if (clipsState.loadAttempt >= CLIP_MAX_RETRIES) {
    clipsToast('Clip is slow to load — try reopening it');
    return;
  }
  clipsState.loadAttempt++;
  clipsToast('Retrying clip…');
  const at = v.currentTime || 0;
  const attempt = clipsState.loadAttempt;
  try { v.pause(); } catch { /* ignore */ }
  // Re-mint a fresh scoped token (the retry may be because the previous one
  // expired), then cache-bust so the element treats it as a fresh source (and
  // drops the stalled request) without an empty-src reset (which fires a spurious
  // 'error'). No JWT fallback — if the token can't be minted, we leave the source.
  clipsClipUrl(id, clipsState.quality).then((src) => {
    if (!src || clipsState.currentId !== id) return;
    v.src = src + '&_r=' + attempt;
    v.load();
    if (at > 0) {
      v.addEventListener('loadeddata', () => { try { v.currentTime = at; } catch { /* ignore */ } }, { once: true });
    }
    v.play().catch(() => {});
    clipsArmWatchdog();
  });
}

function clipsPlay(id, label) {
  const overlay = document.getElementById('clips-player');
  const video = document.getElementById('clips-player-video');
  const title = document.getElementById('clips-player-title');
  if (!overlay || !video) return;
  clipsState.currentId = id;
  clipsState.quality = 'preview';
  clipsState.loadAttempt = 0;
  clipsMarkViewed(id);
  const box = overlay.querySelector('.clips-player-box');
  if (box) box.style.overflow = 'hidden';
  clipsWireZoom();
  clipsResetZoom(false);
  if (title) title.textContent = label || 'Clip';
  const qBtn = document.getElementById('clips-player-quality');
  if (qBtn) { qBtn.classList.remove('active'); qBtn.disabled = false; }
  overlay.classList.remove('hidden');
  // Resolve a scoped media token (pre-warm on open) BEFORE setting the source, so
  // the <video> element never sees the full login JWT in its src.
  clipsClipUrl(id, 'preview').then((src) => {
    if (!src || clipsState.currentId !== id) return; // failed, or clip switched while awaiting
    video.src = src;
    video.play().catch(() => {});
    clipsArmWatchdog();
  });
  clipsMaybeHighlight(clipsState.byId?.[id]);
}

// Transient confirmation toast that floats ABOVE the clip-player modal (the
// bottom status bar is hidden behind the overlay, so setStatus alone is invisible
// here). Reused for snapshot + zoom feedback.
function clipsToast(msg) {
  let t = document.getElementById('clips-toast');
  if (!t) {
    t = document.createElement('div');
    t.id = 'clips-toast';
    t.style.cssText = 'position:fixed;left:50%;bottom:48px;transform:translateX(-50%);'
      + 'background:rgba(20,22,28,.96);color:#fff;padding:10px 16px;border-radius:8px;'
      + 'font-size:13px;z-index:99999;pointer-events:none;opacity:0;transition:opacity .18s;'
      + 'box-shadow:0 6px 20px rgba(0,0,0,.45)';
    document.body.appendChild(t);
  }
  t.textContent = msg;
  t.style.opacity = '1';
  clearTimeout(t._timer);
  t._timer = setTimeout(() => { t.style.opacity = '0'; }, 1800);
}

// Snapshot the current frame of the clip player → download a PNG. The video is
// served with CORS (allow-origin *) + crossorigin="anonymous", so the canvas
// isn't tainted and toBlob works.
function clipsSnapshot() {
  const video = document.getElementById('clips-player-video');
  if (!video || !video.videoWidth) { clipsToast('Snapshot unavailable — video not ready'); return; }
  const canvas = document.createElement('canvas');
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
  const c = clipsState.byId?.[clipsState.currentId];
  const cam = (c?.camera_name || 'clip').replace(/[^A-Za-z0-9_-]+/g, '_');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  canvas.toBlob((blob) => {
    if (!blob) { clipsToast('Snapshot failed'); return; }
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = `crumb_${cam}_${stamp}.png`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 5000);
    setStatus('Snapshot saved');
    clipsToast('📸 Snapshot saved');
  }, 'image/png');
}

// Bookmark the current clip — opens the SAME "Add bookmark" dialog the Playback
// transport uses (description + optional protect-from-delete), seeded with the
// clip's camera, start time, and label.
function clipsBookmark() {
  const c = clipsState.byId?.[clipsState.currentId];
  if (!c) return;
  const label = c.kind === 'motion' ? 'Motion' : (c.label || 'Detection');
  pbAddBookmark(c.camera_id, Date.parse(c.start_ts), label);
}

// Swap the player between the small preview and the full-resolution clip,
// preserving the current playback position. Full quality re-encodes on demand,
// so the first switch may take a moment.
function clipsToggleQuality() {
  const video = document.getElementById('clips-player-video');
  const qBtn = document.getElementById('clips-player-quality');
  if (!video || !clipsState.currentId) return;
  const next = clipsState.quality === 'preview' ? 'full' : 'preview';
  const id = clipsState.currentId;
  const at = video.currentTime || 0;
  const wasPlaying = !video.paused;
  clipsState.quality = next;
  if (qBtn) {
    qBtn.classList.toggle('active', next === 'full');
    qBtn.disabled = true;
  }
  clipsClipUrl(id, next).then((src) => {
    if (!src || clipsState.currentId !== id) { if (qBtn) qBtn.disabled = false; return; }
    video.src = src;
    video.addEventListener('loadeddata', () => {
      try { video.currentTime = at; } catch { /* ignore */ }
      if (wasPlaying) video.play().catch(() => {});
      if (qBtn) qBtn.disabled = false;
    }, { once: true });
  });
}

function clipsClosePlayer() {
  const overlay = document.getElementById('clips-player');
  const video = document.getElementById('clips-player-video');
  clipsClearWatchdog();
  clipsState.loadAttempt = 0;
  clipsResetZoom(false);
  if (video) { video.pause(); video.removeAttribute('src'); video.load(); }
  clipsState.currentId = null;
  overlay?.classList.add('hidden');
}

// ── Export state ──────────────────────────────────────────────────────────────

const exportState = {
  /** setTimeout handle for the poll interval (null = not polling) */
  pollTimer:  null,
  /** Whether an export job is currently in progress */
  running:    false,
  /** True once an export finished — the submit button now reads "Done" and
   *  clicking it must CLOSE the dialog, not run another export. */
  completed:  false,
  /** commercial-VMS-style export list: [{ id, cameraId, startMs, endMs }]. Persists
   *  across tab opens within a session; the batch exports the whole list. */
  list:       [],
  /** Monotonic id source for list items. */
  seq:        0,
  /** Add-clip builder + preview-scrubber state. */
  builder: {
    open:      false,
    editId:    null,   // item id being edited, or null for a new clip
    posMs:     0,      // current preview-scrubber position (epoch ms)
    frameTimer: null,  // debounce handle for the thumbnail fetch
    playTimer:  null,  // auto-advance interval handle
    playing:    false,
    reqToken:   0,     // latest frame request (drop stale responses)
    lastObj:    null,  // last object URL (revoked on replace)
  },
};

// ── Custom export destination (persisted; '' = browser Downloads folder) ──────
const LS_EXPORT_DIR = 'crumb_export_dir';
function getExportDir() { try { return localStorage.getItem(LS_EXPORT_DIR) || ''; } catch { return ''; } }
function setExportDir(d) { try { if (d) localStorage.setItem(LS_EXPORT_DIR, d); else localStorage.removeItem(LS_EXPORT_DIR); } catch { /* quota */ } }
/** Mirror the current export dir into BOTH the dialog input and the Client panel. */
function exportSyncDestLabels() {
  const dir = getExportDir();
  const d1 = document.getElementById('export-dest-path'); if (d1) d1.value = dir || 'Downloads folder';
  const d2 = document.getElementById('srv-export-path');  if (d2) d2.textContent = dir || 'Downloads folder';
  exportUpdateSummary();
}

/** Live "Batch" summary in the Output panel — clip count, distinct cameras, total
 *  duration, rough size estimate, destination — and enables/labels the Export
 *  button. Recomputed whenever the list or output settings change. Safe no-op
 *  before the view exists. */
function exportUpdateSummary() {
  const sum = document.getElementById('export-summary');
  if (!sum) return;

  // Any output-setting change after a completed export clears the "Done" state so
  // the button reverts to a normal "Export N clips" (fixes the stuck-Done case).
  if (exportState.completed) {
    exportState.completed = false;
    document.getElementById('export-done')?.classList.add('hidden');
  }

  const list   = exportState.list;
  const nClips = list.length;
  const cams   = new Set(list.map(it => it.cameraId)).size;
  let totalMs  = 0;
  for (const it of list) totalMs += Math.max(0, it.endMs - it.startMs);
  const dest = ((document.getElementById('export-dest-path') || {}).value || 'Downloads folder').trim();

  // Selected output codec drives both the size estimate and the slower-encode hint.
  const fmtSel = document.getElementById('export-format');
  const codec  = fmtSel?.options[fmtSel.selectedIndex]?.dataset.codec || 'h264';
  document.getElementById('export-codec-hint')?.classList.toggle('hidden', codec !== 'h265');

  const setTxt = (id, t) => { const el = document.getElementById(id); if (el) el.textContent = t; };
  setTxt('export-sum-clips', String(nClips));
  setTxt('export-sum-cams',  String(cams));
  setTxt('export-sum-dur',   nClips ? exportFmtDuration(totalMs) : '—');
  setTxt('export-sum-size',  nClips ? '~' + exportEstSize(totalMs, codec) : '—');
  setTxt('export-list-count', nClips ? `(${nClips})` : '');

  // Enable Export only when the list is non-empty and nothing is running.
  const btn = document.getElementById('export-submit-btn');
  if (btn && !exportState.running && !exportState.completed) {
    btn.disabled = nClips === 0;
    btn.textContent = nClips ? `Export ${nClips} clip${nClips === 1 ? '' : 's'}` : 'Export';
  }

  const destEl = document.getElementById('export-sum-dest');
  destEl.textContent = dest; destEl.title = dest;
}
/** Native folder picker → persist + reflect everywhere. */
async function exportPickFolder() {
  try {
    const dir = await invoke('pick_export_folder');
    if (dir) { setExportDir(dir); exportSyncDestLabels(); }
  } catch (e) { console.warn('pick_export_folder failed:', e); }
}
function exportResetFolder() { setExportDir(''); exportSyncDestLabels(); }

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Format an epoch-ms value as a local datetime-local input string:
 * "YYYY-MM-DDTHH:MM:SS" (the format required by <input type="datetime-local" step="1">)
 */
function exportFmtDatetimeLocal(ms) {
  const d = new Date(ms);
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
         `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

/**
 * Parse a datetime-local string back to epoch ms.
 * Returns NaN on invalid input.
 */
function exportParseDatetimeLocal(s) {
  // "YYYY-MM-DDTHH:MM:SS" → Date constructor treats this as local time
  return new Date(s).getTime();
}

/** Safe camera name lookup, falling back to the raw id. */
function exportCameraName(cameraId) {
  return camById(cameraId)?.name ?? cameraId;
}

/** Compact duration like "1h 4m" / "7m 19s" / "0s" from milliseconds. */
function exportFmtDuration(ms) {
  let s = Math.round(Math.max(0, ms) / 1000);
  const h = Math.floor(s / 3600); s -= h * 3600;
  const m = Math.floor(s / 60); s -= m * 60;
  return [h ? h + 'h' : '', m ? m + 'm' : '', (!h && (s || !m)) ? s + 's' : ''].filter(Boolean).join(' ') || '0s';
}

/** Rough export-size estimate (heuristic ~4 Mbps main stream), scaled by codec.
 *  H.265 re-encodes to roughly half the bitrate; copy/H.264 keep the source rate.
 *  Always labelled "~". */
function exportEstSize(ms, codec) {
  const factor = codec === 'h265' ? 0.5 : 1.0; // copy & h264 ≈ source bitrate
  const bytes = (Math.max(0, ms) / 1000) * 500_000 * factor; // 4 Mbps ≈ 500 KB/s
  if (bytes >= 1e9) return (bytes / 1e9).toFixed(1) + ' GB';
  if (bytes >= 1e6) return Math.round(bytes / 1e6) + ' MB';
  return Math.max(1, Math.round(bytes / 1e3)) + ' KB';
}

/** Wall-clock "MM/DD HH:MM:SS" for the preview readout. */
function exportFmtClock(ms) {
  const d = new Date(ms);
  const pad = n => String(n).padStart(2, '0');
  return `${pad(d.getMonth() + 1)}/${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

/** "+M:SS" offset from a clip's start, for the preview readout. */
function exportFmtOffset(ms) {
  let s = Math.round(Math.max(0, ms) / 1000);
  const m = Math.floor(s / 60); s -= m * 60;
  return `+${m}:${String(s).padStart(2, '0')}`;
}

/**
 * Build the absolute, authed download URL for an output_file entry.
 * The spec says download_url is relative (e.g. "/export/<job>/files/<cam>").
 */
function exportAbsoluteUrl(relUrl) {
  const sep = relUrl.includes('?') ? '&' : '?';
  return state.server + relUrl + sep + 'token=' + encodeURIComponent(state.token);
}

/**
 * Build a friendly local filename for a downloaded output. The extension comes
 * from the server's produced file (mp4/mkv), so codec/container choices are
 * reflected on disk. The encrypted-archive entry (nil camera_id / .zip) becomes
 * crumb-export-<stamp>.zip.
 */
function exportFilename(file, startMs) {
  const d = new Date(startMs);
  const pad = n => String(n).padStart(2, '0');
  const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-` +
                `${pad(d.getHours())}${pad(d.getMinutes())}`;
  const NIL = '00000000-0000-0000-0000-000000000000';
  const extMatch = /\.([a-z0-9]+)$/i.exec(file.filename || '');
  const ext = extMatch ? extMatch[1].toLowerCase() : 'mp4';
  if (file.camera_id === NIL || ext === 'zip') return `crumb-export-${stamp}.zip`;
  const name = exportCameraName(file.camera_id)
    .replace(/[^a-zA-Z0-9_-]/g, '_')  // sanitize for filesystem
    .slice(0, 40);
  return `crumb-${name}-${stamp}.${ext}`;
}

// ── Button injection ──────────────────────────────────────────────────────────

/**
 * Inject the "⬇ Export" button into the playback transport bar.
 * Must be called after pbInjectZoomButtons() so the zoom group already exists.
 */
function exportInjectButton() {
  const transportRight = document.querySelector('.pb-transport-right');
  if (!transportRight) return;

  const btn = document.createElement('button');
  btn.id        = 'pb-export-btn';
  btn.className = 'pb-btn pb-btn-xs pb-btn-export';
  btn.title     = 'Export footage to disk';
  btn.innerHTML = `
    <svg width="11" height="11" viewBox="0 0 11 11" fill="none" style="flex-shrink:0">
      <path d="M5.5 1v6M2.5 5l3 3 3-3" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M1 9h9" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
    </svg>
    Export
  `;
  btn.addEventListener('click', exportOpenDialog);

  // Append after the Live button (last child of right cluster)
  const liveBtn = document.getElementById('pb-live-btn');
  if (liveBtn && liveBtn.nextSibling) {
    transportRight.insertBefore(btn, liveBtn.nextSibling);
  } else {
    transportRight.appendChild(btn);
  }
}

// ── Export view enter / leave ─────────────────────────────────────────────────

/** Switch to the Export VIEW (used by the Playback right-click "Export selection…"
 *  context action; the Export tab routes through activateTab directly). */
function exportOpenDialog() { void activateTab('export'); }

/** Populate the Export view's form (time range + camera list) + reset its
 *  progress/error state. Called by activateTab('export') when the view is shown. */
function exportEnter() {
  // Reset transient run state; the persistent clip list survives tab opens.
  exportStopPoll();
  exportState.running = false;
  exportState.completed = false;
  exportResetProgress();
  document.getElementById('export-progress-wrap').classList.add('hidden');
  const done = document.getElementById('export-done'); if (done) done.classList.add('hidden');
  const err = document.getElementById('export-error'); if (err) { err.classList.add('hidden'); err.textContent = ''; }

  exportCloseBuilder();    // start in list mode
  exportRenderList();
  exportSyncDestLabels();  // → exportUpdateSummary (counts + Export button state)

  // Right-click "Export selection…" jumps here carrying a camera + bracketed range
  // — open the builder pre-filled so it's one click to add it as the first clip.
  const sel = pbState.exportSel;
  if (sel) {
    const cam = (pbState.selectedSlot != null && pbState.selectedSlot >= 0)
      ? (state.slotMap.get(pbState.selectedSlot) ?? null) : null;
    exportOpenBuilder(null, cam, Math.min(sel.startMs, sel.endMs), Math.max(sel.startMs, sel.endMs));
    pbState.exportSel = null; // consume it
  }
}

// ── Export list (build clips → batch-export together) ───────────────────────────

/** Fill the builder's camera <select> with the wall cameras (else all cameras). */
function exportPopulateCameraSelect(selectedId) {
  const sel = document.getElementById('export-b-camera');
  if (!sel) return;
  let ids = pbGetWallCameraIds();
  if (!ids || ids.length === 0) ids = state.cameras.map(c => c.id);
  sel.innerHTML = ids.map(id => `<option value="${escHtml(id)}">${escHtml(exportCameraName(id))}</option>`).join('');
  if (selectedId && ids.includes(selectedId)) sel.value = selectedId;
}

/** Open the add-clip builder (list mode → builder mode), optionally pre-filled. */
function exportOpenBuilder(editId, cameraId, startMs, endMs) {
  const b = exportState.builder;
  b.open = true;
  b.editId = editId ?? null;
  document.getElementById('export-list-mode').classList.add('hidden');
  document.getElementById('export-list-items').classList.add('hidden');
  document.getElementById('export-builder').classList.remove('hidden');
  document.getElementById('export-b-title').textContent = editId ? 'Edit clip' : 'Add clip';
  document.getElementById('export-b-add').textContent = editId ? 'Save changes' : '+ Add to list';
  const berr = document.getElementById('export-b-error'); if (berr) { berr.classList.add('hidden'); berr.textContent = ''; }

  exportPopulateCameraSelect(cameraId);
  let s = startMs, e = endMs;
  if (!Number.isFinite(s) || !Number.isFinite(e) || e <= s) { e = Date.now(); s = e - 60_000; }
  document.getElementById('export-b-start').value = exportFmtDatetimeLocal(s);
  document.getElementById('export-b-end').value   = exportFmtDatetimeLocal(e);

  exportPreviewReset();
  exportPreviewSeek(0);     // load the first frame of the range
}

/** Close the builder (builder mode → list mode), tearing down the preview. */
function exportCloseBuilder() {
  const b = exportState.builder;
  b.open = false; b.editId = null;
  exportPreviewStop();
  exportPreviewTeardown();
  const builder = document.getElementById('export-builder'); if (builder) builder.classList.add('hidden');
  const lm = document.getElementById('export-list-mode'); if (lm) lm.classList.remove('hidden');
  const li = document.getElementById('export-list-items'); if (li) li.classList.remove('hidden');
}

/** Validate + commit the builder's clip into the list (add new or save an edit). */
function exportBuilderCommit() {
  const cam = (document.getElementById('export-b-camera') || {}).value;
  const s = exportParseDatetimeLocal((document.getElementById('export-b-start') || {}).value || '');
  const e = exportParseDatetimeLocal((document.getElementById('export-b-end') || {}).value || '');
  const berr = document.getElementById('export-b-error');
  const fail = (m) => { if (berr) { berr.textContent = m; berr.classList.remove('hidden'); } };
  if (berr) berr.classList.add('hidden');
  if (!cam) return fail('Pick a camera for this clip.');
  if (!Number.isFinite(s) || !Number.isFinite(e)) return fail('Enter a valid start and end time.');
  if (e <= s) return fail('End must be after start.');

  const b = exportState.builder;
  if (b.editId) {
    const it = exportState.list.find(x => x.id === b.editId);
    if (it) { it.cameraId = cam; it.startMs = s; it.endMs = e; }
  } else {
    exportState.list.push({ id: ++exportState.seq, cameraId: cam, startMs: s, endMs: e });
  }
  exportCloseBuilder();
  exportRenderList();
  exportUpdateSummary();
}

/** Remove a clip from the list by id. */
function exportRemoveItem(id) {
  exportState.list = exportState.list.filter(x => x.id !== id);
  exportRenderList();
  exportUpdateSummary();
}

/** Render the export list — one card per clip (thumbnail, camera, range, duration). */
function exportRenderList() {
  const wrap = document.getElementById('export-list-items');
  if (!wrap) return;
  const list = exportState.list;
  if (list.length === 0) {
    wrap.innerHTML = '<div class="export-list-empty">No clips yet.<br>Add a camera + time range to build your export.</div>';
    return;
  }
  wrap.innerHTML = '';
  list.forEach((it, i) => {
    const row = document.createElement('div');
    row.className = 'export-list-item';
    // The thumbnail <img> src is filled after render (exportFillThumbnails) so it can
    // carry a short-lived per-camera scoped token instead of the full login JWT.
    row.innerHTML =
      `<span class="export-li-idx">${i + 1}</span>` +
      `<img class="export-li-thumb" alt="" />` +
      `<div class="export-li-main">` +
        `<div class="export-li-name">${escHtml(exportCameraName(it.cameraId))}</div>` +
        `<div class="export-li-range">${escHtml(exportFmtClock(it.startMs))} → ${escHtml(exportFmtClock(it.endMs))}</div>` +
      `</div>` +
      `<span class="export-li-dur">${escHtml(exportFmtDuration(it.endMs - it.startMs))}</span>` +
      `<button class="export-li-btn export-li-edit" title="Edit clip" data-id="${it.id}">&#9998;</button>` +
      `<button class="export-li-btn export-li-x" title="Remove clip" data-id="${it.id}">&times;</button>`;
    const img = row.querySelector('.export-li-thumb');
    // Strict CSP blocks inline handlers, so hide a broken thumbnail via a listener.
    img.addEventListener('error', () => { img.style.visibility = 'hidden'; });
    exportListThumbUrl(it).then((src) => { if (src && img.isConnected) img.src = src; });
    wrap.appendChild(row);
  });
  wrap.querySelectorAll('.export-li-edit').forEach(btn => btn.addEventListener('click', () => {
    const it = exportState.list.find(x => x.id === Number(btn.dataset.id));
    if (it) exportOpenBuilder(it.id, it.cameraId, it.startMs, it.endMs);
  }));
  wrap.querySelectorAll('.export-li-x').forEach(btn => btn.addEventListener('click', () => {
    exportRemoveItem(Number(btn.dataset.id));
  }));
}

/** Clip-start thumbnail URL (server extracts the past frame on demand), carrying a
 *  short-lived per-camera scoped media token instead of the full login JWT. Async;
 *  resolves to null if no token could be minted (the <img> is simply left blank). */
async function exportListThumbUrl(it) {
  const tsIso = new Date(it.startMs).toISOString();
  return mediaUrlForCamera(it.cameraId,
    `/filmstrip/${encodeURIComponent(it.cameraId)}/frame?ts=${encodeURIComponent(tsIso)}&width=160`);
}

// ── Add-clip preview scrubber (frame-accurate review before adding) ──────────────
// v1 renders the frame at the scrubber position (drag to review). Each scrub fetches
// ONE thumbnail (server extracts + caches it); Play auto-advances at a capped frame
// rate so a long clip can't hammer the extractor.

function exportBuilderRange() {
  const s = exportParseDatetimeLocal((document.getElementById('export-b-start') || {}).value || '');
  const e = exportParseDatetimeLocal((document.getElementById('export-b-end') || {}).value || '');
  return { s, e, ok: Number.isFinite(s) && Number.isFinite(e) && e > s };
}

function exportPreviewReset() {
  const b = exportState.builder;
  b.posMs = 0; b.reqToken++;
  const st = document.getElementById('export-preview-state');
  if (st) { st.style.display = ''; st.textContent = 'Loading preview…'; }
  const img = document.getElementById('export-preview-img'); if (img) img.remove();
  const fill = document.getElementById('export-pv-fill'); if (fill) fill.style.width = '0%';
  const head = document.getElementById('export-pv-head'); if (head) head.style.left = '0%';
  const tm = document.getElementById('export-pv-time'); if (tm) tm.textContent = '—';
}

function exportPreviewTeardown() {
  const b = exportState.builder;
  clearTimeout(b.frameTimer); b.frameTimer = null;
  if (b.lastObj) { URL.revokeObjectURL(b.lastObj); b.lastObj = null; }
}

function exportPreviewSeek(frac) {
  const { s, e, ok } = exportBuilderRange();
  const cam = (document.getElementById('export-b-camera') || {}).value;
  if (!ok || !cam) return;
  frac = Math.max(0, Math.min(1, frac));
  const posMs = Math.round(s + frac * (e - s));
  exportState.builder.posMs = posMs;
  const pct = (frac * 100).toFixed(1) + '%';
  const fill = document.getElementById('export-pv-fill'); if (fill) fill.style.width = pct;
  const head = document.getElementById('export-pv-head'); if (head) head.style.left = pct;
  const tm = document.getElementById('export-pv-time');
  if (tm) tm.textContent = exportFmtOffset(posMs - s) + ' / ' + exportFmtDuration(e - s);
  clearTimeout(exportState.builder.frameTimer);
  exportState.builder.frameTimer = setTimeout(() => exportPreviewFetch(cam, posMs), 110);
}

async function exportPreviewFetch(cam, posMs) {
  const token = ++exportState.builder.reqToken;
  const tsIso = new Date(posMs).toISOString();
  const url = `${state.server}/filmstrip/${encodeURIComponent(cam)}/frame?ts=${encodeURIComponent(tsIso)}&width=480`;
  try {
    const res = await fetchWithTimeout(url, { headers: authHeaders() });
    if (token !== exportState.builder.reqToken) return; // a newer scrub superseded us
    if (!res.ok) { exportPreviewState('No footage at this moment'); return; }
    const blob = await res.blob();
    if (token !== exportState.builder.reqToken) return;
    const obj = URL.createObjectURL(blob);
    let img = document.getElementById('export-preview-img');
    if (!img) {
      img = document.createElement('img');
      img.id = 'export-preview-img';
      img.style.cssText = 'width:100%;height:100%;object-fit:contain;background:#000;';
      document.getElementById('export-preview-box').appendChild(img);
    }
    img.style.visibility = '';
    img.src = obj;
    const st = document.getElementById('export-preview-state'); if (st) st.style.display = 'none';
    if (exportState.builder.lastObj) URL.revokeObjectURL(exportState.builder.lastObj);
    exportState.builder.lastObj = obj;
  } catch { /* transient */ }
}

function exportPreviewState(msg) {
  const st = document.getElementById('export-preview-state');
  if (st) { st.style.display = ''; st.textContent = msg; }
  const img = document.getElementById('export-preview-img'); if (img) img.style.visibility = 'hidden';
}

function exportPreviewPlayToggle() {
  const b = exportState.builder;
  if (b.playing) { exportPreviewStop(); return; }
  const { s, e, ok } = exportBuilderRange();
  if (!ok || !(document.getElementById('export-b-camera') || {}).value) return;
  b.playing = true;
  exportPreviewUpdatePlayIcon();
  const span = e - s;
  const stepMs = Math.max(1000, Math.round(span / 24)); // ≤~24 frames/play — caps extractor load
  b.playTimer = setInterval(() => {
    const cur = (b.posMs && b.posMs >= s && b.posMs < e) ? b.posMs : s;
    const next = cur + stepMs;
    if (next >= e) { exportPreviewSeek(1); exportPreviewStop(); return; }
    exportPreviewSeek((next - s) / span);
  }, 700);
}

function exportPreviewStop() {
  const b = exportState.builder;
  b.playing = false;
  if (b.playTimer) { clearInterval(b.playTimer); b.playTimer = null; }
  exportPreviewUpdatePlayIcon();
}

/** Swap the play ⇄ pause SVG on the builder transport (mirrors pbUpdatePlayPauseBtn). */
function exportPreviewUpdatePlayIcon() {
  const playing = exportState.builder.playing;
  document.getElementById('export-pv-play-icon')?.classList.toggle('hidden', playing);
  document.getElementById('export-pv-pause-icon')?.classList.toggle('hidden', !playing);
}

/** Leave the Export view: stop polling, tear down the preview, return to Live.
 *  Also resets transient run state so re-entering Export is always fresh (no
 *  stuck "Done" button, no stale progress/done panels). */
function exportCloseDialog() {
  exportStopPoll();
  exportCloseBuilder(); // stops the preview auto-advance + revokes the last frame
  exportState.completed = false;
  exportState.running = false;
  document.getElementById('export-done')?.classList.add('hidden');
  document.getElementById('export-progress-wrap')?.classList.add('hidden');
  exportUpdateSummary(); // restore the normal "Export N clips" button label + state
  if (els.appShell && !els.appShell.classList.contains('hidden')) void activateTab('live');
}

function exportResetProgress() {
  document.getElementById('export-progress-wrap').classList.add('hidden');
  document.getElementById('export-progress-bar').style.width = '0%';
  document.getElementById('export-progress-text').textContent = 'Exporting…';
  document.getElementById('export-progress-pct').textContent = '0%';
}

// ── Poll management ───────────────────────────────────────────────────────────

function exportStopPoll() {
  if (exportState.pollTimer !== null) {
    clearTimeout(exportState.pollTimer);
    exportState.pollTimer = null;
  }
  exportState.running = false;
}

// ── Core export flow ──────────────────────────────────────────────────────────

async function exportHandleSubmit() {
  // After a completed export the button reads "Done" → close the dialog instead
  // of firing a second export.
  if (exportState.completed) { exportCloseDialog(); return; }

  const errEl = document.getElementById('export-error');
  errEl.classList.add('hidden'); errEl.textContent = '';

  // Validate the list (re-check ranges in case an item was edited oddly).
  const list = exportState.list.filter(it =>
    it.cameraId && Number.isFinite(it.startMs) && Number.isFinite(it.endMs) && it.endMs > it.startMs);
  if (list.length === 0) {
    errEl.textContent = 'Add at least one clip to the list before exporting.';
    errEl.classList.remove('hidden');
    return;
  }

  // Global output settings (apply to the whole batch).
  const burnTimestamp = document.getElementById('export-burn-ts').checked;
  const includeAudio  = document.getElementById('export-include-audio').checked;
  const fmtSel        = document.getElementById('export-format');
  const fmtOpt        = fmtSel.options[fmtSel.selectedIndex];
  const videoCodec    = fmtOpt?.dataset.codec || 'h264';
  const container     = fmtOpt?.dataset.container || 'mp4';
  const password      = document.getElementById('export-password').value; // '' → unencrypted

  // Lock UI + show progress.
  const submitBtn = document.getElementById('export-submit-btn');
  submitBtn.disabled = true;
  submitBtn.textContent = 'Submitting…';
  exportState.running = true;
  exportResetProgress();
  document.getElementById('export-progress-wrap').classList.remove('hidden');

  const earliestStart = Math.min(...list.map(it => it.startMs));

  // POST /export/batch — one combined archive for the whole list.
  let jobId;
  try {
    const res = await fetchWithTimeout(`${state.server}/export/batch`, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({
        items: list.map(it => ({
          camera_id: it.cameraId,
          start:     new Date(it.startMs).toISOString(),
          end:       new Date(it.endMs).toISOString(),
        })),
        burn_timestamp: burnTimestamp,
        include_audio:  includeAudio,
        video_codec:    videoCodec,   // copy | h264 | h265
        container:      container,     // mp4 | mkv
        password:       password ? password : null, // AES-256 zip when set
      }),
    });
    if (res.status === 401) { handleUnauthorized(); exportCloseDialog(); return; }
    if (!res.ok) {
      const text = await res.text().catch(() => res.statusText);
      throw new Error(`Export request failed (${res.status}): ${text}`);
    }
    const data = await res.json(); // { job_id, status_url }
    jobId = data.job_id;
  } catch (e) {
    exportState.running = false;
    submitBtn.disabled = false;
    exportUpdateSummary(); // restore "Export N clips" label + enabled state
    errEl.textContent = String(e.message ?? e);
    errEl.classList.remove('hidden');
    return;
  }

  submitBtn.textContent = 'Exporting…';
  exportPoll(jobId, earliestStart);
}

function exportPoll(jobId, startMs) {
  if (!exportState.running) return; // cancelled while waiting

  exportState.pollTimer = setTimeout(async () => {
    exportState.pollTimer = null;
    if (!exportState.running) return;

    let job;
    try {
      const res = await fetchWithTimeout(`${state.server}/export/${encodeURIComponent(jobId)}`, {
        headers: authHeaders(),
      });
      if (res.status === 401) { handleUnauthorized(); exportCloseDialog(); return; }
      if (!res.ok) throw new Error(`Poll failed (${res.status})`);
      job = await res.json();
    } catch (e) {
      if (!exportState.running) return; // dialog closed mid-flight
      exportShowError(String(e.message ?? e));
      return;
    }

    if (!exportState.running) return;

    // Update progress bar
    const pct = typeof job.progress_pct === 'number' ? job.progress_pct : 0;
    exportSetProgress(pct, job.status);

    if (job.status === 'done') {
      exportState.running = false;
      exportSetProgress(100, 'done');
      await exportDownloadFiles(job.output_files ?? [], startMs);
      return;
    }

    if (job.status === 'failed') {
      exportShowError(job.error ?? 'Export job failed (no details provided).');
      return;
    }

    // Still queued or running — schedule next poll
    exportPoll(jobId, startMs);
  }, 1500);
}

function exportSetProgress(pct, status) {
  const pctClamped = Math.max(0, Math.min(100, pct));
  document.getElementById('export-progress-bar').style.width = `${pctClamped}%`;
  document.getElementById('export-progress-pct').textContent = `${Math.round(pctClamped)}%`;

  const label = document.getElementById('export-progress-text');
  if (status === 'queued')  label.textContent = 'Queued…';
  else if (status === 'running') label.textContent = `Exporting…`;
  else if (status === 'done')    label.textContent = 'Complete';
}

function exportShowError(msg) {
  exportState.running = false;
  const errEl  = document.getElementById('export-error');
  errEl.textContent = msg;
  errEl.classList.remove('hidden');
  const submitBtn = document.getElementById('export-submit-btn');
  submitBtn.disabled    = false;
  submitBtn.textContent = 'Retry';
}

// ── File download ─────────────────────────────────────────────────────────────

/**
 * Trigger a browser download for each completed output file.
 *
 * Strategy: fetch the file with the auth token → Blob → object URL → hidden
 * <a download> → programmatic click() → revoke URL.
 *
 * Tauri 2 webview note: Tauri's WebView2 (Windows) and WebKit (macOS/Linux)
 * both allow Blob URL creation and support the download attribute on <a> tags
 * as long as the file is fetched through the webview's network stack (not
 * directly from a native path). Because we're fetching via state.server
 * (http://...) and creating a blob: URL in the JS context, this works in Tauri
 * 2 without any additional permissions configuration.
 *
 * If blob download somehow fails (fetch error, very large file, security
 * restriction), we fall back to window.open() which opens the authed URL in a
 * new window/tab — the JWT query param handles auth in that case.
 */
async function exportDownloadFiles(outputFiles, startMs) {
  const destDir = getExportDir(); // '' → browser Downloads
  if (outputFiles.length === 0) {
    setStatus('Export complete — no output files returned.');
    exportState.completed = true;
    document.getElementById('export-submit-btn').textContent = 'Done';
    return;
  }

  let downloaded = 0;
  let lastErr = null;
  for (const file of outputFiles) {
    const absUrl   = exportAbsoluteUrl(file.download_url);
    const filename = exportFilename(file, startMs);

    if (destDir) {
      // Stream straight to the chosen folder via the Rust saver (no browser download).
      try {
        await invoke('save_export_file', { url: absUrl, destDir, filename });
        downloaded++;
      } catch (e) {
        lastErr = e;
        console.warn('save_export_file failed:', e);
      }
    } else {
      // Default: blob download into the browser Downloads folder. Authenticate via
      // the Authorization header (not just the URL's ?token=) so this download
      // doesn't depend on the token-in-URL escape hatch.
      try {
        const res = await fetchWithTimeout(absUrl, { headers: authHeaders() });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const blob      = await res.blob();
        const objectUrl = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = objectUrl;
        a.download = filename;
        a.style.display = 'none';
        document.body.appendChild(a);
        a.click();
        setTimeout(() => { URL.revokeObjectURL(objectUrl); document.body.removeChild(a); }, 2000);
        downloaded++;
      } catch (blobErr) {
        // No window.open() fallback here: that would hand a `?token=` download
        // URL out of the app (a new browser window/tab, outside our control) —
        // an auth escape hatch we don't want. Surface the failure instead.
        console.warn('blob download failed:', blobErr);
        lastErr = blobErr;
      }
    }
  }

  if (downloaded === 0 && lastErr) {
    exportShowError(`Could not save the export: ${lastErr.message ?? lastErr}`);
    return;
  }

  const where = destDir || 'your Downloads folder';
  setStatus(`Exported ${downloaded} file${downloaded !== 1 ? 's' : ''} → ${where}`);
  exportState.completed = true;
  const submitBtn = document.getElementById('export-submit-btn');
  submitBtn.disabled    = false;
  submitBtn.textContent = 'Done';
  document.getElementById('export-progress-wrap').classList.add('hidden');
  document.getElementById('export-done-text').textContent =
    `Saved ${downloaded} file${downloaded !== 1 ? 's' : ''} to ${where}.`;
  document.getElementById('export-done').classList.remove('hidden');

  // Auto-exit back to Live shortly after success — the "Saved N files" status/toast
  // persists; re-entering Export starts fresh (exportEnter + exportCloseDialog reset).
  setTimeout(() => { if (exportState.completed) exportCloseDialog(); }, 1800);
}

// ── Wire up dialog events ─────────────────────────────────────────────────────
// Called once from DOMContentLoaded (after other wiring).

function exportWireEvents() {
  // Export is a view now (no modal × / backdrop); "Back to Live" is the cancel.
  document.getElementById('export-close-btn')?.addEventListener('click',  exportCloseDialog);
  document.getElementById('export-cancel-btn')?.addEventListener('click', exportCloseDialog);
  document.getElementById('export-backdrop')?.addEventListener('click',   exportCloseDialog);
  document.getElementById('export-submit-btn')?.addEventListener('click', exportHandleSubmit);

  // ── Export list ⇄ builder ──────────────────────────────────────────────────
  document.getElementById('export-add-btn')?.addEventListener('click', () => exportOpenBuilder(null, null, NaN, NaN));
  document.getElementById('export-b-back')?.addEventListener('click',   exportCloseBuilder);
  document.getElementById('export-b-cancel')?.addEventListener('click', exportCloseBuilder);
  document.getElementById('export-b-add')?.addEventListener('click',    exportBuilderCommit);

  // Builder camera change → reload the preview at the current scrub position.
  document.getElementById('export-b-camera')?.addEventListener('change', () => { exportPreviewReset(); exportPreviewSeek(0); });
  // Builder range change → re-seek the preview (keep the scrubber fraction).
  ['export-b-start', 'export-b-end'].forEach(id => {
    document.getElementById(id)?.addEventListener('change', () => {
      const { s, e, ok } = exportBuilderRange();
      const frac = ok && exportState.builder.posMs ? (exportState.builder.posMs - s) / (e - s) : 0;
      exportPreviewSeek(Math.max(0, Math.min(1, frac)) || 0);
    });
  });

  // Quick-range chips: set the BUILDER range to the last N minutes ending now.
  document.getElementById('export-quick')?.addEventListener('click', (e) => {
    const pb = e.target.closest('#export-quick-pb');
    if (pb) {
      // "Use playback selection" — pull the active export-range bracket / window.
      const sel = pbState.exportSel;
      let s, en;
      if (sel) { s = Math.min(sel.startMs, sel.endMs); en = Math.max(sel.startMs, sel.endMs); }
      else if (Number.isFinite(pbState.windowStartMs) && pbState.windowEndMs > pbState.windowStartMs) {
        s = pbState.windowStartMs; en = pbState.windowEndMs;
      } else { en = Date.now(); s = en - 60_000; }
      document.getElementById('export-b-start').value = exportFmtDatetimeLocal(s);
      document.getElementById('export-b-end').value   = exportFmtDatetimeLocal(en);
      exportPreviewReset(); exportPreviewSeek(0);
      return;
    }
    const chip = e.target.closest('.export-quick-chip');
    if (!chip || !chip.dataset.mins) return;
    const mins = parseInt(chip.dataset.mins, 10);
    if (!Number.isFinite(mins)) return;
    const end = Date.now(), start = end - mins * 60000;
    document.getElementById('export-b-start').value = exportFmtDatetimeLocal(start);
    document.getElementById('export-b-end').value   = exportFmtDatetimeLocal(end);
    exportPreviewReset(); exportPreviewSeek(0);
  });

  // Preview transport: play/pause + scrub (click or drag the track).
  document.getElementById('export-pv-play')?.addEventListener('click', exportPreviewPlayToggle);
  const track = document.getElementById('export-pv-track');
  if (track) {
    const fracAt = (clientX) => {
      const r = track.getBoundingClientRect();
      return r.width > 0 ? (clientX - r.left) / r.width : 0;
    };
    let dragging = false;
    track.addEventListener('pointerdown', (e) => {
      dragging = true; exportPreviewStop();
      try { track.setPointerCapture(e.pointerId); } catch { /* ok */ }
      exportPreviewSeek(fracAt(e.clientX));
    });
    track.addEventListener('pointermove', (e) => { if (dragging) exportPreviewSeek(fracAt(e.clientX)); });
    const end = () => { dragging = false; };
    track.addEventListener('pointerup', end);
    track.addEventListener('pointercancel', end);
  }

  // Keep the batch summary (+ Export button state) in sync with output settings.
  // Any change after a completed export also clears the stuck "Done" button
  // (handled at the top of exportUpdateSummary).
  document.getElementById('export-format')?.addEventListener('change', exportUpdateSummary);
  document.getElementById('export-password')?.addEventListener('input', exportUpdateSummary);
  document.getElementById('export-burn-ts')?.addEventListener('change', exportUpdateSummary);
  document.getElementById('export-include-audio')?.addEventListener('change', exportUpdateSummary);

  // Open the folder the export was saved to (the chosen dir, or Downloads).
  document.getElementById('export-open-folder-btn')?.addEventListener('click', () => {
    invoke('open_export_folder', { dir: getExportDir() || null }).catch(() => setStatus('Could not open the folder.'));
  });
  // Custom export destination — Browse from the dialog AND from Settings → Client → Export.
  document.getElementById('export-browse-btn')?.addEventListener('click', exportPickFolder);
  document.getElementById('srv-export-browse-btn')?.addEventListener('click', exportPickFolder);
  document.getElementById('srv-export-reset-btn')?.addEventListener('click', exportResetFolder);
  exportSyncDestLabels();

  // Escape leaves the Export view → back to Live.
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && els.viewExport && !els.viewExport.classList.contains('hidden')) {
      exportCloseDialog();
    }
  });
}

// =============================================================================
// SERVER MANAGEMENT MODULE
// =============================================================================
//
// Architecture:
//   - Health panel: GET /status every 5 s while Server tab is visible.
//     Interval is stored in srvState.refreshTimer and cleared on tab exit.
//   - Policy editor: left list (cameras + "Default Policy") drives a right-side
//     form. Save PUTs to per-camera or default endpoint. All fields are
//     optional in the request body (UpdatePolicyRequest).
//   - srvPolicyTarget: { type: 'default' } | { type: 'camera', id, name }
// =============================================================================

// ── Server module state ───────────────────────────────────────────────────────

const srvState = {
  /** Currently visible Settings section: client | cameras | stats | server */
  section: 'client',
  /** Last-fetched per-camera stats rows + the active column sort. */
  statsCams: [],
  statsSort: { key: 'name', dir: 1 },
  /** setInterval handle for health auto-refresh (null = not running) */
  refreshTimer: null,
  /** Currently selected policy target */
  policyTarget: null,
  /** Camera list fetched from /config/cameras (all cameras, not just enabled) */
  allCameras: [],
  /** setInterval handle for the selected-camera live preview (null = not running) */
  previewTimer: null,
  /** Management section: server|token the embedded /admin iframe currently holds,
   *  so re-entering doesn't reload it (and a server/token change does). */
  adminSrcKey: null,
};

/** Stop the policy-editor camera preview refresh loop. */
function srvStopPreview() {
  if (srvState.previewTimer) { clearInterval(srvState.previewTimer); srvState.previewTimer = null; }
}

// ── Enter / exit ──────────────────────────────────────────────────────────────

async function srvEnter() {
  srvRenderConnection();
  srvSelectSection(srvState.section || 'client');

  // Auto-refresh recorder health every 5 s, but only while the Server section is shown.
  // J2: clear any prior interval first so a re-entry can't stack duplicate timers.
  if (srvState.refreshTimer) { clearInterval(srvState.refreshTimer); srvState.refreshTimer = null; }
  srvState.refreshTimer = setInterval(() => {
    if (!els.viewServer.classList.contains('hidden') && srvState.section === 'server') {
      void srvLoadHealth();
    }
  }, 5000);
}

/** Switch the visible Settings section and lazy-load its data. */
function srvSelectSection(name) {
  // 3 sections: This Computer (client prefs), Performance (decode HUD), Server
  // (read-only health + per-camera storage + the motion tuner). Server config
  // proper — cameras, recording policies, groups — lives in the /admin console.
  const valid = ['client', 'server', 'diag', 'motion', 'admin'];
  if (!valid.includes(name)) name = 'client';
  srvState.section = name;
  document.querySelectorAll('#srv-nav .srv-nav-btn').forEach(b =>
    b.classList.toggle('active', b.dataset.section === name));
  document.querySelectorAll('#view-server .srv-section').forEach(s =>
    s.classList.toggle('hidden', s.dataset.section !== name));
  // Leaving Motion: halt the inline tuner's polling so it doesn't run unseen.
  if (name !== 'motion') mtStop();
  if (name === 'client')      { srvReflectClientOptions(); updEnterAbout(); }
  else if (name === 'server') { srvState.lastPolicyUsageMs = 0; void srvLoadHealth(); void srvLoadStats(); void pollRecordingAlerts(); }
  else if (name === 'motion') { void srvEnterMotion(); }
  else if (name === 'admin')  { srvEnterAdmin(); }
  else if (name === 'diag')   { hudStart(); hudRenderDiag(); }
}

/** Enter the Management section: embed the server's /admin console in an iframe,
 *  passing the desktop's current token via the URL hash so the operator doesn't
 *  re-authenticate (admin.html's bootSSO adopts it, then scrubs the hash). The
 *  iframe is built lazily (token isn't baked into static HTML) and only rebuilt
 *  when the server/token changes — re-entering the section keeps the live page. */
function srvEnterAdmin() {
  const host = document.getElementById('srv-admin-frame-host');
  const hostLabel = document.getElementById('srv-admin-host');
  const empty = document.getElementById('srv-admin-empty');
  if (!host) return;
  if (!state.server || !state.token) {
    // Not connected — tear down any stale iframe and show the hint.
    host.querySelector('iframe')?.remove();
    if (empty) empty.style.display = '';
    srvState.adminSrcKey = null;
    return;
  }
  const base = String(state.server).replace(/\/$/, '');
  if (hostLabel) hostLabel.textContent = base.replace(/^https?:\/\//, '');
  // Key = server+token; only (re)load the iframe when one of those changes so
  // navigating away/back doesn't reset the operator's place in the console.
  const key = `${base}|${state.token}`;
  let frame = host.querySelector('iframe');
  if (frame && srvState.adminSrcKey === key) return; // already current
  if (empty) empty.style.display = 'none';
  const url = `${base}/admin#token=${encodeURIComponent(state.token)}&embed=1`;
  if (!frame) {
    frame = document.createElement('iframe');
    frame.id = 'srv-admin-frame';
    frame.setAttribute('title', 'Server management console');
    host.appendChild(frame);
  }
  frame.src = url;
  srvState.adminSrcKey = key;
}

/** Enter the Motion-tuning section: load the camera list, then immediately show
 *  the inline tuner for the selected (or first) camera — no extra "Open" click. */
async function srvEnterMotion() {
  await srvLoadTunerCams();
  const sel = document.getElementById('srv-tuner-cam');
  if (sel && sel.options.length && !sel.value) sel.value = sel.options[0].value;
  if (sel && sel.value) void srvOpenTuner();
}

/** Populate the Server → Motion tuning camera picker (and refresh the cache mtOpen reads). */
async function srvLoadTunerCams() {
  const sel = document.getElementById('srv-tuner-cam');
  if (!sel) return;
  try {
    const res = await fetchWithTimeout(`${state.server}/config/cameras`, { headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (!res.ok) throw new Error(`GET /config/cameras → ${res.status}`);
    srvState.allCameras = await res.json();
  } catch { return; }
  const prev = sel.value;
  sel.innerHTML = (srvState.allCameras || [])
    .map(c => `<option value="${escHtml(String(c.id))}">${escHtml(c.name)}</option>`).join('');
  if (prev && srvState.allCameras.some(c => String(c.id) === prev)) sel.value = prev;
}

/** Open the live motion tuner for the camera selected in the Server section. */
async function srvOpenTuner() {
  const sel = document.getElementById('srv-tuner-cam');
  const id = sel?.value;
  if (!id) { setStatus('Select a camera first.'); return; }
  // Fetch FRESH so the tuner opens with the camera's current threshold/mask.
  try {
    const res = await fetchWithTimeout(`${state.server}/config/cameras/${encodeURIComponent(id)}`,
      { headers: authHeaders() });
    if (res.ok) {
      const cam = await res.json();
      const idx = (srvState.allCameras || []).findIndex(c => String(c.id) === String(cam.id));
      if (idx >= 0) srvState.allCameras[idx] = cam;
      mtOpen(cam);
      return;
    }
  } catch { /* fall through to cache */ }
  const cam = (srvState.allCameras || []).find(c => String(c.id) === id);
  if (cam) mtOpen(cam);
  else setStatus('Could not load that camera.');
}

/** Reflect persisted client options into the Client-section controls. */
function srvReflectClientOptions() {
  const set = (id, v) => { const el = document.getElementById(id); if (el) el.checked = !!v; };
  set('opt-show-infobar', options.showInfoBar);
  set('opt-hotkeys-enabled', options.hotkeysEnabled !== false);
  set('opt-launch-fullscreen', options.launchFullscreen);
  set('opt-wall-sub', options.liveWallSub !== false);
  set('opt-maximize-main', options.maximizeMain !== false);
  set('opt-show-allcams', options.showAllCamerasView !== false);
  set('opt-ptz-center', options.ptzClickMode !== 'pan' && options.ptzClickMode !== 'off');
  set('opt-ptz-pan', options.ptzClickMode === 'pan');
  set('opt-ptz-off', options.ptzClickMode === 'off');
  set('opt-ptz-edges', options.ptzStyle !== 'wheel');
  set('opt-ptz-wheel', options.ptzStyle === 'wheel');
  const wc = document.getElementById('opt-ptz-wheel-corner');
  if (wc) wc.value = options.ptzWheelCorner || 'bottom-left';
  srvRenderHotkeys();
  srvSetHotkeysConfigVisible(options.hotkeysEnabled !== false);
}

/** Show/hide the per-camera hotkey remap UI (note + remap list + Reset button).
 *  When the number hotkeys are disabled the remap window is just noise, so hide it. */
function srvSetHotkeysConfigVisible(on) {
  document.getElementById('srv-hotkeys-config')?.classList.toggle('hidden', !on);
  document.getElementById('srv-hotkeys-reset')?.classList.toggle('hidden', !on);
}

/** Render the Settings → This Computer "Camera hotkeys" remap list. */
function srvRenderHotkeys() {
  const el = document.getElementById('srv-hotkeys-list');
  if (!el) return;
  const cams = state.cameras || [];
  if (!cams.length) { el.innerHTML = '<div class="srv-loading">No cameras.</div>'; return; }
  const map = hotkeysConfigured();
  const optsFor = selectedTok => '<option value="">—</option>' + HOTKEY_TOKENS.map(tok =>
    `<option value="${tok}"${tok === selectedTok ? ' selected' : ''}>${escHtml(hotkeyLabel(tok))}</option>`).join('');
  el.innerHTML = cams.map(cam => {
    const tok = Object.keys(map).find(t => map[t] === cam.id) || '';
    return '<div class="srv-hotkey-row">' +
      `<span class="srv-hotkey-name" title="${escHtml(cam.name)}">${escHtml(cam.name)}</span>` +
      `<select class="srv-hotkey-select export-select" data-cam-id="${escHtml(String(cam.id))}">${optsFor(tok)}</select>` +
      '</div>';
  }).join('');
  el.querySelectorAll('.srv-hotkey-select').forEach(sel =>
    sel.addEventListener('change', () => srvHotkeyChanged(sel)));
}

/** A hotkey <select> changed → reassign uniquely (steal the key), persist, refresh. */
function srvHotkeyChanged(sel) {
  const camId = sel.dataset.camId;
  const tok = sel.value;
  const map = { ...hotkeysEffective() };           // make the effective map explicit
  Object.keys(map).forEach(t => { if (String(map[t]) === String(camId)) delete map[t]; });
  if (tok) { delete map[tok]; map[tok] = camId; }   // free the token, then assign it here
  options.hotkeys = map;
  saveOptions();
  srvRenderHotkeys();   // reflect the steal (the camera that lost the key shows —)
  buildCameraList();    // refresh the list badges
}

/** Reset hotkeys to pure auto (clear the saved override). */
function srvHotkeyReset() {
  options.hotkeys = {};
  saveOptions();
  srvRenderHotkeys();
  buildCameraList();
}

/** Populate the Client → Connection + Export panels. */
function srvRenderConnection() {
  const srv = document.getElementById('srv-conn-server');
  if (srv) srv.textContent = (state.server || '—').replace(/^https?:\/\//, '');
  const usr = document.getElementById('srv-conn-user');
  if (usr) usr.textContent = state.username || '—';
  const adminUrl = document.getElementById('srv-admin-url');
  if (adminUrl) adminUrl.textContent = (state.server || '—').replace(/\/$/, '') + '/admin';
  exportSyncDestLabels(); // reflect the saved export dir in the Export panel
}

// Statistics table columns (label + sort key + formatter). CPU is % of one core
// (a camera's recording+motion ffmpeg can exceed 100). CPU/Mem/GPU populate once
// the recorder reports per-camera resource usage; until then they render "—".
// GPU is null in the container unless nvidia-smi is in the recorder image.
const SRV_STATS_COLS = [
  { key: 'name',            label: 'Camera',    num: false },
  { key: 'cpu_pct',         label: 'CPU',       num: true, fmt: v => v == null ? '—' : `${Math.round(v)}%` },
  { key: 'mem_mb',          label: 'Mem',       num: true, fmt: v => v == null ? '—' : srvFmtMem(v) },
  { key: 'gpu_pct',         label: 'GPU',       num: true, fmt: v => v == null ? '—' : `${Math.round(v)}%` },
  { key: 'total_bytes',     label: 'Disk',      num: true, fmt: v => srvFmtBytes(v || 0) },
  { key: 'gb_per_hour',     label: 'GB/h',      num: true, fmt: v => v > 0 ? v.toFixed(2) : '—' },
  { key: 'segment_count',   label: 'Clips',     num: true, fmt: v => (v || 0).toLocaleString() },
  { key: 'retention_hours', label: 'Retention', num: true, fmt: v => srvFmtRetention(v) },
];

/** Format memory (MB) as "N MB" or "N.N GB". */
function srvFmtMem(mb) {
  if (mb == null) return '—';
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)} GB`;
  return `${Math.round(mb)} MB`;
}

/** Per-camera storage/usage statistics (Statistics section) — GET /stats/cameras. */
async function srvLoadStats() {
  const el = document.getElementById('srv-stats-rows');
  if (!el) return;
  let data;
  try {
    const res = await fetchWithTimeout(`${state.server}/stats/cameras`, { headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (res.status === 403) {
      el.innerHTML = '<div class="srv-loading">Admin account required to view statistics.</div>';
      return;
    }
    if (!res.ok) throw new Error(`GET /stats/cameras → ${res.status}`);
    data = await res.json();
  } catch (e) {
    el.innerHTML = `<div class="srv-loading">Failed to load statistics: ${escHtml(e.message)}</div>`;
    return;
  }
  srvState.statsCams = data.cameras || [];
  srvRenderStats();
}

/** Sort srvState.statsCams by the active column and render the table + clickable headers. */
function srvRenderStats() {
  const el = document.getElementById('srv-stats-rows');
  if (!el) return;
  const cams = srvState.statsCams || [];

  const totalEl = document.getElementById('srv-stats-total');
  if (totalEl) {
    const tB = cams.reduce((s, c) => s + (c.total_bytes || 0), 0);
    const tR = cams.reduce((s, c) => s + (c.gb_per_hour || 0), 0);
    totalEl.textContent = cams.length ? `${srvFmtBytes(tB)} · ${tR.toFixed(1)} GB/h` : '';
  }
  if (!cams.length) { el.innerHTML = '<div class="srv-loading">No cameras.</div>'; return; }

  const { key, dir } = srvState.statsSort;
  const sorted = cams.slice().sort((a, b) => {
    if (key === 'name') return dir * String(a.name || '').localeCompare(String(b.name || ''));
    const av = typeof a[key] === 'number' ? a[key] : -Infinity;
    const bv = typeof b[key] === 'number' ? b[key] : -Infinity;
    return dir * (av - bv);
  });

  const head = '<div class="srv-stats-head">' + SRV_STATS_COLS.map(col => {
    const cls = [];
    if (col.num) cls.push('srv-stats-num');
    if (col.key === key) cls.push('sorted');
    const arrow = col.key === key ? `<span class="srv-stats-arrow">${dir > 0 ? '▲' : '▼'}</span>` : '';
    return `<span data-key="${col.key}" class="${cls.join(' ')}">${col.label}${arrow}</span>`;
  }).join('') + '</div>';

  const rows = sorted.map(c => '<div class="srv-stats-row">' + SRV_STATS_COLS.map(col => {
    if (col.key === 'name') {
      return `<span class="srv-stats-name" title="${escHtml(c.name)}">${escHtml(c.name)}</span>`;
    }
    const raw = c[col.key];
    const txt = col.fmt ? col.fmt(raw) : (raw == null ? '—' : String(raw));
    const zero = (raw == null || raw === 0 || txt === '—') ? ' zero' : '';
    return `<span class="srv-stats-num${zero}">${escHtml(String(txt))}</span>`;
  }).join('') + '</div>').join('');

  el.innerHTML = head + rows;

  el.querySelectorAll('.srv-stats-head > span').forEach(h => {
    h.addEventListener('click', () => {
      const k = h.dataset.key;
      if (srvState.statsSort.key === k) srvState.statsSort.dir *= -1;
      else srvState.statsSort = { key: k, dir: k === 'name' ? 1 : -1 };
      srvRenderStats();
    });
  });
}

/** Format a retention span (hours) as "N h" or "N.N d". */
function srvFmtRetention(hours) {
  if (!hours || hours <= 0) return '—';
  if (hours < 48) return `${Math.round(hours)} h`;
  return `${(hours / 24).toFixed(1)} d`;
}

/* Storage media glyphs (Lucide, MIT) — kept in lockstep with the admin console's
   ICON_PATHS so the desktop shows the same icon the server resolved. The /status
   storages carry `icon` = the RESOLVED kind ('ssd'|'hdd'|'disk'); we just draw it. */
const SRV_STORAGE_GLYPHS = {
  ssd:  '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M13 7l-4 6h3l-1 4 4-6h-3z" fill="currentColor" stroke="none"/>',
  hdd:  '<ellipse cx="12" cy="6" rx="7" ry="3"/><path d="M5 6v12a7 3 0 0 0 14 0V6"/><path d="M5 12a7 3 0 0 0 14 0"/>',
  disk: '<rect x="3" y="4" width="18" height="6" rx="1"/><rect x="3" y="14" width="18" height="6" rx="1"/><circle cx="7" cy="7" r="0.8" fill="currentColor" stroke="none"/><circle cx="7" cy="17" r="0.8" fill="currentColor" stroke="none"/>',
};
/** Inline SVG for a storage's resolved media kind, defaulting to the generic disk. */
function storageGlyph(kind, size = 15) {
  const p = SRV_STORAGE_GLYPHS[kind] || SRV_STORAGE_GLYPHS.disk;
  return `<svg class="srv-storage-icon" viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${p}</svg>`;
}

/** Render the Server → recording-paths list from the /status storages. */
function srvRenderPaths(storages) {
  const container = document.getElementById('srv-paths-rows');
  if (!container) return;
  if (!storages || !storages.length) {
    container.innerHTML = '<div class="srv-loading">No storage volumes reported.</div>';
    return;
  }
  container.innerHTML = storages.map(vol =>
    '<div class="srv-kv">' +
    `<span class="srv-kv-k">${storageGlyph(vol.icon)}${escHtml(vol.name || vol.id || 'Volume')}</span>` +
    `<span class="srv-kv-v">${escHtml(vol.path || '—')}</span>` +
    '</div>'
  ).join('');
}

function srvStopRefresh() {
  if (srvState.refreshTimer !== null) {
    clearInterval(srvState.refreshTimer);
    srvState.refreshTimer = null;
  }
  srvStopPreview(); // also halt the camera preview when leaving the Server tab
}

// ── Utility helpers ───────────────────────────────────────────────────────────

/** Format bytes as "X.X GB" or "XXX MB". */
function srvFmtBytes(bytes) {
  if (typeof bytes !== 'number' || isNaN(bytes)) return '—';
  const gb = bytes / (1024 ** 3);
  if (gb >= 1) return `${gb.toFixed(1)} GB`;
  const mb = bytes / (1024 ** 2);
  return `${Math.round(mb)} MB`;
}

/** Format an ISO timestamp as a compact local time string. */
function srvFmtTimestamp(iso) {
  if (!iso) return '—';
  try {
    const d = new Date(iso);
    const pad = n => String(n).padStart(2, '0');
    return `${pad(d.getMonth() + 1)}/${pad(d.getDate())} ` +
           `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  } catch {
    return iso;
  }
}

/** How many seconds ago was an ISO timestamp? */
function srvSecondsAgo(iso) {
  if (!iso) return null;
  try {
    return (Date.now() - new Date(iso).getTime()) / 1000;
  } catch {
    return null;
  }
}

// ── Health panel ──────────────────────────────────────────────────────────────

async function srvLoadHealth() {
  let data;
  try {
    const res = await fetchWithTimeout(`${state.server}/status`, { headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (res.status === 403) {
      srvSetHealthError('403 — admin account required to view server status.');
      return;
    }
    if (!res.ok) throw new Error(`GET /status → ${res.status}`);
    data = await res.json();
  } catch (e) {
    srvSetHealthError(`Failed to load status: ${e.message}`);
    return;
  }

  srvRenderHeartbeat(data.recorder_heartbeat);
  srvRenderDiskLine(data.storages ?? []);
  void srvLoadPolicyUsage();
  void srvLoadFrigateStatus(data.cameras ?? []);
}

/** Populate the "Frigate detection — Status" row from recent /events. The status
 *  used to be a permanent "—" (never wired up), which read as "not working". We
 *  query the last hour of detection events across all cameras and report whether
 *  the pipeline is live (events flowing), idle (connected, nothing detected), or
 *  unavailable (endpoint error). */
async function srvLoadFrigateStatus(cameras) {
  const el = document.getElementById('srv-frigate-status');
  if (!el) return;
  const camIds = (cameras || []).map(c => c.id).filter(Boolean);
  if (!camIds.length) { el.textContent = 'No cameras configured'; el.style.color = ''; return; }
  const end = new Date();
  const start = new Date(end.getTime() - 60 * 60 * 1000);
  try {
    const url = `${state.server}/events?camera_ids=${camIds.join(',')}`
      + `&start=${encodeURIComponent(start.toISOString())}&end=${encodeURIComponent(end.toISOString())}&limit=200`;
    const res = await fetchWithTimeout(url, { headers: authHeaders() });
    if (!res.ok) {
      el.textContent = `Unavailable (HTTP ${res.status})`;
      el.style.color = 'var(--danger, #E5484D)';
      return;
    }
    const data = await res.json();
    const events = Array.isArray(data) ? data : (data.events || []);
    if (!events.length) {
      el.textContent = 'Connected — no detections in the last hour';
      el.style.color = 'var(--dim, #8a909c)';
      return;
    }
    let latestMs = 0;
    for (const e of events) {
      const t = Date.parse(e.start_ts || e.ts || e.end_ts || '');
      if (t && t > latestMs) latestMs = t;
    }
    let agoTxt = '';
    if (latestMs) {
      const s = Math.max(0, (Date.now() - latestMs) / 1000);
      agoTxt = s < 60 ? `${Math.round(s)}s ago`
             : s < 3600 ? `${Math.round(s / 60)}m ago`
             : `${Math.round(s / 3600)}h ago`;
    }
    el.textContent = `Active — ${events.length} event${events.length === 1 ? '' : 's'} in the last hour`
      + (agoTxt ? ` (latest ${agoTxt})` : '');
    el.style.color = 'var(--ok, #34C759)';
  } catch (e) {
    el.textContent = 'Unavailable (network error)';
    el.style.color = 'var(--danger, #E5484D)';
  }
}

function srvSetHealthError(msg) {
  const diskEl   = document.getElementById('srv-disk-line');
  const policyEl = document.getElementById('srv-policy-rows');
  if (diskEl)   diskEl.innerHTML   = `<span class="srv-loading">${escHtml(msg)}</span>`;
  if (policyEl) policyEl.innerHTML = `<div class="srv-loading">${escHtml(msg)}</div>`;
}

/** Render a compact disk free-space line, one chip per distinct storage path.
 *  Dedupes by exact path string so a disk exposed as two SAME-path storage rows
 *  (#67) shows once; same-disk-different-subdir rows still show separately until
 *  #67 is resolved. */
function srvRenderDiskLine(storages) {
  const el = document.getElementById('srv-disk-line');
  if (!el) return;
  if (!storages || !storages.length) {
    el.innerHTML = '<span class="srv-loading">No storage volumes reported.</span>';
    return;
  }
  const byPath = new Map();
  storages.forEach(vol => {
    const key = vol.path || vol.name || vol.id || '?';
    const free = (vol.free_bytes == null) ? null : vol.free_bytes;
    if (!byPath.has(key)) byPath.set(key, { names: [], free, icon: vol.icon });
    const e = byPath.get(key);
    const nm = vol.name || vol.id;
    if (nm && !e.names.includes(nm)) e.names.push(nm);
    if (e.free == null && free != null) e.free = free;
    if (!e.icon && vol.icon) e.icon = vol.icon;
  });
  const parts = [];
  byPath.forEach(e => {
    const name = e.names.join(' / ') || 'Disk';
    const freeTxt = e.free != null ? `${srvFmtBytes(e.free)} free` : 'capacity unavailable';
    parts.push(`<span class="srv-disk-chip">${storageGlyph(e.icon, 13)}<b>${escHtml(name)}</b> ${escHtml(freeTxt)}</span>`);
  });
  el.innerHTML = parts.join('');
}

// ── Recording-at-risk alert (disk full / under-provisioned) ───────────────────
// Surfaces, on EVERY tab, when the recorder is dropping (or about to drop) footage
// because a disk is filling up or a policy's size budget is too small for its
// configured retention. Computed from the already-served /status (physical free
// space) + /stats/policies (size-vs-time binding) — no extra backend.

const recordingAlertState = { warnings: [], timer: null };

// A recorded disk below these thresholds is about to start dropping recordings.
const DISK_FREE_WARN_PCT = 12;
const DISK_FREE_CRIT_PCT = 4;
const DISK_FREE_WARN_BYTES = 50 * 1e9;
const DISK_FREE_CRIT_BYTES = 12 * 1e9;

/** Build the list of recording-at-risk warnings from /status storages + policies. */
function computeRecordingWarnings(storages, policies) {
  const out = [];
  // 1) Physical disk running out (dedupe by path → one per physical disk). This is
  //    REAL free space (statvfs), not the size-budget — a budget-full disk with
  //    plenty of physical space is normal eviction, not an alert.
  const seen = new Set();
  (storages || []).forEach(vol => {
    const key = vol.path || vol.name || vol.id;
    if (!key || seen.has(key)) return;
    seen.add(key);
    const total = vol.total_bytes || vol.fs_total_bytes || null;
    const free = (vol.free_bytes == null) ? null : vol.free_bytes;
    if (total == null || free == null || total <= 0) return;
    const pct = (free / total) * 100;
    const nm = vol.name || vol.id || 'Disk';
    if (pct < DISK_FREE_CRIT_PCT || free < DISK_FREE_CRIT_BYTES) {
      out.push({ level: 'crit', text: `Disk "${nm}" is ${(100 - pct).toFixed(0)}% full — only ${srvFmtBytes(free)} free. Recording stops when it fills.` });
    } else if (pct < DISK_FREE_WARN_PCT || free < DISK_FREE_WARN_BYTES) {
      out.push({ level: 'warn', text: `Disk "${nm}" is low — ${srvFmtBytes(free)} free (${pct.toFixed(0)}%). Free space soon or recordings will drop.` });
    }
  });
  // 2) Under-provisioned policy: the size budget evicts footage BEFORE the
  //    configured time retention (binding == 'size') → recording the operator
  //    expects to keep is being dropped early.
  (policies || []).forEach(p => {
    if (p.binding_limit === 'size') {
      const held = srvFmtRetention(p.size_bound_retention_hours);
      const target = srvFmtRetention(p.live_retention_hours_cap);
      out.push({ level: 'warn', text: `"${p.label}" only holds ~${held} of its ${target} target — older footage is dropped early. Raise its size budget or add storage.` });
    }
  });
  // 3) Over budget AND not catching up: a capped policy whose live usage is well
  //    OVER its cap means eviction can't keep it under control (archive disk full,
  //    or eviction stuck). A healthy capped policy sits AT or below its cap (below
  //    the low-water when a breathing-room buffer is set), so a 10% margin never
  //    trips on normal operation. NOT raised for merely being NEAR the cap — that's
  //    the policy working as configured (surfaced as the row's "near full" badge,
  //    not an every-tab banner).
  (policies || []).forEach(p => {
    const cap = p.live_max_bytes || 0;
    const used = p.live_used_bytes || 0;
    if (cap > 0 && used > cap * 1.10) {
      const overPct = ((used / cap - 1) * 100).toFixed(0);
      out.push({ level: 'warn', text: `"${p.label}" is ${overPct}% over its size budget (${srvFmtBytes(used)} / ${srvFmtBytes(cap)}). Eviction is catching up — if it persists, the archive disk may be full or eviction is stuck.` });
    }
  });
  return out;
}

/** Show/hide the top banner (every tab) + the Recorder Health detail list. */
function renderRecordingAlert(warnings) {
  recordingAlertState.warnings = warnings || [];
  const w = recordingAlertState.warnings;
  const hasCrit = w.some(x => x.level === 'crit');

  const banner = document.getElementById('recording-alert-banner');
  const txt = document.getElementById('recording-alert-text');
  if (banner && txt) {
    if (!w.length) {
      banner.classList.add('hidden');
    } else {
      banner.classList.remove('hidden');
      banner.classList.toggle('warn', !hasCrit);
      txt.textContent = w.length === 1
        ? w[0].text
        : `${w.length} recording-storage warnings — ${w[0].text}`;
    }
  }

  const detail = document.getElementById('srv-health-alert');
  if (detail) {
    if (!w.length) {
      detail.classList.add('hidden');
      detail.innerHTML = '';
    } else {
      detail.classList.remove('hidden');
      detail.classList.toggle('warn', !hasCrit);
      detail.innerHTML = w.map(x =>
        `<div class="sha-line"><b>${x.level === 'crit' ? 'CRITICAL:' : 'Warning:'}</b> ${escHtml(x.text)}</div>`
      ).join('');
    }
  }
}

/** Fetch the inputs + refresh the recording-at-risk alert. Safe to call from any
 *  tab; quietly keeps the last state on a transient error. */
async function pollRecordingAlerts() {
  if (!state.server || !state.token) return;
  try {
    const [sRes, pRes] = await Promise.all([
      fetchWithTimeout(`${state.server}/status`, { headers: authHeaders() }),
      fetchWithTimeout(`${state.server}/stats/policies`, { headers: authHeaders() }),
    ]);
    if (sRes.status === 401) { handleUnauthorized(); return; }
    const status = sRes.ok ? await sRes.json() : {};
    const policies = pRes.ok ? ((await pRes.json()).policies || []) : [];
    renderRecordingAlert(computeRecordingWarnings(status.storages || [], policies));
  } catch { /* transient — keep showing the last computed state */ }
}

/** Start the global 60s recording-alert poll (called once the app is shown). */
function startRecordingAlertPoll() {
  if (recordingAlertState.timer) clearInterval(recordingAlertState.timer);
  void pollRecordingAlerts();
  recordingAlertState.timer = setInterval(() => void pollRecordingAlerts(), 60000);
}

/** Stop the poll + clear the banner (on sign-out / session end). */
function stopRecordingAlertPoll() {
  if (recordingAlertState.timer) { clearInterval(recordingAlertState.timer); recordingAlertState.timer = null; }
  renderRecordingAlert([]);
}

// ── Update-available checker (issue #7) ───────────────────────────────────────
// Non-intrusive "vX.Y.Z available -> release notes" notice in Settings → This
// Computer → About. The signal comes from THIS server's GET /updates/latest
// (server-mediated per docs/UPDATE-SYSTEM-PLAN.md D2 — the client never talks
// to GitHub itself); version compare against getVersion() is local. A 404 (old
// server) or enabled:false (operator turned the check off) shows nothing.

const LS_UPDATE_DISMISSED_KEY = 'crumb_update_dismissed_version';
const UPDATE_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000; // periodic re-check while the app stays open
// Light in-session guard: coalesce checks fired close together (a launch check +
// an About-panel open, or rapid re-renders) into one actual request. The 24h
// interval governs periodic re-checks; this only debounces bursts.
const UPDATE_CHECK_MIN_GAP_MS = 15 * 1000;

const updateState = {
  data: null,        // last successful enabled:true /updates/latest body, else null
  ownVersion: null,  // resolved once via the Tauri app API; null = unknown/dev build
  timer: null,
  checking: false,   // a request is in flight → the About field shows "Checking…"
  lastCheckMs: 0,    // wall time of the last fired check (for the burst guard)
};

/** Parse a bare "MAJOR.MINOR.PATCH" string into [maj,min,patch] ints. Anything
 *  else (a dev build like "0.0.1-dev", empty, non-numeric) is unparsable —
 *  callers must treat that as "don't know," never guess a comparison. */
function updParseVersion(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(v || '').trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

/** True only when `latest` is a parsable version strictly greater than `own`.
 *  Either side failing to parse means never show the banner (own == a dev
 *  build, or a malformed latest_version) rather than guessing. */
function updIsNewer(latest, own) {
  const a = updParseVersion(latest);
  const b = updParseVersion(own);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] > b[i];
  }
  return false;
}

/** Resolve this build's own version once via the Tauri app API. Cached; an
 *  unavailable/unparsable version (dev tree) just means the banner never shows. */
async function updResolveOwnVersion() {
  try {
    updateState.ownVersion = await window.__TAURI__.app.getVersion();
  } catch {
    updateState.ownVersion = null;
  }
  updRender();
}

function getDismissedUpdateVersion() {
  try { return localStorage.getItem(LS_UPDATE_DISMISSED_KEY) || ''; } catch { return ''; }
}
function setDismissedUpdateVersion(v) {
  try { localStorage.setItem(LS_UPDATE_DISMISSED_KEY, v || ''); } catch { /* quota */ }
}

/** Fetch GET /updates/latest (optionally forcing a fresh GitHub check server-side
 *  via ?refresh=1, see UPDATE-SYSTEM-PLAN.md §2.5 "Check now"). A 404 (server too
 *  old for the endpoint) or a 200 with enabled:false clears the state (nothing
 *  shows); other transient failures keep the last known state. Sets the in-flight
 *  flag so the About field can show "Checking…" while the request runs. */
async function updCheck(refresh) {
  if (!state.server || !state.token) return;
  updateState.checking = true;
  updateState.lastCheckMs = Date.now();
  updRender();
  try {
    const res = await api(`/updates/latest${refresh ? '?refresh=1' : ''}`);
    if (res.status === 404) {
      updateState.data = null;                    // server too old for the endpoint
    } else if (res.ok) {
      const body = await res.json();
      updateState.data = body && body.enabled ? body : null; // enabled:false → clear
    }
    // Any other non-ok status: keep the last known state (transient).
  } catch { /* transient — keep the last known state */ }
  finally {
    updateState.checking = false;
    updRender();
  }
}

/** Fire a normal (non-forced) check unless one ran very recently — coalesces a
 *  launch check with an immediate About-panel open, and absorbs rapid re-renders,
 *  without spamming the server. `force` (the manual "Check now") bypasses this. */
function updMaybeCheck() {
  if (updateState.checking) return;
  if (Date.now() - updateState.lastCheckMs < UPDATE_CHECK_MIN_GAP_MS) return;
  void updCheck(false);
}

/** Begin the update poll on app launch: resolve own version, run one check now
 *  (every launch — NOT gated behind the 24h interval), then re-check periodically
 *  while the app stays open. */
function startUpdateCheckPoll() {
  if (updateState.timer) clearInterval(updateState.timer);
  if (!updateState.ownVersion) void updResolveOwnVersion();
  updateState.lastCheckMs = 0;                    // ensure the launch check always fires
  updMaybeCheck();
  updateState.timer = setInterval(() => void updCheck(false), UPDATE_CHECK_INTERVAL_MS);
}

/** Stop the poll + clear the notice (on sign-out). */
function stopUpdateCheckPoll() {
  if (updateState.timer) { clearInterval(updateState.timer); updateState.timer = null; }
  updateState.data = null;
  updateState.checking = false;
  updRender();
}

/** Opening Settings → This Computer (which holds the About panel) triggers a
 *  fresh check so the always-present Updates field is never stale. This is how a
 *  client that first checked while the server had the feature OFF can discover it
 *  was later turned ON. Coalesced by updMaybeCheck so re-entry doesn't spam. */
function updEnterAbout() {
  updMaybeCheck();
}

/** Reflect updateState into the Settings → This Computer → About panel. */
function updRender() {
  const verEl = document.getElementById('srv-app-version');
  if (verEl) verEl.textContent = updateState.ownVersion ? `v${updateState.ownVersion}` : 'unknown (dev build)';

  const d = updateState.data;
  const enabled = !!d;                            // server reports the check enabled
  const newer = !!(d && d.latest_version && updIsNewer(d.latest_version, updateState.ownVersion));
  const ownKnown = !!updParseVersion(updateState.ownVersion);

  // "Check now" is present only while the check is enabled.
  const checkBtn = document.getElementById('srv-update-check-btn');
  if (checkBtn) checkBtn.classList.toggle('hidden', !enabled);

  // Always-present Updates status field (only while enabled). States:
  //   "Checking…" / "Update available: vX" (+link) / "You're up to date (vX)".
  const fieldRow = document.getElementById('srv-update-field-row');
  const fieldText = document.getElementById('srv-update-field-text');
  const fieldLink = document.getElementById('srv-update-field-link');
  if (fieldRow) fieldRow.classList.toggle('hidden', !enabled);
  if (enabled && fieldText) {
    let msg;
    let linkUrl = '';
    if (updateState.checking) {
      msg = 'Checking…';
    } else if (newer) {
      msg = `Update available: v${d.latest_version}`;
      linkUrl = d.notes_url || '';
    } else if (d.latest_version && ownKnown) {
      msg = `You're up to date (v${d.latest_version})`;
    } else if (d.latest_version) {
      // Own version unparsable (dev build): no up-to-date/behind claim, just report latest.
      msg = `Latest release: v${d.latest_version}`;
    } else {
      // Enabled, but the server has no successful GitHub fetch yet.
      msg = 'Latest version unknown';
    }
    fieldText.textContent = msg;
    if (fieldLink) {
      fieldLink.classList.toggle('hidden', !linkUrl);
      fieldLink.dataset.url = linkUrl;
    }
  }

  // Dismissible proactive banner: only while an update is available and this
  // version hasn't been dismissed. Fed by the every-launch check.
  const banner = document.getElementById('srv-update-banner');
  const text = document.getElementById('srv-update-text');
  const link = document.getElementById('srv-update-link');
  const showBanner = newer && d.latest_version !== getDismissedUpdateVersion();
  if (banner) banner.classList.toggle('hidden', !showBanner);
  if (showBanner) {
    if (text) text.textContent = `Update available: v${d.latest_version}`;
    if (link) {
      link.classList.toggle('hidden', !d.notes_url);
      link.dataset.url = d.notes_url || '';
    }
  }
}

/** "Check now" click (§2.5): force a fresh server-side check. The always-present
 *  field reflects the outcome ("Checking…" → up-to-date / update-available). */
async function onUpdateCheckNow() {
  const btn = document.getElementById('srv-update-check-btn');
  if (btn) btn.disabled = true;
  await updCheck(true);
  if (btn) btn.disabled = false;
}

/** Dismiss the current banner — remembers this version so the banner stays quiet
 *  until a newer release appears (per-version, not permanent). The always-present
 *  Updates field still shows the available update. */
function onUpdateDismiss() {
  const d = updateState.data;
  if (d && d.latest_version) setDismissedUpdateVersion(d.latest_version);
  updRender();
}

/** A short human forecast string for a policy's LIVE store. */
function srvFmtForecast(p) {
  switch (p.binding_limit) {
    case 'size':
      return `full in ${srvFmtRetention(p.live_time_to_full_hours)} · size-capped near ${srvFmtRetention(p.size_bound_retention_hours)}`;
    case 'time':
      return `steady ~${srvFmtRetention(p.live_retention_hours_cap)} (time-capped)`;
    default:
      return 'projecting…';
  }
}

/** Load + render per-policy usage from /stats/policies (admin only).
 *  Throttled to ~20s: it's a full per-policy segments aggregate, so it must NOT
 *  run on every 5s health tick. Section-enter resets the throttle (srvSelectSection)
 *  so the panel is fresh when you open it. */
async function srvLoadPolicyUsage() {
  const now = Date.now();
  if (srvState.lastPolicyUsageMs && (now - srvState.lastPolicyUsageMs) < 20000) return;
  srvState.lastPolicyUsageMs = now; // set before await so concurrent ticks don't double-fire
  const el = document.getElementById('srv-policy-rows');
  try {
    const res = await fetchWithTimeout(`${state.server}/stats/policies`, { headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (res.status === 403) {
      if (el) el.innerHTML = '<div class="srv-loading">Admin account required.</div>';
      return;
    }
    if (!res.ok) throw new Error(`GET /stats/policies → ${res.status}`);
    const data = await res.json();
    srvRenderPolicyUsage(data.policies || []);
  } catch (e) {
    if (el) el.innerHTML = `<div class="srv-loading">Failed: ${escHtml(e.message)}</div>`;
  }
}

/** Render one bar + numeric sub-line + verification badge per recording policy. */
function srvRenderPolicyUsage(policies) {
  const container = document.getElementById('srv-policy-rows');
  if (!container) return;
  const totalBadge = document.getElementById('srv-policy-total');
  if (!policies.length) {
    container.innerHTML = '<div class="srv-loading">No recording policies in use.</div>';
    if (totalBadge) totalBadge.textContent = '';
    return;
  }
  let totUsed = 0;
  container.innerHTML = '';
  policies.forEach(p => {
    const used = p.live_used_bytes || 0;
    const cap = p.live_max_bytes || null;
    totUsed += used + (p.archive_used_bytes || 0);
    const pct = cap ? Math.max(0, Math.min(100, (used / cap) * 100)) : 0;

    // Bar fill colour AND the status badge are derived from the SAME thresholds so
    // they can never disagree (a red bar always has a red badge, etc.):
    //   over cap  → red    "over budget" (eviction is trimming the oldest footage)
    //   ≥ 90%     → red    "near full"
    //   ≥ 75%     → amber  "filling"
    //   < 75%     → green  "ok"
    //   no cap    → neutral "no cap" (time-based retention only)
    let fillCls = '';
    let badge;
    if (!cap) {
      badge = '<span class="srv-stats-num" title="No size cap — time-based retention only">no cap</span>';
    } else if (used > cap) {
      fillCls = 'crit';
      badge = '<span class="srv-heartbeat-badge dead" title="Over the size budget — eviction is trimming the oldest footage to get back under the cap">over budget</span>';
    } else if (pct >= 90) {
      fillCls = 'crit';
      badge = '<span class="srv-heartbeat-badge dead" title="Near the size budget you set — close to the cap">near full</span>';
    } else if (pct >= 75) {
      fillCls = 'warn';
      badge = '<span class="srv-heartbeat-badge warn" title="Filling toward the size budget">filling</span>';
    } else {
      badge = '<span class="srv-heartbeat-badge ok" title="Within size budget">ok</span>';
    }

    const capTxt = cap ? srvFmtBytes(cap) : '∞';
    const pctTxt = cap ? `${pct.toFixed(0)}%` : '—';
    const camN = p.camera_count === 1 ? '1 cam' : `${p.camera_count} cams`;
    const sub = `${srvFmtBytes(used)} / ${capTxt} (${pctTxt}) · ${camN} · ${(p.gb_per_hour || 0).toFixed(1)} GB/h · ${srvFmtForecast(p)}`;

    const row = document.createElement('div');
    row.className = 'srv-policy-row';
    row.dataset.policy = p.policy_id;
    row.innerHTML =
      '<div class="srv-storage-row" style="margin-bottom:2px">' +
        `<span class="srv-storage-name" title="${escHtml((p.camera_names || []).join(', '))}">${escHtml(p.label)}</span>` +
        `<div class="srv-storage-bar-wrap"><div class="srv-storage-bar-fill ${fillCls}" style="width:${pct.toFixed(1)}%"></div></div>` +
        `<span class="srv-storage-free">${badge}</span>` +
      '</div>' +
      `<div class="srv-policy-sub">${escHtml(sub)}</div>`;
    container.appendChild(row);
  });
  if (totalBadge) totalBadge.textContent = `${srvFmtBytes(totUsed)} used`;
}

/** Tier-B verification: walk the disk and stamp each policy row green/amber. */
async function srvVerifyPolicySizes() {
  const btn = document.getElementById('srv-policy-verify');
  const msg = document.getElementById('srv-policy-verify-msg');
  if (btn) btn.disabled = true;
  if (msg) msg.textContent = 'Walking disk…';
  try {
    const res = await fetchWithTimeout(`${state.server}/stats/policies/verify`, { headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (res.status === 403) { if (msg) msg.textContent = 'Admin account required.'; return; }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    let worst = 0;
    (data.policies || []).forEach(v => {
      const row = document.querySelector(`.srv-policy-row[data-policy="${CSS.escape(v.policy_id)}"]`);
      const host = row && row.querySelector('.srv-storage-free');
      if (Math.abs(v.delta_pct) > Math.abs(worst)) worst = v.delta_pct;
      if (host) {
        const ok = Math.abs(v.delta_pct) <= 1;
        host.innerHTML = ok
          ? '<span class="srv-heartbeat-badge ok" title="DB matches disk">✓ disk</span>'
          : `<span class="srv-stats-num bad" title="DB ${srvFmtBytes(v.db_bytes)} vs disk ${srvFmtBytes(v.disk_bytes)}">Δ ${v.delta_pct.toFixed(1)}%</span>`;
      }
    });
    if (msg) msg.textContent = `Checked ${(data.policies || []).length} · worst Δ ${worst.toFixed(1)}%`;
  } catch (e) {
    if (msg) msg.textContent = `Verify failed: ${e.message}`;
  } finally {
    if (btn) btn.disabled = false;
  }
}

function srvRenderHeartbeat(hbIso) {
  const badge = document.getElementById('srv-heartbeat');
  if (!badge) return;

  const age = srvSecondsAgo(hbIso);
  if (age === null) {
    badge.textContent = 'heartbeat —';
    badge.className = 'srv-heartbeat-badge';
    return;
  }

  let label, cls;
  if (age < 15) {
    label = `heartbeat ${Math.round(age)}s ago`;
    cls = 'ok';
  } else if (age < 60) {
    label = `heartbeat ${Math.round(age)}s ago`;
    cls = 'warn';
  } else {
    label = `heartbeat ${Math.round(age / 60)}m ago — STALE`;
    cls = 'dead';
  }
  badge.textContent = label;
  badge.className = `srv-heartbeat-badge ${cls}`;
}

function srvRenderStorageRows(storages) {
  const container = document.getElementById('srv-storage-rows');
  if (!container) return;

  if (storages.length === 0) {
    container.innerHTML = '<div class="srv-loading">No storage volumes reported.</div>';
    return;
  }

  container.innerHTML = '';
  storages.forEach(vol => {
    // Mirror the admin console's capacity bar: prefer a configured size cap, else
    // the live filesystem total (statvfs). "used" = total − free (disk fullness),
    // NOT just our segment bytes — using total_bytes||1 made the bar bogus when a
    // storage had no cap configured.
    const total = vol.total_bytes || vol.fs_total_bytes || null;
    const free  = vol.free_bytes == null ? null : vol.free_bytes;
    const used  = (total != null && free != null) ? Math.max(0, total - free) : (vol.used_bytes || 0);
    const pct   = total ? Math.max(0, Math.min(100, (used / total) * 100)) : 0;

    let fillCls = '';
    if (pct >= 90) fillCls = 'crit';
    else if (pct >= 75) fillCls = 'warn';

    const freeLabel = free != null ? `${srvFmtBytes(free)} free`
                    : (total ? '' : 'capacity unavailable');

    const row = document.createElement('div');
    row.className = 'srv-storage-row';
    row.innerHTML = `
      <span class="srv-storage-name" title="${escHtml(vol.path ?? '')}">
        ${storageGlyph(vol.icon)}${escHtml(vol.name || vol.id || 'Volume')}
      </span>
      <div class="srv-storage-bar-wrap">
        <div class="srv-storage-bar-fill ${fillCls}" style="width:${pct.toFixed(1)}%"></div>
      </div>
      <span class="srv-storage-free">${escHtml(freeLabel)}</span>
    `;
    container.appendChild(row);
  });
}

function srvRenderCameraRows(cameras) {
  const container = document.getElementById('srv-camera-rows');
  if (!container) return;

  if (cameras.length === 0) {
    container.innerHTML = '<div class="srv-loading">No cameras reported.</div>';
    return;
  }

  container.innerHTML = '';
  cameras.forEach(cam => {
    const isRec  = !!cam.recording;
    const dotCls = isRec ? 'recording' : 'idle';
    const label  = isRec ? 'recording' : 'idle';

    const row = document.createElement('div');
    row.className = 'srv-cam-row';
    row.innerHTML = `
      <span class="srv-cam-name" title="${escHtml(cam.name)}">${escHtml(cam.name)}</span>
      <span class="srv-cam-status ${dotCls}">
        <span class="srv-cam-dot ${dotCls}"></span>
        ${label}
      </span>
      <span class="srv-cam-last">${escHtml(srvFmtTimestamp(cam.last_segment_end))}</span>
    `;
    container.appendChild(row);
  });
}

// ── Policy list ───────────────────────────────────────────────────────────────

async function srvLoadPolicyList() {
  // Fetch all cameras (not just enabled) for the policy editor
  let cameras = [];
  try {
    const res = await fetchWithTimeout(`${state.server}/config/cameras`, { headers: authHeaders() });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (!res.ok) throw new Error(`GET /config/cameras → ${res.status}`);
    cameras = await res.json();
  } catch (e) {
    const list = document.getElementById('srv-policy-list');
    if (list) list.innerHTML = `<div class="srv-loading">${escHtml('Failed: ' + e.message)}</div>`;
    return;
  }

  srvState.allCameras = cameras;
  srvRenderPolicyList();
}

function srvRenderPolicyList() {
  const list = document.getElementById('srv-policy-list');
  if (!list) return;
  list.innerHTML = '';

  // "Default Policy" entry at the top
  const defaultItem = document.createElement('div');
  defaultItem.className = 'srv-policy-item is-default' +
    (srvState.policyTarget?.type === 'default' ? ' active' : '');
  defaultItem.innerHTML = `<span class="srv-policy-item-dot"></span>Default Policy`;
  defaultItem.addEventListener('click', () => srvSelectPolicyTarget({ type: 'default' }));
  list.appendChild(defaultItem);

  // One row per camera
  srvState.allCameras.forEach(cam => {
    const item = document.createElement('div');
    const isActive = srvState.policyTarget?.type === 'camera' &&
                     srvState.policyTarget.id === cam.id;
    item.className = 'srv-policy-item' + (isActive ? ' active' : '');
    item.dataset.camId = cam.id;
    item.innerHTML = `<span class="srv-policy-item-dot"></span>${escHtml(cam.name)}`;
    item.addEventListener('click', () =>
      srvSelectPolicyTarget({ type: 'camera', id: cam.id, name: cam.name })
    );
    list.appendChild(item);
  });
}

// ── Policy target selection & form rendering ─────────────────────────────────

async function srvSelectPolicyTarget(target) {
  srvState.policyTarget = target;

  // Update active highlight
  document.querySelectorAll('#srv-policy-list .srv-policy-item').forEach(el => {
    const isDefault = target.type === 'default' && el.classList.contains('is-default');
    const isCam     = target.type === 'camera'  && el.dataset.camId === target.id;
    el.classList.toggle('active', isDefault || isCam);
  });

  // Fetch the policy for this target
  let policy;
  try {
    if (target.type === 'default') {
      const res = await fetchWithTimeout(`${state.server}/config/policy/default`, { headers: authHeaders() });
      if (res.status === 401) { handleUnauthorized(); return; }
      if (!res.ok) throw new Error(`GET /config/policy/default → ${res.status}`);
      policy = await res.json();
    } else {
      // Camera policy lives inside the CameraDto at .policy
      const res = await fetchWithTimeout(`${state.server}/config/cameras/${encodeURIComponent(target.id)}`,
        { headers: authHeaders() });
      if (res.status === 401) { handleUnauthorized(); return; }
      if (!res.ok) throw new Error(`GET /config/cameras/${target.id} → ${res.status}`);
      const dto = await res.json();
      policy = dto.policy ?? {};
      // Keep the camera cache fresh so the Motion Tuner (which reads its camera
      // from this cache) and this editor never diverge after a save in either one.
      const ci = (srvState.allCameras || []).findIndex(c => c.id === dto.id);
      if (ci >= 0) srvState.allCameras[ci] = dto;
    }
  } catch (e) {
    srvShowPolicyStatus(`Failed to load policy: ${e.message}`, 'err');
    return;
  }

  srvRenderPolicyForm(policy);
}

// ── Policy form ───────────────────────────────────────────────────────────────

function srvRenderPolicyForm(policy) {
  const formEl  = document.getElementById('srv-policy-form');
  const statusEl = document.getElementById('srv-policy-status');
  if (!formEl) return;

  // Hide stale status
  if (statusEl) statusEl.className = 'srv-policy-status hidden';

  const target = srvState.policyTarget;
  const title  = target.type === 'default'
    ? 'Default Policy'
    : `Camera: ${escHtml(target.name)}`;

  const p = policy ?? {};
  const mode        = p.mode                ?? 'continuous';
  const recAudio    = !!p.record_audio;
  const recStream   = p.record_stream       ?? 'main';
  const retentionH  = p.live_retention_hours ?? 24;
  const preS        = p.motion_pre_seconds  ?? 5;
  const postS       = p.motion_post_seconds ?? 30;
  const sensitivity = p.motion_sensitivity  ?? 'dynamic';
  // motion_threshold is a FRACTION of frame (0..1; min object size). Show it as %
  // (0.30 default). Recorder clamps 0.05%..5%.
  const thresholdPct = ((p.motion_threshold ?? 0.0030) * 100).toFixed(2);
  const kfOnly      = !!p.motion_keyframes_only;

  // Live preview of the selected camera (refreshing snapshot from go2rtc), so you
  // see the camera you're configuring. Default Policy has no single camera → no preview.
  srvStopPreview();
  const previewCam = target.type === 'camera'
    ? (srvState.allCameras || []).find(c => c.id === target.id)
    : null;
  const previewHtml = previewCam ? `
    <div class="srv-cam-preview-wrap">
      <img id="srv-cam-preview" class="srv-cam-preview" alt="${escHtml(previewCam.name)} preview" />
      <span class="srv-cam-preview-label">LIVE</span>
    </div>` : '';

  // Build form HTML — motion fields hidden/shown by mode via JS below
  formEl.innerHTML = `
    ${previewHtml}
    <div class="srv-policy-form-title" style="
      font-size:11px; font-weight:600; color:var(--text-dim);
      text-transform:uppercase; letter-spacing:0.6px;
      padding-bottom:8px; margin-bottom:4px;
      border-bottom:1px solid var(--border-dim);
    ">${title}</div>

    <div class="srv-field-row">
      <label class="srv-field-label" for="srv-p-mode">Recording mode</label>
      <select id="srv-p-mode" class="srv-select">
        <option value="continuous"${mode === 'continuous' ? ' selected' : ''}>Continuous</option>
        <option value="motion"${mode === 'motion' ? ' selected' : ''}>Motion-triggered</option>
      </select>
    </div>

    <div class="srv-field-row">
      <label class="srv-field-label" for="srv-p-stream">Record stream</label>
      <select id="srv-p-stream" class="srv-select">
        <option value="main"${recStream === 'main' ? ' selected' : ''}>Main</option>
        <option value="sub"${recStream === 'sub'   ? ' selected' : ''}>Sub</option>
      </select>
    </div>

    <div class="srv-field-row">
      <label class="srv-field-label" for="srv-p-retention">Retention (hours)</label>
      <input id="srv-p-retention" class="srv-number" type="number" min="1" max="8760"
             value="${Number(retentionH)}" />
    </div>

    <div class="srv-field-row">
      <span class="srv-field-label">Record audio</span>
      <label class="srv-checkbox-wrap">
        <input id="srv-p-audio" class="srv-checkbox" type="checkbox"${recAudio ? ' checked' : ''} />
        Enable audio recording
      </label>
    </div>

    <!-- Motion detection — always relevant: drives the timeline motion lane and
         the live motion indicators regardless of recording mode. -->
    <div class="srv-field-row">
      <label class="srv-field-label" for="srv-p-sensitivity">Motion sensitivity</label>
      <select id="srv-p-sensitivity" class="srv-select">
        <option value="dynamic"${sensitivity === 'dynamic' ? ' selected' : ''}>Dynamic (auto)</option>
        <option value="manual"${sensitivity === 'manual'  ? ' selected' : ''}>Manual</option>
      </select>
    </div>
    <div id="srv-threshold-row" class="srv-field-row">
      <label class="srv-field-label" for="srv-p-threshold">Min object size (% of frame)</label>
      <input id="srv-p-threshold" class="srv-number" type="number" min="0.05" max="5" step="0.05"
             value="${thresholdPct}" />
    </div>
    <div class="srv-field-hint">
      Higher = less sensitive. Changes smaller than this % of the frame are ignored
      (filters out the timestamp overlay, sensor noise, etc.).
    </div>
    ${target.type === 'camera' ? `
    <div class="srv-field-row">
      <button id="srv-motion-tuner-btn" class="toolbar-btn toolbar-btn-setup" title="Live motion view + draw exclusion zones">Motion tuning…</button>
    </div>` : ''}

    <!-- Motion-recording-only fields (hidden when mode=continuous) -->
    <div id="srv-motion-fields">
      <div class="srv-field-row">
        <label class="srv-field-label" for="srv-p-pre">Pre-motion (sec)</label>
        <input id="srv-p-pre" class="srv-number" type="number" min="0" max="120"
               value="${Number(preS)}" />
      </div>
      <div class="srv-field-row">
        <label class="srv-field-label" for="srv-p-post">Post-motion (sec)</label>
        <input id="srv-p-post" class="srv-number" type="number" min="0" max="300"
               value="${Number(postS)}" />
      </div>
      <div class="srv-field-row">
        <span class="srv-field-label">Keyframes only</span>
        <label class="srv-checkbox-wrap">
          <input id="srv-p-kfonly" class="srv-checkbox" type="checkbox"${kfOnly ? ' checked' : ''} />
          Record keyframes only during motion
        </label>
      </div>
    </div>

    <div class="srv-save-row">
      <button id="srv-save-btn" class="srv-save-btn">Save</button>
    </div>
  `;

  // Wire conditional visibility. Only the motion-RECORDING fields (pre/post/
  // keyframes) are mode-gated; sensitivity + threshold are always shown because
  // motion detection runs regardless of recording mode (timeline + indicators).
  const modeEl         = document.getElementById('srv-p-mode');
  const motionFields   = document.getElementById('srv-motion-fields');

  function applyModeVisibility() {
    const isMotion = modeEl.value === 'motion';
    motionFields.style.display = isMotion ? '' : 'none';
  }

  applyModeVisibility();
  modeEl.addEventListener('change', applyModeVisibility);

  // Wire the Motion Tuner button (camera targets only). The tuner now lives
  // INLINE in the Motion-tuning section — jump there with this camera preselected
  // (srvEnterMotion auto-opens it; no separate "Open" click).
  const tunerBtn = document.getElementById('srv-motion-tuner-btn');
  if (tunerBtn) tunerBtn.addEventListener('click', () => {
    const camSel = document.getElementById('srv-tuner-cam');
    if (camSel) camSel.value = String(target.id);
    srvSelectSection('motion');
  });

  // Wire Save
  document.getElementById('srv-save-btn').addEventListener('click', srvHandleSave);

  // Start the live preview refresh for the selected camera (snapshot ~every 1.5s).
  if (previewCam) {
    srvStopPreview(); // J2: don't stack preview intervals across policy-target switches
    const img = document.getElementById('srv-cam-preview');
    const refresh = async () => {
      const base = await mtSnapshotUrl(previewCam); // scoped-token URL (pre-warmed by the cache)
      if (img && base) img.src = `${base}&t=${Date.now()}`;
    };
    refresh();
    srvState.previewTimer = setInterval(refresh, 1500);
  }
}

// ── Save policy ───────────────────────────────────────────────────────────────

async function srvHandleSave() {
  const saveBtn = document.getElementById('srv-save-btn');
  if (!saveBtn) return;
  saveBtn.disabled = true;

  const target = srvState.policyTarget;
  if (!target) { saveBtn.disabled = false; return; }

  // Collect form values
  const mode = document.getElementById('srv-p-mode')?.value;
  const body = {
    mode,
    record_audio:          document.getElementById('srv-p-audio')?.checked ?? false,
    record_stream:         document.getElementById('srv-p-stream')?.value,
    live_retention_hours:  Number(document.getElementById('srv-p-retention')?.value ?? 24),
  };

  // Include motion fields only when relevant (always send them — the API ignores irrelevant ones)
  body.motion_pre_seconds  = Number(document.getElementById('srv-p-pre')?.value   ?? 5);
  body.motion_post_seconds = Number(document.getElementById('srv-p-post')?.value  ?? 30);
  body.motion_sensitivity  = document.getElementById('srv-p-sensitivity')?.value  ?? 'dynamic';
  // Input is % of frame; persist as the canonical FRACTION (0..1). Recorder clamps 0.05%..5%.
  body.motion_threshold    = Number(document.getElementById('srv-p-threshold')?.value ?? 0.30) / 100;
  body.motion_keyframes_only = document.getElementById('srv-p-kfonly')?.checked   ?? false;

  // Determine endpoint
  const url = target.type === 'default'
    ? `${state.server}/config/policy/default`
    : `${state.server}/config/cameras/${encodeURIComponent(target.id)}/policy`;

  try {
    const res = await fetchWithTimeout(url, {
      method: 'PUT',
      headers: authHeaders(),
      body: JSON.stringify(body),
    });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (res.status === 403) {
      srvShowPolicyStatus('403 — insufficient permissions.', 'err');
      saveBtn.disabled = false;
      return;
    }
    if (!res.ok) {
      const text = await res.text().catch(() => res.statusText);
      throw new Error(`${res.status}: ${text}`);
    }
    // Re-fetch to confirm what was stored
    await srvSelectPolicyTarget(target);
    srvShowPolicyStatus('Policy saved.', 'ok');
    saveBtn.disabled = false; // re-enable so further edits can be saved
  } catch (e) {
    srvShowPolicyStatus(`Save failed: ${e.message}`, 'err');
    saveBtn.disabled = false;
  }
}

function srvShowPolicyStatus(msg, type) {
  const el = document.getElementById('srv-policy-status');
  if (!el) return;
  el.textContent = msg;
  el.className = `srv-policy-status ${type}`;
  // Auto-hide success after 4 s
  if (type === 'ok') {
    setTimeout(() => {
      if (el.textContent === msg) el.className = 'srv-policy-status hidden';
    }, 4000);
  }
}

// ── Motion Tuner (live per-cell motion heatmap + exclusion-box editor) ────────
// Shows a refreshing camera snapshot with a live motion heatmap (red = motion
// now, polled from GET /cameras/:id/motion-grid) and lets the operator drag/click
// grid cells to EXCLUDE areas. Excluded cells are saved as the camera's
// motion_mask (normalized rects) → the recorder ignores motion there.
const mtState = {
  cam: null,
  cols: 16,            // EXCLUSION authoring grid (user-adjustable)
  rows: 9,
  gridCols: 16,        // HEATMAP grid (fixed by the recorder's motion-grid)
  gridRows: 9,
  grid: [],            // latest per-cell intensities (0..100), row-major (gridCols×gridRows)
  excluded: new Set(), // "gx,gy" excluded cells (exclusion grid)
  drag: null,          // { ax, ay, cx, cy, erase } cell coords during a drag
  pollTimer: null,
  snapTimer: null,
  threshold: null,     // motion_threshold as a FRACTION of frame (0..1) — same unit as the score; ×100 = % for display
  sensitivity: 'dynamic',
  liveScore: null,     // recorder's live largest-blob score (0..1) — what it ACTUALLY triggers on
  liveThreshold: null, // recorder's live EFFECTIVE floor (0..1) — auto in dynamic, manual_blob_fraction in manual
};

const MT_MIN_COLS = 4, MT_MAX_COLS = 48, MT_MIN_ROWS = 3, MT_MAX_ROWS = 32;

function mtCellKey(gx, gy) { return `${gx},${gy}`; }

/** Build the go2rtc still-frame URL for a camera (host from the API server URL). */
async function mtSnapshotUrl(cam) {
  if (!cam || !cam.id) return ''; // no camera → gray backdrop, no bogus request
  // Use the API-PROXIED, authed still-frame endpoint (the same one the live tiles
  // use), NOT a direct go2rtc :1984 URL. go2rtc's API port is published host-local
  // only (127.0.0.1:11984), so a direct {host}:1984 URL is unreachable from a
  // remote desktop/phone — that was the black-backdrop bug. The proxy reaches
  // go2rtc server-side and handles the lazy cold-stream warm-up. `?token=` because
  // this loads via <img>/new Image() which can't set an Authorization header — so
  // it carries a short-lived per-camera scoped media token, not the full login JWT.
  return (await mediaUrlForCamera(cam.id, `/cameras/${encodeURIComponent(cam.id)}/frame.jpg`)) || '';
}

/** Build the LIVE MSE (fMP4) URL for a camera via the authed /live proxy. Plays in
 *  a webview <video> so the heatmap canvas can overlay it. Uses the sub-stream
 *  (lower bitrate, and the stream motion analysis runs on). `?token=` because a
 *  <video> element can't set an Authorization header — so it carries a short-lived
 *  per-camera scoped media token, not the full login JWT. */
async function mtLiveUrl(cam) {
  if (!cam || !cam.id) return '';
  return (await mediaUrlForCamera(cam.id, `/live/${encodeURIComponent(cam.id)}/stream.mp4?stream=sub`)) || '';
}

/** Echo the detector the recorder currently has loaded (the camera's saved
 *  motion_source/algorithm). Changing a picker persists immediately; the recorder
 *  respawns the worker and the green heatmap reflects the new detector within a few
 *  seconds. mtApplyMotionConfig refreshes mtState.cam + re-calls this on success. */
function mtUpdateLoadedDetector(cam) {
  const el = document.getElementById('mt-loaded-detector');
  if (!el) return;
  const src = (cam && cam.motion_source === 'frigate') ? 'frigate' : 'pixel';
  const algo = (cam && cam.motion_algorithm) || 'census';
  const label = src === 'frigate' ? 'Frigate detections' : `Pixel analysis · ${algo}`;
  el.textContent = `Recorder detector: ${label} — changes apply to the live heatmap within a few seconds.`;
}

/** Load the camera's existing motion_mask (normalized rects) → excluded cells. */
function mtLoadMaskToCells(cam) {
  mtState.excluded.clear();
  const mask = cam.motion_mask;
  if (!Array.isArray(mask)) return;
  // Only normalized [x,y,w,h] rects map to cells. Legacy polygons ([[x,y],…])
  // can't be edited here — warn so the operator knows saving will replace them.
  const rects = mask.filter(r => Array.isArray(r) && r.length >= 4 && typeof r[0] === 'number');
  const hasPolygon = mask.some(r => Array.isArray(r) && Array.isArray(r[0]));
  if (hasPolygon) {
    mtSetError('This camera has a legacy polygon mask that can’t be shown here — saving will replace it.');
  }
  mtRectsToCells(rects);
}

/** Populate mtState.excluded from normalized [x,y,w,h] rects at the current
 *  exclusion-grid resolution (a cell is excluded if its center is inside a rect). */
function mtRectsToCells(rects) {
  mtState.excluded.clear();
  for (let gy = 0; gy < mtState.rows; gy++) {
    for (let gx = 0; gx < mtState.cols; gx++) {
      const cxN = (gx + 0.5) / mtState.cols;
      const cyN = (gy + 0.5) / mtState.rows;
      for (const r of rects) {
        if (cxN >= r[0] && cxN < r[0] + r[2] && cyN >= r[1] && cyN < r[1] + r[3]) {
          mtState.excluded.add(mtCellKey(gx, gy));
          break;
        }
      }
    }
  }
}

/** Change the exclusion-grid resolution, preserving the painted area: convert
 *  current cells → normalized rects, then re-derive cells at the new resolution. */
function mtSetGridDims(cols, rows) {
  const c = Math.max(MT_MIN_COLS, Math.min(MT_MAX_COLS, cols));
  const r = Math.max(MT_MIN_ROWS, Math.min(MT_MAX_ROWS, rows));
  if (c === mtState.cols && r === mtState.rows) return;
  const rects = mtCellsToMask(); // area at the OLD resolution (normalized)
  mtState.cols = c; mtState.rows = r;
  mtRectsToCells(rects);         // re-paint that area at the NEW resolution
  const sel = document.getElementById('mt-grid-size'); if (sel) sel.value = `${c},${r}`;
  mtDrawGrid();
}

function mtSetError(msg) {
  const el = document.getElementById('mt-error');
  if (!el) return;
  el.textContent = msg || '';
  el.classList.toggle('hidden', !msg);
}

function mtOpen(cam) {
  mtState.cam = cam;
  mtState.grid = [];
  mtState.drag = null;
  mtState.liveScore = null;      // don't show the previous camera's live numbers
  mtState.liveThreshold = null;  // until this camera's first grid poll lands
  // Threshold = motion_threshold as a FRACTION of frame (0..1) + mode, for the meter marker.
  mtState.threshold = cam.policy?.motion_threshold ?? null;
  mtState.sensitivity = cam.policy?.motion_sensitivity ?? 'dynamic';
  // Restore the operator's chosen exclusion authoring grid for THIS camera
  // (persisted in cameras.motion_grid_cols/rows); default 16×9 when unset. The
  // heatmap stays at the recorder's fixed resolution (set by mtPoll).
  const VALID_GRIDS = ['8,5', '16,9', '24,14', '32,18', '48,27'];
  let gc = Number(cam.motion_grid_cols) || 16;
  let gr = Number(cam.motion_grid_rows) || 9;
  if (!VALID_GRIDS.includes(`${gc},${gr}`)) { gc = 16; gr = 9; }
  mtState.cols = gc;
  mtState.rows = gr;
  mtState.gridCols = gc;
  mtState.gridRows = gr;
  const sel = document.getElementById('mt-grid-size'); if (sel) sel.value = `${gc},${gr}`;
  mtLoadMaskToCells(cam);
  { const t = document.getElementById('mt-title'); if (t) t.textContent = cam.name; }
  mtSetError('');
  // Motion source + algorithm pickers reflect the camera's current config.
  const srcSel = document.getElementById('mt-motion-source');
  const algoSel = document.getElementById('mt-motion-algo');
  if (srcSel) srcSel.value = (cam.motion_source === 'frigate') ? 'frigate' : 'pixel';
  if (algoSel) algoSel.value = cam.motion_algorithm || 'census';
  mtSyncMotionSource();
  mtSyncThresholdControls();

  // LIVE video backdrop (MSE fMP4 via the authed /live proxy) so the operator tunes
  // against motion AS IT HAPPENS, with the green heatmap + zone grid overlaid. The
  // still <img> snapshot is a FALLBACK, shown only if the live stream can't start.
  // (The live wall uses native mpv panes, which float above the webview and can't be
  // overlaid — so the tuner uses an in-webview <video> the canvas can sit on top of.)
  const snap = document.getElementById('mt-snapshot');
  const video = document.getElementById('mt-video');
  const stage = document.getElementById('mt-stage');
  clearTimeout(mtState.snapTimer);
  clearInterval(mtState.snapTimer);
  mtState.snapTimer = null;
  clearTimeout(mtState.videoWatchdog);

  // Size the stage to the source's REAL aspect ratio so the feed fills it with no
  // letterbox (else the grid + heatmap paint over black bars — wrong coordinates).
  const sizeStage = (w, h) => {
    if (stage && w > 0 && h > 0) {
      stage.style.aspectRatio = `${w} / ${h}`;
      mtResizeCanvas();
      mtDrawGrid();
    }
  };
  // Still-frame fallback (bounded retry; shown only when live video fails).
  const showStill = async () => {
    const url = await mtSnapshotUrl(cam); // scoped-token URL, not the full JWT
    if (!url || !snap) return;
    let attempts = 0;
    const load = () => {
      const pre = new Image();
      pre.onload = () => { snap.src = pre.src; snap.style.display = 'block'; sizeStage(pre.naturalWidth, pre.naturalHeight); };
      pre.onerror = () => { if (attempts++ < 5) mtState.snapTimer = setTimeout(load, 600); };
      pre.src = `${url}&t=${Date.now()}`;
    };
    load();
  };

  if (video && cam && cam.id) {
    if (snap) snap.style.display = 'none';
    video.style.display = 'block';
    video.onloadedmetadata = () => sizeStage(video.videoWidth, video.videoHeight);
    video.onerror = () => { video.style.display = 'none'; showStill(); };
    // If the live stream produces no frame within ~6s, fall back to the still frame.
    mtState.videoWatchdog = setTimeout(() => {
      if (!video.videoWidth) { video.style.display = 'none'; showStill(); }
    }, 6000);
    // Resolve the scoped media token BEFORE setting the source so the <video>
    // never sees the full login JWT. Guard against the tuner switching cameras
    // while we await.
    mtLiveUrl(cam).then((src) => {
      if (!src || mtState.cam?.id !== cam.id) { if (!src) showStill(); return; }
      video.src = src;
      const pp = video.play?.(); if (pp && pp.catch) pp.catch(() => {});
    });
  } else if (snap) {
    snap.removeAttribute('src'); // no source → gray stage, no bogus request
  }
  mtUpdateLoadedDetector(cam);

  // INLINE panel (in Settings → Motion tuning). No modal/backdrop, and no
  // modalOpened()/pane-hide: the Settings tab already clears native video panes
  // (handle_tab clearAllPanes), so this DOM is never occluded.
  requestAnimationFrame(() => { mtResizeCanvas(); mtDrawGrid(); });
  clearInterval(mtState.pollTimer);
  mtPoll();
  mtState.pollTimer = setInterval(mtPoll, 400);
}

/* True when the inline tuner is the visible Settings section AND has a camera —
   gates the resize/redraw handlers (replaces the old mt-dialog visibility check). */
function mtInlineActive() {
  return !!(
    els.viewServer &&
    !els.viewServer.classList.contains('hidden') &&
    srvState.section === 'motion' &&
    mtState.cam
  );
}

/* Stop the inline tuner's polling (called when leaving the Motion section/tab).
   No modal to hide; just halt timers + drop drag state. */
function mtStop() {
  clearInterval(mtState.pollTimer); mtState.pollTimer = null;
  clearInterval(mtState.snapTimer); mtState.snapTimer = null;
  clearTimeout(mtState.videoWatchdog); mtState.videoWatchdog = null;
  // Stop the live MSE stream so it doesn't keep pulling go2rtc in the background.
  const v = document.getElementById('mt-video');
  if (v) { try { v.pause(); } catch {} v.removeAttribute('src'); try { v.load(); } catch {} }
  mtState.drag = null;
}

async function mtPoll() {
  if (!mtState.cam) return;
  try {
    const res = await fetchWithTimeout(`${state.server}/cameras/${mtState.cam.id}/motion-grid`, { headers: authHeaders() });
    if (!res.ok) return;
    const g = await res.json();
    if (g && Array.isArray(g.cells)) {
      const c = g.cols | 0, r = g.rows | 0;
      if (c <= 0 || r <= 0) return; // ignore malformed dims
      // Heatmap grid is the recorder's resolution; it's INDEPENDENT of the
      // user-set exclusion grid (mtState.cols/rows), so don't touch those.
      mtState.gridCols = c;
      mtState.gridRows = r;
      mtState.grid = g.cells;
      // The recorder publishes the SAME largest-blob score + effective floor it
      // triggers recording on. Use these for the meter — not a client recompute —
      // so the tuner shows the truth (esp. in Dynamic, where the floor is the live
      // auto-calibrated value, not the hidden default).
      if (typeof g.score === 'number') mtState.liveScore = g.score;
      if (typeof g.threshold === 'number') mtState.liveThreshold = g.threshold;
      mtDrawGrid();
      mtRenderMeter();
    }
  } catch { /* transient — ignore */ }
}

/**
 * Live motion meter (commercial-VMS-style). Shows the RECORDER'S OWN numbers — the
 * largest connected-blob fraction it scores each frame, and the effective floor
 * it triggers recording on — both as % of frame. This is the same quantity and
 * the same threshold the recorder uses, so "fill past the marker = recording
 * motion right now" is literally true. The fill = live score; the marker = the
 * floor that WILL apply (the slider's pending value in Manual, the recorder's
 * live auto-calibrated floor in Dynamic). Old code recomputed a mean-of-cells
 * (the pre-blob-redesign quantity) and showed a meaningless default threshold —
 * which is why Family Room read "below 25%" yet recorded motion constantly.
 */
function mtRenderMeter() {
  const fill = document.getElementById('mt-meter-fill');
  const mark = document.getElementById('mt-meter-mark');
  const txt = document.getElementById('mt-meter-text');
  if (!fill) return;

  // Recorder's live largest-blob score (% of frame). null until the first grid.
  const scorePct = (mtState.liveScore != null) ? mtState.liveScore * 100 : null;
  // Floor to SHOW (% of frame): Dynamic → the recorder's live auto floor; Manual →
  // the slider's pending value. motion_threshold and liveThreshold are BOTH
  // fractions (0..1) now — one unit — so it's a single ×100 either way.
  const floorPct = mtState.sensitivity === 'dynamic'
    ? (mtState.liveThreshold != null ? mtState.liveThreshold * 100 : null)
    : (mtState.threshold != null ? mtState.threshold * 100
       : (mtState.liveThreshold != null ? mtState.liveThreshold * 100 : null));

  if (scorePct == null || floorPct == null) {
    fill.style.width = '0%';
    if (mark) mark.style.display = 'none';
    if (txt) { txt.textContent = 'waiting for recorder…'; txt.style.color = 'var(--text-muted)'; }
    return;
  }

  // Scale so the floor marker sits at ~22% of the bar (stable while tuning) and
  // the live level fills relative to it; clamp at 100% when motion far exceeds it.
  const fullScale = Math.max(1.0, floorPct * 4.5);
  const over = scorePct >= floorPct;
  fill.style.width = `${Math.min(100, (scorePct / fullScale) * 100)}%`;
  fill.style.background = over ? 'var(--danger)' : 'var(--accent)';
  if (mark) {
    mark.style.display = 'block';
    mark.style.left = `${Math.min(100, (floorPct / fullScale) * 100)}%`;
  }
  if (txt) {
    const mode = mtState.sensitivity === 'dynamic' ? ' (auto)' : '';
    txt.textContent = `motion ${scorePct.toFixed(2)}%  ·  floor ${floorPct.toFixed(2)}%${mode}`;
    txt.style.color = over ? 'var(--danger)' : 'var(--text-muted)';
  }
}

/** Reflect mtState.threshold/sensitivity onto the slider + Auto checkbox. */
function mtSyncThresholdControls() {
  const slider = document.getElementById('mt-thresh-slider');
  const val = document.getElementById('mt-thresh-val');
  const auto = document.getElementById('mt-thresh-auto');
  if (!slider || !auto) return;
  const isAuto = mtState.sensitivity === 'dynamic';
  // motion_threshold is a FRACTION (0..1); edit it as % of frame (min object size).
  // Recorder clamps 0.05%..5%; default 0.30% (= blob floor) when unset.
  const pct = Math.max(0.05, Math.min(5, (mtState.threshold ?? 0.0030) * 100));
  slider.value = String(pct);
  slider.disabled = isAuto;
  auto.checked = isAuto;
  if (val) val.textContent = `${pct.toFixed(2)}%`;
}

/**
 * Persist the tuner's threshold + sensitivity to the camera's policy LIVE.
 * Adjusting the slider implies Manual mode (Dynamic ignores the threshold), so
 * the slider handler clears Auto; the Auto checkbox flips back to Dynamic.
 */
async function mtApplyThreshold() {
  if (!mtState.cam) return;
  const body = {
    motion_sensitivity: mtState.sensitivity,
    motion_threshold: mtState.threshold ?? 0.0030, // FRACTION of frame (default = blob floor)
  };
  try {
    const res = await fetchWithTimeout(`${state.server}/config/cameras/${mtState.cam.id}/policy`, {
      method: 'PUT', headers: authHeaders(), body: JSON.stringify(body),
    });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (!res.ok) throw new Error(`PUT policy → ${res.status}`);
    // Keep the local copy in sync so reopening the tuner shows the new values.
    if (mtState.cam.policy) {
      mtState.cam.policy.motion_threshold = body.motion_threshold;
      mtState.cam.policy.motion_sensitivity = body.motion_sensitivity;
    }
    setStatus(
      mtState.sensitivity === 'dynamic'
        ? 'Motion sensitivity set to Auto (dynamic)'
        : `Min object size set to ${(body.motion_threshold * 100).toFixed(2)}% of frame`,
    );
  } catch (e) {
    mtSetError(`Threshold save failed: ${e.message}`);
  }
}

function mtResizeCanvas() {
  const cv = document.getElementById('mt-canvas');
  const stage = document.getElementById('mt-stage');
  if (!cv || !stage) return;
  const r = stage.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1; // crisp on HiDPI (CSS stretches to 100%)
  cv.width = Math.max(1, Math.round(r.width * dpr));
  cv.height = Math.max(1, Math.round(r.height * dpr));
}

function mtDrawGrid() {
  const cv = document.getElementById('mt-canvas');
  if (!cv) return;
  const ctx = cv.getContext('2d');
  const W = cv.width, H = cv.height;
  ctx.clearRect(0, 0, W, H);

  // 1. Heatmap (recorder's grid resolution — independent of the exclusion grid).
  const gcols = mtState.gridCols, grows = mtState.gridRows;
  const hcw = W / gcols, hch = H / grows;
  for (let gy = 0; gy < grows; gy++) {
    for (let gx = 0; gx < gcols; gx++) {
      const intensity = mtState.grid[gy * gcols + gx] || 0;
      if (intensity > 0.5) {
        // Motion = GREEN, clearly visible even at low motion (min 0.5 alpha → full
        // at high motion).
        const a = Math.min(1, 0.5 + (intensity / 100) * 0.5);
        ctx.fillStyle = `rgba(40,210,90,${a})`;
        ctx.fillRect(gx * hcw, gy * hch, hcw, hch);
      }
    }
  }

  // 2. Exclusion cells (user authoring grid).
  const cols = mtState.cols, rows = mtState.rows;
  const cw = W / cols, ch = H / rows;
  for (let gy = 0; gy < rows; gy++) {
    for (let gx = 0; gx < cols; gx++) {
      if (mtState.excluded.has(mtCellKey(gx, gy))) {
        const x = gx * cw, y = gy * ch;
        // Excluded zones = RED.
        ctx.fillStyle = 'rgba(239,68,68,0.32)';
        ctx.fillRect(x, y, cw, ch);
        ctx.strokeStyle = 'rgba(239,68,68,0.8)';
        ctx.lineWidth = 1;
        ctx.beginPath(); ctx.moveTo(x, y + ch); ctx.lineTo(x + cw, y); ctx.stroke();
      }
    }
  }
  // Grid lines (exclusion grid).
  ctx.strokeStyle = 'rgba(255,255,255,0.12)';
  ctx.lineWidth = 1;
  for (let gx = 1; gx < cols; gx++) { ctx.beginPath(); ctx.moveTo(gx * cw, 0); ctx.lineTo(gx * cw, H); ctx.stroke(); }
  for (let gy = 1; gy < rows; gy++) { ctx.beginPath(); ctx.moveTo(0, gy * ch); ctx.lineTo(W, gy * ch); ctx.stroke(); }

  // Drag selection preview — white for add, red for erase (right-drag).
  if (mtState.drag) {
    const { ax, ay, cx, cy, erase } = mtState.drag;
    const x0 = Math.min(ax, cx) * cw, y0 = Math.min(ay, cy) * ch;
    const x1 = (Math.max(ax, cx) + 1) * cw, y1 = (Math.max(ay, cy) + 1) * ch;
    // Erase preview = amber (distinct from the red excluded cells); add = white.
    if (erase) { ctx.fillStyle = 'rgba(245,158,11,0.20)'; ctx.fillRect(x0, y0, x1 - x0, y1 - y0); }
    ctx.strokeStyle = erase ? 'rgba(245,158,11,0.95)' : 'rgba(255,255,255,0.9)';
    ctx.lineWidth = 2;
    ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
  }
}

function mtCellFromEvent(e) {
  const cv = document.getElementById('mt-canvas');
  const r = cv.getBoundingClientRect();
  const gx = Math.max(0, Math.min(mtState.cols - 1, Math.floor((e.clientX - r.left) / r.width * mtState.cols)));
  const gy = Math.max(0, Math.min(mtState.rows - 1, Math.floor((e.clientY - r.top) / r.height * mtState.rows)));
  return { gx, gy };
}

function mtPointerDown(e) {
  if (!mtInlineActive()) return;
  e.preventDefault();
  const { gx, gy } = mtCellFromEvent(e);
  // Right button (button 2) = ERASE drag (deselect); left = add exclusion.
  mtState.drag = { ax: gx, ay: gy, cx: gx, cy: gy, erase: e.button === 2 };
  mtDrawGrid();
}
function mtPointerMove(e) {
  if (!mtState.drag) return;
  const { gx, gy } = mtCellFromEvent(e);
  mtState.drag.cx = gx; mtState.drag.cy = gy;
  mtDrawGrid();
}
function mtPointerUp() {
  if (!mtState.drag) return;
  const { ax, ay, cx, cy, erase } = mtState.drag;
  mtState.drag = null;
  const x0 = Math.min(ax, cx), x1 = Math.max(ax, cx), y0 = Math.min(ay, cy), y1 = Math.max(ay, cy);
  if (x0 === x1 && y0 === y1) {
    // Single cell: a right-click erases; a left-click toggles.
    const k = mtCellKey(x0, y0);
    if (erase) mtState.excluded.delete(k);
    else if (mtState.excluded.has(k)) mtState.excluded.delete(k); else mtState.excluded.add(k);
  } else {
    // Region: right-drag erases the whole box, left-drag excludes it.
    for (let gy = y0; gy <= y1; gy++) for (let gx = x0; gx <= x1; gx++) {
      const k = mtCellKey(gx, gy);
      if (erase) mtState.excluded.delete(k); else mtState.excluded.add(k);
    }
  }
  mtDrawGrid();
}

/** Excluded cells → normalized rects (merged into per-row runs). */
function mtCellsToMask() {
  const rects = [];
  for (let gy = 0; gy < mtState.rows; gy++) {
    let runStart = -1;
    for (let gx = 0; gx <= mtState.cols; gx++) {
      const on = gx < mtState.cols && mtState.excluded.has(mtCellKey(gx, gy));
      if (on && runStart < 0) {
        runStart = gx;
      } else if (!on && runStart >= 0) {
        const w = gx - runStart;
        rects.push([runStart / mtState.cols, gy / mtState.rows, w / mtState.cols, 1 / mtState.rows]);
        runStart = -1;
      }
    }
  }
  return rects;
}

async function mtSave() {
  if (!mtState.cam) return;
  const mask = mtCellsToMask();
  try {
    const res = await fetchWithTimeout(`${state.server}/config/cameras/${mtState.cam.id}`, {
      method: 'PUT',
      headers: authHeaders(),
      body: JSON.stringify({ motion_mask: mask }),
    });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (!res.ok) throw new Error(`PUT /config/cameras → ${res.status}`);
    const updated = await res.json().catch(() => null);
    if (updated) {
      const idx = (srvState.allCameras || []).findIndex(c => c.id === mtState.cam.id);
      if (idx >= 0) srvState.allCameras[idx] = updated;
    }
    setStatus(`Motion mask saved (${mask.length} zone${mask.length !== 1 ? 's' : ''})`);
    // Inline tuner: stay put after saving (no modal to close) so the operator
    // can keep tuning; the mask is now persisted + the cache is updated.
  } catch (e) {
    mtSetError(`Save failed: ${e.message}`);
  }
}

// Per-algorithm one-liner shown beside the picker.
const MT_ALGO_NOTES = {
  census: 'illumination-invariant (default)',
  framediff: 'most sensitive; trips on lighting',
  mog2: 'multimodal background (trees/signs)',
  opticalflow: 'true movement only',
  ensemble: 'Census + MOG2 (most robust, ~2–3× CPU)',
};

/** Enable/disable the pixel controls based on the selected motion source, and
 *  show the per-algorithm note. When the source is Frigate the pixel detector,
 *  threshold and exclusion grid are all "managed by Frigate" and disabled. */
function mtSyncMotionSource() {
  const src = (document.getElementById('mt-motion-source')?.value) || 'pixel';
  const algoSel = document.getElementById('mt-motion-algo');
  const note = document.getElementById('mt-motion-algo-note');
  const frigate = src === 'frigate';
  if (algoSel) algoSel.disabled = frigate;
  // Disable the pixel-only controls when Frigate drives motion.
  for (const id of ['mt-thresh-slider', 'mt-thresh-auto', 'mt-grid-size', 'mt-save-btn', 'mt-clear-btn']) {
    const el = document.getElementById(id);
    if (el) el.disabled = frigate;
  }
  if (note) {
    note.textContent = frigate
      ? 'recording is triggered by Frigate detections'
      : (MT_ALGO_NOTES[algoSel?.value] || '');
  }
}

/** Persist the motion source + algorithm to the camera. */
/** Persist the operator's chosen authoring grid size for this camera (UI pref). */
async function mtPersistGrid(cols, rows) {
  if (!mtState.cam) return;
  try {
    const res = await fetchWithTimeout(`${state.server}/config/cameras/${mtState.cam.id}`, {
      method: 'PUT',
      headers: authHeaders(),
      body: JSON.stringify({ motion_grid_cols: cols, motion_grid_rows: rows }),
    });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (!res.ok) return; // non-fatal: grid still applies this session
    const updated = await res.json().catch(() => null);
    if (updated) {
      mtState.cam = updated;
      const idx = (srvState.allCameras || []).findIndex(c => c.id === updated.id);
      if (idx >= 0) srvState.allCameras[idx] = updated;
    }
  } catch { /* non-fatal */ }
}

async function mtApplyMotionConfig() {
  if (!mtState.cam) return;
  const motion_source = document.getElementById('mt-motion-source')?.value || 'pixel';
  const motion_algorithm = document.getElementById('mt-motion-algo')?.value || 'census';
  try {
    const res = await fetchWithTimeout(`${state.server}/config/cameras/${mtState.cam.id}`, {
      method: 'PUT',
      headers: authHeaders(),
      body: JSON.stringify({ motion_source, motion_algorithm }),
    });
    if (res.status === 401) { handleUnauthorized(); return; }
    if (!res.ok) throw new Error(`PUT /config/cameras → ${res.status}`);
    const updated = await res.json().catch(() => null);
    if (updated) {
      mtState.cam = updated;
      const idx = (srvState.allCameras || []).findIndex(c => c.id === updated.id);
      if (idx >= 0) srvState.allCameras[idx] = updated;
    }
    mtUpdateLoadedDetector(mtState.cam); // reflect the now-saved detector
    setStatus(motion_source === 'frigate'
      ? 'Motion source set to Frigate detections'
      : `Motion algorithm set to ${motion_algorithm}`);
  } catch (e) {
    mtSetError(`Save failed: ${e.message}`);
  }
}
