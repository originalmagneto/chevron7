// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// A white SF Symbol on a tinted rounded square, as System Settings draws its panes.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension StatusPillModel.Tone {
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .off: "minus.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .attention: .orange
        case .off: .secondary
        case .info: .blue
        }
    }
}

/// A tinted capsule, not glass: glass belongs to the navigation layer.
struct StatusPill: View {
    let model: StatusPillModel
    /// The pane the pill describes, so VoiceOver reads its full meaning ("EZZK: Pripojené").
    var paneTitle: String?

    var body: some View {
        Label(model.text, systemImage: model.tone.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(model.tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(model.tone.color.opacity(0.15), in: Capsule())
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(paneTitle.map { "\($0): \(model.text)" } ?? model.text)
    }
}

struct SettingsPaneHeader: View {
    let pane: SettingsPane
    let pills: [StatusPillModel]

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIcon(symbol: pane.symbol, tint: pane.tint, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                Text(pane.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !pills.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { pillViews }
                        VStack(alignment: .leading, spacing: 4) { pillViews }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var pillViews: some View {
        ForEach(pills.indices, id: \.self) { StatusPill(model: pills[$0], paneTitle: pane.title) }
    }
}

/// Every pane: a grouped form whose first group is the header, as in System Settings.
struct SettingsPaneForm<Content: View>: View {
    let pane: SettingsPane
    let pills: [StatusPillModel]
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(pane: pane, pills: pills)
            }
            content()
        }
        .formStyle(.grouped)
    }
}

/// Marks an Advanced setting shown only because it holds a non-default value.
struct AdvancedBadge: View {
    var body: some View {
        Text("Rozšírené")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel("Rozšírené nastavenie")
    }
}

struct AdvancedSectionHeader: View {
    var title = "Rozšírené"

    var body: some View {
        Label(title, systemImage: "slider.horizontal.3")
    }
}

/// An error next to the control that caused it.
struct InlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.octagon.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
