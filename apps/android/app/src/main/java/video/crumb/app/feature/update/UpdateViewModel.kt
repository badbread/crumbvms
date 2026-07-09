// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.update

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import video.crumb.app.BuildConfig
import video.crumb.app.data.CrumbRepository
import video.crumb.app.data.SecureStore

/**
 * UI state for the update-available banner + Settings/About row (issue #7).
 *
 * @param enabled Whether the server currently has the check turned on. Drives
 *   whether "Check now" is offered at all (`docs/UPDATE-SYSTEM-PLAN.md` §2.5) —
 *   false either because the operator disabled it, the server predates the
 *   feature (404), or no successful check has happened yet.
 * @param latestVersion Newest stable release tag reported by the server
 *   (without the leading `v`), or null if none has been fetched yet.
 * @param notesUrl Release-notes URL to open on tap.
 * @param dismissedVersion The version the user last dismissed the banner
 *   for; mirrors [SecureStore.dismissedUpdateVersion].
 * @param checking True while a request (organic or "Check now") is in flight.
 * @param everChecked True once at least one response (success or failure) has
 *   come back, so the About row can distinguish "not checked yet" from
 *   "checked, you're up to date".
 * @param ownVersion This app's own build version. Defaults to
 *   `BuildConfig.VERSION_NAME`; a constructor param (not a computed getter) so
 *   the version-compare gating is unit-testable without `BuildConfig`.
 */
data class UpdateUiState(
    val enabled: Boolean = false,
    val latestVersion: String? = null,
    val notesUrl: String? = null,
    val dismissedVersion: String? = null,
    val checking: Boolean = false,
    val everChecked: Boolean = false,
    val ownVersion: String = BuildConfig.VERSION_NAME,
) {
    /**
     * True when a strictly newer stable release exists per [SemVer.isNewer].
     * An unparsable own version (e.g. a local `-dev`/debug build) or latest
     * version is "no signal" — never true.
     */
    val updateAvailable: Boolean
        get() = latestVersion != null && SemVer.isNewer(ownVersion, latestVersion) == true

    /**
     * Show the dismissible banner: an update exists and this exact version
     * hasn't already been dismissed (dismissing stays quiet until a NEWER
     * version than the dismissed one appears).
     */
    val showBanner: Boolean
        get() = updateAvailable && dismissedVersion != latestVersion
}

/**
 * Checks `GET /updates/latest` once on every cold app launch, and again
 * whenever the About dialog is opened (see [refresh]) so its update field is
 * never stale — a client that first checked while the operator had the feature
 * OFF must still be able to discover it was turned ON. Periodic re-checks while
 * the app keeps running are throttled to at most every 24h
 * (`docs/UPDATE-SYSTEM-PLAN.md` §3). Also drives the manual "Check now"
 * affordance (§2.5), which forces an immediate re-check via `?refresh=1` —
 * itself rate-limited server-side, so repeated taps are cheap and never hammer
 * GitHub.
 *
 * A 404 (older server without the endpoint) or any other failure is treated
 * the same as `enabled:false`: state resets to "nothing to show" rather than
 * surfacing an error banner for what is a background nicety, per the plan's
 * feature-detection contract.
 */
class UpdateViewModel(
    private val repo: CrumbRepository,
    private val store: SecureStore,
) : ViewModel() {

    private val _uiState = MutableStateFlow(UpdateUiState(dismissedVersion = store.dismissedUpdateVersion))
    val uiState: StateFlow<UpdateUiState> = _uiState.asStateFlow()

    init {
        if (checkedThisLaunch.compareAndSet(false, true)) {
            // First check of this process launch — ALWAYS, ungated by the 24h
            // timer, so the proactive live-wall banner appears even right after
            // the operator flips the server toggle on. The process-static flag
            // only guards against re-checking on every ViewModel re-creation
            // within the same running process (config change, back-stack churn).
            performCheck(refresh = false)
        } else {
            // A later ViewModel re-creation within the same process: this is the
            // periodic re-check path — throttled to at most once every 24h (§3).
            val elapsed = System.currentTimeMillis() - store.lastUpdateCheckAtMs
            if (elapsed >= RECHECK_INTERVAL_MS) {
                performCheck(refresh = false)
            }
        }
    }

    /**
     * Trigger a fresh NORMAL check (not the forced `?refresh=1` path). Called
     * when the About dialog opens so its update field reflects current server
     * state rather than a possibly-stale cached one. Cheap — the server serves
     * its own 6h cache within the window, so this is at most one GitHub hit
     * every few hours regardless of how often About is opened.
     */
    fun refresh() = performCheck(refresh = false)

    /**
     * Force an immediate re-check ("Check now", §2.5). Safe to call
     * repeatedly — the server itself rate-limits actual GitHub hits to one
     * per 60s and serves the cached value otherwise.
     */
    fun checkNow() = performCheck(refresh = true)

    private fun performCheck(refresh: Boolean) {
        viewModelScope.launch {
            _uiState.update { it.copy(checking = true) }
            val result = repo.updatesLatest(refresh)
            store.lastUpdateCheckAtMs = System.currentTimeMillis()
            result.fold(
                onSuccess = { resp ->
                    _uiState.update {
                        it.copy(
                            enabled = resp.enabled,
                            latestVersion = resp.latestVersion,
                            notesUrl = resp.notesUrl,
                            checking = false,
                            everChecked = true,
                        )
                    }
                },
                onFailure = {
                    // 404 (old server) or a network error: show nothing, same
                    // as enabled:false, rather than an error banner for a
                    // background nicety.
                    _uiState.update {
                        it.copy(
                            enabled = false,
                            latestVersion = null,
                            notesUrl = null,
                            checking = false,
                            everChecked = true,
                        )
                    }
                },
            )
        }
    }

    /**
     * Dismiss the banner for the CURRENT [UpdateUiState.latestVersion] —
     * stays quiet until a newer release than this one appears.
     */
    fun dismiss() {
        val version = _uiState.value.latestVersion ?: return
        store.dismissedUpdateVersion = version
        _uiState.update { it.copy(dismissedVersion = version) }
    }

    companion object {
        /** Re-check at most once a day while the app is used (§3). */
        const val RECHECK_INTERVAL_MS = 24 * 60 * 60 * 1000L

        /**
         * Process-static: has the cold-launch check already fired this process?
         * Ensures the launch check runs exactly once per app launch (ungated by
         * the 24h timer) regardless of how many times [UpdateViewModel] is
         * re-created within that process.
         */
        private val checkedThisLaunch = java.util.concurrent.atomic.AtomicBoolean(false)
    }
}
