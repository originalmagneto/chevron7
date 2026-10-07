// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Security
import ServiceManagement
import Chevron7Identity
import Chevron7WebBridge
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
        /// The bundled agent is not registered, but the old installer's job still runs.
        case legacyAgentOnly
        /// macOS refused the registration (EPERM). `legacyAgentInstalled` says whether
        /// the old installer's plist is still there, which keeps it refusing.
        case refusedByMacOS(legacyAgentInstalled: Bool)
        /// The old installer's agent was just removed; macOS lets the bundled one in
        /// only after a restart.
        case legacyAgentRemoved
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
    ///
    /// Both use the same label. Registering while the old plist still lay in
    /// `~/Library/LaunchAgents`, right after a bootout launchd had not finished,
    /// was refused with "Operation not permitted" on every launch (MacBook Air,
    /// 2026-10-06), so the old job is unloaded, waited for, and its plist moved
    /// aside before registering. On failure the plist goes back and the old job is
    /// loaded again, so Safari never loses its bridge; on success it goes to the Trash.
    @discardableResult
    static func migrateLegacyAgent(
        at url: URL = legacyPlistURL(),
        userID: uid_t = getuid(),
        register: () throws -> Void,
        launchctl: ([String]) -> Void = runLaunchctl,
        waitUntilUnloaded: (String) -> Void = waitUntilUnloaded,
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
        stagingURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(plistName)"),
        moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Bool {
        let domain = "gui/\(userID)"
        let service = "\(domain)/\(label)"
        launchctl(["bootout", service])
        waitUntilUnloaded(service)
        var staged: URL?
        do {
            try moveItem(url, stagingURL)
            staged = stagingURL
        } catch {
            log.error("Old web bridge agent plist not moved aside: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try register()
        } catch {
            let nsError = error as NSError
            log.error("""
                Web bridge agent not registered, old agent restored: \(error.localizedDescription, privacy: .public) \
                domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)
                """)
            if let staged {
                do {
                    try moveItem(staged, url)
                } catch {
                    log.error("Old web bridge agent plist not put back: \(error.localizedDescription, privacy: .public)")
                }
            }
            launchctl(["bootstrap", domain, url.path])
            return false
        }
        do {
            try moveToTrash(staged ?? url)
        } catch {
            log.error("Old web bridge agent plist not removed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    /// Waits up to about three seconds for launchd to drop the service after a bootout.
    private static func waitUntilUnloaded(_ service: String) {
        for _ in 0..<15 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", service]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            if process.terminationStatus != 0 { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Ends an agent still running from a copy of Chevron7 that an update or a
    /// reinstall replaced. The Safari extension refuses such an agent (its code
    /// signature check fails with -67065), and an agent from before
    /// `WebBridgeAgentStaleness` never quits on its own, so signing from Safari
    /// stayed broken until the Mac restarted. launchd starts the current agent
    /// when the listener connects. Runs before `WebBridgeListener.start()`.
    static func retireAbandonedAgents() {
        for pid in WebBridgeAgentStaleness.abandonedAgentProcesses() {
            log.info("Ending web bridge agent \(pid) left over from a replaced copy of Chevron7")
            kill(pid, SIGTERM)
        }
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
        return status(service: SMAppService.agent(plistName: plistName).status,
                      legacyAgentInstalled: legacyAgentInstalled())
    }

    /// What Settings show for the registration state. The old installer's job still
    /// answers Safari while the bundled agent is not registered, but launchd does not
    /// start it again at login once Background Task Management has it switched off.
    static func status(service: SMAppService.Status, legacyAgentInstalled: Bool) -> Status {
        switch service {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return legacyAgentInstalled ? .legacyAgentOnly : .notRegistered
        @unknown default: return legacyAgentInstalled ? .legacyAgentOnly : .notRegistered
        }
    }

    /// A refused registration. On the owner's MacBook Air (2026-10-06) every
    /// registration failed with `SMAppServiceErrorDomain` code 1 (EPERM) while Background
    /// Task Management still recorded the old installer's agent under the same label
    /// (`sfltool dumpbtm`: legacy agent, `[disabled, allowed, notified]`), although
    /// "Povoliť na pozadí" had the developer on. Moving the plist aside for the attempt
    /// did not help; what did was removing it for good, restarting the Mac and
    /// registering a few minutes later, once the record was gone.
    static func status(afterRegistrationError error: Error, legacyAgentInstalled: Bool) -> Status {
        let nsError = error as NSError
        let isEPERM = (nsError.domain == "SMAppServiceErrorDomain" || nsError.domain == NSPOSIXErrorDomain)
            && nsError.code == Int(EPERM)
        return isEPERM ? .refusedByMacOS(legacyAgentInstalled: legacyAgentInstalled) : .failed(error.localizedDescription)
    }

    /// Unloads the old installer's agent and moves its plist to the Trash, for the
    /// Settings button. Safari has no bridge until the bundled agent is registered
    /// after a restart, which Settings say before and after.
    @discardableResult
    static func retireLegacyAgent(
        at url: URL = legacyPlistURL(),
        userID: uid_t = getuid(),
        launchctl: ([String]) -> Void = runLaunchctl,
        moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Status {
        launchctl(["bootout", "gui/\(userID)/\(label)"])
        do {
            try moveToTrash(url)
        } catch {
            log.error("Old web bridge agent plist not removed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        return .legacyAgentRemoved
    }

    /// Registers again on demand, for the Settings button.
    static func registerNow() -> Status {
        let service = SMAppService.agent(plistName: plistName)
        var failure: Error?
        let register = {
            do {
                try service.register()
            } catch {
                failure = error
                throw error
            }
        }
        // The old installer's job holds the same label; it has to go through the
        // same replacement as at launch, or the registration is refused again.
        if legacyAgentInstalled() {
            migrateLegacyAgent(register: register)
        } else {
            try? register()
        }
        let current = currentStatus()
        if let failure, current != .enabled {
            return status(afterRegistrationError: failure, legacyAgentInstalled: legacyAgentInstalled())
        }
        return current
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
