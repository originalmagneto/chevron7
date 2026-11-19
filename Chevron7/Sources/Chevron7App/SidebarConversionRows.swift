// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// The sidebar's "Zaručené konverzie" section: the newest register rows, each with its
/// name, evidence number and EZZK state. Pure values, so the selection and the wording
/// are tested without SwiftUI; the state texts, symbols and tones are the Register's own.
enum SidebarConversionRows {
    /// Rows shown before "Zobraziť všetky" opens the Register.
    static let previewCount = 5

    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let evidenceNumber: String
        let stateLabel: String
        let symbol: String
        let tone: EZZKRecordPresentation.Tone
        /// A record-first conversion waiting in the background: the row opens it in ZaKo.
        var pendingStage: RecordFirstPending.Stage? = nil

        var accessibilityLabel: String {
            "Zaručená konverzia \(name), evidenčné číslo \(evidenceNumber), stav \(stateLabel)"
        }
    }

    struct Section: Equatable {
        let rows: [Row]
        /// Every row in the register, for "Zobraziť všetky (N)".
        let total: Int

        var isEmpty: Bool { total == 0 }
        var hasMore: Bool { total > rows.count }
    }

    /// The newest conversions first (by conversion time, then by when the row was written).
    static func section(from records: [EvidenceRecord], limit: Int = previewCount, now: Date,
                        pendingStages: [UUID: RecordFirstPending.Stage] = [:]) -> Section {
        let newest = records.sorted {
            $0.conversionTime != $1.conversionTime
                ? $0.conversionTime > $1.conversionTime
                : $0.createdAt > $1.createdAt
        }
        // A conversion waiting in the background stays in view even past the newest five.
        let shown = Array(newest.prefix(max(limit, 0)))
        let shownIDs = Set(shown.map(\.id))
        let waiting = newest.filter { pendingStages[$0.id] != nil && !shownIDs.contains($0.id) }
        return Section(rows: (shown + waiting).map { row(for: $0, now: now, pendingStage: pendingStages[$0.id]) },
                       total: records.count)
    }

    static func row(for record: EvidenceRecord, now: Date, pendingStage: RecordFirstPending.Stage? = nil) -> Row {
        // The Register marks a row past its 24-hour deadline in red ("Po lehote"); the
        // sidebar says the same, unless the state itself says what to do next.
        let isOverdue = record.status.isSubmissionPendingState && now > record.submissionDeadline
        let stateLabel = UXLabels.evidenceStatusLabel(for: record.status, isOverdue: isOverdue)
        let showsOverdue = stateLabel != UXLabels.evidenceStatusLabel(for: record.status)
        // A Demo row never reached EZZK: its number says so, its state is the simulation's.
        let isDemo = record.ezzkMode == .demo
        if let pendingStage,
           let waiting = RecordFirstPendingPresentation.state(stage: pendingStage, rowStatus: record.status) {
            return Row(id: record.id,
                       name: displayName(for: record),
                       evidenceNumber: (nonEmpty(record.evidenceNumber) ?? "nezískané") + (isDemo ? " · skúšobný režim" : ""),
                       stateLabel: waiting.label,
                       symbol: waiting.symbol,
                       tone: waiting.tone,
                       pendingStage: pendingStage)
        }
        return Row(id: record.id,
                   name: displayName(for: record),
                   evidenceNumber: (nonEmpty(record.evidenceNumber) ?? "nezískané") + (isDemo ? " · skúšobný režim" : ""),
                   stateLabel: isDemo ? "Skúšobný režim, mimo EZZK" : stateLabel,
                   symbol: showsOverdue ? "clock.badge.exclamationmark" : record.status.sfSymbol,
                   tone: showsOverdue ? .failure : EZZKRecordPresentation.tone(for: record.status))
    }

    /// The original's name, else the new document's, never an empty row.
    static func displayName(for record: EvidenceRecord) -> String {
        nonEmpty(record.originalName) ?? nonEmpty(record.newDocumentName) ?? "Bez názvu"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
