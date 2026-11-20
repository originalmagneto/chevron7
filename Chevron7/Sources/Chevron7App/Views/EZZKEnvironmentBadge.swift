// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

/// The EZZK environment a conversion ran in, said as text so a test conversion (no legal
/// effect) is never mistaken for a real one. Pure values, tested without SwiftUI.
enum EZZKEnvironmentBadgeModel {
    enum Form: Equatable {
        /// Sidebar rows: "Skúšobný", "Test"; production says nothing.
        case short
        /// Lists such as the Register: the full name; production says nothing.
        case list
        /// Where the environment is the subject (the ZaKo header): production is named too.
        case subject
    }

    enum Tone: Equatable {
        case neutral
        case attention
        case live
    }

    /// The badge text, or nil when the form shows nothing for the mode (production in a list,
    /// a row written before EZZK modes were stored).
    static func text(for mode: AppSettings.EZZKMode?, form: Form) -> String? {
        guard let mode else { return nil }
        switch (mode, form) {
        case (.demo, .short): return "Skúšobný"
        case (.test, .short): return "Test"
        case (.demo, _): return "Skúšobný režim"
        case (.test, _): return "Testovacia evidencia"
        case (.production, .subject): return "Ostrá evidencia"
        case (.production, _): return nil
        }
    }

    static func tone(for mode: AppSettings.EZZKMode) -> Tone {
        switch mode {
        case .demo: .neutral
        case .test: .attention
        case .production: .live
        }
    }

    /// What VoiceOver reads: the environment in full and what it means.
    static func accessibilityLabel(for mode: AppSettings.EZZKMode) -> String {
        switch mode {
        case .demo: "Prostredie EZZK: Skúšobný režim, lokálne, mimo EZZK"
        case .test: "Prostredie EZZK: Testovacia evidencia, bez právnych účinkov"
        case .production: "Prostredie EZZK: Ostrá evidencia"
        }
    }

    static func help(for mode: AppSettings.EZZKMode) -> String {
        switch mode {
        case .demo: "Konverzia v skúšobnom režime: lokálna simulácia, do EZZK sa neodoslala."
        case .test: "Konverzia v Testovacej evidencii EZZK: nemá právne účinky."
        case .production: "Konverzia v Ostrej evidencii EZZK."
        }
    }
}

/// A tinted capsule with text, in the Settings pill style. Draws nothing when the form says
/// nothing for the mode.
struct EZZKEnvironmentBadge: View {
    let mode: AppSettings.EZZKMode?
    var form: EZZKEnvironmentBadgeModel.Form = .list

    var body: some View {
        if let mode, let text = EZZKEnvironmentBadgeModel.text(for: mode, form: form) {
            let tint = Self.color(for: EZZKEnvironmentBadgeModel.tone(for: mode))
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.15), in: Capsule())
                .lineLimit(1)
                .fixedSize()
                .help(EZZKEnvironmentBadgeModel.help(for: mode))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(EZZKEnvironmentBadgeModel.accessibilityLabel(for: mode))
        }
    }

    static func color(for tone: EZZKEnvironmentBadgeModel.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .attention: .orange
        case .live: .blue
        }
    }
}
