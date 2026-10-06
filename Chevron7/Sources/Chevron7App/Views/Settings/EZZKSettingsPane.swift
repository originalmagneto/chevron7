// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import SwiftUI

struct EZZKSettingsPane: View {
    @Bindable var settingsStore: AppSettingsStore
    let showAdvanced: Bool
    @State private var loginField = ""
    @State private var passwordField = ""
    @State private var connectError: String?
    @State private var isConnecting = false
    @State private var showConnectConfirmation = false
    @State private var lookupNumber = ""
    @State private var lookupResult: EZZKRecordLookup?
    @State private var lookupError: String?
    @State private var lookupInProgress = false
    @State private var testNumbers: [String] = []
    @State private var numbersError: String?
    @State private var numbersInProgress = false
    @State private var showNumbersConfirmation = false

    private var controller: EZZKAccountController { settingsStore.ezzkAccountController }
    private var isConnected: Bool {
        EZZKConnection.isConnected(mode: controller.mode, hasStoredCredentials: controller.hasStoredCredentials)
    }
    private var productionAllowed: Bool { controller.productionPolicy.allowsConsequentialCalls }

    var body: some View {
        let modeActive = SettingsAdvancedState.ezzkModeIsActive(settingsStore.settings)
        SettingsPaneForm(pane: .ezzk, pills: SettingsStatus.ezzk(
            mode: controller.mode, state: controller.state,
            hasStoredCredentials: controller.hasStoredCredentials, productionAllowed: productionAllowed)) {
            if showAdvanced || modeActive {
                modeSection(showsBadge: !showAdvanced)
            }
            accountSection
            if controller.mode == .test || isConnected {
                submissionSection
            }
            if showAdvanced {
                if !controller.isDemoMode {
                    lookupSection
                    numbersSection
                }
                migrationSection
            }
        }
        .onAppear { loginField = controller.storedLogin }
        .onChange(of: controller.mode) { _, _ in
            loginField = controller.storedLogin
            passwordField = ""
            lookupResult = nil
            lookupError = nil
            testNumbers = []
            numbersError = nil
        }
        .confirmationDialog("Pripojiť k ostrej evidencii EZZK?", isPresented: $showConnectConfirmation,
                            titleVisibility: .visible) {
            Button("Pripojiť") { connect() }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Od tejto chvíle sa evidenčné čísla aj záznamy o konverzii zapisujú do centrálnej evidencie s právnymi účinkami.")
        }
        .confirmationDialog("Vyžiadať evidenčné čísla z testovacieho EZZK?", isPresented: $showNumbersConfirmation,
                            titleVisibility: .visible) {
            Button("Vyžiadať čísla") { Task { await requestTestNumbers() } }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text("Testovacie EZZK vráti nespotrebované čísla osoby a podľa potreby pridelí nové.")
        }
    }

    // MARK: - Basic

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if isConnected {
                LabeledContent("Prihlasovacie meno", value: controller.storedLogin)
                LabeledContent("Heslo") {
                    Label("v Keychaine", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            } else {
                TextField("Prihlasovacie meno", text: $loginField, prompt: Text("z registračného e-mailu EZZK"))
                    .textContentType(.username)
                SecureField("Heslo", text: $passwordField,
                            prompt: Text(controller.hasStoredCredentials ? "uložené v Keychaine" : "heslo do EZZK"))
                    .textContentType(.password)
            }
            TextField("Názov osoby", text: $settingsStore.settings.ezzkPersonName, prompt: Text("presne ako v doložke"))
            TextField("IČO", text: $settingsStore.settings.ezzkICO, prompt: Text("IČO osoby"))
            stateRow
            accountButtons
            if let connectError {
                InlineError(message: connectError)
            } else if case .failed(let message) = controller.state {
                InlineError(message: message)
            }
        } header: {
            Label("Účet EZZK", systemImage: "person.badge.key")
        } footer: {
            Text("Heslo sa uloží iba do Keychainu tohto Macu, a to až po úspešnom overení v EZZK.")
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch controller.state {
        case .verifying:
            Label("Overuje sa v EZZK", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .signedIn(let accountName, let checkedAt):
            Label("Overené: \(accountName), \(checkedAt.formatted(date: .omitted, time: .shortened))",
                  systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .signedOut, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var accountButtons: some View {
        HStack {
            Spacer()
            if controller.mode == .test {
                if controller.hasStoredCredentials {
                    Button("Odhlásiť", role: .destructive) { signOut() }
                }
                Button("Prihlásiť a overiť") { signInInCurrentMode() }
                    .disabled(controller.state == .verifying || loginField.isEmpty || passwordField.isEmpty)
            } else if isConnected {
                Button("Odpojiť", role: .destructive) {
                    EZZKConnection.disconnect(store: settingsStore)
                    loginField = controller.storedLogin
                    passwordField = ""
                }
            } else {
                Button {
                    connectError = nil
                    showConnectConfirmation = true
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Pripojiť k EZZK", systemImage: "link")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isConnecting || loginField.isEmpty || passwordField.isEmpty)
            }
        }
    }

    private var submissionSection: some View {
        let status = submissionStatus
        return Section {
            Label(status.title, systemImage: status.symbol)
        } header: {
            Label("Odosielanie záznamov", systemImage: "arrow.up.doc")
        } footer: {
            Text(status.detail)
        }
    }

    private var submissionStatus: (title: String, symbol: String, detail: String) {
        switch controller.mode {
        case .demo:
            ("Lokálna simulácia", "desktopcomputer",
             "Podpísaný záznam o konverzii sa vytvorí, ale do EZZK sa neodošle.")
        case .test:
            ("Zapnuté automaticky", "checkmark.circle",
             "Po autorizácii sa záznam podpíše rovnakým PIN a odošle do testovacieho EZZK. Výsledok je v Registri konverzií.")
        case .production where productionAllowed:
            ("Zapnuté automaticky", "checkmark.circle",
             "Po autorizácii sa záznam podpíše rovnakým PIN a odošle do EZZK. Čakajúce záznamy sa overujú každých päť minút; výsledok je v Registri konverzií.")
        case .production:
            ("Zamknuté", "lock",
             "Pridelenie čísla aj odoslanie záznamu sú v tejto verzii zamknuté.")
        }
    }

    // MARK: - Advanced

    private func modeSection(showsBadge: Bool) -> some View {
        Section {
            Picker("Prostredie", selection: Binding(
                get: { controller.mode },
                set: { newMode in
                    settingsStore.settings.ezzkMode = newMode
                    controller.setMode(newMode)
                })) {
                ForEach(AppSettings.EZZKMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(controller.state == .verifying || lookupInProgress || numbersInProgress || isConnecting)
            if let environment = controller.environment {
                LabeledContent("Prihlásenie") { endpoint(environment.soapLoginURL.absoluteString) }
                LabeledContent("Služba") { endpoint(environment.soapServiceURL.absoluteString) }
            }
        } header: {
            HStack {
                AdvancedSectionHeader(title: "Prostredie EZZK")
                if showsBadge { AdvancedBadge() }
            }
        } footer: {
            Text(modeExplanation)
        }
    }

    private var modeExplanation: String {
        switch controller.mode {
        case .demo: "Skúšobný režim používa iba lokálnu simuláciu, nič sa neposiela do EZZK."
        case .test: "Testovacia evidencia EZZK na overenie integrácie. Čísla ani záznamy nemajú právne účinky."
        case .production where productionAllowed:
            "Ostrá evidencia: čísla aj záznamy majú právne účinky. Každá konverzia sa zapíše do centrálnej evidencie."
        case .production: "Ostrá evidencia. Zatiaľ iba overenie prihlásenia, čas servera a vyhľadanie záznamu."
        }
    }

    private func endpoint(_ value: String) -> some View {
        Text(value)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    private var lookupSection: some View {
        Section {
            HStack {
                TextField("Evidenčné číslo", text: $lookupNumber)
                    .onSubmit { lookUpRecord() }
                Button("Vyhľadať") { lookUpRecord() }
                    .disabled(lookupInProgress || lookupNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if lookupInProgress {
                ProgressView().controlSize(.small)
            } else if let lookupError {
                InlineError(message: lookupError)
            } else if let lookup = lookupResult {
                if !lookup.isProcessed {
                    Label("Záznam je evidovaný, ale ešte nespracovaný.", systemImage: "hourglass")
                        .foregroundStyle(.orange)
                }
                if let info = lookup.info {
                    infoRow("Číslo", info.evidenceNumber)
                    infoRow("Konverzia", info.executionTime?.formatted(date: .abbreviated, time: .standard))
                    infoRow("Prijaté", info.receiptTime?.formatted(date: .abbreviated, time: .standard))
                    infoRow("Osoba", info.personName)
                    infoRow("Pôvodný", documentSummary(info.originalDocumentName, info.originalDocumentFormat,
                                                       info.originalDocumentSheets))
                    infoRow("Nový", documentSummary(info.newDocumentName, info.newDocumentFormat,
                                                    info.newDocumentSheets))
                }
            }
        } header: {
            AdvancedSectionHeader(title: "Overenie záznamu")
        } footer: {
            Text("Overenie nepotrebuje prihlásenie a v EZZK nič nemení.")
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) { Text(value).textSelection(.enabled) }
        }
    }

    private func documentSummary(_ name: String?, _ format: String?, _ sheets: Int?) -> String {
        [name, format, sheets.map { "listov: \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    private var numbersSection: some View {
        Section {
            if controller.mode == .production {
                // "Vyžiadať čísla" stays test only whatever the production policy: a production
                // number no record uses lapses at midnight and breaks the 24-hour reporting duty.
                Label(productionAllowed
                      ? "V ostrej evidencii sa evidenčné číslo získava iba v zaručenej konverzii."
                      : "V ostrej evidencii je pridelenie evidenčného čísla zatiaľ zamknuté, aj v zaručenej konverzii.",
                      systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Vyžiadať čísla") { showNumbersConfirmation = true }
                        .disabled(numbersInProgress || !controller.hasStoredCredentials)
                    if numbersInProgress { ProgressView().controlSize(.small) }
                }
                if let numbersError {
                    InlineError(message: numbersError)
                } else if !testNumbers.isEmpty {
                    Text(testNumbers.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            AdvancedSectionHeader(title: "Evidenčné čísla")
        } footer: {
            if controller.mode != .production {
                Text("Vyžaduje uložené prihlásenie, názov osoby a IČO.")
            }
        }
    }

    private var migrationSection: some View {
        Section {
            TextField("Notifikačný e-mail", text: $settingsStore.settings.ezzkNotificationEmail,
                      prompt: Text("advokat@kancelaria.sk"))
            TextField("Adresa eDesk", text: $settingsStore.settings.ezzkEdeskAddress,
                      prompt: Text("elektronická schránka"))
        } header: {
            AdvancedSectionHeader(title: "Kontaktné údaje pre migráciu")
        } footer: {
            Text("Slúžia iba na migráciu historických záznamov. Na prihlásenie sa nepoužívajú.")
        }
    }

    // MARK: - Actions

    private func connect() {
        let login = loginField
        let password = passwordField
        isConnecting = true
        connectError = nil
        Task {
            let result = await EZZKConnection.connect(store: settingsStore, login: login, password: password)
            isConnecting = false
            switch result {
            case .connected:
                passwordField = ""
            case .failed(let message):
                connectError = message
            }
        }
    }

    private func signInInCurrentMode() {
        let login = loginField
        let password = passwordField
        Task {
            await controller.signIn(login: login, password: password)
            if case .signedIn = controller.state { passwordField = "" }
        }
    }

    private func signOut() {
        controller.signOut()
        // A failed sign-out keeps the stored login, so keep showing it.
        loginField = controller.storedLogin
        passwordField = ""
    }

    private func lookUpRecord() {
        let number = lookupNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, !lookupInProgress else { return }
        let requestedMode = controller.mode
        lookupInProgress = true
        lookupError = nil
        lookupResult = nil
        Task {
            defer { lookupInProgress = false }
            do {
                let result = try await controller.lookUp(evidenceNumber: number)
                if controller.mode == requestedMode { lookupResult = result }
            } catch {
                if controller.mode == requestedMode { lookupError = EZZKAccountController.message(for: error) }
            }
        }
    }

    private func requestTestNumbers() async {
        let requestedMode = controller.mode
        numbersInProgress = true
        numbersError = nil
        defer { numbersInProgress = false }
        do {
            let numbers = try await settingsStore.requestTestNumbersIntoPool()
            if controller.mode == requestedMode { testNumbers = numbers }
        } catch {
            if controller.mode == requestedMode { numbersError = EZZKAccountController.message(for: error) }
        }
    }
}
