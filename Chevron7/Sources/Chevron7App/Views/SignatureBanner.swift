// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

/// A document's signatures at a glance, above the document: tone, headline with the
/// signers, and the rows in a bubble under the banner, so the document never moves
/// however many signatures it carries. The same banner in signing, the Safari panel
/// and ZaKo.
struct SignatureBanner: View {
    let model: SignatureBannerModel
    var onRevalidate: (() -> Void)?
    var revalidateDisabled = false
    @State private var isShowingDetails = false
    /// The bubble opens with the list focused, not "Overiť znova": with keyboard navigation
    /// on, the first button otherwise showed a focus ring at once. Tab still reaches it.
    @FocusState private var listFocused: Bool
    @Environment(\.openURL) private var openURL

    init(model: SignatureBannerModel, onRevalidate: (() -> Void)? = nil, revalidateDisabled: Bool = false) {
        self.model = model
        self.onRevalidate = onRevalidate
        self.revalidateDisabled = revalidateDisabled
    }

    private var signatureCount: Int { model.rows.filter { $0.verdict != nil }.count }

    var body: some View {
        HStack(spacing: 8) {
            // The symbol and the headline read as one element; the details stay a button.
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
                Button {
                    isShowingDetails.toggle()
                } label: {
                    Label(signatureCount > 0 ? "Podpisy (\(signatureCount))" : "Podrobnosti",
                          systemImage: "signature")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(tint)
                .help("Zobrazí podrobnosti podpisov")
                .accessibilityLabel(signatureCount > 0
                    ? "Zobraziť " + SignatureTreePresentation.signatureCount(signatureCount)
                    : "Zobraziť podrobnosti")
                .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
                    details
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }

    /// At most about half a window high; more signatures scroll inside the bubble.
    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.rows) { row in
                        SignatureRowView(model: SignatureRowModel(row), density: .compact)
                        if row.id != model.rows.last?.id { Divider() }
                    }
                }
                .padding(12)
            }
            .frame(height: min(420, CGFloat(model.rows.count) * 66 + 16))
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            Divider()
            footer.padding(12)
        }
        .frame(width: 500)
        .defaultFocus($listFocused, true)
        .onAppear { listFocused = true }
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
