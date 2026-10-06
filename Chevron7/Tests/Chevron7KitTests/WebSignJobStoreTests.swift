// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
@testable import Chevron7Kit

/// Safari ends a web extension's background after about 30 seconds, so a signing
/// reply that waits for the PIN or the phone is lost. The page starts a job and
/// polls it instead; this store is what the polling reads.
final class WebSignJobStoreTests: XCTestCase {
    func testJobIsPendingUntilFinished() {
        let store = WebSignJobStore()
        let id = store.begin()

        XCTAssertEqual(store.take(id), .pending)
        XCTAssertEqual(store.take(id), .pending, "Reading a pending job must not consume it.")
    }

    func testFinishedJobIsDeliveredOnce() {
        let store = WebSignJobStore()
        let id = store.begin()
        store.finish(id, response: Data("ok".utf8), error: nil)

        XCTAssertEqual(store.take(id), .finished(response: Data("ok".utf8), error: nil))
        XCTAssertEqual(store.take(id), .unknown)
    }

    func testFailedJobCarriesTheError() {
        let store = WebSignJobStore()
        let id = store.begin()
        store.finish(id, response: nil, error: "Podpisovanie ste zrušili.")

        XCTAssertEqual(store.take(id), .finished(response: nil, error: "Podpisovanie ste zrušili."))
    }

    func testUnknownJobIsReported() {
        XCTAssertEqual(WebSignJobStore().take("missing"), .unknown)
    }

    func testFinishedJobsNobodyCollectedExpire() {
        let clock = TestClock()
        let store = WebSignJobStore(lifetime: 60, clock: { clock.now })
        let abandoned = store.begin()
        store.finish(abandoned, response: Data(), error: nil)

        clock.now = clock.now.addingTimeInterval(61)
        _ = store.begin()

        XCTAssertEqual(store.take(abandoned), .unknown)
    }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 0)
}
