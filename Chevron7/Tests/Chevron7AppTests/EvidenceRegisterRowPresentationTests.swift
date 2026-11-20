// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

/// The Register's columns (2026-11-20): direction, client output, the EZZK deadline (never a
/// repeat of the state) and "Dokončiť" for a conversion waiting for its clause signature.
final class EvidenceRegisterRowPresentationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z")!

    private func row(_ status: EvidenceRecord.Status, mode: AppSettings.EZZKMode = .test,
                     direction: ConversionDirection = .paperToElectronic,
                     output: AppSettings.ZakoClientOutput? = nil,
                     conversionTime: Date? = nil) -> EvidenceRecord {
        var record = EvidenceRecord(createdAt: now, status: status, direction: direction, originalName: "Zmluva",
                                    newDocumentName: "Zmluva.pdf", evidenceNumber: "1563-260924-1",
                                    fingerprintSHA256Hex: "ab", attestationXML: "<x/>",
                                    conversionTime: conversionTime ?? now, performingPersonName: "JUDr. Test",
                                    securityElementCount: 0, totalPages: 1, totalSheets: 1, ezzkMode: mode,
                                    evidenceNumberAllocatedAt: conversionTime ?? now)
        record.clientOutput = output
        return record
    }

    func testDirectionLabels() {
        XCTAssertEqual(EvidenceRegisterRowPresentation.direction(.paperToElectronic).text, "P→E")
        XCTAssertEqual(EvidenceRegisterRowPresentation.direction(.electronicToElectronic).text, "E→E")
        XCTAssertEqual(EvidenceRegisterRowPresentation.direction(.electronicToPaper).text, "E→P")
        for direction in ConversionDirection.allCases {
            XCTAssertFalse(EvidenceRegisterRowPresentation.direction(direction).symbol.isEmpty)
            XCTAssertFalse(EvidenceRegisterRowPresentation.directionHelp(direction).isEmpty)
        }
    }

    func testOutputLabels() {
        let container = EvidenceRegisterRowPresentation(record: row(.processed, output: .asicContainer),
                                                        pendingStage: nil, now: now)
        XCTAssertEqual(container.output, "Kontajner ASiC-E")
        let pdf = EvidenceRegisterRowPresentation(record: row(.processed, direction: .electronicToElectronic,
                                                              output: .singlePDF), pendingStage: nil, now: now)
        XCTAssertEqual(pdf.output, "Jeden PDF")
        XCTAssertEqual(pdf.direction.text, "E→E")
        XCTAssertNil(EvidenceRegisterRowPresentation(record: row(.processed), pendingStage: nil, now: now).output,
                     "a row written before the output was stored leaves the cell empty")
    }

    func testDeadlineIsEmptyOnceEZZKHasTheRecordAndForDemo() {
        for status in [EvidenceRecord.Status.processed, .acceptedForProcessing, .submitted, .rejected, .recordUnsigned] {
            XCTAssertNil(EvidenceRegisterDetail.deadline(for: row(status), now: now), "\(status)")
        }
        XCTAssertNil(EvidenceRegisterDetail.deadline(for: row(.queuedForSubmission, mode: .demo), now: now))
    }

    func testDeadlineShowsTheTimeOrPoLehote() throws {
        let today = try XCTUnwrap(EvidenceRegisterDetail.deadline(for: row(.queuedForSubmission), now: now))
        XCTAssertEqual(today.text, "Odoslať ešte dnes, do polnoci")

        let late = try XCTUnwrap(EvidenceRegisterDetail.deadline(for: row(.late), now: now))
        XCTAssertEqual(late.text, "Po lehote")
        XCTAssertEqual(late.tone, .failure)

        let overdue = try XCTUnwrap(EvidenceRegisterDetail.deadline(
            for: row(.queuedForSubmission), now: now.addingTimeInterval(2 * 86400)))
        XCTAssertEqual(overdue.text, "Po lehote")

        let beforeSigning = try XCTUnwrap(EvidenceRegisterDetail.deadline(for: row(.readyToSign), now: now))
        XCTAssertTrue(beforeSigning.text.hasPrefix("do "), beforeSigning.text)
        XCTAssertTrue(beforeSigning.text.contains(EZZKRecordPresentation.timeText(now.addingTimeInterval(86400))))

        for status in EvidenceRecord.Status.allCases {
            let text = EvidenceRegisterDetail.deadline(for: row(status), now: now)?.text ?? ""
            XCTAssertNotEqual(text, UXLabels.evidenceStatusLabel(for: status), "\(status) repeats its state")
            XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
        }
    }

    func testFinishOnlyWhileTheClauseWaitsForItsSignature() {
        XCTAssertTrue(EvidenceRegisterRowPresentation.canFinish(pendingStage: .signingClientContainer))
        XCTAssertFalse(EvidenceRegisterRowPresentation.canFinish(pendingStage: .awaitingEZZK))
        XCTAssertFalse(EvidenceRegisterRowPresentation.canFinish(pendingStage: nil))

        let ready = EvidenceRegisterRowPresentation(record: row(.processed), pendingStage: .signingClientContainer,
                                                    now: now)
        XCTAssertTrue(ready.canFinish)
        XCTAssertEqual(ready.status.label, "Čaká na podpis doložky")
    }

    func testStatusFallsBackToTheRowState() {
        let plain = EvidenceRegisterRowPresentation(record: row(.processed), pendingStage: nil, now: now)
        XCTAssertEqual(plain.status.label, UXLabels.evidenceStatusLabel(for: .processed))
        XCTAssertEqual(plain.status.tone, .success)
        XCTAssertFalse(plain.canFinish)
    }

    func testSummaryTilesAreShortAndDemoOnlyWhenPresent() {
        let records = [row(.processed), row(.queuedForSubmission), row(.processed, mode: .demo)]
        let tiles = EvidenceSummaryTile.tiles(summary: EvidenceRegisterSummary(records: records), overdue: 0)
        XCTAssertEqual(tiles.map(\.title), ["Spolu", "V EZZK", "Na odoslanie", "Neúspešné", "Po lehote", "Skúšobné"])
        XCTAssertEqual(tiles.map(\.value), [3, 1, 1, 0, 0, 1])
        XCTAssertTrue(tiles.allSatisfy { $0.title.count <= 14 && !$0.help.isEmpty })
        let noDemo = EvidenceSummaryTile.tiles(summary: EvidenceRegisterSummary(records: [row(.processed)]), overdue: 0)
        XCTAssertFalse(noDemo.contains { $0.id == "demo" })
    }
}
