// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import video.crumb.app.data.CameraView
import video.crumb.app.ui.theme.Spacing
import video.crumb.app.ui.theme.TealAccent

/**
 * The saved-view selector: "All" + one compact chip per [CameraView], horizontally
 * scrollable so any number of views fit. Shared by the Live wall and the Playback
 * wall, in two placements:
 *  - **portrait** — its own thin strip below the Live|Playback tabs.
 *  - **landscape** — inline next to the tabs in the app-bar title (16 dp of space
 *    between them, no divider rule), because landscape height is scarce and a whole extra row is
 *    a waste; overflow scrolls sideways within the title's remaining width.
 *
 * @param modifier sizing supplied by the caller (fillMaxWidth+padding for the strip,
 *   or weight(1f) when inline in the title). Horizontal scroll is applied internally.
 */
@Composable
fun ViewChipsRow(
    views: List<CameraView>,
    activeViewId: String?,
    onSelect: (String?) -> Unit,
    modifier: Modifier = Modifier,
    /**
     * Whether the "All" (All Cameras) chip is offered at all — the client-side
     * [video.crumb.app.data.SecureStore.showAllCamerasView] preference (desktop
     * parity: `client_options.dart`'s `showAllCamerasView`). Default true so every
     * existing caller keeps today's behavior unless it opts in to hiding it.
     */
    showAllCamerasView: Boolean = true,
    /** Selected-chip accent: the tab colour of the screen hosting the chips (L2). */
    accent: Color = TealAccent,
) {
    Row(
        modifier = modifier.horizontalScroll(rememberScrollState()),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.s),
    ) {
        if (showAllCamerasView) {
            CrumbFilterChip(
                selected = activeViewId == null,
                onClick = { onSelect(null) },
                label = "All",
                accent = accent,
            )
        }
        views.forEach { v ->
            CrumbFilterChip(
                selected = activeViewId == v.id,
                onClick = { onSelect(v.id) },
                label = v.name,
                accent = accent,
            )
        }
    }
}
