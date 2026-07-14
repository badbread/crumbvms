// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import android.content.Context
import java.io.File

/**
 * Bounded cleanup of the app-private cache subdirectories that accumulate files
 * the app writes but never prunes (#147-12): the plate-report PDFs
 * (`cacheDir/reports`, written by `PlatesPdf.generatePlateReportPdf`) and the
 * downloaded export clips staged for the share sheet (`cacheDir/exports`, written
 * by `ExportScreen`). Left unbounded these grow forever — a heavy LPR user can
 * pile up hundreds of multi-MB PDFs, and exports are whole video files.
 *
 * Deliberately narrow in scope:
 *  - Only the two subdirs Crumb itself fills are touched. Coil's own disk cache is
 *    already size-bounded by Coil, and playback/live never write persistent files.
 *  - Camera snapshots are saved to the device gallery (MediaStore / external files),
 *    i.e. the USER's photos — never swept here.
 *
 * Policy per subdir: delete anything older than [MAX_AGE_MS]; then, if the subdir
 * is still over its byte cap, delete oldest-first until it fits. Best-effort and
 * totally non-fatal — every filesystem op is guarded so a janitor hiccup can never
 * take the app down. Meant to run once on app start, off the main thread.
 */
object CacheJanitor {

    /** Files older than this are pruned regardless of the size cap. 7 days. */
    private const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000

    /**
     * Managed cache subdirs and their total-size caps. Names mirror the private
     * `REPORTS_CACHE_SUBDIR` / `EXPORT_CACHE_SUBDIR` constants in the writers.
     * Exports are whole video files, so a roomier cap; report PDFs are small.
     */
    private val MANAGED: List<Pair<String, Long>> = listOf(
        "reports" to 50L * 1024 * 1024, // 50 MB of plate-report PDFs
        "exports" to 250L * 1024 * 1024, // 250 MB of staged export clips
    )

    /** Prune every managed subdir under [context]'s cache dir. Never throws. */
    fun prune(context: Context) {
        val cacheDir = runCatching { context.cacheDir }.getOrNull() ?: return
        val now = System.currentTimeMillis()
        for ((subdir, maxBytes) in MANAGED) {
            runCatching { pruneDir(File(cacheDir, subdir), now, maxBytes) }
        }
    }

    private fun pruneDir(dir: File, now: Long, maxBytes: Long) {
        if (!dir.isDirectory) return
        val files = dir.listFiles()?.filter { it.isFile } ?: return

        // 1. Age cap: drop anything past MAX_AGE_MS.
        val survivors = ArrayList<File>(files.size)
        for (f in files) {
            if (now - f.lastModified() > MAX_AGE_MS) {
                runCatching { f.delete() }
            } else {
                survivors.add(f)
            }
        }

        // 2. Size cap: if still over budget, delete oldest-first until it fits.
        var total = survivors.sumOf { it.length() }
        if (total <= maxBytes) return
        survivors.sortBy { it.lastModified() } // oldest first
        for (f in survivors) {
            if (total <= maxBytes) break
            val len = f.length()
            if (runCatching { f.delete() }.getOrDefault(false)) total -= len
        }
    }
}
