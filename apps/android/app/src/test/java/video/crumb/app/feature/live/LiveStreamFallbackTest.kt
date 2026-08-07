// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import video.crumb.app.data.LiveStreamsResponse

/**
 * The live-stream fallback ladder (#524).
 *
 * A camera that emits H.265 on BOTH its main and its sub has nothing Media3's
 * RTSP stack can decode: the single main→sub downgrade lands on a second
 * unplayable stream and the client reconnect-loops forever, even though the
 * server publishes an H.264 `_mobile` transcode for exactly this case. These
 * tests pin the pure decision logic that walks down to it — chain construction,
 * where to start, when a failure is a codec verdict rather than a blip, and the
 * per-run memory that stops every revisit re-walking the whole ladder.
 */
class LiveStreamFallbackTest {

    private fun streams(
        main: String? = "rtsp://u:p@host:18554/drive",
        sub: String? = "rtsp://u:p@host:18554/drive_sub",
        subv: String? = null,
        mobile: String? = "rtsp://u:p@host:18554/drive_mobile",
    ) = LiveStreamsResponse(
        cameraId = "8f14e45f-ceea-467a-9f3a-8f14e45fceea",
        rtspMainUrl = main ?: "rtsp://u:p@host:18554/drive",
        rtspSubUrl = sub,
        rtspSubvUrl = subv,
        rtspMobileUrl = mobile,
    )

    @Before
    fun resetMemory() {
        LiveStreamFallbackMemory.clearAll()
    }

    // ── chain construction ────────────────────────────────────────────────────

    @Test
    fun `wall chain prefers subv then sub then the transcode`() {
        val chain = streams(subv = "rtsp://u:p@host:18554/drive_subv").wallStreamChain()
        assertEquals(listOf(StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE), chain)
    }

    @Test
    fun `wall chain never escalates to the main when the camera has a sub`() {
        // A wall of N tiles must not end up pulling N main-bitrate streams.
        assertFalse(StreamTier.MAIN in streams().wallStreamChain())
    }

    @Test
    fun `wall chain on a camera with no sub is main then the transcode`() {
        val chain = streams(sub = null).wallStreamChain()
        assertEquals(listOf(StreamTier.MAIN, StreamTier.MOBILE), chain)
    }

    @Test
    fun `chain omits rungs the server does not publish`() {
        // Mobile transcode disabled server-side, or a Frigate-served camera.
        val chain = streams(sub = null, mobile = null).wallStreamChain()
        assertEquals(listOf(StreamTier.MAIN), chain)
    }

    @Test
    fun `fullscreen chain off a metered link is HD first then all the way down`() {
        val chain = streams(subv = "rtsp://u:p@host:18554/drive_subv")
            .fullscreenStreamChain(metered = false)
        assertEquals(
            listOf(StreamTier.MAIN, StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE),
            chain,
        )
    }

    @Test
    fun `fullscreen chain on a metered link keeps the data-saver order`() {
        val chain = streams().fullscreenStreamChain(metered = true)
        assertEquals(listOf(StreamTier.SUB, StreamTier.MOBILE, StreamTier.MAIN), chain)
    }

    @Test
    fun `metered fullscreen on a camera with no sub still starts on the transcode`() {
        // Pre-#524 behaviour: `lowRes ?: rtspMobileUrl` on a metered link. Kept.
        val chain = streams(sub = null).fullscreenStreamChain(metered = true)
        assertEquals(listOf(StreamTier.MOBILE, StreamTier.MAIN), chain)
        assertEquals(StreamTier.MOBILE, startTier(chain, emptySet()))
    }

    @Test
    fun `a rung that repeats an earlier URL is dropped`() {
        // Defensive: a server that answers with the same URL twice must not cost
        // an extra doomed attempt on a stream already known to fail.
        val dup = "rtsp://u:p@host:18554/drive_sub"
        val chain = streams(sub = dup, subv = dup).wallStreamChain()
        assertEquals(listOf(StreamTier.SUBV, StreamTier.MOBILE), chain)
    }

    // ── walking the ladder ────────────────────────────────────────────────────

    @Test
    fun `start tier is the top rung when nothing has failed yet`() {
        val chain = streams().fullscreenStreamChain(metered = false)
        assertEquals(StreamTier.MAIN, startTier(chain, emptySet()))
    }

    @Test
    fun `start tier skips rungs this run already found unplayable`() {
        val chain = streams().fullscreenStreamChain(metered = false)
        val failed = setOf(StreamTier.MAIN, StreamTier.SUB)
        assertEquals(StreamTier.MOBILE, startTier(chain, failed))
    }

    @Test
    fun `start tier falls back to the top rung when every rung has failed`() {
        // Total outage rather than a codec verdict — try again rather than refuse.
        val chain = streams().fullscreenStreamChain(metered = false)
        assertEquals(StreamTier.MAIN, startTier(chain, chain.toSet()))
    }

    @Test
    fun `start tier is null when the camera exposes nothing`() {
        assertNull(startTier(emptyList(), emptySet()))
    }

    @Test
    fun `next tier is the one below, skipping known-bad rungs`() {
        val chain = streams(subv = "rtsp://u:p@host:18554/drive_subv")
            .fullscreenStreamChain(metered = false)
        assertEquals(StreamTier.SUBV, nextTier(chain, StreamTier.MAIN, emptySet()))
        assertEquals(
            StreamTier.MOBILE,
            nextTier(chain, StreamTier.MAIN, setOf(StreamTier.SUBV, StreamTier.SUB)),
        )
    }

    @Test
    fun `next tier is null on the last rung`() {
        val chain = streams().fullscreenStreamChain(metered = false)
        assertNull(nextTier(chain, StreamTier.MOBILE, emptySet()))
    }

    // ── when a failure is a codec verdict ─────────────────────────────────────

    @Test
    fun `a stream that never played falls back`() {
        assertTrue(
            shouldFallBackToNextTier(hasNextTier = true, everReady = false, errorCode = null),
        )
    }

    @Test
    fun `a stream that played and then dropped reconnects instead of falling back`() {
        // Camera reboot / AP roam / Wi-Fi blip: an IO timeout on a stream that was
        // playing must NOT strand a healthy camera on the server transcode.
        assertFalse(
            shouldFallBackToNextTier(hasNextTier = true, everReady = true, errorCode = 2003),
        )
    }

    @Test
    fun `a decoder error falls back even on a stream that had been playing`() {
        assertTrue(
            shouldFallBackToNextTier(hasNextTier = true, everReady = true, errorCode = 4005),
        )
    }

    @Test
    fun `no rung left means no fallback, whatever the failure`() {
        assertFalse(
            shouldFallBackToNextTier(hasNextTier = false, everReady = false, errorCode = 4005),
        )
    }

    @Test
    fun `format and decoder-init errors count as unplayable`() {
        // 1004 FAILED_RUNTIME_CHECK (the RTSP client's "missing attribute fmtp"),
        // 3003 PARSING_CONTAINER_UNSUPPORTED, 4001 DECODER_INIT_FAILED,
        // 4002 DECODER_QUERY_FAILED, 4004 EXCEEDS_CAPABILITIES,
        // 4005 DECODING_FORMAT_UNSUPPORTED.
        listOf(1004, 3003, 4001, 4002, 4004, 4005).forEach {
            assertTrue("code $it should be unplayable", isUnplayableFormatError(it))
        }
    }

    @Test
    fun `transient errors do not count as unplayable`() {
        // 2001/2002/2003 IO, 1003 timeout, 4003 DECODING_FAILED (a corrupt packet
        // on an otherwise healthy stream), 3001 CONTAINER_MALFORMED.
        listOf(1000, 1003, 2001, 2002, 2003, 3001, 4003).forEach {
            assertFalse("code $it should be retryable", isUnplayableFormatError(it))
        }
    }

    // ── the #524 scenario, end to end ─────────────────────────────────────────

    @Test
    fun `an all-H265 camera walks main to sub to the transcode and stays there`() {
        val cameraId = "all-h265-cam"
        val s = streams(subv = "rtsp://u:p@host:18554/drive_subv")
        val chain = s.fullscreenStreamChain(metered = false)

        // Fullscreen opens on the main; H265, so it never reaches a frame.
        var tier = startTier(chain, LiveStreamFallbackMemory.failedTiers(cameraId))
        assertEquals(StreamTier.MAIN, tier)

        // Walk down every unplayable rung exactly as scheduleReconnect() does.
        var guard = 0
        while (guard++ < 10) {
            val failed = LiveStreamFallbackMemory.failedTiers(cameraId)
            val next = nextTier(chain, tier, failed)
            // Everything but the transcode is H265 here: only MOBILE ever plays.
            val everReady = tier == StreamTier.MOBILE
            if (!shouldFallBackToNextTier(next != null, everReady, errorCode = null)) break
            LiveStreamFallbackMemory.markFailed(cameraId, tier!!)
            tier = next
        }

        // Landed on the server's H.264 transcode instead of looping forever.
        assertEquals(StreamTier.MOBILE, tier)
        assertEquals("SD transcode · tap for HD", sdBadgeLabel(tier))

        // And the wall tile for the same camera, resolved independently, opens
        // straight on the transcode rather than re-walking the whole ladder.
        val wall = s.wallStreamChain()
        assertEquals(
            StreamTier.MOBILE,
            startTier(wall, LiveStreamFallbackMemory.failedTiers(cameraId)),
        )
    }

    @Test
    fun `an H265-main-only camera still stops at the H264 sub`() {
        // The pre-existing behaviour must not regress into always transcoding.
        val cameraId = "h265-main-cam"
        val chain = streams().fullscreenStreamChain(metered = false)
        LiveStreamFallbackMemory.markFailed(cameraId, StreamTier.MAIN)
        val tier = startTier(chain, LiveStreamFallbackMemory.failedTiers(cameraId))
        assertEquals(StreamTier.SUB, tier)
        assertEquals("SD · tap for HD", sdBadgeLabel(tier))
    }

    // ── the per-run memory ────────────────────────────────────────────────────

    @Test
    fun `memory is per camera and forgettable`() {
        LiveStreamFallbackMemory.markFailed("cam-a", StreamTier.MAIN)
        LiveStreamFallbackMemory.markFailed("cam-a", StreamTier.SUB)
        LiveStreamFallbackMemory.markFailed("cam-b", StreamTier.MAIN)

        assertEquals(
            setOf(StreamTier.MAIN, StreamTier.SUB),
            LiveStreamFallbackMemory.failedTiers("cam-a"),
        )
        assertEquals(setOf(StreamTier.MAIN), LiveStreamFallbackMemory.failedTiers("cam-b"))
        assertEquals(emptySet<StreamTier>(), LiveStreamFallbackMemory.failedTiers("cam-c"))

        // A camera edit / exhausted ladder forgets just that camera…
        LiveStreamFallbackMemory.clear("cam-a")
        assertEquals(emptySet<StreamTier>(), LiveStreamFallbackMemory.failedTiers("cam-a"))
        assertEquals(setOf(StreamTier.MAIN), LiveStreamFallbackMemory.failedTiers("cam-b"))

        // …a server config change or an explicit Retry forgets everything.
        LiveStreamFallbackMemory.clearAll()
        assertEquals(emptySet<StreamTier>(), LiveStreamFallbackMemory.failedTiers("cam-b"))
    }

    @Test
    fun `the main stream shows no SD badge`() {
        assertNull(sdBadgeLabel(StreamTier.MAIN))
        assertNull(sdBadgeLabel(null))
    }
}
