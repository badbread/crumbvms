// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - Auth

struct LoginRequest: Encodable {
    let username: String
    let password: String
    let remember: Bool
}

struct LoginResponse: Decodable {
    let token: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

/// `GET /media-token?camera=<uuid>` response — a scoped, short-lived (~15 min)
/// token usable ONLY as `?token=` on media endpoints for `cameraId`. See
/// `MediaTokenCache` (Networking/MediaTokenCache.swift).
struct MediaTokenResponse: Decodable {
    let token: String
    let cameraId: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case token
        case cameraId = "camera_id"
        case expiresAt = "expires_at"
    }
}

/// Per-user capability set returned by `GET /auth/me` (mirrors Android's
/// `CapabilitiesDto`). Every field defaults to the most-restrictive value so a
/// client talking to an older server that omits `capabilities` degrades
/// gracefully: admins still see everything (via `UserDto.isAdmin`), viewers fall
/// back to live-only.
struct Capabilities: Codable, Equatable {
    var export: Bool
    var playback: Bool
    var clips: Bool
    var ptz: Bool
    var manageViews: Bool
    /// Bookmark access level: "none", "own", or "all".
    var bookmarks: String

    /// Admins implicitly hold every capability.
    static let admin = Capabilities(export: true, playback: true, clips: true, ptz: true, manageViews: true, bookmarks: "all")

    /// True when the user may see/create any bookmarks at all.
    var canBookmark: Bool { bookmarks != "none" }

    init(export: Bool = false, playback: Bool = false, clips: Bool = false,
         ptz: Bool = false, manageViews: Bool = false, bookmarks: String = "none") {
        self.export = export; self.playback = playback; self.clips = clips
        self.ptz = ptz; self.manageViews = manageViews; self.bookmarks = bookmarks
    }

    enum CodingKeys: String, CodingKey {
        case export, playback, clips, ptz, bookmarks
        case manageViews = "manage_views"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        export = try c.decodeIfPresent(Bool.self, forKey: .export) ?? false
        playback = try c.decodeIfPresent(Bool.self, forKey: .playback) ?? false
        clips = try c.decodeIfPresent(Bool.self, forKey: .clips) ?? false
        ptz = try c.decodeIfPresent(Bool.self, forKey: .ptz) ?? false
        manageViews = try c.decodeIfPresent(Bool.self, forKey: .manageViews) ?? false
        bookmarks = try c.decodeIfPresent(String.self, forKey: .bookmarks) ?? "none"
    }
}

struct UserDto: Decodable {
    let id: String
    let username: String
    let role: String
    let cameraIds: [String]
    /// Server-asserted admin flag (authoritative; absent on older servers).
    let isAdminFlag: Bool?
    /// Fine-grained capability set (absent on older servers → all-false).
    let capabilities: Capabilities
    /// Whether the Plates (LPR) surface should be shown: LPR is enabled
    /// server-side AND this caller holds `view_plates`. The single flag the
    /// client gates the Plates tab on — do NOT re-derive it from `capabilities`.
    /// Absent on servers without LPR → false. Can change, so it's re-fetched at
    /// every login (see `AppContainer.applyUser`).
    let platesEnabled: Bool

    /// Checks the explicit `is_admin` flag first (RBAC servers), falling back to
    /// the role string for backward-compat.
    var isAdmin: Bool { isAdminFlag ?? (role.caseInsensitiveCompare("admin") == .orderedSame) }

    /// Effective capabilities: admins implicitly hold everything; viewers are
    /// governed by the server-sent `capabilities`.
    var effectiveCapabilities: Capabilities { isAdmin ? .admin : capabilities }

    enum CodingKeys: String, CodingKey {
        case id, username, role, capabilities
        case cameraIds = "camera_ids"
        case isAdminFlag = "is_admin"
        case platesEnabled = "plates_enabled"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        role = try c.decode(String.self, forKey: .role)
        cameraIds = try c.decodeIfPresent([String].self, forKey: .cameraIds) ?? []
        isAdminFlag = try c.decodeIfPresent(Bool.self, forKey: .isAdminFlag)
        capabilities = try c.decodeIfPresent(Capabilities.self, forKey: .capabilities) ?? Capabilities()
        platesEnabled = try c.decodeIfPresent(Bool.self, forKey: .platesEnabled) ?? false
    }
}

// MARK: - Cameras

struct CameraDto: Decodable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    /// go2rtc stream name. Present in the admin `GET /config/cameras` response;
    /// the viewer-safe `GET /cameras` omits it (internal plumbing), so it defaults
    /// to empty. Viewers obtain live URLs from `GET /cameras/{id}/streams` instead.
    let go2rtcName: String
    let subUrl: String?
    let motionSource: String
    let motionAlgorithm: String
    let policy: PolicyDto?
    /// Raw JSON for the exclusion-zone mask: an array of normalized [x,y,w,h] rects.
    /// Decoded lazily in the motion tuner rather than structurally here.
    let motionMask: [[Double]]?

    // Viewer-endpoint fields (`GET /cameras`). Absent from the admin response.
    /// Whether a sub-stream is configured (viewer endpoint reports a bool, not the URL).
    private let hasSub: Bool
    /// Whether the camera supports ONVIF PTZ (viewer endpoint).
    let ptzSupported: Bool
    let cameraType: String?
    let icon: String?
    let servedBy: String?

    /// A sub (low-res) stream exists — from either the admin `sub_url` or the
    /// viewer `has_sub` flag.
    var hasSubStream: Bool { subUrl != nil || hasSub }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, policy, icon
        case go2rtcName = "go2rtc_name"
        case subUrl = "sub_url"
        case motionSource = "motion_source"
        case motionAlgorithm = "motion_algorithm"
        case motionMask = "motion_mask"
        case hasSub = "has_sub"
        case ptzSupported = "ptz"
        case cameraType = "camera_type"
        case servedBy = "served_by"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        go2rtcName = try c.decodeIfPresent(String.self, forKey: .go2rtcName) ?? ""
        subUrl = try c.decodeIfPresent(String.self, forKey: .subUrl)
        motionSource = try c.decodeIfPresent(String.self, forKey: .motionSource) ?? "pixel"
        motionAlgorithm = try c.decodeIfPresent(String.self, forKey: .motionAlgorithm) ?? "census"
        policy = try c.decodeIfPresent(PolicyDto.self, forKey: .policy)
        motionMask = try c.decodeIfPresent([[Double]].self, forKey: .motionMask)
        hasSub = try c.decodeIfPresent(Bool.self, forKey: .hasSub) ?? false
        ptzSupported = try c.decodeIfPresent(Bool.self, forKey: .ptzSupported) ?? false
        cameraType = try c.decodeIfPresent(String.self, forKey: .cameraType)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        servedBy = try c.decodeIfPresent(String.self, forKey: .servedBy)
    }
}

struct PolicyDto: Decodable {
    let motionThreshold: Float?
    let motionSensitivity: String
    let mode: String

    enum CodingKeys: String, CodingKey {
        case motionThreshold = "motion_threshold"
        case motionSensitivity = "motion_sensitivity"
        case mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        motionThreshold = try c.decodeIfPresent(Float.self, forKey: .motionThreshold)
        motionSensitivity = try c.decodeIfPresent(String.self, forKey: .motionSensitivity) ?? "dynamic"
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "continuous"
    }
}

// MARK: - PTZ

struct PtzRequest: Encodable {
    let action: String
    var pan: Float = 0
    var tilt: Float = 0
    var zoom: Float = 0
    var preset: String?
}

struct PtzPresetDto: Decodable {
    let token: String
    let name: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    enum CodingKeys: String, CodingKey { case token, name }
}

struct PtzResponse: Decodable {
    let presets: [PtzPresetDto]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presets = try c.decodeIfPresent([PtzPresetDto].self, forKey: .presets) ?? []
    }

    enum CodingKeys: String, CodingKey { case presets }
}

// MARK: - Timeline

struct RecordedSpan: Decodable {
    let cameraId: String
    let start: String
    let end: String
    let hasMotion: Bool
    let stage: String

    enum CodingKeys: String, CodingKey {
        case cameraId = "camera_id"
        case start, end
        case hasMotion = "has_motion"
        case stage
    }
}

struct TimelineResponse: Decodable {
    let spans: [RecordedSpan]
    let total: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case spans, total
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spans = try c.decodeIfPresent([RecordedSpan].self, forKey: .spans) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

struct IntensityResponse: Decodable {
    let buckets: [Float]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try c.decodeIfPresent([Float].self, forKey: .buckets) ?? []
    }

    enum CodingKeys: String, CodingKey { case buckets }
}

// MARK: - Playback

struct ResolvedSegment: Decodable {
    let cameraId: String
    let segmentId: String
    let url: String
    let start: String
    let end: String
    let durationMs: Int
    let hasMotion: Bool

    enum CodingKeys: String, CodingKey {
        case cameraId = "camera_id"
        case segmentId = "segment_id"
        case url, start, end
        case durationMs = "duration_ms"
        case hasMotion = "has_motion"
    }
}

// MARK: - Live Streams

struct LiveStreamsResponse: Decodable {
    let cameraId: String
    let webrtcMainUrl: String?
    let webrtcSubUrl: String?
    let rtspMainUrl: String
    let rtspSubUrl: String?
    /// On-demand low-res H.264 go2rtc transcode (`<name>_mobile`), present only
    /// when the server has `MOBILE_STREAM_ENABLED` and the camera resolves.
    /// NOTE: iOS live plays fMP4/WebRTC via the API's `/live/{id}/stream.mp4`
    /// proxy, which only maps `main`/`sub` — it has no path to the go2rtc
    /// `_mobile` src, and iOS has no RTSP player. So on a metered link iOS falls
    /// back to the native `sub` stream (already low, no transcode); this raw
    /// RTSP URL is not directly consumable here (see the live quality wiring).
    let rtspMobileUrl: String?

    enum CodingKeys: String, CodingKey {
        case cameraId = "camera_id"
        case webrtcMainUrl = "webrtc_main_url"
        case webrtcSubUrl = "webrtc_sub_url"
        case rtspMainUrl = "rtsp_main_url"
        case rtspSubUrl = "rtsp_sub_url"
        case rtspMobileUrl = "rtsp_mobile_url"
    }
}

// MARK: - License Plates (LPR)

/// One license-plate read (`GET /plates`). `plate` is the normalized uppercase
/// alphanumeric form; `confidence` is the plate-OCR score (0…1), NOT the vehicle
/// detection score.
struct PlateRead: Decodable, Identifiable {
    let id: String
    let cameraId: String
    /// ISO 8601 read timestamp.
    let ts: String
    let plate: String
    let plateRaw: String?
    let confidence: Double?
    let region: String?
    let sourceId: String
    /// Sibling detection event, when present — drives the "open playback" jump.
    let eventId: String?
    let snapshotUrl: String?
    /// Plate bounding box `[x, y, w, h]` as fractions (0…1) of the snapshot
    /// frame — used to derive a tight plate crop client-side.
    let bbox: [Double]?

    enum CodingKeys: String, CodingKey {
        case id, ts, plate, confidence, region, bbox
        case cameraId = "camera_id"
        case plateRaw = "plate_raw"
        case sourceId = "source_id"
        case eventId = "event_id"
        case snapshotUrl = "snapshot_url"
    }
}

/// `GET /plates` response page.
struct PlatesResponse: Decodable {
    let plates: [PlateRead]
    let total: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case plates, total
        case hasMore = "has_more"
    }
}

/// One watchlist entry (`GET /lpr/watchlist`). Keyed server-side on the
/// normalized plate, so re-adding the same plate edits rather than duplicates.
struct WatchlistEntry: Decodable, Identifiable {
    let id: String
    let plate: String
    let label: String?
    let note: String?
    let color: String?
    let notify: Bool
    /// `"watch"` (alert on sighting) or `"ignore"` (suppress). Default watch.
    let kind: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, plate, label, note, color, notify, kind
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        plate = try c.decode(String.self, forKey: .plate)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "watch"
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

/// `POST /lpr/watchlist` body. `plate` is normalized server-side; `notify`
/// defaults to true server-side when omitted.
struct WatchlistAddRequest: Encodable {
    let plate: String
    var label: String?
    var note: String?
    var color: String?
    var notify: Bool?
    /// `"watch"` | `"ignore"`; omitted ⇒ server default "watch".
    var kind: String?
}

/// `GET /config/lpr` (admin) — carries `watchlist_fuzz` for the live match
/// preview. Other clients swallow a 403 and hide the preview.
struct LprConfigDto: Decodable {
    let enabled: Bool
    let retentionDays: Int
    let watchlistFuzz: Double
    let hasIngestToken: Bool
    let version: Int

    enum CodingKeys: String, CodingKey {
        case enabled, version
        case retentionDays = "retention_days"
        case watchlistFuzz = "watchlist_fuzz"
        case hasIngestToken = "has_ingest_token"
    }
}

// MARK: - Home Assistant overlay

/// One camera↔entity link (`GET /cameras/:id/ha/links`). Carries the on-video
/// overlay placement/style; the read-only entity sheet ignores the `overlay*`
/// fields. Mirrors the server `HaLinkDto`.
struct HaLink: Decodable, Identifiable {
    let id: String
    let entityId: String
    let role: String
    let deviceClass: String?
    let label: String?
    let sortOrder: Int
    // Overlay placement/style (nil placement ⇒ no on-video badge).
    let overlayX: Double?
    let overlayY: Double?
    let overlaySize: Double?
    let overlayColor: String?
    let overlayIcon: String?
    let overlayShowState: Bool
    let overlayShowAge: Bool
    let overlayOpacity: Double?
    let overlayShape: String?
    let overlayBgColor: String?
    let overlayOutline: Bool

    /// A badge renders iff both placement coords are set.
    var hasPlacement: Bool { overlayX != nil && overlayY != nil }
    /// Display caption: operator label, else the entity id minus its domain.
    var displayName: String {
        if let label, !label.isEmpty { return label }
        if let dot = entityId.firstIndex(of: ".") { return String(entityId[entityId.index(after: dot)...]) }
        return entityId
    }
    /// HA domain (prefix before the first `.`).
    var domain: String {
        entityId.firstIndex(of: ".").map { String(entityId[..<$0]) } ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, role, label
        case entityId = "entity_id"
        case deviceClass = "device_class"
        case sortOrder = "sort_order"
        case overlayX = "overlay_x"
        case overlayY = "overlay_y"
        case overlaySize = "overlay_size"
        case overlayColor = "overlay_color"
        case overlayIcon = "overlay_icon"
        case overlayShowState = "overlay_show_state"
        case overlayShowAge = "overlay_show_age"
        case overlayOpacity = "overlay_opacity"
        case overlayShape = "overlay_shape"
        case overlayBgColor = "overlay_bg_color"
        case overlayOutline = "overlay_outline"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entityId = try c.decode(String.self, forKey: .entityId)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "sensor"
        deviceClass = try c.decodeIfPresent(String.self, forKey: .deviceClass)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        overlayX = try c.decodeIfPresent(Double.self, forKey: .overlayX)
        overlayY = try c.decodeIfPresent(Double.self, forKey: .overlayY)
        overlaySize = try c.decodeIfPresent(Double.self, forKey: .overlaySize)
        overlayColor = try c.decodeIfPresent(String.self, forKey: .overlayColor)
        overlayIcon = try c.decodeIfPresent(String.self, forKey: .overlayIcon)
        overlayShowState = try c.decodeIfPresent(Bool.self, forKey: .overlayShowState) ?? false
        overlayShowAge = try c.decodeIfPresent(Bool.self, forKey: .overlayShowAge) ?? false
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity)
        overlayShape = try c.decodeIfPresent(String.self, forKey: .overlayShape)
        overlayBgColor = try c.decodeIfPresent(String.self, forKey: .overlayBgColor)
        overlayOutline = try c.decodeIfPresent(Bool.self, forKey: .overlayOutline) ?? false
    }
}

/// One entity's live state (`GET /ha/states`).
struct HaEntityState: Decodable {
    let entityId: String
    let state: String
    let lastChanged: String?

    enum CodingKeys: String, CodingKey {
        case state
        case entityId = "entity_id"
        case lastChanged = "last_changed"
    }
}

/// `GET /ha/states` response. `stale` ⇒ HA was unreachable and this is the
/// last-known snapshot (grey the badges). Never treat a stale snapshot as
/// authoritative.
struct HaStatesResponse: Decodable {
    let fetchedAtMsAgo: Int
    let stale: Bool
    let states: [HaEntityState]

    enum CodingKeys: String, CodingKey {
        case stale, states
        case fetchedAtMsAgo = "fetched_at_ms_ago"
    }

    func state(for entityId: String) -> HaEntityState? {
        states.first { $0.entityId == entityId }
    }
}

// MARK: - Export

struct CreateExportRequest: Encodable {
    let cameraIds: [String]
    let start: String
    let end: String
    let burnTimestamp: Bool
    /// `"h264"`, `"h265"`, or `"copy"` (stream-copy, no re-encode).
    let videoCodec: String
    /// `"mp4"` or `"mkv"`.
    let container: String
    let includeAudio: Bool

    enum CodingKeys: String, CodingKey {
        case cameraIds = "camera_ids"
        case start, end
        case burnTimestamp = "burn_timestamp"
        case videoCodec = "video_codec"
        case container
        case includeAudio = "include_audio"
    }
}

/// One clip of a `POST /export/batch` list: a camera + a time range. Ranges and
/// cameras may differ per item; output settings are global to the batch.
struct BatchExportItem: Encodable {
    let cameraId: String
    let start: String
    let end: String

    enum CodingKeys: String, CodingKey {
        case cameraId = "camera_id"
        case start, end
    }
}

/// `POST /export/batch` request body — the commercial-VMS-style export list the
/// desktop client sends. The server bundles the outputs into one archive
/// (`crumb_export.zip`, AES-256 when `password` is set) whenever more than one
/// file is produced or a password is given.
struct CreateBatchExportRequest: Encodable {
    let items: [BatchExportItem]
    let burnTimestamp: Bool
    let includeAudio: Bool
    /// `"h264"`, `"h265"`, or `"copy"` (stream-copy, no re-encode).
    let videoCodec: String
    /// `"mp4"` or `"mkv"`.
    let container: String
    /// Non-empty → AES-256-encrypted ZIP archive.
    let password: String?

    enum CodingKeys: String, CodingKey {
        case items
        case burnTimestamp = "burn_timestamp"
        case includeAudio = "include_audio"
        case videoCodec = "video_codec"
        case container
        case password
    }
}

/// User-facing export format = a container + a video codec, matching the desktop
/// client's options and the backend's accepted (`video_codec`, `container`) pairs.
enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4H264, mp4H265, mkvH265, mp4Copy, mkvCopy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4H264: return "MP4 · H.264"
        case .mp4H265: return "MP4 · H.265"
        case .mkvH265: return "MKV · H.265"
        case .mp4Copy: return "MP4 · Original (copy)"
        case .mkvCopy: return "MKV · Original (copy)"
        }
    }

    /// Short hint shown under the picker.
    var detail: String {
        switch self {
        case .mp4H264: return "Re-encoded H.264 — most compatible."
        case .mp4H265: return "Re-encoded H.265 — smaller files, Apple-friendly."
        case .mkvH265: return "Re-encoded H.265 in Matroska."
        case .mp4Copy: return "No re-encode — fastest, keeps original codec."
        case .mkvCopy: return "No re-encode in Matroska — fastest."
        }
    }

    var videoCodec: String {
        switch self {
        case .mp4H264: return "h264"
        case .mp4H265, .mkvH265: return "h265"
        case .mp4Copy, .mkvCopy: return "copy"
        }
    }

    var container: String {
        switch self {
        case .mp4H264, .mp4H265, .mp4Copy: return "mp4"
        case .mkvH265, .mkvCopy: return "mkv"
        }
    }
}

struct CreateExportResponse: Decodable {
    let jobId: String
    let statusUrl: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case statusUrl = "status_url"
    }
}

struct ExportOutputFile: Decodable {
    let cameraId: String
    let downloadUrl: String
    let sizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case cameraId = "camera_id"
        case downloadUrl = "download_url"
        case sizeBytes = "size_bytes"
    }
}

struct ExportJob: Decodable, Identifiable {
    let id: String
    let status: String
    let cameraIds: [String]
    let start: String
    let end: String
    let outputFiles: [ExportOutputFile]
    let error: String?
    let progressPct: Int

    var isDone: Bool { status.caseInsensitiveCompare("done") == .orderedSame }
    var isFailed: Bool { status.caseInsensitiveCompare("failed") == .orderedSame }
    var isCancelled: Bool { status.caseInsensitiveCompare("cancelled") == .orderedSame }
    var isTerminal: Bool { isDone || isFailed || isCancelled }

    enum CodingKeys: String, CodingKey {
        case id, status, start, end, error
        case cameraIds = "camera_ids"
        case outputFiles = "output_files"
        case progressPct = "progress_pct"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        cameraIds = try c.decodeIfPresent([String].self, forKey: .cameraIds) ?? []
        start = try c.decode(String.self, forKey: .start)
        end = try c.decode(String.self, forKey: .end)
        outputFiles = try c.decodeIfPresent([ExportOutputFile].self, forKey: .outputFiles) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        progressPct = try c.decodeIfPresent(Int.self, forKey: .progressPct) ?? 0
    }
}

// MARK: - Filmstrip

struct FilmstripFrame: Decodable {
    let ts: String
    let url: String
}

struct FilmstripResponse: Decodable {
    let cameraId: String
    let frames: [FilmstripFrame]

    enum CodingKeys: String, CodingKey {
        case cameraId = "camera_id"
        case frames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraId = try c.decode(String.self, forKey: .cameraId)
        frames = try c.decodeIfPresent([FilmstripFrame].self, forKey: .frames) ?? []
    }
}

// MARK: - Bookmarks

struct BookmarkDto: Decodable, Identifiable {
    let id: String
    let cameraId: String
    let cameraName: String?
    let ts: String
    let description: String?
    let protectUntil: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, ts, description
        case cameraId = "camera_id"
        case cameraName = "camera_name"
        case protectUntil = "protect_until"
        case createdAt = "created_at"
    }
}

struct CreateBookmarkRequest: Encodable {
    let cameraId: String
    let ts: String
    let description: String?
    let protectDays: Int?
    let protectPreSeconds: Int?
    let protectPostSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case ts, description
        case cameraId = "camera_id"
        case protectDays = "protect_days"
        case protectPreSeconds = "protect_pre_seconds"
        case protectPostSeconds = "protect_post_seconds"
    }
}

// MARK: - Detection Events

struct DetectionEvent: Decodable, Identifiable {
    let id: String
    let cameraId: String
    let ts: String
    let endTs: String?
    let label: String
    let iconKey: String
    let subLabel: String?
    let score: Float
    let topScore: Float
    let zones: [String]
    let snapshotUrl: String?
    let sourceId: String

    enum CodingKeys: String, CodingKey {
        case id, label, score, zones
        case cameraId = "camera_id"
        case ts
        case endTs = "end_ts"
        case iconKey = "icon_key"
        case subLabel = "sub_label"
        case topScore = "top_score"
        case snapshotUrl = "snapshot_url"
        case sourceId = "source_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cameraId = try c.decode(String.self, forKey: .cameraId)
        ts = try c.decode(String.self, forKey: .ts)
        endTs = try c.decodeIfPresent(String.self, forKey: .endTs)
        label = try c.decode(String.self, forKey: .label)
        iconKey = try c.decode(String.self, forKey: .iconKey)
        subLabel = try c.decodeIfPresent(String.self, forKey: .subLabel)
        score = try c.decodeIfPresent(Float.self, forKey: .score) ?? 0
        topScore = try c.decodeIfPresent(Float.self, forKey: .topScore) ?? 0
        zones = try c.decodeIfPresent([String].self, forKey: .zones) ?? []
        snapshotUrl = try c.decodeIfPresent(String.self, forKey: .snapshotUrl)
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
    }
}

struct DetectionEventsResponse: Decodable {
    let events: [DetectionEvent]
    let total: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case events, total
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([DetectionEvent].self, forKey: .events) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

// MARK: - System Status

struct SystemStatusResponse: Decodable {
    let cameras: [CameraStatusEntry]
    let configVersion: String

    enum CodingKeys: String, CodingKey {
        case cameras
        case configVersion = "config_version"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameras = try c.decodeIfPresent([CameraStatusEntry].self, forKey: .cameras) ?? []
        configVersion = try c.decodeIfPresent(String.self, forKey: .configVersion) ?? ""
    }
}

struct CameraStatusEntry: Decodable, Identifiable {
    let id: String
    let recording: Bool
    let recentMotion: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case recording
        case recentMotion = "recent_motion"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        recording = try c.decodeIfPresent(Bool.self, forKey: .recording) ?? false
        recentMotion = try c.decodeIfPresent(Bool.self, forKey: .recentMotion) ?? false
    }
}

// MARK: - Motion Tuner

/// Live motion heatmap response from `GET /cameras/{id}/motion-grid`.
struct MotionGridDto: Decodable {
    /// Number of columns in the heatmap grid.
    let cols: Int
    /// Number of rows in the heatmap grid.
    let rows: Int
    /// Per-cell intensity values, row-major order. Values are floats in [0, 100].
    let cells: [Float]
    /// Recorder's current largest-blob score as a fraction of frame area (0..1).
    let score: Float
    /// Effective motion threshold as a fraction of frame area (0..1).
    /// In dynamic mode this is the auto floor; in manual mode it is the configured value.
    let threshold: Float

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        cells = try c.decodeIfPresent([Float].self, forKey: .cells) ?? []
        score = try c.decodeIfPresent(Float.self, forKey: .score) ?? 0
        threshold = try c.decodeIfPresent(Float.self, forKey: .threshold) ?? 0
    }

    enum CodingKeys: String, CodingKey { case cols, rows, cells, score, threshold }
}

/// `PUT /config/cameras/{id}/policy` body — motion sensitivity and threshold only.
struct UpdatePolicyRequest: Encodable {
    let motionSensitivity: String
    /// Fraction of frame area (0..1).
    let motionThreshold: Float

    enum CodingKeys: String, CodingKey {
        case motionSensitivity = "motion_sensitivity"
        case motionThreshold = "motion_threshold"
    }
}

/// `PUT /config/cameras/{id}` body — replace the motion exclusion mask only.
struct UpdateCameraMaskRequest: Encodable {
    /// Array of normalized [x, y, w, h] rects covering excluded zones.
    let motionMask: [[Double]]

    enum CodingKeys: String, CodingKey {
        case motionMask = "motion_mask"
    }
}

/// `PUT /config/cameras/{id}` body — set motion source and pixel-detector algorithm.
struct UpdateCameraMotionRequest: Encodable {
    let motionSource: String
    let motionAlgorithm: String

    enum CodingKeys: String, CodingKey {
        case motionSource = "motion_source"
        case motionAlgorithm = "motion_algorithm"
    }
}

// MARK: - Saved Views (server-backed, per-user; shared with desktop/android/web)

/// A saved view as returned by `GET /views`. The server model is richer than the
/// client's `CameraView` (it carries a grid `layout` and a `slots` map whose
/// values may be a bare camera-id string OR a full view-item spec object created
/// on desktop). This client only consumes the ordered camera ids — see
/// `toCameraView()`. Mirrors Android's `ViewDto` (`CrumbApi.kt`) field-for-field.
struct ViewDto: Decodable {
    let id: String
    let name: String
    let layout: String
    /// `{"<slotIndex>": <cameraId-string-or-view-item-object>}` — decoded as a
    /// loosely-typed JSON value since desktop's richer view-item specs (carousel/
    /// ptz/hotspot) aren't modelled here; only bare-string / `{"cameraId": ...}`
    /// slots are extracted.
    let slots: [String: JSONValue]
    let ownerId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, layout, slots
        case ownerId = "owner_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "auto"
        slots = try c.decodeIfPresent([String: JSONValue].self, forKey: .slots) ?? [:]
        ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId)
    }

    /// Server view → client `CameraView`: ordered camera ids from the `slots`
    /// map (numeric slot-key order), skipping non-camera view-items. Mirrors
    /// Android's `ViewDto.toCameraView()`.
    func toCameraView() -> CameraView {
        let ordered = slots.compactMap { (key, value) -> (Int, String)? in
            guard let idx = Int(key), let camId = value.slotCameraId else { return nil }
            return (idx, camId)
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return CameraView(id: id, name: name, cameraIds: ordered)
    }
}

/// `POST /views` body. Cameras are encoded as bare-string slots
/// `{"0": id, "1": id, ...}` so the `{slotIndex: cameraId}` contract shared
/// with web/desktop/android stays clean.
struct CreateViewRequest: Encodable {
    let name: String
    let layout: String
    let slots: [String: String]
}

extension CameraView {
    /// Client `CameraView` → create request (cameras become ordered bare-string
    /// slots). Mirrors Android's `CameraView.toCreateRequest()`.
    func toCreateRequest() -> CreateViewRequest {
        var slots: [String: String] = [:]
        for (i, camId) in cameraIds.enumerated() { slots["\(i)"] = camId }
        return CreateViewRequest(name: name, layout: "auto", slots: slots)
    }
}

/// Minimal loosely-typed JSON value — just enough to pull a camera id out of a
/// `views.slots` entry, which may be a bare string (this client's own writes,
/// and Android's) or a richer object (desktop's view-item specs).
enum JSONValue: Decodable {
    case string(String)
    case object([String: JSONValue])
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .other
        }
    }

    /// A bare string slot IS the camera id; an object slot's `cameraId` field
    /// (desktop's richer view-item spec) provides it; anything else is nil.
    var slotCameraId: String? {
        switch self {
        case .string(let s): return s
        case .object(let o):
            if case .string(let s)? = o["cameraId"] { return s }
            return nil
        case .other: return nil
        }
    }
}
