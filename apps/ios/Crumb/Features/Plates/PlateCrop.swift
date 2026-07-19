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

    /// Wrap a CGImage in the platform image type (UIImage / NSImage).
    private static func platformImage(_ cg: CGImage) -> PlatformImage {
        #if os(macOS)
        return PlatformImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return PlatformImage(cgImage: cg)
        #endif
    }
}
