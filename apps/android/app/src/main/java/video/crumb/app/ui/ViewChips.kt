// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import video.crumb.app.data.CameraView
import video.crumb.app.ui.theme.TextSecondary

/**
 * The saved-view selector: "All" + one compact chip per [CameraView], horizontally
 * scrollable so any number of views fit. Shared by the Live wall and the Playback
 * wall, in two placements:
 *  - **portrait** — its own thin strip below the Live|Playback tabs.
 *  - **landscape** — inline next to the tabs in the app-bar title (separated by
 *    [InlineDivider]), because landscape height is scarce and a whole extra row is
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
) {
    Row(
        modifier = modifier.horizontalScroll(rememberScrollState()),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FilterChip(
            selected = activeViewId == null,
            onClick = { onSelect(null) },
            label = { Text("All", style = MaterialTheme.typography.labelMedium) },
            modifier = Modifier.height(30.dp),
        )
        views.forEach { v ->
            FilterChip(
                selected = activeViewId == v.id,
                onClick = { onSelect(v.id) },
                label = { Text(v.name, style = MaterialTheme.typography.labelMedium) },
                modifier = Modifier.height(30.dp),
            )
        }
    }
}

/** A thin vertical rule used to separate the Live|Playback tabs from the inline
 *  view chips when they share the app-bar title in landscape. */
@Composable
fun InlineDivider(modifier: Modifier = Modifier) {
    Box(
        modifier
            .padding(horizontal = 10.dp)
            .height(20.dp)
            .width(1.dp)
            .background(TextSecondary.copy(alpha = 0.4f)),
    )
}
