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
            requestState { continuation.resume(returning: $0) }
        }
        return status(isEnabled: isEnabled)
    }

    private typealias StateHandler = @convention(block) (SFSafariExtensionState?, NSError?) -> Void

    /// The SDK declares the completion handler `NS_SWIFT_UI_ACTOR`, so a Swift closure
    /// passed to `getStateOfSafariExtension` checks that it runs on the main actor,
    /// while SafariServices calls it on its XPC queue: 1.17.0 trapped there every time
    /// Settings opened Prehliadač a Finder (2026-10-23). The selector is sent through
    /// the runtime with a plain block instead, which carries no isolation.
    private static func requestState(_ done: @escaping @Sendable (Bool?) -> Void) {
        let selector = NSSelectorFromString("getStateOfSafariExtensionWithIdentifier:completionHandler:")
        let manager: AnyObject = SFSafariExtensionManager.self
        guard manager.responds(to: selector) else {
            done(nil)
            return
        }
        let handler: StateHandler = { state, error in
            done(error == nil ? state?.isEnabled : nil)
        }
        _ = manager.perform(selector, with: identifier as NSString, with: handler as AnyObject)
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
