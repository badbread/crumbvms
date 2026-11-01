// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.clips

import video.crumb.app.data.ClipDescriptor

/**
 * Display helpers for the Clips tab (polish pass C4, C5). Pure so they can be unit
 * tested without Compose.
 */
internal object ClipFormat {
    /**
     * Humanise a raw detection label: underscores become spaces, the first letter is
     * upper case and the rest is left alone ("license_plate" becomes "License plate").
     * A blank label falls back to "Detection".
     */
    fun humanizeLabel(raw: String): String {
        val cleaned = raw.replace('_', ' ').trim().replace(Regex("\\s+"), " ")
        if (cleaned.isEmpty()) return "Detection"
        return cleaned.replaceFirstChar { it.uppercase() }
    }

    /** The kind label shown on a clip card and as the player title. */
    fun kindLabel(c: ClipDescriptor): String =
        if (c.kind == "motion") "Motion" else humanizeLabel(c.label)

    /**
     * Clip duration as m:ss ("0:28", "12:05"); h:mm:ss from one hour up. A zero or
     * negative duration is "0:00".
     */
    fun duration(ms: Long): String {
        val total = if (ms <= 0L) 0L else ms / 1000L
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(total / 60, s)
    }
}
