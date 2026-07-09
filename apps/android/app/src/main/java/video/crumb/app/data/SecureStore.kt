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

    private val prefs: SharedPreferences = run {
        try {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                context,
                "crumb_secure",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        } catch (e: Exception) {
            // AndroidKeyStore / TEE can be unavailable (direct-boot, locked
            // keystore, or a corrupt master key after an OS/restore change),
            // which would otherwise crash the app on first launch. Fall back to
            // plain prefs so the app still starts — the stored token is a
            // short-lived JWT, not a long-term secret.
            android.util.Log.w(
                "SecureStore",
                "EncryptedSharedPreferences unavailable; using plain prefs fallback",
                e,
            )
            context.getSharedPreferences("crumb_fallback", Context.MODE_PRIVATE)
        }
    }

    var token: String?
        get() = prefs.getString(KEY_TOKEN, null)
        set(value) = prefs.edit().apply { if (value == null) remove(KEY_TOKEN) else putString(KEY_TOKEN, value) }.apply()

    /** Normalized server base URL with no trailing slash, e.g. `http://192.0.2.10:8080`. */
    var serverUrl: String
        get() = prefs.getString(KEY_SERVER, null) ?: BuildConfig.DEFAULT_SERVER_URL
        set(value) = prefs.edit().putString(KEY_SERVER, normalizeUrl(value)).apply()

    var role: String?
        get() = prefs.getString(KEY_ROLE, null)
        set(value) = prefs.edit().putString(KEY_ROLE, value).apply()

    var username: String?
        get() = prefs.getString(KEY_USERNAME, null)
        set(value) = prefs.edit().putString(KEY_USERNAME, value).apply()

    /**
     * Per-user capability set from `GET /auth/me`. Serialised as JSON so that
     * adding new fields to [CapabilitiesDto] never requires a migration — unknown
     * keys are ignored on decode. Absent (older server) → all-false defaults
     * (admins bypass via [isAdmin]). Cleared on logout.
     */
    var capabilities: CapabilitiesDto
        get() = prefs.getString(KEY_CAPABILITIES, null)?.let { json ->
            runCatching { jsonCodec.decodeFromString<CapabilitiesDto>(json) }.getOrDefault(CapabilitiesDto())
        } ?: CapabilitiesDto()
        set(value) = prefs.edit().putString(KEY_CAPABILITIES, jsonCodec.encodeToString(value)).apply()

    /**
     * Whether the app requires a biometric / device-credential unlock on launch.
     * A device-level preference (kept across logout, not part of the session). The
     * gate only engages when this is true AND there's a stored session ([isLoggedIn]).
     * Default false (opt-in).
     */
    var biometricEnabled: Boolean
        get() = prefs.getBoolean(KEY_BIOMETRIC, false)
        set(value) = prefs.edit().putBoolean(KEY_BIOMETRIC, value).apply()

    /**
     * Whether we've already offered biometric unlock via the one-time post-login
     * prompt. Gates that prompt to fire only once (the Settings toggle remains the
     * way to enable it afterwards), so we don't nag on every sign-in. Default false.
     */
    var biometricOffered: Boolean
        get() = prefs.getBoolean(KEY_BIOMETRIC_OFFERED, false)
        set(value) = prefs.edit().putBoolean(KEY_BIOMETRIC_OFFERED, value).apply()

    /**
     * Camera id of the fullscreen live view the user last had open, or null when
     * they are on the grid. Restored on the next app launch so the camera that
     * was open "stays open" when the app is reopened.
     */
    var lastLiveCameraId: String?
        get() = prefs.getString(KEY_LAST_LIVE_CAM, null)
        set(value) = prefs.edit().apply {
            if (value == null) remove(KEY_LAST_LIVE_CAM) else putString(KEY_LAST_LIVE_CAM, value)
        }.apply()

    /**
     * Whether the fullscreen live view plays audio (play-on-focus). Persisted
     * across sessions so the user's choice is remembered. Defaults to true.
     */
    var liveAudioOn: Boolean
        get() = prefs.getBoolean(KEY_LIVE_AUDIO, true)
        set(value) = prefs.edit().putBoolean(KEY_LIVE_AUDIO, value).apply()

    /**
     * Live wall grid-layout ordinal (GridLayout: 0=single, 1=2x2, 2=list).
     * Persisted so the chosen layout survives navigating in/out of a camera AND
     * app restarts (a plain `remember` was resetting it to 2x2 on every return).
     * Defaults to 2x2 (ordinal 1).
     */
    var liveGridLayout: Int
        get() = prefs.getInt(KEY_LIVE_LAYOUT, 1)
        set(value) = prefs.edit().putInt(KEY_LIVE_LAYOUT, value).apply()

    /**
     * On-screen PTZ control style in the fullscreen camera view: "wheel" (the
     * commercial-VMS-style joystick ring) or "edges" (up/down/left/right arrows pinned
     * to the frame edges). User-selectable; persisted across sessions. Default "wheel".
     */
    var ptzStyle: String
        get() = prefs.getString(KEY_PTZ_STYLE, "wheel") ?: "wheel"
        set(value) = prefs.edit().putString(KEY_PTZ_STYLE, value).apply()

    /**
     * Whether the motion-tuner button is shown in the fullscreen live view.
     * Admins can hide it once cameras are tuned — it's just noise then. Default true.
     */
    var motionTunerEnabled: Boolean
        get() = prefs.getBoolean(KEY_MOTION_TUNER, true)
        set(value) = prefs.edit().putBoolean(KEY_MOTION_TUNER, value).apply()

    /**
     * What a playback snapshot captures when the frame is pinch-zoomed:
     * - `false` (default): the FULL camera frame, regardless of zoom — preserves the
     *   original behaviour, where a snapshot is always the whole scene.
     * - `true`: only the **current view** — the visible (zoomed/panned) viewport is
     *   cropped out of the captured frame, so the snapshot matches what's on screen.
     * At 1× (not zoomed) both modes are identical (the full frame IS the view).
     */
    var snapshotCapturesView: Boolean
        get() = prefs.getBoolean(KEY_SNAPSHOT_VIEW, false)
        set(value) = prefs.edit().putBoolean(KEY_SNAPSHOT_VIEW, value).apply()

    /**
     * Whether the live wall is in Low-bandwidth mode. When true, each tile stops its
     * ExoPlayer/RTSP stream and instead polls a still-frame JPEG (~1 fps) from the
     * server. Persisted so the user's choice survives app restarts.
     *
     * Default false (normal RTSP streaming).
     */
    var lowBandwidthMode: Boolean
        get() = prefs.getBoolean(KEY_LOW_BW_MODE, false)
        set(value) = prefs.edit().putBoolean(KEY_LOW_BW_MODE, value).apply()

    /**
     * One-time migration flag: an earlier build's stall watchdog could falsely
     * trip the auto-fallback and PERSIST [lowBandwidthMode], leaving the wall stuck
     * in low-bw mode. The auto-fallback no longer persists; this gates a one-time
     * clear of the stale flag on upgrade.
     */
    var lowBwAutofixApplied: Boolean
        get() = prefs.getBoolean(KEY_LOW_BW_AUTOFIX, false)
        set(value) = prefs.edit().putBoolean(KEY_LOW_BW_AUTOFIX, value).apply()

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
        get() = prefs.getString(KEY_VIEWS, null)?.let { json ->
            runCatching { jsonCodec.decodeFromString<List<CameraView>>(json) }.getOrDefault(emptyList())
        } ?: emptyList()
        set(value) = prefs.edit().putString(KEY_VIEWS, jsonCodec.encodeToString(value)).apply()

    /** Id of the currently-selected view, or null for the "All cameras" wall. */
    var activeViewId: String?
        get() = prefs.getString(KEY_ACTIVE_VIEW, null)
        set(value) = prefs.edit().apply {
            if (value == null) remove(KEY_ACTIVE_VIEW) else putString(KEY_ACTIVE_VIEW, value)
        }.apply()

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
        get() = prefs.getString(KEY_DISMISSED_UPDATE_VERSION, null)
        set(value) = prefs.edit().apply {
            if (value == null) remove(KEY_DISMISSED_UPDATE_VERSION) else putString(KEY_DISMISSED_UPDATE_VERSION, value)
        }.apply()

    /**
     * Device-local epoch millis of the last organic (non-"Check now")
     * update check, so the app re-checks at most once every 24h across app
     * launches (`docs/UPDATE-SYSTEM-PLAN.md` §3). 0 = never checked.
     */
    var lastUpdateCheckAtMs: Long
        get() = prefs.getLong(KEY_LAST_UPDATE_CHECK, 0L)
        set(value) = prefs.edit().putLong(KEY_LAST_UPDATE_CHECK, value).apply()

    val isLoggedIn: Boolean get() = !token.isNullOrBlank()

    val isAdmin: Boolean get() = role.equals("admin", ignoreCase = true)

    fun clearSession() {
        prefs.edit()
            .remove(KEY_TOKEN)
            .remove(KEY_ROLE)
            .remove(KEY_USERNAME)
            .remove(KEY_LAST_LIVE_CAM)
            .remove(KEY_CAPABILITIES)
            .apply()
    }

    companion object {
        private const val KEY_TOKEN = "token"
        private const val KEY_SERVER = "server_url"
        private const val KEY_ROLE = "role"
        private const val KEY_USERNAME = "username"
        private const val KEY_LAST_LIVE_CAM = "last_live_cam"
        private const val KEY_LIVE_AUDIO = "live_audio_on"
        private const val KEY_LIVE_LAYOUT = "live_grid_layout"
        private const val KEY_LOW_BW_AUTOFIX = "low_bw_autofix_applied"
        private const val KEY_PTZ_STYLE = "ptz_style"
        private const val KEY_MOTION_TUNER = "motion_tuner_enabled"
        private const val KEY_SNAPSHOT_VIEW = "snapshot_captures_view"
        private const val KEY_VIEWS = "camera_views_json"
        private const val KEY_ACTIVE_VIEW = "active_view_id"
        private const val KEY_LOW_BW_MODE = "low_bandwidth_mode"
        private const val KEY_CAPABILITIES = "user_capabilities_json"
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
