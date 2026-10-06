// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import SwiftUI

struct BrowserFinderSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    @State private var agentStatus: WebBridgeAgentService.Status = .notRegistered
    @State private var quickAction: QuickActionVisibility = .notInstalled
    @State private var finderMessage: String?
    @State private var showFinderGuide = false

    private var resolvedFolder: String {
        let configured = settingsStore.settings.webSigningOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? settingsStore.outputDirectory.path : (configured as NSString).expandingTildeInPath
    }

    var body: some View {
        let settings = settingsStore.settings
        let folderActive = SettingsAdvancedState.webSigningFolderIsActive(settings)
        let retentionActive = SettingsAdvancedState.webSigningRetentionIsActive(settings)
        SettingsPaneForm(pane: .browserFinder,
                         pills: SettingsStatus.browserFinder(agent: agentStatus, quickAction: quickAction)) {
            Section {
                agentStatusRow
                Toggle("Ukladať podpísané dokumenty aj lokálne", isOn: $settingsStore.settings.webSigningSavesLocally)
            } header: {
                Label("Safari", systemImage: "safari")
            } footer: {
                Text("Podpis z prehliadača sa vracia stránke. Bez lokálnej kópie po ňom na Macu nezostane súbor, ktorý by sa dal neskôr overiť.")
            }

            Section {
                LabeledContent("Quick Action") {
                    Text(quickActionText).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Ako aktivovať vo Findere…") { showFinderGuide = true }
                    Spacer()
                    if quickAction != .visible {
                        Button("Nainštalovať Quick Action") { install() }
                            .buttonStyle(.glassProminent)
                    }
                }
                if let finderMessage {
                    Text(finderMessage).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Label("Finder", systemImage: "folder")
            } footer: {
                Text("Podpíše označené PDF priamo z Findera (PAdES s kvalifikovanou časovou pečiatkou) bez otvorenia hlavného okna.")
            }

            if showAdvanced || folderActive || retentionActive {
                Section {
                    if showAdvanced || folderActive {
                        HStack {
                            TextField("Priečinok kópií", text: $settingsStore.settings.webSigningOutputPath,
                                      prompt: Text("Predvolený priečinok aplikácie"))
                            Button("Vybrať…") { chooseFolder() }
                            if !showAdvanced { AdvancedBadge() }
                        }
                        .disabled(!settings.webSigningSavesLocally)
                        LabeledContent("Aktuálne") {
                            Text(resolvedFolder).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if showAdvanced || retentionActive {
                        HStack {
                            Picker("Presunúť kópie do Koša", selection: $settingsStore.settings.webSigningRetentionDays) {
                                Text("Nikdy").tag(0)
                                Text("Po 7 dňoch").tag(7)
                                Text("Po 30 dňoch").tag(30)
                                Text("Po 90 dňoch").tag(90)
                            }
                            if !showAdvanced { AdvancedBadge() }
                        }
                        .disabled(!settings.webSigningSavesLocally)
                    }
                    if showAdvanced {
                        Button("Obnoviť služby macOS") {
                            finderMessage = FinderQuickActionService.refreshServicesCache()
                                ? "Registrácia služieb bola odoslaná systému macOS."
                                : "Registráciu služieb sa nepodarilo obnoviť."
                            quickAction = FinderQuickActionService.currentVisibility()
                        }
                    }
                } header: {
                    AdvancedSectionHeader()
                } footer: {
                    Text("Kôš sa týka iba kópií podpisov z prehliadača. Dokumenty podpísané v aplikácii zostávajú, kde ste ich uložili.")
                }
            }
        }
        .onAppear {
            agentStatus = WebBridgeAgentService.currentStatus()
            quickAction = FinderQuickActionService.currentVisibility()
        }
        .sheet(isPresented: $showFinderGuide) {
            FinderGuideSheet { showFinderGuide = false }
        }
    }

    private var quickActionText: String {
        switch quickAction {
        case .visible: "Zobrazená v kontextovej ponuke"
        case .hiddenInFinder: "Nainštalovaná, ale vo Findere vypnutá"
        case .notInstalled: "Nenainštalovaná"
        }
    }

    private func install() {
        finderMessage = FinderQuickActionService.installQuickAction()
            ? "Quick Action bola nainštalovaná do služieb Findera."
            : "Quick Action sa nepodarilo nainštalovať."
        quickAction = FinderQuickActionService.currentVisibility()
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

    /// The launchd agent the Safari extension reaches the app through; without it
    /// a portal never gets an answer.
    @ViewBuilder
    private var agentStatusRow: some View {
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
        case .legacyAgentOnly:
            Label("Podpisovanie zo Safari teraz ide cez staršie prepojenie z predchádzajúcej inštalácie, ktoré macOS po reštarte sám nespustí. Kliknite na Zaregistrovať.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
        case .refusedByMacOS(legacyAgentInstalled: true):
            InlineError(message: "macOS nové prepojenie so Safari nepustí, kým eviduje staré z predchádzajúcej inštalácie. Kliknite na Odstrániť staré prepojenie, reštartujte Mac a o pár minút kliknite na Zaregistrovať. Dovtedy podpisovanie zo Safari nepôjde.")
            HStack {
                Button("Odstrániť staré prepojenie") { agentStatus = WebBridgeAgentService.retireLegacyAgent() }
                Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
            }
        case .refusedByMacOS(legacyAgentInstalled: false):
            InlineError(message: "macOS registráciu prepojenia so Safari zatiaľ odmieta. Ak ste práve odstránili staré prepojenie, reštartujte Mac a o pár minút kliknite na Zaregistrovať. Skontrolujte tiež, či je Chevron7 (the Software s.r.o.) zapnutý v Systémové nastavenia → Všeobecné → Položky pri prihlásení a rozšírenia → Povoliť na pozadí.")
            HStack {
                Button("Otvoriť Položky pri prihlásení…") { WebBridgeAgentService.openLoginItemsSettings() }
                Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
            }
        case .legacyAgentRemoved:
            Label("Staré prepojenie je v Koši. Reštartujte Mac, otvorte Chevron7 a o pár minút kliknite na Zaregistrovať.",
                  systemImage: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            Button("Zaregistrovať") { agentStatus = WebBridgeAgentService.registerNow() }
        case .failed(let message):
            InlineError(message: "Prepojenie so Safari sa nepodarilo zaregistrovať: \(message)")
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
}

struct FinderGuideSheet: View {
    let onClose: () -> Void

    private let steps = [
        "Nainštalujte Chevron7 do priečinka Applications.",
        "Kliknite na Nainštalovať Quick Action. Chevron7 ju uloží do ~/Library/Services.",
        "Vo Findere otvorte Quick Actions → Customize… a zaškrtnite \(FinderQuickActionService.menuTitle).",
        "Označte jeden alebo viac PDF súborov.",
        "Kliknite pravým tlačidlom a zvoľte Quick Actions → \(FinderQuickActionService.menuTitle).",
        "Chevron7 vyberie dostupný podpisový certifikát, mandátny uprednostní. PIN alebo BOK zadáte iba počas podpisu.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Aktivácia vo Findere") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Label {
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "\(index + 1).circle.fill").foregroundStyle(.teal)
                        }
                    }
                }
                Section {
                    Text("Ak položka nie je ani v Customize…, ukončite a znova spustite Chevron7, v Rozšírených kliknite na Obnoviť služby macOS a reštartujte Finder. Workflow prijíma iba PDF súbory, nie ASiC-E kontajnery. PIN sa nikdy neukladá.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Hotovo") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding()
        }
        .frame(width: 520, height: 460)
    }
}
