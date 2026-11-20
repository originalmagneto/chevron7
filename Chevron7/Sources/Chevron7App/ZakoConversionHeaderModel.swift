// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// The steps of a ZaKo conversion as the header shows them: both directions, today's order
/// and the record-first order of 1. 1. 2027. Pure values, tested without SwiftUI.
struct ZakoStepProgress: Equatable {
    enum Stage: Equatable {
        case analysis
        case verification
        case attestation
        case authorize
        /// Record-first: the record is signed and goes to EZZK, which processes it (the wait).
        case recordInEZZK
        /// Record-first: EZZK processed the record; the clause and client output are signed.
        case clauseSignature
        case done

        var title: String {
            switch self {
            case .analysis: "Analýza"
            case .verification: "Overenie"
            case .attestation: "Doložka"
            case .authorize: "Autorizácia"
            case .recordInEZZK: "Záznam do EZZK"
            case .clauseSignature: "Podpis doložky"
            case .done: "Hotovo"
            }
        }

        var symbol: String {
            switch self {
            case .analysis: "doc.text.magnifyingglass"
            case .verification: "checkmark.seal"
            case .attestation: "doc.text"
            case .authorize: "person.badge.key"
            case .recordInEZZK: "tray.and.arrow.up"
            case .clauseSignature: "signature"
            case .done: "flag.checkered"
            }
        }
    }

    let stages: [Stage]
    let currentIndex: Int
    /// The record waits for EZZK in the background ("Záznam do EZZK" is current).
    let isWaitingForEZZK: Bool
    /// The conversion stopped at the current stage: EZZK rejected the record, or it was never
    /// signed, so nothing was delivered.
    let isHalted: Bool

    var titles: [String] { stages.map(\.title) }
    var current: Stage { stages[currentIndex] }
    /// The last stage is current and the conversion went through: every step is done.
    var isFinished: Bool { currentIndex == stages.count - 1 && !isHalted }

    /// "Krok 3 z 6: Autorizácia", the compact form of the indicator.
    var compactText: String {
        "Krok \(currentIndex + 1) z \(stages.count): \(current.title)"
    }

    static func make(direction: ConversionDirection,
                     step: ZakoSessionStore.Step,
                     isRecordFirst: Bool,
                     pendingStage: RecordFirstPending.Stage?,
                     rowStatus: EvidenceRecord.Status?) -> ZakoStepProgress {
        let first: Stage = direction == .electronicToElectronic ? .verification : .analysis
        let stages: [Stage] = isRecordFirst
            ? [first, .attestation, .authorize, .recordInEZZK, .clauseSignature, .done]
            : [first, .attestation, .authorize, .done]
        var current: Stage
        var waiting = false
        var halted = false
        switch step {
        case .intake, .analysis, .verification:
            current = first
        case .attestation:
            current = .attestation
        case .authorize:
            switch pendingStage {
            case .awaitingEZZK?: current = .recordInEZZK; waiting = true
            case .signingClientContainer?: current = .clauseSignature
            case nil: current = .authorize
            }
        case .done:
            switch pendingStage {
            case .awaitingEZZK?: current = .recordInEZZK; waiting = true
            case .signingClientContainer?: current = .clauseSignature
            case nil:
                // Record-first: a rejected or unsigned record ends the conversion with nothing
                // delivered, never as "Hotovo". In today's order the client output is already
                // delivered, so the conversion is done whatever EZZK says later.
                if isRecordFirst, rowStatus == .rejected || rowStatus == .recordUnsigned {
                    current = .recordInEZZK
                    halted = true
                } else {
                    current = .done
                }
            }
        }
        if !isRecordFirst, current == .recordInEZZK || current == .clauseSignature {
            current = .authorize
            waiting = false
        }
        return ZakoStepProgress(stages: stages,
                                currentIndex: stages.firstIndex(of: current) ?? 0,
                                isWaitingForEZZK: waiting,
                                isHalted: halted)
    }
}

/// What the ZaKo conversion header shows above every step after intake: the document, the
/// step indicator and the conversion's own settings (order, client output, EZZK environment).
struct ZakoConversionHeaderModel: Equatable {
    static let recordFirstChip = "Postup od 2027"

    let documentName: String
    let progress: ZakoStepProgress
    let isRecordFirst: Bool
    /// "Kontajner ASiC-E" or "Jeden PDF", once the output is chosen; nil before.
    let outputChip: String?
    let environment: AppSettings.EZZKMode?

    static func outputChip(for output: AppSettings.ZakoClientOutput?) -> String? {
        switch output {
        case .asicContainer?: "Kontajner ASiC-E"
        case .singlePDF?: "Jeden PDF"
        case nil: nil
        }
    }

    /// The conversion's facts, never only the current Settings: a stored conversion keeps the
    /// order, output and environment it started with, and a finished row says what it was.
    struct Input {
        var documentName: String
        var direction: ConversionDirection
        var step: ZakoSessionStore.Step
        var pending: RecordFirstPending?
        var row: EvidenceRecord?
        /// The order by the Mac's clock for the current mode (`expectedRegimeNow`).
        var recordFirstByClock: Bool
        var outputSetting: AppSettings.ZakoClientOutput
        var evidenceNumberMode: AppSettings.EZZKMode?
        var currentMode: AppSettings.EZZKMode
    }

    static func make(_ input: Input) -> ZakoConversionHeaderModel {
        let rowRecordFirst = input.row?.formPack.map { $0.recordVersion == OfficialForm.record_1_2.version }
        let isRecordFirst: Bool
        if input.pending != nil {
            isRecordFirst = true
        } else if input.step == .done, let rowRecordFirst {
            isRecordFirst = rowRecordFirst
        } else {
            isRecordFirst = input.recordFirstByClock
        }

        let output: AppSettings.ZakoClientOutput?
        if let pending = input.pending {
            output = pending.clientOutput
        } else if input.step == .done {
            output = input.row?.clientOutput ?? input.outputSetting
        } else if input.step == .authorize {
            output = input.outputSetting
        } else {
            output = nil
        }

        let environment = input.pending?.mode
            ?? (input.step == .done ? input.row?.ezzkMode : nil)
            ?? input.evidenceNumberMode
            ?? input.currentMode

        return ZakoConversionHeaderModel(
            documentName: input.documentName,
            progress: .make(direction: input.pending?.direction ?? input.direction,
                            step: input.step,
                            isRecordFirst: isRecordFirst,
                            pendingStage: input.pending?.stage,
                            rowStatus: input.row?.status),
            isRecordFirst: isRecordFirst,
            outputChip: outputChip(for: output),
            environment: environment)
    }
}

extension ZakoSessionStore {
    /// The conversion runs in the order of 1. 1. 2027: a stored record-first conversion, or
    /// the order the Mac's clock gives for the current EZZK mode and the preview setting.
    var isRecordFirstOrder: Bool {
        recordFirstPending != nil || expectedRegimeNow == .recordFirst
    }

    /// The document's name: the name the source was opened under, else the file, else the
    /// clause's original name (a stored conversion opened from the Register).
    var headerDocumentName: String {
        func nonEmpty(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return nonEmpty(sourceNameOverride)
            ?? nonEmpty(sourceURL?.lastPathComponent)
            ?? nonEmpty(attestation.originalDocumentName)
            ?? "Dokument"
    }

    var conversionHeaderModel: ZakoConversionHeaderModel {
        // The register row is not observable: the status checker's count redraws the header
        // when the periodic check moves the row on.
        _ = settingsStore.statusChecker.changeCount
        let pending = recordFirstPending
        return .make(.init(documentName: headerDocumentName,
                           direction: direction,
                           step: step,
                           pending: pending,
                           row: evidenceStore.record(id: currentRecordID),
                           recordFirstByClock: isRecordFirstOrder,
                           outputSetting: settings.zakoClientOutput,
                           evidenceNumberMode: attestation.evidenceNumberMode,
                           currentMode: settingsStore.ezzkAccountController.mode))
    }
}
