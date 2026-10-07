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
        let detail: String
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
        let rows = treeRows(state.tree, newSignatureIDs: newSignatureIDs)
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
        let rows = inspection.signatures.map { row(for: $0, depth: 0, isNew: false) }
        return verdictModel(summary: Counts(inspection.signatures), names: namesSummary(inspection.signatures),
                            rows: rows, note: inspection.detail)
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

    private static func treeRows(_ tree: SignatureTree, newSignatureIDs: Set<String>) -> [Row] {
        let own = tree.signatures
            .sorted { newSignatureIDs.contains($0.id) && !newSignatureIDs.contains($1.id) }
            .map { row(for: $0, depth: 0, isNew: newSignatureIDs.contains($0.id)) }
        let documents = tree.documents.flatMap { document -> [Row] in
            switch document.content {
            case .plain:
                return []
            case .signed(_, let nested):
                let header = Row(id: "doc-" + document.name, title: document.name, verdict: nil, badges: [],
                                 detail: SignatureTreePresentation.signatureCount(nested.signatures.count),
                                 warning: nil, depth: 0, isNew: false)
                return [header] + nested.signatures.map { row(for: $0, depth: 1, isNew: newSignatureIDs.contains($0.id)) }
            case .skipped(.depthLimit):
                return [warningRow(document, "Podpisy v tomto súbore sa neoverovali (ďalšie vnorenie).")]
            case .skipped(.tooLarge):
                return [warningRow(document, "Podpisy v tomto súbore sa neoverovali (súbor je príliš veľký).")]
            case .failed:
                return [warningRow(document, "Podpisy v tomto súbore sa nepodarilo overiť.")]
            }
        }
        return own + documents
    }

    private static func warningRow(_ document: SignedDataObject, _ text: String) -> Row {
        Row(id: "doc-" + document.name, title: document.name, verdict: nil, badges: [], detail: "",
            warning: text, depth: 0, isNew: false)
    }

    private static func row(for signature: DocumentSignatureInfo, depth: Int, isNew: Bool) -> Row {
        var badges: [String] = []
        if let label = SignatureTreePresentation.qualificationLabel(signature.certificateQualification) {
            badges.append(label)
        }
        if signature.hasQualifiedTimestamp {
            badges.append("QTS")
        } else if signature.hasTimestamp {
            badges.append("Časová pečiatka")
        }
        var parts: [String] = []
        if let time = signature.signingTime { parts.append(timeFormatter.string(from: time)) }
        if !signature.coveredDocuments.isEmpty {
            parts.append("pokrýva " + signature.coveredDocuments.joined(separator: ", "))
        }
        return Row(id: signature.id, title: displayName(signature), verdict: signature.state, badges: badges,
                   detail: parts.joined(separator: " · "), warning: nil, depth: depth, isNew: isNew)
    }

    private static func displayName(_ signature: DocumentSignatureInfo) -> String {
        let name = signature.signerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? unknownSigner : name
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = "d. M. yyyy HH:mm"
        return formatter
    }()
}
