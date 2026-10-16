// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import XCTest
import Chevron7TestSupport
@testable import Chevron7Kit

final class QualifiedValidationReportTests: XCTestCase {
    private let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x43, count: 100)

    private func original(indication: String = "TOTAL_PASSED") throws -> ElectronicOriginal {
        var signature = E2EEvidenceFixtures.Signature()
        signature.signedRevisionLength = pdf.count
        signature.indication = indication
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [signature]))
        return try ElectronicOriginal.make(sourceName: "zmluva.pdf", sourceData: pdf, evidence: evidence)
    }

    /// The evidence of the report file itself: one seal, by default from a validation service.
    private func sealEvidence(types: [String] = [QualifiedValidationReport.validationServiceType],
                              indication: String = "TOTAL_PASSED",
                              signingTime: String = "2026-10-16T09:00:00Z") throws -> ConversionEvidence {
        var seal = E2EEvidenceFixtures.Signature()
        seal.id = "SEAL"
        seal.signer = "Qualified validation service for QES"
        seal.qualification = "QESEAL"
        seal.trustServiceTypes = types
        seal.indication = indication
        seal.signingTime = signingTime
        seal.timestamps = []
        return try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [seal], pdf: nil))
    }

    /// A report in the shape of Disig's `XadesXml` output (namespace 2022/06/10).
    private func disigReport(contentHash: Data, signatureValue: Data, verdict: String = "VALID") -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <ValidationReport xmlns="http://www.disig.sk/ValidationReport/2022/06/10"><ValidationResponses><ValidationResponse>
        <OriginalDocument><Name>zmluva.pdf</Name><ContentHash><Oid>2.16.840.1.101.3.4.2.1</Oid><Value>\(contentHash.base64EncodedString())</Value></ContentHash></OriginalDocument>
        <Signatures><ESSignatureValidationDetail><SignatureId><SignatureValue>\(signatureValue.base64EncodedString())</SignatureValue></SignatureId>
        <AdESSignatureValidationDetail><Signature><IntegrityValid>true</IntegrityValid><ValidationResult><Type>\(verdict)</Type></ValidationResult></Signature></AdESSignatureValidationDetail>
        </ESSignatureValidationDetail></Signatures></ValidationResponse></ValidationResponses></ValidationReport>
        """.utf8)
    }

    func testDisigXmlReportBindsByContentHash() throws {
        let original = try original()
        let report = disigReport(contentHash: Data(SHA256.hash(data: pdf)), signatureValue: Data("other".utf8))
        let accepted = try QualifiedValidationReport.accept(reportData: report, fileName: "report.xml",
                                                            reportEvidence: try sealEvidence(), original: original)
        XCTAssertEqual(accepted.binding, .matched)
        XCTAssertEqual(accepted.fileExtension, "xml")
    }

    func testReportForAnotherDocumentIsRefused() throws {
        let report = disigReport(contentHash: Data(SHA256.hash(data: Data("other".utf8))), signatureValue: Data("x".utf8))
        XCTAssertThrowsError(try QualifiedValidationReport.accept(reportData: report, fileName: "report.xml",
                                                                  reportEvidence: try sealEvidence(),
                                                                  original: try original())) {
            XCTAssertEqual($0 as? QualifiedValidationReportError, .reportForAnotherDocument)
        }
    }

    func testSealFromOrdinaryCertificateIsRefused() throws {
        let report = disigReport(contentHash: Data(SHA256.hash(data: pdf)), signatureValue: Data("x".utf8))
        XCTAssertThrowsError(try QualifiedValidationReport.accept(
            reportData: report, fileName: "report.xml",
            reportEvidence: try sealEvidence(types: ["http://uri.etsi.org/TrstSvc/Svctype/CA/QC"]),
            original: try original())) { error in
            guard case .notAValidationService = error as? QualifiedValidationReportError else {
                return XCTFail("expected notAValidationService, got \(error)")
            }
        }
    }

    func testInvalidSealIsRefused() throws {
        let report = disigReport(contentHash: Data(SHA256.hash(data: pdf)), signatureValue: Data("x".utf8))
        XCTAssertThrowsError(try QualifiedValidationReport.accept(
            reportData: report, fileName: "report.xml",
            reportEvidence: try sealEvidence(indication: "TOTAL_FAILED"), original: try original())) {
            XCTAssertEqual($0 as? QualifiedValidationReportError, .sealInvalid)
        }
    }

    func testReportOlderThanTheLastSignatureIsRefused() throws {
        let report = disigReport(contentHash: Data(SHA256.hash(data: pdf)), signatureValue: Data("x".utf8))
        XCTAssertThrowsError(try QualifiedValidationReport.accept(
            reportData: report, fileName: "report.xml",
            reportEvidence: try sealEvidence(signingTime: "2026-10-01T00:00:00Z"), original: try original())) {
            XCTAssertEqual($0 as? QualifiedValidationReportError, .validatedBeforeLastSignature)
        }
    }

    func testPdfReportNeedsConfirmation() throws {
        let accepted = try QualifiedValidationReport.accept(reportData: Data("%PDF-1.7 sealed".utf8), fileName: "protokol.pdf",
                                                            reportEvidence: try sealEvidence(), original: try original())
        XCTAssertEqual(accepted.binding, .needsConfirmation)
    }

    func testMismatchingIndicationIsRefused() throws {
        let original = try original()
        let report = disigReport(contentHash: Data(SHA256.hash(data: pdf)),
                                 signatureValue: original.authorizations[0].signatureValue, verdict: "INVALID")
        XCTAssertThrowsError(try QualifiedValidationReport.accept(reportData: report, fileName: "report.xml",
                                                                  reportEvidence: try sealEvidence(), original: original)) {
            XCTAssertEqual($0 as? QualifiedValidationReportError, .indicationMismatch(signer: "Ján Klient"))
        }
    }

    func testMatchingIndicationIsAccepted() throws {
        let original = try original()
        let report = disigReport(contentHash: Data("unrelated".utf8),
                                 signatureValue: original.authorizations[0].signatureValue, verdict: "VALID")
        XCTAssertEqual(try QualifiedValidationReport.accept(reportData: report, fileName: "report.xml",
                                                            reportEvidence: try sealEvidence(), original: original).binding,
                       .matched)
    }

    func testServicesDecodeFromSettingsWithoutKey() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.qualifiedValidationServices, [])
        var changed = settings
        changed.qualifiedValidationServices = [QualifiedValidationService(name: "Disig QESV", provider: "Disig, a.s.",
                                                                          portalURL: URL(string: "https://eidas.disig.sk"))]
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(roundTrip.qualifiedValidationServices, changed.qualifiedValidationServices)
    }
}
