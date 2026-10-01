// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7TestSupport
import Foundation
import XCTest
@testable import Chevron7Kit

/// `AppSettings` loads from and saves to the `UserDefaults` it is given, so tests can keep
/// settings in memory instead of the test runner's `UserDefaults.standard`.
final class AppSettingsPersistenceTests: XCTestCase {
    func testSaveAndLoadUseTheGivenDefaultsOnly() {
        let defaults = MemoryUserDefaults()
        let standardBefore = UserDefaults.standard.data(forKey: AppSettings.storageKey)
        var settings = AppSettings()
        settings.ezzkICO = "12345678"

        settings.save(to: defaults)

        XCTAssertEqual(AppSettings.load(defaults: defaults).ezzkICO, "12345678")
        XCTAssertEqual(AppSettings.load(defaults: MemoryUserDefaults()).ezzkICO, AppSettings.standard.ezzkICO)
        XCTAssertEqual(UserDefaults.standard.data(forKey: AppSettings.storageKey), standardBefore)
    }
}
