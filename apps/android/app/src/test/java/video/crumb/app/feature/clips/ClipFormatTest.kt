// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.clips

import org.junit.Assert.assertEquals
import org.junit.Test
import video.crumb.app.data.ClipDescriptor

class ClipFormatTest {
    private fun clip(kind: String, label: String = "") = ClipDescriptor(
        id = "x", cameraId = "c", kind = kind, label = label,
        startTs = "2026-10-30T00:00:00Z", endTs = "2026-10-30T00:00:10Z",
        thumbnailUrl = "", clipUrl = "",
    )

    @Test
    fun `license plate label is humanised with US spelling`() {
        assertEquals("License plate", ClipFormat.humanizeLabel("license_plate"))
        assertEquals("License plate", ClipFormat.humanizeLabel("License_plate"))
    }

    @Test
    fun `simple labels are only capitalised`() {
        assertEquals("Car", ClipFormat.humanizeLabel("car"))
        assertEquals("Person", ClipFormat.humanizeLabel("person"))
    }

    @Test
    fun `blank label falls back to Detection`() {
        assertEquals("Detection", ClipFormat.humanizeLabel(""))
        assertEquals("Detection", ClipFormat.humanizeLabel("  _ "))
    }

    @Test
    fun `motion clips are always Motion`() {
        assertEquals("Motion", ClipFormat.kindLabel(clip("motion", "whatever")))
        assertEquals("License plate", ClipFormat.kindLabel(clip("detection", "license_plate")))
    }

    @Test
    fun `duration is m ss`() {
        assertEquals("0:28", ClipFormat.duration(28_000))
        assertEquals("0:04", ClipFormat.duration(4_900))
        assertEquals("1:05", ClipFormat.duration(65_000))
        assertEquals("12:00", ClipFormat.duration(720_000))
    }

    @Test
    fun `long and empty durations`() {
        assertEquals("1:01:01", ClipFormat.duration(3_661_000))
        assertEquals("0:00", ClipFormat.duration(0))
        assertEquals("0:00", ClipFormat.duration(-5))
    }
}
