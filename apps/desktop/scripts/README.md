# Desktop verification harness (review A4)

The desktop frontend is baked into the `.exe` at compile time, so a **rebuild +
relaunch is required for any `src/` change to take effect**, a running/old exe
shows stale UI. These scripts make the standard post-change smoke flow repeatable
and checked-in (it previously lived only in session notes).

## Flow

1. **Rebuild** after editing `src/`:
   ```sh
   # in the build dir
   cargo build --manifest-path src-tauri/Cargo.toml
   ```
2. **Launch with the CDP debug port** (kill any running instance first, it locks
   the exe and serves stale UI):
   ```powershell
   $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=9223'
   Start-Process 'src-tauri\target\debug\crumb-desktop.exe'
   ```
3. **Assert invariants** with `cdp-eval.ps1` (evaluates JS in the page over CDP,
   returns the result):
   ```powershell
   ./scripts/cdp-eval.ps1 -Expr "document.querySelectorAll('#tile-grid .tile').length"
   ```
4. **Screenshot** with `cdp-shot.ps1`:
   ```powershell
   ./scripts/cdp-shot.ps1 -Out verify.png
   ```

## Important caveats

- **`app.js` is an ES module**, its top-level functions/consts are NOT on
  `window`. Assert via the **DOM** (`querySelector`, `classList`, element text)
  or drive UI by dispatching events, not by calling module-scope functions.
- **Native panes are libmpv windows owned by the Rust side**, not DOM/canvas.
  WebView2 can't reliably rasterize them here, so verify pane state via the Tauri
  IPC (`window.__TAURI__.core.invoke('pane_stats')`) rather than screenshot
  pixels.
- Mechanical reference checking (typos, renamed globals) is covered separately by
  the ESLint `no-undef` CI job (`npm run lint`); these scripts are for behavioural
  smoke-testing that needs the running app + a logged-in session.
