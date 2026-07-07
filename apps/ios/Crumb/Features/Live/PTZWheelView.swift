// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct PTZWheelView: View {

    let onMove: (Float, Float) -> Void
    let onStop: () -> Void
    let onHome: () -> Void
    let onZoom: (Float) -> Void
    let onZoomStop: () -> Void

    private let wheelSize: CGFloat = 140

    var body: some View {
        HStack(spacing: 16) {
            // Joystick wheel
            ZStack {
                Canvas { ctx, size in
                    let r = size.width / 2
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)

                    // Ring background
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: 0, y: 0, width: size.width, height: size.height)),
                        with: .color(.black.opacity(0.45))
                    )
                    var ring = Path()
                    ring.addEllipse(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                    ctx.stroke(ring, with: .color(.white.opacity(0.5)), lineWidth: 2.5)

                    // Directional chevrons
                    let cr = r * 0.62
                    let cs = r * 0.16
                    let chevronColor = CrumbColors.tealAccent

                    func drawChevron(apex: CGPoint, direction: Int) {
                        var p = Path()
                        switch direction {
                        case 0: // up
                            p.move(to: CGPoint(x: apex.x, y: apex.y - cs))
                            p.addLine(to: CGPoint(x: apex.x - cs, y: apex.y + cs))
                            p.move(to: CGPoint(x: apex.x, y: apex.y - cs))
                            p.addLine(to: CGPoint(x: apex.x + cs, y: apex.y + cs))
                        case 1: // down
                            p.move(to: CGPoint(x: apex.x, y: apex.y + cs))
                            p.addLine(to: CGPoint(x: apex.x - cs, y: apex.y - cs))
                            p.move(to: CGPoint(x: apex.x, y: apex.y + cs))
                            p.addLine(to: CGPoint(x: apex.x + cs, y: apex.y - cs))
                        case 2: // left
                            p.move(to: CGPoint(x: apex.x - cs, y: apex.y))
                            p.addLine(to: CGPoint(x: apex.x + cs, y: apex.y - cs))
                            p.move(to: CGPoint(x: apex.x - cs, y: apex.y))
                            p.addLine(to: CGPoint(x: apex.x + cs, y: apex.y + cs))
                        default: // right
                            p.move(to: CGPoint(x: apex.x + cs, y: apex.y))
                            p.addLine(to: CGPoint(x: apex.x - cs, y: apex.y - cs))
                            p.move(to: CGPoint(x: apex.x + cs, y: apex.y))
                            p.addLine(to: CGPoint(x: apex.x - cs, y: apex.y + cs))
                        }
                        ctx.stroke(p, with: .color(chevronColor.opacity(0.95)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }

                    drawChevron(apex: CGPoint(x: c.x, y: c.y - cr), direction: 0)
                    drawChevron(apex: CGPoint(x: c.x, y: c.y + cr), direction: 1)
                    drawChevron(apex: CGPoint(x: c.x - cr, y: c.y), direction: 2)
                    drawChevron(apex: CGPoint(x: c.x + cr, y: c.y), direction: 3)
                }
                .frame(width: wheelSize, height: wheelSize)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let center = CGPoint(x: wheelSize / 2, y: wheelSize / 2)
                            let radius = wheelSize / 2
                            let innerR = radius * 0.34

                            let dist = hypot(value.location.x - center.x, value.location.y - center.y)
                            if dist <= innerR { return }

                            let dx = Float((value.location.x - center.x) / radius)
                            let dy = Float(-(value.location.y - center.y) / radius)
                            onMove(
                                max(-1, min(1, dx)),
                                max(-1, min(1, dy))
                            )
                        }
                        .onEnded { _ in
                            onStop()
                        }
                )

                // Center home button
                Button(action: onHome) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
            }

            // Zoom buttons
            VStack(spacing: 8) {
                PressHoldButton(
                    icon: "plus",
                    onPress: { onZoom(1) },
                    onRelease: onZoomStop
                )
                PressHoldButton(
                    icon: "minus",
                    onPress: { onZoom(-1) },
                    onRelease: onZoomStop
                )
            }
        }
    }
}

private struct PressHoldButton: View {
    let icon: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(.black.opacity(0.45)))
            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2.5))
            .gesture(
                DragGesture(minimumDistance: 0)
                    // Fire onPress ONCE on press-down, not on every drag tick.
                    .onChanged { _ in if !pressed { pressed = true; onPress() } }
                    .onEnded { _ in pressed = false; onRelease() }
            )
    }
}
