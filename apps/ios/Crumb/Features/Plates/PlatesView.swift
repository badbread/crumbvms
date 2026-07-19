// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Plate-match mode. `contains` is the default; the server also supports
/// `prefix`, `exact`, and `fuzzy` (similarity-ordered).
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
    @Published var collapse: Bool = UserDefaults.standard.object(forKey: "plates_collapse") as? Bool ?? true {
        didSet { UserDefaults.standard.set(collapse, forKey: "plates_collapse") }
    }

    // Watchlist
    @Published var watchlist: [WatchlistEntry] = []
    @Published var watchlistError: String?

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

    /// Decoded plate-crop thumbnails by event id — cached so re-scrolls don't
    /// refetch or re-decode. Main-actor (the whole class is `@MainActor`).
    private var thumbCache: [String: PlatformImage] = [:]

    /// Fetch the snapshot for `eventId` and crop it to the plate `bbox`
    /// (cached). Returns nil on any failure — the row keeps its placeholder.
    func thumb(for eventId: String, bbox: [Double]?) async -> PlatformImage? {
        if let cached = thumbCache[eventId] { return cached }
        guard let data = try? await container.api.plateSnapshot(eventId: eventId),
              let img = PlateCrop.crop(data, bbox: bbox) else { return nil }
        thumbCache[eventId] = img
        return img
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
                LazyVStack(spacing: 0) {
                    ForEach(vm.groups) { group in
                        if let read = vm.plateRead(byId: group.representative.id) {
                            PlateRow(
                                read: read,
                                count: group.count,
                                cameraName: vm.cameraName(read.cameraId),
                                canWatch: vm.isAdmin,
                                watched: vm.isWatched(read.plate),
                                fetchThumb: thumbFetcher(for: read),
                                onOpenPlayback: read.eventId != nil ? {
                                    if let d = parseISO8601(read.ts) { onOpenPlayback(read.cameraId, d) }
                                } : nil,
                                onAddToWatchlist: vm.isAdmin ? { addToWatchlist(read.plate) } : nil
                            )
                            Divider().overlay(CrumbColors.surface)
                        }
                    }
                }
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        VStack { Spacer(); v(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Async thumbnail loader for a row, or nil when the read has no event
    /// (⇒ no snapshot to fetch, the row keeps its placeholder).
    private func thumbFetcher(for read: PlateRead) -> (() async -> PlatformImage?)? {
        guard let eventId = read.eventId else { return nil }
        let vm = vm
        return { await vm.thumb(for: eventId, bbox: read.bbox) }
    }

    private func addToWatchlist(_ plate: String) {
        Task {
            let err = await vm.addToWatchlist(plate: plate, label: nil, notify: true)
            flash(err ?? "Added \(plate) to watchlist")
        }
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
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
    /// Loads the plate-crop thumbnail (nil when the read has no event).
    let fetchThumb: (() async -> PlatformImage?)?
    let onOpenPlayback: (() -> Void)?
    let onAddToWatchlist: (() -> Void)?

    @State private var thumb: PlatformImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(read.plate.isEmpty ? "—" : read.plate)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(CrumbColors.textPrimary)
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
        .task(id: read.id) {
            // Off the row's critical path; the VM caches by event id so
            // re-scrolls resolve instantly without a refetch.
            guard thumb == nil, let fetchThumb else { return }
            thumb = await fetchThumb()
        }
    }

    /// Plate-crop thumbnail; a neutral car placeholder while loading or when
    /// the read has no event/snapshot.
    @ViewBuilder private var thumbnail: some View {
        Group {
            if let thumb {
                Image(platformImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    CrumbColors.surfaceVariant
                    Image(systemName: "car.fill")
                        .font(.system(size: 15))
                        .foregroundColor(CrumbColors.textTertiary)
                }
            }
        }
        .frame(width: 56, height: 40)
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

    var body: some View {
        NavigationStack {
            List {
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
                        WatchlistRow(entry: entry, canRemove: vm.isAdmin) {
                            Task { await remove(entry) }
                        }
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
        .task { vm.loadWatchlist() }
        .sheet(item: $editing) { entry in
            WatchlistEditSheet(vm: vm, entry: entry)
                .macModalSize(width: 420, height: 420)
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

    var body: some View {
        HStack(spacing: 10) {
            if let c = Self.color(from: entry.color) {
                Circle().fill(c).frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.plate)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundColor(CrumbColors.textPrimary)
                if let label = entry.label, !label.isEmpty {
                    Text(label).font(.caption).foregroundColor(CrumbColors.textSecondary)
                }
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
                    Text(entry.plate)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundColor(CrumbColors.textSecondary)
                }
                Section("Details") {
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
