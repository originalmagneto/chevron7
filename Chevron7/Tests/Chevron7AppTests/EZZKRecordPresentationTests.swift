// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation
import XCTest
@testable import Chevron7App

/// What the ZaKo Done screen tells the advocate about the conversion's EZZK record. It
/// reads the stored row (its state and the EZZK mode it was signed in), never the current
/// mode, and claims success only when EZZK has the record.
@MainActor
final class EZZKRecordPresentationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z")!

    func testDoneClaimsSuccessOnlyWhenEZZKHasTheRecord() {
        for status in EvidenceRecord.Status.allCases {
            let done = ZakoDonePresentation(record: row(status), lastError: nil, lastErrorStatus: nil,
                                            nextStatusCheck: nil, now: now)
            let succeeded = status == .acceptedForProcessing || status == .processed || status == .submitted
            XCTAssertEqual(done.tone == .success, succeeded, "\(status)")
            if !succeeded {
                XCTAssertFalse(done.title.contains("úspešne"), "\(status): \(done.title)")
            }
        }
    }

    func testDoneReadsTheModeTheRowWasSignedIn() {
        let test = ZakoDonePresentation(record: row(.queuedForSubmission, mode: .test), lastError: nil,
                                        lastErrorStatus: nil, nextStatusCheck: nil, now: now)
        XCTAssertTrue(test.lines.contains("Režim EZZK pri podpise: Testovacia evidencia"), "\(test.lines)")
        XCTAssertEqual(test.action, .send)

        let demo = ZakoDonePresentation(record: row(.queuedForSubmission, mode: .demo), lastError: nil,
                                        lastErrorStatus: nil, nextStatusCheck: nil, now: now)
        XCTAssertEqual(demo.action, .send)

        let production = ZakoDonePresentation(record: row(.queuedForSubmission, mode: .production), lastError: nil,
                                              lastErrorStatus: nil, nextStatusCheck: nil, now: now)
        XCTAssertEqual(production.action, .none, "production stays refused")
        XCTAssertTrue(production.lines.contains(EZZKError.submissionUnavailable.errorDescription ?? "-"))
    }

    func testDoneExplainsEveryStateThatNeedsTheAdvocate() {
        var unknown = row(.outcomeUnknown)
        unknown.ezzkResultDescription = EZZKError.outcomeUnknown.localizedDescription
        let unknownDone = presentation(unknown, nextStatusCheck: now.addingTimeInterval(4 * 60))
        XCTAssertTrue(unknownDone.lines.joined(separator: " ").contains("najprv overte v EZZK"), "\(unknownDone.lines)")
        XCTAssertEqual(unknownDone.action, .verify(availableAt: now.addingTimeInterval(4 * 60)))
        XCTAssertFalse(unknownDone.isActionEnabled, "the lookup waits five minutes after the attempt")
        XCTAssertTrue(presentation(unknown, nextStatusCheck: now.addingTimeInterval(-1)).isActionEnabled)

        var rejected = row(.rejected)
        rejected.ezzkResultCode = 12
        rejected.ezzkResultDescription = "Neznámy obsah"
        let rejectedDone = presentation(rejected)
        XCTAssertEqual(rejectedDone.tone, .failure)
        XCTAssertTrue(rejectedDone.lines.contains("EZZK vrátilo kód 12: Neznámy obsah"), "\(rejectedDone.lines)")
        XCTAssertEqual(rejectedDone.action, .none)

        var unsigned = row(.recordUnsigned)
        unsigned.ezzkResultDescription = "Karta bola vybratá."
        let unsignedDone = presentation(unsigned)
        let unsignedText = unsignedDone.lines.joined(separator: " ")
        XCTAssertTrue(unsignedText.contains("1563-260924-1"), unsignedText)
        XCTAssertTrue(unsignedText.contains("Neodovzdávajte"), unsignedText)
        XCTAssertTrue(unsignedText.contains("nové evidenčné číslo"), unsignedText)
        XCTAssertEqual(unsignedDone.action, .none)

        let lateDone = presentation(row(.late))
        XCTAssertTrue(lateDone.lines.contains(EZZKRecordPresentation.lateWarning))
        XCTAssertEqual(lateDone.action, .send)

        var queued = row(.queuedForSubmission)
        queued.ezzkResultDescription = "Sieťová chyba pri spojení s EZZK: offline"
        let queuedDone = presentation(queued)
        XCTAssertTrue(queuedDone.lines.contains("Sieťová chyba pri spojení s EZZK: offline"))
        XCTAssertEqual(queuedDone.tone, .pending)

        let accepted = presentation(row(.acceptedForProcessing), nextStatusCheck: now.addingTimeInterval(60))
        XCTAssertEqual(accepted.action, .verify(availableAt: nil), "a refresh of an accepted row needs no wait")
        XCTAssertTrue(accepted.isActionEnabled)
    }

    /// The flow's last error describes the row as ZaKo last saw it; once the periodic check
    /// moved the row on, none of it applies.
    func testDoneShowsTheFlowsErrorOnlyWhileItStillDescribesTheRow() {
        var unknown = row(.outcomeUnknown)
        unknown.ezzkResultDescription = "Výsledok neznámy"
        let stillUnknown = ZakoDonePresentation(record: unknown, lastError: "Výsledok neznámy\nSpojenie prerušené",
                                                lastErrorStatus: .outcomeUnknown,
                                                nextStatusCheck: nil, now: now)
        XCTAssertEqual(stillUnknown.error, "Spojenie prerušené", "the row's own description is already a line")

        let movedOn = ZakoDonePresentation(record: row(.acceptedForProcessing), lastError: "Výsledok neznámy\nSpojenie prerušené",
                                           lastErrorStatus: .outcomeUnknown,
                                           nextStatusCheck: nil, now: now)
        XCTAssertNil(movedOn.error)

        let refused = ZakoDonePresentation(record: row(.queuedForSubmission), lastError: EZZKStatusChecker.rowBusyMessage,
                                           lastErrorStatus: .queuedForSubmission,
                                           nextStatusCheck: nil, now: now)
        XCTAssertEqual(refused.error, EZZKStatusChecker.rowBusyMessage)
    }

    func testDoneWithoutARowSaysSoAndOffersNothing() {
        let done = ZakoDonePresentation(record: nil, lastError: "Register konverzií sa nepodarilo načítať.",
                                        lastErrorStatus: nil, nextStatusCheck: nil, now: now)
        XCTAssertNotEqual(done.tone, .success)
        XCTAssertEqual(done.action, .none)
        XCTAssertEqual(done.error, "Register konverzií sa nepodarilo načítať.")
    }

    /// Ruling R15 in the Register detail: no "Odoslať" for a row from before B2, the
    /// Slovak note instead, and no warning about handing documents over.
    func testRegisterDetailOffersNothingForARowWrittenBeforeB2() {
        var legacy = row(.queuedForSubmission)
        legacy.ezzkMode = nil
        let actions = EvidenceRegisterDetail.actions(for: legacy, currentMode: .test)
        XCTAssertFalse(actions.canSend)
        XCTAssertFalse(actions.canVerify)
        XCTAssertEqual(actions.note, "Záznam vznikol pred odosielaním do EZZK v Chevron7, preto ho aplikácia neodosiela.")

        var unsigned = row(.recordUnsigned)
        unsigned.ezzkMode = nil
        XCTAssertEqual(EvidenceRegisterDetail.actions(for: unsigned, currentMode: .test).note,
                       EZZKStatusChecker.preB2RowMessage)
        XCTAssertFalse(EZZKRecordPresentation.stateExplanation(for: unsigned).joined().contains("Neodovzdávajte"))
    }

    /// A row of another mode is not sent from the Done screen, but may be looked up: the
    /// lookup goes to the row's own EZZK.
    func testDoneSendsNoRowOfAnotherModeButVerifiesIt() {
        let queued = ZakoDonePresentation(record: row(.queuedForSubmission, mode: .test), lastError: nil,
                                          lastErrorStatus: nil, nextStatusCheck: nil, now: now,
                                          currentMode: .demo)
        XCTAssertEqual(queued.action, .none)
        XCTAssertFalse(queued.isActionEnabled)
        XCTAssertTrue(queued.lines.contains(EZZKStatusChecker.recordFromOtherModeMessage), "\(queued.lines)")
        for status in [EvidenceRecord.Status.outcomeUnknown, .acceptedForProcessing] {
            let done = ZakoDonePresentation(record: row(status, mode: .test), lastError: nil, lastErrorStatus: nil,
                                            nextStatusCheck: nil, now: now,
                                            currentMode: .demo)
            XCTAssertEqual(done.action, .verify(availableAt: nil), "\(status)")
            XCTAssertTrue(done.isActionEnabled)
            XCTAssertFalse(done.lines.contains(EZZKStatusChecker.recordFromOtherModeMessage), "\(done.lines)")
        }
        let sameMode = ZakoDonePresentation(record: row(.queuedForSubmission, mode: .test), lastError: nil,
                                            lastErrorStatus: nil, nextStatusCheck: nil,
                                            now: now, currentMode: .test)
        XCTAssertEqual(sameMode.action, .send)
    }

    // MARK: - Register konverzií

    /// "Uložiť záznam…": the signed record lives only in the register, so the Register hands
    /// out its stored bytes under the name EZZK knows it by, and offers nothing without one.
    func testRegisterSavesTheStoredRecordUnderItsEvidenceNumber() throws {
        let store = makeSettingsStore().evidenceStore
        var signed = row(.acceptedForProcessing)
        signed.evidenceNumber = "1563-260924-7"
        XCTAssertNil(EvidenceRegisterDetail.storedRecordContainer(for: signed, in: store),
                     "a row without a signed record offers nothing to save")

        signed.recordContainerPath = try store.storeRecordContainer(Data("zip".utf8), for: signed.id)
        let saved = try XCTUnwrap(EvidenceRegisterDetail.storedRecordContainer(for: signed, in: store))
        XCTAssertEqual(saved.fileName, "1563-260924-7.record.asice")
        XCTAssertEqual(saved.data, Data("zip".utf8))

        signed.recordContainerPath = "../register.json"
        XCTAssertNil(EvidenceRegisterDetail.storedRecordContainer(for: signed, in: store))
    }

    func testRegisterSummaryCountsAcceptedAndProcessedAsSentAndRejectedAsFailed() {
        let rows = [row(.acceptedForProcessing), row(.processed), row(.submitted), row(.rejected),
                    row(.recordUnsigned), row(.outcomeUnknown), row(.late), row(.queuedForSubmission)]
        let summary = EvidenceRegisterSummary(records: rows)
        XCTAssertEqual(summary.total, 8)
        XCTAssertEqual(summary.sent, 3)
        XCTAssertEqual(summary.failed, 2)
        XCTAssertEqual(summary.pending, 3)
        XCTAssertEqual(summary.demo, 0)
    }

    /// The reported case: a Demo row "1563-260924-1" blocked the same real number production
    /// allocated. Only rows of the same mode (and rows from before modes) hold a number.
    func testDemoNumberNeverBlocksARealOne() {
        let demo = row(.acceptedForProcessing, mode: .demo)
        XCTAssertEqual(EvidenceRecord.usedEvidenceNumbers(in: [demo], mode: .production), [])
        XCTAssertEqual(EvidenceRecord.usedEvidenceNumbers(in: [demo], mode: .demo), ["1563-260924-1"])
        var legacy = row(.submitted)
        legacy.ezzkMode = nil
        XCTAssertEqual(EvidenceRecord.usedEvidenceNumbers(in: [legacy], mode: .production), ["1563-260924-1"])
    }

    /// A Demo row is a local simulation: counted in the total and as Demo, never as in EZZK.
    func testRegisterSummaryKeepsDemoRowsOutOfTheEZZKCounts() {
        var demo = row(.acceptedForProcessing)
        demo.ezzkMode = .demo
        var real = row(.processed)
        real.ezzkMode = .production
        let summary = EvidenceRegisterSummary(records: [demo, real])
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.demo, 1)
        XCTAssertEqual(summary.sent, 1)
        XCTAssertEqual(summary.pending, 0)
    }

    func testTimelineShowsAcceptedAsSentAndRejectedAsFailed() {
        let accepted = EvidenceRegisterDetail.timeline(for: row(.acceptedForProcessing))
        XCTAssertEqual(accepted.map(\.label), ["Evidenčné číslo", "Autorizácia KEP", "Záznam v EZZK", "Spracovaný"])
        XCTAssertEqual(accepted.map(\.done), [true, true, true, false])
        XCTAssertEqual(accepted.map(\.failed), [false, false, false, false])

        XCTAssertEqual(EvidenceRegisterDetail.timeline(for: row(.processed)).map(\.done), [true, true, true, true])
        XCTAssertEqual(EvidenceRegisterDetail.timeline(for: row(.rejected)).map(\.failed), [false, false, true, false])
        XCTAssertEqual(EvidenceRegisterDetail.timeline(for: row(.recordUnsigned)).map(\.failed), [false, false, true, false])
        XCTAssertEqual(EvidenceRegisterDetail.timeline(for: row(.outcomeUnknown)).map(\.done), [true, true, false, false])
    }

    func testDetailFactsShowTheSubmission() {
        var record = row(.rejected)
        record.submittedAt = now
        record.submissionMessageID = "ae6fbf72-1"
        record.ezzkResultCode = 12
        record.ezzkResultDescription = "Neznámy obsah"
        record.lastLookupAt = now.addingTimeInterval(3600)
        let facts = Dictionary(uniqueKeysWithValues: EvidenceRegisterDetail.submissionFacts(for: record).map { ($0.label, $0.value) })
        XCTAssertEqual(facts["Stav"], "Odmietnutý v EZZK")
        XCTAssertEqual(facts["Režim EZZK"], "Testovacia evidencia")
        XCTAssertEqual(facts["Odoslané"], "24. 9. 2026 12:00")
        XCTAssertEqual(facts["ID správy"], "ae6fbf72-1")
        XCTAssertEqual(facts["Výsledok EZZK"], "12: Neznámy obsah")
        XCTAssertEqual(facts["Posledné overenie"], "24. 9. 2026 13:00")

        let fresh = EvidenceRegisterDetail.submissionFacts(for: row(.signed)).map(\.label)
        XCTAssertEqual(fresh, ["Stav", "Režim EZZK"], "only what the row has")
    }

    func testDetailActionsFollowStateAndMode() {
        let queued = EvidenceRegisterDetail.actions(for: row(.queuedForSubmission), currentMode: .test)
        XCTAssertTrue(queued.canSend)
        XCTAssertFalse(queued.canVerify)
        XCTAssertNil(queued.note)

        let late = EvidenceRegisterDetail.actions(for: row(.late), currentMode: .test)
        XCTAssertTrue(late.canSend)
        XCTAssertEqual(late.note, EZZKRecordPresentation.lateWarning)

        for status in [EvidenceRecord.Status.outcomeUnknown, .acceptedForProcessing] {
            let actions = EvidenceRegisterDetail.actions(for: row(status), currentMode: .test)
            XCTAssertFalse(actions.canSend, "\(status)")
            XCTAssertTrue(actions.canVerify, "\(status)")
        }

        let otherMode = EvidenceRegisterDetail.actions(for: row(.queuedForSubmission, mode: .demo), currentMode: .test)
        XCTAssertFalse(otherMode.canSend)
        XCTAssertEqual(otherMode.note, EZZKStatusChecker.recordFromOtherModeMessage)
        for status in [EvidenceRecord.Status.outcomeUnknown, .acceptedForProcessing] {
            let verifiable = EvidenceRegisterDetail.actions(for: row(status, mode: .demo), currentMode: .test)
            XCTAssertTrue(verifiable.canVerify, "a lookup goes to the row's own EZZK from any mode: \(status)")
            XCTAssertFalse(verifiable.canSend)
            XCTAssertNil(verifiable.note)
        }
        let productionFromDemo = EvidenceRegisterDetail.actions(for: row(.acceptedForProcessing, mode: .production),
                                                                currentMode: .demo)
        XCTAssertFalse(productionFromDemo.canVerify, "the production policy still decides")

        let production = EvidenceRegisterDetail.actions(for: row(.queuedForSubmission, mode: .production),
                                                         currentMode: .production)
        XCTAssertFalse(production.canSend)
        XCTAssertEqual(production.note, EZZKError.submissionUnavailable.errorDescription)

        let unsigned = EvidenceRegisterDetail.actions(for: row(.recordUnsigned), currentMode: .test)
        XCTAssertFalse(unsigned.canSend)
        XCTAssertFalse(unsigned.canVerify)
        XCTAssertEqual(unsigned.note, "Záznam podpíšte znova novou konverziou; opakovaný podpis z Registra príde neskôr.")
    }

    /// Ruling R18: only a record EZZK refused at submission (nothing stored) with its signed
    /// container in the register can be sent again, behind a confirmation naming EZZK's code.
    func testRegisterOffersResendOnlyForARecordRefusedAtSubmission() {
        let refused = rejectedAtSubmissionRow()

        let offered = EvidenceRegisterDetail.actions(for: refused, currentMode: .test, now: now)
        XCTAssertTrue(offered.canResend)
        XCTAssertFalse(offered.canSend)
        XCTAssertFalse(offered.canVerify)
        XCTAssertEqual(offered.resendConfirmation,
                       "EZZK záznam odmietlo (kód 203: Neplatný podpis záznamu). Odoslať ho znova?")

        var afterReceipt = refused
        afterReceipt.submittedAt = now
        var afterLookup = refused
        afterLookup.lastLookupAt = now
        var withoutContainer = refused
        withoutContainer.recordContainerPath = nil
        for row in [afterReceipt, afterLookup, withoutContainer] {
            let actions = EvidenceRegisterDetail.actions(for: row, currentMode: .test)
            XCTAssertFalse(actions.canResend)
            XCTAssertNil(actions.resendConfirmation)
        }

        let otherMode = EvidenceRegisterDetail.actions(for: refused, currentMode: .demo)
        XCTAssertFalse(otherMode.canResend)
        XCTAssertEqual(otherMode.note, EZZKStatusChecker.recordFromOtherModeMessage)

        var production = refused
        production.ezzkMode = .production
        let productionActions = EvidenceRegisterDetail.actions(for: production, currentMode: .production)
        XCTAssertFalse(productionActions.canResend)
        XCTAssertEqual(productionActions.note, EZZKError.submissionUnavailable.errorDescription)
    }

    /// A manual "Odoslať znova" on a record whose number is past its Bratislava day gets the
    /// same lateness warning the Register shows a pending row, so the advocate is not
    /// surprised when EZZK rejects or flags the resend as late.
    func testResendConfirmationMentionsALateRecord() {
        var row = rejectedAtSubmissionRow()
        row.evidenceNumberAllocatedAt = now.addingTimeInterval(-3 * 24 * 3600)
        let text = EvidenceRegisterDetail.resendConfirmation(for: row, now: now)
        XCTAssertTrue(text.contains(EZZKRecordPresentation.lateWarning), text)
    }

    /// The outcome-unknown message used to name only a lost connection; a server fault
    /// leaves the same doubt and must be named too, so the advocate does not read a
    /// disconnect that never happened.
    func testOutcomeUnknownNamesAServerFaultToo() {
        let text = EZZKError.outcomeUnknown.errorDescription ?? ""
        XCTAssertTrue(text.contains("chyba servera"), text)
    }

    func testDeadlineColumn() {
        XCTAssertEqual(EvidenceRegisterDetail.deadline(for: row(.late), now: now).text, EZZKRecordPresentation.lateWarning)
        XCTAssertEqual(EvidenceRegisterDetail.deadline(for: row(.processed), now: now).text, "Spracovaný v EZZK")
        XCTAssertEqual(EvidenceRegisterDetail.deadline(for: row(.acceptedForProcessing), now: now).tone, .success)

        let today = EvidenceRegisterDetail.deadline(for: row(.queuedForSubmission), now: now)
        XCTAssertEqual(today.text, "Odoslať ešte dnes, do polnoci")
        XCTAssertEqual(today.tone, .warning)

        let unknown = EvidenceRegisterDetail.deadline(for: row(.outcomeUnknown), now: now.addingTimeInterval(2 * 86400))
        XCTAssertEqual(unknown.text, "Najprv overte v EZZK")
        XCTAssertFalse(unknown.text.contains("\u{2014}"), "no em dash")
    }

    // MARK: - Fixtures

    private func presentation(_ record: EvidenceRecord, nextStatusCheck: Date? = nil) -> ZakoDonePresentation {
        ZakoDonePresentation(record: record, lastError: nil, lastErrorStatus: nil,
                             nextStatusCheck: nextStatusCheck, now: now)
    }

    private func row(_ status: EvidenceRecord.Status, mode: AppSettings.EZZKMode = .test) -> EvidenceRecord {
        EvidenceRecord(createdAt: now, status: status, direction: .paperToElectronic, originalName: "Zmluva",
                       newDocumentName: "Zmluva.pdf", evidenceNumber: "1563-260924-1", fingerprintSHA256Hex: "ab",
                       attestationXML: "<x/>", conversionTime: now, performingPersonName: "JUDr. Test Testovací",
                       securityElementCount: 0, totalPages: 1, totalSheets: 1, ezzkMode: mode,
                       evidenceNumberAllocatedAt: now)
    }

    /// A row EZZK refused at submission (nothing stored), with its signed container still in
    /// the register: the only state "Odoslať znova" offers (ruling R18).
    private func rejectedAtSubmissionRow() -> EvidenceRecord {
        var refused = row(.rejected)
        refused.ezzkResultCode = 203
        refused.ezzkResultDescription = "Neplatný podpis záznamu"
        refused.recordContainerPath = "Evidence/Records/x.asice"
        return refused
    }
}
