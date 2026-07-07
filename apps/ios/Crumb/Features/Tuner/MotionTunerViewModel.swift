// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Grid presets (cols × rows) matching the Android tuner and the recorder's supported sizes.
let motionGridPresets: [(cols: Int, rows: Int)] = [(8, 5), (16, 9), (24, 14), (32, 18)]

/// Pixel detector algorithm identifiers mapped to their short display labels.
let motionAlgorithms: [(id: String, label: String)] = [
    ("census", "Census"),
    ("framediff", "Diff"),
    ("mog2", "MOG2"),
    ("opticalflow", "Flow"),
    ("ensemble", "Ensemble"),
]

/// Drives `MotionTunerView`. Loads the camera's existing config, polls the live
/// motion-grid heatmap every second, and exposes editable sensitivity/threshold/mask
/// state with a dirty-flag gating the Save button.
@MainActor
final class MotionTunerViewModel: ObservableObject {

    // MARK: - Immutable camera info (set once on load)

    @Published private(set) var camera: CameraDto?

    // MARK: - Live heatmap (read-only, polled)

    @Published private(set) var grid: MotionGridDto?

    // MARK: - Editable state (dirty when different from the loaded baseline)

    @Published var sensitivity: String = "dynamic"
    @Published var threshold: Float = 0.003
    @Published var motionSource: String = "pixel"
    @Published var motionAlgorithm: String = "census"

    /// Exclusion cells for the current grid resolution. Keys are `gy * 64 + gx`.
    @Published var excluded: Set<Int> = []
    @Published var maskCols: Int = 16
    @Published var maskRows: Int = 9

    // MARK: - Dirty tracking

    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    @Published var error: String?

    // Baseline values captured on load; used to reset and to detect dirtiness.
    private var baselineSensitivity: String = "dynamic"
    private var baselineThreshold: Float = 0.003
    private var baselineMotionSource: String = "pixel"
    private var baselineMotionAlgorithm: String = "census"
    private var baselineExcluded: Set<Int> = []
    private var baselineMaskCols: Int = 16
    private var baselineMaskRows: Int = 9

    // MARK: - Polling tasks

    private var gridPollTask: Task<Void, Never>?

    // MARK: - Dependencies

    let container: AppContainer
    let cameraId: String

    init(container: AppContainer, cameraId: String) {
        self.container = container
        self.cameraId = cameraId
    }

    // MARK: - Lifecycle

    func onAppear() async {
        await loadCamera()
        startGridPolling()
    }

    func onDisappear() {
        stopGridPolling()
    }

    // MARK: - Load

    func loadCamera() async {
        error = nil
        do {
            let list = try await container.api.cameras()
            guard let cam = list.first(where: { $0.id == cameraId }) else {
                error = "Camera not found."
                return
            }
            camera = cam

            // Populate editable fields from the loaded camera.
            let thr = cam.policy?.motionThreshold ?? 0.003
            let sens = cam.policy?.motionSensitivity ?? "dynamic"
            let src = cam.motionSource
            let alg = cam.motionAlgorithm
            let mask = cam.motionMask ?? []
            let excl = rectsToCells(mask, cols: maskCols, rows: maskRows)

            sensitivity = sens
            threshold = thr
            motionSource = src
            motionAlgorithm = alg
            excluded = excl

            // Record baseline for dirty detection / cancel.
            baselineSensitivity = sens
            baselineThreshold = thr
            baselineMotionSource = src
            baselineMotionAlgorithm = alg
            baselineExcluded = excl
            baselineMaskCols = maskCols
            baselineMaskRows = maskRows

            updateDirty()
        } catch {
            self.error = error.userMessage
        }
    }

    // MARK: - Grid polling

    func startGridPolling() {
        stopGridPolling()
        gridPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollGrid()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopGridPolling() {
        gridPollTask?.cancel()
        gridPollTask = nil
    }

    private func pollGrid() async {
        do {
            let g = try await container.api.motionGrid(cameraId: cameraId)
            if g.cols > 0 && g.rows > 0 {
                grid = g
            }
        } catch {
            // Best-effort: heatmap polling errors are silent.
        }
    }

    // MARK: - Dirty flag

    private func updateDirty() {
        isDirty = sensitivity != baselineSensitivity
            || threshold != baselineThreshold
            || motionSource != baselineMotionSource
            || motionAlgorithm != baselineMotionAlgorithm
            || excluded != baselineExcluded
            || maskCols != baselineMaskCols
            || maskRows != baselineMaskRows
    }

    // MARK: - State mutations (call updateDirty after each)

    func setSensitivity(_ s: String) {
        sensitivity = s
        updateDirty()
    }

    func setThreshold(_ t: Float) {
        threshold = t
        updateDirty()
    }

    func setMotionSource(_ src: String) {
        motionSource = src
        updateDirty()
    }

    func setMotionAlgorithm(_ alg: String) {
        motionAlgorithm = alg
        updateDirty()
    }

    func setExcluded(_ excl: Set<Int>) {
        excluded = excl
        updateDirty()
    }

    func toggleCell(gx: Int, gy: Int, add: Bool) {
        var next = excluded
        let k = cellKey(gx: gx, gy: gy)
        if add {
            if next.contains(k) { next.remove(k) } else { next.insert(k) }
        } else {
            next.remove(k)
        }
        excluded = next
        updateDirty()
    }

    func applyBoxRegion(x0: Int, y0: Int, x1: Int, y1: Int, add: Bool) {
        var next = excluded
        for gy in y0...y1 {
            for gx in x0...x1 {
                let k = cellKey(gx: gx, gy: gy)
                if add { next.insert(k) } else { next.remove(k) }
            }
        }
        excluded = next
        updateDirty()
    }

    func clearMask() {
        excluded = []
        updateDirty()
    }

    func changeGrid(newCols: Int, newRows: Int) {
        // Preserve painted area across grid resolution changes.
        let rects = cellsToMask(excluded, cols: maskCols, rows: maskRows)
        maskCols = newCols
        maskRows = newRows
        excluded = rectsToCells(rects, cols: newCols, rows: newRows)
        updateDirty()
    }

    // MARK: - Cancel

    func cancelChanges() {
        sensitivity = baselineSensitivity
        threshold = baselineThreshold
        motionSource = baselineMotionSource
        motionAlgorithm = baselineMotionAlgorithm
        excluded = baselineExcluded
        maskCols = baselineMaskCols
        maskRows = baselineMaskRows
        updateDirty()
    }

    // MARK: - Save

    /// Persists all pending changes in one go: policy (threshold/sensitivity),
    /// mask, and motion config (source/algorithm) as needed.
    func save() async {
        guard isDirty, !isSaving else { return }
        isSaving = true
        error = nil
        do {
            // 1. Policy: sensitivity + threshold.
            if sensitivity != baselineSensitivity || threshold != baselineThreshold {
                try await container.api.updatePolicy(
                    cameraId: cameraId,
                    body: UpdatePolicyRequest(motionSensitivity: sensitivity, motionThreshold: threshold)
                )
            }
            // 2. Exclusion mask.
            if excluded != baselineExcluded || maskCols != baselineMaskCols || maskRows != baselineMaskRows {
                let rects = cellsToMask(excluded, cols: maskCols, rows: maskRows)
                try await container.api.updateCameraMask(
                    cameraId: cameraId,
                    body: UpdateCameraMaskRequest(motionMask: rects)
                )
            }
            // 3. Motion source + algorithm.
            if motionSource != baselineMotionSource || motionAlgorithm != baselineMotionAlgorithm {
                try await container.api.updateCameraMotion(
                    cameraId: cameraId,
                    body: UpdateCameraMotionRequest(motionSource: motionSource, motionAlgorithm: motionAlgorithm)
                )
            }
            // Commit baseline.
            baselineSensitivity = sensitivity
            baselineThreshold = threshold
            baselineMotionSource = motionSource
            baselineMotionAlgorithm = motionAlgorithm
            baselineExcluded = excluded
            baselineMaskCols = maskCols
            baselineMaskRows = maskRows
            isDirty = false
        } catch {
            self.error = "Save failed: \(error.userMessage)"
        }
        isSaving = false
    }

    // MARK: - Derived helpers

    /// Effective motion floor to display in the meter.
    /// Dynamic: use the live recorder floor. Manual: use the pending threshold slider value.
    var displayFloor: Float? {
        if sensitivity == "dynamic" { return grid?.threshold }
        return threshold
    }
}

// MARK: - Geometry / mask helpers

/// Pack a cell coordinate into a single Int key.
func cellKey(gx: Int, gy: Int) -> Int { gy * 64 + gx }

/// Pointer fraction (0..1) → clamped cell coordinate.
func cellAt(xFrac: CGFloat, yFrac: CGFloat, cols: Int, rows: Int) -> (gx: Int, gy: Int) {
    let gx = Int(xFrac * CGFloat(cols)).clamped(0, cols - 1)
    let gy = Int(yFrac * CGFloat(rows)).clamped(0, rows - 1)
    return (gx, gy)
}

/// Normalized `[[x, y, w, h]]` rects → excluded cell keys (center-point test).
func rectsToCells(_ rects: [[Double]], cols: Int, rows: Int) -> Set<Int> {
    guard !rects.isEmpty else { return [] }
    var out = Set<Int>()
    for gy in 0..<rows {
        for gx in 0..<cols {
            let cx = (Double(gx) + 0.5) / Double(cols)
            let cy = (Double(gy) + 0.5) / Double(rows)
            for r in rects where r.count >= 4 {
                if cx >= r[0] && cx < r[0] + r[2] && cy >= r[1] && cy < r[1] + r[3] {
                    out.insert(cellKey(gx: gx, gy: gy))
                    break
                }
            }
        }
    }
    return out
}

/// Excluded cell keys → normalized `[[x, y, w, h]]` rects, merged into per-row runs.
func cellsToMask(_ excluded: Set<Int>, cols: Int, rows: Int) -> [[Double]] {
    var rects: [[Double]] = []
    for gy in 0..<rows {
        var runStart = -1
        for gx in 0...cols {
            let on = gx < cols && excluded.contains(cellKey(gx: gx, gy: gy))
            if on && runStart < 0 {
                runStart = gx
            } else if !on && runStart >= 0 {
                let w = gx - runStart
                rects.append([
                    Double(runStart) / Double(cols),
                    Double(gy) / Double(rows),
                    Double(w) / Double(cols),
                    1.0 / Double(rows),
                ])
                runStart = -1
            }
        }
    }
    return rects
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}
