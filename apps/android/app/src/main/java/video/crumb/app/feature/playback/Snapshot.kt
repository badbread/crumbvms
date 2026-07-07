// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream

/**
 * Save a captured video frame to the device gallery under Pictures/Crumb/
 * (commercial-VMS-style "Snapshot saved to Pictures/…"). Returns a human-readable
 * location on success, or null on failure.
 *
 * - Q+ (API 29+): MediaStore with RELATIVE_PATH — lands in the gallery, no
 *   storage permission required.
 * - Pre-Q: the app's external Pictures dir (no permission; not gallery-indexed).
 */
fun saveFrameToGallery(context: Context, bitmap: Bitmap, camName: String): String? {
    val safeCam = camName.replace(Regex("[^A-Za-z0-9_-]"), "_").ifBlank { "camera" }
    val stamp = android.text.format.DateFormat.format("yyyyMMdd_HHmmss", System.currentTimeMillis())
    val fileName = "crumb_${safeCam}_$stamp.jpg"
    return try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Crumb")
            }
            val uri = context.contentResolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values,
            ) ?: return null
            context.contentResolver.openOutputStream(uri)?.use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)
            } ?: return null
            "Pictures/Crumb/$fileName"
        } else {
            val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_PICTURES), "Crumb")
            dir.mkdirs()
            val f = File(dir, fileName)
            FileOutputStream(f).use { out -> bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out) }
            f.absolutePath
        }
    } catch (e: Exception) {
        android.util.Log.w("Snapshot", "snapshot save failed", e)
        null
    }
}
