// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Time helpers shared across features. The API speaks RFC-3339 UTC strings;
 * the UI displays in the device's local zone.
 */
object Time {
    private val clockFmt = DateTimeFormatter.ofPattern("HH:mm:ss", Locale.US)
    private val clockShortFmt = DateTimeFormatter.ofPattern("HH:mm", Locale.US)
    private val dateFmt = DateTimeFormatter.ofPattern("EEE MMM d", Locale.US)
    private val dateTimeFmt = DateTimeFormatter.ofPattern("MMM d, HH:mm:ss", Locale.US)

    val zone: ZoneId get() = ZoneId.systemDefault()

    /** RFC-3339 string for an instant (UTC, suitable for API query params). */
    fun iso(instant: Instant): String = instant.toString()

    /** Parse an RFC-3339 string (handles fractional seconds + 'Z'). */
    fun parse(iso: String): Instant = Instant.parse(iso)

    fun parseToMillis(iso: String): Long = Instant.parse(iso).toEpochMilli()

    fun clock(instant: Instant): String = clockFmt.format(instant.atZone(zone))
    fun clock(iso: String): String = clock(parse(iso))
    fun clockShort(instant: Instant): String = clockShortFmt.format(instant.atZone(zone))
    fun date(instant: Instant): String = dateFmt.format(instant.atZone(zone))
    fun dateTime(instant: Instant): String = dateTimeFmt.format(instant.atZone(zone))
    fun dateTime(iso: String): String = dateTime(parse(iso))
}
