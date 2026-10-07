// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Observation
import UniformTypeIdentifiers

/// Documents Finder hands to Chevron7 ("Open With", a double click, a drop on the
/// Dock icon). They open in the signing section, where a container shows its
/// signature tree and validation.
@MainActor
@Observable
final class ExternalDocumentOpen {
    private(set) var requestCount = 0
    private var pending: [URL] = []

    /// PDFs and ASiC-E containers, recognised by extension: another app may
    /// declare the .asice type as its own on this Mac.
    static func acceptedURLs(_ urls: [URL]) -> [URL] {
        urls.filter { ["pdf", "asice", "sce"].contains($0.pathExtension.lowercased()) }
    }

    func receive(_ urls: [URL]) {
        let accepted = Self.acceptedURLs(urls)
        guard !accepted.isEmpty else { return }
        pending.append(contentsOf: accepted)
        requestCount += 1
    }

    /// Hands the waiting documents to exactly one window.
    func takePending() -> [URL] {
        defer { pending.removeAll() }
        return pending
    }
}

/// The types the open panel and the drop zone accept for an ASiC-E container.
/// Chevron7 imports `org.autogram.asice`, but where another app (Podpisuj,
/// D.Viewer) exports its own type for the extension, the system gives an .asice
/// that type instead, so both are listed.
enum ContainerFileTypes {
    static var asice: [UTType] {
        // `UTType(importedAs:)` hands back whichever type the system prefers for
        // the identifier's extension (Podpisuj's on the owner's Mac), so the
        // declared type is looked up by identifier first.
        let declared = UTType("org.autogram.asice") ?? UTType(importedAs: "org.autogram.asice", conformingTo: .data)
        let candidates = [declared] + ["asice", "sce"].compactMap { UTType(filenameExtension: $0) }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.identifier).inserted }
    }

    static var documents: [UTType] { [.pdf] + asice }
}
