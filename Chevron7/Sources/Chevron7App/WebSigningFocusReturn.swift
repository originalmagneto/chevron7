// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Which app takes the keyboard back when the web signing panel closes.
///
/// Clicking the panel, typing the PIN or the eID client handing activation back
/// after the BOK makes Chevron7 the active app, and activating an app orders all
/// its windows front, so the main window sat over Safari once the panel closed.
/// The panel hands activation back to the browser that asked instead. Pure, so it
/// is tested with plain values instead of running apps.
enum WebSigningFocusReturn {
    struct App: Equatable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let executableName: String?
        let isTerminated: Bool

        init(processIdentifier: pid_t, bundleIdentifier: String?, executableName: String? = nil,
             isTerminated: Bool = false) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.executableName = executableName
            self.isTerminated = isTerminated
        }
    }

    static let browserBundleIdentifier = "com.apple.Safari"

    /// - Parameters:
    ///   - requester: the app that was frontmost when the request arrived.
    ///   - running: the running apps now, `requester` as it is now among them.
    ///   - ownProcessIdentifier: this app's pid.
    ///   - isActive: whether this app holds activation now. Only then does the
    ///     browser need it back; otherwise whatever the person switched to keeps it.
    /// - Returns: the pid to activate, or nil to leave activation alone.
    static func target(requester: App?, running: [App], ownProcessIdentifier: pid_t,
                       isActive: Bool) -> pid_t? {
        guard isActive else { return nil }
        let alive = running.filter { !$0.isTerminated && $0.processIdentifier != ownProcessIdentifier }
        if let requester,
           let current = alive.first(where: { $0.processIdentifier == requester.processIdentifier }),
           !isEIDKeyboard(current) {
            return current.processIdentifier
        }
        return alive.first { $0.bundleIdentifier == browserBundleIdentifier }?.processIdentifier
    }

    /// The eID client's BOK window, which is frontmost only while it asks for the BOK.
    private static func isEIDKeyboard(_ app: App) -> Bool {
        app.executableName == "VirtualKeyboard"
    }
}
