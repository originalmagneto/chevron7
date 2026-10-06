// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// One status capsule in a Settings pane header.
struct StatusPillModel: Equatable {
    enum Tone: Equatable {
        /// Works.
        case ok
        /// Needs the person to act.
        case attention
        /// Switched off.
        case off
        /// Neutral information.
        case info
    }

    let tone: Tone
    let text: String
}

/// Header pills of each pane, read from state that already exists. Nothing here
/// talks to a service.
enum SettingsStatus {
    static func profile(_ settings: AppSettings) -> [StatusPillModel] {
        guard let active = settings.profiles.first(where: { $0.id == settings.activeProfileID }) else {
            return [StatusPillModel(tone: .attention, text: "Žiadny profil")]
        }
        let name = active.displayName.isEmpty ? "Nový profil" : active.displayName
        return [StatusPillModel(tone: .info, text: name)]
    }

    static func ezzk(mode: AppSettings.EZZKMode, state: EZZKAccountController.State,
                     hasStoredCredentials: Bool, productionAllowed: Bool) -> [StatusPillModel] {
        var pills: [StatusPillModel]
        switch mode {
        case .demo:
            pills = [StatusPillModel(tone: .info, text: "Skúšobný režim, bez zápisu do evidencie")]
        case .test:
            pills = [StatusPillModel(tone: .info, text: "Testovacia evidencia"),
                     hasStoredCredentials
                        ? StatusPillModel(tone: .ok, text: "Prihlásené")
                        : StatusPillModel(tone: .attention, text: "Neprihlásené")]
        case .production:
            if hasStoredCredentials {
                pills = [StatusPillModel(tone: .ok, text: "Pripojené"),
                         productionAllowed
                            ? StatusPillModel(tone: .ok, text: "Odosielanie zapnuté")
                            : StatusPillModel(tone: .off, text: "Odosielanie zamknuté")]
            } else {
                pills = [StatusPillModel(tone: .attention, text: "Nepripojené")]
            }
        }
        if case .failed = state {
            pills.append(StatusPillModel(tone: .attention, text: "Prihlásenie zlyhalo"))
        }
        return pills
    }

    static func signing(_ settings: AppSettings) -> [StatusPillModel] {
        let active = settings.activeTSA
        var pills = [StatusPillModel(tone: .info, text: active.name)]
        if TimestampAuthority.qualifiedURLs.map(\.absoluteString).contains(active.url) {
            pills.append(StatusPillModel(tone: .ok, text: "Kvalifikovaná"))
        } else if settings.activeTSAQualificationIsUnverified {
            pills.append(StatusPillModel(tone: .attention, text: "Kvalifikácia neoverená"))
        }
        return pills
    }

    static func mobile(mobileSigningEnabled: Bool, eidentitaKeyStored: Bool,
                       eidentitaUserID: String) -> [StatusPillModel] {
        let phone = mobileSigningEnabled
            ? StatusPillModel(tone: .ok, text: "Podpis mobilom zapnutý")
            : StatusPillModel(tone: .off, text: "Podpis mobilom vypnutý")
        let hasUserID = !eidentitaUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let eidentita: StatusPillModel = switch (eidentitaKeyStored, hasUserID) {
        case (true, true): StatusPillModel(tone: .ok, text: "eIdentita pripravená")
        case (false, false): StatusPillModel(tone: .off, text: "eIdentita nenastavená")
        default: StatusPillModel(tone: .attention, text: "eIdentita nedokončená")
        }
        return [phone, eidentita]
    }

    static func browserFinder(agent: WebBridgeAgentService.Status,
                              quickAction: QuickActionVisibility) -> [StatusPillModel] {
        let safari: StatusPillModel = switch agent {
        case .enabled: StatusPillModel(tone: .ok, text: "Safari prepojené")
        case .unsignedBuild: StatusPillModel(tone: .off, text: "Safari: vývojárska zostava")
        default: StatusPillModel(tone: .attention, text: "Safari nie je prepojené")
        }
        let finder: StatusPillModel = switch quickAction {
        case .visible: StatusPillModel(tone: .ok, text: "Quick Action vo Findere")
        case .hiddenInFinder: StatusPillModel(tone: .attention, text: "Quick Action skrytá vo Findere")
        case .notInstalled: StatusPillModel(tone: .attention, text: "Quick Action nenainštalovaná")
        }
        return [safari, finder]
    }

    static func ai(mode: AppSettings.AIMode, reviewedPages: Int?) -> [StatusPillModel] {
        let provider: StatusPillModel = switch mode {
        case .builtInOnDevice: StatusPillModel(tone: .ok, text: "Interný režim")
        case .disabled: StatusPillModel(tone: .off, text: "AI vypnutá")
        case .omlxLocal: StatusPillModel(tone: .info, text: "oMLX")
        case .ollamaLocal: StatusPillModel(tone: .info, text: "Ollama")
        case .customAPIKey: StatusPillModel(tone: .info, text: "Vlastné API")
        }
        guard let reviewedPages else { return [provider] }
        return [provider, StatusPillModel(
            tone: .info,
            text: "Skontrolované strany: \(reviewedPages) z \(DetectorTrainingReadiness.firstRunPages)")]
    }
}
