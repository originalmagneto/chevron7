// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import XCTest
import Chevron7TestSupport
@testable import Chevron7Kit

/// The E→E record 1.2 (the order of 1. 1. 2027), spec 2026-11-18 section 7.2. Every record built
/// here is validated against the official schema; enum values are checked against the schema's
/// own enumerations, never against retyped literals alone.
final class ConversionRecordE2E12RendererTests: XCTestCase {
    private let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x42, count: 300)
    private let time = ISO8601DateFormatter().date(from: "2026-10-16T10:15:42Z")!
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x50, count: 40)
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x4A, count: 40)

    // MARK: Fixtures

    private func attestation() -> AttestationData {
        var data = AttestationData(
            originalDocumentName: "zmluva.pdf", numberOfSheets: 1, nonEmptyPageCount: 1, paperSizeBreakdown: [],
            newDocumentName: "zmluva.pdf", conversionExecutionDateTime: time, evidenceNumber: "1563-261016-7",
            performingPerson: AdvocateProfile(fullName: "Mgr. Marián Čuprík", position: "advokát",
                                              registrationNumber: "1042", ico: "42249180",
                                              officeName: "Advokátska kancelária CHZ"))
        data.originalDocumentTypeLabel = "zmluva o pôžičke"
        return data
    }

    private func stamp(_ id: String, at time: String = "2026-10-10T08:15:30Z",
                       type: String = "SIGNATURE_TIMESTAMP") -> E2EEvidenceFixtures.Timestamp {
        var stamp = E2EEvidenceFixtures.Timestamp()
        stamp.id = id
        stamp.productionTime = time
        stamp.type = type
        return stamp
    }

    private func signature(_ id: String, revision: Int?) -> E2EEvidenceFixtures.Signature {
        var signature = E2EEvidenceFixtures.Signature()
        signature.id = id
        signature.signer = "Podpisovateľ \(id)"
        signature.signedRevisionLength = revision
        signature.signatureValue = Data("value-\(id)".utf8)
        signature.timestamps = [stamp("T-\(id)")]
        return signature
    }

    private func containerSignature(_ id: String, file: String?) -> E2EEvidenceFixtures.Signature {
        var signature = signature(id, revision: nil)
        signature.format = "XAdES-BASELINE-T"
        signature.signatureFilename = file
        return signature
    }

    private func pdfOriginal(_ signatures: [E2EEvidenceFixtures.Signature], facts: E2EEvidenceFixtures.PDF = .init(),
                             documentTimestamps: [E2EEvidenceFixtures.DocumentTimestamp] = []) throws -> ElectronicOriginal {
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: signatures, pdf: facts, documentTimestamps: documentTimestamps))
        return try ElectronicOriginal.make(sourceName: "zmluva.pdf", sourceData: pdf, evidence: evidence)
    }

    private func pdfBytes(_ fill: UInt8, count: Int = 200) -> Data {
        Data("%PDF-1.7\n".utf8) + Data(repeating: fill, count: max(0, count - 9))
    }

    private func object(_ name: String, _ bytes: Data, kind: String = "pdf",
                        coveredBy: [String] = ["C-1"]) -> E2EEvidenceFixtures.DataObject {
        var object = E2EEvidenceFixtures.DataObject(name: name, bytes: bytes)
        object.kind = kind
        object.coveredBy = coveredBy
        return object
    }

    private func container(_ objects: [E2EEvidenceFixtures.DataObject],
                           signatures: [E2EEvidenceFixtures.Signature]) throws -> ElectronicOriginal {
        let data = try ASiCEPackager().package(files: objects.map { .init(path: $0.name, data: $0.bytes) })
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = objects.count
        facts.asicDataObjectName = objects.first { $0.kind == "pdf" }?.name
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: signatures, pdf: facts, dataObjects: objects))
        return try ElectronicOriginal.make(sourceName: "spis.asice", sourceData: data, evidence: evidence)
    }

    private func model(_ original: ElectronicOriginal, newDocument: Data = Data("%PDF-converted".utf8),
                       singlePDF: Bool = false) throws -> E2EFormModel {
        try E2EFormModel.make(original: original, attestation: attestation(), newDocumentName: "zmluva.pdf",
                              newDocumentData: newDocument, usedDevice: "Chevron7 1.5.0", qualifiedReport: nil,
                              deliveredAsSinglePDF: singlePDF)
    }

    /// Builds and validates the record 1.2 against the official schema.
    @discardableResult
    private func record12(_ model: E2EFormModel, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let delivery = try E2EDeliveryBuilder().record(model, form: .recordE2E_1_2)
        let xdc = String(decoding: delivery.recordXDCF, as: UTF8.self)
        XCTAssertTrue(xdc.contains("Identifier=\"\(OfficialForm.recordE2E_1_2.identifier)\""), file: file, line: line)
        XCTAssertEqual(delivery.recordXML, ConversionRecordE2E12Renderer().render(model), file: file, line: line)
        return delivery.recordXML
    }

    private func values(_ element: String, in xml: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "<\(element)>([^<]*)</\(element)>")
        return pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).map {
            String(xml[Range($0.range(at: 1), in: xml)!])
        }
    }

    /// The `Authorization` blocks, each with its own name first.
    private func authorizationBlocks(_ xml: String) -> [String] {
        xml.components(separatedBy: "<Authorization>").dropFirst().map {
            $0.components(separatedBy: "</Authorization>")[0]
        }
    }

    private func block(named name: String, in xml: String) throws -> String {
        try XCTUnwrap(authorizationBlocks(xml).first { $0.hasPrefix("<AuthorizationName>\(name)</AuthorizationName>") },
                      "no authorization \(name)")
    }

    /// The enumeration values of a simple type in the official schema.
    private func schemaEnum(_ type: String) -> Set<String> {
        let schema = String(decoding: OfficialForm.recordE2E_1_2.schema, as: UTF8.self)
        guard let start = schema.range(of: "<xs:simpleType name=\"\(type)\">"),
              let end = schema.range(of: "</xs:simpleType>", range: start.upperBound..<schema.endIndex) else { return [] }
        let body = String(schema[start.upperBound..<end.lowerBound])
        let pattern = try! NSRegularExpression(pattern: "<xs:enumeration value=\"([^\"]*)\"")
        return Set(pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).map {
            String(body[Range($0.range(at: 1), in: body)!])
        })
    }

    private func authorized(_ block: String) -> [String] {
        block.components(separatedBy: "<AuthorizedAuthorization>").dropFirst()
            .compactMap { values("AuthorizationName", in: $0).first }
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func assertCrossReferencesResolve(_ xml: String, file: StaticString = #filePath, line: UInt = #line) {
        let blocks = authorizationBlocks(xml)
        let authorizationNames = blocks.map { values("AuthorizationName", in: $0).first ?? "" }
        XCTAssertEqual(Set(authorizationNames).count, authorizationNames.count, "authorization names unique", file: file, line: line)
        let documentNames = Set(xml.components(separatedBy: "<Authorization>")[0]
            .components(separatedBy: "<OriginalDocumentTimestamp>")[0]
            .components(separatedBy: "<OriginalDocumentInfo>").dropFirst()
            .compactMap { values("OriginalDocumentName", in: $0).first })
        let timestampSection = xml.components(separatedBy: "<Authorization>")[0]
        let timestampNames = values("TimeStampName", in: timestampSection)
        XCTAssertEqual(Set(timestampNames).count, timestampNames.count, "timestamp names unique", file: file, line: line)
        for name in values("OriginalDocumentName", in: xml) {
            XCTAssertTrue(documentNames.contains(name), "document \(name) is defined", file: file, line: line)
        }
        for block in blocks {
            for name in values("AuthorizedTimeStampName", in: block) {
                XCTAssertTrue(timestampNames.contains(name), "timestamp \(name) is defined", file: file, line: line)
            }
            let inner = block.components(separatedBy: "<AuthorizedAuthorization>").dropFirst()
            for reference in inner.compactMap({ values("AuthorizationName", in: $0).first }) {
                XCTAssertTrue(authorizationNames.contains(reference), "authorization \(reference) is defined", file: file, line: line)
            }
        }
    }

    // MARK: Shapes of the original

    func testSignedPdfTwoRevisionsRecord12() throws {
        let original = try pdfOriginal([signature("S-1", revision: 150), signature("S-2", revision: pdf.count)])
        let xml = try record12(try model(original))
        XCTAssertTrue(xml.hasPrefix("<ConversionRecord xmlns=\"\(OfficialForm.recordE2E_1_2.namespace)\">"))
        XCTAssertEqual(values("OriginalDocumentName", in: xml.components(separatedBy: "<Authorization>")[0]),
                       ["zmluva-1", "zmluva-2"])
        XCTAssertEqual(values("OriginalDocumentType", in: xml), ["zmluva o pôžičke", "zmluva o pôžičke"])
        XCTAssertTrue(xml.contains("<OriginalDocumentFormat><Codelist><CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009008</CodelistCode><CodelistItem><ItemCode>1</ItemCode><ItemName Language=\"sk\">PDF</ItemName></CodelistItem></Codelist></OriginalDocumentFormat>"))
        XCTAssertFalse(xml.contains("<OriginalDocumentFormatOther>"))
        XCTAssertEqual(values("AuthorizationName", in: xml).prefix(2), ["Autorizacia1", "Autorizacia2"])
        let first = try block(named: "Autorizacia1", in: xml)
        XCTAssertFalse(first.contains("<AuthorizedAuthorization>"))
        XCTAssertTrue(first.contains("<OriginalDocumentInfo><OriginalDocumentName>zmluva-1</OriginalDocumentName></OriginalDocumentInfo>"))
        let second = try block(named: "Autorizacia2", in: xml)
        XCTAssertTrue(second.contains("<OriginalDocumentInfo><OriginalDocumentName>zmluva-2</OriginalDocumentName></OriginalDocumentInfo><AuthorizedAuthorization><AuthorizationName>Autorizacia1</AuthorizationName></AuthorizedAuthorization><AuthorizationState>platný</AuthorizationState>"))
        XCTAssertTrue(second.contains("<ElectronicSignature>\(Data("value-S-2".utf8).base64EncodedString())</ElectronicSignature>"))
        XCTAssertTrue(second.contains("<ValidityVerificationResult>\(Data("<ValidationReport id=\"S-2\"/>".utf8).base64EncodedString())</ValidityVerificationResult>"))
        XCTAssertEqual(values("TimeStampName", in: xml), ["Casova-peciatka-1", "Casova-peciatka-2"])
        XCTAssertFalse(xml.contains("<OriginalDocumentTimestamp>"))
        XCTAssertFalse(xml.contains("<AuthorizationLocation>"))
        XCTAssertFalse(xml.contains("<Position>"))
        XCTAssertTrue(xml.contains("<ConversionRecordEvidenceNumber>https://data.gov.sk/id/egov/conversion-record/1563-261016-7</ConversionRecordEvidenceNumber><UsedDevice>Chevron7 1.5.0</UsedDevice><ConversionExecutionDateTime>2026-10-16T12:15:42+02:00</ConversionExecutionDateTime>"))
        XCTAssertTrue(xml.contains("<NewDocumentInfo><NewDocumentName>zmluva.pdf</NewDocumentName><NewDocumentType>zmluva o pôžičke</NewDocumentType><ContentType>application/pdf</ContentType><NewDocumentFormat><Codelist><CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009009</CodelistCode><CodelistItem><ItemCode>2</ItemCode><ItemName Language=\"sk\">PDF/A-2</ItemName>"))
        XCTAssertTrue(xml.contains("<ID><IdentifierType><Codelist><CodelistCode>https://data.gov.sk/set/codelist/CL004001</CodelistCode>"))
        assertCrossReferencesResolve(xml)
    }

    func testOnePdfContainerRecord12() throws {
        let container = try ASiCEPackager().package(files: [.init(path: "zmluva.pdf", data: pdf)])
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 1
        facts.asicDataObjectName = "zmluva.pdf"
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [containerSignature("C-1", file: "META-INF/signatures001.xml")], pdf: facts))
        let original = try ElectronicOriginal.make(sourceName: "zmluva.asice", sourceData: container, evidence: evidence)
        XCTAssertEqual(original.authorizations[0].signatureFilename, "META-INF/signatures001.xml")
        let xml = try record12(try model(original))
        XCTAssertEqual(values("AuthorizationName", in: xml), ["signatures001.xml"])
        let only = try block(named: "signatures001.xml", in: xml)
        XCTAssertTrue(only.contains("<OriginalDocumentInfo><OriginalDocumentName>zmluva.pdf</OriginalDocumentName></OriginalDocumentInfo><AuthorizationState>"))
        XCTAssertFalse(only.contains("<AuthorizedAuthorization>"))
        assertCrossReferencesResolve(xml)
    }

    func testMultiFileWithNestedAndPartialSignatureRecord12() throws {
        var a = object("a.pdf", pdfBytes(0x5A, count: 1000), coveredBy: ["C-1"])
        a.nestedSignatures = [signature("P-1", revision: 900)]
        let b = object("b.png", png, kind: "png", coveredBy: ["C-1", "C-2"])
        let original = try container([a, b], signatures: [
            containerSignature("C-1", file: "META-INF/signatures001.xml"),
            containerSignature("C-2", file: "META-INF/signatures002.xml"),
        ])
        let xml = try record12(try model(original))
        XCTAssertEqual(values("AuthorizationName", in: xml).filter { !$0.isEmpty }.prefix(1), ["signatures001.xml"])
        let outer = try block(named: "signatures001.xml", in: xml)
        XCTAssertTrue(outer.contains("<OriginalDocumentInfo><OriginalDocumentName>a-2</OriginalDocumentName></OriginalDocumentInfo><OriginalDocumentInfo><OriginalDocumentName>b.png</OriginalDocumentName></OriginalDocumentInfo><AuthorizedAuthorization><AuthorizationName>Autorizacia1</AuthorizationName></AuthorizedAuthorization><AuthorizationState>"))
        let partial = try block(named: "signatures002.xml", in: xml)
        XCTAssertEqual(values("OriginalDocumentName", in: partial), ["b.png"])
        XCTAssertFalse(partial.contains("<AuthorizedAuthorization>"))
        let nested = try block(named: "Autorizacia1", in: xml)
        XCTAssertEqual(values("OriginalDocumentName", in: nested), ["a-1"])
        XCTAssertFalse(nested.contains("<AuthorizedAuthorization>"))
        XCTAssertTrue(xml.contains("<OriginalDocumentName>b.png</OriginalDocumentName><OriginalDocumentType>zmluva o pôžičke</OriginalDocumentType><OriginalDocumentFormat><Codelist><CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009008</CodelistCode><CodelistItem><ItemCode>4</ItemCode><ItemName Language=\"sk\">PNG</ItemName>"))
        assertCrossReferencesResolve(xml)
    }

    func testPAdESChainNamesEarlierSignatureAndTimestamp() throws {
        var documentStamp = E2EEvidenceFixtures.DocumentTimestamp()
        documentStamp.id = "T-DOC-1"
        documentStamp.coveredRevisionLength = 200
        // DSS lists the document timestamp among the earlier signature's own timestamps too.
        var first = signature("S-1", revision: 150)
        first.timestamps = [stamp("T-DOC-1", at: documentStamp.productionTime, type: "DOCUMENT_TIMESTAMP")]
        let second = signature("S-2", revision: pdf.count)
        let original = try pdfOriginal([first, second], documentTimestamps: [documentStamp])
        XCTAssertEqual(original.documentTimestamps.map(\.documentName), ["zmluva-1"])
        let xml = try record12(try model(original))
        XCTAssertTrue(xml.contains("<OriginalDocumentTimestamp><TimeStampName>Casova-peciatka-1</TimeStampName><OriginalDocumentInfo><OriginalDocumentName>zmluva-1</OriginalDocumentName></OriginalDocumentInfo><TimeStampType>kvalifikovaná elektronická časová pečiatka</TimeStampType><TimeStampState>platný</TimeStampState><TimeStampCreated>2026-10-11T09:00:00+02:00</TimeStampCreated><TimeStampPublisher>BOSA TSA</TimeStampPublisher><TimeStampValidationTime>2026-10-16T11:30:00+02:00</TimeStampValidationTime></OriginalDocumentTimestamp>"))
        let later = try block(named: "Autorizacia2", in: xml)
        XCTAssertTrue(later.contains("<OriginalDocumentInfo><OriginalDocumentName>zmluva-2</OriginalDocumentName></OriginalDocumentInfo><AuthorizedTimeStamp><AuthorizedTimeStampName>Casova-peciatka-1</AuthorizedTimeStampName></AuthorizedTimeStamp><AuthorizedAuthorization><AuthorizationName>Autorizacia1</AuthorizationName></AuthorizedAuthorization>"))
        let earlier = try block(named: "Autorizacia1", in: xml)
        XCTAssertFalse(earlier.contains("<AuthorizedTimeStamp>"))
        // The same timestamp keeps its one name: the earlier signature's TimeStamp is Casova-peciatka-1.
        XCTAssertTrue(earlier.contains("<TimeStamp><TimeStampName>Casova-peciatka-1</TimeStampName>"))
        XCTAssertTrue(later.contains("<TimeStamp><TimeStampName>Casova-peciatka-2</TimeStampName>"))
        assertCrossReferencesResolve(xml)
    }

    func testThreeRevisionChainNamesOnlyThePredecessor() throws {
        let original = try pdfOriginal([signature("S-1", revision: 100), signature("S-2", revision: 200),
                                        signature("S-3", revision: pdf.count)])
        let xml = try record12(try model(original))
        // Nested authorizations are not repeated: each names only its predecessor.
        XCTAssertEqual(authorized(try block(named: "Autorizacia3", in: xml)), ["Autorizacia2"])
        XCTAssertEqual(authorized(try block(named: "Autorizacia2", in: xml)), ["Autorizacia1"])
        XCTAssertEqual(authorized(try block(named: "Autorizacia1", in: xml)), [])
    }

    func testNestedDocumentTimestampNamesItsFileRevision() throws {
        var a = object("a.pdf", pdfBytes(0x5A, count: 1000), coveredBy: ["C-1"])
        a.nestedSignatures = [signature("P-1", revision: 400), signature("P-2", revision: 900)]
        var nestedStamp = E2EEvidenceFixtures.DocumentTimestamp()
        nestedStamp.id = "T-NDOC"
        nestedStamp.coveredRevisionLength = 500
        a.nestedDocumentTimestamps = [nestedStamp]
        let original = try container([a], signatures: [containerSignature("C-1", file: "META-INF/signatures001.xml")])
        XCTAssertEqual(original.documentTimestamps.map(\.documentName), ["a-1"])
        XCTAssertEqual(original.documentTimestamps.map(\.fileEntryName), ["a.pdf"])
        let xml = try record12(try model(original))
        let p2 = try block(named: "Autorizacia2", in: xml)
        XCTAssertEqual(values("AuthorizedTimeStampName", in: p2), ["Elektronicka casova peciatka"])
        XCTAssertEqual(p2.components(separatedBy: "<AuthorizedAuthorization>").dropFirst()
            .compactMap { values("AuthorizationName", in: $0).first }, ["Autorizacia1"])
        let outer = try block(named: "signatures001.xml", in: xml)
        XCTAssertEqual(authorized(outer), ["Autorizacia2"])
        XCTAssertEqual(values("AuthorizedTimeStampName", in: outer), [])
        assertCrossReferencesResolve(xml)
    }

    func testPAdESChainAndTimestampsAreNamedOnceEach() throws {
        // a.pdf: P-1 (300), document timestamp D-1 (400), P-2 (500), P-3 (800), D-2 (900), 1000 bytes.
        var a = object("a.pdf", pdfBytes(0x5A, count: 1000), coveredBy: ["C-1"])
        a.nestedSignatures = [signature("P-1", revision: 300), signature("P-2", revision: 500),
                              signature("P-3", revision: 800)]
        var d1 = E2EEvidenceFixtures.DocumentTimestamp()
        d1.id = "D-1"
        d1.coveredRevisionLength = 400
        var d2 = E2EEvidenceFixtures.DocumentTimestamp()
        d2.id = "D-2"
        d2.coveredRevisionLength = 900
        a.nestedDocumentTimestamps = [d1, d2]
        let original = try container([a], signatures: [containerSignature("C-1", file: "META-INF/signatures001.xml")])
        XCTAssertEqual(original.documentTimestamps.map(\.documentName), ["a-1", "a-3"])
        let xml = try record12(try model(original))
        let p1 = try block(named: "Autorizacia1", in: xml)
        let p2 = try block(named: "Autorizacia2", in: xml)
        let p3 = try block(named: "Autorizacia3", in: xml)
        let outer = try block(named: "signatures001.xml", in: xml)
        XCTAssertEqual(authorized(p1), [])
        XCTAssertEqual(values("AuthorizedTimeStampName", in: p1), [])
        XCTAssertEqual(authorized(p2), ["Autorizacia1"])
        XCTAssertEqual(values("AuthorizedTimeStampName", in: p2), ["Casova-peciatka-1"])
        XCTAssertEqual(authorized(p3), ["Autorizacia2"])
        XCTAssertEqual(values("AuthorizedTimeStampName", in: p3), [])
        XCTAssertEqual(authorized(outer), ["Autorizacia3"])
        XCTAssertEqual(values("AuthorizedTimeStampName", in: outer), ["Casova-peciatka-2"])
        // D-1, D-2, then the four signatures' own timestamps.
        XCTAssertEqual(values("TimeStampName", in: xml), (1...6).map { "Casova-peciatka-\($0)" })
        assertCrossReferencesResolve(xml)
    }

    func testContainerNamesTimestampsAfterTheLastPAdES() throws {
        var a = object("a.pdf", pdfBytes(0x5A, count: 1000), coveredBy: ["C-1"])
        a.nestedSignatures = [signature("P-1", revision: 300)]
        var early = E2EEvidenceFixtures.DocumentTimestamp()
        early.id = "D-1"
        early.coveredRevisionLength = 600
        a.nestedDocumentTimestamps = [early]
        let original = try container([a], signatures: [containerSignature("C-1", file: "META-INF/signatures001.xml")])
        let xml = try record12(try model(original))
        XCTAssertEqual(values("AuthorizedTimeStampName", in: try block(named: "signatures001.xml", in: xml)),
                       ["Elektronicka casova peciatka"])
        XCTAssertEqual(values("AuthorizedTimeStampName", in: try block(named: "Autorizacia1", in: xml)), [])
    }

    func testSignatureTimestampIsAlwaysNumbered() throws {
        let xml = try record12(try model(try pdfOriginal([signature("S-1", revision: pdf.count)])))
        XCTAssertEqual(values("TimeStampName", in: xml), ["Casova-peciatka-1"])
    }

    func testSingleDocumentTimestampIsElektronickaCasovaPeciatka() throws {
        var documentStamp = E2EEvidenceFixtures.DocumentTimestamp()
        documentStamp.id = "T-DOC-1"
        documentStamp.coveredRevisionLength = 200
        let xml = try record12(try model(try pdfOriginal(
            [signature("S-1", revision: 150), signature("S-2", revision: pdf.count)], documentTimestamps: [documentStamp])))
        XCTAssertTrue(xml.contains("<OriginalDocumentTimestamp><TimeStampName>Elektronicka casova peciatka</TimeStampName>"))
        XCTAssertEqual(values("AuthorizedTimeStampName", in: xml), ["Elektronicka casova peciatka"])
        XCTAssertEqual(values("TimeStampName", in: try block(named: "Autorizacia1", in: xml)), ["Casova-peciatka-1"])
        XCTAssertEqual(values("TimeStampName", in: try block(named: "Autorizacia2", in: xml)), ["Casova-peciatka-2"])
        assertCrossReferencesResolve(xml)
    }

    func testSingleDocumentTimestampThatIsASignaturesTimeStampIsNumbered() throws {
        // DSS lists the document timestamp under the earlier signature, whose TimeStamp it becomes;
        // that element is always "Casova-peciatka-<N>", and one timestamp keeps one name.
        var documentStamp = E2EEvidenceFixtures.DocumentTimestamp()
        documentStamp.id = "T-DOC-1"
        documentStamp.coveredRevisionLength = 200
        var first = signature("S-1", revision: 150)
        first.timestamps = [stamp("T-DOC-1", at: documentStamp.productionTime, type: "DOCUMENT_TIMESTAMP")]
        var second = signature("S-2", revision: pdf.count)
        second.timestamps = []
        let xml = try record12(try model(try pdfOriginal([first, second], documentTimestamps: [documentStamp])))
        XCTAssertEqual(values("TimeStampName", in: xml), ["Casova-peciatka-1", "Casova-peciatka-1"])
        XCTAssertEqual(values("AuthorizedTimeStampName", in: xml), ["Casova-peciatka-1"])
        XCTAssertFalse(xml.contains("Elektronicka casova peciatka"))
    }

    func testUnmappableOriginalDocumentFormatIsRefused() throws {
        var original = try pdfOriginal([signature("S-1", revision: pdf.count)])
        original.documents[0].format = E2ECodelists.otherFormat
        original.documents[0].formatOther = String(repeating: "X", count: 31)
        XCTAssertThrowsError(try E2EDeliveryBuilder().record(try model(original), form: .recordE2E_1_2)) { error in
            XCTAssertEqual(error as? E2EDeliveryBuilder.Failure, .unmappableOriginalDocumentFormat(name: "zmluva.pdf"))
        }
        original.documents[0].formatOther = nil
        XCTAssertThrowsError(try E2EDeliveryBuilder().record(try model(original), form: .recordE2E_1_2))
    }

    func testContainerNamesEveryTimestampOfAFileWithoutPAdES() throws {
        // a.pdf has two document timestamps and no PAdES signature: the container names both.
        var a = object("a.pdf", pdfBytes(0x5A, count: 1000), coveredBy: ["C-1"])
        var d1 = E2EEvidenceFixtures.DocumentTimestamp()
        d1.id = "D-1"
        d1.coveredRevisionLength = 1000
        var d2 = E2EEvidenceFixtures.DocumentTimestamp()
        d2.id = "D-2"
        d2.coveredRevisionLength = 1000
        a.nestedDocumentTimestamps = [d1, d2]
        let b = object("b.png", png, kind: "png", coveredBy: ["C-1"])
        let original = try container([a, b], signatures: [containerSignature("C-1", file: "META-INF/signatures001.xml")])
        XCTAssertEqual(original.documentTimestamps.map(\.documentName), ["a.pdf", "a.pdf"])
        XCTAssertEqual(original.authorizations.count, 1)
        let xml = try record12(try model(original))
        let outer = try block(named: "signatures001.xml", in: xml)
        XCTAssertEqual(values("AuthorizedTimeStampName", in: outer), ["Casova-peciatka-1", "Casova-peciatka-2"])
        XCTAssertEqual(authorized(outer), [])
        assertCrossReferencesResolve(xml)
    }

    func testDocumentTimestampCoveringNoDocumentIsLeftOut() throws {
        var early = E2EEvidenceFixtures.DocumentTimestamp()
        early.id = "T-EARLY"
        early.coveredRevisionLength = 50
        var unknown = E2EEvidenceFixtures.DocumentTimestamp()
        unknown.id = "T-UNKNOWN"
        let original = try pdfOriginal([signature("S-1", revision: 150), signature("S-2", revision: pdf.count)],
                                       documentTimestamps: [early, unknown])
        XCTAssertTrue(original.documentTimestamps.isEmpty)
        let xml = try record12(try model(original))
        XCTAssertFalse(xml.contains("<OriginalDocumentTimestamp>"))
        XCTAssertFalse(xml.contains("<AuthorizedTimeStamp>"))
    }

    func testSharedSignatureFileFallsBackToTheSequence() throws {
        let container = try ASiCEPackager().package(files: [.init(path: "zmluva.pdf", data: pdf)])
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 1
        facts.asicDataObjectName = "zmluva.pdf"
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [containerSignature("C-1", file: "META-INF/signatures.xml"),
                         containerSignature("C-2", file: "META-INF/signatures.xml"),
                         containerSignature("C-3", file: "META-INF/signatures003.xml")], pdf: facts))
        let original = try ElectronicOriginal.make(sourceName: "zmluva.asice", sourceData: container, evidence: evidence)
        let xml = try record12(try model(original))
        XCTAssertEqual(values("AuthorizationName", in: xml), ["Autorizacia1", "Autorizacia2", "signatures003.xml"])
    }

    // MARK: Values

    func testEveryAuthorizationTypeValidates() throws {
        let cases: [(String, String, String, String?)] = [
            ("QESIG", "esign", "kvalifikovaný elektronický podpis", "certifikát - kvalifikovaný, certifikát je na QSCD"),
            ("QESEAL", "eseal", "kvalifikovaná elektronická pečať", "certifikát - kvalifikovaný, certifikát je na QSCD"),
            ("ADESIG_QC", "esign", "zdokonalený elektronický podpis s použitím kvalifikovaného certifikátu",
             "certifikát \u{2013} kvalifikovaný, certifikát nie je na QSCD"),
            ("ADESEAL_QC", "eseal", "zdokonalená elektronická pečať s použitím kvalifikovaného certifikátu",
             "certifikát \u{2013} kvalifikovaný, certifikát nie je na QSCD"),
            ("ADESIG", "esign", "zdokonalený elektronický podpis", nil),
            ("ADESEAL", "eseal", "zdokonalená elektronická pečať", nil),
            ("NOT_ADES", "esign", "elektronický podpis", nil),
            ("NOT_ADES_QC_QSCD", "eseal", "elektronická pečať", nil),
        ]
        let types = schemaEnum("AuthorizationTypeEnum")
        let certificates = schemaEnum("CertificateTypeEnum")
        XCTAssertEqual(types.count, 10)
        XCTAssertEqual(certificates.count, 4)
        for (qualification, qcType, expectedType, expectedCertificate) in cases {
            XCTAssertTrue(types.contains(expectedType), expectedType)
            if let expectedCertificate { XCTAssertTrue(certificates.contains(expectedCertificate), expectedCertificate) }
            XCTAssertEqual(ConversionRecordE2E12Renderer.authorizationType(qualification: qualification, qcType: qcType),
                           expectedType, qualification)
            var one = signature("S-1", revision: pdf.count)
            one.qualification = qualification
            one.qcType = qcType
            let original = try pdfOriginal([one])
            XCTAssertEqual(original.authorizations[0].qualification, qualification)
            let xml = try record12(try model(original))
            XCTAssertEqual(values("AuthorizationType", in: xml), [expectedType], qualification)
            XCTAssertEqual(values("CertificateType", in: xml), expectedCertificate.map { [$0] } ?? [], qualification)
            XCTAssertEqual(values("OtherAuthorizationInfo", in: xml), ["Kvalifikovaný certifikát: áno"])
        }
    }

    func testMissingMandantIsZiadna() throws {
        let xml = try record12(try model(try pdfOriginal([signature("S-1", revision: pdf.count)])))
        XCTAssertTrue(xml.contains("<AuthorizationPerson><PersonID>PNOSK-1234567890</PersonID><Mandant>Žiadna</Mandant><Mandate>Žiaden</Mandate></AuthorizationPerson>"))
        var mandated = signature("S-1", revision: pdf.count)
        mandated.mandate = "1042 OPRÁVNENIE 1042"
        mandated.mandants = ["MANDANT Kancelária & synovia s.r.o."]
        let withMandate = try record12(try model(try pdfOriginal([mandated])))
        XCTAssertTrue(withMandate.contains("<Mandant>MANDANT Kancelária &amp; synovia s.r.o.</Mandant><Mandate>1042 OPRÁVNENIE 1042</Mandate>"))
    }

    func testFingerprintsAreHex() throws {
        let converted = Data("%PDF-converted".utf8)
        let original = try pdfOriginal([signature("S-1", revision: 150), signature("S-2", revision: pdf.count)])
        let xml = try record12(try model(original, newDocument: converted))
        XCTAssertEqual(values("ElectronicFingerprintValue", in: xml),
                       [hex(Data(SHA256.hash(data: pdf.prefix(150)))), hex(Data(SHA256.hash(data: pdf))),
                        hex(Data(SHA256.hash(data: converted)))])
        XCTAssertEqual(xml.components(separatedBy: "<ElectronicFingerprintCalculationMethod><Codelist><CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009005</CodelistCode><CodelistItem><ItemCode>2.16.840.1.101.3.4.2.1</ItemCode><ItemName Language=\"sk\">sha-256</ItemName>").count - 1, 3)
    }

    func testStatesAreMasculine() throws {
        let states = schemaEnum("AuthorizationOrTimeStampStateEnum")
        XCTAssertEqual(states, ["platný", "neplatný", "nie je možné zistiť"])
        var invalid = signature("S-1", revision: 150)
        invalid.indication = "TOTAL_FAILED"
        invalid.timestamps[0].indication = "FAILED"
        var undetermined = signature("S-2", revision: pdf.count)
        undetermined.indication = "INDETERMINATE"
        undetermined.timestamps[0].indication = "INDETERMINATE"
        let xml = try record12(try model(try pdfOriginal([invalid, undetermined])))
        XCTAssertEqual(values("AuthorizationState", in: xml), ["neplatný", "nie je možné zistiť"])
        XCTAssertEqual(values("TimeStampState", in: xml), ["neplatný", "nie je možné zistiť"])
        let valid = try record12(try model(try pdfOriginal([signature("S-1", revision: pdf.count)])))
        XCTAssertEqual(values("AuthorizationState", in: valid), ["platný"])
        XCTAssertEqual(values("TimeStampState", in: valid), ["platný"])
        XCTAssertTrue(schemaEnum("TimeStampTypeEnum").isSuperset(of: values("TimeStampType", in: valid)))
    }

    func testOnePdfNewDocumentIsPDFA3Item() throws {
        let xml = try record12(try model(try pdfOriginal([signature("S-1", revision: pdf.count)]), singlePDF: true))
        XCTAssertTrue(xml.contains("<NewDocumentFormat><Codelist><CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009009</CodelistCode><CodelistItem><ItemCode>3</ItemCode><ItemName Language=\"sk\">PDF/A-3</ItemName></CodelistItem></Codelist></NewDocumentFormat>"))
    }

    func testKeptPdfaOriginalsKeepTheirFormats() throws {
        let expected: [(Int, String, String, String)] = [(1, "2", "PDF/A-1", "1"), (2, "3", "PDF/A-2", "2"), (3, "8", "PDF/A-3", "3")]
        for (part, originalCode, name, newCode) in expected {
            var facts = E2EEvidenceFixtures.PDF()
            facts.declaredPdfaPart = part
            facts.pdfaCompliant = true
            let original = try pdfOriginal([signature("S-1", revision: pdf.count)], facts: facts)
            let xml = try record12(try model(original, newDocument: pdf))
            XCTAssertTrue(xml.contains("<OriginalDocumentFormat><Codelist><CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009008</CodelistCode><CodelistItem><ItemCode>\(originalCode)</ItemCode><ItemName Language=\"sk\">\(name)</ItemName>"), name)
            XCTAssertFalse(xml.contains("<OriginalDocumentFormatOther>"), name)
            XCTAssertTrue(xml.contains("<NewDocumentFormat><Codelist><CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009009</CodelistCode><CodelistItem><ItemCode>\(newCode)</ItemCode><ItemName Language=\"sk\">\(name)</ItemName>"), name)
        }
    }

    func testJpegIsInyWithItsName() throws {
        let original = try container([object("a.jpg", jpeg, kind: "jpeg")],
                                     signatures: [containerSignature("C-1", file: "META-INF/signatures001.xml")])
        let xml = try record12(try model(original))
        XCTAssertTrue(xml.contains("<CodelistItem><ItemCode>7</ItemCode><ItemName Language=\"sk\">Iný</ItemName></CodelistItem></Codelist></OriginalDocumentFormat><OriginalDocumentFormatOther>JPEG</OriginalDocumentFormatOther>"))
    }

    func testUnmappableNewDocumentFormatIsRefused() throws {
        var kept = try pdfOriginal([signature("S-1", revision: pdf.count)])
        kept.plan = .keep(format: E2ECodelists.otherFormat, formatOther: "XYZ")
        XCTAssertThrowsError(try E2EDeliveryBuilder().record(try model(kept), form: .recordE2E_1_2))
    }

    // MARK: Undetermined qualification

    func testUnmappableQualificationIsReported() throws {
        for qualification in ["INDETERMINATE_QESIG", ""] {
            var one = signature("S-1", revision: pdf.count)
            one.qualification = qualification
            one.indication = "INDETERMINATE"
            let original = try pdfOriginal([one])
            XCTAssertNil(ConversionRecordE2E12Renderer.authorizationType(qualification: qualification, qcType: "esign"))
            XCTAssertEqual(ConversionRecordE2E12Renderer.unmappableAuthorizations(original).map(\.signatureID), ["S-1"])
            XCTAssertThrowsError(try E2EDeliveryBuilder().record(try model(original), form: .recordE2E_1_2)) { error in
                XCTAssertEqual(error as? E2EDeliveryBuilder.Failure, .unmappableAuthorization(signer: "Podpisovateľ S-1"))
            }
            // Record 1.0 keeps its "Iný" with the text.
            XCTAssertNoThrow(try E2EDeliveryBuilder().record(try model(original), form: .recordE2E_1_0))
        }
        for value in ["QES", "ADES_QC", "ADES", "NA", "INDETERMINATE_ADESIG_QC"] {
            XCTAssertNil(ConversionRecordE2E12Renderer.authorizationType(qualification: value, qcType: "esign"), value)
        }
    }

    /// The renderer never substitutes a value: rendered directly, an unmappable type or format
    /// is written empty, and the official schema refuses the record.
    func testUnmappedValuesRenderedDirectlyFailTheSchema() throws {
        var one = signature("S-1", revision: pdf.count)
        one.qualification = "INDETERMINATE_QESIG"
        let unmappedType = ConversionRecordE2E12Renderer().render(try model(try pdfOriginal([one])))
        XCTAssertTrue(unmappedType.contains("<AuthorizationType></AuthorizationType>"))
        XCTAssertThrowsError(try FormSchemaValidator().validate(Data(unmappedType.utf8), against: .recordE2E_1_2))
        var kept = try pdfOriginal([signature("S-1", revision: pdf.count)])
        kept.plan = .keep(format: E2ECodelists.otherFormat, formatOther: "XYZ")
        let unmappedFormat = ConversionRecordE2E12Renderer().render(try model(kept))
        XCTAssertTrue(unmappedFormat.contains("<ItemCode></ItemCode>"))
        XCTAssertThrowsError(try FormSchemaValidator().validate(Data(unmappedFormat.utf8), against: .recordE2E_1_2))
    }

    func testNestedUndeterminedQualificationIsUnmappable() throws {
        var a = object("a.pdf", pdfBytes(0x5A, count: 1000), coveredBy: ["C-1"])
        var nested = signature("P-1", revision: 900)
        nested.qualification = "INDETERMINATE_QESIG"
        a.nestedSignatures = [nested]
        let original = try container([a], signatures: [containerSignature("C-1", file: "META-INF/signatures001.xml")])
        XCTAssertEqual(ConversionRecordE2E12Renderer.unmappableAuthorizations(original).map(\.signatureID), ["P-1"])
        XCTAssertThrowsError(try E2EDeliveryBuilder().record(try model(original), form: .recordE2E_1_2))
    }

    // MARK: Record 1.0 unchanged

    /// SHA-256 of record 1.0 XML rendered before this change (2026-11-18) for the two fixtures
    /// below; the new authorization and timestamp facts must not move a byte of it.
    func testRecord10UnchangedThroughNewSignature() throws {
        let two = try twoRevisionGoldenModel()
        let multi = try multiGoldenModel()
        for (model, expected) in [(two, "56c6465f956792cca28d43c890c290096b98ca4edc4ea2c189fb85b078669801"),
                                  (multi, "c51497f20b4b62c2f5d95830b93f48ef80dd230e9bbbf89b73b0f620164a1f35")] {
            let viaForm = try E2EDeliveryBuilder().record(model, form: .recordE2E_1_0).recordXML
            let viaOld = try E2EDeliveryBuilder().record(model).recordXML
            XCTAssertEqual(viaForm, viaOld)
            XCTAssertEqual(hex(Data(SHA256.hash(data: Data(viaForm.utf8)))), expected)
        }
    }

    private func twoRevisionGoldenModel() throws -> E2EFormModel {
        var s1 = E2EEvidenceFixtures.Signature()
        s1.id = "S-1"
        s1.signedRevisionLength = 150
        s1.mandate = "1042 OPRÁVNENIE 1042"
        s1.mandants = ["MANDANT Kancelária & synovia s.r.o."]
        var s2 = E2EEvidenceFixtures.Signature()
        s2.id = "S-2"
        s2.signedRevisionLength = pdf.count
        s2.signatureValue = Data("signature-value-2".utf8)
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [s1, s2]))
        let original = try ElectronicOriginal.make(sourceName: "zmluva.pdf", sourceData: pdf, evidence: evidence)
        return try E2EFormModel.make(original: original, attestation: attestation(), newDocumentName: "zmluva.pdf",
                                     newDocumentData: Data("%PDF-converted".utf8), usedDevice: "Chevron7 1.5.0",
                                     qualifiedReport: nil)
    }

    private func multiGoldenModel() throws -> E2EFormModel {
        let bytes = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x5A, count: 991)
        var a = E2EEvidenceFixtures.DataObject(name: "a.pdf", bytes: bytes)
        a.coveredBy = ["C-1"]
        var p = E2EEvidenceFixtures.Signature()
        p.id = "P-1"
        p.signedRevisionLength = 900
        p.signatureValue = Data("pades-P-1".utf8)
        a.nestedSignatures = [p]
        var b = E2EEvidenceFixtures.DataObject(name: "b.png", bytes: png)
        b.kind = "png"
        b.coveredBy = ["C-1"]
        var c = E2EEvidenceFixtures.Signature()
        c.id = "C-1"
        c.format = "XAdES-BASELINE-T"
        c.signatureValue = Data("container-C-1".utf8)
        c.signatureFilename = "META-INF/signatures001.xml"
        let data = try ASiCEPackager().package(files: [a, b].map { .init(path: $0.name, data: $0.bytes) })
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = 2
        facts.asicDataObjectName = "a.pdf"
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(
            signatures: [c], pdf: facts, dataObjects: [a, b]))
        let original = try ElectronicOriginal.make(sourceName: "spis.asice", sourceData: data, evidence: evidence)
        return try E2EFormModel.make(original: original, attestation: attestation(), newDocumentName: "spis.pdf",
                                     newDocumentData: Data("%PDF-converted".utf8), usedDevice: "Chevron7 1.5.0",
                                     qualifiedReport: nil)
    }
}
