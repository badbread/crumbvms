// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import video.crumb.app.di.appContainer

/**
 * The app-wide "are the on-video Home Assistant badges shown" flag — the state
 * behind the eye quick-toggle that appears BOTH on the Live wall's action row and
 * in the fullscreen view's top-right controls.
 *
 * It lives in [video.crumb.app.di.AppContainer] (one instance per process) rather
 * than in either screen's `remember`, because the two toggles must be the same
 * switch: the Live wall stays on the nav back stack while the user is inside a
 * camera, so a per-screen `remember` seeded from the store would keep serving the
 * pre-toggle value after the fullscreen button flipped it, and the wall's icon
 * would lie. Observers collect [visible], so a flip from either surface
 * recomposes both immediately — no restart, no re-entry.
 *
 * Purely a DISPLAY switch: hiding the overlays removes the badges (and with them
 * their tap/long-press targets) from the video, and nothing else. Entity links,
 * badge placement, the per-camera entities sheet, and the detail/control popups
 * reachable from it are untouched — inspecting entities must keep working
 * precisely when an operator has decided the video should stay clean.
 *
 * @param initial seed value, read once from [video.crumb.app.data.SecureStore.showHaOverlays].
 * @param persist writes an actual change back to the store (so it survives restarts).
 *   Injected rather than taking the store directly so this stays a plain, testable
 *   unit with no Android dependencies.
 */
class HaOverlayVisibility(
    initial: Boolean,
    private val persist: (Boolean) -> Unit,
) {

    private val _visible = MutableStateFlow(initial)

    /** `true` = on-video HA badges are drawn; `false` = every badge is hidden. */
    val visible: StateFlow<Boolean> = _visible.asStateFlow()

    /**
     * Set the flag, persisting only a real change (a no-op set must not spend an
     * [android.content.SharedPreferences] write — this is called from recomposing
     * UI, and the encrypted store re-encrypts on every write).
     */
    fun set(value: Boolean) {
        if (_visible.value == value) return
        _visible.value = value
        persist(value)
    }

    /** Flip the flag — what both eye buttons call. */
    fun toggle() = set(!_visible.value)
}

/**
 * Live [State]<Boolean> for the shared [HaOverlayVisibility]. Read this in any
 * composable that draws (or offers to hide) the on-video HA badges; call
 * `appContainer().haOverlays.toggle()` to flip it.
 */
@Composable
fun rememberHaOverlaysVisible(): State<Boolean> =
    appContainer().haOverlays.visible.collectAsStateWithLifecycle()
