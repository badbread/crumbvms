// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Tile quality rungs

/// The stream rung a wall tile decodes. `main` is full resolution (heaviest),
/// `sub` is the camera's low-res sub stream (light), `snapshot` is the ~1 fps
/// still path (no live decode at all). On Apple the wall baseline is already
/// sub-preferring (see `CameraTileView`), so the only rung below a live tile
/// with no sub stream is the snapshot still — there is no separate "main wall"
/// stream to drop off of, unlike the desktop client (#382). That asymmetry is
/// why reactive backpressure sheds `main -> sub` where a sub exists and
/// `main/sub -> snapshot` where it does not.
enum TileQuality: Equatable {
    case main
    case sub
    case snapshot
}

// MARK: - Guardrail nudge

/// A pending Stage-1 guardrail nudge (issue #383 / sibling of #382). Advisory
/// only: it never blocks the wall, it warns that the projected full-resolution
/// decode load would exceed this device's headroom before anything saturates.
struct WallGuardrailWarning: Identifiable, Equatable {
    let id = UUID()
    /// How many tiles would decode a full-resolution main stream.
    let mainTileCount: Int
    /// True when the heaviness is because the operator turned on the
    /// high-quality wall (so "Keep sub" can revert it); false when it is just an
    /// inherently heavy set of main-only cameras (nothing to revert).
    let revertable: Bool

    var message: String {
        let base = "This wall would run \(mainTileCount) full resolution "
            + "\(mainTileCount == 1 ? "stream" : "streams"), more than this device "
            + "can comfortably decode at once."
        if revertable {
            return base + " Keep the wall on the lighter sub stream and use "
                + "the fullscreen view for detail?"
        }
        return base + " Crumb will automatically lighten the least important "
            + "tiles if the device gets too warm."
    }
}

// MARK: - Controller

/// Adaptive live-wall quality for the Apple client (iOS / iPadOS / macOS).
///
/// Ports the shared two-stage policy from #382 (the desktop sibling) to
/// Apple-native signals, since VideoToolbox exposes no NVML-style decode-util %:
///
///  * **Stage 1, guardrail (preventive, config time):** a resolution-weighted
///    count projection. Each tile that would decode a main stream is weighted
///    heavier than a sub tile; if the projected load crosses ~75% of this
///    device's decode budget, `warning` is published so the wall can show a
///    dismissible nudge. Advisory, never blocks.
///  * **Stage 2, backpressure (reactive, runtime):** driven primarily by
///    `ProcessInfo.processInfo.thermalState` (the real SoC-over-budget signal on
///    fanless iPads / Macs), with aggregate CPU utilisation as a fallback when
///    thermalState stays uninformative. `.serious` begins shedding, `.critical`
///    sheds aggressively, and a return to `.nominal` restores, all with the same
///    shed-fast / restore-slow hysteresis discipline as #382 (shed after a 4s
///    hold, restore only after a 20s calm, one tile at a time).
///
/// All thresholds are client-local (a phone and an M-series Mac have very
/// different budgets) and both stages are user-toggleable, defaulting on.
@MainActor
final class WallLoadController: ObservableObject {

    /// Tiles the reactive net has currently downgraded (shed). Observed by the
    /// wall so each tile recomputes its effective quality and shows the "SD"
    /// badge. Restores clear silently.
    @Published private(set) var shedCameraIds: Set<String> = []

    /// A pending guardrail nudge, or `nil`. The wall binds an alert to this.
    @Published var warning: WallGuardrailWarning?

    private let settings: AppSettings

    /// One entry per visible wall tile, in wall order. `heavy` == would decode a
    /// full-resolution main stream (either the high-quality wall is on, or the
    /// camera has no sub stream to fall back to).
    private struct WallTile { let id: String; let heavy: Bool }
    private var wall: [WallTile] = []
    private var focusedId: String?

    // Reactive shedding state.
    /// Number of peripheral tiles currently shed (0 == none). Moved toward a
    /// thermal-derived target with directional rate limits (shed fast, restore
    /// slow) so the wall never flaps between quality rungs.
    private var shedCount = 0
    private var pressureSince: Date?
    private var calmSince: Date?
    private var lastRestoreAt: Date?
    private let cpu = CpuLoadSampler()

    // Guardrail bookkeeping: fire once per distinct heavy composition so a
    // static heavy wall nags exactly once, not every re-render.
    private var lastWarnedSignature: String?

    private var tickTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // Timing / threshold constants (client-local; the "60/85 + 4s/20s" of #382
    // re-expressed against thermalState bands).
    private let tickInterval: UInt64 = 3_000_000_000 // 3s
    private let shedHold: TimeInterval = 4           // sustain pressure before first shed
    private let restoreHold: TimeInterval = 20       // sustain calm before restoring
    private let restoreStep: TimeInterval = 5        // min gap between restores
    private let mainWeight = 3.5                      // a main tile ~= 3.5 sub tiles of decode
    private let guardrailCeiling = 0.75              // warn above 75% of budget
    /// CPU fallback high-water mark: only consulted when thermalState is
    /// uninformative (`.nominal` / `.fair`) so a well-cooled Mac that never
    /// reports thermal pressure still gets a reactive net.
    private let cpuHighWater = 0.85

    init(settings: AppSettings) {
        self.settings = settings
        // PRIMARY signal: react immediately to thermal transitions (the tick
        // loop also re-reads thermalState, but the notification makes a spike
        // actionable without waiting up to a full tick).
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.tick() } }
            .store(in: &cancellables)
    }

    /// Feed the current visible wall composition. Recomputes the shed set (so it
    /// tracks a changed camera list) and runs the Stage-1 guardrail projection.
    func configure(cameras: [(id: String, hasSub: Bool)], focusedId: String?) {
        let high = settings.wallHighQuality
        wall = cameras.map { WallTile(id: $0.id, heavy: high || !$0.hasSub) }
        self.focusedId = focusedId
        recomputeShedSet()
        runGuardrail()
        startTicking()
    }

    /// Stop the reactive loop (wall disappeared).
    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Effective quality (pure; shared by the wall's tile builders)

    /// The rung a tile should actually decode, folding together the user's
    /// wall-quality choice, low-bandwidth mode, and any reactive shed.
    ///
    /// Base rung: low-bandwidth forces snapshots for everything; otherwise the
    /// high-quality wall forces main, and the default wall prefers sub when the
    /// camera has one (matching the pre-existing tile behaviour). A shed drops
    /// that rung one step: `main -> sub` when a sub exists, else `-> snapshot`.
    static func effectiveQuality(hasSub: Bool, highQuality: Bool,
                                 lowBandwidth: Bool, degraded: Bool) -> TileQuality {
        if lowBandwidth { return .snapshot }
        let base: TileQuality = highQuality ? .main : (hasSub ? .sub : .main)
        guard degraded else { return base }
        switch base {
        case .main:     return hasSub ? .sub : .snapshot
        case .sub:      return .snapshot
        case .snapshot: return .snapshot
        }
    }

    // MARK: - Stage 1: guardrail projection

    private func deviceDecodeBudget() -> Double {
        // Sub-tile-equivalents this device can decode at ~100%. Deliberately
        // conservative on mobile: iPads and phones have weaker decoders and
        // tighter thermal ceilings than an M-series Mac (issue #383). Tunable;
        // client-local by design.
        #if os(macOS)
        return 18
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 10 : 6
        #endif
    }

    private func runGuardrail() {
        guard settings.wallDecodeGuardrail, !settings.guardrailSuppressed else { return }
        let mainCount = wall.filter(\.heavy).count
        // Resolution-weighted count projection: main tiles cost `mainWeight`
        // sub-equivalents each (Apple exposes no per-stream decode cost, and the
        // viewer camera payload carries no per-camera resolution, so main-vs-sub
        // is the resolution proxy — a main stream is the camera's full-res feed).
        let projected = Double(mainCount) * mainWeight
            + Double(wall.count - mainCount)
        let ceiling = guardrailCeiling * deviceDecodeBudget()
        guard projected > ceiling, mainCount > 0 else {
            // Not heavy (any more) — clear the "already warned" latch so a later
            // heavy composition warns afresh.
            lastWarnedSignature = nil
            return
        }
        let signature = "\(wall.count)|\(mainCount)|\(settings.wallHighQuality)"
        guard signature != lastWarnedSignature, warning == nil else { return }
        lastWarnedSignature = signature
        warning = WallGuardrailWarning(mainTileCount: mainCount,
                                       revertable: settings.wallHighQuality)
    }

    // MARK: - Stage 2: reactive backpressure

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(nanoseconds: self.tickInterval)
            }
        }
    }

    private func tick() {
        guard settings.adaptiveWallQuality else {
            // Feature off: make sure nothing stays shed.
            if shedCount != 0 { shedCount = 0; recomputeShedSet() }
            pressureSince = nil; calmSince = nil
            return
        }

        let thermal = ProcessInfo.processInfo.thermalState
        // CPU fallback is only consulted when thermalState is uninformative
        // (a well-cooled Mac can peg the decoder while still reporting nominal).
        let cpuBusy = cpu.sample() ?? 0
        let cpuHigh = cpuBusy >= cpuHighWater

        let sheddable = sheddableCount()
        let target = targetShed(for: thermal, cpuHigh: cpuHigh, sheddable: sheddable)
        let now = Date()

        if target > shedCount {
            // Rising: require sustained pressure before the first shed, then
            // step in (aggressively under `.critical`).
            calmSince = nil
            if pressureSince == nil { pressureSince = now }
            if now.timeIntervalSince(pressureSince!) >= shedHold {
                let step = (thermal == .critical) ? (target - shedCount) : 1
                shedCount = min(shedCount + step, target)
                recomputeShedSet()
            }
        } else if target < shedCount {
            // Falling: restore slowly, and only after a calm hold, one tile at a
            // time, aborting the moment pressure returns (handled by re-entry).
            pressureSince = nil
            if calmSince == nil { calmSince = now }
            if now.timeIntervalSince(calmSince!) >= restoreHold,
               lastRestoreAt == nil || now.timeIntervalSince(lastRestoreAt!) >= restoreStep {
                shedCount -= 1
                lastRestoreAt = now
                recomputeShedSet()
            }
        } else {
            // Hold (hysteresis band, e.g. thermal `.fair`): neither grow nor
            // shrink, so the wall does not flap around the threshold.
            pressureSince = nil
        }
    }

    /// Target shed level for a thermal band. `.fair` holds (returns the current
    /// level) so the serious<->fair boundary does not oscillate.
    private func targetShed(for thermal: ProcessInfo.ThermalState,
                            cpuHigh: Bool, sheddable: Int) -> Int {
        switch thermal {
        case .critical: return sheddable                 // shed everything peripheral
        case .serious:  return (sheddable + 1) / 2       // begin shedding (~half)
        case .fair:     return cpuHigh ? (sheddable + 1) / 2 : shedCount
        case .nominal:  return cpuHigh ? (sheddable + 1) / 2 : 0
        @unknown default: return shedCount
        }
    }

    /// Peripheral tiles eligible to shed: everything except the focused tile and
    /// the leading (most-visible / primary) tile, which are never shed.
    private func sheddableOrder() -> [String] {
        guard !wall.isEmpty else { return [] }
        var protected: Set<String> = []
        if let focusedId { protected.insert(focusedId) }
        protected.insert(wall[0].id) // keep the primary tile live
        // Shed order: end-of-wall first. True on/off-screen state is not cheap
        // to observe inside a LazyVGrid, so trailing wall order is the
        // off-screen proxy (later tiles scroll below the fold first); leading
        // tiles (the primary view area) are preserved.
        return Array(wall.map(\.id).filter { !protected.contains($0) }.reversed())
    }

    private func sheddableCount() -> Int { sheddableOrder().count }

    private func recomputeShedSet() {
        let order = sheddableOrder()
        shedCount = max(0, min(shedCount, order.count))
        shedCameraIds = Set(order.prefix(shedCount))
    }
}

// MARK: - CPU load sampler (fallback signal)

/// Aggregate system CPU utilisation from successive `host_statistics`
/// (`HOST_CPU_LOAD_INFO`) snapshots. Cumulative tick counters, so the first
/// sample only primes the baseline and returns `nil`; subsequent samples return
/// the busy fraction (0...1) since the previous call. Cross-platform (iOS +
/// macOS) via the Mach host port.
final class CpuLoadSampler {
    private var previous: (busy: UInt64, total: UInt64)?

    func sample() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // cpu_ticks indices: 0 user, 1 system, 2 idle, 3 nice.
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice
        let total = busy &+ idle
        defer { previous = (busy, total) }
        guard let prev = previous else { return nil }
        let dBusy = Double(busy &- prev.busy)
        let dTotal = Double(total &- prev.total)
        guard dTotal > 0 else { return nil }
        return max(0, min(1, dBusy / dTotal))
    }
}
