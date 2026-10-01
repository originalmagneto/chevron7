// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Security
import ServiceManagement
import Chevron7Identity
import os

/// Registers the launchd agent that owns the web bridge Mach service from inside
/// the bundle (`Contents/Library/LaunchAgents`, `SMAppService`).
///
/// A Developer ID release used to need `Install Safari Bridge.command` from the
/// DMG, which Gatekeeper refuses because a shell script cannot be notarized. The
/// signed app now registers the agent itself. An ad hoc build cannot use
/// `SMAppService` and keeps `scripts/install-webbridge-agent.sh`.
enum WebBridgeAgentService {
    static let label = ProductIdentity.webBridgeServiceName
    static let plistName = "\(ProductIdentity.webBridgeServiceName).plist"
    /// Where the agent binary sits in every bundle; a plist written by the old
    /// installer points here, in whichever copy of the app it was run for.
    static let agentPathSuffix = "/Contents/Helpers/chevron7-webbridge-agent"

    enum Plan: Equatable {
        /// Ad hoc build: `SMAppService` refuses it, the developer script stays in charge.
        case skipUnsigned
        /// A portal request launched the app through the agent; touching the
        /// registration now would end the agent while it waits for this app.
        case skipWebSigningLaunch
        /// Gatekeeper runs a quarantined app that was not moved into place from a
        /// read-only copy (App Translocation), and `SMAppService` refuses to
        /// register from there ("Operation not permitted").
        case skipTranslocated
        case register(retireLegacyAgent: Bool)
    }

    enum Status: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case unsignedBuild
        case translocated
        case failed(String)
    }

    private static let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "web-bridge-agent")

    static func plan(teamIdentifier: String?, launchMode: AppLaunchMode, translocated: Bool,
                     legacyAgentInstalled: Bool) -> Plan {
        guard let teamIdentifier, !teamIdentifier.isEmpty else { return .skipUnsigned }
        guard launchMode != .webSigning else { return .skipWebSigningLaunch }
        guard !translocated else { return .skipTranslocated }
        return .register(retireLegacyAgent: legacyAgentInstalled)
    }

    static func isTranslocated(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// True only for a plist the old installer wrote for this agent: it must
    /// carry our label and run our agent binary. Anything else is left alone.
    static func isLegacyAgentPlist(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label,
              let arguments = plist["ProgramArguments"] as? [String],
              let program = arguments.first else { return false }
        return program.hasSuffix(agentPathSuffix)
    }

    static func legacyPlistURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(plistName)")
    }

    static func legacyAgentInstalled(at url: URL = legacyPlistURL()) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isLegacyAgentPlist(data)
    }

    /// Replaces the job the old installer bootstrapped with the bundled agent.
    /// Both use the same label, so the old job is unloaded first; its plist goes
    /// to the Trash only once the new registration has succeeded, and on failure
    /// the old job is loaded again, so Safari never loses its bridge.
    @discardableResult
    static func migrateLegacyAgent(
        at url: URL = legacyPlistURL(),
        userID: uid_t = getuid(),
        register: () throws -> Void,
        launchctl: ([String]) -> Void = runLaunchctl,
        moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Bool {
        let domain = "gui/\(userID)"
        launchctl(["bootout", "\(domain)/\(label)"])
        do {
            try register()
        } catch {
            log.error("Web bridge agent not registered, old agent restored: \(error.localizedDescription, privacy: .public)")
            launchctl(["bootstrap", domain, url.path])
            return false
        }
        do {
            try moveToTrash(url)
        } catch {
            log.error("Old web bridge agent plist not removed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    /// Runs before `WebBridgeListener.start()`, which connects to the agent.
    static func ensureRegistered(launchMode: AppLaunchMode = .current) {
        let plan = plan(teamIdentifier: ownTeamIdentifier(), launchMode: launchMode,
                        translocated: isTranslocated(), legacyAgentInstalled: legacyAgentInstalled())
        guard case .register(let legacyAgentFound) = plan else {
            log.info("Web bridge agent left alone: \(String(describing: plan), privacy: .public)")
            return
        }
        let service = SMAppService.agent(plistName: plistName)
        if legacyAgentFound {
            migrateLegacyAgent(register: {
                // The bootout unloaded whichever job held the label, so an existing
                // registration is renewed as well.
                if service.status == .enabled {
                    try? service.unregister()
                }
                try service.register()
            })
        } else if service.status != .enabled {
            do {
                try service.register()
            } catch {
                log.error("Web bridge agent not registered: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("Web bridge agent status: \(String(describing: service.status), privacy: .public)")
    }

    static func currentStatus() -> Status {
        guard ownTeamIdentifier() != nil else { return .unsignedBuild }
        guard !isTranslocated() else { return .translocated }
        switch SMAppService.agent(plistName: plistName).status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    /// Registers again on demand, for the Settings button.
    static func registerNow() -> Status {
        do {
            try SMAppService.agent(plistName: plistName).register()
        } catch {
            if currentStatus() != .enabled {
                return .failed(error.localizedDescription)
            }
        }
        return currentStatus()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The Team ID of the running app's signature; nil for an ad hoc build.
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("launchctl \(arguments.first ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
