// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Unit tests for the pure report-delivery helpers in `PlatesPdf.kt`
 * ([sanitizePlateForFilename], [plateReportFileName], [uniqueLegacyFile]) — the
 * naming/collision logic behind the new Open / Save to Downloads / Share flow.
 * These run on the JVM (no device) so the filename derivation and the legacy
 * Downloads collision guard are covered without an emulator.
 */
class PlatesPdfTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun `sanitize keeps only letters and digits`() {
        assertEquals("7ABC123", sanitizePlateForFilename("7ABC123"))
        assertEquals("7ABC123", sanitizePlateForFilename("7-ABC 123"))
        assertEquals("ABC123", sanitizePlateForFilename("ABC·123!"))
    }

    @Test
    fun `sanitize falls back to plate for blank or symbol-only input`() {
        assertEquals("plate", sanitizePlateForFilename(""))
        assertEquals("plate", sanitizePlateForFilename("   "))
        assertEquals("plate", sanitizePlateForFilename("--- ///"))
    }

    @Test
    fun `report filename assembles slug and stamp with pdf extension`() {
        assertEquals(
            "crumb-plate-7ABC123-20260807_101530.pdf",
            plateReportFileName("7ABC 123", "20260807_101530"),
        )
        // Blank plate still yields a well-formed, non-empty name.
        assertEquals(
            "crumb-plate-plate-20260807_101530.pdf",
            plateReportFileName("", "20260807_101530"),
        )
    }

    @Test
    fun `unique legacy file returns the name unchanged when free`() {
        val dir = tmp.newFolder("dl")
        val f = uniqueLegacyFile(dir, "crumb-plate-ABC-1.pdf")
        assertEquals("crumb-plate-ABC-1.pdf", f.name)
    }

    @Test
    fun `unique legacy file suffixes before the extension on collision`() {
        val dir = tmp.newFolder("dl")
        File(dir, "crumb-plate-ABC-1.pdf").writeText("x")
        val f1 = uniqueLegacyFile(dir, "crumb-plate-ABC-1.pdf")
        assertEquals("crumb-plate-ABC-1 (1).pdf", f1.name)

        // With (1) also taken, it advances to (2).
        File(dir, "crumb-plate-ABC-1 (1).pdf").writeText("x")
        val f2 = uniqueLegacyFile(dir, "crumb-plate-ABC-1.pdf")
        assertEquals("crumb-plate-ABC-1 (2).pdf", f2.name)
    }

    @Test
    fun `unique legacy file handles a name with no extension`() {
        val dir = tmp.newFolder("dl")
        File(dir, "report").writeText("x")
        val f = uniqueLegacyFile(dir, "report")
        assertEquals("report (1)", f.name)
        assertFalse(f.exists())
        assertTrue(File(dir, "report").exists())
    }
}
