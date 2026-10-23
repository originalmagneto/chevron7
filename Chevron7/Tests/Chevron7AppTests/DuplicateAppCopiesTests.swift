// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class DuplicateAppCopiesTests: XCTestCase {
    private let running = "/Applications/Chevron7.app"

    private func candidates(_ registered: [String], readOnly: Set<String> = [],
                            missing: Set<String> = []) -> [String] {
        DuplicateAppCopies.candidatePaths(registered: registered, runningPath: running,
                                          exists: { !missing.contains($0) },
                                          isOnReadOnlyVolume: { readOnly.contains($0) })
    }

    func testOffersACopyKeptBesideTheRunningApp() {
        // Finder's "Keep Both" over an installed app (2026-10-23).
        XCTAssertEqual(candidates([running, "/Applications/Chevron7 2.app"]), ["/Applications/Chevron7 2.app"])
    }

    func testIgnoresTheRunningAppAndRepeats() {
        XCTAssertEqual(candidates([running, "/Applications/Chevron7.app/", "/Users/a/Apps/Chevron7.app",
                                   "/Users/a/Apps/Chevron7.app"]),
                       ["/Users/a/Apps/Chevron7.app"])
    }

    func testIgnoresCopiesTheTrashCannotOrNeedNotTake() {
        let paths = [
            "/Users/a/.Trash/Chevron7 2.app",
            "/Users/a/Projects/Chevron7/.build/out/Products/Debug/Chevron7.app",
            "/Users/a/Library/Developer/Xcode/DerivedData/x/Build/Products/Debug/Chevron7.app",
            "/private/var/folders/x/AppTranslocation/ABC/d/Chevron7.app",
            "/Users/a/Library/Caches/app.slovensko.chevron7/org.sparkle-project.Sparkle/Installation/Chevron7.app",
            "/Volumes/Chevron7/Chevron7.app",
            "/Applications/Gone.app",
        ]
        XCTAssertEqual(candidates(paths, readOnly: ["/Volumes/Chevron7/Chevron7.app"], missing: ["/Applications/Gone.app"]),
                       [])
    }

    func testDoesNotScanFromABuildADiskImageOrATranslocatedCopy() {
        XCTAssertTrue(DuplicateAppCopies.scansFrom(runningPath: running, isOnReadOnlyVolume: false))
        XCTAssertFalse(DuplicateAppCopies.scansFrom(runningPath: "/Volumes/Chevron7/Chevron7.app", isOnReadOnlyVolume: true))
        XCTAssertFalse(DuplicateAppCopies.scansFrom(
            runningPath: "/Users/a/Projects/Chevron7/.build/out/Products/Debug/Chevron7.app", isOnReadOnlyVolume: false))
        XCTAssertFalse(DuplicateAppCopies.scansFrom(
            runningPath: "/private/var/folders/x/AppTranslocation/ABC/d/Chevron7.app", isOnReadOnlyVolume: false))
    }

    func testComparesVersionsNumerically() {
        XCTAssertFalse(DuplicateAppCopies.isNewer("1.5.4", than: "1.15.1"))
        XCTAssertTrue(DuplicateAppCopies.isNewer("1.15.1", than: "1.5.4"))
        XCTAssertFalse(DuplicateAppCopies.isNewer("1.15.1", than: "1.15.1"))
        XCTAssertFalse(DuplicateAppCopies.isNewer(nil, than: "1.15.1"))
        XCTAssertFalse(DuplicateAppCopies.isNewer("2.0.0", than: nil))
    }

    func testReadsTheVersionFromInfoPlist() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Chevron7.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try (["CFBundleShortVersionString": "1.5.4"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(DuplicateAppCopies.shortVersion(of: app), "1.5.4")
        XCTAssertNil(DuplicateAppCopies.shortVersion(of: app.deletingLastPathComponent()))
    }
}
