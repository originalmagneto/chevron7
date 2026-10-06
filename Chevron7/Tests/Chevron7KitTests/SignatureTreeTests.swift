// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class SignatureTreeTests: XCTestCase {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }

    func testDecodesContainerSignaturesAndNestedPdf() throws {
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"signatures":[{"id":"S-1","format":"XAdES_BASELINE_T","signerDisplayName":"Marián Čuprík",
          "valid":true,"indication":"TOTAL_PASSED","qualifiedTimestampValid":true,
          "signerCertificateQualification":"QESIG","timestamps":[{"id":"T-1","valid":true}],
          "documents":["report.pdf"]}],
         "documents":[
          {"name":"report.pdf","nested":{"kind":"PDF","signatures":[{"id":"S-1","format":"PAdES_BASELINE_T",
            "signerDisplayName":"Iný Podpisovateľ","valid":false,"indication":"TOTAL_FAILED","timestamps":[]}]}},
          {"name":"dolozka.xml.xdcf"},
          {"name":"deep.asice","nestedSkipped":"DEPTH_LIMIT"},
          {"name":"big.pdf","nestedSkipped":"TOO_LARGE"},
          {"name":"bad.pdf","nestedError":"NESTED_INSPECTION_FAILED"}]}
        """))

        XCTAssertEqual(tree.signatures.count, 1)
        let container = tree.signatures[0]
        XCTAssertEqual(container.state, .valid)
        XCTAssertEqual(container.coveredDocuments, ["report.pdf"])
        XCTAssertEqual(container.certificateQualification, "QESIG")
        XCTAssertTrue(container.hasQualifiedTimestamp)
        XCTAssertEqual(tree.documents.map(\.name), ["report.pdf", "dolozka.xml.xdcf", "deep.asice", "big.pdf", "bad.pdf"])
        guard case .signed(.pdf, let nested) = tree.documents[0].content else {
            return XCTFail("report.pdf should be a signed PDF")
        }
        XCTAssertEqual(nested.signatures.map(\.state), [.invalid])
        XCTAssertEqual(tree.documents[1].content, .plain)
        XCTAssertEqual(tree.documents[2].content, .skipped(.depthLimit))
        XCTAssertEqual(tree.documents[3].content, .skipped(.tooLarge))
        XCTAssertEqual(tree.documents[4].content, .failed)
    }

    func testStructuralTimestampIsNotQualified() throws {
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"signatures":[{"id":"S-1","valid":true,"indication":"INDETERMINATE","qualifiedTimestampValid":false,
          "timestamps":[{"id":"T-1","cryptographicIntegrity":true}]}]}
        """))

        XCTAssertEqual(tree.signatures[0].state, .indeterminate)
        XCTAssertFalse(tree.signatures[0].hasQualifiedTimestamp)
        XCTAssertTrue(tree.signatures[0].hasTimestamp)
    }

    func testReadsTheAuthorityAndTimeOfTheFirstIntactTimestamp() throws {
        // A phone signature carries the timestamp its own service added; the done
        // screen names that authority instead of the one chosen in Settings.
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"signatures":[{"id":"S-1","valid":true,"indication":"TOTAL_PASSED","qualifiedTimestampValid":true,
          "timestamps":[{"id":"T-0","valid":false,"producer":"Broken TSA","productionTime":"2026-10-06T17:40:00Z"},
                        {"id":"T-1","valid":true,"producer":"Mobile TSA Unit","productionTime":"2026-10-06T17:44:58Z"}]}]}
        """))

        XCTAssertEqual(tree.signatures[0].timestampAuthority, "Mobile TSA Unit")
        XCTAssertEqual(tree.signatures[0].timestampTime, ISO8601DateFormatter().date(from: "2026-10-06T17:44:58Z"))
    }

    func testNoIntactTimestampLeavesAuthorityEmpty() throws {
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"signatures":[{"id":"S-1","valid":true,"timestamps":[{"id":"T-1","valid":false,"producer":"Broken TSA"}]}]}
        """))

        XCTAssertNil(tree.signatures[0].timestampAuthority)
        XCTAssertNil(tree.signatures[0].timestampTime)
    }

    func testSameSignatureIdOnTwoLevelsStaysSeparate() throws {
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"signatures":[{"id":"S-1","valid":true,"indication":"TOTAL_PASSED","timestamps":[]}],
         "documents":[{"name":"a.pdf","nested":{"kind":"PDF","signatures":[
           {"id":"S-1","valid":false,"indication":"TOTAL_FAILED","timestamps":[]}]}}]}
        """))

        XCTAssertEqual(tree.signatures.map(\.state), [.valid])
        guard case .signed(_, let nested) = tree.documents[0].content else { return XCTFail() }
        XCTAssertEqual(nested.signatures.map(\.state), [.invalid])
        XCTAssertEqual(SignatureTreeSummary(tree: tree).invalid, 1)
        XCTAssertEqual(SignatureTreeSummary(tree: tree).valid, 1)
    }

    func testUnknownSkipReasonDecodesAsFailed() throws {
        let tree = SignatureTreeDecoder.tree(from: try payload("""
        {"documents":[{"name":"x.pdf","nestedSkipped":"SOMETHING_NEW"}]}
        """))

        XCTAssertEqual(tree.documents[0].content, .failed)
    }

    func testSummaryTakesTheWorstResultAndItsLocation() {
        let valid = DocumentSignatureInfo(id: "1", signerDisplayName: "A", state: .valid)
        let invalid = DocumentSignatureInfo(id: "2", signerDisplayName: "B", state: .invalid)
        let tree = SignatureTree(signatures: [valid], documents: [
            SignedDataObject(name: "report.pdf", content: .signed(.pdf, SignatureTree(signatures: [invalid]))),
            SignedDataObject(name: "bad.pdf", content: .failed),
            SignedDataObject(name: "deep.asice", content: .skipped(.depthLimit)),
            SignedDataObject(name: "dolozka.xml.xdcf", content: .plain)
        ])

        let summary = SignatureTreeSummary(tree: tree)

        XCTAssertEqual(summary.valid, 1)
        XCTAssertEqual(summary.invalid, 1)
        XCTAssertEqual(summary.indeterminate, 2)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.overall, .invalid)
        XCTAssertEqual(summary.worstLocation, "report.pdf")
    }

    func testSummaryOfAnEmptyTreeIsUnknown() {
        XCTAssertEqual(SignatureTreeSummary(tree: SignatureTree()).overall, .unknown)
        XCTAssertEqual(SignatureTreeSummary(tree: SignatureTree()).total, 0)
    }
}
