// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Chevron7TestSupport
import Foundation
import XCTest

/// `RealStorageGuard` installs itself when the test bundle loads; these pin that and the
/// folders it watches. The Kit target has the same checks.
final class RealStorageGuardTests: XCTestCase {
    func testGuardIsInstalledBeforeTestsRun() {
        XCTAssertTrue(RealStorageGuard.isInstalled)
    }

    func testGuardWatchesTheProductDataRoots() {
        XCTAssertEqual(RealStorageGuard.watchedRoots,
                       [ProductIdentity.applicationSupportDirectory(), ProductIdentity.cachesDirectory()])
    }

    func testGuardWatchesPreferenceFilesNamedAfterATestSuite() {
        XCTAssertEqual(RealStorageGuard.preferencesDirectory.path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences").path)
        for name in ["SigningBatchTests.0D5E3F0A-7C44-4F7B-9A57-8E8C21B8C0A1.plist",
                     "EZZKProductionPolicyTests-0D5E3F0A-7C44-4F7B-9A57-8E8C21B8C0A1.plist",
                     "MemoryUserDefaultsTests-0D5E3F0A-7C44-4F7B-9A57-8E8C21B8C0A1.plist"] {
            XCTAssertTrue(RealStorageGuard.isTestSuitePreferenceFile(name), name)
        }
        for name in ["app.slovensko.chevron7.plist", "com.apple.dt.xctest.tool.plist", "com.apple.finder.plist",
                     "SigningBatchTests.plist.lockfile", "Tests.plist"] {
            XCTAssertFalse(RealStorageGuard.isTestSuitePreferenceFile(name), name)
        }
    }
}
