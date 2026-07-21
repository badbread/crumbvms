// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Plate-snapshot cropping: turn a full detection frame (JPEG bytes) plus the
// read's fractional `bbox` into a tight plate thumbnail. Pure CoreGraphics /
// ImageIO so the same code runs on iOS and macOS; no SwiftUI, no networking.

import CoreGraphics
import Foundation
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PlateCrop {

    /// Decode `data` (JPEG) and, when `bbox` is a plausible `[x, y, w, h]` in
    /// frame fractions (0…1, top-left origin), crop to that region. Falls back
    /// to the full frame when the bbox is missing, degenerate after clamping,
    /// or the crop comes out near-black (a bad box on a dark frame is worse
    /// than the whole frame). Returns nil only if the data doesn't decode.
    static func crop(_ data: Data, bbox: [Double]?) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        guard let bbox, bbox.count == 4 else { return platformImage(full) }

        let w = CGFloat(full.width)
        let h = CGFloat(full.height)
        let rect = CGRect(
            x: CGFloat(bbox[0]) * w, y: CGFloat(bbox[1]) * h,
            width: CGFloat(bbox[2]) * w, height: CGFloat(bbox[3]) * h
        )
        // Clamp to the frame; a box that clamps away to a sliver is junk.
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard clamped.width >= 4, clamped.height >= 4,
              let cropped = full.cropping(to: clamped),
              !isNearBlack(cropped)
        else { return platformImage(full) }

        return platformImage(cropped)
    }

    /// Whether the image is essentially black — downsample to an 8×8 grayscale
    /// buffer and check the mean luma against a low threshold.
    private static func isNearBlack(_ image: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return mean < 12
    }

    /// Cap on the longer side of any image we hand back for caching. Plate rows
    /// render this at ~72×40pt / ~56×40pt and the gallery card at ~110pt tall —
    /// well under 200pt (≈600px at 3x) even generously. A raw detection frame
    /// can be 2560×1440 (~14 MB decoded); `PlatesView.imageCache` keeps one
    /// entry per event id with no eviction, so caching full-res bitmaps there
    /// is an unbounded-growth OOM risk. Downsampling here — the single choke
    /// point every returned image passes through — caps each cached entry to
    /// well under 1 MB regardless of the source frame's resolution.
    private static let maxCachedPixelSize: CGFloat = 640

    /// Downsample `image` so its longer side is at most `maxPixelSize`,
    /// preserving aspect ratio. Returns `image` unchanged if it's already
    /// smaller (never upscales).
    private static func downsample(_ image: CGImage, maxPixelSize: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard max(w, h) > maxPixelSize, w > 0, h > 0 else { return image }
        let scale = maxPixelSize / max(w, h)
        let newWidth = max(1, Int((w * scale).rounded()))
        let newHeight = max(1, Int((h * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: newWidth, height: newHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return ctx.makeImage() ?? image
    }

    /// Wrap a CGImage in the platform image type (UIImage / NSImage), downsampled
    /// to `maxCachedPixelSize` first (see above) so callers that cache the result
    /// (`PlatesView.imageCache`) never retain a full-resolution detection frame.
    private static func platformImage(_ cg: CGImage) -> PlatformImage {
        let sized = downsample(cg, maxPixelSize: maxCachedPixelSize)
        #if os(macOS)
        return PlatformImage(cgImage: sized, size: NSSize(width: sized.width, height: sized.height))
        #else
        return PlatformImage(cgImage: sized)
        #endif
    }
}
