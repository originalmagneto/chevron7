// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Integration
@testable import Chevron7App

@MainActor
final class IntegrationValidationBrokerTests: XCTestCase {
    func testCancelledActiveOperationKeepsItsSlotUntilItActuallyReturns() async throws {
        let broker = IntegrationValidationBroker()
        let gate = ValidationTestGate()
        var secondStarted = false
        let first = Task { try await broker.run { await gate.wait(); return 1 } }
        await waitUntil { gate.started }
        let second = Task { try await broker.run { secondStarted = true; return 2 } }
        first.cancel()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(secondStarted)
        gate.release()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await second.value
        XCTAssertEqual(result, 2)
    }

    func testCancellingQueuedRequestNeverStartsItOrCancelsActiveRequest() async throws {
        let broker = IntegrationValidationBroker()
        let gate = ValidationTestGate()
        let first = Task { try await broker.run { await gate.wait(); return 1 } }
        await waitUntil { gate.started }
        var queuedStarted = false
        let queued = Task { try await broker.run { queuedStarted = true; return 2 } }
        for _ in 0..<20 { await Task.yield() }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(queuedStarted)
        XCTAssertFalse(first.isCancelled)
        gate.release()
        let result = try await first.value
        XCTAssertEqual(result, 1)
    }

    func testQueueIsBounded() async throws {
        let broker = IntegrationValidationBroker(maximumWaiting: 0)
        let gate = ValidationTestGate()
        let active = Task { try await broker.run { await gate.wait() } }
        await waitUntil { gate.started }
        do { _ = try await broker.run { 2 }; XCTFail("Expected busy") }
        catch { XCTAssertEqual((error as? IntegrationError)?.code, "BUSY") }
        gate.release()
        try await active.value
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Operation did not start")
    }
}

@MainActor
private final class ValidationTestGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            started = true
            self.continuation = continuation
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
