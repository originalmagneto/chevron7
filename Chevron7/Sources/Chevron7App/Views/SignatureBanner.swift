// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

/// A document's signatures at a glance, above the document: tone, headline with the
/// signers, and the rows inline once expanded. The same banner in signing, the Safari
/// panel and ZaKo; the expanded state is remembered for all of them.
struct SignatureBanner: View {
    let model: SignatureBannerModel
    var onRevalidate: (() -> Void)?
    var revalidateDisabled = false
    @AppStorage("signatures.bannerExpanded") private var isExpanded = false
    @Environment(\.openURL) private var openURL

    init(model: SignatureBannerModel, onRevalidate: (() -> Void)? = nil, revalidateDisabled: Bool = false) {
        self.model = model
        self.onRevalidate = onRevalidate
        self.revalidateDisabled = revalidateDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // The symbol and the headline read as one element; the disclosure stays a button.
                HStack(spacing: 8) {
                    if model.tone == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol).foregroundStyle(tint)
                    }
                    Text(model.headline)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                if !model.rows.isEmpty || model.note != nil {
                    Button(isExpanded ? "Skryť ▴" : "Podpisy ▾") { isExpanded.toggle() }
                        .buttonStyle(.link)
                        .accessibilityLabel(isExpanded ? "Skryť podpisy" : "Zobraziť podpisy")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if isExpanded {
                Divider().overlay(tint.opacity(0.3))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.rows) { row in
                        SignatureBannerRow(row: row)
                    }
                    footer
                }
                .padding(10)
            }
        }
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let note = model.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onRevalidate {
                Button("Overiť znova", action: onRevalidate)
                    .buttonStyle(.link)
                    .font(.caption2)
                    .disabled(revalidateDisabled || model.tone == .checking)
            }
            Button("Overiť aj na slovensko.sk") { openURL(SignatureTreePresentation.officialValidationURL) }
                .buttonStyle(.link)
                .font(.caption2)
                .help("Otvorí informatívne overenie podpisov na slovensko.sk. Súbor tam nahráte sami.")
        }
    }

    private var tint: Color {
        switch model.tone {
        case .checking: .secondary
        case .valid: .green
        case .warning: .orange
        case .invalid: .red
        }
    }

    private var symbol: String {
        switch model.tone {
        case .checking: "hourglass"
        case .valid: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .invalid: "xmark.seal.fill"
        }
    }
}

private struct SignatureBannerRow: View {
    let row: SignatureBannerModel.Row

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let verdict = row.verdict {
                Image(systemName: SignatureTreePresentation.icon(verdict))
                    .foregroundStyle(SignatureTreePresentation.tint(verdict))
                    .frame(width: 16)
            } else {
                Image(systemName: row.warning == nil ? "doc.text" : "exclamationmark.triangle.fill")
                    .foregroundStyle(row.warning == nil ? Color.secondary : Color.orange)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.title).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if row.isNew {
                        Text("nový").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    ForEach(row.badges, id: \.self) { badge in
                        Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if !row.detail.isEmpty {
                    Text(row.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let warning = row.warning {
                    Text(warning).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .accessibilityElement(children: .combine)
    }
}
