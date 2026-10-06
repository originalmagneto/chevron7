// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI

/// One entry of the Settings sidebar, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case profile, ezzk, signing, mobile, browserFinder, ai, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profil advokáta"
        case .ezzk: "EZZK"
        case .signing: "Podpisovanie"
        case .mobile: "Mobil a eIdentita"
        case .browserFinder: "Prehliadač a Finder"
        case .ai: "AI a učenie"
        case .general: "Všeobecné"
        }
    }

    var subtitle: String {
        switch self {
        case .profile: "Údaje advokáta do doložky a záznamu o konverzii"
        case .ezzk: "Evidencia zaručených konverzií"
        case .signing: "Časová pečiatka a formát PDF/A"
        case .mobile: "Podpis občianskym preukazom cez iPhone a eIdentitu"
        case .browserFinder: "Podpisovanie zo Safari a z kontextovej ponuky Findera"
        case .ai: "Detekcia bezpečnostných prvkov a učenie na tomto Macu"
        case .general: "Správanie aplikácie"
        }
    }

    var symbol: String {
        switch self {
        case .profile: "person.text.rectangle.fill"
        case .ezzk: "building.columns.fill"
        case .signing: "signature"
        case .mobile: "iphone.radiowaves.left.and.right"
        case .browserFinder: "safari.fill"
        case .ai: "eye.fill"
        case .general: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .profile: .blue
        case .ezzk: .green
        case .signing: .indigo
        case .mobile: .orange
        case .browserFinder: .teal
        case .ai: .purple
        case .general: .gray
        }
    }

    /// The remembered pane, else EZZK while it is not connected (the one step every
    /// advocate needs), else the profile.
    static func initial(stored: String, ezzkConnected: Bool) -> SettingsPane {
        if let pane = SettingsPane(rawValue: stored) { return pane }
        return ezzkConnected ? .profile : .ezzk
    }
}
