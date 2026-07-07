// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.auth

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import video.crumb.app.data.CrumbRepository
import video.crumb.app.data.toUserMessage
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * UI state for the login screen.
 *
 * @property serverUrl The Crumb server base URL, pre-populated from [SecureStore].
 * @property username The username field value.
 * @property password The password field value.
 * @property loading True while a login network call is in-flight.
 * @property error A user-facing error message, or null when no error is present.
 * @property rememberMe When true, request a long-lived token (save-login) so the
 *   session survives restarts and doesn't expire after the default window.
 * @property discovering True while a local-network server scan is in-flight.
 * @property discovered Crumb servers found by the last scan (>1 ⇒ user picks one).
 * @property discoverMessage A user-facing result line for the scan, or null.
 */
data class AuthUiState(
    val serverUrl: String = "",
    val username: String = "",
    val password: String = "",
    val loading: Boolean = false,
    val error: String? = null,
    val rememberMe: Boolean = true,
    val discovering: Boolean = false,
    val discovered: List<DiscoveredServer> = emptyList(),
    val discoverMessage: String? = null,
    val showRangeScan: Boolean = false,
    val discoverRange: String = "",
)

/**
 * ViewModel for [LoginScreen].
 *
 * Holds field state, orchestrates the login call via [CrumbRepository], and
 * emits a one-shot [loginSuccess] event the screen collects to navigate away.
 * Structured concurrency is respected: all suspend work runs in [viewModelScope].
 */
class AuthViewModel(private val repo: CrumbRepository) : ViewModel() {

    private val _uiState = MutableStateFlow(
        AuthUiState(serverUrl = repo.store.serverUrl),
    )

    /** Immutable view of the login form state. */
    val uiState: StateFlow<AuthUiState> = _uiState.asStateFlow()

    /**
     * One-shot channel that fires a [Unit] after a successful login.
     * The screen collects this as a Flow and calls [onLoggedIn] on emission.
     */
    private val _loginSuccess = Channel<Unit>(Channel.BUFFERED)
    val loginSuccess = _loginSuccess.receiveAsFlow()

    // ── field update functions ────────────────────────────────────────────────

    /** Update the server URL field. */
    fun onServerUrlChange(value: String) {
        _uiState.update { it.copy(serverUrl = value, error = null) }
    }

    /** Update the username field. */
    fun onUsernameChange(value: String) {
        _uiState.update { it.copy(username = value, error = null) }
    }

    /** Update the password field. */
    fun onPasswordChange(value: String) {
        _uiState.update { it.copy(password = value, error = null) }
    }

    /** Toggle "keep me signed in" (save-login / long-lived token). */
    fun onRememberChange(value: Boolean) {
        _uiState.update { it.copy(rememberMe = value) }
    }

    // ── server auto-discovery ─────────────────────────────────────────────────

    /**
     * Scan the local network for Crumb servers. A single hit auto-fills the
     * Server URL field; multiple hits are surfaced for the user to pick from
     * (via [selectDiscovered]); none shows a "enter it manually" hint.
     */
    fun discover(context: Context) = runScan(context, range = null)

    /** Scan the user-supplied subnet/range (for a server on a different VLAN). */
    fun scanRange(context: Context) {
        val range = _uiState.value.discoverRange.trim()
        if (range.isEmpty()) return
        runScan(context, range = range)
    }

    private fun runScan(context: Context, range: String?) {
        if (_uiState.value.discovering) return
        _uiState.update {
            it.copy(discovering = true, discovered = emptyList(), discoverMessage = null, error = null)
        }
        val appContext = context.applicationContext
        viewModelScope.launch {
            val found = runCatching { discoverCrumbServers(appContext, range = range) }
                .getOrDefault(emptyList())
            _uiState.update {
                when {
                    found.isEmpty() -> it.copy(
                        discovering = false,
                        discovered = emptyList(),
                        // Reveal + prefill the subnet field so the user can point the
                        // scan at another VLAN (e.g. a server on a different /24).
                        showRangeScan = true,
                        discoverRange = it.discoverRange.ifBlank {
                            detectLocalSubnetCidr(appContext).orEmpty()
                        },
                        discoverMessage = "No Crumb server found" +
                            (range?.let { r -> " on $r" } ?: " on this network") +
                            ". Try scanning another subnet below, or enter the address manually.",
                    )
                    found.size == 1 -> it.copy(
                        discovering = false,
                        discovered = emptyList(),
                        serverUrl = found.first().url,
                        discoverMessage = "Found ${found.first().url}",
                    )
                    else -> it.copy(
                        discovering = false,
                        discovered = found,
                        discoverMessage = "Found ${found.size} servers — tap one to use it.",
                    )
                }
            }
        }
    }

    /** Reveal the "scan a specific subnet" field, prefilled with the device's /24. */
    fun revealRangeScan(context: Context) {
        val appContext = context.applicationContext
        _uiState.update {
            it.copy(
                showRangeScan = true,
                discoverRange = it.discoverRange.ifBlank {
                    detectLocalSubnetCidr(appContext).orEmpty()
                },
            )
        }
    }

    /** Update the subnet/range field. */
    fun onDiscoverRangeChange(value: String) {
        _uiState.update { it.copy(discoverRange = value) }
    }

    /** Pick one of several discovered servers; fills the field and clears the list. */
    fun selectDiscovered(url: String) {
        _uiState.update {
            it.copy(serverUrl = url, discovered = emptyList(), discoverMessage = "Using $url")
        }
    }

    // ── login ────────────────────────────────────────────────────────────────

    /**
     * Attempt to authenticate with the current field values.
     *
     * On success the store already holds the token (set by the repository) and
     * [loginSuccess] fires so the screen can navigate to the main graph.
     * On failure [AuthUiState.error] is set to a human-readable message.
     */
    fun login() {
        val state = _uiState.value
        if (state.loading) return

        _uiState.update { it.copy(loading = true, error = null) }

        viewModelScope.launch {
            val result = repo.login(
                server = state.serverUrl.trim(),
                username = state.username.trim(),
                password = state.password,
                remember = state.rememberMe,
            )
            result.fold(
                onSuccess = {
                    _uiState.update { it.copy(loading = false) }
                    _loginSuccess.send(Unit)
                },
                onFailure = { throwable ->
                    _uiState.update {
                        it.copy(
                            loading = false,
                            error = throwable.toUserMessage(),
                        )
                    }
                },
            )
        }
    }
}
