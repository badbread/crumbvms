// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import android.content.res.Configuration
import android.graphics.drawable.BitmapDrawable
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.imageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import video.crumb.app.data.CameraDto
import video.crumb.app.data.RecordedSpan
import video.crumb.app.data.toUserMessage
import video.crumb.app.di.appContainer
import video.crumb.app.ui.CrumbMode
import video.crumb.app.ui.CrumbModeTabs
import video.crumb.app.ui.GridLayoutToggle
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.InlineDivider
import video.crumb.app.ui.JumpToDateTimeDialog
import video.crumb.app.ui.Time
import video.crumb.app.ui.ViewChipsRow
import video.crumb.app.ui.WallGridLayout
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextSecondary
import java.time.Instant
import kotlin.math.abs

// ─── tuning ────────────────────────────────────────────────────────────────────

/** Initial loaded data window (hours, ending now). Wide enough to scrub a couple of
 *  shifts back without an immediate reload. */
private const val WALL_WINDOW_HOURS = 12L

/** Half-window used when recentering on a jump / scrub-to-edge (total = 2×). */
private const val WALL_RECENTER_HALF_MS = 6L * 3600_000L

/** Default visible (zoom) span of the shared timeline. */
private const val WALL_DEFAULT_SPAN_MS = 60L * 60_000L
private const val WALL_MIN_SPAN_MS = 60_000L
private const val WALL_MAX_SPAN_MS = WALL_WINDOW_HOURS * 3600_000L

// ─── screen ──────────────────────────────────────────────────────────────────

/**
 * Multi-camera **playback wall** — the standalone Playback landing.
 *
 * Instead of dropping the operator straight into one camera's footage, this shows
 * a grid of every enabled camera as a **frozen snapshot** captured on entry (the
 * go2rtc `frame.jpeg` still, the same source the motion tuner uses) — a static
 * reference image, NOT a live-refreshing feed — with **shared playback controls**
 * pinned at the bottom: a scrubbable coverage timeline, a "Latest" reset, and a
 * jump-to-date/time button.
 *
 * The bottom controls drive a single shared **cursor** time. Scrubbing the shared
 * timeline sets a preview time and every tile swaps to its RECORDED frame nearest
 * that moment (fetched from the filmstrip), so the whole wall tracks the scrub; a
 * tile shows "No footage" when no recording covers that instant for that camera.
 * Tapping a tile opens that camera in single-camera [PlaybackScreen] seeded at the
 * cursor, or at its latest footage when the wall is at "Latest".
 *
 * @param onOpenLive Switches to the Live tab (anchored so it never lands on
 *   another tab that happens to be under Playback on the back stack).
 * @param onOpenPlayback Called with `(cameraId, startMs)`; `startMs ≤ 0` means
 *   "open at the camera's latest footage".
 * @param onOpenExport Opens the Export screen (export lives under Playback).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaybackWallScreen(
    onOpenLive: () -> Unit,
    onOpenPlayback: (String, Long) -> Unit,
    onOpenBookmarks: () -> Unit,
    onOpenExport: () -> Unit,
    onOpenClips: () -> Unit = {},
    onOpenPlates: () -> Unit = {},
) {
    val container = appContainer()
    val repo = container.repository
    val store = container.store
    val caps = store.capabilities
    val scope = rememberCoroutineScope()
    // In landscape the phone is short; compact the bottom transport so it doesn't
    // eat a big slice of the (already short) height — mirrors PlaybackScreen.
    val isLandscape =
        LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    // Portrait can't usefully show 4 tiles across (each gets too tiny) — cap it at 3.
    val maxCols = if (isLandscape) 4 else 3

    var cameras by remember { mutableStateOf<List<CameraDto>>(emptyList()) }
    // Saved views (server-backed, per-user — same /views the Live wall uses; the
    // SecureStore cache renders instantly and the selection is shared across tabs).
    // Reconcile with the server on entry, preserving the client-side view order.
    var views by remember { mutableStateOf(store.cameraViews) }
    LaunchedEffect(Unit) {
        repo.listViews().onSuccess { server ->
            val pos = store.cameraViews.mapIndexed { i, v -> v.id to i }.toMap()
            val ordered = server.sortedBy { pos[it.id] ?: Int.MAX_VALUE }
            store.cameraViews = ordered
            views = ordered
        }
    }
    var activeViewId by remember { mutableStateOf(store.activeViewId) }
    // Client-side preference: hide the auto-built "All Cameras" default view (desktop
    // parity — `client_options.dart`'s `showAllCamerasView`), shared with the Live
    // wall's setting (see SettingsDialog, reachable from the Live tab's overflow menu).
    var showAllCamerasView by remember { mutableStateOf(store.showAllCamerasView) }
    var spans by remember { mutableStateOf<List<RecordedSpan>>(emptyList()) }
    // Combined motion histogram across ALL wall cameras (per-bucket max), so the
    // shared timeline shows WHERE there was movement on the busiest camera — quiet
    // only when every camera is quiet. Covers [windowStartMs, windowEndMs].
    var motionBuckets by remember { mutableStateOf<List<Float>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    var windowStartMs by remember { mutableLongStateOf(0L) }
    var windowEndMs by remember { mutableLongStateOf(0L) }
    var cursorMs by remember { mutableLongStateOf(0L) }
    var atLatest by remember { mutableStateOf(true) }
    // Seed the timeline zoom from the persisted device preference (shared with
    // single-camera playback) so it restores the last span the user left it on
    // instead of resetting to the 1 h default. Coerced into the wall's own range.
    var visibleSpanMs by remember {
        mutableLongStateOf(store.playbackSpanMs.coerceIn(WALL_MIN_SPAN_MS, WALL_MAX_SPAN_MS))
    }
    var layout by remember {
        mutableStateOf(WallGridLayout.entries.getOrElse(store.liveGridLayout) { WallGridLayout.TWO })
    }
    var showJump by remember { mutableStateOf(false) }
    // Time the tiles preview: null = "Latest" (live frozen frame); a value = show
    // each camera's RECORDED frame nearest that moment (via the filmstrip). Set on
    // scrub + jump so scrubbing the shared timeline updates every tile's snapshot.
    var previewMs by remember { mutableStateOf<Long?>(null) }

    // Load the timeline spans for ALL wall cameras across [startMs, endMs]. Snaps the
    // cursor to the latest footage when [snapLatest] (initial load / "Latest").
    fun loadSpans(startMs: Long, endMs: Long, snapLatest: Boolean) {
        // Restrict the timeline to the active view's cameras (or all when "All").
        val view = views.firstOrNull { it.id == activeViewId }
        val src = view?.let { v ->
            val byId = cameras.associateBy { it.id }
            v.cameraIds.mapNotNull { byId[it] }
        } ?: cameras
        val ids = src.map { it.id }
        if (ids.isEmpty()) return
        val startIso = Time.iso(Instant.ofEpochMilli(startMs))
        val endIso = Time.iso(Instant.ofEpochMilli(endMs))
        scope.launch {
            repo.timeline(
                cameraIds = ids,
                startIso = startIso,
                endIso = endIso,
            ).onSuccess { sp ->
                spans = sp
                if (snapLatest) {
                    val latest = sp.maxOfOrNull { Time.parseToMillis(it.end) }
                    cursorMs = latest?.let { (it - 1500L).coerceAtLeast(startMs) } ?: endMs
                    atLatest = true
                }
            }
        }
        // Combined motion overlay across all wall cameras (parallel; non-fatal).
        // ~1-min buckets over the 12h window so movement is visible at typical zoom.
        scope.launch {
            repo.timelineIntensityCombined(
                cameraIds = ids,
                startIso = startIso,
                endIso = endIso,
                buckets = 720,
            ).onSuccess { motionBuckets = it }
        }
    }

    // Initial load: cameras, then a wide window of coverage.
    LaunchedEffect(Unit) {
        val now = Instant.now().toEpochMilli()
        windowStartMs = now - WALL_WINDOW_HOURS * 3600_000L
        windowEndMs = now
        cursorMs = now
        repo.visibleCameras()
            .onSuccess { list ->
                cameras = list.filter { it.enabled }
                loading = false
                loadSpans(windowStartMs, windowEndMs, snapLatest = true)
            }
            .onFailure {
                loading = false
                error = it.toUserMessage()
            }
    }

    // Recenter the data window on [centerMs] and reload (jump-to-time / scrub-to-edge).
    fun recenterOn(centerMs: Long) {
        val now = Instant.now().toEpochMilli()
        val ws = (centerMs - WALL_RECENTER_HALF_MS).coerceAtLeast(0L)
        val we = (centerMs + WALL_RECENTER_HALF_MS).coerceAtMost(now)
        windowStartMs = ws
        windowEndMs = we
        loadSpans(ws, we, snapLatest = false)
    }

    fun goLatest() {
        val now = Instant.now().toEpochMilli()
        windowStartMs = now - WALL_WINDOW_HOURS * 3600_000L
        windowEndMs = now
        previewMs = null
        loadSpans(windowStartMs, windowEndMs, snapLatest = true)
    }

    // Switch the active saved view (persisted, shared with the Live wall) and reload
    // the timeline for the new camera set, keeping the current window/cursor.
    fun setActive(id: String?) {
        activeViewId = id
        store.activeViewId = id
        if (cameras.isNotEmpty()) loadSpans(windowStartMs, windowEndMs, snapLatest = atLatest)
    }

    val activeView = views.firstOrNull { it.id == activeViewId }
    // See LiveScreen for the full rationale — same suppress-and-auto-adopt behavior,
    // shared with the Live wall via the same persisted activeViewId/views/preference.
    val suppressingAllCameras = !showAllCamerasView && activeView == null
    val shownCameras = when {
        activeView != null -> {
            val byId = cameras.associateBy { it.id }
            activeView.cameraIds.mapNotNull { byId[it] }
        }
        suppressingAllCameras -> emptyList()
        else -> cameras
    }
    LaunchedEffect(showAllCamerasView, views, activeViewId) {
        if (suppressingAllCameras && views.isNotEmpty()) {
            setActive(views.first().id)
        }
    }

    Scaffold(
        containerColor = NavyDeep,
        topBar = {
            TopAppBar(
                // Same Live | Playback tabs as the Live wall (Playback underlined), with
                // the saved-view chips inline to their right (separated by a rule;
                // overflow scrolls sideways). Tapping "Live" returns to the Live wall.
                title = {
                    // Landscape: view chips inline next to the tabs. Portrait: tabs only
                    // (chips are a separate strip below).
                    if (isLandscape && views.isNotEmpty()) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            CrumbModeTabs(
                                selected = CrumbMode.PLAYBACK,
                                onLive = onOpenLive,
                                onPlayback = {},
                                onClips = onOpenClips,
                                onPlates = onOpenPlates,
                                showPlayback = caps.playback || store.isAdmin,
                                showClips = caps.clips || store.isAdmin,
                                showPlates = store.platesEnabled,
                            )
                            InlineDivider()
                            ViewChipsRow(
                                views = views,
                                activeViewId = activeViewId,
                                onSelect = { setActive(it) },
                                modifier = Modifier.weight(1f),
                                showAllCamerasView = showAllCamerasView,
                            )
                        }
                    } else {
                        CrumbModeTabs(
                            selected = CrumbMode.PLAYBACK,
                            onLive = onOpenLive,
                            onPlayback = {},
                            onClips = onOpenClips,
                            onPlates = onOpenPlates,
                            showPlayback = caps.playback || store.isAdmin,
                            showClips = caps.clips || store.isAdmin,
                            showPlates = store.platesEnabled,
                        )
                    }
                },
                actions = {
                    // Grid-density picker FIRST — same control, icons, and position as
                    // the Live wall (and the same persisted value).
                    GridLayoutToggle(layout, maxCols) { next ->
                        layout = next
                        store.liveGridLayout = next.ordinal
                    }
                    if (caps.bookmarks != "none" || store.isAdmin) {
                        HintTooltip("View bookmarks") {
                            IconButton(onClick = onOpenBookmarks) {
                                Icon(Icons.Default.Bookmarks, contentDescription = "Bookmarks")
                            }
                        }
                    }
                    if (caps.export || store.isAdmin) {
                        HintTooltip("Export footage") {
                            IconButton(onClick = onOpenExport) {
                                Icon(Icons.Default.Share, contentDescription = "Export footage")
                            }
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NavyDeep,
                    titleContentColor = MaterialTheme.colorScheme.onSurface,
                    actionIconContentColor = MaterialTheme.colorScheme.onSurface,
                    navigationIconContentColor = MaterialTheme.colorScheme.onSurface,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            // Saved-view chips strip (PORTRAIT only; landscape shows them inline in the
            // title). Same views as the Live wall; selection shared via SecureStore.
            if (!isLandscape && views.isNotEmpty()) {
                ViewChipsRow(
                    views = views,
                    activeViewId = activeViewId,
                    onSelect = { setActive(it) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 2.dp),
                    showAllCamerasView = showAllCamerasView,
                )
            }
            // ── Snapshot grid (fills space above the controls) ───────────────────
            Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                when {
                    loading -> CircularProgressIndicator(
                        modifier = Modifier.align(Alignment.Center),
                        color = TealAccent,
                    )

                    error != null -> Column(
                        modifier = Modifier.align(Alignment.Center).padding(32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(error!!, color = MaterialTheme.colorScheme.error)
                        TextButton(onClick = {
                            error = null
                            loading = true
                            scope.launch {
                                repo.visibleCameras().onSuccess {
                                    cameras = it.filter { c -> c.enabled }
                                    loading = false
                                    goLatest()
                                }.onFailure { e -> loading = false; error = e.toUserMessage() }
                            }
                        }) { Text("Retry", color = TealAccent) }
                    }

                    shownCameras.isEmpty() -> Text(
                        text = if (suppressingAllCameras) {
                            "No saved views — create one on the Live tab, or turn " +
                                "\"Show All Cameras\" back on in Settings."
                        } else {
                            "No cameras available"
                        },
                        color = TextSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .align(Alignment.Center)
                            .padding(horizontal = 24.dp),
                    )

                    else -> LazyVerticalGrid(
                        columns = GridCells.Fixed(minOf(layout.cols, maxCols)),
                        contentPadding = PaddingValues(8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(shownCameras, key = { it.id }) { cam ->
                            WallSnapshotTile(
                                camera = cam,
                                previewMs = previewMs,
                                onClick = { onOpenPlayback(cam.id, if (atLatest) 0L else cursorMs) },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .aspectRatio(16f / 9f),
                            )
                        }
                    }
                }
            }

            // ── Shared playback controls (the "multi-window" transport) ──────────
            Column(modifier = Modifier.fillMaxWidth().background(NavySurface)) {
                Row(
                    modifier = Modifier.fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = if (isLandscape) 0.dp else 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    FilledTonalButton(
                        onClick = { goLatest() },
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                        colors = ButtonDefaults.filledTonalButtonColors(
                            containerColor = if (atLatest) TealAccent.copy(alpha = 0.25f)
                                else MaterialTheme.colorScheme.surfaceVariant,
                        ),
                    ) {
                        Text("Latest", fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                    }
                    Text(
                        text = "Tap a camera for full playback control",
                        style = MaterialTheme.typography.labelSmall,
                        color = TextSecondary,
                        modifier = Modifier.weight(1f).padding(horizontal = 10.dp),
                    )
                    HintTooltip("Jump to date & time") {
                        IconButton(
                            onClick = { showJump = true },
                            modifier = Modifier.size(if (isLandscape) 36.dp else 48.dp),
                        ) {
                            Icon(Icons.Default.Schedule, contentDescription = "Jump to date & time")
                        }
                    }
                }
                CenteredTimeline(
                    spans = spans,
                    motionBuckets = motionBuckets,
                    motionStartMs = windowStartMs,
                    motionEndMs = windowEndMs,
                    // Detection icons intentionally omitted on the wall (per-camera;
                    // they'd clutter a shared all-camera timeline). Single-camera
                    // playback still shows them.
                    bookmarks = emptyList(),
                    playheadMs = cursorMs,
                    spanMs = visibleSpanMs,
                    minSpanMs = WALL_MIN_SPAN_MS,
                    maxSpanMs = WALL_MAX_SPAN_MS,
                    onScrubStart = {},
                    onScrub = { ts -> cursorMs = ts; atLatest = false; previewMs = ts },
                    onScrubEnd = { ts ->
                        cursorMs = ts
                        atLatest = false
                        previewMs = ts
                        // Recenter the loaded window if the cursor neared an edge, so
                        // there are always spans to scrub into on both sides.
                        val margin = 30L * 60_000L
                        if (ts < windowStartMs + margin || ts > windowEndMs - margin) recenterOn(ts)
                    },
                    onSpanChange = { sp ->
                        val coerced = sp.coerceIn(WALL_MIN_SPAN_MS, WALL_MAX_SPAN_MS)
                        if (coerced != visibleSpanMs) {
                            visibleSpanMs = coerced
                            // Persist as a device preference (shared with single-camera
                            // playback) so the zoom level survives tab switches + restarts.
                            store.playbackSpanMs = coerced
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(if (isLandscape) 40.dp else 64.dp)
                        .padding(horizontal = 8.dp),
                )
            }
        }
    }

    if (showJump) {
        JumpToDateTimeDialog(
            initialMs = if (cursorMs > 0L) cursorMs else Instant.now().toEpochMilli(),
            onDismiss = { showJump = false },
            onPicked = { target ->
                showJump = false
                cursorMs = target
                atLatest = false
                previewMs = target
                recenterOn(target)
            },
        )
    }
}

// ─── snapshot tile ─────────────────────────────────────────────────────────────

/**
 * One camera's tile. Two modes, driven by [previewMs]:
 *  - **Latest** ([previewMs] == null): a single frozen go2rtc still (the live
 *    current frame), captured once with a short retry so a first-fetch miss doesn't
 *    leave the tile blank.
 *  - **Scrubbed** ([previewMs] set): the camera's RECORDED frame nearest that moment,
 *    fetched from the filmstrip — so scrubbing the shared timeline updates every
 *    tile's snapshot to the period scrubbed to.
 *
 * The fetch is debounced and the current image is held until the next one loads, so
 * a continuous drag neither storms the server nor flashes the tiles to a spinner.
 * "No footage" shows when a camera has no recording at the scrubbed time.
 */
@Composable
private fun WallSnapshotTile(
    camera: CameraDto,
    previewMs: Long?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val repo = appContainer().repository
    // Reset only when the CAMERA changes (not on every scrub tick) so scrubbing
    // swaps frames in place without flashing back to a spinner.
    var frame by remember(camera.id) { mutableStateOf<ImageBitmap?>(null) }
    var noFootage by remember(camera.id) { mutableStateOf(false) }

    LaunchedEffect(camera.id, previewMs) {
        if (previewMs == null) {
            // "Latest" → live frozen still; retry on a transient first-fetch miss.
            noFootage = false
            val liveFrameUrl = runCatching { repo.mediaUrls().cameraFrameUrl(camera.id) }.getOrNull()
            if (liveFrameUrl.isNullOrEmpty()) return@LaunchedEffect
            val loader = context.imageLoader
            var attempt = 0
            var got = false
            while (!got && attempt < 5) {
                val req = ImageRequest.Builder(context)
                    .data(if (attempt == 0) liveFrameUrl else "$liveFrameUrl&cb=$attempt")
                    .memoryCachePolicy(CachePolicy.DISABLED)
                    .diskCachePolicy(CachePolicy.DISABLED)
                    .allowHardware(false)
                    .build()
                val result = loader.execute(req)
                if (result is SuccessResult) {
                    (result.drawable as? BitmapDrawable)?.bitmap?.let {
                        frame = it.asImageBitmap(); got = true
                    }
                }
                attempt++
                if (!got) delay(1500L)
            }
        } else {
            // Scrubbed → recorded frame nearest previewMs (via the filmstrip).
            // Debounce; keep the current image until the replacement loads.
            delay(300L)
            val halfMs = 4_000L
            repo.filmstrip(
                cameraId = camera.id,
                startIso = Time.iso(Instant.ofEpochMilli((previewMs - halfMs).coerceAtLeast(0L))),
                endIso = Time.iso(Instant.ofEpochMilli(previewMs + halfMs)),
                width = 320,
            ).onSuccess { frames ->
                val nearest = frames.minByOrNull { abs(Time.parseToMillis(it.ts) - previewMs) }
                val scoped = nearest?.let {
                    runCatching { repo.mediaUrls().scopedUrl(camera.id, it.url) }.getOrNull()
                }
                val bmp = if (scoped == null) {
                    null
                } else {
                    val req = ImageRequest.Builder(context)
                        .data(scoped)
                        .allowHardware(false)
                        .build()
                    (context.imageLoader.execute(req) as? SuccessResult)
                        ?.let { it.drawable as? BitmapDrawable }
                        ?.bitmap
                }
                if (bmp != null) {
                    frame = bmp.asImageBitmap()
                    noFootage = false
                } else {
                    // No thumbnail available at this instant (the frame request
                    // 404s when no recorded segment covers previewMs), or the
                    // image fetch failed. Surface it instead of silently holding
                    // the stale "Latest" frame — that silent-hold was the bug.
                    frame = null
                    noFootage = true
                }
            }.onFailure {
                // The filmstrip LIST request itself failed; don't leave the tile
                // frozen on its old frame with no feedback.
                frame = null
                noFootage = true
            }
        }
    }

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .background(Color.Black)
            .clickable { onClick() },
    ) {
        val f = frame
        when {
            f != null -> Image(
                bitmap = f,
                contentDescription = camera.name,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )

            noFootage -> Text(
                text = "No footage",
                color = TextSecondary,
                fontSize = 11.sp,
                modifier = Modifier.align(Alignment.Center),
            )

            else -> CircularProgressIndicator(
                modifier = Modifier.align(Alignment.Center).size(22.dp),
                color = TealAccent,
                strokeWidth = 2.dp,
            )
        }
        Text(
            text = camera.name,
            color = Color.White,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(6.dp)
                .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(4.dp))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}
