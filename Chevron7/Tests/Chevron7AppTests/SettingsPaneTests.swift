// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class SettingsPaneTests: XCTestCase {
    func testSidebarOrder() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), [
            "Profil advokáta", "EZZK", "Podpisovanie", "Mobil a eIdentita",
            "Prehliadač a Finder", "AI a učenie", "Všeobecné"])
    }

    func testStoredPaneWins() {
        XCTAssertEqual(SettingsPane.initial(stored: "ai", ezzkConnected: false), .ai)
    }

    func testFirstOpenShowsEZZKUntilConnected() {
        XCTAssertEqual(SettingsPane.initial(stored: "", ezzkConnected: false), .ezzk)
        XCTAssertEqual(SettingsPane.initial(stored: "", ezzkConnected: true), .profile)
    }

    func testUnknownStoredPaneFallsBack() {
        XCTAssertEqual(SettingsPane.initial(stored: "conversion", ezzkConnected: true), .profile)
    }
}
