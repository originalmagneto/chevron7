// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// Where a record-first conversion stands (the order of 1. 1. 2027): the record signed, sent to
/// EZZK, processed there, the clause signed, done. Built from the stored conversion and its
/// register row, so the waiting and done steps say what happened, when, and what comes next.
/// Pure value: the view only draws it.
struct ZakoConversionTimeline: Equatable {
    enum Phase: Equatable {
        /// The record is signed but EZZK does not have it yet (not sent, failed or late).
        case waitingNotSent
        /// Sent, but it is not known whether EZZK received it.
        case waitingOutcomeUnknown
        /// EZZK accepted the record and is processing it.
        case waitingSent
        /// EZZK processed the record: the clause waits for the advocate's signature.
        case ready
        /// The clause and the document for the client are being signed.
        case signing
        /// The client output is delivered.
        case done
        /// EZZK refused the record: nothing is delivered.
        case rejected
    }

    enum StepKind: String, CaseIterable {
        case recordSigned, sent, processing, clauseSigning, finished
    }

    enum StepState: Equatable {
        case done
        case current
        case upcoming
        /// Needs the advocate's attention (an unknown send outcome, a late or failed send).
        case attention
        case failed

        /// The state in words, so it never rests on color alone.
        var accessibilityValue: String {
            switch self {
            case .done: "hotovo"
            case .current: "prebieha"
            case .upcoming: "čaká"
            case .attention: "vyžaduje pozornosť"
            case .failed: "zlyhalo"
            }
        }

        var symbol: String {
            switch self {
            case .done: "checkmark.circle.fill"
            case .current: "circle.inset.filled"
            case .upcoming: "circle"
            case .attention: "exclamationmark.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    struct Step: Equatable, Identifiable {
        let kind: StepKind
        let title: String
        let state: StepState
        /// A time, an elapsed time or a reason; nil when there is nothing to add.
        let detail: String?

        var id: StepKind { kind }
    }

    nonisolated static let workOnLine =
        "Môžete pracovať ďalej. Keď EZZK záznam spracuje, ozveme sa upozornením."
    nonisolated static let usualTestDuration = "zvyčajne 10 až 30 minút"

    let phase: Phase
    let headline: String
    /// What comes next, or nil when nothing does.
    let line: String?
    let steps: [Step]

    /// The facts the timeline is built from.
    struct Input {
        var evidenceNumber: String?
        /// When the record was signed (`RecordFirstPending.recordSignedAt`, else the row's
        /// `createdAt`, which record-first writes only once the record is signed).
        var recordSignedAt: Date?
        var stage: RecordFirstPending.Stage?
        var row: EvidenceRecord?
        /// The EZZK mode the conversion runs in (its own, not the current setting).
        var mode: AppSettings.EZZKMode?
        var isSigningClause: Bool
        var isDelivered: Bool
        /// When the clause was signed (the delivered result), if known.
        var clauseSignedAt: Date?
        var now: Date
    }

    static func make(_ input: Input) -> ZakoConversionTimeline {
        let status = input.row?.status
        let phase: Phase
        if status == .rejected {
            phase = .rejected
        } else if input.isDelivered {
            phase = .done
        } else if input.isSigningClause {
            phase = .signing
        } else if input.stage == .signingClientContainer || status == .processed || status == .submitted {
            phase = .ready
        } else if status == .acceptedForProcessing {
            phase = .waitingSent
        } else if status == .outcomeUnknown {
            phase = .waitingOutcomeUnknown
        } else {
            phase = .waitingNotSent
        }

        let number = input.evidenceNumber ?? input.row?.evidenceNumber
        let numbered = number.map { " č. \($0)" } ?? ""
        let headline: String
        let line: String?
        switch phase {
        case .waitingNotSent:
            headline = "Záznam\(numbered) je podpísaný, ešte nie je v EZZK"
            line = "Odošlite ho tlačidlom Odoslať do EZZK. " + workOnLine
        case .waitingOutcomeUnknown:
            headline = "Nie je známe, či EZZK záznam\(numbered) dostalo"
            line = workOnLine
        case .waitingSent:
            headline = "Záznam\(numbered) čaká na spracovanie v EZZK"
            line = workOnLine
        case .ready:
            headline = "EZZK spracovalo záznam\(numbered)"
            line = "Podpíšte doložku s dokumentom pre klienta kartou s mandátnym certifikátom."
        case .signing:
            headline = "Podpisuje sa doložka s dokumentom pre klienta"
            line = nil
        case .done:
            headline = "Zaručená konverzia je dokončená"
            line = nil
        case .rejected:
            headline = "EZZK záznam\(numbered) odmietlo"
            line = "Doložka sa nevytvorí a klient nedostane nič. Skontrolujte údaje a začnite konverziu znova."
        }

        let now = input.now
        let row = input.row
        let sentDone = [.waitingSent, .ready, .signing, .done, .rejected].contains(phase)

        let recordStep = Step(kind: .recordSigned, title: "Záznam podpísaný", state: .done,
                              detail: input.recordSignedAt.map { timeText($0, now: now) })

        let sentStep: Step
        if sentDone {
            sentStep = Step(kind: .sent, title: "Odoslaný do EZZK", state: .done,
                            detail: row?.submittedAt.map { timeText($0, now: now) })
        } else if phase == .waitingOutcomeUnknown {
            sentStep = Step(kind: .sent, title: "Odoslanie do EZZK", state: .attention,
                            detail: "výsledok odoslania neznámy")
        } else {
            let detail: String
            let state: StepState
            switch status {
            case .submissionFailed?: detail = "odoslanie zlyhalo"; state = .attention
            case .late?: detail = "oneskorený"; state = .attention
            default: detail = "ešte neodoslaný"; state = .current
            }
            sentStep = Step(kind: .sent, title: "Odoslanie do EZZK", state: state, detail: detail)
        }

        let processingStep: Step
        switch phase {
        case .waitingSent:
            var parts: [String] = []
            if let sentAt = row?.submittedAt { parts.append("čaká \(elapsedText(from: sentAt, to: now))") }
            if input.mode == .test { parts.append(usualTestDuration) }
            processingStep = Step(kind: .processing, title: "EZZK spracúva", state: .current,
                                  detail: parts.isEmpty ? nil : parts.joined(separator: ", "))
        case .ready, .signing, .done:
            processingStep = Step(kind: .processing, title: "EZZK spracovalo", state: .done,
                                  detail: row?.lastLookupAt.map { timeText($0, now: now) })
        case .rejected:
            processingStep = Step(kind: .processing, title: "EZZK záznam odmietlo", state: .failed,
                                  detail: rejectionDetail(row))
        case .waitingNotSent, .waitingOutcomeUnknown:
            processingStep = Step(kind: .processing, title: "Spracovanie v EZZK", state: .upcoming,
                                  detail: input.mode == .test ? usualTestDuration : nil)
        }

        let clauseStep: Step
        switch phase {
        case .ready:
            clauseStep = Step(kind: .clauseSigning, title: "Podpis doložky", state: .current, detail: "čaká na vás")
        case .signing:
            clauseStep = Step(kind: .clauseSigning, title: "Podpis doložky", state: .current, detail: "prebieha")
        case .done:
            clauseStep = Step(kind: .clauseSigning, title: "Doložka podpísaná", state: .done,
                              detail: input.clauseSignedAt.map { timeText($0, now: now) })
        case .rejected:
            clauseStep = Step(kind: .clauseSigning, title: "Podpis doložky", state: .upcoming, detail: "nebude")
        default:
            clauseStep = Step(kind: .clauseSigning, title: "Podpis doložky", state: .upcoming, detail: nil)
        }

        let finishedStep = Step(kind: .finished, title: "Hotovo", state: phase == .done ? .done : .upcoming,
                                detail: phase == .done ? "výstup pre klienta uložený" : nil)

        return ZakoConversionTimeline(phase: phase, headline: headline, line: line,
                                      steps: [recordStep, sentStep, processingStep, clauseStep, finishedStep])
    }

    /// The step the conversion stands at: the first one not done.
    var currentStep: Step? {
        steps.first { $0.state != .done }
    }

    private static func rejectionDetail(_ row: EvidenceRecord?) -> String? {
        let parts = [row?.ezzkResultCode.map { "kód \($0)" },
                     row?.ezzkResultDescription.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }

    /// The time alone on the same Bratislava day, else the date with it.
    static func timeText(_ date: Date, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = EZZKEvidenceNumberPolicy.timeZone
        guard calendar.isDate(date, inSameDayAs: now) else { return EZZKRecordPresentation.timeText(date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.timeZone = EZZKEvidenceNumberPolicy.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "menej ako minútu", "12 min", "1 h 5 min".
    static func elapsedText(from start: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        if minutes < 1 { return "menej ako minútu" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The done presentation's lines the timeline does not already say: the rejection reason
    /// sits at the EZZK step, the automatic check in the waiting line, and the environment in
    /// the conversion header.
    static func supplementaryLines(_ lines: [String], record: EvidenceRecord?) -> [String] {
        var covered: Set<String> = ["Spracovanie záznamu sa overuje v EZZK automaticky."]
        if let record {
            if record.status == .rejected {
                covered.formUnion(EZZKRecordPresentation.stateExplanation(for: record))
            }
            if let modeLine = EZZKRecordPresentation.modeLine(record.ezzkMode) { covered.insert(modeLine) }
        }
        return lines.filter { !covered.contains($0) }
    }
}

extension ZakoSessionStore {
    /// The record-first timeline of this session's conversion, or nil when it does not run in
    /// that order or has no register row.
    func conversionTimeline(now: Date) -> ZakoConversionTimeline? {
        let pending = recordFirstPending
        let row = evidenceStore.record(id: pending?.recordID ?? currentRecordID)
        guard pending != nil || (row != nil && conversionHeaderModel.isRecordFirst) else { return nil }
        return .make(.init(evidenceNumber: pending?.evidenceNumber ?? row?.evidenceNumber,
                           recordSignedAt: pending?.recordSignedAt ?? row?.createdAt,
                           stage: pending?.stage,
                           row: row,
                           mode: pending?.mode ?? row?.ezzkMode,
                           isSigningClause: isAuthorizing && pending != nil,
                           isDelivered: pending == nil && outputDirectory != nil,
                           clauseSignedAt: result?.signedAt,
                           now: now))
    }
}
