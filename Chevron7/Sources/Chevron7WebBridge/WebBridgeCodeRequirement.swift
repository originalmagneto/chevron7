// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Security
import Chevron7Identity

/// A process that takes part in the Safari web bridge, by its code signing identifier.
public enum WebBridgePeer: CaseIterable, Sendable {
    case app
    case webExtension
    case agent
    /// `webbridge-probe`, the developer tool that stands in for Safari.
    case probe

    public var signingIdentifier: String {
        switch self {
        case .app: ProductIdentity.bundleIdentifier
        case .webExtension: ProductIdentity.webExtensionBundleIdentifier
        case .agent: ProductIdentity.webBridgeAgentIdentifier
        case .probe: ProductIdentity.webBridgeProbeIdentifier
        }
    }
}

/// What a caller of the launchd agent may do. One Mach service serves both, so
/// the agent decides the role when a connection arrives and refuses the other
/// method for its whole lifetime.
public enum WebBridgeCallerRole: CaseIterable, Sendable {
    /// The Chevron7 app: may publish its endpoint (`registerApp`).
    case app
    /// The Safari extension or the probe: may ask for the app's endpoint (`appEndpoint`).
    case endpointClient

    public var peers: [WebBridgePeer] {
        switch self {
        case .app: [.app]
        case .endpointClient: [.webExtension, .probe]
        }
    }

    /// The first role whose requirement `satisfies` accepts, or nil when none does.
    public static func classify(
        teamIdentifier: String?,
        satisfies: (String) -> Bool
    ) -> WebBridgeCallerRole? {
        allCases.first { satisfies(WebBridgeCodeRequirement.requirement(for: $0.peers, teamIdentifier: teamIdentifier)) }
    }
}

/// Code signing requirements for every connection of the web bridge.
///
/// Without them any process of the same user could look up the agent's Mach
/// service, publish its own endpoint in place of the app's (the extension would
/// then hand it portal documents and return its "signature" to the page), or
/// reach the app and submit requests that look like they came from a portal.
///
/// Each process derives the mode from its own signature, never from the peer
/// or from a file on disk, so a signed build cannot be talked into the weaker mode:
/// - Signed with a Team ID (Developer ID for releases, team Q7AU96CW7H): the peer
///   must carry an Apple-issued certificate of the same team and one of the
///   expected identifiers. `anchor apple generic` with the leaf OU also admits
///   Apple Development certificates of that team, so local signed builds work.
/// - Ad hoc (no Team ID, developer builds): only the identifier is checked. Any
///   local process can claim an identifier, so this is no security boundary; it
///   keeps the developer loop working and never ships, because releases are
///   Developer ID signed.
///
/// `webbridge-probe` is accepted alongside the extension. Against a Developer ID
/// build it must be signed by the same team:
/// `codesign -s "Developer ID Application: <team>" -i webbridge-probe <path>`.
public enum WebBridgeCodeRequirement {
    /// Requirement admitting any of `peers`, for a process signed by `teamIdentifier`
    /// (nil for ad hoc). A Team ID that is not 10 letters or digits yields `never`,
    /// so a surprising signature fails closed rather than producing a malformed
    /// string, which `NSXPCConnection` would raise as an uncatchable exception.
    public static func requirement(for peers: [WebBridgePeer], teamIdentifier: String?) -> String {
        let identifiers = peers.map { "identifier \"\($0.signingIdentifier)\"" }.joined(separator: " or ")
        guard !identifiers.isEmpty else { return "never" }
        guard let teamIdentifier else { return "(\(identifiers))" }
        guard isWellFormedTeamIdentifier(teamIdentifier) else { return "never" }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and (\(identifiers))"
    }

    /// Requirement for `peers` in the mode of the calling process.
    public static func requirement(for peers: [WebBridgePeer]) -> String {
        let candidate = requirement(for: peers, teamIdentifier: ownTeamIdentifier)
        return isValid(candidate) ? candidate : "never"
    }

    /// The Team ID of the running process, or nil when it is signed ad hoc.
    public static let ownTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// True when the requirement language accepts `requirement`.
    public static func isValid(_ requirement: String) -> Bool {
        var parsed: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess && parsed != nil
    }

    /// Whether the process `processIdentifier` currently satisfies `requirement`.
    ///
    /// A pid can be reused, so this only chooses which requirement to enforce;
    /// `NSXPCConnection.setCodeSigningRequirement(_:)` then checks every message
    /// against the connection's audit token, and a wrong choice fails closed.
    public static func process(_ processIdentifier: pid_t, satisfies requirement: String) -> Bool {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
              let parsed else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], parsed) == errSecSuccess
    }

    private static func isWellFormedTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
