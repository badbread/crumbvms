// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import video.crumb.app.ui.Time

/** Default lifetime of a cached `/play/` resolve. */
const val PLAY_RESOLVE_TTL_MS = 60_000L

/** Default maximum number of cached segments (all cameras together). */
const val PLAY_RESOLVE_CAPACITY = 256

/**
 * Short-lived cache of `GET /play/{camera_id}` answers, used by
 * [CrumbRepository.resolveSegment].
 *
 * A scrub release, a re-seek and the next-segment prefetch mostly land inside
 * a segment resolved moments earlier, and a segment's identity and
 * `[start, end)` window never change once indexed, so the answer can come from
 * memory instead of another round trip.
 *
 * What is cached is the [ResolvedSegment], whose `url` is the API-relative
 * `/segments/{id}` path with NO media token: the scoped `?token=` claim is
 * added afterwards by `MediaUrls.scopedUrl` from [MediaTokenCache], which
 * refreshes ahead of expiry. A cached resolve therefore never yields an
 * expired media URL; the 60 s TTL (far inside the server's 15 min media-token
 * lifetime anyway) only bounds how long a segment that retention deleted
 * meanwhile can still be answered from memory, and the player-error path
 * invalidates the camera so its recovery always asks the server.
 *
 * Only positive answers are cached: a 404 is never remembered, so footage
 * recorded after a miss shows up on the next resolve. Entries are keyed by
 * [scope] (server + session token, so one principal's grants never answer
 * another's resolve), camera and stream; any instant inside a cached
 * segment's window hits. Thread-safe (all methods synchronized).
 */
class PlayResolveCache(
    private val ttlMs: Long = PLAY_RESOLVE_TTL_MS,
    private val capacity: Int = PLAY_RESOLVE_CAPACITY,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    private class Entry(
        val scope: String,
        val stream: String,
        val seg: ResolvedSegment,
        val startMs: Long,
        val endMs: Long,
        val storedAtMs: Long,
    )

    // Access-ordered: iteration starts at the least recently used entry.
    private val entries = LinkedHashMap<String, Entry>(16, 0.75f, true)

    @get:Synchronized
    val size: Int get() = entries.size

    @Synchronized
    fun lookup(scope: String, cameraId: String, stream: String, tsMs: Long): ResolvedSegment? {
        val now = nowMs()
        entries.values.removeAll { now - it.storedAtMs >= ttlMs }
        val key = entries.entries.firstOrNull { (_, e) ->
            e.scope == scope && e.stream == stream && e.seg.cameraId == cameraId &&
                tsMs >= e.startMs && tsMs < e.endMs
        }?.key ?: return null
        // get() refreshes recency (not the TTL: an entry still expires ttlMs
        // after it was fetched, however often it is read).
        return entries[key]?.seg
    }

    /**
     * Remember [seg] as the answer for [tsMs]. Skipped unless the segment
     * really covers [tsMs] and has a sane window, so a malformed or
     * non-covering answer can never be served for later lookups.
     */
    @Synchronized
    fun put(scope: String, stream: String, seg: ResolvedSegment, tsMs: Long) {
        val startMs = Time.parseToMillis(seg.start)
        val endMs = Time.parseToMillis(seg.end)
        if (startMs <= 0L || endMs <= startMs || tsMs < startMs || tsMs >= endMs) return
        val key = "$scope|${seg.cameraId}|$stream|${seg.segmentId}"
        entries.remove(key)
        entries[key] = Entry(scope, stream, seg, startMs, endMs, nowMs())
        while (entries.size > capacity) {
            entries.remove(entries.keys.first())
        }
    }

    /** Forget every cached resolve, or only [cameraId]'s. */
    @Synchronized
    fun invalidate(cameraId: String? = null) {
        if (cameraId == null) entries.clear()
        else entries.values.removeAll { it.seg.cameraId == cameraId }
    }
}
