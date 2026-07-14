// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.export

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Switch
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request
import video.crumb.app.data.CameraDto
import video.crumb.app.data.ExportJob
import video.crumb.app.data.ExportOutputFile
import video.crumb.app.data.Network
import video.crumb.app.di.AppContainer
import video.crumb.app.di.appContainer
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.Time
import video.crumb.app.ui.theme.BlueAccent
import video.crumb.app.ui.theme.DangerRed
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.NavySurfaceVariant
import video.crumb.app.ui.theme.TextSecondary
import java.io.File
import java.io.InputStream
import java.time.Instant

// ─── screen entry point ───────────────────────────────────────────────────────

/**
 * Export screen: lets the operator pick cameras, a time window, and burn-in
 * preference, then submits an export job and polls it to completion. Completed
 * output files can be downloaded to the device or shared as a URL.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportScreen(onBack: () -> Unit) {
    val container = appContainer()
    val vm: ExportViewModel = viewModel(
        factory = viewModelFactory {
            initializer { ExportViewModel(container.repository) }
        },
    )
    val state by vm.state.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }

    Scaffold(
        snackbarHost = {
            SnackbarHost(hostState = snackbarHostState) { data ->
                Snackbar(snackbarData = data)
            }
        },
        topBar = {
            TopAppBar(
                title = { Text("Export") },
                navigationIcon = {
                    HintTooltip("Back") {
                        IconButton(onClick = onBack) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = "Back",
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NavySurface,
                    titleContentColor = MaterialTheme.colorScheme.onSurface,
                    navigationIconContentColor = MaterialTheme.colorScheme.onSurface,
                ),
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .padding(innerPadding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // ─── camera selection ────────────────────────────────────────────
            SectionHeader("Cameras")
            CameraSelectionSection(
                loading = state.loadingCameras,
                error = state.error,
                cameras = state.cameras,
                selectedIds = state.selectedCameraIds,
                onToggle = vm::toggleCamera,
                onRetry = vm::loadCameras,
            )

            HorizontalDivider(color = NavySurfaceVariant)

            // ─── time range ──────────────────────────────────────────────────
            SectionHeader("Clip Window")
            TimeRangeSection(
                startMs = state.startMs,
                endMs = state.endMs,
                onStartChange = vm::setStart,
                onEndChange = vm::setEnd,
                disabled = state.polling,
            )

            HorizontalDivider(color = NavySurfaceVariant)

            // ─── options ─────────────────────────────────────────────────────
            SectionHeader("Options")
            BurnTimestampRow(
                enabled = state.burn,
                onChange = vm::setBurn,
                disabled = state.polling,
            )

            HorizontalDivider(color = NavySurfaceVariant)

            // ─── submit button ───────────────────────────────────────────────
            val canSubmit = state.selectedCameraIds.isNotEmpty() && !state.polling
            Button(
                onClick = vm::createExport,
                enabled = canSubmit,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (state.polling) "Exporting..." else "Create Export")
            }

            // ─── job progress + results ──────────────────────────────────────
            val job = state.job
            val jobError = state.jobError
            if (state.polling || job != null || jobError != null) {
                HorizontalDivider(color = NavySurfaceVariant)
                SectionHeader("Job Status")
                JobStatusSection(
                    container = container,
                    polling = state.polling,
                    job = job,
                    jobError = jobError,
                    snackbarHostState = snackbarHostState,
                )
            }

            // Bottom breathing room
            Spacer(modifier = Modifier.height(32.dp))
        }
    }
}

// ─── section header ───────────────────────────────────────────────────────────

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.onSurface,
        fontWeight = FontWeight.SemiBold,
    )
}

// ─── camera selection ─────────────────────────────────────────────────────────

@Composable
private fun CameraSelectionSection(
    loading: Boolean,
    error: String?,
    cameras: List<CameraDto>,
    selectedIds: Set<String>,
    onToggle: (String) -> Unit,
    onRetry: () -> Unit,
) {
    when {
        loading -> {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(28.dp),
                    color = BlueAccent,
                )
            }
        }

        error != null && cameras.isEmpty() -> {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = error,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
                TextButton(onClick = onRetry) {
                    Text("Retry")
                }
            }
        }

        cameras.isEmpty() -> {
            Text(
                text = "No cameras available.",
                style = MaterialTheme.typography.bodyMedium,
                color = TextSecondary,
            )
        }

        else -> {
            // Show error banner (e.g. partial access warning) above camera list
            if (error != null) {
                Text(
                    text = error,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
            Card(
                colors = CardDefaults.cardColors(containerColor = NavySurface),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column {
                    cameras.forEachIndexed { index, camera ->
                        CameraCheckRow(
                            camera = camera,
                            checked = camera.id in selectedIds,
                            onToggle = { onToggle(camera.id) },
                        )
                        if (index < cameras.lastIndex) {
                            HorizontalDivider(
                                color = NavySurfaceVariant,
                                modifier = Modifier.padding(horizontal = 12.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CameraCheckRow(
    camera: CameraDto,
    checked: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Checkbox(
            checked = checked,
            onCheckedChange = { onToggle() },
        )
        Text(
            text = camera.name,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        if (!camera.enabled) {
            Text(
                text = "disabled",
                style = MaterialTheme.typography.labelSmall,
                color = TextSecondary,
            )
        }
    }
}

// ─── time range stepper ───────────────────────────────────────────────────────

/**
 * Simple +/- minute steppers for start and end times. Each press moves the
 * boundary by [STEP_MINUTES] minutes. The field shows the device-local time via
 * [Time.dateTime] so the operator sees a human-readable value at a glance.
 *
 * Keeping the implementation self-contained avoids a DatePickerDialog dependency
 * and remains compilable on minSdk 26.
 */
@Composable
private fun TimeRangeSection(
    startMs: Long,
    endMs: Long,
    onStartChange: (Long) -> Unit,
    onEndChange: (Long) -> Unit,
    disabled: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        TimeStepperRow(
            label = "Start",
            epochMs = startMs,
            onChange = onStartChange,
            disabled = disabled,
        )
        TimeStepperRow(
            label = "End",
            epochMs = endMs,
            onChange = onEndChange,
            disabled = disabled,
        )
        val durationSec = (endMs - startMs) / 1_000L
        val durationStr = formatDuration(durationSec)
        Text(
            text = "Duration: $durationStr",
            style = MaterialTheme.typography.bodySmall,
            color = TextSecondary,
        )
    }
}

@Composable
private fun TimeStepperRow(
    label: String,
    epochMs: Long,
    onChange: (Long) -> Unit,
    disabled: Boolean,
) {
    val instant = Instant.ofEpochMilli(epochMs)
    val displayText = Time.dateTime(instant)
    val stepMs = STEP_MINUTES * 60_000L

    Card(
        colors = CardDefaults.cardColors(containerColor = NavySurface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                color = TextSecondary,
            )
            Spacer(modifier = Modifier.height(4.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedButton(
                    onClick = { onChange(epochMs - stepMs) },
                    enabled = !disabled,
                    modifier = Modifier.size(width = 48.dp, height = 36.dp),
                ) {
                    Text("-", style = MaterialTheme.typography.labelLarge)
                }
                Text(
                    text = displayText,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                OutlinedButton(
                    onClick = { onChange(epochMs + stepMs) },
                    enabled = !disabled,
                    modifier = Modifier.size(width = 48.dp, height = 36.dp),
                ) {
                    Text("+", style = MaterialTheme.typography.labelLarge)
                }
            }
        }
    }
}

private fun formatDuration(totalSec: Long): String {
    val h = totalSec / 3600
    val m = (totalSec % 3600) / 60
    val s = totalSec % 60
    return when {
        h > 0 -> "${h}h ${m}m ${s}s"
        m > 0 -> "${m}m ${s}s"
        else -> "${s}s"
    }
}

private const val STEP_MINUTES = 1L

// ─── burn-timestamp switch ────────────────────────────────────────────────────

@Composable
private fun BurnTimestampRow(
    enabled: Boolean,
    onChange: (Boolean) -> Unit,
    disabled: Boolean,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = NavySurface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Burn timestamp",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "Overlay date/time on the exported video",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                )
            }
            Switch(
                checked = enabled,
                onCheckedChange = onChange,
                enabled = !disabled,
            )
        }
    }
}

// ─── job status section ───────────────────────────────────────────────────────

@Composable
private fun JobStatusSection(
    container: AppContainer,
    polling: Boolean,
    job: ExportJob?,
    jobError: String?,
    snackbarHostState: SnackbarHostState,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {

        // Progress bar — shown while polling or while job is non-terminal
        if (polling || (job != null && !job.isTerminal)) {
            val progress = job?.progressPct?.let { it / 100f } ?: 0f
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = jobStatusLabel(job),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = if (job != null) "${job.progressPct}%" else "—",
                        style = MaterialTheme.typography.labelLarge,
                        color = TextSecondary,
                    )
                }
                if (job != null) {
                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier.fillMaxWidth(),
                        color = BlueAccent,
                        trackColor = NavySurfaceVariant,
                    )
                } else {
                    // Indeterminate while waiting for first poll response
                    LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth(),
                        color = BlueAccent,
                        trackColor = NavySurfaceVariant,
                    )
                }
            }
        }

        // Error message (job failure or network blip during polling)
        if (jobError != null) {
            Text(
                text = jobError,
                style = MaterialTheme.typography.bodyMedium,
                color = DangerRed,
            )
        }

        // Output files (only when job is done successfully)
        if (job != null && job.isDone && job.outputFiles.isNotEmpty()) {
            Text(
                text = "Ready to download",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                fontWeight = FontWeight.Medium,
            )
            job.outputFiles.forEach { outputFile ->
                OutputFileRow(
                    container = container,
                    outputFile = outputFile,
                    snackbarHostState = snackbarHostState,
                )
            }
        }
    }
}

private fun jobStatusLabel(job: ExportJob?): String = when {
    job == null -> "Queuing export…"
    job.isDone -> "Done"
    job.isFailed -> "Failed"
    job.status.equals("running", ignoreCase = true) -> "Processing…"
    else -> "Queued…"
}

// ─── output file row ──────────────────────────────────────────────────────────

/**
 * Both actions fetch the export bytes with the session token in an `Authorization`
 * header (never in the URL — the #1/#5 fix; the old code built a `?token=<JWT>` URL
 * and handed it to DownloadManager / the share sheet, leaking the long-lived
 * session token into the system Downloads DB and to whatever app the user picked).
 *
 * They differ in destination (#134):
 * - **Download** streams to the device's **public Downloads** collection via
 *   [saveExportToDownloads] (MediaStore on API 29+, the public Downloads dir on
 *   ≤ 28) so the file is user-findable and not silently purged, then shows a
 *   "Saved to …" confirmation with an actionable **Share** action (#164).
 * - **Share** downloads to app-private cache ([downloadExportFileToCache]) and
 *   hands the receiving app a scoped `content://` [FileProvider] Uri (read-only,
 *   this file only) — a transient copy is the right lifetime for a share. The
 *   Download confirmation's Share action reuses this same stage-then-share path.
 */
@Composable
private fun OutputFileRow(
    container: AppContainer,
    outputFile: ExportOutputFile,
    snackbarHostState: SnackbarHostState,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var busy by remember(outputFile.downloadUrl) { mutableStateOf(false) }

    Card(
        colors = CardDefaults.cardColors(containerColor = NavySurface),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // File info header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = outputFile.cameraId,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = formatBytes(outputFile.sizeBytes),
                    style = MaterialTheme.typography.labelLarge,
                    color = TextSecondary,
                )
            }

            // Action buttons
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FilledTonalButton(
                    onClick = {
                        if (busy) return@FilledTonalButton
                        busy = true
                        scope.launch {
                            val result = saveExportToDownloads(context, container, outputFile)
                            busy = false
                            result
                                .onSuccess { location ->
                                    // #164: the "Saved to …" confirmation is now
                                    // actionable — a "Share" action opens the system
                                    // share sheet. The public-Downloads copy isn't a
                                    // FileProvider path, so Share re-stages the file in
                                    // app cache (downloadExportFileToCache) and shares
                                    // that scoped content:// Uri (the proven path the
                                    // dedicated Share button already uses).
                                    val res = snackbarHostState.showSnackbar(
                                        message = "Saved to $location",
                                        actionLabel = "Share",
                                        duration = SnackbarDuration.Long,
                                    )
                                    if (res == SnackbarResult.ActionPerformed) {
                                        downloadExportFileToCache(context, container, outputFile)
                                            .onSuccess { file -> shareLocalFile(context, file) }
                                            .onFailure { e ->
                                                snackbarHostState.showSnackbar("Share failed: ${e.message}")
                                            }
                                    }
                                }
                                .onFailure { e ->
                                    snackbarHostState.showSnackbar("Download failed: ${e.message}")
                                }
                        }
                    },
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) {
                    if (busy) {
                        CircularProgressIndicator(
                            modifier = Modifier
                                .padding(end = 4.dp)
                                .size(18.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Filled.Download,
                            contentDescription = null,
                            modifier = Modifier
                                .padding(end = 4.dp)
                                .size(18.dp),
                        )
                    }
                    Text("Download")
                }

                OutlinedButton(
                    onClick = {
                        if (busy) return@OutlinedButton
                        busy = true
                        scope.launch {
                            downloadExportFileToCache(context, container, outputFile)
                                .onSuccess { file -> shareLocalFile(context, file) }
                                .onFailure { e ->
                                    snackbarHostState.showSnackbar("Share failed: ${e.message}")
                                }
                            busy = false
                        }
                    },
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) {
                    if (busy) {
                        CircularProgressIndicator(
                            modifier = Modifier
                                .padding(end = 4.dp)
                                .size(18.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Filled.Share,
                            contentDescription = null,
                            modifier = Modifier
                                .padding(end = 4.dp)
                                .size(18.dp),
                        )
                    }
                    Text("Share")
                }
            }
        }
    }
}

// ─── platform helpers ─────────────────────────────────────────────────────────

/** Subdirectory of the app cache dir that [file_paths.xml] exposes via FileProvider. */
private const val EXPORT_CACHE_SUBDIR = "exports"

/** Sub-folder created under the device Downloads dir for exported clips (#134). */
private const val DOWNLOAD_SUBDIR = "CrumbVMS"

/**
 * #134: Save one export output file to the device's **public Downloads** so it's
 * user-findable (Files app, other apps) and not silently purged like the
 * app-private cache the Share path uses.
 *
 * Uses the SAME authenticated request as [downloadExportFileToCache] — bearer
 * token in the `Authorization` header, never in the URL (the #1/#5 fix stays
 * intact) — and streams the response body straight into the destination:
 * - API 29+ (scoped storage): inserts into [MediaStore.Downloads] under
 *   `Downloads/CrumbVMS/`, `IS_PENDING` until the copy finishes. **No storage
 *   permission required.**
 * - API ≤ 28: writes to the public Downloads dir directly, which needs the legacy
 *   `WRITE_EXTERNAL_STORAGE` permission already declared (`maxSdkVersion=28`). If
 *   that isn't granted the copy throws and surfaces as a normal "Download failed".
 *
 * Returns the user-visible saved location on success.
 */
private suspend fun saveExportToDownloads(
    context: Context,
    container: AppContainer,
    outputFile: ExportOutputFile,
): Result<String> = withContext(Dispatchers.IO) {
    runCatching {
        // One-shot authenticated client (bearer header via Network.buildOkHttp),
        // kept off the shared Retrofit client's pool and shut down below — same
        // pattern as downloadExportFileToCache / AppContainer.rebuildApi().
        val client = Network.buildOkHttp(container.store)
        try {
            val base = container.store.serverUrl.trimEnd('/')
            val path = outputFile.downloadUrl.let { if (it.startsWith("/")) it else "/$it" }
            // Credential-free URL: the auth interceptor adds the bearer token as a
            // header. (The old JWT-in-URL `MediaUrls.authed()` builder was removed —
            // no code path puts the bearer token in a URL anymore. #147-9.)
            val absoluteUrl = "$base$path"

            val safeId = outputFile.cameraId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
            // Timestamp so repeated downloads don't collide / silently overwrite.
            val fileName = "crumb-export-$safeId-${System.currentTimeMillis()}.mp4"

            val request = Request.Builder().url(absoluteUrl).build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    error("Server returned HTTP ${response.code}")
                }
                val body = response.body ?: error("Empty response body")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    writeToMediaStoreDownloads(context, fileName, body.byteStream())
                } else {
                    writeToLegacyDownloads(fileName, body.byteStream())
                }
            }
        } finally {
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
        }
    }
}

/**
 * API 29+ path: stream [input] into a new [MediaStore.Downloads] entry under
 * `Downloads/CrumbVMS/`. Uses `IS_PENDING` so the file isn't visible to other apps
 * until the copy completes, and rolls the entry back if the copy fails so no
 * 0-byte ghost is left behind. Returns the user-visible location.
 */
@RequiresApi(Build.VERSION_CODES.Q)
private fun writeToMediaStoreDownloads(
    context: Context,
    fileName: String,
    input: InputStream,
): String {
    val resolver = context.contentResolver
    val values = ContentValues().apply {
        put(MediaStore.Downloads.DISPLAY_NAME, fileName)
        put(MediaStore.Downloads.MIME_TYPE, "video/mp4")
        put(
            MediaStore.Downloads.RELATIVE_PATH,
            Environment.DIRECTORY_DOWNLOADS + "/" + DOWNLOAD_SUBDIR,
        )
        put(MediaStore.Downloads.IS_PENDING, 1)
    }
    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        ?: error("Could not create a Downloads entry")
    try {
        resolver.openOutputStream(uri)?.use { out -> input.copyTo(out) }
            ?: error("Could not open the Downloads output stream")
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
    } catch (t: Throwable) {
        runCatching { resolver.delete(uri, null, null) }
        throw t
    }
    return "Downloads/$DOWNLOAD_SUBDIR/$fileName"
}

/**
 * API ≤ 28 path: write [input] to the public Downloads dir directly (needs the
 * legacy `WRITE_EXTERNAL_STORAGE` permission declared for `maxSdkVersion=28`).
 * Returns the user-visible location.
 */
@Suppress("DEPRECATION")
private fun writeToLegacyDownloads(fileName: String, input: InputStream): String {
    val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    val dir = File(downloads, DOWNLOAD_SUBDIR).apply { mkdirs() }
    val dest = File(dir, fileName)
    dest.outputStream().use { out -> input.copyTo(out) }
    return "Downloads/$DOWNLOAD_SUBDIR/$fileName"
}

/**
 * Download one export output file to app-private cache storage, using an
 * AUTHENTICATED request — the bearer token goes in the `Authorization` header
 * via [Network.buildOkHttp]'s [video.crumb.app.data.SecureStore]-backed
 * interceptor, never in the URL. This is the #1/#5 fix: the old code built a
 * `?token=<JWT>` URL from [outputFile]'s relative `downloadUrl` and handed
 * that to DownloadManager / the share sheet, both of which persist or forward
 * the URL (and therefore the token) outside the app's control.
 *
 * Re-downloads on every call rather than caching a prior result — export
 * output can be large, and a stale duplicate on repeated taps is an acceptable
 * trade for not adding extra cache-invalidation state to this fix's scope.
 * Returns the local [File] on success.
 */
private suspend fun downloadExportFileToCache(
    context: Context,
    container: AppContainer,
    outputFile: ExportOutputFile,
): Result<File> = withContext(Dispatchers.IO) {
    runCatching {
        // A short-lived client for this one download. Built the same way the
        // app's main API client is (Network.buildOkHttp attaches the current
        // bearer token via AuthInterceptor) but kept separate from the shared
        // Retrofit client's connection pool/dispatcher — this is a one-shot
        // transfer, not a long-lived API client — and explicitly shut down
        // below so it doesn't leak threads/sockets (the same leak #12 fixed
        // for the shared client).
        val client = Network.buildOkHttp(container.store)
        try {
            val base = container.store.serverUrl.trimEnd('/')
            val path = outputFile.downloadUrl.let { if (it.startsWith("/")) it else "/$it" }
            // Credential-free URL: the auth interceptor adds the bearer token as
            // the Authorization header. (The JWT-in-URL `MediaUrls.authed()` builder
            // was removed — nothing puts the bearer token in a URL now. #147-9.)
            val absoluteUrl = "$base$path"

            val safeId = outputFile.cameraId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
            val fileName = "crumb-export-$safeId.mp4"
            val exportDir = File(context.cacheDir, EXPORT_CACHE_SUBDIR).apply { mkdirs() }
            val destFile = File(exportDir, fileName)

            val request = Request.Builder().url(absoluteUrl).build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    error("Server returned HTTP ${response.code}")
                }
                val body = response.body ?: error("Empty response body")
                destFile.outputStream().use { out -> body.byteStream().copyTo(out) }
            }
            destFile
        } finally {
            // See AppContainer.rebuildApi() for the same pattern: release the
            // dispatcher's thread pool + pooled connections instead of leaking
            // them once this one-shot client is done.
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
        }
    }
}

/**
 * Share a downloaded export file via the system share sheet, using a scoped
 * `content://` [FileProvider] Uri (read permission granted to the receiving
 * app only, for this file only) instead of a raw file path or — as before — a
 * token-bearing URL.
 */
private fun shareLocalFile(context: Context, file: File) {
    try {
        val authority = "${context.packageName}.fileprovider"
        val uri = FileProvider.getUriForFile(context, authority, file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra(Intent.EXTRA_SUBJECT, "CrumbVMS Export")
        }
        context.startActivity(Intent.createChooser(intent, "Share export"))
    } catch (e: android.content.ActivityNotFoundException) {
        android.widget.Toast
            .makeText(context, "No app available to share", android.widget.Toast.LENGTH_SHORT)
            .show()
    }
}

// ─── formatting ───────────────────────────────────────────────────────────────

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1_073_741_824L -> "%.1f GB".format(bytes / 1_073_741_824.0)
    bytes >= 1_048_576L -> "%.1f MB".format(bytes / 1_048_576.0)
    bytes >= 1_024L -> "%.1f KB".format(bytes / 1_024.0)
    else -> "$bytes B"
}
