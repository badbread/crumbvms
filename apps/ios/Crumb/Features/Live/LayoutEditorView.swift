// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Desktop-style custom **layout** editor: build an N×M grid, merge panes into
/// larger boxes, and assign a camera to each pane. Faithful to the Tauri desktop
/// client's View Setup dialog (camera panes only). Produces a `CameraView` with a
/// `ViewLayout`. macOS-only entry point; iOS keeps the simpler `ViewEditorView`.
struct LayoutEditorView: View {

    let allCameras: [CameraDto]
    let onSave: (CameraView) -> Void
    let onDelete: (String) -> Void
    let onDismiss: () -> Void

    private let viewId: String
    private let isEditing: Bool

    @State private var name: String
    @State private var iconName: String?
    @State private var cols: Int
    @State private var rows: Int
    @State private var cells: [LayoutCell]
    /// "x,y" pane top-left → camera id.
    @State private var assign: [String: String]
    @State private var mode: Mode = .arrange
    @State private var selection: Set<String> = []

    private enum Mode: Hashable { case arrange, editLayout }

    private static let iconChoices = [
        "house", "building.2", "car", "tree", "person.2", "video",
        "shield.lefthalf.filled", "mappin.and.ellipse", "moon.stars", "sun.max",
    ]

    init(existing: CameraView?,
         allCameras: [CameraDto],
         onSave: @escaping (CameraView) -> Void,
         onDelete: @escaping (String) -> Void,
         onDismiss: @escaping () -> Void) {
        self.allCameras = allCameras
        self.onSave = onSave
        self.onDelete = onDelete
        self.onDismiss = onDismiss

        if let v = existing {
            viewId = v.id
            isEditing = true
            _name = State(initialValue: v.name)
            if let lay = v.layout {
                _iconName = State(initialValue: lay.icon)
                _cols = State(initialValue: lay.cols)
                _rows = State(initialValue: lay.rows)
                _cells = State(initialValue: lay.cells.sorted(by: ViewLayout.readingOrder))
                var a: [String: String] = [:]
                for (i, c) in lay.cells.enumerated() where i < lay.slots.count {
                    if let id = lay.slots[i] { a["\(c.x),\(c.y)"] = id }
                }
                _assign = State(initialValue: a)
            } else {
                // Seed a square-ish grid from a simple view's ordered cameras.
                let n = max(v.cameraIds.count, 1)
                let c = min(max(Int(ceil(Double(n).squareRoot())), 1), ViewLayout.maxDim)
                let r = min(max(Int(ceil(Double(n) / Double(c))), 1), ViewLayout.maxDim)
                _iconName = State(initialValue: nil)
                _cols = State(initialValue: c)
                _rows = State(initialValue: r)
                let grid = ViewLayout.grid(cols: c, rows: r).cells
                _cells = State(initialValue: grid)
                var a: [String: String] = [:]
                for (i, cam) in v.cameraIds.enumerated() where i < grid.count {
                    a["\(grid[i].x),\(grid[i].y)"] = cam
                }
                _assign = State(initialValue: a)
            }
        } else {
            viewId = UUID().uuidString
            isEditing = false
            _name = State(initialValue: "")
            _iconName = State(initialValue: nil)
            _cols = State(initialValue: 2)
            _rows = State(initialValue: 2)
            _cells = State(initialValue: ViewLayout.grid(cols: 2, rows: 2).cells)
            _assign = State(initialValue: [:])
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !assign.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(CrumbColors.divider)
                controls
                Divider().overlay(CrumbColors.divider)
                gridCanvas
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(CrumbColors.background)
            .navigationTitle(isEditing ? "Edit View" : "New View")
            .navBarInline()
            .navBarSurfaceBackground(CrumbColors.surface)
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Button("Cancel") { onDismiss() }.foregroundColor(CrumbColors.tealAccent)
                }
                ToolbarItem(placement: .barTrailing) {
                    Button("Save") { onSave(build()) }
                        .foregroundColor(canSave ? CrumbColors.tealAccent : CrumbColors.textTertiary)
                        .disabled(!canSave)
                }
            }
        }
        .macModalSize(width: 780, height: 720)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header (name + icon + delete)

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                Button { iconName = nil } label: { Label("No icon", systemImage: "nosign") }
                ForEach(Self.iconChoices, id: \.self) { sym in
                    Button { iconName = sym } label: { Label(sym, systemImage: sym) }
                }
            } label: {
                Image(systemName: iconName ?? "square.grid.2x2")
                    .font(.system(size: 16))
                    .foregroundColor(CrumbColors.tealAccent)
                    .frame(width: 36, height: 36)
                    .background(CrumbColors.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            TextField("View name", text: $name)
                .textFieldStyle(.plain)
                .font(.headline)
                .foregroundColor(CrumbColors.textPrimary)
                .padding(10)
                .background(CrumbColors.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))

            if isEditing {
                Button(role: .destructive) { onDelete(viewId) } label: {
                    Image(systemName: "trash").foregroundColor(CrumbColors.error)
                }
                .buttonStyle(.plain)
                .help("Delete view")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Controls (dims, presets, mode)

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                stepper("Columns", value: cols) { setDims(cols: $0, rows: rows) }
                stepper("Rows", value: rows) { setDims(cols: cols, rows: $0) }
                Spacer()
                Picker("", selection: $mode) {
                    Text("Arrange").tag(Mode.arrange)
                    Text("Edit layout").tag(Mode.editLayout)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            HStack(spacing: 8) {
                Text("Presets").font(.caption).foregroundColor(CrumbColors.textSecondary)
                presetButton("2×2") { applyPreset(.grid(cols: 2, rows: 2)) }
                presetButton("3×3") { applyPreset(.grid(cols: 3, rows: 3)) }
                presetButton("4×4") { applyPreset(.grid(cols: 4, rows: 4)) }
                presetButton("1+5") { applyPreset(.onePlusFive) }
                presetButton("Hero+row") { applyPreset(.heroBottom) }
                Spacer()
                if mode == .editLayout {
                    Button { mergeSelection() } label: {
                        Label("Merge", systemImage: "rectangle.compress.vertical")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(selection.count >= 2 ? CrumbColors.tealAccent : CrumbColors.textTertiary)
                    .disabled(selection.count < 2)
                }
            }

            if mode == .editLayout {
                Text("Tap unit panes to select, then Merge. Tap a merged pane to split it back.")
                    .font(.caption2)
                    .foregroundColor(CrumbColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func stepper(_ label: String, value: Int, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundColor(CrumbColors.textSecondary)
            Button { set(value - 1) } label: { Image(systemName: "minus") }
                .buttonStyle(.plain).foregroundColor(CrumbColors.textPrimary).disabled(value <= 1)
            Text("\(value)").font(.body.monospacedDigit()).frame(width: 18)
                .foregroundColor(CrumbColors.textPrimary)
            Button { set(value + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundColor(CrumbColors.textPrimary).disabled(value >= ViewLayout.maxDim)
        }
    }

    private func presetButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(CrumbColors.surfaceVariant, in: Capsule())
                .foregroundColor(CrumbColors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid canvas

    private var gridCanvas: some View {
        GeometryReader { geo in
            let cw = geo.size.width / CGFloat(max(cols, 1))
            let ch = geo.size.height / CGFloat(max(rows, 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(cells.sorted(by: ViewLayout.readingOrder).enumerated()), id: \.offset) { idx, cell in
                    pane(idx: idx, cell: cell)
                        .frame(width: max(cw * CGFloat(cell.w) - 6, 1), height: max(ch * CGFloat(cell.h) - 6, 1))
                        .offset(x: cw * CGFloat(cell.x) + 3, y: ch * CGFloat(cell.y) + 3)
                }
            }
        }
        .aspectRatio(CGFloat(max(cols, 1)) / CGFloat(max(rows, 1)) * (9.0 / 16.0), contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pane(idx: Int, cell: LayoutCell) -> some View {
        let key = cellKey(cell)
        let merged = cell.w > 1 || cell.h > 1
        if mode == .arrange {
            Menu {
                Button("Empty") { assign[key] = nil }
                Divider()
                ForEach(allCameras) { cam in
                    Button(cam.name) { assign[key] = cam.id }
                }
            } label: {
                paneVisual(idx: idx, key: key, merged: merged, selected: false)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
        } else {
            Button {
                if merged { split(cell) } else { toggleSelect(key) }
            } label: {
                paneVisual(idx: idx, key: key, merged: merged, selected: selection.contains(key))
            }
            .buttonStyle(.plain)
        }
    }

    private func paneVisual(idx: Int, key: String, merged: Bool, selected: Bool) -> some View {
        let camName = assign[key].flatMap { id in allCameras.first { $0.id == id }?.name }
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? CrumbColors.teal.opacity(0.30)
                      : (camName != nil ? CrumbColors.surface : CrumbColors.surfaceVariant))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? CrumbColors.teal : CrumbColors.divider, lineWidth: selected ? 2 : 1)
                )
            VStack(spacing: 3) {
                if let camName {
                    Image(systemName: "video.fill").font(.caption).foregroundColor(CrumbColors.tealAccent)
                    Text(camName).font(.caption.weight(.medium)).foregroundColor(CrumbColors.textPrimary)
                        .lineLimit(2).multilineTextAlignment(.center)
                } else {
                    Text(mode == .arrange ? "Tap to assign" : (merged ? "Tap to split" : "Empty"))
                        .font(.caption2).foregroundColor(CrumbColors.textTertiary)
                }
            }
            .padding(6)
            Text("\(idx + 1)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(CrumbColors.textTertiary)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Mutations

    private func cellKey(_ cell: LayoutCell) -> String { "\(cell.x),\(cell.y)" }

    private func setDims(cols newCols: Int, rows newRows: Int) {
        let c = max(1, min(newCols, ViewLayout.maxDim))
        let r = max(1, min(newRows, ViewLayout.maxDim))
        cols = c; rows = r
        cells = ViewLayout.grid(cols: c, rows: r).cells
        assign = assign.filter { key, _ in
            let p = key.split(separator: ","); guard p.count == 2, let x = Int(p[0]), let y = Int(p[1]) else { return false }
            return x < c && y < r
        }
        selection.removeAll()
    }

    private func applyPreset(_ preset: ViewLayout) {
        cols = preset.cols; rows = preset.rows
        cells = preset.cells.sorted(by: ViewLayout.readingOrder)
        let tls = Set(cells.map { cellKey($0) })
        assign = assign.filter { tls.contains($0.key) }
        selection.removeAll()
    }

    private func toggleSelect(_ key: String) {
        if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
    }

    private func mergeSelection() {
        let selCells = cells.filter { selection.contains(cellKey($0)) }
        guard !selCells.isEmpty else { return }
        var minX = selCells.map(\.x).min()!
        var minY = selCells.map(\.y).min()!
        var maxX = selCells.map { $0.x + $0.w - 1 }.max()!
        var maxY = selCells.map { $0.y + $0.h - 1 }.max()!
        // Expand to cover any partially-intersecting cell (fixpoint).
        var changed = true
        while changed {
            changed = false
            for c in cells {
                let cx2 = c.x + c.w - 1, cy2 = c.y + c.h - 1
                let intersects = !(c.x > maxX || cx2 < minX || c.y > maxY || cy2 < minY)
                if intersects {
                    if c.x < minX { minX = c.x; changed = true }
                    if cx2 > maxX { maxX = cx2; changed = true }
                    if c.y < minY { minY = c.y; changed = true }
                    if cy2 > maxY { maxY = cy2; changed = true }
                }
            }
        }
        let keepCam = assign["\(minX),\(minY)"]
        cells.removeAll { c in
            let cx2 = c.x + c.w - 1, cy2 = c.y + c.h - 1
            return c.x >= minX && cx2 <= maxX && c.y >= minY && cy2 <= maxY
        }
        // Drop absorbed assignments (keep the top-left's).
        for key in Array(assign.keys) {
            let p = key.split(separator: ","); guard p.count == 2, let kx = Int(p[0]), let ky = Int(p[1]) else { continue }
            if kx >= minX, kx <= maxX, ky >= minY, ky <= maxY, !(kx == minX && ky == minY) {
                assign[key] = nil
            }
        }
        cells.append(LayoutCell(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1))
        if let keepCam { assign["\(minX),\(minY)"] = keepCam }
        cells.sort(by: ViewLayout.readingOrder)
        selection.removeAll()
    }

    private func split(_ cell: LayoutCell) {
        guard cell.w > 1 || cell.h > 1 else { return }
        let keepCam = assign[cellKey(cell)]
        cells.removeAll { $0 == cell }
        for y in cell.y..<(cell.y + cell.h) {
            for x in cell.x..<(cell.x + cell.w) {
                cells.append(LayoutCell(x: x, y: y, w: 1, h: 1))
            }
        }
        if let keepCam { assign["\(cell.x),\(cell.y)"] = keepCam }
        cells.sort(by: ViewLayout.readingOrder)
    }

    private func build() -> CameraView {
        let sorted = cells.sorted(by: ViewLayout.readingOrder)
        let slots = sorted.map { assign[cellKey($0)] }
        let camIds = slots.compactMap { $0 }
        let layout = ViewLayout(cols: cols, rows: rows, cells: sorted, slots: slots, icon: iconName)
        return CameraView(id: viewId, name: name.trimmingCharacters(in: .whitespaces), cameraIds: camIds, layout: layout)
    }
}
