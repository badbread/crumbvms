// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import video.crumb.app.data.ExportOutputFile

class ExportFileNamesTest {

    private fun file(filename: String = "", downloadName: String = "", cameraId: String = "cam-1") =
        ExportOutputFile(
            cameraId = cameraId,
            downloadUrl = "/export/j/output/0",
            sizeBytes = 1,
            filename = filename,
            downloadName = downloadName,
        )

    @Test
    fun `allow-listed extensions pass through lowercased`() {
        assertEquals("mkv", sanitizedExportExtension("abc.MKV"))
        assertEquals("zip", sanitizedExportExtension("crumb_export.zip"))
        assertEquals("mp4", sanitizedExportExtension("abc.mp4"))
    }

    @Test
    fun `hostile or unknown extensions fall back to mp4`() {
        assertEquals("mp4", sanitizedExportExtension("x./../../foo"))
        assertEquals("mp4", sanitizedExportExtension("x.exe"))
        assertEquals("mp4", sanitizedExportExtension("x.mp4/.."))
        assertEquals("mp4", sanitizedExportExtension(""))
        assertEquals("mp4", sanitizedExportExtension("noext"))
        assertEquals("mp4", sanitizedExportExtension("trailing."))
    }

    @Test
    fun `friendly download name is used`() {
        val f = file(filename = "a1b2.mkv", downloadName = "Driveway 2026-10-29 14.05.06-14.09.10.mkv")
        assertEquals("Driveway 2026-10-29 14.05.06-14.09.10.mkv", exportSaveFileName(f))
    }

    @Test
    fun `extension falls back to on-disk filename when download name has none`() {
        val f = file(filename = "a1b2.mkv", downloadName = "Driveway clip")
        assertEquals("Driveway clip.mkv", exportSaveFileName(f))
    }

    @Test
    fun `path separators and dot-dot never survive`() {
        val names = listOf(
            "../../etc/passwd.mp4",
            "..\\..\\evil.mp4",
            "a/../../b.mp4",
            "....mp4",
            "x..y/..\\z.zip",
        )
        for (n in names) {
            val out = exportSaveFileName(file(filename = "a.mp4", downloadName = n))
            assertFalse(out, out.contains("/") || out.contains("\\") || out.contains(".."))
        }
        assertEquals("passwd.mp4", exportSaveFileName(file(downloadName = "../../etc/passwd.mp4")))
    }

    @Test
    fun `blank or unusable download name uses camera fallback`() {
        assertEquals("crumb-export-cam-1.zip", exportSaveFileName(file(filename = "crumb_export.zip")))
        assertEquals("crumb-export-cam-1.mp4", exportSaveFileName(file(downloadName = "...", filename = "")))
    }

    @Test
    fun `hostile server filename cannot escape via extension`() {
        assertEquals("crumb-export-cam-1.mp4", exportSaveFileName(file(filename = "x./../../foo")))
    }
}
