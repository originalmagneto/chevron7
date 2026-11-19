// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// Slovak texts and flags shared by the ZaKo Done screen and Register konverzií for a
/// row's EZZK submission state. Pure values, so the wording is tested without SwiftUI.
enum EZZKRecordPresentation {
    /// Revision 5 ruling 7, kept after the live check of ruling R12 (EZZK accepted a late
    /// record for processing).
    static let lateWarning =
        "Záznam sa neodoslal v deň pridelenia čísla. EZZK ho môže odmietnuť alebo evidovať ako oneskorený."
    static let resignLater =
        "Záznam podpíšte znova novou konverziou; opakovaný podpis z Registra príde neskôr."
    static let unknownExplanation =
        "EZZK mohlo záznam dostať, preto sa znova neodošle: najprv overte v EZZK, či ho má. Ak ho nemá, záznam sa odošle znova."

    enum Tone: Equatable {
        case success, pending, warning, failure
    }

    /// Whether EZZK has the record (accepted or processed; "Zapísané v CEZZK" from part A).
    static func isSent(_ status: EvidenceRecord.Status) -> Bool {
        switch status {
        case .submitted, .acceptedForProcessing, .processed: return true
        default: return false
        }
    }

    /// Whether EZZK refused the record, or part A marked the send as failed.
    static func isFailed(_ status: EvidenceRecord.Status) -> Bool {
        status == .rejected || status == .submissionFailed
    }

    /// Rows "Odoslať" may send: nothing reached EZZK yet (an unknown outcome is verified instead).
    static func isSendable(_ status: EvidenceRecord.Status) -> Bool {
        switch status {
        case .signed, .queuedForSubmission, .submissionFailed, .late: return true
        default: return false
        }
    }

    /// Rows "Overiť v EZZK" may look up.
    static func isVerifiable(_ status: EvidenceRecord.Status) -> Bool {
        status == .outcomeUnknown || status == .acceptedForProcessing
    }

    static func tone(for status: EvidenceRecord.Status) -> Tone {
        switch status {
        case .submitted, .acceptedForProcessing, .processed: return .success
        case .outcomeUnknown, .late: return .warning
        case .rejected, .recordUnsigned, .submissionFailed: return .failure
        case .draft, .awaitingNumber, .readyToSign, .signed, .queuedForSubmission: return .pending
        }
    }

    /// Why the row needs the advocate, in Slovak, or nil when it does not.
    static func stateExplanation(for record: EvidenceRecord) -> [String] {
        switch record.status {
        case .rejected:
            var line = "EZZK záznam odmietlo"
            if let code = record.ezzkResultCode { line = "EZZK vrátilo kód \(code)" }
            if let description = record.ezzkResultDescription, !description.isEmpty {
                line += ": \(description)"
            }
            return [line]
        case .outcomeUnknown:
            return nonEmpty(record.ezzkResultDescription) + [unknownExplanation]
        case .late:
            return [lateWarning] + nonEmpty(record.ezzkResultDescription)
        case .recordUnsigned:
            // A row from before B2 never had a record of its own, so there is nothing to warn about.
            guard record.ezzkMode != nil else { return nonEmpty(record.ezzkResultDescription) }
            return nonEmpty(record.ezzkResultDescription) + [unsignedWarning(for: record), resignLater]
        case .signed, .queuedForSubmission, .submissionFailed:
            return nonEmpty(record.ezzkResultDescription)
        default:
            return []
        }
    }

    /// The client documents already carry the number in their clause, but EZZK has no
    /// record under it; a new conversion gets a new number, so these outputs must not reach the client.
    static func unsignedWarning(for record: EvidenceRecord) -> String {
        let number = record.evidenceNumber.map { " \($0)" } ?? ""
        return "Dokumenty pre klienta nesú evidenčné číslo\(number), ku ktorému sa do EZZK neodoslal žiadny záznam. Neodovzdávajte ich klientovi: nová konverzia dostane nové evidenčné číslo."
    }

    static func modeLine(_ mode: AppSettings.EZZKMode?) -> String? {
        mode.map { "Režim EZZK pri podpise: \($0.label)" }
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.timeZone = EZZKEvidenceNumberPolicy.timeZone
        formatter.dateFormat = "d. M. yyyy HH:mm"
        return formatter.string(from: date)
    }

    private static func nonEmpty(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return [text]
    }
}

/// The EZZK part of the ZaKo Done screen, built from the stored register row.
struct ZakoDonePresentation: Equatable {
    enum Action: Equatable {
        case none
        /// "Odoslať do EZZK".
        case send
        /// "Overiť v EZZK"; `availableAt` is when an unknown outcome may be looked up.
        case verify(availableAt: Date?)
    }

    let title: String
    let symbol: String
    let tone: EZZKRecordPresentation.Tone
    let lines: [String]
    let action: Action
    let isActionEnabled: Bool
    /// What went wrong in the flow and is not already said above, or nil.
    let error: String?

    /// - Parameters:
    ///   - record: the conversion's register row, as stored now.
    ///   - lastError: the ZaKo flow's last error, and `lastErrorStatus` the row state it described.
    ///   - nextStatusCheck: when the row's next lookup is due (`EZZKStatusChecker.nextStatusCheck`).
    ///   - currentMode: the controller's EZZK mode; a row of another mode is not sent, but
    ///     is still looked up in its own mode's EZZK. Nil skips that check.
    ///   - productionAllowed: the production policy; a production row is sent or looked up
    ///     only when it allows consequential calls.
    init(record: EvidenceRecord?, lastError: String?, lastErrorStatus: EvidenceRecord.Status?,
         nextStatusCheck: Date?, now: Date,
         currentMode: AppSettings.EZZKMode? = nil,
         productionAllowed: Bool = false,
         recordFirstStage: RecordFirstPending.Stage? = nil) {
        guard let record else {
            title = "Konverzia nie je zapísaná v Registri konverzií"
            symbol = "exclamationmark.triangle.fill"
            tone = .failure
            lines = []
            action = .none
            isActionEnabled = false
            error = lastError
            return
        }
        let status = record.status
        var tone = EZZKRecordPresentation.tone(for: status)
        let title: String
        let symbol: String
        // Under the order of 1. 1. 2027 the record goes first: until the clause is signed,
        // nothing has been delivered to the client.
        switch (recordFirstStage, status) {
        case (.awaitingEZZK?, .acceptedForProcessing):
            title = "Záznam o konverzii je v EZZK a čaká na spracovanie"
            symbol = "hourglass"
            tone = .pending
        case (.awaitingEZZK?, .signed), (.awaitingEZZK?, .queuedForSubmission),
             (.awaitingEZZK?, .submissionFailed):
            title = "Záznam o konverzii je podpísaný, ešte nie je v EZZK"
            symbol = "tray.and.arrow.up.fill"
        case (.awaitingEZZK?, .late):
            title = "Záznam o konverzii je podpísaný a oneskorený"
            symbol = "clock.badge.exclamationmark.fill"
        case (.signingClientContainer?, .processed):
            title = "EZZK spracovalo záznam, doložka ešte nie je podpísaná"
            symbol = "signature"
            tone = .warning
        default:
        switch status {
        case .processed, .submitted:
            title = "Zaručená konverzia je dokončená, záznam je spracovaný v EZZK"
            symbol = "checkmark.seal.fill"
        case .acceptedForProcessing:
            title = "Zaručená konverzia je dokončená, EZZK prijalo záznam na spracovanie"
            symbol = "checkmark.seal.fill"
        case .outcomeUnknown:
            title = "Nie je známe, či EZZK záznam dostalo"
            symbol = "questionmark.circle.fill"
        case .rejected:
            title = "EZZK záznam o konverzii odmietlo"
            symbol = "xmark.seal.fill"
        case .recordUnsigned:
            title = "Dokumenty sú podpísané, záznam o konverzii nie"
            symbol = "exclamationmark.triangle.fill"
        case .late:
            title = "Dokumenty sú podpísané, záznam je oneskorený"
            symbol = "clock.badge.exclamationmark.fill"
        default:
            title = "Dokumenty sú podpísané, záznam ešte nie je v EZZK"
            symbol = "tray.and.arrow.up.fill"
        }
        }
        self.title = title
        self.symbol = symbol
        self.tone = tone

        var lines = EZZKRecordPresentation.stateExplanation(for: record)
        if status == .acceptedForProcessing {
            lines.append("Spracovanie záznamu sa overuje v EZZK automaticky.")
        }
        let mode = record.ezzkMode
        let offersAction = EZZKRecordPresentation.isSendable(status) || EZZKRecordPresentation.isVerifiable(status)
        if let currentMode, offersAction, mode == nil || (mode != currentMode && EZZKRecordPresentation.isSendable(status)) {
            // Like the Register: a row is sent only in the mode that allocated its number
            // and looked up in that mode's EZZK from any mode (a row without one, from
            // before part B2, never).
            lines.append(mode == nil ? EZZKStatusChecker.preB2RowMessage : EZZKStatusChecker.recordFromOtherModeMessage)
            action = .none
        } else if EZZKRecordPresentation.isSendable(status) {
            if mode == .production, !productionAllowed {
                lines.append(EZZKError.submissionUnavailable.errorDescription ?? "")
                action = .none
            } else {
                action = .send
            }
        } else if EZZKRecordPresentation.isVerifiable(status), mode != .production || productionAllowed {
            action = .verify(availableAt: status == .outcomeUnknown ? nextStatusCheck : nil)
        } else {
            action = .none
        }
        if case .verify(let availableAt?) = action, availableAt > now {
            lines.append("Overiť v EZZK bude možné od \(EZZKRecordPresentation.timeText(availableAt)).")
            isActionEnabled = false
        } else {
            isActionEnabled = action != .none
        }
        if let modeLine = EZZKRecordPresentation.modeLine(mode) { lines.append(modeLine) }
        self.lines = lines

        // The flow's error describes the row as ZaKo last saw it. Lines already shown, or
        // repeating the row's own description, are left out, and once the row has moved on
        // (the periodic check) none of it applies.
        var remaining: [String] = []
        if let lastError, lastErrorStatus == status {
            let description = record.ezzkResultDescription ?? ""
            remaining = lastError.split(separator: "\n").map(String.init).filter { line in
                !lines.contains(line) && (description.isEmpty || !line.contains(description))
            }
        }
        error = remaining.isEmpty ? nil : remaining.joined(separator: "\n")
    }
}

/// The counts in the Register konverzií header.
struct EvidenceRegisterSummary: Equatable {
    let total: Int
    /// EZZK has the record (accepted, processed, or part A's "Zapísané v CEZZK").
    let sent: Int
    /// Waiting to be sent or verified.
    let pending: Int
    /// Refused by EZZK, failed in part A, or the record was never signed.
    let failed: Int
    /// Demo rows: a local simulation that never reached EZZK, so none of the counts above
    /// includes them.
    let demo: Int

    init(records: [EvidenceRecord]) {
        total = records.count
        let real = records.filter { $0.ezzkMode != .demo }
        demo = total - real.count
        sent = real.filter { EZZKRecordPresentation.isSent($0.status) }.count
        failed = real.filter { Self.isFailure($0.status) }.count
        pending = real.filter { $0.status.isSubmissionPendingState && !Self.isFailure($0.status) }.count
    }

    private static func isFailure(_ status: EvidenceRecord.Status) -> Bool {
        EZZKRecordPresentation.isFailed(status) || status == .recordUnsigned
    }
}

/// What the Register's detail sheet and deadline column show for one row.
enum EvidenceRegisterDetail {
    struct Stage: Equatable {
        let label: String
        let done: Bool
        let failed: Bool
    }

    struct Fact: Equatable {
        let label: String
        let value: String
    }

    struct Actions: Equatable {
        /// "Odoslať".
        let canSend: Bool
        /// "Overiť v EZZK".
        let canVerify: Bool
        /// Why the row cannot be sent, or what sending it means, or nil.
        let note: String?
        /// "Odoslať znova": a record EZZK refused at submission (ruling R18).
        var canResend = false
        /// The confirmation shown before "Odoslať znova", naming EZZK's code and description.
        var resendConfirmation: String?
    }

    struct Deadline: Equatable {
        let text: String
        let tone: EZZKRecordPresentation.Tone
    }

    /// "Uložiť záznam…": the signed record the register keeps (the only copy), named as EZZK
    /// knows it (`<number>.record.asice`). Nil when the row has no readable record.
    static func storedRecordContainer(for record: EvidenceRecord,
                                      in store: LocalEvidenceStore) -> (fileName: String, data: Data)? {
        guard record.recordContainerPath != nil, let data = store.recordContainerData(for: record) else { return nil }
        let number = record.evidenceNumber.flatMap { $0.isEmpty ? nil : $0 } ?? record.id.uuidString
        return (ZakoRecordDeliveryBuilder.containerName(evidenceNumber: number), data)
    }

    static let recordContainerMissingMessage = "Podpísaný záznam o konverzii sa v Registri nenašiel."

    static func timeline(for record: EvidenceRecord) -> [Stage] {
        let status = record.status
        return [
            Stage(label: "Evidenčné číslo", done: record.evidenceNumber != nil, failed: false),
            Stage(label: "Autorizácia KEP", done: status.progressIndex >= 3, failed: false),
            Stage(label: "Záznam v EZZK", done: EZZKRecordPresentation.isSent(status),
                  failed: EZZKRecordPresentation.isFailed(status) || status == .recordUnsigned),
            Stage(label: "Spracovaný", done: status == .processed || status == .submitted, failed: false)
        ]
    }

    /// State, mode and whatever the row knows about its submission (nothing it lacks).
    static func submissionFacts(for record: EvidenceRecord) -> [Fact] {
        var facts = [
            Fact(label: "Stav", value: UXLabels.evidenceStatusLabel(for: record.status)),
            Fact(label: "Režim EZZK", value: record.ezzkMode?.label ?? "neuvedený")
        ]
        if let submittedAt = record.submittedAt {
            facts.append(Fact(label: "Odoslané", value: EZZKRecordPresentation.timeText(submittedAt)))
        }
        if let messageID = record.submissionMessageID, !messageID.isEmpty {
            facts.append(Fact(label: "ID správy", value: messageID))
        }
        let description = record.ezzkResultDescription.flatMap { $0.isEmpty ? nil : $0 }
        switch (record.ezzkResultCode, description) {
        case let (code?, description?):
            facts.append(Fact(label: "Výsledok EZZK", value: "\(code): \(description)"))
        case let (code?, nil):
            facts.append(Fact(label: "Výsledok EZZK", value: "\(code)"))
        case let (nil, description?):
            facts.append(Fact(label: "Posledná správa", value: description))
        case (nil, nil):
            break
        }
        if let lastLookupAt = record.lastLookupAt {
            facts.append(Fact(label: "Posledné overenie", value: EZZKRecordPresentation.timeText(lastLookupAt)))
        }
        return facts
    }

    /// A row is sent only while the EZZK mode that allocated its number is current, and
    /// looked up in that mode's EZZK from any mode; never when it has no mode (written before
    /// part B2, ruling R15), and in Production only when the production policy allows it
    /// (`productionAllowed`).
    static func actions(for record: EvidenceRecord, currentMode: AppSettings.EZZKMode,
                        productionAllowed: Bool = false, now: Date = Date()) -> Actions {
        let status = record.status
        let sendable = EZZKRecordPresentation.isSendable(status)
        let verifiable = EZZKRecordPresentation.isVerifiable(status)
        guard let mode = record.ezzkMode else {
            let needsNote = sendable || verifiable || status == .recordUnsigned
            return Actions(canSend: false, canVerify: false,
                           note: needsNote ? EZZKStatusChecker.preB2RowMessage : nil)
        }
        if status == .recordUnsigned {
            return Actions(canSend: false, canVerify: false, note: EZZKRecordPresentation.resignLater)
        }
        let resendable = status == .rejected && EZZKSubmissionCoordinator.canResend(record)
            && record.recordContainerPath != nil
        guard sendable || verifiable || resendable else { return Actions(canSend: false, canVerify: false, note: nil) }
        // A lookup only reads and goes to the row's own EZZK, so it is offered from any mode.
        if mode != currentMode, !verifiable {
            return Actions(canSend: false, canVerify: false, note: EZZKStatusChecker.recordFromOtherModeMessage)
        }
        if mode == .production, !productionAllowed {
            return Actions(canSend: false, canVerify: false, note: EZZKError.submissionUnavailable.errorDescription)
        }
        if resendable {
            return Actions(canSend: false, canVerify: false, note: nil,
                           canResend: true, resendConfirmation: resendConfirmation(for: record, now: now))
        }
        return Actions(canSend: sendable, canVerify: verifiable,
                       note: status == .late ? EZZKRecordPresentation.lateWarning : nil)
    }

    /// "EZZK záznam odmietlo (kód N: popis). Odoslať ho znova?", plus `lateWarning` when the
    /// row's number was allocated on an earlier Bratislava day: a manual resend of a record
    /// that old is exactly the case the warning is for.
    static func resendConfirmation(for record: EvidenceRecord, now: Date = Date()) -> String {
        let description = record.ezzkResultDescription.flatMap { $0.isEmpty ? nil : $0 }
        let reason: String
        switch (record.ezzkResultCode, description) {
        case let (code?, description?): reason = " (kód \(code): \(description))"
        case let (code?, nil): reason = " (kód \(code))"
        case let (nil, description?): reason = " (\(description))"
        case (nil, nil): reason = ""
        }
        var question = "EZZK záznam odmietlo\(reason). Odoslať ho znova?"
        if let allocatedAt = record.evidenceNumberAllocatedAt,
           !EZZKEvidenceNumberPolicy.isUsable(allocatedAt: allocatedAt, at: now) {
            question += " " + EZZKRecordPresentation.lateWarning
        }
        return question
    }

    /// The Register's deadline column. EZZK expects the record on the Bratislava day the
    /// number was allocated; a row past that day is late and says so.
    static func deadline(for record: EvidenceRecord, now: Date) -> Deadline {
        let status = record.status
        if EZZKRecordPresentation.isSent(status) {
            return Deadline(text: UXLabels.evidenceStatusLabel(for: status), tone: .success)
        }
        switch status {
        case .late:
            return Deadline(text: EZZKRecordPresentation.lateWarning, tone: .warning)
        case .outcomeUnknown:
            return Deadline(text: "Najprv overte v EZZK", tone: .warning)
        case .rejected, .recordUnsigned:
            return Deadline(text: UXLabels.evidenceStatusLabel(for: status), tone: .failure)
        default:
            break
        }
        let deadlineText = EZZKRecordPresentation.timeText(record.submissionDeadline)
        guard status.isSubmissionPendingState else {
            return Deadline(text: "Lehota: \(deadlineText)", tone: .pending)
        }
        if let allocatedAt = record.evidenceNumberAllocatedAt,
           EZZKEvidenceNumberPolicy.isUsable(allocatedAt: allocatedAt, at: now) {
            return Deadline(text: "Odoslať ešte dnes, do polnoci", tone: .warning)
        }
        if now > record.submissionDeadline {
            return Deadline(text: "Po lehote: \(deadlineText)", tone: .failure)
        }
        return Deadline(text: "Blíži sa lehota: do \(deadlineText)", tone: .warning)
    }
}
