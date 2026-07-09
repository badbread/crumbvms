// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.update

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [UpdateUiState]'s derived gating — `updateAvailable` and
 * `showBanner` (issue #7). Uses the explicit `ownVersion` constructor param so
 * the version compare is deterministic without `BuildConfig`.
 */
class UpdateUiStateTest {

    @Test
    fun `update available when latest is strictly newer`() {
        val state = UpdateUiState(
            enabled = true,
            latestVersion = "0.0.2",
            everChecked = true,
            ownVersion = "0.0.1",
        )
        assertTrue(state.updateAvailable)
    }

    @Test
    fun `no update when own version is equal or newer`() {
        assertFalse(
            UpdateUiState(enabled = true, latestVersion = "0.0.2", ownVersion = "0.0.2").updateAvailable,
        )
        assertFalse(
            UpdateUiState(enabled = true, latestVersion = "0.0.1", ownVersion = "0.1.0").updateAvailable,
        )
    }

    @Test
    fun `unparsable own version is never an update`() {
        // A local/debug build like "0.0.1-dev" is "no signal", never a banner.
        assertFalse(
            UpdateUiState(enabled = true, latestVersion = "9.9.9", ownVersion = "0.0.1-dev").updateAvailable,
        )
    }

    @Test
    fun `no latest version means no update`() {
        assertFalse(
            UpdateUiState(enabled = true, latestVersion = null, ownVersion = "0.0.1").updateAvailable,
        )
    }

    @Test
    fun `banner shows for a fresh newer release`() {
        val state = UpdateUiState(
            enabled = true,
            latestVersion = "0.0.2",
            dismissedVersion = null,
            ownVersion = "0.0.1",
        )
        assertTrue(state.showBanner)
    }

    @Test
    fun `banner is suppressed for the exact dismissed version`() {
        val state = UpdateUiState(
            enabled = true,
            latestVersion = "0.0.2",
            dismissedVersion = "0.0.2",
            ownVersion = "0.0.1",
        )
        assertFalse(state.showBanner)
    }

    @Test
    fun `banner reappears when a newer release than the dismissed one lands`() {
        val state = UpdateUiState(
            enabled = true,
            latestVersion = "0.0.3",
            dismissedVersion = "0.0.2",
            ownVersion = "0.0.1",
        )
        assertTrue(state.showBanner)
    }
}
