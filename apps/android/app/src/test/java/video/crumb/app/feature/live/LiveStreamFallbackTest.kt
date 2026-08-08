// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import org.junit.After
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
 * A camera whose main AND sub both fail to come up on this device has nothing to
 * play: the single main→sub downgrade lands on a second unplayable stream and the
 * client reconnect-loops forever, even though the server publishes an H.264
 * `_mobile` transcode for exactly this case. These tests pin the pure decision
 * logic that walks down to it — chain construction, where to start, when a failure
 * is a codec verdict rather than a blip, and the per-run memory that stops every
 * revisit re-walking the whole ladder.
 *
 * They also pin the #560 regression that came out of that fix: the first cut read
 * ANY failure before the first frame as a codec verdict and remembered it for the
 * whole app run, so a single connection failure or one slow first keyframe pinned
 * a perfectly healthy camera to SD until the app was relaunched. A failure that
 * says nothing about the codec now has to repeat across the whole backoff curve,
 * an unexplained one has to repeat at all, a known-deterministic signature steps
 * down at once, and every verdict expires.
 */
class LiveStreamFallbackTest {

    private fun streams(
        main: String? = "rtsp://u:p@host:18554/drive",
        mainv: String? = null,
        sub: String? = "rtsp://u:p@host:18554/drive_sub",
        subv: String? = null,
        mobile: String? = "rtsp://u:p@host:18554/drive_mobile",
    ) = LiveStreamsResponse(
        cameraId = "8f14e45f-ceea-467a-9f3a-8f14e45fceea",
        rtspMainUrl = main ?: "rtsp://u:p@host:18554/drive",
        rtspMainvUrl = mainv,
        rtspSubUrl = sub,
        rtspSubvUrl = subv,
        rtspMobileUrl = mobile,
    )

    /** Fake monotonic clock (ns) so verdict expiry is testable without sleeping. */
    private var fakeNanos = 0L

    @Before
    fun resetMemory() {
        LiveStreamFallbackMemory.clearAll()
        fakeNanos = 0L
        LiveStreamFallbackMemory.nanoTime = { fakeNanos }
    }

    @After
    fun restoreClock() {
        LiveStreamFallbackMemory.clearAll()
        LiveStreamFallbackMemory.nanoTime = { System.nanoTime() }
    }

    private fun advanceMs(ms: Long) {
        fakeNanos += ms * 1_000_000L
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

    @Test
    fun `fullscreen chain puts the repaired main right after the raw main`() {
        val chain = streams(
            mainv = "rtsp://u:p@host:18554/drive_mainv",
            subv = "rtsp://u:p@host:18554/drive_subv",
        ).fullscreenStreamChain(metered = false)
        assertEquals(
            listOf(
                StreamTier.MAIN, StreamTier.MAINV,
                StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE,
            ),
            chain,
        )
        // The repaired main is HD, so it must carry no SD badge.
        assertNull(sdBadgeLabel(StreamTier.MAINV))
    }

    @Test
    fun `metered fullscreen keeps the repaired main a last resort with the raw main`() {
        val chain = streams(mainv = "rtsp://u:p@host:18554/drive_mainv")
            .fullscreenStreamChain(metered = true)
        assertEquals(
            listOf(StreamTier.SUB, StreamTier.MOBILE, StreamTier.MAIN, StreamTier.MAINV),
            chain,
        )
    }

    @Test
    fun `a no-sub camera puts the repaired main before the transcode on the wall`() {
        val chain = streams(mainv = "rtsp://u:p@host:18554/drive_mainv", sub = null)
            .wallStreamChain()
        assertEquals(listOf(StreamTier.MAIN, StreamTier.MAINV, StreamTier.MOBILE), chain)
    }

    @Test
    fun `the repaired main rung is absent when the server does not publish one`() {
        // The common case: mainv is null, so the rung is simply not in the ladder
        // and every existing chain is unchanged.
        assertFalse(StreamTier.MAINV in streams().fullscreenStreamChain(metered = false))
        assertFalse(StreamTier.MAINV in streams().wallStreamChain())
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
    fun `a stream that never played falls back only on REPEATED unexplained failures`() {
        // #560: one silent no-first-frame timeout is not a codec verdict — a cold
        // go2rtc restream, a long keyframe interval or a busy wall can produce it
        // on a perfectly playable H.264 camera. The second one in a row is.
        assertFalse(
            shouldFallBackToNextTier(
                hasNextTier = true,
                everReady = false,
                errorCode = null,
                failureDetail = null,
                preFirstFrameFailures = 1,
            ),
        )
        assertTrue(
            shouldFallBackToNextTier(
                hasNextTier = true,
                everReady = false,
                errorCode = null,
                failureDetail = null,
                preFirstFrameFailures = PRE_FIRST_FRAME_FAILURES_BEFORE_FALLBACK,
            ),
        )
    }

    @Test
    fun `a codec-agnostic failure before the first frame retries the SAME rung`() {
        // THE #560 REGRESSION. Media3 reports a failed/timed-out connection with an
        // IO code that says nothing about the codec. #529 read any pre-first-frame
        // failure as "this bitstream is undecodable" and stepped down — so one
        // Wi-Fi blip, or a camera slow to answer, dropped an H.264 camera to SD.
        // Now it takes the WHOLE fast-backoff curve of them, back to back, with
        // not one frame in between, before the rung is given up on.
        listOf(2000, 2001, 2002, 2003, 2004, 2999, 1002, 1003, 4006).forEach { code ->
            (1 until CODEC_AGNOSTIC_FAILURES_BEFORE_FALLBACK).forEach { n ->
                assertFalse(
                    "code $code, failure $n must not step down",
                    shouldFallBackToNextTier(
                        hasNextTier = true,
                        everReady = false,
                        errorCode = code,
                        failureDetail = null,
                        preFirstFrameFailures = n,
                    ),
                )
            }
        }
    }

    @Test
    fun `a rung that never plays at all is still escaped eventually`() {
        // The safety valve: a stream that structurally can't be brought up can
        // report an IO code on every single attempt (the RTP aggregation-packet
        // exception is thrown inside the loader and arrives wrapped in an
        // IOException), so "an IO code never counts" would re-strand #524's camera.
        assertTrue(
            shouldFallBackToNextTier(
                hasNextTier = true,
                everReady = false,
                errorCode = 2000,
                failureDetail = null,
                preFirstFrameFailures = CODEC_AGNOSTIC_FAILURES_BEFORE_FALLBACK,
            ),
        )
        // …and it takes strictly more evidence than an unexplained failure does.
        assertTrue(
            CODEC_AGNOSTIC_FAILURES_BEFORE_FALLBACK > PRE_FIRST_FRAME_FAILURES_BEFORE_FALLBACK,
        )
    }

    @Test
    fun `the RTP aggregation-packet failure steps down at once`() {
        // Media3 1.4.1's RtpH265Reader throws UnsupportedOperationException
        // ("need to implement processAggregationPacket") on RFC 7798 §4.4.2
        // Aggregation Packets — androidx/media#1008, never implemented. It is
        // deterministic for that stream, and it arrives dressed as an IO error, so
        // the code alone would have it retry ~30 s before escaping. The signature
        // in the exception chain is the real evidence.
        val detail = failureDetail(
            java.io.IOException(
                "Unexpected exception loading stream",
                UnsupportedOperationException("need to implement processAggregationPacket"),
            ),
        )
        assertTrue(detail!!, isUnplayableFailureDetail(detail))
        assertTrue(
            shouldFallBackToNextTier(
                hasNextTier = true,
                everReady = false,
                errorCode = 2000,
                failureDetail = detail,
                preFirstFrameFailures = 1,
            ),
        )
        // An ordinary IO failure carries no such signature.
        assertFalse(isUnplayableFailureDetail(failureDetail(java.net.SocketTimeoutException("read timed out"))))
        assertFalse(isUnplayableFailureDetail(null))
    }

    @Test
    fun `the missing-fmtp failure steps down at once instead of waiting out the IO backoff`() {
        // An LPR camera's H.265 MAIN advertises an SDP with no `a=fmtp`, so Media3's
        // RTSP client throws IllegalArgumentException("missing attribute fmtp"). On
        // the MAIN over RTSP it surfaces wrapped through RtspPlaybackException into a
        // 2000 IO code (captured on device, #561), which the graduated threshold
        // would otherwise retry ~30 s before escaping. The SDP is identical every
        // attempt, so the signature must step it down on the FIRST failure.
        val detail = failureDetail(
            java.io.IOException(
                "Source error",
                IllegalArgumentException("missing attribute fmtp"),
            ),
        )
        assertTrue(detail!!, isUnplayableFailureDetail(detail))
        assertTrue(
            shouldFallBackToNextTier(
                hasNextTier = true,
                everReady = false,
                errorCode = 2000,
                failureDetail = detail,
                preFirstFrameFailures = 1,
            ),
        )
        // Contrast: a generic 2000 IO failure with no such signature still has to
        // repeat across the whole backoff curve before the rung is abandoned — the
        // fmtp match must not have widened the codec-agnostic retry path (#560).
        (1 until CODEC_AGNOSTIC_FAILURES_BEFORE_FALLBACK).forEach { n ->
            assertFalse(
                "generic IO failure $n must still retry",
                shouldFallBackToNextTier(
                    hasNextTier = true,
                    everReady = false,
                    errorCode = 2000,
                    failureDetail = failureDetail(java.io.IOException("Source error")),
                    preFirstFrameFailures = n,
                ),
            )
        }
    }

    @Test
    fun `a failure detail never carries stream credentials into logcat`() {
        // RTSP URLs here embed the stream user and password; Media3 puts the URL it
        // was loading into plenty of its messages. A diagnostic must not be the
        // thing that leaks them (golden rule 1).
        val detail = failureDetail(
            java.io.IOException("Unable to connect to rtsp://user:hunter2@192.0.2.4:8554/cam_sub"),
        )!!
        assertFalse(detail, "hunter2" in detail)
        assertFalse(detail, "rtsp://" in detail)
        assertTrue(detail, "<url>" in detail)
        assertTrue(detail, "IOException" in detail)
        assertNull(redactUrls(null))
    }

    @Test
    fun `an unexplained no-frame failure counts, a post-playback one does not`() {
        // The stall watchdog reports no exception at all (errorCode = null): that
        // silent BUFFERING spin IS the H265 signature, so it counts.
        assertEquals(1, tallyPreFirstFrameFailure(0, everReady = false))
        assertEquals(2, tallyPreFirstFrameFailure(1, everReady = false))
        // A rung that already played is not accumulating codec evidence.
        assertEquals(0, tallyPreFirstFrameFailure(1, everReady = true))
        assertEquals(0, tallyPreFirstFrameFailure(9, everReady = true))
    }

    @Test
    fun `a stream that played and then dropped reconnects instead of falling back`() {
        // Camera reboot / AP roam / Wi-Fi blip: an IO timeout on a stream that was
        // playing must NOT strand a healthy camera on the server transcode.
        assertFalse(
            shouldFallBackToNextTier(
                hasNextTier = true,
                everReady = true,
                errorCode = 2003,
                failureDetail = null,
                preFirstFrameFailures = 99,
            ),
        )
    }

    @Test
    fun `a decoder error falls back even on a stream that had been playing`() {
        // A format/decoder verdict is definitive and needs no repetition.
        assertTrue(
            shouldFallBackToNextTier(
                hasNextTier = true,
                everReady = true,
                errorCode = 4005,
                failureDetail = null,
                preFirstFrameFailures = 0,
            ),
        )
        assertTrue(
            shouldFallBackToNextTier(
                hasNextTier = true,
                everReady = false,
                errorCode = 1004,
                failureDetail = null,
                preFirstFrameFailures = 0,
            ),
        )
    }

    @Test
    fun `no rung left means no fallback, whatever the failure`() {
        assertFalse(
            shouldFallBackToNextTier(
                hasNextTier = false,
                everReady = false,
                errorCode = 4005,
                failureDetail = null,
                preFirstFrameFailures = 99,
            ),
        )
    }

    @Test
    fun `codec-agnostic and format error codes are disjoint`() {
        listOf(2000, 2001, 2002, 2003, 2008, 1002, 1003, 4006).forEach {
            assertTrue("code $it should be codec-agnostic", isCodecAgnosticError(it))
            assertFalse("code $it must not be a format verdict", isUnplayableFormatError(it))
        }
        listOf(1004, 3003, 4001, 4002, 4004, 4005).forEach {
            assertFalse("code $it must not be codec-agnostic", isCodecAgnosticError(it))
        }
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

        // Walk down every unplayable rung exactly as scheduleReconnect() does: the
        // watchdog keeps firing with no exception, the tally climbs, and the rung
        // is abandoned once the evidence repeats. The counter resets per rung
        // because the player is re-keyed on the rung's URL.
        var guard = 0
        var noFrameFailures = 0
        while (guard++ < 40) {
            val failed = LiveStreamFallbackMemory.failedTiers(cameraId)
            val next = nextTier(chain, tier, failed)
            // Everything but the transcode is H265 here: only MOBILE ever plays.
            val everReady = tier == StreamTier.MOBILE
            noFrameFailures = tallyPreFirstFrameFailure(noFrameFailures, everReady)
            if (!shouldFallBackToNextTier(next != null, everReady, null, null, noFrameFailures)) {
                if (everReady) break
                continue // same rung, watchdog fires again
            }
            LiveStreamFallbackMemory.markFailed(cameraId, tier!!)
            tier = next
            noFrameFailures = 0
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

    // ── the #560 regression, end to end ───────────────────────────────────────

    @Test
    fun `a healthy H264 camera survives a Wi-Fi blip on the main without going SD`() {
        // The reported regression: H.264 cameras on unmetered Wi-Fi were "very
        // eager to go to SD". Fullscreen opens on the main, the connection fails
        // before the first frame (Media3: IO), and #529 stepped down AND latched
        // the verdict — so every later fullscreen opened on the sub, for the whole
        // app run. Now the same rung is retried and nothing is remembered.
        val cameraId = "h264-cam"
        val s = streams(subv = "rtsp://u:p@host:18554/drive_subv")
        val chain = s.fullscreenStreamChain(metered = false)

        var tier = startTier(chain, LiveStreamFallbackMemory.failedTiers(cameraId))
        assertEquals(StreamTier.MAIN, tier)

        var noFrameFailures = 0
        // Connection failed, then timed out, then failed again — all pre-first-frame.
        listOf(2001, 2002, 2001).forEach { code ->
            noFrameFailures = tallyPreFirstFrameFailure(noFrameFailures, everReady = false)
            val next = nextTier(chain, tier, LiveStreamFallbackMemory.failedTiers(cameraId))
            val stepDown = shouldFallBackToNextTier(next != null, false, code, null, noFrameFailures)
            assertFalse("errorCode $code must retry the main, not step down", stepDown)
        }

        // Still on HD, no badge, and nothing latched — a later revisit still opens HD.
        assertEquals(StreamTier.MAIN, tier)
        assertNull(sdBadgeLabel(tier))
        assertEquals(emptySet<StreamTier>(), LiveStreamFallbackMemory.failedTiers(cameraId))
        assertEquals(StreamTier.MAIN, startTier(chain, LiveStreamFallbackMemory.failedTiers(cameraId)))
    }

    @Test
    fun `one slow first keyframe costs a retry, not a permanent downgrade`() {
        // The other half of #560: the stall watchdog fires with NO exception after
        // the first-load buffering limit. A camera with a long GOP, or a cold
        // go2rtc restream, hits that once and then plays fine.
        val cameraId = "slow-start-cam"
        val chain = streams().fullscreenStreamChain(metered = false)
        val tier = startTier(chain, LiveStreamFallbackMemory.failedTiers(cameraId))
        assertEquals(StreamTier.MAIN, tier)

        val noFrameFailures = tallyPreFirstFrameFailure(0, everReady = false)
        val next = nextTier(chain, tier, emptySet())
        assertFalse(shouldFallBackToNextTier(next != null, false, null, null, noFrameFailures))
        assertEquals(emptySet<StreamTier>(), LiveStreamFallbackMemory.failedTiers(cameraId))
    }

    @Test
    fun `a verdict expires so a wrong guess heals without an app relaunch`() {
        val cameraId = "expiring-cam"
        val chain = streams().fullscreenStreamChain(metered = false)
        LiveStreamFallbackMemory.markFailed(cameraId, StreamTier.MAIN)

        // Inside the TTL the session keeps its verdict — revisits stay on the sub
        // instead of re-walking the ladder every time.
        advanceMs(LiveStreamFallbackMemory.VERDICT_TTL_MS - 1)
        assertEquals(setOf(StreamTier.MAIN), LiveStreamFallbackMemory.failedTiers(cameraId))
        assertEquals(StreamTier.SUB, startTier(chain, LiveStreamFallbackMemory.failedTiers(cameraId)))

        // Past it the guess is dropped and HD is tried again.
        advanceMs(2)
        assertEquals(emptySet<StreamTier>(), LiveStreamFallbackMemory.failedTiers(cameraId))
        assertEquals(StreamTier.MAIN, startTier(chain, LiveStreamFallbackMemory.failedTiers(cameraId)))
    }

    @Test
    fun `verdicts expire independently per rung`() {
        val cameraId = "staggered-cam"
        LiveStreamFallbackMemory.markFailed(cameraId, StreamTier.MAIN)
        advanceMs(LiveStreamFallbackMemory.VERDICT_TTL_MS / 2)
        LiveStreamFallbackMemory.markFailed(cameraId, StreamTier.SUB)
        assertEquals(
            setOf(StreamTier.MAIN, StreamTier.SUB),
            LiveStreamFallbackMemory.failedTiers(cameraId),
        )

        // The main's verdict ages out first; the sub's is still fresh.
        advanceMs(LiveStreamFallbackMemory.VERDICT_TTL_MS / 2 + 1)
        assertEquals(setOf(StreamTier.SUB), LiveStreamFallbackMemory.failedTiers(cameraId))
    }

    // ── the decision log line ─────────────────────────────────────────────────

    @Test
    fun `the log line names the rung, the code and the reason`() {
        // Diagnosability: a step-down must be visible in logcat, with enough to
        // tell a codec verdict from a link problem after the fact.
        val down = fallbackLogLine(
            cameraId = "cam-1",
            from = StreamTier.MAIN,
            to = StreamTier.SUB,
            steppedDown = true,
            everReady = false,
            errorCode = null,
            failureDetail = null,
            preFirstFrameFailures = 2,
        )
        assertTrue(down, down.contains("rung=MAIN"))
        assertTrue(down, down.contains("step down to SUB"))
        assertTrue(down, down.contains("errorCode=none"))
        assertTrue(down, down.contains("noFrameFailures=2"))

        val held = fallbackLogLine(
            cameraId = "cam-1",
            from = StreamTier.MAIN,
            to = StreamTier.SUB,
            steppedDown = false,
            everReady = false,
            errorCode = 2002,
            failureDetail = null,
            preFirstFrameFailures = 0,
        )
        assertTrue(held, held.contains("hold"))
        assertTrue(held, held.contains("errorCode=2002/retryable"))

        val format = fallbackLogLine(
            cameraId = "cam-1",
            from = StreamTier.SUB,
            to = StreamTier.MOBILE,
            steppedDown = true,
            everReady = true,
            errorCode = 4005,
            failureDetail = null,
            preFirstFrameFailures = 0,
        )
        assertTrue(format, format.contains("errorCode=4005/format"))

        // The deterministic signature is called out by name, so a logcat capture
        // says WHY without anyone having to know the code mapping.
        val ap = fallbackLogLine(
            cameraId = "cam-1",
            from = StreamTier.MAIN,
            to = StreamTier.SUB,
            steppedDown = true,
            everReady = false,
            errorCode = 2000,
            failureDetail = "IOException <- UnsupportedOperationException: " +
                "need to implement processAggregationPacket",
            preFirstFrameFailures = 1,
        )
        assertTrue(ap, ap.contains("processAggregationPacket"))
        assertTrue(ap, ap.contains("(known-unplayable)"))
    }

    @Test
    fun `the attach line names the rung and the ladder`() {
        val line = attachLogLine(
            cameraId = "cam-1",
            surface = "fullscreen",
            tier = StreamTier.SUB,
            chain = listOf(StreamTier.MAIN, StreamTier.SUB, StreamTier.MOBILE),
            failed = setOf(StreamTier.MAIN),
        )
        assertTrue(line, line.contains("fullscreen attach rung=SUB"))
        assertTrue(line, line.contains("chain=[MAIN,SUB,MOBILE]"))
        assertTrue(line, line.contains("skipped=[MAIN]"))
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
