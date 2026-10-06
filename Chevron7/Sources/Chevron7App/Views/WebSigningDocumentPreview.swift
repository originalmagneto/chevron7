// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import PDFKit
import Quartz

/// Every page of the PDF a portal asked to sign, scrollable, with Quick Look for a
/// full-size look before anything is signed.
struct WebSigningDocumentPreview: View {
    let document: PDFDocument
    let filename: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PDFPagesView(document: document)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            HStack {
                Text(document.pageCount == 1 ? "1 strana" : "\(document.pageCount) strán")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    WebSigningQuickLook.shared.show(document: document, filename: filename)
                } label: {
                    Label("Otvoriť náhľad", systemImage: "eye")
                }
                .controlSize(.small)
            }
        }
    }
}

private struct PDFPagesView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}

/// Quick Look needs a file, so the document is written to a private temporary
/// folder that is emptied before each preview.
@MainActor
final class WebSigningQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = WebSigningQuickLook()

    private var previewURL: URL?

    func show(document: PDFDocument, filename: String) {
        show(filename: filename, fallbackName: "dokument.pdf") { document.write(to: $0) }
    }

    /// A further document of the signature, which has no page preview of its own.
    func show(data: Data, filename: String) {
        show(filename: filename, fallbackName: "priloha") { (try? data.write(to: $0, options: [.atomic])) != nil }
    }

    private func show(filename: String, fallbackName: String, write: (URL) -> Bool) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Chevron7WebPreview", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (filename as NSString).lastPathComponent
            let url = folder.appendingPathComponent(name.isEmpty ? fallbackName : name)
            guard write(url) else { return }
            previewURL = url
        } catch {
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the preview with the signing prompt and removes the temporary copy.
    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
           panel.dataSource === self {
            panel.orderOut(nil)
            panel.dataSource = nil
        }
        if let previewURL {
            try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
        }
        previewURL = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }
}
