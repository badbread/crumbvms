// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.about

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import video.crumb.app.BuildConfig
import video.crumb.app.feature.update.UpdateCheckRow
import video.crumb.app.feature.update.UpdateUiState
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary

/**
 * "About / Build info" dialog — surfaces the exact build that's running so we can
 * tell at a glance WHICH app/build is installed when debugging.
 *
 * The most useful line is the **package** (`applicationId`): after the
 * Sentinel→Crumb rename the old `com.sentinel.nvr` app can still be installed
 * alongside the new `video.crumb.app`, and the old one has no motion tuner. If
 * this panel shows `com.sentinel.nvr*`, you're on the stale app; the current
 * build is `video.crumb.app` (debug: `video.crumb.app.debug`).
 *
 * @param serverUrl The currently-configured API server, shown for context.
 * @param updateState Update-available check state (issue #7). When the server
 *   reports the check enabled, an always-present update field is shown
 *   ("Checking..." / "You're up to date (X)" / "Update available: X → release
 *   notes") with a "Check now" button; hidden entirely when the server reports
 *   the check off (or an older server 404s).
 * @param onOpened Called once when the dialog opens, to trigger a fresh
 *   (normal, non-forced) check so the update field is never stale — a client
 *   that first checked while the server had the feature OFF can still discover
 *   it was turned ON.
 * @param onCheckNow Force an immediate re-check against the server ("Check now").
 * @param onDismiss Close the dialog.
 */
@Composable
fun AboutDialog(
    serverUrl: String,
    updateState: UpdateUiState,
    onOpened: () -> Unit,
    onCheckNow: () -> Unit,
    onDismiss: () -> Unit,
) {
    // Opening About triggers a fresh check so the field below reflects current
    // server state rather than a cached (possibly hours-stale) one.
    LaunchedEffect(Unit) { onOpened() }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
        title = { Text("About CrumbVMS") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                InfoRow("Version", "${BuildConfig.VERSION_NAME} (build ${BuildConfig.VERSION_CODE})")
                InfoRow("Package", BuildConfig.APPLICATION_ID)
                InfoRow("Built", BuildConfig.BUILD_TIME)
                InfoRow("Commit", BuildConfig.GIT_SHA)
                InfoRow("Build type", BuildConfig.BUILD_TYPE)
                InfoRow("Server", serverUrl)

                // Always present while the server has the check enabled; hidden
                // when it reports enabled:false or an older server 404s.
                if (updateState.enabled) {
                    HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
                    UpdateCheckRow(state = updateState, onCheckNow = onCheckNow)
                }
            }
        },
    )
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = TextSecondary,
            modifier = Modifier.width(84.dp),
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = TextPrimary,
            textAlign = TextAlign.Start,
            modifier = Modifier.weight(1f),
        )
    }
}
