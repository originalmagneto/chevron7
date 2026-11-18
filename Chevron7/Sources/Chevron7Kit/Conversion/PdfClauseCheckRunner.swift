// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation

/// Runs the engine's `PdfClauseAppender` as a check only: would the source PDF/A with this clause
/// appended still be PDF/A-3b? Writes nothing, so ZaKo can refuse before a number is allocated.
public struct PdfClauseCheckRunner: Sendable {
    public enum Failure: LocalizedError, Equatable {
        /// veraPDF rule lines (at most five) of the result that is not PDF/A-3b.
        case notCompliant([String])
        /// The source or the clause could not be read (a signed or encrypted source included).
        case unreadable
        case engineUnavailable
        case failed

        public var errorDescription: String? {
            switch self {
            case .notCompliant:
                return "Výsledný PDF by nespĺňal PDF/A-3b. Konverzia sa nevykoná a evidenčné číslo zostane nepoužité."
            case .unreadable: return "PDF alebo doložku sa nepodarilo prečítať."
            case .engineUnavailable:
                return "Kontrola PDF/A nie je dostupná. Skontrolujte inštaláciu aplikácie Chevron7 a skúste znova."
            case .failed: return "Kontrola PDF/A sa nepodarila."
            }
        }
    }

    /// Runs the engine with these arguments after `-cp <classpath>`; returns exit status and stderr.
    public typealias Launch = PdfaFromSignedRunner.Launch

    private let launch: Launch?

    public init(launch: Launch? = nil) {
        self.launch = launch
    }

    public func check(source: Data, clause: AppendedClause) throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-clause-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let sourceURL = work.appendingPathComponent("source.pdf")
        let pagesURL = work.appendingPathComponent("pages.pdf")
        let attachmentURL = work.appendingPathComponent("attachment.bin")
        try source.write(to: sourceURL, options: [.atomic])
        try clause.pages.write(to: pagesURL, options: [.atomic])
        try clause.attachment.write(to: attachmentURL, options: [.atomic])
        let arguments = ["digital.slovensko.autogram.core.PdfClauseAppender", sourceURL.path, pagesURL.path,
                         attachmentURL.path, clause.attachmentName, clause.attachmentMimeType]
        let result: (status: Int32, stderr: String)
        do {
            result = try (launch ?? PdfaFromSignedRunner.engineLaunch())(arguments)
        } catch let failure as PdfaFromSignedRunner.Failure {
            guard failure == .engineUnavailable else { throw Failure.failed }
            throw Failure.engineUnavailable
        }
        switch result.status {
        case 0: return
        case 3:
            throw Failure.notCompliant(result.stderr.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
        case 2: throw Failure.unreadable
        default: throw Failure.failed
        }
    }
}
