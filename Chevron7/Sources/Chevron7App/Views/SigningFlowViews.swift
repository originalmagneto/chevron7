// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import PDFKit
import Chevron7Kit
import UniformTypeIdentifiers
import AppKit

struct SigningFlowView: View {
    @Bindable var store: SigningSessionStore
    @State private var isTargeted = false

    var body: some View {
        stepContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaPadding(.top)
            .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isTargeted { targetedOverlay }
        }
        .onDrop(of: [UTType.pdf, UTType(importedAs: "org.autogram.asice", conformingTo: .data), .jpeg, .png, .tiff], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .task { await store.refreshIdentities() }
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
        if store.batchPhase != .idle || !store.batchItems.isEmpty {
            SigningBatchView(store: store)
        } else {
            switch store.step {
            case .intake:
                SigningIntakeView(store: store)
            case .prepare:
                SigningPrepareView(store: store)
            case .done:
                SigningDoneView(store: store)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let pdfProvider = providers.first { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        let asiceType = UTType(importedAs: "org.autogram.asice", conformingTo: .data)
        let asiceProvider = providers.first { $0.hasItemConformingToTypeIdentifier(asiceType.identifier) }
        let imageTypes = [UTType.jpeg, .png, .tiff, .heic]
        let imageProvider = imageTypes.compactMap { type in
            providers.first { $0.hasItemConformingToTypeIdentifier(type.identifier) } != nil ? type : nil
        }.first
        let isPDF = pdfProvider != nil || asiceProvider != nil
        let typeIdentifier = pdfProvider != nil
            ? UTType.pdf.identifier
            : (asiceProvider != nil ? asiceType.identifier : (imageProvider?.identifier ?? UTType.png.identifier))
        let provider = (pdfProvider ?? asiceProvider ?? providers.first)!
        let store = self.store

        // A dropped file keeps its own folder and its own name, so the signed
        // output lands beside the original instead of in a temporary directory
        // under a generated name. Only a drop that carries no file falls back to
        // bytes, and that output stays beside the temporary file.
        guard isPDF, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            importDroppedBytes(from: provider, typeIdentifier: typeIdentifier, isPDF: isPDF) { url in
                Task { @MainActor in await store.loadDocument(at: url) }
            }
            return true
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let sourceURL = DroppedFileURL.resolve(from: item) else {
                importDroppedBytes(from: provider, typeIdentifier: typeIdentifier, isPDF: isPDF) { url in
                    Task { @MainActor in await store.loadDocument(at: url) }
                }
                return
            }
            let path = sourceURL.path
            Task { @MainActor in
                await store.loadDocument(at: URL(fileURLWithPath: path))
            }
        }
        return true
    }
}

/// Writes a drop that carries no file to a temporary PDF, converting an image
/// when needed. Nonisolated so the fallback can also run from the item
/// provider's own callback.
private func importDroppedBytes(from provider: NSItemProvider,
                                typeIdentifier: String,
                                isPDF: Bool,
                                completion: @escaping @Sendable (URL) -> Void) {
    provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
        guard let data else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sign-import-\(UUID().uuidString).pdf")

        if isPDF || data.starts(with: Data("%PDF".utf8)) {
            try? data.write(to: tempURL)
        } else if let converted = ImageToPDFConverter.pdf(fromImageData: data) {
            try? converted.write(to: tempURL)
        } else {
            return
        }
        completion(tempURL)
    }
}

// MARK: - Step 1: Intake View
struct SigningIntakeView: View {
    let store: SigningSessionStore

    private var isDemoProvider: Bool {
        store.signingProvider is DemoSigningProvider
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            DropzoneArtwork(icon: "signature", tint: .accentColor)

            VStack(spacing: 8) {
                Text("Pretiahnite dokument na podpísanie")
                    .font(.title2.weight(.bold))

                Text("Podporované formáty: PDF, JPEG, PNG, TIFF. Chevron7 dokument podpíše kvalifikovaným elektronickým podpisom (KEP) s voliteľnou časovou pečiatkou.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
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
                .keyboardShortcut("o", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 16) {
                Label("PAdES / ASiC-E", systemImage: "doc.richtext")
                Label("Časová pečiatka QTS", systemImage: "clock.badge.checkmark")
                Label("Vizuálna pečiatka", systemImage: "seal")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)

            if isDemoProvider {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Demo režim podpisu: pre platný KEP pripojte eID kartu alebo čítačku.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }

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
        panel.allowedContentTypes = [.pdf, UTType(importedAs: "org.autogram.asice", conformingTo: .data)]
        panel.allowsMultipleSelection = true
        panel.message = "Vyberte PDF dokumenty na podpísanie."
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                let urls = panel.urls
                if urls.count == 1 {
                    await store.addDocuments(at: urls, selectLast: true)
                } else {
                    await store.addDocuments(at: urls, selectLast: false)
                    let selectedURLs = Set(urls.map(\.standardizedFileURL))
                    let ids = store.queue
                        .filter {
                            selectedURLs.contains($0.url.standardizedFileURL)
                                && ($0.status == .ready || $0.status == .failed)
                        }
                        .map(\.id)
                    await store.prepareBatch(ids: ids)
                }
            }
        }
    }
}

// MARK: - Step 2: Prepare & Settings View
enum SigningOutputFormatPresentation: CaseIterable, Identifiable {
    case embeddedPAdES
    case attachedASIC

    var id: String { format.rawValue }

    var format: SigningOutputFormat {
        switch self {
        case .embeddedPAdES:
            .embeddedPAdES
        case .attachedASIC:
            .attachedASIC
        }
    }

    var label: String {
        switch self {
        case .embeddedPAdES:
            "PAdES"
        case .attachedASIC:
            "ASiC-E / XAdES"
        }
    }

    var explanation: String {
        switch self {
        case .embeddedPAdES:
            "PAdES vloží podpis priamo do PDF dokumentu."
        case .attachedASIC:
            "ASiC-E / XAdES vytvorí kontajner s podpísaným PDF dokumentom."
        }
    }
}


/// Asks for the card's PIN when "Podpísať KEP" was pressed without one, then signs.
struct SigningPINSheet: View {
    @Bindable var store: SigningSessionStore
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    private var certificateLabel: String? {
        store.identities.first(where: { $0.id == store.selectedIdentityID })?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Zadajte PIN karty", systemImage: "lock.shield")
                .font(.headline)
            if let certificateLabel {
                Text("Certifikát: \(certificateLabel)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            SecureField("PIN karty", text: $pin, prompt: Text("PIN karty"))
                .textFieldStyle(.roundedBorder)
                .focused($pinFocused)
                .onSubmit(confirm)
            Text("PIN sa použije len na tento podpis a neukladá sa.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { store.isAskingForSigningPIN = false }
                    .keyboardShortcut(.cancelAction)
                Button("Podpísať", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { pinFocused = true }
    }

    private func confirm() {
        guard !pin.isEmpty else { return }
        store.signingPIN = pin
        store.isAskingForSigningPIN = false
        Task { await store.sign() }
    }
}

struct SigningPrepareView: View {
    @Bindable var store: SigningSessionStore
    @State private var customTSADraft = ""
    @State private var visualState: SignaturePlacementState?
    @FocusState private var signingPINFocused: Bool
    @State private var bridgePlacement: VisibleSignaturePlacement?
    @State private var isInspectorPresented = true

    var body: some View {
        VStack(spacing: 0) {
            previewColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            StickyActionBar {
                Button {
                    store.reset()
                    store.step = .intake
                } label: {
                    Label("Iný dokument", systemImage: "chevron.left")
                }
                .controlSize(.large)
                .disabled(store.isSigning)

                Spacer()

                mobileSignButton
                signButton
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            ScrollView {
                settingsContent
                    .padding(16)
            }
            .safeAreaPadding(.top)
            .inspectorColumnWidth(min: 300, ideal: MacOS27Layout.inspectorIdealWidth, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.reset()
                    store.step = .intake
                } label: {
                    Label("Iný dokument", systemImage: "chevron.left")
                }
                .help("Vybrať iný dokument na podpísanie")
                .disabled(store.isSigning)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Nastavenia podpisu", systemImage: "sidebar.trailing")
                }
                .help("Zobraziť alebo skryť nastavenia podpisu")
            }
        }
        .sheet(isPresented: $store.isAskingForSigningPIN) {
            SigningPINSheet(store: store)
        }
        .sheet(isPresented: Bindable(store.mobileSigning).isPresented) {
            if let session = store.mobileSigning.session {
                MobileSigningSheet(session: session) { store.mobileSigning.cancel() }
                    .interactiveDismissDisabled()
            }
        }
        .sheet(isPresented: Bindable(store.mobileSigning).isEidentitaPresented) {
            if let session = store.mobileSigning.eidentitaSession {
                EidentitaSigningSheet(session: session) { store.mobileSigning.cancelEidentita() }
                    .interactiveDismissDisabled()
            }
        }
        .task(id: store.document?.dataRepresentation()?.count ?? 0) {
            setupVisualComposition()
        }
        .task(id: "\(store.signingPIN)|\(store.includeVisibleSignature)") {
            guard store.includeVisibleSignature,
                  !store.signingProviderIsDemo,
                  !store.hasResolvedCertificate,
                  !store.signingPIN.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await resolveCertificateForPreview(relinquishApplicationFocus: false)
        }
        .onChange(of: bridgePlacement) { _, newValue in
            syncPlacementToStore(newValue)
        }
        .onChange(of: visualState?.placement) { _, newValue in
            if let newValue, newValue != bridgePlacement {
                bridgePlacement = newValue
            }
        }
        .onChange(of: store.bakedVisualStampIsBlocked, initial: true) { _, blocked in
            if blocked { store.includeVisibleSignature = false }
        }
        .onChange(of: store.includeVisibleSignature) { _, enabled in
            guard let visualState else { return }
            if enabled {
                visualState.setEnabled(true)
                if bridgePlacement == nil {
                    bridgePlacement = visualState.placement
                }
            } else {
                bridgePlacement = nil
            }
        }
        .onAppear {
            if let selected = store.identities.first(where: { $0.id == store.selectedIdentityID }),
               selected.requiresPIN, store.signingPIN.isEmpty {
                signingPINFocused = true
            }
        }
        .onChange(of: store.identities) { _, _ in
            refreshVisualCardContent()
            enableVisualCompositionIfReady()
        }
        .onChange(of: store.selectedIdentityID) { _, newID in
            refreshVisualCardContent()
            if let selected = store.identities.first(where: { $0.id == newID }),
               selected.requiresPIN, store.signingPIN.isEmpty {
                signingPINFocused = true
            }
        }
        .onChange(of: store.certificateLoadError) { _, _ in
            refreshVisualCardContent()
        }
        .onChange(of: store.isResolvingCertificate) { _, _ in
            refreshVisualCardContent()
        }
    }

    private func refreshVisualCardContent() {
        guard let visualState else { return }
        let identity = store.identities.first(where: { $0.id == store.selectedIdentityID })
        guard store.hasResolvedCertificate, let identity else {
            if let error = store.certificateLoadError {
                visualState.setContent(signerName: "Certifikát sa nenačítal", qualification: error)
            } else if store.isResolvingCertificate {
                visualState.setContent(signerName: "Načítavam certifikát…", qualification: nil)
            } else if store.isMobileSigningAvailable {
                // Without a PIN the card is unknown; mobile signing never needs one, so show the
                // neutral content that both paths can honour.
                visualState.setContent(
                    signerName: store.displayName(),
                    qualification: SigningSessionStore.qualifiedSignatureLabel,
                    timestampAuthorityName: store.includeQualifiedTimestamp ? store.settings.activeTSA.name : nil)
            } else {
                visualState.setContent(signerName: "Podpisový certifikát", qualification: "Zadajte PIN pre náhľad")
            }
            return
        }
        visualState.setContent(
            signerName: identity.label,
            certificateName: identity.label,
            qualification: identity.isQualified
                ? "Kvalifikovaný elektronický podpis"
                : "Nekvalifikovaný certifikát",
            timestampAuthorityName: store.addsQualifiedTimestamp(viaMobile: false) ? store.settings.activeTSA.name : nil
        )
    }

    private var usesBridgeComposition: Bool {
        store.includeVisibleSignature && visualState != nil
    }

    private func setupVisualComposition() {
        guard let document = store.document else { return }
        let state = SignaturePlacementState(document: document)
        visualState = state
        refreshVisualCardContent()
        if store.includeVisibleSignature {
            state.setEnabled(true)
            bridgePlacement = state.placement
        }
    }

    private func enableVisualCompositionIfReady() {
        guard store.includeVisibleSignature,
              let visualState,
              bridgePlacement == nil else { return }
        visualState.setEnabled(true)
        bridgePlacement = visualState.placement
    }

    private func syncPlacementToStore(_ placement: VisibleSignaturePlacement?) {
        guard let placement else { return }
        visualState?.update(placement: placement)
        store.visualPlacement = placement
        store.signaturePage = min(max(placement.pageIndex, 0), max(store.analysis.totalPages - 1, 0))
        if let page = store.document?.page(at: store.signaturePage) {
            let cropBox = page.bounds(for: .cropBox)
            guard cropBox.width > 0, cropBox.height > 0 else { return }
            let rect = placement.pageRect
            store.signatureRect = NormalizedRect(
                x: Double(rect.minX / cropBox.width),
                y: Double(1 - (rect.maxY / cropBox.height)),
                width: Double(rect.width / cropBox.width),
                height: Double(rect.height / cropBox.height)
            )
        }
        if let state = visualState, let asset = state.selectedAsset {
            store.visualArtworkOverride = try? Data(contentsOf: state.artworkURL(for: asset))
        } else {
            store.visualArtworkOverride = nil
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                if let document = store.document {
                    if usesBridgeComposition {
                        PDFPreviewView(
                            document: document,
                            placement: Binding(
                                get: { store.includeVisibleSignature ? bridgePlacement : nil },
                                set: { bridgePlacement = $0 }
                            ),
                            cardPreview: visualState?.cardPreview
                        )
                    } else {
                        PDFKitPreview(document: document, stampState: nil)
                    }
                }
            }
            .glassCard(cornerRadius: 12, padding: 6)

            HStack(spacing: 12) {
                StatChip(title: "Strany", value: "\(store.analysis.totalPages)", symbol: "doc.on.doc", tint: .blue)
                if store.analysis.nonEmptyPages != store.analysis.totalPages {
                    StatChip(title: "Neprázdne", value: "\(store.analysis.nonEmptyPages)", symbol: "doc.text", tint: .teal)
                }

                Spacer()

                if let url = store.sourceURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
    }

    private var tokenStatusLine: some View {
        Group {
            if store.identities.isEmpty {
                Label("Karta nie je detegovaná: vložte eID alebo advokátsky preukaz.", systemImage: "creditcard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("Karta je pripojená a aktívna.", systemImage: "creditcard.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    private var existingSignaturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignatureTreeView(
                state: store.existingSignatureState,
                emptyText: "Dokument zatiaľ neobsahuje elektronický podpis. Podpísanie pridá prvý KEP podpis.",
                isBusy: store.isSigning,
                onRevalidate: { Task { await store.revalidateExistingSignatures() } })
            if !store.existingSignatures.isEmpty {
                Text("Pridá sa ďalší podpis k existujúcim podpisom v dokumente.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signatureSectionTitle: String {
        let total = SignatureTreeSummary(tree: store.existingSignatureState.tree).total
        return "Podpisy v dokumente" + (total == 0 ? "" : " · \(total)")
    }

    /// How the chosen format treats the signatures the document already has.
    private var existingSignatureFormatNote: String? {
        switch (store.sourceSignatureKind, store.outputFormat) {
        case (.asicContainer, _):
            "Podpis sa pridá do tohto kontajnera ASiC-E popri existujúcich podpisoch."
        case (.signedPDF, .embeddedPAdES):
            "Podpis sa pridá do PDF popri existujúcich podpisoch."
        case (.signedPDF, .attachedASIC):
            "Podpísané PDF sa vloží do nového kontajnera bez zmeny; jeho podpisy zostanú v PDF."
        case (.unsignedPDF, _):
            nil
        }
    }

    private var selectedOutputFormatPresentation: SigningOutputFormatPresentation {
        switch store.outputFormat {
        case .embeddedPAdES:
            .embeddedPAdES
        case .attachedASIC:
            .attachedASIC
        }
    }
    @MainActor
    private func resolveCertificateForPreview(
        force: Bool = false,
        relinquishApplicationFocus: Bool = true
    ) async {
        if relinquishApplicationFocus {
            signingPINFocused = false
            NSApp.deactivate()
        }
        await store.resolveCertificateForPreview(force: force)
        if relinquishApplicationFocus {
            NSApp.activate(ignoringOtherApps: true)
        }
    }


    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section 1: Podpisový certifikát & PIN
            VStack(alignment: .leading, spacing: 12) {
                Label("Podpisový certifikát", systemImage: "creditcard.fill")
                    .font(.headline)

                tokenStatusLine

                if store.identities.isEmpty {
                    Text("Pripojte čítačku eID alebo advokátsky preukaz SAK.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if store.signingProvider is DemoSigningProvider {
                        Label("DEMO režim: podpis nie je právne záväzný.", systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    ForEach(store.identities) { identity in
                        IdentityRow(
                            identity: identity,
                            isSelected: store.selectedIdentityID == identity.id,
                            onSelect: { store.selectedIdentityID = identity.id }
                        )
                    }

                    if let selected = store.identities.first(where: { $0.id == store.selectedIdentityID }),
                       selected.requiresPIN {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                SecureField("Zadajte PIN karty", text: $store.signingPIN)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($signingPINFocused)
                                    .onSubmit {
                                        Task {
                                            await resolveCertificateForPreview(
                                                force: true,
                                                relinquishApplicationFocus: true)
                                        }
                                    }

                                Button {
                                    Task {
                                        await resolveCertificateForPreview(
                                            force: true,
                                            relinquishApplicationFocus: true)
                                    }
                                } label: {
                                    Label("Načítať certifikáty", systemImage: "arrow.clockwise")
                                }
                                .controlSize(.small)
                                .disabled(store.signingPIN.isEmpty || store.isResolvingCertificate)
                                .help("Načítať certifikáty z vloženej karty")
                            }

                            Text("PIN sa používa iba na túto operáciu a neukladá sa.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            if store.isResolvingCertificate {
                                ProgressView("Načítavam certifikát pre náhľad…")
                                    .font(.caption2)
                            }
                            if let error = store.certificateLoadError {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .inspectorCard(cornerRadius: 12, padding: 12)

            // Section 2: Parametre výstupu & TSA
            VStack(alignment: .leading, spacing: 12) {
                Label("Parametre podpisu", systemImage: "slider.horizontal.3")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Formát výstupu")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(SigningOutputFormatPresentation.allCases) { presentation in
                            let isSelected = store.outputFormat == presentation.format
                            Button {
                                store.outputFormat = presentation.format
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(presentation.label)
                                        .font(.callout.weight(isSelected ? .semibold : .medium))
                                    Text(presentation.format == .embeddedPAdES
                                         ? "Podpis priamo v PDF"
                                         : "Kontajner s XAdES")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            isSelected
                                                ? Color.accentColor.opacity(0.55)
                                                : Color.primary.opacity(0.12),
                                            lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(store.sourceSignatureKind == .asicContainer
                                      && presentation.format == .embeddedPAdES)
                            .accessibilityLabel("Formát výstupu \(presentation.label)")
                            .accessibilityValue(isSelected ? "Vybraný" : "Nevybraný")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }

                    Text(selectedOutputFormatPresentation.explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let note = existingSignatureFormatNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.5)

                Toggle(isOn: $store.qualifiedTimestampSwitchIsOn) {
                    Label("Kvalifikovaná časová pečiatka (QTS)", systemImage: "clock.badge.checkmark")
                        .font(.callout)
                }
                .disabled(store.qualifiedTimestampIsLocked)

                if let note = store.qualifiedTimestampNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.qualifiedTimestampSwitchIsOn || store.signingProvider.alwaysAddsQualifiedTimestamp {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $store.selectedTSAURL) {
                            ForEach(store.settings.availableTSAServers) { server in
                                Text(server.name).tag(server.url)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        if let warning = store.timestampAuthorityWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let note = store.selectedAuthorityQualificationNote {
                            Label(note.text, systemImage: note.isWarning ? "exclamationmark.triangle.fill" : "checkmark.seal")
                                .font(.caption2)
                                .foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 8)
                }

                Divider().opacity(0.5)

                Toggle(isOn: $store.convertToPDFA) {
                    Label("Konvertovať do PDF/A pred podpisom", systemImage: "doc.badge.arrow.up")
                        .font(.callout)
                }
                .disabled(store.preservesSourceBytes)
                if store.preservesSourceBytes {
                    Text("Podpísaný dokument sa do PDF/A nekonvertuje: konverzia by zrušila jeho existujúce podpisy.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .inspectorCard(cornerRadius: 12, padding: 12)

            // Section 3: Vizuálna pečiatka podpisu
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Vizuálna pečiatka v PDF", systemImage: "seal")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $store.includeVisibleSignature)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(store.bakedVisualStampIsBlocked)
                }

                if store.bakedVisualStampIsBlocked {
                    Text(store.sourceSignatureKind == .asicContainer
                         ? "Do dokumentu v kontajneri ASiC-E sa pečiatka nevkladá, podpis sa pridá do kontajnera."
                         : "Pečiatka by v kontajneri ASiC-E prepísala PDF a zrušila jeho podpisy. Pre viditeľnú pečiatku zvoľte PAdES.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if store.includeVisibleSignature, !store.bakedVisualStampIsBlocked, let visualState {
                    Divider().opacity(0.5)
                    VisibleAppearanceInspector(state: visualState)
                }
            }
            .inspectorCard(cornerRadius: 12, padding: 12)

            // Section 4: Existujúce podpisy
            VStack(alignment: .leading, spacing: 8) {
                Label(signatureSectionTitle, systemImage: "signature")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                existingSignaturesSection
            }
            .inspectorCard(cornerRadius: 12, padding: 12)

            if let error = store.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var signButton: some View {
        AsyncActionButton(
            phase: AsyncActionPhase.derive(
                isSigning: store.isSigning, lastError: store.lastError, canSign: store.canSign),
            title: store.existingSignatures.isEmpty ? "Podpísať KEP" : "Pridať podpis",
            loadingText: store.statusText.isEmpty ? nil : store.statusText
        ) {
            Task { await store.sign() }
        }
        // Eligibility stays independent of the visual error phase: an error remains
        // visible even while the button is disabled.
        .disabled(!store.canSign)
    }

    @ViewBuilder
    private var mobileSignButton: some View {
        if store.isMobileSigningAvailable {
            Menu {
                Button("Autogram v mobile") {
                    Task { await store.sign(viaMobile: true, mobileMethod: .autogramMobile) }
                }
                Button("eIdentita (štátna aplikácia)") {
                    Task { await store.sign(viaMobile: true, mobileMethod: .eidentita) }
                }
            } label: {
                HStack(spacing: 8) {
                    if store.isSigning, store.isSigningViaMobile {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    }
                    Text("Podpísať mobilom")
                        .font(.body.weight(.semibold))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!store.canSignViaMobile)
            .help(store.sourceSignatureKind == .asicContainer
                  ? "Do kontajnera ASiC-E sa podpis mobilom pridať nedá."
                  : store.preservesSourceBytes && store.includeVisibleSignature
                  ? "Mobilom sa do podpísaného PDF pečiatka vložiť nedá. Vypnite pečiatku alebo podpíšte kartou."
                  : "Podpis občianskym preukazom s NFC cez iPhone: Autogram v mobile alebo štátna aplikácia eIdentita")
        }
    }
}

struct SignatureInfoRow: View {
    let info: DocumentSignatureInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.signerDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let format = info.format {
                        Text(format).font(.caption2.monospaced())
                    }
                    if let qualification = SignatureTreePresentation.qualificationLabel(info.certificateQualification) {
                        Text(qualification).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if info.hasQualifiedTimestamp {
                        Text("QTS").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    } else if info.hasTimestamp {
                        Text("Časová pečiatka").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(stateLabel).font(.caption2).foregroundStyle(tint)
                }
                if let signingTime = info.signingTime {
                    Text(signingTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !info.coveredDocuments.isEmpty {
                    Text("Pokrýva: " + info.coveredDocuments.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let detail = info.detail, !detail.isEmpty {
                    DisclosureGroup("Detail validácie") {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String { SignatureTreePresentation.icon(info.state) }

    private var tint: Color { SignatureTreePresentation.tint(info.state) }

    private var stateLabel: String {
        switch info.state {
        case .valid: "Platný"
        case .invalid: "Neplatný"
        // DSS INDETERMINATE: the check could not conclude, typically because fresh
        // revocation data for a signature made moments ago is not published yet.
        case .indeterminate: "Neurčitý"
        case .unknown: "Neoverené"
        }
    }
}

// MARK: - Step 3: Done View
struct SigningDoneView: View {
    let store: SigningSessionStore
    @State private var isInspectorPresented = true

    var body: some View {
        VStack(spacing: 0) {
            previewColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            StickyActionBar {
                Button {
                    store.reset()
                    store.step = .intake
                } label: {
                    Label("Nový podpis", systemImage: "plus")
                }
                .controlSize(.large)

                if let url = store.signedOutputURL {
                    Button {
                        Task { await store.addFurtherSignature(to: url) }
                    } label: {
                        Label("Pridať ďalší podpis", systemImage: "signature")
                    }
                    .controlSize(.large)
                    .disabled(!store.canAddFurtherSignature)
                    .help("Otvorí podpísaný dokument a pridá k nemu ďalší podpis")
                }

                Spacer()

                if let url = store.signedOutputURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Ukázať vo Finderi", systemImage: "folder")
                    }
                    .controlSize(.large)

                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Otvoriť", systemImage: "doc.richtext")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            ScrollView {
                resultContent
                    .padding(16)
            }
            .safeAreaPadding(.top)
            .inspectorColumnWidth(min: 300, ideal: MacOS27Layout.inspectorIdealWidth, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Podrobnosti podpisu", systemImage: "sidebar.trailing")
                }
                .help("Zobraziť alebo skryť podrobnosti podpisu")
            }
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 10) {
            ZStack {
                if let document = store.signedPreviewDocument {
                    PDFKitPreview(document: document)
                } else {
                    ContentUnavailableView(
                        "Náhľad podpísaného súboru",
                        systemImage: "doc.richtext",
                        description: Text("Súbor bol úspešne uložený.")
                    )
                }
            }
            .glassCard(cornerRadius: 12, padding: 6)

            if let url = store.signedOutputURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(Color.green.gradient)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Podpis je úspešne uložený")
                        .font(.headline)
                    if let result = store.result {
                        Text(result.isLegallyBinding ? "Kvalifikovaný elektronický podpis (KEP)" : "DEMO podpis")
                            .font(.caption)
                            .foregroundStyle(result.isLegallyBinding ? .green : .orange)
                    }
                }
            }

            GroupBox("Stav súboru a PDF/A") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(store.pdfaPrepared ? "Pred podpisom: PDF/A pripravené" : "Pred podpisom: bez konverzie",
                          systemImage: store.pdfaPrepared ? "checkmark.circle.fill" : "minus.circle")
                        .font(.caption)
                        .foregroundStyle(store.pdfaPrepared ? .green : .secondary)

                    Label(store.pdfaAfterSign ? "Po podpise: PDF/A zachované"
                          : store.signedOutputURL?.pathExtension.lowercased() == "asice"
                          ? "Po podpise: kontajner ASiC-E (XAdES)" : "Po podpise: PDF s podpisom PAdES",
                          systemImage: store.pdfaAfterSign ? "checkmark.circle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(store.pdfaAfterSign ? .green : .secondary)
                }
                .padding(4)
            }

            GroupBox("Overenie podpisov v súbore") {
                SignatureTreeView(
                    state: store.resultSignatureState,
                    emptyText: "Podpísaný súbor je pripravený.",
                    isBusy: store.isSigning,
                    onRevalidate: { Task { await store.revalidateResultSignatures() } })
                    .padding(4)
            }
            if let identity = store.identities.first(where: { $0.id == store.selectedIdentityID }) {
                GroupBox("Použitý certifikát") {
                    VStack(alignment: .leading, spacing: 5) {
                        detailRow("Názov", identity.label)
                        let issuer = store.result?.issuerName(fallback: identity)
                            ?? (identity.describesCertificate ? identity.issuerSummary : "")
                        if !issuer.isEmpty {
                            detailRow("Vydal", issuer)
                        }
                        detailRow("Kvalifikácia", identity.isQualified ? "Kvalifikovaný" : "Nekvalifikovaný")
                        if let validUntil = identity.validUntil {
                            detailRow("Platný do", validUntil.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .padding(4)
                }
            }

            if store.lastSignatureTimestamped {
                GroupBox("Časová pečiatka") {
                    VStack(alignment: .leading, spacing: 5) {
                        let signature = store.resultSignatures.first
                        ForEach(SigningTimestampPresentation.authorityRows(
                            mobileMethod: store.lastMobileSigningMethod,
                            settingsAuthorityName: store.settings.activeTSA.name,
                            settingsAuthorityURL: store.settings.activeTSA.url,
                            validatedAuthority: store.resultSignatureState.phase == .validated
                                ? signature?.timestampAuthority : nil), id: \.label) { row in
                            detailRow(row.label, row.value)
                        }
                        if let verdict = store.lastTimestampQualification {
                            Label(verdict.slovakDescription,
                                  systemImage: verdict == .qualified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(verdict == .qualified ? Color.green : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let signature = store.resultSignatures.first,
                           let signingTime = signature.signingTime {
                            detailRow("Čas podpisu", signingTime.formatted(date: .abbreviated, time: .standard))
                        }
                        if let timestampTime = store.resultSignatures.first?.timestampTime {
                            detailRow("Čas pečiatky", timestampTime.formatted(date: .abbreviated, time: .standard))
                        }
                        if let detail = store.resultSignatures.first?.detail {
                            detailRow("Validácia", detail)
                        }
                    }
                    .padding(4)
                }
            }
        }
    }
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

}

// MARK: - Batch Review, Progress & Summary
struct SigningBatchView: View {
    @Bindable var store: SigningSessionStore

    private var completedCount: Int {
        store.batchItems.filter { $0.state == .signed }.count
    }

    private var failedCount: Int {
        store.batchItems.filter { $0.state == .failed }.count
    }

    private var skippedCount: Int {
        store.batchItems.filter { $0.state == .skipped }.count
    }

    private var cancelledCount: Int {
        store.batchItems.filter { $0.state == .cancelled }.count
    }

    private var pendingCount: Int {
        store.batchItems.filter { $0.state == .pending }.count
    }

    private var selectedIdentity: SigningIdentityInfo? {
        store.identities.first { $0.id == store.selectedIdentityID }
    }

    private var requiresPIN: Bool {
        selectedIdentity?.requiresPIN == true
            || (!store.signingProviderIsDemo && store.batchSettingsSnapshot?.includeVisibleSignature == true)
            || (!store.signingProviderIsDemo && store.identities.isEmpty)
    }

    private var pinMissing: Bool {
        requiresPIN && store.signingPIN.isEmpty
    }

    private var hasBlockingItems: Bool {
        store.batchItems.contains { $0.state == .failed }
    }

    private var canStart: Bool {
        store.batchCanStart && !pinMissing
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    batchErrorBanner
                    if store.batchPhase == .signing {
                        progressCard
                    }
                    if store.batchPhase == .completed || store.batchPhase == .cancelled {
                        summaryCard
                    }
                    settingsCard
                    itemsCard
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }

            StickyActionBar {
                actionBar
            }
        }
        .alert(item: $store.batchErrorDecisionRequest) { request in
            Alert(
                title: Text("Podpis dokumentu zlyhal"),
                message: Text("\(request.displayName)\n\(request.errorMessage)"),
                primaryButton: .default(Text("Pokračovať na ďalšie")) {
                    store.decideBatchFailure(.continueBatch)
                },
                secondaryButton: .destructive(Text("Zastaviť dávku")) {
                    store.decideBatchFailure(.stopBatch)
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerIcon)
                .font(.title2)
                .foregroundStyle(headerTint)
                .frame(width: 38, height: 38)
                .background(headerTint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.title2.weight(.bold))
                Text(headerDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dávka podpisov")
        .accessibilityValue("\(headerTitle). \(headerDetail)")
    }

    @ViewBuilder
    private var batchErrorBanner: some View {
        if let error = store.lastError, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Chyba dávky")
                .accessibilityValue(error)
        }
    }

    /// Options can change until the batch starts; afterwards they show what was used.
    private var settingsEditable: Bool {
        store.batchPhase == .ready || store.batchPhase == .idle
    }

    private var settingsBusy: Bool {
        store.batchPhase == .preflighting || store.batchPhase == .signing
    }

    /// A binding that takes the change into a ready batch at once.
    private func batchOption<Value>(
        _ keyPath: ReferenceWritableKeyPath<SigningSessionStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { newValue in
                store[keyPath: keyPath] = newValue
                store.refreshReadyBatchOptions()
            })
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nastavenie dávky", systemImage: "slider.horizontal.3")
                .font(.headline)

            Form {
                certificateRow
                if requiresPIN {
                    pinRow
                }

                Picker("Formát podpisu", selection: batchOption(\.outputFormat)) {
                    Text("PAdES").tag(SigningOutputFormat.embeddedPAdES)
                    Text("ASiC-E (XAdES)").tag(SigningOutputFormat.attachedASIC)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!settingsEditable)

                if store.outputFormat == .attachedASIC {
                    Picker("Balenie", selection: batchOption(\.batchASiCPackaging)) {
                        Text("Samostatný kontajner pre každý dokument")
                            .tag(AppSettings.BatchASiCPackaging.perDocument)
                        Text("Jeden spoločný kontajner")
                            .tag(AppSettings.BatchASiCPackaging.combined)
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(!settingsEditable)

                    if store.batchASiCPackaging == .combined {
                        LabeledContent("Názov kontajnera") {
                            HStack(spacing: 4) {
                                TextField(
                                    "Názov kontajnera",
                                    text: batchOption(\.batchContainerName),
                                    prompt: Text(store.batchContainerDefaultName))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 280)
                                Text(".asice")
                                    .foregroundStyle(.secondary)
                            }
                            .disabled(!settingsEditable)
                        }
                    }
                }

                LabeledContent("Výstup") {
                    Text(outputSummary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("Časová pečiatka") {
                    VStack(alignment: .leading, spacing: 6) {
                        // A batch signs with the card only, which with the engine always timestamps.
                        let timestampLocked = store.signingProvider.alwaysAddsQualifiedTimestamp
                        Toggle(
                            "Pridať kvalifikovanú časovú pečiatku (QTS)",
                            isOn: timestampLocked ? .constant(true) : batchOption(\.includeQualifiedTimestamp))
                            .toggleStyle(.checkbox)
                            .disabled(timestampLocked)
                        if timestampLocked {
                            Text(SigningSessionStore.cardAlwaysTimestampsNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if store.includeQualifiedTimestamp || timestampLocked {
                            Picker("Služba TSA", selection: batchOption(\.selectedTSAURL)) {
                                ForEach(store.settings.availableTSAServers) { server in
                                    Text(server.name).tag(server.url)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .accessibilityLabel("Služba časovej pečiatky")
                            if let warning = store.timestampAuthorityWarning {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .disabled(!settingsEditable)
                }

                LabeledContent("PDF/A") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "Konvertovať do PDF/A pred podpisom",
                            isOn: batchOption(\.convertToPDFA))
                            .toggleStyle(.checkbox)
                        if store.convertToPDFA {
                            Text("Už podpísané PDF sa nekonvertujú, aby ostali ich podpisy platné.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(!settingsEditable)
                }

                LabeledContent("Vizuálna pečiatka") {
                    Text(visualStampSummary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.columns)

            if let optionsError = store.batchOptionsError {
                Label(optionsError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if store.batchSettingsSnapshot == nil, store.batchPhase == .preflighting {
                Text("Kontrolujem certifikát a dokumenty…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spoločné nastavenia dávky")
    }

    private var certificateRow: some View {
        LabeledContent("Podpisový certifikát") {
            HStack(spacing: 6) {
                Text(certificateSummary)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    Task { await refreshCertificate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Znova načítať certifikát z karty")
                .disabled(settingsBusy)
                .accessibilityLabel("Obnoviť podpisový certifikát")
            }
        }
    }

    private var pinRow: some View {
        LabeledContent("PIN") {
            VStack(alignment: .leading, spacing: 4) {
                SecureField("PIN karty", text: $store.signingPIN, prompt: Text("Zadajte PIN karty"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .disabled(settingsBusy)
                    .accessibilityLabel("PIN podpisovej karty")
                    .accessibilityValue(
                        store.signingPIN.isEmpty ? "PIN nie je zadaný" : "PIN je zadaný")
                Text("PIN sa používa iba počas tejto dávky a neukladá sa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var certificateSummary: String {
        store.batchSettingsSnapshot?.identityLabel
            ?? selectedIdentity?.label
            ?? "Overí sa pri kontrole dávky"
    }

    private var visualStampSummary: String {
        let enabled = store.batchSettingsSnapshot?.includeVisibleSignature ?? store.includeVisibleSignature
        return enabled
            ? "Zapnutá, na mieste zvolenom v náhľade dokumentu"
            : "Vypnutá (nastavuje sa v náhľade dokumentu)"
    }

    /// What the batch writes with the options as they are now.
    private var outputSummary: String {
        let count = store.batchItems.filter { $0.state != .failed }.count
        switch store.outputFormat {
        case .embeddedPAdES:
            return "Podpis priamo v PDF: \(Self.documentCount(count)), každý ako …_podpisane.pdf."
        case .attachedASIC:
            if store.batchASiCPackaging == .combined {
                let name = store.batchItems.first { $0.state != .failed }?.plannedOutputURL?.lastPathComponent
                    ?? "\(store.batchSettingsSnapshot?.containerStem ?? store.batchContainerDefaultName).asice"
                return "Jeden kontajner \(name) so všetkými dokumentmi (\(count))."
            }
            return "\(Self.containerCount(count)), každý dokument vo vlastnom …_podpisane.asice."
        }
    }

    private static func documentCount(_ count: Int) -> String {
        switch count {
        case 1: "1 dokument"
        case 2...4: "\(count) dokumenty"
        default: "\(count) dokumentov"
        }
    }

    private static func containerCount(_ count: Int) -> String {
        switch count {
        case 1: "1 kontajner"
        case 2...4: "\(count) kontajnery"
        default: "\(count) kontajnerov"
        }
    }

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Dokumenty v dávke", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Text("\(store.batchItems.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(store.batchItems) { item in
                batchItemRow(item)
            }
        }
        .glassCard(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dokumenty v dávke, \(store.batchItems.count) položiek")
    }

    private func batchItemRow(_ item: SigningSessionStore.BatchItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: itemIcon(item.state))
                    .foregroundStyle(itemTint(item.state))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(itemStateLabel(item.state))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(itemTint(item.state))
                        Text(inputAvailability(item.url))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let inspectionState = item.inputSignatureState {
                        Text("Podpisy vstupu: \(inputSignatureStateLabel(inspectionState))")
                            .font(.caption2)
                        .foregroundStyle(inspectionState == .valid ? Color.secondary : Color.red)
                    }
                    if let plannedOutputURL = item.plannedOutputURL {
                        Text(
                            item.outputURL == nil
                                ? "Plánovaný výstup: \(plannedOutputURL.lastPathComponent)"
                                : "Výstup: \(plannedOutputURL.lastPathComponent)"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                if let outputURL = item.outputURL, item.state == .signed {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Ukázať výstup vo Finderi")
                    .accessibilityLabel("Ukázať výstup dokumentu \(item.displayName) vo Finderi")
                    .accessibilityValue(outputURL.lastPathComponent)
                }
            }

            if let error = item.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 27)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dokument \(item.displayName)")
        .accessibilityValue(itemAccessibilityValue(item))
    }

    private var progressCard: some View {
        let total = max(store.batchItems.count, 1)
        let currentName = store.batchCurrentIndex.flatMap { index in
            store.batchItems.indices.contains(index) ? store.batchItems[index].displayName : nil
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Priebeh podpisovania", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(completedCount) z \(store.batchItems.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(completedCount), total: Double(total))
                .progressViewStyle(.linear)
                .tint(.accentColor)

            if let currentName {
                Label("Aktuálny dokument: \(currentName)", systemImage: "signature")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                progressMetric("Hotové", count: completedCount, tint: .green, symbol: "checkmark.circle.fill")
                progressMetric("Zlyhania", count: failedCount, tint: .red, symbol: "xmark.circle.fill")
            }
        }
        .glassCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Priebeh podpisovania")
        .accessibilityValue(
            "\(completedCount) z \(store.batchItems.count) hotových, \(failedCount) zlyhaní"
            + (currentName.map { ", podpisuje sa \($0)" } ?? "")
        )
    }

    private func progressMetric(_ title: String, count: Int, tint: Color, symbol: String) -> some View {
        Label("\(title): \(count)", systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                store.batchPhase == .completed ? "Dávka dokončená" : "Dávka zrušená",
                systemImage: store.batchPhase == .completed
                    ? "checkmark.seal.fill"
                    : "pause.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(store.batchPhase == .completed ? .green : .orange)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ],
                spacing: 8
            ) {
                summaryMetric("Úspešné", count: completedCount, tint: .green)
                summaryMetric("Neúspešné", count: failedCount, tint: .red)
                summaryMetric("Preskočené", count: skippedCount, tint: .orange)
                summaryMetric("Zrušené", count: cancelledCount, tint: .secondary)
            }
        }
        .glassCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Záverečné zhrnutie dávky")
        .accessibilityValue(
            "\(completedCount) úspešných, \(failedCount) neúspešných, "
            + "\(skippedCount) preskočených, \(cancelledCount) zrušených"
        )
    }

    private func summaryMetric(_ title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text("\(title): \(count)")
                .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(count)")
    }

    @ViewBuilder
    private var actionBar: some View {
        switch store.batchPhase {
        case .preflighting:
            ProgressView("Kontrolujem dokumenty a vstupné podpisy…")
                .font(.callout)
            Spacer()
            Button("Zrušiť kontrolu") {
                store.cancelBatch()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Zrušiť kontrolu dávky")
            .accessibilityValue("Kontrola preflightu prebieha")
        case .ready, .idle:
            Button {
                beginNewBatch()
            } label: {
                Label("Iná dávka", systemImage: "chevron.left")
            }
            .controlSize(.large)
            .accessibilityLabel("Vybrať inú dávku")

            if !store.batchItems.isEmpty {
                Button {
                    let ids = store.batchItems.map(\.id)
                    Task { await store.prepareBatch(ids: ids) }
                } label: {
                    Label("Znova skontrolovať", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .disabled(store.batchPhase == .preflighting || store.batchPhase == .signing)
                .accessibilityLabel("Znova skontrolovať dávku")
                .accessibilityValue("Spustiť preflight dokumentov a nastavení")
            }

            Spacer()

            if canStart {
                Button {
                    Task { await store.startBatch() }
                } label: {
                    Label("Spustiť dávku", systemImage: "signature.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Spustiť dávku podpisov")
                .accessibilityValue("\(pendingCount) dokumentov čaká na podpis")
            } else if store.batchPhase == .ready {
                Text(
                    pinMissing
                        ? "Zadajte PIN a znova skontrolujte dávku."
                        : store.batchOptionsError
                            ?? "Odstráňte blokujúce problémy pred spustením."
                )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Dávku nie je možné spustiť")
                    .accessibilityValue(
                        pinMissing
                            ? "Zadajte PIN a znova skontrolujte dávku"
                            : "Odstráňte blokujúce problémy"
                    )
            }
        case .signing:
            Text("Podpisujem dokumenty…")
                .font(.callout)
            Spacer()
            Button("Zrušiť dávku") {
                store.cancelBatch()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Zrušiť podpisovanie dávky")
            .accessibilityValue("Dávka je v priebehu")
        case .completed, .cancelled:
            Button {
                beginNewBatch()
            } label: {
                Label("Nová dávka", systemImage: "plus")
            }
            .controlSize(.large)
            .accessibilityLabel("Začať novú dávku")

            Spacer()

            if failedCount > 0 {
                Button {
                    Task { await store.retryFailedBatchItems() }
                } label: {
                    Label("Opakovať neúspešné", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .accessibilityLabel("Opakovať neúspešné dokumenty")
                .accessibilityValue("\(failedCount) dokumentov")
            }

            if store.batchItems.contains(where: { $0.outputURL != nil }) {
                Button {
                    revealOutputs()
                } label: {
                    Label("Ukázať výstupy", systemImage: "folder")
                }
                .controlSize(.large)
                .accessibilityLabel("Ukázať podpísané výstupy vo Finderi")
                .accessibilityValue("\(completedCount) súborov")
            }

            Button {
                exportLog()
            } label: {
                Label("Exportovať protokol…", systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            .accessibilityLabel("Exportovať protokol dávky")
            .accessibilityValue("Uložiť textový protokol do vybraného súboru")
        }
    }

    private var headerTitle: String {
        switch store.batchPhase {
        case .preflighting: "Kontrola dávky"
        case .ready: "Dávka pripravená na podpis"
        case .signing: "Podpisovanie dávky"
        case .completed: "Dávka dokončená"
        case .cancelled: "Dávka zrušená"
        case .idle: "Kontrola dávky"
        }
    }

    private var headerDetail: String {
        switch store.batchPhase {
        case .preflighting:
            "Overujem súbory, nastavenia a vstupné elektronické podpisy."
        case .ready:
            hasBlockingItems
                ? "Niektoré dokumenty obsahujú blokujúce problémy."
                : "\(pendingCount) dokumentov je pripravených na podpis."
        case .signing:
            "Dokumenty sa podpisujú postupne. Výstupy sa ukladajú bezpečne."
        case .completed:
            "Skontrolujte výsledky a prípadne zopakujte neúspešné dokumenty."
        case .cancelled:
            "Podpisovanie bolo zastavené; hotové výstupy zostali zachované."
        case .idle:
            "Preflight dávky sa nedokončil."
        }
    }

    private var headerIcon: String {
        switch store.batchPhase {
        case .preflighting: "checklist"
        case .ready: "signature"
        case .signing: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.seal.fill"
        case .cancelled: "pause.circle.fill"
        case .idle: "exclamationmark.triangle.fill"
        }
    }

    private var headerTint: Color {
        switch store.batchPhase {
        case .preflighting, .signing: .accentColor
        case .ready: .blue
        case .completed: .green
        case .cancelled: .orange
        case .idle: .red
        }
    }

    private func itemAccessibilityValue(_ item: SigningSessionStore.BatchItem) -> String {
        var value = "\(itemStateLabel(item.state)); \(inputAvailability(item.url))"
        if let inspectionState = item.inputSignatureState {
            value += "; vstupné podpisy \(inputSignatureStateLabel(inspectionState))"
        }
        if let detail = item.inputSignatureDetail, !detail.isEmpty {
            value += "; detail \(detail)"
        }
        if let error = item.errorMessage, !error.isEmpty {
            value += "; blokovanie: \(error)"
        }
        if let planned = item.plannedOutputURL, item.outputURL == nil {
            value += "; plánovaný výstup \(planned.lastPathComponent)"
        }
        if let output = item.outputURL {
            value += "; výstup \(output.lastPathComponent)"
        }
        return value
    }

    private func inputAvailability(_ url: URL) -> String {
        FileManager.default.isReadableFile(atPath: url.path) ? "Vstup dostupný" : "Vstup nedostupný"
    }

    private func inputSignatureStateLabel(
        _ state: InputSignatureInspectionResult.State
    ) -> String {
        switch state {
        case .valid: "Overené"
        case .invalid: "Neplatné alebo konfliktné"
        case .unknown: "Neznáme"
        case .unavailable: "Nedostupné"
        }
    }

    private func itemIcon(_ state: SigningSessionStore.BatchItemState) -> String {
        switch state {
        case .pending: "circle"
        case .signing: "arrow.triangle.2.circlepath"
        case .signed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .skipped: "forward.end"
        case .cancelled: "xmark.circle"
        }
    }

    private func itemTint(_ state: SigningSessionStore.BatchItemState) -> Color {
        switch state {
        case .pending: .secondary
        case .signing: .accentColor
        case .signed: .green
        case .failed: .red
        case .skipped: .orange
        case .cancelled: .secondary
        }
    }

    private func itemStateLabel(_ state: SigningSessionStore.BatchItemState) -> String {
        switch state {
        case .pending: "Čaká"
        case .signing: "Podpisuje sa"
        case .signed: "Podpísané"
        case .failed: "Zlyhalo"
        case .skipped: "Preskočené"
        case .cancelled: "Zrušené"
        }
    }

    private func outputFormatLabel(_ format: SigningOutputFormat) -> String {
        switch format {
        case .embeddedPAdES: "PAdES"
        case .attachedASIC: "ASiC-E / XAdES"
        }
    }

    private func beginNewBatch() {
        store.batchItems = []
        store.batchPhase = .idle
        store.batchErrorDecisionRequest = nil
        store.reset()
        store.step = .intake
    }

    private func refreshCertificate() async {
        await store.refreshIdentities()
        if !store.signingProviderIsDemo, !store.signingPIN.isEmpty {
            await store.resolveCertificateForPreview(force: true)
        }
    }

    private func revealOutputs() {
        let outputs = store.batchItems.compactMap(\.outputURL)
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "chevron7-davka.txt"
        panel.message = "Vyberte miesto na uloženie protokolu dávky."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try batchLog().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                store.lastError = "Protokol sa nepodarilo uložiť: \(error.localizedDescription)"
            }
        }
    }

    private func batchLog() -> String {
        var lines = [
            "Chevron7: protokol podpisovania dávky",
            "Stav: \(headerTitle)",
            "Úspešné: \(completedCount)",
            "Neúspešné: \(failedCount)",
            "Preskočené: \(skippedCount)",
            "Zrušené: \(cancelledCount)",
        ]
        if let snapshot = store.batchSettingsSnapshot {
            lines.append("Formát: \(outputFormatLabel(snapshot.outputFormat))")
            if snapshot.outputFormat == .attachedASIC {
                lines.append(snapshot.containerStem.map { "Balenie: jeden kontajner \($0).asice" }
                    ?? "Balenie: samostatný kontajner pre každý dokument")
            }
            lines.append("Časová pečiatka: \(snapshot.includeQualifiedTimestamp ? (snapshot.tsaURL ?? "zapnutá") : "vypnutá")")
            lines.append("PDF/A: \(snapshot.convertToPDFA ? "zapnuté" : "vypnuté")")
        }
        lines += ["", "Dokumenty:"]

        for item in store.batchItems {
            lines.append("- \(item.displayName): \(itemStateLabel(item.state))")
            lines.append("  Vstup: \(item.url.path)")
            if let outputURL = item.outputURL {
                lines.append("  Výstup: \(outputURL.path)")
            }
            if let error = item.errorMessage, !error.isEmpty {
                lines.append("  Chyba: \(error)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
