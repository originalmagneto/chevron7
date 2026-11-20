// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

/// The record-first waiting and done timeline (UI clarity decision 5).
final class ZakoConversionTimelineTests: XCTestCase {
    private let signedAt = Date(timeIntervalSince1970: 1_795_000_000)
    private var sentAt: Date { signedAt.addingTimeInterval(60) }
    private var now: Date { signedAt.addingTimeInterval(13 * 60) }

    private func row(_ status: EvidenceRecord.Status, mode: AppSettings.EZZKMode = .test,
                     submitted: Bool = true, code: Int? = nil, description: String? = nil,
                     lookupAt: Date? = nil) -> EvidenceRecord {
        EvidenceRecord(createdAt: signedAt, status: status, direction: .paperToElectronic,
                       originalName: "Zmluva", newDocumentName: "Zmluva.pdf", evidenceNumber: "1563-261120-1",
                       fingerprintSHA256Hex: "ab", attestationXML: "<x/>", conversionTime: signedAt,
                       performingPersonName: "Marián Čuprík", securityElementCount: 1, totalPages: 1,
                       totalSheets: 1, ezzkMode: mode, submittedAt: submitted ? sentAt : nil,
                       ezzkResultCode: code, ezzkResultDescription: description, lastLookupAt: lookupAt)
    }

    private func timeline(_ row: EvidenceRecord?, stage: RecordFirstPending.Stage? = .awaitingEZZK,
                          signing: Bool = false, delivered: Bool = false,
                          clauseSignedAt: Date? = nil, mode: AppSettings.EZZKMode? = .test,
                          withPending: Bool = true) -> ZakoConversionTimeline {
        .make(.init(evidenceNumber: withPending ? "1563-261120-1" : nil,
                    recordSignedAt: withPending ? signedAt : row?.createdAt,
                    stage: withPending ? stage : nil,
                    row: row, mode: mode, isSigningClause: signing, isDelivered: delivered,
                    clauseSignedAt: clauseSignedAt, now: now))
    }

    private func state(_ timeline: ZakoConversionTimeline, _ kind: ZakoConversionTimeline.StepKind)
        -> ZakoConversionTimeline.StepState? {
        timeline.steps.first { $0.kind == kind }?.state
    }

    private func detail(_ timeline: ZakoConversionTimeline, _ kind: ZakoConversionTimeline.StepKind) -> String? {
        timeline.steps.first { $0.kind == kind }?.detail
    }

    func testWaitingNotSentAsksToSendAndWorksOn() {
        let result = timeline(row(.signed, submitted: false))

        XCTAssertEqual(result.phase, .waitingNotSent)
        XCTAssertEqual(result.headline, "Záznam č. 1563-261120-1 je podpísaný, ešte nie je v EZZK")
        XCTAssertTrue(result.line?.hasSuffix(ZakoConversionTimeline.workOnLine) == true)
        XCTAssertEqual(state(result, .recordSigned), .done)
        XCTAssertEqual(detail(result, .recordSigned), ZakoConversionTimeline.timeText(signedAt, now: now))
        XCTAssertEqual(state(result, .sent), .current)
        XCTAssertEqual(detail(result, .sent), "ešte neodoslaný")
        XCTAssertEqual(result.currentStep?.kind, .sent)
        XCTAssertEqual(state(result, .finished), .upcoming)
    }

    func testFailedOrLateSendNeedsAttentionNotSent() {
        XCTAssertEqual(state(timeline(row(.submissionFailed, submitted: false)), .sent), .attention)
        XCTAssertEqual(state(timeline(row(.late, submitted: false)), .sent), .attention)
        XCTAssertEqual(timeline(row(.late, submitted: false)).phase, .waitingNotSent)
    }

    func testUnknownOutcomeIsNeverSaidToBeSent() {
        let result = timeline(row(.outcomeUnknown))

        XCTAssertEqual(result.phase, .waitingOutcomeUnknown)
        XCTAssertEqual(state(result, .sent), .attention)
        XCTAssertFalse(result.steps.contains { $0.title == "Odoslaný do EZZK" })
    }

    func testWaitingSentShowsElapsedTimeAndTheTestHint() {
        let result = timeline(row(.acceptedForProcessing))

        XCTAssertEqual(result.phase, .waitingSent)
        XCTAssertEqual(result.headline, "Záznam č. 1563-261120-1 čaká na spracovanie v EZZK")
        XCTAssertEqual(result.line, ZakoConversionTimeline.workOnLine)
        XCTAssertEqual(state(result, .sent), .done)
        XCTAssertEqual(detail(result, .sent), ZakoConversionTimeline.timeText(sentAt, now: now))
        XCTAssertEqual(result.currentStep?.kind, .processing)
        XCTAssertEqual(result.currentStep?.title, "EZZK spracúva")
        XCTAssertEqual(detail(result, .processing), "čaká 12 min, zvyčajne 10 až 30 minút")
    }

    func testTheUsualDurationIsSaidOnlyForTestovaciaEvidencia() {
        let production = timeline(row(.acceptedForProcessing, mode: .production), mode: .production)

        XCTAssertEqual(detail(production, .processing), "čaká 12 min")
    }

    func testProcessedRecordWaitsForTheClauseSignature() {
        let result = timeline(row(.processed, lookupAt: now), stage: .signingClientContainer)

        XCTAssertEqual(result.phase, .ready)
        XCTAssertEqual(result.headline, "EZZK spracovalo záznam č. 1563-261120-1")
        XCTAssertEqual(state(result, .processing), .done)
        XCTAssertEqual(result.currentStep?.kind, .clauseSigning)
        XCTAssertEqual(detail(result, .clauseSigning), "čaká na vás")
        XCTAssertNotNil(result.line)
    }

    func testSigningTheClause() {
        let result = timeline(row(.processed), stage: .signingClientContainer, signing: true)

        XCTAssertEqual(result.phase, .signing)
        XCTAssertEqual(result.currentStep?.kind, .clauseSigning)
        XCTAssertEqual(detail(result, .clauseSigning), "prebieha")
        XCTAssertNil(result.line)
    }

    /// Delivered: the pending conversion is gone, so the record time comes from the row.
    func testDoneWithoutPendingChecksEveryStep() {
        let clauseAt = now
        let result = timeline(row(.processed), delivered: true, clauseSignedAt: clauseAt, withPending: false)

        XCTAssertEqual(result.phase, .done)
        XCTAssertEqual(result.headline, "Zaručená konverzia je dokončená")
        XCTAssertTrue(result.steps.allSatisfy { $0.state == .done })
        XCTAssertNil(result.currentStep)
        XCTAssertEqual(detail(result, .recordSigned), ZakoConversionTimeline.timeText(signedAt, now: now))
        XCTAssertEqual(detail(result, .clauseSigning), ZakoConversionTimeline.timeText(clauseAt, now: now))
        XCTAssertNil(result.line)
    }

    /// Rejected: the watcher dropped the pending conversion; the failure sits at the EZZK step.
    func testRejectedShowsTheFailureAtTheEZZKStep() {
        let result = timeline(row(.rejected, code: 12, description: "Neznámy obsah"), withPending: false)

        XCTAssertEqual(result.phase, .rejected)
        XCTAssertEqual(result.headline, "EZZK záznam č. 1563-261120-1 odmietlo")
        XCTAssertEqual(state(result, .processing), .failed)
        XCTAssertEqual(detail(result, .processing), "kód 12: Neznámy obsah")
        XCTAssertEqual(state(result, .clauseSigning), .upcoming)
        XCTAssertEqual(state(result, .finished), .upcoming)
        XCTAssertNotNil(result.line)
    }

    func testEveryStepStateHasWords() {
        let states: [ZakoConversionTimeline.StepState] = [.done, .current, .upcoming, .attention, .failed]
        XCTAssertEqual(Set(states.map(\.accessibilityValue)).count, states.count)
        XCTAssertEqual(Set(states.map(\.symbol)).count, states.count, "color is never the only difference")
    }

    func testElapsedText() {
        XCTAssertEqual(ZakoConversionTimeline.elapsedText(from: signedAt, to: signedAt.addingTimeInterval(20)),
                       "menej ako minútu")
        XCTAssertEqual(ZakoConversionTimeline.elapsedText(from: signedAt, to: signedAt.addingTimeInterval(3600)), "1 h")
        XCTAssertEqual(ZakoConversionTimeline.elapsedText(from: signedAt, to: signedAt.addingTimeInterval(3900)),
                       "1 h 5 min")
    }

    func testTimeTextIsShortOnTheSameDay() {
        let nextDay = signedAt.addingTimeInterval(30 * 3600)
        XCTAssertEqual(ZakoConversionTimeline.timeText(signedAt, now: nextDay), EZZKRecordPresentation.timeText(signedAt))
        XCTAssertEqual(ZakoConversionTimeline.timeText(signedAt, now: signedAt).count, 5)
    }

    /// The done presentation's lines the timeline already says are not repeated.
    func testSupplementaryLinesDropWhatTheTimelineSays() {
        let rejected = row(.rejected, code: 12, description: "Neznámy obsah")
        let lines = EZZKRecordPresentation.stateExplanation(for: rejected)
            + ["Spracovanie záznamu sa overuje v EZZK automaticky.", "Overiť v EZZK bude možné od 12:00.",
               EZZKRecordPresentation.modeLine(.test)!]

        XCTAssertEqual(ZakoConversionTimeline.supplementaryLines(lines, record: rejected),
                       ["Overiť v EZZK bude možné od 12:00."])
    }

    func testTextsCarryNoEmDash() {
        let all = [timeline(row(.signed, submitted: false)), timeline(row(.acceptedForProcessing)),
                   timeline(row(.processed), stage: .signingClientContainer),
                   timeline(row(.rejected), withPending: false)]
        for item in all {
            let texts = [item.headline, item.line ?? ""] + item.steps.flatMap { [$0.title, $0.detail ?? ""] }
            for text in texts { XCTAssertFalse(text.contains("\u{2014}"), text) }
        }
    }
}

/// The store gives a timeline only to a record-first conversion.
@MainActor
final class ZakoConversionTimelineStoreTests: XCTestCase {
    func testTodaysOrderHasNoTimeline() {
        let store = ZakoSessionStore(settingsStore: makeSettingsStore())
        store.step = .done

        XCTAssertNil(store.conversionTimeline(now: Date()))
    }

    func testAttachedPendingConversionHasOne() {
        let store = ZakoSessionStore(settingsStore: makeSettingsStore())
        store.attachRecordFirstPending(RecordFirstPendingStoreTests.samplePending())
        store.step = .done

        let timeline = store.conversionTimeline(now: Date())

        XCTAssertEqual(timeline?.phase, .waitingNotSent, "no row yet: nothing reached EZZK")
    }
}
