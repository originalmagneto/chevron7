// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

enum SignatureTreePresentation {
    static let officialValidationURL = URL(string: "https://www.slovensko.sk/sk/e-sluzby/sluzba-overenia-zep")!

    static func signatureCount(_ count: Int) -> String {
        switch count {
        case 1: "1 podpis"
        case 2...4: "\(count) podpisy"
        default: "\(count) podpisov"
        }
    }

    static func summaryText(_ summary: SignatureTreeSummary) -> String {
        var parts: [String] = []
        if summary.valid > 0 { parts.append("platné \(summary.valid)") }
        if summary.invalid > 0 { parts.append("neplatné \(summary.invalid)") }
        if summary.indeterminateSignatures > 0 { parts.append("neurčité \(summary.indeterminateSignatures)") }
        if summary.unverifiedDocuments > 0 { parts.append("neoverené súbory \(summary.unverifiedDocuments)") }
        var text = signatureCount(summary.total) + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", "))
        if summary.overall != .valid, let location = summary.worstLocation {
            text += " (v \(location))"
        }
        return text
    }

    static func phaseText(_ phase: SignatureTreeState.Phase) -> String? {
        switch phase {
        case .idle: nil
        case .inspecting: "Kontrolujem podpisy…"
        case .structural: "Overuje sa voči dôveryhodným zoznamom…"
        case .validated: "Informatívne overenie voči dôveryhodným zoznamom EÚ"
        case .validationUnavailable(let reason): reason
        case .failed: "Podpisy sa nepodarilo skontrolovať"
        }
    }

    /// Whether a data object's group should open by itself: it holds a signature that is not
    /// valid, or it could not be verified at all.
    static func needsAttention(_ content: SignedDataObject.Content) -> Bool {
        switch content {
        case .signed(_, let tree): SignatureTreeSummary(tree: tree).overall != .valid
        case .skipped, .failed: true
        case .plain: false
        }
    }

    /// Whether any entry directly inside a nested container was skipped or failed.
    static func hasUnverifiedEntries(_ tree: SignatureTree) -> Bool {
        tree.documents.contains { document in
            switch document.content {
            case .skipped, .failed: true
            case .signed, .plain: false
            }
        }
    }

    /// What a DSS SignatureQualification means to the signer. Nil before full validation
    /// (structural results carry none); anything but a qualified signature or seal is shown
    /// as not qualified, so a valid advanced signature never reads as a KEP.
    static func qualificationLabel(_ qualification: String?) -> String? {
        switch qualification {
        case nil: nil
        case "QESIG": "KEP"
        case "QESEAL": "Kvalifikovaná pečať"
        default: "Nekvalifikovaný"
        }
    }

    static func tint(_ state: DocumentSignatureInfo.State) -> Color {
        switch state {
        case .valid: .green
        case .invalid: .red
        case .indeterminate, .unknown: .orange
        }
    }

    static func icon(_ state: DocumentSignatureInfo.State) -> String {
        switch state {
        case .valid: "checkmark.seal.fill"
        case .invalid: "xmark.seal.fill"
        case .indeterminate, .unknown: "questionmark.seal.fill"
        }
    }
}

/// Signatures of a file grouped by where they sit: the container's own signatures, then
/// each data object that carries signatures of its own.
struct SignatureTreeView: View {
    let state: SignatureTreeState
    let emptyText: String
    /// The store is signing; a revalidation now would compete with it for the engine.
    let isBusy: Bool
    let onRevalidate: () -> Void
    @Environment(\.openURL) private var openURL

    private var summary: SignatureTreeSummary { SignatureTreeSummary(tree: state.tree) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.phase {
            case .idle:
                EmptyView()
            case .inspecting:
                ProgressView("Kontrolujem podpisy…").font(.caption)
            case .failed(let reason):
                Label("Podpisy sa nepodarilo skontrolovať", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .structural, .validated, .validationUnavailable:
                if summary.total == 0 && summary.unverifiedDocuments == 0 {
                    Text(emptyText).font(.caption).foregroundStyle(.secondary)
                } else {
                    header
                    treeContent
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.total > 1 || state.tree.isContainer {
                Label(SignatureTreePresentation.summaryText(summary),
                      systemImage: SignatureTreePresentation.icon(summary.overall))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SignatureTreePresentation.tint(summary.overall))
            }
            HStack(spacing: 6) {
                if state.isValidating {
                    ProgressView().controlSize(.mini)
                }
                if let text = SignatureTreePresentation.phaseText(state.phase) {
                    Text(text).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Overiť znova", action: onRevalidate)
                    .font(.caption2)
                    .buttonStyle(.link)
                    .disabled(state.isValidating || isBusy)
            }
        }
    }

    @ViewBuilder
    private var treeContent: some View {
        if state.tree.isContainer {
            if !state.tree.signatures.isEmpty {
                Text("Podpisy kontajnera").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(state.tree.signatures) { SignatureInfoRow(info: $0) }
            }
            ForEach(signedDocuments) { document in
                DataObjectGroup(document: document)
            }
            if !otherDocumentNames.isEmpty {
                Text("Ďalšie súbory v kontajneri: " + otherDocumentNames.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForEach(state.tree.signatures) { SignatureInfoRow(info: $0) }
        }
        Button("Overiť aj na slovensko.sk") { openURL(SignatureTreePresentation.officialValidationURL) }
            .font(.caption2)
            .buttonStyle(.link)
            .help("Otvorí informatívne overenie podpisov na slovensko.sk. Súbor tam nahráte sami.")
    }

    /// Data objects shown as their own group: signed ones, and ones that could not be verified.
    private var signedDocuments: [SignedDataObject] {
        state.tree.documents.filter { document in
            switch document.content {
            case .signed(_, let tree): !tree.signatures.isEmpty || tree.isContainer
            case .skipped, .failed: true
            case .plain: false
            }
        }
    }

    private var otherDocumentNames: [String] {
        let shown = Set(signedDocuments.map(\.name))
        return state.tree.documents.map(\.name).filter { !shown.contains($0) }
    }
}

private struct DataObjectGroup: View {
    let document: SignedDataObject
    @State private var isExpanded: Bool

    init(document: SignedDataObject) {
        self.document = document
        _isExpanded = State(initialValue: SignatureTreePresentation.needsAttention(document.content))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                switch document.content {
                case .signed(_, let tree):
                    ForEach(tree.signatures) { SignatureInfoRow(info: $0) }
                    if tree.isContainer {
                        let names = tree.documents.map(\.name).joined(separator: ", ")
                        Text("Obsahuje: " + names).font(.caption2).foregroundStyle(.secondary)
                        if SignatureTreePresentation.hasUnverifiedEntries(tree) {
                            Text("Niektoré súbory vo vnútri sa neoverovali.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                case .skipped(.depthLimit):
                    Text("Podpisy v tomto súbore sa neoverovali (ďalšie vnorenie).")
                        .font(.caption2).foregroundStyle(.orange)
                case .skipped(.tooLarge):
                    Text("Podpisy v tomto súbore sa neoverovali (súbor je príliš veľký).")
                        .font(.caption2).foregroundStyle(.orange)
                case .failed:
                    Text("Podpisy v tomto súbore sa nepodarilo overiť.")
                        .font(.caption2).foregroundStyle(.orange)
                case .plain:
                    EmptyView()
                }
            }
            .padding(.leading, 4)
        } label: {
            Label(label, systemImage: "doc.text")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        // Full validation can turn a group the user never opened into one that needs attention.
        // Open it then, and never close one the user opened.
        .onChange(of: SignatureTreePresentation.needsAttention(document.content)) { _, needs in
            if needs { isExpanded = true }
        }
    }

    private var label: String {
        if case .signed(_, let tree) = document.content {
            return document.name + " · " + SignatureTreePresentation.signatureCount(tree.signatures.count)
        }
        return document.name
    }
}
