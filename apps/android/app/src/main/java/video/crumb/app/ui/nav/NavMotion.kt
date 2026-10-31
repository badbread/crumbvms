// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.nav

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.ui.graphics.TransformOrigin
import androidx.navigation.NavBackStackEntry

/** Material "emphasized decelerate" curve, used for the tile grow (L6 / W6). */
private val EmphasizedDecelerate = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1.0f)

/** Which motion a navigation step gets. Pure so it can be unit tested. */
enum class NavMotionKind {
    /** Plain fade-through (G1) with no scale. */
    FADE_THROUGH,

    /** Fade-through with the incoming screen scaling 0.92 to 1 (tab to tab). */
    FADE_THROUGH_SCALE,

    /** The destination grows out of (or shrinks back into) the tapped tile. */
    TILE_GROW,
}

private val TAB_ROUTES = setOf(Routes.LIVE, Routes.PLAYBACK_STANDALONE, Routes.CLIPS, Routes.PLATES)

/**
 * Forward navigation from [from] to [to]. Tile grow for wall to single camera;
 * the scale in fade-through only for tab to tab, and never INTO the Live wall
 * (its tiles are SurfaceViews, which do not follow a parent scale).
 */
fun navMotionKind(from: String?, to: String?): NavMotionKind = when {
    from == Routes.LIVE && to == Routes.LIVE_FULL -> NavMotionKind.TILE_GROW
    from == Routes.PLAYBACK_STANDALONE && to == Routes.PLAYBACK -> NavMotionKind.TILE_GROW
    from in TAB_ROUTES && to in TAB_ROUTES && to != Routes.LIVE -> NavMotionKind.FADE_THROUGH_SCALE
    else -> NavMotionKind.FADE_THROUGH
}

/** Back navigation: only the single-camera screens shrink back into their tile. */
fun navPopMotionKind(from: String?, to: String?): NavMotionKind = when {
    from == Routes.LIVE_FULL && to == Routes.LIVE -> NavMotionKind.TILE_GROW
    from == Routes.PLAYBACK && to == Routes.PLAYBACK_STANDALONE -> NavMotionKind.TILE_GROW
    else -> NavMotionKind.FADE_THROUGH
}

/**
 * Where the last tapped wall tile was on screen, as fractions of the window, so the
 * single-camera screen can grow out of it. A simpler stand-in for a shared-element
 * transform: the ExoPlayer surfaces on both screens cannot take part in
 * SharedTransitionLayout, so only the screen's own bounds animate.
 */
object TileOrigin {
    private val fractions = HashMap<String, Pair<Float, Float>>()

    fun record(cameraId: String, fx: Float, fy: Float) {
        fractions[cameraId] = fx.coerceIn(0f, 1f) to fy.coerceIn(0f, 1f)
    }

    fun origin(cameraId: String?): TransformOrigin {
        val f = cameraId?.let { fractions[it] } ?: return TransformOrigin.Center
        return TransformOrigin(f.first, f.second)
    }
}

private fun NavBackStackEntry?.cameraId(): String? = this?.arguments?.getString(Routes.ARG_CAMERA_ID)

private const val GROW_MS = 300
private const val GROW_FROM_SCALE = 0.4f

fun AnimatedContentTransitionScope<NavBackStackEntry>.crumbEnter(): EnterTransition =
    when (navMotionKind(initialState.destination.route, targetState.destination.route)) {
        NavMotionKind.TILE_GROW -> fadeIn(tween(200)) + scaleIn(
            initialScale = GROW_FROM_SCALE,
            transformOrigin = TileOrigin.origin(targetState.cameraId()),
            animationSpec = tween(GROW_MS, easing = EmphasizedDecelerate),
        )
        NavMotionKind.FADE_THROUGH_SCALE -> fadeIn(tween(210, 90, EaseOutCubic)) +
            scaleIn(initialScale = 0.92f, animationSpec = tween(210, 90, EaseOutCubic))
        NavMotionKind.FADE_THROUGH -> fadeIn(tween(210, 90, EaseOutCubic))
    }

fun AnimatedContentTransitionScope<NavBackStackEntry>.crumbExit(): ExitTransition =
    when (navMotionKind(initialState.destination.route, targetState.destination.route)) {
        // The wall stays put underneath while the camera grows out of its tile.
        NavMotionKind.TILE_GROW -> ExitTransition.None
        else -> fadeOut(tween(90))
    }

fun AnimatedContentTransitionScope<NavBackStackEntry>.crumbPopEnter(): EnterTransition =
    when (navPopMotionKind(initialState.destination.route, targetState.destination.route)) {
        NavMotionKind.TILE_GROW -> EnterTransition.None
        else -> fadeIn(tween(210, 90, EaseOutCubic))
    }

fun AnimatedContentTransitionScope<NavBackStackEntry>.crumbPopExit(): ExitTransition =
    when (navPopMotionKind(initialState.destination.route, targetState.destination.route)) {
        NavMotionKind.TILE_GROW -> fadeOut(tween(GROW_MS)) + scaleOut(
            targetScale = GROW_FROM_SCALE,
            transformOrigin = TileOrigin.origin(initialState.cameraId()),
            animationSpec = tween(GROW_MS, easing = EmphasizedDecelerate),
        )
        else -> fadeOut(tween(90))
    }
