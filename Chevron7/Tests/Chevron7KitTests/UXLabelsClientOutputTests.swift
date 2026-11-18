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

    /// A one-PDF row's fingerprint covers only the first revision, so the label says how much of
    /// the file a reader hashes; every other row keeps the plain label.
    func testFingerprintLabelNamesTheFirstRevisionOfAOnePDF() {
        XCTAssertEqual(UXLabels.fingerprintLabel(clientOutput: .singlePDF, revisionOneLength: 48213),
                       "SHA-256 prvej revízie (prvých 48213 bajtov)")
        XCTAssertEqual(UXLabels.fingerprintLabel(clientOutput: .asicContainer, revisionOneLength: nil), "SHA-256 odtlačok")
        XCTAssertEqual(UXLabels.fingerprintLabel(clientOutput: nil, revisionOneLength: nil), "SHA-256 odtlačok")
        XCTAssertEqual(UXLabels.fingerprintLabel(clientOutput: .singlePDF, revisionOneLength: nil), "SHA-256 odtlačok",
                       "without the length a reader could not cut the file")
    }
}
