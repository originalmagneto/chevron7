// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation
import XCTest
@testable import Chevron7App

@MainActor
final class RecordFirstPendingPresentationTests: XCTestCase {
    func testStatesOnlyForTheMatchingRowState() {
        XCTAssertEqual(RecordFirstPendingPresentation.state(stage: .awaitingEZZK, rowStatus: .acceptedForProcessing)?.label,
                       "Čaká na EZZK")
        XCTAssertEqual(RecordFirstPendingPresentation.state(stage: .awaitingEZZK, rowStatus: .outcomeUnknown)?.symbol,
                       "hourglass")
        XCTAssertEqual(RecordFirstPendingPresentation.state(stage: .signingClientContainer, rowStatus: .processed)?.label,
                       "Čaká na podpis doložky")
        XCTAssertNil(RecordFirstPendingPresentation.state(stage: .awaitingEZZK, rowStatus: .late))
        XCTAssertNil(RecordFirstPendingPresentation.state(stage: .awaitingEZZK, rowStatus: .signed))
    }

    func testNotificationTextsNameNumberAndDocument() {
        let pending = RecordFirstPendingStoreTests.samplePending(number: "1563-261119-7")
        let processed = RecordFirstPendingPresentation.processedNotification(pending)
        let rejected = RecordFirstPendingPresentation.rejectedNotification(pending, code: 12, description: "Neznámy obsah")

        XCTAssertEqual(processed.title, "EZZK spracovalo záznam č. 1563-261119-7")
        XCTAssertTrue(processed.body.hasPrefix("Zmluva o dielo:"))
        XCTAssertEqual(rejected.title, "EZZK odmietlo záznam č. 1563-261119-7")
        XCTAssertTrue(rejected.body.contains("kód 12: Neznámy obsah"))
        for text in [processed.title, processed.body, rejected.title, rejected.body,
                     ZakoSessionStore.recordFirstSentInBackgroundMessage] {
            XCTAssertFalse(text.contains("\u{2014}"), "no em dash: \(text)")
        }
    }
}
