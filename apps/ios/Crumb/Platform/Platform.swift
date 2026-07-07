// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

// Cross-platform aliases so the shared UI code compiles on both iOS and macOS.
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

extension Image {
    /// Build a SwiftUI `Image` from a platform image (UIImage on iOS, NSImage on macOS).
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Decode image data on either platform (UIImage(data:) / NSImage(data:)).
    static func decode(_ data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }
}

// MARK: - Cross-platform View modifier shims
//
// SwiftUI's iOS-only modifiers don't exist on macOS; these compile to the iOS
// modifier on iOS and a no-op (or the macOS equivalent) on macOS, so the shared
// view code stays free of `#if` at every call site.

extension View {
    /// `navigationBarTitleDisplayMode(.inline)` on iOS; no-op on macOS.
    @ViewBuilder func navBarInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `statusBarHidden(_:)` on iOS; no-op on macOS (no status bar).
    @ViewBuilder func statusBarHiddenCompat(_ hidden: Bool = true) -> some View {
        #if os(iOS)
        self.statusBarHidden(hidden)
        #else
        self
        #endif
    }

    /// A full-screen cover on iOS; a sheet on macOS (no full-screen cover).
    @ViewBuilder func fullScreenCoverCompat<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }

    /// A keyboard-type hint (URL, etc.) on iOS; no-op on macOS.
    @ViewBuilder func keyboardTypeCompat(_ type: KeyboardKind) -> some View {
        #if os(iOS)
        self.keyboardType(type.uiKeyboardType)
        #else
        self
        #endif
    }

    /// Autocapitalization control on iOS; no-op on macOS.
    @ViewBuilder func autocapitalizationCompat(_ mode: AutocapKind) -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(mode.textInputAutocapitalization)
        #else
        self
        #endif
    }

    /// M6: autofill/Keychain-suggestion hint for a text field. iOS and macOS
    /// SwiftUI each expose `.textContentType(_:)` but over DIFFERENT platform
    /// types (`UITextContentType` vs `NSTextContentType`), so this maps our
    /// single cross-platform `TextContentKind` to whichever one applies.
    /// `nil` (no hint requested) is a no-op on both platforms.
    @ViewBuilder func textContentTypeCompat(_ kind: TextContentKind?) -> some View {
        #if os(iOS)
        if let kind {
            self.textContentType(kind.uiTextContentType)
        } else {
            self
        }
        #else
        if let kind, let mapped = kind.nsTextContentType {
            self.textContentType(mapped)
        } else {
            self
        }
        #endif
    }

    /// Applies the opaque navigation-bar background styling on iOS; no-op on
    /// macOS (the window toolbar is styled by the system, not per-view).
    @ViewBuilder func navBarSurfaceBackground(_ color: Color) -> some View {
        #if os(iOS)
        self.toolbarBackground(color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Forces a List into always-editing mode on iOS so `.onMove` drag handles
    /// appear without an Edit button; no-op on macOS where List reordering works
    /// natively.
    @ViewBuilder func alwaysEditing() -> some View {
        #if os(iOS)
        self.environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }

    /// On macOS, give a presented modal an explicit size. SwiftUI sizes sheets to
    /// their content's ideal size there, which collapses Forms and dialogs to a
    /// tiny, clipped box. No-op on iOS, where sheets and covers fill the screen.
    @ViewBuilder func macModalSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Leading navigation-bar slot on iOS; the cancellation-action slot on macOS.
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .navigationBarLeading
        #else
        .cancellationAction
        #endif
    }

    /// Trailing navigation-bar slot on iOS; the primary-action slot on macOS.
    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .navigationBarTrailing
        #else
        .primaryAction
        #endif
    }
}

/// Platform-neutral keyboard kinds used by the shared views.
enum KeyboardKind {
    case `default`, url
    #if os(iOS)
    var uiKeyboardType: UIKeyboardType {
        switch self {
        case .default: return .default
        case .url: return .URL
        }
    }
    #endif
}

/// Platform-neutral autocapitalization kinds used by the shared views.
enum AutocapKind {
    case never, sentences
    #if os(iOS)
    var textInputAutocapitalization: TextInputAutocapitalization {
        switch self {
        case .never: return .never
        case .sentences: return .sentences
        }
    }
    #endif
}

/// Platform-neutral autofill/Keychain-suggestion hints (M6) — maps to
/// `UITextContentType` on iOS and `NSTextContentType` on macOS via
/// `textContentTypeCompat` above.
enum TextContentKind {
    case URL, username, password

    #if os(iOS)
    var uiTextContentType: UITextContentType {
        switch self {
        case .URL: return .URL
        case .username: return .username
        case .password: return .password
        }
    }
    #else
    /// `NSTextContentType.URL` requires macOS 14+; the app's deployment
    /// target is macOS 13, so that one case has no representable value here
    /// and `textContentTypeCompat` skips applying a hint for it (`nil`).
    /// `.username`/`.password` are macOS 11+ and always available.
    var nsTextContentType: NSTextContentType? {
        switch self {
        case .URL: return nil
        case .username: return .username
        case .password: return .password
        }
    }
    #endif
}
