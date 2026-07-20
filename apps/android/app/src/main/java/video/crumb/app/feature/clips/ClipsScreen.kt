// SPDX-License-Identifier: AGPL-3.0-or-later

@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package video.crumb.app.feature.clips

import android.content.res.Configuration
import android.view.TextureView
import android.widget.Toast
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddAPhoto
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Hd
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import video.crumb.app.data.ClipDescriptor
import video.crumb.app.di.appContainer
import video.crumb.app.feature.playback.saveFrameToGallery
import video.crumb.app.ui.AddBookmarkDialog
import video.crumb.app.ui.CrumbMode
import video.crumb.app.ui.player.PlayerSurface
import video.crumb.app.ui.CrumbModeTabs
import video.crumb.app.ui.InlineDivider
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.TextSecondary
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** The Clips tab: a thumbnail grid of detection + motion clips with tap-to-play. */
@Composable
fun ClipsScreen(
    onOpenLive: () -> Unit,
    onOpenPlayback: () -> Unit,
    onOpenClipAt: (cameraId: String, timeMs: Long) -> Unit = { _, _ -> },
    onOpenPlates: () -> Unit = {},
) {
    val container = appContainer()
    val vm: ClipsViewModel = viewModel(
        factory = viewModelFactory { initializer { ClipsViewModel(container.repository) } },
    )
    val state by vm.state.collectAsStateWithLifecycle()
    val mediaUrls = remember { container.mediaUrls() }
    val store = container.store
    val caps = store.capabilities
    var playing by remember { mutableStateOf<ClipDescriptor?>(null) }
    var bookmarkFor by remember { mutableStateOf<ClipDescriptor?>(null) }
    // Platform-wide bookmarks toggle (server /status.bookmarks_enabled): hide the
    // clip player's bookmark control when the admin disabled bookmarks. Defaults on.
    var bookmarksEnabled by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        container.repository.status().onSuccess { bookmarksEnabled = it.bookmarksEnabled }
    }
    // In LANDSCAPE the phone is short, so — like the Live/Playback tabs — the
    // filter options ride inline in the top bar next to the mode tabs instead of
    // taking their own row below. In PORTRAIT they stay as a row under the bar.
    val isLandscape =
        LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    if (isLandscape) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            CrumbModeTabs(
                                selected = CrumbMode.CLIPS,
                                onLive = onOpenLive,
                                onPlayback = onOpenPlayback,
                                onClips = {},
                                onPlates = onOpenPlates,
                                showPlayback = caps.playback || store.isAdmin,
                                showClips = caps.clips || store.isAdmin,
                                showPlates = store.platesEnabled,
                            )
                            InlineDivider()
                            ClipsFilters(
                                type = state.type,
                                hours = state.hours,
                                onType = { vm.setType(it) },
                                onHours = { vm.setHours(it) },
                                modifier = Modifier.weight(1f),
                            )
                        }
                    } else {
                        CrumbModeTabs(
                            selected = CrumbMode.CLIPS,
                            onLive = onOpenLive,
                            onPlayback = onOpenPlayback,
                            onClips = {},
                            onPlates = onOpenPlates,
                            showPlayback = caps.playback || store.isAdmin,
                            showClips = caps.clips || store.isAdmin,
                            showPlates = store.platesEnabled,
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { vm.refresh() }) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NavyDeep),
            )
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            if (!isLandscape) {
                ClipsFilters(
                    type = state.type,
                    hours = state.hours,
                    onType = { vm.setType(it) },
                    onHours = { vm.setHours(it) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
            Row(
                Modifier.padding(horizontal = 12.dp).fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                Text(
                    "${state.clips.size} clips",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                )
            }
            Box(Modifier.fillMaxSize()) {
                when {
                    state.loading && state.clips.isEmpty() ->
                        CircularProgressIndicator(Modifier.align(Alignment.Center))
                    state.error != null ->
                        Text(state.error!!, Modifier.align(Alignment.Center).padding(24.dp), color = TextSecondary)
                    state.clips.isEmpty() ->
                        Text("No clips in this window.", Modifier.align(Alignment.Center), color = TextSecondary)
                    else -> LazyVerticalGrid(
                        columns = GridCells.Adaptive(minSize = 160.dp),
                        contentPadding = PaddingValues(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(state.clips, key = { it.id }) { c ->
                            ClipCard(c, mediaUrls) {
                                vm.markViewed(c.id)
                                playing = c
                            }
                        }
                    }
                }
            }
        }
    }

    playing?.let { c ->
        ClipPlayerDialog(
            clip = c,
            mediaUrls = mediaUrls,
            title = clipBadge(c),
            motionHighlightSeconds = state.motionHighlightSeconds,
            // null hides the bookmark control (gated by the platform-wide toggle)
            onBookmark = if (bookmarksEnabled) ({ bookmarkFor = c }) else null,
            onOpenTimeline = {
                val ms = runCatching { Instant.parse(c.startTs).toEpochMilli() }.getOrDefault(0L)
                if (ms > 0L) {
                    playing = null
                    onOpenClipAt(c.cameraId, ms)
                }
            },
            onDismiss = { playing = null },
        )
    }

    // Same "Add bookmark" dialog the Playback transport uses (description +
    // optional protect-from-delete), seeded with the clip's moment + label.
    bookmarkFor?.let { c ->
        val context = LocalContext.current
        AddBookmarkDialog(
            atMs = runCatching { Instant.parse(c.startTs).toEpochMilli() }.getOrDefault(0L),
            initialDescription = clipBadge(c),
            onConfirm = { desc, protectDays, preS, postS ->
                vm.bookmarkClip(c.cameraId, c.startTs, desc, protectDays, preS, postS)
                Toast.makeText(context, "Bookmark added", Toast.LENGTH_SHORT).show()
                bookmarkFor = null
            },
            onDismiss = { bookmarkFor = null },
        )
    }
}

/** The Clips filter controls (type chips + range dropdown). Shared between the
 *  landscape top-bar (inline next to the tabs) and the portrait row below it. */
@Composable
private fun ClipsFilters(
    type: String,
    hours: Long,
    onType: (String) -> Unit,
    onHours: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        listOf("all" to "All", "detection" to "Detections", "motion" to "Motion").forEach { (key, label) ->
            FilterChip(
                selected = type == key,
                onClick = { onType(key) },
                label = { Text(label) },
            )
        }
        Spacer(Modifier.weight(1f))
        RangeSelector(hours = hours, onSelect = onHours)
    }
}

/** Compact "Last N" range dropdown for the Clips feed window. */
@Composable
private fun RangeSelector(hours: Long, onSelect: (Long) -> Unit) {
    val options = listOf(
        6L to "Last 6 hours",
        24L to "Last 24 hours",
        72L to "Last 3 days",
        168L to "Last 7 days",
        336L to "Last 14 days",
        720L to "Last 30 days",
    )
    var open by remember { mutableStateOf(false) }
    val current = options.firstOrNull { it.first == hours }?.second ?: "Last ${hours}h"
    Box {
        TextButton(onClick = { open = true }) { Text(current) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (h, label) ->
                DropdownMenuItem(
                    text = { Text(label) },
                    onClick = { open = false; onSelect(h) },
                )
            }
        }
    }
}

@Composable
private fun ClipCard(c: ClipDescriptor, mediaUrls: video.crumb.app.data.MediaUrls, onClick: () -> Unit) {
    // Resolved via the per-camera scoped-token cache — a plain cache hit once
    // warm, a network round-trip only on the first card for that camera / a
    // near-expiry refresh.
    var thumbUrl by remember(c.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(c.id) {
        thumbUrl = runCatching { mediaUrls.clipThumbUrl(c.cameraId, c.id) }.getOrNull()
    }
    Column(
        Modifier
            // Watched: subtle dim so reviewed clips recede without disappearing.
            .alpha(if (c.viewed) 0.55f else 1f)
            .clip(RoundedCornerShape(9.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .background(Color.Black),
        ) {
            AsyncImage(
                model = thumbUrl,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            Text(
                clipBadge(c),
                color = Color.White,
                style = MaterialTheme.typography.labelSmall,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(6.dp)
                    .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 5.dp, vertical = 2.dp),
            )
            if (c.durationMs > 0) {
                Text(
                    "${c.durationMs / 1000}s",
                    color = Color.White,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(6.dp)
                        .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(3.dp))
                        .padding(horizontal = 4.dp, vertical = 1.dp),
                )
            }
        }
        Column(Modifier.padding(7.dp)) {
            Text(
                c.cameraName,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                formatClipTime(c.startTs),
                style = MaterialTheme.typography.labelSmall,
                color = TextSecondary,
            )
        }
    }
}

@OptIn(UnstableApi::class)
@Composable
private fun ClipPlayerDialog(
    clip: ClipDescriptor,
    mediaUrls: video.crumb.app.data.MediaUrls,
    title: String,
    motionHighlightSeconds: Int,
    onBookmark: (() -> Unit)?,
    onOpenTimeline: () -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // Preview (small, reduced res/fps) by default; the HD button swaps to the
    // source-resolution clip, preserving the current position.
    var full by remember { mutableStateOf(false) }
    // The TextureView-backed PlayerView, captured for the snapshot action.
    var playerView by remember { mutableStateOf<PlayerView?>(null) }
    val exo = remember { ExoPlayer.Builder(context).build() }
    DisposableEffect(Unit) { onDispose { exo.release() } }

    // Pause when backgrounded (matches PlaybackScreen) — otherwise this dialog's
    // audio/video keeps playing after the user leaves the app.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, exo) {
        var wasPlaying = false
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> {
                    wasPlaying = exo.playWhenReady
                    exo.pause()
                }
                Lifecycle.Event.ON_RESUME -> if (wasPlaying) exo.play()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The clip URL carries a per-camera scoped token (see MediaTokenCache), so
    // resolving it is a suspend call — prepare the player once the FIRST
    // (preview-quality) URL is ready, keyed on the clip so switching clips
    // re-resolves.
    LaunchedEffect(clip.id) {
        val url = runCatching { mediaUrls.clipVideoUrl(clip.cameraId, clip.id, "preview") }.getOrNull()
            ?: return@LaunchedEffect
        exo.setMediaItem(MediaItem.fromUri(url))
        exo.prepare()
        exo.playWhenReady = true
    }

    // Gate the motion auto-zoom on the FIRST rendered frame. Without this, the
    // zoom-to-motion animation runs against the still-black surface: it zooms
    // into black, holds, then zooms back out before the video even appears.
    // Reset per clip; onRenderedFirstFrame fires again for each newly loaded clip.
    var videoReady by remember(clip.id) { mutableStateOf(false) }
    DisposableEffect(exo) {
        val listener = object : Player.Listener {
            override fun onRenderedFirstFrame() { videoReady = true }
        }
        exo.addListener(listener)
        onDispose { exo.removeListener(listener) }
    }

    // Snapshot: grab the current frame off the TextureView → device gallery
    // (same path the Playback snapshot uses).
    val onSnapshot: () -> Unit = {
        val bmp = (playerView?.videoSurfaceView as? TextureView)?.takeIf { it.isAvailable }?.bitmap
        if (bmp != null) {
            scope.launch {
                val saved = saveFrameToGallery(context, bmp, clip.cameraName.ifBlank { "clip" })
                Toast.makeText(
                    context,
                    if (saved != null) "Snapshot saved to ${saved.displayPath}" else "Snapshot failed",
                    Toast.LENGTH_SHORT,
                ).show()
            }
        } else {
            Toast.makeText(context, "Snapshot unavailable — video not ready", Toast.LENGTH_SHORT).show()
        }
    }

    // In landscape, a 16:9 video at ~full width is taller than the screen and
    // would push the header (and its close button) off-screen — so there pin the
    // header and let the video fill the remaining height instead.
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth(if (landscape) 0.94f else 0.96f)
                .then(if (landscape) Modifier.fillMaxHeight(0.96f) else Modifier)
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surface),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(start = 14.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                IconButton(onClick = onOpenTimeline) {
                    Icon(Icons.Filled.VideoLibrary, contentDescription = "View this moment on the timeline")
                }
                IconButton(onClick = onSnapshot) {
                    Icon(Icons.Filled.AddAPhoto, contentDescription = "Snapshot current frame")
                }
                onBookmark?.let { cb ->
                    IconButton(onClick = cb) {
                        Icon(Icons.Filled.BookmarkBorder, contentDescription = "Bookmark")
                    }
                }
                IconButton(onClick = {
                    val next = !full
                    full = next
                    val at = exo.currentPosition
                    val quality = if (next) "full" else "preview"
                    scope.launch {
                        val url = runCatching { mediaUrls.clipVideoUrl(clip.cameraId, clip.id, quality) }.getOrNull()
                            ?: return@launch
                        exo.setMediaItem(MediaItem.fromUri(url))
                        exo.prepare()
                        exo.seekTo(at)
                        exo.playWhenReady = true
                    }
                }) {
                    Icon(
                        Icons.Filled.Hd,
                        contentDescription = if (full) "Full quality (on)" else "Full quality (off)",
                        tint = if (full) MaterialTheme.colorScheme.primary else LocalContentColor.current,
                    )
                }
                IconButton(onClick = onDismiss) { Icon(Icons.Filled.Close, contentDescription = "Close") }
            }
            ClipZoomSurface(
                clipId = clip.id,
                highlightBbox = clip.motionBbox?.takeIf { clip.kind == "motion" },
                highlightSeconds = motionHighlightSeconds,
                ready = videoReady,
                modifier = Modifier
                    .fillMaxWidth()
                    .then(if (landscape) Modifier.weight(1f) else Modifier.aspectRatio(16f / 9f))
                    .background(Color.Black),
            ) {
                PlayerSurface(
                    player = exo,
                    textureView = true,
                    useController = true,
                    onViewReady = { playerView = it },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}

/**
 * Clip-player digital zoom + motion-highlight auto-zoom. Unlike the shared
 * [video.crumb.app.ui.player.ZoomableVideoSurface], this keeps the ExoPlayer
 * controller usable: it only consumes a two-finger pinch (and a one-finger pan
 * once zoomed in), so single-finger taps and the scrub bar still reach the
 * controls at 1x.
 *
 * When [highlightBbox] (normalized `[x,y,w,h]`) is present and [highlightSeconds]
 * > 0, it eases into framing that region for the configured time, then eases back
 * to the full frame — so a motion clip in this small viewer briefly shows WHERE
 * the motion was. Any touch hands control to the user and cancels the auto-zoom.
 *
 * Transform model mirrors the shared surface: top-left [TransformOrigin],
 * `translation = -offset * zoom`, `offset` clamped to `[0, size·(1 − 1/zoom)]`.
 */
@Composable
private fun ClipZoomSurface(
    clipId: String,
    highlightBbox: List<Float>?,
    highlightSeconds: Int,
    ready: Boolean,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val minScale = 1f
    val maxScale = 5f
    var zoom by remember(clipId) { mutableFloatStateOf(1f) }
    var offset by remember(clipId) { mutableStateOf(Offset.Zero) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    var userTookOver by remember(clipId) { mutableStateOf(false) }

    // Motion-highlight auto-zoom: animate in → hold → animate out. Re-keyed per
    // clip and on first layout; a user gesture sets userTookOver and the writes
    // below no-op so control yields immediately.
    LaunchedEffect(clipId, size, highlightSeconds, ready) {
        val bb = highlightBbox
        // Hold the auto-zoom until the player has rendered a frame, else it
        // animates into (and back out of) a black surface before the clip shows.
        if (!ready) return@LaunchedEffect
        if (highlightSeconds <= 0 || bb == null || bb.size != 4) return@LaunchedEffect
        if (size.width == 0 || size.height == 0) return@LaunchedEffect
        val region = maxOf(bb[2], bb[3])
        if (region <= 0f || region > 0.7f) return@LaunchedEffect // too big to help
        val target = minOf(4f, maxOf(1.4f, 0.9f / region))
        val cx = bb[0] + bb[2] / 2f
        val cy = bb[1] + bb[3] / 2f
        fun offsetFor(s: Float): Offset {
            val maxX = (size.width * (1f - 1f / s)).coerceAtLeast(0f)
            val maxY = (size.height * (1f - 1f / s)).coerceAtLeast(0f)
            return Offset(
                (size.width * (cx - 0.5f / s)).coerceIn(0f, maxX),
                (size.height * (cy - 0.5f / s)).coerceIn(0f, maxY),
            )
        }
        val tgt = offsetFor(target)
        animate(0f, 1f, animationSpec = tween(450)) { p, _ ->
            if (!userTookOver) { zoom = 1f + (target - 1f) * p; offset = Offset(tgt.x * p, tgt.y * p) }
        }
        if (userTookOver) return@LaunchedEffect
        delay(highlightSeconds * 1000L)
        if (userTookOver) return@LaunchedEffect
        val fromS = zoom
        val fromO = offset
        animate(0f, 1f, animationSpec = tween(450)) { p, _ ->
            if (!userTookOver) { zoom = fromS + (1f - fromS) * p; offset = Offset(fromO.x * (1f - p), fromO.y * (1f - p)) }
        }
    }

    Box(
        modifier = modifier
            .onSizeChanged { size = it }
            .pointerInput(clipId) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.count { it.pressed }
                        val zoomChange = event.calculateZoom()
                        val panChange = event.calculatePan()
                        // Only act on a pinch, or a pan once already zoomed in — so at
                        // 1x single-finger taps/scrub reach the ExoPlayer controller.
                        val handle = pressed >= 2 || zoom > 1.001f
                        if (handle && (zoomChange != 1f || panChange != Offset.Zero)) {
                            userTookOver = true
                            val centroid = event.calculateCentroid(useCurrent = true)
                            val oldScale = zoom
                            val newScale = (zoom * zoomChange).coerceIn(minScale, maxScale)
                            var newOffset = (offset + centroid / oldScale) -
                                (centroid / newScale + panChange / oldScale)
                            zoom = newScale
                            val maxX = (size.width * (1f - 1f / newScale)).coerceAtLeast(0f)
                            val maxY = (size.height * (1f - 1f / newScale)).coerceAtLeast(0f)
                            newOffset = Offset(
                                newOffset.x.coerceIn(0f, maxX),
                                newOffset.y.coerceIn(0f, maxY),
                            )
                            offset = newOffset
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                        }
                    } while (event.changes.any { it.pressed })
                }
            }
            .graphicsLayer {
                scaleX = zoom
                scaleY = zoom
                translationX = -offset.x * zoom
                translationY = -offset.y * zoom
                transformOrigin = TransformOrigin(0f, 0f)
                clip = true
            },
    ) {
        content()
    }
}

private fun clipBadge(c: ClipDescriptor): String =
    if (c.kind == "motion") {
        "Motion"
    } else {
        c.label.ifBlank { "Detection" }.replaceFirstChar { it.uppercase() }
    }

private val CLIP_TIME_FMT: DateTimeFormatter = DateTimeFormatter.ofPattern("MMM d, HH:mm:ss")

private fun formatClipTime(iso: String): String = try {
    Instant.parse(iso).atZone(ZoneId.systemDefault()).format(CLIP_TIME_FMT)
} catch (e: Exception) {
    iso
}
