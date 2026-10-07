// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

/// Sparkle replaces the app bundle while the launchd agent keeps running from the
/// old copy, which it then deletes. The Safari extension checks the agent's code
/// signature and refused every request (-67065) until the Mac restarted.
final class WebBridgeAgentStalenessTests: XCTestCase {
    private let agentPath = "/Applications/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent"
    private let launched = WebBridgeAgentStaleness.FileIdentity(device: 16, inode: 1000)

    func testAgentStillAtItsLaunchPathIsCurrent() {
        XCTAssertFalse(WebBridgeAgentStaleness.isStale(
            launchPath: agentPath, launchFile: launched,
            runningPath: agentPath, fileAtLaunchPath: launched))
    }

    /// Sparkle moves the old bundle into its cache; the running image follows it.
    func testAgentMovedAwayFromItsLaunchPathIsStale() {
        XCTAssertTrue(WebBridgeAgentStaleness.isStale(
            launchPath: agentPath, launchFile: launched,
            runningPath: "/Users/x/Library/Caches/app.slovensko.chevron7/org.sparkle-project.Sparkle/Installation/a/b/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent",
            fileAtLaunchPath: WebBridgeAgentStaleness.FileIdentity(device: 16, inode: 2000)))
    }

    /// A copy over the old bundle keeps the path but puts another file there.
    func testAnotherFileAtTheLaunchPathIsStale() {
        XCTAssertTrue(WebBridgeAgentStaleness.isStale(
            launchPath: agentPath, launchFile: launched,
            runningPath: agentPath,
            fileAtLaunchPath: WebBridgeAgentStaleness.FileIdentity(device: 16, inode: 2000)))
    }

    func testNoFileAtTheLaunchPathIsStale() {
        XCTAssertTrue(WebBridgeAgentStaleness.isStale(
            launchPath: agentPath, launchFile: launched,
            runningPath: agentPath, fileAtLaunchPath: nil))
    }

    /// What could not be read at launch decides nothing, so a failing system
    /// call never makes a healthy agent quit on every connection.
    func testUnknownLaunchStateNeverCountsAsStale() {
        XCTAssertFalse(WebBridgeAgentStaleness.isStale(
            launchPath: nil, launchFile: nil,
            runningPath: "/elsewhere/chevron7-webbridge-agent", fileAtLaunchPath: nil))
    }

    func testUnknownRunningPathFallsBackToTheFileCheck() {
        XCTAssertFalse(WebBridgeAgentStaleness.isStale(
            launchPath: agentPath, launchFile: launched,
            runningPath: nil, fileAtLaunchPath: launched))
        XCTAssertTrue(WebBridgeAgentStaleness.isStale(
            launchPath: agentPath, launchFile: launched,
            runningPath: nil, fileAtLaunchPath: nil))
    }

    /// The live helpers read this very test process: it is where it was started.
    func testThisProcessIsNotStale() throws {
        let path = try XCTUnwrap(WebBridgeAgentStaleness.runningExecutablePath())
        let file = try XCTUnwrap(WebBridgeAgentStaleness.fileIdentity(atPath: path))
        XCTAssertFalse(WebBridgeAgentStaleness.isStale(
            launchPath: path, launchFile: file,
            runningPath: WebBridgeAgentStaleness.runningExecutablePath(),
            fileAtLaunchPath: WebBridgeAgentStaleness.fileIdentity(atPath: path)))
    }
}

/// An agent started before an update keeps running the deleted old copy and has
/// no staleness check of its own, so the app ends it when it starts.
final class WebBridgeAbandonedAgentTests: XCTestCase {
    private let sparkleCopy = "/Users/x/Library/Caches/app.slovensko.chevron7/org.sparkle-project.Sparkle/Installation/a/b/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent"

    func testAgentWhoseFileWasDeletedIsAbandoned() {
        XCTAssertTrue(WebBridgeAgentStaleness.isAbandoned(executablePath: sparkleCopy, fileExists: false))
    }

    /// Once its file is deleted the kernel reports no path for the process at
    /// all (proc_pidpath fails with ENOENT), which is what Sparkle leaves behind.
    func testAgentWithoutAnExecutablePathIsAbandoned() {
        XCTAssertTrue(WebBridgeAgentStaleness.isAbandoned(executablePath: nil, fileExists: false))
    }

    func testAgentRunningFromTheTrashIsAbandoned() {
        XCTAssertTrue(WebBridgeAgentStaleness.isAbandoned(
            executablePath: "/Users/x/.Trash/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent", fileExists: true))
    }

    /// A development agent from another copy is left alone: it still exists.
    func testAgentWhoseFileExistsIsKept() {
        XCTAssertFalse(WebBridgeAgentStaleness.isAbandoned(
            executablePath: "/Applications/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent", fileExists: true))
        XCTAssertFalse(WebBridgeAgentStaleness.isAbandoned(
            executablePath: "/Users/x/Projects/Chevron7/.build/out/Products/Debug/Chevron7.app/Contents/Helpers/chevron7-webbridge-agent",
            fileExists: true))
    }

    /// The live scan never reports this test process, which is not an agent.
    func testScanFindsOnlyAgents() {
        XCTAssertFalse(WebBridgeAgentStaleness.abandonedAgentProcesses().contains(getpid()))
    }
}
