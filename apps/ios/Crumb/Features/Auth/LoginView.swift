// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct LoginView: View {

    @StateObject private var vm: AuthViewModel

    init(container: AppContainer) {
        _vm = StateObject(wrappedValue: AuthViewModel(container: container))
    }

    var body: some View {
        ZStack {
            CrumbColors.background.ignoresSafeArea()

            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 24)

                        Image("Logo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 80)

                        Text("Crumb")
                            .font(.largeTitle.bold())
                            .foregroundColor(.white)

                        Text("Sign in to your server")
                            .font(.subheadline)
                            .foregroundColor(CrumbColors.textSecondary)

                        VStack(spacing: 16) {
                            CrumbTextField(
                                icon: "server.rack",
                                placeholder: "Server address",
                                text: $vm.serverUrl,
                                keyboardType: .url,
                                autocapitalization: .never,
                                contentType: .URL
                            )

                            // M6: LAN auto-discovery — probes /health across the
                            // device's subnet for a Crumb server, so a first-time
                            // user (or one who forgot the NVR's LAN IP) doesn't
                            // have to hunt for it. Never auto-submits credentials.
                            discoverySection

                            CrumbTextField(
                                icon: "person.fill",
                                placeholder: "Username",
                                text: $vm.username,
                                autocapitalization: .never,
                                contentType: .username
                            )

                            CrumbTextField(
                                icon: "lock.fill",
                                placeholder: "Password",
                                text: $vm.password,
                                isSecure: true,
                                contentType: .password
                            )

                            Toggle(isOn: $vm.rememberMe) {
                                Text("Keep me signed in")
                                    .font(.subheadline)
                                    .foregroundColor(CrumbColors.textSecondary)
                            }
                            .tint(CrumbColors.teal)
                            .padding(.horizontal, 4)
                        }

                        if let error = vm.error {
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(CrumbColors.error)
                                .multilineTextAlignment(.center)
                        }

                        Button {
                            Task { await vm.login() }
                        } label: {
                            Group {
                                if vm.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("Sign In")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(CrumbColors.teal)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(vm.isLoading)

                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                    // Fill at least the viewport so the form centers vertically;
                    // when the window is shorter than the form it scrolls instead.
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - M6: server discovery UI

    @ViewBuilder private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await vm.discover() }
                } label: {
                    HStack(spacing: 6) {
                        if vm.discovering {
                            ProgressView().tint(CrumbColors.tealAccent).scaleEffect(0.8)
                        } else {
                            Image(systemName: "wifi.router")
                        }
                        Text(vm.discovering ? "Scanning your network…" : "Find my server")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(CrumbColors.tealAccent)
                }
                .disabled(vm.discovering || vm.isLoading)
                Spacer()
            }

            if let message = vm.discoverMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(CrumbColors.textTertiary)
            }

            if !vm.discovered.isEmpty {
                VStack(spacing: 0) {
                    ForEach(vm.discovered) { server in
                        Button {
                            vm.selectDiscovered(server.url)
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundColor(CrumbColors.tealAccent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(server.ip)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(.white)
                                    if let version = server.version {
                                        Text("Crumb \(version)")
                                            .font(.caption2)
                                            .foregroundColor(CrumbColors.textTertiary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(CrumbColors.textTertiary)
                            }
                            .padding(10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if server.id != vm.discovered.last?.id {
                            Rectangle().fill(CrumbColors.divider).frame(height: 1)
                        }
                    }
                }
                .background(CrumbColors.surfaceVariant)
                .cornerRadius(10)
            }
        }
    }
}

private struct CrumbTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: KeyboardKind = .default
    var isSecure: Bool = false
    var autocapitalization: AutocapKind = .sentences
    /// Autofill hint (M6) — lets iOS/macOS offer Keychain-saved credentials
    /// and QuickType suggestions for the server URL/username/password fields.
    var contentType: TextContentKind? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(CrumbColors.textTertiary)
                .frame(width: 20)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .autocapitalizationCompat(autocapitalization)
                    .textContentTypeCompat(contentType)
            } else {
                TextField(placeholder, text: $text)
                    .keyboardTypeCompat(keyboardType)
                    .autocapitalizationCompat(autocapitalization)
                    .autocorrectionDisabled()
                    .textContentTypeCompat(contentType)
            }
        }
        .padding(14)
        .background(CrumbColors.surfaceVariant)
        .cornerRadius(10)
        .foregroundColor(.white)
    }
}
