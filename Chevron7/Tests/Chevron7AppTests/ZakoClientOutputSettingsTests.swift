// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App
@testable import Chevron7Kit

final class ZakoClientOutputSettingsTests: XCTestCase {
    func testClientOutputDefaultsToContainerAndRoundTrips() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.zakoClientOutput, .asicContainer)
        settings.zakoClientOutput = .singlePDF
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.zakoClientOutput, .singlePDF)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.zakoClientOutput, .asicContainer)
    }

    func testUnknownClientOutputFallsBackToContainer() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"zakoClientOutput":"somethingNew"}"#.utf8))
        XCTAssertEqual(decoded.zakoClientOutput, .asicContainer)
    }

    func testOldEvidenceRowsDecodeWithoutClientOutput() throws {
        var row = EvidenceRecord(status: .signed, direction: .paperToElectronic, originalName: "a", newDocumentName: "b",
                                 evidenceNumber: "1", fingerprintSHA256Hex: String(repeating: "a", count: 64),
                                 attestationXML: "<x/>", conversionTime: Date(timeIntervalSince1970: 0),
                                 performingPersonName: "P", securityElementCount: 0, totalPages: 1, totalSheets: 1)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let old = try decoder.decode(EvidenceRecord.self, from: encoder.encode(row))
        XCTAssertNil(old.clientOutput)
        XCTAssertNil(old.revisionOneLength)
        row.clientOutput = .singlePDF
        row.revisionOneLength = 1234
        let back = try decoder.decode(EvidenceRecord.self, from: encoder.encode(row))
        XCTAssertEqual(back.clientOutput, .singlePDF)
        XCTAssertEqual(back.revisionOneLength, 1234)
    }
}
