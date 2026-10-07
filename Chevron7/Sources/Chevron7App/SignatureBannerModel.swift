// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// What the signature banner above a document says: one tone, a headline with the
/// signers, rows for the expansion and a note on how far validation got.
struct SignatureBannerModel: Equatable {
    enum Tone: Equatable { case checking, valid, warning, invalid }

    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let verdict: DocumentSignatureInfo.State?
        let badges: [String]
        /// "Platný", "Neplatný", "Neurčitý" or "Neoverené"; nil for a document row.
        let verdictLabel: String?
        let detail: String
        /// Why the validator did not call a signature valid, when it said.
        let reason: String?
        /// "Časová pečiatka: Belgium BOSA, kvalifikovaná · 7. 10. 2026 11:18:42"; nil without one.
        let timestamp: String?
        let warning: String?
        let depth: Int
        let isNew: Bool
    }

    let tone: Tone
    let headline: String
    let rows: [Row]
    let note: String?

    static let unknownSigner = "Neznámy podpisovateľ"

    // MARK: Builders

    static func make(from state: SignatureTreeState, newSignatureIDs: Set<String> = []) -> SignatureBannerModel? {
        switch state.phase {
        case .idle, .inspecting:
            return nil
        case .failed(let reason):
            return SignatureBannerModel(tone: .warning, headline: "Podpisy sa nepodarilo skontrolovať",
                                        rows: [], note: reason)
        case .structural, .validated, .validationUnavailable:
            break
        }
        let summary = SignatureTreeSummary(tree: state.tree)
        guard summary.total > 0 || summary.unverifiedDocuments > 0 else { return nil }
        let signatures = allSignatures(in: state.tree)
        let names = namesSummary(signatures)
        let rows = treeRows(state.tree, newSignatureIDs: newSignatureIDs, validated: state.phase == .validated)
        let note = SignatureTreePresentation.phaseText(state.phase)
        switch state.phase {
        case .structural:
            return SignatureBannerModel(
                tone: .checking,
                headline: "Overujem \(SignatureTreePresentation.signatureCount(summary.total)) voči dôveryhodným zoznamom…",
                rows: rows, note: note)
        case .validationUnavailable:
            return SignatureBannerModel(tone: .warning, headline: join("Podpisy sa nepodarilo overiť", names),
                                        rows: rows, note: note)
        default:
            return verdictModel(summary: Counts(summary), names: names, rows: rows, note: note)
        }
    }

    static func make(from inspection: InputSignatureInspectionResult) -> SignatureBannerModel? {
        guard inspection.state != .unavailable, !inspection.signatures.isEmpty else { return nil }
        // ZaKo inspects structurally: no authority names nor timestamp qualification.
        let rows = inspection.signatures.map {
            row(for: $0, depth: 0, isNew: false, validated: false, showsCoverage: false)
        }
        return verdictModel(summary: Counts(inspection.signatures), names: namesSummary(inspection.signatures),
                            rows: rows, note: inspection.detail)
    }

    /// Which signatures of `result` this session added, judged against the source's tree
    /// only once that tree was actually inspected: an idle, running or failed inspection
    /// leaves it empty, and every earlier signature would read as new.
    static func newSignatureIDs(existing: SignatureTreeState, result: SignatureTree) -> Set<String> {
        switch existing.phase {
        case .structural, .validated, .validationUnavailable:
            return newSignatureIDs(existing: existing.tree, result: result)
        case .idle, .inspecting, .failed:
            return []
        }
    }

    /// The signatures this session added: those whose id the source did not have, or, when
    /// the engine gave the same signatures other ids, the most recent ones by signing time.
    static func newSignatureIDs(existing: SignatureTree, result: SignatureTree) -> Set<String> {
        let before = allSignatures(in: existing)
        let after = allSignatures(in: result)
        let added = after.count - before.count
        guard added > 0 else { return [] }
        let beforeIDs = Set(before.map(\.id))
        let unseen = after.filter { !beforeIDs.contains($0.id) }
        if unseen.count == added { return Set(unseen.map(\.id)) }
        let newest = after.sorted { ($0.signingTime ?? .distantPast) > ($1.signingTime ?? .distantPast) }
        return Set(newest.prefix(added).map(\.id))
    }

    // MARK: Headlines

    private struct Counts {
        let total: Int
        let valid: Int
        let invalid: Int
        let notVerified: Int
        let unverifiedDocuments: Int

        init(_ summary: SignatureTreeSummary) {
            total = summary.total
            valid = summary.valid
            invalid = summary.invalid
            notVerified = summary.indeterminateSignatures
            unverifiedDocuments = summary.unverifiedDocuments
        }

        init(_ signatures: [DocumentSignatureInfo]) {
            total = signatures.count
            valid = signatures.filter { $0.state == .valid }.count
            invalid = signatures.filter { $0.state == .invalid }.count
            notVerified = signatures.filter { $0.state == .indeterminate || $0.state == .unknown }.count
            unverifiedDocuments = 0
        }
    }

    private static func verdictModel(summary: Counts, names: String, rows: [Row], note: String?) -> SignatureBannerModel {
        if summary.invalid > 0 {
            return SignatureBannerModel(tone: .invalid, headline: join(invalidPhrase(summary.invalid), names),
                                        rows: rows, note: note)
        }
        if summary.notVerified > 0 {
            let phrase = "\(summary.notVerified) z \(summary.total) \(genitivePlural(summary.total)) sa nedalo overiť"
            return SignatureBannerModel(tone: .warning, headline: join(phrase, names), rows: rows, note: note)
        }
        if summary.unverifiedDocuments > 0 {
            return SignatureBannerModel(tone: .warning, headline: join("Niektoré súbory v kontajneri sa neoverili", names),
                                        rows: rows, note: note)
        }
        return SignatureBannerModel(tone: .valid, headline: join(validPhrase(summary.total), names),
                                    rows: rows, note: note)
    }

    private static func validPhrase(_ count: Int) -> String {
        switch count {
        case 1: "Podpísané 1 podpisom, platný"
        case 2: "Podpísané 2 podpismi, oba platné"
        default: "Podpísané \(count) podpismi, všetky platné"
        }
    }

    private static func invalidPhrase(_ count: Int) -> String {
        switch count {
        case 1: "1 podpis je neplatný"
        case 2...4: "\(count) podpisy sú neplatné"
        default: "\(count) podpisov je neplatných"
        }
    }

    /// "1 z 2 podpisov": after "z" the noun is genitive plural for every count but one.
    private static func genitivePlural(_ count: Int) -> String {
        count == 1 ? "podpisu" : "podpisov"
    }

    private static func join(_ phrase: String, _ names: String) -> String {
        names.isEmpty ? phrase : phrase + " · " + names
    }

    /// Up to two distinct signers, then "a N ďalší".
    static func namesSummary(_ signatures: [DocumentSignatureInfo]) -> String {
        var seen = Set<String>()
        let names = signatures.map(displayName).filter { seen.insert($0).inserted }
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " a \(names.count - 2) ďalší"
    }

    // MARK: Rows

    private static func allSignatures(in tree: SignatureTree) -> [DocumentSignatureInfo] {
        tree.signatures + tree.documents.flatMap { document -> [DocumentSignatureInfo] in
            if case .signed(_, let nested) = document.content { return allSignatures(in: nested) }
            return []
        }
    }

    private static func treeRows(_ tree: SignatureTree, newSignatureIDs: Set<String>, validated: Bool) -> [Row] {
        let own = tree.signatures
            .sorted { newSignatureIDs.contains($0.id) && !newSignatureIDs.contains($1.id) }
            .map { row(for: $0, depth: 0, isNew: newSignatureIDs.contains($0.id), validated: validated,
                       showsCoverage: tree.documents.count > 1) }
        return own + documentRows(tree.documents, depth: 0, path: "", newSignatureIDs: newSignatureIDs,
                                  validated: validated)
    }

    /// Data objects with signatures of their own, and those that could not be verified.
    /// An unsigned data object (the engine lists every PDF, an unsigned one as a signed PDF
    /// without signatures) is left out, as before. Ids carry the path, so the same signed
    /// file under two names never gives two rows one id.
    private static func documentRows(_ documents: [SignedDataObject], depth: Int, path: String,
                                     newSignatureIDs: Set<String>, validated: Bool) -> [Row] {
        documents.flatMap { document -> [Row] in
            let documentPath = path + document.name + "/"
            switch document.content {
            case .plain:
                return []
            case .signed(_, let nested):
                guard !nested.signatures.isEmpty || nested.isContainer else { return [] }
                let header = Row(id: "doc-" + documentPath, title: document.name, verdict: nil, badges: [],
                                 verdictLabel: nil,
                                 detail: SignatureTreePresentation.signatureCount(nested.signatures.count),
                                 reason: nil, timestamp: nil, warning: nil, depth: depth, isNew: false)
                let signatures = nested.signatures.map { signature in
                    row(for: signature, depth: depth + 1, isNew: newSignatureIDs.contains(signature.id),
                        validated: validated, showsCoverage: nested.documents.count > 1,
                        id: documentPath + signature.id)
                }
                return [header] + signatures
                    + documentRows(nested.documents.filter(isUnverified), depth: depth + 1, path: documentPath,
                                   newSignatureIDs: newSignatureIDs, validated: validated)
            case .skipped(.depthLimit):
                return [warningRow(document, path: documentPath, depth: depth,
                                   "Podpisy v tomto súbore sa neoverovali (ďalšie vnorenie).")]
            case .skipped(.tooLarge):
                return [warningRow(document, path: documentPath, depth: depth,
                                   "Podpisy v tomto súbore sa neoverovali (súbor je príliš veľký).")]
            case .failed:
                return [warningRow(document, path: documentPath, depth: depth,
                                   "Podpisy v tomto súbore sa nepodarilo overiť.")]
            }
        }
    }

    private static func isUnverified(_ document: SignedDataObject) -> Bool {
        switch document.content {
        case .skipped, .failed: true
        case .plain, .signed: false
        }
    }

    private static func warningRow(_ document: SignedDataObject, path: String, depth: Int, _ text: String) -> Row {
        Row(id: "doc-" + path, title: document.name, verdict: nil, badges: [], verdictLabel: nil, detail: "",
            reason: nil, timestamp: nil, warning: text, depth: depth, isNew: false)
    }

    private static func verdictLabel(_ state: DocumentSignatureInfo.State) -> String {
        switch state {
        case .valid: "Platný"
        case .invalid: "Neplatný"
        // DSS INDETERMINATE: the check could not conclude, typically because fresh
        // revocation data for a signature made moments ago is not published yet.
        case .indeterminate: "Neurčitý"
        case .unknown: "Neoverené"
        }
    }

    private static func row(for signature: DocumentSignatureInfo, depth: Int, isNew: Bool,
                            validated: Bool, showsCoverage: Bool, id: String? = nil) -> Row {
        var badges: [String] = []
        if let label = SignatureTreePresentation.qualificationLabel(signature.certificateQualification) {
            badges.append(label)
        }
        var parts: [String] = []
        if let time = signature.signingTime { parts.append("Podpísané " + minuteFormatter.string(from: time)) }
        if let format = signature.format, !format.isEmpty { parts.append(formatLabel(format)) }
        if showsCoverage, !signature.coveredDocuments.isEmpty {
            parts.append("pokrýva " + signature.coveredDocuments.joined(separator: ", "))
        }
        let reason = signature.state == .valid ? nil
            : signature.detail.flatMap { $0.isEmpty ? nil : $0 }
        return Row(id: id ?? signature.id, title: displayName(signature), verdict: signature.state, badges: badges,
                   verdictLabel: verdictLabel(signature.state), detail: parts.joined(separator: " · "),
                   reason: reason, timestamp: timestampLine(signature, validated: validated),
                   warning: nil, depth: depth, isNew: isNew)
    }

    /// Who issued the timestamp and whether it is qualified come from full validation only:
    /// the structural pass reports the issuer DN and judges no qualification.
    private static func timestampLine(_ signature: DocumentSignatureInfo, validated: Bool) -> String? {
        guard signature.hasTimestamp else { return nil }
        var head = "Časová pečiatka"
        if validated {
            var facts: [String] = []
            if let authority = signature.timestampAuthority, !authority.isEmpty { facts.append(authority) }
            facts.append(signature.hasQualifiedTimestamp ? "kvalifikovaná" : "nekvalifikovaná")
            head += ": " + facts.joined(separator: ", ")
        }
        guard let time = signature.timestampTime else { return head }
        return head + " · " + secondFormatter.string(from: time)
    }

    /// "XAdES_BASELINE_T" reads "XAdES Baseline T".
    private static func formatLabel(_ format: String) -> String {
        format.split(separator: "_").map { $0 == "BASELINE" ? "Baseline" : String($0) }.joined(separator: " ")
    }

    private static func displayName(_ signature: DocumentSignatureInfo) -> String {
        let name = signature.signerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? unknownSigner : name
    }

    private static let minuteFormatter = formatter("d. M. yyyy HH:mm")
    private static let secondFormatter = formatter("d. M. yyyy HH:mm:ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = format
        return formatter
    }
}
