// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Foundation
import SafariServices

/// Whether Safari runs the extension this app carries.
enum SafariExtensionStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Safari did not say, as for a build Safari does not list (ad hoc signed).
    case unknown
}

/// Reads the extension's state from Safari and opens its settings there.
///
/// With the extension off nothing provides `window.ditec`, so a portal offers to
/// start D.Signer instead of signing through Chevron7, and the app hears nothing.
/// Safari turned it off by itself once (MacBook Air, 2026-10-23, a minute after
/// Sparkle installed 1.16.0 while Safari was starting) and the app gave no sign.
enum SafariExtensionState {
    static let identifier = ProductIdentity.webExtensionBundleIdentifier

    static func status(isEnabled: Bool?) -> SafariExtensionStatus {
        switch isEnabled {
        case true?: .enabled
        case false?: .disabled
        case nil: .unknown
        }
    }

    static func current() async -> SafariExtensionStatus {
        let isEnabled: Bool? = await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: identifier) { state, error in
                continuation.resume(returning: error == nil ? state?.isEnabled : nil)
            }
        }
        return status(isEnabled: isEnabled)
    }

    /// Opens Safari's Extensions settings on this extension, starting Safari when it
    /// is not running. Returns a message when Safari refused.
    static func openSafariSettings() async -> String? {
        await withCheckedContinuation { continuation in
            SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier) { error in
                continuation.resume(returning: error.map {
                    "Nastavenia rozšírenia v Safari sa nepodarilo otvoriť: \($0.localizedDescription)"
                })
            }
        }
    }
}
