// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit
import PDFKit
import UniformTypeIdentifiers
import AppKit

struct ZakoFlowView: View {
    @Bindable var store: ZakoSessionStore
    @State private var showOpenPanel = false
    @State private var isTargeted = false

    var body: some View {
        stepContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaPadding(.top)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay {
                if isTargeted { targetedOverlay }
            }
            .onDrop(of: [UTType.pdf, .jpeg, .png, .tiff], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
            .sheet(item: $store.cardPrompt) { prompt in
                ZakoCardPromptSheet(store: store, prompt: prompt)
                    .interactiveDismissDisabled()
            }
            .toolbar {
                if store.step != .intake {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            store.resetSession(keepingProfile: true)
                            store.step = .intake
                        } label: {
                            Label("Iný dokument", systemImage: "chevron.left")
                        }
                        .help("Vybrať iný dokument na konverziu")
                        .disabled(store.isAuthorizing)
                    }
            }
        }
    }

    private var targetedOverlay: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(12)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch store.step {
        case .intake:
            IntakeView(store: store, showOpenPanel: $showOpenPanel)
        case .analysis:
            AnalysisCanvasView(store: store)
        case .attestation:
            AttestationFormView(store: store)
                .task(id: store.currentRecordID) {
                    store.preparePreflight()
                }
        case .authorize:
            AuthorizeView(store: store)
        case .done:
            DoneView(store: store)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let pdfProvider = providers.first { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        let imageTypes = [UTType.jpeg, .png, .tiff, .heic]
        let imageProvider = imageTypes.first { type in
            providers.contains { $0.hasItemConformingToTypeIdentifier(type.identifier) }
        }

        let isPDF = pdfProvider != nil
        let typeIdentifier = isPDF ? UTType.pdf.identifier : (imageProvider?.identifier ?? UTType.png.identifier)
        guard let provider = pdfProvider ?? providers.first else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let sourceURL: URL?
            if let url = item as? URL {
                sourceURL = url
            } else if let url = item as? NSURL {
                sourceURL = url as URL
            } else if let data = item as? Data {
                sourceURL = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                sourceURL = nil
            }

            if let sourceURL, isPDF {
                let sourcePath = sourceURL.path
                let sourceDirectory = sourceURL.deletingLastPathComponent()
                Task { @MainActor in
                    await store.loadDocument(at: URL(fileURLWithPath: sourcePath),
                                             outputDirectory: sourceDirectory,
                                             sourceName: sourceURL.deletingPathExtension().lastPathComponent)
                }
                return
            }

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("zako-import-\(UUID().uuidString).pdf")

                if isPDF || data.starts(with: Data("%PDF".utf8)) {
                    do {
                        try data.write(to: tempURL)
                    } catch {
                        store.lastError = "Import dokumentu sa nepodaril: \(error.localizedDescription)"
                        return
                    }
                } else if let converted = ImageToPDFConverter.pdf(fromImageData: data) {
                    do {
                        try converted.write(to: tempURL)
                    } catch {
                        store.lastError = "Prevod obrázka sa nepodaril: \(error.localizedDescription)"
                        return
                    }
                } else {
                    store.lastError = "Vstupný súbor sa nepodarilo previesť do PDF."
                    return
                }
                await store.loadDocument(at: tempURL)
            }
            }
        }
        return true
    }
}

// MARK: - Intake View for ZaKo
struct IntakeView: View {
    let store: ZakoSessionStore
    @Binding var showOpenPanel: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            DropzoneArtwork(icon: "arrow.down.doc.fill", tint: .indigo)

            VStack(spacing: 8) {
                Text("Pretiahnite naskenovaný papierový dokument")
                    .font(.title2.weight(.bold))

                Text("Originál alebo úradne osvedčená kópia vo formáte PDF. Chevron7 automaticky analyzuje strany, listy a bezpečnostné prvky podľa § 35-39 zákona č. 305/2013 Z. z.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)

                // Scope: paper to electronic only. An electronic original would need its
                // qualified signatures checked by a qualified validation service.
                Text("Chevron7 robí zaručenú konverziu len z listinnej do elektronickej podoby. Konverziu elektronického dokumentu nepodporuje.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                    .help("Konverzia elektronického originálu by podľa § 3 ods. 4 vyhlášky č. 70/2021 Z. z. vyžadovala overenie jeho kvalifikovaných podpisov kvalifikovanou službou validácie.")
            }

            HStack(spacing: 12) {
                Button {
                    openPanel()
                } label: {
                    Label("Vybrať súbor…", systemImage: "folder")
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.indigo)
            }

            HStack(spacing: 16) {
                Label("Automatická AI detekcia", systemImage: "brain.head.profile")
                Label("Výpočet SHA-256 odtlačku", systemImage: "number.square")
                Label("Osvedčovacia doložka", systemImage: "building.columns")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)

            if let error = store.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Vyberte naskenovaný dokument na zaručenú konverziu."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await store.loadDocument(at: url)
            }
        }
    }
}

// MARK: - PDFKit Preview Wrapper
struct PDFKitPreview: NSViewRepresentable {
    let document: PDFDocument
    var stampState: StampOverlayState? = nil

    struct StampOverlayState {
        var rect: NormalizedRect
        var pageIndex: Int
        var image: NSImage?
        var title: String
        var onChange: (NormalizedRect) -> Void
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
