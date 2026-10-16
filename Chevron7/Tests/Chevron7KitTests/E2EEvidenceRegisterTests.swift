// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

final class E2EEvidenceRegisterTests: XCTestCase {
    private func record() -> EvidenceRecord {
        EvidenceRecord(status: .signed, direction: .electronicToElectronic, originalName: "zmluva.pdf",
                       newDocumentName: "zmluva.pdf", evidenceNumber: "1563-261016-7", fingerprintSHA256Hex: "ab",
                       attestationXML: "<x/>", conversionTime: Date(), performingPersonName: "M",
                       securityElementCount: 0, totalPages: 0, totalSheets: 0)
    }

    func testValidationEvidenceIsStoredUnderValidationFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalEvidenceStore(directory: directory)
        var row = record()
        row.validationEvidencePath = try store.storeValidationEvidence(Data("<ValidationReport/>".utf8),
                                                                       fileExtension: "xml", for: row.id)
        row.validationEvidenceSource = "Chevron7 (DSS 6.4)"
        store.upsert(row)

        XCTAssertEqual(row.validationEvidencePath, "validation/\(row.id.uuidString).xml")
        let loaded = try XCTUnwrap(LocalEvidenceStore(directory: directory).record(id: row.id))
        XCTAssertEqual(loaded.direction, .electronicToElectronic)
        XCTAssertEqual(loaded.validationEvidenceSource, "Chevron7 (DSS 6.4)")
        XCTAssertEqual(store.validationEvidenceData(for: loaded), Data("<ValidationReport/>".utf8))
    }

    func testValidationEvidenceRefusesPathEscapingItsFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalEvidenceStore(directory: directory)
        var row = record()
        row.validationEvidencePath = "../Evidence/register.json"
        XCTAssertNil(store.validationEvidenceData(for: row))
    }

    func testOldRegisterRowsDecodeWithoutE2EFields() throws {
        let json = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":"2026-09-20T10:00:00Z","updatedAt":"2026-09-20T10:00:00Z",
         "status":"Vo fronte odoslania","direction":"P→E","originalName":"a","newDocumentName":"a.pdf",
         "evidenceNumber":"1563-260920-1","fingerprintSHA256Hex":"ab","attestationXML":"<x/>","conversionTime":"2026-09-20T10:00:00Z",
         "performingPersonName":"M","securityElementCount":1,"totalPages":1,"totalSheets":1}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(EvidenceRecord.self, from: Data(json.utf8))
        XCTAssertNil(row.validationEvidencePath)
        XCTAssertNil(row.validationEvidenceSource)
    }
}
