// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import video.crumb.app.ui.theme.TealAccent

/**
 * On-video PTZ control — a commercial-VMS-style **clickable wheel with a Home button
 * in the middle**, drawn directly over the camera image (not a separate bar).
 *
 * Interaction:
 * - Press-and-hold anywhere on the ring and the camera pans/tilts continuously
 *   toward that point (velocity ∝ distance from center). Drag to re-aim. Release
 *   stops. This gives an immediate response on touch-down (no drag threshold).
 * - Tap the **Home** button in the middle to recall the home position.
 * - The **+ / −** buttons (right of the wheel) optical-zoom while held.
 *
 * All velocities are normalized to [-1, 1]; the caller throttles network sends.
 *
 * @param onMove Continuous move with (pan, tilt) velocities, called as the touch moves.
 * @param onStop Called once when the touch is released (stop movement).
 * @param onHome Called when the center Home button is tapped.
 * @param onZoom Called when a zoom button goes down (+1 = in, -1 = out).
 * @param onZoomStop Called when a zoom button is released.
 */
@Composable
fun PtzWheel(
    onMove: (pan: Float, tilt: Float) -> Unit,
    onStop: () -> Unit,
    onHome: () -> Unit,
    onZoom: (Float) -> Unit,
    onZoomStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // ── The wheel (joystick ring + chevrons + center Home) ──────────────────
        Box(
            modifier = Modifier.size(132.dp),
            contentAlignment = Alignment.Center,
        ) {
            Canvas(
                modifier = Modifier
                    .fillMaxSize()
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            val center = Offset(size.width / 2f, size.height / 2f)
                            val radius = size.width / 2f
                            val innerR = radius * 0.34f // center = Home button zone

                            fun emit(pos: Offset) {
                                val dx = (pos.x - center.x) / radius
                                val dy = (pos.y - center.y) / radius
                                onMove(dx.coerceIn(-1f, 1f), (-dy).coerceIn(-1f, 1f))
                            }

                            // Touches in the center are the Home button's job.
                            val dist0 = (down.position - center).getDistance()
                            if (dist0 <= innerR) return@awaitEachGesture

                            down.consume()
                            emit(down.position)
                            while (true) {
                                val event = awaitPointerEvent()
                                val ch = event.changes.firstOrNull { it.id == down.id }
                                    ?: event.changes.firstOrNull() ?: break
                                if (!ch.pressed) break
                                emit(ch.position)
                                ch.consume()
                            }
                            onStop()
                        }
                    },
            ) {
                val r = size.minDimension / 2f
                val c = Offset(size.width / 2f, size.height / 2f)
                // Ring background
                drawCircle(color = Color.Black.copy(alpha = 0.45f), radius = r, center = c)
                drawCircle(
                    color = Color.White.copy(alpha = 0.5f),
                    radius = r,
                    center = c,
                    style = Stroke(width = 2.5f),
                )
                // Four directional chevrons (up/down/left/right)
                val chevron = TealAccent.copy(alpha = 0.95f)
                val cr = r * 0.62f // chevron distance from center
                val cs = r * 0.16f // chevron half-size
                fun chevron(apex: Offset, dir: Int) {
                    // dir: 0=up,1=down,2=left,3=right
                    val p = Path()
                    when (dir) {
                        0 -> { p.moveTo(apex.x, apex.y - cs); p.lineTo(apex.x - cs, apex.y + cs); p.moveTo(apex.x, apex.y - cs); p.lineTo(apex.x + cs, apex.y + cs) }
                        1 -> { p.moveTo(apex.x, apex.y + cs); p.lineTo(apex.x - cs, apex.y - cs); p.moveTo(apex.x, apex.y + cs); p.lineTo(apex.x + cs, apex.y - cs) }
                        2 -> { p.moveTo(apex.x - cs, apex.y); p.lineTo(apex.x + cs, apex.y - cs); p.moveTo(apex.x - cs, apex.y); p.lineTo(apex.x + cs, apex.y + cs) }
                        3 -> { p.moveTo(apex.x + cs, apex.y); p.lineTo(apex.x - cs, apex.y - cs); p.moveTo(apex.x + cs, apex.y); p.lineTo(apex.x - cs, apex.y + cs) }
                    }
                    drawPath(p, color = chevron, style = Stroke(width = 4f, cap = StrokeCap.Round))
                }
                chevron(Offset(c.x, c.y - cr), 0)
                chevron(Offset(c.x, c.y + cr), 1)
                chevron(Offset(c.x - cr, c.y), 2)
                chevron(Offset(c.x + cr, c.y), 3)
            }

            // Center Home button (drawn on top so taps hit it, not the joystick).
            Box(
                modifier = Modifier
                    .size(46.dp)
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            // Treat any press on the center as a Home request on release.
                            var released = false
                            while (!released) {
                                val e = awaitPointerEvent()
                                if (e.changes.all { !it.pressed }) released = true
                                e.changes.forEach { it.consume() }
                            }
                            onHome()
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Default.Home,
                    contentDescription = "PTZ home",
                    tint = Color.White,
                    modifier = Modifier.size(22.dp),
                )
            }
        }

        // ── Zoom +/- (press-hold) ───────────────────────────────────────────────
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            ZoomButton(icon = Icons.Default.Add, desc = "Zoom in", onPress = { onZoom(1f) }, onRelease = onZoomStop)
            ZoomButton(icon = Icons.Default.Remove, desc = "Zoom out", onPress = { onZoom(-1f) }, onRelease = onZoomStop)
        }
    }
}

/**
 * On-video PTZ control — **directional arrows pinned to the edges of the camera
 * view** (the commercial VMS "edge" style), as an alternative to [PtzWheel]. Up/Down at the
 * top/bottom centre, Left/Right at the mid sides; a Zoom +/− and Home cluster at
 * the bottom-right. Each arrow is press-and-hold: ONVIF ContinuousMove starts on
 * press and stops on release (same model as the wheel). Fills the parent so the
 * centre stays free for pinch-to-zoom; only the buttons capture touches.
 */
@Composable
fun PtzEdgeControls(
    onMove: (pan: Float, tilt: Float) -> Unit,
    onStop: () -> Unit,
    onHome: () -> Unit,
    onZoom: (Float) -> Unit,
    onZoomStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val v = 0.6f // fixed pan/tilt velocity while an edge arrow is held
    Box(modifier = modifier.fillMaxSize()) {
        ZoomButton(
            icon = Icons.Default.KeyboardArrowUp, desc = "Tilt up",
            onPress = { onMove(0f, v) }, onRelease = onStop,
            modifier = Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 64.dp),
        )
        ZoomButton(
            icon = Icons.Default.KeyboardArrowDown, desc = "Tilt down",
            onPress = { onMove(0f, -v) }, onRelease = onStop,
            modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 28.dp),
        )
        ZoomButton(
            icon = Icons.Default.KeyboardArrowLeft, desc = "Pan left",
            onPress = { onMove(-v, 0f) }, onRelease = onStop,
            modifier = Modifier.align(Alignment.CenterStart).padding(start = 14.dp),
        )
        ZoomButton(
            icon = Icons.Default.KeyboardArrowRight, desc = "Pan right",
            onPress = { onMove(v, 0f) }, onRelease = onStop,
            modifier = Modifier.align(Alignment.CenterEnd).padding(end = 14.dp),
        )
        // Zoom + Home cluster (bottom-right), clear of the bottom-centre Down arrow.
        Column(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .navigationBarsPadding()
                .padding(end = 14.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            ZoomButton(icon = Icons.Default.Add, desc = "Zoom in", onPress = { onZoom(1f) }, onRelease = onZoomStop)
            ZoomButton(icon = Icons.Default.Remove, desc = "Zoom out", onPress = { onZoom(-1f) }, onRelease = onZoomStop)
            ZoomButton(icon = Icons.Default.Home, desc = "PTZ home", onPress = {}, onRelease = onHome)
        }
    }
}

@Composable
private fun ZoomButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    desc: String,
    onPress: () -> Unit,
    onRelease: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .size(44.dp)
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    onPress()
                    var released = false
                    while (!released) {
                        val e = awaitPointerEvent()
                        if (e.changes.all { !it.pressed }) released = true
                        e.changes.forEach { it.consume() }
                    }
                    onRelease()
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        // Filled translucent circle backdrop
        Canvas(Modifier.fillMaxSize()) {
            drawCircle(color = Color.Black.copy(alpha = 0.45f))
            drawCircle(color = Color.White.copy(alpha = 0.5f), style = Stroke(width = 2.5f))
        }
        Icon(imageVector = icon, contentDescription = desc, tint = Color.White, modifier = Modifier.size(24.dp))
    }
}
