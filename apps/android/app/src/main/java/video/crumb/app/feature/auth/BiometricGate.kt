// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import video.crumb.app.di.appContainer
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary

/**
 * Wraps the app content behind a biometric / device-credential unlock.
 *
 * Engages only when the user has opted in ([video.crumb.app.data.SecureStore.biometricEnabled])
 * AND there is a stored session to protect ([video.crumb.app.data.SecureStore.isLoggedIn]).
 * A fresh credential login during this session does **not** re-prompt, because the
 * gate is armed once at composition (cold start) — by then a returning user is
 * already logged in, whereas a first-time login starts from the unauthenticated
 * Login screen with the gate disarmed.
 *
 * The unlock state is `rememberSaveable`, so it survives configuration changes and
 * Picture-in-Picture but resets on process death → the app re-locks on the next
 * cold start. (Re-locking on every background is a deliberate non-goal for now: it
 * fights Picture-in-Picture and the always-on live wall.)
 *
 * To avoid ever locking the user out of their own NVR, the gate also disarms if the
 * device can no longer authenticate (e.g. all biometrics were removed) — the
 * Settings toggle is the source of truth, not a hard vault.
 */
@Composable
fun BiometricGate(content: @Composable () -> Unit) {
    val container = appContainer()
    val store = container.store
    val context = LocalContext.current
    val activity = context as? FragmentActivity

    val armed = remember {
        store.biometricEnabled &&
            store.isLoggedIn &&
            activity != null &&
            biometricAvailability(context) == BiometricAvailability.AVAILABLE
    }
    if (!armed) {
        content()
        return
    }

    var unlocked by rememberSaveable { mutableStateOf(false) }
    var prompting by remember { mutableStateOf(false) }

    if (unlocked) {
        content()
        return
    }

    fun prompt() {
        if (prompting || activity == null) return
        prompting = true
        showBiometricPrompt(activity, "Unlock Crumb", "Confirm it's you") { ok ->
            prompting = false
            if (ok) unlocked = true
        }
    }

    // Auto-show the prompt once on landing; the lock screen offers a retry.
    LaunchedEffect(Unit) { prompt() }

    LockScreen(
        onUnlock = { prompt() },
        onSignOut = {
            container.repository.logout()
            // Release the gate; the nav host now starts at the Login screen since
            // the session was just cleared.
            unlocked = true
        },
    )
}

/**
 * One-time prompt shown right after a fresh sign-in offering to turn on the
 * biometric app lock — the discoverable place users expect "biometric login",
 * versus hunting for the Settings toggle. Gated by
 * [video.crumb.app.data.SecureStore.biometricOffered] so it fires only once.
 */
@Composable
fun BiometricEnrollPrompt(onEnable: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = {
            Icon(imageVector = Icons.Filled.Lock, contentDescription = null, tint = TealAccent)
        },
        title = { Text("Enable biometric unlock?", color = TextPrimary) },
        text = {
            Text(
                text = "Lock Crumb behind your fingerprint, face, or device PIN so it " +
                    "asks for you each time the app starts. You can change this anytime " +
                    "in Settings.",
                style = MaterialTheme.typography.bodyMedium,
                color = TextSecondary,
            )
        },
        confirmButton = {
            TextButton(onClick = onEnable) { Text("Enable") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Not now", color = TextSecondary) }
        },
    )
}

@Composable
private fun LockScreen(onUnlock: () -> Unit, onSignOut: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.Lock,
                contentDescription = null,
                tint = TealAccent,
                modifier = Modifier.size(56.dp),
            )
            Text(
                text = "Crumb is locked",
                style = MaterialTheme.typography.titleLarge,
                color = TextPrimary,
                modifier = Modifier.padding(top = 16.dp),
            )
            Text(
                text = "Unlock with your fingerprint, face, or device PIN to continue.",
                style = MaterialTheme.typography.bodyMedium,
                color = TextSecondary,
                modifier = Modifier.padding(top = 8.dp),
            )
            Button(
                onClick = onUnlock,
                modifier = Modifier.padding(top = 24.dp),
            ) {
                Text("Unlock")
            }
            TextButton(
                onClick = onSignOut,
                modifier = Modifier.padding(top = 4.dp),
            ) {
                Text("Sign out instead", color = TextSecondary)
            }
        }
    }
}
