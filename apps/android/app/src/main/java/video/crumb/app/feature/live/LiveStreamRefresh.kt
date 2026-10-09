// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

/**
 * Pure policy for re-resolving a live tile's stream URLs and for the "is the
 * network usable" gate. Kept free of Android and Compose types so it is unit
 * testable; [LiveViewModel], [LiveCameraTile] and [NetworkConnectivity] call it.
 */

/** Consecutive failed reconnects on one tile before it re-fetches its stream URLs. */
internal const val STREAM_REFRESH_AFTER_FAILURES = 3

/** Minimum gap between two `/streams` re-fetches for the same camera (ms). */
internal const val STREAM_REFRESH_MIN_INTERVAL_MS = 10_000L

/** Backoff for retrying a failed initial `/streams` fetch: first delay and cap (ms). */
internal const val STREAM_FETCH_RETRY_BASE_MS = 2_000L
internal const val STREAM_FETCH_RETRY_MAX_MS = 30_000L

/** How long an offline-parked tile waits before re-checking with a real attempt (ms). */
internal const val OFFLINE_PARK_RETRY_MS = 5_000L

/**
 * True once a tile has failed enough consecutive reconnects that the URL it is
 * dialing is suspect (changed address or credential, restream name gone) and the
 * stream list should be fetched again. [failures] counts attempts since the last
 * sustained-healthy period.
 */
internal fun shouldRefreshStreams(failures: Int): Boolean = failures >= STREAM_REFRESH_AFTER_FAILURES

/** Throttle: a re-fetch is allowed when none ran yet or the last one is old enough. */
internal fun streamRefreshAllowed(lastRefreshMs: Long?, nowMs: Long): Boolean =
    lastRefreshMs == null || nowMs - lastRefreshMs >= STREAM_REFRESH_MIN_INTERVAL_MS

/** Delay before retry number [attempt] (0-based) of a failed initial `/streams` fetch. */
internal fun streamFetchRetryDelayMs(attempt: Int): Long {
    val shift = attempt.coerceIn(0, 10)
    return (STREAM_FETCH_RETRY_BASE_MS shl shift).coerceAtMost(STREAM_FETCH_RETRY_MAX_MS)
}

/**
 * Whether a failed `/streams` fetch is worth retrying. [httpCode] is the HTTP
 * status when the failure was an HTTP error, else null (network / timeout, which
 * always retries). A 4xx other than 408/429 is a definite answer (no such camera,
 * no access), so retrying it would just hammer the server.
 */
internal fun isRetryableStreamFailure(httpCode: Int?): Boolean =
    httpCode == null || httpCode >= 500 || httpCode == 408 || httpCode == 429

/**
 * Whether the active network counts as usable for reconnecting. The server is
 * normally on the LAN and reachable with no Internet at all, so Android's
 * Internet-validation probe ([android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED])
 * is deliberately NOT consulted: a connected Wi-Fi or Ethernet link is usable,
 * and so is any network that advertises Internet capability.
 */
internal fun networkCountsAsOnline(hasInternetCapability: Boolean, isLanTransport: Boolean): Boolean =
    hasInternetCapability || isLanTransport
