// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Sparkle

/// Owns Sparkle's standard updater for the lifetime of the app.
///
/// Local/ad-hoc builds intentionally leave SUPublicEDKey unset. In that case
/// Sparkle stays dormant instead of showing a configuration error. Production
/// release builds inject both SUFeedURL and SUPublicEDKey into Info.plist.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController
    private(set) var hasStarted = false
    let isConfigured: Bool

    init(bundle: Bundle = .main) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isConfigured = !(feed ?? "").isEmpty && !(publicKey ?? "").isEmpty
    }

    func startIfNeeded() {
        guard isConfigured, !hasStarted else { return }
        controller.startUpdater()
        hasStarted = true
    }

    func checkForUpdates() {
        startIfNeeded()
        guard hasStarted else { return }
        controller.checkForUpdates(nil)
    }
}
