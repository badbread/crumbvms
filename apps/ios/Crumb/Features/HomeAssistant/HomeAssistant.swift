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
    /// The tri-state `edgeOn` reading resolved to a determinate "on" (mirrors
    /// exactly what dims `overlayColor` to 45% in `applyOverrides` below).
    /// `false` for an off reading AND for anything indeterminate/stale/scene —
    /// badge background resolution (`HA.badgeBackground`) only consults
    /// `overlay_bg_color_on` when this is `true`.
    let isOn: Bool
}

enum HA {
    // Palette (from desktop ha_icons.dart).
    static let grey = Color(hex: 0x8E8E93)
    static let amber = Color(hex: 0xFFB143)
    static let neutral = Color(hex: 0xB9C2CC)
    static let blue = Color(hex: 0x33C3FF)
    static let green = Color(hex: 0x2BA84A)
    static let warmYellow = Color(hex: 0xFFCC33)
    static let danger = Color(hex: 0xE5484D) // smoke/gas alarm active — attention red

    /// On/off/indeterminate edge, mirroring backend `edge_on`. Returns nil for
    /// anything not explicitly on or off (incl. unavailable/unknown/"").
    static func edgeOn(_ state: String) -> Bool? {
        switch state.trimmingCharacters(in: .whitespaces).lowercased() {
        case "on", "open", "detected", "true", "home", "motion", "occupied": return true
        case "off", "closed", "clear", "false", "not_home", "no_motion": return false
        default: return nil
        }
    }

    /// device_class → coarse badge class. Mirrors desktop `labelForDeviceClass`
    /// exactly, including the display-only extensions (lock/smoke/gas/leak) that
    /// give problem sensors their own glyph + alert color instead of a generic
    /// dot (issue #438, restoring the richness #437 flattened). A SUPERSET of the
    /// backend's `label_for_device_class`; the shared first five cases stay
    /// aligned with it. This ONE mapping backs both the badge and the entity
    /// sheet.
    static func classForDeviceClass(_ dc: String?) -> String {
        switch (dc ?? "").lowercased() {
        case "motion", "moving", "vibration": return "motion"
        case "occupancy", "presence": return "occupancy"
        case "door", "opening": return "door"
        case "window": return "window"
        case "garage_door": return "garage"
        // display-only extensions (badge/sheet richness, issue #438)
        case "lock": return "lock"
        case "smoke": return "smoke"
        case "gas", "carbon_monoxide": return "gas"
        case "moisture": return "leak"
        default: return "sensor"
        }
    }

    /// Human "Type" label for the detail card: the humanized `device_class` when
    /// present, else the humanized entity domain — NEVER blank. Mirrors the
    /// Android `haTypeLabel(domain, deviceClass)` and the desktop card exactly, so
    /// a light with no device_class reads "Light", a cover with `garage_door`
    /// reads "Garage door", `carbon_monoxide` reads "Carbon monoxide".
    static func typeLabel(domain: String, deviceClass: String?) -> String {
        let raw = (deviceClass?.isEmpty == false) ? deviceClass! : domain
        return humanizeToken(raw)
    }

    /// underscores → spaces, and capitalize ONLY the first letter (interior words
    /// untouched): `garage_door` → "Garage door". Not `.capitalized`, which would
    /// title-case every word ("Garage Door").
    private static func humanizeToken(_ token: String) -> String {
        let spaced = token.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
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
            return applyOverrides(link, base: HAVisual(symbol: "film", color: neutral, stateText: "Scene", indeterminate: false, isOn: false), on: nil)
        }

        // Indeterminate (unknown/unavailable/stale) → grey, honest state text.
        // ANY domain whose live state is not an on/off edge lands here — an
        // `unavailable`/`unknown`/empty light or switch is NEVER a confident
        // "Off" (state-honesty invariant; matches Android `defaultVisual` and
        // desktop `haVisualFor`, where `edgeOn(state) == null` greys the badge
        // for every domain). A numeric sensor ("72", "48") lands here too (its
        // state is not an on/off edge), so this is where its
        // unit_of_measurement is appended.
        if stale || state == nil || on == nil {
            let sym = baseSymbol(domain: domain, deviceClass: link.deviceClass, on: false)
            let text = raw.isEmpty ? "Unknown" : stateTextWithUnit(raw, unit: state?.unit)
            return HAVisual(symbol: overrideSymbol(link) ?? sym, color: grey, stateText: text, indeterminate: true, isOn: false)
        }

        // Known reading — `on` is guaranteed non-nil here (nil already routed to
        // the indeterminate branch above).
        let isOn = on ?? false
        let base: HAVisual
        switch domain {
        case "light":
            base = HAVisual(symbol: isOn ? "lightbulb.fill" : "lightbulb",
                            color: isOn ? warmYellow : grey, stateText: isOn ? "On" : "Off", indeterminate: false, isOn: isOn)
        case "switch":
            base = HAVisual(symbol: "power",
                            color: isOn ? green : grey, stateText: isOn ? "On" : "Off", indeterminate: false, isOn: isOn)
        default:
            base = classVisual(HA.classForDeviceClass(link.deviceClass), on: isOn)
        }
        return applyOverrides(link, base: base, on: isOn)
    }

    /// Append the entity's `unit_of_measurement` to a real numeric/plain reading
    /// (issue #449): "72" + "°F" -> "72 °F", "48" + "%" -> "48 %". Never appended
    /// to an on/off/open/closed edge label (those never reach this path) nor to
    /// an indeterminate placeholder. Falls back to today's capitalized text when
    /// there is no unit, so a payload from an older server renders unchanged.
    private static func stateTextWithUnit(_ raw: String, unit: String?) -> String {
        let base = raw.capitalized
        guard let u = unit?.trimmingCharacters(in: .whitespaces), !u.isEmpty else { return base }
        if edgeOn(raw) != nil { return base }
        switch raw.lowercased() {
        case "unavailable", "unknown", "none": return base
        default: return "\(raw) \(u)"
        }
    }

    private static func classVisual(_ cls: String, on: Bool) -> HAVisual {
        switch cls {
        case "door":
            return HAVisual(symbol: on ? "door.left.hand.open" : "door.left.hand.closed",
                            color: on ? amber : neutral, stateText: on ? "Open" : "Closed", indeterminate: false, isOn: on)
        case "window":
            return HAVisual(symbol: on ? "window.vertical.open" : "window.vertical.closed",
                            color: on ? amber : neutral, stateText: on ? "Open" : "Closed", indeterminate: false, isOn: on)
        case "garage":
            return HAVisual(symbol: on ? "door.garage.open" : "door.garage.closed",
                            color: on ? amber : neutral, stateText: on ? "Open" : "Closed", indeterminate: false, isOn: on)
        case "motion":
            return HAVisual(symbol: "figure.run", color: on ? blue : grey,
                            stateText: on ? "Motion" : "Clear", indeterminate: false, isOn: on)
        case "occupancy":
            return HAVisual(symbol: "person.fill", color: on ? blue : grey,
                            stateText: on ? "Occupied" : "Clear", indeterminate: false, isOn: on)
        case "lock":
            // A binary_sensor lock reads on = unsecured/unlocked, off = locked.
            return HAVisual(symbol: on ? "lock.open.fill" : "lock.fill",
                            color: on ? amber : neutral, stateText: on ? "Unlocked" : "Locked", indeterminate: false, isOn: on)
        case "smoke":
            return HAVisual(symbol: "smoke.fill", color: on ? danger : neutral,
                            stateText: on ? "Smoke" : "Clear", indeterminate: false, isOn: on)
        case "gas":
            return HAVisual(symbol: "carbon.monoxide.cloud.fill", color: on ? danger : neutral,
                            stateText: on ? "Gas" : "Clear", indeterminate: false, isOn: on)
        case "leak":
            return HAVisual(symbol: "drop.triangle.fill", color: on ? amber : neutral,
                            stateText: on ? "Leak" : "Dry", indeterminate: false, isOn: on)
        default:
            return HAVisual(symbol: "sensor.fill", color: on ? blue : grey,
                            stateText: on ? "Active" : "Clear", indeterminate: false, isOn: on)
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
        return HAVisual(symbol: symbol, color: color, stateText: base.stateText, indeterminate: base.indeterminate, isOn: base.isOn)
    }

    private static func overrideSymbol(_ link: HaLink) -> String? {
        guard let slug = link.overlayIcon, !slug.isEmpty else { return nil }
        return iconSlugToSymbol[slug]
    }

    /// Curated overlay-icon slug → SF Symbol, covering the ENTIRE canonical closed
    /// vocabulary defined once server-side (`CANONICAL_ICON_SLUGS` in
    /// `services/api/src/ha.rs`, issue #438). Every slug there maps to a REAL SF
    /// Symbol available on iOS 16 / macOS 13, so an operator's pick renders the
    /// same on iOS as on desktop/Android instead of degrading to the generic
    /// `sensor.fill` (the `?? classDefault` fallback in `overrideSymbol`).
    ///
    /// iOS has no dedicated window-covering symbol on our iOS 16 floor, so
    /// cover/blinds/curtains/shade all resolve to `window.vertical.closed`; that
    /// is an honest, compilable choice, not a missing glyph. Likewise the iOS 16
    /// floor has no grill/BBQ or kitchen-appliance symbols, so outdoor cooking
    /// leans on flame/smoke (`grill`→`flame.fill`, `smoker`→`smoke.fill`).
    static let iconSlugToSymbol: [String: String] = [
        // contact & openings
        "door": "door.left.hand.closed", "window": "window.vertical.closed",
        "gate": "door.left.hand.closed", "garage": "door.garage.closed",
        "cover": "window.vertical.closed", "blinds": "window.vertical.closed",
        "curtains": "window.vertical.closed", "shade": "window.vertical.closed",
        "lock": "lock.fill", "key": "key.fill",
        // motion & presence
        "motion": "figure.run", "occupancy": "person.fill", "person": "person.fill",
        "home": "house.fill", "pet": "pawprint.fill", "vibration": "waveform",
        // lighting
        "lightbulb": "lightbulb.fill", "floodlight": "flashlight.on.fill",
        "outdoor_light": "lightbulb.fill", "landscape_light": "light.beacon.max.fill",
        // power & switches
        "switch": "switch.2", "power": "power", "plug": "powerplug.fill",
        "outlet": "poweroutlet.type.b.fill", "energy": "bolt.fill", "meter": "gauge",
        "battery": "battery.100", "solar": "sun.max.fill", "ev": "bolt.car.fill",
        // climate & environment
        "fan": "fanblades.fill", "ac": "snowflake", "heatpump": "thermometer.snowflake",
        "hvac": "wind", "thermostat": "thermometer", "temperature": "thermometer",
        "humidity": "humidity.fill", "sun": "sun.max.fill",
        // weather
        "cloud": "cloud.fill", "rain": "cloud.rain.fill", "wind": "wind",
        "storm": "cloud.bolt.rain.fill", "moon": "moon.fill",
        // safety & alarm
        "smoke": "smoke.fill", "gas": "carbon.monoxide.cloud.fill",
        "co": "carbon.dioxide.cloud.fill", "fire": "flame.fill",
        "leak": "drop.triangle.fill", "water": "drop.fill", "valve": "drop.circle.fill",
        "siren": "megaphone.fill", "security": "shield.fill", "armed": "checkmark.shield.fill",
        "warning": "exclamationmark.triangle.fill", "doorbell": "bell.badge.fill",
        "bell": "bell.fill",
        // camera & media
        "camera": "video.fill", "tv": "tv", "speaker": "hifispeaker.fill",
        "media_player": "play.tv.fill", "remote": "av.remote.fill",
        "game": "gamecontroller.fill", "mic": "mic.fill", "music": "music.note",
        // network & computing
        "wifi": "wifi", "router": "network",
        "printer": "printer.fill", "server": "server.rack", "computer": "desktopcomputer",
        "storage": "externaldrive.fill", "phone": "iphone",
        // vehicles & delivery
        "vehicle": "car.fill", "package": "shippingbox.fill", "mail": "envelope.fill",
        // appliances & outdoor
        "vacuum": "sparkles", "lawn": "leaf.fill", "fridge": "snowflake",
        "laundry": "tshirt.fill", "pool": "figure.pool.swim", "hottub": "water.waves",
        "grill": "flame.fill", "smoker": "smoke.fill", "coffee": "cup.and.saucer.fill",
        "plant": "leaf.circle.fill",
        // time
        "clock": "clock.fill", "calendar": "calendar", "timer": "timer",
        // automation
        "scene": "film", "script": "curlybraces", "button": "hand.tap.fill",
        // generic fallback
        "sensor": "sensor.fill",
    ]

    static func colorFromHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt(s, radix: 16) else { return nil }
        return Color(hex: v)
    }

    /// On-video badge background. When `visual.isOn` (a determinate "on"
    /// reading — never a scene, never off, never indeterminate/stale)
    /// `overlay_bg_color_on` wins if set; every other case, including a
    /// missing/unparseable `overlay_bg_color_on`, falls back to
    /// `overlay_bg_color`, then the shared default badge background. Off and
    /// indeterminate/stale readings NEVER consult `overlay_bg_color_on`.
    static let defaultBadgeBackground = Color(hex: 0x17171B)

    static func badgeBackground(link: HaLink, visual: HAVisual) -> Color {
        if visual.isOn, let hexOn = link.overlayBgColorOn, let c = colorFromHex(hexOn) { return c }
        if let hex = link.overlayBgColor, let c = colorFromHex(hex) { return c }
        return defaultBadgeBackground
    }

    /// A FIXED pill width as a multiple of the pill's HEIGHT (migration 0078,
    /// issue #497), or nil for `auto` — and for any value this build does not
    /// know, which degrades to today's hug-the-content width rather than
    /// guessing at a newer server's vocabulary.
    ///
    /// Height is the unit because it is the one length desktop, Android and iOS
    /// already derive identically from `overlay_size` and the pane scale, so
    /// `medium` is the same pill everywhere. The vocabulary is frozen and
    /// shared with `services/api/src/ha.rs`'s `HA_PILL_WIDTH_MODES`, the
    /// desktop `haPillWidthFactor`, the Android `HaBadgeMetrics.pillWidthFactor`
    /// and the console's width select.
    static func pillWidthFactor(_ mode: String?) -> CGFloat? {
        switch mode {
        case "narrow": return 4
        case "medium": return 6
        case "wide": return 8
        default: return nil // "auto", nil, or anything unrecognized
        }
    }

    /// Where the pill's icon + label group sits once a fixed width has left it
    /// some slack (migration 0078). nil/`"start"` is the leading edge, today's
    /// layout, and is what anything unrecognized falls back to.
    static func pillAlignment(_ align: String?) -> Alignment {
        switch align {
        case "center": return .center
        case "end": return .trailing
        default: return .leading
        }
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

    /// The FULL action set for a domain, a SUPERSET of `actions(for:)` used only
    /// when a link restricts its actions (`allowed_actions` non-null, migration
    /// 0075). The simple on/off domains gain the `toggle` button the default card
    /// omits, so an operator can restrict a light to exactly `toggle` and still
    /// have it render. Every other domain equals its default set. Intersected
    /// with the link's `allowedActions` at the call site.
    static func allActions(for domain: String) -> [HAAction] {
        switch domain {
        case "light", "switch", "fan", "siren":
            return [
                HAAction("turn_on", "On", "power"),
                HAAction("turn_off", "Off", "power"),
                HAAction("toggle", "Toggle", "power"),
            ]
        default:
            return actions(for: domain)
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

    /// Whether a VALUE commit (the `HAValueSlider`) for `link` must be confirmed
    /// before it fires: the link's own `require_confirm` (migration 0075), or a
    /// physical-security domain regardless of that flag, so a cover's position
    /// slider confirms exactly like its Open/Close buttons. Mirrors the Android
    /// `haNeedsConfirm`, `lock` included: a lock exposes no value control today,
    /// but if one ever appears it must confirm rather than silently actuate.
    static func valueNeedsConfirm(_ link: HaLink) -> Bool {
        link.requireConfirm || link.domain == "cover" || link.domain == "lock"
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
        // A per-link confirm requirement, or an allowed_actions restriction that
        // excludes the primary action, routes the tap to the card instead of
        // firing directly (migration 0075, issue #440).
        guard !link.requireConfirm else { return nil }
        guard let primary = HA.primaryAction(for: link.domain), link.actionAllowed(primary) else {
            return nil
        }
        return primary
    }

    /// Fire one HA service call for a link. Throws on any non-2xx so the caller
    /// can surface `403` as "not permitted" and `502` as "HA unreachable".
    /// Deliberately does NOT mutate the shown state: the `/ha/states` poll is the
    /// only source of truth (state-honesty invariant above), so a call that HA
    /// silently drops can never leave the badge lying about the device.
    ///
    /// `value` carries the single numeric a value action needs (issue #442
    /// Slice 1); nil for every discrete action, unchanged from before.
    func perform(link: HaLink, action: String, value: Double? = nil) async throws {
        // Unreachable in practice (links only exist after `activate`), but a
        // missing camera must read as a failure, never as a silent success.
        guard let cameraId else { throw HAActionError.noCamera }
        try await container.api.haAction(cameraId: cameraId, linkId: link.id, action: action, value: value)
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
    /// The global "show HA overlays" quick-toggle. Observed *here*, inside the
    /// overlay itself, rather than at each call site, so every live surface that
    /// composites badges — the single-camera/fullscreen view today, anything
    /// added later — is governed by the one flag and can't drift out of sync.
    @ObservedObject var settings: AppSettings
    let videoSize: CGSize?

    /// Presents the detail card (read-only links + cover/lock on tap; any link on
    /// long-press).
    @State private var tapped: HaLink?
    /// Link ids with a direct-tap action in flight (brief on-badge spinner).
    @State private var firing: Set<String> = []
    /// Direct-tap failure, surfaced as an alert since no card is open.
    @State private var actionError: String?

    var body: some View {
        // Hidden = render nothing at all: no badges, and with them no tap /
        // long-press targets, so the video underneath is completely clear.
        // Display-only — the controller keeps polling, so flipping the toggle
        // back shows live states immediately with no reload.
        if settings.showHaOverlays {
            overlayBody
        }
    }

    private var overlayBody: some View {
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
                .macModalSize(width: 360, height: 368)
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

    private var bgColor: Color { HA.badgeBackground(link: link, visual: visual) }
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
            // A fixed width mode (migration 0078) pins the pill to an exact
            // multiple of its height and lets `alignment` place the icon+label
            // group in the slack; `auto` (nil) keeps today's hug-the-content
            // pill, where the frame is intrinsic and alignment is a no-op.
            let fixedWidth = HA.pillWidthFactor(link.overlayPillWidth).map { $0 * side }
            HStack(spacing: side * 0.2) {
                Image(systemName: visual.symbol).font(.system(size: min(side * 0.56, 40)))
                Text(link.displayName).font(.system(size: min(side * 0.4, 26), weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, side * 0.4)
            // The state pip rides the CONTENT box, not the (possibly widened)
            // pill, so a centred/trailing label keeps its pip beside it instead
            // of stranding it against the leading edge. Identical geometry on an
            // auto-width pill, where the two boxes are the same box.
            .overlay(alignment: .leading) {
                Circle().fill(visual.color).frame(width: side * 0.24, height: side * 0.24).padding(.leading, side * 0.2)
            }
            .frame(width: fixedWidth, height: side, alignment: HA.pillAlignment(link.overlayTextAlign))
            .background(Capsule().fill(bgColor))
            .overlay(outline(Capsule()))
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
        // allowed_actions nil ⇒ today's default set. Non-null ⇒ present ONLY the
        // permitted actions, intersected with the domain's full set (migration
        // 0075, issue #440).
        guard let allowed = link.allowedActions else { return HA.actions(for: link.domain) }
        return HA.allActions(for: link.domain).filter { allowed.contains($0.action) }
    }

    /// The value-setting slider's descriptor, or nil when none applies. Value
    /// words (`set_brightness`/`set_position`/`set_speed`) are not buttons —
    /// this slider is their entire UI (issue #442 Slice 1). Same actuate gate
    /// as `actions`, plus the live `control` descriptor the state poll carries,
    /// plus (when the link restricts actions) the descriptor's action word must
    /// be one of the allowed ones — the same `allowed_actions` intersection the
    /// button set already applies.
    private var valueControl: HaControlDescriptor? {
        guard controller.canActuate, link.isActuator else { return nil }
        guard let control = state?.control else { return nil }
        guard link.actionAllowed(control.action) else { return nil }
        return control
    }

    var body: some View {
        let v = HA.visual(for: link, state: state, stale: stale)
        NavigationStack {
            VStack(spacing: 14) {
                // Badge chip: the SAME state color as this entity's on-video badge
                // (`HA.visual`), tinted into a circle exactly like the badge overlay,
                // the entity-sheet row, and the Android/desktop detail cards — never
                // a greyscale or washed-out header. A lit light reads clearly
                // warm-yellow here, an active motion sensor blue, a smoke alarm red.
                Image(systemName: v.symbol)
                    .font(.system(size: 34))
                    .foregroundColor(v.color)
                    .frame(width: 68, height: 68)
                    .background(v.color.opacity(0.16), in: Circle())
                Text(link.displayName).font(.headline).foregroundColor(CrumbColors.textPrimary)
                Text(v.stateText).font(.title3.weight(.semibold)).foregroundColor(v.color)
                if let age = HA.relativeAgo(state?.lastChanged) {
                    Text("Changed \(age)").font(.caption).foregroundColor(CrumbColors.textSecondary)
                }
                if let control = valueControl {
                    // The slider owns its own confirm prompt and its own
                    // committed-hold state machine (Android parity): a
                    // confirm-gated release must not pin the thumb before the
                    // POST is actually authorized, and a rejected POST must
                    // release the pin at once.
                    HAValueSlider(
                        control: control,
                        entityName: link.displayName,
                        needsConfirm: HA.valueNeedsConfirm(link),
                        disabled: inFlight != nil
                    ) { target in
                        await fireValue(control, target)
                    }
                }
                if !actions.isEmpty {
                    controlsRow
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundColor(CrumbColors.error)
                        .multilineTextAlignment(.center)
                }
                // Single "Type" row: humanized device_class when present, else the
                // humanized domain (never blank), matching the Android
                // `haTypeLabel` and the desktop card.
                detailRow("Type", HA.typeLabel(domain: link.domain, deviceClass: link.deviceClass))
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
                    // Confirm when the action itself is physical-security
                    // (cover/lock) OR the link requires a confirm on every action
                    // (migration 0075, issue #440).
                    if action.confirms || link.requireConfirm {
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

    /// One value-setting service call (issue #442 Slice 1), with the slider
    /// disabled for its duration. Same pattern as `fire`: the shown value is
    /// left alone either way, the 3s poll converges it.
    ///
    /// Returns whether the server accepted the call. A `false` tells the slider
    /// to drop its committed hold immediately and re-seed from the live polled
    /// value, so a rejected (403/400) or dropped POST can never leave the thumb
    /// parked at a position the device was never set to.
    private func fireValue(_ control: HaControlDescriptor, _ value: Double) async -> Bool {
        errorText = nil
        inFlight = control.action
        var accepted = true
        do {
            try await controller.perform(link: link, action: control.action, value: value)
        } catch {
            errorText = HA.actionMessage(for: error)
            accepted = false
        }
        inFlight = nil
        return accepted
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

/// A value-setting slider for `HAStateCard` (issue #442 Slice 1). Kind-agnostic
/// — driven entirely by the descriptor's `min`/`max`/`step`/`unit`, never a
/// hardcoded 0...100, so Slice 2's temperature control reuses this unchanged.
///
/// Interaction mirrors the desktop/Android sliders: commits on release, exactly
/// ONE `onCommit` call per gesture, via `onEditingChanged` going false. The
/// shown value never flips optimistically on commit — it only advances when the
/// descriptor's own `value` changes (i.e. when the next `/ha/states` poll
/// lands), and only while the user isn't mid-drag.
///
/// Post-commit HOLD (issue #465): on an UNGATED commit the thumb is pinned to
/// the committed target and the poll re-seed is suppressed until the polled
/// value converges to within a step of it (see `holdConverged`) OR the hold is
/// cleared. Without the hold the very first poll after a commit — which for a
/// beat still reports the device's OLD value while it transitions — snaps the
/// thumb back the instant you release, then jumps it to the target a poll later:
/// the bounce. The slider is CONTINUOUS (no `step:`, which snaps the thumb to
/// tick positions mid-drag and itself reads as a bounce); the released value is
/// snapped to `step` in `snapToStep`, so the POSTed value stays grid-aligned —
/// Android/desktop parity.
///
/// STATE HONESTY (issue #505). The hold pins the thumb at a value the operator
/// asked for, so it may only ever exist while that value is genuinely on its way
/// to the device — otherwise a cover slider reads 80% while the cover sits at
/// 20%, which for a physical-security device is a lie, not a cosmetic glitch.
/// Two rules follow, both mirroring the Android `HaValueSlider`:
///
///  * A confirm-gated release (`needsConfirm`: `require_confirm`, or a
///    cover/lock) sets `awaitingConfirm`, NOT the hold. Nothing has been sent
///    yet. Only accepting the confirm sets the hold and fires; cancelling
///    reverts the thumb to the live polled value.
///  * A commit the server rejected or that never landed clears the hold
///    immediately rather than pinning the thumb for the whole timeout window.
///
/// Every hold-clear path (converge, timeout, error, confirm-cancel) funnels
/// through the SAME `syncThumb` decision, which is re-run by `onChange` on each
/// of the inputs it reads — `control.value`, `committed` AND `awaitingConfirm` —
/// so clearing a hold always re-seeds from the live value even when the polled
/// value itself has not changed since the commit (keying only on `control.value`
/// is what left the thumb stranded after a hold cleared).
struct HAValueSlider: View {
    let control: HaControlDescriptor
    /// Entity name, interpolated into the confirm prompt.
    var entityName: String = ""
    /// Whether a commit must be confirmed before it fires — `HA.valueNeedsConfirm`
    /// at the call site, the same gate the discrete action buttons use.
    var needsConfirm: Bool = false
    var disabled: Bool = false
    /// Fired once per gesture, on release, with the step-snapped target value —
    /// and only AFTER the confirm was accepted when one was required. Returns
    /// whether the server accepted the call; `false` drops the hold at once.
    let onCommit: (Double) async -> Bool

    @State private var value: Double
    @State private var dragging = false
    /// A value we just committed and pin the thumb at until the `/ha/states`
    /// poll reflects it (issue #465). `nil` means "follow the polled value" —
    /// the normal idle state. Never an optimistic report of a NEW value as
    /// accepted; it only holds a value that has actually been POSTed.
    @State private var committed: Double?
    /// A target awaiting the operator's confirm; non-nil only while its prompt
    /// is up. NOTHING has been sent for it, so it deliberately does not pin the
    /// thumb the way `committed` does — it merely suspends poll tracking so the
    /// prompt and the thumb agree on the value being asked about (#505).
    @State private var awaitingConfirm: Double?

    /// Safety net so a dropped request or a device that never reaches the target
    /// can't freeze the thumb: the hold is released after this window even if the
    /// poll never converges. Matches the Android slider's 6s timeout.
    private static let holdTimeout: Duration = .seconds(6)

    private var lowerBound: Double { control.min ?? 0 }
    private var upperBound: Double { max(control.max ?? 100, lowerBound) }
    private var stepSize: Double { max(control.step ?? 1, 0.01) }

    init(
        control: HaControlDescriptor,
        entityName: String = "",
        needsConfirm: Bool = false,
        disabled: Bool = false,
        onCommit: @escaping (Double) async -> Bool
    ) {
        self.control = control
        self.entityName = entityName
        self.needsConfirm = needsConfirm
        self.disabled = disabled
        self.onCommit = onCommit
        _value = State(initialValue: control.value ?? control.min ?? 0)
    }

    var body: some View {
        VStack(spacing: 4) {
            // CONTINUOUS slider (no `step:`): the thumb tracks the finger; the
            // released value is snapped to the descriptor's grid in `release`.
            Slider(
                value: $value,
                in: lowerBound...upperBound,
                onEditingChanged: { editing in
                    dragging = editing
                    if !editing { release() }
                }
            )
            .disabled(disabled)
            Text(Self.label(for: value, control: control))
                .font(.caption).foregroundColor(CrumbColors.textSecondary)
        }
        .padding(.top, 2)
        // ONE decision (`syncThumb`), re-run whenever any input it reads
        // changes. Keying on `committed`/`awaitingConfirm` too is what makes a
        // cleared hold resume tracking immediately instead of waiting for the
        // next value CHANGE from the poll.
        .onChange(of: control.value) { _ in syncThumb() }
        .onChange(of: committed) { _ in syncThumb() }
        .onChange(of: awaitingConfirm) { _ in syncThumb() }
        // Never hold forever. Re-armed each time `committed` changes; the sleep
        // is cancelled (and this early-returns) the moment the hold clears.
        .task(id: committed) {
            guard committed != nil else { return }
            try? await Task.sleep(for: Self.holdTimeout)
            guard !Task.isCancelled else { return }
            committed = nil
        }
        .confirmationDialog(
            awaitingConfirm.map { "Set \(entityName) to \(Self.label(for: $0, control: control))?" } ?? "",
            isPresented: Binding(get: { awaitingConfirm != nil }, set: { if !$0 { cancelConfirm() } }),
            titleVisibility: .visible
        ) {
            // `target` is captured by value, so this fires the value that was
            // shown in the prompt no matter which way round SwiftUI orders the
            // button action and the dismissal.
            if let target = awaitingConfirm {
                Button("Set") { commit(target) }
            }
            Button("Cancel", role: .cancel) { cancelConfirm() }
        }
    }

    /// Releasing the slider: snap to the grid, then either fire (pinning the
    /// thumb) or ask first (pinning nothing).
    private func release() {
        switch Self.releaseDecision(raw: value, needsConfirm: needsConfirm,
                                    min: lowerBound, max: upperBound, step: stepSize) {
        case .confirm(let target):
            // Show the exact value the prompt is asking about, but set NO hold:
            // if the operator cancels, `cancelConfirm` reverts to the live value.
            value = target
            awaitingConfirm = target
        case .commit(let target):
            commit(target)
        }
    }

    /// Pin the thumb at `target` and fire the one POST for this gesture. Called
    /// straight from `release` for an ungated control, or from the confirm's
    /// accept button — never before the call is authorized.
    private func commit(_ target: Double) {
        value = target
        committed = target
        awaitingConfirm = nil
        Task { @MainActor in
            let accepted = await onCommit(target)
            // A rejected or dropped POST must not keep asserting the target for
            // the rest of the timeout window. Guarded on the hold still being
            // OURS so a newer gesture's hold is never clobbered by an older
            // failure landing late.
            if !accepted, committed == target { committed = nil }
        }
    }

    /// Dismiss the confirm without firing: drop the pending target and let
    /// `syncThumb` put the thumb back on the live polled value. Idempotent, so
    /// the accept path (which clears `awaitingConfirm` itself) can't trip it.
    private func cancelConfirm() {
        guard awaitingConfirm != nil else { return }
        awaitingConfirm = nil
    }

    /// Apply the `thumbSync` decision. `.follow` is also the point where a hold
    /// that has served its purpose is dropped.
    private func syncThumb() {
        switch Self.thumbSync(polled: control.value, fallback: lowerBound,
                              dragging: dragging, awaitingConfirm: awaitingConfirm != nil,
                              committed: committed, step: stepSize) {
        case .ignore, .hold:
            return
        case .follow(let live):
            if committed != nil { committed = nil }
            value = live
        }
    }

    /// Snap a raw slider value onto the descriptor's grid: clamp to `min...max`,
    /// then round to the nearest whole `step` measured from `min`. Kind-agnostic
    /// (never a hardcoded 0...100). Applied ONCE on release so the drag stays
    /// smooth (the slider is continuous) while the committed/POSTed value is
    /// step-aligned. Pure, so it's unit-tested.
    static func snapToStep(_ raw: Double, min: Double, max: Double, step: Double) -> Double {
        let s = step > 0 ? step : 1
        let clamped = Swift.min(Swift.max(raw, min), max)
        let snapped = min + (((clamped - min) / s).rounded()) * s
        return Swift.min(Swift.max(snapped, min), max)
    }

    /// Whether the just-committed value has been reflected by the poll: true once
    /// the `polled` value is within a step (plus a small margin, to absorb
    /// percent↔brightness rounding) of `committed`. While false the slider keeps
    /// holding the committed value rather than snapping to the device's
    /// transitioning old value (#465). Pure, so it's unit-tested. Mirrors the
    /// Android `haHoldConverged`.
    static func holdConverged(polled: Double, committed: Double, step: Double) -> Bool {
        abs(polled - committed) <= step + 0.5
    }

    /// What releasing the slider does with the raw drag position.
    enum ReleaseDecision: Equatable {
        /// Fire now, and pin the thumb at this target until the poll converges.
        case commit(Double)
        /// Ask first. Deliberately carries no hold: the POST has not happened,
        /// so the thumb must be free to snap back to reality on a cancel (#505).
        case confirm(Double)
    }

    /// Whether a release fires straight away or has to be confirmed, and the
    /// step-snapped target either way. Pure, so it's unit-tested. The whole
    /// point of the two cases is that ONLY `.commit` is allowed to set the hold.
    static func releaseDecision(raw: Double, needsConfirm: Bool,
                                min: Double, max: Double, step: Double) -> ReleaseDecision {
        let target = snapToStep(raw, min: min, max: max, step: step)
        return needsConfirm ? .confirm(target) : .commit(target)
    }

    /// Where the thumb belongs whenever anything the slider tracks changes.
    enum ThumbSync: Equatable {
        /// Leave the thumb alone: the operator owns it right now (mid-drag, or
        /// a confirm prompt is up asking about the value it shows).
        case ignore
        /// Keep holding a committed value the device is still transitioning to.
        case hold
        /// Track the live value — and release any hold, which has either
        /// converged or been cleared.
        case follow(Double)
    }

    /// The single re-seed decision, shared by every path that can move the thumb
    /// (a poll tick, a converged hold, a timed-out hold, a failed commit, a
    /// cancelled confirm). Pure, so it's unit-tested. Mirrors the Android
    /// slider's `LaunchedEffect(control.value, committed)`, including its
    /// `dragging || awaitingConfirm` bail-out.
    ///
    /// - Parameter polled: the descriptor's live value; `nil` when HA has never
    ///   reported one, in which case the thumb falls back to `fallback` (the
    ///   descriptor's `min`, exactly what the slider seeds itself with) rather
    ///   than sitting on a number nothing ever confirmed.
    static func thumbSync(polled: Double?, fallback: Double, dragging: Bool,
                          awaitingConfirm: Bool, committed: Double?, step: Double) -> ThumbSync {
        if dragging || awaitingConfirm { return .ignore }
        let live = polled ?? fallback
        if let target = committed, !holdConverged(polled: live, committed: target, step: step) {
            return .hold
        }
        return .follow(live)
    }

    /// "62%" for the percent kind (every Slice 1 word); "72 °F" for a future
    /// kind that carries a `unit`.
    static func label(for value: Double, control: HaControlDescriptor) -> String {
        let rounded = Int(value.rounded())
        if control.kind == "percent" { return "\(rounded)%" }
        if let unit = control.unit, !unit.isEmpty { return "\(rounded) \(unit)" }
        return "\(rounded)"
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
                .macModalSize(width: 360, height: 368)
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
