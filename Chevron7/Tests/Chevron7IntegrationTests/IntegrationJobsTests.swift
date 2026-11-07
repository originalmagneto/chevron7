import Foundation
import XCTest
@testable import Chevron7Integration

final class IntegrationJobsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chevron7-jobs-test-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testIdempotencyIsOwnerScopedAndRejectsChangedContent() throws {
        let store = try IntegrationJobStore(directory: root)
        let first = try store.begin(owner: "A", key: "request", fingerprint: "hash-A", reservedBytes: 1)
        let duplicate = try store.begin(owner: "A", key: "request", fingerprint: "hash-A", reservedBytes: 1)
        XCTAssertTrue(first.isNew)
        XCTAssertFalse(duplicate.isNew)
        XCTAssertEqual(first.job.id, duplicate.job.id)
        assertCode("IDEMPOTENCY_CONFLICT") { _ = try store.begin(owner: "A", key: "request", fingerprint: "hash-B") }
        let independent = try store.begin(owner: "B", key: "request", fingerprint: "hash-A", reservedBytes: 1)
        XCTAssertNotEqual(first.job.id, independent.job.id)
        assertCode("JOB_UNKNOWN") { _ = try store.get(id: first.job.id, owner: "B") }
        assertCode("JOB_UNKNOWN") { _ = try store.update(id: first.job.id, owner: "B", state: .cancelled) }
        assertCode("JOB_UNKNOWN") { _ = try store.directory(for: first.job.id, owner: "B") }
        XCTAssertNil(first.job.json["owner"])
        XCTAssertNil(first.job.json["session"])
    }

    func testTerminalResultsAreRepeatedAndLateCompletionCannotUndoCancellation() throws {
        let store = try IntegrationJobStore(directory: root)
        let job = try store.begin(owner: "owner", fingerprint: "hash").job
        try store.update(id: job.id, owner: "owner", state: .signing)
        try store.update(id: job.id, owner: "owner", state: .cancelled)
        try store.update(id: job.id, owner: "owner", state: .completed, result: .string("late"))
        XCTAssertEqual(try store.get(id: job.id, owner: "owner").state, .cancelled)
        XCTAssertEqual(try store.get(id: job.id, owner: "owner").state, .cancelled)
        assertCode("INVALID_REQUEST") { _ = try store.recordDelivery(id: job.id, owner: "owner", result: .string("late")) }
        let completed = try store.begin(owner: "owner", fingerprint: "another").job
        try store.update(id: completed.id, owner: "owner", state: .completed, result: .string("first result"))
        try store.update(id: completed.id, owner: "owner", state: .completed, result: .string("late overwrite"))
        XCTAssertEqual(try store.get(id: completed.id, owner: "owner").result, .string("first result"))
    }

    func testDeliveryRetryDoesNotCreateAnotherJobOrExtendTTL() throws {
        let clock = TestClock()
        let store = try IntegrationJobStore(directory: root, ttl: 30, clock: { clock.now })
        let job = try store.begin(owner: "owner", fingerprint: "hash").job
        try store.update(id: job.id, owner: "owner", state: .failed,
                         error: IntegrationError(code: "OUTPUT_DELIVERY_FAILED", message: "cannot write"))
        clock.advance(20)
        let result = try store.recordDelivery(id: job.id, owner: "owner", result: .string("saved"))
        XCTAssertEqual(result.state, .completed)
        XCTAssertNil(result.error)
        XCTAssertEqual(store.retainedCount, 1)
        clock.advance(11)
        assertCode("JOB_EXPIRED") { _ = try store.get(id: job.id, owner: "owner") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCapacityNeverEvictsActiveJobsAndTTLOnlyExpiresTerminalJobs() throws {
        let clock = TestClock()
        let store = try IntegrationJobStore(directory: root, maxJobs: 2, maxBytes: 10, ttl: 5, clock: { clock.now })
        let active = try store.begin(owner: "owner", fingerprint: "active", reservedBytes: 6).job
        assertCode("CAPACITY_EXCEEDED") { _ = try store.begin(owner: "owner", fingerprint: "too-big", reservedBytes: 5) }
        let terminal = try store.begin(owner: "owner", fingerprint: "terminal", reservedBytes: 4).job
        try store.update(id: terminal.id, owner: "owner", state: .completed)
        clock.advance(6)
        store.purgeExpired()
        XCTAssertEqual(store.reservedByteCount, 6)
        XCTAssertEqual(try store.get(id: active.id, owner: "owner").state, .awaitingConfirmation)
        assertCode("JOB_EXPIRED") { _ = try store.get(id: terminal.id, owner: "owner") }
        _ = try store.begin(owner: "owner", fingerprint: "replacement", reservedBytes: 4)
        XCTAssertEqual(store.retainedCount, 2)
    }

    func testSessionCloseLeavesOtherOwnersAndReturnsOnlyOwnedActiveJobs() throws {
        let store = try IntegrationJobStore(directory: root)
        let active = try store.begin(owner: "A", fingerprint: "one", reservedBytes: 1).job
        let completed = try store.begin(owner: "A", fingerprint: "two", reservedBytes: 1).job
        let other = try store.begin(owner: "B", fingerprint: "three", reservedBytes: 1).job
        try store.update(id: completed.id, owner: "A", state: .completed)
        XCTAssertEqual(store.closeSession(owner: "A"), [active.id])
        assertCode("JOB_UNKNOWN") { _ = try store.get(id: completed.id, owner: "A") }
        XCTAssertEqual(try store.get(id: other.id, owner: "B").id, other.id)
        XCTAssertEqual(try store.get(id: active.id, owner: "A").id, active.id)
    }

    func testTerminalJobsReleaseUnusedReservationForFurtherSmallSignatures() throws {
        let store = try IntegrationJobStore(directory: root, maxJobs: 10, maxBytes: 100)
        for index in 0..<5 {
            let job = try store.begin(owner: "owner", fingerprint: "signature-\(index)", reservedBytes: 87).job
            let directory = try store.directory(for: job.id, owner: "owner")
            try Data([UInt8(index)]).write(to: directory.appendingPathComponent("signed-output"))
            try store.update(id: job.id, owner: "owner", state: .completed)
        }
        XCTAssertEqual(store.retainedCount, 5)
        XCTAssertEqual(store.reservedByteCount, 5)
        let cancelled = try store.begin(owner: "owner", fingerprint: "cancel", reservedBytes: 87).job
        try store.update(id: cancelled.id, owner: "owner", state: .cancelled)
        XCTAssertEqual(store.reservedByteCount, 5)
    }

    func testTerminalAccountingCannotExceedReservationOrFollowSymlink() throws {
        let store = try IntegrationJobStore(directory: root, maxBytes: 100)
        let job = try store.begin(owner: "owner", fingerprint: "hash", reservedBytes: 5).job
        let directory = try store.directory(for: job.id, owner: "owner")
        let output = directory.appendingPathComponent("signed-output")
        try Data(repeating: 0, count: 6).write(to: output)
        assertCode("CAPACITY_EXCEEDED") { _ = try store.update(id: job.id, owner: "owner", state: .completed) }
        XCTAssertEqual(store.reservedByteCount, 5)
        XCTAssertEqual(try store.get(id: job.id, owner: "owner").state, .awaitingConfirmation)
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: root)
        assertCode("FILE_ACCESS") { _ = try store.update(id: job.id, owner: "owner", state: .completed) }
    }

    func testRestartRemovesOrphanedBytesWithoutPretendingToRecoverOutcome() throws {
        let store = try IntegrationJobStore(directory: root)
        let job = try store.begin(owner: "owner", fingerprint: "hash").job
        let directory = try store.directory(for: job.id, owner: "owner")
        try Data("signed bytes".utf8).write(to: directory.appendingPathComponent("signed.pdf"))
        let restarted = try IntegrationJobStore(directory: root)
        assertCode("JOB_UNKNOWN") { _ = try restarted.get(id: job.id, owner: "owner") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let mode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
