// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Panel vizuálneho podpisu s výberom grafickej pečiatky a nastavením strany.
public struct VisibleAppearanceInspector: View {
    @Bindable var state: SignaturePlacementState
    @State private var artworkError: String?
    @State private var showDeleteConfirmation = false
    public init(state: SignaturePlacementState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.assets.isEmpty {
                VStack(spacing: 8) {
                    Text("Pre vizuálny podpis nahrajte obrázok podpisu alebo pečiatku.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        chooseArtwork()
                    } label: {
                        Label("Nahrať podpis (PNG / JPEG / PDF)", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Zvolená pečiatka podpisu")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(state.assets) { asset in
                                Button {
                                    state.select(asset)
                                } label: {
                                    artworkThumbnail(for: asset)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Grafika podpisu \(asset.id.uuidString)")
                                .accessibilityValue(state.selectedAsset?.id == asset.id ? "Vybraná" : "Nevybraná")
                                .padding(3)
                                .background(
                                    state.selectedAsset?.id == asset.id
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            state.selectedAsset?.id == asset.id
                                                ? Color.accentColor
                                                : Color.primary.opacity(0.1),
                                            lineWidth: state.selectedAsset?.id == asset.id ? 2 : 1
                                        )
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if state.selectedAsset != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Vzhľad na strane")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Picker("Vzhľad na strane", selection: Binding(
                                get: { state.layout },
                                set: { state.setLayout($0) }
                            )) {
                                Text("Podrobný").tag(VisibleSignatureLayout.detailed)
                                Text("Kompaktný").tag(VisibleSignatureLayout.compact)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.small)
                            .help("Kompaktný nechá na strane len podpis, meno a čas. Podrobný pridá certifikát a stav.")
                        }
                    }


                    HStack(spacing: 8) {
                        Button {
                            chooseArtwork()
                        } label: {
                            Label("Pridať ďalší", systemImage: "plus")
                        }
                        .controlSize(.small)

                        if state.selectedAsset != nil {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Zmazať", systemImage: "trash")
                            }
                            .controlSize(.small)
                        }

                        Spacer()

                        if state.placement != nil {
                            Button {
                                state.resetRotation()
                            } label: {
                                Label("Obnoviť pôvodnú pozíciu", systemImage: "arrow.counterclockwise")
                            }
                            .controlSize(.small)
                        }
                    }
                    if let artworkError {
                        Text(artworkError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }

            if state.pageCount > 1 {
                HStack {
                    Text("Umiestnenie na strane:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    pageSelector
                }
            }

            Text("Pozíciu, veľkosť a rotáciu pečiatky upravíte priamo na plátne dokumentu.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
        .confirmationDialog("Naozaj chcete zmazať túto grafiku?",
                           isPresented: $showDeleteConfirmation,
                           titleVisibility: .visible) {
            Button("Zmazať grafiku", role: .destructive) {
                deleteSelectedArtwork()
            }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Grafika sa odstráni z lokálnej knižnice podpisov.")
        }
    }

    private var pageSelector: some View {
        Picker("Strana podpisu", selection: Binding(
            get: { state.placement?.pageIndex ?? 0 },
            set: { state.selectPage($0) }
        )) {
            ForEach(state.pageIndices, id: \.self) { pageIndex in
                Text("Strana \(pageIndex + 1)").tag(pageIndex)
            }
        }
        .disabled(state.placement == nil || state.pageCount == 0)
        .pickerStyle(.menu)
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .pdf]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Vyberte obrázok alebo vektorovú pečiatku podpisu."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try state.importArtwork(from: url,
                                        pdfPageIndex: selectedPDFPageIndex(for: url))
            } catch {
                artworkError = "Nahratie grafiky sa nepodarilo: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func artworkThumbnail(for asset: SignatureAsset) -> some View {
        if let image = NSImage(contentsOf: state.artworkURL(for: asset)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 48)
                .padding(4)
        } else {
            Image(systemName: "photo")
                .frame(width: 80, height: 48)
                .padding(4)
        }
    }

    private func deleteSelectedArtwork() {
        guard let asset = state.selectedAsset else { return }
        do {
            try state.delete(asset)
            artworkError = nil
        } catch {
            artworkError = "Zmazanie grafiky sa nepodarilo: \(error.localizedDescription)"
        }
    }

    private func selectedPDFPageIndex(for url: URL) -> Int {
        guard url.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: url),
              document.pageCount > 1 else {
            return 0
        }
        let alert = NSAlert()
        alert.messageText = "Výber strany PDF pečiatky"
        alert.informativeText = "Zadajte číslo strany z PDF, ktorú chcete použiť."
        let field = NSTextField(string: "1")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let page = Int(field.stringValue),
              document.page(at: page - 1) != nil else {
            return 0
        }
        return page - 1
    }
}
