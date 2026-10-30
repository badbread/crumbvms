// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.util.TimeZone

class JumpToDateTimeDialogTest {

    private val la = TimeZone.getTimeZone("America/Los_Angeles")
    private val laId = ZoneId.of("America/Los_Angeles")

    private fun epoch(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int = 0): Long =
        ZonedDateTime.of(y, mo, d, h, mi, s, 0, laId).toInstant().toEpochMilli()

    private fun utcMidnight(y: Int, mo: Int, d: Int): Long =
        LocalDate.of(y, mo, d).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()

    @Test
    fun `9 PM local seeds the picker with the local date, not the UTC date`() {
        // 2026-10-28 21:00 PDT is 2026-10-29 04:00Z; the picker must show Oct 28.
        val ms = epoch(2026, 10, 28, 21, 0)
        assertEquals(utcMidnight(2026, 10, 28), localDateAsPickerMillis(ms, la))
    }

    @Test
    fun `round trip at 9 PM local keeps the same day and time`() {
        val ms = epoch(2026, 10, 28, 21, 0, 17)
        val pickerMs = localDateAsPickerMillis(ms, la)
        val back = combinePickerDateWithLocalTime(pickerMs, hour = 21, minute = 0, second = 17, millis = 0, zone = la)
        assertEquals(ms, back)
    }

    @Test
    fun `picking another day at 9 PM local lands on that local day`() {
        val back = combinePickerDateWithLocalTime(utcMidnight(2026, 10, 30), 21, 0, 0, 0, la)
        assertEquals(epoch(2026, 10, 30, 21, 0), back)
    }

    @Test
    fun `morning time in a UTC-plus zone seeds the local date`() {
        val tokyo = TimeZone.getTimeZone("Asia/Tokyo")
        // 2026-10-29 07:00 JST is 2026-10-28 22:00Z.
        val ms = ZonedDateTime.of(2026, 10, 29, 7, 0, 0, 0, ZoneId.of("Asia/Tokyo")).toInstant().toEpochMilli()
        assertEquals(utcMidnight(2026, 10, 29), localDateAsPickerMillis(ms, tokyo))
    }
}
