// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Value-control descriptor decode + gating (#442, Slice 1: `set_brightness`/
 * `set_position`/`set_speed`). The Android client must decode the optional
 * `control` object on a `GET /ha/states` entry defensively (an older server
 * that omits it decodes exactly as today via the nullable default — no
 * slider), drive min/max/step/unit FROM the descriptor rather than hardcoding
 * 0..100, and gate the slider on `allowed_actions` the same way the existing
 * action pills do (migration 0075). Also covers the wire shape of
 * [HaActionRequest.value]: present only for a value action, per
 * `Network.kt`'s `explicitNulls = false`.
 */
class HaControlDescriptorTest {

    // Mirror the production decoder: tolerant of unknown keys.
    private val json = Json { ignoreUnknownKeys = true }

    // Mirror the production encoder (Network.kt): omit null fields entirely
    // rather than sending `"value":null`.
    private val wireJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun `a states entry without control decodes to no slider (older server)`() {
        val st = json.decodeFromString(
            HaEntityState.serializer(),
            """{"entity_id":"light.kitchen","state":"on"}""",
        )
        assertNull(st.control)
    }

    @Test
    fun `a dimmable light's control descriptor decodes with server-driven bounds`() {
        val st = json.decodeFromString(
            HaEntityState.serializer(),
            """{"entity_id":"light.kitchen","state":"on","control":
                {"action":"set_brightness","kind":"percent","value":62,"min":0,"max":100,"step":1,"unit":null}}""",
        )
        val c = st.control!!
        assertEquals("set_brightness", c.action)
        assertEquals("percent", c.kind)
        assertEquals(62.0, c.value, 0.0)
        assertEquals(0.0, c.min, 0.0)
        assertEquals(100.0, c.max, 0.0)
        assertEquals(1.0, c.step, 0.0)
        assertNull(c.unit)
    }

    @Test
    fun `a fan's control descriptor may carry a coarser step than 1`() {
        val st = json.decodeFromString(
            HaEntityState.serializer(),
            """{"entity_id":"fan.bedroom","state":"on","control":
                {"action":"set_speed","kind":"percent","value":50,"min":0,"max":100,"step":25,"unit":null}}""",
        )
        assertEquals(25.0, st.control!!.step, 0.0)
    }

    @Test
    fun `an unrestricted link (allowed_actions null) shows the slider whenever a descriptor is present`() {
        val link = json.decodeFromString(
            HaLinkDto.serializer(),
            """{"id":"l1","entity_id":"light.kitchen","role":"actuator","sort_order":0}""",
        )
        val control = HaControlDescriptor("set_brightness", "percent", 40.0, 0.0, 100.0, 1.0, null)
        assertTrue(link.showsSlider(control))
    }

    @Test
    fun `a link restricted away from the value word hides the slider`() {
        val link = json.decodeFromString(
            HaLinkDto.serializer(),
            """{"id":"l2","entity_id":"light.kitchen","role":"actuator","sort_order":0,
                "allowed_actions":["turn_on","turn_off","toggle"]}""",
        )
        val control = HaControlDescriptor("set_brightness", "percent", 40.0, 0.0, 100.0, 1.0, null)
        assertFalse(link.showsSlider(control))
    }

    @Test
    fun `a link explicitly restricted to include the value word shows the slider`() {
        val link = json.decodeFromString(
            HaLinkDto.serializer(),
            """{"id":"l3","entity_id":"cover.garage","role":"actuator","sort_order":0,
                "allowed_actions":["open_cover","close_cover","set_position"]}""",
        )
        val control = HaControlDescriptor("set_position", "percent", 40.0, 0.0, 100.0, 1.0, null)
        assertTrue(link.showsSlider(control))
    }

    @Test
    fun `no descriptor means no slider regardless of allowed_actions`() {
        val link = json.decodeFromString(
            HaLinkDto.serializer(),
            """{"id":"l4","entity_id":"light.kitchen","role":"actuator","sort_order":0}""",
        )
        assertFalse(link.showsSlider(null))
    }

    @Test
    fun `haValueAction mirrors the server's Slice 1 percent domains`() {
        assertEquals("set_brightness", haValueAction("light"))
        assertEquals("set_position", haValueAction("cover"))
        assertEquals("set_speed", haValueAction("fan"))
        // Slice 2 (climate set_temperature) is deliberately not offered yet.
        assertNull(haValueAction("climate"))
        assertNull(haValueAction("switch"))
        assertNull(haValueAction("lock"))
    }

    @Test
    fun `a discrete action request omits value on the wire`() {
        val body = wireJson.encodeToString(HaActionRequest.serializer(), HaActionRequest("l1", "toggle"))
        assertFalse(body.contains("value"))
    }

    @Test
    fun `a value action request carries its numeric value on the wire`() {
        val body = wireJson.encodeToString(
            HaActionRequest.serializer(),
            HaActionRequest("l1", "set_brightness", 42.0),
        )
        assertTrue(body.contains("\"value\":42.0"))
    }
}
