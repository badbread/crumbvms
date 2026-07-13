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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

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
 * Remembers a live [State]<Boolean> tracking whether the active network is
 * metered (see [NetworkConnectivityObserver.isMeteredNow]). Re-samples on every
 * connectivity change over the same lifecycle-gated callback pattern as
 * [rememberIsOnline]. Drives the playback quality selector's Auto mode.
 */
@Composable
fun rememberIsMetered(): State<Boolean> {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var metered by remember { mutableStateOf(NetworkConnectivityObserver.isMeteredNow(context)) }

    DisposableEffect(lifecycleOwner) {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        var callback: ConnectivityManager.NetworkCallback? = null

        fun resync() {
            metered = NetworkConnectivityObserver.isMeteredNow(context)
        }

        fun register() {
            if (cm == null || callback != null) return
            resync()
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = resync()
                override fun onLost(network: Network) = resync()
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = resync()
            }
            callback = cb
            cm.registerNetworkCallback(request, cb)
        }

        fun unregister() {
            callback?.let { cm?.unregisterNetworkCallback(it) }
            callback = null
        }

        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> register()
                Lifecycle.Event.ON_STOP -> unregister()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        register()

        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            unregister()
        }
    }

    return remember { DerivedOnlineState { metered } }
}

/**
 * Remembers a live [State]<Boolean> tracking device connectivity, updated via
 * [ConnectivityManager.registerNetworkCallback]. Defaults to the current
 * synchronous read ([NetworkConnectivityObserver.isOnlineNow]) until the
 * callback fires, and falls back to `true` (assume online, i.e. never block
 * reconnects) if [ConnectivityManager] is unavailable for some reason.
 *
 * The callback is only registered while the host lifecycle is STARTED or
 * above — mirrors the ON_PAUSE/ON_RESUME (tile) and ON_START/ON_STOP
 * (fullscreen) gating already used for the player watchdogs, so a backgrounded
 * screen doesn't keep a system callback registered.
 */
@Composable
fun rememberIsOnline(): State<Boolean> {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var online by remember { mutableStateOf(NetworkConnectivityObserver.isOnlineNow(context)) }

    DisposableEffect(lifecycleOwner) {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        var callback: ConnectivityManager.NetworkCallback? = null

        fun register() {
            if (cm == null) {
                online = true
                return
            }
            // Idempotency guard: androidx.lifecycle.LifecycleRegistry synchronously
            // REPLAYS the missed events (ON_CREATE, ON_START, …) to an observer added
            // while already at/above STARTED — so the explicit register() call below
            // (right after addObserver) could otherwise race with the observer's own
            // ON_START replay and attempt to register the SAME callback twice, which
            // throws. Guard on `callback == null` so whichever fires first wins and
            // the second call is a no-op.
            if (callback != null) return
            // Re-sync immediately — connectivity may have changed while this
            // composable's lifecycle was below STARTED and the callback was
            // unregistered.
            online = NetworkConnectivityObserver.isOnlineNow(context)
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    online = true
                }
                override fun onLost(network: Network) {
                    // A non-default network can die while Wi-Fi is fine, so
                    // recheck via the active network rather than trusting this
                    // single callback in isolation.
                    online = NetworkConnectivityObserver.isOnlineNow(context)
                }
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    online = NetworkConnectivityObserver.isOnlineNow(context)
                }
                override fun onUnavailable() {
                    online = false
                }
            }
            callback = cb
            cm.registerNetworkCallback(request, cb)
        }

        fun unregister() {
            callback?.let { cm?.unregisterNetworkCallback(it) }
            callback = null
        }

        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> register()
                Lifecycle.Event.ON_STOP -> unregister()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        // Belt-and-suspenders: LifecycleRegistry.addObserver() above already
        // synchronously REPLAYS ON_START to `observer` (and thus calls register())
        // when the lifecycle is already at/above STARTED, but call it once more
        // explicitly in case this DisposableEffect ever runs in a context where
        // that replay doesn't happen. Safe either way — register() is idempotent
        // (see the `callback != null` guard above).
        register()

        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            unregister()
        }
    }

    return remember { DerivedOnlineState { online } }
}

/** Trivial [State] wrapper so [rememberIsOnline] can expose a stable snapshot read. */
private class DerivedOnlineState(private val getter: () -> Boolean) : State<Boolean> {
    override val value: Boolean get() = getter()
}
