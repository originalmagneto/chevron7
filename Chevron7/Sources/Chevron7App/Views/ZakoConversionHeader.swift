// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

/// Above every ZaKo step after intake: the document, where the conversion stands and the
/// conversion's own settings (order, client output, EZZK environment). Every part falls back
/// to a narrower form, so the header never widens the window (`ZakoHeaderLayoutTests`).
struct ZakoConversionHeader: View {
    let model: ZakoConversionHeaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(model.documentName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.documentName)
                        // The name keeps some room: the chips step down to shorter forms first.
                        .frame(minWidth: 100, alignment: .leading)
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
                .layoutPriority(-1)
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    chips(environmentForm: .subject, showsSettings: true)
                    chips(environmentForm: .short, showsSettings: true)
                    chips(environmentForm: .short, showsSettings: false)
                }
            }
            ZakoStepIndicator(progress: model.progress)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chips(environmentForm: EZZKEnvironmentBadgeModel.Form, showsSettings: Bool) -> some View {
        HStack(spacing: 6) {
            if showsSettings {
                if model.isRecordFirst {
                    ZakoHeaderChip(text: ZakoConversionHeaderModel.recordFirstChip,
                                   help: "Záznam o konverzii sa podpisuje a posiela do EZZK pred doložkou (postup od 1. 1. 2027).",
                                   accessibility: "Postup od 1. 1. 2027: najprv záznam do EZZK, potom doložka")
                }
                if let output = model.outputChip {
                    ZakoHeaderChip(text: output, help: "Výstup pre klienta",
                                   accessibility: "Výstup pre klienta: \(output)")
                }
            }
            EZZKEnvironmentBadge(mode: model.environment, form: environmentForm)
        }
        .fixedSize()
    }
}

/// A neutral tinted capsule for a conversion setting.
private struct ZakoHeaderChip: View {
    let text: String
    let help: String
    let accessibility: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .help(help)
            .accessibilityLabel(accessibility)
    }
}

/// The steps with their titles when they fit, else the current step's title only, else
/// "Krok N z M: titul".
struct ZakoStepIndicator: View {
    let progress: ZakoStepProgress

    var body: some View {
        ViewThatFits(in: .horizontal) {
            steps(showsAllTitles: true)
            steps(showsAllTitles: false)
            Text(compactText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compactText)
    }

    private var compactText: String {
        if progress.isWaitingForEZZK { return progress.compactText + ", čaká na EZZK" }
        if progress.isHalted { return progress.compactText + ", konverzia sa zastavila" }
        return progress.compactText
    }

    private func steps(showsAllTitles: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(progress.stages.enumerated()), id: \.offset) { index, stage in
                let isComplete = index < progress.currentIndex || (index == progress.currentIndex && progress.isFinished)
                let isActive = index == progress.currentIndex
                HStack(spacing: 5) {
                    marker(stage: stage, isComplete: isComplete, isActive: isActive)
                    if showsAllTitles || isActive {
                        Text(stage.title)
                            .font(.caption.weight(isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    }
                }
                if index < progress.stages.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .fixedSize()
    }

    private func marker(stage: ZakoStepProgress.Stage, isComplete: Bool, isActive: Bool) -> some View {
        let halted = isActive && progress.isHalted
        let symbol = halted ? "xmark"
            : isComplete ? "checkmark"
            : isActive && progress.isWaitingForEZZK ? "hourglass"
            : stage.symbol
        let fill: Color = halted ? .red : isComplete ? .green : isActive ? .accentColor : Color.secondary.opacity(0.18)
        return ZStack {
            Circle().fill(fill).frame(width: 18, height: 18)
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isComplete || isActive ? Color.white : Color.secondary)
        }
    }
}
