// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import CryptoKit
import SwiftUI

enum EidentitaKey {
    /// A key in the Keychain that decodes; the display is derived from it, never regenerated.
    static func isStored() -> Bool {
        guard let raw = try? AGPKeyStore().loadPrivateKey() else { return false }
        return (try? P256.Signing.PrivateKey(rawRepresentation: raw)) != nil
    }
}

/// The portal-side eIdentita setup, kept out of the pane so the pane shows only status.
struct EidentitaSetupSheet: View {
    @Bindable var settingsStore: AppSettingsStore
    let onClose: () -> Void
    @State private var keyStored = false
    @State private var publicPEM = ""
    @State private var error: String?
    @State private var busy = false
    @State private var verified = false

    /// The portal-side setup, as the Autogram Portal's organization settings show it
    /// since its tenants (2026-09-30).
    static let steps = [
        "Prihláste sa na portál Autogram z poľa Portál a otvorte Nastavenia. Predvolený je testovací portál, kde Slovensko.Digital dnes sprístupňuje API; ostrý portál je agp.slovensko.digital.",
        "Ak pod poľom „Verejný kľúč API tokenu“ stojí, že API prístup nie je zapnutý, požiadajte Slovensko.Digital o jeho zapnutie pre vašu organizáciu. Kľúč vkladá vlastník organizácie.",
        "Tu kliknite na „Vygenerovať kľúč“, skopírujte verejný kľúč, vložte ho na portáli do poľa „Verejný kľúč API tokenu“ a kliknite na Uložiť.",
        "Do poľa ID organizácie prepíšte číslo z vety pod tým poľom na portáli: „V tokene použite sub = …“.",
        "Kliknite na „Overiť“. Pri podpise potom vyberte Podpísať mobilom a eIdentitu.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "person.badge.key.fill", tint: .orange, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nastaviť eIdentitu").font(.title3.weight(.semibold))
                            Text("Podpis cez portál Autogram: QR kód z portálu naskenujete aplikáciou eIDENTITA.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Postup") {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        Label {
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "\(index + 1).circle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                Section("Portál") {
                    TextField("Portál", text: $settingsStore.settings.agpBaseURL,
                              prompt: Text(AGPClient.defaultBaseURL.absoluteString))
                    TextField("ID organizácie", text: $settingsStore.settings.agpUserID,
                              prompt: Text("číslo „sub“ z Nastavení na portáli"))
                }
                Section {
                    HStack {
                        Button(keyStored ? "Vygenerovať nový kľúč" : "Vygenerovať kľúč") { generateKey() }
                        Button("Overiť") { verify() }
                            .disabled(!keyStored)
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        if verified {
                            Label("Overené", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }
                    .disabled(busy)
                    if !publicPEM.isEmpty {
                        Text(publicPEM)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(publicPEM, forType: .string)
                        } label: {
                            Label("Skopírovať verejný kľúč", systemImage: "doc.on.doc")
                        }
                    }
                    if let error { InlineError(message: error) }
                } header: {
                    Text("Kľúč")
                } footer: {
                    Text("Súkromný kľúč žije iba v Keychaine tohto Macu. Token sa razí nanovo pre každý request a platí pár minút.")
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
        .frame(width: 560, height: 620)
        .onAppear { loadKey() }
    }

    private func loadKey() {
        if let raw = try? AGPKeyStore().loadPrivateKey(),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            keyStored = true
            publicPEM = AGPTokenMinter.spkiPEM(publicKey: key.publicKey)
        } else {
            keyStored = false
            publicPEM = ""
        }
    }

    private func generateKey() {
        busy = true
        error = nil
        verified = false
        Task {
            do {
                let key = AGPTokenMinter.generateKey()
                try AGPKeyStore().savePrivateKey(Data(key.rawRepresentation))
                publicPEM = AGPTokenMinter.spkiPEM(publicKey: key.publicKey)
                keyStored = true
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func verify() {
        busy = true
        error = nil
        verified = false
        Task {
            do {
                let client = try AGPClient.configured(
                    userID: settingsStore.settings.agpUserID,
                    baseURL: settingsStore.settings.agpBaseURLValue,
                    keyStore: AGPKeyStore())
                guard try await client.verifyToken() else { throw AGPError.invalidResponse }
                verified = true
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
