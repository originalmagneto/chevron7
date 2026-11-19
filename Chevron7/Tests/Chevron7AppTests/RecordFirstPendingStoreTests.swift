// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7TestSupport
import Foundation
import XCTest
@testable import Chevron7App
@testable import Chevron7Kit

@MainActor
final class RecordFirstPendingStoreTests: XCTestCase {
    static func samplePending(id: UUID = UUID(), signedAt: Date = Date(),
                              stage: RecordFirstPending.Stage = .awaitingEZZK,
                              number: String = "1563-261119-1") -> RecordFirstPending {
        var attestation = AttestationData(performingPerson: .empty)
        attestation.originalDocumentName = "Zmluva o dielo"
        attestation.evidenceNumber = number
        return RecordFirstPending(
            recordID: id, stage: stage, recordSignedAt: signedAt,
            direction: .paperToElectronic, originalFingerprints: nil,
            mode: .test, evidenceNumber: number, conversionTime: signedAt,
            finalPDF: Data("%PDF-1.7 final".utf8), fingerprint: "ab",
            containerDocumentName: "Zmluva o dielo.pdf",
            containerFiles: [ASiCEPackager.Entry(path: "1563.xml.xdcf", data: Data("<xdc/>".utf8))],
            directory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            stampsSignatures: true, timestampServers: ["https://tsa.example"], tsaURL: nil,
            attestation: attestation, clientOutput: .singlePDF,
            appendedClause: AppendedClause(pages: Data("%PDF pages".utf8), attachment: Data("<xdc/>".utf8),
                                           attachmentName: "1563.xml.xdcf"),
            fixedTarget: URL(fileURLWithPath: "/tmp/out/Zmluva o dielo.pdf"),
            clientTimestampServers: ["https://bosa.example"], clientTSAURL: nil)
    }

    func testSavedPendingSurvivesReload() throws {
        let directory = makeTemporaryDirectory("pending-store")
        let pending = Self.samplePending()
        try RecordFirstPendingStore(directory: directory).save(pending)

        let reloaded = RecordFirstPendingStore(directory: directory)

        XCTAssertEqual(reloaded.pending(id: pending.recordID), pending)
        XCTAssertEqual(reloaded.all.count, 1)
    }

    func testRemoveDeletesFile() throws {
        let directory = makeTemporaryDirectory("pending-store-remove")
        let store = RecordFirstPendingStore(directory: directory)
        let pending = Self.samplePending()
        try store.save(pending)

        store.remove(id: pending.recordID)

        XCTAssertNil(store.pending(id: pending.recordID))
        XCTAssertTrue(RecordFirstPendingStore(directory: directory).all.isEmpty)
    }

    func testUndecodableFileIsSkipped() throws {
        let directory = makeTemporaryDirectory("pending-store-garbage")
        let garbage = directory.appendingPathComponent("\(UUID().uuidString).plist")
        try Data("not a plist".utf8).write(to: garbage)

        let store = RecordFirstPendingStore(directory: directory)

        XCTAssertTrue(store.all.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: garbage.path), "never deleted")
    }

    func testAllIsSortedBySignedTime() throws {
        let store = RecordFirstPendingStore(directory: makeTemporaryDirectory("pending-store-order"))
        let later = Self.samplePending(signedAt: Date(timeIntervalSince1970: 2_000))
        let earlier = Self.samplePending(signedAt: Date(timeIntervalSince1970: 1_000))
        try store.save(later)
        try store.save(earlier)

        XCTAssertEqual(store.all.map(\.recordID), [earlier.recordID, later.recordID])
    }

    func testFailedWriteKeepsThePendingInMemory() throws {
        let file = makeTemporaryDirectory("pending-store-blocked").appendingPathComponent("blocker")
        try Data().write(to: file)
        // A file where the folder should be: the write fails.
        let store = RecordFirstPendingStore(directory: file)
        let pending = Self.samplePending()

        XCTAssertThrowsError(try store.save(pending))
        XCTAssertEqual(store.pending(id: pending.recordID), pending)
    }
}
