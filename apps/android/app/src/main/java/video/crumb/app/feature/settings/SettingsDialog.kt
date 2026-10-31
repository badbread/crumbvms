// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.settings

import video.crumb.app.ui.theme.Spacing
import video.crumb.app.ui.dialogEntrance
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.heightIn
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
     * Adaptive live-wall quality (#384). Mirrored from the caller (not read from
     * [store] here) so the wall reacts the moment the switch flips. Governs both the
     * config-time guardrail nudge and the runtime decode backpressure.
     */
    adaptiveWallQuality: Boolean,
    onAdaptiveWallQualityChange: (Boolean) -> Unit,
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
    var advancedPlayback by remember { mutableStateOf(store.advancedPlaybackControls) }
    var haShowEntityId by remember { mutableStateOf(store.showHaEntityId) }
    var haShowDeviceType by remember { mutableStateOf(store.showHaDeviceType) }

    // Security — biometric app lock.
    val context = LocalContext.current
    val activity = context as? FragmentActivity
    val biometricAvail = remember { biometricAvailability(context) }
    var biometricOn by remember { mutableStateOf(store.biometricEnabled) }

    AlertDialog(
        onDismissRequest = onDismiss,
        // S1: 28 dp radius (the M3 extra-large shape from the theme) and the shared
        // scale-and-fade entry (G5).
        modifier = Modifier.dialogEntrance(),
        shape = MaterialTheme.shapes.extraLarge,
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Done") }
        },
        title = { Text("Settings", style = MaterialTheme.typography.titleLarge) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                SectionHeader("PTZ control style", first = true)
                ChoiceRow(
                    label = "Joystick wheel",
                    description = "A round 8-direction wheel at the bottom.",
                    selected = ptzStyle == "wheel",
                    onSelect = {
                        ptzStyle = "wheel"
                        store.ptzStyle = "wheel"
                    },
                )
                ChoiceRow(
                    label = "Edge arrows",
                    description = "Arrows pinned to the edges of the view.",
                    selected = ptzStyle == "edges",
                    onSelect = {
                        ptzStyle = "edges"
                        store.ptzStyle = "edges"
                    },
                )

                SectionHeader("Live view")
                SwitchRow(
                    title = "Motion tuner button",
                    description = "In the fullscreen live view. Admin only.",
                    checked = motionTunerOn,
                    onCheckedChange = { checked ->
                        motionTunerOn = checked
                        store.motionTunerEnabled = checked
                    },
                )
                SwitchRow(
                    title = "Low bandwidth mode",
                    description = "Stills at about 1 fps instead of video.",
                    checked = lowBandwidthMode,
                    onCheckedChange = onLowBandwidthChange,
                )
                SwitchRow(
                    title = "Adaptive video quality",
                    description = "Drops tiles to stills when the decoder is saturated.",
                    checked = adaptiveWallQuality,
                    onCheckedChange = onAdaptiveWallQualityChange,
                )
                SwitchRow(
                    title = "Show \"All cameras\" view",
                    description = "A grid of every camera in the view list.",
                    checked = showAllCamerasView,
                    onCheckedChange = onShowAllCamerasViewChange,
                )

                // What the entity "more-info" popup (opened from the HA sheet or an
                // on-video badge) shows below the state. Both default on; read/written
                // straight through to [store], and [HaMoreInfoDialog] reads the same
                // flags when it next opens.
                SectionHeader("Home Assistant popup")
                SwitchRow(
                    title = "Show entity type",
                    description = "The Type row, for example Light or Garage door.",
                    checked = haShowDeviceType,
                    onCheckedChange = { checked ->
                        haShowDeviceType = checked
                        store.showHaDeviceType = checked
                    },
                )
                SwitchRow(
                    title = "Show entity ID",
                    description = "The raw entity_id, for example light.front_porch.",
                    checked = haShowEntityId,
                    onCheckedChange = { checked ->
                        haShowEntityId = checked
                        store.showHaEntityId = checked
                    },
                )

                SectionHeader("Playback")
                SwitchRow(
                    title = "Show advanced playback controls",
                    description = "Off keeps the bar simple, with the rest under More.",
                    checked = advancedPlayback,
                    onCheckedChange = { checked ->
                        advancedPlayback = checked
                        store.advancedPlaybackControls = checked
                    },
                )

                SectionHeader("Playback snapshots")
                ChoiceRow(
                    label = "Full frame",
                    description = "The whole frame, even when zoomed in.",
                    selected = !snapshotView,
                    onSelect = {
                        snapshotView = false
                        store.snapshotCapturesView = false
                    },
                )
                ChoiceRow(
                    label = "Current view (zoomed)",
                    description = "Just what is on screen.",
                    selected = snapshotView,
                    onSelect = {
                        snapshotView = true
                        store.snapshotCapturesView = true
                    },
                )

                SectionHeader("Security")
                SwitchRow(
                    title = "Require biometric unlock",
                    description = when (biometricAvail) {
                        BiometricAvailability.AVAILABLE ->
                            "Fingerprint, face or PIN each time the app starts."
                        BiometricAvailability.NONE_ENROLLED ->
                            "Set up fingerprint or face unlock in device Settings first."
                        else ->
                            "No biometric hardware on this device."
                    },
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
                )
            }
        },
    )
}

/**
 * S2: section header, 11 sp uppercase in the tab accent, 24 dp above (none for the
 * first) and 8 dp below.
 */
@Composable
private fun SectionHeader(text: String, first: Boolean = false) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 0.6.sp),
        color = TealAccent,
        modifier = Modifier.padding(top = if (first) 0.dp else Spacing.xl, bottom = Spacing.s),
    )
}

/** S4: one-line description, 12 sp at 55%. */
@Composable
private fun SettingDescription(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        color = TextPrimary.copy(alpha = 0.55f),
    )
}

/**
 * S3: a switch row. At least 48 dp tall, the switch vertically centred against the
 * text block and 12 dp from it, so every switch lines up on one right edge.
 */
@Composable
private fun SwitchRow(
    title: String,
    description: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .padding(vertical = Spacing.xs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(text = title, style = MaterialTheme.typography.bodyMedium, color = TextPrimary)
            SettingDescription(description)
        }
        Switch(
            checked = checked,
            enabled = enabled,
            onCheckedChange = onCheckedChange,
            colors = crumbSwitchColors(),
        )
    }
}

/** S3: a radio-selectable preference row: label over a one-line description. */
@Composable
private fun ChoiceRow(
    label: String,
    description: String,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .selectable(selected = selected, onClick = onSelect, role = Role.RadioButton)
            .padding(vertical = Spacing.xs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        RadioButton(
            selected = selected,
            onClick = null, // the whole row is the click target
            colors = RadioButtonDefaults.colors(selectedColor = TealAccent),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(text = label, style = MaterialTheme.typography.bodyMedium, color = TextPrimary)
            SettingDescription(description)
        }
    }
}
