// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextSecondary

/**
 * Open [url] in the platform browser. Silently does nothing if no activity
 * can handle it — a release-notes link is a nicety, never worth crashing over.
 */
private fun openInBrowser(context: Context, url: String) {
    runCatching {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}

/**
 * Non-intrusive dismissible banner: "Update available → release notes"
 * (issue #7 §3). Callers should only compose this while
 * [UpdateUiState.showBanner] is true.
 */
@Composable
fun UpdateAvailableBanner(
    state: UpdateUiState,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val version = state.latestVersion ?: return
    val notesUrl = state.notesUrl
    Row(
        modifier = modifier
            .background(NavySurface)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = Icons.Default.SystemUpdate,
            contentDescription = null,
            tint = TealAccent,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = "Update available: v$version",
            style = MaterialTheme.typography.labelMedium,
            color = TextSecondary,
            modifier = Modifier
                .weight(1f)
                .clickable(enabled = notesUrl != null) { notesUrl?.let { openInBrowser(context, it) } },
        )
        if (notesUrl != null) {
            TextButton(
                onClick = { openInBrowser(context, notesUrl) },
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
            ) {
                Text("Release notes", color = TealAccent, style = MaterialTheme.typography.labelMedium)
            }
        }
        IconButton(
            onClick = onDismiss,
            modifier = Modifier.size(28.dp),
        ) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = "Dismiss",
                tint = TextSecondary,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

/**
 * Settings/About row (issue #7 §3). Callers should compose this whenever the
 * server reports the check enabled ([UpdateUiState.enabled]); it is then always
 * present, showing one of three statuses — "Checking..." (first check in
 * flight), "Update available: vX -> release notes" (opens
 * [UpdateUiState.notesUrl] in the browser), or "You're up to date (vX)" — with
 * a "Check now" button always reachable. The caller hides it when the server
 * reports `enabled:false` / 404.
 */
@Composable
fun UpdateCheckRow(
    state: UpdateUiState,
    onCheckNow: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        when {
            state.updateAvailable -> {
                val version = state.latestVersion.orEmpty()
                val notesUrl = state.notesUrl
                Text(
                    text = "Update available: v$version",
                    style = MaterialTheme.typography.bodyMedium,
                    color = TealAccent,
                    modifier = Modifier.clickable(enabled = notesUrl != null) {
                        notesUrl?.let { openInBrowser(context, it) }
                    },
                )
                if (notesUrl != null) {
                    Text(
                        text = "Tap to view release notes",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary,
                    )
                }
            }
            // A result is in hand and there is no newer release: up to date.
            state.everChecked -> {
                Text(
                    text = "You're up to date (v${state.ownVersion})",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                )
            }
            // First check still in flight (nothing resolved yet).
            else -> {
                Text(
                    text = "Checking...",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                )
            }
        }
        TextButton(
            onClick = onCheckNow,
            enabled = !state.checking,
            contentPadding = PaddingValues(horizontal = 0.dp, vertical = 4.dp),
        ) {
            Text(if (state.checking) "Checking..." else "Check now", color = TealAccent)
        }
    }
}
