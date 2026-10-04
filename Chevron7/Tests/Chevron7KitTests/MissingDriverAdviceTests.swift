// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7Kit

final class MissingDriverAdviceTests: XCTestCase {
    /// The owner's I.CA SAK card (STARCOS 3.7, historical bytes "XICA V2.0"), read 2026-10-04.
    private let icaStarcos37 = atrBytes("3BDA96FF81B1FE451F0780584943412056322E30E9")
    /// The same card with another applet version ("XICA V3.0"): the match must not
    /// depend on one exact ATR.
    private let icaOtherVersion = atrBytes("3BDA96FF81B1FE451F0780584943412056332E30E8")
    /// The owner's Slovak eID (IDEMIA Cosmo), read 2026-10-04.
    private let slovakEID = atrBytes("3BDF18FF81B1FE451F870031B96409377213738401E00000008E")
    private let unknownCard = atrBytes("3B8F8001804F0CA000000306030001000000006A")

    func testICACardsAreRecognisedByTheICAInTheirHistoricalBytes() {
        XCTAssertEqual(CardDriver.forCard(atr: icaStarcos37), .icaSecureStore)
        XCTAssertEqual(CardDriver.forCard(atr: icaOtherVersion), .icaSecureStore)
    }

    func testTheMeasuredSlovakEIDNeedsTheEIDClient() {
        XCTAssertEqual(CardDriver.forCard(atr: slovakEID), .eIDKlient)
    }

    func testAnUnknownCardHasNoDriver() {
        XCTAssertNil(CardDriver.forCard(atr: unknownCard))
        XCTAssertNil(CardDriver.forCard(atr: []))
    }

    func testAnICACardWithoutSecureStoreAsksForSecureStore() {
        let advice = MissingDriverAdvice.evaluate(cardATRs: [icaStarcos37], isInstalled: { _ in false })

        XCTAssertEqual(advice?.label, "Chýba ovládač karty")
        XCTAssertEqual(advice?.detail, "Karta I.CA je v čítačke")
        XCTAssertEqual(advice?.drivers, [.icaSecureStore])
    }

    func testAnEIDWithoutTheEIDClientAsksForTheEIDClient() {
        let advice = MissingDriverAdvice.evaluate(
            cardATRs: [slovakEID], isInstalled: { $0 == .icaSecureStore })

        XCTAssertEqual(advice?.detail, "Občiansky preukaz je v čítačke")
        XCTAssertEqual(advice?.drivers, [.eIDKlient])
    }

    func testAnInstalledDriverNeverRaisesAdvice() {
        // The engine polls every few seconds; a freshly inserted card it has not read yet
        // must not flash "missing driver" when its driver is there.
        XCTAssertNil(MissingDriverAdvice.evaluate(cardATRs: [icaStarcos37], isInstalled: { _ in true }))
        XCTAssertNil(MissingDriverAdvice.evaluate(
            cardATRs: [icaStarcos37], isInstalled: { $0 == .icaSecureStore }))
    }

    func testNoCardInTheReaderRaisesNoAdvice() {
        XCTAssertNil(MissingDriverAdvice.evaluate(cardATRs: [], isInstalled: { _ in false }))
    }

    func testAnUnknownCardOnAMacWithoutAnyDriverOffersEveryDriver() {
        let advice = MissingDriverAdvice.evaluate(cardATRs: [unknownCard], isInstalled: { _ in false })

        XCTAssertEqual(advice?.detail, "Karta je v čítačke")
        XCTAssertEqual(advice?.drivers, CardDriver.all)
    }

    func testAnUnknownCardIsLeftAloneOnceSomeDriverIsInstalled() {
        // It may be a card that driver reads; the engine decides.
        XCTAssertNil(MissingDriverAdvice.evaluate(
            cardATRs: [unknownCard], isInstalled: { $0 == .eIDKlient }))
    }

    func testAKnownCardMissingItsDriverWinsOverAnUnknownOne() {
        let advice = MissingDriverAdvice.evaluate(
            cardATRs: [unknownCard, icaStarcos37], isInstalled: { _ in false })

        XCTAssertEqual(advice?.drivers, [.icaSecureStore])
    }

    func testDriverPathsMatchTheEnginesMacDrivers() throws {
        // The engine loads these libraries (DefaultDriverDetector.getMacDrivers()); a path
        // that drifts would tell people to install a driver they already have.
        let detector = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/src/main/java/digital/slovensko/autogram/core/DefaultDriverDetector.java")
        let source = try String(contentsOf: detector, encoding: .utf8)
        for driver in CardDriver.all {
            XCTAssertTrue(source.contains("Path.of(\"\(driver.libraryPath)\")"), driver.name)
        }
    }
}

private func atrBytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
}
