// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Chevron7Kit

/// Dates in the E→E screens as an advocate reads them (Slovak, to the second).
enum E2EDateText {
    static func string(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .standard)
            .locale(Locale(identifier: "sk_SK")))
    }
}

/// One titled group of the ZaKo screens: a secondary label with its symbol over a glass card,
/// the same shape as the P→E clause form's sections.
struct ZakoSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(padding: 14)
        }
    }
}

/// E→E step 2: the client's signatures verified against the trusted lists (§ 36 ods. 4
/// písm. a) a b) zákona č. 305/2013 Z. z.), what the new document will be, and in Ostrá
/// evidencia the qualified validation service's sealed report. Laid out like the P→E
/// analysis step: the document on the left, an inspector of cards on the right.
struct ZakoVerificationView: View {
    @Bindable var store: ZakoSessionStore
    @State private var confirmingUndetermined = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if let document = store.document {
                        PDFKitPreview(document: document)
                    } else {
                        Color(nsColor: .underPageBackgroundColor)
                    }
                }
                .frame(minWidth: 300, maxWidth: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if store.isVerifying {
                            verifyingCard
                        } else if let error = store.verificationError {
                            ZakoNotice(title: "Podpisy sa nepodarilo overiť", message: error, tone: .failure)
                        } else if let original = store.electronicOriginal {
                            verdictCard(original)
                            authorizationsSection(original)
                            documentSection(original)
                            qualifiedSection
                        }
                    }
                    .padding(18)
                }
                .frame(minWidth: 380, idealWidth: 440, maxWidth: 480)
                .background(.regularMaterial)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                }
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
                .disabled(store.validationReportForSaving == nil || store.isVerifying)

                Spacer()

                Button {
                    store.step = .attestation
                } label: {
                    HStack(spacing: 6) {
                        Text("Pokračovať na doložku")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
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
            Label("Overenie podpisov klienta", systemImage: "checkmark.seal")
                .font(.headline)
            Text("Platnosť autorizácie a časovej pečiatky pôvodného dokumentu (§ 36 ods. 4 písm. a) a b) zákona č. 305/2013 Z. z.).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var verifyingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("Overujem podpisy voči dôveryhodným zoznamom EÚ")
                    .font(.callout.weight(.medium))
                Text("Kontrolujem certifikáty, ich odvolanie a časové pečiatky a či je PDF platné PDF/A. Prvé overenie po spustení aplikácie môže trvať do minúty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }

    /// One line that says whether the conversion may go on, in the gate's own words.
    @ViewBuilder
    private func verdictCard(_ original: ElectronicOriginal) -> some View {
        switch store.e2eDecision {
        case .blocked(let reason):
            ZakoNotice(title: "Konverziu nemožno vykonať", message: reason, tone: .failure)
        case .needsConfirmation:
            VStack(alignment: .leading, spacing: 10) {
                ZakoNotice(title: "Platnosť niektorého podpisu sa nedá zistiť", message: undeterminedMessage,
                           tone: .warning)
                if store.undeterminedConfirmed {
                    Label("Potvrdené: do doložky aj záznamu sa zapíše „nie je možné zistiť“.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Pokračovať aj tak…") { confirmingUndetermined = true }
                }
            }
        case .ready, .none:
            ZakoNotice(title: verdictTitle(original),
                       message: "Údaje o podpisoch, ich overení a časových pečiatkach sa zapíšu do doložky aj záznamu.",
                       tone: .success)
        }
    }

    private func verdictTitle(_ original: ElectronicOriginal) -> String {
        switch original.authorizations.count {
        case 1: return "Podpis klienta je platný"
        case 2: return "Oba podpisy sú platné"
        default: return "Všetky podpisy (\(original.authorizations.count)) sú platné"
        }
    }

    private var undeterminedMessage: String {
        guard case .needsConfirmation(let list) = store.e2eDecision else { return "" }
        return list.map { authorization in
            let reason = authorization.reason ?? "dôvod overenie neuviedlo"
            return "Podpis \(authorization.signerName) sa nepodarilo overiť: \(reason)."
        }.joined(separator: " ") + " Do doložky aj záznamu sa zapíše „nie je možné zistiť“."
    }

    private func authorizationsSection(_ original: ElectronicOriginal) -> some View {
        ZakoSection(title: original.authorizations.count == 1 ? "Podpis" : "Podpisy a pečate",
                    symbol: "signature") {
            ForEach(Array(original.authorizations.enumerated()), id: \.element.signatureID) { index, authorization in
                if index > 0 { Divider() }
                authorizationRow(authorization, showsDocument: original.documents.count > 1)
            }
        }
    }

    private func authorizationRow(_ authorization: ElectronicOriginal.Authorization, showsDocument: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(authorization.state))
                    .foregroundStyle(tint(authorization.state))
                    .accessibilityHidden(true)
                Text(authorization.signerName)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(authorization.state.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint(authorization.state))
            }
            Group {
                Text(authorization.typeOther ?? authorization.type.skName)
                if let time = authorization.signingTime {
                    Text("Podpísané \(E2EDateText.string(time))")
                }
                if let mandate = authorization.mandate {
                    Text("Mandát: \(mandate)")
                }
                if let timestamp = authorization.timestamp {
                    Text("Časová pečiatka \(timestamp.typeItem.skName.lowercased()), \(timestamp.state.rawValue): \(timestamp.publisherCommonName), \(E2EDateText.string(timestamp.created))")
                } else {
                    Text("Bez časovej pečiatky")
                }
                if showsDocument {
                    Text("Pokrýva \(authorization.documentNames.joined(separator: ", "))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 24)
        }
        .accessibilityElement(children: .combine)
    }

    private func documentSection(_ original: ElectronicOriginal) -> some View {
        ZakoSection(title: "Dokument", symbol: "doc.text") {
            ForEach(original.documents, id: \.name) { document in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(document.name) · \(document.formatOther ?? document.format.skName)")
                        .font(.callout)
                    Text("SHA-256 \(document.sha256.map { String(format: "%02x", $0) }.joined())")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(document.sha256.map { String(format: "%02x", $0) }.joined())
                }
            }
            Divider()
            switch original.plan {
            case .keep:
                Label("Zostáva nezmenený aj s podpismi klienta: je to PDF/A bez príloh.", systemImage: "doc.on.doc")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .convert(let reason):
                Label("\(reason), preto vznikne nový PDF/A-2b. Podpisy klienta zostanú zapísané v doložke.",
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
            ZakoSection(title: "Kvalifikovaná služba validácie", symbol: "checkmark.shield") {
                Text(store.e2eNeedsQualifiedReport
                     ? "V ostrej evidencii treba podpisy klienta overiť aj kvalifikovanou službou validácie (§ 3 ods. 4 vyhlášky č. 70/2021 Z. z.) a pripojiť jej zapečatený výsledok."
                     : "Výsledok kvalifikovanej služby validácie môžete pripojiť aj v testovacej evidencii.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if services.isEmpty {
                    OpenSettingsButton { Text("Pridať službu v Nastaveniach…") }
                        .buttonStyle(.link)
                        .help("Nastavenia, EZZK, Rozšírené nastavenia, Kvalifikovaná služba validácie")
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
                    Label("Pripojiť výsledok validácie…", systemImage: "paperclip")
                }
                if let report = store.qualifiedReport {
                    Label("\(report.fileName) · pečať: \(report.sealSubject)", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if report.binding == .needsConfirmation {
                        Toggle("Výsledok sa týka tohto dokumentu", isOn: $store.qualifiedReportConfirmed)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                    }
                }
                if let error = store.qualifiedReportError {
                    ZakoNotice(title: "Výsledok validácie nemožno použiť", message: error, tone: .warning)
                }
            }
        }
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

/// A short titled message in the ZaKo screens: success, warning or failure, with its symbol.
struct ZakoNotice: View {
    enum Tone { case success, warning, failure }
    let title: String
    let message: String
    let tone: Tone

    private var color: Color {
        switch tone {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private var symbol: String {
        switch tone {
        case .success: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// E→E step 3: what the advocate adds to the clause and record, laid out like the P→E clause
/// form, with a live preview of the E→E clause beside it.
struct E2EAttestationFormView: View {
    @Bindable var store: ZakoSessionStore
    @State private var availableWidth: CGFloat = .infinity

    static let documentKinds = ["Zmluva", "Plná moc", "Rozsudok", "Osvedčenie", "Rozhodnutie", "Iný dokument"]

    private var previewFits: Bool {
        MacOS27Layout.showsClausePreview(availableWidth: availableWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            HStack(spacing: 0) {
                ScrollView {
                    formContent
                        .padding(18)
                }
                .frame(minWidth: MacOS27Layout.clauseFormMinimumWidth, maxWidth: .infinity)

                if previewFits {
                    clausePreview
                        .frame(minWidth: MacOS27Layout.clausePreviewMinimumWidth, idealWidth: 380, maxWidth: 440)
                }
            }

            StickyActionBar {
                Button {
                    store.step = .verification
                } label: {
                    Label("Späť na overenie", systemImage: "chevron.left")
                }
                .controlSize(.large)

                Spacer()

                if let missing = missingSummary {
                    Text(missing)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
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
                .keyboardShortcut(.defaultAction)
                .disabled(!store.e2eReadyToAuthorize)
            }
        }
        .onAppear {
            if store.attestation.originalDocumentTypeLabel.trimmingCharacters(in: .whitespaces).isEmpty {
                store.attestation.originalDocumentTypeLabel = "Iný dokument"
            }
        }
    }

    /// What still keeps "Pokračovať" off, said beside it.
    private var missingSummary: String? {
        var missing: [String] = []
        if store.attestation.originalDocumentTypeLabel.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("druh dokumentu") }
        if store.attestation.newDocumentName.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("názov nového dokumentu") }
        if store.attestation.performingPerson.fullName.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("meno a priezvisko") }
        return missing.isEmpty ? nil : "Doplňte: " + missing.joined(separator: ", ")
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Osvedčovacia doložka zaručenej konverzie", systemImage: "building.columns.fill")
                    .font(.headline)
                Spacer()
                Button {
                    store.saveProfileFromForm()
                } label: {
                    Label("Uložiť do profilu advokáta", systemImage: "person.crop.circle.badge.checkmark")
                }
                .controlSize(.small)
                .help("Uloží údaje osoby vykonávajúcej konverziu ako profil advokáta")
            }

            ZakoSection(title: "Pôvodný elektronický dokument", symbol: "doc.text") {
                LabeledRow(label: "Súbor") {
                    Text(store.attestation.originalDocumentName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.attestation.originalDocumentName)
                }
                LabeledRow(label: "Druh dokumentu") {
                    Picker("Druh dokumentu", selection: $store.attestation.originalDocumentTypeLabel) {
                        ForEach(Self.documentKinds, id: \.self) { Text($0) }
                        if !Self.documentKinds.contains(store.attestation.originalDocumentTypeLabel),
                           !store.attestation.originalDocumentTypeLabel.isEmpty {
                            Text(store.attestation.originalDocumentTypeLabel).tag(store.attestation.originalDocumentTypeLabel)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                    .help("Druh pôvodného dokumentu do záznamu o konverzii.")
                }
                LabeledRow(label: "Podpisy") {
                    Text(signaturesLine)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ZakoSection(title: "Novovzniknutý elektronický dokument", symbol: "doc.badge.gearshape") {
                LabeledRow(label: "Názov nového dokumentu") {
                    TextField("Názov výstupného súboru", text: $store.attestation.newDocumentName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow(label: "Formát") {
                    Text(newDocumentLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ZakoSection(title: "Osoba vykonávajúca konverziu", symbol: "person.crop.circle.badge.checkmark") {
                LabeledRow(label: "Meno a priezvisko") {
                    TextField("JUDr. Meno Priezvisko", text: $store.attestation.performingPerson.fullName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow(label: "Funkcia") {
                    TextField("advokát", text: $store.attestation.performingPerson.position)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                LabeledRow(label: "Advokátska kancelária") {
                    TextField("Názov kancelárie", text: $store.attestation.performingPerson.officeName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledRow(label: "Evidenčné číslo advokáta (SAK)") {
                    TextField("napr. 1234", text: $store.attestation.performingPerson.registrationNumber)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                LabeledRow(label: "IČO kancelárie") {
                    TextField("8 alebo 12 číslic", text: $store.attestation.performingPerson.ico)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }

            ZakoSection(title: "Evidencia záznamov o konverzii (CEZZK)", symbol: "number.square") {
                LabeledRow(label: "Evidenčné číslo z EZZK") {
                    Text(store.attestation.evidenceNumber ?? "pridelí sa pri autorizácii")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("EZZK pridelí číslo pri autorizácii, až keď sú doložka aj záznam skontrolované podľa oficiálnych formulárov.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signaturesLine: String {
        guard let original = store.electronicOriginal else { return "neoverené" }
        let names = original.authorizations.map(\.signerName).joined(separator: ", ")
        let valid = original.authorizations.allSatisfy { $0.state == .valid }
        return "\(original.authorizations.count) · \(names)" + (valid ? " · platné" : "")
    }

    private var newDocumentLine: String {
        switch store.electronicOriginal?.plan {
        case .keep(let format, let other): return "\(other ?? format.skName), nezmenený s podpismi klienta"
        case .convert: return "nový PDF/A-2b"
        case .none: return ""
        }
    }

    private var clausePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Živý náhľad doložky", systemImage: "doc.plaintext")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("§ 35 ods. 1 písm. c)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                        .frame(maxWidth: .infinity)
                    Text("OSVEDČOVACIA DOLOŽKA")
                        .font(.system(size: 11, weight: .bold, design: .serif))
                        .frame(maxWidth: .infinity)
                    Text("Osvedčujem, že tento elektronický dokument vznikol zaručenou konverziou ako elektronická podoba pôvodného dokumentu v elektronickej forme v súlade s § 35 ods. 1 písm. c) zákona č. 305/2013 Z. z.")
                        .font(.system(size: 10, design: .serif))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    previewRow("Pôvodný dokument", store.electronicOriginal?.documents.map(\.name).joined(separator: ", ") ?? "")
                    ForEach(store.electronicOriginal?.authorizations ?? [], id: \.signatureID) { authorization in
                        previewRow("Autorizácia", "\(authorization.type.skName), \(authorization.personID), \(authorization.state.rawValue)"
                                   + (authorization.timestamp.map { ", časová pečiatka \(E2EDateText.string($0.created))" } ?? ""))
                    }
                    previewRow("Nový dokument", store.attestation.newDocumentName)
                    previewRow("Evidenčné číslo", store.attestation.evidenceNumber ?? "pridelí sa pri autorizácii")
                    previewRow("Konverziu vykonal", store.attestation.performingPerson.clausePreviewLine)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func previewRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label + ":")
                .font(.system(size: 10, design: .serif))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "doplňte" : value)
                .font(.system(size: 10, weight: .semibold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
