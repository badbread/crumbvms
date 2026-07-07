// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import android.net.Uri

/**
 * Builds absolute media URLs.
 *
 * ExoPlayer (segment playback), Coil (still frames, filmstrip/clip thumbnails)
 * fetch bytes directly and cannot set an Authorization header, so the API
 * accepts a token on the query string for media endpoints. Two flavours:
 *
 * - **Scoped, per-camera** (segments, filmstrip frames, camera stills, clip
 *   thumbnails/video): built by the `scoped*` / `authedScoped` suspend
 *   functions below, which use [MediaTokenCache] to attach a short-lived
 *   (~15 min) token valid ONLY for that one camera — never the full login JWT.
 * - **Cross-camera / archive** (export downloads): still carries the full
 *   login JWT via [authed], since an export can span multiple cameras and
 *   stages that a single-camera scoped token can't authorize. See
 *   `ExportViewModel.authedUrl`.
 *
 * RTSP live URLs come pre-formed from the API (go2rtc) and are returned as-is;
 * go2rtc on the LAN does not require a token at all.
 */
class MediaUrls(
    private val serverUrl: String,
    private val mediaTokenCache: MediaTokenCache,
) {
    /**
     * Resolve a possibly-relative API path against the server base, adding the
     * per-camera scoped token as `?token=`. Fetches/refreshes the cached token
     * for [cameraId] first (suspends only on a cache miss / near-expiry).
     */
    private suspend fun authedScoped(cameraId: String, pathOrUrl: String): String {
        val absolute = toAbsolute(pathOrUrl)
        val token = mediaTokenCache.freshToken(cameraId)
        val sep = if (absolute.contains('?')) '&' else '?'
        return "$absolute${sep}token=${Uri.encode(token)}"
    }

    /** RTSP/WebRTC URLs from the API are already absolute and unauthenticated. */
    fun raw(url: String): String = url

    /**
     * API-proxied still-frame URL for the playback wall and any consumer that needs
     * a preview frame regardless of which go2rtc instance owns the camera.
     *
     * Routes to `GET /cameras/{id}/frame.jpg` (scoped-token authed), which the
     * backend proxies from whichever go2rtc actually has the camera. Use this for all
     * wall preview tiles — it works for cameras migrated to Crumb's go2rtc and for
     * cameras that are still on Frigate's go2rtc.
     */
    suspend fun cameraFrameUrl(cameraId: String): String =
        authedScoped(cameraId, "/cameras/$cameraId/frame.jpg")

    /** Scoped-token clip thumbnail (Coil) for a Clips-feed [clipId] on [cameraId]. */
    suspend fun clipThumbUrl(cameraId: String, clipId: String): String =
        authedScoped(cameraId, "/clip/${Uri.encode(clipId)}/thumbnail.jpg")

    /**
     * Scoped-token clip mp4 (ExoPlayer) for a Clips-feed [clipId] on [cameraId].
     *
     * [quality] is `"preview"` (small, reduced res/fps — the feed default) or
     * `"full"` (source resolution, generated on demand for an explicit
     * full-quality action).
     */
    suspend fun clipVideoUrl(cameraId: String, clipId: String, quality: String = "preview"): String =
        authedScoped(cameraId, "/clip/${Uri.encode(clipId)}/clip.mp4?q=$quality")

    /**
     * Scoped-token URL for any other [cameraId]-owned relative media path/URL
     * (recorded segment files, filmstrip frame URLs — both returned by the API
     * as camera-scoped relative paths).
     */
    suspend fun scopedUrl(cameraId: String, pathOrUrl: String): String = authedScoped(cameraId, pathOrUrl)

    /**
     * Resolve [pathOrUrl] against the server base, adding the full LOGIN JWT as
     * `?token=`. Reserved for media that isn't scoped to one camera — currently
     * only export downloads (`ExportViewModel.authedUrl`), which can span
     * multiple cameras/archive stages. Do NOT use this for any new per-camera
     * media URL — use [scopedUrl] / [cameraFrameUrl] / [clipThumbUrl] /
     * [clipVideoUrl] instead so per-camera media never carries the full JWT.
     */
    fun authed(pathOrUrl: String, loginToken: String?): String {
        val absolute = toAbsolute(pathOrUrl)
        if (loginToken.isNullOrBlank()) return absolute
        val sep = if (absolute.contains('?')) '&' else '?'
        return "$absolute${sep}token=${Uri.encode(loginToken)}"
    }

    private fun toAbsolute(pathOrUrl: String): String {
        if (pathOrUrl.startsWith("http://") || pathOrUrl.startsWith("https://")) return pathOrUrl
        val base = serverUrl.trimEnd('/')
        val path = if (pathOrUrl.startsWith("/")) pathOrUrl else "/$pathOrUrl"
        return "$base$path"
    }
}
