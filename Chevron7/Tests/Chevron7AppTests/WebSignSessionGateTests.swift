// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7App

@MainActor
final class WebSignSessionGateTests: XCTestCase {
    private struct Cancelled: Error {}

    /// Opens a request on `gate` and returns its token plus the task awaiting its answer.
    private func openRequest(on gate: WebSignSessionGate<String>) async -> (UUID?, Task<String, Error>) {
        var token: UUID?
        let opened = expectation(description: "opened")
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                token = gate.open(continuation)
                opened.fulfill()
            }
        }
        await fulfillment(of: [opened], timeout: 2)
        return (token, task)
    }

    func testTheOpenRequestGetsItsOwnResult() async throws {
        let gate = WebSignSessionGate<String>()
        let (token, task) = await openRequest(on: gate)

        XCTAssertTrue(gate.close(token, with: .success("A")))
        let answer = try await task.value
        XCTAssertEqual(answer, "A")
        XCTAssertFalse(gate.isOpen)
    }

    /// Request A is cancelled, the page sends B, then A's signature finishes late:
    /// A's result must not answer B.
    func testALateResultOfACancelledRequestNeverReachesTheNextOne() async throws {
        let gate = WebSignSessionGate<String>()
        let (tokenA, taskA) = await openRequest(on: gate)
        XCTAssertTrue(gate.close(tokenA, with: .failure(Cancelled())))
        do {
            _ = try await taskA.value
            XCTFail("A was cancelled")
        } catch {
            XCTAssertTrue(error is Cancelled)
        }

        let (tokenB, taskB) = await openRequest(on: gate)
        XCTAssertNotNil(tokenB)
        XCTAssertNotEqual(tokenA, tokenB)

        XCTAssertFalse(gate.isCurrent(tokenA))
        XCTAssertFalse(gate.close(tokenA, with: .success("signed A")), "A's late result was delivered")
        XCTAssertTrue(gate.isOpen)

        XCTAssertTrue(gate.close(tokenB, with: .success("signed B")))
        let answer = try await taskB.value
        XCTAssertEqual(answer, "signed B")
    }

    func testASecondRequestIsRefusedWhileOneIsOpen() async throws {
        let gate = WebSignSessionGate<String>()
        let (token, task) = await openRequest(on: gate)

        var second: UUID?? = .none
        let refused = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                second = .some(gate.open(continuation))
                if case .some(nil) = second { continuation.resume(throwing: Cancelled()) }
            }
        }
        do {
            _ = try await refused.value
            XCTFail("the second request was opened")
        } catch {
            XCTAssertTrue(error is Cancelled)
        }
        XCTAssertEqual(second, .some(nil))
        XCTAssertTrue(gate.isCurrent(token))

        gate.close(token, with: .success("A"))
        _ = try await task.value
    }

    func testARequestIsAnsweredOnce() async throws {
        let gate = WebSignSessionGate<String>()
        let (token, task) = await openRequest(on: gate)

        XCTAssertTrue(gate.close(token, with: .success("first")))
        XCTAssertFalse(gate.close(token, with: .success("second")))
        let answer = try await task.value
        XCTAssertEqual(answer, "first")
    }
}
