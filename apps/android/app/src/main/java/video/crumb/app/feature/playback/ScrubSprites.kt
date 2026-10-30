// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

/**
 * Client side of the per-segment scrub sprite strips
 * (`GET /filmstrip/{camera}/sprite?ts=`, services/api/src/scrub_sprite.rs).
 *
 * A sprite is ONE small JPEG per recorded segment: [SpriteLayout.tiles] tiles
 * in a row, tile i showing the segment at `start + i * interval` (1 s). One
 * request gives the scrub overlay 1 s granularity across a whole 4 s segment,
 * where the per-frame filmstrip snaps to a 4 s grid. Sprites exist only when
 * the server's background pre-generation is on and has caught up; a 404 means
 * "not generated" and the overlay keeps using the filmstrip frame.
 *
 * Pure (no Android types) so the layout + cache rules are JVM-unit-testable;
 * the repository does the HTTP + bitmap decode and the screen crops.
 */
data class SpriteLayout(
    val startMs: Long,
    val endMs: Long,
    val intervalMs: Long,
    val tiles: Int,
    val columns: Int,
) {
    val rows: Int get() = (tiles + columns - 1) / columns

    fun covers(ms: Long): Boolean = ms in startMs until endMs

    /** Tile showing [ms], clamped into the strip. */
    fun tileFor(ms: Long): Int = ((ms - startMs) / intervalMs).toInt().coerceIn(0, tiles - 1)

    /** Source rectangle `(x, y, w, h)` of [index] in an [imageWidth] x [imageHeight] strip. */
    fun tileRect(index: Int, imageWidth: Int, imageHeight: Int): IntArray {
        val w = imageWidth / columns
        val h = imageHeight / rows
        return intArrayOf((index % columns) * w, (index / columns) * h, w, h)
    }

    companion object {
        /**
         * Parse the `X-Crumb-Sprite-*` response headers (names case-insensitive).
         * Null when anything is missing or nonsensical, so a malformed response
         * is treated as a miss rather than drawing the wrong part of a strip.
         */
        fun fromHeaders(headers: Map<String, String>): SpriteLayout? {
            val h = headers.mapKeys { it.key.lowercase() }
            fun read(k: String) = h["x-crumb-sprite-$k"]?.trim()?.toLongOrNull()
            val start = read("start-ms") ?: return null
            val end = read("end-ms") ?: return null
            val interval = read("interval-ms") ?: return null
            val tiles = read("tiles")?.toInt() ?: return null
            val columns = read("columns")?.toInt() ?: tiles
            if (end <= start || interval <= 0 || tiles <= 0 || columns <= 0) return null
            return SpriteLayout(start, end, interval, tiles, columns)
        }
    }
}

/** A decoded sprite: its layout plus the client's image payload ([T] = Bitmap in the app). */
data class ScrubSprite<T>(val layout: SpriteLayout, val image: T)

/** What the overlay draws: one tile of a sprite. */
data class SpriteTile<T>(val sprite: ScrubSprite<T>, val index: Int)

/** How long "no sprite here" is remembered before asking again. */
const val SPRITE_MISS_TTL_MS = 15_000L

/** Cell width negative results are keyed by (a 404 doesn't say which segment). */
const val SPRITE_MISS_CELL_MS = 4_000L

/** Sprites kept per screen (~10-20 KiB each as JPEG; a few hundred KiB decoded). */
const val SPRITE_CACHE_CAPACITY = 48

/**
 * Small LRU of sprites for ONE camera (the playback screen shows one at a
 * time; [clear] it on a camera switch), plus TTL'd negative results.
 * Not thread-safe: use from the main thread (the ViewModel's scope).
 */
class ScrubSpriteCache<T>(
    private val capacity: Int = SPRITE_CACHE_CAPACITY,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val sprites = LinkedHashMap<Long, ScrubSprite<T>>(16, 0.75f, true)
    private val misses = HashMap<Long, Long>()

    val size: Int get() = sprites.size

    private fun cell(ms: Long) = Math.floorDiv(ms, SPRITE_MISS_CELL_MS)

    /** The tile for [ms] if a cached sprite covers it (refreshes its LRU position). */
    fun lookup(ms: Long): SpriteTile<T>? {
        val s = sprites.values.firstOrNull { it.layout.covers(ms) } ?: return null
        sprites[s.layout.startMs] // touch for access order
        return SpriteTile(s, s.layout.tileFor(ms))
    }

    fun isKnownMiss(ms: Long): Boolean {
        val at = misses[cell(ms)] ?: return false
        if (now() - at > SPRITE_MISS_TTL_MS) {
            misses.remove(cell(ms))
            return false
        }
        return true
    }

    fun has(ms: Long): Boolean = sprites.values.any { it.layout.covers(ms) } || isKnownMiss(ms)

    /** Record a fetch made at [requestedMs]: a sprite, or null for "none there". */
    fun put(requestedMs: Long, sprite: ScrubSprite<T>?) {
        if (sprite == null) {
            misses[cell(requestedMs)] = now()
            return
        }
        misses.remove(cell(requestedMs))
        sprites[sprite.layout.startMs] = sprite
        while (sprites.size > capacity) {
            sprites.remove(sprites.keys.first())
        }
    }

    fun clear() {
        sprites.clear()
        misses.clear()
    }

    /**
     * Instants to request so the segments the finger is heading into are cached
     * before it gets there: just past [current] in the direction of travel, then
     * one more segment of the same length. Already-known instants are skipped.
     */
    fun probesAhead(current: SpriteLayout, forward: Boolean, count: Int = 2): List<Long> {
        val span = current.endMs - current.startMs
        return (0 until count)
            .map { i -> if (forward) current.endMs + i * span else current.startMs - 1 - i * span }
            .filterNot { has(it) }
    }
}
