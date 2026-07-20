// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import video.crumb.app.BuildConfig
import com.jakewharton.retrofit2.converter.kotlinx.serialization.asConverterFactory
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import java.util.concurrent.TimeUnit

/**
 * Builds the OkHttp + Retrofit stack for a given server URL. The stack is
 * rebuilt whenever the server URL changes (see [video.crumb.app.di.AppContainer]).
 */
object Network {

    val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    /**
     * OkHttp interceptor that attaches the bearer token from [SecureStore] and
     * detects session expiry/revocation. When a request that CARRIED a token
     * comes back `401`, the session is dead (expired or revoked server-side via
     * P0-SESSIONS) — fire [onUnauthorized] so the app can log out. Gated on
     * "we attached a token" so a `401` from the login screen itself (wrong
     * password, no token) never trips the global logout.
     *
     * Race guard: a slow in-flight request can carry an OLD token and come back
     * `401` well after the user has logged out and back in with a NEW token. If
     * we blindly cleared/emitted on any 401, that stale response would wipe the
     * fresh session out from under the user. So we snapshot the token WE attached
     * to this specific request, and only fire [onUnauthorized] if the store's
     * CURRENT token still matches it — i.e. nothing has replaced it since. If the
     * store has since been cleared (logout) or replaced (re-login), this stale
     * 401 is a no-op.
     */
    private class AuthInterceptor(
        private val store: SecureStore,
        private val onUnauthorized: () -> Unit,
    ) : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val attachedToken = store.token
            val hadToken = !attachedToken.isNullOrBlank()
            val request = if (hadToken) {
                chain.request().newBuilder()
                    .header("Authorization", "Bearer $attachedToken")
                    .build()
            } else {
                chain.request()
            }
            val response = chain.proceed(request)
            if (hadToken && response.code == 401 && store.token == attachedToken) {
                onUnauthorized()
            }
            return response
        }
    }

    /**
     * @param callTimeoutSeconds Optional whole-call ceiling. Set for the JSON API
     *   client so a wedged socket can never spin the UI indefinitely; leave null
     *   for one-shot transfer clients (export download) whose transfer time is
     *   legitimately unbounded.
     * @param onUnauthorized invoked (possibly off the main thread) when an
     *   authenticated request returns `401`. Keep it cheap + thread-safe.
     */
    fun buildOkHttp(
        store: SecureStore,
        callTimeoutSeconds: Long? = null,
        onUnauthorized: () -> Unit = {},
    ): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .addInterceptor(AuthInterceptor(store, onUnauthorized))
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            // Keep-alive sockets die silently while the app is backgrounded (Wi-Fi
            // power save, NAT/proxy idle timeouts drop the connection with no
            // FIN/RST). For HTTP/2 a dead pooled connection otherwise wedges EVERY
            // request — including manual retries — because new calls coalesce onto
            // the same broken socket and a per-stream timeout never evicts it. PING
            // frames make OkHttp notice within one interval and tear it down.
            .pingInterval(15, TimeUnit.SECONDS)
            // Explicit (it is the default): a request that fails on a stale pooled
            // connection before send is transparently retried on a fresh socket.
            .retryOnConnectionFailure(true)
        if (callTimeoutSeconds != null) builder.callTimeout(callTimeoutSeconds, TimeUnit.SECONDS)
        // Log ONLY in debug builds: BASIC logs request URLs, and media URLs carry a
        // short-lived scoped media token (see MediaTokenCache) as ?token= — never
        // write that to logcat in a release build.
        if (BuildConfig.DEBUG) {
            builder.addInterceptor(
                HttpLoggingInterceptor().apply { level = HttpLoggingInterceptor.Level.BASIC },
            )
        }
        return builder.build()
    }

    fun buildApi(baseUrl: String, client: OkHttpClient): CrumbApi {
        val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
        return Retrofit.Builder()
            .baseUrl(base)
            .client(client)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(CrumbApi::class.java)
    }
}
