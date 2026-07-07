// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A locally-saved Live-wall **view**: a named, ordered subset of cameras, with an
/// optional custom pane layout (desktop-style).
///
/// Device-local only — persisted in UserDefaults as JSON, never synced to the
/// server. Mirrors the Kotlin `CameraView` data class in the Android client; the
/// optional `layout` is a macOS/desktop addition (older views and the iOS/Android
/// clients leave it nil and render `cameraIds` in a uniform grid).
///
/// - `id`: Stable local identifier (random UUID string).
/// - `name`: Display label shown on the view chip.
/// - `cameraIds`: Camera ids in display order. Ids no longer present on the
///   server are skipped when rendering, so deleting a camera can't break a
///   saved view. For a custom-layout view this mirrors the assigned cameras.
/// - `layout`: Optional custom pane layout. nil = uniform grid.
struct CameraView: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var cameraIds: [String]
    var layout: ViewLayout?

    init(id: String = UUID().uuidString, name: String, cameraIds: [String], layout: ViewLayout? = nil) {
        self.id = id
        self.name = name
        self.cameraIds = cameraIds
        self.layout = layout
    }
}

// MARK: - Custom layout

/// A custom wall layout: an `cols`×`rows` grid carved into rectangular panes, each
/// pane optionally bound to a camera. Faithful to the Tauri desktop client's view
/// layout (panes are `{x,y,w,h}` rects; cameras map to panes by sorted reading
/// order). Widget pane types (clock/web/text/…) are intentionally not modelled here.
struct ViewLayout: Codable, Hashable {
    var cols: Int
    var rows: Int
    /// Panes in reading order (top→bottom, left→right). Always tile the grid with
    /// no gaps or overlaps.
    var cells: [LayoutCell]
    /// Camera id per pane, parallel to `cells` (nil = empty pane).
    var slots: [String?]
    /// Optional per-view glyph (an SF Symbol name).
    var icon: String?

    init(cols: Int, rows: Int, cells: [LayoutCell], slots: [String?], icon: String? = nil) {
        self.cols = cols
        self.rows = rows
        self.cells = cells
        self.slots = slots
        self.icon = icon
    }

    /// Reading-order comparator used to keep `cells`/`slots` canonical.
    static func readingOrder(_ a: LayoutCell, _ b: LayoutCell) -> Bool {
        a.y != b.y ? a.y < b.y : a.x < b.x
    }
}

/// One rectangular pane: top-left at `(x, y)`, spanning `w`×`h` grid cells.
struct LayoutCell: Codable, Hashable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
}

// MARK: - Presets

extension ViewLayout {
    static let maxDim = 8

    /// A plain `cols`×`rows` grid of unit panes.
    static func grid(cols: Int, rows: Int) -> ViewLayout {
        let c = max(1, min(cols, maxDim))
        let r = max(1, min(rows, maxDim))
        var cells: [LayoutCell] = []
        for y in 0..<r {
            for x in 0..<c {
                cells.append(LayoutCell(x: x, y: y, w: 1, h: 1))
            }
        }
        return ViewLayout(cols: c, rows: r, cells: cells, slots: Array(repeating: nil, count: cells.count))
    }

    /// Big 2×2 hero (top-left) + five singles — the desktop "1+5".
    static var onePlusFive: ViewLayout {
        let cells = [
            LayoutCell(x: 0, y: 0, w: 2, h: 2),
            LayoutCell(x: 2, y: 0, w: 1, h: 1),
            LayoutCell(x: 2, y: 1, w: 1, h: 1),
            LayoutCell(x: 0, y: 2, w: 1, h: 1),
            LayoutCell(x: 1, y: 2, w: 1, h: 1),
            LayoutCell(x: 2, y: 2, w: 1, h: 1),
        ]
        return ViewLayout(cols: 3, rows: 3, cells: cells, slots: Array(repeating: nil, count: cells.count))
    }

    /// Full-width hero on top + a row of four — the desktop "Hero+row".
    static var heroBottom: ViewLayout {
        let cells = [
            LayoutCell(x: 0, y: 0, w: 4, h: 2),
            LayoutCell(x: 0, y: 2, w: 1, h: 1),
            LayoutCell(x: 1, y: 2, w: 1, h: 1),
            LayoutCell(x: 2, y: 2, w: 1, h: 1),
            LayoutCell(x: 3, y: 2, w: 1, h: 1),
        ]
        return ViewLayout(cols: 4, rows: 3, cells: cells, slots: Array(repeating: nil, count: cells.count))
    }
}
