// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import XCTest
@testable import Chevron7Kit
@testable import Chevron7App

final class DetectorTrainingOverviewTests: XCTestCase {
    private let reviewedAt = Date(timeIntervalSince1970: 1_000_000)

    /// `pages` pages spread over `documents` documents; the boxes sit on the first page.
    private func report(pages: Int, documents: Int, boxes: [SecurityElement.Kind: Int] = [:],
                        lastRunAt: Date? = nil, learnOn: Bool = true, offersEnabled: Bool = true,
                        snoozedUntil: Date? = nil, now: Date = Date(timeIntervalSince1970: 2_000_000))
        -> DetectorTrainingReadiness {
        let pageList = (0..<pages).map { index in
            ReviewedBankPage(
                documentSHA256: "doc\(index % max(documents, 1))", pageIndex: index,
                boxes: index == 0 ? boxes.flatMap { kind, count in
                    Array(repeating: ReviewedPageBox(kind: kind, box: .init(x: 0, y: 0, width: 0.1, height: 0.1)),
                          count: count)
                } : [],
                reviewedAt: reviewedAt, detectorVersion: "t")
        }
        return DetectorTrainingReadiness.report(pages: pageList, lastRunAt: lastRunAt, learnOn: learnOn,
                                                offersEnabled: offersEnabled, snoozedUntil: snoozedUntil,
                                                now: now)
    }

    private func overview(_ report: DetectorTrainingReadiness, trainedBefore: Bool = false,
                          learnOn: Bool = true, offersEnabled: Bool = true,
                          snoozedUntil: Date? = nil) -> DetectorTrainingOverview {
        DetectorTrainingOverview.make(report: report, trainedBefore: trainedBefore, learnOn: learnOn,
                                      offersEnabled: offersEnabled, snoozedUntil: snoozedUntil,
                                      now: Date(timeIntervalSince1970: 2_000_000))
    }

    func testFirstRunMissingPagesAndDocumentsSaysBothWithRequirementOnTop() {
        let o = overview(report(pages: 20, documents: 5))
        XCTAssertEqual(o.readiness, .missing)
        XCTAssertEqual(o.headline, "Na prvé trénovanie chýba 20 strán a 3 dokumenty")
        XCTAssertEqual(o.requirement, "Na prvé trénovanie treba 40 strán aspoň z 8 dokumentov.")
        XCTAssertEqual(o.meters.map(\.valueText), ["20 z 40", "5 z 8"])
        XCTAssertEqual(o.meters.map(\.isMet), [false, false])
        XCTAssertEqual(o.continueBlockedReason, "Pokračovať sa dá po 40 stranách z 8 dokumentov.")
    }

    func testSlovakAgreementForOneFewAndMany() {
        XCTAssertEqual(overview(report(pages: 39, documents: 8)).headline,
                       "Na prvé trénovanie chýba 1 strana")
        XCTAssertEqual(overview(report(pages: 38, documents: 8)).headline,
                       "Na prvé trénovanie chýbajú 2 strany")
        XCTAssertEqual(overview(report(pages: 35, documents: 8)).headline,
                       "Na prvé trénovanie chýba 5 strán")
    }

    func testOnlyDocumentsShort() {
        let o = overview(report(pages: 45, documents: 6))
        XCTAssertEqual(o.headline, "Na prvé trénovanie chýbajú 2 dokumenty")
        XCTAssertEqual(o.meters.map(\.isMet), [true, false])
    }

    func testReadyWhenOfferIsDue() {
        let o = overview(report(pages: 40, documents: 8))
        XCTAssertEqual(o.readiness, .ready)
        XCTAssertEqual(o.headline, "Pripravené na trénovanie")
        XCTAssertNil(o.continueBlockedReason)
    }

    func testGateMetButHeldNamesTheReasonAndNeverSaysReady() {
        let learnOff = overview(report(pages: 40, documents: 8, learnOn: false), learnOn: false)
        XCTAssertEqual(learnOff.readiness, .held)
        XCTAssertNotEqual(learnOff.headline, "Pripravené na trénovanie")
        XCTAssertEqual(learnOff.continueBlockedReason,
                       "Učenie z kontrol je vypnuté. Zapnite ho v Nastaveniach, AI a učenie.")

        let offersOff = overview(report(pages: 40, documents: 8, offersEnabled: false), offersEnabled: false)
        XCTAssertEqual(offersOff.readiness, .held)
        XCTAssertTrue(offersOff.continueBlockedReason?.hasPrefix("Pripomínanie trénovania je vypnuté.") == true)

        let until = Date(timeIntervalSince1970: 2_500_000)
        let snoozed = overview(report(pages: 40, documents: 8, snoozedUntil: until), snoozedUntil: until)
        XCTAssertEqual(snoozed.readiness, .held)
        XCTAssertTrue(snoozed.continueBlockedReason?.hasPrefix("Trénovanie ste odložili do ") == true)
    }

    func testRetrainCountsNewPagesOnly() {
        let lastRun = Date(timeIntervalSince1970: 500_000)
        let r = report(pages: 12, documents: 2, lastRunAt: lastRun)
        let o = overview(r, trainedBefore: true)
        XCTAssertEqual(o.readiness, .missing)
        XCTAssertEqual(o.headline, "Na ďalšie trénovanie chýba 8 nových strán")
        XCTAssertEqual(o.requirement,
                       "Na ďalšie trénovanie treba 20 nových skontrolovaných strán od posledného trénovania.")
        XCTAssertEqual(o.meters.map(\.valueText), ["12 z 20"])
        XCTAssertEqual(o.continueBlockedReason, "Pokračovať sa dá po 20 nových stranách.")
    }

    func testKindRowsCarryCountTargetAndShortState() {
        let o = overview(report(pages: 10, documents: 2,
                                boxes: [.officialStamp: 20, .handwrittenSignature: 9, .waxSeal: 1]))
        let byLabel = Dictionary(uniqueKeysWithValues: o.kinds.map { ($0.trainingLabel, $0) })
        XCTAssertEqual(byLabel["officialStamp"]?.countText, "20/15")
        XCTAssertEqual(byLabel["officialStamp"]?.stateText, "stačí")
        XCTAssertEqual(byLabel["officialStamp"]?.symbol, "rosette")
        XCTAssertEqual(byLabel["handwrittenSignature"]?.stateText, "chýba 6")
        XCTAssertEqual(byLabel["waxSeal"]?.stateText, "chýba 14")
        // Learned kinds first, then the ones left out, each alphabetically by label.
        XCTAssertEqual(o.kinds.map(\.trainingLabel), ["officialStamp", "handwrittenSignature", "waxSeal"])
        XCTAssertEqual(o.kindsExplanation,
                       "Detektor sa naučí len druhy s aspoň 15 príkladmi, ostatné pri trénovaní vynechá.")
    }

    /// The overview of a typical bank fits the window's default content
    /// (680 x 600 minus the step bar, action bar and padding) without scrolling.
    @MainActor
    func testTypicalOverviewFitsDefaultWindowWithoutScrolling() {
        let kinds: [SecurityElement.Kind: Int] = [
            .officialStamp: 41, .handwrittenSignature: 35, .embossedSeal: 3, .initial: 9,
            .bindingCord: 2, .securityTape: 1, .waxSeal: 4, .watermark: 2, .other: 6,
        ]
        let o = overview(report(pages: 20, documents: 8, boxes: kinds))
        XCTAssertEqual(o.kinds.count, 9)
        let view = DetectorTrainingOverviewView(overview: o, onImport: {})
            .frame(width: 680 - 40)
        let host = NSHostingView(rootView: view)
        let height = host.fittingSize.height
        XCTAssertGreaterThan(height, 100)
        XCTAssertLessThanOrEqual(height, 440, "overview is \(height) pt tall")
    }
}
