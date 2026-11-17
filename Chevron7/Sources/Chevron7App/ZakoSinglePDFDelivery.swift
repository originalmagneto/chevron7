// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// Whether the one-PDF output may run in Ostrá evidencia at all. Off until a conversion has been
/// verified end to end in Testovacia evidencia, as with E→E.
enum SinglePDFProductionPolicy {
    static let enabled = false
    static let refusalMessage = "Výstup ako jeden PDF s doložkou Chevron7 v ostrej evidencii zatiaľ nevykonáva: najprv sa overuje v testovacej evidencii. Zvoľte kontajner ASiC-E alebo testovaciu evidenciu."
}

/// Renders the clause's readable pages; `ClausePresentationRenderer` is the real one, tests stub it.
protocol ClausePageRendering: Sendable {
    @MainActor func render(clauseXML: Data, form: OfficialForm) async throws -> Data
}

extension ClausePresentationRenderer: ClausePageRendering {}

/// App-side helpers of the one-PDF ZaKo output (the clause appended to the PDF/A and signed as
/// one PAdES document). The three ZaKo flows call these.
struct ZakoSinglePDFDelivery {
    static let mobileRefusal = "Jeden PDF s doložkou autorizujte kartou s mandátnym certifikátom."
    static let engineRefusal = "Jeden PDF s doložkou vyžaduje podpisový engine Chevron7."

    /// Final file name in `directory`, fixed before the clause: `containerDocumentName` when free,
    /// else `<stem>-konvertovane.pdf`, else `uniqueURL` of that.
    static func fixedTarget(in directory: URL, containerDocumentName: String,
                            fileManager: FileManager = .default) -> URL {
        let preferred = directory.appendingPathComponent(containerDocumentName)
        if !fileManager.fileExists(atPath: preferred.path) { return preferred }
        let stem = (containerDocumentName as NSString).deletingPathExtension
        return ConversionOutputNaming.uniqueURL(in: directory, fileName: "\(stem)-konvertovane.pdf",
                                                fileManager: fileManager)
    }

    /// Renders the pages from `clauseXML` and pairs them with the XDC.
    @MainActor
    static func appendedClause(clauseXML: Data, clauseXDCF: Data, clauseFileName: String,
                               form: OfficialForm, renderer: any ClausePageRendering) async throws -> AppendedClause {
        let pages = try await renderer.render(clauseXML: clauseXML, form: form)
        return AppendedClause(pages: pages, attachment: clauseXDCF, attachmentName: clauseFileName,
                              attachmentMimeType: AppendedClause.xdcMimeType)
    }

    static func refusal(mode: AppSettings.EZZKMode, viaMobile: Bool,
                        provider: QualifiedSigningProviding) -> String? {
        if mode == .production && !SinglePDFProductionPolicy.enabled {
            return SinglePDFProductionPolicy.refusalMessage
        }
        if viaMobile { return mobileRefusal }
        if !provider.supportsAppendedClause { return engineRefusal }
        return nil
    }
}
