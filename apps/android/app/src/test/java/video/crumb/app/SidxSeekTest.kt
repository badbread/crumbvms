// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app

import androidx.media3.extractor.Extractor
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.mp4.FragmentedMp4Extractor
import androidx.media3.test.utils.FakeExtractorInput
import androidx.media3.test.utils.FakeExtractorOutput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Gate 3 (objective, headless) for the Android recorded-playback seek fix.
 *
 * The bug: Crumb records FRAGMENTED mp4 segments with no `sidx` box. Media3's
 * [FragmentedMp4Extractor] builds a seekable [SeekMap] ONLY from an `sidx`, so
 * without one it reports the stream unseekable and every `seekTo` collapses to
 * position 0 (observed on-device as `onPositionDiscontinuity reason=2 -> 0`).
 *
 * The fix under test: adding `+global_sidx` to the recorder mux (proven a
 * `-c copy`, crash-safe, ~176-byte change) makes the SAME footage seekable.
 *
 * This drives the real Media3 extractor over two small fragmented-mp4 fixtures
 * built with the recorder's EXACT mux flags — one with `+global_sidx`, one
 * without (see `app/src/test/resources/seek/`, 4 s / 1 s-GOP / 4 moof each,
 * regenerate with the ffmpeg command in this test's PR) — and asserts the
 * seekability flip: deterministic, no device, no eyeballing. The on-device
 * proof over real HEVC footage is recorded in docs/DECISIONS.md (2026-07-16,
 * "Android recorded-playback seeking"); these tiny synthetic fixtures exercise
 * the same container mechanism (the `sidx` box is codec-independent) while
 * staying small enough to commit.
 */
@RunWith(AndroidJUnit4::class)
class SidxSeekTest {

    private fun seekMapFor(resource: String): SeekMap? {
        val bytes = requireNotNull(javaClass.classLoader?.getResourceAsStream(resource)) {
            "missing test fixture $resource"
        }.readBytes()
        val extractor = FragmentedMp4Extractor()
        val output = FakeExtractorOutput()
        extractor.init(output)
        val input = FakeExtractorInput.Builder().setData(bytes).build()
        val positionHolder = PositionHolder()
        var result = Extractor.RESULT_CONTINUE
        while (result != Extractor.RESULT_END_OF_INPUT) {
            result = extractor.read(input, positionHolder)
            if (result == Extractor.RESULT_SEEK) {
                input.setPosition(positionHolder.position.toInt())
            }
        }
        return output.seekMap
    }

    @Test
    fun sidxSegment_isSeekable_andSeeksToDistinctFrames() {
        val sm = seekMapFor("seek/sidx.mp4")
        assertNotNull("a +global_sidx segment must yield a SeekMap", sm)
        assertTrue("a +global_sidx segment must report seekable", sm!!.isSeekable)

        // Seeking to ~2s must land on a sync sample NEAR 2s — NOT collapse to 0.
        val at2s = sm.getSeekPoints(2_000_000L).first.timeUs
        assertTrue(
            "seek to 2s landed at ${at2s}us; must be a distinct mid-segment frame (> 0.5s)",
            at2s > 500_000L,
        )
        // A later seek must land on a LATER point — proves per-keyframe seeking,
        // not everything snapping to one place.
        val at3s = sm.getSeekPoints(3_000_000L).first.timeUs
        assertTrue(
            "seek to 3s (${at3s}us) must land later than seek to 2s (${at2s}us)",
            at3s > at2s,
        )
    }

    @Test
    fun noSidxSegment_isNotSeekable_reproducesTheBug() {
        val sm = seekMapFor("seek/nosidx.mp4")
        // The bug: no sidx -> no usable SeekMap -> every seek collapses to 0.
        val seekable = sm != null && sm.isSeekable
        assertTrue(
            "a fragmented segment WITHOUT sidx must NOT be seekable (this is the bug)",
            !seekable,
        )
    }
}
