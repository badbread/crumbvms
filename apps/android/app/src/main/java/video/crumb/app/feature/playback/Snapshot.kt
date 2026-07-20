// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

/**
 * A saved snapshot: where it landed (human-readable, for the "Snapshot saved to …"
 * confirmation) plus a scoped `content://` [Uri] that can be handed to the system
 * share sheet ([shareImageUri]).
 *
 * - On API 29+ the [shareUri] is the MediaStore image entry itself (already a
 *   shareable `content://media/…` Uri — no FileProvider needed).
 * - On pre-Q it's a [FileProvider] Uri over the app-external Pictures file (the
 *   provider path is declared in `res/xml/file_paths.xml`).
 */
data class SavedSnapshot(val displayPath: String, val shareUri: Uri)

/**
 * Save a captured video frame to the device gallery under Pictures/Crumb/
 * (commercial-VMS-style "Snapshot saved to Pictures/…"). Returns a [SavedSnapshot]
 * (location + shareable Uri) on success, or null on failure.
 *
 * - Q+ (API 29+): MediaStore with RELATIVE_PATH — lands in the gallery, no
 *   storage permission required.
 * - Pre-Q: the app's external Pictures dir (no permission; not gallery-indexed).
 *
 * Runs the JPEG compress and MediaStore/file I/O off the main thread (same
 * `withContext(Dispatchers.IO)` pattern as `PlatesPdf.generatePlateReportPdf`)
 * — callers only need to grab the [Bitmap] (e.g. `TextureView.getBitmap`) on
 * Main before calling in.
 */
suspend fun saveFrameToGallery(context: Context, bitmap: Bitmap, camName: String): SavedSnapshot? =
    withContext(Dispatchers.IO) {
        val safeCam = camName.replace(Regex("[^A-Za-z0-9_-]"), "_").ifBlank { "camera" }
        val stamp = android.text.format.DateFormat.format("yyyyMMdd_HHmmss", System.currentTimeMillis())
        val fileName = "crumb_${safeCam}_$stamp.jpg"
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                    put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Crumb")
                }
                val uri = context.contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values,
                ) ?: return@withContext null
                context.contentResolver.openOutputStream(uri)?.use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)
                } ?: return@withContext null
                // The MediaStore entry is itself a shareable content:// Uri.
                SavedSnapshot(displayPath = "Pictures/Crumb/$fileName", shareUri = uri)
            } else {
                val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_PICTURES), "Crumb")
                dir.mkdirs()
                val f = File(dir, fileName)
                FileOutputStream(f).use { out -> bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out) }
                val shareUri = FileProvider.getUriForFile(
                    context, "${context.packageName}.fileprovider", f,
                )
                SavedSnapshot(displayPath = f.absolutePath, shareUri = shareUri)
            }
        } catch (e: Exception) {
            android.util.Log.w("Snapshot", "snapshot save failed", e)
            null
        }
    }

/**
 * Open the Android system share sheet for a saved snapshot [uri] (a JPEG image).
 * The receiving app is granted read access to this one item only
 * ([Intent.FLAG_GRANT_READ_URI_PERMISSION]); no persistent permission is granted.
 */
fun shareImageUri(context: Context, uri: Uri) {
    try {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "image/jpeg"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra(Intent.EXTRA_SUBJECT, "CrumbVMS Snapshot")
        }
        context.startActivity(Intent.createChooser(intent, "Share snapshot"))
    } catch (e: android.content.ActivityNotFoundException) {
        android.widget.Toast
            .makeText(context, "No app available to share", android.widget.Toast.LENGTH_SHORT)
            .show()
    }
}
