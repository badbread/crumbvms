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
import androidx.compose.material.icons.filled.AddAPhoto
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
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import android.graphics.drawable.BitmapDrawable
import coil.imageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import video.crumb.app.data.CameraDto
import video.crumb.app.data.CameraView
import video.crumb.app.data.MediaUrls
import video.crumb.app.di.appContainer
import video.crumb.app.feature.about.AboutDialog
import video.crumb.app.feature.playback.SavedSnapshot
import video.crumb.app.feature.playback.saveFrameToGallery
import video.crumb.app.feature.playback.shareImageUri
import video.crumb.app.feature.settings.SettingsDialog
import video.crumb.app.feature.update.UpdateAvailableBanner
import video.crumb.app.feature.update.UpdateViewModel
import video.crumb.app.ui.CrumbMode
import video.crumb.app.ui.CrumbModeTabs
import video.crumb.app.ui.GridLayoutToggle
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.ImmersiveMode
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
    onOpenPlates: () -> Unit = {},
    onLogout: () -> Unit,
) {
    val container = appContainer()
    val vm: LiveViewModel = viewModel(
        factory = viewModelFactory {
            initializer { LiveViewModel(container.repository, container.store) }
        },
    )
    val state by vm.uiState.collectAsStateWithLifecycle()

    // Auto-recover (issue #176): when validated connectivity RETURNS after the
    // initial load gave up with a "can't reach the server" error, kick a fresh
    // Retry so the wall recovers on its own — no user tap needed. `retry()` drops
    // any wedged pooled socket first. Fires only on the offline→online transition
    // (LaunchedEffect keyed on the online flag), so a persistent server-unreachable
    // error while already online doesn't hammer — that path keeps the manual Retry.
    val isOnline by rememberIsOnline()
    LaunchedEffect(isOnline) {
        if (isOnline && state.error != null) vm.retry()
    }

    // Update-available check (issue #7) — lives here because Live is the root
    // destination (always on the back stack, see MainActivity's popUpTo(LIVE)),
    // so its 24h re-check timer survives Live/Playback/Clips tab switches.
    val updateVm: UpdateViewModel = viewModel(
        factory = viewModelFactory {
            initializer { UpdateViewModel(container.repository, container.store) }
        },
    )
    val updateState by updateVm.uiState.collectAsStateWithLifecycle()
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
    // Snapshot (#163): when more than one camera is shown, tapping the snapshot
    // action opens this menu to pick WHICH camera's live frame to grab.
    var snapshotMenuOpen by remember { mutableStateOf(false) }
    // Actionable "Snapshot saved to …" / "Saved to …" confirmations (#164 offers a
    // Share action on them). Activity context (not applicationContext) so the share
    // chooser launches without needing FLAG_ACTIVITY_NEW_TASK.
    val snackbarHostState = remember { SnackbarHostState() }
    val activityContext = LocalContext.current
    // Local saved views (named camera subsets) — phone-only, see SecureStore.
    var views by remember { mutableStateOf(store.cameraViews) }
    var activeViewId by remember { mutableStateOf(store.activeViewId) }
    // Client-side preference: hide the auto-built "All Cameras" default view (desktop
    // parity — `client_options.dart`'s `showAllCamerasView`). Local mirror so the
    // Settings dialog's toggle (below) takes effect immediately, without leaving and
    // re-entering this screen.
    var showAllCamerasView by remember { mutableStateOf(store.showAllCamerasView) }
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
    // When "Show All Cameras" is off and nothing is explicitly selected, the whole
    // point of the option is to NOT fall back to every camera — an operator's own
    // saved views should be what shows instead (see the auto-adopt effect below,
    // which picks a saved view for this case rather than leaving it stuck empty).
    val suppressingAllCameras = !showAllCamerasView && activeView == null
    // Cameras to render: a view's cameras in its saved order (skipping any that no
    // longer exist); every camera when no view is active and "All" isn't suppressed;
    // otherwise nothing (the empty state below prompts for a saved view instead).
    val shownCameras = when {
        activeView != null -> {
            val byId = state.cameras.associateBy { it.id }
            activeView.cameraIds.mapNotNull { byId[it] }
        }
        suppressingAllCameras -> emptyList()
        else -> state.cameras
    }
    // Auto-adopt the operator's first saved view in place of the suppressed "All
    // Cameras" default (persists via setActive, so this only fires once per
    // suppression window — the next recomposition has a non-null activeViewId and
    // suppressingAllCameras goes false). Re-evaluated whenever the option, the view
    // list (e.g. the server refresh in refreshViews()), or the selection changes —
    // e.g. deleting the active view resets activeViewId to null (see the view-editor
    // onDelete below), which should re-adopt another saved view rather than fall
    // through to "All".
    LaunchedEffect(showAllCamerasView, views, activeViewId) {
        if (suppressingAllCameras && views.isNotEmpty()) {
            setActive(views.first().id)
        }
    }
    // Stable (id, name) pairs for the editor — only changes when the camera SET
    // changes, not on the 2 s motion/detection poll, so an open editor / in-progress
    // drag isn't churned by the poll.
    val allCamPairs = remember(state.cameras) { state.cameras.map { it.id to it.name } }

    // Low-bw mode: read from the VM state (which is seeded from SecureStore on init).
    val lowBandwidthMode = state.lowBandwidthMode

    // Snapshot (#163): grab a camera's current live frame → device gallery, then a
    // Share-able confirmation (#164). The wall tiles render on a SurfaceView (no
    // readable pixel buffer), so rather than a surface grab we fetch the camera's
    // server still (`/cameras/{id}/frame.jpg`, the same proxied frame the wall's
    // placeholder/low-bw tiles use) — a full-resolution current frame, decoded via
    // Coil and saved through the shared [saveFrameToGallery] path.
    fun takeSnapshot(cam: CameraDto) {
        viewScope.launch {
            val saved = captureCameraSnapshot(activityContext, mediaUrls, cam.id, cam.name)
            if (saved != null) {
                val res = snackbarHostState.showSnackbar(
                    message = "Snapshot saved to ${saved.displayPath}",
                    actionLabel = "Share",
                    duration = SnackbarDuration.Long,
                )
                if (res == SnackbarResult.ActionPerformed) {
                    shareImageUri(activityContext, saved.shareUri)
                }
            } else {
                snackbarHostState.showSnackbar("Snapshot failed — frame unavailable")
            }
        }
    }

    Scaffold(
        snackbarHost = {
            SnackbarHost(hostState = snackbarHostState) { data -> Snackbar(snackbarData = data) }
        },
        topBar = {
            if (!wallFullscreen) {
                TopAppBar(
                    title = {
                        // Live | Playback | Clips | LPR tabs. The grid/snapshot/
                        // fullscreen actions used to share this row and squeezed the
                        // tabs (#161); they now live on the second bar (the view-chips
                        // row, in the body) so the tabs get the full title width and
                        // keep their own horizontal scroll.
                        CrumbModeTabs(
                            selected = CrumbMode.LIVE,
                            onLive = {},
                            onPlayback = onOpenPlaybackMode,
                            onClips = onOpenClips,
                            onPlates = onOpenPlates,
                            showPlayback = caps.playback || store.isAdmin,
                            showClips = caps.clips || store.isAdmin,
                            showPlates = store.platesEnabled,
                        )
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = NavyDeep,
                        titleContentColor = MaterialTheme.colorScheme.onSurface,
                        actionIconContentColor = MaterialTheme.colorScheme.onSurface,
                    ),
                    actions = {
                        // Low-bandwidth mode lives in Settings (overflow → Settings).
                        // The grid-density, snapshot, and fullscreen actions moved to the
                        // second bar (#161); only the overflow ⋮ stays in the app bar.

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
                // ── Update-available banner (issue #7) ────────────────────────────
                // Non-intrusive, dismissible; dismiss remembers the version so it
                // stays quiet until a NEWER release appears (see UpdateViewModel).
                if (updateState.showBanner) {
                    UpdateAvailableBanner(
                        state = updateState,
                        onDismiss = { updateVm.dismiss() },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }

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

                // ── Second bar (#161): saved-view chips + relocated actions ────────
                // The grid-density, snapshot (#163), and fullscreen actions were moved
                // off the top tab row to here so the tabs get more room. The chips take
                // the remaining width and scroll horizontally (so a growing view list +
                // the fixed action icons never run out of room); the icons stay pinned
                // to the end. Hidden in fullscreen kiosk mode.
                if (!wallFullscreen) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 8.dp, vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ViewChipsRow(
                            views = views,
                            activeViewId = activeViewId,
                            onSelect = { setActive(it) },
                            modifier = Modifier.weight(1f),
                            showAllCamerasView = showAllCamerasView,
                        )

                        // Grid-density picker (shared control + value with Playback).
                        GridLayoutToggle(layout, maxCols) { next ->
                            layout = next
                            store.liveGridLayout = next.ordinal
                        }

                        // Take snapshot (#163). One shown camera → grab it directly;
                        // several → a small menu to pick which camera's frame to grab.
                        Box {
                            HintTooltip("Take snapshot") {
                                IconButton(onClick = {
                                    when (shownCameras.size) {
                                        0 -> viewScope.launch {
                                            snackbarHostState.showSnackbar("No camera to snapshot")
                                        }
                                        1 -> takeSnapshot(shownCameras.first())
                                        else -> snapshotMenuOpen = true
                                    }
                                }) {
                                    Icon(
                                        imageVector = Icons.Default.AddAPhoto,
                                        contentDescription = "Take snapshot",
                                    )
                                }
                            }
                            DropdownMenu(
                                expanded = snapshotMenuOpen,
                                onDismissRequest = { snapshotMenuOpen = false },
                            ) {
                                shownCameras.forEach { cam ->
                                    DropdownMenuItem(
                                        text = { Text(cam.name) },
                                        onClick = {
                                            snapshotMenuOpen = false
                                            takeSnapshot(cam)
                                        },
                                    )
                                }
                            }
                        }

                        // Wall fullscreen toggle.
                        HintTooltip("Fullscreen wall") {
                            IconButton(onClick = { wallFullscreen = true }) {
                                Icon(
                                    imageVector = Icons.Default.Fullscreen,
                                    contentDescription = "Fullscreen",
                                )
                            }
                        }
                    }
                }

                Box(modifier = Modifier.fillMaxSize()) {
                    when {
                        // ── Loading ─────────────────────────────────────────────────
                        // Under a weak/flaky link the initial load retries (issue
                        // #176); once it runs long, a "still trying…" hint appears
                        // under the spinner so the wall is never a silent spinner.
                        state.loading -> {
                            Column(
                                modifier = Modifier.align(Alignment.Center).padding(24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(14.dp),
                            ) {
                                CircularProgressIndicator(color = TealAccent)
                                state.connecting?.let { msg ->
                                    Text(
                                        text = msg,
                                        color = Color.White.copy(alpha = 0.72f),
                                        fontSize = 13.sp,
                                        textAlign = TextAlign.Center,
                                    )
                                }
                            }
                        }

                        // ── Viewer restricted (403) ──────────────────────────────────
                        state.isViewerRestricted -> {
                            ViewerRestrictedState(
                                modifier = Modifier.align(Alignment.Center),
                                onRetry = { vm.retry() },
                            )
                        }

                        // ── Non-403 error ────────────────────────────────────────────
                        state.error != null -> {
                            ErrorState(
                                message = state.error!!,
                                modifier = Modifier.align(Alignment.Center),
                                onRetry = { vm.retry() },
                            )
                        }

                        // ── Empty (no cameras) ───────────────────────────────────────
                        state.cameras.isEmpty() -> {
                            EmptyState(
                                modifier = Modifier.align(Alignment.Center),
                                onRetry = { vm.retry() },
                            )
                        }

                        // ── "All Cameras" suppressed, no saved view to fall back to ──
                        // (cameras exist, "Show All Cameras" is off, and there's nothing
                        // in [views] yet for the auto-adopt effect above to pick).
                        suppressingAllCameras && views.isEmpty() -> {
                            Column(
                                modifier = Modifier.align(Alignment.Center).padding(32.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(
                                    text = "No saved views yet.",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = TextSecondary,
                                )
                                Text(
                                    text = "\"Show All Cameras\" is off in Settings — " +
                                        "create a view, or turn it back on.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextSecondary,
                                )
                                TextButton(onClick = { editorTarget = ViewEditorTarget.New }) {
                                    Text("Create a view", color = TealAccent)
                                }
                                TextButton(onClick = { showSettings = true }) {
                                    Text("Open Settings", color = TealAccent)
                                }
                            }
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
            showAllCamerasView = showAllCamerasView,
            onShowAllCamerasViewChange = {
                showAllCamerasView = it
                store.showAllCamerasView = it
            },
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
        AboutDialog(
            serverUrl = store.serverUrl,
            updateState = updateState,
            onOpened = { updateVm.refresh() },
            onCheckNow = { updateVm.checkNow() },
            onDismiss = { showAbout = false },
        )
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

// ─── live snapshot capture ───────────────────────────────────────────────────

/**
 * Fetch a camera's current server still frame (`GET /cameras/{id}/frame.jpg`,
 * scoped-token authed via [MediaUrls]) and save it to the device gallery.
 *
 * The live wall renders tiles on a Media3 SurfaceView, whose pixel buffer can't
 * be read back for an on-screen grab, so instead of a surface capture we pull the
 * same API-proxied still the wall already uses for its placeholder / low-bandwidth
 * tiles — a full-resolution current frame that works regardless of which go2rtc
 * owns the camera. Decoded with Coil (hardware bitmaps disabled so it can be
 * JPEG-compressed) and written through the shared [saveFrameToGallery] path.
 *
 * Returns the [SavedSnapshot] (location + share Uri) or null on any failure.
 */
private suspend fun captureCameraSnapshot(
    context: android.content.Context,
    mediaUrls: MediaUrls,
    cameraId: String,
    cameraName: String,
): SavedSnapshot? {
    val url = runCatching { mediaUrls.cameraFrameUrl(cameraId) }.getOrNull() ?: return null
    val req = ImageRequest.Builder(context)
        .data(url)
        .memoryCachePolicy(CachePolicy.DISABLED)
        .diskCachePolicy(CachePolicy.DISABLED)
        .allowHardware(false)
        .build()
    val result = context.imageLoader.execute(req)
    if (result !is SuccessResult) return null
    val bmp = (result.drawable as? BitmapDrawable)?.bitmap ?: return null
    return saveFrameToGallery(context, bmp, cameraName)
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
