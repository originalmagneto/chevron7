// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Identity
import Chevron7Kit
import os

/// Brackets an engine call that makes the eID client ask for the BOK, so the
/// stores can be tested without moving the keyboard.
@MainActor
protocol MiddlewareInputHandoff: AnyObject {
    func begin()
    func end()
}

extension MiddlewareInputHandoff {
    /// Runs `body` inside `begin()`/`end()` when `applies`, ending on a throw too.
    func during<T>(_ applies: Bool, _ body: () async throws -> T) async rethrows -> T {
        guard applies else { return try await body() }
        begin()
        defer { end() }
        return try await body()
    }
}

/// Hands the keyboard to the eID client's BOK window while the engine waits for it.
///
/// The eID PKCS#11 module, running inside the signing engine, starts the eID
/// client's `VirtualKeyboard` process for the BOK. A process started that way is
/// not activated, so the keyboard stayed with Chevron7: in the Safari panel, and
/// in the main window with the PIN field still focused, where typing the BOK went
/// into that field (reported 2026-10-15). `begin` takes the keyboard away from
/// any text field here and activates each BOK window that appears, which the
/// system allows only while this app is the active one, so nothing may
/// deactivate the app before the engine runs.
@MainActor
final class EIDKeyboardHandoff: MiddlewareInputHandoff {
    /// The main window's stores share this one; the Safari panel owns its own.
    static let shared = EIDKeyboardHandoff(reclaimsActivation: true)

    /// Called on every poll with the BOK window's number, so the Safari panel
    /// can keep itself just beneath it.
    var onKeyboardWindow: (@MainActor (Int) -> Void)?

    private let reclaimsActivation: Bool
    private var depth = 0
    private var poll: Task<Void, Never>?
    private let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "eid-keyboard")

    /// - Parameter reclaimsActivation: whether `end` takes activation back from
    ///   an eID process still in front. The main window wants it; the Safari panel
    ///   hands activation to the browser on its own (`WebSigningFocusReturn`).
    init(reclaimsActivation: Bool) {
        self.reclaimsActivation = reclaimsActivation
    }

    /// Whether signing or reading certificates with this identity asks the eID
    /// client for the BOK instead of taking a PIN typed here.
    nonisolated static func applies(to identity: SigningIdentityInfo?) -> Bool {
        identity?.usesProtectedAuthenticationPath ?? false
    }

    /// The eID client's BOK window, by its executable. Both the name and the eID
    /// client's folder have to match, so no other `VirtualKeyboard` gets the keyboard.
    nonisolated static func isEIDKeyboard(executableURL: URL?) -> Bool {
        guard let executableURL else { return false }
        return executableURL.lastPathComponent == "VirtualKeyboard" && executableURL.path.contains("eID")
    }

    /// Any eID client process, the BOK window included.
    nonisolated static func isEIDClient(executableURL: URL?) -> Bool {
        guard let path = executableURL?.path else { return false }
        return path.contains("eID") || path.contains("VirtualKeyboard")
    }

    /// Whether `end` asks for activation back: only when Chevron7 lost it to the
    /// eID client, never when the person switched to another app meanwhile.
    nonisolated static func shouldReclaimActivation(isActive: Bool, frontmostExecutableURL: URL?) -> Bool {
        !isActive && isEIDClient(executableURL: frontmostExecutableURL)
    }

    func begin() {
        depth += 1
        guard depth == 1 else { return }
        // Keystrokes meant for the BOK must never land in the PIN field.
        NSApp.keyWindow?.makeFirstResponder(nil)
        poll?.cancel()
        log.notice("BOK handoff started, app active: \(NSApp.isActive, privacy: .public)")
        poll = Task { @MainActor [log, weak self] in
            var activated = Set<pid_t>()
            var reported = Set<pid_t>()
            while !Task.isCancelled {
                for app in NSWorkspace.shared.runningApplications {
                    // Diagnostics: every eID client process seen while the BOK is expected.
                    if Self.isEIDClient(executableURL: app.executableURL), !reported.contains(app.processIdentifier) {
                        reported.insert(app.processIdentifier)
                        log.notice("""
                            eID process pid=\(app.processIdentifier, privacy: .public) \
                            bundle=\(app.bundleIdentifier ?? "-", privacy: .public) \
                            path=\(app.executableURL?.path ?? "-", privacy: .public) \
                            policy=\(app.activationPolicy.rawValue, privacy: .public) active=\(app.isActive, privacy: .public)
                            """)
                    }
                    guard Self.isEIDKeyboard(executableURL: app.executableURL) else { continue }
                    if let onKeyboardWindow = self?.onKeyboardWindow,
                       let window = Self.frontWindowNumber(of: app.processIdentifier) {
                        onKeyboardWindow(window)
                    }
                    guard !activated.contains(app.processIdentifier) else { continue }
                    activated.insert(app.processIdentifier)
                    NSApp.yieldActivation(to: app)
                    let accepted = app.activate(from: .current, options: [])
                    log.notice("""
                        BOK window activation pid=\(app.processIdentifier, privacy: .public) \
                        accepted=\(accepted, privacy: .public) app active=\(NSApp.isActive, privacy: .public)
                        """)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func end() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        poll?.cancel()
        poll = nil
        guard reclaimsActivation else { return }
        // Closing the BOK window normally hands activation back to this app; when
        // the eID client keeps it, ask for it back so the result shows with the keyboard.
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard Self.shouldReclaimActivation(isActive: NSApp.isActive,
                                           frontmostExecutableURL: frontmost?.executableURL) else { return }
        NSApp.activate()
        log.notice("BOK handoff ended, activation asked back from pid=\(frontmost?.processIdentifier ?? 0, privacy: .public)")
    }

    /// Ends a handoff still running, whatever its depth (the Safari panel closing).
    func reset() {
        depth = 0
        poll?.cancel()
        poll = nil
    }

    /// Number of the process's front on-screen window, from the window list.
    private static func frontWindowNumber(of pid: pid_t) -> Int? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }?[kCGWindowNumber as String] as? Int
    }
}
