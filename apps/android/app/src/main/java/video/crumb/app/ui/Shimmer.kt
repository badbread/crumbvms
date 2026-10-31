// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.NavySurfaceVariant
import video.crumb.app.ui.theme.Spacing

/**
 * Hand-rolled skeleton shimmer (polish pass G4); no library. One shared 1200 ms
 * linear sweep so every placeholder on screen pulses in step.
 */
@Composable
fun rememberShimmerBrush(): Brush {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val x by transition.animateFloat(
        initialValue = -600f,
        targetValue = 1800f,
        animationSpec = infiniteRepeatable(tween(1200, easing = LinearEasing), RepeatMode.Restart),
        label = "shimmerX",
    )
    return Brush.linearGradient(
        colors = listOf(NavySurface, NavySurfaceVariant, NavySurface),
        start = Offset(x, 0f),
        end = Offset(x + 600f, 200f),
    )
}

/** A single shimmering block. */
@Composable
fun SkeletonBox(
    modifier: Modifier = Modifier,
    shape: Shape = MaterialTheme.shapes.small,
) {
    val brush = rememberShimmerBrush()
    Box(modifier.clip(shape).background(brush))
}

/**
 * Tile-shaped placeholders in the final grid positions, for the camera walls
 * (L8). [cols] mirrors the real grid so the crossfade to video does not reflow.
 */
@Composable
fun SkeletonTileGrid(
    cols: Int,
    modifier: Modifier = Modifier,
    rows: Int = 2,
) {
    val brush = rememberShimmerBrush()
    val c = cols.coerceAtLeast(1)
    LazyVerticalGrid(
        columns = GridCells.Fixed(c),
        contentPadding = PaddingValues(Spacing.s),
        horizontalArrangement = Arrangement.spacedBy(Spacing.xs),
        verticalArrangement = Arrangement.spacedBy(Spacing.xs),
        userScrollEnabled = false,
        modifier = modifier.fillMaxSize(),
    ) {
        items(List(c * rows) { it }) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .aspectRatio(16f / 9f)
                    .clip(MaterialTheme.shapes.small)
                    .background(brush),
            )
        }
    }
}

/** Row-shaped placeholders for list screens (R2). */
@Composable
fun SkeletonRows(
    count: Int,
    modifier: Modifier = Modifier,
    rowHeight: Dp = 72.dp,
) {
    val brush = rememberShimmerBrush()
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(Spacing.xs),
    ) {
        repeat(count) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(rowHeight)
                    .padding(horizontal = Spacing.l, vertical = Spacing.s),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Spacing.m),
            ) {
                Box(
                    Modifier
                        .width(88.dp)
                        .fillMaxSize()
                        .clip(MaterialTheme.shapes.small)
                        .background(brush),
                )
                Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
                    Box(Modifier.width(120.dp).height(14.dp).clip(CircleShape).background(brush))
                    Box(Modifier.width(180.dp).height(12.dp).clip(CircleShape).background(brush))
                }
            }
        }
    }
}
