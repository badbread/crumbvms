// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Regression guard for the [combineIntensityMax] merge math behind
 * [CrumbRepository.timelineIntensityCombined] (#599). This is the part of the
 * batched-intensity rewrite most likely to regress silently — a wrong merge
 * would show a flat or misleading combined motion strip on the multi-camera
 * playback wall without throwing anything.
 */
class CombineIntensityMaxTest {

    @Test
    fun `takes the per-bucket max across cameras`() {
        val perCamera = listOf(
            listOf(0.1f, 0.9f, 0.0f),
            listOf(0.5f, 0.2f, 0.0f),
            listOf(0.0f, 0.0f, 0.3f),
        )
        assertEquals(listOf(0.5f, 0.9f, 0.3f), combineIntensityMax(perCamera, buckets = 3))
    }

    @Test
    fun `no cameras yields all-zero buckets`() {
        assertEquals(listOf(0.0f, 0.0f, 0.0f, 0.0f), combineIntensityMax(emptyList(), buckets = 4))
    }

    @Test
    fun `a camera array shorter than buckets only contributes over its own length`() {
        // Mirrors a fallback entry from an error-tolerant per-camera fetch that
        // returned fewer buckets than requested.
        val perCamera = listOf(
            listOf(0.7f), // short — e.g. a degraded/partial response
            listOf(0.1f, 0.1f, 0.1f),
        )
        assertEquals(listOf(0.7f, 0.1f, 0.1f), combineIntensityMax(perCamera, buckets = 3))
    }

    @Test
    fun `a camera array longer than buckets is truncated to buckets`() {
        val perCamera = listOf(listOf(0.2f, 0.4f, 0.6f, 0.8f))
        assertEquals(listOf(0.2f, 0.4f), combineIntensityMax(perCamera, buckets = 2))
    }
}
