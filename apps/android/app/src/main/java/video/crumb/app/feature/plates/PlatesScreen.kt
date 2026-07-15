// SPDX-License-Identifier: AGPL-3.0-or-later

@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package video.crumb.app.feature.plates

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Event
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.filled.ViewList
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import coil.compose.AsyncImage
import coil.imageLoader
import coil.request.ImageRequest
import kotlinx.coroutines.launch
import androidx.compose.ui.layout.ContentScale
import video.crumb.app.data.CameraDto
import video.crumb.app.data.MediaUrls
import video.crumb.app.data.PlateRead
import video.crumb.app.data.PlateWatchlistEntry
import video.crumb.app.data.WATCHLIST_KIND_IGNORE
import video.crumb.app.data.WATCHLIST_KIND_WATCH
import video.crumb.app.di.appContainer
import video.crumb.app.ui.CrumbMode
import video.crumb.app.ui.CrumbModeTabs
import video.crumb.app.ui.JumpToDateTimeDialog
import video.crumb.app.ui.Time
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextSecondary
import video.crumb.app.ui.theme.TimelineColors
import kotlin.math.roundToInt

/**
 * The Plates tab: a newest-first browser of license-plate reads (LPR).
 *
 * Mirrors the desktop client's Plates tab
 * (`apps/desktop-flutter/lib/ui/plates/plates_screen.dart`): a filter bar
 * (plate search + exact/contains/fuzzy match toggle, camera multi-select, time
 * range) over a list of reads. Each row shows the plate, the sibling
 * detection-event snapshot, camera name, local timestamp, and a confidence
 * chip; tapping a row jumps to Playback at that read's moment on that camera.
 *
 * Callers gate entry on `SecureStore.platesEnabled` — this screen does not
 * re-check it, so it should never be reachable when that flag is false.
 */
@Composable
fun PlatesScreen(
    onOpenLive: () -> Unit,
    onOpenPlayback: () -> Unit,
    onOpenClips: () -> Unit = {},
    /** `(cameraId, timeMs)` — jump to that camera's Playback at the read's moment. */
    onOpenPlateAt: (cameraId: String, timeMs: Long) -> Unit = { _, _ -> },
) {
    val container = appContainer()
    val vm: PlatesViewModel = viewModel(
        factory = viewModelFactory { initializer { PlatesViewModel(container.repository) } },
    )
    val state by vm.state.collectAsStateWithLifecycle()
    val mediaUrls = remember { container.mediaUrls() }
    val store = container.store
    val caps = store.capabilities
    val isAdmin = store.isAdmin
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var showCameraPicker by remember { mutableStateOf(false) }
    var showJump by remember { mutableStateOf(false) }
    var showWatchlist by remember { mutableStateOf(false) }
    // The plate a "quick add to watchlist" was tapped for — opens a small chooser
    // asking watch (alert) vs ignore (drop) before adding. Null = chooser closed.
    var addKindForPlate by remember { mutableStateOf<String?>(null) }
    // The single plate a report is being built for (opens the builder dialog), plus
    // an in-flight guard so the dialog can show a spinner + block re-taps.
    var reportFor by remember { mutableStateOf<PlateRead?>(null) }
    var generatingReport by remember { mutableStateOf(false) }
    val snackbarHostState = remember { SnackbarHostState() }

    // Surface the ViewModel's one-shot messages (add/remove result, admin-only
    // 403 notice) in a snackbar, then clear so it doesn't re-show on recomposition.
    LaunchedEffect(state.message) {
        val msg = state.message
        if (msg != null) {
            snackbarHostState.showSnackbar(msg)
            vm.consumeMessage()
        }
    }

    Scaffold(
        containerColor = NavyDeep,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    CrumbModeTabs(
                        selected = CrumbMode.PLATES,
                        onLive = onOpenLive,
                        onPlayback = onOpenPlayback,
                        onClips = onOpenClips,
                        onPlates = {},
                        showPlayback = caps.playback || store.isAdmin,
                        showClips = caps.clips || store.isAdmin,
                        showPlates = true,
                    )
                },
                actions = {
                    // Per-plate reports are the primary export path now — each plate row
                    // has its own "Report" action that opens the builder dialog. (The old
                    // bulk "Export PDF" toolbar button was removed in favor of it.)
                    IconButton(onClick = { showWatchlist = true; vm.loadWatchlist(); vm.loadLprConfig() }) {
                        Icon(Icons.Filled.Star, contentDescription = "Plate watchlist")
                    }
                    IconButton(onClick = { vm.refresh() }) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NavyDeep),
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            PlatesFilterBar(
                state = state,
                onQueryChange = { vm.setQuery(it) },
                onSubmitSearch = { vm.submitSearch() },
                onMatchChange = { vm.setMatch(it) },
                onHoursChange = { vm.setHours(it) },
                onPickCameras = { showCameraPicker = true },
                onPickWhen = { showJump = true },
                onResetToNow = { vm.setAnchorEnd(null) },
                modifier = Modifier.fillMaxWidth(),
            )
            PlatesViewSwitcher(
                mode = state.viewMode,
                onSelect = { vm.setViewMode(it) },
                modifier = Modifier.fillMaxWidth(),
            )
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
            Box(Modifier.fillMaxSize()) {
                when {
                    state.loading && state.plates.isEmpty() ->
                        CircularProgressIndicator(Modifier.align(Alignment.Center), color = TealAccent)
                    state.error != null ->
                        Text(
                            "Couldn't load plates: ${state.error}",
                            Modifier.align(Alignment.Center).padding(24.dp),
                            color = MaterialTheme.colorScheme.error,
                        )
                    state.plates.isEmpty() ->
                        Text(
                            "No plate reads in this window.",
                            Modifier.align(Alignment.Center),
                            color = TextSecondary,
                        )
                    else -> {
                        val byId = state.cameras.associateBy { it.id }
                        val onOpen: (PlateRead) -> Unit = { p ->
                            val ms = runCatching { Time.parseToMillis(p.ts) }.getOrNull()
                            if (ms != null) onOpenPlateAt(p.cameraId, ms)
                        }
                        val cameraName: (PlateRead) -> String = { byId[it.cameraId]?.name ?: "(unknown camera)" }
                        when (state.viewMode) {
                            PlatesViewMode.LIST -> PlatesListView(
                                plates = state.plates,
                                cameraName = cameraName,
                                mediaUrls = mediaUrls,
                                onOpen = onOpen,
                                isAdmin = isAdmin,
                                onAddToWatchlist = { addKindForPlate = it },
                                onReport = { reportFor = it },
                            )
                            PlatesViewMode.GALLERY -> PlatesGalleryView(
                                plates = state.plates,
                                cameraName = cameraName,
                                mediaUrls = mediaUrls,
                                onOpen = onOpen,
                                onReport = { reportFor = it },
                            )
                            PlatesViewMode.GROUPED -> PlatesGroupedView(
                                plates = state.plates,
                                cameraName = cameraName,
                                mediaUrls = mediaUrls,
                                onOpen = onOpen,
                            )
                            PlatesViewMode.TIMELINE -> PlatesTimelineView(
                                plates = state.plates,
                                cameraName = cameraName,
                                mediaUrls = mediaUrls,
                                onOpen = onOpen,
                            )
                        }
                    }
                }
            }
        }
    }

    addKindForPlate?.let { plate ->
        AlertDialog(
            onDismissRequest = { addKindForPlate = null },
            title = { Text(plate) },
            text = {
                Text(
                    "Add this plate to the alert watchlist, or ignore it so matching " +
                        "reads are dropped (no alert, not stored)?",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    vm.addToWatchlist(plate, kind = WATCHLIST_KIND_WATCH)
                    addKindForPlate = null
                }) { Text("Watch (alert)") }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = {
                        vm.addToWatchlist(plate, notify = false, kind = WATCHLIST_KIND_IGNORE)
                        addKindForPlate = null
                    }) { Text("Ignore") }
                    TextButton(onClick = { addKindForPlate = null }) { Text("Cancel") }
                }
            },
        )
    }
    if (showCameraPicker) {
        CameraPickerDialog(
            cameras = state.cameras,
            selected = state.selectedCameraIds,
            onApply = { ids -> vm.setSelectedCameras(ids); showCameraPicker = false },
            onDismiss = { showCameraPicker = false },
        )
    }
    if (showJump) {
        JumpToDateTimeDialog(
            initialMs = state.anchorEndMs ?: System.currentTimeMillis(),
            onDismiss = { showJump = false },
            onPicked = { ms -> vm.setAnchorEnd(ms); showJump = false },
        )
    }
    if (showWatchlist) {
        WatchlistDialog(
            state = state,
            isAdmin = isAdmin,
            onAdd = { plate, label, notify, kind -> vm.addToWatchlist(plate, label, notify, kind) },
            onRemove = { id -> vm.removeFromWatchlist(id) },
            onFuzzChange = { vm.setWatchlistFuzz(it) },
            onDismiss = { showWatchlist = false },
        )
    }
    val reportRead = reportFor
    if (reportRead != null) {
        PlateReportDialog(
            read = reportRead,
            mediaUrls = mediaUrls,
            generating = generatingReport,
            onDownload = { zoneId, includeDossier ->
                if (generatingReport) return@PlateReportDialog
                generatingReport = true
                val repo = container.repository
                val camNames = state.cameras.associate { it.id to it.name }
                val allCamIds = state.cameras.map { it.id }
                val loader = context.imageLoader
                val exportedBy = store.username ?: "—"
                scope.launch {
                    // Resolve the watchlist match (BOLO banner) + the sighting dossier
                    // up front so the PDF builder stays a focused render step. The
                    // match honors the server's fuzz tolerance so a FUZZY-alerted plate
                    // still shows the banner, not just an exact hit (#147-4). The fuzz
                    // comes from the admin-only LPR config; a non-admin can't read it,
                    // so it falls back to 0 (exact) — no regression, and admins (the
                    // forensic-report users) get the correct fuzzy banner.
                    val watchEntries = repo.watchlist().getOrNull().orEmpty()
                    val fuzz = repo.lprConfig().getOrNull()?.watchlistFuzz ?: 0f
                    val watchMatch = matchWatchlistBolo(reportRead.plate, watchEntries, fuzz)
                    val dossierResp = if (includeDossier && reportRead.plate.isNotBlank()) {
                        repo.plates(
                            cameraIds = allCamIds,
                            query = reportRead.plate,
                            match = "exact",
                            limit = 100,
                        ).getOrNull()
                    } else {
                        null
                    }
                    val input = PlateReportInput(
                        read = reportRead,
                        cameraNames = camNames,
                        exportedBy = exportedBy,
                        zoneId = zoneId,
                        includeDossier = includeDossier,
                        watchMatch = watchMatch,
                        dossier = dossierResp?.plates ?: emptyList(),
                        dossierTotal = dossierResp?.total ?: 0,
                    )
                    val result = generatePlateReportPdf(context, input, mediaUrls, loader)
                    generatingReport = false
                    reportFor = null
                    result
                        .onSuccess { file -> sharePlatesPdf(context, file) }
                        .onFailure { snackbarHostState.showSnackbar("Couldn't build the plate report.") }
                }
            },
            onDismiss = { if (!generatingReport) reportFor = null },
        )
    }
}

// ─── view switcher ──────────────────────────────────────────────────────────

/** The four-way render-mode toggle (List / Gallery / Grouped / Timeline). */
@Composable
private fun PlatesViewSwitcher(
    mode: PlatesViewMode,
    onSelect: (PlatesViewMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val chips = listOf(
            Triple(PlatesViewMode.LIST, "List", Icons.Filled.ViewList),
            Triple(PlatesViewMode.GALLERY, "Gallery", Icons.Filled.GridView),
            Triple(PlatesViewMode.GROUPED, "Grouped", Icons.Filled.Layers),
            Triple(PlatesViewMode.TIMELINE, "Timeline", Icons.Filled.ViewAgenda),
        )
        chips.forEach { (m, label, icon) ->
            FilterChip(
                selected = mode == m,
                onClick = { onSelect(m) },
                leadingIcon = { Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp)) },
                label = { Text(label) },
            )
        }
    }
}

// ─── reads views (list / gallery / grouped / timeline) ──────────────────────

/** Dense one-line rows — the original Plates view. */
@Composable
private fun PlatesListView(
    plates: List<PlateRead>,
    cameraName: (PlateRead) -> String,
    mediaUrls: MediaUrls,
    onOpen: (PlateRead) -> Unit,
    isAdmin: Boolean,
    onAddToWatchlist: (String) -> Unit,
    onReport: (PlateRead) -> Unit,
) {
    LazyColumn(Modifier.fillMaxSize()) {
        items(plates, key = { it.id }) { p ->
            PlateRow(
                read = p,
                cameraName = cameraName(p),
                mediaUrls = mediaUrls,
                onClick = { onOpen(p) },
                onReport = { onReport(p) },
                // Only admins can manage the watchlist; viewers still see the read-only
                // list via the toolbar. A 403 is handled defensively in the ViewModel
                // regardless (stale role → friendly notice).
                showAddToWatchlist = isAdmin && p.plate.isNotBlank(),
                onAddToWatchlist = { onAddToWatchlist(p.plate) },
            )
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
        }
    }
}

/** A grid of snapshot cards: thumbnail, plate, camera, time, confidence. */
@Composable
private fun PlatesGalleryView(
    plates: List<PlateRead>,
    cameraName: (PlateRead) -> String,
    mediaUrls: MediaUrls,
    onOpen: (PlateRead) -> Unit,
    onReport: (PlateRead) -> Unit,
) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 168.dp),
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        gridItems(plates, key = { it.id }) { p ->
            PlateGalleryCard(
                read = p,
                cameraName = cameraName(p),
                mediaUrls = mediaUrls,
                onClick = { onOpen(p) },
                onReport = { onReport(p) },
            )
        }
    }
}

@Composable
private fun PlateGalleryCard(
    read: PlateRead,
    cameraName: String,
    mediaUrls: MediaUrls,
    onClick: () -> Unit,
    onReport: () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    ) {
        Column {
            PlateThumb(
                read = read,
                mediaUrls = mediaUrls,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(112.dp),
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text = read.plate.ifEmpty { "—" },
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.Bold,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                    )
                    Text(
                        text = cameraName,
                        color = TextSecondary,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                    )
                    Text(
                        text = runCatching { Time.dateTime(read.ts) }.getOrDefault(read.ts),
                        color = TextSecondary,
                        style = MaterialTheme.typography.labelSmall,
                        maxLines = 1,
                    )
                }
                ConfidenceChip(read.confidence)
                IconButton(onClick = onReport, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Filled.PictureAsPdf,
                        contentDescription = "Plate report",
                        tint = TextSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/** Collapsed by normalized plate: one expandable row per unique plate, showing
 *  sighting count, first/last seen, and the cameras involved. Grouping is done
 *  client-side over the already-fetched reads. */
@Composable
private fun PlatesGroupedView(
    plates: List<PlateRead>,
    cameraName: (PlateRead) -> String,
    mediaUrls: MediaUrls,
    onOpen: (PlateRead) -> Unit,
) {
    // Group by normalized plate text (blank plates collapse under "—"). Newest
    // sighting first within each group; groups ordered by most-recent last-seen.
    val groups = remember(plates) { groupByPlate(plates) }
    LazyColumn(Modifier.fillMaxSize()) {
        items(groups, key = { it.key }) { g ->
            PlateGroupRow(group = g, cameraName = cameraName, mediaUrls = mediaUrls, onOpen = onOpen)
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
        }
    }
}

/** One collapsed plate group + its expandable sighting list. */
@Composable
private fun PlateGroupRow(
    group: PlateGroup,
    cameraName: (PlateRead) -> String,
    mediaUrls: MediaUrls,
    onOpen: (PlateRead) -> Unit,
) {
    var expanded by remember(group.key) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            PlateThumb(read = group.latest, mediaUrls = mediaUrls, modifier = Modifier.size(width = 84.dp, height = 50.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = group.plate.ifEmpty { "—" },
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.Bold,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text = "${group.count} sighting${if (group.count == 1) "" else "s"} · ${group.cameraNames(cameraName)}",
                    color = TextSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                )
                Text(
                    text = "First ${runCatching { Time.dateTime(group.firstSeen) }.getOrDefault(group.firstSeen)} · Last ${runCatching { Time.dateTime(group.lastSeen) }.getOrDefault(group.lastSeen)}",
                    color = TextSecondary,
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 2,
                )
            }
            Icon(
                imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = TextSecondary,
            )
        }
        if (expanded) {
            group.reads.forEach { r ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpen(r) }
                        .padding(start = 24.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(Icons.Filled.Videocam, contentDescription = null, tint = TextSecondary, modifier = Modifier.size(13.dp))
                    Text(
                        text = cameraName(r),
                        color = TextSecondary,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = runCatching { Time.dateTime(r.ts) }.getOrDefault(r.ts),
                        color = TextSecondary,
                        style = MaterialTheme.typography.labelSmall,
                    )
                    ConfidenceChip(r.confidence)
                }
            }
        }
    }
}

/** Big touch-friendly chronological rows (newest first). */
@Composable
private fun PlatesTimelineView(
    plates: List<PlateRead>,
    cameraName: (PlateRead) -> String,
    mediaUrls: MediaUrls,
    onOpen: (PlateRead) -> Unit,
) {
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(plates, key = { it.id }) { p ->
            Card(
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp).clickable { onOpen(p) },
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    PlateThumb(read = p, mediaUrls = mediaUrls, modifier = Modifier.size(width = 132.dp, height = 78.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            text = p.plate.ifEmpty { "—" },
                            color = MaterialTheme.colorScheme.onSurface,
                            fontWeight = FontWeight.Bold,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            style = MaterialTheme.typography.headlineSmall,
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Videocam, contentDescription = null, tint = TextSecondary, modifier = Modifier.size(15.dp))
                            Text(
                                text = cameraName(p),
                                color = TextSecondary,
                                style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1,
                                modifier = Modifier.padding(start = 5.dp),
                            )
                        }
                        Text(
                            text = runCatching { Time.dateTime(p.ts) }.getOrDefault(p.ts),
                            color = TextSecondary,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    ConfidenceChip(p.confidence)
                }
            }
        }
    }
}

// ─── grouped-view model (client-side over the fetched reads) ─────────────────

/** One normalized-plate group: its reads (newest first) + summary stats. */
private data class PlateGroup(
    val plate: String,
    val reads: List<PlateRead>,
) {
    val key: String get() = plate.ifEmpty { "—" }
    val count: Int get() = reads.size
    /** Reads are ordered newest-first, so first = latest, last = earliest. */
    val latest: PlateRead get() = reads.first()
    val firstSeen: String get() = reads.last().ts
    val lastSeen: String get() = reads.first().ts

    /** Comma-joined distinct camera names (capped so the summary stays one-ish line). */
    fun cameraNames(nameOf: (PlateRead) -> String): String {
        val names = reads.map(nameOf).distinct()
        return if (names.size <= 2) names.joinToString(", ") else "${names.take(2).joinToString(", ")} +${names.size - 2}"
    }
}

/** Collapse [plates] (already newest-first) by normalized plate text, ordering
 *  groups by most-recent sighting. */
private fun groupByPlate(plates: List<PlateRead>): List<PlateGroup> =
    plates.groupBy { it.plate }
        .map { (plate, reads) -> PlateGroup(plate, reads) }
        .sortedByDescending { runCatching { Time.parseToMillis(it.lastSeen) }.getOrDefault(0L) }

// ─── filter bar ───────────────────────────────────────────────────────────────

/** Horizontally-scrolling filter bar: search + match toggle, camera picker,
 *  range dropdown, jump-to-time, and the result count — mirrors the desktop
 *  client's filter row but laid out for a narrow phone width. */
@Composable
private fun PlatesFilterBar(
    state: PlatesUiState,
    onQueryChange: (String) -> Unit,
    onSubmitSearch: () -> Unit,
    onMatchChange: (String) -> Unit,
    onHoursChange: (Long) -> Unit,
    onPickCameras: () -> Unit,
    onPickWhen: () -> Unit,
    onResetToNow: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        TextField(
            value = state.query,
            onValueChange = onQueryChange,
            placeholder = { Text("Search plate…") },
            singleLine = true,
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = if (state.query.isNotEmpty()) {
                { IconButton(onClick = { onQueryChange("") }) { Icon(Icons.Filled.Clear, contentDescription = "Clear") } }
            } else null,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSubmitSearch() }),
            modifier = Modifier.width(220.dp),
        )
        MatchToggle(value = state.match, onChanged = onMatchChange)
        val camLabel = if (state.selectedCameraIds.size == state.cameras.size && state.cameras.isNotEmpty()) {
            "All cameras"
        } else {
            "${state.selectedCameraIds.size} of ${state.cameras.size} cameras"
        }
        TextButton(onClick = onPickCameras) {
            Icon(Icons.Filled.Videocam, contentDescription = null, modifier = Modifier.size(16.dp))
            Text(camLabel, modifier = Modifier.padding(start = 6.dp))
        }
        RangeSelector(hours = state.hours, onSelect = onHoursChange)
        TextButton(onClick = onPickWhen, enabled = state.hours != 0L) {
            Icon(Icons.Filled.Event, contentDescription = null, modifier = Modifier.size(16.dp))
            Text(
                state.anchorEndMs?.let { ms ->
                    runCatching { Time.dateTime(java.time.Instant.ofEpochMilli(ms)) }.getOrNull()
                } ?: "Jump to…",
                modifier = Modifier.padding(start = 6.dp),
            )
        }
        if (state.anchorEndMs != null && state.hours != 0L) {
            TextButton(onClick = onResetToNow) { Text("Now") }
        }
        if (!state.loading) {
            // The feed caps at 200 loaded reads (see PlatesViewModel.load), but the
            // server reports the full match count. When they differ, say "N of total"
            // so the grouped/timeline stats — computed only over the LOADED reads —
            // don't imply completeness for older reads past the cap (#147-3).
            val loaded = state.plates.size
            val label = if (loaded < state.total) {
                "$loaded of ${state.total} plates"
            } else {
                "${state.total} plate${if (state.total == 1) "" else "s"}"
            }
            Text(
                label,
                style = MaterialTheme.typography.bodySmall,
                color = TextSecondary,
            )
        }
    }
}

@Composable
private fun MatchToggle(value: String, onChanged: (String) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        listOf("exact" to "Exact", "contains" to "Contains", "fuzzy" to "Fuzzy").forEach { (v, label) ->
            FilterChip(
                selected = value == v,
                onClick = { onChanged(v) },
                label = { Text(label) },
            )
        }
    }
}

/** Compact "Last N" range dropdown for the Plates feed window. */
@Composable
private fun RangeSelector(hours: Long, onSelect: (Long) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val current = PLATES_RANGE_OPTIONS.firstOrNull { it.first == hours }?.second ?: "Last ${hours}h"
    Box {
        TextButton(onClick = { open = true }) { Text(current) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            PLATES_RANGE_OPTIONS.forEach { (h, label) ->
                DropdownMenuItem(
                    text = { Text(label) },
                    onClick = { open = false; onSelect(h) },
                )
            }
        }
    }
}

// ─── camera picker dialog ──────────────────────────────────────────────────────

/** Camera multi-select dialog with All / None shortcuts, mirroring the desktop
 *  client's `_CameraPickerDialog`. Returns the new selection via [onApply]. */
@Composable
private fun CameraPickerDialog(
    cameras: List<CameraDto>,
    selected: Set<String>,
    onApply: (Set<String>) -> Unit,
    onDismiss: () -> Unit,
) {
    var sel by remember { mutableStateOf(selected) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Cameras") },
        text = {
            Column {
                Row {
                    TextButton(onClick = { sel = cameras.map { it.id }.toSet() }) { Text("All") }
                    TextButton(onClick = { sel = emptySet() }) { Text("None") }
                }
                HorizontalDivider()
                // A plain scrollable Column (not LazyColumn) — this dialog's text slot
                // doesn't give a bounded max-height constraint, which LazyColumn requires.
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 320.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    cameras.forEach { cam ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    sel = if (sel.contains(cam.id)) sel - cam.id else sel + cam.id
                                }
                                .padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(
                                checked = sel.contains(cam.id),
                                onCheckedChange = { on ->
                                    sel = if (on) sel + cam.id else sel - cam.id
                                },
                            )
                            Text(cam.name)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { onApply(sel) }) { Text("Apply") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// ─── plate row + lazy snapshot ─────────────────────────────────────────────────

@Composable
private fun PlateRow(
    read: PlateRead,
    cameraName: String,
    mediaUrls: MediaUrls,
    onClick: () -> Unit,
    onReport: () -> Unit = {},
    showAddToWatchlist: Boolean = false,
    onAddToWatchlist: () -> Unit = {},
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PlateThumb(read = read, mediaUrls = mediaUrls, modifier = Modifier.size(width = 92.dp, height = 56.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = read.plate.ifEmpty { "—" },
                color = MaterialTheme.colorScheme.onSurface,
                fontWeight = FontWeight.Bold,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                style = MaterialTheme.typography.titleMedium,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.Videocam,
                    contentDescription = null,
                    tint = TextSecondary,
                    modifier = Modifier.size(13.dp),
                )
                Text(
                    text = cameraName,
                    color = TextSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    modifier = Modifier.padding(start = 4.dp),
                )
                val region = read.region
                if (!region.isNullOrEmpty()) {
                    // start-padding, not hardcoded leading spaces, so the gap sits on
                    // the correct side under RTL (#147-11).
                    Text(
                        text = region,
                        color = TextSecondary,
                        style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }
            }
            Text(
                text = runCatching { Time.dateTime(read.ts) }.getOrDefault(read.ts),
                color = TextSecondary,
                style = MaterialTheme.typography.labelSmall,
            )
        }
        ConfidenceChip(read.confidence)
        // Primary per-plate export: build an OpenALPR-style single-plate report.
        IconButton(onClick = onReport) {
            Icon(
                Icons.Filled.PictureAsPdf,
                contentDescription = "Plate report",
                tint = TextSecondary,
            )
        }
        if (showAddToWatchlist) {
            IconButton(onClick = onAddToWatchlist) {
                Icon(
                    Icons.Filled.PlaylistAdd,
                    contentDescription = "Add to watchlist",
                    tint = TextSecondary,
                )
            }
        }
    }
}

/** Decode ceiling (px) for plate-crop images. A plate is a small fraction of its
 *  snapshot, so without this Coil decodes the snapshot at the tiny thumbnail
 *  display size and the crop is a blurry upscale of a handful of pixels. Decoding
 *  to ~1024 first makes the crop sharp. Memory stays bounded: the decode is
 *  transient per image and Coil's memory cache holds only the (small) cropped
 *  result — not the full-size decode — so this fits the P2 bitmap budget. Used by
 *  both the list/grid thumbnails and the report-dialog preview. */
private const val PLATE_CROP_DECODE_PX = 1024

/** Convenience wrapper: the read's snapshot. Honors the "LPR thumbnail image" app
 *  option — the full vehicle snapshot (default) or cropped to the plate box.
 *  Decodes at [PLATE_CROP_DECODE_PX] so the cropped plate stays sharp at thumbnail
 *  size (harmless for the full-image mode, which just shows a crisp downscale). */
@Composable
private fun PlateThumb(read: PlateRead, mediaUrls: MediaUrls, modifier: Modifier = Modifier) {
    val showCrop = appContainer().store.lprImageMode != "vehicle"
    PlateSnapshotImage(
        read = read,
        mediaUrls = mediaUrls,
        modifier = modifier,
        crop = showCrop,
        decodePx = PLATE_CROP_DECODE_PX,
    )
}

/**
 * The read's snapshot: fetched from the sibling detection event's snapshot proxy
 * (scoped-token authed via [MediaUrls.eventSnapshotUrl]). Reads with no linked
 * event have no authed image source, so they show a placeholder.
 *
 * When [crop] is set and the read carries a [PlateRead.bbox], the plate region is
 * cropped **client-side** out of the already-loaded snapshot via
 * [PlateCropTransformation] (no extra network round-trip) and shown letterboxed
 * (`ContentScale.Fit`) so no plate characters are clipped. When the bbox is null
 * (older reads / no box) it falls back to the full snapshot, cropped to fill
 * (`ContentScale.Crop`) exactly as before.
 *
 * Memory: with [decodePx] null the snapshot decodes at the composable's display
 * size (the small thumbnails), and the crop runs on that bounded bitmap. The
 * report-dialog preview passes a bounded [decodePx] for a crisper crop.
 */
@Composable
private fun PlateSnapshotImage(
    read: PlateRead,
    mediaUrls: MediaUrls,
    modifier: Modifier = Modifier,
    crop: Boolean = true,
    decodePx: Int? = null,
) {
    val context = LocalContext.current
    var thumbUrl by remember(read.id) { mutableStateOf<String?>(null) }
    val eventId = read.eventId
    LaunchedEffect(read.id) {
        thumbUrl = if (!eventId.isNullOrBlank()) {
            runCatching { mediaUrls.eventSnapshotUrl(read.cameraId, eventId) }.getOrNull()
        } else {
            null
        }
    }
    Box(
        modifier = modifier
            .background(Color.Black, RoundedCornerShape(6.dp)),
        contentAlignment = Alignment.Center,
    ) {
        val url = thumbUrl
        if (url != null) {
            val bbox = read.bbox?.takeIf { it.size >= 4 }
            val cropping = crop && bbox != null
            // A plain URL is enough unless we need a crop transform or a decode
            // ceiling; only then build an ImageRequest.
            val model: Any = if (cropping || decodePx != null) {
                ImageRequest.Builder(context)
                    .data(url)
                    .apply {
                        decodePx?.let { size(it) }
                        if (crop) bbox?.let { transformations(PlateCropTransformation(it)) }
                    }
                    .build()
            } else {
                url
            }
            AsyncImage(
                model = model,
                contentDescription = null,
                // Fit for a plate crop (never clip characters); Crop to fill the box
                // for the full-snapshot fallback.
                contentScale = if (cropping) ContentScale.Fit else ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(
                Icons.Filled.CreditCard,
                contentDescription = null,
                tint = TextSecondary,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

@Composable
private fun ConfidenceChip(confidence: Float?) {
    val color: Color
    val text: String
    if (confidence == null) {
        color = TextSecondary
        text = "—"
    } else {
        val pct = (confidence * 100).roundToInt()
        color = when {
            confidence >= 0.85f -> Color(0xFF57C888)
            confidence >= 0.6f -> TimelineColors.playhead
            else -> Color(0xFFD65C5C)
        }
        text = "$pct%"
    }
    Box(
        modifier = Modifier
            .background(color.copy(alpha = 0.18f), RoundedCornerShape(12.dp))
            .border(1.dp, color.copy(alpha = 0.6f), RoundedCornerShape(12.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Text(text, color = color, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
    }
}

// ─── plate watchlist dialog ────────────────────────────────────────────────────

/**
 * Manage the LPR plate watchlist: the current entries (plate + label + a notify
 * indicator, each with a remove action for admins) plus, for admins, an add form
 * (plate field, optional label, notify toggle). Viewers see the list read-only —
 * the add/remove controls are gated on [isAdmin] — and the ViewModel still maps a
 * stale-role 403 to a friendly snackbar. Mirrors the CameraPickerDialog pattern
 * (a scrollable [Column], not a LazyColumn, since the dialog text slot gives no
 * bounded max-height).
 */
@Composable
private fun WatchlistDialog(
    state: PlatesUiState,
    isAdmin: Boolean,
    onAdd: (plate: String, label: String, notify: Boolean, kind: String) -> Unit,
    onRemove: (id: String) -> Unit,
    onFuzzChange: (Float) -> Unit,
    onDismiss: () -> Unit,
) {
    var plate by remember { mutableStateOf("") }
    var label by remember { mutableStateOf("") }
    var notify by remember { mutableStateOf(true) }
    // "watch" (alert on a sighting) vs "ignore" (suppress matching reads).
    var kind by remember { mutableStateOf(WATCHLIST_KIND_WATCH) }
    // The entry an admin tapped to edit (kind/label/notify), or null. Opens a
    // small chooser layered over this dialog; saving upserts via [onAdd] (#139).
    var editingEntry by remember { mutableStateOf<PlateWatchlistEntry?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Plate watchlist") },
        text = {
            Column {
                // Fuzziness slider — admin-only, backed by GET/PUT /config/lpr.
                if (isAdmin && state.lprConfig != null) {
                    FuzzinessSlider(
                        fuzz = state.lprConfig.watchlistFuzz,
                        plate = plate,
                        onFuzzChange = onFuzzChange,
                    )
                    HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                }
                if (isAdmin) {
                    TextField(
                        value = plate,
                        onValueChange = { plate = it },
                        placeholder = { Text("Plate") },
                        singleLine = true,
                        leadingIcon = { Icon(Icons.Filled.CreditCard, contentDescription = null) },
                        keyboardOptions = KeyboardOptions(
                            capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.Characters,
                            imeAction = ImeAction.Done,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    TextField(
                        value = label,
                        onValueChange = { label = it },
                        placeholder = { Text("Label (optional)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                    // Watch vs Ignore choice.
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FilterChip(
                            selected = kind == WATCHLIST_KIND_WATCH,
                            onClick = { kind = WATCHLIST_KIND_WATCH },
                            leadingIcon = { Icon(Icons.Filled.Star, contentDescription = null, modifier = Modifier.size(16.dp)) },
                            label = { Text("Watch") },
                        )
                        FilterChip(
                            selected = kind == WATCHLIST_KIND_IGNORE,
                            onClick = { kind = WATCHLIST_KIND_IGNORE },
                            leadingIcon = { Icon(Icons.Filled.Block, contentDescription = null, modifier = Modifier.size(16.dp)) },
                            label = { Text("Ignore") },
                        )
                    }
                    // "Notify on sighting" only applies to Watch entries.
                    if (kind == WATCHLIST_KIND_WATCH) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                "Notify on sighting",
                                color = MaterialTheme.colorScheme.onSurface,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            Spacer(Modifier.weight(1f))
                            Switch(checked = notify, onCheckedChange = { notify = it })
                        }
                    } else {
                        Text(
                            "Ignored plates are dropped on capture — never stored or alerted.",
                            color = TextSecondary,
                            style = MaterialTheme.typography.labelSmall,
                            modifier = Modifier.padding(top = 6.dp),
                        )
                    }
                    TextButton(
                        onClick = {
                            onAdd(plate, label, notify, kind)
                            plate = ""
                            label = ""
                            notify = true
                            kind = WATCHLIST_KIND_WATCH
                        },
                        enabled = plate.isNotBlank(),
                        modifier = Modifier.align(Alignment.End),
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                        Text("Add", modifier = Modifier.padding(start = 6.dp))
                    }
                    HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
                }
                when {
                    state.watchlistLoading && state.watchlist.isEmpty() ->
                        Row(
                            Modifier.fillMaxWidth().padding(16.dp),
                            horizontalArrangement = Arrangement.Center,
                        ) {
                            CircularProgressIndicator(color = TealAccent)
                        }
                    state.watchlistError != null ->
                        Text(
                            "Couldn't load watchlist: ${state.watchlistError}",
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.padding(vertical = 8.dp),
                        )
                    state.watchlist.isEmpty() ->
                        Text(
                            "No plates on the watchlist.",
                            color = TextSecondary,
                            modifier = Modifier.padding(vertical = 8.dp),
                        )
                    else ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 280.dp)
                                .verticalScroll(rememberScrollState()),
                        ) {
                            state.watchlist.forEach { entry ->
                                WatchlistRow(
                                    entry = entry,
                                    isAdmin = isAdmin,
                                    onEdit = { editingEntry = entry },
                                    onRemove = { onRemove(entry.id) },
                                )
                            }
                        }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )

    // Layered edit chooser for an existing entry (admin tap on a row / its edit
    // icon). Saving upserts through the same [onAdd] path, keyed on the normalized
    // plate server-side, so it replaces the entry rather than duplicating it (#139).
    editingEntry?.let { entry ->
        EditWatchlistEntryDialog(
            entry = entry,
            onSave = { newLabel, newNotify, newKind ->
                onAdd(entry.plate, newLabel, newNotify, newKind)
                editingEntry = null
            },
            onDismiss = { editingEntry = null },
        )
    }
}

/**
 * Edit an existing watchlist entry (#139): change its kind (watch/ignore), label,
 * and notify flag. The plate itself is the entry's normalized key and is shown
 * read-only; saving re-POSTs to `/lpr/watchlist`, which upserts on that key, so an
 * edit replaces the entry in place. Mirrors the desktop client's shared
 * Watch/Ignore chooser (`showWatchlistDialog` in `plates_screen.dart`).
 */
@Composable
private fun EditWatchlistEntryDialog(
    entry: PlateWatchlistEntry,
    onSave: (label: String, notify: Boolean, kind: String) -> Unit,
    onDismiss: () -> Unit,
) {
    var label by remember { mutableStateOf(entry.label ?: "") }
    var notify by remember { mutableStateOf(entry.notify) }
    var kind by remember {
        mutableStateOf(if (entry.isIgnore) WATCHLIST_KIND_IGNORE else WATCHLIST_KIND_WATCH)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit watchlist entry") },
        text = {
            Column {
                Text(
                    text = entry.plate.ifEmpty { "—" },
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.titleLarge,
                )
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    FilterChip(
                        selected = kind == WATCHLIST_KIND_WATCH,
                        onClick = { kind = WATCHLIST_KIND_WATCH },
                        leadingIcon = { Icon(Icons.Filled.Star, contentDescription = null, modifier = Modifier.size(16.dp)) },
                        label = { Text("Watch") },
                    )
                    FilterChip(
                        selected = kind == WATCHLIST_KIND_IGNORE,
                        onClick = { kind = WATCHLIST_KIND_IGNORE },
                        leadingIcon = { Icon(Icons.Filled.Block, contentDescription = null, modifier = Modifier.size(16.dp)) },
                        label = { Text("Ignore") },
                    )
                }
                TextField(
                    value = label,
                    onValueChange = { label = it },
                    placeholder = { Text("Label (optional)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
                // "Notify on sighting" only applies to Watch entries.
                if (kind == WATCHLIST_KIND_WATCH) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Notify on sighting",
                            color = MaterialTheme.colorScheme.onSurface,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Spacer(Modifier.weight(1f))
                        Switch(checked = notify, onCheckedChange = { notify = it })
                    }
                } else {
                    Text(
                        "Ignored plates are dropped on capture — never stored or alerted.",
                        color = TextSecondary,
                        style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(label, notify, kind) }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/**
 * Watchlist/ignore match fuzziness slider (admin-only). Maps the 0.0..0.5
 * `watchlist_fuzz` config value to a 0–50% control; commits on release via
 * [onFuzzChange] (a `PUT /config/lpr` that preserves enabled + retention). Seeds
 * its position from [fuzz] but tracks the drag locally so the thumb is smooth.
 *
 * As the slider moves (or the [plate] in the add field changes) it previews, live,
 * a few OCR misreads the current tolerance would still accept — computed by the
 * exact same normalize + Levenshtein + `floor(fuzz·len)` rule the server matches
 * on ([acceptedMisreadExamples]), so the preview is truthful. Matches the desktop
 * client and the admin console. When the add field is empty it illustrates on a
 * sample plate and invites the operator to type one to preview theirs (#140).
 */
@Composable
private fun FuzzinessSlider(
    fuzz: Float,
    plate: String,
    onFuzzChange: (Float) -> Unit,
) {
    // Local drag position, re-seeded whenever the persisted config value changes.
    var pos by remember(fuzz) { mutableFloatStateOf(fuzz.coerceIn(0f, 0.5f)) }
    val accent = TealAccent
    val faint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f)

    val typed = normalizePlate(plate)
    val usingSample = typed.isEmpty()
    val basis = if (usingSample) "7ABC123" else typed
    val allowed = allowedEdits(basis, pos)
    val examples = acceptedMisreadExamples(basis, allowed)

    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Watchlist match fuzziness",
                color = MaterialTheme.colorScheme.onSurface,
                style = MaterialTheme.typography.bodyMedium,
            )
            Spacer(Modifier.weight(1f))
            Text(
                if (allowed == 0) {
                    "Exact"
                } else {
                    "${(pos * 100).roundToInt()}% · up to $allowed char${if (allowed == 1) "" else "s"}"
                },
                color = if (allowed == 0) TextSecondary else accent,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Slider(
            value = pos,
            onValueChange = { pos = it },
            valueRange = 0f..0.5f,
            onValueChangeFinished = { onFuzzChange(pos) },
        )
        if (allowed == 0) {
            Text(
                "Exact match only. A single misread character will not match.",
                color = TextSecondary,
                style = MaterialTheme.typography.labelSmall,
            )
        } else {
            Text(
                if (usingSample) {
                    "Tolerates up to $allowed misread character${if (allowed == 1) "" else "s"}. " +
                        "Example on a sample plate — type a plate above to preview yours:"
                } else {
                    "Tolerates up to $allowed misread character${if (allowed == 1) "" else "s"} on this plate. " +
                        "Would still match:"
                },
                color = TextSecondary,
                style = MaterialTheme.typography.labelSmall,
            )
            if (examples.isNotEmpty()) {
                FlowRow(
                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    examples.forEach { MisreadChip(basis = basis, candidate = it, accent = accent, base = faint) }
                }
            }
        }
    }
}

/** A pill showing an accepted misread [candidate], with the character(s) that
 *  differ from [basis] highlighted in the [accent] colour (the rest in [base]). */
@Composable
private fun MisreadChip(basis: String, candidate: String, accent: Color, base: Color) {
    val text = buildAnnotatedString {
        for (i in candidate.indices) {
            val changed = i >= basis.length || candidate[i] != basis[i]
            withStyle(
                SpanStyle(
                    color = if (changed) accent else base,
                    fontWeight = if (changed) FontWeight.ExtraBold else FontWeight.Medium,
                ),
            ) {
                append(candidate[i])
            }
        }
    }
    Box(
        modifier = Modifier
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(4.dp))
            .border(1.dp, MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(4.dp))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    ) {
        Text(
            text = text,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

@Composable
private fun WatchlistRow(
    entry: PlateWatchlistEntry,
    isAdmin: Boolean,
    onEdit: () -> Unit,
    onRemove: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            // Admins can tap the row to edit it (parity with the desktop client);
            // viewers see it read-only.
            .then(if (isAdmin) Modifier.clickable(onClick = onEdit) else Modifier)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Optional per-entry accent swatch (`#rrggbb`); skipped if unset/unparseable.
        val swatch = entry.color?.let { hex ->
            runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrNull()
        }
        if (swatch != null) {
            Box(
                modifier = Modifier
                    .size(12.dp)
                    .background(swatch, RoundedCornerShape(3.dp)),
            )
        }
        Column(Modifier.weight(1f)) {
            Text(
                text = entry.plate,
                color = MaterialTheme.colorScheme.onSurface,
                fontWeight = FontWeight.Bold,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                style = MaterialTheme.typography.titleSmall,
            )
            val label = entry.label
            if (!label.isNullOrBlank()) {
                Text(
                    text = label,
                    color = TextSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                )
            }
        }
        if (entry.isIgnore) {
            // Ignore entries suppress reads rather than alert — show a distinct
            // indicator instead of the notify bell.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(
                    imageVector = Icons.Filled.Block,
                    contentDescription = "Ignored plate",
                    tint = TextSecondary,
                    modifier = Modifier.size(18.dp),
                )
                Text("Ignored", color = TextSecondary, style = MaterialTheme.typography.labelSmall)
            }
        } else {
            Icon(
                imageVector = if (entry.notify) Icons.Filled.Notifications else Icons.Filled.NotificationsOff,
                contentDescription = if (entry.notify) "Notifies on sighting" else "Notifications off",
                tint = if (entry.notify) TealAccent else TextSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
        if (isAdmin) {
            IconButton(onClick = onEdit) {
                Icon(
                    Icons.Filled.Edit,
                    contentDescription = "Edit watchlist entry",
                    tint = TextSecondary,
                )
            }
            IconButton(onClick = onRemove) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = "Remove from watchlist",
                    tint = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

// ─── single-plate report builder dialog ────────────────────────────────────────

/**
 * A short list of common IANA zones offered by the report builder's timezone
 * picker, in addition to the device-local zone (which is prepended and used as
 * the default). Mirrors OpenALPR's single-plate export, which lets the operator
 * render the sighting's timestamps in a chosen zone rather than only device-local.
 */
private val REPORT_COMMON_ZONES: List<String> = listOf(
    "UTC",
    "America/Los_Angeles",
    "America/Denver",
    "America/Chicago",
    "America/New_York",
    "America/Sao_Paulo",
    "Europe/London",
    "Europe/Paris",
    "Europe/Berlin",
    "Europe/Moscow",
    "Asia/Dubai",
    "Asia/Kolkata",
    "Asia/Shanghai",
    "Asia/Tokyo",
    "Australia/Sydney",
)

/**
 * Builder for the single-plate report: a timezone picker (defaulting to
 * device-local) and a toggle for the sighting dossier — then "Download PDF"
 * (which builds the report and hands it to the system share sheet). Mirrors the
 * [WatchlistDialog]/[CameraPickerDialog] pattern.
 */
@Composable
private fun PlateReportDialog(
    read: PlateRead,
    mediaUrls: MediaUrls,
    generating: Boolean,
    onDownload: (zoneId: java.time.ZoneId, includeDossier: Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    var includeDossier by remember { mutableStateOf(true) }
    val defaultZone = remember { java.time.ZoneId.systemDefault().id }
    // Device-local first (the default), then the curated common set, de-duplicated.
    val zones = remember(defaultZone) { (listOf(defaultZone) + REPORT_COMMON_ZONES).distinct() }
    var zoneId by remember { mutableStateOf(defaultZone) }
    var zoneMenuOpen by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = { if (!generating) onDismiss() },
        title = { Text("Plate report") },
        text = {
            Column {
                // Prominent plate crop (the same client-side bbox crop the report's
                // "PLATE (zoomed)" image uses), with a bounded decode so a small
                // plate region stays crisp; falls back to the full snapshot when the
                // read has no bbox.
                PlateSnapshotImage(
                    read = read,
                    mediaUrls = mediaUrls,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    crop = true,
                    decodePx = PLATE_CROP_DECODE_PX,
                )
                Text(
                    text = read.plate.ifEmpty { "—" },
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.Bold,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.padding(top = 8.dp),
                )
                // Timezone picker.
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Timezone",
                        color = MaterialTheme.colorScheme.onSurface,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(Modifier.weight(1f))
                    Box {
                        TextButton(onClick = { zoneMenuOpen = true }) { Text(zoneId) }
                        DropdownMenu(expanded = zoneMenuOpen, onDismissRequest = { zoneMenuOpen = false }) {
                            zones.forEach { z ->
                                DropdownMenuItem(
                                    text = { Text(z) },
                                    onClick = { zoneMenuOpen = false; zoneId = z },
                                )
                            }
                        }
                    }
                }
                // Dossier toggle.
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            "Sighting history",
                            color = MaterialTheme.colorScheme.onSurface,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Text(
                            "Include a dossier of every sighting of this plate.",
                            color = TextSecondary,
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                    Switch(checked = includeDossier, onCheckedChange = { includeDossier = it })
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onDownload(java.time.ZoneId.of(zoneId), includeDossier) },
                enabled = !generating,
            ) {
                if (generating) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = TealAccent, strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Filled.PictureAsPdf, contentDescription = null, modifier = Modifier.size(16.dp))
                    Text("Download PDF", modifier = Modifier.padding(start = 6.dp))
                }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !generating) { Text("Cancel") } },
    )
}
