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

    func testMultiFileReportMustNameEveryDocumentOrEverySignature() throws {
        let a = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: 50)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x50, count: 20)
        let c = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x43, count: 50)
        var outer = E2EEvidenceFixtures.Signature()
        outer.id = "C-1"
        outer.signatureValue = Data("container-value".utf8)
        var nested = E2EEvidenceFixtures.Signature()
        nested.id = "P-1"
        nested.signedRevisionLength = c.count
        nested.signatureValue = Data("pades-value".utf8)
        var objects = [E2EEvidenceFixtures.DataObject(name: "a.pdf", bytes: a),
                       E2EEvidenceFixtures.DataObject(name: "b.png", bytes: png),
                       E2EEvidenceFixtures.DataObject(name: "c.pdf", bytes: c)]
        objects[1].kind = "png"
        objects[2].nestedSignatures = [nested]
        for index in objects.indices { objects[index].coveredBy = ["C-1"] }
        let container = try ASiCEPackager().package(files: objects.map { .init(path: $0.name, data: $0.bytes) })
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 3
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [outer], pdf: facts, dataObjects: objects))
        let original = try ElectronicOriginal.make(sourceName: "spis.asice", sourceData: container, evidence: evidence)
        XCTAssertEqual(original.kind, .asicEMultiple)

        func hash(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }
        XCTAssertFalse(QualifiedValidationReport.names(original, in: "<r><h>\(hash(a))</h></r>"))
        XCTAssertTrue(QualifiedValidationReport.names(
            original, in: "<r><h>\(hash(a))</h><h>\(hash(png))</h><h>\(hash(c))</h></r>"))
        XCTAssertFalse(QualifiedValidationReport.names(
            original, in: "<r><s>\(outer.signatureValue.base64EncodedString())</s></r>"))
        XCTAssertTrue(QualifiedValidationReport.names(original, in: """
            <r><s>\(outer.signatureValue.base64EncodedString())</s><s>\(nested.signatureValue.base64EncodedString())</s></r>
            """))
        // A single-file original keeps the any-one-hash rule.
        XCTAssertTrue(QualifiedValidationReport.names(try self.original(), in: "<r>\(hash(pdf))</r>"))
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
