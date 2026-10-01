// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App
import Chevron7Kit

final class SignatureTreePresentationTests: XCTestCase {
    private func signature(_ state: DocumentSignatureInfo.State) -> DocumentSignatureInfo {
        DocumentSignatureInfo(id: UUID().uuidString, signerDisplayName: "A", state: state)
    }

    func testSignatureCountUsesSlovakPlurals() {
        XCTAssertEqual(SignatureTreePresentation.signatureCount(1), "1 podpis")
        XCTAssertEqual(SignatureTreePresentation.signatureCount(3), "3 podpisy")
        XCTAssertEqual(SignatureTreePresentation.signatureCount(5), "5 podpisov")
    }

    func testSummaryNamesTheWorstLocation() {
        let tree = SignatureTree(signatures: [signature(.valid)], documents: [
            SignedDataObject(name: "report.pdf", content: .signed(.pdf, SignatureTree(signatures: [signature(.invalid)])))
        ])

        XCTAssertEqual(SignatureTreePresentation.summaryText(SignatureTreeSummary(tree: tree)),
                       "2 podpisy: platné 1, neplatné 1 (v report.pdf)")
    }

    func testSummaryMentionsUnverifiedDocuments() {
        let tree = SignatureTree(signatures: [signature(.valid)], documents: [
            SignedDataObject(name: "deep.asice", content: .skipped(.depthLimit))
        ])

        XCTAssertEqual(SignatureTreePresentation.summaryText(SignatureTreeSummary(tree: tree)),
                       "1 podpis: platné 1, neoverené súbory 1 (v deep.asice)")
    }

    func testPhaseTexts() {
        XCTAssertEqual(SignatureTreePresentation.phaseText(.structural),
                       "Overuje sa voči dôveryhodným zoznamom…")
        XCTAssertEqual(SignatureTreePresentation.phaseText(.validated),
                       "Informatívne overenie voči dôveryhodným zoznamom EÚ")
        XCTAssertEqual(SignatureTreePresentation.phaseText(.validationUnavailable("offline")), "offline")
        XCTAssertNil(SignatureTreePresentation.phaseText(.idle))
    }

    func testFailedPhaseText() {
        XCTAssertEqual(SignatureTreePresentation.phaseText(.failed("x")), "Podpisy sa nepodarilo skontrolovať")
    }
}
