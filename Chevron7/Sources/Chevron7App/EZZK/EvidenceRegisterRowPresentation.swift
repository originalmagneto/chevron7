// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// What one row of the Register's table shows besides its number: the state (a record-first
/// conversion waiting in the background reads as such), the direction, the client output,
/// the EZZK deadline and whether the row offers "Dokončiť".
struct EvidenceRegisterRowPresentation: Equatable {
    struct Label: Equatable {
        let text: String
        let symbol: String
    }

    let status: RecordFirstPendingPresentation.State
    let direction: Label
    /// "Kontajner ASiC-E" or "Jeden PDF"; nil for a row written before the output was stored.
    let output: String?
    /// Nil leaves the "Lehota EZZK" cell empty.
    let deadline: EvidenceRegisterDetail.Deadline?
    /// The conversion waits for its clause signature: "Dokončiť" opens it in ZaKo, exactly as
    /// the detail's "Dokončiť konverziu".
    let canFinish: Bool

    init(record: EvidenceRecord, pendingStage: RecordFirstPending.Stage?, now: Date) {
        if let stage = pendingStage,
           let waiting = RecordFirstPendingPresentation.state(stage: stage, rowStatus: record.status) {
            status = waiting
        } else {
            status = RecordFirstPendingPresentation.State(
                label: UXLabels.evidenceStatusLabel(for: record.status, isOverdue: record.isOverdue),
                symbol: record.status.sfSymbol,
                tone: EZZKRecordPresentation.tone(for: record.status))
        }
        direction = Self.direction(record.direction)
        output = ZakoConversionHeaderModel.outputChip(for: record.clientOutput)
        deadline = EvidenceRegisterDetail.deadline(for: record, now: now)
        canFinish = Self.canFinish(pendingStage: pendingStage)
    }

    /// The state as the table cell says it: beside "Dokončiť" the cell is narrow, so the
    /// waiting clause reads "Čaká na doložku" (the full label stays in the help tag).
    var tableStatusLabel: String {
        canFinish ? Self.finishableShortLabel : status.label
    }

    static let finishableShortLabel = "Čaká na doložku"

    /// The same condition as the detail footer's "Dokončiť konverziu".
    static func canFinish(pendingStage: RecordFirstPending.Stage?) -> Bool {
        pendingStage == .signingClientContainer
    }

    static func direction(_ direction: ConversionDirection) -> Label {
        switch direction {
        case .paperToElectronic: Label(text: "P→E", symbol: "doc.viewfinder")
        case .electronicToElectronic: Label(text: "E→E", symbol: "doc.on.doc")
        case .electronicToPaper: Label(text: "E→P", symbol: "printer")
        }
    }

    static func directionHelp(_ direction: ConversionDirection) -> String {
        switch direction {
        case .paperToElectronic: "Z listinnej do elektronickej podoby"
        case .electronicToElectronic: "Z elektronickej do elektronickej podoby"
        case .electronicToPaper: "Z elektronickej do listinnej podoby"
        }
    }
}

/// One summary tile above the Register: a short title that fits one compact row, the full
/// meaning in the tooltip.
struct EvidenceSummaryTile: Equatable, Identifiable {
    enum Tint: Equatable { case accent, success, attention, failure, quiet }

    let id: String
    let title: String
    let value: Int
    let symbol: String
    let tint: Tint
    let help: String

    /// Demo rows get a tile only when there are some.
    static func tiles(summary: EvidenceRegisterSummary, overdue: Int) -> [EvidenceSummaryTile] {
        var tiles = [
            EvidenceSummaryTile(id: "total", title: "Spolu", value: summary.total, symbol: "archivebox",
                                tint: .accent, help: "Konverzií v registri celkovo"),
            EvidenceSummaryTile(id: "sent", title: "V EZZK", value: summary.sent, symbol: "checkmark.seal.fill",
                                tint: .success, help: "Záznamy, ktoré EZZK prijalo alebo spracovalo"),
            EvidenceSummaryTile(id: "pending", title: "Na odoslanie", value: summary.pending,
                                symbol: "tray.and.arrow.up", tint: summary.pending > 0 ? .attention : .quiet,
                                help: "Záznamy, ktoré čakajú na odoslanie alebo overenie v EZZK"),
            EvidenceSummaryTile(id: "failed", title: "Neúspešné", value: summary.failed, symbol: "xmark.seal.fill",
                                tint: summary.failed > 0 ? .failure : .quiet,
                                help: "Záznamy odmietnuté v EZZK alebo nepodpísané"),
            EvidenceSummaryTile(id: "overdue", title: "Po lehote", value: overdue,
                                symbol: "clock.badge.exclamationmark", tint: overdue > 0 ? .failure : .quiet,
                                help: "Záznamy, ktoré prekročili zákonnú lehotu 24 h na zápis do CEZZK")
        ]
        if summary.demo > 0 {
            tiles.append(EvidenceSummaryTile(id: "demo", title: "Skúšobné", value: summary.demo,
                                             symbol: "theatermasks", tint: .quiet,
                                             help: "Konverzie v skúšobnom režime sú lokálna simulácia. Do EZZK sa nikdy neodoslali."))
        }
        return tiles
    }
}
