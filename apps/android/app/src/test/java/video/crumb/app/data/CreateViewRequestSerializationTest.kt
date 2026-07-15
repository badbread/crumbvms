// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression guard for #159 ("Couldn't save view: Server error (422)").
 *
 * Retrofit serializes request bodies with `encodeDefaults = false` (see
 * [video.crumb.app.data.Network]). With that setting, a property left at its
 * declared Kotlin default is dropped from the wire JSON. [CreateViewRequest.layout]
 * previously carried a `= "auto"` default, so it never reached the server — whose
 * own `CreateViewRequest.layout` is a required field (no serde default) — and the
 * body was rejected with HTTP 422. Removing the Kotlin default forces `layout`
 * onto the wire; this test fails if it ever creeps back.
 */
class CreateViewRequestSerializationTest {

    // Mirror the production encoder's relevant setting exactly.
    private val json = Json { encodeDefaults = false; explicitNulls = false }

    @Test
    fun `POST views body always includes layout`() {
        val body = CameraView(id = "", name = "Perimeter", cameraIds = listOf("cam-a", "cam-b"))
            .toCreateRequest()
        val encoded = json.encodeToString(CreateViewRequest.serializer(), body)

        assertTrue(
            "layout must be present on the wire — the server requires it (#159): $encoded",
            encoded.contains("\"layout\""),
        )
        assertTrue("name must be present: $encoded", encoded.contains("\"name\""))
        assertTrue("slots must be present: $encoded", encoded.contains("\"slots\""))
    }
}
