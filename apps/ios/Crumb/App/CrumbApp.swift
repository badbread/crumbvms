// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

@main
struct CrumbApp: App {

    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .environmentObject(container)
                #if os(macOS)
                // Desktop proportions — the app is a multi-pane NVR shell, not a
                // phone screen. Floor it so the login form and a usable camera wall
                // always fit (macOS hides scroll bars until actively scrolling,
                // which otherwise clips content with no visible cue).
                .frame(minWidth: 900, minHeight: 620)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        #endif
    }
}

struct RootView: View {

    @EnvironmentObject private var container: AppContainer
    /// `container.settings` is a plain `let` (not `@Published`) — observe it
    /// directly here too (same pattern `LiveWallView`/`SettingsView` use) so a
    /// toggle flip in Settings is reflected immediately rather than only on
    /// the next full `container` publish.
    @ObservedObject private var settings: AppSettings
    /// M6 parity: opt-in biometric/passcode gate (mirrors Android's face/
    /// fingerprint lock). `true` means the lock overlay renders (above the
    /// wall in the ZStack, so it never leaks camera content) until
    /// `BiometricLockView` reports success.
    @State private var isLocked = false
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    init(container: AppContainer) {
        _settings = ObservedObject(wrappedValue: container.settings)
    }

    var body: some View {
        ZStack {
            Group {
                if container.isLoggedIn {
                    LiveWallView(container: container)
                } else {
                    LoginView(container: container)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: container.isLoggedIn)

            if container.isLoggedIn && settings.biometricLockEnabled && isLocked {
                BiometricLockView(onUnlocked: { isLocked = false })
                    .transition(.opacity)
            }
        }
        #if os(macOS)
        // macOS gives every Button default push-button chrome; the app's icon
        // buttons are designed borderless (iOS-style). Make plain the default —
        // buttons that want chrome set their own .bordered/.borderedProminent.
        .buttonStyle(.plain)
        #endif
        .onAppear {
            // Cold launch: challenge immediately if the user opted in and is
            // already signed in (a fresh sign-in doesn't need an extra gate —
            // the login form itself already required credentials).
            if container.isLoggedIn && settings.biometricLockEnabled { isLocked = true }
        }
        .onChange(of: container.isLoggedIn) { loggedIn in
            if loggedIn && settings.biometricLockEnabled { isLocked = true }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { phase in
            if phase == .background, settings.biometricLockEnabled { isLocked = true }
        }
        #endif
    }
}
