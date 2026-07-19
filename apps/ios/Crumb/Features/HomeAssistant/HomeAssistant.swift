// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Home Assistant on-video overlays + read-only entity sheet, at parity with the
/// desktop badge overlay and the Android per-camera entity sheet.
///
/// Read-only by design (matches Android/desktop POC): the client renders linked
/// entities and their live states; linking/placement/config is admin-only and
/// lives in the web console / desktop editor. Both surfaces here use only the two
/// viewer-accessible endpoints `GET /cameras/:id/ha/links` and `GET /ha/states`.
///
/// State-honesty invariant (mirrors the recorder's `edge_on` rail): an
/// `unavailable`/`unknown`/empty state, or a `stale` snapshot, is NEVER rendered
/// as "off"/"closed" — it shows grey/indeterminate.

// MARK: - Visual mapping (SF Symbol port of desktop ha_icons.dart)

struct HAVisual {
    let symbol: String
    let color: Color
    let stateText: String
    let indeterminate: Bool
}

enum HA {
    // Palette (from desktop ha_icons.dart).
    static let grey = Color(hex: 0x8E8E93)
    static let amber = Color(hex: 0xFFB143)
    static let neutral = Color(hex: 0xB9C2CC)
    static let blue = Color(hex: 0x33C3FF)
    static let green = Color(hex: 0x2BA84A)
    static let warmYellow = Color(hex: 0xFFCC33)

    /// On/off/indeterminate edge, mirroring backend `edge_on`. Returns nil for
    /// anything not explicitly on or off (incl. unavailable/unknown/"").
    static func edgeOn(_ state: String) -> Bool? {
        switch state.lowercased() {
        case "on", "open", "detected", "true", "home", "motion", "occupied": return true
        case "off", "closed", "clear", "false", "not_home", "no_motion": return false
        default: return nil
        }
    }

    /// device_class → coarse class, mirroring backend `label_for_device_class`.
    static func classForDeviceClass(_ dc: String?) -> String {
        switch (dc ?? "").lowercased() {
        case "motion", "moving", "vibration": return "motion"
        case "occupancy", "presence": return "occupancy"
        case "door", "opening": return "door"
        case "window": return "window"
        case "garage_door": return "garage"
        default: return "sensor"
        }
    }

    /// Relative age of a last-changed RFC3339 timestamp.
    static func relativeAgo(_ lastChanged: String?) -> String? {
        guard let s = lastChanged, let date = parseISO8601(s) else { return nil }
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    /// Resolve the badge visual for a link + its live state.
    static func visual(for link: HaLink, state: HaEntityState?, stale: Bool) -> HAVisual {
        let raw = state?.state ?? ""
        let domain = link.domain
        let on = edgeOn(raw)

        // Scene is stateless.
        if domain == "scene" {
            return applyOverrides(link, base: HAVisual(symbol: "film", color: neutral, stateText: "Scene", indeterminate: false), on: nil)
        }

        // Indeterminate (unknown/unavailable/stale) → grey, honest state text.
        if stale || state == nil || (on == nil && domain != "light" && domain != "switch") {
            let sym = baseSymbol(domain: domain, deviceClass: link.deviceClass, on: false)
            let text = raw.isEmpty ? "Unknown" : raw.capitalized
            return HAVisual(symbol: overrideSymbol(link) ?? sym, color: grey, stateText: text, indeterminate: true)
        }

        // Known reading.
        let isOn = (on ?? (raw.lowercased() == "on"))
        let base: HAVisual
        switch domain {
        case "light":
            base = HAVisual(symbol: isOn ? "lightbulb.fill" : "lightbulb",
                            color: isOn ? warmYellow : grey, stateText: isOn ? "On" : "Off", indeterminate: false)
        case "switch":
            base = HAVisual(symbol: "power",
                            color: isOn ? green : grey, stateText: isOn ? "On" : "Off", indeterminate: false)
        default:
            base = classVisual(HA.classForDeviceClass(link.deviceClass), on: isOn)
        }
        return applyOverrides(link, base: base, on: isOn)
    }

    private static func classVisual(_ cls: String, on: Bool) -> HAVisual {
        switch cls {
        case "door":
            return HAVisual(symbol: on ? "door.left.hand.open" : "door.left.hand.closed",
                            color: on ? amber : neutral, stateText: on ? "Open" : "Closed", indeterminate: false)
        case "window":
            return HAVisual(symbol: on ? "window.vertical.open" : "window.vertical.closed",
                            color: on ? amber : neutral, stateText: on ? "Open" : "Closed", indeterminate: false)
        case "garage":
            return HAVisual(symbol: on ? "door.garage.open" : "door.garage.closed",
                            color: on ? amber : neutral, stateText: on ? "Open" : "Closed", indeterminate: false)
        case "motion":
            return HAVisual(symbol: "figure.run", color: on ? blue : grey,
                            stateText: on ? "Motion" : "Clear", indeterminate: false)
        case "occupancy":
            return HAVisual(symbol: "person.fill", color: on ? blue : grey,
                            stateText: on ? "Occupied" : "Clear", indeterminate: false)
        default:
            return HAVisual(symbol: "sensor.fill", color: on ? blue : grey,
                            stateText: on ? "Active" : "Clear", indeterminate: false)
        }
    }

    private static func baseSymbol(domain: String, deviceClass: String?, on: Bool) -> String {
        switch domain {
        case "light": return "lightbulb"
        case "switch": return "power"
        case "scene": return "film"
        default: return classVisual(HA.classForDeviceClass(deviceClass), on: on).symbol
        }
    }

    /// Apply `overlay_icon` (always) and `overlay_color` (only on a KNOWN
    /// reading; full when on, 45% when off; never on indeterminate).
    private static func applyOverrides(_ link: HaLink, base: HAVisual, on: Bool?) -> HAVisual {
        var symbol = base.symbol
        if let sym = overrideSymbol(link) { symbol = sym }
        var color = base.color
        if !base.indeterminate, let hex = link.overlayColor, let c = colorFromHex(hex) {
            color = (on == false) ? c.opacity(0.45) : c
        }
        return HAVisual(symbol: symbol, color: color, stateText: base.stateText, indeterminate: base.indeterminate)
    }

    private static func overrideSymbol(_ link: HaLink) -> String? {
        guard let slug = link.overlayIcon, !slug.isEmpty else { return nil }
        return iconSlugToSymbol[slug]
    }

    /// Curated overlay-icon slug → SF Symbol (subset of the desktop set; unknown
    /// slugs fall back to the class default).
    static let iconSlugToSymbol: [String: String] = [
        "door": "door.left.hand.closed", "garage": "door.garage.closed",
        "window": "window.vertical.closed", "motion": "figure.run",
        "occupancy": "person.fill", "presence": "person.fill", "person": "person.fill",
        "doorbell": "bell.fill", "bell": "bell.fill", "lock": "lock.fill", "unlock": "lock.open.fill",
        "lightbulb": "lightbulb.fill", "light": "lightbulb.fill", "power": "power",
        "switch": "power", "outlet": "poweroutlet.type.b.fill", "plug": "powerplug.fill",
        "thermostat": "thermometer", "temperature": "thermometer", "humidity": "humidity.fill",
        "fan": "fan.fill", "camera": "video.fill", "car": "car.fill", "gate": "door.garage.closed",
        "water": "drop.fill", "leak": "drop.fill", "smoke": "smoke.fill", "co": "carbon.dioxide.cloud.fill",
        "fire": "flame.fill", "alarm": "alarm.fill", "shield": "shield.fill", "scene": "film",
        "sensor": "sensor.fill", "lightswitch": "power", "sun": "sun.max.fill", "moon": "moon.fill",
    ]

    static func colorFromHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt(s, radix: 16) else { return nil }
        return Color(hex: v)
    }
}

// MARK: - Controller (per-camera links + polled states)

@MainActor
final class HAController: ObservableObject {
    @Published private(set) var links: [HaLink] = []
    @Published private(set) var states: HaStatesResponse?
    /// True when the served snapshot is stale (HA unreachable) or we've missed
    /// two consecutive polls — badges grey out.
    @Published private(set) var stale = false

    private let container: AppContainer
    private var cameraId: String?
    private var pollTask: Task<Void, Never>?
    private var missStreak = 0

    init(container: AppContainer) { self.container = container }

    /// Only links with a placement render as on-video badges.
    var placedLinks: [HaLink] { links.filter(\.hasPlacement) }
    var hasLinks: Bool { !links.isEmpty }

    func state(for entityId: String) -> HaEntityState? { states?.state(for: entityId) }

    /// Point at a camera: load its links, and (re)start state polling if it has
    /// any. Idempotent per camera id.
    func activate(cameraId: String) {
        if self.cameraId == cameraId, !links.isEmpty { return }
        self.cameraId = cameraId
        links = []
        Task { [weak self] in
            guard let self else { return }
            let fetched = (try? await container.api.haLinks(cameraId: cameraId)) ?? []
            guard self.cameraId == cameraId else { return }
            links = fetched
            startPolling()
        }
    }

    func startPolling() {
        pollTask?.cancel()
        guard !links.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
    }

    private func pollOnce() async {
        do {
            let resp = try await container.api.haStates()
            states = resp
            // Stale if the server says so, or two consecutive client misses.
            if resp.stale { missStreak = min(missStreak + 1, 2) } else { missStreak = 0 }
            stale = resp.stale
        } catch {
            missStreak += 1
            if missStreak >= 2 { stale = true }
        }
    }

    deinit { pollTask?.cancel() }
}

// MARK: - On-video badge overlay

/// Positions HA badges over the letterboxed video frame. `videoSize` is the
/// decoded pixel size (from `Fmp4VideoView.onVideoSize`); until it's known,
/// nothing is drawn (prevents misplaced badges).
struct HAOverlayLayer: View {
    @ObservedObject var controller: HAController
    let videoSize: CGSize?

    @State private var tapped: HaLink?

    var body: some View {
        GeometryReader { geo in
            if let vs = videoSize, vs.width > 0, vs.height > 0, !controller.placedLinks.isEmpty {
                let field = fieldRect(pane: geo.size, video: vs)
                let scale = paneScale(geo.size)
                ZStack(alignment: .topLeading) {
                    ForEach(controller.placedLinks) { link in
                        badge(link, field: field, scale: scale)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .sheet(item: $tapped) { link in
            HAStateCard(link: link, state: controller.state(for: link.entityId), stale: controller.stale)
                .macModalSize(width: 360, height: 300)
        }
    }

    @ViewBuilder
    private func badge(_ link: HaLink, field: CGRect, scale: CGFloat) -> some View {
        let side = max(8, 22 * CGFloat(link.overlaySize ?? 1) * scale)
        let x = field.minX + CGFloat(link.overlayX ?? 0) * field.width
        let y = field.minY + CGFloat(link.overlayY ?? 0) * field.height
        HABadge(
            link: link,
            visual: HA.visual(for: link, state: controller.state(for: link.entityId), stale: controller.stale),
            side: side,
            age: link.overlayShowAge ? HA.relativeAgo(controller.state(for: link.entityId)?.lastChanged) : nil
        )
        .opacity(link.overlayOpacity ?? 1)
        .offset(x: min(max(x, field.minX), field.maxX), y: min(max(y, field.minY), field.maxY))
        .onTapGesture { tapped = link }
    }

    /// Letterboxed (BoxFit.contain) frame of the video within the pane.
    private func fieldRect(pane: CGSize, video: CGSize) -> CGRect {
        let s = min(pane.width / video.width, pane.height / video.height)
        let fw = video.width * s, fh = video.height * s
        return CGRect(x: (pane.width - fw) / 2, y: (pane.height - fh) / 2, width: fw, height: fh)
    }

    private func paneScale(_ pane: CGSize) -> CGFloat {
        min(max(min(pane.width, pane.height) / 320, 0.5), 3.0)
    }
}

/// A single badge: dot (circle+icon) or pill (icon+caption), opaque background,
/// optional outline + pinned state/age caption.
private struct HABadge: View {
    let link: HaLink
    let visual: HAVisual
    let side: CGFloat
    let age: String?

    private var bgColor: Color {
        if let hex = link.overlayBgColor, let c = HA.colorFromHex(hex) { return c }
        return Color(hex: 0x17171B)
    }
    private var isPill: Bool { (link.overlayShape ?? "dot") == "pill" }

    var body: some View {
        VStack(spacing: 2) {
            content
            if link.overlayShowState || age != nil {
                VStack(spacing: 0) {
                    if link.overlayShowState {
                        Text(visual.stateText).font(.system(size: max(8, side * 0.3)))
                    }
                    if let age { Text(age).font(.system(size: max(7, side * 0.26))) }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isPill {
            HStack(spacing: side * 0.2) {
                Image(systemName: visual.symbol).font(.system(size: side * 0.56))
                Text(link.displayName).font(.system(size: side * 0.4, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, side * 0.4).frame(height: side)
            .background(Capsule().fill(bgColor))
            .overlay(outline(Capsule()))
            .overlay(alignment: .leading) {
                Circle().fill(visual.color).frame(width: side * 0.24, height: side * 0.24).padding(.leading, side * 0.2)
            }
        } else {
            Image(systemName: visual.symbol)
                .font(.system(size: side * 0.58))
                .foregroundColor(visual.color)
                .frame(width: side, height: side)
                .background(Circle().fill(bgColor))
                .overlay(outline(Circle()))
        }
    }

    @ViewBuilder private func outline<S: InsettableShape>(_ shape: S) -> some View {
        if link.overlayOutline {
            shape.strokeBorder(.white.opacity(0.9), lineWidth: 1.6)
                .shadow(color: .black.opacity(0.6), radius: 5, x: 0, y: 2)
        }
    }
}

// MARK: - Read-only detail card (tap a badge)

struct HAStateCard: View {
    let link: HaLink
    let state: HaEntityState?
    let stale: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let v = HA.visual(for: link, state: state, stale: stale)
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: v.symbol).font(.system(size: 40)).foregroundColor(v.color)
                Text(link.displayName).font(.headline).foregroundColor(CrumbColors.textPrimary)
                Text(v.stateText).font(.title3.weight(.semibold)).foregroundColor(v.color)
                if let age = HA.relativeAgo(state?.lastChanged) {
                    Text("Changed \(age)").font(.caption).foregroundColor(CrumbColors.textSecondary)
                }
                if let dc = link.deviceClass, !dc.isEmpty {
                    detailRow("Device class", dc)
                }
                detailRow("Entity", link.entityId)
                if stale {
                    Label("Stale — Home Assistant connection may be down",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(HA.amber).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(CrumbColors.background)
            .navigationTitle("Entity")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .barTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(CrumbColors.tealAccent)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundColor(CrumbColors.textTertiary)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundColor(CrumbColors.textSecondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Read-only entity sheet (Android-parity; a "Home" button opens it)

struct HAEntitySheet: View {
    @ObservedObject var controller: HAController
    let cameraName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if controller.stale {
                    Label("Home Assistant connection may be down — showing last-known state",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(HA.amber)
                }
                ForEach(controller.links.sorted { $0.sortOrder < $1.sortOrder }) { link in
                    NavigationLink {
                        HAStateCard(link: link, state: controller.state(for: link.entityId), stale: controller.stale)
                    } label: {
                        entityRow(link)
                    }
                }
                if controller.links.isEmpty {
                    Text("No linked entities.").font(.caption).foregroundColor(CrumbColors.textTertiary)
                }
            }
            .navigationTitle("Home Assistant")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .barTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(CrumbColors.tealAccent)
                }
            }
        }
        .task { controller.startPolling() }
    }

    private func entityRow(_ link: HaLink) -> some View {
        let v = HA.visual(for: link, state: controller.state(for: link.entityId), stale: controller.stale)
        return HStack(spacing: 12) {
            Image(systemName: v.symbol).font(.system(size: 16)).foregroundColor(v.color)
                .frame(width: 34, height: 34).background(v.color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(link.displayName).foregroundColor(CrumbColors.textPrimary)
                Text(v.stateText).font(.caption).foregroundColor(CrumbColors.textSecondary)
            }
            Spacer()
            if let age = HA.relativeAgo(controller.state(for: link.entityId)?.lastChanged) {
                Text(age).font(.caption2).foregroundColor(CrumbColors.textTertiary)
            }
        }
    }
}
