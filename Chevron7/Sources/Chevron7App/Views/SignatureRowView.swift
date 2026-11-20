// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// One signature row, the same in the signature banner's bubble and the E→E verification:
/// verdict symbol, signer, "nový", qualification and verdict on the first line, the facts
/// under it, then the reason, a warning and the "Technický detail" disclosure.
struct SignatureRowView: View {
    enum Density {
        /// The banner's bubble: small type, two lines per fact at most.
        case compact
        /// A card in a ZaKo step: larger type, facts wrap in full.
        case regular
    }

    let model: SignatureRowModel
    var density: Density = .regular
    /// Whether "Technický detail" is open; owned by the screen, so it outlives a redraw.
    var detailExpanded: Binding<Bool>?
    @State private var localDetailExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 8) {
                Image(systemName: model.symbol)
                    .foregroundStyle(Self.tint(model.tone))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    header
                    facts
                }
            }
            // One element for VoiceOver; the disclosure below stays its own control.
            .accessibilityElement(children: .combine)
            if let detail = model.technicalDetail {
                technicalDetail(detail)
            }
        }
        .padding(.leading, CGFloat(model.depth) * 18)
    }

    private var compact: Bool { density == .compact }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(model.title)
                .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if model.isNew {
                Text("nový").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            ForEach(model.badges, id: \.self) { badge in
                Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let verdictLabel = model.verdictLabel {
                Text(verdictLabel)
                    .font(compact ? .caption2 : .caption.weight(.medium))
                    .foregroundStyle(Self.tint(model.tone))
            }
        }
    }

    @ViewBuilder
    private var facts: some View {
        let font: Font = compact ? .caption2 : .caption
        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(font).foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : nil)
                .fixedSize(horizontal: false, vertical: !compact)
        }
        if let reason = model.reason {
            Text(reason).font(font).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let warning = model.warning {
            Text(warning).font(font).foregroundStyle(.orange)
        }
    }

    private func technicalDetail(_ detail: String) -> some View {
        let expanded = detailExpanded ?? $localDetailExpanded
        // The label is a button too, so a click on the words opens it as the arrow does,
        // and either is reached with the keyboard.
        return DisclosureGroup(isExpanded: expanded) {
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Button("Technický detail") { expanded.wrappedValue.toggle() }
                .buttonStyle(.plain)
                .accessibilityHint("Zobrazí pôvodný text overenia")
        }
        .font(.caption)
        .padding(.leading, 24)
    }

    static func tint(_ tone: SignatureRowModel.Tone) -> Color {
        switch tone {
        case .valid: .green
        case .invalid: .red
        case .undetermined, .warning: .orange
        case .neutral: .secondary
        }
    }
}
