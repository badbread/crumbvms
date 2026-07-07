// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Motion and detection clip feed.
///
/// Shows the last 24 hours of clips (configurable via `ClipsViewModel.windowHours`)
/// with a camera-filter chip row, pull-to-refresh, and tap-to-play in a full-screen
/// `ClipPlayerView` sheet. Clips are marked viewed on open.
struct ClipsView: View {

    @StateObject private var vm: ClipsViewModel
    @State private var playerItem: ClipDescriptor?
    #if os(macOS)
    /// Clip tile size on the desktop grid: 0 = small, 1 = medium, 2 = large.
    @AppStorage("clipTileSize") private var clipTileSize = 1
    #endif

    /// Camera IDs of the wall's active saved View, or nil for "All cameras".
    let viewCameraIds: [String]?
    /// iOS: clip-grid column count, driven by the wall's tile-size button
    /// (`settings.liveGridLayout`) so that control resizes clip tiles the same way
    /// it resizes the Live/Playback grids. `nil` on macOS, which sizes its clip
    /// grid from its own `clipTileSize` segmented picker instead.
    let gridColumns: Int?
    /// Opens playback for `(cameraId, date)` — the clip player's "View on timeline".
    let onOpenPlayback: ((String, Date) -> Void)?

    init(container: AppContainer, viewCameraIds: [String]?, gridColumns: Int? = nil, onOpenPlayback: ((String, Date) -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ClipsViewModel(container: container))
        self.viewCameraIds = viewCameraIds
        self.gridColumns = gridColumns
        self.onOpenPlayback = onOpenPlayback
    }

    var body: some View {
        ZStack {
            CrumbColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Camera filter chips (narrowed to the active View; shown once loaded).
                if !vm.chipCameras.isEmpty {
                    CameraFilterChips(
                        cameras: vm.chipCameras,
                        selectedId: vm.selectedCameraId,
                        onSelect: { vm.selectCamera($0) }
                    )
                    .padding(.vertical, 4)
                }

                // Type filter + lookback range (matches Android's clip filters).
                HStack(spacing: 6) {
                    kindChip("All", nil)
                    kindChip("Motion", "motion")
                    kindChip("Detections", "detection")
                    Spacer()
                    #if os(macOS)
                    Picker("", selection: $clipTileSize) {
                        Image(systemName: "square.grid.3x3").tag(0)
                        Image(systemName: "square.grid.2x2").tag(1)
                        Image(systemName: "rectangle").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 108)
                    .help("Tile size")
                    #endif
                    rangeMenu
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

                // Content area.
                Group {
                    if vm.isLoading && vm.clips.isEmpty {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(CrumbColors.tealAccent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                    } else if let errorMsg = vm.error {
                        ErrorStateView(message: errorMsg) {
                            Task { await vm.refresh() }
                        }

                    } else if vm.filteredClips.isEmpty {
                        EmptyStateView()

                    } else {
                        clipGrid
                    }
                }
            }
        }
        .navigationTitle("Clips")
        .navBarInline()
        // Runs on appear and whenever the active View changes — reloads the feed
        // restricted to the view's cameras so the View chips filter Clips too.
        .task(id: viewCameraIds) {
            vm.setViewFilter(viewCameraIds)
            await vm.load()
        }
        .refreshable { await vm.refresh() }
        .fullScreenCoverCompat(item: $playerItem) { clip in
            // Scoped media token: `ClipPlayerView` resolves its own video URL
            // (async, per-camera-scoped) via `.task(id: clip.id)` rather than
            // being handed a pre-built one here.
            ClipPlayerView(
                clip: clip,
                mediaUrls: vm.mediaUrls,
                highlightSeconds: vm.motionHighlightSeconds,
                onViewInTimeline: onOpenPlayback.map { cb in
                    { cameraId, date in
                        playerItem = nil       // dismiss the clip player first
                        cb(cameraId, date)
                    }
                }
            )
        }
    }

    // MARK: - Filters

    private func kindChip(_ label: String, _ kind: String?) -> some View {
        let active = vm.selectedKind == kind
        return Button { vm.selectKind(kind) } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? CrumbColors.teal : CrumbColors.surfaceVariant)
                .foregroundColor(active ? .black : CrumbColors.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var rangeMenu: some View {
        Menu {
            ForEach([6.0, 24.0, 72.0, 168.0], id: \.self) { hrs in
                Button { vm.setWindowHours(hrs) } label: {
                    Text(rangeLabel(hrs))
                    if vm.windowHours == hrs { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text(rangeLabel(vm.windowHours))
            }
            .font(.caption.weight(.medium))
            .foregroundColor(CrumbColors.tealAccent)
        }
    }

    private func rangeLabel(_ hours: Double) -> String {
        switch hours {
        case ..<24: return "\(Int(hours))h"
        case 24: return "24h"
        default: return "\(Int(hours / 24))d"
        }
    }

    // MARK: - Clip grid

    private var clipGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumnItems, spacing: 10) {
                ForEach(vm.filteredClips) { clip in
                    ClipCard(clip: clip, mediaUrls: vm.mediaUrls) {
                        vm.markViewed(clip)
                        playerItem = clip
                    }
                }
            }
            .padding(12)
        }
    }

    /// Grid columns: iOS uses a fixed count from the wall's tile-size button
    /// (`gridColumns`, 1–3); macOS uses an adaptive min-width from its own
    /// `clipTileSize` segmented picker.
    private var gridColumnItems: [GridItem] {
        #if os(macOS)
        return [GridItem(.adaptive(minimum: tileMinWidth, maximum: .infinity), spacing: 10)]
        #else
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, gridColumns ?? 2))
        #endif
    }

    #if os(macOS)
    private var tileMinWidth: CGFloat {
        switch clipTileSize {
        case 0: return 175
        case 2: return 340
        default: return 245
        }
    }
    #endif
}

// MARK: - ClipCard (grid tile)

private struct ClipCard: View {
    let clip: ClipDescriptor
    let mediaUrls: MediaUrls
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 16:9 thumbnail with overlays (fills, clipped to card corners below).
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { ClipThumbnail(clip: clip, mediaUrls: mediaUrls) }
                .overlay(alignment: .topTrailing) {
                    if !clip.viewed {
                        Circle().fill(CrumbColors.tealAccent).frame(width: 9, height: 9).padding(7)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    KindBadge(kind: clip.kind).padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if clip.durationMs > 0 {
                        Text(formatDuration(clip.durationSeconds))
                            .font(.caption2).foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.black.opacity(0.6), in: Capsule()).padding(6)
                    }
                }
                .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(clip.cameraName.isEmpty ? clip.cameraId : clip.cameraName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(CrumbColors.textPrimary).lineLimit(1)
                if !clip.label.isEmpty {
                    HStack(spacing: 4) {
                        IconKeyImage(iconKey: clip.iconKey).font(.caption2).foregroundColor(CrumbColors.tealAccent)
                        Text(clip.label.capitalized).font(.caption)
                            .foregroundColor(CrumbColors.textSecondary).lineLimit(1)
                        if let score = clip.score {
                            Text("(\(Int(score * 100))%)").font(.caption2).foregroundColor(CrumbColors.textTertiary)
                        }
                    }
                }
                if let date = clip.startDate {
                    Text(formatRelativeTime(date)).font(.caption2).foregroundColor(CrumbColors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(CrumbColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CrumbColors.divider, lineWidth: 1))
        .opacity(clip.viewed ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - ClipThumbnail

/// Thumbnail using a custom URLSession loader so the Authorization token is
/// included in the request (AsyncImage does not forward custom headers).
///
/// Resolves its own scoped (`?token=`) media-token URL per fetch attempt
/// (`mediaUrls.clipThumbUrl`, camera-scoped, ~15 min token) rather than being
/// handed a pre-built URL — a retry loop that spans more than ~15 min (e.g. slow
/// network on `attempt` 3/4) needs a FRESH token on each attempt, not a stale
/// one baked in at `.task` start.
private struct ClipThumbnail: View {

    let clip: ClipDescriptor
    let mediaUrls: MediaUrls

    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black

            if let img = image {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "camera.metering.unknown")
                    .foregroundColor(CrumbColors.textTertiary)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(CrumbColors.textTertiary)
            }

            // Play triangle overlay
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundColor(.white.opacity(0.75))
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
        .task(id: clip.id) {
            await fetchThumbnail()
        }
    }

    private func fetchThumbnail() async {
        failed = false
        // Retry transient failures (the feed fires many thumbnail requests at
        // once on first load; some get dropped). Without this they only recovered
        // when scrolling the cell off-screen and back re-triggered .task.
        for attempt in 0..<4 {
            if Task.isCancelled { return }
            guard let url = await mediaUrls.clipThumbUrl(clip.id, cameraId: clip.cameraId) else {
                try? await Task.sleep(nanoseconds: UInt64((attempt + 1)) * 700_000_000)
                continue
            }
            var req = URLRequest(url: url)
            req.cachePolicy = .returnCacheDataElseLoad
            req.timeoutInterval = 12
            if let (data, resp) = try? await URLSession.crumbMedia.data(for: req),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let img = PlatformImage(data: data) {
                image = img
                return
            }
            try? await Task.sleep(nanoseconds: UInt64((attempt + 1)) * 700_000_000)
        }
        failed = true
    }
}

// MARK: - KindBadge

private struct KindBadge: View {
    let kind: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: kind == "detection" ? "dot.radiowaves.left.and.right" : "sensor.tag.radiowaves.forward")
                .font(.caption2)
            Text(kind == "detection" ? "Detection" : "Motion")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(kind == "detection" ? CrumbColors.tealAccent : CrumbColors.motionDot)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        // Solid dark pill so the label stays legible when overlaid on a bright
        // video frame (the faint colored tint only worked on the dark footer).
        .background(.black.opacity(0.62))
        .clipShape(Capsule())
    }
}

// MARK: - IconKeyImage

private struct IconKeyImage: View {
    let iconKey: String

    var body: some View {
        Image(systemName: sfSymbol(for: iconKey))
    }

    private func sfSymbol(for key: String) -> String {
        switch key {
        case "person":       return "person.fill"
        case "face":         return "face.smiling"
        case "car", "truck": return "car.fill"
        case "motorcycle":   return "bicycle"
        case "dog", "cat":   return "pawprint.fill"
        case "delivery":     return "shippingbox.fill"
        default:             return "eye.fill"
        }
    }
}

// MARK: - Camera filter chips

private struct CameraFilterChips: View {
    let cameras: [CameraDto]
    let selectedId: String?
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "All", isActive: selectedId == nil) {
                    onSelect(nil)
                }
                ForEach(cameras) { cam in
                    filterChip(label: cam.name, isActive: selectedId == cam.id) {
                        onSelect(cam.id)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func filterChip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive ? CrumbColors.tealAccent : CrumbColors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? CrumbColors.tealAccent.opacity(0.15) : CrumbColors.surface)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isActive ? CrumbColors.tealAccent : CrumbColors.divider,
                            lineWidth: 1
                        )
                )
        }
    }
}

// MARK: - Empty / Error states

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundColor(CrumbColors.textTertiary)
            Text("No clips in the last 24 hours")
                .font(.subheadline)
                .foregroundColor(CrumbColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(CrumbColors.error)
            Text(message)
                .font(.subheadline)
                .foregroundColor(CrumbColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry", action: retry)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(CrumbColors.tealAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
