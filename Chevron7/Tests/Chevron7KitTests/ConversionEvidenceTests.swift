// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7TestSupport
@testable import Chevron7Kit

final class ConversionEvidenceTests: XCTestCase {
    func testDecodesPadesEvidence() throws {
        var signature = E2EEvidenceFixtures.Signature()
        signature.signedRevisionLength = 4096
        signature.mandate = "1042 OPRÁVNENIE 1042"
        signature.policies = [["oid": "1.3.158.36061701.1.1.1042", "explicitText": "OPRÁVNENIE 1042"]]
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [signature]))

        XCTAssertEqual(evidence.dssVersion, "6.4")
        XCTAssertEqual(evidence.validationTime, ISO8601DateFormatter().date(from: E2EEvidenceFixtures.validationTime))
        XCTAssertEqual(evidence.tree.signatures.map(\.id), ["S-1"])
        XCTAssertEqual(evidence.tree.signatures.first?.state, .valid)
        let facts = try XCTUnwrap(evidence.signature(id: "S-1"))
        XCTAssertEqual(facts.signedRevisionLength, 4096)
        XCTAssertEqual(facts.signatureValue, Data("signature-value-1".utf8))
        XCTAssertEqual(facts.mandate, "1042 OPRÁVNENIE 1042")
        XCTAssertEqual(facts.policies.first?.explicitText, "OPRÁVNENIE 1042")
        XCTAssertEqual(facts.timestamps.first?.producerCommonName, "Sectigo Qualified Time Stamping Signer #2")
        XCTAssertEqual(facts.timestamps.first?.qualification, "QTSA")
        XCTAssertFalse(evidence.etsiReport.isEmpty)
        XCTAssertEqual(evidence.pdf?.pdfaCompliant, false)
    }

    func testDecodesTrustedListUnavailable() throws {
        var signature = E2EEvidenceFixtures.Signature()
        signature.indication = "INDETERMINATE"
        signature.trustedListUnavailable = true
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [signature]))
        XCTAssertEqual(evidence.signatures.first?.trustedListUnavailable, true)
        XCTAssertEqual(evidence.tree.signatures.first?.state, .indeterminate)
    }

    func testMissingEvidenceIsMalformed() {
        XCTAssertThrowsError(try ConversionEvidence.decode(payloadJSON: Data(#"{"signatures":[]}"#.utf8)))
    }

    func testRunnerMapsExitCodeThreeToNotCompliant() {
        let runner = PdfaFromSignedRunner(launch: { _ in (3, "font a\nfont b\n") })
        XCTAssertThrowsError(try runner.convert(Data("%PDF".utf8), title: "Zmluva", raster: false)) { error in
            XCTAssertEqual(error as? PdfaFromSignedRunner.Failure, .notCompliant(["font a", "font b"]))
        }
    }

    func testRunnerPassesRasterFlagAndReadsOutput() throws {
        let runner = PdfaFromSignedRunner(launch: { arguments in
            XCTAssertEqual(arguments.first, "digital.slovensko.autogram.core.PdfaFromSigned")
            XCTAssertEqual(arguments.last, "--raster")
            try Data("%PDF-converted".utf8).write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        XCTAssertEqual(try runner.convert(Data("%PDF".utf8), title: "", raster: true), Data("%PDF-converted".utf8))
    }

    func testRunnerMapsUnreadableInput() {
        let runner = PdfaFromSignedRunner(launch: { _ in (2, "") })
        XCTAssertThrowsError(try runner.convert(Data("x".utf8), title: "Zmluva", raster: false)) { error in
            XCTAssertEqual(error as? PdfaFromSignedRunner.Failure, .unreadable)
        }
    }
}
