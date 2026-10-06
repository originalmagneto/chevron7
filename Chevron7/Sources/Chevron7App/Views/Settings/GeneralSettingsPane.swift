// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore

    var body: some View {
        SettingsPaneForm(pane: .general, pills: []) {
            Section {
                Toggle("Pamätať naposledy otvorené dokumenty", isOn: $settingsStore.settings.retainRecentDocuments)
            } header: {
                Label("Naposledy otvorené dokumenty", systemImage: "clock.arrow.circlepath")
            } footer: {
                Text("Uloží najviac osem bezpečných bookmarkov pre rýchly návrat po reštarte. Obsah dokumentov sa do zoznamu neukladá.")
            }
        }
    }
}
