// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Every name macOS and Safari know this product by, in one place.
///
/// `build_app.sh`, `scripts/install-webbridge-agent.sh`, `scripts/safari-spike.sh`
/// and `WebExtension/dist/background.js` repeat these literals because they cannot
/// import Swift; `ProductIdentityTests` pins the Swift values and
/// `scripts/check-rename-boundary.sh --strict` catches old names, so a changed
/// value here must be changed there by hand.
public enum ProductIdentity {
    public static let name = "Chevron7"
    public static let bundleIdentifier = "app.slovensko.chevron7"
    public static let webExtensionBundleIdentifier = "app.slovensko.chevron7.WebExtension"
    /// Mach service the launchd agent owns, and the agent's label.
    public static let webBridgeServiceName = "app.slovensko.chevron7.webbridge"
    /// Code signing identifier of the launchd agent: a bare executable, so its
    /// file name. `scripts/sign-release.sh` passes it explicitly.
    public static let webBridgeAgentIdentifier = "chevron7-webbridge-agent"
    /// Code signing identifier of the `webbridge-probe` developer tool.
    public static let webBridgeProbeIdentifier = "webbridge-probe"
    public static let urlScheme = "chevron7"
    public static let installedAppURL = URL(fileURLWithPath: "/Applications/Chevron7.app", isDirectory: true)

    /// `~/Library/Application Support/Chevron7`, the one root for every file the app keeps.
    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    /// `~/Library/Caches/Chevron7`, for files the app can always recreate.
    public static func cachesDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }
}
