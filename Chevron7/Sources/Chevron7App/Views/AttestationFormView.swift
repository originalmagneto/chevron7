// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

struct AttestationFormView: View {
    @Bindable var store: ZakoSessionStore
    @State private var savedTemplateHint = false
    @State private var showingLivePreview = true
    @State private var availableWidth: CGFloat = .infinity

    /// The preview needs room next to the form; in a narrow window it steps aside.
    private var previewFits: Bool {
        MacOS27Layout.showsClausePreview(availableWidth: availableWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Measures the width offered to this step. The split view itself cannot:
            // with both panes at their minimums it reports its own, larger width.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            // A plain HStack, not HSplitView: the AppKit split view kept its panes' widths and
            // would not let the detail column narrow, which clipped the window on both sides.
            HStack(spacing: 0) {
                ScrollView {
                    formContent
                        .padding(18)
                }
                .frame(minWidth: MacOS27Layout.clauseFormMinimumWidth, maxWidth: .infinity)

                // The pane draws its own leading hairline.
                if showingLivePreview, previewFits {
                    liveClausePreviewPane
                        .frame(minWidth: MacOS27Layout.clausePreviewMinimumWidth, idealWidth: 380, maxWidth: 440)
                }
            }

            StickyActionBar {
                Button {
                    store.step = .analysis
                } label: {
                    Label("Späť na analýzu", systemImage: "chevron.left")
                }
                .controlSize(.large)

                Spacer()

                Button {
                    showingLivePreview.toggle()
                } label: {
                    Label(showingLivePreview && previewFits ? "Skryť náhľad" : "Živý náhľad doložky", systemImage: "sidebar.right")
                }
                .controlSize(.large)
                .disabled(!previewFits)
                .help(previewFits ? "" : "Na živý náhľad je okno príliš úzke. Rozšírte ho.")

                Button {
                    store.recomputePreflight()
                    guard !store.hasUnresolvedPreflightErrors else { return }
                    store.step = .authorize
                    Task { await store.refreshIdentities() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Pokračovať na autorizáciu")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.fetchingEvidenceNumber || store.hasUnresolvedPreflightErrors)
                .keyboardShortcut(.defaultAction)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingLivePreview.toggle()
                } label: {
                    Label("Živý náhľad doložky", systemImage: "sidebar.trailing")
                }
                .disabled(!previewFits)
                .help(!previewFits ? "Na živý náhľad je okno príliš úzke. Rozšírte ho."
                      : showingLivePreview ? "Skryť živý náhľad doložky" : "Zobraziť živý náhľad doložky")
            }
        }
        .onChange(of: store.attestation) { _, _ in
            store.recomputePreflight()
        }
        .onChange(of: store.securityElements) { _, _ in
            store.recomputePreflight()
        }
        .onChange(of: store.effectiveSheetCount) { _, _ in
            store.recomputePreflight()
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Osvedčovacia doložka zaručenej konverzie", systemImage: "building.columns.fill")
                    .font(.headline)

                Spacer()

                Menu {
                    Button {
                        store.loadLatestTemplate()
                    } label: {
                        Label("Načítať poslednú šablónu", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        store.saveTemplate()
                        savedTemplateHint = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            savedTemplateHint = false
                        }
                    } label: {
                        Label("Uložiť ako šablónu údajov", systemImage: "tray.and.arrow.down")
                    }

                    Divider()

                    Button {
                        store.saveProfileFromForm()
                    } label: {
                        Label("Uložiť údaje do profilu advokáta", systemImage: "person.crop.circle.badge.checkmark")
                    }
                } label: {
                    Label("Šablóna a profil", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
            }

            if savedTemplateHint {
                Text("Šablóna bola úspešne uložená pre ďalšie konverzie.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if !store.preflightErrors.isEmpty || store.evidenceNumberError != nil {
                errorCard
            }

            section("Pôvodný listinný dokument", symbol: "doc.text") {
                LabeledRow(label: "Názov dokumentu") {
                    TextField("Napr. Plná moc / Kúpna zmluva", text: $store.attestation.originalDocumentName)
                        .textFieldStyle(.roundedBorder)
                        .help("Názov listiny do doložky. Predvypĺňa sa z mena súboru.")
                }
                LabeledRow(label: "Druh dokumentu") {
                    Picker("", selection: $store.attestation.originalDocumentTypeLabel) {
                        ForEach(["Zmluva", "Plná moc", "Rozsudok", "Osvedčenie", "Rozhodnutie", "Iný dokument"], id: \.self) {
                            Text($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Druh listiny do doložky. Návrh podľa textu vždy skontrolujte, rozhoduje človek.")
                }
                if let suggestion = store.suggestedDocumentKind,
                   suggestion != store.attestation.originalDocumentTypeLabel {
                    LabeledRow(label: "") {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.secondary)
                            Text("Návrh podľa textu: \(suggestion)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Použiť") {
                                store.attestation.originalDocumentTypeLabel = suggestion
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                LabeledRow(label: "Počet listov / neprázdnych strán") {
                    Text("\(store.effectiveSheetCount) listov · \(store.analysis.nonEmptyPages) strán")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .help("Počíta sa z neprázdnych strán analýzy.")
                }
                LabeledRow(label: "Veľkosť listiny") {
                    Text(store.attestation.paperSizeBreakdown.isEmpty
                         ? "A4"
                         : store.attestation.paperSizeBreakdown
                             .map { "\($0.sizeClass.rawValue): \($0.sheets) listov" }
                             .joined(separator: ", "))
                        .font(.callout)
                        .help("Formáty zistené z rozmerov strán.")
                }
            }
            inlineError(.missingOriginalName)
            inlineError(.invalidSheetCount)
            inlineError(.noSecurityElementsConfirmed)
            Toggle("Potvrdzujem, že vstupný dokument je originál alebo úradne osvedčená kópia.",
                   isOn: $store.attestation.originConfirmed)
                .toggleStyle(.switch)
            inlineError(.originNotConfirmed)

            section("Novovzniknutý elektronický dokument", symbol: "doc.badge.gearshape") {
                LabeledRow(label: "Názov výstupu (PDF/A)") {
                    TextField("Názov výstupného súboru", text: $store.attestation.newDocumentName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            inlineError(.missingNewDocumentName)

            section("Osoba vykonávajúca konverziu", symbol: "person.crop.circle.badge.checkmark") {
                LabeledRow(label: "Meno a priezvisko") {
                    TextField("JUDr. Meno Priezvisko", text: $store.attestation.performingPerson.fullName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow(label: "Funkcia") {
                    TextField("advokát", text: $store.attestation.performingPerson.position)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                LabeledRow(label: "Evidenčné číslo advokáta (SAK)") {
                    TextField("napr. 1234", text: $store.attestation.performingPerson.registrationNumber)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                LabeledRow(label: "IČO kancelárie") {
                    TextField("IČO", text: $store.attestation.performingPerson.ico)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }
            inlineError(.missingPerformingPerson)
            inlineError(.missingRegistrationNumber)

            section("Evidencia záznamov o konverzii (CEZZK)", symbol: "number.square") {
                LabeledRow(label: "Evidenčné číslo z EZZK") {
                    HStack(spacing: 10) {
                        if let number = store.attestation.evidenceNumber, !number.isEmpty {
                            Text(number)
                                .font(.callout.monospacedDigit().weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.14), in: Capsule())
                        } else {
                            Text("pridelí sa pri autorizácii")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                    }
                }
                mandateCardStatus
                if let error = store.evidenceNumberError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let warning = store.ezzkIdentityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("EZZK pridelí číslo samo pri autorizácii, tesne pred podpisom, takže sa nikdy nepridelí pre konverziu, ktorá sa nepodpíše. Záznam sa potom sám odošle do centrálnej evidencie.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The card the number and the authorization depend on (outside Demo only).
    @ViewBuilder
    private var mandateCardStatus: some View {
        if store.settingsStore.ezzkAccountController.mode != .demo {
            switch store.mandateGate {
            case .notRequired:
                EmptyView()
            case .ready(let label):
                Label("Mandátny certifikát: \(label)", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .needsUnlock:
                Label(ZakoSessionStore.unlockCardMessage, systemImage: "key.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .insertCard:
                Label(ZakoSessionStore.insertMandateCardMessage, systemImage: "creditcard.and.123")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .noMandate:
                Label(ZakoSessionStore.noMandateMessage, systemImage: "xmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var liveClausePreviewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Živý náhľad doložky", systemImage: "doc.plaintext")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("§ 35-39 Zz")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .center, spacing: 10) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                        .padding(.top, 4)

                    Text("OSVEDČOVACIA DOLOŽKA O ZARUČENEJ KONVERZII")
                        .font(.system(size: 11, weight: .bold, design: .serif))
                        .multilineTextAlignment(.center)

                    Text("podľa § 35 až 39 zákona č. 305/2013 Z. z. o e-Governmente")
                        .font(.system(size: 9, design: .serif))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Divider()
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        clauseFieldRow(number: "1.", label: "Názov pôvodného dokumentu:", value: clauseOriginalName)
                        clauseFieldRow(number: "2.", label: "Druh pôvodného dokumentu:", value: store.attestation.originalDocumentTypeLabel)
                        clauseFieldRow(number: "3.", label: "Počet listov pôvodného dokumentu:", value: "\(store.effectiveSheetCount)")
                        clauseFieldRow(number: "4.", label: "Počet neprázdnych strán:", value: "\(store.analysis.nonEmptyPages)")
                        clauseFieldRow(number: "5.", label: "Bezpečnostné prvky:", value: clauseElementSummary)
                        clauseFieldRow(number: "6.", label: "Osoba vykonávajúca konverziu:", value: clausePerformingPerson)
                        clauseFieldRow(number: "7.", label: "Evidenčné číslo záznamu:", value: store.attestation.evidenceNumber ?? "pridelí sa pri autorizácii")
                        clauseFieldRow(number: "8.", label: "Čas konverzie:", value: "bude určený časovou pečiatkou QTS")
                    }

                    Divider()
                        .padding(.vertical, 2)

                    Text("Tento elektronický dokument vznikol zaručenou konverziou z listinnej podoby a má rovnaké právne účinky ako pôvodný dokument.")
                        .font(.system(size: 9, design: .serif))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .top)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )

            }
        }
        .padding(16)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
        }
    }

    private var clauseOriginalName: String {
        store.attestation.originalDocumentName.isEmpty ? "Názov dokumentu" : store.attestation.originalDocumentName
    }

    private var clausePerformingPerson: String {
        store.attestation.performingPerson.clausePreviewLine
    }

    private var clauseElementSummary: String {
        if store.attestation.noSecurityElementsConfirmed {
            return "Bez bezpečnostných prvkov (potvrdené kontrolou originálu)"
        }
        if store.confirmedSecurityElements.isEmpty {
            return "Zatiaľ nepotvrdené"
        }
        return store.confirmedSecurityElements
            .map(\.clausePreviewLine)
            .joined(separator: "; ")
    }

    private func clauseFieldRow(number: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .serif))
                .frame(width: 14, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, design: .serif))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .serif))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var generatedClausePreviewText: String {
        let name = store.attestation.originalDocumentName.isEmpty ? "Názov dokumentu" : store.attestation.originalDocumentName
        let evidence = store.attestation.evidenceNumber ?? "pridelí sa pri autorizácii"

        let elementSummary = store.attestation.noSecurityElementsConfirmed ? "Bez bezpečnostných prvkov (potvrdené kontrolou originálu)" : store.confirmedSecurityElements.map(\.clausePreviewLine).joined(separator: "; ")

        return """
        OSVEDČOVACIA DOLOŽKA O ZARUČENEJ KONVERZII
        podľa § 35 až 39 zákona č. 305/2013 Z. z. o e-Governmente

        1. Názov pôvodného dokumentu: \(name)
        2. Druh pôvodného dokumentu: \(store.attestation.originalDocumentTypeLabel)
        3. Počet listov pôvodného dokumentu: \(store.effectiveSheetCount)
        4. Počet neprázdnych strán pôvodného dokumentu: \(store.analysis.nonEmptyPages)
        5. Bezpečnostné prvky pôvodného dokumentu: \(elementSummary)
        6. Osoba vykonávajúca konverziu: \(clausePerformingPerson)
        7. Evidenčné číslo záznamu o zaručenej konverzii: \(evidence)
        8. Čas konverzie: bude určený časovou pečiatkou QTS pri autorizácii

        Tento elektronický dokument vznikol zaručenou konverziou z listinnej podoby a má rovnaké právne účinky ako pôvodný dokument.
        """
    }
    @ViewBuilder
    private func inlineError(_ error: AttestationValidationError) -> some View {
        if store.preflightErrors.contains(error) {
            Text(error.errorDescription ?? "")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Doložku nie je možné autorizovať: doplňte údaje:", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(Array(store.validationErrors.enumerated()), id: \.offset) { _, error in
                Text("• \(error.errorDescription ?? "")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func section<Content: View>(_ title: String, symbol: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) { content() }
                .glassCard(padding: 14)
        }
    }
}

struct LabeledRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 190, idealWidth: 230, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
    }
}
