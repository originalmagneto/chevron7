// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7TestSupport
import Foundation
import XCTest
@testable import Chevron7App
@testable import Chevron7Kit

@MainActor
final class RecordingNotifier: RecordFirstNotifying {
    var authorizationRequests = 0
    var processed: [UUID] = []
    var rejected: [(UUID, Int?, String?)] = []

    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func recordProcessed(_ pending: RecordFirstPending) { processed.append(pending.recordID) }
    func recordRejected(_ pending: RecordFirstPending, code: Int?, description: String?) {
        rejected.append((pending.recordID, code, description))
    }
}

@MainActor
final class RecordFirstWatcherTests: XCTestCase {
    private var evidenceStore: LocalEvidenceStore!
    private var pendingStore: RecordFirstPendingStore!
    private var notifier: RecordingNotifier!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var submits: [UUID] = []
    private var verifies: [UUID] = []
    /// What a lookup or send does to the row.
    private var onCall: (UUID) -> Void = { _ in }
    private var submitResult: EZZKStatusChecker.RowResult?
    private var busy: Set<UUID> = []

    override func setUp() async throws {
        let root = makeTemporaryDirectory("watcher")
        evidenceStore = LocalEvidenceStore(directory: root)
        pendingStore = RecordFirstPendingStore(directory: RecordFirstPendingStore.directory(inStorageRoot: root))
        notifier = RecordingNotifier()
    }

    private func makeWatcher() -> RecordFirstWatcher {
        RecordFirstWatcher(
            pendingStore: pendingStore, evidenceStore: evidenceStore,
            submit: { [unowned self] id in
                submits.append(id)
                onCall(id)
                return submitResult ?? .row(evidenceStore.record(id: id)!)
            },
            verify: { [unowned self] id in
                verifies.append(id)
                onCall(id)
                return .row(evidenceStore.record(id: id)!)
            },
            isBusy: { [unowned self] in busy.contains($0) },
            notifier: notifier,
            now: { [unowned self] in clock })
    }

    @discardableResult
    private func seed(status: EvidenceRecord.Status, stage: RecordFirstPending.Stage = .awaitingEZZK) throws -> UUID {
        let id = UUID()
        evidenceStore.upsert(EvidenceRecord(
            id: id, createdAt: clock, status: status, direction: .paperToElectronic, originalName: "Zmluva",
            newDocumentName: "Zmluva.pdf", evidenceNumber: "1563-261119-1", fingerprintSHA256Hex: "ab",
            attestationXML: "<x/>", conversionTime: clock, performingPersonName: "JUDr. Test Testovací",
            securityElementCount: 0, totalPages: 1, totalSheets: 1, ezzkMode: .test,
            evidenceNumberAllocatedAt: clock))
        try pendingStore.save(RecordFirstPendingStoreTests.samplePending(id: id, signedAt: clock, stage: stage))
        return id
    }

    private func setStatus(_ id: UUID, _ status: EvidenceRecord.Status, code: Int? = nil, text: String? = nil) {
        var row = evidenceStore.record(id: id)!
        row.status = status
        row.ezzkResultCode = code
        row.ezzkResultDescription = text
        evidenceStore.upsert(row)
    }

    func testIntervalSchedule() {
        let signed = Date(timeIntervalSince1970: 0)
        func at(_ seconds: TimeInterval) -> TimeInterval? {
            RecordFirstWatcher.checkInterval(signedAt: signed, now: signed.addingTimeInterval(seconds))
        }
        XCTAssertEqual(at(0), 30)
        XCTAssertEqual(at(29 * 60), 30)
        XCTAssertEqual(at(31 * 60), 120)
        XCTAssertEqual(at(23 * 3600), 120)
        XCTAssertNil(at(25 * 3600))
    }

    func testProcessedMovesStageAndNotifiesOnce() async throws {
        let id = try seed(status: .acceptedForProcessing)
        onCall = { [unowned self] in setStatus($0, .processed) }
        let watcher = makeWatcher()

        await watcher.runOnce()
        clock.addTimeInterval(60)
        await watcher.runOnce()

        XCTAssertEqual(notifier.processed, [id])
        XCTAssertEqual(pendingStore.pending(id: id)?.stage, .signingClientContainer)
        XCTAssertEqual(verifies, [id], "a ready conversion is not looked up again")
    }

    func testRowMovedElsewhereIsNoticedWithoutACall() async throws {
        let id = try seed(status: .acceptedForProcessing)
        let watcher = makeWatcher()
        await watcher.runOnce()
        // The five-minute checker or "Overiť v EZZK" moved it, before this watcher was due.
        setStatus(id, .processed)
        clock.addTimeInterval(5)

        await watcher.runOnce()

        XCTAssertEqual(notifier.processed, [id])
        XCTAssertEqual(verifies.count, 1)
    }

    func testRejectedNotifiesWithCodeAndDropsPending() async throws {
        let id = try seed(status: .acceptedForProcessing)
        onCall = { [unowned self] in setStatus($0, .rejected, code: 12, text: "Neznámy obsah") }

        await makeWatcher().runOnce()

        XCTAssertEqual(notifier.rejected.map(\.0), [id])
        XCTAssertEqual(notifier.rejected.first?.1, 12)
        XCTAssertEqual(notifier.rejected.first?.2, "Neznámy obsah")
        XCTAssertNil(pendingStore.pending(id: id))
        XCTAssertNotNil(evidenceStore.record(id: id), "the row stays in the Register")
    }

    func testSignedRowIsSubmittedOnce() async throws {
        let id = try seed(status: .signed)
        let watcher = makeWatcher()

        await watcher.runOnce()
        clock.addTimeInterval(60)
        await watcher.runOnce()

        XCTAssertEqual(submits, [id], "further sends are the status checker's")
        XCTAssertTrue(notifier.processed.isEmpty)
    }

    func testFailedSendIsLeftToTheStatusChecker() async throws {
        try seed(status: .submissionFailed)

        await makeWatcher().runOnce()

        XCTAssertTrue(submits.isEmpty)
        XCTAssertTrue(verifies.isEmpty)
    }

    func testMissingRowDropsPendingSilently() async throws {
        let id = try seed(status: .acceptedForProcessing)
        evidenceStore.delete(id: id)

        await makeWatcher().runOnce()

        XCTAssertNil(pendingStore.pending(id: id))
        XCTAssertTrue(notifier.processed.isEmpty)
        XCTAssertTrue(notifier.rejected.isEmpty)
    }

    func testRefusedSubmitIsRetriedLaterWithoutNotification() async throws {
        // Another EZZK mode is current: the checker refuses to send.
        let id = try seed(status: .signed)
        submitResult = .refused(EZZKStatusChecker.recordFromOtherModeMessage)

        await makeWatcher().runOnce()

        XCTAssertEqual(submits, [id])
        XCTAssertEqual(pendingStore.pending(id: id)?.stage, .awaitingEZZK)
        XCTAssertTrue(notifier.processed.isEmpty && notifier.rejected.isEmpty)
    }

    func testNotDueAgainBeforeInterval() async throws {
        let id = try seed(status: .acceptedForProcessing)
        let watcher = makeWatcher()

        await watcher.runOnce()
        clock.addTimeInterval(10)
        await watcher.runOnce()
        clock.addTimeInterval(25)
        await watcher.runOnce()

        XCTAssertEqual(verifies, [id, id])
    }

    func testAfterADayOnlyTheRowIsWatched() async throws {
        let id = try seed(status: .acceptedForProcessing)
        clock.addTimeInterval(25 * 3600)
        let watcher = makeWatcher()

        await watcher.runOnce()
        XCTAssertTrue(verifies.isEmpty)

        setStatus(id, .processed)
        await watcher.runOnce()
        XCTAssertEqual(notifier.processed, [id], "the hourly check's result is still announced")
    }

    func testBusyConversionIsLeftToZaKo() async throws {
        let id = try seed(status: .acceptedForProcessing)
        setStatus(id, .processed)
        busy = [id]

        await makeWatcher().runOnce()

        XCTAssertTrue(verifies.isEmpty)
        XCTAssertTrue(notifier.processed.isEmpty)
        XCTAssertEqual(pendingStore.pending(id: id)?.stage, .awaitingEZZK)
    }
}
