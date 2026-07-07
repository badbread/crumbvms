// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Lays out a `ViewLayout`'s panes inside the available space — each pane sized
/// and positioned from its `{x,y,w,h}` grid rect (SwiftUI has no CSS-grid spans,
/// so frames are computed from the column/row unit size). The `pane` builder gets
/// the pane's slot index and its resolved camera (nil = empty pane). Shared by the
/// live wall and the layout editor's live preview.
struct CustomLayoutContainer<Pane: View>: View {
    let layout: ViewLayout
    let cameras: [CameraDto]
    var spacing: CGFloat = 4
    @ViewBuilder let pane: (Int, CameraDto?) -> Pane

    var body: some View {
        GeometryReader { geo in
            let cols = CGFloat(max(layout.cols, 1))
            let rows = CGFloat(max(layout.rows, 1))
            let cw = geo.size.width / cols
            let ch = geo.size.height / rows
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.cells.enumerated()), id: \.offset) { idx, cell in
                    pane(idx, camera(at: idx))
                        .frame(
                            width: max(cw * CGFloat(cell.w) - spacing, 1),
                            height: max(ch * CGFloat(cell.h) - spacing, 1)
                        )
                        .offset(
                            x: cw * CGFloat(cell.x) + spacing / 2,
                            y: ch * CGFloat(cell.y) + spacing / 2
                        )
                }
            }
        }
    }

    private func camera(at idx: Int) -> CameraDto? {
        guard idx < layout.slots.count, let id = layout.slots[idx] else { return nil }
        return cameras.first { $0.id == id }
    }
}
