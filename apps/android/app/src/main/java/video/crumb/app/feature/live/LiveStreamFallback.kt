// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import video.crumb.app.data.LiveStreamsResponse
import video.crumb.app.data.subStreamUrl

/**
 * Which of a camera's live endpoints a player is currently attached to — one
 * rung of the fallback ladder walked when a stream turns out to be unplayable
 * on this device.
 *
 * The ladder exists because Media3's RTSP stack cannot bring up H.265: its HEVC
 * depacketizer never reaches a playable frame, so an H265 stream spins in
 * BUFFERING (or errors out) forever while the same camera records fine and
 * plays fine on desktop. Cameras that ship H265 on the main only were already
 * handled by the single-step main→sub downgrade; cameras that ship H265 on
 * **both** main and sub (#524) were not — they exhausted the reconnect ladder
 * on two unplayable streams and never reached [MOBILE], the server-side H.264
 * transcode that exists for exactly this case.
 */
enum class StreamTier {
    /** Full-resolution main stream (`rtsp_main_url`). */
    MAIN,

    /**
     * The server's video-only sub restream (`rtsp_subv_url`, `<name>_subv`): the
     * raw sub run through an ffmpeg **copy** so go2rtc republishes a proper
     * `fmtp` (#483). Same codec as [SUB] — it repairs SDP, not the bitstream.
     */
    SUBV,

    /** The camera's raw sub stream (`rtsp_sub_url`). */
    SUB,

    /**
     * The server's on-demand H.264 transcode (`rtsp_mobile_url`,
     * `<name>_mobile`): go2rtc re-encodes the sub (or the main, on a camera with
     * no sub) to low-res H.264 + AAC. The one rung that is guaranteed to be a
     * codec Media3 can decode, which is why it is always last: it costs a real
     * ffmpeg process on the server for as long as a consumer is attached.
     */
    MOBILE,
}

/** The URL for [tier], or `null` when this camera does not expose that rung. */
fun LiveStreamsResponse.urlForTier(tier: StreamTier): String? = when (tier) {
    StreamTier.MAIN -> rtspMainUrl
    StreamTier.SUBV -> rtspSubvUrl
    StreamTier.SUB -> rtspSubUrl
    StreamTier.MOBILE -> rtspMobileUrl
}

/**
 * Keep the rungs this camera actually exposes, in the given order, and drop any
 * that would re-dial a URL already in the chain (a server that answers with the
 * same URL twice must not cost an extra doomed attempt).
 */
private fun LiveStreamsResponse.chainOf(vararg order: StreamTier): List<StreamTier> {
    val seen = HashSet<String>()
    return order.filter { tier -> urlForTier(tier)?.let { seen.add(it) } == true }
}

/**
 * Fallback ladder for a **live-wall tile**.
 *
 * The wall is low-res by design (N tiles, N decoders), so a camera with a sub
 * starts on it and never escalates to the main's bitrate: `subv → sub → mobile`.
 * A camera with no sub at all keeps today's behaviour of playing the main, with
 * the transcode as its one fallback: `main → mobile`.
 */
fun LiveStreamsResponse.wallStreamChain(): List<StreamTier> =
    if (subStreamUrl() != null) {
        chainOf(StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE)
    } else {
        chainOf(StreamTier.MAIN, StreamTier.MOBILE)
    }

/**
 * Fallback ladder for **fullscreen live**.
 *
 * Off a metered link fullscreen is the one place HD is worth it, so it starts on
 * the main and walks down: `main → subv → sub → mobile`. On a metered link the
 * data-saver order applies (unchanged from before: low-res first, the transcode
 * when the camera has no sub), with the main kept as the last resort so a broken
 * sub still leaves something to watch rather than a spinner.
 */
fun LiveStreamsResponse.fullscreenStreamChain(metered: Boolean): List<StreamTier> =
    if (metered) {
        chainOf(StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE, StreamTier.MAIN)
    } else {
        chainOf(StreamTier.MAIN, StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE)
    }

/**
 * Where to attach first: the highest rung this session has not already found
 * unplayable for this camera. If every rung is marked failed (nothing played at
 * all last time), start at the top anyway rather than refusing to try.
 */
fun startTier(chain: List<StreamTier>, failed: Set<StreamTier>): StreamTier? =
    chain.firstOrNull { it !in failed } ?: chain.firstOrNull()

/**
 * The next rung below [current], skipping ones already known to fail, or `null`
 * when the ladder is exhausted (the caller then falls through to its normal
 * reconnect backoff instead of re-dialling forever).
 */
fun nextTier(chain: List<StreamTier>, current: StreamTier?, failed: Set<StreamTier>): StreamTier? {
    val idx = chain.indexOf(current)
    val rest = if (idx < 0) chain else chain.drop(idx + 1)
    return rest.firstOrNull { it !in failed }
}

/**
 * Media3 `PlaybackException` error codes that mean **this device cannot play
 * this bitstream**, as opposed to a network/transport blip worth retrying.
 *
 * Mirrored as plain ints rather than referenced off `PlaybackException` so this
 * decision logic stays free of Android/Media3 types and is unit-testable on the
 * JVM. The codes are frozen public API (`androidx.media3.common.PlaybackException`):
 *
 * - 1004 `ERROR_CODE_FAILED_RUNTIME_CHECK` — the RTSP client's own
 *   `IllegalArgumentException`s surface here, including the `missing attribute
 *   fmtp` rejection that made cameras reconnect-loop in #483.
 * - 3003 `ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED`
 * - 4001 `ERROR_CODE_DECODER_INIT_FAILED`
 * - 4002 `ERROR_CODE_DECODER_QUERY_FAILED`
 * - 4004 `ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES`
 * - 4005 `ERROR_CODE_DECODING_FORMAT_UNSUPPORTED`
 *
 * Deliberately NOT included: 4003 `ERROR_CODE_DECODING_FAILED` and 3001
 * `ERROR_CODE_PARSING_CONTAINER_MALFORMED`, which a healthy stream can hit
 * transiently on a corrupt packet — those stay on the reconnect ladder.
 */
private val UNPLAYABLE_FORMAT_ERROR_CODES = setOf(1004, 3003, 4001, 4002, 4004, 4005)

/** True when [errorCode] means the bitstream itself can't be decoded here. */
fun isUnplayableFormatError(errorCode: Int): Boolean = errorCode in UNPLAYABLE_FORMAT_ERROR_CODES

/**
 * Should this failure step DOWN the ladder instead of reconnecting to the same
 * stream?
 *
 * - No rung left ⇒ never (fall through to the normal backoff/slow-retry ladder).
 * - The stream never reached a playable frame ⇒ yes. This is the H265 signature:
 *   Media3 either errors immediately or sits in BUFFERING, and no amount of
 *   reconnecting will change the codec. (It is also the pre-existing rule for
 *   the main→sub downgrade, kept verbatim.)
 * - The stream DID play and then dropped ⇒ only for a decoder/format error.
 *   Everything else is a transient blip (camera reboot, AP roam, Wi-Fi drop) and
 *   must reconnect to the SAME stream — downgrading there would quietly strand a
 *   healthy camera on the transcode.
 *
 * @param errorCode Media3 `PlaybackException.errorCode`, or `null` when the
 *   failure came from the stall watchdog (which sees no exception at all).
 */
fun shouldFallBackToNextTier(hasNextTier: Boolean, everReady: Boolean, errorCode: Int?): Boolean =
    when {
        !hasNextTier -> false
        !everReady -> true
        else -> errorCode != null && isUnplayableFormatError(errorCode)
    }

/**
 * Text for the fullscreen "not on HD" badge, or `null` on the main stream (no
 * badge). Naming the transcode matters: "SD" on a camera whose sub is also
 * unplayable would otherwise read as an ordinary sub-stream downgrade, when in
 * fact the device is watching a server-side re-encode (#524).
 */
fun sdBadgeLabel(tier: StreamTier?): String? = when (tier) {
    null, StreamTier.MAIN -> null
    StreamTier.SUBV, StreamTier.SUB -> "SD · tap for HD"
    StreamTier.MOBILE -> "SD transcode · tap for HD"
}

/**
 * Per-camera memory of which rungs proved unplayable, for THIS app run.
 *
 * Without it every wall recomposition and every fullscreen revisit re-walks the
 * whole ladder — one unplayable-stream timeout per rung, every time — which is
 * the "permanent spinner" the operator sees. With it, a camera that settled on
 * the transcode reattaches straight to the transcode.
 *
 * Deliberately process-scoped and NOT persisted: a codec verdict is a guess made
 * from a failure, and the operator can change the camera's encoder at any time.
 * It is dropped on app relaunch, on a server config change (a camera edit bumps
 * `config_version`), and on an explicit Retry — see [LiveViewModel.retry] and
 * `LiveScreen`'s config-version watch. It is also dropped for a camera whose
 * ladder is exhausted with nothing playable, since a total outage is no evidence
 * about codecs.
 */
object LiveStreamFallbackMemory {

    private val failedByCamera = HashMap<String, MutableSet<StreamTier>>()

    /** Rungs already known to be unplayable for [cameraId] this run. */
    @Synchronized
    fun failedTiers(cameraId: String): Set<StreamTier> =
        failedByCamera[cameraId]?.toSet() ?: emptySet()

    /** Record that [tier] never produced a playable frame for [cameraId]. */
    @Synchronized
    fun markFailed(cameraId: String, tier: StreamTier) {
        failedByCamera.getOrPut(cameraId) { mutableSetOf() }.add(tier)
    }

    /** Forget one camera's verdicts (ladder exhausted, or the camera was edited). */
    @Synchronized
    fun clear(cameraId: String) {
        failedByCamera.remove(cameraId)
    }

    /** Forget every verdict (server config changed, or the user tapped Retry). */
    @Synchronized
    fun clearAll() {
        failedByCamera.clear()
    }
}
