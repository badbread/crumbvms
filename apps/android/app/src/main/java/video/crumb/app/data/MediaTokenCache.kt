// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import retrofit2.HttpException
import java.time.Instant

/**
 * Per-camera cache of short-lived **scoped media tokens** (`GET /media-token`),
 * fed to [MediaUrls] so per-camera media URLs (segments, filmstrip frames,
 * camera stills, clip thumbnails/video) carry a ~15 min single-camera token
 * instead of the full (up to 10-year) login JWT.
 *
 * Concurrency model:
 * - One cached [CachedToken] per camera id, read/written under [mutex].
 * - At most one in-flight network fetch per camera at a time: a concurrent
 *   caller for the SAME camera awaits the same [Deferred] rather than firing a
 *   second `GET /media-token` (dedupe).
 * - [freshToken] refreshes proactively when the cached token is missing or
 *   expiring within [REFRESH_SKEW_MS] — comfortably before the server's ~15 min
 *   validity window lapses, so a slow caller never hands out a token that
 *   expires before the media request lands.
 *
 * On a genuine fetch failure this throws (propagating [HttpException] for a
 * 401 so callers can route into the app's existing logout/re-auth path — see
 * [CrumbRepository.mediaToken]). It deliberately never falls back to
 * embedding the full login JWT.
 */
class MediaTokenCache(private val api: CrumbApi) {

    private data class CachedToken(val token: String, val expiresAtEpochMs: Long)

    private val mutex = Mutex()
    private val cached = HashMap<String, CachedToken>()
    private val inFlight = HashMap<String, Deferred<String>>()

    /**
     * A scoped media token for [cameraId], fetching a fresh one if the cached
     * value is missing or within [REFRESH_SKEW_MS] of expiring. Concurrent
     * callers for the same camera share one in-flight fetch.
     */
    suspend fun freshToken(cameraId: String): String {
        // Fast path: a still-fresh cached token, no lock contention beyond the read.
        mutex.withLock {
            val hit = cached[cameraId]
            if (hit != null && !isExpiringSoon(hit.expiresAtEpochMs)) return hit.token
        }

        // Join an in-flight fetch for this camera, or start a new one. The whole
        // check-and-start is done under the lock so two concurrent callers for
        // the same camera can never both kick off a fetch — `created` is
        // non-null for EXACTLY ONE caller per fetch, so only that caller invokes
        // [fetchInto]; every other caller (including callers that arrive after
        // the fetch has started) just awaits the shared [Deferred] below.
        var created: CompletableDeferred<String>? = null
        val deferred: Deferred<String> = mutex.withLock {
            inFlight[cameraId] ?: CompletableDeferred<String>().also {
                inFlight[cameraId] = it
                created = it
            }
        }

        created?.let { fetchInto(cameraId, it) }
        return deferred.await()
    }

    /** Performs the network call and completes [target], clearing [inFlight] either way. */
    private suspend fun fetchInto(cameraId: String, target: CompletableDeferred<String>) {
        try {
            val resp = api.mediaToken(cameraId)
            val expiresAtMs = runCatching { Instant.parse(resp.expiresAt).toEpochMilli() }
                .getOrDefault(System.currentTimeMillis() + DEFAULT_TTL_MS)
            mutex.withLock {
                cached[cameraId] = CachedToken(resp.token, expiresAtMs)
                inFlight.remove(cameraId)
            }
            target.complete(resp.token)
        } catch (t: Throwable) {
            mutex.withLock { inFlight.remove(cameraId) }
            target.completeExceptionally(t)
        }
    }

    /** Drop all cached/in-flight state (call on logout / server change). */
    suspend fun clear() {
        mutex.withLock {
            cached.clear()
            inFlight.clear()
        }
    }

    private fun isExpiringSoon(expiresAtEpochMs: Long): Boolean =
        expiresAtEpochMs - System.currentTimeMillis() <= REFRESH_SKEW_MS

    private companion object {
        /** Refresh a cached token once it's within this long of expiring. */
        const val REFRESH_SKEW_MS = 10_000L

        /** Fallback assumed lifetime if `expires_at` fails to parse — matches the
         *  server's documented ~15 min scoped-token validity. */
        const val DEFAULT_TTL_MS = 60_000L
    }
}

/** True when this failure is specifically an HTTP 401 (the full login JWT used
 *  to mint a scoped token was rejected — expired/revoked session). */
fun Throwable.isUnauthorized(): Boolean = this is HttpException && code() == 401
