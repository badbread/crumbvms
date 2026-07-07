// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import LocalAuthentication
import SwiftUI

/// Opt-in biometric/passcode app-lock gate (M6 parity — mirrors Android's
/// face/fingerprint gate on cold start, see `crumb-android-biometric` in
/// project memory). Uses `LocalAuthentication`'s `deviceOwnerAuthentication`
/// policy, which falls back to the device passcode (iOS) / password (macOS)
/// when biometrics aren't enrolled or fail repeatedly — same policy Apple
/// recommends for "protect app content" gates.
enum BiometricLock {

    /// Whether this device can present *some* local-auth challenge at all
    /// (biometrics enrolled, or at minimum a passcode/password set). Settings
    /// hides/disables the toggle when this is false so a user can't lock
    /// themselves out of the app with no way back in.
    static func isAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// A human-readable label for the primary biometric type available, for
    /// the Settings toggle ("Require Face ID" / "Require Touch ID" / generic
    /// fallback wording when only a passcode is available).
    static func biometryLabel() -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Require device passcode"
        }
        switch context.biometryType {
        case .faceID: return "Require Face ID"
        case .touchID: return "Require Touch ID"
        case .opticID: return "Require Optic ID"
        default: return "Require device passcode"
        }
    }

    /// Evaluate the device-owner-authentication policy (biometrics, falling
    /// back to passcode/password). Returns `true` on success, `false` on any
    /// failure or user cancellation — callers keep the lock screen up on
    /// `false` rather than treating it as "no lock configured".
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "" // let the system supply platform-appropriate wording
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Full-screen lock overlay shown over the app's content while the user
/// hasn't yet passed the biometric/passcode challenge for this launch (or
/// this foreground-resume, if `AppSettings.biometricLockEnabled` is on).
/// Presents automatically on `.onAppear` and retries on tap (e.g. after a
/// user cancel or a failed attempt).
struct BiometricLockView: View {
    let onUnlocked: () -> Void

    @State private var authenticating = false
    @State private var failed = false

    var body: some View {
        ZStack {
            CrumbColors.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 52))
                    .foregroundColor(CrumbColors.tealAccent)
                Text("Crumb is locked")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                if failed {
                    Text("Authentication failed — tap to try again.")
                        .font(.subheadline)
                        .foregroundColor(CrumbColors.error)
                        .multilineTextAlignment(.center)
                }
                Button {
                    attempt()
                } label: {
                    Label(authenticating ? "Authenticating…" : "Unlock", systemImage: "faceid")
                        .frame(maxWidth: 220)
                        .padding(.vertical, 12)
                        .background(CrumbColors.teal, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                }
                .disabled(authenticating)
            }
            .padding(32)
        }
        .onAppear { attempt() }
    }

    private func attempt() {
        guard !authenticating else { return }
        authenticating = true
        failed = false
        Task {
            let ok = await BiometricLock.authenticate(reason: "Unlock Crumb to view your cameras")
            authenticating = false
            if ok {
                onUnlocked()
            } else {
                failed = true
            }
        }
    }
}
