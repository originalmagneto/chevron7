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

    private nonisolated static let folderPrefix = "chevron7-web-signatures-"

    /// Removes the copies a crash or a quit left behind while a panel was open: they hold
    /// documents from a portal, possibly personal data. Called once at launch, before any
    /// request can arrive, so it never takes the copy of a panel that is open.
    nonisolated static func removeStaleCopies(in root: URL = FileManager.default.temporaryDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) {
            let url = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            try? FileManager.default.removeItem(at: url)
        }
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
        let directory = temporaryRoot.appendingPathComponent(Self.folderPrefix + UUID().uuidString)
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

    /// Called when the person confirms the signature. INSPECT and SIGN share one engine
    /// helper, so a structural inspection still running (a large container) would hold up
    /// the signature; it is dropped, and with it the banner it had not filled yet rather
    /// than an orange "could not check". A validation already running stays: it has its
    /// own engine session, and `stop` ends it with the request.
    func cancelInspection() {
        loadTask?.cancel()
        loadTask = nil
        if let loader, loader.state.phase == .inspecting {
            loader.reset()
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
