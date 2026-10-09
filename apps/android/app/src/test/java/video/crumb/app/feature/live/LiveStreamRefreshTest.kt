// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Stream-URL re-resolution policy (A1) and the usable-network gate (A2). */
class LiveStreamRefreshTest {

    @Test
    fun refreshOnlyAfterRepeatedFailures() {
        assertFalse(shouldRefreshStreams(0))
        assertFalse(shouldRefreshStreams(STREAM_REFRESH_AFTER_FAILURES - 1))
        assertTrue(shouldRefreshStreams(STREAM_REFRESH_AFTER_FAILURES))
        assertTrue(shouldRefreshStreams(30))
    }

    @Test
    fun refreshIsThrottledPerCamera() {
        assertTrue(streamRefreshAllowed(null, 1_000L))
        assertFalse(streamRefreshAllowed(1_000L, 1_000L + STREAM_REFRESH_MIN_INTERVAL_MS - 1))
        assertTrue(streamRefreshAllowed(1_000L, 1_000L + STREAM_REFRESH_MIN_INTERVAL_MS))
    }

    @Test
    fun initialFetchRetryBacksOffAndCaps() {
        assertEquals(2_000L, streamFetchRetryDelayMs(0))
        assertEquals(4_000L, streamFetchRetryDelayMs(1))
        assertEquals(8_000L, streamFetchRetryDelayMs(2))
        assertEquals(STREAM_FETCH_RETRY_MAX_MS, streamFetchRetryDelayMs(10))
        assertEquals(STREAM_FETCH_RETRY_MAX_MS, streamFetchRetryDelayMs(1_000))
        assertEquals(2_000L, streamFetchRetryDelayMs(-5))
    }

    @Test
    fun onlyTransientFailuresAreRetried() {
        assertTrue(isRetryableStreamFailure(null)) // network error / timeout
        assertTrue(isRetryableStreamFailure(500))
        assertTrue(isRetryableStreamFailure(503))
        assertTrue(isRetryableStreamFailure(408))
        assertTrue(isRetryableStreamFailure(429))
        assertFalse(isRetryableStreamFailure(401))
        assertFalse(isRetryableStreamFailure(403))
        assertFalse(isRetryableStreamFailure(404))
    }

    @Test
    fun lanWithoutInternetValidationCountsAsOnline() {
        // Wi-Fi/Ethernet with no WAN: not validated, but the NVR is on the LAN.
        assertTrue(networkCountsAsOnline(hasInternetCapability = true, isLanTransport = true))
        assertTrue(networkCountsAsOnline(hasInternetCapability = false, isLanTransport = true))
        assertTrue(networkCountsAsOnline(hasInternetCapability = true, isLanTransport = false))
        assertFalse(networkCountsAsOnline(hasInternetCapability = false, isLanTransport = false))
    }
}
