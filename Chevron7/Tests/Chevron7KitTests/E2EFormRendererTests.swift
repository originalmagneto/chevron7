// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import XCTest
import Chevron7TestSupport
@testable import Chevron7Kit

final class E2EFormRendererTests: XCTestCase {
    private let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x42, count: 300)
    private let time = ISO8601DateFormatter().date(from: "2026-10-16T10:15:42Z")!

    private func attestation() -> AttestationData {
        var data = AttestationData(
            originalDocumentName: "zmluva.pdf",
            numberOfSheets: 1,
            nonEmptyPageCount: 1,
            paperSizeBreakdown: [],
            newDocumentName: "zmluva.pdf",
            conversionExecutionDateTime: time,
            evidenceNumber: "1563-261016-7",
            performingPerson: AdvocateProfile(fullName: "Mgr. Marián Čuprík", position: "advokát",
                                              registrationNumber: "1042", ico: "42249180",
                                              officeName: "Advokátska kancelária CHZ"))
        data.originalDocumentTypeLabel = "zmluva o pôžičke"
        return data
    }

    private func original(_ signatures: [E2EEvidenceFixtures.Signature],
                          pdf facts: E2EEvidenceFixtures.PDF = .init()) throws -> ElectronicOriginal {
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: signatures, pdf: facts))
        return try ElectronicOriginal.make(sourceName: "zmluva.pdf", sourceData: pdf, evidence: evidence)
    }

    private func signature(_ id: String = "S-1", revision: Int? = nil) -> E2EEvidenceFixtures.Signature {
        var signature = E2EEvidenceFixtures.Signature()
        signature.id = id
        signature.signedRevisionLength = revision ?? pdf.count
        signature.mandate = "1042 OPRÁVNENIE 1042"
        signature.mandants = ["MANDANT Kancelária & synovia s.r.o."]
        return signature
    }

    private func model(_ original: ElectronicOriginal, newDocument: Data? = nil, qualified: Data? = nil) throws -> E2EFormModel {
        try E2EFormModel.make(original: original, attestation: attestation(), newDocumentName: "zmluva.pdf",
                              newDocumentData: newDocument ?? Data("%PDF-converted".utf8), usedDevice: "Chevron7 1.5.0",
                              qualifiedReport: qualified)
    }

    func testClauseForOneSignatureValidates() throws {
        let model = try model(try original([signature()]))
        XCTAssertNoThrow(try E2EDeliveryBuilder().clause(model))
        let xml = ConversionCertificateE2ERenderer().render(model)
        XCTAssertTrue(xml.contains("<ConversionRecordEvidenceNumber>https://data.gov.sk/id/egov/conversion-record/1563-261016-7</ConversionRecordEvidenceNumber>"))
        XCTAssertTrue(xml.contains("<ItemCode>2</ItemCode><ItemName Language=\"sk\">Kvalifikovaný elektronický podpis</ItemName>"))
        XCTAssertTrue(xml.contains("<Mandate>1042 OPRÁVNENIE 1042</Mandate>"))
        XCTAssertTrue(xml.contains("<Mandant>MANDANT Kancelária &amp; synovia s.r.o.</Mandant>"))
    }

    func testRecordForOneSignatureValidates() throws {
        let model = try model(try original([signature()]))
        let delivery = try E2EDeliveryBuilder().record(model)
        XCTAssertEqual(delivery.entryName, "1563-261016-7.record.xml.xdcf")
        XCTAssertEqual(delivery.containerName, "1563-261016-7.record.asice")
        XCTAssertTrue(delivery.recordXML.contains("<OriginalDocumentType>zmluva o pôžičke</OriginalDocumentType>"))
        XCTAssertTrue(delivery.recordXML.contains("<ConversionRecordEvidenceNumber>1563-261016-7</ConversionRecordEvidenceNumber>"))
        XCTAssertTrue(delivery.recordXML.contains("<UsedDevice>Chevron7 1.5.0</UsedDevice>"))
        XCTAssertTrue(delivery.recordXML.contains("<ElectronicSignature>\(Data("signature-value-1".utf8).base64EncodedString())</ElectronicSignature>"))
        let xdc = String(decoding: delivery.recordXDCF, as: UTF8.self)
        XCTAssertTrue(xdc.contains("Identifier=\"\(OfficialForm.recordE2E_1_0.identifier)\""))
    }

    func testTwoRevisionClauseListsBothOriginalsAndLinksAuthorizations() throws {
        let model = try model(try original([signature("S-1", revision: 150), signature("S-2")]))
        XCTAssertNoThrow(try E2EDeliveryBuilder().clause(model))
        XCTAssertNoThrow(try E2EDeliveryBuilder().record(model))
        let xml = ConversionCertificateE2ERenderer().render(model)
        XCTAssertTrue(xml.contains("<OriginalDocumentName>zmluva-1</OriginalDocumentName>"))
        XCTAssertTrue(xml.contains("<OriginalDocumentName>zmluva-2</OriginalDocumentName>"))
        XCTAssertTrue(xml.contains("<AuthorizedDocumentName>zmluva-1</AuthorizedDocumentName>"))
        XCTAssertTrue(xml.contains("<AuthorizedDocumentName>zmluva-2</AuthorizedDocumentName>"))
    }

    func testRecordTimesHaveNoFractionsAndBratislavaOffset() throws {
        let xml = ConversionRecordE2ERenderer().render(try model(try original([signature()])))
        let pattern = try NSRegularExpression(pattern: "<(\\w*(?:Time|Created))>([^<]*)</")
        let matches = pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        XCTAssertGreaterThanOrEqual(matches.count, 5)
        for match in matches {
            let value = String(xml[Range(match.range(at: 2), in: xml)!])
            XCTAssertNotNil(value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\+01:00|\+02:00)$"#, options: .regularExpression), value)
        }
    }

    func testKeptDocumentRepeatsOriginalValues() throws {
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 2
        facts.pdfaCompliant = true
        let original = try original([signature()], pdf: facts)
        let model = try model(original, newDocument: pdf)
        XCTAssertEqual(model.newDocument.sha256, original.documents[0].sha256)
        XCTAssertEqual(model.newDocument.format, E2ECodelists.pdfa2Format)
        XCTAssertNoThrow(try E2EDeliveryBuilder().clause(model))
    }

    func testPdfa3UsesInyWithOther() throws {
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 3
        facts.pdfaCompliant = true
        let model = try model(try original([signature()], pdf: facts), newDocument: pdf)
        let clause = ConversionCertificateE2ERenderer().render(model)
        XCTAssertTrue(clause.contains("<NewDocumentFormatOther>PDF/A-3</NewDocumentFormatOther>"))
        XCTAssertNoThrow(try E2EDeliveryBuilder().clause(model))
        XCTAssertTrue(ConversionRecordE2ERenderer().render(model).contains("<NewDocumentFormat>PDF/A-3</NewDocumentFormat>"))
        XCTAssertNoThrow(try E2EDeliveryBuilder().record(model))
    }

    func testConvertedDocumentIsPdfa2WithItsOwnFingerprint() throws {
        let converted = Data("%PDF-converted".utf8)
        let model = try model(try original([signature()]), newDocument: converted)
        XCTAssertEqual(model.newDocument.format, E2ECodelists.pdfa2Format)
        XCTAssertEqual(model.newDocument.sha256, Data(SHA256.hash(data: converted)))
    }

    func testDSSEvidenceUsesEachSignaturesSlimReport() throws {
        let model = try model(try original([signature()]))
        let expected = Data("<ValidationReport id=\"S-1\"/>".utf8).base64EncodedString()
        XCTAssertTrue(ConversionRecordE2ERenderer().render(model)
            .contains("<ValidityVerificationResult>\(expected)</ValidityVerificationResult>"))
    }

    func testQualifiedReportReplacesSlimReport() throws {
        let report = Data("sealed qualified report".utf8)
        let model = try model(try original([signature()]), qualified: report)
        XCTAssertTrue(ConversionRecordE2ERenderer().render(model)
            .contains("<ValidityVerificationResult>\(report.base64EncodedString())</ValidityVerificationResult>"))
    }

    func testUndeterminedStateAndOtherTypeValidate() throws {
        var undetermined = signature()
        undetermined.indication = "INDETERMINATE"
        undetermined.qualification = "INDETERMINATE_QESIG"
        let model = try model(try original([undetermined]))
        let clause = ConversionCertificateE2ERenderer().render(model)
        XCTAssertTrue(clause.contains("<ItemCode>nie je možné zistiť</ItemCode>"))
        XCTAssertTrue(clause.contains("<AuthorizationTypeOther>"))
        XCTAssertNoThrow(try E2EDeliveryBuilder().clause(model))
        XCTAssertNoThrow(try E2EDeliveryBuilder().record(model))
    }
}
