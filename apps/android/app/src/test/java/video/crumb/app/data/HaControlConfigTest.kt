// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Per-link control config (migration 0075, issue #440): the Android client must
 * decode `require_confirm` + `allowed_actions` defensively (an older server that
 * omits them decodes exactly as today via the nullable + default fields) and
 * derive the offered action set from `allowed_actions` when present.
 */
class HaControlConfigTest {

    // Mirror the production decoder: tolerant of unknown keys.
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `an older server payload without the fields defaults to today behavior`() {
        val link = json.decodeFromString(
            HaLinkDto.serializer(),
            """{"id":"l1","entity_id":"light.kitchen","role":"actuator","sort_order":0}""",
        )
        assertFalse(link.requireConfirm)
        assertNull(link.allowedActions)
        // Null allowed_actions ⇒ every action permitted; default control set.
        assertTrue(link.actionAllowed("turn_on"))
        // Simple domain collapses to the single primary tap (Toggle), unchanged.
        assertEquals(listOf("toggle"), link.controlActions().map { it.verb })
    }

    @Test
    fun `present fields parse and restrict the offered actions`() {
        val link = json.decodeFromString(
            HaLinkDto.serializer(),
            """{"id":"l2","entity_id":"light.kitchen","role":"actuator","sort_order":0,
                "require_confirm":true,"allowed_actions":["turn_on"]}""",
        )
        assertTrue(link.requireConfirm)
        assertEquals(listOf("turn_on"), link.allowedActions)
        assertTrue(link.actionAllowed("turn_on"))
        assertFalse(link.actionAllowed("turn_off"))
        // Restricted ⇒ present ONLY the permitted verbs (from the full domain set).
        assertEquals(listOf("turn_on"), link.controlActions().map { it.verb })
    }

    @Test
    fun `a light may be restricted to exactly toggle, a default-card superset verb`() {
        val link = json.decodeFromString(
            HaLinkDto.serializer(),
            """{"id":"l3","entity_id":"light.kitchen","role":"actuator","sort_order":0,
                "allowed_actions":["toggle"]}""",
        )
        assertEquals(listOf("toggle"), link.controlActions().map { it.verb })
    }

    @Test
    fun `a cover restricted to open and close drops stop`() {
        val link = json.decodeFromString(
            HaLinkDto.serializer(),
            """{"id":"l4","entity_id":"cover.garage","role":"actuator","sort_order":0,
                "allowed_actions":["open_cover","close_cover"]}""",
        )
        assertEquals(
            listOf("open_cover", "close_cover"),
            link.controlActions().map { it.verb },
        )
    }
}
