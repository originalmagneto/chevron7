// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class ConversionRecord12RendererTests: XCTestCase {
    private func model(elements: [SecurityElement] = [ConversionFormModelTests.scanElement()],
                       paper: [AttestationData.PaperSizeGroup]? = nil) throws -> ConversionFormModel {
        var data = ConversionFormModelTests.attestation()
        if let paper { data.paperSizeBreakdown = paper }
        return try ConversionFormModel.make(attestation: data, securityElements: elements,
                                            newDocumentSHA256Hex: ConversionFormModelTests.fingerprintHex,
                                            originalNonEmptyPageIndices: [0], usedDevice: "Chevron7")
    }

    private func requireXmllint() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else { throw XCTSkip("xmllint") }
    }

    func testRenderedRecordValidatesAgainstTheOfficialSchema() throws {
        try requireXmllint()
        let xml = ConversionRecord12Renderer().render(try model())
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(xml.utf8), against: .record_1_2))
    }

    func testCarriesTheRecord12Values() throws {
        let xml = ConversionRecord12Renderer().render(try model())
        XCTAssertTrue(xml.hasPrefix("<ConversionRecord xmlns=\"http://schemas.gov.sk/form/50349287.ConversionRecordOfPaperToElectronicDocument_2021.sk/1.2\">"))
        XCTAssertTrue(xml.contains("<PaperSize>A4</PaperSize>"))
        XCTAssertTrue(xml.contains("<OriginalDocumentSecurityElementsDescription>vlastnoručný podpis</OriginalDocumentSecurityElementsDescription>"))
        XCTAssertTrue(xml.contains("<OriginalDocumentSecurityElementsLocation>vľavo dole</OriginalDocumentSecurityElementsLocation>"))
        XCTAssertFalse(xml.contains("NewDocumentSecurityElementsPage"))
        XCTAssertTrue(xml.contains("<NewDocumentType>Brezinová_diplom</NewDocumentType>"))
        XCTAssertTrue(xml.contains("<ContentType>application/pdf</ContentType>"))
        XCTAssertTrue(xml.contains("<CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009009</CodelistCode><CodelistItem><ItemCode>2</ItemCode><ItemName Language=\"sk\">PDF/A-2</ItemName>"))
        XCTAssertTrue(xml.contains("<ElectronicFingerprintValue>\(ConversionFormModelTests.fingerprintHex)</ElectronicFingerprintValue>"))
        XCTAssertTrue(xml.contains("<ItemCode>2.16.840.1.101.3.4.2.1</ItemCode><ItemName Language=\"sk\">sha-256</ItemName>"))
        XCTAssertTrue(xml.contains("<ConversionRecordEvidenceNumber>https://data.gov.sk/id/egov/conversion-record/1563-260824-1</ConversionRecordEvidenceNumber>"))
        XCTAssertTrue(xml.contains("<ConversionExecutionDateTime>2026-08-24T18:35:44+02:00</ConversionExecutionDateTime>"))
        XCTAssertFalse(xml.contains("<Position>"))
        XCTAssertTrue(xml.contains("<CodelistCode>https://data.gov.sk/set/codelist/CL004001</CodelistCode><CodelistItem><ItemCode>7</ItemCode>"))
        XCTAssertTrue(xml.contains("<IdentifierValue>https://data.gov.sk/id/legal-subject/42249180</IdentifierValue>"))
    }

    func testLetterPaperIsOtherWithItsName() throws {
        try requireXmllint()
        let xml = ConversionRecord12Renderer().render(try model(paper: [.init(sizeClass: .letterPortrait, sheets: 1)]))
        XCTAssertTrue(xml.contains("<PaperSize>Iný</PaperSize><PaperSizeOther>Letter</PaperSizeOther>"))
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(xml.utf8), against: .record_1_2))
    }

    func testPermanentBindingUsesTheRecord12Spelling() throws {
        try requireXmllint()
        var element = ConversionFormModelTests.scanElement(.permanentBinding)
        element.verbalDescription = "zošité niťou"
        var other = ConversionFormModelTests.scanElement(.waxSeal)
        other.verbalDescription = "červená pečať"
        let xml = ConversionRecord12Renderer().render(try model(elements: [element, other]))
        XCTAssertTrue(xml.contains("<OriginalDocumentSecurityElementsDescription>trvalé pevné spojenie - iné</OriginalDocumentSecurityElementsDescription>"))
        XCTAssertTrue(xml.contains("<OriginalDocumentSecurityElementsDescription>iný manuálny vstup</OriginalDocumentSecurityElementsDescription><OriginalDocumentSecurityElementsDescriptionOther>"))
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(xml.utf8), against: .record_1_2))
    }

    func testEveryLocationAndDescriptionChevron7WritesIsARecord12Value() throws {
        try requireXmllint()
        let elements = SecurityElement.Kind.allCases.enumerated().map { index, kind -> SecurityElement in
            var element = ConversionFormModelTests.scanElement(kind)
            element.verbalDescription = "opis \(index)"
            let step = Double(index % 9)
            element.boundingBox = NormalizedRect(x: (step.truncatingRemainder(dividingBy: 3)) * 0.33 + 0.01,
                                                 y: (step / 3).rounded(.down) * 0.33 + 0.01,
                                                 width: 0.05, height: 0.05)
            return element
        }
        let xml = ConversionRecord12Renderer().render(try model(elements: elements))
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(xml.utf8), against: .record_1_2))
        // The record 1.2 location enum, from its schema.
        let record12Locations: Set<String> = ["dole", "hore", "dolný okraj", "horný okraj", "ľavý okraj",
                                              "pravý okraj", "uprostred", "vľavo", "vpravo", "vľavo dole",
                                              "vľavo hore", "vpravo dole", "vpravo hore"]
        XCTAssertEqual(Set(ZakoCodelists.locationItems.map(ZakoCodelists.record12Location)), record12Locations)
    }

    func testBuilderWrapsRecord12WithItsOwnForm() throws {
        try requireXmllint()
        let delivery = try ZakoRecordDeliveryBuilder().build(model: try model(), form: .record_1_2)
        let text = String(decoding: delivery.recordXDCF, as: UTF8.self)
        XCTAssertTrue(text.contains("Identifier=\"\(OfficialForm.record_1_2.identifier)\" Version=\"1.2\""))
        XCTAssertTrue(text.contains("\(OfficialForm.record_1_2.namespace)/form.xsd"))
        XCTAssertEqual(delivery.entryName, "1563-260824-1.record.xml.xdcf")
    }
}
