// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - ClipDescriptor

/// One clip in the source-abstracted `/clips` feed (detection or motion).
struct ClipDescriptor: Decodable, Identifiable {

    /// Opaque handle: `d:<event>` or `m:<cam>:<start>:<end>`.
    let id: String
    let cameraId: String
    let cameraName: String
    /// `"detection"` | `"motion"`
    let kind: String
    let label: String
    let iconKey: String
    let score: Float?
    let startTs: String
    let endTs: String
    /// Clip duration in milliseconds.
    let durationMs: Int
    let thumbnailUrl: String
    /// Lightweight preview MP4 (reduced res/fps) — the feed default.
    let clipUrl: String
    /// Full-resolution MP4.
    let downloadUrl: String
    /// `"frigate"` | `"crumb"`
    let source: String
    /// True if the current user has already opened this clip (watched-dimming).
    let viewed: Bool
    /// Normalized `[x, y, w, h]` (0..1 of the frame) for motion-highlight auto-zoom.
    let motionBbox: [Float]?

    // Derived helpers

    var isDetection: Bool { kind == "detection" }
    var isMotion: Bool { kind == "motion" }

    var durationSeconds: TimeInterval { TimeInterval(durationMs) / 1000.0 }

    var startDate: Date? { parseISO8601(startTs) }
    var endDate: Date? { parseISO8601(endTs) }

    /// Return a copy of this clip with `viewed` set to the given value.
    func withViewed(_ newViewed: Bool) -> ClipDescriptor {
        ClipDescriptor(
            id: id, cameraId: cameraId, cameraName: cameraName,
            kind: kind, label: label, iconKey: iconKey, score: score,
            startTs: startTs, endTs: endTs, durationMs: durationMs,
            thumbnailUrl: thumbnailUrl, clipUrl: clipUrl, downloadUrl: downloadUrl,
            source: source, viewed: newViewed, motionBbox: motionBbox
        )
    }

    // Explicit memberwise init so `withViewed(_:)` can create copies without
    // going through the decoder (which also suppresses the synthesized version).
    init(
        id: String, cameraId: String, cameraName: String,
        kind: String, label: String, iconKey: String, score: Float?,
        startTs: String, endTs: String, durationMs: Int,
        thumbnailUrl: String, clipUrl: String, downloadUrl: String,
        source: String, viewed: Bool, motionBbox: [Float]?
    ) {
        self.id = id; self.cameraId = cameraId; self.cameraName = cameraName
        self.kind = kind; self.label = label; self.iconKey = iconKey; self.score = score
        self.startTs = startTs; self.endTs = endTs; self.durationMs = durationMs
        self.thumbnailUrl = thumbnailUrl; self.clipUrl = clipUrl; self.downloadUrl = downloadUrl
        self.source = source; self.viewed = viewed; self.motionBbox = motionBbox
    }

    enum CodingKeys: String, CodingKey {
        case id
        case cameraId = "camera_id"
        case cameraName = "camera_name"
        case kind
        case label
        case iconKey = "icon_key"
        case score
        case startTs = "start_ts"
        case endTs = "end_ts"
        case durationMs = "duration_ms"
        case thumbnailUrl = "thumbnail_url"
        case clipUrl = "clip_url"
        case downloadUrl = "download_url"
        case source
        case viewed
        case motionBbox = "motion_bbox"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cameraId = try c.decode(String.self, forKey: .cameraId)
        cameraName = try c.decodeIfPresent(String.self, forKey: .cameraName) ?? ""
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        iconKey = try c.decodeIfPresent(String.self, forKey: .iconKey) ?? "generic"
        score = try c.decodeIfPresent(Float.self, forKey: .score)
        startTs = try c.decode(String.self, forKey: .startTs)
        endTs = try c.decode(String.self, forKey: .endTs)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl) ?? ""
        clipUrl = try c.decodeIfPresent(String.self, forKey: .clipUrl) ?? ""
        downloadUrl = try c.decodeIfPresent(String.self, forKey: .downloadUrl) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "crumb"
        viewed = try c.decodeIfPresent(Bool.self, forKey: .viewed) ?? false
        motionBbox = try c.decodeIfPresent([Float].self, forKey: .motionBbox)
    }
}

// MARK: - ClipsResponse

struct ClipsResponse: Decodable {
    let clips: [ClipDescriptor]
    let total: Int
    /// Server-configured motion-highlight duration (seconds; 0 = disabled).
    let motionHighlightSeconds: Int

    enum CodingKeys: String, CodingKey {
        case clips, total
        case motionHighlightSeconds = "motion_highlight_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decodeIfPresent([ClipDescriptor].self, forKey: .clips) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        motionHighlightSeconds = try c.decodeIfPresent(Int.self, forKey: .motionHighlightSeconds) ?? 0
    }
}

// MARK: - MarkViewedRequest

/// Body for `POST /clips/viewed`.
struct MarkViewedRequest: Encodable {
    let id: String
}
