// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

final class KeychainStore: ObservableObject {

    @Published private(set) var token: String?

    var serverUrl: String {
        get { UserDefaults.standard.string(forKey: Keys.serverUrl) ?? "http://192.168.1.100:8080" }
        set { UserDefaults.standard.set(Self.normalizeUrl(newValue), forKey: Keys.serverUrl) }
    }

    var role: String? {
        get { UserDefaults.standard.string(forKey: Keys.role) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.role) }
    }

    var username: String? {
        get { UserDefaults.standard.string(forKey: Keys.username) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.username) }
    }

    var lastLiveCameraId: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastLiveCam) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastLiveCam) }
    }

    /// Effective per-user capabilities (persisted so feature gating is correct
    /// immediately on launch, before `GET /auth/me` refreshes it). Cleared on logout.
    var capabilities: Capabilities {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.capabilities),
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Capabilities.self, from: data)
            else { return Capabilities() }
            return decoded
        }
        set {
            let encoded = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
            UserDefaults.standard.set(encoded, forKey: Keys.capabilities)
        }
    }


    var isLoggedIn: Bool { token != nil && !(token?.isEmpty ?? true) }

    var isAdmin: Bool { role?.caseInsensitiveCompare("admin") == .orderedSame }

    init() {
        self.token = Self.readKeychain(key: Keys.token)
    }

    func setToken(_ value: String?) {
        if let value {
            Self.writeKeychain(key: Keys.token, value: value)
        } else {
            Self.deleteKeychain(key: Keys.token)
        }
        // [both] H3 fix: publish synchronously. `KeychainStore` is a class (not an
        // actor), so `@Published` writes have no inherent thread requirement, but
        // every caller is already @MainActor (AuthViewModel, AppContainer, etc.).
        // The previous `DispatchQueue.main.async` deferred the publish to the next
        // run-loop turn, so `AuthViewModel.login()`'s immediate follow-up call to
        // `api.me()` could read the OLD `token` via `addAuth` and fire unauthenticated
        // → 401 → spurious logout right after a successful login.
        self.token = value
    }

    func clearSession() {
        setToken(nil)
        role = nil
        username = nil
        lastLiveCameraId = nil
        UserDefaults.standard.removeObject(forKey: Keys.capabilities)
    }

    static func normalizeUrl(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "http://\(s)"
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: - Keychain helpers

    private static let service = "video.crumb.app"

    private static func readKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(key: String, value: String) {
        deleteKeychain(key: key)
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // ThisDeviceOnly: the token never leaves this device (no iCloud
            // Keychain sync, not restored to a different device from backup).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deleteKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private enum Keys {
        static let token = "token"
        static let serverUrl = "server_url"
        static let role = "role"
        static let username = "username"
        static let lastLiveCam = "last_live_cam"
        static let capabilities = "capabilities"
    }
}
