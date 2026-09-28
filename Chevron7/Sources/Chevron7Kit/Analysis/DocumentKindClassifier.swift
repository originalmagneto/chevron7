// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import PDFKit
import Vision

/// Suggests the conversion clause's document kind from the first page text.
///
/// Embedded text first; when the page has no text layer (a scan), one accurate
/// Vision pass over the rendered page. A scan without readable text stays
/// silent instead of guessing. Keyword rules, most specific first; the
/// performing person always confirms, the suggestion never writes itself
/// into the clause.
public enum DocumentKindClassifier: Sendable {
    /// Labels in the attestation form's picker, without the fallback.
    public static let kinds = ["Zmluva", "Plná moc", "Rozsudok", "Osvedčenie", "Rozhodnutie"]
    public static let fallbackKind = "Iný dokument"

    public static func suggestKind(in document: PDFDocument) -> String? {
        suggestKind(firstPageText: document.page(at: 0)?.string)
    }

    /// One accurate Vision pass over the rendered first page, for scans with
    /// no text layer. Same request shape as `AccurateTextExclusions`.
    public static func recognizedFirstPageText(in document: PDFDocument, targetWidth: Int = 1200) async -> String? {
        guard let page = document.page(at: 0),
              let rendered = BuiltInVisionProvider.render(page: page, targetWidth: targetWidth) else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: rendered.cgImage) else { return nil }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(2000))
    }

    public static func suggestKind(firstPageText: String?) -> String? {
        guard let text = firstPageText, !text.isEmpty else { return nil }
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "sk_SK"))
            .lowercased()
        let head = String(folded.prefix(2000))
        if head.contains("pln"), head.contains("moc") { return "Plná moc" }
        if head.contains("rozsud") { return "Rozsudok" }
        if head.contains("rozhodnut") { return "Rozhodnutie" }
        if head.contains("osvedcen") { return "Osvedčenie" }
        if head.contains("zmluv") { return "Zmluva" }
        return nil
    }
}
