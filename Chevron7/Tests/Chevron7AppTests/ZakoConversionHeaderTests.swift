// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import XCTest
import Chevron7Kit
@testable import Chevron7App

/// The ZaKo conversion header: the step model for both directions and both orders, the
/// chips taken from the conversion itself, and the EZZK environment badge's wording.
@MainActor
final class ZakoConversionHeaderTests: XCTestCase {
    // MARK: Step model

    private func progress(_ step: ZakoSessionStore.Step,
                          direction: ConversionDirection = .paperToElectronic,
                          recordFirst: Bool = false,
                          pending: RecordFirstPending.Stage? = nil,
                          row: EvidenceRecord.Status? = nil) -> ZakoStepProgress {
        .make(direction: direction, step: step, isRecordFirst: recordFirst, pendingStage: pending, rowStatus: row)
    }

    func testTodaysOrderNamesFourStepsPerDirection() {
        XCTAssertEqual(progress(.analysis, direction: .paperToElectronic).titles,
                       ["Analýza", "Doložka", "Autorizácia", "Hotovo"])
        XCTAssertEqual(progress(.verification, direction: .electronicToElectronic).titles,
                       ["Overenie", "Doložka", "Autorizácia", "Hotovo"])
    }

    func testRecordFirstAddsTheRecordAndClauseSignatureStages() {
        XCTAssertEqual(progress(.analysis, direction: .paperToElectronic, recordFirst: true).titles,
                       ["Analýza", "Doložka", "Autorizácia", "Záznam do EZZK", "Podpis doložky", "Hotovo"])
        XCTAssertEqual(progress(.verification, direction: .electronicToElectronic, recordFirst: true).titles,
                       ["Overenie", "Doložka", "Autorizácia", "Záznam do EZZK", "Podpis doložky", "Hotovo"])
    }

    func testTodaysOrderIndexFollowsTheStep() {
        XCTAssertEqual(progress(.analysis).currentIndex, 0)
        XCTAssertEqual(progress(.verification, direction: .electronicToElectronic).currentIndex, 0)
        XCTAssertEqual(progress(.attestation).currentIndex, 1)
        XCTAssertEqual(progress(.authorize).currentIndex, 2)
        let done = progress(.done)
        XCTAssertEqual(done.currentIndex, 3)
        XCTAssertTrue(done.isFinished)
        XCTAssertEqual(done.compactText, "Krok 4 z 4: Hotovo")
    }

    func testRecordFirstAuthorizeWithoutPendingIsTheAuthorizationStep() {
        let authorize = progress(.authorize, recordFirst: true)
        XCTAssertEqual(authorize.current, .authorize)
        XCTAssertEqual(authorize.compactText, "Krok 3 z 6: Autorizácia")
        XCTAssertFalse(authorize.isWaitingForEZZK)
    }

    func testRecordFirstWaitingForEZZKIsTheRecordStage() {
        let waiting = progress(.done, recordFirst: true, pending: .awaitingEZZK, row: .acceptedForProcessing)
        XCTAssertEqual(waiting.current, .recordInEZZK)
        XCTAssertEqual(waiting.currentIndex, 3)
        XCTAssertTrue(waiting.isWaitingForEZZK)
        XCTAssertFalse(waiting.isFinished)
    }

    func testClauseReadyIsTheClauseSignatureStageAtDoneAndWhenLoaded() {
        let atDone = progress(.done, recordFirst: true, pending: .signingClientContainer, row: .processed)
        XCTAssertEqual(atDone.current, .clauseSignature)
        XCTAssertEqual(atDone.currentIndex, 4)
        // A stored conversion opened from the sidebar or the Register lands at authorize.
        let loaded = progress(.authorize, direction: .electronicToElectronic, recordFirst: true,
                              pending: .signingClientContainer, row: .processed)
        XCTAssertEqual(loaded.current, .clauseSignature)
        XCTAssertFalse(loaded.isWaitingForEZZK)
    }

    func testFinishedRecordFirstConversionIsDone() {
        let finished = progress(.done, recordFirst: true, row: .processed)
        XCTAssertEqual(finished.current, .done)
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.compactText, "Krok 6 z 6: Hotovo")
    }

    func testRejectedRecordFirstConversionStopsAtTheRecordAndIsNeverDone() {
        for status in [EvidenceRecord.Status.rejected, .recordUnsigned] {
            let stopped = progress(.done, recordFirst: true, row: status)
            XCTAssertEqual(stopped.current, .recordInEZZK, "\(status)")
            XCTAssertTrue(stopped.isHalted)
            XCTAssertFalse(stopped.isFinished)
        }
        // Today's order delivered the client output before EZZK answered: still done.
        let todays = progress(.done, row: .rejected)
        XCTAssertEqual(todays.current, .done)
        XCTAssertFalse(todays.isHalted)
    }

    // MARK: Header model

    private func input(step: ZakoSessionStore.Step = .attestation,
                       pending: RecordFirstPending? = nil,
                       row: EvidenceRecord? = nil,
                       byClock: Bool = false,
                       output: AppSettings.ZakoClientOutput = .asicContainer,
                       numberMode: AppSettings.EZZKMode? = nil,
                       currentMode: AppSettings.EZZKMode = .production) -> ZakoConversionHeaderModel.Input {
        .init(documentName: "Zmluva.pdf", direction: .paperToElectronic, step: step, pending: pending, row: row,
              recordFirstByClock: byClock, outputSetting: output, evidenceNumberMode: numberMode,
              currentMode: currentMode)
    }

    func testOrderChipOnlyForRecordFirst() {
        XCTAssertFalse(ZakoConversionHeaderModel.make(input()).isRecordFirst)
        XCTAssertTrue(ZakoConversionHeaderModel.make(input(byClock: true)).isRecordFirst)
        XCTAssertTrue(ZakoConversionHeaderModel.make(input(pending: pending(.awaitingEZZK))).isRecordFirst,
                      "a stored conversion keeps its order whatever the clock says")
    }

    func testDoneTrustsTheRowsRecordFormOverTheClock() {
        let record12 = record(formPack: FormPackStamp(pack: FormPackRepository.record12Unverified))
        XCTAssertTrue(ZakoConversionHeaderModel.make(input(step: .done, row: record12)).isRecordFirst)
        let record10 = record(formPack: FormPackStamp(pack: FormPackRepository.currentLegacyUnverified))
        XCTAssertFalse(ZakoConversionHeaderModel.make(input(step: .done, row: record10, byClock: true)).isRecordFirst)
    }

    func testOutputChipOnceChosen() {
        XCTAssertNil(ZakoConversionHeaderModel.make(input(step: .attestation, output: .singlePDF)).outputChip)
        XCTAssertEqual(ZakoConversionHeaderModel.make(input(step: .authorize, output: .singlePDF)).outputChip, "Jeden PDF")
        XCTAssertEqual(ZakoConversionHeaderModel.make(input(step: .authorize)).outputChip, "Kontajner ASiC-E")
        // Fixed by the stored conversion, not the current setting.
        XCTAssertEqual(ZakoConversionHeaderModel.make(input(step: .authorize, pending: pending(.signingClientContainer),
                                                            output: .asicContainer)).outputChip, "Jeden PDF")
        // A finished row says what was delivered.
        XCTAssertEqual(ZakoConversionHeaderModel.make(input(step: .done, row: record(clientOutput: .singlePDF),
                                                            output: .asicContainer)).outputChip, "Jeden PDF")
    }

    func testEnvironmentComesFromTheConversion() {
        XCTAssertEqual(ZakoConversionHeaderModel.make(input(currentMode: .test)).environment, .test)
        XCTAssertEqual(ZakoConversionHeaderModel.make(input(numberMode: .demo, currentMode: .test)).environment, .demo)
        XCTAssertEqual(ZakoConversionHeaderModel.make(input(pending: pending(.awaitingEZZK), currentMode: .production))
            .environment, .test)
        XCTAssertEqual(ZakoConversionHeaderModel.make(input(step: .done, row: record(mode: .demo), currentMode: .production))
            .environment, .demo)
    }

    func testStoreBuildsTheHeaderFromItsSession() {
        let settingsStore = makeSettingsStore()
        let store = ZakoSessionStore(settingsStore: settingsStore)
        store.direction = .electronicToElectronic
        store.sourceNameOverride = "Kúpna zmluva"
        store.step = .verification
        let model = store.conversionHeaderModel
        XCTAssertEqual(model.documentName, "Kúpna zmluva")
        XCTAssertEqual(model.progress.titles.first, "Overenie")
        XCTAssertEqual(model.environment, settingsStore.ezzkAccountController.mode)
        XCTAssertNil(model.outputChip)
    }

    // MARK: Environment badge

    func testBadgeTextPerModeAndForm() {
        XCTAssertEqual(EZZKEnvironmentBadgeModel.text(for: .demo, form: .short), "Skúšobný")
        XCTAssertEqual(EZZKEnvironmentBadgeModel.text(for: .test, form: .short), "Test")
        XCTAssertNil(EZZKEnvironmentBadgeModel.text(for: .production, form: .short))
        XCTAssertEqual(EZZKEnvironmentBadgeModel.text(for: .demo, form: .list), "Skúšobný režim")
        XCTAssertEqual(EZZKEnvironmentBadgeModel.text(for: .test, form: .list), "Testovacia evidencia")
        XCTAssertNil(EZZKEnvironmentBadgeModel.text(for: .production, form: .list), "lists never mark production")
        XCTAssertEqual(EZZKEnvironmentBadgeModel.text(for: .production, form: .subject), "Ostrá evidencia")
        XCTAssertNil(EZZKEnvironmentBadgeModel.text(for: nil, form: .subject), "a row older than EZZK modes")
    }

    func testBadgeAccessibilityNamesTheEnvironmentInFull() {
        for mode in AppSettings.EZZKMode.allCases {
            let label = EZZKEnvironmentBadgeModel.accessibilityLabel(for: mode)
            XCTAssertTrue(label.hasPrefix("Prostredie EZZK: "), label)
        }
        XCTAssertTrue(EZZKEnvironmentBadgeModel.accessibilityLabel(for: .test).contains("Testovacia evidencia"))
    }

    // MARK: Helpers

    private func pending(_ stage: RecordFirstPending.Stage) -> RecordFirstPending {
        RecordFirstPending(
            recordID: UUID(), stage: stage,
            direction: .paperToElectronic, originalFingerprints: nil,
            mode: .test, evidenceNumber: "261120-qd580FC023", conversionTime: Date(),
            finalPDF: Data("%PDF-1.7\n".utf8), fingerprint: "00", containerDocumentName: "zmluva.pdf",
            containerFiles: [], directory: FileManager.default.temporaryDirectory,
            stampsSignatures: false, timestampServers: nil, tsaURL: nil, attestation: AttestationData(),
            clientOutput: .singlePDF, appendedClause: nil, fixedTarget: nil,
            clientTimestampServers: nil, clientTSAURL: nil)
    }

    private func record(mode: AppSettings.EZZKMode? = .test,
                        formPack: FormPackStamp? = nil,
                        clientOutput: AppSettings.ZakoClientOutput? = nil) -> EvidenceRecord {
        EvidenceRecord(status: .processed, direction: .paperToElectronic,
                       originalName: "Zmluva", newDocumentName: "Zmluva.pdf", evidenceNumber: "1563-260924-1",
                       fingerprintSHA256Hex: "ab", attestationXML: "<x/>",
                       conversionTime: Date(), performingPersonName: "JUDr. Test Testovací",
                       securityElementCount: 0, totalPages: 1, totalSheets: 1,
                       formPack: formPack, ezzkMode: mode, clientOutput: clientOutput)
    }
}
