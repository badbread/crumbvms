// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

@MainActor
final class AuthViewModel: ObservableObject {

    @Published var serverUrl = ""
    @Published var username = ""
    @Published var password = ""
    /// Opt-in: when off (default), the server mints a normal short-lived token
    /// instead of a ~10-year "keep me signed in" credential.
    @Published var rememberMe = false
    @Published var isLoading = false
    @Published var error: String?

    // MARK: - M6: server auto-discovery (LAN /health subnet scan)

    @Published var discovering = false
    @Published var discovered: [DiscoveredServer] = []
    @Published var discoverMessage: String?
    /// User-editable "scan a specific subnet" override — prefilled with the
    /// device's own /24 the first time discovery UI is shown, same as Android.
    @Published var discoverRange = ""

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        self.serverUrl = container.store.serverUrl
        if let saved = container.store.username {
            self.username = saved
        }
        self.discoverRange = ServerDiscovery.detectLocalSubnetCidr() ?? ""
    }

    /// Scan the LAN for Crumb servers and populate `discovered`. Uses
    /// `discoverRange` when the user has overridden it, else the device's own
    /// /24 (matches Android's `discover()` semantics).
    func discover() async {
        guard !discovering else { return }
        discovering = true
        discovered = []
        discoverMessage = nil
        let range = discoverRange.trimmingCharacters(in: .whitespaces)
        let found = await ServerDiscovery.discover(range: range.isEmpty ? nil : range)
        discovered = found
        discoverMessage = found.isEmpty
            ? "No Crumb servers found. Try a different subnet, or enter the address manually."
            : nil
        discovering = false
    }

    /// Apply a discovered server's URL to the form (does not auto-submit —
    /// the user still enters credentials and taps Sign In).
    func selectDiscovered(_ url: String) {
        serverUrl = url
        discovered = []
    }

    func login() async {
        guard !serverUrl.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "Enter a server address."
            return
        }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "Enter a username."
            return
        }

        isLoading = true
        error = nil

        do {
            container.store.serverUrl = serverUrl
            container.rebuildApi()
            let resp = try await container.api.login(LoginRequest(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                remember: rememberMe
            ))
            container.store.setToken(resp.token)
            let me = try await container.api.me()
            container.applyUser(me)
            container.store.username = me.username
        } catch {
            container.store.setToken(nil)
            self.error = error.userMessage
        }

        isLoading = false
    }
}
