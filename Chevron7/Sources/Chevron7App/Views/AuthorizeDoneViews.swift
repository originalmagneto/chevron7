// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit
import AppKit
import UniformTypeIdentifiers

struct AuthorizeView: View {
    @Bindable var store: ZakoSessionStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Pred autorizáciou: kontrolný zoznam", systemImage: "checklist")
                        .font(.headline)

                    tokenStatusRow

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            checklistCard
                            certificateCard
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            checklistCard
                            certificateCard
                        }
                    }

                    if let error = store.lastError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !store.validationErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(store.validationErrors.enumerated()), id: \.offset) { _, err in
                                Text("• \(err.errorDescription ?? "")")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .padding(20)
            }

            StickyActionBar {
                Button {
                    store.step = .attestation
                } label: {
                    Label("Späť na doložku", systemImage: "chevron.left")
                }
                .controlSize(.large)
                .disabled(store.isAuthorizing)

                Spacer()

                mobileAuthorizeButton
                authorizeButton
            }
        }
        .sheet(isPresented: Bindable(store.mobileSigning).isPresented) {
            if let session = store.mobileSigning.session {
                MobileSigningSheet(session: session) { store.mobileSigning.cancel() }
                    .interactiveDismissDisabled()
            }
        }
        .task { await store.refreshIdentities() }
        .task(id: store.signingPIN) {
            guard !store.signingProviderIsDemo, !store.signingPIN.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await store.refreshIdentities()
        }
    }

    private var tokenStatusRow: some View {
        Group {
            if store.signingProvider is DemoSigningProvider {
                Label("Demo režim: kvalifikovaná karta nie je pripojená.",
                      systemImage: "creditcard.and.123")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.identities.isEmpty {
                Label("Karta nie je detegovaná: vložte eID alebo advokátsky preukaz.",
                      systemImage: "creditcard.and.123")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.isCertificateTypePending {
                Label("Karta je pripojená. Typ certifikátu sa overí po zadaní PIN.",
                      systemImage: "creditcard.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Karta je pripojená, certifikáty načítané.",
                      systemImage: "creditcard.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var checklistItems: [(Bool, String, String)] {
        let identitySelected = store.selectedIdentityID != nil && store.selectedIdentity != nil
        // Outside Demo the switch is hidden and the qualified built-in authorities always stamp.
        let qtsReady = store.showsQualifiedTimestampToggle
            ? (!store.includeQualifiedTimestamp
               || !store.settings.selectedTSAURL.trimmingCharacters(in: .whitespaces).isEmpty)
            : !TimestampAuthority.qualifiedURLs.isEmpty
        let qtsLabel = !store.showsQualifiedTimestampToggle
            ? "QTS z kvalifikovaných autorít časových pečiatok"
            : (store.includeQualifiedTimestamp ? "QTS pripravená s TSA službou" : "QTS nepoužitá")
        return [
            inputSignatureChecklistItem,
            (store.attestation.originConfirmed,
             "Originál alebo úradne osvedčená kópia potvrdená", "checkmark.seal"),
            (!store.attestation.originalDocumentName.trimmingCharacters(in: .whitespaces).isEmpty,
             "Názov pôvodného dokumentu vyplnený", "text.badge.checkmark"),
            (!store.attestation.newDocumentName.trimmingCharacters(in: .whitespaces).isEmpty,
             "Názov elektronického dokumentu vyplnený", "doc.badge.gearshape"),
            (store.effectiveSheetCount > 0,
             "Počet listov určený (\(store.effectiveSheetCount))", "rectangle.stack"),
            (store.confirmedSecurityElements.count > 0 && store.pendingSecurityElementCount == 0,
             "Bezpečnostné prvky potvrdené (\(store.confirmedSecurityElements.count))", "shield.checkerboard"),
            (store.unreviewedNonEmptyPages.isEmpty && store.analysis.nonEmptyPages > 0,
             "Všetky neprázdne strany skontrolované", "doc.text.magnifyingglass"),
            // Authorization allocates the number itself, so this item never blocks.
            (true, store.attestation.evidenceNumber.map { "Evidenčné číslo z EZZK: \($0)" }
                ?? "Evidenčné číslo pridelí EZZK pri autorizácii", "number.square.fill"),
            (!store.attestation.performingPerson.fullName.trimmingCharacters(in: .whitespaces).isEmpty,
             "Osoba vykonávajúca konverziu vyplnená", "person.crop.circle"),
            (!store.attestation.performingPerson.registrationNumber.trimmingCharacters(in: .whitespaces).isEmpty,
             "Evidenčné číslo advokáta vyplnené", "building.columns"),
            (identitySelected, "Identita pre podpis vybraná", "person.badge.key"),
            (store.mandateRequirementSatisfied, "Mandátny certifikát SAK pripravený", "checkmark.seal"),
            (qtsReady, qtsLabel, "clock.badge.checkmark")
        ]
    }

    private var inputSignatureChecklistItem: (Bool, String, String) {
        switch store.inputSignatureInspection.state {
        case .valid:
            return (true, "Vstupné podpisy overené", "signature.badge.checkmark")
        case .invalid:
            return (false, "Vstup obsahuje neplatný elektronický podpis", "xmark.seal")
        case .unknown:
            return (false, "Vstupné podpisy sa nepodarilo jednoznačne overiť", "questionmark.seal")
        case .unavailable:
            return (false, "Overenie vstupných podpisov nie je dostupné", "exclamationmark.triangle")
        }
    }

    private var checklistCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zákonné náležitosti doložky")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(checklistItems.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Image(systemName: item.0 ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(item.0 ? Color.green : Color.secondary)
                    Image(systemName: item.2)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(item.1)
                        .font(.callout)
                }
            }
            Text(store.inputSignatureInspection.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Detail overenia vstupných podpisov")
                .accessibilityValue(store.inputSignatureInspection.detail)
        }
        .glassCard(padding: 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var certificateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Podpisový certifikát pre autorizáciu")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if store.identities.isEmpty {
                ProgressView("Vyhľadávam certifikáty…")
                    .controlSize(.small)
            } else {
                ForEach(store.identities) { identity in
                    IdentityRow(identity: identity,
                               isSelected: store.selectedIdentityID == identity.id,
                               onSelect: { store.selectedIdentityID = identity.id })
                }
            }

            if store.isResolvingCertificate {
                ProgressView("Načítavam certifikáty z karty…")
                    .controlSize(.small)
            }

            if let error = store.certificateLoadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.signingProviderIsDemo {
                Label(authorizationCardHint, systemImage: "key.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Here, not in the action bar: squeezed between the buttons this text wrapped
            // word by word and grew the window past the screen, hiding "Autorizovať".
            if store.showsMobileOutsideDemoNotice {
                Label(ZakoSessionStore.mobileOutsideDemoMessage, systemImage: "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.showsQualifiedTimestampToggle {
                Toggle(isOn: $store.includeQualifiedTimestamp) {
                    Label("Kvalifikovaná časová pečiatka (QTS)", systemImage: "clock.badge.checkmark")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if store.requiresMandateOverride {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Zvolený certifikát nie je mandátnym certifikátom pre zaručenú konverziu.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Toggle(isOn: Binding(
                        get: { store.hasValidMandateOverride },
                        set: { store.setMandateOverride($0) })) {
                        Text("Rozumiem: pokračovať s ne-mandátnym certifikátom")
                            .font(.caption2)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .glassCard(padding: 14)
        .frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity, alignment: .leading)
    }

    private var authorizationCardHint: String {
        switch store.mandateGate {
        case .ready(let label) where store.hasResolvedCertificate:
            "Podpíše sa mandátnym certifikátom \(label)."
        case .noMandate:
            ZakoSessionStore.noMandateMessage
        default:
            "Podržte Autorizovať: aplikácia skontroluje kartu, vyžiada PIN alebo BOK a načíta mandátny certifikát."
        }
    }

    @ViewBuilder
    private var authorizeButton: some View {
        HoldToConfirmButton(
            title: "Autorizovať konverziu",
            systemImage: "signature.badge.checkmark",
            workingText: store.analysisProgressText,
            disabled: store.isAuthorizing || store.isResolvingCertificate || store.cardPrompt != nil
                || !store.canBeginAuthorization,
            isWorking: store.isAuthorizing
        ) {
            Task { await store.beginAuthorization() }
        }
    }

    @ViewBuilder
    private var mobileAuthorizeButton: some View {
        if store.isMobileSigningAvailable {
            Button {
                Task { await store.authorizeAndSign(viaMobile: true) }
            } label: {
                HStack(spacing: 8) {
                    if store.isAuthorizing, store.isAuthorizingViaMobile {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    }
                    Text("Autorizovať mobilom")
                        .font(.body.weight(.semibold))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(store.isAuthorizing || !store.isMobilePreflightComplete)
            .help("Vyžaduje mandátny certifikát na občianskom preukaze. Bez neho sa konverzia odmietne.")
        }
    }
}

// MARK: - Identity Row Component
struct IdentityRow: View {
    let identity: SigningIdentityInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(identity.issuerSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !identity.hasPrivateKey {
                        Text("vyžaduje PIN/BOK na karte")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if identity.isMandateCertificate {
                    badge("MANDÁTNY", tint: .green)
                }
                if identity.isQualified {
                    badge("QCP", tint: .blue)
                } else if !identity.id.hasPrefix("demo") {
                    badge("KOMERČNÝ", tint: .orange)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.accentColor.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Certifikát \(identity.label)")
        .accessibilityValue("\(identity.issuerSummary); \(isSelected ? "Vybraný" : "Nevybraný")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Step 5: Done View for ZaKo
struct DoneView: View {
    let store: ZakoSessionStore
    @State private var exportError: String?
    @State private var isWorkingOnEZZK = false
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // The stored row decides what is said (its state and the EZZK mode it was signed
            // in); the checker's change count redraws when the periodic check moves it on,
            // and the timeline when a waiting "Overiť v EZZK" becomes available.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ezzkStatus(presentation(at: context.date))
            }
            if let directory = store.outputDirectory {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Priečinok s vygenerovanými súbormi:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(directory.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        Button {
                            NSWorkspace.shared.open(directory)
                        } label: {
                            Label("Ukázať vo Finderi", systemImage: "folder")
                        }
                        .controlSize(.large)

                        Button {
                            exportAs()
                        } label: {
                            Label("Uložiť ako…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            startNewConversion()
                        } label: {
                            Label("Nová konverzia", systemImage: "plus")
                        }
                        .controlSize(.large)
                    }
                    if let exportError {
                        HStack(spacing: 8) {
                            Text(exportError)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Skúsiť znova", action: exportAs)
                                .buttonStyle(.bordered)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .glassCard(cornerRadius: 12, padding: 12)
                .frame(maxWidth: 520)
            }

            DetectorTrainingOfferBanner(settingsStore: store.settingsStore)
                .frame(maxWidth: 520)

            DetectorTrainingProgressLine(store: store)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presentation(at now: Date) -> ZakoDonePresentation {
        let checker = store.settingsStore.statusChecker
        _ = checker.changeCount
        let record = store.evidenceStore.record(id: store.currentRecordID)
        return ZakoDonePresentation(record: record,
                                    lastError: store.lastError,
                                    lastErrorStatus: store.submissionStatus,
                                    nextStatusCheck: record.flatMap { checker.nextStatusCheck(for: $0) },
                                    now: now,
                                    currentMode: store.settingsStore.ezzkAccountController.mode,
                                    productionAllowed: store.settingsStore.ezzkAccountController
                                        .productionPolicy.allowsConsequentialCalls)
    }

    private func toneColor(_ tone: EZZKRecordPresentation.Tone) -> Color {
        switch tone {
        case .success: return .green
        case .pending, .warning: return .orange
        case .failure: return .red
        }
    }

    @ViewBuilder
    private func ezzkStatus(_ done: ZakoDonePresentation) -> some View {
        let tint = toneColor(done.tone)
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 130, height: 130)
                Image(systemName: done.symbol)
                    .font(.system(size: 60))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(done.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let result = store.result {
                    Text(result.isLegallyBinding
                         ? "Kvalifikovaný elektronický podpis a doložka pripojené"
                         : "DEMO režim: konverzia nemá právne účinky")
                        .font(.callout)
                        .foregroundStyle(result.isLegallyBinding ? Color.secondary : Color.orange)
                }

                ForEach(done.lines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(done.tone == .success ? Color.secondary : tint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }

                if let evidence = store.attestation.evidenceNumber {
                    HStack(spacing: 6) {
                        Text("Evidenčné číslo:")
                            .foregroundStyle(.secondary)
                        Text(evidence)
                            .font(.callout.monospacedDigit().weight(.bold))
                    }
                    .padding(.top, 2)
                }

                ezzkActionButton(done)

                if let error = done.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func ezzkActionButton(_ done: ZakoDonePresentation) -> some View {
        switch done.action {
        case .none:
            EmptyView()
        case .send, .verify:
            let isSend = done.action == .send
            Button {
                isWorkingOnEZZK = true
                Task {
                    if isSend {
                        await store.retryQueuedSubmission()
                    } else {
                        await store.verifyRecordInEZZK()
                    }
                    isWorkingOnEZZK = false
                }
            } label: {
                HStack(spacing: 5) {
                    if isWorkingOnEZZK {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isSend ? "tray.and.arrow.up" : "magnifyingglass")
                    }
                    Text(isSend ? "Odoslať do EZZK" : "Overiť v EZZK")
                }
            }
            .controlSize(.small)
            .disabled(!done.isActionEnabled || isWorkingOnEZZK)
            .padding(.top, 4)
        }
    }

    /// "Uložiť ako…": a copy of the file the client got (the ASiC-E, or the PDF/A on the
    /// phone route; rows from before the single output name only the PDF/A).
    private func exportAs() {
        exportError = nil
        guard let directory = store.outputDirectory else { return }
        let record = store.evidenceStore.record(id: store.currentRecordID)
        let fileName = record?.deliveredFileName ?? record?.pdfFileName
            ?? ConversionOutputNaming.pdfFileName(
                originalDocumentName: store.attestation.originalDocumentName,
                requestedDocumentName: store.attestation.newDocumentName)
        let delivered = directory.appendingPathComponent(fileName)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: delivered.pathExtension) ?? .data]
        panel.nameFieldStringValue = delivered.lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard FileManager.default.fileExists(atPath: delivered.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Výstup sa nenašiel."])
                }
                try FileManager.default.copyItem(at: delivered, to: url)
            } catch {
                exportError = "Export sa nepodaril: \(error.localizedDescription)"
            }
        }
    }

    private func startNewConversion() {
        store.resetSession(keepingProfile: true)
        store.step = .intake
    }
}
