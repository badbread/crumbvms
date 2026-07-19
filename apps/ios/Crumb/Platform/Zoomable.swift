// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

extension View {
    /// Makes a view zoomable/pannable. iOS: pinch to zoom, drag to pan, double-tap
    /// to reset. macOS: scroll-wheel to zoom, drag to pan, double-click to reset
    /// (a mouse can't pinch). Pan is clamped to the content edges.
    func zoomable(minZoom: CGFloat = 1, maxZoom: CGFloat = 6,
                  onZoomChange: ((CGFloat) -> Void)? = nil) -> some View {
        modifier(Zoomable(minZoom: minZoom, maxZoom: maxZoom, onZoomChange: onZoomChange))
    }

    /// Conditional variant — used where zoom must yield to another gesture (e.g.
    /// PTZ drag controls on PTZ cameras). `onZoomChange` reports the live scale
    /// (1 = not zoomed) so callers can, e.g., hide overlays that can't track a
    /// digital zoom.
    @ViewBuilder func zoomable(enabled: Bool, minZoom: CGFloat = 1, maxZoom: CGFloat = 6,
                               onZoomChange: ((CGFloat) -> Void)? = nil) -> some View {
        if enabled { zoomable(minZoom: minZoom, maxZoom: maxZoom, onZoomChange: onZoomChange) } else { self }
    }
}

private struct Zoomable: ViewModifier {
    let minZoom: CGFloat
    let maxZoom: CGFloat
    var onZoomChange: ((CGFloat) -> Void)? = nil

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var dragging = false

    func body(content: Content) -> some View {
        GeometryReader { geo in
            ZStack {
                content
                    .scaleEffect(zoom)
                    .offset(offset)
                    .onChange(of: zoom) { onZoomChange?($0) }
                #if os(macOS)
                ScrollPanCatcher(
                    onZoom: { delta in applyZoom(delta, size: geo.size) },
                    onPanBegan: { panStart = offset },
                    onPanChanged: { t in
                        offset = clamp(CGSize(width: panStart.width + t.width,
                                              height: panStart.height + t.height), size: geo.size)
                    },
                    onReset: reset
                )
                #endif
            }
            .clipped()
            .contentShape(Rectangle())
            #if os(iOS)
            .gesture(
                MagnificationGesture()
                    .onChanged { v in zoom = min(max(lastZoom * v, minZoom), maxZoom); offset = clamp(offset, size: geo.size) }
                    .onEnded { _ in lastZoom = zoom }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { v in
                        guard zoom > 1 else { return }
                        if !dragging { panStart = offset; dragging = true }
                        offset = clamp(CGSize(width: panStart.width + v.translation.width,
                                              height: panStart.height + v.translation.height), size: geo.size)
                    }
                    .onEnded { _ in dragging = false }
            )
            .onTapGesture(count: 2) { reset() }
            #endif
        }
    }

    private func applyZoom(_ delta: CGFloat, size: CGSize) {
        let next = zoom * (1 + delta / 120)
        zoom = min(max(next, minZoom), maxZoom)
        lastZoom = zoom
        offset = clamp(offset, size: size)
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1; lastZoom = 1; offset = .zero; panStart = .zero
        }
    }

    /// Clamp the pan offset so the scaled content can't be dragged past its edges.
    private func clamp(_ o: CGSize, size: CGSize) -> CGSize {
        let maxX = (zoom - 1) * size.width / 2
        let maxY = (zoom - 1) * size.height / 2
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }
}

#if os(macOS)
import AppKit

/// Transparent AppKit overlay reporting scroll-wheel (zoom), drag (pan), and
/// double-click (reset) to SwiftUI. macOS has no scroll-wheel SwiftUI hook.
private struct ScrollPanCatcher: NSViewRepresentable {
    let onZoom: (CGFloat) -> Void
    let onPanBegan: () -> Void
    let onPanChanged: (CGSize) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> CatcherView { configure(CatcherView()) }
    func updateNSView(_ v: CatcherView, context: Context) { _ = configure(v) }

    private func configure(_ v: CatcherView) -> CatcherView {
        v.onZoom = onZoom; v.onPanBegan = onPanBegan; v.onPanChanged = onPanChanged; v.onReset = onReset
        return v
    }

    final class CatcherView: NSView {
        var onZoom: (CGFloat) -> Void = { _ in }
        var onPanBegan: () -> Void = {}
        var onPanChanged: (CGSize) -> Void = { _ in }
        var onReset: () -> Void = {}
        private var startX: CGFloat = 0
        private var startY: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            if d != 0 { onZoom(d) }
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset(); return }
            let p = convert(event.locationInWindow, from: nil)
            startX = p.x; startY = p.y
            onPanBegan()
        }
        override func mouseDragged(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            // AppKit y is bottom-up; SwiftUI offset y is top-down → negate dy.
            onPanChanged(CGSize(width: p.x - startX, height: -(p.y - startY)))
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
#endif
