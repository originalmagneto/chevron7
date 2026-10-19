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
            .onDrop(of: [UTType.pdf, .jpeg, .png, .tiff] + ContainerFileTypes.asice, isTargeted: $isTargeted) { providers in
                store.direction == .electronicToElectronic ? handleElectronicDrop(providers) : handleDrop(providers)
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
        case .verification:
            ZakoVerificationView(store: store)
        case .attestation:
            if store.direction == .electronicToElectronic {
                E2EAttestationFormView(store: store)
            } else {
                AttestationFormView(store: store)
                    .task(id: store.currentRecordID) {
                        store.preparePreflight()
                    }
            }
        case .authorize:
            AuthorizeView(store: store)
        case .done:
            DoneView(store: store)
        }
    }

    /// E→E: a signed PDF or an ASiC-E, always the original file itself (its bytes are the
    /// original's fingerprint), never a converted image.
    private func handleElectronicDrop(_ providers: [NSItemProvider]) -> Bool {
        let types = ContainerFileTypes.documents
        guard let (provider, type) = providers.lazy.compactMap({ provider in
            types.first { provider.hasItemConformingToTypeIdentifier($0.identifier) }.map { (provider, $0) }
        }).first else {
            store.lastError = "Zaručená konverzia elektronického dokumentu prijíma PDF alebo kontajner ASiC-E."
            return false
        }
        DroppedFileURL.load(from: provider, typeIdentifier: type.identifier) { sourceURL in
            guard let sourceURL else {
                Task { @MainActor in store.lastError = "Súbor sa nepodarilo otvoriť." }
                return
            }
            Task { @MainActor in
                await store.loadElectronicOriginal(at: sourceURL,
                                                   outputDirectory: sourceURL.deletingLastPathComponent(),
                                                   sourceName: sourceURL.deletingPathExtension().lastPathComponent)
            }
        }
        return true
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

        // A dropped PDF keeps its folder and name (`DroppedFileURL`); only a drop
        // that carries no file falls back to bytes.
        let bytesFileName = DroppedFileURL.pdfName(suggested: provider.suggestedName)
        let loadBytes: @Sendable () -> Void = {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    guard let tempURL = DroppedFileURL.temporaryFile(named: bytesFileName) else {
                        store.lastError = "Import dokumentu sa nepodaril."
                        return
                    }

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

        guard isPDF else {
            loadBytes()
            return true
        }
        DroppedFileURL.load(from: provider, typeIdentifier: typeIdentifier) { sourceURL in
            guard let sourceURL else {
                loadBytes()
                return
            }
            Task { @MainActor in
                await store.loadDocument(at: sourceURL,
                                         outputDirectory: sourceURL.deletingLastPathComponent(),
                                         sourceName: sourceURL.deletingPathExtension().lastPathComponent)
            }
        }
        return true
    }
}

// MARK: - Intake View for ZaKo
struct IntakeView: View {
    @Bindable var store: ZakoSessionStore
    @Binding var showOpenPanel: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("Pôvodný dokument je")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Pôvodný dokument", selection: $store.direction) {
                    Label("Listinný", systemImage: "doc.text").tag(ConversionDirection.paperToElectronic)
                    Label("Elektronický", systemImage: "signature").tag(ConversionDirection.electronicToElectronic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .fixedSize()
                .help("Listinný originál sa naskenuje a analyzuje; elektronický, ktorý klient podpísal, sa overí.")
            }

            DropzoneArtwork(icon: isElectronic ? "signature" : "arrow.down.doc.fill", tint: .indigo)

            VStack(spacing: 8) {
                Text(isElectronic ? "Potiahnite dokument podpísaný klientom sem" : "Potiahnite naskenovaný dokument sem")
                    .font(.title2.weight(.bold))

                Text(isElectronic
                     ? "PDF alebo kontajner .asice, ktorý klient podpísal. Chevron7 overí jeho podpisy a časové pečiatky (§ 36 ods. 4 zákona č. 305/2013 Z. z.) a pripojí osvedčovaciu doložku."
                     : "Originál alebo úradne osvedčená kópia vo formáte PDF. Chevron7 automaticky analyzuje strany, listy a bezpečnostné prvky podľa § 35-39 zákona č. 305/2013 Z. z.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)

                if isElectronic {
                    Text("V ostrej evidencii treba podpisy klienta overiť aj kvalifikovanou službou validácie (§ 3 ods. 4 vyhlášky č. 70/2021 Z. z.).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                }
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
                if isElectronic {
                    Label("Overenie podpisov", systemImage: "checkmark.seal")
                } else {
                    Label("Automatická AI detekcia", systemImage: "brain.head.profile")
                }
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

    private var isElectronic: Bool { store.direction == .electronicToElectronic }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = isElectronic ? ContainerFileTypes.documents : [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = isElectronic
            ? "Vyberte dokument podpísaný klientom (PDF alebo ASiC-E)."
            : "Vyberte naskenovaný dokument na zaručenú konverziu."
        let electronic = isElectronic
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if electronic {
                    await store.loadElectronicOriginal(at: url)
                } else {
                    await store.loadDocument(at: url)
                }
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
