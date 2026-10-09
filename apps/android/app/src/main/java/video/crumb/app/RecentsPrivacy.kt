// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app

import android.os.Build

/**
 * How the app keeps camera content out of the recents / app-switcher card
 * without taking ordinary screenshots away from the operator.
 *
 * Two mechanisms, picked by API level:
 *
 * - **API 33+** has [android.app.Activity.setRecentsScreenshotEnabled], which
 *   suppresses only the recents snapshot. Foreground screenshots and screen
 *   recording keep working, which is what we want: the recents card is the
 *   surface that shows camera video to whoever picks the phone up next, a
 *   deliberate screenshot is the operator's own choice.
 * - **Below 33** there is no such switch, so the window is made secure only
 *   across the leave-the-foreground transition (the snapshot is taken as the
 *   activity is paused) and cleared again on resume. While the operator is
 *   looking at the app the window is not secure, so screenshots still work.
 *
 * Picture-in-Picture is exempt from the pre-33 path: entering PiP also delivers
 * `onPause`, and a secure window would blank the floating video window. The
 * trade-off is that a pre-33 device that leaves the app straight into PiP can
 * still put a video frame on its recents card; API 33+ devices, which is where
 * the supported majority sits, use the dedicated switch and are unaffected.
 *
 * Pure decision logic, no framework calls, so it is unit-testable. The actual
 * `setRecentsScreenshotEnabled` call stays inline in `MainActivity` with a
 * literal `Build.VERSION.SDK_INT` comparison so lint can see the API guard.
 */
internal object RecentsPrivacy {

    /** True when the platform offers the dedicated recents-snapshot switch. */
    fun usesRecentsSwitch(sdkInt: Int): Boolean = sdkInt >= Build.VERSION_CODES.TIRAMISU

    /** True when the pre-33 secure-window fallback applies on this platform. */
    fun usesSecureWindowFallback(sdkInt: Int): Boolean = !usesRecentsSwitch(sdkInt)

    /**
     * Whether `onPause` should make the window secure: only on the pre-33
     * fallback, and never when the pause is a Picture-in-Picture transition.
     */
    fun secureOnPause(sdkInt: Int, inPictureInPicture: Boolean): Boolean =
        usesSecureWindowFallback(sdkInt) && !inPictureInPicture
}
