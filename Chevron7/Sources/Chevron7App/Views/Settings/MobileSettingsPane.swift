// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

struct MobileSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    @State private var keyStored = false
    @State private var showSetup = false

    var body: some View {
        let settings = settingsStore.settings
        let avmActive = SettingsAdvancedState.avmServerIsActive(settings)
        let portalActive = SettingsAdvancedState.agpPortalIsActive(settings)
        let pills = SettingsStatus.mobile(mobileSigningEnabled: settings.mobileSigningEnabled,
                                          eidentitaKeyStored: keyStored, eidentitaUserID: settings.agpUserID)
        SettingsPaneForm(pane: .mobile, pills: pills) {
            Section {
                Toggle("Ponúkať podpis občianskym preukazom s NFC cez iPhone",
                       isOn: $settingsStore.settings.mobileSigningEnabled)
            } header: {
                Label("Autogram v mobile", systemImage: "iphone.gen3.radiowaves.left.and.right")
            } footer: {
                Text("Dokument sa zašifruje kľúčom, ktorý pozná len tento Mac, nahrá sa na server Slovensko.Digital a po naskenovaní QR kódu ho podpíšete v aplikácii Autogram v mobile. Server dokument zmaže do 24 hodín.")
            }

            Section {
                LabeledContent("Stav") {
                    if let eidentita = pills.last { StatusPill(model: eidentita) }
                }
                HStack {
                    Spacer()
                    Button("Nastaviť eIdentitu…") { showSetup = true }
                        .disabled(!settings.mobileSigningEnabled)
                }
            } header: {
                Label("eIdentita (štátna aplikácia)", systemImage: "person.badge.key")
            } footer: {
                Text("Dokument sa nahrá do vášho balíka na portáli Autogram, QR kód naskenujete aplikáciou eIDENTITA a podpísaný dokument sa stiahne späť.")
            }

            if showAdvanced || avmActive || portalActive {
                Section {
                    if showAdvanced || avmActive {
                        HStack {
                            TextField("Server Autogram v mobile", text: $settingsStore.settings.avmBaseURL,
                                      prompt: Text(AVMClient.publicBaseURL.absoluteString))
                            if !showAdvanced { AdvancedBadge() }
                        }
                    }
                    if showAdvanced || portalActive {
                        HStack {
                            TextField("Portál eIdentity", text: $settingsStore.settings.agpBaseURL,
                                      prompt: Text(AGPClient.defaultBaseURL.absoluteString))
                            if !showAdvanced { AdvancedBadge() }
                        }
                    }
                    if showAdvanced, keyStored {
                        Button("Odstrániť kľúč eIdentity", role: .destructive) {
                            try? AGPKeyStore().delete()
                            keyStored = EidentitaKey.isStored()
                        }
                    }
                } header: {
                    AdvancedSectionHeader()
                } footer: {
                    Text("Aplikácia Autogram v mobile otvára len odkazy z autogram.slovensko.digital. Iný server je určený len na testovanie.")
                }
            }
        }
        .onAppear { keyStored = EidentitaKey.isStored() }
        .sheet(isPresented: $showSetup, onDismiss: { keyStored = EidentitaKey.isStored() }) {
            EidentitaSetupSheet(settingsStore: settingsStore) { showSetup = false }
        }
    }
}
