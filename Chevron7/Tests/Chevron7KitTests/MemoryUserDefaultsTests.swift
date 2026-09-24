// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7TestSupport
import Foundation
import XCTest

/// `MemoryUserDefaults` must keep what the code under test writes, through the typed
/// accessors it actually calls, without ever creating a preference file.
final class MemoryUserDefaultsTests: XCTestCase {
    func testTypedAccessorsRoundTripThroughMemory() {
        let defaults = MemoryUserDefaults()
        XCTAssertFalse(defaults.bool(forKey: "flag"))
        XCTAssertNil(defaults.data(forKey: "data"))

        defaults.set(true, forKey: "flag")
        defaults.set(Data([1, 2, 3]), forKey: "data")
        defaults.set(7, forKey: "count")
        defaults.set("text", forKey: "string")

        XCTAssertTrue(defaults.bool(forKey: "flag"))
        XCTAssertEqual(defaults.data(forKey: "data"), Data([1, 2, 3]))
        XCTAssertEqual(defaults.integer(forKey: "count"), 7)
        XCTAssertEqual(defaults.string(forKey: "string"), "text")

        defaults.removeObject(forKey: "data")
        XCTAssertNil(defaults.data(forKey: "data"))
    }

    func testInstancesDoNotShareValuesWithEachOtherOrStandard() {
        let first = MemoryUserDefaults()
        let second = MemoryUserDefaults()
        let key = "MemoryUserDefaultsTests.\(UUID().uuidString)"

        first.set(true, forKey: key)

        XCTAssertTrue(first.bool(forKey: key))
        XCTAssertFalse(second.bool(forKey: key))
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertNotEqual(first.suiteName, second.suiteName)
    }

    func testWritingCreatesNoPreferenceFile() {
        let defaults = MemoryUserDefaults()
        defaults.set(true, forKey: "flag")
        defaults.set(Data([1]), forKey: "data")

        XCTAssertTrue(RealStorageGuard.isTestSuitePreferenceFile("\(defaults.suiteName).plist"))
        let file = RealStorageGuard.preferencesDirectory.appendingPathComponent("\(defaults.suiteName).plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
