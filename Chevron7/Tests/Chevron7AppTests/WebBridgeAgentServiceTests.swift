// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import ServiceManagement
import XCTest
@testable import Chevron7App

final class WebBridgeAgentServiceTests: XCTestCase {
    private var directory: URL!
    private var launchctlCalls: [[String]] = []
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebBridgeAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        launchctlCalls = []
        trashed = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func plistData(label: String, program: String?) throws -> Data {
        var plist: [String: Any] = ["Label": label]
        if let program {
            plist["ProgramArguments"] = [program]
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func writePlist(label: String, program: String?) throws -> URL {
        let url = directory.appendingPathComponent(WebBridgeAgentService.plistName)
        try plistData(label: label, program: program).write(to: url)
        return url
    }

    private struct RegistrationRefused: Error {}

    private var staging: URL { directory.appendingPathComponent("staged.plist") }

    /// Records every step in order; moves are real, inside the test's own directory.
    private func migrate(_ url: URL, registerSucceeds: Bool) -> Bool {
        WebBridgeAgentService.migrateLegacyAgent(
            at: url,
            userID: 501,
            register: {
                // The old plist must be out of the way when the registration runs.
                self.launchctlCalls.append(["<register>",
                                            FileManager.default.fileExists(atPath: url.path) ? "plist present" : "plist aside"])
                if !registerSucceeds { throw RegistrationRefused() }
            },
            launchctl: { self.launchctlCalls.append($0) },
            waitUntilUnloaded: { self.launchctlCalls.append(["<wait>", $0]) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            stagingURL: staging,
            moveToTrash: { self.trashed.append($0) }
        )
    }

    // MARK: - Plan

    func testAdHocBuildLeavesTheAgentToTheDeveloperScript() {
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: nil, launchMode: .normal, translocated: false, legacyAgentInstalled: true),
                       .skipUnsigned)
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "", launchMode: .normal, translocated: false, legacyAgentInstalled: false),
                       .skipUnsigned)
    }

    /// The agent launched the app for a portal request and waits for it: ending
    /// the agent now would fail that request.
    func testWebSigningLaunchNeverTouchesTheRegistration() {
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "Q7AU96CW7H", launchMode: .webSigning, translocated: false,
                                                  legacyAgentInstalled: true),
                       .skipWebSigningLaunch)
    }

    func testSignedRegularLaunchRegistersAndRetiresTheOldInstallerAgent() {
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "Q7AU96CW7H", launchMode: .normal, translocated: false,
                                                  legacyAgentInstalled: true),
                       .register(retireLegacyAgent: true))
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "Q7AU96CW7H", launchMode: .normal, translocated: false,
                                                  legacyAgentInstalled: false),
                       .register(retireLegacyAgent: false))
    }

    // MARK: - Legacy plist

    func testOldInstallerPlistIsRecognisedForAnyCopyOfTheApp() throws {
        for program in ["/Applications/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent",
                        "/Users/someone/Builds/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent"] {
            let data = try plistData(label: "app.slovensko.chevron7.webbridge", program: program)
            XCTAssertTrue(WebBridgeAgentService.isLegacyAgentPlist(data), program)
        }
    }

    func testForeignPlistsAreNotRecognised() throws {
        XCTAssertFalse(WebBridgeAgentService.isLegacyAgentPlist(
            try plistData(label: "com.example.other", program: "/Applications/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent")))
        XCTAssertFalse(WebBridgeAgentService.isLegacyAgentPlist(
            try plistData(label: "app.slovensko.chevron7.webbridge", program: "/usr/local/bin/something-else")))
        XCTAssertFalse(WebBridgeAgentService.isLegacyAgentPlist(
            try plistData(label: "app.slovensko.chevron7.webbridge", program: nil)))
        XCTAssertFalse(WebBridgeAgentService.isLegacyAgentPlist(Data("not a plist".utf8)))
    }

    /// A quarantined app run from the DMG or not moved into place runs translocated,
    /// where SMAppService refuses to register; the old agent must stay untouched.
    func testTranslocatedAppLeavesEverythingAsItIs() {
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "Q7AU96CW7H", launchMode: .normal, translocated: true,
                                                  legacyAgentInstalled: true),
                       .skipTranslocated)
    }

    func testTranslocationIsRecognisedFromTheBundlePath() {
        XCTAssertTrue(WebBridgeAgentService.isTranslocated(
            bundlePath: "/private/var/folders/v0/x/T/AppTranslocation/4B8C0D07-BA55/d/Chevron7.app"))
        XCTAssertFalse(WebBridgeAgentService.isTranslocated(bundlePath: "/Applications/Chevron7.app"))
    }

    // MARK: - Migration

    func testOldAgentIsReplacedAndItsPlistTrashedAfterRegistration() throws {
        let url = try writePlist(label: "app.slovensko.chevron7.webbridge",
                                 program: "/Applications/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent")

        XCTAssertTrue(migrate(url, registerSucceeds: true))
        XCTAssertEqual(launchctlCalls, [["bootout", "gui/501/app.slovensko.chevron7.webbridge"],
                                        ["<wait>", "gui/501/app.slovensko.chevron7.webbridge"],
                                        ["<register>", "plist aside"]])
        XCTAssertEqual(trashed, [staging])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Safari must never lose its bridge: a refused registration loads the old
    /// agent again and keeps its plist.
    func testRefusedRegistrationRestoresTheOldAgent() throws {
        let url = try writePlist(label: "app.slovensko.chevron7.webbridge",
                                 program: "/Applications/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent")

        XCTAssertFalse(migrate(url, registerSucceeds: false))
        XCTAssertEqual(launchctlCalls, [["bootout", "gui/501/app.slovensko.chevron7.webbridge"],
                                        ["<wait>", "gui/501/app.slovensko.chevron7.webbridge"],
                                        ["<register>", "plist aside"],
                                        ["bootstrap", "gui/501", url.path]])
        XCTAssertEqual(trashed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The old plist must be back in place.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testForeignPlistWithOurNameIsNotTreatedAsTheOldAgent() throws {
        let url = try writePlist(label: "app.slovensko.chevron7.webbridge", program: "/usr/local/bin/something-else")

        XCTAssertFalse(WebBridgeAgentService.legacyAgentInstalled(at: url))
        XCTAssertFalse(WebBridgeAgentService.legacyAgentInstalled(
            at: directory.appendingPathComponent("missing.plist")))
    }

    func testPlistNameMatchesTheBundledAgentPlist() {
        XCTAssertEqual(WebBridgeAgentService.plistName, "app.slovensko.chevron7.webbridge.plist")
    }

    // MARK: - Status

    /// The MacBook Air case: "Povoliť na pozadí" off for the developer, every
    /// registration refused with SMAppServiceErrorDomain code 1.
    func testRefusalWithEPERMPointsToBackgroundItems() {
        let refused = NSError(domain: "SMAppServiceErrorDomain", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        XCTAssertEqual(WebBridgeAgentService.status(afterRegistrationError: refused), .deniedInBackgroundItems)
        XCTAssertEqual(WebBridgeAgentService.status(afterRegistrationError: NSError(domain: NSPOSIXErrorDomain, code: 1)),
                       .deniedInBackgroundItems)
    }

    func testOtherRefusalsKeepTheirMessage() {
        let other = NSError(domain: "SMAppServiceErrorDomain", code: 22,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid argument"])
        XCTAssertEqual(WebBridgeAgentService.status(afterRegistrationError: other), .failed("Invalid argument"))
    }

    func testOldAgentStillRunningIsNotShownAsMissing() {
        XCTAssertEqual(WebBridgeAgentService.status(service: .notRegistered, legacyAgentInstalled: true), .legacyAgentOnly)
        XCTAssertEqual(WebBridgeAgentService.status(service: .notRegistered, legacyAgentInstalled: false), .notRegistered)
        XCTAssertEqual(WebBridgeAgentService.status(service: .enabled, legacyAgentInstalled: true), .enabled)
        XCTAssertEqual(WebBridgeAgentService.status(service: .requiresApproval, legacyAgentInstalled: true), .requiresApproval)
    }
}
