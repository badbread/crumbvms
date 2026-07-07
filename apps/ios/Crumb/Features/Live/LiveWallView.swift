// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

enum GridLayout: Int, CaseIterable {
    case single = 0
    case twoByTwo = 1
    case compact = 2

    var columns: Int {
        switch self {
        case .single: return 1
        case .twoByTwo: return 2
        case .compact: return 3
        }
    }

    var icon: String {
        switch self {
        case .single: return "rectangle"
        case .twoByTwo: return "square.grid.2x2"
        case .compact: return "square.grid.3x3"
        }
    }
}

struct LiveWallView: View {

    @StateObject private var vm: LiveViewModel
    @State private var selectedCameraId: String?
    @State private var playbackCameraId: String?
    @State private var playbackStartTime: Date?
    /// Camera to open in playback once the Bookmarks sheet finishes dismissing
    /// (presenting a fullScreenCover in the same tick as a sheet dismiss is swallowed).
    @State private var pendingBookmarkCameraId: String?
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var editingView: CameraView?
    @State private var showNewView = false
    @State private var mode: Mode = .live
    /// macOS: hide the top-nav + toolbar to show the wall edge-to-edge.
    @State private var macWallFullscreen = false
    @ObservedObject private var container: AppContainer
    @ObservedObject private var settings: AppSettings
    #if os(iOS)
    /// Compact vertical size class == iPhone landscape. In landscape the mode tabs
    /// fold up into the top toolbar (inline with the tile-size button) to reclaim
    /// vertical space; portrait keeps them on their own row.
    @Environment(\.verticalSizeClass) private var vSizeClass
    #endif

    init(container: AppContainer) {
        _container = ObservedObject(wrappedValue: container)
        _settings = ObservedObject(wrappedValue: container.settings)
        let vm = LiveViewModel(container: container)
        _vm = StateObject(wrappedValue: vm)
        _selectedCameraId = State(initialValue: container.store.lastLiveCameraId)
    }

    /// Default grid layout, driven reactively by the observable setting so a
    /// change made in Settings reaches the wall immediately.
    private var gridLayout: GridLayout { GridLayout(rawValue: settings.liveGridLayout) ?? .twoByTwo }

    /// Camera IDs of the active saved View, or nil for "All cameras" — used to
    /// restrict the Clips feed the same way `visibleCameras` restricts Live/Playback.
    private var activeViewCameraIds: [String]? {
        guard let activeViewId = settings.activeViewId,
              let view = vm.views.first(where: { $0.id == activeViewId })
        else { return nil }
        return view.cameraIds
    }

    /// Cameras visible given the active view filter.
    private var visibleCameras: [CameraDto] {
        guard let activeViewId = settings.activeViewId,
              let view = vm.views.first(where: { $0.id == activeViewId })
        else { return vm.cameras }
        let order = view.cameraIds
        var indexMap: [String: Int] = [:]
        for (i, id) in order.enumerated() { indexMap[id] = i }
        return vm.cameras
            .filter { indexMap.keys.contains($0.id) }
            .sorted { (indexMap[$0.id] ?? 0) < (indexMap[$1.id] ?? 0) }
    }

    /// Mode tabs the signed-in user may see — Live always; Playback/Clips per
    /// capability (admins see all).
    private var visibleTabs: [Mode] {
        var t: [Mode] = [.live]
        if container.isAdmin || container.capabilities.playback { t.append(.playback) }
        if container.isAdmin || container.capabilities.clips { t.append(.clips) }
        return t
    }


    var body: some View {
        Group {
            #if os(macOS)
            macShell
            #else
            iosWall
            #endif
        }
        .sheet(isPresented: $showBookmarks, onDismiss: {
            // Open playback only after the sheet has fully dismissed.
            if let id = pendingBookmarkCameraId {
                pendingBookmarkCameraId = nil
                playbackCameraId = id
                #if os(macOS)
                mode = .playback
                #endif
            }
        }) {
            NavigationStack {
                BookmarksView(container: container) { cameraId, date in
                    playbackStartTime = date
                    pendingBookmarkCameraId = cameraId
                    showBookmarks = false
                }
                .navigationTitle("Bookmarks")
                .navBarInline()
                .toolbar {
                    ToolbarItem(placement: .barTrailing) {
                        Button("Done") { showBookmarks = false }
                            .foregroundColor(CrumbColors.tealAccent)
                    }
                }
            }
            .macModalSize(width: 480, height: 640)
        }
        .sheet(item: $editingView) { existing in
            #if os(macOS)
            LayoutEditorView(
                existing: existing,
                allCameras: vm.cameras,
                onSave: { saveView($0) },
                onDelete: { deleteView($0) },
                onDismiss: { editingView = nil }
            )
            #else
            ViewEditorView(
                target: .edit(existing),
                allCameras: vm.cameras,
                onSave: { saveView($0) },
                onDelete: { deleteView($0) },
                onDismiss: { editingView = nil }
            )
            #endif
        }
        .sheet(isPresented: $showNewView) {
            #if os(macOS)
            LayoutEditorView(
                existing: nil,
                allCameras: vm.cameras,
                onSave: { saveView($0) },
                onDelete: { _ in showNewView = false },
                onDismiss: { showNewView = false }
            )
            #else
            ViewEditorView(
                target: .new,
                allCameras: vm.cameras,
                onSave: { saveView($0) },
                onDelete: { _ in showNewView = false },
                onDismiss: { showNewView = false }
            )
            #endif
        }
        .task {
            await vm.loadCameras()
            vm.startStatusPolling()
        }
        .task {
            await vm.loadViews()
        }
        .onDisappear {
            vm.stopStatusPolling()
        }
    }

    // MARK: - View persistence (M1: server-backed `/views`, shared by both editors)
    //
    // The server has no update endpoint for a view (`views.rs` exposes only
    // GET/POST/DELETE) — "editing" an existing view is therefore delete-then-
    // recreate, same pattern Android's `CrumbRepository` uses. The server
    // mints a fresh id on create, so the locally-held `existing.id` is only
    // used to find-and-delete the prior server row; the id the app then
    // treats as "active" is whatever the server assigns to the new row.

    /// Insert (or replace, if editing) a saved view server-side and make it active.
    private func saveView(_ saved: CameraView) {
        Task {
            // Editing an existing (already-server-persisted) view: delete the
            // old row first so we don't leave an orphaned duplicate behind.
            if vm.views.contains(where: { $0.id == saved.id }) {
                await vm.deleteView(saved.id)
            }
            if let created = await vm.createView(saved) {
                settings.activeViewId = created.id
            }
            editingView = nil
            showNewView = false
        }
    }

    private func deleteView(_ id: String) {
        Task {
            await vm.deleteView(id)
            if settings.activeViewId == id { settings.activeViewId = nil }
            editingView = nil
            showNewView = false
        }
    }

    /// The active view's custom pane layout, if it has one (drives the macOS
    /// Live wall; nil = uniform column grid). Server-backed views don't
    /// currently round-trip a custom `ViewLayout` through `/views` (M1 scope:
    /// ordered camera ids only, matching Android/desktop's shared contract),
    /// so this stays nil for server views — the macOS custom-layout editor
    /// still works locally within a session but a relaunch reverts to the
    /// uniform grid. Tracked as a follow-up, not a regression: the OLD
    /// UserDefaults-only store never synced across devices either.
    private var activeLayout: ViewLayout? {
        guard let id = settings.activeViewId else { return nil }
        return vm.views.first(where: { $0.id == id })?.layout
    }

    // MARK: - iOS wall (phone-shaped: fullscreen takeover + sheets/covers)

    #if os(iOS)
    @ViewBuilder private var iosWall: some View {
        ZStack {
            CrumbColors.background.ignoresSafeArea()

            if let cameraId = selectedCameraId,
               let camera = vm.cameras.first(where: { $0.id == cameraId }) {
                LiveFullscreenView(
                    camera: camera,
                    cameras: visibleCameras.isEmpty ? vm.cameras : visibleCameras,
                    vm: vm,
                    onBack: {
                        selectedCameraId = nil
                        vm.store.lastLiveCameraId = nil
                    },
                    onSwipeCamera: { newId in
                        selectedCameraId = newId
                        vm.store.lastLiveCameraId = newId
                    },
                    onOpenPlayback: { id in
                        playbackCameraId = id
                    }
                )
            } else {
                wallContent
            }
        }
        .fullScreenCoverCompat(item: Binding(
            get: { playbackCameraId.flatMap { id in vm.cameras.first(where: { $0.id == id }) } },
            set: { _ in playbackCameraId = nil; playbackStartTime = nil }
        )) { camera in
            PlaybackView(camera: camera, cameras: visibleCameras.isEmpty ? vm.cameras : visibleCameras, container: container, startTime: playbackStartTime) {
                playbackCameraId = nil
                playbackStartTime = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(container: container)
        }
    }
    #endif

    // MARK: - macOS desktop shell (top-nav + full-window pages, inline playback)

    #if os(macOS)
    /// Top-nav destinations, gated to the signed-in user's capabilities. Settings
    /// is always present; Exports rides with playback access.
    private var macTabs: [Mode] {
        var t: [Mode] = [.live]
        if container.isAdmin || container.capabilities.playback {
            t.append(.playback)
            t.append(.exports)
        }
        if container.isAdmin || container.capabilities.clips { t.append(.clips) }
        t.append(.settings)
        return t
    }

    @ViewBuilder private var macShell: some View {
        ZStack {
            CrumbColors.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if !macWallFullscreen {
                    MacTopNav(mode: $mode, tabs: macTabs)
                }
                macPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if macWallFullscreen {
                Button { macWallFullscreen = false } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .help("Exit fullscreen (Esc)")
            }
        }
        .onChange(of: macTabs) { tabs in
            if !tabs.contains(mode) { mode = .live }
        }
        .onExitCommand { if macWallFullscreen { macWallFullscreen = false } }
    }

    @ViewBuilder private var macPage: some View {
        switch mode {
        case .live:
            if let cameraId = selectedCameraId,
               let camera = vm.cameras.first(where: { $0.id == cameraId }) {
                LiveFullscreenView(
                    camera: camera,
                    cameras: visibleCameras.isEmpty ? vm.cameras : visibleCameras,
                    vm: vm,
                    onBack: {
                        selectedCameraId = nil
                        vm.store.lastLiveCameraId = nil
                    },
                    onSwipeCamera: { newId in
                        selectedCameraId = newId
                        vm.store.lastLiveCameraId = newId
                    },
                    onOpenPlayback: { id in
                        playbackCameraId = id
                        mode = .playback
                    }
                )
            } else {
                VStack(spacing: 0) {
                    if !macWallFullscreen {
                        macSecondaryBar(showGrid: activeLayout == nil, showLiveActions: true)
                    }
                    if let layout = activeLayout {
                        macCustomLiveWall(layout: layout)
                    } else {
                        liveContent
                    }
                }
            }
        case .playback:
            if let id = playbackCameraId,
               let cam = vm.cameras.first(where: { $0.id == id }) {
                PlaybackView(camera: cam, cameras: visibleCameras.isEmpty ? vm.cameras : visibleCameras, container: container, startTime: playbackStartTime) {
                    playbackCameraId = nil
                    playbackStartTime = nil
                }
            } else {
                VStack(spacing: 0) {
                    macSecondaryBar(showGrid: true, showLiveActions: false)
                    PlaybackWallView(
                        container: container,
                        cameras: visibleCameras,
                        columns: gridLayout.columns,
                        onOpenPlayback: { id, start in
                            playbackStartTime = start
                            playbackCameraId = id
                        }
                    )
                }
            }
        case .exports:
            ExportView(
                container: container,
                cameras: visibleCameras.isEmpty ? vm.cameras : visibleCameras,
                cameraIds: [],
                start: Date().addingTimeInterval(-3600),
                end: Date(),
                onClose: { mode = .live }
            )
        case .clips:
            VStack(spacing: 0) {
                macSecondaryBar(showGrid: false, showLiveActions: false)
                ClipsView(container: container, viewCameraIds: activeViewCameraIds, onOpenPlayback: { id, date in
                    playbackStartTime = date
                    playbackCameraId = id
                    mode = .playback
                })
            }
        case .settings:
            SettingsView(container: container)
        }
    }

    /// Shared secondary toolbar above the camera tabs (Live / Playback / Clips) —
    /// saved-view chips, plus an optional grid-layout picker and the Live-only
    /// bookmarks + fullscreen actions. Mirrors the desktop client's sub-toolbar.
    @ViewBuilder private func macSecondaryBar(showGrid: Bool, showLiveActions: Bool) -> some View {
        HStack(spacing: 12) {
            if showGrid {
                HStack(spacing: 2) {
                    ForEach(GridLayout.allCases, id: \.rawValue) { layout in
                        Button {
                            settings.liveGridLayout = layout.rawValue
                        } label: {
                            Image(systemName: layout.icon)
                                .font(.system(size: 13))
                                .foregroundColor(gridLayout == layout ? CrumbColors.teal : CrumbColors.textTertiary)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ViewChipsView(
                views: vm.views,
                activeId: Binding(
                    get: { settings.activeViewId },
                    set: { settings.activeViewId = $0 }
                ),
                onCreate: { showNewView = true },
                onEdit: { v in editingView = v }
            )

            Spacer()

            if showLiveActions {
                if settings.bookmarksButtonEnabled && (container.isAdmin || container.capabilities.canBookmark) {
                    Button {
                        showBookmarks = true
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .foregroundColor(CrumbColors.bookmarkGold)
                    }
                    .buttonStyle(.plain)
                    .help("Bookmarks")
                }

                Button {
                    macWallFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundColor(CrumbColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Fullscreen wall")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The Live wall rendered with a saved view's custom pane layout: each pane
    /// fills its rect with that camera's live tile (or an empty placeholder).
    @ViewBuilder private func macCustomLiveWall(layout: ViewLayout) -> some View {
        let urls = vm.mediaUrls()
        CustomLayoutContainer(layout: layout, cameras: vm.cameras, spacing: 4) { _, cam in
            if let cam {
                CameraTileView(
                    camera: cam,
                    status: vm.cameraStatuses[cam.id],
                    detectionKeys: vm.activeDetections[cam.id] ?? [],
                    mediaUrls: urls,
                    lowBandwidth: settings.lowBandwidthMode,
                    lockAspect: false,
                    onTap: {
                        selectedCameraId = cam.id
                        vm.store.lastLiveCameraId = cam.id
                    }
                )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.45))
                    .overlay(Image(systemName: "video.slash").foregroundColor(CrumbColors.textTertiary))
            }
        }
        .padding(6)
    }
    #endif

    /// Whether the tabs fold into the toolbar (iPhone landscape / compact height).
    private var tabsInline: Bool {
        #if os(iOS)
        return vSizeClass == .compact
        #else
        return false
        #endif
    }

    /// Cycle the wall's tile size (single → 2×2 → 3×3 → single) — one button that
    /// steps through the grid layouts instead of three separate icons.
    private func cycleGridLayout() {
        let all = GridLayout.allCases
        let idx = all.firstIndex(where: { $0.rawValue == settings.liveGridLayout }) ?? 0
        settings.liveGridLayout = all[(idx + 1) % all.count].rawValue
    }

    /// Single tile-size button showing the current layout's icon; tap cycles.
    private var tileSizeButton: some View {
        Button(action: cycleGridLayout) {
            Image(systemName: gridLayout.icon)
                .font(.system(size: 16))
                .foregroundColor(CrumbColors.teal)
                .padding(8)
        }
        .accessibilityLabel("Tile size")
    }

    @ViewBuilder private var bookmarksButton: some View {
        if settings.bookmarksButtonEnabled && (container.isAdmin || container.capabilities.canBookmark) {
            Button { showBookmarks = true } label: {
                Image(systemName: "bookmark.fill")
                    .foregroundColor(CrumbColors.bookmarkGold)
            }
        }
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .foregroundColor(CrumbColors.textSecondary)
        }
    }

    private var modeTabs: some View {
        ModeTabs(mode: $mode, tabs: visibleTabs)
            .onChange(of: visibleTabs) { tabs in
                if !tabs.contains(mode) { mode = .live }
            }
    }

    @ViewBuilder
    private var wallContent: some View {
        VStack(spacing: 0) {
            if tabsInline {
                // Landscape: tabs inline with the toolbar controls (saves a row).
                HStack(spacing: 12) {
                    modeTabs
                    Spacer()
                    tileSizeButton
                    bookmarksButton
                    settingsButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
                // Portrait: logo + controls up top, tabs on their own row beneath.
                HStack(spacing: 12) {
                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 30)

                    Spacer()

                    tileSizeButton
                    bookmarksButton
                    settingsButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                modeTabs
                    .padding(.bottom, 8)
            }

            // View chips
            ViewChipsView(
                views: vm.views,
                activeId: Binding(
                    get: { settings.activeViewId },
                    set: { settings.activeViewId = $0 }
                ),
                onCreate: { showNewView = true },
                onEdit: { v in editingView = v }
            )
            .padding(.bottom, 6)

            // Mode content
            switch mode {
            case .live:
                liveContent
            case .playback:
                PlaybackWallView(
                    container: container,
                    cameras: visibleCameras,
                    columns: gridLayout.columns,
                    onOpenPlayback: { id, start in
                        playbackStartTime = start
                        playbackCameraId = id
                    }
                )
            case .clips:
                ClipsView(container: container, viewCameraIds: activeViewCameraIds, gridColumns: gridLayout.columns, onOpenPlayback: { id, date in
                    playbackStartTime = date
                    playbackCameraId = id
                })
            case .exports, .settings:
                // macOS-only top-nav destinations; never selected on iOS.
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        if vm.isLoading && vm.cameras.isEmpty {
            Spacer()
            ProgressView()
                .tint(CrumbColors.teal)
            Spacer()
        } else if let error = vm.error, vm.cameras.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(CrumbColors.error)
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(CrumbColors.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await vm.loadCameras() }
                }
                .foregroundColor(CrumbColors.teal)
            }
            .padding()
            Spacer()
        } else if visibleCameras.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.largeTitle)
                    .foregroundColor(CrumbColors.textTertiary)
                Text("No cameras in this view")
                    .font(.subheadline)
                    .foregroundColor(CrumbColors.textSecondary)
            }
            Spacer()
        } else {
            cameraGrid
        }
    }

    @ViewBuilder
    private var cameraGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: gridLayout.columns)
        let urls = vm.mediaUrls()

        ScrollView {
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(visibleCameras) { camera in
                    CameraTileView(
                        camera: camera,
                        status: vm.cameraStatuses[camera.id],
                        detectionKeys: vm.activeDetections[camera.id] ?? [],
                        mediaUrls: urls,
                        lowBandwidth: settings.lowBandwidthMode,
                        onTap: {
                            selectedCameraId = camera.id
                            vm.store.lastLiveCameraId = camera.id
                        }
                    )
                }
            }
            .padding(.horizontal, 4)
        }
        .refreshable {
            await vm.loadCameras()
        }
    }
}
