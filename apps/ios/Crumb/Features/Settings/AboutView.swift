// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct AboutView: View {

    let container: AppContainer

    private var store: KeychainStore { container.store }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                logoHeader

                section("Build") {
                    AboutRow(label: "Version", value: appVersion)
                    rowDivider
                    AboutRow(label: "Build", value: buildNumber)
                }

                section("Connection") {
                    AboutRow(label: "Server", value: store.serverUrl)
                }

                section("Legal") {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .foregroundColor(CrumbColors.teal)
                        Text("A self-hosted video management system you run yourself.")
                            .font(.subheadline)
                            .foregroundColor(CrumbColors.textSecondary)
                        Spacer()
                    }
                }

                Link(destination: URL(string: "https://github.com/badbread/crumbvms")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square")
                        Text("View on GitHub")
                        Spacer()
                    }
                    .foregroundColor(CrumbColors.tealAccent)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(CrumbColors.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .background(CrumbColors.background)
        .navigationTitle("About")
        .navBarInline()
        .navBarSurfaceBackground(CrumbColors.surface)
        .preferredColorScheme(.dark)
    }

    // MARK: - Logo

    private var logoHeader: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 72)

            Text("Crumb")
                .font(.title2.bold())
                .foregroundColor(CrumbColors.textPrimary)

            Text("Network Video Recorder")
                .font(.subheadline)
                .foregroundColor(CrumbColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // MARK: - Section card

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(CrumbColors.textSecondary)
                .tracking(0.5)
            VStack(spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CrumbColors.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(CrumbColors.divider).frame(height: 1)
    }
}

// MARK: - Reusable row

private struct AboutRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundColor(CrumbColors.textSecondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.subheadline.monospaced())
                .foregroundColor(CrumbColors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
