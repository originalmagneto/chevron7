// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

final class SettingsLearningCardTests: XCTestCase {
    func testCellsListCountsPerKindGroupInSlovak() {
        let cells = LearningCardText.cells(counts: [
            .kind(.officialStamp): 12, .kind(.handwrittenSignature): 7, .negative: 3,
            .kind(.watermark): 1, .kind(.lamination): 2])
        XCTAssertEqual(cells.map(\.title),
                       ["Pečiatky", "Podpisy", "Slepotlač", "Parafy", "Šnúrky", "Pásky", "Pečate", "Ochranné prvky", "Iné"])
        XCTAssertEqual(cells.map(\.count), [12, 7, 0, 0, 0, 0, 0, 3, 0])
    }

    func testRejectedCountIsApartFromTheGrid() {
        let counts: [BankLabel: Int] = [.kind(.officialStamp): 4, .negative: 3]
        XCTAssertEqual(LearningCardText.rejected(counts: counts), 3)
        XCTAssertFalse(LearningCardText.cells(counts: counts).contains { $0.title == "Zamietnuté" })
    }

    func testRowsSplitIntoThreeColumns() {
        let rows = LearningCardText.rows(counts: [:])
        XCTAssertEqual(rows.map(\.count), [3, 3, 3])
        XCTAssertEqual(rows.first?.map(\.title), ["Pečiatky", "Podpisy", "Slepotlač"])
    }

    func testSpokenSummaryNamesEveryCount() {
        XCTAssertEqual(LearningCardText.summary(counts: [.kind(.officialStamp): 12, .negative: 3]),
                       "Pečiatky: 12, Podpisy: 0, Slepotlač: 0, Parafy: 0, Šnúrky: 0, Pásky: 0, Pečate: 0, Ochranné prvky: 0, Iné: 0, Zamietnuté: 3")
    }
}
