// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

// MARK: - HintTooltip

/// Wraps content in a long-press gesture (~0.6 s) that shows a brief text hint
/// in a black-translucent capsule overlay. The hint auto-dismisses after 2 s or
/// immediately on the next tap.
///
/// Usage:
/// ```swift
/// HintTooltip("Export footage") {
///     Image(systemName: "square.and.arrow.up")
/// }
/// ```
struct HintTooltip<Content: View>: View {
    let hint: String
    let content: Content

    @State private var isVisible = false
    @State private var dismissTask: Task<Void, Never>?

    init(_ hint: String, @ViewBuilder content: () -> Content) {
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        content
            .overlay(alignment: .top) {
                if isVisible {
                    TooltipCapsule(text: hint)
                        .offset(y: -36)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .zIndex(1)
                }
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.6)
                    .onEnded { _ in showTooltip() }
            )
            .onTapGesture {
                if isVisible { hideTooltip() }
            }
    }

    // MARK: Helpers

    private func showTooltip() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { isVisible = true }
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { hideTooltip() }
        }
    }

    private func hideTooltip() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.easeIn(duration: 0.12)) { isVisible = false }
    }
}

// MARK: - Capsule bubble

private struct TooltipCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.75))
                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
            )
            .fixedSize()
            .allowsHitTesting(false)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ZStack {
        CrumbColors.background.ignoresSafeArea()
        HStack(spacing: 24) {
            HintTooltip("Fullscreen") {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title2)
                    .foregroundColor(CrumbColors.tealAccent)
                    .frame(width: 44, height: 44)
            }
            HintTooltip("Export footage") {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2)
                    .foregroundColor(CrumbColors.tealAccent)
                    .frame(width: 44, height: 44)
            }
        }
    }
}
#endif
