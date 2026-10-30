// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The seeded Export route has to round-trip through Navigation-Compose's URI
 * parsing, so its query string must be built with real percent-encoding (and
 * NOT form-encoding's `+` for a space, which a URI reads as a literal plus).
 */
class RoutesExportTest {

    @Test
    fun `the registered route declares all three optional args`() {
        assertEquals("export?cameraId={cameraId}&startMs={startMs}&endMs={endMs}", Routes.EXPORT)
        assertTrue(Routes.EXPORT.contains("{${Routes.ARG_CAMERA_ID}}"))
        assertTrue(Routes.EXPORT.contains("{${Routes.ARG_START_MS}}"))
        assertTrue(Routes.EXPORT.contains("{${Routes.ARG_END_MS}}"))
    }

    @Test
    fun `an unseeded export route carries empty defaults`() {
        assertEquals("export?cameraId=&startMs=0&endMs=0", Routes.export())
    }

    @Test
    fun `a seeded export route carries the camera and the window`() {
        assertEquals(
            "export?cameraId=front-door&startMs=1700000000000&endMs=1700000060000",
            Routes.export("front-door", 1_700_000_000_000L, 1_700_000_060_000L),
        )
    }

    @Test
    fun `a space in a camera id is percent-encoded, never a plus`() {
        val route = Routes.export("Front Door")
        assertEquals("export?cameraId=Front%20Door&startMs=0&endMs=0", route)
    }

    @Test
    fun `reserved characters in a camera id are escaped`() {
        val route = Routes.export("a/b?c&d=e")
        assertTrue(route.startsWith("export?cameraId="))
        // None of the escaped characters may leak into the query structure: after
        // the camera-id value there must be exactly the two known separators.
        val cameraValue = route.removePrefix("export?cameraId=").substringBefore("&startMs=")
        assertEquals("a%2Fb%3Fc%26d%3De", cameraValue)
        assertEquals(2, route.count { it == '&' })
    }

    @Test
    fun `encodeArg leaves an ordinary uuid untouched`() {
        val uuid = "6f1f8e2a-1c34-4a5f-9a1e-2b7c8d9e0f11"
        assertEquals(uuid, Routes.encodeArg(uuid))
    }
}
