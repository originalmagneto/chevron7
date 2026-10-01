// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import Chevron7Kit
import AppKit
import FoundationModels

enum AIPromptPreset: String, CaseIterable, Identifiable {
    case legalDocuments = "Právne dokumenty"
    case conservativeReview = "Konzervatívna kontrola"
    case signaturesAndInitials = "Podpisy a parafy"
    case stampsAndEmbossedElements = "Pečiatky a reliéfne prvky"
    case customPrompt = "Vlastný prompt"

    var id: String { rawValue }

    var promptText: String? {
        switch self {
        case .legalDocuments:
            return LLMVisionParser.systemPrompt
        case .conservativeReview:
            return LLMVisionParser.systemPrompt
                + "\nBuď pri klasifikácii mimoriadne konzervatívny a prvok vynechaj pri akejkoľvek neistote."
        case .signaturesAndInitials:
            return LLMVisionParser.systemPrompt
                + "\nZameraj sa najmä na každý fyzicky viditeľný podpis alebo parafu."
        case .stampsAndEmbossedElements:
            return LLMVisionParser.systemPrompt
                + "\nZameraj sa najmä na každý fyzicky viditeľný výskyt pečiatky alebo reliéfneho prvku."
        case .customPrompt:
            return nil
        }
    }
}

struct SettingsView: View {
    @Bindable var settingsStore: AppSettingsStore
    var waitForLearningWrites: @MainActor () async -> Void = {}
    @State private var newTSAURL = ""
    @State private var tsaTestStatus: String?
    @State private var isTestingTSA = false
    @State private var tsaToDelete: String?
    @State private var showTSADeleteConfirmation = false
    @State private var profileToDelete: UUID?
    @State private var showProfileDeleteConfirmation = false
    @State private var ezzkLoginField = ""
    @State private var ezzkPasswordField = ""
    @State private var ezzkLookupNumber = ""
    @State private var ezzkLookupResult: EZZKRecordLookup?
    @State private var ezzkLookupError: String?
    @State private var ezzkLookupInProgress = false
    @State private var ezzkTestNumbers: [String] = []
    @State private var ezzkNumbersError: String?
    @State private var ezzkNumbersInProgress = false
    @State private var showEZZKNumbersConfirmation = false
    @State private var finderQuickActionStatus: String?

    @State private var selectedPromptPreset: AIPromptPreset = .legalDocuments
    var body: some View {
        TabView {
            Tab("AI Vision", systemImage: "brain.head.profile") {
                settingsTabContent(aiTab)
            }
            Tab("Konverzia PDF/A", systemImage: "doc.badge.gearshape") {
                settingsTabContent(conversionTab)
            }
            Tab("EZZK", systemImage: "number.square") {
                settingsTabContent(ezzkTab)
            }
            Tab("Finder Quick Action", systemImage: "finder") {
                settingsTabContent(finderQuickActionTab)
            }
            Tab("Profily advokáta", systemImage: "person.crop.circle.badge.checkmark") {
                settingsTabContent(profilesTab)
            }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .confirmationDialog("Naozaj chcete odstrániť tento TSA server?",
                           isPresented: $showTSADeleteConfirmation,
                           titleVisibility: .visible) {
            Button("Odstrániť TSA server", role: .destructive) {
                if let server = tsaToDelete {
                    settingsStore.settings.customTSAServers.removeAll { $0 == server }
                    if settingsStore.settings.selectedTSAURL == server {
                        settingsStore.settings.selectedTSAURL = TimestampAuthority.legacyDefaultURL
                    }
                }
                tsaToDelete = nil
            }
            Button("Zrušiť", role: .cancel) { tsaToDelete = nil }
        } message: {
            Text("Server bude odstránený zo zoznamu vlastných TSA služieb.")
        }
        .confirmationDialog("Naozaj chcete odstrániť tento profil?",
                           isPresented: $showProfileDeleteConfirmation,
                           titleVisibility: .visible) {
            Button("Odstrániť profil", role: .destructive) {
                if let id = profileToDelete {
                    settingsStore.settings.profiles.removeAll { $0.id == id }
                    if settingsStore.settings.activeProfileID == id {
                        settingsStore.settings.activeProfileID = settingsStore.settings.profiles.first?.id
                    }
                }
                profileToDelete = nil
            }
            Button("Zrušiť", role: .cancel) { profileToDelete = nil }
        } message: {
            Text("Profil a jeho údaje budú odstránené z tejto aplikácie.")
        }
        .confirmationDialog(
            "Vyžiadať evidenčné čísla z testovacieho EZZK?",
            isPresented: $showEZZKNumbersConfirmation,
            titleVisibility: .visible
        ) {
            Button("Vyžiadať čísla") {
                Task { await requestEZZKTestNumbers() }
            }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Testovacie EZZK vráti nespotrebované čísla osoby a podľa potreby pridelí nové.")
        }
    }

    /// The scroll container is what keeps a tab taller than the window reachable;
    /// without it the content was simply clipped at the bottom edge.
    private func settingsTabContent<Content: View>(_ content: Content) -> some View {
        ScrollView {
            content
                .frame(maxWidth: 960, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 18)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }


    // MARK: - Tab 1: AI Vision
    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Poskytovateľ AI Vision detekcie")
                    .font(.headline)

                VStack(spacing: 4) {
                    aiProviderRow(
                        mode: .omlxLocal,
                        title: "oMLX (Apple Silicon MLX)",
                        subtitle: "Lokálne MLX servovanie modelov Qwen2.5-VL / Llama-3.2-Vision (localhost:8000)",
                        icon: "apple.logo"
                    )

                    aiProviderRow(
                        mode: .ollamaLocal,
                        title: "Ollama (Local Vision)",
                        subtitle: "Lokálny Ollama server pre modely LLaVA / Llama-Vision (localhost:11434)",
                        icon: "laptopcomputer"
                    )

                    aiProviderRow(
                        mode: .builtInOnDevice,
                        title: "Interný režim (On-Device Vision)",
                        subtitle: "Základné počítačové videnie priamo na Macu bez externých serverov",
                        icon: "bolt.badge.checkmark"
                    )

                    aiProviderRow(
                        mode: .customAPIKey,
                        title: "Vlastný API kľúč (OpenAI / Claude / Gemini)",
                        subtitle: "Cloudové OpenAI-compatible API s bezpečným uložením kľúča v Kľúčenke",
                        icon: "key.fill"
                    )

                    aiProviderRow(
                        mode: .disabled,
                        title: "Vypnuté",
                        subtitle: "Využívať iba základné pravidlá bez asistencie AI",
                        icon: "xmark.circle"
                    )
                }

                Text("Vstavané on-device pravidlá bežia vždy. Klasifikačný prompt sa použije iba pre oMLX, Ollama a Custom API; zvolený AI režim dopĺňa detekciu bezpečnostných prvkov podľa § 37.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                aiReadinessRows
            }
            .glassCard(cornerRadius: 12, padding: 12)

            VStack(alignment: .leading, spacing: 10) {
                Label("Naposledy otvorené dokumenty", systemImage: "clock.arrow.circlepath")
                    .font(.headline)

                Toggle(
                    "Pamätať naposledy otvorené dokumenty",
                    isOn: $settingsStore.settings.retainRecentDocuments)

                Text("Uloží najviac osem bezpečných bookmarkov pre rýchly návrat po reštarte. Obsah dokumentov sa do zoznamu neukladá.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .glassCard(cornerRadius: 12, padding: 12)

            if settingsStore.settings.aiMode == .omlxLocal {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Konfigurácia oMLX (Apple Silicon)", systemImage: "apple.logo")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("API Endpoint")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)
                            TextField("http://localhost:8000/v1", text: $settingsStore.settings.omlxURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        GridRow {
                            Text("Vision Model")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            TextField("mlx-community/Qwen2.5-VL-7B-Instruct-4bit", text: $settingsStore.settings.omlxModel)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text("oMLX beží na Apple Silicon s natívnou akceleráciou GPU/Neural Engine. Odporúčané modely: Qwen2.5-VL, Llama-3.2-11B-Vision-Instruct.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .glassCard(cornerRadius: 12, padding: 12)
            }

            if settingsStore.settings.aiMode == .ollamaLocal {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Konfigurácia Ollama", systemImage: "laptopcomputer")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("Server URL")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)
                            TextField("http://localhost:11434", text: $settingsStore.settings.ollamaURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        GridRow {
                            Text("Model")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            TextField("llava / llama3.2-vision", text: $settingsStore.settings.ollamaModel)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text("100 % offline spracovanie priamo na Macu cez lokálny Ollama server.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .glassCard(cornerRadius: 12, padding: 12)
            }

            if settingsStore.settings.aiMode == .customAPIKey {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Vlastný API kľúč", systemImage: "key.fill")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("Base URL")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)
                            TextField("https://api.openai.com/v1", text: $settingsStore.settings.openAICompatibleBaseURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        GridRow {
                            Text("Model")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            TextField("gpt-4o-mini", text: $settingsStore.settings.openAICompatibleModel)
                                .textFieldStyle(.roundedBorder)
                        }

                        GridRow {
                            Text("API kľúč (Keychain)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            SecureField("sk-…", text: Binding(
                                get: { KeychainStore.load(account: "ai.apikey") ?? "" },
                                set: { newValue in
                                    if newValue.isEmpty {
                                        KeychainStore.delete(account: "ai.apikey")
                                    } else {
                                        _ = KeychainStore.save(secret: newValue, account: "ai.apikey")
                                    }
                                }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text("Kľúč sa ukladá výhradne do systémovej Kľúčenky tohto Macu.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .glassCard(cornerRadius: 12, padding: 12)
            }

            let promptEnabled = settingsStore.settings.aiMode.supportsPromptOverride
            if promptEnabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Klasifikačný prompt pre LLM")
                        .font(.headline)
                    Spacer()
                    Button("Obnoviť predvolený") {
                        settingsStore.settings.aiPrompt = nil
                        selectedPromptPreset = .legalDocuments
                    }
                    .controlSize(.small)
                    .disabled(!promptEnabled)
                }

                Picker("Predvoľba promptu", selection: $selectedPromptPreset) {
                    ForEach(AIPromptPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!promptEnabled)
                .onChange(of: selectedPromptPreset) { _, preset in
                    if let promptText = preset.promptText {
                        settingsStore.settings.aiPrompt = promptText
                    }
                }

                TextEditor(text: Binding(
                    get: { settingsStore.settings.aiPrompt ?? "" },
                    set: { newValue in
                        selectedPromptPreset = .customPrompt
                        settingsStore.settings.aiPrompt =
                            newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil : newValue
                    }))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 64)
                    .padding(4)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .disabled(!promptEnabled)

                Text("Prázdne pole znamená schválený predvolený prompt. Prompt sa použije iba pre oMLX, Ollama a vlastné API.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .glassCard(cornerRadius: 12, padding: 12)
            .onAppear {
                let current = settingsStore.settings.aiPrompt
                selectedPromptPreset = AIPromptPreset.allCases.first {
                    $0.promptText == current
                } ?? (current == nil ? .legalDocuments : .customPrompt)
            }
            }

            LearningDatasetCard(settingsStore: settingsStore, bank: settingsStore.exampleBank, waitForLearningWrites: waitForLearningWrites)
        }
    }

    @ViewBuilder
    private var aiReadinessRows: some View {
        let mode = settingsStore.settings.aiMode
        VStack(alignment: .leading, spacing: 6) {
            Text("Pripravenosť zvolenej konfigurácie")
                .font(.caption.weight(.semibold))
            switch mode {
            case .omlxLocal:
                readinessRow("oMLX URL", value: settingsStore.settings.omlxURL,
                             isReady: validEndpoint(settingsStore.settings.omlxURL))
                readinessRow("oMLX model", value: settingsStore.settings.omlxModel,
                             isReady: !settingsStore.settings.omlxModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .ollamaLocal:
                readinessRow("Ollama URL", value: settingsStore.settings.ollamaURL,
                             isReady: validEndpoint(settingsStore.settings.ollamaURL))
                readinessRow("Ollama model", value: settingsStore.settings.ollamaModel,
                             isReady: !settingsStore.settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .customAPIKey:
                readinessRow("Custom API URL", value: settingsStore.settings.openAICompatibleBaseURL,
                             isReady: validEndpoint(settingsStore.settings.openAICompatibleBaseURL))
                readinessRow("Custom API model", value: settingsStore.settings.openAICompatibleModel,
                             isReady: !settingsStore.settings.openAICompatibleModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                readinessRow("Custom API keychain key", value: KeychainStore.load(account: "ai.apikey") == nil ? "Chýba" : "Uložený",
                             isReady: !(KeychainStore.load(account: "ai.apikey") ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .builtInOnDevice, .disabled:
                Text("Vstavaný detektor beží vždy. Prompt sa v tomto režime nepoužíva.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readinessRow(_ label: String, value: String, isReady: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isReady ? .green : .orange)
            Text(label)
                .font(.caption2.weight(.medium))
            Spacer()
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func validEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    private func aiProviderRow(mode: AppSettings.AIMode, title: String, subtitle: String, icon: String) -> some View {
        let isSelected = settingsStore.settings.aiMode == mode

        return Button {
            settingsStore.settings.aiMode = mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 22)

                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Vybraný" : "Nevybraný")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Tab 2: Konverzia PDF/A
    private var conversionTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Spôsob konverzie do PDF/A")
                    .font(.headline)

                Picker("Režim PDF/A", selection: $settingsStore.settings.pdfaMode) {
                    ForEach(PDFAConversionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("Vektorová konverzia zachováva textovú vrstvu; rasterizovaná garancia (200 dpi) vyrovná problematické skeny. Obe možnosti spĺňajú štandard PDF/A-2b.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .glassCard(cornerRadius: 12, padding: 12)

            VStack(alignment: .leading, spacing: 14) {
                Label("Časová pečiatka (RFC 3161 TSA)", systemImage: "clock.badge.checkmark")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Aktívna TSA")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)

                        Picker("Aktívna TSA", selection: $settingsStore.settings.selectedTSAURL) {
                            ForEach(settingsStore.settings.availableTSAServers) { server in
                                Text("\(server.name) (\(server.url))").tag(server.url)
                            }
                        }
                        .accessibilityLabel("Aktívna TSA")
                    }
                }

                if !settingsStore.settings.customTSAServers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Vlastné TSA servery")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(settingsStore.settings.customTSAServers, id: \.self) { server in
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundStyle(.secondary)
                                Text(server)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    tsaToDelete = server
                                    showTSADeleteConfirmation = true
                                } label: {
                                    Label("Odstrániť TSA server", systemImage: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("https://vlastna-tsa.sk/tsp", text: $newTSAURL)
                        .textFieldStyle(.roundedBorder)

                    Button("Pridať TSA") {
                        let trimmed = newTSAURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !settingsStore.settings.customTSAServers.contains(trimmed) else { return }
                        settingsStore.settings.customTSAServers.append(trimmed)
                        newTSAURL = ""
                    }
                    .disabled(newTSAURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack(spacing: 10) {
                    Button {
                        testTSAConnection()
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingTSA {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                            }
                            Text("Otestovať spojenie")
                        }
                    }
                    .disabled(isTestingTSA || settingsStore.settings.selectedTSAURL.isEmpty)

                    if let status = tsaTestStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? Color.green : Color.red)
                    }
                }
            }
            .glassCard(cornerRadius: 12, padding: 12)

            MobileSigningCard(settingsStore: settingsStore)
            WebSigningStorageCard(settingsStore: settingsStore)
        }
    }

    private func testTSAConnection() {
        isTestingTSA = true
        tsaTestStatus = nil
        let urlString = settingsStore.settings.selectedTSAURL
        Task {
            defer { isTestingTSA = false }
            guard let url = URL(string: urlString), url.scheme != nil else {
                tsaTestStatus = "✗ Neplatná adresa TSA."
                return
            }
            do {
                let reply = try await RFC3161TimestampClient()
                    .requestToken(for: Data("chevron7-tsa-connectivity-test".utf8), tsaURL: url)
                if let time = reply.genTime {
                    tsaTestStatus = "✓ Pečiatka prijatá (\(AttestationClauseGenerator.isoFormatter.string(from: time)))"
                } else {
                    tsaTestStatus = "✓ Token prijatý (\(reply.token.count) B)."
                }
            } catch {
                tsaTestStatus = "✗ \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Tab 3: EZZK
    private var ezzkTab: some View {
        let controller = settingsStore.ezzkAccountController

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ezzkEnvironmentCard(controller)
                if !controller.isDemoMode {
                    ezzkAccountCard(controller)
                }
            }

            if !controller.isDemoMode {
                HStack(alignment: .top, spacing: 14) {
                    ezzkLookupCard(controller)
                    ezzkNumbersCard(controller)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                ezzkSubmissionCard
                ezzkMigrationCard
            }
        }
        .frame(maxWidth: 960, alignment: .topLeading)
        .onAppear { ezzkLoginField = controller.storedLogin }
        .onChange(of: controller.mode) { _, _ in
            ezzkLoginField = controller.storedLogin
            ezzkPasswordField = ""
            ezzkLookupResult = nil
            ezzkLookupError = nil
            ezzkTestNumbers = []
            ezzkNumbersError = nil
        }
    }

    private func ezzkEnvironmentCard(_ controller: EZZKAccountController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Prostredie EZZK", systemImage: "server.rack")
                .font(.headline)

            Picker("Prostredie", selection: Binding(
                get: { controller.mode },
                set: { newMode in
                    settingsStore.settings.ezzkMode = newMode
                    controller.setMode(newMode)
                }
            )) {
                ForEach(AppSettings.EZZKMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.state == .verifying || ezzkLookupInProgress || ezzkNumbersInProgress)

            Text(ezzkModeExplanation(controller.mode,
                                     productionAllowed: controller.productionPolicy.allowsConsequentialCalls))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let environment = controller.environment {
                Divider().opacity(0.5)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ezzkEndpointRow(label: "Prihlásenie", value: environment.soapLoginURL.absoluteString)
                    ezzkEndpointRow(label: "Služba", value: environment.soapServiceURL.absoluteString)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    private func ezzkModeExplanation(_ mode: AppSettings.EZZKMode, productionAllowed: Bool) -> String {
        switch mode {
        case .demo:
            "Demo používa iba lokálnu simuláciu, nič sa neposiela do EZZK."
        case .test:
            "Testovacie prostredie EZZK na overenie integrácie. Čísla ani záznamy nemajú právne účinky."
        case .production where productionAllowed:
            "Ostré EZZK: čísla aj záznamy majú právne účinky. Každá konverzia sa zapíše do centrálnej evidencie."
        case .production:
            "Ostré EZZK. Zatiaľ iba overenie prihlásenia, čas servera a vyhľadanie záznamu."
        }
    }

    private func ezzkEndpointRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func ezzkAccountCard(_ controller: EZZKAccountController) -> some View {
        let presentation = ezzkStatePresentation(controller.state,
                                                 hasStoredCredentials: controller.hasStoredCredentials)

        return VStack(alignment: .leading, spacing: 10) {
            Label("Účet EZZK", systemImage: "person.badge.key")
                .font(.headline)

            Label(presentation.title, systemImage: presentation.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(presentation.color)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Prihlasovacie meno")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("z registračného e-mailu EZZK", text: $ezzkLoginField)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }
                GridRow {
                    Text("Heslo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(controller.hasStoredCredentials ? "uložené v Keychaine" : "heslo do EZZK",
                                text: $ezzkPasswordField)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                }
                GridRow {
                    Text("Názov osoby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("presne ako v doložke", text: $settingsStore.settings.ezzkPersonName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("IČO")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("IČO osoby", text: $settingsStore.settings.ezzkICO)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 8) {
                Button {
                    let login = ezzkLoginField
                    let password = ezzkPasswordField
                    Task {
                        await controller.signIn(login: login, password: password)
                        if case .signedIn = controller.state {
                            ezzkPasswordField = ""
                        }
                    }
                } label: {
                    Label("Prihlásiť a overiť", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(controller.state == .verifying || ezzkLoginField.isEmpty || ezzkPasswordField.isEmpty)

                if controller.hasStoredCredentials {
                    Button("Odhlásiť", role: .destructive) {
                        controller.signOut()
                        // A failed sign-out keeps the stored login, so keep showing it.
                        ezzkLoginField = controller.storedLogin
                        ezzkPasswordField = ""
                    }
                    .controlSize(.small)
                }
            }

            Text("Heslo sa uloží iba do Keychainu tohto Macu, a to až po úspešnom overení v EZZK.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = controller.state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    private func ezzkStatePresentation(
        _ state: EZZKAccountController.State,
        hasStoredCredentials: Bool
    ) -> (title: String, symbol: String, color: Color) {
        switch state {
        case .signedOut:
            hasStoredCredentials
                ? ("Prihlásenie uložené", "key.fill", .secondary)
                : ("Neprihlásené", "person.crop.circle", .secondary)
        case .verifying:
            ("Overuje sa v EZZK", "arrow.triangle.2.circlepath", .orange)
        case .signedIn(let accountName, let checkedAt):
            ("Overené: \(accountName), \(checkedAt.formatted(date: .omitted, time: .shortened))",
             "checkmark.seal.fill", .green)
        case .failed:
            ("Prihlásenie zlyhalo", "exclamationmark.triangle.fill", .red)
        }
    }

    private func ezzkLookupCard(_ controller: EZZKAccountController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Overenie záznamu", systemImage: "magnifyingglass")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("evidenčné číslo", text: $ezzkLookupNumber)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { lookUpEZZKRecord(controller) }
                Button {
                    lookUpEZZKRecord(controller)
                } label: {
                    if ezzkLookupInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Vyhľadať")
                    }
                }
                .controlSize(.small)
                .disabled(ezzkLookupInProgress
                          || ezzkLookupNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = ezzkLookupError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let lookup = ezzkLookupResult {
                if !lookup.isProcessed {
                    Label("Záznam je evidovaný, ale ešte nespracovaný.", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let info = lookup.info {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ezzkInfoRow("Číslo", info.evidenceNumber)
                        ezzkInfoRow("Konverzia", info.executionTime?.formatted(date: .abbreviated, time: .standard))
                        ezzkInfoRow("Prijaté", info.receiptTime?.formatted(date: .abbreviated, time: .standard))
                        ezzkInfoRow("Osoba", info.personName)
                        ezzkInfoRow("Pôvodný", ezzkDocumentSummary(info.originalDocumentName,
                                                                  info.originalDocumentFormat,
                                                                  info.originalDocumentSheets))
                        ezzkInfoRow("Nový", ezzkDocumentSummary(info.newDocumentName, info.newDocumentFormat,
                                                               info.newDocumentSheets))
                    }
                }
            } else {
                Text("Overenie nepotrebuje prihlásenie a v EZZK nič nemení.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    @ViewBuilder
    private func ezzkInfoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
    }

    private func ezzkDocumentSummary(_ name: String?, _ format: String?, _ sheets: Int?) -> String {
        [name, format, sheets.map { "listov: \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    private func lookUpEZZKRecord(_ controller: EZZKAccountController) {
        let number = ezzkLookupNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, !ezzkLookupInProgress else { return }
        let requestedMode = controller.mode
        ezzkLookupInProgress = true
        ezzkLookupError = nil
        ezzkLookupResult = nil
        Task {
            defer { ezzkLookupInProgress = false }
            do {
                let result = try await controller.lookUp(evidenceNumber: number)
                if controller.mode == requestedMode {
                    ezzkLookupResult = result
                }
            } catch {
                if controller.mode == requestedMode {
                    ezzkLookupError = EZZKAccountController.message(for: error)
                }
            }
        }
    }

    private func ezzkNumbersCard(_ controller: EZZKAccountController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Evidenčné čísla", systemImage: "number.square.fill")
                .font(.headline)

            if controller.mode == .production {
                // "Vyžiadať čísla" stays test only whatever the production policy: a production
                // number no record uses lapses at midnight and breaks the 24-hour reporting duty.
                Label(controller.productionPolicy.allowsConsequentialCalls
                      ? "V produkcii sa evidenčné číslo získava iba v zaručenej konverzii."
                      : "V produkcii je pridelenie evidenčného čísla zatiaľ zamknuté, aj v zaručenej konverzii. Na skúšku použite režim Demo alebo Test.",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    showEZZKNumbersConfirmation = true
                } label: {
                    if ezzkNumbersInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Vyžiadať čísla")
                    }
                }
                .controlSize(.small)
                .disabled(ezzkNumbersInProgress || !controller.hasStoredCredentials)

                if let error = ezzkNumbersError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !ezzkTestNumbers.isEmpty {
                    Text(ezzkTestNumbers.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("Vyžaduje uložené prihlásenie, názov osoby a IČO.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    private func requestEZZKTestNumbers() async {
        let controller = settingsStore.ezzkAccountController
        let requestedMode = controller.mode
        ezzkNumbersInProgress = true
        ezzkNumbersError = nil
        defer { ezzkNumbersInProgress = false }
        do {
            let numbers = try await settingsStore.requestTestNumbersIntoPool()
            if controller.mode == requestedMode {
                ezzkTestNumbers = numbers
            }
        } catch {
            if controller.mode == requestedMode {
                ezzkNumbersError = EZZKAccountController.message(for: error)
            }
        }
    }

    private var ezzkSubmissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Odosielanie záznamov", systemImage: "arrow.up.doc")
                .font(.headline)

            let controller = settingsStore.ezzkAccountController
            let status = ezzkSubmissionStatus(controller.mode,
                                              productionAllowed: controller.productionPolicy.allowsConsequentialCalls)
            Label(status.title, systemImage: status.symbol)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    private func ezzkSubmissionStatus(_ mode: AppSettings.EZZKMode,
                                      productionAllowed: Bool) -> (title: String, symbol: String, detail: String) {
        switch mode {
        case .demo:
            ("Lokálna simulácia", "desktopcomputer",
             "Podpísaný záznam o konverzii sa vytvorí, ale do EZZK sa neodošle. Stav v Registri konverzií je iba ukážkový.")
        case .test:
            ("Zapnuté automaticky", "checkmark.circle",
             "Po autorizácii sa záznam o konverzii podpíše rovnakým PIN a hneď odošle do testovacieho EZZK. Čakajúce odoslania a stav spracovania aplikácia overuje každých päť minút; výsledok je v Registri konverzií.")
        case .production where productionAllowed:
            ("Zapnuté automaticky", "checkmark.circle",
             "Po autorizácii sa záznam o konverzii podpíše rovnakým PIN a hneď odošle do ostrého EZZK. Čakajúce odoslania a stav spracovania aplikácia overuje každých päť minút; výsledok je v Registri konverzií.")
        case .production:
            ("Príde v ďalšej verzii", "lock",
             "Na produkcii sú pridelenie čísla aj odoslanie záznamu zatiaľ zamknuté. Zapnú sa po overení prvej ostrej konverzie.")
        }
    }

    private var ezzkMigrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Kontaktné údaje pre migráciu", systemImage: "archivebox")
                .font(.headline)

            Text("Tieto údaje slúžia iba na migráciu historických záznamov. Na prihlásenie sa nepoužívajú.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Notifikačný e-mail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("advokat@kancelaria.sk", text: $settingsStore.settings.ezzkNotificationEmail)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Adresa eDesk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("elektronická schránka", text: $settingsStore.settings.ezzkEdeskAddress)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
    }

    // MARK: - Tab 4: Finder Quick Action
    private var finderQuickActionTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Podpisovanie z Findera", systemImage: "finder")
                    .font(.headline)

                Text(
                    "Quick Action je samostatné Automator workflow. Spúšťa pomocný program podpisového enginu v pozadí, takže hlavné okno aplikácie sa pri podpise neotvorí."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Výstupom je podpísané PDF vo formáte PAdES Baseline T s kvalifikovanou časovou pečiatkou. Workflow zobrazí iba výber ovládača, certifikátu a PIN/BOK dialóg."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(spacing: 10) {
                    Button("Nainštalovať Quick Action") {
                        finderQuickActionStatus = FinderQuickActionService.installQuickAction()
                            ? "Quick Action bola nainštalovaná do služieb Findera."
                            : "Quick Action sa nepodarilo nainštalovať."
                    }
                    .controlSize(.small)

                    Button("Obnoviť služby") {
                        finderQuickActionStatus = FinderQuickActionService.refreshServicesCache()
                            ? "Registrácia služieb bola odoslaná systému macOS."
                            : "Registráciu služieb sa nepodarilo obnoviť."
                    }
                    .controlSize(.small)

                    if let finderQuickActionStatus {
                        Text(finderQuickActionStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12, padding: 12)

            VStack(alignment: .leading, spacing: 10) {
                Label("Aktivácia vo Findere", systemImage: "questionmark.circle")
                    .font(.headline)

                Text(
                    """
                    1. Nainštalujte Chevron7 do priečinka /Applications.
                    2. Kliknite na Nainštalovať Quick Action vyššie. Chevron7 ju uloží do ~/Library/Services.
                    3. Vo Findere otvorte Quick Actions → Customize... a zaškrtnite \(FinderQuickActionService.menuTitle).
                    4. Vo Findere označte jeden alebo viac PDF súborov.
                    5. Kliknite pravým tlačidlom myši a zvoľte Quick Actions → \(FinderQuickActionService.menuTitle).
                    6. Chevron7 vyberie dostupný podpisový certifikát, pričom mandátny certifikát uprednostní. PIN alebo BOK zadáte iba počas podpisu.
                    """
                )
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Ak položka nie je ani v Customize..., ukončite a znova spustite Chevron7, kliknite na Obnoviť služby a reštartujte Finder. Workflow prijíma iba PDF súbory, nie ASiC-E kontajnery. PIN sa nikdy neukladá do nastavení."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 12, padding: 12)
        }
    }

    // MARK: - Tab 5: Profily advokáta
    private var profilesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Správa profilov advokáta")
                    .font(.headline)

                Spacer()

                Button {
                    let profile = AdvocateProfile()
                    settingsStore.settings.profiles.append(profile)
                    settingsStore.settings.activeProfileID = profile.id
                } label: {
                    Label("Nový profil", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if settingsStore.settings.profiles.isEmpty {
                Text("Zatiaľ nemáte vytvorený profil. Kliknite na 'Nový profil' pre pridanie údajov advokáta.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .glassCard()
            } else {
                ForEach($settingsStore.settings.profiles) { $profile in
                    let isActive = settingsStore.settings.activeProfileID == profile.id

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(profile.displayName.isEmpty ? "Nový profil" : profile.displayName)
                                .font(.headline)

                            if isActive {
                                Text("AKTÍVNY")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.green)
                            }

                            Spacer()

                            if !isActive {
                                Button("Nastaviť ako aktívny") {
                                    settingsStore.settings.activeProfileID = profile.id
                                }
                                .controlSize(.small)
                            }

                            if settingsStore.settings.profiles.count > 1 {
                                Button(role: .destructive) {
                                    profileToDelete = profile.id
                                    showProfileDeleteConfirmation = true
                                } label: {
                                    Label("Odstrániť profil", systemImage: "trash")
                                }
                                .controlSize(.small)
                            }
                        }

                        Divider()

                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                            GridRow {
                                Text("Meno a priezvisko")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 160, alignment: .leading)
                                TextField("JUDr. Meno Priezvisko", text: $profile.fullName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("Funkcia")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                TextField("advokát", text: $profile.position)
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("Evidenčné číslo SAK")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                TextField("1234", text: $profile.registrationNumber)
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("IČO kancelárie")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                TextField("IČO", text: $profile.ico)
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("Názov kancelárie")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                TextField("Advokátska kancelária…", text: $profile.officeName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("Adresa kancelárie")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                TextField("Ulica, PSČ a mesto", text: $profile.officeAddress)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        Toggle("Právnická osoba (kancelária)", isOn: $profile.isLegalEntity)
                            .font(.callout)
                            .toggleStyle(.switch)
                    }
                    .glassCard(cornerRadius: 12, padding: 12)
                }
            }
        }
    }
}

extension AdvocateProfile {
    var displayName: String {
        fullName.isEmpty ? officeName : fullName
    }
}

enum LearningCardText {
    static func summary(counts: [BankLabel: Int]) -> String {
        func n(_ label: BankLabel) -> Int { counts[label] ?? 0 }
        return "Pečiatky: \(n(.kind(.officialStamp))) · Podpisy: \(n(.kind(.handwrittenSignature))) · " +
               "Slepotlač: \(n(.kind(.embossedSeal))) · Parafy: \(n(.kind(.initial))) · " +
               "Šnúrky: \(n(.kind(.bindingCord))) · Pásky: \(n(.kind(.securityTape))) · Pečate: \(n(.kind(.waxSeal))) · " +
               "Ochranné prvky: \([SecurityElement.Kind.watermark, .securityPattern, .opticallyVariable, .securityFoil, .lamination].reduce(0) { $0 + n(.kind($1)) }) · " +
               "Iné: \(n(.kind(.other))) · Zamietnuté: \(n(.negative))"
    }
}

struct LearningDatasetCard: View {
    @Bindable var settingsStore: AppSettingsStore
    let bank: ExampleBank
    var waitForLearningWrites: @MainActor () async -> Void = {}
    @Environment(\.openWindow) private var openWindow
    @State private var counts: [BankLabel: Int] = [:]
    @State private var exportMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var modelAvailable = false
    @State private var readinessText: String?
    @State private var activeModelText: String?
    @State private var hasPreviousModel = false
    @State private var hasActiveModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Učenie a lokálny dataset").font(.headline)

            Toggle("Klasifikovať neisté nálezy modelom na tomto Macu (Apple Intelligence)",
                   isOn: $settingsStore.settings.useFoundationModelClassifier)
                .disabled(!modelAvailable)
            Text(modelAvailable
                 ? "Model beží výhradne na tomto Macu. Bez neho rozhoduje iba porovnanie s potvrdenými príkladmi."
                 : "On-device model nie je na tomto Macu dostupný. Zapnite Apple Intelligence v Systémových nastaveniach.")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("Učiť sa z potvrdených a odmietnutých prvkov", isOn: $settingsStore.settings.learnFromReviews)
            Text(LearningCardText.summary(counts: counts))
                .font(.caption.monospacedDigit())
            Text("Export pre Create ML obsahuje iba úplne skontrolované strany. Kontroly originálu bez obrazovej oblasti sa neučia. Potvrdenia dopĺňajú lokálne príklady, nepretrénovávajú systémový model.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Dataset zostáva na tomto Macu. Obsahuje náhľady strán dokumentov, ktorých prvky ste potvrdili alebo odmietli. Nikdy sa neodosiela.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Button("Exportovať dataset pre Create ML…") { exportDataset() }
                Button("Vymazať lokálny dataset…", role: .destructive) { showDeleteConfirmation = true }
                Spacer()
            }
            .controlSize(.small)

            Divider()
            Text("Vlastný detektor").font(.headline)
            Text("Ako sa Chevron7 učí: rovnaký výrez si zapamätá hneď, rovnaký dokument si prinesie vašu kontrolu a dosť skontrolovaných strán natrénuje detektor aj pre nové dokumenty, iba na tomto Macu.")
                .font(.caption2).foregroundStyle(.secondary)

            if let readinessText {
                Text(readinessText).font(.caption.monospacedDigit())
            }
            if let activeModelText {
                Text(activeModelText).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Otvoriť trénovanie…") { openWindow(id: DetectorTrainingWindow.id) }
                if hasActiveModel {
                    Button("Exportovať detektor…") { exportModel() }
                }
                if hasPreviousModel {
                    Button("Vrátiť predchádzajúci detektor") { rollbackModel() }
                }
                Spacer()
            }
            .controlSize(.small)
            Text("Prenos detektora nesie iba model, nikdy vaše skeny ani príklady. Dovezený detektor sa aktivuje, len keď prejde overením na vašich stranách.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Pripomínať trénovanie detektora", isOn: $settingsStore.settings.detectorTrainingOffersEnabled)
            .controlSize(.small)
            if let exportMessage {
                Text(exportMessage).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .glassCard(cornerRadius: 12, padding: 12)
        .task { await refreshCounts() }
        .confirmationDialog("Vymazať všetky uložené príklady?", isPresented: $showDeleteConfirmation) {
            Button("Vymazať", role: .destructive) {
                Task {
                    do {
                        await waitForLearningWrites()
                        try await bank.removeAll()
                        exportMessage = "Lokálny dataset bol vymazaný."
                    } catch {
                        exportMessage = "Vymazanie zlyhalo: \(error.localizedDescription)"
                    }
                    await refreshCounts()
                }
            }
            Button("Zrušiť", role: .cancel) {}
        }
    }

    private func refreshCounts() async {
        modelAvailable = SystemLanguageModel.default.isAvailable
        let entries = await bank.entries()
        counts = Dictionary(grouping: entries, by: \.label).mapValues(\.count)
        await refreshTrainingStatus()
    }

    private func refreshTrainingStatus() async {
        let bankDir = await bank.directory
        let root = ModelRegistry.modelsDirectory(in: bankDir)
        let pages = (try? await bank.reviewedPages()) ?? []
        let state = (try? TrainingState.load(from: root)) ?? TrainingState()
        let settings = settingsStore.settings
        let report = DetectorTrainingReadiness.report(
            pages: pages, lastRunAt: state.lastRunAt,
            learnOn: settings.learnFromReviews,
            offersEnabled: settings.detectorTrainingOffersEnabled,
            snoozedUntil: state.snoozedUntil)
        if state.lastRunAt == nil {
            readinessText = "Skontrolované strany: \(report.reviewedPages) z \(DetectorTrainingReadiness.firstRunPages) pre prvé trénovanie"
        } else {
            readinessText = "Nové strany od posledného trénovania: \(report.newSinceLastTraining) z \(DetectorTrainingReadiness.retrainNewPages)"
        }
        let registry = ModelRegistry(root: root)
        if let meta = try? JSONDecoder().decode(
            ModelMetadata.self,
            from: Data(contentsOf: root.appendingPathComponent("active/metadata.json"))) {
            let date = meta.trainedAt.formatted(date: .numeric, time: .omitted)
            activeModelText = "Aktívny vlastný detektor z \(date): recall +\(Int((meta.recallGain * 100).rounded())) %."
            hasActiveModel = true
        } else {
            activeModelText = nil
            hasActiveModel = false
        }
        hasPreviousModel = FileManager.default.fileExists(
            atPath: registry.previousModelURL().path)
    }

    private func rollbackModel() {
        Task {
            do {
                let bankDir = await bank.directory
                try ModelRegistry(root: ModelRegistry.modelsDirectory(in: bankDir)).rollback()
                exportMessage = "Vrátený predchádzajúci detektor."
            } catch {
                exportMessage = "Vrátenie zlyhalo: \(error.localizedDescription)"
            }
            await refreshCounts()
        }
    }

    private func exportModel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Detector.zip"
        panel.prompt = "Exportovať"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let bankDir = await bank.directory
                try ModelTransfer().exportActiveModel(
                    modelsRoot: ModelRegistry.modelsDirectory(in: bankDir), to: url)
                exportMessage = "Detektor exportovaný: \(url.lastPathComponent). Obsahuje iba model, nikdy vaše skeny."
            } catch {
                exportMessage = "Export zlyhal: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private func exportDataset() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Exportovať"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            do {
                await waitForLearningWrites()
                let url = try await CreateMLExporter.export(bank: bank, to: folder)
                exportMessage = "Export hotový: \(url.path)"
            } catch {
                exportMessage = "Export zlyhal: \(error.localizedDescription)"
            }
        }
    }
}

/// Where browser signatures are kept.
///
/// An in-app signature is written next to the file it came from. A browser
/// signature has no such file, so without a folder of its own it would leave no
/// local trace at all.
struct WebSigningStorageCard: View {
    @Bindable var settingsStore: AppSettingsStore
    @State private var agentStatus: WebBridgeAgentService.Status = .notRegistered

    private var resolvedFolder: String {
        let configured = settingsStore.settings.webSigningOutputPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            return settingsStore.outputDirectory.path
        }
        return (configured as NSString).expandingTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Podpisovanie z prehliadača", systemImage: "safari")
                .font(.headline)

            agentStatusRow

            Toggle("Ukladať podpísané dokumenty aj lokálne",
                   isOn: $settingsStore.settings.webSigningSavesLocally)
            Text("Podpis z prehliadača sa vracia stránke. Bez tejto možnosti po ňom na Macu nezostane žiadny súbor, ktorý by sa dal neskôr overiť.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Priečinok")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    HStack(spacing: 8) {
                        TextField("Predvolený priečinok aplikácie",
                                  text: $settingsStore.settings.webSigningOutputPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Vybrať…") { chooseFolder() }
                    }
                    .disabled(!settingsStore.settings.webSigningSavesLocally)
                }
            }
            Text("Aktuálne: \(resolvedFolder)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Picker("Automaticky presunúť kópie do Koša", selection: $settingsStore.settings.webSigningRetentionDays) {
                Text("Nikdy").tag(0)
                Text("Po 7 dňoch").tag(7)
                Text("Po 30 dňoch").tag(30)
                Text("Po 90 dňoch").tag(90)
            }
            .disabled(!settingsStore.settings.webSigningSavesLocally)
            Text("Týka sa iba kópií podpisov z prehliadača. Dokumenty podpísané v aplikácii zostávajú, kde ste ich uložili.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .glassCard(cornerRadius: 12, padding: 12)
        .onAppear { agentStatus = WebBridgeAgentService.currentStatus() }
    }

    /// The launchd agent the Safari extension reaches the app through; without it
    /// a portal never gets an answer.
    @ViewBuilder
    private var agentStatusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch agentStatus {
            case .enabled:
                Label("Prepojenie so Safari je zapnuté.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .requiresApproval:
                Label("Prepojenie so Safari čaká na povolenie v Položkách pri prihlásení.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Otvoriť Položky pri prihlásení…") { WebBridgeAgentService.openLoginItemsSettings() }
            case .notRegistered:
                Label("Prepojenie so Safari nie je zaregistrované.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
            case .failed(let message):
                Label("Prepojenie so Safari sa nepodarilo zaregistrovať: \(message)",
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Button("Otvoriť Položky pri prihlásení…") { WebBridgeAgentService.openLoginItemsSettings() }
            case .translocated:
                Label("Chevron7 beží priamo z disku DMG alebo z neprenesenej kópie, odkiaľ macOS prepojenie so Safari nedovolí. Presuňte Chevron7 do priečinka Applications a spustite ho znova.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .unsignedBuild:
                Label("Vývojárska zostava bez Developer ID: prepojenie so Safari registruje scripts/install-webbridge-agent.sh.",
                      systemImage: "hammer")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Vybrať"
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.webSigningOutputPath = url.path
        }
    }
}

struct MobileSigningCard: View {
    @Bindable var settingsStore: AppSettingsStore
    @State private var agpKeyStored = false
    @State private var agpPublicPEM = ""
    @State private var agpError: String?
    @State private var agpBusy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Podpisovanie mobilom", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .font(.headline)

            Toggle("Ponúkať podpis občianskym preukazom s NFC cez iPhone",
                   isOn: $settingsStore.settings.mobileSigningEnabled)
            Text("Dokument sa zašifruje kľúčom, ktorý pozná len tento Mac, nahrá sa na server Slovensko.Digital a po naskenovaní QR kódu ho podpíšete v aplikácii Autogram v mobile. Server dokument zmaže do 24 hodín.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Server")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    TextField("https://autogram.slovensko.digital/api/v1", text: $settingsStore.settings.avmBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settingsStore.settings.mobileSigningEnabled)
                }
            }
            Text("Aplikácia Autogram v mobile otvára len odkazy z autogram.slovensko.digital. Iný server je určený len na testovanie.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Label("eIdentita (štátna aplikácia)", systemImage: "person.badge.key")
                .font(.callout.weight(.semibold))
            Text("Podpis cez eIdentitu ide cez portál Autogram: dokument sa nahrá do vášho balíka, QR kód z portálu naskenujete mobilom a podpísaný dokument sa stiahne späť. Portál nepozná heslá pre integrácie: správcu portálu požiadajte o zapnutie API pre váš účet a o vaše číselné ID používateľa; verejný kľúč odtiaľto potom vložíte do profilu na portáli.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Portál")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    TextField("https://agp.slovensko.digital", text: $settingsStore.settings.agpBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settingsStore.settings.mobileSigningEnabled || agpBusy)
                }
                GridRow {
                    Text("ID používateľa")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    TextField("číslo z profilu na portáli", text: $settingsStore.settings.agpUserID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settingsStore.settings.mobileSigningEnabled || agpBusy)
                }
            }
            HStack(spacing: 8) {
                Button {
                    agpBusy = true
                    agpError = nil
                    Task {
                        do {
                            let key = AGPTokenMinter.generateKey()
                            try AGPKeyStore().savePrivateKey(Data(key.rawRepresentation))
                            agpPublicPEM = AGPTokenMinter.spkiPEM(publicKey: key.publicKey)
                            agpKeyStored = true
                        } catch {
                            agpError = error.localizedDescription
                        }
                        agpBusy = false
                    }
                } label: {
                    Label(agpKeyStored ? "Vygenerovať nový kľúč" : "Vygenerovať kľúč", systemImage: "key")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!settingsStore.settings.mobileSigningEnabled || agpBusy)
                Button {
                    agpBusy = true
                    agpError = nil
                    Task {
                        do {
                            let client = try AGPClient.configured(
                                userID: settingsStore.settings.agpUserID,
                                baseURL: settingsStore.settings.agpBaseURLValue,
                                keyStore: AGPKeyStore())
                            guard try await client.verifyToken() else { throw AGPError.invalidResponse }
                        } catch {
                            agpError = error.localizedDescription
                        }
                        agpBusy = false
                    }
                } label: {
                    Label("Overiť", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!settingsStore.settings.mobileSigningEnabled || agpBusy || !agpKeyStored)
                if agpKeyStored {
                    Button("Odstrániť kľúč", role: .destructive) {
                        try? AGPKeyStore().delete()
                        agpKeyStored = false
                        agpPublicPEM = ""
                    }
                    .controlSize(.small)
                }
            }
            if !agpPublicPEM.isEmpty {
                Text("Verejný kľúč do profilu na portáli:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(agpPublicPEM)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(agpPublicPEM, forType: .string)
                } label: {
                    Label("Skopírovať kľúč", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            Text("Súkromný kľúč žije iba v Keychaine tohto Macu. Token sa razí nanovo pre každý request a platí pár minút.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let agpError {
                Text(agpError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            // Derive the display from the stored private key: regenerating would
            // overwrite the key already registered with the portal.
            if let raw = try? AGPKeyStore().loadPrivateKey(),
               let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
                agpKeyStored = true
                agpPublicPEM = AGPTokenMinter.spkiPEM(publicKey: key.publicKey)
            } else {
                agpKeyStored = false
            }
        }
        .glassCard(cornerRadius: 12, padding: 12)
    }
}
