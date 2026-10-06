// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// The Basic EZZK flow: one account on the live register, no environment picker.
@MainActor
enum EZZKConnection {
    enum Result: Equatable {
        case connected
        case failed(String)
    }

    static func isConnected(mode: AppSettings.EZZKMode, hasStoredCredentials: Bool) -> Bool {
        mode == .production && hasStoredCredentials
    }

    /// Switches to the live register and signs in. A refused login restores the mode the
    /// person had, so a typo never leaves them on production without an account.
    static func connect(store: AppSettingsStore, login: String, password: String) async -> Result {
        let controller = store.ezzkAccountController
        let previous = controller.mode
        store.settings.ezzkMode = .production
        controller.setMode(.production)
        await controller.signIn(login: login, password: password)
        if case .signedIn = controller.state { return .connected }
        let message: String = if case .failed(let text) = controller.state {
            text
        } else {
            "Pripojenie k EZZK sa nepodarilo."
        }
        store.settings.ezzkMode = previous
        controller.setMode(previous)
        return .failed(message)
    }

    /// Drops the saved login and keeps the live register selected: a conversion then
    /// stops with a login error instead of quietly running without legal effect.
    static func disconnect(store: AppSettingsStore) {
        store.ezzkAccountController.signOut()
    }
}
