// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

/// The engine sniffs the payload type from the source filename, so browser
/// TXT/PNG must keep their real name instead of `document.pdf`.
final class EngineBridgePlainSourceTests: XCTestCase {
    private func signingRequest(filename: String?, format: SigningOutputFormat = .attachedASIC) -> SigningRequest {
        SigningRequest(pdfData: Data(), identityID: "id", includeTimestamp: false,
                       outputFormat: format, filename: filename)
    }

    func testTxtAndPngKeepTheirName() {
        XCTAssertEqual(EngineBridgeSigningProvider.plainSourceName(
            for: signingRequest(filename: "poznamka.txt")), "poznamka.txt")
        XCTAssertEqual(EngineBridgeSigningProvider.plainSourceName(
            for: signingRequest(filename: "obrazok.png")), "obrazok.png")
    }

    func testPdfXmlAndMissingNamesAreNotPlain() {
        XCTAssertNil(EngineBridgeSigningProvider.plainSourceName(
            for: signingRequest(filename: "dokument.pdf")))
        XCTAssertNil(EngineBridgeSigningProvider.plainSourceName(
            for: signingRequest(filename: "formular.xml")))
        XCTAssertNil(EngineBridgeSigningProvider.plainSourceName(
            for: signingRequest(filename: nil)))
    }
}
