// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.compose.setContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.fragment.app.FragmentActivity
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import video.crumb.app.di.appContainer
import video.crumb.app.feature.auth.BiometricAvailability
import video.crumb.app.feature.auth.BiometricEnrollPrompt
import video.crumb.app.feature.auth.BiometricGate
import video.crumb.app.feature.auth.LoginScreen
import video.crumb.app.feature.auth.biometricAvailability
import video.crumb.app.feature.auth.showBiometricPrompt
import video.crumb.app.feature.clips.ClipsScreen
import video.crumb.app.feature.export.ExportScreen
import video.crumb.app.feature.live.LiveFullscreenScreen
import video.crumb.app.feature.live.LiveScreen
import video.crumb.app.feature.playback.BookmarksScreen
import video.crumb.app.feature.playback.PlaybackScreen
import video.crumb.app.feature.playback.PlaybackWallScreen
import video.crumb.app.feature.tuner.MotionTunerScreen
import video.crumb.app.ui.nav.Routes
import video.crumb.app.ui.theme.CrumbTheme

class MainActivity : FragmentActivity() {

    // Picture-in-Picture state shared with the full-screen video screen.
    private val inPipState = mutableStateOf(false)
    private var videoActive = false
    private val pipAspect = Rational(16, 9)

    private val pipController = object : PipController {
        override val isInPip: Boolean get() = inPipState.value
        override fun setVideoActive(active: Boolean) {
            videoActive = active
            applyPipParams()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            CrumbTheme {
                CompositionLocalProvider(LocalPipController provides pipController) {
                    Surface(
                        modifier = Modifier.fillMaxSize(),
                        color = MaterialTheme.colorScheme.background,
                    ) {
                        BiometricGate {
                            CrumbNavHost()
                        }
                    }
                }
            }
        }
    }

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** Keep PiP params current: aspect ratio + (API 31+) auto-enter on leave. */
    private fun applyPipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && pipSupported()) {
            setPictureInPictureParams(
                PictureInPictureParams.Builder()
                    .setAspectRatio(pipAspect)
                    .setAutoEnterEnabled(videoActive)
                    .build(),
            )
        }
    }

    // Enter PiP when the user leaves the app (Home button / nav) while a
    // full-screen camera is up, so the video keeps playing in a floating window.
    // This is the reliable path for button navigation; setAutoEnterEnabled (API
    // 31+, set in applyPipParams) covers the gesture-nav home swipe. Entering when
    // already entering is a harmless no-op, so running both is safe.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (videoActive && pipSupported()) {
            runCatching {
                enterPictureInPictureMode(
                    PictureInPictureParams.Builder().setAspectRatio(pipAspect).build(),
                )
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPipState.value = isInPictureInPictureMode
    }
}

@Composable
private fun CrumbNavHost() {
    val navController = rememberNavController()
    val container = appContainer()
    val start = if (container.store.isLoggedIn) Routes.LIVE else Routes.LOGIN

    // Post-login biometric enrollment offer (one-time; see BiometricEnrollPrompt).
    val store = container.store
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    var offerBiometric by remember { mutableStateOf(false) }

    // Session expiry/revocation (P0-SESSIONS): the OkHttp interceptor emits on any
    // authenticated 401, having already cleared the token. Drop back to Login,
    // wiping the whole back stack so no authed screen lingers underneath.
    LaunchedEffect(Unit) {
        container.authExpired.collect {
            container.repository.logout()
            navController.navigate(Routes.LOGIN) {
                popUpTo(0) { inclusive = true }
                launchSingleTop = true
            }
        }
    }

    // Also offer on a cold start where the session is already active (updated in
    // place, no Login screen this run). The Login path below covers fresh sign-ins.
    LaunchedEffect(Unit) {
        if (store.isLoggedIn && !store.biometricEnabled && !store.biometricOffered &&
            activity != null &&
            biometricAvailability(context) == BiometricAvailability.AVAILABLE
        ) {
            store.biometricOffered = true
            offerBiometric = true
        }
    }

    // Top-level tab switches (Live / Playback / Clips) must behave like sibling
    // tabs, not a growing back stack: anchor every switch on LIVE so the stack
    // stays [LIVE] or [LIVE, tab]. Without this, Clips → Playback → Live popped
    // back to Clips (the popBackStack-as-Live shortcut landed on whatever was
    // underneath Playback). popUpTo(LIVE) + launchSingleTop keeps a single Live
    // root and avoids duplicate tab destinations.
    fun navigateTab(route: String) {
        navController.navigate(route) {
            popUpTo(Routes.LIVE) { inclusive = false }
            launchSingleTop = true
        }
    }

    // Cold start lands on the all-cameras Live wall (Routes.LIVE). We intentionally
    // do NOT auto-reopen the last fullscreen camera, so the user always sees the
    // wall first and chooses a camera from there.

    // Quick cross-fade between destinations (not a slide) so switching the Live ⇄
    // Playback tabs reads as a content swap under the shared tab row, not "opening
    // another page". Applies app-wide for a consistent, calm feel.
    NavHost(
        navController = navController,
        startDestination = start,
        enterTransition = { fadeIn(animationSpec = tween(160)) },
        exitTransition = { fadeOut(animationSpec = tween(160)) },
        popEnterTransition = { fadeIn(animationSpec = tween(160)) },
        popExitTransition = { fadeOut(animationSpec = tween(160)) },
    ) {

        composable(Routes.LOGIN) {
            LoginScreen(
                onLoggedIn = {
                    // Offer biometric unlock once, right after a fresh sign-in, when the
                    // device supports it and it isn't already on or previously declined.
                    if (!store.biometricEnabled && !store.biometricOffered &&
                        activity != null &&
                        biometricAvailability(context) == BiometricAvailability.AVAILABLE
                    ) {
                        store.biometricOffered = true
                        offerBiometric = true
                    }
                    navController.navigate(Routes.LIVE) {
                        popUpTo(Routes.LOGIN) { inclusive = true }
                    }
                },
            )
        }

        composable(Routes.LIVE) {
            val store = container.store
            val caps = store.capabilities
            LiveScreen(
                onOpenFullscreen = { id ->
                    // Remember the open camera so it is restored on next launch.
                    store.lastLiveCameraId = id
                    navController.navigate(Routes.liveFull(id))
                },
                // Enter Playback as a standalone mode (defaults to first camera).
                // Guard against a role that lacks the playback capability — the tab
                // is already hidden in LiveScreen, but an explicit back-stack pop or
                // a deep-link could still invoke this callback.
                onOpenPlaybackMode = {
                    if (store.isAdmin || caps.playback) navigateTab(Routes.PLAYBACK_STANDALONE)
                },
                onOpenClips = {
                    if (store.isAdmin || caps.clips) navigateTab(Routes.CLIPS)
                },
                onLogout = {
                    container.repository.logout()
                    navController.navigate(Routes.LOGIN) {
                        popUpTo(0) { inclusive = true }
                    }
                },
            )
        }

        composable(
            route = Routes.LIVE_FULL,
            arguments = listOf(navArgument(Routes.ARG_CAMERA_ID) { type = NavType.StringType }),
        ) { entry ->
            val cameraId = entry.arguments?.getString(Routes.ARG_CAMERA_ID).orEmpty()
            if (cameraId.isBlank()) {
                LaunchedEffect(Unit) { navController.popBackStack() }
            } else {
                LiveFullscreenScreen(
                    cameraId = cameraId,
                    onBack = {
                        // Returning to the grid: no camera is "open" anymore.
                        container.store.lastLiveCameraId = null
                        navController.popBackStack()
                    },
                    onOpenPlayback = { id ->
                        navController.navigate(Routes.playback(id))
                    },
                    onTuneMotion = { id ->
                        navController.navigate(Routes.motionTuner(id))
                    },
                )
            }
        }

        // Standalone Playback mode — the multi-camera PLAYBACK WALL: a grid of
        // latest-image snapshots with shared playback controls. Tapping a tile opens
        // that camera in single-camera playback, seeded at the wall's scrubbed time
        // (or its latest footage when the wall is at "Latest").
        composable(Routes.PLAYBACK_STANDALONE) {
            val store = container.store
            val caps = store.capabilities
            PlaybackWallScreen(
                onOpenLive = { navigateTab(Routes.LIVE) },
                onOpenPlayback = { id, startMs ->
                    navController.navigate(
                        if (startMs > 0L) Routes.playbackAt(id, startMs) else Routes.playback(id),
                    )
                },
                onOpenBookmarks = { navController.navigate(Routes.BOOKMARKS) },
                onOpenExport = {
                    if (store.isAdmin || caps.export) navController.navigate(Routes.EXPORT)
                },
                onOpenClips = {
                    if (store.isAdmin || caps.clips) navigateTab(Routes.CLIPS)
                },
            )
        }

        // Cross-camera bookmarks list — tapping a row jumps to that camera+time.
        composable(Routes.BOOKMARKS) {
            BookmarksScreen(
                onBack = { navController.popBackStack() },
                onOpen = { id, ms -> navController.navigate(Routes.playbackAt(id, ms)) },
            )
        }

        // Playback seeded with a specific camera (from a Live tile / fullscreen
        // shortcut / the playback wall). Optional `t` (epoch-millis) seeds the start
        // time; absent/≤0 → jump to latest. Still fully switchable once inside.
        composable(
            route = Routes.PLAYBACK,
            arguments = listOf(
                navArgument(Routes.ARG_CAMERA_ID) { type = NavType.StringType },
                navArgument(Routes.ARG_TIME) {
                    type = NavType.LongType
                    defaultValue = 0L
                },
            ),
        ) { entry ->
            val cameraId = entry.arguments?.getString(Routes.ARG_CAMERA_ID).orEmpty()
            val startMs = entry.arguments?.getLong(Routes.ARG_TIME) ?: 0L
            PlaybackScreen(
                initialCameraId = cameraId,
                initialTimeMs = startMs,
                onBack = { navController.popBackStack() },
            )
        }

        composable(Routes.EXPORT) {
            ExportScreen(onBack = { navController.popBackStack() })
        }

        // Clips tab — a thumbnail grid of detection + motion clips with tap-to-play.
        composable(Routes.CLIPS) {
            ClipsScreen(
                onOpenLive = { navigateTab(Routes.LIVE) },
                onOpenPlayback = { navigateTab(Routes.PLAYBACK_STANDALONE) },
                // Jump to the clip's moment on the recorded-playback timeline.
                onOpenClipAt = { cameraId, timeMs ->
                    navController.navigate(Routes.playbackAt(cameraId, timeMs))
                },
            )
        }

        // Motion Tuner for a single camera (admin-only; entry is gated in the
        // fullscreen live view). Seeded with the camera id from the nav arg.
        composable(
            route = Routes.MOTION_TUNER,
            arguments = listOf(navArgument(Routes.ARG_CAMERA_ID) { type = NavType.StringType }),
        ) { entry ->
            val cameraId = entry.arguments?.getString(Routes.ARG_CAMERA_ID).orEmpty()
            if (cameraId.isBlank()) {
                LaunchedEffect(Unit) { navController.popBackStack() }
            } else {
                MotionTunerScreen(
                    cameraId = cameraId,
                    onClose = { navController.popBackStack() },
                )
            }
        }
    }

    if (offerBiometric && activity != null) {
        BiometricEnrollPrompt(
            onEnable = {
                showBiometricPrompt(
                    activity,
                    "Enable biometric unlock",
                    "Confirm to turn it on",
                ) { ok ->
                    if (ok) store.biometricEnabled = true
                    offerBiometric = false
                }
            },
            onDismiss = { offerBiometric = false },
        )
    }
}
