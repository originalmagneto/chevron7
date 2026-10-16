// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

/// The advocate's qualified validation services (vyhláška 70/2021 § 3 ods. 4) for E→E
/// conversions in Ostrá evidencia. v1 keeps name, provider and portal; the sealed report is
/// imported at verification, so no credentials are stored.
struct QualifiedValidationSection: View {
    @Bindable var settingsStore: AppSettingsStore
    let showsBadge: Bool
    @State private var isAdding = false

    static let footer = "Pri zaručenej konverzii elektronického dokumentu v ostrej evidencii treba podpisy klienta overiť kvalifikovanou službou validácie (§ 3 ods. 4 vyhlášky č. 70/2021 Z. z.). Službu si zmluvne zabezpečte u poskytovateľa (napríklad Disig, Ardaco alebo NFQES) a jej výsledok potom pripojíte pri overení."

    var body: some View {
        Section {
            ForEach(settingsStore.settings.qualifiedValidationServices) { service in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name)
                        Text(service.portalURL.map { "\(service.provider) · \($0.host() ?? $0.absoluteString)" } ?? service.provider)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        settingsStore.settings.qualifiedValidationServices.removeAll { $0.id == service.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Odstrániť službu")
                    .accessibilityLabel("Odstrániť službu \(service.name)")
                }
            }
            Button("Pridať službu…") { isAdding = true }
        } header: {
            HStack {
                AdvancedSectionHeader(title: "Kvalifikovaná služba validácie")
                if showsBadge { AdvancedBadge() }
            }
        } footer: {
            Text(Self.footer)
        }
        .sheet(isPresented: $isAdding) {
            QualifiedValidationServiceSheet { service in
                settingsStore.settings.qualifiedValidationServices.append(service)
            }
        }
    }
}

struct QualifiedValidationServiceSheet: View {
    let onAdd: (QualifiedValidationService) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var provider = ""
    @State private var portal = ""

    private var portalURL: URL? {
        let trimmed = portal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host() != nil else {
            return nil
        }
        return url
    }

    private var portalIsInvalid: Bool {
        !portal.trimmingCharacters(in: .whitespaces).isEmpty && portalURL == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Názov", text: $name, prompt: Text("napr. Validácia Disig"))
                TextField("Poskytovateľ", text: $provider, prompt: Text("napr. Disig, a.s."))
                TextField("Adresa portálu (nepovinné)", text: $portal, prompt: Text("https://"))
                if portalIsInvalid {
                    Text("Zadajte adresu začínajúcu https://").font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Zrušiť", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pridať") {
                    onAdd(QualifiedValidationService(name: name.trimmingCharacters(in: .whitespaces),
                                                     provider: provider.trimmingCharacters(in: .whitespaces),
                                                     portalURL: portalURL))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || provider.trimmingCharacters(in: .whitespaces).isEmpty || portalIsInvalid)
            }
            .padding()
        }
        .frame(width: 420)
    }
}
