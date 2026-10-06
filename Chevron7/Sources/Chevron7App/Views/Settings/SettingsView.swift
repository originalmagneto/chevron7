// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// Settings as System Settings lays them out: panes in a sidebar, Basic content always,
/// Advanced content behind one toggle at the bottom of the sidebar.
struct SettingsView: View {
    @Bindable var settingsStore: AppSettingsStore
    var waitForLearningWrites: @MainActor () async -> Void = {}
    @AppStorage("settings.showAdvanced") private var showAdvanced = false
    @AppStorage("settings.selectedPane") private var storedPane = ""
    @State private var selection: SettingsPane?

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                Toggle("Rozšírené nastavenia", isOn: $showAdvanced)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Zobrazí technické nastavenia v každej sekcii.")
            }
        } detail: {
            detail(for: selection ?? .profile)
        }
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            let controller = settingsStore.ezzkAccountController
            selection = SettingsPane.initial(
                stored: storedPane,
                ezzkConnected: EZZKConnection.isConnected(mode: controller.mode,
                                                          hasStoredCredentials: controller.hasStoredCredentials))
        }
        .onChange(of: selection) { _, pane in
            if let pane { storedPane = pane.rawValue }
        }
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .profile:
            ProfileSettingsPane(settingsStore: settingsStore)
        case .ezzk:
            EZZKSettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced)
        case .signing:
            SigningSettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced)
        case .mobile:
            MobileSettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced)
        case .browserFinder:
            BrowserFinderSettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced)
        case .ai:
            AISettingsPane(settingsStore: settingsStore, showAdvanced: showAdvanced,
                           waitForLearningWrites: waitForLearningWrites)
        case .general:
            GeneralSettingsPane(settingsStore: settingsStore)
        }
    }
}
