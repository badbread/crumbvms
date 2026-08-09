// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import video.crumb.app.data.LiveStreamsResponse
import video.crumb.app.data.subStreamUrl

/**
 * Which of a camera's live endpoints a player is currently attached to — one
 * rung of the fallback ladder walked when a stream turns out to be unplayable
 * on this device.
 *
 * **H.265 is not the discriminator — read this before "fixing" anything here.**
 * The comments and issue history around #483/#524 said Media3's RTSP stack cannot
 * bring up H.265 at all. Measured on device (Media3 1.4.1, 2026-08-07): it plays
 * H.265 mains over RTSP perfectly well, 4K included, and on a typical install most
 * cameras' mains are H.265. Do not add anything that avoids H.265 pre-emptively;
 * doing so downgrades cameras that would have played in HD, which is exactly the
 * regression #560 was.
 *
 * What genuinely fails is narrower and is about RTP **packetization**, not the
 * codec: Media3's `RtpH265Reader` has never implemented RFC 7798 §4.4.2
 * Aggregation Packets (androidx/media#1008), so a stream whose NALs are small
 * enough to be aggregated — seen on an LPR camera at 1080p, while the same
 * vendor's 4K streams always fragment and play fine — throws every time. Some
 * devices also lack an HEVC hardware decoder entirely. Both are real, both are
 * per-stream, and neither is knowable in advance: hence a REACTIVE ladder, walked
 * only on observed playback failure, ending at [MOBILE], the server-side H.264
 * transcode that exists for exactly this case (#524).
 */
enum class StreamTier {
    /** Full-resolution main stream (`rtsp_main_url`). */
    MAIN,

    /**
     * The server's repaired full-resolution main (`rtsp_mainv_url`, `<name>_mainv`):
     * a per-camera H.265->H.264 **transcode** the server registers only for a main
     * it has detected publishes video with no `a=fmtp`, and only when the operator
     * has opted the repair in (it costs recorder CPU). Unlike [SUBV] this is a
     * re-encode, not a copy: a copy-remux of an H.265 main fixes the SDP but go2rtc
     * then bundles the parameter sets into an RTP Aggregation Packet Media3 cannot
     * depacketize, so only a transcode yields a main this device can actually play.
     * Full resolution, so it carries no SD badge. Normally `null`.
     */
    MAINV,

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
    StreamTier.MAINV -> rtspMainvUrl
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
 * A camera with no sub at all plays the main. When the server publishes a
 * repaired main (`mainv`) it is tried FIRST — its presence means the raw main is
 * unplayable here, so leading with the raw main would just be a doomed connect —
 * then the raw main, then the transcode: `mainv → main → mobile`. With no repair
 * `mainv` is absent and this is the unchanged `main → mobile`.
 */
fun LiveStreamsResponse.wallStreamChain(): List<StreamTier> =
    if (subStreamUrl() != null) {
        chainOf(StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE)
    } else {
        chainOf(StreamTier.MAINV, StreamTier.MAIN, StreamTier.MOBILE)
    }

/**
 * Fallback ladder for **fullscreen live**.
 *
 * Off a metered link fullscreen is the one place HD is worth it, so it starts on
 * the HD main and walks down: `mainv → main → subv → sub → mobile`. The repaired
 * main (`mainv`) sits BEFORE the raw main, not after it: the server publishes
 * `mainv` ONLY for a main it has positively detected this device cannot play
 * (missing served `fmtp`), so trying the raw main first would be a guaranteed
 * doomed connect on every open — the LPR startup lag. Leading with `mainv` gets HD
 * straight away and never loses a main that would have worked (a camera with no
 * repair has no `mainv` rung and starts on the raw main exactly as before). On a
 * metered link the data-saver order applies (low-res first, the transcode when the
 * camera has no sub), with both HD mains kept as the last resort — `mainv` still
 * ahead of the doomed raw main — so a broken sub still leaves something to watch.
 */
fun LiveStreamsResponse.fullscreenStreamChain(metered: Boolean): List<StreamTier> =
    if (metered) {
        chainOf(StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE, StreamTier.MAINV, StreamTier.MAIN)
    } else {
        chainOf(StreamTier.MAINV, StreamTier.MAIN, StreamTier.SUBV, StreamTier.SUB, StreamTier.MOBILE)
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
 * Media3 `PlaybackException` error codes that say **nothing about the codec**, so
 * they can never be evidence for stepping down the ladder (#560). Verified
 * against the pinned `androidx.media3:media3-common:1.4.1`:
 *
 * - `2000..2999` — the whole IO block (2000 `ERROR_CODE_IO_UNSPECIFIED`, 2001
 *   `..._NETWORK_CONNECTION_FAILED`, 2002 `..._NETWORK_CONNECTION_TIMEOUT`,
 *   2003…2008). The range is matched rather than enumerated so a newer Media3
 *   adding an IO code lands on the retry side by default. The bytes did not
 *   arrive; that is not a statement about whether they were decodable.
 * - 1002 `ERROR_CODE_BEHIND_LIVE_WINDOW` and 1003 `ERROR_CODE_TIMEOUT` — the
 *   stream fell behind, or an operation timed out. A re-prepare fixes both; a
 *   different codec fixes neither.
 * - 4006 `ERROR_CODE_DECODING_RESOURCES_RECLAIMED` — the platform took the
 *   decoder away (another app, or a surface that went away). It sits in the
 *   decoder block but it is a resource event, not a verdict on the bitstream.
 *
 * A camera slow to hand out its first keyframe, an AP roam, a phone coming back
 * from doze: on RTSP these all land here BEFORE the stream ever produced a frame,
 * which is exactly the case #529 read as "undecodable codec".
 */
fun isCodecAgnosticError(errorCode: Int): Boolean =
    errorCode in 2000..2999 || errorCode == 1002 || errorCode == 1003 || errorCode == 4006

/**
 * Substrings that identify a failure Media3 will hit **every single time** on this
 * stream, from the exception chain rather than the error code.
 *
 * Two matter today, both thrown from inside the RTSP loader, so both reach the app
 * wrapped in an `IOException` and arrive with an IO error code that looks exactly
 * like a network problem — which is precisely why the code alone is not enough to
 * classify either:
 *
 * - `processAggregationPacket`: `RtpH265Reader`'s
 *   `UnsupportedOperationException("need to implement processAggregationPacket")`,
 *   verified present in the pinned `media3-exoplayer-rtsp:1.4.1`. RFC 7798 §4.4.2
 *   Aggregation Packets pack several SMALL NALs into one RTP packet, and Media3 has
 *   never implemented that path (androidx/media#1008).
 * - `missing attribute fmtp`: the RTSP client rejects an SDP whose media track has
 *   no `a=fmtp` line (an H264/H265 track with no out-of-band parameter sets), the
 *   `IllegalArgumentException` #483 is about. Depending on where it surfaces this
 *   can arrive as a `1004 FAILED_RUNTIME_CHECK` (already an unplayable format code)
 *   OR — as seen on an LPR camera's H.265 MAIN over RTSP — wrapped through
 *   `RtspPlaybackException` into a `2000` IO code, which the graduated threshold
 *   would otherwise retry ~30 s before giving up. The SDP does not change between
 *   attempts, so it is deterministic; the signature makes the step-down immediate
 *   regardless of the code it happens to wear. NB the server-side `_subv`/`_mainv`
 *   fmtp repair fixes only cameras it manages and detects — this is the client's
 *   backstop for the rest.
 *
 * This is a *narrow* list on purpose: a signature here means "step down now, do
 * not retry", so only failures that are structurally deterministic belong in it.
 */
private val UNPLAYABLE_FAILURE_SIGNATURES = listOf("processAggregationPacket", "missing attribute fmtp")

/**
 * True when a failure's [detail] (see [failureDetail]) names a deterministic,
 * stream-specific limitation rather than a moment's bad luck.
 */
fun isUnplayableFailureDetail(detail: String?): Boolean =
    detail != null && UNPLAYABLE_FAILURE_SIGNATURES.any { it in detail }

/**
 * Strip anything URL-shaped out of text bound for logcat. RTSP URLs in this app
 * carry the stream credentials, and Media3 puts the URL it was loading into plenty
 * of its exception messages — a diagnostic log must never be the thing that leaks
 * them (golden rule 1).
 */
fun redactUrls(text: String?): String? =
    text?.replace(Regex("""[a-zA-Z][a-zA-Z0-9+.\-]*://\S*"""), "<url>")

/**
 * A short, credential-free summary of a failure's exception chain, for both
 * [isUnplayableFailureDetail] and the log line: `Class: message` per level, most
 * specific cause last. Capped so a deep chain can't flood logcat.
 */
fun failureDetail(error: Throwable?, maxDepth: Int = 4): String? {
    if (error == null) return null
    val parts = ArrayList<String>(maxDepth)
    var t: Throwable? = error
    var depth = 0
    while (t != null && depth < maxDepth) {
        val msg = redactUrls(t.message)?.takeIf { it.isNotBlank() }
        parts += if (msg != null) "${t.javaClass.simpleName}: $msg" else t.javaClass.simpleName
        t = t.cause?.takeIf { it !== t }
        depth += 1
    }
    return parts.joinToString(" <- ")
}

/**
 * How many pre-first-frame failures a rung has to accumulate before an
 * **unexplained** failure (the stall watchdog's silent spin, an unspecified
 * error) is accepted as "nothing will ever play here".
 *
 * One is too few: the first attempt at a cold rung competes with go2rtc spawning
 * an ffmpeg, the camera's keyframe interval, and whatever else the wall is doing
 * over the same Wi-Fi. Two, each already bounded by the first-load buffering
 * limit and separated by a re-prepare, keeps a genuinely unplayable stream's walk
 * fast while making a one-off slow start cost a retry rather than a permanent
 * downgrade.
 */
const val PRE_FIRST_FRAME_FAILURES_BEFORE_FALLBACK = 2

/**
 * How many pre-first-frame failures it takes before even a **codec-agnostic**
 * failure (an IO code) is treated as a reason to leave the rung.
 *
 * This is the safety valve, not the main path. A stream that structurally cannot
 * be depacketized can surface as an IO error every attempt (see
 * [UNPLAYABLE_FAILURE_SIGNATURES]: the exception is thrown inside the loader and
 * arrives wrapped in an `IOException`), so "an IO code never counts" would strand
 * such a camera on a rung forever — the #524 spinner, back again. Five in a row
 * with not one frame in between spans the whole fast-backoff curve (~30 s of
 * 1 s + 2 s + 4 s + 8 s + 15 s), which no ordinary Wi-Fi blip or slow camera start
 * survives, but a deterministic failure reaches every time.
 */
const val CODEC_AGNOSTIC_FAILURES_BEFORE_FALLBACK = 5

/**
 * Running tally of consecutive failures on the CURRENT rung before it ever showed
 * a frame. Reset by the rung playing, and implicitly by moving to another rung
 * (the caller's counter lives with the player, which is re-keyed on the rung's
 * URL).
 */
fun tallyPreFirstFrameFailure(previous: Int, everReady: Boolean): Int =
    if (everReady) 0 else previous + 1

/**
 * Should this failure step DOWN the ladder instead of reconnecting to the same
 * stream?
 *
 * - No rung left ⇒ never (fall through to the normal backoff/slow-retry ladder).
 * - A decoder/format error, or a known-deterministic failure signature
 *   ([isUnplayableFailureDetail]) ⇒ always, immediately, played or not: this is
 *   the device or the depacketizer saying outright that it cannot handle this
 *   stream, and every retry will land in the same place.
 * - The stream DID play and then dropped ⇒ never (bar the above). That is a
 *   camera reboot, an AP roam or a Wi-Fi drop, and downgrading would quietly
 *   strand a healthy camera on the transcode.
 * - A codec-agnostic failure before the first frame ⇒ only after
 *   [CODEC_AGNOSTIC_FAILURES_BEFORE_FALLBACK] of them in a row. #529 read *any*
 *   pre-first-frame failure as a codec verdict, so one Wi-Fi blip or one slow
 *   camera start pinned the camera to SD for the rest of the app run (#560);
 *   requiring the whole backoff curve to go by with nothing playing keeps the
 *   escape hatch without the false positives.
 * - Anything else before the first frame (the stall watchdog's silent BUFFERING
 *   spin, an unspecified error) ⇒ after
 *   [PRE_FIRST_FRAME_FAILURES_BEFORE_FALLBACK]. A stream that spins in BUFFERING
 *   without ever erroring is the classic undecodable signature, so the ladder
 *   still walks down — just on repeated evidence rather than the first timeout.
 *
 * @param errorCode Media3 `PlaybackException.errorCode`, or `null` when the
 *   failure came from the stall watchdog (which sees no exception at all).
 * @param failureDetail the exception chain summary from [failureDetail], if any.
 * @param preFirstFrameFailures this rung's [tallyPreFirstFrameFailure] count,
 *   including the failure being judged now.
 */
fun shouldFallBackToNextTier(
    hasNextTier: Boolean,
    everReady: Boolean,
    errorCode: Int?,
    failureDetail: String?,
    preFirstFrameFailures: Int,
): Boolean =
    when {
        !hasNextTier -> false
        errorCode != null && isUnplayableFormatError(errorCode) -> true
        isUnplayableFailureDetail(failureDetail) -> true
        everReady -> false
        errorCode != null && isCodecAgnosticError(errorCode) ->
            preFirstFrameFailures >= CODEC_AGNOSTIC_FAILURES_BEFORE_FALLBACK
        else -> preFirstFrameFailures >= PRE_FIRST_FRAME_FAILURES_BEFORE_FALLBACK
    }

/**
 * logcat tag for every fallback-ladder decision, on the wall and in fullscreen
 * alike. `adb logcat -s CrumbLiveFallback:I` shows exactly which rung a camera
 * left, which one it moved to, and what the evidence was — without it a step-down
 * is invisible and "my cameras went to SD" can only be guessed at (#560).
 */
const val FALLBACK_LOG_TAG = "CrumbLiveFallback"

/**
 * One line describing a fallback decision, in a format both the wall tile and
 * fullscreen emit so a logcat capture reads the same either way. Carries the
 * camera's id (a UUID, not an operator-visible name), the rungs, and the whole
 * basis for the call: the Media3 error code (or `none` when the stall watchdog
 * fired with no exception), whether the rung had ever played, and how many
 * pre-first-frame failures it has accumulated.
 */
fun fallbackLogLine(
    cameraId: String,
    from: StreamTier?,
    to: StreamTier?,
    steppedDown: Boolean,
    everReady: Boolean,
    errorCode: Int?,
    failureDetail: String?,
    preFirstFrameFailures: Int,
): String {
    val verb = if (steppedDown) "step down to ${to?.name ?: "?"}" else "hold"
    val code = errorCode?.let {
        val kind = when {
            isUnplayableFormatError(it) -> "format"
            isCodecAgnosticError(it) -> "retryable"
            else -> "other"
        }
        "$it/$kind"
    } ?: "none"
    val detail = failureDetail?.let {
        " detail=\"$it\"${if (isUnplayableFailureDetail(it)) " (known-unplayable)" else ""}"
    } ?: ""
    return "camera=$cameraId rung=${from?.name ?: "?"} $verb " +
        "errorCode=$code everReady=$everReady noFrameFailures=$preFirstFrameFailures$detail"
}

/** One line naming the rung a camera is about to attach to, and the ladder it sits in. */
fun attachLogLine(
    cameraId: String,
    surface: String,
    tier: StreamTier?,
    chain: List<StreamTier>,
    failed: Set<StreamTier>,
): String =
    "camera=$cameraId $surface attach rung=${tier?.name ?: "none"} " +
        "chain=[${chain.joinToString(",") { it.name }}] " +
        "skipped=[${chain.filter { it in failed }.joinToString(",") { it.name }}]"

/**
 * Text for the fullscreen "not on HD" badge, or `null` on the main stream (no
 * badge). Naming the transcode matters: "SD" on a camera whose sub is also
 * unplayable would otherwise read as an ordinary sub-stream downgrade, when in
 * fact the device is watching a server-side re-encode (#524).
 */
fun sdBadgeLabel(tier: StreamTier?): String? = when (tier) {
    // MAINV is a full-resolution repaired main — HD, so no badge, like MAIN.
    null, StreamTier.MAIN, StreamTier.MAINV -> null
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
 *
 * Verdicts additionally **expire** after [VERDICT_TTL_MS] (#560). A guess made
 * from a failure should not outlive the conditions that produced it: without a
 * TTL, one bad moment — a congested AP, a camera still booting, a server that
 * had not warmed the restream yet — pinned a camera to a lower rung until the
 * app was force-stopped. Re-testing the top rung costs at most one more walk down
 * the ladder, which is bounded and silent; being wrong for a whole day is not.
 */
object LiveStreamFallbackMemory {

    /**
     * How long a rung stays marked unplayable. Long enough that a session of
     * flipping between the wall and fullscreen never re-walks the ladder, short
     * enough that a wrong verdict heals itself while the operator is still
     * holding the phone.
     */
    const val VERDICT_TTL_MS = 10 * 60 * 1000L

    private val ttlNanos = VERDICT_TTL_MS * 1_000_000L

    /** Monotonic clock, swapped in tests. `nanoTime` because a verdict's age must
     *  not be affected by a wall-clock or timezone change. */
    internal var nanoTime: () -> Long = { System.nanoTime() }

    private val failedByCamera = HashMap<String, MutableMap<StreamTier, Long>>()

    /** Rungs known to be unplayable for [cameraId], minus any whose verdict aged out. */
    @Synchronized
    fun failedTiers(cameraId: String): Set<StreamTier> {
        val marks = failedByCamera[cameraId] ?: return emptySet()
        val now = nanoTime()
        marks.entries.retainAll { now - it.value < ttlNanos }
        if (marks.isEmpty()) {
            failedByCamera.remove(cameraId)
            return emptySet()
        }
        return marks.keys.toSet()
    }

    /** Record that [tier] never produced a playable frame for [cameraId]. */
    @Synchronized
    fun markFailed(cameraId: String, tier: StreamTier) {
        failedByCamera.getOrPut(cameraId) { mutableMapOf() }[tier] = nanoTime()
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
