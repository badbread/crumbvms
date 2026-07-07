// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

// MARK: - Constants

private let heatmapMotionGreen = Color(red: 0.157, green: 0.824, blue: 0.353)
private let gridLineColor = Color.white.opacity(0.12)
private let exclusionRed = Color.red

// MARK: - MotionTunerView

/// Full-screen sheet for per-camera motion detection tuning:
/// - Polling still-frame backdrop (every 2s, no blank flash)
/// - Canvas heatmap overlay with live motion cells (green→red by intensity)
/// - Exclusion-zone editor (tap to toggle, drag to box-select a region)
/// - Motion meter: live score vs threshold floor
/// - Source picker (pixel / Frigate) and pixel algorithm picker
/// - Sensitivity toggle (Auto / Manual) and threshold slider
/// - Grid resolution presets
/// - Save / Cancel buttons, greyed-out until dirty
struct MotionTunerView: View {

    @StateObject private var vm: MotionTunerViewModel
    let onClose: () -> Void

    // Frame poller state — held here so we can swap only on ready decode.
    @State private var frameImage: PlatformImage?
    @State private var framePollTask: Task<Void, Never>?

    // Exclusion-zone editor interaction.
    @State private var addMode = true
    @State private var dragAnchor: (gx: Int, gy: Int)?
    @State private var dragCur: (gx: Int, gy: Int)?

    init(container: AppContainer, cameraId: String, onClose: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: MotionTunerViewModel(container: container, cameraId: cameraId))
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            CrumbColors.background.ignoresSafeArea()

            if let cam = vm.camera {
                ScrollView {
                    VStack(spacing: 0) {
                        topBar(cam: cam)
                        stageSection(cam: cam)
                        motionMeter
                        sourceSection
                        thresholdSection
                        gridPresetsSection
                        maskEditSection
                        saveSection
                        if let err = vm.error {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(CrumbColors.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                        }
                        Spacer(minLength: 24)
                    }
                }
            } else if vm.error != nil {
                loadErrorView
            } else {
                ProgressView()
                    .tint(CrumbColors.teal)
            }
        }
        .task { await vm.onAppear() }
        .onDisappear {
            vm.onDisappear()
            stopFramePoller()
        }
        .onChange(of: vm.camera?.id) { newId in
            stopFramePoller()
            if newId != nil { startFramePoller(container: vm.container) }
        }
        .macModalSize(width: 720, height: 720)
    }

    // MARK: - Top bar

    private func topBar(cam: CameraDto) -> some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(CrumbColors.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(CrumbColors.surface)
                    .clipShape(Circle())
            }
            .disabled(vm.isSaving)

            Text("Motion Tuner")
                .font(.headline)
                .foregroundColor(CrumbColors.textPrimary)

            Text("·")
                .foregroundColor(CrumbColors.textTertiary)

            Text(cam.name)
                .font(.subheadline)
                .foregroundColor(CrumbColors.textSecondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Stage: frame + heatmap canvas

    private func stageSection(cam: CameraDto) -> some View {
        GeometryReader { geo in
            let stageWidth = geo.size.width
            let stageHeight = stageWidth * 9 / 16
            ZStack {
                Color.black

                // Still-frame backdrop. Held in @State so the previous frame
                // remains visible during the ~100-400ms each new fetch takes.
                if let img = frameImage {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: stageWidth, height: stageHeight)
                        .clipped()
                }

                // Heatmap + exclusion-zone canvas overlay.
                HeatmapCanvas(
                    grid: vm.grid,
                    excluded: vm.excluded,
                    maskCols: vm.maskCols,
                    maskRows: vm.maskRows,
                    addMode: addMode,
                    dragAnchor: dragAnchor,
                    dragCur: dragCur
                )
                .frame(width: stageWidth, height: stageHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .local)
                        .onChanged { value in
                            let xFrac = value.location.x / stageWidth
                            let yFrac = value.location.y / stageHeight
                            let cell = cellAt(xFrac: xFrac, yFrac: yFrac, cols: vm.maskCols, rows: vm.maskRows)
                            if dragAnchor == nil { dragAnchor = cell }
                            dragCur = cell
                        }
                        .onEnded { value in
                            if let a = dragAnchor, let b = dragCur {
                                let x0 = min(a.gx, b.gx); let x1 = max(a.gx, b.gx)
                                let y0 = min(a.gy, b.gy); let y1 = max(a.gy, b.gy)
                                vm.applyBoxRegion(x0: x0, y0: y0, x1: x1, y1: y1, add: addMode)
                            }
                            dragAnchor = nil; dragCur = nil
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .local)
                        .onEnded { value in
                            // Only fire tap when there's no ongoing drag.
                            guard dragAnchor == nil else { return }
                            let xFrac = value.location.x / stageWidth
                            let yFrac = value.location.y / stageHeight
                            let (gx, gy) = cellAt(xFrac: xFrac, yFrac: yFrac, cols: vm.maskCols, rows: vm.maskRows)
                            vm.toggleCell(gx: gx, gy: gy, add: addMode)
                        }
                )
            }
            .frame(width: stageWidth, height: stageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .task(id: vm.camera?.id) {
            guard let _ = vm.camera else { return }
            startFramePoller(container: vm.container)
        }
    }

    // MARK: - Motion meter

    private var motionMeter: some View {
        MotionMeterView(
            scoreFrac: vm.grid?.score,
            floorFrac: vm.displayFloor,
            isAuto: vm.sensitivity == "dynamic"
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Source picker

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Detection source")
            HStack(spacing: 8) {
                chipButton("Pixel", selected: vm.motionSource != "frigate") {
                    vm.setMotionSource("pixel")
                }
                chipButton("Frigate", selected: vm.motionSource == "frigate") {
                    vm.setMotionSource("frigate")
                }
            }

            if vm.motionSource != "frigate" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Algorithm")
                            .font(.caption)
                            .foregroundColor(CrumbColors.textSecondary)
                        ForEach(motionAlgorithms, id: \.id) { algo in
                            chipButton(algo.label, selected: vm.motionAlgorithm == algo.id) {
                                vm.setMotionAlgorithm(algo.id)
                            }
                        }
                    }
                }
            } else {
                Text("Recording is triggered by Frigate detections — the pixel detector, threshold, and exclusions below are inactive.")
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Threshold section

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Motion threshold")

            // Auto toggle
            HStack {
                Text("Auto (dynamic)")
                    .font(.subheadline)
                    .foregroundColor(CrumbColors.textSecondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vm.sensitivity == "dynamic" },
                    set: { auto in vm.setSensitivity(auto ? "dynamic" : "manual") }
                ))
                .labelsHidden()
                .tint(CrumbColors.teal)
            }

            // Threshold slider (enabled only in manual mode)
            let thrPct = (vm.threshold * 100).clamped(to: 0.05...5)
            HStack(spacing: 10) {
                Text("Min size")
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)
                Slider(
                    value: Binding(
                        get: { Double(thrPct) },
                        set: { v in
                            vm.setThreshold(Float(v) / 100)
                            if vm.sensitivity == "dynamic" { vm.setSensitivity("manual") }
                        }
                    ),
                    in: 0.05...5
                )
                .tint(CrumbColors.tealAccent)
                .disabled(vm.sensitivity == "dynamic")
                .opacity(vm.sensitivity == "dynamic" ? 0.4 : 1)

                Text(String(format: "%.2f%%", thrPct))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(CrumbColors.textPrimary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Grid presets

    private var gridPresetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Exclusion grid")
            HStack(spacing: 8) {
                ForEach(motionGridPresets, id: \.cols) { preset in
                    chipButton("\(preset.cols)×\(preset.rows)", selected: vm.maskCols == preset.cols && vm.maskRows == preset.rows) {
                        vm.changeGrid(newCols: preset.cols, newRows: preset.rows)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Mask edit controls

    private var maskEditSection: some View {
        HStack(spacing: 10) {
            chipButton("Exclude", icon: "paintbrush", selected: addMode) { addMode = true }
            chipButton("Erase", icon: "eraser", selected: !addMode) { addMode = false }
            Spacer()
            Button("Clear all") {
                vm.clearMask()
            }
            .font(.subheadline)
            .foregroundColor(CrumbColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(CrumbColors.surfaceVariant)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Save / cancel

    private var saveSection: some View {
        HStack(spacing: 10) {
            if vm.isDirty {
                Button("Cancel") {
                    vm.cancelChanges()
                }
                .font(.subheadline)
                .foregroundColor(CrumbColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(CrumbColors.surfaceVariant)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Button(action: {
                Task { await vm.save() }
            }) {
                HStack(spacing: 6) {
                    if vm.isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.black)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(vm.isSaving ? "Saving…" : "Save")
                        .font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .foregroundColor(.black)
            .background(vm.isDirty ? CrumbColors.teal : CrumbColors.surfaceVariant)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(!vm.isDirty || vm.isSaving)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.15), value: vm.isDirty)
    }

    // MARK: - Load error

    private var loadErrorView: some View {
        VStack(spacing: 16) {
            Text(vm.error ?? "Failed to load camera.")
                .foregroundColor(CrumbColors.error)
                .multilineTextAlignment(.center)
            Button("Close", action: onClose)
                .foregroundColor(CrumbColors.textSecondary)
        }
        .padding(24)
    }

    // MARK: - Frame poller

    private func startFramePoller(container: AppContainer) {
        stopFramePoller()
        let mediaUrls = container.mediaUrls()
        let cameraId = vm.cameraId
        framePollTask = Task {
            var cacheBust = 0
            while !Task.isCancelled {
                // Re-resolved every poll rather than reusing one URL: the
                // scoped media token behind it is only valid ~15 min, and this
                // poller can run far longer than that while the tuner sheet
                // stays open. `MediaTokenCache` makes the common case (token
                // still fresh) a cheap in-memory hit, so this costs nothing
                // extra beyond the occasional real mint.
                if let frameURL = await mediaUrls.cameraFrameUrl(cameraId) {
                    var components = URLComponents(url: frameURL, resolvingAgainstBaseURL: false)
                    var items = components?.queryItems ?? []
                    items.append(URLQueryItem(name: "cb", value: "\(cacheBust)"))
                    components?.queryItems = items
                    if let url = components?.url,
                       let (data, _) = try? await URLSession.crumbMedia.data(from: url),
                       let img = PlatformImage(data: data) {
                        frameImage = img
                    }
                }
                cacheBust += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopFramePoller() {
        framePollTask?.cancel()
        framePollTask = nil
    }

    // MARK: - Small helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(CrumbColors.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func chipButton(
        _ label: String,
        icon: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(label)
                    .font(.caption.bold())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? CrumbColors.teal : CrumbColors.surfaceVariant)
            .foregroundColor(selected ? .black : CrumbColors.textSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - HeatmapCanvas

/// Canvas that renders:
///  1. Live motion heatmap cells (green at low intensity → red at high)
///  2. Exclusion-zone cells (red semi-transparent fill + diagonal hatch)
///  3. Grid lines
///  4. Drag-preview selection rectangle
private struct HeatmapCanvas: View {

    let grid: MotionGridDto?
    let excluded: Set<Int>
    let maskCols: Int
    let maskRows: Int
    let addMode: Bool
    let dragAnchor: (gx: Int, gy: Int)?
    let dragCur: (gx: Int, gy: Int)?

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height

            // 1. Heatmap cells
            if let g = grid, g.cols > 0, g.rows > 0 {
                let hcw = w / CGFloat(g.cols)
                let hch = h / CGFloat(g.rows)
                for gy in 0..<g.rows {
                    for gx in 0..<g.cols {
                        let raw = g.cells[safe: gy * g.cols + gx] ?? 0
                        // intensity is in [0, 100]; normalize to [0, 1]
                        let intensity = (raw / 100).clamped(to: 0...1)
                        if intensity < 0.02 { continue }
                        let color = heatmapColor(intensity: intensity)
                        ctx.fill(
                            Path(CGRect(
                                x: CGFloat(gx) * hcw,
                                y: CGFloat(gy) * hch,
                                width: hcw,
                                height: hch
                            )),
                            with: .color(color)
                        )
                    }
                }
            }

            // 2. Exclusion cells
            let cw = w / CGFloat(maskCols)
            let ch = h / CGFloat(maskRows)
            for gy in 0..<maskRows {
                for gx in 0..<maskCols {
                    guard excluded.contains(cellKey(gx: gx, gy: gy)) else { continue }
                    let x = CGFloat(gx) * cw
                    let y = CGFloat(gy) * ch
                    // Red fill
                    ctx.fill(
                        Path(CGRect(x: x, y: y, width: cw, height: ch)),
                        with: .color(exclusionRed.opacity(0.30))
                    )
                    // Diagonal hatch line (bottom-left to top-right)
                    var hatch = Path()
                    hatch.move(to: CGPoint(x: x, y: y + ch))
                    hatch.addLine(to: CGPoint(x: x + cw, y: y))
                    ctx.stroke(hatch, with: .color(exclusionRed.opacity(0.75)), lineWidth: 1.2)
                }
            }

            // 3. Grid lines
            for gx in 1..<maskCols {
                var line = Path()
                let lx = CGFloat(gx) * cw
                line.move(to: CGPoint(x: lx, y: 0))
                line.addLine(to: CGPoint(x: lx, y: h))
                ctx.stroke(line, with: .color(gridLineColor), lineWidth: 0.5)
            }
            for gy in 1..<maskRows {
                var line = Path()
                let ly = CGFloat(gy) * ch
                line.move(to: CGPoint(x: 0, y: ly))
                line.addLine(to: CGPoint(x: w, y: ly))
                ctx.stroke(line, with: .color(gridLineColor), lineWidth: 0.5)
            }

            // 4. Drag preview
            if let a = dragAnchor, let b = dragCur {
                let x0 = CGFloat(min(a.gx, b.gx)) * cw
                let y0 = CGFloat(min(a.gy, b.gy)) * ch
                let x1 = CGFloat(max(a.gx, b.gx) + 1) * cw
                let y1 = CGFloat(max(a.gy, b.gy) + 1) * ch
                let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                let strokeColor: Color = addMode ? .white : CrumbColors.tealAccent
                if !addMode {
                    ctx.fill(Path(rect), with: .color(CrumbColors.tealAccent.opacity(0.18)))
                }
                ctx.stroke(Path(rect), with: .color(strokeColor), lineWidth: 2)
            }
        }
    }

    /// Linear interpolation from transparent green (0) → yellow (0.5) → red (1.0).
    private func heatmapColor(intensity: Float) -> Color {
        let t = CGFloat(intensity)
        if t <= 0.5 {
            // green → yellow
            let u = t / 0.5  // 0..1
            return Color(
                red: Double(u),
                green: 0.82,
                blue: 0,
                opacity: Double(0.35 + u * 0.25)  // 0.35..0.60
            )
        } else {
            // yellow → red
            let u = (t - 0.5) / 0.5  // 0..1
            return Color(
                red: 1,
                green: Double(0.82 * (1 - u)),
                blue: 0,
                opacity: Double(0.60 + u * 0.15)  // 0.60..0.75
            )
        }
    }
}

// MARK: - MotionMeterView

private struct MotionMeterView: View {

    let scoreFrac: Float?
    let floorFrac: Float?
    let isAuto: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let barW = geo.size.width

                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(CrumbColors.surfaceVariant)
                        .frame(height: 8)

                    if let score = scoreFrac, let floor = floorFrac {
                        let fullScale = max(0.001, floor * 4.5)
                        let fillFrac = CGFloat((score / fullScale).clamped(to: 0...1))
                        let markerFrac = CGFloat((floor / fullScale).clamped(to: 0...1))
                        let over = score >= floor

                        // Fill bar
                        RoundedRectangle(cornerRadius: 4)
                            .fill(over ? CrumbColors.error : CrumbColors.teal)
                            .frame(width: barW * fillFrac, height: 8)
                            .animation(.linear(duration: 0.2), value: fillFrac)

                        // Threshold marker line
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 2, height: 12)
                            .offset(x: barW * markerFrac - 1, y: -2)
                    }
                }
                .frame(height: 8)
            }
            .frame(height: 12)

            if let score = scoreFrac, let floor = floorFrac {
                let over = score >= floor
                let modeSuffix = isAuto ? " (auto)" : ""
                Text(String(format: "motion %.2f%%  ·  floor %.2f%%%@",
                            score * 100, floor * 100, modeSuffix))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(over ? CrumbColors.error : CrumbColors.textSecondary)
                    .animation(.none, value: over)
            } else {
                Text("waiting for recorder…")
                    .font(.caption)
                    .foregroundColor(CrumbColors.textTertiary)
            }
        }
    }
}

// MARK: - Utilities

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

private extension FloatingPoint {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
