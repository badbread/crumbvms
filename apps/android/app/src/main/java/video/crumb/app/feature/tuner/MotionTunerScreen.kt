// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.tuner

import android.graphics.drawable.BitmapDrawable
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Brush
import androidx.compose.material.icons.filled.ClearAll
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import coil.imageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import video.crumb.app.data.CameraDto
import video.crumb.app.data.MotionGridDto
import video.crumb.app.data.toUserMessage
import video.crumb.app.di.appContainer
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.theme.BlueAccent
import video.crumb.app.ui.theme.DangerRed
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Heatmap = live motion (green); exclusion zones = red. Matches the desktop tuner.
private val MotionGreen = Color(0xFF28D25A)
private val GridLine = Color.White.copy(alpha = 0.12f)

private const val MT_POLL_MS = 400L
private const val MT_FRAME_MS = 2000L

private val GRID_PRESETS = listOf(8 to 5, 16 to 9, 24 to 14, 32 to 18)

// Pixel detector algorithms (id → short chip label). Mirrors the recorder's
// MotionAlgorithm variants and the desktop tuner picker.
private val MOTION_ALGOS = listOf(
    "census" to "Census",
    "framediff" to "Diff",
    "mog2" to "MOG2",
    "opticalflow" to "Flow",
    "ensemble" to "Ensemble",
)

/** Pack an exclusion cell into an Int key (cols are bounded well below 64). */
private fun cellKey(gx: Int, gy: Int): Int = gy * 64 + gx

/**
 * Full-screen single-camera **Motion Tuner**: a refreshing camera frame with a
 * live motion heatmap (polled from `/cameras/{id}/motion-grid`), a motion meter
 * vs the configured threshold, a threshold slider (Manual) / Auto (Dynamic), and
 * a touch exclusion-zone editor saved as the camera's `motion_mask`.
 *
 * Mirrors the desktop tuner's logic. Touch model: tap a cell to toggle, drag to
 * box a region; an Add/Erase mode replaces the desktop's left/right mouse button.
 */
@Composable
fun MotionTunerScreen(
    cameraId: String,
    onClose: () -> Unit,
) {
    val container = appContainer()
    val repo = container.repository
    val mediaUrls = remember { repo.mediaUrls() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    var cam by remember { mutableStateOf<CameraDto?>(null) }
    var grid by remember { mutableStateOf<MotionGridDto?>(null) }
    var excluded by remember { mutableStateOf<Set<Int>>(emptySet()) }
    var cols by remember { mutableStateOf(16) }
    var rows by remember { mutableStateOf(9) }
    var threshold by remember { mutableStateOf<Float?>(null) } // motion_threshold as a FRACTION of frame (0..1)
    var sensitivity by remember { mutableStateOf("dynamic") }
    var motionSource by remember { mutableStateOf("pixel") } // "pixel" | "frigate"
    var motionAlgorithm by remember { mutableStateOf("census") }
    var addMode by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    // Last successfully-decoded camera frame. Held in state so a refresh never
    // blanks the backdrop (a new frame replaces it only once it's ready).
    var frameBitmap by remember { mutableStateOf<ImageBitmap?>(null) }
    // Drag box (exclusion-cell coords) for the region preview.
    var dragAnchor by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    var dragCur by remember { mutableStateOf<Pair<Int, Int>?>(null) }

    // Prewarm this camera's scoped media token — the still-frame backdrop poll
    // below starts fetching almost immediately, so get the token cached ahead
    // of that first request rather than paying the round-trip on it.
    LaunchedEffect(cameraId) {
        repo.prewarmMediaToken(cameraId)
    }

    // Load the camera (policy + existing mask).
    LaunchedEffect(cameraId) {
        repo.cameras().fold(
            onSuccess = { list ->
                val c = list.firstOrNull { it.id == cameraId }
                cam = c
                if (c != null) {
                    threshold = c.policy?.motionThreshold
                    sensitivity = c.policy?.motionSensitivity ?: "dynamic"
                    motionSource = c.motionSource
                    motionAlgorithm = c.motionAlgorithm
                    excluded = rectsToCells(parseMaskRects(c.motionMask), cols, rows)
                }
            },
            onFailure = { error = it.toUserMessage() },
        )
    }

    // Poll the live heatmap.
    LaunchedEffect(cameraId) {
        while (true) {
            repo.motionGrid(cameraId).onSuccess { g ->
                if (g != null && g.cols > 0 && g.rows > 0) grid = g
            }
            delay(MT_POLL_MS)
        }
    }

    // Until the camera (its existing mask + policy) has loaded we must NOT render the
    // editor: painting/saving from an empty baseline would overwrite the camera's real
    // motion_mask (the PUT replaces it). Show a spinner while loading, and a clear,
    // above-the-fold error + Back if the load failed — never a half-broken editor.
    val loadedCam = cam
    if (loadedCam == null) {
        Box(
            modifier = Modifier.fillMaxSize().background(NavyDeep).statusBarsPadding(),
            contentAlignment = Alignment.Center,
        ) {
            val loadErr = error
            if (loadErr != null) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(loadErr, color = DangerRed, style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.height(12.dp))
                    OutlinedButton(onClick = onClose) { Text("Back") }
                }
            } else {
                CircularProgressIndicator(color = BlueAccent)
            }
        }
        return
    }

    val gridCols = grid?.cols ?: 16
    val gridRows = grid?.rows ?: 9
    val cells = grid?.cells ?: emptyList()
    val level = computeLevel(cells, gridCols, gridRows, excluded, cols, rows)

    // Refresh the still-frame backdrop WITHOUT blanking. AsyncImage clears the image
    // on every model change → a black flash for the ~100–400ms the new JPEG takes to
    // arrive, every 2s. Instead we decode each frame off-screen and only swap it into
    // `frameBitmap` once it's ready, so the previous frame stays up during the fetch
    // (same as a browser <img> swapping its src — what the desktop tuner relies on).
    // Coil caching stays disabled + a per-fetch cache-buster: the endpoint is a single
    // mutable live frame, so caching would only churn the LRU with frames never reused.
    LaunchedEffect(loadedCam.id) {
        // API-PROXIED, authed still-frame (same as the live tiles + playback wall).
        // NOT a direct go2rtc :1984 URL: go2rtc's API port is host-local only, so a
        // direct {host}:1984 URL is unreachable from the phone — that was the
        // black-backdrop bug. The proxy reaches go2rtc server-side.
        //
        // The URL is rebuilt every tick (not resolved once up front): this loop
        // can run for as long as the tuner stays open, far past one scoped media
        // token's ~15 min lifetime — mediaUrls.cameraFrameUrl() only pays a network
        // round-trip when the cached token is missing/near-expiry, otherwise it's
        // a cheap cache hit.
        val loader = context.imageLoader
        var cb = 0
        while (true) {
            val baseUrl = runCatching { mediaUrls.cameraFrameUrl(loadedCam.id) }.getOrNull()
            if (baseUrl.isNullOrEmpty()) {
                delay(MT_FRAME_MS)
                continue
            }
            val req = ImageRequest.Builder(context)
                .data("$baseUrl&cb=$cb")
                .memoryCachePolicy(CachePolicy.DISABLED)
                .diskCachePolicy(CachePolicy.DISABLED)
                .allowHardware(false) // software bitmap → safe to draw via Image()
                .build()
            val result = loader.execute(req)
            if (result is SuccessResult) {
                (result.drawable as? BitmapDrawable)?.bitmap?.let { frameBitmap = it.asImageBitmap() }
            }
            cb++
            delay(MT_FRAME_MS)
        }
    }

    // While a Save is in flight, swallow the system Back gesture so it can't race the
    // success callback into a double pop (which would skip past the fullscreen view).
    BackHandler(enabled = saving) {}

    fun applyThreshold(thr: Float, sens: String) {
        threshold = thr
        sensitivity = sens
        scope.launch {
            repo.updateMotionPolicy(cameraId, sens, thr)
                .onFailure { error = "Threshold save failed: ${it.message}" }
        }
    }

    fun applyMotionConfig(source: String, algorithm: String) {
        motionSource = source
        motionAlgorithm = algorithm
        scope.launch {
            repo.updateMotionConfig(cameraId, source, algorithm)
                .onFailure { error = "Motion source save failed: ${it.message}" }
        }
    }

    fun changeGrid(newCols: Int, newRows: Int) {
        // Preserve the painted area across a resolution change.
        val rects = cellsToMask(excluded, cols, rows)
        cols = newCols
        rows = newRows
        excluded = rectsToCells(rects, newCols, newRows)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(NavyDeep)
            .statusBarsPadding()
            .verticalScroll(rememberScrollState()),
    ) {
        // ── Top bar ────────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            HintTooltip("Close motion tuner") {
                IconButton(onClick = onClose, enabled = !saving) {
                    Icon(Icons.Default.ArrowBack, contentDescription = "Close", tint = TextPrimary)
                }
            }
            Text(
                text = "Motion Tuner",
                style = MaterialTheme.typography.titleMedium,
                color = TextPrimary,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = loadedCam.name,
                style = MaterialTheme.typography.bodyMedium,
                color = TextSecondary,
            )
        }

        // ── Stage: frame + heatmap/exclusion canvas ──────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp)
                .clip(RoundedCornerShape(8.dp))
                .aspectRatio(16f / 9f)
                .background(Color.Black),
        ) {
            frameBitmap?.let { bmp ->
                Image(
                    bitmap = bmp,
                    contentDescription = "Camera frame",
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.FillBounds,
                )
            }
            Canvas(
                modifier = Modifier
                    .fillMaxSize()
                    .pointerInput(cols, rows, addMode) {
                        detectTapGestures { off ->
                            val (gx, gy) = cellAt(off.x, off.y, size, cols, rows)
                            val k = cellKey(gx, gy)
                            excluded = excluded.toMutableSet().apply {
                                if (addMode) {
                                    if (contains(k)) remove(k) else add(k)
                                } else {
                                    remove(k)
                                }
                            }
                        }
                    }
                    .pointerInput(cols, rows, addMode) {
                        detectDragGestures(
                            onDragStart = { off ->
                                val c = cellAt(off.x, off.y, size, cols, rows)
                                dragAnchor = c
                                dragCur = c
                            },
                            onDrag = { change, _ ->
                                dragCur = cellAt(change.position.x, change.position.y, size, cols, rows)
                            },
                            onDragEnd = {
                                val a = dragAnchor
                                val b = dragCur
                                if (a != null && b != null) {
                                    val x0 = min(a.first, b.first); val x1 = max(a.first, b.first)
                                    val y0 = min(a.second, b.second); val y1 = max(a.second, b.second)
                                    excluded = excluded.toMutableSet().apply {
                                        for (gy in y0..y1) for (gx in x0..x1) {
                                            val k = cellKey(gx, gy)
                                            if (addMode) add(k) else remove(k)
                                        }
                                    }
                                }
                                dragAnchor = null; dragCur = null
                            },
                            onDragCancel = { dragAnchor = null; dragCur = null },
                        )
                    },
            ) {
                val w = size.width; val h = size.height

                // 1. Heatmap (recorder's grid resolution).
                if (gridCols > 0 && gridRows > 0) {
                    val hcw = w / gridCols; val hch = h / gridRows
                    for (gy in 0 until gridRows) for (gx in 0 until gridCols) {
                        val intensity = cells.getOrElse(gy * gridCols + gx) { 0f }
                        if (intensity > 0.5f) {
                            val a = (0.5f + (intensity / 100f) * 0.5f).coerceAtMost(1f)
                            drawRect(MotionGreen.copy(alpha = a), Offset(gx * hcw, gy * hch), Size(hcw, hch))
                        }
                    }
                }

                // 2. Exclusion cells (user authoring grid) + diagonal hatch.
                val cw = w / cols; val ch = h / rows
                for (gy in 0 until rows) for (gx in 0 until cols) {
                    if (excluded.contains(cellKey(gx, gy))) {
                        val x = gx * cw; val y = gy * ch
                        drawRect(DangerRed.copy(alpha = 0.32f), Offset(x, y), Size(cw, ch))
                        drawLine(DangerRed.copy(alpha = 0.8f), Offset(x, y + ch), Offset(x + cw, y), strokeWidth = 1.5f)
                    }
                }

                // 3. Grid lines.
                for (gx in 1 until cols) drawLine(GridLine, Offset(gx * cw, 0f), Offset(gx * cw, h), 1f)
                for (gy in 1 until rows) drawLine(GridLine, Offset(0f, gy * ch), Offset(w, gy * ch), 1f)

                // 4. Drag preview box.
                val a = dragAnchor; val b = dragCur
                if (a != null && b != null) {
                    val x0 = min(a.first, b.first) * cw; val y0 = min(a.second, b.second) * ch
                    val x1 = (max(a.first, b.first) + 1) * cw; val y1 = (max(a.second, b.second) + 1) * ch
                    val stroke = if (addMode) Color.White else BlueAccent
                    if (!addMode) drawRect(BlueAccent.copy(alpha = 0.18f), Offset(x0, y0), Size(x1 - x0, y1 - y0))
                    drawRect(stroke, Offset(x0, y0), Size(x1 - x0, y1 - y0), style = Stroke(width = 2.5f))
                }
            }
        }

        // ── Motion meter ─────────────────────────────────────────────────────────
        // Show the RECORDER's real numbers (largest-blob score + effective floor,
        // both fractions 0..1) — not the client mean-of-cells. Marker floor: the
        // live auto floor in Dynamic, the slider's pending value in Manual.
        val floorFrac = if (sensitivity == "dynamic") grid?.threshold else (threshold ?: grid?.threshold)
        MotionMeter(scoreFrac = grid?.score, floorFrac = floorFrac, sensitivity = sensitivity)

        // ── Detection: motion source + (pixel) algorithm ─────────────────────────
        val pixelSource = motionSource != "frigate"
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text("Source", style = MaterialTheme.typography.labelLarge, color = TextSecondary)
            FilterChip(
                selected = pixelSource,
                onClick = { applyMotionConfig("pixel", motionAlgorithm) },
                label = { Text("Pixel") },
            )
            FilterChip(
                selected = !pixelSource,
                onClick = { applyMotionConfig("frigate", motionAlgorithm) },
                label = { Text("Frigate") },
            )
        }
        if (pixelSource) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("Algorithm", style = MaterialTheme.typography.labelLarge, color = TextSecondary)
                MOTION_ALGOS.forEach { (id, label) ->
                    FilterChip(
                        selected = motionAlgorithm == id,
                        onClick = { applyMotionConfig("pixel", id) },
                        label = { Text(label, style = MaterialTheme.typography.labelSmall) },
                    )
                }
            }
        } else {
            Text(
                "Recording is triggered by Frigate detections — the pixel detector, threshold and exclusions below are not used.",
                style = MaterialTheme.typography.bodySmall,
                color = TextSecondary,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            )
        }

        // ── Threshold + Auto ─────────────────────────────────────────────────────
        val isAuto = sensitivity == "dynamic"
        // Edit the threshold as % of frame (min object size); store the fraction.
        val thrPct = ((threshold ?: 0.0030f) * 100f).coerceIn(0.05f, 5f)
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Min size", style = MaterialTheme.typography.labelLarge, color = TextSecondary)
            Spacer(Modifier.width(12.dp))
            Slider(
                value = thrPct,
                onValueChange = { threshold = it / 100f; sensitivity = "manual" }, // % → fraction
                onValueChangeFinished = { applyThreshold(threshold ?: 0.0030f, "manual") },
                valueRange = 0.05f..5f,
                enabled = !isAuto,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            Text("%.2f%%".format(thrPct), style = MaterialTheme.typography.bodyMedium, color = TextPrimary, modifier = Modifier.width(48.dp))
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Auto (dynamic)", style = MaterialTheme.typography.bodyMedium, color = TextSecondary)
            Spacer(Modifier.weight(1f))
            Switch(
                checked = isAuto,
                onCheckedChange = { auto -> applyThreshold(threshold ?: 0.0030f, if (auto) "dynamic" else "manual") },
            )
        }

        // ── Grid size presets ────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text("Grid", style = MaterialTheme.typography.labelLarge, color = TextSecondary)
            GRID_PRESETS.forEach { (c, r) ->
                FilterChip(
                    selected = cols == c && rows == r,
                    onClick = { changeGrid(c, r) },
                    label = { Text("${c}×${r}", style = MaterialTheme.typography.labelSmall) },
                )
            }
        }

        // ── Add / Erase mode + actions ───────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilterChip(
                selected = addMode,
                onClick = { addMode = true },
                leadingIcon = { Icon(Icons.Default.Brush, contentDescription = null, modifier = Modifier.size(16.dp)) },
                label = { Text("Exclude") },
            )
            FilterChip(
                selected = !addMode,
                onClick = { addMode = false },
                leadingIcon = { Icon(Icons.Default.ClearAll, contentDescription = null, modifier = Modifier.size(16.dp)) },
                label = { Text("Erase") },
            )
            Spacer(Modifier.weight(1f))
            OutlinedButton(onClick = { excluded = emptySet() }) { Text("Clear") }
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            Button(
                onClick = { saving = true; scope.launch {
                    repo.updateMotionMask(cameraId, cellsToMask(excluded, cols, rows)).fold(
                        onSuccess = { saving = false; onClose() },
                        onFailure = { saving = false; error = "Save failed: ${it.message}" },
                    )
                } },
                enabled = !saving,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = BlueAccent, contentColor = NavyDeep),
            ) {
                Icon(Icons.Default.Save, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (saving) "Saving…" else "Save mask")
            }
        }

        error?.let {
            Text(
                text = it,
                color = DangerRed,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            )
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun MotionMeter(scoreFrac: Float?, floorFrac: Float?, sensitivity: String) {
    // scoreFrac/floorFrac are fractions of frame (0..1) straight from the recorder.
    // Display as % of frame; the floor marker sits at ~22% of the bar (stable while
    // tuning) and the live score fills relative to it.
    if (scoreFrac == null || floorFrac == null) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
            Box(modifier = Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(5.dp)).background(NavySurface))
            Spacer(Modifier.height(4.dp))
            Text("waiting for recorder…", style = MaterialTheme.typography.bodySmall, color = TextSecondary)
        }
        return
    }
    val scorePct = scoreFrac * 100f
    val floorPct = floorFrac * 100f
    val fullScale = max(1f, floorPct * 4.5f)
    val fill = (scorePct / fullScale).coerceIn(0f, 1f)
    val markFrac = (floorPct / fullScale).coerceIn(0f, 1f)
    val over = scorePct >= floorPct
    val fillColor = if (over) DangerRed else BlueAccent
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(10.dp)
                .clip(RoundedCornerShape(5.dp))
                .background(NavySurface),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(fill)
                    .height(10.dp)
                    .background(fillColor),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth(markFrac)
                    .height(10.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Box(modifier = Modifier.width(2.dp).height(10.dp).background(TextPrimary))
            }
        }
        Spacer(Modifier.height(4.dp))
        val mode = if (sensitivity == "dynamic") " (auto)" else ""
        Text(
            text = "motion %.2f%%  ·  floor %.2f%%%s".format(scorePct, floorPct, mode),
            style = MaterialTheme.typography.bodySmall,
            color = if (over) DangerRed else TextSecondary,
        )
    }
}

// ─── geometry / mask helpers ─────────────────────────────────────────────────

/** Pointer (px) → exclusion cell, clamped. */
private fun cellAt(x: Float, y: Float, size: IntSize, cols: Int, rows: Int): Pair<Int, Int> {
    val gx = (x / size.width * cols).toInt().coerceIn(0, cols - 1)
    val gy = (y / size.height * rows).toInt().coerceIn(0, rows - 1)
    return gx to gy
}

/** Current overall motion level = mean of the NON-excluded heatmap cells (0..100). */
private fun computeLevel(
    cells: List<Float>, gc: Int, gr: Int,
    excluded: Set<Int>, cols: Int, rows: Int,
): Float {
    if (gc <= 0 || gr <= 0 || cells.isEmpty()) return 0f
    var sum = 0f; var n = 0
    for (gy in 0 until gr) for (gx in 0 until gc) {
        val ex = floor(gx.toFloat() / gc * cols).toInt().coerceIn(0, cols - 1)
        val ey = floor(gy.toFloat() / gr * rows).toInt().coerceIn(0, rows - 1)
        if (excluded.contains(cellKey(ex, ey))) continue
        sum += cells.getOrElse(gy * gc + gx) { 0f }
        n++
    }
    return if (n > 0) sum / n else 0f
}

/** Parse a `motion_mask` JSON value into normalized `[x,y,w,h]` rects (skips legacy polygons). */
private fun parseMaskRects(mask: JsonElement?): List<List<Double>> {
    val arr = mask as? JsonArray ?: return emptyList()
    return arr.mapNotNull { el ->
        val a = el as? JsonArray ?: return@mapNotNull null
        if (a.size < 4) return@mapNotNull null
        val nums = a.take(4).map { (it as? kotlinx.serialization.json.JsonPrimitive)?.doubleOrNull }
        if (nums.any { it == null }) null else nums.filterNotNull()
    }
}

/** Normalized rects → excluded cells (a cell is excluded if its center is inside a rect). */
private fun rectsToCells(rects: List<List<Double>>, cols: Int, rows: Int): Set<Int> {
    if (rects.isEmpty()) return emptySet()
    val out = HashSet<Int>()
    for (gy in 0 until rows) for (gx in 0 until cols) {
        val cx = (gx + 0.5) / cols; val cy = (gy + 0.5) / rows
        for (r in rects) {
            if (cx >= r[0] && cx < r[0] + r[2] && cy >= r[1] && cy < r[1] + r[3]) {
                out.add(cellKey(gx, gy)); break
            }
        }
    }
    return out
}

/** Excluded cells → normalized rects, merged into per-row runs. */
private fun cellsToMask(excluded: Set<Int>, cols: Int, rows: Int): List<List<Double>> {
    val rects = ArrayList<List<Double>>()
    for (gy in 0 until rows) {
        var runStart = -1
        for (gx in 0..cols) {
            val on = gx < cols && excluded.contains(cellKey(gx, gy))
            if (on && runStart < 0) {
                runStart = gx
            } else if (!on && runStart >= 0) {
                val w = gx - runStart
                rects.add(listOf(runStart.toDouble() / cols, gy.toDouble() / rows, w.toDouble() / cols, 1.0 / rows))
                runStart = -1
            }
        }
    }
    return rects
}
