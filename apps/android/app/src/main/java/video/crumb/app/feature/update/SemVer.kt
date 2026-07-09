// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.update

/**
 * Tiny hand-rolled SemVer 2.0.0 precedence compare for the update-available
 * checker (issue #7). Deliberately not a library dependency (golden rule 6,
 * `AGENTS.md`) — mirrors the server's `services/api/src/updates.rs`
 * `parse_semver`/`is_update_available` exactly: only a plain
 * `MAJOR.MINOR.PATCH` triple of non-negative integers parses; anything else
 * (a `-dev` suffix, a missing part, non-numeric text) is "no signal", not an
 * error (`docs/UPDATE-SYSTEM-PLAN.md` §2.2).
 */
object SemVer {

    /**
     * Parse a plain `MAJOR.MINOR.PATCH` version (exactly three dot-separated
     * non-negative integers). `null` for anything else.
     */
    fun parse(raw: String): Triple<Long, Long, Long>? {
        val parts = raw.trim().split(".")
        if (parts.size != 3) return null
        val major = parts[0].toLongOrNull() ?: return null
        val minor = parts[1].toLongOrNull() ?: return null
        val patch = parts[2].toLongOrNull() ?: return null
        return Triple(major, minor, patch)
    }

    /**
     * Whether [latest] is a strictly newer release than [current] (SemVer
     * 2.0.0 precedence, tuple-lexicographic since neither side carries a
     * pre-release/build suffix once parsed). `null` — not `false` — when
     * either fails to parse, so an unparsable local/dev build (e.g.
     * `"0.0.1-dev"`) never claims an update is or isn't available.
     */
    fun isNewer(current: String, latest: String): Boolean? {
        val cur = parse(current) ?: return null
        val lat = parse(latest) ?: return null
        if (lat.first != cur.first) return lat.first > cur.first
        if (lat.second != cur.second) return lat.second > cur.second
        return lat.third > cur.third
    }
}
