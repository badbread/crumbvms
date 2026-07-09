// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [SemVer] — mirrors the equivalent Rust test module in
 * `services/api/src/updates.rs` (`parses_plain_versions`,
 * `rejects_prerelease_suffix_and_garbage`, `detects_newer_release`,
 * `unparsable_version_is_no_signal_not_false`) so both ends of the
 * update-available check (issue #7) agree on precedence.
 */
class SemVerTest {

    @Test
    fun `parses plain versions`() {
        assertEquals(Triple(0L, 0L, 1L), SemVer.parse("0.0.1"))
        assertEquals(Triple(1L, 2L, 3L), SemVer.parse("1.2.3"))
        assertEquals(Triple(1L, 2L, 3L), SemVer.parse(" 1.2.3 "))
    }

    @Test
    fun `rejects prerelease suffix and garbage`() {
        // Unparsable => "no signal" (docs/UPDATE-SYSTEM-PLAN.md sec 2.2), the
        // exact case a local/debug build hits (e.g. "0.0.1-dev").
        assertNull(SemVer.parse("0.0.1-dev"))
        assertNull(SemVer.parse("v0.0.1"))
        assertNull(SemVer.parse("0.0"))
        assertNull(SemVer.parse("0.0.1.2"))
        assertNull(SemVer.parse(""))
        assertNull(SemVer.parse("not-a-version"))
    }

    @Test
    fun `detects newer release`() {
        assertEquals(true, SemVer.isNewer("0.0.1", "0.0.2"))
        assertEquals(false, SemVer.isNewer("0.0.2", "0.0.2"))
        assertEquals(false, SemVer.isNewer("0.1.0", "0.0.9"))
        assertEquals(true, SemVer.isNewer("0.9.9", "1.0.0"))
    }

    @Test
    fun `unparsable version is no signal not false`() {
        assertNull(SemVer.isNewer("0.0.1-dev", "0.0.2"))
        assertNull(SemVer.isNewer("0.0.1", "not-a-version"))
    }
}
