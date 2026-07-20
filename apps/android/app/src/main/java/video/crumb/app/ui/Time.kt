// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import java.time.Instant
import java.time.OffsetDateTime
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

    /**
     * Parse an RFC-3339 string to epoch-millis, leniently: recorded-span and
     * segment timestamps come straight from the server and are trusted
     * unconditionally by many hot paths (playback resolve, the centered
     * timeline), so a single malformed/oddly-formatted value (e.g. an explicit
     * offset like `+00:00` instead of a `Z` suffix) must not crash composition
     * or a ViewModel coroutine. Falls back to [OffsetDateTime.parse] for
     * offset-style timestamps [Instant.parse] rejects, and to `0L` (epoch) if
     * neither parses.
     */
    fun parseToMillis(iso: String): Long =
        runCatching { Instant.parse(iso).toEpochMilli() }
            .recoverCatching { OffsetDateTime.parse(iso).toInstant().toEpochMilli() }
            .getOrDefault(0L)

    fun clock(instant: Instant): String = clockFmt.format(instant.atZone(zone))
    fun clock(iso: String): String = clock(parse(iso))
    fun clockShort(instant: Instant): String = clockShortFmt.format(instant.atZone(zone))
    fun date(instant: Instant): String = dateFmt.format(instant.atZone(zone))
    fun dateTime(instant: Instant): String = dateTimeFmt.format(instant.atZone(zone))
    fun dateTime(iso: String): String = dateTime(parse(iso))
}
