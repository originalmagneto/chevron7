// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// The steps of a record-first conversion as a vertical list: done steps checked with their
/// times, the current one highlighted, a refused one marked. Every state is said in words too.
struct ZakoConversionTimelineView: View {
    let timeline: ZakoConversionTimeline
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(timeline.steps) { step in
                row(step)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Priebeh konverzie")
    }

    private func row(_ step: ZakoConversionTimeline.Step) -> some View {
        let isCurrent = step.id == timeline.currentStep?.id
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: step.state.symbol)
                .foregroundStyle(color(step.state))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(compact ? .callout : .body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(step.state == .upcoming ? .secondary : .primary)
                if let detail = step.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(step.state == .failed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 0 : 4)
        .padding(.horizontal, compact ? 0 : 8)
        .background {
            if isCurrent, !compact {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state.accessibilityValue)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func color(_ state: ZakoConversionTimeline.StepState) -> Color {
        switch state {
        case .done: .green
        case .current: .accentColor
        case .upcoming: .secondary
        case .attention: .orange
        case .failed: .red
        }
    }
}
