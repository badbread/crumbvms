// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

// MARK: - PTZEdgesView

/// commercial-VMS-style PTZ controls with directional arrows pinned to the edges of
/// the camera view, and a Zoom +/− + Home cluster at the bottom-right.
///
/// This is an alternative to `PTZWheelView`. Both share the same callback API so
/// the parent can switch between them without changing call sites.
///
/// Interaction model (identical to the Android `PtzEdgeControls`):
/// - **Press and hold** an arrow → calls `onMove` with a fixed ±0.6 velocity.
/// - **Release** → calls `onStop`.
/// - **Home** button: press-then-release fires `onHome`.
/// - **Zoom +/−**: press → `onZoom(±1)`, release → `onZoomStop`.
///
/// The view fills its parent so the centre of the camera feed stays free for
/// pinch-to-zoom; only the button areas capture touches.
///
/// ```swift
/// PTZEdgesView(
///     onMove:     { pan, tilt in viewModel.ptzMove(pan: pan, tilt: tilt) },
///     onStop:     { viewModel.ptzStop() },
///     onHome:     { viewModel.ptzHome() },
///     onZoom:     { speed in viewModel.ptzZoom(speed) },
///     onZoomStop: { viewModel.ptzZoomStop() }
/// )
/// .ignoresSafeArea()
/// ```
struct PTZEdgesView: View {

    let onMove:     (Float, Float) -> Void
    let onStop:     () -> Void
    let onHome:     () -> Void
    let onZoom:     (Float) -> Void
    let onZoomStop: () -> Void

    private let velocity: Float = 0.6

    var body: some View {
        ZStack {
            // ── Up ────────────────────────────────────────────────────────────
            EdgeArrow(systemName: "chevron.up",
                      accessibilityLabel: "Tilt up",
                      onPress: { onMove(0,  velocity) },
                      onRelease: onStop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 72)

            // ── Down ──────────────────────────────────────────────────────────
            EdgeArrow(systemName: "chevron.down",
                      accessibilityLabel: "Tilt down",
                      onPress: { onMove(0, -velocity) },
                      onRelease: onStop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)

            // ── Left ──────────────────────────────────────────────────────────
            EdgeArrow(systemName: "chevron.left",
                      accessibilityLabel: "Pan left",
                      onPress: { onMove(-velocity, 0) },
                      onRelease: onStop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 14)

            // ── Right ─────────────────────────────────────────────────────────
            EdgeArrow(systemName: "chevron.right",
                      accessibilityLabel: "Pan right",
                      onPress: { onMove(velocity, 0) },
                      onRelease: onStop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 14)

            // ── Zoom + Home cluster (bottom-right) ────────────────────────────
            VStack(spacing: 8) {
                EdgeArrow(systemName: "plus",
                          accessibilityLabel: "Zoom in",
                          onPress: { onZoom(1) },
                          onRelease: onZoomStop)
                EdgeArrow(systemName: "minus",
                          accessibilityLabel: "Zoom out",
                          onPress: { onZoom(-1) },
                          onRelease: onZoomStop)
                // Home fires on release (same as Android ZoomButton onRelease = onHome).
                EdgeArrow(systemName: "house.fill",
                          accessibilityLabel: "PTZ home",
                          onPress: {},
                          onRelease: onHome)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 14)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Private edge button

/// A 44 pt circular button with a translucent black fill and white icon.
/// Fires `onPress` on touch-down and `onRelease` on touch-up.
private struct EdgeArrow: View {
    let systemName: String
    let accessibilityLabel: String
    let onPress: () -> Void
    let onRelease: () -> Void

    /// Tracks whether `onPress` has already been fired for the current touch
    /// so we call it exactly once per gesture, even as `onChanged` repeats.
    @State private var pressing = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 2.5))
            .accessibilityLabel(accessibilityLabel)
            // DragGesture(minimumDistance:0) fires onChanged immediately on
            // touch-down and onEnded on lift, giving us press-hold semantics
            // without UIKit gesture recognizers.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        onPress()
                    }
                    .onEnded { _ in
                        pressing = false
                        onRelease()
                    }
            )
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ZStack {
        CrumbColors.background.ignoresSafeArea()
        PTZEdgesView(
            onMove:     { _, _ in },
            onStop:     {},
            onHome:     {},
            onZoom:     { _ in },
            onZoomStop: {}
        )
    }
}
#endif
