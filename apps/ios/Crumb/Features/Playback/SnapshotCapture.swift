// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
#if os(iOS)
import Photos
#else
import AppKit
import UniformTypeIdentifiers
#endif

/// Saves a snapshot image — the camera-snapshot feature used by the live
/// fullscreen and playback views. On iOS it writes to the Photo Library
/// (requesting `.addOnly` authorization automatically). On macOS it presents a
/// save panel so the user picks a destination for the PNG. Throws if the user
/// denies access or the save fails.
@MainActor
func saveToPhotos(_ image: PlatformImage) async throws {
    #if os(iOS)
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
        throw SnapshotError.photoLibraryDenied
    }
    try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAsset(from: image)
    }
    #else
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw SnapshotError.encodeFailed
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "Crumb Snapshot.png"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try data.write(to: url)
    #endif
}

enum SnapshotError: LocalizedError {
    case photoLibraryDenied
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .photoLibraryDenied:
            return "Photos access is required to save snapshots. Enable it in Settings."
        case .encodeFailed:
            return "Couldn't encode the snapshot image."
        }
    }
}
