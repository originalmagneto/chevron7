// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class SafariExtensionStateTests: XCTestCase {
    func testMapsSafarisAnswer() {
        XCTAssertEqual(SafariExtensionState.status(isEnabled: true), .enabled)
        XCTAssertEqual(SafariExtensionState.status(isEnabled: false), .disabled)
        // An error or no state: Safari did not say, which is not "off".
        XCTAssertEqual(SafariExtensionState.status(isEnabled: nil), .unknown)
    }

    func testAsksForTheBundledExtension() {
        XCTAssertEqual(SafariExtensionState.identifier, "app.slovensko.chevron7.WebExtension")
    }
}
