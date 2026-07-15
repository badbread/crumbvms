// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import video.crumb.app.BuildConfig

/**
 * Encrypted persistent storage for the auth token, server URL, and basic
 * profile info. Backed by [EncryptedSharedPreferences] (AES-256).
 *
 * The token is the JWT bearer; the server URL is user-configurable (so the app
 * can connect to a home server over Tailscale with an arbitrary address).
 */
class SecureStore(context: Context) {

    private val appContext = context.applicationContext

    /**
     * Whether [prefs] is the real AES-256 [EncryptedSharedPreferences] store.
     * `false` means the keystore was unavailable and we fell back to plaintext
     * prefs — in which case the auth token is kept IN MEMORY ONLY (never written
     * unencrypted to disk); see [token]. Set during [prefs] init below.
     */
    private var usingEncryptedPrefs: Boolean = false

    /**
     * Auth token when running on the plaintext fallback ([usingEncryptedPrefs] ==
     * false): held only for this process, never persisted. On process death the
     * app simply returns to the login screen rather than leaking a long-lived JWT
     * in cleartext on disk. Unused (always null) in the normal encrypted path.
     */
    @Volatile
    private var inMemoryToken: String? = null

    private val prefs: SharedPreferences = run {
        try {
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                appContext,
                SECURE_PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            ).also { usingEncryptedPrefs = true }
        } catch (e: Exception) {
            // AndroidKeyStore / TEE can be unavailable (direct-boot, locked
            // keystore, or a corrupt master key after an OS/restore change),
            // which would otherwise crash the app on first launch. Fall back to
            // plain prefs so the app still starts, but keep the auth token in
            // memory only (see [inMemoryToken]) — never write the JWT to plaintext
            // prefs. Non-secret settings (server URL, UI prefs) still persist.
            usingEncryptedPrefs = false
            android.util.Log.w(
                "SecureStore",
                "EncryptedSharedPreferences unavailable; using plain prefs fallback " +
                    "(token kept in-memory only)",
                e,
            )
            appContext.getSharedPreferences("crumb_fallback", Context.MODE_PRIVATE)
        }
    }

    /**
     * Read a value from [prefs], degrading to [fallback] if the read throws (#136).
     *
     * [EncryptedSharedPreferences] decrypts on every read, so an OS keystore
     * invalidation (the user changed their lock-screen credential, an OEM keystore
     * bug, a restore onto different hardware) makes previously-fine reads start
     * throwing mid-session — which, unguarded, crash-loops the app on launch. On
     * failure we best-effort WIPE the now-unreadable store and return the logged-out
     * default, so the app simply shows the login screen instead of dying.
     */
    private fun <T> safeRead(fallback: T, read: (SharedPreferences) -> T): T =
        try {
            read(prefs)
        } catch (e: Exception) {
            android.util.Log.w("SecureStore", "encrypted read failed; degrading to logged-out", e)
            runCatching { prefs.edit().clear().apply() }
            runCatching { appContext.deleteSharedPreferences(SECURE_PREFS_NAME) }
            fallback
        }

    /**
     * Apply an edit to [prefs], swallowing (not crashing on) a failure for the same
     * keystore-invalidation reason as [safeRead]. The next guarded read handles the
     * wipe + logout; a write must never take the app down.
     */
    private fun safeWrite(mutate: (SharedPreferences.Editor) -> Unit) {
        try {
            prefs.edit().apply(mutate).apply()
        } catch (e: Exception) {
            android.util.Log.w("SecureStore", "encrypted write failed; ignoring", e)
        }
    }

    /**
     * The JWT bearer. On the normal encrypted store it is persisted (AES-256); on
     * the plaintext fallback it is held IN MEMORY ONLY ([inMemoryToken]) and never
     * written to disk, so a keystore failure degrades to "session lost on restart"
     * rather than "long-lived token sitting in cleartext prefs" (#147-6).
     */
    var token: String?
        get() = if (usingEncryptedPrefs) safeRead(null) { it.getString(KEY_TOKEN, null) } else inMemoryToken
        set(value) {
            if (usingEncryptedPrefs) {
                safeWrite { if (value == null) it.remove(KEY_TOKEN) else it.putString(KEY_TOKEN, value) }
            } else {
                inMemoryToken = value
            }
        }

    /** Normalized server base URL with no trailing slash, e.g. `http://192.0.2.10:8080`. */
    var serverUrl: String
        get() = safeRead(BuildConfig.DEFAULT_SERVER_URL) {
            it.getString(KEY_SERVER, null) ?: BuildConfig.DEFAULT_SERVER_URL
        }
        set(value) = safeWrite { it.putString(KEY_SERVER, normalizeUrl(value)) }

    var role: String?
        get() = safeRead(null) { it.getString(KEY_ROLE, null) }
        set(value) = safeWrite { it.putString(KEY_ROLE, value) }

    var username: String?
        get() = safeRead(null) { it.getString(KEY_USERNAME, null) }
        set(value) = safeWrite { it.putString(KEY_USERNAME, value) }

    /**
     * Per-user capability set from `GET /auth/me`. Serialised as JSON so that
     * adding new fields to [CapabilitiesDto] never requires a migration — unknown
     * keys are ignored on decode. Absent (older server) → all-false defaults
     * (admins bypass via [isAdmin]). Cleared on logout.
     */
    var capabilities: CapabilitiesDto
        get() = safeRead(CapabilitiesDto()) { p ->
            p.getString(KEY_CAPABILITIES, null)?.let { json ->
                runCatching { jsonCodec.decodeFromString<CapabilitiesDto>(json) }.getOrDefault(CapabilitiesDto())
            } ?: CapabilitiesDto()
        }
        set(value) = safeWrite { it.putString(KEY_CAPABILITIES, jsonCodec.encodeToString(value)) }

    /**
     * Whether the Plates (license-plate recognition) surface is available:
     * server-side LPR enabled AND the caller has the `view_plates` capability
     * (`GET /auth/me.plates_enabled`, set at login — see [CrumbRepository.login]).
     * This is computed entirely server-side (including any admin bypass); the
     * client reflects it directly and never re-derives it from [capabilities].
     * Default false so an older server, or a session predating this field,
     * fails closed (the Plates tab stays hidden). Cleared on logout.
     */
    var platesEnabled: Boolean
        get() = safeRead(false) { it.getBoolean(KEY_PLATES_ENABLED, false) }
        set(value) = safeWrite { it.putBoolean(KEY_PLATES_ENABLED, value) }

    /**
     * Whether the app requires a biometric / device-credential unlock on launch.
     * A device-level preference (kept across logout, not part of the session). The
     * gate only engages when this is true AND there's a stored session ([isLoggedIn]).
     * Default false (opt-in).
     */
    var biometricEnabled: Boolean
        get() = safeRead(false) { it.getBoolean(KEY_BIOMETRIC, false) }
        set(value) = safeWrite { it.putBoolean(KEY_BIOMETRIC, value) }

    /**
     * Whether we've already offered biometric unlock via the one-time post-login
     * prompt. Gates that prompt to fire only once (the Settings toggle remains the
     * way to enable it afterwards), so we don't nag on every sign-in. Default false.
     */
    var biometricOffered: Boolean
        get() = safeRead(false) { it.getBoolean(KEY_BIOMETRIC_OFFERED, false) }
        set(value) = safeWrite { it.putBoolean(KEY_BIOMETRIC_OFFERED, value) }

    /**
     * Camera id of the fullscreen live view the user last had open, or null when
     * they are on the grid. Restored on the next app launch so the camera that
     * was open "stays open" when the app is reopened.
     */
    var lastLiveCameraId: String?
        get() = safeRead(null) { it.getString(KEY_LAST_LIVE_CAM, null) }
        set(value) = safeWrite {
            if (value == null) it.remove(KEY_LAST_LIVE_CAM) else it.putString(KEY_LAST_LIVE_CAM, value)
        }

    /**
     * Whether the fullscreen live view plays audio (play-on-focus). Persisted
     * across sessions so the user's choice is remembered. Defaults to true.
     */
    var liveAudioOn: Boolean
        get() = safeRead(true) { it.getBoolean(KEY_LIVE_AUDIO, true) }
        set(value) = safeWrite { it.putBoolean(KEY_LIVE_AUDIO, value) }

    /**
     * Whether the recorded-playback screen plays segment audio. Persisted across
     * sessions so the user's choice is remembered. Defaults to FALSE — reviewing
     * footage should stay silent unless the operator explicitly turns audio on,
     * so scrubbing through recordings never blares unexpected sound. (Older
     * footage recorded before audio capture landed simply plays silent when the
     * toggle is on — no crash.)
     */
    var playbackAudioOn: Boolean
        get() = safeRead(false) { it.getBoolean(KEY_PLAYBACK_AUDIO, false) }
        set(value) = safeWrite { it.putBoolean(KEY_PLAYBACK_AUDIO, value) }

    /**
     * Recorded-playback quality mode: "auto" (default), "full", or "low".
     * - "auto": full-res recorded bytes on Wi-Fi/unmetered, the server's on-demand
     *   640p `low.mp4` transcode on metered/cellular.
     * - "full": always the recorded main-stream bytes.
     * - "low": always the low-bitrate transcode ("Data saver").
     * Persisted across sessions (a device-level preference, so it survives logout).
     */
    var playbackQuality: String
        get() = safeRead("auto") { it.getString(KEY_PLAYBACK_QUALITY, "auto") ?: "auto" }
        set(value) = safeWrite { it.putString(KEY_PLAYBACK_QUALITY, value) }

    /**
     * LPR thumbnail image mode: "plate" (default) crops the thumbnail to the
     * license plate; "vehicle" shows the full detection snapshot (the whole car).
     * A device-level display preference, persisted across sessions.
     */
    var lprImageMode: String
        get() = safeRead("plate") { it.getString(KEY_LPR_IMAGE_MODE, "plate") ?: "plate" }
        set(value) = safeWrite { it.putString(KEY_LPR_IMAGE_MODE, value) }

    /**
     * Live wall grid-layout ordinal (GridLayout: 0=single, 1=2x2, 2=list).
     * Persisted so the chosen layout survives navigating in/out of a camera AND
     * app restarts (a plain `remember` was resetting it to 2x2 on every return).
     * Defaults to 2x2 (ordinal 1).
     */
    var liveGridLayout: Int
        get() = safeRead(1) { it.getInt(KEY_LIVE_LAYOUT, 1) }
        set(value) = safeWrite { it.putInt(KEY_LIVE_LAYOUT, value) }

    /**
     * On-screen PTZ control style in the fullscreen camera view: "wheel" (the
     * commercial-VMS-style joystick ring) or "edges" (up/down/left/right arrows pinned
     * to the frame edges). User-selectable; persisted across sessions. Default "wheel".
     */
    var ptzStyle: String
        get() = safeRead("wheel") { it.getString(KEY_PTZ_STYLE, "wheel") ?: "wheel" }
        set(value) = safeWrite { it.putString(KEY_PTZ_STYLE, value) }

    /**
     * Whether the motion-tuner button is shown in the fullscreen live view.
     * Admins can hide it once cameras are tuned — it's just noise then. Default true.
     */
    var motionTunerEnabled: Boolean
        get() = safeRead(true) { it.getBoolean(KEY_MOTION_TUNER, true) }
        set(value) = safeWrite { it.putBoolean(KEY_MOTION_TUNER, value) }

    /**
     * Whether the auto-built "All Cameras" quick-grid default view is offered on the
     * Live/Playback wall — a client-side preference, not a server setting. Mirrors
     * the desktop client's `showAllCamerasView` option (`client_options.dart`).
     * Default true (unchanged behavior): "All" stays the default until an operator
     * opts to hide it in favor of their own saved views. A device-level preference
     * like [ptzStyle]/[motionTunerEnabled]; NOT cleared on logout.
     */
    var showAllCamerasView: Boolean
        get() = safeRead(true) { it.getBoolean(KEY_SHOW_ALL_CAMERAS_VIEW, true) }
        set(value) = safeWrite { it.putBoolean(KEY_SHOW_ALL_CAMERAS_VIEW, value) }

    /**
     * Last playback-timeline zoom level (visible time span, in millis) the user left
     * the Playback surfaces on. Shared by BOTH single-camera playback and the playback
     * wall, so switching between them and back restores the same scale, and it survives
     * app restarts (a plain `remember`/`UiState` default was resetting to 1 h on every
     * return). A device-level UI preference like [ptzStyle]/[showAllCamerasView]; NOT
     * cleared on logout. Default 1 h. Callers coerce into each surface's own min/max
     * before writing (never persist an out-of-range span).
     */
    var playbackSpanMs: Long
        get() = safeRead(60L * 60_000L) { it.getLong(KEY_PLAYBACK_SPAN_MS, 60L * 60_000L) }
        set(value) = safeWrite { it.putLong(KEY_PLAYBACK_SPAN_MS, value) }

    /**
     * What a playback snapshot captures when the frame is pinch-zoomed:
     * - `false` (default): the FULL camera frame, regardless of zoom — preserves the
     *   original behaviour, where a snapshot is always the whole scene.
     * - `true`: only the **current view** — the visible (zoomed/panned) viewport is
     *   cropped out of the captured frame, so the snapshot matches what's on screen.
     * At 1× (not zoomed) both modes are identical (the full frame IS the view).
     */
    var snapshotCapturesView: Boolean
        get() = safeRead(false) { it.getBoolean(KEY_SNAPSHOT_VIEW, false) }
        set(value) = safeWrite { it.putBoolean(KEY_SNAPSHOT_VIEW, value) }

    /**
     * Whether the live wall is in Low-bandwidth mode. When true, each tile stops its
     * ExoPlayer/RTSP stream and instead polls a still-frame JPEG (~1 fps) from the
     * server. Persisted so the user's choice survives app restarts.
     *
     * Default false (normal RTSP streaming).
     */
    var lowBandwidthMode: Boolean
        get() = safeRead(false) { it.getBoolean(KEY_LOW_BW_MODE, false) }
        set(value) = safeWrite { it.putBoolean(KEY_LOW_BW_MODE, value) }

    /**
     * One-time migration flag: an earlier build's stall watchdog could falsely
     * trip the auto-fallback and PERSIST [lowBandwidthMode], leaving the wall stuck
     * in low-bw mode. The auto-fallback no longer persists; this gates a one-time
     * clear of the stale flag on upgrade.
     */
    var lowBwAutofixApplied: Boolean
        get() = safeRead(false) { it.getBoolean(KEY_LOW_BW_AUTOFIX, false) }
        set(value) = safeWrite { it.putBoolean(KEY_LOW_BW_AUTOFIX, value) }

    /**
     * How the Plates tab renders its reads: "list" (dense rows, default),
     * "gallery" (snapshot grid), "grouped" (collapsed by plate), or "timeline"
     * (big chronological feed). Per-account UI residue: CLEARED on logout
     * ([clearSession]) so a shared device doesn't carry one operator's choice into
     * the next login (#147-7). Default "list" (the original view).
     */
    var platesViewMode: String
        get() = safeRead("list") { it.getString(KEY_PLATES_VIEW_MODE, "list") ?: "list" }
        set(value) = safeWrite { it.putString(KEY_PLATES_VIEW_MODE, value) }

    // ── Live-wall views cache (server-backed; this is a local mirror) ────────────

    /**
     * Local CACHE of the caller's saved Live-wall views. The source of truth is now
     * the server (`/views`, per-user) — the same set the desktop uses — so views
     * survive reinstalls and sync across devices. This mirror lets the chips render
     * instantly and offline; the Live/Playback screens reconcile it with the server
     * on entry and after every edit. Client-side view ORDER is kept here (the server
     * has no ordering). A corrupt/old JSON value decodes to an empty list.
     */
    var cameraViews: List<CameraView>
        get() = safeRead(emptyList()) { p ->
            p.getString(KEY_VIEWS, null)?.let { json ->
                runCatching { jsonCodec.decodeFromString<List<CameraView>>(json) }.getOrDefault(emptyList())
            } ?: emptyList()
        }
        set(value) = safeWrite { it.putString(KEY_VIEWS, jsonCodec.encodeToString(value)) }

    /** Id of the currently-selected view, or null for the "All cameras" wall. */
    var activeViewId: String?
        get() = safeRead(null) { it.getString(KEY_ACTIVE_VIEW, null) }
        set(value) = safeWrite {
            if (value == null) it.remove(KEY_ACTIVE_VIEW) else it.putString(KEY_ACTIVE_VIEW, value)
        }

    // Playback bookmarks moved server-side (shared across clients) — see
    // CrumbRepository.bookmarks()/addBookmark() and the /bookmarks API.

    // ── update-available check (issue #7) ────────────────────────────────────

    /**
     * Release version the user last dismissed the update-available banner
     * for. The banner stays hidden until a NEWER release appears than this
     * one — dismissing v0.0.2 does not suppress a later v0.0.3. Null when
     * nothing has ever been dismissed.
     */
    var dismissedUpdateVersion: String?
        get() = safeRead(null) { it.getString(KEY_DISMISSED_UPDATE_VERSION, null) }
        set(value) = safeWrite {
            if (value == null) it.remove(KEY_DISMISSED_UPDATE_VERSION) else it.putString(KEY_DISMISSED_UPDATE_VERSION, value)
        }

    /**
     * Device-local epoch millis of the last organic (non-"Check now")
     * update check, so the app re-checks at most once every 24h across app
     * launches (`docs/UPDATE-SYSTEM-PLAN.md` §3). 0 = never checked.
     */
    var lastUpdateCheckAtMs: Long
        get() = safeRead(0L) { it.getLong(KEY_LAST_UPDATE_CHECK, 0L) }
        set(value) = safeWrite { it.putLong(KEY_LAST_UPDATE_CHECK, value) }

    val isLoggedIn: Boolean get() = !token.isNullOrBlank()

    val isAdmin: Boolean get() = role.equals("admin", ignoreCase = true)

    fun clearSession() {
        // Drop the in-memory token used by the plaintext fallback (#147-6).
        inMemoryToken = null
        safeWrite {
            it.remove(KEY_TOKEN)
                .remove(KEY_ROLE)
                .remove(KEY_USERNAME)
                .remove(KEY_LAST_LIVE_CAM)
                .remove(KEY_CAPABILITIES)
                .remove(KEY_PLATES_ENABLED)
                // Per-account UI residue: on a SHARED device, the next principal to
                // log in must not inherit the previous account's saved-view mirror,
                // selected view, or Plates render mode (#147-7). These repopulate on
                // first use / server reconcile; genuine device-chrome preferences
                // (ptzStyle, showAllCamerasView, playback quality, grid layout, …)
                // are deliberately NOT cleared.
                .remove(KEY_VIEWS)
                .remove(KEY_ACTIVE_VIEW)
                .remove(KEY_PLATES_VIEW_MODE)
        }
    }

    companion object {
        /** Name of the AES-256 EncryptedSharedPreferences store (see [safeRead]'s wipe). */
        private const val SECURE_PREFS_NAME = "crumb_secure"
        private const val KEY_TOKEN = "token"
        private const val KEY_SERVER = "server_url"
        private const val KEY_ROLE = "role"
        private const val KEY_USERNAME = "username"
        private const val KEY_LAST_LIVE_CAM = "last_live_cam"
        private const val KEY_LIVE_AUDIO = "live_audio_on"
        private const val KEY_PLAYBACK_AUDIO = "playback_audio_on"
        private const val KEY_PLAYBACK_QUALITY = "playback_quality"
        private const val KEY_LIVE_LAYOUT = "live_grid_layout"
        private const val KEY_LOW_BW_AUTOFIX = "low_bw_autofix_applied"
        private const val KEY_PTZ_STYLE = "ptz_style"
        private const val KEY_MOTION_TUNER = "motion_tuner_enabled"
        private const val KEY_SHOW_ALL_CAMERAS_VIEW = "show_all_cameras_view"
        private const val KEY_PLAYBACK_SPAN_MS = "playback_span_ms"
        private const val KEY_PLATES_VIEW_MODE = "plates_view_mode"
        private const val KEY_LPR_IMAGE_MODE = "lpr_image_mode"
        private const val KEY_SNAPSHOT_VIEW = "snapshot_captures_view"
        private const val KEY_VIEWS = "camera_views_json"
        private const val KEY_ACTIVE_VIEW = "active_view_id"
        private const val KEY_LOW_BW_MODE = "low_bandwidth_mode"
        private const val KEY_CAPABILITIES = "user_capabilities_json"
        private const val KEY_PLATES_ENABLED = "plates_enabled"
        private const val KEY_BIOMETRIC = "biometric_enabled"
        private const val KEY_BIOMETRIC_OFFERED = "biometric_offered"
        private const val KEY_DISMISSED_UPDATE_VERSION = "dismissed_update_version"
        private const val KEY_LAST_UPDATE_CHECK = "last_update_check_at_ms"

        /** Lenient JSON for the local views blob and capability set (tolerates schema drift). */
        private val jsonCodec = Json { ignoreUnknownKeys = true }

        /** Trim whitespace and trailing slashes; prepend http:// if no scheme given. */
        fun normalizeUrl(raw: String): String {
            var s = raw.trim()
            if (s.isEmpty()) return s
            if (!s.startsWith("http://") && !s.startsWith("https://")) {
                s = "http://$s"
            }
            return s.trimEnd('/')
        }
    }
}
