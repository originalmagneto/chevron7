// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

/// The one-PDF output names PDF/A-3 in the official forms; the container output stays as it was.
final class ZakoSinglePDFFormsTests: XCTestCase {
    private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/asic-output")

    private func model() throws -> ConversionFormModel {
        try ConversionFormModel.make(attestation: ConversionFormModelTests.attestation(),
                                     securityElements: [ConversionFormModelTests.scanElement()],
                                     newDocumentSHA256Hex: ConversionFormModelTests.fingerprintHex,
                                     originalNonEmptyPageIndices: [0], usedDevice: "Chevron7")
    }

    private func renderedDefaults() throws -> [String: String] {
        let m = try model()
        return ["clause-1.3.xml": ConversionCertificateRenderer().render(m),
                "record-1.0.xml": ConversionRecordRenderer().render(m),
                "record-1.2.xml": ConversionRecord12Renderer().render(m)]
    }

    private func singleModel() throws -> ConversionFormModel {
        try ConversionFormModel.make(attestation: ConversionFormModelTests.attestation(),
                                     securityElements: [ConversionFormModelTests.scanElement()],
                                     newDocumentSHA256Hex: ConversionFormModelTests.fingerprintHex,
                                     originalNonEmptyPageIndices: [0], usedDevice: "Chevron7",
                                     deliveredAsSinglePDF: true)
    }

    private func requireXmllint() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else { throw XCTSkip("xmllint") }
    }

    func testSinglePDFClauseNamesPdfA3AsOther() throws {
        try requireXmllint()
        let xml = ConversionCertificateRenderer().render(try singleModel())
        XCTAssertTrue(xml.contains("<ItemCode>Iny</ItemCode>"))
        XCTAssertTrue(xml.contains("<NewDocumentFormatOther>PDF/A-3</NewDocumentFormatOther>"))
        XCTAssertFalse(xml.contains("PDFA2"))
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(xml.utf8), against: .clause_1_3))
    }

    func testSinglePDFRecord10SaysPdfA3() throws {
        try requireXmllint()
        let xml = ConversionRecordRenderer().render(try singleModel())
        XCTAssertTrue(xml.contains("<NewDocumentFormat>PDF/A-3</NewDocumentFormat>"))
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(xml.utf8), against: .record_1_0))
    }

    func testSinglePDFRecord12UsesItem3() throws {
        try requireXmllint()
        let xml = ConversionRecord12Renderer().render(try singleModel())
        XCTAssertTrue(xml.contains("<CodelistCode>https://metais.vicepremier.gov.sk/set/codelist/CL009009</CodelistCode><CodelistItem><ItemCode>3</ItemCode><ItemName Language=\"sk\">PDF/A-3</ItemName>"))
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(xml.utf8), against: .record_1_2))
    }

    func testAsicOutputUnchanged() throws {
        for (name, xml) in try renderedDefaults() {
            let expected = try String(contentsOf: Self.fixtureDirectory.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(xml, expected, name)
        }
    }
}
