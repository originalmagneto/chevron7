// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class EZZKModeLabelTests: XCTestCase {
    func testLabelsAreUserFacing() {
        XCTAssertEqual(AppSettings.EZZKMode.demo.label, "Skúšobný režim (lokálne)")
        XCTAssertEqual(AppSettings.EZZKMode.test.label, "Testovacia evidencia")
        XCTAssertEqual(AppSettings.EZZKMode.production.label, "Ostrá evidencia")
    }

    func testRawValuesStayPersisted() {
        XCTAssertEqual(AppSettings.EZZKMode.allCases.map(\.rawValue), ["demo", "test", "production"])
    }
}
