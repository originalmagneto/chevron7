// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// What the training window's overview step says, derived from the readiness
/// report alone. Pure, so every sentence and state is unit tested; the view
/// only lays it out. The rule behind "Pokračovať" stays `report.offerDue`.
struct DetectorTrainingOverview: Equatable {
    struct Meter: Equatable {
        var title: String
        var value: Int
        var target: Int
        var isMet: Bool { value >= target }
        var valueText: String { "\(value) z \(target)" }
        var fraction: Double { min(1, Double(value) / Double(max(target, 1))) }
    }

    struct KindRow: Equatable, Identifiable {
        var trainingLabel: String
        var title: String
        var symbol: String
        var count: Int
        var target: Int
        var id: String { trainingLabel }
        var isEnough: Bool { count >= target }
        var countText: String { "\(count)/\(target)" }
        /// Short state readable without colour.
        var stateText: String { isEnough ? "stačí" : "chýba \(target - count)" }
        var accessibilityText: String { "\(title), \(count) z \(target), \(stateText)" }
    }

    enum Readiness: Equatable {
        /// The gate is not met yet.
        case missing
        /// The gate is met and the offer is due: "Pokračovať" is enabled.
        case ready
        /// The gate is met, but learning, reminders or a snooze hold the offer.
        case held
    }

    var readiness: Readiness
    var headline: String
    var requirement: String
    var meters: [Meter]
    var kinds: [KindRow]
    /// Said once above the kind table.
    var kindsExplanation: String
    /// Visible next to the disabled "Pokračovať"; nil when it is enabled.
    var continueBlockedReason: String?

    static let kindsExplanationText =
        "Detektor sa naučí len druhy s aspoň \(DetectorTrainingReadiness.boxesPerLabelMinimum) príkladmi, ostatné pri trénovaní vynechá."

    static func make(report: DetectorTrainingReadiness, trainedBefore: Bool,
                     learnOn: Bool, offersEnabled: Bool, snoozedUntil: Date?,
                     now: Date = Date()) -> DetectorTrainingOverview {
        let firstPages = DetectorTrainingReadiness.firstRunPages
        let firstDocs = DetectorTrainingReadiness.firstRunDocuments
        let retrain = DetectorTrainingReadiness.retrainNewPages

        let meters: [Meter]
        let requirement: String
        let missingParts: [(count: Int, one: String, few: String, many: String)]
        if trainedBefore {
            meters = [Meter(title: "Nové strany od posledného trénovania",
                            value: report.newSinceLastTraining, target: retrain)]
            requirement = "Na ďalšie trénovanie treba \(UXLabels.count(retrain, one: "novú skontrolovanú stranu", few: "nové skontrolované strany", many: "nových skontrolovaných strán")) od posledného trénovania."
            missingParts = [(max(0, retrain - report.newSinceLastTraining), "nová strana", "nové strany", "nových strán")]
        } else {
            meters = [Meter(title: "Skontrolované strany", value: report.reviewedPages, target: firstPages),
                      Meter(title: "Dokumenty", value: report.documents, target: firstDocs)]
            requirement = "Na prvé trénovanie treba \(UXLabels.count(firstPages, one: "stranu", few: "strany", many: "strán")) aspoň z \(UXLabels.count(firstDocs, one: "dokumentu", few: "dokumentov", many: "dokumentov"))."
            missingParts = [(max(0, firstPages - report.reviewedPages), "strana", "strany", "strán"),
                            (max(0, firstDocs - report.documents), "dokument", "dokumenty", "dokumentov")]
        }
        let gateMet = meters.allSatisfy(\.isMet)
        let readiness: Readiness = report.offerDue ? .ready : (gateMet ? .held : .missing)

        let headline: String
        let blockedReason: String?
        switch readiness {
        case .ready:
            headline = "Pripravené na trénovanie"
            blockedReason = nil
        case .missing:
            let parts = missingParts.filter { $0.count > 0 }
            let phrase = parts.map { UXLabels.count($0.count, one: $0.one, few: $0.few, many: $0.many) }
                .joined(separator: " a ")
            let verb = (parts.first.map { (2...4).contains($0.count) } ?? false) ? "chýbajú" : "chýba"
            headline = "Na \(trainedBefore ? "ďalšie" : "prvé") trénovanie \(verb) \(phrase)"
            blockedReason = trainedBefore
                ? "Pokračovať sa dá po \(UXLabels.count(retrain, one: "novej strane", few: "nových stranách", many: "nových stranách"))."
                : "Pokračovať sa dá po \(UXLabels.count(firstPages, one: "strane", few: "stranách", many: "stranách")) z \(UXLabels.count(firstDocs, one: "dokumentu", few: "dokumentov", many: "dokumentov"))."
        case .held:
            headline = "Strán je na trénovanie dosť"
            blockedReason = heldReason(learnOn: learnOn, offersEnabled: offersEnabled,
                                       snoozedUntil: snoozedUntil, now: now)
        }

        let labels = report.trainedLabels.sorted() + report.leftOutLabels.keys.sorted()
        let kinds = labels.map { label in
            let kind = VisionTrainSplit.kind(forTrainingLabel: label)
            return KindRow(trainingLabel: label, title: kind?.label ?? label,
                           symbol: symbol(for: kind),
                           count: report.boxesPerLabel[label] ?? report.leftOutLabels[label] ?? 0,
                           target: DetectorTrainingReadiness.boxesPerLabelMinimum)
        }

        return DetectorTrainingOverview(readiness: readiness, headline: headline,
                                        requirement: requirement, meters: meters, kinds: kinds,
                                        kindsExplanation: kindsExplanationText,
                                        continueBlockedReason: blockedReason)
    }

    private static func heldReason(learnOn: Bool, offersEnabled: Bool, snoozedUntil: Date?,
                                   now: Date) -> String {
        if !learnOn {
            return "Učenie z kontrol je vypnuté. Zapnite ho v Nastaveniach, AI a učenie."
        }
        if !offersEnabled {
            return "Pripomínanie trénovania je vypnuté. Zapnite ho v Nastaveniach, AI a učenie (Rozšírené nastavenia)."
        }
        if let snoozedUntil, snoozedUntil > now {
            let date = snoozedUntil.formatted(.dateTime.day().month(.defaultDigits).year()
                .locale(Locale(identifier: "sk_SK")))
            return "Trénovanie ste odložili do \(date)."
        }
        return "Trénovanie teraz nie je dostupné."
    }

    /// The symbol the window has always shown for a kind.
    static func symbol(for kind: SecurityElement.Kind?) -> String {
        switch kind {
        case .officialStamp: return "rosette"
        case .initial: return "scribble"
        case .waxSeal: return "seal"
        default: return kind?.sfSymbol ?? "questionmark.circle"
        }
    }
}
