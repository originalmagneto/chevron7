// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Security
import XCTest
@testable import Chevron7WebBridge

@objc private protocol RequirementEchoProtocol {
    func echo(_ value: String, reply: @escaping (String) -> Void)
}

private final class RequirementEcho: NSObject, RequirementEchoProtocol {
    func echo(_ value: String, reply: @escaping (String) -> Void) { reply(value) }
}

private final class RequirementListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RequirementEchoProtocol.self)
        connection.exportedObject = RequirementEcho()
        connection.resume()
        return true
    }
}

/// Any process of the same user could reach the agent and the app before these
/// requirements: publish its own endpoint in place of the app's, or submit
/// requests that look like they came from a portal.
final class WebBridgeCodeRequirementTests: XCTestCase {
    func testSignedBuildRequiresTheTeamAndTheIdentifiers() {
        XCTAssertEqual(
            WebBridgeCodeRequirement.requirement(for: [.webExtension, .probe], teamIdentifier: "Q7AU96CW7H"),
            "anchor apple generic and certificate leaf[subject.OU] = \"Q7AU96CW7H\" and "
                + "(identifier \"app.slovensko.chevron7.WebExtension\" or identifier \"webbridge-probe\")"
        )
        XCTAssertEqual(
            WebBridgeCodeRequirement.requirement(for: [.app], teamIdentifier: "Q7AU96CW7H"),
            "anchor apple generic and certificate leaf[subject.OU] = \"Q7AU96CW7H\" and (identifier \"app.slovensko.chevron7\")"
        )
    }

    func testAdHocBuildChecksOnlyTheIdentifier() {
        XCTAssertEqual(
            WebBridgeCodeRequirement.requirement(for: [.agent], teamIdentifier: nil),
            "(identifier \"chevron7-webbridge-agent\")"
        )
    }

    func testUnexpectedInputFailsClosed() {
        XCTAssertEqual(WebBridgeCodeRequirement.requirement(for: [.app], teamIdentifier: "Q7AU96CW7H\" or anchor"), "never")
        XCTAssertEqual(WebBridgeCodeRequirement.requirement(for: [.app], teamIdentifier: "SHORT"), "never")
        XCTAssertEqual(WebBridgeCodeRequirement.requirement(for: [], teamIdentifier: "Q7AU96CW7H"), "never")
    }

    /// `NSXPCConnection` raises an Objective-C exception on a malformed
    /// requirement, which Swift cannot catch, so every variant must parse.
    func testEveryRequirementParses() {
        let peerSets: [[WebBridgePeer]] = [[.app], [.agent], [.webExtension], [.probe], [.webExtension, .probe]]
        for peers in peerSets {
            for team in ["Q7AU96CW7H", nil, "bad\"team"] as [String?] {
                let requirement = WebBridgeCodeRequirement.requirement(for: peers, teamIdentifier: team)
                XCTAssertTrue(WebBridgeCodeRequirement.isValid(requirement), requirement)
            }
            XCTAssertTrue(WebBridgeCodeRequirement.isValid(WebBridgeCodeRequirement.requirement(for: peers)))
        }
    }

    func testRolesSeparateTheAppFromItsClients() {
        XCTAssertEqual(WebBridgeCallerRole.app.peers, [.app])
        XCTAssertEqual(WebBridgeCallerRole.endpointClient.peers, [.webExtension, .probe])

        let appRequirement = WebBridgeCodeRequirement.requirement(for: [.app], teamIdentifier: "Q7AU96CW7H")
        let clientRequirement = WebBridgeCodeRequirement.requirement(for: [.webExtension, .probe], teamIdentifier: "Q7AU96CW7H")
        XCTAssertEqual(WebBridgeCallerRole.classify(teamIdentifier: "Q7AU96CW7H") { $0 == appRequirement }, .app)
        XCTAssertEqual(WebBridgeCallerRole.classify(teamIdentifier: "Q7AU96CW7H") { $0 == clientRequirement }, .endpointClient)
        XCTAssertNil(WebBridgeCallerRole.classify(teamIdentifier: "Q7AU96CW7H") { _ in false })
    }

    func testRunningProcessIsCheckedAgainstItsOwnRequirement() throws {
        let own = try ownDesignatedRequirement()
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(WebBridgeCodeRequirement.process(pid, satisfies: own))
        XCTAssertFalse(WebBridgeCodeRequirement.process(pid, satisfies: "never"))
        XCTAssertFalse(WebBridgeCodeRequirement.process(pid, satisfies: "identifier \"app.slovensko.chevron7\""))
    }

    /// Ad hoc builds rely on identifier-only requirements. The linker signs a
    /// product as "<name>-<hash>", which they do not match, so `build_app.sh` and
    /// `scripts/webbridge-probe.sh` sign the agent and the probe with the plain name.
    func testIdentifierOnlyRequirementMatchesAnAdHocSignatureWithThatIdentifier() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("webbridge-probe")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--identifier", "webbridge-probe", binary.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0)

        var staticCode: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(binary as CFURL, [], &staticCode), errSecSuccess)
        let code = try XCTUnwrap(staticCode)
        XCTAssertTrue(self.staticCode(code, satisfies: WebBridgeCodeRequirement.requirement(
            for: WebBridgeCallerRole.endpointClient.peers, teamIdentifier: nil)))
        XCTAssertFalse(self.staticCode(code, satisfies: WebBridgeCodeRequirement.requirement(
            for: WebBridgeCallerRole.app.peers, teamIdentifier: nil)))
        XCTAssertFalse(self.staticCode(code, satisfies: WebBridgeCodeRequirement.requirement(
            for: WebBridgeCallerRole.endpointClient.peers, teamIdentifier: "Q7AU96CW7H")))
    }

    func testListenerAcceptsAMatchingPeer() throws {
        let reply = try echo(through: ownDesignatedRequirement())
        XCTAssertEqual(reply, "signed")
    }

    func testListenerRefusesAPeerThatDoesNotMatch() {
        XCTAssertNil(echo(through: WebBridgeCodeRequirement.requirement(for: [.webExtension, .probe], teamIdentifier: "Q7AU96CW7H")))
    }

    // MARK: - Helpers

    private func ownDesignatedRequirement() throws -> String {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode), errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), [], &requirement), errSecSuccess)
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), [], &text), errSecSuccess)
        return try XCTUnwrap(text) as String
    }

    private func staticCode(_ code: SecStaticCode, satisfies requirement: String) -> Bool {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return false }
        return SecStaticCodeCheckValidity(code, [], parsed) == errSecSuccess
    }

    /// Sends one message through an anonymous listener guarded by `requirement`;
    /// this process is the peer. Nil when the connection was refused.
    private func echo(through requirement: String) -> String? {
        let delegate = RequirementListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: RequirementEchoProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let done = expectation(description: "reply or error")
        let result = LockedValue()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.fulfill() } as? RequirementEchoProtocol
        proxy?.echo("signed") { value in
            result.set(value)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result.get()
    }
}

private final class LockedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
