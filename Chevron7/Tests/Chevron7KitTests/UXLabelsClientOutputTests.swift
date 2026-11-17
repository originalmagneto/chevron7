// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class UXLabelsClientOutputTests: XCTestCase {
    func testClientOutputLabels() {
        XCTAssertEqual(UXLabels.clientOutputLabel(.asicContainer), "Kontajner ASiC-E")
        XCTAssertEqual(UXLabels.clientOutputLabel(.singlePDF), "Jeden PDF s doložkou")
        XCTAssertNil(UXLabels.clientOutputLabel(nil))
    }
}
