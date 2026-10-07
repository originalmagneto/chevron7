// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Observation
import Chevron7Kit

/// The signatures of a document a portal sent, for the banner in the signing panel.
/// Only bytes that are already signed (a PDF with a signature, a container) are
/// inspected, so the usual unsigned portal document costs no engine work. The document
/// arrives in memory; it is written to a private temporary file for the engine and
/// removed when the request ends. Validation never holds up the signature.
@MainActor
@Observable
final class WebSigningSignatureCheck {
    private(set) var loader: SignatureTreeLoader?
    private(set) var loadTask: Task<Void, Never>?
    private(set) var fileURL: URL?
    private let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
    }

    var bannerModel: SignatureBannerModel? {
        loader.flatMap { SignatureBannerModel.make(from: $0.state) }
    }

    static func inspects(fileName: String, data: Data) -> Bool {
        ExistingSignatureGuard.classify(fileName: fileName, data: data) != .unsignedPDF
            && (data.starts(with: Data("%PDF".utf8)) || data.starts(with: Data("PK".utf8)))
    }

    /// Sets everything up at once, so a `stop` that follows always finds it; only the
    /// engine work runs later, in `loadTask`, and a cancelled one never starts.
    func start(fileName: String, data: Data, provider: any QualifiedSigningProviding) {
        stop()
        guard Self.inspects(fileName: fileName, data: data) else { return }
        let directory = temporaryRoot.appendingPathComponent("chevron7-web-signatures-\(UUID().uuidString)")
        let lastComponent = (fileName as NSString).lastPathComponent
        let url = directory.appendingPathComponent(lastComponent.isEmpty ? "dokument" : lastComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        let loader = SignatureTreeLoader(provider: provider)
        self.loader = loader
        fileURL = url
        loadTask = Task {
            guard !Task.isCancelled else { return }
            await loader.load(url)
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        loader?.reset()
        loader = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        fileURL = nil
    }
}
