// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import android.app.Activity
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

/**
 * Hide the system status + navigation bars (true fullscreen / immersive) while
 * [enabled] is true, restoring them when it flips to false or the composable
 * leaves composition.
 *
 * Uses sticky/transient immersive behaviour so an edge swipe TEMPORARILY reveals
 * the bars (and the clock/battery) without leaving fullscreen — the expected feel
 * for a full-screen video. Safe no-op if the host view isn't backed by an
 * Activity window (e.g. preview).
 */
@Composable
fun ImmersiveMode(enabled: Boolean) {
    val view = LocalView.current
    DisposableEffect(enabled) {
        val window = (view.context as? Activity)?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, view) }
        if (enabled && controller != null) {
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller?.show(WindowInsetsCompat.Type.systemBars())
        }
        onDispose {
            // Always restore the bars on the way out so other screens are normal.
            controller?.show(WindowInsetsCompat.Type.systemBars())
        }
    }
}

/**
 * Hold [WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON] while [enabled] is true so
 * the display never sleeps mid-watch on a live wall (security operators leave it up
 * for long stretches; the default screen timeout would blank it). The flag is
 * cleared when [enabled] flips to false or the composable leaves composition, so it
 * never leaks the wake-lock to other screens. Safe no-op outside an Activity window.
 */
@Composable
fun KeepScreenOn(enabled: Boolean) {
    val view = LocalView.current
    DisposableEffect(enabled) {
        val window = (view.context as? Activity)?.window
        if (enabled) {
            window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}
