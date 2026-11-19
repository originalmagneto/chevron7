// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// How a record-first conversion waiting in the background reads in the sidebar, the Register
/// and the notifications. Pure values, tested without SwiftUI.
enum RecordFirstPendingPresentation {
    struct State: Equatable {
        let label: String
        let symbol: String
        let tone: EZZKRecordPresentation.Tone
    }

    /// The state that replaces the row's EZZK state, or nil when the row's own state says more:
    /// a record not sent yet, a failed send or a late row keeps the Register's wording.
    static func state(stage: RecordFirstPending.Stage, rowStatus: EvidenceRecord.Status) -> State? {
        switch (stage, rowStatus) {
        case (.awaitingEZZK, .acceptedForProcessing), (.awaitingEZZK, .outcomeUnknown):
            State(label: "Čaká na EZZK", symbol: "hourglass", tone: .pending)
        case (.signingClientContainer, .processed):
            State(label: "Čaká na podpis doložky", symbol: "signature", tone: .warning)
        default:
            nil
        }
    }

    static func processedNotification(_ pending: RecordFirstPending) -> (title: String, body: String) {
        ("EZZK spracovalo záznam č. \(pending.evidenceNumber)",
         "\(documentName(pending)): podpíšte doložku s dokumentom pre klienta. Kliknutím otvoríte konverziu.")
    }

    static func rejectedNotification(_ pending: RecordFirstPending, code: Int?, description: String?) -> (title: String, body: String) {
        let detail = [code.map { "kód \($0)" }, description].compactMap { $0 }.joined(separator: ": ")
        return ("EZZK odmietlo záznam č. \(pending.evidenceNumber)",
                "\(documentName(pending))\(detail.isEmpty ? "" : " (\(detail))"). Doložka sa nevytvorí; skontrolujte údaje a začnite konverziu znova.")
    }

    static func documentName(_ pending: RecordFirstPending) -> String {
        let candidates = [pending.attestation.originalDocumentName, pending.containerDocumentName]
        return candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Konverzia"
    }
}
