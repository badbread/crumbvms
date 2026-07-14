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
import video.crumb.app.data.LprConfigDto
import video.crumb.app.data.PlateRead
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

/**
 * How the Plates feed renders its reads. Persisted across sessions via
 * [video.crumb.app.data.SecureStore.platesViewMode] (keyed on [storageKey]).
 */
enum class PlatesViewMode(val storageKey: String) {
    /** Dense one-line rows (the original view). */
    LIST("list"),
    /** A grid of snapshot cards. */
    GALLERY("gallery"),
    /** Collapsed by normalized plate: one expandable row per unique plate. */
    GROUPED("grouped"),
    /** Big touch-friendly chronological rows, newest first. */
    TIMELINE("timeline"),
    ;

    companion object {
        /** Parse a stored [storageKey] back to a mode; unknown/null → [LIST]. */
        fun fromKey(key: String?): PlatesViewMode =
            entries.firstOrNull { it.storageKey == key } ?: LIST
    }
}

data class PlatesUiState(
    val loading: Boolean = false,
    val error: String? = null,
    val cameras: List<CameraDto> = emptyList(),
    /** Defaults to every visible camera once [cameras] loads — the natural
     *  "show me everything" starting point for a plate log. */
    val selectedCameraIds: Set<String> = emptySet(),
    val query: String = "",
    /** "exact" | "contains" | "fuzzy" — only meaningful when [query] is non-blank. */
    val match: String = "contains",
    val hours: Long = 24,
    /** Anchor end-of-window (epoch millis); null = window ends "now". */
    val anchorEndMs: Long? = null,
    val plates: List<PlateRead> = emptyList(),
    val total: Int = 0,
    /** LPR plate watchlist (management surface). Loaded lazily when the watchlist
     *  sheet opens and re-loaded after every add/remove. */
    val watchlist: List<PlateWatchlistEntry> = emptyList(),
    val watchlistLoading: Boolean = false,
    val watchlistError: String? = null,
    /** Current render mode for the reads list. Seeded from persisted preference. */
    val viewMode: PlatesViewMode = PlatesViewMode.LIST,
    /** Platform LPR config (admin-only). Loaded when the watchlist sheet opens;
     *  null until loaded or when the caller isn't an admin (403). Backs the
     *  fuzziness slider and lets a fuzz edit preserve enabled + retention_days. */
    val lprConfig: LprConfigDto? = null,
    val lprConfigLoading: Boolean = false,
    /** One-shot user-facing message (add/remove result, or the admin-only 403
     *  notice) — the screen shows it in a snackbar then calls [PlatesViewModel.consumeMessage]. */
    val message: String? = null,
)

/**
 * Loads the `GET /plates` feed (license-plate reads) for the Plates tab.
 * Mirrors the desktop client's `_PlatesScreenState` behavior: newest-first
 * results, a debounced free-text search, a match-mode toggle, a camera
 * multi-select (defaulting to all), and an hours-window with an optional
 * jump-to anchor.
 */
class PlatesViewModel(private val repo: CrumbRepository) : ViewModel() {
    private val _state = MutableStateFlow(PlatesUiState())
    val state: StateFlow<PlatesUiState> = _state.asStateFlow()

    /** Debounces the network reload while the user is still typing a search. */
    private var searchJob: Job? = null

    init {
        // Restore the persisted render mode before the first frame.
        _state.update { it.copy(viewMode = PlatesViewMode.fromKey(repo.store.platesViewMode)) }
        loadCameras()
    }

    /** Switch the reads render mode and persist it (survives app restarts). */
    fun setViewMode(mode: PlatesViewMode) {
        if (mode == _state.value.viewMode) return
        repo.store.platesViewMode = mode.storageKey
        _state.update { it.copy(viewMode = mode) }
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

    /** Clear the one-shot [PlatesUiState.message] once the screen has shown it. */
    fun consumeMessage() {
        _state.update { it.copy(message = null) }
    }

    /** 403 → the friendly admin-only notice; anything else → its user message. */
    private fun watchlistErrorMessage(e: Throwable): String =
        if (e.isForbidden()) "Only admins can manage the watchlist." else e.toUserMessage()

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
                }
                .onFailure { e ->
                    _state.update { it.copy(loading = false, error = e.toUserMessage()) }
                }
        }
    }
}
