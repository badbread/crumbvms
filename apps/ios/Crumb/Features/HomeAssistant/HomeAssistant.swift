// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Home Assistant on-video overlays + entity sheet, at parity with the desktop
/// badge overlay and the Android per-camera entity sheet.
///
/// Linking/placement/config stays admin-only (web console / desktop editor); the
/// client only reads `GET /cameras/:id/ha/links` and `GET /ha/states`. Phase 2
/// (issue #187) adds ONE write: `POST /cameras/:id/ha/action` on the detail
/// card, gated on the `actuators` capability AND an `actuator`-role link, so a
/// viewer without the grant sees exactly the read-only surface it saw before.
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

// MARK: - Actions (Phase 2 controls, issue #187)

/// One button on the detail card: the wire `action` the server accepts, its
/// caption, an SF Symbol from the same vocabulary the badges use, and whether
/// it needs a confirmation first.
struct HAAction: Identifiable, Equatable {
    let action: String
    let title: String
    let symbol: String
    /// Physical-security domains (locks, covers) confirm before firing.
    let confirms: Bool
    /// Renders the confirm button in the destructive role (unlock / open).
    let destructive: Bool

    var id: String { action }

    init(_ action: String, _ title: String, _ symbol: String, confirms: Bool = false, destructive: Bool = false) {
        self.action = action
        self.title = title
        self.symbol = symbol
        self.confirms = confirms
        self.destructive = destructive
    }
}

extension HA {
    /// Allowed actions BY DOMAIN, mirroring the server's allow-list. An unknown
    /// domain yields no buttons (the card stays read-only) rather than guessing
    /// at a service call the server would reject.
    static func actions(for domain: String) -> [HAAction] {
        switch domain {
        case "light", "switch", "fan", "siren":
            return [
                HAAction("turn_on", "On", "power"),
                HAAction("turn_off", "Off", "power"),
            ]
        case "cover":
            return [
                HAAction("open_cover", "Open", "arrow.up.square", confirms: true, destructive: true),
                HAAction("stop_cover", "Stop", "stop.fill", confirms: true),
                HAAction("close_cover", "Close", "arrow.down.square", confirms: true),
            ]
        case "lock":
            return [
                HAAction("lock", "Lock", "lock.fill", confirms: true),
                HAAction("unlock", "Unlock", "lock.open.fill", confirms: true, destructive: true),
            ]
        case "button", "input_button":
            return [HAAction("press", "Press", "hand.tap.fill")]
        case "scene":
            return [HAAction("turn_on", "Activate", "film")]
        case "script":
            return [HAAction("turn_on", "Run", "play.fill")]
        default:
            return []
        }
    }

    /// Domains whose control is genuinely multi-action or needs a safety confirm,
    /// so a single tap cannot express it: the tap opens `HAStateCard` instead of
    /// firing. Today only `cover` (open/stop/close) and `lock` (lock/unlock, which
    /// keeps its confirm). A future value-setting control (a dimmer / position
    /// slider) would also live on the card and belongs here; the backend action
    /// allow-list is on/off/toggle only for now, so there is no brightness UI yet.
    static func needsCard(_ domain: String) -> Bool {
        domain == "cover" || domain == "lock"
    }

    /// The single service call a one-tap fires for a directly-controllable
    /// (simple) actuator domain, mirroring the server allow-list: `toggle` for
    /// on/off devices, `press` for buttons, `turn_on` (activate/run) for
    /// scenes/scripts. Returns nil for card domains (cover/lock) and unknown
    /// domains, which never direct-fire.
    static func primaryAction(for domain: String) -> String? {
        switch domain {
        case "light", "switch", "fan", "siren": return "toggle"
        case "button", "input_button": return "press"
        case "scene", "script": return "turn_on"
        default: return nil
        }
    }

    /// Human phrasing for an action failure, shared by the direct-tap surfaces
    /// (badge, entity-sheet row) and the detail card. 403 → permission denial,
    /// 502 → "Crumb is up, HA isn't", 400/404 → rejected; else the app's shared
    /// error text.
    static func actionMessage(for error: Error) -> String {
        if let api = error as? APIError {
            if api.isForbidden { return "You are not permitted to control this device." }
            if api.isBadGateway { return "Home Assistant did not respond. The device was not changed." }
            if case .http(let code, _) = api, code == 400 || code == 404 {
                return "Home Assistant rejected that action."
            }
        }
        return error.userMessage
    }
}

/// Client-side failure before an action ever reaches the server.
enum HAActionError: LocalizedError {
    case noCamera

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No camera selected."
        }
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

    /// Whether this user may actuate linked devices (issue #187). Deny-by-default:
    /// an older server omits the capability, `Capabilities` defaults it to false,
    /// and the detail card renders byte-identically to the read-only Phase 1 UI.
    /// Admins implicitly hold it (`Capabilities.admin`), same as every other cap.
    var canActuate: Bool { container.isAdmin || container.capabilities.actuators }

    func state(for entityId: String) -> HaEntityState? { states?.state(for: entityId) }

    /// The action a single tap should fire directly for `link`, or nil when a tap
    /// should instead open the detail card. Direct-fire requires the actuate grant
    /// AND an actuator-role link AND a simple (non-card) domain with a defined
    /// primary action. Read-only links, cover/lock, and unknown domains return nil
    /// (tap opens `HAStateCard`, exactly as the read-only Phase 1 UI did).
    func directTapAction(for link: HaLink) -> String? {
        guard canActuate, link.isActuator, !HA.needsCard(link.domain) else { return nil }
        return HA.primaryAction(for: link.domain)
    }

    /// Fire one HA service call for a link. Throws on any non-2xx so the caller
    /// can surface `403` as "not permitted" and `502` as "HA unreachable".
    /// Deliberately does NOT mutate the shown state: the `/ha/states` poll is the
    /// only source of truth (state-honesty invariant above), so a call that HA
    /// silently drops can never leave the badge lying about the device.
    func perform(link: HaLink, action: String) async throws {
        // Unreachable in practice (links only exist after `activate`), but a
        // missing camera must read as a failure, never as a silent success.
        guard let cameraId else { throw HAActionError.noCamera }
        try await container.api.haAction(cameraId: cameraId, linkId: link.id, action: action)
        // Nudge the poll so the real new state lands sooner than the next tick.
        await pollOnce()
    }

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

    /// Presents the detail card (read-only links + cover/lock on tap; any link on
    /// long-press).
    @State private var tapped: HaLink?
    /// Link ids with a direct-tap action in flight (brief on-badge spinner).
    @State private var firing: Set<String> = []
    /// Direct-tap failure, surfaced as an alert since no card is open.
    @State private var actionError: String?

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
            HAStateCard(link: link, controller: controller)
                .macModalSize(width: 360, height: 340)
        }
        .alert("Control failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
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
            age: link.overlayShowAge ? HA.relativeAgo(controller.state(for: link.entityId)?.lastChanged) : nil,
            busy: firing.contains(link.id)
        )
        .opacity(link.overlayOpacity ?? 1)
        // Clamp the top-left origin so the badge box stays fully inside the video
        // frame (desktop clamps to max - boxSize, not just max).
        .offset(x: min(max(x, field.minX), max(field.minX, field.maxX - side)),
                y: min(max(y, field.minY), max(field.minY, field.maxY - side)))
        // A single tap fires the primary action for a directly-controllable simple
        // actuator (light/switch/fan/siren toggle, button press, scene/script run);
        // for read-only links and cover/lock it opens the detail card instead. A
        // long-press always opens the card, so a controllable simple actuator can
        // still be inspected without actuating it.
        .onTapGesture {
            if let action = controller.directTapAction(for: link) {
                fire(link, action)
            } else {
                tapped = link
            }
        }
        .onLongPressGesture { tapped = link }
    }

    /// Fire one direct-tap action, showing a brief on-badge spinner and surfacing
    /// any failure via the alert. The shown state is never flipped locally; the
    /// controller's poll converges it (state-honesty invariant).
    private func fire(_ link: HaLink, _ action: String) {
        guard !firing.contains(link.id) else { return }
        firing.insert(link.id)
        Task { @MainActor in
            do {
                try await controller.perform(link: link, action: action)
            } catch {
                actionError = HA.actionMessage(for: error)
            }
            firing.remove(link.id)
        }
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
    /// A direct-tap action is in flight — dim the icon and overlay a spinner.
    var busy: Bool = false

    private var bgColor: Color {
        if let hex = link.overlayBgColor, let c = HA.colorFromHex(hex) { return c }
        return Color(hex: 0x17171B)
    }
    private var isPill: Bool { (link.overlayShape ?? "dot") == "pill" }

    var body: some View {
        VStack(spacing: 2) {
            content
                .opacity(busy ? 0.55 : 1)
                .overlay {
                    if busy {
                        ProgressView().controlSize(.small).tint(.white)
                            .padding(4)
                            .background(Circle().fill(.black.opacity(0.6)))
                    }
                }
            if link.overlayShowState || age != nil {
                VStack(spacing: 0) {
                    if link.overlayShowState {
                        Text(visual.stateText).font(.system(size: min(max(8, side * 0.3), 13)))
                    }
                    if let age { Text(age).font(.system(size: min(max(7, side * 0.26), 11))) }
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
                Image(systemName: visual.symbol).font(.system(size: min(side * 0.56, 40)))
                Text(link.displayName).font(.system(size: min(side * 0.4, 26), weight: .semibold)).lineLimit(1)
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
                .font(.system(size: min(side * 0.58, 40)))
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

// MARK: - Detail card (tap a badge) — read-only, plus Phase 2 controls

struct HAStateCard: View {
    let link: HaLink
    /// Observed (not snapshotted) so the 3s poll keeps the shown state current
    /// while the card is open — the card never flips state locally after an
    /// action, it waits for the poll to say so.
    @ObservedObject var controller: HAController
    @Environment(\.dismiss) private var dismiss

    /// The action currently in flight (its wire name), or nil.
    @State private var inFlight: String?
    /// Awaiting confirmation (lock/cover only).
    @State private var pending: HAAction?
    @State private var errorText: String?

    private var state: HaEntityState? { controller.state(for: link.entityId) }
    private var stale: Bool { controller.stale }

    /// Controls render only for an `actuator`-role link when the user holds the
    /// `actuators` capability. Both false ⇒ the exact Phase 1 card.
    private var actions: [HAAction] {
        guard controller.canActuate, link.isActuator else { return [] }
        return HA.actions(for: link.domain)
    }

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
                if !actions.isEmpty {
                    controlsRow
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundColor(CrumbColors.error)
                        .multilineTextAlignment(.center)
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
        .confirmationDialog(
            pending.map { "\($0.title) \(link.displayName)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pending {
                Button(action.title, role: action.destructive ? ButtonRole.destructive : nil) {
                    pending = nil
                    Task { await fire(action) }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }

    /// The per-domain button set. Buttons stay disabled while any action is in
    /// flight so a double tap can't queue two service calls at a lock.
    private var controlsRow: some View {
        HStack(spacing: 10) {
            ForEach(actions) { action in
                Button {
                    if action.confirms {
                        pending = action
                    } else {
                        Task { await fire(action) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if inFlight == action.action {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: action.symbol).font(.system(size: 13))
                        }
                        Text(action.title).font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(CrumbColors.surfaceVariant, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundColor(CrumbColors.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(inFlight != nil)
                .opacity(inFlight != nil && inFlight != action.action ? 0.5 : 1)
            }
        }
        .padding(.top, 2)
    }

    /// One service call, with the button disabled for its duration. The shown
    /// state is left alone either way; the 3s poll converges it.
    private func fire(_ action: HAAction) async {
        errorText = nil
        inFlight = action.action
        do {
            try await controller.perform(link: link, action: action.action)
        } catch {
            errorText = HA.actionMessage(for: error)
        }
        inFlight = nil
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

// MARK: - Per-camera entity sheet (Android-parity; a "Home" button opens it)

struct HAEntitySheet: View {
    @ObservedObject var controller: HAController
    let cameraName: String
    @Environment(\.dismiss) private var dismiss

    /// Detail card opened from a long-press (or a tap on a read-only / cover / lock
    /// row); mirrors the on-video badge affordance.
    @State private var detail: HaLink?
    /// Link ids with a direct-tap action in flight (brief inline spinner).
    @State private var firing: Set<String> = []
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            List {
                if controller.stale {
                    Label("Home Assistant connection may be down — showing last-known state",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(HA.amber)
                }
                ForEach(controller.links.sorted { $0.sortOrder < $1.sortOrder }) { link in
                    row(link)
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
        .sheet(item: $detail) { link in
            HAStateCard(link: link, controller: controller)
                .macModalSize(width: 360, height: 340)
        }
        .alert("Control failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task { controller.startPolling() }
    }

    /// A directly-controllable simple actuator fires its primary action on tap and
    /// opens the detail card on long-press; everything else (read-only links,
    /// cover/lock) pushes the detail card on tap, exactly as before.
    @ViewBuilder
    private func row(_ link: HaLink) -> some View {
        if let action = controller.directTapAction(for: link) {
            Button {
                fire(link, action)
            } label: {
                entityRow(link, busy: firing.contains(link.id))
            }
            .buttonStyle(.plain)
            .onLongPressGesture { detail = link }
        } else {
            NavigationLink {
                HAStateCard(link: link, controller: controller)
            } label: {
                entityRow(link)
            }
        }
    }

    /// Fire one direct-tap action, showing a brief inline spinner and surfacing any
    /// failure via the alert. State is never flipped locally; the poll converges it.
    private func fire(_ link: HaLink, _ action: String) {
        guard !firing.contains(link.id) else { return }
        firing.insert(link.id)
        Task { @MainActor in
            do {
                try await controller.perform(link: link, action: action)
            } catch {
                actionError = HA.actionMessage(for: error)
            }
            firing.remove(link.id)
        }
    }

    private func entityRow(_ link: HaLink, busy: Bool = false) -> some View {
        let v = HA.visual(for: link, state: controller.state(for: link.entityId), stale: controller.stale)
        return HStack(spacing: 12) {
            ZStack {
                Image(systemName: v.symbol).font(.system(size: 16)).foregroundColor(v.color)
                    .opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.small) }
            }
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
