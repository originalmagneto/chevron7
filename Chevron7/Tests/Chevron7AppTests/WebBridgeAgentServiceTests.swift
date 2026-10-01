// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class WebBridgeAgentServiceTests: XCTestCase {
    private var directory: URL!
    private var bootouts: [String] = []
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebBridgeAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bootouts = []
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

    private func retire(_ url: URL) -> Bool {
        WebBridgeAgentService.retireLegacyAgent(
            at: url,
            userID: 501,
            bootout: { self.bootouts.append($0) },
            moveToTrash: { self.trashed.append($0) }
        )
    }

    // MARK: - Plan

    func testAdHocBuildLeavesTheAgentToTheDeveloperScript() {
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: nil, launchMode: .normal, legacyAgentInstalled: true),
                       .skipUnsigned)
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "", launchMode: .normal, legacyAgentInstalled: false),
                       .skipUnsigned)
    }

    /// The agent launched the app for a portal request and waits for it: ending
    /// the agent now would fail that request.
    func testWebSigningLaunchNeverTouchesTheRegistration() {
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "Q7AU96CW7H", launchMode: .webSigning,
                                                  legacyAgentInstalled: true),
                       .skipWebSigningLaunch)
    }

    func testSignedRegularLaunchRegistersAndRetiresTheOldInstallerAgent() {
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "Q7AU96CW7H", launchMode: .normal,
                                                  legacyAgentInstalled: true),
                       .register(retireLegacyAgent: true))
        XCTAssertEqual(WebBridgeAgentService.plan(teamIdentifier: "Q7AU96CW7H", launchMode: .normal,
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

    // MARK: - Retirement

    func testOldInstallerAgentIsBootedOutAndTrashed() throws {
        let url = try writePlist(label: "app.slovensko.chevron7.webbridge",
                                 program: "/Applications/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent")

        XCTAssertTrue(retire(url))
        XCTAssertEqual(bootouts, ["gui/501/app.slovensko.chevron7.webbridge"])
        XCTAssertEqual(trashed, [url])
    }

    func testForeignPlistWithOurNameIsLeftAlone() throws {
        let url = try writePlist(label: "app.slovensko.chevron7.webbridge", program: "/usr/local/bin/something-else")

        XCTAssertFalse(retire(url))
        XCTAssertEqual(bootouts, [])
        XCTAssertEqual(trashed, [])
    }

    func testMissingPlistIsNothingToRetire() {
        XCTAssertFalse(retire(directory.appendingPathComponent(WebBridgeAgentService.plistName)))
        XCTAssertEqual(bootouts, [])
        XCTAssertEqual(trashed, [])
    }

    func testPlistNameMatchesTheBundledAgentPlist() {
        XCTAssertEqual(WebBridgeAgentService.plistName, "app.slovensko.chevron7.webbridge.plist")
    }
}
