// SPDX-License-Identifier: AGPL-3.0-or-later

@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package video.crumb.app.feature.plates

import android.content.res.Configuration
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.ui.AspectRatioFrameLayout
import video.crumb.app.data.CrumbRepository
import video.crumb.app.data.MediaUrls
import video.crumb.app.data.PlateRead
import video.crumb.app.data.PlateWatchlistEntry
import video.crumb.app.ui.AddBookmarkDialog
import video.crumb.app.ui.Time
import video.crumb.app.ui.player.PlayerSurface
import video.crumb.app.ui.player.ZoomableVideoSurface
import video.crumb.app.ui.theme.JetBrainsMono
import video.crumb.app.ui.theme.LprAccent
import video.crumb.app.ui.theme.LprAccentChip
import video.crumb.app.ui.theme.LprAccentHot
import video.crumb.app.ui.theme.LprWatchAmber
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary
import java.time.Instant

/** Everything the profile screen does to the outside world, as one bundle of callbacks. */
class PlateProfileActions(
    val onBack: () -> Unit,
    val onSelectVisit: (PlateRead) -> Unit,
    val onToggleWatch: () -> Unit,
    val onCopy: () -> Unit,
    val onRename: () -> Unit,
    val onCorrect: () -> Unit,
    val onReport: (PlateRead) -> Unit,
    val onOpenPlayback: (PlateRead) -> Unit,
    val onUndoAlias: (String) -> Unit,
    val onAddBookmark: (cameraId: String, atMs: Long, description: String, protectDays: Int?, preSeconds: Int?, postSeconds: Int?) -> Unit,
)

/**
 * The plate profile (3B): a distinct full screen with a clear back. The video of
 * the selected sighting is pinned at the top with real controls, pinch zoom and
 * a bookmark button. Under it, three tabs: Visits (tap one to swap the video),
 * History (hour-of-day bars, camera split, 30 days) and Details (name,
 * watchlist, known misreads, the Correct plate button). In landscape the video
 * sits left and the tabs right.
 */
@Composable
fun PlateProfileScreen(
    profile: PlateProfileState,
    cameraNames: Map<String, String>,
    repo: CrumbRepository,
    mediaUrls: MediaUrls,
    isAdmin: Boolean,
    watchEntry: PlateWatchlistEntry?,
    regularMinReads: Int,
    statsTz: String,
    bookmarksEnabled: Boolean,
    actions: PlateProfileActions,
    modifier: Modifier = Modifier,
) {
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val playback = rememberSightingPlayback(repo, mediaUrls)
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var menuOpen by remember { mutableStateOf(false) }
    var bookmarkAt by remember { mutableStateOf<Long?>(null) }

    val selected = profile.selected
    val visit = remember(profile.visits, selected.id) {
        profile.visits.firstOrNull { v -> v.reads.any { it.id == selected.id } }
    }
    val focusMs = remember(selected.id) { Time.parseToMillis(selected.ts) }

    // Start (or swap to) the selected sighting. The window is re-fitted below once
    // the visits have loaded, without restarting the video.
    LaunchedEffect(selected.id, selected.cameraId) {
        val (ws, we) = sightingWindow(focusMs, focusMs, focusMs)
        playback.start(selected.cameraId, ws, we, startAtMs = focusMs - 4_000L, fallbackAtMs = focusMs)
    }
    LaunchedEffect(visit?.id, profile.loading) {
        if (visit != null) {
            val (ws, we) = sightingWindow(visit.startMs, visit.endMs, focusMs)
            playback.setWindow(ws, we)
        }
    }

    val watched = watchEntry != null && !watchEntry.isIgnore
    val stats = profile.stats
    val badge = when {
        stats != null && stats.isNewPlate() -> "New"
        stats != null && stats.isRegularPlate(regularMinReads) -> "Regular"
        else -> null
    }
    val camName = cameraNames[selected.cameraId] ?: "Unknown camera"

    Box(modifier.fillMaxSize().background(NavyDeep)) {
        if (landscape) {
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.weight(0.58f).fillMaxHeight().background(Color.Black)) {
                    SightingVideo(
                        playback = playback,
                        read = selected,
                        cameraName = camName,
                        canBookmark = bookmarksEnabled,
                        onBookmark = { bookmarkAt = playback.currentAbs() },
                        modifier = Modifier.fillMaxSize(),
                        captionTopPadding = 56.dp,
                    )
                    ProfileTopBar(
                        profile = profile,
                        badge = badge,
                        watched = watched,
                        canToggleWatch = isAdmin,
                        overVideo = true,
                        onBack = actions.onBack,
                        onToggleWatch = actions.onToggleWatch,
                        onMenu = { menuOpen = true },
                        modifier = Modifier.align(Alignment.TopStart).fillMaxWidth(),
                    )
                }
                Column(Modifier.weight(0.42f).fillMaxHeight()) {
                    ProfileFacts(profile)
                    ProfileTabs(tab) { tab = it }
                    ProfilePanes(
                        tab = tab,
                        profile = profile,
                        visit = visit,
                        cameraNames = cameraNames,
                        mediaUrls = mediaUrls,
                        isAdmin = isAdmin,
                        watchEntry = watchEntry,
                        statsTz = statsTz,
                        actions = actions,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        } else {
            Column(Modifier.fillMaxSize()) {
                ProfileTopBar(
                    profile = profile,
                    badge = badge,
                    watched = watched,
                    canToggleWatch = isAdmin,
                    overVideo = false,
                    onBack = actions.onBack,
                    onToggleWatch = actions.onToggleWatch,
                    onMenu = { menuOpen = true },
                    modifier = Modifier.fillMaxWidth(),
                )
                SightingVideo(
                    playback = playback,
                    read = selected,
                    cameraName = camName,
                    canBookmark = bookmarksEnabled,
                    onBookmark = { bookmarkAt = playback.currentAbs() },
                    modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
                )
                ProfileFacts(profile)
                ProfileTabs(tab) { tab = it }
                ProfilePanes(
                    tab = tab,
                    profile = profile,
                    visit = visit,
                    cameraNames = cameraNames,
                    mediaUrls = mediaUrls,
                    isAdmin = isAdmin,
                    watchEntry = watchEntry,
                    statsTz = statsTz,
                    actions = actions,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }

    if (menuOpen) {
        ProfileMenuSheet(
            named = !profile.displayName.isNullOrBlank(),
            isAdmin = isAdmin,
            canCorrect = canOfferPlateCorrection(isAdmin, profile.plate),
            onCopy = { menuOpen = false; actions.onCopy() },
            onRename = { menuOpen = false; actions.onRename() },
            onCorrect = { menuOpen = false; actions.onCorrect() },
            onReport = { menuOpen = false; actions.onReport(selected) },
            onPlayback = { menuOpen = false; actions.onOpenPlayback(selected) },
            onDismiss = { menuOpen = false },
        )
    }

    bookmarkAt?.let { at ->
        AddBookmarkDialog(
            atMs = at,
            initialDescription = listOfNotNull(profile.plate, profile.displayName?.takeIf { it.isNotBlank() }).joinToString(" "),
            onConfirm = { desc, d, pre, post ->
                actions.onAddBookmark(selected.cameraId, at, desc, d, pre, post)
                bookmarkAt = null
            },
            onDismiss = { bookmarkAt = null },
        )
    }
}

// ─── top bar ────────────────────────────────────────────────────────────────

@Composable
private fun ProfileTopBar(
    profile: PlateProfileState,
    badge: String?,
    watched: Boolean,
    canToggleWatch: Boolean,
    overVideo: Boolean,
    onBack: () -> Unit,
    onToggleWatch: () -> Unit,
    onMenu: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tint = if (overVideo) Color.White else Color(0xFFC7CBD3)
    Row(
        modifier = modifier
            .height(56.dp)
            .then(
                if (overVideo) {
                    Modifier.background(Brush.verticalGradient(listOf(Color(0xB3000000), Color.Transparent)))
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = tint)
        }
        Column(Modifier.weight(1f).padding(start = 4.dp)) {
            Text(
                profile.plate.ifEmpty { "No plate" },
                color = if (overVideo) Color.White else TextPrimary,
                fontFamily = JetBrainsMono,
                fontWeight = FontWeight.Bold,
                fontSize = 18.sp,
                letterSpacing = 1.sp,
                maxLines = 1,
            )
            val name = profile.displayName?.takeIf { it.isNotBlank() }
            if (name != null) {
                Text(name, color = LprAccentHot, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (badge != null) {
            Text(
                badge.uppercase(),
                color = if (badge == "New") LprAccentHot else TextSecondary,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.6.sp,
                modifier = Modifier
                    .background(if (badge == "New") LprAccentChip else Color(0xFF2E313A), RoundedCornerShape(4.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
        // The star is a control for admins (watchlist writes are admin-only); a
        // viewer only sees whether the plate is on the list.
        if (canToggleWatch || watched) {
            IconButton(onClick = onToggleWatch, enabled = canToggleWatch) {
                Icon(
                    if (watched) Icons.Filled.Star else Icons.Filled.StarBorder,
                    contentDescription = if (watched) "On the watchlist" else "Add to the watchlist",
                    tint = if (watched) LprWatchAmber else tint,
                )
            }
        }
        IconButton(onClick = onMenu) {
            Icon(Icons.Filled.MoreVert, contentDescription = "More", tint = tint)
        }
    }
}

// ─── video ──────────────────────────────────────────────────────────────────

/**
 * The pinned video: pinch to zoom (double-tap resets), the detection box drawn
 * around the plate near the moment it was read, and real controls: skip back,
 * play or pause, skip forward, a scrubber over the sighting, bookmark, mute.
 */
@Composable
private fun SightingVideo(
    playback: SightingPlayback,
    read: PlateRead,
    cameraName: String,
    canBookmark: Boolean,
    onBookmark: () -> Unit,
    modifier: Modifier = Modifier,
    captionTopPadding: androidx.compose.ui.unit.Dp = 8.dp,
) {
    var zoomScale by remember { mutableFloatStateOf(1f) }
    var dragValue by remember { mutableStateOf<Float?>(null) }
    val readMs = remember(read.id) { Time.parseToMillis(read.ts) }
    val bbox = read.bbox?.takeIf { it.size >= 4 }
    val span = (playback.windowEndMs - playback.windowStartMs).coerceAtLeast(1L)
    val fraction = ((playback.positionMs - playback.windowStartMs).toFloat() / span).coerceIn(0f, 1f)

    Box(modifier.background(Color.Black)) {
        ZoomableVideoSurface(
            modifier = Modifier.fillMaxSize(),
            onTransformChange = { zoomScale = it.scale },
        ) {
            Box(Modifier.fillMaxSize()) {
                PlayerSurface(
                    player = playback.player,
                    modifier = Modifier.fillMaxSize(),
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT,
                    textureView = true,
                )
                // The plate's box, only while we are near the moment it was read.
                val near = kotlin.math.abs(playback.positionMs - readMs) <= 2_500L
                val vs = playback.videoSize
                if (bbox != null && near && vs.width > 0 && vs.height > 0 && playback.status == SightingStatus.READY) {
                    Canvas(Modifier.fillMaxSize()) {
                        val frameAspect = vs.width.toFloat() / vs.height
                        val boxAspect = size.width / size.height
                        val fw: Float
                        val fh: Float
                        if (frameAspect > boxAspect) {
                            fw = size.width
                            fh = size.width / frameAspect
                        } else {
                            fh = size.height
                            fw = size.height * frameAspect
                        }
                        val ox = (size.width - fw) / 2f
                        val oy = (size.height - fh) / 2f
                        drawRect(
                            color = LprAccent,
                            topLeft = Offset(ox + bbox[0].toFloat() * fw, oy + bbox[1].toFloat() * fh),
                            size = Size(bbox[2].toFloat() * fw, bbox[3].toFloat() * fh),
                            style = Stroke(width = 1.5.dp.toPx()),
                        )
                    }
                }
            }
        }

        // Caption: camera, the instant on screen, and the zoom level once zoomed.
        Row(
            Modifier
                .align(Alignment.TopStart)
                .padding(start = 10.dp, end = 10.dp, top = captionTopPadding),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(cameraName, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                Time.dateTime(Instant.ofEpochMilli(playback.positionMs)),
                color = Color(0xCCFFFFFF),
                fontSize = 12.sp,
                maxLines = 1,
            )
            if (zoomScale > 1.02f) {
                Text(
                    String.format(java.util.Locale.US, "%.1fx", zoomScale),
                    color = Color.White,
                    fontSize = 11.sp,
                    modifier = Modifier.background(Color(0x80000000), RoundedCornerShape(10.dp)).padding(horizontal = 8.dp, vertical = 2.dp),
                )
            }
        }

        // Status / big play button.
        when (playback.status) {
            SightingStatus.LOADING -> CircularProgressIndicator(
                Modifier.align(Alignment.Center).size(32.dp),
                color = LprAccent,
                strokeWidth = 3.dp,
            )
            SightingStatus.NO_FOOTAGE -> VideoMessage("No footage at this moment.", Modifier.align(Alignment.Center))
            SightingStatus.ERROR -> VideoMessage("Couldn't play this footage. Try another visit.", Modifier.align(Alignment.Center))
            SightingStatus.READY -> if (!playback.playing) {
                IconButton(
                    onClick = { playback.togglePlay() },
                    modifier = Modifier
                        .align(Alignment.Center)
                        .size(56.dp)
                        .background(Color(0x73000000), androidx.compose.foundation.shape.CircleShape),
                ) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = "Play", tint = Color.White, modifier = Modifier.size(30.dp))
                }
            }
        }

        // Controls over a soft gradient.
        Row(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xC0000000))))
                .padding(start = 4.dp, end = 4.dp, top = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VideoButton(Icons.Filled.Replay10, "Back 10 seconds") { playback.skip(-10_000L) }
            VideoButton(
                if (playback.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                if (playback.playing) "Pause" else "Play",
            ) { playback.togglePlay() }
            VideoButton(Icons.Filled.Forward10, "Forward 10 seconds") { playback.skip(10_000L) }
            Text(
                scrubTimeLabel(((dragValue ?: fraction) * span).toLong()),
                color = Color.White,
                fontFamily = JetBrainsMono,
                fontSize = 11.sp,
                modifier = Modifier.padding(start = 4.dp),
            )
            Slider(
                value = dragValue ?: fraction,
                onValueChange = { dragValue = it },
                onValueChangeFinished = {
                    dragValue?.let { playback.seekTo(playback.windowStartMs + (it * span).toLong()) }
                    dragValue = null
                },
                colors = SliderDefaults.colors(
                    thumbColor = LprAccent,
                    activeTrackColor = LprAccent,
                    inactiveTrackColor = Color(0x4DFFFFFF),
                ),
                modifier = Modifier.weight(1f).height(36.dp).padding(horizontal = 4.dp),
            )
            Text(
                scrubTimeLabel(span),
                color = Color.White,
                fontFamily = JetBrainsMono,
                fontSize = 11.sp,
            )
            if (canBookmark) VideoButton(Icons.Filled.BookmarkAdd, "Add bookmark") { onBookmark() }
            VideoButton(
                if (playback.muted) Icons.Filled.VolumeOff else Icons.Filled.VolumeUp,
                if (playback.muted) "Turn sound on" else "Mute",
            ) { playback.applyMuted(!playback.muted) }
        }
    }
}

@Composable
private fun VideoButton(icon: ImageVector, description: String, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.size(40.dp)) {
        Icon(icon, contentDescription = description, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun VideoMessage(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        color = Color.White,
        fontSize = 13.sp,
        modifier = modifier
            .background(Color(0x99000000), RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    )
}

// ─── facts and tabs ─────────────────────────────────────────────────────────

/** One line of four facts: first seen, last seen, last 30 days, total. Drawn once the history has loaded. */
@Composable
private fun ProfileFacts(profile: PlateProfileState) {
    val stats = profile.stats ?: return
    val now = remember(stats) { System.currentTimeMillis() }
    val first = stats.firstSeen?.let { Time.parseToMillis(it) }
    val last = stats.lastSeen?.let { Time.parseToMillis(it) }
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp)) {
        Fact(first?.let { shortDateLabel(it, now) }.orEmpty(), "First seen", Modifier.weight(1f))
        Fact(last?.let { agoLabel(it, now) }.orEmpty(), "Last seen", Modifier.weight(1f))
        Fact(stats.seen30d.toString(), "Last 30 days", Modifier.weight(1f))
        Fact(stats.total.toString(), "Total", Modifier.weight(1f))
    }
}

@Composable
private fun Fact(value: String, label: String, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text(value, color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        Text(label, color = TextSecondary, fontSize = 11.5.sp, maxLines = 1)
    }
}

private val PROFILE_TABS = listOf("Visits", "History", "Details")

/** Three equal tabs under the video with an accent underline. */
@Composable
private fun ProfileTabs(selected: Int, onSelect: (Int) -> Unit) {
    Column(Modifier.padding(top = 4.dp)) {
        Row(Modifier.fillMaxWidth().height(48.dp).selectableGroup()) {
            PROFILE_TABS.forEachIndexed { i, label ->
                val on = i == selected
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .clickable(role = Role.Tab) { onSelect(i) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label,
                        color = if (on) LprAccentHot else TextSecondary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    if (on) {
                        Box(
                            Modifier
                                .align(Alignment.BottomCenter)
                                .padding(horizontal = 24.dp)
                                .fillMaxWidth()
                                .height(3.dp)
                                .background(LprAccent, RoundedCornerShape(topStart = 3.dp, topEnd = 3.dp)),
                        )
                    }
                }
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Color(0xFF2A2E36)))
    }
}

// ─── overflow menu ──────────────────────────────────────────────────────────

@Composable
private fun ProfileMenuSheet(
    named: Boolean,
    isAdmin: Boolean,
    canCorrect: Boolean,
    onCopy: () -> Unit,
    onRename: () -> Unit,
    onCorrect: () -> Unit,
    onReport: () -> Unit,
    onPlayback: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xFF24272E),
    ) {
        Column(Modifier.navigationBarsPadding().padding(bottom = 12.dp)) {
            MenuItem(Icons.Filled.ContentCopy, "Copy plate", onClick = onCopy)
            if (isAdmin) MenuItem(Icons.Filled.Edit, if (named) "Rename" else "Name this plate", onClick = onRename)
            if (canCorrect) MenuItem(Icons.Filled.EditNote, "Correct plate", trailing = "Admin", onClick = onCorrect)
            MenuItem(Icons.Filled.PictureAsPdf, "Plate report (PDF)", onClick = onReport)
            MenuItem(Icons.Filled.VideoLibrary, "Open in Playback", onClick = onPlayback)
        }
    }
}

@Composable
private fun MenuItem(icon: ImageVector, label: String, trailing: String? = null, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Color(0xFFC7CBD3), modifier = Modifier.size(22.dp))
        Text(label, color = TextPrimary, fontSize = 15.sp, modifier = Modifier.weight(1f))
        if (trailing != null) Text(trailing, color = TextSecondary, fontSize = 12.5.sp)
    }
}
