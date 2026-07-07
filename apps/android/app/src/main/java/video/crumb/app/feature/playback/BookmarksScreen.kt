// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import video.crumb.app.data.BookmarkDto
import video.crumb.app.data.toUserMessage
import video.crumb.app.di.appContainer
import video.crumb.app.ui.Time
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextSecondary

/**
 * Bookmarks list — every saved playback moment (server-shared), newest first.
 * Tapping a row jumps to that camera's playback at the bookmarked time; the
 * trailing trash icon deletes it.
 *
 * @param onBack  Pop back.
 * @param onOpen  `(cameraId, tsMs)` — open single-camera playback at the moment.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookmarksScreen(
    onBack: () -> Unit,
    onOpen: (String, Long) -> Unit,
) {
    val repo = appContainer().repository
    val scope = rememberCoroutineScope()

    var items by remember { mutableStateOf<List<BookmarkDto>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    fun reload() {
        scope.launch {
            loading = true
            repo.bookmarks()
                .onSuccess { items = it; error = null }
                .onFailure { error = it.toUserMessage() }
            loading = false
        }
    }
    androidx.compose.runtime.LaunchedEffect(Unit) { reload() }

    Scaffold(
        containerColor = NavyDeep,
        topBar = {
            TopAppBar(
                title = { Text("Bookmarks") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NavyDeep,
                    titleContentColor = MaterialTheme.colorScheme.onSurface,
                    navigationIconContentColor = MaterialTheme.colorScheme.onSurface,
                ),
            )
        },
    ) { pad ->
        Box(modifier = Modifier.fillMaxSize().padding(pad)) {
            when {
                loading -> CircularProgressIndicator(
                    modifier = Modifier.align(Alignment.Center),
                    color = TealAccent,
                )

                error != null -> Column(
                    modifier = Modifier.align(Alignment.Center).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(error!!, color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = { reload() }) { Text("Retry", color = TealAccent) }
                }

                items.isEmpty() -> Column(
                    modifier = Modifier.align(Alignment.Center).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("No bookmarks yet", color = TextSecondary)
                    Text(
                        "Add one from a camera's playback (the bookmark button).",
                        color = TextSecondary,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }

                else -> LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(items, key = { it.id }) { bm ->
                        BookmarkRow(
                            bookmark = bm,
                            onClick = {
                                val ms = runCatching { Time.parseToMillis(bm.ts) }.getOrNull()
                                if (ms != null) onOpen(bm.cameraId, ms)
                            },
                            onDelete = {
                                scope.launch {
                                    repo.deleteBookmark(bm.id).onSuccess {
                                        items = items.filterNot { it.id == bm.id }
                                    }
                                }
                            },
                        )
                        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun BookmarkRow(
    bookmark: BookmarkDto,
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = bookmark.cameraName ?: "Camera",
                    color = TealAccent,
                    fontWeight = FontWeight.SemiBold,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    text = runCatching { Time.dateTime(bookmark.ts) }.getOrDefault(bookmark.ts),
                    color = TextSecondary,
                    style = MaterialTheme.typography.bodySmall,
                )
                val protectedActive = bookmark.protectUntil?.let {
                    runCatching { Time.parseToMillis(it) > System.currentTimeMillis() }.getOrDefault(false)
                } ?: false
                if (protectedActive) {
                    Icon(
                        Icons.Default.Lock,
                        contentDescription = "Protected from auto-delete",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
            val desc = bookmark.description?.trim()
            Text(
                text = if (desc.isNullOrEmpty()) "No description" else desc,
                color = if (desc.isNullOrEmpty()) TextSecondary else MaterialTheme.colorScheme.onSurface,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 2,
            )
        }
        IconButton(onClick = onDelete) {
            Icon(
                Icons.Default.Delete,
                contentDescription = "Delete bookmark",
                tint = TextSecondary,
            )
        }
    }
}
