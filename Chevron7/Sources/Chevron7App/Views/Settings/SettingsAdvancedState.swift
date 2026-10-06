// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// Whether an Advanced setting holds a value other than its default. Such a setting
/// stays visible even with Advanced off, so no hidden value changes signing or EZZK.
enum SettingsAdvancedState {
    static func ezzkModeIsActive(_ settings: AppSettings) -> Bool {
        settings.ezzkMode == .test
    }

    static func customTSAIsActive(_ settings: AppSettings) -> Bool {
        settings.customTSAServers.contains(settings.selectedTSAURL)
    }

    static func avmServerIsActive(_ settings: AppSettings) -> Bool {
        trimmed(settings.avmBaseURL) != AVMClient.publicBaseURL.absoluteString
    }

    static func agpPortalIsActive(_ settings: AppSettings) -> Bool {
        trimmed(settings.agpBaseURL) != AGPClient.defaultBaseURL.absoluteString
    }

    static func webSigningFolderIsActive(_ settings: AppSettings) -> Bool {
        !trimmed(settings.webSigningOutputPath).isEmpty
    }

    static func webSigningRetentionIsActive(_ settings: AppSettings) -> Bool {
        settings.webSigningRetentionDays != 0
    }

    static func aiProviderIsActive(_ settings: AppSettings) -> Bool {
        switch settings.aiMode {
        case .omlxLocal, .ollamaLocal, .customAPIKey: true
        case .builtInOnDevice, .disabled: false
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
