// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pick order for the low-res (sub) live stream — [subStreamUrl].
 *
 * Android is the ONLY client that prefers the server's video-only `_subv`
 * restream. Media3's RTSP client requires an `fmtp` attribute on every track it
 * builds and throws `IllegalArgumentException: missing attribute fmtp` without
 * one, so cameras that publish H264 with no out-of-band parameter sets
 * reconnect-loop forever on the plain sub (#483); `_subv` is that stream run
 * through an ffmpeg copy, which restores the fmtp.
 *
 * The fallback matters just as much as the preference: go2rtc spawns the `_subv`
 * remux ffmpeg lazily per consumer, so the server publishes it as a SEPARATE
 * field and leaves `rtsp_sub_url` pointing at the always-warm raw sub for
 * desktop/iOS. A server that predates the field, or a camera whose go2rtc
 * streams the server does not manage (Frigate-served / legacy rows), simply has
 * no `_subv` — and this client must behave exactly as it did before.
 */
class SubStreamUrlTest {

    /** Mirrors `Network.json` — the decoder Retrofit actually uses. */
    private val json = Json { ignoreUnknownKeys = true }

    private fun streams(sub: String?, subv: String?) = LiveStreamsResponse(
        cameraId = "8f14e45f-ceea-467a-9f3a-8f14e45fceea",
        rtspMainUrl = "rtsp://u:p@host:18554/famroom",
        rtspSubUrl = sub,
        rtspSubvUrl = subv,
    )

    @Test
    fun `prefers subv when the server offers one`() {
        val s = streams(
            sub = "rtsp://u:p@host:18554/famroom_sub",
            subv = "rtsp://u:p@host:18554/famroom_subv",
        )
        assertEquals("rtsp://u:p@host:18554/famroom_subv", s.subStreamUrl())
    }

    @Test
    fun `falls back to the raw sub when there is no subv`() {
        // Unmanaged camera (Frigate-served / legacy row): the server publishes a
        // sub but no `_subv`, because reconcile never registered one.
        val s = streams(sub = "rtsp://frigate:8554/famroom_sub", subv = null)
        assertEquals("rtsp://frigate:8554/famroom_sub", s.subStreamUrl())
    }

    @Test
    fun `null when the camera has no sub stream at all`() {
        // Caller falls back to the main stream itself; this must not invent a URL.
        assertNull(streams(sub = null, subv = null).subStreamUrl())
    }

    @Test
    fun `subv alone is still used`() {
        // Defensive: the two fields are independent on the wire.
        val s = streams(sub = null, subv = "rtsp://u:p@host:18554/famroom_subv")
        assertEquals("rtsp://u:p@host:18554/famroom_subv", s.subStreamUrl())
    }

    @Test
    fun `an older server without the field decodes and behaves exactly as before`() {
        // Wire payload from a server predating `rtsp_subv_url`. The field is
        // nullable-with-default, so decoding must succeed and the pick order must
        // land on the raw sub — no behaviour change against an old server.
        val body = """
            {
              "camera_id": "8f14e45f-ceea-467a-9f3a-8f14e45fceea",
              "rtsp_main_url": "rtsp://u:p@host:18554/famroom",
              "rtsp_sub_url": "rtsp://u:p@host:18554/famroom_sub"
            }
        """.trimIndent()
        val decoded = json.decodeFromString(LiveStreamsResponse.serializer(), body)
        assertNull(decoded.rtspSubvUrl)
        assertEquals("rtsp://u:p@host:18554/famroom_sub", decoded.subStreamUrl())
    }

    @Test
    fun `decodes the new field when the server sends it`() {
        val body = """
            {
              "camera_id": "8f14e45f-ceea-467a-9f3a-8f14e45fceea",
              "rtsp_main_url": "rtsp://u:p@host:18554/famroom",
              "rtsp_sub_url": "rtsp://u:p@host:18554/famroom_sub",
              "rtsp_subv_url": "rtsp://u:p@host:18554/famroom_subv"
            }
        """.trimIndent()
        val decoded = json.decodeFromString(LiveStreamsResponse.serializer(), body)
        assertEquals("rtsp://u:p@host:18554/famroom_subv", decoded.subStreamUrl())
        // The raw sub is still there for anything that wants the warm producer.
        assertEquals("rtsp://u:p@host:18554/famroom_sub", decoded.rtspSubUrl)
    }
}
