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
    /// Label for a DSS `SignatureQualification` name. DSS reached no negative conclusion for
    /// the INDETERMINATE_* and UNKNOWN* values (typically revocation or trust data was
    /// unavailable), so only the ADES*, NOT_ADES* and NA family counts as unqualified.
    static func qualificationLabel(_ qualification: String?) -> String? {
        switch qualification {
        case nil: nil
        case "QESIG": "KEP"
        case "QESEAL": "Kvalifikovaná pečať"
        case let name? where name.contains("INDETERMINATE") || name.contains("UNKNOWN"):
            "Kvalifikácia neurčená"
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
