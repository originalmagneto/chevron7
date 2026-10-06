// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import FoundationModels
import SwiftUI
import UniformTypeIdentifiers

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

struct AISettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    var waitForLearningWrites: @MainActor () async -> Void = {}
    @Environment(\.openWindow) private var openWindow
    @State private var selectedPromptPreset: AIPromptPreset = .legalDocuments
    @State private var counts: [BankLabel: Int] = [:]
    @State private var reviewedPages: Int?
    @State private var message: String?
    @State private var showDeleteConfirmation = false
    @State private var modelAvailable = false
    @State private var readinessText: String?
    @State private var activeModelText: String?
    @State private var hasPreviousModel = false
    @State private var hasActiveModel = false

    private var bank: ExampleBank { settingsStore.exampleBank }

    private static let basicModes: [AppSettings.AIMode] = [.builtInOnDevice, .disabled]
    private static let allModes: [AppSettings.AIMode] = [.builtInOnDevice, .omlxLocal, .ollamaLocal, .customAPIKey, .disabled]

    var body: some View {
        let settings = settingsStore.settings
        let providerActive = SettingsAdvancedState.aiProviderIsActive(settings)
        let modes = (showAdvanced || providerActive) ? Self.allModes : Self.basicModes
        SettingsPaneForm(pane: .ai, pills: SettingsStatus.ai(mode: settings.aiMode, reviewedPages: reviewedPages)) {
            Section {
                Picker("Poskytovateľ", selection: $settingsStore.settings.aiMode) {
                    ForEach(modes) { mode in
                        Text(title(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Label("Detekcia", systemImage: "viewfinder")
            } footer: {
                Text("Vstavané pravidlá na tomto Macu bežia vždy. Zvolený režim dopĺňa detekciu bezpečnostných prvkov podľa § 37.")
            }

            if settings.aiMode.supportsPromptOverride {
                providerSection(showsBadge: !showAdvanced)
                if showAdvanced { promptSection }
            }

            Section {
                Toggle("Klasifikovať neisté nálezy modelom na tomto Macu (Apple Intelligence)",
                       isOn: $settingsStore.settings.useFoundationModelClassifier)
                    .disabled(!modelAvailable)
                Toggle("Učiť sa z potvrdených a odmietnutých prvkov", isOn: $settingsStore.settings.learnFromReviews)
                Text(LearningCardText.summary(counts: counts))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack {
                    if showAdvanced {
                        Button("Exportovať dataset pre Create ML…") { exportDataset() }
                    }
                    Spacer()
                    Button("Vymazať lokálny dataset…", role: .destructive) { showDeleteConfirmation = true }
                }
            } header: {
                Label("Učenie", systemImage: "graduationcap")
            } footer: {
                Text(modelAvailable
                     ? "Dataset aj model zostávajú na tomto Macu a nikdy sa neodosielajú."
                     : "On-device model nie je dostupný. Zapnite Apple Intelligence v Systémových nastaveniach.")
            }

            Section {
                if let readinessText {
                    Text(readinessText).monospacedDigit()
                }
                if let activeModelText {
                    Text(activeModelText).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Otvoriť trénovanie…") { openWindow(id: DetectorTrainingWindow.id) }
                    if showAdvanced, hasActiveModel {
                        Button("Exportovať detektor…") { exportModel() }
                    }
                    if hasPreviousModel {
                        Button("Vrátiť predchádzajúci detektor") { rollbackModel() }
                    }
                }
                if showAdvanced {
                    Toggle("Pripomínať trénovanie detektora", isOn: $settingsStore.settings.detectorTrainingOffersEnabled)
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            } header: {
                Label("Vlastný detektor", systemImage: "scope")
            } footer: {
                Text("Dosť skontrolovaných strán natrénuje detektor aj pre nové dokumenty, iba na tomto Macu. Prenos detektora nesie iba model, nikdy vaše skeny.")
            }
        }
        .task { await refresh() }
        .onAppear {
            let current = settingsStore.settings.aiPrompt
            selectedPromptPreset = AIPromptPreset.allCases.first { $0.promptText == current }
                ?? (current == nil ? .legalDocuments : .customPrompt)
        }
        .confirmationDialog("Vymazať všetky uložené príklady?", isPresented: $showDeleteConfirmation) {
            Button("Vymazať", role: .destructive) { deleteDataset() }
            Button("Zrušiť", role: .cancel) {}
        }
    }

    private func title(for mode: AppSettings.AIMode) -> String {
        switch mode {
        case .builtInOnDevice: "Interný režim (na tomto Macu)"
        case .omlxLocal: "oMLX (Apple Silicon MLX)"
        case .ollamaLocal: "Ollama (lokálny server)"
        case .customAPIKey: "Vlastný API kľúč (OpenAI-compatible)"
        case .disabled: "Vypnuté"
        }
    }

    // MARK: - Advanced provider

    private func providerSection(showsBadge: Bool) -> some View {
        Section {
            switch settingsStore.settings.aiMode {
            case .omlxLocal:
                TextField("API endpoint", text: $settingsStore.settings.omlxURL, prompt: Text("http://localhost:8000/v1"))
                TextField("Model", text: $settingsStore.settings.omlxModel,
                          prompt: Text("mlx-community/Qwen2.5-VL-7B-Instruct-4bit"))
                readinessRow("Endpoint", ready: validEndpoint(settingsStore.settings.omlxURL))
                readinessRow("Model", ready: !trimmed(settingsStore.settings.omlxModel).isEmpty)
            case .ollamaLocal:
                TextField("Server", text: $settingsStore.settings.ollamaURL, prompt: Text("http://localhost:11434"))
                TextField("Model", text: $settingsStore.settings.ollamaModel, prompt: Text("llava / llama3.2-vision"))
                readinessRow("Server", ready: validEndpoint(settingsStore.settings.ollamaURL))
                readinessRow("Model", ready: !trimmed(settingsStore.settings.ollamaModel).isEmpty)
            case .customAPIKey:
                TextField("Base URL", text: $settingsStore.settings.openAICompatibleBaseURL,
                          prompt: Text("https://api.openai.com/v1"))
                TextField("Model", text: $settingsStore.settings.openAICompatibleModel, prompt: Text("gpt-4o-mini"))
                SecureField("API kľúč", text: Binding(
                    get: { KeychainStore.load(account: "ai.apikey") ?? "" },
                    set: { newValue in
                        if newValue.isEmpty {
                            KeychainStore.delete(account: "ai.apikey")
                        } else {
                            _ = KeychainStore.save(secret: newValue, account: "ai.apikey")
                        }
                    }), prompt: Text("sk-…"))
                readinessRow("Base URL", ready: validEndpoint(settingsStore.settings.openAICompatibleBaseURL))
                readinessRow("API kľúč v Keychaine", ready: !trimmed(KeychainStore.load(account: "ai.apikey") ?? "").isEmpty)
            case .builtInOnDevice, .disabled:
                EmptyView()
            }
        } header: {
            HStack {
                AdvancedSectionHeader(title: "Konfigurácia poskytovateľa")
                if showsBadge { AdvancedBadge() }
            }
        } footer: {
            Text("Kľúč sa ukladá výhradne do Keychainu tohto Macu.")
        }
    }

    private var promptSection: some View {
        Section {
            Picker("Predvoľba promptu", selection: $selectedPromptPreset) {
                ForEach(AIPromptPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
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
                        newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue
                }))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 80)
            HStack {
                Spacer()
                Button("Obnoviť predvolený") {
                    settingsStore.settings.aiPrompt = nil
                    selectedPromptPreset = .legalDocuments
                }
            }
        } header: {
            AdvancedSectionHeader(title: "Klasifikačný prompt")
        } footer: {
            Text("Prázdne pole znamená schválený predvolený prompt. Prompt sa použije iba pre oMLX, Ollama a vlastné API.")
        }
    }

    private func readinessRow(_ label: String, ready: Bool) -> some View {
        LabeledContent(label) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
                .accessibilityLabel(ready ? "Pripravené" : "Chýba")
        }
    }

    private func validEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: trimmed(value)), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return false }
        return true
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Learning (moved from LearningDatasetCard)

    private func refresh() async {
        modelAvailable = SystemLanguageModel.default.isAvailable
        let entries = await bank.entries()
        counts = Dictionary(grouping: entries, by: \.label).mapValues(\.count)
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
        reviewedPages = state.lastRunAt == nil ? report.reviewedPages : nil
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
        hasPreviousModel = FileManager.default.fileExists(atPath: registry.previousModelURL().path)
    }

    private func deleteDataset() {
        Task {
            do {
                await waitForLearningWrites()
                try await bank.removeAll()
                message = "Lokálny dataset bol vymazaný."
            } catch {
                message = "Vymazanie zlyhalo: \(error.localizedDescription)"
            }
            await refresh()
        }
    }

    private func rollbackModel() {
        Task {
            do {
                let bankDir = await bank.directory
                try ModelRegistry(root: ModelRegistry.modelsDirectory(in: bankDir)).rollback()
                message = "Vrátený predchádzajúci detektor."
            } catch {
                message = "Vrátenie zlyhalo: \(error.localizedDescription)"
            }
            await refresh()
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
                try ModelTransfer().exportActiveModel(modelsRoot: ModelRegistry.modelsDirectory(in: bankDir), to: url)
                message = "Detektor exportovaný: \(url.lastPathComponent). Obsahuje iba model, nikdy vaše skeny."
            } catch {
                message = "Export zlyhal: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
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
                message = "Export hotový: \(url.path)"
            } catch {
                message = "Export zlyhal: \(error.localizedDescription)"
            }
        }
    }
}
