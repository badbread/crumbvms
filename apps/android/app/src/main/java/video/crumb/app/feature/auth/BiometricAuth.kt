// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.auth

import android.content.Context
import android.os.Build
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/**
 * Thin wrapper over AndroidX [BiometricPrompt] for the app-lock feature.
 *
 * Authenticator set is tuned per API level:
 * - **API 30+ (R):** strong biometric OR the device PIN/pattern/password
 *   (`DEVICE_CREDENTIAL`), which supplies its own fallback button.
 * - **API 26-29:** biometric only (`BIOMETRIC_WEAK or BIOMETRIC_STRONG`) with a
 *   custom "Cancel" button — combining biometric with `DEVICE_CREDENTIAL` in a
 *   single prompt isn't supported by BiometricPrompt below API 30.
 */
private fun allowedAuthenticators(): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        BIOMETRIC_STRONG or DEVICE_CREDENTIAL
    } else {
        BIOMETRIC_WEAK or BIOMETRIC_STRONG
    }

/** Whether the device can satisfy the app-lock prompt right now. */
enum class BiometricAvailability {
    /** A biometric (or, API 30+, device credential) is enrolled and usable. */
    AVAILABLE,

    /** Hardware exists but nothing is enrolled — guide the user to system Settings. */
    NONE_ENROLLED,

    /** No biometric hardware, or it's currently unavailable. */
    NO_HARDWARE,

    /** Unknown / transient failure. */
    UNAVAILABLE,
}

fun biometricAvailability(context: Context): BiometricAvailability =
    when (BiometricManager.from(context).canAuthenticate(allowedAuthenticators())) {
        BiometricManager.BIOMETRIC_SUCCESS -> BiometricAvailability.AVAILABLE
        BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> BiometricAvailability.NONE_ENROLLED
        BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
        BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE,
        -> BiometricAvailability.NO_HARDWARE
        else -> BiometricAvailability.UNAVAILABLE
    }

/**
 * Show the system biometric / device-credential prompt. [onResult] fires exactly
 * once: `true` on success, `false` on user cancel or an unrecoverable error.
 *
 * A single rejected fingerprint (`onAuthenticationFailed`) is transient — the
 * prompt stays up for a retry, so it does not resolve [onResult].
 */
fun showBiometricPrompt(
    activity: FragmentActivity,
    title: String,
    subtitle: String?,
    onResult: (Boolean) -> Unit,
) {
    val executor = ContextCompat.getMainExecutor(activity)
    val prompt = BiometricPrompt(
        activity,
        executor,
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onResult(true)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                onResult(false)
            }
        },
    )
    val builder = BiometricPrompt.PromptInfo.Builder()
        .setTitle(title)
        .setAllowedAuthenticators(allowedAuthenticators())
    if (subtitle != null) builder.setSubtitle(subtitle)
    // A negative button is required UNLESS DEVICE_CREDENTIAL is allowed (API 30+),
    // which provides its own "Use PIN" fallback button.
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
        builder.setNegativeButtonText("Cancel")
    }
    prompt.authenticate(builder.build())
}
