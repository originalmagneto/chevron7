// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

final class AsyncActionButtonTests: XCTestCase {
    func testLoadingWinsOverIneligibility() {
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: true, lastError: nil, canSign: false),
            .loading)
    }

    func testErrorWinsOverEligibility() {
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: false, lastError: "Zlyhalo.", canSign: true),
            .error("Zlyhalo."))
    }

    func testErrorStaysVisibleWithoutEligibility() {
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: false, lastError: "Zlyhalo.", canSign: false),
            .error("Zlyhalo."))
    }

    func testIdleAndDisabled() {
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: false, lastError: nil, canSign: true),
            .idle)
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: false, lastError: nil, canSign: false),
            .disabled)
    }

    func testRetryCycleIdleErrorLoadingError() {
        // The visual idle → error → retry → error path, as store state evolves:
        // sign() resets lastError and sets isSigning on retry, then fails again.
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: false, lastError: nil, canSign: true),
            .idle)
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: false, lastError: "Prvé zlyhanie.", canSign: true),
            .error("Prvé zlyhanie."))
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: true, lastError: nil, canSign: false),
            .loading)
        XCTAssertEqual(
            AsyncActionPhase.derive(isSigning: false, lastError: "Druhé zlyhanie.", canSign: true),
            .error("Druhé zlyhanie."))
    }
}
