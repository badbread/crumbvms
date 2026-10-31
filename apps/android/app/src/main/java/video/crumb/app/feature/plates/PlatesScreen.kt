// SPDX-License-Identifier: AGPL-3.0-or-later

@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package video.crumb.app.feature.plates

import video.crumb.app.ui.staggerIn
import video.crumb.app.ui.StateMessage
import video.crumb.app.ui.SkeletonRows
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.foundation.lazy.itemsIndexed
import android.content.res.Configuration
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.withStyle
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
import video.crumb.app.ui.theme.LprAccent
import video.crumb.app.ui.theme.LprAccentHot
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.TextSecondary
import java.io.File
import java.time.Instant
import kotlin.math.roundToInt

/** One entry in the list view: a day header or a read row. */
private sealed interface ListEntry {
    val key: String

    data class Header(val label: String) : ListEntry {
        override val key: String get() = "h:$label"
    }

    data class Row(val data: PlateRowData, val timeLabel: String) : ListEntry {
        override val key: String get() = "r:${data.read.id}"
    }
}

/**
 * The Plates tab (LPR): a newest-first browser of license-plate reads.
 *
 * Mirrors the desktop client's Plates tab (`apps/desktop-flutter/lib/ui/plates/`)
 * but laid out for a phone: a search bar and ONE filter sheet (no control rows),
 * calm two-line rows with an aspect-true plate crop, long-press for actions, and
 * a full-screen plate profile (video, visits, history, details) on tap.
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
    val profile by vm.profile.collectAsStateWithLifecycle()
    val mediaUrls = remember { container.mediaUrls() }
    val store = container.store
    val caps = store.capabilities
    val isAdmin = store.isAdmin
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val isLandscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE

    var showFilters by remember { mutableStateOf(false) }
    var showJump by remember { mutableStateOf(false) }
    var showWatchlist by remember { mutableStateOf(false) }
    // The plate a "quick add to watchlist" was tapped for — opens a small chooser
    // asking watch (alert) vs ignore (drop) before adding. Null = chooser closed.
    var addKindForPlate by remember { mutableStateOf<String?>(null) }
    // The row whose long-press peek is open.
    var peek by remember { mutableStateOf<PlateRowData?>(null) }
    // (plate, current name) while the Name / Rename dialog is open.
    var renameFor by remember { mutableStateOf<Pair<String, String?>?>(null) }
    // The single plate a report is being built for (opens the builder dialog), plus
    // an in-flight guard so the dialog can show a spinner + block re-taps.
    var reportFor by remember { mutableStateOf<PlateRead?>(null) }
    var generatingReport by remember { mutableStateOf(false) }
    // The just-generated report PDF (app-private cache file). Non-null opens the
    // post-generate actions sheet: Open (view now) / Save to Downloads / Share.
    var reportActionsFile by remember { mutableStateOf<File?>(null) }
    // Platform-wide bookmarks toggle (server /status.bookmarks_enabled): hide the
    // profile's bookmark control when the admin disabled bookmarks. Defaults on.
    var bookmarksEnabled by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        container.repository.status().onSuccess { bookmarksEnabled = it.bookmarksEnabled }
    }
    val snackbarHostState = remember { SnackbarHostState() }
    // Hoisted so the list keeps its scroll position while a profile is open over it.
    val listState = rememberLazyListState()
    val gridState = rememberLazyGridState()

    // System back closes the profile first, then leaves the screen as usual.
    BackHandler(enabled = profile != null) { vm.closeProfile() }

    // Surface the ViewModel's one-shot messages (add/remove result, admin-only
    // 403 notice, correction + Undo) in a snackbar, then clear so it doesn't
    // re-show on recomposition.
    LaunchedEffect(state.message) {
        val msg = state.message
        if (msg != null) {
            val undo = state.messageUndoAlias
            val result = snackbarHostState.showSnackbar(
                message = msg,
                actionLabel = if (undo != null) "Undo" else null,
                duration = if (undo != null) SnackbarDuration.Long else SnackbarDuration.Short,
            )
            vm.consumeMessage()
            if (result == SnackbarResult.ActionPerformed && undo != null) vm.undoCorrection(undo)
        }
    }

    val camNames = remember(state.cameras) { state.cameras.associate { it.id to it.name } }

    // Put the RAW plate on the clipboard (see plateCopyText) and confirm it,
    // except where the platform already confirms for us.
    val onCopy: (PlateRead) -> Unit = { p ->
        val text = plateCopyText(p)
        if (text == null) {
            scope.launch { snackbarHostState.showSnackbar("This read has no plate text to copy.") }
        } else {
            clipboard.setText(AnnotatedString(text))
            if (!systemConfirmsClipboardWrite(Build.VERSION.SDK_INT)) {
                scope.launch { snackbarHostState.showSnackbar("Copied $text") }
            }
        }
    }
    val openInPlayback: (PlateRead) -> Unit = { p ->
        val ms = runCatching { Time.parseToMillis(p.ts) }.getOrNull()
        if (ms != null) onOpenPlateAt(p.cameraId, ms)
    }

    // Derived list data: Hide regulars, then Merge duplicates, then row decoration.
    val visibleReads = remember(state.plates, state.hideRegulars, state.stats, state.regularMinReads, state.watchlist) {
        state.visibleReads()
    }
    val watchedSet = state.watchedPlates
    val nowMs = remember(state.plates) { System.currentTimeMillis() }
    fun decorate(read: PlateRead, count: Int): PlateRowData {
        val st = state.stats[read.plate]
        return PlateRowData(
            read = read,
            cameraName = camNames[read.cameraId] ?: "Unknown camera",
            watched = read.plate in watchedSet,
            rail = plateRail(read.plate in watchedSet, st, state.regularMinReads),
            isNew = st?.isNewPlate() == true,
            passCount = count,
        )
    }
    val rows: List<PlateRowData> = remember(visibleReads, state.mergeDuplicates, state.viewMode, state.stats, state.watchlist, camNames, state.regularMinReads) {
        if (state.viewMode == PlatesViewMode.GROUPED) {
            groupByPlate(visibleReads).map { decorate(it.latest, it.count) }
        } else if (state.mergeDuplicates) {
            collapsePlateReads(visibleReads).map { decorate(it.representative, it.count) }
        } else {
            visibleReads.map { decorate(it, 1) }
        }
    }

    val chips = activeFilterChips(
        cameraNames = camNames,
        selected = state.selectedCameraIds,
        hours = state.hours,
        anchorEndMs = state.anchorEndMs,
        anchorLabel = state.anchorEndMs?.let { runCatching { Time.dateTime(Instant.ofEpochMilli(it)) }.getOrNull() },
        match = state.match,
        hideRegulars = state.hideRegulars,
        rangeLabel = ::rangeLabel,
    )

    val searchBar: @Composable (Modifier, Boolean) -> Unit = { mod, compact ->
        PlatesSearchBar(
            query = state.query,
            onQueryChange = { vm.setQuery(it) },
            onSubmit = { vm.submitSearch() },
            activeFilters = activeFilterCount(chips),
            onOpenFilters = { showFilters = true },
            onWatchlist = { showWatchlist = true; vm.loadWatchlist(); vm.loadLprConfig() },
            onRefresh = { vm.refresh() },
            modifier = mod,
            compact = compact,
        )
    }

    Scaffold(
        containerColor = NavyDeep,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            // The profile is its own full screen with its own top bar.
            if (profile == null) {
                TopAppBar(
                    title = {
                        // In LANDSCAPE the phone is short, so — like Clips — the search and
                        // filter controls ride inline in the top bar next to the mode tabs.
                        if (isLandscape) {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                                PlatesModeTabs(onOpenLive, onOpenPlayback, onOpenClips, caps.playback || store.isAdmin, caps.clips || store.isAdmin)
                                Box(
                                    Modifier
                                        .padding(horizontal = 10.dp)
                                        .width(1.dp)
                                        .height(24.dp)
                                        .background(Color(0xFF2E313A)),
                                )
                                searchBar(Modifier.weight(1f).padding(end = 8.dp), true)
                            }
                        } else {
                            PlatesModeTabs(onOpenLive, onOpenPlayback, onOpenClips, caps.playback || store.isAdmin, caps.clips || store.isAdmin)
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = NavyDeep),
                )
            }
        },
    ) { pad ->
        val p = profile
        if (p != null) {
            PlateProfileScreen(
                profile = p,
                cameraNames = camNames,
                repo = container.repository,
                mediaUrls = mediaUrls,
                isAdmin = isAdmin,
                watchEntry = state.watchlist.firstOrNull { it.plate == p.plate },
                regularMinReads = state.regularMinReads,
                statsTz = state.statsTz,
                bookmarksEnabled = bookmarksEnabled,
                actions = PlateProfileActions(
                    onBack = { vm.closeProfile() },
                    onSelectVisit = { vm.selectProfileRead(it) },
                    onToggleWatch = {
                        val existing = state.watchlist.firstOrNull { it.plate == p.plate && !it.isIgnore }
                        if (existing != null) vm.removeFromWatchlist(existing.id) else vm.addToWatchlist(p.plate, kind = WATCHLIST_KIND_WATCH)
                    },
                    onCopy = { onCopy(p.selected) },
                    onRename = { renameFor = p.plate to p.displayName },
                    onCorrect = { vm.openCorrection(p.plate) },
                    onReport = { reportFor = it },
                    onOpenPlayback = openInPlayback,
                    onUndoAlias = { vm.undoCorrection(it) },
                    onAddBookmark = { cameraId, atMs, desc, days, pre, post ->
                        scope.launch {
                            container.repository.addBookmark(
                                cameraId,
                                Time.iso(Instant.ofEpochMilli(atMs)),
                                desc,
                                protectDays = days,
                                protectPreSeconds = pre,
                                protectPostSeconds = post,
                            ).onSuccess {
                                Toast.makeText(context, "Bookmark added", Toast.LENGTH_SHORT).show()
                            }.onFailure {
                                snackbarHostState.showSnackbar("Couldn't add bookmark")
                            }
                        }
                    },
                ),
                modifier = Modifier.padding(pad),
            )
        } else {
            Column(Modifier.padding(pad).fillMaxSize()) {
                if (!isLandscape) {
                    searchBar(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 8.dp), false)
                }
                ActiveFilterStrip(chips = chips, onClear = { vm.clearFilter(it) })
                Box(Modifier.fillMaxSize()) {
                    when {
                        // R2: row-shaped shimmers while the first page loads.
                        state.loading && state.plates.isEmpty() -> SkeletonRows(count = 7)
                        state.error != null -> StateMessage(
                            icon = Icons.Filled.ErrorOutline,
                            title = "Can't load plates",
                            body = state.error,
                            actionLabel = "Retry",
                            onAction = { vm.refresh() },
                            accent = LprAccent,
                            modifier = Modifier.align(Alignment.Center),
                        )
                        state.plates.isEmpty() -> StateMessage(
                            icon = Icons.Filled.Search,
                            title = "No plate reads in this window",
                            accent = LprAccent,
                            modifier = Modifier.align(Alignment.Center),
                        )
                        rows.isEmpty() -> StateMessage(
                            icon = Icons.Filled.Search,
                            title = "Only regulars in this window",
                            body = "Turn off Hide regulars in Filters to see them.",
                            accent = LprAccent,
                            modifier = Modifier.align(Alignment.Center),
                        )
                        else -> {
                            val footer = if (state.plates.size < state.total) {
                                "Showing the latest ${state.plates.size} of ${state.total} reads. Narrow the time range to see older ones."
                            } else {
                                null
                            }
                            when (state.viewMode) {
                                PlatesViewMode.LIST -> PlatesListView(
                                    rows = rows,
                                    nowMs = nowMs,
                                    mediaUrls = mediaUrls,
                                    footer = footer,
                                    listState = listState,
                                    onOpen = { vm.openProfile(it.read) },
                                    onPeek = { peek = it },
                                )
                                PlatesViewMode.GALLERY -> PlatesGalleryView(
                                    rows = rows,
                                    nowMs = nowMs,
                                    mediaUrls = mediaUrls,
                                    footer = footer,
                                    gridState = gridState,
                                    onOpen = { vm.openProfile(it.read) },
                                    onPeek = { peek = it },
                                )
                                PlatesViewMode.GROUPED -> PlatesGroupedView(
                                    rows = rows,
                                    nowMs = nowMs,
                                    mediaUrls = mediaUrls,
                                    footer = footer,
                                    listState = listState,
                                    onOpen = { vm.openProfile(it.read) },
                                    onPeek = { peek = it },
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // ── sheets and dialogs ────────────────────────────────────────────────────

    if (showFilters) {
        val hidden = state.plates.size - visibleReads.size
        PlatesFilterSheet(
            sheet = PlatesFilterSheetState(
                cameras = state.cameras.sortedBy { it.name.lowercase() }.map { it.id to it.name },
                selectedCameraIds = state.selectedCameraIds,
                hours = state.hours,
                anchorEndMs = state.anchorEndMs,
                anchorLabel = state.anchorEndMs?.let { runCatching { Time.dateTime(Instant.ofEpochMilli(it)) }.getOrNull() },
                match = state.match,
                viewMode = state.viewMode,
                hideRegulars = state.hideRegulars,
                mergeDuplicates = state.mergeDuplicates,
                anyActive = chips.isNotEmpty(),
                footer = if (state.loading) "" else feedSummary(visibleReads.size, state.plates.size, state.total, hidden),
                watchlistCount = state.watchlist.size,
            ),
            onCameras = { vm.setSelectedCameras(it) },
            onHours = { vm.setHours(it) },
            onPickEndsAt = { showJump = true },
            onResetEndsAt = { vm.setAnchorEnd(null) },
            onMatch = { vm.setMatch(it) },
            onViewMode = { vm.setViewMode(it) },
            onHideRegulars = { vm.setHideRegulars(it) },
            onMergeDuplicates = { vm.setMergeDuplicates(it) },
            onReset = { vm.resetFilters() },
            onWatchlist = {
                showFilters = false
                showWatchlist = true
                vm.loadWatchlist()
                vm.loadLprConfig()
            },
            onDismiss = { showFilters = false },
        )
    }
    if (showJump) {
        JumpToDateTimeDialog(
            initialMs = state.anchorEndMs ?: System.currentTimeMillis(),
            onDismiss = { showJump = false },
            onPicked = { ms -> vm.setAnchorEnd(ms); showJump = false },
        )
    }

    peek?.let { item ->
        PlatePeek(
            item = item,
            mediaUrls = mediaUrls,
            timeLabel = rowTimeLabel(Time.parseToMillis(item.read.ts), System.currentTimeMillis()),
            isAdmin = isAdmin,
            onCopy = { onCopy(item.read) },
            onWatch = {
                if (item.watched) vm.removePlateFromWatchlist(item.read.plate) else addKindForPlate = item.read.plate
            },
            onCorrect = { vm.openCorrection(item.read.plate) },
            onReport = { reportFor = item.read },
            onPlayback = { openInPlayback(item.read) },
            onDismiss = { peek = null },
        )
    }

    state.correction?.let { ui ->
        PlateCorrectionSheet(
            ui = ui,
            onSubmit = { vm.submitCorrection(it) },
            onDismiss = { vm.closeCorrection() },
        )
    }

    renameFor?.let { (plate, current) ->
        RenamePlateDialog(
            plate = plate,
            current = current,
            onSave = { name -> vm.renamePlate(plate, name); renameFor = null },
            onDismiss = { renameFor = null },
        )
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
                val camNamesForReport = state.cameras.associate { it.id to it.name }
                val allCamIds = state.cameras.map { it.id }
                val loader = context.imageLoader
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
                        cameraNames = camNamesForReport,
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
                        // Don't auto-fire the share sheet (the operator often just
                        // wants to VIEW or SAVE the report, not send it). Offer all
                        // three deliveries in a follow-up sheet instead.
                        .onSuccess { file -> reportActionsFile = file }
                        .onFailure { snackbarHostState.showSnackbar("Couldn't build the plate report.") }
                }
            },
            onDismiss = { if (!generatingReport) reportFor = null },
        )
    }

    // Post-generate deliveries: Open (view now in a PDF viewer), Save to Downloads
    // (a durable copy the Files app can find), or Share. Replaces the old
    // share-only behavior, which left the operator with no way to just view or
    // keep the report on the phone.
    val actionsFile = reportActionsFile
    if (actionsFile != null) {
        PlateReportActionsDialog(
            onOpen = {
                val launched = openPlatesPdf(context, actionsFile)
                reportActionsFile = null
                if (!launched) {
                    scope.launch {
                        snackbarHostState.showSnackbar(
                            "No PDF viewer is installed. Try Save to Downloads or Share instead.",
                        )
                    }
                }
            },
            onSave = {
                reportActionsFile = null
                scope.launch {
                    savePlateReportToDownloads(context, actionsFile)
                        .onSuccess { location ->
                            val res = snackbarHostState.showSnackbar(
                                message = "Saved to $location",
                                actionLabel = "Open",
                                duration = SnackbarDuration.Long,
                            )
                            if (res == SnackbarResult.ActionPerformed) {
                                // The public-Downloads copy isn't a FileProvider
                                // path; open the still-present cache original, which
                                // is byte-identical, through the reports provider.
                                if (!openPlatesPdf(context, actionsFile)) {
                                    snackbarHostState.showSnackbar("No PDF viewer is installed.")
                                }
                            }
                        }
                        .onFailure { e ->
                            snackbarHostState.showSnackbar("Couldn't save to Downloads: ${e.message}")
                        }
                }
            },
            onShare = {
                sharePlatesPdf(context, actionsFile)
                reportActionsFile = null
            },
            onDismiss = { reportActionsFile = null },
        )
    }
}

/** The shared mode-tab row with LPR selected. */
@Composable
private fun PlatesModeTabs(
    onOpenLive: () -> Unit,
    onOpenPlayback: () -> Unit,
    onOpenClips: () -> Unit,
    showPlayback: Boolean,
    showClips: Boolean,
) {
    CrumbModeTabs(
        selected = CrumbMode.PLATES,
        onLive = onOpenLive,
        onPlayback = onOpenPlayback,
        onClips = onOpenClips,
        onPlates = {},
        showPlayback = showPlayback,
        showClips = showClips,
        showPlates = true,
    )
}

// ─── reads views (list / gallery / grouped) ─────────────────────────────────

/** Two-line rows under date headers. */
@Composable
private fun PlatesListView(
    rows: List<PlateRowData>,
    nowMs: Long,
    mediaUrls: MediaUrls,
    footer: String?,
    listState: LazyListState,
    onOpen: (PlateRowData) -> Unit,
    onPeek: (PlateRowData) -> Unit,
) {
    val entries = remember(rows, nowMs) {
        buildList {
            var day: java.time.LocalDate? = null
            rows.forEach { r ->
                val ms = Time.parseToMillis(r.read.ts)
                val d = dayKey(ms)
                if (d != day) {
                    day = d
                    add(ListEntry.Header(dayLabel(ms, nowMs)))
                }
                add(ListEntry.Row(r, rowTimeLabel(ms, nowMs)))
            }
        }
    }
    LazyColumn(Modifier.fillMaxSize(), state = listState) {
        itemsIndexed(entries, key = { _, e -> e.key }) { index, e ->
            when (e) {
                is ListEntry.Header -> PlateDayHeader(e.label)
                is ListEntry.Row -> PlateListRow(
                    item = e.data,
                    mediaUrls = mediaUrls,
                    timeLabel = e.timeLabel,
                    onClick = { onOpen(e.data) },
                    onLongClick = { onPeek(e.data) },
                    // R1: rows stagger in on first load; reorders animate in place.
                    modifier = Modifier.animateItem().staggerIn(index),
                )
            }
        }
        footer?.let { item { ListFooter(it) } }
    }
}

/** Two-column cards: the frame with the aspect-true crop inset. */
@Composable
private fun PlatesGalleryView(
    rows: List<PlateRowData>,
    nowMs: Long,
    mediaUrls: MediaUrls,
    footer: String?,
    gridState: LazyGridState,
    onOpen: (PlateRowData) -> Unit,
    onPeek: (PlateRowData) -> Unit,
) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 168.dp),
        state = gridState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        gridItems(rows, key = { it.read.id }) { r ->
            PlateGalleryCard(
                item = r,
                mediaUrls = mediaUrls,
                timeLabel = rowTimeLabel(Time.parseToMillis(r.read.ts), nowMs),
                onClick = { onOpen(r) },
                onLongClick = { onPeek(r) },
            )
        }
        footer?.let { item(span = { GridItemSpan(maxLineSpan) }) { ListFooter(it) } }
    }
}

/** One row per plate, newest first, with how many reads it has in range. Tap opens the profile. */
@Composable
private fun PlatesGroupedView(
    rows: List<PlateRowData>,
    nowMs: Long,
    mediaUrls: MediaUrls,
    footer: String?,
    listState: LazyListState,
    onOpen: (PlateRowData) -> Unit,
    onPeek: (PlateRowData) -> Unit,
) {
    LazyColumn(Modifier.fillMaxSize(), state = listState) {
        items(rows, key = { it.read.plate.ifEmpty { "(none)" } }) { r ->
            PlateGroupListRow(
                item = r,
                count = r.passCount,
                mediaUrls = mediaUrls,
                timeLabel = rowTimeLabel(Time.parseToMillis(r.read.ts), nowMs),
                onClick = { onOpen(r) },
                onLongClick = { onPeek(r) },
            )
        }
        footer?.let { item { ListFooter(it) } }
    }
}

@Composable
private fun ListFooter(text: String) {
    Text(
        text,
        color = TextSecondary,
        style = MaterialTheme.typography.bodySmall,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 16.dp),
    )
}

// ─── name / rename dialog ───────────────────────────────────────────────────

/** Name a plate (admin-only server-side). Saving a blank name clears it. */
@Composable
private fun RenamePlateDialog(
    plate: String,
    current: String?,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var name by remember(plate) { mutableStateOf(current.orEmpty()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (current.isNullOrBlank()) "Name this plate" else "Rename plate") },
        text = {
            Column {
                Text(plate, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, color = TextSecondary)
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it.take(60) },
                    label = { Text("Name") },
                    placeholder = { Text("For example, Mom's car") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
                Text(
                    "Naming a plate does not set up alerts. Use the watchlist for that.",
                    color = TextSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(name) }, enabled = name.isNotBlank() || !current.isNullOrBlank()) {
                Text(if (name.isBlank()) "Clear name" else "Save")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// ─── plate primary label (name over raw plate) ─────────────────────────────────

/**
 * The primary label for a plate. When the server resolved a human-readable
 * [displayName] (e.g. "Mom's car") it becomes the prominent line, styled with
 * [nameStyle], with the raw [plate] shown small and monospaced beneath it.
 * When [displayName] is null/blank the raw [plate] is rendered exactly as before
 * (bold monospace at [nameStyle]); the fallback is the plate text, never a dash
 * in place of a name.
 */
@Composable
private fun PlateLabel(
    displayName: String?,
    plate: String,
    nameStyle: TextStyle,
    modifier: Modifier = Modifier,
    /**
     * When non-null, a small copy button is drawn beside the RAW plate text —
     * on the plate line in both layouts, so what the button copies is never
     * ambiguous even when a name is the prominent line. Suppressed for a read
     * with no plate text, where there would be nothing to copy.
     */
    onCopy: (() -> Unit)? = null,
) {
    val copy = onCopy?.takeIf { plate.isNotBlank() }
    val name = displayName?.takeIf { it.isNotBlank() }
    if (name == null) {
        Row(modifier, verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = plate.ifEmpty { "No plate" },
                color = MaterialTheme.colorScheme.onSurface,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                style = nameStyle,
                maxLines = 1,
                modifier = Modifier.weight(1f, fill = false),
            )
            PlateCopyButton(copy)
        }
    } else {
        Column(modifier) {
            Text(
                text = name,
                color = MaterialTheme.colorScheme.onSurface,
                fontWeight = FontWeight.Bold,
                style = nameStyle,
                maxLines = 1,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = plate.ifEmpty { "No plate" },
                    color = TextSecondary,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    modifier = Modifier.weight(1f, fill = false),
                )
                PlateCopyButton(copy)
            }
        }
    }
}

/**
 * The copy-the-plate affordance: a small icon button beside the raw plate text.
 * A visible control rather than a long-press-only gesture, so an operator can
 * see the plate is copyable; it is compact enough to sit in the dense list row
 * and the gallery card alike. Renders nothing when [onCopy] is null.
 */
@Composable
private fun PlateCopyButton(onCopy: (() -> Unit)?) {
    if (onCopy == null) return
    IconButton(onClick = onCopy, modifier = Modifier.size(32.dp)) {
        Icon(
            Icons.Filled.ContentCopy,
            contentDescription = "Copy plate number",
            tint = TextSecondary,
            modifier = Modifier.size(16.dp),
        )
    }
}

/**
 * What a copy action puts on the clipboard for a plate read: always the RAW
 * plate string, never the operator-assigned display name, even when the name is
 * what the row shows most prominently. The name is a local label; the raw plate
 * is the value that matches the read elsewhere (search, reports, other systems).
 * Returns null when there is nothing to copy (a read with no plate text).
 */
internal fun plateCopyText(read: PlateRead): String? = read.plate.trim().takeIf { it.isNotEmpty() }

/**
 * Whether the platform shows its own confirmation when an app writes to the
 * clipboard. Android 13 (API 33) added a system clipboard-write panel, so an
 * in-app snackbar on top of it would be a duplicate confirmation; below 33 there
 * is no system feedback and the snackbar is the only thing the operator sees.
 */
internal fun systemConfirmsClipboardWrite(sdkInt: Int): Boolean = sdkInt >= Build.VERSION_CODES.TIRAMISU


/** Decode ceiling (px) for plate-crop images. A plate is a small fraction of its
 *  snapshot, so without this Coil decodes the snapshot at the tiny thumbnail
 *  display size and the crop is a blurry upscale of a handful of pixels. Decoding
 *  to ~1024 first makes the crop sharp. Memory stays bounded: the decode is
 *  transient per image and Coil's memory cache holds only the (small) cropped
 *  result — not the full-size decode — so this fits the P2 bitmap budget. Used by
 *  both the list/grid thumbnails and the report-dialog preview. */
private const val PLATE_CROP_DECODE_PX = 1024

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
                            "Ignored plates are dropped on capture. They are never stored or alerted on.",
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
                            CircularProgressIndicator(color = LprAccent)
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
                PlateLabel(
                    displayName = entry.displayName,
                    plate = entry.plate,
                    nameStyle = MaterialTheme.typography.titleLarge,
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
                        "Ignored plates are dropped on capture. They are never stored or alerted on.",
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
    val accent = LprAccent
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
                        "Example on a sample plate. Type a plate above to preview yours:"
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
            PlateLabel(
                displayName = entry.displayName,
                plate = entry.plate,
                nameStyle = MaterialTheme.typography.titleSmall,
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
                tint = if (entry.notify) LprAccent else TextSecondary,
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
                PlateLabel(
                    displayName = read.displayName,
                    plate = read.plate,
                    nameStyle = MaterialTheme.typography.titleLarge,
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
                            "List every sighting (date/time and camera). Pictures stay capped.",
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
                    CircularProgressIndicator(Modifier.size(18.dp), color = LprAccent, strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Filled.PictureAsPdf, contentDescription = null, modifier = Modifier.size(16.dp))
                    Text("Download PDF", modifier = Modifier.padding(start = 6.dp))
                }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !generating) { Text("Cancel") } },
    )
}

/**
 * Post-generate delivery chooser for a finished plate report. The old flow fired
 * the system share sheet automatically, which left an operator who "just wants to
 * view it on my phone" with no way to open or keep the report. This offers the
 * three obvious choices as a stacked action row:
 *  - **Open** — view it right now in the device's default PDF viewer.
 *  - **Save to Downloads** — a durable copy the Files app can find.
 *  - **Share** — the original system share sheet.
 */
@Composable
private fun PlateReportActionsDialog(
    onOpen: () -> Unit,
    onSave: () -> Unit,
    onShare: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Filled.PictureAsPdf, contentDescription = null) },
        title = { Text("Report ready") },
        text = {
            Column {
                Text(
                    "View it now, save a copy to your Downloads folder, or share it.",
                    color = TextSecondary,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(12.dp))
                ReportActionButton(
                    icon = Icons.Filled.Visibility,
                    label = "Open",
                    onClick = onOpen,
                )
                ReportActionButton(
                    icon = Icons.Filled.Download,
                    label = "Save to Downloads",
                    onClick = onSave,
                )
                ReportActionButton(
                    icon = Icons.Filled.Share,
                    label = "Share",
                    onClick = onShare,
                )
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

/** One full-width action in the [PlateReportActionsDialog] (icon + label). */
@Composable
private fun ReportActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        Text(
            label,
            modifier = Modifier
                .weight(1f)
                .padding(start = 12.dp),
        )
    }
}

