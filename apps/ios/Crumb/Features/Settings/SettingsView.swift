// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct SettingsView: View {

    let container: AppContainer
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var updateChecker: UpdateChecker

    // Pulled out as a local alias for readability.
    private var store: KeychainStore { container.store }

    // Local state for the server-URL edit sheet.
    @State private var editingServerUrl = false
    @State private var draftServerUrl = ""

    @State private var navigateToAbout = false

    init(container: AppContainer) {
        self.container = container
        _settings = ObservedObject(wrappedValue: container.settings)
        _updateChecker = ObservedObject(wrappedValue: container.updateChecker)
    }

    /// Grid-layout pref as a `GridLayout` binding over the Int-backed setting.
    private var gridLayoutBinding: Binding<GridLayout> {
        Binding(
            get: { GridLayout(rawValue: settings.liveGridLayout) ?? .twoByTwo },
            set: { settings.liveGridLayout = $0.rawValue }
        )
    }

    private var ptzStyleBinding: Binding<String> {
        Binding(get: { settings.ptzStyle }, set: { settings.ptzStyle = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    accountCard
                    liveCard
                    ptzCard
                    if store.isAdmin { motionTunerCard }
                    updateCard
                    aboutButton
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .background(CrumbColors.background)
            .navigationTitle("Settings")
            .navBarInline()
            .navBarSurfaceBackground(CrumbColors.surface)
            .navigationDestination(isPresented: $navigateToAbout) {
                AboutView(container: container)
            }
            .onAppear {
                // Fresh (non-throttled) check every time Settings opens, so the
                // card is never stale — and so a client that previously saw the
                // check DISABLED discovers it was turned back on (the card's own
                // `.onAppear` can't do that: it only renders once enabled).
                // `runCheck` coalesces overlapping calls, so this is safe
                // alongside the launch check.
                Task { await updateChecker.check() }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $editingServerUrl) {
            ServerUrlSheet(
                draft: $draftServerUrl,
                onSave: {
                    store.serverUrl = draftServerUrl
                    container.rebuildApi()
                    editingServerUrl = false
                },
                onCancel: { editingServerUrl = false }
            )
        }
    }

    // MARK: - Account

    private var accountCard: some View {
        card("Account") {
            kvRow("Username", store.username ?? "—")
            rowDivider
            kvRow("Role", (store.role ?? "—").capitalized)
            if BiometricLock.isAvailable() {
                rowDivider
                settingToggle(
                    BiometricLock.biometryLabel(),
                    "Require authentication to open Crumb each time it's launched or resumed from the background.",
                    $settings.biometricLockEnabled
                )
            }
            rowDivider
            Button {
                draftServerUrl = store.serverUrl
                editingServerUrl = true
            } label: {
                HStack {
                    Text("Server URL").foregroundColor(CrumbColors.textPrimary)
                    Spacer()
                    Text(store.serverUrl)
                        .foregroundColor(CrumbColors.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundColor(CrumbColors.textTertiary)
                }
            }
            .buttonStyle(.plain)
            rowDivider
            Button(role: .destructive) {
                store.clearSession()
            } label: {
                Text("Sign Out")
                    .fontWeight(.semibold)
                    .foregroundColor(CrumbColors.error)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Live

    private var liveCard: some View {
        card("Live") {
            HStack {
                Text("Default grid layout").foregroundColor(CrumbColors.textPrimary)
                Spacer()
                Picker("", selection: gridLayoutBinding) {
                    ForEach(GridLayout.allCases, id: \.rawValue) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                .tint(CrumbColors.tealAccent)
            }
            rowDivider
            settingToggle(
                "Low-bandwidth mode",
                "Drop the live wall to still snapshots (~1 fps) instead of live video — for weak or metered connections.",
                $settings.lowBandwidthMode
            )
            rowDivider
            settingToggle(
                "Show bookmarks button",
                "Show the bookmark button in the live wall's top bar.",
                $settings.bookmarksButtonEnabled
            )
            rowDivider
            settingToggle(
                "Show \"All cameras\" view",
                "Show the built-in all-cameras quick view. Turn off to work only from your saved Views.",
                $settings.showAllCamerasView
            )
        }
    }

    // MARK: - PTZ

    private var ptzCard: some View {
        card("PTZ") {
            HStack {
                Text("Control style").foregroundColor(CrumbColors.textPrimary)
                Spacer()
                Picker("", selection: ptzStyleBinding) {
                    Text("Joystick wheel").tag("wheel")
                    Text("Edge arrows").tag("edges")
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                .tint(CrumbColors.tealAccent)
            }
            Text(settings.ptzStyle == "edges"
                 ? "Up/down/left/right pinned to the edges of the camera view."
                 : "A round 8-direction wheel at the bottom of the screen.")
                .font(.caption)
                .foregroundColor(CrumbColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Motion tuner (admin only)

    private var motionTunerCard: some View {
        card("Motion tuner") {
            settingToggle(
                "Show motion-tuner button",
                "Show the motion-detection tuner button in the fullscreen live view.",
                $settings.motionTunerEnabled
            )
        }
    }

    // MARK: - Software update (issue #7 / task C4)

    /// Always present whenever the server reports the check enabled; hidden
    /// entirely when disabled (`enabled:false`) or absent (an older server that
    /// 404s). A fresh check fires on `.onAppear` (see the card's modifier) so
    /// the shown state is never stale — a client that previously saw the
    /// feature OFF discovers it flipped ON just by opening Settings. Three
    /// states: "Checking…", the up-to-date line, or the dismissible
    /// update-available row. "Check now" is present in all three.
    @ViewBuilder
    private var updateCard: some View {
        if updateChecker.isEnabled {
            card("Software Update") {
                updateStatusRow
                rowDivider
                checkNowRow
            }
        }
    }

    @ViewBuilder
    private var updateStatusRow: some View {
        if let banner = updateChecker.bannerVersion {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update available: v\(banner)")
                        .fontWeight(.semibold)
                        .foregroundColor(CrumbColors.textPrimary)
                    if let url = updateChecker.notesURL {
                        Link("Release notes", destination: url)
                            .font(.caption)
                            .foregroundColor(CrumbColors.tealAccent)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    updateChecker.dismiss(version: banner)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(CrumbColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        } else if updateChecker.isChecking {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(CrumbColors.teal)
                Text("Checking…")
                    .foregroundColor(CrumbColors.textSecondary)
                Spacer()
            }
        } else {
            HStack {
                Text(updateChecker.upToDateText)
                    .foregroundColor(CrumbColors.textPrimary)
                Spacer()
            }
        }
    }

    private var checkNowRow: some View {
        HStack {
            if let hint = updateChecker.lastCheckedHint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)
            }
            Spacer()
            Button("Check Now") {
                Task { await updateChecker.checkNow() }
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(CrumbColors.tealAccent)
            .disabled(updateChecker.isChecking)
        }
    }

    // MARK: - About

    private var aboutButton: some View {
        Button { navigateToAbout = true } label: {
            HStack {
                Text("About Crumb").foregroundColor(CrumbColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(CrumbColors.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(CrumbColors.surface, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - building blocks

    @ViewBuilder
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(CrumbColors.textSecondary)
                .tracking(0.5)
            VStack(spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CrumbColors.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func kvRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(CrumbColors.textPrimary)
            Spacer()
            Text(value).foregroundColor(CrumbColors.textSecondary)
        }
    }

    private func settingToggle(_ title: String, _ description: String, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(CrumbColors.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(CrumbColors.teal)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(CrumbColors.divider).frame(height: 1)
    }
}

// MARK: - GridLayout display name

private extension GridLayout {
    var displayName: String {
        switch self {
        case .single: return "Single column"
        case .twoByTwo: return "2 × 2 grid"
        case .compact: return "Compact grid"
        }
    }
}

// MARK: - Server URL edit sheet

private struct ServerUrlSheet: View {

    @Binding var draft: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("SERVER URL")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(CrumbColors.textSecondary)
                    .tracking(0.5)
                TextField("http://198.51.100.100:8080", text: $draft)
                    .textFieldStyle(.plain)
                    .keyboardTypeCompat(.url)
                    .autocorrectionDisabled()
                    .autocapitalizationCompat(.never)
                    .foregroundColor(CrumbColors.textPrimary)
                    .padding(12)
                    .background(CrumbColors.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                Text("Include the port if needed. Example: http://198.51.100.100:8080")
                    .font(.caption)
                    .foregroundColor(CrumbColors.textTertiary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CrumbColors.background)
            .navigationTitle("Edit Server URL")
            .navBarInline()
            .navBarSurfaceBackground(CrumbColors.surface)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .foregroundColor(CrumbColors.tealAccent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .foregroundColor(CrumbColors.teal)
                        .fontWeight(.semibold)
                }
            }
        }
        .macModalSize(width: 460, height: 280)
        .preferredColorScheme(.dark)
    }
}
