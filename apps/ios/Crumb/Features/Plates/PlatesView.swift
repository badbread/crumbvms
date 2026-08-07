// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Plate-match mode. `contains` is the default; the server also supports
/// `prefix`, `exact`, and `fuzzy` (similarity-ordered).
/// Overall layout of the plate hits. (list + gallery for now; grouped/timeline
/// on desktop are follow-ups.) Raw values persist in UserDefaults.
enum PlatesLayout: String, CaseIterable, Identifiable {
    case list, gallery
    var id: String { rawValue }
    var label: String { self == .list ? "List" : "Gallery" }
    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// Which plate image(s) a row shows. Raw values persist in UserDefaults.
enum PlateImageDisplay: String, CaseIterable, Identifiable {
    case both, full = "full", crop = "crop"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return "Full frame + crop"
        case .full: return "Full frame only"
        case .crop: return "Plate crop only"
        }
    }
}

enum PlateMatch: String, CaseIterable, Identifiable {
    case contains, prefix, exact, fuzzy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .contains: return "Contains"
        case .prefix: return "Prefix"
        case .exact: return "Exact"
        case .fuzzy: return "Fuzzy"
        }
    }
}

// MARK: - View model

@MainActor
final class PlatesViewModel: ObservableObject {

    @Published var plates: [PlateRead] = []
    @Published var total = 0
    @Published var loading = false
    @Published var error: String?

    @Published var query = ""
    @Published var match: PlateMatch = .contains
    /// Lookback window in hours; 0 = all time. Matches the desktop options.
    @Published var rangeHours: Double = 24
    /// Collapse near-duplicate reads (same camera, ≤15 s, similar plate) into
    /// one row. Device-local preference, persisted like `playbackQuality`.
    /// Hit layout (list / gallery), persisted per device.
    @Published var layout: PlatesLayout =
        PlatesLayout(rawValue: UserDefaults.standard.string(forKey: "plates_layout") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "plates_layout") }
    }

    @Published var collapse: Bool = UserDefaults.standard.object(forKey: "plates_collapse") as? Bool ?? true {
        didSet { UserDefaults.standard.set(collapse, forKey: "plates_collapse") }
    }

    // Watchlist
    @Published var watchlist: [WatchlistEntry] = []
    @Published var watchlistError: String?
    /// Watchlist fuzziness (0…0.5) from `GET /config/lpr`; nil until loaded /
    /// when the caller isn't an admin (403). Drives the add-form slider + preview.
    @Published var watchlistFuzz: Double?
    private var lprConfig: LprConfigDto?

    let container: AppContainer
    let cameras: [CameraDto]

    private var loadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    private static let iso = ISO8601DateFormatter()

    init(container: AppContainer, cameras: [CameraDto]) {
        self.container = container
        self.cameras = cameras
    }

    var isAdmin: Bool { container.isAdmin }

    /// Camera id → display name, for the row's camera line.
    func cameraName(_ id: String) -> String {
        cameras.first(where: { $0.id == id })?.name ?? "(unknown camera)"
    }

    /// Whether `plate` is already on the watchlist (normalized compare).
    func isWatched(_ plate: String) -> Bool {
        let norm = plate.uppercased()
        return watchlist.contains { $0.plate.uppercased() == norm }
    }

    /// The rendered list: `plates` collapsed into duplicate groups. Collapse
    /// operates over the reads in server order (which for fuzzy IS the result,
    /// see `load()`), so ordering is preserved — no re-sort here either.
    var groups: [Lpr.PlateGroup] {
        let lites = plates.map {
            Lpr.PlateReadLite(
                id: $0.id, cameraId: $0.cameraId,
                tsMs: Int64(parseISO8601($0.ts)?.timeIntervalSince1970 ?? 0) * 1000,
                plate: $0.plate, confidence: $0.confidence
            )
        }
        return Lpr.collapse(lites, enabled: collapse)
    }

    /// Look a full `PlateRead` back up by id (group representatives are lites).
    func plateRead(byId id: String) -> PlateRead? {
        plates.first { $0.id == id }
    }

    // MARK: plate-crop thumbnails

    /// Which plate image(s) to show in each row — full frame, tight crop, or both
    /// (matches the desktop client). Persisted per device.
    @Published var imageDisplay: PlateImageDisplay =
        PlateImageDisplay(rawValue: UserDefaults.standard.string(forKey: "plates_image_display") ?? "") ?? .both {
        didSet { UserDefaults.standard.set(imageDisplay.rawValue, forKey: "plates_image_display") }
    }

    /// Decoded (full, crop) images by event id — the snapshot is fetched once and
    /// both derived from it, cached so re-scrolls don't refetch/re-decode.
    private var imageCache: [String: (full: PlatformImage?, crop: PlatformImage?)] = [:]

    /// Fetch the snapshot for `eventId` and derive the full frame + the tight
    /// plate crop (from `bbox`), cached. Either may be nil on failure.
    func images(for eventId: String, bbox: [Double]?) async -> (full: PlatformImage?, crop: PlatformImage?) {
        if let cached = imageCache[eventId] { return cached }
        guard let data = try? await container.api.plateSnapshot(eventId: eventId) else { return (nil, nil) }
        let full = PlateCrop.crop(data, bbox: nil)
        let crop = bbox != nil ? PlateCrop.crop(data, bbox: bbox) : full
        let pair = (full, crop)
        imageCache[eventId] = pair
        return pair
    }

    // MARK: reads

    func load() {
        loadTask?.cancel()
        let ids = cameras.map(\.id)
        guard !ids.isEmpty else {
            plates = []; total = 0; error = nil; loading = false
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchMode = match
        let (startISO, endISO) = window()
        loading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resp = try await container.api.plates(
                    cameraIds: ids,
                    start: startISO, end: endISO,
                    q: q.isEmpty ? nil : q,
                    match: q.isEmpty ? nil : matchMode.rawValue
                )
                guard !Task.isCancelled else { return }
                // CRITICAL: fuzzy results are ordered by similarity server-side and
                // that ordering IS the result — never re-sort them by time (that
                // was a real bug on the other clients). Non-fuzzy already arrives
                // newest-first from the server, so we don't re-sort either: render
                // exactly what the server returned.
                plates = resp.plates
                total = resp.total
                error = nil
                loading = false
            } catch is CancellationError {
                // superseded by a newer load
            } catch {
                guard !Task.isCancelled else { return }
                plates = []
                self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
                loading = false
            }
        }
    }

    /// Debounced reload on search-text change (immediate on submit via `load()`).
    func queryChanged() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            load()
        }
    }

    func setMatch(_ m: PlateMatch) {
        guard m != match else { return }
        match = m
        // Changing the mode only affects a non-empty query.
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { load() }
    }

    func setRangeHours(_ h: Double) {
        guard h != rangeHours else { return }
        rangeHours = h
        load()
    }

    /// `start`/`end` ISO strings for the current window (nil = unbounded).
    private func window() -> (String?, String?) {
        guard rangeHours > 0 else { return (nil, nil) }
        let start = Date().addingTimeInterval(-rangeHours * 3600)
        return (Self.iso.string(from: start), nil)
    }

    // MARK: watchlist

    func loadWatchlist() {
        Task { [weak self] in
            guard let self else { return }
            do {
                watchlist = try await container.api.watchlist()
                watchlistError = nil
            } catch {
                watchlistError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Load the LPR config for the fuzziness control (admin only; a 403 for a
    /// non-admin just leaves the slider hidden).
    func loadLprConfig() {
        guard isAdmin else { return }
        Task { [weak self] in
            guard let self else { return }
            if let cfg = try? await container.api.lprConfig() {
                lprConfig = cfg
                watchlistFuzz = cfg.watchlistFuzz
            }
        }
    }

    /// Persist a new fuzziness (admin), round-tripping enabled/retention.
    func saveFuzz(_ fuzz: Double) {
        guard let cfg = lprConfig else { return }
        watchlistFuzz = fuzz
        Task { [weak self] in
            guard let self else { return }
            if let updated = try? await container.api.putLprConfig(
                enabled: cfg.enabled, retentionDays: cfg.retentionDays, watchlistFuzz: fuzz) {
                lprConfig = updated
                watchlistFuzz = updated.watchlistFuzz
            }
        }
    }

    /// Add/edit a watchlist entry (admin only; POST is an upsert keyed on the
    /// normalized plate). Callers editing an existing entry must round-trip its
    /// `note`/`color` so the upsert doesn't wipe them. Returns nil on success
    /// or an error message to surface. Refreshes the list on success.
    func addToWatchlist(
        plate: String, label: String?, notify: Bool,
        note: String? = nil, color: String? = nil, kind: String? = nil
    ) async -> String? {
        let trimmed = plate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a plate." }
        do {
            _ = try await container.api.addWatchlist(
                WatchlistAddRequest(
                    plate: trimmed,
                    label: label?.isEmpty == true ? nil : label,
                    note: note, color: color, notify: notify, kind: kind
                )
            )
            loadWatchlist()
            return nil
        } catch let e as APIError where e.isForbidden {
            return "Only admins can manage the watchlist."
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: plate names

    /// Set, edit, or clear a plate's human-readable name (`plate_labels`, issue
    /// #363). Admin-only server-side, so the affordances that call this are
    /// gated on `isAdmin` — a viewer never sees a control that would 403.
    ///
    /// This is naming, NOT alerting: it writes `plate_labels` only, so the plate
    /// does not join the watchlist and no `plate_watchlist_hit` can result. A
    /// blank `name` clears (matching the web console), and an unchanged name
    /// spends no request. Returns nil on success, else a message to surface.
    ///
    /// On success both the reads and the watchlist reload, so the new name
    /// paints everywhere that plate appears in this client.
    func namePlate(_ plate: String, name: String, current: String?) async -> String? {
        let action = PlateNaming.action(input: name, current: current)
        guard action != .noChange else { return nil }
        do {
            switch action {
            case .set(let label):
                try await container.api.setPlateLabel(plate: plate, label: label)
            case .clear:
                try await container.api.clearPlateLabel(plate: plate)
            case .noChange:
                return nil
            }
        } catch let e as APIError where e.isForbidden {
            return "Only admins can name a plate."
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        load()
        loadWatchlist()
        return nil
    }

    /// Remove a watchlist entry (admin only). Returns nil on success (incl. a
    /// 404 already-gone) or an error message. The API layer verifies the HTTP
    /// status — a non-2xx (e.g. 403) surfaces here rather than a false success.
    func removeFromWatchlist(_ entry: WatchlistEntry) async -> String? {
        do {
            try await container.api.deleteWatchlist(id: entry.id)
            loadWatchlist()
            return nil
        } catch let e as APIError where e.isForbidden {
            return "Only admins can manage the watchlist."
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Screen

struct PlatesView: View {

    @StateObject private var vm: PlatesViewModel
    /// Jump to playback at a read's time (camera id + timestamp).
    let onOpenPlayback: (String, Date) -> Void

    @State private var showWatchlist = false
    @State private var toast: String?
    /// The plate whose name is being edited (admin only); nil = sheet closed.
    @State private var naming: PlateNameTarget?
    /// The plate-hit clip to play (tapping a read with an event opens the
    /// server-windowed clip, which lands on the car — see `openReadClip`).
    @State private var playingClip: ClipDescriptor?

    init(container: AppContainer, cameras: [CameraDto], onOpenPlayback: @escaping (String, Date) -> Void) {
        _vm = StateObject(wrappedValue: PlatesViewModel(container: container, cameras: cameras))
        self.onOpenPlayback = onOpenPlayback
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().overlay(CrumbColors.surfaceVariant)
            content
        }
        .background(CrumbColors.background)
        .task {
            vm.load()
            vm.loadWatchlist()
        }
        .sheet(isPresented: $showWatchlist) {
            WatchlistSheet(vm: vm)
                .macModalSize(width: 460, height: 560)
        }
        .sheet(item: $naming) { target in
            PlateNameSheet(vm: vm, target: target) { flash($0) }
                .macModalSize(width: 420, height: 340)
        }
        .fullScreenCoverCompat(item: $playingClip) { clip in
            ClipPlayerView(
                clip: clip,
                mediaUrls: vm.container.mediaUrls(),
                highlightSeconds: 0,
                onViewInTimeline: { cameraId, date in
                    playingClip = nil
                    onOpenPlayback(cameraId, date)
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium)).foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.78)))
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: controls

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(CrumbColors.textTertiary)
                    TextField("Search plate…", text: $vm.query)
                        .textFieldStyle(.plain)
                        .foregroundColor(CrumbColors.textPrimary)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .onChange(of: vm.query) { _ in vm.queryChanged() }
                        .onSubmit { vm.load() }
                    if !vm.query.isEmpty {
                        Button { vm.query = ""; vm.load() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(CrumbColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(CrumbColors.surfaceVariant, in: Capsule())

                matchMenu
                rangeMenu

                Button { vm.collapse.toggle() } label: {
                    Image(systemName: vm.collapse ? "square.stack.3d.up" : "square.stack.3d.up.slash")
                        .foregroundColor(vm.collapse ? CrumbColors.tealAccent : CrumbColors.textTertiary)
                }
                .buttonStyle(.plain)
                .help(vm.collapse ? "Collapsing duplicate reads" : "Showing every read")

                Button { vm.layout = vm.layout == .list ? .gallery : .list } label: {
                    Image(systemName: vm.layout.icon).foregroundColor(CrumbColors.tealAccent)
                }
                .buttonStyle(.plain)
                .help("Layout: \(vm.layout.label)")

                Menu {
                    ForEach(PlateImageDisplay.allCases) { mode in
                        Button { vm.imageDisplay = mode } label: {
                            Text(mode.label)
                            if vm.imageDisplay == mode { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    Image(systemName: "photo.on.rectangle").foregroundColor(CrumbColors.tealAccent)
                }
                .help("Image display")

                Button { showWatchlist = true } label: {
                    Image(systemName: "list.star").foregroundColor(CrumbColors.tealAccent)
                }
                .buttonStyle(.plain)
                .help("Watchlist")
            }

            HStack {
                if vm.loading {
                    ProgressView().controlSize(.small).tint(CrumbColors.tealAccent)
                } else {
                    Text("\(vm.total) plate\(vm.total == 1 ? "" : "s")")
                        .font(.caption).foregroundColor(CrumbColors.textSecondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var matchMenu: some View {
        Menu {
            ForEach(PlateMatch.allCases) { m in
                Button { vm.setMatch(m) } label: {
                    Text(m.label)
                    if vm.match == m { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(vm.match.label).font(.caption.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundColor(CrumbColors.tealAccent)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(CrumbColors.surfaceVariant, in: Capsule())
        }
        .fixedSize()
    }

    private var rangeMenu: some View {
        Menu {
            ForEach(Self.rangeOptions, id: \.hours) { opt in
                Button { vm.setRangeHours(opt.hours) } label: {
                    Text(opt.label)
                    if vm.rangeHours == opt.hours { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.caption2)
                Text(Self.rangeLabel(vm.rangeHours)).font(.caption.weight(.semibold))
            }
            .foregroundColor(CrumbColors.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(CrumbColors.surfaceVariant, in: Capsule())
        }
        .fixedSize()
    }

    private static let rangeOptions: [(label: String, hours: Double)] = [
        ("All time", 0), ("1 hour", 1), ("6 hours", 6), ("24 hours", 24),
        ("3 days", 72), ("7 days", 168), ("30 days", 720),
    ]
    private static func rangeLabel(_ h: Double) -> String {
        rangeOptions.first { $0.hours == h }?.label ?? "24 hours"
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if let error = vm.error, vm.plates.isEmpty {
            centered {
                VStack(spacing: 8) {
                    Text("Couldn't load plates").foregroundColor(CrumbColors.error)
                    Text(error).font(.caption).foregroundColor(CrumbColors.textTertiary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { vm.load() }.foregroundColor(CrumbColors.tealAccent)
                }.padding(24)
            }
        } else if vm.plates.isEmpty && !vm.loading {
            centered {
                Text("No plate reads in this window.")
                    .foregroundColor(CrumbColors.textTertiary)
            }
        } else {
            ScrollView {
                switch vm.layout {
                case .gallery: galleryLayout
                case .list: listLayout
                }
            }
        }
    }

    @ViewBuilder private var listLayout: some View {
        LazyVStack(spacing: 0) {
            ForEach(vm.groups) { group in
                if let read = vm.plateRead(byId: group.representative.id) {
                    PlateRow(
                        read: read,
                        count: group.count,
                        cameraName: vm.cameraName(read.cameraId),
                        canWatch: vm.isAdmin,
                        watched: vm.isWatched(read.plate),
                        display: vm.imageDisplay,
                        fetchImages: imagesFetcher(for: read),
                        onOpenPlayback: read.eventId != nil ? { openReadClip(read) } : nil,
                        onAddToWatchlist: vm.isAdmin ? { addToWatchlist(read.plate) } : nil,
                        onCopied: { flash("Copied \($0)") },
                        onName: nameAction(for: read)
                    )
                    Divider().overlay(CrumbColors.surface)
                }
            }
        }
    }

    @ViewBuilder private var galleryLayout: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
            ForEach(vm.groups) { group in
                if let read = vm.plateRead(byId: group.representative.id) {
                    PlateCard(
                        read: read,
                        count: group.count,
                        cameraName: vm.cameraName(read.cameraId),
                        canWatch: vm.isAdmin,
                        watched: vm.isWatched(read.plate),
                        fetchImages: imagesFetcher(for: read),
                        onOpenPlayback: read.eventId != nil ? { openReadClip(read) } : nil,
                        onAddToWatchlist: vm.isAdmin ? { addToWatchlist(read.plate) } : nil,
                        onCopied: { flash("Copied \($0)") },
                        onName: nameAction(for: read)
                    )
                }
            }
        }
        .padding(12)
    }

    /// The "name this plate" action for a read, or nil when the caller isn't an
    /// admin or the read has no plate — `PUT`/`DELETE /lpr/plate-labels` are
    /// admin-only, so a viewer must never see a control that would 403.
    private func nameAction(for read: PlateRead) -> (() -> Void)? {
        guard vm.isAdmin, !read.plate.isEmpty else { return nil }
        return { naming = PlateNameTarget(plate: read.plate, current: read.resolvedName) }
    }

    private func centered<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        VStack { Spacer(); v(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Async thumbnail loader for a row, or nil when the read has no event
    /// (⇒ no snapshot to fetch, the row keeps its placeholder).
    private func imagesFetcher(for read: PlateRead) -> (() async -> (PlatformImage?, PlatformImage?))? {
        guard let eventId = read.eventId else { return nil }
        let vm = vm
        return { await vm.images(for: eventId, bbox: read.bbox) }
    }

    private func addToWatchlist(_ plate: String) {
        Task {
            let err = await vm.addToWatchlist(plate: plate, label: nil, notify: true)
            flash(err ?? "Added \(plate) to watchlist")
        }
    }

    /// Play the plate-hit clip for a read. The clip id `d:<eventId>` resolves to
    /// `/clip/d:<eventId>/clip.mp4?q=preview`, which the server windows with the
    /// backward-weighted `plate_window` (ts-8s … ts+4s) so playback lands ON the
    /// car — unlike seeking the timeline at the raw read ts (which is after the
    /// pass, when the car has already left frame).
    private func openReadClip(_ read: PlateRead) {
        guard let eventId = read.eventId else {
            if let d = parseISO8601(read.ts) { onOpenPlayback(read.cameraId, d) }
            return
        }
        let ts = parseISO8601(read.ts) ?? Date()
        let iso = ISO8601DateFormatter()
        playingClip = ClipDescriptor(
            id: "d:\(eventId)",
            cameraId: read.cameraId,
            cameraName: vm.cameraName(read.cameraId),
            kind: "detection",
            label: read.resolvedName ?? (read.plate.isEmpty ? "license_plate" : read.plate),
            iconKey: "car",
            score: read.confidence.map(Float.init),
            startTs: iso.string(from: ts.addingTimeInterval(-8)),
            endTs: iso.string(from: ts.addingTimeInterval(4)),
            durationMs: 12000,
            thumbnailUrl: "", clipUrl: "", downloadUrl: "",
            source: "crumb", viewed: true, motionBbox: nil
        )
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }
}

// MARK: - Plate name

private extension PlateRead {
    /// The operator-assigned plate name, trimmed; nil when absent or blank so
    /// the UI falls back to the raw plate exactly as before. Precedence between
    /// a first-class name and a legacy watchlist label is resolved server-side.
    var resolvedName: String? { PlateNaming.resolvedName(displayName) }
}

private extension WatchlistEntry {
    /// The operator-assigned plate name, trimmed; nil when absent or blank.
    var resolvedName: String? { PlateNaming.resolvedName(displayName) }
}

/// A plate the operator asked to name; drives the `PlateNameSheet`. Keyed on
/// the raw plate, which is also the server's upsert key.
private struct PlateNameTarget: Identifiable {
    let plate: String
    /// The name currently shown for this plate, for prefill (nil = unnamed).
    let current: String?
    var id: String { plate }
}

// MARK: - Copy affordance

/// The copy button that sits next to a plate number. Copies the RAW plate even
/// when an operator-assigned name is the prominent line above it, then flips to
/// a checkmark for a moment so the operator can see it landed. Right-click /
/// long-press "Copy plate number" on the surrounding row does the same thing.
private struct CopyPlateButton: View {
    let plate: String
    /// The name shown for this plate, if any — passed only so the copy target
    /// is chosen explicitly (it is always the plate, never the name).
    var displayName: String? = nil
    var size: CGFloat = 12
    /// Optional extra confirmation (the Plates tab raises a toast).
    var onCopied: ((String) -> Void)? = nil

    @State private var copied = false

    var body: some View {
        Button {
            copy()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(copied ? CrumbColors.tealAccent : CrumbColors.textTertiary)
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy plate number")
        .accessibilityLabel(copied ? "Plate number copied" : "Copy plate number")
    }

    private func copy() {
        guard let value = PlateNaming.copyTarget(plate: plate, displayName: displayName),
              CrumbClipboard.copy(value) else { return }
        onCopied?(value)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { copied = false }
        }
    }
}

/// The shared context menu for any surface showing a plate: copy the number,
/// and (admin only) name/rename it. Naming is display metadata — the menu keeps
/// it visibly separate from the watchlist action, which is the alert list.
@ViewBuilder
private func plateContextMenu(
    plate: String,
    displayName: String?,
    onCopied: @escaping (String) -> Void,
    onName: (() -> Void)?
) -> some View {
    Button {
        guard let value = PlateNaming.copyTarget(plate: plate, displayName: displayName),
              CrumbClipboard.copy(value) else { return }
        onCopied(value)
    } label: {
        Label("Copy plate number", systemImage: "doc.on.doc")
    }
    if let onName {
        Button(action: onName) {
            Label(
                PlateNaming.resolvedName(displayName) == nil ? "Name this plate…" : "Rename this plate…",
                systemImage: "tag"
            )
        }
    }
}

// MARK: - Plate row

private struct PlateRow: View {
    let read: PlateRead
    /// Collapsed-group size; > 1 renders the "×N" badge.
    let count: Int
    let cameraName: String
    let canWatch: Bool
    let watched: Bool
    let display: PlateImageDisplay
    /// Loads (full, crop) images (nil when the read has no event).
    let fetchImages: (() async -> (PlatformImage?, PlatformImage?))?
    let onOpenPlayback: (() -> Void)?
    let onAddToWatchlist: (() -> Void)?
    /// Raise the tab's transient confirmation ("Copied ABC123").
    let onCopied: (String) -> Void
    /// Open the name editor for this plate; nil for a non-admin (the naming
    /// endpoints are admin-only, so the control is hidden rather than 403'd).
    let onName: (() -> Void)?

    @State private var full: PlatformImage?
    @State private var crop: PlatformImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let name = read.resolvedName {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(CrumbColors.textPrimary)
                                .lineLimit(1)
                            Text(read.plate.isEmpty ? "—" : read.plate)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(CrumbColors.textSecondary)
                        }
                    } else {
                        Text(read.plate.isEmpty ? "—" : read.plate)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundColor(CrumbColors.textPrimary)
                    }
                    if !read.plate.isEmpty {
                        CopyPlateButton(
                            plate: read.plate, displayName: read.displayName, onCopied: onCopied
                        )
                    }
                    if count > 1 {
                        Text("×\(count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundColor(CrumbColors.tealAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(CrumbColors.tealAccent.opacity(0.18), in: Capsule())
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "video").font(.system(size: 11)).foregroundColor(CrumbColors.textTertiary)
                    Text(cameraName).font(.caption).foregroundColor(CrumbColors.textSecondary)
                        .lineLimit(1)
                    if let region = read.region, !region.isEmpty {
                        Text(region).font(.caption2).foregroundColor(CrumbColors.textTertiary)
                    }
                }
                Text(Self.formatTs(read.ts)).font(.caption2).foregroundColor(CrumbColors.textTertiary)
            }
            Spacer(minLength: 4)
            ConfidenceChip(confidence: read.confidence)
            if canWatch, let onAddToWatchlist {
                Button(action: onAddToWatchlist) {
                    Image(systemName: watched ? "star.fill" : "star")
                        .font(.system(size: 15))
                        .foregroundColor(watched ? CrumbColors.bookmarkGold : CrumbColors.textTertiary)
                }
                .buttonStyle(.plain)
                .help(watched ? "On watchlist" : "Add to watchlist")
            }
            if onOpenPlayback != nil {
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(CrumbColors.textTertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onOpenPlayback?() }
        .contextMenu {
            plateContextMenu(
                plate: read.plate, displayName: read.displayName,
                onCopied: onCopied, onName: onName
            )
            if let onAddToWatchlist {
                Divider()
                Button(action: onAddToWatchlist) {
                    Label(watched ? "On watchlist" : "Add to watchlist", systemImage: "star")
                }
                .disabled(watched)
            }
        }
        .task(id: read.id) {
            // Off the row's critical path; the VM caches by event id so
            // re-scrolls resolve instantly without a refetch.
            guard full == nil, crop == nil, let fetchImages else { return }
            let pair = await fetchImages()
            full = pair.0; crop = pair.1
        }
    }

    /// Full frame (~16:9), tight crop, or both side-by-side per the display mode;
    /// a neutral car placeholder while loading or when there's no event/snapshot.
    @ViewBuilder private var thumbnail: some View {
        HStack(spacing: 4) {
            if display != .crop {
                imageBox(full, width: 72) // full frame, 16:9-ish
            }
            if display != .full {
                imageBox(crop, width: 56) // tight plate crop
            }
        }
    }

    private func imageBox(_ image: PlatformImage?, width: CGFloat) -> some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    CrumbColors.surfaceVariant
                    Image(systemName: "car.fill").font(.system(size: 15)).foregroundColor(CrumbColors.textTertiary)
                }
            }
        }
        .frame(width: width, height: 40)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Local time, 12-hour with seconds — e.g. "Jul 13, 3:07:09 PM".
    private static func formatTs(_ iso: String) -> String {
        guard let date = parseISO8601(iso) else { return iso }
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm:ss a"
        return f.string(from: date)
    }
}

// MARK: - Plate card (gallery layout)

private struct PlateCard: View {
    let read: PlateRead
    let count: Int
    let cameraName: String
    let canWatch: Bool
    let watched: Bool
    let fetchImages: (() async -> (PlatformImage?, PlatformImage?))?
    let onOpenPlayback: (() -> Void)?
    let onAddToWatchlist: (() -> Void)?
    /// Raise the tab's transient confirmation ("Copied ABC123").
    let onCopied: (String) -> Void
    /// Open the name editor for this plate; nil for a non-admin.
    let onName: (() -> Void)?

    @State private var full: PlatformImage?
    @State private var crop: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                image
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .clipped()
                if count > 1 {
                    Text("×\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit()).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if let name = read.resolvedName {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(CrumbColors.textPrimary).lineLimit(1)
                            Text(read.plate.isEmpty ? "—" : read.plate)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(CrumbColors.textSecondary).lineLimit(1)
                        }
                    } else {
                        Text(read.plate.isEmpty ? "—" : read.plate)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(CrumbColors.textPrimary).lineLimit(1)
                    }
                    if !read.plate.isEmpty {
                        CopyPlateButton(
                            plate: read.plate, displayName: read.displayName,
                            size: 11, onCopied: onCopied
                        )
                    }
                    Spacer()
                    ConfidenceChip(confidence: read.confidence)
                }
                HStack(spacing: 4) {
                    Image(systemName: "video").font(.system(size: 10)).foregroundColor(CrumbColors.textTertiary)
                    Text(cameraName).font(.caption2).foregroundColor(CrumbColors.textSecondary).lineLimit(1)
                    Spacer()
                    if canWatch, let onAddToWatchlist {
                        Button(action: onAddToWatchlist) {
                            Image(systemName: watched ? "star.fill" : "star")
                                .font(.system(size: 13))
                                .foregroundColor(watched ? CrumbColors.bookmarkGold : CrumbColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(8)
        }
        .background(CrumbColors.surface, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { onOpenPlayback?() }
        .contextMenu {
            plateContextMenu(
                plate: read.plate, displayName: read.displayName,
                onCopied: onCopied, onName: onName
            )
            if let onAddToWatchlist {
                Divider()
                Button(action: onAddToWatchlist) {
                    Label(watched ? "On watchlist" : "Add to watchlist", systemImage: "star")
                }
                .disabled(watched)
            }
        }
        .task(id: read.id) {
            guard full == nil, crop == nil, let fetchImages else { return }
            let pair = await fetchImages()
            full = pair.0; crop = pair.1
        }
    }

    /// Prefer the full frame for context; fall back to the crop, then a placeholder.
    @ViewBuilder private var image: some View {
        if let img = full ?? crop {
            Image(platformImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                CrumbColors.surfaceVariant
                Image(systemName: "car.fill").font(.system(size: 22)).foregroundColor(CrumbColors.textTertiary)
            }
        }
    }
}

// MARK: - Confidence chip

private struct ConfidenceChip: View {
    let confidence: Double?

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }

    private var text: String {
        guard let c = confidence else { return "—" }
        return "\(Int((c * 100).rounded()))%"
    }
    private var color: Color {
        guard let c = confidence else { return CrumbColors.textTertiary }
        if c >= 0.85 { return Color(hex: 0x57C888) }
        if c >= 0.6 { return Color(hex: 0xE8A33D) }
        return Color(hex: 0xD65C5C)
    }
}

// MARK: - Plate name sheet

/// Set, edit, or clear a plate's human-readable name (issue #363). Mirrors the
/// web console's `namePlate()`: prefilled with the name currently shown, and a
/// blank field clears it.
///
/// Admin-only — `PUT`/`DELETE /lpr/plate-labels` are admin-gated server-side and
/// the affordances that open this sheet are hidden for everyone else.
///
/// The footer says plainly that a name is not an alert, because the watchlist
/// (which *is* the alert list) is one control away on the same tab.
private struct PlateNameSheet: View {
    @ObservedObject var vm: PlatesViewModel
    let target: PlateNameTarget
    /// Raise the tab's transient confirmation.
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var formError: String?
    @State private var busy = false

    init(vm: PlatesViewModel, target: PlateNameTarget, onDone: @escaping (String) -> Void) {
        self.vm = vm
        self.target = target
        self.onDone = onDone
        _name = State(initialValue: target.current ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Plate") {
                    HStack(spacing: 8) {
                        Text(target.plate)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundColor(CrumbColors.textPrimary)
                            .textSelection(.enabled)
                        CopyPlateButton(plate: target.plate, displayName: target.current, size: 13)
                        Spacer()
                    }
                }
                Section {
                    TextField("Name (e.g. Delivery van)", text: $name)
                        .autocorrectionDisabled()
                    if let formError {
                        Text(formError).font(.caption).foregroundColor(CrumbColors.error)
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text(
                        "Shown wherever this plate appears. Naming a plate does not add it "
                        + "to the watchlist and never triggers an alert. Leave blank to clear the name."
                    )
                    .font(.caption)
                    .foregroundColor(CrumbColors.textTertiary)
                }
                #if os(macOS)
                // macOS sheets don't reliably render the nav-bar toolbar, so the
                // Cancel/Save pair also lives in the body here (same reason the
                // watchlist sheet carries its own Done row).
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundColor(CrumbColors.textSecondary)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button { Task { await save() } } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .foregroundColor(CrumbColors.tealAccent)
                    .keyboardShortcut(.defaultAction)
                }
                .listRowSeparator(.hidden)
                #endif
            }
            .navigationTitle(target.current == nil ? "Name plate" : "Rename plate")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(CrumbColors.textSecondary)
                }
                ToolbarItem(placement: .barTrailing) {
                    Button { Task { await save() } } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .disabled(busy)
                    .foregroundColor(CrumbColors.tealAccent)
                }
            }
        }
    }

    private func save() async {
        busy = true
        let action = PlateNaming.action(input: name, current: target.current)
        let err = await vm.namePlate(target.plate, name: name, current: target.current)
        busy = false
        if let err {
            formError = err
            return
        }
        switch action {
        case .set: onDone("Plate named.")
        case .clear: onDone("Name cleared.")
        case .noChange: break
        }
        dismiss()
    }
}

// MARK: - Watchlist sheet

private struct WatchlistSheet: View {
    @ObservedObject var vm: PlatesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newPlate = ""
    @State private var newLabel = ""
    @State private var newNotify = true
    @State private var formError: String?
    @State private var busy = false
    /// Entry being edited (admin taps a row); drives the edit sheet.
    @State private var editing: WatchlistEntry?
    /// Plate whose name is being edited (admin only); nil = sheet closed.
    @State private var naming: PlateNameTarget?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                #if os(macOS)
                // macOS sheets don't reliably render the nav-bar toolbar, so give
                // the watchlist an explicit, visible close row (Esc also works).
                HStack {
                    Text("Watchlist").font(.headline).foregroundColor(CrumbColors.textPrimary)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundColor(CrumbColors.tealAccent)
                        .keyboardShortcut(.cancelAction)
                }
                .listRowSeparator(.hidden)
                #endif
                if vm.isAdmin {
                    Section("Add plate") {
                        TextField("Plate (e.g. ABC123)", text: $newPlate)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                        TextField("Label (optional)", text: $newLabel)
                        Toggle("Notify when seen", isOn: $newNotify)
                            .tint(CrumbColors.teal)
                        if vm.watchlistFuzz != nil { fuzzControl }
                        if let formError {
                            Text(formError).font(.caption).foregroundColor(CrumbColors.error)
                        }
                        Button {
                            Task { await add() }
                        } label: {
                            HStack {
                                if busy { ProgressView().controlSize(.small) }
                                Text("Add to watchlist")
                            }
                        }
                        .disabled(busy || newPlate.trimmingCharacters(in: .whitespaces).isEmpty)
                        .foregroundColor(CrumbColors.tealAccent)
                    }
                } else {
                    Section {
                        Text("Only admins can manage the watchlist.")
                            .font(.caption).foregroundColor(CrumbColors.textTertiary)
                    }
                }

                Section(vm.watchlist.isEmpty ? "Watchlist" : "Watchlist (\(vm.watchlist.count))") {
                    if let err = vm.watchlistError {
                        Text(err).font(.caption).foregroundColor(CrumbColors.error)
                    }
                    if vm.watchlist.isEmpty {
                        Text("No plates on the watchlist.")
                            .font(.caption).foregroundColor(CrumbColors.textTertiary)
                    }
                    ForEach(vm.watchlist) { entry in
                        WatchlistRow(
                            entry: entry,
                            canRemove: vm.isAdmin,
                            onRemove: { Task { await remove(entry) } },
                            onCopied: { flash("Copied \($0)") },
                            onName: vm.isAdmin && !entry.plate.isEmpty
                                ? { naming = PlateNameTarget(plate: entry.plate, current: entry.resolvedName) }
                                : nil
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { if vm.isAdmin { editing = entry } }
                    }
                }
            }
            .navigationTitle("Watchlist")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .barTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(CrumbColors.tealAccent)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium)).foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.78)))
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .task { vm.loadWatchlist(); vm.loadLprConfig() }
        .sheet(item: $editing) { entry in
            WatchlistEditSheet(vm: vm, entry: entry)
                .macModalSize(width: 420, height: 420)
        }
        .sheet(item: $naming) { target in
            PlateNameSheet(vm: vm, target: target) { flash($0) }
                .macModalSize(width: 420, height: 340)
        }
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    /// Admin fuzziness slider + live "up to N edits" preview. The edit budget is
    /// computed by the same `Lpr` matcher the server uses, off the plate being
    /// typed (or a sample when empty).
    private var fuzzControl: some View {
        let fuzz = vm.watchlistFuzz ?? 0
        let basis = newPlate.trimmingCharacters(in: .whitespaces).isEmpty ? "7ABC123" : newPlate
        let edits = Lpr.allowedEdits(reference: basis, fuzz: fuzz)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Fuzziness").font(.caption).foregroundColor(CrumbColors.textSecondary)
                Spacer()
                Text(edits == 0 ? "Exact" : "\(Int((fuzz * 100).rounded()))% · up to \(edits) char\(edits == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit()).foregroundColor(CrumbColors.tealAccent)
            }
            Slider(
                value: Binding(get: { vm.watchlistFuzz ?? 0 }, set: { vm.watchlistFuzz = $0 }),
                in: 0...0.5, step: 0.01,
                onEditingChanged: { editing in if !editing { vm.saveFuzz(vm.watchlistFuzz ?? 0) } }
            )
            .tint(CrumbColors.teal)
        }
    }

    private func add() async {
        busy = true
        formError = await vm.addToWatchlist(
            plate: newPlate, label: newLabel, notify: newNotify, kind: "watch"
        )
        busy = false
        if formError == nil { newPlate = ""; newLabel = ""; newNotify = true }
    }

    private func remove(_ entry: WatchlistEntry) async {
        if let err = await vm.removeFromWatchlist(entry) {
            vm.watchlistError = err
        }
    }
}

private struct WatchlistRow: View {
    let entry: WatchlistEntry
    let canRemove: Bool
    let onRemove: () -> Void
    /// Raise the sheet's transient confirmation ("Copied ABC123").
    var onCopied: ((String) -> Void)? = nil
    /// Open the name editor for this plate; nil for a non-admin.
    var onName: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let c = Self.color(from: entry.color) {
                Circle().fill(c).frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let name = entry.resolvedName {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundColor(CrumbColors.textPrimary)
                    Text(entry.plate)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundColor(CrumbColors.textSecondary)
                } else {
                    Text(entry.plate)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundColor(CrumbColors.textPrimary)
                }
                if let label = entry.label, !label.isEmpty {
                    Text(label).font(.caption).foregroundColor(CrumbColors.textSecondary)
                }
            }
            if !entry.plate.isEmpty {
                CopyPlateButton(
                    plate: entry.plate, displayName: entry.displayName, onCopied: onCopied
                )
            }
            Spacer()
            if entry.kind == "ignore" {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13))
                    .foregroundColor(CrumbColors.textTertiary)
                    .help("Ignored plate")
            }
            Image(systemName: entry.notify ? "bell.fill" : "bell.slash")
                .font(.system(size: 13))
                .foregroundColor(entry.notify ? CrumbColors.tealAccent : CrumbColors.textTertiary)
            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash").font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(CrumbColors.error)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            plateContextMenu(
                plate: entry.plate, displayName: entry.displayName,
                onCopied: { onCopied?($0) }, onName: onName
            )
        }
    }

    /// Parse a `#rrggbb` (or `rrggbb`) string into a `Color`, or nil.
    static func color(from hex: String?) -> Color? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt(s, radix: 16) else { return nil }
        return Color(hex: value)
    }
}

// MARK: - Watchlist edit sheet

/// Edit an existing watchlist entry (admin only). The plate is the server's
/// upsert key so it's shown read-only; saving re-POSTs through
/// `addToWatchlist`, round-tripping the entry's `note`/`color` so an edit
/// doesn't wipe fields this sheet doesn't expose.
private struct WatchlistEditSheet: View {
    @ObservedObject var vm: PlatesViewModel
    let entry: WatchlistEntry
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var kind: String
    @State private var notify: Bool
    @State private var formError: String?
    @State private var busy = false

    init(vm: PlatesViewModel, entry: WatchlistEntry) {
        self.vm = vm
        self.entry = entry
        _label = State(initialValue: entry.label ?? "")
        _kind = State(initialValue: entry.kind == "ignore" ? "ignore" : "watch")
        _notify = State(initialValue: entry.notify)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Plate") {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let name = entry.resolvedName {
                                Text(name)
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(CrumbColors.textPrimary)
                            }
                            Text(entry.plate)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .foregroundColor(CrumbColors.textSecondary)
                        }
                        CopyPlateButton(plate: entry.plate, displayName: entry.displayName, size: 13)
                        Spacer()
                    }
                }
                Section {
                    TextField("Label (optional)", text: $label)
                    Picker("Kind", selection: $kind) {
                        Text("Watch").tag("watch")
                        Text("Ignore").tag("ignore")
                    }
                    .pickerStyle(.segmented)
                    if kind == "watch" {
                        Toggle("Notify when seen", isOn: $notify)
                            .tint(CrumbColors.teal)
                    }
                    if let formError {
                        Text(formError).font(.caption).foregroundColor(CrumbColors.error)
                    }
                } header: {
                    Text("Details")
                } footer: {
                    Text(
                        "This label belongs to the watchlist entry. A plate name set with "
                        + "\"Rename this plate\" wins over it wherever the plate is shown."
                    )
                    .font(.caption)
                    .foregroundColor(CrumbColors.textTertiary)
                }
            }
            .navigationTitle("Edit plate")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(CrumbColors.textSecondary)
                }
                ToolbarItem(placement: .barTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .disabled(busy)
                    .foregroundColor(CrumbColors.tealAccent)
                }
            }
        }
    }

    private func save() async {
        busy = true
        let err = await vm.addToWatchlist(
            plate: entry.plate, label: label, notify: notify,
            note: entry.note, color: entry.color, kind: kind
        )
        busy = false
        if let err {
            formError = err
        } else {
            dismiss()
        }
    }
}
