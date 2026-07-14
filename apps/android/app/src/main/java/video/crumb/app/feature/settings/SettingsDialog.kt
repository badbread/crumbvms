// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import video.crumb.app.data.SecureStore
import video.crumb.app.feature.auth.BiometricAvailability
import video.crumb.app.feature.auth.biometricAvailability
import video.crumb.app.feature.auth.showBiometricPrompt
import video.crumb.app.ui.crumbSwitchColors
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary

/**
 * App settings — a discoverable home for user-selectable preferences.
 *
 * The first (and currently only) preference is the **PTZ control style**, which
 * was previously only reachable as an unlabelled icon buried in the fullscreen
 * PTZ overlay — users couldn't find it. This dialog surfaces it where an Android
 * user looks for settings (the Live screen overflow menu) and mirrors the
 * wording of the desktop Options dialog for cross-client parity.
 *
 * Each choice writes straight through to [SecureStore] (the source of truth the
 * fullscreen live view reads when it opens), so the change takes effect the next
 * time the PTZ overlay is shown — no Apply/Save step.
 *
 * @param store Persisted preferences.
 * @param onDismiss Close the dialog.
 */
@Composable
fun SettingsDialog(
    store: SecureStore,
    lowBandwidthMode: Boolean,
    onLowBandwidthChange: (Boolean) -> Unit,
    /**
     * Whether the auto-built "All Cameras" quick-grid default view is offered on the
     * Live/Playback wall. Mirrored (not read straight from [store]) so the caller's
     * copy — which the wall itself reacts to live — stays in sync; see
     * [onShowAllCamerasViewChange].
     */
    showAllCamerasView: Boolean,
    onShowAllCamerasViewChange: (Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    // Local mirrors so controls update instantly; every change is persisted.
    var ptzStyle by remember { mutableStateOf(store.ptzStyle) }
    var motionTunerOn by remember { mutableStateOf(store.motionTunerEnabled) }
    var snapshotView by remember { mutableStateOf(store.snapshotCapturesView) }

    // Security — biometric app lock.
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    val biometricAvail = remember { biometricAvailability(context) }
    var biometricOn by remember { mutableStateOf(store.biometricEnabled) }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Done") }
        },
        title = { Text("Settings") },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Text(
                    text = "PTZ — control style",
                    style = MaterialTheme.typography.labelMedium,
                    color = TextSecondary,
                )
                PtzStyleRow(
                    label = "Joystick wheel",
                    description = "A round 8-direction wheel at the bottom of the screen.",
                    selected = ptzStyle == "wheel",
                    onSelect = {
                        ptzStyle = "wheel"
                        store.ptzStyle = "wheel"
                    },
                )
                PtzStyleRow(
                    label = "Edge arrows",
                    description = "Up/down/left/right pinned to the edges of the camera view.",
                    selected = ptzStyle == "edges",
                    onSelect = {
                        ptzStyle = "edges"
                        store.ptzStyle = "edges"
                    },
                )

                // ── Live view section ────────────────────────────────────────────
                Text(
                    text = "Live view",
                    style = MaterialTheme.typography.labelMedium,
                    color = TextSecondary,
                    modifier = Modifier.padding(top = 12.dp),
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .padding(end = 8.dp),
                    ) {
                        Text(
                            text = "Show motion-tuner button",
                            style = MaterialTheme.typography.bodyMedium,
                            color = TextPrimary,
                        )
                        Text(
                            text = "Show the motion-detection tuner button in the fullscreen live view (admin).",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                        )
                    }
                    Switch(
                        checked = motionTunerOn,
                        onCheckedChange = { checked ->
                            motionTunerOn = checked
                            store.motionTunerEnabled = checked
                        },
                        colors = crumbSwitchColors(),
                    )
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .padding(end = 8.dp),
                    ) {
                        Text(
                            text = "Low-bandwidth mode",
                            style = MaterialTheme.typography.bodyMedium,
                            color = TextPrimary,
                        )
                        Text(
                            text = "Drop the live wall to ~1 fps still snapshots instead of " +
                                "video — for weak or metered connections. Also engages on its " +
                                "own if streams keep stalling (with a tap-to-restore banner).",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                        )
                    }
                    Switch(
                        checked = lowBandwidthMode,
                        onCheckedChange = onLowBandwidthChange,
                        colors = crumbSwitchColors(),
                    )
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .padding(end = 8.dp),
                    ) {
                        Text(
                            text = "Show \"All Cameras\" quick view",
                            style = MaterialTheme.typography.bodyMedium,
                            color = TextPrimary,
                        )
                        Text(
                            text = "Auto-build a grid of every camera as a selectable " +
                                "default view. Turn off to have your own saved views " +
                                "be the default instead.",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                        )
                    }
                    Switch(
                        checked = showAllCamerasView,
                        onCheckedChange = onShowAllCamerasViewChange,
                        colors = crumbSwitchColors(),
                    )
                }

                // ── Playback section ─────────────────────────────────────────────
                Text(
                    text = "Playback — snapshot captures",
                    style = MaterialTheme.typography.labelMedium,
                    color = TextSecondary,
                    modifier = Modifier.padding(top = 12.dp),
                )
                PtzStyleRow(
                    label = "Full frame",
                    description = "Always save the whole camera frame, even when zoomed in.",
                    selected = !snapshotView,
                    onSelect = {
                        snapshotView = false
                        store.snapshotCapturesView = false
                    },
                )
                PtzStyleRow(
                    label = "Current view (zoomed)",
                    description = "Save just what's on screen — crop to the zoomed/panned area.",
                    selected = snapshotView,
                    onSelect = {
                        snapshotView = true
                        store.snapshotCapturesView = true
                    },
                )

                // ── Security section ──────────────────────────────────────────────
                Text(
                    text = "Security",
                    style = MaterialTheme.typography.labelMedium,
                    color = TextSecondary,
                    modifier = Modifier.padding(top = 12.dp),
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .padding(end = 8.dp),
                    ) {
                        Text(
                            text = "Require biometric unlock",
                            style = MaterialTheme.typography.bodyMedium,
                            color = TextPrimary,
                        )
                        Text(
                            text = when (biometricAvail) {
                                BiometricAvailability.AVAILABLE ->
                                    "Ask for your fingerprint, face, or device PIN each time the app starts."
                                BiometricAvailability.NONE_ENROLLED ->
                                    "Set up a fingerprint or face unlock in your device Settings to use this."
                                else ->
                                    "This device has no biometric hardware available."
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                        )
                    }
                    Switch(
                        checked = biometricOn,
                        enabled = biometricAvail == BiometricAvailability.AVAILABLE && activity != null,
                        onCheckedChange = { checked ->
                            if (checked) {
                                // Confirm the user can actually authenticate before
                                // arming the lock, so we never strand them behind it.
                                activity?.let { act ->
                                    showBiometricPrompt(
                                        act,
                                        "Enable biometric unlock",
                                        "Confirm to turn this on",
                                    ) { ok ->
                                        if (ok) {
                                            biometricOn = true
                                            store.biometricEnabled = true
                                        }
                                    }
                                }
                            } else {
                                biometricOn = false
                                store.biometricEnabled = false
                            }
                        },
                        colors = crumbSwitchColors(),
                    )
                }
            }
        },
    )
}

/** A single radio-selectable preference row: label over a one-line description. */
@Composable
private fun PtzStyleRow(
    label: String,
    description: String,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .selectable(selected = selected, onClick = onSelect, role = Role.RadioButton)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        RadioButton(
            selected = selected,
            onClick = null, // the whole row is the click target
            colors = RadioButtonDefaults.colors(selectedColor = TealAccent),
        )
        Column(modifier = Modifier.padding(start = 8.dp)) {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
                color = TextPrimary,
            )
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = TextSecondary,
            )
        }
    }
}
