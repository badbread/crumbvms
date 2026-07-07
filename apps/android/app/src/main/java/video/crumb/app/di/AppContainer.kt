// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.di

import android.content.Context
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import video.crumb.app.data.MediaTokenCache
import video.crumb.app.data.MediaUrls
import video.crumb.app.data.Network
import video.crumb.app.data.SecureStore
import video.crumb.app.data.CrumbApi
import video.crumb.app.data.CrumbRepository

/**
 * Manual dependency container — created once in [video.crumb.app.CrumbApp].
 *
 * Deliberately avoids an annotation-processing DI framework (Hilt/KSP) to keep
 * the build simple and fast. The single [CrumbRepository] and [SecureStore]
 * are shared app-wide; the [CrumbApi] is rebuilt when the server URL changes.
 */
class AppContainer(context: Context) {

    val store = SecureStore(context.applicationContext)

    /**
     * Emits when an authenticated request returns `401` (session expired or
     * revoked server-side via P0-SESSIONS). Collected once in the nav host to
     * drop the session and route back to Login. `extraBufferCapacity = 1` so the
     * off-main-thread `tryEmit` from the OkHttp interceptor never drops the event.
     */
    private val _authExpired = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val authExpired: SharedFlow<Unit> = _authExpired.asSharedFlow()

    // api + client are always rebuilt together (the client is the api's transport),
    // so they're held as one pair to keep them from drifting out of sync. The
    // per-camera scoped-media-token cache wraps `api` (it calls GET /media-token),
    // so it is rebuilt in lockstep too — a stale cache surviving a server/session
    // change would otherwise hand out tokens minted against the OLD session.
    @Volatile
    private var current: ApiAndClient = buildApiAndClient()

    val api: CrumbApi get() = current.api

    private data class ApiAndClient(
        val api: CrumbApi,
        val client: OkHttpClient,
        val mediaTokenCache: MediaTokenCache,
    )

    private fun buildApiAndClient(): ApiAndClient {
        // On any authenticated 401, clear the token immediately (stops further
        // requests from re-attaching a dead token) and signal the UI to log out.
        val client = Network.buildOkHttp(store) {
            store.clearSession()
            _authExpired.tryEmit(Unit)
        }
        val api = Network.buildApi(store.serverUrl, client)
        return ApiAndClient(api, client, MediaTokenCache(api))
    }

    /**
     * Rebuild the Retrofit stack against the current `store.serverUrl`.
     *
     * Shuts down the PREVIOUS client's dispatcher executor + connection pool
     * after swapping in the new one, so its idle threads and pooled sockets
     * don't leak every time the server URL changes (e.g. repeated edits in
     * Settings). Any request already in flight on the old client fails
     * naturally when its executor is shut down — nothing else holds a
     * reference to it once this returns.
     */
    @Synchronized
    fun rebuildApi() {
        val old = current.client
        current = buildApiAndClient()
        old.dispatcher.executorService.shutdown()
        old.connectionPool.evictAll()
    }

    /** A media-URL builder bound to the current server + scoped-token cache. Cheap; create per use. */
    fun mediaUrls(): MediaUrls = MediaUrls(store.serverUrl, current.mediaTokenCache)

    /** The scoped-media-token cache backing the CURRENT api/session (see [mediaUrls]). */
    fun mediaTokenCache(): MediaTokenCache = current.mediaTokenCache

    /**
     * Drop all cached scoped media tokens. Called on logout so a lingering
     * cached token from the just-ended session can't outlive it (the tokens
     * are short-lived anyway, but this keeps the cache honest immediately
     * rather than waiting out the ~15 min window).
     */
    fun clearMediaTokenCache() = runBlocking { current.mediaTokenCache.clear() }

    val repository: CrumbRepository by lazy { CrumbRepository(this) }
}
