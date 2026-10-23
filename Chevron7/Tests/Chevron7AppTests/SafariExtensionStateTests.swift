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

    /// The SDK marks the completion handler NS_SWIFT_UI_ACTOR, but SafariServices
    /// calls it on its XPC queue; a Swift closure of that type traps there (1.17.0
    /// crashed at launch of Settings, 2026-10-23). The test process carries no
    /// extension, so Safari answers with an error, on the same queue.
    func testReadingTheStateDoesNotTrapOnSafarisQueue() async {
        let status = await SafariExtensionState.current()
        XCTAssertEqual(status, .unknown)
    }

    /// Settings asks from the main actor.
    @MainActor
    func testReadingTheStateFromTheMainActorDoesNotTrap() async {
        let status = await SafariExtensionState.current()
        XCTAssertEqual(status, .unknown)
    }

    func testAsksForTheBundledExtension() {
        XCTAssertEqual(SafariExtensionState.identifier, "app.slovensko.chevron7.WebExtension")
    }
}
