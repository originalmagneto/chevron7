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
        case register(retireLegacyAgent: Bool)
    }

    enum Status: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case unsignedBuild
        case failed(String)
    }

    private static let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "web-bridge-agent")

    static func plan(teamIdentifier: String?, launchMode: AppLaunchMode, legacyAgentInstalled: Bool) -> Plan {
        guard let teamIdentifier, !teamIdentifier.isEmpty else { return .skipUnsigned }
        guard launchMode != .webSigning else { return .skipWebSigningLaunch }
        return .register(retireLegacyAgent: legacyAgentInstalled)
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

    /// Unloads the job the old installer bootstrapped and moves its plist to the
    /// Trash, so the bundled agent is the only job with this label.
    @discardableResult
    static func retireLegacyAgent(
        at url: URL = legacyPlistURL(),
        userID: uid_t = getuid(),
        bootout: (String) -> Void = runLaunchctlBootout,
        moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Bool {
        guard legacyAgentInstalled(at: url) else { return false }
        bootout("gui/\(userID)/\(label)")
        do {
            try moveToTrash(url)
            return true
        } catch {
            log.error("Legacy web bridge agent plist not removed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Runs before `WebBridgeListener.start()`, which connects to the agent.
    static func ensureRegistered(launchMode: AppLaunchMode = .current) {
        let plan = plan(teamIdentifier: ownTeamIdentifier(), launchMode: launchMode,
                        legacyAgentInstalled: legacyAgentInstalled())
        guard case .register(let legacyAgentFound) = plan else { return }
        let service = SMAppService.agent(plistName: plistName)
        do {
            if legacyAgentFound, retireLegacyAgent() {
                // The bootout above unloaded whichever job held the label, so a
                // registration that already existed is renewed as well.
                if service.status == .enabled {
                    try? service.unregister()
                }
            }
            if service.status != .enabled {
                try service.register()
            }
            log.info("Web bridge agent status: \(String(describing: service.status), privacy: .public)")
        } catch {
            log.error("Web bridge agent not registered: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func currentStatus() -> Status {
        guard ownTeamIdentifier() != nil else { return .unsignedBuild }
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

    private static func runLaunchctlBootout(_ target: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("launchctl bootout failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
