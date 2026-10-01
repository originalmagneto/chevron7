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

    func testNeedsAttentionForSignedTrees() {
        let invalid = SignedDataObject.Content.signed(.pdf, SignatureTree(signatures: [signature(.invalid)]))
        let valid = SignedDataObject.Content.signed(.pdf, SignatureTree(signatures: [signature(.valid)]))
        XCTAssertTrue(SignatureTreePresentation.needsAttention(invalid))
        XCTAssertFalse(SignatureTreePresentation.needsAttention(valid))
    }

    func testNeedsAttentionForUnverifiedAndPlainContent() {
        XCTAssertTrue(SignatureTreePresentation.needsAttention(.skipped(.depthLimit)))
        XCTAssertTrue(SignatureTreePresentation.needsAttention(.skipped(.tooLarge)))
        XCTAssertTrue(SignatureTreePresentation.needsAttention(.failed))
        XCTAssertFalse(SignatureTreePresentation.needsAttention(.plain))
    }

    func testNeedsAttentionForNestedContainerWithUnverifiedEntry() {
        let inner = SignatureTree(signatures: [signature(.valid)], documents: [
            SignedDataObject(name: "big.pdf", content: .skipped(.tooLarge))
        ])
        XCTAssertTrue(SignatureTreePresentation.needsAttention(.signed(.asic, inner)))
    }

    func testHasUnverifiedEntries() {
        let mixed = SignatureTree(signatures: [signature(.valid)], documents: [
            SignedDataObject(name: "a.xml", content: .plain),
            SignedDataObject(name: "b.pdf", content: .failed)
        ])
        let clean = SignatureTree(signatures: [signature(.valid)], documents: [
            SignedDataObject(name: "a.xml", content: .plain)
        ])
        XCTAssertTrue(SignatureTreePresentation.hasUnverifiedEntries(mixed))
        XCTAssertFalse(SignatureTreePresentation.hasUnverifiedEntries(clean))
    }

    func testQualificationLabel() {
        XCTAssertEqual(SignatureTreePresentation.qualificationLabel("QESIG"), "KEP")
        XCTAssertEqual(SignatureTreePresentation.qualificationLabel("QESEAL"), "Kvalifikovaná pečať")
        XCTAssertNil(SignatureTreePresentation.qualificationLabel(nil))
        XCTAssertEqual(SignatureTreePresentation.qualificationLabel("ADESIG_QC"), "Nekvalifikovaný")
        XCTAssertEqual(SignatureTreePresentation.qualificationLabel("ADESIG"), "Nekvalifikovaný")
        XCTAssertEqual(SignatureTreePresentation.qualificationLabel("NA"), "Nekvalifikovaný")
        XCTAssertEqual(SignatureTreePresentation.qualificationLabel("ADESEAL_QC"), "Nekvalifikovaný")
        XCTAssertEqual(SignatureTreePresentation.qualificationLabel("NOT_ADES"), "Nekvalifikovaný")
        XCTAssertEqual(SignatureTreePresentation.qualificationLabel("NOT_ADES_QC_QSCD"), "Nekvalifikovaný")
    }

    /// DSS reached no negative conclusion for these (typically revocation or trust data was
    /// unavailable), so the signature must not be called unqualified.
    func testUndeterminedQualificationIsNotCalledUnqualified() {
        for name in ["INDETERMINATE_QESIG", "INDETERMINATE_QESEAL", "INDETERMINATE_ADESIG_QC",
                     "INDETERMINATE_UNKNOWN_QC_QSCD", "INDETERMINATE_ADESIG", "UNKNOWN_QC",
                     "UNKNOWN_QC_QSCD", "UNKNOWN"] {
            XCTAssertEqual(SignatureTreePresentation.qualificationLabel(name), "Kvalifikácia neurčená", name)
        }
    }
}
