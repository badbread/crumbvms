// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import video.crumb.app.data.CameraDto
import video.crumb.app.data.CrumbRepository
import video.crumb.app.data.DEFAULT_REGULAR_MIN_READS_30D
import video.crumb.app.data.LprConfigDto
import video.crumb.app.data.PlateAliasDto
import video.crumb.app.data.PlateRead
import video.crumb.app.data.PlateStatsDto
import video.crumb.app.data.PlateSuggestionsResponse
import video.crumb.app.data.PlateWatchlistEntry
import video.crumb.app.data.WATCHLIST_KIND_WATCH
import video.crumb.app.data.isForbidden
import video.crumb.app.data.toUserMessage
import video.crumb.app.ui.Time
import java.time.Instant

/**
 * Time-range presets in hours; `0` is the "all time" sentinel (no start/end
 * sent to the server). Mirrors the desktop Plates tab's `_rangeOptions`
 * exactly (`apps/desktop-flutter/lib/ui/plates/plates_screen.dart`).
 */
val PLATES_RANGE_OPTIONS: List<Pair<Long, String>> = listOf(
    0L to "All time",
    1L to "1 hour",
    6L to "6 hours",
    24L to "24 hours",
    72L to "3 days",
    168L to "7 days",
    720L to "30 days",
)

/** Plain-language label for a range in hours (used by the filter chips). */
fun rangeLabel(hours: Long): String =
    PLATES_RANGE_OPTIONS.firstOrNull { it.first == hours }?.second ?: "Last $hours hours"

/**
 * How the Plates feed renders its reads. Persisted across sessions via
 * [video.crumb.app.data.SecureStore.platesViewMode] (keyed on [storageKey]).
 * The old Timeline view duplicated List and was removed; a stored "timeline"
 * falls back to [LIST].
 */
enum class PlatesViewMode(val storageKey: String, val label: String) {
    /** Two-line rows with an aspect-true plate crop. */
    LIST("list", "List"),
    /** A two-column grid of snapshot cards. */
    GALLERY("gallery", "Gallery"),
    /** Collapsed by normalized plate: one row per unique plate. */
    GROUPED("grouped", "Grouped by plate"),
    ;

    companion object {
        /** Parse a stored [storageKey] back to a mode; unknown/null/legacy → [LIST]. */
        fun fromKey(key: String?): PlatesViewMode =
            entries.firstOrNull { it.storageKey == key } ?: LIST
    }
}

/** State of the "Correct plate" sheet (admin-only); null when closed. */
data class PlateCorrectionUi(
    /** The normalized plate being corrected (the suspected misread). */
    val plate: String,
    val loading: Boolean = true,
    val suggestions: PlateSuggestionsResponse? = null,
    /** True when the server predates plate corrections (404/405). */
    val unsupported: Boolean = false,
    val saving: Boolean = false,
    val error: String? = null,
)

data class PlatesUiState(
    val loading: Boolean = false,
    val error: String? = null,
    val cameras: List<CameraDto> = emptyList(),
    /** Defaults to every visible camera once [cameras] loads — the natural
     *  "show me everything" starting point for a plate log. */
    val selectedCameraIds: Set<String> = emptySet(),
    val query: String = "",
    /** "exact" | "contains" | "fuzzy" — only meaningful when [query] is non-blank. */
    val match: String = DEFAULT_MATCH,
    val hours: Long = DEFAULT_RANGE_HOURS,
    /** Anchor end-of-window (epoch millis); null = window ends "now". */
    val anchorEndMs: Long? = null,
    val plates: List<PlateRead> = emptyList(),
    val total: Int = 0,
    /** LPR plate watchlist. Loaded quietly with the feed (stars and rails) and
     *  re-loaded after every add/remove. */
    val watchlist: List<PlateWatchlistEntry> = emptyList(),
    val watchlistLoading: Boolean = false,
    val watchlistError: String? = null,
    /** Current render mode for the reads list. Seeded from persisted preference. */
    val viewMode: PlatesViewMode = PlatesViewMode.LIST,
    /** "Hide regulars": persisted, applied client-side from [stats]. */
    val hideRegulars: Boolean = false,
    /** "Merge duplicates": repeat reads of one pass become one row. Persisted. */
    val mergeDuplicates: Boolean = true,
    /** History of the plates on screen, keyed by normalized plate. */
    val stats: Map<String, PlateStatsDto> = emptyMap(),
    /** The server's "regular" threshold, from the last stats response. */
    val regularMinReads: Int = DEFAULT_REGULAR_MIN_READS_30D,
    /** IANA zone the stats' hour and day buckets are in; blank = unknown. */
    val statsTz: String = "",
    /** Platform LPR config (admin-only). Loaded when the watchlist sheet opens;
     *  null until loaded or when the caller isn't an admin (403). Backs the
     *  fuzziness slider and lets a fuzz edit preserve enabled + retention_days. */
    val lprConfig: LprConfigDto? = null,
    val lprConfigLoading: Boolean = false,
    /** Open "Correct plate" sheet, or null. */
    val correction: PlateCorrectionUi? = null,
    /** One-shot user-facing message (add/remove result, or the admin-only 403
     *  notice) — the screen shows it in a snackbar then calls [PlatesViewModel.consumeMessage]. */
    val message: String? = null,
    /** When set, the [message] snackbar offers Undo, which deletes this alias. */
    val messageUndoAlias: String? = null,
) {
    /** Plates on the alert watchlist (ignore entries do not count as watched). */
    val watchedPlates: Set<String> get() = watchlist.filter { !it.isIgnore }.map { it.plate }.toSet()

    /** The reads the list shows after Hide regulars; Merge duplicates is applied by the screen. */
    fun visibleReads(): List<PlateRead> =
        if (hideRegulars) {
            val watched = watchedPlates
            withoutRegularReads(plates, { it in watched }, { stats[it] }, regularMinReads)
        } else {
            plates
        }
}

/** State of the plate profile screen; null in [PlatesViewModel.profile] when closed. */
data class PlateProfileState(
    /** The normalized plate the profile is about. */
    val plate: String,
    /** The read the profile was opened from; the video starts here. */
    val focus: PlateRead,
    /** The read the video is currently anchored on (changes when a visit is tapped). */
    val selected: PlateRead,
    val loading: Boolean = true,
    val error: String? = null,
    val visits: List<PlateVisit> = emptyList(),
    val stats: PlateStatsDto? = null,
    val aliases: List<PlateAliasDto> = emptyList(),
    /** The resolved name, once reads have loaded (falls back to the focus read's). */
    val displayName: String? = null,
)

/**
 * Loads the `GET /plates` feed (license-plate reads) for the Plates tab, plus the
 * plate-desk extras on top: per-plate history for "Hide regulars" and the NEW
 * tags, the watchlist for stars, the plate profile, and the admin-only name /
 * correction actions.
 *
 * Mirrors the desktop client's `_PlatesScreenState`: newest-first results, a
 * debounced free-text search, a match-mode toggle, a camera multi-select
 * (defaulting to all), and an hours-window with an optional jump-to anchor.
 */
class PlatesViewModel(private val repo: CrumbRepository) : ViewModel() {
    private val _state = MutableStateFlow(PlatesUiState())
    val state: StateFlow<PlatesUiState> = _state.asStateFlow()

    private val _profile = MutableStateFlow<PlateProfileState?>(null)

    /** The open plate profile, or null while the list is showing. */
    val profile: StateFlow<PlateProfileState?> = _profile.asStateFlow()

    /** Debounces the network reload while the user is still typing a search. */
    private var searchJob: Job? = null

    /** Latest profile load, so a stale one can't overwrite a newer plate. */
    private var profileJob: Job? = null

    /** Switch the reads render mode and persist it (survives app restarts). */
    fun setViewMode(mode: PlatesViewMode) {
        if (mode == _state.value.viewMode) return
        repo.store.platesViewMode = mode.storageKey
        _state.update { it.copy(viewMode = mode) }
    }

    /** Toggle "Hide regulars" and persist it. Purely client-side. */
    fun setHideRegulars(on: Boolean) {
        if (on == _state.value.hideRegulars) return
        repo.store.platesHideRegulars = on
        _state.update { it.copy(hideRegulars = on) }
    }

    /** Toggle "Merge duplicates" and persist it. Purely client-side. */
    fun setMergeDuplicates(on: Boolean) {
        if (on == _state.value.mergeDuplicates) return
        repo.store.platesMergeDuplicates = on
        _state.update { it.copy(mergeDuplicates = on) }
    }

    private fun loadCameras() {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            repo.visibleCameras()
                .onSuccess { list ->
                    val enabled = list.filter { it.enabled }
                    _state.update {
                        it.copy(cameras = enabled, selectedCameraIds = enabled.map { c -> c.id }.toSet())
                    }
                    load()
                }
                .onFailure { e ->
                    _state.update { it.copy(loading = false, error = e.toUserMessage()) }
                }
        }
    }

    /** Search box text changed — debounced (350ms) so every keystroke doesn't
     *  trigger a network round-trip; matches the desktop client's timing. */
    fun setQuery(q: String) {
        _state.update { it.copy(query = q) }
        searchJob?.cancel()
        searchJob = viewModelScope.launch {
            delay(350)
            load()
        }
    }

    /** IME "search" action / explicit submit — load immediately, skipping the debounce. */
    fun submitSearch() {
        searchJob?.cancel()
        load()
    }

    fun setMatch(match: String) {
        if (match == _state.value.match) return
        _state.update { it.copy(match = match) }
        if (_state.value.query.isNotBlank()) load()
    }

    fun setHours(hours: Long) {
        if (hours == _state.value.hours) return
        _state.update { it.copy(hours = hours) }
        load()
    }

    /** Jump-to-time picker result; null resets to "Now". */
    fun setAnchorEnd(ms: Long?) {
        _state.update { it.copy(anchorEndMs = ms) }
        load()
    }

    fun setSelectedCameras(ids: Set<String>) {
        _state.update { it.copy(selectedCameraIds = ids) }
        load()
    }

    /** Put one filter back to its default (tapping a chip in the strip). */
    fun clearFilter(kind: FilterKind) {
        when (kind) {
            FilterKind.CAMERAS -> setSelectedCameras(_state.value.cameras.map { it.id }.toSet())
            FilterKind.RANGE -> setHours(DEFAULT_RANGE_HOURS)
            FilterKind.ENDS_AT -> setAnchorEnd(null)
            FilterKind.MATCH -> setMatch(DEFAULT_MATCH)
            FilterKind.HIDE_REGULARS -> setHideRegulars(false)
        }
    }

    /** Reset every filter to its default in one go (the sheet's Reset). */
    fun resetFilters() {
        val s = _state.value
        if (s.hideRegulars) setHideRegulars(false)
        val allCams = s.cameras.map { it.id }.toSet()
        _state.update {
            it.copy(
                selectedCameraIds = allCams,
                hours = DEFAULT_RANGE_HOURS,
                anchorEndMs = null,
                match = DEFAULT_MATCH,
            )
        }
        load()
    }

    fun refresh() {
        searchJob?.cancel()
        load()
    }

    // ── LPR plate watchlist ──────────────────────────────────────────────────────

    /** (Re)load the plate watchlist — call when the management sheet opens. */
    fun loadWatchlist() {
        viewModelScope.launch {
            _state.update { it.copy(watchlistLoading = true, watchlistError = null) }
            repo.watchlist()
                .onSuccess { list ->
                    _state.update { it.copy(watchlistLoading = false, watchlist = list) }
                }
                .onFailure { e ->
                    _state.update { it.copy(watchlistLoading = false, watchlistError = e.toUserMessage()) }
                }
        }
    }

    /**
     * Add [plate] to the watchlist (admin-only server-side). On success reloads
     * the list and posts a confirmation; a 403 posts the friendly admin-only
     * notice rather than surfacing a raw error. A blank [plate] is a no-op.
     */
    fun addToWatchlist(
        plate: String,
        label: String? = null,
        notify: Boolean = true,
        kind: String = WATCHLIST_KIND_WATCH,
    ) {
        val p = plate.trim()
        if (p.isBlank()) return
        viewModelScope.launch {
            repo.addWatchlist(plate = p, label = label, notify = notify, kind = kind)
                .onSuccess { entry ->
                    val verb = if (entry.isIgnore) "Ignoring" else "Added"
                    val suffix = if (entry.isIgnore) "." else " to the watchlist."
                    _state.update { it.copy(message = "$verb ${entry.plate}$suffix") }
                    loadWatchlist()
                }
                .onFailure { e ->
                    _state.update { it.copy(message = watchlistErrorMessage(e)) }
                }
        }
    }

    // ── LPR config (fuzziness; admin-only) ───────────────────────────────────────

    /**
     * Load the platform LPR config (admin-only). Called when the watchlist sheet
     * opens; a non-admin caller's 403 is swallowed silently (the fuzz slider is
     * simply not shown) rather than surfaced as an error. Leaves [PlatesUiState.lprConfig]
     * null on any failure.
     */
    fun loadLprConfig() {
        viewModelScope.launch {
            _state.update { it.copy(lprConfigLoading = true) }
            repo.lprConfig()
                .onSuccess { cfg ->
                    _state.update { it.copy(lprConfigLoading = false, lprConfig = cfg) }
                }
                .onFailure {
                    // 403 (non-admin) or older server → just hide the slider.
                    _state.update { it.copy(lprConfigLoading = false, lprConfig = null) }
                }
        }
    }

    /**
     * Persist a new watchlist [fuzz] (0.0..0.5), preserving the current enabled +
     * retention_days (the PUT replaces all three). Admin-only; a 403 posts the
     * friendly admin-only notice. No-op until [loadLprConfig] has populated the
     * baseline config.
     */
    fun setWatchlistFuzz(fuzz: Float) {
        val cfg = _state.value.lprConfig ?: return
        val clamped = fuzz.coerceIn(0f, 0.5f)
        viewModelScope.launch {
            repo.updateLprConfig(
                enabled = cfg.enabled,
                retentionDays = cfg.retentionDays,
                watchlistFuzz = clamped,
            )
                .onSuccess { updated ->
                    _state.update { it.copy(lprConfig = updated) }
                }
                .onFailure { e ->
                    _state.update { it.copy(message = watchlistErrorMessage(e)) }
                }
        }
    }

    /** Remove a watchlist entry by id (admin-only server-side). */
    fun removeFromWatchlist(id: String) {
        viewModelScope.launch {
            repo.deleteWatchlist(id)
                .onSuccess {
                    _state.update { it.copy(message = "Removed from the watchlist.") }
                    loadWatchlist()
                }
                .onFailure { e ->
                    _state.update { it.copy(message = watchlistErrorMessage(e)) }
                }
        }
    }

    /** Remove [plate] from the watchlist, if it is on it (the star toggle). */
    fun removePlateFromWatchlist(plate: String) {
        val entry = _state.value.watchlist.firstOrNull { it.plate == plate && !it.isIgnore } ?: return
        removeFromWatchlist(entry.id)
    }

    /** Clear the one-shot [PlatesUiState.message] once the screen has shown it. */
    fun consumeMessage() {
        _state.update { it.copy(message = null, messageUndoAlias = null) }
    }

    /** 403 → the friendly admin-only notice; anything else → its user message. */
    private fun watchlistErrorMessage(e: Throwable): String =
        if (e.isForbidden()) "Only admins can manage the watchlist." else e.toUserMessage()

    // ── plate names (admin) ──────────────────────────────────────────────────────

    /** Name [plate] (blank [label] clears the name). Admin-only server-side. */
    fun renamePlate(plate: String, label: String) {
        val p = plate.trim()
        if (p.isBlank()) return
        viewModelScope.launch {
            val clearing = label.isBlank()
            val result = if (clearing) repo.clearPlateLabel(p) else repo.setPlateLabel(p, label)
            result
                .onSuccess {
                    _state.update {
                        it.copy(message = if (clearing) "Name cleared." else "Named $p ${label.trim()}.")
                    }
                    load()
                    reloadProfile()
                }
                .onFailure { e ->
                    _state.update {
                        it.copy(
                            message = if (e.isForbidden()) "Only admins can name plates." else e.toUserMessage(),
                        )
                    }
                }
        }
    }

    // ── plate corrections (admin) ────────────────────────────────────────────────

    /** Open the "Correct plate" sheet for [plate] and load the likely matches. */
    fun openCorrection(plate: String) {
        val p = plate.trim()
        if (p.isBlank()) return
        _state.update { it.copy(correction = PlateCorrectionUi(plate = p)) }
        viewModelScope.launch {
            repo.plateAliasSuggestions(p)
                .onSuccess { resp ->
                    _state.update { s ->
                        s.copy(correction = s.correction?.takeIf { it.plate == p }?.copy(loading = false, suggestions = resp) ?: s.correction)
                    }
                }
                .onFailure { e ->
                    val missing = (e as? retrofit2.HttpException)?.code().let { it == 404 || it == 405 }
                    _state.update { s ->
                        s.copy(
                            correction = s.correction?.takeIf { it.plate == p }?.copy(
                                loading = false,
                                unsupported = missing,
                                error = if (missing) null else e.toUserMessage(),
                            ) ?: s.correction,
                        )
                    }
                }
        }
    }

    fun closeCorrection() {
        _state.update { it.copy(correction = null) }
    }

    /**
     * Save "reads of the open plate count as [target]". On success the sheet
     * closes, a snackbar offers Undo, and the list (and an open profile) reload.
     */
    fun submitCorrection(target: String) {
        val c = _state.value.correction ?: return
        val to = normalizePlateInput(target)
        if (to.isEmpty() || to == c.plate || c.saving) return
        _state.update { it.copy(correction = c.copy(saving = true, error = null)) }
        viewModelScope.launch {
            repo.createPlateAlias(c.plate, to)
                .onSuccess { created ->
                    val saved = created.alias
                    _state.update {
                        it.copy(
                            correction = null,
                            message = "${saved.aliasPlate} now counts as ${saved.canonicalPlate}.",
                            messageUndoAlias = saved.aliasPlate,
                        )
                    }
                    // An open profile on the misread moves to the real plate.
                    val p = _profile.value
                    if (p != null && p.plate == saved.aliasPlate) {
                        _profile.update { cur ->
                            cur?.copy(plate = saved.canonicalPlate, focus = plateReadAs(cur.focus, saved.canonicalPlate), selected = plateReadAs(cur.selected, saved.canonicalPlate))
                        }
                    }
                    load()
                    reloadProfile()
                }
                .onFailure { e ->
                    val msg = when ((e as? retrofit2.HttpException)?.code()) {
                        403 -> "Only admins can correct plates."
                        400 -> "Enter a different plate to correct it to."
                        404, 405 -> "This server cannot correct plates yet. Update it."
                        else -> e.toUserMessage()
                    }
                    _state.update { it.copy(correction = it.correction?.copy(saving = false, error = msg)) }
                }
        }
    }

    /** Undo a correction by its misread string (the snackbar Undo, or the profile's misreads list). */
    fun undoCorrection(alias: String) {
        viewModelScope.launch {
            repo.deletePlateAlias(alias)
                .onSuccess {
                    _state.update { it.copy(message = "$alias counts as itself again.") }
                    load()
                    reloadProfile()
                }
                .onFailure { e ->
                    _state.update {
                        it.copy(message = if (e.isForbidden()) "Only admins can correct plates." else e.toUserMessage())
                    }
                }
        }
    }

    // ── plate profile ────────────────────────────────────────────────────────────

    /** Open the profile for [read]'s plate; the video starts on this read. */
    fun openProfile(read: PlateRead) {
        if (read.plate.isBlank()) return
        _profile.value = PlateProfileState(plate = read.plate, focus = read, selected = read, displayName = read.displayName)
        reloadProfile()
    }

    fun closeProfile() {
        profileJob?.cancel()
        _profile.value = null
    }

    /** Pick a visit in the profile: the video swaps to that visit's best read. */
    fun selectProfileRead(read: PlateRead) {
        _profile.update { it?.copy(selected = read) }
    }

    private fun reloadProfile() {
        val p = _profile.value ?: return
        val plate = p.plate
        profileJob?.cancel()
        profileJob = viewModelScope.launch {
            _profile.update { it?.copy(loading = true, error = null) }
            val cams = _state.value.cameras.map { it.id }
            // History + misreads load alongside the visits; each lands on its own.
            launch {
                repo.plateStats(listOf(plate)).onSuccess { b ->
                    _profile.update { cur ->
                        cur?.takeIf { it.plate == plate }?.copy(stats = b.byPlate[plate])
                    }
                    _state.update { s ->
                        s.copy(
                            stats = s.stats + b.byPlate,
                            regularMinReads = b.regularMinReads30d,
                            statsTz = b.tz.ifBlank { s.statsTz },
                        )
                    }
                }
            }
            launch {
                repo.plateAliases(plate).onSuccess { list ->
                    _profile.update { cur ->
                        cur?.takeIf { it.plate == plate }?.copy(aliases = list.filter { it.canonicalPlate == plate })
                    }
                }
            }
            repo.plates(cameraIds = cams, query = plate, match = "exact", limit = 200)
                .onSuccess { page ->
                    val visits = collapseVisits(page.plates)
                    _profile.update { cur ->
                        if (cur == null || cur.plate != plate) {
                            cur
                        } else {
                            val name = page.plates.firstOrNull { !it.displayName.isNullOrBlank() }?.displayName
                            cur.copy(
                                loading = false,
                                visits = visits,
                                displayName = name ?: cur.displayName?.takeIf { page.plates.isEmpty() },
                            )
                        }
                    }
                }
                .onFailure { e ->
                    _profile.update { cur ->
                        cur?.takeIf { it.plate == plate }?.copy(loading = false, error = e.toUserMessage())
                    }
                }
        }
    }

    // ── feed ─────────────────────────────────────────────────────────────────────

    private fun load() {
        val s = _state.value
        val ids = s.cameras.filter { s.selectedCameraIds.contains(it.id) }.map { it.id }
        if (ids.isEmpty()) {
            _state.update { it.copy(loading = false, error = null, plates = emptyList(), total = 0) }
            return
        }
        val startIso: String?
        val endIso: String?
        if (s.hours <= 0L) {
            startIso = null
            endIso = null
        } else {
            val end = s.anchorEndMs?.let { Instant.ofEpochMilli(it) } ?: Instant.now()
            val start = end.minusSeconds(s.hours * 3600)
            startIso = Time.iso(start)
            endIso = Time.iso(end)
        }
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            repo.plates(
                cameraIds = ids,
                startIso = startIso,
                endIso = endIso,
                query = s.query,
                match = s.match,
                limit = 200,
            )
                .onSuccess { page ->
                    // Guarantee newest-first regardless of server ordering.
                    val sorted = page.plates.sortedByDescending {
                        runCatching { Time.parseToMillis(it.ts) }.getOrDefault(0L)
                    }
                    _state.update { it.copy(loading = false, plates = sorted, total = page.total) }
                    loadStats(sorted.map { it.plate })
                }
                .onFailure { e ->
                    _state.update { it.copy(loading = false, error = e.toUserMessage()) }
                }
        }
    }

    /**
     * History for the plates now on screen (Hide regulars, NEW tags, rails). Best
     * effort: an older server without the endpoint, or any failure, just leaves
     * the extras off and never shows an error.
     */
    private fun loadStats(plates: List<String>) {
        val wanted = plates.filter { it.isNotBlank() }.distinct()
        if (wanted.isEmpty()) return
        viewModelScope.launch {
            repo.plateStats(wanted).onSuccess { b ->
                _state.update {
                    it.copy(
                        stats = it.stats + b.byPlate,
                        regularMinReads = b.regularMinReads30d,
                        statsTz = b.tz.ifBlank { it.statsTz },
                    )
                }
            }
        }
    }

    // Kept LAST: this block calls methods that touch the properties above, and a
    // Kotlin init block runs in declaration order, so every property they read
    // must already be initialized.
    init {
        _state.update {
            it.copy(
                viewMode = PlatesViewMode.fromKey(repo.store.platesViewMode),
                hideRegulars = repo.store.platesHideRegulars,
                mergeDuplicates = repo.store.platesMergeDuplicates,
            )
        }
        loadCameras()
        loadWatchlist()
    }
}
