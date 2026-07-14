// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import video.crumb.app.di.appContainer

/**
 * Self-contained network-connectivity observer for the live wall / fullscreen
 * reconnect logic ([LiveRtspContent], [LiveFullscreenScreen]).
 *
 * Backed by [ConnectivityManager.registerNetworkCallback] rather than the
 * deprecated CONNECTIVITY_ACTION broadcast, and rather than polling — a single
 * process-wide callback per subscriber, "online" defined as "has a validated
 * default network with INTERNET capability." That's a slightly stricter bar than
 * "has any network" (e.g. a captive portal or an AP with no uplink reads as
 * offline), which is what we want: a tile shouldn't burn its reconnect budget
 * attempting RTSP over a link that can't actually reach the server.
 *
 * [rememberIsOnline] is a Composable [State] for driving reconnect gating from
 * inside a tile/screen. It registers/unregisters the callback across the
 * lifecycle using the same `DisposableEffect` + [LifecycleEventObserver] pattern
 * already used for the pause/resume watchdogs in [LiveCameraTile] and
 * [LiveFullscreenScreen] (ON_START/ON_STOP-gated, so a backgrounded wall isn't
 * left holding a live callback for no reason).
 */
object NetworkConnectivityObserver {
    /** Best-effort synchronous online check (validated default network w/ INTERNET). */
    fun isOnlineNow(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return true
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    /**
     * Best-effort synchronous "is the active network metered" check — cellular,
     * a metered Wi-Fi hotspot, or a network the user manually flagged as metered.
     * Uses [ConnectivityManager.isActiveNetworkMetered], which honours the user's
     * per-network metered override, and falls back to `false` (assume unmetered,
     * i.e. never force the low-bitrate path) when connectivity can't be read.
     * Drives the playback quality selector's **Auto** mode (Auto → Low on metered).
     */
    fun isMeteredNow(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
        return cm.isActiveNetworkMetered
    }
}

/**
 * ONE process-wide connectivity observer (#137), owned by
 * [video.crumb.app.di.AppContainer]. It registers a **single**
 * [ConnectivityManager.registerNetworkCallback] for the whole app and exposes the
 * result as [online]/[metered] [StateFlow]s that any number of tiles subscribe to.
 *
 * This replaces the old per-composable registration: a full live wall calls
 * [rememberIsOnline] once per tile, so the previous design registered one system
 * callback per tile. Past the per-app callback ceiling (~100) that throws
 * `TooManyRequestsException` (API 30+) and, on some Android 11 builds, a spurious
 * `SecurityException` — crashing the app the moment a large wall opened. A single
 * shared callback makes the ceiling unreachable, and registration is additionally
 * wrapped so that even a framework refusal degrades to the last static snapshot
 * instead of crashing.
 *
 * Subscribers ref-count via [acquire]/[release]; the callback is registered on the
 * first subscriber and unregistered when the last leaves, so an app with no live
 * surfaces on screen holds no system callback.
 */
class NetworkStatusObserver(context: Context) {

    private val appContext = context.applicationContext
    private val cm = appContext.getSystemService(ConnectivityManager::class.java)

    private val _online = MutableStateFlow(NetworkConnectivityObserver.isOnlineNow(appContext))
    /** Validated default network with INTERNET (see [NetworkConnectivityObserver.isOnlineNow]). */
    val online: StateFlow<Boolean> = _online.asStateFlow()

    private val _metered = MutableStateFlow(NetworkConnectivityObserver.isMeteredNow(appContext))
    /** Active network is metered (see [NetworkConnectivityObserver.isMeteredNow]). */
    val metered: StateFlow<Boolean> = _metered.asStateFlow()

    private var callback: ConnectivityManager.NetworkCallback? = null
    private var refCount = 0

    /** Add a subscriber; registers the shared callback on the first one. */
    @Synchronized
    fun acquire() {
        if (refCount++ == 0) register()
    }

    /** Drop a subscriber; unregisters the shared callback when the last leaves. */
    @Synchronized
    fun release() {
        if (refCount > 0 && --refCount == 0) unregister()
    }

    private fun register() {
        if (cm == null || callback != null) return
        resync()
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = resync()
            override fun onLost(network: Network) = resync()
            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) = resync()
            override fun onUnavailable() = resync()
        }
        // #137: never let a callback-registration failure crash the wall.
        try {
            cm.registerNetworkCallback(request, cb)
            callback = cb
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "registerNetworkCallback failed; using static snapshot", t)
            callback = null
        }
    }

    private fun unregister() {
        val cb = callback ?: return
        callback = null
        try {
            cm?.unregisterNetworkCallback(cb)
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "unregisterNetworkCallback failed", t)
        }
    }

    /** Recompute both flows from the current active network. */
    private fun resync() {
        _online.value = NetworkConnectivityObserver.isOnlineNow(appContext)
        _metered.value = NetworkConnectivityObserver.isMeteredNow(appContext)
    }

    private companion object {
        const val TAG = "NetworkStatus"
    }
}

/**
 * Subscribe this composition to the shared [NetworkStatusObserver] for as long as
 * it is composed (ref-counted [acquire]/[release]). Reads are lifecycle-gated by
 * the [collectAsStateWithLifecycle] in the public wrappers below.
 */
@Composable
private fun rememberNetworkStatus(): NetworkStatusObserver {
    val observer = appContainer().networkStatus
    DisposableEffect(observer) {
        observer.acquire()
        onDispose { observer.release() }
    }
    return observer
}

/**
 * Live [State]<Boolean> tracking whether the active network is metered. Backed by
 * the shared [NetworkStatusObserver] (one callback for the whole app). Drives the
 * playback quality selector's Auto mode.
 */
@Composable
fun rememberIsMetered(): State<Boolean> =
    rememberNetworkStatus().metered.collectAsStateWithLifecycle()

/**
 * Live [State]<Boolean> tracking device connectivity, backed by the shared
 * [NetworkStatusObserver]. Defaults to the current synchronous read
 * ([NetworkConnectivityObserver.isOnlineNow]) until the callback fires, and falls
 * back to `true` (assume online, i.e. never block reconnects) when
 * [ConnectivityManager] is unavailable.
 */
@Composable
fun rememberIsOnline(): State<Boolean> =
    rememberNetworkStatus().online.collectAsStateWithLifecycle()
