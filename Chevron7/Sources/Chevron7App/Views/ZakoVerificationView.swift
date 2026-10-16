// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Chevron7Kit

/// E→E step 2: the client's signatures verified against the trusted lists (§ 36 ods. 4
/// písm. a) a b) zákona č. 305/2013 Z. z.), what the new document will be, and in Ostrá
/// evidencia the qualified validation service's sealed report.
struct ZakoVerificationView: View {
    @Bindable var store: ZakoSessionStore
    @State private var confirmingUndetermined = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let document = store.document {
                    PDFKitPreview(document: document)
                        .frame(minWidth: 320)
                } else {
                    Color.clear.frame(minWidth: 320)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if store.isVerifying {
                            ProgressView("Overujem podpisy voči dôveryhodným zoznamom…")
                                .controlSize(.small)
                        }
                        if let error = store.verificationError {
                            message(error, systemImage: "xmark.octagon.fill", tint: .red)
                        }
                        if let original = store.electronicOriginal {
                            if let banner = SignatureBannerModel.make(
                                from: SignatureTreeState(tree: original.evidence.tree, phase: .validated)) {
                                SignatureBanner(model: banner)
                            }
                            decisionSection
                            authorizationsSection(original)
                            documentsSection(original)
                            newDocumentSection(original)
                            qualifiedSection
                        }
                    }
                    .padding(20)
                }
                .frame(minWidth: 380, idealWidth: 440)
            }
            StickyActionBar {
                Button {
                    Task { await store.verifyElectronicOriginal() }
                } label: {
                    Label("Overiť znova", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                .disabled(store.isVerifying)

                Button {
                    saveReport()
                } label: {
                    Label("Uložiť správu o overení…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.large)
                .disabled(store.validationReportForSaving == nil)

                Spacer()

                Button {
                    store.step = .attestation
                } label: {
                    Label("Pokračovať", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!store.canContinueFromVerification)
            }
        }
        .confirmationDialog("Platnosť podpisu sa nedá zistiť", isPresented: $confirmingUndetermined,
                            titleVisibility: .visible) {
            Button("Pokračovať aj tak") { store.confirmUndetermined() }
            Button("Zrušiť", role: .cancel) {}
        } message: {
            Text(undeterminedMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Overenie podpisov")
                .font(.title3.weight(.semibold))
            Text("Platnosť autorizácie a časovej pečiatky pôvodného dokumentu podľa § 36 ods. 4 písm. a) a b) zákona č. 305/2013 Z. z.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var decisionSection: some View {
        switch store.e2eDecision {
        case .blocked(let reason):
            message(reason, systemImage: "xmark.octagon.fill", tint: .red)
        case .needsConfirmation:
            VStack(alignment: .leading, spacing: 8) {
                message(undeterminedMessage, systemImage: "questionmark.diamond.fill", tint: .orange)
                if store.undeterminedConfirmed {
                    Label("Potvrdené: zapíše sa „nie je možné zistiť“.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Pokračovať aj tak…") { confirmingUndetermined = true }
                }
            }
        case .ready, .none:
            EmptyView()
        }
    }

    private var undeterminedMessage: String {
        guard case .needsConfirmation(let list) = store.e2eDecision else { return "" }
        return list.map { authorization in
            let reason = authorization.reason ?? "dôvod engine neuviedol"
            return "Podpis \(authorization.signerName) sa nepodarilo overiť: \(reason)."
        }.joined(separator: " ") + " Do doložky aj záznamu sa zapíše „nie je možné zistiť“."
    }

    private func authorizationsSection(_ original: ElectronicOriginal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Podpisy a pečate")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(original.authorizations, id: \.signatureID) { authorization in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: icon(authorization.state))
                            .foregroundStyle(tint(authorization.state))
                        Text(authorization.signerName).font(.callout.weight(.medium))
                        Spacer()
                        Text(authorization.state.rawValue).font(.caption).foregroundStyle(tint(authorization.state))
                    }
                    Text(authorization.typeOther ?? authorization.type.skName)
                        .font(.caption).foregroundStyle(.secondary)
                    if let mandate = authorization.mandate {
                        Text("Mandát: \(mandate)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let timestamp = authorization.timestamp {
                        Text("Časová pečiatka: \(timestamp.typeItem.skName.lowercased()), \(timestamp.publisherCommonName), \(timestamp.created.formatted(date: .abbreviated, time: .standard)) (\(timestamp.state.rawValue))")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Bez časovej pečiatky").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Pokrýva: \(authorization.documentNames.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func documentsSection(_ original: ElectronicOriginal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pôvodné dokumenty")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(original.documents, id: \.name) { document in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(document.name) · \(document.formatOther ?? document.format.skName)").font(.callout)
                    Text("SHA-256: \(document.sha256.map { String(format: "%02x", $0) }.joined())")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func newDocumentSection(_ original: ElectronicOriginal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nový dokument")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            switch original.plan {
            case .keep:
                Label("PDF je PDF/A bez príloh: zostáva nezmenený aj s podpismi klienta.", systemImage: "doc.on.doc")
                    .font(.callout)
            case .convert(let reason):
                Label("\(reason): vznikne nový PDF/A-2b, podpisy klienta zostanú zapísané v doložke.",
                      systemImage: "doc.badge.arrow.up")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var qualifiedSection: some View {
        let services = store.settings.qualifiedValidationServices
        if store.e2eNeedsQualifiedReport || !services.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kvalifikovaná služba validácie")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(store.e2eNeedsQualifiedReport
                     ? "V ostrej evidencii treba podpisy klienta overiť kvalifikovanou službou validácie (§ 3 ods. 4 vyhlášky č. 70/2021 Z. z.) a pripojiť jej zapečatený výsledok."
                     : "Výsledok kvalifikovanej služby validácie môžete pripojiť aj v testovacej evidencii.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if services.isEmpty {
                    Label("Pridajte službu v Nastaveniach, EZZK, Rozšírené nastavenia, Kvalifikovaná služba validácie.", systemImage: "gearshape")
                        .font(.caption)
                }
                ForEach(services) { service in
                    if let portal = service.portalURL {
                        Button {
                            NSWorkspace.shared.open(portal)
                        } label: {
                            Label("Otvoriť portál služby \(service.name)", systemImage: "safari")
                        }
                        .buttonStyle(.link)
                    }
                }
                Button {
                    attachReport()
                } label: {
                    Label("Pripojiť výsledok kvalifikovanej validácie…", systemImage: "paperclip")
                }
                .disabled(store.electronicOriginal == nil)
                if let report = store.qualifiedReport {
                    Label("Pripojený: \(report.fileName) (pečať: \(report.sealSubject))", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if report.binding == .needsConfirmation {
                        Toggle("Výsledok sa týka tohto dokumentu (\(store.electronicOriginal?.sourceName ?? ""))",
                               isOn: $store.qualifiedReportConfirmed)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                    }
                }
                if let error = store.qualifiedReportError {
                    message(error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
        }
    }

    private func message(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func icon(_ state: ElectronicOriginal.ValidityState) -> String {
        switch state {
        case .valid: return "checkmark.seal.fill"
        case .invalid: return "xmark.seal.fill"
        case .undetermined: return "questionmark.diamond.fill"
        }
    }

    private func tint(_ state: ElectronicOriginal.ValidityState) -> Color {
        switch state {
        case .valid: return .green
        case .invalid: return .red
        case .undetermined: return .orange
        }
    }

    private func saveReport() {
        guard let report = store.validationReportForSaving else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = report.fileName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.data.write(to: url, options: [.atomic])
            } catch {
                store.verificationError = "Správu o overení sa nepodarilo uložiť: \(error.localizedDescription)"
            }
        }
    }

    private func attachReport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Vyberte zapečatený výsledok kvalifikovanej služby validácie (PDF, XML alebo ASiC)."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await store.attachQualifiedReport(at: url) }
        }
    }
}

/// E→E step 3: what the advocate adds to the clause and record. The original's authorizations
/// come from the verification and are not edited here.
struct E2EAttestationFormView: View {
    @Bindable var store: ZakoSessionStore

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Pôvodný dokument") {
                    LabeledContent("Súbor", value: store.attestation.originalDocumentName)
                    TextField("Druh dokumentu", text: $store.attestation.originalDocumentTypeLabel,
                              prompt: Text("napr. zmluva o pôžičke"))
                }
                Section("Nový dokument") {
                    TextField("Názov nového dokumentu", text: $store.attestation.newDocumentName)
                }
                Section("Osoba vykonávajúca konverziu") {
                    TextField("Meno a priezvisko", text: $store.attestation.performingPerson.fullName)
                    TextField("Funkcia", text: $store.attestation.performingPerson.position)
                    TextField("Advokátska kancelária", text: $store.attestation.performingPerson.officeName)
                    TextField("IČO", text: $store.attestation.performingPerson.ico)
                    TextField("Evidenčné číslo SAK", text: $store.attestation.performingPerson.registrationNumber)
                }
                Section("Osvedčovacia doložka") {
                    Text("Osvedčujem, že tento elektronický dokument vznikol zaručenou konverziou ako elektronická podoba pôvodného dokumentu v elektronickej forme v súlade s § 35 ods. 1 písm. c) zákona č. 305/2013 Z. z.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Údaje o podpisoch klienta, ich overení a časových pečiatkach sa doplnia z overenia; evidenčné číslo pridelí EZZK pri autorizácii.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            StickyActionBar {
                Button {
                    store.step = .verification
                } label: {
                    Label("Späť na overenie", systemImage: "chevron.left")
                }
                .controlSize(.large)
                Spacer()
                Button {
                    store.step = .authorize
                } label: {
                    Label("Pokračovať na autorizáciu", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!store.e2eReadyToAuthorize)
            }
        }
    }
}
