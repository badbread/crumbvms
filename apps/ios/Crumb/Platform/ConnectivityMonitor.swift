// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network

/// App-wide "is the current link metered?" signal, driving the `.auto` quality
/// mode (metered ⇒ low-bitrate variants). Mirrors Android's
/// `ConnectivityManager.isActiveNetworkMetered` check
/// (`feature/live/NetworkConnectivity.kt`), using the iOS-native equivalent:
/// `NWPathMonitor` with `path.isExpensive` (cellular / personal hotspot /
/// carrier-metered Wi-Fi) OR `path.isConstrained` (Low Data Mode).
///
/// Fail-open: `isMetered` starts `false` and stays `false` if the path can't be
/// evaluated, so an unknown link is treated as unmetered (Full), never forced to
/// low — matching Android's "assume unmetered when connectivity is unreadable".
///
/// One monitor for the whole app, owned by `AppContainer`; live and playback
/// both observe it, so a link that flips metered while a screen is open
/// re-drives quality without a manual refresh.
@MainActor
final class ConnectivityMonitor: ObservableObject {

    @Published private(set) var isMetered = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "video.crumb.connectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Personal hotspot / cellular / carrier-metered Wi-Fi report
            // `isExpensive`; Low Data Mode reports `isConstrained`. Either means
            // "spend bytes carefully" → prefer the low-bitrate variants.
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in self?.isMetered = metered }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
