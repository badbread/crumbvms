// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import org.junit.Assert.assertEquals
import org.junit.Test
import video.crumb.app.data.FilmstripFrame

/**
 * The pure prefetch plan behind the scrub overlay: which filmstrip frames the
 * screen warms into Coil's cache around the one under the finger. Direction-
 * aware (leads the finger), one behind, nearest first, never the shown frame,
 * and clipped at the list edges.
 */
class ScrubPrefetchPlanTest {

    private val frames = (0 until 10).map { i ->
        FilmstripFrame(ts = "2026-01-01T00:00:${"%02d".format(i * 4)}Z", url = "/f/$i")
    }

    private fun urls(plan: List<FilmstripFrame>) = plan.map { it.url }

    @Test
    fun forwardLeadsTheFingerNearestFirst() {
        assertEquals(
            listOf("/f/5", "/f/3", "/f/6", "/f/7"),
            urls(scrubPrefetchPlan(frames, nearestIdx = 4, forward = true)),
        )
    }

    @Test
    fun backwardMirrorsThePlan() {
        assertEquals(
            listOf("/f/3", "/f/5", "/f/2", "/f/1"),
            urls(scrubPrefetchPlan(frames, nearestIdx = 4, forward = false)),
        )
    }

    @Test
    fun clipsAtTheListEdges() {
        assertEquals(
            listOf("/f/1", "/f/2", "/f/3"),
            urls(scrubPrefetchPlan(frames, nearestIdx = 0, forward = true)),
        )
        assertEquals(
            listOf("/f/8"),
            urls(scrubPrefetchPlan(frames, nearestIdx = 9, forward = true)),
        )
    }

    @Test
    fun invalidIndexOrEmptyListPlansNothing() {
        assertEquals(emptyList<String>(), urls(scrubPrefetchPlan(frames, nearestIdx = -1, forward = true)))
        assertEquals(emptyList<String>(), urls(scrubPrefetchPlan(emptyList(), nearestIdx = 0, forward = true)))
    }
}
