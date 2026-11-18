// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class EngineDiagnosticTextTests: XCTestCase {
    func testKeepsRuleTextAndDropsPaths() {
        let text = """
        6.2.11.4.1-1: The font programs for all fonts used for rendering /Type /Font shall be embedded (PDF/A-3b)
        ISO 19005-3:2012/6.2.11 failed in /private/var/folders/x1/T/pdf-clause-check-1A2B/source.pdf

        file:///Users/advokat/Documents/Zmluva.pdf and ~/Desktop/klient.pdf
        """
        XCTAssertEqual(EngineDiagnosticText.loggableLines(text), [
            "6.2.11.4.1-1: The font programs for all fonts used for rendering /Type /Font shall be embedded (PDF/A-3b)",
            "ISO 19005-3:2012/6.2.11 failed in <cesta>",
            "<cesta> and <cesta>"
        ])
    }

    func testEmptyTextHasNoLines() {
        XCTAssertEqual(EngineDiagnosticText.loggableLines(""), [])
        XCTAssertEqual(EngineDiagnosticText.loggableLines("\n  \n"), [])
    }

    /// The engine's `file.failed` for PDFA_INVALID carries veraPDF's rules in `message`.
    func testPdfaFailureDetailsReadTheMessageOnlyForPdfaInvalid() {
        let payload: [String: JSONValue] = ["code": .string("PDFA_INVALID"),
                                            "message": .string("rule 1\nrule 2 in /tmp/x/source.pdf")]
        XCTAssertEqual(AutogramCLIEngine.pdfaFailureDetails(in: payload), ["rule 1", "rule 2 in <cesta>"])
        XCTAssertEqual(AutogramCLIEngine.pdfaFailureDetails(in: ["code": .string("SIGNING_FAILED"),
                                                                 "message": .string("rule 1")]), [])
        XCTAssertEqual(AutogramCLIEngine.pdfaFailureDetails(in: ["code": .string("PDFA_INVALID")]), [])
    }
}
