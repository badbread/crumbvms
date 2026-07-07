// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.clips

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import video.crumb.app.data.ClipDescriptor
import video.crumb.app.data.CrumbRepository
import java.time.Instant

data class ClipsUiState(
    val loading: Boolean = false,
    val clips: List<ClipDescriptor> = emptyList(),
    val type: String = "all",
    val hours: Long = 24,
    val error: String? = null,
    /** Server-configured motion-highlight auto-zoom duration (seconds; 0 = off). */
    val motionHighlightSeconds: Int = 0,
)

/** Loads the source-abstracted `/clips` feed for the Clips tab. */
class ClipsViewModel(private val repo: CrumbRepository) : ViewModel() {
    private val _state = MutableStateFlow(ClipsUiState())
    val state: StateFlow<ClipsUiState> = _state.asStateFlow()

    init { load() }

    fun setType(type: String) {
        if (type == _state.value.type) return
        _state.update { it.copy(type = type) }
        load()
    }

    fun setHours(hours: Long) {
        if (hours == _state.value.hours) return
        _state.update { it.copy(hours = hours) }
        load()
    }

    fun refresh() = load()

    /** Bookmark a clip's moment (its camera + start time) into the shared
     *  cross-camera bookmarks. Protection is whatever the shared Add-bookmark
     *  dialog returned (null when the user left it off). Best-effort. */
    fun bookmarkClip(
        cameraId: String,
        tsIso: String,
        description: String,
        protectDays: Int?,
        protectPreSeconds: Int?,
        protectPostSeconds: Int?,
    ) {
        viewModelScope.launch {
            repo.addBookmark(cameraId, tsIso, description, protectDays, protectPreSeconds, protectPostSeconds)
        }
    }

    /** Mark a clip watched (server + optimistic local dim) when the user opens it. */
    fun markViewed(id: String) {
        if (_state.value.clips.firstOrNull { it.id == id }?.viewed == true) return
        _state.update { s -> s.copy(clips = s.clips.map { if (it.id == id) it.copy(viewed = true) else it }) }
        viewModelScope.launch { repo.markClipViewed(id) }
    }

    private fun load() {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            val cams = repo.cameras().getOrDefault(emptyList()).map { it.id }
            if (cams.isEmpty()) {
                _state.update { it.copy(loading = false, clips = emptyList()) }
                return@launch
            }
            val end = Instant.now()
            val start = end.minusSeconds(_state.value.hours * 3600)
            repo.clips(cams, start.toString(), end.toString(), _state.value.type)
                .onSuccess { r ->
                    _state.update {
                        it.copy(
                            loading = false,
                            clips = r.clips,
                            motionHighlightSeconds = r.motionHighlightSeconds,
                        )
                    }
                }
                .onFailure { e -> _state.update { it.copy(loading = false, error = e.message ?: "Failed to load clips") } }
        }
    }
}
