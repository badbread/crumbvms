// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import kotlin.math.max

/**
 * Reactive live-wall decode-load signal + the two-stage shed/restore controller
 * (issue #384, the Android sibling of the desktop #382 policy).
 *
 * ## Why this exists
 * The live wall decodes N RTSP tiles through Media3 -> MediaCodec. On a weaker
 * mobile SoC (a tablet or an Android TV wall), enough concurrent tiles
 * over-subscribe the hardware decoder or push the SoC into thermal throttling —
 * dropped frames, black tiles, stutter. The cameras themselves are shielded
 * (go2rtc pulls each once and fans out), so this is a purely client-local
 * resource cliff. The desktop client already sampled whole-GPU decode util and
 * keyed off it; Android exposes no such single number, so this class *builds* the
 * signal from Android-native sources and applies the same policy.
 *
 * ## Signal (highest to lowest priority)
 * 1. **Dropped frames** — each live tile attaches a Media3 `AnalyticsListener`
 *    whose `onDroppedVideoFrames` deltas are fed to [reportDroppedVideoFrames].
 *    This is the direct "frames are being dropped" evidence and is available
 *    whenever any tile is decoding. Aggregated across all tiles.
 * 2. **Thermal** — [PowerManager.getThermalHeadroom] (API 30+) plus an
 *    [PowerManager.OnThermalStatusChangedListener] (API 29+, cached in
 *    [latestThermalStatus]); mobile SoCs throttle decode under thermal pressure
 *    well before frames visibly drop, so this is the leading indicator on phones.
 * 3. **CPU fallback** — process CPU utilization from `/proc/self/stat`, used only
 *    when neither of the above produced a sample (e.g. no tiles decoding yet on a
 *    pre-API-29 device). We never assume unmeasurable headroom.
 *
 * The three are folded into a single 0..1 `load` (max of whatever is available,
 * CPU only as a last resort), EMA-smoothed over ~3s to ride keyframe bursts.
 *
 * ## Policy (mirrors #382; thresholds/timings/shed-order are shared)
 * - **Shed** when smoothed load stays above [SHED_LINE] (0.85) for
 *   [SHED_SUSTAIN_MS] (4s): downgrade ONE peripheral tile from RTSP video to the
 *   still-frame snapshot path (Android's next quality tier down, since the wall is
 *   already on the sub stream). Shed-fast.
 * - **Restore** when smoothed load stays below [RESTORE_LINE] (0.60) for
 *   [RESTORE_SUSTAIN_MS] (20s): promote one shed tile back to video. Restore-slow.
 * - The 0.60/0.85 gap + shed-fast / restore-slow timing is the hysteresis that
 *   prevents flapping.
 * - **Shed order** (last shed = most protected): off-screen tiles first, then the
 *   oldest-added / lowest wall-order tile, **never** the focused (single-camera)
 *   tile. A floor of [MIN_ACTIVE_TILES] video tiles is always kept.
 *
 * A shed tile carries the "SD"-style auto badge (see [LiveCameraTile]) and
 * self-restores silently. Everything here is client-local; nothing is persisted
 * and no server call is made.
 *
 * ## Threading
 * [reportDroppedVideoFrames] is called from ExoPlayer's callback threads and is
 * synchronized. [tick]/[updateTopology]/[start]/[stop]/[reset] are called from the
 * wall's main-thread Compose effects. The published [shedIds] is a [StateFlow].
 */
class WallDecodeMonitor(context: Context) {

    private val appContext = context.applicationContext
    private val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager

    // ── dropped-frame aggregation (across all live video tiles) ──────────────────

    private val dropLock = Any()
    private var droppedFramesAccum = 0L
    private var decodeElapsedMsAccum = 0L

    /**
     * Called from each tile's `AnalyticsListener.onDroppedVideoFrames`. [dropped]
     * is the number of frames dropped over [elapsedMs] of decode time for that
     * tile. Thread-safe (invoked on ExoPlayer callback threads).
     */
    fun reportDroppedVideoFrames(dropped: Int, elapsedMs: Long) {
        if (dropped <= 0 || elapsedMs <= 0) return
        synchronized(dropLock) {
            droppedFramesAccum += dropped
            decodeElapsedMsAccum += elapsedMs
        }
    }

    /** Drain the accumulated drop rate as a 0..1 load, or null if no decode time
     *  was reported this window (no active video tiles). */
    private fun drainDropLoad(): Float? {
        val dropped: Long
        val elapsed: Long
        synchronized(dropLock) {
            dropped = droppedFramesAccum
            elapsed = decodeElapsedMsAccum
            droppedFramesAccum = 0L
            decodeElapsedMsAccum = 0L
        }
        if (elapsed <= 0L) return null
        // Average dropped frames-per-second across the pool's tile-seconds.
        val droppedPerSec = dropped * 1000.0 / elapsed
        return (droppedPerSec / DROPPED_FPS_AT_FULL_LOAD).toFloat().coerceIn(0f, 1f)
    }

    // ── thermal ──────────────────────────────────────────────────────────────────

    @Volatile private var latestThermalStatus: Int = -1
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null

    /** Thermal pressure as 0..1, or null when the platform exposes nothing usable. */
    private fun thermalLoad(): Float? {
        val pm = powerManager ?: return null
        // getThermalHeadroom (API 30+): 0.0 = cool, 1.0 = at the throttling
        // threshold. NaN when the device can't forecast — fall through to status.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val hr = try {
                pm.getThermalHeadroom(THERMAL_FORECAST_SECONDS)
            } catch (_: Throwable) {
                Float.NaN
            }
            if (!hr.isNaN()) return hr.coerceIn(0f, 1f)
        }
        // THERMAL_STATUS_* (API 29+), kept fresh by the registered listener.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val status = if (latestThermalStatus >= 0) latestThermalStatus else {
                try { pm.currentThermalStatus } catch (_: Throwable) { -1 }
            }
            return when (status) {
                PowerManager.THERMAL_STATUS_NONE -> 0.0f
                PowerManager.THERMAL_STATUS_LIGHT -> 0.35f
                PowerManager.THERMAL_STATUS_MODERATE -> 0.60f
                PowerManager.THERMAL_STATUS_SEVERE -> 0.85f
                -1 -> null
                else -> 1.0f // CRITICAL / EMERGENCY / SHUTDOWN
            }
        }
        return null
    }

    // ── CPU fallback (process utilization from /proc/self/stat) ──────────────────

    private val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
    private var lastCpuTicks = -1L
    private var lastCpuWallMs = 0L

    /** Last-resort CPU load as 0..1, or null if it can't be measured this tick. */
    private fun cpuLoad(): Float? {
        return try {
            // `comm` (field 2) can contain spaces and parentheses; everything after
            // the final ')' is the stable, space-delimited tail starting at `state`.
            val raw = File("/proc/self/stat").readText()
            val rparen = raw.lastIndexOf(')')
            if (rparen < 0) return null
            val tail = raw.substring(rparen + 1).trim().split(Regex("\\s+"))
            // Post-`comm` index: state=0, ... utime=11, stime=12 (fields 14/15).
            val utime = tail.getOrNull(11)?.toLongOrNull() ?: return null
            val stime = tail.getOrNull(12)?.toLongOrNull() ?: return null
            val ticks = utime + stime
            val nowMs = SystemClock.elapsedRealtime()
            if (lastCpuTicks < 0L) {
                lastCpuTicks = ticks
                lastCpuWallMs = nowMs
                return null // need a delta first
            }
            val dTicks = ticks - lastCpuTicks
            val dWallMs = nowMs - lastCpuWallMs
            lastCpuTicks = ticks
            lastCpuWallMs = nowMs
            if (dWallMs <= 0L) return null
            val cpuSec = dTicks.toDouble() / CLOCK_TICKS_PER_SEC
            val load = cpuSec / (dWallMs / 1000.0 * cores)
            load.toFloat().coerceIn(0f, 1f)
        } catch (_: Throwable) {
            null
        }
    }

    /** Combined instantaneous load: max(dropped, thermal), CPU only as a fallback. */
    private fun currentLoad(): Float? {
        // Always drain the drop accumulator so it doesn't stale across ticks.
        val drop = drainDropLoad()
        val thermal = thermalLoad()
        val primary = when {
            drop != null && thermal != null -> max(drop, thermal)
            drop != null -> drop
            thermal != null -> thermal
            else -> null
        }
        return primary ?: cpuLoad()
    }

    // ── shed/restore state machine ────────────────────────────────────────────────

    private val _shedIds = MutableStateFlow<Set<String>>(emptySet())
    /** Camera ids currently shed to the still-frame path. Observed by the wall. */
    val shedIds: StateFlow<Set<String>> = _shedIds.asStateFlow()

    private var smoothedLoad = 0f
    private var overMs = 0L
    private var underMs = 0L

    // Topology, pushed by the wall each layout/scroll change.
    @Volatile private var orderedIds: List<String> = emptyList()
    @Volatile private var offscreenIds: Set<String> = emptySet()
    @Volatile private var focusedId: String? = null

    // Insertion order == shed order, so restore is LIFO (last shed comes back first).
    private val shedOrder = LinkedHashSet<String>()

    /**
     * Update the wall topology so shedding respects on-screen/order/focus. Called
     * from the wall whenever the shown set, scroll position, or focus changes.
     * Also prunes shed entries for cameras that left the wall.
     */
    fun updateTopology(ordered: List<String>, offscreen: Set<String>, focused: String?) {
        orderedIds = ordered
        offscreenIds = offscreen
        focusedId = focused
        val present = ordered.toHashSet()
        if (shedOrder.retainAll(present)) publish()
    }

    /**
     * Advance the controller by [tickMs] of elapsed time. Reads the current load,
     * smooths it, and sheds/restores one tile when the sustained-threshold timers
     * fire. A no-op when no signal is available (holds the current state).
     */
    fun tick(tickMs: Long) {
        val raw = currentLoad() ?: return
        smoothedLoad += LOAD_EMA_ALPHA * (raw - smoothedLoad)
        when {
            smoothedLoad >= SHED_LINE -> { overMs += tickMs; underMs = 0L }
            smoothedLoad <= RESTORE_LINE -> { underMs += tickMs; overMs = 0L }
            else -> { overMs = 0L; underMs = 0L } // hysteresis band: hold steady
        }
        if (overMs >= SHED_SUSTAIN_MS) {
            overMs = 0L
            shedOne()
        } else if (underMs >= RESTORE_SUSTAIN_MS) {
            underMs = 0L
            restoreOne()
        }
    }

    /** Shed one peripheral tile: off-screen first, then earliest wall-order, never
     *  the focused tile, keeping at least [MIN_ACTIVE_TILES] video tiles. */
    private fun shedOne() {
        val activeCount = orderedIds.count { it !in shedOrder }
        if (activeCount <= MIN_ACTIVE_TILES) return
        val candidates = orderedIds.filter { it != focusedId && it !in shedOrder }
        if (candidates.isEmpty()) return
        val pick = candidates.firstOrNull { it in offscreenIds } ?: candidates.first()
        shedOrder.add(pick)
        publish()
    }

    /** Restore the most-recently-shed tile (LIFO), so the wall recovers gradually. */
    private fun restoreOne() {
        val last = shedOrder.lastOrNull() ?: return
        shedOrder.remove(last)
        publish()
    }

    private fun publish() {
        _shedIds.value = shedOrder.toSet()
    }

    /** Clear all shed state (e.g. the feature was turned off, or the wall dropped to
     *  wall-wide low-bandwidth mode where every tile is already a still). */
    fun reset() {
        smoothedLoad = 0f
        overMs = 0L
        underMs = 0L
        lastCpuTicks = -1L
        synchronized(dropLock) {
            droppedFramesAccum = 0L
            decodeElapsedMsAccum = 0L
        }
        if (shedOrder.isNotEmpty()) {
            shedOrder.clear()
            publish()
        }
    }

    // ── lifecycle (thermal listener registration) ────────────────────────────────

    /** Register the thermal-status listener. Idempotent. Call when the wall is
     *  foregrounded; pair with [stop]. Guarded to API 29+. */
    fun start() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val pm = powerManager ?: return
        if (thermalListener != null) return
        val l = PowerManager.OnThermalStatusChangedListener { status ->
            latestThermalStatus = status
        }
        try {
            pm.addThermalStatusListener(l)
            thermalListener = l
            latestThermalStatus = try { pm.currentThermalStatus } catch (_: Throwable) { -1 }
        } catch (_: Throwable) {
            thermalListener = null
        }
    }

    /** Remove the thermal-status listener. Idempotent; safe to call any time. */
    fun stop() {
        val l = thermalListener ?: return
        thermalListener = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            powerManager?.removeThermalStatusListener(l)
        } catch (_: Throwable) {
            // ignore
        }
    }

    companion object {
        /** Shed above this smoothed load; mirrors desktop's 85% shed line. */
        private const val SHED_LINE = 0.85f
        /** Restore below this smoothed load; mirrors desktop's 60% restore line. */
        private const val RESTORE_LINE = 0.60f
        /** Shed-fast: load must hold above the shed line this long (ms). */
        private const val SHED_SUSTAIN_MS = 4_000L
        /** Restore-slow: load must hold below the restore line this long (ms). */
        private const val RESTORE_SUSTAIN_MS = 20_000L
        /** EMA factor at the ~2s control tick, giving a ~3s smoothing window. */
        private const val LOAD_EMA_ALPHA = 0.5f
        /** Average dropped frames-per-second (per tile-second) mapped to load 1.0. */
        private const val DROPPED_FPS_AT_FULL_LOAD = 6.0
        /** Thermal-headroom forecast horizon (s); must be within [0, 60]. */
        private const val THERMAL_FORECAST_SECONDS = 10
        /** Never shed below this many live video tiles. */
        private const val MIN_ACTIVE_TILES = 2
        /** Standard Linux USER_HZ on Android (`sysconf(_SC_CLK_TCK)`). */
        private const val CLOCK_TICKS_PER_SEC = 100L

        /** The control-loop tick used by the wall (kept here so the wall and the
         *  smoothing constant above stay in sync). */
        const val WALL_TICK_MS = 2_000L

        /**
         * Stage-1 guardrail: warn when this many live video tiles would render at
         * once. A conservative COUNT budget, not the resolution-weighted budget the
         * desktop uses — the Android client is not sent per-camera stream resolution
         * (see #384), so it can't weight by 4K-vs-1080p without a server change.
         * The runtime shedder ([tick]) is the real safety net; this is the advisory
         * heads-up that fires first, before anything saturates.
         */
        const val GUARDRAIL_TILE_BUDGET = 12
    }
}
