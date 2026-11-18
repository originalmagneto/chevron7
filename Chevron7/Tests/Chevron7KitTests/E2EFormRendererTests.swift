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

    func testE2ESinglePDFFormats() throws {
        let original = try original([signature()])
        let single = try E2EFormModel.make(original: original, attestation: attestation(), newDocumentName: "zmluva.pdf",
                                           newDocumentData: Data("%PDF-converted".utf8), usedDevice: "Chevron7 1.5.0",
                                           qualifiedReport: nil, deliveredAsSinglePDF: true)
        XCTAssertNoThrow(try E2EDeliveryBuilder().clause(single))
        let clauseXML = ConversionCertificateE2ERenderer().render(single)
        XCTAssertTrue(clauseXML.contains("<ItemCode>Iny</ItemCode>"))
        XCTAssertTrue(clauseXML.contains("<NewDocumentFormatOther>PDF/A-3</NewDocumentFormatOther>"))
        let record = try E2EDeliveryBuilder().record(single)
        XCTAssertTrue(record.recordXML.contains("<NewDocumentFormat>PDF/A-3</NewDocumentFormat>"))
    }

    func testE2EDefaultKeepsThePlansFormat() throws {
        var kept = try original([signature()])
        kept.plan = .keep(format: E2ECodelists.otherFormat, formatOther: "XYZ")
        let model = try model(kept)
        XCTAssertTrue(ConversionCertificateE2ERenderer().render(model).contains("<NewDocumentFormatOther>XYZ</NewDocumentFormatOther>"))
        XCTAssertTrue(try E2EDeliveryBuilder().record(model).recordXML.contains("<NewDocumentFormat>XYZ</NewDocumentFormat>"))
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

    // MARK: Containers with several files

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x50, count: 40)

    private func pdfBytes(_ fill: UInt8, count: Int = 200) -> Data {
        Data("%PDF-1.7\n".utf8) + Data(repeating: fill, count: max(0, count - 9))
    }

    private func multiOriginal(nested: Bool) throws -> ElectronicOriginal {
        var a = E2EEvidenceFixtures.DataObject(name: "a.pdf", bytes: pdfBytes(0x5A, count: 1000))
        a.coveredBy = ["C-1"]
        if nested {
            var padesSignature = E2EEvidenceFixtures.Signature()
            padesSignature.id = "P-1"
            padesSignature.signedRevisionLength = 900
            padesSignature.signatureValue = Data("pades-P-1".utf8)
            a.nestedSignatures = [padesSignature]
        }
        var b = E2EEvidenceFixtures.DataObject(name: "b.png", bytes: png)
        b.kind = "png"
        b.coveredBy = ["C-1"]
        var container = E2EEvidenceFixtures.Signature()
        container.id = "C-1"
        container.format = "XAdES-BASELINE-T"
        container.signatureValue = Data("container-C-1".utf8)
        let objects = [a, b]
        let data = try ASiCEPackager().package(files: objects.map { .init(path: $0.name, data: $0.bytes) })
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = objects.count
        facts.asicDataObjectName = "a.pdf"
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [container], pdf: facts, dataObjects: objects))
        return try ElectronicOriginal.make(sourceName: "spis.asice", sourceData: data, evidence: evidence)
    }

    private func multiModel(_ original: ElectronicOriginal, labels: [String: String] = [:]) throws -> E2EFormModel {
        var data = attestation()
        data.originalDocumentTypeLabels = labels
        return try E2EFormModel.make(original: original, attestation: data, newDocumentName: "spis.pdf",
                                     newDocumentData: Data("%PDF-converted".utf8), usedDevice: "Chevron7 1.5.0",
                                     qualifiedReport: nil)
    }

    func testThreeOriginalsWithNestedSignatureValidateAgainstBothSchemas() throws {
        let original = try multiOriginal(nested: true)
        XCTAssertEqual(original.documents.map(\.name), ["a-1", "a-2", "b.png"])
        let model = try multiModel(original)
        XCTAssertNoThrow(try E2EDeliveryBuilder().clause(model))
        XCTAssertNoThrow(try E2EDeliveryBuilder().record(model))
        let clause = ConversionCertificateE2ERenderer().render(model)
        XCTAssertEqual(clause.components(separatedBy: "<OriginalDocumentInfo>").count - 1, 3)
        let record = ConversionRecordE2ERenderer().render(model)
        XCTAssertEqual(record.components(separatedBy: "<OriginalDocumentInfo>").count - 1, 3)
        let nestedRange = try XCTUnwrap(clause.range(of: "<AuthorizedDocument><AuthorizedDocumentName>a-1</AuthorizedDocumentName></AuthorizedDocument><AuthorizationState>"))
        XCTAssertFalse(clause[nestedRange].contains("a-2"))
    }

    func testRecordCarriesTypePerFile() throws {
        let original = try multiOriginal(nested: false)
        let model = try multiModel(original, labels: ["a.pdf": "Zmluva", "b.png": "Iný dokument"])
        XCTAssertEqual(model.originalDocumentTypes, ["Zmluva", "Iný dokument"])
        let record = ConversionRecordE2ERenderer().render(model)
        let first = try XCTUnwrap(record.range(of: "<OriginalDocumentType>Zmluva</OriginalDocumentType>"))
        let second = try XCTUnwrap(record.range(of: "<OriginalDocumentType>Iný dokument</OriginalDocumentType>"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertNoThrow(try E2EDeliveryBuilder().record(model))
    }

    func testRevisionDocumentTakesItsFilesTypeAndFallsBackToCommonLabel() throws {
        let original = try multiOriginal(nested: true)
        let model = try multiModel(original, labels: ["a.pdf": "Zmluva"])
        XCTAssertEqual(model.originalDocumentTypes, ["Zmluva", "Zmluva", "zmluva o pôžičke"])
    }

    func testStoredAttestationWithoutLabelsStillDecodes() throws {
        let data = attestation()
        let encoder = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with: encoder.encode(data)) as! [String: Any]
        json.removeValue(forKey: "originalDocumentTypeLabels")
        let decoded = try JSONDecoder().decode(AttestationData.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.originalDocumentTypeLabels, [:])
    }
}
