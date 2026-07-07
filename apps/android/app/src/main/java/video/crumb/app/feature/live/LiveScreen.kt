// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import android.content.res.Configuration
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.SignalWifiStatusbarConnectedNoInternet4
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import android.widget.Toast
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import video.crumb.app.data.toUserMessage
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import video.crumb.app.data.CameraView
import video.crumb.app.di.appContainer
import video.crumb.app.feature.about.AboutDialog
import video.crumb.app.feature.settings.SettingsDialog
import video.crumb.app.ui.CrumbMode
import video.crumb.app.ui.CrumbModeTabs
import video.crumb.app.ui.GridLayoutToggle
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.ImmersiveMode
import video.crumb.app.ui.InlineDivider
import video.crumb.app.ui.KeepScreenOn
import video.crumb.app.ui.ViewChipsRow
import video.crumb.app.ui.WallGridLayout
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.TextSecondary
import video.crumb.app.ui.theme.TealAccent

// ─── screen ──────────────────────────────────────────────────────────────────

/**
 * Live camera wall.
 *
 * Renders all enabled cameras in a configurable grid, with per-tile quick
 * access to fullscreen and playback. The layout can be toggled between a
 * single-column view and a 2x2 grid.
 *
 * @param onOpenFullscreen Called when the user taps a tile; navigates to the
 *   full-screen single-camera live view for the given camera id.
 * @param onOpenPlaybackMode Called when the user enters the standalone Playback
 *   mode (the Playback tab); navigates to Playback with no seed camera.
 * @param onLogout Called when the user selects Logout from the overflow menu.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveScreen(
    onOpenFullscreen: (String) -> Unit,
    onOpenPlaybackMode: () -> Unit,
    onOpenClips: () -> Unit = {},
    onLogout: () -> Unit,
) {
    val container = appContainer()
    val vm: LiveViewModel = viewModel(
        factory = viewModelFactory {
            initializer { LiveViewModel(container.repository, container.store) }
        },
    )
    val state by vm.uiState.collectAsStateWithLifecycle()
    val store = container.store
    val caps = store.capabilities
    // Built once (server URL + token are stable for the session). Used to derive the
    // per-tile still-frame URL for the instant-feel snapshot placeholder.
    val mediaUrls = remember { container.mediaUrls() }

    // Seed from the persisted layout (SecureStore is the source of truth) so the
    // chosen layout survives navigating into a camera and back — and app restarts.
    // A plain remember reset to 2x2 every time the screen recomposed on return.
    // Stale ordinal 2 (old LIST) falls back to TWO_BY_TWO safely via getOrElse.
    var layout by remember {
        mutableStateOf(WallGridLayout.entries.getOrElse(store.liveGridLayout) { WallGridLayout.TWO })
    }
    var overflowExpanded by remember { mutableStateOf(false) }
    var showAbout by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showViewsManager by remember { mutableStateOf(false) }
    var wallFullscreen by remember { mutableStateOf(false) }
    // Local saved views (named camera subsets) — phone-only, see SecureStore.
    var views by remember { mutableStateOf(store.cameraViews) }
    var activeViewId by remember { mutableStateOf(store.activeViewId) }
    var editorTarget by remember { mutableStateOf<ViewEditorTarget?>(null) }
    // Paired in-memory + persisted writes so a store write can't be forgotten (the
    // store is the source of truth — selection/views survive navigate-away-and-back).
    fun setViews(list: List<CameraView>) { views = list; store.cameraViews = list }
    fun setActive(id: String?) { activeViewId = id; store.activeViewId = id }
    // Views are now server-backed (per-user, same /views the desktop uses). The store
    // stays a local CACHE so chips render instantly + offline; we reconcile with the
    // server on entry and after every edit. Ordering is client-only (the server has no
    // view order), so a refresh re-applies the cached order and appends anything new.
    val viewScope = rememberCoroutineScope()
    val appCtx = LocalContext.current.applicationContext
    suspend fun refreshViews() {
        container.repository.listViews().onSuccess { server ->
            val pos = store.cameraViews.mapIndexed { i, v -> v.id to i }.toMap()
            setViews(server.sortedBy { pos[it.id] ?: Int.MAX_VALUE })
        }
    }
    LaunchedEffect(Unit) { refreshViews() }
    // Top tabs: Live (this wall) vs Playback. Playback is now a STANDALONE mode, so
    // selecting it navigates straight into the Playback screen rather than retargeting
    // tile taps. The Live wall always opens fullscreen-live on tile tap.
    val onTileClick: (String) -> Unit = { id -> onOpenFullscreen(id) }

    // Poll /status every 2s for the set of cameras with motion "right now" → the
    // red running-person badge on each tile (commercial-VMS-style). Cancelled when the
    // screen leaves composition.
    var motionCams by remember { mutableStateOf<Set<String>>(emptySet()) }
    // Cameras actually RECORDING right now → the red REC dot. A motion-mode camera
    // is live but only records WHILE motion is recording, so a quiet motion camera
    // must NOT show the red dot (it was previously shown for every live tile).
    var recordingCams by remember { mutableStateOf<Set<String>>(emptySet()) }
    // Frigate's live object detections per camera (cameraId -> icon_keys) → the
    // color-coded object icons on each tile (person/vehicle/animal/…).
    var detectionCams by remember { mutableStateOf<Map<String, List<String>>>(emptyMap()) }
    // Last-seen server config fingerprint; a change means a server-side edit (stream
    // URL, mode, retention, enable/disable, …) — re-fetch cameras + reconnect panes.
    var lastConfigVersion by remember { mutableStateOf<String?>(null) }
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(Unit) {
        // Only poll while the screen is at least STARTED — stops the /status +
        // detections network loop when the app is backgrounded (saves battery + data).
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            var failStreak = 0
            while (true) {
                val statusRes = container.repository.status().onSuccess { st ->
                    motionCams = st.cameras.filter { it.recentMotion }.map { it.id }.toSet()
                    recordingCams = st.cameras.filter { it.recording }.map { it.id }.toSet()
                    val cv = st.configVersion
                    // Refresh on a CHANGE only (skip the first observation so opening the
                    // screen doesn't double-load). vm.refresh() re-resolves all streams.
                    if (cv.isNotEmpty() && lastConfigVersion != null && cv != lastConfigVersion) {
                        vm.refresh()
                    }
                    if (cv.isNotEmpty()) lastConfigVersion = cv
                }
                val ids = vm.uiState.value.cameras.map { it.id }
                container.repository.activeDetections(ids).onSuccess { detectionCams = it }
                // Exponential backoff under failure so a down/slow server isn't hit
                // every 2s on a flaky link (review D1); snap back on recovery.
                failStreak = if (statusRes.isSuccess) 0 else failStreak + 1
                val delayMs = if (failStreak == 0) 2000L
                else (2000L shl (failStreak - 1)).coerceAtMost(30000L)
                delay(delayMs)
            }
        }
    }

    // Engage/disengage true immersive mode for the kiosk wall fullscreen.
    ImmersiveMode(enabled = wallFullscreen)
    // Keep the display awake while the live wall is up — a security wall is meant to
    // stay visible, and the default screen timeout would blank it mid-watch.
    KeepScreenOn(enabled = true)

    // In landscape the top is short, so the view chips ride inline with the tabs (see
    // the app-bar title). In portrait they stay a separate strip below the tabs.
    val isLandscape =
        LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    // Portrait can't usefully show 4 tiles across (each gets too tiny) — cap it at 3.
    val maxCols = if (isLandscape) 4 else 3

    // The active view (null = "All cameras"); a stale persisted id resolves to null.
    val activeView = views.firstOrNull { it.id == activeViewId }
    // Cameras to render: a view's cameras in its saved order (skipping any that no
    // longer exist), or every camera when no view is active.
    val shownCameras = activeView?.let { v ->
        val byId = state.cameras.associateBy { it.id }
        v.cameraIds.mapNotNull { byId[it] }
    } ?: state.cameras
    // Stable (id, name) pairs for the editor — only changes when the camera SET
    // changes, not on the 2 s motion/detection poll, so an open editor / in-progress
    // drag isn't churned by the poll.
    val allCamPairs = remember(state.cameras) { state.cameras.map { it.id to it.name } }

    // Low-bw mode: read from the VM state (which is seeded from SecureStore on init).
    val lowBandwidthMode = state.lowBandwidthMode

    Scaffold(
        topBar = {
            if (!wallFullscreen) {
                TopAppBar(
                    title = {
                        // Live | Playback tabs. In LANDSCAPE the saved-view chips ride
                        // inline to their right (separated by a rule; overflow scrolls
                        // sideways) to save scarce vertical space; in PORTRAIT they're a
                        // separate strip below (rendered in the body).
                        if (isLandscape && views.isNotEmpty()) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                CrumbModeTabs(
                                    selected = CrumbMode.LIVE,
                                    onLive = {},
                                    onPlayback = onOpenPlaybackMode,
                                    onClips = onOpenClips,
                                    showPlayback = caps.playback || store.isAdmin,
                                    showClips = caps.clips || store.isAdmin,
                                )
                                InlineDivider()
                                ViewChipsRow(
                                    views = views,
                                    activeViewId = activeViewId,
                                    onSelect = { setActive(it) },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        } else {
                            CrumbModeTabs(
                                selected = CrumbMode.LIVE,
                                onLive = {},
                                onPlayback = onOpenPlaybackMode,
                                onClips = onOpenClips,
                                showPlayback = caps.playback || store.isAdmin,
                                showClips = caps.clips || store.isAdmin,
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = NavyDeep,
                        titleContentColor = MaterialTheme.colorScheme.onSurface,
                        actionIconContentColor = MaterialTheme.colorScheme.onSurface,
                    ),
                    actions = {
                        // Low-bandwidth mode now lives in Settings (overflow → Settings),
                        // not as an app-bar icon. The auto-fallback banner (below the
                        // tabs) still offers one-tap restore when it engages on its own.

                        // Grid-density picker (shared control + value with Playback).
                        GridLayoutToggle(layout, maxCols) { next ->
                            layout = next
                            store.liveGridLayout = next.ordinal
                        }

                        // Export lives under Playback now (not on the Live wall).

                        // Wall fullscreen toggle.
                        HintTooltip("Fullscreen wall") {
                            IconButton(onClick = { wallFullscreen = true }) {
                                Icon(
                                    imageVector = Icons.Default.Fullscreen,
                                    contentDescription = "Fullscreen",
                                )
                            }
                        }

                        // Overflow menu (Settings / About / Logout).
                        Box {
                            HintTooltip("More options") {
                                IconButton(onClick = { overflowExpanded = true }) {
                                    Icon(
                                        imageVector = Icons.Default.MoreVert,
                                        contentDescription = "More options",
                                    )
                                }
                            }
                            DropdownMenu(
                                expanded = overflowExpanded,
                                onDismissRequest = { overflowExpanded = false },
                            ) {
                                DropdownMenuItem(
                                    text = { Text("Manage views") },
                                    onClick = {
                                        overflowExpanded = false
                                        showViewsManager = true
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Settings") },
                                    onClick = {
                                        overflowExpanded = false
                                        showSettings = true
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("About / build info") },
                                    onClick = {
                                        overflowExpanded = false
                                        showAbout = true
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Logout") },
                                    onClick = {
                                        overflowExpanded = false
                                        onLogout()
                                    },
                                )
                            }
                        }
                    },
                )
            }
        },
        containerColor = NavyDeep,
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                // ── Auto-fallback badge ───────────────────────────────────────────
                // Shown when the wall auto-entered low-bw mode due to stalling tiles.
                // Dismissed by tapping "Restore" (manually exits low-bw mode) or the
                // X button (closes the badge but keeps low-bw mode active).
                if (state.autoFallbackActive) {
                    LowBandwidthAutoFallbackBanner(
                        onRestore = { vm.setLowBandwidthMode(false) },
                        onDismiss = { vm.dismissAutoFallbackBadge() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }

                // Saved-view chips strip (PORTRAIT only; landscape shows them inline in
                // the title). Hidden in fullscreen kiosk mode. Tap to switch; persists.
                if (!isLandscape && !wallFullscreen && views.isNotEmpty()) {
                    ViewChipsRow(
                        views = views,
                        activeViewId = activeViewId,
                        onSelect = { setActive(it) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                    )
                }

                Box(modifier = Modifier.fillMaxSize()) {
                    when {
                        // ── Loading ─────────────────────────────────────────────────
                        state.loading -> {
                            CircularProgressIndicator(
                                modifier = Modifier.align(Alignment.Center),
                                color = TealAccent,
                            )
                        }

                        // ── Viewer restricted (403) ──────────────────────────────────
                        state.isViewerRestricted -> {
                            ViewerRestrictedState(
                                modifier = Modifier.align(Alignment.Center),
                                onRetry = { vm.refresh() },
                            )
                        }

                        // ── Non-403 error ────────────────────────────────────────────
                        state.error != null -> {
                            ErrorState(
                                message = state.error!!,
                                modifier = Modifier.align(Alignment.Center),
                                onRetry = { vm.refresh() },
                            )
                        }

                        // ── Empty (no cameras) ───────────────────────────────────────
                        state.cameras.isEmpty() -> {
                            EmptyState(
                                modifier = Modifier.align(Alignment.Center),
                                onRetry = { vm.refresh() },
                            )
                        }

                        // ── Active view filtered to zero available cameras ───────────
                        // (cameras exist, but none of this view's are present/enabled).
                        shownCameras.isEmpty() -> {
                            Column(
                                modifier = Modifier.align(Alignment.Center).padding(32.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(
                                    text = "This view has no available cameras.",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = TextSecondary,
                                )
                                TextButton(onClick = { setActive(null) }) {
                                    Text("Show all cameras", color = TealAccent)
                                }
                                activeView?.let { av ->
                                    TextButton(onClick = { editorTarget = ViewEditorTarget.Edit(av) }) {
                                        Text("Edit view", color = TealAccent)
                                    }
                                }
                            }
                        }

                        // ── Camera grid ──────────────────────────────────────────────
                        else -> {
                            LazyVerticalGrid(
                                columns = GridCells.Fixed(minOf(layout.cols, maxCols)),
                                contentPadding = PaddingValues(8.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                                modifier = Modifier.fillMaxSize(),
                            ) {
                                items(shownCameras, key = { it.id }) { cam ->
                                    LiveCameraTile(
                                        camera = cam,
                                        streams = state.streams[cam.id],
                                        onClick = { onTileClick(cam.id) },
                                        mediaUrls = mediaUrls,
                                        motion = motionCams.contains(cam.id),
                                        // REC dot = actually recording NOW, straight from
                                        // /status (`recording` = a segment was indexed in
                                        // the last ~12s). The recorder only indexes segments
                                        // while a motion-mode camera is actively recording
                                        // motion, so this is already false when such a camera
                                        // is idle — no need to second-guess via the policy
                                        // mode (which reflects config, not live state).
                                        recording = recordingCams.contains(cam.id),
                                        detections = detectionCams[cam.id] ?: emptyList(),
                                        lowBandwidthMode = lowBandwidthMode,
                                        onStall = { vm.reportTileStall(cam.id) },
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .aspectRatio(16f / 9f),
                                    )
                                }
                            }
                        }
                    }

                    // Floating exit button shown only in wall fullscreen mode.
                    // Positioned top-end with status-bar padding so it doesn't hide
                    // under the system bar when the user edge-swipes it back.
                    if (wallFullscreen) {
                        HintTooltip("Exit fullscreen") {
                            IconButton(
                                onClick = { wallFullscreen = false },
                                modifier = Modifier
                                    .align(Alignment.TopEnd)
                                    .statusBarsPadding()
                                    .padding(4.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.FullscreenExit,
                                    contentDescription = "Exit fullscreen",
                                    tint = TealAccent,
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    if (showSettings) {
        SettingsDialog(
            store = store,
            lowBandwidthMode = lowBandwidthMode,
            onLowBandwidthChange = { vm.setLowBandwidthMode(it) },
            onDismiss = { showSettings = false },
        )
    }
    if (showViewsManager) {
        ViewsManagerDialog(
            views = views,
            activeViewId = activeViewId,
            onReorder = { from, to ->
                val list = views.toMutableList()
                if (from in list.indices && to in list.indices) {
                    val item = list.removeAt(from)
                    list.add(to, item)
                    setViews(list)
                }
            },
            onSelect = { id ->
                setActive(id)
                showViewsManager = false
            },
            onNew = { editorTarget = ViewEditorTarget.New },
            onEdit = { v -> editorTarget = ViewEditorTarget.Edit(v) },
            onDismiss = { showViewsManager = false },
        )
    }
    if (showAbout) {
        AboutDialog(serverUrl = store.serverUrl, onDismiss = { showAbout = false })
    }
    editorTarget?.let { target ->
        ViewEditorDialog(
            target = target,
            allCameras = allCamPairs,
            onSave = { saved ->
                // The server has no view-UPDATE, so an edit = delete the old + create a
                // new one (its id changes). A new view is just a create.
                val isEdit = views.any { it.id == saved.id }
                viewScope.launch {
                    if (isEdit) container.repository.deleteView(saved.id)
                    container.repository.createView(saved.name, saved.cameraIds)
                        .onSuccess { created -> refreshViews(); setActive(created.id) }
                        .onFailure {
                            Toast.makeText(appCtx, "Couldn't save view: ${it.toUserMessage()}", Toast.LENGTH_LONG).show()
                        }
                }
                editorTarget = null
            },
            onDelete = { id ->
                viewScope.launch {
                    container.repository.deleteView(id)
                        .onSuccess {
                            if (activeViewId == id) setActive(null)
                            refreshViews()
                        }
                        .onFailure {
                            Toast.makeText(appCtx, "Couldn't delete view: ${it.toUserMessage()}", Toast.LENGTH_LONG).show()
                        }
                }
                editorTarget = null
            },
            onDismiss = { editorTarget = null },
        )
    }
}

// ─── low-bandwidth auto-fallback banner ──────────────────────────────────────

/**
 * A dismissible banner shown when the live wall automatically entered
 * low-bandwidth mode due to repeated tile stalls. Two actions:
 * - "Restore" — calls [onRestore] which flips the mode off + arms the cooldown.
 * - X — calls [onDismiss] which hides just the badge (mode stays on).
 */
@Composable
private fun LowBandwidthAutoFallbackBanner(
    onRestore: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .background(NavySurface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = Icons.Default.SignalWifiStatusbarConnectedNoInternet4,
            contentDescription = null,
            tint = TealAccent,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = "Low bandwidth — tap to restore",
            style = MaterialTheme.typography.labelMedium,
            color = TextSecondary,
            modifier = Modifier
                .weight(1f)
                .clickable(onClick = onRestore),
        )
        TextButton(
            onClick = onRestore,
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
        ) {
            Text("Restore", color = TealAccent, style = MaterialTheme.typography.labelMedium)
        }
        IconButton(
            onClick = onDismiss,
            modifier = Modifier.size(28.dp),
        ) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = "Dismiss",
                tint = TextSecondary,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

// ─── private state composables ───────────────────────────────────────────────

@Composable
private fun ViewerRestrictedState(
    modifier: Modifier = Modifier,
    onRetry: () -> Unit,
) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = "You don't have access to any cameras.",
            style = MaterialTheme.typography.bodyMedium,
            color = TextSecondary,
        )
        TextButton(onClick = onRetry) {
            Text("Retry", color = TealAccent)
        }
    }
}

@Composable
private fun ErrorState(
    message: String,
    modifier: Modifier = Modifier,
    onRetry: () -> Unit,
) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
        )
        TextButton(onClick = onRetry) {
            Text("Retry", color = TealAccent)
        }
    }
}

@Composable
private fun EmptyState(
    modifier: Modifier = Modifier,
    onRetry: () -> Unit,
) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = "No cameras available",
            style = MaterialTheme.typography.bodyMedium,
            color = TextSecondary,
        )
        TextButton(onClick = onRetry) {
            Text("Refresh", color = TealAccent)
        }
    }
}
