// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

extension AdvocateProfile {
    var displayName: String {
        fullName.isEmpty ? officeName : fullName
    }
}

struct ProfileSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    @State private var editingID: UUID?
    @State private var profileToDelete: UUID?

    private var profiles: [AdvocateProfile] { settingsStore.settings.profiles }
    private var activeID: UUID? { settingsStore.settings.activeProfileID }

    var body: some View {
        SettingsPaneForm(pane: .profile, pills: SettingsStatus.profile(settingsStore.settings)) {
            Section("Profily") {
                if profiles.isEmpty {
                    Text("Pridajte profil s údajmi advokáta. Použije sa v doložke aj v zázname o konverzii.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
                HStack(spacing: 8) {
                    Button { addProfile() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Pridať profil")
                    Button {
                        profileToDelete = editingID
                    } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Odstrániť profil")
                        .disabled(editingID == nil || profiles.count < 2)
                    Spacer()
                    if let editingID, editingID != activeID {
                        Button("Nastaviť ako aktívny") {
                            settingsStore.settings.activeProfileID = editingID
                        }
                    }
                }
                .buttonStyle(.borderless)
            }

            if let index = profiles.firstIndex(where: { $0.id == editingID }) {
                Section("Údaje profilu") {
                    TextField("Meno a priezvisko", text: $settingsStore.settings.profiles[index].fullName,
                              prompt: Text("JUDr. Meno Priezvisko"))
                    TextField("Funkcia", text: $settingsStore.settings.profiles[index].position,
                              prompt: Text("advokát"))
                    TextField("Evidenčné číslo SAK", text: $settingsStore.settings.profiles[index].registrationNumber,
                              prompt: Text("1234"))
                    TextField("IČO kancelárie", text: $settingsStore.settings.profiles[index].ico,
                              prompt: Text("IČO"))
                    TextField("Názov kancelárie", text: $settingsStore.settings.profiles[index].officeName,
                              prompt: Text("Advokátska kancelária…"))
                    TextField("Adresa kancelárie", text: $settingsStore.settings.profiles[index].officeAddress,
                              prompt: Text("Ulica, PSČ a mesto"))
                    Toggle("Právnická osoba (kancelária)", isOn: $settingsStore.settings.profiles[index].isLegalEntity)
                }
            }
        }
        .onAppear { editingID = editingID ?? activeID ?? profiles.first?.id }
        .confirmationDialog("Naozaj chcete odstrániť tento profil?",
                            isPresented: Binding(get: { profileToDelete != nil },
                                                 set: { if !$0 { profileToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Odstrániť profil", role: .destructive) { deleteProfile() }
            Button("Zrušiť", role: .cancel) { profileToDelete = nil }
        } message: {
            Text("Profil a jeho údaje budú odstránené z tejto aplikácie.")
        }
    }

    private func profileRow(_ profile: AdvocateProfile) -> some View {
        let isActive = profile.id == activeID
        let isEditing = profile.id == editingID
        return Button {
            editingID = profile.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isEditing ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName.isEmpty ? "Nový profil" : profile.displayName)
                    if !profile.officeName.isEmpty, profile.officeName != profile.displayName {
                        Text(profile.officeName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isActive {
                    StatusPill(model: StatusPillModel(tone: .ok, text: "Aktívny"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isEditing ? .isSelected : [])
    }

    private func addProfile() {
        let profile = AdvocateProfile()
        settingsStore.settings.profiles.append(profile)
        if settingsStore.settings.activeProfileID == nil {
            settingsStore.settings.activeProfileID = profile.id
        }
        editingID = profile.id
    }

    private func deleteProfile() {
        guard let id = profileToDelete else { return }
        settingsStore.settings.profiles.removeAll { $0.id == id }
        if settingsStore.settings.activeProfileID == id {
            settingsStore.settings.activeProfileID = settingsStore.settings.profiles.first?.id
        }
        editingID = settingsStore.settings.activeProfileID
        profileToDelete = nil
    }
}
