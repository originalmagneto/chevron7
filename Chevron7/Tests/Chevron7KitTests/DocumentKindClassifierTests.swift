// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import PDFKit
import XCTest
@testable import Chevron7Kit

final class DocumentKindClassifierTests: XCTestCase {
    func testEachKind() {
        XCTAssertEqual(DocumentKindClassifier.suggestKind(firstPageText: "Kúpna zmluva na byt"), "Zmluva")
        XCTAssertEqual(DocumentKindClassifier.suggestKind(firstPageText: "PLNÁ MOC na zastupovanie"), "Plná moc")
        XCTAssertEqual(DocumentKindClassifier.suggestKind(firstPageText: "Rozsudok Okresného súdu"), "Rozsudok")
        XCTAssertEqual(DocumentKindClassifier.suggestKind(firstPageText: "Rozhodnutie o povolení"), "Rozhodnutie")
        XCTAssertEqual(DocumentKindClassifier.suggestKind(firstPageText: "Osvedčenie o pravosti podpisu"), "Osvedčenie")
    }

    func testDiacriticsAndCaseDoNotMatter() {
        XCTAssertEqual(DocumentKindClassifier.suggestKind(firstPageText: "KUPNA ZMLUVA"), "Zmluva")
        XCTAssertEqual(DocumentKindClassifier.suggestKind(firstPageText: "rozsudok"), "Rozsudok")
    }

    func testSpecificBeatsGeneric() {
        // Both words present: the judgment wins over the generic contract mention.
        XCTAssertEqual(
            DocumentKindClassifier.suggestKind(firstPageText: "Rozsudok, ktorým sa zamieta návrh zo zmluvy"),
            "Rozsudok")
    }

    func testSilenceWithoutSignal() {
        XCTAssertNil(DocumentKindClassifier.suggestKind(firstPageText: nil))
        XCTAssertNil(DocumentKindClassifier.suggestKind(firstPageText: ""))
        XCTAssertNil(DocumentKindClassifier.suggestKind(firstPageText: "Ukazkova zapisnica bez klucovych slov"))
    }

    /// A rendered page has no text layer by construction, so this exercises
    /// the scan path: render, accurate OCR, classify.
    func testScanPathFindsKindThroughOcr() async throws {
        let data = TestPDFBuilder.build(pages: [(
            size: CGSize(width: 600, height: 800),
            draw: TestPDFBuilder.text("Kúpna zmluva na byt", at: CGPoint(x: 50, y: 700), size: 28)
        )])
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = await DocumentKindClassifier.recognizedFirstPageText(in: document)
        XCTAssertEqual(DocumentKindClassifier.suggestKind(firstPageText: text), "Zmluva")
    }
}
