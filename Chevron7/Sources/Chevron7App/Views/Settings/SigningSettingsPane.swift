// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

struct SigningSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    @State private var newTSAURL = ""
    @State private var tsaTestStatus: String?
    @State private var tsaTestFailed = false
    @State private var isTestingTSA = false
    @State private var tsaToDelete: String?

    var body: some View {
        let settings = settingsStore.settings
        let customActive = SettingsAdvancedState.customTSAIsActive(settings)
        SettingsPaneForm(pane: .signing, pills: SettingsStatus.signing(settings)) {
            Section {
                Picker("Aktívna TSA", selection: $settingsStore.settings.selectedTSAURL) {
                    ForEach(settings.availableTSAServers) { server in
                        Text(server.name).tag(server.url)
                    }
                }
                LabeledContent("Adresa") {
                    Text(settings.activeTSA.url)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button {
                        testTSAConnection()
                    } label: {
                        if isTestingTSA {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Otestovať spojenie", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(isTestingTSA || settings.selectedTSAURL.isEmpty)
                    Spacer()
                    if let tsaTestStatus {
                        if tsaTestFailed {
                            InlineError(message: tsaTestStatus)
                        } else {
                            Label(tsaTestStatus, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            } header: {
                Label("Časová pečiatka", systemImage: "clock.badge.checkmark")
            } footer: {
                if settings.activeTSAQualificationIsUnverified {
                    Label(TimestampAuthority.unverifiedQualificationWarning,
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Režim PDF/A", selection: $settingsStore.settings.pdfaMode) {
                    ForEach(PDFAConversionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Label("PDF/A", systemImage: "doc.badge.gearshape")
            } footer: {
                Text("Vektorová konverzia zachováva textovú vrstvu; rasterizovaná garancia (200 dpi) vyrovná problematické skeny. Obe spĺňajú PDF/A-2b.")
            }

            if showAdvanced || customActive {
                Section {
                    ForEach(settings.customTSAServers, id: \.self) { server in
                        HStack {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                            Text(server).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            if !showAdvanced, server == settings.selectedTSAURL { AdvancedBadge() }
                            Button(role: .destructive) {
                                tsaToDelete = server
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Odstrániť TSA server")
                        }
                    }
                    HStack {
                        TextField("Nový server", text: $newTSAURL, prompt: Text("https://vlastna-tsa.sk/tsp"))
                        Button("Pridať") { addTSA() }
                            .disabled(newTSAURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    AdvancedSectionHeader(title: "Vlastné TSA servery")
                }
            }
        }
        .confirmationDialog("Naozaj chcete odstrániť tento TSA server?",
                            isPresented: Binding(get: { tsaToDelete != nil },
                                                 set: { if !$0 { tsaToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Odstrániť TSA server", role: .destructive) { deleteTSA() }
            Button("Zrušiť", role: .cancel) { tsaToDelete = nil }
        } message: {
            Text("Server bude odstránený zo zoznamu vlastných TSA služieb.")
        }
    }

    private func addTSA() {
        let trimmed = newTSAURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settingsStore.settings.customTSAServers.contains(trimmed) else { return }
        settingsStore.settings.customTSAServers.append(trimmed)
        newTSAURL = ""
    }

    private func deleteTSA() {
        guard let server = tsaToDelete else { return }
        settingsStore.settings.customTSAServers.removeAll { $0 == server }
        if settingsStore.settings.selectedTSAURL == server {
            settingsStore.settings.selectedTSAURL = TimestampAuthority.legacyDefaultURL
        }
        tsaToDelete = nil
    }

    private func testTSAConnection() {
        isTestingTSA = true
        tsaTestStatus = nil
        let urlString = settingsStore.settings.selectedTSAURL
        Task {
            defer { isTestingTSA = false }
            guard let url = URL(string: urlString), url.scheme != nil else {
                tsaTestFailed = true
                tsaTestStatus = "Neplatná adresa TSA."
                return
            }
            do {
                let reply = try await RFC3161TimestampClient()
                    .requestToken(for: Data("chevron7-tsa-connectivity-test".utf8), tsaURL: url)
                tsaTestFailed = false
                if let time = reply.genTime {
                    tsaTestStatus = "Pečiatka prijatá (\(AttestationClauseGenerator.isoFormatter.string(from: time)))"
                } else {
                    tsaTestStatus = "Token prijatý (\(reply.token.count) B)."
                }
            } catch {
                tsaTestFailed = true
                tsaTestStatus = error.localizedDescription
            }
        }
    }
}
